#!/bin/bash
# update-packages.sh - move one of speech's two SwiftPM dependency graphs to the
# newest versions its manifest allows, and say what moved.
#
# Usage: tools/update-packages.sh root|speech-mlx
#
#   root        Package.swift and the Package.resolved beside it (build.sh)
#   speech-mlx  Helpers/speech-mlx/project.yml and the Package.resolved inside
#               the project generated from it (build-speech-mlx.sh, which
#               regenerates that project before calling this)
#
# build.sh and build-speech-mlx.sh run this before every build unless they are
# given --no-update. The manifests declare ranges (`from:`), and the committed
# Package.resolved records the exact versions a build used, so an update lands
# as a diff of that file to review and commit rather than as a silent change
# under a recorded measurement. --no-update builds exactly what the file pins.
#
# What it does, in order:
#
#   1. Copies Package.resolved into a temp folder. Every failure below, and an
#      interrupt, puts it back, so a network outage or a version conflict leaves
#      the pins exactly as they were and the build can go on with them.
#
#   2. Resolves to the newest allowed versions.
#      - root: `swift package update`. Measured 2026-10-15: starting from a
#        0.15.6 checkout it moved FluidAudio to 0.17.7, and a second run checked
#        nothing out again, so the build after it stays incremental. It writes
#        Package.resolved before it downloads binary artifacts, so a failure late
#        in the run has already moved the pins - which is why step 1 exists.
#      - speech-mlx: there is no `xcodebuild -updatePackages`, and
#        -resolvePackageDependencies honors an existing Package.resolved, so the
#        file is removed first. That alone is not enough: with no Package.resolved,
#        SwiftPM still prefers whatever is checked out whenever it satisfies the
#        ranges (measured in mlx-agent on 2026-10-15, where ten packages moved
#        DOWN). So the resolve runs in a derived-data folder of its own,
#        Helpers/speech-mlx/build/package-update, whose checkouts are removed
#        before and after and whose clone cache is kept for the next run. The
#        build's own folder is left alone, so the build that follows re-checks-out
#        only what moved instead of recompiling MLX from scratch every time.
#
#   3. Copies the new versions into the literals the binaries report:
#      fluidAudioVersion in Sources/speech/Environment.swift, and mlxAudio and
#      mlxSwift in Helpers/speech-mlx/Sources/speech-mlx/Version.swift. Neither
#      library exposes a runtime version, and those strings are written beside
#      every measurement, so a stale one would credit a number to the wrong
#      library.
#
#   4. Prints which pins moved, then compares each direct dependency with its
#      newest release tag upstream. A gap there means a range somewhere in the
#      graph blocks the release (mlx-swift-lm holds mlx-swift to its own minor
#      version, for instance), which no resolver output says.
#
# Exit status: 0 updated, or already current; 1 failed, previous pins restored;
# 2 usage error; 3 failed AND the previous pins could not be restored (the
# message says how to get them back); 4 the pins moved but a version literal
# could not be rewritten to match; 128+N interrupted by signal N.

SCRIPT_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -P -- "$SCRIPT_DIR/.." && pwd)"
PIN_AWK="$SCRIPT_DIR/package_pin_versions.awk"

usage() {
    echo "Usage: $0 root|speech-mlx"
    echo "  Update the root package graph (build.sh) or the speech-mlx helper's"
    echo "  (build-speech-mlx.sh) to the newest versions its manifest allows."
}

GRAPH=""
while [ $# -gt 0 ]; do
    case "$1" in
        root|speech-mlx) GRAPH="$1" ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "update-packages.sh: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done
if [ -z "$GRAPH" ]; then
    usage >&2
    exit 2
fi

# LITERALS: one "identity file constant" per line, the file relative to REPO_ROOT.
case "$GRAPH" in
    root)
        MANIFEST="$REPO_ROOT/Package.swift"
        RESOLVED="$REPO_ROOT/Package.resolved"
        RESOLVED_SHOWN="Package.resolved"
        SCRATCH=""
        LITERALS="fluidaudio Sources/speech/Environment.swift fluidAudioVersion"
        ;;
    speech-mlx)
        HELPER="$REPO_ROOT/Helpers/speech-mlx"
        PROJECT="$HELPER/speech-mlx.xcodeproj"
        MANIFEST="$HELPER/project.yml"
        RESOLVED="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        RESOLVED_SHOWN="Helpers/speech-mlx/speech-mlx.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        SCRATCH="$HELPER/build/package-update"
        LITERALS="mlx-audio-swift Helpers/speech-mlx/Sources/speech-mlx/Version.swift mlxAudio
mlx-swift Helpers/speech-mlx/Sources/speech-mlx/Version.swift mlxSwift"
        ;;
esac

