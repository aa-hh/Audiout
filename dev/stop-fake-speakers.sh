#!/usr/bin/env bash
#
# stop-fake-speakers.sh — stop every dummy receiver started by fake-speakers.sh
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.run"
[[ -d "$RUN_DIR" ]] || { echo "Nothing to stop (no .run dir)."; exit 0; }

stopped=0
for pidfile in "$RUN_DIR"/*.pid; do
  [[ -e "$pidfile" ]] || continue
  pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" && echo "• stopped pid $pid ($(basename "$pidfile" .pid))"
    stopped=$((stopped + 1))
  fi
  rm -f "$pidfile"
done

[[ $stopped -eq 0 ]] && echo "No running fake speakers found." || echo "Stopped $stopped."
