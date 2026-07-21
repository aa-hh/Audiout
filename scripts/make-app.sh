#!/bin/bash
# make-app.sh — wrap the AudiouterApp SwiftPM binary into a real,
# double-clickable macOS .app bundle and ad-hoc codesign it.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# RESOLVED Q1: the app ships as a SwiftPM executable + this bundle script (no
# Xcode project). This produces "Audiouter.app" with an Info.plist
# (LSUIElement=true → menu-bar-only, no Dock icon), a stable bundle id, and an
# ad-hoc signature so Gatekeeper lets it launch locally.
#
# Usage: scripts/make-app.sh [output-dir]   (default output dir: ./build)
# Every command below is a paste-proof one-liner — no backslash continuations.

set -euo pipefail

# --- Config ---------------------------------------------------------------
# APP_NAME / BUNDLE_ID honor env overrides so a side-by-side dev build can carry
# a distinct identity (its own menu-bar app + LaunchServices registration) and
# coexist with an installed copy that shares the default bundle id. Defaults are
# unchanged, so a normal `./scripts/make-app.sh` produces the usual Audiouter.app.
APP_NAME="${APP_NAME:-Audiouter}"
EXECUTABLE="AudiouterApp"
BUNDLE_ID="${BUNDLE_ID:-com.audiouter.Audiouter}"
MIN_MACOS="13.0"
# Human-readable marketing version and monotonic build number.
APP_VERSION="0.1.0"
BUILD_NUMBER="1"
# Shown verbatim inside the macOS system-audio permission dialog. Written in the
# user's mental model ("send my audio to speakers"), not the OS's ("record"),
# and states the limit explicitly — this is the only text they get before
# deciding, so it has to do the whole job.
AUDIO_CAPTURE_USAGE="Audiouter needs to capture your Mac's audio so it can send it to the AirPlay speakers you choose. Audio goes only to those speakers — it is never recorded, saved, or sent anywhere else."
# Shown INSIDE the macOS Local Network permission dialog. The app browses Bonjour
# (_airplay._tcp / _raop._tcp) to find AirPlay speakers; say that plainly.
LOCAL_NETWORK_USAGE="Audiouter looks for AirPlay speakers on your local network so you can play your Mac's audio to them. It only finds speakers — it doesn't read or collect anything else about your network."

# --- Paths ----------------------------------------------------------------
# Resolve the repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/AudiouterCore"
OUTPUT_DIR="${1:-$REPO_ROOT/build}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
# Flattened 1024 "Default" (light) render exported from Icon Composer. See the
# app-icon step below for why we bake a classic .icns from this instead of
# compiling the .icon bundle directly.
ICON_SOURCE="$SCRIPT_DIR/AudioOuter-MacOS-Default-1024x1024@1x.png"

# --- Build (release) ------------------------------------------------------
echo "==> Building $EXECUTABLE (release)"
swift build --package-path "$PACKAGE_DIR" -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path)"
BUILT_BINARY="$BIN_DIR/$EXECUTABLE"
test -x "$BUILT_BINARY" || { echo "error: built binary not found at $BUILT_BINARY" >&2; exit 1; }

# --- Assemble the bundle --------------------------------------------------
echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp "$BUILT_BINARY" "$MACOS_DIR/$EXECUTABLE"
chmod +x "$MACOS_DIR/$EXECUTABLE"

# --- Bundle Homebrew dylibs (opt-in) ---------------------------------------
# The executable currently links Homebrew dylibs (libevent, libsodium,
# libgcrypt, libgpg-error, libplist, ffmpeg + its transitive chain — see
# AirPlayEngine/Package.swift's brewLibFlags) via absolute paths under
# /opt/homebrew or /usr/local, which don't exist on a Mac without Homebrew.
# scripts/bundle-dylibs.sh copies every such dylib (walked transitively via
# otool -L, not a hardcoded list) into Contents/Frameworks and repoints the
# load commands at @rpath, making the bundle self-contained.
#
# Gated behind AUDIOUTER_BUNDLE_DYLIBS=1 (default: skip) because it's a
# non-trivial extra step (walks + copies + relinks a whole dependency tree)
# that plain local dev builds don't need — Homebrew is already on the dev
# machine, so the fast unbundled build launches fine there. Set this env var
# for a release/distribution build that has to run on a machine without
# Homebrew. NOT signed here — codesign below still ad-hoc-signs the whole
# bundle (including these newly-added Frameworks) in one pass.
#
# PROVING it worked is a SEPARATE, deliberately manual step — NOT run here.
# `otool -L` / `codesign` below confirm the load commands LOOK right, but only
# on THIS machine, which has Homebrew. To actually prove the bundle launches on
# a Mac WITHOUT Homebrew, run:  scripts/verify-standalone-app.sh <this .app>
# It temporarily renames the Homebrew keg dirs this bundle used and launches the
# app with them gone. That's intentionally left out of the build because it
# moves real directories on the developer's disk (restored via a trap) and is
# slow/invasive — you don't want it firing on every AUDIOUTER_BUNDLE_DYLIBS=1
# build. Invoke it by hand before shipping a distribution build.
if [ "${AUDIOUTER_BUNDLE_DYLIBS:-0}" = "1" ]; then
  echo "==> Bundling Homebrew dylibs (AUDIOUTER_BUNDLE_DYLIBS=1)"
  "$SCRIPT_DIR/bundle-dylibs.sh" "$APP_BUNDLE"
  echo "    (to PROVE this launches with no Homebrew present, run: scripts/verify-standalone-app.sh \"$APP_BUNDLE\")"
