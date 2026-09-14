# 14 — Pacing-clock steps: log the creep, rate-limit the triggers, calibrate against the mic

Status: planned
Blocked by: 09, 10

Turn a Bluetooth pacing-clock step from a bare trigger into a measured prior: make
sub-2 ms creep visible, stop a bad link from blinding the tracker, and find out
whether a step means the sound actually moved.

- **Log the cumulative deviation.** Only steps over 2 ms are visible today
  (`AudioutCore/Sources/AudioutCore/BTClockStability.swift:49`, logged at
  `AudioutCore/Sources/AudioutCore/OwnToneBackend.swift:1017`); the running
  deviation the detector already computes
  (`BTClockStability.swift:108`) is never reported, so slow creep stays
  invisible: one candidate for the 11 ms desync nothing caught in live test 2.
  Expose it and write one line per sink about every 30 s: uid, cumulative ms
  since baseline, count of steps over the threshold since the last line. Local
  `Telemetry.log(.localPlayback, ...)` only, never PostHog.
- **Rate-limit the triggers.** Every step fires a window with no limit
  (`OwnToneBackend.swift:1019`, `NativeBackend.swift:11100`), so live test 2's
  storm blinds the tracker in about 25 s. At most one step-triggered window per
  speaker per 60 s. Past a rolling 60 s count (start at 10) treat that speaker
  as a bad link, log it once, and stop triggering off its steps until it runs a
  minute clean. Suppressed steps still count in the deviation line.
- **Calibration study.** Pair each accepted acoustic delay change for a uid
  (windows from 09/10, no correction in between) with the summed signed steps
  since that uid's previous accepted window, and fit
  `delta = g * sum + c` over about 20 pairs. Lives as `dev/drift-clock-step-fit.py`
  over `~/Library/Logs/Audiout/telemetry.jsonl`, beside `dev/drift-window-analysis.py`.
  Prints pair count, g, c, residual spread, and whether g reads near plus or
  minus 1 (playout moved), near 0 (bookkeeping only) or unresolved. Needs
  `hostNanos` in `drift_window_result` for the join.
- **Use it, in that order.** Once g's sign holds, narrow that speaker's next
  search from plus or minus 120 ms (`PassiveDriftSampler.swift:83`) to plus or
  minus 40 ms centred on baseline + g * sum while a step is pending. Correcting
  straight from the step size, inside the 10 to 40 ms band and only when the
  next window agrees, is a later option and needs Alec's ruling first.

Done when: unit tests over an injected sequence of `BTClockStability.Outcome`
values show one triggered window per speaker per 60 s and a 15-step burst
classified as a bad link with triggering stopped; a running app writes a
per-sink deviation line every ~30 s into telemetry.jsonl; and the fit script
prints its pair count and slope over a real log.

## Comments

- 2026-09-13: drafted from live test 2 (`HANDOFF.md`), spec decision 2,
  `dev/notes/drift-ensemble-design-brief.md` §3.
