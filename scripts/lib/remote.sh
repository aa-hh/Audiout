#!/bin/sh
# Shared "should this work go to the other Mac, and can it?" logic.
#
# SOURCED, never executed. Callers: scripts/run-tests.sh, scripts/build.sh,
# scripts/make-app.sh.
#
# WHY A SHARED FILE: all three callers need the same answer to the same
# question, and every expensive mistake in that answer is identical in each of
# them — a sleeping host that must fail fast rather than stall, a toolchain skew
# that must never present as "your code is broken", a remote path with a space
# in it that rsync parses itself. Three copies of this would drift, and the
# drift would show up as one script mysteriously never using the remote.
#
# ONE setting governs tests and builds alike. That is deliberate: "prefer the
# other Mac" is a fact about the machines, not about the kind of work, so a
# second AUDIOUT_BUILD_* family of variables would just be a way for the two
# to disagree. The names keep their AUDIOUT_TEST_ prefix for compatibility
# with what is already configured and documented.
#
# Config (git config, NOT a committed file or a shell export — see the
# audiout.remoteHost note in AudioutCore/AGENTS.md for why):
#   git config --local audiout.remoteHost 'user@host.local'
#   git config --local audiout.testPrefer cpu     # local (default) | remote | cpu
#   git config --local audiout.testRemoteBias 40  # cpu mode only

remote_host=${AUDIOUT_TEST_REMOTE_HOST:-$(git config --get audiout.remoteHost 2>/dev/null || true)}
remote_pref=${AUDIOUT_TEST_PREFER:-$(git config --get audiout.testPrefer 2>/dev/null || echo local)}
# How many load-per-core percentage points busier the remote may be and still
# win the "cpu" comparison. The two machines are NOT interchangeable: this one
# also carries the agents, the editor and any app under live test, so its spare
# capacity is worth more. 0 = strict lower-load-wins.
remote_bias=${AUDIOUT_TEST_REMOTE_BIAS:-$(git config --get audiout.testRemoteBias 2>/dev/null || echo 40)}
# Deliberately RELATIVE to the remote home directory — no leading `~`. A tilde
# survives neither quoting on the remote `cd` (it is not expanded inside quotes,
# so `cd '~/foo'` fails) nor safe quoting of paths containing spaces. ssh starts
# in $HOME, so a relative path is both simpler and correct.
remote_root=${AUDIOUT_TEST_REMOTE_ROOT:-audiout-remote-tests}
# The binary whose presence proves the remote can do this KIND of work. SwiftPM
# callers want `swift`; the iOS target is built by `xcodebuild`, which can sit on
# a machine with no Swift on PATH and vice versa. A caller sets this before
# remote_run; a wrong answer takes the sentinel-97 path below and becomes "stay
# local" rather than a failed build.
remote_toolchain=${remote_toolchain:-swift}
# Short ON PURPOSE. The known failure mode of this particular machine is
# sleeping: it answers ping (sleep proxy) but refuses TCP, so a generous timeout
# would stall every run behind a host that is never going to answer.
remote_probe_timeout=${AUDIOUT_TEST_REMOTE_TIMEOUT:-5}

# How many jobs may run ON THE REMOTE at once. The local machine has had a slot
# cap for a long time; the remote had NONE, and that asymmetry is what actually
# overloaded it: with `testPrefer = remote` every agent shipped its suite there
# unconditionally, and the remote attempt happens BEFORE the local semaphore is
# taken, so a remote run touched no cap at all. Observed: three suites at once
# on a 8-core mule.
#
# A COUNT, deliberately, not a load-average check. Load average is a lie for
# this workload -- the suite is wait-bound, so it parks threads on timers and
# reports a load of 20+ while the CPU sits near 25%. Anything that gates on
# load either throttles an idle machine or waves through a busy one. A permit
# count measures the thing we actually care about: how many jobs are resident.
remote_slots=${AUDIOUT_TEST_REMOTE_SLOTS:-$(git config --get audiout.remoteSlots 2>/dev/null || echo 2)}

