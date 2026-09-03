#!/bin/bash
# make-staging.sh — full release rehearsal against the STAGING license server.
# build → sign → notarize → staple → DMG → notarize DMG → staple DMG →
# sign_update → latest-vN.json + appcast-vN.xml → upload to the staging R2
# bucket. Production (make-release.sh) is untouched by anything here: this
# script only ever writes to audiout-releases-staging.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Usage:
#   APP_VERSION=1.0.0 BUILD_NUMBER=2 SPARKLE_ED_PUBLIC_KEY=... scripts/make-staging.sh [output-dir]
#
# Flags (default OFF — the default run mirrors a real buyer end to end):
#   SKIP_NOTARIZE=1  skip both Apple notary waits (fast iteration; the artifact
#                    will NOT pass Gatekeeper on a quarantined download)
#   SKIP_DMG=1       ship the zip as the download instead of building a DMG
#   VERIFY_KEY=<key> after uploading, re-download through the real /download
#                    route with this staging licence key and check the artifact
#                    the way a buyer's Mac will (Gatekeeper, stapled ticket,
#                    /Applications drag target)
#
# razor: steps are NOT parallelized. Each one consumes the previous one's
# output (stapled app → DMG → stapled DMG → EdDSA signature → upload), so
# there is nothing independent to overlap; the per-step timers below show
# where the time actually goes (the two notary waits). Every command is a
# paste-proof one-liner — no backslash continuations.

set -euo pipefail

[ -n "${APP_VERSION:-}" ] || { echo "ERROR: APP_VERSION must be set (e.g. APP_VERSION=1.0.0 BUILD_NUMBER=2 scripts/make-staging.sh)" >&2; exit 1; }
[ -n "${BUILD_NUMBER:-}" ] || { echo "ERROR: BUILD_NUMBER must be set (e.g. APP_VERSION=1.0.0 BUILD_NUMBER=2 scripts/make-staging.sh)" >&2; exit 1; }

# The staging worker, not production — and overridable for a local `wrangler dev`.
export AUDIOUT_LICENSE_URL="${AUDIOUT_LICENSE_URL:-https://license-staging.audiout.app}"
# The buy page is the same in staging and production. Without it the
# first-open gate hides its "Buy Audiout" button — the only way through for
# someone who arrives without a key — which is exactly the state a rehearsal
# must not ship.
export AUDIOUT_BUY_URL="${AUDIOUT_BUY_URL:-https://audiout.app/buy}"
R2_BUCKET="${R2_BUCKET:-audiout-releases-staging}"
# Both release buckets live in the EU jurisdiction. Without -J the uploads
# land in a different (default-jurisdiction) bucket the Worker cannot read.
R2_JURISDICTION="${R2_JURISDICTION:-eu}"
NOTARY_PROFILE="${NOTARY_PROFILE:-audiout-notary}"
WRANGLER="${WRANGLER:-npx --yes wrangler}"
MAJOR="${APP_VERSION%%.*}"
# The license server repo, read only to cross-check CURRENT_MAJOR below.
LICENSE_REPO="${LICENSE_REPO:-$HOME/Projects/Audiout License Server}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/verify-plist-license.sh
. "$SCRIPT_DIR/lib/verify-plist-license.sh"
OUTPUT_DIR="${1:-$REPO_ROOT/build}"
APP_BUNDLE="$OUTPUT_DIR/Audiout.app"
DIST_ZIP="$OUTPUT_DIR/Audiout-${APP_VERSION}.zip"
DIST_DMG="$OUTPUT_DIR/Audiout-${APP_VERSION}.dmg"
SIGN_UPDATE="${SIGN_UPDATE:-$REPO_ROOT/AudioutCore/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
GENERATE_KEYS="${GENERATE_KEYS:-$REPO_ROOT/AudioutCore/.build/artifacts/sparkle/Sparkle/bin/generate_keys}"

# make-app.sh defaults SPARKLE_FEED_URL from AUDIOUT_LICENSE_URL but has no
# default for the public key, and refuses a feed without one — so a run that
# passes neither dies AFTER the build. The private key is already in this
# Mac's keychain; `generate_keys -p` prints its public half, so derive it
# rather than making the caller paste it. Explicit env still wins.
if [ -z "${SPARKLE_ED_PUBLIC_KEY:-}" ] && [ -x "$GENERATE_KEYS" ]; then
  SPARKLE_ED_PUBLIC_KEY="$("$GENERATE_KEYS" -p 2>/dev/null | tr -d '[:space:]')" || true
  [ -n "$SPARKLE_ED_PUBLIC_KEY" ] && export SPARKLE_ED_PUBLIC_KEY && echo "==> [0] Derived SPARKLE_ED_PUBLIC_KEY from the keychain"
