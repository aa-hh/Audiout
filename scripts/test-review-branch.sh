#!/bin/bash
# Proves scripts/review-branch.sh picks the right review level, hands the
# right passes and models to the Claude session, scores and drops findings,
# posts one PR comment and a `review` commit status, blocks only on HIGH, and
# stops after two rounds, reading the round from the PR's comments. It also
# proves the deep pass's model follows risk vs size and round 2 inherits it.
#
# Clones the current checkout into a temp dir and brings over this checkout's
# review script and instruction files. A helper plays the Claude session: it
# reads the passes the script prints, saves a canned reply per pass, and runs
# --continue. GH points at a stub that records every gh call, so no model and
# no GitHub request is ever made.
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
PRINTED="$TMP_DIR/printed"   # every pass line the script printed for one review
PROMPTS="$TMP_DIR/prompts"   # a copy of each prompt the session was handed
ANSWERS="$TMP_DIR/answers"
analytics="AudioutCore/Sources/AudioutCore/Analytics.swift"
license="AudioutCore/Sources/AudioutCore/LicenseGate.swift"
mkdir -p "$ANSWERS" "$PROMPTS"

# The gh stub. GH_CALLS gets one line per call; `pr view` prints the number in
# GH_PR (fails when the file is missing, as gh does with no PR); `pr comment`
# copies the body to GH_COMMENT and appends it to GH_THREAD, the PR's comment
# history; reading the comments prints GH_THREAD; a status post exits with
# the number in GH_API_EXIT.
GH_CALLS="$TMP_DIR/gh-calls"; GH_PR="$TMP_DIR/gh-pr"; GH_THREAD="$TMP_DIR/gh-thread"
GH_COMMENT="$TMP_DIR/gh-comment"; GH_API_EXIT="$TMP_DIR/gh-api-exit"
cat > "$TMP_DIR/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$GH_CALLS"
case "\$*" in
  "pr view"*) [ -f "$GH_PR" ] && cat "$GH_PR" || exit 1 ;;
  "pr comment"*) cp "\$5" "$GH_COMMENT"; cat "\$5" >> "$GH_THREAD" ;;
  *"/comments"*) cat "$GH_THREAD" 2> /dev/null; true ;;
  "api "*) exit "\$(cat "$GH_API_EXIT")" ;;
esac
EOF
chmod +x "$TMP_DIR/gh"
export GH="$TMP_DIR/gh"
echo 42 > "$GH_PR"; echo 0 > "$GH_API_EXIT"

git clone -q "$SRC_ROOT" "$REPO" || { echo "clone failed" >&2; exit 1; }
cd "$REPO" || exit 1
git config user.name test; git config user.email test@example.invalid
git checkout -q -B main

# The clone has only committed content; bring over this checkout's files so
# uncommitted edits are what gets tested.
cp "$SRC_ROOT/scripts/review-branch.sh" scripts/review-branch.sh
cp "$SRC_ROOT/.gitignore" .gitignore
rm -rf docs/review && cp -R "$SRC_ROOT/docs/review" docs/review
git add -A .gitignore docs/review scripts/review-branch.sh
git commit -q --no-verify --allow-empty -m "test setup" || { echo "setup commit failed" >&2; exit 1; }
# origin is the clone itself, so the script's `git fetch origin` makes
# origin/main follow this clone's main.
git remote set-url origin "$REPO"

COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
REVIEW_LOG="$COMMON/audiout-branch-reviews.log"

# make_branch <name> <file> <lines>: a branch off main adding <lines> comment
# lines to <file>, committed past the hooks and left checked out. The lines
# carry the branch name: the pending review is keyed on the diff, so two
# branches with the same diff would share one.
make_branch() {
  rm -f "$GH_THREAD"   # a new branch is a new PR
  git checkout -q -b "$1" main
  mkdir -p "$(dirname "$2")"
  for i in $(seq 1 "$3"); do echo "// review test line $i ($1)" >> "$2"; done
  git add "$2"
  git commit -q --no-verify -m "$1"
}

