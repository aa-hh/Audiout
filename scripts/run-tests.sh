#!/bin/sh
# Machine-wide serialised runner for the AudioutCore suite.
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
#   AUDIOUT_TEST_WORKERS   worker count once the lock is held (default 6)
#   AUDIOUT_TEST_NO_LOCK=1 run immediately, no lock (for a deliberate
#                            foreground run when you know the machine is idle)
#   AUDIOUT_TEST_NO_CACHE=1 always run, never consult or write the cache
#   AUDIOUT_TEST_LOCK_TIMEOUT  seconds to wait for the lock (default 1800)
set -eu

repo_root=$(git rev-parse --show-toplevel)
core="$repo_root/AudioutCore"

# Disk housekeeping (prune .prunable-flagged worktrees, cap .build caches) at
# the moment disk pressure actually appears: a build starting. Best-effort by
# construction — a housekeeping failure must never fail or block a test run.
# Same resolution order as Guard 4 uses for this script: this worktree's own
# copy first, else the copy beside this script (the primary checkout's).
hk="$repo_root/scripts/housekeeping.sh"
[ -x "$hk" ] || hk="$(cd "$(dirname "$0")" && pwd)/housekeeping.sh"
if [ -x "$hk" ]; then "$hk" --current "$repo_root" || true; fi

workers=${AUDIOUT_TEST_WORKERS:-6}
lock_timeout=${AUDIOUT_TEST_LOCK_TIMEOUT:-1800}
# How many suite runs may proceed at once, machine-wide. Default 2: a single run
# only reaches ~2.6 of 8 cores (it is wait-bound, not CPU-bound), so two overlap
# comfortably while still leaving headroom for the developer's own machine.
# Raise for a beefier box, set to 1 for strict one-at-a-time.
slots=${AUDIOUT_TEST_SLOTS:-2}

# --- remote machine ---------------------------------------------------------
# Host resolution, the local-vs-remote decision, sync and the run-there wrapper
# all live in scripts/lib/remote.sh, shared with scripts/build.sh and
# scripts/make-app.sh so tests and builds cannot drift apart on where work goes.
# Resolved beside THIS script rather than from $repo_root: Guard 4 runs a
# worktree's hook against the primary checkout's scripts/ when the worktree
# predates them, and the library must travel with the script that sources it.
. "$(cd "$(dirname "$0")" && pwd)/lib/remote.sh"
remote_tried=0

# Thin test-specific wrapper over remote_run. Return codes are remote_run's:
#   0 = passed remotely   1 = could not use the remote   2 = ran and FAILED
run_remote() {
    if [ "$remote_pref" = "remote" ]; then
        echo "  suite: sending to remote $remote_host (preferred) ..." >&2
    elif [ "$remote_pref" = "cpu" ]; then
        echo "  suite: sending to remote $remote_host (lower CPU load) ..." >&2
    else
        echo "  suite: local slots busy — trying remote $remote_host ..." >&2
    fi

    # Mode for the REMOTE run is decided independently of the local machine:
    # the whole reason we are here is that this Mac is busy and that one is not,
    # so the remote gets the fast parallel path (~1.8x quicker on an idle host).
    # An explicitly forced AUDIOUT_TEST_MODE is still honoured.
    case "${AUDIOUT_TEST_MODE:-auto}" in
        serial) rargs="" ;;
        *)      rargs="--parallel --num-workers $workers" ;;
    esac

    rrc=0
    remote_run "$repo_root" "cd AudioutCore && swift test $rargs $*" || rrc=$?
    if [ "$rrc" -eq 2 ]; then
        # "Ran, but failed" — re-run locally rather than trusting the verdict. A
        # machine on a different Swift/SDK must never be what REFUSES a commit:
        # Guard 4 blocks on this result, and a toolchain difference presenting
        # as "your code is broken" would send an agent hunting a bug that does
        # not exist. A remote PASS is still accepted — the asymmetry is
        # deliberate, since the expensive error is a false refusal.
        echo "  suite: remote reported FAILURES — re-running locally to confirm." >&2
        return 2
    fi
    [ "$rrc" -ne 0 ] && return 1
    echo "  suite: passed on remote $remote_host." >&2
    return 0
}

# Lock and cache live in /tmp on purpose: they must be shared by EVERY worktree
# and every clone on this machine, so they cannot live under $repo_root (each
# worktree has its own) or under .git (ditto).
lock_file=${AUDIOUT_TEST_LOCK_FILE:-/tmp/audiout-suite.lock}
cache_dir=${AUDIOUT_TEST_CACHE_DIR:-/tmp/audiout-suite-cache}

