#!/bin/sh
# Disk housekeeping for the multi-worktree workflow. Two jobs:
#
#   A. PRUNE worktrees explicitly flagged as finished: a worktree whose root
#      contains a `.prunable` marker file is removed (and its branch deleted if
#      merged) — but only after safety gates prove nothing can be lost.
#   B. SWEEP build caches machine-wide: each worktree accumulates its own
#      SwiftPM `.build` (~1 GB each; 15 worktrees once filled the disk to
#      zero bytes free mid-build). Caches untouched for a week are deleted
#      (worthless after that much source drift), and when free disk falls
#      below a floor, caches go least-recently-built-first until the floor
#      is restored. Pure compiler output, regenerable by one cold build.
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
# Env: AUDIOUT_CACHE_MAX_AGE_DAYS  staleness cutoff (default 3)
#      AUDIOUT_MIN_FREE_GB         headroom target, our caches only (default 15)
#      AUDIOUT_CRITICAL_FREE_GB    take everything below this (default 6)
#      AUDIOUT_NO_HOUSEKEEPING=1   do nothing (escape hatch for odd states)
set -u

[ "${AUDIOUT_NO_HOUSEKEEPING:-0}" = "1" ] && exit 0

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
lock=/tmp/audiout-housekeeping.lock
if [ "$dry_run" -eq 0 ]; then
    /usr/bin/shlock -f "$lock" -p $$ || exit 0
    trap 'rm -f "$lock"' EXIT HUP INT TERM
fi

say() { echo "  housekeeping: $*" >&2; }

