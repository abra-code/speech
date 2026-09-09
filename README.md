# speech

A macOS command-line tool for speech to text. One binary, one engine protocol,
one output format, whatever model is doing the work.

It is built to answer a question that cannot be answered by reading benchmarks:
for *your* language, on *your* Mac, with *your* recordings, which speech model
is actually worth the download? So the first thing it can do is measure - WER,
CER, real-time factor and peak memory against a reference corpus - and every
model it later offers has to earn its place against Apple's built-in engines,
which are free, already installed, and better than most people expect.

Stage 4 of the development plan is complete. The Apple engines, the FluidAudio,
transcribe.cpp and MLX engines, the model store, the inventory, the scorer, the
decoder, the event protocol, the evaluation harness, live microphone capture,
live sessions for every row that can stream and voice-activity segmentation are
all in place. Speech.app is stage 5, and post-processing, diarization and release
are stage 6.

## Build

    ./build.sh              # produces build/speech (arm64, ad-hoc signed)
    ./test.sh               # builds, runs the unit tests and the CLI smoke tests
    ./build-speech-mlx.sh   # optional: produces build/speech-mlx, for the mlx.* rows

Deployment target macOS 15, still set by `fluid.canary-1b-v2@int4`: its int4
weight payloads need CoreML's macOS 15 runtime and no other precision is
published for that model. That row is no longer listed (see Engines below) but
its engine is still built and still runs from an id typed in full, so the floor
stays. Nothing else needs it - FluidAudio itself declares macOS 14 and has no OS
gate in any engine used here. The Apple engines need macOS 26, are weak
linked, and report why when they are unavailable. arm64 only: FluidAudio's sources use Float16, which is
unavailable on x86_64 macOS, and its CoreML pipelines want the Neural Engine in
any case.

Two dependencies: FluidAudio, pinned to 0.15.6, which brings the Parakeet, Canary
and Nemotron CoreML pipelines; and transcribe.cpp 0.2.3 as the `CTranscribe`
binary target. Both fetch at resolve time, so the first build needs the network.
Beyond them `build/speech` needs no Python, no ffmpeg and no package manager:
audio decoding is AVFoundation and the Apple engines are the system's own
frameworks. The measuring tools under `tools/` are Python, and the optional MLX
helper wants XcodeGen and Apple's Metal toolchain, but neither is on the path to
the binary.

The optional `speech-mlx` helper has its own pins - mlx-audio-swift 0.1.3 on
mlx-swift 0.31.6 - and its own project, deliberately off the main binary's
dependency graph. `speech` builds, tests and ships without it; the `mlx.*` rows
then report `unavailable` with a reason rather than disappearing.

## Usage

    speech <verb> [options] [arguments]

Diagnostics go to stderr; the transcript goes to stdout. Exit status is 0 on
success, 1 on a runtime error, 2 on a usage error or an engine that cannot run
here, and 3 when a model is not installed.

| Verb | Description |
| --- | --- |
| `info` | The machine, the models directory, engine availability, Apple locales supported and installed |
| `engines` | The engines in this build with their capability flags |
| `catalog` | Every way this build can run speech recognition, as text, JSON or TSV |
| `models install-locale <bcp47>` | Install Apple's speech assets for a locale |
| `models download/list/status/delete` | The model store |
| `transcribe <media>` | Transcribe an audio or video file to txt, srt, vtt or json |
| `stream` | Transcribe the microphone live, optionally refining each utterance with a second engine |
| `eval` | Score a model against a manifest: WER, CER, RTFx, peak memory |
| `export <json>` | Convert a saved transcript to another format without re-transcribing |
| `decode <media>` | Write the 16 kHz mono wav every engine would receive |

`notices` is defined by the plan and arrives in a later stage; it refuses with a
reason rather than pretending not to exist.

Global options: `--json` (JSONL events on stdout, see [docs/protocol.md](docs/protocol.md)),
`--models-dir <path>`, `--log <path>`, `--verbose`.

### Examples

    speech info
    speech models install-locale pl-PL
    speech transcribe interview.mov --model apple.transcriber --format srt -o interview.srt
    speech transcribe notes.m4a --model apple.dictation --language pl-PL
    speech stream --model apple.transcriber --language en-US
    speech stream --model apple.transcriber --refine apple.dictation --language en-US
    speech --json transcribe talk.mp3 --model apple.transcriber | jq -r 'select(.type=="segment.final").text'
    speech eval --model apple.dictation --manifest ~/Corpora/fleurs/pl_pl/manifest.tsv --limit 200 --report Private/eval

## Supported input

Anything AVFoundation opens: wav, aiff, caf, m4a, mp3, mov, mp4, m4v. A movie's
audio is decoded from all of its audio tracks, mixed down to 16 kHz mono. webm,
mkv, ogg and opus are reported as unsupported rather than half-handled.

