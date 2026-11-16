#!/usr/bin/env bash
# Tests for .githooks/guard-test-discipline.sh (Guard 11). Stages edits in a
# shared clone and runs the helper from THIS checkout with cwd in the clone.
# No build, no test run: a few seconds.
#
# Usage: scripts/test-guard-test-discipline.sh

set -uo pipefail   # deliberately NOT -e: a case failing must not stop the rest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO/.githooks/guard-test-discipline.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok — $1"; }

CLONE="$TMP_DIR/clone with space"
git clone -q --shared "$REPO" "$CLONE" || { echo "clone failed" >&2; exit 1; }
T=AudioutCore/Tests/AudioutCoreTests
NEW="$T/GuardProbeTests.swift"
EXISTING="$T/PopoverControllerTests.swift"

reset() { git -C "$CLONE" reset -q --hard; git -C "$CLONE" clean -qfd; }
# run_guard: sets RC and ERR
run_guard() {
  ERR="$(cd "$CLONE" && sh "$GUARD" 2>&1 >/dev/null)"; RC=$?
}
# expect <label> <rc> [stderr-substring]
expect() {
  if [ "$RC" -ne "$2" ]; then fail "$1: exit $RC, wanted $2 ($ERR)"; return; fi
  if [ -n "${3:-}" ] && ! printf '%s' "$ERR" | grep -qF -- "$3"; then
    fail "$1: stderr lacks '$3' ($ERR)"; return
  fi
  ok "$1"
}
write() { printf '%s\n' "$2" > "$CLONE/$1"; git -C "$CLONE" add -- "$1"; }

GOOD='import Testing

/// Turns red if the probe stops returning true.
@Test func a() {}

/// Fails if the probe returns false.
@Test func b() {}'

# (a) nothing staged
reset; run_guard; expect "nothing staged passes" 0

# (b) two tests, both with sentences
reset; write "$NEW" "$GOOD"; run_guard; expect "new file, two sentenced tests" 0

# (c) second lacks it
reset; write "$NEW" 'import Testing

/// Turns red if the probe stops returning true.
@Test func a() {}

/// Checks the probe.
@Test func b() {}'
run_guard; expect "second test lacks sentence" 1 "GuardProbeTests.swift:7"
BAD_C="$(cat "$CLONE/$NEW")"

# (d) sentence three comment lines above
reset; write "$NEW" 'import Testing

/// Turns red if the probe stops returning true.
/// Context line one.
/// Context line two.
@Test func a() {}

// Goes red when the probe lies.
// more
@Test func b() {}'
run_guard; expect "sentence several lines above" 0

# (e) existing file
reset; printf '\n@Test func guardProbe() {}\n' >> "$CLONE/$EXISTING"; git -C "$CLONE" add -- "$EXISTING"
run_guard; expect "appended test without sentence" 1 "PopoverControllerTests.swift"
reset; printf '\n// Turns red if the probe is removed.\n@Test func guardProbe() {}\n' >> "$CLONE/$EXISTING"; git -C "$CLONE" add -- "$EXISTING"
run_guard; expect "appended test with sentence" 0

# (f) print
reset; printf '\nprint("x")\n' >> "$CLONE/$EXISTING"; git -C "$CLONE" add -- "$EXISTING"
run_guard; expect "print( blocked" 1 "print("
reset; printf '\nprint("x") // print-ok\n' >> "$CLONE/$EXISTING"; git -C "$CLONE" add -- "$EXISTING"
run_guard; expect "print-ok exempts" 0

# (g) one-test new file
reset; write "$NEW" 'import Testing

/// Turns red if the probe stops returning true.
@Test func a() {}'
run_guard; expect "new one-test file blocked" 1 "GuardProbeTests.swift"
reset; write "$NEW" 'import Testing
// new-suite-ok
/// Turns red if the probe stops returning true.
@Test func a() {}'
run_guard; expect "new-suite-ok exempts" 0

# (h) merge exemption with (c) staged
reset; write "$NEW" "$BAD_C"
git -C "$CLONE" rev-parse HEAD > "$CLONE/.git/MERGE_HEAD"
ERR="$(cd "$CLONE" && sh "$GUARD" 2>&1 >/dev/null)"; RC=$?
rm -f "$CLONE/.git/MERGE_HEAD"
expect "a merge commit (MERGE_HEAD) is exempt" 0

# (i) non-test Swift file with print(
reset; printf '\nprint("x")\n' >> "$CLONE/AudioutCore/Sources/AudioutCore/Analytics.swift"
git -C "$CLONE" add -- AudioutCore/Sources/AudioutCore/Analytics.swift
run_guard; expect "non-test source ignored" 0