# --- content key ------------------------------------------------------------
# Hash what the suite's result actually depends on: the Swift sources and tests
# of the package under test, plus the engine package it links and both
# manifests. Hashing files on disk (not the git index) is deliberate — it is
# correct both for a pre-commit run, where the working tree IS what is about to
# be committed, and for a manual run mid-edit.
suite_key() {
    {
        find "$repo_root/AudioutCore/Sources" "$repo_root/AudioutCore/Tests" \
             "$repo_root/AirPlayEngine/Sources" \
             -type f \( -name '*.swift' -o -name '*.c' -o -name '*.h' \) \
             -exec shasum -a 256 {} + 2>/dev/null
        # The manifests MUST be in the key and are not under any Sources/ dir:
        # they carry the target graph, dependencies and the brew include flags,
        # so a manifest-only edit changes what the suite links and can flip a
        # result with every source file byte-identical.
        shasum -a 256 "$repo_root/AudioutCore/Package.swift" \
                      "$repo_root/AirPlayEngine/Package.swift" 2>/dev/null
    } | awk '{print $1}' | sort | shasum -a 256 | awk '{print $1}'
}

key=$(suite_key)
# The cache records "these exact sources passed", so it must also be keyed on
# the arguments — a `--filter Foo` pass says nothing about the full suite.
args_key=$(printf '%s' "$*" | shasum -a 256 | awk '{print $1}')
stamp="$cache_dir/$key.$args_key"

if [ "${AUDIOUT_TEST_NO_CACHE:-0}" != "1" ] && [ -f "$stamp" ]; then
    echo "  suite: sources unchanged since a passing run — skipping." >&2
    echo "  (AUDIOUT_TEST_NO_CACHE=1 to force)" >&2
    exit 0
fi

# --- prefer-remote ----------------------------------------------------------
# With `audiout.testPrefer = remote`, go to the other Mac FIRST rather than
# only on contention — this keeps THIS machine free unconditionally. With
# `= cpu`, only go first if the other Mac is CURRENTLY less loaded — a straight
# "remote" preference is wrong the moment the remote is the one that's busy
# (another agent testing there, or just awake and doing something else). Local
# slots remain the fallback either way, so an asleep/offline/unmeasurable
# remote costs one 5s probe and behaves exactly as if none were configured.
# `|| true` under `set -e`: "stay local" is a non-zero return from remote_wins,
# and a bare call would abort the whole script instead of falling through.
try_remote_first=0
remote_wins && try_remote_first=1 || true

if [ "$try_remote_first" -eq 1 ] && [ "$remote_tried" -eq 0 ]; then
    remote_tried=1
    # `|| rrc=$?` rather than a bare call: `set -e` would abort the script on any
    # non-zero return, and non-zero is the normal "fall back locally" signal.
    rrc=0
    run_remote "$@" || rrc=$?
    if [ "$rrc" -eq 0 ]; then
        if [ "${AUDIOUT_TEST_NO_CACHE:-0}" != "1" ]; then
            mkdir -p "$cache_dir"
            : > "$stamp"
        fi
        exit 0
    elif [ "$rrc" -eq 1 ]; then
        # 1 = could not use the remote at all. 2 = it ran and failed, and has
        # already said it is re-running locally, so do not print a second reason.
        echo "  suite: falling back to this machine." >&2
    fi
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
if [ "${AUDIOUT_TEST_NO_LOCK:-0}" = "1" ]; then
    echo "  suite: AUDIOUT_TEST_NO_LOCK=1 — not limiting concurrency." >&2
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
        # OVERFLOW: rather than idle in a queue, hand this run to the remote Mac
        # if one is configured and awake. Tried ONCE, on first contention only —
        # re-probing a sleeping host every 5s would add latency to every wait.
        if [ "$announced" -eq 0 ] && [ -n "$remote_host" ] && [ "$remote_tried" -eq 0 ]; then
            remote_tried=1
            # "$@" forwards the caller's own flags (e.g. --filter Foo) into the
            # function; a bare `run_remote` would see the function's empty
            # argument list instead of the script's.
            # `|| rrc=$?` because `set -e` would otherwise abort on the non-zero
            # "fall back locally" signal.
            rrc=0
            run_remote "$@" || rrc=$?
            if [ "$rrc" -eq 0 ]; then
                # A remote PASS is a real pass of these exact sources, so record
                # it — otherwise the very next commit re-runs the whole suite and
                # the cache silently does nothing for every overflowed run.
                if [ "${AUDIOUT_TEST_NO_CACHE:-0}" != "1" ]; then
                    mkdir -p "$cache_dir"
                    : > "$stamp"
                fi
                # Nothing local was started, so there is no slot or trap to unwind.
                exit 0
            fi
            # rrc 1 (unusable) and rrc 2 (ran, failed -> confirm locally) both
            # fall through into the normal local path below.
        fi
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

