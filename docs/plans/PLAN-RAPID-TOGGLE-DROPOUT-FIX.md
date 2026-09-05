# Plan — Fix the rapid-toggle synced-local dropout

Status: **T1+T2 (`32a632d`), T3 (`60ddf63`) and T4 EXECUTED AND COMMITTED, 2026-07-25. The §E adversarial
review gate HAS now run — verdict SAFE on the primary regression question, but it produced 7 findings, one of
which (H-1, §H below) questions whether this fix actually closes the reported bug at slower click cadences.
T5 (the owner's live test) is NOT started and is gated on the H-1 decision. NOT MERGED anywhere —
`claude/warm-signal-full` only.**
Ported by hand onto today's `AudioutCore` on branch `claude/rapid-toggle-detector-2` (2026-09-02): detector #2, the T3 seam and tests, the `stop()` sink teardown and the H-6 metering fix. T5 is still owed.
Produced via `/orchestrate`. Root-cause evidence: live-tested by the owner on `claude/warm-signal-full`, diagnosed from `~/Library/Logs/Audiout/telemetry.jsonl` (19 whole-system tap rebuilds in 2.5s of rapid clicking, `desiredOn` unchanged across all of them). Distinct from, but related to, `docs/plans/PLAN-SYNCED-LOCAL-DROPOUT-FIX.md` (T1–T9, already merged to main) — that plan fixed AirPlay going silent on a single Mac-add caused by a *device sample-rate renegotiation*; this plan fixes a *different* trigger: the whole-system tap rebuild that `setSyncedLocalSink` itself forces on every attach/detach, which storms under rapid repeated clicking.

---

## A. End state (one paragraph)

Rapidly selecting/deselecting the Mac as a local output while an AirPlay device is playing no longer permanently silences audio, and no longer produces audibly out-of-sync playback. A burst of rapid toggling collapses to at most one real synced-local-sink transition (250ms trailing-edge debounce) instead of one per click, which by itself kills both the whole-system-tap-rebuild storm and the sink's session-anchor re-fire storm. If the burst genuinely churned (≥2 coalesced toggles), the app also re-establishes the AirPlay receiver's RTP session exactly once after the dust settles, as a safety net — a normal single toggle can never take that branch, so the earlier fix that made single-toggle connects fast (no redundant reset) is not regressed.

---

## B. Decisions (owner's call, 2026-07-25) — all questions resolved

**Q1 — Where does the fix live?**
**Decided: in `NativeBackend.swift` (recommended option).** This is the file that actually drives BOTH the tap rebuild and the sink re-anchor, so one fix there addresses both symptoms (silence and out-of-sync). A narrower fix inside `NativeCaptureCoordinator.setSyncedLocalSink` was considered and rejected — it would only address the tap-rebuild half, not the sink-anchor-reset half.

**Q2 — Add a safety-net RTP re-sync after a churny settle?**
**Decided: yes (recommended option).** Reuse the existing, already-single-flighted `resetAirPlaySessionForWholeSystem()`, guarded to fire only when the settle absorbed ≥2 distinct toggle decisions. Accepts one brief extra silence on a genuinely rapid-toggle burst, in exchange for guaranteed recovery instead of the current permanent silence.

**Q3 — Debounce window length?**
**Decided: 250ms (recommended option).** Comfortably outlasts rapid clicking; negligible added delay on a normal single toggle.

**Q4 — Leading-edge or trailing-edge execution?**
**Decided: trailing-edge only (planner's recommendation, not separately re-litigated).** Simpler, guarantees the last click's decision wins. Adds the 250ms window as a delay even on a normal single toggle — an accepted, explicit tradeoff.

**Q5 — Touch `SyncedLocalSink.swift`'s session-anchor timing directly?**
**Decided: no, not in this pass (recommended option).** Fix the storm upstream and let the anchor settle as a side effect of firing at most once. If T7 (live test) still shows residual out-of-sync audio after this fix, that would need a separate, evidence-driven follow-up task — not pre-emptively touching real-time sync code without proof it's still broken.

---

## C. Task list

### T1 — Coalesce rapid synced-local enable/disable transitions
- **files:** `AudioutCore/Sources/AudioutCore/NativeBackend.swift` — `setOutputSet`'s synced-local decision, new `scheduleSyncedLocalSettleLocked()`/`fireSyncedLocalSettle()`, new `stateQueue`-confined fields (`syncedLocalSinkApplied`, `pendingSyncedLocalSettle`, `syncedLocalCoalescedCount`, `syncedLocalSettleWindow`).
- **what:** Record the desired synced-local state and (re)schedule a 250ms trailing-edge settle instead of executing each transition immediately, mirroring the existing `armWakeWatchdog` debounce idiom. On fire, run the real transition only if desired differs from applied, so a burst collapses to at most one `applySyncedLocalSinkTransition` call.
- **kind:** backend
- **depends_on:** — (start of the chain)
- **model / effort used:** opus 4.8 / high (kept at planner's original assignment — a cost-check flagged this as a possible sonnet/medium downgrade, but the owner confirmed keeping the stronger model given this edits the app's most concurrency-sensitive audio file).
- **status: DONE, committed `32a632d`.**
- **verify:** `swift build --build-system native` clean ✓. Full suite (`swift test --build-system native --parallel`, 1264 tests) green ✓ (via the repo's own pre-commit Guard 4, run independently at commit time). Existing `NativeBackendSyncedLocalSelectionTests` (6 cases) pass with the debounce in place ✓. **New regression tests specific to the debounce/churn behavior are NOT yet written — that's T3 below.**

### T2 — Guarded safety-net RTP re-sync on a churny settle
- **files:** same file as T1, same commit — `fireSyncedLocalSettle()`'s churn branch, reusing the existing `resetAirPlaySessionForWholeSystem()`.
- **what:** If the settle absorbed ≥2 distinct toggle decisions (churn detected), call `resetAirPlaySessionForWholeSystem()` exactly once after the transition. A normal single toggle (coalesced count = 1) structurally can never enter this branch.
- **kind:** backend
- **depends_on:** T1 (same file, same agent, sequenced after)
- **model / effort used:** opus 4.8 / high (same reasoning as T1).
- **status: DONE, committed `32a632d`** (same commit as T1 — they were implemented together by one agent, per the plan's "serialize on one agent" call).
- **verify:** same as T1 — build clean, existing smoke tests pass. **No dedicated test yet asserting "exactly one reset on a churny settle, zero on a single toggle" — that's T3.**

### T3 — Hermetic regression tests
- **files:** likely `AudioutCore/Tests/AudioutCoreTests/NativeBackendSyncedLocalSelectionTests.swift` (extend) or `NativeBackendTests.swift` — whichever the codebase's existing convention points to; new cases subclass `IsolatedSuite`.
- **what:** Prove, hermetically (no real audio): (a) a rapid toggle burst produces at most one real transition, not one per click; (b) a normal single toggle still works and takes zero reset calls — the single most important case, since getting this wrong reintroduces the exact "redundant reset on every connect" bug `PLAN-SYNCED-LOCAL-DROPOUT-FIX.md`'s T2 follow-up already fixed once; (c) a net-no-op burst (e.g. on→off→on landing back where it started) does nothing at all — no transition, no reset; (d) a churny settle that lands on a genuinely new state fires the transition plus exactly one reset; (e) `stop()` cancels a pending settle so it can't fire against a torn-down backend.
- **kind:** test
- **depends_on:** T1, T2
- **recommended_model / effort:** sonnet 5 / medium.
- **status: DONE, committed `60ddf63`.** Six cases, not five: (a)/(c)/(e) extend
  `NativeBackendSyncedLocalSelectionTests.swift`; (b)/(d) live in `NativeBackendTests.swift`, which is the
  only harness that can put a device into `added` so a reset assertion (observed as one engine flush, `SpyEngine.flushedIDs`, in the port) is not VACUOUS — (d) is the
  positive control that proves the harness *can* emit one, which is what makes (b)'s zero-reset assertion
  meaningful. Sixth case pins the production default window. The settle window became an injectable
  designated-init parameter (`syncedLocalSettleWindow`, default 0.25 at T3, widened to 0.5 in the remediation pass below) following the file's existing
  `processNotYetAudibleRetryDelay` seam shape; production has exactly one construction site and it goes
  through the convenience init, which cannot override it.
- **also in `60ddf63`, beyond T3's scope:** a real `stop()` bug the review surfaced mid-flight — `stop()`
  force-reset the desired/applied flags without ever calling `applySyncedLocalSinkTransition(enable: false)`,
  leaving a genuinely running sink attached. Now torn down on `captureControlQueue`, ordered like the
  `captureCoordinator.stop()` immediately below it. Independently re-verified as correct by the review agent.
- **verify:** `swift build` clean ✓. **`swift test --parallel --num-workers 4` (the repo's official gate
  command, per `a675d95`): 1271/1271, exit 0 ✓** — re-run independently, not taken from the agent's report.
  Caveat recorded honestly: under an UNCAPPED `swift test --parallel` (harsher than the repo standard), two
  pre-existing timing-sensitive tests (`testProcessNotYetAudibleRetriesStopOnDeRoute`,
  `testRebindRecoveryGivesUpAfterMaxAttempts`) fail on contention; both pass in isolation and under the
  4-worker cap. The pre-T3 tree passed uncapped, so T3's new wall-clock waits plausibly tipped them — see H-3.

### T4 — Dev-notes writeup
- **files:** `dev/notes/synced-local-mixed-selection-dropout-fix.md` (extend — this is the existing note whose §7 "T2 latency regression" section documents the exact prior fix this new fix must not regress) or a new sibling note if the existing one is a poor fit once T3 is read.
- **what:** Document the rapid-toggle storm root cause (STABILITY(C6) coalescing only protects against a rebuild landing while already mid-rebuild — it does NOT protect against many back-to-back rebuilds that each complete cleanly before the next starts, which is what this bug actually was), the chosen fix location and debounce window, and the guarded safety-net reset's exact firing condition.
- **kind:** docs
- **depends_on:** T1, T2, T3
- **recommended_model / effort:** haiku 4.5 / low.
- **status: DONE** — `dev/notes/synced-local-mixed-selection-dropout-fix.md` §8, alongside the §7 fix it must
  not regress. Still owed as a small amendment: H-6 and H-7 below (both were found by the review running
  concurrently with the writeup, so §8 could not yet mention them).
- **verify:** file extended ✓, backticked symbols `git grep`-verified ✓.

### T5 — Gated by-ear live test (owner only)
- **files:** none (manual).
- **what:** With an AirPlay device playing, rapidly toggle the Mac's "Current Device" checkbox many times, leave it deselected → audio must keep playing (no permanent silence, matching the original confirmed repro). Then a single, unhurried select of the Mac while AirPlay plays → Mac and AirPlay audibly in sync (or, if not, that is new evidence Q5's "leave `SyncedLocalSink` alone" decision needs revisiting). Native single-instance only (PTP 319/320 exclusive to one worktree).
- **kind:** test (manual/live)
- **depends_on:** T3 green
- **recommended_model / effort:** n/a (human) — sole authority on audio-routing correctness; an agent must never claim this done from automated tests alone.
- **status: NOT STARTED** — T3 is green, so the original gate is clear, but the review changed what this test
  must cover. Two additions are now mandatory before it means anything:
  1. **Test the SLOWER cadence too (H-1).** The debounce only defends clicks landing inside 250ms of each
     other. Clicking about 3×/second is fully outside the window, so every click gets its own settle, the
     churn counter never reaches 2, and the storm returns with the safety net provably unreachable. A tester
     told only to "rapidly toggle" may click slower than 4×/s, reproduce the original silence, and conclude
     the fix failed — when in fact it was never armed. Test both a frantic burst AND a steady ~3/s tapping.
  2. **Add "select the Mac and a fresh AirPlay device together" (H-5).** The plan's existing wording only
     covers selecting the Mac while AirPlay is ALREADY playing — the case where the tap is already capturing
     and the ordering is unchanged by this fix. On a fresh combined connect the ordering DID change: the
     `.exclusionChange` tap rebuild now lands ~250ms into a live RTP session instead of at tap start.

---

## D. Parallelization

Single hot file (`NativeBackend.swift`) for T1/T2 — serialized on one agent, which is what happened. No real intra-code concurrency in this plan; it's one serialized fix chain plus tests plus docs.
- **Wave 1 (done):** T1 → T2, serial, same agent, same commit.
- **Wave 2 (not started):** T3.
- **Wave 3 (not started):** T4 (docs, after T1–T3).
- **Wave 4 (not started):** T5 (the owner, live) — gated on T3 green.
- **Critical path:** T1 → T2 → T3 → T5.

---

## E. Recommended execution

**agents (watched).** Only ~4 code/doc/test tasks on a single serialized critical path, but T1/T2 are opus/high, judgment-heavy real-time-audio correctness work on the app's hottest file, with several genuinely open design questions (Q1–Q5) that reshaped the work before it started. Live transcripts and steering were worth more than workflow determinism here. Followed as planned for T1/T2; T3 was queued the same way but not yet run.

**Review gate (per the plan, not yet executed):** an adversarial `/code-review` pass on the T1+T2 diff (`32a632d`) before calling this fully done — not yet run. Given how easy it would be to accidentally reintroduce the "redundant reset on every normal connect" regression, this should happen before or alongside T3, not skipped.

---

## F. Test + docs/registry impact
- New hermetic cases planned for T3 (file TBD — see T3 above), all `IsolatedSuite`, none added to the routine automated audio-playback suite (standing rule).
- No protocol/enum signature changes were needed (reuses existing `resetAirPlaySessionForWholeSystem`) — no exhaustive-`switch` fallout expected.
- Docs: T4 extends the existing dev-note; this plan doc itself is the tracking artifact.

## G. Open risks / confirm during execution
- **T3 is the main gap right now.** T1+T2 are committed and build-verified, and the existing (pre-fix) `NativeBackendSyncedLocalSelectionTests` still pass, but there is no test yet that would fail if this exact fix were reverted — i.e., no regression protection yet for the bug just fixed.
- **The adversarial review gate has not run.** The sharpest failure mode (a mis-guarded safety-net reset firing on every normal connect) would show up as added connect latency on ordinary use, not as a test failure unless T3 specifically asserts a zero reset-call count on the single-toggle path — make sure T3 covers this explicitly.
- **Q5 is provisional, not proven.** "Don't touch `SyncedLocalSink.swift`" was a bet that fixing the storm upstream is sufficient for the sync-timing symptom too. T5 (live) is what actually confirms or refutes that bet.
- **Single-instance live test:** PTP 319/320 exclusive to one worktree, same constraint as the related merged plan.

---

## H. Adversarial review findings (§E gate, RUN 2026-07-25, opus/high)

**Verdict on the question the gate existed to answer: SAFE.** A normal single toggle can never reach
`resetAirPlaySessionForWholeSystem()`. The load-bearing reason is subtle and worth protecting: the coalesce
counter increments once per **desired-state FLIP**, not once per `setOutputSet` call — it lives inside
`if wantSyncedLocal != self.syncedLocalSinkEnabled`. Since every settle exits with `desired == applied`, N
flips leave `desired != applied` only when N is odd, so the reset needs N ≥ 3. No single user action produces
three flips (traced through `GroupController.setDeviceSelected`'s auto-swap and current-device floor,
`activateGroup`, `setMainOut`, and `PopoverController.handleConnectionTransitions`' per-device failure loop,
where `ids` only shrinks monotonically). **If anyone ever moves the schedule call out of that `if`
("schedule unconditionally, decide at fire time"), the regression returns instantly and live-only.**
Queue discipline, cancellation/work-item lifetime, ordering across sleep/wake and stop()/restart: all clean.

| id | sev | status | finding |
|----|-----|--------|---------|
| H-1 | high | **FIXED** (cadence-independent arming + 0.5s window; see the dev-note's T6) | The 250ms window is the fix's only protection. At a ~330ms click cadence (~3/s, a comfortable sustained human rate) every click gets its own settle, `churned` is always false, and the tap storms exactly as pre-fix with the safety net structurally unreachable. Behaviour at that cadence is identical to before the fix. Mitigation direction: count REAL transitions over a rolling ~2s horizon and arm the reset on N≥2 regardless of coalescing, and/or rate-limit transitions rather than only debouncing them. |
| H-2 | med | **FIXED** (helpers now omit the argument; re-verified non-vacuous) | `syncedLocalSettleWindowProductionDefaultIsUnchanged` is VACUOUS. `makeBackend()` declares its own `= 0.25` and always forwards it, so the test pins the helper's literal, not the designated init's default. Change the real default to 2.5s and it stays green while every production Mac join/leave waits 2.5s. Must assert through a path that omits the argument. |
| H-3 | med | **FIXED** (0.15s windows) | The new tests shrink the window to 30–50ms, below scheduling jitter under parallel load; a burst split across two windows produces a false FAILURE. Confirmed empirically: uncapped `--parallel` now fails two timing tests that passed pre-T3. ~0.15–0.2s keeps the tests fast with real headroom (wait budgets are already 0.3–3s). |
| H-4 | med | **FIXED** (`GroupControllerSyncedLocalFlipTests`, 6 cases) — but see H-8, which it uncovered | No coverage at the layer where the regression would actually originate. All six cases drive `setOutputSet` directly, so nothing proves ONE user action yields at most one flip. A future edit making `applyRouting` a clear-then-set pair would reintroduce the latency bug with all six tests still green. Wants a `GroupController`-level test with a spy backend. |
| H-5 | med | folded into T5 | Fresh combined Mac+AirPlay connect: the `.exclusionChange` rebuild moved from tap-start to ~250ms into a live RTP session. The justification for skipping the session reset on an `.exclusionChange` was established for the OLD ordering. Only the live test can settle it. |
| H-6 | low | **FIXED** (`isMeterable` + the eager emit both moved to the applied state) | `isMeterable` reads the DESIRED flag, so the local row's meter leads physical audio by up to 250ms both ways (meter clears while the Mac still plays; moves while still silent). Cosmetic. Note: the "one-line fix" is really two places — `setOutputSet`'s eager `emitCombinedLevel` exists precisely because `isMeterable` flips immediately, so it would need re-pointing at `fireSyncedLocalSettle`. |
| H-8 | med | **OPEN** (new, surfaced by H-4's agent) | `GroupController` structurally cannot fan one user action into 2+ backend calls today — every routing entry point (`setDeviceSelected`, `setMainOut`, `activateGroup`) calls `setOutputSet` at most once per invocation, now locked by the six H-4 tests. But `PopoverController.handleConnectionTransitions`' per-device failure loop sits one layer ABOVE that and can plausibly call `setDeviceSelected` more than once per user gesture; it has no flip-counting coverage. Not a regression and not currently known to misbehave — the review traced it as safe because `ids` only shrinks monotonically there — but it is the one remaining place the "one action → at most one flip" property is unproven. Wants a `PopoverController`-level test. |
| H-7 | low | doc-only | The trailing edge has no max-wait cap, so a sustained sub-250ms cadence defers the transition indefinitely; and because an even flip count is a net no-op, a user ending a long burst on an even count sees their final click produce nothing — which will read as a dropped click. Accepted Q4 tradeoff; belongs in the §8 dev-note so it is not later re-diagnosed as a new bug. |

**Review-process note:** the review ran concurrently with T3 in the same worktree, so it reviewed a moving
tree (it snapshotted and re-diffed, and its quoted code is current). The T3 agent also committed despite being
instructed not to, which turned the intended pre-commit gate into a post-hoc review; its `git add` was at
least path-scoped, so T4's concurrent edits were not swept. Serialize or isolate next time.

### Remediation pass (H-1 / H-2 / H-3 / H-6)

Serialized onto one agent (all four touch `NativeBackend.swift` + its two test files). H-1 took both
halves the owner decided on — structural first, then the window — mirroring the memory-leak plan's
T8-before-T9/T10 sequencing: churn is now armed by EITHER ≥2 coalesced decisions in one settle OR ≥2
REAL applied transitions inside a rolling 2s horizon (monotonic `uptimeNanoseconds`), and the window
moved 0.25s → 0.5s. The zero-reset-on-a-single-toggle invariant is unchanged and still guarded;
`resetAirPlaySessionForWholeSystem` stays the single-flight mechanism (no second rate limiter added).
Details, including why 2s is the horizon and why the H-1 test uses a SHORTER window than H-3's floor,
are in the dev-note's T6 section. H-4/H-5/H-7 are untouched and still open.
