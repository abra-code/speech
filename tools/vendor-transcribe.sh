#!/bin/sh
# vendor-transcribe.sh - produce vendor/TranscribeCpp.xcframework from source.
#
# speech needs two transcribe.cpp fixes that no published release carries, so it
# cannot link the release asset. This script clones the pinned tag, applies the
# patches in patches/transcribe.cpp/, and builds the xcframework that
# Package.swift's CTranscribe binaryTarget points at. Every machine runs the same
# clone, the same patches and the same build, which is the whole point: the fixes
# live in this repository, not in someone's working tree.
#
# Usage:
#   tools/vendor-transcribe.sh                   # build if the inputs changed, else skip
#   tools/vendor-transcribe.sh --force           # rebuild unconditionally
#   tools/vendor-transcribe.sh --report-upstream # reprint the last newer-release
#                                                # reminder; builds and checks nothing
#
# Environment:
#   SPEECH_VENDOR_OFFLINE=1   skip the "is there a newer release?" check
#
# A patch that no longer applies FAILS the build. That is deliberate: it means
# upstream changed the code underneath a fix, and the fix has to be re-reviewed
# against the new code rather than silently dropped. Do not hand-edit the clone -
# it is deleted and re-created on every rebuild.
#
# Requires cmake and Xcode itself, not just the command line tools: upstream's
# build script ends in `xcodebuild -create-xcframework`, and xcodebuild is a
# stub without Xcode.app. ninja is used if present and the build falls back to
# make if it is not.

REPO_URL="https://github.com/handy-computer/transcribe.cpp.git"
PINNED_TAG="v0.2.3"
# The commit the tag pointed at when the pin was made. A tag can be moved; a
# commit cannot, so the clone is verified against this.
PINNED_COMMIT="63a44d9239d610b3908e8a66b384924cd4a77217"
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

usage() {
    printf 'usage: %s [--force | --report-upstream]\n' "$0" >&2
    exit 1
}

force=""
report_only=""
if [ "$#" -gt 1 ]; then
    usage
fi
case "${1:-}" in
    "") ;;
    --force) force="yes" ;;
    --report-upstream) report_only="yes" ;;
    *) usage ;;
esac

say() { printf 'vendor-transcribe: %s\n' "$1" >&2; }

clone_state() { printf '%s\n' "$1" > "$clone_state_file"; }

die() {
    local _line
    printf '\n' >&2
    printf 'vendor-transcribe.sh: FAILED\n' >&2
    for _line in "$@"; do
        printf '  %s\n' "$_line" >&2
    done
    printf '\n' >&2
    exit 1
}

# ---- patch series -----------------------------------------------------------
#
# Patches directly under patches/transcribe.cpp/ apply at the clone root.
# Patches under patches/transcribe.cpp/ggml/ apply inside the vendored ggml
# tree, because they are written against the ggml repository and are meant to go
# upstream to ggml unchanged (transcribe.cpp keeps its own in patches/ggml/ the
# same way).

root_patches() { /usr/bin/find "$patch_root" -maxdepth 1 -name '*.patch' 2>/dev/null | /usr/bin/sort; }
ggml_patches() { /usr/bin/find "$patch_root/ggml" -maxdepth 1 -name '*.patch' 2>/dev/null | /usr/bin/sort; }

# The identity of a build: the recipe, the pinned commit, the slices, and the
# content of every patch. Any change to those invalidates what is in vendor/.
fingerprint() {
    local _p
    printf 'recipe=%s commit=%s slices=%s\n' "$RECIPE_VERSION" "$PINNED_COMMIT" "$SLICES"
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
    local _tags="$(GIT_TERMINAL_PROMPT=0 /usr/bin/git \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 \
        ls-remote --tags --refs "$REPO_URL" 'v*' 2>/dev/null)"
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
    fi
}

