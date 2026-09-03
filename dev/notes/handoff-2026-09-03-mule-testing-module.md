# The mule looked dead. The cause was its developer directory.

2026-09-03. **Answered — see `claude/xctest-retirement` (PR #105), which carries
the fix.** This note began as a handover for an open investigation; it is kept
because the false trail is worth recognising, not because the question is open.

## The answer

The mule's developer-directory link pointed at an `/Applications/Xcode.app`
that had been removed, so `/usr/bin/swift` fell back to the Command Line Tools.
CLT ships no platform path, so SwiftPM fails before any test bundle loads — for
**every** package, `AirPlayEngine` included, whether or not it contains a single
test. The error that surfaced was:

```
error: '--num-workers' is only supported when testing with XCTest
```

which reads as a code problem and is actually *wrong developer directory*.
Three independent investigations converged on this.

PR #105 makes the runner fail fast instead: `run-tests.sh` exits 78 when
`xcode-select -p` sits under `/Library/Developer/CommandLineTools`, naming the
path and the fix. It also drops `--num-workers` outright (it only ever fanned
XCTest across worker processes; Swift Testing runs in one process), and makes
`AUDIOUT_TEST_MODE=serial` actually serialise via `--no-parallel`.

## Why it cost ninety minutes, and what to do differently

**The wrapper hides the remote's real error.** On a remote failure `run-tests.sh`
discards the remote output and re-runs locally — deliberately, so a remote on a
different toolchain can never be what refuses a commit (`run-tests.sh:141-152`). The
consequence is that a broken mule presents as "the mule found bugs in your
code". The remote's actual error is only in the full log, above the fallback
line:

```bash
LOG=/tmp/mule.log
AUDIOUT_TEST_PREFER=remote bash scripts/run-tests.sh > "$LOG" 2>&1
sed -n "1,$(grep -n 're-running locally' "$LOG" | head -1 | cut -d: -f1)p" "$LOG" \
  | grep -vE "housekeeping|^ +[MA?] " | tail -30
```

**Read the log; never grep it.** A test-target compile failure surfaces from
`swift test` as a bare `error: fatalError` with no test name. It matches none of the
obvious patterns and reads exactly like a runtime trap. Grepping for
`fatalError|failed|Test run with` hides the compiler diagnostic sitting thirty
lines above it.

**A changing failure set is the machine, not the code.** While the mule was
unusable every full suite ran locally. On a box at load 27-31 across 8 cores,
async and deadline tests fail at random and a *different* set each run
(`CompanionEndToEndTests` `waitUntil`, `PopoverControllerTests`
`panel.superview`, `NativeBackendTests` telemetry drain). Check `uptime`, and
check whether the run actually reached the mule, before believing any of it.

**What I ruled out, wrongly confident.** `xcode-select -p`, `xcrun -f swift`,
`xcrun --show-sdk-path` and `swift --version` were all checked over ssh and all
looked identical to the local Mac — which is what made the toolchain look
innocent. Whatever those printed in that shell, the runner's own
non-interactive invocation resolved differently. A hypothesis is only ruled out
by reproducing the failing command's exact environment, not by inspecting a
neighbouring one.
