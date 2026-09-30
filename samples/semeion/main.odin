/*
    2026 (c) Zaya, https://github.com/zm69

    Semeion handwritten digits: train Lu_Brain on most samples, then recognize the rest.

    Dataset: 1593 handwritten digits, 16x16, 1 bit per pixel (data/semeion.names).

    Two modes:
      - tuned (default): patch voting, ~96% (10-fold cross-validation, see samples/semeion_eval)
          * images are blurred (3x3 box) into grayscale, 3 value steps with fuzzy matching,
          * every training sample gets its own label, linked to all cells of rec level 1 (2x2 patches),
          * a sample scores the sum of its matching patches (Label_Scoring.Sum),
          * the test digit is matched at every +-1 px offset, the class is voted over the top 5 samples.
      - baseline (-define:SMN_BASELINE=true): the original C example_01, ~75%
          * one label per class, linked to the top seq cell only.

    Run from this folder:
        odin run . -o:speed -out:out/semeion.exe
        odin run . -o:speed -out:out/semeion.exe -define:SMN_BASELINE=true
    Fixed sample split:
        odin run . -o:speed -out:out/semeion.exe -define:SMN_SEED=42
*/
package semeion

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

    TEST_SAMPLES_PER_DIGIT :: 10

    FILE_NAME :: "data/semeion.data"

    SEED :: #config(SMN_SEED, 0) // 0 = random
    BASELINE :: #config(SMN_BASELINE, false)

    // Tuned mode
    BLUR_RADIUS :: 1
    MATCH_SHIFT :: 1
    LINK_LEVEL :: 1

///////////////////////////////////////////////////////////////////////////////
// Digit

    Pixels :: [DIGIT__PIXEL_COUNT]lu.Value

    Digit :: struct {
        id: int,
        name: int,
        pixels: Pixels,
    }

    BLANK_PIXELS: Pixels

    digit__print :: proc(self: ^Digit) {
        fmt.printf("\n--------------------------------------------------")
        fmt.printf("\nDigit: %v, id: %v\n\n", self.name, self.id)
        for y in 0..<DIGIT__H {
            for x in 0..<DIGIT__W do fmt.print(self.pixels[y * DIGIT__W + x] > 0.4 ? "X" : " ")
            fmt.println()
        }
        fmt.printf("--------------------------------------------------\n")
    }

    // Box blur; averages only in-bounds pixels.
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

///////////////////////////////////////////////////////////////////////////////
// Data

    // Each line: 256 pixel values followed by 10 one-hot digit values.
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

            for i in 0..<DIGIT__PIXEL_COUNT {
                digit.pixels[i], _ = strconv.parse_f64(fields[i])
            }

            for i in 0..<DIGIT__VALUE_COUNT {
                if v, _ := strconv.parse_int(fields[DIGIT__PIXEL_COUNT + i]); v != 0 do digit.name = i
            }

            if digit.name < 0 {
                fmt.eprintfln("Sample %v has no digit value", digit.id)
                delete(digits)
                return nil, false
            }

            append(&digits, digit)
        }

        free_all(context.temp_allocator)

        return digits, true
    }

    // Picks TEST_SAMPLES_PER_DIGIT random samples of every digit for testing, the rest for training.
    data__split :: proc(digits: []Digit, allocator: runtime.Allocator) -> (training, test: [dynamic]^Digit) {
        training = make([dynamic]^Digit, 0, len(digits), allocator)
        test = make([dynamic]^Digit, 0, DIGIT__VALUE_COUNT * TEST_SAMPLES_PER_DIGIT, allocator)

        order := make([]int, len(digits), context.temp_allocator)
        for &o, i in order do o = i
        rand.shuffle(order)

        test_counts: [DIGIT__VALUE_COUNT]int
        for i in order {
            d := &digits[i]
            if test_counts[d.name] < TEST_SAMPLES_PER_DIGIT {
                test_counts[d.name] += 1
                append(&test, d)
            }
        }

        // training keeps the original order
        for &d in digits {
            is_test := false
            for t in test do if t == &d { is_test = true; break }
            if !is_test do append(&training, &d)
        }

        return
    }

