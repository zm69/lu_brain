/*
    2026 (c) Zaya, https://github.com/zm69

    Semeion handwritten digits: train Lu_Brain on most samples, then recognize the rest.

    Dataset: 1593 handwritten digits, 16x16, 1 bit per pixel (data/semeion.names).
    Port of the C examples/semeion/example_01.c.

    Run from this folder:
        odin run . -o:speed -out:out/semeion.exe
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

///////////////////////////////////////////////////////////////////////////////
// Digit

    Digit :: struct {
        id: int,
        name: int,
        pixels: [DIGIT__PIXEL_COUNT]lu.Value,
    }

    BLANK_PIXELS: [DIGIT__PIXEL_COUNT]lu.Value

    digit__print :: proc(self: ^Digit) {
        fmt.printf("\n--------------------------------------------------")
        fmt.printf("\nDigit: %v, id: %v\n\n", self.name, self.id)
        for y in 0..<DIGIT__H {
            for x in 0..<DIGIT__W do fmt.print(self.pixels[y * DIGIT__W + x] > 0.4 ? "X" : " ")
            fmt.println()
        }
        fmt.printf("--------------------------------------------------\n")
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

        //
        // Data
        //
        digits, ok := data__load(FILE_NAME, allocator)
        if !ok do return lu.API_Error.Invalid_Argument
        defer delete(digits)

        fmt.printf("\nLoaded %v samples", len(digits))

        training, test := data__split(digits[:], allocator)
        defer delete(training)
        defer delete(test)

        fmt.printf("\nSelected %v training and %v test samples", len(training), len(test))

        //
        // Brain
        //
        config := lu.CONFIGS[.Semeion_01]
        config.w_match_sig_breakpoint = 0.4

        brain: lu.Brain
        lu.brain_init(&brain, config, allocator) or_return
        defer lu.brain_terminate(&brain)

        image_rec := lu.add_rec(&brain, DIGIT__W, DIGIT__H, 1, lu.REC_CONFIGS[.Mono1_Image]) or_return

        // After all recs are added, build the brain
        lu.build(&brain) or_return

        save_wave: lu.Save_Wave
        lu.save_wave_init(&save_wave, &brain) or_return
        defer lu.save_wave_terminate(&save_wave)

        match_wave: lu.Match_Wave
        lu.match_wave_init(&match_wave, &brain) or_return
        defer lu.match_wave_terminate(&match_wave)

        fmt.printf("\n\nRandom sample:")
        digit__print(rand.choice(test[:]))

        //
        // Training
        //
        fmt.printf("\nTraining %v samples.. ", len(training))

        start := time.tick_now()

        for d in training {
            lu.push(&save_wave, image_rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.push(&save_wave, image_rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.save(&save_wave) or_return
            lu.link_to_label(&save_wave, lu.N_AREA__SPECIAL_AREA_SKIP, 0, 0, 0, d.name) or_return
        }

        fmt.printf(
            "\nTraining of %v samples in a single thread without hardware acceleration took %.2f sec\n",
            len(training),
            time.duration_seconds(time.tick_since(start)),
        )

        lu.print_net_stats(&brain)

        //
        // Testing
        //
        success_count := 0
        failed_count := 0

        fmt.printf("\n\nTesting samples.. ")

        start = time.tick_now()

        for d in test {
            lu.push(&match_wave, image_rec, BLANK_PIXELS[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.push(&match_wave, image_rec, d.pixels[:], DIGIT__W, DIGIT__H, 1) or_return
            lu.match(&match_wave) or_return

            results := lu.match_results(&match_wave)

            if len(results) > 0 && results[0].id == d.name {
                success_count += 1
            } else {
                failed_count += 1

                fmt.printf("\nFAILED to recognize:")
                digit__print(d)
                lu.print_results(&match_wave)
                fmt.printf("\nRESULT: %v\n", len(results) > 0 ? results[0].id : -1)
            }
        }

        match_time := time.duration_seconds(time.tick_since(start))

        fmt.printf("\n\nReport:")
        fmt.printf("\n\tSuccessfully recognized: %v", success_count)
        fmt.printf("\n\tFailed recognition: %v", failed_count)
        fmt.printf("\n\tAccuracy rate: %.2f%%", f64(success_count) / f64(len(test)) * 100)
        fmt.printf("\n\tMatching took %.3f sec (%.2f ms per sample)\n", match_time, match_time * 1000 / f64(len(test)))

        return nil
    }
