#!/bin/bash
# publish-release.sh — put a finished release into R2, in two separate events:
# `upload` (nothing changes for anyone) then `promote` (it becomes reachable).
# Sibling of make-release.sh, which builds/notarises/staples the zip this script
# publishes. This script never builds, signs or notarises anything.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# WHY TWO MODES: a release is three independent objects in R2, and the license
# server reads them independently —
#
#   releases/Audiout-<version>.zip   GET /download streams it. Present but
#                                    unreferenced = invisible to everyone.
#   releases/latest-vN.json          GET /download resolves the current build
#                                    for the key's major. Flipping it = new
#                                    buyers get the new build. Reversible.
#   appcast-vN.xml                   GET /appcast.xml serves it to Sparkle.
#                                    Adding the <item> = every installed copy
#                                    gets the update. One-way.
#
# So uploading the zip and leaving it unreferenced is a staged release at zero
# exposure: you can smoke-test it, sit on it for a week, or overwrite it, and
# no user's copy of the app can tell. `promote` is the separate, deliberate act
# that makes it reachable. Doing it the other way round — an appcast item
# pointing at a zip that is not in R2 yet — makes EVERY running copy of the app
# show a failed update.
#
# Usage:
#   APP_VERSION=1.0.0 scripts/publish-release.sh upload
#   APP_VERSION=1.0.0 SPARKLE_ED_SIGNATURE="<sign_update output>" scripts/publish-release.sh promote --verified-standalone
#
# Every command below is a paste-proof one-liner — no backslash continuations.
#
# See docs/RELEASE.md for the full runbook, including the manual steps this
# script deliberately does NOT automate: Sparkle's sign_update (the private key
# stays in the keychain) and scripts/verify-standalone-app.sh (it moves real
# Homebrew directories, so it stays a human decision).

set -euo pipefail

# --- Config -----------------------------------------------------------------
# The one bucket everything lives in. Note the "er": audioutER-releases.
R2_BUCKET="${R2_BUCKET:-audiouter-releases}"

# Sparkle enclosure URL. Always the license server's gated /download — never a
# direct R2 or GitHub URL, because the whole paid-distribution model is that
# the server decides which file a key is entitled to. Sparkle sends the key as
# a bearer header on the enclosure fetch, so one URL serves every version.
ENCLOSURE_URL="${ENCLOSURE_URL:-https://license.audiout.app/download}"

# Seconds between Sparkle's rollout groups. Sparkle uses seven hardcoded
# groups, so 86400 spreads an update over roughly a week — one group per day
# after the item's pubDate. Manual "Check for Updates…" bypasses it entirely.
PHASED_ROLLOUT_INTERVAL="${PHASED_ROLLOUT_INTERVAL:-86400}"

# --- Paths --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Arguments ----------------------------------------------------------------
MODE="${1:-}"
if [ "$MODE" != "upload" ] && [ "$MODE" != "promote" ]; then
  echo "ERROR: first argument must be 'upload' or 'promote' (got: '${MODE:-<none>}')" >&2
  echo "  APP_VERSION=1.0.0 scripts/publish-release.sh upload" >&2
  echo "  APP_VERSION=1.0.0 SPARKLE_ED_SIGNATURE=... scripts/publish-release.sh promote --verified-standalone" >&2
  exit 1
fi
shift

# promote-only flags. Parsed for both modes so that passing one to `upload` is
# an obvious error rather than a silently ignored argument.
VERIFIED_STANDALONE=0
SIGNATURE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verified-standalone) VERIFIED_STANDALONE=1 ;;
    --signature) shift; SIGNATURE_ARG="${1:-}" ;;
    --signature=*) SIGNATURE_ARG="${1#--signature=}" ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift
done

# APP_VERSION is REQUIRED, like make-release.sh — every object key, the appcast
# item and the git tag check are derived from it, so a defaulted value would
# publish under a filename nobody meant.
if [ -z "${APP_VERSION:-}" ]; then
  echo "ERROR: APP_VERSION must be set (e.g. APP_VERSION=1.0.0 scripts/publish-release.sh $MODE)" >&2
  exit 1
fi

# N is DERIVED from APP_VERSION's major, never taken as a second input: two
# inputs that have to agree is a bug waiting to happen, and getting it wrong
# writes the release into the wrong major's feed.
MAJOR="${APP_VERSION%%.*}"
case "$MAJOR" in
  ''|*[!0-9]*) echo "ERROR: APP_VERSION='$APP_VERSION' does not start with a numeric major version" >&2; exit 1 ;;
esac

DIST_ZIP="$REPO_ROOT/build/Audiout-${APP_VERSION}.zip"
ZIP_KEY="releases/Audiout-${APP_VERSION}.zip"
LATEST_KEY="releases/latest-v${MAJOR}.json"
APPCAST_KEY="appcast-v${MAJOR}.xml"

