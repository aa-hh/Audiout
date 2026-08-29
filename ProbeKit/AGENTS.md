# ProbeKit

## Purpose

The sync-probe DSP, as a standalone SwiftPM package at the repo root: it takes
a recording of the two simultaneous sweep probes the Mac stages as `[Float]`
and returns how late the target speaker sounded relative to the reference.
Nothing else — no audio I/O, no networking, no app concepts, no dependencies
beyond Accelerate and Foundation. Capture, session setup and orchestration live
in whichever app is calling.

**Both apps depend on this package.** The Mac (`AudioutCore`, via
`.package(path: "../ProbeKit")`) runs it against its built-in microphone, and
the iPhone companion runs it against the phone's microphone. It is a root
package rather than a folder inside either app precisely so there is one copy
of the file the two ends must agree on.

The technique is the Mac's shipped mic-probe calibration (roadmap 064): a DOWN
sweep (2000→500 Hz) on the reference lane and an UP sweep (3200→10000 Hz) on
the target lane, played at the same scheduled moment, recovered from one
recording by matched filter. One mic hears both speakers, so capture latency
and the shared start are common to both arrivals and cancel in the DIFFERENCE.

## Rules

- **This is the single home of `SyncProbeCorrelator.swift`.** It used to be
  hand-copied into the phone's own package; the copy is gone and must not come
  back. The Mac stages the sweeps this file describes, so a divergence between
  the two ends is not a local bug — it is a measurement of the wrong signal
  reported as a confident number.
- **`ProbeAnalyzer.sweepSeconds` (1.0) is a hand-copy**, of
  `AlignmentTickInjector.probeSweepSeconds` in AudioutCore. The Mac plays a
  sweep of exactly that length; this package renders its own to match against.
  It stays a copy because the dependency only runs one way — this package may
  never import AudioutCore — so the two constants have to move together by hand.
- **The lane assignment is the Mac's choice, not this package's.** DOWN is the
  reference lane, UP is the target (Bluetooth) lane. Swapping the labels here
  silently reverses the sign of every measurement, and nothing fails loudly
  when it happens.
- **The caller reports the raw measurement; the Mac owns trim semantics.**
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
- **MIT, and every source file says so.** The package carries its own `LICENSE`
  and an `// SPDX-License-Identifier: MIT` line in each Swift file. That is
  load-bearing twice over: the Mac app is GPL (it links the vendored sender in
  `AirPlayEngine/`), and the iPhone companion ships closed-source. A GPL header
  here would relicense the package out from under the phone; no header at all
  would default to all-rights-reserved, which is wrong for source published
  beside the GPL tree. Never put a GPL header on anything in here, and never
  move GPL-derived code in.

## Build / test

Bare `swift test` and `swift build` are **blocked by a repo hook**. Build and
test this package through the repo's own wrappers, from the repo root:

```
bash scripts/build.sh
AUDIOUT_TEST_PACKAGE=ProbeKit bash scripts/run-tests.sh
```

`build.sh` reaches this package through AudioutCore, which depends on it, so a
compile error in here fails the app build. **The tests need the override.**
SwiftPM never runs a DEPENDENCY package's test targets, so a plain suite run —
and the pre-commit guard, which runs the same thing — builds ProbeKit but never
executes `ProbeKitTests`. Run the line above after changing anything in here.
It is pure computation on synthetic recordings: no hardware, no phone, seconds
to run.

`Package.swift` keeps `.macOS(.v14)` alongside `.iOS(.v17)` so the package
builds and tests on the Mac at all; the iOS floor is what the companion needs.

## Map

- `Package.swift` — swift-tools-version 6.0, iOS 17 / macOS 14, ZERO
  dependencies, one library product `ProbeKit`.
- `LICENSE` — MIT.
- `Sources/ProbeKit/ProbeAnalyzer.swift` — the phone's reduction of a capture
  to one number: `ProbeAnalysis` (`offsetMs`, `confidence`),
  `ProbeAnalysisError`, and `analyze(recording:ambientEndSample:)`, which
  renders both sweeps at the capture's own sample rate, tries the SNR-weighted
  correlation first and falls back to the plain matched filter when weighting
  finds nothing. Holds the hand-copied `sweepSeconds`, the lane assignment, and
  the note on what changes when the microphone can be carried (~2.9 ms per
  metre of distance asymmetry).
- `Sources/ProbeKit/SyncProbeCorrelator.swift` — `SyncProbe` (sweep design and
  synthesis, the two lanes' disjoint bands) and `SyncProbeCorrelator` (FFT
  cross-correlation, optional ambient-noise weighting, robust
  peak-to-sidelobe confidence, sub-sample peak interpolation). Its header
  carries the reasoning behind the band split and the confidence estimator —
  read it before touching either.
- `Tests/ProbeKitTests/SyncProbeCorrelatorTests.swift` — the filter itself
  against synthetic scenes rendered at analytic fractional delays: sub-sample
  accuracy, the two lanes separating with a 23 dB level imbalance, echoes, hum,
  and the refusals.
- `Tests/ProbeKitTests/ProbeAnalyzerTests.swift` — the contract with the Mac,
  using the SHIPPING sweep designs: a known offset recovered in milliseconds at
  the sample rates a phone hands us, the sign, and the refusals.
