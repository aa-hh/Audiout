# The moment itself: the sync sheet's waiting state

Lens: the user has just opened the sheet, the speaker connected recently, and
there are N seconds of settling left. What do they see, hear, feel and do in
those seconds so it reads as control and preparation rather than a locked door.

Paths are absolute. Every code claim carries a file and line. Where I could not
confirm something I say so.

---

## Ground facts I checked before designing

These change what is worth designing, so they come first.

**1. The minimum wait is about 10 seconds, not 60.** On the Mac branch
`claude/settle-window-adaptive`, `report(uid:hasStoreEntry:now:)` tests the
detector before the floor: `if stable { settleRemaining = nil }` comes first,
and only then the 60 s floor (branch
`AudioutCore/Sources/AudioutCore/BTAlignmentFreshness.swift:269-280`). "Stable"
means `stableForSeconds >= BTClockStability.stableAfterSeconds`, which is 10.0
(branch `AudioutCore/Sources/AudioutCore/BTClockStability.swift:62`). So a Sony
that never jumps clears at roughly 10 to 11 seconds. The brief's reading that
the floor holds a clean speaker for 60 s is wrong for this branch. The 60 s
floor only bites while the detector has not yet accumulated 10 quiet seconds.

**2. The wait only runs while the speaker is playing.** A sample where
`sampleTime` did not move returns `.frozen` and drops the baseline (branch
`BTClockStability.swift:83-91`); a failed query is a skipped tick with no
observation at all (branch `BTClockStability.swift:196-204` in the poller's
`tick()`). A silent speaker therefore never accumulates quiet seconds. The
sheet's existing precondition already demands playback ("Play it first. The
room has to hear both speakers.",
`/Users/alechenderson/Projects/audiout-remote/AudioutRemote/UI/Sync/SyncSheet.swift:207`),
so the two agree, but it means any waiting screen must not tell someone they can
put the phone down and come back.

**3. The Mac does not refuse an early measurement.** The gate is entirely a
phone-side rendering decision. `CompanionAlignmentPreconditions.evaluate` checks
only that the target is Bluetooth, audible, and has an audible reference (branch
`BTAlignmentFreshness.swift:409-428`). Nothing consults the settle window. So
"measure now anyway" is already legal on the wire, and the phone branch already
ships it (`git show claude/settle-window-phone:AudioutRemote/UI/Sync/SyncSheet.swift:254`).

**4. The phone can run a measurement and simply not report it.** The Mac only
learns a number when the phone calls `reportAlignmentMeasurement`
(`AudioutRemote/Model/AlignmentRunController.swift:294`), and that call is what
ends the run for the Mac (`AlignmentRunController.swift:286-288`). A run that
finishes and calls `cancelAlignmentProbe` instead
(`AlignmentRunController.swift:205-209`) leaves nothing stored. This is a
phone-only change: no Mac work, no wire field. It is what makes an honest
"did I hear both speakers from here" check possible.

**5. The phone cannot honestly tell you that you are standing in a good spot.**
ProbeKit says so in its own contract: "Held beside one speaker it is a confident
wrong answer, and nothing in the signal can tell the two apart. Placement is the
caller's problem to state plainly to the user; this package cannot detect it."
(`/Users/alechenderson/Projects/audiout-shared/Sources/ProbeKit/ProbeAnalyzer.swift:45-48`).
What it can tell you is whether both sweeps were found: that is the difference
between a result and `probeNotFound` (`ProbeAnalyzer.swift:26-28`), which the
run controller already turns into "Couldn't hear both speakers from there"
(`AlignmentRunController.swift:80`, `AlignmentRunController.swift:321-322`).

