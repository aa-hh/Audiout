# Roadmap 008 research — scope exclusivity + cross-FIFO ordering in NativeBackend

Research pass for the routing-arbiter work (roadmap 008), 2026-08-05.
Base: branch `claude/routing-arbiter-008` off `main@fa73edd6`. All line numbers
cite the code AS OF THIS COMMIT — NativeBackend.swift is the most-churned file
in the repo, so re-verify lines before acting on them. Docs orient, code decides.

T7's own residual statement (git show `86b02b7`): *"scope exclusivity is still
enforced only in GroupController, not NativeBackend; and ordering between the
two FIFOs across an in-flight transition (not within one) is still
unarbitrated."* This document maps exactly those two residuals against the
current code.

All paths below are relative to the repo root; the main file is
`AudiouterCore/Sources/AudiouterCore/NativeBackend.swift` (6165 lines),
abbreviated **NB**.

---

## 1. The two serialization domains

Both are *decided* under the one state lock, `stateQueue`
(`DispatchQueue(label: "NativeBackend.state")`, NB:277), but *execute* as
independent unstructured Tasks. A third serial queue, `captureControlQueue`
(NB:406), carries capture-tap work only (never engine session ops) and is not
one of the two FIFOs at issue.

### 1a. "converging" — the whole-system (stream 0) domain

Not a Task chain at all: a **per-device in-flight slot + coalescing target**,
chased by detached per-device loops.

- `private var desiredOn: [String: Bool]` — latest desired on/off per device
  (NB:532).
- `private var converging: Set<String> = []` — "a converge op is in flight for
  this id; at most one per id" (NB:537).
- Enqueue: `setOutputSet(_:)` (NB:1742) claims the slot under `stateQueue.sync`
  (`self.converging.insert(id)`, NB:1817) and then spawns
  `Task { await self.convergeDevice(id:outputID:) }` per kicked device
  (NB:1908-1913). Additional claim sites: discovery recovery in `addOrUpdate`
  (NB:4674-4678), toggle-off-raced-good-transition in `applyEngineState`
  (NB:4834-4835), `handleSystemDidWake` re-kick (NB grep `!converging.contains`),
  `convergeToTarget` (NB:4110-4128, used by `applyStartBuffer`), and — crucially —
  `resetAirPlaySessionForWholeSystem` (NB:2579-2586, see §1c).
- Run: `convergeDevice(id:outputID:)` (NB:3665) loops: snapshot the coalesced
  target under `stateQueue.sync`, issue ONE engine op, write bookkeeping
  (`added` insert/remove) under `stateQueue.sync` *after* op success, repeat.
  Release + requeue is atomic under `stateQueue`
  (`releaseConvergingAndRequeueIfNeeded`, NB:3649-3663, called from the defer at
  NB:3666-3677).
- Serialization guarantee: at most one engine op in flight **per device**, but
  loops for different devices run concurrently, and nothing orders this domain
  against `bindTail`.

### 1b. "bindTail" — the per-app (stream >= 1) domain

A single **global Task chain FIFO** across all devices:

```swift
/// FIFO chain that serializes the per-app engine bind ops. ...
private var bindTail: Task<Void, Never> = Task {}          // NB:678
```

- Enqueue: `enqueueBindOps(_ ops: [StreamBindOp])` (NB:3370-3379), called on
  `stateQueue` from `handleDestinationSetsChanged` (NB:3355):

  ```swift
  for op in ops {
      let prev = self.bindTail
      self.bindTail = Task { [weak self] in
          await prev.value
          await self?.performBindOp(op)
      }
  }
  ```

- Ops: `enum StreamBindOp { case bind(OutputID, UInt32); case rebind(OutputID,
  UInt32); case unbind(OutputID) }` (NB:3162-3166), executed by
  `performBindOp(_:)` (NB:3389): PTP takeover gate, then
  `bindOutput(outputID, toStream: stream)` (bind/rebind) or a bare
  `engine.removeOutput` (unbind, NB:3425).
- Reset: `stop()` cancels the chain and replaces it (`bindTail.cancel();
  bindTail = Task {}`, NB:1529-1530) and clears `streamBindings`.
