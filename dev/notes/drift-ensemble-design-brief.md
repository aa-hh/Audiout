# Drift tracking: ensemble estimator design, 2026-09-13

Builds on `drift-tde-algorithms-brief.md` (the literature) and the live findings in
`.scratch/passive-drift-tracking/HANDOFF.md`. Code: `PassiveDriftCorrelator.swift` and
`SyncProbeCorrelator.swift` in audiout-shared; `PassiveDriftSampler.swift` (sampler
plus the `PassiveDriftTracker` loop) in the Mac app.

The question: which estimators to run together on one 4 s window so a 20 to 90 ms
jump on one of two Bluetooth speakers is caught to ±1 ms at 50 dBA. Tonight one plain
correlation scored 2.5 to 2.9 against a threshold of 3, refused windows' best lags
wandered 455 to 534 ms, and an 11 ms desync at 19:51 UTC was missed by everything.

Below the "what exists" facts, everything is design reasoning from first principles
unless a source is named.

## 0. One window today

Capture: 4 s from the built-in mic at its own rate (48 kHz assumed; the sidecar
records it). Reference: the retained 44.1 kHz mix, linearly resampled to the capture
rate, cut to 4 s minus (largest baseline + 120 + 50 ms), about 3.3 s. Both band-limited
300 Hz to 8 kHz. One cross-correlation by FFT of length 2^19, one peak search per
speaker inside ±120 ms of its baseline, one score: peak over the expected extreme of a
Gaussian background sized from the whole correlation's median. Tonight's 14 windows:
two accepted (3.12, 3.29), two merged (4.18, 2.52), the rest refused with best
candidates 0.96 to 2.52.

The reference is known exactly, so every estimator below is a per-frequency weighting
of ONE cross-spectrum (Knapp and Carter 1976): two forward transforms, then one
inverse per estimator. That is what makes an ensemble cheap.

## 1. The ensemble

Five estimators on the cross-spectrum C(f) = Capture(f) · conj(Reference(f)), with
P(f) = |Reference(f)|² and floor ε at a few percent of P's in-band mean (sweep it):

