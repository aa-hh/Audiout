#!/usr/bin/env bash
# Tests for scripts/real-time-tests.sh. Builds a throwaway git repo with fake
# sources and tests and runs the script inside it. No build: under a second.
#
# Usage: scripts/test-real-time-tests.sh

set -uo pipefail   # deliberately NOT -e: a case failing must not stop the rest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO/scripts/real-time-tests.sh"
GUARD="$REPO/.githooks/guard-test-discipline.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok — $1"; }
has()  { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else fail "$1: missing '$2' in: $OUT"; fi; }
lacks() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then fail "$1: unexpected '$2' in: $OUT"; else ok "$1"; fi; }

FAKE="$TMP_DIR/fake repo"
mkdir -p "$FAKE/AudioutCore/Sources/Core" "$FAKE/AudioutCore/Tests/CoreTests" "$FAKE/AirPlayEngine/Tests/EngineTests"
git -C "$FAKE" init -q

cat > "$FAKE/AudioutCore/Sources/Core/Widget.swift" <<'EOF'
public final class Widget {
    enum Gadget { case idle }
}
EOF
cat > "$FAKE/AudioutCore/Sources/Core/Gadget+Extra.swift" <<'EOF'
extension Gadget {
    func extra() {}
}
EOF
cat > "$FAKE/AudioutCore/Tests/CoreTests/WidgetTests.swift" <<'EOF'
@Test func waitsOnTheClock() async {
    let w = Widget()
    try? await Task.sleep(for: .milliseconds(50))
}
@Test func drivesTheManualClock() {
    clock.advance(by: 1)
    // Thread.sleep would be wrong here
}
@Test func keepsARealCeiling() {
    _ = sem.wait(timeout: .now() + 5)   // real-time-ok: hang ceiling
}
EOF
cat > "$FAKE/AudioutCore/Tests/CoreTests/OtherTests.swift" <<'EOF'
@Test func unrelated() { usleep(1000) }
EOF
cat > "$FAKE/AirPlayEngine/Tests/EngineTests/GadgetTests.swift" <<'EOF'
@Test func gadgetGrace() { let g = Gadget(); let graceSeconds = 0.2 }
EOF

OUT="$(cd "$FAKE" && bash "$SCRIPT" AudioutCore/Sources/Core/Widget.swift AudioutCore/Sources/Core/Gadget+Extra.swift)"
has   "a sleep in a test using the type is listed with its func" "AudioutCore/Tests/CoreTests/WidgetTests.swift:3: waitsOnTheClock: try? await Task.sleep"
has   "a real-time-ok line is still listed" "WidgetTests.swift:10: keepsARealCeiling:"
lacks "a manual-clock test is not listed" "drivesTheManualClock"
lacks "a commented sleep is not listed" "Thread.sleep"
lacks "a test file that never names the type is not listed" "OtherTests.swift"
has   "an extension's base type counts, in AirPlayEngine tests too" "AirPlayEngine/Tests/EngineTests/GadgetTests.swift:1: gadgetGrace:"

OUT="$(cd "$FAKE" && bash "$SCRIPT" AudioutCore/Sources/Core/Widget.swift)"
lacks "a nested type name is not used for matching" "GadgetTests.swift"

(cd "$FAKE" && bash "$SCRIPT" >/dev/null 2>&1); rc=$?
if [ "$rc" -eq 64 ]; then ok "no arguments is a usage error"; else fail "no arguments: exit $rc, wanted 64"; fi

pattern=$(sed -nE "s/^PATTERN='(.*)\|real-time-ok:'$/\1/p" "$SCRIPT")
if [ -n "$pattern" ] && grep -qF -- "$pattern" "$GUARD"; then
    ok "the wait pattern matches Guard 11's"
else
    fail "the wait pattern in real-time-tests.sh no longer matches .githooks/guard-test-discipline.sh"
fi

[ "$FAILURES" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$FAILURES failed" >&2; exit 1
