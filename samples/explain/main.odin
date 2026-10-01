/*
    2026 (c) Zaya, https://github.com/zm69

    What Lu_Brain's memory graph can do that k-nearest-neighbour can't (easily).

    The tuned Lu_Brain is an example-based patch classifier: kNN with the same preprocessing is as
    accurate and faster (see README, "Honest comparison"). This demo shows what the graph adds
    instead: every stored digit is made of shared 2x2 patch patterns (rec level 1 cells), and each
    pattern knows every training sample that contains it. That makes it possible to:

        1. see how knowledge is shared between samples and classes,
        2. explain a decision through the exact shared patches that caused it,
        3. forget one training sample and know which knowledge was only its own,
        4. edit knowledge at the pattern level (prune patterns) with no retraining.

    kNN keeps whole images. It can show the nearest image and delete whole examples, but it has no
    shared parts to point at, count, or edit without building an extra index -- which is what the
    graph is.

    Run from this folder:
        odin run . -o:speed -out:out/explain.exe
        odin run . -o:speed -out:out/explain.exe -define:EXPLAIN_SEED=5
*/
package explain

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:math/rand"
    import "core:os"
    import "core:slice"
    import "core:strconv"
    import "core:strings"
    import "core:time"

// Lu
    import lu "../../src"
    import lc "../../src/lu_core"

///////////////////////////////////////////////////////////////////////////////
// Defines

    DIGIT__W :: 16
    DIGIT__H :: 16
    DIGIT__PIXEL_COUNT :: DIGIT__W * DIGIT__H
    DIGIT__VALUE_COUNT :: 10

    PATCH__W :: DIGIT__W - 1 // rec level 1: one 2x2 patch per position
    PATCH__H :: DIGIT__H - 1

    TEST_SAMPLES_PER_DIGIT :: 10
    FILE_NAME :: "../semeion/data/semeion.data"

    SEED :: #config(EXPLAIN_SEED, 1)

    BLUR_RADIUS :: 1
    MATCH_SHIFT :: 1
    LINK_LEVEL :: 1

///////////////////////////////////////////////////////////////////////////////
// Data (same as samples/semeion)

    Pixels :: [DIGIT__PIXEL_COUNT]lu.Value

    Digit :: struct {
        id: int,
        name: int,
        pixels: Pixels,
    }

    BLANK_PIXELS: Pixels

    data__load :: proc(file_name: string, allocator: runtime.Allocator) -> (digits: [dynamic]Digit, ok: bool) {
        bytes, err := os.read_entire_file(file_name, allocator)
        if err != nil {
            fmt.eprintfln("Could not open file %v: %v", file_name, err)
            return
        }
        defer delete(bytes, allocator)

        digits = make([dynamic]Digit, 0, 1600, allocator)

        text := string(bytes)
        for line in strings.split_lines_iterator(&text) {
            fields := strings.fields(line, context.temp_allocator)
            if len(fields) < DIGIT__PIXEL_COUNT + DIGIT__VALUE_COUNT do continue

            digit := Digit{ id = len(digits), name = -1 }
            for i in 0..<DIGIT__PIXEL_COUNT do digit.pixels[i], _ = strconv.parse_f64(fields[i])
            for i in 0..<DIGIT__VALUE_COUNT {
                if v, _ := strconv.parse_int(fields[DIGIT__PIXEL_COUNT + i]); v != 0 do digit.name = i
            }
            if digit.name >= 0 do append(&digits, digit)
        }
        free_all(context.temp_allocator)

        return digits, true
    }

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

    data__split :: proc(digits: []Digit, allocator: runtime.Allocator) -> (training, test: [dynamic]^Digit) {
        training = make([dynamic]^Digit, 0, len(digits), allocator)
        test = make([dynamic]^Digit, 0, DIGIT__VALUE_COUNT * TEST_SAMPLES_PER_DIGIT, allocator)

        order := make([]int, len(digits), context.temp_allocator)
        for &o, i in order do o = i
        rand.shuffle(order)

        is_test := make([]bool, len(digits), context.temp_allocator)
        test_counts: [DIGIT__VALUE_COUNT]int
        for i in order {
            d := &digits[i]
            if test_counts[d.name] < TEST_SAMPLES_PER_DIGIT {
                test_counts[d.name] += 1
                is_test[i] = true
                append(&test, d)
            }
        }
        for &d, i in digits do if !is_test[i] do append(&training, &d)

        free_all(context.temp_allocator)
        return
    }

