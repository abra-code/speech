# Granite Speech

> Measured on an Apple M5 with macOS 26.6.2 in September 2026, over the full
> LibriSpeech test-clean and test-other sets and the full FLEURS English test
> set. Use these numbers as a guide: results on your Mac and with your own
> recordings can differ.

IBM's Granite Speech in four builds from two generations: Granite Speech 4.1 2B; its Plus build, the only one with timestamps; its NAR (non-autoregressive) build, which writes the whole transcript in a few passes instead of word by word; and the older Granite 4.0 1B Speech. The four take the top four places on both LibriSpeech sets, ahead of every other model measured, but place only 20th to 26th of 33 on FLEURS English.

## Measurements

Full test sets, 2026-09-11 and 2026-09-12. Word error rate (WER) in percent, lower is better, with the rank among all models measured on that set in brackets; speed in multiples of real time.

| row | LibriSpeech clean | LibriSpeech other | FLEURS English | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.granite-speech-4.1-2b-nar@q8_0` | 1.41 (1st of 32) | 2.86 (2nd) | 5.63 (20th of 33) | 16-17x | 5.17-5.35 GB |
| `ggml.granite-speech-4.1-2b@q8_0` | 1.49 (2nd) | 2.84 (1st) | 5.99 (23rd) | 9-11x | 3.76-3.80 GB |
| `ggml.granite-4.0-1b-speech@q8_0` | 1.58 (3rd) | 3.12 (3rd) | 6.87 (26th) | 10-12x | 3.76-3.79 GB |
| `ggml.granite-speech-4.1-2b-plus@q8_0` | 1.65 (4th) | 3.32 (4th) | 5.66 (21st) | 9-10x | 3.58-3.65 GB |
| the four `@q4_k_m` builds | not measured | | | | |

For comparison, on the same three sets:

| row | LibriSpeech clean | LibriSpeech other | FLEURS English | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.parakeet-unified-en-0.6b@q8_0` | 1.75 | 3.36 | 4.92 | 72-124x | 0.91-0.94 GB |
| `fluid.parakeet-unified@int8` | 1.83 | 3.38 | 4.90 | 131-166x | 0.70-0.71 GB |
| `ggml.qwen3-asr-1.7b@q8_0` | 1.88 | 3.67 | 3.74 | 11-17x | 3.66-3.67 GB |
| `apple.transcriber` | 2.34 | 4.90 | 8.03 | 52-60x | 22 MB |

## Why the rankings disagree

Both sets are English read aloud. LibriSpeech is audiobooks from the public-domain LibriVox project and is widely used to train English speech models; FLEURS is Wikipedia sentences read by volunteers. A model that leads on one and sits mid-table on the other most likely reflects how closely its training data resembles each set, not how it will handle your recordings.

Within the family the sets agree: the 4.1 builds beat 4.0 on all three, so there is no reason to choose 4.0.

## Which build

- **4.1 2B NAR** is the fastest, 16 to 17 times real time, and the most accurate on LibriSpeech test-clean. It uses the most memory of any model in the catalog, 5.17 to 5.35 GB, which is 1.4 to 1.6 GB more than 4.1 2B, even though its download is slightly smaller (2.50 GB against 2.56 GB).
- **4.1 2B** is first on LibriSpeech test-other, the harder set, at 3.8 GB and 9 to 11 times real time.
- **4.1 2B Plus** is the only build with word and segment timestamps, so the only one that can make subtitles. It is slightly less accurate on LibriSpeech and the slowest, about 9 times real time.
- **4.0 1B** is the older generation. Despite its name, its Q8_0 file is the same size as that of 4.1 2B, and it is behind the 4.1 builds on every set.

## Cost

3.6 to 5.4 GB of memory, and 9 to 17 times real time, so an hour of audio takes 4 to 7 minutes. On a 16 GB Mac the NAR build uses a third of the memory.

Compared with Parakeet Unified English, that buys up to half a WER point on LibriSpeech and nothing on FLEURS English, where Parakeet Unified is 0.7 points or more ahead - and Parakeet Unified runs at 72 to 166 times real time in under 1 GB. Choose Granite when your recordings resemble audiobooks and the extra accuracy is worth the memory and time.

## Limits

- **No language detection.** `speech` requires `--language`, and Speech.app offers no Automatic choice.
- **No timestamps**, except in the Plus build.
- **No live mode.**
- **At most 377 seconds of audio per run** (384 for NAR). Longer recordings are cut at silences and transcribed in pieces.
- **Only English was measured on full test sets.** The builds also list French, German, Spanish and Portuguese, and 4.1 2B and 4.0 1B list Japanese. Samples of 20 FLEURS sentences put German at 9 to 12 percent WER, against 6.51 for `apple.transcriber` on the full German set. That sample is too small to rank models, but gives no reason to choose Granite for German.

## What these tests do not cover

Both sets are clear read speech from one speaker at a time. Neither includes meetings, phone calls, strong accents, noisy rooms or hesitant speakers, which is where most errors happen. A top score on audiobooks is a good sign for reading prepared text aloud, and says little about conversation.
