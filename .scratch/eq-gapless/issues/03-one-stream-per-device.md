# 03 — One permanent whole-system stream per AirPlay speaker (Track C), or Track A

Status: Track C built + reviewed APPROVE at 33edbfc4 (251 NativeBackend tests); PR open; live check owed
Blocked by: 02
Worktree: this one (`claude/equalizer-latency-optimization-d714da`)

Gate: ticket 02's `ENCODE_BENCH` line. `rtf <= 0.25` → build **Track C** below.
Otherwise build **Track A** (bottom) and stop.

All file:line anchors are as of commit 2ea27de2; re-grep before editing.

## Track C — every AirPlay speaker owns a stream from connect to disconnect

An EQ edit then changes coefficients only, never topology. `EQStreamTopology`,
`EQStreamAllocator`, the reconcile diff, deferred rebinds and the budget-by-curve
machinery all go.

### NativeBackend.swift

1. State (replace `eqAllocator`, `eqStreamIDByDevice`, `eqRebindDeferred` at `:569-582`):
   - `private var wholeSystemStreamByDevice: [String: UInt32] = [:]   // on stateQueue`
     — the stream a device's whole-system session is bound to for the life of the
     engine session. `0` means "shares the flat stream 0" (over budget only).
   - `private var nextWholeSystemStreamID: UInt32 = 0x8000_0000` — monotonic, never
     reused (keeps decision 8 and the id-space split: per-app ids from 1 upward,
     `AppRouteMixer.nextStreamID`; whole-system ids in the top half, so the range test
     at `eqBudgetLocked` `:3437` keeps telling them apart).
   - Keep `eqByDeviceID`, `storedMainOutEQ`, `eqSlotByStream`, `mainOutEQSlot`.
2. `private func connectTargetStreamLocked(_ id: String) -> UInt32` — on `stateQueue`.
   Returns `wholeSystemStreamByDevice[id]` if present. Otherwise allocates: budget =
   `engineStreamCapacity − 1 − perAppStreams.count − (number of ids in
   wholeSystemStreamByDevice whose value != 0)`; if `budget > 0` take
   `nextWholeSystemStreamID`, bump it, store and return it; else store and return `0`.
   A device that got `0` keeps `0` until it disconnects (`removeFromAddedLocked`
   drops its entry, see 6) — no re-homing on a neighbour's departure, by design.
3. Route every whole-system session-establishing op to the home stream:
   - `convergeDevice` `:7104` `bindOutput(outputID, toStream: 0)` →
     `toStream: stateQueue.sync { connectTargetStreamLocked(id) }` (read it under the
     lock right before the op, exactly where the `0` was).
   - `performRebindRecovery` verify-first `:5859-5867`: `home` from the same call;
     `guard let live, live != home`; `rebindOutput(outputID, toStreamId: home)`.
   - `session_reset` telemetry `:5583` `"stream": "0"` → the home stream.
   - grep `toStream: 0`, `toStreamId: 0`, `addOutput(outputID)` (the legacy
     single-arg add) in this file and route each whole-system one the same way;
     `bindOutput`'s own `if streamId == 0 { addOutput(id) } else { addOutput(id, streamId:) }`
     stays as the single switch.
4. `setEQ` `:3279-3305`: keep the guard, store, `applyLocal`, save-on-commit, the BT
   branch. Then just `pushEQPlanLocked()`. Delete `eqEditIsExpressibleLocked` and the
   `commit || …` branch; the doc comment loses "decision 9 … accepted ~1 s gap".
5. `reconcileEQPlan()` `:3350-3405` shrinks to: recompute `eqBypassReason` per known
   device (`.perAppRouting` when `streamBindings[id] != nil && !eq.isFlat`;
   `.streamBudget` when `wholeSystemStreamByDevice[id] == 0 && !eq.isFlat`; else nil,
   via `applyLocal`), then `pushEQPlanLocked()`. Keep the name and every existing
   call site (both `added` edges, `setOutputSet`, per-app destination changes,
   `stop()`), since they are exactly the moments the plan's device set changes.
