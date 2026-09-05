# Synced-local mixed-selection dropout fix (Plan-SYNCED-LOCAL-DROPOUT-FIX)

**IMPLEMENTED 2026-07-24.** Two-part fix for the critical bug that silences
AirPlay audio when the Mac's built-in speakers are added to a synced-local
selection. Root cause confirmed live vs. real Sonos + AirPort Express.

This note complements `p2b-synced-local-brief.md` (the delayline design)
with a diagnosis of the nominal-sample-rate renegotiation dropout and the
surgery needed to recover: adding a whole-system tap listener to match the
per-app routing's recovery pattern, plus rendering the local sink at the
device's native rate to prevent the renegotiation in the first place.

---

## 0. Root cause (confirmed live 2026-07-24)

When the Mac's built-in speakers are added to a Mac+AirPlay synced-local
selection, `SyncedLocalSink`'s `AVAudioEngine` opens the speakers. The
speakers report a nominal sample rate of 48 kHz (Apple Silicon Macs
default to 48 kHz on built-in output). This renegotiation forces the
tapped output device's nominal sample rate away from the 44.1 kHz default
(48 ↔ 44.1 kHz flip).

**Core Audio's process tap exhibits Apple bug Dev Forums thread 825780:**
when the tapped device's nominal sample rate changes, Core Audio continues
delivering PCM buffers at the full capture cadence (no sample loss or timing
break) but fills them with **all-zero frames** — silent output. The entire
tap output goes mute. This is an Apple-unresolved bug in Core Audio's tap
infrastructure, not a Audiout issue.

The whole-system `NativeCaptureCoordinator` monitors the tapped device for
IDENTITY changes (UID match), but the nominal sample rate change does not
change the device UID — only its rate property. The coordinator never
detects the change and never rebuilds the tap. AirPlay continues to receive
dead silence.

Re-adding AirPlay afterward produces pitched-up audio (~+8.8% = 48000/44100)
followed by judder and stream dropout. The tap has gone stale and the audio
pipeline is out of sync.

**Per-app routing already solves this for app-specific taps:**
`PerAppCaptureCoordinator.installSampleRateListener` (§1.1 below) monitors
each app's tapped device for `kAudioDevicePropertyNominalSampleRate` changes
and triggers a tap rebuild on detection. The per-app path does not suffer
from the mixed-selection dropout.

**Further architectural gap:** even with a rebuilt tap, a whole-system tap
rebuild does not currently reset the AirPlay RTP session. The session is
owned by `NativeBackend` and was seeded with the old tap's mach → monotonic
PTP mapping. A stale session stays silent even with fresh PCM. The per-app
fix resets sessions per-app via `resetAirPlaySessionForRoutedApp`; the
whole-system path never observes the coordinator's state changes and never
issues a reset (§1.2 below).

---

## 1. Two-part fix

### 1.1 Part A1: Port the nominal-sample-rate listener to the whole-system tap

**File:** `NativeCaptureCoordinator.swift`, method `CoreAudioSystemTap`.

**Change:** Add the same nominal-sample-rate listener that `PerAppCaptureCoordinator`
uses (lines ~952-977 in `PerAppCaptureCoordinator.swift`), modeled to the
whole-system tap's tapped device. The listener must:

1. Capture the `tappedOutputDeviceID` in `createAggregate()` (where the device
   is determined via `kAudioHardwarePropertyDefaultOutputDevice`).
2. Install the listener via `installSampleRateListener()` in `createAndStart()`.
3. Remove the listener via `removeSampleRateListener()` in `teardown()`.
4. Route property-change notifications into the existing `onDefaultDeviceChanged`
   path, which already calls `handleDeviceChange()` → `recreateTap()`.
5. Use the class's existing `listenerQueue` for add/remove (per-app uses `nil`,
   which defaults to the main queue; the whole-system path already manages
   its own queue explicitly).

