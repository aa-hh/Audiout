# Drift tracking with music as the probe: delay-estimation research, 2026-09-13

Which correlation method finds a Bluetooth speaker's arrival in a microphone
capture when the only probe is the music itself. Primary sources only. The code
under discussion is `~/Projects/audiout-shared/Sources/ProbeKit/PassiveDriftCorrelator.swift`
and `SyncProbeCorrelator.swift`; the live numbers are from the 2026-09-13 living-room
run (MacBook Pro mic, two Sonos Move).

## The problem

The Mac keeps the audio it sent (the reference) and records a few seconds on its own
mic (the capture). It cross-correlates the two, band-limited to 300 Hz to 8 kHz, and
looks for a peak within ±120 ms of each speaker's expected delay. Score is peak over
the largest value a Gaussian background of that size would reach, background taken as
a median over the whole correlation; threshold 3. Goal: catch a 20 to 90 ms jump on one
speaker, to ±1 ms. Live: true arrivals scored 2.5 to 2.9 at normal level, refused
windows' best false peaks reached 1.9, and an 8 s window scored no better than 4 s.

That last fact is the diagnosis. With a plain cross-correlation the output is the
reference's own autocorrelation passed through the room, so the "background" is the
music's self-similarity, not noise. More seconds of music bring proportionally more
self-similarity. Longer windows cannot help until the reference's spectrum is taken out.

## 1. Weighting the cross-correlation

Knapp and Carter (IEEE Trans. Acoustics, Speech and Signal Processing 24(4), 1976,
doi 10.1109/TASSP.1976.1162830, abstract at
https://ui.adsabs.harvard.edu/abs/1976ITASS..24..320K/abstract) define the generalized
cross-correlation: multiply the cross-spectrum by a per-frequency weight before the
inverse transform. Roth divides by one input's power spectrum (they note this is the
Wiener-filter estimate of the impulse response between the two signals); SCOT by the
geometric mean of both; PHAT by the cross-spectrum magnitude, keeping phase only;
Eckart weights by signal power over the product of the noise powers; the
maximum-likelihood weight is coherence-based and equals Eckart at low signal-to-noise
ratio.

With a clean, exactly known reference, the maximum-likelihood weight reduces to
phase-only correlation scaled per band by the program's signal-to-noise ratio at the
mic. The current no-ambient-slice path is unweighted: its output is the reference's
power spectrum times the room, bass-heavy for music, so the peak is a broad lobe on
structured sidelobes. The ambient-slice path divides by the noise spectrum only, which
is the maximum-likelihood weight up to the room's magnitude response: optimal for fine
accuracy once the right lobe is chosen, useless for choosing it. The live fault is lobe
choice (false peaks at 1.9 against true peaks at 2.5), so an ambient slice attacks the
wrong term.

