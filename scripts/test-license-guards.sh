#!/bin/bash
# Fast tests for the licence-gate guard rails: the env checks that make a paid
# build impossible to produce without a licence server URL, and the plist check
# make-staging.sh runs against the shipped artifact.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# No build, no network, no signing — every case here fails (or passes) in well
# under a second, because each guard under test fires before any compile. That
# is what makes this a unit-level file: CI's build-invariants job proves the
# full build honours the licence URL; this file proves the refusals and the
# artifact check, cheaply enough to run on every CI job.
#
# plutil is macOS-only, so the plist-function cases skip on Linux. CI runs this
# file on both runner kinds, which covers everything.
#
# Usage: scripts/test-license-guards.sh

set -uo pipefail   # deliberately NOT -e: the tests assert on expected failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

# expect_guard <name> <expected substring> <cmd...>: the command must exit
# nonzero AND print the substring. The perl alarm bounds a regressed guard —
# without it, a guard that stopped firing would start a real multi-minute
# build right here (macOS ships no timeout(1), perl is everywhere).
expect_guard() {
  name="$1"; want="$2"; shift 2
  out="$(perl -e 'alarm shift; exec @ARGV' 30 "$@" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then fail "$name — expected a nonzero exit, got 0"; return; fi
  case "$out" in
    *"$want"*) echo "  ok — $name" ;;
    *) fail "$name — output lacks '$want'"; echo "$out" >&2 ;;
  esac
}

# --- The refusals that keep a paid artifact from being mis-built --------------

# A release build must be impossible without the licence server URL — unset
# and empty are the same mistake.
expect_guard "make-release.sh refuses a build with no AUDIOUT_LICENSE_URL" \
  "AUDIOUT_LICENSE_URL must be set" \
  env -u AUDIOUT_LICENSE_URL APP_VERSION=9.9.9 BUILD_NUMBER=999 bash "$SCRIPT_DIR/make-release.sh" "$TMP_DIR/out"

expect_guard "make-release.sh refuses a build with an empty AUDIOUT_LICENSE_URL" \
  "AUDIOUT_LICENSE_URL must be set" \
  env AUDIOUT_LICENSE_URL= APP_VERSION=9.9.9 BUILD_NUMBER=999 bash "$SCRIPT_DIR/make-release.sh" "$TMP_DIR/out"

# The licence key travels to this URL as a bearer token — plaintext is refused.
expect_guard "make-app.sh refuses a plaintext AUDIOUT_LICENSE_URL" \
  "AUDIOUT_LICENSE_URL must be https://" \
  env AUDIOUT_LICENSE_URL=http://license.audiout.app bash "$SCRIPT_DIR/make-app.sh" "$TMP_DIR/out"

expect_guard "make-app.sh refuses a plaintext SPARKLE_FEED_URL" \
  "SPARKLE_FEED_URL must be https://" \
  env SPARKLE_FEED_URL=http://feed.example bash "$SCRIPT_DIR/make-app.sh" "$TMP_DIR/out"

# make-staging.sh's own fail-fast (this also proves the script still parses,
# since it sources lib/verify-plist-license.sh before these guards run).
expect_guard "make-staging.sh refuses a run with no APP_VERSION" \
  "APP_VERSION must be set" \
  env -u APP_VERSION bash "$SCRIPT_DIR/make-staging.sh" "$TMP_DIR/out"

# --- The artifact check make-staging.sh runs against the shipped DMG ----------

if command -v plutil >/dev/null 2>&1; then
  # shellcheck source=lib/verify-plist-license.sh
  . "$SCRIPT_DIR/lib/verify-plist-license.sh"
  APP="$TMP_DIR/Audiout.app"
  mkdir -p "$APP/Contents"
  write_plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>%s</dict></plist>\n' "$1" > "$APP/Contents/Info.plist"; }

  write_plist '<key>AudioutLicenseServerURL</key><string>https://example.invalid</string>'
  if verify_app_plist_license_url "$APP" "https://example.invalid" 2>/dev/null; then
    echo "  ok — plist check accepts a matching URL"
  else
    fail "plist check rejected a matching URL"
  fi

  err="$(verify_app_plist_license_url "$APP" "https://license.audiout.app" 2>&1)"
  if [ $? -eq 0 ]; then
    fail "plist check accepted a mismatched URL"
  elif [[ "$err" == *"'https://example.invalid'"* && "$err" == *"'https://license.audiout.app'"* ]]; then
    echo "  ok — plist check names actual and expected on a mismatch"
  else
    fail "mismatch error does not name both URLs"; echo "$err" >&2
  fi

  write_plist '<key>CFBundleName</key><string>Audiout</string>'
  err="$(verify_app_plist_license_url "$APP" "https://example.invalid" 2>&1)"
  if [ $? -eq 0 ]; then
    fail "plist check accepted a bundle with no AudioutLicenseServerURL"
  elif [[ "$err" == *"<missing>"* ]]; then
    echo "  ok — plist check reports a missing key as <missing>"
  else
    fail "missing-key error does not say <missing>"; echo "$err" >&2
  fi

  rm "$APP/Contents/Info.plist"
  if verify_app_plist_license_url "$APP" "https://example.invalid" 2>/dev/null; then
    fail "plist check accepted a bundle with no Info.plist at all"
  else
    echo "  ok — plist check rejects a bundle with no Info.plist"
  fi
else
  echo "  skip — plutil not available (Linux); the plist cases run on macOS"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES licence-guard test(s) FAILED" >&2
  exit 1
fi
echo "all licence-guard tests passed"
