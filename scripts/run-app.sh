#!/bin/sh
# The sanctioned way to launch the offline app: a Claude Code hook denies a
# bare `swift run`, so this script holds a local capacity permit for the
# app's whole lifetime and execs `swift run` in its place.
#
# Usage: scripts/run-app.sh [-h] [extra swift-run args...]
# Env:   AIRPLAY_BACKEND (default mock), AUDIOUT_TEST_PACKAGE (default
#        AudioutCore), AUDIOUT_RUN_PRODUCT (default AudioutApp)

case ${1:-} in
    -h|--help)
        echo "Usage: scripts/run-app.sh [extra swift-run args...]"
        echo "  Runs the offline app (default AIRPLAY_BACKEND=mock) under a local"
        echo "  capacity permit. Extra arguments pass through to the app."
        exit 0
        ;;
esac

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/remote.sh
. "$SCRIPT_DIR/lib/remote.sh"

AIRPLAY_BACKEND=${AIRPLAY_BACKEND:-mock}
export AIRPLAY_BACKEND
pkg=${AUDIOUT_TEST_PACKAGE:-AudioutCore}
product=${AUDIOUT_RUN_PRODUCT:-AudioutApp}

capacity_acquire run-app

# exec, not a plain call: it replaces this shell with swift-run in place, same
# pid, so the permit file (which holds $$) still names the right process for
# as long as the app runs. shlock reclaims it the moment the app quits, the
# same as any other holder's exit.
exec swift run --package-path "$SCRIPT_DIR/../$pkg" "$product" "$@"
