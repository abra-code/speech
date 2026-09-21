# Parakeet Unified (English)

NVIDIA's English-only Parakeet. The fastest model offered here, and the most accurate English you can get in under 1 GB of memory.

| | |
| --- | --- |
| **Best for** | English, in bulk, quickly |
| **Speed** | 100 to 160 times real time, so an hour takes well under a minute |
| **Memory** | 0.7 GB |
| **Live typing** | Yes |
| **Subtitles** | Yes |

## Languages

English only. It takes no language setting at all.

## Word Error Rate (WER)

Word error rate (WER) is the share of words you would have to fix, so lower is better. Read sentences come from the [FLEURS](https://huggingface.co/datasets/google/fleurs) dataset, audiobooks from the [LibriSpeech](https://openslr.org/12/) test-clean split; your own recordings can differ.

| | Parakeet Unified | Built into macOS |
| --- | --- | --- |
| Read sentences | 4.9% | 8.0% |
| Audiobooks | 1.8% | 2.3% |

## Choosing

**Pick it if** you transcribe English and want the best speed-to-accuracy trade here, or you have a large backlog of recordings.

**Skip it if** you need any other language - it has none - or you want the lowest possible English error count, where Qwen3-ASR is more than a point better at a tenth of the speed and five times the memory.

**Worth knowing**

- Two versions differ only in memory: one uses 578 MB more for identical accuracy and speed, so the lighter one is the sensible choice.
- It is the one model here fast enough that transcription time is rarely what you wait for.
