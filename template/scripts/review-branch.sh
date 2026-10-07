#!/bin/bash
# Code review for one branch's pull request. The result goes to the PR as one
# comment and as the `review` commit status on HEAD, which scripts/land.sh
# requires before it merges.
#
# Picks a level from the committed diff against origin/main (fetched first;
# local main is never used, since nothing updates it any more): skip (no model), cheap
# (one sonnet pass) or full (four parallel reviewers, the deep one on fable, then one haiku
# confidence score per finding, findings under 75 dropped). Prints the
# findings and appends one line to <git-common-dir>/branch-reviews.log.
# Instruction files: docs/review/<pass>.md.
#
# At most two rounds per PR. The round state lives on the PR, not in local
# files, so a fresh checkout works the same: every comment this script posts
# starts with a marker line
#   <!-- agent-review round=<n> head=<sha> level=<level> high=<k> changes=<id> -->
# and the next run reads the PR's comments, highest round wins. <id> is the
# patch id of the branch's own non-Markdown changes against origin/main
# (`none` when there are none). A push that leaves it unchanged, such as
# merging main in or a docs-only commit, uses no round: the run re-posts that
# round's status on the new HEAD and exits with its result. Round 2
# reviews only what was committed since round 1's head (the fix for its HIGH
# findings) and never skips; a third run refuses. No PR yet means round 1
# against main. Only a HIGH finding fails the status; MEDIUM and LOW are
# posted and do not block.
#
# The reviewers run as subagents of the Claude session that owns the branch,
# because headless Claude CLI runs are refused on this account. The script hands
# work over through .review-pending/<key>/ in this worktree (git-ignored; a
# session's subagents may write there but not into the shared .git folder):
# a run writes one <pass>.prompt per pass and prints, per pass, its model,
# the prompt path and the .out path the session saves the reply to; the
# session runs those subagents, then runs --continue, which reads the replies
# and either prints the next set of passes (escalation, scoring) or records
# the result and deletes the pending directory.
#
# Usage: bash scripts/review-branch.sh [--continue]
#   (no flag)    start the next round; re-running before it finishes starts it over.
#   --continue   read the saved replies and go on to the next step.
# Exit: 0 reviewed, no HIGH finding; 1 a HIGH finding survived scoring (fix
#       groups printed in round 1), or two rounds are done;
#       2 the review did not run or its result could not be posted;
#       3 reviewer subagents needed (run the printed passes, then --continue).
# GH overrides the gh command (the self-test points it at a stub).

set -uo pipefail

# ---------------------------------------------------------------------------
# The one place to edit: thresholds, risk paths, the model each pass runs on.
SKIP_UNDER_LINES=50
FULL_OVER_LINES=300
SCORE_KEEP_AT=75

CHEAP_MODEL=sonnet
DEEP_MODEL=fable
RULES_MODEL=sonnet
HISTORY_MODEL=sonnet
COMMENTS_MODEL=sonnet
SCORE_MODEL=haiku

# Any touched path here makes the review full, whatever its size.
is_risk_path() {
  case "$1" in
    # Fill in per project: the code where a small diff can do large harm
    # (persistence formats, auth/licensing, concurrency, hooks). Example:
    # src/storage/*|src/auth/*|.githooks/*) return 0 ;;
    __none__) return 0 ;;
  esac
  return 1
}

