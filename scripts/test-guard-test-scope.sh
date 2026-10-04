#!/bin/bash
# Fast tests for .githooks/guard-test-scope.sh, the script that picks which
# suites Guard 4 runs on a branch commit.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# The scope script reads the staged index of the repo it runs in, so every case
# stages real files in a throwaway clone under $TMPDIR and runs the scope
# script from THIS checkout against it (the clone holds only committed files,
# so an uncommitted edit to the scope script is still the one under test).
# No build, no test run: the whole file takes a few seconds.
#
# Usage: scripts/test-guard-test-scope.sh

set -uo pipefail   # deliberately NOT -e: a case failing must not stop the rest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SCOPE="$REPO/.githooks/guard-test-scope.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok — $1"; }

CLONE="$TMP_DIR/clone with space"   # the real checkout path has a space too
git clone -q --shared "$REPO" "$CLONE" || { echo "clone failed" >&2; exit 1; }
SRC=AudioutCore/Sources

# scope_for <path...>: stage an edit to each path in a clean clone, print scope.
scope_for() {
  git -C "$CLONE" reset -q --hard
  for p in "$@"; do
    echo "// scope test" >> "$CLONE/$p"
    git -C "$CLONE" add -- "$p"
  done
  (cd "$CLONE" && env -u AUDIOUT_FULL_SUITE sh "$SCOPE")
}

has_suite() { printf '%s\n' "$1" | tr '|' '\n' | grep -qx "$2"; }

# --- Rule 1: a `Type+Aspect.swift` file maps like `Type.swift` ----------------

base="$(scope_for "$SRC/AudioutCore/NativeBackend.swift")"
ext="$(scope_for "$SRC/AudioutCore/NativeBackend+Bluetooth.swift")"
if [ "$base" = FULL ] || [ -z "$base" ]; then
  fail "NativeBackend.swift itself printed '$base'"
elif [ "$ext" = "$base" ]; then
  ok "NativeBackend+Bluetooth.swift runs the NativeBackend suites"
else
  fail "NativeBackend+Bluetooth.swift printed '$ext', expected '$base'"
fi

base="$(scope_for "$SRC/AudioutPopoverUI/PopoverController.swift")"
ext="$(scope_for "$SRC/AudioutPopoverUI/PopoverController+SyncDrawer.swift")"
if [ "$base" = FULL ] || [ -z "$base" ]; then
  fail "PopoverController.swift itself printed '$base'"
elif [ "$ext" = "$base" ]; then
  ok "PopoverController+SyncDrawer.swift runs the PopoverController suites"
else
  fail "PopoverController+SyncDrawer.swift printed '$ext', expected '$base'"
fi

# --- Rule 2: an unmatched UI file maps by the targets that can reach it -------

# GroupEditorViewController.swift has no GroupEditorViewController*Tests.swift.
# AudioutWindowUI is imported directly and through AudioutPopoverUI; nothing
# that imports only AudioutOnboardingUI or only AudioutSharedUI can reach it.
got="$(scope_for "$SRC/AudioutWindowUI/GroupEditorViewController.swift")"
if [ "$got" = FULL ]; then
  fail "GroupEditorViewController.swift printed FULL"
else
  missing=""
  for s in SidebarActionsTests PopoverControllerTests; do
    has_suite "$got" "$s" || missing="$missing $s"
  done
  extra=""
  for s in OnboardingWindowLevelTests LevelMeterViewTests; do
    has_suite "$got" "$s" && extra="$extra $s"
  done
  if [ -z "$missing$extra" ]; then
    ok "unmatched AudioutWindowUI file runs WindowUI + PopoverUI importers only"
  else
    fail "unmatched AudioutWindowUI file: missing [$missing ] unexpected [$extra ]"
  fi
fi

got="$(scope_for "$SRC/AudioutCore/OutputBackend.swift")"
[ "$got" = FULL ] && ok "unmatched AudioutCore file runs FULL" \
  || fail "unmatched AudioutCore file printed '$got', expected FULL"

got="$(scope_for "$SRC/AudioutApp/AppDelegate.swift")"
[ "$got" = FULL ] && ok "AudioutApp file runs FULL" \
  || fail "AudioutApp file printed '$got', expected FULL"

# --- Existing fail-closed rule: a deletion is FULL ----------------------------

git -C "$CLONE" reset -q --hard
git -C "$CLONE" rm -q -- "$SRC/AudioutCore/NativeBackend+Tone.swift"
got="$(cd "$CLONE" && env -u AUDIOUT_FULL_SUITE sh "$SCOPE")"
[ "$got" = FULL ] && ok "a deleted Swift file runs FULL" \
  || fail "a deleted Swift file printed '$got', expected FULL"

# --- The dependents table matches AudioutCore/Package.swift -------------------

# Library targets and their target dependencies, read from Package.swift: one
# "<target> <dependency>" line per edge, plus "<target> -" for every target.
edges="$(awk '
  /^[[:space:]]*\.target\(/                           { lib = 1; name = ""; deps = 0; next }
  /^[[:space:]]*\.(executableTarget|testTarget)\(/   { lib = 0; next }
  lib && name == "" && match($0, /name: "[^"]+"/) {
    name = substr($0, RSTART + 7, RLENGTH - 8); print name, "-"
  }
  lib && /dependencies:/ { deps = 1 }
  lib && deps {
    line = $0
    while (match(line, /"[A-Za-z0-9_]+"/)) {
      print name, substr(line, RSTART + 1, RLENGTH - 2)
      line = substr(line, RSTART + RLENGTH)
    }
    if ($0 ~ /\]/) deps = 0
  }
' "$REPO/AudioutCore/Package.swift")"

pkg_targets="$(printf '%s\n' "$edges" | awk '$2 == "-" {print $1}' | sort)"
eval "$(sed -n '/^library_targets=/p' "$SCOPE")"
eval "$(sed -n '/^dependents_of() {/,/^}/p' "$SCOPE")"
script_targets="$(printf '%s\n' $library_targets | sort)"
if [ "$pkg_targets" = "$script_targets" ]; then
  ok "library_targets lists every .target in Package.swift"
else
  fail "library_targets differs from Package.swift's .target list"
  diff <(echo "$script_targets") <(echo "$pkg_targets") >&2
fi

table_ok=1
for t in $pkg_targets; do
  # Dependency names that are not library targets (products such as
  # AirPlayEngine or AudioutField) drop out here.
  want="$(printf '%s\n' "$edges" | awk -v t="$t" '$2 == t {print $1}' | sort -u)"
  have="$(printf '%s\n' $(dependents_of "$t") | grep -v '^$' | sort -u)"
  if [ "$want" != "$have" ]; then
    table_ok=0
    fail "dependents_of $t is [$(echo $have)], Package.swift says [$(echo $want)]"
  fi
done
[ "$table_ok" = 1 ] && ok "dependents_of matches every dependencies: block in Package.swift"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES guard-test-scope test(s) FAILED" >&2
  exit 1
fi
echo "all guard-test-scope tests passed"
