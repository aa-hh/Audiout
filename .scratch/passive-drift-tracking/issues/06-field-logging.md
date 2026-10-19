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

## Comments

- 2026-09-13: the PostHog side of a correction already exists. Do not add it
  again. `bt_sync:drift_corrected` is captured at
  `DriftCorrectionApplier.swift:151`, and its row is in audiout-shared
  `docs/analytics-events.md`. It is charted as "Drift corrections" on the
  "Audiout — Speaker alignment" dashboard
  (https://eu.posthog.com/project/258793/dashboard/949953). Two things for
  this ticket:
  - The shared row says the event fires "after the move lands, never before".
    That holds for an in-gap move. For a slew the capture runs when the slew
    starts, before the delay has finished moving. Make the code and the row
    agree: capture when the slew completes, or reword the row to "when the
    correction starts".
  - A correction count alone can't give "how often the tracker catches a
    speaker out of sync", because nothing sends the number of sampling windows
    it was out of. Deciding whether a bucketed per-session window count (usable
    / unusable) goes to PostHog is Alec's call. Ask before adding an event.