# --- serial vs parallel -----------------------------------------------------
# MEASURED (1025 tests, same machine, same work):
#
#   --parallel 6   wall 127s   user 358s   sys 51.7s
#   --parallel 2   wall 278s   user 316s   sys 46.6s
#   serial         wall 124s   user  69.7s sys  6.0s
#
# Serial does the identical work for ~1/5 the CPU and ~1/8 the system time.
# `swift test --parallel` parallelises at the test-CLASS level — one fresh OS
# process per class, and this suite has 57 — so each spawn re-execs and re-links
# a large AppKit/CoreAudio/AirPlayEngine binary just to run a handful of tests.
# Real test work is only ~70 CPU-seconds; parallel burns ~290 MORE on fork/exec
# and dyld. That overhead is also why lowering --num-workers barely helps: it
# does not remove the 57 spawns, it just staggers them.
#
# On an IDLE machine parallel is still ~1.8x faster in wall time (~70s vs ~124s
# warm), which is what a human watching the terminal wants. With several agents
# testing at once nobody is watching a clock, and 5x the CPU is precisely what
# makes the machine unusable. So: pick by conditions rather than fixing one.
#
# AUDIOUT_TEST_MODE=auto (default) | parallel | serial
mode=${AUDIOUT_TEST_MODE:-auto}

# Is anything else already testing? Two sources, because the second is the one
# that actually bites: other runner slots, AND bare `swift test` invocations
# that never went through this script at all (an agent typing it by hand is the
# dominant real-world case — observed driving load average past 40).
machine_busy=0
n=1
while [ "$n" -le "$slots" ]; do
    f="${lock_file}.$n"
    if [ "$f" != "$slot_file" ] && [ -f "$f" ]; then
        # Liveness-check the PID: a stale file left by a killed run must not
        # permanently force everyone onto the slow path.
        p=$(cat "$f" 2>/dev/null || echo '')
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then machine_busy=1; fi
    fi
    n=$((n + 1))
done
if pgrep -f 'swift-test|xctest' >/dev/null 2>&1; then machine_busy=1; fi

case "$mode" in
    serial)   test_args="" ;;
    parallel) test_args="--parallel --num-workers $workers" ;;
    *)        if [ "$machine_busy" -eq 1 ]; then test_args=""
              else test_args="--parallel --num-workers $workers"; fi ;;
esac

if [ "$acquired" -eq 1 ]; then
    # State the REASON accurately: an explicitly forced mode was not a decision
    # this script made, and printing "machine idle" next to a mode the caller
    # pinned would be a lie the next reader has to debug.
    if [ "$mode" = "auto" ]; then
        why=$([ "$machine_busy" -eq 1 ] && echo "machine busy" || echo "machine idle")
    else
        why="AUDIOUT_TEST_MODE=$mode"
    fi
    if [ -z "$test_args" ]; then
        echo "  suite: slot $(basename "$slot_file") of $slots — SERIAL ($why; ~1/5 the CPU of parallel)." >&2
    else
        echo "  suite: slot $(basename "$slot_file") of $slots — parallel, $workers workers ($why)." >&2
    fi
fi

# --- run --------------------------------------------------------------------
# `set -e` is off for this one command so a failure reaches the cache logic
# (which must NOT write a stamp) and the trap, rather than exiting immediately.
set +e
# $test_args is deliberately UNQUOTED: it must word-split into flags (or expand
# to nothing at all in serial mode). "$@" stays quoted so caller arguments with
# spaces survive.
# shellcheck disable=SC2086
( cd "$core" && swift test $test_args "$@" ) >&2
status=$?
set -e

if [ "$status" -eq 0 ] && [ "${AUDIOUT_TEST_NO_CACHE:-0}" != "1" ]; then
    mkdir -p "$cache_dir"
    : > "$stamp"
else
    # Say it in our own voice, last. The exit code below is correct and always
    # has been, but a caller who writes `run-tests.sh | tail -15` gets TAIL's
    # exit code — 0, always — and then reads a green status over a red suite.
    # (That is exactly how this script got accused of swallowing failures.) One
    # unmistakable line survives any tail, so the transcript cannot look green.
    [ "$status" -eq 0 ] || echo "  suite: FAILED — swift test exited $status." >&2
fi

exit "$status"
