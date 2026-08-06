#!/bin/sh
# GUARD 7 helper: staged-Swift readability screen + self-review receipt.
# Called by pre-commit; runnable standalone while iterating on it:
#   sh .githooks/guard-self-review.sh    (exit 0 = would pass)
#
# Two parts, cheap first:
#   A. A deterministic screen over the ADDED comment lines of the staged
#      Swift diff (same -U0 technique as Guards 3/5). It hard-blocks only
#      near-certain slop — the three patterns the 2026-08-06 audit
#      (dev/notes/verbosity-audit-2026-08-06.md) found with ~zero false
#      positives — and prints softer past-tense patterns as a warning for
#      the self-review to weigh. A rare legitimate hit takes a trailing
#      `slop-ok` comment (sibling of Guard 3's `isolation-ok`).
#   B. A review receipt: scripts/self-review.sh hashes the staged Swift
#      diff after showing the rubric checklist; this guard refuses the
#      commit until that receipt matches the exact staged bytes. The
#      review itself happens in the committer's own context — deliberately
#      no LLM call here (razor: latency/cost in a pre-commit hook trains
#      everyone to --no-verify past it; the upgrade path is an async
#      second-model review at PR time, not a synchronous hook call).

git_dir=$(git rev-parse --git-dir 2>/dev/null) || exit 0

staged_swift=$(git diff --cached --name-only -- '*.swift' 2>/dev/null)
[ -z "$staged_swift" ] && exit 0

added_comments=$(git diff --cached -U0 -- '*.swift' 2>/dev/null \
    | grep -E '^\+[^+]' | grep -E '//' | grep -v 'slop-ok')

# --- Part A: near-certain slop (BLOCKING) --------------------------------
block_hits=$(printf '%s\n' "$added_comments" | grep -E \
    -e 'this session' \
    -e '\((architecture review|fixed|added|updated|revised|corrected) 20[0-9][0-9]' \
    -e '// ?={5,}' )
if [ -n "$block_hits" ]; then
    echo "" >&2
    echo "  REFUSED (Guard 7): staged comment lines match near-certain slop" >&2
    echo "  patterns (session-relative time, dated changelog citations, banner" >&2
    echo "  rules). Git owns history — see docs/REVIEW-RUBRIC.md." >&2
    printf '%s\n' "$block_hits" | sed 's/^+/    /' >&2
    echo "" >&2
    echo "  A rare legitimate line takes a trailing 'slop-ok' comment." >&2
    echo "  ('git commit --no-verify' for a real emergency, as ever.)" >&2
    echo "" >&2
    exit 1
fi

# --- Part A': softer patterns (WARN-ONLY; the self-review weighs them) ---
warn_hits=$(printf '%s\n' "$added_comments" | grep -E \
    -e '[Pp]reviously' \
    -e 'used to (be|stand|call|have|do)' \
    -e 'no longer (exists|needed)' \
    -e 'replaces the (old|removed|retired|deleted)' \
    -e 'as of 20[0-9][0-9]')
if [ -n "$warn_hits" ]; then
    echo "" >&2
    echo "  NOTE (non-blocking, Guard 7): past-tense comment lines staged —" >&2
    echo "  fine when they document WHY a guard exists, slop when they narrate" >&2
    echo "  an edit. Weigh them in the self-review:" >&2
    printf '%s\n' "$warn_hits" | sed 's/^+/    /' >&2
    echo "" >&2
fi

# --- Part B: the self-review receipt (BLOCKING) --------------------------
expected=$(git diff --cached -- '*.swift' 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
receipt=$(cat "$git_dir/audiouter-review-receipt" 2>/dev/null || echo none)
if [ "$receipt" != "$expected" ]; then
    echo "" >&2
    echo "  REFUSED (Guard 7): staged Swift has no matching self-review receipt." >&2
    echo "" >&2
    echo "  Run scripts/self-review.sh, actually read your staged diff against" >&2
    echo "  docs/REVIEW-RUBRIC.md (change-log narration, stale claims, naming," >&2
    echo "  reviewer-speak), fix what you find, restage, run it again, commit." >&2
    echo "" >&2
    echo "  ('git commit --no-verify' for a real emergency, as ever.)" >&2
    echo "" >&2
    exit 1
fi

echo "  Guard 7: self-review receipt verified." >&2
exit 0
