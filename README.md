# speech

A macOS command-line tool for speech to text. One binary, one engine protocol,
one output format, whatever model is doing the work.

It is built to answer a question that cannot be answered by reading benchmarks:
for *your* language, on *your* Mac, with *your* recordings, which speech model
is actually worth the download? So the first thing it can do is measure - WER,
CER, real-time factor and peak memory against a reference corpus - and every
model it later offers has to earn its place against Apple's built-in engines,
which are free, already installed, and better than most people expect.

Stage 4 of the development plan. The Apple engines, the FluidAudio and
transcribe.cpp engines, the model store, the inventory, the scorer, the decoder,
the event protocol, the evaluation harness and live microphone capture are in
place. Live sessions for the non-Apple rows, voice-activity segmentation, the
MLX helper and Speech.app are the stages after this one.

## Build

    ./build.sh          # produces build/speech (arm64, ad-hoc signed)
    ./test.sh           # builds, runs the unit tests and the CLI smoke tests

Deployment target macOS 15, set by `fluid.canary-1b-v2@int4`: its int4 weight
payloads need CoreML's macOS 15 runtime and no other precision is published for
that model. Nothing else needs it - FluidAudio itself declares macOS 14 and has
no OS gate in any engine used here. The Apple engines need macOS 26, are weak
linked, and report why when they are unavailable. arm64 only: FluidAudio's sources use Float16, which is
unavailable on x86_64 macOS, and its CoreML pipelines want the Neural Engine in
any case.

One dependency, FluidAudio, pinned to 0.15.6. It brings the Parakeet, Canary and
Nemotron CoreML pipelines and fetches a binary xcframework at resolve time, so
the first build needs the network. Beyond it nothing here needs Python, ffmpeg or
a package manager; audio decoding is AVFoundation and the Apple engines are the
system's own frameworks.

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

Global options: `--json` (JSONL events on stdout, see `docs/protocol.md`),
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

Scoring normalizes to NFC, lowercases in the reference language's locale, and
replaces punctuation and symbols with spaces - keeping an apostrophe that sits
between two letters, and folding the typographic form onto the ASCII one, so
that a recognizer is not charged for its typography. Numbers are **not**
normalized, which is why the FLEURS tooling takes the spelled-out
`transcription` column.

Corpus WER is total edits over total reference words, not the mean of per-row
rates. A run that scored no rows exits 1 rather than reporting 0.00%.

## Engines

See `docs/engines.md` for the capability flags and `docs/catalog.md` for the
inventory; `speech catalog` prints it. Three engine families are compiled in:
the two Apple modules (`apple.transcriber`, `apple.dictation`; macOS 26 and
up), nine FluidAudio CoreML rows (`fluid.*`), and thirteen GGUF rows through
transcribe.cpp (`ggml.*`).

Live mode is documented in `docs/live.md` and today covers the two Apple rows;
`speech engines` marks every row that can stream with a `live` flag.

## License

Apache-2.0. See LICENSE.
