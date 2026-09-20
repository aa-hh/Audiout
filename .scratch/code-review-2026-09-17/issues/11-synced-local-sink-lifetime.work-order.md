# Work order — ticket 11: SyncedLocalSink deinit, restart failure report, stale comment, deinit deadlock

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-11-synced-local-sink-lifetime` (HEAD a14ff11f, clean). `cd` there first.

### Goal

`SyncedLocalSink` (the Mac's own delayed speaker output) currently can never be freed: its render closure holds a strong reference back to the sink, so `deinit` never runs. Fix that so the sink deinits after `stop()`, with a test that proves it. While in the file: a failed engine restart after a device change or wake is swallowed by `try?` and never recorded, so make it report through `Telemetry.fail`; one comment claims the clock rebase is pre-roll only when it runs every render cycle, so rewrite the comment; and once the sink can deinit, `deinit` calling `stopObservingLifecycleEvents()` (which does `lifecycleQueue.sync`) can deadlock if deinit runs on `lifecycleQueue`, so make the deinit path skip the queue hop. Findings sync #2, #3, #7 plus the sync.md loose-end note.

### Verified facts

- `SyncedLocalSink` is at `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift`, class starts line 41; a stub twin for platforms without AVFoundation is at line 1008 (do not touch it).
- The render-block cycle: lines 189-195 declare `var boxed: SyncedLocalSink?`, build `AVAudioSourceNode(format: format) { ... boxed?.render(...) ?? noErr }`, then `boxed = self`. `sourceNode` is `private let` (line 81), so the cycle is self → sourceNode → closure → boxed → self.
- `deinit` (lines 199-202) calls `stopObservingLifecycleEvents()` then `deinterleaveScratch.deallocate()`.
- Reference pattern: `BTDeviceSink.makeSourceNode` at `BTSyncedSink.swift:1102-1112`: `AVAudioSourceNode(format: connectionFormat) { [weak self] isSilence, timestamp, frameCount, audioBufferList in guard let self else { isSilence.pointee = true; return noErr }; return self.render(...) }`.
- `render(isSilence:timestamp:frameCount:audioBufferList:)` in SyncedLocalSink is a private instance method (signature at lines 629-634); its parameter labels match what the boxed call passes at line 193.
- `makeLiveLifecycleHooks()` at lines 368-373; the line to change is 372: `restartEngine: { [weak self] in try? self?.start() })`. `LifecycleHooks.restartEngine` is `() -> Void` (line 362). `start()` is `public func start() throws` (line 232).
- `Telemetry.Category` at `Telemetry.swift:54-56` includes `localPlayback`. `Telemetry.fail` signature at `Telemetry.swift:81-82`: `fail(_ category: Category, _ event: StaticString, local: [String: String] = [:], shared: [String: String] = [:])`. Existing callers with the same category: `BTConnectionManager.swift:165` (`Telemetry.fail(.localPlayback, "bt:connect_failed", ...)`).
- `AudioutCore/Sources/AudioutCore/AGENTS.md:22`: error text goes in `local`, only `shared` leaves the Mac.
- The stale comment is lines 642-645 (starting `// mach hostTime → CLOCK_MONOTONIC ns via the shared, sleep-aware rebase.` through `... paid during pre-roll only, not steady state.`). Lines 646-648 (`// The rebase lives on CoreAudioSystemTap (macOS 14.2+)...emit silence.`) are accurate and stay. The rebase call at lines 650-652 runs unconditionally before `renderInterleaved` is called at line 659.
- `lifecycleQueue` is `private let lifecycleQueue = DispatchQueue(label: "com.audiout.syncedlocalsink.lifecycle")` (line 111). `deviceChangeListenerBlock` is `private var` (line 113). `defaultOutputDeviceAddress` is a `private var` (lines 525-528) inside `#if canImport(AudioToolbox)`.
- `startObservingLifecycleEvents()` (lines 539-550) installs a listener block on `lifecycleQueue` capturing `[weak self]` and calling `self?.handleDefaultOutputDeviceChanged()`. `stopObservingLifecycleEvents()` (lines 553-560) does `lifecycleQueue.sync { guard let block = deviceChangeListenerBlock ... AudioObjectRemovePropertyListenerBlock(...); deviceChangeListenerBlock = nil }`. Both sit inside `#if canImport(AudioToolbox)`; the `#else` branch (lines 561-564) stubs both as empty.
- Deadlock reachability (decision 4): once step 2 lands, deinit CAN run on `lifecycleQueue`. The listener block's `self?.handle...` promotes the weak reference to a strong one for the call; if the owner drops its reference during that call, the block's temporary reference is the last, and deinit runs on `lifecycleQueue` when the call returns, then `lifecycleQueue.sync` inside deinit deadlocks. Today `NativeBackend.applySyncedLocalSinkTransition` (`NativeBackend.swift:4461-4482`) never sets `syncedLocalSink` to nil, so it is not hit in production yet; it is not provably unreachable, so fix it (step 5).
- `stop()` (lines 261-264) calls `teardownEngine()` then `clearSessionState()`; `teardownEngine` guards on `started`, so `stop()` on a never-started sink is safe and touches no engine.
- Test file: `AudioutCore/Tests/AudioutCoreTests/SyncedLocalSinkTests.swift` (1048 lines), `@Suite final class SyncedLocalSinkTests: IsolatedSuite` at line 11, Swift Testing (`import Testing`, `@testable import AudioutCore`). Helper `static func rampSink() -> SyncedLocalSink` at lines 399-408 builds an offline sink (no engine start). Weak-reference test idiom in this repo: `DefaultOutputDeviceMonitorTests.swift:257-268` (`weak var weakDropped: Recorder?`, scope block, `#expect(weakDropped == nil, ...)`).
- Baseline (run 2026-09-20 with `AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter SyncedLocalSink`): `Test run with 43 tests in 6 suites passed`.
- No AGENTS.md exists under `AudioutCore/Tests/`. Applicable ones: root `AGENTS.md`, `AudioutCore/AGENTS.md`, `AudioutCore/Sources/AudioutCore/AGENTS.md`.