**6. There is a per-speaker confidence number, but it is not a loudness.**
`SyncProbeCorrelator.Measurement` carries `arrivalA` and `arrivalB`, each with a
`peakToSidelobe`
(`/Users/alechenderson/Projects/audiout-shared/Sources/ProbeKit/SyncProbeCorrelator.swift:196-223`),
and `ProbeAnalysis` collapses them to the weaker of the two
(`ProbeAnalyzer.swift:16-19`). Surfacing both would be an additive change in
`audiout-shared`. But peak over background is a cleanliness ratio, not a level:
a quiet speaker in a quiet room can beat a loud one in a noisy one. So it can
honestly say "found" or "not found" per speaker. It cannot say "this one is
louder from here", and it cannot say anything about distance. **Not verified:**
whether the two ratios separate reliably enough to distinguish "one speaker is
much closer" in real rooms. Nobody has that data.

**7. The tick already plays on both speakers and it costs a Mac session.**
`setAlignmentTick(targetID:active:)` exists
(`AudioutRemote/Model/MacSessionProtocol.swift:82`) and the by-ear page turns it
on for exactly this (`SyncSheet.swift:495-497`). The Mac holds one
phone-driven run or tick session at a time (branch
`BTAlignmentFreshness.swift:449-451` doc). So a tick running during the wait
must be turned off before a measurement starts, or the run is refused.

**8. Leaving ticks on has a real trap. This is the sharpest one.** The Mac
writes back whatever tuning the tick session was left holding when the session
ends (`SyncSheet.swift:41-44` and `SyncSheet.swift:520-526`). So if a waiting
screen offers the by-ear slider while the speaker is still settling, the user
can silently store a number measured against a moving clock. That is the exact
failure the settle window exists to prevent, arriving by the back door. Today
"Adjust by ear" sits next to the disabled Measure button on the placement page
(`SyncSheet.swift:174`) and is reachable during the whole wait. Any concept
below that keeps ticks running must keep the slider out of reach until the
speaker is steady, or accept that hole.

**9. The haptic, the screen-awake and the local countdown already exist on the
phone branch.** Light impact when the button goes live (branch
`SyncSheet.swift:160-165`), screen kept awake only while counting, running or
waiting on a re-check (branch `SyncSheet.swift:167-168`, `352-355`), and the
local tick-down re-seeded from every snapshot (branch `SyncSheet.swift:305-311`,
`297-301`). None of the concepts below need to invent these.

**10. Gold text is not a gold button.** The rule is one gold action per decision
screen (`/Users/alechenderson/Projects/audiout-remote/DESIGN.md:1181-1183`). The
placement page today already carries one filled gold button plus one gold text
link (`SyncSheet.swift:170-178`), and the branch adds a second gold text line
(branch `SyncSheet.swift:254`). So gold text lines are allowed to stack; a
second filled pill is not.

---

## Concept 1: a short walk-through that ends at the button

Three screens, one thing each, paced by the user's own taps rather than a timer.
It teaches by making the user do the thing, and it lands them at the button at
roughly the moment a typical speaker has settled. When there is no wait, the
same three screens still run, because placement is what decides whether the
measurement is any good (fact 5), and they take about as long as a person needs
to walk across a room anyway.

