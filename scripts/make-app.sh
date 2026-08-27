#!/bin/bash
# make-app.sh — wrap the AudioutApp SwiftPM binary into a real,
# double-clickable macOS .app bundle and codesign it (Developer ID when the
# keychain has one, else ad-hoc).
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# RESOLVED Q1: the app ships as a SwiftPM executable + this bundle script (no
# Xcode project). This produces "Audiout.app" with an Info.plist
# (LSUIElement=true → menu-bar-only, no Dock icon), a stable bundle id, and a
# code signature (Developer ID when the keychain has one, else ad-hoc) so
# Gatekeeper lets it launch.
#
# Usage: scripts/make-app.sh [output-dir]   (default output dir: ./build)
# Every command below is a paste-proof one-liner — no backslash continuations.

set -euo pipefail

# --- Config ---------------------------------------------------------------
# APP_NAME / BUNDLE_ID honor env overrides so a side-by-side dev build can carry
# a distinct identity (its own menu-bar app + LaunchServices registration) and
# coexist with an installed copy that shares the default bundle id. Defaults are
# unchanged, so a normal `./scripts/make-app.sh` produces the usual Audiout.app.
APP_NAME="${APP_NAME:-Audiout}"
EXECUTABLE="AudioutApp"
BUNDLE_ID="${BUNDLE_ID:-com.audiout.Audiout}"
# The oldest macOS the app supports. 14.2, NOT 13.x: the native backend's
# whole-system audio capture uses Core Audio process taps
# (AudioHardwareCreateProcessTap / CATapDescription), a macOS 14.2 API — on 13.x
# the app launches and then crashes/misbehaves the moment it tries to capture.
# Advertising 14.2 here stops a 13.x user installing a build that can't work
# (crash-hang.md M2). Feeds BOTH LSMinimumSystemVersion and actool's
# --minimum-deployment-target below. Env-overridable, but don't drop below 14.2.
MIN_MACOS="${MIN_MACOS:-14.2}"
# Human-readable marketing version (CFBundleShortVersionString) and monotonic
# build number (CFBundleVersion). Env-overridable so a release can bump them
# without editing this script:
#   APP_VERSION=0.2.0 BUILD_NUMBER=7 scripts/make-app.sh
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# Shown verbatim inside the macOS system-audio permission dialog. Written in the
# user's mental model ("send my audio to speakers"), not the OS's ("record"),
# and states the limit explicitly — this is the only text they get before
# deciding, so it has to do the whole job.
AUDIO_CAPTURE_USAGE="Audiout needs to capture your Mac's audio so it can send it to the AirPlay speakers you choose. Audio goes only to those speakers — it is never recorded, saved, or sent anywhere else."
# Shown INSIDE the macOS Local Network permission dialog. The app browses Bonjour
# (_airplay._tcp / _raop._tcp) to find AirPlay speakers; say that plainly.
LOCAL_NETWORK_USAGE="Audiout looks for AirPlay speakers on your local network so you can play your Mac's audio to them. It only finds speakers — it doesn't read or collect anything else about your network."
# Shown INSIDE the macOS Bluetooth permission dialog (BT-CONNECT,
# PLAN-UNIVERSAL-SYNC §B/§K). Same mental-model rule as the two above.
BLUETOOTH_USAGE="Audiout connects to Bluetooth speakers you've already paired so it can play your Mac's audio on them. It only reaches speakers you choose — it never scans for or reads anything else."

MICROPHONE_USAGE="Audiout can listen through your Mac's built-in microphone for a couple of seconds during speaker alignment, to measure how far apart your speakers sound. The recording is analysed on your Mac and thrown away — nothing is saved or sent anywhere."

# The privileged root PTP helper (T2/T5, ptp-helper-design.md §2). Lives in
# the AirPlayEngine package, not AudioutCore — a separate `swift build`
# invocation below. Label MUST equal the LaunchDaemons plist's own filename
# (SMAppService.daemon(plistName:) resolves it by exact name match).
#
# BUNDLE_ID-derived (not hardcoded): PTPHelperService.swift's default
# plistName mirrors this exact derivation (Bundle.main.bundleIdentifier +
# ".ptphelper.plist"), so a side-by-side dev build under a distinct
# BUNDLE_ID registers its OWN daemon identity instead of colliding with
# another Audiout copy that already claimed "com.audiout.Audiout.ptphelper"
# (2026-07-24 live-testing bug: the loser's SMAppService.register() silently
# no-ops instead of throwing, so the daemon never shows up in Login Items at
# all for the losing copy). Default BUNDLE_ID unset ⇒ identical to before.
HELPER_EXECUTABLE="ptp-helper"
HELPER_LABEL="${BUNDLE_ID}.ptphelper"

# Tiny, short-lived TCC-preflight probe (T14, TCCProbeRunner.swift): a
# brand-new process gets a brand-new `TCCAccessPreflight` cache, dodging the
# per-process staleness `TCCBucketDiagnostic.swift`'s header comment documents
# — `TCCProbeRunner` spawns this fresh, on demand, to get a live read with no
# app relaunch needed. Unlike ptp-helper above, it lives in the SAME package
# (AudioutCore) as the app executable, so it's built via the SAME `swift
# build` invocation/bin dir below rather than a second package build.
TCC_PROBE_EXECUTABLE="tcc-probe"

# SwiftPM resource bundle for AudioutSharedUI (holds the in-app brand mark,
# Audiout-Hero-1024.svg). SwiftPM emits it next to the app executable in the
# build's bin dir and `Bundle.module` resolves it from Contents/Resources at
# runtime — so it MUST be copied into the .app or the first BrandMark.image
# access traps (the generated accessor fatalErrors when the bundle is absent).
# Name is `<PackageName>_<TargetName>.bundle`, deterministic from Package.swift.
RESOURCE_BUNDLE_NAME="AudioutCore_AudioutSharedUI.bundle"

