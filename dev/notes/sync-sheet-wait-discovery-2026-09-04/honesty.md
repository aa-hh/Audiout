# The waiting state, judged on honesty and feasibility

Read against the two unmerged branches as they stand. Mac branch = `claude/settle-window-adaptive`;
phone branch = `claude/settle-window-phone`. Every line number below is on the branch unless it says
"main".

## The one-sentence version

The adaptive branch already cuts the real wait for a well-behaved speaker from 60 seconds to about
11, but the **number on screen still starts at 60 for everyone**, because the detector cannot say
anything until it has 10 seconds of evidence. The screen is therefore promising a wait five times
longer than it will usually deliver. That is the honesty problem worth designing around, and it
points the opposite way from Alec's brief: the wait does not need filling, it needs not being
announced as a minute.

---

## 1. The truth table of the wait

### The machine, in four facts

1. `BTClockStability` watches the speaker's pacing clock once a second
   (`BTClockStability.swift:57`, `sampleIntervalSeconds = 1.0`). A step over 2 ms between two
   samples is a jump (`:49`). The clock is trusted after 10 seconds of jump-free advance
   (`:62`, `stableAfterSeconds = 10.0`).
2. The watcher runs only while the speaker's audio engine runs — started in `BTDeviceSink.startLocked`
   (`BTSyncedSink.swift:772`), cancelled in `stopLocked` (`:776`). A speaker that is connected but
   silent produces no samples at all. Each start builds a fresh detector
   (`BTClockStability.swift:177-181`), so the count begins again after every sink rebuild.
3. Wiring is live in the shipping backend: `OwnToneBackend.swift:978-995` hands each sink an observer
   that calls `BTAlignmentFreshness.noteClockOutcome`.
4. The number the phone gets is chosen here, and the order of the branches is the whole story
   (`BTAlignmentFreshness.swift:268-279`):

```swift
let stable = stableFor >= BTClockStability.stableAfterSeconds
let settleRemaining: Int?
if stable {
    settleRemaining = nil                                   // (a) detector says trusted
} else if let floor = Self.settleRemainingSeconds(lastConnectedAt: connected, now: now) {
    settleRemaining = floor                                 // (b) inside 60 s of link-up
} else if let lastAdvance,
          now.timeIntervalSince(lastAdvance) <= Self.advancingSampleMaxAgeSeconds {
    settleRemaining = Int((BTClockStability.stableAfterSeconds - stableFor).rounded(.up))  // (c)
} else {
    settleRemaining = nil                                   // (d) nothing left to say
}
```

Branch (a) is checked **before** the floor. So the 60 is not a minimum wait. It is a fallback for
"the Mac has no verdict yet."

### The table

Assume the ordinary case: music is playing on the speaker (the phone's own precondition demands it,
`SyncSheet.swift:299-304`), so the sink is running and samples flow from about one second after the
link comes up. `t` counts from link-up.

| Speaker | Real wait until the button goes live | What the phone shows while waiting | Is that number a countdown, an estimate, or a floor? |
|---|---|---|---|
| Sony-class (zero jumps; `dev/notes/bt-spike-findings-2026-08-07.md:59` — "ZERO jumps, +0.4 ppm over 118s") | **about 11 s.** First sample at t=1 is `.ignored` (`BTAlignmentFreshness.swift:187-189`), ten `.advanced` samples add a second each (`:196-198`), `stableFor` reaches 10 at t≈11, branch (a) fires and publishes `nil` (`:200`, `publish = !wasStable && isStableLocked(uid)`) | 60, 55, 50 … it disappears at about 50 | **A floor, and a wrong one.** The user is told "About 60 s to go" and gets 11. The published number never once described this speaker. |
| Sonos-class (42 s of jumps, `bt-spike-findings-2026-08-07.md:39-41`) | **about 53 s.** Every jump zeroes the count (`:202`), so the ten clean seconds start after the last jump at t≈42 | 60, 55 … it disappears at about 7 | **A floor that happens to be roughly right.** It is right by luck: 60 was picked as a margin over this one speaker's observed 42 s (`dev/notes/handoff-2026-09-03-settle-window-adaptive.md`, "60 is a rounded margin over a single observed 42 s worst case, from two speaker brands"). |
| Unknown speaker, jumps stop before t=50 | 10 s after the last jump | 60 counting down, ending early | A floor. |
| Unknown speaker, still jumping past t=50 | 10 s after the last jump, whenever that is | 60 down to ~0, **then the number jumps back up to 10** and repeats | Branch (b) hands over to branch (c) at t=60. Past that point the number is a real statement: "10 seconds from the last jump". Before that point it is a constant. |
| Any speaker, not playing | Branch (b) for the full 60 s, then branch (d) publishes `nil` | The phone shows "Play it first — the room has to hear both speakers." instead, because `macBlocker` outranks the settle line (`SyncSheet.swift:283-294`) | Moot. The countdown is hidden behind the other blocker. |
| Speaker already connected for hours, music started now | `stableFor` is whatever it was; if the sink never ran this session it is 0, the floor is expired, so branch (d) says `nil` — **button live at once** — until the first jump after audio starts re-publishes up to 10 (`:204-205`) | Nothing, then possibly 10 | The button can be live before the Mac has any evidence. |