# "Open" = a live process actually RUNNING OUT OF this path — a build, a
# script, an app launched from it, an indexer sitting in it.
#
# `pgrep -f <path>` alone is NOT that test, and using it as one silently
# disabled this whole sweep: it matches any process that merely NAMES the path
# in an argument, so one `du .../failed-row-stack` from an agent's shell makes
# that worktree look open for as long as that shell lives. Observed live —
# every candidate was "in use", nothing was ever reclaimed, and the only
# output was "still under the floor".
#
# So pgrep is used just to get cheap candidates, then each one must prove it
# really lives here: the program being executed is inside the path (argv[0],
# e.g. a built .app binary), or its working directory is (covers `/bin/sh
# <script in tree>` and swift-frontend, whose argv[0] is the toolchain's).
# Paths are compared with `case`, never split on whitespace — this repo's own
# path contains a space.
in_use() {
    for pid in $(pgrep -f "$1" 2>/dev/null); do
        cmd=$(ps -o command= -p "$pid" 2>/dev/null)
        case "$cmd" in "$1"/*) return 0 ;; esac
        cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
        case "$cwd" in "$1" | "$1"/*) return 0 ;; esac
    done
    return 1
}

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

# --- B. build caches: staleness sweep + disk-pressure floor ------------------
# NOT a fixed count. Caches on a roomy disk cost nothing, and a count cap
# forces cold rebuilds (minutes of heavy compile per Guard-4 commit) exactly
# on the busy multi-agent days run-tests.sh exists to keep survivable. The
# harm was only ever disk exhaustion, so target that directly:
#   1. STALENESS: a cache untouched for AUDIOUT_CACHE_MAX_AGE_DAYS (3) is
#      deleted unconditionally — after that much source drift SwiftPM largely
#      rebuilds from scratch anyway, so it saves ~nothing and holds ~1.3 GB.
#      Cut from 7 days to 3 on 2026-08-29: with 30+ live worktrees nothing was
#      ever idle for a full week, so this rule had never once fired.
#   2. PRESSURE: below AUDIOUT_MIN_FREE_GB (15) free, delete caches least-
#      recently-built first — but ONLY when doing so actually reaches the
#      floor, so builds never eat the last of the disk while a shortfall
#      caused elsewhere is left for a human to deal with. See rule 2 below.
# The current checkout and anything a live process references are never
# touched by either rule.
max_age_days=${AUDIOUT_CACHE_MAX_AGE_DAYS:-3}
# The headroom a build should be able to count on: ~2 builds' worth (~1.3 GB
# each) plus room for the OS to breathe, and comfortably ABOVE the ~8 GB line
# where this machine's builds start hanging and dying with 137.
# Raised 8 -> 15 on 2026-08-29: the disk sat at 8.4-8.8 GB for days, i.e.
# permanently just above the old trigger, so the pressure rule never ran while
# builds were already failing for want of space.
min_free_gb=${AUDIOUT_MIN_FREE_GB:-15}
# Emergency line. Above it, a shortfall we cannot fix is reported and left
# alone; below it, every reclaimable cache goes regardless, because a build
# dying on a full disk is the incident this whole script exists to prevent.
critical_gb=${AUDIOUT_CRITICAL_FREE_GB:-6}
now=$(date +%s)

# A "build" is a checkout owning any SwiftPM cache dir; its recency is the
# newest mtime among them (a build touches its .build root).
# Found by search, not by a hardcoded list of three: the spike packages under
# dev/ (dev/audiocap, dev/bt-multi-spike) own their own caches — 68 MB and
# 240 MB when this was written — and a fixed list simply never saw them.
# -maxdepth 3 keeps the scan cheap and stops short of
# .claude/worktrees/<slug>/*/.build, whose caches are enumerated as their own
# units; -prune stops the walk at each cache instead of descending it.
caches_of() { find "$1" -maxdepth 3 -type d -name .build -prune 2>/dev/null; }
# Newline-piped, never `for d in $(...)`: this repo's own path contains a
# space, which word-splitting silently breaks (see the AGENTS.md warning).
newest_mtime() {
    m=$(caches_of "$1" | while IFS= read -r d; do stat -f %m "$d" 2>/dev/null; done | sort -rn | head -1)
    echo "${m:-0}"
}
free_kb() { df -k "$primary" | awk 'NR==2 {print $4}'; }
human_mb() { awk -v kb="$1" 'BEGIN { if (kb >= 1048576) printf "%.1f GB", kb/1048576; else printf "%d MB", kb/1024 }'; }
size_of() {  # $1 = unit — total KB across every cache it owns
    caches_of "$1" | while IFS= read -r d; do du -sk "$d" 2>/dev/null | cut -f1; done |
        awk '{s+=$1} END {print s+0}'
}
delete_caches() {  # $1 = unit, $2 = reason
    sz=$(human_mb "$(size_of "$1")")
    if [ "$dry_run" -eq 1 ]; then
        say "would delete build cache in $(basename "$1")${sz:+ (~$sz)} — $2."
    else
        caches_of "$1" | while IFS= read -r d; do rm -rf "$d"; done
        say "deleted build cache in $(basename "$1")${sz:+ (~$sz)} — $2 (regenerable)."
    fi
}
# Says WHY it is skipping. An unexplained "still under the floor" is
# indistinguishable from the sweep being broken — which it silently was, until
# in_use stopped counting "some shell mentioned this path" as in use.
skippable() {
    [ "$1" = "$current" ] && return 1
    # The primary checkout is Alec's live workspace, and every worktree path
    # sits under it — so the cwd test below would call it "in use" for the
    # wrong reason. Protect it deliberately and say why.
    if [ "$1" = "$primary" ]; then
        say "keeping cache in the primary checkout (live workspace)."
        return 1
    fi
    if in_use "$1"; then
        say "keeping cache in $(basename "$1") — a process is running out of it."
        return 1
    fi
    return 0
}

# Enumerate units (primary + every worktree) that have caches, oldest first —
# the deletion order for both rules. Paths contain spaces, so the mtime sort
# key rides in front, tab-separated.
units=$(
    { printf '%s\n' "$primary"; for wt in "$worktrees_dir"/*/; do printf '%s\n' "${wt%/}"; done; } |
    while IFS= read -r u; do
        [ -n "$(caches_of "$u")" ] || continue
        printf '%s\t%s\n' "$(newest_mtime "$u")" "$u"
    done | sort -n
)

# Rule 0: dead-engine subtrees. This repo builds exclusively with
# `--build-system native` (see scripts/run-tests.sh), whose cache is
# .build/arm64-apple-macosx. The DEFAULT engine's cache — .build/out — is
# therefore unreachable: no command this repo runs can ever hit it again. It is
# ~800 MB per worktree and was 8.4 GB machine-wide at the switchover.
#
# This runs BEFORE the two rules below on purpose, because it is the only
# reclaim that is free: rules 1 and 2 delete WARM caches and make that
# worktree's next build cold (~95s), whereas a dead engine's tree costs nothing
# to give up. Reclaiming it first often clears the floor with no rebuild at all.
#
# Same "unless open" gate as every other delete — a worktree someone left on the
# old engine still has a live process pointing at it, so `skippable` protects it
# and it simply ages out via rule 1 instead.
#
# AND it only fires on a worktree whose OWN checkout has the native pin. A
# branch cut before that change still builds with swiftbuild, so its .build/out
# is its LIVE cache, not a dead one — deleting it would force a cold rebuild
# that the branch then immediately redoes, thrashing it once per housekeeping
# run until it merges main. Checking each worktree's own run-tests.sh keeps the
# reclaim to caches that are genuinely unreachable.
dead_engine_dir=out
migrated() {
    grep -q -- '--build-system native' "$1/scripts/run-tests.sh" 2>/dev/null && return 0
    # A worktree predating the pin is still BUILT by the primary checkout's
    # wrapper — Guard 4 resolves scripts/ there whenever the worktree is older
    # than they are — so the native cache it grew is the live one and .build/out
    # is dead after all. Presence of BOTH is the evidence: nothing produces an
    # arm64-apple-macosx tree except the pinned wrapper. Without this the
    # commonest case on this machine (33 worktrees, 10 carrying both engines)
    # was skipped forever and cost ~1.3 GB each.
    both=$(caches_of "$1" | while IFS= read -r d; do
        [ -d "$d/arm64-apple-macosx" ] && printf 'x'
    done)
    [ -n "$both" ]
}
printf '%s\n' "$units" | while IFS='	' read -r mt u; do
    [ -n "$u" ] || continue
    found=$(caches_of "$u" | while IFS= read -r d; do
        [ -d "$d/$dead_engine_dir" ] && printf '%s\n' "$d/$dead_engine_dir"
    done)
    [ -n "$found" ] || continue
    migrated "$u" || continue
    skippable "$u" || continue
    sz=$(printf '%s\n' "$found" | while IFS= read -r d; do du -sk "$d" 2>/dev/null | cut -f1; done |
         awk '{t+=$1} END {printf "%d", t/1024}')
    if [ "$dry_run" -eq 1 ]; then
        say "would delete dead swiftbuild cache in $(basename "$u") (~${sz} MB) — repo builds with --build-system native."
    else
        printf '%s\n' "$found" | while IFS= read -r d; do rm -rf "$d"; done
        say "deleted dead swiftbuild cache in $(basename "$u") (~${sz} MB) — unreachable, repo builds with --build-system native."
    fi
done

# Rule 1: staleness.
max_age_s=$((max_age_days * 86400))
printf '%s\n' "$units" | while IFS='	' read -r mt u; do
    [ -n "$u" ] || continue
    [ $((now - mt)) -gt "$max_age_s" ] || continue
    skippable "$u" || continue
    delete_caches "$u" "untouched for >${max_age_days}d"
done

# Rule 1b: Xcode's own build caches, outside the repo.
#
# Not this repo's directories, but the same substance — regenerable output
# that this project's own work creates, and much bigger than anything in the
# tree. Two kinds:
#   iOS DeviceSupport  symbols copied off the iPhone on each attach, ~1.5 GB
#                      per iOS build, one directory per build. Reached 6.4 GB
#                      during the companion-app work and put the machine under
#                      the floor by itself, which the repo's own caches then
#                      could not fix — the case rule 2 below used to give up on.
#   DerivedData        Xcode's per-project build output.
# Losing either costs one slow re-attach or one cold Xcode build. Never work.
#
# Deliberately NOT touched: the simulator RUNTIME image (~7.5 GB, in
# ~/Library/Developer/CoreSimulator) and DVTDownloads. Those are downloads,
# not caches — re-fetching them is a long job, and Alec has said keep them.
# Simulator DEVICES are left alone too: erasing one is a decision about
# someone's test state, not disk hygiene.
#
# Skipped wholesale while Xcode is running: it may be mid-attach or mid-build.
xcode_dir="$HOME/Library/Developer/Xcode"
xcode_caches() {
    for d in "$xcode_dir/iOS DeviceSupport"/*/ "$xcode_dir/DerivedData"/*/; do
        [ -d "$d" ] && printf '%s\n' "${d%/}"
    done
}
delete_xcode_cache() {  # $1 = dir, $2 = reason
    sz=$(human_mb "$(du -sk "$1" 2>/dev/null | cut -f1)")
    if [ "$dry_run" -eq 1 ]; then
        say "would delete Xcode cache $(basename "$1") (~$sz) — $2."
    else
        rm -rf "$1"
        say "deleted Xcode cache $(basename "$1") (~$sz) — $2 (regenerable)."
    fi
}
xcode_busy=0
pgrep -x Xcode >/dev/null 2>&1 && xcode_busy=1
if [ "$xcode_busy" -eq 1 ]; then
    say "keeping Xcode's caches — Xcode is running."
else
    xcode_caches | while IFS= read -r d; do
        mt=$(stat -f %m "$d" 2>/dev/null || echo "$now")
        [ $((now - mt)) -gt "$max_age_s" ] || continue
        delete_xcode_cache "$d" "untouched for >${max_age_days}d"
    done
fi

# Rule 2: pressure floor — scoped to what this project's work created.
#
# The floor is headroom this script tries to guarantee using the caches it
# owns: the repo's `.build` trees and, since rule 1b, Xcode's device-support
# and DerivedData trees. It is still NOT a promise about the disk as a whole —
# a 62 GB music library or a simulator runtime image is not ours to reclaim.
#
# That is why this is not a plain "delete oldest until free >= floor" loop. It
# cannot reach a floor our caches did not cause, so it would delete every warm
# cache, make the next build in each worktree cold, and STILL report failure —
# pure loss. Observed live, and the reason this rule was rewritten.
#
# So: measure what is actually reclaimable first, and only reclaim when doing
# so reaches the floor. When it cannot, keep the caches and say plainly that
# the shortfall came from somewhere else — that is a message for a human, not
# a problem this script should thrash trying to fix.
#
# Xcode's caches go FIRST in the order, ahead of even the oldest `.build`.
# They are the cheap ones: giving one up costs a re-attach nobody is waiting
# on, where a warm `.build` costs ~95s of compile on the next commit.
#
# The exception is genuine emergency: below AUDIOUT_CRITICAL_FREE_GB, take
# everything reclaimable even though it falls short. Preventing a build that
# dies on a full disk beats keeping caches warm, and a zero-byte disk is the
# incident that started all of this.
min_free_kb=$((min_free_gb * 1024 * 1024))
critical_kb=$((critical_gb * 1024 * 1024))
free_now=$(free_kb)
if [ "$free_now" -lt "$min_free_kb" ]; then
    # Candidates as `size<TAB>kind<TAB>path`, cheapest-to-lose first: Xcode's
    # caches, then `.build` trees oldest first. Skip reasons print to stderr
    # from skippable(), so they never pollute this capture.
    candidates=$(
        [ "$xcode_busy" -eq 0 ] && xcode_caches | while IFS= read -r d; do
            printf '%s\txcode\t%s\n' "$(du -sk "$d" 2>/dev/null | cut -f1)" "$d"
        done
        printf '%s\n' "$units" | while IFS='	' read -r mt u; do
            [ -n "$u" ] || continue
            [ -n "$(caches_of "$u")" ] || continue   # rule 1 may have emptied it
            skippable "$u" || continue
            printf '%s\tswift\t%s\n' "$(size_of "$u")" "$u"
        done
    )
    reclaimable=$(printf '%s\n' "$candidates" | awk -F'\t' '{s+=$1} END {print s+0}')

    if [ -z "$candidates" ]; then
        say "under ${min_free_gb} GB free, but every build cache is in use or protected — nothing to reclaim."
    elif [ $((free_now + reclaimable)) -ge "$min_free_kb" ] || [ "$free_now" -lt "$critical_kb" ]; then
        say "under ${min_free_gb} GB free — reclaiming build caches, cheapest first."
        printf '%s\n' "$candidates" | while IFS='	' read -r sz kind p; do
            [ -n "$p" ] || continue
            # Re-read df per delete so this stops at the minimum needed. In a
            # dry run nothing is freed, so this would never stop — hence the
            # dry_run guard, which lists the full order instead.
            [ "$dry_run" -eq 0 ] && [ "$(free_kb)" -ge "$min_free_kb" ] && break
            case "$kind" in
                xcode) delete_xcode_cache "$p" "disk below ${min_free_gb} GB free" ;;
                *)     delete_caches "$p" "disk below ${min_free_gb} GB free" ;;
            esac
        done
    else
        say "under ${min_free_gb} GB free ($((free_now / 1024 / 1024)) GB), but every cache this"
        say "project owns totals only $(human_mb "$reclaimable") — the shortfall is not ours, so they stay warm."
        say "Look elsewhere: the simulator runtime image, DVTDownloads, ~/Music, ~/Library/Caches."
    fi
fi

exit 0