| # | Estimator | Weight | Role |
|---|---|---|---|
| E1 | plain matched filter (today's) | 1 | fine position on the right lobe; the one that survives a quiet passage |
| E2 | half whitened | 1 / (P + ε)^0.5 | the working estimator: harmonic self-similarity removed, noise bands not yet over-voted (Donohue et al. 2007: best exponent near 0.4 for speech) |
| E3 | fully whitened by the reference | 1 / (P + ε) | the Roth weight; with a clean known reference this is the least-squares room impulse response, the closed form of what WebRTC's matched filter fits adaptively. Sharpest lobe, weakest at 50 dBA |
| E4 | five octave sub-bands of E2 | E2 masked to 300–600, 600–1200, 1200–2400, 2400–4800, 4800–8000 Hz | agreement across bands (Cobos et al. 2020): an arrival peaks at one lag in every band, a beat or a bass repeat does not |
| E5 | onset-envelope correlation | time domain | lobe picker only: half-wave-rectified log-energy difference (Bello et al. 2005; Ellis 2007) at 1 ms hop over the same ±120 ms. Resolution ~2 ms, blind to harmonic structure |

Per speaker window each estimator reports its best lag and a peak-to-second-peak
ratio: the peak over the next distinct maximum more than 5 ms away inside the window.
That ratio answers "is this lobe better than the music's next repeat", which is the
decision being made. E1 keeps today's background ratio for continuity.

**Combination: agreement, not weighted voting.** The estimators see the same data, so
their errors on the true lag are correlated and a weighted sum counts one piece of
evidence several times. What is nearly independent is WHERE each fails: plain toward
bass structure, whitened toward noise bands, each band toward its own repeat period.
So the signal is agreement of location:

1. Fine answer: E2's lag, refined by E1's parabola when E1 agrees within 0.5 ms.
2. Core agreement: E1 and E3 within 1.5 ms of E2, E5 within 3 ms. At least 2 of 3.
3. Band agreement: at least 3 of the 4 upper bands within 1.5 ms of E2 (the 300 to
   600 Hz band's lobe is 3 ms wide: logged, not counted).
4. Margin: E2's second-peak ratio at least 1.5 (fit on the harness; start there).

Accept when 2, 3 and 4 all hold. Log both counts and the ratio on every window
whatever the verdict. This replaces `minPeakToSidelobe`, and the 2.3 ruling goes with
it once plan step 2 lands. A joint likelihood is the upgrade path once the harness has
score distributions per estimator; not before, because it needs noise models nobody
has measured.

**Expected behaviour on tonight's failures.**

- *Loop-based music.* An exact loop repeats in every band and in the envelope, so all
  five agree on the true lag AND on the lag one period away; rule 4 refuses because
  the second peak matches the first. Refused, never wrong. Windows over different
  material resolve it (section 2); the periodicity check still refuses bare loops
  before any correlation runs.
- *Quiet passage.* E3 and the upper bands fail first, E1 and E5 last; agreement
  collapses and rule 2 or 3 refuses. The −50 dBFS check still catches silence.
- *Room noise.* Localised in frequency, so it costs one or two bands, not four. An
  ambient slice, if the Mac ever supplies one, multiplies in as today.
- *Two speakers merged.* E1's lobe is milliseconds wide, so speakers within a few ms
  merge. E2 and E3 lobes are 0.1 to 0.3 ms wide, so a pair 2 ms apart becomes two
  peaks. `peakSeparationSeconds` (5 ms) must drop to about 1 ms with whitening, or the
  sampler keeps reading a resolved pair as one merged arrival. Two peaks under 10 ms
  apart sit in the policy's leave-alone band, so nothing moves.
- *24 ms wander between refused windows.* Those lags were each window's strongest
  bass-structure lobe; E3 and the upper bands do not share them, so rule 3 refuses.
  Some of tonight's wander was real: the merged rule and the owner's trims moved the
  baselines between windows.

## 2. Evidence across windows

Average E2's correlation, never E1's. Whitened, the background is noise: different
material adds incoherently while a fixed arrival adds coherently, so the true peak
grows about √N over N windows. Unwhitened, the music structure adds too, which is why
8 s equalled 4 s tonight. Keep only the ±120 ms slice per speaker (11,500 floats,
46 KB) from each of the last three windows, in absolute delay from the shared zero so
they add directly. Cross-check by vote: accept the sum's peak only when at least two
contributing windows' own E2 lags sit within 1.5 ms of it. A jump between windows
shows as two peaks in the sum, which is the detection and brackets the moment. Any
baseline change (trim, merged rule, re-baseline) empties the accumulator.

Reaction time: a window that passes section 1 fires at once; the sum only rescues
marginal windows, so at 3 min cadence it adds 3 to 6 min. The fix is not a shorter
fixed interval. A near-miss (two of the three rules pass, or the margin is within 20%
of its bar) should schedule the next window 30 s later, at most three times, then fall
back to 3 min. Event triggers already take a window within 5 s. A shorter fixed
interval costs the orange mic indicator every cycle and buys nothing while windows are
refused for material rather than timing; revisit only if per-window accept rates reach
90% and detection latency is what remains.

## 3. The pacing-clock step as a prior

`BTClockStability` polls `AudioDeviceGetCurrentTime` on the Bluetooth device once a
second and tracks (samples ÷ nominal rate − host elapsed) in ms; a step over 2 ms is
logged as `bt_clock_jump` (uid, signed ms) and triggers a window. A step of +s ms says
the host stack now believes the device consumed s ms more audio than wall time
allowed. Two mechanisms fit: the stack re-centred its jitter buffer (playout moved by
about s, sign unknown) or corrected its own bookkeeping (playout unchanged). The
bench note's Move 2 trace (32 steps, net −353 ms in 42 s, then pinned) reads as the
second; tonight's steps "audible as a dip that came back re-timed" read as the first.
Nobody has paired a step with an acoustic reading.

**Validation.** Fit delay_change = g · Σ(steps since the last accepted acoustic reading
for that uid) + c over accepted windows with no correction between. About 20 pairs.
g near ±1 with residual under 5 ms means playout changes; g near 0 means bookkeeping.
Two log additions make it possible: a once-a-minute per-sink line with the cumulative
deviation (steps under 2 ms are invisible today, one candidate for the unseen 11 ms
desync), and `hostNanos` in `drift_window_result` for the join. No `bt_clock_jump`
line exists in either local log file yet; the data set starts empty.

**Use, in order of proof required.** (a) Prior: centre the search on baseline +
g·Σsteps and narrow the half-width from 120 to 40 ms while a step is pending; fewer
admitted repeats, higher accept rate. Safe once g's sign is known. (b) Direct
correction: only after the fit holds, only inside the 10 to 40 ms silent band, and
always followed by the acoustic verify, which today is a no-op (`DriftCorrectionApplier`
treats `.scheduleVerify` as ignore). Never for a surfaced ≥ 40 ms move without a mic
reading. A step no later window confirms is logged as a miss and lowers trust in g.

## 4. Offline validation harness

Python 3, numpy and scipy only (venv in the session scratchpad). Inputs:
`~/Library/Logs/Audiout/drift-windows/<stamp>-{ref,cap}.f32` (Float32 mono
little-endian) and `<stamp>-meta.json` (referenceRate, captureRate, baselines with
uid, expectedDelayMs, anchor). Extend the sidecar with trigger reason, the app's own
verdict and candidates, and `hostNanos`, so the harness checks itself against the app
and joins `telemetry.jsonl`.

`replay.py`, per window: resample and band-limit exactly as the Swift does (same
biquads, same linear interpolation), one cross-spectrum, every section-1 estimator,
the multi-window sum over consecutive stamps, then one row per speaker: stamp, uid,
expected delay, label, per-estimator lag and score, core count, band count, margin,
verdict, error against the label. Summary: accept rate and error RMS on labelled-good
windows, false accepts on garbage, detection delay on forced jumps. Step zero, before
any estimator work, answers the owner's pipeline suspicion: correlate over the FULL
lag range (is the arrival outside ±120 ms?), report capture peak level (clipping) and
per-band coherence, and reproduce the app's score within 5% on each window so the
harness is known to match the Swift path.

**Labelled set.**

- *Known-good:* freshly calibrated speakers; one 60 dBA window accepted at ≥ 3.5
  before and after the run pins the truth; then 10 or more windows at 50 dBA over
  varied material.
- *Forced jump, exact:* a trim change is a ring seek in `BTSyncedSink`, so a +30 ms
  trim IS a 30 ms delay step with known sign and time. The cleanest ground truth.
- *Forced jump, real:* power-cycle one Move (a reconnect rolls a fresh 20 to 90 ms
  latency per the bench note); pin the new truth with one loud window, then dump
  quiet ones. Exercises attribution and the merged-to-split transition.
- *Garbage:* both Moves muted at their own buttons while the app streams (room only in
  the capture), plus synthetic pairs of one window's reference with another's capture:
  an unlimited zero-arrival set.
- *Loops:* 10 or more windows of loop-based tracks with the pinned delay.

## 5. Cost on the Mac

FFT length 2^19 as today (192,000 + 158,000 samples). Today's path already runs about
seven 2^19 transforms per window (correlation 3, suitability autocorrelation 3,
bandwidth 1). The ensemble shares two forward transforms and adds one inverse per
estimator: E1, E2, E3 and five bands make 8, about 12 in all; the envelope path is
4,000 short frames per signal, negligible. Estimate (5·N·log₂N per complex transform,
about 50 Mflop, a few ms each with vDSP on Apple silicon): 40 to 100 ms of one core
per window, once per 3 min, under 0.1% average. Memory: 4 MB per complex spectrum;
cross-spectrum, one weighted copy and one output at a time add about 16 MB transient,
freed when the window ends. The accumulator holds 3 × 46 KB per speaker. All of it
stays on the existing serial `com.audiout.passive-drift` queue, never the render or
mic thread. Acceptance: a ProbeKit test times `analyzeWithCandidates` on a 4 s window
under 200 ms.

## 6. Ranked plan

Where things live: estimators, the agreement rule, per-window diagnostics and a pure
accumulator that sums correlation slices stay in ProbeKit (DSP only: no speakers,
clocks or queues). Cadence, near-miss retry, the clock prior, the verify, the dump
and every log line are the Mac app's.

1. **Harness plus labelled set** (Python; Mac: sidecar additions). Accept: harness
   reproduces the app's score within 5% on every dumped window; step zero says
   whether the arrival is present, where, and whether anything clips; at least 10
   known-good, 40 garbage and one exact forced-jump window in hand.
2. **ProbeKit: E2 and E3 whitening, second-peak margin, 1 ms peak separation.**
   Accept: at the chosen exponent, true arrivals accepted in ≥ 90% of known-good
   windows at 50 dBA; 0 of 40 garbage windows accepted; accepted error RMS ≤ 1 ms.
3. **ProbeKit: sub-bands, envelope, agreement rule replacing `minPeakToSidelobe`.**
   Accept: step-2 numbers hold; 0 wrong-lobe accepts on the loop set; the exact forced
   jump read in the first accepted window after it, within 2 ms.
4. **Mac: near-miss retry and the multi-window sum** (accumulator in ProbeKit).
   Accept: of known-good windows refused singly, ≥ 70% accepted by the sum of three;
   0 accepts on garbage triples; the real forced jump shows as a split peak.
5. **Mac: cumulative clock-deviation logging, the g fit, the narrowed-search prior.**
   Accept: ≥ 20 step-to-reading pairs logged; g, c and residual reported; with the
   prior on, harness accept rate on step-flagged windows does not fall.
6. **Mac: build the verify half of decision 7, then clock-step direct correction
   inside 10 to 40 ms.** Accept: every guessed or clock-driven correction is followed
   by a window that confirms or reverts it, visible in the log.

## 7. What not to do

- No per-speaker signal tweaks (level dips, notches, watermarks) and no injected probe
  during playback: spec decisions 1 and 7. Nothing above needs either; attribution
  comes from baselines, the merged rule and clock events.
- No full phase-only correlation as the decider: at 50 dBA noise bands get equal vote
  (Cobos et al. 2020). E3 is one voice, not the answer.
- No weighted average of estimator lags: the same data counted several times looks
  like confidence and is not.
- No summing of unwhitened correlations, no longer windows: the music's structure sums
  with the signal; tonight's 8 s result shows it.
- No lower threshold: refused garbage reached 1.9 and 2.52; the margin must come from
  the estimator.
- No learned estimator yet: there is no labelled set. Step 1 makes one.
- No clock-step correction before the g fit exists and the verify runs.
- No super-resolution of an in-sync pair: needs signal-to-noise the room lacks, for a
  state the product wants.

## Sources

- Knapp, C. H. and Carter, G. C., "The generalized correlation method for estimation of
  time delay", IEEE Trans. ASSP 24(4), 1976, doi 10.1109/TASSP.1976.1162830 (Roth,
  SCOT, PHAT, Eckart, maximum-likelihood weights).
- Donohue, K. D., Hannemann, J. and Dietz, H. G., "Performance of phase transform for
  detecting sound sources with microphone arrays in reverberant and noisy
  environments", Signal Processing 87(7), 2007 (partial whitening exponent).
- Cobos, M., Antonacci, F., Comanducci, L. and Sarti, A., "Frequency-sliding
  generalized cross-correlation", IEEE/ACM TASLP 2020, arXiv:1910.08838 (sub-band
  agreement, phase-only limits).
- Bolme, D. et al., "Visual object tracking using adaptive correlation filters",
  CVPR 2010 (the peak-to-sidelobe ratio the current score derives from).
- WebRTC AEC3 `modules/audio_processing/aec3/matched_filter.cc` and
  `api/audio/echo_canceller3_config.h` (adaptive matched filter on program audio,
  residual-energy acceptance at 0.2).
- Bello, J. P. et al., "A tutorial on onset detection in music signals", IEEE Trans.
  Speech and Audio Processing 13(5), 2005, doi 10.1109/TSA.2005.851998.
- Ellis, D. P. W., "Beat tracking by dynamic programming", J. New Music Research
  36(1), 2007 (onset-strength envelope).
- Internal: `dev/notes/drift-tde-algorithms-brief.md`,
  `dev/notes/bt-latency-stability-research-2026-09-05.md`,
  `.scratch/passive-drift-tracking/HANDOFF.md` and `spec.md`,
  `~/Library/Logs/Audiout/telemetry.jsonl` (2026-09-13 windows).
