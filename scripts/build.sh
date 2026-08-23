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
#   scripts/build.sh                       # AudiouterCore, debug
#   scripts/build.sh -c release            # any swift-build flags pass through
#   scripts/build.sh --product ptp-helper  #
#   AUDIOUTER_BUILD_PACKAGE=AirPlayEngine scripts/build.sh
#
# Env:
#   AUDIOUTER_BUILD_PACKAGE  package dir, relative to the repo root
#                            (default AudiouterCore)
#   AUDIOUTER_BUILD_LOCAL=1  skip the remote entirely
#
# SCOPE — this is a CHECK, not a producer. It answers "does this compile?" and
# deliberately does NOT copy artifacts back: a remote compile does not warm the
# local .build cache, so anything that needs a runnable binary here (swift run,
# make-app.sh's bundle) must build locally anyway. make-app.sh handles its own
# remote/local split and fetches the products it needs.
set -eu

repo_root=$(git rev-parse --show-toplevel)
package=${AUDIOUTER_BUILD_PACKAGE:-AudiouterCore}

# --build-system native: Xcode 26+/27 made the new "swiftbuild" engine the
# default, but it doesn't forward a C target's cSettings unsafeFlags
# (AirPlayEngine/Package.swift's Homebrew -I paths) into the clang module
# dependency scan, so `import CAirPlayEngine` fails to resolve. It is also the
# engine every other script here pins — and the engines keep SEPARATE caches, so
# one stray default-engine command costs a full cold rebuild. Same flag
# everywhere, always.
build_flags="--build-system native"

. "$(cd "$(dirname "$0")" && pwd)/lib/remote.sh"

if [ "${AUDIOUTER_BUILD_LOCAL:-0}" != "1" ] && remote_wins; then
    echo "  build: sending to remote $remote_host ..." >&2
    rrc=0
    # remote_quote, not a bare `$*`: the remote shell re-parses this string, so
    # caller flags must arrive quoted (see remote.sh).
    remote_run "$repo_root" "cd \"$package\" && swift build $build_flags$(remote_quote "$@")" || rrc=$?
    if [ "$rrc" -eq 0 ]; then
        echo "  build: compiled clean on remote $remote_host." >&2
        exit 0
    elif [ "$rrc" -eq 2 ]; then
        # Ran and failed. Do NOT report it as the caller's error: the toolchains
        # differ (local Swift 6.4 / macOS 27 SDK vs remote 6.3.1 / macOS 26), so
        # a remote-only failure is as likely to be skew as a real break. Same
        # asymmetry run-tests.sh uses — a remote PASS is accepted, a remote
        # FAILURE is re-confirmed here before anyone acts on it.
        echo "  build: remote reported ERRORS — rebuilding locally to confirm." >&2
    else
        echo "  build: falling back to this machine." >&2
    fi
fi

# shellcheck disable=SC2086
( cd "$repo_root/$package" && swift build $build_flags "$@" )
