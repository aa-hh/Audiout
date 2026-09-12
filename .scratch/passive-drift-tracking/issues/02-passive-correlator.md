# 02 — Passive correlator: mic capture vs retained program audio

Status: ready-for-agent
Blocked by: 01

Extend ProbeKit (audiout-shared) to correlate a mic recording against an arbitrary
reference slice instead of a re-rendered sweep, and to extract multiple peaks.

- Reuse `SyncProbeCorrelator`'s FFT matched filter, parabolic sub-sample peak
  interpolation, and the median-floor peak-to-sidelobe confidence score. The
  change is the reference input (program audio slice + pts, not a rendered sweep)
  and multi-peak output (one arrival per speaker, plus the Mac/AirPlay lane when
  audible).
- Keep the SNR-aware noise weighting with plain matched filter as fallback, same
  as today (`MicProbeSession.swift:300-322` pattern). PHAT stays rejected.
- Music self-similarity (repeating beats) creates false peaks: constrain the lag
  search to a window around each speaker's baseline delay (from chirp
  calibration) ± the largest expected jump (~120 ms), and score windows on
  spectral flatness / bandwidth of the reference slice — reject slices that are
  too quiet, too narrowband, or too periodic to localize.
- Output per window: list of (delay, confidence) peaks + a usable/unusable
  verdict. Attribution to speakers is the caller's job (ticket 03), not the DSP's.
- Pure DSP, no app concepts — same ProbeKit boundary as the existing correlator.

Done when: unit tests with synthesized speaker mixtures (two delayed copies of
real-music fixtures + noise) recover both delays within ±1 ms at realistic SNR,
and quiet/periodic fixtures come back marked unusable rather than wrong.
Live-hardware validation is owed before anything acts on its numbers.
