/*
    2026 (c) Zaya, https://github.com/zm69

    Evidence-map re-ranking: a second stage over the brain's top (sample, offset) candidates.

    For every candidate, its evidence map says, per 2x2 position, whether (and how strongly) the
    candidate's own stored pattern matched the test digit. The brain's score is the sum of the map.
    The variants here use the *layout* of the map:

      A  clustered disagreement: score - lambda * (largest mismatch region)            (A1)
                                 score - lambda * (sum of squared mismatch regions)     (A2)
      B  learned position weights from leave-one-out mistakes on the training digits:
         one weight per position (B global) or per position and class (B class)
      C  two-class focus: when two classes compete, re-score both on the region where their best
         candidates disagree, averaging each class's top k candidates
*/
package semeion_eval

// Lu
    import lu "../../src"

///////////////////////////////////////////////////////////////////////////////
// Evidence maps

    EV__W :: DIGIT__W - 1
    EV__H :: DIGIT__H - 1
    EV__POSITIONS :: EV__W * EV__H

    EV__CANDIDATES :: 30        // re-ranked (sample, offset) candidates per digit
    EV__TRAIN_CANDIDATES :: 20  // cached per training digit for B

    Ev_Entry :: struct {
        sample: int,
        class: int,
        score: f64,                         // brain score
        raw: [EV__POSITIONS]f32,            // fire sig of the sample's pattern, 0 if it did not fire
        weighted: [EV__POSITIONS]f32,       // contribution to the score (raw * pattern * link weight)
    }

    // Evidence maps of the best `n` candidates. Re-matches once per distinct offset.
    evidence__build :: proc(h: ^Hybrid_Brain, d: ^Digit, combined: []Candidate, n: int, allocator := context.temp_allocator) -> (entries: []Ev_Entry, err: lu.Error) {
        eval := h.eval
        top := combined[:min(len(combined), n)]
        entries = make([]Ev_Entry, len(top), allocator) or_return

        done := make([]bool, len(top), context.temp_allocator)

        for first in 0..<len(top) {
            if done[first] do continue
            dx, dy := top[first].dx, top[first].dy

            // match at this offset, collect the fired level-1 cells
            lu.set_dest_start_pos(h.rec, dx, dy)
            lu.push(&h.match_wave, h.rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.push(&h.match_wave, h.rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.match(&h.match_wave) or_return
            lu.set_dest_start_pos(h.rec, 0, 0)

            fired := lu.fired_cells(&h.match_wave, h.rec, 1, context.temp_allocator) or_return
            fired_sig := make(map[u64]f32, len(fired), context.temp_allocator)
            fired_weight := make(map[u64]f32, len(fired), context.temp_allocator)
            for c in fired {
                key := lu.n_addr__value(c.addr)
                fired_sig[key] = f32(c.sig)
                fired_weight[key] = f32(lu.pattern_weight(&h.match_wave, c.addr))
            }

            for k in first..<len(top) {
                if done[k] || top[k].dx != dx || top[k].dy != dy do continue
                done[k] = true

                e := &entries[k]
                e.sample = top[k].sample
                e.class = eval.digits[e.sample].name
                e.score = top[k].score

                cells, _ := lu.label_cells(&h.brain, e.sample, context.temp_allocator)
                for addr in cells {
                    key := lu.n_addr__value(addr)
                    sig, ok := fired_sig[key]
                    if !ok do continue
                    pos := int(addr.column_ix)
                    link_weight, _ := lu.link_weight(&h.brain, addr, e.sample)
                    e.raw[pos] = sig
                    e.weighted[pos] = sig * fired_weight[key] * f32(link_weight)
                }
            }
        }

        return
    }

    // Class vote over the 5 best entries by `scores` (best first after sorting a copy).
    evidence__vote :: proc(eval: ^Eval, entries: []Ev_Entry, scores: []f64) -> int {
        order := make([]int, len(entries), context.temp_allocator)
        for &o, i in order do o = i
        // insertion sort, small n, stable
        for i in 1..<len(order) {
            j := i
            for j > 0 && scores[order[j]] > scores[order[j - 1]] {
                order[j], order[j - 1] = order[j - 1], order[j]
                j -= 1
            }
        }

        top := order[:min(5, len(order))]
        samples := make([]int, len(top), context.temp_allocator)
        weights := make([]f64, len(top), context.temp_allocator)
        for ix, k in top { samples[k], weights[k] = entries[ix].sample, max(scores[ix], 0) }
        return vote(eval, samples, weights)
    }

///////////////////////////////////////////////////////////////////////////////
// A. Clustered disagreement

    // Sizes of 4-connected regions where the candidate's pattern matched weakly (raw < 0.5).
    evidence__mismatch_regions :: proc(e: ^Ev_Entry) -> (largest: int, sum_squares: int) {
        seen: [EV__POSITIONS]bool
        stack: [EV__POSITIONS]int

        for start in 0..<EV__POSITIONS {
            if seen[start] || e.raw[start] >= 0.5 do continue

            size := 0
            top := 0
            stack[top] = start
            top += 1
            seen[start] = true

            for top > 0 {
                top -= 1
                pos := stack[top]
                size += 1
                x, y := pos % EV__W, pos / EV__W

                neighbours := [4][2]int{ {x - 1, y}, {x + 1, y}, {x, y - 1}, {x, y + 1} }
                for nb in neighbours {
                    if nb.x < 0 || nb.y < 0 || nb.x >= EV__W || nb.y >= EV__H do continue
                    npos := nb.y * EV__W + nb.x
                    if seen[npos] || e.raw[npos] >= 0.5 do continue
                    seen[npos] = true
                    stack[top] = npos
                    top += 1
                }
            }

            largest = max(largest, size)
            sum_squares += size * size
        }
        return
    }

///////////////////////////////////////////////////////////////////////////////
// B. Learned position weights

    Ev_Weights :: struct {
        global: [EV__POSITIONS]f64,
        class: [DIGIT__VALUE_COUNT][EV__POSITIONS]f64,
    }

    ev_weights__init :: proc(self: ^Ev_Weights) {
        for &w in self.global do w = 1
        for &c in self.class do for &w in c do w = 1
    }

    evidence__score_global :: proc(w: ^Ev_Weights, e: ^Ev_Entry) -> (score: f64) {
        for pos in 0..<EV__POSITIONS do score += w.global[pos] * f64(e.weighted[pos])
        return
    }

    evidence__score_class :: proc(w: ^Ev_Weights, e: ^Ev_Entry) -> (score: f64) {
        for pos in 0..<EV__POSITIONS do score += w.class[e.class][pos] * f64(e.weighted[pos])
        return
    }

    // Perceptron passes over cached leave-one-out evidence of the training digits.
    ev_weights__learn :: proc(self: ^Ev_Weights, eval: ^Eval, cache: [][]Ev_Entry, truth: []int, epochs: int, rate: f64) {
        scores := make([]f64, EV__TRAIN_CANDIDATES)
        defer delete(scores)

        for _ in 0..<epochs {
            for entries, i in cache {
                if len(entries) == 0 do continue
                name := truth[i]

                for global in ([]bool{ true, false }) {
                    for &e, k in entries {
                        scores[k] = global ? evidence__score_global(self, &e) : evidence__score_class(self, &e)
                    }
                    predicted := evidence__vote(eval, entries, scores[:len(entries)])
                    if predicted == name || predicted < 0 do continue

                    winner, rival := -1, -1
                    for k in 0..<len(entries) {
                        if entries[k].class == predicted && (winner < 0 || scores[k] > scores[winner]) do winner = k
                        if entries[k].class == name && (rival < 0 || scores[k] > scores[rival]) do rival = k
                    }
                    if winner < 0 do continue

                    for pos in 0..<EV__POSITIONS {
                        ew := f64(entries[winner].weighted[pos])
                        er := rival >= 0 ? f64(entries[rival].weighted[pos]) : 0
                        if global {
                            self.global[pos] = max(self.global[pos] + rate * (er - ew), 0)
                        } else {
                            if rival >= 0 do self.class[name][pos] = max(self.class[name][pos] + rate * er, 0)
                            self.class[predicted][pos] = max(self.class[predicted][pos] - rate * ew, 0)
                        }
                    }
                }
                free_all(context.temp_allocator)
            }
        }
    }

///////////////////////////////////////////////////////////////////////////////
// C. Two-class focus

    evidence__two_class :: proc(eval: ^Eval, entries: []Ev_Entry, k: int) -> int {
        scores := make([]f64, len(entries), context.temp_allocator)
        for &e, i in entries do scores[i] = e.score
        c1 := evidence__vote(eval, entries, scores)

        // best entry of c1, best entry of the best other class
        e1, e2 := -1, -1
        for i in 0..<len(entries) {
            if entries[i].class == c1 { if e1 < 0 do e1 = i }
            else if e2 < 0 do e2 = i
        }
        if e1 < 0 || e2 < 0 do return c1
        c2 := entries[e2].class

        // region where the two disagree, dilated by 1
        region: [EV__POSITIONS]bool
        any := false
        for pos in 0..<EV__POSITIONS {
            if abs(entries[e1].raw[pos] - entries[e2].raw[pos]) < 0.5 do continue
            x, y := pos % EV__W, pos / EV__W
            for dy in -1..=1 do for dx in -1..=1 {
                nx, ny := x + dx, y + dy
                if nx < 0 || ny < 0 || nx >= EV__W || ny >= EV__H do continue
                region[ny * EV__W + nx] = true
                any = true
            }
        }
        if !any do return c1

        class_score :: proc(entries: []Ev_Entry, region: ^[EV__POSITIONS]bool, class: int, k: int) -> f64 {
            sum: f64
            n := 0
            for &e in entries {
                if e.class != class do continue
                if n >= k do break
                for pos in 0..<EV__POSITIONS do if region[pos] do sum += f64(e.weighted[pos])
                n += 1
            }
            return n > 0 ? sum / f64(n) : 0
        }

        return class_score(entries, &region, c2, k) > class_score(entries, &region, c1, k) ? c2 : c1
    }

///////////////////////////////////////////////////////////////////////////////
// All variants for one test digit

    A1_LAMBDAS := [?]f64{ 0.1, 0.3, 1.0 }
    A2_LAMBDAS := [?]f64{ 0.01, 0.03, 0.1 }

    evidence__variants :: proc(h: ^Hybrid_Brain, d: ^Digit, combined: []Candidate, r: ^Fold_Result) -> lu.Error {
        eval := h.eval
        entries := evidence__build(h, d, combined, EV__CANDIDATES) or_return
        if len(entries) == 0 do return nil

        name := d.name
        scores := make([]f64, len(entries), context.temp_allocator)

        // self-check: the map must add up to the score the brain gave
        for &e in entries {
            sum: f64
            for w in e.weighted do sum += f64(w)
            if abs(sum - e.score) > 1e-3 * max(1, e.score) do r.variants[.Ev_Check_Fails] += 1
        }

        // A1, A2
        regions_largest := make([]int, len(entries), context.temp_allocator)
        regions_squares := make([]int, len(entries), context.temp_allocator)
        for &e, i in entries do regions_largest[i], regions_squares[i] = evidence__mismatch_regions(&e)

        for lambda, li in A1_LAMBDAS {
            for &e, i in entries do scores[i] = e.score - lambda * f64(regions_largest[i])
            if evidence__vote(eval, entries, scores) == name do r.variants[Variant(int(Variant.Ev_A1_0) + li)] += 1
        }
        for lambda, li in A2_LAMBDAS {
            for &e, i in entries do scores[i] = e.score - lambda * f64(regions_squares[i])
            if evidence__vote(eval, entries, scores) == name do r.variants[Variant(int(Variant.Ev_A2_0) + li)] += 1
        }

        // B
        if h.has_ev_weights {
            for &e, i in entries do scores[i] = evidence__score_global(&h.ev_weights, &e)
            if evidence__vote(eval, entries, scores) == name do r.variants[.Ev_B_Global] += 1
            for &e, i in entries do scores[i] = evidence__score_class(&h.ev_weights, &e)
            if evidence__vote(eval, entries, scores) == name do r.variants[.Ev_B_Class] += 1
        }

        // C
        if evidence__two_class(eval, entries, 3) == name do r.variants[.Ev_C_K3] += 1
        if evidence__two_class(eval, entries, 5) == name do r.variants[.Ev_C_K5] += 1

        return nil
    }

    // Cached leave-one-out evidence of every training digit, for learning B.
    evidence__learn :: proc(h: ^Hybrid_Brain, fold: int) -> lu.Error {
        eval := h.eval
        opts := &eval.opts

        cache := make([dynamic][]Ev_Entry)
        defer {
            for c in cache do delete(c)
            delete(cache)
        }
        truth := make([dynamic]int)
        defer delete(truth)

        for &d, i in eval.digits {
            if eval.fold_of[i] == fold || eval.fold_of[i] < 0 do continue

            combined := hybrid_brain__match(h, &d, i) or_return
            entries := evidence__build(h, &d, combined[:], EV__TRAIN_CANDIDATES, context.allocator) or_return
            delete(combined)

            append(&cache, entries)
            append(&truth, d.name)
            free_all(context.temp_allocator)
        }

        ev_weights__init(&h.ev_weights)
        ev_weights__learn(&h.ev_weights, eval, cache[:], truth[:], opts.evidence_epochs, opts.evidence_rate)
        h.has_ev_weights = true

        return nil
    }
