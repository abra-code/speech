#!/bin/sh
# test.sh - build speech, run the unit tests, then run CLI smoke tests over
# generated fixtures.
#
# Two layers on purpose. `swift test` covers the parts with arithmetic in them
# (the scorer, the cue builder, the wire format, the decoder), where a wrong
# answer is a number. The smoke tests below cover the parts that only exist at
# the process boundary: exit codes, which stream a thing is written to, whether
# --json really keeps stdout free of anything but JSONL. Those are the contract
# the applet's shell scripts depend on, and no unit test can see them.
#
# The speech fixtures are synthesized with `say`, so no audio is committed and
# no network is needed. The assertions are about structure, never about the
# exact words: what the recognizer returns is Apple's business and changes with
# the OS, while "two segments came out and both had a start time" is ours.

set -e

cd "$(dirname "$0")"

./build.sh

SPEECH="./build/speech"
TMP="Tests/tmp"

rm -rf "$TMP"
mkdir -p "$TMP"

# The built-in catalog only. A developer's own entries in Application Support
# would change `catalog --tsv` and fail the diff against the checked-in copy for
# a reason that has nothing to do with the build.
export SPEECH_CATALOG_DIR="$TMP/no-user-catalog"

# Failure counter in a file: an assertion may run inside a pipeline, and a
# pipeline stage is a subshell whose variable updates are lost to the parent.
FAILLOG="$TMP/.failures"
: > "$FAILLOG"
fail() { echo "FAIL: $*" >&2; echo x >> "$FAILLOG"; }

expect_ok()   { if ! "$@" >/dev/null 2>&1; then fail "expected success: $*"; fi; }
expect_code() {
    want="$1"; shift
    if "$@" >/dev/null 2>&1; then got=0; else got=$?; fi
    if [ "$got" != "$want" ]; then fail "expected exit $want, got $got: $*"; fi
}
expect_grep() {
    pat="$1"; shift
    if ! "$@" 2>/dev/null | grep -q -- "$pat"; then fail "expected /$pat/ on stdout from: $*"; fi
}
# Diagnostics go to stderr by design, so anything about an error message has to
# look there and nowhere else - checking stdout would pass by accident the day
# an error started being printed to the wrong stream.
expect_grep_err() {
    pat="$1"; shift
    if ! "$@" 2>&1 >/dev/null | grep -q -- "$pat"; then fail "expected /$pat/ on stderr from: $*"; fi
}
expect_nogrep() {
    pat="$1"; shift
    if "$@" 2>/dev/null | grep -q -- "$pat"; then fail "unexpected /$pat/ from: $*"; fi
}

# `plutil -lint` only understands property lists and rejects JSON outright, so
# the JSON check is a conversion to /dev/null: it parses the input and exits
# non-zero when it cannot.
json_ok() { plutil -convert json -o /dev/null -- - >/dev/null 2>&1; }
expect_json_file() {
    if ! json_ok < "$1"; then fail "not valid JSON: $1"; fi
}

echo "== swift test =="
swift test --scratch-path build

echo "== fixtures =="
# `say` is the only speech source that needs no network and no committed audio.
# en-US is the one locale macOS always has installed, so this works on a fresh
# machine without a download.
say -o "$TMP/fox.aiff" "The quick brown fox jumps over the lazy dog. Pack my box with liquor jugs."

echo "== basics =="
expect_grep "^speech " "$SPEECH" --version
expect_grep "Usage: speech" "$SPEECH" --help
expect_code 2 "$SPEECH" nonsense-verb
expect_code 2 "$SPEECH" --nonsense-flag
# A verb the plan defines but a later stage implements must say so, not 404.
expect_grep_err "not implemented yet" "$SPEECH" notices
expect_code 2 "$SPEECH" notices

echo "== catalog =="
expect_grep "ggml.canary-1b-v2@q8_0" "$SPEECH" catalog
"$SPEECH" --json catalog > "$TMP/catalog.json"
expect_json_file "$TMP/catalog.json"

# The inventory reports what a caller needs to build a model list: provenance,
# size, install state and what the loaded model says it can do. It does not
# rank or recommend - that decision needs measurements from the machine it will
# run on, and it belongs to Speech.app.
expect_grep "handy-computer/canary-1b-v2-gguf" "$SPEECH" --json catalog
expect_grep '"installed"' "$SPEECH" --json catalog
expect_code 2 "$SPEECH" catalog --language pl

if ! "$SPEECH" catalog --tsv > "$TMP/catalog.tsv"; then
    # Do not go on to diff against a truncated file: the second failure is
    # noisier than the first and buries the message that explains it.
    fail "catalog --tsv failed"
