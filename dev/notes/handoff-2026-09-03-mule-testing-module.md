# The mule is silently dead: `no such module 'Testing'`

Handover, 2026-09-03. Written after losing ~90 minutes to the downstream
symptoms. The bug is not in any product code.

## What is actually happening

`scripts/run-tests.sh` prefers the remote Mac (`alechamilton@SUMUP-M9Y197RFVG.local`).
The remote run **fails to compile the test target**, so `remote_run` returns
non-zero, and the wrapper falls back to the local machine:

```
suite: sending to remote alechamilton@SUMUP-M9Y197RFVG.local (preferred) ...
suite: remote reported FAILURES — re-running locally to confirm.
```

That fallback is deliberate and correct (`run-tests.sh:141-152`): a remote on a
different toolchain must never be what refuses a commit. But it also **hides the
remote's real error**, so this reads as "the mule found bugs" when the mule
never ran a test.

**Every full-suite run in the repo is therefore executing locally.** On a box at
load 27-31 (8 cores) that produces random async/deadline failures — a different
set each run. Seen: `CompanionEndToEndTests` `waitUntil` timeouts,
`PopoverControllerTests.diagnosisPanelViewIsActuallyMountedInViewTree`
(`panel.superview == nil`), `NativeBackendTests.bindBowsOutDuringWholeSystemTeardownAndIsRedriven`
(empty telemetry). None are real. Do not chase them; check `uptime` and check
whether the run reached the mule.

## How to see the real error

The remote output is only in the full log, above the fallback line:

```bash
LOG=/tmp/mule.log
AUDIOUT_TEST_PREFER=remote bash scripts/run-tests.sh > "$LOG" 2>&1
sed -n "1,$(grep -n 're-running locally' "$LOG" | head -1 | cut -d: -f1)p" "$LOG" \
  | grep -vE "housekeeping|^ +[MA?] " | tail -30
```

Never `grep` for the failure by name. A test-target COMPILE failure surfaces as
a bare `error: fatalError` with no test name, which looks like a runtime trap
and matches none of the obvious patterns.

## The two causes, in order

**1. `--num-workers` is XCTest-only. FIXED IN PRINCIPLE, NOT COMMITTED.**

```
error: '--num-workers' is only supported when testing with XCTest
```

`run_remote()` builds `rargs="$engine --parallel --num-workers $workers"`
(`run-tests.sh:129`). Swift Testing rejects `--num-workers` and exits before
running anything. `--parallel` alone is right — Swift Testing picks its own
worker count. The local path (`:370`, `:372`) passes the same flag and the local
toolchain tolerates it, which is why only the remote broke.

The one-line change was written and verified to remove this error, then reverted
to keep an unrelated commit clean. Re-apply it; it is necessary but **not
sufficient**.

**2. `no such module 'Testing'` on the mule. OPEN. This is the real one.**

```
/Users/alechamilton/audiout-remote-tests/container-edge/AudioutCore/Tests/AudioutCoreTests/AboutSectionTests.swift:4:8:
error: no such module 'Testing'
```

Compilation reaches ~[187/189] and every test file fails the same way.

### Ruled out — do not re-check these

| Hypothesis | Finding |
|---|---|
| Old/missing toolchain on the mule | Identical to local: Xcode-beta, Swift 6.4 (`swiftlang-6.4.0.33.1`) |
| `Testing.swiftmodule` absent for macOS | Present at `Xcode-beta.app/.../MacOSX.platform/Developer/Library/Frameworks/Testing.framework/Modules/` |
| Homebrew `swift` shadowing Xcode's via the `PATH` export in `remote_run` | No Homebrew swift on either machine; `which swift` = `/usr/bin/swift` on both |
| `DEVELOPER_DIR` pointing elsewhere in the non-interactive ssh shell | Unset on both; `xcode-select -p` = Xcode-beta on both |
| `xcrun` resolving a different SDK | `xcrun -f swift` and `--show-sdk-path` both resolve inside Xcode-beta; SDK 27.0 |
| Stale/corrupt `.build` in the mule's scratch copy | No `.build` present in `/Users/alechamilton/audiout-remote-tests/container-edge` |
| Mule too loaded or out of disk | load 3.44/8 cores, 34Gi free — idle and healthy |

### Where to look next

- The remote command runs **non-interactively over `ssh -tt`** with only
  `export PATH=/opt/homebrew/bin:$PATH` (`lib/remote.sh:207-211`). Compare a
  full `swift build --build-tests` run in that exact shell against the same
  command in an interactive ssh session — if they differ, the environment
  gap is the answer, not the toolchain.
- `swift test` on the mule may be resolving a **different destination/SDK** than
  `xcrun` reports. Try `--destination`/`--sdk` explicitly, and print
  `swift build --build-tests -v` on the mule to see the actual `-sdk` flag and
  the framework search paths passed to the test target.
- The macOS `Testing` module ships inside the **platform's** Frameworks
  directory, not the toolchain's `lib/swift`. If the remote build is missing the
  `-F .../MacOSX.platform/Developer/Library/Frameworks` search path that the
  local build gets, that is exactly this error.
- Check whether the mule ever built this test target successfully. If it never
  has, this is not a regression and there is no "last good" state to diff.

## Reproduce in one command

```bash
cd .claude/worktrees/<any-worktree>
AUDIOUT_TEST_PREFER=remote bash scripts/run-tests.sh --filter AboutSectionTests > /tmp/mule.log 2>&1
sed -n "1,$(grep -n 're-running locally' /tmp/mule.log | head -1 | cut -d: -f1)p" /tmp/mule.log | tail -20
```

## Why it is worth fixing properly

The mule is idle and roughly twice as fast as the primary Mac, which is
routinely at load 30 with several agents on it. Restoring it removes the largest
current source of false test failures and roughly halves full-suite wall time.
