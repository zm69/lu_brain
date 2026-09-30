/*
    2026 (c) Zaya, https://github.com/zm69

    Baselines for a fair comparison with the Lu_Brain tuned mode, on the same (blurred) pixels and
    the same +-match_shift offsets:

    - Knn:   k-nearest-neighbour, squared L2 distance, minimum over offsets, majority vote.
    - Patch: the tuned mode's patch score computed directly, without the memory graph:
             a sample scores, per 2x2 patch position, the mean pixel agreement of its patch if it
             reaches the breakpoint. Pixel agreement is 1 for the same value step, and the fuzzy
             signal for a neighbouring step. Per offset the top `results` samples are kept, then the
             best of all offsets vote, exactly like the graph version.
*/
package semeion_eval

// Core
    import "core:slice"
    import "core:time"

// Lu
    import lu "../../src"

///////////////////////////////////////////////////////////////////////////////
// Shared

    // Zero-filled shift: dst(x, y) = src(x - dx, y - dy), like set_dest_start_pos in the brain.
    pixels__shift :: proc(src: ^Pixels, dx, dy: int) -> (dst: Pixels) {
        for y in 0..<DIGIT__H {
            for x in 0..<DIGIT__W {
                sx, sy := x - dx, y - dy
                if sx < 0 || sy < 0 || sx >= DIGIT__W || sy >= DIGIT__H do continue
                dst[y * DIGIT__W + x] = src[sy * DIGIT__W + sx]
            }
        }
        return
    }

    // Top class of a candidate list (best first) by summed score; ties go to the class seen first.
    candidates__vote :: proc(eval: ^Eval, candidates: []lu.Label) -> int {
        scores: [DIGIT__VALUE_COUNT]lu.Value
        first_seen: [DIGIT__VALUE_COUNT]int
        for &f in first_seen do f = max(int)

        for c, k in candidates {
            class := eval.digits[c.id].name
            scores[class] += c.sig
            if first_seen[class] == max(int) do first_seen[class] = k
        }

        best := -1
        for c in 0..<DIGIT__VALUE_COUNT {
            if first_seen[c] == max(int) do continue
            if best < 0 || scores[c] > scores[best] || (scores[c] == scores[best] && first_seen[c] < first_seen[best]) do best = c
        }
        return best
    }

///////////////////////////////////////////////////////////////////////////////
// Knn

    fold__run_knn :: proc(eval: ^Eval, fold: int, r: ^Fold_Result) {
        opts := &eval.opts
        k := max(1, opts.results)

        start := time.tick_now()

        dists := make([dynamic]lu.Label, 0, len(eval.digits))
        defer delete(dists)

        for &d, i in eval.digits {
            if eval.fold_of[i] != fold do continue
            r.tested += 1

            shifted := make([]Pixels, (2 * opts.match_shift + 1) * (2 * opts.match_shift + 1), context.temp_allocator)
            {
                s := 0
                for dy in -opts.match_shift..=opts.match_shift {
                    for dx in -opts.match_shift..=opts.match_shift {
                        shifted[s] = pixels__shift(&d.pixels, dx, dy)
                        s += 1
                    }
                }
            }

            clear(&dists)
            for &t, j in eval.digits {
                if eval.fold_of[j] == fold || eval.fold_of[j] < 0 do continue

                best := max(f64)
                for &sp in shifted {
                    dist: f64
                    for p in 0..<DIGIT__PIXEL_COUNT {
                        diff := sp[p] - t.pixels[p]
                        dist += diff * diff
                    }
                    best = min(best, dist)
                }
                // sig = 1 per neighbour (majority vote), distance kept for ordering
                append(&dists, lu.Label{ id = j, sig = 1, sig_received_count = best })
            }

            slice.sort_by(dists[:], proc(a, b: lu.Label) -> bool { return a.sig_received_count < b.sig_received_count })

            if candidates__vote(eval, dists[:min(k, len(dists))]) == d.name do r.correct += 1

            free_all(context.temp_allocator)
        }

        r.match_sec = time.duration_seconds(time.tick_since(start))
    }

