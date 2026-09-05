# Plan — Memory-leak & daily-impact audit (coreaudiod growth on per-app redirect)

Status: **Waves 1-2 EXECUTED + COMMITTED** (`a10defd`) · Wave 3 (Firefox plan) in progress · Wave 4 pending
Branch: `claude/memory-leak-investigation-396ac3` · Backend: **native**
Investigation: 9 subsystem audits (8 complete + 1 partial with residual scoped as W0.3), every High finding independently staff-verified at source by the session lead.

## Symptom (user report, 2026-07-23)

- Memory growth observed in **coreaudiod / system side**, NOT (primarily) the Audiout process.
- Occurred while a per-app redirect was active **and broken** (audio out of BOTH the redirect
  target AND Selected Devices — the known child-process/wrong-PID routing bug).
- Goal: first external users incoming; every combination of audio selection, device
  determination, and per-app redirection must stay low-CPU / low-memory across full-day use.

## The verdict — four legs, all confirmed

1. **Bounded-object leaks (staff-verified, fix-ready):**
   - **L1 · Tap resurrection race** — de-route during a pending retry window (≤10 s) resurrects
     a *muted* tap+aggregate in coreaudiod that no future route diff can see, AND silences that
     app system-wide. `NativeBackend.swift:1387-1396` (no membership re-check), `:1572-1575`
     (false fail-fast doc), retry item fired from `DispatchQueue.global()` `:1580-1588`.
   - **L2 · "Play on this Mac" quit gap** — quit observer only resets `.device` routes
     (`AppRoutingController.swift:101-105` guards `isDeviceRoute`); `handleAppTerminated` has NO
     production caller (grep-verified). A quit `.currentDevice` app strands tap+aggregate+IOProc
     on a dead pid; relaunch never restarts capture (`handleAppLaunched` consults
     `routedBundleIDs` only).
   - **L3 · Events-channel fd leak** — `client_free` (`airplay_events.c:97-113`) never closes
     `client->fd`; `airplay.c:3321` never stores it. One TCP socket leaked per AirPlay
     disconnect/reconnect → fd exhaustion over long sessions; reconnects are exactly what
     redirect churn generates.
   - **L4 · Onboarding-probe HAL leak** (two audits converged) — `AudioCapturePermissionProbe.swift:185-187`
     `defer` sits AFTER the `guard tap.start()`; `SelfProcessTap` has no deinit backstop; four
     partial-failure exits (`:357,:377-379,:403,:406`) leak tap/aggregate/IOProc permanently.
   - **L5 · Orphaned local player nodes** — `LocalPlaybackEngine.swift:413` throw path has no
     detach for the node attached at `:395`/connected at `:404` (rollbacks exist only at
     `:408/:423/:445`); our own tap churn provokes exactly this throw.
2. **Permanence mechanism:** **12 silent-destroy sites** (`NCC:1044-1053`, `PAC:999-1008`,
   `Probe:412-421`) + ignored listener-remove statuses — a failed destroy is invisible AND
   unretryable (stored id reset unconditionally) = permanent coreaudiod growth.
3. **Unbounded churn (the storm):** rebuild loop **C-A** — per-tap nominal-rate listeners have
   NO changed-value guard and no debounce; all taps pin the same device; one rate perturbation
   fires N rebuilds (~16 coreaudiod round-trips + 2 device-list mutations each), rebuilds can
   re-perturb the rate → live-lock. Retry loop **C-B** — `.processNotYetAudible` re-driven
   forever by backoff + process-object-list events (fired by the target app's own child
   processes). Broken-redirect state = C-B continuous + possible zombie tap joining every C-A
   round + a session reset per rebuild.
4. **Churn amplifiers:** every re-route toggle misread as recapture → spurious session reset
   (`everCapturedBundleIDs` insert-only, `:1394`); LPE full engine restart per device-list
   notification, uncoalesced; popover toggle churns M metering-tap trios; Groups window
   refreshes on every backend event while closed.

