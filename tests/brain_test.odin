/*
    2026 (c) Zaya, https://github.com/zm69

    Ports of the C test_brain_01 .. test_brain_05: save patterns, then match, delete or restore them.
*/
package lu_brain__tests

// Core
    import "core:testing"

// Lu
    import lu "../src"

///////////////////////////////////////////////////////////////////////////////
// brain_01 -- 3x3 rec, 2x2 patterns

    @(test)
    brain_01__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 3, 1)
        defer fixture__terminate(t, &f)

        blank := [4]lu.Value{}
        values := [5][4]lu.Value{
            { 1, 0,
              0, 0 },
            { 0, 1,
              0, 0 },
            { 1, 0,
              1, 1 },
            { 1, 0,
              0, 1 },
            { 0, 0,
              1, 0 },
        }
        labels := [5]int{ 0, 1, 2, 3, 4 }

        //
        // Save
        //
        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)

        testing.expect_value(t, s_wave.wave_ix, 0)
        testing.expect(t, lu.get_wave(&f.brain, s_wave.wave_ix, .Save) == &s_wave.wave)

        for i in 0..<4 do save_pattern(t, &s_wave, f.rec, blank[:], values[i][:], 2, 2, labels[i])

        //
        // Match
        //
        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)

        testing.expect_value(t, m_wave.wave_ix, 0)
        testing.expect(t, lu.get_wave(&f.brain, m_wave.wave_ix, .Match) == &m_wave.wave)

        for i in 0..<4 {
            results := match_pattern(t, &m_wave, f.rec, blank[:], values[i][:], 2, 2)
            testing.expect_value(t, top_label(results), labels[i])
        }

        // unseen pattern is closest to label 0
        results := match_pattern(t, &m_wave, f.rec, blank[:], values[4][:], 2, 2)
        testing.expect_value(t, top_label(results), labels[0])
    }

///////////////////////////////////////////////////////////////////////////////
// brain_02 -- save and match 12 digit patterns

    @(test)
    brain_02__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        save_all_digits(t, &f, &s_wave)

        m_wave: lu.Match_Wave
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)
        match_all_digits(t, &f, &m_wave)
    }

///////////////////////////////////////////////////////////////////////////////
// brain_03 -- low breakpoint, match patterns that were never saved

    @(test)
    brain_03__test :: proc(t: ^testing.T) {
        blank := [15]lu.Value{}
        patterns := [6][15]lu.Value{
            {
                1, 0, 0,
                1, 0, 0,
                1, 0, 0,
                1, 0, 0,
                1, 0, 0,
            },
            {
                0, 0, 1,
                0, 0, 1,
                0, 0, 1,
                0, 0, 1,
                0, 0, 1,
            },
            {
                1, 0, 0,
                0, 0, 0,
                0, 1, 0,
                1, 0, 0,
                1, 0, 1,
            },
            {
                1, 1, 1,
                1, 0, 1,
                1, 1, 1,
                0, 1, 1,
                1, 0, 1,
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
        }

        config := lu.CONFIGS[.Default]
        config.w_match_sig_breakpoint = 0.2

        f: Fixture
        fixture__init(t, &f, config, 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)

        // only the first two patterns are saved
        for i in 0..<2 do save_pattern(t, &s_wave, f.rec, blank[:], patterns[i][:], 3, 5, i)

        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)

        testing.expect_value(t, top_label(match_pattern(t, &m_wave, f.rec, blank[:], patterns[2][:], 3, 5)), 0)
        testing.expect_value(t, top_label(match_pattern(t, &m_wave, f.rec, blank[:], patterns[3][:], 3, 5)), 1)
        testing.expect_value(t, top_label(match_pattern(t, &m_wave, f.rec, blank[:], patterns[4][:], 3, 5)), 1)

        top := top_label(match_pattern(t, &m_wave, f.rec, blank[:], patterns[5][:], 3, 5))
        testing.expect(t, top == 0 || top == 1)
    }

///////////////////////////////////////////////////////////////////////////////
// brain_04 -- delete every label, the net must end up empty

    @(test)
    brain_04__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        save_all_digits(t, &f, &s_wave)

        m_wave: lu.Match_Wave
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)
        match_all_digits(t, &f, &m_wave)

        testing.expect(t, lu.get_net_stats(&f.brain).cells_count > 0)

        d_wave: lu.Delete_Wave
        testing.expect(t, lu.delete_wave_init(&d_wave, &f.brain) == nil)
        defer testing.expect(t, lu.delete_wave_terminate(&d_wave) == nil)

        for label in DIGIT_LABELS do testing.expect(t, lu.delete_label(&d_wave, label) == nil)

        testing.expect_value(t, lu.get_net_stats(&f.brain).cells_count, 0)
    }

