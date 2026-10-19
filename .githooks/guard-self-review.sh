#!/bin/sh
# GUARD 7 helper: staged-Swift readability screen.
# Called by pre-commit; runnable standalone while iterating on it:
#   sh .githooks/guard-self-review.sh    (exit 0 = would pass)
#
# A deterministic screen over the ADDED comment lines of the staged
#   Swift diff (same -U0 technique as Guards 3/5). It hard-blocks only
#   near-certain slop — the three patterns the 2026-08-06 audit
#   (dev/notes/verbosity-audit-2026-08-06.md) found with ~zero false
#   positives — and prints softer past-tense patterns as a warning for
#   a reader to weigh. A rare legitimate hit takes a trailing
#   `slop-ok` comment (sibling of Guard 3's `isolation-ok`).

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

# --- Part A': softer patterns (WARN-ONLY) ---
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