**Verification:** nominal-sample-rate changes trigger `recreateTap()` via the
listener, confirmed by unit tests (T4, see §2.1). The listener fires before
the tap goes silent (Apple Forums 825780 side-effect window is milliseconds).

**House rule:** always read the device from `kAudioHardwarePropertyDefaultOutputDevice`,
never `DefaultSystemOutput` (alert-sound device) — see `tap-follows-default-output-device.md`.

### 1.2 Part A2: Whole-system AirPlay RTP session reset on tap rebuild

**File:** `NativeBackend.swift`.

**Change:** Add `onStateChange` callback to the `CaptureControlling` protocol
(default no-op so existing fakes compile). Wire `captureCoordinator?.onStateChange`
to be called whenever the coordinator rebuilds the tap.

**Gap finding:** `CaptureControlling` is a read-only protocol with no
state-change callback. Coordinators rebuild and notify nothing. `NativeBackend`
has no way to know a rebuild happened. This is the architectural seam the
fix closes.

In `NativeBackend`, upon `onStateChange` notification:

1. Add **recapture detection** mirroring the per-app pattern (`everCapturedBundleIDs`
   / `isRecapture` for whole-system, analogous to per-app stream logic).
2. Reuse `enqueueRebindRecovery()` / `performRebindRecovery()`, generalized to
   support **whole-system rebinds without a stream-id** (not all rebinds are
   per-app).
3. Emit a rebind command that unbinds then re-binds all selected devices (the
   `added` / `desiredOn` set that feeds `engine.addOutput(outputID)`), parallel
   to `resetAirPlaySessionForRoutedApp` but for the whole-system set.
4. Maintain single-flight generations to coalesce rapid rebuilds.

**Verification:** unit test (T4, see §2.1) asserts a simulated whole-system
recapture issues exactly one removeOutput → addOutput cycle per selected
device. All `CaptureControlling` fakes continue to compile.

### 1.3 Part B: Render the local sink at the device-native rate

**Files:** `SyncedLocalSink.swift` (render rate, connection format, ring sizing),
`OwnToneBackend.swift` (sink construction), `NativeCaptureCoordinator.swift`
(fan-out format).

**Rationale:** rather than wait for a tap rebuild to recover from the
renegotiation, avoid the renegotiation in the first place. Open the speakers
at their **native rate** (48 kHz) and base-resample the 44.1 kHz audio feed
up to 48 kHz once, before the delay ring. The nominal-sample-rate listener
(Part A1) is still essential as a safety net and for correct meter readings,
but preventing the renegotiation upfront eliminates the dropout window.

**Change:**

1. Read the device native rate once via `kAudioDevicePropertyNominalSampleRate`
   at sink construction time (reuse the pattern from `LocalOutputLatency.swift:83`).
   Re-read whenever synced-local is toggled on (dynamic mid-session tracking
   deferred to v2).
2. Set `SyncedLocalSink.renderSampleRate` to the device's native rate.
3. **Base-resample the 44.1 kHz fan-out up to the native rate ONCE, before the
   delay ring.** Reuse or add a `FractionalResampler` with a fixed ratio
   (e.g., 48000 / 44100 = 1.0884...). This is NOT the drift-correction
   resampler later in the chain — it does a one-shot base-rate conversion.
4. Update `SyncTiming` and ring sizing to scale from `renderSampleRate`.
5. Verify no hardcoded `44100` constants remain in the sink or fan-out path.

**Verification:** offline/synthetic tests (T5, see §2.2) confirm:

- No pitch error at 48 kHz rendering.
- Correct frame counts and ring buffer math.
- Real-time path stays allocation- and lock-free (`stateLock.try()` idiom).
- Sync-offset alignment (not just pitch compensation).

**Note:** `NativeCaptureCoordinator.swift` is a hot file shared with Part A1
(T1 + T3 serialize on one agent). Coordinate edits carefully.

---

## 2. Verification & test coverage