# reset_answers: every pass answers NO FINDINGS; no pass lines, prompts or gh
# calls seen; the branch has PR 42 and every gh call succeeds.
reset_answers() {
  rm -rf "$ANSWERS" "$PROMPTS"; mkdir -p "$ANSWERS" "$PROMPTS"; : > "$PRINTED"
  : > "$GH_CALLS"; rm -f "$GH_COMMENT"; echo 42 > "$GH_PR"; echo 0 > "$GH_API_EXIT"
}

# answer_passes <output>: play the Claude session for every pass line in
# <output>. Reviewer passes answer from $ANSWERS/<pass> (default NO FINDINGS);
# $ANSWERS/<pass>.missing saves no reply. Score passes answer SCORE: 40 when
# the finding contains DROPME, else SCORE: 95.
answer_passes() {
  grep -F '  save reply to=' "$1" | while IFS= read -r l; do
    name=${l%%  *}
    prompt=$(printf '%s\n' "$l" | sed -n 's/.*  prompt=\(.*\)  save reply to=.*/\1/p')
    reply=${l##*  save reply to=}
    echo "$l" >> "$PRINTED"
    cp "$prompt" "$PROMPTS/$name.prompt"
    [ -f "$ANSWERS/$name.missing" ] && continue
    case "$name" in
      score-*) if sed -n '/^## Finding$/,/^## Repo rules$/p' "$prompt" | grep -q DROPME
               then echo "SCORE: 40"; else echo "SCORE: 95"; fi ;;
      *) if [ -f "$ANSWERS/$name" ]; then cat "$ANSWERS/$name"; else echo "NO FINDINGS"; fi ;;
    esac > "$reply"
  done
}

# review [args]: run the script on the checked-out branch, answer its passes
# and run --continue until it stops asking. Sets $rc and $out (every step's
# output, in order).
review() {
  out="$TMP_DIR/review.out"; : > "$out"
  bash scripts/review-branch.sh "$@" > "$out.step" 2>&1; rc=$?
  cat "$out.step" >> "$out"
  local steps=0
  while [ "$rc" = 3 ] && [ "$steps" -lt 5 ]; do
    steps=$((steps + 1))
    answer_passes "$out.step"
    bash scripts/review-branch.sh --continue > "$out.step" 2>&1; rc=$?
    cat "$out.step" >> "$out"
  done
}

# start_review: only the first step, no answers. Sets $rc, $out.
start_review() {
  out="$TMP_DIR/review.out"
  bash scripts/review-branch.sh > "$out" 2>&1; rc=$?
}

pending_path() {
  local key
  key=$(git diff -U0 --no-renames "$(git merge-base origin/main HEAD)" HEAD | git patch-id --stable | cut -d' ' -f1)
  echo "$REPO/.review-pending/${key:-empty}"
}
# printed <text>: how many pass lines the script printed containing <text>.
printed() { grep -c -F -- "$1" "$PRINTED"; }
last_log() { tail -n 1 "$REVIEW_LOG"; }
show() { cat "$out" >&2; }
# status_call: the one `api` call, or nothing. statuses: how many were made.
status_call() { grep '^api repos/aa-hh/Audiout/statuses/' "$GH_CALLS"; }
statuses() { grep -c '^api repos/aa-hh/Audiout/statuses/' "$GH_CALLS"; }
comments() { grep -c '^pr comment ' "$GH_CALLS"; }

# (a) Docs only: no model; a comment that records the round, and a success
# status "skip".
# Catches: docs counting as product lines, or a skip that posts no status or
# leaves no round on the PR.
reset_answers
make_branch docs-only docs/review-test-notes.md 80
review
grep -q '^Review level: skip' "$out" && ok "a: level skip" || { fail "a: not skip"; show; }
[ "$rc" = 0 ] && [ ! -s "$PRINTED" ] && ok "a: no pass handed over" || fail "a: rc $rc, passes: $(cat "$PRINTED")"
if [ "$(statuses)" = 1 ] && [ "$(comments)" = 1 ] \
   && head -n 1 "$GH_COMMENT" | grep -qx "<!-- audiout-review round=1 head=$(git rev-parse HEAD) level=skip high=0 changes=none deep=- -->" \
   && [ "$(status_call)" = "api repos/aa-hh/Audiout/statuses/$(git rev-parse HEAD) -f context=review -f state=success -f description=skip" ]; then
  ok "a: success status 'skip' on HEAD, comment carries the round marker"
