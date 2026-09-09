#!/bin/sh
# build-speech-mlx.sh - build the optional MLX helper, speech-mlx.
#
# Usage:
#   ./build-speech-mlx.sh               # produces build/speech-mlx and its bundles
#   ./build-speech-mlx.sh -h, --help    # this usage (-h and --help both work)
#   ./build-speech-mlx.sh --download-metal-toolchain
#                                       # answer the Metal toolchain question with
#                                       # yes rather than asking, for a run with no
#                                       # terminal to prompt on
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

# ask: prompt when there is a terminal to prompt on and refuse with instructions
# when there is not. A 688 MB download is not something to start behind
# someone's back, and a script that hangs on a prompt nobody can see is worse
# than one that says why it stopped.
download_metal="ask"

while [ $# -gt 0 ]; do
    case "$1" in
        --download-metal-toolchain) download_metal="yes" ;;
        -h|--help)
            echo "Usage: $0 [-h|--help] [--download-metal-toolchain]"
            echo
            echo "Builds build/speech-mlx and the resource bundles that have to sit"
            echo "beside it. With --download-metal-toolchain, a missing Metal"
            echo "component is downloaded without asking - for a run with no terminal"
            echo "to prompt on (stdin or stderr redirected), where the question would"
            echo "otherwise go unanswered."
            exit 0
            ;;
        *)
            echo "error: unknown argument: '$1'" >&2
            echo "Usage: $0 [-h|--help] [--download-metal-toolchain]" >&2
            exit 2
            ;;
    esac
    shift
done

# Xcode 26 ships the Metal compiler as a separately downloaded component, and
# without it every shader compile fails with a message about the toolchain
# rather than about this project. Checked before the project is regenerated:
# it is the cheapest precondition here and the one most likely to fail on a
# fresh machine, and failing first leaves the tree untouched.
#
# WHY THIS RUNS THE COMPILER AND DOES NOT LOOK FOR IT. `xcrun --find metal`
# answers this question wrong: Xcode carries a small stub at
# Toolchains/XcodeDefault.xctoolchain/usr/bin/metal whether or not the component
# is installed, so the lookup succeeds on a machine that cannot compile a single
# shader, and the stub is then what the build runs - the failure arrives
# thousands of lines into xcodebuild's output. Executing the stub is what
# reveals it, and --version is the cheapest thing to ask a compiler that has
# nothing to compile.
#
# Only zero against non-zero is tested, deliberately: measured on Xcode 26.6 the
# stub exits 1 with "cannot execute tool 'metal' due to missing Metal Toolchain",
# while a Command Line Tools developer directory never reaches the stub and
# xcrun's own lookup failure exits 72. Neither number is a contract.
#
# The status is returned in a variable rather than as the function's exit code,
# and that is load-bearing under `set -e`: a call whose status were non-zero
# would end the script here instead of reaching the offer below.
#
# ASKED TWICE, AND WHY NEITHER WAY IS ENOUGH ALONE. xcrun keeps a lookup cache
# in the per-user Darwin temp directory - it does not follow $TMPDIR, so it
# cannot be moved out of the way - and both consulting it and bypassing it have
# a failure mode, measured on Xcode 26.6:
#
#   - The cache can hold a stale positive. Before the component is installed the
#     lookup succeeds and answers with the stub, so a cached probe taken right
#     after a download still runs the stub and still reports the component
#     missing.
#   - A probe that does not use the cache resolves to the stub whenever xcrun
#     cannot write it. Measured with the component installed and the temp
#     directory read-only: `xcrun --no-cache --find metal` answers with the
#     Xcode stub (exit 0) and `xcrun --no-cache metal --version` exits 1
#     reporting the toolchain missing, while the warm cached lookup answers with
#     the installed cryptex. A restricted sandbox or CI container is exactly
#     where that happens, and it would turn a machine whose compiler works into
#     "no Metal compiler".
#
# So the cheap cached question is asked first, and only when it fails is a
# second opinion taken with the cache bypassed. A compiler that runs either way
# is a compiler that is there.
#
# Failing both is not proof of absence, though, and the code below does not
# treat it as such. An unwritable cache with no entry yet for this developer
# directory sends BOTH probes to the stub - measured the same way, forcing a
# cache miss with an equivalent-but-different DEVELOPER_DIR - so an installed
# component looks exactly like a missing one. That state announces itself in the
# output ("couldn't create cache file") and is handled where the download would
# otherwise be offered.
check_metal_compiler() {
    metal_status=0
    metal_output=""
    fresh_output=""
    metal_output="$(xcrun metal --version 2>&1)" || metal_status=$?
    if [ "$metal_status" -ne 0 ]; then
        fresh_status=0
        fresh_output="$(xcrun --no-cache metal --version 2>&1)" || fresh_status=$?
        if [ "$fresh_status" -eq 0 ]; then
            metal_status=0
            metal_output="$fresh_output"
        fi
    fi
}

