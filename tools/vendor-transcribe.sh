#!/bin/sh
# vendor-transcribe.sh - produce vendor/TranscribeCpp.xcframework from source.
#
# speech needs transcribe.cpp fixes that no published release carries, so it
# cannot link the release asset. This script clones the pinned tag, applies the
# patches in patches/transcribe.cpp/, and builds the xcframework that
# Package.swift's CTranscribe binaryTarget points at. Every machine runs the same
# clone, the same patches and the same build, which is the whole point: the fixes
# live in this repository, not in someone's working tree.
#
# The pin - a tag and the commit it pointed at - is patches/transcribe.cpp/PIN,
# beside the patches written against it.
#
# Usage:
#   tools/vendor-transcribe.sh                   # build the pin if the inputs changed, else skip
#   tools/vendor-transcribe.sh --update          # build the newest release instead, and
#                                                # move the pin to it once that builds
#   tools/vendor-transcribe.sh --force           # rebuild unconditionally (combines with --update)
#   tools/vendor-transcribe.sh --report-upstream # reprint the last newer-release
#                                                # reminder; builds and checks nothing
#
# ./build.sh passes --update unless it is given --no-update, the same policy as
# its Swift packages: the default build moves to the newest release, and the
# committed PIN records which one a build used.
#
# Environment:
#   SPEECH_VENDOR_OFFLINE=1   skip the "is there a newer release?" check, which
#                             also makes --update build the pin
#
# A patch that no longer applies FAILS the build, on the pin and on an update
# alike. That is deliberate: it means upstream changed the code underneath a
# fix, and the fix has to be re-reviewed against the new code rather than
# silently dropped. A patch the release already carries fails too, so it gets
# deleted rather than left to rot. An update that fails leaves PIN as it was, so
# `./build.sh --no-update` still builds the pinned release. Do not hand-edit the
# clone - it is deleted and re-created on every rebuild.
#
# Requires cmake and Xcode itself, not just the command line tools: upstream's
# build script ends in `xcodebuild -create-xcframework`, and xcodebuild is a
# stub without Xcode.app. ninja is used if present and the build falls back to
# make if it is not.

REPO_URL="https://github.com/handy-computer/transcribe.cpp.git"
# macos only. speech is arm64-only (see build.sh) and has no use for the iOS
# slices, which would triple the build. The macos slice itself is universal
# because that is what upstream's script produces and forking its linking and
# framework-assembly logic to save a compile is not worth the drift.
SLICES="macos"
# Bump when this script changes what it produces, so a cached build is discarded.
RECIPE_VERSION="1"

script_dir="$(/usr/bin/dirname "$0")"
repo_root="$(cd "$script_dir/.." && pwd)"
patch_root="$repo_root/patches/transcribe.cpp"
vendor_dir="$repo_root/vendor"
clone_dir="$vendor_dir/transcribe.cpp"
xcframework="$vendor_dir/TranscribeCpp.xcframework"
stamp_file="$vendor_dir/.stamp"
# How far patching got in the clone. A tree left behind by a failed run looks
# exactly like a good one, and a later run whose build is still cached does NOT
# re-clone, so that half-patched tree can sit there for hours and mislead anyone
# who reads it as "the patched source" - it compiles, and produces a binary
# quietly missing fixes.
clone_state_file="$clone_dir/.speech-patch-state"
# What the last upstream check found, so build.sh can repeat the reminder after
# its own log without asking the network a second time.
newer_tag_file="$vendor_dir/.newer-tag"
abihash_swift="$repo_root/Sources/TranscribeCpp/ABIHash.swift"
wrapper_swift="$repo_root/Sources/TranscribeCpp/TranscribeCpp.swift"
pin_file="$patch_root/PIN"

usage() {
    printf 'usage: %s [--update] [--force] | --report-upstream\n' "$0" >&2
    exit 1
}

force=""
update=""
report_only=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) force="yes" ;;
        --update) update="yes" ;;
        --report-upstream) report_only="yes" ;;
        *) usage ;;
    esac
    shift
done
if [ -n "$report_only" ] && { [ -n "$force" ] || [ -n "$update" ]; }; then
    usage
fi

say() { printf 'vendor-transcribe: %s\n' "$1" >&2; }