### Steps

1. **Test first** — `SyncedLocalSinkTests.swift`, inside the `SyncedLocalSinkTests` class (add it after `noAudioBeforeEnqueue_isSilent` or at the end of the "render core" tests; anywhere inside the class body). Add one `@Test func` named `sinkDeinitsAfterStop`. Body: declare `weak var weakSink: SyncedLocalSink?`; inside a `do { }` block create `let sink = Self.rampSink()`, assign `weakSink = sink`, call `sink.stop()`; after the block `#expect(weakSink == nil, "...")` with a message naming the render-block capture. Do not call `start()` or `startObservingLifecycleEvents()`. Run `bash scripts/run-tests.sh --filter SyncedLocalSink` and paste the output: this test must FAIL on the current tree (the boxed capture keeps the sink alive). If it passes before step 2, stop and report.

2. **Render block** — `SyncedLocalSink.swift` lines 189-195, in `init`. Delete the `var boxed` declaration, the `boxed = self` assignment, and the two comment lines above them. Build the node as `BTSyncedSink.swift:1102-1112` does: capture `[weak self]`, `guard let self else { isSilence.pointee = true; return noErr }`, then `return self.render(isSilence:timestamp:frameCount:audioBufferList:)` with the same arguments the old call passed. Replace the two-line comment with one line saying the block captures self weakly so the sink can deinit (do not reuse the word "unowned").

3. **Failed restart** — `SyncedLocalSink.swift` line 372. Replace `restartEngine: { [weak self] in try? self?.start() }` with a closure that still captures `[weak self]`, does `guard let self else { return }`, then `do { try self.start() } catch { Telemetry.fail(.localPlayback, "sync:restart_failed", local: ["error": String(describing: error)]) }`. No `shared` payload. Event name is exactly `sync:restart_failed`, category `.localPlayback` (exists, see Verified facts). Leave the `performLifecycleRebuild` doc comment (lines 375-378) unchanged.

4. **Stale comment** — `SyncedLocalSink.swift` lines 642-645 only. Replace those four comment lines with a comment that says: the mach host time is rebased to `CLOCK_MONOTONIC` here on every render cycle, before `renderInterleaved` runs, because the T-CORRECTION loop inside `renderInterleaved` needs `cycleStartMonotonicNanos` each cycle. Keep lines 646-648 as they are. Do not change the `if #available` block or the `CoreAudioSystemTap.timespec(fromHostTime:)` call (ticket 12 owns that call).

