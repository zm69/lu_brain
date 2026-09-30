/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:math"

// Lu
    import lc "lu_core"

///////////////////////////////////////////////////////////////////////////////
// W_Cell -- wave cell of an N layer: points to the n_cell the wave landed on.
//
// Holds the column pointer plus a cell index, not an ^N_Cell: S_Column.cells grows (and moves)
// when a column is full, while S_Column itself never moves.

    W_Cell :: struct {
        s_column: ^S_Column,
        cell_ix: u32,
    }

    w_cell__reset :: #force_inline proc "contextless" (self: ^W_Cell) {
        self^ = {}
    }

    w_cell__is_set :: #force_inline proc "contextless" (self: ^W_Cell) -> bool {
        return self.s_column != nil
    }

    w_cell__save :: #force_inline proc "contextless" (self: ^W_Cell, s_column: ^S_Column, cell_ix: int) {
        self.s_column = s_column
        self.cell_ix = u32(cell_ix)
    }

    w_cell__n_cell :: #force_inline proc(self: ^W_Cell) -> ^N_Cell {
        when VALIDATIONS do assert(self.s_column != nil)
        return &self.s_column.cells[self.cell_ix]
    }

    w_cell__has_null_n_cell :: proc(self: ^W_Cell) -> bool {
        if self == nil || self.s_column == nil do return false
        return self.cell_ix == 0
    }

    w_cell__print_symbol :: proc(self: ^W_Cell) {
        if self == nil do fmt.printf("0 ")
        else if !w_cell__is_set(self) do fmt.printf("E ")
        else if w_cell__has_null_n_cell(self) do fmt.printf("N ")
        else do fmt.printf("X ")
    }

///////////////////////////////////////////////////////////////////////////////
// W_Cell_P -- wave cell of a comp ("p") view: collects values of two consecutive blocks and
// saves the difference as a VP cell.

    W_Cell_P :: struct {
        n_cell_vp: ^N_Cell_VP,
        s_column_comp: ^S_Column_Comp,

        sig: Value,

        p_1: Value,
        p_2: Value,
    }

    w_cell_p__reset :: #force_inline proc "contextless" (self: ^W_Cell_P) {
        self^ = {}
    }

    w_cell_p__has_null_n_cell :: proc "contextless" (self: ^W_Cell_P) -> bool {
        if self == nil || self.n_cell_vp == nil do return false
        return self.n_cell_vp.addr.cell_ix == 0
    }

    w_cell_p__calc_p :: #force_inline proc "contextless" (self: ^W_Cell_P) -> Value {
        return math.abs(self.p_2 - self.p_1)
    }

    w_cell_p__collect_and_shift :: #force_inline proc "contextless" (self: ^W_Cell_P, v: Value) {
        self.p_1 = self.p_2
        self.p_2 = v
    }

    w_cell_p__save :: proc(self: ^W_Cell_P, x, y: int, comp_calc: ^Comp_Calc, s_table: ^S_Table_Comp) -> ^W_Cell_P {
        p := w_cell_p__calc_p(self)

        z := 0 // points to the NULL cell by default
        self.sig = 0

        if p >= comp_calc.step {
            z = comp_calc__ix(comp_calc, comp_calc__norm(comp_calc, p))
            self.sig = 1.0
        }

        self.s_column_comp = s_table_comp__get_column(s_table, x, y)
        self.n_cell_vp = &self.s_column_comp.cells[z]

        return self
    }

    w_cell_p__print_symbol :: proc(self: ^W_Cell_P) {
        if self == nil || w_cell_p__has_null_n_cell(self) do fmt.printf(" ")
        else do fmt.printf("X")
    }

///////////////////////////////////////////////////////////////////////////////
// W_Child -- a child w_cell with its position relative to the parent.

    W_Child :: struct {
        child_pos: W_Child_Pos,
        w_cell: ^W_Cell,
    }

    w_children__print_symbols :: proc(children: []W_Child) {
        fmt.printf("\nCHILDREN(count=%v): ", len(children))
        for child in children do w_cell__print_symbol(child.w_cell)
    }

