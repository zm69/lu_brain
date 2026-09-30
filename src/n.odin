/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Lu
    import lc "lu_core"

///////////////////////////////////////////////////////////////////////////////
// Defines

    // TODO: per-cell wave state is fixed-size (one wave of each type). Move it to per-wave storage
    // indexed by n_cell addr to support many concurrent waves.
    N_CELL__W_MATCH_CELLS_SIZE :: 1
    N_CELL__W_SAVE_CELLS_SIZE :: 1
    N_CELL__W_RESTORE_CELLS_SIZE :: 1

///////////////////////////////////////////////////////////////////////////////
// N_Link -- singly linked list node of N_Addr, stored in an index pool.
//
// Links are addressed by index (not pointer) because the pool grows and moves.

    N_Link_Ix :: distinct u32

    N_LINK_IX__NULL :: N_Link_Ix(lc.POOL_NULL_IX)

    N_Link :: struct {
        n_addr: N_Addr,
        next: N_Link_Ix,
    }

    N_Link_Mem :: lc.Pool(N_Link)

    n_link_mem__init :: proc(self: ^N_Link_Mem, size: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        return lc.pool__init(self, size, true, allocator)
    }

    n_link_mem__terminate :: proc(self: ^N_Link_Mem) -> runtime.Allocator_Error {
        return lc.pool__terminate(self)
    }

    // Returns nil for N_LINK_IX__NULL.
    n_link_mem__get :: #force_inline proc(self: ^N_Link_Mem, ix: N_Link_Ix) -> ^N_Link {
        return lc.pool__get(self, u32(ix))
    }

    n_link_mem__links_count :: proc(self: ^N_Link_Mem) -> int {
        return lc.pool__len(self)
    }

    n_link_mem__links_size :: proc(self: ^N_Link_Mem) -> int {
        return lc.pool__cap(self)
    }

    n_link_mem__free :: #force_inline proc(self: ^N_Link_Mem, ix: N_Link_Ix) -> runtime.Allocator_Error {
        return lc.pool__free(self, u32(ix))
    }

    // Prepends addr to the list starting at head, returns the new head.
    n_link_mem__prepend :: proc(self: ^N_Link_Mem, head: N_Link_Ix, addr: N_Addr) -> (N_Link_Ix, runtime.Allocator_Error) {
        ix, err := lc.pool__alloc(self)
        if err != nil do return head, err

        link := n_link_mem__get(self, N_Link_Ix(ix))
        link.n_addr = addr
        link.next = head

        return N_Link_Ix(ix), nil
    }

    // Removes the first link with addr from the list starting at head^.
    n_link_mem__remove :: proc(self: ^N_Link_Mem, head: ^N_Link_Ix, addr: N_Addr) -> runtime.Allocator_Error {
        prev: ^N_Link = nil
        ix := head^

        for ix != N_LINK_IX__NULL {
            link := n_link_mem__get(self, ix)

            if n_addr__is_eq(link.n_addr, addr) {
                if prev != nil do prev.next = link.next
                else do head^ = link.next

                return lc.pool__free(self, u32(ix))
            }

            prev = link
            ix = link.next
        }

        return nil
    }

    // Frees every link of the list starting at head^ and sets head^ to null.
    n_link_mem__free_all :: proc(self: ^N_Link_Mem, head: ^N_Link_Ix) -> runtime.Allocator_Error {
        ix := head^
        for ix != N_LINK_IX__NULL {
            next := n_link_mem__get(self, ix).next
            lc.pool__free(self, u32(ix)) or_return
            ix = next
        }
        head^ = N_LINK_IX__NULL
        return nil
    }

    n_link_mem__contains :: proc(self: ^N_Link_Mem, head: N_Link_Ix, addr: N_Addr) -> bool {
        for link := n_link_mem__get(self, head); link != nil; link = n_link_mem__get(self, link.next) {
            if n_addr__is_eq(link.n_addr, addr) do return true
        }
        return false
    }

///////////////////////////////////////////////////////////////////////////////
// N_Cell_VP -- component (value/"p") cell. Bottom of the net, one per discrete value step.

    N_Cell_VP :: struct {
        addr: N_Addr, // useful for testing and debugging

        value: Value,
        x: int,
        y: int,
        z: int,

        parents: N_Link_Ix,
    }

