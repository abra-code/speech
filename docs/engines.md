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

`live` is what `speech stream` filters on, and today only the two Apple rows
carry it. See `docs/live.md` for how a live session is driven, what format each
family demands, and how a run stops.

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

## `fluid.*` - FluidAudio 0.15.6, CoreML on the Neural Engine

Shipped in stage 1. NVIDIA's Parakeet, Canary and Nemotron models as compiled
CoreML packages, downloaded from FluidInference on Hugging Face into the tool's
own model store.

The distinguishing property is memory. These rows keep most of their cost on the
Neural Engine rather than in process footprint, so peak RSS cannot see it and
`speech eval` has to sum the footprint and the ANE ledger to report it at all.
They are also the only rows that accept a custom vocabulary, which they
implement by spotting terms with a separate small CTC model.

Fourteen rows: two Parakeet v3 precisions, three Nemotron streaming chunk tiers,
one Canary precision, two Parakeet Unified precisions, four Parakeet Unified
streaming latency tiers, and two helpers that transcribe nothing - the CTC
spotter behind custom vocabulary, and the Silero detector below.

### `fluid.silero-vad`, the row that produces no text

One compiled CoreML bundle, 1.1 MB, an LSTM over a 256 ms window: it answers
"is someone speaking" and nothing else. It is a catalog row rather than an
implementation detail because it is downloaded, measured, listed and deleted
exactly like a model, and because `speech stream --segment vad` cannot run until
it is installed - which is a download instruction a user has to be able to find.

Its capability record is every flag false and no language at all, which for this
model is the literal truth rather than a shrug: it hears speech as an acoustic
event, so it carries no vocabulary and no language. Measured here, detection
costs about 0.1 percent of real time - 0.36 s of compute for 470 s of audio -
so it can run beside any draft engine without competing with it.

Why it exists: every live row in this catalog decides utterance boundaries its
own way and none of them decides from the audio, so the same recording is cut
differently by every row and `--refine` re-transcribes a span the model chose.
See docs/live.md for what the boundaries are used for.

### Parakeet Unified has two encoders, and they are separate downloads

`fluid.parakeet-unified@int8` and `@fp16` are the *offline* encoder: full
attention over a 15 second window, the better accuracy, no live mode.
`fluid.parakeet-unified@stream-<ms>` is the *streaming* encoder from the same
checkpoint: chunked attention with the `[left, chunk, right]` mask baked in at
conversion time.

Because the mask is baked in, each latency tier is a physically different
encoder bundle, so the tier is part of the row id rather than a runtime option,
and installing one tier does not install another. The number is the theoretical
latency in milliseconds - chunk plus look-ahead, the delay before the encoder
can see a whole word:

| Row | context | latency | download |
|---|---|---|---|
| `@stream-2080` | 70, 13, 13 | 2.08 s | 609 MB |
| `@stream-1120` | 70, 7, 7 | 1.12 s | 609 MB |
| `@stream-640` | 70, 7, 1 | 0.64 s | 609 MB |
| `@stream-320` | 70, 2, 2 | 0.32 s | 608 MB |

int8 only. FluidAudio publishes each tier in both precisions and measures the
two at 2.14% and 2.15% on LibriSpeech test-clean streaming, so fp16 would double
the download for a difference smaller than any corpus here can resolve. That
published figure names no context, and the library's default is `70_13_13`, so
take it as covering the top tier rather than all four. Note also that `@fp16` is
*not* the fp16 build of these rows - it is the offline encoder, and it does not
stream.

Batch on a `@stream-` row means the streaming encoder run over a whole file.
That is deliberate: `speech eval --live` scores a row against that same row's
batch WER, and a batch number taken from the offline encoder would be comparing
two different models.

## `ggml.*` - transcribe.cpp 0.2.3, ggml on Metal

Shipped in stage 2. GGUF weights from handy-computer on Hugging Face, run
through a vendored Swift wrapper over a binary xcframework.

This engine is what put Whisper, Qwen3-ASR and an 8-bit Canary within reach. Its
cost is memory of a different shape: every measured row reports a Neural Engine ledger
of exactly zero, because ggml runs on Metal and never touches the ANE, so the
whole cost is process footprint, which is the mirror image of the CoreML rows
and means the two engines have to be sized differently for the same weights.

Thirteen rows across six families, most at two quantizations.

Any figure quoted on this page or in docs/models.catalog.tsv is a property of a
build, not a score: sizes and capability flags are stable, but speed and
accuracy belong to a machine, an OS and a set of dependency versions, and have
to be measured where they are going to be used.

Two things this engine does that no other does. It reads every capability fact
out of the GGUF rather than from a model card, which corrected four assumptions
in stage 2 - Canary has no timestamps and a 400 second ceiling, Nemotron does
identify its own language, Qwen3-ASR caps a run at about 87 minutes, and
Parakeet v3 reports 25 languages where the CoreML build advertises 28. And it
cuts a long recording into pieces for the families with a hard ceiling, at local
energy minima, stitching the transcripts back with offset timestamps.

Its xcframework is dynamic, unlike FluidAudio's static dependency, so
`CTranscribe.framework` ships beside `build/speech` and whoever embeds one
embeds both.

## Deployment floor

Both libraries would run lower - FluidAudio declares macOS 14 and transcribe.cpp
macOS 13 - but the binary's deployment target is macOS 15, set by
`fluid.canary-1b-v2@int4`, whose int4 weight payloads need CoreML's macOS 15
runtime and which has no other published precision.

A build without those targets simply has no `fluid` or `ggml` entry in the
engine registry and reports `unavailable` for those ids, rather than failing to
link. That is what lets the stages land one engine at a time.

## Choosing between them

`speech engines` lists what a build carries and whether it can run here.
`speech catalog` adds where each row's weights come from, how big they are and
whether they are installed. Neither has an opinion about any of it, and that is
deliberate: which row to use depends on the language, the recording and the
machine, and the measurements that would settle it are only valid for the
machine, the OS and the dependency versions they were taken on.

Speech.app makes that choice, and can re-measure locally with `speech eval` -
against the standard corpora or against the user's own recordings. See
docs/catalog.md for what this tool reports and why the ranking is not part of
it.
