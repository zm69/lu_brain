/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"

///////////////////////////////////////////////////////////////////////////////
// Defines

    // Breakpoints used on save to decide if an existing parent matches well enough.
    S_COLUMN__VP_PARENT_BREAKPOINT :: 0.76
    S_COLUMN__PARENT_BREAKPOINT :: 0.8

    S_COLUMN__CELLS_MAX :: 1 << N_CELL_IX__BITS

///////////////////////////////////////////////////////////////////////////////
// S_Column_Comp -- fixed column of VP cells, one per discrete value step.

    S_Column_Comp :: struct {
        column_ix: int,
        cells: []N_Cell_VP,
        link_mem: N_Link_Mem,
    }

    s_column_comp__init :: proc(
        self: ^S_Column_Comp,
        cells_size, x, y, area_ix, layer_ix, column_ix: int,
        comp_calc: ^Comp_Calc,
        config: ^Config,
        allocator: runtime.Allocator,
    ) -> runtime.Allocator_Error {
        when VALIDATIONS do assert(cells_size > 0)

        self.column_ix = column_ix
        self.cells = make([]N_Cell_VP, cells_size, allocator) or_return

        for &cell, i in self.cells {
            cell = N_Cell_VP{
                addr = n_addr__make(i, column_ix, layer_ix, area_ix),
                value = comp_calc.steps[i],
                x = x,
                y = y,
                z = i,
            }
        }

        n_link_mem__init(&self.link_mem, config.n_link_mem_size, allocator) or_return

        return nil
    }

    s_column_comp__terminate :: proc(self: ^S_Column_Comp, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        n_link_mem__terminate(&self.link_mem) or_return
        delete(self.cells, allocator) or_return
        self.cells = nil
        return nil
    }

    s_column_comp__find_n_cell :: proc(self: ^S_Column_Comp, addr: N_Addr) -> ^N_Cell_VP {
        n_cell_vp := &self.cells[addr.cell_ix]
        when VALIDATIONS do assert(n_addr__is_eq(n_cell_vp.addr, addr))
        return n_cell_vp
    }

///////////////////////////////////////////////////////////////////////////////
// S_Table_Comp

    S_Table_Comp :: struct {
        allocator: runtime.Allocator,
        w: int,
        h: int,
        d: int,
        wh: int,
        columns: []S_Column_Comp,
    }

    s_table_comp__init :: proc(
        self: ^S_Table_Comp,
        config: ^Config,
        comp_calc: ^Comp_Calc,
        w, h, d, layer_ix, area_ix: int,
        allocator: runtime.Allocator,
    ) -> runtime.Allocator_Error {
        when VALIDATIONS {
            assert(w > 0 && h > 0 && d > 0)
            assert(comp_calc.cells_size == d)
            assert(area_ix >= N_AREA__SPECIAL_AREA_SKIP)
        }

        self.allocator = allocator
        self.w = w
        self.h = h
        self.d = d
        self.wh = w * h

        self.columns = make([]S_Column_Comp, self.wh, allocator) or_return

        column_ix := 0
        for y in 0..<h {
            for x in 0..<w {
                s_column_comp__init(&self.columns[column_ix], d, x, y, area_ix, layer_ix, column_ix, comp_calc, config, allocator) or_return
                column_ix += 1
            }
        }

        return nil
    }

    s_table_comp__terminate :: proc(self: ^S_Table_Comp) -> runtime.Allocator_Error {
        for &column in self.columns do s_column_comp__terminate(&column, self.allocator) or_return
        delete(self.columns, self.allocator) or_return
        self.columns = nil
        return nil
    }

    s_table_comp__get_column :: #force_inline proc(self: ^S_Table_Comp, x, y: int) -> ^S_Column_Comp {
        return &self.columns[y * self.w + x]
    }

    s_table_comp__get_column_by_ix :: #force_inline proc(self: ^S_Table_Comp, column_ix: int) -> ^S_Column_Comp {
        return &self.columns[column_ix]
    }

