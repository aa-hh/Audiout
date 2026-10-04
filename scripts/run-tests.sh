#!/bin/sh
# Machine-wide serialised runner for the AudioutCore suite.
#
# WHY THIS EXISTS: every worktree's pre-commit Guard 4 runs the full suite, and
# nothing coordinates across worktrees. With four agents committing at once the
# machine sees 4 full suites compiling and testing at the same time, on 8 cores.
# Measured 15-minute load average during a normal multi-agent session: 73.
#
# Two mechanisms:
#   1. A machine-wide slot cap on concurrent RUNS (/tmp, so it spans every
#      worktree). A run that finds every slot taken queues for one to free.
#   2. A content-addressed pass cache (scripts/lib/suite-cache.sh). Agents
#      routinely run the suite by hand and then commit, which fires Guard 4 on
#      byte-identical sources immediately afterwards. The cache skips whatever
#      an earlier pass already covered: a full pass covers any filter, and a
#      `--filter A` pass covers the A part of a later `--filter A|B`.
#
# Usage:  scripts/run-tests.sh [extra swift-test args...]
#         scripts/run-tests.sh --shard N [extra swift-test args...]
#           one of the GitHub workflow's shards (scripts/lib/suite-shards.sh)
# Env:
#   AUDIOUT_TEST_SHARDS    most processes a full mule run may fan out to;
#                            default 3; 1 = one process as before
#   AUDIOUT_TEST_MODE      serial runs strictly one test at a time
#                            (--no-parallel; for flake hunting, slower).
#                            Anything else or unset runs --parallel.
#   AUDIOUT_TEST_NO_LOCK=1 run immediately, no lock (for a deliberate
#                            foreground run when you know the machine is idle)
#   AUDIOUT_TEST_NO_CACHE=1 always run, never consult or write the cache
#   AUDIOUT_TEST_LOCK_TIMEOUT  seconds to wait for a local permit before
#                            proceeding uncapped (default 600) — an alias for
#                            AUDIOUT_CAPACITY_TIMEOUT, see scripts/lib/remote.sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
# Which package's tests to run. AudioutCore by default -- it is what Guard 4
# and every inner-loop run mean by "the suite". SwiftPM never runs a
# DEPENDENCY package's test targets, so a sibling package's own suite needs
# this override to run at all (mirrors AUDIOUT_BUILD_PACKAGE in
# scripts/build.sh):  AUDIOUT_TEST_PACKAGE=AirPlayEngine scripts/run-tests.sh
# The sync-probe DSP's suite is NOT reachable from here any more: it moved to
# the audiout-shared repo and runs there, against the tag this app pins.
pkg=${AUDIOUT_TEST_PACKAGE:-AudioutCore}
core="$repo_root/$pkg"
# A name that is not a sibling directory fails HERE with the reason, not three
# hundred lines later as a bare `cd` error. ProbeKit is the case people hit:
# its suite moved to the audiout-shared repo and runs there.
if [ ! -d "$core" ]; then
    echo "  suite: no package directory '$pkg' in this repo." >&2
    [ "$pkg" = "ProbeKit" ] && echo "  ProbeKit's tests live in the audiout-shared repo now (~/Projects/audiout-shared)." >&2
    exit 64
fi

# Disk housekeeping (prune .prunable-flagged worktrees, cap .build caches) at
# the moment disk pressure actually appears: a build starting. Best-effort by
# construction — a housekeeping failure must never fail or block a test run.
# Same resolution order as Guard 4 uses for this script: this worktree's own
# copy first, else the copy beside this script (the primary checkout's).
hk="$repo_root/scripts/housekeeping.sh"
[ -x "$hk" ] || hk="$(cd "$(dirname "$0")" && pwd)/housekeeping.sh"
if [ -x "$hk" ]; then "$hk" --current "$repo_root" || true; fi

