# External precedent: how other products handle an unavoidable wait, and how calibration rituals are staged

Lens: external precedent only. Everything factual about other products carries a URL. Everything factual about our code carries a path and line. Where I could not confirm something, I say so.

## What I read first

- The shared brief.
- `/Users/alechenderson/Projects/audiout-remote/AudioutRemote/UI/Sync/SyncSheet.swift` — placement page at :149, the title "Go to where you listen." at :151, the disabled button text `"Ready in \(remaining)s"` at :196-198, the two preconditions the Mac publishes at :204-209, the local one-second tick at :213-220, the run page and its green field at :236-279, the verdict line at :365-371, and the single forward offer to the next untuned speaker at :338-352 and :374-383.
- `AudioutRemote/Model/AlignmentRunController.swift:45-51` — the four phase words the run can show: "Hearing the room", "Chirping", "Letting it land", "Measuring". There is no fifth, and no percentage.
- The unmerged phone branch, via `git show claude/settle-window-phone:AudioutRemote/UI/Sync/SyncSheet.swift` — the footnote that replaces the disabled button (:283-294), the settling sentence itself (:662-666), the "Measure it now" line (:255-259), and the automatic re-check machinery (:337 onward).
- `dev/notes/handoff-2026-09-03-settle-window-adaptive.md` in the Mac worktree.

Three facts from that reading shape every judgement below:

1. The phone has four named moments in a run and no progress fraction. Any pattern that needs a percentage is out on honesty grounds before it is out on anything else.
2. The wait is 0 to 60 s, and today nothing tells the phone how long it will really be. On the unmerged Mac branch it can end early; it still cannot be predicted at the start.
3. The sheet already sequences speakers one at a time, but only as a single line offered after a verdict (`SyncSheet.swift:338-352`). There is no list, no queue, and no "which of these do you want to set up" step anywhere.

---

## 1. Pattern catalogue

Twelve patterns. Each has a one-line description, named examples with URLs, the mechanism in plain words, and an honest fit note against our constraints.

### 1. Say why the wait exists, in one sentence, at the moment it bites

Replace a bare countdown with a plain reason for it.

- Tesla says the car cannot be driven during an install and why: functions are limited and interrupting can corrupt the software. https://www.tesla.com/ownersmanual/model3/en_us/GUID-A5A60CB3-7659-4B08-B2FD-AFD12C2D6EE1.html
- Nielsen Norman Group's guidance on progress indicators is explicit that the text beside the indicator should say what is happening, and that time estimates must not be more precise than the truth. https://www.nngroup.com/articles/progress-indicators/

Mechanism: Maister's classic list has "unexplained waits are longer than explained waits" as one of its propositions. https://www.columbia.edu/~ww2040/4615S13/Psychology_of_Waiting_Lines.pdf (I could not extract the PDF text through the fetch tool; the proposition list is also summarised at https://uen.pressbooks.pub/opexintro/chapter/managing-the-psychology-of-waiting/)

Fit: excellent, and already built on the unmerged phone branch — the settling sentence at `claude/settle-window-phone:AudioutRemote/UI/Sync/SyncSheet.swift:662-666`. It is the cheapest fix and it is not the thing Alec is complaining about. He has seen a version of it and still calls the screen text-heavy and empty. So this is a floor, not an answer.

### 2. Fill the wait with a real task the user must do anyway

Give the user the setup work that has to happen regardless, so the clock runs behind it.

- Sonos Trueplay advanced tuning: before any measurement, the app has the user flip the phone upside down so the microphone is at the top, then samples background noise, then plays a video teaching the waving technique, and only then starts. https://support.sonos.com/en-us/article/tune-your-sonos-speakers-with-trueplay and https://www.imore.com/how-tune-your-sonos-speakers-use-trueplay-iphone-and-ipad
- Bose ADAPTiQ walks the user to five seating positions with a headset on before it has an answer. https://support.bose.com/s/article/1002760?language=en_US
- Restaurants hand out menus while people queue, the standard illustration of Maister's "occupied time feels shorter than unoccupied time". https://uen.pressbooks.pub/servicesmgt/chapter/chapter-12-the-psychology-of-waiting/

Mechanism: occupied time feels shorter, and once a person has started they feel served rather than queued.

