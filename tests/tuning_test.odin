/*
    2026 (c) Zaya, https://github.com/zm69

    Tests for the tunable (non-C) options: save breakpoints, label scoring, fuzzy value matching.
    With default values these options reproduce the C behavior (see c_parity__test).
*/
package lu_brain__tests

// Core
    import "core:testing"

// Lu
    import lu "../src"

///////////////////////////////////////////////////////////////////////////////
// Validation

    @(test)
    tuning_validation__test :: proc(t: ^testing.T) {
        brain: lu.Brain

        config := lu.CONFIGS[.Default]
        config.s_parent_breakpoint = 0
        testing.expect_value(t, lu.brain_init(&brain, config), lu.Error(lu.API_Error.Invalid_Config))

        config = lu.CONFIGS[.Default]
        config.s_vp_parent_breakpoint = 1.5
        testing.expect_value(t, lu.brain_init(&brain, config), lu.Error(lu.API_Error.Invalid_Config))

        testing.expect(t, lu.brain_init(&brain, lu.CONFIGS[.Default]) == nil)
        defer testing.expect(t, lu.brain_terminate(&brain) == nil)

        rec_config := lu.REC_CONFIGS[.Mono1_Image]
        rec_config.comp_config.p_null_damping = 2
        _, err := lu.add_rec(&brain, 3, 3, 1, rec_config)
        testing.expect_value(t, err, lu.Error(lu.API_Error.Invalid_Config))

        rec_config = lu.REC_CONFIGS[.Mono1_Image]
        rec_config.comp_config.p_fuzzy_radius = -1
        _, err = lu.add_rec(&brain, 3, 3, 1, rec_config)
        testing.expect_value(t, err, lu.Error(lu.API_Error.Invalid_Config))
    }

    @(test)
    set_match_sig_breakpoint__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 5, 1)
        defer fixture__terminate(t, &f)

        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)

        testing.expect(t, lu.set_match_sig_breakpoint(&m_wave, 0.3) == nil)
        testing.expect_value(t, m_wave.processor.sig_breakpoint, 0.3)
        testing.expect_value(t, lu.set_match_sig_breakpoint(&m_wave, 0), lu.Error(lu.API_Error.Invalid_Argument))
    }

///////////////////////////////////////////////////////////////////////////////
// Label scoring

    // Saves every digit and links its label to the seq top cell and to the frame layer cell, so an
    // exact match receives two signals per label.
    @(private="file")
    scoring__match_digit_3 :: proc(t: ^testing.T, scoring: lu.Label_Scoring) -> (results: [dynamic]lu.Label) {
        config := lu.CONFIGS[.Default]
        config.w_match_label_scoring = scoring

        f: Fixture
        fixture__init(t, &f, config, 3, 5, 1)
        defer fixture__terminate(t, &f)

        frame_area_ix := lu.s__get_area_by_tag(&f.brain.s, .Frame).area_ix

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)

        for &digit, i in DIGITS_3X5 {
            save_pattern(t, &s_wave, f.rec, BLANK_3X5[:], digit[:], 3, 5, DIGIT_LABELS[i])
            _, err := lu.link_to_label(&s_wave, frame_area_ix, 0, 0, 0, DIGIT_LABELS[i])
            testing.expect(t, err == nil)
        }

        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)

        for label in match_pattern(t, &m_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[3][:], 3, 5) do append(&results, label)
        return
    }

    @(test)
    label_scoring__test :: proc(t: ^testing.T) {
        max_results := scoring__match_digit_3(t, .Max)
        defer delete(max_results)
        sum_results := scoring__match_digit_3(t, .Sum)
        defer delete(sum_results)
        mean_results := scoring__match_digit_3(t, .Mean)
        defer delete(mean_results)

        testing.expect_value(t, top_label(max_results[:]), 3)
        testing.expect_value(t, top_label(sum_results[:]), 3)
        testing.expect_value(t, top_label(mean_results[:]), 3)

        if len(max_results) > 0 && len(sum_results) > 0 && len(mean_results) > 0 {
            // two linked cells both fire fully for an exact match
            testing.expect_value(t, max_results[0].sig, 1.0)
            testing.expect_value(t, sum_results[0].sig, 2.0)
            testing.expect_value(t, mean_results[0].sig, 1.0)
            testing.expect_value(t, sum_results[0].sig_received_count, 2)
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Fuzzy value matching

    // Saves a grayscale pattern, then matches a copy where one pixel moved to the neighbouring value
    // step. Returns the fired cell count and the results.
    @(private="file")
    fuzzy__match :: proc(t: ^testing.T, fuzzy_radius: int) -> (fired: int, top: int) {
        rec_config := lu.Rec_Config{ comp_config = { v_min = 0, v_max = 1, v_neu_size = 4, p_neu_size = 4, p_fuzzy_radius = fuzzy_radius } }

        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 3, 1, rec_config)
        defer fixture__terminate(t, &f)

        blank := [9]lu.Value{}
        saved := [9]lu.Value{
            0.9, 0.9, 0,
            0.9, 0.9, 0,
            0,   0,   0,
        }
        // top-left pixel is one step lower
        probe := [9]lu.Value{
            0.6, 0.9, 0,
            0.9, 0.9, 0,
            0,   0,   0,
        }

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        save_pattern(t, &s_wave, f.rec, blank[:], saved[:], 3, 3, 7)

        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)

        results := match_pattern(t, &m_wave, f.rec, blank[:], probe[:], 3, 3)
        return lu.fired_cells_count(&m_wave), top_label(results)
    }

    @(test)
    fuzzy_matching__test :: proc(t: ^testing.T) {
        fired_exact, _ := fuzzy__match(t, 0)
        fired_fuzzy, top_fuzzy := fuzzy__match(t, 1)

        // the neighbouring value step now contributes a partial signal
        testing.expect(t, fired_fuzzy > fired_exact)
        testing.expect_value(t, top_fuzzy, 7)
    }

