# PLAN — Routing arbiter (roadmap 008)

Scope exclusivity + cross-FIFO ordering in `NativeBackend`, the two residuals
T7 (commit `86b02b7`, roadmap 007) deliberately deferred. Research base:
`docs/notes/routing-arbiter-008-research.md` (all line numbers below re-verified
against branch `claude/routing-arbiter-008` on 2026-08-05 — but NativeBackend.swift
is the most-churned file in the repo: docs orient, code decides).

> **Design review (2026-08-05, adversarial pass against the code):** the
> chosen architecture stands, but the original draft did NOT close the
> cross-FIFO race — it narrowed it (a concrete surviving interleaving is now
> written out under I1/I2), left the recovery chains ungated, would have
> regressed a zombie-session teardown via the blanket unbind-downgrade, and
> its test plan contained one unforceable interleaving, one flake-by-race,
> and one self-contradictory "must keep passing" claim. All repairs are
> inline, each marked "Design review". Net: mechanism 2's `.unbind` arm is
> four cases with a verify-first settle reusing the existing rebind-recovery
> machinery; mechanism 3 also re-drives deferred settles; `stillOwnsRebind`
> gains the WS-claim conjunct.

**NB** = `AudiouterCore/Sources/AudiouterCore/NativeBackend.swift`.

---

## 1. Chosen architecture

