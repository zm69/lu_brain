/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Core
    import "core:fmt"
    import "core:math"

///////////////////////////////////////////////////////////////////////////////
// Value

    Value :: f64

    VALUE__NON_SIGNF :: 0.0001

    value__eq_with_signif :: #force_inline proc "contextless" (a, b, signif: Value) -> bool {
        return math.abs(a - b) < signif
    }

    value__eq :: #force_inline proc "contextless" (a, b: Value) -> bool {
        return value__eq_with_signif(a, b, VALUE__NON_SIGNF)
    }

///////////////////////////////////////////////////////////////////////////////
// N_Addr -- packed address of a neuron cell: area / layer / column / cell.
//
// Area indexes start at N_AREA__SPECIAL_AREA_SKIP, so an N_Addr with value 0 is never a real
// cell and is used as "null".

    N_CELL_IX__BITS :: 16
    N_COLUMN_IX__BITS :: 24
    N_LAYER_IX__BITS :: 16
    N_AREA_IX__BITS :: 8

    N_Addr :: bit_field u64 {
        cell_ix: u64 | N_CELL_IX__BITS,
        column_ix: u64 | N_COLUMN_IX__BITS,
        layer_ix: u64 | N_LAYER_IX__BITS,
        area_ix: u64 | N_AREA_IX__BITS,
    }

    N_AREA__NULL :: 0
    N_AREA__INACTIVE :: 1
    N_AREA__SPECIAL_AREA_SKIP :: 2

    N_ADDR__NULL :: N_Addr{}

    n_addr__make :: #force_inline proc "contextless" (cell_ix, column_ix, layer_ix, area_ix: int) -> N_Addr {
        return N_Addr{
            cell_ix = u64(cell_ix),
            column_ix = u64(column_ix),
            layer_ix = u64(layer_ix),
            area_ix = u64(area_ix),
        }
    }

    n_addr__value :: #force_inline proc "contextless" (self: N_Addr) -> u64 {
        return transmute(u64) self
    }

    n_addr__is_blank :: #force_inline proc "contextless" (self: N_Addr) -> bool {
        return n_addr__value(self) == 0
    }

    n_addr__is_present :: #force_inline proc "contextless" (self: N_Addr) -> bool {
        return n_addr__value(self) != 0
    }

    n_addr__is_eq :: #force_inline proc "contextless" (a, b: N_Addr) -> bool {
        return n_addr__value(a) == n_addr__value(b)
    }

    // True if both addresses point into the same column (cell_ix is ignored).
    n_addr__is_space_eq :: #force_inline proc "contextless" (a, b: N_Addr) -> bool {
        a, b := a, b
        a.cell_ix = 0
        b.cell_ix = 0
        return n_addr__value(a) == n_addr__value(b)
    }

    n_addr__print :: proc(self: N_Addr) {
        fmt.printf("CELL: %v (AREA: %v LAYER: %v COLUMN: %v)", self.cell_ix, self.area_ix, self.layer_ix, self.column_ix)
    }

///////////////////////////////////////////////////////////////////////////////
// Block_Id -- identifies one block (time step) of one wave.

    NOT_SET :: max(int)

    Block_Id :: struct {
        wave_id: int,  // "id" because not sequential
        block_ix: int, // "ix" because sequential
    }

    BLOCK_ID__NOT_SET :: Block_Id{ NOT_SET, NOT_SET }

    block_id__is_set :: #force_inline proc "contextless" (self: Block_Id) -> bool {
        return self.wave_id != NOT_SET && self.block_ix != NOT_SET
    }

    block_id__increase_block_ix :: proc "contextless" (self: ^Block_Id) {
        if self.block_ix == NOT_SET do self.block_ix = 0
        else do self.block_ix += 1
    }

    block_id__print :: proc(self: Block_Id) {
        fmt.printf("[wave_id=%v, block_ix=%v]", self.wave_id, self.block_ix)
    }

///////////////////////////////////////////////////////////////////////////////
// Enums

    Area_Tag :: enum {
        Null,
        Comp,
        Rec,
        Frame,
        Seq,
        Event,
        Scene,
        Story,
        Other,
    }

    Wave_Type :: enum {
        Save,
        Match,
        Restore,
        Delete,
    }
