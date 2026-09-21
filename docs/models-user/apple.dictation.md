# Apple dictation (built into macOS)

The engine behind keyboard dictation, meant for short bursts of speech. Nothing to download, about 20 MB of memory, and it covers 33 languages - far more than Apple's long-form engine, including most of central and eastern Europe.

| | |
| --- | --- |
| **Best for** | Languages Apple's long-form engine does not cover, and short dictation |
| **Speed** | 26 to 59 times real time |
| **Memory** | About 20 MB |
| **Download** | None, though macOS fetches a language the first time you use it |
| **Live typing** | Yes |
| **Needs** | macOS 26 or later |

## Languages

Croatian, Czech, Polish, Russian, Slovak and Ukrainian are covered by this engine alone - Apple's long-form engine has no model for them at all.

## Word Error Rate (WER)

Word error rate (WER) is the share of words you would have to fix, so lower is better. Measured on read speech in the [FLEURS](https://huggingface.co/datasets/google/fleurs) dataset; your own recordings can differ.

| | This engine | Apple long-form | Best downloadable model |
| --- | --- | --- | --- |
| English | 12.9% | 8.0% | 3.7% |
| German | 13.0% | 6.5% | 4.1% |
| Spanish | 7.4% | 4.5% | 3.1% |
| French | 16.5% | 7.5% | 4.6% |
| Polish | 13.2% | not supported | 5.8% |

Where both built-in engines exist, this is the weaker one by 3 to 9 points. Where it is the only one, a downloaded model typically more than halves its errors.

## Choosing

**Pick it if** your language is not one of Apple's long-form languages and you would rather not download anything, or you are dictating a sentence at a time.

**Skip it for recordings.** It is built for short speech, and on anything longer almost every downloadable model beats it by a wide margin.

**Worth knowing**

- **It arrived in macOS 26.** On anything older it does not exist, and Speech says so rather than offering it.
- **A macOS update can change it, but so far barely has.** Across macOS 26.6.2, 26.7.0 and 27.0 its accuracy moved by at most a fifth of a percentage point.
- Speech turns punctuation on for it; on its own it returns unpunctuated text.
- It produces word-level timings, so it can make subtitles.
- It cannot be given your own vocabulary, and learns nothing from your corrections.
