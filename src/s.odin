/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"

///////////////////////////////////////////////////////////////////////////////
// S_Area -- a group of layers with the same tag.

    S_Area :: struct {
        tag: Area_Tag,
        area_ix: int,
        layers: [dynamic]S_Layer,
    }

    s_area__get_layer :: #force_inline proc(self: ^S_Area, layer_ix: int) -> S_Layer {
        return self.layers[layer_ix]
    }

    s_area__get_last_layer :: proc(self: ^S_Area) -> S_Layer {
        if len(self.layers) == 0 do return nil
        return self.layers[len(self.layers) - 1]
    }

    // Returns nil if the layer is not a plain N layer (only those expose w_cells for now).
    s_area__get_w_cell_from_save_w_table :: proc(self: ^S_Area, wave_ix, layer_ix, x, y: int) -> ^W_Cell {
        if layer_ix < 0 || layer_ix >= len(self.layers) do return nil

        layer, ok := self.layers[layer_ix].(^S_Layer_N)
        if !ok do return nil

        return w_table__get_w_cell(&layer.w_save_tables[wave_ix], x, y)
    }

    s_area__save_rec :: proc(self: ^S_Area, wave_ix: int, data: ^Data) -> (curr_w_table: ^W_Table, err: Error) {
        layer_rec := self.layers[0].(^S_Layer_Rec)

        curr_w_table = s_layer_rec__save(layer_rec, wave_ix, data) or_return
        if !w_table__any_fired(curr_w_table, data.block_id) do return nil, nil

        parent := s_layer__as_n(layer_rec.p)
        for parent.tag != .Frame {
            when DEEP_DEBUG {
                fmt.printf("\nPROCESSING ")
                s_layer_base__print_basic_info(&parent.base)
            }

            curr_w_table = s_layer_n__save(parent, wave_ix, data.block_id, curr_w_table) or_return
            if !w_table__any_fired(curr_w_table, data.block_id) do return nil, nil

            parent = s_layer_n__get_parent(parent)
        }

        return curr_w_table, nil
    }

    s_area__save_frame :: proc(self: ^S_Area, wave_ix: int, block_id: Block_Id, prev_w_table: ^W_Table) -> (curr_w_table: ^W_Table, err: Error) {
        curr_w_table = prev_w_table

        parent := s_layer_n__get_parent(curr_w_table.s_layer)
        for parent.tag != .Seq {
            when DEEP_DEBUG {
                fmt.printf("\nPROCESSING ")
                s_layer_base__print_basic_info(&parent.base)
            }

            curr_w_table = s_layer_n__save(parent, wave_ix, block_id, curr_w_table) or_return
            if !w_table__any_fired(curr_w_table, block_id) do return nil, nil

            parent = s_layer_n__get_parent(parent)
        }

        return curr_w_table, nil
    }

    s_area__save_seq :: proc(self: ^S_Area, wave_ix: int, block_id: Block_Id, curr_w_table: ^W_Table) -> (^W_Table, Error) {
        parent := s_layer_n__get_parent(curr_w_table.s_layer)

        when DEEP_DEBUG {
            fmt.printf("\nPROCESSING ")
            s_layer_base__print_basic_info(&parent.base)
        }

        return s_layer_n__save(parent, wave_ix, block_id, curr_w_table)
    }

    s_area__match_rec :: proc(self: ^S_Area, wave_ix: int, data: ^Data, processor: ^W_Match_Processor) -> Error {
        layer_rec := self.layers[0].(^S_Layer_Rec)

        state := s_layer_rec__match(layer_rec, wave_ix, data, processor) or_return

        switch state {
            case .Collect: w_match_processor__reset_results(processor)
            case .Collect_And_Finish: w_match_processor__run(processor) or_return
        }

        return nil
    }

    s_area__get_net_stats :: proc(self: ^S_Area) -> (stats: Net_Stats) {
        for layer in self.layers do net_stats__add(&stats, s_layer__get_net_stats(layer))
        return
    }

    s_area__print :: proc(self: ^S_Area, short_version: bool) {
        fmt.printf("\n\tarea_ix: %v, tag: %v", self.area_ix, self.tag)
        if short_version do return

        for layer in self.layers {
            fmt.printf("\n\t\t")
            s_layer_base__print_basic_info(s_layer__base(layer))
        }
    }

    s_area__print_net_stats :: proc(self: ^S_Area) {
        fmt.printf("\narea_ix: %v, tag: %v", self.area_ix, self.tag)

        for layer in self.layers {
            fmt.printf("\n\t")
            s_layer_base__print_basic_info(s_layer__base(layer))

            n := s_layer__as_n(layer)
            if n == nil do continue

            ns := s_table__get_net_stats(&n.s_table)
            fmt.printf(
                "\n\t\tS_TABLE [%vx%v] cells: %v/%v, links: %v/%v",
                n.s_table.w, n.s_table.h_max, ns.cells_count, ns.cells_size, ns.links_count, ns.links_size,
            )
        }
    }