# --- wrangler -----------------------------------------------------------------
# Prefer a global wrangler; fall back to npx. Either way it uses the OAuth login
# already on this Mac — no API token is read, held or written by this script.
if command -v wrangler >/dev/null 2>&1; then
  WRANGLER=(wrangler)
else
  WRANGLER=(npx --yes wrangler)
fi

# --- Scratch ------------------------------------------------------------------
WORK_DIR="$(mktemp -d -t audiout-publish)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ==============================================================================
# upload
# ==============================================================================
if [ "$MODE" = "upload" ]; then
  echo "==> Mode: upload (nothing becomes reachable — see promote)"

  # Guard 1 — the artifact exists. Nothing else is worth checking without it.
  test -f "$DIST_ZIP" || { echo "ERROR: no distributable at $DIST_ZIP — run 'APP_VERSION=$APP_VERSION BUILD_NUMBER=<n> scripts/make-release.sh' first" >&2; exit 1; }

  # Guard 2 — the git tag is the single source of truth for what a version IS.
  # Without this the tag, APP_VERSION and the appcast item can all disagree and
  # nothing catches it until a user reports the wrong build.
  EXACT_TAG="$(git -C "$REPO_ROOT" describe --tags --exact-match 2>/dev/null || true)"
  if [ "$EXACT_TAG" != "v$APP_VERSION" ]; then
    echo "ERROR: HEAD is not tagged 'v$APP_VERSION' (git describe --tags --exact-match says: '${EXACT_TAG:-<untagged>}')" >&2
    echo "  Tag the commit you are publishing: git tag v$APP_VERSION && git push origin v$APP_VERSION" >&2
    exit 1
  fi
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    echo "ERROR: working tree is dirty — the tag would not describe what is being published" >&2
    git -C "$REPO_ROOT" status --short >&2
    exit 1
  fi

  # Guard 3 — the zip in build/ is genuinely notarised AND stapled. make-release.sh
  # staples, but build/ is not cleaned between runs, so the zip sitting there can
  # be a stale artifact from an earlier attempt. `stapler validate` costs a second
  # and catches the whole class of "shipped the wrong artifact" mistakes — it
  # fails both when no ticket is attached and when the ticket does not match the
  # bundle's current code directory. (`spctl -a -vvv -t install` answers the same
  # question from Gatekeeper's side if you ever need a second opinion by hand.)
  echo "==> Verifying notarization ticket is stapled to the app inside the zip"
  ditto -x -k "$DIST_ZIP" "$WORK_DIR/extracted"
  STAPLED_APP="$(find "$WORK_DIR/extracted" -maxdepth 2 -name '*.app' -print -quit)"
  test -n "$STAPLED_APP" || { echo "ERROR: no .app bundle found inside $DIST_ZIP" >&2; exit 1; }
  xcrun stapler validate "$STAPLED_APP" || { echo "ERROR: $DIST_ZIP is not notarised+stapled — do NOT publish it (rebuild with scripts/make-release.sh)" >&2; exit 1; }

  # The upload itself. This is the whole mutation: one object nothing references.
  echo "==> Uploading $ZIP_KEY to r2://$R2_BUCKET"
  "${WRANGLER[@]}" r2 object put "$R2_BUCKET/$ZIP_KEY" --file "$DIST_ZIP"

  echo "==> Uploaded checksum:"
  shasum -a 256 "$DIST_ZIP"
  echo
  echo "==> Done. NOTHING is reachable yet: latest-v${MAJOR}.json and $APPCAST_KEY are untouched,"
  echo "    so /download still resolves the previous build and Sparkle sees no new item."
  echo "    Next: run scripts/verify-standalone-app.sh by hand, smoke-test, then:"
  echo "      APP_VERSION=$APP_VERSION SPARKLE_ED_SIGNATURE=\"<sign_update output>\" scripts/publish-release.sh promote --verified-standalone"
  exit 0
fi

# ==============================================================================
# promote
# ==============================================================================
echo "==> Mode: promote (this makes the release reachable)"

# Guard 1 — the acknowledgement. verify-standalone-app.sh proves the bundle
# launches on a Mac with no Homebrew, and it is the one launch check the runbook
# calls for. It is NOT invoked from here on purpose: it moves real Homebrew
# directories on this machine, so it stays a deliberate human action. All this
# script can do is refuse to promote until you say you ran it.
if [ "$VERIFIED_STANDALONE" != "1" ]; then
  echo "ERROR: pass --verified-standalone to confirm you have run 'scripts/verify-standalone-app.sh' by hand on this build" >&2
  echo "  That script proves the app launches with Homebrew unreachable. It is not run automatically — it moves real directories on this Mac." >&2
  exit 1
fi

