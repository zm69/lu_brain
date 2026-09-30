![Lu_Brain banner](/img/banner.png?raw=true)
# 🧠 Lu_Brain

Ludyna Brain (Lu_Brain) is a human-like memory database, written in [Odin](https://odin-lang.org).

This is an Odin port of an experimental C project I created years ago. The code around the algorithm was rewritten in modern Odin:

- explicit allocators instead of a global `Lu_Mem`,
- typed slices, dynamic arrays and a small index pool instead of `void*` containers,
- tagged unions instead of virtual destructors,
- `Error` unions with `or_return` instead of exceptions.

### 🚧 ___This project is an EXPERIMENTAL, just-for-fun work in progress.___ 🚧

Accuracy on the Semeion handwritten digits (1,593 digits, 16×16), 10-fold cross-validation:

| Mode | Accuracy | Train (1,493 digits, 1 thread) | Net size | Match |
|---|---|---|---|---|
| Original C algorithm | ~74.5% | 0.6 s | ~1 M cells | ~70 ms / digit |
| Tuned (`CONFIGS[.Semeion_Tuned]`) | **~96.2%** | 0.2 s | ~8 k cells | ~16 ms / digit |

The CV results are averaged over 4 random fold splits (range 95.9–96.3%).

#### Honest comparison

The settings were chosen by watching CV scores on the same data, so they were also checked on a
clean holdout. Each method was tuned by CV on half A only, trained on A (800 digits), and tested
once on the untouched half B (793 digits):

| Method | Holdout accuracy | Match |
|---|---|---|
| Original C algorithm | 69.4% | 25 ms / digit |
| k-nearest-neighbour, raw pixels | 90.0% | 0.2 ms / digit |
| **Tuned Lu_Brain** | **95.3%** | 8.8 ms / digit |
| k-nearest-neighbour, same blur and ±1 px shift | **95.7%** | 0.7 ms / digit |

What this shows:

- The tuned mode is an **example-based patch classifier**. Computing the same patch score directly,
  without the memory graph, gives exactly the same predictions (`-mode:Patch` in the harness).
  The graph works as a shared index of patch patterns. It does not add accuracy.
- **kNN with the same preprocessing is as accurate and about 12× faster.** On this benchmark
  Lu_Brain's accuracy comes from the preprocessing and the patch voting, not from the memory
  structure itself.
- Lu_Brain's case has to rest on what the memory structure offers beyond accuracy: inspectable
  and editable memories, shared patterns, and deleting specific knowledge. None of this is
  benchmarked yet.

- ‼️It learns in one pass. Each digit is learned instantly and incrementally, with no retraining.
- ‼️No gradient descent.
- ‼️It doesn't use hardware acceleration yet.

### How the tuned mode works

The core algorithm is unchanged; the gain comes from how it is used plus a few new, opt-in config
options (their defaults reproduce the C version exactly):

- **Patch voting instead of one top cell.** Every training sample gets its own label, linked to all
  cells of rec level 1 (`link_level_to_label`). Each of those cells is a 2×2 patch pattern.
  With `Label_Scoring.Sum` a sample scores the sum of its matching patches over the whole image,
  and the class is voted over the 5 best (sample, offset) scores. The original C approach links one label per class
  to the single top cell. Because every layer averages 2×2 children, that top cell mostly "sees"
  the center of the image.
- **Grayscale with fuzzy values.** Images are blurred (3×3 box) into grayscale, quantized into
  3 value steps, and neighbouring steps also match with a partial signal (`p_fuzzy_radius = 1`).
- **Shift tolerance.** The test digit is matched at every ±1 px offset (`set_dest_start_pos`), and
  the best sample scores win. A sample that matches well at several offsets can take several of the
  5 voting places; counting each sample only once scores slightly lower (~95.8%).
- **Faster matching.** `w_match_max_level = 1` stops propagation above the level the labels live on.
  Results are identical, and matching is about 85× faster.
- **Smaller net.** `s_save_max_level = 1` builds only the layers that are used. Results are
  identical, the net shrinks from ~1 M to ~8 k cells, and training is ~4× faster.

`samples/semeion_eval` is the evaluation harness. Every option is a command-line flag, for example:

```sh
cd samples/semeion_eval && odin build . -o:speed -out:out/eval.exe
out/eval.exe                                            # original C algorithm
out/eval.exe -per-sample -no-seq-link -scoring:Sum -stop -stop-save -link-level:1 -match-shift:1 -fuzzy:1 -blur:1 -steps:3 -results:5
out/eval.exe -mode:Knn -blur:1 -match-shift:1 -results:3          # kNN baseline, same preprocessing
out/eval.exe -mode:Patch -match-shift:1 -fuzzy:1 -blur:1 -steps:3 -results:5   # patch score without the graph
out/eval.exe -holdout:Tune ...   /   -holdout:Test ...          # tune on half A, test once on half B
```

## Why Lu_Brain?

#### Dynamicity

Lu_Brain learns "on the fly", without retraining an artificial neural network (ANN). It can
"forget" patterns and learn new ones at any time, so it fits AI that keeps learning while it runs.
For example, a game AI could pick up new tricks from players during a game.

#### Transparency and control

In a "classic" ANN, knowledge lives somewhere in the weights, and it is hard to say where. Lu_Brain
shows you exactly where each piece of information is. You can make it forget specific patterns or
replace them with new ones, and you can see the complete path that led to a decision.

#### Speed

Learning speed does not depend on how many patterns were already learned, because there is no
gradient descent.

## Usage

```odin
import lu "lu_brain/src"

brain: lu.Brain
lu.brain_init(&brain, lu.CONFIGS[.Default]) or_return
defer lu.brain_terminate(&brain)

// 1. Add receivers (inputs), then build the net
rec := lu.add_rec(&brain, 16, 16, 1, lu.REC_CONFIGS[.Mono1_Image]) or_return
lu.build(&brain) or_return

// 2. Save: push two blocks (values are learned from the change between them), link to a label
save_wave: lu.Save_Wave
lu.save_wave_init(&save_wave, &brain) or_return
defer lu.save_wave_terminate(&save_wave)

lu.push(&save_wave, rec, blank[:], 16, 16, 1) or_return
lu.push(&save_wave, rec, pixels[:], 16, 16, 1) or_return
lu.save(&save_wave) or_return
lu.link_to_label(&save_wave, lu.N_AREA__SPECIAL_AREA_SKIP, 0, 0, 0, label) or_return

// 3. Match
match_wave: lu.Match_Wave
lu.match_wave_init(&match_wave, &brain) or_return
defer lu.match_wave_terminate(&match_wave)

lu.push(&match_wave, rec, blank[:], 16, 16, 1) or_return
lu.push(&match_wave, rec, pixels[:], 16, 16, 1) or_return
lu.match(&match_wave) or_return

for result in lu.match_results(&match_wave) do fmt.println(result.id, result.sig)
```

`Delete_Wave` (`delete_label`, `delete_neuron`) and `Restore_Wave` (`restore_from_label`,
`restore_values`) follow the same pattern.

Every procedure takes an allocator (brain) or uses the brain's allocator (waves). Brains and waves
are user-owned structs that keep internal pointers, so they must not be moved after init.

## Build and test

```sh
cd tests && odin test .                                  # test suite
cd tests && odin test . -define:LU_VALIDATIONS=false     # without validation asserts
cd src/lu_core && odin test .                            # core containers
cd samples/semeion && odin run . -o:speed -out:out/semeion.exe
```

`samples/semeion` trains on about 1,500 handwritten digits and recognizes 100 held-out ones, using the
tuned mode. Add `-define:SMN_BASELINE=true` to run the original C approach instead.

## Legal

___The library is free to use by everyone with good intentions (zlib license).___
