#!/bin/sh
# Shared by pre-commit (Guard 4) and pre-merge-commit (Guard 5): if the
# changed files include AudiouterCore Swift sources/tests, run the full
# `swift test --parallel` and fail if it fails. This is the single coverage
# GUARANTEE both callers rely on — one implementation, so the two gates can
# never silently drift apart.
#
# Usage: run-full-suite-if-swift-changed.sh <guard-label> <diff-revision-arg>
#   <guard-label>        e.g. "Guard 4" or "Guard 5" — only used in messages.
#   <diff-revision-arg>  what to diff against to find changed files:
#                          "--cached" for a normal commit (staged vs HEAD)
#                          "HEAD"     for a merge (working tree vs pre-merge HEAD)
#
# Exit 0 = nothing to gate, or the suite passed. Exit 1 = suite failed, caller
# must refuse. Missing `swift` toolchain => skip rather than wedge a machine
# that can't build.

label="$1"
diff_rev="$2"

# Directory-prefix pathspec (not a **/*.swift glob) + a plain grep for the
# extension: a git `**` pathspec segment must span at least one intermediate
# directory, so `Sources/**/*.swift` silently fails to match a file sitting
# directly in Sources/ (verified empirically — cost real debugging time to
# find). A bare directory pathspec matches everything under it at any depth,
# including depth zero, with no such gap.
changed_swift=$(git diff --name-only --diff-filter=ACM "$diff_rev" -- \
    'AudiouterCore/Sources/' 'AudiouterCore/Tests/' 2>/dev/null | grep '\.swift$')

[ -n "$changed_swift" ] || exit 0
command -v swift >/dev/null 2>&1 || exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
echo "" >&2
echo "  $label: AudiouterCore Swift changed — running full suite" >&2
echo "  (swift test --parallel) before this lands. ~70s warm; --no-verify to skip." >&2
if ! ( cd "$repo_root/AudiouterCore" && swift test --parallel >&2 ); then
    echo "" >&2
    echo "  REFUSED: full test suite failed. A filtered inner-loop run can miss" >&2
    echo "  a suite the change broke — this gate is why that never ships." >&2
    echo "  Fix the failures (or --no-verify for a real emergency)." >&2
    echo "" >&2
    exit 1
fi
echo "  $label: full suite passed." >&2
exit 0
