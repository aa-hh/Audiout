#!/bin/bash
# Proves scripts/review-branch.sh picks the right review level, calls claude
# with the right flags per pass, scores and drops findings, writes receipts
# keyed to the committed diff, and that Guard 10 refuses a merge onto main
# without one.
#
# Clones the current checkout into a temp dir, brings over this checkout's
# hooks, review script and instruction files, stubs the test runner and the
# `claude` CLI (the stub answers per pass from files), and does real
# `git merge --no-ff` runs through the hooks. No model is ever called.
#
# Usage: scripts/test-review-branch.sh

set -uo pipefail   # deliberately NOT -e: the tests assert on expected failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/review-branch.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok — $1"; }

REPO="$TMP_DIR/repo"
RUNNER_EXIT="$TMP_DIR/stub-exit"
RUNNER_LOG="$TMP_DIR/runner.log"
CLAUDE_LOG="$TMP_DIR/claude.log"
ANSWERS="$TMP_DIR/answers"
runner="run-tests"   # built from parts: the Claude Code Bash hook matches the literal name
analytics="AudioutCore/Sources/AudioutCore/Analytics.swift"
license="AudioutCore/Sources/AudioutCore/LicenseGate.swift"

unset AUDIOUT_SKIP_BRANCH_REVIEW AUDIOUT_TEST_NO_CACHE
export AUDIOUT_TEST_CACHE_DIR="$TMP_DIR/stamps"
mkdir -p "$AUDIOUT_TEST_CACHE_DIR" "$ANSWERS" "$TMP_DIR/bin"

# The claude stub: logs its arguments, answers per pass from $ANSWERS.
export STUB_TMP="$TMP_DIR"
cat > "$TMP_DIR/bin/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_TMP/claude.log"
in="$STUB_TMP/stdin.$$"
cat > "$in"
name=$(sed -n 's/^# Review pass: //p' "$in" | head -n 1)
if [ "$name" = score ]; then
  if grep -q DROPME "$in"; then echo "SCORE: 40"; else echo "SCORE: 95"; fi
elif [ -f "$STUB_TMP/answers/$name" ]; then
  cat "$STUB_TMP/answers/$name"
else
  echo "NO FINDINGS"
fi
[ -f "$STUB_TMP/answers/$name.exit" ] && exit "$(cat "$STUB_TMP/answers/$name.exit")"
exit 0
EOF
chmod +x "$TMP_DIR/bin/claude"
export PATH="$TMP_DIR/bin:$PATH"

git clone -q "$SRC_ROOT" "$REPO" || { echo "clone failed" >&2; exit 1; }
cd "$REPO" || exit 1
git config user.name test; git config user.email test@example.invalid
git config core.hooksPath .githooks
git checkout -q -B main

# The clone has only committed content; bring over this checkout's files so
# uncommitted edits are what gets tested.
rm -rf .githooks && cp -R "$SRC_ROOT/.githooks" .githooks
cp "$SRC_ROOT/scripts/review-branch.sh" scripts/review-branch.sh
rm -rf docs/review && cp -R "$SRC_ROOT/docs/review" docs/review
cp "$SRC_ROOT/scripts/lib/suite-cache.sh" scripts/lib/suite-cache.sh
printf '#!/bin/sh\necho "$*" >> "%s"\nexit "$(cat "%s")"\n' "$RUNNER_LOG" "$RUNNER_EXIT" > "scripts/$runner.sh"
chmod +x "scripts/$runner.sh"
echo 0 > "$RUNNER_EXIT"
git add -A .githooks docs/review scripts/review-branch.sh scripts/lib/suite-cache.sh "scripts/$runner.sh"
git commit -q --no-verify -m "test setup" || { echo "setup commit failed" >&2; exit 1; }

COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
RECEIPTS="$COMMON/audiout-branch-reviews"
REVIEW_LOG="$COMMON/audiout-branch-reviews.log"

# make_branch <name> <file> <lines>: a branch off main adding <lines> comment
# lines to <file>, committed past the hooks and left checked out. The lines
# carry the branch name: the receipt key hashes the diff, so two branches with
# the same diff would share one receipt.
make_branch() {
  git checkout -q -b "$1" main
  mkdir -p "$(dirname "$2")"
  for i in $(seq 1 "$3"); do echo "// review test line $i ($1)" >> "$2"; done
  git add "$2"
  git commit -q --no-verify -m "$1"
}

# reset_answers: every pass answers NO FINDINGS and exits 0; claude.log empty.
reset_answers() { rm -rf "$ANSWERS"; mkdir -p "$ANSWERS"; : > "$CLAUDE_LOG"; }