# Free-space floor on the remote, in MB. Under this, remote_prune_stale starts
# evicting least-recently-used trees. 20 GB covers the concurrent slots' build
# caches (~1.6 GB per tree) with room for whatever else that Mac is doing.
remote_free_floor=${AUDIOUT_TEST_REMOTE_FREE_MB:-$(git config --get audiout.remoteFreeMB 2>/dev/null || echo 20000)}

remote_configured() { [ -n "$remote_host" ]; }

remote_reachable() {
    ssh -o BatchMode=yes -o ConnectTimeout="$remote_probe_timeout" \
        -o StrictHostKeyChecking=accept-new "$remote_host" true >/dev/null 2>&1
}

# Load average alone isn't comparable across two machines with different core
# counts, so normalise to "load per core, as a percent" on each side before
# comparing. Values over 100 mean that machine is oversubscribed.
remote_local_load_pct() {
    ncpu=$(sysctl -n hw.ncpu)
    set -- $(sysctl -n vm.loadavg | tr -d '{}')
    awk -v l="$1" -v n="$ncpu" 'BEGIN { printf "%d", (l / n) * 100 }'
}

# Empty output means unreachable — the caller treats "couldn't check" the same
# as "don't prefer it".
remote_remote_load_pct() {
    ssh -o BatchMode=yes -o ConnectTimeout="$remote_probe_timeout" \
        -o StrictHostKeyChecking=accept-new "$remote_host" \
        "n=\$(sysctl -n hw.ncpu); set -- \$(sysctl -n vm.loadavg | tr -d '{}'); awk -v l=\"\$1\" -v n=\"\$n\" 'BEGIN{printf \"%d\", (l/n)*100}'" 2>/dev/null
}

# Returns 0 when the work should be offered to the remote BEFORE trying locally.
# Never fails the caller: an unconfigured, asleep or unmeasurable remote simply
# returns 1 and everything proceeds locally.
remote_wins() {
    remote_configured || return 1
    [ "$remote_pref" = "remote" ] && return 0
    [ "$remote_pref" = "cpu" ] || return 1
    # `|| true` matters under `set -e`: an unreachable host makes ssh exit
    # non-zero, and a bare command substitution would propagate that straight
    # out of the calling script — killing the run with no output at all instead
    # of falling back locally.
    _rl=$(remote_remote_load_pct || true)
    [ -n "$_rl" ] || return 1
    _ll=$(remote_local_load_pct)
    echo "  remote: cpu check — local ${_ll}%/core, remote ${_rl}%/core (remote allowed +${remote_bias})." >&2
    [ "$_rl" -lt "$((_ll + remote_bias))" ]
}

# Print the remote-side directory this repo root maps to. Every worktree gets
# its own, keyed on basename, so two branches never overwrite each other's tree.
remote_dir_for() { printf '%s/%s' "$remote_root" "$(basename "$1")"; }

# rsync the working tree (sources only) to the remote. Returns non-zero on any
# failure so the caller can fall back locally.
remote_sync() {
    _root=$1
    _rdir=$(remote_dir_for "$_root")
    # rsync parses "host:path" ITSELF, before any shell (local or remote) gets
    # involved — normal shell quoting around the whole argument does not protect
    # spaces inside the path portion. The primary checkout's own directory is
    # "AirPlay Controller" (a space in its basename), so the path needs its
    # spaces escaped for rsync's remote-path parser specifically, not just
    # quoted for this local shell. Confirmed broken without this: rsync errors
    # "server receiver mode requires two argument" and the whole remote path
    # silently fell back to local for every run from the main checkout.
    _esc=$(printf '%s' "$_rdir" | sed 's/ /\\ /g')
    # Source only: .build is per-machine (absolute paths baked in) and .git is
    # not needed to compile. Tracked sources are ~20MB/445 files, so after the
    # first sync this ships only the handful of files an agent actually edited.
    rsync -az --delete --timeout=30 \
          --exclude '.build/' --exclude '.git/' --exclude '.claude/' \
          "$_root/" "$remote_host:$_esc/" >/dev/null 2>&1
}

