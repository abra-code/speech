# Whisper large-v3-turbo

> Measured on an Apple M5 with macOS 27.0.1 in October 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

OpenAI's Whisper large-v3-turbo, 809 million parameters, 99 languages - far more languages than any other model here, and the most even across the ones measured.

## Measurements

Full FLEURS test sets, 2026-10-21 to 2026-10-24, speech 0.2 (transcribe.cpp 0.4.1, mlx-audio-swift 0.1.6). Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.whisper-large-v3-turbo@q8_0` | 4.97 | 5.81 | 5.07 | 12.2-16.4x | 1.05-1.06 GB |
| `mlx.whisper-large-v3-turbo` | 4.95 | 5.84 | **4.61** | 9.0-13.0x | 3.59-3.60 GB |
| `ggml.whisper-large-v3-turbo@q4_k_m` | 5.21 | 6.04 | 5.29 | 12.2-16.1x | 0.70-0.71 GB |

Of the six languages measured it takes first place in Polish, at 5.81, and is a point or so behind the best in English and German. The MLX build matches the ggml build in English and Polish and is half a point better in German. It is about a quarter slower and uses three times the memory, and for German `ggml.qwen3-asr-1.7b@q8_0` does better still, at 4.05. The 4-bit ggml build saves a third of the memory for a quarter of a point.

Polish at 5.81 means 56 percent fewer errors than Apple's 13.16.

## Speed

Published figures on an M4 Max are 40 to 55 times real time; on the M5 it measured 12 to 16, three to four times slower. The speed held steady across full test sets, so overheating is not the cause. An hour of audio takes about four minutes, against about 30 seconds for Parakeet.

## Limits

- **Segment timestamps only, no word timings.** Enough for subtitles, not for word-level alignment.
- **No custom vocabulary.**

## When to choose it

For Polish, and for languages no other model here supports. For English and German, other models are more accurate and much faster.
