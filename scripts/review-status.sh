#!/bin/bash
# Posts the `review` commit status on a pull request's head from the marker
# comment scripts/review-branch.sh leaves on it. Run by the review-status
# workflow: a cloud session can post that comment, but its proxy refuses
# status writes, so the status comes from here. A Mac session posts the same
# status itself, so this posts it a second time with the same value.
#
# Only comments by aa-hh count. The newest round's marker decides:
#   - marker head = PR head: post that round's status.
#   - another head, same own changes (the marker's changes= patch id of the
#     non-Markdown diff against origin/main; main merged in, a docs-only
#     commit): post that round's status on the new head, as review-branch.sh
#     does when run again.
#   - another head with new changes, or no marker: post nothing; the branch
#     needs review-branch.sh again.
#
# Usage: scripts/review-status.sh <pr number>   (run inside a full clone)
# GH overrides the gh command (the self-test points it at a stub).

set -euo pipefail

pr=${1:?usage: review-status.sh <pr number>}
GH=${GH:-gh}
repo=aa-hh/Audiout

head=$($GH api "repos/$repo/pulls/$pr" --jq .head.sha)
last=$($GH api --paginate "repos/$repo/issues/$pr/comments" \
  | jq -r '.[] | select(.user.login == "aa-hh") | .body' \
  | grep '^<!-- audiout-review round=[0-9]' \
  | sed 's/^<!-- audiout-review round=\([0-9]*\)/\1	&/' | sort -n | tail -n 1 | cut -f2- || true)
if [ -z "$last" ]; then
  echo "PR #$pr has no review marker yet; nothing to post."
  exit 0
fi
field() { printf '%s\n' "$last" | sed -n "s/.* $1=\([^ ]*\).*/\1/p"; }
round=$(field round); marker_head=$(field head); level=$(field level)
high=$(field high); marker_changes=$(field changes)

if [ "$marker_head" != "$head" ]; then
  git fetch -q origin main
  git fetch -q origin "pull/$pr/head"
  tip=$(git rev-parse FETCH_HEAD)
  [ "$tip" = "$head" ] || { echo "PR #$pr moved while this ran; the next event posts its status."; exit 0; }
  base=$(git merge-base origin/main "$tip")
  changes=$(git diff "$base" "$tip" -- . ':!*.md' | git patch-id --stable | cut -d' ' -f1)
  [ -n "$changes" ] || changes=none
  if [ "$changes" != "$marker_changes" ]; then
    echo "PR #$pr changed since review round $round; run scripts/review-branch.sh on it."
    exit 0
  fi
fi

if [ "$level" = skip ]; then desc=skip; else desc="$level, round $round, $high HIGH"; fi
state=success
[ "$high" -gt 0 ] && state=failure
$GH api "repos/$repo/statuses/$head" -f context=review -f "state=$state" \
  -f "description=$desc" > /dev/null
echo "Review status: $state ($desc) on ${head:0:12}."
