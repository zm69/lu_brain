/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"

///////////////////////////////////////////////////////////////////////////////
// W_Rec -- per-wave state of a rec. Data is saved or matched from the difference of two
// consecutive blocks, so the first block only collects.

    W_Rec_State :: enum {
        Collect,
        Collect_And_Finish,
    }

    W_Rec :: struct {
        block_id: Block_Id,
        wave_ix: int,
        state: W_Rec_State,
        view: Rec_View,
    }

    w_rec__reset :: proc "contextless" (self: ^W_Rec) {
        self.block_id = BLOCK_ID__NOT_SET
        self.wave_ix = NOT_SET
        self.state = .Collect
    }

    w_rec__update :: proc(self: ^W_Rec, block_id: Block_Id, wave_ix: int, view: Rec_View) {
        when VALIDATIONS do assert(block_id__is_set(block_id))

        if self.block_id.wave_id != block_id.wave_id {
            self.state = .Collect
        } else if self.wave_ix != wave_ix {
            self.state = .Collect
        } else {
            diff := block_id.block_ix - self.block_id.block_ix
            when VALIDATIONS do assert(diff > 0)

            if diff > 1 {
                self.state = .Collect
            } else if self.state == .Collect {
                self.state = .Collect_And_Finish
            }
        }

        self.block_id = block_id
        self.wave_ix = wave_ix
        self.view = view
    }

///////////////////////////////////////////////////////////////////////////////
// W_Table_P -- wave table of one comp view.

    W_Table_P :: struct {
        w: int,
        h: int,
        cells: []W_Cell_P,
    }

    w_table_p__init :: proc(self: ^W_Table_P, w, h: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.w = w
        self.h = h
        self.cells = make([]W_Cell_P, w * h, allocator) or_return
        return nil
    }

    w_table_p__terminate :: proc(self: ^W_Table_P, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        err := delete(self.cells, allocator)
        self.cells = nil
        return err
    }

    w_table_p__reset :: proc(self: ^W_Table_P) {
        for &cell in self.cells do w_cell_p__reset(&cell)
    }

    w_table_p__get_w_cell :: #force_inline proc(self: ^W_Table_P, x, y: int) -> ^W_Cell_P {
        return &self.cells[y * self.w + x]
    }

    w_table_p__print :: proc(self: ^W_Table_P) {
        fmt.printf("\n-------- W_Table_P:")
        for y in 0..<self.h {
            fmt.printf("\n")
            for x in 0..<self.w do w_cell_p__print_symbol(w_table_p__get_w_cell(self, x, y))
        }
    }

///////////////////////////////////////////////////////////////////////////////
// W_Table -- wave table of one N layer.

    W_Table :: struct {
        s_layer: ^S_Layer_N,

        block_id: Block_Id,
        wave_ix: int,

        w: int,
        h: int,
        h_max: int,

        normal_children_size: int,

        cells: []W_Cell, // w * h_max

        any_fired: bool,

        s_table: ^S_Table,
    }

    w_table__init :: proc(self: ^W_Table, s_layer: ^S_Layer_N, w, h, h_max: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.s_layer = s_layer
        self.w = w
        self.h = h
        self.h_max = h_max
        self.normal_children_size = calc__expected_child_size(w, h)
        self.block_id = BLOCK_ID__NOT_SET
        self.wave_ix = NOT_SET
        self.any_fired = false
        self.s_table = nil

        self.cells = make([]W_Cell, w * h_max, allocator) or_return

        return nil
    }

    w_table__terminate :: proc(self: ^W_Table, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        err := delete(self.cells, allocator)
        self.cells = nil
        return err
    }

    // Returns nil for out of bounds.
    w_table__get_w_cell :: #force_inline proc "contextless" (self: ^W_Table, x, y: int) -> ^W_Cell {
        if x >= self.w || y >= self.h do return nil
        return &self.cells[y * self.w + x]
    }

    w_table__prepare_for_wave :: proc(self: ^W_Table, block_id: Block_Id, wave_ix: int, s_table: ^S_Table) {
        when VALIDATIONS do assert(self.block_id != block_id)

        self.block_id = block_id
        self.wave_ix = wave_ix
        self.s_table = s_table
        self.any_fired = false
    }

    w_table__any_fired :: proc "contextless" (self: ^W_Table, block_id: Block_Id) -> bool {
        if self == nil do return false
        if self.block_id != block_id do return false
        return self.any_fired
    }

    // Collects up to 4 children (TL, TR, BL, BR) of parent position (x, y) from this (child) table.
    w_table__collect_children :: proc(self: ^W_Table, x, y: int, children: ^[4]W_Child) -> []W_Child {
        count := 0

        collect :: #force_inline proc(self: ^W_Table, x, y: int, pos: W_Child_Pos, children: ^[4]W_Child, count: ^int) {
            w_cell := w_table__get_w_cell(self, x, y)
            if w_cell == nil do return

            when VALIDATIONS do assert(w_cell__is_set(w_cell))

            children[count^] = W_Child{ child_pos = pos, w_cell = w_cell }
            count^ += 1
        }

        collect(self, x, y, .TL, children, &count)
        collect(self, x + 1, y, .TR, children, &count)
        collect(self, x, y + 1, .BL, children, &count)
        collect(self, x + 1, y + 1, .BR, children, &count)

        when VALIDATIONS do assert(count == self.normal_children_size)

        return children[:count]
    }

    w_table__print :: proc(self: ^W_Table) {
        fmt.printf("\nW_TABLE from s_layer (")
        s_layer_base__print_basic_info(&self.s_layer.base)
        fmt.printf("):")

        for y in 0..<self.h_max {
            fmt.printf("\n   ")
            for x in 0..<self.w do w_cell__print_symbol(w_table__get_w_cell(self, x, y))
        }
    }