**Whole-system-priority scope arbiter, implemented as POLICY OVER EXISTING
STATE — three small mechanisms at existing choke points, all on `stateQueue`,
zero new locks.** (Design review: "zero new load-bearing bookkeeping" was
overstated and is retracted — mechanism 2 needs one small deferred-op set,
`pendingScopeSettles`; see Auditability for why Alt C's objection does not
apply to it.)

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

   **Design review — three corrections to this mechanism (the original
   wording did not close the race, see the I1/I2 discussion below):**

   - **Gate placement:** the fire-time check runs AFTER `ensurePTPTakeover`
     (a seconds-wide suspension, NB:3707/3398 — the widest window in the
     file), immediately before the engine call. A gate before the PTP wait
     re-opens the whole window it exists to close.
   - **The `.unbind` arm is FOUR cases, not a blanket downgrade.** A blanket
     "skip iff operational claim" has two provable failure modes: (a) it
     strands an astray engine session forever when the converge committed via
     the silent `.alreadyBound` no-op (interleaving below), and (b) when the
     claim is `desiredOn`-only (converge parked on PTP refusal / add
     failure), skipping the unbind leaks a live per-app session the demotion
     already evicted — a zombie receiver playing an app it no longer routes
     (today's code tears that down; a blanket skip would be a regression).
     The correct arm:
       1. no operational claim → `removeOutput`, byte-identical to today;
       2. claim is `desiredOn`-only (`!added && !converging`, i.e. parked or
          limbo — WS holds no engine session and no op is in flight) →
          `removeOutput`, byte-identical to today (correct teardown of the
          per-app session; WS re-adds fresh via retry/re-toggle);
       3. `converging` held (a WS op is in flight; its outcome — success vs
          park — decides what the right action WOULD have been, and is
          unknowable now) → skip, `unbind_deferred` telemetry, record the
          device in `pendingScopeSettles`; the release side re-drives it
          (mechanism 3);
       4. `added && !converging` (WS believes it owns a settled stream-0
          session — the only state the silent-no-op race can corrupt) →
          claim the `converging` slot Finding-1 style (insert into
          `converging` + `rebindConverging`, bump `rebindRecoveryGen`) and
          enqueue a **verify-first whole-system recovery** on the existing
          `enqueueRebindRecovery` machinery: read `engine.boundStreamId`;
          `0` → success with ZERO engine ops; astray (≥ 1) →
          `rebindOutput(_, 0)`; the chain's existing backoff / terminal-exit
          / slot-release discipline applies unchanged. `unbind_downgraded`
          telemetry either way. No new choreography — this IS
          `resetAirPlaySessionForWholeSystem`'s own claim shape, reused.
   - **The recovery chains need the same gate.** `enqueueRebindRecovery`'s
     ops execute `performRebindRecovery` directly on `bindTail` — they never
     pass through `performBindOp`, so the gate as originally scoped never
     sees them. A `.perApp`-scope recovery firing in the demotion-latency
     window (claim landed, eviction not yet propagated through
     `captureControlQueue` → mixer → `handleDestinationSetsChanged`) passes
     `stillOwnsRebind` (`streamBindings[D]` still set) and does
     removeOutput → addOutput(N), tearing down the user's fresh stream-0
     session. Fix: extend `stillOwnsRebind`'s `.perApp` arm with the
     operational-WS-claim conjunct, and add a pre-op re-check (same gen +
     ownership guard the completion already runs) BEFORE
     `performRebindRecovery` in the chain body. The `.wholeSystem` arm is
     NOT gated on the claim — it IS the whole-system domain and holds the
     slot. Uncontested chains pass both checks → op traces unchanged.
3. **Re-drive-at-release** (liveness): when the whole-system domain fully
   releases a device (converge teardown complete, `converging` slot freed) and
   the per-app table still wants it with a cleared binding, the existing
   replay (`replayPerAppBindingsAfterClockRecovery`, NB:3601 — generalized)
   re-issues the bind. Nothing ever WAITS on the other FIFO; losers bow out
   and are re-driven by the releasing side.

   **Design review — two additions:**
   - The release side ALSO consumes `pendingScopeSettles` (mechanism 2 case
     3): on a release WITHOUT requeue, a pending device re-runs the
     `added && !converging` settle arm (claim the freed slot, verify-first
     recovery). If the release DOES requeue a converge, the pending entry
     stays and defers to that converge's own release — no waiting, bounded
     by claim transitions, no timer loop.
   - Both the per-app-bind re-drive flag AND the pending-settle consumption
     are computed AFTER `releaseConvergingAndRequeueIfNeeded`'s existing
     `!suspended` early-return (NB:3656): a sleep-window release must re-drive
     NOTHING (sessions are dead; the wake re-kick + discovery re-drive are
     the recovery, per §6). The suspension handler (NB:4200-4222) clears
     `pendingScopeSettles` alongside `rebindRecoveryGen` — sleep tears every
     session down, so there is nothing left to settle.

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
  enqueued (demoted at decision) or bows out at fire.

  **Design review — the original text here claimed that when a claim lands
  after a bind op passed its fire-time check, "the whole-system converge
  necessarily runs after it and arbitrates on engine truth." That is FALSE:
  converge STARTING after the bind op does not order converge's
  `boundStreamId` read after the bind's `addOutput` landing.** The surviving
  interleaving: bind(D, 1) passes its gate → `setOutputSet([D])` lands →
  converge reaches `bindOutput(D, 0)` and reads `boundStreamId` = nil →
  per-app `addOutput(D, streamId: 1)` lands (session live on 1) → converge's
  `addOutput(D)` is the engine's silent `.alreadyBound` no-op, returns
  success → `added.insert(D)`, `.connected`. Engine stuck on stream 1,
  whole-system writes stream 0, device shows connected and plays the wrong
  audio — and with a blanket unbind-downgrade, the demotion's trailing
  `.unbind` (the only op left) would be skipped, freezing that state forever.
  The mirror order (converge runs entirely first; the in-flight per-app
  `bindOutput` then reads live = 0 and REBINDS the user's fresh session to
  stream 1) survives the same way.

  What actually closes it: every astray session implies a per-app engine op
  that ran, which implies `streamBindings[D]` was still set when the demotion's
  topology diff ran, which GUARANTEES a trailing `.unbind(D)` op FIFO-ordered
  after the astray op. Mechanism 2's four-case unbind arm turns that
  guaranteed trailing op into the deterministic last word: case 4's
  verify-first recovery reads engine truth AFTER the astray op completed and
  rebinds ≥ 1 → 0; case 3 defers to the release side when converge is still
  in flight, and the release-side settle re-runs case 4. No ping-pong is
  possible: under a claim, per-app ops only ever bow out, and the only
  session-movers are whole-system-priority (converge's own `bindOutput` and
  the verify-first settle), both moving toward 0.
- **I3 (remove-vs-bind, deselect-then-redirect):** the bind fires while
  converge's teardown is in flight → `ws_in_flight` bow-out → re-driven at
  slot release → binds against a fully-released device. No ordering left to
  chance.
- **I4 (unbind-vs-converge-add):** an `.unbind` firing for a whole-system-
  claimed device never issues the `removeOutput` that used to kill the user's
  fresh session. **Design review:** the resolution is the four-case arm, not
  a blanket skip — mid-converge (`converging` held) it defers to the release
  side (the converge's outcome decides whether the right action was "leave
  the moved session alone" or "tear down the orphan"); post-converge
  (`added`) it verifies engine truth; a `desiredOn`-only claim (converge
  parked) proceeds with today's teardown, which is correct there and whose
  loss would be a zombie-session regression.
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
  - `unbind_downgraded` — an `.unbind` converted to the verify-first settle
    because whole-system owns a settled session (case 4): `device`, plus
    `settled: noop | rebound` once the verify resolves (the recovery chain's
    existing `rebind` outcome trail carries the attempt detail).
  - `unbind_deferred` — an `.unbind` deferred to the release side because a
    whole-system op was in flight (case 3): `device`. (Design review: split
    from `unbind_downgraded` — the two cases have different semantics and a
    debugging session must be able to tell them apart.)
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
- Design review: the verify-first settle preserves this — its
  `boundStreamId` read + possible rebind run ONLY on a contested `.unbind`
  (cases 3/4 require an operational WS claim, impossible in either
  single-domain trace), so "zero extra engine ops" above stays literally
  true. The recovery-chain pre-op gate re-checks only what the completion
  already checks; uncontested recoveries pass it and their traces are
  unchanged.

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
- Design review: the verify-first settle keeps that rule. Its slot
  acquisition is a TRY-claim under the same `stateQueue.sync` that classified
  the unbind (slot busy ⇒ case 3's defer, never a wait), identical to
  `resetAirPlaySessionForWholeSystem`'s existing bow-out-if-converging shape
  (NB:2579). Its engine reads/ops run inside the existing
  `enqueueRebindRecovery` chain body — off the lock, appended to `bindTail`
  from within the currently-executing op's context (the new task awaits the
  CURRENT tail, which never awaits the new task — no cycle). Holding the
  slot across the verify is what makes the settle's read-then-act atomic
  against a concurrent converge: without it, a teardown's `removeOutput`
  landing inside the settle's read→rebind gap would let the rebind
  RESURRECT a session the user just deselected.
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
TapRebuildLifecycle.swift header's rule). The arbiter is a handful of small,
named, single-purpose insertions at choke points that already exist, each
carrying the one-sentence policy in its comment. New state, stated honestly
(design review): the diagnostic `ScopeConflict` record/map (never read by a
decision path), plus ONE small load-bearing set — `pendingScopeSettles:
Set<String>` (an unbind deferred while a WS op was in flight; consumed at
release, cleared in `stop()` and in the suspension handler). It is a
deferred-op note in the exact species of `pendingRebindRecoveries`, not an
ownership map — Alt C's objection (a third bookkeeping system that must stay
coherent with `desiredOn`/`added`/`streamBindings`) does not apply: a stale
entry costs one redundant verify read that finds live == 0 and no-ops. Both
FIFOs keep their two direct, readable bodies.

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
| `performBindOp` | changed: one `stateQueue.sync` fire-time gate per op, placed AFTER `ensurePTPTakeover`, immediately before the engine call — `.bind`/`.rebind` bow out iff operational WS claim (reason `ws_claimed` / `ws_in_flight`; clears `streamBindings[id]` so re-drives re-issue, the `handleBindFailure(clearBinding: true)` precedent); `.unbind` runs the FOUR-CASE arm (§1 mechanism 2, design review): no claim / `desiredOn`-only → today's `removeOutput`; `converging` → defer (`pendingScopeSettles`); `added && !converging` → try-claim slot + verify-first recovery | NB:3389-3427 |
| `pendingScopeSettles: Set<String>` | new (design review): unbinds deferred mid-converge, consumed at release; cleared in `stop()` + suspension handler | `stateQueue` |
| `stillOwnsRebind` + `enqueueRebindRecovery` chain body | changed (design review): `.perApp` arm gains the operational-WS-claim conjunct; chain body gains a pre-op `stateQueue.sync` re-check (gen + ownership) BEFORE `performRebindRecovery`; `.wholeSystem` scope gains the verify-first flavor (read `boundStreamId`; 0 → success no-op; ≥ 1 → `rebindOutput(_, 0)`) used by the settle | NB:2625, 2659-2812 |
| `releaseConvergingAndRequeueIfNeeded` | changed: additionally reports "per-app re-drive warranted" (released, `desiredOn[id] != true`, `lastDestinationSets` wants id, `streamBindings[id] == nil`) AND "pending scope-settle warranted" (`pendingScopeSettles` holds id, no requeue) — both computed after the existing `!suspended` early-return (design review) | NB:3649 |
| `convergeDevice` defer + `enqueueRebindRecovery` terminal exits (incl. the backed-off retry's terminal exit, NB:2778-2792) | changed: on release-without-requeue with the re-drive flag, call the replay OFF the lock | NB:3666, 2691-2812 |
| `replayPerAppBindingsAfterClockRecovery` | renamed/generalized → `replayPendingPerAppBindings(trigger:)`; guard unchanged (`outputIDs != nil && streamBindings == nil`, already exactly right) | NB:3601 |
| `ScopeConflict` (stage `routeDemoted`, bundleIDs, stream, date) + `lastScopeConflicts` + `test_scopeConflict(deviceID:)` | new diagnostic struct + map + `@testable` seam; cleared in `stop()` (NB:1517-1558) | `stateQueue` |
| `SpyEngine.onRemoveOutputBody`, `SpyEngine.onRebindBody` | new test hooks mirroring `onAddOutputBody` (:105); design review: `onAddOutputBody` must ALSO be invoked from `addOutput(_:streamId:)` — today only the stream-0 `addOutput(_:)` runs it, so no per-app-side interleaving is forceable — and each hold-open hook blocks on a test-controlled continuation, placed BEFORE the spy's `liveStreams` write | `AudiouterCore/Tests/AudiouterCoreTests/NativeBackendTests.swift` |

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
- **T3 — Validate-at-fire.** The `performBindOp` gate (AFTER the PTP gate,
  immediately before the engine call) + bow-out telemetry + `streamBindings`
  clear on WS-reason bow-outs; the four-case `.unbind` arm incl. the
  verify-first settle (slot try-claim + `enqueueRebindRecovery` verify
  flavor) and `pendingScopeSettles`; the recovery-chain pre-op gate +
  `stillOwnsRebind` `.perApp` WS-claim conjunct (design review — all three
  are load-bearing, see §1 mechanism 2). A vanished device (no `outputIDs`
  reverse entry) proceeds as today (engine tolerates).
- **T4 — Re-drive-at-release.** Release-helper flags (per-app re-drive AND
  pending scope-settle, both after the `!suspended` guard); call
  `replayPendingPerAppBindings(trigger: "ws_release")` / run the settle arm
  off the lock from `convergeDevice`'s defer and every
  `enqueueRebindRecovery` terminal exit; clear `pendingScopeSettles` in the
  suspension handler; `per_app_redrive` telemetry.
- **T5 — Queryable seam.** `ScopeConflict` + map + `test_scopeConflict` +
  `stop()` clear.
- **T6 — Test infra.** `SpyEngine.onRemoveOutputBody` / `onRebindBody` hooks;
  wire the existing `onAddOutputBody` into `addOutput(_:streamId:)` too
  (design review — the per-app add currently never invokes it, so test 6/9
  would be unforceable); hooks must support hold-open (block on a
  continuation) with placement BEFORE the spy's `liveStreams` write.
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
3. **`unbindFiringDuringConvergesRebindIsDeferredThenSettles`** (forces I4,
   the §3-walk kill-the-fresh-session bug). Route app→D live on stream 1;
   install `onRebindBody` to BLOCK converge's 1→0 rebind on a test-controlled
   continuation (hook placement: between the rebind's stop-half and add-half,
   so a concurrent read sees no stale stream); `setOutputSet([D])`; the T2
   replay's `.unbind(D)` fires while the rebind is held open → poll for
   `unbind_deferred` telemetry (design review: case 3, not a downgrade);
   release the rebind; converge completes and its release consumes the
   pending settle → verify reads live == 0 → zero ops. Asserts: no `remove:`
   for D anywhere after the route push; `liveStream(D) == 0`; `added` still
   contains D (via connected state); settle telemetry shows the no-op
   verify outcome.
4. **`bindBowsOutDuringWholeSystemTeardownAndIsRedriven`** (forces I3,
   deselect-then-redirect). D selected + live on 0; install
   `onRemoveOutputBody` to push route app→D from INSIDE converge's teardown
   `removeOutput` and then HOLD the removeOutput open (poll inside the hook /
   block on a continuation) until `bind_superseded`/`ws_in_flight` is
   observed — design review: without the hold, the bind op RACES converge's
   slot release after the hook returns and the test flakes between bow-out
   and direct bind; the hold is what makes "fires strictly within the
   teardown window" true rather than hoped. Then release; teardown
   completes; release re-drive fires. Asserts: telemetry trail
   (`bind_superseded` then `per_app_redrive`); `opLog` shows D's `remove:`
   BEFORE its `streamAdd:`; final `liveStream(D) == 1`.
5. **`routeDuringWholeSystemRecoveryBackoffDoesNotPingPong`** (forces I5).
   D selected, live; inject `addFailures` so the whole-system rebind recovery
   schedules a backoff retry holding `converging[D]`; push route app→D during
   the backoff. Asserts: no `streamAdd:` for D while the recovery owns it
   (demoted — D still selected); no alternating add(0)/add(N) in `opLog`.
   Then deselect D mid-backoff → recovery's retry-fire terminal exit releases
   the slot → re-drive → poll `liveStream(D) == 1`.
6. **`selectionLandingInsidePerAppAddConvergesToWholeSystem`** (forces I1/I2
   TOCTOU, favorable engine order). Route app→D; `onAddOutputBody` (now wired
   into `addOutput(_:streamId:)` — T6, design review) fires `setOutputSet([D])`
   from inside the per-app add — the claim lands mid-op, after the fire-time
   check passed; the hook returns before the spy's `liveStreams` write, so
   converge's later `boundStreamId` read sees the live per-app stream and
   rebinds. Asserts: final `liveStream(D) == 0` (converge arbitrates on
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
9. **`staleConvergeReadIsHealedByTheSettlingUnbind`** (design review — forces
   the I1 interleaving the original plan believed impossible: converge reads
   `boundStreamId` = nil BEFORE the in-flight per-app add lands, then its own
   `addOutput` is the silent `.alreadyBound` no-op). Route app→D with the
   per-app `addOutput(_:streamId:)` HELD OPEN in `onAddOutputBody` (pre-
   `liveStreams`-write); `setOutputSet([D])`; hold converge's stream-0
   `addOutput(_:)` in the same hook once it arrives (its `boundStreamId`
   already read nil); release the per-app add (live → 1); release converge's
   add (silent no-op — live stays 1, `added` inserted). The demotion's
   trailing `.unbind` then hits case 4: try-claim + verify reads 1 →
   `rebindOutput(D, 0)`. Asserts: `pollUntil { liveStream(D) == 0 }`;
   `rebindCalls` contains (D, 0) issued by the settle; `unbind_downgraded`
   with `settled: rebound`; no per-app bookkeeping survives.

Existing T7 test `deviceMovingFromPerAppToWholeSystemRebindsTheLiveSession`
must keep passing with additive deltas only (new telemetry, `.routedApps`
clear). **Design review — the original claim that BOTH T7 tests "must keep
passing" was self-contradictory:**
`deviceMovingFromWholeSystemToPerAppRebindsTheLiveSession` asserts that
redirecting a SELECTED device moves the session to stream ≥ 1 — the exact
scenario test 2 above now pins to "never binds at all" (demoted; engine
stays on 0). That is the intended semantics change of this roadmap, not a
regression: the flow it modeled is UI-prevented (menu filter) and
UI-healed (`clearRoutes`), and the backend now enforces the same rule. The
test must be REWRITTEN, not preserved: its within-transition-rebind purpose
(the engine session genuinely moving 0 → N through `rebindOutput`) survives
by first DESELECTING D and then routing to it — the legitimate direction —
which test 7's deselect half already exercises; fold or rename accordingly
and note the supersession in the test's doc comment.

---

## 6. Implementation deviations (2026-08-05, implementation pass)

All mechanisms landed as designed; four deviations, each in the design's
spirit, none silent:

1. **Release-side settle consumption re-enqueues the deferred `.unbind` instead
   of running the case-4 arm inline.** §1 mechanism 3 says the release "re-runs
   the `added && !converging` settle arm". The implementation instead re-enqueues
   `.unbind(outputID)` through `enqueueBindOps` (on-`stateQueue`-safe), so the
   deferred op re-runs `performBindOp`'s full four-case classification against
   the post-converge world. This is strictly more correct than the letter: a
   converge that PARKED (release with `added == false`) leaves a live per-app
   session the demotion already evicted — the design's own case-2 analysis says
   the right action there is today's `removeOutput`, which the re-enqueued op
   takes and an inline case-4-only settle would have skipped (the zombie-session
   leak the design review §1 flagged for the blanket-skip variant). A NEW claim
   landing in the meantime re-defers (case 3) — bounded by claim transitions,
   as designed. Telemetry: the re-enqueue is logged as `unbind_redrive`
   (`trigger: ws_release`).
2. **`unbind_downgraded` is emitted twice per settle**: once at conversion with
   `settled: pending` (case 4 classification) and once at verify resolution with
   `settled: noop | rebound`. The design asked for one event "plus `settled` once
   the verify resolves"; two lines keep both moments in the trail without a new
   event name.
3. **SpyEngine hooks**: instead of converting the existing sync `onAddOutputBody`
   to a blocking hold, the hold-open capability landed as separate ASYNC hooks
   (`onAddOutputHold(_, stream)` on both add variants, `onRemoveOutputBody`,
   `onRebindBody`), awaited at the exact pre-`liveStreams`-write placement points
   — a blocked continuation never pins a cooperative-pool thread. The existing
   sync `onAddOutputBody` is additionally invoked from `addOutput(_:streamId:)`
   exactly as T6 required.
4. **Test-plan adjustments discovered against the code:** (a) test 3's "no
   `remove:` for D anywhere after the route push" is unassertable as written —
   the spy deliberately records `rebindOutput`'s stop half into the same
   `remove:` oplog — so the test pins "exactly ONE remove (the scope rebind's own
   stop half)" instead, which captures the same fact (the deferred unbind issued
   none). (b) Re-engage assertions accept any stream ≥ 1: the mixer assigns a
   FRESH stream id when a demoted route re-engages. (c) The pre-existing metering
   test `deviceFedBySystemAndStreamReportsMax` built its fixture on the exact
   state the arbiter now prevents (one device simultaneously Selected and a live
   redirect target); it was rewritten to prove each side of the MAX in the state
   that can now carry it, with the supersession noted in its doc comment (same
   treatment §5 prescribed for `deviceMovingFromWholeSystemToPerApp...`, which
   became `...AfterDeselectEndsOnThePerAppStream`).

## 6b. Final adversarial review (2026-08-05, independent pass against the landed code)

Verdict: design and implementation hold — every mechanism re-verified against
the code (demote-at-decision full-table-only callers, fire-time gate placement
after the PTP wait, four-case arm, recovery-chain preflight + `.perApp`
WS-conjunct, release re-drives behind the `!suspended` guard, `stop()`/sleep
clears, leaf-`stateQueue` discipline, `enqueueBindOps` append-only-under-lock).
Single-domain op traces re-confirmed byte-identical (test 8). ONE real defect
found, forced red, fixed, and pinned:

- **Stale deferred unbind vs. a re-engaged route (fixed).** The release-side
  settle consumption re-enqueued the deferred `.unbind` unconditionally. When
  the user DESELECTED while the deferring converge was still in flight, the
  restore replay re-decides a binding (`streamBindings[id]` set) and its
  `.bind` is FIFO-AHEAD of the re-enqueued unbind; the stale unbind then fires
  with no claim left (case 1) and removeOutput-kills the freshly re-engaged
  session — and with `streamBindings` set, every replay guard
  (`streamBindings == nil`) skips the device forever: silent audio loss with
  no self-recovery. Fix: the consume drops the settle (loudly,
  `unbind_redrive` `outcome: dropped_route_reengaged`) when
  `streamBindings[id] != nil`; the read and the restore diff's write are both
  under `stateQueue`, so the decision is atomic against the replay in both
  orders. Safety of the drop: this release's own converge tore the engine
  session down on the way to `added == false`, and a still-live astray session
  is moved by the restored `bindOutput` itself (engine-truth read). Test 10
  (`staleDeferredUnbindMustNotKillAReengagedRoute`) forces the interleaving
  deterministically (held rebind → deferred unbind → deselect → restored bind
  parked pre-gate on the armable PTP activator → release) and was confirmed
  red pre-fix (session dead, remove after the re-engaged bind) and green
  post-fix.

Test honesty spot-check: tests 3 and 9 re-run against a locally neutered
four-case arm (blanket `removeOutput`, the pre-008 behavior) go red as
claimed; neuter discarded.

## 7. OUT OF SCOPE

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
