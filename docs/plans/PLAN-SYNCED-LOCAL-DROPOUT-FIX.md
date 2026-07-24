# Plan — Fix the synced-local mixed-selection AirPlay dropout

Status: **EXECUTED AND MERGED TO MAIN, 2026-07-24.** T1–T9 built as planned. Live testing (T7) surfaced four additional bugs beyond this plan's original scope, all fixed in the same pass before merge: a pre-existing capture-side sample-rate mismatch causing pitch-up on plain single-AirPlay playback (unrelated to T1–T3, never caught before since this was the first live by-ear test of the whole feature); a concurrency race in T2's rebind recovery found by adversarial review (deselect-during-recovery could leave a zombie AirPlay session); the Mac speaker's own meter never populating in a mixed selection (a pre-existing gap between the synced-local sink and per-device metering); and a redundant full AirPlay session reset firing on every Mac+AirPlay connect, adding unnecessary connect latency (a genuine T2 regression, fixed by distinguishing device/rate-change rebuilds from sink-attach rebuilds). Temporary `AIRPLAY_AUDIO_DIAG`-gated connect-latency logging was added to help characterize the residual ~5s connect-to-audio time (by-design AirPlay/sync buffering vs. anything further to fix) — still open as of merge.
Produced via `/plan`. Root-cause evidence: memory `synced-local-mixed-selection-dropout-diagnosis` (live 2026-07-24). Feature plan: `docs/plans/synced-local-airplay-plan.md` (on `claude/synced-local-airplay`).

---

## A. End state (one paragraph)

Adding the Mac's built-in speakers to an output set that already streams to one or more AirPlay devices no longer silences AirPlay. The whole-system capture path recovers from a nominal-sample-rate renegotiation (48↔44.1 kHz) exactly the way the per-app path already does — a `kAudioDevicePropertyNominalSampleRate` listener on the tapped device drives a tap rebuild, AND the whole-system AirPlay session is reset (rebind) on that rebuild so the receiver picks up the fresh timeline instead of staying desynced/silent (Part A, the recovery safety-net). Additionally, the local sink renders at the speakers' native rate so opening the device never forces the renegotiation in the first place (Part B, the root-cause fix). Both are verified by hermetic unit tests where possible; final correctness is Alec's live by-ear test with real AirPlay + Mac-speaker hardware.

---

## B. Decisions (Alec, 2026-07-24) — all questions resolved

**Q0 (BLOCKING) — Which branch does this fix belong on?**
**Decided: Option 1.** Build on the `claude/synced-local-airplay` branch/worktree, where `SyncedLocalSink.swift` (Part B's target) actually exists. Executing agents must target that worktree, not `claude/synced-local-dropout-fix-34b73e` (this plan doc's current home, off main). An earlier approved copy of this plan is already committed there (`fd0663a`) — treat this file as the version of record and reconcile/replace that copy when work starts there.

**Q1 — Direction A, Direction B, or both?**
**Decided: both (my recommendation).** B (native-rate render) prevents the renegotiation trigger; A (listener + session reset) is the safety-net for any other cause of a silent tap (a mic grab forcing voice-processing mode, an unrelated app changing the device rate). Build A1+A2 and B together, belt-and-suspenders, matching the per-app path's proven shape.

**Q2 — Is Part A actually two sub-parts (listener AND session reset)?**
**Decided: yes, confirmed in code** — build A1 (listener, T1) + A2 (session reset, T2) together, per Q1. `CaptureControlling` has no `onStateChange` member (`NativeBackend.swift:3469-3492`); without it a rebuilt tap still stays silent, mirroring the per-app path's proof (`resetAirPlaySessionForRoutedApp`, `:1463-1487`, called on recapture at `:1422-1426`).