**Broken-redirect root cause** is the approved, unexecuted Firefox plan
(`.claude/worktrees/firefox-audio-routing-bug-14ba63/docs/plans/PLAN-FIREFOX-ROUTING-LEAK.md` —
doc exists ONLY in that worktree): single-PID resolution misses browsers' child audio
processes. Its execution is Wave 3 here; its fix removes the worst-case amplifier state.

**Exonerated (verified clean, do not re-audit):** PTP root daemon (fully clean); popover
open/close hot path incl. meters (push-only, nothing to detach); PerAppCaptureCoordinator
internals; AppRouteMixer pruning; CompletionRegistry (prior continuation-leak class closed);
per-stream C session state (symmetric; ~1.5 MB alloc/free per redirect = RSS fragmentation
candidate in OUR process, not a leak); AudioDiag (no in-memory buffer, env-gated); pairing
normal paths; all stores; MockBackend; no Combine and no CGEventTap anywhere in UI.

## Execution prerequisites

- **Merge local `main` (≥ `48c3a82`)** into this worktree before any task runs `swift test`
  (test-only loopback-bind fix; kills the firewall prompt storm). Merge-approval hook applies.
- All work in THIS worktree; waves land as serialized merges within the branch; **nothing
  merges to `main` without the owner's explicit go-ahead**.
- Live audio is **owner-only** (standing rule): agents verify with silent `swift build` +
  `swift test --parallel`; every wave that touches the audio path ends in an owner live gate.
- Native live testing is single-instance (PTP ports) — one live test at a time, coordinated.

## Execution mode — orchestrated watched agents

Watched **agents** (not a background workflow), one per task lane, launched per wave.
**The session lead (Fable, this session) is the orchestrator:** writes each task's spec,
reviews every returned diff line-by-line against spec + cohesion + the combined build
(staff-review gate), and tidies imperfections directly rather than bouncing trivial fixes
back. Agents are still expected to deliver to spec **exceptionally** — the review gate is a
quality floor, not a license to under-deliver. A task is "done" only when: its named tests
pass under `swift test --filter <Suite>`, the COMBINED tree builds + passes
`swift test --parallel`, and the lead has signed off the diff.

## Wave 0 — measurement + residuals (all three lanes parallel, no code conflicts)

### W0.1 · Measurement kit — **the owner** (~20 min at the Mac) · unblocked NOW
> Claude never plays/captures audio. Passive observation only; you do the redirects.

**Terminal window 1 — leave running the whole session:**

```sh
while true; do
  echo "$(date '+%H:%M:%S') $(ps axo rss=,comm= | grep -E '(coreaudiod|Audiout)' | grep -v grep | tr '\n' ' | ')"
  sleep 5
done | tee ~/Desktop/audio-mem-log.txt
```

- **Phase 0 (2 min):** baseline — app running, popover closed, music to Selected Devices, hands off.
- **Phase A (~10 min):** redirect **Music** (native app) to a speaker, wait 30 s, un-redirect,
  wait 30 s — ×10. Note start/end clock times. *Tests: does each cycle permanently step memory up?*
- **Phase B (5 min):** redirect **Firefox** (known-broken double-audio state), hands off 5 min.
  *Tests: steady climb with zero user action = retry-storm churn (C-B) confirmed.*
- **Phase C (2 min):** remove redirect, wait 30 s, **quit Audiout**, watch 2 more min.
  *Big coreaudiod drop on quit ⇒ process-held leaked objects (L1/L2/L4 class); little drop ⇒
  churn-internal growth (C-A class). This one number halves the fix-priority debate.*
- Return `~/Desktop/audio-mem-log.txt` + phase times. (Popover closed during phases reads cleanest.)
- Note: external counting of leftover `PerAppTap-*` devices is impossible — private aggregates
  are invisible outside our process. In-app counters are T5.

**Decision gate fed by W0.1:** Phase B dominant → promote Wave 3 (Firefox) ahead of Wave 2.
Phase A steps dominant → order stands (Wave 1 already fixes the per-cycle leaks).