# Whatever a tool said about why it will not run beats anything guessed here.
# The empty case is spelled out rather than skipped: a tool killed by a signal
# or a policy fails with nothing to say, and a heading followed by nothing reads
# like the script lost the message. `|| :` because this runs under `set -e` and
# ahead of the lines that say what to do about the failure - a sed that died
# must not take that advice down with it.
print_indented() {
    if [ -n "$1" ]; then
        printf '%s\n' "$1" | sed 's/^/  /' >&2 || :
    else
        echo "  (no output)" >&2
    fi
}

check_metal_compiler
if [ "$metal_status" -ne 0 ]; then
    # Only one reason a compiler will not run is fixed by a download. An
    # unaccepted license, a broken xcrun, a DEVELOPER_DIR pointing at nothing -
    # offering to fetch 688 MB for any of those would be a wrong answer
    # delivered slowly, so the rest are reported as they came back. Two
    # spellings because there are two shapes of missing: the stub refusing to
    # run, and no metal on the path at all. Both probes' output is classified,
    # not just the cached one: they can disagree, and a "missing Metal
    # Toolchain" from either is the answer that leads somewhere useful. Joined
    # with a newline so no pattern can match across the seam between them.
    case "$metal_output
$fresh_output" in
        *"missing Metal Toolchain"*|*'unable to find utility "metal"'*)
            : ;;
        *)
            echo "error: the Metal compiler will not run, and not because the toolchain" >&2
            echo "       is missing. xcrun metal --version said:" >&2
            print_indented "$metal_output"
            if [ -n "$fresh_output" ] && [ "$fresh_output" != "$metal_output" ]; then
                echo "       and with its lookup cache bypassed:" >&2
                print_indented "$fresh_output"
            fi
            exit 1
            ;;
    esac

    # A component download needs a full Xcode, so that comes first: Command Line
    # Tools as the active developer directory produces the same "unable to find
    # utility" message and has no xcodebuild to fetch anything with. xcodebuild's
    # own message says which directory is active and why it will not do; it is
    # printed rather than summarized, because a machine can keep Xcode somewhere
    # other than /Applications and a guess would send someone somewhere wrong.
    #
    # Ahead of the cache check below, and that order is deliberate. A read-only
    # temp directory makes xcrun print its cache complaint whatever else is
    # wrong, Command Line Tools included, so the cache branch would otherwise
    # answer a misconfigured developer directory with two remedies that cannot
    # help it. Measured: this check still exits 0 in the unwritable-cache state
    # on a full Xcode, so the genuinely undecidable case still reaches it.
    xcodebuild_status=0
    xcodebuild_output="$(xcodebuild -version 2>&1)" || xcodebuild_status=$?
    if [ "$xcodebuild_status" -ne 0 ]; then
        echo "error: no Metal compiler, and xcodebuild will not run to download one." >&2
        echo "       xcodebuild -version said:" >&2
        print_indented "$xcodebuild_output"
        echo "       If that names a command line tools directory, point xcode-select" >&2
        echo "       at a full Xcode: sudo xcode-select -s /path/to/Xcode.app" >&2
        exit 1
    fi

    # The one state this cannot resolve. With an unwritable lookup cache and no
    # entry yet for this developer directory, xcrun answers with Xcode's stub
    # whichever way it is asked, so an installed component reports itself
    # missing. Neither answer is available here, so neither is guessed - not even
    # with --download-metal-toolchain: 688 MB would as likely reinstall what is
    # already there, and the re-check afterwards would fail for the same reason
    # and call a good install a bad one.
    case "$metal_output
