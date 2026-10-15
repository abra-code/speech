#!/bin/bash
# check-release-binary.sh - refuse a shipped Mach-O file that carries what a
# release must not: the get-task-allow entitlement, or debug information.
#
# Usage: tools/check-release-binary.sh <file-or-folder>...
#
# build.sh and build-speech-mlx.sh run this on everything they put in build/.
# A folder is searched for Mach-O files (a framework, a resource bundle); a
# folder with none in it passes, since a bundle of shaders and JSON carries
# nothing to check.
#
# get-task-allow lets any process attach a debugger, and notarization rejects a
# binary that has it. Xcode injects it whenever it signs to run locally, Release
# included (CODE_SIGN_INJECT_BASE_ENTITLEMENTS) - mlx-agent shipped it that way
# and failed notarization. Both build scripts re-sign ad hoc without
# --preserve-metadata, which drops it, but a later "keep the entitlements"
# change would bring it back without a word, so it is checked rather than
# trusted. A downstream signer that preserves entitlements would carry it into
# the notarized app.
#
# Debug information is checked two ways: a __DWARF segment (DWARF linked into
# the file itself), and debug-map entries in the symbol table (N_STAB records
# such as SO, OSO and FUN, which point a debugger at the object files of the
# build machine and name its paths). `strip -x` removes the latter. The one
# entry ld always writes, `OPT radr://5614542`, is a linker marker, not debug
# information, and is allowed. Debug information belongs in the .dSYM beside
# the binary, which is not shipped inside it.
#
# Exit status: 0 every file passed; 1 at least one did not (each failure is
# named); 2 usage error.

if [ $# -eq 0 ]; then
    echo "Usage: $0 <file-or-folder>..." >&2
    exit 2
fi

failures=0

report() {
    echo "check-release-binary: $1: $2" >&2
    failures=$((failures + 1))
}

check_file() {
    local _file="$1"

    local _entitlements
    _entitlements="$(/usr/bin/codesign -d --entitlements :- "$_file" 2>/dev/null)"
    local _codesign_status=$?
    if [ "$_codesign_status" -ne 0 ]; then
        report "$_file" "not signed, or its signature cannot be read (codesign exit $_codesign_status)"
    else
        case "$_entitlements" in
            *get-task-allow*) report "$_file" "has the get-task-allow entitlement, which notarization rejects" ;;
        esac
    fi

    local _load_commands
    _load_commands="$(/usr/bin/otool -l "$_file" 2>/dev/null)"
    local _otool_status=$?
    if [ "$_otool_status" -ne 0 ]; then
        report "$_file" "otool could not read its load commands (exit $_otool_status)"
    else
        case "$_load_commands" in
            *"segname __DWARF"*) report "$_file" "has a __DWARF segment (debug information linked in)" ;;
        esac
    fi

    # nm -ap prints a debug-map entry as: <value> - <sect> <desc> <TYPE> <name>
    local _symbols
    _symbols="$(/usr/bin/nm -ap "$_file" 2>/dev/null)"
    local _nm_status=$?
    if [ "$_nm_status" -ne 0 ]; then
        report "$_file" "nm could not read its symbol table (exit $_nm_status)"
        return
    fi
    local _stabs="$(printf '%s\n' "$_symbols" | /usr/bin/awk '$2 == "-" && $5 != "OPT"' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    if [ "$_stabs" != "0" ]; then
        report "$_file" "has $_stabs debug-map entries in its symbol table (not stripped with strip -x)"
    fi
}

is_macho() {
    local _kind="$(/usr/bin/file -b "$1" 2>/dev/null)"
    case "$_kind" in
        Mach-O*) return 0 ;;
    esac
    return 1
}

checked=0
for target in "$@"; do
    if [ -d "$target" ]; then
        # -type f skips the framework's Versions/Current symlinks, so each file
        # is checked once.
        found="$(/usr/bin/find "$target" -type f)"
        find_status=$?
        if [ "$find_status" -ne 0 ]; then
            report "$target" "could not be searched (find exit $find_status)"
            continue
        fi
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            is_macho "$candidate" || continue
            check_file "$candidate"
            checked=$((checked + 1))
        done <<EOF
$found
EOF
    elif [ -f "$target" ]; then
        if is_macho "$target"; then
            check_file "$target"
            checked=$((checked + 1))
        else
            report "$target" "is not a Mach-O file"
        fi
    else
        report "$target" "does not exist"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "check-release-binary: $failures problem(s) in $checked Mach-O file(s)" >&2
    exit 1
fi
echo "check-release-binary: $checked Mach-O file(s) clean: no get-task-allow, no debug information"
exit 0
