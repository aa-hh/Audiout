# 05 — Apply corrections: gaps first, slew for residuals, thresholds

Status: claimed (decision core built + reviewed 2026-09-12; wiring + slew + analytics remain)
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

- Bluetooth only (decision 13): corrections are generated for Bluetooth device
  UIDs and nothing else. AirPlay/Cast run fixed scheduled delays against the
  room reference clock and are never adjusted; the integration layer must not
  feed their observations into the policy as correctable devices.

## Comments

- 2026-09-12: wave 1 review fix pass applied findings 1–3 — the swap/re-correct path
  now moves only group members still off by at least the ignore threshold.
- 2026-09-12 review pass 3, ruled immaterial for wave 1 but MUST fix before ticket 06
  logs action kinds: a stored guess group never empties (it always keeps its own
  device), so a lone stale-group re-correction is emitted as `.swapAndRecorrect([x])`
  instead of `.correct` — same move, wrong label; a field log counting swap events as
  wrong-attribution would miscount ordinary drift. Fix: drop the device from its own
  stored group too, or treat a `[self]` group as no group
  (`DriftCorrectionPolicy.swift:226` area).
