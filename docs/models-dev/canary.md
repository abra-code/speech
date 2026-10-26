# Canary 1B v2

> Measured on an Apple M5 with macOS 27.0.1 in October 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

NVIDIA's Canary-1B-v2, covering 25 European languages. The best all-round model in these measurements: at least 15 percent fewer errors than Apple's engine in all three languages tested, about 50 times faster than real time, in about 1.3 GB of memory.

## Measurements

Full FLEURS test sets, 2026-10-23 to 2026-10-26, speech 0.2.1 (transcribe.cpp 0.4.1, FluidAudio 0.17.7). Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.canary-1b-v2@q8_0` | 4.92 | 6.82 | 4.41 | 48-57x | 1.33-1.39 GB |
| `ggml.canary-1b-v2@q4_k_m` | 5.04 | 7.18 | 4.59 | 54-64x | 0.92-0.99 GB |
| `fluid.canary-1b-v2@int4` | 6.39 | 11.80 | 6.93 | 6-8x | 0.30-0.34 GB |

## The 4-bit Core ML build

FluidInference publishes this model for Core ML only in 4-bit form. That build is 1.5 to 5 WER points worse than the 8-bit GGUF build in every language, and about seven times slower. Its only advantage is memory: 0.30-0.34 GB against 1.33-1.39 GB, or 0.92-0.99 GB for the 4-bit GGUF build, which is 0.1 to 0.4 points behind the 8-bit one. It is hidden from the model list, but still runs when its full id is given.

## Limits

- **No timestamps**, word or segment, so no SRT or WebVTT subtitles.
- **Long recordings are transcribed in 15-second pieces**, cut at pauses and joined. The model declares 400 seconds per run, but it stops writing after about a minute of speech, and longer pieces lose whole sentences: 15-second pieces scored 6.4% WER in English and 8.1% in Polish, against 13.8% and 10.8% at 30 seconds; a one-minute LibriSpeech passage given whole came back at 25.5% (docs/engines.md).
- **No language detection, and no error without a language.** Given non-English audio and no `--language`, Canary returns fluent English about the same subject, because without a source language it translates. `speech` refuses to run it without a language.
- **`fluid.canary-1b-v2@int4` needs macOS 15**, which is why `speech` requires macOS 15 rather than 14.

## Language tags

Canary uses tags without a region: it accepts `pl` and rejects `pl-PL`. `speech` converts a tag to the model's own form, so either works.