**Q3 — Fix the meter/tap-health disconnect in the same pass?**
**Decided: Option 2 — add a real health indicator in this pass (the opposite of my recommendation).** Alec wants the meter (or a new adjacent indicator) to reflect whether audio is actually reaching the AirPlay receiver, not just capture-side RMS, so a future silent-tap-style failure is visible in the UI instead of hiding behind a moving meter. Scoped minimally as new task **T8** (plus test task **T9**) below — a health *signal*, not a UI redesign. The most direct proxy available for "the session had to be recovered" is the exact same recapture/rebind detection T2 already builds (`onStateChange` → recapture detection → rebind); T8 taps that signal rather than inventing a new receiver-side probe (no such probe exists in the codebase, and building real RTP-ACK/receiver-side confirmation would be a materially larger, speculative scope Alec hasn't asked for). Real UI/visual design for how this surfaces (badge, color, copy) is explicitly a **follow-up**, not this pass — T8 exposes the signal to the UI layer as a `BackendEvent` field/case; a dedicated design pass can decide how it's drawn later.

**Q4 — Native render rate: read once, or follow live?**
**Decided: read once (my recommendation).** Read the device native rate once at `SyncedLocalSink` construction; re-read each time synced-local toggles on. A mid-session device swap to a different-native-rate device isn't followed until the next toggle (Part A's rebuild still keeps AirPlay alive in that window; only local phase-alignment could drift). Full dynamic follow deferred.

---

## C. Task list

Anchors verified on this branch (coordinator/backend code is identical to the synced-local branch, which has main merged in). `SyncedLocalSink.swift` anchors are from `claude/synced-local-airplay`.