# Lines in these paths count toward the size thresholds; tests and docs do not.
is_product_path() {
  case "$1" in *Tests/*|*.md) return 1 ;; esac
  case "${1##*/}" in *Test*) return 1 ;; esac
  case "$1" in .githooks/*|*.swift|*.c|*.h|*.m|*.sh|*.py|*.ts|*.tsx|*.js|*.go|*.rs|*.rb|*.java|*.kt) return 0 ;; esac
  return 1
}

OUTPUT_FORMAT=$(cat <<'EOF'
Output format (a script parses this; follow it exactly):
- One line per finding: SEVERITY | path:line | one sentence naming the defect and the smallest fix.
- SEVERITY is exactly HIGH, MEDIUM, or LOW.
  HIGH = a defect with a concrete failing scenario, a data-loss or lockout path, or a breach of a quoted AGENTS.md rule.
  MEDIUM = a likely defect without a confirmed scenario, or changed behaviour with no test where root AGENTS.md's Tests section says one is needed.
  LOW = readability or naming.
- If there are no findings, output the single line: NO FINDINGS
- Lines starting with anything else are shown to a human and never counted; add them only when your instructions above ask for them.
EOF
)
# ---------------------------------------------------------------------------


mode=""
case "${1:-}" in
  "") ;;
  --continue) mode="$1" ;;
  *) echo "usage: bash scripts/review-branch.sh [--continue]" >&2; exit 2 ;;
esac

branch=$(git symbolic-ref --short HEAD 2>/dev/null) || branch=detached
if [ "$branch" = "main" ]; then
  echo "Refusing to review main: run this in the branch's worktree." >&2
  exit 2
fi
top=$(git rev-parse --show-toplevel) || exit 2
cd "$top" || exit 2
common=$(cd "$(git rev-parse --git-common-dir)" && pwd) || exit 2

GH=${GH:-gh}
REPO=${REPO:-$($GH repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}
[ -n "$REPO" ] || { echo "Could not determine the GitHub repo (gh repo view failed); set REPO=owner/name." >&2; exit 2; }
git fetch -q origin || echo "Warning: git fetch origin failed; origin/main may be out of date." >&2
tip=$(git rev-parse --verify HEAD) || exit 2
main_base=$(git merge-base origin/main "$tip") || { echo "No merge base with origin/main." >&2; exit 2; }
changes=$(git diff "$main_base" "$tip" -- . ':!*.md' | git patch-id --stable | cut -d' ' -f1)
[ -n "$changes" ] || changes=none
pending_root="$PWD/.review-pending"
review_log="$common/branch-reviews.log"

# post_status <state> <description>: the `review` commit status on HEAD.
post_status() {
  $GH api "repos/$REPO/statuses/$tip" -f context=review -f "state=$1" \
      -f "description=$2" > /dev/null \
    || { echo "Review result not posted: the review status on $tip failed. Push the branch (git push -u origin HEAD) and run the same command again." >&2; exit 2; }
  echo "Review status: $1 ($2) on ${tip:0:12}."
}

# The last round posted on this branch's PR: prev_round, prev_head,
# prev_level, prev_high, prev_changes (prev_round 0 when none or no PR).
pr=$($GH pr view --json number -q .number 2>/dev/null)
prev_round=0; prev_head=""; prev_level=""; prev_high=0; prev_changes=""
if [ -n "$pr" ]; then
  bodies=$($GH api --paginate "repos/$REPO/issues/$pr/comments" --jq '.[].body') \
    || { echo "Could not read the comments on PR #$pr, so the review round is unknown." >&2; exit 2; }
  last=$(printf '%s\n' "$bodies" | grep '^<!-- agent-review round=[0-9]' \
    | sed 's/^<!-- agent-review round=\([0-9]*\)/\1	&/' | sort -n | tail -n 1 | cut -f2-)
  marker_field() { printf '%s\n' "$last" | sed -n "s/.* $1=\([^ ]*\).*/\1/p"; }
  if [ -n "$last" ]; then
    prev_round=$(marker_field round); prev_head=$(marker_field head)
    prev_level=$(marker_field level); prev_high=$(marker_field high)
    prev_changes=$(marker_field changes)
  fi
fi
round=$((prev_round + 1))
# Same head, or the same own changes as the last round (main merged in, a
# docs-only commit, a failed status post): post that round's status on this
# HEAD again rather than review again.
if [ -n "$prev_head" ] && { [ "$prev_head" = "$tip" ] || [ "$prev_changes" = "$changes" ]; }; then
  echo "This branch's changes were already reviewed in round $prev_round (PR #$pr)."
  if [ "$prev_level" = skip ]; then d=skip; else d="$prev_level, round $prev_round, $prev_high HIGH"; fi
  if [ "$prev_high" -gt 0 ]; then post_status failure "$d"; exit 1; fi
  post_status success "$d"
  exit 0
fi
if [ "$round" -gt 2 ] && [ "$mode" != --continue ]; then
  echo "two rounds done; remaining findings are on the PR"
  exit 1
fi
if [ "$round" = 2 ]; then
  base=$prev_head
  git rev-parse --verify -q "$base^{commit}" > /dev/null \
    || { echo "Round 1's head $base (from PR #$pr) is not in this clone; git fetch, then run again." >&2; exit 2; }
else
  base=$main_base
fi
# Keys the pending review to the reviewed changes, so a commit between the
# handover and --continue is caught.
hash=$(git diff -U0 --no-renames "$base" "$tip" | git patch-id --stable | cut -d' ' -f1)
[ -n "$hash" ] || hash=empty

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Warning: uncommitted changes are not part of this review; it covers committed work only." >&2
fi

