# 15 — Mac: record a room-sound slice during program silence and pass it to the correlator

Status: planned
Blocked by: 16

The Mac has never passed `ambientNoise` to the correlator, so ProbeKit's noise weighting has never run in the field.

- Already there: `PassiveDriftCorrelator.analyze(... ambientNoise:)` defaults to nil
  (`~/Projects/audiout-shared/Sources/ProbeKit/PassiveDriftCorrelator.swift:176`); given a slice it
  divides the correlation bins by the measured noise power spectrum and falls back to the plain matched
  filter when the weighted pass finds no peak (same file, 236-254; weighting described at
  `SyncProbeCorrelator.swift:137-150`). `PassiveDriftSampler.analyze` already forwards the parameter
  (`AudioutCore/Sources/AudioutCore/PassiveDriftSampler.swift:137-151`). Only the caller is missing:
  `finishWindow` never supplies one (`PassiveDriftSampler.swift:453`).
- Capture about 1 s from the same built-in mic (`makeRecorder`, `PassiveDriftSampler.swift:340`;
  `BuiltInMicRecorder` at `MicProbeSession.swift:76`) once the program has been quiet, using the signal
  corrections already wait on: `btProgramIsSilent` (`NativeBackend.swift:11279`), passed as the
  `programIsSilent` closure at `NativeBackend.swift:11089`. Skip while a window is in flight — one mic.
- Keep only the newest slice plus the time it was taken; refresh on the window schedule. Drop it past a
  set age, and drop it when the mic level now is far from the level at capture time, so a slice from a
  quiet room never weights a loud one.
- The speakers stream zeros through program silence (ticket 04), so the room really is quiet then. That
  is the point: the slice measures the room and the mic, not the music.
- Mic permission: reuse `permissionIsGranted` (`PassiveDriftSampler.swift:428`); never prompt for this.
- Privacy: memory only, never written to disk, never leaves the Mac.
- Honest gain: sharper fine timing on a lag already chosen. Little help choosing the lag, which is the
  live failure. The brief ranks it last for that reason and calls it cheap
  (`dev/notes/drift-tde-algorithms-brief.md:175-180`).

Done when: a unit test with an injected recorder shows a slice captured only while the program is
silent and attached to the next window's `analyze` call as `ambientNoise`, and none captured while the
program plays. Then re-run the ticket-16 fixtures with and without a synthetic noise slice and write the
score comparison into this ticket's Comments.

## Comments

- 2026-09-13: drafted from live test 2 (HANDOFF.md "Still open") and dev/notes/drift-tde-algorithms-brief.md (ranked last for lag choice; cheap). Live test 3's window 2 was near-field noise at the Mac, and the mic's own floor limits the treble band.