# The suite compiles with the SwiftPM default engine (swiftbuild). This used to
# pin the old `native` engine because swiftbuild did not forward a C target's
# cSettings unsafeFlags (AirPlayEngine/Package.swift's Homebrew -I paths) into
# the clang module dependency scan, so `import CAirPlayEngine` failed. Fixed as
# of Swift 6.4 — verified 2026-09-04.
#
# Do NOT add an engine flag back here alone. The two engines keep SEPARATE
# .build trees (`out` AND `arm64-apple-macosx`) at ~1.3 GB apiece, so one script
# disagreeing with scripts/build.sh and scripts/make-app.sh doubles every
# worktree's cache. That duplication is what filled this disk once already:
# 10 of 33 worktrees were holding both. housekeeping.sh's stale-cache sweep
# reads this file to decide which tree is live.

# Command Line Tools cannot run `swift test` for ANY package, XCTest or not —
# measured: SwiftPM calls `xcrun --sdk macosx --show-sdk-platform-path` before
# running any test bundle, and that lookup itself fails under CLT ("unable to
# lookup item 'PlatformPath'"). Fail fast here with a clear reason, rather than
# let it surface as a Guard 4 refusal that looks like broken code. The remote
# twin of this check is remote_run's exit-97 gate in scripts/lib/remote.sh.
selected_devdir=$(xcode-select -p 2>/dev/null || echo '')
case "$selected_devdir" in
    /Library/Developer/CommandLineTools*)
        echo "  suite: the selected developer directory is Command Line Tools" >&2
        echo "  ($selected_devdir) — it ships no platform path, so 'swift test'" >&2
        echo "  cannot run any package on macOS, this one included." >&2
        # The glob sorts Xcode-beta.app ahead of Xcode.app ('-' sorts before
        # '.'), so a Mac with both was told to select the beta.
        if [ -d /Applications/Xcode.app ]; then
            xcode_app=/Applications/Xcode.app
        else
            xcode_app=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)
        fi
        if [ -n "$xcode_app" ]; then
            echo "  Fix: sudo xcode-select -s $xcode_app/Contents/Developer" >&2
        else
            echo "  Fix: install Xcode from the App Store or developer.apple.com," >&2
            echo "  then sudo xcode-select -s /Applications/<Xcode>.app/Contents/Developer" >&2
        fi
        exit 78
        ;;
esac

# Alias: AUDIOUT_TEST_LOCK_TIMEOUT is this script's older name for the same
# setting scripts/lib/remote.sh's capacity_acquire reads as AUDIOUT_CAPACITY_TIMEOUT.
[ -n "${AUDIOUT_TEST_LOCK_TIMEOUT:-}" ] && : "${AUDIOUT_CAPACITY_TIMEOUT:=$AUDIOUT_TEST_LOCK_TIMEOUT}"

# How many suite runs may proceed at once, machine-wide. Configurable the same
# way remote_slots is (see lib/remote.sh) — `git config --local
# audiout.localSlots N` takes effect on every worktree's next run with no
# script change needed, which is what makes this a MACHINE setting rather than
# a per-agent one: an agent exporting AUDIOUT_TEST_SLOTS in its own shell only
# affects its own commands, and Guard 4's git hook runs as its own subprocess
# that does not inherit that export.
#
# Lowered 4 -> 3 (owner's call, 2026-08-30): 4 was sized purely for this
# machine's CPU headroom (the suite is WAIT-bound, not CPU-bound — a serial run
# burns only ~0.56 of 8 cores). What it did not account for is that EVERY
# concurrent run, however small — a single `--filter` invocation, not just a
# full-suite Guard 4 run — occupies one full permit the same as any other. On a
# night with several agents each running many small filtered checks, four full
# permits let through more simultaneous test processes than the machine's
# wait-bound-but-still-real scheduler contention could absorb without starving
# the fixed-deadline waits elsewhere in the suite (the roadmap-023 class). Lower
# for stricter, raise for a beefier box or a quieter night.
slots=${AUDIOUT_TEST_SLOTS:-$(git config --get audiout.localSlots 2>/dev/null || echo 3)}