### 2.1 Part A tests (T4)

**Files:** `NativeCaptureCoordinatorTests.swift`, `NativeBackendTests.swift`.

**Simulated nominal-sample-rate change** drives `recreateTap()`:

```swift
testNominalSampleRateChangeTriggersRebuild()
  // Simulate property notification on tapped device
  // Assert recreateTap() was called
```

**Whole-system recapture triggers exactly-once rebind:**

```swift
testWholeSystemRecaptureRebindsSelectedDeviceExactlyOnce()
  // Spy engine.addOutput/removeOutput calls
  // Simulate onStateChange() with a recapture flag
  // Assert exactly one removeOutput → addOutput pair per device
  // All CaptureControlling fakes compile
```

### 2.2 Part B tests (T5)

**Files:** `SyncedLocalSinkTests.swift`, `SyncedLocalFanoutTests.swift`,
`PhaseControllerTests.swift`.

**44.1 kHz input rendered at 48 kHz:**

```swift
testRenderAtDeviceNativeRateNoPlaytimeShift()
  // Input: 44.1 kHz stream
  // Output: 48 kHz ring
  // Assert: frame counts are correct (resample ratio applied)
  // Assert: no pitch shift (frequency domain)
```

**Sync-offset alignment post-resample:**

```swift
testSyncOffsetRescalesWithRenderRate()
  // Different render rates (44.1, 48) produce correctly-aligned delay
  // SyncTiming.delay scales with rate
```

---

## 3. Open risk: rate-bounce coalescing

Rapid nominal-sample-rate flips (44.1 → 48 → 44.1, seconds apart) must be
coalesced to avoid thrashing the rebind. `NativeCaptureCoordinator`'s
existing `pendingDeviceChange` guard (callback/debounce, C6 in
`PLAN-SYNCED-LOCAL-DROPOUT-FIX.md`) should cover this — the new listener
rides that same coalescing and does not add a new thrashing vector.
Confirmed by unit tests that rapid notifications do not produce redundant
rebuilds.

---

## 4. Health signal: tap/RTP recovery monitoring (T8)

**Files:** `NativeBackend.swift`, `OutputBackend.swift`, `AppDelegate.swift`.

**Signal:** `BackendEvent.streamHealth(id:recovering:)` — fired from the
recapture/rebind machinery to indicate when a stream is entering or exiting
recovery.

- **`recovering: true`** — a whole-system or per-app rebind is enqueued (tap
  or RTP session out of sync, recovery in flight).
- **`recovering: false`** — the rebind succeeded; stream is live.

Signal-only for now; no UI currently consumes it. `AppDelegate` logs it, and
the mock-speakers demo prints it for visibility. A future monitoring/debug UI
or system health dashboard can consume this signal.

---

## 5. Related documentation

- **Per-app routing design:** `dev/notes/p2b-multistream-brief.md` §"Per-app
  capture coordinator & nominal-sample-rate listener" (the pattern being
  ported to the whole-system path).
- **Synced-local architecture:** `dev/notes/p2b-synced-local-brief.md` (the
  delay ring, clock domains, output latency).
- **AirPlay 2 wire protocol & RTP state:** `AirPlayEngine/docs/seam-map.md`.
- **Crash/stability:** `dev/notes/stability-audit-2026-07-18.md` (related
  process-tap lifetime issues).

---

## 6. Implementation checklist

All tasks completed and merged to `claude/dropout-fix-integration`:

- [ ] **T1** — Port sample-rate listener to whole-system tap ✓
- [ ] **T2** — Whole-system AirPlay session reset on rebuild ✓
- [ ] **T3** — Render local sink at device-native rate ✓
- [ ] **T4** — Tests for Part A (nominal-rate listener + rebind) ✓
- [ ] **T5** — Tests for Part B (native-rate rendering + sync) ✓
- [ ] **T6** — Dev-notes writeup (this file) ✓
- [ ] **T7** — Gated by-ear live test (pending: owner manual verification)
- [ ] **T8** — Health signal emission (streamHealth event) ✓
- [ ] **T9** — Health signal test ✓