# review [args]: run the script on the checked-out branch. Sets $rc, $out.
review() {
  out="$TMP_DIR/review.out"
  bash scripts/review-branch.sh "$@" > "$out" 2>&1
  rc=$?
}

# receipt_path: where the receipt for the checked-out branch must be.
receipt_path() {
  local key
  key=$(git diff -U0 --no-renames "$(git merge-base main HEAD)" HEAD | git patch-id --stable | cut -d' ' -f1)
  echo "$RECEIPTS/${key:-empty}"
}

# advance_main <file> <text>: one commit on main past the hooks, appending
# <text> to <file>; leaves main checked out.
advance_main() {
  git checkout -q main
  echo "$2" >> "$1"
  git add "$1"
  git commit -q --no-verify -m "main moves: $1"
}

# merge <branch> [env...]: merge onto main through the hooks. Sets $mrc, $mout.
merge() {
  br="$1"; shift
  git checkout -q main
  mout="$TMP_DIR/merge.out"
  env "$@" git merge -q --no-ff -m "merge $br" "$br" > "$mout" 2>&1
  mrc=$?
  [ "$mrc" = 0 ] || git merge --abort > /dev/null 2>&1
}

calls() { grep -c -F -- "$1" "$CLAUDE_LOG"; }
last_log() { tail -n 1 "$REVIEW_LOG"; }
show() { cat "$out" >&2; }

# (a) Docs only: no model, receipt, merge lands.
# Catches: docs counting as product lines, or a skip that writes no receipt.
reset_answers
make_branch docs-only docs/review-test-notes.md 80
review
grep -q '^Review level: skip' "$out" && ok "a: level skip" || { fail "a: not skip"; show; }
[ ! -s "$CLAUDE_LOG" ] && ok "a: no claude call" || fail "a: claude called"
[ -f "$(receipt_path)" ] && ok "a: receipt written" || fail "a: no receipt"
merge docs-only
[ "$mrc" = 0 ] && ok "a: merge landed" || { fail "a: merge refused"; cat "$mout" >&2; }

# (b) 10 product lines: skip. Catches: a small change paying for a model.
reset_answers
make_branch small "$analytics" 10
review
grep -q '^Review level: skip (10 product lines)' "$out" && ok "b: level skip" || { fail "b: not skip"; show; }

# (c) 120 lines: cheap, one sonnet call with no tools.
# Catches: wrong thresholds or the cheap pass getting tools.
reset_answers
make_branch medium "$analytics" 120
review
grep -q '^Review level: cheap' "$out" && ok "c: level cheap" || { fail "c: not cheap"; show; }
n=$(wc -l < "$CLAUDE_LOG" | tr -d ' ')
[ "$n" = 1 ] && ok "c: one claude call" || fail "c: $n claude calls"
if grep -q -- '--model sonnet' "$CLAUDE_LOG" && grep -q -- '--tools  --' "$CLAUDE_LOG"; then
  ok "c: sonnet with an empty --tools"
else fail "c: wrong flags: $(cat "$CLAUDE_LOG")"; fi
[ "$rc" = 0 ] && ok "c: exit 0" || fail "c: exit $rc"
[ -f "$(receipt_path)" ] && ok "c: receipt written" || fail "c: no receipt"
last_log | grep -q "$(printf '\tcheap\t0\t0\t0\t0\t')" && ok "c: log counts 0 0 0 0" || fail "c: log line '$(last_log)'"

# (d) 400 lines: full, four reviewers with their own model and tools.
# Catches: a reviewer on the wrong model, or the history pass without its git limits.
reset_answers
make_branch large "$analytics" 400
review
grep -q '^Review level: full' "$out" && ok "d: level full" || { fail "d: not full"; show; }
n=$(wc -l < "$CLAUDE_LOG" | tr -d ' ')
[ "$n" = 4 ] && ok "d: four reviewer calls" || fail "d: $n claude calls"
[ "$(calls '--model opus --tools Read,Grep,Glob --')" = 1 ] && ok "d: one opus reviewer" || fail "d: opus calls wrong: $(cat "$CLAUDE_LOG")"
[ "$(calls '--model sonnet --tools Read,Grep,Glob --max')" = 2 ] && ok "d: two sonnet reviewers with Read,Grep,Glob" || fail "d: sonnet calls wrong"
[ "$(calls '--model sonnet --tools Read,Grep,Glob,Bash --allowedTools Bash(git log:*) Bash(git blame:*)')" = 1 ] \
  && ok "d: history reviewer limited to git log and git blame" || fail "d: history call wrong"