else fail "a: gh calls: $(cat "$GH_CALLS")"; fi

# (b) 10 product lines: skip. Catches: a small change paying for a model.
reset_answers
make_branch small "$analytics" 10
review
grep -q '^Review level: skip (10 product lines), round 1' "$out" && ok "b: level skip" || { fail "b: not skip"; show; }

# (c) 120 lines: cheap, one sonnet pass with its own prompt; clean result
# posts "Review: no findings" and a success status.
# Catches: wrong thresholds, the cheap pass on the wrong model, a prompt
# missing its instructions or output format, or a clean review left unposted.
reset_answers
make_branch medium "$analytics" 120
review
grep -q '^Review level: cheap' "$out" && ok "c: level cheap" || { fail "c: not cheap"; show; }
n=$(wc -l < "$PRINTED" | tr -d ' ')
[ "$n" = 1 ] && [ "$(printed 'cheap  model=sonnet  prompt=')" = 1 ] && ok "c: one sonnet pass" || fail "c: passes: $(cat "$PRINTED")"
if head -n 1 "$PROMPTS/cheap.prompt" | grep -qx '# Review pass: cheap' \
   && grep -q '^Output format' "$PROMPTS/cheap.prompt" && grep -q '^## Diff' "$PROMPTS/cheap.prompt"; then
  ok "c: prompt has the pass header, output format and diff"
else fail "c: cheap prompt wrong"; fi
grep -q 'Then run: bash scripts/review-branch.sh --continue' "$out" && ok "c: handover steps printed" || { fail "c: no handover steps"; show; }
[ ! -e "$(pending_path)" ] && ok "c: pending directory removed" || fail "c: pending directory left"
[ "$rc" = 0 ] && ok "c: exit 0" || fail "c: exit $rc"
grep -q '^pr comment 42 --body-file ' "$GH_CALLS" && [ "$(comments)" = 1 ] \
  && head -n 1 "$GH_COMMENT" | grep -qx "<!-- audiout-review round=1 head=$(git rev-parse HEAD) level=cheap high=0 changes=[0-9a-f]* deep=- -->" \
  && sed -n 2p "$GH_COMMENT" | grep -qx '## Review: cheap, round 1' && grep -qx 'Review: no findings' "$GH_COMMENT" \
  && ok "c: one comment on PR 42: marker, heading, then 'Review: no findings'" || { fail "c: comment wrong"; cat "$GH_CALLS" "$GH_COMMENT" >&2; }
status_call | grep -q -- '-f state=success -f description=cheap, round 1, 0 HIGH$' \
  && ok "c: success status 'cheap, round 1, 0 HIGH'" || fail "c: status: $(status_call)"
[ "$(head -n 1 "$GH_CALLS" | cut -d' ' -f1-2)" = "pr view" ] && [ "$(tail -n 1 "$GH_CALLS" | cut -d' ' -f1)" = api ] \
  && ok "c: comment posted before the status" || fail "c: gh call order: $(cat "$GH_CALLS")"
last_log | grep -q "$(printf '\tcheap\t0\t0\t0\t0\t')" && ok "c: log counts 0 0 0 0" || fail "c: log line '$(last_log)'"
[ "$(last_log | cut -f9)" = - ] && ok "c: log gains a trailing - column" || fail "c: log column 9 '$(last_log | cut -f9)'"

# (d) 400 lines: full, four reviewers with their own model.
# Catches: a reviewer on the wrong model, or the history pass without its git limits.
reset_answers
make_branch large "$analytics" 400
review
grep -q '^Review level: full' "$out" && ok "d: level full" || { fail "d: not full"; show; }
n=$(wc -l < "$PRINTED" | tr -d ' ')
[ "$n" = 4 ] && ok "d: four reviewer passes" || fail "d: $n passes"
[ "$(printed 'deep  model=opus  ')" = 1 ] && ok "d: deep reviewer on opus for a size-only full" || fail "d: passes: $(cat "$PRINTED")"
sed -n 2p "$GH_COMMENT" | grep -qx '## Review: full, round 1 (deep pass: opus)' \
  && head -n 1 "$GH_COMMENT" | grep -q ' deep=opus -->$' && [ "$(last_log | cut -f9)" = opus ] \
  && ok "d: heading, marker and log name opus" || fail "d: deep record wrong: $(head -n 2 "$GH_COMMENT")"

