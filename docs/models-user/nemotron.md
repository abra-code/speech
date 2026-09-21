# Nemotron 3.5 ASR streaming

NVIDIA's streaming model. It writes text while you are still speaking, which is the one thing the more accurate models cannot do.

| | |
| --- | --- |
| **Best for** | Live typing as you speak |
| **Speed** | Keeps up with speech comfortably |
| **Memory** | 0.65 GB to 1.0 GB |
| **Download** | About 664 MB per version |
| **Live typing** | Yes - this is its purpose |

## Languages

About 30, and it works out which one is being spoken on its own.

## Word Error Rate (WER)

Word error rate (WER) is the share of words you would have to fix, so lower is better. These come from transcribing finished recordings of read speech in the [FLEURS](https://huggingface.co/datasets/google/fleurs) dataset; your own recordings can differ.

| | Nemotron | Built into macOS |
| --- | --- | --- |
| English | 10.4% | 8.0% |
| Polish | 17.2% | 13.2% |
| German | 10.3% | 6.5% |

It loses to the built-in engines on every language measured, which is the honest picture for transcribing files.

## Choosing

**Pick it if** you want words appearing as you talk and you would rather not use the built-in dictation.

**Skip it for recordings.** For a file you already have, every other model here is more accurate, including the one already in macOS.

**Worth knowing**

- Several versions are offered that differ only in how long they wait before showing text. A shorter wait puts words on screen sooner; a longer one is slightly more accurate. Each is a separate download.
- These figures come from transcribing files, so they flatter it: judge it live, where its competition is the built-in dictation engine rather than the models above.