# --- remote machine ---------------------------------------------------------
# Host resolution, the local-vs-remote decision, sync and the run-there wrapper
# all live in scripts/lib/remote.sh, shared with scripts/build.sh and
# scripts/make-app.sh so tests and builds cannot drift apart on where work goes.
# Resolved beside THIS script rather than from $repo_root: Guard 4 runs a
# worktree's hook against the primary checkout's scripts/ when the worktree
# predates them, and the library must travel with the script that sources it.
. "$(cd "$(dirname "$0")" && pwd)/lib/remote.sh"
. "$(cd "$(dirname "$0")" && pwd)/lib/suite-shards.sh"
remote_tried=0

# Thin test-specific wrapper over remote_run. Its own return codes, which are
# remote_run's 0/1/2 plus a third for "the remote's verdict is final":
#   0 = passed remotely
#   1 = could not use the remote at all - run here, no verdict claimed
#   2 = ran and FAILED, but that failure is not a verdict - re-run here
#   3 = ran and FAILED with named failing tests - end the run on that result
run_remote() {
    if [ "$remote_pref" = "remote" ]; then
        echo "  suite: sending to remote $remote_host (preferred) ..." >&2
    elif [ "$remote_pref" = "cpu" ]; then
        echo "  suite: sending to remote $remote_host (lower CPU load) ..." >&2
    else
        echo "  suite: local slots busy — trying remote $remote_host ..." >&2
    fi

    # Mode for the REMOTE run is decided independently of the local machine:
    # the whole reason we are here is that this Mac is busy and that one is not.
    # An explicitly forced AUDIOUT_TEST_MODE is still honoured.
    #
    # `--disable-keychain` is remote-only. Over ssh the mule's login keychain
    # cannot raise an approval dialog (errSecInteractionNotAllowed, -25308), so
    # SwiftPM's credential lookup for github.com fails while it fetches the
    # Sparkle binary artifact and the run exits 1 even though the build
    # finished. Skipping the lookup is safe here: everything this package
    # fetches is public (audiout-shared, Sparkle, posthog-ios; AirPlayEngine is
    # a local path), and the private iOS repo is reached over ssh by a
    # different script.
    case "${AUDIOUT_TEST_MODE:-parallel}" in
        serial) rargs="--disable-keychain --no-parallel" ;;
        *)      rargs="--disable-keychain --parallel" ;;
    esac

    # A full AudioutCore run: build once on the mule, then one `swift test`
    # per free mule permit, split the way the GitHub `tests` workflow splits
    # it (scripts/lib/suite-shards.sh). One process has one main thread and
    # most suites are main-actor UI tests, so a single full process takes
    # about as long as the workflow's shards added together. `--ignore-lock`
    # lets the processes share the one .build tree the build just finished;
    # without it each waits for the one before it.
    k=0
    shards=${AUDIOUT_TEST_SHARDS:-3}
    if [ $# -eq 0 ] && [ "$pkg" = "AudioutCore" ] \
        && [ "${AUDIOUT_TEST_MODE:-parallel}" != "serial" ] && [ "$shards" -ge 2 ]; then
        if [ "$shards" -gt "$suite_shards_max" ]; then shards=$suite_shards_max; fi
        k=$(remote_mule_free_count || echo 0)
        if [ "$k" -gt "$shards" ]; then k=$shards; fi
    fi
    if [ "$k" -ge 2 ]; then
        echo "  suite: full run — building once on $remote_host, then $k test processes." >&2
        rrc=0
        remote_run "$repo_root" "cd $pkg && swift build --build-tests --disable-keychain" || rrc=$?
        if [ "$rrc" -eq 2 ] && [ "${AUDIOUT_TRUST_REMOTE_FAILURE:-0}" = "1" ]; then
            echo "  suite: remote reported FAILURES — trusting it (AUDIOUT_TRUST_REMOTE_FAILURE=1)." >&2
            return 3
        fi
        if [ "$rrc" -eq 2 ]; then
            case "${remote_failure_kind:-}" in
                tests)
                    echo "  suite: remote reported named test FAILURES — trusting that verdict, not re-running here." >&2
                    return 3
                    ;;
                *)
                    echo "  suite: remote failed without a verdict (${remote_failure_kind:-unknown}) — re-running locally to confirm." >&2
                    return 2
                    ;;
            esac
        fi
        [ "$rrc" -ne 0 ] && return 1

        # Each process runs in a background subshell, so remote_run's globals
        # cannot come back from it: its exit code, remote_status and
        # remote_failure_kind go through a file beside its log instead. The
        # runner's pid is in both names, so two sessions' runs never share them.
        suite_log="${AUDIOUT_TEST_LOG:-/tmp/audiout-suite-last.log}"
        shard_base="${suite_log%.log}.$$.shard"
        t0=$(date +%s)
        pids=
        i=1
        while [ "$i" -le "$k" ]; do
            (
                suite_shards_args "$i" "$k"
                remote_status=
                src=0
                remote_run "$repo_root" "cd $pkg && swift test $rargs --skip-build --ignore-lock$(remote_quote_args "$suite_shards_flag" "$suite_shards_regex")" \
                    >"$shard_base$i.log" 2>&1 || src=$?
                echo "$src ${remote_status:-} ${remote_failure_kind:-}" >"$shard_base$i.rc"
            ) &
            pids="$pids $!"
            i=$((i + 1))
        done
        for p in $pids; do wait "$p" || true; done

        # A shard the mule turned away while it was reachable -- no free permit,
        # usually because another session took one during the build -- runs
        # here by itself, after the mule shards, one at a time, with a local
        # permit like any local run. Nothing waits for a mule permit.
        i=1
        while [ "$i" -le "$k" ]; do
            read -r src sst skind <"$shard_base$i.rc"
            if [ "$src" -eq 1 ] && ! grep -q 'remote: unreachable' "$shard_base$i.log"; then
                echo "  suite: shard $i/$k: no mule permit — running it on this machine." >&2
                suite_shards_args "$i" "$k"
                # Serial mode never shards, so a shard always runs --parallel.
                test_args=--parallel
                AUDIOUT_CAPACITY_NO_TRAP=1 capacity_acquire suite
                trap 'capacity_release' EXIT HUP INT TERM
                local_swift_test "$shard_base$i.log" "$suite_shards_flag" "$suite_shards_regex"
                capacity_release
                trap - EXIT HUP INT TERM
                echo "$status $status local" >"$shard_base$i.rc"
            fi
            i=$((i + 1))
        done
        t1=$(date +%s)

        : >"$suite_log"
        i=1
        while [ "$i" -le "$k" ]; do
            echo "=== shard $i/$k ===" >>"$suite_log"
            cat "$shard_base$i.log" >>"$suite_log"
            i=$((i + 1))
        done

        # The summary line arrives with an SF Symbol glyph and colour codes
        # around it; keep only the words from "Test run with" on.
        esc=$(printf '\033')
        tot_n=0
        tot_m=0
        failed=0
        passed=
        verdict=
        noverdict=
        i=1
        while [ "$i" -le "$k" ]; do
            read -r src sst skind <"$shard_base$i.rc"
            slog="$shard_base$i.log"
            line=$(sed "s/$esc\[[0-9;]*m//g" "$slog" | grep 'Test run with ' | tail -1 \
                | sed 's/.*Test run with /Test run with /' || true)
            nm=$(printf '%s\n' "$line" \
                | sed -n 's/^Test run with \([0-9]*\) tests* in \([0-9]*\) suites* passed.*/\1 \2/p')
            why=
            if [ "$src" -eq 0 ] && [ -z "$nm" ]; then
                # Exit 0 without a summary line is no verdict, not a pass.
                src=2
                sst=1
                skind=noverdict
                why="exit 0 with no \"Test run with\" line in its output"
            fi
            nm=${nm:-0 0}
            if [ "$src" -eq 0 ]; then
                echo "  suite: shard $i/$k: $line" >&2
                tot_n=$((tot_n + ${nm% *}))
                tot_m=$((tot_m + ${nm#* }))
                if [ "$i" -lt "$k" ]; then passed="$passed $i"; fi
            else
                failed=1
                if [ "$skind" = local ]; then
                    why="ran on this machine, swift test exited $src"
                    # Named the same way as the unsharded local run below.
                    lfailed=$(tr -d '\r' < "$slog" | grep ' Test ' | grep ' failed after ' \
                        | sed -e 's/.* Test //' -e 's/ failed after .*//' | grep -v '^run with ' || true)
                    nlfailed=$(printf '%s' "$lfailed" | grep -c . || true)
                    if [ "$nlfailed" -gt 0 ]; then
                        why="$why — $nlfailed test(s) failed: $(printf '%s' "$lfailed" | tr '\n' ' ')"
                    fi
                elif [ "$src" -eq 1 ]; then
                    why="could not run on the remote"
                elif [ -z "$why" ]; then
                    why=$(grep '  remote: ran and FAILED there — ' "$slog" | tail -1 | sed 's/^ *//' || true)
                fi
                echo "  suite: shard $i/$k FAILED — $why" >&2
                # A local shard's failure is this machine's own verdict, the
                # same as an unsharded local run's.
                if [ -z "$verdict" ] && { [ "$skind" = tests ] || [ "$skind" = local ] \
                    || { [ "${AUDIOUT_TRUST_REMOTE_FAILURE:-0}" = "1" ] && [ "$src" -eq 2 ]; }; }; then
                    verdict=$i
                    remote_status=$sst
                    # Tells the caller this verdict came from this Mac.
                    if [ "$skind" = local ]; then verdict_local=1; fi
                fi
                if [ -z "$noverdict" ]; then noverdict=$i; fi
            fi
            i=$((i + 1))
        done
        rm -f "$shard_base"*.log "$shard_base"*.rc

        if [ "$failed" -eq 0 ]; then
            tw=tests
            sw=suites
            if [ "$tot_n" -eq 1 ]; then tw=test; fi
            if [ "$tot_m" -eq 1 ]; then sw=suite; fi
            echo "  suite: Test run with $tot_n $tw in $tot_m $sw passed after $((t1 - t0)) seconds — $k shards on $remote_host." >&2
            return 0
        fi

        # A listed shard that passed keeps its suites green for later filtered
        # runs. The last shard has no name list, so it stamps nothing.
        for i in $passed; do
            # shellcheck disable=SC2046
            suite_cache_record "$key" --filter "$(printf '%s\n' $(suite_shards_names "$i") | paste -sd '|' -)"
        done
        if [ -n "$verdict" ]; then
            echo "  suite: full output in $suite_log — grep 'recorded an issue' for the assertion." >&2
            return 3
        fi
        echo "  suite: shard $noverdict/$k gave no verdict — re-running the full suite on this machine." >&2
        return 2
    fi

    # The remote command is a STRING the far shell re-parses, so caller flags
    # must be quoted INTO it: an unquoted `--filter "A|B"` arrived there as a
    # pipe into a command named `B`. See remote_quote_args in lib/remote.sh.
    qargs=$(remote_quote_args "$@")

    rrc=0
    remote_run "$repo_root" "cd $pkg && swift test $rargs$qargs" || rrc=$?
    if [ "$rrc" -eq 2 ] && [ "${AUDIOUT_TRUST_REMOTE_FAILURE:-0}" = "1" ]; then
        # Opt-out for an EXPLORATORY run: the caller is gating nothing, so the
        # false-refusal risk the re-run protects against does not apply, and
        # confirming locally would just build the same tree a second time.
        # Never set this in a hook, or in anything a commit blocks on.
        echo "  suite: remote reported FAILURES — trusting it (AUDIOUT_TRUST_REMOTE_FAILURE=1)." >&2
        return 3
    fi
    if [ "$rrc" -eq 2 ]; then
        # Which of the three failures it was decides whether it is a verdict.
        # Named failing tests are: the toolchains match (re-checked 2026-09-20),
        # so the same sources fail the same way here and there is nothing to
        # confirm. The other two say more about the machine than about the code
        # — the mule has been out of disk and starved before, and a test process
        # that died mid-run produced no verdict at all — so they still get
        # re-run here rather than being allowed to refuse a commit through
        # Guard 4. Empty means the classifier never ran: treat it as untrusted.
        case "${remote_failure_kind:-}" in
            tests)
                echo "  suite: remote reported named test FAILURES — trusting that verdict, not re-running here." >&2
                return 3
                ;;
            *)
                echo "  suite: remote failed without a verdict (${remote_failure_kind:-unknown}) — re-running locally to confirm." >&2
                return 2
                ;;
        esac
    fi
    [ "$rrc" -ne 0 ] && return 1
    echo "  suite: passed on remote $remote_host." >&2
    return 0
}

