# 12 — Sum the last three windows, and retry a near miss after 30 s

Status: planned
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