///////////////////////////////////////////////////////////////////////////////
// Brain: the tuned recipe (see samples/semeion)

    Candidate :: struct {
        sample: int,    // training index = label
        score: lu.Value,
        dx: int,
        dy: int,
    }

    Brain :: struct {
        brain: lu.Brain,
        rec: ^lu.Rec,
        save_wave: lu.Save_Wave,
        match_wave: lu.Match_Wave,
        delete_wave: lu.Delete_Wave,
        restore_wave: lu.Restore_Wave,
        training: []^Digit,
    }

    brain__init :: proc(self: ^Brain, training: []^Digit, allocator: runtime.Allocator) -> lu.Error {
        self.training = training

        config := lu.CONFIGS[.Semeion_Tuned]
        config.la_labels_size = max(config.la_labels_size, len(training))

        lu.brain_init(&self.brain, config, allocator) or_return
        self.rec = lu.add_rec(&self.brain, DIGIT__W, DIGIT__H, 1, lu.REC_CONFIGS[.Semeion_Tuned]) or_return
        lu.build(&self.brain) or_return

        lu.save_wave_init(&self.save_wave, &self.brain) or_return
        lu.match_wave_init(&self.match_wave, &self.brain) or_return
        lu.delete_wave_init(&self.delete_wave, &self.brain) or_return
        lu.restore_wave_init(&self.restore_wave, &self.brain) or_return

        for d, i in training {
            lu.push(&self.save_wave, self.rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.push(&self.save_wave, self.rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.save(&self.save_wave) or_return
            // label = training sample, linked to every 2x2 patch cell of the digit
            lu.link_level_to_label(&self.save_wave, self.rec, LINK_LEVEL, i) or_return
        }

        return nil
    }

    brain__terminate :: proc(self: ^Brain) {
        lu.restore_wave_terminate(&self.restore_wave)
        lu.delete_wave_terminate(&self.delete_wave)
        lu.match_wave_terminate(&self.match_wave)
        lu.save_wave_terminate(&self.save_wave)
        lu.brain_terminate(&self.brain)
    }

    brain__match_at :: proc(self: ^Brain, d: ^Digit, dx, dy: int) -> lu.Error {
        lu.set_dest_start_pos(self.rec, dx, dy)
        defer lu.set_dest_start_pos(self.rec, 0, 0)
        lu.push(&self.match_wave, self.rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
        lu.push(&self.match_wave, self.rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
        return lu.match(&self.match_wave)
    }

    // Recognized class (-1 if nothing matched) and the 5 best candidates over all offsets.
    brain__recognize :: proc(self: ^Brain, d: ^Digit, allocator := context.temp_allocator) -> (class: int, top: []Candidate, err: lu.Error) {
        combined := make([dynamic]Candidate, 0, 64, allocator)
        for dy in -MATCH_SHIFT..=MATCH_SHIFT {
            for dx in -MATCH_SHIFT..=MATCH_SHIFT {
                brain__match_at(self, d, dx, dy) or_return
                for r in lu.match_results(&self.match_wave) do append(&combined, Candidate{ r.id, r.sig, dx, dy })
            }
        }

        slice.stable_sort_by(combined[:], proc(a, b: Candidate) -> bool { return a.score > b.score })
        top = combined[:min(len(combined), self.brain.config.w_match_results_size)]

        votes: [DIGIT__VALUE_COUNT]lu.Value
        for c in top do votes[self.training[c.sample].name] += c.score

        class = -1
        for v, c in votes do if v > 0 && (class < 0 || v > votes[class]) do class = c
        return
    }

    // Accuracy over the test digits and time per digit.
    brain__evaluate :: proc(self: ^Brain, test: []^Digit) -> (accuracy: f64, ms_per_digit: f64, err: lu.Error) {
        start := time.tick_now()
        correct := 0
        for d in test {
            class, _ := brain__recognize(self, d) or_return
            if class == d.name do correct += 1
            free_all(context.temp_allocator)
        }
        ms_per_digit = time.duration_milliseconds(time.tick_since(start)) / f64(len(test))
        return f64(correct) * 100 / f64(len(test)), ms_per_digit, nil
    }

    brain__live_patterns :: proc(self: ^Brain) -> (count: int) {
        layer := lu.level_layer(&self.brain, self.rec, LINK_LEVEL)
        for &column in layer.s_table.columns do for &n_cell in column.cells do if !lu.n_cell__is_blank(&n_cell) do count += 1
        return
    }

    // Classes of the training samples linked to a pattern: count per class.
    brain__pattern_classes :: proc(self: ^Brain, addr: lu.N_Addr) -> (per_class: [DIGIT__VALUE_COUNT]int, samples: int) {
        labels, _ := lu.cell_labels(&self.brain, addr, context.temp_allocator)
        for l in labels do per_class[self.training[l].name] += 1
        return per_class, len(labels)
    }

///////////////////////////////////////////////////////////////////////////////
// Printing

    value__char :: proc(v: lu.Value) -> rune {
        if v < 0.17 do return '.'
        if v < 0.5 do return '+'
        return '#'
    }

    // 2x2 glyph of a stored pattern, rebuilt from the memory with a Restore_Wave.
    pattern__glyph :: proc(self: ^Brain, addr: lu.N_Addr) -> string {
        if lu.restore_from_neuron(&self.restore_wave, addr) != nil do return "????"
        values := lu.restore_values(&self.restore_wave)
        if values == nil do return "...."

        x, y := int(addr.column_ix) % PATCH__W, int(addr.column_ix) / PATCH__W
        return fmt.tprintf("%c%c/%c%c",
            value__char(values[y * DIGIT__W + x]), value__char(values[y * DIGIT__W + x + 1]),
            value__char(values[(y + 1) * DIGIT__W + x]), value__char(values[(y + 1) * DIGIT__W + x + 1]),
        )
    }

    pixels__patch_glyph :: proc(p: ^Pixels, x, y: int) -> string {
        return fmt.tprintf("%c%c/%c%c",
            value__char(p[y * DIGIT__W + x]), value__char(p[y * DIGIT__W + x + 1]),
            value__char(p[(y + 1) * DIGIT__W + x]), value__char(p[(y + 1) * DIGIT__W + x + 1]),
        )
    }

    per_class__string :: proc(per_class: [DIGIT__VALUE_COUNT]int) -> string {
        b := strings.builder_make(context.temp_allocator)
        first := true
        for n, c in per_class {
            if n == 0 do continue
            if !first do strings.write_string(&b, ", ")
            fmt.sbprintf(&b, "%v×'%v'", n, c)
            first = false
        }
        return strings.to_string(b)
    }

    // Right-justified column (fmt pads widths with zeros).
    rj :: proc(v: any, width: int) -> string {
        return strings.right_justify(fmt.tprint(v), width, " ", context.temp_allocator)
    }

    section :: proc(title: string) {
        fmt.printf("\n\n=============================================================================")
        fmt.printf("\n %s", title)
        fmt.printf("\n=============================================================================\n")
    }

///////////////////////////////////////////////////////////////////////////////
// 1. Sharing

    show_sharing :: proc(self: ^Brain) {
        section("1. Knowledge is stored as shared patterns")

        layer := lu.level_layer(&self.brain, self.rec, LINK_LEVEL)

        Pattern :: struct { addr: lu.N_Addr, samples: int, classes: int }
        patterns := make([dynamic]Pattern, context.temp_allocator)

        instances := 0
        classes_hist: [DIGIT__VALUE_COUNT + 1]int
        single_sample := 0

        for &column in layer.s_table.columns {
            for &n_cell in column.cells {
                if lu.n_cell__is_blank(&n_cell) do continue
                per_class, samples := brain__pattern_classes(self, n_cell.addr)
                classes := 0
                for n in per_class do if n > 0 do classes += 1

                instances += samples
                classes_hist[classes] += 1
                if samples == 1 do single_sample += 1
                append(&patterns, Pattern{ n_cell.addr, samples, classes })
            }
        }

        fmt.printf("\n %v training digits = %v patch instances (one 2x2 patch per position, %vx%v positions)",
            len(self.training), instances, PATCH__W, PATCH__H)
        fmt.printf("\n stored as %v distinct patterns: each pattern is reused %.1f times on average.",
            len(patterns), f64(instances) / f64(len(patterns)))
        fmt.printf("\n %v patterns (%.0f%%) belong to a single training digit; the rest are shared.\n",
            single_sample, f64(single_sample) * 100 / f64(len(patterns)))

        fmt.printf("\n How many digit classes use each pattern:")
        for n, classes in classes_hist {
            if classes == 0 do continue
            fmt.printf("\n   %s class%s %s patterns", rj(classes, 2), classes == 1 ? ":  " : "es:", rj(n, 6))
        }

        slice.sort_by(patterns[:], proc(a, b: Pattern) -> bool { return a.samples > b.samples })

        print_pattern :: proc(self: ^Brain, p: Pattern) {
            per_class, _ := brain__pattern_classes(self, p.addr)
            fmt.printf("\n   at (%s,%s)  %s  used by %s digits: %s",
                rj(int(p.addr.column_ix) % PATCH__W, 2), rj(int(p.addr.column_ix) / PATCH__W, 2),
                pattern__glyph(self, p.addr), rj(p.samples, 4), per_class__string(per_class))
        }

        fmt.printf("\n\n Most shared patterns (2x2 glyph, rows separated by /; . blank, + gray, # ink):")
        for p in patterns[:3] do print_pattern(self, p)

        fmt.printf("\n\n Most shared patterns that contain ink:")
        shown := 0
        for p in patterns {
            if shown >= 4 do break
            if !strings.contains_any(pattern__glyph(self, p.addr), "+#") do continue
            print_pattern(self, p)
            shown += 1
        }

        fmt.printf("\n\n Most shared class-specific patterns (used by many digits, all of one class):")
        shown = 0
        for p in patterns {
            if shown >= 4 do break
            if p.classes != 1 do continue
            print_pattern(self, p)
            shown += 1
        }

        fmt.printf("\n\n kNN keeps %v separate images; it has no shared parts to count or point at.\n", len(self.training))

        free_all(context.temp_allocator)
    }

///////////////////////////////////////////////////////////////////////////////
// 2. Explain

    Explanation :: struct {
        predicted: int,
        top: []Candidate,
        culprit: int,  // best sample of the predicted class
        rival: int,    // best sample of the true class (-1 if none fired)
    }

    // Per-sample score from the fired patches at one offset; the same Label_Scoring.Sum score the
    // brain computed, rebuilt from the memory.
    sample_scores :: proc(self: ^Brain, fired: []lu.Fired_Cell) -> map[int]lu.Value {
        scores := make(map[int]lu.Value, 1024, context.temp_allocator)
        for c in fired {
            labels, _ := lu.cell_labels(&self.brain, c.addr, context.temp_allocator)
            for l in labels do scores[l] += c.sig
        }
        return scores
    }

    explain :: proc(self: ^Brain, d: ^Digit, verbose: bool) -> (e: Explanation, err: lu.Error) {
        e.predicted, e.top = brain__recognize(self, d, context.allocator) or_return
        e.culprit, e.rival = -1, -1

        fmt.printf("\n Test digit #%v, true class '%v', recognized as '%v'%s\n",
            d.id, d.name, e.predicted, e.predicted == d.name ? " (correct)" : " (WRONG)")

        fmt.printf("\n Decision: the 5 best (training digit, offset) scores vote")
        for c in e.top {
            fmt.printf("\n   training digit #%-5v class '%v'  score %.2f  at offset (%+d,%+d)",
                self.training[c.sample].id, self.training[c.sample].name, c.score, c.dx, c.dy)
        }

        if len(e.top) == 0 do return

        // explain at the offset of the best candidate
        best := e.top[0]
        brain__match_at(self, d, best.dx, best.dy) or_return
        fired := lu.fired_cells(&self.match_wave, self.rec, LINK_LEVEL, context.temp_allocator) or_return
        scores := sample_scores(self, fired[:])

        rival_score: lu.Value = -1
        culprit_score: lu.Value = -1
        for sample, score in scores {
            name := self.training[sample].name
            if name == e.predicted && score > culprit_score { e.culprit, culprit_score = sample, score }
            if name == d.name && name != e.predicted && score > rival_score { e.rival, rival_score = sample, score }
        }

        if !verbose do return

        // where each side's evidence comes from
        culprit_sig, rival_sig: [PATCH__W * PATCH__H]lu.Value
        culprit_cell, rival_cell: [PATCH__W * PATCH__H]lu.N_Addr
        for c in fired {
            labels, _ := lu.cell_labels(&self.brain, c.addr, context.temp_allocator)
            pos := c.y * PATCH__W + c.x
            if slice.contains(labels[:], e.culprit) && c.sig > culprit_sig[pos] { culprit_sig[pos], culprit_cell[pos] = c.sig, c.addr }
            if e.rival >= 0 && slice.contains(labels[:], e.rival) && c.sig > rival_sig[pos] { rival_sig[pos], rival_cell[pos] = c.sig, c.addr }
        }

        p_char := rune('0' + e.predicted)
        t_char := rune('0' + d.name)

        fmt.printf("\n\n Evidence map at offset (%+d,%+d): which stored patches matched, per 2x2 position", best.dx, best.dy)
        if e.rival >= 0 {
            fmt.printf("\n   '%c' = only training digit #%v ('%v') has a matching patch here",
                p_char, self.training[e.culprit].id, e.predicted)
            fmt.printf("\n   '%c' = only training digit #%v ('%v', best of the true class) has one",
                t_char, self.training[e.rival].id, d.name)
            fmt.printf("\n   ':' = both match (shared evidence),  ' ' = neither")
        }

        shifted := d.pixels
        fmt.printf("\n\n   test digit          evidence map")
        for y in 0..<DIGIT__H {
            fmt.printf("\n   ")
            for x in 0..<DIGIT__W do fmt.printf("%c", value__char(shifted[y * DIGIT__W + x]))
            fmt.printf("    ")
            if y < PATCH__H {
                for x in 0..<PATCH__W {
                    pos := y * PATCH__W + x
                    a, b := culprit_sig[pos] > 0, rival_sig[pos] > 0
                    ch := ' '
                    if a && b do ch = ':'
                    else if a do ch = p_char
                    else if b do ch = t_char
                    fmt.printf("%c", ch)
                }
            }
        }

        if e.rival < 0 {
            fmt.printf("\n\n (no sample of the true class matched at this offset)\n")
            return
        }

        fmt.printf("\n\n Score at this offset: #%v ('%v') %.2f  vs  #%v ('%v') %.2f",
            self.training[e.culprit].id, e.predicted, scores[e.culprit],
            self.training[e.rival].id, d.name, scores[e.rival])

        // decisive patches: matched for the culprit, not for the rival
        Decisive :: struct { pos: int, margin: lu.Value }
        decisive := make([dynamic]Decisive, context.temp_allocator)
        for pos in 0..<PATCH__W * PATCH__H {
            margin := culprit_sig[pos] - rival_sig[pos]
            if margin > 0 do append(&decisive, Decisive{ pos, margin })
        }
        slice.sort_by(decisive[:], proc(a, b: Decisive) -> bool { return a.margin > b.margin })

        fmt.printf("\n\n Decisive patches (matched for '%v' but not for '%v'):", e.predicted, d.name)
        fmt.printf("\n   pos       test  '%v' patch  shared by (stored pattern)", e.predicted)
        for dec in decisive[:min(6, len(decisive))] {
            x, y := dec.pos % PATCH__W, dec.pos / PATCH__W
            per_class, samples := brain__pattern_classes(self, culprit_cell[dec.pos])
            fmt.printf("\n   (%s,%s)  %s   %s       %d digits: %s",
                rj(x, 2), rj(y, 2), pixels__patch_glyph(&shifted, x, y), pattern__glyph(self, culprit_cell[dec.pos]),
                samples, per_class__string(per_class))
        }

        fmt.printf("\n\n Every vote above is traceable to named, shared stored patterns.")
        fmt.printf("\n kNN could only say: \"nearest image is #%v\" and show a pixel difference.\n", self.training[e.culprit].id)
        return
    }

///////////////////////////////////////////////////////////////////////////////
// 3. Forget one sample

    forget :: proc(self: ^Brain, sample: int, d: ^Digit, test: []^Digit) -> lu.Error {
        cells, _ := lu.label_cells(&self.brain, sample, context.allocator)
        defer delete(cells)

        unique, shared := 0, 0
        for addr in cells {
            if lu.cell_labels_count(&self.brain, lu.get_n_cell(&self.brain, addr)) == 1 do unique += 1
            else do shared += 1
        }

        acc_before, _ := brain__evaluate(self, test) or_return
        patterns_before := brain__live_patterns(self)

        fmt.printf("\n Training digit #%v ('%v') owns %v patch patterns:", self.training[sample].id, self.training[sample].name, len(cells))
        fmt.printf("\n   %s are only its own  -> will be freed", rj(unique, 3))
        fmt.printf("\n   %s are shared with other digits -> kept, the other digits keep their knowledge", rj(shared, 3))

        lu.delete_label(&self.delete_wave, sample) or_return

        after, _ := lu.label_cells(&self.brain, sample, context.allocator)
        defer delete(after)
        still_live := 0
        for addr in cells do if lu.is_cell_live(&self.brain, addr) do still_live += 1

        patterns_after := brain__live_patterns(self)
        acc_after, _ := brain__evaluate(self, test) or_return
        fmt.printf("\n\n After delete_label(#%v):", self.training[sample].id)
        fmt.printf("\n   cells linked to it: %v, its former patterns still live: %v (= shared %v)", len(after), still_live, shared)
        fmt.printf("\n   distinct patterns in memory: %v -> %v (-%v)", patterns_before, patterns_after, patterns_before - patterns_after)
        if d != nil {
            class, top := brain__recognize(self, d) or_return
            fmt.printf("\n   test digit #%v is now recognized as '%v' (true '%v')%s",
                d.id, class, d.name, class == d.name ? " -- fixed" : " -- still wrong;")
            if class != d.name {
                fmt.printf(" the vote is now led by:")
                for c in top do fmt.printf(" #%v('%v')", self.training[c.sample].id, self.training[c.sample].name)
            }
        }
        fmt.printf("\n   accuracy on all %v test digits: %.0f%% -> %.0f%%", len(test), acc_before, acc_after)

        fmt.printf("\n")
        free_all(context.temp_allocator)
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// 4. Prune

    Prune_Rule :: struct {
        name: string,
        min_classes: int,   // prune patterns used by digits of >= min_classes classes (0 = off)
        max_samples: int,   // prune patterns used by <= max_samples digits (0 = off)
    }

    // Deletes the patterns matching the rule. Returns how many.
    prune :: proc(self: ^Brain, rule: Prune_Rule) -> (pruned: int, err: lu.Error) {
        layer := lu.level_layer(&self.brain, self.rec, LINK_LEVEL)

        targets := make([dynamic]lu.N_Addr, context.temp_allocator)
        for &column in layer.s_table.columns {
            for &n_cell in column.cells {
                if lu.n_cell__is_blank(&n_cell) do continue
                per_class, samples := brain__pattern_classes(self, n_cell.addr)
                classes := 0
                for n in per_class do if n > 0 do classes += 1
                hit := (rule.min_classes > 0 && classes >= rule.min_classes) || (rule.max_samples > 0 && samples <= rule.max_samples)
                if hit do append(&targets, n_cell.addr)
            }
        }

        for addr in targets do lu.delete_neuron(&self.delete_wave, addr) or_return

        free_all(context.temp_allocator)
        return len(targets), nil
    }

    show_pruning :: proc(training, test: []^Digit, allocator: runtime.Allocator) -> lu.Error {
        section("4. Edit knowledge at the pattern level: prune uninformative patterns")

        fmt.printf("\n Every pattern can be deleted on its own with delete_neuron -- instantly, no retraining --")
        fmt.printf("\n and the effect measured. Two hypotheses, tested:")
        fmt.printf("\n   a) patterns shared by many classes carry little information (background, common strokes)")
        fmt.printf("\n   b) patterns used by only one or two digits are noise\n")
        fmt.printf("\n   prune                              patterns left   accuracy   ms / digit")

        rules := []Prune_Rule{
            { "nothing", 0, 0 },
            { "a) used by all 10 classes", 10, 0 },
            { "a) used by >= 9 classes", 9, 0 },
            { "a) used by >= 8 classes", 8, 0 },
            { "b) used by 1 digit only", 0, 1 },
            { "b) used by <= 2 digits", 0, 2 },
            { "b) used by <= 5 digits", 0, 5 },
        }

        for rule in rules {
            b: Brain
            brain__init(&b, training, allocator) or_return
            defer brain__terminate(&b)

            prune(&b, rule) or_return

            acc, ms := brain__evaluate(&b, test) or_return
            fmt.printf("\n   %s %s        %s%%     %s",
                strings.left_justify(rule.name, 32, " ", context.temp_allocator),
                rj(brain__live_patterns(&b), 8), rj(fmt.tprintf("%.0f", acc), 5), rj(fmt.tprintf("%.2f", ms), 7))
            free_all(context.temp_allocator)
        }

        fmt.printf("\n\n Hypothesis a) is wrong: agreeing on background is real evidence.")
        fmt.printf("\n The point is not that these rules are good, but that knowledge can be edited and")
        fmt.printf("\n measured at the level of individual shared parts.")
        fmt.printf("\n\n kNN has no parts to remove; the closest equivalent is masking pixels or changing")
        fmt.printf("\n its distance metric, which affects every example the same way.\n")
        return nil
    }

///////////////////////////////////////////////////////////////////////////////
// Main

    main :: proc() {
        mt: lc.Mem_Track
        allocator := lc.mem_track__init(&mt, context.allocator)
        defer lc.mem_track__terminate(&mt)

        context.allocator = allocator

        if err := run(allocator); err != nil do fmt.eprintfln("\nError: %v", err)

        free_all(context.temp_allocator)
        lc.mem_track__panic_if_bad_frees_or_leaks(&mt)
    }

    run :: proc(allocator: runtime.Allocator) -> lu.Error {
        rand.reset(u64(SEED))

        digits, ok := data__load(FILE_NAME, allocator)
        if !ok do return lu.API_Error.Invalid_Argument
        defer delete(digits)

        for &d in digits do d.pixels = pixels__blur(&d.pixels, BLUR_RADIUS)

        training, test := data__split(digits[:], allocator)
        defer delete(training)
        defer delete(test)

        fmt.printf("Lu_Brain explainability demo -- Semeion digits, %v training / %v test, seed %v",
            len(training), len(test), SEED)

        b: Brain
        brain__init(&b, training[:], allocator) or_return
        defer brain__terminate(&b)

        acc, ms := brain__evaluate(&b, test[:]) or_return
        fmt.printf("\nTuned brain: %.0f%% of the test digits correct, %.1f ms per digit", acc, ms)

        //
        // 1. Sharing
        //
        show_sharing(&b)

        //
        // 2. Explain one correct and one wrong decision
        //
        section("2. Explain a decision through the shared patches that caused it")

        wrong: ^Digit
        for d in test {
            class, _ := brain__recognize(&b, d) or_return
            free_all(context.temp_allocator)
            if class != d.name { wrong = d; break }
        }

        {
            e := explain(&b, test[0], false) or_return
            delete(e.top)
            free_all(context.temp_allocator)
        }

        if wrong == nil {
            fmt.printf("\n\n (all test digits were recognized; try another -define:EXPLAIN_SEED)\n")
        } else {
            fmt.printf("\n -----------------------------------------------------------------------------")
            e := explain(&b, wrong, true) or_return
            defer delete(e.top)
            culprit := e.culprit
            free_all(context.temp_allocator)

            //
            // 3. Forget the training digit that caused the mistake
            //
            section("3. Forget a training digit, with provenance")
            if culprit >= 0 {
                fmt.printf("\n First the training digit that led the wrong vote:\n")
                forget(&b, culprit, wrong, test[:]) or_return
            }

            // the training digit with the most patterns of its own
            unusual, unusual_count := -1, -1
            for _, i in training {
                cells, _ := lu.label_cells(&b.brain, i, context.temp_allocator)
                own := 0
                for addr in cells do if lu.cell_labels_count(&b.brain, lu.get_n_cell(&b.brain, addr)) == 1 do own += 1
                if own > unusual_count { unusual, unusual_count = i, own }
                free_all(context.temp_allocator)
            }
            fmt.printf("\n For contrast, the most unusual training digit (most patterns of its own):\n")
            forget(&b, unusual, nil, test[:]) or_return

            fmt.printf("\n kNN can delete an example too, but cannot say which knowledge was only that example's.\n")
        }

        //
        // 4. Prune uninformative patterns
        //
        show_pruning(training[:], test[:], allocator) or_return

        section("What this shows -- and what it doesn't")
        fmt.printf("\n + Decisions decompose into stored, shared sub-patterns with known owners.")
        fmt.printf("\n + Knowledge can be removed per training digit (with provenance) or per pattern,")
        fmt.printf("\n   instantly and without retraining.")
        fmt.printf("\n - Accuracy is no better than kNN with the same preprocessing, and matching is slower.")
        fmt.printf("\n - Whether pattern-level editing is useful needs a real application, not this demo.\n")

        return nil
    }