Fit: strong and directly what Alec proposed. Our real preparation work is genuine, not invented: get to the listening position, get music playing on both speakers, pick which speakers to do. Two of those are already preconditions the Mac publishes (`SyncSheet.swift:204-209`). Risk: on a Sony that settles instantly, a staged ritual would invent a wait that does not exist, and that is a lie by pacing even if every sentence is true.

### 3. Show the machine's own work, honestly, while it works

Display what the system is actually doing rather than an abstract spinner.

- Buell and Norton, "The Labor Illusion", Management Science 57(9), 2011: across five experiments, people sometimes preferred a site that showed its work and took longer over one that returned identical results instantly. https://pubsonline.informs.org/doi/10.1287/mnsc.1110.1376 and the paper PDF at https://www.hbs.edu/ris/Publication%20Files/Norton_Michael_The%20labor%20illusion%20How%20operational_f4269b70-3732-4fc4-8113-72d0c47533e0.pdf

Mechanism: visible effort reads as effort spent on you, and raises the perceived worth of the result.

Fit: partial. Our run page already does this well with four honest phase words (`AlignmentRunController.swift:45-51`). The settling window is the opposite case: the Mac is watching a clock, not labouring, and the phone knows only a seconds estimate. Faking a busy log would break "the UI never lies". The only honest version is a live readout of something the Mac genuinely knows, which needs a new wire field.

### 4. Make the wait a rehearsal of the thing about to happen

Use the wait to demonstrate or preview the outcome so the user learns what "good" sounds like.

- Sonos plays a video of the waving technique during setup rather than describing it. https://www.imore.com/how-tune-your-sonos-speakers-use-trueplay-iphone-and-ipad
- Apple's ear tip fit test is a fifteen second measurement whose whole purpose is to teach the user what a good seal is, then let them change a tip and rerun it. https://support.apple.com/en-us/119849

Mechanism: people accept a wait better when it is teaching them something they can act on.

Fit: good, and we have the material. The sheet already has an A/B demo command ("Hear it", `SyncSheet.swift:308-310`). Letting a user hear the current out-of-step state during the wait makes the wait the argument for the feature. Risk: the demo command is a Mac command and may be refused; and playing a demo needs both speakers sounding, which is one of the two preconditions.

### 5. Turn a queue into a checklist the user builds

Ask which items to process, then work them in order with visible position.

- Dirac Live has the user choose a measurement arrangement first, nine positions for a single chair or thirteen for a sofa, then walks them through. https://www.audioadvice.com/blogs/expert-advice/dirac-live-room-calibration-tips-tricks-setup-guide
- Audyssey MultEQ takes up to eight microphone positions in sequence. https://manuals.denon.com/avrx4100w/NA/EN/GFNFSYnuokgukf.php
- Sonos tunes each room separately; quick tuning covers a standalone speaker, a stereo pair or a home theatre set. https://support.sonos.com/en-us/article/tune-your-arc-ultra-era-100-or-era-300-with-trueplay

Mechanism: a known finite list beats an open-ended one. Maister: uncertain waits feel longer than known finite waits.

Fit: strong for Alec's "define which speakers they want to set up". We only have a single forward link today (`SyncSheet.swift:338-352`). The catch is our own rule that nothing is app-initiated: a list may be built by the user and advanced by the user, but must not run itself.

### 6. Stage the wait behind a physical instruction the user is executing

Give a bodily instruction whose natural execution takes about as long as the wait.

- Apple's personalized spatial audio setup: hold the phone about twelve inches away, circle the head, then move the right arm out forty five degrees and turn the head left, then swap hands and repeat. https://support.apple.com/en-us/102596
- Face ID setup asks for two full head circles, the second filling gaps left by the first. https://support.apple.com/en-us/108411
- Sonos advanced tuning: "make smooth movements with your device from head to waist as you move around" the room, roughly three minutes end to end. https://support.sonos.com/en-us/article/tune-your-sonos-speakers-with-trueplay

Mechanism: a body doing a task does not experience the task as waiting. Maister's "people want to get started" and the pre-process versus in-process distinction.

Fit: very strong on face value and the closest match to what our screen already asks (`SyncSheet.swift:151`, "Go to where you listen."). The honest catch: walking to the sofa takes ten to twenty seconds, not sixty, and we cannot pad it with invented steps without either lying or wasting the user's time. Best used as the opening of the wait, not the whole of it.