///////////////////////////////////////////////////////////////////////////////
// N_Cell -- a neuron in an S_Column.

    // Position of a child relative to its parent. The child->parent link is stored in the slot
    // named after that position.
    W_Child_Pos :: enum {
        TL,
        TR,
        BL,
        BR,
    }

    N_Cell :: struct {
        addr: N_Addr,

        labels: La_Link_Ix,

        parents: [W_Child_Pos]N_Link_Ix,
        children: N_Link_Ix,

        default_sig: Value,

        // Temporary per-wave state, not persistent
        w_match_cells: [N_CELL__W_MATCH_CELLS_SIZE]W_Match_Ix,
        w_save_cells: [N_CELL__W_SAVE_CELLS_SIZE]W_Save_Cell,
        w_restore_cells: [N_CELL__W_RESTORE_CELLS_SIZE]W_Restore_Cell,
    }

    n_cell__init :: proc(self: ^N_Cell, cell_ix, column_ix, layer_ix, area_ix: int) {
        when VALIDATIONS do assert(area_ix >= N_AREA__SPECIAL_AREA_SKIP)

        self^ = {}
        self.addr = n_addr__make(cell_ix, column_ix, layer_ix, area_ix)

        when VALIDATIONS {
            assert(int(self.addr.cell_ix) == cell_ix)
            assert(int(self.addr.column_ix) == column_ix)
            assert(int(self.addr.layer_ix) == layer_ix)
            assert(int(self.addr.area_ix) == area_ix)
        }

        for &c in self.w_save_cells do c.block_id = BLOCK_ID__NOT_SET
        for &c in self.w_restore_cells do c.block_id = BLOCK_ID__NOT_SET
    }

    n_cell__is_blank :: #force_inline proc "contextless" (self: ^N_Cell) -> bool {
        return self.children == N_LINK_IX__NULL
    }

    n_cell__is_null_cell :: #force_inline proc "contextless" (self: ^N_Cell) -> bool {
        return self.addr.cell_ix == 0
    }

    n_cell__has_parents :: #force_inline proc "contextless" (self: ^N_Cell) -> bool {
        for p in self.parents do if p != N_LINK_IX__NULL do return true
        return false
    }

    n_cell__children_prepend :: proc(self: ^N_Cell, link_mem: ^N_Link_Mem, addr: N_Addr) -> runtime.Allocator_Error {
        self.children = n_link_mem__prepend(link_mem, self.children, addr) or_return

        // For every child we have plus sig potential, that should be overcome by child signal
        self.default_sig += 1

        return nil
    }

    // Links a new parent cell (self, in s_column) to VP children.
    n_cell__vp_save :: proc(self: ^N_Cell, link_mem: ^N_Link_Mem, children: []^W_Cell_P) -> runtime.Allocator_Error {
        #reverse for w_cell_p in children {
            when VALIDATIONS do assert(w_cell_p != nil && w_cell_p.n_cell_vp != nil)

            n_cell__children_prepend(self, link_mem, w_cell_p.n_cell_vp.addr) or_return

            vp := w_cell_p.n_cell_vp
            vp.parents = n_link_mem__prepend(&w_cell_p.s_column_comp.link_mem, vp.parents, self.addr) or_return
        }
        return nil
    }

    // Links a new parent cell (self, in s_column) to N children.
    n_cell__save :: proc(self: ^N_Cell, link_mem: ^N_Link_Mem, children: []W_Child) -> runtime.Allocator_Error {
        #reverse for &child in children {
            w_cell := child.w_cell

            // Out of bounds situation
            if w_cell == nil do continue

            when VALIDATIONS do assert(w_cell__is_set(w_cell))

            child_column := w_cell.s_column
            child_n_cell := w_cell__n_cell(w_cell)

            n_cell__children_prepend(self, link_mem, child_n_cell.addr) or_return

            // NOTE: link from child to parent is saved in the slot named after the child's position
            // relative to the parent. Allocating in child_column.link_mem never moves child_n_cell.
            slot := &child_n_cell.parents[child.child_pos]
            slot^ = n_link_mem__prepend(&child_column.link_mem, slot^, self.addr) or_return
        }
        return nil
    }

    n_cell__prepend_label :: proc(self: ^N_Cell, la_ix: int, la_link_mem: ^La_Link_Mem) -> runtime.Allocator_Error {
        self.labels = la_link_mem__prepend(la_link_mem, self.labels, la_ix) or_return
        return nil
    }

    n_cell__remove_link_to_label :: proc(self: ^N_Cell, la_ix: int, la_link_mem: ^La_Link_Mem) -> runtime.Allocator_Error {
        return la_link_mem__remove(la_link_mem, &self.labels, la_ix)
    }

    // Removes links to parent from every child->parent slot.
    n_cell__remove_links_to_parent :: proc(self: ^N_Cell, parent: N_Addr, link_mem: ^N_Link_Mem) -> runtime.Allocator_Error {
        for &slot in self.parents do n_link_mem__remove(link_mem, &slot, parent) or_return
        return nil
    }

    n_cell__get_and_reset_match_cell :: proc(
        self: ^N_Cell,
        block_id: Block_Id,
        wave_ix: int,
        match_cell_mem: ^W_Match_Cell_Mem,
    ) -> (match_ix: W_Match_Ix, err: runtime.Allocator_Error) {
        match_ix = self.w_match_cells[wave_ix]

        match_cell := w_match_cell_mem__get_owned(match_cell_mem, match_ix, self.addr)
        if match_cell == nil {
            match_ix = w_match_cell_mem__alloc(match_cell_mem) or_return
            self.w_match_cells[wave_ix] = match_ix
            w_match_cell__init(w_match_cell_mem__get(match_cell_mem, match_ix), self.addr, block_id)
            return
        }

        if match_cell.block_id != block_id do w_match_cell__init(match_cell, self.addr, block_id)

        return
    }

///////////////////////////////////////////////////////////////////////////////
// N_Located_Cell -- result of looking up an N_Addr in S.

    N_Located_N :: struct {
        n_cell: ^N_Cell,
        s_column: ^S_Column,
    }

    N_Located_VP :: struct {
        n_cell_vp: ^N_Cell_VP,
        s_column_comp: ^S_Column_Comp,
        s_layer_comp: ^S_Layer_Comp,
    }

    N_Located_Cell :: union {
        N_Located_N,
        N_Located_VP,
    }
