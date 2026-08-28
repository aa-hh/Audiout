#!/bin/sh
# Machine-wide "live test slot" — one agent at a time may build or launch the
# shared dev build (com.audiout.Audiout.dev).
#
# WHY THIS EXISTS: only ONE native Audiout can run at a time (the PTP helper
# binds UDP 319/320 exclusively), and the dev loop deliberately REUSES one
# bundle id so its TCC grants and its Login Items approval survive every
# rebuild (CLAUDE.md, "Build & run"). Those two facts together mean a second
# agent that builds or launches the dev id while Alec is mid-test does damage
# twice over: it overwrites the .app on disk under him, and its copy fights the
# running one for the same daemon identity — the loser's SMAppService
# .register() silently no-ops, so the symptom is "the PTP helper is broken"
# rather than "two copies are running". Neither failure names its cause, which
# is what makes them expensive.
#
# Agents work in separate worktrees, in separate Claude sessions, with no
# shared memory. The only place they can agree on anything is the filesystem —
# hence a lock in /tmp, following scripts/run-tests.sh exactly (same shlock(1),
# same /tmp-so-it-spans-worktrees reasoning; flock(1) is not installed on
# macOS). Do not add a second, different locking mechanism.
#
# TRAP — THE RECORDED PID IS NOT THE HOLDER. `acquire` returns immediately (see
# below), so the process that took the slot is gone a second later. shlock's
# own dead-process reclaim would therefore free the slot instantly, which is
# the exact opposite of what is wanted. So the PID written by default is 1
# (launchd — always alive): the slot is held by INTENT, and freed only by
# `done` or by the expiry. Pass `--pid <n>` to tie it to a genuinely
# long-lived process and get shlock's honest stale-reclaim back.
#
# ACQUISITION NEVER BLOCKS. A queued agent is told who holds the slot, for how
# long, and where it stands in line — then it is expected to go do other work
# and retry. An agent asleep in a `sleep` loop is an agent doing nothing for
# half an hour, and Alec cannot see from the outside why it went quiet.
#
# Usage:
#   scripts/livetest.sh acquire --label <who> [--pid <n>]
#   scripts/livetest.sh status
#   scripts/livetest.sh queue --label <who>
#   scripts/livetest.sh done [--label <who>] [--force]   # `release` = same
#   scripts/livetest.sh check [--label <who>]            # used by make-app.sh
#
# Exit codes:
#   0  did what you asked (acquired, released, printed status)
#   1  bad usage
#   2  the slot is not yours: someone else holds it (`acquire`), or someone
#      else holds it / nobody does (`check`). Go do other work, retry later.
#   3  release refused — you are not the holder. Re-run with --force.
#
# Env:
#   AUDIOUT_LIVETEST_TTL        seconds before a held slot may be taken over
#                                 (default 2700 = 45 min)
#   AUDIOUT_LIVETEST_LOCK_FILE  where the lock lives
#                                 (default /tmp/audiout-livetest.lock)
#   AUDIOUT_NO_LIVETEST_LOCK=1  read by scripts/make-app.sh, NOT by this
#                                 script: skip the dev-id gate entirely, for a
#                                 deliberate build when you know no one else is
#                                 testing.
set -eu

lock_file=${AUDIOUT_LIVETEST_LOCK_FILE:-/tmp/audiout-livetest.lock}
meta_file="$lock_file.meta"
queue_dir="${lock_file%.lock}-queue"
ttl=${AUDIOUT_LIVETEST_TTL:-2700}
TAB=$(printf '\t')

# Who is asking. The worktree root, not a PID: the slot outlives every process
# that touches it, so identity has to be something an agent still has when it
# comes back in a fresh shell ten minutes later. A `--label` match works too,
# which is what lets Alec release a slot from anywhere.
me=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# --- arguments --------------------------------------------------------------
cmd=${1:-help}
[ $# -eq 0 ] || shift
label=""
pid=1
force=0
while [ $# -gt 0 ]; do
    case $1 in
        --label|--pid)
            [ $# -ge 2 ] || { echo "livetest: $1 needs a value" >&2; exit 1; }
            if [ "$1" = "--label" ]; then label=$2; else pid=$2; fi
            shift 2 ;;
        --force) force=1; shift ;;
        *) echo "livetest: unknown argument '$1'" >&2; exit 1 ;;
    esac
done
# A tab would split the metadata line back into the wrong fields, and a newline
# would add a field. Neither belongs in a branch or task name anyway.
label=$(printf '%s' "$label" | tr '\t\n' '  ')
case $pid in ''|*[!0-9]*) echo "livetest: --pid must be a number" >&2; exit 1 ;; esac

