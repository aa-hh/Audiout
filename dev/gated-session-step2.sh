#!/bin/bash
# Phase 2b gated session — STEP 2: the real app on AIRPLAY_BACKEND=native.
# Run with:  sudo bash dev/gated-session-step2.sh   (from the worktree root)
# Interim privilege model (until the SMAppService PTP helper ships): the app
# runs under sudo so the engine can bind PTP UDP 319/320, exactly like the
# probe. Firewall-allowlist BEFORE first bind.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="$ROOT/build/Audiout.app/Contents/MacOS/AudioutApp"
[ -x "$APP_BIN" ] || { echo "app not built (scripts/make-app.sh)"; exit 1; }

FW=/usr/libexec/ApplicationFirewall/socketfilterfw
"$FW" --add "$APP_BIN" >/dev/null 2>&1 || true
"$FW" --unblockapp "$APP_BIN" >/dev/null 2>&1 || true

export AIRPLAY_BACKEND=native
export AIRPLAYENGINE_LOG_LEVEL=3
export AIRPLAYENGINE_LOG_STDERR=1

echo ">>> launching the app on the native backend (menu-bar icon should appear) <<<"
echo ">>> grant the system-audio recording permission if prompted <<<"
exec script -q /tmp/app-native.log "$APP_BIN"