elif ! { grep -v '^#' docs/models.catalog.tsv > "$TMP/catalog.want"; \
         grep -v '^#' "$TMP/catalog.tsv" > "$TMP/catalog.got"; \
         diff -u "$TMP/catalog.want" "$TMP/catalog.got" > "$TMP/catalog.diff"; }; then
    sed -n '1,20p' "$TMP/catalog.diff"
    fail "docs/models.catalog.tsv is stale; regenerate it with: ./build.sh && build/speech catalog --tsv > docs/models.catalog.tsv"
fi

# --json promises stdout carries nothing but JSON. A TSV on the same stream
# would break every applet script that parses it.
expect_code 2 "$SPEECH" --json catalog --tsv

echo "== info and engines =="
expect_grep "apple.transcriber" "$SPEECH" engines
# The FluidAudio rows are listed whether or not their weights are downloaded:
# "available" is about this machine, not about the model store.
expect_grep "fluid.parakeet-v3@int8" "$SPEECH" engines
# Languages Apple has no engine for at all - the reason this row exists.
expect_grep " sl " "$SPEECH" engines
expect_grep "Models dir:" "$SPEECH" info
"$SPEECH" --json info > "$TMP/info.json"
expect_json_file "$TMP/info.json"

# The model store, exercised against an empty directory of its own so the test
# never touches the user's real downloads and never needs the network. The
# download path itself is not covered here: it is half a gigabyte over HTTP,
# which does not belong in a smoke suite.
echo "== models =="
MODELS="$TMP/models"
mkdir -p "$MODELS"

expect_grep "No models are installed" "$SPEECH" --models-dir "$MODELS" models list
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-v3@int8
expect_grep '"state":"missing"' \
    "$SPEECH" --json --models-dir "$MODELS" models status fluid.parakeet-v3@int8
# The path is reported even when nothing is installed: it is where the download
# would land, which is what an applet offering that download needs.
expect_grep '"path":' \
    "$SPEECH" --json --models-dir "$MODELS" models status fluid.parakeet-v3@int8

# Apple's assets are owned by the OS: no path, no size, and download refuses
# rather than pretending.
expect_grep "system_managed" "$SPEECH" --models-dir "$MODELS" models status apple.transcriber
expect_code 2 "$SPEECH" --models-dir "$MODELS" models download apple.transcriber

# A catalog id becomes a path, and in stage 3 ids come from a TSV rather than
# argv. Any component that could escape the store must be refused at parse,
# because `models delete` removes the directory an id names.
for bad in "fluid.../../../Documents" "fluid..." "fluid./etc/passwd"; do
    expect_code 2 "$SPEECH" --models-dir "$MODELS" models status "$bad"
    expect_code 2 "$SPEECH" --models-dir "$MODELS" models delete "$bad"
done
if [ -n "$(ls -A "$MODELS")" ]; then fail "a rejected catalog id created something in the store"; fi

# A typo in the variant must not read as a valid row.
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-v3@int9
# Nemotron's variant is a chunk tier, so the typo shape is different: a number
# that is a real FluidAudio tier this build does not ship (4480), and a number
# with the unit attached. Both have to be refused rather than downloaded.
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.nemotron-multilingual@4480
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.nemotron-multilingual@2240ms
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.nemotron-multilingual@2240
# A bare id is the default tier, not a rejection.
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.nemotron-multilingual
# Parakeet Unified carries two axes in one variant: the encoder export and,
# for the streaming one, its latency tier. A tier that does not exist and a
# second spelling of one that does must both be refused - the variant is a
# directory name in the store, so two spellings of one tier would be two
# half-downloads of the same 609 MB.
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-unified@stream-641
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-unified@stream-0640
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-unified@stream
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-unified@stream-640
# Deleting what was never installed is a no-op, not an error.
expect_ok "$SPEECH" --models-dir "$MODELS" models delete fluid.parakeet-v3@int8

# Every row `list` prints must also be addressable by `status` and `delete`.
# A row whose id does not even parse still exists on disk and still occupies
# space, and listing one that delete then refuses is the disagreement this
# guards against.
mkdir -p "$MODELS/fluid/@weird"
echo "occupying space" > "$MODELS/fluid/@weird/blob.bin"
expect_grep "unknown to this build" "$SPEECH" --models-dir "$MODELS" models list
expect_grep "unknown to this build" "$SPEECH" --models-dir "$MODELS" models status "fluid.@weird"
expect_ok "$SPEECH" --models-dir "$MODELS" models delete "fluid.@weird"
if [ -d "$MODELS/fluid/@weird" ]; then fail "delete left the row behind"; fi

