# Work order — ticket 03: NativeBackend reports the failures it swallows

## Goal
Three clusters in `NativeBackend.swift` throw away failures the user feels: five persisted-store loads in `init` (a corrupt file silently resets measured Bluetooth latencies, sync trims, Cast offsets and per-device tone to defaults), four local-playback engine starts (the Mac goes silent in a "play everywhere" selection with nothing logged), and the quit-time restore of the user's prior default output (the write result is discarded and the aggregate is destroyed one line later). Each site gets the same report its siblings in the same file already use. Behaviour on failure does not change — only the reporting.

## Verified facts
1. `AudioutCore/Sources/AudioutCore/NativeBackend.swift` is 13,222 lines. Every ticket line number is still accurate.
2. Store loads, all inside `init`: `NativeBackend.swift:1785` (`btTrimStore?.load()`), `:1788` (`loadLatencies()`), `:1791` (`loadSpeakerIndex()`), `:1798` (`castOffsetStore?.load()`), `:1804` (`eqStore?.load()`). Each has the shape `if let x = (try? store?.call()) ?? nil { … }`.
3. All five load functions are `throws` and return an Optional: `BTTrimStore.load() throws -> [String: Double]?` (`BTTrimStore.swift:146`), `loadLatencies()` (`:160`), `loadSpeakerIndex()` (`:166`), `DeviceEQStore.load() throws -> (mainOut: DeviceEQ?, devices: [String: DeviceEQ])?` (`DeviceEQStore.swift:44`). Both quarantine the file and rethrow the decode error (`BTTrimStore.swift:213-224`, `DeviceEQStore.swift:44-56`).
4. `StoreRecovery.noteWriteFailure(_ error: Error)` is a static func on a public enum, no-op when no handler is installed (`StoreRecovery.swift:47-50`). The handler slot is `StoreRecovery.onWriteFailure: ((Error) -> Void)?` (`StoreRecovery.swift:39-42`) — process-global.
5. The sibling idiom already in this file: `do { try btTrimStore?.saveLatencies(all) } catch { StoreRecovery.noteWriteFailure(error) }` — `NativeBackend.swift:11509`, `:11570`, `:11601`, `:11775`, `:13049`, `:13058`.
6. Local-playback starts: `:4474` (`try? sink.start()`, inside `applySyncedLocalSinkTransition`, between `attachSyncedLocalSink(sink)` and `sink.startObservingLifecycleEvents()`); `:5243-5244` (`try? self.localPlaybackEngine?.start()` + `try? …addApp(…)`, inside `updateAppRoutes`'s `for route in plan.localRoutes + plan.leveledLocalRoutes` loop, guarded by `if case .capturing(let format)`); `:5348-5349` (same pair inside `handleLocalCaptureStateChange`, `case .capturing`); `:10217-10218` (same pair inside `reconcileLeveledConsumersLocked`'s `captureControlQueue.async` body).
7. `SyncedLocalSinkControlling.start() throws` (`NativeBackend.swift:13090-13091`). `LocalPlaybackControlling.start() throws` and `addApp(bundleID:tapFormat:volume:) throws` (`LocalPlaybackEngine.swift:45`, `:57`).
8. `Telemetry.fail(_ category: Category, _ event: StaticString, local: [String: String] = [:], shared: [String: String] = [:])` (`Telemetry.swift:81-82`). `Category` includes `localPlayback` (`Telemetry.swift:55`). `local` stays on the Mac; only `shared` reaches PostHog (`Telemetry.swift:74-80`).
9. `local_playback:start_failed` does not exist anywhere in `AudioutCore/Sources` today — it is a new event name, spelled exactly as the ticket gives it.
10. Quit-time restore: `:2799` `_ = self.aggregateControl.setDefaultOutputDevice(priorID)`, inside `stop()`, guarded by `aggregateDefaultActive` + default-is-ours + resolvable prior (`:2794-2798`); `publicAggregate.sweepOrphans()` runs on `:2800`. `priorUID` IS in scope at `:2799` as a `String`, bound at `:2796`.
11. `AggregateDeviceControlling.setDefaultOutputDevice(_:) -> Bool` (`AggregateOutputDevice.swift:74`).
12. `aggregate_default_restore` is emitted four times, all `Telemetry.log(.airplay, …)`: `:8409` (`outcome: no_target`, plus `prior`), `:8454` (`wrote`/`write_refused`, keys `outcome`/`target`/`attempt`), `:8480` (`landed`, plus `default`), `:8484` (`did_not_land`). `Telemetry.log` lines never leave the Mac. Signature is `Telemetry.log(_ category:_ event:_ fields:)`.
13. `pointDefaultAtAggregate()` captures `priorDefaultUID` and sets `aggregateDefaultActive = true` (`:8346-8358`).
14. `NativeBackendTests.swift` is 11,104 lines. Two suites: `@Suite struct NativeBackendTests` (`:1567`) and `@Suite struct NativeBackendGlobalStateTests` (`:10003`), the second nested in `extension SerializedSharedState` (`:9975`).
15. File-scope helper `makeBackend(eqStore:…)` passes `eqStore` into `NativeBackend.init` and injects `NoOpAggregateControl` (`NativeBackendTests.swift:639`, `:665`, `:686`). It does NOT expose `btTrimStore` or `castOffsetStore`.
16. Existing store test pattern: `makeBackend(eqStore: DeviceEQStore(directory: directory))` over `isolation.scratchDir` (`:9407-9412`). `NativeBackendTests` owns `private let isolation = TestIsolation(owner: "NativeBackendTests")` (`:1569`); `NativeBackendGlobalStateTests` has no such property. `TestIsolation` is `public final class` with `public init(owner: String)` (`IsolatedSuite.swift:47`, `:60`).
17. `DeviceEQStore` writes `device-eq.json` in its injected directory (`DeviceEQStore.swift:35-36`).
18. `StoreRecovery.onWriteFailure` install/restore precedent: `StoreRecoveryTests.swift:142-143`; a private `FailureCounter` lives at `StoreRecoveryTests.swift:153`.
19. `SpySyncedLocalSink` is a file-scope private double whose `start() throws` records `"start"` and throws nothing (`NativeBackendTests.swift:1407-1416`). `makeSyncedLocalBackend(macSelectedByDefault:…)` wires it via `backend.syncedLocalSinkFactory = { sink }` (`:1435-1452`).
20. `SpyLocalPlayback` is the `LocalPlaybackControlling` double (`:1305`, `:1323`).
21. Telemetry assertion pattern: `TelemetryLineBox` + `Telemetry._installTestSink { box.append($0) }` with `defer { Telemetry._installTestSink(nil) }`, asserting on raw JSON substrings like `"evt":"send_sched"` (`:1294-1301`, `:10023-10024`, `:10039`). `pollUntil` exists in both test files.
22. `AggregateOutputDeviceWiringTests` (`AggregateOutputDeviceTests.swift:296`) is inside `extension SerializedSharedState` (`:294`), has `makeBackend(aggregateControl:currentDefaultOutputUIDBox:)` (`:401-422`), a `FakeAggregateControl` with `resolvable:`/`setDefaultSucceeds:` and a `setDefaultCalls` log (`:22-99`), a `LockedBox<String?>` (`:102`), `pollUntil` (`:737`), and uses `Telemetry._installTestSink` (`:921-922`) with a `LinesBox` (`:715`).
23. `backend.test_aggregateDefaultActive` and `test_priorDefaultUID` exist (`NativeBackend.swift:7758-7759`).

