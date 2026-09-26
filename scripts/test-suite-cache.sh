#!/bin/bash
# Tests for scripts/lib/suite-cache.sh, the pass cache scripts/run-tests.sh
# consults before a run and writes after a pass.
#
# Everything runs against a scratch stamp folder (AUDIOUT_TEST_CACHE_DIR), so
# the live /tmp/audiout-suite-cache is never read or written. The last part
# drives the real runner in a throwaway clone with `swift` replaced by a stub,
# so no Swift code is compiled or tested.
#
# Usage: scripts/test-suite-cache.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export AUDIOUT_TEST_CACHE_DIR="$TMP_DIR/stamps"
unset AUDIOUT_TEST_NO_CACHE
. "$SCRIPT_DIR/lib/suite-cache.sh"

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok — $1"; }
reset() { rm -rf "$AUDIOUT_TEST_CACHE_DIR"; }

SRC=deadbeef

# --- 1. a full pass covers a later filtered run ------------------------------
# Catches: a full-suite pass that still leaves every filtered run to re-test.
reset
suite_cache_record "$SRC"
[ -f "$AUDIOUT_TEST_CACHE_DIR/$SRC.full" ] || fail "1: full pass wrote no .full stamp"
if suite_cache_satisfied "$SRC" --filter A; then ok "1: full pass satisfies --filter A"
else fail "1: full pass did not satisfy --filter A"; fi

# --- 2. an earlier A pass narrows a later A|B run to B -----------------------
# Catches: Guard 4's derived A|B re-running A, which the agent already ran.
reset
suite_cache_record "$SRC" --filter A
if suite_cache_satisfied "$SRC" --filter 'A|B'; then
    fail "2: A|B counted as satisfied with only A stamped"
elif [ "$suite_cache_missing" = "B" ]; then
    ok "2: A pass then A|B lookup leaves only B to run"
else
    fail "2: missing was '$suite_cache_missing', expected 'B'"
fi
if suite_cache_satisfied "$SRC"; then fail "2: an A pass satisfied the full suite"
else ok "2: an A pass does not satisfy the full suite"; fi

# --- 3. an A|B pass covers a later A run -------------------------------------
# Catches: stamping the alternation as one string instead of per name.
reset
suite_cache_record "$SRC" --filter 'A|B'
if suite_cache_satisfied "$SRC" --filter A; then ok "3: A|B pass satisfies --filter A"
else fail "3: A|B pass did not satisfy --filter A"; fi

# --- 4. a regex filter: covered by .full, stamped by exact argument hash -----
# A full run contained whatever any filter selects, so .full satisfies it.
# Writing falls back to the exact argument hash, because the cache cannot
# know which suites 'Foo.*' selected.
# Catches: an odd filter shape being split into bogus per-name stamps, or
# being refused the full pass that already covered it.
reset
suite_cache_record "$SRC"
if suite_cache_satisfied "$SRC" --filter 'Foo.*'; then ok "4: .full satisfies --filter 'Foo.*'"
else fail "4: .full did not satisfy --filter 'Foo.*'"; fi
reset
suite_cache_record "$SRC" --filter 'Foo.*'
want="$AUDIOUT_TEST_CACHE_DIR/$SRC.$(suite_cache_args_stamp --filter 'Foo.*')"
n=$(ls "$AUDIOUT_TEST_CACHE_DIR" | grep -c .)
if [ -f "$want" ] && [ "$n" -eq 1 ]; then ok "4: 'Foo.*' pass wrote one exact-hash stamp"
else fail "4: 'Foo.*' pass wrote $n stamp(s), exact-hash stamp present: $([ -f "$want" ] && echo yes || echo no)"; fi
suite_cache_satisfied "$SRC" --filter 'Foo.*' && ok "4: 'Foo.*' pass satisfies the same filter" \
    || fail "4: 'Foo.*' pass did not satisfy the same filter"
suite_cache_satisfied "$SRC" --filter 'Foo.*|Bar' && fail "4: 'Foo.*' pass satisfied a different filter"
suite_cache_classify --filter 'A|'
[ "$suite_cache_kind" = "other" ] || fail "4: 'A|' classified as $suite_cache_kind, expected other"
suite_cache_classify --filter "A
B"
[ "$suite_cache_kind" = "other" ] || fail "4: a filter with a newline classified as $suite_cache_kind"

# --- 5. AUDIOUT_TEST_NO_CACHE=1 neither writes nor reads ---------------------
# Catches: the escape hatch leaving a stamp that skips the next normal run,
# or still honouring an old one.
reset
AUDIOUT_TEST_NO_CACHE=1 suite_cache_record "$SRC" --filter A
AUDIOUT_TEST_NO_CACHE=1 suite_cache_record "$SRC"
if [ -d "$AUDIOUT_TEST_CACHE_DIR" ] && [ -n "$(ls "$AUDIOUT_TEST_CACHE_DIR")" ]; then
    fail "5: NO_CACHE=1 wrote stamps"
else ok "5: NO_CACHE=1 wrote nothing"; fi
suite_cache_record "$SRC"
if AUDIOUT_TEST_NO_CACHE=1 suite_cache_satisfied "$SRC" --filter A; then
    fail "5: NO_CACHE=1 read an existing .full stamp"
else ok "5: NO_CACHE=1 ignores an existing .full stamp"; fi

# --- 6. different sources satisfy nothing -------------------------------------
# Catches: a stamp lookup that ignores the source hash.
reset
suite_cache_record "$SRC"
suite_cache_record "$SRC" --filter 'A|B'
if suite_cache_satisfied cafef00d || suite_cache_satisfied cafef00d --filter A; then
    fail "6: stamps for one source hash satisfied another"
