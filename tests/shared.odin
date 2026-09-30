/*
    2026 (c) Zaya, https://github.com/zm69

    Helpers shared by the brain tests.
*/
package lu_brain__tests

// Base
    import "base:runtime"

// Core
    import "core:testing"

// Lu
    import lu "../src"
    import lc "../src/lu_core"

///////////////////////////////////////////////////////////////////////////////
// Fixture -- brain with one rec, on a leak-tracked allocator.

    Fixture :: struct {
        mt: lc.Mem_Track,
        allocator: runtime.Allocator,
        brain: lu.Brain,
        rec: ^lu.Rec,
    }

    fixture__init :: proc(t: ^testing.T, self: ^Fixture, config: lu.Config, w, h, d: int, rec_config := lu.REC_CONFIGS[.Mono1_Image]) {
        self.allocator = lc.mem_track__init(&self.mt, context.allocator)

        testing.expect(t, lu.brain_init(&self.brain, config, self.allocator) == nil)

        err: lu.Error
        self.rec, err = lu.add_rec(&self.brain, w, h, d, rec_config)
        testing.expect(t, err == nil)
        testing.expect(t, self.rec != nil)

        testing.expect(t, lu.build(&self.brain) == nil)
    }

    // Terminates the brain and checks that everything was freed.
    fixture__terminate :: proc(t: ^testing.T, self: ^Fixture) {
        testing.expect(t, lu.brain_terminate(&self.brain) == nil)
        testing.expect(t, !lc.mem_track__check_leaks(&self.mt))
        testing.expect(t, !lc.mem_track__check_bad_frees(&self.mt))
        lc.mem_track__terminate(&self.mt)
    }

///////////////////////////////////////////////////////////////////////////////
// 3x5 digit patterns (used by brain_02, brain_04, brain_05)

    BLANK_3X5 := [15]lu.Value{}

    DIGITS_3X5 := [12][15]lu.Value{
        {
            1, 1, 1,
            1, 0, 1,
            1, 0, 1,
            1, 0, 1,
            1, 1, 1,
        },
        {
            0, 0, 1,
            0, 1, 1,
            0, 0, 1,
            0, 0, 1,
            0, 0, 1,
        },
        {
            1, 1, 1,
            0, 0, 1,
            0, 1, 0,
            1, 0, 0,
            1, 1, 1,
        },
        {
            1, 1, 1,
            0, 0, 1,
            1, 1, 1,
            0, 0, 1,
            1, 1, 1,
        },
        {
            1, 0, 1,
            1, 0, 1,
            1, 1, 1,
            0, 0, 1,
            0, 0, 1,
        },
        {
            1, 1, 1,
            1, 0, 0,
            1, 1, 1,
            0, 0, 1,
            1, 1, 1,
        },
        {
            1, 1, 1,
            1, 0, 0,
            1, 1, 1,
            1, 0, 1,
            1, 1, 1,
        },
        {
            1, 1, 1,
            1, 0, 1,
            0, 0, 1,
            0, 0, 1,
            0, 0, 1,
        },
        {
            1, 1, 1,
            1, 0, 1,
            1, 1, 1,
            1, 0, 1,
            1, 1, 1,
        },
        {
            1, 1, 1,
            1, 0, 1,
            1, 1, 1,
            0, 0, 1,
            1, 1, 1,
        },
        {
            1, 0, 0,
            0, 0, 0,
            0, 0, 0,
            0, 0, 0,
            0, 0, 0,
        },
        {
            0, 0, 0,
            0, 1, 0,
            0, 0, 0,
            0, 1, 0,
            0, 0, 0,
        },
    }

    DIGIT_LABELS := [12]int{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 14, 15 }

///////////////////////////////////////////////////////////////////////////////
// Save / match helpers

    // Seq area is the first area, its only layer sits on top of everything.
    SEQ_AREA_IX :: lu.N_AREA__SPECIAL_AREA_SKIP

    save_pattern :: proc(t: ^testing.T, wave: ^lu.Save_Wave, rec: ^lu.Rec, blank, values: []lu.Value, w, h: int, label: int) {
        testing.expect(t, lu.push(wave, rec, blank, w, h, 1) == nil)
        testing.expect(t, lu.push(wave, rec, values, w, h, 1) == nil)
        testing.expect(t, lu.save(wave) == nil)

        la_cell, err := lu.link_to_label(wave, SEQ_AREA_IX, 0, 0, 0, label)
        testing.expect(t, err == nil)
        testing.expect(t, la_cell != nil)
    }

    match_pattern :: proc(t: ^testing.T, wave: ^lu.Match_Wave, rec: ^lu.Rec, blank, values: []lu.Value, w, h: int) -> []lu.Label {
        testing.expect(t, lu.push(wave, rec, blank, w, h, 1) == nil)
        testing.expect(t, lu.push(wave, rec, values, w, h, 1) == nil)
        testing.expect(t, lu.match(wave) == nil)
        return lu.match_results(wave)
    }

    top_label :: proc(results: []lu.Label) -> int {
        if len(results) == 0 do return -1
        return results[0].id
    }

    save_all_digits :: proc(t: ^testing.T, f: ^Fixture, wave: ^lu.Save_Wave) {
        testing.expect(t, lu.save_wave_init(wave, &f.brain) == nil)
        testing.expect_value(t, wave.wave_ix, 0)
        testing.expect(t, lu.get_wave(&f.brain, wave.wave_ix, .Save) == &wave.wave)

        for &digit, i in DIGITS_3X5 {
            save_pattern(t, wave, f.rec, BLANK_3X5[:], digit[:], 3, 5, DIGIT_LABELS[i])
        }
    }

    match_all_digits :: proc(t: ^testing.T, f: ^Fixture, wave: ^lu.Match_Wave) {
        testing.expect(t, lu.match_wave_init(wave, &f.brain) == nil)
        testing.expect_value(t, wave.wave_ix, 0)
        testing.expect(t, lu.get_wave(&f.brain, wave.wave_ix, .Match) == &wave.wave)

        for &digit, i in DIGITS_3X5 {
            results := match_pattern(t, wave, f.rec, BLANK_3X5[:], digit[:], 3, 5)
            testing.expect_value(t, top_label(results), DIGIT_LABELS[i])
        }
    }
