#!/bin/sh
# GUARD 4 scope: decide WHICH suites a commit has to run.
#
# Decision: the owner, 2026-09-04. The full ~3,500-test run on every branch
# commit was the main cost of committing (and hung twice that day). Branch
# commits now run only the suites that plausibly cover the staged Swift; the
# full suite runs when a merge lands on main — the one commit shape Guard 1
# permits there, and the last gate before main.
#
# Prints ONE line on stdout:
#   FULL      — run the whole suite
#   <regex>   — pass to the runner as `--filter <regex>`
#
# pre-commit calls it with no arguments, so it reads the staged index. Runnable
# standalone for a dry run by passing the file list as arguments:
#   sh .githooks/guard-test-scope.sh AudioutCore/Sources/AudioutCore/Analytics.swift
# Dry-run env: GUARD_MERGE=1 (merge landing on main), GUARD_DELETED (newline
# separated paths), GUARD_SCOPE_ROOT (repo root to look for test files under).
#
# How a staged source file maps to test files, first rule that finds any wins:
#   1. By name. `Foo.swift` selects every test file named `Foo*Tests.swift`. A
#      `+Aspect` part is dropped first, so `NativeBackend+Bluetooth.swift` looks
#      for `NativeBackend*Tests.swift`: Swift extension files are named
#      `Type+Aspect.swift` and the tests for the type cover the extension.
#   2. By target. A file under `AudioutCore/Sources/<Target>/` selects every
#      test file that imports <Target> or any target that depends on it,
#      directly or through another target (the table in `dependents_of` below,
#      copied from AudioutCore/Package.swift). Not done when that set of
#      targets includes AudioutCore itself: 172 of the 209 test files import
#      it, so the selection would be close to the full suite anyway.
#
# It fails CLOSED — anything it cannot map prints FULL:
#   - a staged source file that neither rule above maps to any test file,
#     including every file in AudioutCore (rule 2 skipped, see above) and in
#     AudioutApp or any other executable target (no test imports those)
#   - any deletion or rename (a deleted file has no suites of its own, and
#     removing one breaks callers that live elsewhere)
#   - AUDIOUT_FULL_SUITE=1, the switch agents already use for a deliberate full
#     run, so no second variable is needed
#
# A rebase or cherry-pick also produces commits with no MERGE_HEAD, so those get
# the branch treatment. That is correct, not a bug to fix: those commits replay
# work that was already gated, and the merge onto main runs everything anyway.

root=${GUARD_SCOPE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}

if [ "$#" -gt 0 ]; then
    changed=$(printf '%s\n' "$@")
    deleted=${GUARD_DELETED:-}
    merge=${GUARD_MERGE:-0}
else
    # Same pathspec idiom as Guard 4 itself: a bare directory plus a `.swift`
    # grep, never `Sources/**/*.swift` (whose `**` misses a file sitting
    # directly in Sources/).
    changed=$(git diff --cached --name-only --diff-filter=ACM -- \
        'AudioutCore/Sources/' 'AudioutCore/Tests/' 2>/dev/null | grep '\.swift$')
    deleted=$(git diff --cached --name-only --diff-filter=DR -- \
        'AudioutCore/Sources/' 'AudioutCore/Tests/' 2>/dev/null | grep '\.swift$')
    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    git_dir=$(git rev-parse --git-dir 2>/dev/null)
    merge=0
    if [ "$branch" = "main" ] && [ -f "$git_dir/MERGE_HEAD" ]; then
        merge=1
    fi
fi

if [ "$merge" = "1" ] || [ "${AUDIOUT_FULL_SUITE:-0}" = "1" ] || [ -n "$deleted" ]; then
    echo FULL
    exit 0
fi

# The library targets that list <target> in their `dependencies:` in
# AudioutCore/Package.swift. Executable and test targets are left out: no test
# file imports them. Keep in step with Package.swift — the test
# scripts/test-guard-test-scope.sh fails when the two disagree.
dependents_of() {
    case "$1" in
        AudioutCore)       echo "AudioutSharedUI AudioutPopoverUI AudioutWindowUI AudioutSettingsUI AudioutOnboardingUI" ;;
        AudioutSharedUI)   echo "AudioutPopoverUI AudioutWindowUI AudioutSettingsUI AudioutOnboardingUI" ;;
        AudioutWindowUI)   echo "AudioutPopoverUI" ;;
        AudioutSettingsUI) echo "AudioutPopoverUI" ;;
        CastSender)        echo "AudioutCore CastFakeReceiver" ;;
        ObjCExceptionShim) echo "AudioutCore" ;;
    esac
}

