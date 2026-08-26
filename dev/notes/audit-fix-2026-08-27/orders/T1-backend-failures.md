# T1 — Backend failure wiring (work order)

## Header

**Branch:** `claude/fix-backend-failures`, forked from commit `7886f98d` (clean tree, no uncommitted work).
Create per repo rules: `git worktree add .claude/worktrees/fix-backend-failures -b claude/fix-backend-failures`, then `git push -u origin claude/fix-backend-failures`. Enable hooks if fresh: `git config core.hooksPath .githooks`. Commit on this branch only; `main` is merge-only. Do NOT merge — pushing the branch is the end state; merging needs Alec's go-ahead.

Repo root (path has a space — quote it everywhere): `/Users/alechenderson/Projects/AirPlay Controller` → work in the new worktree. Read `CLAUDE.md`, `AGENTS.md`, `AudioutCore/AGENTS.md`, `AudioutCore/Sources/AudioutCore/AGENTS.md`, `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md`, `AudioutCore/Sources/AudioutApp/AGENTS.md`, `AudioutCore/Sources/AudioutSettingsUI/AGENTS.md` before editing.

**BINDING BUILD/TEST RULE.** ALL compiles and test runs go through the wrapper scripts, which route work to the remote test mule: `bash scripts/build.sh` for every compile check, `bash scripts/run-tests.sh --filter <Suite>` for every test run (the full suite only as the final check — Guard 4 runs it at commit anyway). Bare swift-build / swift-test invocations are FORBIDDEN in this repo — they opt out of the mule, the machine-wide concurrency cap, and the unchanged-sources cache, and pin work to the local machine that is running many parallel agents (a PreToolUse hook also blocks them). `AUDIOUT_BUILD_LOCAL=1` only if the mule is unreachable, and say so in your report. Two known traps: never pipe run-tests.sh through `| tail` or similar — the pipe eats the exit code; read it directly. And never kill or abandon an in-flight remote test run — orphaned remote legs pin the build lock.

**Goal.** The app's failure copy and honesty machinery exist but several of the best pieces are unwired: a speaker that vanishes reports "unknown reason" while perfect copy sits two files away; a dead capture tap retries forever behind rows that still read "Connected", with no user-visible state; Copy Details is permanently greyed on every AirPlay failure; the Settings pane claims "Speakers reconnected" without checking; a dropped volume push leaves the fader lying with no bound; and two backend reads block the popover's main thread on busy serial queues. This track wires each existing piece to its consumer with the smallest root-cause diff. It is for a paid app (€30) whose named target user runs it unattended all day — honest failure surfacing is the product promise.