**Test suite:** `swift test --parallel` reports 988/988 green.

---

## 7. Follow-up fix — T2 latency regression: reset only on a device/rate rebuild

**Symptom (owner, live by-ear):** music already playing on the Mac; adding an
AirPlay device connects fast, then a **long silence** before audio comes out of
the AirPlay device — on **every** connect (first or Nth), while everything after
the connect (switching, play/pause, volume) stays snappy.

**Root cause — a structural misclassification in §1.2's recapture detection.**
T2 recognised a tap REBUILD as "a later `.capturing` in the same capture epoch"
(`everCapturedWholeSystem` / `handleWholeSystemCaptureHealthChange`) and, on any
such rebuild, reset every stream-0 AirPlay session (removeOutput → addOutput).
But a rebuild is a NORMAL part of a Mac+AirPlay connect: attaching the
synced-local sink adds its own render pid to the whole-system tap's exclusion set
(`NativeBackend.attachSyncedLocalSink` → `setSyncedLocalSink(_:renderProcessPID:)`
→ `recreateTap`), which recreates the tap and emits a second `.capturing` on
**every** connect — with the tapped device and its clock unchanged, i.e. the
receivers' RTP timeline intact. T2 could not tell that benign rebuild apart from
the genuine nominal-rate-renegotiation rebuild, so it fired a redundant full RTP
re-establish (removeOutput → addOutput) after each already-fast connect: exactly
"connects fast, then a long silence." It is unconditional (independent of any
real 44.1↔48 kHz change — confirmed by a standalone Core Audio probe: creating
the aggregate and opening an `AVAudioEngine` on the built-in device did NOT fire
the nominal-rate listener), which is why every reconnect is equally slow.

**Fix — distinguish the rebuild cause.** `recreateTap(cause:)` now carries a
`RebuildCause`:
- `.deviceOrRateChange` — from `handleDeviceChange()` (the default-device /
  nominal-sample-rate listener). The tapped device's clock moved, so the rebuild
  DOES desync the receivers and MUST reset. Fires the new
  `NativeCaptureCoordinator.onDeviceRateRebuild` callback on a successful commit.
- `.exclusionChange` — from `updateRouting(...)` / `setSyncedLocalSink(...)`. The
  device/clock is unchanged; the receivers stay in sync, so NO reset. Never fires
  `onDeviceRateRebuild`.

`NativeBackend` wires `captureCoordinator?.onDeviceRateRebuild` →
`resetAirPlaySessionForWholeSystem` and drops the `.capturing`-count heuristic
(`everCapturedWholeSystem` + `handleWholeSystemCaptureHealthChange` removed). The
dropout the reset was built for still recovers (a real rate renegotiation goes
through `handleDeviceChange` → `.deviceOrRateChange`); the pitch fix and the
mid-rebuild C6 replay (which conservatively replays as `.deviceOrRateChange`) are
untouched.

**Tests:**
- `NativeCaptureCoordinatorTests.testExclusionChangeRebuildDoesNotFireDeviceRateRebuildButDeviceChangeDoes`
  — an exclusion-set rebuild (`updateRouting`) does NOT fire `onDeviceRateRebuild`;
  a `fireDeviceChange()` rebuild fires it exactly once. (The faithful regression.)
- `NativeBackendTests.testWholeSystemConnectWithoutDeviceRateRebuildDoesNotResetSession`
  and `...testWholeSystemDeselectReselectCycleDoesNotResetSession` — a plain
  connect / reconnect issues no rebind-recovery removeOutput→addOutput.
- The former recapture tests now drive `capture.fireDeviceRateRebuild()` instead
  of a second `.capturing`, asserting the reset still fires exactly once on a
  genuine device/rate rebuild.

