# W1-T0 spike: can a live Core Audio Tap's process list be updated in place?

*Investigation only — no shipping code changed. Done for Wave 1 of
docs/plans/PLAN-RELIABILITY.md, to inform W1-T4 (live membership diffing for
browser tab processes).*

## Answer: yes, with caveats — `kAudioTapPropertyDescription` is documented as settable

Apple's SDK header for the Core Audio Taps API
(`CoreAudio.framework/Headers/AudioHardware.h`, macOS 14.2+ SDK, "Tap Object
Properties" section) documents three properties on the Tap object class:

- `kAudioTapPropertyUID` — read-only persistent identifier.
- `kAudioTapPropertyDescription` — **"The `CATapDescription` used to initially
  create this tap. This property can be used to modify and set the
  description of an existing tap."** This is explicit, unambiguous language
  that the property is settable post-creation via
  `AudioObjectSetPropertyData`, not just gettable.
- `kAudioTapPropertyFormat` — the tap's current `AudioStreamBasicDescription`;
  documented as informational output only (no "can be used to set" language).

Corroborating evidence from `CATapDescription.h`: the `processes` property —
the array of process object IDs a tap mixes/excludes — is declared
`@property (atomic, copy, readwrite) NSArray<NSNumber*>* processes`. It's a
mutable, readwrite Obj-C property on the description object itself, which is
consistent with "mutate the description, then push it back to the live tap
via `kAudioTapPropertyDescription`" being the intended update path. Other
description fields (`mono`, `exclusive`, `mixdown`, `deviceUID`, `stream`,
`muteBehavior`) are readwrite too, suggesting the same set-property mechanism
could adjust more than just membership, though W1-T4 only needs `processes`.

`AudioHardwareTapping.h` (the create/destroy entry points) has exactly two
functions — `AudioHardwareCreateProcessTap` and
`AudioHardwareDestroyProcessTap` — no `...Update` or `...Modify` function
exists at that layer. That's expected: the update path is the generic
`AudioObjectSetPropertyData(tapID, &address, ...)` call against
`kAudioTapPropertyDescription`, the same mechanism used elsewhere in Core
Audio for any settable object property, not a tap-specific function.

## What's *not* confirmed

- **No caveats or failure semantics are documented.** The header doesn't say
  whether a live process-list update is applied glitch-free, whether it can
  fail if the new process set includes a since-terminated PID (a likely race
  for W1-T4's exact scenario — tab process already dead by the time the
  update lands), or whether format (`kAudioTapPropertyFormat`) can change
  correctly out from under a running aggregate device/IO consumer when
  membership changes (e.g. mono singleton -> stereo mix).
- **Nothing in this codebase currently uses this path.** `git grep` in
  `NativeCaptureCoordinator.swift` and `PerAppCaptureCoordinator.swift` shows
  only `AudioHardwareCreateProcessTap` (once, at setup) and
  `AudioHardwareDestroyProcessTap` (once, at teardown at
  `NativeCaptureCoordinator.swift:1053`), plus a single
  `AudioObjectGetPropertyData` read of `kAudioTapPropertyFormat`
  (`NativeCaptureCoordinator.swift:834-839`) to pick up the format after
  creation. No existing call sets `kAudioTapPropertyDescription` or writes to
  a live tap. There's no in-repo precedent to lean on, and no compiled
  probe was run against real hardware for this spike (per instructions —
  documentation/API-surface investigation only, no live audio test).
- Apple's own sample/WWDC material for this API (not available offline in
  this environment) would likely clarify glitch behavior on live update, but
  wasn't consulted here.

## Recommendation for W1-T4

**Prefer a live update via `AudioObjectSetPropertyData(tapID,
kAudioTapPropertyDescription, ...)` with a mutated `CATapDescription.processes`
array, but implement it behind a fallback to full teardown/recreate on any
non-zero `OSStatus`.** The header's language is about as close to an explicit
"yes" as Apple's docs get without a WWDC talk to back it up, so it's worth
building — an in-place update avoids the audible gap and IO-thread churn a
full tap rebuild causes on every tab open/close. But because failure modes on
a since-dead process ID and cross-mono/stereo format transitions are
undocumented, the implementation must treat the set call as best-effort: try
it, and if it errors (or if a subsequent format re-read shows the tap fell
out of a healthy state), fall back to the existing destroy-then-recreate path
that R10's fix already exercises for sample-rate changes.

If W1-T4's owner wants the simplest safe default instead — no live-update
code path at all — **"always recreate" remains an acceptable fallback**
given the caveats above; it's already what the codebase does today and is
proven correct, just noisier on rapid membership churn (e.g. a browser
opening/closing several tabs in a burst).
