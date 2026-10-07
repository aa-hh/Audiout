#!/bin/sh
# Merges the current branch's pull request — the replacement for a merge
# queue on a repo with no CI and no required checks. Run it ONLY after the
# owner has said yes; the Claude merge-approval hook asks either way.
#
# It refuses unless, on the PR's head commit:
#   - the full suite passed locally (recorded by .githooks/pre-push), and
#   - the `review` commit status is success (posted by scripts/review-branch.sh).
#
# Usage: sh scripts/land.sh [--squash|--rebase]   (default: --merge)
set -eu

method=--merge
case "${1:-}" in "") ;; --merge|--squash|--rebase) method=$1 ;; *) echo "usage: sh scripts/land.sh [--merge|--squash|--rebase]" >&2; exit 2 ;; esac

common=$(cd "$(git rev-parse --git-common-dir)" && pwd)
pr=$(gh pr view --json number -q .number) || { echo "No pull request for this branch." >&2; exit 2; }
head=$(gh pr view --json headRefOid -q .headRefOid)
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)

[ "$(git rev-parse HEAD)" = "$head" ] \
  || { echo "Local HEAD differs from PR head ${head%"${head#????????????}"}; push or pull first." >&2; exit 1; }
grep -qx "$head" "$common/tests-passed" 2>/dev/null \
  || { echo "No recorded full-suite pass for $head. Push again (pre-push runs it) or run: sh scripts/test.sh --full && git rev-parse HEAD >> \"$common/tests-passed\"" >&2; exit 1; }
state=$(gh api "repos/$repo/commits/$head/status" --jq '[.statuses[] | select(.context=="review")][0].state // "missing"')
[ "$state" = success ] \
  || { echo "The review status on $head is '$state'. Run: bash scripts/review-branch.sh" >&2; exit 1; }
mergeable=$(gh pr view --json mergeable -q .mergeable)
[ "$mergeable" != CONFLICTING ] \
  || { echo "PR #$pr conflicts with main: merge origin/main in, push, review again." >&2; exit 1; }

gh pr merge "$pr" "$method" --delete-branch=false
echo "PR #$pr landed."