- Serialization guarantee: per-app ops never overlap **each other** (global
  FIFO, submission order = decision order under `stateQueue`); nothing orders
  it against `converging` loops.

### 1c. The one cross-link that already exists

`enqueueRebindRecovery` (NB:2659) — the shared whole-system/per-app session
reset chain — **chains onto `bindTail`** (NB:2675-2676) even for
`.wholeSystem` scope, *while also holding the device's `converging` slot*
(claimed in `resetAirPlaySessionForWholeSystem`, NB:2579-2586, tracked in
`rebindConverging`, released only at every terminal exit via
`releaseRebindConverging`, NB:2644-2647). So the whole-system *recovery* path
is already dual-domain: it blocks converge via the slot AND rides the per-app
FIFO. Its backoff retry re-enters `enqueueRebindRecovery` from a
`DispatchQueue.global().asyncAfter` work item (NB:2750-2806), which appends to
whatever `bindTail` is *at that later time* — per-app ops enqueued during the
backoff window run **between** recovery attempts while `converging` is still
held (converge is blocked; per-app ops are not).

Comment-anchor note: this design is `// Finding 1` (NB:2567-2578) — the
recovery used to be an independent third domain and was folded onto the
`converging` slot precisely because "the two used to be independent
serialization domains touching the same OutputID".

---

## 2. Every scope-transition path

The shared choke point both domains call is `bindOutput(_:toStream:
tearDownWhenBindingUnknown:)` (NB:3475-3495) — "THE single call site that puts
a device's engine session onto a stream" (doc comment NB:3442-3474). It reads
`engine.boundStreamId(for:)`; if a live session exists on a different stream
it calls `engine.rebindOutput(_:toStreamId:)`; if no live binding, it falls to
plain `addOutput` (stream 0 → `addOutput(_:)`, else `addOutput(_:streamId:)`).
(There is **no** function named `ensureOutputOnStream` on this branch — that
name in the roadmap brief corresponds to `bindOutput`.)

Engine side (`AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift`):
`boundStreamId(for:)` (AE:815) reads the live C `device->stream_id`+state;
`rebindOutput` (AE:838) holds the per-`OutputID` `opsInFlight` slot (AE:184,
acquire/release AE:1576-1587) across both the stop and re-add; `bind(_:streamId:
serialize:)` (AE:849) answers an already-live session with
`.alreadyBound` **without moving it** (AE:869-881) — the silent no-op that
defines defect B.

### Path A — whole-system claim: `setOutputSet` → `convergeDevice`

- Initiator: `GroupController.applyRouting()` (GroupController.swift:450-469,
  `.selectedDevices` branch → `backend.setOutputSet(routableOutputIDs)` at
  :462) or `activateGroup(id:)` (:643 `backend.setOutputSet(airplayMembers)`).
- Domain/FIFO: claims `converging[id]`; runs on a detached converge Task.
- Reads: `desiredOn`, `added`, `failedGate`, `lastDescriptors` (all under
  `stateQueue`); engine truth via `boundStreamId` inside `bindOutput(_, 0)`
  (NB:3730).
- Writes: `expectedSelected` (NB:1758), `desiredOn`, `userConnectSeed`,
  connectionState eagerly (NB:1810); on op success `added.insert(id)` +
  volume seed + `.connected` (NB:3732-3776); on failure `failedGate` park
  (NB:3782-3787).
- Note the T7 comment at the call site (NB:3722-3729): converge deliberately
  goes through `bindOutput` because the device may be live on a stream >= 1
  "bound by the `bindTail` FIFO this loop knows nothing about".

### Path B — per-app claim: `updateAppRoutes` → mixer topology → `handleDestinationSetsChanged` → `enqueueBindOps`

- Initiator: `AppRoutingController.onRoutesDidChange` →
  `AppDelegate.pushAppRoutesToBackend` → `NativeBackend.updateAppRoutes`
  (NB:2132). Inside: route diff under `stateQueue.sync` (NB:2136-2230), then —
  **off the lock, synchronously** — `routeMixer.updateRoutes(plan.mixerRoutes)`
  (NB:2239), which fires `onDestinationSetsChanged` iff topology changed
  (AppRouteMixer.swift:252) → `handleDestinationSetsChanged` (NB:3282), which
  re-enters `stateQueue.sync`, diffs `streamBindings` vs the new sets, and
  enqueues `.bind`/`.rebind`/`.unbind` ops on `bindTail` (NB:3323-3355).