# A half-finished download must never look installed, whatever is in the
# directory. The marker is the store's own, so this needs no real weights.
mkdir -p "$MODELS/fluid/parakeet-v3@int8"
touch "$MODELS/fluid/parakeet-v3@int8/.partial"
expect_grep "partial" "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-v3@int8
expect_code 3 "$SPEECH" --models-dir "$MODELS" transcribe --model fluid.parakeet-v3@int8 "$TMP/fox.aiff"
expect_ok "$SPEECH" --models-dir "$MODELS" models delete fluid.parakeet-v3@int8

# The same for a row whose weights sit three directories below the row itself:
# a check applied at the wrong level would call this installed.
mkdir -p "$MODELS/fluid/nemotron-multilingual@2240"
touch "$MODELS/fluid/nemotron-multilingual@2240/metadata.json"
touch "$MODELS/fluid/nemotron-multilingual@2240/tokenizer.json"
expect_grep "missing" \
    "$SPEECH" --models-dir "$MODELS" models status fluid.nemotron-multilingual@2240
expect_code 3 "$SPEECH" --models-dir "$MODELS" \
    transcribe --model fluid.nemotron-multilingual@2240 "$TMP/fox.aiff"
expect_ok "$SPEECH" --models-dir "$MODELS" models delete fluid.nemotron-multilingual@2240

# Canary's precisions: only int4 is published, and the other two have to say so
# rather than falling through to "unknown variant".
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.canary-1b-v2@fp16
expect_grep_err "only int4" "$SPEECH" --models-dir "$MODELS" models status fluid.canary-1b-v2@fp16
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.canary-1b-v2@int8
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.canary-1b-v2@int4

# The shape an interrupted Canary download leaves: every path FluidAudio checks
# for exists, and not one of the bundles has been filled. Their own
# `modelsExist` calls this installed; reporting that would clear the partial
# marker and turn a resumable download into a load failure much later.
CANARY="$MODELS/fluid/canary-1b-v2@int4"
mkdir -p "$CANARY"/{Preprocessor,Projection,EncoderInt4,DecoderInt4}.mlmodelc
: > "$CANARY/vocab.json"
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.canary-1b-v2@int4
expect_code 3 "$SPEECH" --models-dir "$MODELS" \
    transcribe --model fluid.canary-1b-v2@int4 "$TMP/fox.aiff"
expect_ok "$SPEECH" --models-dir "$MODELS" models delete fluid.canary-1b-v2@int4

# Parakeet Unified: both precisions are real rows, and its weights sit one
# directory below the row, so a check at the wrong level would call this
# installed. The bundle needs its manifest, which is what an interrupted fetch
# leaves out.
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-unified@int8
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-unified@fp16
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-unified@int4
UNIFIED="$MODELS/fluid/parakeet-unified@int8/parakeet-unified-en-0.6b"
mkdir -p "$UNIFIED/parakeet_unified_encoder_int8.mlmodelc"
mkdir -p "$UNIFIED/parakeet_unified_decoder.mlmodelc"
mkdir -p "$UNIFIED/parakeet_unified_joint_decision_single_step.mlmodelc"
: > "$UNIFIED/vocab.json"
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-unified@int8
expect_code 3 "$SPEECH" --models-dir "$MODELS" \
    transcribe --model fluid.parakeet-unified@int8 "$TMP/fox.aiff"
expect_ok "$SPEECH" --models-dir "$MODELS" models delete fluid.parakeet-unified@int8

# The CTC spotter is a store row like any other - downloadable, listable,
# deletable - but not a transcriber, and it has no variants.
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-ctc-110m
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-ctc-110m@int8
expect_code 2 "$SPEECH" --models-dir "$MODELS" \
    transcribe --model fluid.parakeet-ctc-110m "$TMP/fox.aiff"
# "not batch" used to be reported as "live-only", which is wrong for a row that
# is neither and sends the reader to `speech stream`, which refuses it too.
expect_grep_err "not a transcription engine" "$SPEECH" --models-dir "$MODELS" \
    transcribe --model fluid.parakeet-ctc-110m "$TMP/fox.aiff"

# The Silero detector is the second helper row, and the one whose files land
# two components below the row rather than one: the loader appends `Models` to
# what it is handed before the downloader appends the repo folder, so a check at
# either wrong level would call an empty row installed.
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.silero-vad
expect_code 2 "$SPEECH" --models-dir "$MODELS" models status fluid.silero-vad@v6
VAD="$MODELS/fluid/silero-vad/Models/silero-vad"
mkdir -p "$VAD/silero-vad-unified-256ms-v6.2.1.mlmodelc"
expect_grep "missing" "$SPEECH" --models-dir "$MODELS" models status fluid.silero-vad
: > "$VAD/silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin"
expect_grep "installed" "$SPEECH" --models-dir "$MODELS" models status fluid.silero-vad
expect_grep_err "not a transcription engine" "$SPEECH" --models-dir "$MODELS" \
    transcribe --model fluid.silero-vad "$TMP/fox.aiff"
