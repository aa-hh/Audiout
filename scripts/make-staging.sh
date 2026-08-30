#!/bin/bash
# make-staging.sh — build the app wired to the STAGING licence server, as a
# standing side-by-side install. The staging sibling of make-release.sh.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# What this exists for: the licence gate, the purchase return link and the
# "I lost my key" resend all talk to a server, and none of them can be
# exercised by a bare `swift run` (no Info.plist, so no licence URL, so the
# whole surface stays hidden). Before this script that meant hand-assembling
# five env vars and rediscovering two non-obvious requirements every time —
# the Sparkle key pair and an explicit BUILD_NUMBER. Now it is one command.
#
# Usage: bash scripts/make-staging.sh [output-dir]   (default: ./build)
#
# Env (all optional — the defaults ARE the staging environment):
#   AUDIOUT_LICENSE_URL      staging licence server
#   AUDIOUT_BUY_URL          where "Buy Audiout…" sends the user
#   SPARKLE_ED_PUBLIC_KEY    EdDSA public key; derived from Sparkle's own
#                            generate_keys when unset (reads YOUR keychain)
#   BUILD_NUMBER             defaults to a timestamp, so it always climbs.
#                            Set it LOW to make the staging appcast offer an
#                            update — that is how you test the updater.
#   APP_NAME / BUNDLE_ID     override to build a throwaway id instead
#   plus anything make-app.sh takes (AUDIOUT_BUILD_LOCAL, AUDIOUT_BUNDLE_DYLIBS…)
#
# Every command below is a paste-proof one-liner — no backslash continuations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/build}"

# --- Identity ---------------------------------------------------------------
# A dedicated, STABLE id — deliberately neither the shipping id nor the shared
# dev id.
#
# Not the shipping id (com.audiout.Audiout): that is the /Applications copy,
# and a staging build must never replace the real one.
#
# Not the dev id (com.audiout.Audiout.dev): that one is gated by the live-test
# slot because a rebuild clobbers whatever another agent is testing. Staging is
# its own bundle and its own launchd daemon identity, so it cannot clobber the
# dev build and needs no slot — you can build this while someone else holds it.
#
# Stable rather than fresh-per-build on purpose: macOS pins TCC grants and the
# Login Items approval to the bundle id, so one id means ONE round of
# permission clicks, ever, and every later staging build is silent. A fresh id
# each time would re-nag and pile up dead Privacy & Security rows (the reason
# scripts/purge-dev-installs.sh exists). Cost: one first-run approval pass.
APP_NAME="${APP_NAME:-Audiout Staging}"
BUNDLE_ID="${BUNDLE_ID:-com.audiout.Audiout.staging}"

# --- The staging environment ------------------------------------------------
# The licence server this build validates keys against, resends keys from, and
# derives its appcast from. Unlike a release, getting this wrong costs nothing
# permanent — nobody is shipped a staging build — so these are defaults, not
# hard requirements.
AUDIOUT_LICENSE_URL="${AUDIOUT_LICENSE_URL:-https://license-staging.audiout.app}"
# NOTE: the staging site sits behind Cloudflare Access, so this link opens a
# login wall first unless the browser already holds an Access session. That is
# staging being staging, not a bug in the gate — point this at another URL if
# you want the buy affordance to land somewhere open.
AUDIOUT_BUY_URL="${AUDIOUT_BUY_URL:-https://staging.audiout.app/buy}"

# CFBundleVersion must climb for Sparkle to reason about updates, and a staging
# build is rebuilt constantly, so a timestamp is the one default that is always
# unique and always increasing without anybody tracking a counter.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%y%m%d%H%M)}"

# --- Sparkle key ------------------------------------------------------------
# make-app.sh refuses a feed with no key (an unverified update channel), and
# the public half lives in Sparkle's own keychain item rather than this repo.
# Ask Sparkle for it rather than hardcoding a copy that can silently go stale
# if the pair is ever rotated. `generate_keys -p` prints the PUBLIC key only.
if [ -z "${SPARKLE_ED_PUBLIC_KEY:-}" ]; then
  GENERATE_KEYS="$(find "$REPO_ROOT/AudioutCore/.build/artifacts" -name generate_keys -type f 2>/dev/null | head -1 || true)"
  if [ -n "$GENERATE_KEYS" ]; then
    SPARKLE_ED_PUBLIC_KEY="$("$GENERATE_KEYS" -p 2>/dev/null | tail -1 || true)"
  fi
