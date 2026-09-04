# Mic-probe sync calibration — direction + build plan

2026-08-27. Distilled from the "Beyond the Tick" research brief (artifact
prepared for Alec, August 2026); this file is the in-repo record. It REVERSES
the 2026-08-07 "mic-based auto-offset — do not revive" cut in
`per-device-trim-spec.md` (amendment recorded there).

## The finding

The Bayesian by-ear wizard is already at the information-theoretic ceiling for
a human answerer (~1.58 bits max per 3-way answer, ~6.4 bits needed → ~15
answers is the floor). Getting faster means more bits per observation, and one
mic sample is worth thousands of answers. The mature path is the one-shot
acoustic probe: play a known signal per speaker, record with the Mac's
built-in mic, matched-filter, subtract arrivals — the DSP behind every AV
receiver calibration and Sonos Trueplay.

Why the difference measurement is trustworthy (the BeepBeep observation): one
mic hears both speakers, so capture latency and the probes' shared scheduled
start cancel in the arrival DIFFERENCE. What survives is per-speaker output
latency plus mic distance asymmetry (~2.9 ms/m — inside the ±6 ms blend bar
unless the Mac sits far off-centre; one sentence of UX copy).

## The plan, in leverage order

1. **Probe pipeline (building now).** Up-sweep to one speaker, down-sweep to
   the other, simultaneously; built-in mic capture; SNR-weighted matched
   filter; peak pair → offset. Also lands roadmap 062's reconnect-survival
   measurement as a superset.

   **The probe rides the device's own volume.** Nothing normalises it: a
   speaker turned well down, or far off across a room, simply arrives quiet
   and the measurement's margin shrinks with it. The lane amplitudes are held
   deliberately low — this is a chirp the user is sitting next to, and a
   near-full-scale sweep is the "heavy static" complaint again — so margin is
   bought from the *statistic* (see the confidence note in
   `SyncProbeCorrelator`) rather than from loudness. If that ever runs out,
   the option is briefly standardising output volume for the sweep the way an
   AVR's room calibration does; it is NOT built, and it needs its own UX
   decision before it is.
2. **Wire into the wizard, don't replace it.** Measurement becomes the
   zero-click `openingProposalMs` (seam already exists end-to-end,
   `PopoverController.startBTAlignmentWizard` → `BTAlignmentWizardSession` →
   `BTAlignmentPosterior`); by-ear confirm stays the gate; the full
   questionnaire stays as the mic-denied/noisy-room fallback. The flat-prior
   fence stands: the measurement feeds the PROPOSAL, never the prior.
3. **Seed database.** Accumulate per-device-model latency from accepted
   results; known model → instant opening proposal (the AmpMe lesson:
   a good first guess beat a fragile measurement for most users).
4. **Only then chase "always right".** Auto re-probe on connect/silence gaps.
   Continuous estimation from the music itself has an unsolved same-signal
   separation problem for our topology — wait for field data. Auracast is
   Apple-blocked as of mid-2026; keep the sender seam shaped for it, build
   nothing.

## Design decisions already taken

- **SNR weighting, not PHAT whitening.** The 2026 TDOA-probing result:
  trained estimators learn magnitude-aware frequency weighting and never
  learn PHAT; whitening throws away per-band SNR. Implemented as
  ambient-noise-spectrum division in `SyncProbeCorrelator` (license-clean,
  `Sources/ProbeKit/SyncProbeCorrelator.swift` in audiout-shared).
- **Audible-pleasant, not ultrasonic.** A2DP codecs roll off 14–18 kHz
  unpredictably per device; probes stay 500 Hz–10 kHz. A short branded chirp
  on connect is the accepted UX (AVRs trained everyone).
- **Confidence gate, then fall back.** A peak-to-sidelobe threshold rejects
  shaky measurements → wizard, never a bad number. Sidelobe search excludes a
  post-peak reverb shadow: echoes are the room's answer, not evidence against
  the measurement.

## Build state (2026-08-27)

All four steps are BUILT, none live-tested (Alec's call — live checks later):

1. DSP core — `SyncProbeCorrelator.swift` + tests.
2. `mic-probe-spike` CLI (HFP survival check on hardware still OWED).
3. In-app pipeline: `AlignmentTickInjector.stageProbe/armProbe` renders the
   sweeps into the two wizard lanes (DOWN→engine/Mac, UP→Bluetooth); the
   backend's existing arm gate starts the probe instead of the first tick
   and hands over to the tick grid on completion
   (`NativeCaptureCoordinator.stageWizardMicProbe`); `BuiltInMicRecorder` +
   `MicProbeSession` capture and reduce to Δ; TCC surface added
   (make-app.sh `NSMicrophoneUsageDescription` + plutil gate, audio-input
   entitlement, `MicCapturePermission`).
4. Wizard wiring: `PopoverController.startBTWizardMicProbe` runs a probe on
   every tick-on edge when the pair spans two fan-outs; the result —
   `preview-in-force + Δ` — arrives via
   `BTAlignmentWizardSession.offerMeasuredProposal` as the proposal to
   confirm by ear (flat prior untouched). A preview change mid-probe
   (answer, reference swap) voids the measurement via a generation counter.

Known v1 seams: the FIRST run on a fresh install prompts for the mic
mid-run, so that run usually falls back to by-ear and the SECOND run
measures; BT-vs-BT pairs never probe (same fan-out, unattributable
arrivals); probe only wired for the native backend (mock never prompts).

## Constraints from prior repo findings (read before building the capture leg)

- **HFP hazard is unresolved on hardware.** Opening a BT device's OWN mic
  collapses A2DP to narrowband HFP (PLAN-UNIVERSAL-SYNC risk R-A2DP/HFP,
  highest; live bug: roadmap 019). BT-SPIKE-OFFSET was cut before running, so
  "does A2DP survive while the BUILT-IN mic records" is still unproven. The
  measuring tool now exists — `mic-probe-spike` (an `AudioutCore` executable
  target): dual-sweep playback on a chosen output, built-in-mic capture
  pinned by device ID (never the default input, which may BE the headset),
  matched-filter analysis, and an HFP verdict from the output device's
  nominal sample rate before/during/after capture. Run from a terminal
  against a BT speaker:
  `swift run --package-path AudioutCore mic-probe-spike --output "<speaker>"`
  (`--selftest` for the hardware-free wiring check). Live run on real
  speakers still OWED.
- **No mic capture exists anywhere in the repo.** New TCC surface:
  `NSMicrophoneUsageDescription` in `scripts/make-app.sh` (with the same
  plutil gate as the other three), `com.apple.security.device.audio-input`
  entitlement, `kTCCServiceMicrophone` preflight via the `tcc-probe` pattern.
- **BT clocks settle ~60 s after connect** (bt-spike-findings 2026-08-07:
  chaotic 0–42 s, then ±0.01 ms). A probe fired immediately on reconnect
  measures the chaos, not the speaker.
- **Value spaces:** a measurement lands as measured LATENCY
  (`BTTrimStore.saveLatencies` → `BTSyncedSink.setOffsetMs`, live splice,
  never a rebuild); the wizard's `invertsEstimate` handles the sign.