expect_ok "$SPEECH" --models-dir "$MODELS" models delete fluid.silero-vad

# An engine with no vocabulary support warns and continues, rather than
# failing: the terms are a hint there, not a dependency. The opposite case -
# an engine that *does* support them, with the spotter row absent - needs a
# real model on disk to reach, so it is verified by hand rather than here.
printf 'Solanki\nKirchner\n' > "$TMP/vocab.txt"
expect_grep_err "cannot bias recognition" "$SPEECH" --models-dir "$MODELS" \
    transcribe --model apple.transcriber --vocab "$TMP/vocab.txt" "$TMP/fox.aiff"

# The marker outranks any file check for this row too. It matters most here:
# this is the only family whose install verifies by loading, so it is the only
# one that can leave a row marked partial while holding a complete download.
mkdir -p "$MODELS/fluid/parakeet-unified@int8"
touch "$MODELS/fluid/parakeet-unified@int8/.partial"
expect_grep "partial" "$SPEECH" --models-dir "$MODELS" models status fluid.parakeet-unified@int8
expect_code 3 "$SPEECH" --models-dir "$MODELS" \
    transcribe --model fluid.parakeet-unified@int8 "$TMP/fox.aiff"
expect_ok "$SPEECH" --models-dir "$MODELS" models delete fluid.parakeet-unified@int8

echo "== decode =="
expect_ok "$SPEECH" decode "$TMP/fox.aiff" --output "$TMP/fox.wav"
if [ ! -s "$TMP/fox.wav" ]; then fail "decode produced no wav"; fi
# A container AVFoundation will not open must name the extension in the error.
: > "$TMP/bogus.webm"
expect_code 1 "$SPEECH" decode "$TMP/bogus.webm" --output "$TMP/bogus.wav"
expect_grep_err "webm" "$SPEECH" decode "$TMP/bogus.webm" --output "$TMP/bogus.wav"

echo "== record =="
# Like stream below, nothing here opens the microphone. Each is a refusal that
# has to come before recording starts: after it, a refusal would cost a
# permission prompt and a lit microphone indicator for nothing.
expect_code 2 "$SPEECH" record                                   # no file
expect_code 2 "$SPEECH" record "$TMP/one.wav" "$TMP/two.wav"     # two files
expect_code 2 "$SPEECH" record "$TMP/take.mp3"                   # a format it cannot write
expect_grep_err "m4a" "$SPEECH" record "$TMP/take.mp3"
: > "$TMP/existing.wav"
expect_code 2 "$SPEECH" record "$TMP/existing.wav"               # would replace a file
expect_grep_err "overwrite" "$SPEECH" record "$TMP/existing.wav"
mkdir -p "$TMP/folder.wav"
expect_code 2 "$SPEECH" record "$TMP/folder.wav" --overwrite       # a directory is never replaced
expect_grep_err "directory" "$SPEECH" record "$TMP/folder.wav" --overwrite
expect_code 2 "$SPEECH" record "$TMP/no-such-directory/take.wav" # nowhere to write it
mkdir -p "$TMP/read-only"
chmod 555 "$TMP/read-only"
expect_code 2 "$SPEECH" record "$TMP/read-only/take.wav"         # somewhere it cannot write
expect_grep_err "cannot write" "$SPEECH" record "$TMP/read-only/take.wav"
chmod 755 "$TMP/read-only"
expect_code 2 "$SPEECH" record "$TMP/take.wav" --parent-pid 0
expect_ok "$SPEECH" record --help
expect_ok "$SPEECH" record --list-devices

echo "== stream =="
# Everything here stops short of opening the microphone: the tap needs hardware,
# a TCC grant, and somebody to speak into it. What is testable without all that
# is the argument contract the applet depends on, and every one of these is a
# refusal that must happen *before* a recording starts rather than after.
expect_code 2 "$SPEECH" stream                                        # no --model
expect_code 2 "$SPEECH" stream --model nope.model                     # unknown engine
expect_code 2 "$SPEECH" stream --model ggml.parakeet-tdt-0.6b-v3@q8_0 # batch-only row
expect_grep_err "no live mode" "$SPEECH" stream --model ggml.parakeet-tdt-0.6b-v3@q8_0
# Refining with the model that produced the text would just run it twice.
expect_code 2 "$SPEECH" stream --model apple.transcriber --refine apple.transcriber
# The CTC spotter is a store row, not a transcriber, so it cannot refine either.
expect_code 2 "$SPEECH" stream --model apple.transcriber --refine fluid.parakeet-ctc-110m
expect_code 2 "$SPEECH" stream --model apple.transcriber --parent-pid 0
expect_code 2 "$SPEECH" stream extra-argument --model apple.transcriber

