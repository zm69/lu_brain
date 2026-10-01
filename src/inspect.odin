/*
    2026 (c) Zaya, https://github.com/zm69

    Read-only inspection of the memory: which cells a match fired, which labels a cell belongs to,
    which cells a label owns. This is what makes decisions explainable through shared patterns.
*/
package lu_brain

// Base
    import "base:runtime"

///////////////////////////////////////////////////////////////////////////////
// Layers

    // Plain N layer at `level` of the rec's area (1 = first layer above the rec base), nil if none.
    brain__level_layer :: proc(self: ^Brain, rec: ^Rec, level: int) -> ^S_Layer_N {
        if !self.is_built do return nil

        for layer in s__get_rec_area(&self.s, rec.id).layers {
            if n, ok := layer.(^S_Layer_N); ok && n.level == level do return n
        }
        return nil
    }

    // Returns nil for an address that is not an N cell.
    brain__get_n_cell :: proc(self: ^Brain, addr: N_Addr) -> ^N_Cell {
        located, ok := s__find_n_cell(&self.s, addr).(N_Located_N)
        if !ok do return nil
        return located.n_cell
    }

    // False for cells removed by a Delete_Wave (they keep their slot but lose their children).
    brain__is_cell_live :: proc(self: ^Brain, addr: N_Addr) -> bool {
        n_cell := brain__get_n_cell(self, addr)
        return n_cell != nil && !n_cell__is_blank(n_cell)
    }

///////////////////////////////////////////////////////////////////////////////
// Labels

    // Labels linked to a cell.
    brain__cell_labels :: proc(self: ^Brain, addr: N_Addr, allocator := context.allocator) -> (labels: [dynamic]int, err: runtime.Allocator_Error) {
        labels = make([dynamic]int, allocator) or_return

        n_cell := brain__get_n_cell(self, addr)
        if n_cell == nil do return

        link_mem := &self.la_column.la_link_mem
        for link := la_link_mem__get(link_mem, n_cell.labels); link != nil; link = la_link_mem__get(link_mem, link.next) {
            append(&labels, link.la_ix) or_return
        }
        return
    }

    // Number of labels linked to a cell, without allocating.
    brain__cell_labels_count :: proc(self: ^Brain, n_cell: ^N_Cell) -> int {
        return int(n_cell.labels_count)
    }

    // Live cells linked to a label.
    brain__label_cells :: proc(self: ^Brain, label: int, allocator := context.allocator) -> (cells: [dynamic]N_Addr, err: runtime.Allocator_Error) {
        cells = make([dynamic]N_Addr, allocator) or_return

        la_cell := la_column__get_la_cell(&self.la_column, label)
        if la_cell == nil do return

        link_mem := &self.la_column.n_link_mem
        for link := n_link_mem__get(link_mem, la_cell.children); link != nil; link = n_link_mem__get(link_mem, link.next) {
            if brain__is_cell_live(self, link.n_addr) do append(&cells, link.n_addr) or_return
        }
        return
    }

///////////////////////////////////////////////////////////////////////////////
// Match

    Fired_Cell :: struct {
        addr: N_Addr,
        x: int,
        y: int,
        sig: Value, // fire sig, 0..1
    }

    // Weight the last match applied to a cell's signal to its labels (Config.w_match_idf_power /
    // w_match_purity_power); 1 when pattern weights are off. Link weights come on top, see learn.odin.
    match_wave__pattern_weight :: proc(self: ^Match_Wave, addr: N_Addr) -> Value {
        n_cell := brain__get_n_cell(self.brain, addr)
        if n_cell == nil do return 0
        return w_match_processor__pattern_weight(&self.processor, n_cell)
    }

    // Cells of the rec layer at `level` that fired in the last match of this wave.
    match_wave__fired_cells :: proc(self: ^Match_Wave, rec: ^Rec, level: int, allocator := context.allocator) -> (fired: [dynamic]Fired_Cell, err: Error) {
        layer := brain__level_layer(self.brain, rec, level)
        if layer == nil do return nil, API_Error.Invalid_Argument

        fired = make([dynamic]Fired_Cell, allocator) or_return

        processor := &self.processor

        for &column in layer.s_table.columns {
            for &n_cell in column.cells {
                match_cell := w_match_cell_mem__get_owned(&self.match_cell_mem, n_cell.w_match_cells[self.wave_ix], n_cell.addr)
                if match_cell == nil || !match_cell.fired || match_cell.block_id != processor.block_id do continue

                append(&fired, Fired_Cell{
                    addr = n_cell.addr,
                    x = column.x,
                    y = column.y,
                    sig = match_cell.sig / n_cell.default_sig,
                }) or_return
            }
        }

        return
    }
