#!/bin/bash
# Proves scripts/review-status.sh posts the `review` status from the newest
# aa-hh marker comment on a PR: on the head it names, on a later head whose own
# changes are unchanged, and never on a head with new changes or without a
# marker.
#
# Builds a throwaway repo whose origin carries main and refs/pull/7/head. GH
# points at a stub that serves the PR head and its comments from files and
# records every call, so no GitHub request is ever made.
#
# Usage: scripts/test-review-status.sh

set -uo pipefail   # deliberately NOT -e: the tests assert on expected failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/review-status.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok — $1"; }

# The gh stub. HEAD_FILE holds the PR head; COMMENTS holds the comments API's
# JSON; CALLS gets one line per call.
CALLS="$TMP_DIR/calls"; HEAD_FILE="$TMP_DIR/head"; COMMENTS="$TMP_DIR/comments"
cat > "$TMP_DIR/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$CALLS"
case "\$*" in
  "api repos/aa-hh/Audiout/pulls/7 --jq .head.sha") cat "$HEAD_FILE" ;;
  "api --paginate repos/aa-hh/Audiout/issues/7/comments") cat "$COMMENTS" ;;
  "api repos/aa-hh/Audiout/statuses/"*) true ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/gh"
export GH="$TMP_DIR/gh"

ORIGIN="$TMP_DIR/origin.git"; WORK="$TMP_DIR/work"; CLONE="$TMP_DIR/clone"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$WORK"
cd "$WORK" || exit 1
git config user.name test; git config user.email test@example.invalid
echo base > a.swift; git add a.swift; git commit -q -m base
git remote add origin "$ORIGIN"; git push -q origin main
git checkout -q -b feature
echo code >> a.swift; git commit -q -am code
reviewed=$(git rev-parse HEAD)
# changes_of <commit>: the patch id review-branch.sh puts in its marker.
changes_of() { git diff "$(git merge-base origin/main "$1")" "$1" -- . ':!*.md' | git patch-id --stable | cut -d' ' -f1; }
reviewed_changes=$(changes_of "$reviewed")
git clone -q "$ORIGIN" "$CLONE"

# set_pr <commit>: the PR head, on the API and as origin's refs/pull/7/head.
set_pr() { echo "$1" > "$HEAD_FILE"; git -C "$WORK" push -q -f origin "$1:refs/pull/7/head"; }
# comment <login> <marker fields>: one comment by <login> whose first line is the marker.
comment() { jq -nc --arg u "$1" --arg b "<!-- audiout-review $2 -->"$'\n'"## Review" '{user: {login: $u}, body: $b}'; }
# comments <json objects...>: the comments API's one page.
comments() { printf '%s\n' "$@" | jq -s . > "$COMMENTS"; }
run() { : > "$CALLS"; out=$(cd "$CLONE" && bash "$SCRIPT_DIR/review-status.sh" 7 2>&1); rc=$?; }
status_of() { grep "^api repos/aa-hh/Audiout/statuses/$1 " "$CALLS"; }
statuses() { grep -c '^api repos/aa-hh/Audiout/statuses/' "$CALLS"; }

# (a) The marker names the PR head: that round's status on it.
# Catches: a status built from the wrong fields or posted on another commit.
set_pr "$reviewed"
comments "$(comment aa-hh "round=1 head=$reviewed level=cheap high=0 changes=$reviewed_changes")"
run
[ "$rc" = 0 ] && [ "$(status_of "$reviewed")" = "api repos/aa-hh/Audiout/statuses/$reviewed -f context=review -f state=success -f description=cheap, round 1, 0 HIGH" ] \
  && ok "a: success 'cheap, round 1, 0 HIGH' on the reviewed head" || fail "a: rc $rc, calls: $(cat "$CALLS") $out"

# (b) A HIGH finding fails the status. Catches: a blocking review posted green.
comments "$(comment aa-hh "round=1 head=$reviewed level=full high=2 changes=$reviewed_changes")"
run
status_of "$reviewed" | grep -q -- '-f state=failure -f description=full, round 1, 2 HIGH$' \
  && ok "b: failure 'full, round 1, 2 HIGH'" || fail "b: calls: $(cat "$CALLS") $out"

# (c) The newest round wins, whatever the comment order.
# Catches: the first marker read, so a fixed PR stays red.
comments "$(comment aa-hh "round=2 head=$reviewed level=cheap high=0 changes=$reviewed_changes")" \
  "$(comment aa-hh "round=1 head=$reviewed level=full high=2 changes=$reviewed_changes")"
run
status_of "$reviewed" | grep -q -- '-f state=success -f description=cheap, round 2, 0 HIGH$' \
  && ok "c: round 2 decides" || fail "c: calls: $(cat "$CALLS") $out"

# (d) Level skip reads 'skip'. Catches: 'skip, round 1, 0 HIGH'.
comments "$(comment aa-hh "round=1 head=$reviewed level=skip high=0 changes=$reviewed_changes")"
run
status_of "$reviewed" | grep -q -- '-f state=success -f description=skip$' \
  && ok "d: skip reads 'skip'" || fail "d: calls: $(cat "$CALLS") $out"

# (e) Another user's marker is ignored. Catches: anyone who can comment
# setting a required check.
comments "$(comment someone "round=1 head=$reviewed level=cheap high=0 changes=$reviewed_changes")"
run
[ "$rc" = 0 ] && [ "$(statuses)" = 0 ] && ok "e: someone else's marker posts nothing" || fail "e: calls: $(cat "$CALLS") $out"

# (f) No marker: nothing. Catches: a status invented for an unreviewed PR.
comments '{"user": {"login": "aa-hh"}, "body": "just a comment"}'
run
[ "$rc" = 0 ] && [ "$(statuses)" = 0 ] && ok "f: no marker posts nothing" || fail "f: calls: $(cat "$CALLS") $out"

# (g) A docs-only commit on top keeps the reviewed changes: the round's status
# moves to the new head. Catches: every docs push leaving the PR without a status.
cd "$WORK" || exit 1
echo notes > notes.md; git add notes.md; git commit -q -m docs
docs_head=$(git rev-parse HEAD)
set_pr "$docs_head"
comments "$(comment aa-hh "round=1 head=$reviewed level=cheap high=0 changes=$reviewed_changes")"
run
[ "$rc" = 0 ] && status_of "$docs_head" | grep -q -- '-f state=success -f description=cheap, round 1, 0 HIGH$' \
  && ok "g: docs-only push gets round 1's status on its head" || fail "g: rc $rc, calls: $(cat "$CALLS") $out"

# (h) New code after the review: no status. Catches: an unreviewed change
# inheriting the last green review.
echo more >> a.swift; git commit -q -am more
set_pr "$(git rev-parse HEAD)"
run
[ "$rc" = 0 ] && [ "$(statuses)" = 0 ] && ok "h: new code posts nothing" || fail "h: calls: $(cat "$CALLS") $out"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES review status test(s) FAILED" >&2
  exit 1
fi
echo "all review status tests passed"
