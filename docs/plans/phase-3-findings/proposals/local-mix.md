# Mixing the Mac's Own Speakers With AirPlay — Design Proposal

## The restriction

Today you can play audio on the Mac's own speakers alone ("Current Device"),
or on one or more AirPlay speakers together — but you can't turn on the Mac's
own speakers *at the same time as* an AirPlay speaker. If you try, the app
quietly refuses the toggle (it's greyed out with a tooltip explaining why, not
a silent no-op). This was a deliberate call made back in Phase 1: at the time,
there was no way to keep the Mac's own speakers in step with AirPlay's own
~2-second sync buffer, so mixing them would have meant hearing the Mac's audio
arrive up to two seconds before the same audio hits the AirPlay speakers —
which is worse than just blocking it. The plan always was to lift this once
the app had its own native AirPlay engine, by giving the Mac's speakers a
"synced local output" that plays on the same shared clock as everything else.
This is that native engine now exists (it shipped and is what the app uses
today) — this proposal is about whether now is the time to actually build the
synced-local piece and lift the restriction, or to leave it and just explain
it better.

## What's already built toward lifting this

Short version: the door was left open for this, but nothing behind it has
been built. Here's exactly what exists today, so the size of the remaining
work is clear:

- The AirPlay engine (`AirPlayEngine.swift`) has a small API already sitting
  there for this: a `localOutput` property and a `setLocalOutputEnabled(_:)`
  method. But read what they actually do — `setLocalOutputEnabled` just flips
  a private boolean (`localOutputEnabled`) and nothing else. The code comment
  on it says, verbatim, "Records intent only," with a `TODO(later task):
  start/stop the Core Audio unit here." There's a companion type,
  `LocalOutputSink`, whose `isImplemented` property is hard-coded to always
  return `false`. This is a stub — an honest placeholder for a future feature,
  not a partially-built one. Nothing in the app (`NativeBackend`, the group
  logic, anything) even calls this API yet; it's unused outside the engine
  package itself.
- The actual hard part — capturing the AirPlay session's shared timing clock
  and using it to play a deliberately delayed copy of the audio on the Mac's
  built-in speakers so it lines up sample-for-sample with the AirPlay
  speakers — has no code at all, anywhere. That's the piece that makes this
  a "synced" local output instead of just "local output."
- There IS a related, already-working feature that shows the team knows how
  to render live audio to the Mac's own speakers: `LocalPlaybackEngine`,
  used today when you route a single app to "Current Device" from the
  per-app routing list. It uses a real `AVAudioEngine` to play that one app's
  captured audio on the Mac's speakers as its own independent stream. This is
  useful groundwork — it proves the team already has working Core Audio
  playback plumbing in the codebase — but it is explicitly NOT synced to
  anything; it plays in real time, which is exactly the "arrives early"
  problem this proposal is about. It solves a different problem (give one
  routed app its own local volume), not this one.
- The actual on/off restriction you see in the app is implemented cleanly and
  is easy to find: `GroupController.setDeviceSelected` in
  `AudioutCore/Sources/AudioutCore/GroupController.swift` refuses the
  toggle with a fixed message ("Synced everywhere-audio arrives with the new
  engine") whenever turning on the Mac's speakers would mix it with an
  already-selected AirPlay device, and `PopoverController` wires that refusal
  into a tooltip on the greyed-out checkbox. So lifting the restriction later
  is a small, well-isolated change on this side — the toggle logic is not the
  bottleneck. The bottleneck is entirely on the engine side, where nothing
  has been started.

In short: the API name and shape are already sketched out as a placeholder,
and the team has done the easier building block (unsynced local playback)
once already for a different feature — but the one piece that actually
matters here, clock-synced playback, is 0% built.

## Option A — build the real synced-local-output feature now (full lift)

Implement the actual feature: read the AirPlay session's shared presentation
clock out of the engine, mute the Mac's normal system output, and render a
deliberately delayed copy of the same audio through a Core Audio output timed
to land in step with the AirPlay speakers. Wire it into `NativeBackend` and
remove the block in `GroupController`.

**Upside.** This is the feature exactly as originally envisioned — the Mac's
speakers become a full member of a mixed set, with no restriction and no
workaround needed. It removes a rough edge a real user (the owner, in the live
walkthrough) already noticed and called out as worth fixing before release,
and it's one of the differentiators the native engine was built to unlock in
the first place.

**Downside — and this is the important part.** This is not a small remaining
step; it is close to new feature work. Nothing that does the actual
syncing exists yet, so this needs: (1) new plumbing inside the engine to
expose its internal timing/clock information as something the Swift side can
use — timing details currently live deep in the vendored C code and aren't
exposed at all; (2) a real Core Audio output path that can render audio on a
deliberate delay, timed against that clock, which is a different and harder
problem than the "play it now" approach `LocalPlaybackEngine` already uses;
(3) rewiring the on/off logic in `GroupController` and retesting every
existing case that currently assumes "local OR AirPlay, never both" (the
auto-swap and reverse-auto-swap behavior around Main Out, for example, both
lean on that assumption); and (4) — matching this repo's established pattern
for anything touching real AirPlay timing — a genuine gated live test against
real hardware, listening by ear to confirm the Mac and the speaker are
actually in sync, since this exact kind of audible drift is what caused the
restriction to be added in the first place. Realistically this is multiple
work sessions of engine-level effort with real hardware required to verify
it, not a quick follow-up.

## Option B — leave the restriction, communicate it better

Keep the block exactly as it is today, but improve how the reason is
surfaced. Right now the explanation only appears as a tooltip on a greyed-out
checkbox — something you only see if you hover over a control that looks
disabled, which is easy to miss entirely (this is very likely why the owner still
flagged it as a rough edge during the walkthrough, even though a reason
already exists under the hood). Make the "why" visible without hovering —
for example, a small inline note near the device row, or copy in the row's
subtitle, saying plainly that the Mac's speakers can play alone or the
AirPlay speakers can play together, but not both at once yet, and why.

**Upside.** This is a small, low-risk change — the refusal message and the
logic that decides when to show it already exist (`GroupController.
localMixRefusalReason`); this is purely a matter of showing that message more
prominently in the UI, which is a UI-only change with no engine work and no
new hardware testing required. It ships fast and directly answers the
confusion the owner ran into.

**Downside.** It doesn't give the user the feature they might actually want
— someone who genuinely wants their Mac and their AirPlay speakers playing
together at once still can't do that, they just understand more clearly why
not. It's a better-explained limitation, not a fix.

## Recommendation

Given that the synced-local piece is a true 0%-built placeholder — not a
nearly-finished feature — Option B (explain the restriction clearly in the
UI) is the right move for now, with Option A revisited as a real scoped
project later rather than folded into this pass.