### 7. Let the user proceed early, and be explicit about the cost

Offer a way through the gate with the consequence stated.

- Sonos lets a tuning be aborted with the play or pause button or the X. https://support.sonos.com/en-us/article/tune-your-sonos-speakers-with-trueplay
- Nielsen Norman Group: anything slow needs a clearly signposted way to interrupt. https://www.nngroup.com/articles/progress-indicators/

Mechanism: control lowers the felt cost of a wait more than shortening it does.

Fit: already built on the unmerged phone branch as the "Measure it now" line plus an automatic re-check (`claude/settle-window-phone:AudioutRemote/UI/Sync/SyncSheet.swift:255-259`, :662-668). It is exactly the "single CTA that gives you the option to pass through" that Alec is unhappy with. So the escape hatch is necessary and not sufficient. Note also the rule tension: a self-starting re-check is app-initiated behaviour and only survives as the one sanctioned announced, refusable exception.

### 8. Do the slow thing on the device instead of the person, and say so

Where the hardware can measure itself, shorten the human's involvement to a tap.

- Sonos quick tuning uses the speaker's own microphones, needs one tap, and completes in roughly fifteen to twenty seconds against about three minutes for the walk-around version. https://www.trustedreviews.com/explainer/what-is-sonos-quick-tune-trueplay-4307835 and https://support.sonos.com/en-us/article/tune-your-arc-ultra-era-100-or-era-300-with-trueplay
- HomePod listens to its own reflections and re-maps in a few seconds whenever its accelerometer notices it has moved. https://www.apple.com/newsroom/2023/01/apple-introduces-the-new-homepod-with-breakthrough-sound-and-intelligence/ and https://appleinsider.com/articles/18/02/07/homepod-doesnt-have-manual-eq-options-will-auto-adjust-based-on-analytics-says-apples-eddy-cue

Mechanism: the fastest wait is the one that is not the user's.

Fit: not available to us as an alternative measurement, since the whole point of the companion is that the Mac has no microphone. It is available as a way to shorten the gate: this is the Mac-side adaptive detector and the clock-delta compensation in `dev/notes/handoff-2026-09-03-settle-window-adaptive.md`. Worth naming in the report because it is the only route that removes the wait rather than dressing it.

### 9. Two tiers: a fast rough pass and a slow careful one, user's choice

Offer a quick result now and a better result later.

- Sonos: quick tuning versus advanced tuning, iOS only for the latter. https://support.sonos.com/en-us/article/tune-your-arc-ultra-era-100-or-era-300-with-trueplay
- Dirac Live: differently sized measurement arrangements for a single chair or a sofa. https://www.audioadvice.com/blogs/expert-advice/dirac-live-room-calibration-tips-tricks-setup-guide

Mechanism: choosing between two honest options is control; being told to wait is not.

Fit: promising and mostly free. We already have two paths on the same page: measure with the microphone, or "Adjust by ear" (`SyncSheet.swift:174`). Today the by-ear link is styled as an afterthought beside the gold button. Presenting it as a real second option during the wait is a copy and layout change, not new state. Risk: our design rule allows one gold action per decision screen, so the second option stays plain gold text.

### 10. Give the wait a rhythm the user can read without a number

Use a moving visual that shows liveness without claiming a fraction.

- Harrison, Yeo and Hudson, CHI 2010: progress bars with backwards decelerating ribbing were perceived as faster; a five second plain bar felt equivalent to a 5.61 second ribbed one, about twelve percent longer in real duration. https://www.chrisharrison.net/projects/progressbars2/ProgressBarsHarrison.pdf and https://dl.acm.org/doi/10.1145/1753326.1753556
- Apple Watch pairing shows a swirling particle cloud, which is a real optical code being read by the phone camera rather than decoration. https://appleinsider.com/articles/15/05/05/apple-watch-particle-cloud-pairing-method-likely-revealed-in-new-patent

Mechanism: movement occupies attention and shortens felt duration; a visual tied to something real also stays honest.

Fit: careful yes. We own an emitter field already, used on the run page (`SyncSheet.swift:236-279`), and the design record allows green inside this sheet. A still or slow field during the wait, moving only when the Mac says something changed, is honest. What is out: any speed or fill that implies a fraction, and any motion at all under Reduce Motion. Harrison's specific finding is about a determinate bar, which we cannot honestly draw.