5. **Deinit deadlock** — `SyncedLocalSink.swift`. Inside the `#if canImport(AudioToolbox)` block, move the body of `stopObservingLifecycleEvents()`'s `sync` closure (the `guard let block ...`, the `AudioObjectRemovePropertyListenerBlock(...)` call, and `deviceChangeListenerBlock = nil`) into a new `private func removeDeviceChangeListener()`. `stopObservingLifecycleEvents()` becomes `lifecycleQueue.sync { removeDeviceChangeListener() }`. In the `#else` branch add an empty `private func removeDeviceChangeListener() {}` next to the two existing stubs. Change `deinit` (line 200) to call `removeDeviceChangeListener()` instead of `stopObservingLifecycleEvents()`, with a two-line comment: deinit can run on `lifecycleQueue` (the listener block's temporary strong reference can be the last one), so it must not `sync` onto that queue; nothing else can reach the sink during deinit, so no queue hop is needed. Update the doc comment on `stopObservingLifecycleEvents` (line 552) so it no longer says "also called from `deinit`".

6. Run the Verification commands.

### Out of scope — do not touch

- Any file other than `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift` and `AudioutCore/Tests/AudioutCoreTests/SyncedLocalSinkTests.swift`. `Telemetry.swift` stays untouched (the category exists).
- The rebase call at lines 650-652 and the `if #available` block (ticket 12 rewrites it in another worktree). Only the comment lines 642-645 change.
- `BTSyncedSink.swift`, `NativeBackend.swift`, `NativeCaptureCoordinator.swift`, the stub `SyncedLocalSink` at line 1008.
- No test for the restart failure (needs a throwing `AVAudioEngine.start()`; not reachable offline). No test for the deinit-on-queue path.
- No renaming of `LifecycleHooks`, no changes to `performLifecycleRebuild`, `start()`, `stop()`, `teardownEngine`, `clearSessionState`, or the existing telemetry events (`sync_ring_overflow`, `synced_local_reanchor`).
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims.
- The `sync:restart_failed` event needs a row in `docs/analytics-events.md` in the `audiout-shared` repository (CLAUDE.md rule). That repo is not in this worktree: do not attempt it; state in the report that the row is owed.

### Verification

```
bash scripts/run-tests.sh --filter SyncedLocalSink
```
Expected: a line `Test run with 44 tests in 6 suites passed` (43 baseline + `sinkDeinitsAfterStop`). Trust only the `Test run with N tests` line; a filter that matches nothing also prints "passed". Use `AUDIOUT_TEST_NO_CACHE=1` in front if a repeated run reports a cache skip.

```
bash scripts/build.sh
```
Expected: exits 0, no errors.

Baseline observed before any change: `Test run with 43 tests in 6 suites passed after 3.874 seconds`.

Test seam: `SyncedLocalSinkTests` (`AudioutCore/Tests/AudioutCoreTests/SyncedLocalSinkTests.swift:11`), new test `sinkDeinitsAfterStop`. Defect it catches: a strong capture in the render block keeps the sink alive forever, so `deinit` (listener removal, scratch free) never runs. Steps 3, 4, 5 change nothing a test can see offline; the build and the unchanged 43 tests stand in.

### Execution plan

Single track, all six steps, files: `SyncedLocalSink.swift`, `SyncedLocalSinkTests.swift`. Model: opus. Effort: high. SERIAL by nature (one track). Branch has no uncommitted work; tree is clean at a14ff11f.

### Executor rules (copy verbatim into the handoff prompt)

> - First `cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-11-synced-local-sink-lifetime"`. Work only there.
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
> - Tests and builds go ONLY through `bash scripts/run-tests.sh --filter SyncedLocalSink` and `bash scripts/build.sh`; never a bare `swift test`/`swift build`. Trust only a `Test run with N tests` line.
> - Never `git commit` or `git push`.
> - If the Edit/Write tools refuse to write to the worktree, make the edit through the shell instead (python, sed, or a heredoc).
