# Apple (built in)

> Measured on an Apple M5 with macOS 26.6.2, 26.7.0 and 27.0 in September 2026,
> over the full FLEURS test sets. The table below is macOS 27.0; what the three
> releases changed is its own section. Use these numbers as a guide: results on
> your Mac and with your own recordings can differ.

macOS includes two speech engines, and `speech` offers both. They need no download, run on the Neural Engine, and set the bar: a downloaded model is worth installing only if it does better.

Both need macOS 26; on older systems they show as unavailable, with the reason. Neither needs Siri or keyboard dictation turned on. The first time a language is used, macOS downloads its files. If macOS reports the long-form model as unavailable, `apple.transcriber` says so and `apple.dictation` still works.

## The two engines

**`apple.transcriber` (SpeechTranscriber).** The long-form engine used by Notes and Voice Memos. 45 locales in 25 languages on macOS 27.0, and 30 locales in 10 languages on macOS 26.6.2 - the difference is 15 Indian languages that macOS 27 added. Word timings and confidence scores. Strong on clear English speech, and by far the lightest on memory.

**`apple.dictation` (DictationTranscriber).** The keyboard dictation engine. 54 locales in 33 languages, including Croatian, Czech, Polish, Russian, Slovak and Ukrainian, which the long-form engine does not support. It is built for short speech and is the only Apple engine that accepts a custom vocabulary. `speech` turns punctuation on for it; by default it returns unpunctuated text.

## Measurements

Full FLEURS test sets, macOS 27.0, 2026-09-19. Word error rate (WER) in percent, lower is better; speed in multiples of real time. Both engines ship with the operating system and change with it, so every Apple figure here and in [docs/benchmarks](../benchmarks/README.md) names the macOS version it was measured on.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `apple.transcriber` | 8.03 | not supported | 6.51 | 54-85x | 17-21 MB |
| `apple.dictation` | 12.86 | 13.16 | 13.03 | 26-59x | 17-21 MB |

Memory is in tens of megabytes because macOS, not the app, holds the model. Every downloaded model uses hundreds of megabytes or more.

Where both engines support a language, the long-form engine is 4.8 to 6.5 WER points better (English and German).

## What three macOS releases changed

The same Mac, the same corpora, three operating systems. Accuracy barely moves; speed does.

**The long-form engine gained 15 languages in macOS 27.0, all Indian.** `SpeechTranscriber.supportedLocales` returns 30 locales on macOS 26.6.2 and 45 on 27.0, and every new one is an `_IN` locale: Bengali, Gujarati, Hindi, Kannada, Kashmiri, Maithili, Malayalam, Marathi, Nepali, Odia, Punjabi, Tamil, Telugu, Urdu, and a `mul_IN` multilingual model. In language terms that is 10 to 25. `DictationTranscriber` did not move: 54 locales on both.

That is the largest functional change in these three releases, and it is the one `speech` does not yet show you: the language list it prints for `apple.transcriber` is a constant derived from macOS 26.6.2, so the new languages are missing from `speech engines` and from the catalog's language filter until that list is re-derived. Nothing blocks them at run time - the engine is asked for the real answer when a run prepares - but they are not advertised, and none of them is measured in [docs/benchmarks](../benchmarks/README.md).

**The long-form engine's accuracy has not changed at all.** `apple.transcriber` returns the same WER to two decimals on every FLEURS language across 26.6.2, 26.7.0 and 27.0 - 8.03 English, 6.51 German, 4.54 Spanish, 7.47 French - and within 0.01 on both LibriSpeech splits. Its live figures repeat across versions too. If a release improved this engine, it did not improve what it gets right.

**Dictation moves slightly, and only on 27.0.** 26.6.2 and 26.7.0 agree to two decimals everywhere except French.

| `apple.dictation` WER | 26.6.2 | 26.7.0 | 27.0 |
| --- | --- | --- | --- |
| en (FLEURS) | 13.08 | 13.08 | 12.86 |
| de | 13.20 | 13.20 | 13.03 |
| fr | 16.39 | 16.55 | 16.50 |
| pl | 13.16 | 13.16 | 13.16 |
| LibriSpeech test-clean | 8.38 | 8.38 | 8.39 |
| LibriSpeech test-other | 15.72 | 15.72 | 15.83 |

The German gain is worth trusting more than its size suggests: the live battery measured the same -0.17 on a different corpus through a different code path.