clone_state() { printf '%s\n' "$1" > "$clone_state_file"; }

# Set once an update to a newer release is under way, so every failure from
# then on says how to build the pin instead.
updating=""

die() {
    local _line
    printf '\n' >&2
    printf 'vendor-transcribe.sh: FAILED\n' >&2
    for _line in "$@"; do
        printf '  %s\n' "$_line" >&2
    done
    if [ -n "$updating" ]; then
        printf '\n' >&2
        printf '  This was the update to %s; patches/transcribe.cpp/PIN still names\n' "$target_tag" >&2
        printf '  %s, and ./build.sh --no-update builds that.\n' "$PINNED_TAG" >&2
    fi
    printf '\n' >&2
    exit 1
}

# ---- the pin ----------------------------------------------------------------
#
# A tag and the commit it pointed at when the pin was made. A tag can be moved;
# a commit cannot, so the clone is verified against the commit.
if [ ! -f "$pin_file" ]; then
    die "no pin: $pin_file is missing." \
        "It names the transcribe.cpp release the patches are written against."
fi
PINNED_TAG="$(/usr/bin/sed -n 's/^tag[[:space:]][[:space:]]*\([^[:space:]]*\).*/\1/p' "$pin_file" | /usr/bin/head -1)"
PINNED_COMMIT="$(/usr/bin/sed -n 's/^commit[[:space:]][[:space:]]*\([0-9a-f]*\).*/\1/p' "$pin_file" | /usr/bin/head -1)"
case "$PINNED_TAG" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) die "$pin_file names no tag of the form vX.Y.Z (found '${PINNED_TAG}')." ;;
esac
if [ "${#PINNED_COMMIT}" -ne 40 ]; then
    die "$pin_file names no full 40-character commit (found '${PINNED_COMMIT}')."
fi

# What this run builds: the pin, or with --update the newest release when there
# is a newer one. Set after the upstream check below.
target_tag="$PINNED_TAG"
target_commit="$PINNED_COMMIT"

# ---- patch series -----------------------------------------------------------
#
# Patches directly under patches/transcribe.cpp/ apply at the clone root.
# Patches under patches/transcribe.cpp/ggml/ apply inside the vendored ggml
# tree, because they are written against the ggml repository and are meant to go
# upstream to ggml unchanged (transcribe.cpp keeps its own in patches/ggml/ the
# same way). There are none at v0.4.0, whose newer ggml carries both of the
# fixes that used to live there; the folder is simply absent until another one
# is needed.

root_patches() { /usr/bin/find "$patch_root" -maxdepth 1 -name '*.patch' 2>/dev/null | /usr/bin/sort; }
ggml_patches() { /usr/bin/find "$patch_root/ggml" -maxdepth 1 -name '*.patch' 2>/dev/null | /usr/bin/sort; }

