/*
    2026 (c) Zaya, https://github.com/zm69

    Lu_Brain (Ludyna Brain) -- a human-like memory database.

    This file is the public API surface: defines, errors and short public aliases for the
    `typename__action` procedures that implement them.
*/
package lu_brain

// Base
    import "base:runtime"

// Lu
    import lc "lu_core"

///////////////////////////////////////////////////////////////////////////////
// Defines

    VALIDATIONS :: #config(LU_VALIDATIONS, true)

    // Verbose tracing of save / match internals.
    DEEP_DEBUG :: #config(LU_DEEP_DEBUG, false)

///////////////////////////////////////////////////////////////////////////////
// Errors

    API_Error :: enum {
        None = 0,
        Invalid_Config,
        Invalid_Argument,
        Recs_Required,
        Too_Many_Recs,
        Too_Many_Waves,
        Too_Many_Areas,
        Too_Many_Layers,
        Column_Is_Full,
        Brain_Not_Built,
        Waves_Still_Registered,
        Label_Out_Of_Range,
        W_Cell_Not_Found,
        Invalid_N_Addr,
    }

    Error :: union #shared_nil {
        API_Error,
        lc.Core_Error,
        runtime.Allocator_Error,
    }

///////////////////////////////////////////////////////////////////////////////
// Brain

    brain_init :: brain__init
    brain_terminate :: brain__terminate
    add_rec :: brain__add_rec
    get_rec :: brain__get_rec
    build :: brain__build
    get_wave :: brain__get_wave
    get_net_stats :: brain__get_net_stats
    print_info :: brain__print_info
    print_areas :: brain__print_areas
    print_net_stats :: brain__print_net_stats

///////////////////////////////////////////////////////////////////////////////
// Rec view
//
// The view belongs to the rec and is captured on every push.

    set_dest_start_pos :: proc{
        rec__set_dest_start_pos,
        save_wave__set_dest_start_pos,
        match_wave__set_dest_start_pos,
    }

    set_src_start_pos :: proc{
        rec__set_src_start_pos,
        save_wave__set_src_start_pos,
        match_wave__set_src_start_pos,
    }

    set_src_end_pos :: proc{
        rec__set_src_end_pos,
        save_wave__set_src_end_pos,
        match_wave__set_src_end_pos,
    }

    set_src_start_z :: rec__set_src_start_z
    set_src_end_z :: rec__set_src_end_z

    save_wave__set_dest_start_pos :: proc(self: ^Save_Wave, rec: ^Rec, dest_x, dest_y: int) { rec__set_dest_start_pos(rec, dest_x, dest_y) }
    save_wave__set_src_start_pos :: proc(self: ^Save_Wave, rec: ^Rec, src_x, src_y: int) { rec__set_src_start_pos(rec, src_x, src_y) }
    save_wave__set_src_end_pos :: proc(self: ^Save_Wave, rec: ^Rec, src_x, src_y: int) { rec__set_src_end_pos(rec, src_x, src_y) }
    match_wave__set_dest_start_pos :: proc(self: ^Match_Wave, rec: ^Rec, dest_x, dest_y: int) { rec__set_dest_start_pos(rec, dest_x, dest_y) }
    match_wave__set_src_start_pos :: proc(self: ^Match_Wave, rec: ^Rec, src_x, src_y: int) { rec__set_src_start_pos(rec, src_x, src_y) }
    match_wave__set_src_end_pos :: proc(self: ^Match_Wave, rec: ^Rec, src_x, src_y: int) { rec__set_src_end_pos(rec, src_x, src_y) }

///////////////////////////////////////////////////////////////////////////////
// Waves

    save_wave_init :: save_wave__init
    save_wave_terminate :: save_wave__terminate
    match_wave_init :: match_wave__init
    match_wave_terminate :: match_wave__terminate
    delete_wave_init :: delete_wave__init
    delete_wave_terminate :: delete_wave__terminate
    restore_wave_init :: restore_wave__init
    restore_wave_terminate :: restore_wave__terminate

    save_wave__push :: proc(self: ^Save_Wave, rec: ^Rec, values: []Value, w, h, d: int) -> Error { return data_wave__push(self, rec, values, w, h, d) }
    match_wave__push :: proc(self: ^Match_Wave, rec: ^Rec, values: []Value, w, h, d: int) -> Error { return data_wave__push(self, rec, values, w, h, d) }
    save_wave__block_begin :: proc(self: ^Save_Wave) { data_wave__block_begin(self) }
    match_wave__block_begin :: proc(self: ^Match_Wave) { data_wave__block_begin(self) }
    save_wave__block_end :: proc(self: ^Save_Wave) { data_wave__block_end(self) }
    match_wave__block_end :: proc(self: ^Match_Wave) { data_wave__block_end(self) }

    push :: proc{ save_wave__push, match_wave__push }
    block_begin :: proc{ save_wave__block_begin, match_wave__block_begin }
    block_end :: proc{ save_wave__block_end, match_wave__block_end }
    reset :: proc{ save_wave__reset, match_wave__reset }

    //
    // Save
    //

    save :: save_wave__save
    save_step :: save_wave__save_step
    link_to_label :: save_wave__link_to_label
    link_level_to_label :: save_wave__link_level_to_label

    //
    // Match
    //

    match :: match_wave__match
    match_step :: match_wave__match_step
    match_results :: match_wave__results
    fired_cells_count :: match_wave__fired_cells_count
    set_match_sig_breakpoint :: match_wave__set_sig_breakpoint
    print_results :: match_wave__print_results

    //
    // Delete
    //

    delete_label :: delete_wave__delete_label
    delete_neuron :: delete_wave__delete_neuron

    //
    // Restore
    //

    restore_from_label :: restore_wave__restore_from_label
    restore_from_neuron :: restore_wave__restore_from_neuron
    restore_values :: restore_wave__values