### 11. Fill the wait with content of independent worth

Show something useful or interesting that is true whether or not the wait exists.

- Video game loading screens with tips and lore. Namco's patent on auxiliary loading-screen games expired 27 November 2015, which is why the interactive version largely vanished for twenty years. https://www.eff.org/deeplinks/2015/12/loading-screen-game-patent-finally-expires and https://www.gamedeveloper.com/business/2015-the-year-we-get-loading-screen-mini-games-back
- Nintendo, PlayStation and console installers use the same tips pattern (widely reported; I did not find a first-party design source and have not verified any vendor rationale).

Mechanism: passive waiting is overestimated; occupied waiting is not.

Fit: weak for us, and the failure mode is exactly Alec's complaint. Our current screen is already a wall of explanation with an empty middle. More reading material makes it worse. Tips only work if they are acted on, which folds them back into pattern 2 or 4.

### 12. Make the finish loud so the wait reads as a threshold rather than an interruption

Mark the end of the wait with a distinct signal so the wait has a shape.

- AirPods proximity pairing: the case opens near the phone and a card slides up with an image and a battery level, arriving without a tap. https://support.apple.com/guide/airpods/pair-airpods-with-an-apple-device-dev7c85810f2/web
- Nest Wifi setup ends on an explicit "Connected" confirmation screen after a few minutes of network creation. https://support.google.com/googlehome/answer/9548301?hl=en-AU

Mechanism: a marked ending converts an open-ended wait into a known finite one after the fact, and gives the user a moment of arrival.

Fit: partly built. The unmerged phone branch already fires a light haptic and posts a VoiceOver announcement when the button goes live (`claude/settle-window-phone:AudioutRemote/UI/Sync/SyncSheet.swift:161-172`). Cheap to strengthen visually. Constraint: no notifications, so this only lands while the sheet is on screen, which is also why the branch keeps the screen awake.

---

## 2. How calibration rituals stage the moment before measuring

Six questions, answered from the sources above.

**What they ask the user to do first.** Every one of them asks for a physical act before any measurement.
- Sonos: flip the phone so the microphone points up, then sample background noise, then watch a technique video, then start. https://support.sonos.com/en-us/article/tune-your-sonos-speakers-with-trueplay
- Bose: put on a headset with a microphone, sit in position one of five. https://support.bose.com/s/article/1002760?language=en_US
- Audyssey and Dirac: put the microphone tip at ear height where your head goes, pointing at the ceiling, and treat that first position as the important one. https://manuals.denon.com/avrx4100w/NA/EN/GFNFSYnuokgukf.php and https://www.audioadvice.com/blogs/expert-advice/dirac-live-room-calibration-tips-tricks-setup-guide
- Apple's spatial audio scan: three separate captures with a stated arm angle and head direction for each. https://support.apple.com/en-us/102596

The pattern is that the instruction is always about position, and it is always concrete: an angle, a distance, a body part. Ours is already in this family (`SyncSheet.swift:151`) but stated once as prose rather than staged as an act.

**How they explain why, and at what length.** Very short, and never before the first instruction. Sonos's own article explains the mechanism, room reflections off walls, ceiling and furniture, in about a sentence, and puts the technique video before the theory. https://support.sonos.com/en-us/article/tune-your-sonos-speakers-with-trueplay. Apple's spatial audio page gives no theory at all in the flow, only the instructions. HomePod's room sensing is explained publicly but never in a setup screen, because there is no setup screen. https://www.apple.com/newsroom/2023/01/apple-introduces-the-new-homepod-with-breakthrough-sound-and-intelligence/

Read against our screen: our placement page leads with roughly forty words of explanation before anything to do. That is longer than any of these products puts in front of a first action.

**What they show while working.** Sound and motion, not numbers. Sonos plays sweeping test tones while the user waves; the app's feedback is the tone itself plus the movement instruction, and the tuning aborts on a play/pause press. https://support.sonos.com/en-us/article/tune-your-sonos-speakers-with-trueplay. Bose plays tones per position. Dirac's app plays test tones per position and then draws the measured curve against a target curve at the end. https://www.dirac.com/home/dirac-live/processor. None of them shows a percentage during the acoustic part.