# Kill remote runs whose local caller is gone. A caller killed mid-run (crashed
# session, cancelled agent) used to leave its remote command alive: without a
# tty, sshd sends the remote side nothing when the connection dies, so the
# orphan kept the package build lock and every later run queued behind it at 0%
# CPU — observed twice, 40+ minutes each. The `-tt` on remote_run's ssh is the
# real fix (connection death now hangs up the remote); this sweep catches runs
# started before that fix, and the sleep/crash case where the socket never
# closes. Orphan = parented to PID 1 AND working under $remote_root — never a
# run whose ssh leg is still alive, so concurrent live sessions are untouched.
remote_sweep_orphans() {
    ssh -o BatchMode=yes "$remote_host" \
        "ps -axo pid=,ppid=,pgid=,command= | \
         awk -v root=\"$remote_root\" '\$2 == 1 && index(\$0, root) { print \$3 }' | \
         sort -u | while read -r _g; do kill -TERM -- \"-\$_g\" 2>/dev/null; done" \
        2>/dev/null || true
}

# Delete remote trees to keep the disk usable. Two rules, applied in order:
#   1. AGE  — a tree unused for 24h+ goes, unconditionally.
#   2. SPACE — while free space is under the floor, evict the least recently
#      used tree, until it clears or nothing is left to take.
#
# Rule 1 was 7 days and bounded nothing -- twice that took the remote down.
# `.last-used` is re-stamped every run, so with a fleet of agents cycling
# branches no tree ever reached 7 days and the rule never fired once. 24h is
# short enough to actually bite. NOTE the BSD find quirk: `-mtime +1` means
# older than TWO days (the fraction is truncated), so "older than 24h" is
# `-mtime +0` -- the same predicate rule 2 uses to protect a live run.
# Cost of cutting it this fine: returning to a worktree after a day pays one
# re-sync plus one cold build, a few minutes.
# Each tree carries a ~1.6 GB .build cache, and `.last-used` is re-stamped on
# every run -- so a fleet of agents cycling through branches keeps 60+ trees
# permanently "fresh". First 79 dead trees / 93 GB (Aug 2026), then 62 LIVE
# trees / 101 GB (Aug 29) took the disk to 113 MB free: swift failed with
# `error: other(28)` (ENOSPC), rsync with an I/O error, and every suite fell
# back to local -- the exact silent-fallback failure this file exists to
# prevent. Age says nothing about how much room is left; the floor does.
#
# Recency = the .last-used stamp remote_run touches (top-dir mtime for trees
# predating the stamp). Best-effort throughout: a tree pruned wrongly costs one
# re-sync (~seconds) plus one cold build.
remote_prune_stale() {
    ssh -o BatchMode=yes "$remote_host" \
        "cd \"$remote_root\" 2>/dev/null || exit 0; \
         for d in */; do d=\${d%/}; s=\"\$d/.last-used\"; [ -f \"\$s\" ] || s=\"\$d\"; \
             [ -n \"\$(find \"\$s\" -maxdepth 0 -mtime +0 2>/dev/null)\" ] && rm -rf \"\$d\"; \
         done; \
         while [ \"\$(df -m . | awk 'NR==2{print \$4}')\" -lt $remote_free_floor ]; do \
             _v=\$(for d in */; do d=\${d%/}; s=\"\$d/.last-used\"; [ -f \"\$s\" ] || s=\"\$d\"; \
                     [ -n \"\$(find \"\$s\" -maxdepth 0 -mtime +0 2>/dev/null)\" ] && \
                         echo \"\$(date -r \"\$s\" +%s) \$d\"; \
                   done | sort -n | head -1 | cut -d' ' -f2-); \
             [ -n \"\$_v\" ] || break; \
             rm -rf \"\$_v\"; \
         done; true" \
        2>/dev/null || true
}