///////////////////////////////////////////////////////////////////////////////
// S -- space: areas and layers of the net ("intersected squares cortex").
//
// Built bottom-up from recs:
//
//     SEQ area    one 1x1 layer
//       ^
//     FRAME area  layers_count(recs, 1) chained 1x1 layers
//       ^
//     REC area    (one per rec) shrinking layers: w x h -> (w-1) x (h-1) -> ... -> apex
//                 layer 0 is the S_Layer_Rec, layers 1..depth are its S_Layer_Comp children
//
// Area indexes start at N_AREA__SPECIAL_AREA_SKIP so that N_Addr 0 is never a real cell.

    S :: struct {
        allocator: runtime.Allocator,
        config: ^Config,

        areas: [dynamic]S_Area,          // [0, N_AREA__SPECIAL_AREA_SKIP) are reserved and empty
        tag_to_area: [Area_Tag]int,      // first area with the tag, -1 if none

        v_recs: []^S_Layer_Rec,          // rec base layer by rec id
        rec_to_area: []int,              // rec area index by rec id
    }

    s__init :: proc(self: ^S, config: ^Config, recs: []Rec, allocator: runtime.Allocator) -> Error {
        when VALIDATIONS do assert(len(recs) > 0)

        self.allocator = allocator
        self.config = config

        self.areas = make([dynamic]S_Area, N_AREA__SPECIAL_AREA_SKIP, max(config.s_areas_size, N_AREA__SPECIAL_AREA_SKIP), allocator) or_return
        for &ix in self.tag_to_area do ix = -1

        self.v_recs = make([]^S_Layer_Rec, len(recs), allocator) or_return
        self.rec_to_area = make([]int, len(recs), allocator) or_return

        //
        // Story: seq and frame areas
        //
        seq_area_ix := s__create_area(self, .Seq) or_return
        seq := s__create_layer_n(self, seq_area_ix, 1, 1, 1) or_return

        frame_area_ix := s__create_area(self, .Frame) or_return
        frames_base := s__create_layer_n(self, frame_area_ix, 1, 1, 1) or_return
        frames := frames_base

        for _ in 1..<calc__layers_count(len(recs), 1) {
            next := s__create_layer_n(self, frame_area_ix, 1, 1, 1) or_return
            s_layer__connect(next, frames) or_return
            frames = next
        }

        s_layer__connect(seq, frames) or_return

        //
        // Recs
        //
        for &rec_value, i in recs {
            rec := &rec_value
            rec_area_ix := s__create_area(self, .Rec) or_return
            self.rec_to_area[i] = rec_area_ix

            rec_base := s__create_layer_rec(self, rec_area_ix, rec) or_return
            self.v_recs[i] = rec_base

            for z in 0..<rec.depth {
                comp := s__create_layer_comp(self, rec_area_ix, rec_base, rec_config__get_comp_config(&rec.config, z)) or_return
                s_layer__connect(rec_base, comp) or_return
            }

            apex: S_Layer = rec_base
            w := rec_base.s_table.w
            h := rec_base.s_table.h

            for w > 1 || h > 1 {
                if w > 1 do w -= 1
                if h > 1 do h -= 1

                rec_layer := s__create_layer_n(self, rec_area_ix, w, h, h) or_return
                s_layer__connect(rec_layer, apex) or_return
                apex = rec_layer

                if calc__is_last_layer(w, h) do break
            }

            s_layer__connect(frames_base, apex) or_return
        }

        return nil
    }

    s__terminate :: proc(self: ^S) -> Error {
        for &area in self.areas {
            for layer in area.layers do s_layer__destroy(layer) or_return
            delete(area.layers) or_return
        }
        delete(self.areas) or_return
        delete(self.rec_to_area, self.allocator) or_return
        delete(self.v_recs, self.allocator) or_return

        self.areas = nil
        self.rec_to_area = nil
        self.v_recs = nil

        return nil
    }

    @(private="file")
    s__create_area :: proc(self: ^S, tag: Area_Tag) -> (area_ix: int, err: Error) {
        area_ix = len(self.areas)
        if area_ix >= 1 << N_AREA_IX__BITS do return -1, API_Error.Too_Many_Areas

        append(&self.areas, S_Area{ tag = tag, area_ix = area_ix }) or_return
        self.areas[area_ix].layers = make([dynamic]S_Layer, 0, 4, self.allocator) or_return

        if self.tag_to_area[tag] < 0 do self.tag_to_area[tag] = area_ix

        return
    }

    @(private="file")
    s__register_layer :: proc(self: ^S, area_ix: int, layer: S_Layer) -> Error {
        if len(self.areas[area_ix].layers) >= 1 << N_LAYER_IX__BITS do return API_Error.Too_Many_Layers
        append(&self.areas[area_ix].layers, layer) or_return
        return nil
    }

    @(private="file")
    s__create_layer_n :: proc(self: ^S, area_ix: int, n_w, n_h, n_h_max: int) -> (layer: ^S_Layer_N, err: Error) {
        area := &self.areas[area_ix]
        layer = s_layer_n__create(self.config, area.tag, len(area.layers), area_ix, n_w, n_h, n_h_max, self.allocator) or_return
        s__register_layer(self, area_ix, layer) or_return
        return
    }

    @(private="file")
    s__create_layer_rec :: proc(self: ^S, area_ix: int, rec: ^Rec) -> (layer: ^S_Layer_Rec, err: Error) {
        area := &self.areas[area_ix]
        layer = s_layer_rec__create(self.config, rec, len(area.layers), area_ix, self.allocator) or_return
        s__register_layer(self, area_ix, layer) or_return
        return
    }

    @(private="file")
    s__create_layer_comp :: proc(self: ^S, area_ix: int, frame: ^S_Layer_Rec, rc_config: ^Rec_Comp_Config) -> (layer: ^S_Layer_Comp, err: Error) {
        area := &self.areas[area_ix]
        layer = s_layer_comp__create(self.config, frame, rc_config, len(area.layers), area_ix, self.allocator) or_return
        s__register_layer(self, area_ix, layer) or_return
        return
    }

    // Returns nil for reserved or out of range area indexes.
    s__get_area :: proc(self: ^S, area_ix: int) -> ^S_Area {
        if area_ix < N_AREA__SPECIAL_AREA_SKIP || area_ix >= len(self.areas) do return nil
        return &self.areas[area_ix]
    }

    s__get_area_by_tag :: proc(self: ^S, tag: Area_Tag) -> ^S_Area {
        ix := self.tag_to_area[tag]
        if ix < 0 do return nil
        return &self.areas[ix]
    }

    s__get_rec_area :: proc(self: ^S, rec_id: int) -> ^S_Area {
        return &self.areas[self.rec_to_area[rec_id]]
    }

    s__get_w_cell_from_save_w_table :: proc(self: ^S, wave_ix, area_ix, layer_ix, x, y: int) -> ^W_Cell {
        area := s__get_area(self, area_ix)
        if area == nil do return nil
        return s_area__get_w_cell_from_save_w_table(area, wave_ix, layer_ix, x, y)
    }

    s__find_n_cell :: proc(self: ^S, addr: N_Addr) -> N_Located_Cell {
        area := s__get_area(self, int(addr.area_ix))
        when VALIDATIONS do assert(area != nil)
        return s_layer__find_n_cell(area.layers[addr.layer_ix], addr)
    }

    s__get_net_stats :: proc(self: ^S) -> (stats: Net_Stats) {
        for &area in self.areas[N_AREA__SPECIAL_AREA_SKIP:] do net_stats__add(&stats, s_area__get_net_stats(&area))
        return
    }

    s__print_areas :: proc(self: ^S) {
        fmt.printf("\nS Areas: ")
        for &area in self.areas[N_AREA__SPECIAL_AREA_SKIP:] do s_area__print(&area, false)
    }

    s__print_net_stats :: proc(self: ^S) {
        for &area in self.areas[N_AREA__SPECIAL_AREA_SKIP:] do s_area__print_net_stats(&area)

        ns := s__get_net_stats(self)
        fmt.printf("\nTotal cells: %v/%v, Total links: %v/%v", ns.cells_count, ns.cells_size, ns.links_count, ns.links_size)
    }