# eval --live refuses the same way, before any model is loaded. The manifest
# has to exist for the run to reach the engine at all, so it is a throwaway one
# rather than the scored manifest built later inside the Apple block.
printf '%s\t%s\n' "nowhere.wav" "unused" > "$TMP/usage-manifest.tsv"
expect_code 2 "$SPEECH" eval --model ggml.parakeet-tdt-0.6b-v3@q8_0 \
    --manifest "$TMP/usage-manifest.tsv" --live
expect_grep_err "no live mode" "$SPEECH" eval --model ggml.parakeet-tdt-0.6b-v3@q8_0 \
    --manifest "$TMP/usage-manifest.tsv" --live
# --segment is the same shape of choice as --pace: live only, and a spelling
# that is not one of the two modes is a typo rather than the default. The vad
# mode needs a row on disk, so a machine without it gets a download instruction
# (exit 3) before any model is loaded, rather than a run segmented the old way.
expect_code 2 "$SPEECH" --models-dir "$MODELS" stream --model apple.transcriber --segment vader
expect_code 2 "$SPEECH" --models-dir "$MODELS" eval --model apple.transcriber \
    --manifest "$TMP/usage-manifest.tsv" --segment vad
expect_code 3 "$SPEECH" --models-dir "$MODELS" eval --model fluid.parakeet-v3@int8 \
    --manifest "$TMP/usage-manifest.tsv" --live --segment vad
expect_grep_err "silero-vad" "$SPEECH" --models-dir "$MODELS" eval \
    --model fluid.parakeet-v3@int8 --manifest "$TMP/usage-manifest.tsv" --live --segment vad

# --pace without --live is a typo, not a request: a batch eval has no clock to
# pace, so silently ignoring it would hide the mistake.
expect_code 2 "$SPEECH" eval --model apple.transcriber \
    --manifest "$TMP/usage-manifest.tsv" --pace 2
expect_code 2 "$SPEECH" eval --model apple.transcriber \
    --manifest "$TMP/usage-manifest.tsv" --live --pace 0
expect_code 2 "$SPEECH" eval --model apple.transcriber \
    --manifest "$TMP/usage-manifest.tsv" --live --pace nonsense

# --list-devices answers without touching the engine or the microphone, so it
# works in a sandbox that blocks CoreAudio (where the list is simply empty).
expect_ok "$SPEECH" stream --list-devices
"$SPEECH" --json stream --list-devices > "$TMP/devices.json" 2>/dev/null
expect_json_file "$TMP/devices.json"
expect_grep '"devices"' cat "$TMP/devices.json"

# The live rows have to be discoverable: the applet builds its live picker by
# filtering `engines` on this flag, and a row that cannot stream must not carry
# it. Pin the exact set rather than grepping for the word: a bare grep for
# "live" would pass with the flag on a ggml row and off both Apple ones, and
# `expect_nogrep` alone cannot tell "the flag is absent" from "the verb broke".
#
# When the remaining fluid rows gain live mode, this fails with a message
# naming everything else that has to move with it.
live_ids=$("$SPEECH" engines | awk '/ live|,live/ {print $1}' | sort | tr '\n' ' ')
want_live="apple.dictation apple.transcriber fluid.nemotron-multilingual@1120 fluid.nemotron-multilingual@2240 fluid.nemotron-multilingual@560 fluid.parakeet-unified@stream-1120 fluid.parakeet-unified@stream-2080 fluid.parakeet-unified@stream-320 fluid.parakeet-unified@stream-640 fluid.parakeet-v3@int4 fluid.parakeet-v3@int8 ggml.nemotron-3.5-asr-streaming-0.6b@q4_k_m ggml.nemotron-3.5-asr-streaming-0.6b@q8_0 ggml.parakeet-unified-en-0.6b@q8_0 "
if [ "$live_ids" != "$want_live" ]; then
    fail "the set of rows with the 'live' flag changed to [$live_ids].
    If that is intended, update in the same commit: docs/models.catalog.tsv
    (regenerate it), docs/live.md's 'What is not here yet' section, and this
    assertion."
fi

