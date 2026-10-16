#!/bin/sh
# Build speech as a command-line binary.
#
# Usage:
#   ./build.sh                   # produces build/speech (arm64, ad-hoc signed)
#   ./build.sh arm64             # the only supported architecture (see below)
#   ./build.sh --no-update       # build exactly what Package.resolved pins
#
# By default the dependencies are first moved to their newest releases: the
# Swift packages within Package.swift's ranges (tools/update-packages.sh root,
# which says what moved and what a range still holds back), and transcribe.cpp
# (tools/vendor-transcribe.sh --update). Package.resolved and
# patches/transcribe.cpp/PIN are committed, so a move shows up as a diff to
# review. --no-update skips both, for a build that has to match a recorded one
# or a machine with no network. A package update that fails leaves the pins as
# they were and the build goes on; a transcribe.cpp update that fails stops the
# build (see below).
#
# Mirrors pdfutil's and langid's build.sh deliberately - same contract, same
# shape, so an applet's update script treats every helper identically. The
# contract downstream is build/speech: an ad-hoc signed binary at a fixed path.
# Keep that path and the CLI stable.
#
# arm64 only, which is where this diverges from pdfutil.
#
# This started as a preference and became a hard constraint in stage 1. Two of
# the three planned engines are Apple Silicon only - FluidAudio ships CoreML
# packages for the ANE, and transcribe.cpp's Metal backend is the only one worth
# shipping - so an x86_64 slice was always going to be a binary that builds and
# then cannot run a single third-party model. Since linking FluidAudio it does
# not even build: FluidAudio's own sources use Float16, which is unavailable on
# x86_64 macOS (ASR/Shared/LogitsArgmax.swift, ASR/Paraformer/ParaformerManager.swift
# and the TTS pipelines it compiles alongside them). That is a limitation of the
# dependency, not a choice made here, so the other architectures are refused
# with a reason rather than left to fail eighty lines into a build log.
#
# Always an optimized release build; the compiler flags are SwiftPM's business
# (see Package.swift). This script only picks architectures, strips and signs.
#
# No `set -e`: each step that can fail is checked where it runs, so a failure
# names the step instead of ending the script with nothing said.

usage() { echo "usage: ./build.sh [arm64] [--no-update]"; }

fail() {
    echo "build.sh: $*" >&2
    exit 1
}

# Runs a command and fails the build, naming it, when it does not succeed.
step() {
    "$@"
    step_status=$?
    if [ "$step_status" -ne 0 ]; then
        fail "'$*' failed (exit $step_status)"
    fi
}

CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" || fail "cannot change to the directory holding build.sh"

want="arm64"
update="yes"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-update) update="no" ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "build.sh: unknown option '$1'" >&2; usage >&2; exit 1 ;;
        *) want="$1" ;;
    esac
    shift
done

case "$want" in
    arm64) arch_flags="--arch arm64" ;;
    x86_64|universal)
        echo "build.sh: '$want' cannot be built." >&2
        echo "" >&2
        echo "FluidAudio uses Float16, which is unavailable on x86_64 macOS, so the" >&2
        echo "dependency itself does not compile for that architecture. Even if it did," >&2
        echo "the FluidAudio and transcribe.cpp engines need Apple Silicon to run." >&2
        echo "Only 'arm64' is supported." >&2
        exit 1
        ;;
    *) usage >&2; exit 1 ;;
esac

# The transcribe.cpp xcframework is built from a patched clone rather than taken
# from a release, so it has to exist before SwiftPM reads Package.swift - a
# binaryTarget with a missing path is a manifest error. The script is a no-op
# once the pin and the patches have not changed, and it is where the fixes in
# patches/transcribe.cpp/ are applied (a patch that no longer applies stops the
# build here).
#
# It updates like the Swift packages: --update moves to the newest
# transcribe.cpp release, and patches/transcribe.cpp/PIN records which one a
# build used. Unlike a package update, one that fails stops the build - a patch
# that no longer applies, or that the release already carries, or a Swift
# wrapper that does not match the release, each needs a person - and leaves PIN
# as it was, so --no-update still builds the pinned release.
vendor_args=""
if [ "$update" = "yes" ]; then
    vendor_args="--update"
fi
pin_before="$(/sbin/md5 -q patches/transcribe.cpp/PIN 2>/dev/null)"
# shellcheck disable=SC2086  # an empty $vendor_args must expand to no argument.
./tools/vendor-transcribe.sh $vendor_args
vendor_status=$?
if [ "$vendor_status" -ne 0 ]; then
    fail "the transcribe.cpp vendor build failed; see above."