# Run a command in the synced tree on the remote.
#   remote_run <repo_root> <shell command string>
# Sets $remote_status to the command's own exit code when it ACTUALLY RAN.
#
# Return codes, and why the distinction is the whole point of this function:
#   0  ran remotely and succeeded
#   1  could not use the remote at all (unreachable / sync failed / no toolchain
#      / connection dropped) — infrastructure, NOT a verdict on the caller's code
#   2  ran remotely and FAILED
#
# A remote that cannot be reached, synced or set up must NEVER surface as "your
# code is broken". Both Macs run Swift 6.4 but against different SDKs (macOS 27
# here, macOS 26 there), and the remote has been out of disk and starved
# before, so callers accept a remote PASS but re-confirm a
# remote FAILURE locally before letting it block anything. The asymmetry is
# deliberate: the expensive error is a false refusal, not a false pass.
remote_run() {
    _root=$1
    shift
    _rdir=$(remote_dir_for "$_root")
    if ! remote_reachable; then
        echo "  remote: unreachable (asleep or offline) — staying local." >&2
        return 1
    fi
    # Housekeeping runs BEFORE the sync, not after. A full disk is precisely
    # what makes rsync fail, so a pruner reachable only via a SUCCESSFUL sync
    # can never clear the condition blocking it -- the self-healing step sits
    # on the wrong side of the failure it is meant to heal.
    remote_prune_stale
    if ! remote_sync "$_root"; then
        echo "  remote: rsync failed (disk full?) — staying local." >&2
        return 1
    fi
    remote_sweep_orphans
    # PATH is set explicitly: a non-interactive ssh shell often lacks
    # /opt/homebrew/bin, and Package.swift shells out to `brew --prefix` to find
    # the keg-only C dependencies.
    # Exit 97 is a private sentinel for "the remote ENVIRONMENT is wrong"
    # (directory missing, no toolchain) as opposed to "the work failed". Without it,
    # a broken remote reports as a failure of the caller's code — exactly the
    # confusion this function exists to prevent.
    # Two probes guard it, because one is not enough: /usr/bin/swift exists
    # under Command Line Tools, so `command -v` cannot see a CLT-selected
    # remote. `xcrun --show-sdk-platform-path` is what SwiftPM calls before
    # running any test bundle, and it fails under CLT — the remote twin of
    # run-tests.sh's exit-78 check.
    # The mule permit loop is preceded by the same stale sweep capacity_sweep
    # does locally: shlock reclaims a permit whose PID is dead, but not one held
    # by a hung job or by a recycled PID, and either shrinks that pool until
    # someone notices. Exit 98 stays immediate — when the mule is genuinely full
    # the work comes straight back here (no mule wait, owner's call, 2026-09-10).
    # -tt allocates a tty on the mule. It does NOT hang the remote job up when
    # the local side dies, which is what this comment used to claim. Measured
    # on this pair of Macs 2026-09-11: SIGKILL of the local ssh client, and
    # SIGTERM of it, both left the remote wrapper running — reparented to pid 1,
    # its own EXIT/HUP/INT/TERM trap never firing, still holding the permit file
    # and SwiftPM's build lock. What ends an orphaned run is the pair of
    # watchers below: a local one that kills this ssh as soon as the runner
    # process is gone, and a remote one that sees its own parent become pid 1
    # and kills the job's process group. The tty's price is CRLF line endings,
    # stripped right below before anything parses $_out.
    # SDKROOT is pinned to the selected Xcode's macOS SDK before the toolchain
    # probe. Found 2026-09-10: the mule runs macOS 26.5 with only the Xcode 27
    # beta installed, and with no SDK matching the OS version a bare `xcrun`
    # falls back to the Command Line Tools SDK, which is broken there — every
    # run took the exit-97 path and every "mule" job silently ran on this Mac.
    # An explicit `--sdk macosx` resolves correctly; exporting its answer makes
    # the probe and the compile agree. If the lookup fails SDKROOT stays empty
    # and the probe below reports it as it always did.
    # $$ inside remote_run is the RUNNER's pid: this file is sourced, never run.
    _rr_pid=$$
    _rr_out=$(mktemp -t audiout-remote-out)
    ssh -tt -o BatchMode=yes -o LogLevel=QUIET \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        "$remote_host" \
        "export PATH=/opt/homebrew/bin:\$PATH; \
         export SDKROOT=\$(xcrun --sdk macosx --show-sdk-path 2>/dev/null); \
         cd \"$_rdir\" || exit 97; \
         touch .last-used; \
         command -v $remote_toolchain >/dev/null 2>&1 || exit 97; \
         xcrun --show-sdk-platform-path >/dev/null 2>&1 || exit 97; \
         _n=1; \
         while [ \$_n -le $remote_slots ]; do \
             _f=/tmp/audiout-remote-work.lock.\$_n; \
             if [ -f \"\$_f\" ]; then \
                 _p=\$(cat \"\$_f\" 2>/dev/null | tr -d ' '); \
                 if [ -n \"\$_p\" ] && kill -0 \"\$_p\" 2>/dev/null; then \
                     _c=\$(ps -o command= -p \"\$_p\" 2>/dev/null); \
                     _a=\$(( \$(date +%s) - \$(stat -f %m \"\$_f\" 2>/dev/null || date +%s) )); \
                     _pp=\$(ps -o ppid= -p \"\$_p\" 2>/dev/null | tr -d ' '); \
                     if [ \"\$_pp\" = 1 ]; then \
                         _g=\$(ps -o pgid= -p \"\$_p\" 2>/dev/null | tr -d ' '); \
                         [ -n \"\$_g\" ] && kill -KILL -- \"-\$_g\" 2>/dev/null; \
                         rm -f \"\$_f\"; \
                         echo \"  remote: reclaimed mule permit \$_n held by pid \$_p (its ssh session is gone; killed its process group)\" >&2; \
                     else \
                         case \"\$_c\" in \
                             *run-tests.sh*|*build.sh*|*make-app.sh*|*ios.sh*|*run-app.sh*|*pre-commit*|*swift*|*xcodebuild*|*xctest*) \
                                 if [ \$_a -gt 2700 ]; then rm -f \"\$_f\"; \
                                     echo \"  remote: reclaimed mule permit \$_n held by pid \$_p (held \${_a}s > ceiling)\" >&2; fi;; \
                             *) rm -f \"\$_f\"; \
                                 echo \"  remote: reclaimed mule permit \$_n held by pid \$_p (not a recognised job)\" >&2;; \
                         esac; \
                     fi; \
                 fi; \
             fi; \
             _n=\$((_n + 1)); \
         done; \
         _s=''; _n=1; \
         while [ \$_n -le $remote_slots ]; do \
             if /usr/bin/shlock -f /tmp/audiout-remote-work.lock.\$_n -p \$\$; then \
                 _s=/tmp/audiout-remote-work.lock.\$_n; break; \
             fi; \
             _n=\$((_n + 1)); \
         done; \
         [ -n \"\$_s\" ] || exit 98; \
         _me=\$\$; _pg=\$(ps -o pgid= -p \$\$ 2>/dev/null | tr -d ' '); \
         ( while :; do sleep 5; \
               case \"\$(ps -o ppid= -p \$_me 2>/dev/null | tr -d ' ')\" in \
                   '') exit 0;; \
                   1) rm -f \"\$_s\"; kill -KILL -- \"-\$_pg\" 2>/dev/null; exit 0;; \
               esac; \
           done ) & \
         _w=\$!; \
         trap 'rm -f \"\$_s\"; kill \$_w 2>/dev/null' EXIT HUP INT TERM; \
         $* ; echo \"REMOTE_EXIT:\$?\"" >"$_rr_out" 2>&1 </dev/null &
    _rr_ssh=$!
    # macOS has no parent-death signal, so poll for one. A trap cannot cover
    # this: the runner is often SIGKILLed (a torn-down agent session), and traps
    # do not run then. Observed 2026-09-11: the ssh client was reparented to
    # launchd and held the connection open for 27 minutes after its runner was
    # gone, so sshd never even started tearing the session down and the mule sat
    # on a permit and the build lock the whole time.
    ( while kill -0 "$_rr_pid" 2>/dev/null; do sleep 3; done; \
      kill -TERM "$_rr_ssh" 2>/dev/null ) &
    _rr_watch=$!
    wait "$_rr_ssh"
    _rc=$?
    # `wait` after the kill, stderr discarded: without it the shell announces the
    # watcher's death ("Terminated: 15 ( while kill -0 ... )") on every single
    # remote run, in the middle of a pre-commit guard's output.
    kill -TERM "$_rr_watch" 2>/dev/null || true
    wait "$_rr_watch" 2>/dev/null || true
    _out=$(cat "$_rr_out" 2>/dev/null || true)
    rm -f "$_rr_out"
    _out=$(printf '%s' "$_out" | tr -d '\r')
    # `|| true` on both greps: a grep that matches nothing exits 1, and callers
    # run with `set -e` (make-app.sh adds `pipefail`), so a remote command whose
    # only output was the marker line would kill the CALLER outright instead of
    # falling back. Neither grep's exit status is information we use.
    printf '%s\n' "$_out" | grep -v '^REMOTE_EXIT:' >&2 || true
    _marker=$(printf '%s\n' "$_out" | grep '^REMOTE_EXIT:' | tail -1 | cut -d: -f2 || true)

    if [ "$_rc" -eq 97 ]; then
        echo "  remote: environment not usable (missing dir, no toolchain, or Command Line Tools selected instead of Xcode) — staying local." >&2
        return 1
    fi
    # 98: the remote is at its job cap. Not an error and not a failure of the
    # caller's code -- just "no capacity there", which is the same answer as an
    # unreachable host, so it takes the same path back into the local queue.
    # Falling back is strictly better than waiting: the local slots are usually
    # free precisely when everyone has piled onto the remote.
    if [ "$_rc" -eq 98 ]; then
        echo "  remote: all $remote_slots remote slots busy — staying local." >&2
        return 1
    fi
    # 255 is ssh's own error code, and a missing marker means the command never
    # completed — either way there is no verdict to trust.
    if [ "$_rc" -eq 255 ] || [ -z "$_marker" ]; then
        echo "  remote: run did not complete (connection dropped) — staying local." >&2
        return 1
    fi
    remote_status="$_marker"
    [ "$remote_status" -eq 0 ] && return 0
    # Say WHAT kind of failure it was. The case this exists for: a remote suite
    # whose test process died with a signal after 3294 passes, where the caller
    # saw one anonymous "FAILURES" and no way to tell that from a compile error
    # or from real failing tests. Matched on plain words only — the per-test
    # lines arrive with SF Symbols glyphs and ANSI colour codes around them.
    # Only for the swift toolchain: xcodebuild (ios.sh) prints neither of these
    # words, so classifying its output would call every iOS failure a build failure.
    if [ "$remote_toolchain" = swift ]; then
        _failed=$(printf '%s\n' "$_out" | grep ' Test ' | grep ' failed after ' \
            | sed -e 's/.* Test //' -e 's/ failed after .*//' \
            | grep -v '^run with ' || true)
        _nfailed=$(printf '%s' "$_failed" | grep -c . || true)
        if [ "$_nfailed" -gt 0 ]; then
            _names=$(printf '%s' "$_failed" | tr '\n' ' ' | sed 's/ *$//')
            echo "  remote: ran and FAILED there — $_nfailed test(s) failed: $_names" >&2
        else
            # Pattern match, not `grep -q`: under pipefail grep -q exits at the first
            # match, printf takes SIGPIPE, and `!` inverts the resulting 141 — which
            # read a transcript with an early "Build complete!" as a build that never
            # finished.
            case "$_out" in
                *"Build complete!"*)
                    _npassed=$(printf '%s\n' "$_out" | grep -v ' Test run with ' \
                        | grep -c ' Test .* passed after ' || true)
                    echo "  remote: ran and FAILED there — exit $remote_status, no test verdict in the output ($_npassed tests passed, no failure lines, no summary line)" >&2
                    ;;
                *)
                    echo "  remote: ran and FAILED there — the build did not finish (no \"Build complete!\" line); the compiler errors are in the output above" >&2
                    ;;
            esac
        fi
    fi
    return 2
}

