#!/bin/bash
# Fast tests for scripts/sync-main.sh: local main follows origin/main by
# fast-forward only, and is left alone (with one stderr line) whenever moving
# it could lose work. A temp bare repo plays origin; a second clone pushes to
# it. No network.
#
# Usage: scripts/test-sync-main.sh

set -uo pipefail   # deliberately NOT -e: a case failing must not stop the rest

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sync-main.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok — $1"; }

ORIGIN="$TMP_DIR/origin.git"; PUSHER="$TMP_DIR/pusher"; LOCAL="$TMP_DIR/local"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$PUSHER" 2> /dev/null
cd "$PUSHER" || exit 1
git config user.name test; git config user.email test@example.invalid
mkdir -p scripts && cp "$SRC_ROOT/scripts/sync-main.sh" scripts/
echo base > file.txt
git add -A && git commit -q -m base && git push -q origin main
git clone -q "$ORIGIN" "$LOCAL"
git -C "$LOCAL" config user.name test; git -C "$LOCAL" config user.email test@example.invalid

# advance: one new commit on origin/main.
advance() {
  echo "$1" >> "$PUSHER/file.txt"
  git -C "$PUSHER" commit -q -am "$1" && git -C "$PUSHER" push -q origin main
}
sync() { sh "$LOCAL/scripts/sync-main.sh" > "$TMP_DIR/out" 2> "$TMP_DIR/err"; rc=$?; }
origin_tip() { git -C "$ORIGIN" rev-parse main; }
local_main() { git -C "$LOCAL" rev-parse main; }

# (1) Clean checkout on main: fast-forwarded, one line naming the new tip.
# Catches: the mirror not moving, or moving by a merge commit.
advance one
sync
if [ "$rc" = 0 ] && [ "$(local_main)" = "$(origin_tip)" ] \
   && grep -qx "sync-main: main -> $(git -C "$LOCAL" rev-parse --short main)" "$TMP_DIR/out" \
   && [ "$(git -C "$LOCAL" rev-list --merges --count main)" = 0 ]; then
  ok "1: clean main fast-forwarded"
else fail "1: rc $rc, out $(cat "$TMP_DIR/out" "$TMP_DIR/err")"; fi
sync
[ "$rc" = 0 ] && [ ! -s "$TMP_DIR/out" ] && [ ! -s "$TMP_DIR/err" ] && ok "1: second run silent" || fail "1: second run printed"

# (2) Uncommitted edits on main: left alone, one stderr line, edits kept.
# Catches: a sync that discards or merges into someone's loose edits.
advance two
before=$(local_main)
echo "loose edit" >> "$LOCAL/file.txt"
sync
if [ "$rc" = 0 ] && [ "$(local_main)" = "$before" ] && grep -q 'uncommitted changes' "$TMP_DIR/err" \
   && grep -q 'loose edit' "$LOCAL/file.txt"; then
  ok "2: dirty main left alone with the reason"
else fail "2: rc $rc, err $(cat "$TMP_DIR/err")"; fi
git -C "$LOCAL" checkout -q -- file.txt

# (3) main not checked out: the ref moves by update-ref.
# Catches: main going stale whenever the primary checkout is on a branch.
git -C "$LOCAL" checkout -q -b elsewhere
advance three
sync
[ "$rc" = 0 ] && [ "$(local_main)" = "$(origin_tip)" ] && [ "$(git -C "$LOCAL" symbolic-ref --short HEAD)" = elsewhere ] \
  && ok "3: main not checked out moved to origin/main" || fail "3: rc $rc, err $(cat "$TMP_DIR/err")"

# (4) Local main has a commit origin lacks: left alone, checked out or not.
# Catches: a sync that rewinds or merges over local-only commits.
git -C "$LOCAL" checkout -q main
echo local >> "$LOCAL/file.txt"; git -C "$LOCAL" commit -q -am "local only"
ahead=$(local_main)
advance four
sync
[ "$rc" = 0 ] && [ "$(local_main)" = "$ahead" ] && grep -q 'commits origin/main lacks' "$TMP_DIR/err" \
  && ok "4: local main ahead (checked out) left alone" || fail "4: rc $rc, err $(cat "$TMP_DIR/err")"
git -C "$LOCAL" checkout -q elsewhere
sync
[ "$rc" = 0 ] && [ "$(local_main)" = "$ahead" ] && grep -q 'commits origin/main lacks' "$TMP_DIR/err" \
  && ok "4: local main ahead (not checked out) left alone" || fail "4: rc $rc, err $(cat "$TMP_DIR/err")"

# (5) Usage error is the only non-zero exit.
sh "$LOCAL/scripts/sync-main.sh" extra > /dev/null 2>&1
[ "$?" = 2 ] && ok "5: an argument is a usage error" || fail "5: argument not refused"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES sync-main test(s) FAILED" >&2
  exit 1
fi
echo "all sync-main tests passed"