///////////////////////////////////////////////////////////////////////////////
// Patch

    Patch_Pixel :: struct {
        z: int,        // value step
        val: lu.Value, // normalized value, for the fuzzy signal
    }

    patch__quantize :: proc(cc: ^lu.Comp_Calc, pixels: ^Pixels) -> (q: [DIGIT__PIXEL_COUNT]Patch_Pixel) {
        for p in 0..<DIGIT__PIXEL_COUNT {
            v := abs(pixels[p]) // the brain saves |value - blank|
            z := 0
            if v >= cc.step do z = lu.comp_calc__ix(cc, lu.comp_calc__norm(cc, v))
            q[p] = { z, lu.comp_calc__norm(cc, v) }
        }
        return
    }

    // Signal a stored pixel (step z) gets from a test pixel, 0 if its rec cell does not fire.
    patch__pixel_sig :: #force_inline proc(cc: ^lu.Comp_Calc, opts: ^Options, stored_z: int, test: Patch_Pixel) -> f64 {
        if stored_z == test.z do return 1
        if abs(stored_z - test.z) > opts.fuzzy do return 0
        sig := lu.comp_calc__calc_sig(cc, stored_z, test.val)
        return sig >= opts.bp ? sig : 0
    }

    fold__run_patch :: proc(eval: ^Eval, fold: int, r: ^Fold_Result) {
        opts := &eval.opts

        cc: lu.Comp_Calc
        lu.comp_calc__init(&cc, 0, 1, opts.steps, context.allocator)
        defer lu.comp_calc__terminate(&cc)

        //
        // "Train": quantize the training samples
        //
        start := time.tick_now()

        train_ixs := make([dynamic]int)
        defer delete(train_ixs)
        stored := make([dynamic][DIGIT__PIXEL_COUNT]Patch_Pixel)
        defer delete(stored)

        for &d, i in eval.digits {
            if eval.fold_of[i] == fold || eval.fold_of[i] < 0 do continue
            append(&train_ixs, i)
            append(&stored, patch__quantize(&cc, &d.pixels))
        }

        r.train_sec = time.duration_seconds(time.tick_since(start))

        //
        // Test
        //
        start = time.tick_now()

        per_offset := make([dynamic]lu.Label, 0, len(train_ixs))
        defer delete(per_offset)
        combined := make([dynamic]lu.Label, 0, 64)
        defer delete(combined)

        W :: DIGIT__W - 1 // level 1 is 15 x 15
        H :: DIGIT__H - 1

        for &d, i in eval.digits {
            if eval.fold_of[i] != fold do continue
            r.tested += 1

            clear(&combined)

            for dy in -opts.match_shift..=opts.match_shift {
                for dx in -opts.match_shift..=opts.match_shift {
                    shifted := pixels__shift(&d.pixels, dx, dy)
                    test := patch__quantize(&cc, &shifted)

                    clear(&per_offset)
                    for &s, si in stored {
                        score: f64
                        fired: f64
                        for y in 0..<H {
                            for x in 0..<W {
                                tl := y * DIGIT__W + x
                                sig := patch__pixel_sig(&cc, opts, s[tl].z, test[tl]) +
                                    patch__pixel_sig(&cc, opts, s[tl + 1].z, test[tl + 1]) +
                                    patch__pixel_sig(&cc, opts, s[tl + DIGIT__W].z, test[tl + DIGIT__W]) +
                                    patch__pixel_sig(&cc, opts, s[tl + DIGIT__W + 1].z, test[tl + DIGIT__W + 1])
                                sig /= 4
                                if sig >= opts.bp - 1e-12 {
                                    score += sig
                                    fired += 1
                                }
                            }
                        }
                        if score > 0 do append(&per_offset, lu.Label{ id = train_ixs[si], sig = score, sig_received_count = fired })
                    }

                    // same ranking as the library (Label_Scoring.Sum)
                    slice.stable_sort_by(per_offset[:], proc(a, b: lu.Label) -> bool { return lu.label__compare(a, b) < 0 })
                    append(&combined, ..per_offset[:min(len(per_offset), opts.results)])
                }
            }

            slice.stable_sort_by(combined[:], proc(a, b: lu.Label) -> bool { return a.sig > b.sig })

            if len(combined) == 0 {
                r.no_result += 1
                continue
            }

            if candidates__vote(eval, combined[:min(len(combined), opts.results)]) == d.name do r.correct += 1
        }

        r.match_sec = time.duration_seconds(time.tick_since(start))
    }