**Files T1 owns (edit freely):**
- `AudioutCore/Sources/AudioutCore/NativeBackend.swift` — EXCEPT lines ~8632–8900 (the "MeteringControlling (T-GATE / T3) + level coalescing (D3)" MARK section starting at 8632: `levelEmitIntervalNanos`, `emitLevel`, `emitAppLevel`, `emitCombinedLevel`, `scheduleLevelEmit`, `emit(_:)`). A parallel track (T8) owns that region. You may CALL `emit(_:)` (NativeBackend.swift:8853, runs on `stateQueue`) but not edit anything inside the region.
- `AudioutCore/Sources/AudioutCore/ConnectionState.swift`
- `AudioutCore/Sources/AudioutCore/NativeCaptureCoordinator.swift` (research found no edit is needed here; listed for completeness)
- `AudioutCore/Sources/AudioutCore/OwnToneBackend.swift` — `makeBackend` arm only (research found no edit needed; the diagnostics-port option was rejected — see Open decisions #1)

**Sanctioned narrow-exception hunks (smallest possible; each is flagged again at its step):**
1. `AudioutCore/Sources/AudioutCore/OutputBackend.swift` — ONE new `BackendEvent` case (step 3) + the `LatencyConfigurable.applyStartBuffer` signature/doc (step 6).
2. `AudioutCore/Sources/AudioutApp/AppDelegate.swift` — the new event's `apply`/`describe` arms (step 3) + `makeLatencySettingModel`'s closure return (step 6). Nothing else in AppDelegate.
3. `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift` — ONLY the note-slot region, lines ~993–1181 (`resolvedSystemAirPlayNote`, its state vars/setters, the PRECEDENCE doc comment, the `test_systemAirPlayNote*` seams). A parallel track owns the rest of this file.
4. `AudioutCore/Sources/AudioutSettingsUI/AudioSettingsViewController.swift` — the `LatencySettingModel` struct (top of the same file) + the status-label logic in `applyBuffer` (step 6). Nothing else.
5. `AudioutCore/Sources/AudioutCore/MockBackend.swift` — the `LatencyConfigurable` conformance return values only (~3 lines, step 6).
6. `AudioutCore/Sources/settings-snapshot/main.swift` — the `LatencySettingModel` `apply:` closure return (1 line, step 6).
7. `AudioutCore/Sources/mock-speakers-demo/main.swift` — one new case in its exhaustive `describe` switch (the compiler will demand it after step 3).
8. `AudioutCore/AGENTS.md` — one bullet update (step 9). Docs land with code (repo rule).

**Do not touch (owned by parallel tracks or out of scope):**
- NativeBackend.swift 8632–8900 (T8: level coalescing).
- PopoverController.swift outside ~993–1181; PopoverPanelViewController.swift; any row view; ConnectionDiagnosisView.swift (no edit needed — Copy Details enables itself once `detail` is populated on the model).
- MenuBarStatus / StatusItemController (menu-bar failure state is another track's finding).
- The Cast failure-construction sites (NativeBackend.swift 3375–3521, 3934) — they already produce specific causes and detail.
- GroupController / stores / About pane / license code / onboarding / capture coordinator internals.
- No new dependencies, no notifications, no refactors, no cleanup passes, no renames, no abstractions beyond what a step names, no error handling for impossible cases, no backwards-compat shims. If a step is impossible as written, STOP and report.

---

## Numbered edits (most load-bearing first)

### 1. `.vanished` one-token fix (hardening §1 P1)
`NativeBackend.swift:8187` (inside `merge(existing:discovered:)`, the sticky-AP2-offline branch whose comment reads "Sticky-AP2 device that went OFFLINE"):
```swift
result.connectionState = .failed(ConnectionFailure(cause: .unknown))
```
→ `cause: .vanished`. The copy for `.vanished` already exists at ConnectionState.swift:117 ("The speaker is no longer visible on the network. …") and describes exactly this case.
**Test update:** `NativeBackendTests.swift:3240` currently expects `.failed(ConnectionFailure(cause: .unknown))` on this path — change to `.vanished` (and its assertion message).
WHY: the most common household failure currently gets the least useful message in the app.

### 2. Map engine failure evidence onto existing causes + populate `detail` (hardening §1 P1 + §2 item 13)
Decision (Open decisions #1): map at the catch sites; do NOT port `NetworkConnectionDiagnostics`.

a) `NativeBackend.swift:8431-8433` — `enterFailure` gains a detail parameter:
```swift
private func enterFailure(_ id: String, cause: ConnectionFailure.Cause = .unknown, detail: String? = nil)
```
and passes it into the `ConnectionFailure`. Update its doc comment (8425–8430): the "every caller but one has no better guess than `.unknown`" sentence is now wrong — say the converge catch maps `passwordRequired → .authRequired` and `opTimedOut → .timedOut` and always carries the engine error as `detail`; still no `ConnectionDiagnosing` seam.

b) `NativeBackend.swift:6081-6087` — the `convergeDevice` add-throw catch. Today:
```swift
var cause: ConnectionFailure.Cause = .unknown
if case AirPlayEngineError.passwordRequired = error { cause = .authRequired }
```
Add one more mapping: `if case AirPlayEngineError.opTimedOut = error { cause = .timedOut }` (an armed op's completion never arrived within the bounded window — AirPlayTypes.swift:189 — which is exactly `.timedOut`'s copy "the connection attempt didn't complete"). Every other error keeps `.unknown`. Then pass `detail: String(describing: error)` into the `enterFailure` call at 6087. Do NOT map `.sessionFailed`/`.operationRejected` to anything else (Open decisions #1).

c) `NativeBackend.swift:7911-7931` — `applyEngineState`'s `.failed, .passwordRequired` arm. Line 7921 currently reads `eqNeedsReconcile = self.added.remove(id) != nil`. Capture that Bool first (`let wasStreaming = self.added.remove(id) != nil; eqNeedsReconcile = wasStreaming`), then in the `desiredOn` block replace the cause line (7929–7931) with:
- `.passwordRequired` → `.authRequired` (unchanged),
- else `wasStreaming ? .droppedMidStream : .unknown` (a live session dying out-of-band IS "was connected, silently dropped" — ConnectionState.swift:44),
and construct the failure with `detail: "engine state: \(state)"` (exact literal; `state` is the engine `OutputState`).

`detail != nil` is what enables Copy Details (`ConnectionDiagnosisView.swift:102`: `copyDetailsButton.isEnabled = failure.detail != nil`) — no UI edit needed.

**Test updates/additions (NativeBackendTests.swift):**
- `:3751` (`connectionStateAddFailureGoesFailed`, SpyEngine default `addFailureError = .sessionFailed`): keep `cause == .unknown` but reword the message (the "no diagnostics seam — always .unknown" claim) and ADD `#expect(failure.detail != nil, "the engine's raw error backs Copy Details")`.
- New test beside it: `engine.addFailureError = .opTimedOut` → cause `.timedOut`, detail non-nil. (SpyEngine already has the `addFailures`/`addFailureError` knobs, NativeBackendTests.swift:44-49.)
- New test: connect a device successfully (pattern of the connect-flow test ~:3700), then `engine.pushState(id, .failed)` → poll until `.failed`; expect cause `.droppedMidStream` and detail non-nil. (`pushState` exists at NativeBackendTests.swift:290.)
- The existing auth tests at :2800–2862 must stay green unchanged.

### 3. `BackendEvent.captureFailed` — capture failure gets a user-visible state (hardening §1 P1)
a) **OutputBackend.swift** (narrow exception 1): add as the LAST case of `BackendEvent` (after `takeoverStatus` at line 255):
```swift
case captureFailed(message: String?, retrying: Bool)
```
Doc comment: the whole-system capture tap failed (`NativeCaptureError.userMessage` is `message`); `retrying` says whether the T16 backoff retry is armed (`false` = permanent, e.g. `.osUnsupported`); `message: nil` clears the condition (capture recovered, or is no longer desired). Only `NativeBackend` emits it.

