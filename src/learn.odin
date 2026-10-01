/*
    2026 (c) Zaya, https://github.com/zm69

    Learning from mistakes: per-link weights between pattern cells and labels.

    Every cell -> label link carries a weight (1 by default, which is the C behavior). A match adds
    `cell fire sig * link weight` to the label. After a wrong decision, reinforce() lowers the
    weights of the links that made the wrong label win and raises those of the right label, but
    only on the patches where the two differ. So every change is local, explainable and reversible.
*/
package lu_brain

///////////////////////////////////////////////////////////////////////////////
// Label groups

    // Sets the group of a label (e.g. the class of a per-sample label). Used by
    // Config.w_match_purity_power. Groups outside [0, LA_GROUPS__MAX) are ignored there.
    brain__set_label_group :: proc(self: ^Brain, label: int, group: int) -> Error {
        la_cell := la_column__get_la_cell(&self.la_column, label)
        if la_cell == nil do return API_Error.Label_Out_Of_Range
        la_cell.group = group
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Link weights

    @(private="file")
    brain__find_link :: proc(self: ^Brain, addr: N_Addr, label: int) -> ^La_Link {
        n_cell := brain__get_n_cell(self, addr)
        if n_cell == nil do return nil

        link_mem := &self.la_column.la_link_mem
        for link := la_link_mem__get(link_mem, n_cell.labels); link != nil; link = la_link_mem__get(link_mem, link.next) {
            if link.la_ix == label do return link
        }
        return nil
    }

    // Weight of the link from a cell to a label; ok = false if they are not linked.
    brain__link_weight :: proc(self: ^Brain, addr: N_Addr, label: int) -> (weight: Value, ok: bool) {
        link := brain__find_link(self, addr, label)
        if link == nil do return 0, false
        return link.weight, true
    }

    // Adds delta to a link weight, clamped to [0, LA_LINK__WEIGHT_MAX]. False if not linked.
    brain__adjust_link_weight :: proc(self: ^Brain, addr: N_Addr, label: int, delta: Value) -> bool {
        link := brain__find_link(self, addr, label)
        if link == nil do return false
        link.weight = clamp(link.weight + delta, 0, LA_LINK__WEIGHT_MAX)
        return true
    }

///////////////////////////////////////////////////////////////////////////////
// Reinforce

    Reinforce_Result :: struct {
        demoted: int,   // links of `demote` weakened
        promoted: int,  // links of `promote` strengthened
    }

    // Learns from the last match of this wave, at the rec layer `level`:
    // on every fired cell linked to `demote` but not to `promote`, the demote link loses
    // rate * fire sig; on every fired cell linked to `promote` but not to `demote`, the promote
    // link gains rate * fire sig. Pass LA_IX__NULL to skip one side.
    match_wave__reinforce :: proc(
        self: ^Match_Wave,
        rec: ^Rec,
        level: int,
        promote: int,
        demote: int,
        rate: Value,
    ) -> (result: Reinforce_Result, err: Error) {
        fired := match_wave__fired_cells(self, rec, level, context.temp_allocator) or_return
        brain := self.brain

        for c in fired {
            has_promote := promote != LA_IX__NULL && brain__find_link(brain, c.addr, promote) != nil
            has_demote := demote != LA_IX__NULL && brain__find_link(brain, c.addr, demote) != nil

            if has_demote && !has_promote {
                brain__adjust_link_weight(brain, c.addr, demote, -rate * c.sig)
                result.demoted += 1
            } else if has_promote && !has_demote {
                brain__adjust_link_weight(brain, c.addr, promote, rate * c.sig)
                result.promoted += 1
            }
        }

        return
    }
