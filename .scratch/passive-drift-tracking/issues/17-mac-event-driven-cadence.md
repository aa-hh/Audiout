# 17 — Listen on events, with one sparse periodic check (decision 18)

Status: planned
Blocked by: (none)

Replace the 3-minute periodic window with event-driven listening plus one
sparse check, so the microphone runs a few times a session instead of every
three minutes.

- `PassiveDriftTracker.periodicIntervalSeconds` (PassiveDriftSampler.swift,
  180 with its razor note) becomes 20–30 minutes; the first window after
  tracking turns on stays at +3 min (it is the one that establishes the sync
  point after a relaunch, and relaunches re-roll a link by ~10 ms: live test 4,
  block 8 vs 6).
- Event triggers already exist (`Trigger.periodic`, `.clockJump`, `.reconnect`,
  `.audioModeChange`, `.silenceToAudio`, `.verify`): make sure each fires where
  the spec says (reconnect: `NativeBackend` on a Bluetooth sink rebuild with
  cause reconnect; silence→audio: the keep-alive's `programIsSilent` edge;
  clock step: ticket 14's rate limit, one per speaker per 60 s, and a storm on
  one speaker classified as a bad link, not drift).
- A near-miss retry (ticket 12 part b) stays: a refused window whose best
  candidate cleared two of three gates retries once after ~30 s.
- The blind rule (5 unusable in a row) counts only event and periodic windows.
- Log the trigger on `drift_window_started` (already there) so field data can
  say which events actually catch jumps.

Done when: with both speakers selected and music playing, the local log shows
one window at +3 min, then none for 20 minutes without an event; a Bluetooth
reconnect (turn one speaker off and on) produces a window within 30 s of the
sink rebuild; a `bt_clock_jump` storm produces at most one window per minute
per speaker. Tests in PassiveDriftTrackerTests with an injected recorder.

## Comments

- 2026-09-14: written from Alec's ruling (decision 18) after live tests 2–4.
  Ticket 12's accumulator (part a) is less pressing under this cadence; its
  near-miss retry (part b) folds in here.
