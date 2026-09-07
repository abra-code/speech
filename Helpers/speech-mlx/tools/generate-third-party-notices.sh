#!/bin/sh
# generate-third-party-notices.sh - collect the license texts of everything that
# is statically linked into, or shipped beside, build/speech-mlx.
#
# `speech` and `speech-mlx` are Apache 2.0; see LICENSE in the repository root.
# The helper executable is a static link of every package the resolution names,
# under MIT, Apache 2.0 and BSD terms, and several of those vendor third-party
# C and C++ of their own - mlx-swift's Cmlx target carries Apple's MLX, mlx-c,
# fmt, nlohmann/json, metal-cpp and pocketfft. It also ships resource bundles
# that travel beside the binary, one of them the compiled Metal shaders without
# which the helper aborts. Every one of those licenses requires its notice to
# accompany the binary form, so whatever ships `speech-mlx` ships this file next
# to it.
#
# The list is read from the resolved package graph and the SPM checkouts that
# build-speech-mlx.sh leaves in Helpers/speech-mlx/build, so it tracks the
# actual pins rather than a list maintained by hand. Anything that would make
# the output incomplete - a package with no license text, a checkout with no
# pin, checkouts that do not match the pins, a missing supplemental directory -
# is a hard error. A notices file that is quietly short is worse than no notices
# file at all, because it looks complete.
#
# WHAT THIS SEARCH CANNOT SEE, and what the supplemental directory is for: a
# license that exists only as a comment at the top of a source file. Four live
# cases, all inside mlx, all compiled in - small_vector.h (BSD-3, the V8
# project, included by array.h and so in every translation unit), pocketfft.h
# (BSD-3, included by both FFT backends), expm1f.h (BSD-2, Norbert Juffa) and
# cexpf.h (Apache 2.0, NVIDIA and Filipe RNC Maia), the last two compiled into
# the Metal library. All four are carried as supplementals. ACKNOWLEDGMENTS is
# searched for as well, because mlx's copy carries a PocketFFT section, but
# that text names an older copyright than the header of the code actually
# vendored, which is why the supplemental exists rather than a reliance on it.
#
# The lesson, for whoever moves a pin: a file-name search finds license FILES,
# and this graph's most-used third-party code does not have one. Grep the new
# sources for "Copyright" - `grep -rIl -i copyright --include='*.h'
# --include='*.hpp' --include='*.cpp' --include='*.metal'` over the checkouts -
# and read what it finds.
#
# Usage: Helpers/speech-mlx/tools/generate-third-party-notices.sh
#            [--checkouts DIR] [--resolved FILE] [--supplemental DIR]
#            [--bundles DIR] [--output FILE] [--allow-stale-checkouts]
#
# pipefail is deliberately not set: it is not POSIX, and on a shell where `set`
# rejects it the whole option string fails and -u would be lost with it.
set -u

HELPER_ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
CHECKOUTS="$HELPER_ROOT/build/SourcePackages/checkouts"
RESOLVED="$HELPER_ROOT/speech-mlx.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SUPPLEMENTAL="$HELPER_ROOT/tools/notices-supplemental"
BUNDLES=""
OUTPUT=""
ALLOW_STALE="no"

fail() { echo "generate-third-party-notices: $*" >&2; exit 1; }

