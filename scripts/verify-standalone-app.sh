#!/bin/bash
# verify-standalone-app.sh — PROVE the built .app is actually self-contained by
# launching it with every Homebrew library it needs made unreachable.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# WHY THIS EXISTS: scripts/bundle-dylibs.sh copies the Homebrew dylibs into
# Contents/Frameworks and repoints load commands at @rpath, and make-app.sh
# checks the result with `otool -L` / `codesign`. But every one of those checks
# runs on a machine that HAS Homebrew installed — so they prove the load
# commands LOOK right, not that the app actually LAUNCHES when Homebrew is gone.
# Those are different claims. A single missed dependency (a dylib bundle-dylibs
# didn't walk, an @rpath that resolves to a Homebrew path by accident, a load
# command install_name_tool didn't rewrite) is invisible to otool-on-a-dev-box
# and shows up only as a dyld "Library not loaded / image not found" abort on
# the target Mac. This script manufactures that target Mac locally, temporarily,
# by hiding the exact Homebrew directories this bundle used to depend on, then
# launching the app and confirming it stays up.
#
# TWO INDEPENDENT CHECKS:
#   1. STATIC  — walk every Mach-O in the bundle and assert NO remaining
#                LC_LOAD_DYLIB points at an absolute Homebrew path. Cheap; run
#                first so an obviously-broken build fails before we touch disk.
#   2. DYNAMIC — rename the Homebrew keg directories this bundle's dylibs came
#                from (so those files genuinely vanish from the filesystem),
#                launch Contents/MacOS/<exe> with a scrubbed PATH, and confirm
#                the process is still alive N seconds later with no dyld error.
#
# ############################################################################
# # SAFETY: this script MOVES REAL DIRECTORIES on the developer's disk. The   #
# # single most important property is that it ALWAYS puts them back — on      #
# # success, on failure, on Ctrl-C, on SIGTERM, on a crash mid-run. That is   #
# # what the RESTORE trap below guarantees. Do not weaken it. Every rename is  #
# # recorded BEFORE it happens and restored by the trap, so even a kill in    #
# # the middle of the rename loop leaves Homebrew intact.                     #
# ############################################################################
#
# Usage: scripts/verify-standalone-app.sh [path-to-.app]   (default: build/Audiouter.app)
# Every command below is a paste-proof one-liner — no backslash continuations.
#
# BASH VERSION: like bundle-dylibs.sh, this must run under macOS's stock bash
# 3.2 — no associative arrays, no `mapfile`. Bookkeeping uses plain temp files.

set -euo pipefail

# --- Args / paths ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Default matches make-app.sh's default output location (its OUTPUT_DIR is
# $REPO_ROOT/build and APP_NAME is Audiouter) so `verify-standalone-app.sh` with
# no argument checks the app a plain `make-app.sh` just produced.
APP_BUNDLE="${1:-$REPO_ROOT/build/Audiouter.app}"
EXECUTABLE_NAME="AudiouterApp"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"

test -d "$APP_BUNDLE"   || { echo "error: app bundle not found at $APP_BUNDLE" >&2; exit 1; }
test -x "$EXECUTABLE"    || { echo "error: executable not found at $EXECUTABLE" >&2; exit 1; }

