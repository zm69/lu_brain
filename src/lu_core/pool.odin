/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_core

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:testing"

///////////////////////////////////////////////////////////////////////////////
// Pool -- growing array of records addressed by a stable u32 index, with a freelist.
//
// Replaces the C Lu_Mem_Table. Records are addressed by index, never by pointer, because the
// backing array doubles when full and pointers returned by pool__get are invalidated by pool__alloc.
// When `reserve_null` is set, index 0 is allocated at init and never handed out, so 0 can be used
// as the "null" handle (pool__get returns nil for it).

    POOL_NULL_IX :: 0

    Pool :: struct($T: typeid) {
        allocator: runtime.Allocator,
        items: [dynamic]T,
        free_ixs: [dynamic]u32,
        reserve_null: bool,
    }

    pool__init :: proc(self: ^Pool($T), cap: int, reserve_null: bool, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        when VALIDATIONS do assert(cap > 0)

        self.allocator = allocator
        self.reserve_null = reserve_null
        self.items = make([dynamic]T, 0, cap, allocator) or_return
        self.free_ixs = make([dynamic]u32, 0, 0, allocator) or_return

        if reserve_null do append(&self.items, T{}) or_return

        return nil
    }

    pool__terminate :: proc(self: ^Pool($T)) -> runtime.Allocator_Error {
        delete(self.free_ixs) or_return
        delete(self.items) or_return
        self.free_ixs = nil
        self.items = nil
        return nil
    }

    pool__is_valid :: proc(self: ^Pool($T)) -> bool {
        if self == nil do return false
        if self.items == nil do return false
        return true
    }

    // Allocates a zeroed record and returns its index. May reallocate the backing array.
    pool__alloc :: proc(self: ^Pool($T)) -> (ix: u32, err: runtime.Allocator_Error) {
        if n := len(self.free_ixs); n > 0 {
            ix = self.free_ixs[n - 1]
            pop(&self.free_ixs)
            self.items[ix] = T{}
            return ix, nil
        }

        ix = u32(len(self.items))
        append(&self.items, T{}) or_return
        return ix, nil
    }

    pool__free :: proc(self: ^Pool($T), ix: u32) -> runtime.Allocator_Error {
        when VALIDATIONS {
            assert(int(ix) < len(self.items))
            assert(!(self.reserve_null && ix == POOL_NULL_IX))
        }

        append(&self.free_ixs, ix) or_return
        return nil
    }

    // Returns nil for the reserved null index.
    pool__get :: #force_inline proc(self: ^Pool($T), ix: u32) -> ^T {
        if self.reserve_null && ix == POOL_NULL_IX do return nil
        return &self.items[ix]
    }

    // Number of live (allocated, not freed) records, excluding the reserved null record.
    pool__len :: proc(self: ^Pool($T)) -> int {
        n := len(self.items) - len(self.free_ixs)
        if self.reserve_null do n -= 1
        return n
    }

    // Number of records that fit without reallocation, excluding the reserved null record.
    pool__cap :: proc(self: ^Pool($T)) -> int {
        n := cap(self.items)
        if self.reserve_null do n -= 1
        return n
    }

    // Frees every record. Existing indexes become invalid.
    pool__clear :: proc(self: ^Pool($T)) {
        clear(&self.free_ixs)
        clear(&self.items)
        if self.reserve_null do append(&self.items, T{})
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    pool__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator() // no allocations outside the provided allocator

        Item :: struct { a: int }

        pool: Pool(Item)
        testing.expect(t, pool__init(&pool, 2, true, allocator) == nil)
        defer pool__terminate(&pool)

        testing.expect(t, pool__get(&pool, POOL_NULL_IX) == nil)
        testing.expect_value(t, pool__len(&pool), 0)

        a, _ := pool__alloc(&pool)
        b, _ := pool__alloc(&pool)
        c, _ := pool__alloc(&pool) // grows
        testing.expect_value(t, a, 1)
        testing.expect_value(t, b, 2)
        testing.expect_value(t, c, 3)
        testing.expect_value(t, pool__len(&pool), 3)

        pool__get(&pool, b).a = 7
        testing.expect_value(t, pool__get(&pool, b).a, 7)

        testing.expect(t, pool__free(&pool, b) == nil)
        testing.expect_value(t, pool__len(&pool), 2)

        d, _ := pool__alloc(&pool) // reuses b, zeroed
        testing.expect_value(t, d, b)
        testing.expect_value(t, pool__get(&pool, d).a, 0)

        pool__clear(&pool)
        testing.expect_value(t, pool__len(&pool), 0)

        // without a reserved null, the first index is 0
        pool2: Pool(Item)
        testing.expect(t, pool__init(&pool2, 1, false, allocator) == nil)
        defer pool__terminate(&pool2)
        e, _ := pool__alloc(&pool2)
        testing.expect_value(t, e, 0)
        testing.expect(t, pool__get(&pool2, e) != nil)
    }