b) **NativeBackend.swift** — emission. Add `private var captureFailureNoteActive = false   // on stateQueue` near the other capture-retry state. In `handleCaptureCoordinatorStateChange` (:5026-5059):
- `.failed(let error)` arm: inside the existing `stateQueue.sync` block, and ONLY when `self.captureRunning` is true (a failure while capture isn't desired is noise), set `captureFailureNoteActive = true` and `self.emit(.captureFailed(message: error.userMessage, retrying: error.isRetryable))`. Note the current guard-else path (not running OR non-retryable) must still emit when `captureRunning && !error.isRetryable` — restructure the sync block so `captureRunning` and `error.isRetryable` are each read once and the emit decision covers both branches, while preserving the existing retry-scheduling and stale-timer-cancel behavior exactly. `emit` runs on `stateQueue` (:8853), so emitting inside the sync block is correct.
- `.capturing` arm: inside its `stateQueue.sync`, if `captureFailureNoteActive` { set it false; `self.emit(.captureFailed(message: nil, retrying: false))` }.
- `reconcileCaptureGate`'s stop branch (:8605-8621, the `else` that cancels `pendingCaptureRetry` — this sits BEFORE the forbidden 8632 boundary): same clear-if-active emit, so deselecting everything retires a stale failure note.

c) **AppDelegate.swift** (narrow exception 2): the exhaustive `apply(_:)` switch (:1522) gains:
```swift
case .captureFailed(let message, _):
    popoverController.setCaptureFailureMessage(message)
    log("event: \(describe(event))")
    return
```
and `describe(_:)` (:1693) gains a case rendering both fields, e.g. `"captureFailed(\(message ?? "cleared"), retrying: \(retrying))"`. The compiler will also demand a case in `mock-speakers-demo/main.swift`'s exhaustive `describe` switch (narrow exception 7) — add a one-line "handled so the switch stays exhaustive" case in that file's existing style. If the compiler flags any OTHER exhaustive switch, the fix is the same display-case shape; report it, don't improvise beyond that.

