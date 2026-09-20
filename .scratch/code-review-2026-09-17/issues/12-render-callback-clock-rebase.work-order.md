## Work order — ticket 12: synced sinks stop resampling both clocks per render cycle

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-12-render-callback-clock-rebase` at `a14ff11f`, clean. All line numbers below are at that commit.

### Goal

`SyncedLocalSink.render` and `BTDeviceSink.render` each call `CoreAudioSystemTap.timespec(fromHostTime:)` once per render cycle. That helper reads `mach_absolute_time` and `clock_gettime(CLOCK_MONOTONIC)` back to back on every call, and its own doc says production must never do that per buffer. The sampling error between the two reads lands directly in the cycle-start value the release gate compares and that `PhaseController` reads as phase error, so the PI loop is fed per-cycle noise. Give both sinks the same cached per-instance offset the capture tap already uses: seeded on every engine (re)start, drift-healed per cycle by the existing `shouldResample` check, rebased through `timespec(machNanos:offset:)`. Ticket 11 edits the same `SyncedLocalSink.swift` in another worktree; this diff must merge cleanly with it.

### Settled decisions (final)

- Both sinks carry a cached mach-to-monotonic offset, sampled on start and re-sampled on the existing rebuild edges (every rebuild passes through `start()` / `startLocked()`, so seeding there covers all of them).
- Per-cycle `timespec(fromHostTime:)` is gone from both render paths. Healing IS needed: `BTDeviceSink` has no sleep/wake handling at all (grep `sleep|wake` in `BTSyncedSink.swift` returns only the comment at :1127), so without the heal a sleep would leave its offset stale by the sleep duration until an unrelated rebuild. Copy the capture tap's heal (the `shouldResample` → resample pattern at `NativeCaptureCoordinator.swift:3778-3787`) into ONE new shared static overload on `CoreAudioSystemTap`; both sinks call it. `BTSyncedSink.swift` is licence-clean (`AudioutCore/Sources/AudioutCore/AGENTS.md:10` names `SyncCore.swift`; `areas/sync.md` verdict names `BTSyncedSink.swift` too), so the heal logic lives in `NativeCaptureCoordinator.swift` and the sinks only call it.
- Test seam: a new test in each of `SyncedLocalSinkTests` and `BTSyncedSinkTests` seeds the sink's cached offset 300 ms ahead of the real one, drives the real `render` with a synthetic `AudioTimeStamp`, and expects the gate to open exactly where the cached offset says. No global counters, no injected clock.
- Existing sync accuracy tests unchanged.
- Verification: `bash scripts/run-tests.sh --filter 'SyncedLocalSink|BTSyncedSink'`.

### Verified facts

Paths are under `AudioutCore/Sources/AudioutCore/` unless noted; `NCC` = `NativeCaptureCoordinator.swift`, `SLS` = `SyncedLocalSink.swift`, `BTS` = `BTSyncedSink.swift`.

- `NCC:4451-4452` `@available(macOS 14.2, *) final class CoreAudioSystemTap`. Package deployment target is macOS 14.4 (`AudioutCore/Package.swift:79`), so no `#available` guard is needed to call it from the sinks.
- `NCC:3502-3508` the tap's cached offset `private var machToMonotonicOffsetNanos: Int64 = 0` with the thread-confinement reasoning; seeded at `NCC:3752-3758` inside `startIOProc()` before `AudioDeviceStart`; healed per buffer at `NCC:3773-3788`: `machNanoseconds(fromHostTime:)` → `if Self.shouldResample(machNanos:offset:monotonicNowNanos: Self.currentMonotonicNanos()) { offset = Self.sampleMachToMonotonicOffsetNanos() }` → `Self.timespec(machNanos:offset:)`.
- `NCC:4170-4175` `static func timespec(machNanos: UInt64, offset: Int64) -> timespec` (internal).
- `NCC:4177-4187` `static func timespec(fromHostTime hostTime: UInt64) -> timespec` with the "Production code must go through the instance path" doc.
- `NCC:4189-4192` `private static func machNanoseconds(fromHostTime hostTime: UInt64) -> UInt64`.
- `NCC:4202-4206` `private static func currentMonotonicNanos() -> UInt64`.
- `NCC:4218-4223` `private static func sampleMachToMonotonicOffsetNanos() -> Int64`.
- `NCC:4233-4237` `static func shouldResample(machNanos: UInt64, offset: Int64, monotonicNowNanos: UInt64) -> Bool` (internal, threshold 1 s).
- `SLS:123-134` the session-state vars (`anchored`, `released`, `targetReleaseNanos`, `cachedTotalDelayNanos`, `lastPhaseErrorNanos`); `SLS:148` `private var gain`.
- `SLS:232-258` `public func start() throws` on `graphQueue`: `guard !started` at :234, `engine.prepare()` :255, `try engine.start()` :256. `SLS:285-295` `teardownEngine()` stops the engine and clears `started`, so every lifecycle rebuild (`SLS:379-384`, reached from device change :391, sleep :514, wake :520) re-enters `start()` past the guard.
- `SLS:350-358` `LifecycleHooks` doc claims the render block "re-seeds itself on every call already (no cached offset in this file to go stale)". False after this change.
- `SLS:623-628` render doc; `SLS:629` `private func render(`; `SLS:642-648` the fenced comment block; `SLS:649` `let cycleStartMonotonicNanos: Int64`; `SLS:650` `if #available(macOS 14.2, *) {`; `SLS:651` `let monoTs = CoreAudioSystemTap.timespec(fromHostTime: timestamp.pointee.mHostTime)`; `SLS:652` `cycleStartMonotonicNanos = SyncTiming.monotonicNanos(monoTs)`.
- `SLS:192` the init render block calls `boxed?.render(isSilence:timestamp:frameCount:audioBufferList:)` — unchanged by making `render` internal.
- `BTS:485` `final class BTDeviceSink: @unchecked Sendable`; `BTS:590-591` `scratch` / `scratchCapacity`; `BTS:563` `private var running`.
- `BTS:748` `private func startLocked() throws` (on `graphQueue`), `guard !running` :749, `engine.prepare()` :793, `try engine.start()` :794. `BTS:833-849` `rebuildLocked` → `stopLocked` → `startLocked`, so every rebuild cause (`config_change`, `rate_change`, `composition_change`, `reanchorAll`) re-seeds through `startLocked`.
- `BTS:1101-1111` `makeSourceNode` captures `[weak self]`; `BTS:1113` `private func render(`; `BTS:1120-1125` guard including `#available(macOS 14.2, *)`; `BTS:1126-1129` the two comment lines plus `let cycleStart = SyncTiming.monotonicNanos(CoreAudioSystemTap.timespec(fromHostTime: timestamp.pointee.mHostTime))`.
- `BTS:874` `func test_waitForPendingRebuild() { graphQueue.sync {} }`; `BTS:1676` `BTSyncedSink.enqueue(interleavedFrames:frameCount:pts:)`; `BTS:1764` `sinkForTesting(uid:)`.
- Tests (`AudioutCore/Tests/AudioutCoreTests/`): `SyncedLocalSinkTests.swift:1-3` imports `Testing`, `Foundation`, `@testable import AudioutCore`; `:399-409` `rampSink()` (87 ms effective delay, mono 48 kHz); `:414-423` `enqueueRamp(into:)` (20 000-sample ramp starting at 1.0, fixed pts). `BTSyncedSinkTests.swift:1-3` same imports; `:500-507` `anchoredSink(uid:)` (100 ms delay, mono 48 kHz, fixed pts); `:20-30` `enqueueRamp(into:atSec:)`; `:604-605` the `test_waitForPendingRebuild()` idiom before rendering after an enqueue. Neither suite ever starts an engine; both drive `renderInterleaved` only.
- `SyncCore.swift:18-22` doc says pts are produced by `timespec(fromHostTime:)` and the render block uses "that same helper".
- Other callers of `timespec(fromHostTime:)`: `BTClockStability.swift:226` (1 Hz timer, not a render path), `MicProbeSession.swift:187`, `NativeCaptureCoordinatorTests.swift:1071,1091-1092`. All stay.
- Root `AGENTS.md:146-155`: a new test names its defect in one comment sentence. `AudioutCore/AGENTS.md`: `IsolatedSuite`, no bare `swift test`.

