/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

///////////////////////////////////////////////////////////////////////////////
// Config -- brain configuration. All "_size" fields are (initial) capacities.
//
// The C version had one Lu_Mem per subsystem here; memory now comes from the single allocator
// passed to brain__init.

    Config :: struct {
        //
        // Brain
        //
        b_id: int,                              // optional, to identify brain by unique id
        b_recs_size: int,                       // maximum number of recs

        //
        // Space
        //
        s_areas_size: int,                      // initial number of areas
        s_column_h: int,                        // initial n_cells per s_column (grows x2)

        //
        // Network
        //
        n_link_mem_size: int,                   // initial links per link pool (grows x2)

        //
        // Waves
        //
        w_save_waves_size: int,                 // <= N_CELL__W_SAVE_CELLS_SIZE
        w_match_waves_size: int,                // <= N_CELL__W_MATCH_CELLS_SIZE
        w_match_sig_breakpoint: Value,          // (0, 1]
        w_match_processor_queue_size: int,
        w_match_results_size: int,
        w_match_cells_size_per_wave: int,
        w_delete_waves_size: int,
        w_restore_waves_size: int,              // <= N_CELL__W_RESTORE_CELLS_SIZE

        //
        // Labels
        //
        la_labels_size: int,
        la_link_mem_size: int,
    }

    Config_Type :: enum {
        Default,
        Semeion_01,
        Semeion_02,
    }

    CONFIGS :: [Config_Type]Config {
        .Default = {
            b_id = 0,
            b_recs_size = 3,
            s_areas_size = 16,
            s_column_h = 64,
            n_link_mem_size = 64 * 3 * 2,
            w_save_waves_size = 1,
            w_match_waves_size = 1,
            w_match_sig_breakpoint = 0.6,
            w_match_processor_queue_size = 1024,
            w_match_results_size = 3,
            w_match_cells_size_per_wave = 1024,
            w_delete_waves_size = 1,
            w_restore_waves_size = 1,
            la_labels_size = 128,
            la_link_mem_size = 1024,
        },
        .Semeion_01 = {
            b_id = 0,
            b_recs_size = 1,
            s_areas_size = 16,
            s_column_h = 1000,
            n_link_mem_size = 15000,
            w_save_waves_size = 1,
            w_match_waves_size = 1,
            w_match_sig_breakpoint = 0.44,
            w_match_processor_queue_size = 1000000,
            w_match_results_size = 3,
            w_match_cells_size_per_wave = 2000000,
            w_delete_waves_size = 1,
            w_restore_waves_size = 1,
            la_labels_size = 11,
            la_link_mem_size = 2000,
        },
        .Semeion_02 = {
            b_id = 0,
            b_recs_size = 1,
            s_areas_size = 16,
            s_column_h = 1000,
            n_link_mem_size = 6000,
            w_save_waves_size = 1,
            w_match_waves_size = 1,
            w_match_sig_breakpoint = 0.44,
            w_match_processor_queue_size = 100000,
            w_match_results_size = 3,
            w_match_cells_size_per_wave = 200000,
            w_delete_waves_size = 1,
            w_restore_waves_size = 1,
            la_labels_size = 11,
            la_link_mem_size = 2000,
        },
    }

    config__validate :: proc(self: ^Config) -> Error {
        if self.b_recs_size <= 0 do return API_Error.Invalid_Config
        if self.s_areas_size <= 0 do return API_Error.Invalid_Config
        if self.s_column_h <= 1 do return API_Error.Invalid_Config
        if self.n_link_mem_size <= 1 do return API_Error.Invalid_Config
        if self.w_save_waves_size <= 0 || self.w_save_waves_size > N_CELL__W_SAVE_CELLS_SIZE do return API_Error.Invalid_Config
        if self.w_match_waves_size <= 0 || self.w_match_waves_size > N_CELL__W_MATCH_CELLS_SIZE do return API_Error.Invalid_Config
        if self.w_match_waves_size > LA_CELL__MATCH_CELLS_SIZE do return API_Error.Invalid_Config
        if self.w_restore_waves_size <= 0 || self.w_restore_waves_size > N_CELL__W_RESTORE_CELLS_SIZE do return API_Error.Invalid_Config
        if self.w_delete_waves_size <= 0 do return API_Error.Invalid_Config
        if self.w_match_sig_breakpoint <= 0 || self.w_match_sig_breakpoint > 1 do return API_Error.Invalid_Config
        if self.w_match_processor_queue_size <= 0 do return API_Error.Invalid_Config
        if self.w_match_results_size <= 0 do return API_Error.Invalid_Config
        if self.w_match_cells_size_per_wave <= 1 do return API_Error.Invalid_Config
        if self.la_labels_size <= 0 do return API_Error.Invalid_Config
        if self.la_link_mem_size <= 1 do return API_Error.Invalid_Config

        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Rec_Config -- receiver config.

    // At this moment every component uses the same v and p config, but the S architecture
    // already allows per-component configs.
    Rec_Comp_Config :: struct {
        v_min: Value,
        v_max: Value,
        v_neu_size: int, // TODO: used by the V (value) view, which is not ported yet
        p_neu_size: int,
    }

    Rec_Config :: struct {
        comp_config: Rec_Comp_Config,
    }

    Rec_Config_Type :: enum {
        Mono1_Image,
        Rgb8_Image,
        Test1,
    }

    REC_CONFIGS :: [Rec_Config_Type]Rec_Config {
        .Mono1_Image = { comp_config = { v_min = 0, v_max = 1, v_neu_size = 2, p_neu_size = 2 } },
        .Rgb8_Image = { comp_config = { v_min = 0, v_max = 255, v_neu_size = 256, p_neu_size = 128 } },
        .Test1 = { comp_config = { v_min = 0, v_max = 10, v_neu_size = 10, p_neu_size = 2 } },
    }

    rec_comp_config__validate :: proc(self: ^Rec_Comp_Config) -> Error {
        if self.v_max <= self.v_min do return API_Error.Invalid_Config
        if self.p_neu_size <= 0 do return API_Error.Invalid_Config
        return nil
    }

    rec_config__validate :: proc(self: ^Rec_Config) -> Error {
        return rec_comp_config__validate(&self.comp_config)
    }

    rec_config__get_comp_config :: proc(self: ^Rec_Config, comp_ix: int) -> ^Rec_Comp_Config {
        return &self.comp_config
    }