## Steps
Test first in each cluster. Run each new test before its production edit and paste the failing output.

**Cluster A — store loads**
1. In `NativeBackendTests.swift`, inside `@Suite struct NativeBackendGlobalStateTests` (`:10003`), add a stored property `private let isolation = TestIsolation(owner: "NativeBackendGlobalStateTests")`, mirroring `:1569`.
2. In the same suite, add one test named `aCorruptEQStoreReportsTheFailedLoad`. It: takes `isolation.scratchDir`; writes bytes that are not valid JSON (`Data("not json".utf8)`) to `device-eq.json` in that directory; installs a capture into `StoreRecovery.onWriteFailure` with `defer { StoreRecovery.onWriteFailure = nil }`; constructs the backend with `makeBackend(eqStore: DeviceEQStore(directory: directory))`; then asserts the handler received at least one error. Do not call `backend.start()` — the failure happens in `init`. Failure message must name the defect: a corrupt tone store silently resets every stored EQ to flat with nothing reported.
3. Extend the doc comment above `NativeBackendGlobalStateTests` (`:9977-10002`), which today says "TWO kinds qualify, and nothing else does", to list a third kind: tests that install `StoreRecovery.onWriteFailure`, the same one process-global slot hazard. Keep the existing two bullets unchanged.
4. In `NativeBackend.swift`, rewrite each of the five load sites at `:1785`, `:1788`, `:1791`, `:1798`, `:1804` as a `do` block that calls the load with `try` and keeps the existing body for a non-nil result, with `catch { StoreRecovery.noteWriteFailure(error) }`. Each site stays independently wrapped (a failed Bluetooth trim load must not skip the latency load). The properties keep their existing declaration-site defaults, so failure behaviour is unchanged. Do not reorder the assignments interleaved between them.