### Steps

Order keeps the build green at every step and makes the new tests fail for the real reason (Step 5) before the render lines change (Step 6).

1. **`NCC` — open the two statics the sinks and tests need.** At `:4189` change `private static func machNanoseconds(fromHostTime` to `static func machNanoseconds(fromHostTime` (internal). At `:4218` change `private static func sampleMachToMonotonicOffsetNanos()` to `static func sampleMachToMonotonicOffsetNanos()`. Leave `currentMonotonicNanos()` private. No other changes to those functions.

2. **`NCC` — add the shared cached-and-healed overload.** Immediately after the closing brace of `timespec(fromHostTime:)` (`:4187`) and before the `machNanoseconds` doc comment, add:
   `static func timespec(fromHostTime hostTime: UInt64, offset: inout Int64) -> timespec`
   Body, in this order: `machNanos = machNanoseconds(fromHostTime: hostTime)`; if `shouldResample(machNanos: machNanos, offset: offset, monotonicNowNanos: currentMonotonicNanos())` then `offset = sampleMachToMonotonicOffsetNanos()`; return `timespec(machNanos: machNanos, offset: offset)`. This is the `NCC:3778-3788` sequence moved into one function; the tap's own IOProc keeps its inline copy (do not refactor it). Doc comment: the production entry for a caller that owns a cached offset (a synced sink's render block); one `clock_gettime` per call for the drift check, never the two-clock resample unless the offset has fallen more than 1 s out of step (sleep). Then, in the `timespec(fromHostTime:)` doc at `:4180-4182`, extend "must go through the instance path (seeded in `startIOProc`, healed in the IOProc block)" with "or the `offset:` overload below" — one clause, nothing else.

