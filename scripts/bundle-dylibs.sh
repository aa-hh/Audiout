#!/bin/bash
# bundle-dylibs.sh — copy every Homebrew dylib the app's Mach-O binaries load
# (transitively) into Contents/Frameworks and repoint the load commands at
# @rpath, so the shipped .app runs on a Mac with NO Homebrew installed.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# WHY THIS EXISTS: AirPlayEngine/Package.swift links libevent, libsodium,
# libgcrypt, libgpg-error, libplist, and ffmpeg (avcodec/avutil/swresample)
# straight out of the user's Homebrew prefix (see brewLibFlags there). That's
# fine for local dev (Homebrew is on the build machine) but means the built
# binary hard-references absolute paths like
# /opt/homebrew/opt/libevent/lib/libevent-2.1.7.dylib — which do not exist on
# a machine without Homebrew, or with different formula versions. This script
# walks the REAL dependency graph on THIS machine (not a hardcoded list —
# ffmpeg's own dependency set varies with how the user's brew build was
# configured: x264, aom, dav1d, lame, opus, vpx, etc. are pulled in
# transitively and can only be discovered by actually running otool -L) and
# makes the app self-contained.
#
# Usage: scripts/bundle-dylibs.sh <path-to-.app>
# Every command below is a paste-proof one-liner — no backslash continuations.
#
# NOTE ON BASH VERSION: macOS ships bash 3.2 (no associative arrays), and this
# script deliberately runs under /bin/bash without assuming a newer one is on
# PATH — so dedup/visited-set bookkeeping below uses plain temp files + grep,
# not `declare -A`. Don't "modernize" this to associative arrays; it'll break
# on a stock Mac.
#
# LICENSE NOTE (LGPL §6, libgcrypt/libgpg-error/libplist/ffmpeg): dylibs are
# copied and relinked as separate, independently-swappable .dylib files in
# Contents/Frameworks — never statically merged/combined into the executable
# or into each other. That preserves the user's right to substitute a
# compatible version of any one of them. Do not change that.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-to-.app>" >&2
  exit 1
fi

APP_BUNDLE="$1"
EXECUTABLE_NAME="AudioutApp"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"

test -x "$EXECUTABLE" || { echo "error: executable not found at $EXECUTABLE" >&2; exit 1; }

mkdir -p "$FRAMEWORKS_DIR"

# --- Bookkeeping (plain files, not associative arrays — see NOTE above) ----
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
VISITED_FILE="$WORK_DIR/visited"      # realpaths of Mach-Os we've run otool -L on
COPIED_FILE="$WORK_DIR/copied"        # "<realpath> <basename>" for every dylib copied so far
QUEUE_FILE="$WORK_DIR/queue"          # on-disk paths still to scan
touch "$VISITED_FILE" "$COPIED_FILE" "$QUEUE_FILE"
printf '%s\n' "$EXECUTABLE" >> "$QUEUE_FILE"

# A dependency counts as "Homebrew" if its real (symlink-resolved) path lives
# under either brew prefix layout — Apple Silicon (/opt/homebrew) or Intel
# (/usr/local). Matched on the REAL path (not the literal load-command
# string) so e.g. /opt/homebrew/lib/libfoo.dylib -> Cellar path both count.
is_homebrew_realpath() {
  case "$1" in
    /opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*|/usr/local/lib/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Look up the bundled basename already assigned to a given realpath, if any.
copied_basename_for() {
  awk -v r="$1" '$1 == r { print $2; found=1 } END { if (!found) exit 1 }' "$COPIED_FILE"
}

echo "==> Discovering + bundling Homebrew dylibs for $EXECUTABLE_NAME"

# --- BFS over the Mach-O dependency graph ----------------------------------
# Pop one path off the queue each iteration (plain-file queue, portable under
# bash 3.2). For each of its dependencies that resolves (via realpath) to a
# Homebrew path: copy it into Contents/Frameworks/ (once, dedup'd by
# realpath), set its own -id to @rpath/<basename>, rewrite the REFERENCE in
# the current file to @rpath/<basename>, and enqueue the copy so its own
# transitive deps get walked too (this is how the variable ffmpeg chain
# — x264/aom/dav1d/lame/opus/vpx/etc — gets picked up without a hardcoded
# list: whatever THIS machine's ffmpeg actually links is what gets walked).
while [ -s "$QUEUE_FILE" ]; do
  current="$(head -n 1 "$QUEUE_FILE")"
  tail -n +2 "$QUEUE_FILE" > "$QUEUE_FILE.tmp" && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"

  current_real="$(realpath "$current")"
  if grep -Fxq "$current_real" "$VISITED_FILE"; then
    continue
  fi
  echo "$current_real" >> "$VISITED_FILE"

  # otool -L header line is the file's own path (executables) or its own
  # LC_ID_DYLIB (dylibs, already rewritten to @rpath/... by the time we get
  # here for anything we bundled) — skip it, only the remaining lines are
  # real dependencies. Each dependency line looks like:
  #   "        /opt/homebrew/opt/libevent/lib/libevent-2.1.7.dylib (compatibility version ...)"
  otool -L "$current" | tail -n +2 | awk '{print $1}' | while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    case "$dep" in
      @rpath/*|@loader_path/*|@executable_path/*) continue ;;
    esac
    dep_real="$(realpath "$dep" 2>/dev/null || true)"
    [ -z "$dep_real" ] && continue
    if ! is_homebrew_realpath "$dep_real"; then
      continue
    fi

    if existing="$(copied_basename_for "$dep_real")"; then
      dep_basename="$existing"
    else
      dep_basename="$(basename "$dep_real")"
      dest="$FRAMEWORKS_DIR/$dep_basename"
      echo "    + $dep_basename  (from $dep_real)"
      cp "$dep_real" "$dest"
      chmod u+w "$dest"
      install_name_tool -id "@rpath/$dep_basename" "$dest"
      echo "$dep_real $dep_basename" >> "$COPIED_FILE"
      printf '%s\n' "$dest" >> "$QUEUE_FILE"
    fi

    # Repoint THIS reference (in $current, whether that's the main executable
    # or another already-bundled dylib) at the bundled copy. install_name_tool
    # matches on the literal load-command string, so use $dep (the string
    # otool printed), not $dep_real.
    install_name_tool -change "$dep" "@rpath/$dep_basename" "$current"
  done
done

# --- rpath on the main executable -------------------------------------------
# So @rpath/<basename> references resolve at load time. Harmless to call
# add_rpath more than once across re-runs would error ("would duplicate") —
# guard with otool -l/grep so re-running this script on an already-bundled
# app is idempotent.
if ! otool -l "$EXECUTABLE" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"
fi

BUNDLED_COUNT="$(wc -l < "$COPIED_FILE" | tr -d ' ')"
echo "==> Bundled $BUNDLED_COUNT Homebrew dylib(s) into $FRAMEWORKS_DIR"
