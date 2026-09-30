/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"

///////////////////////////////////////////////////////////////////////////////
// Net_Stats

    Net_Stats :: struct {
        cells_count: int,
        cells_size: int,
        links_count: int,
        links_size: int,
    }

    net_stats__add :: proc "contextless" (self: ^Net_Stats, other: Net_Stats) {
        self.cells_count += other.cells_count
        self.cells_size += other.cells_size
        self.links_count += other.links_count
        self.links_size += other.links_size
    }

///////////////////////////////////////////////////////////////////////////////
// Brain
//
// Usage: brain__init -> brain__add_rec (one or more) -> brain__build -> create waves.
// Brain is a user-owned struct and must not move between init and terminate.

    Brain :: struct {
        allocator: runtime.Allocator,
        config: Config,

        recs: []Rec,          // b_recs_size slots
        recs_count: int,

        s: S,
        is_built: bool,

        w_manager: W_Manager,
        la_column: La_Column,
    }

    brain__init :: proc(self: ^Brain, config: Config, allocator := context.allocator) -> Error {
        self.allocator = allocator
        self.config = config
        config__validate(&self.config) or_return

        self.recs = make([]Rec, self.config.b_recs_size, allocator) or_return
        self.recs_count = 0
        self.is_built = false

        w_manager__init(&self.w_manager, &self.config, allocator) or_return
        la_column__init(&self.la_column, &self.config, allocator) or_return

        return nil
    }

    brain__terminate :: proc(self: ^Brain) -> Error {
        if !w_manager__is_empty(&self.w_manager) do return API_Error.Waves_Still_Registered

        la_column__terminate(&self.la_column) or_return

        if self.is_built {
            s__terminate(&self.s) or_return
            self.is_built = false
        }

        w_manager__terminate(&self.w_manager) or_return

        delete(self.recs, self.allocator) or_return
        self.recs = nil
        self.recs_count = 0

        return nil
    }

    brain__is_built :: #force_inline proc "contextless" (self: ^Brain) -> bool {
        return self.is_built
    }

    brain__add_rec :: proc(self: ^Brain, width, height, depth: int, config: Rec_Config) -> (rec: ^Rec, err: Error) {
        config := config
        rec_config__validate(&config) or_return

        if width <= 0 || height <= 0 || depth <= 0 do return nil, API_Error.Invalid_Argument
        if self.recs_count >= len(self.recs) do return nil, API_Error.Too_Many_Recs

        rec = &self.recs[self.recs_count]
        rec^ = Rec{
            brain = self,
            id = self.recs_count,
            width = width,
            height = height,
            depth = depth,
            config = config,
            view = rec_view__make(width, height, depth),
        }
        self.recs_count += 1

        return
    }

    brain__get_rec :: proc(self: ^Brain, rec_id: int) -> ^Rec {
        if rec_id < 0 || rec_id >= self.recs_count do return nil
        return &self.recs[rec_id]
    }

    // Builds (or rebuilds) the net after recs were added. Rebuilding drops everything learned.
    brain__build :: proc(self: ^Brain) -> Error {
        if self.recs_count == 0 do return API_Error.Recs_Required
        if !w_manager__is_empty(&self.w_manager) do return API_Error.Waves_Still_Registered

        if self.is_built {
            s__terminate(&self.s) or_return
            self.is_built = false
        }

        s__init(&self.s, &self.config, self.recs[:self.recs_count], self.allocator) or_return
        self.is_built = true

        return nil
    }

    brain__get_wave :: proc(self: ^Brain, wave_ix: int, wave_type: Wave_Type) -> ^Wave {
        return w_manager__get_wave(&self.w_manager, wave_ix, wave_type)
    }

    brain__get_net_stats :: proc(self: ^Brain) -> Net_Stats {
        if !self.is_built do return {}
        return s__get_net_stats(&self.s)
    }

    brain__print_info :: proc(self: ^Brain) {
        fmt.printf("\n\n=========> Brain #%v Info <=========", self.config.b_id)
        if self.is_built do s__print_areas(&self.s)
    }

    brain__print_areas :: proc(self: ^Brain) {
        if self.is_built do s__print_areas(&self.s)
    }

    brain__print_net_stats :: proc(self: ^Brain) {
        fmt.printf("\n\n=======================> Brain #%v Net Stats Info <=======================", self.config.b_id)
        if self.is_built do s__print_net_stats(&self.s)
    }
