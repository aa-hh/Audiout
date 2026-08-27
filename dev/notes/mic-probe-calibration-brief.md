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
  `AudioutCore/Sources/AudioutCore/SyncProbeCorrelator.swift`).
- **Audible-pleasant, not ultrasonic.** A2DP codecs roll off 14–18 kHz
  unpredictably per device; probes stay 500 Hz–10 kHz. A short branded chirp
  on connect is the accepted UX (AVRs trained everyone).
- **Confidence gate, then fall back.** A peak-to-sidelobe threshold rejects
  shaky measurements → wizard, never a bad number. Sidelobe search excludes a
  post-peak reverb shadow: echoes are the room's answer, not evidence against
  the measurement.

## Constraints from prior repo findings (read before building the capture leg)

- **HFP hazard is unresolved on hardware.** Opening a BT device's OWN mic
  collapses A2DP to narrowband HFP (PLAN-UNIVERSAL-SYNC risk R-A2DP/HFP,
  highest; live bug: roadmap 019). BT-SPIKE-OFFSET was cut before running, so
  "does A2DP survive while the BUILT-IN mic records" is still unproven —
  prove it first, with a standalone `dev/` probe in the `audiocap` mould. Pin
  the built-in mic by device ID, never the default input (which may BE the
  headset).
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
