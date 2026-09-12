# 03 — Mac-mic sampling loop + attribution from baseline

Status: ready-for-agent
Blocked by: 02

The tracking loop on the Mac: capture short windows, run the passive correlator,
attribute peaks to speakers, decide whether alignment moved.

- Capture via the existing `BuiltInMicRecorder` path (pinned to built-in device,
  never default input — HFP trap). Requires the mic permission already granted
  for the wizard; if not granted, tracking is simply off.
- Window length: a few seconds (Alec: "even 10 seconds is more than necessary").
  Cadence: every 2–5 min while music plays, plus triggers: silence→audio
  (when keep-alive is off or timed out, ticket 04), Bluetooth reconnect, OS
  audio-mode change, and a `BTClockStability` jump report.
- Attribution: match each returned peak to the nearest baseline delay. One peak
  moved → that speaker jumped. Several moved → best guess (likeliest assignment),
  schedule a verify window, swap the assignment if the verify disagrees
  (decision 7).
- Mic-moved guard: all peaks shifted by a similar amount → re-baseline the mic
  constant, do not correct (decision 8; the Mac has no motion sensor, this
  heuristic is the only guard here).
- Blind mic (decision 9): N consecutive unusable windows (start N=5) → stop
  sampling, expose a status the UI renders as a small note ("can't hear the
  speakers"); any successful re-sync or new calibration re-arms it.
- Emits observations only (per-speaker delta + confidence). Acting on them is
  ticket 05; logging is ticket 06.

Done when: with the fake-speaker dev tooling, an injected delay change on one
sink produces an attributed observation within one sampling cycle, and unusable
windows count toward the quiet-disable without ever emitting a delta.
