#!/usr/bin/env bash
#
# fake-speakers.sh — spin up dummy AirPlay (v1) receivers for offline development.
#
# Each speaker is a separate `shairport-sync` process advertising itself over
# Bonjour with a distinct name and RTSP port, so the app's discovery layer
# (NWBrowser on `_raop._tcp`) sees several real devices with NO hardware.
#
# What this exercises:   Bonjour discovery, device appear/disappear, AirPlay-1
#                        RTSP/RAOP send path.
# What it does NOT:      AirPlay-2 PTP sync, Sonos-specific behaviour. Those need
#                        real speakers (or a second host) — the in-app mock
#                        backend stands in for them at the UI layer.
#
# Usage:
#   ./fake-speakers.sh                       # launches the 3 defaults
#   ./fake-speakers.sh "Kitchen" "Garage"    # launches named speakers
#   SILENT=0 ./fake-speakers.sh              # actually play audio (default: silent)
#
# Stop them with ./stop-fake-speakers.sh
set -euo pipefail

SHAIRPORT="$(command -v shairport-sync || echo /opt/homebrew/opt/shairport-sync/bin/shairport-sync)"
if [[ ! -x "$SHAIRPORT" ]]; then
  echo "shairport-sync not found. Install it:  brew install shairport-sync" >&2
  exit 1
fi

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.run"
mkdir -p "$RUN_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# IMPORTANT single-machine limitation (verified 2026-07-13, shairport-sync 5.1):
#   • The Homebrew build is AirPlay-1 only and IGNORES the RTSP port setting
#     (both CLI -p and config `port`) in Classic AirPlay mode — every instance
#     binds :5000, so you can run AT MOST ONE at a time.
#   • macOS's own AirPlay Receiver also holds :5000. Free it first:
#       System Settings ▸ General ▸ AirDrop & Handoff ▸ AirPlay Receiver → Off
#   ⇒ This gives ONE real, discoverable AirPlay-1 target for sanity-checking the
#     discovery/send path. For MULTIPLE devices, groups and sync, use the in-app
#     MockBackend (AudioutCore) — that's the primary offline tool.
# ─────────────────────────────────────────────────────────────────────────────

# One speaker by default (see limitation above). Pass names to try more, but
# expect all-but-one to die on the :5000 collision until the build supports ports.
SPEAKERS=("$@")
if [[ ${#SPEAKERS[@]} -eq 0 ]]; then
  SPEAKERS=("Dev Speaker")
fi

# Silent by default. This build has no `dummy` backend, so silent mode uses the
# `stdout` backend and throws the PCM away (>/dev/null). SILENT=0 → audible via ao.
# NOTE: shairport-sync 5.1's CLI `-p/--port` is ignored in Classic AirPlay mode,
# so name+port MUST be set via a generated per-instance config file (see below).
SILENT="${SILENT:-1}"
if [[ "$SILENT" == "1" ]]; then
  BACKEND="stdout"; DISCARD_AUDIO=1
else
  BACKEND="ao"; DISCARD_AUDIO=0     # play through CoreAudio via libao
fi

BASE_PORT=5100
i=0
for name in "${SPEAKERS[@]}"; do
  port=$((BASE_PORT + i))
  slug="$(echo "$name" | tr ' A-Z' '-a-z')"
  pidfile="$RUN_DIR/$slug.pid"
  logfile="$RUN_DIR/$slug.log"

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "• '$name' already running (pid $(cat "$pidfile"))"
    i=$((i + 1)); continue
  fi

  # Generate a per-instance config: name + distinct RTSP port + backend.
  # (CLI -p is ignored in this build; config `general.port` is honoured.)
  cfgfile="$RUN_DIR/$slug.conf"
  cat >"$cfgfile" <<EOF
general = {
  name = "$name";
  port = $port;
  output_backend = "$BACKEND";
};
EOF

  # stderr → logfile (shairport logs there by default); stdout → audio sink.
  if [[ "$DISCARD_AUDIO" == "1" ]]; then
    "$SHAIRPORT" -c "$cfgfile" -v >/dev/null 2>"$logfile" &
  else
    "$SHAIRPORT" -c "$cfgfile" -v >"$logfile" 2>&1 &
  fi
  echo $! >"$pidfile"
  echo "• '$name'  RTSP :$port  pid $!  log $logfile"
  i=$((i + 1))
done

# Health check: shairport dies immediately on a :5000 collision, so confirm each
# instance is actually alive and surface the fatal line if not.
sleep 1
dead=0
for name in "${SPEAKERS[@]}"; do
  slug="$(echo "$name" | tr ' A-Z' '-a-z')"
  pidfile="$RUN_DIR/$slug.pid"; logfile="$RUN_DIR/$slug.log"
  [[ -f "$pidfile" ]] || continue
  if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    dead=$((dead + 1))
    echo "  ✗ '$name' died. Last error:"
    grep -iE 'fatal|Address already' "$logfile" | tail -1 | sed 's/^/      /'
    rm -f "$pidfile"
  fi
done

echo
if [[ $dead -gt 0 ]]; then
  echo "⚠ $dead instance(s) died — almost certainly the :5000 collision noted above."
  echo "  Turn off macOS AirPlay Receiver, and run only ONE fake speaker."
fi
echo "Verify the survivor advertises with:   dns-sd -B _raop._tcp"
echo "Stop everything with:                  $(dirname "${BASH_SOURCE[0]}")/stop-fake-speakers.sh"