report_upstream() {
    if [ -z "$newer_tag" ]; then
        return 0
    fi
    printf '\n' >&2
    printf '**********************************************************************\n' >&2
    printf '**  transcribe.cpp %s is published. speech is pinned to %s.\n' "$newer_tag" "$PINNED_TAG" >&2
    printf '**\n' >&2
    printf '**  Nothing is broken and nothing was changed. This is a reminder to\n' >&2
    printf '**  evaluate the new release: whether it carries the fixes in\n' >&2
    printf '**  patches/transcribe.cpp/ (then drop them), what it changes for the\n' >&2
    printf '**  measured rows in docs/, and whether the vendored Swift wrapper in\n' >&2
    printf '**  Sources/TranscribeCpp still matches its ABI hash.\n' >&2
    printf '**\n' >&2
    printf '**  The pin lives in tools/vendor-transcribe.sh (PINNED_TAG).\n' >&2
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

# Same guard for the ggml half of the series. find prints nothing for a missing
# directory, so without this a checkout that lost patches/transcribe.cpp/ggml/
# would build with the root patches only and report success. If the ggml fixes
# ever land upstream, delete this check along with the directory.
if [ ! -d "$patch_root/ggml" ]; then
    die "patches/transcribe.cpp/ggml/ is missing from this checkout." \
        "The Metal out-of-memory fixes live there; a build without them crashes" \
        "on a long recording instead of returning an error."
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

want_stamp="$(fingerprint | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1)"

have_stamp=""
if [ -f "$stamp_file" ]; then
    read -r have_stamp < "$stamp_file"
fi

# Info.plist rather than the directory: an xcframework without its plist is not
# one, and half-deleted trees are the kind of thing that survives a Ctrl-C.
if [ -z "$force" ] && [ -f "$xcframework/Info.plist" ] && [ "$have_stamp" = "$want_stamp" ]; then
    say "vendor/TranscribeCpp.xcframework is up to date ($PINNED_TAG plus $patch_count patches)."
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

say "cloning transcribe.cpp $PINNED_TAG"
/bin/rm -rf "$clone_dir"
# advice.detachedHead off: cloning a tag always detaches, and git's paragraph
# about experimental branches is noise in a build log, not news. No low-speed
# guard here, unlike the tag check: a real clone over a slow link is allowed to
# take its time. GIT_TERMINAL_PROMPT=0 so it fails instead of waiting for
# credentials nobody is there to type.
GIT_TERMINAL_PROMPT=0 /usr/bin/git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$PINNED_TAG" "$REPO_URL" "$clone_dir"
clone_status=$?
if [ "$clone_status" -ne 0 ]; then
    die "git clone of $REPO_URL at $PINNED_TAG failed (status $clone_status)." \
        "A network is needed whenever the framework is rebuilt: the first build" \
        "on a machine, --force, or a change to a patch or the pin. The clone is" \
        "re-created every time; only the built xcframework in vendor/ is reused."
fi

head_commit="$(/usr/bin/git -C "$clone_dir" rev-parse HEAD 2>/dev/null)"
if [ "$head_commit" != "$PINNED_COMMIT" ]; then
    die "$PINNED_TAG resolved to $head_commit, not the pinned $PINNED_COMMIT." \
        "The tag was moved, or the clone came from a different repository." \
        "Nothing was built. Review what changed before updating PINNED_COMMIT in" \
        "tools/vendor-transcribe.sh."
fi

clone_state "incomplete: patches not applied yet"

# ---- patch ------------------------------------------------------------------
#
patch_failed() {
    clone_state "incomplete: $1 did not apply; patches after it were never tried"
    die "patch does not apply: $1" \
        "" \
        "Target: transcribe.cpp $PINNED_TAG ($PINNED_COMMIT)$2" \
        "" \
        "Upstream changed the code this fix depends on, so the fix cannot be" \
        "applied as written and the build stops here rather than shipping a" \
        "binary without it. Rework the patch against the pinned tag (or move the" \
        "pin and re-verify the fix), then run this script again." \
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
        "the one being built. Re-vendor the wrapper from $PINNED_TAG and review" \
        "what moved in the C header before bumping the pinned hash."
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

say "vendor/TranscribeCpp.xcframework built from $PINNED_TAG plus $patch_count patches."
report_upstream
exit 0
