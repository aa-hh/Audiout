# 11 — ProbeKit: sub-band agreement as the accept rule

Status: planned
Blocked by: 09, 10, 16

Run the whitened correlation in four sub-bands and accept a lag only when enough bands land on it, so the music's own repeats stop being read as arrivals.

- **Bands (voters).** Four geometric bands over the existing timing band, as `dev/drift-window-analysis.py:112` already computes: 300–697, 697–1620, 1620–3766, 3766–8000 Hz. Mask the one cross-spectrum per band and inverse-transform it; no re-filtering of the time signals.
- **Below 300 Hz is not a voter.** Live test 3: the mic hears 100–300 Hz best (correlation 0.5–0.67) but that band repeats every ~10 ms, giving the comb at 558/569/579/588 ms. Optional, off by default: a 60–300 Hz correlation whose peaks are handed out as candidate teeth for the upper bands to pick from.
- **Combine by location.** Take each band's best lag inside the speaker's search window. Agreeing bands are those within 1.5 ms of ticket 09's whitened full-band lag; report the agreed lag as their median and the spread of the agreeing set as the confidence. Accept at 3 of 4.
- **Composition with ticket 10.** Agreement supplements, it does not replace: a window is accepted only when the second-peak margin passes AND 3 of 4 bands agree. Both counts are reported on every window whatever the verdict. `minPeakToSidelobe` (`PassiveDriftCorrelator.swift:117`, overridden to 2.3 at `PassiveDriftSampler.swift:104`) is retired once both land.
- **Composition with the merged-peak rule.** Whitening narrows the lobe, so `peakSeparationSeconds` (`PassiveDriftCorrelator.swift:153`) drops to ~1 ms and two speakers a few ms apart resolve as two peaks rather than one. A peak that is still sole claimant for two baselines (`PassiveDriftSampler.swift:275`, decision 14) must also pass band agreement before it is taken as the sync point; that refuses the false merge at 574.3 seen in live test 3.
- **No onset-envelope estimator.** Nothing in the four dumped windows measures one, and the comb it must disambiguate has 10 ms teeth against its ~2 ms resolution. Revisit only if the fixtures show band agreement alone failing.
- **Cost.** Two forward transforms shared with ticket 09, plus one inverse per band: 4 more 2^19 transforms per window, tens of milliseconds of one core every 3 minutes. Fits the existing serial drift queue; never the render or mic thread.

Done when: on the ticket-16 fixtures, every loop-based window is refused rather than given a lag; on known-good windows the band-agreed lag is within 1 ms of ticket 09's whitened full-band answer; the exact forced +40 ms trim jump reads within 2 ms in the first accepted window after it.

## Comments

- 2026-09-13: drafted from live test 3 (HANDOFF.md) and dev/notes/drift-ensemble-design-brief.md
