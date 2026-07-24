# Plan — Fix the synced-local mixed-selection dropout bug

Status: **APPROVED-PENDING — plan finalized 2026-07-24, NOT yet executed.** Awaiting Alec's go-ahead to build.
Worktree: `.claude/worktrees/synced-local-airplay`, branch `claude/synced-local-airplay`.
Produced via `/plan` (planner: opus/high; cost-check: model-critic). Companion to `docs/plans/synced-local-airplay-plan.md` (the feature this fixes). Root-cause evidence in memory `synced-local-mixed-selection-dropout-diagnosis`.

To execute later: `/orchestrate` this file, or hand it to a fresh session. Nothing merges to `main` without Alec's explicit go-ahead AND his passing live test.

## Root cause (confirmed live 2026-07-24)

Adding the Mac's built-in speakers (48 kHz native) to a Mac+AirPlay synced-local selection makes `SyncedLocalSink`'s `AVAudioEngine` open the speakers and renegotiate the tapped output device's nominal sample rate (48↔44.1 kHz). Core Audio process taps keep delivering buffers at full cadence but go SILENT (all-zero PCM) on nominal-rate renegotiation — Apple-unresolved bug (Dev Forums 825780). So AirPlay gets silence while the meter still shows levels. The whole-system `NativeCaptureCoordinator` only rebuilds on device-IDENTITY change (UID unchanged here — only the rate changed), so it never recovers. Re-adding AirPlay plays pitched up (~+8.8% = 48000/44100) then judders/stops.

`PerAppCaptureCoordinator` already fixes this for the per-app path (`installSampleRateListener`, ~L939-990); the whole-system path never got the equivalent. The planner further confirmed the whole-system AirPlay **session reset** on rebuild is also missing (`NativeBackend` never observes the whole-system coordinator's state changes) — a rebuilt tap alone would still leave AirPlay silent.

## Locked decisions (Alec, 2026-07-24)

- **Q1 → render the sink at the speakers' NATIVE rate** (root-cause fix, not recovery-only; not force-44.1). Base-resample the 44.1 kHz feed up once so opening the device never forces a renegotiation.
- **Q2 → build BOTH the detector AND the AirPlay session restart together** (proven per-app pattern; a rebuilt tap without a session reset stays silent).
- **Q3 → read the device native rate ONCE at sink construction** (re-read each time synced-local toggles on; dynamic mid-session follow deferred).
- **Cost-check:** model-critic flagged T3 opus→sonnet as a CONFIRM-with-real-risk. Alec chose to KEEP T3 on opus (the one RT-DSP task where the pitch bug lives; a wrong call costs a live-test cycle). No downgrades applied.

## Task list

**T1 — Port the nominal-sample-rate listener into the whole-system tap (Part A1)**
Files: `AudiouterCore/Sources/AudiouterCore/NativeCaptureCoordinator.swift` (`CoreAudioSystemTap`). Capture `tappedOutputDeviceID` where `outputID` is read in `createAggregate()`; add `installSampleRateListener`/`removeSampleRateListener` modeled on `PerAppCaptureCoordinator.swift:952-977`; call install in `createAndStart`, remove in `teardown()`. Route the notification into the existing `onDefaultDeviceChanged` → `handleDeviceChange` → `recreateTap()`. Use the class's existing `listenerQueue` for add/remove (do NOT copy per-app's `nil` queue).
Kind: new-code · Depends: — · **Model: sonnet 5 · Effort: medium**
Verify: unit test (T4) — a simulated nominal-rate change drives a rebuild; `grep -c NominalSampleRate` > 0; `swift test --parallel` green.

**T2 — Whole-system AirPlay RTP session reset on tap rebuild (Part A2)**
Files: `AudiouterCore/Sources/AudiouterCore/NativeBackend.swift`. Add `onStateChange` to `CaptureControlling` (default no-op so fakes compile); wire `captureCoordinator?.onStateChange`; add recapture detection mirroring `everCapturedBundleIDs`/`isRecapture`; add a whole-system analogue of `resetAirPlaySessionForRoutedApp` that rebinds the selected devices (the `added`/`desiredOn` set feeding `engine.addOutput(outputID)`, not per-app `streamBindings`). Reuse `enqueueRebindRecovery`/`performRebindRecovery` generalized to no-streamId rebinds; keep single-flight generations.
Kind: backend · Depends: — (reads `onStateChange`, already public on the coordinator) · **Model: opus 4.8 · Effort: high**
Verify: unit test (T4) with an engine spy asserts a simulated whole-system recapture issues removeOutput→addOutput per selected device exactly once; all `CaptureControlling` fakes still compile.