6. `removeFromAddedLocked` `:3418-3422`: also `wholeSystemStreamByDevice.removeValue(forKey: id)`
   so a reconnect re-homes fresh and a freed slot returns to the budget. Do the same
   in the `applyEngineState` `.failed/.passwordRequired` arm where `added.remove(id)`
   happens (`:9322`) if it does not already go through `removeFromAddedLocked`.
7. `pushEQPlanLocked()` `:3455-3475`: build `eqByStream` from
   `added.filter { streamBindings[$0] == nil }` → for each, `stream = wholeSystemStreamByDevice[id] ?? 0`,
   skip `stream == 0`, `eqByStream[stream] = eqByDeviceID[id] ?? .flat`. Everything
   below that line stays: slots for departed streams dropped, stream 0 entry first,
   `processor(reusing:for:)` returns `nil` for flat (passthrough copy on its own
   stream — the flat invariant holds because `EQProcessor` is never run) and
   retargets a live one otherwise.
8. Delete `enqueueEQRebindLocked` `:3500-3570`, `eqBudgetLocked` `:3436-3439` (fold the
   per-app count into step 2), the deferred re-drive at `:7010-7012`, and the
   `eqStreamIDByDevice`/`eqRebindDeferred` clears at `:2702-2703` and `:7852-7853`
   (`eqSlotByStream`/`mainOutEQSlot`/passthrough clears stay in both places;
   `stop()` `:2697` additionally clears `wholeSystemStreamByDevice` — sleep does NOT,
   the wake re-add must land on the same stream).
9. `rebindConverging` keeps its recovery-chain users; only the EQ rebind's insert/
   remove go.

### DeviceEQ.swift

Delete `EQStreamAllocator` and `EQStreamTopology` (`:98-215`). Grep the repo for both
names; the only production user is `NativeBackend`. Keep `DeviceEQ` itself untouched.

### Device.swift / EQEditorView.swift

- `EQBypassReason.streamBudget` doc `:89-91`: "more whole-system speakers than the
  engine has streams for, so this one shares the flat stream".
- `EQEditorView.bypassNoteText(.streamBudget)` `:71`: "Not applied. Too many speakers
  are streaming at once for this one to get its own EQ." Grep tests for the old
  sentence and update the one assertion that quotes it.

### Tests (`NativeBackendTests.swift`, `EQStreamTopologyTests.swift`)

- Delete `EQStreamTopologyTests.swift` (the type is gone).
- `nonFlatCommitRebindsOntoAnEQStreamAndFlatReturnsToZero` `:9397` → rename
  `aConnectBindsStraightToTheDevicesOwnStreamAndAnEditNeverRebinds`: after
  `startSelectAndStream`, `liveStream >= 0x8000_0000` immediately (no `setEQ` yet);
  `setEQ(treble 3, commit: true)` then `setEQ(.flat, commit: true)` → `liveStream`
  unchanged and `engine.rebindCalls.isEmpty`. Defect: any path that still moves a
  live session for an EQ value.
- `budgetExhaustionBypassesTheDeterministicLoserWithoutBinding` `:9437` → build
  `engineStreamCapacity` devices; the LAST to connect lands on stream 0 with
  `.streamBudget` (the loser is now the last one to bind, not the largest id — select
  them one `setOutputSet` at a time so the order is deterministic); assert stored
  values survive and no rebind was issued for it.
- `aDepartureUnbypassesTheBudgetLoserAndTakesItsOwnStreamOutOfThePlan` `:9490` →
  keep only the second half: after a departure, `capture.eqPlans.last` no longer
  carries the departed device's stream. Rename accordingly.
- `aScrubOnOneDeviceKeepsEveryOtherStreamsProcessorInstance` `:9549` and
  `aScrubOnTheEditedDeviceKeepsItsOwnProcessorInstance` `:9603`: keep; adjust any
  `>= EQStreamAllocator.idBase` polls to `>= 0x8000_0000` (add a file-local constant).
