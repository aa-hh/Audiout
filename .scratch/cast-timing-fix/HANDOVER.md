# Cast timing fix: handover, 2026-10-07 00:20 local

Branch: `claude/cast-timing-fix-wip` (this commit), built on PR #283's head `db50e957`
(`claude/cast-timing-fix`). #283 itself was NOT updated: pushing there needs the owner's go,
and #283's two review rounds are used, so its next head needs the owner's `review` status or the bypass.
Worktree: `.claude/worktrees/cast-timing-fix-r2`.

## In this commit (all reviewed, 149 Cast tests green)

1. **Windowed-sinc resampler for the Cast feed** (`CastSincResampler`, `CastOutputManager.swift`).
   Replaces the 4-tap cubic speed matching read through, which dipped the treble up to 4.6 dB
   depending on phase (heard as dull highs + pumping; confirmed by a live A/B on 2026-10-06).
   32 taps, Kaiser beta 8, 256 phases, reads the ring in place. Work order: `evidence/sinc-workorder.md`.
2. **One clock for every Cast timestamp** (raw mach nanoseconds). Before, capture `pts`
   (mach + an offset frozen at tap start) was subtracted from `CLOCK_MONOTONIC`, which macOS's
   `timed` slews 12 to 30 ppm and steps every 17 to 29 minutes. That phantom fed speed matching
   and moved the TV for real (up to ~48 ms). Synthetic producers (wizard pacer, leveled fallback,
   gap fill) read both clocks fresh per block. New telemetry: `ioproc_to_push_max_ms`, `ring_wait_max_ms`.
   Work order + review fix list: `evidence/clock-workorder.md`. Root-cause report: `evidence/load-discovery-report.md`.
   **Live PASS 2026-10-06 23:50 local:** `timed` corrections of −9.5 s and −4.7 s moved nothing
   (`ioproc_to_push_ms` 13.4 → 13.5, no step in `age_ms`, speed match 0 to +10 ppm, error 0 ms).

## OPEN: TV highs/volume dip irregularly and often (start here tomorrow)

- Heard on the TV with the dev build, TV alone too. The shipping `/Applications` copy does NOT do it.
- Ruled out: speaker interference (happens on the TV alone); TV auto-volume / enhancement / night
  mode (all off); speed matching / resampler (an A/B build with `speedMatchGainPpmPerMs = 0` still dips);
  clipping in our path (Cast stream peaks −17.8 dBFS max, about 18 dB of headroom); underruns, dropped
  blocks, feed-gate changes, delay changes (none in telemetry).
- Owner's hunch: bass-heavy passages trigger an overall dip.
- Agreed next step: a diagnostic switch in the dev build that records exactly what the Cast feed
  sends (same code path) to a WAV on the Mac. Listen on headphones. Dips in the recording = our
  code (bisect this branch's feed changes: feed gate fade, 80 ms standing queue, delay line,
  crossfaded grows). Clean recording = the TV reacting to something about the stream; compare
  with what the shipping app sends.

## Smaller follow-ups found tonight

- Cast `age_ms` creeps ~1 to 2 ms/min for a whole session (Mac-side queue grows as the TV's buffer shrinks); TV stays in sync.
- `cast_volume_lag` flips 5 ↔ 6 every second (rounding at ~5.5 s lead): UI-only churn.
- AirPlay engine: the sync packet's "play at" time is on the pts clock, but receivers learn the Mac's
  time from live `CLOCK_MONOTONIC` (vendored C timing + PTP responders), so a `timed` step shifts it.
  Not verified audible. See the "Other paths" section of `evidence/clock-workorder.md`.
- Optional: Cast server queue priority to `.userInteractive` (report fix 3).

## Live-test notes

- Build the dev id from THIS worktree, holding the slot acquired from this worktree, or make-app refuses
  and `open` relaunches the OLD binary. Check the binary's mtime before relaunching.
- Other sessions take the dev slot often; the A/B copy (speed matching off) is what is in `build/` now.
- Owner's by-ear TV trim tonight: about −80 to −105 ms.
- Checks: `evidence/clock-check.sh <since-UTC>`, `evidence/castdrift.py <telemetry> <since>`.