else ok "6: a different source hash is satisfied by nothing"; fi

# --- 7. the AirPlayEngine hash covers its own tests --------------------------
# Catches: an engine-test-only edit reusing a stale engine pass.
FAKE="$TMP_DIR/fake-repo"
mkdir -p "$FAKE/AudioutCore/Sources" "$FAKE/AirPlayEngine/Sources" "$FAKE/AirPlayEngine/Tests/X"
echo 'let a = 1' > "$FAKE/AirPlayEngine/Tests/X/T.swift"
echo '// manifest' > "$FAKE/AirPlayEngine/Package.swift"
e1=$(suite_cache_source_hash "$FAKE" AirPlayEngine)
c1=$(suite_cache_source_hash "$FAKE" AudioutCore)
echo 'let a = 2' > "$FAKE/AirPlayEngine/Tests/X/T.swift"
e2=$(suite_cache_source_hash "$FAKE" AirPlayEngine)
c2=$(suite_cache_source_hash "$FAKE" AudioutCore)
[ "$e1" != "$e2" ] && ok "7: an AirPlayEngine/Tests edit changes the engine hash" \
    || fail "7: an AirPlayEngine/Tests edit left the engine hash unchanged"
[ "$c1" = "$c2" ] || fail "7: an AirPlayEngine/Tests edit changed the AudioutCore hash"
[ "$c1" != "$e1" ] || fail "7: AudioutCore and AirPlayEngine share one hash"
echo '{}' > "$FAKE/AirPlayEngine/Package.resolved"
e3=$(suite_cache_source_hash "$FAKE" AirPlayEngine)
[ "$e3" != "$e2" ] && ok "7: AirPlayEngine/Package.resolved is in the engine hash" \
    || fail "7: adding AirPlayEngine/Package.resolved left the engine hash unchanged"

# --- end to end: the real runner, swift stubbed -------------------------------
# Catches: the runner not narrowing the filter it hands swift, or not writing
# stamps a later run can use.
reset
CLONE="$TMP_DIR/clone"
git clone -q --shared "$REPO" "$CLONE" || { fail "e2e: git clone failed"; CLONE=; }
if [ -n "$CLONE" ]; then
    # The working-tree copies, so an uncommitted change is what gets tested.
    cp "$SCRIPT_DIR/run-tests.sh" "$CLONE/scripts/run-tests.sh"
    cp "$SCRIPT_DIR/lib/suite-cache.sh" "$SCRIPT_DIR/lib/remote.sh" "$CLONE/scripts/lib/"
    # The orphan reaper scans the whole machine; nothing to reap here.
    printf '#!/bin/sh\nexit 0\n' > "$CLONE/scripts/reap-orphaned-swift.sh"
    # A warm checkout folder skips the runner's `swift package resolve` step.
    mkdir -p "$CLONE/AudioutCore/.build/checkouts/stub"
    mkdir -p "$TMP_DIR/bin"
    SWIFT_LOG="$TMP_DIR/swift.log"
    cat > "$TMP_DIR/bin/swift" <<EOF
#!/bin/sh
echo "\$*" >> "$SWIFT_LOG"
echo "Test run with 3 tests in 1 suite passed"
exit 0
EOF
    chmod +x "$TMP_DIR/bin/swift"
    runner() {
        (cd "$CLONE" && PATH="$TMP_DIR/bin:$PATH" \
            AUDIOUT_TEST_PREFER=local AUDIOUT_TEST_SLOTS=1 \
            AUDIOUT_TEST_LOCK_FILE="$TMP_DIR/lock" AUDIOUT_NO_HOUSEKEEPING=1 \
            sh scripts/run-tests.sh "$@" 2>&1)
    }
    out1=$(runner --filter FooTests); rc1=$?
    out2=$(runner --filter 'FooTests|BarTests'); rc2=$?
    out3=$(runner --filter 'FooTests|BarTests'); rc3=$?
    echo "  --- second run's output:"
    printf '%s\n' "$out2" | sed 's/^/    /'
    echo "  --- swift stub calls:"
    sed 's/^/    /' "$SWIFT_LOG"
    [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -eq 0 ] \
        || fail "e2e: runner exit codes $rc1 $rc2 $rc3, expected 0 0 0"
    printf '%s\n' "$out2" | grep -q 'already passed on these sources, skipping: FooTests' \
        && ok "e2e: second run prints the skip line for FooTests" \
        || fail "e2e: second run printed no skip line for FooTests"
    [ "$(sed -n 1p "$SWIFT_LOG")" = "test --parallel --filter FooTests" ] \
        || fail "e2e: first swift call was '$(sed -n 1p "$SWIFT_LOG")'"
    [ "$(sed -n 2p "$SWIFT_LOG")" = "test --parallel --filter BarTests" ] \
        && ok "e2e: second run called swift with --filter BarTests only" \
        || fail "e2e: second swift call was '$(sed -n 2p "$SWIFT_LOG")'"
    printf '%s\n' "$out3" | grep -q 'sources unchanged since a passing run' \
        && [ "$(grep -c . "$SWIFT_LOG")" -eq 2 ] \
        && ok "e2e: third run skipped entirely, swift not called" \
        || fail "e2e: third run did not skip (swift called $(grep -c . "$SWIFT_LOG") times)"
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES suite-cache test(s) FAILED" >&2
    exit 1
fi
echo "all suite-cache tests passed"