# Guard 2 — the Sparkle signature comes from outside. The EdDSA private key
# lives in the keychain and `sign_update` is run by hand (docs/RELEASE.md step
# c/e); this script must never hold, read or derive it.
ED_SIGNATURE="${SIGNATURE_ARG:-${SPARKLE_ED_SIGNATURE:-}}"
if [ -z "$ED_SIGNATURE" ]; then
  echo "ERROR: the Sparkle EdDSA signature is required — set SPARKLE_ED_SIGNATURE or pass --signature '<value>'" >&2
  echo "  Produce it by hand: ./bin/sign_update \"$DIST_ZIP\"   (Sparkle's tool; the private key never leaves your keychain)" >&2
  exit 1
fi

# Guard 3 — the local zip, needed for the appcast item's length and versions.
test -f "$DIST_ZIP" || { echo "ERROR: no local copy at $DIST_ZIP — promote reads the appcast item's byte length and versions from it" >&2; exit 1; }

# Guard 4 — THE ORDERING GUARD, and the reason this script exists. If the zip
# is not in R2, an appcast item pointing at it makes every installed copy of
# the app show a failed update.
echo "==> Confirming $ZIP_KEY is already in r2://$R2_BUCKET"
"${WRANGLER[@]}" r2 object get "$R2_BUCKET/$ZIP_KEY" --pipe > "$WORK_DIR/remote.zip" 2>"$WORK_DIR/get.err" || { cat "$WORK_DIR/get.err" >&2; echo "ERROR: $ZIP_KEY is not in r2://$R2_BUCKET — run 'APP_VERSION=$APP_VERSION scripts/publish-release.sh upload' first" >&2; exit 1; }
test -s "$WORK_DIR/remote.zip" || { echo "ERROR: $ZIP_KEY read back empty from r2://$R2_BUCKET" >&2; exit 1; }

# ...and it is byte-identical to the local copy, because the appcast item's
# length and version fields are read from the local one. A mismatch means the
# appcast would describe a file the server does not serve.
LOCAL_SHA="$(shasum -a 256 "$DIST_ZIP" | awk '{print $1}')"
REMOTE_SHA="$(shasum -a 256 "$WORK_DIR/remote.zip" | awk '{print $1}')"
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  echo "ERROR: the object in R2 differs from $DIST_ZIP (local $LOCAL_SHA vs remote $REMOTE_SHA)" >&2
  echo "  Re-run upload with the artifact you actually mean to ship, or fetch the shipped one locally." >&2
  exit 1
fi

# Guard 5 — versions come from the artifact's own Info.plist, not from a second
# input the caller could get wrong. CFBundleShortVersionString must agree with
# APP_VERSION; CFBundleVersion is what Sparkle actually compares.
ditto -x -k "$DIST_ZIP" "$WORK_DIR/extracted"
PROMOTE_APP="$(find "$WORK_DIR/extracted" -maxdepth 2 -name '*.app' -print -quit)"
test -n "$PROMOTE_APP" || { echo "ERROR: no .app bundle found inside $DIST_ZIP" >&2; exit 1; }
INFO_PLIST="$PROMOTE_APP/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"
test -n "$SHORT_VERSION" || { echo "ERROR: could not read CFBundleShortVersionString from $INFO_PLIST" >&2; exit 1; }
test -n "$BUNDLE_VERSION" || { echo "ERROR: could not read CFBundleVersion from $INFO_PLIST" >&2; exit 1; }
if [ "$SHORT_VERSION" != "$APP_VERSION" ]; then
  echo "ERROR: the built app says CFBundleShortVersionString=$SHORT_VERSION but APP_VERSION=$APP_VERSION" >&2
  exit 1
fi

ZIP_LENGTH="$(stat -f%z "$DIST_ZIP")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# --- Fetch the existing appcast (if any) --------------------------------------
# Absent is normal for the first release of a major; anything else is the feed
# already live for every installed copy, so the new item is PREPENDED to it and
# nothing existing is rewritten.
echo "==> Fetching current $APPCAST_KEY from r2://$R2_BUCKET (absent is fine for a first release)"
if "${WRANGLER[@]}" r2 object get "$R2_BUCKET/$APPCAST_KEY" --pipe > "$WORK_DIR/appcast-old.xml" 2>/dev/null && [ -s "$WORK_DIR/appcast-old.xml" ]; then
  echo "    found existing feed ($(wc -c < "$WORK_DIR/appcast-old.xml" | tr -d ' ') bytes)"
else
  echo "    none found — a fresh feed skeleton will be created"
  rm -f "$WORK_DIR/appcast-old.xml"
fi

