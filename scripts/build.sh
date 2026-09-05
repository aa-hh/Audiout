#!/bin/sh
# Compile-check entry point. Use this instead of a bare `swift build`.
#
# WHY: a bare `swift build` pins the compile to THIS machine — the one already
# carrying every agent, the editor, and any app under live test. This wrapper
# asks the same question scripts/run-tests.sh asks (scripts/lib/remote.sh), so
# builds and tests agree on where work goes instead of each answering it
# separately. With no remote configured it is a passthrough to `swift build`.
#
# Usage:
#   scripts/build.sh                       # AudioutCore, debug
#   scripts/build.sh -c release            # any swift-build flags pass through
#   scripts/build.sh --product ptp-helper  #
#   AUDIOUT_BUILD_PACKAGE=AirPlayEngine scripts/build.sh
#
# Env:
#   AUDIOUT_BUILD_PACKAGE  package dir, relative to the repo root
#                            (default AudioutCore)
#   AUDIOUT_BUILD_LOCAL=1  skip the remote entirely
#
# SCOPE — this is a CHECK, not a producer. It answers "does this compile?" and
# deliberately does NOT copy artifacts back: a remote compile does not warm the
# local .build cache, so anything that needs a runnable binary here (swift run,
# make-app.sh's bundle) must build locally anyway. make-app.sh handles its own
# remote/local split and fetches the products it needs.
set -eu

# A compiler orphaned by a killed wrapper holds the .build lock and makes
# this script hang with no output at all. Clear it first -- see
# scripts/reap-orphaned-swift.sh.
bash "$(dirname "${BASH_SOURCE[0]}")/reap-orphaned-swift.sh" || true

repo_root=$(git rev-parse --show-toplevel)
package=${AUDIOUT_BUILD_PACKAGE:-AudioutCore}

# Build engine: the SwiftPM default (swiftbuild). This used to pin the old
# `native` engine, because swiftbuild did not forward a C target's cSettings
# unsafeFlags (AirPlayEngine/Package.swift's Homebrew -I paths) into the clang
# module dependency scan, so `import CAirPlayEngine` failed to resolve. That is
# fixed as of Swift 6.4 — verified 2026-09-04 by building both packages and
# running the suite with no flag.
#
# Do NOT reintroduce a per-script engine flag. The engines keep SEPARATE caches
# (~1.3 GB apiece), so one script disagreeing with the others costs every
# worktree a full cold rebuild. build.sh, run-tests.sh and make-app.sh use the
# same engine, and housekeeping.sh's stale-cache sweep assumes it.

. "$(cd "$(dirname "$0")" && pwd)/lib/remote.sh"

if [ "${AUDIOUT_BUILD_LOCAL:-0}" != "1" ] && remote_wins; then
    echo "  build: sending to remote $remote_host ..." >&2
    rrc=0
    remote_run "$repo_root" "cd \"$package\" && swift build $*" || rrc=$?
    if [ "$rrc" -eq 0 ]; then
        echo "  build: compiled clean on remote $remote_host." >&2
        exit 0
    elif [ "$rrc" -eq 2 ]; then
        # Ran and failed. Do NOT report it as the caller's error: both Macs run
        # Swift 6.4 but against different SDKs (macOS 27 here, macOS 26 there),
        # and the remote has been out of disk and starved before, so
        # a remote-only failure is as likely to be skew as a real break. Same
        # asymmetry run-tests.sh uses — a remote PASS is accepted, a remote
        # FAILURE is re-confirmed here before anyone acts on it.
        echo "  build: remote reported ERRORS — rebuilding locally to confirm." >&2
    else
        echo "  build: falling back to this machine." >&2
    fi
fi

# shellcheck disable=SC2086
( cd "$repo_root/$package" && swift build "$@" )