[ "$(printed 'rules  model=sonnet  ')" = 1 ] && [ "$(printed 'history  model=sonnet  ')" = 1 ] \
  && [ "$(printed 'comments  model=sonnet  ')" = 1 ] && ok "d: three sonnet reviewers" || fail "d: sonnet passes wrong"
grep -q 'The history pass may only run git log and git blame' "$out" \
  && ok "d: history reviewer limited to git log and git blame" || { fail "d: no history limit printed"; show; }
[ "$(printed 'model=haiku')" = 0 ] && ok "d: no scorer pass without findings" || fail "d: haiku pass printed"
[ "$rc" = 0 ] && ok "d: exit 0" || fail "d: exit $rc"

# (e) 20 lines in a licence file: full. Catches: risk paths not forcing full.
reset_answers
make_branch risky "$license" 20
review
grep -q '^Review level: full (20 product lines, risk: AudioutCore/Sources/AudioutCore/LicenseGate.swift)' "$out" \
  && ok "e: risk path forces full" || { fail "e: not full"; show; }
# Catches: the deep model ignoring the risk path, or the record naming another model.
[ "$(printed 'deep  model=fable  ')" = 1 ] && sed -n 2p "$GH_COMMENT" | grep -qx '## Review: full, round 1 (deep pass: fable)' \
  && head -n 1 "$GH_COMMENT" | grep -q ' deep=fable -->$' && [ "$(last_log | cut -f9)" = fable ] \
  && ok "e: risk path puts the deep pass on fable, recorded" || fail "e: deep record wrong: $(cat "$PRINTED")"

# (f) Scoring: one haiku pass per finding, under 75 dropped and listed apart.
# A surviving LOW is posted but does not block.
# Catches: a low-confidence finding counted, one dropped silently, or a LOW
# failing the status.
reset_answers
printf 'LOW | a.swift:1 | real\nLOW | a.swift:2 | DROPME nit\n' > "$ANSWERS/deep"
echo 'MEDIUM | a.swift:3 | DROPME' > "$ANSWERS/rules"
make_branch scored "$license" 20
review
[ "$(printed 'model=haiku')" = 3 ] && ok "f: three scorer passes" || fail "f: $(printed 'model=haiku') scorer passes"
if head -n 1 "$PROMPTS/score-1.prompt" | grep -qx '# Review pass: score' && grep -q '^## Finding$' "$PROMPTS/score-1.prompt"; then
  ok "f: score prompt carries the finding"
else fail "f: score prompt wrong"; fi
kept_part=$(sed '/^Dropped by scorer:/,$d' "$out")
dropped_part=$(sed -n '/^Dropped by scorer:/,$p' "$out")
if printf '%s\n' "$kept_part" | grep -q 'a.swift:1' && ! printf '%s\n' "$kept_part" | grep -q DROPME \
   && [ "$(printf '%s\n' "$dropped_part" | grep -c DROPME)" = 2 ]; then
  ok "f: survivor kept, two DROPME lines under Dropped by scorer"
else fail "f: wrong split"; show; fi
grep -q '^Findings: 0 high, 0 medium, 1 low (2 dropped)$' "$out" && ok "f: counts" || { fail "f: counts"; show; }
[ "$rc" = 0 ] && ! grep -q '^fix-' "$out" && ok "f: a LOW does not block (exit 0, no fix group)" || { fail "f: exit $rc"; show; }
grep -qx '### LOW' "$GH_COMMENT" && grep -qx -- '- a.swift:1: real' "$GH_COMMENT" && ! grep -q DROPME "$GH_COMMENT" \
  && ok "f: comment lists the LOW survivor with file:line, not the dropped ones" || { fail "f: comment wrong"; cat "$GH_COMMENT" >&2; }
