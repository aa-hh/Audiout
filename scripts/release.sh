#!/bin/bash
# release.sh — cut a live release. One command, from main, start to finish:
#
#   build → sign → notarize → staple → DMG → notarize DMG → staple DMG →
#   sign_update → latest-vN.json + appcast-vN.xml → upload to the live R2 bucket
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Usage:
#   scripts/release.sh 1.0.1                       # publish
#   VERIFY_KEY=AUDT-... scripts/release.sh 1.0.1   # publish, then re-download
#                                                  # through /download and check it
#
# razor: this script publishes nothing itself. make-staging.sh is and stays the
# only publish pipeline — a production release is that same pipeline pointed at
# the live server and bucket. Everything here is the gate in front of it: the
# checks and the two overrides that, when typed by hand, were what went wrong
# on the first live release. If you are changing HOW a release is built, change
# make-staging.sh; this file only decides whether it may run.
#
# What this refuses to let you do, and why each one bit before:
#   - Release from anywhere but a clean, pushed `main`.
#   - Reuse a build number. Sparkle compares CFBundleVersion; ship the same
#     number twice and no installed copy is ever offered the update.
#   - Publish while a D1 migration is unapplied in production. The deployed
#     Worker INSERTs columns the migration adds — a purchase then takes the
#     money and fails to issue a key. Nothing else checks this; it was found
#     once by reading sqlite_master by hand.
#   - Forget AUDIOUT_LICENSE_URL or R2_BUCKET and quietly cut a release that
#     points at staging, or land the bytes where /download cannot see them.
#
# Not automated on purpose:
#   - The test suite. The merge that put this commit on main already ran it in
#     full (Guard 4). Re-running costs ~15 minutes and proves the same thing.
#   - scripts/verify-standalone-app.sh. It moves this machine's real Homebrew
#     directories; it stays a deliberate, manual act. Reminded at the end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- The two values a live release is defined by ------------------------------
# Overridable only so a dry run can point elsewhere; a real release never sets
# them. The bucket also drives the appcast channel title inside make-staging.sh,
# so the feed cannot claim to be staging while the bytes land in the live bucket.
export AUDIOUT_LICENSE_URL="${AUDIOUT_LICENSE_URL:-https://license.audiout.app}"
export R2_BUCKET="${R2_BUCKET:-audiout-releases-live}"
LICENSE_REPO="${LICENSE_REPO:-$HOME/Projects/Audiout License Server}"
PROD_D1="${PROD_D1:-audiouter-license}"

# --- Version ------------------------------------------------------------------
APP_VERSION="${1:-${APP_VERSION:-}}"
[ -n "$APP_VERSION" ] || { echo "ERROR: usage: scripts/release.sh <version>   (e.g. scripts/release.sh 1.0.1)" >&2; exit 1; }
case "$APP_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "ERROR: version '$APP_VERSION' is not major.minor.patch — the DMG filename, latest-vN.json and the appcast all key off it" >&2; exit 1;;
esac
export APP_VERSION

# CFBundleVersion. The commit count on main only ever goes up, and a release
# only ever comes from main, so it cannot repeat or go backwards — which is the
# single property Sparkle needs and the one a hand-typed number kept losing.
export BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$REPO_ROOT" rev-list --count HEAD)}"

# --- Gate 1: a clean, pushed main --------------------------------------------
echo "==> Checking this is a clean, pushed main"
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || { echo "ERROR: on branch '$BRANCH' — a release is cut from main only. Merge first, then run this from the main checkout." >&2; exit 1; }
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || { echo "ERROR: the working tree is dirty. What ships must be exactly what is on main:" >&2; git -C "$REPO_ROOT" status --short >&2; exit 1; }
git -C "$REPO_ROOT" fetch --quiet origin main
LOCAL_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
REMOTE_SHA="$(git -C "$REPO_ROOT" rev-parse origin/main)"
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "ERROR: local main ($LOCAL_SHA) and origin/main ($REMOTE_SHA) disagree. Push or pull, then re-run — otherwise nothing on GitHub matches the bytes you are about to sell." >&2; exit 1; }
echo "    ok — main at $LOCAL_SHA, clean, in sync with origin"

# --- Gate 2: production D1 has every migration applied ------------------------
echo "==> Checking production D1 migrations are applied"
if [ -d "$LICENSE_REPO" ]; then
  MIGRATIONS="$(cd "$LICENSE_REPO" && npx --yes wrangler d1 migrations list "$PROD_D1" --env production --remote 2>&1)" || { echo "$MIGRATIONS" >&2; echo "ERROR: could not list production D1 migrations. Fix the wrangler auth (or pass PROD_D1=) — do not skip this check." >&2; exit 1; }
  # Clean is a POSITIVE result — wrangler prints exactly "No migrations to
  # apply!" and nothing else. Matched that way round on purpose: keying off the
  # unapplied-migration table instead would pass silently the day wrangler
  # reformats it, and this check exists precisely for the failure nobody sees.
  if ! printf '%s\n' "$MIGRATIONS" | grep -qF 'No migrations to apply!'; then
    printf '%s\n' "$MIGRATIONS" >&2
    echo "ERROR: production D1 '$PROD_D1' is not fully migrated (wrangler output above). The deployed Worker writes columns those migrations add — a purchase would take the money and fail to issue a key." >&2
    echo "       Apply them: cd '$LICENSE_REPO' && CONFIRM_PROD=yes npm run db:migrate:production" >&2
    exit 1
  fi
  echo "    ok — no unapplied migrations"
else
  echo "ERROR: license server repo not found at $LICENSE_REPO — set LICENSE_REPO. The migration check is not optional; it is the one failure that costs a buyer their money." >&2
  exit 1
fi

# --- Confirm ------------------------------------------------------------------
# Everything past this point is public and permanent: buyers download it, and
# every installed copy polls the URL baked into it forever.
cat <<EOF

  About to cut a LIVE release.

    Version        $APP_VERSION  (build $BUILD_NUMBER)
    Commit         $LOCAL_SHA
    License server $AUDIOUT_LICENSE_URL
    R2 bucket      $R2_BUCKET
    Buyer check    ${VERIFY_KEY:+enabled}${VERIFY_KEY:-NOT RUN — pass VERIFY_KEY=<a live key> to re-download and check what a buyer receives}

  This notarizes with Apple, uploads to R2, and flips latest-v${APP_VERSION%%.*}.json,
  which is what "published" means. Existing installs start being offered it.

EOF
if [ "${YES:-0}" != "1" ]; then
  printf '  Type the version to continue: '
  read -r CONFIRM
  [ "$CONFIRM" = "$APP_VERSION" ] || { echo "  Aborted." >&2; exit 1; }
fi

# --- Run the pipeline ---------------------------------------------------------
# Nothing is passed positionally: make-staging.sh reads the exported environment
# above, and its own pre-flight re-checks the major version, the signing key,
# wrangler auth and that the feed URL answers as the license server.
"$SCRIPT_DIR/make-staging.sh"

cat <<EOF

==> Published $APP_VERSION (build $BUILD_NUMBER) to $R2_BUCKET.

    Still owed by hand:
      1. scripts/verify-standalone-app.sh "$REPO_ROOT/build/Audiout.app"
         Proves it launches on a Mac with no Homebrew. Moves real Homebrew
         directories on this machine, so it is never run automatically.
      2. Download through $AUDIOUT_LICENSE_URL/download?key=<a real key> and
         open the app once, from /Applications.
EOF
[ -n "${VERIFY_KEY:-}" ] || echo "         (Step 2 is what VERIFY_KEY would have done for you.)"
echo
