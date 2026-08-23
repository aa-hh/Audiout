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
# Short ON PURPOSE. The known failure mode of this particular machine is
# sleeping: it answers ping (sleep proxy) but refuses TCP, so a generous timeout
# would stall every run behind a host that is never going to answer.
remote_probe_timeout=${AUDIOUT_TEST_REMOTE_TIMEOUT:-5}

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
# code is broken". The toolchains differ (local Swift 6.4 / macOS 27 SDK vs
# remote 6.3.1 / macOS 26), so callers accept a remote PASS but re-confirm a
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
    if ! remote_sync "$_root"; then
        echo "  remote: rsync failed — staying local." >&2
        return 1
    fi
    remote_sweep_orphans
    # PATH is set explicitly: a non-interactive ssh shell often lacks
    # /opt/homebrew/bin, and Package.swift shells out to `brew --prefix` to find
    # the keg-only C dependencies.
    # Exit 97 is a private sentinel for "the remote ENVIRONMENT is wrong"
    # (directory missing, no swift) as opposed to "the work failed". Without it,
    # a broken remote reports as a failure of the caller's code — exactly the
    # confusion this function exists to prevent.
    # -tt ties the remote command's life to this connection: with a tty, sshd
    # HUPs the remote process group the moment the local side dies — even
    # SIGKILL, since the kernel still closes the socket. Without it an
    # interrupted caller strands its run on the remote, where it holds the
    # package build lock (see remote_sweep_orphans). The tty's price is CRLF
    # line endings, stripped right below before anything parses $_out.
    _out=$(ssh -tt -o BatchMode=yes -o LogLevel=QUIET \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        "$remote_host" \
        "export PATH=/opt/homebrew/bin:\$PATH; \
         cd \"$_rdir\" || exit 97; \
         command -v swift >/dev/null 2>&1 || exit 97; \
         $* ; echo \"REMOTE_EXIT:\$?\"" 2>&1)
    _rc=$?
    _out=$(printf '%s' "$_out" | tr -d '\r')
    # `|| true` on both greps: a grep that matches nothing exits 1, and callers
    # run with `set -e` (make-app.sh adds `pipefail`), so a remote command whose
    # only output was the marker line would kill the CALLER outright instead of
    # falling back. Neither grep's exit status is information we use.
    printf '%s\n' "$_out" | grep -v '^REMOTE_EXIT:' >&2 || true
    _marker=$(printf '%s\n' "$_out" | grep '^REMOTE_EXIT:' | tail -1 | cut -d: -f2 || true)

    if [ "$_rc" -eq 97 ]; then
        echo "  remote: environment not usable (missing dir or toolchain) — staying local." >&2
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
    return 2
}

# Copy one file back from the synced remote tree. $2 is relative to the remote
# repo root; $3 is the local destination path.
remote_fetch() {
    _esc=$(printf '%s/%s' "$(remote_dir_for "$1")" "$2" | sed 's/ /\\ /g')
    rsync -az --timeout=30 "$remote_host:$_esc" "$3" >/dev/null 2>&1
}
