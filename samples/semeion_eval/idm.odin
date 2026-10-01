/*
    2026 (c) Zaya, https://github.com/zm69

    Image distortion model (IDM) on top of Lu_Brain.

    The brain's ±1 shift matching moves the whole test digit (global offset g):
        score = max over g ( sum over patches of patch match at g )
    Two IDM variants, from the same matches at every offset within ±2:

      local     every patch finds its own best alignment within ±1 (no global shift):
                    sum over patches ( max over d of match(d) - mu * |d| )
      global    global shift first, then every patch may move ±1 more around it:
                + local   max over g ( sum over patches ( max over d of match(g + d) - mu * |d| ) )
                With a large mu this becomes exactly the brain's global shift matching.

    Every stored pattern keeps the signal it received at every offset; samples are scored from
    those signals times the pattern and link weights, exactly like the brain.
*/
package semeion_eval

// Lu
    import lu "../../src"

///////////////////////////////////////////////////////////////////////////////
// IDM

    IDM__R :: 2                          // offsets matched: ±2
    IDM__SIDE :: 2 * IDM__R + 1
    IDM__OFFSETS :: IDM__SIDE * IDM__SIDE
    IDM__PENALTIES_COUNT :: 3

    Idm_Cell :: struct {
        addr: lu.N_Addr,
        pattern_weight: f64,
        sig: [IDM__OFFSETS]f32,          // fire sig at every offset, 0 if not fired
    }

    idm__offset_ix :: #force_inline proc(dx, dy: int) -> int {
        return (dy + IDM__R) * IDM__SIDE + (dx + IDM__R)
    }

    // Best (sig - mu * displacement) of a cell over local moves d (|d| <= 1) around offset g.
    idm__local_best :: #force_inline proc(cell: ^Idm_Cell, gx, gy: int, mu: f64) -> (best: f64) {
        for dy in -1..=1 {
            for dx in -1..=1 {
                x, y := gx + dx, gy + dy
                if abs(x) > IDM__R || abs(y) > IDM__R do continue
                sig := f64(cell.sig[idm__offset_ix(x, y)])
                if sig <= 0 do continue
                best = max(best, sig - mu * f64(max(abs(dx), abs(dy))))
            }
        }
        return
    }

    idm__variants :: proc(h: ^Hybrid_Brain, d: ^Digit, r: ^Fold_Result) -> lu.Error {
        eval := h.eval
        penalties := [IDM__PENALTIES_COUNT]f64{ eval.opts.idm_mu_a, eval.opts.idm_mu_b, eval.opts.idm_mu_c }

        //
        // Match at every offset, keep each cell's signal per offset
        //
        cells := make(map[u64]Idm_Cell, 4096, context.temp_allocator)

        for dy in -IDM__R..=IDM__R {
            for dx in -IDM__R..=IDM__R {
                lu.set_dest_start_pos(h.rec, dx, dy)
                lu.push(&h.match_wave, h.rec, FEATURE_BLANK, DIGIT__W, DIGIT__H, FEATURE_DEPTH) or_return
                lu.push(&h.match_wave, h.rec, d.features, DIGIT__W, DIGIT__H, FEATURE_DEPTH) or_return
                lu.match(&h.match_wave) or_return

                fired := lu.fired_cells(&h.match_wave, h.rec, h.level, context.temp_allocator) or_return
                for c in fired {
                    key := lu.n_addr__value(c.addr)
                    cell, found := &cells[key]
                    if !found {
                        cells[key] = Idm_Cell{ addr = c.addr, pattern_weight = lu.pattern_weight(&h.match_wave, c.addr) }
                        cell = &cells[key]
                    }
                    cell.sig[idm__offset_ix(dx, dy)] = f32(c.sig)
                }
            }
        }
        lu.set_dest_start_pos(h.rec, 0, 0)

        // labels and weights of every fired cell, resolved once
        Link :: struct { label: int, factor: f64 }
        Resolved :: struct { cell: ^Idm_Cell, links: []Link }
        resolved := make([dynamic]Resolved, 0, len(cells), context.temp_allocator)
        for _, &cell in cells {
            labels, _ := lu.cell_labels(&h.brain, cell.addr, context.temp_allocator)
            links := make([]Link, len(labels), context.temp_allocator)
            for l, k in labels {
                link_weight, _ := lu.link_weight(&h.brain, cell.addr, l)
                links[k] = { l, cell.pattern_weight * link_weight }
            }
            append(&resolved, Resolved{ &cell, links })
        }

        n := len(eval.digits)
        scores := make([]f64, n, context.temp_allocator)

        for mu, mi in penalties {
            //
            // local: patches move ±1 around offset 0
            //
            for &s in scores do s = 0
            for res in resolved {
                v := idm__local_best(res.cell, 0, 0, mu)
                if v <= 0 do continue
                for link in res.links do scores[link.label] += v * link.factor
            }
            if idm__vote_top(eval, scores) == d.name do r.variants[Variant(int(Variant.Idm_Local_A) + mi)] += 1

            //
            // global ±1, then patches move ±1 around it. Like the brain, the 5 best
            // (sample, global offset) entries vote, so a sample can count once per offset.
            //
            entries := make([dynamic]Candidate, 0, 9 * 5, context.temp_allocator)
            for gy in -1..=1 {
                for gx in -1..=1 {
                    for &s in scores do s = 0
                    for res in resolved {
                        v := idm__local_best(res.cell, gx, gy, mu)
                        if v <= 0 do continue
                        for link in res.links do scores[link.label] += v * link.factor
                    }
                    for t in idm__top5(scores) do if t >= 0 do append(&entries, Candidate{ t, scores[t], gx, gy })
                }
            }
            if hybrid__vote_top(eval, idm__sorted(entries[:])) == d.name do r.variants[Variant(int(Variant.Idm_Global_A) + mi)] += 1
        }

        return nil
    }

    // Indexes of the 5 best positive scores, best first (-1 if fewer).
    idm__top5 :: proc(scores: []f64) -> (top: [5]int) {
        top = { -1, -1, -1, -1, -1 }
        for v, s in scores {
            if v <= 0 do continue
            for k in 0..<5 {
                if top[k] < 0 || v > scores[top[k]] {
                    for m := 4; m > k; m -= 1 do top[m] = top[m - 1]
                    top[k] = s
                    break
                }
            }
        }
        return
    }

    idm__sorted :: proc(entries: []Candidate) -> []Candidate {
        for i in 1..<len(entries) {
            j := i
            for j > 0 && entries[j].score > entries[j - 1].score {
                entries[j], entries[j - 1] = entries[j - 1], entries[j]
                j -= 1
            }
        }
        return entries
    }

    // Top 5 samples by score vote (each sample once).
    idm__vote_top :: proc(eval: ^Eval, scores: []f64) -> int {
        top := idm__top5(scores)

        n := 0
        for t in top do if t >= 0 do n += 1
        samples := make([]int, n, context.temp_allocator)
        weights := make([]f64, n, context.temp_allocator)
        for k in 0..<n { samples[k], weights[k] = top[k], scores[top[k]] }
        return vote(eval, samples, weights)
    }