else
  echo "==> Skipping dylib bundling (set AUDIOUTER_BUNDLE_DYLIBS=1 to bundle for a Homebrew-less target Mac)"
fi

# --- App icon --------------------------------------------------------------
# The official icon is authored in Icon Composer (scripts/AudioOuter.icon) as a
# Liquid Glass icon. Compiling that bundle standalone (outside an .xcodeproj)
# requires Xcode 26's actool, and Liquid Glass only renders on macOS 26 anyway.
# actool's CLI contract for a bare .icon bundle isn't Apple-documented yet (this
# is a brand-new Xcode 26 feature), so we ATTEMPT it opportunistically and fall
# back automatically to a classic .icns baked from Icon Composer's flattened
# 1024 "Default" render — this keeps the script working unmodified on an
# Xcode-15 machine (falls back every time) and an Xcode-26 machine (uses the
# real Liquid Glass icon whenever the actool invocation below is accepted).
# NOTE: this is a menu-bar app (LSUIElement) so it has no Dock icon; this icon
# is what Finder, Get Info, the About box, notifications, and any
# Store/distribution listing use.
mkdir -p "$RESOURCES_DIR"
ICON_MODE="icns"
ICON_BUNDLE_SRC="$SCRIPT_DIR/AudioOuter.icon"
XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || true)"
if [ -n "$XCODE_MAJOR" ] && [ "$XCODE_MAJOR" -ge 26 ] && [ -d "$ICON_BUNDLE_SRC" ]; then
  echo "==> Xcode $XCODE_MAJOR detected — attempting Liquid Glass icon compile via actool"
  ACTOOL_TMP="$(mktemp -d)"
  if xcrun actool \
      --compile "$RESOURCES_DIR" \
      --platform macosx \
      --minimum-deployment-target "$MIN_MACOS" \
      --app-icon "$(basename "$ICON_BUNDLE_SRC" .icon)" \
      --output-partial-info-plist "$ACTOOL_TMP/partial-info.plist" \
      --output-format human-readable-text \
      --notices --warnings \
      "$ICON_BUNDLE_SRC" >"$ACTOOL_TMP/actool.log" 2>&1 \
    && [ -f "$RESOURCES_DIR/Assets.car" ]; then
    echo "    actool compiled Assets.car — using Liquid Glass icon"
    ICON_MODE="liquidglass"
  else
    echo "    actool did not produce Assets.car — falling back to classic .icns (log below)"
    sed 's/^/    actool: /' "$ACTOOL_TMP/actool.log" || true
  fi
fi

if [ "$ICON_MODE" = "icns" ]; then
  echo "==> Generating app icon (.icns fallback)"
  test -f "$ICON_SOURCE" || { echo "error: icon source not found at $ICON_SOURCE" >&2; exit 1; }
  ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  for s in 16 32 128 256 512; do d=$((s * 2)); sips -z "$s" "$s" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${s}x${s}.png" >/dev/null; sips -z "$d" "$d" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${s}x${s}@2x.png" >/dev/null; done
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
  test -f "$RESOURCES_DIR/AppIcon.icns" || { echo "error: AppIcon.icns not generated" >&2; exit 1; }
fi

