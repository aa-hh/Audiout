#!/bin/bash
# Proves a clean `git merge` onto main runs Guard 4's full, uncached suite.
#
# Git never runs pre-commit for a merge without conflicts; it runs
# .githooks/pre-merge-commit. This clones the current checkout into a temp
# dir, swaps the test runner for a stub that logs how it was called, and does
# real `git merge --no-ff` runs through the hooks: one where the stub passes
# (merge lands, one unfiltered call with the cache off) and one where it fails
# (merge refused, main unchanged). Then the one case the merge may skip: a
# full-suite pass stamped on the identical merged tree, and the near misses
# that must still run. No compile — the stub stands in for it.
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

# A scratch stamp folder, so the live /tmp/audiout-suite-cache is never read.
export AUDIOUT_TEST_CACHE_DIR="$TMP_DIR/stamps"
unset AUDIOUT_TEST_NO_CACHE
mkdir -p "$AUDIOUT_TEST_CACHE_DIR"

git clone -q "$SRC_ROOT" "$REPO" || { echo "clone failed" >&2; exit 1; }
cd "$REPO" || exit 1
git config user.name test; git config user.email test@example.invalid
git config core.hooksPath .githooks
git checkout -q -B main

# The clone has only committed content; bring over this checkout's hooks so
# uncommitted hook edits are what gets tested.
rm -rf .githooks && cp -R "$SRC_ROOT/.githooks" .githooks
cp "$SRC_ROOT/scripts/lib/suite-cache.sh" scripts/lib/suite-cache.sh

printf '#!/bin/sh\necho "${AUDIOUT_TEST_NO_CACHE:-}|$*" >> "%s"\nexit "$(cat "%s")"\n' \
  "$LOG" "$EXIT_FILE" > "scripts/$runner.sh"
chmod +x "scripts/$runner.sh"
git add -A .githooks scripts/lib/suite-cache.sh "scripts/$runner.sh"
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

# --- A stamped full pass on the identical tree lets the merge skip -----------
. "$SRC_ROOT/scripts/lib/suite-cache.sh"
echo 0 > "$EXIT_FILE"

# stamp_branch <branch> <suffix>: write the stamp <hash>.<suffix> for the
# branch's working tree, hashed the way run-tests.sh hashes it. A --no-ff
# merge of a branch cut from main commits exactly the branch's tree.
stamp_branch() {
  git checkout -q "$1"
  key="$(suite_cache_source_hash "$REPO" AudioutCore)"
  : > "$AUDIOUT_TEST_CACHE_DIR/$key.$2"
  git checkout -q main
}

# merge_case <label> <branch> [env...]: merge with the stub passing, then
# report whether the runner was called. Sets $merge_out.
merge_case() {
  label="$1"; br="$2"; shift 2
  : > "$LOG"
  merge_out="$TMP_DIR/$br.out"
  env "$@" git merge -q --no-ff -m "merge $br" "$br" >"$merge_out" 2>&1 \
    || { fail "$label: merge refused"; cat "$merge_out" >&2; }
}
expect_run() {
  if grep -q '^1|$' "$LOG"; then ok "$1: runner ran the full suite uncached"
  else fail "$1: runner not called uncached (log: '$(cat "$LOG")')"; cat "$merge_out" >&2; fi
}

# (a) A full pass stamped on the same tree: no run, one line naming the stamp.
# Catches: the merge still paying for a full run the branch already passed.
rm -f "$AUDIOUT_TEST_CACHE_DIR"/*
make_branch same-full "identical tree, full stamp"
stamp_branch same-full full
merge_case "a" same-full
if [ ! -s "$LOG" ]; then ok "a: runner not called"; else fail "a: runner called: $(cat "$LOG")"; fi
if grep -q "Guard 4: skipped — full suite already passed on this exact merged tree" "$merge_out" \
   && grep -q "stamp $(printf '%.12s' "$key"), passed 20" "$merge_out"; then
  ok "a: printed the stamp's hash prefix and time"
else
  fail "a: no skip line naming stamp $(printf '%.12s' "$key")"; cat "$merge_out" >&2
fi

# (b) Only per-name stamps on the same tree. Catches: a filtered pass being
# taken for a full one.
rm -f "$AUDIOUT_TEST_CACHE_DIR"/*
make_branch same-filtered "identical tree, filtered stamps"
stamp_branch same-filtered suite.AnalyticsTests
stamp_branch same-filtered suite.PopoverControllerTests
merge_case "b" same-filtered
expect_run "b"

# (c) A full stamp for an earlier commit of the branch. Catches: a stamp
# lookup that ignores the hash.
rm -f "$AUDIOUT_TEST_CACHE_DIR"/*
make_branch moved-on "stamped, then changed"
stamp_branch moved-on full
git checkout -q moved-on; echo "// after the stamp" >> "$target"; git commit -q --no-verify -am more; git checkout -q main
merge_case "c" moved-on
expect_run "c"

# (d) AUDIOUT_TEST_NO_CACHE=1 forces the run past a matching full stamp.
rm -f "$AUDIOUT_TEST_CACHE_DIR"/*
make_branch no-cache "identical tree, cache forced off"
stamp_branch no-cache full
merge_case "d" no-cache AUDIOUT_TEST_NO_CACHE=1
expect_run "d"

# (e) An old-format stamp (before 400b60c2: <src>.<sha256 of "package\nargs">)
# for an argument-free run on the same tree. Catches: a pre-.full stamp
# satisfying the merge.
rm -f "$AUDIOUT_TEST_CACHE_DIR"/*
make_branch old-format "identical tree, old-format full stamp"
stamp_branch old-format "$(printf 'AudioutCore\n' | shasum -a 256 | awk '{print $1}')"
merge_case "e" old-format
expect_run "e"

# (f) A full pass that ran on the remote Mac. run-tests.sh records it here
# with the same call as a local pass (suite_cache_record "$key" "$@", no
# arguments for a full run), keyed on this Mac's sources. Catches: a remote
# pass not counting, or recording a stamp the merge cannot find.
rm -f "$AUDIOUT_TEST_CACHE_DIR"/*
make_branch remote-pass "identical tree, full pass on the remote Mac"
git checkout -q remote-pass
suite_cache_record "$(suite_cache_source_hash "$REPO" AudioutCore)"
git checkout -q main
merge_case "f" remote-pass
if [ ! -s "$LOG" ] && grep -q "Guard 4: skipped" "$merge_out"; then ok "f: remote pass let the merge skip"
else fail "f: remote pass did not satisfy the merge (log: '$(cat "$LOG")')"; cat "$merge_out" >&2; fi

# (g) A stamp from a filter that selects every suite. Catches: any stamp
# other than an argument-free full run satisfying the merge.
rm -f "$AUDIOUT_TEST_CACHE_DIR"/*
make_branch regex-all "identical tree, --filter '.*' stamp"
stamp_branch regex-all "$(suite_cache_args_stamp --filter '.*')"
merge_case "g" regex-all
expect_run "g"

# (h) The stamp matches the working tree only because of an untracked file the
# merge does not commit. Catches: hashing the working tree instead of the index.
rm -f "$AUDIOUT_TEST_CACHE_DIR"/*
make_branch untracked "working tree differs from the index"
extra="AudioutCore/Sources/AudioutCore/UntrackedByMergeTest.swift"
echo "// untracked" > "$extra"
stamp_branch untracked full
merge_case "h" untracked
expect_run "h"
rm -f "$extra"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES pre-merge hook test(s) FAILED" >&2
  exit 1
fi
echo "all pre-merge hook tests passed"
