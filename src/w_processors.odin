/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"

///////////////////////////////////////////////////////////////////////////////
// W_Queue -- double-buffered work list: items added while processing `curr` go to `next`.

    W_Queue :: struct($T: typeid) {
        curr: [dynamic]T,
        next: [dynamic]T,
    }

    w_queue__init :: proc(self: ^W_Queue($T), cap: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.curr = make([dynamic]T, 0, cap, allocator) or_return
        self.next = make([dynamic]T, 0, cap, allocator) or_return
        return nil
    }

    w_queue__terminate :: proc(self: ^W_Queue($T)) -> runtime.Allocator_Error {
        delete(self.next) or_return
        delete(self.curr) or_return
        self.next = nil
        self.curr = nil
        return nil
    }

    w_queue__has_next :: #force_inline proc "contextless" (self: ^W_Queue($T)) -> bool {
        return len(self.next) > 0
    }

    // Moves `next` into `curr` for processing.
    w_queue__swap :: proc(self: ^W_Queue($T)) {
        when VALIDATIONS do assert(len(self.curr) == 0)
        self.curr, self.next = self.next, self.curr
    }

    w_queue__clear :: proc(self: ^W_Queue($T)) {
        clear(&self.curr)
        clear(&self.next)
    }

///////////////////////////////////////////////////////////////////////////////
// W_Processor_Stats

    W_Processor_Stats :: struct {
        cells_processed: int,
    }

