# AGENTS.md history: dev/phase-spike

Archived verbatim from AGENTS.md on 2026-09-02 when that file was trimmed to the root rule (three sections, at most 300 words). Not maintained: symbols named below may no longer exist. Orientation lives in AGENTS.md; grep this file for the long form of a trap, the dated decisions, and the changelog.

---

# dev/phase-spike

## Purpose

Throwaway feasibility harness for **T-SPIKE-PHASE** (Risk R7 of the synced-local
plan): measures the achievable phase-lock precision of the kind of
`AVAudioEngine` graph `SyncedLocalSink` builds, and evaluates candidate
rate-correction mechanisms for the follow-on T-CORRECTION work. Full plan
context: `../../docs/plans/synced-local-airplay-plan.md`; the writeup this
harness feeds: `../notes/phase-lock-spike-findings.md`.

**Relationship to production code:** standalone — deliberately does **not**
link `AudioutCore`. `PlanMath.swift` re-derives `SyncTiming.plan` from
`AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift` independently, so
its Monte-Carlo is a cross-check against the shipping formula rather than a
test of it (the two must be kept in sync by hand if `SyncTiming.plan` changes).
Nothing here is vendored into the app; this package is disposable measurement
code.

**Status (per `../notes/phase-lock-spike-findings.md`):** the `offline` suite
has been run and reports GO for a "sample-accurate at the electronic output
boundary" target, ≤ ½-frame initial release phase, and recommends a custom
fractional resampler (see `ResamplerProbe.swift`) over `AVAudioUnitVarispeed`/
`AVAudioUnitTimePitch` for T-CORRECTION. The `realdevice` real-hostTime-jitter
probe has **not** been run unattended (see Notable Patterns) — that number is
still owed. The findings doc is a CHECKPOINT awaiting the owner's confirmation
before T-CORRECTION starts.

**Keep this file up to date** when probes are added/removed/renamed, when
`SyncTiming.plan` changes in a way that could desync `PlanMath.swift`, or when
the findings doc's go/no-go verdict changes.

## Notable Patterns

- **Silence is enforced in triplicate for `realdevice`**: zeroed samples,
  `isSilence.pointee = true`, and `mainMixerNode.outputVolume = 0`. It still
  opens a real IO cycle on the default output device, which can click a
  speaker relay on some Macs — that's why it's a separate opt-in subcommand
  left for a human to run, not bundled into `offline`.
- **`offline` never touches a real device** — all four of its probes run
  through `AVAudioEngine.enableManualRenderingMode(.offline, …)`, so
  `mHostTime` is never flagged valid there (see `OfflineTimestampProbe.swift`);
  only `realdevice` can measure real hostTime jitter.
- **Click detection is bound-based, not threshold-based**: `Signal.maxAbsFirstDiff`
  is compared against `Signal.sineDiffBound` (the theoretical max sample-to-sample
  delta for a clean sine at that frequency/rate); a ratio ≥ ~1.5 flags a possible
  discontinuity.
- **`--seconds N` on `realdevice`** controls how long the IO cycle stays open
  (default 4s); keep it short in ad-hoc runs.

## Key Types

| Type | Role |
|---|---|
| `PlanMath` | Independent re-derivation of `SyncTiming.plan`; Monte-Carlos the sub-buffer release-placement floor. |
| `OfflineTimestampProbe` | Runs an offline `AVAudioSourceNode` graph, records `AudioTimeStamp` cadence, proves `hostTime` is invalid offline. |
| `CorrectionProbe` | Drives `AVAudioUnitTimePitch`/`AVAudioUnitVarispeed` under a continuous ppm rate sweep; measures latency, click-freeness, rate accuracy. |
| `FractionalResampler` (`ResamplerProbe.swift`) | Custom 4-tap Catmull-Rom fractional resampler — the harness's recommended T-CORRECTION mechanism. |
| `RealDeviceProbe` | Opens the real default output device to measure actual per-cycle `hostTime` jitter; silent by construction (see Notable Patterns). |
| `Stats` / `Signal` / `MachTime` (`Stats.swift`) | Dependency-free stats + signal-analysis + mach↔ns helpers shared by all probes. |

## External Dependencies

| Dependency | Usage |
|---|---|
| `AVFoundation` | `AVAudioEngine` manual rendering graphs, `AVAudioUnitTimePitch`/`AVAudioUnitVarispeed`, used by every probe except `PlanMath`/`Stats`. |

No third-party SPM packages — `Package.swift` declares a single executable
target with no dependencies.