# --- Homebrew prefix matching (kept in lockstep with bundle-dylibs.sh) ------
# A real (symlink-resolved) path counts as "Homebrew" if it lives under either
# brew prefix layout — Apple Silicon (/opt/homebrew) or Intel (/usr/local).
# THIS PREDICATE MUST STAY IDENTICAL to is_homebrew_realpath() in
# scripts/bundle-dylibs.sh: if that script bundles a dylib this one doesn't
# recognise as Homebrew (or vice versa), the static check and the bundler
# disagree and this whole verification is meaningless. bundle-dylibs.sh is not
# source-able (it runs top-to-bottom with side effects on include), so the
# predicate is duplicated here verbatim rather than shared — if you change one,
# change both, and the negative-control run (step 3 in the task) is the
# backstop that catches a drift.
is_homebrew_realpath() {
  case "$1" in
    /opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*|/usr/local/lib/*) return 0 ;;
    *) return 1 ;;
  esac
}
# Same set, but matched against the LITERAL load-command string otool prints
# (which is an absolute path, not yet symlink-resolved) — used by the static
# check, because a lingering LC_LOAD_DYLIB records the string, and that string
# is exactly what dyld would try (and fail) to open on a Homebrew-less Mac.
is_homebrew_loadpath() { is_homebrew_realpath "$1"; }

# --- Scratch bookkeeping ---------------------------------------------------
WORK_DIR="$(mktemp -d)"
# List of "<hidden-temp-path>\t<original-path>" for every directory we rename,
# appended to BEFORE each mv so the trap can always undo a partial run.
MOVES_FILE="$WORK_DIR/moves"
touch "$MOVES_FILE"
APP_PID=""

# --- THE RESTORE TRAP (the load-bearing safety mechanism) ------------------
# Fires on EVERY exit path: normal return, `set -e` abort, Ctrl-C (INT),
# SIGTERM, SIGHUP. It (a) kills the test-launched app so we never strand a
# stray Audiouter, then (b) moves every renamed Homebrew directory back to its
# original name. Restore reads MOVES_FILE bottom-up (reverse order) purely for
# tidiness; each entry is independent. We DELIBERATELY do not `set -e` inside
# the trap — if one restore fails we still attempt the rest and shout loudly,
# rather than bailing and leaving more dirs hidden.
restore_all() {
  # Kill the launched app first (ignore errors — it may have already exited).
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [ -s "$MOVES_FILE" ]; then
    # Reverse the file so most-recent move is undone first.
    local restore_failed=0
    while IFS="$(printf '\t')" read -r hidden original; do
      [ -z "$hidden" ] && continue
      if [ -e "$hidden" ]; then
        if mv "$hidden" "$original" 2>/dev/null; then
          :
        else
          echo "!!! FAILED to restore Homebrew dir: $hidden -> $original" >&2
          echo "!!! RESTORE IT BY HAND: mv \"$hidden\" \"$original\"" >&2
          restore_failed=1
        fi
      elif [ -e "$original" ]; then
        : # already back (double-fire) — nothing to do.
      else
        echo "!!! Homebrew dir missing on BOTH paths (hidden=$hidden original=$original)" >&2
        restore_failed=1
      fi
    done < <(tail -r "$MOVES_FILE")
    if [ "$restore_failed" = "1" ]; then
      echo "!!! One or more Homebrew directories may still be hidden — see messages above." >&2
    fi
  fi
  rm -rf "$WORK_DIR" 2>/dev/null || true
}
# INT/TERM/HUP re-raise conceptually via EXIT (bash runs EXIT after these), so a
# single EXIT handler suffices; but trap them explicitly too so a signal during
# a blocking `wait`/`sleep` still routes through restore_all promptly.
trap restore_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

echo "==> Verifying standalone launch of: $APP_BUNDLE"

# --- Enumerate the bundle's Mach-Os ----------------------------------------
# The main executable plus every dylib bundle-dylibs.sh copied into Frameworks.
MACHO_LIST="$WORK_DIR/machos"
printf '%s\n' "$EXECUTABLE" > "$MACHO_LIST"
if [ -d "$FRAMEWORKS_DIR" ]; then
  # -print0 + read -d '' so a space in the repo path can't split a filename.
  find "$FRAMEWORKS_DIR" -name '*.dylib' -print0 | while IFS= read -r -d '' d; do
    printf '%s\n' "$d"
  done >> "$MACHO_LIST"
fi

# ===========================================================================
# CHECK 1 — STATIC: no remaining absolute Homebrew LC_LOAD_DYLIB anywhere.
# ===========================================================================
echo "==> [static] Scanning Mach-O load commands for leftover Homebrew paths"
STATIC_OFFENDERS="$WORK_DIR/offenders"
touch "$STATIC_OFFENDERS"
while IFS= read -r macho; do
  [ -z "$macho" ] && continue
  # otool -L line 1 is the file's own id/path — skip it (tail -n +2); the rest
  # are its LC_LOAD_DYLIB references. Column 1 is the recorded path string.
  otool -L "$macho" | tail -n +2 | awk '{print $1}' | while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    case "$dep" in
      @rpath/*|@loader_path/*|@executable_path/*|/usr/lib/*|/System/*) continue ;;
    esac
    if is_homebrew_loadpath "$dep"; then
      echo "  OFFENDER: $macho" >&2
      echo "      still loads: $dep" >&2
      printf '%s\t%s\n' "$macho" "$dep" >> "$STATIC_OFFENDERS"
    fi
  done
done < "$MACHO_LIST"
if [ -s "$STATIC_OFFENDERS" ]; then
  echo "==> [static] FAIL: $(wc -l < "$STATIC_OFFENDERS" | tr -d ' ') Homebrew load command(s) remain — the app is NOT self-contained." >&2
  echo "==> These absolute paths do not exist on a Mac without Homebrew; the app would dyld-abort at launch there." >&2
  exit 1
fi
echo "==> [static] PASS: no absolute Homebrew load commands remain."

# ===========================================================================
# CHECK 2 — DYNAMIC: hide the Homebrew dirs, then launch and confirm survival.
# ===========================================================================
# Work out WHICH Homebrew directories to hide. We do NOT hardcode paths: for
# each dylib basename actually present in Contents/Frameworks, we locate the
# matching file inside a Homebrew Cellar and hide its version-specific keg dir
# (…/Cellar/<formula>/<version>). Renaming that keg makes the real file vanish
# AND dangles the /opt/<formula> and /<prefix>/lib symlinks that point into it
# — so an absolute reference like /opt/homebrew/opt/libevent/lib/libevent…dylib
# (what the UNBUNDLED build records) can no longer be opened. That is exactly
# the negative-control failure we want a Homebrew-dependent build to hit.
#
# Why the keg dir and not the whole /opt/homebrew: renaming the entire prefix
# would work but is maximally disruptive and slow; hiding only the specific
# kegs this bundle drew from is targeted, fast, and just as conclusive for
# THESE dylibs. Anything we cannot confidently map to a keg we SKIP (fail
# safe) rather than rename something we're unsure about.

# Candidate Cellar roots: whatever `brew --prefix` reports, plus both standard
# layouts, deduped. Guarded so a machine without brew still runs the static
# check and simply finds nothing to hide (the dynamic launch then happens with
# Homebrew fully present — less conclusive, but never destructive).
CELLAR_ROOTS="$WORK_DIR/cellar_roots"
: > "$CELLAR_ROOTS"
if command -v brew >/dev/null 2>&1; then
  bp="$(brew --prefix 2>/dev/null || true)"
  [ -n "$bp" ] && [ -d "$bp/Cellar" ] && printf '%s\n' "$bp/Cellar" >> "$CELLAR_ROOTS"
fi
[ -d /opt/homebrew/Cellar ] && printf '%s\n' /opt/homebrew/Cellar >> "$CELLAR_ROOTS"
[ -d /usr/local/Cellar ]    && printf '%s\n' /usr/local/Cellar    >> "$CELLAR_ROOTS"
# Dedup.
sort -u "$CELLAR_ROOTS" -o "$CELLAR_ROOTS"

# Build the set of keg dirs to hide by matching each Frameworks dylib basename.
DIRS_TO_HIDE="$WORK_DIR/dirs_to_hide"
: > "$DIRS_TO_HIDE"
if [ -d "$FRAMEWORKS_DIR" ] && [ -s "$CELLAR_ROOTS" ]; then
  find "$FRAMEWORKS_DIR" -name '*.dylib' -print0 | while IFS= read -r -d '' bundled; do
    base="$(basename "$bundled")"
    while IFS= read -r croot; do
      [ -z "$croot" ] && continue
      # There may be several matches (e.g. two openssl@3 versions) — hide every
      # keg that actually contains a file of this name.
      find "$croot" -name "$base" -type f 2>/dev/null | while IFS= read -r hit; do
        real="$(realpath "$hit" 2>/dev/null || true)"
        [ -z "$real" ] && continue
        is_homebrew_realpath "$real" || continue
        # Expect …/Cellar/<formula>/<version>/…/<base>. Strip back to the
        # <version> component: the keg dir is Cellar's grandchild. Peel path
        # segments off until the parent's parent is a Cellar dir.
        keg="$real"
        while [ "$keg" != "/" ]; do
          parent="$(dirname "$keg")"
          grandparent="$(dirname "$parent")"
          case "$grandparent" in
            */Cellar) break ;;   # keg == Cellar/<formula>/<version>
          esac
          keg="$parent"
        done
        # If we walked all the way to / without finding a Cellar grandparent,
        # we don't understand this layout — SKIP (fail safe), don't rename.
        if [ "$keg" = "/" ]; then
          echo "  [skip] can't locate keg dir for $real — leaving it in place" >&2
          continue
        fi
        printf '%s\n' "$keg" >> "$DIRS_TO_HIDE"
      done
    done < "$CELLAR_ROOTS"
  done
