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

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES capacity test(s) FAILED" >&2
  exit 1
fi
echo "all capacity tests passed"
