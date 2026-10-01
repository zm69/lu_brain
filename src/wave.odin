/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"

// Lu
    import lc "lu_core"

///////////////////////////////////////////////////////////////////////////////
// Wave -- common part of every wave. One save or match wave is one sequence.
//
// Waves are user-owned structs; they keep internal pointers to themselves and to the brain,
// so neither may move between init and terminate.

    Wave :: struct {
        allocator: runtime.Allocator,
        brain: ^Brain,

        wave_id: int,       // global, unique per brain
        wave_ix: int,       // per wave type, indexes per-cell wave state
        type: Wave_Type,
    }

    @(private)
    wave__init :: proc(self: ^Wave, type: Wave_Type, brain: ^Brain) -> Error {
        if !brain__is_built(brain) do return API_Error.Brain_Not_Built

        self.allocator = brain.allocator
        self.brain = brain
        self.type = type

        return w_manager__register_wave(&brain.w_manager, self)
    }

    @(private)
    wave__terminate :: proc(self: ^Wave) -> Error {
        return w_manager__unregister_wave(&self.brain.w_manager, self)
    }

///////////////////////////////////////////////////////////////////////////////
// W_Manager -- registry of live waves, hands out wave ids and per-type wave indexes.

    W_MANAGER__FIRST_WAVE_ID :: 10000 when DEEP_DEBUG else 1000

    W_Manager :: struct {
        waves: [Wave_Type]lc.Pool(^Wave),
        waves_size: [Wave_Type]int,
        next_wave_id: int,
    }

    w_manager__init :: proc(self: ^W_Manager, config: ^Config, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.waves_size = {
            .Save = config.w_save_waves_size,
            .Match = config.w_match_waves_size,
            .Delete = config.w_delete_waves_size,
            .Restore = config.w_restore_waves_size,
        }

        for type in Wave_Type do lc.pool__init(&self.waves[type], self.waves_size[type], false, allocator) or_return

        self.next_wave_id = W_MANAGER__FIRST_WAVE_ID

        return nil
    }

    w_manager__terminate :: proc(self: ^W_Manager) -> runtime.Allocator_Error {
        for type in Wave_Type do lc.pool__terminate(&self.waves[type]) or_return
        return nil
    }

    w_manager__is_empty :: proc(self: ^W_Manager) -> bool {
        for type in Wave_Type do if lc.pool__len(&self.waves[type]) > 0 do return false
        return true
    }

    w_manager__register_wave :: proc(self: ^W_Manager, wave: ^Wave) -> Error {
        pool := &self.waves[wave.type]
        if lc.pool__len(pool) >= self.waves_size[wave.type] do return API_Error.Too_Many_Waves

        ix := lc.pool__alloc(pool) or_return
        lc.pool__get(pool, ix)^ = wave

        wave.wave_ix = int(ix)
        wave.wave_id = self.next_wave_id
        self.next_wave_id += 1

        return nil
    }

    w_manager__unregister_wave :: proc(self: ^W_Manager, wave: ^Wave) -> Error {
        pool := &self.waves[wave.type]
        lc.pool__get(pool, u32(wave.wave_ix))^ = nil
        return lc.pool__free(pool, u32(wave.wave_ix))
    }

    w_manager__get_wave :: proc(self: ^W_Manager, wave_ix: int, type: Wave_Type) -> ^Wave {
        pool := &self.waves[type]
        if wave_ix < 0 || wave_ix >= len(pool.items) do return nil
        return lc.pool__get(pool, u32(wave_ix))^
    }