**Cluster B — local playback starts**
5. In `NativeBackendTests.swift`, give `SpySyncedLocalSink` (`:1407-1416`) a settable error to throw: add a lock-guarded stored `Error?` property, defaulting to nil, and make `start()` throw it when set, after recording `"start"`. Every existing call site keeps working unchanged. Add nothing else to the double.
6. In `@Suite struct NativeBackendGlobalStateTests`, add one test named `aSyncedLocalSinkThatRefusesToStartIsReported`. Build the backend with the existing file-scope `makeSyncedLocalBackend(macSelectedByDefault: true)` (`:1435`), set the spy's start error before the sink is started, install a `TelemetryLineBox` via `Telemetry._installTestSink` with `defer { Telemetry._installTestSink(nil) }`, drive the selection, and `pollUntil` a line containing `"evt":"local_playback:start_failed"` appears. Failure message: "play everywhere" leaves the Mac silent with no report when the local sink refuses to start.
7. In `NativeBackend.swift:4474`, replace `try? sink.start()` with a `do`/`catch` whose catch calls `Telemetry.fail(.localPlayback, "local_playback:start_failed", local: ["error": "\(error)"], shared: ["site": "synced_local"])`. `sink.startObservingLifecycleEvents()` on the next line stays outside the `do` block and still runs.
8. In `NativeBackend.swift:5243-5244`, wrap the `start()` and `addApp(…)` pair in ONE `do` block, catching once with the same call as step 7 but `shared: ["site": "app_routes"]`. The following `setVolume` call stays outside and unchanged.
9. In `NativeBackend.swift:5348-5349`, same single `do` block over the pair, `shared: ["site": "capture_state"]`.
10. In `NativeBackend.swift:10217-10218`, same single `do` block over the pair, `shared: ["site": "leveled"]`. The following `setVolume` call stays outside and unchanged.

Fixed decisions for steps 7-10: event name exactly `local_playback:start_failed`; the error's description goes in `local` only; `shared` carries only the enum-like `site` key with exactly the four values above, and nothing else (no bundle id, no device name).