[ "$(calls '--model haiku')" = 0 ] && ok "d: no scorer call without findings" || fail "d: haiku called"
[ "$rc" = 0 ] && ok "d: exit 0" || fail "d: exit $rc"
[ -f "$(receipt_path)" ] && ok "d: receipt written" || fail "d: no receipt"

# (e) 20 lines in a licence file: full. Catches: risk paths not forcing full.
reset_answers
make_branch risky "$license" 20
review
grep -q '^Review level: full (20 product lines, risk: AudioutCore/Sources/AudioutCore/LicenseGate.swift)' "$out" \
  && ok "e: risk path forces full" || { fail "e: not full"; show; }

# (f) Scoring: one haiku call per finding, under 80 dropped and listed apart.
# Catches: a low-confidence finding counted, or one dropped silently.
reset_answers
printf 'LOW | a.swift:1 | real\nLOW | a.swift:2 | DROPME nit\n' > "$ANSWERS/deep"
echo 'MEDIUM | a.swift:3 | DROPME' > "$ANSWERS/rules"
make_branch scored "$license" 20
review
[ "$(calls '--model haiku')" = 3 ] && ok "f: three scorer calls" || fail "f: $(calls '--model haiku') scorer calls"
kept_part=$(sed '/^Dropped by scorer:/,$d' "$out")
dropped_part=$(sed -n '/^Dropped by scorer:/,$p' "$out")
if printf '%s\n' "$kept_part" | grep -q 'a.swift:1' && ! printf '%s\n' "$kept_part" | grep -q DROPME \
   && [ "$(printf '%s\n' "$dropped_part" | grep -c DROPME)" = 2 ]; then
  ok "f: survivor kept, two DROPME lines under Dropped by scorer"
else fail "f: wrong split"; show; fi
grep -q '^Findings: 0 high, 0 medium, 1 low (2 dropped)$' "$out" && ok "f: counts" || { fail "f: counts"; show; }
[ "$rc" = 0 ] && ok "f: exit 0" || fail "f: exit $rc"
[ -f "$(receipt_path)" ] && ok "f: receipt written" || fail "f: no receipt"

# (g) A surviving HIGH blocks the receipt and the merge.
# Catches: a HIGH from a non-deep reviewer being ignored.
reset_answers
echo 'HIGH | a.swift:1 | x' > "$ANSWERS/comments"
make_branch high "$license" 20
review
[ "$rc" = 1 ] && ok "g: exit 1" || { fail "g: exit $rc"; show; }
[ ! -f "$(receipt_path)" ] && ok "g: no receipt" || fail "g: receipt written"
merge high
if [ "$mrc" != 0 ] && grep -q 'REFUSED (Guard 10)' "$mout" && grep -q 'scripts/review-branch.sh' "$mout"; then
  ok "g: merge refused by Guard 10"
else fail "g: merge not refused by Guard 10 (rc $mrc)"; cat "$mout" >&2; fi

# (h) A HIGH the scorer doubts is dropped and does not block.
# Catches: dropped findings still counting toward the block.
reset_answers
echo 'HIGH | a.swift:1 | DROPME' > "$ANSWERS/deep"
make_branch high-dropped "$license" 20
review
[ "$rc" = 0 ] && ok "h: exit 0" || { fail "h: exit $rc"; show; }
[ -f "$(receipt_path)" ] && ok "h: receipt written" || fail "h: no receipt"

# (i) Cheap escalates to full. Catches: ESCALATE being treated as a finding.
reset_answers
echo 'ESCALATE: needs the store format' > "$ANSWERS/cheap"
make_branch escalate "$analytics" 120
review
grep -q '^ESCALATE:' "$out" && ok "i: escalation printed" || { fail "i: no ESCALATE line"; show; }
n=$(wc -l < "$CLAUDE_LOG" | tr -d ' ')
[ "$n" = 5 ] && [ "$(calls '--model opus')" = 1 ] && ok "i: cheap call then four reviewers" || fail "i: $n claude calls"
last_log | grep -q "$(printf '\tfull-escalated\t')" && ok "i: logged full-escalated" || fail "i: log line '$(last_log)'"

# (j) Cheap findings are counted unscored.
# Catches: cheap findings dropped or sent to the scorer.
reset_answers
echo 'MEDIUM | a.swift:1 | x' > "$ANSWERS/cheap"
make_branch cheap-medium "$analytics" 120
review
[ "$rc" = 0 ] && ok "j: exit 0" || { fail "j: exit $rc"; show; }
[ -f "$(receipt_path)" ] && ok "j: receipt written" || fail "j: no receipt"
last_log | grep -q "$(printf '\tcheap\t0\t1\t0\t0\t')" && ok "j: log counts 0 1 0 0" || fail "j: log line '$(last_log)'"
[ "$(calls '--model haiku')" = 0 ] && ok "j: no scorer call" || fail "j: haiku called"

