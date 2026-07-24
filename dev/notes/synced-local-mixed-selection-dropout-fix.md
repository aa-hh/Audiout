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
infrastructure, not a Audiouter issue.

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
- [ ] **T7** — Gated by-ear live test (pending: Alec manual verification)
- [ ] **T8** — Health signal emission (streamHealth event) ✓
- [ ] **T9** — Health signal test ✓

**Test suite:** `swift test --parallel` reports 988/988 green.

---

## 7. Follow-up fix — T2 latency regression: reset only on a device/rate rebuild

**Symptom (Alec, live by-ear):** music already playing on the Mac; adding an
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