# Guard 6 — never publish the same version twice. Sparkle would offer whichever
# item it parsed first; more to the point, a second item means somebody is
# re-promoting a version whose signature or length may no longer match.
if [ -f "$WORK_DIR/appcast-old.xml" ] && grep -q "<sparkle:shortVersionString>${APP_VERSION}</sparkle:shortVersionString>" "$WORK_DIR/appcast-old.xml"; then
  echo "ERROR: $APPCAST_KEY already has an item for $APP_VERSION — refusing to add a second one" >&2
  echo "  To replace it, edit the feed by hand and re-put it; that is a rollback, not a promote." >&2
  exit 1
fi

# --- 1. latest-vN.json FIRST --------------------------------------------------
# ORDER MATTERS, and this is the whole point of the script: downloads before
# updates. latest-vN.json only affects NEW downloads, and it points at an object
# already proven present above — so if the appcast put below fails, new buyers
# still get a working download and no installed copy is broken. The reverse
# order can leave Sparkle offering an update the server cannot serve.
printf '{"version": "%s", "file": "%s"}\n' "$APP_VERSION" "$ZIP_KEY" > "$WORK_DIR/latest.json"
echo "==> Putting $LATEST_KEY (new downloads resolve to $APP_VERSION from here on)"
"${WRANGLER[@]}" r2 object put "$R2_BUCKET/$LATEST_KEY" --file "$WORK_DIR/latest.json" --content-type application/json

# --- 2. appcast-vN.xml SECOND -------------------------------------------------
# This is the one-way step: a copy that has already updated cannot be rolled
# back by editing XML. phasedRolloutInterval is what limits the blast radius.
ITEM_TITLE="$APP_VERSION"
python3 - "$WORK_DIR" "$APPCAST_KEY" "$MAJOR" "$ITEM_TITLE" "$PUB_DATE" "$BUNDLE_VERSION" "$SHORT_VERSION" "$PHASED_ROLLOUT_INTERVAL" "$ENCLOSURE_URL" "$ZIP_LENGTH" "$ED_SIGNATURE" <<'PY'
import html, os, sys

work, appcast_key, major, title, pub_date, bundle_version, short_version, interval, url, length, signature = sys.argv[1:12]
old_path = os.path.join(work, "appcast-old.xml")

# Deliberately string surgery, not an XML library: the live feed is hand-edited
# during a rollback, and a round-trip through a parser would reflow every
# existing item and make that diff unreadable.
item = (
    "    <item>\n"
    f"      <title>{html.escape(title)}</title>\n"
    f"      <pubDate>{html.escape(pub_date)}</pubDate>\n"
    f"      <sparkle:version>{html.escape(bundle_version)}</sparkle:version>\n"
    f"      <sparkle:shortVersionString>{html.escape(short_version)}</sparkle:shortVersionString>\n"
    f"      <sparkle:phasedRolloutInterval>{html.escape(interval)}</sparkle:phasedRolloutInterval>\n"
    f'      <enclosure url="{html.escape(url, quote=True)}" length="{html.escape(length)}" type="application/octet-stream" sparkle:edSignature="{html.escape(signature, quote=True)}" />\n'
    "    </item>\n"
)

if os.path.exists(old_path):
    with open(old_path, encoding="utf-8") as handle:
        feed = handle.read()
    # Newest first: before the first existing <item>, else before </channel>.
    anchor = feed.find("<item>")
    if anchor == -1:
        anchor = feed.find("</channel>")
    if anchor == -1:
        sys.exit(f"ERROR: {appcast_key} in R2 has no <item> and no </channel> — refusing to guess where the new item goes")
    line_start = feed.rfind("\n", 0, anchor) + 1
    feed = feed[:line_start] + item + feed[line_start:]
else:
    feed = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        "  <channel>\n"
        "    <title>Audiout</title>\n"
        f"    <description>Audiout {major}.x updates</description>\n"
        "    <language>en</language>\n"
        f"{item}"
        "  </channel>\n"
        "</rss>\n"
    )

with open(os.path.join(work, "appcast-new.xml"), "w", encoding="utf-8") as handle:
    handle.write(feed)
PY

echo "==> Putting $APPCAST_KEY (installed copies begin seeing $APP_VERSION — this step is one-way)"
"${WRANGLER[@]}" r2 object put "$R2_BUCKET/$APPCAST_KEY" --file "$WORK_DIR/appcast-new.xml" --content-type application/xml

echo
echo "==> Promoted $APP_VERSION (build $BUNDLE_VERSION)."
echo "    /download now resolves to $ZIP_KEY; Sparkle offers it over ~$(( PHASED_ROLLOUT_INTERVAL * 7 / 86400 )) days (7 groups x ${PHASED_ROLLOUT_INTERVAL}s)."
echo "    Manual 'Check for Updates…' bypasses the phasing and gets it immediately."
echo "    Rollback: re-put the previous $LATEST_KEY and remove this item from $APPCAST_KEY."
