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
expect_grep "Models dir:" "$SPEECH" info
"$SPEECH" --json info > "$TMP/info.json"
expect_json_file "$TMP/info.json"

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
if "$SPEECH" engines | grep -q "apple.transcriber  available" \
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