///////////////////////////////////////////////////////////////////////////////
// Match propagation limit

    @(test)
    match_max_level__test :: proc(t: ^testing.T) {
        config := lu.CONFIGS[.Default]
        config.w_match_max_level = 1

        f: Fixture
        fixture__init(t, &f, config, 3, 5, 1)
        defer fixture__terminate(t, &f)

        rec_area := lu.s__get_rec_area(&f.brain.s, 0)

        // level 1 = first N layer above the rec base
        level_1_ix := -1
        for layer, li in rec_area.layers {
            if n, ok := layer.(^lu.S_Layer_N); ok && n.level == 1 do level_1_ix = li
        }
        testing.expect(t, level_1_ix > 0)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)

        // digit 0 is linked at the top (seq) only, digit 1 at level 1 only
        save_pattern(t, &s_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[0][:], 3, 5, 0)

        testing.expect(t, lu.push(&s_wave, f.rec, BLANK_3X5[:], 3, 5, 1) == nil)
        testing.expect(t, lu.push(&s_wave, f.rec, DIGITS_3X5[1][:], 3, 5, 1) == nil)
        testing.expect(t, lu.save(&s_wave) == nil)
        _, err := lu.link_to_label(&s_wave, rec_area.area_ix, level_1_ix, 0, 0, 1)
        testing.expect(t, err == nil)

        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)

        // the seq top is never reached
        testing.expect_value(t, len(match_pattern(t, &m_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[0][:], 3, 5)), 0)

        // level 1 labels still fire
        testing.expect_value(t, top_label(match_pattern(t, &m_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[1][:], 3, 5)), 1)

        // validation
        config.w_match_max_level = -1
        brain: lu.Brain
        testing.expect_value(t, lu.brain_init(&brain, config), lu.Error(lu.API_Error.Invalid_Config))
    }

///////////////////////////////////////////////////////////////////////////////
// link_level_to_label

    @(test)
    link_level_to_label__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)

        testing.expect(t, lu.push(&s_wave, f.rec, BLANK_3X5[:], 3, 5, 1) == nil)
        testing.expect(t, lu.push(&s_wave, f.rec, DIGITS_3X5[0][:], 3, 5, 1) == nil)
        testing.expect(t, lu.save(&s_wave) == nil)

        // level 1 of a 3x5 rec is 2x4
        linked, err := lu.link_level_to_label(&s_wave, f.rec, 1, 0)
        testing.expect(t, err == nil)
        testing.expect_value(t, linked, 2 * 4)
        testing.expect_value(t, f.brain.la_column.cells[0].children_count, 2 * 4)

        _, err = lu.link_level_to_label(&s_wave, f.rec, 99, 0)
        testing.expect_value(t, err, lu.Error(lu.API_Error.Invalid_Argument))
    }