**Stated durations.** Sonos advanced tuning: "approximately 3 minutes from start to finish". https://support.sonos.com/en-us/article/tune-your-sonos-speakers-with-trueplay. Sonos quick tuning: roughly fifteen to twenty seconds. https://www.trustedreviews.com/explainer/what-is-sonos-quick-tune-trueplay-4307835. Bose ADAPTiQ: allow ten minutes. https://support.bose.com/s/article/1002760?language=en_US. Dirac: under thirty minutes for the full guided calibration. https://www.audioadvice.com/blogs/expert-advice/dirac-live-room-calibration-tips-tricks-setup-guide. HomePod: a few seconds, unannounced. https://www.macobserver.com/tips/quick-tip/homepod-recalibrate-shake/

The relevant comparison: our worst case, 60 s of waiting plus a 10 to 20 s run, is short by the standards of this category. Nobody in this category has succeeded in making calibration feel instant; they have succeeded in making it feel like a procedure with a known length. Note that all of these durations are quoted up front and are stable. Ours is neither, and that is the actual difference.

**How they treat skipping and doing it later.** Trueplay is opt-in from settings and can be toggled off after tuning, so the tuning result is reversible without redoing anything. https://support.sonos.com/en-us/article/tune-your-sonos-speakers-with-trueplay. Bose can be deactivated. https://www.bose.co.uk/en_gb/support/articles/HC1971/productCodes/bose_soundbar_700/article.html. Apple's spatial audio support page mentions no skip path at all in the flow. Apple's ear tip fit test is a rerun-until-happy loop with a plain two-state result. https://support.apple.com/en-us/119849. The common shape is: the ritual is always optional at the level of the feature, and never optional halfway through a single measurement.

**How they handle several speakers or rooms.** Serially and manually. Sonos tunes each room separately and does not offer a batch. https://support.sonos.com/en-us/article/tune-your-arc-ultra-era-100-or-era-300-with-trueplay. Audyssey and Dirac sequence positions within one room, with the position count chosen up front. Nobody in this set runs an unattended queue across rooms, and the reason is obvious once stated: the measurement needs a human standing somewhere specific, so a queue that runs itself has nobody in the right place.

That last point is worth carrying into the concepts. A "set up all my speakers" list is a good idea for choosing scope, and a bad idea for automation, and our own rule against app-initiated runs happens to agree with every product in this category.

---

## 3. Three concept sketches

No names. Concept 1, 2, 3. Each is described as the user's experience on our sheet.

### Concept 1: the wait is spent walking, and the sheet asks for one thing at a time

Derived from patterns 6, 2 and 1: Sonos's flip-then-sample-then-teach sequence, and Apple's spatial audio choreography, both of which never put two instructions on screen at once.

**Step by step.** The sheet opens on a single short line: get to where you listen, with the two speaker names in it. No paragraph. Below it, one line of state: whether the Mac is ready. If the Mac's preconditions are unmet (`SyncSheet.swift:204-209`), that is the only thing shown, phrased as the next thing to do. Once the user is there, the sheet asks for the second thing, which is confirming both speakers are audible from that spot. That confirmation is a real tap, and it is what advances the page. If the speaker has settled by then, the gold Measure button is live and the user has never seen a countdown. If it has not, the button shows as not yet live with the one-sentence reason underneath, and the plain gold "Measure it now" line stays available.

**What fills the wait.** Walking, and one confirmation tap. Nothing invented.

**Instant settle.** The user sees no wait at all: two short instructions, then Measure. This is the case that most needs to look normal, and here it does.

**Short settle, five to fifteen seconds.** The walk covers it. The button is live by the time the user looks up.

**Long settle, thirty to sixty seconds.** The user arrives before the Mac is ready, and lands on a screen showing the reason line and the early-measurement offer. That is close to today's failure, softened by having done something first.

**Several untuned speakers.** Unchanged from today: one forward line after a verdict (`SyncSheet.swift:338-352`).

**State or commands we do not have.** None. This is copy, layout and one extra page transition. It works on `main` today and works better with the unmerged phone branch's footnote.