### T1 — Port the nominal-sample-rate listener into the whole-system tap (Part A1)
- files: `AudiouterCore/Sources/AudiouterCore/NativeCaptureCoordinator.swift` — `CoreAudioSystemTap` (class at `:776`; `createAggregate()` `:896`, `createAndStart()` `:817`, `teardown()` `:1041`, `installDefaultDeviceListener()` `:1015`).
- what: Store the tapped output device id where `createAggregate()` resolves `outputID` (`:903`). Add `installSampleRateListener()`/`removeSampleRateListener()` on `kAudioDevicePropertyNominalSampleRate` modeled EXACTLY on `PerAppCaptureCoordinator.swift:952-977`, routing the notification into the existing `onDefaultDeviceChanged` (→ `handleDeviceChange` → `recreateTap`). Call install in `createAndStart` after the aggregate exists; call remove in `teardown()`. Register add/remove on this class's existing `listenerQueue` (`:806`) — do NOT copy the per-app `nil` queue.
- kind: new-code
- depends_on: —
- recommended_model: sonnet 5 — mechanical port of a proven, well-documented sibling; low algorithmic novelty but touches a live HAL listener add/remove pair (symmetry matters).
- recommended_effort: medium — must get add/remove-queue symmetry and teardown ordering right, but the template exists.
- verify: AUTOMATABLE — unit test (T4) drives a simulated nominal-rate notification through the seam and asserts a rebuild; `git grep -c NominalSampleRate NativeCaptureCoordinator.swift` > 0; `swift test --parallel` green. Does NOT prove real-hardware recovery (that's T7, live).

### T2 — Whole-system AirPlay RTP session reset on tap rebuild (Part A2)
- files: `AudiouterCore/Sources/AudiouterCore/NativeBackend.swift` — `CaptureControlling` (`:3469-3499`), coordinator wiring (`:861`), recapture-detection precedent (`everCapturedBundleIDs`/`isRecapture` `:1413-1426`), `resetAirPlaySessionForRoutedApp` (`:1463`), `enqueueRebindRecovery`/`performRebindRecovery` (`:1506`/`:1562`), whole-system output set `added`/`desiredOn` (`:192`/`:282`), whole-system bind `engine.addOutput(_:streamId:)` on stream 0 (`:1808`).
- what: Add `var onStateChange: (@Sendable (NativeCaptureCoordinator.State) -> Void)?` to `CaptureControlling` with a default no-op so existing fakes compile. Wire `captureCoordinator?.onStateChange` in `start()` (near `:861`). Detect a whole-system RE-capture (a `.capturing` transition that is NOT the first — mirror the `everCaptured` flag) and, on recapture, reset the whole-system AirPlay session by rebinding every device in the selected output set (`added`/`desiredOn`, stream 0) via a whole-system analogue of `resetAirPlaySessionForRoutedApp`. Reuse `enqueueRebindRecovery`/`performRebindRecovery` (generalize to a stream-0 / no-per-app-stream rebind); keep the single-flight `rebindRecoveryGen` discipline.
- kind: backend
- depends_on: — (can develop in parallel with T1; wire-up reads state the coordinator already publishes)
- recommended_model: opus 4.8 — correctness-critical, high blast-radius: touches the shared engine bind/rebind machinery and the `CaptureControlling` seam that every fake conforms to; a wrong reset thrashes real receivers. This is the make-or-break task.
- recommended_effort: high — concurrency-sensitive (stateQueue + bindTail + generation single-flighting) and must not regress per-app rebind.
- verify: AUTOMATABLE — unit test (T4) with an engine spy asserts a simulated whole-system recapture issues removeOutput→addOutput per selected device exactly once and is single-flighted; assert all `CaptureControlling` fakes still compile. Does NOT prove the receiver actually un-mutes (T7, live).

### T3 — Render the local sink at the device-native rate (Part B)
- files: `AudiouterCore/Sources/AudiouterCore/SyncedLocalSink.swift` (`SyncTiming` rate scaling; `renderSampleRate`/`connectionFormat`; ring sizing) [branch `claude/synced-local-airplay`]; the base-resample point where the 44.1 kHz fan-out feeds the sink; `OwnToneBackend.swift`/`makeBackend` construction rate; reuse the device-rate read idiom in `LocalOutputLatency.swift`.
- what: Read the tapped device's native `kAudioDevicePropertyNominalSampleRate` (house rule: from `kAudioHardwarePropertyDefaultOutputDevice`, NEVER `DefaultSystemOutput`). Render the sink at that native rate so opening the device forces no renegotiation. Base-resample the 44.1 kHz feed UP to the native rate ONCE before the ring; keep any existing `FractionalResampler` as a ±ppm drift corrector only (it must NOT do base conversion). Scale `SyncTiming`/delay math off the render rate. Remove any hardcoded 44100.
- kind: new-code
- depends_on: Q0 (must be on the synced-local branch), Q1/Q4 (locked)
- recommended_model: opus 4.8 — real-time DSP on the render thread; the pitch/frame-count and phase-alignment logic is where a subtle bug (e.g. +8.8% pitch) hides and costs a whole live-test cycle. RT path must stay alloc/lock-free.
- recommended_effort: xhigh — resample-ratio correctness, latency-budget folding into sync, and RT-safety together.
- verify: AUTOMATABLE (offline/synthetic, T5) — 44.1 input rendered at 48 kHz yields correct frame counts and no pitch shift; `SyncTiming` delays scale with render rate; resampler is pass-through at ratio 1; RT path uses the `stateLock.try()` idiom. `swift test --parallel` green. Real phase-alignment by ear is T7 (live). NOTE: does NOT share a hot file with T1 (see self-critique) — but see risks re latency budget.

### T4 — Tests for Part A
- files: `AudiouterCore/Tests/AudiouterCoreTests/NativeCaptureCoordinatorTests.swift`, `NativeBackendTests.swift` (new cases subclass `IsolatedTestCase`).
- what: Simulated nominal-rate notification → `recreateTap` fires (via the injected fake tap seam). Whole-system recapture → exactly-once rebind per selected device via an engine spy; assert single-flighting and that per-app rebind is unregressed. No real audio, not in the routine/automated audio-playback suite.
- kind: test
- depends_on: T1, T2
- recommended_model: sonnet 5 — test authoring against existing fakes/spies; mechanical but needs care to exercise the recapture edge.
- recommended_effort: medium
- verify: AUTOMATABLE — `swift test --parallel` green; new cases fail if T1/T2 reverted.

### T5 — Tests for Part B
- files: `AudiouterCore/Tests/AudiouterCoreTests/SyncedLocalSinkTests.swift`, `SyncedLocalFanoutTests.swift`, sync-offset/phase tests (subclass `IsolatedTestCase`) [synced-local branch].
- what: 44.1 input rendered at 48 kHz = right frame count + no pitch shift; `SyncTiming` delays scale with render rate; resampler pass-through at ratio 1; sync-offset alignment (not just pitch — the extra resample's latency must fold into the delay).
- kind: test
- depends_on: T3
- recommended_model: sonnet 5 — synthetic-signal test authoring.
- recommended_effort: medium
- verify: AUTOMATABLE — `swift test --parallel` green.

### T6 — Dev-notes writeup
- files: `dev/notes/` (worktree only, NEVER main).
- what: Record the two-part fix and the Forums-825780 root cause next to the per-app note; note the `CaptureControlling.onStateChange` gap finding and the new tap/RTP health signal (T8).
- kind: docs
- depends_on: T1, T2, T3, T8
- recommended_model: haiku 4.5 — prose summary of decided work.
- recommended_effort: low
- verify: AUTOMATABLE (trivial) — file exists, links resolve.

### T8 — Tap/RTP health signal (Q3: real health indicator, minimal scope)
- files: `AudiouterCore/Sources/AudiouterCore/NativeBackend.swift` (T2's `onStateChange` wiring and recapture detection, `:1413-1426`; `emit(_:)` at `:3438`); `AudiouterCore/Sources/AudiouterCore/OutputBackend.swift` (`BackendEvent` enum, `:23` — add a case here, e.g. `streamHealth(id: String, recovering: Bool)`, alongside the existing device-keyed `.level`/`.deviceUpdated` cases).
- what: Alec wants the UI to be able to tell when a stream had to be silently recovered, not just see a moving capture-side meter (Q3 finding: `.level` is RMS on the CAPTURED buffer, `NativeCaptureCoordinator.handleBuffer` → `emitLevel` — it says nothing about whether audio is reaching the receiver over RTP). Rather than build a new receiver-side probe (no such mechanism exists, and one would be a much larger, speculative scope), reuse T2's own recapture/rebind signal as the health proxy: when `onStateChange` fires a whole-system recapture and a rebind is enqueued (`enqueueRebindRecovery`), emit a new `BackendEvent` (e.g. `.streamHealth(id:, recovering: true)`) for the affected device(s); emit `recovering: false` once `performRebindRecovery` completes. This is a signal only — no meter redesign, no new view. How it's drawn (badge/color/copy) is an explicit follow-up for a real UI/design pass, not this task. Keep the health flag boolean/enum-simple (e.g. `.healthy` / `.recovering`), not a numeric score.
- kind: backend
- depends_on: T2 (needs `onStateChange`/recapture detection wired first — same file, sequence after T2 on the same or a coordinating agent)
- recommended_model: sonnet 5 — plumbing a new event off an already-built signal; low algorithmic novelty, but touches the shared `BackendEvent` enum every consumer switches over exhaustively (or has a default case) — verify nothing else breaks.
- recommended_effort: medium — mechanical, but must find and update every exhaustive `switch` over `BackendEvent` (or confirm a default case) and get the recovering→healthy transition timing right (must clear on rebind completion, not immediately on detection, or it lies the other way).
- verify: AUTOMATABLE — unit test (T9) simulates a recapture and asserts `.streamHealth(recovering: true)` fires before the rebind and `.streamHealth(recovering: false)` after `performRebindRecovery` completes; `swift test --parallel` green. Does NOT prove the indicator is visible/legible in real UI (that's a follow-up design pass, out of scope here) — T7 live test only confirms the underlying event fires correctly during a real recovery, not its visual presentation.

### T9 — Tests for T8 (health signal)
- files: `AudiouterCore/Tests/AudiouterCoreTests/NativeBackendTests.swift` (subclass `IsolatedTestCase`), reusing the T4 recapture/engine-spy harness.
- what: Simulated whole-system recapture emits `.streamHealth(recovering: true)` then `.streamHealth(recovering: false)` in the right order relative to the rebind; no `.streamHealth` events on the normal (non-recapture) path; existing `BackendEvent` consumers/fakes still compile.
- kind: test
- depends_on: T8
- recommended_model: sonnet 5 — test authoring against an existing harness (T4's), mechanical event-ordering assertions.
- recommended_effort: low
- verify: AUTOMATABLE — `swift test --parallel` green; fails if T8 reverted.

### T7 — Gated by-ear live test (Alec only)
- files: none (manual).
- what: 1 AirPlay ✓ → 2 AirPlay ✓ → add Mac: AirPlay keeps playing IN SYNC, no silence, no pitch/judder → deselect Mac: AirPlay continues cleanly. Also provoke a non-sink rate change (grab the mic in another app) to exercise Part A's safety-net, and confirm the T8 health signal fires (check logs/debug hook — no dedicated UI yet) during a real recovery. Native single-instance only (PTP 319/320 exclusive to one worktree).
- kind: test (manual/live)
- depends_on: T4, T5, T9 (green suite first)
- recommended_model: n/a (human)
- recommended_effort: n/a
- verify: LIVE HUMAN HARDWARE ONLY — an agent must NEVER claim this done from automated tests. This is the sole authority on audio-routing correctness (standing rule).

---

## D. Parallelization

Hot files: `NativeCaptureCoordinator.swift` (T1) and `NativeBackend.swift` (T2, and now T8) — DIFFERENT files from each other, so T1 and T2 run concurrently. `SyncedLocalSink.swift`/`OwnToneBackend.swift` (T3) don't collide with either. T8 shares `NativeBackend.swift` with T2 but is sequenced strictly after it (T8 depends_on T2), so there's no real contention — it's a second pass over a file T2 just finished, not concurrent editing.
- **Wave 1 (all concurrent):** T1 ∥ T2 ∥ T3. No shared hot file among them.
- **Wave 2:** T4 (after T1+T2) ∥ T5 (after T3) ∥ T8 (after T2, same-file follow-on — either the T2 agent continues onto T8, or a fresh agent starts only once T2's diff lands, to avoid a merge race on `NativeBackend.swift`).
- **Wave 3:** T9 (after T8) ∥ T6 (docs, after T1/T2/T3/T8).
- **Wave 4:** T7 (Alec, live) — gated on T4, T5, T9 all green.
- Critical path: **T3 (opus/xhigh) → T5 → T7.** T2 → T8 → T9 → T7 is a shorter chain and does not extend the critical path (T8/T9 are both sonnet/medium-low). T2 is still the make-or-break correctness task, just not the longest chain.

(Correction vs the earlier approved copy: that copy serialized T1+T3 on `NativeCaptureCoordinator.swift`. On re-reading, Part B's base-resample point can live at the `SyncedLocalSink` fan-out consumer rather than inside `CoreAudioSystemTap`, so T1 and T3 need not edit the same file. If, during T3, the base-resample MUST be inserted inside `NativeCaptureCoordinator.swift`'s fan-out, then T1 and T3 DO contend — in that case serialize them on one agent owning that file. Flag at T3 start.)

---

## E. Recommended execution

**agents (watched).** 7 code/test tasks plus 2 gates, judgment-heavy real-time-audio on a correctness-critical shipping path, with human-gated decisions (Q0–Q4, now all resolved) that reshaped the work (T8/T9 added) and live findings likely to require further course correction. Steerable, visible transcripts beat workflow overhead here. Not `workflow` (tasks are non-uniform and judgment-heavy, and per-task effort is already well-separated — only T2 and T3 need opus, T8/T9 are cheap sonnet add-ons). Not `inline` (too many tasks, real parallelism across 4 waves). Rationale tie-breaker: default to `agents` on a close call — and this isn't even close given T2/T3's risk plus T8's same-file follow-on needing a clean handoff.

**Review gate (added 2026-07-24):** there is no standing "supervisor agent" watching subagents run in real time — visibility during execution comes from Alec reading live transcripts and redirecting via SendMessage, and from Claude reading each agent's actual diff (not its self-report) when it lands. To backstop that, add an explicit adversarial code-review pass on T2 and T3 specifically (the two opus/high-risk correctness tasks) before either is marked done: run `/code-review` (or an equivalent independent review agent) against each task's diff as soon as it lands, in parallel with that task's own test task (T4 for T2, T5 for T3). A finding that survives adversarial review blocks moving that task to "done" and blocks T7 (Alec's live test) until resolved — it does not block the other Wave-1 tasks from proceeding.

---

## F. Test + docs/registry impact
- New/changed unit tests: T4 (`NativeCaptureCoordinatorTests`, `NativeBackendTests`), T5 (`SyncedLocalSinkTests`, `SyncedLocalFanoutTests`, sync/phase), T9 (`NativeBackendTests`, health-signal ordering). All subclass `IsolatedTestCase`; all hermetic (no real audio); NOT added to the routine automated audio-playback suite (standing rule).
- Docs: T6 dev-note (worktree only), now also covering the T8 health signal. This plan doc itself. No registry/config changes.
- `CaptureControlling` gains `onStateChange` (default no-op) — every conformer/fake compiles unchanged (verify in T4).
- `BackendEvent` gains a new case (T8, e.g. `.streamHealth(id:, recovering:)`) — verify every exhaustive `switch` over `BackendEvent` (or a default case) still compiles (verify in T9).

## G. Open risks / confirm during execution
- **No live supervisor agent exists:** Alec asked whether a dedicated agent could watch subagents operate in real time; it doesn't exist as a standing capability. Mitigated via (a) watched-`agents` mode's live transcripts + SendMessage steering, and (b) the review gate above for T2/T3 specifically.
- **T2 is make-or-break:** a rebuilt tap without the session reset stays silent. Small chance the fresh mach→monotonic pts reseed on rebuild self-heals the whole-system stream where per-app didn't — the "deselecting Mac doesn't recover" symptom argues it does not; confirm in T2's spy test AND live.
- **T3 latency budget:** the added 44.1→native resample adds a few ms that must fold into `SyncTiming` so local stays phase-aligned with AirPlay — verify sync in T5, not just pitch.
- **Rate-bounce coalescing:** rapid 44.1→48→44.1 must coalesce; `recreateTap`'s `pendingDeviceChange` (STABILITY C6, `NativeCaptureCoordinator.swift:431-450`) should cover it — confirm the new listener rides it and doesn't thrash the rebind.
- **House rule:** native rate read from `kAudioHardwarePropertyDefaultOutputDevice`, never `DefaultSystemOutput` — grep-verify any touched selector.
- **Single-instance live test:** PTP 319/320 exclusive — only one worktree runs T7.
- **T8 scope discipline:** T8 is a signal only (a `BackendEvent` case), not a UI/visual redesign — confirm the executing agent doesn't scope-creep into meter/badge design work Alec hasn't asked for; flag a real UI design pass as a separate follow-up if he wants the indicator actually drawn somewhere.
- **T8 timing correctness:** `recovering: false` must fire on rebind *completion* (`performRebindRecovery` done), not on detection — an early clear would misreport a still-recovering session as healthy, defeating the point of Q3.