**Test suite:** `swift test --parallel` reports 998/998 green.

---

## 8. Follow-up fix — T3 rapid-toggle storm: coalesce bursts + guarded RTP re-sync

**Symptom (owner, live by-ear on `claude/warm-signal-full`):** after the §7 fix landed,
the single-toggle connect latency was cured. But rapidly clicking the Mac's "Current
Device" checkbox (toggling on/off/on/off rapidly over 2–3 seconds) permanently silences
AirPlay audio — the exact same symptom as §0's nominal-sample-rate bug, but triggered
by a *different root cause*: the whole-system tap rebuild that `setSyncedLocalSink`
itself *deliberately forces on every attach/detach* (see `NativeCaptureCoordinator`'s
`setSyncedLocalSink` → `updateRouting` → `recreateTap`), not by a hardware sample-rate
renegotiation.

**Root cause — STABILITY(C6) coalescing only protects half the problem.** The
`NativeCaptureCoordinator` already has coalescing (`pendingDeviceChange` guard, C6 in
`PLAN-SYNCED-LOCAL-DROPOUT-FIX.md`) that prevents a rebuild landing while *one is
already in flight* — call it serialization. But rapid toggling bypasses that: each
click calls `setOutputSet` → `applySyncedLocalSinkTransition` (the pre-fix code path)
→ `attachSyncedLocalSink` → `recreateTap`, and if each rebuild *completes cleanly
before the next click arrives*, the C6 guard does NOT prevent it. Telemetry evidence:
~19 whole-system tap rebuilds in 2.5s of rapid clicking, each completing successfully
before the next one began, `desiredOn` set unchanged across all of them (user never
actually *changed* which devices were selected, just spammed the toggle).

Each rebuild is an `.exclusionChange` (the `syncedLocalSink`'s render PID changed from
missing to present or vice versa), NOT a `.deviceOrRateChange` — so the rebuild
deliberately does NOT reset the AirPlay receiver's RTP session (§7's `onDeviceRateRebuild`
callback doesn't fire). The receiver clock stays at its old PTP timeline while the
Mac-side tap's `mach → monotonic` mapping is STALE in every one of those 19 rebuilds.
The receiver's audio samples desync relative to the tap's delivery, RTP playback
becomes incoherent → silent output on the receiver. Mac-side capture coordinator
reports perfectly healthy (both the tap and the `NativeCaptureCoordinator` are running
normally; they just have an out-of-sync clock mapping).

Why nothing logged an error: `.exclusionChange` rebuilds are CORRECT to skip the reset.
They are ordinarily benign (a per-app routing change, for example, doesn't need an RTP
reset). The reset exists to handle *device/rate changes* that HAVE moved the receiver's
clock (§7). A tap rebuild alone — with the device and rate unchanged — is not an error
condition at the coordinator level, and the coordinator has no way to know whether this
particular rapid series is pathological or deliberate.