### Screen 1 of 3

    Take the phone to where you listen.

    Not next to a speaker. Where you actually sit. The phone measures
    the room from wherever it is standing.

    [ I'm there ]        Adjust by ear

The gold button is live immediately. Nothing is gated here; the user is being
asked to walk, and only they know when they have.

### Screen 2 of 3

The Mac starts the tick on both speakers as this screen appears.

    Can you hear both from here?

    Kitchen Sonos and Living Room HomePod are each clicking.

    [ Both of them ]     [ Only one ]

If they tap "Only one":

    Move somewhere both reach you, or turn the quiet one up.

    The clicks keep going.

    [ Both of them now ]     [ Only one ]

No timer, no advance. The user fixes it and answers again. Nothing is stored
either way: the answer changes which screen shows, not what the Mac holds.

### Screen 3 of 3

Ticks stop as this screen appears (fact 7).

    Hold still.

    You'll hear two sweeps over the music. Stay quiet while they play.

    [ Measure ]          Adjust by ear

While the speaker is still settling, the button is not live and one footnote
sits above it:

    Kitchen Sonos is still settling after connecting, so a measurement
    now may be off. About 25 s to go.

    Measure it now

("Measure it now" is the existing gold text escape, branch
`SyncSheet.swift:254`. Wording kept because it already promises exactly what it
delivers: the sheet re-checks by itself later, branch
`SyncSheet.swift:668`.)

**What the user does.** Walks. Listens. Answers one question with their ears.
Then holds still. Three physical acts, no reading of theory.

**What the phone shows, and the motion.** No green anywhere on these three
screens: the chassis stays cool and the green field stays the run page's own
identity (`SyncSheet.swift:239-247`). Screens cross-slide on the app's one
spring, `.spring(duration: 0.25)` (`DESIGN.md:1174-1176`). Under Reduce Motion,
cross-fade in place with no travel; the copy and the step position carry the
whole state, so nothing is lost.

**Instant.** All three screens still show, all three buttons live from the
moment each appears. Nothing flashes and vanishes, because nothing on these
screens is driven by the settle number except the footnote and the button's
liveness on screen 3, and with no wait there is no footnote. Total added time is
two taps.

**15 s.** The user is on screen 2 or 3 when it clears. If they are on screen 2,
the wait is invisible: they answer, land on screen 3, and the button is already
live. This is the case the design is tuned for.

**45 s.** They reach screen 3 with time left. The screen holds because the ticks
can keep going: the honest thing to do with a wait is listen to the room, and
the clicks are real sound, not a progress animation. Screen 3's footnote counts
down in 5 second steps (the branch already rounds up to the next multiple of 5
so the text changes at most every 5 s, branch `SyncSheet.swift:724`). If they
would rather not wait, "Measure it now" is right there.

**The button going live.** The footnote disappears, "Measure it now"
disappears with it, and the pill goes from `well` to `gold` fill
(`SyncSheet.swift:620`). Light impact haptic (branch `SyncSheet.swift:160-165`)
and a VoiceOver announcement (branch `SyncSheet.swift:104-107`). No motion, no
pulse: the fill change plus the haptic is the event. A pulsing button would
compete with the field on the next page.

**Multi-speaker.** The chain line after a verdict already offers the next
untuned speaker (`SyncSheet.swift:338-352`). Taking it should skip screens 1 and
2 and open straight at screen 3: the user has not moved, and asking them to walk
again is the thing that would make this feel like a lecture. One session-lived
flag on the sheet does it.

**State and commands.**
- Tick on and off: EXISTS, `MacSessionProtocol.swift:82`, used at
  `SyncSheet.swift:495-497`.
- Speaker names and reference name: EXISTS, `SyncSheet.swift:74-75`.
- Settle seconds and the local count: EXISTS on the branch,
  branch `SyncSheet.swift:297-311`.
- Haptic on going live: EXISTS on the branch, branch `SyncSheet.swift:160-165`.
- Step index (which of the three screens): NEW, phone only, local `@State`.
- "Already walked through this in this sheet": NEW, phone only, local `@State`.
- Naming the two timbres ("a bright click" from one, "a low knock" from the
  other) the way the Mac's own wizard does
  (`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:59-69`):
  NEW wire string, because the rule is per transport and the phone deriving it
  from `kind` would be the phone computing state it is supposed to render. Skip
  it in a first cut; screen 2's question works without it.

**Conflicts with the design rules.** Screen 2 carries two chips and no filled
gold button, which is fine under the one-gold-action rule; if the chips were
gold fills that would be two gold actions on one screen, so they should be the
neutral `pill` treatment (`WarmSignal.swift:334`). The bigger tension: this adds
two screens before a button that used to be one tap away, which is literally the
artificial gate Alec asked for and also the thing he called overly complex. It
lives or dies on whether screens 1 and 2 feel like being helped or being
delayed, which is a device call, not a code call.

**Effort: M.** Phone only. Three view states, one tick lifecycle already
written, no Mac and no wire.

---

## Concept 2: the wait is an ear check

One screen. The wait is spent listening rather than reading, and the listening
is honest about what it can and cannot tell you.

The Mac's tick starts as the sheet opens. The question asked is deliberately not
"which one is first" (that is a measurement, and during settling the answer is
moving), but "how many clicks do you hear".

### While settling

    Listen for two clicks.

    Kitchen Sonos and Living Room HomePod are both clicking. Go to
    where you listen, then tell me what you hear.

    [ One click ]   [ Two clicks ]   [ Only one speaker ]

After any answer:

    Kitchen Sonos is still settling after connecting. You may hear the
    two clicks slide apart while it does. That's the thing we're
    waiting for.

    About 25 s to go.

    [ Measure ]          Measure it now          Adjust by ear

If they answered "Only one speaker":

    Move somewhere both reach you, or turn the quiet one up.

### When it settles

    It's holding steady now.

    [ Measure ]          Adjust by ear

**Is a tick during settling misleading? Partly, and the copy has to own it.**
The gap between the two clicks is genuinely moving during settling: the Sonos
Move 2 accumulated about 353 ms of net shift over 42 seconds across 32 re-anchor
jumps (`dev/notes/handoff-2026-09-03-settle-window-adaptive.md`, "Why the gate
exists"). So a user who hears one click at second 8 and two clicks at second 30
is hearing something real, and the copy above tells them that is expected rather
than letting them conclude the app broke it. What would be misleading is
treating the answer as information: storing it, feeding it into anything, or
letting the by-ear slider act on it. It does none of those.

**The trap this concept walks straight into.** Ticks running plus "Adjust by
ear" one tap away means the user can store a tuning against a moving clock
(fact 8). This concept must hide or disable the by-ear slider while
`settleRemainingSeconds` is non-nil, which is a change to the existing sheet, not
just an addition. The by-ear page's Revert and Clear should stay reachable
(`SyncSheet.swift:514`, `SyncSheet.swift:520`); it is the slider that must wait.

**What the user does.** Walks, listens, taps once. Then keeps listening, or
measures early.

**What the phone shows, and the motion.** No new visual. Ordinary chassis, one
headline, one body, three chips, the gold pill. Motion is only the answer chips
giving way to the waiting copy, on the same one spring. Under Reduce Motion the
copy swaps with no travel.

**Instant.** No wait means no reason to hold anyone: the sheet opens on the
existing placement page with a live button and no ticks at all. The ear check
does not appear. That is a deliberate asymmetry, and it means the screen the
user sees depends on their speaker, which is worth Alec's eye.

**15 s.** The question and one answer fill it. The button is live by the time
they have finished answering.

**45 s.** The clicks keep going and the count keeps dropping in 5 second steps.
This is the case where a single static screen risks feeling abandoned, and the
only thing keeping it alive is sound in the room, not pixels. That is either
enough or it is not, and it is an ear test rather than an argument.

**The button going live.** As Concept 1: fill change, light impact, VoiceOver
line, plus the ticks stopping. The ticks stopping is itself the strongest signal
in the room and costs nothing.

**Multi-speaker.** The chain line opens the next speaker with the tick already
running against a new pair, so the question can be asked again without any new
screen. Its answer is worth asking again because the reference speaker changed.

**State and commands.**
- Tick on and off: EXISTS, `MacSessionProtocol.swift:82`.
- Which speakers are ticking, by name: EXISTS, `SyncSheet.swift:74-75`.
- The settle count: EXISTS on the branch.
- The answer the user gave: NEW, phone only, local `@State`, never sent
  anywhere.
- Disabling the by-ear slider during settling: NEW, phone only, and a change to
  `FineTunePage` rather than an addition (`SyncSheet.swift:549-573`).

**Conflicts with the design rules.** Three chips plus a gold pill plus two gold
text lines is a crowded screen; the chips must be neutral. "Nothing app
initiated" (`DESIGN.md:1128-1131`) is worth checking: the tick starts because
the user opened the sheet, which is their own action, and the by-ear page
already starts ticks on appear (`SyncSheet.swift:535-538`), so the precedent is
set. But the sheet opening now makes noise in the room, which it did not before.
That is a real change in behaviour and Alec should rule on it.

**Effort: S to M.** Phone only. One screen's worth of copy and one existing
command, plus the by-ear slider lockout, which is small but is a behaviour
change to shipped code.

---

## Concept 3: the field shows the settling, from the Mac's own verdict

The sheet already owns the green field (`SyncSheet.swift:239-247`), and
`EmitterField` has exactly the knob this needs. Emitters that share a `family`
ring in lock-step; emitters with different families do not
(`AudioutRemote/UI/Shared/EmitterField.swift:38-44`, `50-52`). So "these two
agree in time" and "these two do not" have a literal, already-built picture, and
it is the same picture the verdict page's converging rings are drawing by hand
(`SyncSheet.swift:637-668`).

### While settling

A framed field box, roughly the shape `SearchWaves` uses on the Connect gate
(`AudioutRemote/UI/Connect/ConnectGateView.swift:642-651`), two emitters, the
"Movie night" ramp. The two emitters carry different families: their rings cross
at a place that wanders.

    Kitchen Sonos is finding its footing.

    [ field ]

    Settling

    Its clock is still moving after connecting. A measurement now
    would measure the moving, not the speaker. About 25 s to go.

    [ Measure ]          Measure it now          Adjust by ear

### When it settles

The two emitters take the same family and fall into lock-step. The word changes.

    Steady

    [ Measure ]          Adjust by ear

**What "restless" and "steady" look like.** Steady is the two ring patterns
breathing together, crests arriving at the same moments, which is what a shared
family does. Restless is the same two patterns running at their own rates so the
crests slide past each other. Nothing else changes: no speed-up, no jitter, no
colour shift. The difference is legible in about two seconds of watching and
means precisely one thing.

**How honest is it?** Two tiers, and they differ a lot in cost.

*The cheap tier, no wire change.* Drive the family split off
`settleRemainingSeconds` alone: non-nil means separate families, nil means
shared. That is honest, because that field already is the Mac's verdict on
whether the clock can be trusted (branch `BTAlignmentFreshness.swift:269-280`).
It does not show individual jumps, so it is not a live readout; it is a
two-state picture of a two-state fact, which is what the field is good at.

*The expensive tier, needs Mac and wire work.* Show each real jump as a visible
step: when the Mac reports `.jumped` (branch `BTClockStability.swift:41`,
`119-122`), the target's emitter shifts position once. Every visible movement
would correspond to one real re-anchor. That needs a new push message on the
wire and a new hook on the Mac, and it turns a background into a live
instrument, which is a bigger claim than the sheet makes anywhere else.

**Reduce Motion.** `EmitterField` renders one still frame at a fixed `t` under
Reduce Motion and never loops (`EmitterField.swift:85-86`). So under Reduce
Motion the field says nothing at all, and the word underneath carries the whole
state. That is why the word is always present, for everyone, and why it is the
VoiceOver value rather than the field being described. The field must also stand
down at accessibility text sizes, as the Connect gate's does
(`DESIGN.md:1193-1194`).

**What the user does.** Nothing. This is the weakness: it is a thing to watch,
not a thing to do. It answers "why am I waiting" and does not answer "what
should I be doing with these seconds". It wants Concept 1 or 2 beside it.

**Instant.** The field never appears at all: with no wait there is nothing to
show settling. So an instant speaker gets today's plain placement page and a
live button. Nothing flashes.

**15 s.** The field appears once, holds for a moment, falls into step. That is a
pleasing beat and it is honest.

**45 s.** The field is the only thing carrying the time, and a picture that says
"still restless" for 45 seconds says the same thing 45 times. On its own this
case is where the concept is weakest.

**The button going live.** Two things at the same instant: the emitters fall
into lock-step and the pill fills. Plus the haptic and the word change. This is
the best "it happened" moment of the four concepts because the picture and the
control agree.

**Multi-speaker.** The field always shows the target and its reference, so the
next speaker in the chain redraws with a new pair and no new state.

**State and commands.**
- `EmitterField` with per-emitter `family`: EXISTS,
  `EmitterField.swift:45-55`, `130-135`.
- The "Movie night" ramp: EXISTS, `SyncSheet.swift:279`.
- Framed field box with the chassis' own edge: EXISTS as a pattern,
  `ConnectGateView.swift:645-651`.
- `settleRemainingSeconds`: EXISTS, wire,
  `/Users/alechenderson/Projects/audiout-shared/Sources/AudioutProtocol/CompanionSnapshot.swift:53`.
- Per-jump events: NEW on the Mac (a hook where `noteClockOutcome` already
  handles `.jumped`, branch `BTAlignmentFreshness.swift:201-204`) and NEW on the
  wire.

**Conflicts with the design rules.** Green inside the sheet is allowed and this
stays inside it (`DESIGN.md:1084-1090`). The real tension is that the field is
currently the run page's identity: putting it on the waiting screen too makes
the run page less distinct. Keeping the waiting one small and framed while the
run's is full-bleed is the mitigation, and it is exactly the difference between
the Connect gate's framed waves and the Groups empty state's full field.

**Effort: S for the cheap tier, L for the per-jump tier.** The cheap tier is one
new view in the sheet and no Mac work at all.

---

## Concept 4: name the speakers first, then work down the list

This is Alec's own second idea. The wait is per connection, not per device
(`handoff-2026-09-03-settle-window-adaptive.md`, "Why the gate exists"), so with
several speakers the waits can overlap: while speaker two settles, speaker one
is being measured. The user walks once.

### Screen 1

    Which speakers should I set up?

    I'll do them one at a time, from wherever you're standing.

    Kitchen Sonos          Timing not set        [x]
    Bathroom Move          Timing not set        [x]
    Desk speaker           Reconnected           [ ]

    [ Set up 2 speakers ]

### Screen 2

    Take the phone to where you listen.

    Not next to a speaker. Where you actually sit.

    [ I'm there ]

### Then, per speaker

    Kitchen Sonos first.

    [ Measure ]

and between them:

    Kitchen Sonos is done. Bathroom Move next.

    [ Measure ]          Adjust by ear

**What the user does.** Picks a list, walks once, then presses one button per
speaker without moving.

**What the phone shows, and the motion.** A plain checklist on the chassis; no
field, no green. Between speakers the headline swaps on the same spring, cross
fade under Reduce Motion.

**Instant, 15 s, 45 s.** This concept changes the arithmetic rather than the
screen: with two or more speakers the second one's wait is spent measuring the
first, so a 45 second settle costs nothing after the first speaker. With exactly
one speaker it adds a list screen and helps nobody, which is its main problem.

**The button going live.** Same treatment as Concept 1. The difference is that
after the first speaker the button is usually already live when the user arrives
at it, which is the whole point.

**Multi-speaker.** This is the concept.

**State and commands.**
- The list of Bluetooth speakers with their alignment status: EXISTS,
  `SyncSheet.swift:374-383`, and the snapshot field at
  `CompanionSnapshot.swift:43-53`.
- Selecting and routing speakers, if the flow wants to bring one up
  deliberately: EXISTS, `MacSessionProtocol.swift:47` and
  `MacSessionProtocol.swift:49`.
- The chosen list and its order: NEW, phone only.
- Running the queue: NEW, phone only, and it is the piece that needs care, since
  a queue that advances by itself starts looking like a run the user did not
  start.

**Conflicts with the design rules.** Two: "the sheet is one place" becomes a
sheet that is a workflow, and a queue that steps to the next speaker on its own
brushes against "nothing app initiated"
(`DESIGN.md:1128-1131`). The existing chain line is the sanctioned shape for
"do the next one" precisely because it is one offer the user may ignore
(`SyncSheet.swift:372-373` doc). This concept replaces a line the user may
ignore with a list they committed to up front, which is a different promise.
It also front-loads a decision before the user has heard anything work.

**Effort: L.** Phone only in principle, but it is a new flow with its own
ordering, its own failure handling per speaker, and its own way out mid-queue.

---

## What must not be done

- **No fake progress.** No bar, no spinner, no percentage. The run page already
  refuses one on the grounds that the phone knows four moments and no
  percentage (`SyncSheet.swift:230-234`), and the waiting screen knows less than
  that. The Mac's number is an estimate that can go back up when the clock jumps
  after the floor (branch `BTAlignmentFreshness.swift:274-277`), so a bar would
  have to run backwards.
- **No countdown presented as a promise.** "Ready in 47s" is what Alec hit, and
  the number is the Mac's estimate, not a deadline. The branch's "About 25 s to
  go", rounded up to the next multiple of 5 (branch `SyncSheet.swift:724`), is
  the right shape: it reads as an estimate because it is written as one.
- **No green outside the sheet.** Not on the row, not on the invite card, not as
  type, not as a flat fill (`DESIGN.md:308-312`, `DESIGN.md:1170-1172`).
- **No second filled gold action.** Gold text lines may stack; a second gold
  pill on the same screen is a second decision the reader did not come to make
  (`DESIGN.md:1181-1183`).
- **No run the user did not start.** The one sanctioned exception is the
  announced, refusable re-check on the verdict page, and it is fenced by three
  conditions (branch `SyncSheet.swift:346-350` and the DESIGN.md entry the
  branch adds). A waiting screen that measures on its own when the count reaches
  zero would break that fence, and it would also fire while the user is still
  walking.
- **No by-ear slider while the speaker is settling.** Fact 8. This one is not a
  style rule, it is a correctness hole that exists in the shipped sheet today.
- **No claim that the phone knows where you are standing.** Fact 5. "Both are
  audible from here" is honest; "you're in a good spot" is not.
- **No screen that appears and vanishes.** Any waiting treatment must be absent
  entirely when `settleRemainingSeconds` is nil on open, not shown and then
  dismissed.

---

## My ranked pick

**1. Concept 1, with Concept 3's cheap tier on its third screen.** Concept 1's
screen 2 is Concept 2, so picking 1 gets the ear check for free, and it gets it
at the moment it is useful rather than as the whole design. Concept 3's cheap
tier costs one new view and no Mac work, and it puts an honest picture behind
the one screen that has to hold for 45 seconds. Together they answer both halves
of what Alec asked for: something to do with the seconds, and a reason the
seconds exist. They also fix an accuracy problem that has nothing to do with
waiting, which is that placement is what decides the measurement and the current
sheet states it in one paragraph nobody reads.

**2. Concept 2 alone**, if the appetite is small. It is the cheapest thing that
turns an empty screen into an activity, it reuses a command that already ships,
and it forces the by-ear lockout to be fixed, which needs fixing anyway.

**3. Concept 3 alone.** Beautiful and honest, and it answers "why" without
answering "what do I do". On a 45 second settle it is a picture the user watches
while doing nothing, which is the state Alec is complaining about, prettier.

**4. Concept 4.** Right idea for the person with four Bluetooth speakers, wrong
first move for the person with one. It belongs behind the invite card, after a
group is saved, and it should be built after somebody has watched a real person
get through one speaker.

---

## Three questions only Alec can answer

1. **Is the compensation scheme still live?** The handoff note's experiment,
   measuring early and correcting by the observed clock shift, would remove the
   wait entirely if the clock delta matches the acoustic delta
   (`handoff-2026-09-03-settle-window-adaptive.md`, "Alec's proposal"). If that
   experiment is going to happen soon and might pass, every concept here is
   designing a screen that would then have nothing to wait for. Is this work
   sized as permanent, or as the thing that carries the product until the
   experiment answers?

2. **May the sheet make a sound in the room the moment it opens?** Concepts 1
   and 2 both start the tick without a tap. The by-ear page already does this
   (`SyncSheet.swift:535-538`), so there is precedent, but that page is one the
   user chose to open for the express purpose of listening. Opening the sync
   sheet from a row glyph is not obviously the same consent, and the sound goes
   to speakers other people in the house can hear.

3. **On the second and later speakers, and on the second and later visits, how
   much of the walk-through should repeat?** Nothing here can decide that from
   state: the phone cannot know whether the user moved. Options are always show
   it, show it once per phone, or show it once per sheet and skip it for the
   chain. Each is defensible and they feel completely different by the third
   speaker.