///////////////////////////////////////////////////////////////////////////////
// Data_Wave -- a wave that receives data (save and match).

    Data_Wave :: struct {
        using wave: Wave,
        seq: Data_Seq,
    }

    @(private)
    data_wave__init :: proc(self: ^Data_Wave, type: Wave_Type, brain: ^Brain) -> Error {
        wave__init(&self.wave, type, brain) or_return
        data_seq__init(&self.seq, self.wave_id, len(brain.recs), self.allocator) or_return
        return nil
    }

    @(private)
    data_wave__terminate :: proc(self: ^Data_Wave) -> Error {
        data_seq__terminate(&self.seq) or_return
        return wave__terminate(&self.wave)
    }

    // Clears pushed data and the rec state, so the next push starts a new sequence.
    data_wave__reset :: proc(self: ^Data_Wave) {
        data_seq__reset(&self.seq)

        // TODO: only rec 0 is processed for now
        layer_rec := s__get_rec_area(&self.brain.s, 0).layers[0].(^S_Layer_Rec)
        w_rec__reset(s_layer_rec__get_w_rec(layer_rec, self.wave_ix, self.type))
    }

    data_wave__block_begin :: proc(self: ^Data_Wave) {
        data_seq__block_begin(&self.seq)
    }

    data_wave__block_end :: proc(self: ^Data_Wave) {
        data_seq__block_end(&self.seq)
    }

    // Values are borrowed and must stay alive until the wave is processed (save / match).
    data_wave__push :: proc(self: ^Data_Wave, rec: ^Rec, values: []Value, w, h, d: int) -> Error {
        when VALIDATIONS do assert(rec.brain == self.brain)
        if len(values) < w * h * d do return API_Error.Invalid_Argument

        return data_seq__push(&self.seq, rec.id, values, w, h, d, rec.view)
    }

    @(private)
    data_wave__prepare_data :: proc(self: ^Data_Wave, block: ^Data_Block) -> ^Data {
        // TODO: only rec 0 is processed for now
        rec_id := 0
        data := &block.datum[rec_id]

        if .Reset_Recs in block.flags do data.flags += { .Reset_Rec }

        return data
    }

///////////////////////////////////////////////////////////////////////////////
// Save_Wave

    Save_Wave :: struct {
        using data_wave: Data_Wave,
    }

    save_wave__init :: proc(self: ^Save_Wave, brain: ^Brain) -> Error {
        return data_wave__init(&self.data_wave, .Save, brain)
    }

    save_wave__terminate :: proc(self: ^Save_Wave) -> Error {
        return data_wave__terminate(&self.data_wave)
    }

    @(private="file")
    save_wave__process_block :: proc(self: ^Save_Wave, block: ^Data_Block) -> Error {
        s := &self.brain.s
        data := data_wave__prepare_data(self, block)
        if data__is_empty(data) do return nil

        w_table := s_area__save_rec(s__get_rec_area(s, data.rec_id), self.wave_ix, data) or_return
        if w_table == nil do return nil

        w_table = s_area__save_frame(s__get_area_by_tag(s, .Frame), self.wave_ix, data.block_id, w_table) or_return
        if w_table == nil do return nil

        _ = s_area__save_seq(s__get_area_by_tag(s, .Seq), self.wave_ix, data.block_id, w_table) or_return

        return nil
    }

    // Saves the next pushed block only.
    save_wave__save_step :: proc(self: ^Save_Wave) -> Error {
        block := data_seq__next_block(&self.seq)
        if block == nil do return nil
        return save_wave__process_block(self, block)
    }

    // Saves every pushed block and clears the pushed data.
    save_wave__save :: proc(self: ^Save_Wave) -> Error {
        for block := data_seq__next_block(&self.seq); block != nil; block = data_seq__next_block(&self.seq) {
            save_wave__process_block(self, block) or_return
        }

        data_seq__reset(&self.seq)

        return nil
    }

    // Links label to the n_cell the last save landed on at (area_ix, layer_ix, x, y).
    save_wave__link_to_label :: proc(self: ^Save_Wave, area_ix, layer_ix, x, y: int, label: int) -> (la_cell: ^La_Cell, err: Error) {
        w_cell := s__get_w_cell_from_save_w_table(&self.brain.s, self.wave_ix, area_ix, layer_ix, x, y)
        if w_cell == nil || !w_cell__is_set(w_cell) do return nil, API_Error.W_Cell_Not_Found

        when DEEP_DEBUG {
            fmt.printf("\nLINKING LABEL %v TO n_cell: ", label)
            n_addr__print(w_cell__n_cell(w_cell).addr)
        }

        return la_column__save_label(&self.brain.la_column, w_cell__n_cell(w_cell), label)
    }

    // Links label to every n_cell the last save landed on in the rec layer at `level`
    // (1 = first layer above the rec base). Returns how many cells were linked.
    //
    // Linking a label per training sample at a low level turns matching into patch voting:
    // with Label_Scoring.Sum a sample scores the sum of its matching patches over the whole input.
    save_wave__link_level_to_label :: proc(self: ^Save_Wave, rec: ^Rec, level: int, label: int) -> (linked: int, err: Error) {
        rec_area := s__get_rec_area(&self.brain.s, rec.id)

        for layer, layer_ix in rec_area.layers {
            n, ok := layer.(^S_Layer_N)
            if !ok || n.level != level do continue

            for y in 0..<n.s_table.h {
                for x in 0..<n.s_table.w {
                    save_wave__link_to_label(self, rec_area.area_ix, layer_ix, x, y, label) or_return
                    linked += 1
                }
            }
            return
        }

        return 0, API_Error.Invalid_Argument
    }

    save_wave__reset :: proc(self: ^Save_Wave) {
        data_wave__reset(&self.data_wave)
    }

