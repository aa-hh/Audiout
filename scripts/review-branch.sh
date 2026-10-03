#!/bin/bash
# Code review for one branch before it merges to main (Guard 10 checks the
# receipt this writes; the hook itself never calls a model).
#
# Picks a level from the committed diff against main: skip (no model), cheap
# (one sonnet pass) or full (four parallel reviewers, then one haiku
# confidence score per finding, findings under 80 dropped). Prints the
# findings, appends one line to <git-common-dir>/audiout-branch-reviews.log,
# and writes a receipt keyed to the branch's own committed changes, so a later
# commit that changes them needs a new review (merging main in does not).
# Instruction files: docs/review/<pass>.md.
#
# The reviewers run as subagents of the Claude session merging the branch,
# because headless Claude CLI runs are refused on this account. The script hands
# work over through .review-pending/<key>/ in this worktree (git-ignored; a
# session's subagents may write there but not into the shared .git folder):
# a run writes one <pass>.prompt per pass and prints, per pass, its model,
# the prompt path and the .out path the session saves the reply to; the
# session runs those subagents, then runs --continue, which reads the replies
# and either prints the next set of passes (escalation, scoring) or records
# the result and deletes the pending directory.
#
# Usage: bash scripts/review-branch.sh [--continue | --already-reviewed]
#   (no flag)           start the review; re-running starts it over.
#   --continue          read the saved replies and go on to the next step.
#   --already-reviewed  record work a /scope-and-run reviewer already approved;
#                       writes the receipt without any model.
# Exit: 0 reviewed + receipt; 1 findings to fix (any severity), no receipt,
#       fix groups printed;
#       2 the review did not run, no receipt; 3 reviewer subagents needed
#       (run the printed passes, then --continue).

set -uo pipefail

# ---------------------------------------------------------------------------
# The one place to edit: thresholds, risk paths, the model each pass runs on.
SKIP_UNDER_LINES=50
FULL_OVER_LINES=300
SCORE_KEEP_AT=80

CHEAP_MODEL=sonnet
DEEP_MODEL=opus
RULES_MODEL=sonnet
HISTORY_MODEL=sonnet
COMMENTS_MODEL=sonnet
SCORE_MODEL=haiku

