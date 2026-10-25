# Qwen3-ASR

> Measured on an Apple M5 with macOS 27.0.1 in October 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

Alibaba's Qwen3-ASR, a speech encoder paired with a language-model decoder, in 0.6B and 1.7B sizes. The 1.7B model gives the most accurate English and German measured, but its Polish is weak.

## Measurements

Full FLEURS test sets, 2026-10-21 to 2026-10-25, speech 0.2 (transcribe.cpp 0.4.1, mlx-audio-swift 0.1.6). Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.qwen3-asr-1.7b@q8_0` | 3.74 | 12.19 | 4.05 | 10-16x | 2.59 GB |
| `mlx.qwen3-asr-1.7b@8bit` | 3.84 | 12.43 | 4.23 | 9-14x | 3.93-4.15 GB |
| `mlx.qwen3-asr-1.7b@4bit` | 4.02 | 15.50 | 5.07 | 13-20x | 2.98-3.28 GB |
| `ggml.qwen3-asr-1.7b@q4_k_m` | 4.29 | 16.95 | 5.03 | 14-21x | 1.72 GB |
| `ggml.qwen3-asr-0.6b@q8_0` | 4.87 | 24.83 | 6.65 | 24-36x | 1.25 GB |
| `ggml.qwen3-asr-0.6b@q4_k_m` | 5.48 | 31.17 | 8.12 | 29-43x | 0.99 GB |

The MLX builds use the same weights and are now close to the GGUF builds or ahead of them: the 8-bit one trails `ggml.qwen3-asr-1.7b@q8_0` by 0.1 to 0.25 points in English, Polish and German and edges ahead of it in Spanish and French, and the 4-bit one beats `@q4_k_m` in English and Polish. They need more memory: 3.9 to 4.1 GB for the 8-bit build against 2.59 GB. MLX spends one token budget across a whole request, so a long recording sent in one piece loses its ending without an error; `speech` sends it to the MLX builds in five-minute pieces.

## A language on its list is not a language it is good at

Its 30 languages are not equally served, and the six measured here spread further apart than for any other model. German is its best: 4.05, the lowest German measured and 37.8 percent fewer errors than Apple. Polish is its worst: 12 to 31 percent, where even the best build's 12.19 fails to beat Apple's 13.16 by the 15 percent this project asks for. Check the language you care about in the table above rather than trusting the list.

## Cost

The 8-bit 1.7B build uses 2.59 GB of memory, 16 percent of a 16 GB Mac, and runs at about 15 times real time in English and German (10 in Polish), so an hour of audio takes about four minutes. The 4-bit build saves 0.9 GB and costs half a point in English and nearly five in Polish: a fair trade where memory is short and the recording is in one of its stronger languages.

## Limits

- **No timestamps**, so no subtitles.
- **No custom vocabulary.**
- **Long recordings are transcribed in 15-second pieces**, cut at pauses. The model declares 87 minutes per run, but it stops writing after about a minute of speech, and longer pieces lose whole sentences: on 5-minute recordings, 15-second pieces scored 9.2% WER in English and 13.9% in Polish, against 15.5% and 18.2% for 45-second ones (docs/engines.md).

## What FLEURS does not cover

Qwen3-ASR is published as strong on difficult audio: accents, noise and overlapping speech. FLEURS is clear read speech and cannot test that, so on difficult recordings Qwen3-ASR may compare better than these numbers show.
