# Sync sheet: shape brief

*2026-09-05. Impeccable `shape` with `animate`, `delight` and `clarify`, on the iPhone app's sync sheet (`AudioutRemote/UI/Sync/SyncSheet.swift`, `Model/AlignmentRunController.swift`, `UI/Sync/SyncInviteCard.swift`). Mode: Operate. Inputs: PLAN-REMOTE-RELEASE.md decisions D7 to D10 and tasks T7, T8; the Mac ADR 0001 (remembered offset on reconnect); the shared ADR 0001 (quieter sweeps); the glossary `audiout-shared/CONTEXT.md`; DESIGN.md's "The sync surfaces" and "Decision Record"; the research note `bt-latency-stability-research-2026-09-05.md`. Every line number below was read in source this session. No interview was possible; anything not settled by the plan or the ADRs is marked "Assumption" inline or listed under "Open decisions".*

## Brief

**Job and audience.** A paying Mac owner standing in the room with a Bluetooth speaker that plays late. They opened the sheet from a speaker row, from the invite card after saving a scene, or from the Mac's own invite. Phone in one hand, music already playing, patience short. Success is one thing: after the sheet, the two speakers sound like one, and the phone told them so in words they can check with their ears.

**Outcome and proof.** The proof is audible, not numeric. The verdict says which speaker was late, whether that was enough to hear, and that they are in step now, then plays the before and after without being asked. The millisecond count stays behind Details. The words are grounded in the research note's audibility bands: under 10 ms the pair is still one sound; 10 to 40 ms is enough to hear on transients; 40 ms and over is an echo. The Mac ADR uses the same bands (replace at 10, tell the user at 40).

**Direction.** The existing sheet's thesis holds: one act per page, every page advancing on the user's own tap, results rather than errors, no red, green only inside the sheet and only as the site's "Movie night" ramp. What changes is the shape of the wait. The wait is no longer a gate. Measure goes live the moment both speakers play; a reading taken before the Mac calls the speaker steady is applied at once and called a first pass; and the sheet never starts a run on its own. The one automatic run the app had (the silent re-check on the verdict page) is replaced by a banner that asks for a tap. The pages before Measure fall from five to four, and a returning user with a granted microphone sees two.

**Scope and boundaries.** Production copy and behaviour for the sheet's seven pages, the device row's timing label, and the invite card's trigger. Untouched: the measurement itself (`ProbeSession`, ProbeKit), the wire protocol beyond what T2 adds, the Mac's own "Align by ear" wizard, the Speakers, Apps and Groups tabs beyond the row label, and the five sentences the Mac owns (below). Anti-goals: no countdown, no percentage, no number in a headline, no run without a tap, no second gold button on one page, no new hue.

**States and ranges.** Target and reference names run from "Kitchen" to a 30-character Sonos name; every sentence below was written to survive a long name at the largest non-accessibility Dynamic Type size, wrapping to three lines. Offsets from a real room: 3 to 120 ms; the demo's canned run reports 96 ms. Clock states from the Mac: `unknown`, `settling`, `steady`, or absent on an older Mac (treated as steady). Stale reasons: `reconnected`, `measuredWhileSettling`, `moved`. The applied-offset source T2 adds: measured, first pass, from last time.

**Constraints.** iOS 18, iPhone only, SwiftUI, Dynamic Type throughout, 44 pt targets, Reduce Motion honoured on every moving thing, VoiceOver announcement for every state that changes without a tap. Verified on the physical iPhone 15 Pro only. The sweeps are the shared package's business (6 dB down, 80 ms fades, one tag pinned in both apps); the phone's copy stops calling them chirps.

## The flow, page by page

Page order and skipping are decided by `SyncSheet.firstPreRunPage(blocked:micUndetermined:walked:)` (`SyncSheet.swift:126`). Today it returns `.playing`, `.microphone`, `.walk` or `.placement`. The new version drops `.walk` and `.listen` for one `.listen` page: silent speaker first, then the microphone only while undecided, then the listen page unless the user has already walked this sheet, then Hold still. A page whose condition is already met is never shown; that logic exists and is tested (`AlignmentRunControllerTests.swift:158`). The only new skip is the page that no longer exists.

### A. Both speakers playing

Shown only while the Mac's precondition is unmet (`macBlocker` non-nil). Copy unchanged:

