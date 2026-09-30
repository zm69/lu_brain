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
// Defines

    LA_CELL__MATCH_CELLS_SIZE :: 1

    LA_IX__NULL :: max(int)

///////////////////////////////////////////////////////////////////////////////
// La_Link -- singly linked list node of label indexes (n_cell -> labels).

    La_Link_Ix :: distinct u32

    LA_LINK_IX__NULL :: La_Link_Ix(lc.POOL_NULL_IX)

    La_Link :: struct {
        la_ix: int,
        next: La_Link_Ix,
    }

    La_Link_Mem :: lc.Pool(La_Link)

    la_link_mem__init :: proc(self: ^La_Link_Mem, size: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        return lc.pool__init(self, size, true, allocator)
    }

    la_link_mem__terminate :: proc(self: ^La_Link_Mem) -> runtime.Allocator_Error {
        return lc.pool__terminate(self)
    }

    // Returns nil for LA_LINK_IX__NULL.
    la_link_mem__get :: #force_inline proc(self: ^La_Link_Mem, ix: La_Link_Ix) -> ^La_Link {
        return lc.pool__get(self, u32(ix))
    }

    la_link_mem__prepend :: proc(self: ^La_Link_Mem, head: La_Link_Ix, la_ix: int) -> (La_Link_Ix, runtime.Allocator_Error) {
        ix, err := lc.pool__alloc(self)
        if err != nil do return head, err

        link := la_link_mem__get(self, La_Link_Ix(ix))
        link.la_ix = la_ix
        link.next = head

        return La_Link_Ix(ix), nil
    }

    la_link_mem__remove :: proc(self: ^La_Link_Mem, head: ^La_Link_Ix, la_ix: int) -> runtime.Allocator_Error {
        prev: ^La_Link = nil
        ix := head^

        for ix != LA_LINK_IX__NULL {
            link := la_link_mem__get(self, ix)

            if link.la_ix == la_ix {
                if prev != nil do prev.next = link.next
                else do head^ = link.next

                return lc.pool__free(self, u32(ix))
            }

            prev = link
            ix = link.next
        }

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// W_La_Match_Cell -- per-wave match state of a label.

    W_La_Match_Cell :: struct {
        block_id: Block_Id,
        sig: Value,                 // max received sig
        sig_sum: Value,             // sum of received sigs
        n_addr: N_Addr,             // cell that sent the max sig (debug)
        sig_received_count: Value,
    }

    w_la_match_cell__init :: proc "contextless" (self: ^W_La_Match_Cell, block_id: Block_Id) {
        self^ = { block_id = block_id }
    }

    w_la_match_cell__reset :: proc "contextless" (self: ^W_La_Match_Cell) {
        self^ = { block_id = BLOCK_ID__NOT_SET }
    }

    w_la_match_cell__no_sig :: #force_inline proc "contextless" (self: ^W_La_Match_Cell) -> bool {
        return self.sig == 0
    }

    w_la_match_cell__add_sig :: proc "contextless" (self: ^W_La_Match_Cell, n_addr: N_Addr, sig: Value) {
        if sig > self.sig {
            self.sig = sig
            self.n_addr = n_addr
        }
        self.sig_sum += sig
        self.sig_received_count += 1
    }

    w_la_match_cell__score :: proc "contextless" (self: ^W_La_Match_Cell, scoring: Label_Scoring) -> Value {
        switch scoring {
            case .Max: return self.sig
            case .Sum: return self.sig_sum
            case .Mean: return self.sig_received_count > 0 ? self.sig_sum / self.sig_received_count : 0
        }
        return self.sig
    }

