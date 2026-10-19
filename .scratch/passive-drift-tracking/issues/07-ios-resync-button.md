# 07 — iOS re-sync button: listen to the music, no chirps

Status: ready-for-agent
Blocked by: 02

One tap on the phone re-measures alignment from the playing music. Spans three
repos (Mac app, audiout-shared protocol, audiout-remote UI).

- Flow: button → phone records ~5–10 s via the existing `ProbeCaptureSession`
  path (built-in mic pinned, interruption/route-change invalidation kept) →
  phone streams the capture to the Mac → Mac correlates against the retained
  reference (tickets 01/02) → correction applies per ticket 05 rules.
- This inverts today's design: the phone currently re-renders sweeps locally and
  never ships audio. Music has no local re-render, so the capture crosses the
  network — new `CompanionCommand` + a capture-upload message in
  AudioutProtocol (audiout-shared, add to `docs/analytics-events.md` if any new
  event ships). A one-shot user-initiated recording sent to the user's own Mac;
  never stored beyond the correlation.
- Motion gate (decision 8): discard and re-prompt if the phone moved during the
  window ("hold still a moment"); re-baseline the phone's mic constant per
  placement — a moved phone changes path lengths (2.9 ms/m), so phone-measured
  deltas are relative to where it sat at calibration.
- Failure path (Alec's ruling): low confidence → present the manual by-ear
  paddles (existing wizard nudge UI), with the chirp probe offered as an option
  on that screen. Never dead-end into the full wizard.
- Instrument: `bt_sync:resync_tapped` and outcome enum, success-gated.

Done when: on staging builds, a tap during music playback round-trips a
correction with no audible interruption, and a capture during a quiet passage
lands on the paddles screen with the chirp option visible.
