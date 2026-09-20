# Parakeet v3

NVIDIA's Parakeet v3, for 25 European languages. More accurate than the engine built into macOS in every language measured, and fast enough to get through an hour of audio in well under a minute.

| | |
| --- | --- |
| **Best for** | Long recordings in European languages |
| **Speed** | 100 to 150 times real time |
| **Memory** | 0.6 GB, or 1.0 GB for the most accurate build |
| **Live typing** | Yes |

## Languages

The three builds differ slightly: the FluidAudio (Core ML) one adds Belarusian, Bosnian and Serbian to the 25 the others cover.

## Word Error Rate (WER)

Word error rate (WER) is the share of words you would have to fix, so lower is better. Measured on read speech; your own recordings can differ.

| | Parakeet v3 | Built into macOS |
| --- | --- | --- |
| English | 5.4% | 8.0% |
| Polish | 7.4% | 13.2% |
| German | 5.2% | 6.5% |

Apple's column is whichever of its two engines does better in that language. Of these 25 languages macOS handles only 6 with its better engine; 13 more it covers with dictation alone, which is weaker, and 6 it does not support at all.

## Choosing

**Pick it if** you work in one of these languages and want the best accuracy for the download size.

**Skip it if** your language is not on the list - Whisper and Qwen3-ASR cover far more.

**Worth knowing**

- Three builds of the same model are offered. The FluidAudio (Core ML) build is the fastest and the smallest; the ggml build is slightly more accurate; the MLX build needs about four times the memory for the same result.
- The int4 build saves 145 MB and gives up several points of accuracy, which puts it behind Apple. Choose it only if disk space is the deciding factor.
- Long recordings are split at quiet points automatically, so length is not a limit.
