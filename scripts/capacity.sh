#!/bin/sh
# Read-only view of the local and mule capacity pools scripts/lib/remote.sh
# manages: who holds a permit, how old the hold is, and whether capacity_sweep
# (locally) or the mule-side reclaim loop in remote_run would already have
# taken it back. Never reclaims anything itself — an agent deciding whether to
# start a build should be able to look without changing what it sees.
#
# Usage: scripts/capacity.sh [status]
#   status is the only subcommand; no args = status. Always exits 0 — a
#   status check that can itself fail would be one more thing to debug before
#   the thing it is meant to help you debug.

cmd=${1:-status}
if [ "$cmd" != "status" ]; then
    echo "capacity: unknown subcommand '$cmd' (only 'status')" >&2
    exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/remote.sh
. "$SCRIPT_DIR/lib/remote.sh"

max_age=${AUDIOUT_CAPACITY_MAX_AGE:-2700}
now=$(date +%s)

# Trim a command line to about 80 characters so one permit stays one line.
trim80() {
    _t="$1"
    if [ "${#_t}" -gt 80 ]; then
        printf '%s...' "$(printf '%s' "$_t" | cut -c1-77)"
    else
        printf '%s' "$_t"
    fi
}

# One permit line for a local lock file $1 (already known to exist), numbered
# $2 of $3 slots. Echoes "held" (1) or nothing (0) via return status.
print_local_permit() {
    _f="$1"; _n="$2"
    _pid=$(cat "$_f" 2>/dev/null | tr -d ' ')
    case $_pid in
        ''|*[!0-9]*) echo "  local permit $_n: unreadable lock file, skipping"; return 1 ;;
    esac
    if kill -0 "$_pid" 2>/dev/null; then
        _alive="alive"
        _cmd=$(ps -o command= -p "$_pid" 2>/dev/null)
        _cmd=$(trim80 "$_cmd")
    else
        _alive="dead"
        _cmd="(process gone)"
    fi
    _age=$((now - $(stat -f %m "$_f" 2>/dev/null || echo "$now")))
    _stale=""
    if [ "$_alive" = "alive" ]; then
        case "$_cmd" in
            *run-tests.sh*|*build.sh*|*make-app.sh*|*ios.sh*|*run-app.sh*|*pre-commit*|*swift*|*xcodebuild*|*xctest*)
                [ "$_age" -gt "$max_age" ] && _stale=" STALE (age > ${max_age}s)" ;;
            *) _stale=" STALE (unrecognised command)" ;;
        esac
    fi
    echo "  local permit $_n: pid $_pid, $_alive, age ${_age}s, cmd: $_cmd$_stale"
    return 0
}

echo "local ($(hostname -s 2>/dev/null || hostname)):"
_base=$(capacity_lock_base)
_slots=$(capacity_slots)
_held=0
_n=1
while [ "$_n" -le "$_slots" ]; do
    _f="${_base}.${_n}"
    if [ -f "$_f" ]; then
        print_local_permit "$_f" "$_n" && _held=$((_held + 1))
    fi
    _n=$((_n + 1))
done
echo "  held $_held of $_slots"

echo "mule:"
if ! remote_configured; then
    echo "  mule: unreachable"
    exit 0
fi
if ! remote_reachable; then
    echo "  mule: unreachable"
    exit 0
fi
_mule_out=$(ssh -o BatchMode=yes -o ConnectTimeout="$remote_probe_timeout" \
    -o StrictHostKeyChecking=accept-new "$remote_host" \
    "_n=1; while [ \$_n -le $remote_slots ]; do \
         _f=/tmp/audiout-remote-work.lock.\$_n; \
         if [ -f \"\$_f\" ]; then \
             _p=\$(cat \"\$_f\" 2>/dev/null | tr -d ' '); \
             _age=\$(( \$(date +%s) - \$(stat -f %m \"\$_f\" 2>/dev/null || date +%s) )); \
             if [ -n \"\$_p\" ] && kill -0 \"\$_p\" 2>/dev/null; then \
                 _c=\$(ps -o command= -p \"\$_p\" 2>/dev/null); \
                 echo \"\$_n	\$_p	alive	\$_age	\$_c\"; \
             else \
                 echo \"\$_n	\$_p	dead	\$_age	(process gone)\"; \
             fi; \
         fi; \
         _n=\$((_n + 1)); \
     done" 2>/dev/null)
if [ -z "$_mule_out" ]; then
    _held=0
else
    _held=$(printf '%s\n' "$_mule_out" | grep -c .)
fi
printf '%s\n' "$_mule_out" | while IFS="$(printf '\t')" read -r _n _pid _alive _age _cmd; do
    [ -n "$_n" ] || continue
    _stale=""
    if [ "$_alive" = "alive" ]; then
        case "$_cmd" in
            *run-tests.sh*|*build.sh*|*make-app.sh*|*ios.sh*|*run-app.sh*|*pre-commit*|*swift*|*xcodebuild*|*xctest*)
                [ "$_age" -gt "$max_age" ] && _stale=" STALE (age > ${max_age}s)" ;;
            *) _stale=" STALE (unrecognised command)" ;;
        esac
    fi
    echo "  mule permit $_n: pid $_pid, $_alive, age ${_age}s, cmd: $(trim80 "$_cmd")$_stale"
done
echo "  held $_held of $remote_slots"

exit 0