- Title: "Both speakers need to be playing."
- Body, no reference: "Nothing else is playing to compare the {target} against. Play something on another speaker, or on your Mac."
- Body, target silent and startable: "The {target} isn't playing yet. The room has to hear it and the {reference} together."
- Body, Main Audio on a scene the target is not in: "Main Audio is playing to a scene the {target} isn't in. Add it to that scene, or point Main Audio back at your speakers."
- Body once both play: "Both are playing."
- Gold: "Play the {target}" while startable; "Continue" once both play.

Behaviour unchanged: the page waits on the Mac's word and never advances itself. "Continue" goes to the next unmet page.

### B. The microphone

Shown only while permission is undetermined. Copy unchanged: "Audiout needs to hear the room." / "It listens for two quick sweeps from your speakers, wherever this iPhone is standing." / gold "Allow the microphone". A refusal swaps in the refusal page under it, as today.

### C. Where you listen (the walk and the listen, merged)

Replaces pages C and D (`SyncSheet.swift:373-411`). Shown once per sheet; the chain to the next speaker skips it. The Mac's clicks start on appear, exactly as the old listen page did (`setAlignmentTick(active: true)`), and keep going through Hold still until Measure is tapped.

- Title: "Go to where you listen."
- Body, clicks running: "Not next to a speaker. Where you actually sit. The {target} and the {reference} are each clicking. When both clicks reach you, you're there."
- Body, clicks refused by the Mac: "Not next to a speaker. Where you actually sit. You should hear music from both the {target} and the {reference}."
- Body after "Only one", clicks running: "Move somewhere both reach you, or turn the quiet one up. The clicks keep going."
- Body after "Only one", clicks refused: "Move somewhere both reach you, or turn the quiet one up. Then answer again."
- Gold: "I hear both". Sets `walkedThisSheet`, goes to Hold still.
- Text button, `goldText`, same row: "Only one". Flips the body; nothing advances.

Why the gold moved: the old listen page used two neutral chips because "Both" and "Only one" were equal answers to a question. On the merged page the question is folded into the instruction, and "I hear both" is the completion of the act the page asked for, which is what gold marks everywhere else in the sheet. "Only one" is a problem report, not an equal answer.

Assumption: "Adjust by ear" leaves this page. It sat on the old walk page; it stays on Hold still, the verdict and every refusal, one tap away. T10 already flags the sheet's three-button rows as a defect.

### D. Hold still

The last page before the run, and the only one with Measure on it (`SyncSheet.swift:445-483`).

- Title: "Hold still."
- Body: "You'll hear two quick sweeps over the music. Stay quiet while they play."
- Gold: "Measure". Live whenever `macBlocker` is nil. The clock verdict no longer gates it (`ctaReady` at `:544` drops `!waitingToSettle`; `clockReady` at `:532-539` then only decides the footnote and the by-ear lock at `:1017-1020`).
- Text button: "Adjust by ear".
- The "Measure it now" escape (`:456-466`) goes: Measure is the escape now.

The footnote under the body, by precedence (`placementFootnote`, `:909`):

1. A Mac precondition: "Needs another speaker playing." or "Play it first: the room has to hear both speakers." (unchanged; Measure is not live).
2. Clock `unknown` or `settling`: "The {target} isn't steady yet, so this will be a first pass. You can check it again once it is." One line for both states: the Mac's evidence differs, the consequence for the user does not. Replaces "Getting the {target} ready." and "The {target} is still settling after connecting. Hold on."
3. Source is from last time (steady): "The {target} is on last time's timing. This checks whether it still fits." Replaces the reconnect theory line ("picks a fresh delay every time it reconnects, so the old number no longer fits"), which is no longer what the Mac does.
4. Source is first pass (steady, sheet reopened): "The last measurement was a first pass, taken while the {target} was still settling. Measure again from where you listen."
5. Stale reason `moved`: "It's moved since you measured. Measure again from where you listen." (unchanged)
6. Older Mac, stale reason `reconnected` with no source field: "The {target} picks a fresh delay every time it reconnects, so the old number no longer fits." (kept only for a Mac that predates T14)

VoiceOver: Measure's spoken value while not live is the precondition line only; `readyValue` for `settling` and `unknown` goes. The "Ready" haptic and "Ready to measure the {target}." announcement fire only if a precondition clears while this page is showing.

### E. The run

`SyncSheet.swift:657-698`; phases at `AlignmentRunController.swift:33-52`. The emitter field in the green ramp, one phase word, Cancel. Phase words:

- `hearingRoom`: "Hearing the room"
- `chirping`: "Playing the sweeps" (was "Chirping". The page before it promised "two quick sweeps"; one word per thing.)
- `lettingItLand`: "Letting it land"
- `measuring`: "Measuring"

Motion is under "Motion and haptics". Cancel behaviour unchanged for a tapped run; there are no automatic runs left, so the automatic branch at `:682-687` goes.

### F. The verdict

`SyncSheet.swift:713-760`. Order on the page: rings, headline, [Hear it | Adjust by ear], the re-check banner when there is one, the notice line, Details, the chain line.

**Headline.** One sentence, `.title3` semibold, from three inputs: the measured offset the Mac reported back, how far the Mac actually moved the speaker (`correctedMs`), and what this reading replaces. Direction words stay "trailing" and "ahead of" (the invite card already says "will trail"). Size words come from the audibility bands.

Measured, steady, first measurement or replacing nothing:

| Offset | Mac moved it | Sentence |
|---|---|---|
| under 10 ms | no | "The {target} was already in step with the {reference}." |
| under 10 ms | yes | "The {target} was barely {trailing / ahead of} the {reference}, too little to hear. Now in step." |
| 10 to 40 ms | yes | "The {target} was {trailing / ahead of} the {reference}, enough to hear. Now in step." |
| 10 to 40 ms | no | "The {target} was {trailing / ahead of} the {reference}, enough to hear. Your Mac couldn't change it." |
| 40 ms and over | yes | "The {target} was {trailing / ahead of} the {reference} by enough to echo. Now in step." |
| 40 ms and over | no | "The {target} was {trailing / ahead of} the {reference} by enough to echo. Your Mac couldn't change it." |