///////////////////////////////////////////////////////////////////////////////
// W_Match_Processor -- fires signals up from VP cells through n_cells to labels.

    // Float tolerance for sig invariants (sig >= default_sig * breakpoint was checked in multiplied form).
    W_MATCH__SIG_EPSILON :: 1e-9

    W_Match_Item :: struct {
        match_ix: W_Match_Ix,
        s_column: ^S_Column,
        cell_ix: u32,
    }

    W_Match_Processor :: struct {
        block_id: Block_Id,
        wave_ix: int,

        s: ^S,
        match_cell_mem: ^W_Match_Cell_Mem,
        la_column: ^La_Column,

        queue: W_Queue(W_Match_Item),

        results: [dynamic]Label,     // sorted, best first, at most results_size
        results_hidden: [dynamic]int, // per result: labels that tied with it (see add_result)
        results_total: int,
        results_size: int,
        sig_breakpoint: Value,

        stats: W_Processor_Stats,
    }

    w_match_processor__init :: proc(
        self: ^W_Match_Processor,
        s: ^S,
        config: ^Config,
        match_cell_mem: ^W_Match_Cell_Mem,
        la_column: ^La_Column,
        allocator: runtime.Allocator,
    ) -> runtime.Allocator_Error {
        self.block_id = BLOCK_ID__NOT_SET
        self.wave_ix = NOT_SET
        self.s = s
        self.match_cell_mem = match_cell_mem
        self.la_column = la_column
        self.results_size = config.w_match_results_size
        self.sig_breakpoint = config.w_match_sig_breakpoint

        w_queue__init(&self.queue, config.w_match_processor_queue_size, allocator) or_return
        self.results = make([dynamic]Label, 0, self.results_size, allocator) or_return
        self.results_hidden = make([dynamic]int, 0, self.results_size, allocator) or_return

        return nil
    }

    w_match_processor__terminate :: proc(self: ^W_Match_Processor) -> runtime.Allocator_Error {
        delete(self.results_hidden) or_return
        delete(self.results) or_return
        self.results_hidden = nil
        self.results = nil
        return w_queue__terminate(&self.queue)
    }

    w_match_processor__fire_n_cell :: proc(self: ^W_Match_Processor, s_column: ^S_Column, cell_ix: u32, sig: Value) -> Error {
        n_cell := &s_column.cells[cell_ix]

        match_ix := n_cell__get_and_reset_match_cell(n_cell, self.block_id, self.wave_ix, self.match_cell_mem) or_return
        match_cell := w_match_cell_mem__get(self.match_cell_mem, match_ix)

        match_cell.sig += sig

        if w_match_cell__is_sig_over_breakpoint(match_cell, n_cell, self.sig_breakpoint) {
            match_cell.fired = true

            append(&self.queue.next, W_Match_Item{ match_ix = match_ix, s_column = s_column, cell_ix = cell_ix }) or_return

            self.stats.cells_processed += 1
        }

        return nil
    }

    w_match_processor__fire_n_parents :: proc(self: ^W_Match_Processor, link_mem: ^N_Link_Mem, sig: Value, head: N_Link_Ix) -> Error {
        for link := n_link_mem__get(link_mem, head); link != nil; link = n_link_mem__get(link_mem, link.next) {
            located, ok := s__find_n_cell(self.s, link.n_addr).(N_Located_N)
            when VALIDATIONS do assert(ok)

            w_match_processor__fire_n_cell(self, located.s_column, u32(link.n_addr.cell_ix), sig) or_return
        }
        return nil
    }

    w_match_processor__fire_vp_parents_with_sig :: proc(self: ^W_Match_Processor, n_cell_vp: ^N_Cell_VP, s_column_comp: ^S_Column_Comp, sig: Value) -> Error {
        when VALIDATIONS do assert(sig > 0)

        if n_cell_vp.parents == N_LINK_IX__NULL do return nil
        return w_match_processor__fire_n_parents(self, &s_column_comp.link_mem, sig, n_cell_vp.parents)
    }

    w_match_processor__fire_n_parents_with_sig :: proc(self: ^W_Match_Processor, n_cell: ^N_Cell, s_column: ^S_Column, sig: Value) -> Error {
        when VALIDATIONS do assert(sig > 0)

        for head in n_cell.parents {
            if head == N_LINK_IX__NULL do continue
            w_match_processor__fire_n_parents(self, &s_column.link_mem, sig, head) or_return
        }
        return nil
    }

    w_match_processor__fire_n_labels_with_sig :: proc(self: ^W_Match_Processor, n_cell: ^N_Cell, sig: Value) {
        when VALIDATIONS do assert(sig > 0)

        link_mem := &self.la_column.la_link_mem

        for link := la_link_mem__get(link_mem, n_cell.labels); link != nil; link = la_link_mem__get(link_mem, link.next) {
            la_cell := la_column__get_la_cell(self.la_column, link.la_ix)
            when VALIDATIONS do assert(la_cell != nil)

            match_cell := la_cell__get_and_reset_match_cell(la_cell, self.block_id, self.wave_ix)
            w_la_match_cell__add_sig(match_cell, n_cell.addr, sig)
        }
    }

    w_match_processor__run_iteration :: proc(self: ^W_Match_Processor) -> (cells_processed: int, err: Error) {
        w_queue__swap(&self.queue)

        for item in self.queue.curr {
            n_cell := &item.s_column.cells[item.cell_ix]
            match_cell := w_match_cell_mem__get(self.match_cell_mem, item.match_ix)

            fire_sig := match_cell.sig / n_cell.default_sig

            when VALIDATIONS {
                assert(fire_sig >= self.sig_breakpoint - W_MATCH__SIG_EPSILON)
                assert(fire_sig <= 1.0 + W_MATCH__SIG_EPSILON)
            }

            w_match_processor__fire_n_parents_with_sig(self, n_cell, item.s_column, fire_sig) or_return

            if n_cell.labels != LA_LINK_IX__NULL {
                when DEEP_DEBUG do fmt.printf("\nN_CELL has label (cell_ix=%v) link=%v", n_cell.addr.cell_ix, n_cell.labels)
                w_match_processor__fire_n_labels_with_sig(self, n_cell, fire_sig)
            }

            cells_processed += 1
        }

        clear(&self.queue.curr)

        return
    }

    // Inserts label into the sorted results (best first), replicating the C sorted skip list:
    //   - a label that compares equal (0) to an existing result is counted but hidden behind it,
    //   - hidden labels count toward results_size and are dropped before visible ones.
    @(private="file")
    w_match_processor__add_result :: proc(self: ^W_Match_Processor, label: Label) -> runtime.Allocator_Error {
        if self.results_total >= self.results_size {
            last := len(self.results) - 1
            if label__compare(self.results[last], label) <= 0 do return nil

            if self.results_hidden[last] > 0 {
                self.results_hidden[last] -= 1
            } else {
                pop(&self.results)
                pop(&self.results_hidden)
            }
            self.results_total -= 1
        }

        ix := len(self.results)
        for r, i in self.results {
            cmp := label__compare(label, r)

            if cmp == 0 {
                self.results_hidden[i] += 1
                self.results_total += 1
                return nil
            }

            if cmp < 0 {
                ix = i
                break
            }
        }

        inject_at(&self.results, ix, label) or_return
        inject_at(&self.results_hidden, ix, 0) or_return
        self.results_total += 1

        return nil
    }

    w_match_processor__prepare_results :: proc(self: ^W_Match_Processor) -> Error {
        for &la_cell in self.la_column.cells {
            if la_cell.children_count == 0 do continue

            match_cell := &la_cell.w_match_cells[self.wave_ix]

            if w_la_match_cell__no_sig(match_cell) do continue
            if match_cell.block_id != self.block_id do continue

            w_match_processor__add_result(self, Label{
                id = la_cell.la_ix,
                sig = match_cell.sig,
                sig_received_count = match_cell.sig_received_count,
            }) or_return
        }

        return nil
    }

    w_match_processor__run :: proc(self: ^W_Match_Processor) -> Error {
        for w_queue__has_next(&self.queue) {
            when DEEP_DEBUG {
                fmt.printf("\nMATCH PROCESSOR BATCH:")
                w_match_processor__print_symbols(self)
            }

            w_match_processor__run_iteration(self) or_return
        }

        return w_match_processor__prepare_results(self)
    }

    w_match_processor__reset_results :: proc(self: ^W_Match_Processor) {
        clear(&self.results)
        clear(&self.results_hidden)
        self.results_total = 0
        self.stats = {}
    }

    w_match_processor__print_symbols :: proc(self: ^W_Match_Processor) {
        for item in self.queue.next {
            n_cell := &item.s_column.cells[item.cell_ix]
            match_cell := w_match_cell_mem__get(self.match_cell_mem, item.match_ix)
            fmt.printf("\n[%v, %v] sig=%.f | ", item.s_column.x, item.s_column.y, match_cell.sig)
            n_addr__print(n_cell.addr)
        }
    }

