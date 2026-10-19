#!/usr/bin/env bash
# Lists the real-time waits in tests that use the code you changed.
#
# Usage: scripts/real-time-tests.sh <source.swift>...
#
# Takes the types each given file declares at top level (class, struct, enum,
# actor, protocol, and the type a top-level `extension` extends), finds the
# test files under AudioutCore/Tests and AirPlayEngine/Tests that name one of
# them as a whole word, and prints every line in those files that matches
# Guard 11's real-time wait pattern, as
#   <file>:<line>: <enclosing func>: <the line>
# Lines carrying `real-time-ok:` are listed too: they still wait on the real
# clock. Comment lines are skipped, as Guard 11 skips them. The match is by
# type name and file, so read the listed test before converting it.
# Run from anywhere inside the repo; prints nothing when nothing matches.

set -euo pipefail

[ $# -gt 0 ] || { echo "usage: $0 <source.swift>..." >&2; exit 64; }

# Kept identical to the pattern in .githooks/guard-test-discipline.sh;
# scripts/test-real-time-tests.sh fails if the two drift apart.
PATTERN='Task\.sleep|Thread\.sleep|usleep\(|(^|[^A-Za-z0-9_.])sleep\(|asyncAfter|SuiteWait\.settle\(|\.wait\(timeout:|([Tt]imeout|[Dd]elay|[Dd]eadline|[Ii]nterval|[Gg]race|[Ww]indow|[Ss]econds)(Override)?[[:space:]]*(:[[:space:]]*[A-Za-z]+[[:space:]]*)?[=:][[:space:]]*0*\.0*[1-9]|real-time-ok:'

ROOT="$(git rev-parse --show-toplevel)"

types=$(for src in "$@"; do
    sed -nE 's/^(@[A-Za-z]+[[:space:]]+)*((public|internal|package|private|fileprivate|final|open)[[:space:]]+)*(class|struct|enum|actor|protocol|extension)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\5/p' "$src"
done | sort -u)
[ -n "$types" ] || exit 0
alternation=$(printf '%s\n' "$types" | paste -sd '|' -)

dirs=()
for d in AudioutCore/Tests AirPlayEngine/Tests; do [ -d "$ROOT/$d" ] && dirs+=("$ROOT/$d"); done
[ ${#dirs[@]} -gt 0 ] || exit 0

{ grep -rlwE --include='*.swift' "($alternation)" "${dirs[@]}" || true; } | sort | while IFS= read -r file; do
    lines=$({ grep -nE "$PATTERN" "$file" || true; } | { grep -vE '^[0-9]+:[[:space:]]*//' || true; } | cut -d: -f1 | tr '\n' ' ')
    [ -n "$lines" ] || continue
    awk -v want=" $lines" -v name="${file#"$ROOT"/}" '
        match($0, /func [A-Za-z_][A-Za-z0-9_]*/) { fn = substr($0, RSTART + 5, RLENGTH - 5) }
        index(want, " " NR " ") { line = $0; sub(/^[[:space:]]+/, "", line); print name ":" NR ": " fn ": " line }
    ' "$file"
done