**Biggest risk.** It does not solve the long case, which is the case Alec named. It also adds a tap to a flow that is already several screens deep, and the confirmation tap risks reading as busywork if the Mac already knows both speakers are sounding, which it does.

### Concept 2: the wait is spent choosing scope, and the sheet becomes a short list of speakers

Derived from patterns 5 and 9: Dirac and Audyssey choosing the measurement arrangement before measuring, Sonos tuning rooms one at a time, and Alec's own proposal.

**Step by step.** Entering the sheet with more than one untuned or stale speaker opens on a list of them, each with a plain state word, and each tappable to include or exclude. The user picks. Then the placement instruction, then Measure for the first one. After each verdict, the next chosen speaker's placement page follows, with a plain "2 of 3" style position. A speaker still settling when its turn comes is shown as such and the list offers to take a ready one first, on a tap, never on its own.

**What fills the wait.** The choosing, and then the fact that there is always another speaker that is ready while one settles. With two or more Bluetooth speakers this genuinely converts dead time into work.

**Instant settle.** The list is one extra screen before a flow that would otherwise be instant. With a single untuned speaker the list must not appear at all.

**Short settle.** Absorbed by choosing.

**Long settle.** Absorbed only if another speaker is ready. With exactly one Bluetooth speaker in the house, which I suspect is the common case, this concept degrades to Concept 1 plus a pointless list.

**Several untuned speakers.** This is the concept's whole subject. Order is the user's, advancing is the user's, and nothing runs unattended, which matches every product in the calibration set and our own no-app-initiated-runs rule.

**State or commands we do not have.** Nothing new on the wire strictly: the snapshot already carries per-device alignment status, and `SyncSheet.swift:374-383` already filters for the speakers that need work. What we do not have is a per-speaker settle estimate for speakers other than the current target, which we would want in order to say "do the other one first". I could not verify from the phone repo alone whether `settleRemainingSeconds` is published for every Bluetooth device or only some; that needs checking in `CompanionSnapshotBuilder.swift` on the Mac side.

**Biggest risk.** It is the most work and it helps the fewest users. It also risks reading as a chore list at the exact moment the user wanted to press play, which is Alec's stated objection turned inside out.

### Concept 3: the wait is spent listening to the problem

Derived from patterns 4, 10 and 12: Apple's ear tip fit test as a teach-by-measuring loop, Sonos playing tones the user can hear throughout, and the finish-signal pattern.

**Step by step.** The sheet opens on the placement line as today. While the speaker is settling, the screen offers one plain gold text action, not the gold button: hear what it sounds like now. Tapping it plays the existing A/B demo (`SyncSheet.swift:308-310`) so the user hears the two speakers out of step from the listening position. The emitter field is present behind it, still, in the green ramp already allowed in this sheet, moving only while sound is actually in the room, exactly as the run page already does it (`SyncSheet.swift:236-248`). When the Mac says the speaker has settled, the field settles with it, the light haptic fires, and the gold Measure button appears. The wait ends visibly and audibly rather than by a number reaching zero.

**What fills the wait.** The problem itself, heard from the place the fix will be measured from. This is the only one of the three that makes the user want the measurement rather than tolerate it.

**Instant settle.** The demo offer never appears; the Measure button is there on open. No wait is invented.

**Short settle.** One demo playthrough roughly covers it.

**Long settle.** The user can hear it, walk, hear it again. Sixty seconds of "listen to how wrong this is" is a better sixty seconds than sixty seconds of reading.

**Several untuned speakers.** Unchanged from today's single forward line, or combined with Concept 2 later.

**State or commands we do not have.** The A/B demo command exists, but I could not verify whether the Mac will accept it for a speaker that has no tuning yet, which is precisely the state we would be calling it in. If it only demonstrates a stored correction, this concept needs a new Mac behaviour: play the same short passage on both speakers, uncorrected, on request. That is the one real dependency. It also needs both speakers sounding, which is already a published precondition.

**Biggest risk.** Two. First, if the demo is refused for an untuned speaker, the wait screen becomes a broken promise, which is worse than an empty one. Second, one gold action per decision screen: the demo offer and the Measure button must never be gold at the same time, so the demo has to be plain gold text and the button appears only when live. That is workable but tight.

---

## 4. Ranked recommendation

**First: Concept 3, with Concept 1's copy discipline folded in.**