fi
if [ -z "${SPARKLE_ED_PUBLIC_KEY:-}" ]; then
  echo "ERROR: no Sparkle EdDSA public key." >&2
  echo "       It normally comes from Sparkle's generate_keys, which needs the SwiftPM" >&2
  echo "       artifacts present — run 'bash scripts/build.sh' once, then retry." >&2
  echo "       Or pass it yourself: SPARKLE_ED_PUBLIC_KEY=... bash scripts/make-staging.sh" >&2
  exit 1
fi

SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$AUDIOUT_LICENSE_URL/appcast.xml}"

# --- Pre-flight -------------------------------------------------------------
# Same check make-release.sh runs, for the same reason and at a fifth of the
# stakes: prove the URL about to be baked in really is the licence server
# before spending a two-minute build on it. Unauthenticated, the appcast
# answers 401 "licence key required" — anything else means the Worker is not
# deployed, or another route is shadowing the hostname.
echo "==> Pre-flight: $SPARKLE_FEED_URL must answer as the licence server"
FEED_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$SPARKLE_FEED_URL")" || FEED_CURL_EXIT=$?
if [ -n "${FEED_CURL_EXIT:-}" ]; then
  echo "ERROR: could not reach $SPARKLE_FEED_URL — curl exited $FEED_CURL_EXIT (6 = hostname did not resolve, 28 = timed out)." >&2
  echo "       Check your connection and that the staging Worker is deployed, then re-run." >&2
  exit 1
fi
if [ "$FEED_STATUS" != "401" ]; then
  echo "ERROR: $SPARKLE_FEED_URL answered HTTP $FEED_STATUS, expected 401 (licence key required)." >&2
  echo "       The staging Worker may not be deployed, or a Cloudflare route is shadowing the hostname." >&2
  exit 1
fi
echo "    ok — 401 licence key required"

# --- Build ------------------------------------------------------------------
echo "==> Building $APP_NAME ($BUNDLE_ID), build $BUILD_NUMBER, against $AUDIOUT_LICENSE_URL"
APP_NAME="$APP_NAME" BUNDLE_ID="$BUNDLE_ID" BUILD_NUMBER="$BUILD_NUMBER" AUDIOUT_LICENSE_URL="$AUDIOUT_LICENSE_URL" AUDIOUT_BUY_URL="$AUDIOUT_BUY_URL" SPARKLE_FEED_URL="$SPARKLE_FEED_URL" SPARKLE_ED_PUBLIC_KEY="$SPARKLE_ED_PUBLIC_KEY" "$SCRIPT_DIR/make-app.sh" "$OUTPUT_DIR"

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
test -d "$APP_BUNDLE" || { echo "ERROR: expected app bundle not found at $APP_BUNDLE" >&2; exit 1; }

# --- How to drive it --------------------------------------------------------
# The gate only presents itself when the install is unregistered, so a build
# that has already been registered once shows nothing on the next launch.
# AUDIOUT_LICENSE_GATE=force is what re-opens it, and it only works when the
# binary is launched directly (LaunchServices does not carry the caller's
# environment into an `open`ed bundle).
echo ""
echo "==> Done: $APP_BUNDLE"
echo ""
echo "    Run it (gate forced, permissions flow skipped, no hardware needed):"
echo "      AUDIOUT_LICENSE_GATE=force AIRPLAY_SETUP=skip AIRPLAY_BACKEND=mock \"$APP_BUNDLE/Contents/MacOS/Audiout\""
echo ""
echo "    Run it as a user would (real backend, real first-run flow):"
echo "      open \"$APP_BUNDLE\""
echo ""
echo "    Forget the stored key to get a virgin gate back:"
echo "      defaults delete $BUNDLE_ID license.key"
