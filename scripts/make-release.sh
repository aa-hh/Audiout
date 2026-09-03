#!/bin/bash
# make-release.sh — wrap make-app.sh's output into a notarised, stapled,
# distributable zip. This is the release pipeline: build → sign (make-app.sh)
# → notarise → staple → zip the distributable → checksum.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# razor: no DMG. A zip is the one artifact both Paddle's file delivery and
# Sparkle's updater consume unmodified — a DMG would be a second packaging
# format serving no consumer this pipeline has today. If a future distribution
# channel needs a DMG (e.g. a marketing-site "drag to Applications" affordance),
# add a `hdiutil create` step after the staple below; nothing here blocks it.
#
# Usage: APP_VERSION=1.0.0 BUILD_NUMBER=1 scripts/make-release.sh [output-dir]
# Every command below is a paste-proof one-liner — no backslash continuations.
#
# See docs/RELEASE.md for the full runbook, including the one-time credential
# setup this script assumes is already done (Developer ID cert, notarytool
# keychain profile).

set -euo pipefail

# --- Config -----------------------------------------------------------------
# APP_VERSION / BUILD_NUMBER are REQUIRED here, unlike make-app.sh (which
# defaults them for dev builds) — a release with an unversioned or
# accidentally-defaulted filename is exactly the kind of mistake this script
# exists to prevent (Paddle delivery and the Sparkle appcast both key off
# APP_VERSION). Fail fast rather than silently shipping "Audiout-0.1.0.zip".
if [ -z "${APP_VERSION:-}" ]; then
  echo "ERROR: APP_VERSION must be set (e.g. APP_VERSION=1.0.0 BUILD_NUMBER=3 scripts/make-release.sh)" >&2
  exit 1
fi
if [ -z "${BUILD_NUMBER:-}" ]; then
  echo "ERROR: BUILD_NUMBER must be set (e.g. APP_VERSION=1.0.0 BUILD_NUMBER=3 scripts/make-release.sh)" >&2
  exit 1
fi

# AUDIOUT_LICENSE_URL is optional in make-app.sh — a build with no license
# server is the free source build, a real product state. It is REQUIRED here:
# this script produces the notarised artifact a buyer pays for, and that one
# validates keys and updates itself.
if [ -z "${AUDIOUT_LICENSE_URL:-}" ]; then
  echo "ERROR: AUDIOUT_LICENSE_URL must be set for a release build (e.g. AUDIOUT_LICENSE_URL=https://license.audiout.app) — without it the shipped app validates no keys and never updates" >&2
  exit 1
fi

# Same reasoning: the first-open gate's only route for someone without a key
# is its "Buy Audiout" button, and that button hides itself without this.
export AUDIOUT_BUY_URL="${AUDIOUT_BUY_URL:-https://audiout.app/buy}"

# The address below is the one thing about this artifact that can never be
# fixed later: make-app.sh writes it into Info.plist, and every copy on every
# buyer's Mac polls it forever. Get it wrong and they lose key validation AND
# the update channel that would have delivered the correction — there is no
# way to reach them afterwards. So it is proven reachable before anything is
# built, signed or notarised.
#
# Same default make-app.sh applies, so this checks the feed that actually
# gets baked rather than one nothing will use.
FEED_URL="${SPARKLE_FEED_URL:-$AUDIOUT_LICENSE_URL/appcast.xml}"

# Unauthenticated, the license server answers its feed 401 "license key
# required". Any other answer means this URL is not the license server right
# now — which is not hypothetical: a stray Cloudflare route once left
# license.audiout.app serving the marketing site, and a release cut in that
# window would have shipped a permanently broken updater to every buyer.
echo "==> Pre-flight: $FEED_URL must answer as the license server"
FEED_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$FEED_URL")" || FEED_CURL_EXIT=$?
# Not reached at all (no DNS, no route, timeout) is a different problem from
# reached-and-answered-wrong, and pointing at the URL would misdiagnose it.
if [ -n "${FEED_CURL_EXIT:-}" ]; then
  echo "ERROR: could not reach $FEED_URL — curl exited $FEED_CURL_EXIT (6 = hostname did not resolve, 28 = timed out)" >&2
  echo "       This says nothing about whether the URL is correct. Check your connection, then re-run." >&2
  exit 1
fi
if [ "$FEED_STATUS" != "401" ]; then
  echo "ERROR: $FEED_URL answered HTTP $FEED_STATUS, expected 401 (license key required)" >&2
  echo "       That URL is baked into every copy of this release and cannot be changed afterwards." >&2
  echo "       Check the Worker is deployed and that no other Cloudflare route is shadowing the hostname, then re-run." >&2
  exit 1
