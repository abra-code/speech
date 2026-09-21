# Granite Speech

IBM's Granite Speech, in four versions. It takes the top four places of every model measured on audiobook recordings, and sits mid-table on read Wikipedia sentences - so what it is worth depends on what your recordings sound like.

| | |
| --- | --- |
| **Best for** | Clear, prepared English speech: audiobooks, read scripts, narration |
| **Speed** | 9 to 17 times real time, so an hour takes 4 to 7 minutes |
| **Memory** | 3.6 GB to 5.4 GB, the heaviest here |
| **Live typing** | No |
| **Subtitles** | Only from the Plus version |

## Languages

English in practice. The models also list French, German, Portuguese, Spanish and, in two of them, Japanese, but only English was measured on full test sets. A small German sample was well behind what macOS already does, so there is no reason yet to choose it for German.

## Word Error Rate (WER)

Word error rate (WER) is the share of words you would have to fix, so lower is better. Two English test sets here, because they disagree: audiobooks from the [LibriSpeech](https://openslr.org/12/) test-clean split, and read sentences from the [FLEURS](https://huggingface.co/datasets/google/fleurs) dataset.

| | Granite | Parakeet Unified | Built into macOS |
| --- | --- | --- | --- |
| Audiobooks | 1.4% | 1.8% | 2.3% |
| Read sentences | 5.6% | 4.9% | 8.0% |

Both are clear English read aloud. A model that leads on one and not the other is telling you which kind of recording it was trained on, not which is better in general.

## Choosing

**Pick it if** your recordings are audiobook-like and the last half point of accuracy is worth several gigabytes of memory and a few minutes per hour.

**Skip it if** you want one model for everything. Parakeet Unified is within half a point on audiobooks, ahead on ordinary sentences, and runs five to ten times faster in under 1 GB.

**Worth knowing**

- Four versions: the fastest and most accurate on audiobooks needs the most memory of anything offered, 5.4 GB; the Plus version is the only one that can make subtitles; the oldest version is behind the others on every test and can be ignored.
- **You must tell it the language**; it cannot detect one.
- Neither test set contains meetings, phone calls, strong accents or noisy rooms, which is where most errors really happen.
