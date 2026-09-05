# Per-device delay trim — spec

2026-08-22 · shaped and decided with the owner · grounded against main @ 469282ab

## Goal

Every device that can sit off the group's timeline has one obvious, signed,
per-device millisecond trim on its own row, and aligning it by ear is easy
enough that a first-time user succeeds on the first try. This was the #1
parity candidate in the competitor research (003): rivals either don't ship
per-output trim (Sonos group delay is global, Apple ships nothing) or bury
it (Airfoil's advanced sliders).

## Decisions (locked 2026-08-22)

1. **AirPlay rows get NO trim.** All AirPlay 2 outputs ride one PTP-synced
   write timeline (`AirPlayEngine.write(pcm:pts:)` fans a single pts to every
   bound output — there is no per-device delay hook), so AirPlay↔AirPlay is
   aligned by protocol. Cross-protocol alignment is already covered: BT sinks
   schedule against the AirPlay presentation timeline (trim adjusts that),
   and the Mac's local sink has its own offset. Revisit trigger: real user
   reports of AirPlay↔AirPlay misalignment from receiver-side DSP latency —
   that would need per-device pts shifting and is deliberately not built now.
2. **The Mac's own output becomes a trimmable device row.** Its offset today
   is the global `AppSettings.syncOffsetMs` buried in Settings → Audio →
   Advanced. It moves onto the Mac's device row as the same SYNC control BT
   rows use. Storage stays `AppSettings.syncOffsetMs` (one local device — a
   migration buys nothing); the Settings Advanced row is REMOVED once the row
   ships so the value has one home. Coordinate with roadmap 050 (in
   progress), which just rebuilt that Settings row and its live hint — the
   help copy moves to the SYNC affordance's tooltip.
3. **The alignment wizard is redesigned in this same track** — method of
   constant stimuli replaces the forced-choice bisection (below).

## Current state (verified against code 2026-08-22)

- **BT**: per-device `trimMs` lives end to end — `BTSyncedSink` applies it,
  `BTTrimStore` persists whole ms per device UID (`bt-sync-trims.json`,
  ±`BTSyncTrim.rangeMs` = 500, `resolutionMs` = 1), re-pushed on every sink
  arm. Popover SYNC column stepper + `BTSyncDrawerView` + alignment wizard
  (`BTAlignmentBisection` / `BTAlignmentWizardSession`) all ship on main.
- **Mac**: `AppSettings.syncOffsetMs` (clamped ±500), added as a static user
  bias inside `SyncTiming.totalDelayNanos` via `SyncedLocalSink`. Global,
  Settings-only, not on the device row.
- **AirPlay**: nothing, by design (Decision 1).
- **Drift**: settled acoustically 2026-08-12 — A2DP sinks servo to the host
  delivery rate; measured inter-speaker drift −0.02 ppm (~0 over 30 min). A
  fixed trim holds for a whole session. `BTDriftCorrector` servos on the
  host-side pacing clock, i.e. compares that clock to itself — it is inert.

## Part 1 — one SYNC surface for every trimmable device

- Mac row gains the SYNC stepper, bound to `syncOffsetMs`. Identical
  affordance to BT rows: ±500 ms, 1 ms resolution, same coarse/fine stepper
  behavior, same drawer and metronome align aid (the tick works for
  Mac-vs-AirPlay exactly as for BT-vs-AirPlay).
- Trim semantics stay signed-nudge-on-top-of-computed-delay everywhere;
  positive/negative direction must read the same on both device kinds.
- Settings → Audio → Advanced loses its sync-offset row (Decision 2).
- Value readout stays bare numeric ms (no presets — per the owner's standing
  localization/numeric preference).

## Part 2 — wizard: method of constant stimuli

Why replace the bisection: it is unforgiving. Two-reversal convergence means
one mistaken judgment freezes the ticks and converges early; there is no
undo; "can't tell" is a dead end instead of data.

New method (the owner's design, 2026-08-12):

- Each trial adds a KNOWN deliberate offset δ on top of the current
  estimate, drawn from a fixed stimulus set (e.g. {−24, −16, −8, −4, 0, +4,
  +8, +16, +24} ms), presented in randomized order; the app subtracts δ back
  out of the answer. Every judgment stays an easy "which side leads?"
  question because the app controls how far off each trial is.
- Answers are left / right / can't tell. "Can't tell" near the crossover is
  expected, averageable data — not a failure state.
- The estimate is the crossover of the resulting psychometric curve (sign
  flips + can't-tell centroid). 2–3 repetitions per level, ~20–30 fast
  trials. A single wrong answer nudges the fit instead of derailing it; a
  Back button just re-queues the trial.
- Perceptual constraints to honor (probe-validated live on the owner):
  lateralization reads clearly at 7–15 ms even on a broken baseline; below
  ~4 ms two clicks fuse and the offset is heard as image POSITION
  (resolution 0.1–0.5 ms). Stimulus spacing reflects that: coarse wings,
  dense center.
- **Tick source**: the wizard drives its own synthesized tick (the existing
  woodblock, 1.8+2.9 kHz partials, injected into the capture fan-out at
  NativeCaptureCoordinator post-convert), ~72 BPM (never 120 — 500 ms beats
  alias with the ±500 range), so it works with music paused. This absorbs
  roadmap 040.
- Applies to the Mac row's trim identically.
- Carry-overs that stay as built: 30 s auto-stop, Sonos amp-park mitigation (~−47 dBFS
  keep-alive bed + ~3 s wake preamble), and the hard rule to never schedule
  audio at absolute times against a BT device clock (continuous loop +
  in-place rewrite only). The first-mix intercept card is GONE — see the
  2026-09-03 amendment under "ALIGNMENT WIZARD UX LOCKED" in
  `docs/plans/PLAN-UNIVERSAL-SYNC.md`.

## Part 3 — making a saved trim trustworthy (prerequisites)

A trim is only worth aligning if it still means something tomorrow. Two
known holes, one measurement:

- **(a) Lineup changes re-anchor playing sinks.** Adding/removing a speaker
  fires `bt_sink_rebuild cause=config_change` on the sinks already playing
  and re-anchors their timing, so a saved alignment shifts on every lineup
  change (observed live 2026-08-12). Requirement: alignment survives
  add/remove — carry each surviving sink's anchor across the rebuild instead
  of re-deriving it. Acceptance: align two speakers, add a third mid-play,
  hear no shift in the first two.
- **(b) Reconnect survival is an open unknown — measure before designing.**
  Extend the spike's drift-meter with the band-split-chirp addition (~1 h)
  to measure absolute offset across disconnect/reconnect cycles. If the
  offset is stable (within a few ms), stored trims persist silently and
  nothing more ships. If not, an aligned device that reconnects gets a
  re-align prompt (wizard entry point) — never silently plays misaligned.
- **(c) Delete `BTDriftCorrector`.** Inert (Part 0 above); it reads as a
  safety net but corrects nothing. Removing it simplifies BTSyncedSink and
  kills a false signal for future readers.

## Out of scope

- AirPlay per-device trim (Decision 1; revisit trigger recorded there).
- ~~Mic-based auto-offset — CUT by the owner 2026-08-07 (mic position
  uncontrollable; different-rooms is the good case). Do not revive.~~
  **REVERSED by the owner 2026-08-27** on the strength of the "Beyond the Tick"
  research brief: mic position only contributes distance asymmetry
  (~2.9 ms/m), well inside the ±6 ms blend bar unless the Mac sits far
  off-centre — a UX-copy problem, not a blocker. The mic measurement feeds
  the wizard's existing `openingProposalMs` seam (by-ear confirm stays the
  gate; wizard remains the mic-denied fallback). See
  `mic-probe-calibration-brief.md`.
- Continuous drift correction — measured unnecessary (drift ≈ 0).
- Per-brand seed table — no data source exists.

## Verification

- Unit: stimulus schedule properties (randomized order, δ always subtracted
  back, estimator converges under a simulated observer with ~10% lapse
  rate); anchor-continuity across a simulated config_change rebuild.
- Live by-ear checklist (this is also the still-owed BT live test): wizard
  align on both BT brands; lineup add/remove with no audible shift;
  disconnect/reconnect; sleep/wake; Mac-row trim against an AirPlay
  reference.

## Roadmap wiring

- New entry for this spec (this doc is its `doc`).
- Absorbs 040 (wizard tick source — close it against this entry when built).
- Related, not blocked: 038 (BT rows have no meter), 041 (bt-fix-rtlocks
  branch), 019 (HFP oscillation), 050 (Settings row removal coordination).
