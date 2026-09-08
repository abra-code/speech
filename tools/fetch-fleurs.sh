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

# No `set -e`, by standing rule: it cascades into subshells and `|| true` just to
# call a tool normally, and when it does fire it aborts with nothing useful said.
# Every fallible operation below is checked explicitly and reports what failed.
#
# The shape is the same everywhere: run the tool, test its status, say what went
# wrong and what to do about it, then move to the next language rather than to
# the next line. That last part is what `set -e` could not do here - it abandoned
# the languages still on the command line because one of them 404ed.
#
# External tools are called by absolute path: this may run under a restricted
# PATH or from a host application that sets none.

corpus_dir="${SPEECH_CORPUS_DIR:-$HOME/Corpora}"
base="https://huggingface.co/datasets/google/fleurs/resolve/main/data"

if [ $# -eq 0 ]; then
    echo "usage: tools/fetch-fleurs.sh <lang_dir>... (for example pl_pl en_us de_de)" >&2
    exit 1
fi

# A FLEURS directory name is <language>[_<script>]_<region>, and neither half of
# that is the tag a model wants:
#
#   pl_pl       -> pl-PL
#   pt_br       -> pt-BR      the region decides which Portuguese
#   es_419      -> es-419     a numeric region, kept as it is
#   cmn_hans_cn -> zh-CN      FLEURS uses ISO 639-3 where every model says zh
#   yue_hant_hk -> yue-HK     the script subtag is dropped
#
# Taking everything before the first underscore, which is what this script used
# to do, gets `cmn` - a tag no model in the catalog claims, because they all say
# `zh`. Measured on one row, and the three engine groups do three things:
#
#   ggml, mlx    refuse the run: "does not support 'cmn'". Loud, and safe.
#   the wildcard the fluid.nemotron rows report no language list, so
#   rows        `Capabilities.supports` is true for anything, no warning is
#               emitted at all, and `cmn` goes to the model to be decoded as
#               whatever it makes of it. This is the dangerous one: it writes a
#               WER into a report, and a bad Mandarin WER looks like a model
#               that is bad at Mandarin.
#   apple       resolves `cmn` to zh_CN, exactly as it resolves `zh-CN`.
#               `supportedLocale(equivalentTo:)` normalizes it. Only the
#               `language_unsupported` warning and the language written into
#               summary.json were wrong; the measurement itself was fine.
#
# `zh-CN` is right for all three, and silences the warning on the Apple rows.
#
# The region is worth keeping even where a model ignores it. `Language.match`
# inside the tool resolves a regional tag down to a bare one, but not the other
# way round with any certainty: a bare `pt` lands on whichever Portuguese the
# model happens to list first, while `pt-BR` lands on Brazilian because it says so.
#
# One thing a manifest cannot express, because the column is one value for all
# models: where two models spell the same language differently. Whisper says
# `jw` for Javanese, `tl` for Filipino and `no` for Norwegian, where the rest of
# the catalog says `jv`, `fil` and `nb`. (`tl` and `no` are the older ISO 639-1
# codes; `jw` is not one at all - ISO 639-1 Javanese is `jv` - it is Whisper's
# own spelling.) So the `jv-ID` this function produces is claimed by no row in
# the catalog, while the three Whisper rows that can actually transcribe
# Javanese all list `jw` and will not match it.
#
# tools/language-battery.py resolves a tag per model for exactly this reason -
# its `tag_for` mirrors this function, and its LANGUAGE_ALIASES table covers
# what a single column cannot. Keep the two in step. For a hand-run eval, pass
# --language yourself against a manifest with no language column.
language_tag() {
    # FLEURS directory names are lowercase ASCII. The case arms below are
    # ranges, and a range in a shell glob follows the collation of the ambient
    # locale rather than ASCII, so they are only a lowercase test for input that
    # is already lowercase.
    local primary="${1%%_*}"
    case "$primary" in
    cmn) primary=zh ;;
    esac

    local region="${1##*_}"
    if [ "$region" = "$1" ]; then
        region=""                       # no underscore at all
    else
        case "$region" in
        [a-z][a-z]) region="$(printf '%s' "$region" | /usr/bin/tr 'a-z' 'A-Z')" ;;
        [0-9][0-9][0-9]) ;;             # a UN M.49 area code, e.g. 419
        *) region="" ;;                 # a script or something unexpected
        esac
    fi

    if [ -n "$region" ]; then
        printf '%s-%s\n' "$primary" "$region"
    else
        printf '%s\n' "$primary"
    fi
}

failures=0

# Every failure path in this script is the same shape, so it is written once.
# Two arguments: what went wrong, and what to do about it. The second is the
# half that makes the message worth printing at all.
fail() {
    echo "-- $1" >&2
    if [ -n "${2:-}" ]; then
        echo "   $2" >&2
    fi
    failures=$((failures + 1))
}