///////////////////////////////////////////////////////////////////////////////
// La_Cell -- one label.

    La_Cell :: struct {
        la_ix: int,

        children: N_Link_Ix,        // n_cells linked to this label (in La_Column.n_link_mem)
        children_count: int,

        w_match_cells: [LA_CELL__MATCH_CELLS_SIZE]W_La_Match_Cell,
    }

    la_cell__init :: proc "contextless" (self: ^La_Cell, la_ix: int) {
        self^ = { la_ix = la_ix }
        for &c in self.w_match_cells do w_la_match_cell__reset(&c)
    }

    la_cell__reset :: proc "contextless" (self: ^La_Cell) {
        self.children = N_LINK_IX__NULL
        self.children_count = 0
    }

    la_cell__get_and_reset_match_cell :: proc(self: ^La_Cell, block_id: Block_Id, wave_ix: int) -> ^W_La_Match_Cell {
        when VALIDATIONS do assert(wave_ix < LA_CELL__MATCH_CELLS_SIZE)

        match_cell := &self.w_match_cells[wave_ix]
        if match_cell.block_id != block_id do w_la_match_cell__init(match_cell, block_id)

        return match_cell
    }

    la_cell__print :: proc(self: ^La_Cell) {
        fmt.printf(
            "LA_IX=%v, children_count=%v, children_present?=%s",
            self.la_ix,
            self.children_count,
            self.children != N_LINK_IX__NULL ? "Y" : "N",
        )
    }

///////////////////////////////////////////////////////////////////////////////
// La_Column -- all labels of a brain.

    La_Column :: struct {
        allocator: runtime.Allocator,

        cells: []La_Cell,

        n_link_mem: N_Link_Mem,     // label -> n_cells
        la_link_mem: La_Link_Mem,   // n_cell -> labels
    }

    la_column__init :: proc(self: ^La_Column, config: ^Config, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        self.allocator = allocator

        self.cells = make([]La_Cell, config.la_labels_size, allocator) or_return
        for &cell, i in self.cells do la_cell__init(&cell, i)

        n_link_mem__init(&self.n_link_mem, config.n_link_mem_size, allocator) or_return
        la_link_mem__init(&self.la_link_mem, config.la_link_mem_size, allocator) or_return

        return nil
    }

    la_column__terminate :: proc(self: ^La_Column) -> runtime.Allocator_Error {
        la_link_mem__terminate(&self.la_link_mem) or_return
        n_link_mem__terminate(&self.n_link_mem) or_return
        delete(self.cells, self.allocator) or_return
        self.cells = nil
        return nil
    }

    // Returns nil if label is out of range.
    la_column__get_la_cell :: #force_inline proc "contextless" (self: ^La_Column, label: int) -> ^La_Cell {
        if label < 0 || label >= len(self.cells) do return nil
        return &self.cells[label]
    }

    la_column__save_label :: proc(self: ^La_Column, n_cell: ^N_Cell, label: int) -> (la_cell: ^La_Cell, err: Error) {
        la_cell = la_column__get_la_cell(self, label)
        if la_cell == nil do return nil, API_Error.Label_Out_Of_Range

        if n_link_mem__contains(&self.n_link_mem, la_cell.children, n_cell.addr) do return

        la_cell.children = n_link_mem__prepend(&self.n_link_mem, la_cell.children, n_cell.addr) or_return
        la_cell.children_count += 1

        n_cell__prepend_label(n_cell, la_cell.la_ix, &self.la_link_mem) or_return

        return
    }

///////////////////////////////////////////////////////////////////////////////
// Label -- one match result.

    Label :: struct {
        id: int,
        sig: Value,
        sig_received_count: Value,
    }

    // < 0 if a ranks before b. Higher sig first; nearly equal sigs (< 0.01) are ranked by how many
    // signals the label received.
    label__compare :: proc "contextless" (a, b: Label) -> Value {
        diff := b.sig - a.sig
        if abs(diff) < 0.01 do return b.sig_received_count - a.sig_received_count
        return diff
    }

    labels__print :: proc(labels: []Label) {
        for label in labels {
            fmt.printf("\n\tlabel=%v, sig=%.2f (%.0f)", label.id, label.sig, label.sig_received_count)
        }
    }
