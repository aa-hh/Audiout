#!/bin/sh
# Disk housekeeping for the multi-worktree workflow. Two jobs:
#
#   A. PRUNE worktrees explicitly flagged as finished: a worktree whose root
#      contains a `.prunable` marker file is removed (and its branch deleted if
#      merged) — but only after safety gates prove nothing can be lost.
#   B. CAP build caches machine-wide: each worktree accumulates its own
#      SwiftPM `.build` (~1 GB each; 15 worktrees once filled the disk to
#      zero bytes free mid-build). At most CAP (default 2) checkouts keep a
#      cache: the one building now plus the most recently built other. The
#      rest are deleted — they are pure compiler output, regenerable at the
#      cost of one cold build.
#
# Called best-effort (never blocking, never failing the caller) from
# scripts/run-tests.sh and scripts/make-app.sh, so it runs whenever a build or
# suite run happens — the exact moment disk pressure appears. Also runnable by
# hand.
#
# Flagging a worktree for prune (do this once its branch is merged AND
# live-verified, or abandoned):
#     touch .claude/worktrees/<slug>/.prunable
# The flag alone is not enough — every gate below must ALSO pass, so a
# mistaken flag on a dirty or unpushed worktree is refused loudly, not obeyed.
#
# Safety gates for a prune (ALL required):
#   - not the checkout invoking this script, and not the primary checkout
#   - no running process references the worktree path (catches an editor with
#     the project open, a build, an indexer — "unless one's open")
#   - `git status --porcelain` clean apart from the marker itself
#   - HEAD is merged into main, OR identical to its pushed upstream — either
#     way every commit survives the prune
#   - the branch itself is deleted only when merged (`git branch -d`, never -D)
#
# A cache delete has the same "unless open" gate: a checkout with any live
# process referencing it keeps its cache and does not count against the cap.
#
# Usage: scripts/housekeeping.sh [--current <repo-root>] [--dry-run]
#   --current  the checkout whose build is starting (default: the repo root
#              this script is invoked from) — always protected from both jobs
#   --dry-run  report what would happen, touch nothing
#
# Env: AUDIOUTER_BUILD_CACHE_CAP  how many .build caches survive (default 2)
#      AUDIOUTER_NO_HOUSEKEEPING=1  do nothing (escape hatch for odd states)
set -u

[ "${AUDIOUTER_NO_HOUSEKEEPING:-0}" = "1" ] && exit 0

dry_run=0
current=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --current) shift; current=${1:-} ;;
        *) echo "housekeeping: unknown arg '$1'" >&2; exit 2 ;;
    esac
    shift
done

# Resolve the primary checkout from wherever we were invoked: the common git
# dir is always <primary>/.git, even when cwd is a worktree.
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
primary=$(dirname "$common_dir")
worktrees_dir="$primary/.claude/worktrees"
[ -d "$worktrees_dir" ] || exit 0
[ -n "$current" ] || current=$(git rev-parse --show-toplevel 2>/dev/null || echo "$primary")

# Single instance machine-wide: two builds starting at once must not race to
# prune the same worktree or delete each other's kept cache. shlock (macOS
# base system) reclaims the lock if the recorded PID is dead. Busy => the
# other run is already doing this exact work — skip silently, don't queue.
lock=/tmp/audiouter-housekeeping.lock
if [ "$dry_run" -eq 0 ]; then
    /usr/bin/shlock -f "$lock" -p $$ || exit 0
    trap 'rm -f "$lock"' EXIT HUP INT TERM
fi

say() { echo "  housekeeping: $*" >&2; }

# "Open" = any live process whose command line references this path — an
# editor, a build, sourcekitd indexing it. pgrep -f treats the path as a
# regex; the dots in usernames match-any is fine (over-matching only makes us
# MORE conservative). $$-family excluded implicitly: our own command line only
# names --current, which is protected before this check is ever consulted.
in_use() { pgrep -f "$1" >/dev/null 2>&1; }

