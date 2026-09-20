Revised 2026-09-20 by the orchestrator after the spec check: settle window is `testSettleWindow` (the wrapper is released at `stop()`, not at the deadline; 0.5 s raced the real timer), a branch for the pre-change test passing, comment ceiling settled as no comment, ticket Status line fenced, weak read inside a `do { }` block.

# Work order — ticket 10: stop leaking one DispatchWorkItem per notification

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-10-default-output-monitor-workitem-cycle` (clean at scoping time, HEAD `a14ff11f`).

### Goal
`scheduleTrailingFanout()` builds its trailing-delivery `DispatchWorkItem` with a `var item: DispatchWorkItem!` that the item's own block reads, so the item retains itself and never deallocates. One is created per default-output or nominal-rate notification on the single process-wide monitor, and a Bluetooth headset connect posts four notifications in 0.9 s, so the leak grows with every connect for the life of the process. Build the item with `let`, drop the `!item.isCancelled` check (a cancelled `DispatchWorkItem` already skips its block), and add one test that a scheduled-then-cancelled item is released.

### Verified facts
- The leak, verbatim: `AudioutCore/Sources/AudioutCore/DefaultOutputDeviceMonitor.swift:383-395` — `pendingFanout?.cancel()`, then `var item: DispatchWorkItem!`, `item = DispatchWorkItem { [weak self] in guard let self, !item.isCancelled else { return } … }`, `pendingFanout = item`, `queue.asyncAfter(deadline: .now() + settleWindowSeconds, execute: item)`.
- `pendingFanout` is declared `private var pendingFanout: DispatchWorkItem?` at `DefaultOutputDeviceMonitor.swift:151`, documented "Only ever touched on `queue`". `private` is not reachable from the test target even under `@testable import`.
- `scheduleTrailingFanout()` is called at the end of every `handleNotification()` — `DefaultOutputDeviceMonitor.swift:355` — so any single `hal.fire(...)` arms exactly one item.
- `stop()` cancels the armed item and clears the monitor's strong reference: `pendingFanout?.cancel()` / `pendingFanout = nil` at `DefaultOutputDeviceMonitor.swift:216-217`.
- The existing test-only read seam style: `_drainForTesting()` is `internal func` at `DefaultOutputDeviceMonitor.swift:447`, and `subscriberCount` is an internal computed property at `DefaultOutputDeviceMonitor.swift:267-271` ("Live subscriber count — for tests/diagnostics").
- `runOnQueue(_:)` at `DefaultOutputDeviceMonitor.swift:122-127` runs a body on `queue` synchronously, and does not re-enter when already on `queue`. `current` uses it: `runOnQueue { latest }` at `DefaultOutputDeviceMonitor.swift:227-229`.
- The test file imports the module for internal access: `@testable import AudioutCore` at `AudioutCore/Tests/AudioutCoreTests/DefaultOutputDeviceMonitorTests.swift:3`. It is swift-testing (`import Testing`, `@Suite struct DefaultOutputDeviceMonitorTests` at line 14), not `@MainActor`.
- The fake HAL fires a listener synchronously on the monitor's own queue: `token.queue.sync { token.handler() }` at `DefaultOutputDeviceMonitorTests.swift:82-87`, so `hal.fire(...)` returns only after the notification has been handled and the item armed.
- The suite's shared settle window is `private let testSettleWindow: TimeInterval = 60` at `DefaultOutputDeviceMonitorTests.swift:128`, chosen so the real timer can never win inside a test; every test constructs `DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)` (e.g. line 137).
- `init(hal:settleWindow:)` takes any `TimeInterval`: `DefaultOutputDeviceMonitor.swift:173-177`.
- The shared polling wait is `SuiteWait.until(_:timeout:sourceLocation:_:)` — `async`, polls every 5 ms, records an `Issue` at the call site when it expires: `AudioutCore/Tests/AudioutCoreTests/SuiteWait.swift:113-132`. Its default deadline is `static let timeout: TimeInterval = 30` (`SuiteWait.swift:78`). Existing call shape: `await SuiteWait.until("the prewarmed screens to be built") { … }` (`AudioutCore/Tests/AudioutCoreTests/SurfaceScreenSwitchCostTests.swift:72`).
- `pendingFanout` is referenced only inside `DefaultOutputDeviceMonitor.swift` (lines 151, 216, 217, 327, 384, 388, 393, 449, 451, 509, 510) — no other file in `AudioutCore` touches it.
- Folder rules read this session: `AudioutCore/AGENTS.md` ("`scripts/run-tests.sh --filter <Suite>` for the inner loop, never a bare `swift test`"; "Tests must stay invisible") and `AudioutCore/Sources/AudioutCore/AGENTS.md`. There is no `AGENTS.md` under `AudioutCore/Tests/`.
- Pre-change baseline, run in this worktree with `AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter DefaultOutputDeviceMonitor`: `Test run with 17 tests in 1 suite passed after 0.046 seconds.` (exit 0).

Platform behaviour this rests on, not verified against this repo's code: Apple documents that a `DispatchWorkItem` cancelled before it begins executing does not run its block. That is the ticket's settled premise for dropping the `!item.isCancelled` check.

### Steps

1. **Add the read seam.** In `AudioutCore/Sources/AudioutCore/DefaultOutputDeviceMonitor.swift`, directly after `_drainForTesting()` (ends line 458), add an internal computed property that returns the currently armed trailing fan-out item, read through `runOnQueue` exactly as `current` does at line 228 (`runOnQueue { pendingFanout }`). Name it `_pendingFanoutForTesting`, matching the `_drainForTesting` naming already in the file. Give it a one-or-two-line doc comment saying it is the armed trailing fan-out, read on `queue`, tests only. Leave `pendingFanout` itself `private`.

2. **Write the failing test.** In `AudioutCore/Tests/AudioutCoreTests/DefaultOutputDeviceMonitorTests.swift`, add one `@Test func … async` at the end of the suite (after `rateRiseOffLowRateDeliversImmediately()`, which ends at line 494). Its doc comment names the defect: the trailing fan-out item's block read the item itself, so the item retained itself and one leaked per default-output/rate notification — four per Bluetooth connect on the single process-wide monitor. The test:
   - builds `FakeHAL()` and `DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)` exactly like the other tests (line 137). Do NOT use a short window: `DispatchQueue.asyncAfter(deadline:execute:)` hands libdispatch the item's underlying block, not the `DispatchWorkItem` wrapper, so after the fix the wrapper is released the moment `stop()` clears `pendingFanout` — the assertion never needs to outlast the deadline, and a short window would let the real timer fire between `hal.fire` and the read, failing the "armed" guard on a slow machine;
   - attaches a `Recorder(deviceID: 42, rate: 48_000)` and calls `monitor.start()`;
   - sets `hal.rate = 44_100` and calls `hal.fire(rateSelector)` once, which arms exactly one trailing item;
   - declares `weak var weakItem: DispatchWorkItem?` and assigns it inside a nested `do { weakItem = monitor._pendingFanoutForTesting }` block, so the getter's temporary strong reference cannot outlive the statement in a debug build; then asserts `weakItem != nil` with a message saying the trailing fan-out is armed — this guards against the assertion passing vacuously because the item already ran;
   - calls `monitor.stop()`, which cancels the item and drops the monitor's reference;
   - `await SuiteWait.until("the cancelled trailing fan-out work item to be released") { weakItem == nil }` and then `#expect(weakItem == nil)`.

   Run `bash scripts/run-tests.sh --filter DefaultOutputDeviceMonitor` and paste the output: this test must FAIL (the wait expires after 30 s and `SuiteWait` records the timeout at the call site) because the unfixed item retains itself. Do not proceed until you have seen that failure. If instead the new test PASSES before step 3, STOP and report that with the output — do not rewrite the test and do not proceed to step 3.

