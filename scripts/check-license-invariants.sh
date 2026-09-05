#!/bin/bash
# check-license-invariants.sh — the licence-wiring invariants, checked on a
# real build.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Two things must always be true of an Audiout build, and both are about the
# Info.plist key that points the app at its licence server:
#
#   1. A build made WITHOUT AUDIOUT_LICENSE_URL carries NO
#      AudioutLicenseServerURL key. An unlicensed build that embeds one would
#      phone a server it was never meant to know about.
#   2. A build made WITH one carries EXACTLY that URL. A paid build whose key
#      is missing or stale cannot register, and the buyer is stranded.
#
# WHY THIS IS A SCRIPT AND NOT CI: it used to be the `build-invariants` job in
# .github/workflows/license-gate.yml, on a macos runner. GitHub bills macOS at
# 10x, so a ~4.5 minute job cost ~45 minutes of allowance every time it ran —
# on every PR touching scripts/, AudioutCore/ or AirPlayEngine/. That single
# job was the bulk of a 2000-minute monthly budget, and it is now deleted: no
# macOS runner remains in this repo, and this script is the only thing that
# checks these invariants.
#
# Moving it here LOSES nothing that matters, because the check rides on a
# machine that must already be working: make-release.sh builds, signs with a
# Developer ID and notarises locally, so a release cannot happen without a
# functioning local Mac build. make-app.sh routes compilation to the other Mac
# when it is up (scripts/lib/remote.sh) and falls back locally when it is not,
# so this is faster when that machine is available and correct when it is not.
#
# KNOWN GAP, accepted deliberately: the deleted CI job installed the Homebrew
# dependencies from scratch on a clean runner, so it would have caught a build
# that had come to depend on something outside that list. Nothing checks that
# now. Both of this project's Macs have the dependencies already, so the way
# it would surface is a buyer's machine failing to launch a release — which
# bundle-dylibs.sh and scripts/verify-standalone-app.sh are the real defence
# against, not a CI runner.
#
# Usage:
#   check-license-invariants.sh full [<app-bundle> <expected-url>]
#       Guard tests, then a real unlicensed build asserted to carry no key.
#       Given an already-built licensed bundle, asserts invariant 2 on it
#       rather than building a second time.
#
#   check-license-invariants.sh artifact <app-bundle> <expected-url>
#       Invariant 2 only, on a bundle that already exists. No build, so it is
#       cheap enough for the fast iteration paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PLIST_KEY="AudioutLicenseServerURL"

# Reads the key, or prints nothing when it is absent. `plutil -extract` exits
# non-zero on a missing key, which under `set -e` would kill the caller before
# it could report which invariant failed.
read_key() {
  plutil -extract "$PLIST_KEY" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

assert_licensed() {
  _app=$1
  _want=$2
  test -d "$_app" || { echo "ERROR: no app bundle at $_app" >&2; exit 1; }
  _got=$(read_key "$_app")
  [ "$_got" = "$_want" ] || {
    echo "ERROR: licensed build must carry $PLIST_KEY = $_want, got '${_got:-<absent>}'" >&2
    exit 1
  }
  echo "ok — licensed build carries $_want"
}

assert_unlicensed() {
  _app=$1
  _got=$(read_key "$_app")
  [ -z "$_got" ] || {
    echo "ERROR: unlicensed build must carry no $PLIST_KEY, got '$_got'" >&2
    exit 1
  }
  echo "ok — unlicensed build has no $PLIST_KEY"
}

MODE=${1:-full}

case "$MODE" in
  artifact)
    [ $# -eq 3 ] || { echo "usage: $0 artifact <app-bundle> <expected-url>" >&2; exit 2; }
    assert_licensed "$2" "$3"
    ;;

  full)
    echo "==> Licence guard tests"
    bash "$SCRIPT_DIR/test-license-guards.sh"

    # A throwaway output dir: this build exists only to be inspected, and must
    # never land where a release step might pick it up.
    UNLICENSED_DIR=$(mktemp -d "${TMPDIR:-/tmp}/audiout-unlicensed.XXXXXX")
    trap 'rm -rf "$UNLICENSED_DIR"' EXIT

    echo "==> Building WITHOUT a licence URL (invariant 1)"
    # env -u, not `AUDIOUT_LICENSE_URL= `: make-app.sh keys off the variable
    # being SET, so an empty value would not exercise the unlicensed path. The
    # PostHog values are placeholders — this build is inspected, never run.
    ( cd "$REPO_ROOT" && env -u AUDIOUT_LICENSE_URL \
        POSTHOG_PROJECT_TOKEN=invariant-check \
        POSTHOG_HOST=https://example.invalid \
        bash "$SCRIPT_DIR/make-app.sh" "$UNLICENSED_DIR" >/dev/null )
    assert_unlicensed "$UNLICENSED_DIR/Audiout.app"

    if [ $# -eq 3 ]; then
      echo "==> Checking the licensed build already made (invariant 2)"
      assert_licensed "$2" "$3"
    fi
    ;;

  *)
    echo "usage: $0 full [<app-bundle> <expected-url>] | $0 artifact <app-bundle> <expected-url>" >&2
    exit 2
    ;;
esac

echo "licence invariants OK"
