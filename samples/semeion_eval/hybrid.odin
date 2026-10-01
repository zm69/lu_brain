/*
    2026 (c) Zaya, https://github.com/zm69

    Hybrid experiments: the tuned Lu_Brain combined with pixel kNN, evaluated in one pass so that
    every variant sees exactly the same folds.

    Variants:
      brain        tuned Lu_Brain (top 5 (sample, offset) scores vote)
      knn          kNN, same blur and +-shift, k = 3
      rerank k1/k3 Lu_Brain proposes its top `candidates` samples, kNN distance picks among them
      fuse a       per candidate: a * brain score / best + (1 - a) * nearest distance / distance, top 3 vote

    Plus error overlap of brain and knn: only one wrong vs both wrong.
*/
package semeion_eval

// Core
    import "core:slice"
    import "core:time"

// Lu
    import lu "../../src"

///////////////////////////////////////////////////////////////////////////////
// Variants

    Variant :: enum {
        Brain,
        Knn,
        Rerank_K1,
        Rerank_K3,
        Fuse_25,
        Fuse_50,
        Fuse_75,
        // evidence-map re-ranking (evidence.odin)
        Ev_A1_0,
        Ev_A1_1,
        Ev_A1_2,
        Ev_A2_0,
        Ev_A2_1,
        Ev_A2_2,
        Ev_B_Global,
        Ev_B_Class,
        Ev_C_K3,
        Ev_C_K5,
        // image distortion model (idm.odin), order: width major, penalty minor
        Idm_Local_A,
        Idm_Local_B,
        Idm_Local_C,
        Idm_Global_A,
        Idm_Global_B,
        Idm_Global_C,
        // error overlap (counts, not accuracy)
        Only_Brain_Wrong,
        Only_Knn_Wrong,
        Both_Wrong,
        Ev_Check_Fails, // evidence maps whose sum differs from the brain score
    }

    VARIANT__NAMES := [Variant]string{
        .Brain = "brain",
        .Knn = "knn (k=3)",
        .Rerank_K1 = "rerank k=1",
        .Rerank_K3 = "rerank k=3",
        .Fuse_25 = "fuse a=0.25",
        .Fuse_50 = "fuse a=0.50",
        .Fuse_75 = "fuse a=0.75",
        .Ev_A1_0 = "A1 largest l=0.1",
        .Ev_A1_1 = "A1 largest l=0.3",
        .Ev_A1_2 = "A1 largest l=1.0",
        .Ev_A2_0 = "A2 squares l=0.01",
        .Ev_A2_1 = "A2 squares l=0.03",
        .Ev_A2_2 = "A2 squares l=0.1",
        .Ev_B_Global = "B pos weights",
        .Ev_B_Class = "B pos x class",
        .Ev_C_K3 = "C two-class k=3",
        .Ev_C_K5 = "C two-class k=5",
        .Idm_Local_A = "IDM local mu=a",
        .Idm_Local_B = "IDM local mu=b",
        .Idm_Local_C = "IDM local mu=c",
        .Idm_Global_A = "IDM glob+loc mu=a",
        .Idm_Global_B = "IDM glob+loc mu=b",
        .Idm_Global_C = "IDM glob+loc mu=c",
        .Only_Brain_Wrong = "only brain wrong",
        .Only_Knn_Wrong = "only knn wrong",
        .Both_Wrong = "both wrong",
        .Ev_Check_Fails = "evidence check fails",
    }

    HYBRID__PER_OFFSET_RESULTS :: 20