Reasoning. Every product in the calibration set fills the pre-measurement moment with something the user's body or ears are doing, and none of them fills it with explanation. Our screen currently fills it with explanation and an empty middle, which is why it reads as text-heavy. Concept 3 is the only one that turns the wait into the argument for the feature: a person who has just heard their kitchen speaker trailing wants the measurement, and a person who wants the measurement will wait for it. It also uses assets we already own, the demo command and the emitter field, and it degrades to nothing when the speaker settles instantly, which protects the Sony case. Its dependency is small and testable: does the Mac play the demo for an untuned speaker.

**Second: Concept 1.**

It is free, it ships on `main` or on the unmerged branch without new state, and it fixes a real defect: forty words of prose ahead of the first action, where Sonos and Apple put roughly one instruction. It should ship regardless of which concept wins, because it is a prerequisite for both of the others. On its own it does not answer the long-settle case.

**Third: Concept 2.**

Right idea, wrong first move. It is the most build, it needs a per-device settle estimate we may not publish, and it only pays off for users with two or more Bluetooth speakers. It becomes attractive once the Mac branch's adaptive detector lands and the wait is genuinely variable per speaker, because then "do the ready one first" is a real answer rather than a list.

**Standing above all three:** the wait that gets removed beats every wait that gets decorated. The clock-delta compensation described in `dev/notes/handoff-2026-09-03-settle-window-adaptive.md` would make this whole design question smaller. None of these concepts should be built in a way that assumes the 60 s floor survives.

**One warning from the precedent, against Alec's own framing.** He suggested "an almost artificial gate of introducing them to how the system works". Nothing in this precedent set supports an artificial gate, and our own rule against a lying interface forbids one. Sonos's steps are all load-bearing: the flip positions the microphone, the noise sample is a real check, the video teaches a technique the measurement depends on. What looks like ceremony is procedure. Fill the wait with real work or real sound. If the speaker has settled, show no gate at all.

---

## 5. Three open questions only Alec can answer

1. **Will the Mac play the A/B demo for a speaker with no tuning stored, and does it need both speakers already sounding?** Concept 1 recommendation stands either way; Concept 3 depends on this answer, and it decides whether the wait can be filled with sound or only with words.

2. **How many Bluetooth speakers does a typical buyer have?** One or two changes the ranking. If most users have exactly one, Concept 2 is dead weight and the list should never be built. If two or more is common, Concept 2 rises above Concept 1.

3. **Does the announced, refusable re-check on the verdict page stay the only app-initiated exception, or may the wait screen also change on its own when the Mac says the speaker settled?** Concept 3's ending, the field settling and the button appearing, is a screen changing without a tap. It happens only while the sheet is open and is closer to a state readout than to a run, but it is a judgement call about the rule, not a technical one.

---

## Sources