# local_swift_test <log> [swift-test args...]
# Run `swift test $test_args <args>` here, its output also written to <log>,
# and set status to swift's exit code. The unsharded local run below and a
# shard the mule turned away (run_remote) both go through this.
local_swift_test() {
    _lt_log=$1
    shift
    # --- cold checkouts: resolve solo first --------------------------------------
    # A run that has to MATERIALISE .build/checkouts while another SwiftPM process
    # races it over the shared package cache is what produced the "unable to read
    # tree" Sparkle failures during the merge guards. Doing the checkout step on its
    # own first removes the race; a warm checkout skips this entirely. Best-effort:
    # a resolve failure is left for `swift test` below to report properly.
    if [ ! -d "$core/.build/checkouts" ] || [ -z "$(ls -A "$core/.build/checkouts" 2>/dev/null)" ]; then
        echo "  suite: cold package checkouts — resolving first, on its own." >&2
        ( cd "$core" && swift package resolve ) >&2 || true
    fi

    # Clear any compiler left orphaned by a killed wrapper before competing for
    # the lock -- see scripts/reap-orphaned-swift.sh for why this is not paranoia.
    bash "$(dirname "$0")/reap-orphaned-swift.sh" || true

    # `set -e` is off for this one command so a failure reaches the cache logic
    # (which must NOT write a stamp) and the trap, rather than exiting immediately.
    set +e
    # $test_args is deliberately UNQUOTED: it must reach swift test as a flag
    # (`--parallel` or `--no-parallel`) rather than as one quoted word. "$@" stays
    # quoted so caller arguments with spaces survive.
    # shellcheck disable=SC2086
    #
    # Backgrounded under `set -m` so the subshell becomes its own PROCESS GROUP,
    # then killed as a group if this wrapper dies. Without that, a timeout or a
    # Ctrl-C leaves the compiler running, holding SwiftPM's per-`.build` lock, and
    # every later build queues behind it silently -- the failure looks like a slow
    # build and cost hours on 2026-09-04. `wait` still yields the real exit status.
    set -m
    # Output also lands in $1 so a failure can be NAMED after the fact.
    # The commit guard's 4001-test merge run on 2026-10-04 reported "1 issue" and
    # nothing else, which cost a second 5-minute full run just to learn which test.
    # `pipefail` inside the subshell makes its exit status swift's, not tee's.
    ( set -o pipefail; cd "$core" && swift test $test_args "$@" 2>&1 | tee "$_lt_log" >&2 ) &
    swift_pgid=$!
    # `|| true`: by the time this trap fires the group is usually already reaped
    # by the `wait` below, so kill fails with "no such process" -- and under
    # `set -e` a failing trap command aborts the rest of the trap (skipping the
    # release) and overrides the exit code, turning a pass into a false failure.
    # Same fix as PR #165; carried here because this line changed too.
    trap 'kill -- -"$swift_pgid" 2>/dev/null || true; capacity_release' EXIT HUP INT TERM
    wait "$swift_pgid"
    status=$?
    set +m
    set -e
}

