/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:mem"

///////////////////////////////////////////////////////////////////////////////
// Rec_View -- which part of the source data is read, and where it lands in the rec.

    Rec_View :: struct {
        src_start_x: int,
        src_start_y: int,
        src_start_z: int,
        src_end_x: int,
        src_end_y: int,
        src_end_z: int,

        dest_start_x: int,
        dest_start_y: int,
    }

    rec_view__make :: proc "contextless" (w, h, d: int) -> Rec_View {
        return Rec_View{ src_end_x = w, src_end_y = h, src_end_z = d }
    }

    rec_view__update_to_dimensions :: proc "contextless" (self: ^Rec_View, w, h, d: int) {
        if self.src_end_x > w do self.src_end_x = w
        if self.src_end_y > h do self.src_end_y = h
        if self.src_end_z > d do self.src_end_z = d
    }

///////////////////////////////////////////////////////////////////////////////
// Data -- one frame of values for one rec. `values` is borrowed (w*h*d, x fastest, then y, then z).

    Data_Flag :: enum {
        Reset_Rec,
    }

    Data_Flags :: bit_set[Data_Flag]

    Data :: struct {
        block_id: Block_Id,
        rec_id: int,
        flags: Data_Flags,
        w: int,
        h: int,
        d: int,
        values: []Value,
        view: Rec_View,
    }

    data__default :: proc "contextless" () -> Data {
        return Data{ block_id = BLOCK_ID__NOT_SET, rec_id = NOT_SET }
    }

    data__set :: proc(self: ^Data, block_id: Block_Id, rec_id: int, w, h, d: int, values: []Value, view: Rec_View, flags: Data_Flags) {
        when VALIDATIONS do assert(values == nil || len(values) >= w * h * d)

        self.block_id = block_id
        self.rec_id = rec_id
        self.flags = flags
        self.w = w
        self.h = h
        self.d = d
        self.values = values
        self.view = view

        rec_view__update_to_dimensions(&self.view, w, h, d)
    }

    // Allocates zeroed values owned by the Data. Free with data__terminate.
    data__init :: proc(self: ^Data, w, h, d: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        when VALIDATIONS do assert(w > 0 && h > 0 && d > 0)

        self^ = data__default()
        self.w = w
        self.h = h
        self.d = d
        self.values = make([]Value, w * h * d, allocator) or_return
        self.view = rec_view__make(w, h, d)

        return nil
    }

    // Allocates a copy of src values owned by the Data. Free with data__terminate.
    data__init_copy :: proc(self: ^Data, src: []Value, w, h, d: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        data__init(self, w, h, d, allocator) or_return
        copy(self.values, src[:w * h * d])
        return nil
    }

    data__terminate :: proc(self: ^Data, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        err := delete(self.values, allocator)
        self.values = nil
        return err
    }

    data__is_empty :: #force_inline proc "contextless" (self: ^Data) -> bool {
        return self.values == nil
    }

    data__get_value :: #force_inline proc(self: ^Data, x, y, z: int) -> Value {
        when VALIDATIONS do assert(x < self.w && y < self.h && z < self.d)
        return self.values[z * self.w * self.h + y * self.w + x]
    }

    data__set_value :: #force_inline proc(self: ^Data, x, y, z: int, value: Value) {
        when VALIDATIONS do assert(x < self.w && y < self.h && z < self.d)
        self.values[z * self.w * self.h + y * self.w + x] = value
    }

    data__print :: proc(self: ^Data) {
        fmt.printf("\nData: ")
        fmt.printf("\n\twave_id: %v, block_ix: %v, rec_id: %v", self.block_id.wave_id, self.block_id.block_ix, self.rec_id)
        fmt.printf("\n\tw: %v, h: %v, d: %v", self.w, self.h, self.d)
        if self.values != nil do values__print(self.values, self.w, self.h, self.d)
        else do fmt.printf("\tvalues: nil")
        fmt.printf("\n")
    }

    data__print_symbols :: proc(self: ^Data) {
        fmt.printf("\nData: ")
        fmt.printf("\n\twave_id: %v, block_ix: %v, rec_id: %v", self.block_id.wave_id, self.block_id.block_ix, self.rec_id)
        fmt.printf("\n\tw: %v, h: %v, d: %v", self.w, self.h, self.d)
        if self.values != nil do values__print_symbols(self.values, self.w, self.h, self.d)
        else do fmt.printf("\tvalues: nil")
        fmt.printf("\n")
    }

    values__print :: proc(values: []Value, w, h, d: int) {
        for z in 0..<d {
            fmt.printf("\n")
            for y in 0..<h {
                fmt.printf("\n")
                for x in 0..<w do fmt.printf(" %.1f", values[z * w * h + y * w + x])
            }
        }
    }

    values__print_symbols :: proc(values: []Value, w, h, d: int) {
        for z in 0..<d {
            fmt.printf("\n")
            for y in 0..<h {
                fmt.printf("\n")
                for x in 0..<w do fmt.printf("%s", values[z * w * h + y * w + x] > 0 ? "X" : ".")
            }
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Data_Block -- one Data per rec for one block (time step).

    Data_Block_Flag :: enum {
        Reset_Recs,
    }

    Data_Block_Flags :: bit_set[Data_Block_Flag]

    Data_Block :: struct {
        block_id: Block_Id,
        datum: []Data, // one per rec, indexed by rec_id
        flags: Data_Block_Flags,
    }

///////////////////////////////////////////////////////////////////////////////
// Data_Seq -- sequence of blocks pushed into a wave before it is processed.
//
// Block datum storage comes from a Dynamic_Arena that is reset (not freed) on data_seq__reset,
// so repeated push/process cycles do not churn the backing allocator.

    DATA_SEQ__ARENA_BLOCK_SIZE :: 4096

    Data_Seq :: struct {
        allocator: runtime.Allocator,
        arena: mem.Dynamic_Arena,

        wave_id: int,
        recs_size: int,

        blocks: [dynamic]Data_Block,
        next_block_ix: int,             // never reset, block ids stay unique for the wave
        start_block_on_next_data: bool,
        read_pos: int,                  // -1 means "start from the first block"
    }

    data_seq__init :: proc(self: ^Data_Seq, wave_id: int, recs_size: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        when VALIDATIONS do assert(recs_size > 0)

        self.allocator = allocator
        mem.dynamic_arena_init(&self.arena, allocator, allocator, DATA_SEQ__ARENA_BLOCK_SIZE)

        self.wave_id = wave_id
        self.recs_size = recs_size
        self.blocks = make([dynamic]Data_Block, 0, 4, allocator) or_return
        self.next_block_ix = 0
        self.start_block_on_next_data = false
        self.read_pos = -1

        return nil
    }

    data_seq__terminate :: proc(self: ^Data_Seq) -> runtime.Allocator_Error {
        err := delete(self.blocks)
        self.blocks = nil
        mem.dynamic_arena_destroy(&self.arena)
        return err
    }

    data_seq__reset :: proc(self: ^Data_Seq) {
        clear(&self.blocks)
        mem.dynamic_arena_reset(&self.arena)
        self.start_block_on_next_data = false
        self.read_pos = -1
    }

    data_seq__blocks_count :: #force_inline proc "contextless" (self: ^Data_Seq) -> int {
        return len(self.blocks)
    }

    data_seq__is_empty :: #force_inline proc "contextless" (self: ^Data_Seq) -> bool {
        return len(self.blocks) == 0
    }

    data_seq__block_begin :: proc "contextless" (self: ^Data_Seq) {
        self.start_block_on_next_data = true
    }

    data_seq__block_end :: proc "contextless" (self: ^Data_Seq) {
        self.start_block_on_next_data = true
    }

    @(private)
    data_seq__block_add :: proc(self: ^Data_Seq) -> (block: ^Data_Block, err: runtime.Allocator_Error) {
        block_id := Block_Id{ self.wave_id, self.next_block_ix }
        self.next_block_ix += 1

        datum := make([]Data, self.recs_size, mem.dynamic_arena_allocator(&self.arena)) or_return
        for &data in datum {
            data = data__default()
            data.block_id = block_id
        }

        append(&self.blocks, Data_Block{ block_id = block_id, datum = datum }) or_return

        return &self.blocks[len(self.blocks) - 1], nil
    }

    data_seq__get_last_data :: proc(self: ^Data_Seq, rec_id: int) -> ^Data {
        if len(self.blocks) == 0 do return nil
        return &self.blocks[len(self.blocks) - 1].datum[rec_id]
    }

    data_seq__get_last_values :: proc(self: ^Data_Seq, rec_id: int) -> []Value {
        data := data_seq__get_last_data(self, rec_id)
        if data == nil do return nil
        return data.values
    }

    // Values are borrowed and must stay alive until the wave processes the sequence.
    data_seq__push :: proc(self: ^Data_Seq, rec_id: int, values: []Value, w, h, d: int, view: Rec_View) -> runtime.Allocator_Error {
        when VALIDATIONS do assert(rec_id < self.recs_size)

        if self.start_block_on_next_data {
            data_seq__block_add(self) or_return
            self.start_block_on_next_data = false
        }

        if len(self.blocks) == 0 do data_seq__block_add(self) or_return

        data := data_seq__get_last_data(self, rec_id)
        if data.values != nil {
            data_seq__block_add(self) or_return
            data = data_seq__get_last_data(self, rec_id)
        }

        data__set(data, data.block_id, rec_id, w, h, d, values, view, data.flags)

        return nil
    }

    // Returns the next block to process, or nil (and rewinds) when the sequence is exhausted.
    // The first block is flagged Reset_Recs.
    data_seq__next_block :: proc(self: ^Data_Seq) -> ^Data_Block {
        if self.read_pos < 0 {
            if len(self.blocks) == 0 do return nil

            self.read_pos = 0
            block := &self.blocks[0]
            block.flags += { .Reset_Recs }
            return block
        }

        self.read_pos += 1
        if self.read_pos >= len(self.blocks) {
            self.read_pos = -1
            return nil
        }

        return &self.blocks[self.read_pos]
    }
