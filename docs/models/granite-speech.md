# Granite Speech

> Every number on this page comes from one battery: an Apple M5 on macOS 26.6.2,
> September 2026, over the full LibriSpeech test-clean and test-other sets and
> the full FLEURS English test split. It is a reference point for what to
> expect, not a measurement of your Mac. Speech.app can re-run it locally, and
> against your own recordings, which is the number that actually decides.

IBM's Granite Speech, four builds from two generations: Granite Speech 4.1 2B, its Plus build (the one with timestamps), its NAR build (a non-autoregressive decoder, which writes the whole transcript in a few passes rather than a word at a time), and the older Granite 4.0 1B Speech. All four take the first four places on both halves of LibriSpeech, ahead of every other row measured in this project. On FLEURS English the same four place 20th to 26th of 33.

## What it measured

Full test sets, 2026-09-11 and 2026-09-12. WER in percent, with the row's place among the rows scored on that corpus in brackets.

| row | LibriSpeech clean | LibriSpeech other | FLEURS English | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.granite-speech-4.1-2b-nar@q8_0` | 1.41 (1st of 32) | 2.86 (2nd) | 5.63 (20th of 33) | 16-17x | 5.17-5.35 GB |
| `ggml.granite-speech-4.1-2b@q8_0` | 1.49 (2nd) | 2.84 (1st) | 5.99 (23rd) | 9-11x | 3.76-3.80 GB |
| `ggml.granite-4.0-1b-speech@q8_0` | 1.58 (3rd) | 3.12 (3rd) | 6.87 (26th) | 10-12x | 3.76-3.79 GB |
| `ggml.granite-speech-4.1-2b-plus@q8_0` | 1.65 (4th) | 3.32 (4th) | 5.66 (21st) | 9-10x | 3.58-3.65 GB |
| the four `@q4_k_m` builds | not measured | | | | |

For comparison, on the same three corpora:

| row | LibriSpeech clean | LibriSpeech other | FLEURS English | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `ggml.parakeet-unified-en-0.6b@q8_0` | 1.75 | 3.36 | 4.92 | 72-124x | 0.91-0.94 GB |
| `fluid.parakeet-unified@int8` | 1.83 | 3.38 | 4.90 | 131-166x | 0.70-0.71 GB |
| `ggml.qwen3-asr-1.7b@q8_0` | 1.88 | 3.67 | 3.74 | 11-17x | 3.66-3.67 GB |
| `apple.transcriber` | 2.34 | 4.90 | 8.03 | 52-60x | 22 MB |

## First on LibriSpeech, twentieth on FLEURS

Both corpora are English read aloud, and the two rankings disagree about this family more than about any other. LibriSpeech is audiobook recordings from the public-domain LibriVox project, and it is one of the most widely used sets for training English speech models; FLEURS is sentences from Wikipedia read by volunteers for a benchmark. A model that leads by a wide margin on one and sits mid-table on the other is most likely telling you how much its training data resembles each set, not how it will handle yours. Nothing here says what Granite was trained on, and nothing needs to: the disagreement is the finding.

What the two corpora do agree on is order within the family. The 4.1 builds beat the 4.0 build on all three corpora, so there is no measured reason to choose 4.0.

## Which build

- **4.1 2B NAR** is the fastest, at 16 to 17 times real time, and the most accurate on LibriSpeech test-clean. It also needs the most memory of any row in the catalog: 5.17 to 5.35 GB, 1.4 to 1.6 GB more than the ordinary 4.1 build, for a download that is slightly smaller (2.50 GB against 2.56 GB).
- **4.1 2B** is first on LibriSpeech test-other, the harder half, at 3.8 GB and 9 to 11 times real time.
- **4.1 2B Plus** is the only Granite build that reports word and segment timestamps, so it is the only one that can make subtitles. It costs a little accuracy on LibriSpeech and is the slowest, around 9 times real time.
- **4.0 1B** is the earlier generation. Despite the name, its Q8_0 file is exactly the size of the 4.1 2B file, and it is behind the 4.1 builds everywhere it was measured.

## The cost

3.6 to 5.4 GB of memory and 9 to 17 times real time: an hour of audio in 4 to 7 minutes. On a 16 GB Mac the NAR build takes a third of the memory.

That price buys 0.3 to 0.5 points of WER over Parakeet Unified English on LibriSpeech, and nothing on FLEURS English, where Parakeet Unified is ahead by 0.7 points or more. Parakeet Unified runs 72 to 166 times real time in under 1 GB. Granite is the choice when the recordings resemble LibriSpeech and accuracy is worth several gigabytes and a slower run; the user's own recordings are what show whether they do.

## What it cannot do

- **No language identification.** The language has to be chosen: `speech` refuses to run a Granite row without `--language`, and Speech.app offers no Automatic for it.
- **No timestamps**, except in the Plus build.
- **No live mode.** None of the four streams.
- **At most 377 seconds of audio per run** (384 for the NAR build). Longer recordings are cut at silences by the engine and transcribed in pieces.
- **Only English has been measured on a full test set.** The builds claim French, German, Spanish and Portuguese, and the 4.1 2B and 4.0 1B builds also Japanese. Twenty-utterance FLEURS spot checks put German at 9 to 12 percent WER across the four, where `apple.transcriber` scored 6.51 percent on the full German split. Twenty utterances rank nothing, but they are no reason to pick Granite for German.

## What these corpora cannot tell you

Both are clean, single-speaker read speech. Neither has a meeting, a phone call, an accent far from the training data, a noisy room or a speaker who hesitates, and those are where transcription accuracy is usually lost. A first place on audiobooks is a good sign for dictation of prepared text and says little about a conversation.
