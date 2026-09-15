# Canary 1B v2

> Measured on an Apple M5 with macOS 26.6.2 in September 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

NVIDIA's Canary-1B-v2, covering 25 European languages. The best all-round model in these measurements: at least 15 percent fewer errors than Apple's engine in all three languages tested, about 50 times faster than real time, in about 1.3 GB of memory.

## Measurements

Full FLEURS test sets, 2026-09-04 and 2026-09-05. Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.canary-1b-v2@q8_0` | 4.92 | 6.82 | 4.41 | 47-56x | 1.32-1.38 GB |
| `ggml.canary-1b-v2@q4_k_m` | not measured | | | | |
| `fluid.canary-1b-v2@int4` | 6.36 | 11.77 | 6.96 | 6-8x | 0.31-0.34 GB |

## The 4-bit Core ML build

FluidInference publishes this model for Core ML only in 4-bit form. That build is 1.4 to 5 WER points worse than the 8-bit GGUF build in every language, and about seven times slower. Its only advantage is memory: 0.31-0.34 GB against 1.32-1.38 GB. It is hidden from the model list, but still runs when its full id is given.

## Limits

- **No timestamps**, word or segment, so no SRT or WebVTT subtitles.
- **At most 400 seconds (6 minutes 40 seconds) per run.** Longer recordings are cut into pieces at quiet points and the transcripts joined. Canary is the one model that depends on this.
- **No language detection, and no error without a language.** Given Polish audio and no `--language`, Canary returns fluent English about the same subject, because without a source language it translates. `speech` refuses to run it without a language.
- **`fluid.canary-1b-v2@int4` needs macOS 15**, which is why `speech` requires macOS 15 rather than 14.

## Language tags

Canary uses tags without a region: it accepts `pl` and rejects `pl-PL`. `speech` converts a tag to the model's own form, so either works.