fi
sort -u "$DIRS_TO_HIDE" -o "$DIRS_TO_HIDE"

HIDE_COUNT="$(wc -l < "$DIRS_TO_HIDE" | tr -d ' ')"
if [ "$HIDE_COUNT" = "0" ]; then
  echo "==> [dynamic] WARNING: found no Homebrew keg directories to hide." >&2
  echo "==> The dynamic launch below will run with Homebrew fully present, so it" >&2
  echo "==> proves far less. (This is expected only on a machine without Homebrew," >&2
  echo "==> or if the bundle has no Frameworks dylibs.)" >&2
else
  echo "==> [dynamic] Will temporarily hide $HIDE_COUNT Homebrew keg dir(s):"
  while IFS= read -r d; do echo "      $d"; done < "$DIRS_TO_HIDE"
fi

# --- Hide the keg dirs (recording each move BEFORE doing it) ---------------
# Record-then-move ordering is what makes the trap correct even if we're killed
# between the record and the mv, or between two moves.
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  # Defensive: only rename something that exists and is a real directory (not a
  # symlink we'd follow) under a Homebrew prefix. Prefer skipping over risking a
  # rename of the wrong thing.
  if [ ! -d "$dir" ]; then
    echo "  [skip] not a directory (vanished?): $dir" >&2
    continue
  fi
  if [ -L "$dir" ]; then
    echo "  [skip] is a symlink, not a real keg dir: $dir" >&2
    continue
  fi
  is_homebrew_realpath "$dir" || { echo "  [skip] not under a Homebrew prefix: $dir" >&2; continue; }
  hidden="${dir}.verify-standalone-hidden.$$"
  # Record FIRST so the trap can undo this even if the mv is interrupted.
  printf '%s\t%s\n' "$hidden" "$dir" >> "$MOVES_FILE"
  echo "  hiding: $dir"
  mv "$dir" "$hidden"