**Cluster C — quit-time default restore**
11. In `AggregateOutputDeviceTests.swift`, inside `@Suite struct AggregateOutputDeviceWiringTests` (`:296`), add one test named `theQuitTimeDefaultRestoreReportsItsOutcome`. Build a `FakeAggregateControl` that resolves both `AggregateOutputDevice.productUID` and a prior-device UID of your choice, `setDefaultSucceeds` at its `true` default. Start the `LockedBox<String?>` at the prior UID, `backend.start()`, then `setOutputSet` with one device id so the takeover runs — assert as a precondition that `backend.test_aggregateDefaultActive` is true and `test_priorDefaultUID` is the prior UID. Then set the box to `AggregateOutputDevice.productUID`, install the file's existing `LinesBox` + `Telemetry._installTestSink` pattern (`:715`, `:921-922`), call `backend.stop()`, and assert a line containing `"evt":"aggregate_default_restore"` and `"outcome":"wrote"` was emitted. Failure message: the quit-time restore of the user's prior default output reports nothing at all today, so a write the HAL refuses is invisible.
12. In `NativeBackend.swift:2799`, replace `_ = self.aggregateControl.setDefaultOutputDevice(priorID)` with a capture of the Bool into a local, followed by a `Telemetry.log(.airplay, "aggregate_default_restore", …)` call carrying the outcome. Reuse the exact `outcome` values `"wrote"` and `"write_refused"` from `:8455`. Do not call `restoreWriteReturned` and do not schedule a read-back: `sweepOrphans()` destroys the aggregate on the next line. Nothing else in the `stop()` teardown moves.

## Corrections appendix — these OVERRIDE the steps above where they conflict
These come from an independent spec check of the work order against the code. Apply them.

**C1 (blocking, step 4 as written does not compile).** `btTrimStore`, `castOffsetStore` and `eqStore` are Optional properties AND every `load()` returns an Optional, so `try btTrimStore?.load()` has type `[String: Double]??`. The existing `(try? …) ?? nil` is what flattens it. A literal `do { if let loaded = try btTrimStore?.load() { … } }` leaves `loaded` as `[String: Double]?` and `loaded.mapValues` / `loaded.mainOut` fail to compile. Keep the flattening: write each site as
```swift
do {
    if let loaded = try btTrimStore?.load() ?? nil {
        …existing body unchanged…
    }
} catch {
    StoreRecovery.noteWriteFailure(error)
}
```
and follow that same shape for the other four. Confirm each compiles rather than assuming.

**C2 (blocking, step 11 races).** The whole `stop()` teardown containing `:2799` runs inside `stateQueue.async { … }` opened at `NativeBackend.swift:2575`, so the telemetry line is written AFTER `backend.stop()` returns. Do not assert straight after `stop()`. Use the suite's own `pollUntil` (`AggregateOutputDeviceTests.swift:737`) to wait for the line.

**C3 (step 4 citations).** The interleaved assignments you must not reorder are `:1794-1796` (`btHardwareVolumeStore`, `btHardwareVolumeControl`, `btAbsoluteVolumeClaim`), plus `:1797` and `:1803`. `:1793` is a closing brace, not an assignment.

**C4 (step 12 field shape — settled).** Match the existing `:8454` emission's shape as closely as the site allows: emit keys `outcome` (`"wrote"` / `"write_refused"`) and `target` (`priorUID`, which is in scope as a `String`). Add `site: "stop"` so this fifth emission is distinguishable from the four in `restoreDefaultFromAggregate`, which this one is not part of. Do NOT add `attempt` — there is no retry loop here. The step-11 test asserts only `"evt":"aggregate_default_restore"` and `"outcome":"wrote"`; it does not assert the `site` key.

**C5 (step 2 capture type — settled).** No shared thread-safe error box exists: `FailureCounter` is private inside its own suite (`StoreRecoveryTests.swift:153`) and `TelemetryLineBox` (`NativeBackendTests.swift:1294`) holds strings, not errors. Add one small `private final class` box inside `NativeBackendTests.swift`, at file scope next to `TelemetryLineBox`, guarding an `[Error]` with an `NSLock` exactly the way `TelemetryLineBox` guards its strings. Nothing more.

**C6 (step 6 sequence — settled).** The new test lands in `NativeBackendGlobalStateTests`, which has no synced-local tests of its own, and the two candidates in `NativeBackendTests` disagree: `:8026` does `startAndDiscover(...)` then `setOutputSet([device.id])`; `:8060` does `backend.start()` then `setOutputSet([])`, which deliberately never enables the sink and would hang `pollUntil`. Use the `:8026` sequence — `startAndDiscover(...)` then `setOutputSet([device.id])` — so the sink actually starts and throws.