fi

# --- Step banners with per-step timing ---------------------------------------
STEP_N=0
STEP_T0=$SECONDS
step() { local now=$SECONDS; [ "$STEP_N" -gt 0 ] && echo "    step $STEP_N took $((now - STEP_T0))s"; STEP_N=$((STEP_N + 1)); STEP_T0=$now; echo "==> [$STEP_N $(date +%H:%M:%S)] $1"; }

# --- Pre-flight: fail in seconds, not after a 10-minute notary wait ----------
step "Pre-flight: major version, signing key, wrangler auth"

# CURRENT_MAJOR (license server) and this build's major must agree. The Worker
# stamps max_major=CURRENT_MAJOR on every new key, and /download then serves
# releases/latest-v<max_major>.json. Drift either way is silent and only hurts
# NEW buyers: ship 2.x while CURRENT_MAJOR is still 1 and their keys can never
# reach it; bump CURRENT_MAJOR to 2 before a v2 release is uploaded and their
# download 404s. Nothing else checks this — the two values live in different
# repos and no endpoint exposes the Worker's copy.
CURRENT_MAJOR="$(sed -n 's|.*"CURRENT_MAJOR"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*|\1|p' "$LICENSE_REPO/wrangler.jsonc" 2>/dev/null | head -1)"
if [ -z "$CURRENT_MAJOR" ]; then
  echo "    WARNING: could not read CURRENT_MAJOR from $LICENSE_REPO/wrangler.jsonc — skipping the major-version cross-check (set LICENSE_REPO to enable it)"
elif [ "$CURRENT_MAJOR" != "$MAJOR" ]; then
  echo "ERROR: this build is major $MAJOR (APP_VERSION=$APP_VERSION) but the license server issues keys with max_major=$CURRENT_MAJOR." >&2
  echo "       Every new key would be entitled to v$CURRENT_MAJOR while /download serves releases/latest-v$MAJOR.json — new buyers get a 404." >&2
  echo "       Set CURRENT_MAJOR=\"$MAJOR\" in $LICENSE_REPO/wrangler.jsonc and redeploy, or build a $CURRENT_MAJOR.x version." >&2
  exit 1
fi
echo "    ok — build major $MAJOR matches the license server's CURRENT_MAJOR"

# Checked HERE because make-app.sh only errors on it after building ffmpeg
# from source and linking the app — minutes of work thrown away.
if [ -z "${SPARKLE_ED_PUBLIC_KEY:-}" ]; then
  echo "ERROR: SPARKLE_ED_PUBLIC_KEY is unset and could not be derived — build AudioutCore once so SwiftPM fetches Sparkle's generate_keys, or pass the key explicitly. make-app.sh defaults the feed URL and then refuses a feed with no key, so this run would fail after the build." >&2
  exit 1
fi
$WRANGLER whoami >/dev/null 2>&1 || { echo "ERROR: wrangler is not authenticated — run 'npx wrangler login' first" >&2; exit 1; }

# --- Build the artifact -------------------------------------------------------
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  # Fast path: build + sign + zip, no Apple round-trips. make-release.sh is
  # bypassed entirely because notarization is its whole point.
  step "Build + sign (make-app.sh, NOTARIZATION SKIPPED)"
  AUDIOUT_BUNDLE_DYLIBS=1 "$SCRIPT_DIR/make-app.sh" "$OUTPUT_DIR"
  test -d "$APP_BUNDLE" || { echo "ERROR: expected app bundle not found at $APP_BUNDLE" >&2; exit 1; }
  rm -f "$DIST_ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$DIST_ZIP"
else
  # Real path: make-release.sh does build → notarize → staple → zip, plus its
  # own pre-flight that the feed URL above answers as the license server.
  step "Build + notarize + staple + zip (make-release.sh, against $AUDIOUT_LICENSE_URL)"
  "$SCRIPT_DIR/make-release.sh" "$OUTPUT_DIR"
fi

# --- DMG ----------------------------------------------------------------------
if [ "${SKIP_DMG:-0}" = "1" ]; then
  DIST_FILE="$DIST_ZIP"
  ENCLOSURE_TYPE="application/zip"
