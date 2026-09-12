# 05 — Apply corrections: gaps first, slew for residuals, thresholds

Status: ready-for-agent
Blocked by: 03

Turn attributed observations into delay-line changes without audible artifacts.

- Thresholds (decision 6, starting values): |delta| < 10 ms → ignore.
  10–40 ms → auto-correct silently. ≥ 40 ms → correct and surface a small
  notice. Tune later from ticket 06 data.
- Preferred moment: a playback gap — apply the full new delay while the program
  is silent (inaudible by definition). Detect gaps from the same program-level
  signal the keep-alive uses (ticket 04).
- No gap available: slew the per-device delay gradually (resampling / fractional
  delay), rate capped so the pitch shift stays inaudible (~0.2% ≈ 2 ms of
  correction per second of music — verify by ear on real hardware). Large deltas
  therefore wait for a gap unless echo is already obvious; ≥40 ms may prefer a
  single quick correction over a 30 s slew — decide by ear during live testing.
- Best-guess + verify (decision 7): after an ambiguous correction, the next
  window is a verify; if it disagrees, swap the assignment and re-correct.
- Corrections update the same per-device trim the wizard writes, so calibration
  and tracking share one source of truth; mark the stored calibration stale
  rather than silently rewriting it (staleness semantics from
  `bt-latency-stability-research-2026-09-05.md:204-225`).
- Instrument at the choke point once live: category `bt_sync`, counts/enums only
  (privacy fence).

Done when: fake-speaker test shows a mid-window delta applied at the next gap,
a residual slewn without discontinuity in the output samples, and the ≥40 ms
path surfacing its notice.
