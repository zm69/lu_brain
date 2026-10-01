/*
    2026 (c) Zaya, https://github.com/zm69

    Tests for the inspection API and pattern-level editing (w_delete_keep_labeled, delete_neuron).
*/
package lu_brain__tests

// Core
    import "core:slice"
    import "core:testing"

// Lu
    import lu "../src"

///////////////////////////////////////////////////////////////////////////////
// Helpers

    // Default config, net built only up to level 1, so level-1 cells have no parents.
    @(private="file")
    inspect__config :: proc(keep_labeled: bool) -> lu.Config {
        config := lu.CONFIGS[.Default]
        config.s_save_max_level = 1
        config.w_delete_keep_labeled = keep_labeled
        return config
    }

    @(private="file")
    inspect__save :: proc(t: ^testing.T, f: ^Fixture, wave: ^lu.Save_Wave, digit: int, label: int) {
        testing.expect(t, lu.push(wave, f.rec, BLANK_3X5[:], 3, 5, 1) == nil)
        testing.expect(t, lu.push(wave, f.rec, DIGITS_3X5[digit][:], 3, 5, 1) == nil)
        testing.expect(t, lu.save(wave) == nil)
        linked, err := lu.link_level_to_label(wave, f.rec, 1, label)
        testing.expect(t, err == nil)
        testing.expect_value(t, linked, 2 * 4) // level 1 of a 3x5 rec is 2x4
    }

///////////////////////////////////////////////////////////////////////////////
// Tests

    @(test)
    inspect_labels__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, inspect__config(false), 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)

        inspect__save(t, &f, &s_wave, 3, 0)
        inspect__save(t, &f, &s_wave, 9, 1)

        cells_0, _ := lu.label_cells(&f.brain, 0)
        defer delete(cells_0)
        testing.expect_value(t, len(cells_0), 8)

        // round trip: every cell of label 0 lists label 0
        for addr in cells_0 {
            labels, _ := lu.cell_labels(&f.brain, addr)
            defer delete(labels)
            testing.expect(t, slice.contains(labels[:], 0))
            testing.expect_value(t, lu.cell_labels_count(&f.brain, lu.get_n_cell(&f.brain, addr)), len(labels))
        }

        testing.expect(t, lu.level_layer(&f.brain, f.rec, 1) != nil)
        testing.expect(t, lu.level_layer(&f.brain, f.rec, 99) == nil)
    }

    @(test)
    inspect_fired_cells__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, inspect__config(false), 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        inspect__save(t, &f, &s_wave, 3, 0)

        m_wave: lu.Match_Wave
        testing.expect(t, lu.match_wave_init(&m_wave, &f.brain) == nil)
        defer testing.expect(t, lu.match_wave_terminate(&m_wave) == nil)
        match_pattern(t, &m_wave, f.rec, BLANK_3X5[:], DIGITS_3X5[3][:], 3, 5)

        fired, err := lu.fired_cells(&m_wave, f.rec, 1)
        defer delete(fired)
        testing.expect(t, err == nil)

        cells_0, _ := lu.label_cells(&f.brain, 0)
        defer delete(cells_0)

        // an exact match fires every patch of the saved digit fully
        for addr in cells_0 {
            found := false
            for c in fired {
                if lu.n_addr__is_eq(c.addr, addr) {
                    found = true
                    testing.expect_value(t, c.sig, 1.0)
                }
            }
            testing.expect(t, found)
        }
    }

    // Deleting one sample keeps the patterns it shares with another sample when keep_labeled is set.
    @(private="file")
    inspect__delete_shared :: proc(t: ^testing.T, keep_labeled: bool) -> (live_1_after: int, shared: int) {
        f: Fixture
        fixture__init(t, &f, inspect__config(keep_labeled), 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)

        inspect__save(t, &f, &s_wave, 3, 0)
        inspect__save(t, &f, &s_wave, 9, 1)

        cells_0, _ := lu.label_cells(&f.brain, 0)
        defer delete(cells_0)
        cells_1, _ := lu.label_cells(&f.brain, 1)
        defer delete(cells_1)

        for a in cells_0 do for b in cells_1 do if lu.n_addr__is_eq(a, b) do shared += 1
        testing.expect(t, shared > 0) // 3 and 9 share patches

        d_wave: lu.Delete_Wave
        testing.expect(t, lu.delete_wave_init(&d_wave, &f.brain) == nil)
        defer testing.expect(t, lu.delete_wave_terminate(&d_wave) == nil)
        testing.expect(t, lu.delete_label(&d_wave, 0) == nil)

        // cells unique to label 0 are gone either way
        for a in cells_0 {
            in_1 := false
            for b in cells_1 do if lu.n_addr__is_eq(a, b) do in_1 = true
            if !in_1 do testing.expect(t, !lu.is_cell_live(&f.brain, a))
        }

        after, _ := lu.label_cells(&f.brain, 1)
        defer delete(after)
        return len(after), shared
    }

    @(test)
    delete_keep_labeled__test :: proc(t: ^testing.T) {
        // C behavior: shared patterns are destroyed with the deleted sample
        live_c, shared := inspect__delete_shared(t, false)
        testing.expect_value(t, live_c, 8 - shared)

        // keep_labeled: the other sample keeps all of its patterns
        live_keep, _ := inspect__delete_shared(t, true)
        testing.expect_value(t, live_keep, 8)
    }

    @(test)
    delete_neuron_unlinks_labels__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, inspect__config(true), 3, 5, 1)
        defer fixture__terminate(t, &f)

        s_wave: lu.Save_Wave
        testing.expect(t, lu.save_wave_init(&s_wave, &f.brain) == nil)
        defer testing.expect(t, lu.save_wave_terminate(&s_wave) == nil)
        inspect__save(t, &f, &s_wave, 3, 0)
        inspect__save(t, &f, &s_wave, 9, 1)

        cells_0, _ := lu.label_cells(&f.brain, 0)
        defer delete(cells_0)
        target := cells_0[0]

        d_wave: lu.Delete_Wave
        testing.expect(t, lu.delete_wave_init(&d_wave, &f.brain) == nil)
        defer testing.expect(t, lu.delete_wave_terminate(&d_wave) == nil)

        // explicit delete removes the pattern even though labels use it
        testing.expect(t, lu.delete_neuron(&d_wave, target) == nil)
        testing.expect(t, !lu.is_cell_live(&f.brain, target))

        labels, _ := lu.cell_labels(&f.brain, target)
        defer delete(labels)
        testing.expect_value(t, len(labels), 0)

        after, _ := lu.label_cells(&f.brain, 0)
        defer delete(after)
        testing.expect_value(t, len(after), 7)
        testing.expect_value(t, f.brain.la_column.cells[0].children_count, 7)
    }