else
  step "Create + sign DMG"
  DMG_STAGE="$OUTPUT_DIR/dmg-stage"
  rm -rf "$DMG_STAGE" "$DIST_DMG"
  mkdir -p "$DMG_STAGE"
  cp -R "$APP_BUNDLE" "$DMG_STAGE/"
  ln -s /Applications "$DMG_STAGE/Applications"
  hdiutil create -volname "Audiout" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DIST_DMG" -quiet
  rm -rf "$DMG_STAGE"
  # Same auto-detection as make-app.sh; ad-hoc only if notarization is off.
  DMG_IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)}"
  if [ -z "$DMG_IDENTITY" ]; then
    [ "${SKIP_NOTARIZE:-0}" = "1" ] || { echo "ERROR: no Developer ID Application identity in the keychain — the DMG could not be notarized" >&2; exit 1; }
    DMG_IDENTITY="-"
  fi
  codesign --force --sign "$DMG_IDENTITY" "$DIST_DMG"

  if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    step "Notarize + staple DMG (Apple wait, typically minutes)"
    NOTARY_OUTPUT="$(xcrun notarytool submit "$DIST_DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || { echo "$NOTARY_OUTPUT" >&2; echo "ERROR: notarytool submit failed for the DMG" >&2; exit 1; }
    echo "$NOTARY_OUTPUT" | grep -q "status: Accepted" || { echo "$NOTARY_OUTPUT" >&2; SUBMISSION_ID="$(echo "$NOTARY_OUTPUT" | grep -m1 '  id:' | awk '{print $2}')"; [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2; echo "ERROR: DMG notarization was not Accepted" >&2; exit 1; }
    xcrun stapler staple "$DIST_DMG"
  fi
  DIST_FILE="$DIST_DMG"
  ENCLOSURE_TYPE="application/x-apple-diskimage"
fi
DIST_NAME="$(basename "$DIST_FILE")"

# --- latest-vN.json + appcast-vN.xml -----------------------------------------
# latest-vN.json is THE pointer /download serves from — flipping it is what
# "publishing" means. The appcast carries only this release: staging rehearses
# the newest update, and regenerating history would need every old artifact's
# signature for no test value.
step "Write latest-v$MAJOR.json + appcast-v$MAJOR.xml"
printf '{"version": "%s", "file": "releases/%s"}\n' "$APP_VERSION" "$DIST_NAME" > "$OUTPUT_DIR/latest-v$MAJOR.json"

# A missing or unsignable appcast is fatal on a real run — an update channel
# that cannot verify signatures is worse than none. On a SKIP_NOTARIZE
# rehearsal it is only a warning: that run exists to prove the upload path,
# and its unnotarised artifact was never going to update anyone anyway.
APPCAST="$OUTPUT_DIR/appcast-v$MAJOR.xml"
REHEARSAL="${SKIP_NOTARIZE:-0}"
if [ ! -x "$SIGN_UPDATE" ]; then
  [ "$REHEARSAL" = "1" ] || { echo "ERROR: sign_update not found at $SIGN_UPDATE — build AudioutCore once so SwiftPM fetches the Sparkle artifact, or set SIGN_UPDATE. Without it this release has no verifiable update feed." >&2; exit 1; }
  echo "    WARNING: sign_update not found at $SIGN_UPDATE — skipping the appcast (rehearsal only; /download is still exercised)"
  APPCAST=""
elif ! SIG_ATTRS="$("$SIGN_UPDATE" "$DIST_FILE" 2>&1)"; then
  [ "$REHEARSAL" = "1" ] || { echo "ERROR: sign_update failed — is the Sparkle EdDSA private key in this Mac's keychain? (docs/RELEASE.md §c)" >&2; echo "$SIG_ATTRS" >&2; exit 1; }
  echo "    WARNING: sign_update failed (no EdDSA private key in the keychain?) — skipping the appcast (rehearsal only)"
  APPCAST=""
else
  # sign_update signs the FINAL bytes (post-staple) and prints the exact
  # attribute pair the enclosure needs: sparkle:edSignature="..." length="..."
  { printf '<?xml version="1.0" encoding="utf-8"?>\n'; printf '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'; printf '<channel><title>Audiout v%s updates (STAGING)</title>\n' "$MAJOR"; printf '<item><title>%s</title>\n' "$APP_VERSION"; printf '<sparkle:version>%s</sparkle:version>\n' "$BUILD_NUMBER"; printf '<sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$APP_VERSION"; printf '<sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>\n'; printf '<enclosure url="%s/download" %s type="%s"/>\n' "$AUDIOUT_LICENSE_URL" "$SIG_ATTRS" "$ENCLOSURE_TYPE"; printf '</item></channel></rss>\n'; } > "$APPCAST"
fi

# --- Upload -------------------------------------------------------------------
step "Upload to R2 bucket $R2_BUCKET"
# --remote is NOT optional: without it wrangler writes to the local .wrangler
# simulator and still prints "Upload complete", so the release silently never
# leaves this Mac. The only visible tell is a "Resource location: local" line.
$WRANGLER r2 object put "$R2_BUCKET/releases/$DIST_NAME" --file "$DIST_FILE" -J "$R2_JURISDICTION" --remote
$WRANGLER r2 object put "$R2_BUCKET/releases/latest-v$MAJOR.json" --file "$OUTPUT_DIR/latest-v$MAJOR.json" -J "$R2_JURISDICTION" --remote
[ -n "$APPCAST" ] && $WRANGLER r2 object put "$R2_BUCKET/appcast-v$MAJOR.xml" --file "$APPCAST" -J "$R2_JURISDICTION" --remote

# --- Verify what a buyer will actually receive --------------------------------
# Set VERIFY_KEY to an active staging licence key and this re-downloads the
# artifact through the real /download route and checks it the way the buyer's
# Mac will: Gatekeeper's verdict, the stapled notarisation ticket (so first
# launch works offline), and the /Applications symlink that makes the install
# a drag rather than a puzzle. Everything here is what the buyer's DOUBLE-CLICK
# depends on; the drag itself is their gesture, not a build step.
if [ -n "${VERIFY_KEY:-}" ]; then
  step "Verify the published artifact end to end"
  VERIFY_DIR="$OUTPUT_DIR/verify"
  rm -rf "$VERIFY_DIR"; mkdir -p "$VERIFY_DIR"
  VERIFY_FILE="$VERIFY_DIR/$DIST_NAME"

  HTTP_CODE="$(curl -sS -w '%{http_code}' -o "$VERIFY_FILE" --max-time 300 "$AUDIOUT_LICENSE_URL/download?key=$VERIFY_KEY")" || { echo "ERROR: /download request failed outright" >&2; exit 1; }
  [ "$HTTP_CODE" = "200" ] || { echo "ERROR: /download answered HTTP $HTTP_CODE, expected 200 — the buyer would get nothing" >&2; head -c 200 "$VERIFY_FILE" >&2; echo >&2; exit 1; }
  echo "    ok — /download served HTTP 200"

  # Byte-identical to what was uploaded, so R2 is serving this build.
  [ "$(shasum -a 256 < "$VERIFY_FILE" | cut -d' ' -f1)" = "$(shasum -a 256 < "$DIST_FILE" | cut -d' ' -f1)" ] || { echo "ERROR: downloaded bytes differ from the uploaded artifact" >&2; exit 1; }
  echo "    ok — bytes match the uploaded artifact"

  if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    xcrun stapler validate "$VERIFY_FILE" >/dev/null 2>&1 || { echo "ERROR: no stapled notarisation ticket — a buyer with no network gets a Gatekeeper block on first launch" >&2; exit 1; }
    echo "    ok — notarisation ticket is stapled"
  fi

  if [ "${SKIP_DMG:-0}" != "1" ]; then
    MOUNT_DIR="$VERIFY_DIR/mnt"; mkdir -p "$MOUNT_DIR"
    hdiutil attach "$VERIFY_FILE" -mountpoint "$MOUNT_DIR" -nobrowse -quiet -readonly || { echo "ERROR: the DMG would not mount" >&2; exit 1; }
    # Always unmount, even if a check below fails.
    trap 'hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true' EXIT
    [ -d "$MOUNT_DIR/Audiout.app" ] || { echo "ERROR: no Audiout.app at the root of the DMG — Sparkle and the buyer both look for it there" >&2; exit 1; }
    verify_app_plist_license_url "$MOUNT_DIR/Audiout.app" "$AUDIOUT_LICENSE_URL" || exit 1
    echo "    ok — Info.plist AudioutLicenseServerURL matches $AUDIOUT_LICENSE_URL"
    [ -L "$MOUNT_DIR/Applications" ] || { echo "ERROR: no /Applications symlink in the DMG — the buyer has no drag target and is likely to run it from Downloads, where translocation breaks the PTP helper's bundle path" >&2; exit 1; }
    echo "    ok — Audiout.app and the /Applications drag target are both present"

    if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
      # The verdict Gatekeeper itself gives the app the buyer drags out.
      spctl -a -t exec -vv "$MOUNT_DIR/Audiout.app" 2>&1 | grep -q "accepted" || { echo "ERROR: Gatekeeper rejects the app inside the DMG" >&2; spctl -a -t exec -vv "$MOUNT_DIR/Audiout.app" 2>&1 >&2; exit 1; }
      echo "    ok — Gatekeeper accepts the app inside the DMG"
    fi
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    trap - EXIT
  fi
  rm -rf "$VERIFY_DIR"
fi

step "Done"
shasum -a 256 "$DIST_FILE"
if [ -n "${VERIFY_KEY:-}" ]; then
  echo "    Verified through $AUDIOUT_LICENSE_URL/download — this is what a buyer receives."
else
  echo "    Try it: $AUDIOUT_LICENSE_URL/download?key=<a staging key> should now stream $DIST_NAME"
  echo "    Or re-run with VERIFY_KEY=<staging key> to have this script check that automatically."
fi