# Copy one product back from the synced remote tree. $2 is relative to the remote
# repo root; $3 is the local destination path, whose LAST COMPONENT must equal
# $2's — the destination handed to rsync is $3's parent directory, not $3.
#
# That indirection is what makes a DIRECTORY source (the SwiftPM resource bundle)
# land correctly. rsync, unlike cp, does not rename a directory source to the
# destination path: `rsync -a src/foo dest/foo` treats dest/foo as a container and
# writes dest/foo/foo, so the bundle used to nest one level deep and Bundle.module
# could no longer find it (a remote-built .app then trapped on first access). Both
# a file and a directory copy into a destination DIRECTORY under their own name,
# so passing the parent is the one form that is correct for either.
remote_fetch() {
    _esc=$(printf '%s/%s' "$(remote_dir_for "$1")" "$2" | sed 's/ /\\ /g')
    rsync -az --timeout=30 "$remote_host:$_esc" "$(dirname "$3")/" >/dev/null 2>&1
}

# --- local capacity permits -------------------------------------------------
# The counting semaphore that used to live inline in scripts/run-tests.sh, moved
# here so every entry point can take a permit from the SAME pool. Only the test
# runner ever took one; build.sh, make-app.sh, ios.sh and Guard 6 compiled
# uncapped beside it, so "3 permits" never described what the machine was
# actually running.
#
# Rulings (owner's call, 2026-09-10): no mule wait, 600s local ceiling then
# uncapped, sweep-on-acquire.
#   - no mule wait: remote_run's exit 98 keeps falling straight back to local.
#   - 600s local ceiling then uncapped: waiting forever would let one wedged
#     worktree block every commit on the machine; refusing would fail a commit
#     for a reason its author cannot see. Degrading is the only option that
#     leaves the machine usable.
#   - sweep-on-acquire: shlock reclaims a permit whose PID is dead, but not one
#     whose PID was recycled onto some unrelated process, and not one held by a
#     job that hung. Both wedge the pool until a human notices.

