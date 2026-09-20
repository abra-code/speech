# Whisper large-v3-turbo

OpenAI's Whisper, covering about 99 languages - far more than anything else offered here - and the most even across the ones measured.

| | |
| --- | --- |
| **Best for** | Languages nothing else covers, and ones the other models handle poorly |
| **Speed** | 13 to 17 times real time, so an hour of audio takes about four minutes |
| **Memory** | 1.1 GB, or 3.6 GB for the heavier build |
| **Live typing** | No |
| **Subtitles** | Yes, by sentence rather than by word |

## Languages

About 99, which in practice means nearly every language with a written standard. Being on the list is not the same as being well served: quality falls off for languages with little training data, and only English, Polish, German, Spanish, French and Chinese were measured here.

## Word Error Rate (WER)

Word error rate (WER) is the share of words you would have to fix, so lower is better.

| | Whisper | Built into macOS |
| --- | --- | --- |
| English | 5.0% | 8.0% |
| Polish | 5.8% | 13.2% |
| German | 5.1% | 6.5% |

It is strongest where the widely supported models are weakest. Polish, the least widely supported of the languages measured here, is the clearest case: 56 percent fewer errors than macOS makes, and better than every other model measured.

## Choosing

**Pick it if** your language is not covered elsewhere, or the models with shorter language lists do poorly on it.

**Skip it if** you transcribe English or German and care about speed - other models here are both more accurate and five to ten times faster.

**Worth knowing**

- It is the slowest of the fast models. An hour takes about four minutes, against about thirty seconds for Parakeet.
- Timestamps are by sentence, not by word, which is enough for subtitles but not for lining text up word by word.
- The heavier build is a fraction better in German and needs three times the memory for it.
