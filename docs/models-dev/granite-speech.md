# Granite Speech

> Measured on an Apple M5 with macOS 27.0.1 in October 2026, over the full
> LibriSpeech test-clean and test-other sets and the full FLEURS English test
> set. Use these numbers as a guide: results on your Mac and with your own
> recordings can differ.

IBM's Granite Speech in four builds from two generations: Granite Speech 4.1 2B; its Plus build, the only one with timestamps; its NAR (non-autoregressive) build, which writes the whole transcript in a few passes instead of word by word; and the older Granite 4.0 1B Speech. The four take the top four places on both LibriSpeech sets, ahead of every other model measured, but place only 20th to 26th of 35 on FLEURS English.

## Measurements

Full test sets, 2026-10-23 to 2026-10-25, speech 0.2.1 (transcribe.cpp 0.4.1). Word error rate (WER) in percent, lower is better, with the rank among all models measured on that set in brackets; speed in multiples of real time.

| row | LibriSpeech clean | LibriSpeech other | FLEURS English | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.granite-speech-4.1-2b-nar@q8_0` | 1.42 (1st of 34) | 2.86 (2nd) | 5.65 (21st of 35) | 32-35x | 2.87-2.91 GB |
| `ggml.granite-speech-4.1-2b@q8_0` | 1.47 (2nd) | 2.84 (1st) | 5.98 (23rd) | 12-14x | 2.83-2.87 GB |
| `ggml.granite-4.0-1b-speech@q8_0` | 1.58 (3rd) | 3.13 (3rd) | 6.87 (26th) | 13-14x | 2.83-2.87 GB |
| `ggml.granite-speech-4.1-2b-plus@q8_0` | 1.64 (4th) | 3.35 (4th) | 5.64 (20th) | 12-13x | 2.65-2.69 GB |
| the four `@q4_k_m` builds | not measured | | | | |

For comparison, on the same three sets:

| row | LibriSpeech clean | LibriSpeech other | FLEURS English | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.parakeet-unified-en-0.6b@q8_0` | 1.74 | 3.35 | 4.92 | 90-104x | 0.94-0.97 GB |
| `fluid.parakeet-unified@int8` | 1.84 | 3.37 | 4.90 | 128-163x | 0.70-0.71 GB |
| `ggml.qwen3-asr-1.7b@q8_0` | 1.87 | 3.70 | 3.74 | 14-16x | 2.59 GB |
| `apple.transcriber` on macOS 27.0.1 | 2.33 | 4.91 | 8.03 | 56-65x | 20-22 MB |

## Why the rankings disagree

Both sets are English read aloud. LibriSpeech is audiobooks from the public-domain LibriVox project and is widely used to train English speech models; FLEURS is Wikipedia sentences read by volunteers. A model that leads on one and sits mid-table on the other most likely reflects how closely its training data resembles each set, not how it will handle your recordings.

Within the family the sets mostly agree: 4.1 2B and NAR beat 4.0 on all three, and Plus beats it on FLEURS English but not on LibriSpeech, so there is no reason to choose 4.0.

## Which build

- **4.1 2B NAR** is the fastest, 32 to 35 times real time - two and a half times the others - and the most accurate on LibriSpeech test-clean, in the same 2.9 GB as 4.1 2B. Measured with transcribe.cpp 0.2.3 in September it needed 5.2 to 5.3 GB and ran at 16 to 17 times real time.
- **4.1 2B** is first on LibriSpeech test-other, the harder set, at 2.9 GB and 12 to 14 times real time.
- **4.1 2B Plus** is the only build with word and segment timestamps, so the only one that can make subtitles. It is slightly less accurate on LibriSpeech, at 12 to 13 times real time and 2.7 GB.
- **4.0 1B** is the older generation. Despite its name, its Q8_0 file is the same size as that of 4.1 2B, and it is behind 4.1 2B and NAR on every set.

## Cost

2.7 to 2.9 GB of memory, and 12 to 35 times real time, so an hour of audio takes 2 to 5 minutes. On a 16 GB Mac any build uses under a fifth of the memory.

Compared with Parakeet Unified English, that buys up to half a WER point on LibriSpeech and nothing on FLEURS English, where Parakeet Unified is 0.7 points or more ahead - and Parakeet Unified runs at 90 to 163 times real time in under 1 GB. Choose Granite when your recordings resemble audiobooks and the extra accuracy is worth the memory and time.

## Limits

- **No language detection.** `speech` requires `--language`, and Speech.app offers no Automatic choice.
- **No timestamps**, except in the Plus build.
- **No live mode.**
- **Long recordings are transcribed in 20-second pieces (4.0 1B) and 10-second pieces (NAR)**, cut at pauses. The builds declare 377 seconds per run (384 for NAR), but 4.0 1B stops writing after about a minute of speech, NAR fills its context before 5 minutes, and longer pieces lose whole sentences: in English, 4.0 1B scored 6.8% WER at 20 seconds against 8.4% at 30, and NAR 8.6% at 10 seconds against 11.0% at 15 and 24.5% at 45. The Plus build and 4.1 2B were not measured and get the same length (docs/engines.md).
- **Only English was measured on full test sets.** The builds also list French, German, Spanish and Portuguese, and 4.1 2B and 4.0 1B list Japanese. Samples of 20 FLEURS sentences put German at 9 to 12 percent WER, against 6.51 for `apple.transcriber` on the full German set. That sample is too small to rank models, but gives no reason to choose Granite for German.

## What these tests do not cover

Both sets are clear read speech from one speaker at a time. Neither includes meetings, phone calls, strong accents, noisy rooms or hesitant speakers, which is where most errors happen. A top score on audiobooks is a good sign for reading prepared text aloud, and says little about conversation.
