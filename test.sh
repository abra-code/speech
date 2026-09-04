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
expect_grep_err "not implemented yet" "$SPEECH" catalog
expect_code 2 "$SPEECH" catalog

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

echo "== decode =="
expect_ok "$SPEECH" decode "$TMP/fox.aiff" --output "$TMP/fox.wav"
if [ ! -s "$TMP/fox.wav" ]; then fail "decode produced no wav"; fi
# A container AVFoundation will not open must name the extension in the error.
: > "$TMP/bogus.webm"
expect_code 1 "$SPEECH" decode "$TMP/bogus.webm" --output "$TMP/bogus.wav"
expect_grep_err "webm" "$SPEECH" decode "$TMP/bogus.webm" --output "$TMP/bogus.wav"

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