# Codesigning identity, resolved in priority order:
#   1. CODESIGN_IDENTITY from the environment — an explicit override. Set it to
#      "-" to force ad-hoc, or to a full identity string to pin a specific one.
#   2. Auto-detected "Developer ID Application" identity from the keychain — the
#      normal release path. A real Team ID is what lets the bundled SMAppService
#      LaunchDaemon actually register() and bind privileged PTP ports (ad-hoc
#      signatures have no Team ID, so the OS won't associate the daemon with the
#      app), AND produces a Gatekeeper-acceptable, notarization-ready build. The
#      identity is resolved BY NAME from the keychain, never a hardcoded hash, so
#      this works on any developer's machine that holds the cert.
#   3. Ad-hoc ("-") when no Developer ID identity is present (headless CI, a
#      machine without the cert) — still launches locally + covers the
#      unprivileged test paths; it just can't register the daemon.
# Both the app and the nested ptp-helper are signed with THIS identity so their
# Team IDs match.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Codesign identity from environment: $CODESIGN_IDENTITY"
else
  # `|| true`: grep exits 1 when the keychain has no Developer ID identity, and
  # under `set -euo pipefail` a failing command substitution would abort the
  # build — we want the ad-hoc fallback instead. Prints the identity NAME (codesign
  # accepts it), picking the first if several are installed.
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)"
  if [ -n "$CODESIGN_IDENTITY" ]; then
    echo "==> Auto-detected Developer ID signing identity: $CODESIGN_IDENTITY"
  elif [ "${CODESIGN_REQUIRE_IDENTITY:-0}" = "1" ]; then
    # Strict opt-in for permission-dependent builds (live/on-device testing). A
    # Developer ID signature keys TCC grants to a STABLE Team ID + bundle id, so
    # a grant survives every rebuild; an ad-hoc signature re-pins to a fresh
    # cdhash each build, orphaning the grant and forcing re-onboarding. When
    # CODESIGN_REQUIRE_IDENTITY=1 we refuse to silently produce that throwaway
    # build — fail loudly so the tester notices the missing cert instead of
    # chasing "permissions denied" on a binary that can never keep them.
    echo "ERROR: CODESIGN_REQUIRE_IDENTITY=1 but no Developer ID Application identity is in the keychain." >&2
    echo "       An ad-hoc build's TCC grants re-pin to the binary and are lost on the next rebuild." >&2
    echo "       Install the Developer ID cert, or set CODESIGN_IDENTITY explicitly, or unset" >&2
    echo "       CODESIGN_REQUIRE_IDENTITY to allow the ad-hoc fallback." >&2
    exit 1
  else
    CODESIGN_IDENTITY="-"
    echo "==> No Developer ID Application identity in keychain — falling back to ad-hoc signing"
    echo "    NOTE: ad-hoc TCC grants re-pin to the binary and are LOST on the next rebuild." >&2
    echo "    For repeatable permission-dependent testing, sign with Developer ID" >&2
    echo "    (set CODESIGN_REQUIRE_IDENTITY=1 to make a missing cert a hard error)." >&2
  fi
fi
# Secure timestamp only with a real identity: Apple's timestamp service needs a
# trusted identity (and network), and ad-hoc signatures can't carry one. Empty
# for ad-hoc so the UNQUOTED expansion in each codesign call below adds no
# argument — a plain string, not a bash array, so it stays macOS bash-3.2 safe
# under `set -u` (an empty "${arr[@]}" would be an unbound-variable error there).
if [ "$CODESIGN_IDENTITY" = "-" ]; then TIMESTAMP_FLAG=""; else TIMESTAMP_FLAG="--timestamp"; fi

# --- Paths ----------------------------------------------------------------
# Resolve the repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/AudioutCore"
ENGINE_PACKAGE_DIR="$REPO_ROOT/AirPlayEngine"
OUTPUT_DIR="${1:-$REPO_ROOT/build}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
LAUNCH_DAEMONS_DIR="$CONTENTS/Library/LaunchDaemons"
HELPER_PLIST_SOURCE="$SCRIPT_DIR/ptp-helper.plist"
# Info.plist embedded into the ptp-helper Mach-O as a __TEXT,__info_plist
# section at link time (SMAppService requires a standalone-executable daemon to
# carry an embedded CFBundleIdentifier — see the file's header comment).
HELPER_INFO_PLIST="$SCRIPT_DIR/ptp-helper-info.plist"
# Flattened 1024 "Default" (light) render exported from Icon Composer. See the
# app-icon step below for why we bake a classic .icns from this instead of
# compiling the .icon bundle directly.
ICON_SOURCE="$SCRIPT_DIR/Audiout-MacOS-Default-1024x1024@1x.png"
# Flattened 1024 "Dark" render from Icon Composer, paired with ICON_SOURCE to
# build a light/dark appearance-aware icon (see the app-icon step below).
ICON_SOURCE_DARK="$SCRIPT_DIR/Audiout-MacOS-Dark-1024x1024@1x.png"

# --- Build (release) ------------------------------------------------------
# For a self-contained release bundle, build the minimal audio-only ffmpeg FIRST
# (idempotent — skips if already built; set FFMPEG_MIN_FORCE=1 to rebuild), so the
# app links ONLY the ALAC encoder statically and bundle-dylibs.sh finds zero
# video-codec dylibs — a ~30 MB smaller download. Package.swift auto-detects
# AirPlayEngine/vendor/ffmpeg-min/ and prefers it; absent, it falls back to
# Homebrew's fat ffmpeg unchanged. Gated to the bundling path only, since the trim
# is invisible when dylibs aren't bundled. See AirPlayEngine/docs/ffmpeg-minimal-build.md.
if [ "${AUDIOUT_BUNDLE_DYLIBS:-0}" = "1" ]; then
  echo "==> Building minimal audio-only ffmpeg for the release bundle (first run compiles from source; then cached)"
  "$SCRIPT_DIR/build-min-ffmpeg.sh"
fi

# Disk housekeeping (prune flagged worktrees, cap .build caches) before this
# build starts writing ~1 GB of artifacts. Best-effort: never fails the build.
if [ -x "$SCRIPT_DIR/housekeeping.sh" ]; then
  "$SCRIPT_DIR/housekeeping.sh" --current "$(cd "$SCRIPT_DIR/.." && pwd)" || true
fi