///////////////////////////////////////////////////////////////////////////////
// brain_05 -- restore values from every label

    @(test)
    brain_05__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        save_all_digits(t, &f, &s_wave)

        r_wave: lu.Restore_Wave
        testing.expect(t, lu.restore_wave_init(&r_wave, &f.brain) == nil)
        defer testing.expect(t, lu.restore_wave_terminate(&r_wave) == nil)

        for label in DIGIT_LABELS {
            testing.expect(t, lu.restore_from_label(&r_wave, label) == nil)

            values := lu.restore_values(&r_wave)
            testing.expect(t, values != nil)
            testing.expect_value(t, len(values), 3 * 5)
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Brain lifecycle

    @(test)
    brain_lifecycle__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 3, 1)
        defer fixture__terminate(t, &f)

        // cannot terminate while a wave is registered
        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        testing.expect_value(t, lu.brain_terminate(&f.brain), lu.Error(lu.API_Error.Waves_Still_Registered))
        testing.expect_value(t, lu.build(&f.brain), lu.Error(lu.API_Error.Waves_Still_Registered))

        // only w_save_waves_size save waves
        s_wave_2: lu.Save_Wave
        testing.expect_value(t, lu.save_wave_init(&s_wave_2, &f.brain), lu.Error(lu.API_Error.Too_Many_Waves))

        testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)

        // the freed wave_ix is reused
        testing.expect(t, lu.save_wave_init(&s_wave_2, &f.brain) == nil)
        testing.expect_value(t, s_wave_2.wave_ix, 0)
        testing.expect(t, lu.save_wave_terminate(&s_wave_2) == nil)

        // no rec slots left after b_recs_size recs
        for _ in f.brain.recs_count..<f.brain.config.b_recs_size {
            _, err := lu.add_rec(&f.brain, 2, 2, 1, lu.REC_CONFIGS[.Mono1_Image])
            testing.expect(t, err == nil)
        }
        _, err := lu.add_rec(&f.brain, 2, 2, 1, lu.REC_CONFIGS[.Mono1_Image])
        testing.expect_value(t, err, lu.Error(lu.API_Error.Too_Many_Recs))

        // rebuild with several recs
        testing.expect(t, lu.build(&f.brain) == nil)
    }

    @(test)
    brain_invalid_config__test :: proc(t: ^testing.T) {
        config := lu.CONFIGS[.Default]
        config.w_match_sig_breakpoint = 0

        brain: lu.Brain
        testing.expect_value(t, lu.brain_init(&brain, config), lu.Error(lu.API_Error.Invalid_Config))

        // a wave needs a built brain
        testing.expect(t, lu.brain_init(&brain, lu.CONFIGS[.Default]) == nil)
        s_wave: lu.Save_Wave
        testing.expect_value(t, lu.save_wave_init(&s_wave, &brain), lu.Error(lu.API_Error.Brain_Not_Built))
        testing.expect_value(t, lu.build(&brain), lu.Error(lu.API_Error.Recs_Required))
        testing.expect(t, lu.brain_terminate(&brain) == nil)
    }

///////////////////////////////////////////////////////////////////////////////
// C parity -- exact numbers produced by the original C implementation for the digits flow.

    @(test)
    c_parity__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        save_all_digits(t, &f, &s_wave)

        stats := lu.get_net_stats(&f.brain)
        testing.expect_value(t, stats.cells_count, 152)
        testing.expect_value(t, stats.links_count, 790)

        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)

        // digit 3: three results
        results := match_pattern(t, &m_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[3][:], 3, 5)
        testing.expect_value(t, lu.fired_cells_count(&m_wave), 77)
        testing.expect_value(t, len(results), 3)
        if len(results) == 3 {
            testing.expect_value(t, results[0], lu.Label{ 3, 1.0, 1 })
            testing.expect_value(t, results[1], lu.Label{ 9, 0.9375, 1 })
            testing.expect_value(t, results[2], lu.Label{ 5, 0.875, 1 })
        }

        // digit 5: label 9 ties with label 6 (same sig and count) and is hidden, as in C
        results = match_pattern(t, &m_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[5][:], 3, 5)
        testing.expect_value(t, lu.fired_cells_count(&m_wave), 72)
        testing.expect_value(t, len(results), 2)
        if len(results) == 2 {
            testing.expect_value(t, results[0], lu.Label{ 5, 1.0, 1 })
            testing.expect_value(t, results[1], lu.Label{ 6, 0.9375, 1 })
        }

        // restore digit 0
        r_wave: lu.Restore_Wave
        testing.expect(t, lu.restore_wave_init(&r_wave, &f.brain) == nil)
        defer testing.expect(t, lu.restore_wave_terminate(&r_wave) == nil)

        testing.expect(t, lu.restore_from_label(&r_wave, 0) == nil)
        expected := [15]lu.Value{ .5, .5, .5, .5, 0, .5, .5, 0, .5, .5, 0, .5, .5, .5, .5 }
        values := lu.restore_values(&r_wave)
        testing.expect_value(t, len(values), 15)
        if len(values) == 15 do for v, i in values do testing.expect_value(t, v, expected[i])

        // delete labels one by one
        d_wave: lu.Delete_Wave
        testing.expect(t, lu.delete_wave_init(&d_wave, &f.brain) == nil)
        defer testing.expect(t, lu.delete_wave_terminate(&d_wave) == nil)

        expected_cells := [12]int{ 143, 135, 123, 115, 107, 102, 94, 83, 74, 48, 30, 0 }
        expected_links := [12]int{ 736, 690, 612, 566, 520, 498, 452, 382, 335, 222, 117, 0 }

        for label, i in DIGIT_LABELS {
            testing.expect(t, lu.delete_label(&d_wave, label) == nil)
            stats = lu.get_net_stats(&f.brain)
            testing.expect_value(t, stats.cells_count, expected_cells[i])
            testing.expect_value(t, stats.links_count, expected_links[i])
        }
    }