$fresh_output" in
        *"couldn't create cache file"*)
            echo "error: cannot tell whether the Metal compiler is installed. xcrun could" >&2
            echo "       not write its lookup cache, and with no cached entry it answers" >&2
            echo "       with Xcode's stub whether or not the component is there:" >&2
            # One probe's output, not both: in this state they differ only by
            # the random suffix in the cache file's name, so printing the second
            # would be fifteen near-identical lines saying the same thing.
            print_indented "$metal_output"
            echo "       A sandbox or container with a read-only per-user temp directory is" >&2
            echo "       the usual cause. Make it writable and run this again, or install" >&2
            echo "       the component yourself:" >&2
            echo "       xcodebuild -downloadComponent MetalToolchain" >&2
            if [ "$download_metal" = "yes" ]; then
                echo "       --download-metal-toolchain was read and is not being honored" >&2
                echo "       here: with the compiler's presence undecidable, the download" >&2
                echo "       would as likely reinstall what is already there and then be" >&2
                echo "       judged a failure by a re-check with the same blind spot." >&2
            fi
            exit 1
            ;;
    esac

    echo "note: no Metal compiler. Xcode ships it as a separate component, about" >&2
    echo "      688 MB, and without it every shader in this build fails." >&2

    if [ "$download_metal" = "ask" ]; then
        # Both streams, not just stdin. The question goes to stderr, so
        # `./build-speech-mlx.sh 2> build.log` from a terminal leaves stdin a
        # tty while the question itself lands in the log - a read blocking
        # forever on a prompt nobody can see, which is the one outcome this
        # whole arrangement exists to avoid.
        if [ -t 0 ] && [ -t 2 ]; then
            printf 'Download it now (xcodebuild -downloadComponent MetalToolchain)? [y/N] ' >&2
            answer=""
            # `|| :` rather than `|| answer=""`: read returns non-zero at end of
            # input but has already assigned what it read, so clearing the
            # variable would turn a "y" typed without a newline into a no.
            read -r answer || :
            case "$answer" in
                [yY]|[yY][eE][sS]) download_metal="yes" ;;
                *) download_metal="no" ;;
            esac
        else
            download_metal="no"
        fi
    fi

    if [ "$download_metal" != "yes" ]; then
        echo "error: this cannot build without the Metal compiler." >&2
        echo "Install it once per machine: xcodebuild -downloadComponent MetalToolchain" >&2
        echo "Or re-run this script with --download-metal-toolchain to have it do that." >&2
        exit 1
    fi

    echo "== downloading the Metal toolchain ==" >&2
    download_status=0
    xcodebuild -downloadComponent MetalToolchain || download_status=$?
    if [ "$download_status" -ne 0 ]; then
        echo "error: xcodebuild -downloadComponent MetalToolchain exited $download_status." >&2
        echo "       The component installs outside your home directory, so on some" >&2
        echo "       machines it needs administrator rights:" >&2
        echo "       sudo xcodebuild -downloadComponent MetalToolchain" >&2
        exit 1
    fi

    # Asked again rather than assumed: the download can report success while
    # this process still cannot reach the newly mounted toolchain, and that is
    # a much better thing to say here than a shader error later. The stale
    # positive described above is exactly this call's problem, and the second
    # opinion inside the function is what answers it.
    check_metal_compiler
    if [ "$metal_status" -ne 0 ]; then
        echo "error: the component downloaded but the compiler still will not run." >&2
        echo "       Try a new terminal, or xcodebuild -showComponent MetalToolchain." >&2
        print_indented "$metal_output"
        exit 1
    fi
    echo "note: Metal toolchain installed." >&2
fi

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
    # `|| :` for the same reason as in print_indented: under `set -e` a sed that
    # died would end the script here, leaking the temp file below and exiting
    # with sed's status instead of 1.
    sed 's/^/  /' "$handshake_err" >&2 || :
    rm -f "$handshake_err"
    exit 1
fi
rm -f "$handshake_err"

lipo -info build/speech-mlx

echo "Done."
