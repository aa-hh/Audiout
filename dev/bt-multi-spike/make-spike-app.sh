#!/bin/bash
# make-spike-app.sh — wrap the bt-multi-spike CLI in a minimal ad-hoc-signed
# .app bundle so macOS attributes the Bluetooth TCC prompt/grant to the bundle
# instead of the invoking terminal. A bare shell-launched CLI inherits the
# terminal's TCC context (responsible-process attribution) and may never see
# its own prompt — this wrapper is the fallback for --connect-probe when that
# happens. Radically simplified from the repo-root scripts/make-app.sh: no
# icons, no helper daemons, no entitlements, ad-hoc signature only.
#
# Usage:
#   bash make-spike-app.sh
#
# Then ALWAYS launch via `open` — running the inner binary from a shell
# re-inherits the terminal's TCC context and defeats the wrapper:
#   open --stdout "$(tty)" --stderr "$(tty)" build/bt-multi-spike.app \
#     --args --connect-probe "<name-or-address>"
#
# GOTCHA (memory: tcc-grants-cdhash-pinned-on-adhoc-builds): an ad-hoc
# signature pins the TCC grant to this exact binary's cdhash. After ANY
# rebuild, REMOVE the stale grant in System Settings > Privacy & Security >
# Bluetooth (the "-" button — toggling is not enough) and let it re-prompt.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="bt-multi-spike"
BUNDLE_ID="com.audiouter.bt-multi-spike"

swift build -c release
BIN=".build/release/$APP_NAME"
test -x "$BIN" || { echo "error: $BIN missing after build" >&2; exit 1; }

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$PLIST"
# CLI in a bundle: keep it out of the Dock when launched via `open`.
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST"
# The rationale macOS shows in the Bluetooth permission prompt.
/usr/libexec/PlistBuddy -c "Add :NSBluetoothAlwaysUsageDescription string bt-multi-spike probes paired Bluetooth speakers: connect/reconnect feasibility for Audiouter (BT-SPIKE-CONNECT)." "$PLIST"

codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "OK: $APP"
echo "Launch via open (never the inner binary directly):"
echo "  open --stdout \"\$(tty)\" --stderr \"\$(tty)\" \"$APP\" --args --connect-probe \"<name-or-address>\""
