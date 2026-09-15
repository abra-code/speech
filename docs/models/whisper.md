# Whisper large-v3-turbo

> Measured on an Apple M5 with macOS 26.6.2 in September 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

OpenAI's Whisper large-v3-turbo, 809 million parameters, 99 languages - far more languages than any other model here. It gives the best Polish measured.

## Measurements

Full FLEURS test sets, 2026-09-05 (MLX build 2026-09-07). Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.whisper-large-v3-turbo@q8_0` | 4.97 | 5.81 | 5.07 | 12.7-17.1x | 1.13 GB |
| `mlx.whisper-large-v3-turbo` | 4.92 | 5.82 | **4.54** | 8.1-11.7x | 3.61 GB |
| `ggml.whisper-large-v3-turbo@q4_k_m` | not measured | | | | |

The MLX build matches the ggml build in English and Polish and is half a point better in German. It is about a third slower and uses three times the memory, and for German `ggml.qwen3-asr-1.7b@q8_0` does better still, at 4.06.

Polish at 5.81 means 56 percent fewer errors than Apple's 13.16.

## Speed

Published figures on an M4 Max are 40 to 55 times real time; on the M5 it measured 13 to 17, three to four times slower. The speed held steady across full test sets, so overheating is not the cause. An hour of audio takes about four minutes, against about 30 seconds for Parakeet.

## Limits

- **Segment timestamps only, no word timings.** Enough for subtitles, not for word-level alignment.
- **No custom vocabulary.**

## When to choose it

For Polish, and for languages no other model here supports. For English and German, other models are more accurate and much faster.
