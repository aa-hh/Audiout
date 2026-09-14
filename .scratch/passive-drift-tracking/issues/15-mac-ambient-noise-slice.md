# 15 — Mac: record a room-sound slice during program silence and pass it to the correlator

Status: shelved (Alec, 2026-09-14) — built on branch claude/drift-t15-ambient, NOT merged; see the 2026-09-14 review comment
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

- 2026-09-14, built then SHELVED after adversarial review. The code is on branch
  `claude/drift-t15-ambient` (worktree `.claude/worktrees/drift-t15-ambient`,
  forked from `9a8de7f0`), pushed, NOT merged. Do not merge it as it stands.

  **The microphone cap is broken, which is the one thing the owner set as a
  requirement.** `PassiveDriftSampler.swift:652`: an empty capture is dropped
  and leaves `ambient` nil, so the age-cap test at `:642` passes again on the
  very next poll one second later (`:620`) and `recorder.start()` runs again.
  `BuiltInMicRecorder` has three documented ways to start cleanly and return
  nothing (`MicProbeSession.swift`: a configuration change ~42 ms in with a
  failed restart, `engine.start()` returning with the engine stopped, no valid
  host time on any buffer). Result: the mic indicator blinks on for 1 s roughly
  every 2 s for the whole silent spell. `:645` (start throws) retries the same
  way. A failed attempt must count against the cap exactly like a kept slice.

  Same leak at `:658` when the program is audible at stop: every later pause of
  6 s or more captures again until one sticks. Bounded by play/pause, not by the
  25-minute rule.

  **The stop-time check has a hole as wide as the dispatch overshoot.**
  `programIsSilent()` means "no audible render in the last 1.0 s"
  (`DriftCorrectionApplier.gapAfterSilentSeconds`), and the slice is also 1.0 s.
  A render in the first few ms of the slice is already older than 1.0 s when the
  `asyncAfter` fires, so it reads silent and the slice is kept with music in it.
  If the weighted pass then accepts a peak, the plain filter never runs
  (audiout-shared 0.15.1 `PassiveDriftCorrelator.swift:396-402`), so a wrong lag
  can move a speaker. Needs a margin between slice length and gap, or a second
  check a poll later.

  **The test pins the call site and nothing else.** Three mutations all stayed
  GREEN: removing `ambientNoise:` from the `analyze` call entirely (the phase-3
  assertion reads a flag set before the call, so it proves the flag, not the
  data path); removing the `guard programIsSilent()` at `:658`; removing the age
  cap at `:642`.

  **Two gaps that are the work order's fault, not the executor's:** the ticket's
  "drop it when the mic level now is far from the level at capture time" was
  deliberately scoped out (there is nothing comparable to measure at window
  time, since the only level available then contains the program), and the
  second "Done when" — replaying the ticket-16 fixtures with and without a
  synthetic noise slice and writing the comparison here — was never run.

  **Why shelved rather than fixed:** that missing comparison is the whole value
  question. The weighting divides each bin by measured stationary room noise, on
  top of the existing 0.7 whitening, and everything below 300 Hz is cut before
  either applies. The live failure is the music's own repeats, which a room-noise
  spectrum cannot touch. This ticket already ranked itself last and admitted it
  gives "little help choosing the lag, which is the live failure". So the cost is
  a microphone indicator plus two real defects, against a benefit nobody has
  measured.

  **To un-shelve:** run the fixture comparison FIRST and show a real gain. Only
  then fix the cap leak, the silence-check margin, and the test's three green
  mutations.

