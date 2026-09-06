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
want_live="apple.dictation apple.transcriber fluid.nemotron-multilingual@1120 fluid.nemotron-multilingual@2240 fluid.nemotron-multilingual@560 fluid.parakeet-v3@int4 fluid.parakeet-v3@int8 ggml.nemotron-3.5-asr-streaming-0.6b@q4_k_m ggml.nemotron-3.5-asr-streaming-0.6b@q8_0 ggml.parakeet-unified-en-0.6b@q8_0 "
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

FAILURES=$(wc -l < "$FAILLOG" | tr -d ' ')
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES test(s) failed." >&2
    exit 1
fi
echo "All tests passed."