### When the number can go UP

Three ways, all real:

- **The floor expires and the detector takes over** (`:272` hands to `:274-278`). The phone's local
  count reaches 0 at t=60; the Mac's next publish says 10.
- **A jump after t=60** re-publishes (`:204-205`, `publish = settleRemainingSeconds(...) == nil`).
- **A reconnect** resets everything and restarts the floor at 60 (`:102-116`).

The phone re-seeds from every snapshot, up or down, deliberately: "a Mac that publishes 10 again
after the count reached 3 means 10" (`SyncSheet.swift:44-47`, `reseedSettle()` at `:356-360`).
So the countdown running backwards is by design, and the user will see it.

### Does the 60 s floor survive, and for whom?

**As a wait: no, for any speaker whose audio is running.** Branch (a) beats it. A Sony waits about
11 seconds, not 60. The brief's worry — "as written, the floor means a Sony still waits up to 60 s"
— is not what the code does.

**As the number on screen: yes, for everyone, for the first ten seconds at least.** Nobody can
escape branch (b) before the detector has 10 seconds of evidence, so every speaker's wait opens with
"About 60 s to go" (`SyncSheet.swift:662-666`, rounded up to the next multiple of 5 by `:724`).

**As a wait, in one real case: yes.** `BTClockWatcher.isEnabled` is an environment switch
(`BTClockStability.swift:155-157`); with `AUDIOUT_BT_CLOCK_WATCH=0` the observer is `nil`
(`OwnToneBackend.swift:987-988`), no samples ever arrive, and every speaker falls back to the flat
60 seconds. The switch exists because a live test on 2026-09-03 hit judder and then silence on a
build carrying this file (`BTClockStability.swift:148-153`). If that switch ever gets set for a
shipping build, the same screen with the same copy delivers five times the wait and the phone has no
way to know.

**Not verified:** I have no evidence about how a third speaker brand behaves, and neither does the
codebase. Two speakers is the whole sample.

---

## 2. What the phone can honestly say, and what it cannot

### "Your speaker is still settling" — qualified yes

Source: `DeviceState.AlignmentState.settleRemainingSeconds`
(`audiout-shared/Sources/AudioutProtocol/CompanionSnapshot.swift:53`), computed at
`BTAlignmentFreshness.swift:268-279`.

The catch: a non-nil number means two different things and the phone cannot tell them apart. Inside
the first ten seconds it means **"the Mac has not looked long enough to say"**. Past that it means
**"the Mac has seen this clock jump"**. Only the second is "still settling". Saying "still settling"
during the first ten seconds is a guess dressed as an observation. Distinguishing them needs one new
boolean on the wire (has the detector actually seen a jump since link-up) — the store already knows,
it just does not publish it.

### "About 20 s" — no, not inside the floor

Inside branch (b) the number is a constant minus elapsed time. Its error against the truth is the
whole gap between 60 and the real settle time: **up to about 49 seconds too long** for a Sony, and it
can also be **too short** for a speaker that jumps past t=60, where it reaches zero and then goes back
up. Past the floor, branch (c)'s number is honest but narrow: it says "10 seconds from the last jump",
which is not a prediction of when the jumping stops. Nothing in the system predicts that.

The only honest framings available today are a ceiling ("up to a minute, usually much less") or no
number at all until branch (c) takes over.

### "Settled" — no. "Ready to measure" — yes

`nil` on the wire carries three unrelated facts: the detector is satisfied (`:270`), the floor expired
with no live samples (`:277-278`), and this device never connected in this session
(`:301-302`). The phone gets one value for all three. It can honestly say the button is live; it
cannot honestly say the speaker settled. The phone branch already gets this right — its announcement
is "Ready to measure the {name}." (`SyncSheet.swift:680-682`), not "Settled".

