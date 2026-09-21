# Qwen3-ASR

Alibaba's Qwen3-ASR, which pairs a speech model with a language model. The most accurate English and German measured here, and the most uneven across languages - which is why the language you work in decides whether it is the right choice.

| | |
| --- | --- |
| **Best for** | English and German, where accuracy matters more than speed |
| **Speed** | 10 to 14 times real time, so an hour takes about five minutes |
| **Memory** | 3.7 GB, or 1.6 GB for the smaller model |
| **Live typing** | No |
| **Subtitles** | No - it produces no timestamps |

## Word Error Rate (WER)

Word error rate (WER) is the share of words you would have to fix, so lower is better. Measured on read speech in the [FLEURS](https://huggingface.co/datasets/google/fleurs) dataset; your own recordings can differ.

| | Qwen3-ASR | Built into macOS |
| --- | --- | --- |
| English | 3.7% | 8.0% |
| German | 4.1% | 6.5% |
| Polish | 12.2% | 13.2% |

**Being on the list is not the same as being good at it.** Its languages spread further apart than any other model measured here: best-in-class German at one end, and at the other a score that barely improves on what macOS already does for free. Check the language you care about in the table above rather than trusting the list.

## Choosing

**Pick it if** you transcribe English or German and want the lowest error count available, and a few minutes per hour of audio is acceptable.

**Skip it if** your language is one of its weaker ones, you need subtitles, or your Mac has 8 GB of memory - the accurate version alone wants 3.7 GB.

**Worth knowing**

- A smaller version is offered at about half the memory. It costs half a point in English and several points in the languages it is already weakest at.
- No timestamps, so no subtitle files.
- Its makers publish it as strong on difficult audio - accents, background noise, people talking over each other. These measurements are all clear read speech and cannot show that, so it may do better on hard recordings than the table suggests.