# --- Info.plist -----------------------------------------------------------
# LSUIElement=true makes it a menu-bar-only accessory (no Dock icon, no menu
# bar) even before the code sets .accessory — belt-and-suspenders.
echo "==> Writing Info.plist"
PLIST="$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Clear dict" "$PLIST" >/dev/null 2>&1 || printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict></dict></plist>' > "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $EXECUTABLE" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MIN_MACOS" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$PLIST"
# Point the bundle at whichever icon the app-icon step above produced:
# CFBundleIconName for the compiled Liquid Glass Assets.car (actool convention —
# name matches the --app-icon value passed above), CFBundleIconFile for the
# classic .icns fallback (basename without extension, per convention).
if [ "$ICON_MODE" = "liquidglass" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $(basename "$ICON_BUNDLE_SRC" .icon)" "$PLIST"
else
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
fi
# The text macOS shows INSIDE the system-audio permission dialog. Without this
# key the prompt is a bare "wants to record" ask with no reason attached — and
# the permission lives in the "Screen & System Audio Recording" bucket, so the
# user sees this app listed next to actual screen recorders. Their mental model
# is "send my audio elsewhere", not "record me": say so, in their words, and say
# what we DON'T do. (The Phase 0 `audiocap` spike carried an equivalent string —
# see dev/audiocap/Sources/audiocap/Info.plist — which was lost in the port to
# the real .app bundle. Capture only ever runs while streaming to a speaker; see
# NativeBackend's capture gate.)
#
# plutil, NOT PlistBuddy, for this one key: PlistBuddy re-parses its own -c
# argument, so an apostrophe in the prose ("your Mac's audio") dies with
# "Parse Error: Unclosed Quotes" — AND EXITS 0, silently shipping a bundle with
# no usage string, which is invisible until a user meets a bare "wants to
# record" prompt. plutil takes the value as a real argv element, so ordinary
# English punctuation is safe. Don't "simplify" this back to PlistBuddy.
plutil -insert NSAudioCaptureUsageDescription -string "$AUDIO_CAPTURE_USAGE" "$PLIST"
# Assert it actually landed: this key failing silently is the exact bug above,
# and a missing permission rationale is not something to discover in the wild.
plutil -extract NSAudioCaptureUsageDescription raw -o - "$PLIST" >/dev/null || { echo "ERROR: NSAudioCaptureUsageDescription missing from Info.plist" >&2; exit 1; }

# Local Network: the app browses Bonjour to discover AirPlay speakers, which macOS
# gates behind the Local Network permission (a separate prompt from audio). Two
# keys are needed and BOTH must be present or discovery silently finds nothing:
#   NSLocalNetworkUsageDescription — the prompt's rationale (same plutil-not-
#     PlistBuddy reasoning as above: the prose has apostrophes).
#   NSBonjourServices — the service types we're allowed to browse; without it the
#     browse is blocked even with the usage string. These MUST match the types
#     NativeDiscovery browses (_airplay._tcp for AirPlay 2, _raop._tcp for AP1).
plutil -insert NSLocalNetworkUsageDescription -string "$LOCAL_NETWORK_USAGE" "$PLIST"
plutil -insert NSBonjourServices -array "$PLIST"
plutil -insert NSBonjourServices.0 -string "_airplay._tcp" "$PLIST"
plutil -insert NSBonjourServices.1 -string "_raop._tcp" "$PLIST"
plutil -extract NSLocalNetworkUsageDescription raw -o - "$PLIST" >/dev/null || { echo "ERROR: NSLocalNetworkUsageDescription missing from Info.plist" >&2; exit 1; }
plutil -extract NSBonjourServices.0 raw -o - "$PLIST" >/dev/null || { echo "ERROR: NSBonjourServices missing from Info.plist" >&2; exit 1; }

# --- Strip extended attributes ---------------------------------------------
# codesign refuses to sign anything carrying AppleDouble/resource-fork-style
# metadata ("resource fork, Finder information, or similar detritus not
# allowed") — e.g. a legacy FinderInfo custom-icon flag or an iCloud-sync
# attribute picked up by one of the icon assets (SVGs/PNGs) or the built
# .icns/Assets.car. Observed when building from a repo checkout under
# ~/Documents, which iCloud Drive commonly syncs and tags. `xattr -cr` strips
# extended attributes recursively across the whole bundle; harmless when
# there's nothing to strip.
#
# xattr -cr alone was NOT enough on an actual iCloud-synced checkout: the
# codesign error persisted even after it ran. That's because an AppleDouble
# sidecar (a literal hidden `._name` file living NEXT TO `name`, or a stray
# `.DS_Store`) is a separate file, not an extended attribute on an existing
# one — xattr has nothing to strip it of. Delete those outright too.
echo "==> Stripping extended attributes from bundle"
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" \( -name '._*' -o -name '.DS_Store' \) -delete

# --- Codesign (ad-hoc, HARDENED RUNTIME) ----------------------------------
# Ad-hoc ("-") signature: no Developer ID needed for local launch. Phase 2
# swaps this for a real signing identity + notarization.
#
# `--options runtime` (hardened runtime) is a SECURITY REQUIREMENT, not just a
# distribution one: this app holds the "System Audio Recording" TCC grant, and
# without the hardened runtime a local attacker could `DYLD_INSERT_LIBRARIES` a
# dylib into the process and inherit that grant. The hardened runtime makes dyld
# ignore DYLD_* env vars, closing that vector — as long as we withhold the
# allow-dyld-environment-variables entitlement (we do). Library validation is
# deliberately DISABLED in scripts/Audiouter.entitlements even though bundled
# dylibs are re-signed here (inside-out): ad-hoc signatures have no Team ID, so
# library validation would reject them. Developer ID would allow re-enabling it.
# The DYLD_INSERT protection does NOT depend on library validation.
#
# NOT `--deep`: it is deprecated by Apple and signs nested code with the wrong
# (inherited) options. When AUDIOUTER_BUNDLE_DYLIBS=1 the bundle now has ~20
# Mach-Os (main executable + every Homebrew dylib bundle-dylibs.sh copied into
# Contents/Frameworks) — so sign them explicitly INSIDE-OUT before this line,
# same rule this comment has always stated, now actually exercised.
#
# WHY ORDER MATTERS: `codesign --verify --strict` on the outer .app bundle
# checks the bundle's own signature AND that any nested code it embeds is
# itself validly signed. install_name_tool (in bundle-dylibs.sh) rewrote each
# dylib's LC_ID_DYLIB and every referencing load command — that invalidates
# whatever signature the dylib had from Homebrew, so each one must be
# (re-)signed before the outer bundle is signed. Sign the outer bundle first
# and `--verify --strict` fails (or, worse, silently ignores unsigned nested
# code depending on codesign version) — sign inside-out and it can't.
if [ -d "$CONTENTS/Frameworks" ] && [ -n "$(ls -A "$CONTENTS/Frameworks" 2>/dev/null)" ]; then
  echo "==> Ad-hoc codesigning bundled dylibs in Contents/Frameworks (inside-out, before the app)"
  # --options runtime for consistency with the hardened-runtime posture below;
  # these are library code, not the entitled executable, so no --entitlements
  # here — only the main executable needs the audio-capture / local-network /
  # disable-library-validation entitlements.
  find "$CONTENTS/Frameworks" -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
    echo "    signing $(basename "$dylib")"
    codesign --force --options runtime --sign - "$dylib"
  done
fi
echo "==> Ad-hoc codesigning (hardened runtime)"
ENTITLEMENTS="$SCRIPT_DIR/Audiouter.entitlements"
test -f "$ENTITLEMENTS" || { echo "error: entitlements file not found at $ENTITLEMENTS" >&2; exit 1; }
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE"
codesign --verify --strict --verbose "$APP_BUNDLE"
# Assert the hardened runtime actually got applied — a signature silently missing
# the runtime flag would reopen the injection surface above. Capture first, then
# grep: piping straight into `grep -q` makes grep close the pipe early, codesign
# takes SIGPIPE, and `set -o pipefail` would flag that as a spurious failure.
SIG_INFO="$(codesign --display --verbose=2 "$APP_BUNDLE" 2>&1 || true)"
printf '%s\n' "$SIG_INFO" | grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' || { echo "ERROR: hardened runtime flag not set on signature" >&2; exit 1; }
# Assert the entitlements actually EMBEDDED. codesign exits 0 even when AMFI
# rejects a malformed entitlements plist (it just drops them), which would ship a
# hardened-runtime app with library validation still ON — and that app cannot
# load its Homebrew dylibs, so it would crash at launch. Verify the load-bearing
# key is present rather than trusting codesign's exit code.
EMBEDDED_ENTS="$(codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null || true)"
printf '%s' "$EMBEDDED_ENTS" | grep -q 'com.apple.security.cs.disable-library-validation' || { echo "ERROR: entitlements did not embed (AMFI likely rejected the plist) — app would fail to load Homebrew dylibs" >&2; exit 1; }

# Final nested-code check. `--verify --strict` above only checked the OUTER
# bundle's own signature; it does not recurse into Contents/Frameworks. Run a
# --deep verify now to prove every nested Mach-O (all the bundled dylibs, when
# present) is validly signed too — this is read-only VERIFICATION, which is
# fine; the `--deep` ban above is specifically about SIGNING with --deep
# (wrong inherited options), not about verifying with it. If this fails, the
# inside-out signing above didn't actually cover something nested.
echo "==> Verifying nested code (deep verify)"
codesign --verify --strict --verbose=4 "$APP_BUNDLE" || { echo "ERROR: codesign --verify --strict failed on $APP_BUNDLE" >&2; exit 1; }
codesign --verify --deep --strict "$APP_BUNDLE" || { echo "ERROR: codesign --verify --deep --strict failed — some nested Mach-O (likely a dylib in Contents/Frameworks) is unsigned or invalidly signed" >&2; exit 1; }

echo "==> Done: $APP_BUNDLE"