///////////////////////////////////////////////////////////////////////////////
// W_Save_Cell -- per-wave save state of an n_cell.

    W_Save_Cell :: struct {
        block_id: Block_Id,
        sig: Value,
    }

    w_save_cell__add_sig :: #force_inline proc "contextless" (self: ^W_Save_Cell, block_id: Block_Id, sig: Value) {
        if self.block_id != block_id {
            self.block_id = block_id
            self.sig = sig
            return
        }

        self.sig += sig
    }

    w_save_cell__is_sig_over_breakpoint :: #force_inline proc(self: ^W_Save_Cell, n_cell: ^N_Cell, breakpoint: Value) -> bool {
        when VALIDATIONS do assert(n_cell.default_sig - self.sig >= 0) // should never go below 0

        return self.sig >= n_cell.default_sig * breakpoint
    }

    w_save_cell__calc_fire_sig :: #force_inline proc "contextless" (self: ^W_Save_Cell, default_sig: Value) -> Value {
        return self.sig / default_sig
    }

///////////////////////////////////////////////////////////////////////////////
// W_Restore_Cell -- per-wave restore state of an n_cell.

    W_Restore_Cell :: struct {
        block_id: Block_Id,
    }

///////////////////////////////////////////////////////////////////////////////
// W_Match_Cell -- per-wave match state of an n_cell, allocated only for cells that received sig.

    W_Match_Ix :: distinct u32

    W_MATCH_IX__NULL :: W_Match_Ix(lc.POOL_NULL_IX)

    W_Match_Cell :: struct {
        n_addr: N_Addr, // owner, detects stale indexes left in n_cells by a terminated match wave
        block_id: Block_Id,
        sig: Value,
        fired: bool,
    }

    w_match_cell__init :: #force_inline proc "contextless" (self: ^W_Match_Cell, n_addr: N_Addr, block_id: Block_Id) {
        self^ = { n_addr = n_addr, block_id = block_id }
    }

    w_match_cell__is_sig_over_breakpoint :: #force_inline proc(self: ^W_Match_Cell, n_cell: ^N_Cell, breakpoint: Value) -> bool {
        if self.fired do return false

        when VALIDATIONS do assert(n_cell.default_sig - self.sig >= 0) // should never go below 0

        return self.sig >= n_cell.default_sig * breakpoint
    }

    W_Match_Cell_Mem :: lc.Pool(W_Match_Cell)

    w_match_cell_mem__init :: proc(self: ^W_Match_Cell_Mem, size: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        return lc.pool__init(self, size, true, allocator)
    }

    w_match_cell_mem__terminate :: proc(self: ^W_Match_Cell_Mem) -> runtime.Allocator_Error {
        return lc.pool__terminate(self)
    }

    w_match_cell_mem__alloc :: #force_inline proc(self: ^W_Match_Cell_Mem) -> (W_Match_Ix, runtime.Allocator_Error) {
        ix, err := lc.pool__alloc(self)
        return W_Match_Ix(ix), err
    }

    // Returns nil for W_MATCH_IX__NULL.
    w_match_cell_mem__get :: #force_inline proc(self: ^W_Match_Cell_Mem, ix: W_Match_Ix) -> ^W_Match_Cell {
        return lc.pool__get(self, u32(ix))
    }

    // Returns the match cell owned by n_addr, or nil if ix is null, out of range or owned by another cell.
    w_match_cell_mem__get_owned :: #force_inline proc(self: ^W_Match_Cell_Mem, ix: W_Match_Ix, n_addr: N_Addr) -> ^W_Match_Cell {
        if ix == W_MATCH_IX__NULL || int(ix) >= len(self.items) do return nil
        cell := &self.items[ix]
        if !n_addr__is_eq(cell.n_addr, n_addr) do return nil
        return cell
    }