///////////////////////////////////////////////////////////////////////////////
// Recognition

    Recognizer :: struct {
        brain: lu.Brain,
        rec: ^lu.Rec,
        save_wave: lu.Save_Wave,
        match_wave: lu.Match_Wave,
        training: []^Digit,
    }

    recognizer__init :: proc(self: ^Recognizer, training: []^Digit, allocator: runtime.Allocator) -> lu.Error {
        self.training = training

        config := lu.CONFIGS[.Semeion_Tuned] when !BASELINE else lu.CONFIGS[.Semeion_01]
        rec_config := lu.REC_CONFIGS[.Semeion_Tuned] when !BASELINE else lu.REC_CONFIGS[.Mono1_Image]

        when BASELINE do config.w_match_sig_breakpoint = 0.4
        else do config.la_labels_size = max(config.la_labels_size, len(training))

        lu.brain_init(&self.brain, config, allocator) or_return

        self.rec = lu.add_rec(&self.brain, DIGIT__W, DIGIT__H, 1, rec_config) or_return

        // After all recs are added, build the brain
        lu.build(&self.brain) or_return

        lu.save_wave_init(&self.save_wave, &self.brain) or_return
        lu.match_wave_init(&self.match_wave, &self.brain) or_return

        return nil
    }

    recognizer__terminate :: proc(self: ^Recognizer) {
        lu.match_wave_terminate(&self.match_wave)
        lu.save_wave_terminate(&self.save_wave)
        lu.brain_terminate(&self.brain)
    }

    recognizer__train :: proc(self: ^Recognizer) -> lu.Error {
        for d, i in self.training {
            lu.push(&self.save_wave, self.rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.push(&self.save_wave, self.rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.save(&self.save_wave) or_return

            when BASELINE {
                // label = class, on the top (seq) cell
                lu.link_to_label(&self.save_wave, lu.N_AREA__SPECIAL_AREA_SKIP, 0, 0, 0, d.name) or_return
            } else {
                // label = training sample, on every 2x2 patch cell
                lu.link_level_to_label(&self.save_wave, self.rec, LINK_LEVEL, i) or_return
            }
        }
        return nil
    }

    // Returns the recognized class, -1 if nothing matched.
    recognizer__recognize :: proc(self: ^Recognizer, d: ^Digit) -> (class: int, err: lu.Error) {
        when BASELINE {
            match_at(self, d, 0, 0) or_return
            results := lu.match_results(&self.match_wave)
            return len(results) > 0 ? results[0].id : -1, nil
        } else {
            // best sample scores over every offset
            combined := make([dynamic]lu.Label, 0, 64, context.temp_allocator)
            for dy in -MATCH_SHIFT..=MATCH_SHIFT {
                for dx in -MATCH_SHIFT..=MATCH_SHIFT {
                    match_at(self, d, dx, dy) or_return
                    append(&combined, ..lu.match_results(&self.match_wave))
                }
            }
            lu.set_dest_start_pos(self.rec, 0, 0)

            slice.sort_by(combined[:], proc(a, b: lu.Label) -> bool { return a.sig > b.sig })
            top := combined[:min(len(combined), self.brain.config.w_match_results_size)]

            // vote: sum of sample scores per class
            votes: [DIGIT__VALUE_COUNT]lu.Value
            for label in top do votes[self.training[label.id].name] += label.sig

            class = -1
            for v, c in votes {
                if v > 0 && (class < 0 || v > votes[class]) do class = c
            }
            return class, nil
        }
    }

    @(private="file")
    match_at :: proc(self: ^Recognizer, d: ^Digit, dx, dy: int) -> lu.Error {
        lu.set_dest_start_pos(self.rec, dx, dy)
        lu.push(&self.match_wave, self.rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
        lu.push(&self.match_wave, self.rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
        return lu.match(&self.match_wave)
    }

///////////////////////////////////////////////////////////////////////////////
// Main

    main :: proc() {
        mt: lc.Mem_Track
        allocator := lc.mem_track__init(&mt, context.allocator)
        defer lc.mem_track__terminate(&mt)

        err := run(allocator)
        if err != nil do fmt.eprintfln("\nError: %v", err)

        free_all(context.temp_allocator)
        lc.mem_track__panic_if_bad_frees_or_leaks(&mt)
    }

    run :: proc(allocator: runtime.Allocator) -> lu.Error {
        when SEED != 0 do rand.reset(u64(SEED))

        fmt.printf("\nMode: %s", BASELINE ? "baseline (C algorithm)" : "tuned (patch voting)")

        //
        // Data
        //
        digits, ok := data__load(FILE_NAME, allocator)
        if !ok do return lu.API_Error.Invalid_Argument
        defer delete(digits)

        fmt.printf("\nLoaded %v samples", len(digits))

        when !BASELINE {
            for &d in digits do d.pixels = pixels__blur(&d.pixels, BLUR_RADIUS)
        }

        training, test := data__split(digits[:], allocator)
        defer delete(training)
        defer delete(test)

        fmt.printf("\nSelected %v training and %v test samples", len(training), len(test))

        fmt.printf("\n\nRandom sample:")
        digit__print(rand.choice(test[:]))

        //
        // Brain
        //
        recognizer: Recognizer
        recognizer__init(&recognizer, training[:], allocator) or_return
        defer recognizer__terminate(&recognizer)

        //
        // Training
        //
        fmt.printf("\nTraining %v samples.. ", len(training))

        start := time.tick_now()
        recognizer__train(&recognizer) or_return

        fmt.printf(
            "\nTraining of %v samples in a single thread without hardware acceleration took %.2f sec\n",
            len(training),
            time.duration_seconds(time.tick_since(start)),
        )

        lu.print_net_stats(&recognizer.brain)

        //
        // Testing
        //
        success_count := 0

        fmt.printf("\n\nTesting samples.. ")

        start = time.tick_now()

        for d in test {
            class := recognizer__recognize(&recognizer, d) or_return
            free_all(context.temp_allocator)

            if class == d.name {
                success_count += 1
            } else {
                fmt.printf("\nFAILED to recognize (got %v):", class)
                digit__print(d)
            }
        }

        match_time := time.duration_seconds(time.tick_since(start))

        fmt.printf("\n\nReport:")
        fmt.printf("\n\tSuccessfully recognized: %v", success_count)
        fmt.printf("\n\tFailed recognition: %v", len(test) - success_count)
        fmt.printf("\n\tAccuracy rate: %.2f%%", f64(success_count) / f64(len(test)) * 100)
        fmt.printf("\n\tMatching took %.3f sec (%.2f ms per sample)\n", match_time, match_time * 1000 / f64(len(test)))

        return nil
    }
