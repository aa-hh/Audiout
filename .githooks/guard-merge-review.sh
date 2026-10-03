#!/bin/sh
# GUARD 10 (BLOCKING): a merge onto main needs a code review receipt for the
# branch being merged. This hook never calls a model: scripts/review-branch.sh
# runs the review in the branch's worktree and writes the receipt checked here.
#
# The merged commit: the first line of MERGE_HEAD when git has written it (a
# conflict-resolution merge commit, which runs pre-commit), else the last word
# of GIT_REFLOG_ACTION ("merge <branch>"), because pre-merge-commit runs before
# git writes MERGE_HEAD. The branch must contain the latest main, so HEAD
# (main) is the base; the receipt key is the same line as in
# scripts/review-branch.sh.
#
# Override once, loudly: AUDIOUT_SKIP_BRANCH_REVIEW=1 git merge --no-ff <branch>

branch=$(git symbolic-ref --short HEAD 2>/dev/null)
[ "$branch" = "main" ] || exit 0

if [ "${AUDIOUT_SKIP_BRANCH_REVIEW:-}" = "1" ]; then
    echo "  WARNING (Guard 10): branch review check skipped by AUDIOUT_SKIP_BRANCH_REVIEW=1. This merge lands without a code review." >&2
    exit 0
fi

git_dir=$(git rev-parse --git-dir 2>/dev/null)
word=""
if [ -f "$git_dir/MERGE_HEAD" ]; then
    word=$(head -n 1 "$git_dir/MERGE_HEAD")
else
    case "${GIT_REFLOG_ACTION:-}" in
        "merge "*) word=${GIT_REFLOG_ACTION##* } ;;
    esac
fi
tip=""
[ -n "$word" ] && tip=$(git rev-parse --verify -q "$word^{commit}" 2>/dev/null)
if [ -z "$tip" ]; then
    echo "  REFUSED (Guard 10): cannot tell which branch is being merged. Merge with a plain 'git merge --no-ff <branch>', or set AUDIOUT_SKIP_BRANCH_REVIEW=1 to land it unreviewed." >&2
    exit 1
fi

if ! git merge-base --is-ancestor HEAD "$tip"; then
    cat >&2 <<'EOF'
  REFUSED (Guard 10): this branch does not contain the latest main.

  No tests ran. First run git merge --abort here, then in the branch's
  worktree run git merge main. That merge runs the full suite when main's side
  changes AudioutCore Swift, and this merge then skips it; otherwise the full
  suite runs here. Either way it runs once. The code review stays valid if the
  merge did not change the branch's own lines.

  Emergency only:   AUDIOUT_SKIP_BRANCH_REVIEW=1 git merge --no-ff <branch>
EOF
    exit 1
fi

base=$(git rev-parse HEAD)
# Same changes keep the same key after main is merged into the branch; a conflict resolution that changes the branch's own lines changes it.
hash=$(git diff -U0 --no-renames "$base" "$tip" | git patch-id --stable | cut -d' ' -f1)
[ -n "$hash" ] || hash=empty
receipt="$(git rev-parse --git-common-dir)/audiout-branch-reviews/$hash"

if [ -f "$receipt" ]; then
    level=$(sed -n 's/.* level=\([^ ]*\).*/\1/p' "$receipt")
    echo "  Guard 10: branch review receipt found ($level)." >&2
    exit 0
fi

cat >&2 <<'EOF'
  REFUSED (Guard 10): no code review receipt for the commits being merged.

  In the branch's worktree run:   bash scripts/review-branch.sh
  It picks the review depth from the diff and prints reviewer passes for the
  Claude session merging the branch to run as its own subagents (headless
  claude -p is refused on this account). Follow its printed steps, then run
  bash scripts/review-branch.sh --continue, which prints the findings and
  records the receipt this merge needs. Work already reviewed by /scope-and-run's
  reviewer:   bash scripts/review-branch.sh --already-reviewed
  Then run this merge again. A receipt covers the branch's own changes when
  it was written; a later commit that changes them needs a new one (merging
  main in does not).

  Order that runs the full suite once:
    1. review, fix and commit (re-review if lines changed)
    2. merge main into the branch (runs the full suite when main's side
       changes AudioutCore Swift)
    3. merge the branch into main (skips the suite if step 2 ran it,
       otherwise runs it)

  Emergency only:   AUDIOUT_SKIP_BRANCH_REVIEW=1 git merge --no-ff <branch>
EOF
exit 1
