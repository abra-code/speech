# Parakeet v3

> Every number on this page comes from one battery: an Apple M5 on macOS 26.6.2,
> September 2026, over the full FLEURS test splits. It is a reference point for
> what to expect, not a measurement of your Mac. Speech.app can re-run it locally,
> and against your own recordings, which is the number that actually decides.

NVIDIA's Parakeet TDT 0.6B v3, covering 25 European languages. The fast row in this battery: it beat Apple by more than 15 percent in all three languages while transcribing at over 100 times real time, which is what makes it worth considering for long recordings.

## What it measured

Full FLEURS test splits, 2026-09-04 to 2026-09-07.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.parakeet-tdt-0.6b-v3@q8_0` | 5.42 | 7.36 | 5.21 | 106-118x | 0.98-1.00 GB |
| `fluid.parakeet-v3@int8` | 5.89 | 7.77 | 5.57 | 121-151x | 0.56-0.58 GB |
| `mlx.parakeet-tdt-0.6b-v3` | 5.38 | 7.38 | 5.18 | 98-113x | 3.93 GB |
| `ggml.parakeet-tdt-0.6b-v3@q4_k_m` | not measured | | | | |
| `fluid.parakeet-v3@int4` | 9.29 | 16.47 | 10.20 | 120-148x | 0.41-0.45 GB |

## The same model on two runtimes

This family is the controlled comparison the ggml stage was really for: identical weights, two runtimes, same corpora, same scorer.

The ggml build wins on accuracy in all three languages by a few tenths of a point. The CoreML build wins on speed by 1.0 to 1.5 times and on memory by about 400 MB, and it is the only one of the two that accepts a custom vocabulary. Neither dominates, which is why both are worth having installed.

Which one is right depends on the machine and the recording, which is why Speech.app decides it rather than the catalog.

**The third runtime agrees with the first two, and that is its whole value.** `mlx.parakeet-tdt-0.6b-v3` scores 5.38 / 7.38 / 5.18 where the ggml build scores 5.42 / 7.36 / 5.21 - the same number three times, from a different implementation of the same checkpoint. It is not offered, because it costs four times the ggml build's memory for that tie, but it is the strongest evidence available that these figures are the model's rather than one runtime's.

**`fluid.parakeet-v3@int4` is not a smaller Parakeet, it is a worse one.** It saves about 145 MB and costs 3 to 9 WER points, which put it behind Apple in all three languages measured. That is what makes it a smaller download rather than a smaller model.

## What it cannot do

- **No language identification on the CoreML build**; the ggml build has it.
- **Custom vocabulary is CoreML only**, and it works by spotting terms with a separate small CTC model, `fluid.parakeet-ctc-110m`, which `speech` carries as a helper row rather than as something to transcribe with.

## Language coverage disagrees between the two builds

The GGUF reports 25 languages where the CoreML package advertises 28. The loaded model answers for itself; the inventory's copy is advisory.