# --- Where to compile ------------------------------------------------------
# The three release compiles below are the expensive part of this script, and
# they answer to the SAME local-vs-remote rule as scripts/run-tests.sh — one
# shared decision in scripts/lib/remote.sh, so a machine judged too busy for a
# test run is not simultaneously judged fine for a release build.
#
# ONLY the compile moves. Assembly, dylib bundling and codesigning always happen
# here, for three separate reasons, each of which independently rules the remote
# out:
#   - Codesigning needs the login keychain, and over a non-interactive ssh
#     session `codesign --sign "Developer ID Application: ..."` fails with
#     errSecInternalComponent (keychain locked). Signing here keeps the identity
#     resolution above authoritative and the artifact byte-identical to a fully
#     local build.
#   - The .app has to exist on THIS machine to be launched, TCC-granted and
#     live-tested anyway.
#   - AUDIOUT_BUNDLE_DYLIBS=1 walks `otool -L` and copies the referenced
#     Homebrew dylibs from the LOCAL /opt/homebrew. A binary linked on the other
#     Mac records that machine's formula versions, which may not exist here — so
#     the bundling path opts out of the remote entirely (the condition below).
REMOTE_BUILT=0
# shellcheck source=lib/remote.sh
. "$SCRIPT_DIR/lib/remote.sh"
if [ "${AUDIOUT_BUILD_LOCAL:-0}" != "1" ] &&
   [ "${AUDIOUT_BUNDLE_DYLIBS:-0}" != "1" ] &&
   remote_wins; then
  echo "==> Compiling on remote $remote_host (assembly + signing stay here)"
  # Built from the repo root with --package-path, mirroring the local commands
  # below exactly. The products are staged into .remote-products/ inside the
  # synced tree so they can be fetched by a KNOWN relative path — parsing the
  # remote's --show-bin-path output would bake in an architecture triple.
  # \$ escapes keep PWD/BIN/HBIN for the remote shell; $EXECUTABLE and friends
  # expand here.
  REMOTE_CMD="R=\$PWD; \
swift build --build-system native --package-path AudioutCore -c release --product $EXECUTABLE && \
swift build --build-system native --package-path AudioutCore -c release --product $TCC_PROBE_EXECUTABLE && \
BIN=\$(swift build --build-system native --package-path AudioutCore -c release --show-bin-path) && \
swift build --build-system native --package-path AirPlayEngine -c release --product $HELPER_EXECUTABLE \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker \"\$R/scripts/ptp-helper-info.plist\" && \
HBIN=\$(swift build --build-system native --package-path AirPlayEngine -c release --show-bin-path) && \
rm -rf .remote-products && mkdir -p .remote-products && \
cp \"\$BIN/$EXECUTABLE\" \"\$BIN/$TCC_PROBE_EXECUTABLE\" \"\$HBIN/$HELPER_EXECUTABLE\" .remote-products/ && \
cp -R \"\$BIN/$RESOURCE_BUNDLE_NAME\" .remote-products/"

  RRC=0
  remote_run "$REPO_ROOT" "$REMOTE_CMD" || RRC=$?
  if [ "$RRC" -eq 0 ]; then
    STAGE="$OUTPUT_DIR/.remote-products"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    # Fetched release binaries are ~6.5 MB and are dead the moment they have
    # been copied into the bundle. Disk pressure is a recurring problem on this
    # machine (scripts/housekeeping.sh exists for it), so clear them on EVERY
    # exit path rather than leaving a copy behind per build.
    trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
    if remote_fetch "$REPO_ROOT" ".remote-products/$EXECUTABLE" "$STAGE/$EXECUTABLE" &&
       remote_fetch "$REPO_ROOT" ".remote-products/$TCC_PROBE_EXECUTABLE" "$STAGE/$TCC_PROBE_EXECUTABLE" &&
       remote_fetch "$REPO_ROOT" ".remote-products/$HELPER_EXECUTABLE" "$STAGE/$HELPER_EXECUTABLE" &&
       remote_fetch "$REPO_ROOT" ".remote-products/$RESOURCE_BUNDLE_NAME" "$STAGE/$RESOURCE_BUNDLE_NAME"; then
      BUILT_BINARY="$STAGE/$EXECUTABLE"
      BUILT_TCC_PROBE="$STAGE/$TCC_PROBE_EXECUTABLE"
      BUILT_HELPER="$STAGE/$HELPER_EXECUTABLE"
      BUILT_RESOURCE_BUNDLE="$STAGE/$RESOURCE_BUNDLE_NAME"
      chmod +x "$BUILT_BINARY" "$BUILT_TCC_PROBE" "$BUILT_HELPER"
      REMOTE_BUILT=1
      echo "==> Fetched 3 products from $remote_host"
    else
      echo "==> Could not fetch products back — building locally instead" >&2
    fi
  elif [ "$RRC" -eq 2 ]; then
    # Compiled and FAILED there. Never report that as this build's verdict: the
    # toolchains differ (local Swift 6.4 / macOS 27 SDK vs remote 6.3.1 /
    # macOS 26), so a remote-only error is as likely to be skew as a real break.
    # Same asymmetry run-tests.sh uses — accept a remote pass, re-confirm a
    # remote failure here.
    echo "==> Remote compile reported ERRORS — rebuilding locally to confirm" >&2
  else
    echo "==> Remote unavailable — building locally" >&2
  fi
fi

if [ "$REMOTE_BUILT" -eq 0 ]; then
echo "==> Building $EXECUTABLE (release)"
# --build-system native: Xcode 26+/27 made the new "swiftbuild" engine the
# default for `swift build`, but it doesn't forward a C target's cSettings
# unsafeFlags (AirPlayEngine/Package.swift's Homebrew -I paths for libevent/
# libsodium/libgcrypt/libplist) into the clang module dependency scan used by
# Swift targets that `import CAirPlayEngine` — so <event2/thread.h> fails to
# resolve and the build errors out with "could not build module
# 'CAirPlayEngine'". The deprecated native engine still merges those flags
# correctly. Pin it explicitly until Package.swift's header search paths are
# restructured to survive the new engine (or SwiftPM fixes the propagation).
swift build --build-system native --package-path "$PACKAGE_DIR" -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build --build-system native --package-path "$PACKAGE_DIR" -c release --show-bin-path)"
BUILT_BINARY="$BIN_DIR/$EXECUTABLE"
BUILT_RESOURCE_BUNDLE="$BIN_DIR/$RESOURCE_BUNDLE_NAME"
test -x "$BUILT_BINARY" || { echo "error: built binary not found at $BUILT_BINARY" >&2; exit 1; }

# Same package as $EXECUTABLE, same release config — this lands in $BIN_DIR
# alongside it, no second package build needed (contrast with ptp-helper below).
echo "==> Building $TCC_PROBE_EXECUTABLE (release)"
swift build --build-system native --package-path "$PACKAGE_DIR" -c release --product "$TCC_PROBE_EXECUTABLE"
BUILT_TCC_PROBE="$BIN_DIR/$TCC_PROBE_EXECUTABLE"
test -x "$BUILT_TCC_PROBE" || { echo "error: built binary not found at $BUILT_TCC_PROBE" >&2; exit 1; }

# Separate package (AirPlayEngine), separate `swift build` invocation — see
# HELPER_EXECUTABLE comment above for why this binary is built and signed
# apart from the app executable.
echo "==> Building $HELPER_EXECUTABLE (release)"
# -sectcreate __TEXT __info_plist bakes the daemon's Info.plist (CFBundleIdentifier
# etc.) into the Mach-O — mandatory for a standalone-executable SMAppService
# LaunchDaemon (§ HELPER_INFO_PLIST above). Absolute path so it resolves
# regardless of the linker's working directory. Only this bundled/signed build
# carries the section; plain `swift build --product ptp-helper` (dev/tests) omits
# it, which is fine — the section only matters to SMAppService registration.
test -f "$HELPER_INFO_PLIST" || { echo "error: helper Info.plist not found at $HELPER_INFO_PLIST" >&2; exit 1; }
swift build --build-system native --package-path "$ENGINE_PACKAGE_DIR" -c release --product "$HELPER_EXECUTABLE" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$HELPER_INFO_PLIST"
HELPER_BIN_DIR="$(swift build --build-system native --package-path "$ENGINE_PACKAGE_DIR" -c release --show-bin-path)"
BUILT_HELPER="$HELPER_BIN_DIR/$HELPER_EXECUTABLE"
test -x "$BUILT_HELPER" || { echo "error: built helper not found at $BUILT_HELPER" >&2; exit 1; }
fi  # REMOTE_BUILT

# Whichever machine compiled them, the three products must now exist here — the
# rest of this script only ever refers to these three paths.
test -x "$BUILT_BINARY"    || { echo "error: app binary not found at $BUILT_BINARY" >&2; exit 1; }
test -x "$BUILT_TCC_PROBE" || { echo "error: tcc-probe not found at $BUILT_TCC_PROBE" >&2; exit 1; }
test -x "$BUILT_HELPER"    || { echo "error: ptp-helper not found at $BUILT_HELPER" >&2; exit 1; }
test -d "$BUILT_RESOURCE_BUNDLE" || { echo "error: resource bundle not found at $BUILT_RESOURCE_BUNDLE" >&2; exit 1; }

