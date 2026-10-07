#!/bin/sh
# The one way tests run in this repo. Hooks, agents and humans all call this,
# never the bare test command, so how tests run is decided in one place.
#
# Usage: sh scripts/test.sh [--full] [extra args passed to the test runner]
#   (no flag)  the fast run Guard 4 uses at commit
#   --full     the full suite; pre-push runs it (this repo has no CI)
#
# Fill in the two commands below for your stack.
set -eu
cd "$(dirname "$0")/.."

full=0
[ "${1:-}" = --full ] && { full=1; shift; }

if [ "$full" = 1 ]; then
    echo "scripts/test.sh: no full-suite command configured yet — edit scripts/test.sh" >&2
    # e.g.  npm test -- "$@"   |  pytest "$@"   |  go test ./... "$@"
else
    echo "scripts/test.sh: no fast test command configured yet — edit scripts/test.sh" >&2
    # e.g.  npm test -- --changed "$@"  |  pytest -x -q "$@"
fi
