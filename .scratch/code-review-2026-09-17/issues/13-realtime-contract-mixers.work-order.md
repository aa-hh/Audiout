# Work order — ticket 13: one real-time policy for tap delivery, and no blocking `queue.sync` in the mixers

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-13-realtime-contract-mixers` at `a14ff11f`, clean.

## Goal

The per-app tap delivery path (`NativeBackend.swift:1874-1875` → `AppRouteMixer.handleBuffer` and `LeveledAppInjector.handleBuffer`) currently parks the tap's delivery thread on each mixer's default-QoS state queue, the same queue that main-thread route edits, converter construction and metering toggles hold. The whole-system path already fixed this (the T8 snapshot at `NativeCaptureCoordinator.swift:1659-1688`), but its own comments contradict each other about what the delivery thread is. This ticket writes the policy down once at the IOProc registration site, makes the whole-system comments agree with it, and brings both mixers onto the same snapshot-plus-`try()` shape so a route edit on main can no longer stall a tap's delivery. Reviewer's findings capture #4 and #10; the fix is for the user who hears stutter when they drag a slider while two per-app-routed apps play.

## Settled: real-time policy

Decision: option (b), refined. The delivery thread is the `.userInitiated` serial dispatch queue the IOProc is registered on, not the HAL's real-time thread, but the HAL dispatches the block synchronously and waits for it, so the block's wall time still counts against the device's IO cycle. Reasoning, all from code:

- `NativeCaptureCoordinator.swift:3761-3766`: the IOProc is created with `AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue)` where `queue = DispatchQueue(label: "com.audiout.native.capture", qos: .userInitiated)`. Apple's header (`AudioHardware.h`, MacOSX27.0.sdk, `inDispatchQueue` doc at lines 1384-1388): "The dispatch queue on which the IOBlock will be dispatched. All IOBlocks are dispatched synchronously. … If this value is NULL, then the IOBlock will be directly invoked." So: not the RT thread's priority, but on the RT thread's critical path.
- The block itself already allocates (`Data(bytes:count:)` copies at `:3789-3801`) and the design accepts the AVAudioConverter run on this path (`:1656-1658`, `:1696`). Allocation and the converter run are accepted costs; there is no "no-allocation" contract to honour.
- `AVFormatConverter.lock` (`:4318`) has exactly two takers: `convertToAirPlayPCM` (`:4419-4420`, the delivery thread) and `conversionFailureCount` (`:4387-4388`, a test seam). No production thread ever contends it, so `lock.lock()` there never parks anyone. The mixers' per-bundle converters are the same class with the same single caller (the one tap per bundle).
- The T8 `try()` at `:1683-1688` is guarding a different thing: `queue`-published state whose writers (`start`/`stop`/`recreateTap`/`updateRouting`) do unbounded work while holding `queue`, and the last-published snapshot is at most one edit stale, so dropping one buffer on a miss costs nothing.
- `LeveledAppInjector.swift:98-101` already states the bounded-lock rule for `mixLock`: "Critical sections are a bounded sample copy and nothing else: never a Core Audio call, never a wait on `queue`", and its `handleBuffer` (`:284-286`) already takes `mixLock` with `lock()` from the delivery path.

So the one policy, to be written at the registration site:

1. The IOProc block runs on the `.userInitiated` serial queue it was registered on; the HAL dispatches it synchronously, so its wall time counts against the IO cycle.
2. Nothing on this path (the block, `handleBuffer`, the mixers) waits on a serial queue, or on any lock whose holder may do unbounded work (build a converter, recompute routes, fire callbacks, log). Queue-confined state is read as an immutable snapshot through `snapshotLock.try()`; a miss drops the buffer.
3. A lock whose every holder does only bounded in-memory work may be taken with `lock()`: the converter's own lock (single caller in production), the mixers' timeline and ring locks.
4. Allocation and the `AVAudioConverter` run are accepted costs here.

The `// ---- REALTIME THREAD ----` labels (`NativeCaptureCoordinator.swift:3766`, `PerAppCaptureCoordinator.swift:1346`) and the `REAL-TIME THREAD — never take queue here` line (`:1660`) are the inconsistency: they claim a real-time thread the code does not run on. They get reworded to point at the policy. The `try()`-drop stays (it is the T8 pattern the mixers now copy). The converter lock stays and gets a one-line note. `PerAppCaptureCoordinator.swift` is IN scope for its one label line only; nothing else in that file changes.