- Sonos, Tune your Sonos speakers with Trueplay: https://support.sonos.com/en-us/article/tune-your-sonos-speakers-with-trueplay
- Sonos, Tune your Arc Ultra, Era 100, or Era 300 with Trueplay: https://support.sonos.com/en-us/article/tune-your-arc-ultra-era-100-or-era-300-with-trueplay
- Trusted Reviews, What is Sonos Quick Tune: https://www.trustedreviews.com/explainer/what-is-sonos-quick-tune-trueplay-4307835
- iMore, How to tune your Sonos speakers to use Trueplay: https://www.imore.com/how-tune-your-sonos-speakers-use-trueplay-iphone-and-ipad
- Bose, To run the ADAPTiQ audio calibration system: https://support.bose.com/s/article/1002760?language=en_US
- Bose UK, ADAPTiQ system setup and deactivation: https://www.bose.co.uk/en_gb/support/articles/HC1971/productCodes/bose_soundbar_700/article.html
- Denon, Procedure for speaker settings (Audyssey Setup): https://manuals.denon.com/avrx4100w/NA/EN/GFNFSYnuokgukf.php
- Audio Advice, Dirac Live setup guide: https://www.audioadvice.com/blogs/expert-advice/dirac-live-room-calibration-tips-tricks-setup-guide
- Dirac, Dirac Live Processor: https://www.dirac.com/home/dirac-live/processor
- Apple, Listen with Personalized Spatial Audio: https://support.apple.com/en-us/102596
- Apple, Use Face ID: https://support.apple.com/en-us/108411
- Apple, Choose your AirPods Pro ear tips: https://support.apple.com/en-us/119849
- Apple, Pair AirPods with an Apple device: https://support.apple.com/guide/airpods/pair-airpods-with-an-apple-device-dev7c85810f2/web
- Apple Newsroom, HomePod (2nd generation): https://www.apple.com/newsroom/2023/01/apple-introduces-the-new-homepod-with-breakthrough-sound-and-intelligence/
- AppleInsider, Eddy Cue on HomePod auto-adjustment: https://appleinsider.com/articles/18/02/07/homepod-doesnt-have-manual-eq-options-will-auto-adjust-based-on-analytics-says-apples-eddy-cue
- Mac Observer, shake HomePod to recalibrate: https://www.macobserver.com/tips/quick-tip/homepod-recalibrate-shake/
- AppleInsider, Apple Watch particle cloud pairing patent: https://appleinsider.com/articles/15/05/05/apple-watch-particle-cloud-pairing-method-likely-revealed-in-new-patent
- Google, Set up Nest Wifi Pro or Nest Wifi: https://support.google.com/googlehome/answer/9548301?hl=en-AU
- Google, Smart Sound for Google Home Max: https://support.google.com/googlehome/answer/7585574?hl=en
- Google blog, Nest Audio (Media EQ, Ambient IQ): https://blog.google/products-and-platforms/devices/google-nest/new-nest-audio/
- Tesla owner's manual, Software Updates: https://www.tesla.com/ownersmanual/model3/en_us/GUID-A5A60CB3-7659-4B08-B2FD-AFD12C2D6EE1.html
- BluOS, Grouping Players using A/V Mode: https://support.bluos.net/hc/en-us/articles/360021056034-Grouping-Players-using-A-V-Mode
- Roon Labs community, NAD/Bluesound grouped zones out of sync: https://community.roonlabs.com/t/nad-bluesound-grouped-zones-out-of-sync-investigating/286887
- Buell and Norton, The Labor Illusion, Management Science 2011: https://pubsonline.informs.org/doi/10.1287/mnsc.1110.1376 (PDF: https://www.hbs.edu/ris/Publication%20Files/Norton_Michael_The%20labor%20illusion%20How%20operational_f4269b70-3732-4fc4-8113-72d0c47533e0.pdf)
- Maister, The Psychology of Waiting Lines: https://www.columbia.edu/~ww2040/4615S13/Psychology_of_Waiting_Lines.pdf (fetch returned unreadable binary; propositions cross-checked at https://uen.pressbooks.pub/servicesmgt/chapter/chapter-12-the-psychology-of-waiting/ and https://uen.pressbooks.pub/opexintro/chapter/managing-the-psychology-of-waiting/)
- Harrison, Yeo and Hudson, Faster Progress Bars, CHI 2010: https://www.chrisharrison.net/projects/progressbars2/ProgressBarsHarrison.pdf and https://dl.acm.org/doi/10.1145/1753326.1753556
- Nielsen Norman Group, Progress Indicators Make a Slow System Less Insufferable: https://www.nngroup.com/articles/progress-indicators/
- Nielsen, Response Time Limits: https://www.nngroup.com/articles/response-times-3-important-limits/
- EFF, The Loading Screen Game Patent Finally Expires: https://www.eff.org/deeplinks/2015/12/loading-screen-game-patent-finally-expires
- Game Developer, 2015: The Year We Get Loading Screen Mini-Games Back: https://www.gamedeveloper.com/business/2015-the-year-we-get-loading-screen-mini-games-back

## Not verified

- Whether the Mac accepts `playAlignmentDemo` for a speaker with no stored tuning. Concept 3 depends on it.
- Whether `settleRemainingSeconds` is published for every Bluetooth device in the snapshot or only the current target. Concept 2 depends on it.
- Maister's proposition list was read through secondary summaries, not the original PDF, because the fetch returned unreadable binary.
- Console installer tip screens (Nintendo, PlayStation): commonly described but I found no first-party design source, so no claim is made about their rationale.
- Any claim about latency readouts inside JBL, Ultimate Ears or Bose phone apps. The search results on this were low-quality aggregator pages, not vendor documentation, so I have left the pattern out rather than cite them.