d) **PopoverController.swift** (narrow exception 3, note-slot region ~:993-1181 only):
- `private var captureFailureMessage: String?` + doc comment (highest-precedence note; renders `NativeCaptureError.userMessage` verbatim).
- `public func setCaptureFailureMessage(_ message: String?)` — idempotent guard (`guard message != captureFailureMessage else { return }`), assign, `applyNoteSlot()` — same shape as `setRoutingBlockedNeedsDefault` (:1043-1047).
- `resolvedSystemAirPlayNote` (:1113): NEW first branch, above routing-blocked:
```swift
if let captureFailureMessage {
    return (captureFailureMessage, nil, .warning)
}
```
No action button (Open decisions #2).
- Update the PRECEDENCE comment block (:996-1006) and the property's doc (:1105-1112): capture-failed (audio is dead while rows still say Connected) outranks routing-blocked, which outranks takeover, double-path, unregistered.
The existing rebuild-tail re-apply (:1475-1476 reads `resolvedSystemAirPlayNote`) restores the note on reopen for free — no extra wiring.

**Tests:**
- `PopoverControllerTests.swift`: new test modeled exactly on `routingBlockedWarningShowsOutranksTakeoverFiresReselectAndClears` (:2734): `setCaptureFailureMessage("…")` shows verbatim via `test_systemAirPlayNoteText`; with `setRoutingBlockedNeedsDefault(true)` also set, capture-failed still owns the slot; clearing it (nil) reveals the routing-blocked text; a repeated set is a no-op.
- `NativeBackendTests.swift`, in the existing "Whole-system capture retry (T16, E10)" section (:4183 ff., which already builds a backend with a `FakeCapture` and drives `capture.fireState(...)`): (i) select a device so `captureRunning` is true, fire `.failed(.tapCreationFailed(reason: "x"))` → collect a `.captureFailed` event with `message == NativeCaptureError.tapCreationFailed(reason: "x").userMessage` and `retrying == true`; (ii) fire `.capturing` → a `.captureFailed(message: nil, …)` clear event; (iii) fire `.failed(.osUnsupported(minimum: "14.2"))` → `retrying == false`; (iv) with nothing selected, `.failed` emits NO `.captureFailed` event.

WHY: today a dead tap means silence on every speaker while the UI says Connected, forever — the audit's worst "UI never lies" violation.

### 4. Bounded volume echo — revert the fader when the engine refuses the push (hardening §2 item 8)
All in NativeBackend.swift, outside the forbidden region.
- New `private var confirmedVolume: [String: Int] = [:]   // on stateQueue` — last UI-domain level per device id the engine actually acknowledged.
- Rework the push plumbing (:8320-8373) to carry identity and the UI level:
  - `private var volumePending: [OutputID: (engineValue: Double, id: String, uiLevel: Int?)] = [:]`
  - `private func pushVolume(_ outputID: OutputID, id: String, engineValue: Double, uiLevel: Int?)` — same in-flight/pending latest-wins coalescing, tuple stored in `volumePending`, and the chased pending push carries its own tuple.
  - `issueVolumePush` takes the same extra parameters and replaces the discarded-error engine call at :8363 with do/catch. On the `stateQueue.async` hop afterwards (both paths still run the existing chase/clear logic):
    - success + `uiLevel != nil` → `confirmedVolume[id] = uiLevel`.
    - throw + `uiLevel != nil` → revert ONLY when ALL hold: no superseding value queued in `volumePending[outputID]`, `!muted.contains(id)`, `known[id]?.volume == uiLevel` (the optimistic echo still shows the failed value — never clobber a newer user edit), and `let confirmed = confirmedVolume[id]`, `confirmed != uiLevel`. Then `applyLocal(id) { $0.volume = confirmed }` — the honest `deviceUpdated` snap-back.
- Update the six call sites with their `uiLevel`:
  - `:2415` (`setVolume` unmuted push) → `uiLevel: clamped`
  - `:2479` (mute's silence push) → `uiLevel: nil` (a failed mute push is outside this finding)
  - `:2508` (`setMasterGain` re-push loop) → `uiLevel: nil` (gain-only; the fader didn't move, so a failure must not move it)
  - `:8086` (`setSpeakerVolume`, the DACP knob path) → `uiLevel: stored`
  - `:8442` (`restoreEffectiveVolume`) → `uiLevel: intended`
  - `:8544` (connect seed while muted) → `uiLevel: nil`; `:8546` (seed unmuted) → `uiLevel: seed`
- Keep `pushVolume`'s doc honest: the "failures are non-fatal … swallowed" sentence (:8344-8345) now reads that a throw re-emits the last confirmed level so the fader never lies.

**Tests (NativeBackendTests.swift):** SpyEngine gains `var volumeFailures: Set<UInt64> = []`; its `setVolume` (:273-275) throws `AirPlayEngineError.sessionFailed` for those ids (still recording the call). New test: connect a device; `backend.setVolume(60, for: id)` succeeds (poll `volumeCalls`); set `volumeFailures = [outputID.rawValue]`; `backend.setVolume(25, for: id)`; poll until `backend.devices` shows the volume back at 60; also assert the event stream carried a `deviceUpdated` at 25 (optimistic echo) before the one at 60 (revert). Existing volume tests (e.g. the `waitForVolumeCall` helper :1353) must stay green.

WHY: the native backend has no poll loop by design (:8398-8406 — "the engine's completions and state-stream transitions ARE ground truth"), so a dropped write today leaves the fader lying with no bound and no correction.

### 5. Cast copy de-jargoned (hardening §1 P3)
`ConnectionState.swift:137` — replace the `.castAppUnavailable` suggestion string with EXACTLY:
```
This receiver can't play a stream from Audiout — some software receivers don't support it. Try a different Cast device.
```
Only the user-facing string changes; the case's developer-facing comment (:67-69) may keep the "Default Media Receiver" term. `DeviceCastKindTests` pins only the headline and the trailing-period rule, not this sentence — no test change expected; if one fails, update the pinned string and nothing else.

### 6. Honest "Speakers reconnected" (hardening §2 item 7)
a) **OutputBackend.swift:484-499** (narrow exception 1) — `LatencyConfigurable`:
```swift
@discardableResult
func applyStartBuffer(ms: Int) async -> (reconnected: Int, expected: Int)
```
Doc: `expected` = devices streaming when the apply began; `reconnected` = how many of those were re-established (the D4 best-effort re-add).
b) **NativeBackend.applyStartBuffer** (:6435-6506): `expected = streaming.count`; compute `reconnected` inside the FINAL `stateQueue.sync` (:6503-6505, where `bufferReAdding` is cleared): `streaming.filter { self.added.contains($0.id) }.count`; return the pair.
c) **MockBackend.swift:689-694** (narrow exception 5): read `let n = queue.sync { expectedSelected.count }` once at entry; after the existing sleep + store, return `(n, n)`.
d) **AudioSettingsViewController.swift** (narrow exception 4): `LatencySettingModel.apply` type becomes `@MainActor (Int) async -> (reconnected: Int, expected: Int)` (struct at :13-39, init included). In `applyBuffer` (:668-696): `let result = await latency.apply(target)`, and replace the label line (:686) with:
```swift
applyStatusLabel.stringValue = wasStreaming
    ? (result.reconnected == result.expected
        ? "Speakers reconnected"
        : "Some speakers didn't reconnect — check the mixer")
    : "Applied"
```
(exact strings, em dash).
e) **AppDelegate.makeLatencySettingModel** (:1336-1350, narrow exception 2): the closure returns `await configurable.applyStartBuffer(ms: ms)` (persist-first ordering unchanged — the comment at :1333-1334 stays true).
f) **settings-snapshot/main.swift:137** (narrow exception 6): `apply: { _ in (0, 0) }`.