# --no-renames so a renamed file shows its real new path to the risk check.
lines=0; files=0; risk=(); changed=()
while IFS=$'\t' read -r added deleted path; do
  [ "$added" = "-" ] && added=0
  [ "$deleted" = "-" ] && deleted=0
  files=$((files + 1)); changed+=("$path")
  is_product_path "$path" && lines=$((lines + added + deleted))
  is_risk_path "$path" && risk+=("$path")
done < <(git diff --numstat --no-renames "$base" "$tip")

if [ ${#risk[@]} -gt 0 ]; then level=full
elif [ "$lines" -lt "$SKIP_UNDER_LINES" ] && [ "$round" = 1 ]; then level=skip
elif [ "$lines" -lt "$SKIP_UNDER_LINES" ]; then level=cheap
elif [ "$lines" -gt "$FULL_OVER_LINES" ]; then level=full
else level=cheap
fi

state="$pending_root/$hash"

if [ "$mode" = --continue ]; then
  if [ ! -f "$state/level" ]; then
    for b in "$pending_root"/*/branch; do
      if [ -f "$b" ] && [ "$(cat "$b")" = "$branch" ]; then
        echo "The branch's committed changes differ from when this review started. Run again with no flag: bash scripts/review-branch.sh" >&2
        exit 2
      fi
    done
    echo "No review in progress for this branch. Start one: bash scripts/review-branch.sh" >&2
    exit 2
  fi
  level=$(cat "$state/level")
fi

summary="$lines product lines"
if [ ${#risk[@]} -gt 0 ]; then
  joined=$(printf ', %s' "${risk[@]}")
  summary="$summary, risk: ${joined:2}"
fi
echo "Review level: $level ($summary), round $round"

# log_line <high> <medium> <low> <dropped>
log_line() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$branch" "$level" "$1" "$2" "$3" "$4" "$files" >> "$review_log"
}

# post_result <high> <comment file>: the PR comment, marker line first (or the
# body printed when there is no PR), then the `review` status on HEAD. A
# failed status post exits 2; running again re-posts it from the marker.
post_result() {
  local st=success desc
  [ "$1" -gt 0 ] && st=failure
  if [ "$level" = skip ]; then desc=skip; else desc="$level, round $round, $1 HIGH"; fi
  { echo "<!-- agent-review round=$round head=$tip level=$level high=$1 changes=$changes -->"; cat "$2"; } > "$2.post" || exit 2
  if [ -n "$pr" ]; then
    $GH pr comment "$pr" --body-file "$2.post" > /dev/null \
      || { echo "Review result not posted: gh pr comment failed for PR #$pr." >&2; exit 2; }
    echo "Review comment posted to PR #$pr."
  else
    echo "No pull request for $branch, so no comment was posted (and no round recorded). Its body:"
    cat "$2.post"
  fi
  post_status "$st" "$desc"
}

if [ "$level" = skip ]; then
  skip_body=$(mktemp "${TMPDIR:-/tmp}/review-skip.XXXXXX") || exit 2
  printf '## Review: skip, round %s\n\nReview: no findings (%s, below the review threshold)\n' "$round" "$summary" > "$skip_body"
  post_result 0 "$skip_body"
  rm -f "$skip_body" "$skip_body.post"
  log_line 0 0 0 0
  exit 0
fi

pass_model() {
  case "$1" in
    cheap)    echo "$CHEAP_MODEL" ;;
    deep)     echo "$DEEP_MODEL" ;;
    rules)    echo "$RULES_MODEL" ;;
    history)  echo "$HISTORY_MODEL" ;;
    comments) echo "$COMMENTS_MODEL" ;;
    score*)   echo "$SCORE_MODEL" ;;
  esac
}

# write_prompt <pass> <instruction file> [finding]: the pass's prompt file.
# The score pass gets the finding instead of the output format.
write_prompt() {
  local name="$1" doc="docs/review/$2.md" finding="${3:-}"
  [ -f "$doc" ] || { echo "Review did not run: missing $doc"; exit 2; }
  {
    printf '# Review pass: %s\n\n' "$2"
    cat "$doc"
    if [ "$2" = score ]; then printf '\n## Finding\n\n%s\n\n' "$finding"
    else printf '\n%s\n\n' "$OUTPUT_FORMAT"
    fi
    cat "$state/tail"
  } > "$state/$name.prompt" || exit 2
}

# hand_over <instruction> <pass>...: record the passes, print one line each and
# the instruction, exit 3 for the session to run them.
hand_over() {
  local instruction="$1"; shift
  echo "$*" > "$state/passes" || exit 2
  echo
  for p in "$@"; do
    echo "$p  model=$(pass_model "$p")  prompt=$state/$p.prompt  save reply to=$state/$p.out"
  done
  echo
  echo "$instruction"
  exit 3
}

REVIEW_STEPS="Run every pass above as a subagent of this Claude session, in parallel, read-only, with the model shown. Give it the prompt file's full contents as its task. Save its reply verbatim to the .out path. The history pass may only run git log and git blame. Then run: bash scripts/review-branch.sh --continue"
SCORE_STEPS="Run each as a haiku subagent in parallel, save reply verbatim, then run: bash scripts/review-branch.sh --continue"
REVIEWERS=(deep rules history comments)

# plan_reviewers <level> <pass>...: prompts for the reviewer passes, then hand over.
plan_reviewers() {
  echo "$1" > "$state/level" || exit 2
  shift
  for p in "$@"; do rm -f "$state/$p.out"; write_prompt "$p" "$p"; done
  hand_over "$REVIEW_STEPS" "$@"
}

if [ "$mode" != --continue ]; then
  # Start over: drop this branch's earlier pending reviews, whatever their key.
  for b in "$pending_root"/*/branch; do
    [ -f "$b" ] && [ "$(cat "$b")" = "$branch" ] && rm -rf "$(dirname "$b")"
  done
  rm -rf "$state"
  mkdir -p "$state" || exit 2
  echo "$branch" > "$state/branch" || exit 2

  # Shared prompt tail: root AGENTS.md plus the nearest AGENTS.md above each
  # changed file (read at the tip), then the diff.
  agents=("AGENTS.md")
  for path in ${changed[@]+"${changed[@]}"}; do
    dir=$(dirname "$path")
    while [ "$dir" != "." ]; do
      if git cat-file -e "$tip:$dir/AGENTS.md" 2>/dev/null; then
        case " ${agents[*]} " in *" $dir/AGENTS.md "*) ;; *) agents+=("$dir/AGENTS.md") ;; esac
        break
      fi
      dir=$(dirname "$dir")
    done
  done
  {
    echo "## Repo rules"
    for a in "${agents[@]}"; do
      printf '\n### %s\n\n' "$a"
      git show "$tip:$a" 2>/dev/null
    done
    printf '\n## Diff\n\nbase: %s tip: %s\n\n' "$base" "$tip"
    git diff "$base" "$tip"
  } > "$state/tail" || exit 2

  if [ "$level" = cheap ]; then plan_reviewers cheap cheap
  else plan_reviewers full "${REVIEWERS[@]}"
  fi
