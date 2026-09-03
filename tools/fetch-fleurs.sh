#!/bin/sh
# fetch-fleurs.sh - download one FLEURS test split and write a manifest for it.
#
# Usage:
#   tools/fetch-fleurs.sh pl_pl
#   tools/fetch-fleurs.sh en_us de_de
#   SPEECH_CORPUS_DIR=~/Corpora tools/fetch-fleurs.sh pl_pl
#
# FLEURS (google/fleurs on Hugging Face, CC-BY-4.0, no authentication) is the
# only public set with references in the languages this product cares about, and
# it is the ranking corpus: it says which engines are worth measuring further.
# Own recordings decide what ships. See tools/make-manifest.sh for those.
#
# The reference column is column 4, `transcription`, not column 3
# `raw_transcription`. Column 4 spells numbers out as words, and the scorer
# deliberately does not normalize numbers, so scoring against column 3 would
# charge every engine for writing "21" where the reader said "twenty one".
#
# Downloads resume (curl -C -) and are skipped when the archive is already
# unpacked, so re-running after an interrupted 338 MB fetch costs nothing.

set -e

corpus_dir="${SPEECH_CORPUS_DIR:-$HOME/Corpora}"
base="https://huggingface.co/datasets/google/fleurs/resolve/main/data"

if [ $# -eq 0 ]; then
    echo "usage: tools/fetch-fleurs.sh <lang_dir>... (for example pl_pl en_us de_de)" >&2
    exit 1
fi

for lang in "$@"; do
    dest="$corpus_dir/fleurs/$lang"
    mkdir -p "$dest"
    echo "== $lang -> $dest"

    if [ ! -s "$dest/test.tsv" ]; then
        echo "-- test.tsv"
        curl -fL -C - -o "$dest/test.tsv.part" "$base/$lang/test.tsv"
        mv "$dest/test.tsv.part" "$dest/test.tsv"
    fi

    if [ ! -d "$dest/test" ]; then
        echo "-- test.tar.gz (this is a few hundred MB)"
        curl -fL -C - -o "$dest/test.tar.gz" "$base/$lang/audio/test.tar.gz"
        # Unpack beside the archive, then move into place, so an interrupted
        # untar never leaves a half-populated test/ that the next run skips.
        rm -rf "$dest/.unpack"
        mkdir -p "$dest/.unpack"
        tar -xzf "$dest/test.tar.gz" -C "$dest/.unpack"
        if [ -d "$dest/.unpack/test" ]; then
            mv "$dest/.unpack/test" "$dest/test"
        else
            mv "$dest/.unpack" "$dest/test"
        fi
        rm -rf "$dest/.unpack"
        rm -f "$dest/test.tar.gz"
    fi

    # test.tsv has seven tab-separated columns and no header:
    #   1 id, 2 file_name, 3 raw_transcription, 4 transcription,
    #   5 char-tokenized, 6 num_samples, 7 gender
    # Rows whose audio file is missing from the archive are dropped with a
    # count, rather than left in to fail one at a time during a long eval run.
    awk -F'\t' -v dir="$dest/test" -v lang="$lang" '
        NF >= 4 && $2 != "" && $4 != "" {
            path = dir "/" $2
            if ((getline line < path) >= 0) {
                close(path)
                printf "%s\t%s\t%s\n", path, $4, substr(lang, 1, index(lang, "_") - 1)
                kept++
            } else {
                missing++
            }
        }
        END {
            printf "-- %d rows, %d audio files missing\n", kept, missing > "/dev/stderr"
        }
    ' "$dest/test.tsv" > "$dest/manifest.tsv"

    echo "-- manifest: $dest/manifest.tsv"
done

echo
echo "Score one with:"
echo "  ./build/speech eval --model apple.dictation --manifest $corpus_dir/fleurs/<lang>/manifest.tsv --limit 200 --report Private/eval"