### A live stability picture — technically possible, editorially bad

The rate exists: the detector produces one verdict a second (`BTClockStability.swift:57`). Nothing of
it reaches the wire today; `noteClockOutcome` deliberately fires a rebuild only on the flips the phone
can already see (`BTAlignmentFreshness.swift:170-181`: first arrival at stable, a jump past the floor,
the "moved" line being crossed).

Cadence, if you wanted 1 Hz: snapshots are event-driven with a 50 ms trailing coalescer and no
periodic tick (`AudioutCore/Sources/AudioutApp/AppDelegate.swift:2535-2544`), and the server drops
identical snapshots. A full rebuild walks the whole device list plus the running-application list
(`AppDelegate.swift:2749-2784`) and the snapshot carries size ceilings
(`CompanionSnapshotBuilder.swift:18-28`). One rebuild a second per connected Bluetooth speaker is not
expensive on the socket — a snapshot is small and a local network link is not the constraint — but it
defeats the identical-snapshot suppression the whole design leans on, and it would rebuild the app
list once a second for a progress animation. A separate small message would be the right shape.
That is a new wire message, not an additive field.

The editorial objection is stronger than the technical one. A live jump trace during a wait shows the
user a graph of their speaker misbehaving, which they can do nothing about, on a screen whose job is
to get them to stand in the right place. It also breaks "no fake progress" from the other direction:
a real but meaningless picture is worse than an honest sentence.

### Whether the user is standing in the right place — no

