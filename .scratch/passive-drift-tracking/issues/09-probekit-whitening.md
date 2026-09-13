# 09 — Whiten the cross-spectrum by the reference's own spectrum

Status: planned
Blocked by: 16

Give the drift correlator a configurable whitening exponent so the music's own harmonic
structure stops dominating the correlation background, and pick the exponent on fixtures.

- **Where it goes.** The cross-spectrum is formed in the shared static function
  `SyncProbeCorrelator.correlate` (`~/Projects/audiout-shared/Sources/ProbeKit/SyncProbeCorrelator.swift:345`).
  Add a `whiteningExponent` parameter: divide each bin by the reference's own magnitude
  spectrum raised to that power. 0 reproduces today's plain matched filter, 1 is the full
  phase transform (PHAT, phase transform). Regularise with a floor at a few percent of the
  mean reference power so near-empty bins cannot blow up, the same shape as the existing
  `noiseWeights` epsilon (`SyncProbeCorrelator.swift:395`). Band limiting to
  `timingBandLowHz`/`timingBandHighHz` (`PassiveDriftCorrelator.swift:145`) still applies.
- **The two paths share code without changing the wizard.** Default the new parameter to 0,
  so every existing caller (the chirp probe path through `ProbeAnalyzer`, used by the
  wizard) is unchanged. Only `PassiveDriftCorrelator`'s two call sites
  (`:241`, `:249`) pass a non-zero value. If the sweep shows the chirp path also gains,
  that is a separate ruling, not this ticket.
- **Pick the exponent on the ticket 16 fixtures**, sweeping 0.3 to 1.0. Live evidence
  favours the top: window 4 scored 1.85 plain and 4.52 at exponent 1.0. The literature
  brief favours about 0.4 to 0.5 for speech. Record the sweep here and set the default from it.
- **Peak separation must move with it.** `peakSeparationSeconds` is 0.005 at
  `PassiveDriftCorrelator.swift:153` (it lives there, not in `SyncProbeCorrelator` as the
  brief implies). A whitened lobe is 0.1 to 0.3 ms wide, so two speakers 2 ms apart split
  into two peaks and the merged-peak rule of decision 14
  (`AudioutCore/Sources/AudioutCore/PassiveDriftSampler.swift:275`, `mergedArrival`) stops
  firing, because it needs one peak alone in two speakers' windows. Drop the constant to
  about 1 ms and prove on a fixture with two arrivals 2 ms apart that either the merged
  rule still fires or both peaks land inside the leave-alone band under 10 ms, so an
  in-sync pair is never corrected apart.
- **Version.** Ship as audiout-shared 0.14.0 and bump the pin at
  `AudioutCore/Package.swift:178` (0.13.0 today).
- Update the doc comments that currently reject whitening outright
  (`SyncProbeCorrelator.swift:140-147`, `PassiveDriftCorrelator.swift:70-73`) to say the
  drift path whitens partially and why the chirp path does not.

Done when: at the chosen exponent, on ticket 16's labelled fixtures, at least 90 % of
known-good windows at normal level yield an accepted arrival within 1 ms of the labelled
answer, 0 of the garbage windows are accepted, and the four 2026-09-13 windows' answers
cluster within 2 ms across windows 1, 3 and 4.

## Comments

- 2026-09-13: drafted from live test 3 (HANDOFF.md), spec decision 16,
  `dev/notes/drift-tde-algorithms-brief.md` and `dev/notes/drift-ensemble-design-brief.md`.
