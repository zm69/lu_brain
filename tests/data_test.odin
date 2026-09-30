/*
    2026 (c) Zaya, https://github.com/zm69

    Data_Seq, Comp_Calc, N_Addr and S layout tests (ports of test_lu_story.c and test_comp_calc.c).
*/
package lu_brain__tests

// Core
    import "core:testing"

// Lu
    import lu "../src"
    import lc "../src/lu_core"

///////////////////////////////////////////////////////////////////////////////
// Data_Seq

    DATA_00 := [9]lu.Value{ 0, 0, 0, 1, 1, 1, 1, 1, 1 }
    DATA_01 := [9]lu.Value{ 1, 0, 0, 1, 1, 1, 1, 1, 1 }
    DATA_02 := [9]lu.Value{ 2, 0, 0, 1, 1, 1, 1, 1, 1 }
    DATA_04 := [9]lu.Value{ 4, 0, 0, 1, 1, 1, 1, 1, 1 }
    DATA_05 := [9]lu.Value{ 5, 0, 0, 1, 1, 1, 1, 1, 1 }
    DATA_12 := [4]lu.Value{ 2, 0, 1, 1 }
    DATA_13 := [4]lu.Value{ 3, 0, 1, 1 }
    DATA_16 := [4]lu.Value{ 6, 0, 1, 1 }

    @(test)
    data_seq__test :: proc(t: ^testing.T) {
        mt: lc.Mem_Track
        allocator := lc.mem_track__init(&mt, context.allocator)
        defer lc.mem_track__terminate(&mt)

        view_0 := lu.rec_view__make(3, 3, 1)
        view_1 := lu.rec_view__make(2, 2, 1)

        seq: lu.Data_Seq
        testing.expect(t, lu.data_seq__init(&seq, 0, 2, allocator) == nil)

        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 0)
        testing.expect(t, lu.data_seq__get_last_values(&seq, 0) == nil)

        lu.data_seq__push(&seq, 0, DATA_00[:], 3, 3, 1, view_0)
        testing.expect_value(t, lu.data_seq__get_last_values(&seq, 0)[0], 0)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 1)

        // rec 0 already has data in the last block -> new block
        lu.data_seq__push(&seq, 0, DATA_01[:], 3, 3, 1, view_0)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 2)

        // rec 1 has no data in the last block -> same block
        lu.data_seq__push(&seq, 1, DATA_12[:], 2, 2, 1, view_1)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 2)
        testing.expect_value(t, lu.data_seq__get_last_values(&seq, 0)[0], 1)
        testing.expect_value(t, lu.data_seq__get_last_values(&seq, 1)[0], 2)

        lu.data_seq__block_begin(&seq)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 2)

        lu.data_seq__push(&seq, 0, DATA_02[:], 3, 3, 1, view_0)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 3)

        lu.data_seq__push(&seq, 1, DATA_13[:], 2, 2, 1, view_1)
        testing.expect_value(t, lu.data_seq__get_last_values(&seq, 1)[0], 3)

        lu.data_seq__block_end(&seq)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 3)

        lu.data_seq__push(&seq, 0, DATA_04[:], 3, 3, 1, view_0)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 4)

        // reading: first block is flagged, block ids are sequential
        block := lu.data_seq__next_block(&seq)
        testing.expect(t, .Reset_Recs in block.flags)
        testing.expect_value(t, block.block_id.block_ix, 0)
        count := 1
        for b := lu.data_seq__next_block(&seq); b != nil; b = lu.data_seq__next_block(&seq) do count += 1
        testing.expect_value(t, count, 4)

        lu.data_seq__reset(&seq)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 0)

        lu.data_seq__block_begin(&seq)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 0)

        lu.data_seq__push(&seq, 0, DATA_05[:], 3, 3, 1, view_0)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 1)

        // block ixs keep growing after reset
        testing.expect_value(t, lu.data_seq__get_last_data(&seq, 0).block_id.block_ix, 4)

        lu.data_seq__push(&seq, 1, DATA_16[:], 2, 2, 1, view_1)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 1)

        data := lu.data_seq__get_last_data(&seq, 1)
        testing.expect_value(t, data.values[0], 6)
        testing.expect_value(t, data.w, 2)
        testing.expect_value(t, data.h, 2)

        data = lu.data_seq__get_last_data(&seq, 0)
        testing.expect_value(t, data.values[0], 5)
        testing.expect_value(t, data.w, 3)
        testing.expect_value(t, data.h, 3)

        testing.expect(t, lu.data_seq__terminate(&seq) == nil)
        testing.expect(t, !lc.mem_track__check_leaks(&mt))
    }

    @(test)
    data_seq_blocks__test :: proc(t: ^testing.T) {
        seq: lu.Data_Seq
        testing.expect(t, lu.data_seq__init(&seq, 0, 2, context.allocator) == nil)
        defer lu.data_seq__terminate(&seq)

        lu.data_seq__block_begin(&seq)
        lu.data_seq__block_begin(&seq)
        lu.data_seq__block_begin(&seq)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 0)
        testing.expect(t, lu.data_seq__get_last_values(&seq, 0) == nil)

        lu.data_seq__block_end(&seq)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 0)
        lu.data_seq__block_end(&seq)

        lu.data_seq__push(&seq, 0, DATA_00[:], 3, 3, 1, lu.rec_view__make(3, 3, 1))
        lu.data_seq__block_begin(&seq)
        lu.data_seq__block_begin(&seq)
        testing.expect_value(t, lu.data_seq__get_last_values(&seq, 0)[0], 0)
        testing.expect_value(t, lu.data_seq__blocks_count(&seq), 1)
    }