# The pass cache (source hash, stamps, which earlier passes cover this run)
# lives in scripts/lib/suite-cache.sh, resolved beside this script for the same
# reason remote.sh is above.
. "$(cd "$(dirname "$0")" && pwd)/lib/suite-cache.sh"
key=$(suite_cache_source_hash "$repo_root" "$pkg")

# `--shard N` becomes that shard's own --filter or --skip, ahead of the cache
# lookup, so the cache and swift both see the real arguments.
if [ "${1:-}" = "--shard" ]; then
    case "${2:-}" in
        ''|*[!0-9]*) n=0 ;;
        *) n=$2 ;;
    esac
    if [ "$n" -lt 1 ] || [ "$n" -gt "$suite_shards_max" ]; then
        echo "  suite: --shard takes a number from 1 to $suite_shards_max." >&2
        exit 64
    fi
    shift 2
    suite_shards_args "$n" "$suite_shards_max"
    set -- "$suite_shards_flag" "$suite_shards_regex" "$@"
fi

if suite_cache_satisfied "$key" "$@"; then
    echo "  suite: sources unchanged since a passing run — skipping." >&2
    echo "  (AUDIOUT_TEST_NO_CACHE=1 to force)" >&2
    exit 0
fi
# A plain-name filter where some names already passed on these sources runs
# only the rest. This is what lets Guard 4's `--filter A|B|C` at commit reuse an
# earlier hand-run `--filter A`.
if [ "$suite_cache_kind" = "suites" ] && [ "$suite_cache_missing" != "$suite_cache_names" ]; then
    skipped=
    for n in $suite_cache_names; do
        case " $suite_cache_missing " in *" $n "*) ;; *) skipped="$skipped $n" ;; esac
    done
    echo "  suite: already passed on these sources, skipping:$skipped" >&2
    set -- --filter "$(printf '%s' "$suite_cache_missing" | tr ' ' '|')"
    echo "  suite: running $*" >&2