**Tests:** `AudioSettingsLatencyTests.swift` — update every `apply:` closure to return a pair (`(1, 1)` on the happy paths so :74 "Speakers reconnected" still passes; `(0, 0)` for the inert ones). New test: streaming recorder + `apply` returning `(1, 2)` → `test_applyStatusText == "Some speakers didn't reconnect — check the mixer"`. `SettingsAccentAndHintsTests.swift` :173/:188/:207 — same mechanical closure updates.

### 7. Popover open path stops blocking on `stateQueue` for BT recency (performance P0-1)
`NativeBackend.swift`:
- New `private let btLastUsedLock = NSLock()` next to `btLastUsed` (:7618); re-annotate `btLastUsed`'s comment from `// on stateQueue` to `// btLastUsedLock`.
- `applyBTSnapshots` (:7648): wrap the write — `btLastUsedLock.withLock { btLastUsed[id] = snapshot.lastUsed }` (per-entry is fine; N is a handful of BT devices).
- `lastUsedDatesForBTDevices` (:7632-7634): `btLastUsedLock.withLock { btLastUsed }` instead of `stateQueue.sync { … }`; update its doc comment — this is the popover-open read (`deviceSections()` → `orderedBluetoothDevices` → `btLastUsedProvider`; PopoverController.swift:1673, AppDelegate.swift:565) and must never wait on `stateQueue`.
This mirrors the file's own sanctioned pattern (`btSyncTrim(forDevice:)` under `btTrimLock` at :9441, and the cached system volume at :2990-2993). Behavior identical; `NativeBackendBTDevicesTests.swift:165` pins the read and must stay green.

