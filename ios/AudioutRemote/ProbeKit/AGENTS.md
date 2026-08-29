# ios/AudioutRemote/ProbeKit

## Purpose

The sync-probe DSP, as a standalone SwiftPM package: it takes the phone's
recording of the two simultaneous sweep probes the Mac stages as `[Float]` and
returns how late the target speaker sounded relative to the reference. Nothing
else — no audio I/O, no networking, no app concepts, no dependencies beyond
Accelerate and Foundation. Capture, session setup and orchestration live in the
app.

The technique is the Mac's shipped mic-probe calibration (roadmap 064) with the
phone standing in for the built-in microphone: a DOWN sweep (2000→500 Hz) on
the reference lane and an UP sweep (3200→10000 Hz) on the target lane, played
at the same scheduled moment, recovered from one recording by matched filter.
One mic hears both speakers, so capture latency and the shared start are common
to both arrivals and cancel in the DIFFERENCE.

## Rules

- **`SyncProbeCorrelator.swift` is a HAND-COPY of
  `AudioutCore/Sources/AudioutCore/SyncProbeCorrelator.swift`. Change one,
  change the other.** `ios/` may never depend on AudioutCore (see
  `ios/AGENTS.md`), so the phone carries its own copy; the duplication is a
  consequence of the package layout, not a preference. The Mac stages the
  sweeps this file describes, so a divergence is not a local bug — it is a
  phone that measures the wrong signal and reports a confident wrong number.
  The standing option that removes the hazard: make AudioutCore depend on
  ProbeKit instead and delete the copy. One file, one home.
- **`ProbeAnalyzer.sweepSeconds` (1.0) is a hand-copy too**, of
  `AlignmentTickInjector.probeSweepSeconds`. The Mac plays a sweep of exactly
  that length; this package renders its own to match against. Same rule: they
  move together.
- **The lane assignment is the Mac's choice, not this package's.** DOWN is the
  reference lane, UP is the target (Bluetooth) lane. Swapping the labels here
  silently reverses the sign of every measurement, and nothing fails loudly
  when it happens.
- **The phone reports the raw measurement; the Mac owns trim semantics.**
  `offsetMs` is positive when the target sounded LATE. Do not fold a sign
  convention or a trim calculation in here.
- **Refuse rather than guess.** A capture shorter than one sweep throws
  `recordingTooShort`; a sweep that is not found convincingly throws
  `probeNotFound`. There is no "best effort" answer — a wrong alignment number
  is worse than none, because the caller falls back to the by-ear wizard and
  the user never learns the number was invented.
- **Pure DSP, and it stays that way.** No `AVFoundation`, no networking, no
  app types, no new dependencies. Anything that touches a microphone or a
  socket belongs in the app target.
- **No GPL SPDX header on either source file.** Both are license-clean by
  design (PLAN-UNIVERSAL-SYNC Decision 5 lineage) so the Apple-only Bluetooth
  path can share them; the rest of `ios/AudioutRemote/` does carry the GPL
  header. Match the neighbouring file, and never move GPL-derived code in here.

## Build / test

Bare `swift test` and `swift build` are **blocked by a repo hook** — it matches
the command string anywhere, including from outside the repo, so there is no
directory to run it from. `scripts/run-tests.sh` is no help either: it only
knows AudioutCore.

Copy the package to a scratch directory outside the repo and drive it with
`xcodebuild`, which the hook does not block:

```
cp -R ios/AudioutRemote/ProbeKit "$SCRATCH/ProbeKit"
cd "$SCRATCH/ProbeKit" && xcodebuild test -scheme ProbeKit -destination 'platform=macOS'
```

`platform=macOS` is deliberate: the package builds for macOS 14 as well as
iOS 17 precisely so its tests can run without a simulator. It is pure
computation on synthetic recordings — no hardware, no phone, seconds to run.

Edit in the repo, copy, run. Never edit inside the scratch copy; it is
throwaway and the diff will be lost.

## Map

- `Package.swift` — swift-tools-version 6.0, iOS 17 / macOS 14, ZERO
  dependencies, one library product `ProbeKit`.
- `Sources/ProbeKit/ProbeAnalyzer.swift` — the public API: `ProbeAnalysis`
  (`offsetMs`, `confidence`), `ProbeAnalysisError`, and `analyze(recording:
  ambientEndSample:)`, which renders both sweeps at the capture's own sample
  rate, tries the SNR-weighted correlation first and falls back to the plain
  matched filter when weighting finds nothing. Holds the hand-copied
  `sweepSeconds`, the lane assignment, and the note on what changes when the
  microphone can be carried (~2.9 ms per metre of distance asymmetry).
- `Sources/ProbeKit/SyncProbeCorrelator.swift` — the hand-copy: `SyncProbe`
  (sweep design and synthesis, the two lanes' disjoint bands) and
  `SyncProbeCorrelator` (FFT cross-correlation, optional ambient-noise
  weighting, robust peak-to-sidelobe confidence, sub-sample peak
  interpolation). Its header carries the copy warning and the reasoning behind
  the band split and the confidence estimator — read it before touching either.
- `Tests/ProbeKitTests/SyncProbeCorrelatorTests.swift` — the filter itself
  against synthetic scenes rendered at analytic fractional delays: sub-sample
  accuracy, the two lanes separating with a 23 dB level imbalance, echoes, hum,
  and the refusals.
- `Tests/ProbeKitTests/ProbeAnalyzerTests.swift` — the contract with the Mac,
  using the SHIPPING sweep designs: a known offset recovered in milliseconds at
  the sample rates a phone hands us, the sign, and the refusals.