- `anUncommittedEditOnANonStreamingDevicePublishesNoPlan` `:9656`: keep — a device
  not in `added` has no stream, so `pushEQPlanLocked` publishes the same plan; if the
  assertion counted plan pushes, relax it to "the plan carries no stream for it".
- `perAppRoutingBypassesTheStoredEQAndUnroutingRestoresIt` `:9687`: keep; unrouting
  returns the device to its home stream (not 0) — update the expected stream.
- `aSleepWakeCycleRebindsTheEQdSpeakerBackOntoItsStream` `:9721` → rename
  `aSleepWakeCycleReAddsTheSpeakerOntoItsOwnStreamWithoutARebind`: after wake
  `liveStream == the pre-sleep stream` and `rebindCalls.count == rebindsBeforeSleep`.
- Add `aStoredCurveCostsOneSessionOnConnect`: device with a saved `DeviceEQ(bassDB: 4)`
  (commit before selecting, or via `DeviceEQStore`), select it; assert exactly one
  `add:` op in `engine.opLog` for it and `rebindCalls.isEmpty`; `capture.eqPlans.last`
  carries its stream with a processor. Defect: the double session on connect.
- Run: `bash scripts/run-tests.sh --filter NativeBackendTests` (expect the count to
  drop by the deleted tests and rise by the added ones — read the `Test run with N`
  line), `--filter EQProcessorTests`, and then the full `bash scripts/run-tests.sh`.

### Docs

`AudioutCore/Sources/AudioutCore/AGENTS.md:14-15` become:
- Every AirPlay speaker binds to its own whole-system stream at connect
  (`connectTargetStreamLocked`); an EQ edit retargets that stream's processor and
  never moves a session, because a rebind costs the receiver's ~2 s lead.
- Over budget, a speaker shares stream 0 and streams flat, and says so through
  `eqBypassReason`.
Move nothing else; the old paragraphs are already in AGENTS-HISTORY.md. Update the
`Map` line for `DeviceEQ.swift` if it names the deleted types. Roadmap 056's
`what` is superseded by this ticket; leave the JSONL to the closer.

## Track A — fallback if the encode gate fails

Keep the topology machinery and remove the two commonest gaps only:

- A1 bind-at-connect: steps 2 and 3 above, but `connectTargetStreamLocked` returns
  `eqStreamIDByDevice[id] ?? 0` after running `EQStreamTopology.resolve` for the
  would-be active set including `id` (so a saved curve binds straight to its group's
  stream and `reconcileEQPlan` on the `added` edge finds `previous == stream`, no
  rebind).
- A2 lone-device stream 0: in `EQStreamTopology.resolve`, a non-flat group whose
  member is the ONLY active device gets stream 0 (entry `streamID: 0, eq: group.key`);
  `eqEditIsExpressibleLocked` drops the `stream != 0` guard and instead answers true
  when `id` is the only device in `eqStreamIDByDevice`; `pushEQPlanLocked` allows a
  processor on the stream 0 entry (the flat invariant still holds: flat → `nil`).
- Tests: `aConnectBindsStraightToTheDevicesOwnStream…` and
  `aStoredCurveCostsOneSessionOnConnect` as above; add
  `aLoneSpeakerShapesStreamZeroInPlace` (single device, `setEQ` non-flat → no rebind,
  plan's stream 0 entry has a processor); keep `EQStreamTopologyTests` and add the
  lone-device rule to it.
- Same AGENTS.md update, worded for what was built.

## Comments

- 2026-09-15 review (Fable, adversarial, three passes): APPROVE at 33edbfc4. Known, accepted: a
  converge that exits through the `failedGate` guard while a deselect lands between its last
  snapshot and its `defer` releases no home; one budget slot is over-counted for that speaker
  until it is reselected (then reused). Closure if ever needed: release in
  `releaseConvergingAndRequeueIfNeeded`'s no-requeue branch when `desiredOn[id] != true &&
  !added.contains(id)`.
