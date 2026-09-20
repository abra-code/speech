# Canary 1B v2

NVIDIA's Canary, covering 25 European languages. The best all-round accuracy measured here, at a speed and memory cost most Macs will not notice.

| | |
| --- | --- |
| **Best for** | Accurate transcription in European languages |
| **Speed** | 47 to 56 times real time, so an hour takes about a minute |
| **Memory** | 1.3 GB |
| **Live typing** | No |
| **Subtitles** | No - it produces no timestamps |

## Word Error Rate (WER)

Word error rate (WER) is the share of words you would have to fix, so lower is better.

| | Canary | Built into macOS |
| --- | --- | --- |
| English | 4.9% | 8.0% |
| Polish | 6.8% | 13.2% |
| German | 4.4% | 6.5% |

## Choosing

**Pick it if** you want one model that is strong in every European language and you do not need subtitles.

**Skip it if** you need subtitles or live typing, or your language is outside Europe.

**Worth knowing**

- **You must tell it the language.** It cannot detect one, and given the wrong language it quietly translates instead of transcribing - fluent text about the right subject, in the wrong language. Speech refuses to run it without a language set rather than let that happen.
- No timestamps at all, so no subtitle files.
- Long recordings are split at quiet points automatically.
