#!/bin/sh
# fetch-librispeech.sh - download LibriSpeech test splits and write a manifest
# for each.
#
# Usage:
#   tools/fetch-librispeech.sh                  # test-clean and test-other
#   tools/fetch-librispeech.sh test-other
#   SPEECH_CORPUS_DIR=~/Corpora tools/fetch-librispeech.sh test-clean
#
# LibriSpeech (openslr.org/12, CC-BY-4.0, no account needed) is the English
# benchmark model cards quote. test-clean and test-other are about 350 MB each
# and are downloaded, checked against openslr's published md5, and unpacked
# into $SPEECH_CORPUS_DIR/LibriSpeech/<split>, the layout the archives
# themselves use. Any other split (dev-clean, ...) is not downloaded - the
# training splits run to tens of gigabytes - but one unpacked there by hand
# still gets a manifest.
#
# Each split holds <speaker>/<chapter>/*.flac beside one
# <speaker>-<chapter>.trans.txt whose lines are "<utt-id> <REFERENCE>". Rows
# join the two and carry en-US, because LibriSpeech is English-only.
#
# The manifest is sorted by path, which is by utterance id, so --limit N
# selects the same rows for every engine. It is written via .part files and
# renamed into place, so an interrupted run never leaves a truncated manifest
# behind. The audio is unpacked beside its final place and moved in, for the
# same reason: the split directory existing is what stops a refetch.
#
# SPEECH_LIBRISPEECH_URL replaces the download base, for an openslr mirror
# (https://us.openslr.org/resources/12, https://openslr.elda.org/resources/12).
# Mirrors carry the same files, so the checksum still applies.
# SPEECH_LIBRISPEECH_MD5 replaces the checksum for every split named. It exists
# for tools/test-fetch-librispeech.sh, which serves a synthetic archive; do not
# set it for a real download.
#
# No `set -e`, by standing rule: it cascades into subshells and `|| true` just to
# call a tool normally, and when it does fire it aborts with nothing useful said.
# Every fallible operation below is checked explicitly and reports what failed.
#
# External tools are called by absolute path: this may run under a restricted
# PATH or from a host application that sets none.

corpus_dir="${SPEECH_CORPUS_DIR:-$HOME/Corpora}"
ls_dir="$corpus_dir/LibriSpeech"
base="${SPEECH_LIBRISPEECH_URL:-https://www.openslr.org/resources/12}"