///////////////////////////////////////////////////////////////////////////////
// Match_Wave

    Match_Wave :: struct {
        using data_wave: Data_Wave,

        match_cell_mem: W_Match_Cell_Mem,
        processor: W_Match_Processor,
    }

    match_wave__init :: proc(self: ^Match_Wave, brain: ^Brain) -> Error {
        data_wave__init(&self.data_wave, .Match, brain) or_return

        w_match_cell_mem__init(&self.match_cell_mem, brain.config.w_match_cells_size_per_wave, self.allocator) or_return
        w_match_processor__init(&self.processor, &brain.s, &brain.config, &self.match_cell_mem, &brain.la_column, self.allocator) or_return

        return nil
    }

    match_wave__terminate :: proc(self: ^Match_Wave) -> Error {
        w_match_processor__terminate(&self.processor) or_return
        w_match_cell_mem__terminate(&self.match_cell_mem) or_return
        return data_wave__terminate(&self.data_wave)
    }

    @(private="file")
    match_wave__process_block :: proc(self: ^Match_Wave, block: ^Data_Block) -> Error {
        s := &self.brain.s
        data := data_wave__prepare_data(self, block)
        if data__is_empty(data) do return nil

        return s_area__match_rec(s__get_rec_area(s, data.rec_id), self.wave_ix, data, &self.processor)
    }

    // Matches the next pushed block only.
    match_wave__match_step :: proc(self: ^Match_Wave) -> Error {
        block := data_seq__next_block(&self.seq)
        if block == nil do return nil
        return match_wave__process_block(self, block)
    }

    // Matches every pushed block and clears the pushed data. Read results with match_wave__results.
    match_wave__match :: proc(self: ^Match_Wave) -> Error {
        for block := data_seq__next_block(&self.seq); block != nil; block = data_seq__next_block(&self.seq) {
            match_wave__process_block(self, block) or_return
        }

        data_seq__reset(&self.seq)

        return nil
    }

    // Matched labels, best first. Valid until the next match.
    match_wave__results :: proc(self: ^Match_Wave) -> []Label {
        return self.processor.results[:]
    }

    // Overrides Config.w_match_sig_breakpoint for this wave, e.g. to retry with a lower one.
    match_wave__set_sig_breakpoint :: proc(self: ^Match_Wave, breakpoint: Value) -> Error {
        if breakpoint <= 0 || breakpoint > 1 do return API_Error.Invalid_Argument
        self.processor.sig_breakpoint = breakpoint
        return nil
    }

    match_wave__fired_cells_count :: proc(self: ^Match_Wave) -> int {
        return self.processor.stats.cells_processed
    }

    match_wave__print_results :: proc(self: ^Match_Wave) {
        fmt.printf("\nMATCH RESULTS (%v cells fired):", match_wave__fired_cells_count(self))
        labels__print(match_wave__results(self))
    }

    match_wave__reset :: proc(self: ^Match_Wave) {
        data_wave__reset(&self.data_wave)
    }