# --- helpers ----------------------------------------------------------------
now() { date +%s; }

human() {
    s=$1
    if   [ "$s" -lt 60 ];   then echo "${s}s"
    elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m"
    else echo "$((s / 3600))h$(((s % 3600) / 60))m"
    fi
}

# Is the slot held right now? `shlock -f` without `-p` cannot answer this — it
# returns 0 both for a valid lock AND for no lock at all — so check the pid
# ourselves. `ps -p`, not `kill -0`: kill(2) on a process owned by another user
# (pid 1, the default holder pid above) fails with EPERM, which would read as
# "dead". A lock whose process really is gone reads as free here and is then
# reclaimed by shlock itself in acquire_lock.
slot_held() {
    [ -f "$lock_file" ] || return 1
    read -r held_pid < "$lock_file" 2>/dev/null || return 1
    case $held_pid in ''|*[!0-9]*) return 1 ;; esac
    ps -p "$held_pid" >/dev/null 2>&1
}

# Holder facts into m_label / m_tree / m_age. The age comes from the lock
# file's own mtime rather than a stored timestamp: shlock creates the file with
# link(2) and nothing ever touches it afterwards, so its mtime IS the moment
# the slot was taken, and there is one less field to go stale or contradict.
read_holder() {
    m_label="(unlabelled)"
    m_tree="(unknown)"
    if [ -f "$meta_file" ]; then
        IFS="$TAB" read -r m_label m_tree < "$meta_file" || true
        [ -n "$m_label" ] || m_label="(unlabelled)"
        [ -n "$m_tree" ] || m_tree="(unknown)"
    fi
    m_started=$(stat -f %m "$lock_file" 2>/dev/null || now)
    m_age=$(( $(now) - m_started ))
    [ "$m_age" -ge 0 ] || m_age=0
}

# Does the caller own the current hold? Either identity is enough — the
# worktree so an agent needs no argument, the label so Alec can free a slot
# from the main checkout without --force.
holder_is_me() {
    [ "$m_tree" = "$me" ] && return 0
    [ -n "$label" ] && [ "$label" = "$m_label" ]
}

# --- queue ------------------------------------------------------------------
# One small file per waiting label. Keyed by LABEL, not pid: every waiter is a
# process that exited the moment it was told to come back later, so there is
# nothing alive to liveness-check and a pid-keyed queue would be empty by
# construction. Abandoned entries age out on the same TTL as the slot; an agent
# that waited longer than that and returns simply re-registers, at the back.
q_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

queue_add() {
    [ -n "$label" ] || return 0
    mkdir -p "$queue_dir"
    qf="$queue_dir/$(q_key "$label")"
    # First registration keeps the timestamp: a retry must not send a waiter to
    # the back of its own queue.
    [ -f "$qf" ] || printf '%s%s%s\n' "$(now)" "$TAB" "$label" > "$qf"
}

queue_remove() {
    [ -n "$label" ] || return 0
    rm -f "$queue_dir/$(q_key "$label")" 2>/dev/null || true
}