- Reads: `streamBindings`, `outputIDs`, `known` (AP1 filter NB:3314).
- Writes: `streamBindings = newBindings` (NB:3354) — **before the ops run**
  (intent-ahead-of-engine), unlike `added`, which is written only on op
  success. `lastDestinationSets` cache (NB:3287). `.routedApps` UI events.
- Failure walk-back: `handleBindFailure` (NB:3515) clears `routedAppNames`
  and (PTP-refusal only) the `streamBindings` slot.

### Path C — per-app release: same pipeline, `.unbind`

A device leaving all per-app destination sets gets `ops.append(.unbind(...))`
(NB:3345) → `performBindOp` calls `try? await engine.removeOutput(outputID)`
(NB:3425). **It never touches `added`, `desiredOn`, or `converging`** — correct
under the exclusivity assumption, undefined without it (see §3).

### Path D — re-drive/replay paths (per-app, all funnel into Path B's tail)

- Discovery re-drive: `addOrUpdate` re-runs the binding pass for a target
  discovered after the routes were applied (NB:4681-4699 area; cache
  `lastDestinationSets`, NB:640-647).
- Clock recovery replay: `replayPerAppBindingsAfterClockRecovery` (NB:3601)
  re-calls `handleDestinationSetsChanged(lastDestinationSets)`.

### Path E — session resets (both scopes) → `enqueueRebindRecovery`

- Per-app: `resetAirPlaySessionForRoutedApp(bundleID:)` (NB:2515) — per-app tap
  rebuilt with unchanged topology; finds every device bound to that stream and
  starts a recovery chain (`scope: .perApp(stream:)`), gen-bumped, on `bindTail`.
- Whole-system: `resetAirPlaySessionForWholeSystem()` (NB:2563) — whole-system
  tap rebuilt on a device/rate change; iterates `added`, claims `converging`
  (bows out with `whole_system_rebind_skipped` if a converge is running,
  NB:2579-2584), starts `scope: .wholeSystem` chains on `bindTail`.
- Ownership guard: `stillOwnsRebind(deviceID:scope:)` (NB:2625-2630) —
  per-app: `streamBindings[deviceID] == stream`; whole-system:
  `added.contains(deviceID)`. The chains share `rebindRecoveryGen` /
  `pendingRebindRecoveries` keyed by deviceID, **explicitly justified by the
  exclusivity assumption**: "a device is either whole-system or per-app, never
  both, so one recovery chain per device is exactly right" (NB:2557-2559).

### Path F — exclusion changes

`updateAppRoutes(_:excludedBundleIDs:)` → `captureCoordinator.updateRouting`
on `captureControlQueue` (NB:2299-2301). Tap-only; issues **no engine session
ops** and never crosses the two FIFOs. Relevant to 008 only insofar as an
`.exclusionChange` tap rebuild can escalate into Path E's whole-system reset
when the tap comes back on a different device/rate (`AudiouterCore/AGENTS.md`,
R10 rule).

---

## 3. Scope exclusivity today — UI layer only

**The invariant**: {Main Out members} ∩ {per-app `.device` redirect targets}
= ∅ — "one role per speaker". Maintained by three cooperating UI/coordinator
pieces, none inside NativeBackend:

1. **Senior-action clear** — `GroupController.applyRouting()` /
   `activateGroup(id:)` call `onMainOutMembersChanged?(members)`
   (GroupController.swift:465, :646) **after** `backend.setOutputSet(...)`.
   `AppDelegate` wires it (AppDelegate.swift:410-412) to
   `AppRoutingController.clearRoutes(toDevices:)`
   (AppRoutingController.swift:218-229), which reverts every `.device` route
   targeting a new member to `.noRedirect` and fires `onRoutesDidChange` →
   `updateAppRoutes` (tearing down the per-app claim via Path C).
2. **Menu filter (mirror direction)** — `PopoverController` drops Main Out
   members from every app row's redirect menu (`lastMainOutMemberIDs`,
   PopoverController.swift:367-376; "a Main Out member is never offered as a
   redirect target", AppDelegate.swift:407-409). So the redirect→member
   direction is *prevented*, the member→redirect direction is *healed*.