3. **`SLS` — cached offset, seeding, `render` reachable.**
   - After `SLS:134` (`private var lastPhaseErrorNanos: Int64 = 0`) add `var machToMonotonicOffsetNanos: Int64 = 0` (internal, not private) with a doc comment stating: mach→CLOCK_MONOTONIC rebase offset for the render block, mirroring `CoreAudioSystemTap.machToMonotonicOffsetNanos`; seeded in `start()` before `engine.start()` and every lifecycle rebuild re-enters `start()`; thereafter written only by the render thread through `timespec(fromHostTime:offset:)`'s heal, so no lock; internal so a test can seed it while the engine is stopped.
   - In `start()`, insert `machToMonotonicOffsetNanos = CoreAudioSystemTap.sampleMachToMonotonicOffsetNanos()` on its own line immediately before `engine.prepare()` (`:255`), i.e. after the `guard !started` and the graph wiring, still inside the `graphQueue.sync` block.
   - `:629` change `private func render(` to `func render(`.
   - Render doc `:623-628`: replace the clause "by REUSING ``CoreAudioSystemTap/timespec(fromHostTime:)`` (the sleep-aware mach↔MONOTONIC helper — not reimplemented here)" with a clause naming `CoreAudioSystemTap.timespec(fromHostTime:offset:)` and the cached `machToMonotonicOffsetNanos`, and add one sentence: internal (not `private`) so a test can drive it with a synthetic `AudioTimeStamp`. Edit only lines 623-628.
   - `LifecycleHooks` doc `:350-358`: rewrite the sentence at `:351-356` so it says the render block's rebase offset (`machToMonotonicOffsetNanos`) is re-seeded by `start()`, which `restartEngine` reaches, so the state this file must explicitly clear is the release anchor (keep the list of anchor fields that follows). Edit only lines 351-356.
   - Do NOT touch `:651` yet (Step 6).

4. **`BTS` — same three edits for `BTDeviceSink`.**
   - After `BTS:591` (`private let scratchCapacity: Int`) add `var machToMonotonicOffsetNanos: Int64 = 0` (internal) with the same doc as Step 3, naming `startLocked()` and "every `rebuildLocked` pass re-enters `startLocked`" instead.
   - In `startLocked()`, insert `machToMonotonicOffsetNanos = CoreAudioSystemTap.sampleMachToMonotonicOffsetNanos()` on its own line immediately before `engine.prepare()` (`:793`).
   - `:1113` change `private func render(` to `func render(`, and add a one-line doc above it: internal so a test can drive it with a synthetic `AudioTimeStamp`.
   - Do NOT touch `:1126-1129` yet (Step 6).