# --- Assemble the bundle --------------------------------------------------
echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp "$BUILT_BINARY" "$MACOS_DIR/$EXECUTABLE"
chmod +x "$MACOS_DIR/$EXECUTABLE"

# ptp-helper ships alongside the app executable; the launchd plist below
# points BundleProgram at this exact bundle-relative path.
cp "$BUILT_HELPER" "$MACOS_DIR/$HELPER_EXECUTABLE"
chmod +x "$MACOS_DIR/$HELPER_EXECUTABLE"

# tcc-probe ships alongside the app executable too — TCCProbeRunner.locateHelper()
# resolves it at exactly Contents/MacOS/tcc-probe, relative to the running bundle.
cp "$BUILT_TCC_PROBE" "$MACOS_DIR/$TCC_PROBE_EXECUTABLE"
chmod +x "$MACOS_DIR/$TCC_PROBE_EXECUTABLE"

# SwiftPM resource bundle → Contents/Resources. `Bundle.module`'s generated
# accessor searches Bundle.main.resourceURL (== Contents/Resources) first, so
# this is where the in-app brand mark becomes reachable at runtime.
mkdir -p "$RESOURCES_DIR"
cp -R "$BUILT_RESOURCE_BUNDLE" "$RESOURCES_DIR/$RESOURCE_BUNDLE_NAME"

# --- SMAppService launchd daemon plist -------------------------------------
# Ships from scripts/ptp-helper.plist with __BUNDLE_ID__ substituted for the
# real BUNDLE_ID (see that file for the SMAppService shape rationale —
# ptp-helper-design.md §2.2, and the BUNDLE_ID-derivation rationale). The
# filename here MUST equal Label + ".plist"; SMAppService.daemon(plistName:)
# resolves the plist by that exact name, not by content.
echo "==> Installing LaunchDaemons plist"
test -f "$HELPER_PLIST_SOURCE" || { echo "error: helper plist not found at $HELPER_PLIST_SOURCE" >&2; exit 1; }
mkdir -p "$LAUNCH_DAEMONS_DIR"
sed "s/__BUNDLE_ID__/$BUNDLE_ID/g" "$HELPER_PLIST_SOURCE" > "$LAUNCH_DAEMONS_DIR/$HELPER_LABEL.plist"

# --- Bundle Homebrew dylibs (opt-in) ---------------------------------------
# The executable currently links Homebrew dylibs (libevent, libsodium,
# libgcrypt, libgpg-error, libplist, ffmpeg + its transitive chain — see
# AirPlayEngine/Package.swift's brewLibFlags) via absolute paths under
# /opt/homebrew or /usr/local, which don't exist on a Mac without Homebrew.
# scripts/bundle-dylibs.sh copies every such dylib (walked transitively via
# otool -L, not a hardcoded list) into Contents/Frameworks and repoints the
# load commands at @rpath, making the bundle self-contained.
#
# Gated behind AUDIOUT_BUNDLE_DYLIBS=1 (default: skip) because it's a
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
# slow/invasive — you don't want it firing on every AUDIOUT_BUNDLE_DYLIBS=1
# build. Invoke it by hand before shipping a distribution build.
if [ "${AUDIOUT_BUNDLE_DYLIBS:-0}" = "1" ]; then
  echo "==> Bundling Homebrew dylibs (AUDIOUT_BUNDLE_DYLIBS=1)"
  "$SCRIPT_DIR/bundle-dylibs.sh" "$APP_BUNDLE"
  echo "    (to PROVE this launches with no Homebrew present, run: scripts/verify-standalone-app.sh \"$APP_BUNDLE\")"
else
  echo "==> Skipping dylib bundling (set AUDIOUT_BUNDLE_DYLIBS=1 to bundle for a Homebrew-less target Mac)"
fi

# --- Sparkle.framework (unconditional) --------------------------------------
# The executable links Sparkle in EVERY build (Package.swift scopes it to the
# AudioutApp target), so the framework has to ship even when
# AUDIOUT_BUNDLE_DYLIBS is unset — an unbundled build would otherwise not
# launch at all. That is also why the @rpath is added here rather than left to
# bundle-dylibs.sh, which only runs on the bundling path.
#
# SwiftPM copies the macOS slice out of the downloaded xcframework, so the
# framework exists once the package has been built or resolved on this machine
# — which a remote-compiled build has not necessarily done. When it's absent we
# fetch it here with a local `swift package resolve`: that downloads and
# extracts the binary artifact (seconds, no compile) without disturbing the
# remote/local split above. NOT `scripts/build.sh` — that check may satisfy
# itself entirely on the remote and leave this machine's .build as cold as it
# found it, so telling the operator to run it would loop forever.
echo "==> Embedding Sparkle.framework"
find_sparkle() {
  if [ -n "${BIN_DIR:-}" ] && [ -d "$BIN_DIR/Sparkle.framework" ]; then
    printf '%s' "$BIN_DIR/Sparkle.framework"
  else
    find "$PACKAGE_DIR/.build/artifacts" -type d -name 'Sparkle.framework' -print -quit 2>/dev/null || true
  fi
}
SPARKLE_FRAMEWORK="$(find_sparkle)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
  echo "    not in this machine's .build — resolving the binary artifact locally"
  swift package resolve --package-path "$PACKAGE_DIR"
  SPARKLE_FRAMEWORK="$(find_sparkle)"
fi
[ -n "$SPARKLE_FRAMEWORK" ] && [ -d "$SPARKLE_FRAMEWORK" ] || {
  echo "ERROR: Sparkle.framework still not found under $PACKAGE_DIR/.build after 'swift package resolve' — run 'AUDIOUT_BUILD_LOCAL=1 bash scripts/build.sh' to force a local build that populates the artifacts" >&2
  exit 1
}
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
# -R (not -RL): a framework is a web of relative symlinks (Versions/Current,
# the top-level Sparkle/Autoupdate/Resources aliases) and resolving them would
# both double the size and break codesign's bundle-format check.
rm -rf "$FRAMEWORKS_DIR/Sparkle.framework"
cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
test -x "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Sparkle" || { echo "ERROR: Sparkle.framework copied but its binary is missing" >&2; exit 1; }
# Same idempotent otool guard bundle-dylibs.sh uses: install_name_tool errors
# out on a duplicate LC_RPATH, and that script may already have added this one.
if ! otool -l "$MACOS_DIR/$EXECUTABLE" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$EXECUTABLE"
fi