status_call | grep -q -- '-f state=success ' && ok "f: status success" || fail "f: status: $(status_call)"

# (g) A surviving HIGH exits 1, fails the status, and gets a fix group.
# Catches: a HIGH from a non-deep reviewer being ignored.
reset_answers
echo 'HIGH | a.swift:1 | x' > "$ANSWERS/comments"
echo 'LOW | b.swift:4 | y' > "$ANSWERS/rules"
make_branch high "$license" 20
review
[ "$rc" = 1 ] && ok "g: exit 1" || { fail "g: exit $rc"; show; }
grep -q 'then run round 2, which reviews only the fix: bash scripts/review-branch.sh' "$out" \
  && ok "g: fix instructions printed" || { fail "g: no fix instructions"; show; }
[ "$(grep -c '^fix-' "$out")" = 1 ] && grep -qx 'fix-1  file=a.swift' "$out" \
  && ok "g: one fix group, for the HIGH only" || { fail "g: fix groups wrong"; show; }
status_call | grep -q -- '-f state=failure -f description=full, round 1, 1 HIGH$' \
  && ok "g: failure status 'full, round 1, 1 HIGH'" || fail "g: status: $(status_call)"
if [ "$(sed -n '/^### HIGH$/,/^### /p' "$GH_COMMENT" | grep -c '^- a.swift:1: x$')" = 1 ] \
   && grep -qx -- '- b.swift:4: y' "$GH_COMMENT" \
   && [ "$(grep -n '^### HIGH$' "$GH_COMMENT" | cut -d: -f1)" -lt "$(grep -n '^### LOW$' "$GH_COMMENT" | cut -d: -f1)" ]; then
  ok "g: comment groups HIGH before LOW"
else fail "g: comment wrong"; cat "$GH_COMMENT" >&2; fi

# (g2) Round 2 reviews only the fix, never skips, and a clean result passes.
# The round comes from the PR comments alone: local review files are wiped.
# Catches: round 2 re-reviewing the whole branch, a small fix skipped unseen,
# or round state kept in the checkout instead of on the PR.
reset_answers
echo "// the fix" >> "$analytics"; git commit -q --no-verify -am "fix"
rm -rf .review-pending
review
grep -q '^Review level: cheap (1 product lines), round 2' "$out" && ok "g2: round 2 is cheap over the one fix line" || { fail "g2: level line"; show; }
grep -q '^+// the fix$' "$PROMPTS/cheap.prompt" && ! grep -q 'review test line' "$PROMPTS/cheap.prompt" \
  && ok "g2: prompt holds only the fix diff" || fail "g2: prompt diff wrong"
[ "$rc" = 0 ] && status_call | grep -q -- '-f state=success -f description=cheap, round 2, 0 HIGH$' \
  && ok "g2: exit 0, success status for round 2" || { fail "g2: exit $rc, status $(status_call)"; show; }

# (g3) A third run refuses.
# Catches: the two-round limit dropped, or the round read from anything but
# the highest marker on the PR.
reset_answers
echo "// more" >> "$analytics"; git commit -q --no-verify -am "more"
review
[ "$rc" = 1 ] && grep -qx 'two rounds done; remaining findings are on the PR' "$out" \
  && [ "$(statuses)" = 0 ] && [ "$(comments)" = 0 ] \
  && ok "g3: third run refused, exit 1, nothing posted" || { fail "g3: exit $rc"; show; }

# (g4) A HIGH that survives round 2 exits 1 with no fix group.
# Catches: fix groups printed for a third round that will be refused.
reset_answers
echo 'HIGH | a.swift:1 | x' > "$ANSWERS/comments"
make_branch high-twice "$license" 20
review
echo "// not a fix" >> "$license"; git commit -q --no-verify -am "attempt"
review
[ "$rc" = 1 ] && grep -qx 'two rounds done; remaining findings are on the PR' "$out" && ! grep -q '^fix-' "$out" \
  && status_call | tail -n 1 | grep -q -- '-f state=failure -f description=full, round 2, 1 HIGH$' \
  && ok "g4: HIGH after round 2 → exit 1, failure status, no fix group" || { fail "g4: exit $rc"; show; }

