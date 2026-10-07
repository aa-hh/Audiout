#!/bin/sh
# GUARD 7 helper: comment-slop screen over staged source.
# Called by pre-commit; runnable standalone while iterating on it:
#   sh .githooks/guard-self-review.sh    (exit 0 = would pass)
#
# A deterministic screen over the ADDED comment lines of the staged diff. It
# hard-blocks only near-certain slop and prints softer past-tense patterns as
# a warning for a reader to weigh. Rubric: docs/REVIEW-RUBRIC.md. A rare
# legitimate hit takes a trailing `slop-ok` comment.

hook_dir=$(dirname "$0")
COMMENT_EXTS="ts tsx js py swift go rs sh"
[ -f "$hook_dir/project.conf" ] && . "$hook_dir/project.conf"

specs=""
for e in $COMMENT_EXTS; do specs="$specs *.$e"; done
[ -z "$specs" ] && exit 0
# shellcheck disable=SC2086
staged=$(git diff --cached --name-only -- $specs 2>/dev/null)
[ -z "$staged" ] && exit 0

# shellcheck disable=SC2086
added_comments=$(git diff --cached -U0 -- $specs 2>/dev/null \
    | grep -E '^\+[^+]' | grep -E '(//|#|--|/\*|^\+[[:space:]]*\*)' | grep -v 'slop-ok')

# --- near-certain slop (BLOCKING) ---
block_hits=$(printf '%s\n' "$added_comments" | grep -E \
    -e 'this session' \
    -e '\((architecture review|fixed|added|updated|revised|corrected) 20[0-9][0-9]' \
    -e '(//|#) ?[=#-]{5,}' )
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

# --- softer patterns (WARN-ONLY) ---
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
    echo "  an edit. Weigh them before merging:" >&2
    printf '%s\n' "$warn_hits" | sed 's/^+/    /' >&2
    echo "" >&2
fi
exit 0
