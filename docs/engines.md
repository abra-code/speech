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

`live` is what `speech stream` filters on, and fourteen rows carry it: the two
Apple modules, both Nemotron streaming families, `fluid.parakeet-v3`, the four
`fluid.parakeet-unified@stream-` tiers and `ggml.parakeet-unified-en-0.6b`. See
[docs/live.md](live.md) for how a live session is driven, what format each
family demands, and how a run stops.

Options an engine cannot honor are a `warning` event and a transcript, not a
failure: a transcript without hotword biasing still beats no transcript.

## Shipping now

### `apple.transcriber` - SpeechTranscriber (macOS 26+)

Apple's long-form engine, the one behind Notes and Voice Memos. Zero download
beyond its locale asset, ANE-resident, and state of the art on clean English
read speech. This is the baseline every other catalog row has to beat in some
language, or beat on a capability, to be worth shipping at all.

- 45 locales in 25 languages on macOS 27.0: the 10 of macOS 26.6.2 - de, en,
  es, fr, it, ja, ko, pt, yue, zh - plus 15 Indian languages macOS 27 added:
  bn, gu, hi, kn, ks, mai, ml, mr, ne, or, pa, ta, te, ur and a `mul_IN`
  multilingual model. The list `speech` prints is still the macOS 26.6.2 one
  (`AppleSpeech.transcriberLanguages`), so the new languages work when asked
  for but are not advertised.
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

Both Apple engines are gated by `#if canImport(Speech)` at compile time and
`#available(macOS 26, *)` at run time. `apple.transcriber` alone is also gated
by `SpeechTranscriber.isAvailable`, which macOS sets false on a Mac that cannot
run the long-form model. The SDK has no such property for
DictationTranscriber, and Apple names it as the module to use in that case, so
`apple.dictation` stays available there. Every negative answer carries a
reason; `speech info` prints them.

Neither engine needs Siri or keyboard dictation turned on in System Settings.
That was the older SFSpeechRecognizer's requirement; Apple says it does not
apply to SpeechAnalyzer.

Locale assets are system-wide and shared between apps. `speech models
install-locale <bcp47>` installs one and then verifies it turns up in
`installedLocales`, because a locale can be reported as supported, install
without error, and still not be there.

### Language handling

A bare primary subtag resolves to the locale for the language's main region
when the engine has one: `it` is `it_IT`, `nl` is `nl_NL`, `es` is `es_ES`, `pt`
is `pt_BR`, `zh` is `zh_CN`. The main region comes from CLDR's likely subtags
(`Locale.Language.maximalIdentifier`). Apple's own
`supportedLocale(equivalentTo:)` picks whichever variant it lists first, and
that changes - it gave `it_CH` for `it` and `nl_BE` for dictation's `nl` on
macOS 26.6.2, and earlier `de_AT` for `de` - so it decides only when there is
no main-region locale, as for Arabic (`ar_SA`).

Spanish is pinned rather than resolved either way: a bare `es` and `es-419`
both reach Apple's engines as `es_MX`. Apple lists es_CL, es_ES, es_MX and
es_US, none of them matching `es-419`, and its own lookup answers with an
arbitrary one of them - fixed within a process, redrawn on the next launch, on
macOS 26.6.2 and 27.0 alike. That draw is worth 6.5 WER points on continuous
speech, because es_ES drops the last words of an utterance where es_MX does
not, so leaving it to chance would make a Spanish measurement unrepeatable.
The Spanish this project measures and ships for is Latin American, which is
why the pin is es_MX and not CLDR's es_ES. A tag naming a region Apple does
list - `es-ES`, `es-CL` - is taken as asked.

Read `engine.ready.locale` - or the eval report's "Locale actually used" - to
see which one a run really used.

The same rule picks among a ggml or MLX model's own regional spellings
(`Language.match`): a bare `es` finds `es-ES` in Nemotron's list, which names
`es-US` first.


The `languages` list on an Apple engine is a catalog fact and can lag an OS
update, so it is never the gate: a language it does not list produces a warning,
and the engine's own `supportedLocale(equivalentTo:)` gives the authoritative
answer with a better message. `speech info` prints the live lists, which is how
a drift gets noticed.

## `fluid.*` - FluidAudio 0.15.6, CoreML on the Neural Engine

NVIDIA's Parakeet, Canary and Nemotron models as compiled CoreML packages,
downloaded from FluidInference on Hugging Face into the tool's own model store.

The distinguishing property is memory. These rows keep most of their cost on the
Neural Engine rather than in process footprint, so peak RSS cannot see it and
`speech eval` has to sum the footprint and the ANE ledger to report it at all.
They are also the only rows that accept a custom vocabulary, which they
implement by spotting terms with a separate small CTC model.

