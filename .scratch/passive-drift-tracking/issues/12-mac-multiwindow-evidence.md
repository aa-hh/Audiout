# 12 — Sum the last three windows, and retry a near miss after 30 s

Status: shelved (Alec, 2026-09-14) — ProbeKit half built and tagged 0.16.0 but NOT adopted; see the 2026-09-14 review comment
Blocked by: 09, 10

One 4 s window is often too weak to pass on ordinary music: add evidence across windows, and stop waiting 3 minutes after a near miss.

- **Accumulator (ProbeKit, pure).** A small value type holding, per baseline, the whitened correlation slice from the last N windows (propose N = 3) and their summed values, indexed by absolute delay from the shared zero, so slices from different windows add directly. No app concepts: it takes `(deviceUID, slice: [Float], firstLagMs, lagStepMs, ownBestLagMs)` and returns the sum's best lag plus how many windows agree with it.
- **Vote cross-check** (brief §2): report the sum's peak only when at least two contributing windows' own best lags sit within 1.5 ms of it. Two peaks in the sum means the speaker moved between windows.
- **Memory.** ±120 ms at 48 kHz is 11,520 floats, 46 KB per slice; two speakers × 3 windows ≈ 280 KB. The reference ring is untouched: its 15 s capacity (`ReferenceAudioRing.swift:50`) already covers a 4 s window plus tail.
- **Emptying.** Any baseline change clears every slice: `setBaselines` (`PassiveDriftSampler.swift:112`), the merged rule (`:275`), a re-baseline, a landed correction.
- **Near-miss retry.** When a window is refused but its best candidate (`lastCandidates`, `PassiveDriftSampler.swift:124`) scores within 20 % of the gate (`minPeakToSidelobe` 2.3 at `PassiveDriftSampler.swift:104`, so 1.84 and up), take the next window 30 s later instead of the 180 s cadence (`periodicIntervalSeconds`, `PassiveDriftSampler.swift:334`). Cap at 3 consecutive retries, then back to 180 s: at most 4 windows in 2 minutes, so a bad room never runs `BuiltInMicRecorder` (`MicProbeSession.swift`) continuously.
- **Blind counter.** Retry windows do not increment `consecutiveUnusableWindows` (`PassiveDriftSampler.swift:156`); only the window that opened the burst counts. Otherwise three fast retries spend most of the 5-window budget (`blindAfterUnusableWindows`, `:79`) in 90 s and turn tracking off.
- **Reaction time.** A jump at t is seen today at the first window that passes: t + 3 min at best, t + 9 min when two windows are marginal. With retries and the sum, three windows land inside 90 s: t + 30 s to t + 3.5 min. With no near miss the cadence is unchanged and the sum adds 3 to 6 min (brief §2).

Done when: the ticket-16 fixtures replayed in sequence put the accumulated answer for windows 1 + 3 + 4 within 2 ms of the labelled sync point while any single window may fail, and the 30 s retry path is unit-tested with an injected recorder as `PassiveDriftTrackerTests` does (`AudioutCore/Tests/AudioutCoreTests/PassiveDriftSamplerTests.swift:176`).

## Comments

- 2026-09-13: drafted from live tests 2–3 (HANDOFF.md) and dev/notes/drift-ensemble-design-brief.md §2.
- 2026-09-14: the ProbeKit half is built and tagged `0.16.0` in audiout-shared — `DriftSlice`, a third `slices` element on `analyzeWithCandidates`, and `PassiveDriftAccumulator` (3 windows, 1.5 ms vote tolerance, 2 agreeing windows, and the newest window must be one of them so a verify window cannot confirm the guess it was taken to check). `PassiveDriftFixtureTests` replays the three 2026-09-13 `good` windows through one accumulator, keyed by baseline index, and prints what the summed evidence reaches:

  ```
  EVIDENCE key=0 none
  EVIDENCE key=1 none
  ```

  Summing those three windows reaches no answer either speaker's own windows support.

- 2026-09-14, adversarial review — **SHELVED. Do not pin the Mac to 0.16.0.**
  The explanation in the comment above is wrong, and the review's numbers say so:
  windows 21:07 and 21:13 share baselines (537/529), so no correction landed
  between them, yet their own best lags differ by 7 ms (567.05 vs 574.33; the
  third reads 570.64). The summed peak is 561.01 ms for BOTH keys — a lag none
  of the three windows chose, one bass-comb tooth below the ~570 ms arrival that
  recurs across them. Summing three real windows moved the answer onto a
  different tooth instead of sharpening the true one, so this ticket's
  "Done when" is NOT met.

  The blocking defect: `PassiveDriftAccumulator.consensus` has **no confidence
  gate**. A single window must clear margin ≥ 1.2, local ≥ 2.4 and 2 of 4 bands;
  the summed answer clears nothing. `Arrival` carries `peakMargin`,
  `localScore` and `peakToSidelobe` and all three are discarded, so the Mac
  cannot gate it either. On the fixture the sum's margin is 1.024 and only the
  vote stopped it. On bass-comb material two windows whose own argmax lands on
  the same wrong tooth sum to a peak on that tooth, the vote passes, and the app
  moves a speaker ~10 ms.

  Two more, both needed before any Mac adoption:
  - The newest-window clause does not close the self-verification hazard on
    periodic material: a correction shifts the whole comb, so a tooth still sits
    at the old lag and the newest window can argmax there again.
  - Every key's slices are cut from the same `full` correlation, so with
    baselines 8 ms apart the two keys carry near-identical evidence. Two
    speakers in sync can never reach consensus for the second key — its votes
    are always for the runner-up.
  - Mechanical: the Mac's `let (outcome, candidates) = analyzeWithCandidates(`
    will not compile against the 3-tuple. Adoption means fixing that too.

  To un-shelve: carry the sum's own margin / local score / peak-to-sidelobe out
  of `consensus` and gate on them, then re-run the fixture replay and require it
  to land within 2 ms of the labelled sync point. That is a 0.16.1 or 0.17.0
  release; 0.16.0 is pushed and cannot be amended. The Mac stays on 0.15.1.