# (g5) Re-running on a head already reviewed re-posts that round's status
# and reviews nothing.
# Catches: re-running on the same head turning a failed status into a skip.
reset_answers
echo 'HIGH | a.swift:1 | x' > "$ANSWERS/comments"
make_branch high-norerun "$license" 20
review
reset_answers
review
[ "$rc" = 1 ] && grep -q 'already reviewed in round 1' "$out" && [ "$(comments)" = 0 ] && [ ! -s "$PRINTED" ] \
  && status_call | grep -q -- '-f state=failure -f description=full, round 1, 1 HIGH$' \
  && ok "g5: same head → failure status re-posted, exit 1, no new review" || { fail "g5: exit $rc"; show; }

# (g6) Round 2 inherits round 1's deep model.
# Catches: round 2 recomputing the deep model from its own diff instead of reading the marker.
reset_answers
echo 'HIGH | a.swift:1 | x' > "$ANSWERS/comments"
make_branch inherit "$analytics" 400
review
[ "$(printed 'deep  model=opus  ')" = 1 ] && ok "g6: round 1 deep on opus" || fail "g6: passes: $(cat "$PRINTED")"
reset_answers
echo '// fix' >> "$license"
git add "$license" && git commit -q --no-verify -m fix
review
grep -q '^Review level: full (1 product lines, risk: .*LicenseGate.swift), round 2' "$out" \
  && [ "$(printed 'deep  model=opus  ')" = 1 ] && sed -n 2p "$GH_COMMENT" | grep -qx '## Review: full, round 2 (deep pass: opus)' \
  && head -n 1 "$GH_COMMENT" | grep -q ' deep=opus -->$' \
  && ok "g6: round 2 keeps opus although the risk path alone says fable" || { fail "g6: round 2 wrong"; show; }

# (g7) An old marker without deep= gets the rule applied to this round's diff.
# Catches: a missing deep= field breaking round 2 or leaving the deep model empty.
reset_answers
make_branch old-marker "$analytics" 10
echo "<!-- audiout-review round=1 head=$(git rev-parse HEAD) level=full high=1 changes=stale -->" > "$GH_THREAD"
for i in $(seq 1 400); do echo "// line $i" >> "$analytics"; done
git add "$analytics" && git commit -q --no-verify -m big
review
grep -q 'round 2$' "$out" && [ "$(printed 'deep  model=opus  ')" = 1 ] && head -n 1 "$GH_COMMENT" | grep -q ' deep=opus -->$' \
  && ok "g7: old marker, deep pass on opus by the size rule" || { fail "g7: wrong"; show; }

# (h) A HIGH the scorer doubts is dropped and does not block.
# Catches: dropped findings still counting toward the block.
reset_answers
echo 'HIGH | a.swift:1 | DROPME' > "$ANSWERS/deep"
make_branch high-dropped "$license" 20
review
[ "$rc" = 0 ] && grep -qx 'Review: no findings' "$GH_COMMENT" && ok "h: exit 0, no findings posted" || { fail "h: exit $rc"; show; }

# (i) Cheap escalates to full. Catches: ESCALATE being treated as a finding.
reset_answers
echo 'ESCALATE: needs the store format' > "$ANSWERS/cheap"
make_branch escalate "$analytics" 120
review
grep -q '^ESCALATE:' "$out" && ok "i: escalation printed" || { fail "i: no ESCALATE line"; show; }
n=$(wc -l < "$PRINTED" | tr -d ' ')
[ "$n" = 5 ] && [ "$(head -n 1 "$PRINTED" | cut -d' ' -f1)" = cheap ] && [ "$(printed 'model=opus')" = 1 ] \
  && ok "i: cheap pass then four reviewers" || fail "i: passes: $(cat "$PRINTED")"
last_log | grep -q "$(printf '\tfull-escalated\t')" && ok "i: logged full-escalated" || fail "i: log line '$(last_log)'"
[ "$(last_log | cut -f9)" = opus ] && ok "i: escalated deep pass logged as opus" || fail "i: log column 9 '$(last_log | cut -f9)'"