# --- App icon --------------------------------------------------------------
# The official icon is authored in Icon Composer (scripts/Audiout.icon) as a
# Liquid Glass icon. Compiling that bundle into the real Liquid Glass asset
# (Assets.car) requires Xcode 26's actool, and Liquid Glass only renders on
# macOS 26 anyway. IMPORTANT: the .icon must be authored in an Icon Composer
# whose format GENERATION matches the actool doing the compile — a mismatch
# makes actool crash with an unhelpful "insert nil object" backtrace (it's
# really "wrong format", surfaced as a crash rather than a clean error). This
# bundle is authored in Icon Composer 1.4 (the generation that ships inside
# Xcode 26.4.x), so Xcode 26.4.x's actool compiles it cleanly. (An earlier
# revision authored in the newer standalone Icon Composer 2.0 crashed 26.4.x's
# 1.4-generation actool for exactly this reason — see also the separate
# post-26.4.1 actool regression FB20183399 / github.com/expo/expo/issues/46121.)
# We ATTEMPT the compile opportunistically and fall back automatically to a
# classic .icns baked from Icon Composer's flattened 1024 "Default" render,
# which keeps the script working unmodified on an Xcode-15 machine (falls back
# every time) while an Xcode-26 machine gets the real Liquid Glass icon.
# NOTE: this is a menu-bar app (LSUIElement) so it has no Dock icon; this icon
# is what Finder, Get Info, the About box, notifications, and any
# Store/distribution listing use.
mkdir -p "$RESOURCES_DIR"
ICON_MODE="icns"
ICON_BUNDLE_SRC="$SCRIPT_DIR/Audiout.icon"
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

# Middle tier: a light/dark appearance-aware icon, built from Icon Composer's
# two flattened 1024 renders as a plain Xcode asset-catalog appiconset (NOT
# the Icon Composer .icon/Liquid Glass format above). This is a much older,
# stable actool code path — distinct from the actively-regressed
# Icon-Composer-specific compiler (see the Liquid Glass block's failure log,
# and https://github.com/expo/expo/issues/46121 / FB20183399 for the known
# Xcode 26.5 actool crash on ANY .icon input, confirmed content-independent).
# Not true dynamic Liquid Glass (no specular/refraction), but a real, correct
# light/dark-switching icon using both of Icon Composer's exported renders.
#
# GATED TO XCODE 16+: a confirmed real-world example (an "Add dark mode app
# icon for macOS Sequoia" PR — github.com/manaflow-ai/cmux/pull/702) uses this
# exact schema, and macOS Sequoia paired with roughly Xcode 16. LEARNED THE
# HARD WAY: on Xcode 15.4, actool ACCEPTS this schema and exits 0 with
# Assets.car produced — silently WITHOUT actually encoding a usable dark
# trait. Loading the compiled icon straight from the bundle's own asset
# catalog (Bundle(path:).image(forResource:)) and forcing both
# NSAppearance.aqua/.darkAqua drawing contexts rendered byte-identical PNGs —
# a real functional failure that a bare `[ -f Assets.car ]` check can't catch.
# So: gate on Xcode major version AND functionally verify light vs dark
# actually render differently before trusting this tier; fall through to the
# classic .icns fallback on either the version gate or the verification
# failing, rather than silently shipping a non-functional "success".
if [ "$ICON_MODE" = "icns" ] && [ -f "$ICON_SOURCE" ] && [ -f "$ICON_SOURCE_DARK" ] \
   && [ -n "$XCODE_MAJOR" ] && [ "$XCODE_MAJOR" -ge 16 ]; then
  echo "==> Xcode $XCODE_MAJOR detected — attempting light/dark appearance-aware icon compile via actool"
  XCASSETS_DIR="$(mktemp -d)/Icons.xcassets"
  APPICONSET_DIR="$XCASSETS_DIR/AppIcon.appiconset"
  mkdir -p "$APPICONSET_DIR"
  cat > "$XCASSETS_DIR/Contents.json" << 'JEOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JEOF
  for s in 16 32 128 256 512; do
    d=$((s * 2))
    sips -z "$s" "$s" "$ICON_SOURCE" --out "$APPICONSET_DIR/icon_${s}x${s}.png" >/dev/null
    sips -z "$d" "$d" "$ICON_SOURCE" --out "$APPICONSET_DIR/icon_${s}x${s}@2x.png" >/dev/null
    sips -z "$s" "$s" "$ICON_SOURCE_DARK" --out "$APPICONSET_DIR/icon_${s}x${s}_dark.png" >/dev/null
    sips -z "$d" "$d" "$ICON_SOURCE_DARK" --out "$APPICONSET_DIR/icon_${s}x${s}@2x_dark.png" >/dev/null
  done
  python3 - "$APPICONSET_DIR/Contents.json" << 'PYEOF'
import json, sys
path = sys.argv[1]
sizes = [16, 32, 128, 256, 512]
images = []
for s in sizes:
    images.append({"filename": f"icon_{s}x{s}.png", "idiom": "mac", "scale": "1x", "size": f"{s}x{s}"})
    images.append({"filename": f"icon_{s}x{s}@2x.png", "idiom": "mac", "scale": "2x", "size": f"{s}x{s}"})
    images.append({"filename": f"icon_{s}x{s}_dark.png", "idiom": "mac", "scale": "1x", "size": f"{s}x{s}",
                    "appearances": [{"appearance": "luminosity", "value": "dark"}]})
    images.append({"filename": f"icon_{s}x{s}@2x_dark.png", "idiom": "mac", "scale": "2x", "size": f"{s}x{s}",
                    "appearances": [{"appearance": "luminosity", "value": "dark"}]})
data = {"images": images, "info": {"author": "xcode", "version": 1}}
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF
  ACTOOL_LD_TMP="$(mktemp -d)"
  if xcrun actool \
      --compile "$RESOURCES_DIR" \
      --platform macosx \
      --minimum-deployment-target "$MIN_MACOS" \
      --app-icon AppIcon \
      --output-partial-info-plist "$ACTOOL_LD_TMP/partial-info.plist" \
      --output-format human-readable-text \
      --notices --warnings \
      "$XCASSETS_DIR" >"$ACTOOL_LD_TMP/actool.log" 2>&1 \
    && [ -f "$RESOURCES_DIR/Assets.car" ]; then
    echo "    actool compiled Assets.car — verifying light and dark actually render differently"
    VERIFY_SWIFT="$(mktemp -d)/verify_appearance.swift"
    cat > "$VERIFY_SWIFT" << 'SWIFTEOF'
import AppKit
import CryptoKit
let appPath = CommandLine.arguments[1]
guard let bundle = Bundle(path: appPath), let image = bundle.image(forResource: "AppIcon") else {
    print("LOADFAIL"); exit(1)
}
func hash(_ appearanceName: NSAppearance.Name) -> String {
    var data: Data? = nil
    NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
        let size = NSSize(width: 256, height: 256)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        data = rep.representation(using: .png, properties: [:])
    }
    guard let d = data else { return "NONE" }
    return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}
