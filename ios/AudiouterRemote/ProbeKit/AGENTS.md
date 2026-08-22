# ios/AudiouterRemote/ProbeKit

## Purpose

The alignment-probe DSP, as a standalone SwiftPM package: it takes the phone's
recording of the alternating-mute tick probe as `[Float]` and returns how late
the target speaker sounded relative to the reference. Nothing else — no audio
I/O, no networking, no app concepts, no dependencies beyond Accelerate.

Built for the BT auto-cal spike; contract in
`dev/notes/bt-autocal-spike-spec.md`.

## Rules

- **`TickTemplate` is a hand-copy of `AlignmentTickInjector`'s tick synthesis**
  (`AudiouterCore/Sources/AudiouterCore/AlignmentTickInjector.swift`). The Mac
  plays that tick, this package matches against it, and the two must stay
  identical. `ios/` may never depend on AudiouterCore (see `ios/AGENTS.md`), so
  the duplication is deliberate — change one, change the other.
- **The phone reports the raw measurement; the Mac owns trim semantics.**
  `offsetMs` is positive when the target sounded LATE. Do not fold a sign
  convention or a trim calculation in here.
- **Refuse rather than guess.** A recording that does not match the expected
  REF/TGT block pattern throws `patternMismatch`; too few usable block pairs
  throws `insufficientPairs`. There is no "best effort" answer — a wrong
  alignment number is worse than none.
- **`vDSP.FFT<DSPSplitComplex>` is the REAL FFT**, not a complex one: its
  `log2n` counts real samples and the split-complex buffers hold the even/odd
  halves, with bin 0 packing DC and Nyquist together. Feeding it a complex
  signal with zero imaginary parts silently transforms only half the buffer.

## Build / test

```
swift test --package-path ios/AudiouterRemote/ProbeKit
```

Run it directly. This package is the documented exception to the repo's
`scripts/run-tests.sh` rule — the wrapper only knows AudiouterCore, and the
whole suite is seconds long. It is pure computation on synthetic recordings, so
it needs no hardware and no phone.

## Map

- `Sources/ProbeKit/ProbeAnalyzer.swift` — the public API and the measurement:
  blocks, grid fit, REF→TGT pairs, confidence.
- `Sources/ProbeKit/MatchedFilter.swift` — whitened cross-correlation and the
  vDSP real-FFT wrapper.
- `Sources/ProbeKit/TickPicker.swift` — correlation trace to tick arrivals.
- `Sources/ProbeKit/TickTemplate.swift` — the tick, re-synthesized at the
  recording's sample rate.
- `Tests/ProbeKitTests/SyntheticProbeRecording.swift` — builds recordings with a
  known injected offset, noise, reflections and clipped boundary ticks. Every
  claim this package makes about accuracy comes from here.