///////////////////////////////////////////////////////////////////////////////
// Helpers

    Scored :: struct {
        sample: int,
        score: f64,  // brain score (higher is better)
        dist: f64,   // pixel distance (lower is better)
    }

    // Majority-free vote: sum of weights per class; ties go to the class listed first.
    vote :: proc(eval: ^Eval, samples: []int, weights: []f64) -> int {
        scores: [DIGIT__VALUE_COUNT]f64
        first_seen: [DIGIT__VALUE_COUNT]int
        for &f in first_seen do f = max(int)

        for s, k in samples {
            class := eval.digits[s].name
            scores[class] += weights[k]
            if first_seen[class] == max(int) do first_seen[class] = k
        }

        best := -1
        for c in 0..<DIGIT__VALUE_COUNT {
            if first_seen[c] == max(int) do continue
            if best < 0 || scores[c] > scores[best] || (scores[c] == scores[best] && first_seen[c] < first_seen[best]) do best = c
        }
        return best
    }

    // Squared L2 distance, minimum over +-shift offsets of the test digit.
    knn__distance :: proc(shifted: []Pixels, t: ^Pixels) -> f64 {
        best := max(f64)
        for &sp in shifted {
            dist: f64
            for p in 0..<DIGIT__PIXEL_COUNT {
                diff := sp[p] - t[p]
                dist += diff * diff
            }
            best = min(best, dist)
        }
        return best
    }

///////////////////////////////////////////////////////////////////////////////
// Fold

    fold__run_hybrid :: proc(eval: ^Eval, fold: int, r: ^Fold_Result) -> lu.Error {
        opts := &eval.opts

        h: Hybrid_Brain
        hybrid_brain__init(&h, eval, fold) or_return
        defer hybrid_brain__terminate(&h)

        r.train_sec = h.train_sec
        r.learn_errors_first = h.learn_errors_first
        r.learn_errors_last = h.learn_errors_last
        r.cells = lu.get_net_stats(&h.brain).cells_count

        start := time.tick_now()

        offsets := (2 * opts.match_shift + 1) * (2 * opts.match_shift + 1)
        shifted := make([]Pixels, offsets)
        defer delete(shifted)

        dists := make([]f64, len(eval.digits))
        defer delete(dists)

        for &d, i in eval.digits {
            if eval.fold_of[i] != fold do continue
            r.tested += 1

            //
            // Brain: all (sample, offset) scores
            //
            combined := hybrid_brain__match(&h, &d, -1) or_return
            defer delete(combined)

            brain_class := hybrid__vote_top(eval, combined[:])

            // evidence maps are 15 x 15 (level 1 only)
            if opts.evidence && h.level == 1 do evidence__variants(&h, &d, combined[:], r) or_return
            if opts.idm do idm__variants(&h, &d, r) or_return

            //
            // kNN over all training samples
            //
            {
                s := 0
                for dy in -opts.match_shift..=opts.match_shift {
                    for dx in -opts.match_shift..=opts.match_shift {
                        shifted[s] = pixels__shift(&d.pixels, dx, dy)
                        s += 1
                    }
                }
            }

            knn_order := make([dynamic]int, 0, len(eval.digits), context.temp_allocator)
            for &t, j in eval.digits {
                if eval.fold_of[j] == fold || eval.fold_of[j] < 0 do continue
                dists[j] = knn__distance(shifted, &t.pixels)
                append(&knn_order, j)
            }
            // the 3 nearest (insertion, no closure needed for the distances)
            knn_top: [3]int = { -1, -1, -1 }
            for j in knn_order {
                for k in 0..<3 {
                    if knn_top[k] < 0 || dists[j] < dists[knn_top[k]] {
                        for m := 2; m > k; m -= 1 do knn_top[m] = knn_top[m - 1]
                        knn_top[k] = j
                        break
                    }
                }
            }
            knn_class := vote(eval, knn_top[:], []f64{ 1, 1, 1 })

            //
            // Candidates: best distinct samples by brain score
            //
            candidates := make([dynamic]Scored, 0, opts.candidates, context.temp_allocator)
            for c in combined {
                if len(candidates) >= opts.candidates do break
                seen := false
                for x in candidates do if x.sample == c.sample { seen = true; break }
                if !seen do append(&candidates, Scored{ c.sample, c.score, dists[c.sample] })
            }

            rerank_k1, rerank_k3 := -1, -1
            fuse: [3]int = { -1, -1, -1 }

            if len(candidates) > 0 {
                by_dist := slice.clone(candidates[:], context.temp_allocator)
                slice.sort_by(by_dist, proc(a, b: Scored) -> bool { return a.dist < b.dist })

                rerank_k1 = eval.digits[by_dist[0].sample].name

                k3 := by_dist[:min(3, len(by_dist))]
                samples := make([]int, len(k3), context.temp_allocator)
                ones := make([]f64, len(k3), context.temp_allocator)
                for c, k in k3 { samples[k], ones[k] = c.sample, 1 }
                rerank_k3 = vote(eval, samples, ones)

                best_score := candidates[0].score
                best_dist := by_dist[0].dist

                for alpha, ai in ([]f64{ 0.25, 0.5, 0.75 }) {
                    Fused :: struct { sample: int, value: f64 }
                    fused := make([]Fused, len(candidates), context.temp_allocator)
                    for c, k in candidates {
                        sk := c.dist > 0 ? best_dist / c.dist : 1
                        sb := best_score > 0 ? c.score / best_score : 0
                        fused[k] = { c.sample, alpha * sb + (1 - alpha) * sk }
                    }
                    slice.sort_by(fused, proc(a, b: Fused) -> bool { return a.value > b.value })

                    top := fused[:min(3, len(fused))]
                    fs := make([]int, len(top), context.temp_allocator)
                    fw := make([]f64, len(top), context.temp_allocator)
                    for f, k in top { fs[k], fw[k] = f.sample, 1 }
                    fuse[ai] = vote(eval, fs, fw)
                }
            }

            name := d.name
            if brain_class == name do r.variants[.Brain] += 1
            if knn_class == name do r.variants[.Knn] += 1
            if rerank_k1 == name do r.variants[.Rerank_K1] += 1
            if rerank_k3 == name do r.variants[.Rerank_K3] += 1
            if fuse[0] == name do r.variants[.Fuse_25] += 1
            if fuse[1] == name do r.variants[.Fuse_50] += 1
            if fuse[2] == name do r.variants[.Fuse_75] += 1

            brain_ok, knn_ok := brain_class == name, knn_class == name
            if !brain_ok && knn_ok do r.variants[.Only_Brain_Wrong] += 1
            if brain_ok && !knn_ok do r.variants[.Only_Knn_Wrong] += 1
            if !brain_ok && !knn_ok do r.variants[.Both_Wrong] += 1

            if brain_ok do r.correct += 1

            free_all(context.temp_allocator)
        }

        r.match_sec = time.duration_seconds(time.tick_since(start))
        return nil
    }

    // The tuned brain decision: the 5 best (sample, offset) scores vote.
    hybrid__vote_top :: proc(eval: ^Eval, combined: []Candidate) -> int {
        top := combined[:min(len(combined), 5)]
        samples := make([]int, len(top), context.temp_allocator)
        weights := make([]f64, len(top), context.temp_allocator)
        for c, k in top { samples[k], weights[k] = c.sample, c.score }
        return vote(eval, samples, weights)
    }

