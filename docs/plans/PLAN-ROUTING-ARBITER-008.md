# PLAN — Routing arbiter (roadmap 008)

Scope exclusivity + cross-FIFO ordering in `NativeBackend`, the two residuals
T7 (commit `86b02b7`, roadmap 007) deliberately deferred. Research base:
`docs/notes/routing-arbiter-008-research.md` (all line numbers below re-verified
against branch `claude/routing-arbiter-008` on 2026-08-05 — but NativeBackend.swift
is the most-churned file in the repo: docs orient, code decides).

**NB** = `AudiouterCore/Sources/AudiouterCore/NativeBackend.swift`.

---

## 1. Chosen architecture

**Whole-system-priority scope arbiter, implemented as POLICY OVER EXISTING
STATE — three small mechanisms at existing choke points, all on `stateQueue`,
zero new locks, zero new load-bearing bookkeeping:**

1. **Demote-at-decision** (exclusivity): a `.device` route whose target is a
   Selected Device (`expectedSelected.contains(id)`) is INELIGIBLE and reads
   as effective-`.noRedirect` — plugged into the existing R5 effective-route
   mechanism (`effectiveAppRoutesLocked`, NB:2060), so the losing app rejoins
   the whole-system mix audibly instead of streaming into the void.
2. **Validate-at-fire** (transition-window ordering): every `bindTail` op
   re-checks the whole-system claim under `stateQueue` immediately before its
   engine call and BOWS OUT loudly if whole-system owns or is mid-operation on
   the device — generalizing the fire-time ownership check the rebind-recovery
   chains already use (`stillOwnsRebind`, NB:2625).
3. **Re-drive-at-release** (liveness): when the whole-system domain fully
   releases a device (converge teardown complete, `converging` slot freed) and
   the per-app table still wants it with a cleared binding, the existing
   replay (`replayPerAppBindingsAfterClockRecovery`, NB:3601 — generalized)
   re-issues the bind. Nothing ever WAITS on the other FIFO; losers bow out
   and are re-driven by the releasing side.

### The policy in one sentence

**Whole-system routing (stream 0) always wins a contested device; the per-app
domain yields loudly (telemetry + queryable conflict record + `.routedApps`
clear + audible fallback into the system mix) and re-engages automatically the
moment the device is deselected — the exact semantics R5 already gives an
unreachable redirect target.**

Why whole-system priority (static, not last-writer-wins):

- It is the backend enforcement of the UX rule already encoded in the UI
  layer: "selection is the senior action" (`GroupController.applyRouting` →
  `clearRoutes(toDevices:)` heals member→redirect conflicts; the popover menu
  filter prevents redirect→member ones). The arbiter is defense-in-depth for
  the transition window, races, and future callers — not a replacement.
