# Canary 1B v2

> Every number on this page comes from one battery: an Apple M5 on macOS 26.6.2,
> September 2026, over the full FLEURS test splits. It is a reference point for
> what to expect, not a measurement of your Mac. Speech.app can re-run it locally,
> and against your own recordings, which is the number that actually decides.

NVIDIA's Canary-1B-v2, an encoder-decoder model covering 25 European languages. In this battery it was the best all-round row: it beat Apple's built-in engine by more than 15 percent in all three languages tested, at around 50 times real time, in about 1.3 GB.

## What it measured

Full FLEURS test splits, 2026-09-04 and 2026-09-05.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.canary-1b-v2@q8_0` | 4.92 | 6.82 | 4.41 | 47-56x | 1.32-1.38 GB |
| `ggml.canary-1b-v2@q4_k_m` | not measured | | | | |
| `fluid.canary-1b-v2@int4` | 6.36 | 11.77 | 6.96 | 6-8x | 0.31-0.34 GB |

## The finding worth reading

Stage 1 measured Canary on CoreML at int4, found it beaten everywhere and twenty times slower than the alternatives, and hid it. Stage 2 measured the same model on ggml at Q8_0 and found it the best row in the set.

**That was int4's fault, not Canary's.** FluidInference publishes only int4 CoreML weights for this model, so stage 1 was measuring a 4-bit build with no 8-bit option to compare against. The `handy-computer` GGUF repository publishes a full quantization ladder, and at Q8_0 the same model is 1.4 to 5 WER points better in every language and seven times faster.

The cost is memory: 305-341 MB on CoreML against 1.32-1.38 GB here, four times more for the same family. The int4 row is kept for that reason and no other.

## What it cannot do

- **No timestamps at all.** Not word, not segment. This was read out of the GGUF rather than from a model card, and it corrected an assumption the plan had made. A row with no timestamps cannot produce subtitles, so `speech export` to srt or vtt has nothing to work with.
- **A hard 400 second ceiling.** Past 6 minutes 40 seconds the library throws rather than degrading, so a long recording is cut into pieces at local energy minima and the transcripts stitched back with offset timestamps. Canary is the one row where that chunking is load-bearing.
- **No language identification, and a missing hint is not an error.** Given Polish audio with no `--language`, Canary returns fluent, confident English prose about the same subject, because a Canary prompt with no source language is a translation request. The engine refuses to prepare without a hint rather than letting that happen.
- **`fluid.canary-1b-v2@int4` needs macOS 15**, and is the only reason this binary's floor is not macOS 14.

## Language tags

Canary publishes bare subtags. It accepts `pl` and rejects `pl-PL`. The engine looks the request up in the loaded model's own list and hands back the model's own spelling, so either form works from the command line.
