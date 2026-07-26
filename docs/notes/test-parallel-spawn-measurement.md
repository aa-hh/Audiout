# What determines the xctest process count under `swift test --parallel`

Measured 2026-07-25 in this repo (worktree `.claude/worktrees/test-class-consolidation`),
against the real `AudiouterCoreTests` binary (AppKit / CoreAudio / AirPlayEngine linked),
Apple Swift 6.4, `xctest` from `/Applications/Xcode-beta.app`.

## Verdict

**CONFIRMED: one process per test METHOD, not per class — consolidating classes cannot
reduce process-spawn count.**

This contradicts the "one process per test CLASS" claim currently written in
`AudiouterCore/AGENTS.md` (~lines 165 and 251). That claim is wrong.

## Method

Subject class: `AudiouterCore/Tests/AudiouterCoreTests/AppSettingsTests.swift`,
`final class AppSettingsTests: XCTestCase`, **21** `func test…` methods.

```
cd AudiouterCore && swift build --build-tests          # warm, 44.7s
# then, for W in 4, 2, 6 — test run backgrounded, sampled concurrently:
swift test --parallel --num-workers $W --filter AppSettingsTests &
while kill -0 $! ; do ps -Ao pid,ppid,command | grep '[x]ctest' ; sleep 0.1 ; done
```

(The unfiltered `ps` also catches xctest processes belonging to *other* worktrees running
their own suites; the analysis below filters to lines containing `AppSettingsTests/` and
confirms all of them share a single parent PID, i.e. they are our run's children.)

## Raw capture (representative — `--num-workers 6`, one single sample instant)

```
ts                 pid   ppid  command
1785015558.558545  93974 93486 …/usr/bin/xctest -XCTest AudiouterCoreTests.AppSettingsTests/testDensityRoundTrips …
1785015558.558545  93975 93486 …/usr/bin/xctest -XCTest AudiouterCoreTests.AppSettingsTests/testDefaultsWhenUnset …
1785015558.558545  93976 93486 …/usr/bin/xctest -XCTest AudiouterCoreTests.AppSettingsTests/testHasCompletedSetupRoundTrips …
1785015558.558545  93977 93486 …/usr/bin/xctest -XCTest AudiouterCoreTests.AppSettingsTests/testHasCompletedSetupDefaultsFalse …
1785015558.558545  93978 93486 …/usr/bin/xctest -XCTest AudiouterCoreTests.AppSettingsTests/testStartBufferDefaultsWhenUnset …
1785015558.558545  93979 93486 …/usr/bin/xctest -XCTest AudiouterCoreTests.AppSettingsTests/testStartBufferOptionListInvariants …
```

Six *different methods of the same class*, six different PIDs, alive at the same instant,
all forked from the same parent (93486). Per-class parallelism could not produce this.

## Results across worker counts

| `--num-workers` | max concurrent xctest procs | distinct PIDs over the run | distinct methods seen |
|---|---|---|---|
| 2 | **2** | 21 | 21 |
| 4 | **4** | 21 | 21 |
| 6 | **6** | 21 | 21 |

Two independent confirmations:
1. Peak concurrency tracks `--num-workers` exactly (2 / 4 / 6), so workers are the
   concurrency cap, not the spawn count.
2. The run spawns exactly **21 processes for 21 methods of 1 class** in every
   configuration. Under per-class semantics a `--filter AppSettingsTests` run would
   have spawned exactly **1**.

`swift test`'s own progress output agrees: it prints
`[17/21] Testing AudiouterCoreTests.AppSettingsTests/testWakeRestoreRoundTripsEveryOfferedOption`
— a 21-unit work queue for a single class.

## Arithmetic cross-check against the AGENTS.md measurements

Current repo counts (`grep -rho 'func test[A-Za-z0-9_]*' Tests/`): **1025** test methods,
**58** XCTestCase subclasses (AGENTS.md says 57 — off by one, immaterial here).

From the AGENTS.md table for the identical suite:

* `--parallel 6`: 358s user + 51.7s sys = **409.7 CPU-s**
* serial:         69.7s user + 6.0s sys  = **75.7 CPU-s**
* spawn overhead  = **334.0 CPU-s**

| hypothesis | spawns | CPU per spawn |
|---|---|---|
| per **method** | 1025 | **326 ms** |
| per **class**  | 57   | **5.86 s** |

326 ms is exactly the expected order of magnitude for `fork`/`exec` + dyld-linking a large
AppKit/CoreAudio/AirPlayEngine test binary (tens to low hundreds of ms). 5.86 s of CPU for
a single process launch is physically implausible — the whole *serial* suite, all 1025
tests of real work included, only costs 75.7 CPU-s, i.e. less than 13 such "launches".
The arithmetic independently corroborates the direct observation.

It also explains the AGENTS.md note that lowering `--num-workers` "barely helps": 6→2
workers kept CPU roughly flat (409.7 → 362.6 CPU-s) because the spawn count is fixed by
the method count, not by the worker count. That sentence was right; its stated cause
("staggers the 57 spawns") was wrong — it staggers 1025 spawns.

## Consequence

Consolidating the suite's ~57/58 test classes into fewer classes **cannot** reduce the
number of spawned processes or the ~334 CPU-s of parallel overhead. 1025 methods spawn
~1025 processes regardless of how they are grouped. Any effort justified by
"fewer classes → fewer processes" is void. The only levers that move that number are
running serially, or reducing/merging test *methods*.