for lang in "$@"; do
    dest="$corpus_dir/fleurs/$lang"
    echo "== $lang -> $dest"

    /bin/mkdir -p "$dest"
    if [ $? -ne 0 ]; then
        fail "could not create $dest - check permissions on $corpus_dir; skipping $lang"
        continue
    fi

    if [ ! -s "$dest/test.tsv" ]; then
        echo "-- test.tsv"
        # Into .part and then moved, so a failed or interrupted download cannot
        # leave a truncated test.tsv that the -s test above accepts next time.
        /usr/bin/curl -fL -C - -o "$dest/test.tsv.part" "$base/$lang/test.tsv"
        status=$?
        if [ "$status" -ne 0 ]; then
            /bin/rm -f "$dest/test.tsv.part"
            fail "could not download test.tsv for $lang (curl $status)" \
                 "check that '$lang' is a real FLEURS directory: $base/"
            continue
        fi
        /bin/mv "$dest/test.tsv.part" "$dest/test.tsv"
        if [ $? -ne 0 ]; then
            fail "could not write $dest/test.tsv" "check permissions on $dest"
            continue
        fi
    fi

    if [ ! -d "$dest/test" ]; then
        echo "-- test.tar.gz (this is a few hundred MB)"
        /usr/bin/curl -fL -C - -o "$dest/test.tar.gz" "$base/$lang/audio/test.tar.gz"
        status=$?
        if [ "$status" -ne 0 ]; then
            # The partial archive is kept: curl -C - resumes it next time.
            fail "could not download the audio for $lang (curl $status)" \
                 "re-run to resume the partial download, or delete $dest/test.tar.gz to start over"
            continue
        fi
        # Unpack beside the archive, then move into place, so an interrupted
        # untar never leaves a half-populated test/ that the next run skips.
        # This is the failure that most needs catching: `test/` existing is the
        # only thing that stops a refetch, so a half-unpacked one would be
        # permanent.
        /bin/rm -rf "$dest/.unpack"
        /bin/mkdir -p "$dest/.unpack"
        status=$?
        if [ "$status" -ne 0 ]; then
            fail "could not create $dest/.unpack" "check permissions on $dest"
            continue
        fi
        /usr/bin/tar -xzf "$dest/test.tar.gz" -C "$dest/.unpack"
        status=$?
        if [ "$status" -ne 0 ]; then
            /bin/rm -rf "$dest/.unpack"
            fail "could not unpack the audio for $lang (tar $status)" \
                 "the archive is probably truncated: delete $dest/test.tar.gz and re-run"
            continue
        fi
        if [ -d "$dest/.unpack/test" ]; then
            moved_from="$dest/.unpack/test"
        else
            moved_from="$dest/.unpack"
        fi
        /bin/mv "$moved_from" "$dest/test"
        if [ $? -ne 0 ]; then
            /bin/rm -rf "$dest/.unpack"
            fail "could not move the unpacked audio into place for $lang" \
                 "check permissions on $dest"
            continue
        fi
        /bin/rm -rf "$dest/.unpack"
        /bin/rm -f "$dest/test.tar.gz"
    fi

    # test.tsv has seven tab-separated columns and no header:
    #   1 id, 2 file_name, 3 raw_transcription, 4 transcription,
    #   5 char-tokenized, 6 num_samples, 7 gender
    # Rows whose audio file is missing from the archive are dropped with a
    # count, rather than left in to fail one at a time during a long eval run.
    # On its own line, not inline in the awk arguments. The status of a command
    # substitution used as a word of a simple command is discarded - the command
    # reports awk's status, not the substitution's - so there is nowhere to test
    # it, and awk would run with an empty tag. An empty third column parses as no
    # language at all, so every row would silently stop naming its own.
    tag="$(language_tag "$lang")"
    if [ -z "$tag" ]; then
        fail "could not derive a language tag for '$lang'" \
             "expected a FLEURS directory name such as pl_pl, pt_br or cmn_hans_cn"
        continue
    fi

    /usr/bin/awk -F'\t' -v dir="$dest/test" -v tag="$tag" '
        NF >= 4 && $2 != "" && $4 != "" {
            path = dir "/" $2
            if ((getline line < path) >= 0) {
                close(path)
                printf "%s\t%s\t%s\n", path, $4, tag
                kept++
            } else {
                missing++
            }
        }
        END {
            printf "-- %d rows, %d audio files missing\n", kept, missing > "/dev/stderr"
        }
    ' "$dest/test.tsv" > "$dest/manifest.tsv.part"
    status=$?
    if [ "$status" -ne 0 ]; then
        /bin/rm -f "$dest/manifest.tsv.part"
        fail "could not build a manifest for $lang (awk $status)" \
             "check that $dest/test.tsv is readable and tab-separated"
        continue
    fi

    # A manifest with no rows means test.tsv and test/ disagree about which
    # files exist. Publishing it would hand every later run an empty corpus that
    # looks downloaded, so it is a failure rather than an empty file.
    if [ ! -s "$dest/manifest.tsv.part" ]; then
        /bin/rm -f "$dest/manifest.tsv.part"
        fail "no usable rows for $lang - test.tsv and test/ disagree about which files exist" \
             "delete $dest and re-run to fetch it cleanly; the old manifest is untouched"
        continue
    fi

    /bin/mv "$dest/manifest.tsv.part" "$dest/manifest.tsv"
    if [ $? -ne 0 ]; then
        fail "could not write $dest/manifest.tsv" "check permissions on $dest"
        continue
    fi

    echo "-- manifest: $dest/manifest.tsv"
done

if [ "$failures" -gt 0 ]; then
    echo
    echo "$failures of $# language(s) failed; see the messages above." >&2
    exit 1
fi

echo
echo "Score one with:"
echo "  ./build/speech eval --model apple.dictation --manifest $corpus_dir/fleurs/<lang>/manifest.tsv --limit 200 --report Private/eval"
