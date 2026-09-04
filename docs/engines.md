# Engines

Every backend implements one protocol (`TranscriptionEngine` in SpeechCore) and
declares what it can do in an `EngineCapabilities` record. Nothing above the
engine layer branches on which engine is running; if one backend can do
something another cannot, that is a capability flag.

A catalog id is `<engine>.<model>[@<variant>]` - `apple.transcriber`,
`fluid.parakeet-v3@int8`, `ggml.qwen3-asr-1.7b@q4_k_m`. Everything before the
first dot selects the backend; a model name may contain dots of its own.

## Capability flags

| flag | meaning |
| --- | --- |
| `batch` | transcribes a whole file in one call |
| `live` | accepts a microphone stream and emits partials |
| `word_ts` | reports per-word time ranges |
| `seg_ts` | reports per-segment time ranges |
| `vocab` | biases recognition toward supplied terms |
| `diarize` | labels speakers |
| `lang_id` | detects the spoken language on its own |
| `lang_hint` | accepts a language hint (some engines require one) |

`languages` lists BCP-47 primary subtags; an empty list means the engine takes
any language. `minimum_macos` is the floor the engine runs on.

Options an engine cannot honor are a `warning` event and a transcript, not a
failure: a transcript without hotword biasing still beats no transcript.

## Shipping now

### `apple.transcriber` - SpeechTranscriber (macOS 26+)

Apple's long-form engine, the one behind Notes and Voice Memos. Zero download
beyond its locale asset, ANE-resident, and state of the art on clean English
read speech. This is the baseline every other catalog row has to beat in some
language, or beat on a capability, to be worth shipping at all.

- 30 locales in 10 languages on macOS 26.6.2: de, en, es, fr, it, ja, ko, pt,
  yue, zh.
- Word timings and confidences.
- **No custom vocabulary.** SpeechTranscriber ignores contextual strings
  entirely - confirmed by an Apple engineer in developer forum thread 801877 -
  so the engine reports `vocab: false` instead of accepting terms and silently
  dropping them.
- Etiquette replacement (profanity masking) is deliberately left off: it would
  change the words, and therefore the WER, of the row everything else is
  measured against.

### `apple.dictation` - DictationTranscriber (macOS 26+)

Keyboard dictation's engine. Short-form, but it is the only Apple module that
covers Polish, Czech, Croatian, Ukrainian, Russian and Slovak, and the only one
that accepts a custom vocabulary.

- 54 locales in 33 languages.
- Punctuation is requested explicitly. Dictation emits unpunctuated text by
  default, which is right for a text field and wrong for a transcript.
- Contextual strings are passed through `--vocab`.

Both Apple engines are gated three ways: `#if canImport(Speech)` at compile
time, `#available(macOS 26, *)` at run time, and `SpeechTranscriber.isAvailable`
for the case where the OS is new enough but the models are not there. Every
negative answer carries a reason; `speech info` prints them.

Locale assets are system-wide and shared between apps. `speech models
install-locale <bcp47>` installs one and then verifies it turns up in
`installedLocales`, because a locale can be reported as supported, install
without error, and still not be there.

### Language handling

A bare primary subtag resolves to whichever regional model Apple ships first,
and it is not always the one you would guess: `de` lands on `de_AT`, `es` on
`es_US`, `fr` on `fr_CA`, `it` on `it_CH`. Pass a full tag (`de-DE`) when the
region matters, and read `engine.ready.locale` - or the eval report's "Locale
actually used" - to see which one a run really used.


The `languages` list on an Apple engine is a catalog fact and can lag an OS
update, so it is never the gate: a language it does not list produces a warning,
and the engine's own `supportedLocale(equivalentTo:)` gives the authoritative
answer with a better message. `speech info` prints the live lists, which is how
a drift gets noticed.

## Planned

| id prefix | backend | stage |
| --- | --- | --- |
| `fluid` | FluidAudio 0.15.6, CoreML on the ANE | 1 |
| `ggml` | transcribe.cpp 0.2.3 xcframework, ggml with Metal | 2 |

Both libraries would run lower - FluidAudio declares macOS 14 and transcribe.cpp
macOS 13 - but the binary's deployment target is macOS 15, set by
`fluid.canary-1b-v2@int4`, whose int4 weight payloads need CoreML's macOS 15
runtime and which has no other published precision.

A build without those targets simply has no `fluid` or `ggml` entry in the
engine registry and reports `unavailable` for those ids, rather than failing to
link. That is what lets the stages land one engine at a time.
