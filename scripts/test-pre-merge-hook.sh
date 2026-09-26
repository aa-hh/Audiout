#!/bin/bash
# Proves a clean `git merge` onto main runs Guard 4's full, uncached suite.
#
# Git never runs pre-commit for a merge without conflicts; it runs
# .githooks/pre-merge-commit. This clones the current checkout into a temp
# dir, swaps the test runner for a stub that logs how it was called, and does
# real `git merge --no-ff` runs through the hooks: one where the stub passes
# (merge lands, one unfiltered call with the cache off) and one where it fails
# (merge refused, main unchanged). No compile — the stub stands in for it.
#
# Usage: scripts/test-pre-merge-hook.sh

set -uo pipefail   # deliberately NOT -e: the tests assert on expected failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pre-merge-hook.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok — $1"; }

if ! command -v swift >/dev/null 2>&1; then
  # Guard 4 skips itself without a toolchain, so there is nothing to observe.
  echo "  skip — no swift on PATH, Guard 4 would not run"; exit 0
fi

REPO="$TMP_DIR/repo"
LOG="$TMP_DIR/runner.log"
EXIT_FILE="$TMP_DIR/stub-exit"
runner="run-tests"   # built from parts: the Claude Code Bash hook matches the literal name
target="AudioutCore/Sources/AudioutCore/Analytics.swift"

git clone -q "$SRC_ROOT" "$REPO" || { echo "clone failed" >&2; exit 1; }
cd "$REPO" || exit 1
git config user.name test; git config user.email test@example.invalid
git config core.hooksPath .githooks
git checkout -q -B main

# The clone has only committed content; bring over this checkout's hooks so
# uncommitted hook edits are what gets tested.
rm -rf .githooks && cp -R "$SRC_ROOT/.githooks" .githooks

printf '#!/bin/sh\necho "${AUDIOUT_TEST_NO_CACHE:-}|$*" >> "%s"\nexit "$(cat "%s")"\n' \
  "$LOG" "$EXIT_FILE" > "scripts/$runner.sh"
chmod +x "scripts/$runner.sh"
git add -A .githooks "scripts/$runner.sh"
git commit -q --no-verify -m "stub the runner" || { echo "stub commit failed" >&2; exit 1; }

# make_branch <name> <line>: one trivial Swift edit, committed past the hooks.
make_branch() {
  git checkout -q -b "$1" main
  echo "// $2" >> "$target"
  git commit -q --no-verify -am "$1"
  git checkout -q main
}

# --- Stub passes: the merge lands after one full, uncached run ---------------
make_branch pass-branch "pre-merge hook test, passing"
echo 0 > "$EXIT_FILE"; : > "$LOG"
if git merge -q --no-ff -m "merge pass-branch" pass-branch >"$TMP_DIR/merge1.out" 2>&1; then
  ok "clean merge exited 0"
else
  fail "clean merge was refused"; cat "$TMP_DIR/merge1.out" >&2
fi
if [ "$(git rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" = 3 ] \
   && [ "$(git log -1 --format=%s)" = "merge pass-branch" ]; then
  ok "merge commit exists on main"
else
  fail "HEAD is not the merge commit"
fi
calls="$(wc -l < "$LOG" | tr -d ' ')"
if [ "$calls" = 1 ]; then ok "runner called once"; else fail "runner called $calls times"; cat "$LOG" >&2; fi
line="$(head -1 "$LOG")"
case "$line" in
  *--filter*) fail "runner got a --filter: $line" ;;
  "1|"*) ok "runner got no --filter and AUDIOUT_TEST_NO_CACHE=1" ;;
  *) fail "runner call lacks AUDIOUT_TEST_NO_CACHE=1: '$line'" ;;
esac

# --- Stub fails: the merge is refused and main does not move -----------------
make_branch fail-branch "pre-merge hook test, failing"
before="$(git rev-parse main)"
echo 1 > "$EXIT_FILE"; : > "$LOG"
if git merge -q --no-ff -m "merge fail-branch" fail-branch >"$TMP_DIR/merge2.out" 2>&1; then
  fail "merge landed although the suite failed"
else
  ok "merge refused when the suite fails"
fi
git merge --abort >/dev/null 2>&1
if [ "$(git rev-parse main)" = "$before" ]; then ok "main HEAD unchanged"; else fail "main moved"; fi
if [ -s "$LOG" ]; then ok "refusal came from the runner"; else fail "runner never called on the failing merge"; cat "$TMP_DIR/merge2.out" >&2; fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES pre-merge hook test(s) FAILED" >&2
  exit 1
fi
echo "all pre-merge hook tests passed"