fi

# --- prefer-remote ----------------------------------------------------------
# With `audiout.testPrefer = permits` (the setting since 2026-09-11), go to
# the other Mac FIRST only when it has at least as many free capacity permits
# as this one — see remote_permits_win. `= remote` goes there first
# unconditionally, which keeps THIS machine free but piles every job onto the
# mule while the local permits idle; `= cpu` compares load average, which
# misreports this wait-bound suite. Local slots remain the fallback in every
# mode, so an asleep/offline/unmeasurable remote costs one 5s probe and
# behaves exactly as if none were configured.
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
        suite_cache_record "$key" "$@"
        exit 0
    elif [ "$rrc" -eq 3 ]; then
        # The remote's verdict is final. No pass stamp, no local re-run, and
        # nothing local has been acquired yet, so there is no permit to unwind.
        if [ "${verdict_local:-0}" = "1" ]; then
            echo "  suite: FAILED on this machine." >&2
        else
            echo "  suite: FAILED on remote $remote_host — not re-run here." >&2
        fi
        exit "${remote_status:-1}"
    elif [ "$rrc" -eq 1 ]; then
        # 1 = could not use the remote at all. 2 = it ran and failed, and has
        # already said it is re-running locally, so do not print a second reason.
        echo "  suite: falling back to this machine." >&2
    fi
