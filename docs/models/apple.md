# Apple (built in)

> Every number on this page comes from one battery: an Apple M5 on macOS 26.6.2,
> September 2026, over the full FLEURS test splits. It is a reference point for
> what to expect, not a measurement of your Mac. Speech.app can re-run it locally,
> and against your own recordings, which is the number that actually decides.

macOS ships two speech engines and `speech` exposes both. They cost nothing to install, run on the Neural Engine, and are the sensible baseline: whatever else you install has to be better than what the Mac already does.

Neither needs Siri or keyboard dictation turned on in System Settings, and a language's files download from Apple the first time it is used. On a Mac where macOS reports the long-form model as not available, `apple.transcriber` says so and `apple.dictation` still runs.

Both need macOS 26. On anything older they report `unavailable` with a reason, and there is no built-in baseline at all - on those systems any working third-party row is an improvement over nothing.

## The two rows

**`apple.transcriber` - SpeechTranscriber.** The long-form engine, the one behind Notes and Voice Memos. 30 locales in 10 languages. Word timings and confidences. It was strong on clean English read speech and the cheapest thing here by a wide margin.

**`apple.dictation` - DictationTranscriber.** Keyboard dictation's engine. 54 locales in 33 languages, and the only Apple module that covers Polish, Czech, Croatian, Ukrainian, Russian and Slovak. It is short-form, and it is the only Apple engine that accepts a custom vocabulary.

Punctuation is requested explicitly for dictation. Left alone it emits unpunctuated text, which is right for a text field and wrong for a transcript.

## What they measured

Full FLEURS test splits on macOS 26.6.2, 2026-09-04.

These are figures for that version of macOS. Both engines ship with the system and change with it, so a later version is measured again and reported beside these rather than in their place: [docs/benchmarks](../benchmarks/README.md) names the macOS version on every Apple row.

| row | en | pl | de | speed | memory |
| --- | --- | --- | --- | --- | --- |
| `apple.transcriber` | 8.03 | not supported | 6.51 | 60-124x | 18-20 MB |
| `apple.dictation` | 13.08 | 13.16 | 12.98 | 35-61x | 20-25 MB |

The memory figures are not a typo. Both engines are ANE-resident with the weights owned by the OS, so the process footprint is tens of megabytes against hundreds for any downloaded row. Nothing else measured here is close.

The gap between the two is large enough to matter: on English and German, using dictation where the long-form engine would work costs about 6 WER points.

## What they cannot do

- **No custom vocabulary on the long-form engine.** SpeechTranscriber ignores contextual strings entirely, confirmed by an Apple engineer in developer forum thread 801877, so the row reports `vocab: false` rather than accepting terms and silently dropping them.
- **No Polish on the long-form engine**, and no Czech, Croatian, Ukrainian, Russian or Slovak either. Those languages fall to dictation, which is why Polish has a 13.16 baseline where German has 6.51.
- **No diarization, no language identification.**
- **Locale assets are a separate install.** They are system-wide and shared between apps. `speech models install-locale <bcp47>` installs one and then verifies it turns up in `installedLocales`, because a locale can be reported as supported, install without error, and still not be there.

## Language handling

A bare primary subtag resolves to whichever regional model Apple ships first, and it is not always the one you would guess: `de` lands on `de_AT`, `es` on `es_US`, `fr` on `fr_CA`, `it` on `it_CH`. Pass a full tag when the region matters, and read `engine.ready.locale` to see which one a run really used.