# (k) A failed or unparseable model call means no review.
# Catches: a broken claude call being taken for a clean review.
reset_answers
echo 1 > "$ANSWERS/cheap.exit"
make_branch cheap-broken "$analytics" 120
review
[ "$rc" = 2 ] && [ ! -f "$(receipt_path)" ] && ok "k: non-zero claude exit → exit 2, no receipt" || { fail "k: exit $rc"; show; }
rm -f "$ANSWERS/cheap.exit"
echo 'Looks fine to me.' > "$ANSWERS/cheap"
review
[ "$rc" = 2 ] && [ ! -f "$(receipt_path)" ] && ok "k: unparseable answer → exit 2, no receipt" || { fail "k: exit $rc"; show; }

# (l) A commit after the review needs a new receipt; the override lands it loudly.
# Catches: a receipt keyed to the branch name instead of the committed diff.
reset_answers
make_branch late-commit "$analytics" 10
review
echo "// after the review" >> "$analytics"; git commit -q --no-verify -am "after review"
merge late-commit
[ "$mrc" != 0 ] && grep -q 'REFUSED (Guard 10)' "$mout" && ok "l: stale receipt refused" || { fail "l: merge not refused"; cat "$mout" >&2; }
merge late-commit AUDIOUT_SKIP_BRANCH_REVIEW=1
[ "$mrc" = 0 ] && grep -q 'WARNING (Guard 10)' "$mout" && ok "l: override landed with a warning" || { fail "l: override failed"; cat "$mout" >&2; }

# (m) --already-reviewed: no model, receipt level external, merge lands.
reset_answers
make_branch external "$analytics" 400
review --already-reviewed
[ ! -s "$CLAUDE_LOG" ] && ok "m: no claude call" || fail "m: claude called"
[ -f "$(receipt_path)" ] && ok "m: receipt written" || fail "m: no receipt"
last_log | grep -q "$(printf '\texternal\t')" && ok "m: logged external" || fail "m: log line '$(last_log)'"
merge external
[ "$mrc" = 0 ] && grep -q 'Guard 10: branch review receipt found (external)' "$mout" && ok "m: merge landed" || { fail "m: merge refused"; cat "$mout" >&2; }

# (n) A reviewed branch with a failing suite is still refused, by the suite.
# Catches: a receipt letting a merge skip the tests.
if command -v swift > /dev/null 2>&1; then
  reset_answers
  make_branch suite-fails "$analytics" 10
  review
  echo 1 > "$RUNNER_EXIT"
  : > "$RUNNER_LOG"
  merge suite-fails
  echo 0 > "$RUNNER_EXIT"
  if [ "$mrc" != 0 ] && grep -q 'Guard 10: branch review receipt found' "$mout" \
     && ! grep -q 'REFUSED (Guard 10)' "$mout" && [ -s "$RUNNER_LOG" ]; then
    ok "n: receipt found, then the failing suite refused the merge"
  else fail "n: rc $mrc"; cat "$mout" >&2; fi
else
  echo "  skip — n: no swift on PATH, Guard 4 would not run"
fi

# (u) An up-to-date branch with no receipt is refused before any tests run.
# Catches: the receipt lookup running after the suite.
reset_answers
make_branch no-receipt "$analytics" 10
: > "$RUNNER_LOG"
merge no-receipt
[ "$mrc" != 0 ] && grep -q 'REFUSED (Guard 10)' "$mout" && grep -q 'no code review receipt' "$mout" \
  && ok "u: missing receipt refused" || { fail "u: not refused"; cat "$mout" >&2; }
[ ! -s "$RUNNER_LOG" ] && ok "u: no tests ran" || fail "u: runner called: $(cat "$RUNNER_LOG")"

# (p) Main moves on: the merge is refused until main is merged into the
# branch, then the old receipt still counts and no new review runs.
# Catches: landing code the suite never saw, or a receipt lost to a sync.
reset_answers
make_branch behind "$analytics" 10
review
advance_main docs/review-test-main.md "unrelated main change"
merge behind
[ "$mrc" != 0 ] && grep -q 'does not contain the latest main' "$mout" && ok "p: out-of-date branch refused" || { fail "p: not refused"; cat "$mout" >&2; }
git checkout -q behind
git merge -q --no-verify --no-edit main > /dev/null 2>&1 || fail "p: syncing main into the branch failed"
merge behind
[ "$mrc" = 0 ] && grep -q 'Guard 10: branch review receipt found' "$mout" && ok "p: synced branch landed on the old receipt" || { fail "p: synced merge refused"; cat "$mout" >&2; }
[ ! -s "$CLAUDE_LOG" ] && ok "p: no new review ran" || fail "p: claude called"

