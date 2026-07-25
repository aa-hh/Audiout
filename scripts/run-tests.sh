#!/bin/sh
# Machine-wide serialised runner for the AudiouterCore suite.
#
# WHY THIS EXISTS: every worktree's pre-commit Guard 4 runs the full suite, and
# each run politely caps itself at `--num-workers 4`. But that cap is
# PER-PROCESS — nothing coordinates across worktrees. With four agents
# committing at once the machine sees 4 full suites x 4 workers = 16 concurrent
# xctest processes plus 4 independent compiles, on 8 cores. Measured 15-minute
# load average during a normal multi-agent session: 73.
#
# Serialising is strictly better than throttling here. Test runs are
# CPU-saturating, so running two at once does not overlap any idle time — it
# just makes both slower and the machine unusable. One run at a time, given
# more workers than the timid shared-machine cap, finishes each run FASTER than
# today while leaving headroom for everything else.
#
# Two mechanisms:
#   1. A machine-wide lock (/tmp, so it spans every worktree). Waiters queue.
#   2. A content-addressed pass cache. Agents routinely run the suite by hand
#      and then commit, which fires Guard 4 on byte-identical sources
#      immediately afterwards. The second run is pure waste; the cache skips it.
#
# Usage:  scripts/run-tests.sh [extra swift-test args...]
# Env:
#   AUDIOUTER_TEST_WORKERS   worker count once the lock is held (default 6)
#   AUDIOUTER_TEST_NO_LOCK=1 run immediately, no lock (for a deliberate
#                            foreground run when you know the machine is idle)
#   AUDIOUTER_TEST_NO_CACHE=1 always run, never consult or write the cache
#   AUDIOUTER_TEST_LOCK_TIMEOUT  seconds to wait for the lock (default 1800)
set -eu

repo_root=$(git rev-parse --show-toplevel)
core="$repo_root/AudiouterCore"

workers=${AUDIOUTER_TEST_WORKERS:-6}
lock_timeout=${AUDIOUTER_TEST_LOCK_TIMEOUT:-1800}
# How many suite runs may proceed at once, machine-wide. Default 2: a single run
# only reaches ~2.6 of 8 cores (it is wait-bound, not CPU-bound), so two overlap
# comfortably while still leaving headroom for the developer's own machine.
# Raise for a beefier box, set to 1 for strict one-at-a-time.
slots=${AUDIOUTER_TEST_SLOTS:-2}

# Lock and cache live in /tmp on purpose: they must be shared by EVERY worktree
# and every clone on this machine, so they cannot live under $repo_root (each
# worktree has its own) or under .git (ditto).
lock_file=${AUDIOUTER_TEST_LOCK_FILE:-/tmp/audiouter-suite.lock}
cache_dir=${AUDIOUTER_TEST_CACHE_DIR:-/tmp/audiouter-suite-cache}

# --- content key ------------------------------------------------------------
# Hash what the suite's result actually depends on: the Swift sources and tests
# of the package under test, plus the engine package it links and both
# manifests. Hashing files on disk (not the git index) is deliberate — it is
# correct both for a pre-commit run, where the working tree IS what is about to
# be committed, and for a manual run mid-edit.
suite_key() {
    {
        find "$repo_root/AudiouterCore/Sources" "$repo_root/AudiouterCore/Tests" \
             "$repo_root/AirPlayEngine/Sources" \
             -type f \( -name '*.swift' -o -name '*.c' -o -name '*.h' \) \
             -exec shasum -a 256 {} + 2>/dev/null
        # The manifests MUST be in the key and are not under any Sources/ dir:
        # they carry the target graph, dependencies and the brew include flags,
        # so a manifest-only edit changes what the suite links and can flip a
        # result with every source file byte-identical.
        shasum -a 256 "$repo_root/AudiouterCore/Package.swift" \
                      "$repo_root/AirPlayEngine/Package.swift" 2>/dev/null
    } | awk '{print $1}' | sort | shasum -a 256 | awk '{print $1}'
}