///////////////////////////////////////////////////////////////////////////////
// S_Column -- column of n_cells at one (x, y) of an S_Table. Grows on demand.

    S_Column :: struct {
        s_table: ^S_Table,

        col_addr: N_Addr,  // cell_ix is 0

        cells: [dynamic]N_Cell,
        free_count: int,

        link_mem: N_Link_Mem,

        // Position, mostly for debugging
        x: int,
        y: int,
    }

    s_column__init :: proc(
        self: ^S_Column,
        s_table: ^S_Table,
        cells_size, area_ix, layer_ix, column_ix: int,
        config: ^Config,
        x, y: int,
        allocator: runtime.Allocator,
    ) -> runtime.Allocator_Error {
        when VALIDATIONS do assert(cells_size > 1)

        self.s_table = s_table
        self.x = x
        self.y = y
        self.free_count = 0
        self.col_addr = n_addr__make(0, column_ix, layer_ix, area_ix)

        self.cells = make([dynamic]N_Cell, 0, cells_size, allocator) or_return

        n_link_mem__init(&self.link_mem, config.n_link_mem_size, allocator) or_return

        return nil
    }

    s_column__terminate :: proc(self: ^S_Column) -> runtime.Allocator_Error {
        n_link_mem__terminate(&self.link_mem) or_return
        delete(self.cells) or_return
        self.cells = nil
        return nil
    }

    s_column__get_cell :: #force_inline proc(self: ^S_Column, cell_ix: int) -> ^N_Cell {
        return &self.cells[cell_ix]
    }

    s_column__column_ix :: #force_inline proc(self: ^S_Column) -> int {
        return int(self.col_addr.column_ix)
    }

    s_column__n_cell_count :: #force_inline proc(self: ^S_Column) -> int {
        return len(self.cells) - self.free_count
    }

    s_column__n_cell_size :: #force_inline proc(self: ^S_Column) -> int {
        return cap(self.cells)
    }

    // Allocates a new n_cell. Invalidates ^N_Cell pointers into this column.
    s_column__alloc_n_cell :: proc(self: ^S_Column) -> (cell_ix: int, err: Error) {
        cell_ix = len(self.cells)
        if cell_ix >= S_COLUMN__CELLS_MAX do return -1, API_Error.Column_Is_Full

        append(&self.cells, N_Cell{}) or_return
        n_cell__init(
            &self.cells[cell_ix],
            cell_ix,
            int(self.col_addr.column_ix),
            int(self.col_addr.layer_ix),
            int(self.col_addr.area_ix),
        )

        return cell_ix, nil
    }

    s_column__free_n_cell :: proc(self: ^S_Column, n_cell: ^N_Cell) {
        // TODO: implement indexes to reuse n_cell memory. For now, just count.
        self.free_count += 1
    }

    s_column__find_n_cell :: proc(self: ^S_Column, addr: N_Addr) -> ^N_Cell {
        n_cell := &self.cells[addr.cell_ix]
        when VALIDATIONS do assert(n_addr__is_eq(n_cell.addr, addr))
        return n_cell
    }

    // self is the parent column of the VP child.
    @(private="file")
    s_column__find_matching_parent_vp :: proc(
        self: ^S_Column,
        child: ^W_Cell_P,
        block_id: Block_Id,
        wave_ix: int,
        out_save_cell: ^^W_Save_Cell,
        out_cell_ix: ^int,
    ) {
        when VALIDATIONS do assert(child.n_cell_vp != nil && child.s_column_comp != nil)

        link_mem := &child.s_column_comp.link_mem

        for link := n_link_mem__get(link_mem, child.n_cell_vp.parents); link != nil; link = n_link_mem__get(link_mem, link.next) {
            when VALIDATIONS do assert(link.n_addr.column_ix == self.col_addr.column_ix)

            parent := &self.cells[link.n_addr.cell_ix]
            save_cell := &parent.w_save_cells[wave_ix]

            w_save_cell__add_sig(save_cell, block_id, 1.0)

            if out_save_cell^ == nil || save_cell.sig > out_save_cell^.sig {
                out_save_cell^ = save_cell
                out_cell_ix^ = int(link.n_addr.cell_ix)
            }
        }
    }

    s_column__find_or_create_parent_for_vp_children :: proc(
        self: ^S_Column,
        children: []^W_Cell_P,
        block_id: Block_Id,
        wave_ix: int,
    ) -> (cell_ix: int, err: Error) {
        when VALIDATIONS do assert(len(children) > 0)

        save_cell: ^W_Save_Cell = nil
        cell_ix = -1

        for child in children do s_column__find_matching_parent_vp(self, child, block_id, wave_ix, &save_cell, &cell_ix)

        if save_cell == nil || !w_save_cell__is_sig_over_breakpoint(save_cell, &self.cells[cell_ix], S_COLUMN__VP_PARENT_BREAKPOINT) {
            cell_ix = s_column__alloc_n_cell(self) or_return
            n_cell__vp_save(&self.cells[cell_ix], &self.link_mem, children) or_return
        }

        return
    }

    // self is the parent column of the child.
    @(private="file")
    s_column__find_matching_parent :: proc(
        self: ^S_Column,
        child: ^W_Child,
        block_id: Block_Id,
        wave_ix: int,
        out_save_cell: ^^W_Save_Cell,
        out_cell_ix: ^int,
    ) {
        when VALIDATIONS do assert(child.w_cell != nil && w_cell__is_set(child.w_cell))

        child_n_cell := w_cell__n_cell(child.w_cell)
        link_mem := &child.w_cell.s_column.link_mem

        child_save_cell := &child_n_cell.w_save_cells[wave_ix]
        sig := w_save_cell__calc_fire_sig(child_save_cell, child_n_cell.default_sig)

        for link := n_link_mem__get(link_mem, child_n_cell.parents[child.child_pos]); link != nil; link = n_link_mem__get(link_mem, link.next) {
            when VALIDATIONS do assert(n_addr__is_space_eq(link.n_addr, self.col_addr))

            parent := &self.cells[link.n_addr.cell_ix]
            save_cell := &parent.w_save_cells[wave_ix]

            w_save_cell__add_sig(save_cell, block_id, sig)

            if out_save_cell^ == nil || save_cell.sig > out_save_cell^.sig {
                out_save_cell^ = save_cell
                out_cell_ix^ = int(link.n_addr.cell_ix)
            }
        }
    }

    s_column__find_or_create_parent :: proc(
        self: ^S_Column,
        children: []W_Child,
        block_id: Block_Id,
        wave_ix: int,
    ) -> (cell_ix: int, err: Error) {
        when VALIDATIONS do assert(len(children) > 0)

        save_cell: ^W_Save_Cell = nil
        cell_ix = -1

        for &child in children do s_column__find_matching_parent(self, &child, block_id, wave_ix, &save_cell, &cell_ix)

        if save_cell == nil || !w_save_cell__is_sig_over_breakpoint(save_cell, &self.cells[cell_ix], S_COLUMN__PARENT_BREAKPOINT) {
            cell_ix = s_column__alloc_n_cell(self) or_return
            n_cell__save(&self.cells[cell_ix], &self.link_mem, children) or_return
        }

        return
    }

    s_column__print_net_stats :: proc(self: ^S_Column) {
        fmt.printf(
            "[%v, %v] cells: %v/%v, links: %v/%v",
            self.x,
            self.y,
            s_column__n_cell_count(self),
            s_column__n_cell_size(self),
            n_link_mem__links_count(&self.link_mem),
            n_link_mem__links_size(&self.link_mem),
        )
    }

