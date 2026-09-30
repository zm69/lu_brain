/*
    2026 (c) Zaya, https://github.com/zm69

    Semeion evaluation harness: stratified k-fold cross-validation on all 1,593 digits.

    Every option is a command-line flag, so parameters can be tuned without recompiling.
    Defaults reproduce the C algorithm (the baseline).

    Run from this folder:
        odin build . -o:speed -out:out/eval.exe
        out/eval.exe                                   # baseline, 10 folds
        out/eval.exe -scoring:Sum -link-layers:3       # try options
        out/eval.exe -help
*/
package semeion_eval

// Base
    import "base:runtime"

// Core
    import "core:flags"
    import "core:fmt"
    import "core:math/rand"
    import "core:os"
    import "core:slice"
    import "core:strconv"
    import "core:strings"
    import "core:sync"
    import "core:thread"
    import "core:time"

// Lu
    import lu "../../src"

///////////////////////////////////////////////////////////////////////////////
// Options

    Options :: struct {
        data: string                `usage:"Path to semeion.data."`,
        folds: int                  `usage:"Number of cross-validation folds."`,
        seed: u64                   `usage:"Seed for the fold split."`,
        threads: int                `usage:"Folds evaluated in parallel."`,

        // Brain
        bp: f64                     `usage:"Match sig breakpoint (C: 0.4 in the sample)."`,
        vp_bp: f64                  `usage:"Save breakpoint for parents of VP cells (C: 0.76)."`,
        n_bp: f64                   `usage:"Save breakpoint for parents of N cells (C: 0.8)."`,
        scoring: lu.Label_Scoring   `usage:"Label scoring: Max (C), Sum, Mean."`,
        results: int                `usage:"Match results kept per match."`,

        // Rec
        steps: int                  `usage:"Value steps per pixel (p_neu_size, C: 2)."`,
        fuzzy: int                  `usage:"Fuzzy radius in value steps (C: 0)."`,
        null_damping: f64           `usage:"Damping of background (z = 0) cells on match, 0..1 (C: 0)."`,

        // Sample
        blur: int                   `usage:"Box blur radius applied to every image (0 = none)."`,
        shift: int                  `usage:"Also train shifted copies within +-shift pixels."`,
        match_shift: int            `usage:"Match at every offset within +-match-shift pixels, keep the best scores."`,
        link_layers: int            `usage:"Also link labels to every cell of the top N rec layers."`,
        link_frame: bool            `usage:"Also link labels to the frame layers."`,
        link_skip: int              `usage:"Skip the top M rec layers before linking link-layers."`,
        link_level: int             `usage:"Link labels to every cell of the rec layer at this level (1 = just above the rec base)."`,
        stop: bool                  `usage:"Stop match propagation at link-level (faster, same results for labels at that level)."`,
        no_seq_link: bool           `usage:"Do not link labels to the top seq cell."`,
        per_sample: bool            `usage:"Label = training sample id; the class is voted over the top results."`,
        retry: bool                 `usage:"Retry with lower breakpoints when a match returns nothing."`,

        verbose: bool               `usage:"Print per-fold results."`,
    }

    options__default :: proc() -> Options {
        return Options{
            data = "../semeion/data/semeion.data",
            folds = 10,
            seed = 1,
            threads = 8,
            bp = 0.4,
            vp_bp = 0.76,
            n_bp = 0.8,
            scoring = .Max,
            results = 3,
            steps = 2,
            fuzzy = 0,
            null_damping = 0,
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Data

    DIGIT__W :: 16
    DIGIT__H :: 16
    DIGIT__PIXEL_COUNT :: DIGIT__W * DIGIT__H
    DIGIT__VALUE_COUNT :: 10

    Pixels :: [DIGIT__PIXEL_COUNT]lu.Value

    Digit :: struct {
        name: int,
        pixels: Pixels,
    }

    BLANK_PIXELS: Pixels

    data__load :: proc(file_name: string) -> (digits: [dynamic]Digit, ok: bool) {
        bytes, err := os.read_entire_file(file_name, context.allocator)
        if err != nil {
            fmt.eprintfln("Could not open file %v: %v", file_name, err)
            return
        }
        defer delete(bytes)

        text := string(bytes)
        for line in strings.split_lines_iterator(&text) {
            fields := strings.fields(line, context.temp_allocator)
            if len(fields) < DIGIT__PIXEL_COUNT + DIGIT__VALUE_COUNT do continue

            digit := Digit{ name = -1 }
            for i in 0..<DIGIT__PIXEL_COUNT do digit.pixels[i], _ = strconv.parse_f64(fields[i])
            for i in 0..<DIGIT__VALUE_COUNT {
                if v, _ := strconv.parse_int(fields[DIGIT__PIXEL_COUNT + i]); v != 0 do digit.name = i
            }
            if digit.name >= 0 do append(&digits, digit)
        }
        free_all(context.temp_allocator)

        return digits, true
    }

    // Box blur with the given radius; averages only in-bounds pixels.
    pixels__blur :: proc(src: ^Pixels, radius: int) -> (dst: Pixels) {
        for y in 0..<DIGIT__H {
            for x in 0..<DIGIT__W {
                sum: lu.Value
                count := 0
                for dy in -radius..=radius {
                    for dx in -radius..=radius {
                        sx, sy := x + dx, y + dy
                        if sx < 0 || sy < 0 || sx >= DIGIT__W || sy >= DIGIT__H do continue
                        sum += src[sy * DIGIT__W + sx]
                        count += 1
                    }
                }
                dst[y * DIGIT__W + x] = sum / lu.Value(count)
            }
        }
        return
    }

    // Stratified split: every digit class is shuffled and dealt round-robin to the folds.
    folds__make :: proc(digits: []Digit, folds: int, seed: u64) -> []int {
        fold_of := make([]int, len(digits))

        gen_state := rand.create(seed)
        gen := runtime.default_random_generator(&gen_state)

        for name in 0..<DIGIT__VALUE_COUNT {
            ixs: [dynamic]int
            defer delete(ixs)
            for d, i in digits do if d.name == name do append(&ixs, i)

            rand.shuffle(ixs[:], gen)
            for ix, k in ixs do fold_of[ix] = k % folds
        }

        return fold_of
    }

///////////////////////////////////////////////////////////////////////////////
// Fold

    Fold_Result :: struct {
        tested: int,
        correct: int,
        top3: int,
        no_result: int,
        train_sec: f64,
        match_sec: f64,
        cells: int,
        err: lu.Error,
    }

    Eval :: struct {
        opts: Options,
        digits: []Digit,        // already blurred if requested
        fold_of: []int,
        next_fold: int,         // atomic work counter
        results: []Fold_Result,
    }

    fold__run :: proc(eval: ^Eval, fold: int) -> (r: Fold_Result) {
        r.err = fold__run_internal(eval, fold, &r)
        return
    }

    fold__run_internal :: proc(eval: ^Eval, fold: int, r: ^Fold_Result) -> lu.Error {
        opts := &eval.opts

        config := lu.CONFIGS[.Semeion_01]
        // capacities only, they grow on demand and do not change results
        config.s_column_h = 16
        config.n_link_mem_size = 16
        config.w_match_processor_queue_size = 4096
        config.w_match_cells_size_per_wave = 1 << 16
        config.la_link_mem_size = 1024
        copies := (2 * opts.shift + 1) * (2 * opts.shift + 1)
        if opts.per_sample do config.la_labels_size = len(eval.digits) * copies
        // algorithm
        config.w_match_sig_breakpoint = opts.bp
        config.s_vp_parent_breakpoint = opts.vp_bp
        config.s_parent_breakpoint = opts.n_bp
        config.w_match_label_scoring = opts.scoring
        config.w_match_results_size = opts.results
        if opts.stop do config.w_match_max_level = opts.link_level

        rec_config := lu.REC_CONFIGS[.Mono1_Image]
        rec_config.comp_config.p_neu_size = opts.steps
        rec_config.comp_config.p_fuzzy_radius = opts.fuzzy
        rec_config.comp_config.p_null_damping = opts.null_damping

        brain: lu.Brain
        lu.brain_init(&brain, config) or_return
        defer lu.brain_terminate(&brain)

        rec := lu.add_rec(&brain, DIGIT__W, DIGIT__H, 1, rec_config) or_return
        lu.build(&brain) or_return

        save_wave: lu.Save_Wave
        lu.save_wave_init(&save_wave, &brain) or_return
        defer lu.save_wave_terminate(&save_wave)

        match_wave: lu.Match_Wave
        lu.match_wave_init(&match_wave, &brain) or_return
        defer lu.match_wave_terminate(&match_wave)

        //
        // Train
        //
        seq_area_ix := lu.s__get_area_by_tag(&brain.s, .Seq).area_ix
        frame_area := lu.s__get_area_by_tag(&brain.s, .Frame)
        rec_area := lu.s__get_rec_area(&brain.s, 0)

        start := time.tick_now()

        for &d, i in eval.digits {
            if eval.fold_of[i] == fold do continue

            copy_ix := 0
            for dy in -opts.shift..=opts.shift {
                for dx in -opts.shift..=opts.shift {
                    defer copy_ix += 1

                    lu.set_dest_start_pos(rec, dx, dy)

                    lu.push(&save_wave, rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
                    lu.push(&save_wave, rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
                    lu.save(&save_wave) or_return

                    // per sample: every shifted copy is its own candidate (label / copies = sample)
                    label := opts.per_sample ? i * copies + copy_ix : d.name

                    if !opts.no_seq_link do lu.link_to_label(&save_wave, seq_area_ix, 0, 0, 0, label) or_return

                    if opts.link_frame {
                        for li in 0..<len(frame_area.layers) {
                            lu.link_to_label(&save_wave, frame_area.area_ix, li, 0, 0, label) or_return
                        }
                    }

                    if opts.link_level > 0 {
                        for layer, li in rec_area.layers {
                            n, ok := layer.(^lu.S_Layer_N)
                            if !ok || n.level != opts.link_level do continue
                            for y in 0..<n.s_table.h {
                                for x in 0..<n.s_table.w {
                                    lu.link_to_label(&save_wave, rec_area.area_ix, li, x, y, label) or_return
                                }
                            }
                        }
                    }

                    // top N plain N layers of the rec area
                    linked := 0
                    skipped := 0
                    #reverse for layer, li in rec_area.layers {
                        if linked >= opts.link_layers do break
                        n, ok := layer.(^lu.S_Layer_N)
                        if !ok do break
                        if skipped < opts.link_skip {
                            skipped += 1
                            continue
                        }
                        for y in 0..<n.s_table.h {
                            for x in 0..<n.s_table.w {
                                lu.link_to_label(&save_wave, rec_area.area_ix, li, x, y, label) or_return
                            }
                        }
                        linked += 1
                    }
                }
            }
        }

        lu.set_dest_start_pos(rec, 0, 0)

        r.train_sec = time.duration_seconds(time.tick_since(start))
        r.cells = lu.get_net_stats(&brain).cells_count

        //
        // Test
        //
        start = time.tick_now()

        for &d, i in eval.digits {
            if eval.fold_of[i] != fold do continue

            r.tested += 1

            // results of every offset, best first, at most opts.results
            combined := make([dynamic]lu.Label, 0, opts.results * 25, context.temp_allocator)

            for dy in -opts.match_shift..=opts.match_shift {
                for dx in -opts.match_shift..=opts.match_shift {
                    lu.set_dest_start_pos(rec, dx, dy)

                    results := match_digit(&match_wave, rec, &d) or_return

                    if len(results) == 0 && opts.retry {
                        for factor in ([]f64{ 0.75, 0.5, 0.25 }) {
                            lu.set_match_sig_breakpoint(&match_wave, opts.bp * factor) or_return
                            results = match_digit(&match_wave, rec, &d) or_return
                            if len(results) > 0 do break
                        }
                        lu.set_match_sig_breakpoint(&match_wave, opts.bp) or_return
                    }

                    append(&combined, ..results)
                }
            }
            lu.set_dest_start_pos(rec, 0, 0)

            slice.sort_by(combined[:], proc(a, b: lu.Label) -> bool { return a.sig > b.sig })
            results := combined[:min(len(combined), opts.results)]

            if len(results) == 0 {
                r.no_result += 1
                free_all(context.temp_allocator)
                continue
            }

            rank := class_rank(eval, results, d.name)
            if rank == 0 do r.correct += 1
            if rank < 3 do r.top3 += 1

            free_all(context.temp_allocator)
        }

        r.match_sec = time.duration_seconds(time.tick_since(start))

        return nil
    }

    // Rank (0 = best) of the true class among the classes of the results, by summed score.
    // Without per_sample, result ids are classes already.
    class_rank :: proc(eval: ^Eval, results: []lu.Label, name: int) -> int {
        scores: [DIGIT__VALUE_COUNT]lu.Value
        seen: [DIGIT__VALUE_COUNT]bool
        first := -1

        for res, k in results {
            copies := (2 * eval.opts.shift + 1) * (2 * eval.opts.shift + 1)
            class := eval.opts.per_sample ? eval.digits[res.id / copies].name : res.id
            if !eval.opts.per_sample {
                // keep the library ranking
                if class == name do return k
                continue
            }
            if first < 0 do first = class
            scores[class] += res.sig
            seen[class] = true
        }

        if !eval.opts.per_sample do return max(int)
        if !seen[name] do return max(int)

        rank := 0
        for c in 0..<DIGIT__VALUE_COUNT {
            if c == name || !seen[c] do continue
            if scores[c] > scores[name] || (scores[c] == scores[name] && c == first) do rank += 1
        }
        return rank
    }

    match_digit :: proc(match_wave: ^lu.Match_Wave, rec: ^lu.Rec, d: ^Digit) -> (results: []lu.Label, err: lu.Error) {
        lu.push(match_wave, rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
        lu.push(match_wave, rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
        lu.match(match_wave) or_return
        return lu.match_results(match_wave), nil
    }

    worker :: proc(eval: ^Eval) {
        for {
            fold := sync.atomic_add(&eval.next_fold, 1)
            if fold >= eval.opts.folds do return

            eval.results[fold] = fold__run(eval, fold)

            if eval.opts.verbose {
                r := eval.results[fold]
                fmt.printfln(
                    "  fold %2d: %3d/%3d (%.1f%%), no result %d, cells %v, train %.1fs, match %.1fs, err %v",
                    fold, r.correct, r.tested, f64(r.correct) * 100 / f64(max(r.tested, 1)),
                    r.no_result, r.cells, r.train_sec, r.match_sec, r.err,
                )
            }
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Main

    main :: proc() {
        opts := options__default()
        flags.parse_or_exit(&opts, os.args, .Odin)

        digits, ok := data__load(opts.data)
        if !ok do os.exit(1)
        defer delete(digits)

        if opts.blur > 0 {
            for &d in digits do d.pixels = pixels__blur(&d.pixels, opts.blur)
        }

        fold_of := folds__make(digits[:], opts.folds, opts.seed)
        defer delete(fold_of)

        eval := Eval{
            opts = opts,
            digits = digits[:],
            fold_of = fold_of,
            results = make([]Fold_Result, opts.folds),
        }
        defer delete(eval.results)

        start := time.tick_now()

        threads := make([]^thread.Thread, max(1, min(opts.threads, opts.folds)))
        defer delete(threads)
        for &t in threads do t = thread.create_and_start_with_poly_data(&eval, worker)
        thread.join_multiple(..threads)
        for t in threads do thread.destroy(t)

        total: Fold_Result
        for r in eval.results {
            if r.err != nil {
                fmt.eprintfln("Fold failed: %v", r.err)
                os.exit(1)
            }
            total.tested += r.tested
            total.correct += r.correct
            total.top3 += r.top3
            total.no_result += r.no_result
            total.train_sec += r.train_sec
            total.match_sec += r.match_sec
            total.cells += r.cells
        }

        fmt.printfln(
            "accuracy %.2f%% (%d/%d), top3 %.2f%%, no result %d, avg cells %v, train %.2fs/fold, match %.2fms/digit, wall %.1fs | %v",
            f64(total.correct) * 100 / f64(total.tested), total.correct, total.tested, f64(total.top3) * 100 / f64(total.tested), total.no_result,
            total.cells / opts.folds, total.train_sec / f64(opts.folds), total.match_sec * 1000 / f64(total.tested),
            time.duration_seconds(time.tick_since(start)), options__summary(&opts),
        )
    }

    options__summary :: proc(o: ^Options) -> string {
        return fmt.tprintf(
            "bp=%v vp_bp=%v n_bp=%v scoring=%v results=%v steps=%v fuzzy=%v null_damping=%v blur=%v shift=%v match_shift=%v link_layers=%v link_skip=%v link_level=%v stop=%v link_frame=%v no_seq_link=%v per_sample=%v retry=%v",
            o.bp, o.vp_bp, o.n_bp, o.scoring, o.results, o.steps, o.fuzzy, o.null_damping, o.blur, o.shift, o.match_shift, o.link_layers, o.link_skip, o.link_level, o.stop, o.link_frame, o.no_seq_link, o.per_sample, o.retry,
        )
    }