# Every value-taking flag goes through this, because `--output` written last on
# the line leaves $1 empty after the shift, and an empty OUTPUT means "write to
# stdout" - so the one invocation most likely to be a typo would silently print
# the notices instead of installing them. Not a function that echoes the value:
# `fail` inside a command substitution kills the substitution and not the
# script, which is the same class of quiet failure this whole file exists to
# refuse.
require_value() { [ -n "${1:-}" ] || fail "$2 needs a value"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --checkouts=*)    CHECKOUTS="${1#*=}" ;;
        --checkouts)      shift; require_value "${1:-}" --checkouts; CHECKOUTS="$1" ;;
        --resolved=*)     RESOLVED="${1#*=}" ;;
        --resolved)       shift; require_value "${1:-}" --resolved; RESOLVED="$1" ;;
        --supplemental=*) SUPPLEMENTAL="${1#*=}" ;;
        --supplemental)   shift; require_value "${1:-}" --supplemental; SUPPLEMENTAL="$1" ;;
        --bundles=*)      BUNDLES="${1#*=}" ;;
        --bundles)        shift; require_value "${1:-}" --bundles; BUNDLES="$1" ;;
        --output=*)       OUTPUT="${1#*=}" ;;
        --output|-o)      shift; require_value "${1:-}" --output; OUTPUT="$1" ;;
        --allow-stale-checkouts) ALLOW_STALE="yes" ;;
        -h|--help)
            echo "Usage: $0 [--checkouts DIR] [--resolved FILE] [--supplemental DIR]"
            echo "          [--bundles DIR] [--output FILE] [--allow-stale-checkouts]"
            echo
            echo "--allow-stale-checkouts downgrades three fatal checks to warnings:"
            echo "  a checkout with no pin, a checkout whose revision does not match"
            echo "  its pin, and a missing workspace-state.json. All three mean the"
            echo "  output may not describe the binary beside it."
            exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
    shift
done

[ -f "$RESOLVED" ] || fail "No Package.resolved at $RESOLVED"
[ -d "$CHECKOUTS" ] || fail "No SPM checkouts at $CHECKOUTS - run ./build-speech-mlx.sh first, which is what populates them"
# The supplemental directory is the only carrier for notices that no checkout
# provides. Skipping it because a path was mistyped would silently drop a
# required notice, so its absence is fatal rather than a no-op.
[ -d "$SUPPLEMENTAL" ] || fail "No supplemental notices directory at $SUPPLEMENTAL - it carries the licenses that exist only as source-file headers"
[ -z "$OUTPUT" ] || [ ! -d "$OUTPUT" ] || fail "--output names a directory: $OUTPUT"

STATE="$(/usr/bin/dirname "$CHECKOUTS")/workspace-state.json"

_pins="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/notices-pins.XXXXXX")" || fail "mktemp failed"
_liclist="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/notices-lics.XXXXXX")" || fail "mktemp failed"
_state="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/notices-state.XXXXXX")" || fail "mktemp failed"
_licraw="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/notices-raw.XXXXXX")" || fail "mktemp failed"
_stage=""
trap '/bin/rm -f "$_pins" "$_liclist" "$_state" "$_licraw" ${_stage:+"$_stage"}' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT

# --- parse Package.resolved ------------------------------------------------
# SPM writes one key per line, so a line-oriented parser is enough. Every
# pattern requires a QUOTED value: Package.resolved v3 ends with a bare
# `"version" : 3` after the pins array, which an unguarded match would graft
# onto the last pin as its version.
/usr/bin/awk '
function qval(line,   n, s) {
    n = index(line, ":"); s = substr(line, n + 1)
    sub(/^[[:space:]]*"/, "", s); sub(/"[[:space:]]*,?[[:space:]]*$/, "", s)
    return s
}
function flush(   v) {
    if (id == "") return
    v = (ver != "") ? ver : ((rev != "") ? "rev " substr(rev, 1, 12) : "-")
    printf "%s\t%s\t%s\t%s\n", id, (loc != "" ? loc : "-"), v, rev
}
/"identity"[[:space:]]*:[[:space:]]*"/ { flush(); id = qval($0); loc = ""; ver = ""; rev = ""; next }
/"location"[[:space:]]*:[[:space:]]*"/ { loc = qval($0); next }
/"revision"[[:space:]]*:[[:space:]]*"/ { rev = qval($0); next }
/"version"[[:space:]]*:[[:space:]]*"/  { ver = qval($0); next }
END { flush() }
' "$RESOLVED" > "$_pins" || fail "Could not parse $RESOLVED"