///////////////////////////////////////////////////////////////////////////////
// S_Table -- w * h_max columns of an N layer.

    S_Table :: struct {
        allocator: runtime.Allocator,
        layer: ^S_Layer_Base,

        w: int,
        h: int,
        h_max: int,

        columns: []S_Column,
    }

    s_table__init :: proc(
        self: ^S_Table,
        w, h, h_max: int,
        config: ^Config,
        layer_ix, area_ix: int,
        layer: ^S_Layer_Base,
        allocator: runtime.Allocator,
    ) -> runtime.Allocator_Error {
        when VALIDATIONS do assert(w > 0 && h > 0 && h_max >= h)

        self.allocator = allocator
        self.layer = layer
        self.w = w
        self.h = h
        self.h_max = h_max

        self.columns = make([]S_Column, w * h_max, allocator) or_return

        i := 0
        for y in 0..<h_max {
            for x in 0..<w {
                s_column__init(&self.columns[i], self, config.s_column_h, area_ix, layer_ix, i, config, x, y, allocator) or_return
                i += 1
            }
        }

        return nil
    }

    s_table__terminate :: proc(self: ^S_Table) -> runtime.Allocator_Error {
        for &column in self.columns do s_column__terminate(&column) or_return
        delete(self.columns, self.allocator) or_return
        self.columns = nil
        return nil
    }

    s_table__get_column_by_ix :: #force_inline proc(self: ^S_Table, column_ix: int) -> ^S_Column {
        return &self.columns[column_ix]
    }

    s_table__get_column :: #force_inline proc(self: ^S_Table, x, y: int) -> ^S_Column {
        return &self.columns[y * self.w + x]
    }

    s_table__get_n_cell :: proc(self: ^S_Table, n_addr: N_Addr) -> ^N_Cell {
        return s_column__get_cell(&self.columns[n_addr.column_ix], int(n_addr.cell_ix))
    }

    // Returns true if was able to expand.
    s_table__expand :: proc "contextless" (self: ^S_Table) -> bool {
        if self.h + 1 >= self.h_max do return false
        self.h += 1
        return true
    }

    s_table__get_net_stats :: proc(self: ^S_Table) -> (stats: Net_Stats) {
        for &column in self.columns {
            stats.cells_count += s_column__n_cell_count(&column)
            stats.cells_size += s_column__n_cell_size(&column)
            stats.links_count += n_link_mem__links_count(&column.link_mem)
            stats.links_size += n_link_mem__links_size(&column.link_mem)
        }
        return
    }
