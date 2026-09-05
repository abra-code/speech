# The JSONL event protocol

`speech --json <verb> ...` writes one JSON object per line to stdout and nothing
else. Diagnostics go to stderr. This is the interface Speech.app's poller
reads, so it is a contract: a field may be added, but renaming or removing one
is a breaking change and has to move in step with `Sources/SpeechCore/Events.swift`
and the applet.

Two kinds of verb write to that stream, and they are not the same thing:

- **Streaming verbs** - `transcribe`, `eval`, and later `stream` and
  `models download` - emit a sequence of the events tabulated below, each with
  `type` and `t`.
- **Query verbs** - `info`, `engines`, and later `catalog` - emit exactly one
  JSON object: a document, on a single line, with no `type` and no `t`. They are
  questions with an answer, not runs with a history. A reader that switches on
  `type` should treat their absence as "this is the answer", not as a
  malformed event.

`export` has no third mode: under `--json` it requires `--output`, because its
whole product is a document that is not JSON, and writing srt into the event
stream would corrupt it.

`--help` prints usage text on stdout in both modes. It is a question about the
tool, asked before any run begins, and every unix tool answers it that way.

Without `--json` the tool behaves like a unix filter instead: the transcript
goes to stdout, everything else to stderr, so `speech transcribe x.m4a --model
apple.transcriber > x.txt` produces a clean file while the progress line still
shows in the terminal.

`--log <path>` appends the JSONL stream to a file **whatever the output mode is**,
which is how the applet keeps a record of a run it displayed as human text.

## Every event

Two fields are always present and come first in the type's definition:

| field | type | meaning |
| --- | --- | --- |
| `type` | string | the event kind, from the table below |
| `t` | number | seconds since the process started, monotonic |

Keys are sorted alphabetically on the wire. That is deliberate: `JSONEncoder`'s
natural order varies between runs of the same binary, which makes two logs
impossible to diff. Parse the JSON; do not pattern-match on key order.

Unknown fields must be ignored by readers, and unknown `type` values should be
skipped rather than treated as errors, so a newer `speech` can be dropped into
an older applet.

## Event kinds

| type | fields |
| --- | --- |
| `engine.ready` | `engine`, `model`, `capabilities`, `load_seconds`, `locale` |
| `model.progress` | `model`, `phase`, `fraction`, `bytes_done`, `bytes_total`, `file` |
| `model.installed` | `model`, `path`, `bytes` (the last two omitted when unknown) |
| `model.entry` | `model`, `state`, `path`, `bytes`, `bytes_are_lower_bound` (`path`/`bytes` omitted when there are none; the flag omitted when false) |
| `progress` | `fraction`, `audio_seconds_done`, `audio_seconds_total` |
| `segment.partial` | the Segment fields, flat |
| `segment.final` | the Segment fields, flat |
| `segment.refined` | the Segment fields, flat, plus `refined_by` |
| `warning` | `message`, `code` |
| `error` | `message`, `code` |
| `done` | `segments`, `audio_seconds`, `wall_seconds`, `rtfx`, `peak_rss_bytes`, `peak_memory_bytes`, `output` |
| `eval.row` | `index`, `path`, `reference`, `hypothesis`, `wer`, `cer`, `audio_seconds`, `wall_seconds` |
| `eval.summary` | `model`, `language`, `rows`, `wer`, `cer`, `audio_seconds`, `wall_seconds`, `rtfx`, `peak_rss_bytes`, `peak_memory_bytes`, `worst` |

`model.entry` is one row of `models list` or `models status`. Its `state` is one
of:

| state | meaning |
| --- | --- |
| `installed` | present and usable |
| `partial` | a download started and did not finish; resumable |
| `missing` | not usable. `bytes` may still be present and non-zero, which means files are on disk that do not make a working model - delete and download again |
| `system_managed` | the OS owns these weights (Apple's locale assets). No `path`, nothing to download or delete here |
| `unknown` | files are present but no engine in this build can judge or use them - a row left by an older build or a pin bump. Offer deletion, never transcription |

`bytes_are_lower_bound` means something under the row could not be read and the
size is a floor, not a total. A consumer showing the figure must qualify it -
deleting the row reclaims at least that much and possibly more.

`path` is reported even for a `missing` row, because it is where a download
would land, which is what a caller offering that download needs. `bytes` is
omitted rather than zero when there is nothing on disk, so "not downloaded"
stays distinguishable from "an empty download".

`model.progress.phase` is one of `listing`, `downloading`, `compiling`,
`installing`. `compiling` covers every "making the model usable" step that moves
no bytes - CoreML's first-run ANE compile, loading weights, a warm-up pass -
because those take seconds and silence there reads as a hang.

`engine.ready.locale` is the locale the engine actually resolved the requested
language to, when that is more specific than what was asked for: a bare `de`
reaches Apple's engines as `de_AT` and `es` as `es_US`. Omitted when the engine
has nothing more specific to report. A measurement that does not record which
asset produced it cannot be reproduced, so `speech eval` also writes it to
`summary.json` as `resolved_locales` and to `report.md`.

`model.installed` omits `path` and `bytes` for Apple's locale assets: the OS
installs them system-wide at no path this tool owns, and Apple publishes no
size. A zero there would be a measurement rather than a missing one.

`error.code` is one of `usage`, `unavailable`, `model_missing`,
`unsupported_format`, `unsupported_language`, `runtime`, and maps onto the exit
status: 0 success, 1 runtime error, 2 usage or unavailable engine, 3 model
missing.

## Segment

Segments are written flat, not nested under a payload key, so a reader that
understands segments can treat `segment.partial`, `segment.final` and
`segment.refined` identically.

| field | type | notes |
| --- | --- | --- |
| `id` | int | increases within a session; a `segment.refined` reuses the id of the `segment.final` it replaces |
| `start`, `end` | number | seconds from the start of the media |
| `text` | string | |
| `words` | array, optional | omitted entirely when the engine has no word timings, which is different from an empty array |
| `confidence` | number, optional | |
| `speaker` | int, optional | 1-based, present only when diarization ran |
| `language` | string, optional | detected or hinted primary subtag |

Each word is `{text, start, end, confidence?}`.

Optional fields are **omitted** rather than sent as `null`.

## Reading `eval.summary`

`wer` and `cer` are corpus-level: total edits over total reference units, never
the mean of the per-row rates, which would let a three-word utterance outvote a
fifty-word one.

Check `rows` before reading `wer`. A run in which every row was skipped reports
`rows: 0` with `wer: 0`, which is not a perfect score - it is no measurement.
`speech eval` exits 1 in that case rather than letting it be mistaken for one.

`wall_seconds` in `eval.row` and `eval.summary` covers transcription only. It
excludes decoding and scoring, which is the right measure for comparing two
engines and the wrong one for predicting how long a progress bar runs.

`peak_memory_bytes` is the memory number to compare two engines with: the
process's peak physical footprint plus the model the Neural Engine is holding
for it. Both halves come from one `TASK_VM_INFO` read, and both are stable -
five identical runs of `fluid.parakeet-v3@int8` reported the same Neural Engine
figure to the byte and footprints within 1 MB of each other.

On a kernel that does not report those ledgers, `peak_memory_bytes` falls back
to the resident peak and equals `peak_rss_bytes`. The event stream carries no
separate flag for that; the signal is the `--report` JSON, where
`peak_footprint_bytes` and `peak_neural_bytes` are absent together.

`peak_rss_bytes` is the whole process's peak resident size, kept because
published figures for other tools are RSS. **Do not rank engines by it.** It
counts clean file-backed pages, and whether a CoreML model's weight pages are
counted in our address space during the hand-off to the Neural Engine is the
system's decision, not ours. Three identical runs of
`fluid.parakeet-unified@fp16` measured 1.25 GB, 76 MB and 76 MB while
`peak_memory_bytes` sat at 1.29 GB in all three. The high figure tends to come
in the first run or two after a model goes cold, which is exactly the pattern
that makes it look like a real measurement.

The report written by `--report` carries the breakdown - `peak_footprint_bytes`
and `peak_neural_bytes` - plus baselines and deltas for both totals
(`peak_memory_baseline_bytes`, `peak_memory_delta_bytes`, and the `peak_rss_*`
equivalents), for the narrower question of what the model itself cost. The two
breakdown fields are absent together on a kernel that does not report the
ledgers; when they are missing, `peak_memory_bytes` has fallen back to the
resident peak and is subject to everything said about it above.