### 8. Sync drawer's range read stops blocking on the tap-rebuild queue (performance P1-2)
The audit suggested caching the range under `btTrimLock`; that suggestion is WRONG here and is overridden: `BTSyncedSink.usableTrimRangeMs` is documented "LIVE QUERY — do not cache the result … never memoize" (BTSyncedSink.swift:1489-1496) because the floor moves the instant an AirPlay device joins/leaves the composition, and `BTSyncedSinkTests.usableTrimRangeMs_movesLiveWhenAirPlayJoins` (:233) pins that. The sink itself is thread-safe (`@unchecked Sendable`, every table access under its own `tableLock` — BTSyncedSink.swift:1269-1273, 1500-1516); only the `btSink` PROPERTY is queue-confined. So remove the queue hop and keep the live query:
- New `private let btSinkRefLock = NSLock()` beside `btSink` (:274).
- The one write site — `applyBTSinkTransition` (:3741, `btSink = sink`; verified nothing ever nils it) — becomes `btSinkRefLock.withLock { btSink = sink }`.
- `btUsableTrimRangeMs` (:9608-9612): `let sink = btSinkRefLock.withLock { btSink }` then `return sink?.usableTrimRangeMs(forDeviceUID: id) ?? (-BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)` — no `captureControlQueue.sync`. Rewrite the doc comment (:9601-9607): the reference is read under `btSinkRefLock`; the sink's own `tableLock` makes the call safe off-queue; the answer stays a live query per the sink's contract. Every OTHER `btSink` touch stays on `captureControlQueue` unchanged.
- Add one sentence to the `BTSyncedSinkControlling` protocol's `usableTrimRangeMs` requirement (NativeBackend.swift:9946): may be called off `captureControlQueue`; implementations must be internally synchronized (the real sink is).
- `NativeBackendBTDevicesTests.swift:315-324` (`usableTrimRangeMsDefaultsToFullRangeWithNoBTSink`) pins the nil-sink default — keep green; update its doc comment's "captureControlQueue.sync hop" phrase.
Residual, accepted: when AirPlay is in the composition the sink's reference read still does one `stateQueue.sync` (`btReferenceDelayMs`, :6385-6389) — the multi-hundred-ms tap-rebuild queue is out of the path, which is the P1.

### 9. Docs ride the same commit
`AudioutCore/AGENTS.md`, the bullet at ~line 410 — currently:
> `NativeBackend` has no `ConnectionDiagnosing` seam — `.failed` cause is always `.unknown`. `MockBackend` mutation stays no-op-silent and confined to its private serial queue.

Rewrite the first sentence: NativeBackend still has no `ConnectionDiagnosing` seam, but `.failed` causes are mapped from the engine's own evidence — `.authRequired` (passwordRequired), `.timedOut` (opTimedOut), `.droppedMidStream` (a live session dying out-of-band), `.vanished` (the sticky-AP2 offline merge), `.timingUnavailable` (the PTP gate) — everything else stays `.unknown`, and every native failure carries `detail` so Copy Details works. Keep the MockBackend sentence verbatim. (Guard 2 checks symbol names in AGENTS.md — every symbol named above exists in source.)

---

## Tests — commands

Per the BINDING BUILD/TEST RULE in the header. Inner loop:
- Compile check: `bash scripts/build.sh`
- Scoped suites (the inner loop AND the final proof):
```
bash scripts/run-tests.sh --filter NativeBackendTests --filter NativeBackendBTDevicesTests --filter PopoverControllerTests --filter AudioSettingsLatencyTests --filter SettingsAccentAndHintsTests --filter ConnectionStateTests --filter MockBackendTests
```
**Pre-change baseline, personally observed on this exact command at `7886f98d`: `Test run with 459 tests in 10 suites passed after 52.116 seconds`, exit code 0.** After the change: same command, all suites pass, test count HIGHER than 459 (new tests from steps 1–6). Read the exit code directly — no pipes. Guard 4 runs the full suite at commit time and must pass; Guard 7 requires `scripts/self-review.sh` before any Swift commit — run it, keep its chatter out of your report.