fi

# --continue: every pass handed over must have a reply, and a reviewer's reply
# must be in the expected format.
passes=()
read -r -a passes < "$state/passes" 2>/dev/null
if [ "${#passes[@]}" -eq 0 ]; then
  echo "Review did not run: no reviewer passes were handed over. Run again with no flag."
  exit 2
fi
for p in ${passes[@]+"${passes[@]}"}; do
  out="$state/$p.out"
  if [ ! -f "$out" ]; then
    echo "Review did not run: no reply saved for the $p pass ($out)."
    exit 2
  fi
  case "$p" in score*) continue ;; esac
  grep -Eq '^(HIGH|MEDIUM|LOW) \|' "$out" && continue
  grep -qx 'NO FINDINGS' "$out" && continue
  [ "$p" = cheap ] && grep -q '^ESCALATE:' "$out" && continue
  cat "$out"
  echo "Review did not run ($p reply is not in the expected format)."
  exit 2
done

high=0; medium=0; low=0; dropped=0; survivors=()
count() {
  survivors+=("$1")
  case "$1" in
    HIGH*) high=$((high + 1)) ;;
    MEDIUM*) medium=$((medium + 1)) ;;
    LOW*) low=$((low + 1)) ;;
  esac
}

if [ "$level" = cheap ]; then
  if grep -q '^ESCALATE:' "$state/cheap.out"; then
    grep '^ESCALATE:' "$state/cheap.out"
    plan_reviewers full-escalated "${REVIEWERS[@]}"
  fi
  while IFS= read -r line; do
    echo "  [cheap] $line"; count "$line"
  done < <(grep -E '^(HIGH|MEDIUM|LOW) \|' "$state/cheap.out")