Thirteen rows: two Parakeet v3 precisions, three Nemotron streaming chunk tiers,
two Parakeet Unified precisions, four Parakeet Unified streaming latency tiers,
and two helpers that transcribe nothing - the CTC spotter behind custom
vocabulary, and the Silero detector below.

A fourteenth, `fluid.canary-1b-v2@int4`, is built but unlisted. Its entry in
`catalog/fluid.json` is `"hidden": true`, which leaves it out of both sides of
the join below, so neither check reports it; `make` still builds it, so the id
still works when typed in full.
The measurements are in the README: the GGUF build of the same weights is 1.3 to
2.9 WER points better and 8x faster on an M5, and on M1-class hardware the ANE
compile fails outright after 85 minutes and leaves the row at RTFx 3.7.

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
See [docs/live.md](live.md) for what the boundaries are used for.

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

## `ggml.*` - transcribe.cpp, ggml on Metal

Built from the release in `patches/transcribe.cpp/PIN` - 0.4.1 since
2026-10-22. The measurements in this section were taken on 0.2.3 and have not
been repeated on 0.4.x yet.

GGUF weights from handy-computer on Hugging Face, run through a vendored Swift
wrapper over an xcframework.

That xcframework is built here rather than downloaded. A defect this engine
hits - the streaming commit freeze in `docs/live.md` - is fixed in no published
release (the Metal out-of-memory crash below was too, until 0.4.0), so
`tools/vendor-transcribe.sh` clones the pinned tag, applies
`patches/transcribe.cpp/`, and builds it. A patch that stops applying fails the
build; `patches/transcribe.cpp/README.md` says what each one is and what it
costs to carry.

This engine is what put Whisper, Qwen3-ASR and an 8-bit Canary within reach. Its
cost is memory of a different shape: every measured row reports a Neural Engine ledger
of exactly zero, because ggml runs on Metal and never touches the ANE, so the
whole cost is process footprint, which is the mirror image of the CoreML rows
and means the two engines have to be sized differently for the same weights.

Thirteen rows across six families, most at two quantizations.

Any figure quoted on this page or in [docs/models.catalog.tsv](models.catalog.tsv) is a property of a
build, not a score: sizes and capability flags are stable, but speed and
accuracy belong to a machine, an OS and a set of dependency versions, and have
to be measured where they are going to be used.

Two things this engine does that no other does. It reads every capability fact
out of the GGUF rather than from a model card, which corrected four
assumptions - Canary has no timestamps and declares a 400 second ceiling,
Nemotron does identify its own language, Qwen3-ASR declares about 87 minutes,
and Parakeet v3 reports 25 languages where the CoreML build advertises 28. And it
cuts every recording into pieces at local energy minima, stitching the
transcripts back with offset timestamps.

### A run's declared ceiling is not a length it survives

Until 2026-09-17 a recording was cut only where the GGUF declared a ceiling,
and a 36-minute talk showed what that missed. The declared figure bounds the
input and nothing else:

- The families whose decoder writes text token by token stop at 256 tokens per
  run, about a minute of speech. Qwen3-ASR declares 87 minutes and refused 5;
  Granite 4.0 and Canary refused 5 too, with "output truncated". Granite Speech
  NAR's 4096-token context was full at 5 minutes.
- The encoder families grow their compute graph with the square of the audio.
  Parakeet, Parakeet Unified and Nemotron finished 10 minutes and asked Metal for
  13.7 GB at 20. An unpatched transcribe.cpp 0.2.3 crashes on the failed
  allocation (SIGSEGV) rather than returning an error - measured on Parakeet TDT
  0.6B v3 at 20 minutes. Patched - by this repository on 0.2.3, by the ggml that
  0.4.0 vendors - the library reports the allocation failure and ends the run
  with an out-of-memory error instead, which is a refusal a caller can act on
  rather than a dead process; that half was measured on Qwen3-ASR 1.7B (on
  0.2.3 with the patches), which takes the same allocation path.
- Whisper windows its own input at 30 seconds and ran 20 minutes in 1.3 GB.

Staying under those limits is not enough either: every family drops whole
sentences from long pieces. So each architecture now has a measured length
(`GGMLPieces`): the longest of 10, 15, 20, 30, 45 and 70 seconds (60, 120 and
300 for Parakeet) that loses nothing against the shorter ones. It was measured
on 2026-10-22 with speech 0.2.1 on transcribe.cpp 0.4.1, on four 5-minute
recordings per language joined from unique FLEURS sentences, and on 20
one-speaker LibriSpeech passages of about a minute:

| architecture | piece | WER at that length (FLEURS one sentence at a time) | WER at 45 s, or 300 s for Parakeet |
| --- | --- | --- | --- |
| `qwen3_asr` (1.7B Q8_0) | 15 s | en 9.2% (4.2%), pl 13.9% (14.0%), LibriSpeech 1.6% | en 15.5%, pl 18.2%, LibriSpeech 1.7% |
| `canary` (1B v2 Q8_0) | 15 s | en 6.4% (4.9%), pl 8.1% (8.2%), LibriSpeech 2.1% | en 12.1%, pl 13.9%, LibriSpeech 6.6% |
| `granite_speech` (4.0 1B Q8_0) | 20 s | en 6.8% (7.4%), LibriSpeech 2.4% | en 8.0%, LibriSpeech 4.4% |
| `granite_speech_nar` (4.1 2B NAR Q8_0) | 10 s | en 8.6% (5.9%), LibriSpeech 1.7% | en 24.5%, LibriSpeech 1.6% |
| `parakeet` (TDT 0.6B v3 Q8_0) | 30 s | en 6.7% (5.0%), pl 8.8% (8.4%), LibriSpeech 1.9% | en 47.5%, pl 10.1% |

The one-speaker passages barely care about length. What a long piece costs is
the quieter of two speakers in it: the FLEURS English speakers span 49 dB, and
the sentences a long piece drops are the quiet speakers'. So the joined
recordings decide, as a meeting with a quiet participant would. Qwen3-ASR does
better in English at 10 s (7.9%) but worse in Polish (15.9%). Lengths shorter
than 10 s, and 10 s for Canary, were not tried.

Whisper keeps the whole file; another encoder gets 30 seconds, and any other
architecture 15, since a piece too short costs a little accuracy where one too
long costs the transcript. A piece refused anyway - a decoder that repeats
itself can fill its budget on ten seconds, as Granite 4.0 did once - is cut in
half at quiet points and retried, down to 5 seconds, so one bad piece does not
fail a long recording.

A new speaker every sentence makes the joined recordings harsher than a talk:
Parakeet v3 on FluidAudio, which is not cut this way, scored 10.1% on one of
the English ones. The table is for comparing lengths, not for quoting as
accuracy. The raw reports are in `Private/ggml-pieces-2026-10-22b/` (the
September lengths, measured with the earlier cutter, in
`Private/ggml-pieces-2026-09-17/`).

Its xcframework is dynamic, unlike FluidAudio's static dependency, so
`CTranscribe.framework` ships beside `build/speech` and whoever embeds one
embeds both - along with `speech-catalog/`, the built-in model catalog, which
`speech` refuses to start without (docs/catalog.md).

## `mlx.*` - mlx-audio-swift 0.1.3 on mlx-swift 0.31.6, Metal, in another process

Safetensors checkpoints from mlx-community on Hugging Face, run through
`speech-mlx`: a separate binary that turns PCM into spans and does nothing
else. It does not reach the network, decode a container, read a manifest or
know that a catalog exists, because `speech` already has all of that.

The out-of-process split is the distinguishing property and it is not tidiness.
mlx-swift compiles its Metal kernels into a resource bundle that has to travel
beside the binary, mlx-audio-swift pulls in four more packages directly and
fourteen once resolved, and the API has changed shape more than once. Behind a
protocol of four requests, all of that churn moves inside a binary this tool can
also ship without. See
[docs/mlx-helper.md](mlx-helper.md) for the wire format; the test suite parses
and re-encodes the examples in it, so an example that stops being true fails the
build.

That makes this the only optional engine. `./build-speech-mlx.sh` builds the
helper, `./build.sh` does not, and nothing in the helper is on the main binary's
dependency graph. A build with no `speech-mlx` beside it still registers the
prefix and still lists the rows: it reports `unavailable` with a reason naming
where it looked and how to build what it did not find, rather than the "no engine
'mlx' in this build" that a missing compile-time target produces, which would
send the reader to the wrong problem. `SPEECH_MLX_BIN` overrides the location.

Five rows: two Parakeet sizes, Qwen3-ASR 1.7B at two quantizations, and Whisper
large-v3-turbo. All batch only, with segment timestamps and a language hint;
every row but the English-only `parakeet-tdt_ctc-110m` also identifies the
language on its own. No row here streams, none reports word timings, and none
accepts a custom vocabulary.

Memory is the third shape in this catalog. `peak_memory_bytes` for an `mlx` row
is this process plus the helper's own peak footprint, because both are resident
at once and the model is in the second one. Every twin landed between 3.0 and
4.1 GB whatever the model was, so the premium over the equivalent `ggml` row is
largest where the model is smallest: Parakeet v3 pays 0.98 to 1.00 GB through
ggml against 3.93 GB here, near four times, while Qwen3-ASR 1.7B at 8 bits
moves only from 3.67 to between 3.89 and 4.08 GB. The Parakeet twins agreed on
accuracy to within four hundredths of a point across English, Polish and
German.