echo "== transcribe =="
expect_code 2 "$SPEECH" transcribe "$TMP/fox.aiff"                      # no --model
expect_code 2 "$SPEECH" transcribe "$TMP/fox.aiff" --model nope.model   # unknown engine
expect_code 1 "$SPEECH" transcribe "$TMP/absent.wav" --model apple.transcriber

# `engines` can report "available" while the Speech asset service is
# unreachable - inside a command sandbox, supportedLocales comes back empty with
# no error - and every engine test would then fail for a reason that has nothing
# to do with the code. Require at least one supported locale before running them.
apple_locales=$("$SPEECH" info 2>/dev/null | sed -n 's/.*supported (\([0-9]*\)).*/\1/p' | head -1)
# Match the column with a regex, not a fixed run of spaces: the id column is
# padded to the widest id, so adding a longer engine id (fluid.parakeet-v3@int8)
# silently turned this probe false and skipped every Apple test below it.
if "$SPEECH" engines | grep -qE "apple\.transcriber +available" \
    && [ -n "$apple_locales" ] && [ "$apple_locales" -gt 0 ]; then
    expect_grep "quick brown fox" \
        "$SPEECH" transcribe "$TMP/fox.aiff" --model apple.transcriber --language en-US

    # Under --json, stdout is JSONL and nothing else. Every line must parse.
    "$SPEECH" --json transcribe "$TMP/fox.aiff" --model apple.transcriber \
        --language en-US > "$TMP/events.jsonl" 2>/dev/null
    while IFS= read -r line; do
        printf '%s' "$line" | json_ok \
            || fail "not JSON on stdout under --json: $line"
    done < "$TMP/events.jsonl"
    expect_grep '"type":"engine.ready"' cat "$TMP/events.jsonl"
    expect_grep '"type":"segment.final"' cat "$TMP/events.jsonl"
    expect_grep '"type":"done"' cat "$TMP/events.jsonl"

    # Formats, and the round trip through export that the applet's Export
    # popup relies on so it never re-transcribes.
    expect_ok "$SPEECH" transcribe "$TMP/fox.aiff" --model apple.transcriber \
        --language en-US --format json --output "$TMP/fox.json"
    expect_json_file "$TMP/fox.json"
    expect_grep "00:00:0" "$SPEECH" export "$TMP/fox.json" --format srt
    expect_grep "^WEBVTT" "$SPEECH" export "$TMP/fox.json" --format vtt
    expect_grep "quick brown fox" "$SPEECH" export "$TMP/fox.json" --format txt

    # --log records the events whatever the output mode.
    rm -f "$TMP/run.log"
    expect_ok "$SPEECH" --log "$TMP/run.log" transcribe "$TMP/fox.aiff" \
        --model apple.transcriber --language en-US
    expect_grep '"type":"done"' cat "$TMP/run.log"

    # An eval run over a one-row manifest: the scorer, the decoder and the
    # engine wired together, plus the written report.
    printf '%s\t%s\n' "fox.aiff" \
        "The quick brown fox jumps over the lazy dog. Pack my box with liquor jugs." \
        > "$TMP/manifest.tsv"
    expect_ok "$SPEECH" eval --model apple.transcriber --manifest "$TMP/manifest.tsv" \
        --language en-US --report "$TMP/report"
    if [ ! -s "$TMP/report/summary.json" ]; then fail "eval wrote no summary.json"; fi
    if [ ! -s "$TMP/report/report.md" ]; then fail "eval wrote no report.md"; fi
    expect_grep '"wer"' cat "$TMP/report/summary.json"
    # A batch report must stay free of live keys: the applet and every
    # summary.json already on disk were written before live mode existed.
    expect_nogrep '"live"' cat "$TMP/report/summary.json"

    # The same manifest through the live path. --pace 1 because a latency
    # measured at any other speed is not one, and this file is only a few
    # seconds long.
    expect_ok "$SPEECH" eval --model apple.transcriber --manifest "$TMP/manifest.tsv" \
        --language en-US --live --report "$TMP/report-live"
    expect_grep '"trailing_words_lost"' cat "$TMP/report-live/summary.json"
    expect_grep "## Live" cat "$TMP/report-live/report.md"
    expect_grep "Time to first partial" cat "$TMP/report-live/report.md"
    # RTFx under pacing measures the harness, so the report must refuse to
    # print it as a number rather than invite the comparison.
    expect_nogrep "| RTFx | [0-9]" cat "$TMP/report-live/report.md"
else
    echo "WARNING: the Apple engines are unavailable or report no locales on this"
    echo "         machine - skipping the engine tests. They need macOS 26 or later,"
    echo "         and they need to run outside a sandbox that blocks the speech"
    echo "         asset service."
fi