# Same resolution as the inline copy it replaces, so a worktree still running the
# old runner sees the same number.
capacity_slots() {
    echo "${AUDIOUT_TEST_SLOTS:-$(git config --get audiout.localSlots 2>/dev/null || echo 3)}"
}

# The name is load-bearing: worktrees that predate this file still take permits
# under /tmp/audiout-suite.lock.N inline, and both must share one pool or the cap
# is silently doubled.
capacity_lock_base() {
    echo "${AUDIOUT_TEST_LOCK_FILE:-/tmp/audiout-suite.lock}"
}

# Free permits whose holder is alive but is not the job it claims to be, or has
# held far longer than any real job takes. Never kills the PID — a wrong guess
# then costs one over-subscribed run, not somebody's build.
capacity_sweep() {
    _cs_base=$(capacity_lock_base)
    _cs_slots=$(capacity_slots)
    _cs_max=${AUDIOUT_CAPACITY_MAX_AGE:-2700}
    _cs_now=$(date +%s)
    _cs_n=1
    while [ "$_cs_n" -le "$_cs_slots" ]; do
        _cs_f="${_cs_base}.${_cs_n}"
        if [ -f "$_cs_f" ]; then
            _cs_pid=$(cat "$_cs_f" 2>/dev/null | tr -d ' ')
            # A dead PID is left alone on purpose: shlock reclaims exactly that
            # case atomically on the next acquire, and racing it here would let
            # two processes take the same permit.
            if [ -n "$_cs_pid" ] && kill -0 "$_cs_pid" 2>/dev/null; then
                _cs_cmd=$(ps -o command= -p "$_cs_pid" 2>/dev/null)
                _cs_age=$((_cs_now - $(stat -f %m "$_cs_f" 2>/dev/null || echo "$_cs_now")))
                case "$_cs_cmd" in
                    *run-tests.sh*|*build.sh*|*make-app.sh*|*ios.sh*|*run-app.sh*|*pre-commit*|*swift*|*xcodebuild*|*xctest*)
                        if [ "$_cs_age" -gt "$_cs_max" ]; then
                            rm -f "$_cs_f"
                            echo "  capacity: reclaimed local permit $_cs_n held by pid $_cs_pid (held ${_cs_age}s > ceiling)" >&2
                            echo "  (pid $_cs_pid is still running and may be a genuinely stuck job just cut loose — check it)" >&2
                        fi
                        ;;
                    *)
                        rm -f "$_cs_f"
                        echo "  capacity: reclaimed local permit $_cs_n held by pid $_cs_pid (not a recognised job)" >&2
                        ;;
                esac
            fi
        fi
        _cs_n=$((_cs_n + 1))
    done
}

