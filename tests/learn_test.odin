/*
    2026 (c) Zaya, https://github.com/zm69

    Tests for link weights, label groups, pattern weights (idf / purity) and reinforce.
*/
package lu_brain__tests

// Core
    import "core:testing"

// Lu
    import lu "../src"

///////////////////////////////////////////////////////////////////////////////
// Helpers

    // Per-sample labels on level 1, Sum scoring, net and match limited to level 1.
    @(private="file")
    learn__config :: proc() -> lu.Config {
        config := lu.CONFIGS[.Default]
        config.s_save_max_level = 1
        config.w_match_max_level = 1
        config.w_match_label_scoring = .Sum
        config.w_delete_keep_labeled = true
        return config
    }

    @(private="file")
    learn__save :: proc(t: ^testing.T, f: ^Fixture, wave: ^lu.Save_Wave, digit: int, label: int, group: int) {
        testing.expect(t, lu.push(wave, f.rec, BLANK_3X5[:], 3, 5, 1) == nil)
        testing.expect(t, lu.push(wave, f.rec, DIGITS_3X5[digit][:], 3, 5, 1) == nil)
        testing.expect(t, lu.save(wave) == nil)
        _, err := lu.link_level_to_label(wave, f.rec, 1, label)
        testing.expect(t, err == nil)
        testing.expect(t, lu.set_label_group(&f.brain, label, group) == nil)
    }

    @(private="file")
    learn__score :: proc(results: []lu.Label, label: int) -> lu.Value {
        for r in results do if r.id == label do return r.sig
        return 0
    }

    // Saves digit 3 (label 0, group 3) and digit 9 (label 1, group 9), then matches digit 3.
    @(private="file")
    learn__match_3 :: proc(t: ^testing.T, config: lu.Config) -> (score_0, score_1: lu.Value) {
        f: Fixture
        fixture__init(t, &f, config, 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        learn__save(t, &f, &s_wave, 3, 0, 3)
        learn__save(t, &f, &s_wave, 9, 1, 9)

        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)

        results := match_pattern(t, &m_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[3][:], 3, 5)
        return learn__score(results, 0), learn__score(results, 1)
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    link_weight__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, learn__config(), 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        learn__save(t, &f, &s_wave, 3, 0, 3)

        cells, _ := lu.label_cells(&f.brain, 0)
        defer delete(cells)
        addr := cells[0]

        w, ok := lu.link_weight(&f.brain, addr, 0)
        testing.expect(t, ok)
        testing.expect_value(t, w, 1.0)

        _, ok = lu.link_weight(&f.brain, addr, 5) // not linked
        testing.expect(t, !ok)

        testing.expect(t, lu.adjust_link_weight(&f.brain, addr, 0, -10))
        w, _ = lu.link_weight(&f.brain, addr, 0)
        testing.expect_value(t, w, 0.0)

        testing.expect(t, lu.adjust_link_weight(&f.brain, addr, 0, 100))
        w, _ = lu.link_weight(&f.brain, addr, 0)
        testing.expect_value(t, w, lu.LA_LINK__WEIGHT_MAX)

        testing.expect_value(t, lu.set_label_group(&f.brain, 9999, 1), lu.Error(lu.API_Error.Label_Out_Of_Range))
    }

    @(test)
    pattern_weights__test :: proc(t: ^testing.T) {
        plain_0, plain_1 := learn__match_3(t, learn__config())

        // 8 patches, all fire fully for the exact match
        testing.expect_value(t, plain_0, 8.0)
        testing.expect(t, plain_1 > 0 && plain_1 < plain_0)

        // purity: patches shared by '3' and '9' count half, so '9' (which only shares) loses more
        config := learn__config()
        config.w_match_purity_power = 1
        purity_0, purity_1 := learn__match_3(t, config)
        testing.expect(t, purity_0 < plain_0)
        testing.expect(t, purity_1 / purity_0 < plain_1 / plain_0)

        // idf: with 2 labels, shared patches get log(3/2), unique ones log(3)
        config = learn__config()
        config.w_match_idf_power = 1
        idf_0, idf_1 := learn__match_3(t, config)
        testing.expect(t, idf_0 > 0)
        testing.expect(t, idf_1 / idf_0 < plain_1 / plain_0)
    }

    @(test)
    reinforce__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, learn__config(), 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        learn__save(t, &f, &s_wave, 3, 0, 3)
        learn__save(t, &f, &s_wave, 9, 1, 9)

        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)

        results := match_pattern(t, &m_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[3][:], 3, 5)
        before_0 := learn__score(results, 0)

        // pretend '3' was the wrong answer: weaken label 0 where it differs from label 1
        result, err := lu.reinforce(&m_wave, f.rec, 1, 1, 0, 0.5)
        testing.expect(t, err == nil)
        testing.expect(t, result.demoted > 0)

        results = match_pattern(t, &m_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[3][:], 3, 5)
        after_0 := learn__score(results, 0)
        testing.expect(t, after_0 < before_0)

        // shared patches were not touched
        cells_0, _ := lu.label_cells(&f.brain, 0)
        defer delete(cells_0)
        cells_1, _ := lu.label_cells(&f.brain, 1)
        defer delete(cells_1)
        for a in cells_0 {
            shared := false
            for b in cells_1 do if lu.n_addr__is_eq(a, b) do shared = true
            if shared {
                w, _ := lu.link_weight(&f.brain, a, 0)
                testing.expect_value(t, w, 1.0)
            }
        }
    }
