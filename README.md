![Lu_Brain banner](/img/banner.png?raw=true)
# 🧠 Lu_Brain

Ludyna Brain (Lu_Brain) is a human-like memory database, written in [Odin](https://odin-lang.org).

This is an Odin port of an experimental C project I created years ago.

So far Lu_Brain distinct value is in what kNN can't do: shared patterns, explanations, and fine-grained forgetting.

### 🚧 ___This project is an EXPERIMENTAL, just-for-fun work in progress.___ 🚧

- ‼️It learns in one pass. Each example is learned instantly and incrementally, with no retraining.
- ‼️No gradient descent.
- ‼️It doesn't use hardware acceleration yet.

## Accuracy

Semeion handwritten digits (1,593 digits, 16×16), 10-fold cross-validation averaged over 4 random
fold splits:

| Mode | Accuracy | Train (1,493 digits, 1 thread) | Net size | Match |
|---|---|---|---|---|
| Original C algorithm | ~74.5% | 0.6 s | ~0.9 M cells | ~70 ms / digit |
| Tuned (`CONFIGS[.Semeion_Tuned]` + deskew) | **~97.1%** (range 96.9–97.3%) | 0.2 s | ~8 k cells | ~19 ms / digit |

#### Honest comparison

The tuned settings were chosen by watching CV scores on the same data, so they were also checked on
a clean holdout: settings chosen by CV on half A only, trained on A (800 digits), tested once on
the untouched half B (793 digits):

| Method | Holdout accuracy |
|---|---|
| Original C algorithm | 69.4% |
| k-nearest-neighbour, raw pixels | 90.0% |
| Tuned Lu_Brain without rarity weights, no deskew | 95.3% |
| k-nearest-neighbour, same blur and ±1 px shift, no deskew | 95.7% |
| Tuned Lu_Brain, no deskew | 96.0% |
| **Tuned Lu_Brain (current, with deskew)** | **96.2%** |
| **k-nearest-neighbour, same blur, ±1 px shift and deskew** | **97.4%** |

Matching takes ~10–20 ms per digit for Lu_Brain and ~1 ms for kNN.

What this shows:

- The tuned mode is an **example-based patch classifier**. Computing the same patch score directly,
  without the memory graph, gives exactly the same predictions (`-mode:Patch` in the harness).
  The graph works as a shared index of patch patterns.
- **kNN with the same preprocessing is at least as accurate and more than 10× faster.** Without
  deskewing the two were tied (rarity weighting put Lu_Brain slightly ahead, within noise).
  Deskewing helps kNN much more (+1.6 points on the holdout) than Lu_Brain (+0.3), probably because
  kNN uses the exact intensities, while Lu_Brain quantizes them into 3 value steps. With deskew,
  kNN is clearly ahead (97.4% vs 96.2% on the holdout, 97.6% vs 97.1% in cross-validation).
- Lu_Brain's case rests on what the memory structure offers beyond accuracy: inspectable and
  editable memories, shared patterns, and deleting specific knowledge. These are demonstrated in
  `samples/explain` (below), but not benchmarked.

## How the tuned mode works

The core algorithm is the C one; the gain comes from how it is used plus a few opt-in config
options (their defaults reproduce the C version exactly):

- **Patch voting instead of one top cell.** Every training sample gets its own label, linked to all
  cells of rec level 1 (`link_level_to_label`). Each of those cells is a 2×2 patch pattern. With
  `Label_Scoring.Sum` a sample scores the sum of its matching patches over the whole image. The
  original C approach links one label per class to the single top cell; because every layer averages
  2×2 children, that top cell mostly "sees" the center of the image.
- **Deskew, then grayscale with fuzzy values.** Every image is sheared upright using its pixel
  moments (preprocessing in `samples/semeion`), blurred (3×3 box) into grayscale, quantized into
  3 value steps, and neighbouring steps also match with a partial signal (`p_fuzzy_radius = 1`).
- **Shift tolerance.** The test digit is matched at every ±1 px offset (`set_dest_start_pos`), and
  the class is voted over the 5 best (sample, offset) scores.
- **Rare patterns count a little more.** `w_match_idf_power = 0.2` multiplies a pattern's signal by
  `log((labels + 1) / labels using the pattern)^0.2`. A gentle tilt, not a removal: common
  background patterns still count. About +0.6 points in cross-validation and on the holdout.
- **Faster and smaller.** `w_match_max_level = 1` stops match propagation above the level the labels
  live on, and `s_save_max_level = 1` builds only the layers that are used. Results are identical;
  matching is much faster and the net shrinks from ~0.9 M to ~8 k cells.

## Explainability and editing demo

`samples/explain` shows what kNN can't do easily. Every stored digit is made of shared 2×2 patch
patterns, and each pattern knows every training digit that contains it:

- **Sharing.** 1,493 training digits = 335,925 patch instances, stored as 6,976 distinct patterns
  (each reused ~48×), with per-pattern class statistics.
- **Explaining a decision through the shared patches that caused it.** For a misrecognized '9'
  (read as '8') it prints an evidence map: where only the winning '8' sample matched, where only the
  best '9' sample matched, and where both did. It then lists the decisive patterns with the classes
  of the digits that share them:

  ```
     test digit          evidence map
     ..##########....    ::::::::::88:::
     .+##+++++###+...    ::::::::::88:::
     +###+....+##+...    ::::::::::88:::
     +###+....+##+...    ::::::88::88:::
  ```
- **Forgetting with provenance.** `delete_label` on one training digit reports which of its
  patterns were only its own (freed) and which are shared (kept for the other digits). The digit
  that led the wrong vote above had 0 patterns of its own; forgetting it does not fix the mistake,
  because other similar digits still outvote the '9'.
- **Editing at the pattern level.** Patterns can be deleted one by one with `delete_neuron` and the
  effect measured instantly. On the demo's 100 test digits, pruning patterns used by ≤ 2 digits
  removes 7% of the memory with no accuracy loss (≤ 5 digits: 17% less memory, one more digit
  wrong). Pruning patterns shared by all classes drops accuracy from 97% to 67%, because background
  agreement is real evidence.

kNN keeps whole images. It can show the nearest image and delete whole examples, but it has no
shared parts to point at, count or edit without building an extra index, and that index is what
the graph is. Whether pattern-level editing pays off still needs a real application.

## What was tried to improve accuracy

Measured with 10-fold cross-validation (1–4 seeds) and, for anything promising, on the A/B holdout.

| Idea | Result |
|---|---|
| Pattern weight by rarity (`w_match_idf_power`) | **+0.6** at power 0.2 (holdout 95.3% → 96.0%), kept; powers ≥ 0.3 hurt |
| Pattern weight by class purity (`w_match_purity_power`, needs `set_label_group`) | hurts at every power tried |
| Learned link weights (`reinforce`, leave-one-out correction passes) | fewer training errors (546 → 245), but no holdout gain |
| kNN re-ranking of the brain's candidates | ≈ kNN alone |
| Score fusion brain + kNN | +0.3 to +0.6 over the brain without rarity weights; ≈ the current brain |
| Evidence map: penalize clustered mismatch regions | no gain, or worse |
| Evidence map: learned weight per 2×2 position | +1 to +3 digits in CV, worse on the holdout (96.0% → 95.6%) |
| Evidence map: weight per position and class | clearly worse (overfits) |
| Evidence map: two-class re-check of the disputed region | worse |
| Image distortion model: each patch finds its own best alignment within ±1 / ±2 px | worse (95.8–96.1%; ±2 down to 70%) |
| Image distortion model: global ±1 shift + per-patch ±1 refinement | 2×2 patches: equal or worse; 3×3 patches: +0.1 to +0.25 over their own baseline, still below 2×2 |
| Deskew (shear upright by pixel moments) | **+0.4** CV (+0.6 with 4 value steps), +0.3 holdout, kept; helps kNN much more (+1.2 CV, +1.6 holdout) |
| Stroke-direction channels (Sobel orientation, 2–8 channels as extra rec components) | at best equal (97.05%), with tuning: exact component match on save, per-channel zero damping 0.4; without it down to chance |

Lessons:

- The brain and kNN mostly fail on the *same* digits, so combining them can add at most ~1 point.
- The brain's score already is the sum of the evidence map, so re-ranking by where the mismatches
  are mostly double-counts them. The evidence map's value is explanation, not accuracy.
- A 2×2 patch is too small for per-patch distortion: wrong digits find matching patches as easily
  as the right ones. Shifting the whole digit already captures the useful tolerance.
- Extra input channels need care: channels that are zero almost everywhere (like stroke direction)
  dominate both cell reuse on save and firing on match. Per-component configs
  (`Rec_Config.comp_configs`) allow separate value steps and zero damping per channel, but the
  direction channels still did not add accuracy here.
- Learned link weights did not improve accuracy, but they are a real capability: `reinforce`
  changes only the links of the patches where the wrong and the right answer differ, so every
  correction is local and explainable.

`samples/semeion_eval` is the evaluation harness. Every option is a command-line flag:

```sh
cd samples/semeion_eval && odin build . -o:speed -out:out/eval.exe
out/eval.exe                                                     # original C algorithm
out/eval.exe -mode:Hybrid -blur:1 -steps:3 -fuzzy:1 -match-shift:1 -idf:0.2 -deskew   # current tuned brain vs kNN vs fusion
out/eval.exe -mode:Knn -blur:1 -match-shift:1 -results:3                  # kNN baseline, same preprocessing
out/eval.exe -mode:Patch -match-shift:1 -fuzzy:1 -blur:1 -steps:3 -results:5   # patch score without the graph
out/eval.exe ... -holdout:Tune   /   ... -holdout:Test             # tune on half A, test once on half B
out/eval.exe -help                                               # all options (-dirs, -evidence, -idm, -learn-epochs, ...)
```

## Why Lu_Brain?

#### Dynamicity

Lu_Brain learns "on the fly", without retraining an artificial neural network (ANN). It can
"forget" patterns and learn new ones at any time, so it could fit AI that keeps learning while it
runs. For example, a game AI could pick up new tricks from players during a game.

#### Transparency and control

In a "classic" ANN, knowledge lives somewhere in the weights, and it is hard to say where. Lu_Brain
shows you where each piece of information is: which stored patterns fired, which training examples
share them, and which of them decided a result. You can make it forget specific examples or
patterns, and correct individual link weights.

#### Learning cost

Learning a new example is one pass through the net, with no gradient descent and no retraining of
what was already learned. Its cost grows with the number of stored patterns it is compared
against; how it scales to much larger memories is not benchmarked yet.

## Usage

The tuned recipe (see `samples/semeion` for the complete program):

```odin
import lu "lu_brain/src"

brain: lu.Brain
lu.brain_init(&brain, lu.CONFIGS[.Semeion_Tuned]) or_return
defer lu.brain_terminate(&brain)

// 1. Add receivers (inputs), then build the net
rec := lu.add_rec(&brain, 16, 16, 1, lu.REC_CONFIGS[.Semeion_Tuned]) or_return
lu.build(&brain) or_return

// 2. Save every training example: push two blocks (values are learned from the change between
//    them), then link the example's own label to all of its 2x2 patch cells
save_wave: lu.Save_Wave
lu.save_wave_init(&save_wave, &brain) or_return
defer lu.save_wave_terminate(&save_wave)

for &example, i in examples {
    lu.push(&save_wave, rec, blank[:], 16, 16, 1) or_return
    lu.push(&save_wave, rec, example.pixels[:], 16, 16, 1) or_return
    lu.save(&save_wave) or_return
    lu.link_level_to_label(&save_wave, rec, 1, i) or_return
}

// 3. Match (repeat at ±1 px offsets with set_dest_start_pos for shift tolerance)
match_wave: lu.Match_Wave
lu.match_wave_init(&match_wave, &brain) or_return
defer lu.match_wave_terminate(&match_wave)

lu.push(&match_wave, rec, blank[:], 16, 16, 1) or_return
lu.push(&match_wave, rec, pixels[:], 16, 16, 1) or_return
lu.match(&match_wave) or_return

// best matching examples first; vote over their classes
for result in lu.match_results(&match_wave) do fmt.println(examples[result.id].class, result.sig)
```

`Delete_Wave` (`delete_label`, `delete_neuron`) and `Restore_Wave` (`restore_from_label`,
`restore_values`) follow the same pattern. Inspection (`fired_cells`, `cell_labels`, `label_cells`)
and learning (`reinforce`, `link_weight`) procedures are listed in `src/lu_brain.odin`.

Every procedure takes an allocator (brain) or uses the brain's allocator (waves). Brains and waves
are user-owned structs that keep internal pointers, so they must not be moved after init.

## Build and test

```sh
cd tests && odin test .                                  # test suite
cd tests && odin test . -define:LU_VALIDATIONS=false     # without validation asserts
cd src/lu_core && odin test .                            # core containers
cd samples/semeion && odin run . -o:speed -out:out/semeion.exe
cd samples/explain && odin run . -o:speed -out:out/explain.exe
```

`samples/semeion` trains on about 1,500 handwritten digits and recognizes 100 held-out ones, using
the tuned mode. Add `-define:SMN_BASELINE=true` to run the original C approach instead.

## Legal

___The library is free to use by everyone with good intentions (zlib license).___