## Verified facts

NativeCaptureCoordinator.swift (`AudioutCore/Sources/AudioutCore/`):
- `:135` `private let queue = DispatchQueue(label: "NativeCaptureCoordinator.state")` (no QoS).
- `:233-247` `snapshotLock` doc; `:247` `private let snapshotLock = NSLock()`; `:253` `_bufferSnapshot`.
- `:1308-1337` `publishBufferSnapshot()` — "must hold `queue`", builds a `BufferSnapshot` and swaps it under `snapshotLock.lock()/unlock()`.
- `:1656-1659` `handleBuffer` doc + signature; `:1660` the line `// T8 (plan finding F12): REAL-TIME THREAD — never take \`queue\` here.`; `:1683-1688` the `snapshotLock.try()` read with `else { return }`; `:1696` `let converted = converter.convertToAirPlayPCM(buffer)`.
- `:3748` `private func startIOProc() throws`; `:3761` the `.userInitiated` queue; `:3763-3765` `AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue)`; `:3766` `// ---- REALTIME THREAD ----`.
- `:4312` `final class AVFormatConverter: PCMConverting, @unchecked Sendable`; `:4318` `private let lock = NSLock()`; `:4387-4388` `conversionFailureCount` takes `lock` (test seam); `:4419-4420` `convertToAirPlayPCM` begins `lock.lock(); defer { lock.unlock() }`.
- `NativeCaptureCoordinator.rmsOfS16LE` is static and pure (used at `AppRouteMixer.swift:403`).

PerAppCaptureCoordinator.swift:
- `:1339-1340` the per-app IOProc queue, `qos: .userInitiated`; `:1343-1345` `AudioDeviceCreateIOProcIDWithBlock`; `:1346` `// ---- REALTIME THREAD ----`. `:1396` `onBuffer?(CapturedBuffer(...))` is called from inside that block.
- `:79-91` `enum State` has `.idle, .resolvingProcess, .creatingTap, .capturing(TapFormat), .stopping, .failed` (the switch at `AppRouteMixer.swift:374-379` lists all of them).

NativeBackend.swift `:1874-1875`: both `routeMixer.handleBuffer(bundleID:buffer:)` and `leveledInjector.handleBuffer(bundleID:buffer:)` are called from the per-app `onBuffer` closure, i.e. on the per-app tap's IOProc queue.