**Speed is where 27.0 differs, and only for the long-form engine.**

| `apple.transcriber` speed | 26.6.2 | 26.7.0 | 27.0 |
| --- | --- | --- | --- |
| en (FLEURS) | 59.6x | 58.4x | 64.3x |
| de | 123.4x | 123.8x | 84.7x |
| es | 115.3x | 113.6x | 80.8x |
| fr | 101.6x | 101.9x | 75.2x |
| zh | 98.3x | 95.7x | 59.8x |
| LibriSpeech test-clean | 52.0x | 51.2x | 53.5x |

26.6.2 and 26.7.0 sit within a percent or two of each other. On 27.0 the non-English rows lost a quarter to a third of their throughput while English gained about ten percent, leaving every language inside one 54-85x band. `apple.dictation` lost 3 to 8 percent across the board and has no such split.

This does not show up in live use. Streaming feeds audio at 1x, so 54x is still fifty times more headroom than the audio needs, and the live figures for those same languages are unchanged. It matters for batch work on long recordings, and on hardware slower than an M5.

**Spanish is pinned to `es_MX`, because Apple's own answer is a coin flip.** When a tag names a region Apple has no exact locale for, `supportedLocale(equivalentTo:)` returns an arbitrary member of the matching set: fixed within a process, redrawn on the next launch. Twelve launches on one macOS 27.0 Mac answered `es-419` with es_US five times, es_CL four, es_ES twice and es_MX once; a second Mac on macOS 26.6.2 split it four ways too, so this is not something a release introduced. A tag Apple lists exactly, such as `es-ES` or `es-MX`, answers the same every launch.

That draw is worth 6.5 WER points. Live, `apple.dictation` scored 18.43 WER through `es_ES` and 11.90 through `es_MX` on the same corpus: `es_ES` dropped the last words of utterances, 96 of them across twenty passages, and `es_MX` dropped none. Forcing `es-ES` explicitly reproduces the bad figure exactly - 18.19 WER, the same 96 words. Batch scoring shows the opposite and much smaller effect, 6.93 against 7.44, because a batch row is one short utterance where a dropped tail costs little.

So `speech` does not leave it to chance: a bare `es` and `es-419` both reach Apple's engines as `es_MX`, deliberately, because the Spanish this project measures and ships for is Latin American. `es-ES` and the other regions Apple lists are taken as asked. Figures measured before this pin recorded whichever locale the run drew, which is why every report names the locale it used - the macOS 26.7.0 Spanish rows in [docs/benchmarks](../benchmarks/README.md) drew `es_ES`, and the 27.0 rows drew `es_MX`.

This is not an accent match either way. FLEURS files the corpus as `es_419`, "Latin America", but the label is on the split, not the speakers: its 908 test rows are 348 sentences read by several voices each, and the only per-row metadata is the reader's gender. The varieties are mixed - at least one passage is plainly Rioplatense, with `ellas` read as "eshas" rather than the "eyas" heard in most of Latin America - so no single regional model matches the set. What separates `es_ES` from `es_MX` here is whether the engine finishes an utterance, not which accent it was trained on.

## Limits

- **No custom vocabulary on the long-form engine.** It ignores custom terms (an Apple engineer confirmed this in developer forum thread 801877), so `speech` reports `vocab: false` for it.
- **Six of its languages have no long-form engine:** Croatian, Czech, Polish, Russian, Slovak and Ukrainian. They fall back to dictation, which is the whole gap between Apple's best and worst measured scores - 6.51 in German against 13.16 in Polish.
- **No speaker labels and no language detection.**
- **Language files are installed separately** and shared by all apps. `speech models install-locale <bcp47>` installs one and then checks that it is really there, because macOS can report a locale as supported and installed when it is not.

## Language tags

A language without a region uses its main region: `it` is `it_IT`, `nl` is `nl_NL`, `es` is `es_ES`, `pt` is `pt_BR`. Apple's own lookup picks the first variant it lists, so `speech` uses it only when there is no locale for the main region, as for Arabic (`ar_SA`) and `es-419`. What that lookup returns changes between releases: `it_CH` for Italian on macOS 26.6.2, and `es-419` resolved to `es_ES` on macOS 26 but to `es_MX` on macOS 27.0. Pass a full tag for another region; `engine.ready.locale` shows which locale a run used, and `speech eval` records it in every report.