done < "$DIRS_TO_HIDE"

# --- Launch the app with a scrubbed environment ----------------------------
# Direct exec of the binary (NOT `open`): `open` hands off to launchd and
# swallows the child's stderr, so a real dyld "Library not loaded" abort would
# look like a silent no-op. Exec'ing the Mach-O directly surfaces dyld's error
# on stderr, which we capture and inspect.
#
# `env -i PATH=/usr/bin:/bin` gives the process a minimal environment with NO
# Homebrew on PATH — belt-and-suspenders so nothing brew-related leaks in via
# PATH-dependent resolution. (The primary defense is that the dylibs are gone
# from disk; dyld resolves LC_LOAD_DYLIB by absolute path / @rpath, not PATH —
# but we scrub PATH anyway so no child tool the app spawns finds brew either.)
# HOME is preserved so the app can reach its normal support dirs.
APP_LOG="$WORK_DIR/app.stderr"
echo "==> [dynamic] Launching $EXECUTABLE_NAME with Homebrew hidden + scrubbed PATH"
env -i PATH=/usr/bin:/bin HOME="$HOME" "$EXECUTABLE" >"$APP_LOG" 2>&1 &
APP_PID=$!

# Give dyld time to resolve the whole graph and the app to reach steady state.
# A dyld image-not-found abort happens within the first moment of exec; a menu-
# bar (LSUIElement) app that clears that has "launched" — there's no window to
# check, so "still alive after the settle window, no dyld error logged" is the
# correct success signal.
SETTLE_SECS=5
i=0
while [ "$i" -lt "$SETTLE_SECS" ]; do
  # If the process already died, stop waiting and go diagnose.
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    break
  fi
  sleep 1
  i=$((i + 1))
done

# --- Judge the outcome -----------------------------------------------------
LAUNCH_OK=1
if kill -0 "$APP_PID" 2>/dev/null; then
  echo "==> [dynamic] Process $APP_PID still alive after ${SETTLE_SECS}s."
else
  # It exited during the settle window. Reap it and read its status.
  wait "$APP_PID" 2>/dev/null || true
  echo "==> [dynamic] Process exited during the ${SETTLE_SECS}s settle window." >&2
  LAUNCH_OK=0
fi

# Scan captured stderr for dyld's dependency-resolution failure signatures,
# regardless of whether the process is technically still up (some failures
# print then hang). These strings are dyld's own wording for a missing image.
if grep -Eiq 'Library not loaded|image not found|dyld\[[0-9]+\]:|Symbol not found|no such file.*dylib' "$APP_LOG"; then
  echo "==> [dynamic] dyld error detected in the app's output:" >&2
  echo "    ----------------------------------------------------------------" >&2
  sed 's/^/    /' "$APP_LOG" >&2
  echo "    ----------------------------------------------------------------" >&2
  LAUNCH_OK=0
fi

# Kill the app now (also handled by the trap, but do it explicitly so restore
# doesn't wait on it). Clear APP_PID so the trap doesn't double-kill/wait.
if [ -n "$APP_PID" ]; then
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
fi

if [ "$LAUNCH_OK" != "1" ]; then
  echo "==> [dynamic] FAIL: the app did NOT launch cleanly with Homebrew hidden." >&2
  echo "==> This is the real-world failure a Homebrew-less user would hit. The" >&2
  echo "==> bundle is missing at least one dependency (or an @rpath resolves to a" >&2
  echo "==> Homebrew path). Re-check scripts/bundle-dylibs.sh coverage." >&2
  exit 1
fi

echo "==> [dynamic] PASS: app launched and stayed up with $HIDE_COUNT Homebrew keg(s) hidden."
echo "==> Homebrew directories will now be restored by the exit trap."
echo "==> ALL CHECKS PASSED — $APP_BUNDLE is self-contained."
# The EXIT trap restores every hidden Homebrew directory here.