# Waiters oldest-first, one "<epoch><tab><label>" line each. Prunes as it goes.
queue_list() {
    [ -d "$queue_dir" ] || return 0
    cutoff=$(( $(now) - ttl ))
    for f in "$queue_dir"/*; do
        [ -f "$f" ] || continue
        qt=""; ql=""
        IFS="$TAB" read -r qt ql < "$f" || true
        case $qt in ''|*[!0-9]*) rm -f "$f"; continue ;; esac
        [ "$qt" -ge "$cutoff" ] || { rm -f "$f"; continue; }
        printf '%s%s%s\n' "$qt" "$TAB" "$ql"
    done | sort -n
}

# Read the queue ONCE and report from that snapshot: the other agents are
# writing into the same directory while we print, so counting it three times
# gives three different answers ("#1 of 2" above a list of five).
queue_report() {
    q=$(queue_list)
    [ -n "$q" ] || return 0
    n=$(printf '%s\n' "$q" | grep -c .)
    if [ -n "$label" ]; then
        pos=$(printf '%s\n' "$q" | awk -F"$TAB" -v l="$label" '$2 == l { print NR; exit }')
        [ -z "$pos" ] || echo "  you are #$pos of $n waiting."
    fi
    printf '%s\n' "$q" | while IFS="$TAB" read -r qt ql; do
        echo "    waiting: $ql (for $(human $(( $(now) - qt ))))"
    done
}

write_meta() { printf '%s%s%s\n' "$label" "$TAB" "$me" > "$meta_file"; }

release() { rm -f "$lock_file" "$meta_file"; }

# --- commands ---------------------------------------------------------------
case $cmd in

acquire)
    [ -n "$label" ] || { echo "livetest: acquire needs --label <who> (your branch or task name)" >&2; exit 1; }
    if slot_held; then
        read_holder
        if holder_is_me; then
            queue_remove
            echo "live-test slot: already yours — held $(human "$m_age") as \"$m_label\"."
            exit 0
        fi
        if [ "$m_age" -lt "$ttl" ]; then
            queue_add
            echo "live-test slot: BUSY — \"$m_label\" has held it $(human "$m_age") (expires in $(human $((ttl - m_age))))." >&2
            echo "  worktree: $m_tree" >&2
            queue_report >&2
            echo "  Go do other work and retry; 'scripts/livetest.sh status' is cheap." >&2
            exit 2
        fi
        # Expired. Take it over — but LOUDLY. Alec may still be at the speakers
        # with a build from this slot; nothing about a stale lock proves he is
        # finished, only that nobody said so.
        echo "live-test slot: WARNING — taking over an EXPIRED slot." >&2
        echo "  \"$m_label\" held it $(human "$m_age"), past the $(human "$ttl") limit, and never released it." >&2
        echo "  worktree: $m_tree" >&2
        echo "  If Alec is still testing that build, STOP and ask before you build or launch." >&2
        release
    elif [ -f "$lock_file" ]; then
        read_holder
        echo "live-test slot: reclaiming a stale slot from \"$m_label\" — its process is gone." >&2
    fi
    if /usr/bin/shlock -f "$lock_file" -p "$pid"; then
        write_meta
        queue_remove
        echo "live-test slot: ACQUIRED by \"$label\" (pid $pid). Release with: scripts/livetest.sh done"
        exit 0
    fi
    # Lost a race with another agent between the check and the shlock.
    read_holder
    queue_add
    echo "live-test slot: BUSY — \"$m_label\" took it first." >&2
    queue_report >&2
    exit 2
    ;;

done|release)
    if ! slot_held && [ ! -f "$lock_file" ]; then
        echo "live-test slot: already free."
        exit 0
    fi
    read_holder
    if holder_is_me || [ "$force" -eq 1 ]; then
        release
        [ "$force" -eq 1 ] && why=" (--force)" || why=""
        echo "live-test slot: RELEASED$why — \"$m_label\" held it $(human "$m_age")."
        n=$(queue_list | grep -c . || true)
        [ "$n" -eq 0 ] || echo "  $n waiting; the next 'acquire' takes it."
        exit 0
    fi
    echo "livetest: refusing — \"$m_label\" holds the slot, not you." >&2
    echo "  worktree: $m_tree (held $(human "$m_age"))" >&2
    echo "  If that agent is dead or wedged: scripts/livetest.sh done --force" >&2
    exit 3
    ;;

status)
    if slot_held || [ -f "$lock_file" ]; then
        read_holder
        if ! slot_held; then
            echo "live-test slot: STALE — \"$m_label\" held it $(human "$m_age"); its process is gone. The next acquire reclaims it."
        elif [ "$m_age" -ge "$ttl" ]; then
            echo "live-test slot: HELD by \"$m_label\" for $(human "$m_age") — EXPIRED (past $(human "$ttl")). The next acquire takes it over."
        else
            echo "live-test slot: HELD by \"$m_label\" for $(human "$m_age") (expires in $(human $((ttl - m_age))))."
        fi
        echo "  worktree: $m_tree"
    else
        echo "live-test slot: FREE."
    fi
    queue_report
    exit 0
    ;;

queue)
    [ -n "$label" ] || { echo "livetest: queue needs --label <who>" >&2; exit 1; }
    queue_add
    if slot_held; then
        read_holder
        echo "live-test slot: \"$m_label\" holds it ($(human "$m_age"))."
    else
        echo "live-test slot: free — 'acquire' now."
    fi
    queue_report
    exit 0
    ;;

check)
    if slot_held; then
        read_holder
        if holder_is_me; then exit 0; fi
        echo "  the live-test slot is held by \"$m_label\" (for $(human "$m_age"))" >&2
        echo "  worktree: $m_tree" >&2
        exit 2
    fi
    echo "  nobody holds the live-test slot" >&2
    exit 2
    ;;

help|--help|-h)
    # Print the header down to the first line that is not a comment. The header
    # IS the documentation, so what this prints cannot drift from it.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;

*)
    echo "livetest: unknown command '$cmd' (acquire | done | status | queue | check)" >&2
    exit 1
    ;;
esac
