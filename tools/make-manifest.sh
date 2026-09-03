#!/bin/sh
# make-manifest.sh - build a manifest from a folder of recordings.
#
# Usage:
#   tools/make-manifest.sh ~/Recordings/polish [language]
#
# Pairs every audio or video file with a same-basename .txt holding its
# reference transcript, and writes manifest.tsv into the folder. This is the
# corpus that decides what ships: FLEURS is read speech in a studio, and the
# question the product actually has to answer is what happens to your own
# dictation, your own meeting, your own accent, in your own room.
#
# Write the references by hand once, transcribing what was said rather than what
# should have been said - false starts and all - or the numbers measure the
# recording, not the recognizer.

set -e

folder="$1"
language="$2"

if [ -z "$folder" ] || [ ! -d "$folder" ]; then
    echo "usage: tools/make-manifest.sh <folder> [language]" >&2
    exit 1
fi

out="$folder/manifest.tsv"
: > "$out.part"

found=0
missing=0
for media in "$folder"/*; do
    # Extensions are matched case-insensitively. A camera writes IMG_1234.MOV
    # and many exporters write .M4A; skipping those silently and then reporting
    # "0 skipped" is the worst possible answer.
    lower=$(printf '%s' "$media" | LC_ALL=C tr 'A-Z' 'a-z')
    case "$lower" in
        *.wav|*.aiff|*.aif|*.caf|*.m4a|*.mp3|*.mov|*.mp4|*.m4v) ;;
        *) continue ;;
    esac
    base=$(basename "$media")
    reference="${media%.*}.txt"
    if [ ! -f "$reference" ]; then
        echo "-- no reference for $base" >&2
        missing=$((missing + 1))
        continue
    fi
    # A reference that is not UTF-8 would be truncated at the first bad byte by
    # the tr below, and the truncation would be invisible: the row still gets
    # written, just with half a sentence in it, and the WER it produces is
    # nonsense. Reject the file instead.
    if ! iconv -f UTF-8 -t UTF-8 < "$reference" > /dev/null 2>&1; then
        echo "-- reference for $base is not UTF-8; convert it first" >&2
        missing=$((missing + 1))
        continue
    fi
    # Collapse the reference to one line: the manifest is line-oriented, and a
    # hand-written .txt almost always has newlines in it. LC_ALL=C so tr works
    # on bytes and cannot fail part way through a multi-byte character.
    text=$(LC_ALL=C tr '\n\r\t' '   ' < "$reference" | sed 's/  */ /g; s/^ //; s/ $//')
    if [ -z "$text" ]; then
        echo "-- empty reference for $base" >&2
        missing=$((missing + 1))
        continue
    fi
    # The basename, not the path as given. `speech` resolves a relative manifest
    # entry against the manifest's own directory, which is this folder, so
    # writing "Recordings/a.wav" here would resolve to "Recordings/Recordings/a.wav"
    # whenever the script was invoked with a relative folder.
    if [ -n "$language" ]; then
        printf '%s\t%s\t%s\n' "$base" "$text" "$language" >> "$out.part"
    else
        printf '%s\t%s\n' "$base" "$text" >> "$out.part"
    fi
    found=$((found + 1))
done

mv "$out.part" "$out"
echo "$found rows written to $out ($missing skipped)"