fi
pin_after="$(/sbin/md5 -q patches/transcribe.cpp/PIN 2>/dev/null)"
transcribe_moved="no"
if [ "$pin_before" != "$pin_after" ]; then
    transcribe_moved="yes"
fi

# The package update, after the vendor step because it loads Package.swift.
# Exit 1 means it failed and put the previous pins back, which is not a reason
# to stop a build: it is what happens offline, and the pins it leaves are the
# committed ones. Anything else - the pins could not be restored, a version
# string could not be rewritten, an interrupt - is.
update_result="skipped"
if [ "$update" = "yes" ]; then
    # What moved is compared, not the file's bytes: SwiftPM rewrites
    # Package.resolved's originHash whenever the manifest's dependency lines
    # change, with every pin where it was. The literal file is compared too, in
    # case a version string was behind pins that did not move.
    pins_before="$(/usr/bin/awk -f tools/package_pin_versions.awk Package.resolved 2>/dev/null)"
    literal_before="$(/sbin/md5 -q Sources/speech/Environment.swift 2>/dev/null)"
    ./tools/update-packages.sh root
    update_status=$?
    case "$update_status" in
        0)
            pins_after="$(/usr/bin/awk -f tools/package_pin_versions.awk Package.resolved 2>/dev/null)"
            literal_after="$(/sbin/md5 -q Sources/speech/Environment.swift 2>/dev/null)"
            if [ "$pins_before" != "$pins_after" ] || [ "$literal_before" != "$literal_after" ]; then
                update_result="changed"
            else
                update_result="current"
            fi
            ;;
        1) update_result="failed" ;;
        *) fail "the package update stopped (exit $update_status); see above." ;;
    esac
fi

# SwiftPM's scratch directory, in the visible build/ rather than a hidden
# .build, alongside the binary handed to consumers. SwiftPM only creates
# subdirectories in here, so build/speech does not collide with anything it owns.
scratch="build"

# After an update that moved the pins, the build products start over. Measured
# 2026-10-15 on the FluidAudio 0.15.6 -> 0.17.7 update, which also moved its
# NemoTextProcessing.xcframework from v0.3.0 to v0.3.1: the first incremental
# build compiled the framework's C module before its module.modulemap had been
# copied into Products/Release/include, and failed with "error reading
# .../include/module.modulemap"; the same build run again succeeded. A build
# that fails once after every update is not a default worth keeping.
#
# Only the build systems' own output folders go: out/ (Swift Build) and the
# per-triple folder (SwiftPM's native build system). Not `swift package clean`,
# which also deletes build/speech, the framework and the catalog beside it, so
# a failed rebuild would leave nothing that runs. Checkouts, repositories and
# downloaded artifacts stay, so this costs a recompile, not a download.
if [ "$update_result" = "changed" ]; then
    step /bin/rm -rf "$scratch/out" "$scratch/arm64-apple-macosx"
fi

# `swift build` runs lipo itself when given more than one --arch, so there is no
# separate universal step. Repeating the flags for --show-bin-path is not a
# rebuild: it re-resolves and prints the path, which differs by architecture
# selection, so it must not be hardcoded.
# shellcheck disable=SC2086  # $arch_flags must word-split into separate args.
/usr/bin/swift build -c release --scratch-path "$scratch" $arch_flags
build_status=$?
if [ "$build_status" -ne 0 ]; then
    if [ "$update_result" = "changed" ]; then
        echo "build.sh: this build follows a package update that moved the pins. To build" >&2
        echo "          the previous ones: git checkout -- Package.resolved Sources/speech/Environment.swift" >&2
        echo "          and then ./build.sh --no-update" >&2
    fi
    fail "swift build failed (exit $build_status)"
fi
bin_path=""
# shellcheck disable=SC2086
bin_path="$(/usr/bin/swift build -c release --scratch-path "$scratch" $arch_flags --show-bin-path)"
bin_status=$?
if [ "$bin_status" -ne 0 ] || [ -z "$bin_path" ]; then
    fail "swift build --show-bin-path failed (exit $bin_status)"
fi

# Assemble under a temporary name and rename into place only when the binary is
# finished. A cp that dies partway - full disk, killed build - would otherwise
# leave a truncated binary that still looks like a build product. A rename
# within one filesystem is atomic.
step /bin/rm -f build/speech.new
step /bin/cp "$bin_path/speech" build/speech.new

# Drop the local symbol table before signing; stripping a signed binary
# invalidates the signature, and SwiftPM ad-hoc signs its own output so there is
# always one to invalidate.
step /usr/bin/strip -x build/speech.new