- Static priority is deterministic under any interleaving. Last-writer-wins is
  exactly the today-bug (research §4 I2: "the last op to reach the engine wins
  and the other domain's maps go stale").
- The loser's failure mode is benign AND audible: a demoted route plays in the
  whole-system mix (which includes the contested device). The reverse priority
  would make a user-selected device silently drop out of the selection — the
  worst possible UX and invisible.
- The recovery machinery is already built on exclusivity keyed this way
  (`rebindRecoveryGen` shared per-device "a device is either whole-system or
  per-app, never both", NB:2557-2559). The arbiter makes that assumption TRUE
  instead of adding a third bookkeeping system (research fact 4).

### What "claim" means (research fact 3: one consistent read per layer)

- **Decision layer** (demotion) keys on pure INTENT: `expectedSelected` — set
  atomically in one place (`setOutputSet`, NB:1758), covers group activation
  (`activateGroup` funnels through `setOutputSet`), stable across
  `applyStartBuffer`'s internal `desiredOn` flap (which never touches
  `expectedSelected`, by documented design), and covers selected-but-not-yet-
  discovered targets (those are also demoted by the existing reachability
  conjunct — an unknown id counts unreachable, NB:2039).
- **Execution layer** (fire-time) keys on the OPERATIONAL claim:
  `desiredOn[id] == true || converging.contains(id) || added.contains(id)` —
  because its job is precisely to protect the in-flight window that intent
  alone cannot see (a deselected device whose teardown `removeOutput` is still
  in flight is still whole-system-owned at the engine).

### How this resolves the researched interleavings (research §4)

- **I1/I2 (TOCTOU double-read):** a per-app bind for a claimed device is never
  enqueued (demoted at decision) or bows out at fire. If a claim lands after a
  bind op passed its fire-time check, the whole-system converge necessarily
  runs after it and arbitrates on engine truth (`bindOutput` reads
  `boundStreamId`, rebinds — T7's existing fix); per-app bookkeeping was
  already evicted, so the engine's silent `.alreadyBound` no-op can no longer
  create a bookkeeping lie. Either engine order converges to stream 0.
- **I3 (remove-vs-bind, deselect-then-redirect):** the bind fires while
  converge's teardown is in flight → `ws_in_flight` bow-out → re-driven at
  slot release → binds against a fully-released device. No ordering left to
  chance.
- **I4 (unbind-vs-converge-add):** an `.unbind` firing for a whole-system-
  claimed device is DOWNGRADED to a no-op (skip `removeOutput`) — the converge
  owns the session and either already moved it to stream 0 or will; the
  removeOutput that used to kill the user's fresh session is never issued.
- **I5 (recovery-window ping-pong):** a route to a device whose whole-system
  recovery holds `converging` across backoff is demoted at decision (device
  still in `expectedSelected`), so the `.bind` that used to land between
  retry attempts never exists. Deselect mid-backoff → recovery's terminal
  exit releases the slot → re-drive.
- **I6 (PTP stall inversion):** per-app ops for the stalled device bow out;
  ops for OTHER devices proceed untouched (no cross-device coupling).
- **Steady-state double-claim / `rebindRecoveryGen` fight:** unreachable once
  claims are exclusive; during rollout a pre-existing mixed state self-heals
  toward whole-system (fire-time checks + converge's engine-truth rebind).

Cross-FIFO ordering is deliberately NOT totalized. Same-device orderings are
turned into explicit claim handoffs (bow-out + re-drive); different-device
interleavings share no engine state and were never the problem. Ordering
without an ownership decision would still leave "who wins" to timing — the
constraint demands a loud loser, which requires ownership anyway; once
ownership + fire-time validation exist, total ordering adds nothing.

### Loud loser (constraint 1)

- New Telemetry events, all `.airplay`:
  - `scope_conflict` — edge-triggered when a demotion engages/disengages for a
    (device, route) pair: `device`, `winner: wholeSystem`, `stage: routeDemoted
    | routeRestored`, `bundleIDs`, `stream`.
  - `bind_superseded` — a `.bind`/`.rebind` bow-out: `device`, `op`, `stream`,
    `reason: ws_claimed | ws_in_flight`.
  - `unbind_downgraded` — an `.unbind` skipped because whole-system owns the
    session: `device`.
  - `per_app_redrive` — the release-side replay firing: `trigger: ws_release`
    (the existing `app_route_rebind_on_clock_recovery` event stays as-is for
    its existing trigger).
- Queryable: `lastScopeConflicts: [String: ScopeConflict]` (device → current
  conflict; written on engage, removed on disengage, cleared in `stop()`),
  exposed via `test_scopeConflict(deviceID:)`. Diagnostic only — never read by
  any decision path (deliberately NOT a third bookkeeping system).
- UI truth: the demotion's topology change already clears `.routedApps` for
  the contested device through the existing diff (NB:3296-3302), so the teal
  dot/sublabel never lies. (The popover's app-row still shows the user's
  route INTENT — the same accepted gap R5 has today for unreachable targets.)

### No behavior change on single-domain paths (constraint 2)

- Whole-system-only (no routes): demotion iterates an empty `lastRoutes`;
  the `setOutputSet` hook guards on `lastRoutes.contains(.device …)` (same
  guard shape as `rerunAppRoutesIfTargeted`, NB:4719) → no-op; no `bindTail`
  ops exist for fire-time checks; the release-side re-drive flag requires
  `lastDestinationSets` to want the id → always false. Zero extra engine ops,
  zero extra events, one extra Set lookup per release.
- Per-app-only (no selection ever): `expectedSelected`/`desiredOn`/
  `converging`/`added` are all empty, so the demotion conjunct always passes
  and every fire-time predicate evaluates false-in-all-terms → every op
  proceeds exactly as today. The fire-time predicates deliberately contain NO
  topology-supersession check (`streamBindings[id] == stream`) precisely so
  the per-app-only op trace stays byte-identical — within-FIFO ordering
  already handles topology supersession correctly (FIFO order = decision
  order).

### Locks, queues, deadlock proof (constraint 4)

- The arbiter lives entirely on the existing `stateQueue` (NB:277). No new
  lock, queue, or Task chain.
- New critical sections are either extensions of EXISTING `stateQueue.sync`
  blocks (`setOutputSet`, `updateAppRoutes`, the converge defer, recovery
  terminal exits) or a new leaf-level `stateQueue.sync` inside
  `performBindOp` — which already takes `stateQueue.sync` today via
  `deviceID(for:)` (NB:3398/3431), so this adds no new lock-ordering edge.
- `stateQueue` stays a LEAF: no new section acquires any other lock/queue
  inside it (`Telemetry.log` is a non-blocking hand-off by contract), and no
  lock is ever held across an `await`.
- Nothing ever blocks waiting on the other FIFO — bow-out + re-drive replaces
  waiting, so no cross-domain wait cycle can exist. (See rejected Alt B for
  the concrete deadlock a blocking claim would create.)
- The 013-postmortem shape (same-queue `dispatch_sync` reentrancy → SIGTRAP,
  see `DefaultOutputDeviceMonitor.runOnQueue`, DODM:114-125) is avoided by the
  same discipline `rerunAppRoutesForReachabilityChange` documents (NB:2076):
  every hook that runs UNDER `stateQueue` and needs the route replay only
  ENQUEUES it (`captureControlQueue.async`) or calls it after its own sync
  block returns (converge Task context). The replay itself
  (`replayPerAppBindingsAfterClockRecovery`) already takes `stateQueue.sync`
  internally and calls `handleDestinationSetsChanged` OFF the lock (NB:3602-
  3610) — unchanged.

### Auditability (house style)

No parameterized abstraction, no shared control-flow type (the
TapRebuildLifecycle.swift header's rule). The arbiter is four small, named,
single-purpose insertions at choke points that already exist, each carrying
the one-sentence policy in its comment. The only new type is the diagnostic
`ScopeConflict` record. Both FIFOs keep their two direct, readable bodies.

---

## 2. Rejected alternatives

**Alt A — single serialization domain spanning both FIFOs** (merge converge
into `bindTail`, or one merged per-device FIFO):
- Head-of-line blocking: converge ops legitimately stall for SECONDS in
  `ensurePTPTakeover` (NB:3707, the widest window in the file). One global
  chain would stall every per-app op for every device behind one device's
  clock wait — a visible performance regression on paths the constraints
  require byte-identical.
- Reentrancy: converge's defer/requeue spawns new converge Tasks; folded into
  the chain, a completing op would append to the chain currently executing it
  — the recursive shape the 013 postmortem warns about, now in Task-chain
  clothing. T7 already rejected the spanning-lock variant by name (NB:3460-
  3462); a merged execution domain is the same objection.
- Insufficient anyway: total ordering serializes outcomes but still leaves
  "who wins" to arrival order — it needs the ownership policy on top, at
  which point the ordering machinery adds nothing.
- Blast radius: rewrites both domains' machinery in the repo's hottest file.

**Alt B — extend Finding-1 to all bindTail ops (bind ops claim/wait on the
`converging` slot):** concrete provable deadlock: a whole-system rebind
recovery claims `converging[D]` under `stateQueue` and THEN enqueues itself
onto `bindTail` (NB:2585, 2675). A `.bind(D, N)` op already queued AHEAD of it
would block waiting for `converging[D]` — held by the recovery queued BEHIND
it, which can never run because the FIFO can't advance past the blocked bind.
Cycle: bind waits on slot; slot-holder waits on bind. This is exactly the
deadlock surface T7's comment predicted for cross-domain claims; the chosen
design's non-blocking bow-out is the answer to it.

**Alt C — a new `scopeClaims: [String: DeviceScopeClaim]` ownership map:**
a third bookkeeping system that must be kept coherent with `desiredOn`/
`added`/`streamBindings` across stop, sleep, discovery loss, and every failure
walk-back — the split-ownership shape the house rules exist to prevent
(must-be-single-owned state), and the exact thing research fact 4 warns
against. Policy-over-existing-state yields the same arbitration with zero new
load-bearing state; the existing maps ARE the claims.

**Alt D — keep exclusivity UI-only:** roadmap 008 exists because the UI layer
cannot see the transition window (the sanctioned select-then-clear flow is
ITSELF a transient double-claim, research §3), cannot bind future callers, and
leaves the backend's behavior undefined on any race. Rejected by the roadmap's
own framing.

---

## 3. New/changed types and their owners

All in **NB** unless noted; everything below is `private` to `NativeBackend`
except the `test_` seam.

| Item | Kind | Owner / where |
|---|---|---|
| `isWholeSystemClaimedLocked(_ id:) -> Bool` | new func (`expectedSelected.contains(id)`) | `stateQueue`, next to `isRouteTargetReachableLocked` (NB:2039) |
| `isRouteTargetEligibleLocked(_ id:) -> Bool` | new func = reachable && !wholeSystemClaimed | same; consumed by `effectiveAppRoutesLocked` + `rerunAppRoutesIfTargeted` (reachability helper itself stays pure — its doc comment stays true) |
| `effectiveAppRoutesLocked` | changed: demotes on eligibility, not bare reachability; writes/clears the conflict record + edge telemetry | NB:2060 |
| `setOutputSet` | changed: inside the existing critical section, for ids whose membership in `expectedSelected` flipped, run the `rerunAppRoutesIfTargeted` shape keyed on eligibility (enqueue-only — never inline) | NB:1754-1901 |
| `performBindOp` | changed: one `stateQueue.sync` fire-time gate per op — `.bind`/`.rebind` bow out iff operational WS claim (reason `ws_claimed` / `ws_in_flight`; clears `streamBindings[id]` so re-drives re-issue, the `handleBindFailure(clearBinding: true)` precedent); `.unbind` downgraded to no-op iff operational WS claim | NB:3389-3427 |
| `releaseConvergingAndRequeueIfNeeded` | changed: additionally reports "per-app re-drive warranted" (released, `desiredOn[id] != true`, `lastDestinationSets` wants id, `streamBindings[id] == nil`) | NB:3649 |
| `convergeDevice` defer + `enqueueRebindRecovery` terminal exits (incl. the backed-off retry's terminal exit, NB:2778-2792) | changed: on release-without-requeue with the re-drive flag, call the replay OFF the lock | NB:3666, 2691-2812 |
| `replayPerAppBindingsAfterClockRecovery` | renamed/generalized → `replayPendingPerAppBindings(trigger:)`; guard unchanged (`outputIDs != nil && streamBindings == nil`, already exactly right) | NB:3601 |
| `ScopeConflict` (stage `routeDemoted`, bundleIDs, stream, date) + `lastScopeConflicts` + `test_scopeConflict(deviceID:)` | new diagnostic struct + map + `@testable` seam; cleared in `stop()` (NB:1517-1558) | `stateQueue` |
| `SpyEngine.onRemoveOutputBody`, `SpyEngine.onRebindBody` | new test hooks mirroring `onAddOutputBody` (:105) | `AudiouterCore/Tests/AudiouterCoreTests/NativeBackendTests.swift` |

No `AirPlayEngine` changes. No `GroupController`/`AppRoutingController`/UI
changes. No `OutputBackend`/`EngineControlling` protocol changes.

---

## 4. Task list

- **T1 — Demote-at-decision.** `isWholeSystemClaimedLocked` +
  `isRouteTargetEligibleLocked`; switch `effectiveAppRoutesLocked` and
  `rerunAppRoutesIfTargeted` to eligibility; audit ALL consumers of
  `isRouteTargetReachableLocked` first and decide per-site (reachability vs
  eligibility — e.g. `handleDeviceDisappeared` keys on disappearance, not
  this). Conflict record + `scope_conflict` edge telemetry.
- **T2 — Selection-edge replay.** In `setOutputSet`'s critical section:
  compute the `expectedSelected` symmetric difference; if any `.device` route
  in `lastRoutes` targets a flipped id, enqueue
  `rerunAppRoutesForReachabilityChange()` (it is documented safe to call with
  `stateQueue` held — enqueue-only). Covers both select (demote) and deselect
  (restore).
- **T3 — Validate-at-fire.** The `performBindOp` gate + bow-out/downgrade
  telemetry + `streamBindings` clear on WS-reason bow-outs. A vanished device
  (no `outputIDs` reverse entry) proceeds as today (engine tolerates).
- **T4 — Re-drive-at-release.** Release-helper flag; call
  `replayPendingPerAppBindings(trigger: "ws_release")` off the lock from
  `convergeDevice`'s defer and every `enqueueRebindRecovery` terminal exit;
  `per_app_redrive` telemetry.
- **T5 — Queryable seam.** `ScopeConflict` + map + `test_scopeConflict` +
  `stop()` clear.
- **T6 — Test infra.** `SpyEngine.onRemoveOutputBody` / `onRebindBody` hooks.
- **T7 — Race tests** (see §5).
- **T8 — Regression + docs.** Happy-path op-trace pin tests; full
  `scripts/run-tests.sh`; AudiouterCore/AGENTS.md rule entry (the arbiter
  invariant, where it lives, and the TRAP: bindTail ops must never WAIT on
  `converging` — Alt B's deadlock cycle); PROGRESS.md digest.

T1+T2 are one commit (exclusivity), T3+T4 one commit (ordering), T5+T6 small,
T7 the bulk. Each commit passes Guard 4 on its own.

---

## 5. Test plan

All in `NativeBackendTests.swift` (swift-testing, nested in
`SerializedSharedState` for the Telemetry sink), using the existing
`startAndDiscover` / `route(_:name:toDevice:)` / `ap2Device()` / `pollUntil` /
`airplayLines(evt:)` helpers and the T7 precedent tests (:4525, :4556) as the
template. Every race test names the interleaving it forces and forces it
deterministically via a SpyEngine hook — no sleeps-as-synchronization.

1. **`selectingARedirectTargetDemotesTheRouteAndWinsStream0`** (sanctioned
   direction, steady state). Route app→D, poll live stream 1; `setOutputSet
   ([D])`. Asserts: `liveStream(D) == 0`; `.routedApps(D, [])` emitted;
   `scope_conflict`/`routeDemoted` telemetry; `test_scopeConflict("D")` set.
2. **`redirectToASelectedDeviceNeverBindsAtAll`** (demote-at-decision).
   Select D first, then push route app→D. Asserts: NO `streamAdd:` for D ever
   appears in `opLog`; demotion telemetry; conflict queryable.
3. **`unbindFiringDuringConvergesRebindIsDowngraded`** (forces I4, the
   §3-walk kill-the-fresh-session bug). Route app→D live on stream 1;
   install `onRebindBody` to BLOCK converge's 1→0 rebind on a test-controlled
   continuation; `setOutputSet([D])`; the T2 replay's `.unbind(D)` fires while
   the rebind is held open → poll for `unbind_downgraded` telemetry; release
   the rebind. Asserts: no `remove:` for D anywhere after the route push;
   `liveStream(D) == 0`; `added` still contains D (via connected state).
4. **`bindBowsOutDuringWholeSystemTeardownAndIsRedriven`** (forces I3,
   deselect-then-redirect). D selected + live on 0; install
   `onRemoveOutputBody` to push route app→D from INSIDE converge's teardown
   `removeOutput` — the bind op therefore fires strictly within the teardown
   window → `bind_superseded`/`ws_in_flight`; teardown completes; release
   re-drive fires. Asserts: telemetry trail (`bind_superseded` then
   `per_app_redrive`); `opLog` shows D's `remove:` BEFORE its `streamAdd:`;
   final `liveStream(D) == 1`.
5. **`routeDuringWholeSystemRecoveryBackoffDoesNotPingPong`** (forces I5).
   D selected, live; inject `addFailures` so the whole-system rebind recovery
   schedules a backoff retry holding `converging[D]`; push route app→D during
   the backoff. Asserts: no `streamAdd:` for D while the recovery owns it
   (demoted — D still selected); no alternating add(0)/add(N) in `opLog`.
   Then deselect D mid-backoff → recovery's retry-fire terminal exit releases
   the slot → re-drive → poll `liveStream(D) == 1`.
6. **`selectionLandingInsidePerAppAddConvergesToWholeSystem`** (forces I1/I2
   TOCTOU). Route app→D; `onAddOutputBody` fires `setOutputSet([D])` from
   inside the per-app `addOutput` — the claim lands mid-op, after the fire-time
   check passed. Asserts: final `liveStream(D) == 0` (converge arbitrates on
   engine truth); no surviving per-app bookkeeping for D (`.routedApps` empty,
   `test_scopeConflict` shows the demotion); `maxConcurrentPerDevice == 1`.
7. **`demotedRouteReengagesOnDeselect`** (end-to-end backend-only exclusivity,
   no GroupController). Route app→D; select D (assert demoted + stream 0);
   deselect D (assert route re-engages with no route-table edit: poll
   `liveStream(D) == 1`, `.routedApps` repopulated, conflict record cleared,
   `scope_conflict`/`routeRestored`).
8. **`wholeSystemOnlyAndPerAppOnlyOpTracesAreUnchanged`** (constraint 2 pin).
   A WS-only select/deselect cycle and a per-app-only route/unroute cycle;
   assert `opLog` equals the exact pre-arbiter sequences.

Existing T7 tests (`deviceMovingFromWholeSystemToPerAppRebindsTheLiveSession`,
`deviceMovingFromPerAppToWholeSystemRebindsTheLiveSession`) must keep passing;
expected additive deltas only (new telemetry, `.routedApps` clear on the
per-app→WS direction).

---

## 6. OUT OF SCOPE

- **GroupController / AppRoutingController / popover changes.** UI-layer
  exclusivity (clearRoutes + menu filter) stays exactly as-is; the arbiter is
  defense-in-depth behind it.
- **Surfacing the demotion in the app-row UI** (route intent shown while
  effectively demoted) — the same accepted gap R5 has today for unreachable
  targets; owner decision if it should ever change.
- **A public `BackendEvent` for scope conflicts.** No UI design exists for
  it; `test_scopeConflict` + Telemetry satisfy the queryable-error constraint.
- **Totalizing cross-FIFO ordering** (rejected Alt A) and any restructuring of
  `bindTail` into per-device chains.
- **Topology-supersession fire-time skips** (`streamBindings[id] == stream`
  checks that would skip within-FIFO-superseded ops) — a benign optimization,
  deliberately excluded to keep per-app-only op traces byte-identical.
- **Sleep/suspend-window bind ops.** Existing wake re-kick + discovery
  re-drive cover recovery; unchanged here.
- **`AirPlayEngine` changes.** Engine-truth arbitration (`boundStreamId` /
  `rebindOutput` / per-output `opsInFlight`) is T7's and stays as-is.
- **`MockBackend` / `OwnToneBackend`** — no dual FIFOs there.
- **Merge-conflict absorption** from `claude/aggregate-device-wave3` (5
  unmerged NB commits — highest collision risk per research §6): rebase burden
  acknowledged, handled at merge time, not designed around here.