fi

# --- lock -------------------------------------------------------------------
# The local permit semaphore (shlock-based counting cap, sweep of stale
# holders, degrade-to-uncapped past the ceiling) now lives in capacity_acquire
# (scripts/lib/remote.sh), shared with build.sh, make-app.sh and ios.sh so
# "N jobs at once" describes the whole machine, not just this script's own
# runs. See capacity_acquire's own comment for why a COUNTING semaphore, not
# one exclusive lock, is the right shape — this file just used to carry that
# reasoning inline.
if [ "${AUDIOUT_TEST_NO_LOCK:-0}" != "1" ] && [ "$remote_tried" -eq 0 ]; then
    # OVERFLOW: on first local contention, hand this run to the remote Mac once
    # before joining capacity_acquire's wait — re-probing a sleeping host on
    # every tick would add latency to every wait later. Non-blocking probe:
    # sweep stale permits, then check whether every slot file still names a
    # live holder (existence is enough — capacity_sweep already removed any
    # dead one, so a survivor is a real occupant, not a race to actually take).
    capacity_sweep
    busy=1
    n=1
    while [ "$n" -le "$slots" ]; do
        [ -f "$(capacity_lock_base).$n" ] || { busy=0; break; }
        n=$((n + 1))
    done
    if [ "$busy" -eq 1 ] && [ -n "$remote_host" ]; then
        remote_tried=1
        # `|| rrc=$?` because `set -e` would otherwise abort on the non-zero
        # "fall back locally" signal.
        rrc=0
        run_remote "$@" || rrc=$?
        if [ "$rrc" -eq 0 ]; then
            # A remote PASS is a real pass of these exact sources, so record
            # it — otherwise the very next commit re-runs the whole suite and
            # the cache silently does nothing for every overflowed run.
            suite_cache_record "$key" "$@"
            # Nothing local was started, so there is no permit to unwind.
            exit 0
        fi
        if [ "$rrc" -eq 3 ]; then
            # Same final verdict as the prefer-remote path above. This site is
            # reached whenever the local slots were busy, and missing it would
            # leave every overflowed run still building the tree twice.
            if [ "${verdict_local:-0}" = "1" ]; then
                echo "  suite: FAILED on this machine." >&2
            else
                echo "  suite: FAILED on remote $remote_host — not re-run here." >&2
            fi
            exit "${remote_status:-1}"
        fi
        echo "  suite: all $slots test slots busy — waiting for one to free." >&2
    fi