fi
echo "    ok — 401 license key required"

# Release builds always carry the canonical shipping identity — never a
# side-by-side test id. Unlike a live-test handoff build (which MUST get a
# fresh APP_NAME/BUNDLE_ID every time, see CLAUDE.md), this artifact is meant
# to replace the previous release under the SAME identity, so any override
# left in the environment from an earlier test build is discarded here rather
# than silently baked into the thing being notarised and shipped.
unset APP_NAME BUNDLE_ID

NOTARY_PROFILE="${NOTARY_PROFILE:-audiout-notary}"

# --- Paths --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/build}"
APP_BUNDLE="$OUTPUT_DIR/Audiout.app"
NOTARIZE_ZIP="$OUTPUT_DIR/Audiout-notarize.zip"
DIST_ZIP="$OUTPUT_DIR/Audiout-${APP_VERSION}.zip"

# --- Build + sign (make-app.sh) ----------------------------------------------
# AUDIOUT_BUNDLE_DYLIBS=1: the release build must run on a Mac with no
# Homebrew — see bundle-dylibs.sh. CODESIGN_REQUIRE_IDENTITY=1: a release
# built ad-hoc (no Developer ID cert in the keychain) is not shippable —
# notarization below would reject it anyway, so fail here with make-app.sh's
# clearer error instead of a confusing notarytool rejection.
echo "==> Building and signing the release app (make-app.sh)"
AUDIOUT_BUNDLE_DYLIBS=1 CODESIGN_REQUIRE_IDENTITY=1 "$SCRIPT_DIR/make-app.sh" "$OUTPUT_DIR"
test -d "$APP_BUNDLE" || { echo "ERROR: expected app bundle not found at $APP_BUNDLE" >&2; exit 1; }

# --- Zip for notarization -----------------------------------------------------
# ditto -c -k --keepParent, not `zip`: it's what Apple's own notarization docs
# use, and it preserves the bundle's resource forks/extended attributes and
# directory structure exactly (a plain `zip` can silently mangle a signed
# bundle's internal structure).
echo "==> Zipping for notarization: $NOTARIZE_ZIP"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

# --- Notarize ------------------------------------------------------------------
# --wait blocks until Apple's notary service returns a verdict (typically
# minutes). --keychain-profile reads the credentials stored once via
# `xcrun notarytool store-credentials audiout-notary` (docs/RELEASE.md) —
# never inline an Apple ID / app-specific password here.
echo "==> Submitting for notarization (profile: $NOTARY_PROFILE)"
NOTARY_OUTPUT="$(xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || {
  echo "$NOTARY_OUTPUT"
  echo "ERROR: xcrun notarytool submit failed to run (missing profile? see docs/RELEASE.md)" >&2
  exit 1
}
echo "$NOTARY_OUTPUT"
if ! printf '%s\n' "$NOTARY_OUTPUT" | grep -q 'status: Accepted'; then
  echo "ERROR: notarization was NOT accepted — see log above" >&2
  SUBMISSION_ID="$(printf '%s\n' "$NOTARY_OUTPUT" | grep -o 'id: [a-f0-9-]*' | head -1 | awk '{print $2}')"
  if [ -n "$SUBMISSION_ID" ]; then
    echo "==> Fetching notary log for submission $SUBMISSION_ID" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  exit 1
fi

# --- Staple ----------------------------------------------------------------
# Staples the notarization ticket to the .app itself so Gatekeeper can verify
# it offline (no network call needed at the user's first launch).
echo "==> Stapling notarization ticket to $APP_BUNDLE"
xcrun stapler staple "$APP_BUNDLE"

# --- Re-zip the stapled app as the distributable ------------------------------
# The notarization zip above is scratch — the stapled app is the thing that
# ships, so it gets re-zipped fresh under the versioned filename Paddle
# delivers and Sparkle's appcast points at.
echo "==> Zipping distributable: $DIST_ZIP"
rm -f "$DIST_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$DIST_ZIP"

echo "==> Distributable checksum:"
shasum -a 256 "$DIST_ZIP"

echo "==> Done: $DIST_ZIP"
echo "==> REMINDER: run 'scripts/verify-standalone-app.sh \"$APP_BUNDLE\"' by hand before shipping —"
echo "    it proves the bundle launches on a Mac with no Homebrew. Not run automatically (see that"
echo "    script's own header: it moves real Homebrew directories on this machine)."
