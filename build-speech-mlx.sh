#!/bin/sh
# build-speech-mlx.sh - build the optional MLX helper, speech-mlx.
#
# Usage:
#   ./build-speech-mlx.sh               # produces build/speech-mlx and its bundles
#
# Separate from build.sh because the helper is separate from the product.
# `speech` runs with no MLX at all: with no helper beside it, the `mlx` rows
# report unavailable with a reason, exactly as a missing engine target already
# does. Nothing here is needed to build, test or ship the main binary, and
# nothing here is on its dependency graph - see Helpers/speech-mlx/project.yml
# for why that needed a separate project rather than a second SwiftPM product.
#
# WHY xcodebuild AND NOT swift build. Measured, not inherited: a `swift build`
# of an MLX binary links and then dies on its first array operation with
# "Failed to load the default metallib. library not found" repeated once per
# search path, because SwiftPM's command line has no rule for compiling
# mlx-swift's Metal kernels and never produces mlx-swift_Cmlx.bundle.
#
# Consequence for whoever ships this: the binary does not travel alone. It needs
# the resource bundles copied beside it, the same way build/speech needs
# CTranscribe.framework, and for the same reason - a copy of the binary on its
# own is a binary that aborts.

set -e

cd "$(dirname "$0")"

project="Helpers/speech-mlx/speech-mlx.xcodeproj"

# project.yml is the source of truth and the .xcodeproj is generated from it.
# Regenerating here rather than comparing timestamps: git does not preserve
# modification times, so on a fresh clone "is the spec newer than the project"
# is an accident rather than an answer. XcodeGen is idempotent - regenerating an
# unchanged spec produces a byte-identical project - so this costs nothing and
# removes the class of failure where a build silently uses the previous spec.
if command -v xcodegen > /dev/null 2>&1; then
    before=""
    [ -f "$project/project.pbxproj" ] && before="$(md5 -q "$project/project.pbxproj")"
    ( cd Helpers/speech-mlx && xcodegen generate ) > /dev/null
    # Regeneration is idempotent for a given XcodeGen, but XcodeGen itself is a
    # floor rather than an exact pin - the one dependency here that is - so a
    # different local version can rewrite the project without the spec having
    # changed. Say so rather than leaving a dirty tree to be discovered later.
    if [ -n "$before" ] && [ "$before" != "$(md5 -q "$project/project.pbxproj")" ]; then
        echo "note: xcodegen rewrote $project/project.pbxproj." >&2
        echo "      Review the diff and commit it, or check your xcodegen version." >&2
    fi
elif [ ! -d "$project" ]; then
    echo "error: $project is missing and xcodegen is not installed." >&2
    echo "Install it with: brew install xcodegen" >&2
    exit 1
else
    echo "note: xcodegen not installed; building the committed project as it stands." >&2
fi

# Xcode 26 ships the Metal compiler as a separately downloaded component, and
# without it every shader compile fails with a message about the toolchain
# rather than about this project.
if ! xcrun --find metal > /dev/null 2>&1; then
    echo "error: no Metal compiler." >&2
    echo "Install it once per machine: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

derived="Helpers/speech-mlx/build"

# The two -skip flags trust the package plugin and the swift-syntax macros in
# this graph; without them xcodebuild stops on a validation prompt that no
# script can answer.
#
# ARCHS is passed here rather than set in project.yml, and that is not a style
# choice. Per-target settings in the spec apply to our targets only: the package
# dependencies build as their own generated projects and take their settings
# from their own manifests, so an ARCHS there is inert. Measured on this graph -
# with ARCHS only in the spec, every dependency compiled twice, arm64 and
# x86_64, for a binary that is arm64 alone. A command-line override is the one
# form that reaches package targets.
xcodebuild \
    -project "$project" \
    -scheme speech-mlx \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Release \
    -derivedDataPath "$derived" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    build

products="$derived/Build/Products/Release"
[ -x "$products/speech-mlx" ] || {
    echo "error: no speech-mlx in $products" >&2
    exit 1
}

mkdir -p build

# The Metal library is not optional and not something to warn about: without it
# the binary aborts on its first array operation, so a build that cannot find it
# has produced something that only looks like a helper.
metal_bundle="mlx-swift_Cmlx.bundle"
[ -d "$products/$metal_bundle" ] || {
    echo "error: $metal_bundle not found in $products; build/speech-mlx would abort at startup" >&2
    exit 1
}
[ -f "$products/$metal_bundle/Contents/Resources/default.metallib" ] || {
    echo "error: $metal_bundle carries no default.metallib" >&2
    exit 1
}

# Every resource bundle the graph produced, not a list written down here: the
# set depends on the dependency versions, and a bundle left behind is a runtime
# failure rather than a build one. Replaced wholesale rather than merged,
# because a stale resource beside a new binary is the same abort.
for bundle in "$products"/*.bundle; do
    [ -d "$bundle" ] || continue
    name="$(basename "$bundle")"
    rm -rf "build/$name.new"
    cp -R "$bundle" "build/$name.new"
    codesign -f -s - "build/$name.new"
    rm -rf "build/$name.old"
    [ -d "build/$name" ] && mv "build/$name" "build/$name.old"
    mv "build/$name.new" "build/$name"
    rm -rf "build/$name.old"
done

# Assembled under a temporary name and renamed into place only when finished,
# like build.sh: a copy that dies partway would otherwise leave a truncated
# binary that still looks like a build product.
rm -f build/speech-mlx.new
cp "$products/speech-mlx" build/speech-mlx.new
strip -x build/speech-mlx.new
# -f because xcodebuild already signed its product and, unlike SwiftPM's, that
# signature survives the strip; codesign then refuses to sign an already signed
# binary and under `set -e` that ends the build after everything worked.
codesign -f -s - build/speech-mlx.new

# The notices for everything statically linked into what was just built, and
# they are written BEFORE the binary is moved into place. `set -e` then makes
# the pair consistent in both directions: a generator that fails leaves the
# previous binary beside the previous notices, rather than a new binary beside
# a file describing the dependency graph of an older build. The pins come out
# of the resolution xcodebuild just used, so the file cannot lag what it sits
# beside, and it is a hard failure for the same reason it is generated rather
# than written by hand - an incomplete notices file passes every check that
# only asks whether one exists.
Helpers/speech-mlx/tools/generate-third-party-notices.sh \
    --bundles build --output build/speech-mlx-THIRD-PARTY-NOTICES.txt

mv build/speech-mlx.new build/speech-mlx


# Prove it launches and reaches the GPU rather than trusting that it linked.
# This is the whole reason the helper answers a handshake before reading a
# request: the failure this catches is one the build cannot see.
#
# With one carve-out, the same one test.sh makes: a process with no GPU access
# dies inside MTLCopyAllDevices() before it can say anything, and that is a
# property of where this is running rather than of what was just built.
# Reporting a good artifact as a failed build would be worse than saying so.
handshake_err="$(mktemp -t speech-mlx-handshake)"
if printf '{"op":"bye"}\n' | ./build/speech-mlx > /dev/null 2> "$handshake_err"; then
    :
elif grep -q 'NSRangeException' "$handshake_err" \
    && grep -qE 'MTLCopyAllDevices|mlx4core5metal6Device' "$handshake_err"; then
    echo "note: this process cannot reach the GPU, so the handshake could not be" >&2
    echo "      checked. The build itself is complete." >&2
else
    echo "error: build/speech-mlx did not complete a handshake." >&2
    sed 's/^/  /' "$handshake_err" >&2
    rm -f "$handshake_err"
    exit 1
fi
rm -f "$handshake_err"

lipo -info build/speech-mlx

echo "Done."