3. The rationale is written in `clearRoutes`' doc comment
   (AppRoutingController.swift:201-211): "a speaker can carry only ONE role at
   a time … the AirPlay engine holds one session per receiver, and a second
   bind is a silent no-op."

**NativeBackend has no arbiter.** Nothing in `setOutputSet` checks
`streamBindings`; nothing in `handleDestinationSetsChanged` checks
`added`/`desiredOn`/`expectedSelected`. The two bookkeeping maps never
cross-invalidate (T7 commit message says exactly this).

### Walking an actual double-claim

Suppose both domains claim device D (stale UI, a race, or any future caller):

- **Ordering within the sanctioned flow is itself a transient double-claim**:
  `applyRouting` calls `setOutputSet` FIRST (converge toward stream 0 kicked,
  `desiredOn[D]=true`) and only THEN fires the clear → `updateAppRoutes` →
  `.unbind` op. Until the unbind runs, `streamBindings[D]=N` and
  `desiredOn[D]=true` coexist, and the converge Task and the unbind op race
  through the engine.
- **If converge's `bindOutput(D, 0)` runs first**: `boundStreamId` returns N,
  `rebindOutput` moves D to stream 0, `added.insert(D)`. Then the `.unbind`
  op runs `engine.removeOutput(D)` — tearing down the *stream-0* session the
  user just asked for. Path C touches no whole-system bookkeeping, so `added`
  still contains D and the device row shows `.connected` while silent. Recovery
  is only *incidental*: the engine's out-of-band state stream may emit
  `.stopped`, and `applyEngineState`'s handling plus a later re-kick may
  restore it — undefined, order-dependent behavior, exactly the 008 gap.
- **If the `.unbind` runs first**: benign — converge then binds fresh to 0.
- **Both in flight concurrently**: see §4 TOCTOU.
- **Steady-state double-claim** (both maps hold D long-term): every
  whole-system tap rebuild (`resetAirPlaySessionForWholeSystem`) and every
  per-app tap rebuild (`resetAirPlaySessionForRoutedApp`) would fight over the
  single shared `rebindRecoveryGen[D]` chain, each gen-bump superseding the
  other's recovery; whichever reset fires last rebinds D to *its* stream and
  the other domain's audio goes to a stream D no longer joins. Both writers
  keep writing (`EngineSink` → stream 0; mixer → `write(pcm:streamId:N)`),
  one of them into the void.

---

## 4. What an in-flight transition looks like — suspension points and interleavings

A transition is "in flight" from the moment its FIFO claims it (converge:
`converging.insert(id)` under `stateQueue`; bindTail: op Task appended) until
its post-op bookkeeping commits. All engine calls are `await`s off the lock,
so the other domain is free to run at every one of them.

**Suspension points while `converging[id]` is held** (`convergeDevice`):
1. `engine.updateDiscovery(descriptor)` (NB:3698)
2. `ensurePTPTakeover` (NB:3707) — can take *seconds* (helper wake + bounded
   clock wait, NB:3569+); widest window in the file
3. inside `bindOutput(_, 0)`: `engine.boundStreamId(for:)` (NB:3478) — then a
   **gap** — then `engine.rebindOutput` (NB:3483) or `engine.addOutput`
   (NB:3491)
4. desired-off arm: `engine.removeOutput` (NB:3792)

**Suspension points per bindTail op** (`performBindOp`):
1. `await prev.value` (NB:3375) — the op waits behind the whole chain,
   including any in-progress whole-system recovery attempt
2. `ensurePTPTakeover` (NB:3398/3411)
3. the same `boundStreamId` → op gap inside `bindOutput(_, N)`
4. `.unbind`: `engine.removeOutput` (NB:3425)

**Concrete interleavings possible today** (same device D; the engine's
per-output `opsInFlight` slot serializes each *single* op but not the
read-then-act sequence, and nothing orders the two FIFOs):

