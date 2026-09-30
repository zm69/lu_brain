/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"

///////////////////////////////////////////////////////////////////////////////
// S_Layer -- one layer of an S_Area. Three kinds:
//
//     S_Layer_Comp  -- one component (z) of a rec, holds VP cells (bottom of the net)
//     S_Layer_Rec   -- rec base layer, an N layer that also collects data from its comp layers
//     S_Layer_N     -- plain N layer
//
// Layers are allocated individually, so pointers to them are stable. `p` is the parent
// (the layer above), `c` are the children (layers below).

    S_Layer :: union {
        ^S_Layer_Comp,
        ^S_Layer_N,
        ^S_Layer_Rec,
    }

    S_Layer_Type :: enum {
        Comp,
        Rec,
        Layer,
    }

    S_Layer_Base :: struct {
        allocator: runtime.Allocator,

        type: S_Layer_Type,
        tag: Area_Tag,
        layer_ix: int,
        area_ix: int,

        p: S_Layer,
        c: [dynamic]S_Layer,
    }

    s_layer_base__init :: proc(self: ^S_Layer_Base, type: S_Layer_Type, tag: Area_Tag, layer_ix, area_ix: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.allocator = allocator
        self.type = type
        self.tag = tag
        self.layer_ix = layer_ix
        self.area_ix = area_ix
        self.p = nil
        self.c = make([dynamic]S_Layer, 0, 1, allocator) or_return
        return nil
    }

    s_layer_base__terminate :: proc(self: ^S_Layer_Base) -> runtime.Allocator_Error {
        err := delete(self.c)
        self.c = nil
        self.p = nil
        return err
    }

    s_layer_base__print_basic_info :: proc(self: ^S_Layer_Base) {
        fmt.printf("%v:%v A=%v, L=%v", self.tag, self.type, self.area_ix, self.layer_ix)
    }

    s_layer__base :: proc "contextless" (layer: S_Layer) -> ^S_Layer_Base {
        switch l in layer {
            case ^S_Layer_Comp: return &l.base
            case ^S_Layer_N: return &l.base
            case ^S_Layer_Rec: return &l.base
        }
        return nil
    }

    // Returns the N layer part of a plain or rec layer, nil for a comp layer.
    s_layer__as_n :: proc "contextless" (layer: S_Layer) -> ^S_Layer_N {
        switch l in layer {
            case ^S_Layer_Comp: return nil
            case ^S_Layer_N: return l
            case ^S_Layer_Rec: return &l.layer
        }
        return nil
    }

    s_layer__connect :: proc(p: S_Layer, c: S_Layer) -> runtime.Allocator_Error {
        s_layer__base(c).p = p
        _, err := append(&s_layer__base(p).c, c)
        return err
    }

    s_layer__destroy :: proc(layer: S_Layer) -> Error {
        switch l in layer {
            case ^S_Layer_Comp:
                allocator := l.allocator
                s_layer_comp__terminate(l) or_return
                free(l, allocator) or_return
            case ^S_Layer_N:
                allocator := l.allocator
                s_layer_n__terminate(l) or_return
                free(l, allocator) or_return
            case ^S_Layer_Rec:
                allocator := l.allocator
                s_layer_rec__terminate(l) or_return
                free(l, allocator) or_return
        }
        return nil
    }

    s_layer__get_net_stats :: proc(layer: S_Layer) -> Net_Stats {
        n := s_layer__as_n(layer)
        if n == nil do return {} // TODO: VP cells are not counted yet
        return s_table__get_net_stats(&n.s_table)
    }

    s_layer__find_n_cell :: proc(layer: S_Layer, addr: N_Addr) -> N_Located_Cell {
        switch l in layer {
            case ^S_Layer_Comp:
                s_column_comp := s_table_comp__get_column_by_ix(&l.p_view.n_comp_table, int(addr.column_ix))
                return N_Located_VP{
                    n_cell_vp = s_column_comp__find_n_cell(s_column_comp, addr),
                    s_column_comp = s_column_comp,
                    s_layer_comp = l,
                }
            case ^S_Layer_N:
                s_column := s_table__get_column_by_ix(&l.s_table, int(addr.column_ix))
                return N_Located_N{ n_cell = s_column__find_n_cell(s_column, addr), s_column = s_column }
            case ^S_Layer_Rec:
                s_column := s_table__get_column_by_ix(&l.s_table, int(addr.column_ix))
                return N_Located_N{ n_cell = s_column__find_n_cell(s_column, addr), s_column = s_column }
        }
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// S_View_P -- "p" view of a component: saves the change of a value between two blocks.
//
// TODO: the C version also had an S_View_V ("value" view) whose save step was never
// implemented. It is not ported.

    S_View_P :: struct {
        comp_calc: Comp_Calc,

        n_comp_table: S_Table_Comp,
        w_save_tables: []W_Table_P,
        w_match_tables: []W_Table_P,
        w_restore_data: []Data,
    }

    s_view_p__init :: proc(
        self: ^S_View_P,
        config: ^Config,
        w, h: int,
        min, max: Value,
        cells_size, layer_ix, area_ix: int,
        allocator: runtime.Allocator,
    ) -> runtime.Allocator_Error {
        comp_calc__init(&self.comp_calc, min, max, cells_size, allocator) or_return
        s_table_comp__init(&self.n_comp_table, config, &self.comp_calc, w, h, cells_size, layer_ix, area_ix, allocator) or_return

        self.w_save_tables = make([]W_Table_P, config.w_save_waves_size, allocator) or_return
        for &t in self.w_save_tables do w_table_p__init(&t, w, h, allocator) or_return

        self.w_match_tables = make([]W_Table_P, config.w_match_waves_size, allocator) or_return
        for &t in self.w_match_tables do w_table_p__init(&t, w, h, allocator) or_return

        self.w_restore_data = make([]Data, config.w_restore_waves_size, allocator) or_return
        for &d in self.w_restore_data do data__init(&d, w, h, 1, allocator) or_return

        return nil
    }

    s_view_p__terminate :: proc(self: ^S_View_P, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        for &d in self.w_restore_data do data__terminate(&d, allocator) or_return
        delete(self.w_restore_data, allocator) or_return

        for &t in self.w_match_tables do w_table_p__terminate(&t, allocator) or_return
        delete(self.w_match_tables, allocator) or_return

        for &t in self.w_save_tables do w_table_p__terminate(&t, allocator) or_return
        delete(self.w_save_tables, allocator) or_return

        s_table_comp__terminate(&self.n_comp_table) or_return
        comp_calc__terminate(&self.comp_calc) or_return

        return nil
    }

    s_view_p__get_w_table :: proc(self: ^S_View_P, wave_ix: int, wave_type: Wave_Type) -> ^W_Table_P {
        #partial switch wave_type {
            case .Save: return &self.w_save_tables[wave_ix]
            case .Match: return &self.w_match_tables[wave_ix]
        }
        when VALIDATIONS do assert(false)
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// S_Layer_Comp

    S_Layer_Comp :: struct {
        using base: S_Layer_Base,

        p_view: S_View_P,
    }

    s_layer_comp__create :: proc(
        config: ^Config,
        frame: ^S_Layer_Rec,
        rc_config: ^Rec_Comp_Config,
        layer_ix, area_ix: int,
        allocator: runtime.Allocator,
    ) -> (self: ^S_Layer_Comp, err: Error) {
        self = new(S_Layer_Comp, allocator) or_return

        s_layer_base__init(&self.base, .Comp, .Comp, layer_ix, area_ix, allocator) or_return

        rec := frame.rec
        s_view_p__init(&self.p_view, config, rec.width, rec.height, rc_config.v_min, rc_config.v_max, rc_config.p_neu_size, layer_ix, area_ix, allocator) or_return

        return
    }

    s_layer_comp__terminate :: proc(self: ^S_Layer_Comp) -> Error {
        s_view_p__terminate(&self.p_view, self.allocator) or_return
        s_layer_base__terminate(&self.base) or_return
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// S_Layer_N

    S_Layer_N :: struct {
        using base: S_Layer_Base,

        s_table: S_Table,
        w_save_tables: []W_Table,
    }

    s_layer_n__init :: proc(
        self: ^S_Layer_N,
        config: ^Config,
        type: S_Layer_Type,
        tag: Area_Tag,
        layer_ix, area_ix: int,
        n_w, n_h, n_h_max: int,
        allocator: runtime.Allocator,
    ) -> Error {
        s_layer_base__init(&self.base, type, tag, layer_ix, area_ix, allocator) or_return

        s_table__init(&self.s_table, n_w, n_h, n_h_max, config, layer_ix, area_ix, &self.base, allocator) or_return

        self.w_save_tables = make([]W_Table, config.w_save_waves_size, allocator) or_return
        for &t in self.w_save_tables do w_table__init(&t, self, n_w, n_h, n_h_max, allocator) or_return

        return nil
    }

    s_layer_n__terminate :: proc(self: ^S_Layer_N) -> Error {
        for &t in self.w_save_tables do w_table__terminate(&t, self.allocator) or_return
        delete(self.w_save_tables, self.allocator) or_return

        s_table__terminate(&self.s_table) or_return
        s_layer_base__terminate(&self.base) or_return

        return nil
    }

    s_layer_n__create :: proc(
        config: ^Config,
        tag: Area_Tag,
        layer_ix, area_ix: int,
        n_w, n_h, n_h_max: int,
        allocator: runtime.Allocator,
    ) -> (self: ^S_Layer_N, err: Error) {
        self = new(S_Layer_N, allocator) or_return
        s_layer_n__init(self, config, .Layer, tag, layer_ix, area_ix, n_w, n_h, n_h_max, allocator) or_return
        return
    }

    s_layer_n__get_parent :: proc(self: ^S_Layer_N) -> ^S_Layer_N {
        return s_layer__as_n(self.p)
    }

    s_layer_n__expand :: proc(self: ^S_Layer_N) -> bool {
        return s_table__expand(&self.s_table)
    }

    s_layer_n__save :: proc(self: ^S_Layer_N, wave_ix: int, block_id: Block_Id, prev_w_table: ^W_Table) -> (curr_w_table: ^W_Table, err: Error) {
        curr_w_table = &self.w_save_tables[wave_ix]
        curr_s_table := &self.s_table

        w_table__prepare_for_wave(curr_w_table, block_id, wave_ix, curr_s_table)

        when DEEP_DEBUG {
            fmt.printf("\npw=(%v, %v), cw=(%v, %v)", prev_w_table.w, prev_w_table.h, curr_w_table.w, curr_w_table.h)
            w_table__print(prev_w_table)
            w_table__print(curr_w_table)
        }

        children_buf: [4]W_Child

        for y in 0..<curr_w_table.h {
            for x in 0..<curr_w_table.w {
                curr_w_cell := w_table__get_w_cell(curr_w_table, x, y)
                w_cell__reset(curr_w_cell)

                children := w_table__collect_children(prev_w_table, x, y, &children_buf)

                when DEEP_DEBUG do w_children__print_symbols(children)

                s_column := s_table__get_column(curr_s_table, x, y)
                cell_ix := s_column__find_or_create_parent(s_column, children, block_id, wave_ix) or_return

                w_cell__save(curr_w_cell, s_column, cell_ix)
            }
        }

        curr_w_table.any_fired = true

        return
    }

///////////////////////////////////////////////////////////////////////////////
// S_Layer_Rec

    S_Layer_Rec :: struct {
        using layer: S_Layer_N,

        rec: ^Rec,

        save_w_recs: []W_Rec,
        match_w_recs: []W_Rec,

        // w_match_tables are needed to start the match process, higher layers (S_Layer_N)
        // don't need them
        w_match_tables: []W_Table,

        children_buf: []^W_Cell_P, // rec.depth, scratch for finish
    }

    s_layer_rec__create :: proc(config: ^Config, rec: ^Rec, layer_ix, area_ix: int, allocator: runtime.Allocator) -> (self: ^S_Layer_Rec, err: Error) {
        self = new(S_Layer_Rec, allocator) or_return

        // fixed s_table: h_max == h
        s_layer_n__init(&self.layer, config, .Rec, .Rec, layer_ix, area_ix, rec.width, rec.height, rec.height, allocator) or_return

        self.rec = rec

        self.save_w_recs = make([]W_Rec, config.w_save_waves_size, allocator) or_return
        for &w_rec in self.save_w_recs do w_rec__reset(&w_rec)

        self.match_w_recs = make([]W_Rec, config.w_match_waves_size, allocator) or_return
        for &w_rec in self.match_w_recs do w_rec__reset(&w_rec)

        self.w_match_tables = make([]W_Table, config.w_match_waves_size, allocator) or_return
        for &t in self.w_match_tables do w_table__init(&t, &self.layer, rec.width, rec.height, rec.height, allocator) or_return

        self.children_buf = make([]^W_Cell_P, rec.depth, allocator) or_return

        return
    }

    s_layer_rec__terminate :: proc(self: ^S_Layer_Rec) -> Error {
        allocator := self.allocator

        delete(self.children_buf, allocator) or_return

        for &t in self.w_match_tables do w_table__terminate(&t, allocator) or_return
        delete(self.w_match_tables, allocator) or_return

        delete(self.match_w_recs, allocator) or_return
        delete(self.save_w_recs, allocator) or_return

        s_layer_n__terminate(&self.layer) or_return

        return nil
    }

    s_layer_rec__get_w_rec :: proc(self: ^S_Layer_Rec, wave_ix: int, wave_type: Wave_Type) -> ^W_Rec {
        #partial switch wave_type {
            case .Save: return &self.save_w_recs[wave_ix]
            case .Match: return &self.match_w_recs[wave_ix]
        }
        when VALIDATIONS do assert(false)
        return nil
    }

    s_layer_rec__get_w_table :: proc(self: ^S_Layer_Rec, wave_ix: int, wave_type: Wave_Type) -> ^W_Table {
        #partial switch wave_type {
            case .Save: return &self.w_save_tables[wave_ix]
            case .Match: return &self.w_match_tables[wave_ix]
        }
        when VALIDATIONS do assert(false)
        return nil
    }

    s_layer_rec__get_layer_comp :: #force_inline proc(self: ^S_Layer_Rec, ix: int) -> ^S_Layer_Comp {
        return self.c[ix].(^S_Layer_Comp)
    }

    s_layer_rec__reset_all_w_table_p :: proc(self: ^S_Layer_Rec, wave_ix: int, wave_type: Wave_Type) {
        for z in 0..<self.rec.depth {
            comp := s_layer_rec__get_layer_comp(self, z)
            w_table_p__reset(s_view_p__get_w_table(&comp.p_view, wave_ix, wave_type))
        }
    }

    // Collects data values into comp w_cell_ps, using the rec view stored in w_rec.
    s_layer_rec__collect :: proc(self: ^S_Layer_Rec, w_rec: ^W_Rec, data: ^Data, wave_ix: int, wave_type: Wave_Type) {
        rec := self.rec
        view := &w_rec.view

        for src_y in view.src_start_y..<view.src_end_y {
            dest_y := view.dest_start_y + (src_y - view.src_start_y)
            if dest_y < 0 || dest_y >= rec.height do continue

            for src_x in view.src_start_x..<view.src_end_x {
                dest_x := view.dest_start_x + (src_x - view.src_start_x)
                if dest_x < 0 || dest_x >= rec.width do continue

                for src_z in view.src_start_z..<view.src_end_z {
                    comp := s_layer_rec__get_layer_comp(self, src_z)
                    w_table_p := s_view_p__get_w_table(&comp.p_view, wave_ix, wave_type)
                    w_cell_p := w_table_p__get_w_cell(w_table_p, dest_x, dest_y)

                    w_cell_p__collect_and_shift(w_cell_p, data__get_value(data, src_x, src_y, src_z))
                }
            }
        }
    }

    // Saves every collected w_cell_p as a VP cell, then either links rec n_cells to them (save)
    // or fires their parents (match).
    s_layer_rec__finish :: proc(
        self: ^S_Layer_Rec,
        curr_w_table: ^W_Table,
        data: ^Data,
        wave_ix: int,
        wave_type: Wave_Type,
        processor: ^W_Match_Processor,
    ) -> Error {
        d := self.rec.depth
        children := self.children_buf

        when DEEP_DEBUG do fmt.printf("\nFINISH_PROCESS w_cell_p table and n_cell table:")

        for y in 0..<curr_w_table.h {
            when DEEP_DEBUG do fmt.printf("\n\t")

            for x in 0..<curr_w_table.w {
                w_cell := w_table__get_w_cell(curr_w_table, x, y)
                w_cell__reset(w_cell)

                for z in 0..<d {
                    comp := s_layer_rec__get_layer_comp(self, z)
                    s_view_p := &comp.p_view
                    w_table_p := s_view_p__get_w_table(s_view_p, wave_ix, wave_type)
                    w_cell_p := w_table_p__get_w_cell(w_table_p, x, y)

                    children[z] = w_cell_p__save(w_cell_p, x, y, &s_view_p.comp_calc, &s_view_p.n_comp_table)

                    when DEEP_DEBUG do fmt.printf("%v ", w_cell_p.n_cell_vp.addr.cell_ix)

                    if wave_type == .Match {
                        w_match_processor__fire_vp_parents_with_sig(processor, w_cell_p.n_cell_vp, w_cell_p.s_column_comp, 1.0) or_return
                    }
                }

                if wave_type == .Save {
                    s_column := s_table__get_column(&self.s_table, x, y)
                    cell_ix := s_column__find_or_create_parent_for_vp_children(s_column, children, data.block_id, wave_ix) or_return
                    w_cell__save(w_cell, s_column, cell_ix)
                }
            }
        }

        return nil
    }

    s_layer_rec__process_data :: proc(
        self: ^S_Layer_Rec,
        wave_ix: int,
        wave_type: Wave_Type,
        data: ^Data,
        w_rec: ^W_Rec,
        processor: ^W_Match_Processor,
    ) -> (curr_w_table: ^W_Table, err: Error) {
        if .Reset_Rec in data.flags do w_rec__reset(w_rec)

        w_rec__update(w_rec, data.block_id, wave_ix, data.view)

        when DEEP_DEBUG {
            fmt.printf(
                "\nREC: w_state = %v, wave_id = %v, wave_ix = %v, block_ix = %v, view dest pos=[%v, %v]",
                w_rec.state, w_rec.block_id.wave_id, w_rec.wave_ix, w_rec.block_id.block_ix,
                w_rec.view.dest_start_x, w_rec.view.dest_start_y,
            )
            data__print_symbols(data)
        }

        curr_w_table = s_layer_rec__get_w_table(self, wave_ix, wave_type)
        w_table__prepare_for_wave(curr_w_table, data.block_id, wave_ix, &self.s_table)

        switch w_rec.state {
            case .Collect:
                s_layer_rec__reset_all_w_table_p(self, wave_ix, wave_type)
                s_layer_rec__collect(self, w_rec, data, wave_ix, wave_type)

            case .Collect_And_Finish:
                s_layer_rec__collect(self, w_rec, data, wave_ix, wave_type)
                s_layer_rec__finish(self, curr_w_table, data, wave_ix, wave_type, processor) or_return
                curr_w_table.any_fired = true
        }

        return
    }

    s_layer_rec__save :: proc(self: ^S_Layer_Rec, wave_ix: int, data: ^Data) -> (^W_Table, Error) {
        return s_layer_rec__process_data(self, wave_ix, .Save, data, &self.save_w_recs[wave_ix], nil)
    }

    s_layer_rec__match :: proc(self: ^S_Layer_Rec, wave_ix: int, data: ^Data, processor: ^W_Match_Processor) -> (W_Rec_State, Error) {
        processor.block_id = data.block_id
        processor.wave_ix = wave_ix

        w_rec := &self.match_w_recs[wave_ix]
        _, err := s_layer_rec__process_data(self, wave_ix, .Match, data, w_rec, processor)

        return w_rec.state, err
    }