///////////////////////////////////////////////////////////////////////////////
// Tuned brain for the hybrid experiments

    Candidate :: struct {
        sample: int,
        score: f64,
        dx: int,
        dy: int,
    }

    Hybrid_Brain :: struct {
        eval: ^Eval,
        brain: lu.Brain,
        rec: ^lu.Rec,
        save_wave: lu.Save_Wave,
        match_wave: lu.Match_Wave,
        train_sec: f64,
        learn_errors_first: int,
        learn_errors_last: int,
        ev_weights: Ev_Weights,
        has_ev_weights: bool,
        level: int, // rec level the labels are linked to
    }

    hybrid_brain__init :: proc(self: ^Hybrid_Brain, eval: ^Eval, fold: int) -> lu.Error {
        opts := &eval.opts
        self.eval = eval

        config := lu.CONFIGS[.Semeion_Tuned]
        config.la_labels_size = len(eval.digits)
        config.w_match_sig_breakpoint = opts.bp
        config.w_match_results_size = max(HYBRID__PER_OFFSET_RESULTS, opts.candidates)
        config.w_match_idf_power = opts.idf
        // labels on rec level `level`: build and match only up to it
        self.level = max(opts.link_level, 1)
        config.s_save_max_level = self.level
        config.w_match_max_level = self.level
        config.w_match_purity_power = opts.purity

        rec_config := lu.REC_CONFIGS[.Semeion_Tuned]
        rec_config.comp_config.p_neu_size = opts.steps
        rec_config.comp_config.p_fuzzy_radius = opts.fuzzy

        lu.brain_init(&self.brain, config) or_return
        self.rec = lu.add_rec(&self.brain, DIGIT__W, DIGIT__H, 1, rec_config) or_return
        lu.build(&self.brain) or_return

        lu.save_wave_init(&self.save_wave, &self.brain) or_return
        lu.match_wave_init(&self.match_wave, &self.brain) or_return

        start := time.tick_now()
        for &d, i in eval.digits {
            if eval.fold_of[i] == fold || eval.fold_of[i] < 0 do continue

            lu.push(&self.save_wave, self.rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.push(&self.save_wave, self.rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.save(&self.save_wave) or_return
            lu.link_level_to_label(&self.save_wave, self.rec, self.level, i) or_return
            lu.set_label_group(&self.brain, i, d.name) or_return
        }

        //
        // Learn from mistakes: match every training digit against the others (leave one out),
        // and reinforce on errors.
        //
        for epoch in 0..<opts.learn_epochs {
            errors := 0
            for &d, i in eval.digits {
                if eval.fold_of[i] == fold || eval.fold_of[i] < 0 do continue

                combined := hybrid_brain__match(self, &d, i) or_return
                defer delete(combined)

                predicted := hybrid__vote_top(eval, combined[:])
                if predicted == d.name || predicted < 0 do continue
                errors += 1

                winner, rival := -1, -1
                for c, k in combined {
                    name := eval.digits[c.sample].name
                    if winner < 0 && name == predicted do winner = k
                    if rival < 0 && name == d.name do rival = k
                }

                w := combined[winner]
                lu.set_dest_start_pos(self.rec, w.dx, w.dy)
                lu.push(&self.match_wave, self.rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
                lu.push(&self.match_wave, self.rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
                lu.match(&self.match_wave) or_return
                lu.set_dest_start_pos(self.rec, 0, 0)

                promote := rival >= 0 ? combined[rival].sample : lu.LA_IX__NULL
                demote := w.sample
                if opts.learn_mode == .Demote do promote = lu.LA_IX__NULL
                if opts.learn_mode == .Promote do demote = lu.LA_IX__NULL
                lu.reinforce(&self.match_wave, self.rec, 1, promote, demote, opts.learn_rate) or_return

                free_all(context.temp_allocator)
            }
            if epoch == 0 do self.learn_errors_first = errors
            self.learn_errors_last = errors
        }

        if opts.evidence && opts.evidence_epochs > 0 && self.level == 1 do evidence__learn(self, fold) or_return

        self.train_sec = time.duration_seconds(time.tick_since(start))

        return nil
    }

    hybrid_brain__terminate :: proc(self: ^Hybrid_Brain) {
        lu.match_wave_terminate(&self.match_wave)
        lu.save_wave_terminate(&self.save_wave)
        lu.brain_terminate(&self.brain)
    }

    // All (sample, offset) scores of a digit, best first. `exclude` (a training sample) is skipped.
    hybrid_brain__match :: proc(self: ^Hybrid_Brain, d: ^Digit, exclude: int) -> (combined: [dynamic]Candidate, err: lu.Error) {
        shift := self.eval.opts.match_shift
        combined = make([dynamic]Candidate, 0, 9 * HYBRID__PER_OFFSET_RESULTS)

        for dy in -shift..=shift {
            for dx in -shift..=shift {
                lu.set_dest_start_pos(self.rec, dx, dy)
                lu.push(&self.match_wave, self.rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
                lu.push(&self.match_wave, self.rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
                lu.match(&self.match_wave) or_return

                for res in lu.match_results(&self.match_wave) {
                    if res.id == exclude do continue
                    append(&combined, Candidate{ res.id, res.sig, dx, dy })
                }
            }
        }
        lu.set_dest_start_pos(self.rec, 0, 0)

        slice.stable_sort_by(combined[:], proc(a, b: Candidate) -> bool { return a.score > b.score })
        return
    }