if [ $# -eq 0 ]; then
    set -- test-clean test-other
fi

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

for split in "$@"; do
    # A shape test rather than a blocklist, because the value becomes a path
    # component under $ls_dir and part of the download URL.
    case "$split" in
        ""|*[!a-z0-9-]*)
            fail "'$split' is not a LibriSpeech split name" \
                 "expected lowercase letters, digits and hyphens, for example test-clean"
            continue
            ;;
    esac

    # From https://www.openslr.org/resources/12/md5sum.txt.
    md5=""
    case "$split" in
        test-clean) md5="32fa31d27d2e1cad72775fee3f4849a9" ;;
        test-other) md5="fb5a50374b501bb3bac4815ee91d3135" ;;
    esac
    if [ -n "$md5" ] && [ -n "${SPEECH_LIBRISPEECH_MD5:-}" ]; then
        md5="$SPEECH_LIBRISPEECH_MD5"
    fi

    dest="$ls_dir/$split"
    echo "== $split -> $dest"

    if [ ! -d "$dest" ]; then
        if [ -z "$md5" ]; then
            fail "no directory $dest" \
                 "only test-clean and test-other are downloaded; unpack $split from https://www.openslr.org/12/ under $ls_dir by hand"
            continue
        fi

        /bin/mkdir -p "$ls_dir"
        status=$?
        if [ "$status" -ne 0 ]; then
            fail "could not create $ls_dir" "check permissions on $corpus_dir"
            continue
        fi

        # An archive already on disk is checked before anything is fetched: a
        # run killed between the download and the unpack leaves a complete one,
        # and resuming a complete file is a range request the server refuses.
        archive="$ls_dir/$split.tar.gz"
        got=""
        if [ -s "$archive" ]; then
            got="$(/sbin/md5 -q "$archive")"
        fi
        if [ "$got" != "$md5" ]; then
            echo "-- $split.tar.gz (about 350 MB)"
            /usr/bin/curl -fL -C - -o "$archive" "$base/$split.tar.gz"
            status=$?
            if [ "$status" -ne 0 ]; then
                # The partial archive is kept: curl -C - resumes it next time.
                fail "could not download $split (curl $status)" \
                     "re-run to resume the partial download, or delete $archive to start over"
                continue
            fi
            got="$(/sbin/md5 -q "$archive")"
            status=$?
            if [ "$status" -ne 0 ] || [ "$got" != "$md5" ]; then
                /bin/rm -f "$archive"
                fail "$split.tar.gz failed its checksum (md5 '$got', expected $md5)" \
                     "the download was corrupted or truncated and has been deleted; re-run to fetch it again"
                continue
            fi
        fi

        # The archive unpacks to LibriSpeech/<split>/... plus the corpus-wide
        # LibriSpeech/*.TXT files (license, speakers, chapters, books).
        unpack="$ls_dir/.unpack-$split"
        /bin/rm -rf "$unpack"
        /bin/mkdir -p "$unpack"
        status=$?
        if [ "$status" -ne 0 ]; then
            fail "could not create $unpack" "check permissions on $ls_dir"
            continue
        fi
        echo "-- unpacking"
        /usr/bin/tar -xzf "$archive" -C "$unpack"
        status=$?
        if [ "$status" -ne 0 ]; then
            # The archive is kept: it matched the published checksum a moment
            # ago, so tar failed on the disk, not on the download. The next run
            # finds it, checks it again and unpacks without fetching.
            /bin/rm -rf "$unpack"
            fail "could not unpack $split (tar $status)" \
                 "check disk space and permissions on $ls_dir and re-run; the verified $archive is kept, or delete it to fetch again"
            continue
        fi
        if [ ! -d "$unpack/LibriSpeech/$split" ]; then
            /bin/rm -rf "$unpack"
            fail "$split.tar.gz holds no LibriSpeech/$split directory" \
                 "check that $base/$split.tar.gz is the LibriSpeech archive; $archive is kept for inspection"
            continue
        fi
        /bin/mv "$unpack/LibriSpeech/$split" "$dest"
        status=$?
        if [ "$status" -ne 0 ]; then
            /bin/rm -rf "$unpack"
            fail "could not move the unpacked audio into $dest" "check permissions on $ls_dir"
            continue
        fi
        # The corpus-wide files are the same in every archive, so the first
        # split to arrive supplies them. Missing them costs nothing here.
        for text in "$unpack"/LibriSpeech/*.TXT; do
            if [ -f "$text" ] && [ ! -e "$ls_dir/${text##*/}" ]; then
                /bin/mv "$text" "$ls_dir/"
                status=$?
                if [ "$status" -ne 0 ]; then
                    echo "   note: could not keep ${text##*/} in $ls_dir" >&2
                fi
            fi
        done
        /bin/rm -rf "$unpack"
        /bin/rm -f "$archive"
    fi

    # printf, not `:`, to create the files: `:` is a POSIX special builtin, and
    # a redirection error on one ends a non-interactive /bin/sh on the spot,
    # before the status check below can say anything. printf is a regular
    # builtin, so the failure comes back as a status like any other command's.
    part="$dest/manifest.tsv.part"
    printf '' > "$part"
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "could not write $part" "check permissions on $dest"
        continue
    fi
    err="$dest/manifest.tsv.err"
    printf '' > "$err"
    status=$?
    if [ "$status" -ne 0 ]; then
        /bin/rm -f "$part"
        fail "could not write $err" "check permissions on $dest"
        continue
    fi

    # One awk per .trans.txt, appending rows; missing audio is reported on
    # stderr into $err rather than counted in a shell variable, because the
    # while loop runs in a pipeline subshell whose variables are lost to the
    # parent. LC_ALL=C so the traversal order is deterministic everywhere.
    /usr/bin/find "$dest" -name '*.trans.txt' -print | LC_ALL=C /usr/bin/sort | while IFS= read -r trans; do
        dir="$(/usr/bin/dirname "$trans")"
        /usr/bin/awk -v dir="$dir" '
            NF >= 2 {
                uid = $1
                $1 = ""
                sub(/^ /, "")
                if ($0 == "") next
                path = dir "/" uid ".flac"
                if ((getline line < path) >= 0) {
                    close(path)
                    printf "%s\t%s\ten-US\n", path, $0
                } else {
                    printf "missing audio for %s\n", path > "/dev/stderr"
                }
            }
        ' "$trans" >> "$part" 2>> "$err"
    done

    missing="$(/usr/bin/wc -l < "$err" | /usr/bin/tr -d ' ')"
    if [ -z "$missing" ]; then
        missing="?"
    fi
    /bin/rm -f "$err"

    # A global sort: the per-file appends arrive chapter by chapter, and the
    # manifest order is the run order - --limit N must select the same rows
    # for every engine. sort -o onto the same file is safe.
    LC_ALL=C /usr/bin/sort -o "$part" "$part"
    status=$?
    if [ "$status" -ne 0 ]; then
        /bin/rm -f "$part"
        fail "could not sort the manifest for $split" "check disk space on $dest"
        continue
    fi

    # A manifest with no rows means the split directory and its .trans.txt
    # files disagree about what is there. Publishing it would hand every later
    # run an empty corpus that looks downloaded, so it is a failure rather
    # than an empty file.
    if [ ! -s "$part" ]; then
        /bin/rm -f "$part"
        fail "no usable rows for $split - no .trans.txt entries with matching .flac files" \
             "check that $dest holds unpacked <speaker>/<chapter> directories, or delete it and re-run to fetch it cleanly"
        continue
    fi

    /bin/mv "$part" "$dest/manifest.tsv"
    status=$?
    if [ "$status" -ne 0 ]; then
        /bin/rm -f "$part"
        fail "could not write $dest/manifest.tsv" "check permissions on $dest"
        continue
    fi

    kept="$(/usr/bin/wc -l < "$dest/manifest.tsv" | /usr/bin/tr -d ' ')"
    if [ -z "$kept" ]; then
        kept="?"
    fi
    echo "-- $kept rows, $missing audio files missing"
    echo "-- manifest: $dest/manifest.tsv"
done

if [ "$failures" -gt 0 ]; then
    echo
    echo "$failures of $# split(s) failed; see the messages above." >&2
    exit 1
fi

echo
echo "Score one with:"
echo "  ./build/speech eval --model apple.transcriber --manifest $ls_dir/<split>/manifest.tsv --language en-US --limit 200 --report Private/eval"
