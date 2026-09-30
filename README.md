# 🧠 Lu_Brain

Ludyna Brain (Lu_Brain) is a human-like memory database, written in [Odin](https://odin-lang.org).

This is an Odin port of the original experimental C project created by me years ago. The code around the algorithm was rewritten in modern Odin:

- explicit allocators instead of a global `Lu_Mem`,
- typed slices, dynamic arrays and a small index pool instead of `void*` containers,
- tagged unions instead of virtual destructors,
- `Error` unions with `or_return` instead of exceptions.

### 🚧 ___This project is an EXPERIMENTAL, for fun, work in progress.___ 🚧

Current accuracy is weak: **70–79%** (difference is mostly noise from the random split.)

But:
- It learns in one pass‼️Each digit is learned instantly and incrementally (about 0.55 s for 1,493 digits), and nothing has been tuned yet.
- No hardware acceleration yet.

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

`samples/semeion` trains on about 1500 handwritten digits and recognizes 100 held-out ones.

## Legal

___The library is free to use by everyone with good intentions (zLib license).___
