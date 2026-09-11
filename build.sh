#!/bin/sh
# Build speech as a command-line binary.
#
# Usage:
#   ./build.sh                   # produces build/speech (arm64, ad-hoc signed)
#   ./build.sh arm64             # the only supported architecture (see below)
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

set -e

cd "$(dirname "$0")"

want="${1:-arm64}"
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
    *) echo "usage: ./build.sh [arm64]" >&2; exit 1 ;;
esac

# SwiftPM's scratch directory, in the visible build/ rather than a hidden
# .build, alongside the binary handed to consumers. SwiftPM only creates
# subdirectories in here, so build/speech does not collide with anything it owns.
scratch="build"

# `swift build` runs lipo itself when given more than one --arch, so there is no
# separate universal step. Repeating the flags for --show-bin-path is not a
# rebuild: it re-resolves and prints the path, which differs by architecture
# selection, so it must not be hardcoded.
# shellcheck disable=SC2086  # $arch_flags must word-split into separate args.
swift build -c release --scratch-path "$scratch" $arch_flags
# shellcheck disable=SC2086
bin_path="$(swift build -c release --scratch-path "$scratch" $arch_flags --show-bin-path)"

# Assemble under a temporary name and rename into place only when the binary is
# finished. A cp that dies partway - full disk, killed build - would otherwise
# leave a truncated binary that still looks like a build product. A rename
# within one filesystem is atomic.
rm -f build/speech.new
cp "$bin_path/speech" build/speech.new

# Drop the local symbol table before signing; stripping a signed binary
# invalidates the signature, and SwiftPM ad-hoc signs its own output so there is
# always one to invalidate.
strip -x build/speech.new

codesign -s - build/speech.new

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
    rm -rf "build/$fw.new"
    cp -R "$bin_path/$fw" "build/$fw.new"
    # -f because SwiftPM already ad-hoc signed it and codesign refuses
    # to re-sign otherwise, which under `set -e` aborts the build.
    codesign -f -s - "build/$fw.new"
    # The previous copy is moved aside rather than deleted first, so a failed
    # rename leaves a working framework behind instead of none at all.
    rm -rf "build/$fw.old"
    [ -d "build/$fw" ] && mv "build/$fw" "build/$fw.old"
    mv "build/$fw.new" "build/$fw"
    rm -rf "build/$fw.old"
else
    # Not a warning: `speech` carries an @rpath reference to this framework, so
    # a build that cannot find it produces a binary that dies at dyld. Failing
    # here is the difference between a broken build and a broken release.
    echo "error: $fw not found in $bin_path; build/speech would not launch" >&2
    exit 1
fi

# The built-in model catalog travels beside the binary the same way: `speech`
# reads speech-catalog/*.json at startup and refuses to run without it. Swapped
# in whole, so a reader never sees half of the old files and half of the new.
cat_dir="speech-catalog"
rm -rf "build/$cat_dir.new"
cp -R catalog "build/$cat_dir.new"
rm -rf "build/$cat_dir.old"
[ -d "build/$cat_dir" ] && mv "build/$cat_dir" "build/$cat_dir.old"
mv "build/$cat_dir.new" "build/$cat_dir"
rm -rf "build/$cat_dir.old"

mv build/speech.new build/speech

if [ -d "$bin_path/speech.dSYM" ]; then
    rm -rf build/speech.dSYM.new
    cp -R "$bin_path/speech.dSYM" build/speech.dSYM.new
    rm -rf build/speech.dSYM
    mv build/speech.dSYM.new build/speech.dSYM
fi

lipo -info build/speech

echo "Done."