New tests live in the EXISTING suites named per step (no new test files). Binding test conventions: swift-testing `@Suite`/`IsolatedSuite`, nothing a test does may reach the screen, never `UserDefaults(suiteName:)`.

## Acceptance checklist (verifiable from diff + test output)

- [ ] `merge(existing:discovered:)`'s sticky-AP2 branch produces `.vanished`; the test formerly at :3240 asserts it.
- [ ] `convergeDevice` catch maps `.opTimedOut → .timedOut` and passes `detail: String(describing: error)`; `applyEngineState` maps was-streaming `.failed → .droppedMidStream` with `detail: "engine state: \(state)"`; `enterFailure` has the `detail:` parameter; tests cover `.timedOut`, `.droppedMidStream`, and detail-non-nil on the `.sessionFailed` NACK.
- [ ] `BackendEvent.captureFailed(message:retrying:)` exists; NativeBackend emits it on `.failed`-while-desired (`retrying = isRetryable`), clears on `.capturing` and on the capture-gate stop edge, guarded by `captureFailureNoteActive`; AppDelegate `apply`/`describe` handle it; PopoverController renders it at `.warning`, top precedence, no action button; the precedence and emission tests pass.
- [ ] `issueVolumePush` uses do/catch; success records `confirmedVolume`; a throw reverts the optimistic echo under the four stated guards; SpyEngine has `volumeFailures`; the revert test passes; the six `pushVolume` call sites carry the specified `uiLevel` values.
- [ ] `ConnectionState.swift` carries the exact new Cast sentence.
- [ ] `applyStartBuffer` returns `(reconnected:, expected:)` from the protocol down; the Settings label shows exactly one of "Speakers reconnected" / "Some speakers didn't reconnect — check the mixer" / "Applied" per the rule; the mismatch test passes.
- [ ] `lastUsedDatesForBTDevices` and `btUsableTrimRangeMs` contain NO `stateQueue.sync` / `captureControlQueue.sync`; the two new locks exist; BT tests stay green; NO caching of the trim range anywhere.
- [ ] `AudioutCore/AGENTS.md` bullet updated in the same commit(s) as the code it describes.
- [ ] Zero edits inside NativeBackend.swift 8632–8900; zero edits in PopoverController.swift outside ~993–1181; zero edits to files not listed in the header.
- [ ] The filtered command above run in-session, output pasted, all pass, count > 459, exit 0 read directly.
- [ ] Branch pushed to `origin/claude/fix-backend-failures`. NOT merged.

## Open decisions (defaults the executor takes if unresolved)

1. **Cause mapping vs. porting `NetworkConnectionDiagnostics` to the native arm — DECIDED: map at the catch sites.** The diagnostics port is the bigger diff (a new seam on NativeBackend + an async replace-if-still-failed flow + episode-boundary interaction with the popover's edge rules + a Bonjour browse and TCP probe per failure), and its extra causes (`.notResponding`/`.refusedOrBusy`) require network probing the thrown engine error cannot provide. Grounded-evidence mapping only: `.sessionFailed`/`.operationRejected`/other engine errors stay `.unknown` (now with `detail`) — a plausible-but-wrong cause is worse than a vague one. Do not add the diagnostics seam.
2. **No action button on the capture-failure note.** The `userMessage` strings name the remedy in prose; wiring a System Settings deep-link into the popover is scope growth. Default: `action: nil`.
3. **`retrying:` rides the event but the popover ignores it** — it exists for the stderr `describe` line (distinguishes self-healing from permanent in a log a user might send). Default: keep the flag, render only `message`.
4. **Volume revert scope:** unmuted pushes with a known confirmed level only; mute / master-gain / seed-while-muted pushes pass `uiLevel: nil` and never revert or confirm. Default as written in step 4.
5. **`.osUnsupported` note lifecycle:** no retry is armed, so it clears only via the capture-gate stop edge or process restart — correct, the condition is permanent. Default: no extra handling.

## Executor rules (verbatim)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a cited fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
