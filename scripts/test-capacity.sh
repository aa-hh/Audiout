#!/bin/bash
# Tests for scripts/lib/remote.sh's local capacity permit pool
# (capacity_acquire / capacity_sweep / capacity_release) — the pool
# scripts/run-tests.sh, scripts/build.sh, scripts/make-app.sh and
# scripts/run-app.sh all take a permit from.
#
# Runs entirely against a throwaway lock pool: AUDIOUT_TEST_LOCK_FILE points
# at a scratch dir and AUDIOUT_TEST_SLOTS=2, so nothing here ever touches the
# live /tmp/audiout-suite.lock.N pool a real build or test run holds.
#
# Usage: scripts/test-capacity.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
LOCK_BASE="$TMP_DIR/capacity-selftest.lock"
export AUDIOUT_TEST_LOCK_FILE="$LOCK_BASE"
export AUDIOUT_TEST_SLOTS=2

PIDS=""
cleanup() {
  for p in $PIDS; do kill -TERM "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

count_locks() { ls "${LOCK_BASE}".* 2>/dev/null | grep -c . || true; }

# A holder whose ps command line contains "run-tests.sh", so capacity_sweep's
# recognised-job pattern matches it the way a real caller's argv[0] would.
HOLDER="$TMP_DIR/run-tests.sh"
cat > "$HOLDER" <<EOF
#!/bin/sh
. "$SCRIPT_DIR/lib/remote.sh"
capacity_acquire selftest
sleep 30
EOF
chmod +x "$HOLDER"

# --- (a) three concurrent acquires against 2 slots never produce a 3rd file --
# Catches: capacity_acquire's shlock loop racing past its own slot count under
# concurrent callers instead of making the third one wait.
"$HOLDER" >/dev/null 2>&1 & PIDS="$PIDS $!"
"$HOLDER" >/dev/null 2>&1 & PIDS="$PIDS $!"
"$HOLDER" >/dev/null 2>&1 & PIDS="$PIDS $!"
sleep 2
n=$(count_locks)
if [ "$n" -gt 2 ]; then
  fail "three concurrent acquires against 2 slots produced $n lock files"
else
  echo "  ok — $n lock file(s) for 3 holders against 2 slots"
fi
for p in $PIDS; do kill -TERM "$p" 2>/dev/null; done
wait 2>/dev/null
PIDS=""
rm -f "${LOCK_BASE}".*

# --- (b) a holder killed with SIGTERM leaves no lock file behind -------------
# Catches: capacity_acquire's EXIT/HUP/INT/TERM trap not actually installed
# (or clobbered), so a killed holder's permit is never freed and the pool
# quietly shrinks.
"$HOLDER" >/dev/null 2>&1 & hp=$!
PIDS="$hp"
sleep 1
if [ "$(count_locks)" -eq 0 ]; then
  fail "holder never took a permit before being killed — assertion b tests nothing"
else
  kill -TERM "$hp" 2>/dev/null
  wait "$hp" 2>/dev/null
  sleep 1
  n=$(count_locks)
  if [ "$n" -ne 0 ]; then
    fail "SIGTERM'd holder left $n lock file(s) behind"
  else
    echo "  ok — SIGTERM'd holder released its permit"
  fi
fi
PIDS=""
rm -f "${LOCK_BASE}".*

# --- (c) capacity_release: no-op when nothing is held, and never deletes ----
# a permit file owned by another pid.
# Catches: capacity_release deleting a file just because capacity_slot_file
# is set, without checking the file still names this process's own pid —
# which would hand a second, unrelated process's permit away.
# shellcheck source=lib/remote.sh
. "$SCRIPT_DIR/lib/remote.sh"

other_pid=$(( $$ + 1 ))
echo "$other_pid" > "${LOCK_BASE}.1"
capacity_slot_file="${LOCK_BASE}.1"
capacity_release
if [ -f "${LOCK_BASE}.1" ]; then
  echo "  ok — capacity_release left a permit owned by another pid alone"
else
  fail "capacity_release deleted a permit file not owned by this process"
fi
rm -f "${LOCK_BASE}.1"

capacity_slot_file=""
if capacity_release; then
  echo "  ok — capacity_release with nothing held is a no-op"
else
  fail "capacity_release with nothing held returned nonzero"
fi

# --- (d) remote_permits_win routes to the side with more free permits --------
# remote.sh is already sourced (case c). The mule half is stubbed: no ssh, no
# reachability probe, just a fixed permit table, so these cases test the
# comparison and nothing else.
remote_reachable() { return 0; }
remote_mule_permits() { printf '%s\n' "$MULE_TABLE"; }
remote_slots=3
remote_host=fake

TAB=$'\t'
alive_line() { printf '%s\t%s\talive\t10\tswift test' "$1" "$((10000 + $1))"; }

# A live process whose ps command line contains "run-tests.sh". The lock files
# below must name one: remote_permits_win sweeps before counting, and the sweep
# reclaims any permit held by a command it does not recognise — so a permit
# naming this test script's own pid would be gone before it was counted.
SLEEPER="$TMP_DIR/run-tests.sh.sleeper"
printf '#!/bin/sh\nsleep 60\n' > "$SLEEPER"
chmod +x "$SLEEPER"

# $1 = mule table, $2 = local permits to hold, $3 = "mule"|"local", $4 = message
check_route() {
  MULE_TABLE="$1"
  rm -f "${LOCK_BASE}".*
  held_pids=""
  i=1
  while [ "$i" -le "$2" ]; do
    "$SLEEPER" & held_pids="$held_pids $!"
    echo "$!" > "${LOCK_BASE}.$i"
    i=$((i + 1))
  done
  if remote_permits_win 2>/dev/null; then got=mule; else got=local; fi
  for p in $held_pids; do kill -TERM "$p" 2>/dev/null; done
  wait 2>/dev/null
  if [ "$got" = "$3" ]; then
    echo "  ok — $4"
  else
    fail "$4 (routed to $got)"
  fi
  rm -f "${LOCK_BASE}".*
}

# Catches: a comparison that never picks the mule (an inverted rule, or one
# that treats this machine's free permits as always winning).
check_route "" 1 mule "mule 3 free vs local 1 free — mule"

# Catches: sending work to a mule with nothing free, which costs a full sync
# and round trip only to come back on exit 98.
check_route "$(alive_line 1)
$(alive_line 2)
$(alive_line 3)" 0 local "mule 0 free vs local 2 free — local"

# Catches: a strict greater-than that sends a tie to this machine, the one also
# running the agents, the editor and any app under live test.
check_route "$(alive_line 1)
$(alive_line 2)" 1 mule "mule 1 free vs local 1 free — tie goes to the mule"

# Catches: a comparison inverted, or one that treats any free mule permit as a win.
check_route "$(alive_line 1)
$(alive_line 2)" 0 local "mule 1 free vs local 2 free — local"

# Catches: counting orphaned holders as held, which would hide a mule that is
# actually idle (the next remote run reclaims those permits).
check_route "1${TAB}10001${TAB}orphaned${TAB}10${TAB}swift test
2${TAB}10002${TAB}orphaned${TAB}10${TAB}swift test
3${TAB}10003${TAB}orphaned${TAB}10${TAB}swift test" 0 mule "3 orphaned mule permits don't count — mule"

# Catches: an unaskable mule reading as a win — a failed probe must mean
# local, never a guess.
remote_mule_permits() { return 1; }
check_route "" 0 local "mule permit table unavailable — local"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES capacity test(s) FAILED" >&2
  exit 1
fi
echo "all capacity tests passed"