else
  # razor: no cross-reviewer dedupe; two passes reporting the same defect show
  # twice. Upgrade path: merge findings on their path:line key before scoring.
  if [ ! -f "$state/findings" ]; then
    : > "$state/findings" || exit 2
    for p in "${REVIEWERS[@]}"; do
      grep -E '^(HIGH|MEDIUM|LOW) \|' "$state/$p.out" | sed "s/^/$p	/" >> "$state/findings"
    done
    if [ -s "$state/findings" ]; then
      scores=(); n=0
      while IFS=$'\t' read -r tag line; do
        n=$((n + 1)); write_prompt "score-$n" score "$line"; scores+=("score-$n")
      done < "$state/findings"
      hand_over "$SCORE_STEPS" "${scores[@]}"
    fi
  fi

  kept=(); gone=(); n=0
  while IFS=$'\t' read -r tag line; do
    n=$((n + 1))
    s=$(grep -Eo '^SCORE: [0-9]+' "$state/score-$n.out" 2>/dev/null | head -1 | grep -Eo '[0-9]+')
    if [ -z "$s" ]; then
      kept+=("  [$tag] (unscored) $line"); count "$line"
    elif [ "$s" -lt "$SCORE_KEEP_AT" ]; then
      gone+=("  [$tag] ($s) $line"); dropped=$((dropped + 1))
    else
      kept+=("  [$tag] ($s) $line"); count "$line"
    fi
  done < "$state/findings"
  for l in ${kept[@]+"${kept[@]}"}; do echo "$l"; done
  if [ ${#gone[@]} -gt 0 ]; then
    echo "Dropped by scorer:"
    for l in "${gone[@]}"; do echo "$l"; done
  fi
  grep -E '^(COMPAT|LIVE TEST|DECLINED) \|' "$state/deep.out"
fi

echo "Findings: $high high, $medium medium, $low low ($dropped dropped)"

comment="$state/comment.md"
{
  echo "## Review: $level, round $round"
  echo
  if [ ${#survivors[@]} -eq 0 ]; then
    echo "Review: no findings"
  fi
  for sev in HIGH MEDIUM LOW; do
    group=$(for l in ${survivors[@]+"${survivors[@]}"}; do printf '%s\n' "$l"; done \
      | sed -n "s/^$sev | \([^|]*[^| ]\) | \(.*\)/- \1: \2/p")
    if [ -n "$group" ]; then printf '### %s\n\n%s\n\n' "$sev" "$group"; fi
  done
} > "$comment" || exit 2
post_result "$high" "$comment"
log_line "$high" "$medium" "$low" "$dropped"
rm -rf "$state"
[ "$high" -eq 0 ] && exit 0
if [ "$round" = 2 ]; then
  echo "two rounds done; remaining findings are on the PR"
  exit 1
fi

# Only HIGH findings block. Group them by the file in their path:line field,
# one builder subagent per group.
# razor: one group per file; upgrade path is merging groups whose files the
# findings name together.
file_of() {
  local f
  f=$(printf '%s\n' "$1" | sed -n 's/^[A-Z]* | \([^|:]*[^|: ]\):[0-9][^|]* | .*/\1/p')
  [ -n "$f" ] && echo "$f" || echo "$1"
}
highs=(); keys=(); groups=()
for l in "${survivors[@]}"; do
  case "$l" in HIGH*) ;; *) continue ;; esac
  highs+=("$l")
  k=$(file_of "$l"); keys+=("$k")
  seen=0
  for g in ${groups[@]+"${groups[@]}"}; do [ "$g" = "$k" ] && seen=1; done
  [ "$seen" = 1 ] || groups+=("$k")
done
echo
n=0
for g in "${groups[@]}"; do
  n=$((n + 1))
  echo "fix-$n  file=$g"
  i=0
  for l in "${highs[@]}"; do
    [ "${keys[$i]}" = "$g" ] && echo "    $l"
    i=$((i + 1))
  done
done
echo
echo "Fix every HIGH finding above. Launch one builder subagent (model opus) per fix group, all in parallel in this worktree; give each its group's finding lines verbatim plus: edit only the named file and its own test file, read the nearest AGENTS.md first, a test you add or move carries one comment sentence naming the code change that turns it red; for any finding about stale wording, grep the source tree and every *.md for the retired term and fix each hit inside your file, listing hits outside it in your report; do not commit. Two groups never share a file. When all return, run the tests covering the changed files, commit, push, then run round 2, which reviews only the fix: bash scripts/review-branch.sh"
exit 1
