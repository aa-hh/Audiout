#!/bin/bash
#
# Load generator for audio scheduling measurement.
# Spins up N CPU-burning background processes for a configurable duration.
#
# Usage: bash scripts/load-gen.sh [N] [duration_seconds]
#
# Arguments:
#   N                (optional, default 16) - number of CPU spinner processes
#   duration_seconds (optional, default 60) - how long to run (seconds)
#
# Example:
#   bash scripts/load-gen.sh 4 5     # 4 spinners for 5 seconds
#   bash scripts/load-gen.sh 16      # 16 spinners for 60 seconds (default)
#   bash scripts/load-gen.sh         # 16 spinners for 60 seconds
#
# On macOS with an 8-core machine, N=16 reproduces a load average of ~16.
#

set -euo pipefail

# Parse arguments
N_SPINNERS="${1:-16}"
DURATION_SECS="${2:-60}"

# Validate arguments
if ! [[ "$N_SPINNERS" =~ ^[0-9]+$ ]] || [ "$N_SPINNERS" -lt 1 ]; then
    echo "Error: N_SPINNERS must be a positive integer (got: $N_SPINNERS)" >&2
    exit 1
fi

if ! [[ "$DURATION_SECS" =~ ^[0-9]+$ ]] || [ "$DURATION_SECS" -lt 1 ]; then
    echo "Error: DURATION_SECS must be a positive integer (got: $DURATION_SECS)" >&2
    exit 1
fi

# Array to track spawned process PIDs
declare -a SPINNER_PIDS

# Cleanup function: kill all spawned processes
cleanup() {
    for pid in "${SPINNER_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    # Wait a moment for processes to exit
    sleep 0.1
    # Force-kill any stragglers
    for pid in "${SPINNER_PIDS[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
    done
}

# Install trap to clean up on exit (normal or interrupt)
trap cleanup EXIT

echo "=== Load Generator Start ==="
echo "Baseline (before load):"
uptime

echo ""
echo "Starting $N_SPINNERS CPU spinner(s) for ${DURATION_SECS}s..."
echo ""

# Start N background spinner processes
# Each spinner is a portable busy-loop using shell arithmetic
for i in $(seq 1 "$N_SPINNERS"); do
    (
        # Busy-loop: spin on arithmetic to peg a CPU core
        # This is portable across macOS and Linux
        end_time=$(($(date +%s) + DURATION_SECS))
        while [ "$(date +%s)" -lt "$end_time" ]; do
            # Arithmetic busy-loop: compute something that can't be optimized away
            x=0
            for _ in $(seq 1 100000); do
                x=$((x + 1))
            done
        done
    ) &
    SPINNER_PIDS+=($!)
done

echo "Spinners running (PIDs: ${SPINNER_PIDS[*]})"

# Wait for the specified duration
sleep "$DURATION_SECS"

# Cleanup is automatic via trap, but we can print the result here
echo ""
echo "=== Load Generator Complete ==="
echo "Load after stopping (should return to baseline within ~30s):"
uptime
echo ""
echo "All spinners cleaned up."
