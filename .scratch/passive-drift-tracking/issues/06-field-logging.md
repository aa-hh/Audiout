# 06 — Field logging: every sample recorded locally

Status: ready-for-agent
Blocked by: 03

Two jobs: settle the "is there real mid-playback creep?" question (bench says no,
Alec thinks he has heard it), and provide the data that tunes the 10/40 ms
thresholds.

- Log every sampling window locally via the decision log: per-speaker delay,
  confidence, usable/unusable, trigger reason (periodic / silence→audio /
  reconnect / mode change / clock-jump / verify / manual), action taken.
- Local only for the detail (device ids, raw deltas). Anything to PostHog goes
  through the privacy fence: counts, enums, bucketed magnitudes — no device
  names. Failures the user felt go through `Telemetry.fail`.
- A small readout (debug menu or log query) that plots per-speaker delay over a
  session, so a few real evenings answer the creep question directly: slope ≈ 0
  with occasional steps = jumps model confirmed; steady slope = creep is real
  and the tracker already corrects it as a series of small steps.

Done when: a session's windows can be pulled from the local log as a time series
per speaker, and nothing in the shared telemetry carries identifying detail.