# The identity of a build: the recipe, the pinned commit, the slices, and the
# content of every patch. Any change to those invalidates what is in vendor/.
fingerprint() {
    local _p
    printf 'recipe=%s commit=%s slices=%s\n' "$RECIPE_VERSION" "$target_commit" "$SLICES"
    # The vendored Swift wrapper's ABI hash and version too. The gates that
    # compare them with the library run only when the framework is rebuilt, so
    # a wrapper that changed on its own (a checkout, a re-vendor) has to force
    # that rebuild - or an up-to-date skip would pass a pair that cannot load.
    printf 'wrapper-abihash=%s wrapper-version=%s\n' \
        "$(/usr/bin/sed -n 's/.*pinnedHeaderHash = "\([0-9a-f]*\)".*/\1/p' "$abihash_swift")" \
        "$(/usr/bin/sed -n 's/.*compiledVersion = "\([^"]*\)".*/\1/p' "$wrapper_swift")"
    { root_patches; ggml_patches; } | while read -r _p; do
        printf '%s %s\n' "$(/usr/bin/shasum -a 256 "$_p" | /usr/bin/cut -d' ' -f1)" "$(/usr/bin/basename "$_p")"
    done
}

# ---- is there a newer release? ----------------------------------------------
#
# Pinning a tag is how the build stays reproducible; not noticing that the tag is
# a year old is how it rots. The check never fails the build - no network, no
# complaint - and what it finds is recorded in vendor/.newer-tag so build.sh can
# print the same banner again after the Swift build, where nothing scrolls past
# it. Under ./build.sh the reminder therefore appears twice, which is the right
# number of times for something that is easy to keep ignoring.

newer_tag=""
newer_commit=""

check_upstream() {
    /bin/rm -f "$newer_tag_file"
    if [ "${SPEECH_VENDOR_OFFLINE:-}" = "1" ]; then
        return 0
    fi
    # GIT_TERMINAL_PROMPT=0 so a repository that has become private cannot stop
    # the build on a credential prompt, and the low-speed guard so a transfer
    # that stalls mid-answer - a captive portal, a proxy that accepts and then
    # sits there - is abandoned after 5 seconds. It bounds the transfer, not the
    # connect: git has no connect timeout, so a black-holed SYN or a hanging
    # resolver still costs the OS default, around 75 s on macOS. Both matter
    # because this runs on every build, including the cached no-op.
    #
    # Without --refs, so annotated tags also list the commit they point at (the
    # "^{}" lines): --update pins that commit before it clones, exactly as the
    # pin itself is verified.
    local _tags="$(GIT_TERMINAL_PROMPT=0 /usr/bin/git \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 \
        ls-remote --tags "$REPO_URL" 'v*' 2>/dev/null)"
    if [ -z "$_tags" ]; then
        return 0
    fi
    local _latest="$(printf '%s\n' "$_tags" \
        | /usr/bin/sed -n 's|.*refs/tags/||p' \
        | /usr/bin/grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | /usr/bin/sort -V \
        | /usr/bin/tail -1)"
    if [ -z "$_latest" ] || [ "$_latest" = "$PINNED_TAG" ]; then
        return 0
    fi
    # sort -V decides which is newer; an older "latest" means the pin is ahead of
    # the published tags (a pin on main, say) and is not worth a banner.
    local _newest="$(printf '%s\n%s\n' "$PINNED_TAG" "$_latest" | /usr/bin/sort -V | /usr/bin/tail -1)"
    if [ "$_newest" != "$PINNED_TAG" ]; then
        newer_tag="$_latest"
        printf '%s\n' "$newer_tag" > "$newer_tag_file"
        # The peeled line for an annotated tag, the tag's own line for a
        # lightweight one, whose object is the commit.
        newer_commit="$(printf '%s\n' "$_tags" | /usr/bin/awk -v ref="refs/tags/$_latest^{}" '$2 == ref { print $1 }')"
        if [ -z "$newer_commit" ]; then
            newer_commit="$(printf '%s\n' "$_tags" | /usr/bin/awk -v ref="refs/tags/$_latest" '$2 == ref { print $1 }')"
        fi
    fi
}

report_upstream() {
    if [ -z "$newer_tag" ]; then
        return 0
    fi
    printf '\n' >&2
    printf '**********************************************************************\n' >&2
    printf '**  transcribe.cpp %s is published. This build used the pinned %s.\n' "$newer_tag" "$PINNED_TAG" >&2
    printf '**\n' >&2
    printf '**  Nothing is broken. It was not updated because this run had no\n' >&2
    printf '**  --update (./build.sh --no-update, or this script run directly).\n' >&2
    printf '**  A default ./build.sh moves to it, and stops if a patch in\n' >&2
    printf '**  patches/transcribe.cpp/ no longer applies, if the release already\n' >&2
    printf '**  carries one, or if the vendored Swift wrapper in Sources/TranscribeCpp\n' >&2
    printf '**  does not match its ABI hash or version.\n' >&2
    printf '**\n' >&2
    printf '**  The pin lives in patches/transcribe.cpp/PIN.\n' >&2
    printf '**********************************************************************\n' >&2
    printf '\n' >&2
}

# --report-upstream: print what the last check found and nothing else. This is
# how build.sh repeats the reminder at the end of its own output; it reads the
# file this script wrote minutes earlier rather than asking the network again,
# and it builds, checks and changes nothing.
if [ -n "$report_only" ]; then
    if [ -f "$newer_tag_file" ]; then
        read -r newer_tag < "$newer_tag_file"
    fi
    # The marker is only as current as the last check. If the pin has since
    # been moved up to (or past) what it recorded, the tag is not newer any
    # more and must not be announced as if it were - same sort -V test as the
    # check itself.
    if [ -n "$newer_tag" ]; then
        newest="$(printf '%s\n%s\n' "$PINNED_TAG" "$newer_tag" | /usr/bin/sort -V | /usr/bin/tail -1)"
        if [ "$newest" = "$PINNED_TAG" ]; then
            newer_tag=""
        fi
    fi
    report_upstream
    exit 0
fi

# ---- preflight --------------------------------------------------------------

cmake_path="$(command -v cmake 2>/dev/null)"
if [ -z "$cmake_path" ]; then
    die "cmake was not found in PATH." \
        "transcribe.cpp is built from source here, so cmake is required." \
        "Install it with 'brew install cmake' (ninja is optional but faster)."
fi

/usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1
xcrun_status=$?
if [ "$xcrun_status" -ne 0 ]; then
    die "no macOS SDK: 'xcrun --sdk macosx --show-sdk-path' failed." \
        "Install the Xcode command line tools with 'xcode-select --install'."
fi

# The SDK check above passes with the command line tools alone, but upstream's
# build script finishes with `xcodebuild -create-xcframework`, and xcodebuild
# under a command-line-tools developer directory is a stub that refuses to run.
# Catch that here rather than after several minutes of compiling.
/usr/bin/xcodebuild -version >/dev/null 2>&1
xcodebuild_status=$?
if [ "$xcodebuild_status" -ne 0 ]; then
    die "xcodebuild is not usable: 'xcodebuild -version' failed." \
        "Assembling the xcframework needs Xcode itself, not only the command" \
        "line tools. Install Xcode and point xcode-select at it:" \
        "  sudo xcode-select -s /Applications/Xcode.app"
fi

if [ ! -d "$patch_root" ]; then
    die "patches/transcribe.cpp/ is missing from this checkout." \
        "The patched build cannot be reproduced without it."
fi

# An empty series would build a clean upstream tree and hand back a framework
# without the fixes, which is exactly the silent outcome this script exists to
# prevent. If the fixes ever land upstream, delete this check along with them.
patch_count="$({ root_patches; ggml_patches; } | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [ "$patch_count" = "0" ]; then
    die "patches/transcribe.cpp/ holds no patches." \
        "speech links transcribe.cpp only because of the fixes kept there; an" \
        "unpatched build would lose them without saying so."
fi

# ---- skip when nothing changed ----------------------------------------------

# Before the upstream check, which records what it found in here.
/bin/mkdir -p "$vendor_dir"
mkdir_status=$?
if [ "$mkdir_status" -ne 0 ]; then
    die "could not create $vendor_dir"
fi

check_upstream

if [ -n "$update" ] && [ -n "$newer_tag" ]; then
    if [ "${#newer_commit}" -ne 40 ]; then
        die "$newer_tag is published, but its commit could not be read from" \
            "git ls-remote, so it cannot be pinned. ./build.sh --no-update builds" \
            "the pinned $PINNED_TAG."
    fi
    target_tag="$newer_tag"
    target_commit="$newer_commit"
    updating="yes"
    say "updating transcribe.cpp $PINNED_TAG -> $target_tag ($target_commit)"
fi

# Move the pin to the update target. Only ever called once the framework for
# that target exists, so a failed update leaves PIN naming the last release that
# built. The file's comment lines are kept; it is written beside the original
# and renamed over it, so an interrupt cannot leave half a pin.
write_pin() {
    local _staged="$pin_file.new.$$"
    {
        /usr/bin/grep '^#' "$pin_file"
        printf 'tag %s\n' "$target_tag"
        printf 'commit %s\n' "$target_commit"
    } > "$_staged"
    local _write_status=$?
    if [ "$_write_status" -eq 0 ]; then
        /bin/mv -f "$_staged" "$pin_file"
        _write_status=$?
    fi
    if [ "$_write_status" -ne 0 ]; then
        /bin/rm -f "$_staged"
        updating=""
        die "built $target_tag, but could not write it into $pin_file." \
            "Set it by hand: tag $target_tag, commit $target_commit."
    fi
    say "patches/transcribe.cpp/PIN moved $PINNED_TAG -> $target_tag; review and commit it."
    # Not newer any more: the banner below must not announce it.
    newer_tag=""
    /bin/rm -f "$newer_tag_file"
}

want_stamp="$(fingerprint | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1)"

have_stamp=""
if [ -f "$stamp_file" ]; then
    read -r have_stamp < "$stamp_file"
fi

# Info.plist rather than the directory: an xcframework without its plist is not
# one, and half-deleted trees are the kind of thing that survives a Ctrl-C.
if [ -z "$force" ] && [ -f "$xcframework/Info.plist" ] && [ "$have_stamp" = "$want_stamp" ]; then
    say "vendor/TranscribeCpp.xcframework is up to date ($target_tag plus $patch_count patches)."
    # Built from the update target already, with PIN since put back (a git
    # checkout, say): the framework stands, and the pin has to follow it.
    if [ -n "$updating" ]; then
        write_pin
    fi
    # The framework is right; the clone beside it may not be. Say so rather than
    # let it be mistaken for the source the framework was built from.
    clone_state_now=""
    if [ -f "$clone_state_file" ]; then
        read -r clone_state_now < "$clone_state_file"
    fi
    if [ -d "$clone_dir" ] && [ "$clone_state_now" != "complete $want_stamp" ]; then
        say "note: vendor/transcribe.cpp is NOT a complete patched tree (${clone_state_now:-state unknown})."
        say "      The framework above is unaffected. Run --force before reading or building from that clone."
    fi
    report_upstream
    exit 0
fi

# ---- clone ------------------------------------------------------------------

say "cloning transcribe.cpp $target_tag"
/bin/rm -rf "$clone_dir"
# advice.detachedHead off: cloning a tag always detaches, and git's paragraph
# about experimental branches is noise in a build log, not news. No low-speed
# guard here, unlike the tag check: a real clone over a slow link is allowed to
# take its time. GIT_TERMINAL_PROMPT=0 so it fails instead of waiting for
# credentials nobody is there to type.
GIT_TERMINAL_PROMPT=0 /usr/bin/git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$target_tag" "$REPO_URL" "$clone_dir"
clone_status=$?
if [ "$clone_status" -ne 0 ]; then
    die "git clone of $REPO_URL at $target_tag failed (status $clone_status)." \
        "A network is needed whenever the framework is rebuilt: the first build" \
        "on a machine, --force, or a change to a patch or the pin. The clone is" \
        "re-created every time; only the built xcframework in vendor/ is reused."
fi

head_commit="$(/usr/bin/git -C "$clone_dir" rev-parse HEAD 2>/dev/null)"
if [ "$head_commit" != "$target_commit" ]; then
    die "$target_tag resolved to $head_commit, not the expected $target_commit." \
        "The tag was moved, or the clone came from a different repository." \
        "Nothing was built. Review what changed before updating the commit in" \
        "patches/transcribe.cpp/PIN."
fi

clone_state "incomplete: patches not applied yet"

# ---- patch ------------------------------------------------------------------
#
patch_failed() {
    clone_state "incomplete: $1 did not apply; patches after it were never tried"
    die "patch does not apply: $1" \
        "" \
        "Target: transcribe.cpp $target_tag ($target_commit)$2" \
        "" \
        "Upstream changed the code this fix depends on, so the fix cannot be" \
        "applied as written and the build stops here rather than shipping a" \
        "binary without it. Rework the patch against $target_tag, then run" \
        "this script again." \
        "" \
        "The clone is left as it was when the patch failed, for inspection: the" \
        "patches ordered after this one were never applied, so do not build from" \
        "it or read it as the patched source. Do not hand-edit it either - it is" \
        "deleted and re-cloned on the next rebuild." \
        "" \
        "What each patch is for: patches/transcribe.cpp/README.md"
}

apply_one() {
    local _patch="$1"
    local _subdir="$2"
    local _name="$(/usr/bin/basename "$_patch")"
    local _where=""
    if [ -n "$_subdir" ]; then
        _where=", applied in $_subdir/"
    fi

    local _check_status
    if [ -n "$_subdir" ]; then
        /usr/bin/git -C "$clone_dir" apply --check -p1 --directory="$_subdir" "$_patch"
        _check_status=$?
    else
        /usr/bin/git -C "$clone_dir" apply --check -p1 "$_patch"
        _check_status=$?
    fi
    if [ "$_check_status" -ne 0 ]; then
        patch_failed "$_name" "$_where"
    fi

    local _apply_status
    if [ -n "$_subdir" ]; then
        /usr/bin/git -C "$clone_dir" apply -p1 --directory="$_subdir" "$_patch"
        _apply_status=$?
    else
        /usr/bin/git -C "$clone_dir" apply -p1 "$_patch"
        _apply_status=$?
    fi
    if [ "$_apply_status" -ne 0 ]; then
        patch_failed "$_name" "$_where"
    fi
    say "applied $_name"
}

# Every patch is first checked on its own against the clean tree, so a release
# that breaks several says so for all of them at once, and a patch the release
# already carries is named as such: it fails `git apply --check` like any other,
# but the remedy is to delete it, not to rework it. Any failure here stops the
# build, so every patch has to apply to the clean tree on its own: a patch that
# builds on an earlier one in the series would be rejected here even though the
# in-order apply below would take it.
precheck_failed=""
precheck_one() {
    local _patch="$1"
    local _subdir="$2"
    local _name="$(/usr/bin/basename "$_patch")"
    local _label="$_name"
    if [ -n "$_subdir" ]; then
        _label="$_subdir/$_name"
    fi
    local _forward_status
    local _reverse_status
    if [ -n "$_subdir" ]; then
        /usr/bin/git -C "$clone_dir" apply --check -p1 --directory="$_subdir" "$_patch" > /dev/null 2>&1
        _forward_status=$?
    else
        /usr/bin/git -C "$clone_dir" apply --check -p1 "$_patch" > /dev/null 2>&1
        _forward_status=$?
    fi
    if [ "$_forward_status" -eq 0 ]; then
        say "  $_label: applies"
        return 0
    fi
    if [ -n "$_subdir" ]; then
        /usr/bin/git -C "$clone_dir" apply --check -R -p1 --directory="$_subdir" "$_patch" > /dev/null 2>&1
        _reverse_status=$?
    else
        /usr/bin/git -C "$clone_dir" apply --check -R -p1 "$_patch" > /dev/null 2>&1
        _reverse_status=$?
    fi
    if [ "$_reverse_status" -eq 0 ]; then
        say "  $_label: ALREADY IN $target_tag - delete the patch and its section in patches/transcribe.cpp/README.md"
    else
        say "  $_label: DOES NOT APPLY to $target_tag - rework it against that release"
    fi
    precheck_failed="$precheck_failed $_label"
}

say "checking the patches against $target_tag:"
saved_ifs="$IFS"
IFS='
'
set -f
for patch in $(root_patches); do
    precheck_one "$patch" ""
done
for patch in $(ggml_patches); do
    precheck_one "$patch" "ggml"
done
set +f
IFS="$saved_ifs"

if [ -n "$precheck_failed" ]; then
    clone_state "incomplete: patches not applied (pre-check failed:$precheck_failed)"
    die "patches that do not apply to transcribe.cpp $target_tag:$precheck_failed" \
        "" \
        "Each one is listed above with what to do about it. The build stops here" \
        "rather than shipping a binary without a fix. How to rework a patch:" \
        "patches/transcribe.cpp/README.md (\"When a patch stops applying\")."
fi

# Split on newlines only, so a checkout under a path with spaces still works, and
# loop in THIS shell rather than piping into one: a `die` inside a pipeline would
# exit the subshell and let a failed patch through. `set -f` because an unquoted
# expansion is still glob-expanded, and a checkout under a path containing [ or *
# would otherwise turn a patch name into something else or nothing at all.
saved_ifs="$IFS"
IFS='
'
set -f
for patch in $(root_patches); do
    apply_one "$patch" ""
done
for patch in $(ggml_patches); do
    apply_one "$patch" "ggml"
done
set +f
IFS="$saved_ifs"

clone_state "complete $want_stamp"

# ---- the wrapper and the library have to agree on the ABI -------------------
#
# Sources/TranscribeCpp is upstream's Swift wrapper, vendored at the pinned tag.
# Its pinned hash is the gate upstream uses in CI; checking it here catches a pin
# bump that moved the C header without the wrapper being re-vendored.

clone_abihash=""
if [ -f "$clone_dir/include/transcribe.abihash" ]; then
    read -r clone_abihash < "$clone_dir/include/transcribe.abihash"
fi
wrapper_abihash="$(/usr/bin/sed -n 's/.*pinnedHeaderHash = "\([0-9a-f]*\)".*/\1/p' "$abihash_swift")"

if [ -z "$clone_abihash" ] || [ -z "$wrapper_abihash" ]; then
    die "could not read the ABI hashes to compare." \
        "clone: $clone_dir/include/transcribe.abihash" \
        "wrapper: $abihash_swift"
fi
if [ "$clone_abihash" != "$wrapper_abihash" ]; then
    die "public ABI mismatch: the library says $clone_abihash, the vendored" \
        "Swift wrapper is pinned to $wrapper_abihash." \
        "" \
        "Sources/TranscribeCpp was copied from a different transcribe.cpp than" \
        "the one being built. Re-vendor the wrapper from $target_tag and review" \
        "what moved in the C header before bumping the pinned hash."
fi

# And on the version. The wrapper refuses, at load time, any library whose
# MAJOR.MINOR.PATCH differs from its compiledVersion (Transcribe.ensureCompatible),
# so a release that left the ABI hash alone would still build here and then
# fail on every ggml row at runtime. Checked now, while it is a build error.
header="$clone_dir/include/transcribe.h"
clone_major="$(/usr/bin/sed -n 's/^#define TRANSCRIBE_VERSION_MAJOR[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' "$header")"
clone_minor="$(/usr/bin/sed -n 's/^#define TRANSCRIBE_VERSION_MINOR[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' "$header")"
clone_patch="$(/usr/bin/sed -n 's/^#define TRANSCRIBE_VERSION_PATCH[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' "$header")"
wrapper_version="$(/usr/bin/sed -n 's/.*compiledVersion = "\([^"]*\)".*/\1/p' "$wrapper_swift")"
if [ -z "$clone_major" ] || [ -z "$clone_minor" ] || [ -z "$clone_patch" ] || [ -z "$wrapper_version" ]; then
    die "could not read the versions to compare." \
        "library: TRANSCRIBE_VERSION_* in $header" \
        "wrapper: compiledVersion in $wrapper_swift"
fi
clone_version="$clone_major.$clone_minor.$clone_patch"
# The base version exactly as the wrapper's baseVersion() takes it - the leading
# run of digits and dots - so a packaging suffix still loads.
wrapper_base="${wrapper_version%%[!0-9.]*}"
if [ "$clone_version" != "$wrapper_base" ]; then
    die "version mismatch: the library is $clone_version, the vendored Swift" \
        "wrapper was built against $wrapper_version (compiledVersion), and it" \
        "refuses to load a library of another version." \
        "" \
        "Re-vendor Sources/TranscribeCpp from $target_tag."
fi

# ---- build ------------------------------------------------------------------

say "building the $SLICES xcframework (this takes a while on a cold tree)"
TRANSCRIBE_XCFRAMEWORK_SLICES="$SLICES" "$clone_dir/scripts/ci/build_xcframework.sh"
build_status=$?
if [ "$build_status" -ne 0 ]; then
    die "the transcribe.cpp xcframework build failed (status $build_status)." \
        "The patched source is in $clone_dir; the build log is above."
fi

built="$clone_dir/bindings/swift/build-apple/TranscribeCpp.xcframework"
if [ ! -d "$built" ]; then
    die "the build reported success but produced no xcframework at:" "$built"
fi

/bin/rm -rf "$xcframework"
/bin/mv "$built" "$xcframework"
mv_status=$?
if [ "$mv_status" -ne 0 ]; then
    die "could not move the built xcframework into $vendor_dir"
fi

printf '%s\n' "$want_stamp" > "$stamp_file"

say "vendor/TranscribeCpp.xcframework built from $target_tag plus $patch_count patches."
if [ -n "$updating" ]; then
    write_pin
fi
report_upstream
exit 0