print(hash(.aqua) == hash(.darkAqua) ? "IDENTICAL" : "DIFFERS")
SWIFTEOF
    VERIFY_RESULT="$(swift "$VERIFY_SWIFT" "$APP_BUNDLE" 2>/dev/null | tail -1)"
    if [ "$VERIFY_RESULT" = "DIFFERS" ]; then
      echo "    verified: light and dark render differently — using light/dark appearance-aware icon"
      ICON_MODE="lightdark"
    else
      echo "    verification result='$VERIFY_RESULT' (expected DIFFERS) — actool silently produced a non-functional appearance-aware icon on this toolchain; falling back to classic .icns"
      rm -f "$RESOURCES_DIR/Assets.car"
    fi
  else
    echo "    actool did not produce Assets.car for light/dark catalog — falling back to classic .icns (log below)"
    sed 's/^/    actool: /' "$ACTOOL_LD_TMP/actool.log" || true
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
# CFBundleIconName for either compiled-Assets.car mode (actool convention —
# name matches the --app-icon value passed for that mode: the .icon bundle's
# basename for liquidglass, "AppIcon" for the light/dark appiconset),
# CFBundleIconFile for the classic single-image .icns fallback (basename
# without extension, per convention).
if [ "$ICON_MODE" = "liquidglass" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $(basename "$ICON_BUNDLE_SRC" .icon)" "$PLIST"
elif [ "$ICON_MODE" = "lightdark" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$PLIST"
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
#     browse is blocked even with the usage string. These MUST match every type
#     the app browses: _airplay._tcp for AirPlay 2 and _raop._tcp for AP1
#     (NativeDiscovery), _googlecast._tcp for Cast receivers
#     (CastDeviceEnumerator), plus _audiout-pf._tcp — the service setup
#     publishes and then browses for on this same Mac to PROVE the permission
#     was granted (LocalNetworkPrimer's self-discovery). Leave that last one out
#     and the self-browse is silently blocked, so setup can never confirm a
#     grant on a network with no speaker switched on. That name is SHORT on
#     purpose: Bonjour caps a service name at 15 characters, and the longer
#     _audiout-preflight._tcp was rejected outright (BadParam), which is
#     exactly as invisible as leaving it out. Keep it in step with
#     LocalNetworkPrimer.selfServiceType.
plutil -insert NSLocalNetworkUsageDescription -string "$LOCAL_NETWORK_USAGE" "$PLIST"
plutil -insert NSBonjourServices -array "$PLIST"
plutil -insert NSBonjourServices.0 -string "_airplay._tcp" "$PLIST"
plutil -insert NSBonjourServices.1 -string "_raop._tcp" "$PLIST"
plutil -insert NSBonjourServices.2 -string "_audiout-pf._tcp" "$PLIST"
plutil -insert NSBonjourServices.3 -string "_googlecast._tcp" "$PLIST"
plutil -extract NSLocalNetworkUsageDescription raw -o - "$PLIST" >/dev/null || { echo "ERROR: NSLocalNetworkUsageDescription missing from Info.plist" >&2; exit 1; }
plutil -extract NSBonjourServices.0 raw -o - "$PLIST" >/dev/null || { echo "ERROR: NSBonjourServices missing from Info.plist" >&2; exit 1; }
plutil -extract NSBonjourServices.2 raw -o - "$PLIST" >/dev/null || { echo "ERROR: NSBonjourServices is missing the setup self-discovery type — setup could not prove a Local Network grant" >&2; exit 1; }
plutil -extract NSBonjourServices.3 raw -o - "$PLIST" >/dev/null || { echo "ERROR: NSBonjourServices is missing _googlecast._tcp — Cast discovery would be silently blocked" >&2; exit 1; }

# Bluetooth (BT-CONNECT): reconnecting an already-paired speaker touches
# IOBluetooth, which macOS gates behind the Bluetooth TCC prompt — and a
# process WITHOUT this usage string is KILLED on its first touch (SIGABRT, no
# prompt, no error; live-verified 2026-08-07, dev/notes/bt-spike-findings-
# 2026-08-07.md). So this key is a hard requirement, not a nicety — hence the
# same plutil-plus-assert treatment as the audio-capture string above.
plutil -insert NSBluetoothAlwaysUsageDescription -string "$BLUETOOTH_USAGE" "$PLIST"
plutil -extract NSBluetoothAlwaysUsageDescription raw -o - "$PLIST" >/dev/null || { echo "ERROR: NSBluetoothAlwaysUsageDescription missing from Info.plist" >&2; exit 1; }

# Microphone (roadmap 064): the alignment wizard's mic-probe measurement
# records the BUILT-IN mic for a few seconds. A separate TCC bucket from
# System Audio Recording above — same plutil-plus-assert treatment, same
# reason (a silently missing rationale is a bare "wants to record" prompt,
# or on this key a capture that delivers only zeros).
plutil -insert NSMicrophoneUsageDescription -string "$MICROPHONE_USAGE" "$PLIST"
plutil -extract NSMicrophoneUsageDescription raw -o - "$PLIST" >/dev/null || { echo "ERROR: NSMicrophoneUsageDescription missing from Info.plist" >&2; exit 1; }

# --- License server + buy page (release builds only) ------------------------
# AUDIOUT_LICENSE_URL is the base URL of the license server (the Worker in
# ~/Projects/Audiout License Server). Its presence is the whole switch for the
# app's soft license check: with it the app validates the stored key, checks in,
# and can show the unregistered note; without it — a build run from source — it
# does none of those. AUDIOUT_BUY_URL is where "Buy Audiout…" sends the
# user; absent, every buy affordance stays hidden.
#
# Independent of the Sparkle pair below, EXCEPT that a license server already
# knows where its own appcast lives, so it supplies the feed URL when one wasn't
# given explicitly. The SPARKLE_ED_PUBLIC_KEY requirement still applies to that
# derived feed — an unverified update channel is never worth the convenience.
if [ -n "${AUDIOUT_LICENSE_URL:-}" ]; then
  echo "==> Writing AudioutLicenseServerURL ($AUDIOUT_LICENSE_URL)"
  plutil -insert AudioutLicenseServerURL -string "$AUDIOUT_LICENSE_URL" "$PLIST"
  plutil -extract AudioutLicenseServerURL raw -o - "$PLIST" >/dev/null || { echo "ERROR: AudioutLicenseServerURL missing from Info.plist" >&2; exit 1; }
  if [ -z "${SPARKLE_FEED_URL:-}" ]; then
    SPARKLE_FEED_URL="$AUDIOUT_LICENSE_URL/appcast.xml"
    echo "==> Defaulting SPARKLE_FEED_URL to the license server's appcast ($SPARKLE_FEED_URL)"
  fi
else
  echo "==> Skipping AudioutLicenseServerURL (set AUDIOUT_LICENSE_URL for a build that checks its license)"
fi

if [ -n "${AUDIOUT_BUY_URL:-}" ]; then
  echo "==> Writing AudioutBuyURL ($AUDIOUT_BUY_URL)"
  plutil -insert AudioutBuyURL -string "$AUDIOUT_BUY_URL" "$PLIST"
  plutil -extract AudioutBuyURL raw -o - "$PLIST" >/dev/null || { echo "ERROR: AudioutBuyURL missing from Info.plist" >&2; exit 1; }
else
  echo "==> Skipping AudioutBuyURL (set AUDIOUT_BUY_URL to offer a purchase link)"
fi

# --- Sparkle in-app updates (release builds only) ---------------------------
# Set BOTH SPARKLE_FEED_URL and SPARKLE_ED_PUBLIC_KEY to build an updating
# release; set neither for a dev/handover build, which then gets no updater at
# all (AppDelegate creates SPUStandardUpdaterController only when SUFeedURL is
# present, and Settings hides "Check for Updates…" when it didn't).
#
# One without the other is refused rather than defaulted: a feed with no key
# means Sparkle downloads updates it cannot verify, and a key with no feed
# means an updater that can never find anything. Both are silent at build time
# and only surface in a shipped app.
if [ -n "${SPARKLE_FEED_URL:-}" ] || [ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ]; then
  [ -n "${SPARKLE_FEED_URL:-}" ] || { echo "ERROR: SPARKLE_ED_PUBLIC_KEY is set but SPARKLE_FEED_URL is not — an EdDSA key with no appcast is an updater that can never check" >&2; exit 1; }
  [ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ] || { echo "ERROR: SPARKLE_FEED_URL is set but SPARKLE_ED_PUBLIC_KEY is not — an appcast with no EdDSA key means updates are installed unverified" >&2; exit 1; }
  echo "==> Writing Sparkle appcast keys (SUFeedURL, SUPublicEDKey)"
  plutil -insert SUFeedURL -string "$SPARKLE_FEED_URL" "$PLIST"
  plutil -insert SUPublicEDKey -string "$SPARKLE_ED_PUBLIC_KEY" "$PLIST"
  plutil -extract SUFeedURL raw -o - "$PLIST" >/dev/null || { echo "ERROR: SUFeedURL missing from Info.plist" >&2; exit 1; }
  plutil -extract SUPublicEDKey raw -o - "$PLIST" >/dev/null || { echo "ERROR: SUPublicEDKey missing from Info.plist" >&2; exit 1; }
else
  echo "==> Skipping Sparkle appcast keys (set SPARKLE_FEED_URL + SPARKLE_ED_PUBLIC_KEY for an updating release build)"
fi

# --- LSEnvironment: release runtime defaults --------------------------------
# Environment variables LaunchServices injects when the app is launched by
# double-click / `open` (a bundled build), so the release default lives HERE
# rather than baked into the Swift, keeping dev overrides intact: a developer who
# runs the raw Mach-O directly does NOT go through LaunchServices, so LSEnvironment
# is NOT applied and the shell's own env wins (and `swift run`/tests never read
# Info.plist at all).
#
#   AIRPLAY_BACKEND=native — a double-clicked release MUST drive real speakers.
#     BackendKind.resolved() already defaults to `.native` in code (mock is
#     opt-in only), so this is belt-and-suspenders: it makes the release intent
#     explicit AND is robust if the code default ever changes. (It also can't be
#     relied on ALONE — a shared-bundle-id LaunchServices collision can launch
#     this binary while resolving LSEnvironment from a different registration, so
#     the native code default is what actually guarantees real audio.) Override
#     in dev with `AIRPLAY_BACKEND=mock <binary>` (direct exec ignores
#     LSEnvironment) or by running via SwiftPM.
echo "==> Writing LSEnvironment (release backend default)"
plutil -insert LSEnvironment -dictionary "$PLIST"
plutil -insert LSEnvironment.AIRPLAY_BACKEND -string "native" "$PLIST"
plutil -extract LSEnvironment.AIRPLAY_BACKEND raw -o - "$PLIST" >/dev/null || { echo "ERROR: LSEnvironment.AIRPLAY_BACKEND missing from Info.plist — release builds must pin the native backend explicitly (belt-and-suspenders over the native code default)" >&2; exit 1; }

# Opt-in dev diagnostics, baked into LSEnvironment so an `open`-launched bundle
# still sees them: an `open`ed app does NOT inherit the shell env, and it MUST be
# launched via `open` (not the raw binary) for a correct TCC identity — so these
# can't be passed on the command line. Only written when set at build time, so a
# normal release carries none of them.
#   AUDIOUT_STATUS_LABEL — tags the menu-bar item so side-by-side dev builds
#     (which share the bundle id, hence collide in LaunchServices) are visually
#     distinguishable; see the multiple-app-copies-collide hazard.
#   AIRPLAYENGINE_LOG_FILE / _LEVEL — append engine + DACP diagnostics to a file
#     an `open`-launched session (stderr/os_log swallowed) can still be read from.
#   AUDIOUT_TCC_DIAG — starts `TCCBucketDiagnostic`'s once-per-second raw
#     TCC-bucket poll (T1); needed here for the same reason as the others — an
#     `open`ed bundle never sees the shell's env.
#   AIRPLAY_AUDIO_DIAG — `AudioDiag`'s coreaudiod-object event log + live-handle
#     counters, written to the file this names.
#   AIRPLAY_DEBUG_LATENCY — enables the engine's `WriteLatencyProbe`
#     (pts-freshness stats on the write path).
#
# A dev BUNDLE_ID without AUDIOUT_STATUS_LABEL gets one defaulted here (owner
# rule, 2026-07-29): an unlabeled dev build is visually indistinguishable from
# the live menu-bar app. APP_NAME override wins, else the BUNDLE_ID suffix.
if [ "$BUNDLE_ID" != "com.audiout.Audiout" ] && [ -z "${AUDIOUT_STATUS_LABEL:-}" ]; then
  if [ "$APP_NAME" != "Audiout" ]; then AUDIOUT_STATUS_LABEL="$APP_NAME"; else AUDIOUT_STATUS_LABEL="${BUNDLE_ID##*.}"; fi
  echo "==> AUDIOUT_STATUS_LABEL unset with dev BUNDLE_ID — defaulting to \"$AUDIOUT_STATUS_LABEL\""
fi
for diag in AUDIOUT_STATUS_LABEL AIRPLAYENGINE_LOG_FILE AIRPLAYENGINE_LOG_LEVEL AUDIOUT_TCC_DIAG \
            AIRPLAY_AUDIO_DIAG AIRPLAY_DEBUG_LATENCY; do
  eval "val=\${$diag:-}"
  if [ -n "$val" ]; then
    plutil -insert "LSEnvironment.$diag" -string "$val" "$PLIST"
    echo "==> LSEnvironment.$diag = $val (dev diagnostic)"
  fi
done

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

# --- Codesign (Developer ID when available, else ad-hoc; HARDENED RUNTIME) --
# Signs with $CODESIGN_IDENTITY, resolved up in Config: a Developer ID
# Application identity when the keychain has one (the release path — a real Team
# ID lets the SMAppService daemon register, and the build is Gatekeeper-
# acceptable + notarization-ready), else ad-hoc ("-") for a local/CI build.
# Notarization is a SEPARATE, later step (submit the signed .app to Apple's
# notary service); this script signs only.
#
# `--options runtime` (hardened runtime) is a SECURITY REQUIREMENT, not just a
# distribution one: this app holds the "System Audio Recording" TCC grant, and
# without the hardened runtime a local attacker could `DYLD_INSERT_LIBRARIES` a
# dylib into the process and inherit that grant. The hardened runtime makes dyld
# ignore DYLD_* env vars, closing that vector — as long as we withhold the
# allow-dyld-environment-variables entitlement (we do). Library validation is
# deliberately DISABLED in scripts/Audiout.entitlements even though bundled
# dylibs are re-signed here (inside-out): ad-hoc signatures have no Team ID, so
# library validation would reject them. Developer ID would allow re-enabling it.
# The DYLD_INSERT protection does NOT depend on library validation.
#
# NOT `--deep`: it is deprecated by Apple and signs nested code with the wrong
# (inherited) options. When AUDIOUT_BUNDLE_DYLIBS=1 the bundle now has ~20
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
  echo "==> Codesigning bundled dylibs in Contents/Frameworks (identity: $CODESIGN_IDENTITY, inside-out, before the app)"
  # --options runtime for consistency with the hardened-runtime posture below;
  # these are library code, not the entitled executable, so no --entitlements
  # here — only the main executable needs the audio-capture / local-network /
  # disable-library-validation entitlements.
  find "$CONTENTS/Frameworks" -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
    echo "    signing $(basename "$dylib")"
    codesign --force $TIMESTAMP_FLAG --options runtime --sign "$CODESIGN_IDENTITY" "$dylib"
  done
fi

# Sparkle.framework carries its OWN nested code — two XPC service bundles, the
# Updater.app progress UI and the Autoupdate installer helper — each of which
# is a separate signable unit that the outer app's `--verify --deep --strict`
# will inspect. Sparkle ships it pre-signed by the Sparkle project, but that
# signature is not ours: notarization requires every Mach-O in the bundle to
# carry this build's identity, so re-sign the lot with --force, innermost
# first (XPC services and helpers before the framework version that contains
# them) for the same reason the dylibs above are signed before the app.
#
# The framework's VERSION directory is what gets signed, not the top-level
# Sparkle.framework path: this is a versioned (Versions/B + Versions/Current)
# framework, where the signature belongs inside the version being signed.
#
# No --entitlements, same rule as the dylibs and helpers: only the main
# executable is entitled.
SPARKLE_VERSION_DIR="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE_VERSION_DIR" ]; then
  echo "==> Codesigning Sparkle.framework (identity: $CODESIGN_IDENTITY, inside-out, before the app)"
  for nested in "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
                "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
                "$SPARKLE_VERSION_DIR/Updater.app" \
                "$SPARKLE_VERSION_DIR/Autoupdate"; do
    test -e "$nested" || { echo "ERROR: expected Sparkle component missing: $nested" >&2; exit 1; }
    echo "    signing $(basename "$nested")"
    codesign --force $TIMESTAMP_FLAG --options runtime --sign "$CODESIGN_IDENTITY" "$nested"
  done
  echo "    signing Sparkle.framework/Versions/B"
  codesign --force $TIMESTAMP_FLAG --options runtime --sign "$CODESIGN_IDENTITY" "$SPARKLE_VERSION_DIR"
fi
# ptp-helper is a second Mach-O living directly in Contents/MacOS (not nested
# inside a Frameworks/Plugins bundle), so `codesign --deep` on the outer app
# would NOT reach it (--deep only recurses into nested bundles) — sign it
# explicitly here, inside-out, same rule as the Frameworks dylibs above and
# same reason ("WHY ORDER MATTERS" comment above still applies verbatim: this
# binary was copied after its own build, no re-signing-invalidation risk here,
# but the outer app's --verify --strict still expects everything under
# Contents to already carry a valid signature by the time IT is signed).
#
# No --entitlements: this is a plain root PTP/UDP daemon launched by launchd,
# not sandboxed, holds no TCC grant (no audio capture, no Bonjour/network-client
# API) and needs no keychain/JIT/etc access — the app's audio-capture and
# local-network entitlements are scoped to the main executable only. Confirmed
# by reading AirPlayEngine/Sources/ptp-helper/main.c: it only calls
# airptp_daemon_bind/airptp_daemon_start/airptp_end plus libc signal/socket
# calls. Do not add entitlements to this binary speculatively.
echo "==> Codesigning ptp-helper (identity: $CODESIGN_IDENTITY, inside-out, before the app)"
codesign --force $TIMESTAMP_FLAG --options runtime --sign "$CODESIGN_IDENTITY" "$MACOS_DIR/$HELPER_EXECUTABLE"
codesign --verify --strict "$MACOS_DIR/$HELPER_EXECUTABLE"

# tcc-probe is the same shape as ptp-helper above: a second Mach-O directly in
# Contents/MacOS, so --deep on the outer app wouldn't reach it either — sign it
# here, inside-out, same reason. No --entitlements: it only calls the private
# read-only TCCAccessPreflight (see Sources/tcc-probe/main.swift) — no audio
# capture, no network, no keychain/JIT access — so, same as ptp-helper, it gets
# no entitlements of its own; the app's audio-capture/local-network entitlements
# stay scoped to the main executable only.
echo "==> Codesigning tcc-probe (identity: $CODESIGN_IDENTITY, inside-out, before the app)"
codesign --force $TIMESTAMP_FLAG --options runtime --sign "$CODESIGN_IDENTITY" "$MACOS_DIR/$TCC_PROBE_EXECUTABLE"
codesign --verify --strict "$MACOS_DIR/$TCC_PROBE_EXECUTABLE"

echo "==> Codesigning app (identity: $CODESIGN_IDENTITY, hardened runtime)"
ENTITLEMENTS="$SCRIPT_DIR/Audiout.entitlements"
test -f "$ENTITLEMENTS" || { echo "error: entitlements file not found at $ENTITLEMENTS" >&2; exit 1; }
codesign --force $TIMESTAMP_FLAG --options runtime --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
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

# ptp-helper isn't nested code (§ above), so the --deep verify above never looked
# at it — assert its bundled artifacts directly instead of trusting the copy step.
test -x "$MACOS_DIR/$HELPER_EXECUTABLE" || { echo "ERROR: $MACOS_DIR/$HELPER_EXECUTABLE missing after assembly" >&2; exit 1; }
test -f "$LAUNCH_DAEMONS_DIR/$HELPER_LABEL.plist" || { echo "ERROR: $LAUNCH_DAEMONS_DIR/$HELPER_LABEL.plist missing after assembly" >&2; exit 1; }
codesign --verify --strict "$MACOS_DIR/$HELPER_EXECUTABLE" || { echo "ERROR: codesign --verify --strict failed on ptp-helper" >&2; exit 1; }

# tcc-probe is the same shape (not nested code, so --deep never looked at it either).
test -x "$MACOS_DIR/$TCC_PROBE_EXECUTABLE" || { echo "ERROR: $MACOS_DIR/$TCC_PROBE_EXECUTABLE missing after assembly" >&2; exit 1; }
codesign --verify --strict "$MACOS_DIR/$TCC_PROBE_EXECUTABLE" || { echo "ERROR: codesign --verify --strict failed on tcc-probe" >&2; exit 1; }

echo "==> Done: $APP_BUNDLE"
