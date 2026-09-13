# Whisper large-v3-turbo

> Every number on this page comes from one battery: an Apple M5 on macOS 26.6.2,
> September 2026, over the full FLEURS test splits. It is a reference point for
> what to expect, not a measurement of your Mac. Speech.app can re-run it locally,
> and against your own recordings, which is the number that actually decides.

OpenAI's Whisper large-v3-turbo, 809M parameters, 99 languages - by far the widest language coverage of any row measured here. It produced the best Polish measured anywhere in this project.

## What it measured

Full FLEURS test splits, 2026-09-05.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.whisper-large-v3-turbo@q8_0` | 4.97 | 5.81 | 5.07 | 12.7-17.1x | 1.13 GB |
| `mlx.whisper-large-v3-turbo` | 4.92 | 5.82 | **4.54** | 8.1-11.7x | 3.61 GB |
| `ggml.whisper-large-v3-turbo@q4_k_m` | not measured | | | | |

The MLX build, measured 2026-09-07, is the only place in this project where an MLX row wins anything: 4.54 in German is half a point better than the ggml build and the best German Whisper measured here. It is not offered, because it gives up a third of the speed and three times the memory for that half point, and `ggml.qwen3-asr-1.7b@q8_0` reaches 4.06 in German anyway.

Polish at 5.81 against Apple's 13.16 is a 56 percent relative improvement, and it is the strongest single result behind this product's central claim: that Polish users are badly served by what their Mac already does.

## Speed is the disappointment

Published figures for this model on an M4 Max are 40 to 55 times real time. It measured 13 to 17 here, three to four times slower, and that is the single largest gap between expectation and measurement in this project. The figures are flat across full splits with no throttling observed, so it is not a thermal effect.

It is still the slowest row that clears the bar in all three languages. On a one-hour recording that is roughly four minutes of work rather than the thirty seconds Parakeet would take.

## What it cannot do

- **Segment timestamps only, no word timings.** Enough for subtitles, not enough for word-level alignment.
- **No custom vocabulary.**

## When to pick it

For Polish, and for any language nothing else in this catalog covers. For English and German there are more accurate rows and much faster ones.
