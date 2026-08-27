# dev/phase-spike

## Purpose

Throwaway feasibility harness that measures the achievable phase-lock
precision of the kind of `AVAudioEngine` graph `SyncedLocalSink` builds, and
evaluates candidate rate-correction mechanisms for follow-on work. Full plan
context: `../../docs/plans/synced-local-airplay-plan.md`; go/no-go status and
the writeup this harness feeds: `../notes/phase-lock-spike-findings.md`.

Deliberately does **not** link `AudioutCore` — nothing here is vendored into
the app; this package is disposable measurement code.

## Notable Patterns

- **`PlanMath.swift` re-derives `SyncTiming.plan`** — the two must be kept in
  sync by hand if `SyncTiming.plan` changes.
- **Silence is enforced in triplicate for `realdevice`**: zeroed samples,
  `isSilence.pointee = true`, and `mainMixerNode.outputVolume = 0`. It still
  opens a real IO cycle on the default output device, which can click a
  speaker relay on some Macs — that's why it's a separate opt-in subcommand
  left for a human to run, not bundled into `offline`, and why `--seconds N`
  (default 4s) should be kept short in ad-hoc runs.
- **`offline` never touches a real device** — all four of its probes run
  through `AVAudioEngine.enableManualRenderingMode(.offline, …)`, so
  `mHostTime` is never flagged valid there; only `realdevice` can measure
  real hostTime jitter.
- **Click detection is bound-based, not threshold-based**: `Signal.maxAbsFirstDiff`
  is compared against `Signal.sineDiffBound` (the theoretical max sample-to-sample
  delta for a clean sine at that frequency/rate); a ratio ≥ ~1.5 flags a possible
  discontinuity.

File map: see README.md.