# Any touched path here makes the review full, whatever its size.
is_risk_path() {
  case "$1" in
    AirPlayEngine/Sources/*) return 0 ;;
    AudioutCore/Sources/AudioutCore/BT*.swift \
    | AudioutCore/Sources/AudioutCore/Sync*.swift \
    | AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift \
    | AudioutCore/Sources/AudioutCore/DriftCorrection*.swift \
    | AudioutCore/Sources/AudioutCore/PassiveDriftSampler.swift \
    | AudioutCore/Sources/AudioutCore/AlignmentTickInjector.swift \
    | AudioutCore/Sources/AudioutCore/PTPHelperService.swift \
    | AudioutCore/Sources/AudioutCore/NativeBackend*.swift \
    | AudioutCore/Sources/AudioutCore/NativeCaptureCoordinator.swift \
    | AudioutCore/Sources/AudioutCore/PerAppCaptureCoordinator.swift \
    | AudioutCore/Sources/AudioutCore/AppRouteMixer.swift \
    | AudioutCore/Sources/AudioutCore/AggregateOutputDevice.swift \
    | AudioutCore/Sources/AudioutCore/TapRebuildLifecycle.swift \
    | AudioutCore/Sources/AudioutCore/License*.swift \
    | AudioutCore/Sources/AudioutCore/Trial*.swift \
    | AudioutCore/Sources/AudioutCore/CompanionLicenseActivation.swift \
    | AudioutCore/Sources/AudioutCore/*Store.swift \
    | AudioutCore/Sources/AudioutCore/StoreRecovery.swift \
    | AudioutCore/Sources/AudioutCore/AppSettings.swift) return 0 ;;
  esac
  return 1
}

# Lines in these paths count toward the size thresholds; tests and docs do not.
is_product_path() {
  case "$1" in *Tests/*|*.md) return 1 ;; esac
  case "${1##*/}" in *Test*) return 1 ;; esac
  case "$1" in .githooks/*|*.swift|*.c|*.h|*.m|*.sh|*.py) return 0 ;; esac
  return 1
}

OUTPUT_FORMAT=$(cat <<'EOF'
Output format (a script parses this; follow it exactly):
- One line per finding: SEVERITY | path:line | one sentence naming the defect and the smallest fix.
- SEVERITY is exactly HIGH, MEDIUM, or LOW.
  HIGH = a defect with a concrete failing scenario, a data-loss or lockout path, or a breach of a quoted AGENTS.md rule.
  MEDIUM = a likely defect without a confirmed scenario, or changed behaviour with no test.
  LOW = readability or naming.
- If there are no findings, output the single line: NO FINDINGS
- Lines starting with anything else are shown to a human and never counted; add them only when your instructions above ask for them.
EOF
)
# ---------------------------------------------------------------------------


mode=""
case "${1:-}" in
  "") ;;
  --already-reviewed|--continue) mode="$1" ;;
  *) echo "usage: bash scripts/review-branch.sh [--continue | --already-reviewed]" >&2; exit 2 ;;
esac

branch=$(git symbolic-ref --short HEAD 2>/dev/null) || branch=detached
if [ "$branch" = "main" ]; then
  echo "Refusing to review main: run this in the branch's worktree." >&2
  exit 2
fi
top=$(git rev-parse --show-toplevel) || exit 2
cd "$top" || exit 2
common=$(cd "$(git rev-parse --git-common-dir)" && pwd) || exit 2

tip=$(git rev-parse --verify HEAD) || exit 2
base=$(git merge-base main "$tip") || { echo "No merge base with main." >&2; exit 2; }
# Same changes keep the same key after main is merged into the branch; a conflict resolution that changes the branch's own lines changes it.
hash=$(git diff -U0 --no-renames "$base" "$tip" | git patch-id --stable | cut -d' ' -f1)
[ -n "$hash" ] || hash=empty
git merge-base --is-ancestor main "$tip" \
  || echo "Note: this branch does not contain the latest main. The review still counts; merge main in before landing."

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Warning: uncommitted changes are not part of this review; the receipt covers committed work only." >&2
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

if [ "$mode" = --already-reviewed ]; then level=external
elif [ ${#risk[@]} -gt 0 ]; then level=full
elif [ "$lines" -lt "$SKIP_UNDER_LINES" ]; then level=skip
elif [ "$lines" -gt "$FULL_OVER_LINES" ]; then level=full
else level=cheap
fi

reviews_dir="$common/audiout-branch-reviews"
review_log="$common/audiout-branch-reviews.log"
pending_root="$PWD/.review-pending"
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
echo "Review level: $level ($summary)"

# log_line <high> <medium> <low> <dropped>
log_line() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$branch" "$level" "$1" "$2" "$3" "$4" "$files" >> "$review_log"
}
write_receipt() {
  mkdir -p "$reviews_dir" || exit 2
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ) branch=$branch level=$level tip=$tip" \
    > "$reviews_dir/$hash" || exit 2
  echo "Receipt written: ${hash:0:12}"
}

if [ "$level" = skip ] || [ "$level" = external ]; then
  log_line 0 0 0 0
  write_receipt
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
log_line "$high" "$medium" "$low" "$dropped"
rm -rf "$state"
if [ ${#survivors[@]} -eq 0 ]; then
  write_receipt
  exit 0
fi

# Every surviving finding is fixed before the branch merges: group them by the
# file in their path:line field, one builder subagent per group.
# razor: one group per file; upgrade path is merging groups whose files the
# findings name together.
file_of() {
  local f
  f=$(printf '%s\n' "$1" | sed -n 's/^[A-Z]* | \([^|:]*[^|: ]\):[0-9][^|]* | .*/\1/p')
  [ -n "$f" ] && echo "$f" || echo "$1"
}
keys=(); groups=()
for l in "${survivors[@]}"; do
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
  for l in "${survivors[@]}"; do
    [ "${keys[$i]}" = "$g" ] && echo "    $l"
    i=$((i + 1))
  done
done
echo
echo "Fix every finding above. Launch one builder subagent (work-order-executor, model opus) per fix group, all in parallel in this worktree; give each its group's finding lines verbatim plus: edit only the named file and its own test file, read the nearest AGENTS.md first, do not commit. Two groups never share a file. When all return, run the tests covering the changed files, commit, then start a fresh review: bash scripts/review-branch.sh"
exit 1