5. **Tests — write both, run, paste the red output.** Each test is a `@Test` inside the existing suite class, named `renderUsesTheCachedRebaseOffset_notAFreshTwoClockSample`. Add `import AVFoundation` at the top of each test file (for `AudioTimeStamp`, `AudioBufferList`, `mach_absolute_time`). Defect sentence (required by root `AGENTS.md:148`), to put in the doc comment of each: "The render block rebases `mHostTime` with a fresh two-clock sample instead of the sink's cached offset: with the cached offset seeded 300 ms ahead of the real one, a cycle whose cached rebase lands exactly on the release target must open the gate, while a fresh sample lands 300 ms early and stays silent."

   Body, both suites:
   1. `let real = CoreAudioSystemTap.sampleMachToMonotonicOffsetNanos()`; set `sink.machToMonotonicOffsetNanos = real + 300_000_000`.
   2. `let host = mach_absolute_time()`; `let cycleStart = Int64(CoreAudioSystemTap.machNanoseconds(fromHostTime: host)) + sink.machToMonotonicOffsetNanos`.
   3. Anchor so the target equals `cycleStart`: pts nanos = `cycleStart - delay` where delay is `87_000_000` for `SyncedLocalSinkTests` (the `rampSink()` delay, `:397-398`) and `100_000_000` for `BTSyncedSinkTests` (`anchoredSink`'s 100 ms, `:494-495`). Build `timespec(tv_sec: Int(pts / 1_000_000_000), tv_nsec: Int(pts % 1_000_000_000))` and enqueue the same strictly increasing ramp the existing helpers build (`SyncedLocalSinkTests.swift:414-423`, `BTSyncedSinkTests.swift:20-30`), but with this computed pts instead of the fixed second. SLS: `sink.enqueue(...)` directly. BT: build the manager exactly as `anchoredSink` does (`:500-505`), call `manager.enqueue(interleavedFrames:frameCount:pts:)`, take `sink = manager.sinkForTesting(uid:)`, then `sink.test_waitForPendingRebuild()` (the `:604-605` idiom), and `defer { manager.stop() }`. Set the sink's offset (step 1) before the enqueue in both.
   4. Build `var stamp = AudioTimeStamp()` with `stamp.mHostTime = host` and `stamp.mFlags = .hostTimeValid`; a `[Float](repeating: 0, count: 512)` output array; `let abl = AudioBufferList.allocate(maximumBuffers: 1)` with buffer 0's `mNumberChannels = 1`, `mDataByteSize = UInt32(512 * MemoryLayout<Float>.size)`, `mData` = the array's base pointer (inside `withUnsafeMutableBufferPointer`); `var isSilence = ObjCBool(false)`; call `sink.render(isSilence: &isSilence, timestamp: &stamp, frameCount: 512, audioBufferList: abl.unsafeMutablePointer)`; `free(abl.unsafeMutablePointer)` after.
   5. Assert: the returned status `== noErr`; `isSilence.boolValue == false`; `out.first(where: { $0 != 0 }) == ramp[0]`.

   Why it is red before Step 6: the helper's fresh sample is within microseconds of `real`, so the cycle lands 300 ms before the target and the gate stays shut (`isSilence` true, all zeros). Why the heal does not interfere after Step 6: predicted − now is 300 ms minus the test's own elapsed microseconds, well under the 1 s threshold at `NCC:4236`.

   Run `bash scripts/run-tests.sh --filter 'SyncedLocalSink|BTSyncedSink'`. Expected: a `Test run with N tests` line, exactly the two new tests failing, everything else passing. Paste the output.

6. **Swap the render lines.**
   - `SLS:651`: replace that single line with `let monoTs = CoreAudioSystemTap.timespec(fromHostTime: timestamp.pointee.mHostTime, offset: &machToMonotonicOffsetNanos)`. Lines 642-650 and 652 onward stay byte-identical.
   - `BTS:1126-1129`: replace the two comment lines and the two-line `let cycleStart = ...` with a one-line comment (rebase through the sink's cached offset, healed by the shared helper) and `let cycleStart = SyncTiming.monotonicNanos(CoreAudioSystemTap.timespec(fromHostTime: timestamp.pointee.mHostTime, offset: &machToMonotonicOffsetNanos))`.

7. **`SyncCore.swift:20-22`** — reword so the render blocks rebase "through the same offset math (`CoreAudioSystemTap.timespec(fromHostTime:offset:)`, a cached per-sink offset)" instead of "via that same helper". Doc only; the file is licence-clean, add no code.

8. Run Verification.

### Out of scope — do not touch

- `SLS:190-194` (`var boxed` / `boxed = self`), `SLS:367-372` (`makeLiveLifecycleHooks`, the `restartEngine: { try? ... }` hook), `SLS:642-650` (the "Called only while still gated ... pre-roll only" comment block plus the two lines after it). Ticket 11 owns these; the only edit near them is the single line `:651`.
- The tap's own inline heal at `NCC:3773-3788` and `PerAppCaptureCoordinator.swift`'s duplicated offset code — no refactor to the new overload.
- `BTClockStability.swift:226` and `MicProbeSession.swift:187` still call `timespec(fromHostTime:)`; leave them.
- No sleep/wake wiring for `BTSyncedSink` in `NativeBackend.swift`; the heal covers it.
- No changes to existing tests, `renderInterleaved`, `PhaseController`, `SyncTiming.plan`, telemetry, or `Analytics`.
- No cleanup, no abstractions beyond the one overload, no error handling for impossible cases, no backwards-compat shims. Do not commit or push.

### Verification

```
bash scripts/run-tests.sh --filter 'SyncedLocalSink|BTSyncedSink'
```
Expected: a `Test run with N tests` line with N = previous count + 2, zero failures. Also `bash scripts/build.sh` → exits 0.

Baseline: I started this filter at `a14ff11f` but it never got a build permit (both local permits held by other pipelines, mule unreachable) and did not finish. Step 5's run is the baseline: every pre-existing test in the filter must pass there and only the two new ones fail. If any pre-existing test fails in Step 5, stop and report it as a discrepancy.

Test seam: `AudioutCore/Tests/AudioutCoreTests/SyncedLocalSinkTests.swift` (suite at `:11`) and `AudioutCore/Tests/AudioutCoreTests/BTSyncedSinkTests.swift` (suite at `:9`). Defect each catches: the render block rebasing with a fresh two-clock sample instead of the sink's cached offset.

Merge check for the parallel ticket, after Step 8: `git diff -U0 -- AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift` must show no hunk touching lines 190-194, 367-372, or 642-650.

### Execution plan

One track, SERIAL, in this worktree: `NativeCaptureCoordinator.swift`, `SyncedLocalSink.swift`, `BTSyncedSink.swift`, `SyncCore.swift`, the two test files. Model: sonnet. Effort: medium. Steps 3 and 4 depend on Step 1-2's symbols; Step 6 depends on 3-4; nothing is parallelisable without a second worktree, and the ticket says one worktree. No uncommitted work on the branch.

### Executor rules (copy verbatim into the handoff prompt)

> - `cd` into `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-12-render-callback-clock-rebase` first; confirm `git rev-parse --short HEAD` prints a14ff11f.
> - Read the nearest AGENTS.md before editing any folder (root `AGENTS.md`, `AudioutCore/AGENTS.md`, `AudioutCore/Sources/AudioutCore/AGENTS.md`).
> - Never commit or push.
> - Tests and builds ONLY via `bash scripts/run-tests.sh --filter ...` and `bash scripts/build.sh`; never bare swift/xcodebuild. Build capacity is 2 local permits shared with five other pipelines: expect queueing, never bypass it. Trust only a `Test run with N tests` line in the output; a filter that matches nothing prints green. Never run audio-playing tests outside the ticket's filter.
> - If Edit/Write refuse (cross-worktree), edit via shell (sed, heredocs, python).
> - Never touch `main` or any other worktree.
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
