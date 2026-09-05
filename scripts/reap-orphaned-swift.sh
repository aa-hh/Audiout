#!/usr/bin/env bash
# Kill SwiftPM/compiler processes whose parent has died.
#
# WHY THIS EXISTS (2026-09-04). Killing a wrapper — a command timeout, a user
# interrupt, a `pkill run-tests.sh` — does NOT kill the `swift` it spawned. The
# orphan keeps SwiftPM's per-`.build` lock, and every later build then queues
# behind it printing NOTHING. On the day this was written that cost about four
# hours across three separate incidents; one orphan was found still holding the
# lock 3h26m after its parent died, and the symptom every time looked like "the
# build is slow" rather than "the build is blocked".
#
# The signal is exact: a process whose parent has exited is reparented to PID 1.
# A swift process with ppid 1 has no wrapper waiting on it, so nothing will ever
# collect it and nothing legitimate is reading its output. A live build's swift
# always has its wrapper as parent, so this cannot touch one.
#
# Deliberately NOT time-based: an age cutoff would either kill a slow honest
# build or spare a fresh orphan. Parentage answers the question directly.
#
# `pgrep -x` requires an EXACT match of the whole process name, so the
# original pattern here never matched `swift-test` or the actual hung
# process, `swiftpm-testing-helper` — only a literal `swift` or `swiftpm`
# binary. Found 2026-09-05 when three stale test-runner processes (one 10+
# hours old) sat unreaped, at ppid 1, still holding every local suite lock.
# `pgrep -f` matches the full command line instead, so it needs its own
# anchor against false positives — this repo's own paths contain "swift" too
# (`swift-` scripts, `Swift` in folder names). The pattern requires a `/`
# before the binary name (so it matches the executable, not an argument that
# happens to contain the word) and whitespace or end-of-line after it (every
# one of these binaries takes arguments, so anchoring on `$` alone matches
# nothing).
set -uo pipefail

reaped=0
for pid in $(pgrep -f '/(swift|swift-build|swift-frontend|swiftpm|swift-test|swiftpm-testing-helper)([[:space:]]|$)' 2>/dev/null); do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$ppid" = "1" ] || continue
    elapsed=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    kill -9 "$pid" 2>/dev/null || continue
    echo "  reaped orphaned swift process $pid (parent gone, alive $elapsed)" >&2
    reaped=$((reaped + 1))
done
[ "$reaped" -eq 0 ] || echo "  reaped $reaped orphan(s) holding the build lock" >&2
exit 0