- **I1 — TOCTOU double-read, both see "no live session"**: converge and a
  `.bind` op both call `boundStreamId` before either issues its add → both get
  `nil` → converge issues `addOutput(D)` (stream 0), bindTail issues
  `addOutput(D, streamId: N)`. The engine serializes them; the **second is a
  silent `.alreadyBound` no-op** (AE:869-881) that does NOT move the session.
  Result: defect B resurrected in the concurrent case — one domain's
  bookkeeping records a binding the engine never made. T7 fixed the
  *sequential* case only.
- **I2 — TOCTOU double-read, both see the same live stream**: both read
  live=0; converge no-ops ("already owns", NB:3479); bindTail rebinds to N.
  Fine sequentially — but the mirrored order (read live=N: converge rebinds
  to 0, bindTail no-ops) means the **last op to reach the engine wins** and
  the other domain's maps (`added` vs `streamBindings`) go stale with no
  cross-invalidation.
- **I3 — remove-vs-bind**: converge's desired-off `removeOutput` lands inside
  bindTail's `boundStreamId`→`rebindOutput` gap. `rebindOutput` tolerates the
  missing session (stop half no-ops, add half binds fresh, AE:836-846) — OK if
  per-app still wants D, but if the `.unbind` for D is *behind* the rebind in
  the chain the session is resurrected then killed; transiently undefined.
- **I4 — unbind-vs-converge-add**: the §3 walk — `.unbind`'s `removeOutput`
  lands after converge's successful stream-0 add; live session destroyed while
  `added` still claims it.
- **I5 — recovery-window interleave**: a whole-system recovery holds
  `converging[D]` across its backoff (`return nil // still in progress — keep
  the converging slot held`, NB:2807), but per-app ops enqueued during the
  backoff run in between attempts (§1c). A `.bind(D, N)` landing there moves D
  to stream N; the retry then fires, passes `stillOwnsRebind` (D still in
  `added` — nothing removed it), and re-adds D to stream 0 via
  `performRebindRecovery` — yanking the per-app claim back. Ping-pong, decided
  by timers.
- **I6 — PTP-gate stall inversion**: converge blocks seconds in
  `ensurePTPTakeover` while holding `converging[D]`; a full per-app
  bind/unbind cycle completes inside the window; converge resumes with a
  decision snapshot from before the world changed (its `bindOutput` re-reads
  engine truth — the *stream* is re-checked, but `desiredOn`/`added` etc. were
  read a window earlier).

Within-one-FIFO ordering is sound (that was T7 + Finding 1); every defect
above needs both FIFOs live at once.

---

## 5. Test seams for a hermetic cross-FIFO race suite

All in `AudiouterCore/Tests/AudiouterCoreTests/NativeBackendTests.swift`
(nested in `SerializedSharedState` for Telemetry-sink mutual exclusion, :22):