# (q) A conflict resolved by changing the branch's own lines needs a new review.
# Catches: a sync that rewrote the reviewed lines riding on the old receipt.
reset_answers
make_branch rewritten "$analytics" 10
review
advance_main "$analytics" "// main's own line at the same spot"
git checkout -q rewritten
git merge -q --no-verify --no-edit main > /dev/null 2>&1 && fail "q: expected a conflict"
git show main:"$analytics" > "$analytics"
echo "// resolved: the branch's line, changed" >> "$analytics"
git add "$analytics"
git commit -q --no-verify --no-edit
merge rewritten
[ "$mrc" != 0 ] && grep -q 'no code review receipt' "$mout" && ok "q: changed lines need a new receipt" || { fail "q: not refused for a missing receipt"; cat "$mout" >&2; }

# (r) The override still lands an out-of-date branch, loudly.
reset_answers
make_branch behind-override "$analytics" 10
advance_main docs/review-test-main.md "another unrelated main change"
merge behind-override AUDIOUT_SKIP_BRANCH_REVIEW=1
[ "$mrc" = 0 ] && [ "$(grep -c 'WARNING (Guard 10)' "$mout")" = 1 ] && ok "r: override landed an out-of-date branch with one warning" || { fail "r: override failed"; cat "$mout" >&2; }

# (s) Main edits lines near the branch's own: the old receipt still counts.
# Catches: a receipt key that hashes the unchanged lines around the branch's edits.
reset_answers
nearby=docs/review-test-nearby.md
git checkout -q main
seq 1 30 | sed 's/^/line /' > "$nearby"
git add "$nearby"; git commit -q --no-verify -m "nearby file"
git checkout -q -b nearby main
sed -e '10s/.*/line 10 (branch)/' -e '20s/.*/line 20 (branch)/' "$nearby" > "$TMP_DIR/nearby" && cp "$TMP_DIR/nearby" "$nearby"
git commit -q --no-verify -am "nearby"
review
[ -f "$(receipt_path)" ] && ok "s: receipt written" || { fail "s: no receipt"; show; }
git checkout -q main
{ printf 'top 1\ntop 2\ntop 3\n'; sed -e '7s/.*/line 7 (main)/' -e '13s/.*/line 13 (main)/' -e '22s/.*/line 22 (main)/' "$nearby"; } > "$TMP_DIR/nearby" && cp "$TMP_DIR/nearby" "$nearby"
git commit -q --no-verify -am "main edits near the branch's lines"
git checkout -q nearby
git merge -q --no-verify --no-edit main > /dev/null 2>&1 || fail "s: syncing main into the branch did not merge cleanly"
: > "$CLAUDE_LOG"
merge nearby
[ "$mrc" = 0 ] && grep -q 'Guard 10: branch review receipt found' "$mout" && ok "s: nearby main edits kept the receipt" || { fail "s: merge refused"; cat "$mout" >&2; }
[ ! -s "$CLAUDE_LOG" ] && ok "s: no new review ran" || fail "s: claude called"

# (t) An out-of-date branch is refused before any tests run.
# Catches: a refused merge still paying for a suite run.
reset_answers
make_branch stale "$analytics" 10
review
advance_main docs/review-test-main.md "a third unrelated main change"
: > "$RUNNER_LOG"
merge stale
if [ "$mrc" != 0 ] && grep -q 'does not contain the latest main' "$mout" && grep -q 'git merge --abort' "$mout"; then
  ok "t: out-of-date branch refused"
else fail "t: not refused"; cat "$mout" >&2; fi
[ ! -s "$RUNNER_LOG" ] && ok "t: no tests ran" || fail "t: runner called: $(cat "$RUNNER_LOG")"

# (o) The script refuses to review main.
git checkout -q main
before=$(ls "$RECEIPTS" | wc -l | tr -d ' ')
review
after=$(ls "$RECEIPTS" | wc -l | tr -d ' ')
[ "$rc" != 0 ] && [ "$before" = "$after" ] && ok "o: refused on main, no receipt" || { fail "o: exit $rc"; show; }

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES branch review test(s) FAILED" >&2
  exit 1
fi
echo "all branch review tests passed"