That is the fact worth carrying away: no `mlx` row beat its `ggml` twin on both
accuracy and memory, and the one place MLX won anything was German on Whisper
turbo, 4.54 against 5.07, bought with a third of the speed and three times the
memory. The rows are here as an instrument, not as a recommendation.

Installing a Qwen3-ASR row is not quite finished when the download is. Loading
one synthesizes a `tokenizer.json` from `vocab.json` and `merges.txt` when the
repository ships none, which is the normal case for those repositories, and
writes it into the model directory. So the row grows a file after it was
installed, and a read-only model store fails the load rather than the download.

### `seg_ts` means something different here per family

The helper reports whether a row's timings came from the model or from the
helper covering the buffer with one span, and that distinction does not survive
into the capability flag. Parakeet returns real spans from its own alignment.
Whisper and Qwen3-ASR return one span per decoding chunk instead: a window
Whisper fixes at 30 seconds internally, and for Qwen3-ASR the `chunk_seconds`
this build sends, which is also 30 today. Either way that is the same field as
Parakeet's sentence-level alignment carrying a very different thing. Read
`seg_ts` on an `mlx` row as "the model said", not as "finely".

### Every row carries an audio ceiling, and it is not a tuning knob

MLX Audio defaults to 1200 second decoding chunks, and its issue #248 reports
that default building a roughly 7 GB KV cache and hanging a 108 minute file on a
48 GB machine. `speech` hands the helper bounded buffers and states how they may
be cut. The cost of not doing so was measured rather than assumed: one whole
recording in a single request took `mlx.parakeet-tdt-0.6b-v3` to 21.91 GB at
41.9x, against 4.55 GB at 153.4x with the 120 second ceiling that row carried
at the time.

A ceiling that fits in memory can still be too long to transcribe, the same way
the `ggml` pieces above are. The Parakeet rows were measured on the same corpora
on 2026-09-17 and now get 30 and 15 seconds instead of 120:

| pieces | `parakeet-tdt-0.6b-v3` en | pl | `parakeet-tdt_ctc-110m` en |
| --- | --- | --- | --- |
| one sentence at a time | 5.18% | 8.36% | 8.34% |
| 15 s | 11.00% | 9.27% | **13.37%** |
| 30 s | **8.94%** | **9.14%** | 20.28% |
| 60 s | 22.27% | 10.96% | - |
| 120 s | 37.55% | 12.91% | 22.64% |

English at 120 seconds deleted 908 words of about 2,400, which is how this
shows up on a real recording: a transcript that reads well and is missing
stretches. A 1 h 45 min talk came out 15,874 words at 120 seconds with a
56-second stretch absent, and 16,032 words with no gap over 10 seconds at 30 -
the `ggml` build of the same checkpoint, at 30 seconds, wrote 16,036. It was
also the fastest length on the corpus, and peak memory did not move.

Whisper windows its own input at 30 seconds and Qwen3-ASR decodes in 30-second
chunks, so their 300 second ceilings do not carry this risk, and the same talk
says so: Qwen3-ASR wrote 16,083 words and Whisper 14,765, Whisper's shortfall
spread evenly over every five-minute window rather than collected in gaps,
which is Whisper leaving out the "um" and "uh" the other two write down. The
reports are in `Private/mlx-pieces-2026-09-17/`.

## Deployment floor

Both libraries would run lower - FluidAudio declares macOS 14 and transcribe.cpp
macOS 13 - but the binary's deployment target is macOS 15, set by
`fluid.canary-1b-v2@int4`, whose int4 weight payloads need CoreML's macOS 15
runtime and which has no other published precision. Unlisting that row did not
lower the floor: its engine is still compiled in and still loads an installed
copy, so the runtime requirement is still in the binary.

A build without those targets simply has no `fluid` or `ggml` entry in the
engine registry and reports `unavailable` for those ids, rather than failing to
link. That is what lets one engine land at a time.

`speech-mlx` is built separately and carries the same macOS 15 target, but it is
absent rather than unregistered when it was not built: the `mlx` rows stay in the
catalog and report why they cannot run. It also does not travel alone - like
`CTranscribe.framework` beside `build/speech`, mlx-swift's Metal resource bundles
have to sit beside the helper, and a copy of the binary on its own aborts at
startup.

## Choosing between them

`speech engines` lists what a build carries and whether it can run here.
`speech catalog` adds where each row's weights come from, how big they are and
whether they are installed. Neither has an opinion about any of it, and that is
deliberate: which row to use depends on the language, the recording and the
machine, and the measurements that would settle it are only valid for the
machine, the OS and the dependency versions they were taken on.

Speech.app makes that choice, and can re-measure locally with `speech eval` -
against the standard corpora or against the user's own recordings. See
[docs/catalog.md](catalog.md) for what this tool reports and why the ranking is
not part of it.
