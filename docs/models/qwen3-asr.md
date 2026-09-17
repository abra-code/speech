# Qwen3-ASR

> Measured on an Apple M5 with macOS 26.6.2 in September 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

Alibaba's Qwen3-ASR, a speech encoder paired with a language-model decoder, in 0.6B and 1.7B sizes. The 1.7B model gives the most accurate English and German measured, but its Polish is weak.

## Measurements

Full FLEURS test sets, 2026-09-05 (MLX builds 2026-09-07). Word error rate (WER) in percent, lower is better; speed in multiples of real time.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.qwen3-asr-1.7b@q8_0` | 3.74 | 12.21 | 4.06 | 10-14x | 3.67 GB |
| `ggml.qwen3-asr-1.7b@q4_k_m` | 4.29 | 16.95 | 5.03 | 12-20x | 2.36 GB |
| `ggml.qwen3-asr-0.6b@q8_0` | 4.83 | 24.80 | 6.62 | 22-34x | 1.58 GB |
| `mlx.qwen3-asr-1.7b@8bit` | 4.11 | 17.43 | 5.07 | 9-14x | 3.89-4.08 GB |
| `mlx.qwen3-asr-1.7b@4bit` | 4.89 | 21.77 | 6.10 | 13-19x | 3.03-3.23 GB |
| `ggml.qwen3-asr-0.6b@q4_k_m` | not measured | | | | |

The MLX builds use the same weights and are worse in every language: by 0.4 points in English and about five in Polish. MLX spends one token budget across a whole request, so a long recording sent in one piece loses its ending without an error; `speech` sends it to the MLX builds in five-minute pieces.

## Not for Polish

Polish is on its list of 30 languages, but it scores 12 to 25 percent WER in Polish against 3.74 in English. Even the best build, at 12.21, is not 15 percent better than Apple's 13.16.

German is the opposite: 4.06 is the best German measured, 37.6 percent fewer errors than Apple.

## Cost

The 8-bit 1.7B build uses 3.67 GB of memory, 23 percent of a 16 GB Mac, and runs at about 12 times real time, so an hour of audio takes about five minutes. The 4-bit build saves 1.3 GB and costs half a point in English and nearly five in Polish: a fair trade when memory is short and Polish is not needed.

## Limits

- **No timestamps**, so no subtitles.
- **No custom vocabulary.**
- **Long recordings are transcribed in 10-second pieces**, cut at quiet points. The model declares 87 minutes per run, but it stops writing after about a minute of speech, and longer pieces lose whole sentences: on 5-minute recordings, 10-second pieces scored 11.3% WER in English against 17.2% for 45-second ones (docs/engines.md).

## What FLEURS does not cover

Qwen3-ASR is published as strong on difficult audio: accents, noise and overlapping speech. FLEURS is clear read speech and cannot test that, so on difficult recordings Qwen3-ASR may compare better than these numbers show.