say() { echo "update-packages ($GRAPH): $*" >&2; }

# Globals rather than locals because the signal handler has to see them.
WORK_DIR=""
BACKUP=""
PINS_MOVED="no"

cleanup() {
    # Only ever remove the folder this run created; never an inherited or empty value.
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        /bin/rm -rf "$WORK_DIR"
    fi
    # The scratch checkouts are a few hundred MB that nothing reads between runs.
    if [ -n "$SCRATCH" ]; then
        /bin/rm -rf "$SCRATCH/SourcePackages/checkouts" "$SCRATCH/SourcePackages/workspace-state.json"
    fi
}

# Put the pins back as they were before this run: the saved copy, or no file if
# there was none. Always discards what the resolve wrote, since SwiftPM writes
# Package.resolved in place and an interrupt can leave it truncated. Staged under
# a temp name in the same folder and renamed, so a second signal cannot leave the
# real path half-written. Returns 0 when the previous state is back.
restore_pins() {
    if [ -z "$BACKUP" ]; then
        /bin/rm -f "$RESOLVED"
        return $?
    fi
    [ -f "$BACKUP" ] || return 1
    local _staged="$RESOLVED.restoring.$$"
    /bin/cp -f "$BACKUP" "$_staged"
    local _cp_status=$?
    if [ "$_cp_status" -ne 0 ]; then
        /bin/rm -f "$_staged"
        return 1
    fi
    /bin/mv -f "$_staged" "$RESOLVED"
}

# When the restore itself failed, how to get the pins back, into RECOVERY_HINT.
# The backup is the right source, not git, since the pins being replaced may be
# an uncommitted upgrade; its folder is then kept (cleanup skips it once WORK_DIR
# is cleared) and named. Sets globals rather than printing, because a $(...)
# caller would clear WORK_DIR in a subshell.
RECOVERY_HINT=""
set_recovery_hint() {
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        WORK_DIR=""
        RECOVERY_HINT="copy it back from the backup this run kept: /bin/cp '$BACKUP' '$RESOLVED'"
    else
        RECOVERY_HINT="recover the committed one with: git -C '$REPO_ROOT' checkout -- '$RESOLVED_SHOWN'"
    fi
}

# Restore the pins, then exit 1 with "$1", or 3 when the restore failed too. A
# full disk is a likely cause of the failure being reported, and then the
# restore's copy can fail as well; saying "restored" there would be false.
fail_restoring() {
    restore_pins
    local _restored=$?
    if [ "$_restored" -eq 0 ]; then
        say "$1"
        say "Package.resolved is back as it was before this run."
        cleanup
        exit 1
    fi
    set_recovery_hint
    say "$1 - and could NOT restore $RESOLVED_SHOWN; $RECOVERY_HINT"
    cleanup
    exit 3
}

on_signal() {
    echo >&2
    if [ "$PINS_MOVED" = "yes" ]; then
        restore_pins
        local _restored=$?
        if [ "$_restored" -eq 0 ]; then
            say "interrupted - Package.resolved is back as it was before this run"
        else
            set_recovery_hint
            say "interrupted - could NOT restore $RESOLVED_SHOWN; $RECOVERY_HINT"
        fi
    fi
    cleanup
    exit "$1"
}

trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
trap 'on_signal 131' QUIT

pin_versions() { /usr/bin/awk -f "$PIN_AWK" "$1"; }

# The version of identity $2 in a pin table $1 (pin_versions output).
pin_of() { printf '%s\n' "$1" | /usr/bin/awk -v id="$2" '$1 == id { $1 = ""; sub(/^ /, ""); print }'; }

# Older of two versions, by sort -V.
lower_of() { printf '%s\n%s\n' "$1" "$2" | /usr/bin/sort -V | /usr/bin/head -1; }

# The value of `static let NAME = "..."` in a Swift file, or nothing.
literal_value() {
    /usr/bin/sed -n "s/^[[:space:]]*static let $2 = \"\([^\"]*\)\".*/\1/p" "$1" | /usr/bin/head -1
}

report_changes() {
    local _old_pins="$1"
    local _new_pins="$2"
    local _id
    local _version
    printf '%s\n' "$_new_pins" | while read -r _id _version; do
        local _old="$(pin_of "$_old_pins" "$_id")"
        if [ -z "$_old" ]; then
            echo "    $_id: added at $_version"
        elif [ "$_old" != "$_version" ]; then
            case "$_old $_version" in
                *rev*)
                    echo "    $_id: $_old -> $_version"
                    ;;
                *)
                    local _lower="$(lower_of "$_old" "$_version")"
                    if [ "$_lower" = "$_version" ]; then
                        echo "    $_id: $_old -> $_version   WARNING: went DOWN (a narrowed range or a yanked tag?)"
                    else
                        echo "    $_id: $_old -> $_version"
                    fi
                    ;;
            esac
        fi
    done
    printf '%s\n' "$_old_pins" | while read -r _id _version; do
        local _new="$(pin_of "$_new_pins" "$_id")"
        if [ -n "$_id" ] && [ -z "$_new" ]; then
            echo "    $_id: removed (was $_version)"
        fi
    done
}

