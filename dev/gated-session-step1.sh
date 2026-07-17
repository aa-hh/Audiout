#!/bin/bash
# Phase 2b gated session — STEP 1: multi-room sync (engine-probe, 2 outputs).
# Run with:  sudo bash dev/gated-session-step1.sh   (from the worktree root)
# PTP needs root (UDP 319/320); firewall must allowlist BEFORE first bind.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/AirPlayEngine/.build/debug/engine-probe"
TONE="$ROOT/dev/probe-tone.raw"
[ -x "$PROBE" ] || { echo "engine-probe not built (swift build in AirPlayEngine/)"; exit 1; }
[ -f "$TONE" ] || { echo "probe tone missing: $TONE"; exit 1; }

FW=/usr/libexec/ApplicationFirewall/socketfilterfw
"$FW" --add "$PROBE" >/dev/null 2>&1 || true
"$FW" --unblockapp "$PROBE" >/dev/null 2>&1 || true

export AIRPLAYENGINE_LOG_LEVEL=3   # E_INFO
export AIRPLAYENGINE_LOG_STDERR=1

echo ">>> streaming 25s beeping tone to Sonos Move + Move 2 — listen for sync <<<"
exec script -q /tmp/probe-multiroom.log "$PROBE" \
  --name "Mixer"  --port 7000 --address 192.168.4.29 --device-id A4:E9:75:F1:F0:DA \
  --name "Move 2"     --port 7000 --address 192.168.4.37 --device-id C4:38:75:0E:BF:4A \
  --pcm "$TONE" \
  --i-have-a-receiver-and-owntone-is-stopped