///////////////////////////////////////////////////////////////////////////////
// Delete_Wave

    DELETE_WAVE__LIST_SIZE :: 1024

    Delete_Wave :: struct {
        using wave: Wave,
        processor: W_Del_Processor,
    }

    delete_wave__init :: proc(self: ^Delete_Wave, brain: ^Brain, list_size := DELETE_WAVE__LIST_SIZE) -> Error {
        wave__init(&self.wave, .Delete, brain) or_return
        w_del_processor__init(&self.processor, &brain.s, list_size, self.allocator) or_return
        return nil
    }

    delete_wave__terminate :: proc(self: ^Delete_Wave) -> Error {
        w_del_processor__terminate(&self.processor) or_return
        return wave__terminate(&self.wave)
    }

    // Unlinks label from its n_cells and deletes the n_cells no other parent depends on.
    delete_wave__delete_label :: proc(self: ^Delete_Wave, label: int) -> Error {
        s := &self.brain.s
        la_column := &self.brain.la_column

        la_cell := la_column__get_la_cell(la_column, label)
        if la_cell == nil do return API_Error.Label_Out_Of_Range
        if la_cell.children_count == 0 do return nil

        n_link_mem := &la_column.n_link_mem
        link_ix := la_cell.children

        for link_ix != N_LINK_IX__NULL {
            link := n_link_mem__get(n_link_mem, link_ix)

            if located, ok := s__find_n_cell(s, link.n_addr).(N_Located_N); ok {
                n_cell__remove_link_to_label(located.n_cell, la_cell.la_ix, &la_column.la_link_mem) or_return
                w_del_processor__add(&self.processor, located.s_column, u32(located.n_cell.addr.cell_ix)) or_return
            }

            next := link.next
            n_link_mem__free(n_link_mem, link_ix) or_return
            link_ix = next
        }

        la_cell__reset(la_cell)

        return w_del_processor__run(&self.processor)
    }

    delete_wave__delete_neuron :: proc(self: ^Delete_Wave, n_addr: N_Addr) -> Error {
        located, ok := s__find_n_cell(&self.brain.s, n_addr).(N_Located_N)
        if !ok do return API_Error.Invalid_N_Addr

        // unlink the cell from its labels, so label -> cells stays accurate
        la_column := &self.brain.la_column
        for link := la_link_mem__get(&la_column.la_link_mem, located.n_cell.labels); link != nil; link = la_link_mem__get(&la_column.la_link_mem, link.next) {
            la_cell := la_column__get_la_cell(la_column, link.la_ix)
            if la_cell == nil do continue

            before := n_link_mem__links_count(&la_column.n_link_mem)
            n_link_mem__remove(&la_column.n_link_mem, &la_cell.children, n_addr) or_return
            if n_link_mem__links_count(&la_column.n_link_mem) < before do la_cell.children_count -= 1
        }
        la_link_mem__free_all(&la_column.la_link_mem, &located.n_cell.labels) or_return
        located.n_cell.labels_count = 0

        w_del_processor__add(&self.processor, located.s_column, u32(n_addr.cell_ix), force = true) or_return

        return w_del_processor__run(&self.processor)
    }

///////////////////////////////////////////////////////////////////////////////
// Restore_Wave

    RESTORE_WAVE__LIST_SIZE :: 1024

    Restore_Wave :: struct {
        using wave: Wave,
        processor: W_Restore_Processor,
    }

    restore_wave__init :: proc(self: ^Restore_Wave, brain: ^Brain, list_size := RESTORE_WAVE__LIST_SIZE) -> Error {
        wave__init(&self.wave, .Restore, brain) or_return
        w_restore_processor__init(&self.processor, self.wave_id, self.wave_ix, &brain.s, list_size, self.allocator) or_return
        return nil
    }

    restore_wave__terminate :: proc(self: ^Restore_Wave) -> Error {
        w_restore_processor__terminate(&self.processor) or_return
        return wave__terminate(&self.wave)
    }

    restore_wave__restore_from_label :: proc(self: ^Restore_Wave, label: int) -> Error {
        s := &self.brain.s
        la_column := &self.brain.la_column

        w_restore_processor__reset(&self.processor)

        la_cell := la_column__get_la_cell(la_column, label)
        if la_cell == nil do return API_Error.Label_Out_Of_Range
        if la_cell.children_count == 0 do return nil

        n_link_mem := &la_column.n_link_mem

        for link := n_link_mem__get(n_link_mem, la_cell.children); link != nil; link = n_link_mem__get(n_link_mem, link.next) {
            if located, ok := s__find_n_cell(s, link.n_addr).(N_Located_N); ok {
                w_restore_processor__add(&self.processor, located.s_column, u32(located.n_cell.addr.cell_ix)) or_return
            }
        }

        return w_restore_processor__run(&self.processor)
    }

    restore_wave__restore_from_neuron :: proc(self: ^Restore_Wave, n_addr: N_Addr) -> Error {
        w_restore_processor__reset(&self.processor)

        located, ok := s__find_n_cell(&self.brain.s, n_addr).(N_Located_N)
        if !ok do return API_Error.Invalid_N_Addr

        w_restore_processor__add(&self.processor, located.s_column, u32(n_addr.cell_ix)) or_return

        return w_restore_processor__run(&self.processor)
    }

    // Restored values (w * h of the rec, one comp), nil if nothing was restored.
    // TODO: temporary API, restores only the first comp that was reached.
    restore_wave__values :: proc(self: ^Restore_Wave) -> []Value {
        if self.processor.data == nil do return nil
        return self.processor.data.values
    }
