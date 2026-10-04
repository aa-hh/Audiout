#!/bin/sh
# GUARD 12 helper: AGENTS.md / AGENTS-HISTORY.md rules.
# Called by pre-commit; runnable standalone while iterating on it:
#   sh .githooks/guard-agents-docs.sh    (exit 0 = would pass)
#
#   1. AGENTS-HISTORY.md is append-only: any removed line blocks
#   2. folder AGENTS.md gains no ruling phrasing (blocks)
#   3. folder AGENTS.md gains no new date (warns only)
#   4. folder AGENTS.md over 300 words must not grow (blocks)
# The root AGENTS.md is exempt from 2-4.

# A conflict-resolution merge commit (MERGE_HEAD present) carries other
# people's lines; a clean merge never runs pre-commit at all.
[ -f "$(git rev-parse --git-dir 2>/dev/null)/MERGE_HEAD" ] && exit 0

staged=$(git diff --cached --no-renames --name-only --diff-filter=AM 2>/dev/null | grep -E '(^|/)AGENTS(-HISTORY)?\.md$')
# Deleted/renamed-away lines in a history file still count: include all statuses for history.
hist=$(git diff --cached --no-renames --name-only 2>/dev/null | grep -E '(^|/)AGENTS-HISTORY\.md$')
[ -z "$staged" ] && [ -z "$hist" ] && exit 0
folder=$(printf '%s\n' "$staged" | grep -E '(^|/)AGENTS\.md$' | grep -vx 'AGENTS.md')

nl='
'
h1=""; h2=""; h3=""; h4=""
for f in $hist; do
    r=$(git diff --cached --no-renames -U0 -- "$f" | grep -E '^-' | grep -vE '^--- (a/|/dev/null)')
    [ -n "$r" ] && h1="$h1$f$nl"
done
for f in $folder; do
    added=$(git diff --cached --no-renames -U0 -- "$f" | grep -E '^\+[^+]')
    if printf '%s\n' "$added" | grep -qiE "owner'?s (ruling|call)|\bruling\b|superseded"; then
        h2="$h2$f$nl"
    fi
    if printf '%s\n' "$added" | grep -qE '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]'; then
        h3="$h3$f$nl"
    fi
    s=$(git show ":$f" | wc -w | tr -d ' ')
    h=$(git show "HEAD:$f" 2>/dev/null | wc -w | tr -d ' ')
    [ -z "$h" ] && h=0
    if [ "$s" -gt 300 ] && [ "$s" -gt "$h" ]; then
        h4="$h4$f: $s words staged, $h at HEAD$nl"
    fi
done

rc=0
if [ -n "$h1" ]; then
    echo "" >&2
    echo "  REFUSED (Guard 12): lines removed or changed in an AGENTS-HISTORY.md:" >&2
    printf '%s' "$h1" | sed 's/^/    /' >&2
    echo "  Root AGENTS.md: history files are \"archived verbatim, not maintained\"." >&2
    echo "  Append a new dated entry instead of rewriting an old one." >&2
    echo "  ('git commit --no-verify' for a real emergency.)" >&2
    rc=1
fi
if [ -n "$h2" ]; then
    echo "" >&2
    echo "  REFUSED (Guard 12): ruling phrasing added to a folder AGENTS.md:" >&2
    printf '%s' "$h2" | sed 's/^/    /' >&2
    echo "  Root AGENTS.md: \"Never document: … dates, changelogs, 'NEW', task or" >&2
    echo "  decision ids (git owns history)\". Dated rulings go in that folder's" >&2
    echo "  AGENTS-HISTORY.md. ('git commit --no-verify' for a real emergency.)" >&2
    rc=1
fi
if [ -n "$h4" ]; then
    echo "" >&2
    echo "  REFUSED (Guard 12): folder AGENTS.md over 300 words grew:" >&2
    printf '%s' "$h4" | sed 's/^/    /' >&2
    echo "  Root AGENTS.md: \"Three sections, ≤300 words per folder AGENTS.md\"; over-budget" >&2
    echo "  material goes in a sibling AGENTS-HISTORY.md. Shrink it, don't grow it." >&2
    echo "  ('git commit --no-verify' for a real emergency.)" >&2
    rc=1
fi
if [ -n "$h3" ]; then
    echo "" >&2
    echo "  NOTE (non-blocking, Guard 12): date added to a folder AGENTS.md:" >&2
    printf '%s' "$h3" | sed 's/^/    /' >&2
    echo "  A one-line trap may keep its date; anything longer goes to AGENTS-HISTORY.md." >&2
fi
exit $rc
