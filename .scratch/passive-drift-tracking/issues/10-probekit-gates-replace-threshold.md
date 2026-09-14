# 10 — Two gates in place of the single acceptance threshold

Status: resolved (audiout-shared claude/drift-gates 6990309, in 0.15.0; Mac override removed ca746f81)
Blocked by: 09, 16

One number measured over the whole tape cannot separate a real arrival from the music's next repeat. Measure the two things that can: the competition inside the search window, and the background right around the peak.

- **Why today's number misses.** `SyncProbeCorrelator.arrival(inCorrelation:searchCount:lags:)` (`~/Projects/audiout-shared/Sources/ProbeKit/SyncProbeCorrelator.swift:250`) takes the median of `|correlation|` over every lag outside the peak's 5 ms exclusion and 250 ms reverb shadow, scales it by `sqrt(2 ln N)`, and refuses anything under `minPeakToSidelobe` (`:263-275`). That background is dominated by lags nowhere near the peak, so it never measures the real competitor: the same music one repeat period later, tens of milliseconds away.
- **Gate (a), peak over second-best peak, inside the ±120 ms window.** Second best is the highest lag in the same window more than 3 ms from the best (`dev/drift-window-analysis.py:88-93`). Start the accept at 1.5 and fit it on the ticket 16 fixtures (`dev/notes/drift-ensemble-design-brief.md:59`). The brief's prose says 5 ms at `:45`; the harness uses 3 ms and the harness is what parity is measured against.
- **Gate (b), local background score.** Same median-times-`sqrt(2 ln N)` formula, but over a ±300 ms window around the peak with the peak excluded (`dev/drift-window-analysis.py:73-84`). Report it beside the whole-tape score; do not drop the whole-tape one.
- **Carry both numbers on `DriftPeak`** (`~/Projects/audiout-shared/Sources/ProbeKit/PassiveDriftCorrelator.swift:22`) so `analyzeWithCandidates` (`:195`) reports them for refused windows too. Its candidate pass already re-runs with the threshold at zero (`:257-262`).
- **Local log line.** `candidates` in `PassiveDriftSampler.logWindow` prints `delay@score` (`AudioutCore/Sources/AudioutCore/PassiveDriftSampler.swift:543`); add the margin and the local score so a refused window says which gate stopped it. Local log only, device ids allowed.
- **Then the threshold goes back.** `PassiveDriftSampler.minPeakToSidelobe = 2.3` (`:104`, applied at `:107`) returns to the correlator's default 3 (`PassiveDriftCorrelator.swift:117`), or the constant and the line setting it are deleted once the gates carry the decision. That is the ruling spec decision 15 owes.
- **Parity:** the Swift values for both numbers must land within 5 % of the harness's `local` and `p2p` columns (`dev/drift-window-analysis.py:113-120`) on the ticket 16 fixtures.

Done when: over the labelled fixtures, zero garbage and noise windows pass the gates; the 21:13:33 window (574.3 ms, whole-tape score 2.40, 4 % above its neighbour, local score 1.6) is refused; and at least 90 % of known-good windows are still accepted with ticket 09's whitening in place.

## Comments

- 2026-09-13: drafted from live tests 2–3 (HANDOFF.md), spec decision 15, dev/notes/drift-ensemble-design-brief.md.