Nothing measures the room before a run. The only quality number in the system is `confidence`, which
exists only after a recording is analysed (`AlignmentRunController.swift:266`, `analysis.confidence`)
and which the Mac records but does not gate on (`AppDelegate.swift:2657-2664` on the branch: "it does
not gate on it — it only records it").

It could be made possible: the phone has a microphone and the music is already playing, so a short
listen could report whether two distinct sources are audible from here. That is new work in ProbeKit
(which today holds only `ProbeAnalyzer.swift` and `SyncProbeCorrelator.swift`), it needs the microphone
permission before the user has agreed to a measurement, and the best it could ever say is "I can hear
more than one speaker", not "you are in the right place". **Unless** the answer is allowed to be that
weak, the honest answer is no.

### Which other speakers are untuned — yes

`SyncSheet.needsTuning(_:)` (`SyncSheet.swift:647-649`) reads the published status; `chainCandidate`
(`:638-642`) picks the first one; the row's word comes from
`DeviceRowView.alignmentWord(for:)` (`AudioutRemote/UI/Speakers/DeviceRowView.swift:768-776`, phone
branch adds the `Check timing again` case). All of it is Mac-published state the phone renders.

---

## 3. The measure-early path

### What actually happens when the user taps "Measure it now"

1. The line only appears while the Mac's preconditions are clear and the window is open
   (`SyncSheet.swift:250-260`). It calls `startRun()` directly.
2. **The Mac does not refuse it.** `startCompanionAlignmentProbe` checks the speaker is live, that two
   Bluetooth speakers can be told apart, and that nothing else is running
   (`NativeBackend.swift:10728-10780`). It never consults the settle window. The gate is entirely the
   phone's rendering.
3. The measurement is applied and **written to disk immediately** — `applyCompanionAlignmentMeasurement`
   at `:10874`, clamped at `:10890`, kept via `endBTWizardLatencyPreview(...keepMs:)` at `:10930`,
   which calls `noteAligned` at `:11237`.
4. `noteAligned` marks it: not stable plus (a window running or a clock already being sampled) means
   `measuredWhileSettling` (`BTAlignmentFreshness.swift:139-155`). That becomes a stale reason on the
   wire, the row says "Check timing again", and the sheet arms a re-check.
5. The verdict page shows the ordinary sentence — "{name} was trailing. **Fixed.**"
   (`SyncSheet.swift:629-634`) — with the forward line under it: "still settling, so this could move.
   Checking again in about N s." (`:684-687`).
6. The re-check runs by itself when the Mac says the speaker settled, only while the verdict page is
   on screen and the app is in front (`:346-348`), announced first (`:391`), refusable with "Not now"
   (`:587`), once per sheet (`:410-414`).

### What can go wrong

- **A wrong number is in force, audibly, in the meantime.** For a Sonos-class speaker the clock
  accumulated about −353 ms of shift across its settling window
  (`bt-spike-findings-2026-08-07.md:41`). A measurement at t=5 can be out by a large fraction of that.
  The user hears the result of a number the Mac itself has flagged as untrustworthy, for as long as it
  takes them to get back to the verdict page.
- **The verdict says "Fixed."** for a number the same screen expects to replace. Two sentences on one
  screen contradicting each other is the clearest honesty defect in the flow.
- **The re-check often will not run.** It needs the verdict page on screen, in the foreground, with the
  sheet still open. Close the sheet, background the app (`:170-174` sets `recheckDeclined`), tap
  "Adjust by ear", or walk away — and it never happens. This is precisely the user who tapped
  "Measure it now" because they were not willing to stand there.
- **Two runs' worth of chirps.** Each run is a lead-in (`ProbeSession.minimumLeadInSeconds = 1.0`),
  the sweeps, a 3 s tail (`pipelineTailSeconds = 3`), the analysis, then the Mac's apply. During a run
  every other Bluetooth speaker is held silent (`NativeBackend.swift:10785`,
  `setBTWizardTickActive(true, ...)` — "the participant hold (every other Bluetooth speaker silent for
  the run)"). So measure-early costs the room two interruptions instead of one, and the second one
  arrives with no tap behind it.
- **One automatic pass only** (`:410-414`). If the second run is also marked early, the number stays
  wrong and the screen falls back to an offer line.

### Position: bad as a default, fine as an escape hatch that has to be earned

Measure-early should not be the shape of this screen for a general consumer. Three reasons:

1. **After the adaptive branch the usual wait is about 11 seconds.** An escape hatch from 11 seconds is
   not worth a wrong stored latency, a self-contradicting verdict, and a doubled chirp.
2. **The failure is silent and audible at the same time.** The number is plausible, kept, and playing.
   The handoff note names exactly this: "worse than no calibration, because the number looks plausible
   and then gets stored" (`handoff-2026-09-03-settle-window-adaptive.md`).
3. **The correction is conditional on behaviour we have already established the user will not do.**

What I would keep: the line, but only once the wait has proven itself unusual. Show it when the Mac's
number is still counting past the point where it stops being a constant — that is, past the floor,
where branch (c) means the Mac has genuinely watched this speaker jump. Then the escape hatch appears
for the one speaker in the room that earned it, and never on the 11-second case.

And if it is tapped, the verdict must not say "Fixed." It should say what it is: a first reading,
which the phone will replace.

---

## 4. The honesty checklist

Apply to every concept. All must be yes.

1. Does every number on screen come from the Mac, with no phone-side arithmetic beyond ticking a
   published number down?
2. Is every number labelled as what it is — a ceiling ("up to"), a live count, or a measurement — and
   never a prediction the Mac cannot make?
3. Does the screen avoid showing "About 60 s" to a speaker that will be ready in 11? (Equivalently:
   does it survive the number turning out to be five times too long?)
4. Does the screen survive the number going **up**, including from nothing to ten?
5. Does the screen for an instant settle ever appear? (If the Mac publishes `nil` on the first
   snapshot, does the user see a wait screen flash?)
6. Is there exactly one gold action on the screen?
7. Does anything start without a tap, except the announced, refusable re-check on the verdict page?
8. Does any sentence claim a fix that another sentence on the same screen expects to replace?
9. Does the concept work when the Mac publishes `nil` for a reason other than "settled" — no samples,
   or a device that never connected this session?
10. Is every moving thing on screen driven by a real event, with nothing animating on a timer to
    suggest progress?
11. Does it still read correctly if the clock detector is switched off and every wait is a flat 60
    seconds?
12. Can a user who walks away, backgrounds the app, or closes the sheet end up with a stored number
    the Mac has marked as untrustworthy and no way to notice?

---

## 5. Two concepts

### Concept 1 — spend the wait on the walk, and never name a minute

The wait is usually about 11 seconds. The screen already has an 11-second job: getting the user from
wherever they are to where they listen. Done right, the wait costs nothing and needs no filling.

**The experience, step by step**

1. Row glyph tap opens the sheet on the placement page, exactly as today. Title and body unchanged —
   "Go to where you listen." is already the right sentence and it is the one thing that decides whether
   the measurement is any good.
2. The gold "Measure" button is present and not live. Under it, one cool-ink line, no number:
   *"Getting the {name} ready — walk over while it does."*
   No countdown, because during the first ten seconds the Mac's number is a constant, not an estimate.
3. If the wait passes the point where the number starts meaning something — the Mac's floor has expired
   and branch (c) is publishing — the line gains a number, and only then:
   *"The {name} is still settling. About 10 s from the last wobble."*
   That sentence is true; "About 55 s to go" at t=5 is not.
4. The moment the Mac says ready, the existing light haptic fires (`SyncSheet.swift:160-162`) and the
   button goes live. The user is standing in the right place with the phone in their hand.
5. "Measure it now" appears only in the case at step 3. On the common path it never renders at all.

**State and commands**

| Piece | Status |
|---|---|
| The settle number | EXISTS — `CompanionSnapshot.swift:53`, `BTAlignmentFreshness.swift:268-279` |
| Local tick-down and re-seed | EXISTS — `SyncSheet.swift:356-370` |
| Haptic on going live | EXISTS — `SyncSheet.swift:160-162` (phone branch), `DESIGN.md` "Ready" haptic |
| Screen kept awake | EXISTS — `SyncSheet.swift:167-169`, `:352-354` |
| Telling "no evidence yet" from "seen it jump" | **NEW (Mac + wire)** — the store knows (`stableForSecondsByUID`, `lastAdvanceAtByUID`); it needs one additive boolean on `AlignmentState`. Without it the phone cannot pick between the two sentences at steps 2 and 3 and has to guess from whether the number is above 10. |

**Rule conflicts:** none that I can see. One gold action. Nothing app-initiated. No number the Mac did
not send. The one judgement call is dropping the countdown entirely for the first stretch, which some
readers will call hiding information — the defence is that the information was wrong.

**On "tune while music plays, phone in your pocket, we tell you when it's done":** dead, and not
because of the sheet-must-be-open rule. Three independent walls, in order of hardness:

- The measurement needs the microphone and the app is not allowed to run in the background. There is no
  `UIBackgroundModes` key in `AudioutRemote/Info.plist` (it carries only the local-network strings, the
  launch screen and the font), so the app suspends on background or lock and the recording stops.
- Even with the background audio mode added, a phone in a pocket measures a pocket. The whole premise
  of the feature is that the microphone stands where the ears stand.
- "We tell you when it's done" needs a notification. `DESIGN.md` forbids it outright ("Nothing
  app-initiated: no notifications, no banner on a timer or on a connection"), and there is no
  notification code in the phone app at all — nothing matches `UNUserNotification` anywhere in
  `AudioutRemote/`.

The sheet-must-be-open rule is the fourth wall, not the first. What survives of the idea: the screen
stays awake so the phone can sit where the user is standing, which the branch already does.

**Effort:** phone S (copy and one threshold). Mac S (one field on the report). Wire S (one additive
boolean; per `audiout-shared/AGENTS.md` additive fields do not bump the protocol version, but both pins
ship together).

**Biggest risk:** the eleven-second figure is arithmetic from two constants and one speaker's trace,
not something anyone has watched happen. If real speakers routinely need 30 or 40 seconds, a screen
built on "the wait is short, don't mention it" is a screen with a silent dead patch in the middle. That
is a live test, not a design decision, and it should happen before this ships.

### Concept 2 — when the wait is genuinely long, spend it on the other speakers

For the rare speaker that is still jumping past the floor, the wait is real and the walk is over. Then
the screen has honest work: the rest of the room. This is Alec's own idea, scoped to the case that
earns it.

**The experience, step by step**

1. Everything in Concept 1 runs first. This only appears once the Mac's number has crossed into branch
   (c) — the Mac has watched this speaker jump and the wait has outlived the floor.
2. A plain divider and a cool-ink line under the footnote: *"While you wait — which other speakers do
   you want set up?"* Under it, the other Bluetooth speakers the Mac reports as untuned, each a plain
   row with a checkmark. No gold on any of them; the single gold action stays "Measure".
3. When the target settles, the button goes live as usual. The run happens as usual.
4. On the verdict page, the existing chain line (`SyncSheet.swift:552-567`) is driven by the list the
   user just ticked instead of by "the first untuned device in the snapshot" — "Next: {name}." Still a
   line the user taps, never a queue that advances itself.
5. Repeat. Each speaker gets the same placement page, but the user is already standing in the right
   place, so the second and third are quick.

**State and commands**

| Piece | Status |
|---|---|
| Which speakers are untuned | EXISTS — `SyncSheet.swift:647-649`, `:638-642`; `DeviceRowView.swift:768-776` |
| Bring a speaker into the mix | EXISTS — `MacSessionProtocol.swift:47`, `setDeviceSelected(id:selected:)` |
| One run at a time, enforced by the Mac | EXISTS — `NativeBackend.swift:10760-10779`, "This Mac is already measuring a speaker — finish that first." |
| Every other Bluetooth speaker held silent during a run | EXISTS — `NativeBackend.swift:10785` |
| Per-speaker settle number | EXISTS — `CompanionSnapshot.swift:53` |
| The user's list for this sitting | **NEW (phone)** — sheet-local state, nothing persisted |
| "Seen it jump" vs "no evidence yet" | **NEW (Mac + wire)** — same field as Concept 1; it is what decides when this section may appear at all |

**Rule conflicts**

- The list is a second decision on a decision screen. `DESIGN.md`'s "Do keep the gate to one junction
  and at most one gold action" is about the connect gate, but the spirit applies here. Resolved by
  keeping every row plain and cool: the only gold thing on the page stays "Measure".
- "Nothing app-initiated" binds hard. The sequence must never advance on its own. The announced
  re-check stays the only exception in the app.
- The invite card is offered once per speaker ever (`SyncInviteCard.swift:17`, backed by
  `UserDefaults`). If this list re-offers a speaker the card already burned, two doors disagree about
  whether a speaker has been asked about. Worth deciding explicitly.

**Effort:** phone M (a new section, list state, rewiring the chain line). Mac S (the one field).
Wire S.

**Biggest risk:** it designs the screen around its rarest state. Every speaker in the list carries its
own settle window, connected at its own moment, so the second speaker can stall exactly like the first
and the sequence turns into three waits instead of one. And bringing a speaker into the mix can start
its link-up, which restarts its own 60-second floor (`NativeBackend.swift:3846`, `:8414`) — so the act
of preparing the queue can lengthen the queue.

---

## 6. Ranked pick

**Concept 1 first, and on its own.** The wait for a well-behaved speaker is already about eleven
seconds on the branch. The problem Alec is reacting to is mostly a copy problem wearing a countdown:
the screen announces a minute, delivers eleven seconds, and explains neither. Fixing the sentence is
small, ships on the branches that already exist, and removes the reason for most of the machinery
anyone would otherwise build.

**Concept 2 second, gated on evidence.** It is the right answer for the long wait and it is Alec's own
instinct, but it should not be built until someone knows how often the long wait actually happens.
Today the whole distribution is two speakers.

**Measure-early: demote.** Keep it, move it behind the long-wait condition, and change the verdict
sentence so it stops saying "Fixed." for a number it plans to replace.

### Three questions only Alec can answer

1. **The measured wait, on real speakers.** After the branches land, how long does the button actually
   take to go live on each speaker you own, from link-up with music already playing? Everything above
   is arithmetic from two constants and one Sonos trace. If the answer is eleven seconds, Concept 1 is
   the whole job. If it is forty, the screen needs Concept 2 and the copy needs a number after all.
2. **Is a wrong stored latency acceptable for the minutes between an early measurement and its
   re-check?** The user hears it. It can be far out on exactly the speaker class this feature exists
   for. Answering "no" removes measure-early from the default path; answering "yes" means the verdict
   sentence has to stop claiming a fix.
3. **Should the Mac's own by-ear wizard gate on the same window?** Right now it does not — the same
   speaker can be measured instantly from the Mac and not for a minute from the phone
   (`handoff-2026-09-03-settle-window-adaptive.md`, "nothing in the Mac's own alignment wizard gates on
   connect age at all"). Whatever the phone screen becomes, two devices disagreeing about whether a
   speaker is ready is a bug the user will eventually see.

---

## Things I could not verify

- Whether a speaker that is already connected but idle re-anchors its pacing clock when audio starts.
  The spike measured from connect only. This decides how the "connected for hours, music starts now"
  row of the table really behaves.
- Whether `AUDIOUT_BT_CLOCK_WATCH=0` has ever been needed on a shipping build, and so whether the flat
  60-second fallback is a live possibility or a diagnostic that will be deleted.
- Any speaker's behaviour other than the Sonos Move 2 and the Sony WH-1000XM3.
- Exact snapshot sizes on the wire, so the "1 Hz is cheap on the socket" claim is reasoning from the
  size ceilings in `CompanionSnapshotBuilder.swift:18-28`, not from a measurement.