///////////////////////////////////////////////////////////////////////////////
// Comp_Calc

    @(test)
    comp_calc__test :: proc(t: ^testing.T) {
        values := [18]lu.Value{
            0, 0, 0,
            1, 2.4, 1,
            1, 1, 1,

            1, 3, 4,
            7, 2.4, 3.8,
            6, 6, 6,
        }

        data: lu.Data
        testing.expect(t, lu.data__init_copy(&data, values[:], 3, 3, 2, context.allocator) == nil)
        defer lu.data__terminate(&data, context.allocator)

        testing.expect_value(t, lu.data__get_value(&data, 1, 1, 0), 2.4)
        testing.expect_value(t, lu.data__get_value(&data, 1, 1, 1), 2.4)

        cc: lu.Comp_Calc
        testing.expect(t, lu.comp_calc__init(&cc, 2, 5, 6, context.allocator) == nil)
        defer lu.comp_calc__terminate(&cc)

        lu.comp_calc__digitalize_data(&cc, &data, 1)

        testing.expect_value(t, lu.data__get_value(&data, 1, 1, 0), 2.4)
        testing.expect_value(t, lu.data__get_value(&data, 1, 1, 1), 0)
        testing.expect_value(t, lu.data__get_value(&data, 2, 1, 1), 1.5)
    }

    @(test)
    calc__test :: proc(t: ^testing.T) {
        testing.expect_value(t, lu.calc__layers_count(1, 1), 1)
        testing.expect_value(t, lu.calc__layers_count(3, 1), 1)
        testing.expect_value(t, lu.calc__layers_count(4, 1), 2)
        testing.expect_value(t, lu.calc__expected_child_size(1, 1), 1)
        testing.expect_value(t, lu.calc__expected_child_size(1, 5), 2)
        testing.expect_value(t, lu.calc__expected_child_size(3, 5), 4)
        testing.expect(t, lu.calc__is_last_layer(2, 2))
        testing.expect(t, !lu.calc__is_last_layer(3, 2))
    }

///////////////////////////////////////////////////////////////////////////////
// N_Addr

    @(test)
    n_addr__test :: proc(t: ^testing.T) {
        testing.expect_value(t, size_of(lu.N_Addr), 8)

        a := lu.n_addr__make(3, 70000, 12, 4)
        testing.expect_value(t, a.cell_ix, 3)
        testing.expect_value(t, a.column_ix, 70000)
        testing.expect_value(t, a.layer_ix, 12)
        testing.expect_value(t, a.area_ix, 4)

        testing.expect(t, lu.n_addr__is_blank(lu.N_ADDR__NULL))
        testing.expect(t, lu.n_addr__is_present(a))

        inactive := lu.N_Addr{ area_ix = lu.N_AREA__INACTIVE }
        testing.expect(t, !lu.n_addr__is_eq(inactive, lu.N_ADDR__NULL))

        b := lu.n_addr__make(9, 70000, 12, 4)
        testing.expect(t, !lu.n_addr__is_eq(a, b))
        testing.expect(t, lu.n_addr__is_space_eq(a, b))
    }

///////////////////////////////////////////////////////////////////////////////
// S layout

    @(test)
    s_layout__test :: proc(t: ^testing.T) {
        f: Fixture
        fixture__init(t, &f, lu.CONFIGS[.Default], 3, 5, 1)
        defer fixture__terminate(t, &f)

        s := &f.brain.s

        // seq, frame, rec
        testing.expect_value(t, len(s.areas), lu.N_AREA__SPECIAL_AREA_SKIP + 3)
        testing.expect_value(t, lu.s__get_area_by_tag(s, .Seq).area_ix, SEQ_AREA_IX)
        testing.expect_value(t, lu.s__get_area_by_tag(s, .Frame).area_ix, SEQ_AREA_IX + 1)

        // rec area: rec (3x5), comp, 2x4, 1x3, 1x2
        rec_area := lu.s__get_rec_area(s, 0)
        testing.expect_value(t, rec_area.tag, lu.Area_Tag.Rec)
        testing.expect_value(t, len(rec_area.layers), 5)

        _, is_rec := rec_area.layers[0].(^lu.S_Layer_Rec)
        _, is_comp := rec_area.layers[1].(^lu.S_Layer_Comp)
        testing.expect(t, is_rec)
        testing.expect(t, is_comp)

        apex := rec_area.layers[4].(^lu.S_Layer_N)
        testing.expect_value(t, apex.s_table.w, 1)
        testing.expect_value(t, apex.s_table.h, 2)

        // apex -> frame -> seq
        frame := lu.s_layer_n__get_parent(apex)
        testing.expect_value(t, frame.tag, lu.Area_Tag.Frame)
        testing.expect_value(t, lu.s_layer_n__get_parent(frame).tag, lu.Area_Tag.Seq)
    }