**C7 (extra fence).** A DUPLICATE `SpySyncedLocalSink` lives at `NativeBackendSyncedLocalSelectionTests.swift:25`, and the doc comment at `NativeBackendTests.swift:1402-1406` points at it. Step 5 changes ONLY the copy in `NativeBackendTests.swift`. Do not touch `NativeBackendSyncedLocalSelectionTests.swift` at all.

**C8 (baseline).** The `295 tests in 6 suites` baseline below is the scoper's own observed run, not an independent fact. If your pre-change run differs, report the number you saw and carry on; do not treat the mismatch as a blocker.

## Verification
```bash
bash scripts/run-tests.sh --filter 'NativeBackendTests|AggregateOutputDevice'
```
Scoper's observed pre-change baseline at `a14ff11f`, clean tree: `Test run with 295 tests in 6 suites passed after 14.346 seconds`, exit 0 (~17.5 min wall clock including the build). Done = the same command prints a `Test run with 298 tests` line (baseline + the three new tests) and `passed`. A bare "passed" without a `Test run with N tests` line proves nothing — a non-matching filter reports green. If a re-run finishes suspiciously fast, `AUDIOUT_TEST_NO_CACHE=1` forces a real run.

The ticket's own filter (`--filter NativeBackendTests`) does not reach cluster C's suite, which is why the filter above is widened. Run the widened one.

## Out of scope — do not touch
- Any restructuring or splitting of `NativeBackend.swift` — ticket 22 owns that. Minimal edits at the cited lines only. No refactors, no helper extraction, no reformatting.
- The other `try?` sites in `NativeBackend.swift` (`:2834`, `:5972`, `:6684`, `:6770`, `:7172`, `:7689`, `:7807`, `:7969`, `:8770`, `:10726`), and `_ = self.publicAggregate.adoptOrCreate()` at `:2082`.
- `restoreDefaultFromAggregate` / `restoreWriteReturned` / `verifyRestoreLanded` (`:8402-8494`) — read them, change nothing.
- `StoreRecovery.swift`, `Telemetry.swift`, `BTTrimStore.swift`, `DeviceEQStore.swift`, `LocalPlaybackEngine.swift`, `AggregateOutputDevice.swift`.
- `NativeBackendSyncedLocalSelectionTests.swift` (see C7).
- Adding `btTrimStore`/`castOffsetStore` parameters to the test `makeBackend` helper.
- The comment blocks around the edited lines, except the one doc-comment extension named in step 3.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims.

## Executor rules
- Follow the steps in order. Do not add, merge, reorder, or skip steps.
- Before editing in any folder, read the nearest AGENTS.md above it (and the root one) — folder rules and traps bind even when this work order doesn't repeat them. At minimum `AudioutCore/Sources/AudioutCore/AGENTS.md` and the tests folder's AGENTS.md if one exists.
- If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
- Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for.
- Run each of the three new tests BEFORE making its production change and paste the failing output. A test that passes before the change proves nothing.
- "Done" means the Verification command was run in this session and passed, with a `Test run with N tests` line in the output. Paste it. A bare "passed" is not evidence.
- Always `bash scripts/run-tests.sh` / `bash scripts/build.sh`; never a bare `swift test`, `swift build`, `swift run`, `xcodebuild` or `swift package`, filtered runs included.
- Nobody commits or pushes. All work stays uncommitted. No `.dev` bundle builds, no `livetest.sh`, no `make-app.sh`.
- Event names are an external contract: use exactly `local_playback:start_failed` and `aggregate_default_restore`, and the existing `Telemetry.fail(category:event:local:shared:)` / `Telemetry.log(category:event:fields:)` shapes. No device names, bundle ids, or free text in `shared`.
- Touch nothing in the Out-of-scope list.
- Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified.

## Owner follow-up, not a step
`local_playback:start_failed` is a new PostHog exception type. The event table lives in `docs/analytics-events.md` in the external `audiout-shared` repository and a new event is added there first. That repository is not in this worktree — flag it in your report.