fi

# AUDIOUT_CAPACITY_NO_TRAP=1: this script re-traps around the compiler process
# group below, and letting capacity_acquire install its own trap here would
# get silently clobbered by that later one — install ours instead, right away,
# so an interrupt during the cold-checkout/reap steps below still releases.
AUDIOUT_CAPACITY_NO_TRAP=1 capacity_acquire suite
acquired=0
[ -n "$capacity_slot_file" ] && acquired=1
trap 'capacity_release' EXIT HUP INT TERM

# --- serial vs parallel -----------------------------------------------------
# Swift Testing runs tests concurrently inside one process whether or not
# `--parallel` is passed (measured: 57 in flight with no flag). `--parallel` is
# passed because SwiftPM accepts it for both frameworks, and no worker count
# goes with it: a worker count only fans out XCTest's one-process-per-class
# model, and one process has nothing to fan out. `AUDIOUT_TEST_MODE=serial`
# passes `--no-parallel`, which does serialise (measured: 1 in flight) and
# exists for flake hunting.
mode=${AUDIOUT_TEST_MODE:-parallel}

case "$mode" in
    serial) test_args="--no-parallel" ;;
    *)      test_args="--parallel" ;;
esac

if [ "$acquired" -eq 1 ]; then
    echo "  suite: $test_args." >&2
fi

# --- run --------------------------------------------------------------------
suite_log="${AUDIOUT_TEST_LOG:-/tmp/audiout-suite-last.log}"
local_swift_test "$suite_log" "$@"

if [ "$status" -eq 0 ]; then
    suite_cache_record "$key" "$@"
else
    # Say it in our own voice, last. The exit code below is correct and always
    # has been, but a caller who writes `run-tests.sh | tail -15` gets TAIL's
    # exit code — 0, always — and then reads a green status over a red suite.
    # (That is exactly how this script got accused of swallowing failures.) One
    # unmistakable line survives any tail, so the transcript cannot look green.
    echo "  suite: FAILED — swift test exited $status." >&2
    # Same classification as remote_run's: name the failed tests from the log,
    # stripping the SF Symbol glyphs and colour codes around each line.
    failed=$(tr -d '\r' < "$suite_log" | grep ' Test ' | grep ' failed after ' \
        | sed -e 's/.* Test //' -e 's/ failed after .*//' | grep -v '^run with ' || true)
    nfailed=$(printf '%s' "$failed" | grep -c . || true)
    if [ "$nfailed" -gt 0 ]; then
        echo "  suite: $nfailed test(s) failed: $(printf '%s' "$failed" | tr '\n' ' ')" >&2
    fi
    echo "  suite: full output in $suite_log — grep 'recorded an issue' for the assertion." >&2
fi

exit "$status"