3. **Fix `scheduleTrailingFanout()`.** In the same source file, lines 385-387: replace the two-line `var item: DispatchWorkItem!` / `item = DispatchWorkItem { … }` pair with a single `let item = DispatchWorkItem { [weak self] in … }`, and change the block's first line from `guard let self, !item.isCancelled else { return }` to `guard let self else { return }`. Everything else in the block and the rest of the function (lines 388-394, including `pendingFanout = item` and the `asyncAfter`) is unchanged. Add nothing else: no new comment in the function; the existing doc comment above it stays as is.

4. Re-run `bash scripts/run-tests.sh --filter DefaultOutputDeviceMonitor` and paste the output. Expect 18 tests, all passing.

### Out of scope — do not touch
- The settle-window logic itself: `handleNotification()`, `handsFreeHold(for:)`, `deliverToSubscribers(forcingRebuild:)`, `_drainForTesting()`, `stop()`, `removeListeners()`. No behaviour change beyond the item's lifetime.
- `testSettleWindow` (line 128) and every existing test in the suite — do not retune, rename, or "modernise" them.
- Making `pendingFanout` non-private, adding any public API, or adding a general-purpose leak-checking helper to the test target.
- Other files: no other source or test file is edited. The other findings in `.scratch/code-review-2026-09-17/` are separate tickets.
- The ticket file `.scratch/code-review-2026-09-17/issues/10-default-output-monitor-workitem-cycle.md`, including its `Status:` line — do not edit it; the orchestrator owns ticket status.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims.

### Verification
```bash
bash scripts/run-tests.sh --filter DefaultOutputDeviceMonitor
```
Expected final line: `Test run with 18 tests in 1 suite passed after …`. Trust only a `Test run with N tests` line — a filter that matches nothing prints green. Pre-change baseline observed this session: `Test run with 17 tests in 1 suite passed after 0.046 seconds.` If the run is served from the pass cache, force a real run with `AUDIOUT_TEST_NO_CACHE=1`.

Test seam: `AudioutCore/Tests/AudioutCoreTests/DefaultOutputDeviceMonitorTests.swift:14` (the whole suite; new test appended after line 494). Defect it catches: a trailing fan-out item that has been scheduled and then cancelled is never deallocated, because its block reads the item itself.

If a `weak` reference to a `DispatchWorkItem` turns out not to observe deallocation at all (the new test also fails after step 3), STOP and report — do not invent a different assertion.

### Execution plan
Single track, SERIAL within itself, nothing to parallelise (two files, one of which depends on the other's seam).
- Files: `AudioutCore/Sources/AudioutCore/DefaultOutputDeviceMonitor.swift`, `AudioutCore/Tests/AudioutCoreTests/DefaultOutputDeviceMonitorTests.swift`.
- Model: sonnet. Effort: low-to-medium — the edit is three lines plus one test; the only judgement is the test's timing, which is specified above.
- The branch has no uncommitted work; the tracks would fork from `a14ff11f`.

### Executor rules (copy verbatim into the handoff prompt)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
> - Do not commit and do not push. All work stays uncommitted in this worktree.
> - Tests only via `bash scripts/run-tests.sh --filter DefaultOutputDeviceMonitor`; compile checks only via `bash scripts/build.sh`. Never a bare `swift test`, `swift build`, `swift run`, `swift package`, or `xcodebuild`.
> - Trust only a `Test run with N tests` line in the output. A filter that matches nothing prints green.
> - If Edit/Write refuse because of the worktree path, edit through the shell (python, a heredoc, or sed).