# The direct dependencies' URLs, from the manifest.
direct_urls() {
    case "$GRAPH" in
        root)
            /usr/bin/sed -n 's/.*\.package(url:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST"
            ;;
        speech-mlx)
            /usr/bin/sed -n 's/^[[:space:]]*url:[[:space:]]*//p' "$MANIFEST" | /usr/bin/tr -d "\"'"
            ;;
    esac
}

# For each direct dependency, the resolved version against the newest release tag
# upstream. Informational: an unreachable remote is reported, never fatal.
report_held_back() {
    local _by_location="$(/usr/bin/awk -v by_location=1 -f "$PIN_AWK" "$RESOLVED")"
    local _urls="$(direct_urls)"
    local _held="no"
    local _url
    local _tags
    echo "  Newest upstream releases of the direct dependencies:"
    for _url in $_urls; do
        local _name="$(/usr/bin/basename "$_url" .git)"
        local _key="$(printf '%s\n' "$_url" | /usr/bin/awk '{ l = tolower($0); sub(/\/+$/, "", l); sub(/\.git$/, "", l); print l }')"
        local _resolved="$(printf '%s\n' "$_by_location" | /usr/bin/awk -v key="$_key" '$1 == key { print $2 }')"
        # No prompt, and no hang on a stalled connection: under 1 KB/s for 20 s
        # gives up, and the remote is reported as unreachable.
        _tags="$(GIT_TERMINAL_PROMPT=0 /usr/bin/git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 ls-remote --tags --refs "$_url" 2>/dev/null)"
        local _git_status=$?
        if [ "$_git_status" -ne 0 ]; then
            printf '    %-20s %-10s %s\n' "$_name" "${_resolved:-?}" "(could not reach $_url)"
            continue
        fi
        local _latest="$(printf '%s\n' "$_tags" | /usr/bin/sed -n 's#.*refs/tags/v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' | /usr/bin/sort -V | /usr/bin/tail -1)"
        if [ -z "$_resolved" ]; then
            printf '    %-20s %-10s %s\n' "$_name" "?" "(not found in Package.resolved${_latest:+; newest tag is $_latest})"
            continue
        fi
        if [ -z "$_latest" ] || [ "$_resolved" = "$_latest" ]; then
            printf '    %-20s %-10s %s\n' "$_name" "$_resolved" "${_latest:+(newest)}"
            continue
        fi
        local _lower="$(lower_of "$_resolved" "$_latest")"
        if [ "$_lower" = "$_resolved" ]; then
            printf '    %-20s %-10s %s\n' "$_name" "$_resolved" "HELD BACK: $_latest is out"
            _held="yes"
        else
            printf '    %-20s %-10s %s\n' "$_name" "$_resolved" "(newest tag is $_latest)"
        fi
    done
    if [ "$_held" = "yes" ]; then
        echo "  A version range blocks a newer release. If it is the range in"
        echo "  ${MANIFEST#$REPO_ROOT/}, raise it there; if it is another package's,"
        echo "  it has to wait for that package."
    fi
}

if [ ! -f "$PIN_AWK" ]; then
    say "no $PIN_AWK - it ships beside this script"
    exit 1
fi
if [ "$GRAPH" = "speech-mlx" ] && [ ! -d "$PROJECT" ]; then
    say "no $PROJECT - build-speech-mlx.sh generates it before calling this"
    exit 1
fi

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/speech-update-packages.XXXXXX")"
if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    say "mktemp failed"
    exit 1
fi
LOG="$WORK_DIR/resolve.log"

OLD_PINS=""
if [ -f "$RESOLVED" ]; then
    BACKUP="$WORK_DIR/Package.resolved"
    /bin/cp -f "$RESOLVED" "$BACKUP"
    cp_status=$?
    if [ "$cp_status" -ne 0 ]; then
        say "could not back up $RESOLVED_SHOWN"
        cleanup
        exit 1
    fi
    OLD_PINS="$(pin_versions "$BACKUP")"
fi

say "updating to the newest versions ${MANIFEST#$REPO_ROOT/} allows..."

