# 06 — Suspected bug: "This Mac" plays on the built-in speakers when the default output is not built-in

Status: needs-triage
Type: task

Independent of the feature, and possibly the real complaint behind it.

## Evidence (source reading, NOT yet reproduced live)

- Whole-system routing points the default output at the public aggregate
  (`NativeBackend+AggregateOutput.swift`, `pointDefaultAtAggregate`).
- That aggregate wraps ONLY the built-in output
  (`AggregateOutputDevice.swift`, `createAggregate(... subDeviceUID:
  builtInOutputDeviceUID())`).
- `SyncedLocalSink` renders through the system default (no `setDeviceID` pin),
  i.e. through the aggregate, i.e. the built-in speakers.
- So with any other wired output as the user's default — a USB DAC, external
  headphones in the jack, a monitor's speakers — selecting an AirPlay speaker
  + "This Mac" should move the Mac's copy to the laptop speakers, and
  `priorDefaultUID` only restores the real device when routing ends.
  Reproducible with headphones alone; no DAC needed.

## Verify first (ticket 01, question 5), then decide

Options if confirmed: (a) wrap the PRIOR default's UID in the aggregate instead
of the built-in when that device is a safe wired transport (loop-risk check
stays); (b) pin the synced local sink to the prior default's device id rather
than the system default. (a) also fixes plain passthrough-through-aggregate
edge cases; (b) is smaller. Either must survive that device being unplugged
mid-session (fall back to built-in, as `LocalPlaybackEngine` already does).