# (j) attribute line between the sentence and @Test
reset; write "$NEW" 'import Testing

/// Turns red if the probe stops returning true.
@MainActor
@Test func a() {}

/// Fails if the probe returns false.
@available(macOS 14.2, *)
@Test func b() {}'
run_guard; expect "attribute between sentence and @Test" 0

# (k) blank line between the sentence block and @Test
reset; write "$NEW" 'import Testing

/// Turns red if the probe stops returning true.

@Test func a() {}

/// Fails if the probe returns false.

@Test func b() {}'
run_guard; expect "blank line between sentence and @Test" 0

# (l) rename an existing sentence-less test
reset; ln=$(grep -nE '^[[:space:]]*@Test func [A-Za-z]' "$CLONE/$EXISTING" | head -1 | cut -d: -f1)
sed -i.bak "${ln}s/@Test func /@Test func renamed/" "$CLONE/$EXISTING"; rm -f "$CLONE/$EXISTING.bak"; git -C "$CLONE" add -- "$EXISTING"
run_guard; expect "renamed existing test passes" 0

# (m) one @Test removed, two added without sentences (a rename plus a new test): the new one blocks
reset; ln=$(grep -nE '^[[:space:]]*@Test func [A-Za-z]' "$CLONE/$EXISTING" | head -1 | cut -d: -f1)
sed -i.bak "${ln}s/@Test func /@Test func renamed/" "$CLONE/$EXISTING"
sed -i.bak "${ln}a\\
@Test func guardProbeNew() {}" "$CLONE/$EXISTING"; rm -f "$CLONE/$EXISTING.bak"; git -C "$CLONE" add -- "$EXISTING"
run_guard; expect "rename plus new test blocks" 1 "PopoverControllerTests.swift"

# (n) sentence above a suite header does not cover a bare @Test inside it
reset; write "$NEW" 'import Testing

/// This suite fails if the probe breaks.
@Suite struct Probe {
@Test func a() {}
}'
run_guard; expect "suite header sentence not borrowed" 1 "GuardProbeTests.swift:5"

# (o) sentence on the @Test itself inside a suite
reset; write "$NEW" 'import Testing

@Suite struct Probe {
/// Fails if the probe returns false.
@Test func a() {}
/// Turns red if the probe stops returning true.
@Test func b() {}
}'
run_guard; expect "sentence on the test inside a suite" 0

# (p) real-time waits
append() { reset; printf '\n%s\n' "$1" >> "$CLONE/$EXISTING"; git -C "$CLONE" add -- "$EXISTING"; run_guard; }
append 'try? await Task.sleep(nanoseconds: 1)'; expect "Task.sleep blocked" 1 "real-time wait"
append 'Thread.sleep(forTimeInterval: 1)'; expect "Thread.sleep blocked" 1 "real-time wait"
append 'usleep(1)'; expect "usleep blocked" 1 "real-time wait"
append 'q.asyncAfter(deadline: .now() + 1) {}'; expect "asyncAfter blocked" 1 "real-time wait"
append 'try? await Task.sleep(nanoseconds: 1) // real-time-ok: production timer under test'
expect "real-time-ok with a reason exempts" 0
append 'try? await Task.sleep(nanoseconds: 1) // real-time-ok:'; expect "bare real-time-ok still blocks" 1 "real-time wait"
append '// a comment naming Task.sleep'; expect "comment line naming Task.sleep passes" 0
append 'SuiteWait.settle(0.3)'; expect "SuiteWait.settle blocked" 1 "real-time wait"
append 'sem.wait(timeout: .now() + 5)'; expect ".wait(timeout: blocked" 1 "real-time wait"
append 'stallSeconds = 0.05'; expect "Seconds name with fraction blocked" 1 "real-time wait"
append 'castAbsenceGrace: TimeInterval = 0.05'; expect "typed Grace default blocked" 1 "real-time wait"
append 'test_handshakeTimeoutOverride = 0.3'; expect "TimeoutOverride blocked" 1 "real-time wait"
append 'makeBackend(castAbsenceGrace: 0.3)'; expect "Grace argument blocked" 1 "real-time wait"
append 'nowSeconds = 0.0'; expect "zero Seconds passes" 0
append 'lightWindowAlpha: CGFloat = 0.9'; expect "Window inside a longer name passes" 0
append 'makeBackend(castAbsenceGrace: 1)'; expect "whole-second Grace passes" 0
append 'sem.wait(timeout: .now() + 5) // real-time-ok: hang ceiling'; expect "hang ceiling with a reason passes" 0

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES guard-test-discipline test(s) FAILED" >&2
  exit 1
fi
echo "all guard-test-discipline tests passed"
