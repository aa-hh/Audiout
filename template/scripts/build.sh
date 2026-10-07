#!/bin/sh
# The one way to compile/typecheck this repo. Agents call this, never the bare
# build command (the Claude hook in .claude/hooks/ enforces it).
#
# Fill in for your stack.
set -eu
cd "$(dirname "$0")/.."
echo "scripts/build.sh: no build command configured yet — edit scripts/build.sh" >&2
# e.g.  npm run build "$@"  |  cargo build "$@"  |  swift build "$@"
