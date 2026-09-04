#!/bin/bash
# fetch-wordmark-font.sh — put ClashDisplay-Semibold.otf (the wordmark face,
# Tokens.Font.wordmark) and its licence text into a .app's Contents/Resources.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# WHY THIS EXISTS: the font is Indian Type Foundry's, under the ITF Free Font
# License — embedding in a desktop app is permitted (§01), redistributing the
# file through a public repository is not (§02). This repo is public, so the
# .otf never enters git: it is fetched from Fontshare at assembly, pinned by
# sha256, and only ever lands under build/ (gitignored) and inside the .app.
# Fontshare's download URL is not a published contract; the pins are the
# guard, and AUDIOUT_WORDMARK_FONT is the fallback when the URL dies.
#
# Usage:  scripts/fetch-wordmark-font.sh <Contents/Resources dir> [cache dir]
# Env:    AUDIOUT_WORDMARK_FONT=/path/to/ClashDisplay-Semibold.otf  use this
#         file instead of downloading (offline builds). Still checksummed.
set -euo pipefail

if [ $# -lt 1 ]; then echo "Usage: $0 <Contents/Resources dir> [cache dir]" >&2; exit 1; fi
DEST="$1"
CACHE="${2:-$(cd "$(dirname "$0")/.." && pwd)/build/font-cache}"
FONT_NAME="ClashDisplay-Semibold.otf"
LICENSE_NAME="ClashDisplay-FFL.txt"
FONT_SHA="e70dce86ab1ba52063e2f85a536c21d70c3a9dee271f1fa453e58147be3c2f60"
ZIP_URL="https://api.fontshare.com/v2/fonts/download/clash-display"
ZIP_SHA="1f93e17103f05b49b58ccb66704aae3bd570c361c41233c2bfd4db1a3e48952c"
ZIP="$CACHE/clash-display.zip"
ZIP_FONT_ENTRY="ClashDisplay_Complete/Fonts/OTF/ClashDisplay-Semibold.otf"
ZIP_LICENSE_ENTRY="ClashDisplay_Complete/License/FFL.txt"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p "$CACHE" "$DEST"

if [ -n "${AUDIOUT_WORDMARK_FONT:-}" ]; then
  FONT_SRC="$AUDIOUT_WORDMARK_FONT"
  [ -f "$FONT_SRC" ] || { echo "ERROR: AUDIOUT_WORDMARK_FONT=$FONT_SRC does not exist" >&2; exit 1; }
else
  # Cached zip with the pinned hash → skip the network. A re-packaged zip (new
  # hash) is still accepted as long as the .otf inside matches its own pin.
  if [ ! -f "$ZIP" ] || [ "$(sha256_of "$ZIP")" != "$ZIP_SHA" ]; then
    echo "==> Fetching Clash Display from Fontshare into $CACHE"
    curl -fsSL --compressed --max-time 120 -A "Mozilla/5.0" "$ZIP_URL" -o "$ZIP" || { echo "ERROR: could not download $FONT_NAME from $ZIP_URL — set AUDIOUT_WORDMARK_FONT to a local copy" >&2; exit 1; }
  fi
  unzip -p "$ZIP" "$ZIP_FONT_ENTRY" > "$CACHE/$FONT_NAME" || { echo "ERROR: $ZIP_FONT_ENTRY missing from the Fontshare zip — the package layout changed; set AUDIOUT_WORDMARK_FONT" >&2; exit 1; }
  unzip -p "$ZIP" "$ZIP_LICENSE_ENTRY" > "$CACHE/$LICENSE_NAME" || { echo "ERROR: $ZIP_LICENSE_ENTRY missing from the Fontshare zip" >&2; exit 1; }
  FONT_SRC="$CACHE/$FONT_NAME"
fi

ACTUAL="$(sha256_of "$FONT_SRC")"
[ "$ACTUAL" = "$FONT_SHA" ] || { echo "ERROR: $FONT_NAME sha256 $ACTUAL != pinned $FONT_SHA — the wordmark face changed upstream or the file is corrupt; not shipping it" >&2; exit 1; }
cp "$FONT_SRC" "$DEST/$FONT_NAME"
if [ -f "$CACHE/$LICENSE_NAME" ]; then cp "$CACHE/$LICENSE_NAME" "$DEST/$LICENSE_NAME"; else echo "WARNING: $LICENSE_NAME not in $CACHE (AUDIOUT_WORDMARK_FONT build) — the licence text ships only from a Fontshare fetch" >&2; fi
echo "==> $FONT_NAME ($ACTUAL) -> $DEST"
