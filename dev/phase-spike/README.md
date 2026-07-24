# phase-spike

Throwaway feasibility harness for **T-SPIKE-PHASE** (see the plan
`docs/plans/synced-local-airplay-plan.md` and the writeup
`dev/notes/phase-lock-spike-findings.md`). Measures the achievable phase-lock
precision of the kind of `AVAudioEngine` graph `SyncedLocalSink` builds, and the
behaviour of candidate rate-correction mechanisms for T-CORRECTION.

Deliberately **separate from AudiouterCore** (does not link it): disposable
measurement code, and it re-derives the release-plan math independently so it is an
*independent* cross-check of `SyncTiming.plan`.

## Build & run

```
cd dev/phase-spike
swift build
./.build/debug/phase-spike offline        # silent, no device — the full measurement suite
./.build/debug/phase-spike realdevice --seconds 8   # real hostTime jitter; SILENT (zeros only)
./.build/debug/phase-spike --help
```

- **`offline`** touches no audio device and produces no sound. This is what the
  findings doc's numbers come from.
- **`realdevice`** opens an IO cycle on the default output device to read the real
  per-cycle `hostTime`, but emits only digital silence (zeros, `isSilence=true`,
  mainMixer volume 0). It is the one number the offline path cannot get (offline
  manual rendering never flags `hostTime` valid). Safe to run — makes no sound — but
  left for a human to run since starting the audio subsystem can click a speaker relay.

## What each source does

| File | Measures |
|---|---|
| `PlanMath.swift` | Monte-Carlo of the sub-buffer release-placement floor (≤ ½ frame). |
| `OfflineTimestampProbe.swift` | Render-block `AudioTimeStamp` cadence + proves `hostTime` is invalid offline. |
| `CorrectionProbe.swift` | `AVAudioUnitTimePitch` / `AVAudioUnitVarispeed` latency + click-freeness + rate accuracy (offline). |
| `ResamplerProbe.swift` | Custom 4-tap cubic fractional resampler — the recommended T-CORRECTION mechanism. |
| `RealDeviceProbe.swift` | Real per-cycle `hostTime` jitter on the default output device (silent). |
| `Stats.swift` | Stats + signal helpers + mach↔ns conversion. |