# capacity_acquire [label] — take one permit, or proceed uncapped after the
# ceiling. NEVER returns non-zero: a caller that cannot get a permit still has
# work to do, and refusing would turn machine load into a build failure.
# AUDIOUT_CAPACITY_NO_TRAP=1 means the caller installs its own EXIT trap (run-
# tests.sh re-traps around the compiler process group) and calls
# capacity_release itself; installing ours would clobber theirs.
capacity_acquire() {
    _ca_label=${1:-job}
    capacity_slot_file=""
    if [ "${AUDIOUT_TEST_NO_LOCK:-0}" = "1" ]; then
        echo "  capacity: AUDIOUT_TEST_NO_LOCK=1 — not limiting concurrency." >&2
        return 0
    fi
    _ca_base=$(capacity_lock_base)
    _ca_slots=$(capacity_slots)
    _ca_ceiling=${AUDIOUT_CAPACITY_TIMEOUT:-600}
    capacity_sweep
    _ca_waited=0
    _ca_announced=0
    while :; do
        _ca_n=1
        while [ "$_ca_n" -le "$_ca_slots" ]; do
            if /usr/bin/shlock -f "${_ca_base}.${_ca_n}" -p $$; then
                capacity_slot_file="${_ca_base}.${_ca_n}"
                break
            fi
            _ca_n=$((_ca_n + 1))
        done
        if [ -n "$capacity_slot_file" ]; then
            echo "  capacity: local permit $_ca_n/$_ca_slots ($_ca_label)" >&2
            [ "${AUDIOUT_CAPACITY_NO_TRAP:-0}" = "1" ] || \
                trap 'capacity_release' EXIT HUP INT TERM
            return 0
        fi
        if [ "$_ca_announced" -eq 0 ]; then
            echo "  capacity: all $_ca_slots local permits busy — waiting (ceiling ${_ca_ceiling}s)" >&2
            _ca_announced=1
        fi
        if [ "$_ca_waited" -ge "$_ca_ceiling" ]; then
            echo "  capacity: WARNING all local permits busy for ${_ca_ceiling}s — proceeding UNCAPPED (check scripts/capacity.sh status)" >&2
            capacity_slot_file=""
            return 0
        fi
        sleep 5
        _ca_waited=$((_ca_waited + 5))
        # Re-sweep on the same minute tick as the progress line: a permit that
        # went stale WHILE we waited is the common case in a long wait.
        if [ $((_ca_waited % 60)) -eq 0 ]; then
            capacity_sweep
            echo "  capacity: still waiting (${_ca_waited}s of ${_ca_ceiling}s)" >&2
        fi
    done
}

# Idempotent, and refuses to delete a file that is no longer ours — after the
# sweep above reclaims a permit, the next holder's PID is in it, and removing
# that would hand a third process a permit nobody counted.
capacity_release() {
    [ -n "${capacity_slot_file:-}" ] || return 0
    if [ "$(cat "$capacity_slot_file" 2>/dev/null | tr -d ' ')" = "$$" ]; then
        rm -f "$capacity_slot_file"
    fi
    capacity_slot_file=""
}