# --- A. prune flagged worktrees --------------------------------------------
for wt in "$worktrees_dir"/*/; do
    wt=${wt%/}
    [ -f "$wt/.prunable" ] || continue
    if [ "$wt" = "$current" ] || [ "$wt" = "$primary" ]; then
        say "SKIP prune $(basename "$wt"): is the checkout running this build."
        continue
    fi
    if in_use "$wt"; then
        say "SKIP prune $(basename "$wt"): a running process references it."
        continue
    fi
    dirt=$(git -C "$wt" status --porcelain 2>/dev/null | grep -v '^?? \.prunable$' || true)
    if [ -n "$dirt" ]; then
        say "SKIP prune $(basename "$wt"): uncommitted changes (flag it again once clean):"
        printf '%s\n' "$dirt" | sed 's/^/      /' >&2
        continue
    fi
    merged=0
    git -C "$wt" merge-base --is-ancestor HEAD main 2>/dev/null && merged=1
    if [ "$merged" -eq 0 ]; then
        up=$(git -C "$wt" rev-parse '@{upstream}' 2>/dev/null || true)
        if [ -z "$up" ] || [ "$up" != "$(git -C "$wt" rev-parse HEAD)" ]; then
            say "SKIP prune $(basename "$wt"): HEAD neither merged into main nor pushed."
            continue
        fi
    fi
    branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true)
    if [ "$dry_run" -eq 1 ]; then
        if [ "$merged" -eq 1 ] && [ -n "$branch" ]; then
            say "would prune worktree $(basename "$wt") and delete merged branch $branch."
        else
            say "would prune worktree $(basename "$wt") (branch kept — pushed but not merged)."
        fi
        continue
    fi
    # The marker is untracked, which `worktree remove` refuses without
    # --force. Deleting the marker first keeps --force out of this script
    # entirely: any OTHER untracked file still refuses the removal.
    rm -f "$wt/.prunable"
    if git -C "$primary" worktree remove "$wt" 2>/dev/null; then
        say "pruned worktree $(basename "$wt")."
        if [ "$merged" -eq 1 ] && [ -n "$branch" ]; then
            git -C "$primary" branch -d "$branch" >/dev/null 2>&1 \
                && say "deleted merged branch $branch."
        fi
    else
        touch "$wt/.prunable" 2>/dev/null
        say "SKIP prune $(basename "$wt"): git worktree remove refused (locked or untracked files)."
    fi
done

# --- B. cap build caches ----------------------------------------------------
cap=${AUDIOUTER_BUILD_CACHE_CAP:-2}

# A "build" is a checkout owning any SwiftPM cache dir; its recency is the
# newest mtime among them (a build touches its .build root).
caches_of() { for d in "$1/.build" "$1/AudiouterCore/.build" "$1/AirPlayEngine/.build"; do [ -d "$d" ] && printf '%s\n' "$d"; done; }
# Newline-piped, never `for d in $(...)`: this repo's own path contains a
# space, which word-splitting silently breaks (see the AGENTS.md warning).
newest_mtime() {
    m=$(caches_of "$1" | while IFS= read -r d; do stat -f %m "$d" 2>/dev/null; done | sort -rn | head -1)
    echo "${m:-0}"
}

# Enumerate units (primary + every worktree), newest first. Paths contain
# spaces, so the sort key rides in front and is stripped after.
units=$(
    { printf '%s\n' "$primary"; for wt in "$worktrees_dir"/*/; do printf '%s\n' "${wt%/}"; done; } |
    while IFS= read -r u; do
        [ -n "$(caches_of "$u")" ] || continue
        printf '%s\t%s\n' "$(newest_mtime "$u")" "$u"
    done | sort -rn | cut -f2-
)

kept=1  # the current checkout always holds a slot — it is building right now
printf '%s\n' "$units" | while IFS= read -r u; do
    [ -n "$u" ] || continue
    [ "$u" = "$current" ] && continue
    if in_use "$u"; then
        [ "$dry_run" -eq 1 ] && say "keeping cache in $(basename "$u") (in use)."
        continue
    fi
    if [ "$kept" -lt "$cap" ]; then
        kept=$((kept + 1))
        continue
    fi
    sz=$(du -sh "$u/AudiouterCore/.build" 2>/dev/null | cut -f1)
    if [ "$dry_run" -eq 1 ]; then
        say "would delete build cache in $(basename "$u")${sz:+ (~$sz)}."
    else
        caches_of "$u" | while IFS= read -r d; do rm -rf "$d"; done
        say "deleted build cache in $(basename "$u")${sz:+ (~$sz)} — regenerable, cap is $cap."
    fi
done

exit 0