# This compares the file against itself - awk emits one row per identity line
# and grep counts identity lines - so it detects a renamed or unquoted key, NOT
# a short or truncated file. The real backstops against under-reporting are the
# two checks below, which compare the pin list against what SPM actually put on
# disk.
_want=$(/usr/bin/grep -c '"identity"[[:space:]]*:' "$RESOLVED" | /usr/bin/tr -d " ")
_got=$(/usr/bin/wc -l < "$_pins" | /usr/bin/tr -d " ")
[ "${_got:-0}" -gt 0 ] || fail "Parsed no packages out of $RESOLVED - the format changed"
[ "$_got" = "$_want" ] || fail "Parsed $_got packages but $RESOLVED declares $_want - the format changed"

# Every checkout on disk must correspond to a pin. An unmatched one is either a
# stale leftover from a dropped dependency or - the case that matters - a
# package this file would not cover. Fatal by default: for a compliance
# artifact the safe direction is to stop, not to warn in the middle of a wall
# of build output. --allow-stale-checkouts is the escape hatch for a build
# directory that is merely stale.
_unpinned=""
for _c in "$CHECKOUTS"/*; do
    [ -d "$_c" ] || continue
    _cb=$(/usr/bin/basename "$_c")
    /usr/bin/awk -F'\t' -v n="$_cb" 'tolower($1)==tolower(n) { found=1 } END { exit !found }' "$_pins" \
        || _unpinned="$_unpinned $_cb"
done
if [ -n "$_unpinned" ]; then
    if [ "$ALLOW_STALE" = "yes" ]; then
        echo "generate-third-party-notices: WARNING: checkouts with no pin (not covered):$_unpinned" >&2
    else
        fail "Checkouts with no pin in $RESOLVED:$_unpinned
  Either they are stale (clean $CHECKOUTS, or re-resolve) or they are linked and
  this file would not cover them. Re-run with --allow-stale-checkouts once you
  know which."
    fi
fi

# And the pins must match the checkouts they are labeled with. The versions come
# from Package.resolved and the license texts from the checkouts, which are two
# sources that can disagree: pull a pin bump, run this without rebuilding, and
# every license set gets stamped with a version whose sources are not on disk -
# the "describes an older graph" failure, wearing the right version numbers.
# workspace-state.json is SPM's record of what it actually checked out.
if [ -f "$STATE" ]; then
    /usr/bin/awk '
    function qval(line,   n, s) {
        n = index(line, ":"); s = substr(line, n + 1)
        sub(/^[[:space:]]*"/, "", s); sub(/"[[:space:]]*,?[[:space:]]*$/, "", s)
        return s
    }
    /"identity"[[:space:]]*:[[:space:]]*"/ { id = qval($0); rev = ""; ver = ""; next }
    /"revision"[[:space:]]*:[[:space:]]*"/ { if (id != "" && rev == "") rev = qval($0); next }
    /"version"[[:space:]]*:[[:space:]]*"/  { if (id != "" && ver == "") ver = qval($0); next }
    /"subpath"[[:space:]]*:[[:space:]]*"/ {
        if (id != "") printf "%s\t%s\t%s\n", id, rev, ver
        id = ""; next
    }
    ' "$STATE" > "$_state" || fail "Could not parse $STATE"
    _skew=""
    while IFS="$(/usr/bin/printf '\t')" read -r _id _loc _ver _rev; do
        [ -n "${_id:-}" ] || continue
        [ -n "${_rev:-}" ] || continue
        _have=$(/usr/bin/awk -F'\t' -v n="$_id" 'tolower($1)==tolower(n) { print $2; exit }' "$_state")
        [ -n "$_have" ] || { _skew="$_skew $_id(absent)"; continue; }
        [ "$_have" = "$_rev" ] || { _skew="$_skew $_id"; continue; }
        # And the label, because the label is what gets printed. A pin whose
        # version was edited without its revision is not something SPM writes,
        # but it is what this file would repeat as fact.
        _haveVer=$(/usr/bin/awk -F'\t' -v n="$_id" 'tolower($1)==tolower(n) { print $3; exit }' "$_state")
        case "$_ver" in
            "rev "*|-) ;;
            *) [ "$_haveVer" = "$_ver" ] || _skew="$_skew $_id(version)" ;;
        esac
    done < "$_pins"
    if [ -n "$_skew" ]; then
        if [ "$ALLOW_STALE" = "yes" ]; then
            echo "generate-third-party-notices: WARNING: checkouts do not match the pins:$_skew" >&2
        else
            fail "Checkouts do not match the pins in $RESOLVED:$_skew
  The license texts on disk are from a different resolution than the versions
  this file would print. Re-run ./build-speech-mlx.sh."
        fi
    fi
elif [ "$ALLOW_STALE" = "yes" ]; then
    echo "generate-third-party-notices: WARNING: no $STATE - cannot prove the checkouts match the pins" >&2
else
    fail "No $STATE - without it there is no way to tell whether the checkouts match the pins. Re-run ./build-speech-mlx.sh."
fi

# --- per-package license discovery -----------------------------------------
# The checkout directory is named after the repository and the pin after the
# identity, and the two differ in case (identity "eventsource" -> checkout
# "EventSource").
checkout_dir() {   # $1 = identity
    [ -d "$CHECKOUTS/$1" ] && { echo "$CHECKOUTS/$1"; return 0; }
    /usr/bin/find "$CHECKOUTS" -maxdepth 1 -type d -iname "$1" -print | /usr/bin/head -1
}

# Nested, not just the checkout root: several packages vendor third-party C and
# C++ that is compiled straight into the binary and carries its own license
# beside the sources - mlx-swift/Source/Cmlx holds Apple's MLX, mlx-c, fmt,
# nlohmann/json and metal-cpp. Taking only the root LICENSE looked complete
# while omitting all of those. ACKNOWLEDGMENTS is searched for as well, because
# that is where mlx reproduces the license of the one component it vendors as a
# header rather than as a directory (pocketfft). Tests are excluded because
# their fixtures are not redistributed.
emit_package_licenses() {   # $1 = checkout dir; nonzero if it carries no license text at all
    # find's status, not the pipeline's: a subtree it cannot descend into is a
    # set of licenses this file would omit, and `find | sort` would report the
    # exit status of sort.
    /usr/bin/find "$1" -maxdepth 5 -type f \
        \( -iname "LICENSE*" -o -iname "NOTICE*" -o -iname "COPYING*" \
           -o -iname "ACKNOWLEDGMENTS*" \) \
        ! -path "*/Tests/*" ! -path "*/.git/*" -print > "$_licraw" || return 1
    LC_ALL=C /usr/bin/sort "$_licraw" > "$_liclist" || return 1
    _any=0
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        [ -f "$_f" ] || continue
        # Not `--- path ---`: fmt's LICENSE contains a line of exactly that
        # shape ("--- Optional exception to the license ---"), so a reader
        # could not tell a heading of ours from the text of a license.
        echo "[license file] ${_f#"$1"/}"
        echo
        /bin/cat "$_f" || fail "Could not read $_f"
        echo
        _any=1
    done < "$_liclist"
    [ "$_any" = 1 ]
}

# --- emit ------------------------------------------------------------------
emit() {
    cat <<'HEADER'
speech-mlx - Third-Party Software Notices
=========================================

speech-mlx is part of `speech` and is licensed under the Apache License,
Version 2.0; see the LICENSE file distributed beside this one.

The speech-mlx executable statically links the Swift packages listed below.
HEADER

    # The bundles are read off the build product rather than written down here,
    # because build-speech-mlx.sh copies whatever the graph produced and that
    # set moves with the dependency versions.
    _bundles=""
    if [ -n "$BUNDLES" ] && [ -d "$BUNDLES" ]; then
        for _b in "$BUNDLES"/*.bundle; do
            [ -d "$_b" ] || continue
            _bundles="$_bundles $(/usr/bin/basename "$_b")"
        done
    fi
    if [ -n "$_bundles" ]; then
        echo "Some of them also ship resource bundles that are redistributed beside the"
        echo "binary; this build produced these, one of them the compiled Metal shaders"
        echo "without which the helper aborts:"
        echo
        for _b in $_bundles; do echo "    $_b"; done
        echo
    else
        echo "Some of them also ship resource bundles that are redistributed beside the"
        echo "binary, one of them the compiled Metal shaders without which the helper"
        echo "aborts."
        echo
    fi

    cat <<'HEADER'
Every license below is reproduced in full, as those licenses require when the
covered work is redistributed in binary form. Where a package vendors
third-party code of its own, that code's license is reproduced too and is
labeled with its path inside the package.

The list is generated from the resolved package graph, so it covers the whole
pinned dependency set rather than only the two direct dependencies. Some listed
packages are not linked into the shipped binary at all - swift-syntax backs a
compiler macro plugin, and swift-crypto's vendored BoringSSL is compiled only
on platforms without CryptoKit - and they are kept because over-reporting a
notice is harmless while omitting one is not.

The models the helper runs are NOT covered here. They are downloaded at the
user's request, are not redistributed with this binary, and carry their own
licenses on Hugging Face; `speech catalog` names the repository each one comes
from.

HEADER

    _n=0
    _tab=$(/usr/bin/printf '\t')
    while IFS="$_tab" read -r _id _loc _ver _rev; do
        [ -n "${_id:-}" ] || continue
        _dir=$(checkout_dir "$_id")
        [ -n "$_dir" ] && [ -d "$_dir" ] || fail "No checkout for '$_id' under $CHECKOUTS - build first so SPM resolves it"
        _n=$((_n + 1))
        echo "--------------------------------------------------------------------------------"
        echo "$_n. $_id ${_ver:--}"
        echo "   ${_loc:--}"
        echo "--------------------------------------------------------------------------------"
        echo
        emit_package_licenses "$_dir" \
            || fail "No license text anywhere under $_dir - '$_id' would ship with no notice. Vendor its license under $SUPPLEMENTAL if upstream ships none."
        echo
    done < "$_pins"

    # Licenses that exist only as a header comment in a source file, which the
    # search above cannot find by construction. Each supplemental file explains
    # what it covers and why.
    _sup=0
    for _s in "$SUPPLEMENTAL"/*.txt; do
        [ -f "$_s" ] || continue
        echo "--------------------------------------------------------------------------------"
        echo "Vendored component: $(/usr/bin/basename "$_s" .txt)"
        echo "--------------------------------------------------------------------------------"
        echo
        /bin/cat "$_s" || fail "Could not read $_s"
        echo
        _sup=$((_sup + 1))
    done
    [ "$_sup" -gt 0 ] || fail "No *.txt in $SUPPLEMENTAL - it must carry the licenses that exist only as source-file headers (small_vector, pocketfft, expm1f, cexpf)"
}

if [ -n "$OUTPUT" ]; then
    # Staged inside the DESTINATION directory so the install is a same-volume
    # rename. Writing straight to $OUTPUT would truncate it up front, and a full
    # disk or a signal mid-copy would leave a short but non-empty notices file -
    # which passes every "is it there and non-empty" check downstream and ships
    # looking complete.
    _outdir=$(/usr/bin/dirname "$OUTPUT")
    [ -d "$_outdir" ] || fail "No directory $_outdir for --output"
    _stage=$(/usr/bin/mktemp "$_outdir/.notices.XXXXXX") || fail "Could not stage in $_outdir"
    emit > "$_stage" || fail "Could not assemble the notices"
    /bin/chmod 644 "$_stage" || fail "Could not set permissions on the staged notices"
    /bin/mv -f "$_stage" "$OUTPUT" || fail "Could not install $OUTPUT"
    _stage=""
    echo "Wrote $OUTPUT ($(/usr/bin/wc -l < "$OUTPUT" | /usr/bin/tr -d " ") lines, $_got packages)"
else
    emit
fi
