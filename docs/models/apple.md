# Apple (built in)

> Measured on an Apple M5 with macOS 26.6.2 in September 2026, over the full
> FLEURS test sets. Use these numbers as a guide: results on your Mac and with
> your own recordings can differ.

macOS includes two speech engines, and `speech` offers both. They need no download, run on the Neural Engine, and set the bar: a downloaded model is worth installing only if it does better.

Both need macOS 26; on older systems they show as unavailable, with the reason. Neither needs Siri or keyboard dictation turned on. The first time a language is used, macOS downloads its files. If macOS reports the long-form model as unavailable, `apple.transcriber` says so and `apple.dictation` still works.

## The two engines

**`apple.transcriber` (SpeechTranscriber).** The long-form engine used by Notes and Voice Memos. 30 locales in 10 languages, with word timings and confidence scores. Strong on clear English speech, and by far the lightest on memory.

**`apple.dictation` (DictationTranscriber).** The keyboard dictation engine. 54 locales in 33 languages, including Polish, Czech, Croatian, Ukrainian, Russian and Slovak, which the long-form engine does not support. It is built for short speech and is the only Apple engine that accepts a custom vocabulary. `speech` turns punctuation on for it; by default it returns unpunctuated text.

## Measurements

Full FLEURS test sets, macOS 26.6.2, 2026-09-04. Word error rate (WER) in percent, lower is better; speed in multiples of real time. Both engines change with macOS updates, and [docs/benchmarks](../benchmarks/README.md) lists the macOS version for every Apple result.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `apple.transcriber` | 8.03 | not supported | 6.51 | 60-124x | 18-20 MB |
| `apple.dictation` | 13.08 | 13.16 | 12.98 | 35-61x | 20-25 MB |

Memory is in tens of megabytes because macOS, not the app, holds the model. Every downloaded model uses hundreds of megabytes or more.

Where both engines support a language, the long-form engine is 5 to 6.5 WER points better (English and German).

## Limits

- **No custom vocabulary on the long-form engine.** It ignores custom terms (an Apple engineer confirmed this in developer forum thread 801877), so `speech` reports `vocab: false` for it.
- **No Polish, Czech, Croatian, Ukrainian, Russian or Slovak on the long-form engine.** These languages use dictation, which is why Apple's Polish score is 13.16 while German is 6.51.
- **No speaker labels and no language detection.**
- **Language files are installed separately** and shared by all apps. `speech models install-locale <bcp47>` installs one and then checks that it is really there, because macOS can report a locale as supported and installed when it is not.

## Language tags

A language without a region uses its main region: `it` is `it_IT`, `nl` is `nl_NL`, `es` is `es_ES`, `pt` is `pt_BR`. Apple's own lookup picks the first variant it lists (`it_CH` for Italian on macOS 26.6.2), so `speech` uses it only when there is no locale for the main region, as for Arabic (`ar_SA`). Pass a full tag for another region; `engine.ready.locale` shows which locale a run used.