Cobos, Antonacci, Comanducci and Sarti (IEEE/ACM Trans. Audio, Speech and Language
Processing 2020, https://arxiv.org/abs/1910.08838) summarise the field: phase-only
correlation "has been repeatedly shown to be a suitable alternative" in real reverberant
rooms, but "its performance can only be considered optimal under uncorrelated noise
conditions and a high signal-to-noise ratio". Their own results (Section V) show the
split: phase-only correlation has far fewer wrong-lobe answers than plain correlation,
while at high signal-to-noise ratio plain correlation is fractionally more accurate on
the answers that are right ("below 1 sample").

Partial whitening splits the difference. Donohue, Hannemann and Dietz (Signal
Processing 87(7), 2007, pp. 1677 to 1691,
https://www.sciencedirect.com/science/article/abs/pii/S0165168407000370) raise the
cross-spectrum magnitude to a power between 0 (plain) and 1 (phase only); their
companion paper on delay estimation with speech under reverberation plus independent
noise reports the best results near 0.4, better than either end
(https://www.semanticscholar.org/paper/d1980acf1d70847184b70bfaeae4d2ff105ba907). Those
numbers are for speech; nobody has published the same sweep for music.

## 2. Background and confidence

The code's peak-to-sidelobe ratio is Bolme et al.'s (CVPR 2010,
https://www.cs.colostate.edu/~draper/papers/bolme_cvpr10.pdf): peak over the mean and
standard deviation of everything outside a small window around it. Their thresholds are
for image tracking and do not transfer; what does is that the ratio means "how far above
noise" only when the sidelobes are noise. With music they are not, so the median
underestimates the tails and false peaks reach 1.9 where pure noise reaches about 1.

WebRTC's echo canceller solves the same problem (known reference, mic capture, unknown
delay, program audio as probe) and scores differently: it fits a short adaptive filter
per lag window and calls a lag reliable when the residual after subtracting the fitted
echo is below 0.2 of the capture energy, i.e. the reference explains at least 80% of
what the mic heard
(https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/aec3/matched_filter.cc,
threshold `delay_candidate_detection_threshold = 0.2f` in
https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/echo_canceller3_config.h).
That test is independent of the source's autocorrelation. It also runs the estimator
signals through a high-pass filter because that "improves the adaptation of the matched
filters in noisy environments"
(https://webrtc.googlesource.com/src/+/6bf5a0d5b6784eba4a6c4fc730a848721acbcee1), the
same reason this code band-limits at 300 Hz.

No primary source was found that defines a peak-to-second-peak ratio for delay
estimation; the idea is straightforward but uncited here.

## 3. Onsets and envelopes

Lin (arXiv:2604.01524, 2026, https://arxiv.org/abs/2604.01524) localises speakers from
detected onsets because at an onset the mic signal "is dominated by direct-path
components" before reflections arrive, and reports reliable results at reverberation
times up to 1 s. Speech-only, and it estimates direction, not millisecond delay. An
envelope is a low-bandwidth signal, so envelope correlation cannot reach ±1 ms on its
own; it can pick the right repeat of a loop, whose bars differ more in transient
pattern than in harmonics. No music-specific evidence was found.

## 4. Sub-band agreement

Cobos et al. (above) compute one phase-only correlation per sliding frequency band and
show the stack is rank one for a single clean path: a true delay appears as the same
peak in every band, noise and reflections do not. Keeping only the dominant rank
reduced wrong-lobe answers by about 35 percentage points at 0 dB signal-to-noise ratio
in anechoic tests and more than 40 points at 10 dB in a 0.3 s reverberation room
(Sections V-C, Figs. 6 and 7). They also observe the representation "shows clearly
which frequency bands are actively contributing to a reliable time delay estimate".
For music this is the useful property: a bass line's repeat period and a hi-hat's are
different, so a peak that survives band agreement is an arrival, not a beat.

## 5. Model-based estimation with a known source

Benesty's adaptive eigenvalue decomposition (J. Acoust. Soc. Am. 107(1), 2000, pp. 384
to 391, https://pubmed.ncbi.nlm.nih.gov/10641647/) blindly estimates two room impulse
responses from two mics when the source is unknown. Ours is known, so the blind step is
unnecessary: estimating the Mac-to-mic impulse response is ordinary supervised system
identification, which WebRTC's filter bank does adaptively and the Roth weight does in
closed form (Knapp and Carter, above). Each speaker is one peak in that response.

## 6. Two speakers, one mic, same program

Both speakers are peaks in one impulse response, separable when their spacing exceeds
roughly one over the usable bandwidth (about 0.13 ms for 300 Hz to 8 kHz); a 20 ms jump
is 150 times that. Speakers within a fraction of a millisecond merge and no weighting
separates them; super-resolution methods for close echoes exist (IEEE Trans. Circuits
and Systems I, https://ieeexplore.ieee.org/document/4303294/) but need signal-to-noise
ratios this room lacks, for a case the product does not need. What the acoustics
cannot say is which speaker moved: the program is identical from both. That must come
from outside the signal: per-speaker level and colouration recorded at chirp
calibration, or the host's view of each Bluetooth link.

## 7. Industry practice

Sonos Trueplay plays a purpose-built periodic test tone for 45 s, deconvolves it, and
states "for the spectral correction, we don't use the phase information": tone, not
timing (https://tech-blog.sonos.com/posts/trueplay-spectral-correction/). Dirac Live
"plays a sweep in each speaker" and takes its timing fixes from that sweep
(https://support1.bluesound.com/hc/en-us/articles/26482099028119). WiSA fixes latency
at 5.2 ms and syncs speakers to ±2 µs in the radio protocol, no acoustic measurement
(https://www.wisatechnologies.com/home-theater-technology). Apple says HomePod
"listens for sound reflections" to learn placement, nothing on timing
(https://www.apple.com/homepod-2nd-generation/). Nothing primary found for Google.
Every vendor that measures timing injects a signal; the only shipped system using
program audio as the probe is echo cancellation (WebRTC, above).

## Ranked recommendation

1. **ProbeKit: partially whiten by the reference's own spectrum.** Divide the
   cross-spectrum by the reference power spectrum raised to a power (start 0.5,
   sweep 0.3 to 0.8), regularised by a floor at a few percent of its mean, and keep the
   300 Hz to 8 kHz band. The reference is known exactly, so this whitening has no
   estimation noise, unlike the two-mic literature. Trade-off: bands where the music is
   quiet get more vote, so noise rises; the exponent sets how much. Expected gain: the
   background stops being music structure and becomes noise, so the score should scale
   with the square root of window length again, which it currently does not (8 s equals
   4 s). Speech evidence puts the best exponent near 0.4 (Donohue et al.); measure on
   the 2026-09-13 captures.
2. **ProbeKit: score against the second-best distinct peak inside the ±120 ms window**
   alongside the existing ratio, and require both. The competitor for the decision is
   the next repeat of the music, and that is what this measures; the whole-tape median
   answers a different question.
3. **ProbeKit: sub-band agreement.** Split the band into 4 to 6 slices, whiten each,
   and accept a lag only where the per-band peaks agree within 1 ms (Cobos et al.).
   Costs a few more FFTs per window. Literature gain: tens of percentage points fewer
   wrong lobes.
4. **Mac: pick windows, do not lengthen them.** From the retained buffer choose the 4 s
   with the best suitability score in each 3-minute period, and average the whitened
   correlations of two or three consecutive windows when their peaks agree. A jump
   shows as a split peak in the average, which is also the detection.
5. **Mac: name the moved speaker from outside the signal.** Keep each speaker's arrival
   level from chirp calibration, and log any per-link Bluetooth event the host sees,
   so a split peak can be attributed. Without this a jump is detected but not assigned.
6. **Mac: ambient-noise slice, last.** Record it when the outgoing program is under
   the existing −50 dBFS silence threshold. It sharpens fine accuracy and lowers
   nothing that failed live. Do it after 1 to 3 have moved the score.

## Do not

- Do not go to full phase-only correlation. At 50 dBA the noise bands get equal vote;
  Cobos et al. say phase-only is optimal only at high signal-to-noise ratio.
- Do not lower the threshold to 2.5. False peaks reached 1.9; the margin is the
  estimator's, not the threshold's.
- Do not lengthen windows or add an ambient slice first. Both pay off only after
  whitening removes the music's self-correlation from the background.
- Do not adopt Benesty's blind method (unknown source; ours is known), and do not try
  to split an in-sync pair (needs signal-to-noise ratio the room lacks, for a case the
  product does not need).
- Do not score against a window-local background alone; the code's own note is right.
- Do not inject anything per speaker. Product rule, and none of the above needs it.