key=$(suite_key)
# The cache records "these exact sources passed", so it must also be keyed on
# the arguments — a `--filter Foo` pass says nothing about the full suite.
args_key=$(printf '%s' "$*" | shasum -a 256 | awk '{print $1}')
stamp="$cache_dir/$key.$args_key"

if [ "${AUDIOUTER_TEST_NO_CACHE:-0}" != "1" ] && [ -f "$stamp" ]; then
    echo "  suite: sources unchanged since a passing run — skipping." >&2
    echo "  (AUDIOUTER_TEST_NO_CACHE=1 to force)" >&2
    exit 0
fi

# --- lock -------------------------------------------------------------------
# shlock(1) is the macOS base-system answer to flock(1), which is NOT installed
# here. It writes our PID atomically and, critically, reclaims the lock if the
# recorded PID is gone — so an agent killed mid-run cannot wedge the machine.
#
# NOT a hard mutex — a COUNTING semaphore of `slots` permits, implemented as
# `slots` independent shlock files where a run takes the first one it can get.
#
# Why not one exclusive lock (the obvious first design, and what this was):
# that assumed a test run saturates the CPU, so overlapping two would gain
# nothing. MEASUREMENT SAYS OTHERWISE — a warm `--parallel --num-workers 6` run
# uses 411s user + 66s sys over 181s wall, i.e. only ~2.6 of 8 cores. The suite
# is WAIT-bound (timers, expectations), not CPU-bound. Two or three concurrent
# runs genuinely do overlap, so serialising to exactly one would idle most of
# the machine AND make four agents queue behind each other for no reason.
# The cap exists to stop unbounded pile-up, not to enforce single-file.
acquired=0
slot_file=""
if [ "${AUDIOUTER_TEST_NO_LOCK:-0}" = "1" ]; then
    echo "  suite: AUDIOUTER_TEST_NO_LOCK=1 — not limiting concurrency." >&2
else
    waited=0
    announced=0
    while :; do
        n=1
        while [ "$n" -le "$slots" ]; do
            if /usr/bin/shlock -f "${lock_file}.$n" -p $$; then
                slot_file="${lock_file}.$n"
                break
            fi
            n=$((n + 1))
        done
        [ -n "$slot_file" ] && break
        if [ "$announced" -eq 0 ]; then
            echo "  suite: all $slots test slots busy — waiting for one to free." >&2
            announced=1
        fi
        if [ "$waited" -ge "$lock_timeout" ]; then
            # Degrade, do NOT fail. This runner's job is to keep the machine
            # usable, not to gate correctness — Guard 4 calls it to decide
            # whether a commit is safe, and failing a commit because some OTHER
            # worktree is busy would block legitimate work for a reason the
            # committer cannot see or fix. Falling through runs unlocked, i.e.
            # exactly the pre-runner behaviour, so the worst case is the old
            # contention rather than a wedged agent.
            echo "  suite: all slots busy for ${lock_timeout}s — proceeding UNCAPPED." >&2
            echo "  (expect contention; check ${lock_file}.N pids if this repeats)" >&2
            timed_out=1
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    # Only install the release trap if we actually HOLD a slot. On the timeout
    # path `slot_file` is empty; removing someone else's slot file would hand a
    # permit to a third process and break the cap.
    if [ "${timed_out:-0}" -eq 0 ] && [ -n "$slot_file" ]; then
        acquired=1
        # Release on ANY exit path, including the failure exit below and a
        # signal — a held slot outliving its holder permanently shrinks the cap.
        trap 'rm -f "$slot_file"' EXIT HUP INT TERM
    fi
fi

[ "$acquired" -eq 1 ] && \
    echo "  suite: slot $(basename "$slot_file") of $slots — running with $workers workers." >&2

# --- run --------------------------------------------------------------------
# `set -e` is off for this one command so a failure reaches the cache logic
# (which must NOT write a stamp) and the trap, rather than exiting immediately.
set +e
( cd "$core" && swift test --parallel --num-workers "$workers" "$@" ) >&2
status=$?
set -e

if [ "$status" -eq 0 ] && [ "${AUDIOUTER_TEST_NO_CACHE:-0}" != "1" ]; then
    mkdir -p "$cache_dir"
    : > "$stamp"
fi

exit "$status"