**T3 — Render the local sink at the device-native rate (Part B)**
Files: `SyncedLocalSink.swift` (`renderSampleRate`/`connectionFormat`, `SyncTiming`, ring sizing), `OwnToneBackend.swift` (`makeBackend` — constructs at 44_100), `NativeCaptureCoordinator.swift` (`fanOutToSyncedLocal` feeds `PCMFormat.airplay` 44.1 — the base-resample point). Reuse the device-rate read idiom in `LocalOutputLatency.swift:83`. Set render rate to the tapped device's native `kAudioDevicePropertyNominalSampleRate`; base-resample the 44.1 fan-out up to it once BEFORE the ring (the `FractionalResampler` stays a 1±ppm drift corrector — it must NOT do base conversion). Verify no hardcoded 44100 remains and `SyncTiming` scales off `renderSampleRate`.
Kind: new-code · Depends: Q1 (locked) · **Model: opus 4.8 · Effort: xhigh**
Verify: offline/synthetic tests (T5) — no pitch error + correct frame counts at 48 kHz; RT path stays alloc/lock-free (`stateLock.try()` idiom); `swift test --parallel` green.
Note: HOT file shared with T1 — T1 and T3 serialize on one agent owning `NativeCaptureCoordinator.swift`.

**T4 — Tests for Part A**
Files: `NativeCaptureCoordinatorTests.swift`, `NativeBackendTests.swift` (subclass `IsolatedTestCase`). Simulated nominal-rate notification drives `recreateTap`; whole-system recapture triggers exactly-once rebind via engine spy. No real audio.
Kind: test · Depends: T1, T2 · **Model: sonnet 5 · Effort: medium**

**T5 — Tests for Part B**
Files: `SyncedLocalSinkTests.swift`, `SyncedLocalFanoutTests.swift`, `PhaseControllerTests.swift` (subclass `IsolatedTestCase`). 44.1 input rendered at 48 k = right frame count + no pitch shift; `SyncTiming` delays scale with render rate; resampler pass-through at ratio==1; sync-offset alignment (not just pitch).
Kind: test · Depends: T3 · **Model: sonnet 5 · Effort: medium**

**T6 — Dev-notes writeup**
Files: worktree `dev/notes/` (worktree only, never main). Two-part fix + Forums-825780 root cause next to the per-app note.
Kind: docs · Depends: T1, T2, T3 · **Model: haiku 4.5 · Effort: low**

**T7 — Gated by-ear live test (Alec only, terminal)**
1 AirPlay ✓ → 2 AirPlay ✓ → add Mac: AirPlay keeps playing in sync → deselect Mac: AirPlay continues, no pitch/judder. Native single-instance (PTP 319/320) from this worktree.
Kind: test (manual/live) · Depends: T4, T5 (green suite first)

## Parallelization

Hot file: `NativeCaptureCoordinator.swift` (T1 + T3) → serialize on ONE agent. `NativeBackend.swift` (T2) and `OwnToneBackend.swift` (T3) don't collide.
- Wave 1: **T2** ∥ [**T1 → T3** serialized on the hot-file agent].
- Wave 2: T4 ∥ T5 (+ T6 docs).
- Wave 3: T7 (Alec live).
Critical path: T3 (opus/xhigh) → T5 → T7.

## Execution mode: watched agents

~5 code/test tasks, judgment-heavy real-time-audio on a correctness-critical shipping path, human-gated forks resolved, likely to need mid-course correction from live findings. Interactive steerable transcripts beat workflow overhead.

## Open risks

- **T2 is make-or-break:** a rebuilt tap without the session reset stays silent — build + review it hard. (Small chance the fresh mach→monotonic pts reseed self-heals the whole-system stream where per-app didn't; the "deselecting Mac doesn't recover" symptom argues it does not — confirm in T2's spy test + live.)
- **T3 latency budget:** the extra 44.1→48 resample adds a few ms that must fold into `SyncTiming`'s delay so local stays phase-aligned with AirPlay — verify sync in T5, not just pitch.
- **Rate-bounce coalescing:** rapid 44.1→48→44.1 flips must coalesce; `recreateTap`'s `pendingDeviceChange` (C6) guard should cover it — confirm the new listener rides it and doesn't thrash the rebind.
- **House rule:** read native rate from `kAudioHardwarePropertyDefaultOutputDevice`, never `DefaultSystemOutput`.
- **Single-instance live test:** PTP 319/320 exclusive — only this worktree runs T7.