**Fix — coalesce at the backend level.** `NativeBackend.swift` owns BOTH the tap rebuild
(via `applySyncedLocalSinkTransition` → `attachSyncedLocalSink`) AND the sink re-anchor
(the ~977ms session re-fire happens inside `SyncedLocalSink`'s attach/start). So one fix
there addresses both symptoms. T1 + T2 (commit `32a632d`, 2026-07-25):

### T1 — Debounce synced-local attach/detach on a trailing-edge window

> The window is **0.5s** and churn has a second, cadence-independent arming path; T6 below
> explains why the original 250ms-only shape was not enough. The 250ms figures in T1/T2/T3
> are the as-first-shipped values, kept because the reasoning still reads correctly.

**Location:** `NativeBackend.swift`, new methods `scheduleSyncedLocalSettleLocked()` and
`fireSyncedLocalSettle()`, new `stateQueue`-confined fields `syncedLocalSinkApplied`,
`pendingSyncedLocalSettle`, `syncedLocalCoalescedCount`.

**Mechanism:** Every Mac select/deselect updates `syncedLocalSinkEnabled` (the DESIRED
state) inside `stateQueue` (already serialized). Instead of running the attach/detach
immediately, `setOutputSet` calls `scheduleSyncedLocalSettleLocked()`, which:

1. Increments `syncedLocalCoalescedCount` (how many distinct toggle decisions landed).
2. Cancels `pendingSyncedLocalSettle` if already armed.
3. (Re)schedules `fireSyncedLocalSettle` to run 250ms from now on `stateQueue` via
   `stateQueue.asyncAfter(deadline: .now() + 0.25)`.

The `DispatchWorkItem` is stored in `pendingSyncedLocalSettle` so a newer toggle can
cancel it before it fires. On fire, `fireSyncedLocalSettle()`:

1. Clears the pending item and coalesce counter.
2. **Bails if desired == already-applied** (net no-op burst like on→off→on landing back
   on ON — no transition needed, no reset needed).
3. Sets `syncedLocalSinkApplied = desired` and enqueues `applySyncedLocalSinkTransition`
   on `captureControlQueue` (the same serial queue every capture start/stop runs on, so
   a tap recreate never races a gate toggle).
4. If `coalesced >= 2` (churn detected), also calls `resetAirPlaySessionForWholeSystem()`
   to re-establish the receiver's RTP session exactly once after the transition.

A normal single toggle decision coalesces to exactly 1, so step 4 is structurally
unreachable on a single click.

**250ms window is trailing-edge only (planner's recommendation).** On a single toggle,
the user experiences a 250ms latency from click to transition — an accepted tradeoff
for simplicity and guarantee that the last toggle's decision wins (no leading-edge
fast path needed).

### T2 — Guarded safety-net RTP re-sync for churny settles

The coalescing alone fixes the tap-rebuild storm (T1), which kills the tap's clock
desync immediately. But the sink's session re-anchor happens in parallel: each attach
re-fires the ~977ms anchor window. With N rebuilds, that became N overlapping re-anchor
cycles, thrashing the session's PTP timeline. Simply collapsing to one rebuild (T1)
also collapses to one re-anchor, fixing the symptom.

T2 adds a safety net: if the settle absorbed `>= 2` distinct toggle decisions (genuine
churn), fire a one-shot `resetAirPlaySessionForWholeSystem()` after the transition
settles. This is **already single-flighted** by the existing per-device `converging`
claim and generation counter, so:

- It cannot fire redundantly on a single toggle (coalesce count = 1 bails).
- It cannot fight a concurrent device convergence or thrash a healthy session.
- It is emitted as a Telemetry event (`synced_local_churn_resync`) for observability.

### T3 — Hermetic regression tests

**Files:** `NativeBackendSyncedLocalSelectionTests.swift` (cases a, c, e) and
`NativeBackendTests.swift` (cases b, d, production default).

The six test cases guard the fix against regressions:

**(a)** `rapidToggleBurstProducesAtMostOneTransition` — a 5-decision burst
(on→off→on→off→on in ~50ms, settled in 50ms window) must collapse to exactly ONE sink
transition, not 5. The spy `SyncedLocalSinkControlling` records every call; a broken
(uncoalesced) path would show 5 `start`/`stop` cycles.

**(c)** `netNoOpBurstDoesNothing` — a burst that lands back on the already-applied
state (enabled initially, then off→on→off→on landing back on enabled) must do absolutely
NOTHING — no sink call, no reset. This is critical: it catches forgetting the
`desired != applied` guard that prevents churn-count-based resets on a redundant burst.

**(e)** `stopCancelsPendingSettle` — `stop()` must cancel a still-pending settle so
it never fires against a torn-down backend. Uses a 1.0s window (much longer than usual)
to create a scenario where the settle is still armed. The test reads `test_hasPendingSyncedLocalSettle`
(an injected `stateQueue.sync` accessor) before and after `stop()` to verify the pending
item is cleared synchronously, independent of any other guard. (Belt-and-suspenders: even
if `stop()` forgets to cancel, `fireSyncedLocalSettle`'s own `desired != applied` bail
would still prevent a crash, but this test catches the regression directly.)

**(b)** `singleSyncedLocalToggleAppliesTransitionWithZeroResets` — **THE SHARPEST
correctness constraint:** a NORMAL SINGLE Mac toggle must (1) apply the transition
(sink starts listening) and (2) issue ZERO `resetAirPlaySessionForWholeSystem` calls.
This guards against reintroducing the redundant RTP re-establish on every ordinary
connect that §7's follow-up fix already removed once. A broken churn detector that fired
on every toggle (not just `>= 2`) would cause this case to fail.

**(d)** `churnyToggleBurstLandingOnNewStateFiresTransitionPlusExactlyOneReset` — a
genuine 3-decision burst (off→on→off→on over ~50ms, landing on a new state different
from currently-applied) must fire the sink transition PLUS exactly ONE `resetAirPlaySessionForWholeSystem`
call. Detects the reset as exactly one engine flush (`SpyEngine.flushedIDs`), which is what
today's whole-system reset issues.

**Test-only seam:** `syncedLocalSettleWindow` is injected through the designated
initializer (`init(..., syncedLocalSettleWindow: TimeInterval = 0.25)`) rather than a
module-level constant, same shape as `processNotYetAudibleRetryDelay` and
`rebindRecoveryRetryDelay` elsewhere in the file. The convenience init (every real
production call site, including `makeBackend`) takes no such parameter, so production
always inherits the 0.25s default unchanged. Case (f), `syncedLocalSettleWindowProductionDefaultIsUnchanged`,
pins the default so the seam itself never silently drifts.

Two injected accessors were added:
- `test_syncedLocalSettleWindow: TimeInterval` — returns the private `syncedLocalSettleWindow`
  to verify the production default is 0.25s (case f).
- `test_hasPendingSyncedLocalSettle: Bool` — reads `pendingSyncedLocalSettle != nil` on
  `stateQueue`, used by case (e) to discriminate a missing cancel from other guards.

**Test suite:** `swift test --parallel` reports 1270 tests green. All six cases were
verified NOT vacuous: temporarily reverting different pieces of `32a632d` caused them
to fail with the exact expected diagnostics (e.g., removing the `coalesced >= 2` guard
made case b fail; removing `pendingSyncedLocalSettle = nil` made case e fail).

### T6 — Cadence-proof arming (the review's H-1), and what it changed

The adversarial gate found that T1+T2 as shipped were **window-proof, not cadence-proof**.
The 250ms window was the only protection, so a user clicking the Mac checkbox every ~330ms
(~3/s, a comfortable sustained human rate) landed every click OUTSIDE the window: each got
its own settle with `coalesced == 1`, `churned` was always false, and the T2 safety net was
**provably unreachable** — one full tap rebuild per click, zero re-syncs, behaviour identical
to pre-fix. The reported bug still reproduced at moderate clicking speeds.

Both halves of the remediation, in the order the memory-leak audit established for this storm
class (`docs/plans/PLAN-MEMORY-LEAK-AUDIT.md`: its structural loop-breaker T8 landed BEFORE
its debounces T9/T10, precisely because a window must never be the only protection):

1. **Structural, cadence-independent arming.** `fireSyncedLocalSettle` now appends a monotonic
   timestamp (`DispatchTime.now().uptimeNanoseconds`) for every transition it REALLY applies —
   past the `desired != applied` guard, never per toggle decision — into
   `syncedLocalTransitionTimes`, pruned to a rolling `syncedLocalTransitionHorizon` (2s). Churn
   is now `coalesced >= 2 || recentTransitions >= 2`. The second disjunct is what recovers a
   cadence slower than the window; the first still catches faster-than-window bursts.
2. **Window widened 0.25s → 0.5s.** 500ms is the top of the band that plan used for
   user-facing debounces (T10's shared monitor, 300–500ms) — deliberately not its 1–2s scan
   window (T9), which gated a background process-list scan rather than a user-visible action,
   and which its own T11 warns costs first-start latency.

**The invariant is untouched.** A normal single toggle satisfies neither disjunct: one
decision, and its own transition alone inside the horizon. Two *deliberate* toggles several
seconds apart are likewise one transition each per horizon and pay nothing — the horizon is
exactly what separates them from churn. The horizon's floor is the settle window (or a cadence
just outside the window slips through the same hole again); its ceiling is deliberate
reconsideration, and since every transition already trails its click by the window, a 2s gap
between transitions is a 2s gap between clicks.

No second rate limiter guards a SUSTAINED storm, by design: `resetAirPlaySessionForWholeSystem`
is already single-flighted, so a device still recovering sits in `converging` and the next call
skips it (`whole_system_rebind_skipped`).

Three more findings closed in the same pass:

- **H-2 (the pin test was vacuous).** `makeBackend` re-declared `syncedLocalSettleWindow = 0.25`
  and always forwarded it, so `syncedLocalSettleWindowProductionDefaultIsUnchanged` pinned
  the *helper's* literal — the real default could drift underneath it. The two pin tests construct
  the backend directly through the designated init with no timing arguments, so they read the
  real default rather than a helper literal. Verified by temporarily setting the default to 2.5s: the test fails.
  `test_syncedLocalTransitionHorizon` + a matching pin case cover the horizon the same way.
- **H-3 (false-failure risk).** The coalescing cases shrank the window to 30–50ms, under
  scheduling jitter with `--parallel`; a split burst inverted their meaning. Now 0.15s. The
  H-1 case deliberately keeps a SHORT (0.05s) window — its hazard is inverted: it needs each
  click to fall OUTSIDE the window, so a merge (which needs a 280ms stall) is its only failure
  mode.
- **H-6 (meter led the audio).** `isMeterable` read the DESIRED flag, so the local row's meter
  moved up to a full window ahead of physical audio in both directions. It now reads
  `syncedLocalSinkApplied`, and `setOutputSet`'s eager `emitCombinedLevel(forDevice:)` — which
  existed ONLY because the desired flag flipped instantly — moved into `fireSyncedLocalSettle`
  alongside the applied flag, so the clear still happens, at the moment the transition lands.

New hermetic cases (all `IsolatedSuite`, no audio): `slowCadenceToggleStormArmsExactlyOneReset`
(the H-1 regression — two clicks 330ms apart, each outside the window, arm exactly one re-sync;
verified to FAIL with `recentTransitions >= 2` removed, reporting 0 resets),
`twoUnhurriedTogglesOutsideTheHorizonArmNoReset`,
`syncedLocalTransitionHorizonProductionDefaultIsUnchanged`, and
`localDeviceMeterFollowsAppliedNotDesiredSyncedLocalState` (verified to FAIL against the
desired-flag `isMeterable`).

### Cross-reference

- **PLAN:** `docs/plans/PLAN-RAPID-TOGGLE-DROPOUT-FIX.md` (decisions Q1–Q5, task list,
  risk analysis, §H adversarial-review ledger).
- **Commit:** `32a632d` ("Debounce rapid synced-local toggling; guarded RTP re-sync on
  churn"), 2026-07-25.
- **Prior fix that this reuses:** §7 above (the `.deviceOrRateChange` callback that
  CORRECTLY fires on a genuine device/rate rebuild, which this rapid-toggle fix must
  NOT regress).
- **Related:** the nominal-sample-rate listener itself (§1.1), which is still the
  safety net for real hardware rate changes; this fix addresses rapid *toggling* as a
  separate (and orthogonal) coalescing problem.