# Ad hoc, and deliberately without --preserve-metadata: whatever entitlements
# the linker's signature carried are dropped, get-task-allow included, which
# notarization rejects. Checked rather than trusted, along with the strip.
step /usr/bin/codesign -s - build/speech.new
step ./tools/check-release-binary.sh build/speech.new

# transcribe.cpp's xcframework is a *dynamic* library, unlike FluidAudio's
# NemoTextProcessing, which links statically and leaves nothing to ship. So
# `speech` carries `@rpath/CTranscribe.framework/...` and does not run without
# it: a binary copied on its own dies at launch with a dyld error, which is how
# this was found - every test in test.sh aborting with "Library not loaded".
#
# SwiftPM already writes `@loader_path` into the binary's rpaths, so the
# framework only has to sit beside the binary. That also means whoever embeds
# `speech` embeds them as a pair - for Speech.app, both go into
# Contents/Support/ and the deep signing pass covers the framework too.
#
# Signed before the binary and separately: a nested framework carries its own
# signature, and signing the binary does not seal it.
fw="CTranscribe.framework"
if [ -d "$bin_path/$fw" ]; then
    step /bin/rm -rf "build/$fw.new"
    step /bin/cp -R "$bin_path/$fw" "build/$fw.new"
    # Stripped like the binary: the xcframework's library arrives with its
    # local symbols. Through Versions/Current so the file is stripped in place
    # and the framework's symlinks stay symlinks; its exported symbols are
    # global and survive -x.
    step /usr/bin/strip -x "build/$fw.new/Versions/Current/CTranscribe"
    # -f because SwiftPM already ad-hoc signed it and the strip invalidated that
    # signature; codesign refuses to replace one otherwise.
    step /usr/bin/codesign -f -s - "build/$fw.new"
    step ./tools/check-release-binary.sh "build/$fw.new"
    # The previous copy is moved aside rather than deleted first, so a failed
    # rename leaves a working framework behind instead of none at all.
    step /bin/rm -rf "build/$fw.old"
    if [ -d "build/$fw" ]; then
        step /bin/mv "build/$fw" "build/$fw.old"
    fi
    step /bin/mv "build/$fw.new" "build/$fw"
    step /bin/rm -rf "build/$fw.old"
else
    # Not a warning: `speech` carries an @rpath reference to this framework, so
    # a build that cannot find it produces a binary that dies at dyld. Failing
    # here is the difference between a broken build and a broken release.
    fail "$fw not found in $bin_path; build/speech would not launch"
fi

# The built-in model catalog travels beside the binary the same way: `speech`
# reads speech-catalog/*.json at startup and refuses to run without it. Swapped
# in whole, so a reader never sees half of the old files and half of the new.
cat_dir="speech-catalog"
step /bin/rm -rf "build/$cat_dir.new"
step /bin/cp -R catalog "build/$cat_dir.new"
step /bin/rm -rf "build/$cat_dir.old"
if [ -d "build/$cat_dir" ]; then
    step /bin/mv "build/$cat_dir" "build/$cat_dir.old"
fi
step /bin/mv "build/$cat_dir.new" "build/$cat_dir"
step /bin/rm -rf "build/$cat_dir.old"

step /bin/mv build/speech.new build/speech

if [ -d "$bin_path/speech.dSYM" ]; then
    step /bin/rm -rf build/speech.dSYM.new
    step /bin/cp -R "$bin_path/speech.dSYM" build/speech.dSYM.new
    step /bin/rm -rf build/speech.dSYM
    step /bin/mv build/speech.dSYM.new build/speech.dSYM
fi

step /usr/bin/lipo -info build/speech

# The reminders last, where nothing scrolls past them: the vendor step and the
# package update run before a build log that is hundreds of lines long, so what
# they found gets said again here. The transcribe.cpp one reads what the vendor
# step already found - no second network call - and a reminder that fails to
# print is still not a failed build, which is why its status is not acted on.
./tools/vendor-transcribe.sh --report-upstream
if [ "$transcribe_moved" = "yes" ]; then
    echo "note: transcribe.cpp moved to a new release (see above the build log). Review" >&2
    echo "      and commit patches/transcribe.cpp/PIN, and re-measure the ggml rows." >&2
fi
case "$update_result" in
    changed)
        echo "note: the package update moved the pins (listed above the build log)." >&2
        echo "      Review and commit Package.resolved and Sources/speech/Environment.swift," >&2
        echo "      and regenerate docs/models.catalog.tsv (see test.sh)." >&2
        ;;
    failed)
        echo "WARNING: the package update failed (see above the build log), so this is a" >&2
        echo "         build of the pins in Package.resolved as they were. --no-update" >&2
        echo "         skips the attempt." >&2
        ;;
esac

echo "Done."
