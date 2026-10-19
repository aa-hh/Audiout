#!/bin/sh
# GUARD 11 helper: test discipline for staged test files.
# Called by pre-commit; runnable standalone while iterating on it:
#   sh .githooks/guard-test-discipline.sh    (exit 0 = would pass)
#
# (A @Test line added in a hunk that also removed one is a rename or an
# attribute edit of an existing test, not a new test: replacing one @Test
# with a different test in the same hunk, equal counts, is not checked.)
# Four checks over staged Swift files under AudioutCore/Tests and
# AirPlayEngine/Tests (root AGENTS.md "New tests buy their place"):
#   1. every ADDED @Test has, in the comment block directly above it, a
#      sentence naming the change that turns it red (no escape marker)
#   2. no added print( line (trailing `print-ok` exempts)
#   3. a NEW test file holds more than one @Test (`new-suite-ok` exempts)
#   4. no added real-time wait outside a // comment: Task.sleep, Thread.sleep,
#      usleep, sleep(, asyncAfter, SuiteWait.settle(, any .wait(timeout:
#      (a hang ceiling counts), or a Timeout/Delay/Deadline/Interval/Grace/
#      Window/Seconds name (optionally with Override and a type) set to a
#      positive fraction of a second such as `stallSeconds = 0.05` or
#      `makeBackend(castAbsenceGrace: 0.3)`. `real-time-ok: <reason>` exempts.

# A conflict-resolution merge commit (MERGE_HEAD present) carries other
# people's lines; a clean merge never runs pre-commit at all.
[ -f "$(git rev-parse --git-dir 2>/dev/null)/MERGE_HEAD" ] && exit 0

files=$(git diff --cached --name-only --diff-filter=AM -- 'AudioutCore/Tests/' 'AirPlayEngine/Tests/' 2>/dev/null | grep -E '\.swift$')
[ -z "$files" ] && exit 0

new_files=$(git diff --cached --name-only --diff-filter=A -- 'AudioutCore/Tests/' 'AirPlayEngine/Tests/' 2>/dev/null | grep -E '\.swift$')

hits1=""; hits2=""; hits3=""; hits4=""
nl='
'
for f in $files; do
    content=$(git show ":$f" 2>/dev/null) || continue

    # Line numbers (in the staged file) of added lines starting with @Test.
    added=$(git diff --cached -U0 -- "$f" | awk '
        /^@@/ { s = $3; sub(/^\+/, "", s); split(s, p, ","); n = p[1] + 0; r = 0; next }
        /^\+\+\+/ { next }
        /^---/ { next }
        /^-[ \t]*@Test/ { r++; next }
        /^\+/ { if ($0 ~ /^\+[ \t]*@Test/) { if (r > 0) r--; else print n }; n++ }')
    for ln in $added; do
        ok=$(printf '%s\n' "$content" | awk -v t="$ln" '
            { l[NR] = $0 }
            END {
                for (i = t - 1; i >= 1; i--) {
                    if (l[i] ~ /^[ \t]*$/) continue
                    if (l[i] !~ /^[ \t]*(\/\/|@)/ || l[i] ~ /^[ \t]*@Test/ || l[i] ~ /\{/) break
                    if (l[i] !~ /^[ \t]*\/\//) continue
                    if (tolower(l[i]) ~ /red if|turns? (it )?red|goes red|fails if/) { print "y"; exit }
                }
            }')
        [ "$ok" = y ] || hits1="$hits1$f:$ln$nl"
    done

    p=$(git diff --cached -U0 -- "$f" | grep -E '^\+[[:space:]]*print\(' | grep -v 'print-ok')
    [ -n "$p" ] && hits2="$hits2$f$nl"

    w=$(git diff --cached -U0 -- "$f" | grep -E '^\+' | grep -vE '^\+\+\+' | grep -vE '^\+[[:space:]]*//' \
        | grep -E 'Task\.sleep|Thread\.sleep|usleep\(|(^|[^A-Za-z0-9_.])sleep\(|asyncAfter|SuiteWait\.settle\(|\.wait\(timeout:|([Tt]imeout|[Dd]elay|[Dd]eadline|[Ii]nterval|[Gg]race|[Ww]indow|[Ss]econds)(Override)?[[:space:]]*(:[[:space:]]*[A-Za-z]+[[:space:]]*)?[=:][[:space:]]*0*\.0*[1-9]' \
        | grep -vE 'real-time-ok:[[:space:]]*[^[:space:]]')
    [ -n "$w" ] && hits4="$hits4$f$nl"

    case "$nl$new_files$nl" in
    *"$nl$f$nl"*)
        n=$(printf '%s\n' "$content" | grep -cE '^[[:space:]]*@Test')
        if [ "$n" -eq 1 ] && ! printf '%s\n' "$content" | grep -q 'new-suite-ok'; then
            hits3="$hits3$f$nl"
        fi ;;
    esac
done

rc=0
if [ -n "$hits1" ]; then
    echo "" >&2
    echo "  REFUSED (Guard 11): new @Test without its defect sentence:" >&2
    printf '%s' "$hits1" | sed 's/^/    /' >&2
    echo "  Root AGENTS.md: \"A new test NAMES ITS DEFECT — one comment sentence" >&2
    echo "  stating the code change that would turn it red.\" Put it in the //" >&2
    echo "  block directly above the @Test line. ('git commit --no-verify' for a" >&2
    echo "  real emergency.)" >&2
    rc=1
fi
if [ -n "$hits2" ]; then
    echo "" >&2
    echo "  REFUSED (Guard 11): print( added in a test file:" >&2
    printf '%s' "$hits2" | sed 's/^/    /' >&2
    echo "  Root AGENTS.md: a test that cannot fail is deleted, not patched; print" >&2
    echo "  asserts nothing. A trailing 'print-ok' exempts a line." >&2
    echo "  ('git commit --no-verify' for a real emergency.)" >&2
    rc=1
fi
if [ -n "$hits3" ]; then
    echo "" >&2
    echo "  REFUSED (Guard 11): new test file holding a single @Test:" >&2
    printf '%s' "$hits3" | sed 's/^/    /' >&2
    echo "  Root AGENTS.md: \"Extend before adding… a new test beats a new suite.\"" >&2
    echo "  Add it to an existing suite, or put 'new-suite-ok' in the file." >&2
    echo "  ('git commit --no-verify' for a real emergency.)" >&2
    rc=1
fi
if [ -n "$hits4" ]; then
    echo "" >&2
    echo "  REFUSED (Guard 11): real-time wait added in a test file:" >&2
    printf '%s' "$hits4" | sed 's/^/    /' >&2
    echo "  Covered: Task.sleep, Thread.sleep, usleep, sleep(, asyncAfter," >&2
    echo "  SuiteWait.settle(, every .wait(timeout:, and a Timeout/Delay/Deadline/" >&2
    echo "  Interval/Grace/Window/Seconds value set to a fraction of a second." >&2
    echo "  A wait on the wall clock flakes on a slow runner. Inject the backend's" >&2
    echo "  uptimeClock/delayClock and drive ManualDelayClock" >&2
    echo "  (AudioutCore/Tests/AudioutCoreTests/NativeBackendTests.swift) with" >&2
    echo "  advance(by:) instead. A trailing 'real-time-ok: <reason>' exempts a line;" >&2
    echo "  a hang ceiling (a .wait(timeout:) safety limit) counts as a reason." >&2
    echo "  ('git commit --no-verify' for a real emergency.)" >&2
    rc=1
fi
exit $rc