# (j) Cheap findings are counted unscored; a MEDIUM does not block.
# Catches: cheap findings dropped, sent to the scorer, or a MEDIUM blocking.
reset_answers
echo 'MEDIUM | a.swift:1 | x' > "$ANSWERS/cheap"
make_branch cheap-medium "$analytics" 120
review
[ "$rc" = 0 ] && ! grep -q '^fix-' "$out" && ok "j: exit 0, no fix group" || { fail "j: exit $rc"; show; }
grep -qx '### MEDIUM' "$GH_COMMENT" && grep -qx -- '- a.swift:1: x' "$GH_COMMENT" && ok "j: MEDIUM posted" || fail "j: comment wrong"
last_log | grep -q "$(printf '\tcheap\t0\t1\t0\t0\t')" && ok "j: log counts 0 1 0 0" || fail "j: log line '$(last_log)'"
[ "$(printed 'model=haiku')" = 0 ] && ok "j: no scorer pass" || fail "j: haiku pass printed"

# (k) An unparseable reply means no review.
# Catches: a reply in the wrong format being taken for a clean review.
reset_answers
echo 'Looks fine to me.' > "$ANSWERS/cheap"
make_branch cheap-broken "$analytics" 120
review
[ "$rc" = 2 ] && [ "$(statuses)" = 0 ] && ok "k: unparseable answer → exit 2, no status" || { fail "k: exit $rc"; show; }

# (l) No pull request: round 1 against main, the body is printed instead, and
# the status still posts.
# Catches: a missing PR aborting before the status posts.
reset_answers
rm -f "$GH_PR"
make_branch no-pr "$analytics" 120
review
[ "$rc" = 0 ] && grep -q '^No pull request for no-pr' "$out" && grep -qx 'Review: no findings' "$out" \
  && [ "$(comments)" = 0 ] && [ "$(statuses)" = 1 ] \
  && ok "l: no PR → body printed, status posted, exit 0" || { fail "l: exit $rc"; show; }

# (m) A failed status post exits 2; running again re-posts it from the marker.
# Catches: an unpushed head silently counting as reviewed, or a retry
# starting a second round on the same commit.
reset_answers
echo 1 > "$GH_API_EXIT"
make_branch unpushed "$analytics" 120
review
[ "$rc" = 2 ] && grep -q 'Push the branch' "$out" && ok "m: failed status → exit 2" || { fail "m: exit $rc"; show; }
echo 0 > "$GH_API_EXIT"
: > "$GH_CALLS"
bash scripts/review-branch.sh --continue > "$out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'already reviewed in round 1' "$out" && [ "$(comments)" = 0 ] \
  && status_call | grep -q -- '-f state=success -f description=cheap, round 1, 0 HIGH$' \
  && ok "m: running again re-posts round 1's status" || { fail "m: retry exit $rc"; show; }

# (n) A docs-only commit after a review uses no round: same own changes, so
# round 1's status is re-posted on the new HEAD with no new comment.
# Catches: a push that leaves the branch's own lines alone consuming a round.
reset_answers
make_branch same-changes "$analytics" 120
review
first=$(git rev-parse HEAD)
reset_answers
echo "notes" >> docs/review-test-notes.md; git add docs/review-test-notes.md; git commit -q --no-verify -m "docs only"
review
[ "$rc" = 0 ] && [ "$(comments)" = 0 ] && [ ! -s "$PRINTED" ] && grep -q 'already reviewed in round 1' "$out" \
  && status_call | grep -q "statuses/$(git rev-parse HEAD) .*-f state=success -f description=cheap, round 1, 0 HIGH$" \
  && [ "$(git rev-parse HEAD)" != "$first" ] \
  && ok "n: docs-only commit → round 1 status re-posted on the new HEAD, no round used" || { fail "n: exit $rc"; show; }
reset_answers
echo "// real change" >> "$analytics"; git commit -q --no-verify -am "code"
start_review
grep -q ', round 2$' "$out" && ok "n: the next code change is round 2" || { fail "n: not round 2"; show; }

