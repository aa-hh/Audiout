#!/bin/bash
# make-app.sh — wrap the AirPlayControllerApp SwiftPM binary into a real,
# double-clickable macOS .app bundle and ad-hoc codesign it.
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Alec Henderson and contributors.
#
# RESOLVED Q1: the app ships as a SwiftPM executable + this bundle script (no
# Xcode project). This produces "AirPlay Controller.app" with an Info.plist
# (LSUIElement=true → menu-bar-only, no Dock icon), a stable bundle id, and an
# ad-hoc signature so Gatekeeper lets it launch locally.
#
# Usage: scripts/make-app.sh [output-dir]   (default output dir: ./build)
# Every command below is a paste-proof one-liner — no backslash continuations.

set -euo pipefail

# --- Config ---------------------------------------------------------------
APP_NAME="AirPlay Controller"
EXECUTABLE="AirPlayControllerApp"
BUNDLE_ID="com.alechenderson.AirPlayController"
MIN_MACOS="13.0"
# Human-readable marketing version and monotonic build number.
APP_VERSION="0.1.0"
BUILD_NUMBER="1"
# Shown verbatim inside the macOS system-audio permission dialog. Written in the
# user's mental model ("send my audio to speakers"), not the OS's ("record"),
# and states the limit explicitly — this is the only text they get before
# deciding, so it has to do the whole job.
AUDIO_CAPTURE_USAGE="AirPlay Controller needs to capture your Mac's audio so it can send it to the AirPlay speakers you choose. Audio goes only to those speakers — it is never recorded, saved, or sent anywhere else."

# --- Paths ----------------------------------------------------------------
# Resolve the repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/AirPlayControllerCore"
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

# --- Codesign (ad-hoc) ----------------------------------------------------
# Ad-hoc ("-") signature: no Developer ID needed for local launch. Phase 2
# swaps this for a real signing identity + notarization.
echo "==> Ad-hoc codesigning"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