# Library targets rule 2 knows about. A target missing from this list (the
# executables: AudioutApp, the harnesses, the snapshot tools) maps to nothing.
library_targets=" AudioutCore AudioutSharedUI AudioutPopoverUI AudioutWindowUI AudioutSettingsUI AudioutOnboardingUI CastSender CastFakeReceiver ObjCExceptionShim "

# Prints the test files rule 2 selects for a source file, or nothing.
tests_by_target() {
    case "$1" in
        AudioutCore/Sources/*/*) ;;
        *) return ;;
    esac
    rest=${1#AudioutCore/Sources/}
    target=${rest%%/*}
    case "$library_targets" in
        *" $target "*) ;;
        *) return ;;
    esac
    # The caller's loop splits on newlines only; this function's lists are
    # space-separated, so split on spaces here and put the caller's back after.
    caller_ifs=$IFS
    IFS=' '
    # Walk the dependents table until no new target turns up.
    closure=" $target "
    todo=$target
    while [ -n "$todo" ]; do
        next=""
        for t in $todo; do
            for d in $(dependents_of "$t"); do
                case "$closure" in
                    *" $d "*) ;;
                    *) closure="$closure$d "; next="$next $d" ;;
                esac
            done
        done
        todo=$next
    done
    alts=$(echo $closure | tr ' ' '|')
    IFS=$caller_ifs
    case "$closure" in
        *" AudioutCore "*) return ;;
    esac
    grep -rlE "^(@testable )?import ($alts)\$" "$root/AudioutCore/Tests" 2>/dev/null
}

# Name mapping (rule 1), deliberately dumb so it is obvious what it will do:
#   FooBar.swift       -> every test file named FooBar*Tests.swift
#   FooBar+Baz.swift   -> the same as FooBar.swift
#   FooBarTests.swift  -> itself
# then the suite names are read out of those files rather than assumed from the
# file name, because they do not always agree — BTRowsUITests.swift declares
# BTDeviceRowTests, BTPopoverRowsTests, BTSyncDrawerAccordionTests and
# EqualizerSeatBorderTests and no suite of its own name. Filtering on the file
# name there would have run nothing and passed, which is the one failure this
# guard must not have.
suites=""
# Split on newlines only, never spaces: this repo's own checkout lives under
# "~/Projects/AirPlay Controller", so the absolute paths `find` returns below
# contain a space. Splitting on the default IFS turned every one of them into
# two paths that do not exist, and the scan then silently found no suite names.
old_ifs=$IFS
IFS='
'
for f in $changed; do
    base=${f##*/}
    base=${base%.swift}
    case "$base" in
        *Tests) matches=$f ;;
        *)      base=${base%%+*}
                matches=$(find "$root/AudioutCore/Tests" -name "$base*Tests.swift" 2>/dev/null)
                if [ -z "$matches" ]; then
                    matches=$(tests_by_target "$f")
                fi ;;
    esac
    if [ -z "$matches" ]; then
        IFS=$old_ifs
        echo FULL
        exit 0
    fi
    for t in $matches; do
        case "$t" in
            /*) path=$t ;;
            *)  path="$root/$t" ;;
        esac
        # A name picked up from a comment or a heredoc inside a test file only
        # ever ADDS an alternative that matches nothing, so this scan can be
        # loose without opening a hole.
        names=$(grep -Eho '(struct|class|enum|actor)[[:space:]]+[A-Za-z0-9_]*Tests' "$path" 2>/dev/null \
                | awk '{print $NF}')
        if [ -z "$names" ]; then
            names=$base
        fi
        suites="$suites
$names"
    done
done
IFS=$old_ifs

regex=$(printf '%s\n' "$suites" | grep -v '^[[:space:]]*$' | sort -u | paste -sd '|' -)
if [ -z "$regex" ]; then
    echo FULL
    exit 0
fi
echo "$regex"