# (n2) Merging main into the branch, with main's change elsewhere, uses no round.
# Catches: the old receipt's "merging main in keeps the review" rule lost.
reset_answers
make_branch main-merged "$analytics" 120
review
git checkout -q main
echo "// main moves" >> "$license"; git commit -q --no-verify -am "main moves"
git checkout -q main-merged
git merge -q --no-verify --no-edit main > /dev/null 2>&1 || fail "n2: merging main did not merge cleanly"
reset_answers
review
[ "$rc" = 0 ] && [ "$(comments)" = 0 ] && [ ! -s "$PRINTED" ] \
  && status_call | grep -q "statuses/$(git rev-parse HEAD) .*-f state=success -f description=cheap, round 1, 0 HIGH$" \
  && ok "n2: main merged in → round 1 status re-posted on the merge commit, no round used" || { fail "n2: exit $rc"; show; }

# (v) A commit between the handover and --continue means no review.
# Catches: replies about older code recorded against the new code.
reset_answers
make_branch moved-on "$analytics" 120
start_review
[ "$rc" = 3 ] && ok "v: handover exits 3" || { fail "v: exit $rc"; show; }
echo "// committed after the handover" >> "$analytics"; git commit -q --no-verify -am "after handover"
answer_passes "$out"
bash scripts/review-branch.sh --continue > "$out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'Run again with no flag' "$out" && [ "$(statuses)" = 0 ] \
  && ok "v: changed branch → exit 2, no status" || { fail "v: exit $rc"; show; }

# (w) A pass with no saved reply means no review, and the message names it.
# Catches: a skipped reviewer being taken for a clean one.
reset_answers
touch "$ANSWERS/rules.missing"
make_branch no-reply "$license" 20
review
[ "$rc" = 2 ] && grep -q 'no reply saved for the rules pass' "$out" && [ "$(statuses)" = 0 ] \
  && ok "w: missing reply → exit 2 naming the pass" || { fail "w: exit $rc"; show; }

# (x) A handover that broke before listing its passes means no review.
# Catches: an empty pass list counting zero findings and posting success.
reset_answers
make_branch half-planned "$analytics" 120
start_review
rm -f "$(pending_path)/passes"
bash scripts/review-branch.sh --continue > "$out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'no reviewer passes were handed over' "$out" && [ "$(statuses)" = 0 ] \
  && ok "x: no pass list → exit 2, no status" || { fail "x: exit $rc"; show; }

# (y) Fix groups: one per file, a file's HIGH findings together.
# Catches: two builders handed the same file, or one file's findings split.
reset_answers
printf 'HIGH | a.swift:1 | x\nHIGH | b.swift:2 | y\n' > "$ANSWERS/cheap"
make_branch two-files "$analytics" 120
review
if [ "$rc" = 1 ] && [ "$(grep -c '^fix-' "$out")" = 2 ] && grep -qx 'fix-1  file=a.swift' "$out" \
   && grep -qx 'fix-2  file=b.swift' "$out"; then
  ok "y: two files → two fix groups"
else fail "y: two-file groups wrong (rc $rc)"; show; fi
reset_answers
printf 'HIGH | b.swift:2 | first\nHIGH | b.swift:9 | second\n' > "$ANSWERS/cheap"
make_branch one-file "$analytics" 120
review
group=$(sed -n '/^fix-1  file=b.swift$/,/^$/p' "$out")
if [ "$rc" = 1 ] && [ "$(grep -c '^fix-' "$out")" = 1 ] \
   && printf '%s\n' "$group" | grep -qx '    HIGH | b.swift:2 | first' \
   && printf '%s\n' "$group" | grep -qx '    HIGH | b.swift:9 | second'; then
  ok "y: one file → one fix group with both lines"
else fail "y: one-file group wrong (rc $rc)"; show; fi

# (o) The script refuses to review main.
git checkout -q main
reset_answers
review
[ "$rc" != 0 ] && [ ! -s "$GH_CALLS" ] && ok "o: refused on main, gh never called" || { fail "o: exit $rc"; show; }

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES branch review test(s) FAILED" >&2
  exit 1
fi
echo "all branch review tests passed"
