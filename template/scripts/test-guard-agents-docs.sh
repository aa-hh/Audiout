#!/usr/bin/env bash
# Tests for .githooks/guard-agents-docs.sh (Guard 12). Builds a throwaway
# fixture repo and runs the helper from THIS checkout with cwd in it.
#
# Usage: scripts/test-guard-agents-docs.sh

set -uo pipefail   # deliberately NOT -e: a case failing must not stop the rest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO/.githooks/guard-agents-docs.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok — $1"; }

CLONE="$TMP_DIR/repo with space"
mkdir -p "$CLONE/src/a" "$CLONE/src/b" "$CLONE/src/c" "$CLONE/dev"
HIST=src/a/AGENTS-HISTORY.md
CAST=src/b/AGENTS.md
DEVD=dev/AGENTS.md
POP=src/c/AGENTS.md
for i in 1 2 3 4 5 6 7 8; do echo "- history entry $i" >> "$CLONE/$HIST"; done
printf '# b

## Purpose
A small folder.
' > "$CLONE/$CAST"
printf '# dev

## Purpose
Dev tools.
' > "$CLONE/$DEVD"
{ echo "# c"; for i in $(seq 1 40); do echo "word word word word word word word word"; done; } > "$CLONE/$POP"
echo "# root" > "$CLONE/AGENTS.md"
git -C "$CLONE" init -q
git -C "$CLONE" -c user.email=t@t -c user.name=t add -A
git -C "$CLONE" -c user.email=t@t -c user.name=t commit -qm fixture || { echo "fixture commit failed" >&2; exit 1; }

reset() { git -C "$CLONE" reset -q --hard; git -C "$CLONE" clean -qfd; }
run_guard() { ERR="$(cd "$CLONE" && sh "$GUARD" 2>&1 >/dev/null)"; RC=$?; }
expect() {
  if [ "$RC" -ne "$2" ]; then fail "$1: exit $RC, wanted $2 ($ERR)"; return; fi
  if [ -n "${3:-}" ] && ! printf '%s' "$ERR" | grep -qF -- "$3"; then
    fail "$1: stderr lacks '$3' ($ERR)"; return
  fi
  ok "$1"
}
stage() { git -C "$CLONE" add -- "$1"; }

# (a)
reset; run_guard; expect "nothing staged passes" 0

# (b) history append
reset; echo "- appended entry" >> "$CLONE/$HIST"; stage "$HIST"
run_guard; expect "history append passes" 0

# (c) history line removed
reset; sed -i.bak '5d' "$CLONE/$HIST"; rm -f "$CLONE/$HIST.bak"; stage "$HIST"
run_guard; expect "history removal blocked" 1 "AGENTS-HISTORY.md"
(cd "$CLONE" && git diff --cached --quiet) && fail "case (c) staged nothing"

# (d) ruling phrasing in a folder file
reset; echo "- Keep this (owner's ruling 2026-10-04)." >> "$CLONE/$CAST"; stage "$CAST"
run_guard; expect "ruling phrasing blocked" 1 "ruling phrasing"

# (e) dated trap, file stays under 300 words
reset; echo "- A trap noted 2026-10-04." >> "$CLONE/$DEVD"; stage "$DEVD"
run_guard; expect "date only warns" 0 "NOTE (non-blocking, Guard 12)"

# (f) growth of an over-budget file
reset; echo "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty" >> "$CLONE/$POP"; stage "$POP"
run_guard; expect "over-budget growth blocked" 1 "words staged"
printf '%s' "$ERR" | grep -qE '[0-9]+ words staged, [0-9]+ at HEAD' || fail "(f) counts not printed"

# (g) shrink of the same file
reset; sed -i.bak '$d' "$CLONE/$POP"; rm -f "$CLONE/$POP.bak"; stage "$POP"
run_guard; expect "over-budget shrink passes" 0

# (h) root AGENTS.md exempt
reset; echo "- Keep this (owner's ruling 2026-10-04)." >> "$CLONE/AGENTS.md"; stage AGENTS.md
run_guard; expect "root AGENTS.md exempt" 0

# (i) merge exemption
reset; sed -i.bak '5d' "$CLONE/$HIST"; rm -f "$CLONE/$HIST.bak"; stage "$HIST"
git -C "$CLONE" rev-parse HEAD > "$CLONE/.git/MERGE_HEAD"
ERR="$(cd "$CLONE" && sh "$GUARD" 2>&1 >/dev/null)"; RC=$?
rm -f "$CLONE/.git/MERGE_HEAD"
expect "a merge commit (MERGE_HEAD) is exempt" 0

# (j) deleting a history file blocks
reset; git -C "$CLONE" rm -q -- "$HIST"
run_guard; expect "history deletion blocked" 1 "AGENTS-HISTORY.md"

# (k) a history file moved to a non-history name blocks
reset; mkdir -p "$CLONE/dev"; git -C "$CLONE" mv "$HIST" dev/NOTES.md
run_guard; expect "history moved to other name blocked" 1 "AGENTS-HISTORY.md"

# (l) a history file moved to another folder with a line deleted blocks
reset; mkdir -p "$CLONE/dev/newdir"; sed -i.bak '5d' "$CLONE/$HIST"; rm -f "$CLONE/$HIST.bak"
git -C "$CLONE" mv "$HIST" dev/newdir/AGENTS-HISTORY.md
run_guard; expect "history moved with deletion blocked" 1 "AGENTS-HISTORY.md"

# (m) a file moved into place as a folder AGENTS.md is checked whole
reset; mkdir -p "$CLONE/dev/sub"; git -C "$CLONE" mv "$DEVD" dev/sub/AGENTS.md
echo "- Keep this (owner's ruling)." >> "$CLONE/dev/sub/AGENTS.md"; stage dev/sub/AGENTS.md
run_guard; expect "renamed-in AGENTS.md ruling blocked" 1 "ruling phrasing"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES guard-agents-docs test(s) FAILED" >&2
  exit 1
fi
echo "all guard-agents-docs tests passed"
