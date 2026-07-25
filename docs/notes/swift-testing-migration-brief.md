# Brief: migrating AudiouterCoreTests to swift-testing

Status: **not started, not scheduled** — written as a costed option per Alec's
request, alongside the finding in
[test-parallel-spawn-measurement.md](test-parallel-spawn-measurement.md) that
consolidating test *classes* cannot reduce the ~1025-process spawn overhead
under `swift test --parallel` (verified: it's one process per test *method*).
This is the option that would fix the actual root cause instead of working
around it.

## Why this is the option that actually removes the CPU cost

Apple's `swift-testing` framework runs tests concurrently *within one process*,
using Swift's structured-concurrency task scheduling rather than forking a
process per test. If that holds for this suite, the ~290-CPU-second
fork/exec+dyld overhead measured this session (`AudiouterCore/AGENTS.md`,
parallel vs serial comparison) goes away almost entirely — not reduced, gone —
while keeping (likely beating) parallel's wall-clock speed, since there is no
process-startup tax per test.

The adaptive runner shipped this session (`scripts/run-tests.sh`) works around
this cost by choosing serial vs parallel by machine load. Migrating the
framework would mean that choice stops mattering: parallel would just be
cheap. The runner itself would likely still be worth keeping (the remote-Mac
overflow and pass-cache are independent wins), but its serial/parallel
adaptivity would become moot.

## Scope, measured in this repo (not estimated)

- **1025 test methods, 58 test classes, 59 files** import `XCTest` under
  `AudiouterCore/Tests/AudiouterCoreTests/`.
- **~2631 XCTest assertion call sites** (`XCTAssert*`, `XCTUnwrap`, `XCTSkip`,
  `XCTFail` combined, rough grep count) that would each need translating to
  swift-testing's `#expect`/`#require` macros.
- **8 files subclass `IsolatedTestCase`** (a custom `XCTestCase` subclass for
  per-test isolation) — this base class itself would need an equivalent
  rewritten against swift-testing's model (it doesn't have `XCTestCase`
  subclassing; isolation would move to per-test setup via `init`/`deinit` or
  traits).
- **1 file, `AudioHardwareTestGate.swift`**, uses `XCTSkipUnless` — swift-testing
  has an equivalent (`.disabled(if:)` trait) but the call site and its API
  shape differ.
- Current toolchain: `swift-tools-version:5.10` in both `AudiouterCore/Package.swift`
  and `AirPlayEngine/Package.swift`; installed compiler is Swift 6.4 on macOS 27.
  **To verify before starting, not assumed here:** the exact minimum
  `swift-tools-version` and deployment target swift-testing requires for this
  toolchain/platform combination, and whether it can be adopted file-by-file
  alongside existing `XCTest` classes in the same target (mixed suites are
  supported by SwiftPM, but the two frameworks' output needs checking against
  this repo's `scripts/run-tests.sh`, which currently parses `swift test`
  output text for pass/fail/skip counts).

## Why this is bigger than everything done this session combined

Every other change this session (the adaptive runner, the remote Mac, the
audio-hardware gate, this doc correction) touched a handful of files each and
landed same-day. This would touch **59 files and ~2631 call sites**, is not
safely automatable as a single mechanical pass (assertion semantics don't map
1:1 — e.g. `XCTAssertEqual(a, b, accuracy:)` vs `#expect(abs(a - b) <= accuracy)`
needs per-call judgment in places, and `IsolatedTestCase`'s isolation model
needs redesigning, not just renaming), and would need the full suite re-verified
green at the end (currently 1025 tests, 9 skipped) rather than per-file.

It would also conflict with the **10+ other worktrees** currently doing
independent work against these same test files — a multi-session migration
sitting open against a fast-moving shared test target is a real coordination
cost, not just an engineering one.

## Recommended shape, if this is ever picked up

1. A dedicated spike (same shape as the one that answered the class/method
   question): migrate ONE small, simple test file end-to-end, confirm it
   compiles, passes, and that `scripts/run-tests.sh` still parses its
   pass/fail output correctly — before committing to the rest.
2. If that spike is clean, batch the remaining ~58 files into a planned,
   parallelizable task list (this is the shape of mechanical, repetitive work
   that suits many agents in parallel, similar to the abandoned Phase B design
   for class-consolidation, but for a real payoff this time) — but only after
   the spike, and only with an explicit go-ahead, given the size and the
   shared-target coordination risk above.
3. `IsolatedTestCase`'s replacement design is the one piece of real judgment
   in the whole migration and should be designed once, up front, not
   rediscovered per file.

## Bottom line

Worth doing eventually if the CPU cost keeps mattering and the machine's load
profile doesn't improve with what's already shipped. Not worth starting
casually — it is a real project, not an afternoon task, and should get its own
spike-gated plan when Alec decides to prioritize it.