Every engine is handed byte-identical audio, decoded once by AVFoundation. That
is what makes a WER comparison between two engines mean anything, and it is why
even the Apple engines - which would happily open the original file themselves -
are fed a wav written from the same samples.

## Measuring

A manifest is a UTF-8 TSV with no header:

    audio_path <TAB> reference_text [<TAB> language]

`tools/fetch-fleurs.sh pl_pl en_us de_de` downloads FLEURS test splits
(CC-BY-4.0, no account needed) and writes a manifest for each.
`tools/make-manifest.sh <folder>` pairs recordings with same-basename `.txt`
references. Public sets rank models; your own recordings decide.

`tools/language-battery.py` runs the whole matrix for one or more languages:
every transcriber row whose loaded model claims the language, against that
language's FLEURS split, resumable at the cell so a multi-day run survives being
interrupted. It picks the models from `speech catalog --json` rather than a
list, so a new catalog row joins the matrix by existing.

    tools/language-battery.py --list                 # the 102 FLEURS languages, and who claims each
    tools/language-battery.py --plan cs_cz uk_ua     # the cells, the downloads, the hours
    tools/language-battery.py --caffeinate --download cs_cz uk_ua

Scoring normalizes to NFC, lowercases in the reference language's locale, and
replaces punctuation and symbols with spaces - keeping an apostrophe that sits
between two letters, and folding the typographic form onto the ASCII one, so
that a recognizer is not charged for its typography. Numbers are **not**
normalized, which is why the FLEURS tooling takes the spelled-out
`transcription` column.

Corpus WER is total edits over total reference words, not the mean of per-row
rates. A run that scored no rows exits 1 rather than reporting 0.00%.

## Engines

See [docs/engines.md](docs/engines.md) for the capability flags and
[docs/catalog.md](docs/catalog.md) for the inventory; `speech catalog` prints it.
Four engine families: the two Apple modules (`apple.transcriber`,
`apple.dictation`; macOS 26 and up), thirteen FluidAudio CoreML rows (`fluid.*`),
thirteen GGUF rows through transcribe.cpp (`ggml.*`), and five MLX rows
(`mlx.*`). The first three are compiled in; the MLX rows run in a separate
`speech-mlx` process and are the one family a build can be missing, which
[docs/mlx-helper.md](docs/mlx-helper.md) specifies.

### One row is built but not listed

`fluid.canary-1b-v2@int4` is the fourteenth FluidAudio row. The engine is still
compiled in and an id typed in full still downloads, loads and transcribes, but
the row is absent from `speech catalog` and `speech engines` so that nothing
offers it. It was measured against `ggml.canary-1b-v2@q4_k_m`, which is the same
NVIDIA weights quantized to 4 bits as a GGUF, over the whole of FLEURS per
language:

| language | int4 WER | q4_k_m WER | int4 RTFx | q4_k_m RTFx |
| --- | --- | --- | --- | --- |
| de_de | 6.96 | 4.59 | 7.7 | 59.5 |
| en_us | 6.36 | 5.04 | 7.6 | 63.1 |
| es_419 | 6.03 | 3.10 | 5.4 | 49.8 |
| pl_pl | 11.77 | 7.19 | 6.0 | 49.3 |

Those are M5 figures, on the hardware where the conversion works. On M1 and M1
Pro the CoreML runtime fails to compile part of the graph for the Neural Engine
("ANECCompile() FAILED"), takes 85 minutes to give up, and then runs 88% of each
decoder step on a single BNNS thread: RTFx 3.7 and 3.4 GB of peak memory, where
the GGUF row measures 36.3 and 0.89 GB on the same machine. The two M1-class
machines produced byte-identical Neural Engine figures, so this is a property of
that ANE generation and that conversion, not of one Mac. FluidAudio labels the
conversion beta; if a later one fixes it, the row can come back.

Live mode is documented in [docs/live.md](docs/live.md) and covers fourteen rows
across three engines; `speech engines` marks every row that can stream with a
`live` flag.

## Documentation

| Document | What is in it |
| --- | --- |
| [docs/engines.md](docs/engines.md) | Every backend, its capability flags, what it costs and why it is shaped the way it is |
| [docs/catalog.md](docs/catalog.md) | What the model inventory reports, field by field, and why it ranks nothing |
| [docs/models.catalog.tsv](docs/models.catalog.tsv) | The inventory itself, exported from `speech catalog --tsv` and diffed by `test.sh`, which fails when it is stale |
| [docs/protocol.md](docs/protocol.md) | The `--json` event stream: every event kind and every field |
| [docs/live.md](docs/live.md) | How a live microphone session is driven, what each engine family demands of it, and how a run stops |
| [docs/mlx-helper.md](docs/mlx-helper.md) | The `speech-mlx` wire format, whose examples the test suite parses |

## License

Apache-2.0. See [LICENSE](LICENSE).