AppRouteMixer.swift:
- `:55` `public final class AppRouteMixer: @unchecked Sendable`.
- `:147-148`, `:152-153`, `:159` callback docs say "Called on the mixer's serial queue" — false today for `onMixedBuffer`/`onAppLevel` (fired at `:417-418` after `queue.sync` returns, on the caller's thread) and for `onDestinationSetsChanged` (`:308`, after `queue.sync`).
- `:183` `makeConverter` closure; `:187` `private let queue = DispatchQueue(label: "AppRouteMixer.state")` (no QoS); `:195` `nextStreamID`; `:199` `currentSets`; `:204` `streamGainsForBundle`; `:210` `converterForBundle`; `:213` `timelines: [Int: MixTimeline]`; `:220` `meteringActive`.
- `:243-244` `destinationSets` and `:250-251` `streamIDs(for:)` are `queue.sync` reads.
- `:269-309` `updateRoutes`: `queue.sync` rebuilds `streamGainsForBundle` (`:296`), prunes `timelines` (`:299-303`), then `guard newSets != currentSets else { return nil }` (`:305`), sets `currentSets` (`:306`).
- `:361-363` `setMeteringActive` is `queue.async`.
- `:372-381` `handleStateChange`: `queue.sync`; `.capturing(format)` calls `makeConverter(format)` INSIDE the held queue (`:376`).
- `:389-418` `handleBuffer`: everything inside `queue.sync` including `convertToAirPlayPCM` (`:393`), `rmsOfS16LE` (`:403`), and `mixLocked` (`:411`); callbacks after (`:417-418`). Doc `:388` "Safe to call concurrently from several taps' IOProc threads."
- `:421-471` `mixLocked` ("MUST hold `queue`"): reads `currentSets` for the contributor count (`:425-426`), mutates `timelines` (`:441`, `:460-464`), calls `timeline.add` / `drainReady`.
- `:474-481` `flush`: `queue.sync` over `timelines`. `:485-490` `removeApp`: `queue.sync` removing from `converterForBundle` and `streamGainsForBundle`.
- `:560-567` `MixTimeline` doc: "Not thread-safe on its own — `AppRouteMixer` only ever touches it while holding its serial queue."

LeveledAppInjector.swift:
- `:53` `public final class LeveledAppInjector: @unchecked Sendable`.
- `:80` `private let queue = DispatchQueue(label: "LeveledAppInjector.state")`; `:84` `volumeForBundle`; `:89` `converterForBundle`; `:94` `meteringActive`.
- `:98-101` `mixLock` doc and declaration; `:104` `rings`; `:110` `active`; `:132` `diag`.
- `:133-143` the five write-side counters (`buffersIn`, `droppedInactive`, `droppedNotLeveled`, `droppedNoConverter`, `droppedConvertFailed`), documented as queue-confined and "Deliberately NOT under `mixLock`".
- `:147-166` `takeDiagnostics()`: `queue.sync`, holds `mixLock` for the `diag` block (`:148-155`), then reads/resets the five counters outside `mixLock` (`:157-165`).
- `:194-210` `updateLeveled`: `queue.sync`, then `mixLock` for `rings`. `:215-220` `setVolume`: `queue.async`. `:227-235` `setActive`: `queue.sync` + `mixLock`. `:239-241` `setMeteringActive`: `queue.async`. `:248-257` `handleStateChange`: `queue.sync`, `makeConverter` inside.
- `:259-294` `handleBuffer`: all inside `queue.sync`: `mixLock` read of `active` (`:266-268`), counter bumps, `convertToAirPlayPCM` (`:276`), scaling (`:280`), `buffersIn += 1` (`:284`), `mixLock` ring write (`:285-287`), `meteringActive` read (`:291`). Doc `:263` says "hops to `queue` like `AppRouteMixer`".
- `:300-333` `mix(into:frameCount:)`: `mixLock.try()`, bounded. `:339-343` `hasPendingAudio`: `mixLock.lock()`.
- `:349-352` `test_pendingSamples(for:)` (under `mixLock`); `:355-358` `test_hasRing(for:)`; `:362-364` `test_hasConverter(for:)` is `queue.sync` (so calling it drains the queue).
- `:369-373` `SampleRing` doc: "Written from `LeveledAppInjector`'s serial queue, read from the whole-system tap's real-time thread, both under `mixLock`".

Tests (`AudioutCore/Tests/AudioutCoreTests/`), Swift Testing (`@Suite`, `@Test`, `#expect`):
- `AppRouteMixerTests.swift`: `IdentityConverter` `:20-24`; `Sink` `:28-34`; `LevelSink` `:45-52`; `mixer()` `:55-57` builds `AppRouteMixer(makeConverter: { _ in IdentityConverter() })`; `s16Buffer(frames:atSecond:)` `:62`; `route(_:to:volume:)` `:106-111`; `capturing(_:)` `:124-126`; `// MARK: - Robustness` `:543`; `// MARK: - 6.` metering `:568`; `singleContributorLevel` `:571-583` calls `setMeteringActive(true)` then `updateRoutes` (sync) then `handleStateChange` (sync) then `handleBuffer`.
- `LeveledAppInjectorTests.swift`: `IdentityConverter` `:19-23`; `injector(_:)` `:40-48`; `capturing` `:50-53`; `s16Buffer(_:)` `:56-59`; `samples(_:)` `:77`; `program(_:frames:)` `:90`; `setVolumeAppliesToTheNextBuffer` `:236-244` calls `setVolume` (async) then `handleBuffer` directly; `preVolumeSourceRMSIsEmittedOnlyWhileMeteringIsActive` `:259-276` calls `setMeteringActive(true)` (async) then `handleBuffer` directly; `// MARK: - 8. Removal` `:279`.
- Both existing tests above are deterministic only because `handleBuffer` currently serializes behind the async setter on the same queue. After the fix they need one queue-draining sync call (Step 6).

Rules that bind: `AGENTS.md:143-155` (new tests name their defect in one comment sentence; extend before adding); `AudioutCore/AGENTS.md:11` (`run-tests.sh --filter`, never bare swift); `AudioutCore/Sources/AudioutCore/AGENTS.md` has no rule on this path beyond the map line `:36`. Memory trap: a `--filter` with no match reports green, so trust only the `Test run with N tests` line.

Baseline: `bash scripts/run-tests.sh --filter 'AppRouteMixer|LeveledAppInjector|NativeCaptureCoordinator'` → `Test run with 123 tests in 4 suites passed`. Mule was unreachable; ran locally, ~10 min cold.

## Steps

**Step 1 — failing test, AppRouteMixer.** In `AudioutCore/Tests/AudioutCoreTests/AppRouteMixerTests.swift`, under `// MARK: - Robustness` (`:543`), add `@Test func handleBufferDoesNotParkBehindAStateEditHoldingTheQueue()`. Defect comment (one sentence, required by `AGENTS.md:145`): it turns red if `handleBuffer` takes the mixer's state queue again, because a state or route edit holding that queue then parks the tap delivery thread for the edit's whole duration. Mechanics: build the mixer with a `makeConverter` closure driven by a small `@unchecked Sendable` gate object (an `NSLock`-guarded `Bool` plus two `DispatchSemaphore`s, `entered` and `release`): when the gate is open the closure returns `IdentityConverter()` at once; when closed it signals `entered`, waits on `release`, then returns `IdentityConverter()`. Sequence: gate open → `updateRoutes([route("a", to: "dev1")])`, `handleStateChange(bundleID: "a", state: capturing())`, attach a `Sink` to `onMixedBuffer`. Close the gate. On `DispatchQueue.global()` call `handleStateChange(bundleID: "b", state: capturing())` and signal a `finished` semaphore after it returns. Main test thread: `entered.wait()`. Then on a second `DispatchQueue.global()` block call `handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(7, 7)], atSecond: 1))` and signal `returned`. Assert `returned.wait(timeout: .now() + 10) == .success` (a 10 s ceiling is a hang-stop, not a speed claim). Then `release.signal()`, `finished.wait()`, and assert `sink.all.count == 1` (the buffer was mixed from the last published snapshot, not dropped). Run `bash scripts/run-tests.sh --filter AppRouteMixerTests` and paste the failing output before any source edit (fails on the `.success` expectation after 10 s).

**Step 2 — failing test, LeveledAppInjector.** In `LeveledAppInjectorTests.swift` before `// MARK: - 8. Removal` (`:279`), add `@Test func handleBufferDoesNotParkBehindAStateEditHoldingTheQueue()` with the same defect sentence and the same gate mechanics, built directly as `LeveledAppInjector(makeConverter: …)` (not via the `injector(_:)` helper). Setup with gate open: `updateLeveled([("a", 50)])`, `handleStateChange(bundleID: "a", state: capturing)`, `setActive(true)`. Close the gate; background `handleStateChange(bundleID: "b", state: capturing)`; `entered.wait()`; background `handleBuffer(bundleID: "a", buffer: s16Buffer([(1000, 1000)]))` + `returned`; assert `returned.wait(timeout: .now() + 10) == .success`; release, `finished.wait()`; assert `test_pendingSamples(for: "a") == 2`. Run `--filter LeveledAppInjectorTests`, paste the failing output.

**Step 3 — AppRouteMixer: snapshot + timeline lock.** In `AudioutCore/Sources/AudioutCore/AppRouteMixer.swift`:
- Add a private immutable struct (name it `DeliverySnapshot`) holding: `streamGainsForBundle: [String: [Int: Int]]`, `converterForBundle: [String: PCMConverting]`, `contributorCountByStream: [Int: Int]`, `meteringActive: Bool`, with a static empty value. Add `private let snapshotLock = NSLock()` and `private var _snapshot` (empty), documented as `NativeCaptureCoordinator.swift:233-247` documents its lock: guards only the reference, one store on publish, one `try()` read on delivery.
- Add `private func publishSnapshotLocked()` ("must hold `queue`") that builds the struct from `streamGainsForBundle`, `converterForBundle`, `meteringActive`, and `currentSets` (contributor count per `streamID`, mirroring `:425-426`), then stores it under `snapshotLock.lock()/unlock()` — same shape as `publishBufferSnapshot()` at `:1308-1337`.
- Call it at the end of every queue-held mutation: in `updateRoutes` after `currentSets = newSets` AND on the early-return path of the `guard newSets != currentSets` (`:305`) — `streamGainsForBundle` was already rewritten at `:296`, so publish BEFORE that guard; in `handleStateChange` after the switch; in `setMeteringActive`'s async block after the assignment; in `removeApp` after the two removals.
- Add `private let timelineLock = NSLock()` guarding `timelines` only; document it as bounded (holders do only array add/drain/removal, never a converter call, never a wait on `queue`). Every touch of `timelines` moves under `timelineLock`: the prune in `updateRoutes` (`:299-303`, inside the queue block is fine), `flush` (replace its `queue.sync` with `timelineLock`), and the mix step.
- Rewrite `handleBuffer` (`:389-418`) to: read the snapshot with `snapshotLock.try()` and return on a miss (copy the T8 comment's reasoning in two or three lines, pointing at the policy comment from Step 7); guard `streamGains`/`converter` from the snapshot; convert and compute the level OUTSIDE any lock; then for each stream call the mix step, which takes `timelineLock.lock()` for the timeline add/drain (and for the single-contributor `timelines.removeValue` at `:441`); fire the callbacks after, as today.
- Change `mixLocked` (`:421-471`) to take `contributorCount` as a parameter (from the snapshot) instead of reading `currentSets`, and to hold `timelineLock` instead of requiring `queue`; rename it `mixUnderTimelineLock` or keep the name and fix its "MUST hold" doc, either is fine, but the doc must name `timelineLock`.
- Fix the docs: `:147-148` → called on whatever thread called `updateRoutes`; `:152-153` and `:159` → called on the delivering tap's thread; `:388` keep; `:560-567` `MixTimeline` → "while holding `timelineLock`"; the `// MARK: State (confined to \`queue\`)` at `:185` gets a sibling MARK for the two locks.

**Step 4 — LeveledAppInjector: snapshot; counters under `mixLock`.** In `LeveledAppInjector.swift`:
- Same `DeliverySnapshot` shape (private to this file): `volumeForBundle`, `converterForBundle`, `meteringActive`; `snapshotLock`; `_snapshot`; `publishSnapshotLocked()` ("must hold `queue`"). Publish at the end of `updateLeveled`'s queue block, `setVolume`'s async block (inside the guard's success path), `setMeteringActive`'s async block, and `handleStateChange`.
- Move the five write-side counters (`:139-143`) under `mixLock`: replace the doc at `:133-138` with one saying they are bumped under `mixLock` from the delivery thread and read under `mixLock` by `takeDiagnostics`; an increment adds nothing measurable to `mix(into:)`'s critical section. In `takeDiagnostics` (`:147-166`) move the reads/resets of the five counters inside the existing `mixLock` section (keep the outer `queue.sync`, `diag` handling unchanged).
- Rewrite `handleBuffer` (`:259-294`) with no `queue.sync`: snapshot via `snapshotLock.try()` (miss → return); `mixLock.lock()` to read `active` and, if inactive, bump `droppedInactive` in the same section and return; guard `volume` and `converter` from the snapshot, bumping `droppedNotLeveled` / `droppedNoConverter` under a short `mixLock` take on those paths; convert and scale OUTSIDE any lock (`droppedConvertFailed` likewise under `mixLock` on failure); then one `mixLock` section for `buffersIn += 1` and the ring write; fire `onAppLevel` after. Fix the doc at `:263` (no longer hops to `queue`; reads the published snapshot and takes `mixLock` for bounded sections) and the `SampleRing` doc at `:369-371` ("Written from the per-app tap's delivery thread").

**Step 5 — run the two new tests green.** `bash scripts/run-tests.sh --filter 'AppRouteMixerTests|LeveledAppInjectorTests'`; paste the output. Expect the two new tests to pass and, before Step 6, possibly one or both of `setVolumeAppliesToTheNextBuffer` and `preVolumeSourceRMSIsEmittedOnlyWhileMeteringIsActive` to flake.

**Step 6 — drain the queue in the two async-setter tests.** In `LeveledAppInjectorTests.swift`, in `setVolumeAppliesToTheNextBuffer` (`:236-244`) insert `_ = injector.test_hasConverter(for: "a")` between `setVolume` and `handleBuffer`, and in `preVolumeSourceRMSIsEmittedOnlyWhileMeteringIsActive` (`:259-276`) insert the same line between `setMeteringActive(true)` and the second `handleBuffer`, each with a one-line comment: the setter is async on the state queue and `handleBuffer` no longer serializes behind it, so this sync read drains the queue first. `AppRouteMixerTests` needs no change: every `setMeteringActive(true)` there is followed by a `queue.sync` call (`updateRoutes` / `handleStateChange`) before `handleBuffer`.

**Step 7 — the policy comment and the labels in NativeCaptureCoordinator.swift.**
- `:3766`: replace `// ---- REALTIME THREAD ----` with the four-point policy from "Settled: real-time policy" above, in prose, opening with what thread this block really runs on and quoting the header sentence `All IOBlocks are dispatched synchronously` (AudioHardware.h). This is the ONE place the policy lives.
- `:1660`: replace `REAL-TIME THREAD — never take \`queue\` here.` with wording that names the tap delivery thread and refers to "the policy at `startIOProc`'s IOProc block". Leave the rest of that comment block (`:1661-1682`) as is.
- `:1696`: add one comment line above the `convertToAirPlayPCM` call: the converter's lock is the bounded, single-caller kind the policy allows.
- `:4318`: add one comment line on `private let lock = NSLock()`: taken by `convertToAirPlayPCM` on the delivery thread and by the `conversionFailureCount` test seam only.

**Step 8 — PerAppCaptureCoordinator.swift:1346.** Replace `// ---- REALTIME THREAD ----` with a one-line label naming the per-app tap delivery block and pointing at the policy comment in `NativeCaptureCoordinator.startIOProc`. Nothing else in this file.

**Step 9 — Verification** (below).

## Out of scope — do not touch

- `AVFormatConverter`'s lock stays; do not remove it, make it `try()`, or move converter ownership.
- No QoS change to any `DispatchQueue(label:)` in the three files; no `queue.sync` → `queue.async` conversions of the setters (`setVolume`, `setMeteringActive` stay async).
- No changes to `MixTimeline` / `SampleRing` internals, `mix(into:)`, `hasPendingAudio`, the sample math, `assignStreamIDs`, `updateRoutes`' topology logic, telemetry, or analytics.
- `PerAppCaptureCoordinator.swift`: the one label line only. `NativeBackend.swift`, `LocalPlaybackEngine`, `SyncedLocalSink`: untouched.
- Do not edit `singleContributorLevel`'s comment (`AppRouteMixerTests.swift:571-574`) or any other existing test beyond Step 6.
- No new files, no new test suites, no shared test helper extracted across the two test files (duplicate the small gate in each).
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims, no edits to any AGENTS.md or docs.
- Nobody commits or pushes.

## Verification

```
cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-13-realtime-contract-mixers"
bash scripts/run-tests.sh --filter 'AppRouteMixer|LeveledAppInjector|NativeCaptureCoordinator'
```
Expected: `Test run with 125 tests in 4 suites passed` (baseline observed: `Test run with 123 tests in 4 suites passed after 0.424 seconds`; +2 new tests). Trust only the `Test run with N tests` line. Then `bash scripts/build.sh` → exits 0 (the package compiles with the doc/comment edits). `git status --short` shows only the five edited files (three sources under `AudioutCore/Sources/AudioutCore/`, two tests under `AudioutCore/Tests/AudioutCoreTests/`) plus `PerAppCaptureCoordinator.swift`.

Test seam: `AppRouteMixerTests` (`AudioutCore/Tests/AudioutCoreTests/AppRouteMixerTests.swift:543`) and `LeveledAppInjectorTests` (`…/LeveledAppInjectorTests.swift:279`). Defect each new test catches: `handleBuffer` waiting on the mixer's state queue while a state edit (converter construction under `handleStateChange`) holds it, which parks the tap delivery thread for the edit's whole duration. Steps 1-2 must show these red before Step 3. Finding 4 is comment-only; its check is the build plus the reviewer reading the one policy comment at `startIOProc` against `:1660`, `:1696`, `:4318` and `PerAppCaptureCoordinator.swift:1346`.

## Execution plan

One track, serial, in this worktree. Steps 1-9 in order.
- Files: `AudioutCore/Sources/AudioutCore/AppRouteMixer.swift`, `…/LeveledAppInjector.swift`, `…/NativeCaptureCoordinator.swift`, `…/PerAppCaptureCoordinator.swift`, `AudioutCore/Tests/AudioutCoreTests/AppRouteMixerTests.swift`, `…/LeveledAppInjectorTests.swift`.
- Model: opus. Effort: high for Steps 3-4 (two lock domains and a snapshot per mixer, with counters moving lock), medium for the rest.
- No uncommitted work on the branch; the tree is clean at `a14ff11f`.
- Note for the runner: the mule was unreachable during my baseline run; a cold local run of this filter took about 10 minutes.

## Executor rules (copy verbatim into the handoff prompt)

> - `cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-13-realtime-contract-mixers"` first and confirm `git rev-parse --short HEAD` prints `a14ff11f`. Work only there; do not touch `main` or any other worktree.
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) — folder rules and traps bind even when the work order doesn't repeat them.
> - If Edit/Write refuse because the path is in another worktree, edit through the shell (`python3` / heredoc / `sed`) with the absolute path.
> - Tests and builds only via `bash scripts/run-tests.sh --filter ...` and `bash scripts/build.sh`; never bare `swift test`/`swift build`/`xcodebuild`. Never run audio-playing tests or any filter wider than the ticket's.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - The work order names two new tests: run each before making the source change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output, including the `Test run with N tests` line.
> - Touch nothing in the Out-of-scope list. Never `git commit`, `git push`, `git stash`, or `git checkout`.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