# The MLX helper, only if it has been built. `speech` runs without it and
# `build.sh` does not produce it, so its absence is the normal case rather than
# a skipped test worth warning about. What is checked here is the process
# boundary and nothing else: no model is loaded, because a model is half a
# gigabyte and this suite needs neither the network nor the store.
if [ -x build/speech-mlx ]; then
    echo "== speech-mlx =="

    # The third-party notices that have to travel with this binary, checked
    # before anything that needs a GPU because a compliance artifact is not a
    # runtime property. The file has to be there on every machine that has the
    # helper, which is why this check is not nested under the one below: a
    # machine that received a prebuilt binary is exactly the machine where a
    # missing notices file is the compliance failure, and it is also what is
    # left after someone deletes the multi-gigabyte derived data and keeps
    # build/.
    if [ ! -f build/speech-mlx-THIRD-PARTY-NOTICES.txt ]; then
        fail "no build/speech-mlx-THIRD-PARTY-NOTICES.txt beside build/speech-mlx"
    elif [ -d Helpers/speech-mlx/build/SourcePackages/checkouts ]; then
        # Regenerated and compared rather than merely looked for: the failure
        # worth catching is a file that is present, non-empty and describing
        # the dependency graph of some earlier build. Same arguments as
        # build-speech-mlx.sh uses, or the comparison would fail on a
        # difference this suite introduced.
        if Helpers/speech-mlx/tools/generate-third-party-notices.sh \
                --bundles build --output "$TMP/notices.txt" > /dev/null; then
            cmp -s build/speech-mlx-THIRD-PARTY-NOTICES.txt "$TMP/notices.txt" \
                || fail "build/speech-mlx-THIRD-PARTY-NOTICES.txt does not match the resolved pins - re-run ./build-speech-mlx.sh"
        else
            fail "the third-party notices could not be generated"
        fi
    else
        # Said out loud, the way the GPU skip below is: a check that quietly
        # did not run reads exactly like a check that passed.
        echo "WARNING: no SPM checkouts, so the notices were not regenerated and compared."
    fi

    # The handshake, which is also the proof that this build can reach the GPU:
    # a helper that lost its Metal bundle dies here rather than mid-measurement.
    printf '{"op":"bye"}\n' | ./build/speech-mlx \
        > "$TMP/mlx-hello.jsonl" 2> "$TMP/mlx-hello.err"
    mlx_status=$?

    # An MLX process with no GPU access - a restrictive sandbox, some CI
    # containers - dies before it can say anything, with an NSRangeException
    # from MTLCopyAllDevices() returning an empty array. That is a property of
    # where this is running and not of the build, so it is reported and skipped
    # the way the Apple engines are, rather than counted as a failure. Any
    # other non-zero exit is a real one.
    # Both the exception name and the crash site, because the name alone is a
    # substring anything could contain: a real regression that happened to
    # raise an NSRangeException elsewhere would silently skip this whole block
    # instead of failing it.
    if [ "$mlx_status" != 0 ] && grep -q 'NSRangeException' "$TMP/mlx-hello.err" \
        && grep -qE 'MTLCopyAllDevices|mlx4core5metal6Device' "$TMP/mlx-hello.err"; then
        echo "WARNING: this process cannot reach the GPU (MTLCopyAllDevices returned"
        echo "         nothing), so speech-mlx cannot start - skipping its tests."
    elif [ "$mlx_status" != 0 ]; then
        fail "speech-mlx did not exit cleanly on bye (exit $mlx_status)"
    else
        expect_grep '"event":"ready"' head -1 "$TMP/mlx-hello.jsonl"
        expect_grep '"mlx_swift"' head -1 "$TMP/mlx-hello.jsonl"

        # The buffer-cache bound, which is the difference between a peak
        # footprint that means something and one that records how much MLX was
        # willing to keep. The default is asserted by value because that value
        # is what every recorded measurement was taken under, and the override
        # is exercised because an unread environment variable looks exactly
        # like a working one.
        # The comma matters: '"cache_mb":64' also matches 640 and 6400, and the
        # keys are sorted, so a value is always followed by one.
        expect_grep '"cache_mb":512,' head -1 "$TMP/mlx-hello.jsonl"
        printf '{"op":"bye"}\n' | SPEECH_MLX_CACHE_MB=64 ./build/speech-mlx \
            > "$TMP/mlx-cache.jsonl" 2>/dev/null \
            || fail "speech-mlx did not exit cleanly under SPEECH_MLX_CACHE_MB"
        expect_grep '"cache_mb":64,' head -1 "$TMP/mlx-cache.jsonl"


        # The response stream carries JSON and nothing else. This is the check
        # that earns its keep: MLX Audio prints to stdout while loading a model,
        # and without the descriptor rescue in the helper those lines land here.
        while IFS= read -r line; do
            printf '%s' "$line" | json_ok || fail "speech-mlx wrote a non-JSON line: $line"
        done < "$TMP/mlx-hello.jsonl"

        # Every request gets exactly one terminal reply, including the ones with
        # nothing to report.
        printf '{"op":"unload"}\n{"op":"bye"}\n' \
            | ./build/speech-mlx > "$TMP/mlx-unload.jsonl" 2>/dev/null
        expect_grep '"event":"ok"' cat "$TMP/mlx-unload.jsonl"

        # A transcribe whose byte count is not a whole number of samples is
        # refused, rather than transcribed with every sample after the first one
        # shifted. The frame here is complete - eight bytes really do follow - so
        # this exercises the arithmetic check and not the framing.
        printf '{"op":"transcribe","id":1,"samples":4,"bytes":8}\n12345678{"op":"bye"}\n' \
            | ./build/speech-mlx > "$TMP/mlx-short.jsonl" 2>/dev/null \
            || fail "speech-mlx exited non-zero on a well-framed bad request"
        expect_grep '"event":"error"' cat "$TMP/mlx-short.jsonl"
        expect_grep 'not 4 Float32 samples' cat "$TMP/mlx-short.jsonl"

        # And the same check with a sample count that cannot be multiplied.
        # A signed overflow is a trap in Swift, not a wrong answer, so
        # `samples * 4` written plainly would take the process down before any
        # guard could refuse the request.
        printf '{"op":"transcribe","id":9,"samples":9223372036854775807,"bytes":8}\n12345678{"op":"bye"}\n' \
            | ./build/speech-mlx > "$TMP/mlx-huge.jsonl" 2>/dev/null \
            || fail "speech-mlx died on an oversized sample count"
        expect_grep '"event":"error"' cat "$TMP/mlx-huge.jsonl"

        # A stream cut off inside a payload is reported, not treated as the end
        # of a conversation. Sixteen bytes are promised and six arrive.
        printf '{"op":"transcribe","id":2,"samples":4,"bytes":16}\nshort\n' \
            | ./build/speech-mlx > "$TMP/mlx-cut.jsonl" 2>/dev/null \
            && fail "speech-mlx exited 0 on a truncated frame"
        expect_grep 'ended mid-frame' cat "$TMP/mlx-cut.jsonl"

        # And the engine on this side of it. `engines` reports these rows as
        # available only because the helper is beside the binary; the same
        # command with the override pointed at nothing must report them
        # unavailable and say why, since that is what every machine without a
        # helper sees.
        # A leading space, not ".*available": "unavailable" contains
        # "available", so the loose pattern would pass either way round.
        expect_grep "mlx.parakeet-tdt_ctc-110m .* available " "$SPEECH" engines
        SPEECH_MLX_BIN=/nonexistent/speech-mlx "$SPEECH" engines > "$TMP/mlx-engines.txt" 2>&1
        expect_grep "mlx.parakeet-tdt_ctc-110m .* unavailable " cat "$TMP/mlx-engines.txt"
        expect_grep "SPEECH_MLX_BIN is set to /nonexistent/speech-mlx" cat "$TMP/mlx-engines.txt"

        # Exit 2 is "unavailable engine". It is 2 and not 3 ("model missing")
        # whether or not these weights happen to be downloaded on this machine,
        # because the helper is checked before the store - see MLXEngine.start.
        expect_code 2 env SPEECH_MLX_BIN=/nonexistent/speech-mlx \
            "$SPEECH" transcribe "$TMP/fox.aiff" --model mlx.parakeet-tdt_ctc-110m
        # And the one thing the notices check above cannot prove: that the
        # notices describe THIS binary. The generator compares the pins against
        # the checkouts, never against what was compiled - so a pin bump plus a
        # failed compile leaves an old helper beside fresh checkouts, and a
        # regeneration would make the two agree with each other and not with
        # the binary. The handshake reports the mlx-swift it was built against;
        # the notices name the version they were generated from.
        mlx_swift=$(sed -n 's/.*"mlx_swift":"\([^"]*\)".*/\1/p' "$TMP/mlx-hello.jsonl" | head -1)
        [ -n "$mlx_swift" ] || fail "the handshake did not report an mlx_swift version"
        expect_grep "mlx-swift $mlx_swift" cat build/speech-mlx-THIRD-PARTY-NOTICES.txt
    fi
fi

FAILURES=$(wc -l < "$FAILLOG" | tr -d ' ')
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES test(s) failed." >&2
    exit 1
fi
echo "All tests passed."
