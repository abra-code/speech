# Qwen3-ASR

> Every number on this page comes from one battery: an Apple M5 on macOS 26.6.2,
> September 2026, over the full FLEURS test splits. It is a reference point for
> what to expect, not a measurement of your Mac. Speech.app can re-run it locally,
> and against your own recordings, which is the number that actually decides.

Alibaba's Qwen3-ASR, a speech encoder in front of a language-model decoder, in 0.6B and 1.7B sizes. The 1.7B row produced the most accurate English and German measured anywhere in this project. Its Polish is the worst of any row that passes elsewhere.

## What it measured

Full FLEURS test splits, 2026-09-05.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.qwen3-asr-1.7b@q8_0` | 3.74 | 12.21 | 4.06 | 10-14x | 3.67 GB |
| `ggml.qwen3-asr-1.7b@q4_k_m` | 4.29 | 16.95 | 5.03 | 12-20x | 2.36 GB |
| `ggml.qwen3-asr-0.6b@q8_0` | 4.83 | 24.80 | 6.62 | 22-34x | 1.58 GB |
| `mlx.qwen3-asr-1.7b@8bit` | 4.11 | 17.43 | 5.07 | 9-14x | 3.89-4.08 GB |
| `mlx.qwen3-asr-1.7b@4bit` | 4.89 | 21.77 | 6.10 | 13-19x | 3.03-3.23 GB |
| `ggml.qwen3-asr-0.6b@q4_k_m` | not measured | | | | |

The MLX rows, measured 2026-09-07, are the same weights on a different runtime and are worse in every language - by 0.4 points in English and by five in Polish. They are not offered. They also carry the one long-recording caveat worth knowing about this family: its token budget is spent across a whole request, so a recording handed over in one piece loses its tail silently. `speech` cuts at five minutes for that reason.

## It is not a Polish model, whatever its language list says

It carries `pl` among 30 languages and produces 12 to 25 percent WER on it while producing 3.74 percent on English. A catalog that offered it for Polish because the metadata listed the language would be offering the worst row in the set, 12.21 does not reach the 11.19 bar that 15 percent over Apple's 13.16 implies, and 24.80 is not close to anything.

German is the opposite story. 4.06 is the best German measured here, a 37.6 percent relative improvement over Apple.

## The cost

3.67 GB of memory for the 8-bit 1.7B row, which is 23 percent of a 16 GB Mac for one model, and about 12 times real time - an hour of audio in five minutes. The 4-bit build saves 1.3 GB and costs half a point of English and nearly five points of Polish, which is a reasonable trade if memory is the constraint and Polish was never the plan.

## What it cannot do

- **No timestamps at all**, so no subtitles.
- **No custom vocabulary.**
- A run is capped at 5,218,560 ms, about 87 minutes, after which audio is chunked.

## What FLEURS cannot tell you

Qwen3-ASR's published strength is hard audio - accents, noise, overlapping speech - and FLEURS is clean read prose, which is exactly what this corpus cannot test. The numbers above rank it on the easy case. On the hard case it may well be further ahead than they suggest, and nothing here proves it.