First pass (the Mac marks the reading as taken while the speaker was not steady; today the phone decides this from the clock state at run start, `runIsEarly`, and the Mac's rule at `BTAlignmentFreshness.swift:201` is the same test at apply time):

| Offset | Mac moved it | Sentence |
|---|---|---|
| under 10 ms | either | "First pass: the {target} was already in step with the {reference}." |
| 10 to 40 ms | yes | "First pass: the {target} was {trailing / ahead of} the {reference}, enough to hear. In step for now." |
| 40 ms and over | yes | "First pass: the {target} was {trailing / ahead of} the {reference} by enough to echo. In step for now." |
| 10 ms and over | no | "First pass: the {target} was {trailing / ahead of} the {reference}{, enough to hear / by enough to echo}. Your Mac couldn't change it." |

A first pass never says "Fixed." or "Now in step." The banner under it says what happens next.

Re-check (this reading replaces a first pass, last time's timing, or a measurement the Mac saw move). The Mac keeps the old value under 10 ms and replaces it from 10 (Mac ADR 0001), so "Still in step" is also "nothing changed":

| Offset | Replacing | Sentence |
|---|---|---|
| under 10 ms | any | "Still in step." |
| 10 to 40 ms | first pass | "It had drifted since the first pass, enough to hear. Fixed." |
| 10 to 40 ms | last time | "It had drifted since last time, enough to hear. Fixed." |
| 10 to 40 ms | moved | "It had drifted since you measured, enough to hear. Fixed." |
| 40 ms and over | any of the three | "It had drifted since {the first pass / last time / you measured} by enough to echo. Fixed." |
| 10 ms and over | any, Mac could not move it | same sentence, ending "Your Mac couldn't change it." |

The 40 ms row is the ADR's "over 40 ms the user is told". "Your Mac couldn't change it." replaces the two spellings in the code today ("The Mac couldn't change it." at `:876`, "Your Mac couldn't change it." at `:979` and `:1011`); one spelling.

**Hear it.** Gold "Hear it", unchanged label. The before and after now plays on arrival without a tap (`playAlignmentDemo` on `.applied`, per D7 and T7). "Hear it" replays it. While the Mac's demo is playing (4 s: 2 s at the old value, 2 s at the new, `NativeBackend.companionDemoLegSeconds`) the button is drawn but not live, so a second tap cannot earn the Mac's refusal line ("This Mac is already measuring a speaker. Finish that first."). Nothing plays on a refusal page.

**The re-check banner.** Replaces the silent second run (`recheckDue` `:578`, `startRecheckWhenDue` `:588`, `startRun(automatic:)` `:600`) and the follow-up lines (`:823-860`). One shape, the invite card's: a `panel` fill, `containerEdge` half-point stroke, row radius, 12 pt padding, one footnote sentence in `label2`, and, when live, a row of two text buttons under it. Its states, in order of arrival:

1. First pass, speaker not yet steady: "The {target} is still settling, so this may move. Keep this iPhone where you listen." Sentence in `labelCool2`, no buttons. The screen stays awake (existing `keepAwake`).
2. The Mac says steady: the sentence becomes "The {target} is steady now. Check it again from here?" in `label2`, and the buttons appear: "Check again" in `goldText`, "Not now" in `labelCool`. This is the moment the "Ready" haptic fires and VoiceOver hears "Ready to check the {target} again." (existing). Nothing starts.
3. Stale reason `moved` while the verdict is on screen: "It's moved since you measured. Check again from here?" with the same two buttons.
4. "Check again" goes straight to the run page (the user is where they listen; no walk, no Hold still). "Not now" removes the banner for the rest of this sheet; the row keeps its word and its glyph as the standing offer.
5. After a re-check verdict the banner is gone unless the Mac marks the new reading too, in which case state 1 returns. It costs a tap each time, so a clock that never holds cannot loop.

Never automatic: no timer, no `.task(id: recheckDue)`, no retry after a Mac refusal, no run while backgrounded. The `recheckDeclined`, `recheckRetried`, `recheckDue`, `runIsAutomatic` state and `startRecheckWhenDue()` go.

**Details.** Unchanged: a disclosure, `footnote`, `goldText` tint, holding the unsigned millisecond count in the readout face.

**Chain line.** Unchanged shape; one new sentence for a speaker on last time's timing: "{name} is on last time's timing. Check it next?" The others stay: "{name} needs a check too. Check it next?" and "{name} isn't set either. Tune it next?"

### G. Adjust by ear

`SyncSheet.swift:1101-1250`. The clicks run the whole time the page is open (on at appear, off at disappear, both already in code at `:1188-1193`) and stop when the sheet goes (`:214`). The "Stop the ticks" / "Start the ticks" toggle (`:1147-1155`) goes: D9 says the click runs throughout, and a page whose whole instrument is the click has no reason to offer silence. One haptic per nudge, the detent family at intensity 0.52, already at `:1194-1195`. Copy unchanged: "Listen for one click, not two." and the slide-well-over-then-back body. The slider stays drawn and inert while the speaker is not steady, with its line "The {target} is still settling after connecting. The slider unlocks when it's steady." (see Open decisions). Revert and "Clear this speaker's tuning" unchanged.

### H. Refusal

`SyncSheet.swift:1037-1089` and the refusal copy at `AlignmentRunController.swift:63-108`. Unchanged. A refusal only ever follows a run the user tapped for, which was already the rule and is now the only case.

### The speaker row

`DeviceRowView.alignmentWord(for:)` (`DeviceRowView.swift:768`). The row renders the Mac's status and never computes it. The label is the word in the state slot, `labelCool2`, with the `tuningfork` glyph in `goldText` beside mute; both vanish once the source is a steady measurement.

| Mac publishes | Row word | Glyph |
|---|---|---|
| status `notSet` | "Timing not set" | yes |
| source first pass (status `stale`, reason `measuredWhileSettling`), clock not steady | "First pass" | yes |
| source first pass, clock `steady` | "First pass. Check again" | yes |
| source from last time (T2) | "Timing from last time" | yes |
| status `stale`, reason `moved` | "Check timing again" | yes |
| source measured, status `tuned` | no word | no |
| older Mac: status `stale`, reason `reconnected`, no source | "Reconnected, timing not set" | yes |

VoiceOver reads the same word as part of the row's value (`spokenValue`, `:211`). The long-press "Tune…" item stays on every Bluetooth row.

### The invite card

`SyncInviteCard.swift`. Trigger unchanged (a scene saved or Main Audio pointed at one; once per speaker ever). Its sentence, "{name} will trail the {reference} until it's tuned. Takes seconds.", is true for `notSet` and for `moved`, and false for a speaker running last time's timing, which usually lands within tens of milliseconds of right. `SyncSheet.needsTuning` must not count a from-last-time speaker; see Open decisions, T2.

## Motion and haptics

Motion thesis: the sheet has one authored sequence, the verdict, and one piece of live feedback, the field moving while sound is in the room. Everything else is the app's one tempo (`.spring(duration: 0.25)`, no bounce) or a quarter-second fade. D8: the emitter field is otherwise calm.

**The run page's field.** Two emitters in the "Movie night" ramp, as today. The field's rings travel only while sound is in the room (`still: !phase.isSounding`, unchanged). New: a brightness envelope on the whole field. At rest, during "Hearing the room" and "Measuring", the field sits dim, at about 45% opacity. On `.started` (the Mac says the sweeps entered the feed) it rises to full over 0.2 s; on `.finished` it falls back over 0.5 s, the way the rings themselves die crossing the room. Rise faster than fall. Mechanism: `.opacity` on the `EmitterField` view, animated on the phase; no shader change and no new knob. The phone learns two moments from the Mac and no more (it is never told the stagger between the DOWN and UP sweeps), so the swell is one rise and one fall, not two beats. Razor ceiling: if the Mac ever publishes the stagger, the envelope can become two beats one second long each (`ProbeAnalyzer.sweepSeconds`). Driving it off the microphone level was considered and dropped: the sweeps are now 6 dB under the music, so a level meter would pulse with the song, not the sweeps.

Reduce Motion: the field is one still frame (existing). The opacity envelope still runs, because a brightness change with nothing travelling is the one piece of feedback that says the room is hearing the sweeps. No ring travel, no phase-word animation.

**The verdict.** Sequence, from the moment `.applied` arrives and the page appears:

- 0.0 s: the headline is on screen (no entrance animation; the words are the point). The "Measurement lands" haptic fires. The before-and-after is requested from the Mac. The rings draw apart (the existing 26 pt offset) and hold still.
- 2.0 s (the Mac's swap from the old value to the new; `companionDemoLegSeconds`, hand-copied on the phone with a comment naming the Mac constant, the same rule `ProbeAnalyzer.sweepSeconds` lives under): the rings converge over 0.6 s ease-out (the existing `RegisterRings` curve) and are still from then on. Nothing else moves on the page afterwards.
- 4.0 s: the Mac's demo ends; "Hear it" goes live (the quarter-second fade `GoldCTA` already has).
- On a Mac refusal of the demo, or in the demo session until T6 lands, the rings converge at once (0.6 s from page arrival), as today.
- "Hear it" replays the sound and nothing moves; the rings are a picture of the result, drawn once.

Reduce Motion: rings drawn converged from the first frame (existing). The haptic and the sound are unchanged; neither is motion.

**Page changes.** `.spring(duration: 0.25)` between pre-run pages (existing). The re-check banner's sentence change and button row appearing use the same spring; under Reduce Motion, a crossfade.

**Haptics.** The sheet's four events, each keyed to a fact from the Mac, never to a tap:

| Event | Feedback | Trigger |
|---|---|---|
| Measurement lands (new, D8) | `.impact(weight: .heavy)`, full intensity, once per verdict (`verdictCount`) | the Mac's `.applied` event; never on a refusal |
| Ready (existing, retargeted) | `.impact(weight: .light)` | a precondition clears while Hold still is showing, or the re-check banner goes live on the Mac's `steady` |
| By-ear nudge (existing) | `.impact(weight: .light, intensity: 0.52)`, the fader detent | each 5 ms detent crossed on the by-ear slider |
| The clicks stopping (not a haptic) | the Mac's clicks end | the Measure tap |

`.impact(weight: .heavy)` rather than `.success`: every other impact in the app is light, so one heavy single strike is unmistakable, and a single strike matches "lands". Assumption; the alternative is the system `.success` pattern.

**VoiceOver.** Announcements post for every change without a tap: the banner going live ("Ready to check the {target} again."), a re-check verdict (the headline itself), Measure going live on a cleared precondition ("Ready to measure the {target}."). The run page's phase word is its accessibility label. The rings are hidden from VoiceOver.

**Screen awake.** Unchanged rule: only this sheet, while mid-run, while Hold still waits on a precondition, or while the re-check banner is waiting for steady; cleared unconditionally on disappear.

## Design system delta

Exact text for `DESIGN.md`. Line numbers are today's.

### Frontmatter, `components:`

Add after `status-banner`:

```
  recheck-banner:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.label2}"
    rounded: "{rounded.row}"
    padding: "12pt"
```

### Components: amend "Device Row", the Tune bullet (`:622-628`)

Replace the sentence beginning "The row's sub-label carries the same fact" with:

> The row's sub-label carries the same fact in one of five words the Mac publishes and the phone only renders: "Timing not set", "First pass" (and "First pass. Check again" once the Mac calls the speaker steady), "Timing from last time", "Check timing again", or, from a Mac older than the remembered-offset change, "Reconnected, timing not set". Only on an available, unmuted row that is not connecting and has not failed. The word and the glyph both go the moment the Mac reports a steady measurement.

### Components: add after "ToastBanner" (`:977`)

```
### Re-check banner (sync sheet)
The one offer in the app that follows from a fact the speaker produced rather
than from the user's own action, and it asks for a tap every time. Shown only
on the sync sheet's verdict page, under Hear it. The invite card's shape:
`panel` fill, `containerEdge` 0.5pt stroke, row radius, 12pt padding, one
`.footnote` sentence, and, once the Mac calls the speaker steady, a row of two
text buttons: "Check again" in `goldText`, "Not now" in `labelCool`. Before
that moment the sentence sits in `labelCool2` with no buttons. "Check again"
goes straight to the run page; "Not now" removes the banner for the rest of
the sheet. It never starts anything: no timer, no retry, no run while
backgrounded. The "Ready" haptic and a VoiceOver announcement mark the
sentence changing.
```

### Haptics (`:978-1007`)

Change "Five feedback events" to "Seven feedback events". Replace the "Ready" entry with:

```
- **Ready:** a light `.impact` when the sync sheet's Measure button goes live
  because a precondition cleared, or when the verdict page's re-check banner
  goes live on the Mac calling the speaker steady. Never on a tap and never
  on first appear. Measure no longer waits on the clock verdict, so the
  banner is where this event now usually lands.
- **Measurement lands:** one `.impact(weight: .heavy)` at full intensity when
  the Mac's `alignmentApplied` arrives and the verdict page opens. Never on a
  refusal. The only heavy impact in the app; everything else is light, so
  this one is unmistakable.
- **By-ear nudge:** the fader detent (`.impact(weight: .light, intensity:
  0.52)`) once per 5 ms step crossed on the by-ear slider, keyed to a count so
  a fast finger that crosses three steps feels three.
```

Delete the trailing sentence "The sync sheet's by-ear fine-tune reuses the detent family for its 5ms steps; see 'The sync surfaces'." (now an entry).

### New section, after Haptics

```
## Motion

One tempo, and four named exceptions. Every animation in the app is one of
these; a fifth curve is a defect.

- **App tempo:** `.spring(duration: 0.25)`, no bounce. Row travel, section
  collapse, Apps re-sort, the sync sheet's page changes, the re-check
  banner's change of state.
- **Gate tempo:** `.snappy(duration: 0.35)` between the Connect gate's
  junctions (`ConnectGateView.motionCurve`); `.easeInOut(0.25)` under Reduce
  Motion.
- **Going live:** `.easeOut(duration: 0.25)` on a control's fill warming
  (`GoldCTA`) or a follow-up line changing; at once under Reduce Motion.
- **Ring settle:** `.easeOut(duration: 0.6)` for the verdict's two rings
  arriving in register, started at the before-and-after's swap (2 s after the
  demo is requested, `companionDemoLegSeconds` on the Mac) or at once if the
  Mac declined to play it. Still from then on.
- **Field swell:** the run page's emitter field sits at 45% opacity and rises
  to full over 0.2 s when the Mac reports the sweeps in the feed, falling
  back over 0.5 s when it reports them done. Rise faster than fall. This
  envelope runs under Reduce Motion; the field's ring travel does not.

Reduce Motion means fewer and gentler animations, not none: a crossfade or a
brightness change may stand in for travel, and a haptic or a sound is not
motion. Nothing loops while hidden.
```

### Corrections to "The sync surfaces" (`:1113-1189`)

Replace the row bullet's list of words with the five in the Device Row amendment above, and change "the Mac applied a measurement before the speaker had settled, or has seen it move by about 10 ms since" to name the three cases separately (first pass; from last time; moved 10 ms or more, summed).

Replace the sheet bullet's opening, "Five screens before a measurement", and its list with:

> Four screens before a measurement, one act each, every one advancing on the user's own tap and every one skipped when its condition is already met: both speakers playing (only while one is silent), the microphone (only while undecided), where you listen (the walk and the click check on one page; the Mac's clicks start on appear and run until Measure is tapped; gold "I hear both", text "Only one"), and Hold still, which carries Measure and Adjust by ear. Where-you-listen runs once per sheet; the chain to the next speaker opens on Hold still. Measure is live whenever both speakers play. The clock verdict gates nothing; it changes what the footnote says and what the verdict is called.

Replace the two paragraphs beginning "**No number appears while a speaker settles.**" and "A measurement taken while the speaker was still settling" with:

> **No number appears while a speaker settles, and no wait is imposed.** The footnote under Hold still says, on `unknown` or `settling`, that the reading will be a first pass and can be checked again once the speaker is steady; nothing on `steady`. A first pass is applied at once and its verdict opens "First pass:" and never says "Fixed." or "Now in step."; the by-ear slider stays inert until `steady`, one line above it saying why, because the Mac stores whatever trim a tick session was left holding.
>
> **Nothing runs without a tap.** Under a first-pass verdict the re-check banner waits, saying the speaker is still settling and to keep this iPhone where it is; when the Mac calls the speaker steady the banner goes live with "Check again" and "Not now". "Check again" goes straight to the run page. A speaker the Mac has seen move since its measurement gets the same banner. The automatic re-check is gone (Alec, 2026-09-05, D10: never automatic).
>
> **The verdict speaks in audibility, not milliseconds.** Under 10 ms the pair was one sound; 10 to 40 ms was enough to hear; 40 ms and over was an echo. The count stays behind Details. The before-and-after plays on arrival and "Hear it" replays it.

Add to the Decision Record, dated 2026-09-05: the four D7 to D10 rulings in one paragraph (sound only from the speakers being synced and the before-and-after unprompted; the four haptics and the three motions; measure as soon as both play with a labelled first pass; remembered timing on reconnect with a tapped re-check). Point at `docs/plans/PLAN-REMOTE-RELEASE.md` and the two ADRs rather than restating them.

### Do's and Don'ts

No change. The keep-awake bullet still describes the three conditions correctly; "a re-check pending" now means the banner waiting for steady.

## Copy inventory

Every string that is new or changes, with the function or view it lives in, so the String Catalog (T12) and the tests (`AlignmentRunControllerTests.swift:130-310`) can be updated in one pass. Unchanged strings are not listed.

| Where | Was | Becomes |
|---|---|---|
| merged page title | "Take this iPhone to where you listen." | "Go to where you listen." |
| merged page body | "Not next to a speaker. Where you actually sit." + separate listen page | "Not next to a speaker. Where you actually sit. The {target} and the {reference} are each clicking. When both clicks reach you, you're there." |
| merged page, clicks refused | "You should hear music from both the {target} and the {reference}." | "Not next to a speaker. Where you actually sit. You should hear music from both the {target} and the {reference}." |
| merged page gold | "I'm there" / chip "Both" | "I hear both" |
| merged page text button | chip "Only one" | "Only one" |
| `gettingReadyLine`, `settlingLine` | "Getting the {target} ready." / "The {target} is still settling after connecting. Hold on." | one line: "The {target} isn't steady yet, so this will be a first pass. You can check it again once it is." |
| `reconnectedLine` (Mac with a source field) | "The {target} picks a fresh delay every time it reconnects, so the old number no longer fits." | "The {target} is on last time's timing. This checks whether it still fits." |
| `reopenAfterEarlyLine` | "The last measurement was taken while the {target} was still settling. Measure again from where you listen." | "The last measurement was a first pass, taken while the {target} was still settling. Measure again from where you listen." |
| "Measure it now", `measureNowHint` | present | removed |
| `readyValue` for `settling`, `unknown` | "Not yet. The {target} is still settling." / "Getting the {target} ready." | removed (Measure is live) |
| `Phase.chirping.label` | "Chirping" | "Playing the sweeps" |
| `verdictLine` | "{target} is in step." / "{target} was trailing. Fixed." / "... The Mac couldn't change it." | the six-row measured table above |
| `earlyVerdictLine` | "First reading: the {target} was trailing. Your Mac moved it; this iPhone will check again once it's steady." | the first-pass table above |
| `recheckVerdictLine` | "Still in step." / "It had drifted 40 ms. Fixed." | the re-check table above |
| `forwardLine` | "The {target} is still settling, so this could move. This iPhone will check again once it's steady. Keep it where it is." | "The {target} is still settling, so this may move. Keep this iPhone where you listen." |
| `offerLine`, `offerWaitingLine` | "Check again" / "Check again once it's steady." | banner sentence "The {target} is steady now. Check it again from here?" with buttons "Check again", "Not now" |
| `movedOfferLine` | "It's moved since you measured. Check again now." | "It's moved since you measured. Check again from here?" with the same buttons |
| `recheckAnnouncement` | "Checking the {target} again." | removed (no automatic run to announce) |
| `chainLine`, from last time | none | "{name} is on last time's timing. Check it next?" |
| by-ear toggle | "Stop the ticks" / "Start the ticks" | removed |
| `alignmentWord` | "Reconnected, timing not set" for every stale reconnect | "Timing from last time", "First pass", "First pass. Check again"; the old word only for an older Mac |

Voice check against `BRAND-VOICE.md` and the copy-review skill: every line is plain, sentence case, names the speaker, says what happens next, uses "this iPhone" and "your Mac", and carries no number in a headline. Warmth is one clause at most ("you're there").

**The five sentences the Mac owns do not change.** `MacCopyTripwireTests.swift:26-33` pins them and this brief touches none: "Speakers unreachable. Playing on your Mac. Will resume automatically." / "Your Mac's system output is also set to AirPlay. Audio may play twice. Switch it back to avoid an echo." / "A scene needs at least one speaker." / "Unknown speaker." / "Unknown scene." The sheet also shows the Mac's refusal reasons verbatim under Details; those are the Mac's too and are not rewritten here.

## Open decisions

The builder must not settle these alone.

1. **T2's wire shape for the source, and what status rides with it.** The row, `needsTuning`, the invite card and the chain line all key off `status`. Recommendation: a from-last-time speaker publishes `status: "tuned"` with `source: "fromLastTime"`, so nothing that means "untuned" fires for a speaker that has a working number; a first pass publishes `status: "stale"`, `staleReason: "measuredWhileSettling"`, `source: "firstPass"`, so today's row and chain logic keep working. Needs Alec's yes before T2 is tagged.
2. **Where the phone learns "first pass".** The verdict needs it the moment `.applied` arrives, and the snapshot carrying the Mac's mark can land after it. Today the phone decides from the clock state at run start, which is the Mac's own test (`BTAlignmentFreshness.swift:201`) five seconds earlier. Recommendation: T2 puts the source on the `alignmentApplied` message so the phone never guesses; fallback is the phone's existing guess.
3. **The by-ear slider while settling.** D9 says nothing about it. It is inert until steady because the Mac stores whatever a tick session was holding, and a first pass is now stored while settling anyway. Recommendation: keep the lock and its line; a by-ear trim has no first-pass mark on the Mac to label it with.
4. **The re-check banner outside the sheet.** The Mac ADR says "a one-tap re-check on the phone once the Mac's clock verdict says the link has settled". From the Speakers tab one tap cannot skip the walk, so the honest one-tap there is the row's word and glyph opening the sheet, which exist. Recommendation: no second banner on the Speakers tab; the row is the offer. Alec to confirm, since D10 says "banner".
5. **"Settled" versus "steady".** The glossary's term is "Settled"; the sheet's rule and the wire value are "settling" and "steady", never "settled". Every line here uses "steady". One of the two documents has to move.
6. **"Timing", "tune" and "tuning" in the copy-review terminology table.** The table lists align / Sync / sync offset for the feature and never mentions the words the sheet and the row actually use. Not re-litigated here; flagged.
7. **The heavy impact versus `.success`** for "Measurement lands" (marked as an assumption above).
8. **Verdict bands at 10 and 40 ms** replace the code's 4 ms "in step" band. The research supports 10; T23 may move it once the settle log has twenty reconnects per speaker. The band lives in one place on the phone (`verdictLine` and its two siblings) so it can move.

## What this touches in code (for the builder's scope, not for design)

`SyncSheet.swift`: `Page`, `firstPreRunPage`, the merged page, `placementPage` and `placementFootnote`, `ctaReady`, `liveAnnouncement`, `startRun` (drop `automatic`), `runDidFinish`, `verdictPage`, `followUpLine` and its lines, `measuredPage` (auto demo, Hear it hold), `RegisterRings` (start apart, converge on a trigger), the removed re-check state. `AlignmentRunController.swift:33-52` (one phase word). `DeviceRowView.swift:768` (the word). `SyncInviteCard.swift` via `needsTuning`. `AlignmentRunControllerTests.swift:130-310` (every pinned sentence above). Sweep level and fade are T1 in the shared package and not phone work.