///////////////////////////////////////////////////////////////////////////////
// W_Del_Processor -- removes n_cells top-down: a cell without parents unlinks its children,
// which are then processed in turn.

    W_Del_Item :: struct {
        s_column: ^S_Column,
        cell_ix: u32,
    }

    W_Del_Processor :: struct {
        s: ^S,
        queue: W_Queue(W_Del_Item),
        stats: W_Processor_Stats,
    }

    w_del_processor__init :: proc(self: ^W_Del_Processor, s: ^S, list_size: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.s = s
        return w_queue__init(&self.queue, list_size, allocator)
    }

    w_del_processor__terminate :: proc(self: ^W_Del_Processor) -> runtime.Allocator_Error {
        return w_queue__terminate(&self.queue)
    }

    w_del_processor__add :: proc(self: ^W_Del_Processor, s_column: ^S_Column, cell_ix: u32) -> runtime.Allocator_Error {
        _, err := append(&self.queue.next, W_Del_Item{ s_column = s_column, cell_ix = cell_ix })
        return err
    }

    w_del_processor__run_iteration :: proc(self: ^W_Del_Processor) -> (cells_processed: int, err: Error) {
        w_queue__swap(&self.queue)

        for item in self.queue.curr {
            s_column := item.s_column
            n_cell := &s_column.cells[item.cell_ix]

            // Still used by other parents
            if n_cell__has_parents(n_cell) do continue

            if n_cell.children != N_LINK_IX__NULL {
                link_mem := &s_column.link_mem
                link_ix := n_cell.children

                for link_ix != N_LINK_IX__NULL {
                    link := n_link_mem__get(link_mem, link_ix)

                    switch located in s__find_n_cell(self.s, link.n_addr) {
                        case N_Located_N:
                            n_cell__remove_links_to_parent(located.n_cell, n_cell.addr, &located.s_column.link_mem) or_return
                            w_del_processor__add(self, located.s_column, u32(located.n_cell.addr.cell_ix)) or_return

                        case N_Located_VP:
                            n_link_mem__remove(&located.s_column_comp.link_mem, &located.n_cell_vp.parents, n_cell.addr) or_return
                    }

                    next := link.next
                    n_link_mem__free(link_mem, link_ix) or_return
                    link_ix = next
                }

                n_cell.children = N_LINK_IX__NULL
                s_column__free_n_cell(s_column, n_cell)
            }

            cells_processed += 1
        }

        clear(&self.queue.curr)

        return
    }

    w_del_processor__run :: proc(self: ^W_Del_Processor) -> Error {
        for w_queue__has_next(&self.queue) {
            w_del_processor__run_iteration(self) or_return
        }
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// W_Restore_Processor -- walks down from n_cells to VP cells and rebuilds the values.

    W_Restore_Item :: struct {
        s_column: ^S_Column,
        cell_ix: u32,
    }

    W_Restore_Processor :: struct {
        block_id: Block_Id,
        wave_ix: int,

        s: ^S,
        queue: W_Queue(W_Restore_Item),
        stats: W_Processor_Stats,

        data: ^Data, // restored values (points into the comp layer's restore data)
    }

    w_restore_processor__init :: proc(self: ^W_Restore_Processor, wave_id, wave_ix: int, s: ^S, list_size: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.block_id = Block_Id{ wave_id, 0 }
        self.wave_ix = wave_ix
        self.s = s
        self.data = nil
        return w_queue__init(&self.queue, list_size, allocator)
    }

    w_restore_processor__terminate :: proc(self: ^W_Restore_Processor) -> runtime.Allocator_Error {
        return w_queue__terminate(&self.queue)
    }

    w_restore_processor__reset :: proc(self: ^W_Restore_Processor) {
        block_id__increase_block_ix(&self.block_id)
        w_queue__clear(&self.queue)
        self.stats = {}
        self.data = nil
    }

    w_restore_processor__add :: proc(self: ^W_Restore_Processor, s_column: ^S_Column, cell_ix: u32) -> runtime.Allocator_Error {
        _, err := append(&self.queue.next, W_Restore_Item{ s_column = s_column, cell_ix = cell_ix })
        return err
    }

    w_restore_processor__run_iteration :: proc(self: ^W_Restore_Processor) -> (cells_processed: int, err: Error) {
        w_queue__swap(&self.queue)

        for item in self.queue.curr {
            n_cell := &item.s_column.cells[item.cell_ix]
            link_mem := &item.s_column.link_mem

            for link := n_link_mem__get(link_mem, n_cell.children); link != nil; link = n_link_mem__get(link_mem, link.next) {
                switch located in s__find_n_cell(self.s, link.n_addr) {
                    case N_Located_N:
                        restore_cell := &located.n_cell.w_restore_cells[self.wave_ix]
                        if restore_cell.block_id == self.block_id do continue

                        restore_cell.block_id = self.block_id
                        w_restore_processor__add(self, located.s_column, u32(located.n_cell.addr.cell_ix)) or_return

                    case N_Located_VP:
                        data := &located.s_layer_comp.p_view.w_restore_data[self.wave_ix]
                        if self.data == nil {
                            for &v in data.values do v = 0
                            self.data = data
                        }

                        column_ix := located.s_column_comp.column_ix
                        value := located.n_cell_vp.value

                        if data.values[column_ix] > 0 {
                            data.values[column_ix] = (data.values[column_ix] + value) / 2
                        } else {
                            data.values[column_ix] = value
                        }
                }
            }

            cells_processed += 1
        }

        clear(&self.queue.curr)

        return
    }

    w_restore_processor__run :: proc(self: ^W_Restore_Processor) -> Error {
        for w_queue__has_next(&self.queue) {
            w_restore_processor__run_iteration(self) or_return
        }
        return nil
    }