- **`SpyEngine: EngineControlling`** (:66) — the key double:
  - `liveStreams: [UInt64: UInt32]` (:148) faithfully models the vendored
    `device->stream_id` **including the silent `.alreadyBound` no-op**
    (`addOutput` only writes `liveStreams` if absent, :162, :232-234) — so
    cross-FIFO defects are genuinely reproducible offline.
  - `opDelayNanos` (:110) — artificial per-op latency via `runOp` (:264-274),
    purpose-built "to force slow op completions to race fast toggle flips";
    the direct tool for holding one FIFO's op open while the other runs.
  - `onAddOutputBody` hook (:105) — deterministic mid-op injection ("in the
    window between addOutput resolving and NativeBackend's post-success
    write"); a race test can trigger the *other* FIFO from inside an op.
  - `maxConcurrentPerDevice` (:117-118) — asserts per-device op overlap == 1.
  - `rebindCalls` (:153), `streamAddCalls`, `opLog` (interleaved op order,
    :84), `pushState` (out-of-band engine transitions, :294), `addFailures`/
    `removeFailures`/`flushFailures`/`flushNoOps` failure injection.
- **`FakeDiscovery`** (:329) — synchronous `DiscoveryEvent` feed; fake
  `DACPEndpoint` (:338) — zero sockets.
- **`workingPerAppCapture(bundleIDs:)`** (used at :4527) — a
  `PerAppCaptureCoordinator` double that reaches `.capturing` so
  `updateAppRoutes` drives the real mixer→bindTail pipeline hermetically.
- **Backend-side test seams** (NB): `test_isConverging` (NB:4163 — "isEmpty"
  only; a per-device variant may be worth adding), `test_expectedSelected`
  (NB:4145), `test_hasPendingRebindRecovery(deviceID:)` (NB:828),
  `test_hasPendingRetry` (NB:820).
- **Direct precedent**: the two T7 tests, `deviceMovingFromWholeSystemToPerApp
  RebindsTheLiveSession` (:4525) and `deviceMovingFromPerAppToWholeSystem
  RebindsTheLiveSession` (:4556) — `pollUntil { engine.liveStream(of:) == … }`
  pattern, `route(_:name:toDevice:)` + `ap2Device()` + `startAndDiscover`
  helpers. A 008 race test is these two tests with the second trigger fired
  *inside* the first's window (via `opDelayNanos` or `onAddOutputBody`) instead
  of after it settles.
- **Telemetry assertions**: `Telemetry._installTestSink` via the suite's
  `airplayLines(evt:)` helper (e.g. :5984) — `engine_scope_rebind`,
  `whole_system_rebind_skipped`, `bind_failed`, `rebind` outcome trails are
  all already emitted at the decision points an arbiter would live at.

---

## 6. Branch/file-contention risks (checked 2026-08-05, `git branch -a`)

Unmerged branches with commits beyond `main@fa73edd6` touching this surface:

| Branch | Contention |
|---|---|
| `claude/aggregate-device-wave3` | **5 commits touch NativeBackend.swift** + 2 on GroupController/AppRouting/engine surface. Live-verified, merge pending (seamless-handoff work). **Highest collision risk** — plan for a real merge conflict in NB. |
| `claude/warm-signal-full` | 3 commits touch NativeBackend.swift (+3 on the wider surface). Rapid-toggle detector #2 unmerged here. |
| `claude/companion-app-phase2-ios` | 2 commits touch NativeBackend.swift (+4 wider). Merge deliberately HELD. |
| `claude/onboarding-permission-priming` | 1 commit touches NativeBackend.swift (+2 wider). |
| `claude/focused-nightingale-42a9fd` | 2 commits on the wider surface (VU meters; uncommitted work may also exist in its worktree). |
| `claude/companion-app-research-e89998` | 1 commit on the wider surface. |
| `claude/volume-key-interception-bfd689` | no NB commits beyond main today, but the queued "we own volume" interceptor mode is scoped to land in this area (memory: A2). |

Name-suggests-routing branches verified to have **zero** NB commits beyond
main: `audio-routing-exception-bug-1ef721`, `audio-routing-architecture-
review-3f1eff`, `audio-routing-consolidation-92be71` (007, merged),
`redirect-follow-main-silence` / `connect-volume-seed` (merged),
`dropout`/`judder` branches, `t-zombie-investigation-e28483`,
`split-ownership-sweep`. Also remember other worktrees' *uncommitted* edits
are invisible to this scan (root `AGENTS.md` rule).

---

## 7. Facts a design must not break (summary for the design agent)

1. `bindOutput` is already the single stream-placement call site; the engine's
   per-output `opsInFlight` + `boundStreamId`/`rebindOutput` already make each
   *individual* transition atomic. The gap is purely **concurrent in-flight**
   transitions (§4 I1-I6) and **absent ownership arbitration** (§3).
2. T7 explicitly rejected "a second lock spanning converging and bindTail" as
   a deadlock surface (commit `86b02b7`; doc comment NB:3460-3462). A design
   that reintroduces one must answer that objection.
3. `streamBindings` records *intent* (written before ops run, NB:3354);
   `added` records *completion* (written after op success, NB:3763). Any
   arbiter keying on "who owns this device" must pick a consistent read.
4. The recovery machinery (`rebindRecoveryGen`, `stillOwnsRebind`,
   `releaseRebindConverging`) is already built on the exclusivity assumption
   (NB:2557-2559) — an arbiter makes that assumption true rather than adding a
   third bookkeeping system.
5. UI-layer exclusivity (clearRoutes + menu filter) stays; the backend arbiter
   is defense-in-depth for the transition window, races, and future callers —
   not a replacement for the UX rule "selection is the senior action".
6. `stop()` resets both domains wholesale (NB:1519-1560); an arbiter's state
   must reset there too.
