#!/bin/sh
# test-fetch-librispeech.sh - offline sanity test for tools/fetch-librispeech.sh.
#
# Serves a synthetic LibriSpeech archive over a file:// URL, so nothing is
# downloaded and no corpus is needed. Covers the install, a re-run that must
# not fetch again, a checksum failure, a split that is not downloaded, and a
# bad split name. Prints PASS or FAIL per check and exits non-zero on any FAIL.
#
# No `set -e`, by standing rule; external tools by absolute path.

here="$(/usr/bin/dirname "$0")"
fetch="$here/fetch-librispeech.sh"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/fetch-librispeech-test.XXXXXX")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$work" ]; then
    echo "could not create a temporary directory" >&2
    exit 1
fi

failures=0
check() {
    # $1: description, $2: 0 if the check held
    if [ "$2" -eq 0 ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1" >&2
        failures=$((failures + 1))
    fi
}

# The fixture: one chapter, two utterances with audio (listed out of order) and
# one without, plus a corpus-wide text file the way the real archives carry one.
chapter="$work/src/LibriSpeech/test-clean/11/22"
/bin/mkdir -p "$chapter" "$work/srv"
printf 'fLaC' > "$chapter/11-22-0000.flac"
printf 'fLaC' > "$chapter/11-22-0001.flac"
printf '11-22-0001 SECOND LINE\n11-22-0000 FIRST  LINE\n11-22-0002 NO AUDIO\n' > "$chapter/11-22.trans.txt"
printf 'license\n' > "$work/src/LibriSpeech/LICENSE.TXT"
/usr/bin/tar -czf "$work/srv/test-clean.tar.gz" -C "$work/src" LibriSpeech
status=$?
if [ "$status" -ne 0 ]; then
    echo "could not build the fixture archive (tar $status)" >&2
    /bin/rm -rf "$work"
    exit 1
fi
good_md5="$(/sbin/md5 -q "$work/srv/test-clean.tar.gz")"

corpora="$work/corpora"
manifest="$corpora/LibriSpeech/test-clean/manifest.tsv"

# 1. Install: download, verify, unpack into place, build the manifest.
SPEECH_CORPUS_DIR="$corpora" SPEECH_LIBRISPEECH_URL="file://$work/srv" SPEECH_LIBRISPEECH_MD5="$good_md5" \
    "$fetch" test-clean > "$work/log1" 2>&1
check "install exits 0" "$?"
rows="$(/usr/bin/wc -l < "$manifest" | /usr/bin/tr -d ' ')"
[ "$rows" = "2" ]
check "manifest has the 2 rows with audio (got '$rows')" "$?"
first="$(/usr/bin/head -1 "$manifest")"
[ "$first" = "$corpora/LibriSpeech/test-clean/11/22/11-22-0000.flac	FIRST LINE	en-US" ]
check "rows are sorted, spaces collapsed, tagged en-US" "$?"
[ -f "$corpora/LibriSpeech/LICENSE.TXT" ]
check "corpus-wide LICENSE.TXT is kept" "$?"
[ ! -e "$corpora/LibriSpeech/test-clean.tar.gz" ] && [ ! -e "$corpora/LibriSpeech/.unpack-test-clean" ]
check "archive and unpack directory are cleaned up" "$?"

# 2. Re-run with the source gone: an installed split must not be fetched again.
/bin/mv "$work/srv/test-clean.tar.gz" "$work/test-clean.tar.gz.saved"
SPEECH_CORPUS_DIR="$corpora" SPEECH_LIBRISPEECH_URL="file://$work/srv" SPEECH_LIBRISPEECH_MD5="$good_md5" \
    "$fetch" test-clean > "$work/log2" 2>&1
check "re-run exits 0 without the source" "$?"
/bin/mv "$work/test-clean.tar.gz.saved" "$work/srv/test-clean.tar.gz"

# 3. Checksum mismatch: nothing installed, the bad archive deleted.
SPEECH_CORPUS_DIR="$work/corpora-bad" SPEECH_LIBRISPEECH_URL="file://$work/srv" \
    SPEECH_LIBRISPEECH_MD5="00000000000000000000000000000000" \
    "$fetch" test-clean > "$work/log3" 2>&1
[ "$?" -eq 1 ]
check "checksum mismatch exits 1" "$?"
[ ! -e "$work/corpora-bad/LibriSpeech/test-clean" ] && [ ! -e "$work/corpora-bad/LibriSpeech/test-clean.tar.gz" ]
check "checksum mismatch installs nothing and deletes the archive" "$?"
/usr/bin/grep -q "failed its checksum" "$work/log3"
check "checksum mismatch says so" "$?"

# 4. A split that is not downloaded, and 5. a name that is not a split.
SPEECH_CORPUS_DIR="$corpora" "$fetch" dev-clean > "$work/log4" 2>&1
[ "$?" -eq 1 ]
check "an absent split other than the two test splits exits 1" "$?"
/usr/bin/grep -q "only test-clean and test-other are downloaded" "$work/log4"
check "and says which splits are downloaded" "$?"
SPEECH_CORPUS_DIR="$corpora" "$fetch" '../x' > "$work/log5" 2>&1
[ "$?" -eq 1 ]
check "a bad split name exits 1" "$?"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed; logs kept in $work" >&2
    exit 1
fi
/bin/rm -rf "$work"
echo "all checks passed"