### W0.2 · Merge `main` ≥ 48c3a82 — **lead, inline** (hook-gated) · trivial
### W0.3 · Residual C-sender audit — **opus · high** · read-only
Cover what the killed audit didn't finish: `mdns.c`, `transcode.c`, `raop.c` per-call alloc
paths, remaining `airplay_events.c` surface (beyond the verified fd leak), `rtp_common.c`
re-check. Checklist + exoneration format as the other audits. *Why this tier: adversarial
error-path reading of vendored C; no spec can remove the judgment.*

## Wave 1 — surgical leak fixes (7 parallel lanes, disjoint file ownership)

Every task below ships with: exact spec (anchors verified in this tree), do-not-touch bounds,
named `IsolatedTestCase` tests + filter command, and lead sign-off. Full specs get written
per-task at launch; the table is the authoritative scope/assignment.

| ID | Task (files) | Model · Effort | Why this tier |
|----|--------------|----------------|---------------|
| T1 | **Backend lifecycle contract**: (a) membership re-check in `.capturing` branch → `stop()` if bundle ∉ routed∪local (NB:1387-1396) + fix false doc :1572-1575; (b) quit path: extend `handleAppTerminated` guard to routed∪local + `localPlaybackEngine.removeApp` + call it from AppDelegate didTerminate observer (keep `resetDeviceRoute`); (c) `handleAppLaunched` consults `localBundleIDs` for capture restart. Files: `NativeBackend.swift`, `AppDelegate.swift` (observer block only), `NativeBackendTests`. | **sonnet · high** | Two verified bugs with exact anchors, but semantics cross the Core/AppKit seam and tests need scripted coordinator fakes — real residual judgment, bounded. |
| T2 | **LPE orphan rollback**: do/catch around `:413` → `engine.detach(player)` + rethrow (mirror `:408` idiom); add `test_startOverride` seam (repo `test_*Override` convention); test = forced start-throw leaves `engine.attachedNodes` clean. File: `LocalPlaybackEngine.swift` + tests. | **haiku · medium** | Airtight spec; the idiom to copy is three lines away in the same function. |
| T3 | **Probe teardown**: move `defer` above the `guard` (`AudioCapturePermissionProbe.swift:185-187`), add `SelfProcessTap.deinit { teardown() }`, log the 4 destroy statuses (:412-421). | **haiku · low** | One-line motion + boilerplate; teardown already tolerates partial state. |
| T4 | **C hygiene batch**: `close(client->fd)` in `client_free` (guard ≥0, `airplay_events.c:97-113`) + `free_ng(usr->ng)` in both `srp_user_new` err_exits (`pair_fruit.c:259-275`, `pair_homekit.c:368-384`); provenance comments. | **haiku · low** | Mechanical, exact lines, no control-flow change. |
| T5 | **Observability**: log OSStatus at the 12 destroy sites + listener-remove sites (NCC/PAC/SOV/DOO — Probe's 4 live in T3); add env-gated live-handle counters (taps/aggregates/IOProcs) to `AudioDiag` with a dump hook. Zero cost when disabled. | **sonnet · low** | Mechanical but cross-file; must match AudioDiag conventions and stay off the hot path. |
| T6 | **DACP hardening**: idle receive deadline (~30 s, cancel+prune) + confine `listener`/`connections` mutations to `queue` (`DACPServer.swift:68-155`). | **sonnet · low** | NWConnection lifecycle needs mild care; scope is one small file. |
| T7 | **Meter displaylink retain fix**: `passUnretained` → `passRetained` with stop-before-release ordering (or `NSView.displayLink(target:selector:)`), `LevelMeterView.swift:198-208` vs `:72-74`. | **haiku · medium** | Exact pattern dictated in-spec; crash-class hardening, tiny surface. |

**Gate W1:** combined `swift test --parallel` + lead diff review + **owner live smoke**
(redirect Music on/off ×3, quit a "play on this Mac" app, watch T5 counters return to zero).

## Wave 2 — storm damping (coordinator cluster SEQUENTIAL; 4 side lanes parallel)

Cluster (same files, strictly ordered, one agent may carry through all three via SendMessage):

| ID | Task | Model · Effort | Why |
|----|------|----------------|-----|
| T8 | **Rebuild guard**: store built-against `(deviceID, nominalRate)`; on any listener fire, read current pair and NO-OP if unchanged (PAC + NCC) — the structural C-A loop breaker. Also replay `pendingDeviceChange` from initial `beginStart` commit (the A1 gap). + tests w/ scripted tap fakes. | **opus · high** | Semantics must preserve every legitimate rebuild (documented silent-tap pathology); wrong guard = silent audio regression. RT-adjacent judgment survives any spec. |
| T9 | **Process-list debounce** (1–2 s trailing, both coordinators) + drop non-retryable `.failed` slots from re-drive scans. PAC. | **sonnet · medium** | Pattern (debounced DispatchSourceTimer) prescribed; semantics preserved by backoff floor. After T8 (file ownership). |
| T10 | **Shared device-event monitor**: ONE default-device + ONE rate listener on a dedicated serial queue, trailing-edge debounce 300–500 ms, sequential fan-out to NCC + both PAC coordinators, cross-coordinator generation coalescing; per-tap listeners removed; rebuilds leave HAL notification threads. New file + PAC/NCC/NativeBackend wiring. | **opus · xhigh**, mandatory lead line-review + owner live gate | The riskiest change in the plan: replaces the listener topology under live audio. Highest residual design judgment; prior live regressions in adjacent code. |

Parallel side lanes (disjoint from cluster and each other):

| ID | Task | Model · Effort | Why |
|----|------|----------------|-----|
| T11 | **LPE config-change coalescing** (~300 ms trailing edge; handler already idempotent). | **sonnet · medium** | Prescribed pattern; must not delay first-start latency — one judgment point. |
| T12 | **Bookkeeping hygiene**: `everCapturedBundleIDs` remove-on-stop (kills spurious session resets per re-route toggle) + retry/rebind map removals (F5) + `GroupController.memberState` prune-on-device-removal. + tests. | **sonnet · low** | Exact removals enumerated; isRecapture semantics interaction is spelled out in-spec. |
| T13 | **UI batch**: `presentSetup` nil-guard (mirror :395), Groups-window B8 gate (`skip refreshAll when !isVisible`, refresh on show — mirror PopoverController :436-441), `QuittingIndicatorPanel.isReleasedWhenClosed = false`. | **haiku · medium** | Three point-fixes with the exact sibling pattern cited for each. |
| T14 | **Engine write-queue cap**: bounded depth at `enqueue` (drop-oldest + diag counter) so an engine-thread stall can't grow memory at audio rate (`EngineThread.swift:138-181`, `AirPlayEngine.swift:1064-1072`). | **opus · medium** | Drop policy on the audio path = judgment; cap mechanics are simple. |

**Gate W2:** combined suite + lead review + **owner live gate** (device flip during playback
with 2 routed apps: no audio gap > 1 s, `PAC.handleDeviceChange FIRED` log count bounded,
coreaudiod CPU settles < 10 s).

## Wave 3 — root cause + remaining correctness (after W2, or promoted by W0.1 Phase B)

| ID | Task | Model · Effort |
|----|------|----------------|
| T15 | **Execute the Firefox routing plan** (its own approved table governs: T7 diag haiku·low → T1 resolver opus·high → T2 opus·high / T3 sonnet·medium / T4 sonnet·medium / T5 opus·high → T6 tests sonnet·medium → T8 docs haiku·low). Cherry-pick/port its plan doc into this branch first. Removes the broken-redirect amplifier state entirely. | per its table |
| T16 | Whole-system tap `.failed` → wire `onStateChange` retry (mirror per-app backoff pattern; E10). NB + NCC. | **sonnet · medium** |
| T17 | Engine slot-cleanup ordering: make timed-out-op cleanup tracked/ordered so it can't clobber the next op's slot (A9-F4). | **opus · medium** |

**Gate W3:** Firefox plan's own live gates (the owner, real Firefox + BT hardware) + suite.

## Wave 4 — verification + closure (serial)

| ID | Task | Owner |
|----|------|-------|
| T18 | Combined verification: full `swift test --parallel`, cross-cutting regression tests for L1/L2 shapes, lead end-to-end diff review of ALL waves. | lead + sonnet·medium for test gaps |
| T19 | **The owner re-runs the measurement kit** on the fixed build — Phase A flat, Phase B flat (post-T15), Phase C no-drop; plus by-ear redirect QA. | The owner |
| T20 | Docs: AGENTS.md deltas, STABILITY ledger updates, memory notes, backlog filing. | haiku · low |

## Deferred backlog (explicitly NOT scheduled — LOW/dormant, filed in T20)
OwnTone-only items (muted/stashedVolume prune, pollTask self-retain, D5 continuation);
engine C registry out-of-band prune (A9-F5); `DeviceIconController.onChange` chain comment;
`GroupRowView` dead-code delete; `updateAppRoutes` plan-ordering atomicity note (F8); IOProc
per-callback `Data` allocation churn (perf, RT hygiene); popover metering-tap churn per toggle
(E9 — revisit only if T5 counters show it mattering).

**Surfaced during Wave 1-2 execution (new, not in the original audit):**
- `GroupController.memberState` has no real per-device-removal hook to prune on today (T12
  finding) — the class never subscribes to `BackendEvent`/caches a device list at all; the
  nearest candidate signal, `BackendEvent.deviceRemoved`, would be WRONG to prune on (it
  signals an ordinary offline blip, not permanent removal — pruning there drops a
  reconnecting device's mute state, a real regression). Left as a comment at the
  declaration; needs a genuine device-lifecycle signal this class doesn't have before it's
  actionable.
- `AirPlayEngine`'s C device registry (outputs.c) still doesn't prune a device that fails
  out-of-band after disappearing from mDNS (A9-F5, unchanged — bounded by distinct device
  ids ever seen, not urgent).
- `swift test --parallel` flaked on 4 different, unrelated, pre-existing timing tests across
  this session under unusually heavy concurrent-agent CPU load (`testMuteStashAndRestore`,
  `testLevelEmissionIsCoalescedToDisplayCadence`, `testCaptureCrashOverBudgetSurfacesError`
  ×2) while serial `swift test` stayed 907-917/917 clean every single time — see
  `test-suite-parallel-default.md` memory note. Not a regression from anything in this plan;
  same root-cause category as the already-fixed `waitFor` 2s→8s poll-ceiling widening
  documented there. Worth widening those 3 tests' own timeouts in a future pass if it
  recurs on a quieter machine (i.e. confirm it's genuinely load-correlated, not something
  else) — not done here since it's out of scope for a memory-leak audit.

## Parallelization summary
- **W0:** 3 lanes parallel (the owner ∥ merge ∥ residual audit).
- **W1:** 7 lanes fully parallel — disjoint file ownership verified (NB+AppDelegate / LPE /
  Probe / C files / NCC+PAC logging / DACP / LMV).
- **W2:** T8→T9→T10 strictly sequential (shared files) ∥ T11 ∥ T12 ∥ T13 ∥ T14.
- **W3:** T15 critical path; T16 ∥ T17 alongside (disjoint).
- **W4:** serial gate.
- Hot-file rule holds: `NativeBackend.swift` has exactly one owner per wave (T1 → T12 → T16).

## Model mix (pre-critic)
2× opus·high, 1× opus·xhigh, 2× opus·medium, 1× sonnet·high, 3× sonnet·medium, 3× sonnet·low,
2× haiku·medium, 3× haiku·low + Firefox plan's own table. Assignments justified by residual
ambiguity, then challenged by a model-critic pass — **verdict 2026-07-23: 0 of 19 flagged,
no over-provisioning found** (spec quality + lead's line-review gate carry the cheap tiers).

## Guardrails (standing, non-negotiable)
- Live audio testing is **owner-only**; agents verify silently.
- **No merge to `main` without the owner's explicit go-ahead**; passing tests ≠ ready.
- Main checkout is a live workspace — never touched.
- New tests subclass `IsolatedTestCase`; pre-commit Guard 4 runs the full parallel suite.
