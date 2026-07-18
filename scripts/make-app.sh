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
APP_NAME="Audiouter"
EXECUTABLE="AudiouterApp"
BUNDLE_ID="com.audiouter.Audiouter"
MIN_MACOS="13.0"
# Human-readable marketing version and monotonic build number.
APP_VERSION="0.1.0"
BUILD_NUMBER="1"
# Shown verbatim inside the macOS system-audio permission dialog. Written in the
# user's mental model ("send my audio to speakers"), not the OS's ("record"),
# and states the limit explicitly — this is the only text they get before
# deciding, so it has to do the whole job.
AUDIO_CAPTURE_USAGE="Audiouter needs to capture your Mac's audio so it can send it to the AirPlay speakers you choose. Audio goes only to those speakers — it is never recorded, saved, or sent anywhere else."

# --- Paths ----------------------------------------------------------------
# Resolve the repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/AudiouterCore"
OUTPUT_DIR="${1:-$REPO_ROOT/build}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

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
# deliberately DISABLED in scripts/Audiouter.entitlements because the app links
# Homebrew dylibs signed under a different Team ID (with it on, dyld aborts at
# launch); the DYLD_INSERT protection does NOT depend on library validation. See
# that file for the full rationale and the Phase 2 plan to re-enable it.
#
# NOT `--deep`: it is deprecated by Apple and signs nested code with the wrong
# (inherited) options. The bundle currently has a single Mach-O; when helpers get
# embedded, sign them explicitly inside-out before this line.
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

echo "==> Done: $APP_BUNDLE"