# From here until the new pins are checked, the signal handler restores them.
PINS_MOVED="yes"
case "$GRAPH" in
    root)
        /usr/bin/swift package --package-path "$REPO_ROOT" --scratch-path "$REPO_ROOT/build" update > "$LOG" 2>&1
        resolve_status=$?
        resolve_command="swift package update"
        ;;
    speech-mlx)
        # Checked, not assumed: a Package.resolved that survives is honored, and
        # the "update" would then report pins it never re-resolved.
        /bin/rm -f "$RESOLVED"
        rm_status=$?
        if [ "$rm_status" -eq 0 ]; then
            /bin/rm -rf "$SCRATCH/SourcePackages/checkouts" "$SCRATCH/SourcePackages/workspace-state.json"
            rm_status=$?
        fi
        if [ "$rm_status" -ne 0 ]; then
            fail_restoring "could not remove $RESOLVED_SHOWN or the stale checkouts in $SCRATCH"
        fi
        /usr/bin/xcodebuild \
            -project "$PROJECT" \
            -scheme speech-mlx \
            -derivedDataPath "$SCRATCH" \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            -resolvePackageDependencies > "$LOG" 2>&1
        resolve_status=$?
        resolve_command="xcodebuild -resolvePackageDependencies"
        ;;
esac
if [ "$resolve_status" -ne 0 ]; then
    # A version conflict is the informative failure here, so show what the
    # resolver said rather than only that it failed.
    /usr/bin/tail -20 "$LOG" | /usr/bin/sed 's/^/    /' >&2
    fail_restoring "$resolve_command failed (exit $resolve_status)"
fi
if [ ! -f "$RESOLVED" ]; then
    fail_restoring "$resolve_command wrote no Package.resolved"
fi

# Existence is not enough: a resolve that died mid-write leaves a file that
# parses to nothing, which would compare unequal to the old pins and be reported
# as an ordinary change with no versions under it.
NEW_PINS="$(pin_versions "$RESOLVED")"
if [ -z "$NEW_PINS" ]; then
    fail_restoring "$resolve_command produced a Package.resolved with no pins in it"
fi

# Every literal is checked before any is written, so a missing one leaves the
# sources untouched along with the restored pins.
while read -r lit_id lit_file lit_name; do
    [ -n "$lit_id" ] || continue
    lit_version="$(pin_of "$NEW_PINS" "$lit_id")"
    if [ -z "$lit_version" ]; then
        fail_restoring "$lit_id is not in the new Package.resolved, so $lit_file cannot say which version it reports"
    fi
    lit_current="$(literal_value "$REPO_ROOT/$lit_file" "$lit_name")"
    if [ -z "$lit_current" ]; then
        fail_restoring "no 'static let $lit_name = \"...\"' in $lit_file to record the $lit_id version in"
    fi
done <<EOF
$LITERALS
EOF
PINS_MOVED="no"

# The pins are final from here; a literal that fails to update is reported and
# exits 4, because a binary built now would report the wrong version.
literal_status=0
while read -r lit_id lit_file lit_name; do
    [ -n "$lit_id" ] || continue
    lit_version="$(pin_of "$NEW_PINS" "$lit_id")"
    lit_current="$(literal_value "$REPO_ROOT/$lit_file" "$lit_name")"
    [ "$lit_current" = "$lit_version" ] && continue
    /usr/bin/sed -i '' "s/^\([[:space:]]*static let $lit_name = \"\)[^\"]*\"/\1$lit_version\"/" "$REPO_ROOT/$lit_file"
    sed_status=$?
    lit_written="$(literal_value "$REPO_ROOT/$lit_file" "$lit_name")"
    if [ "$sed_status" -ne 0 ] || [ "$lit_written" != "$lit_version" ]; then
        say "could not set $lit_name in $lit_file to $lit_version; it still says ${lit_written:-nothing}"
        literal_status=4
    else
        say "$lit_file: $lit_name $lit_current -> $lit_version"
    fi
done <<EOF
$LITERALS
EOF

if [ -z "$BACKUP" ]; then
    say "resolved from scratch (there was no Package.resolved) - review and commit $RESOLVED_SHOWN"
    printf '%s\n' "$NEW_PINS"
elif [ "$NEW_PINS" != "$OLD_PINS" ]; then
    say "package versions changed - review and commit $RESOLVED_SHOWN:"
    report_changes "$OLD_PINS" "$NEW_PINS"
else
    /usr/bin/cmp -s "$BACKUP" "$RESOLVED"
    cmp_status=$?
    if [ "$cmp_status" -eq 0 ]; then
        say "already at the newest allowed versions"
    else
        # Every pin landed where it was, but SwiftPM rewrote originHash, a hash
        # of the dependency declarations. Said, because the git diff otherwise
        # looks like an upgrade.
        say "versions unchanged; only Package.resolved metadata was rewritten (a manifest edit changes its originHash)"
    fi
fi

report_held_back

cleanup
exit "$literal_status"
