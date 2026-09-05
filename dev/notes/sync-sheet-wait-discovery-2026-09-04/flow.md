# The sync sheet's wait, from the journey in

Product-flow lens. Everything below is read off the code in the two checkouts named in the brief, on `main` unless a branch is named. Paths are relative to `~/Projects/audiout-remote/` (phone), `~/Projects/AirPlay Controller/.claude/worktrees/sync-wizard-waiting-ux-b93148/` (Mac) and `~/Projects/audiout-shared/` (wire).

---

## 0. Six facts that change the shape of the problem

Read these before the scenario map. Four of them are not in the brief, and two of them are bugs.

**(a) The window only ever runs for a link edge this running Mac process watched.**
`noteConnected` has exactly two call sites: the manual reconnect's own outcome (`AudioutCore/Sources/AudioutCore/NativeBackend.swift:3846`) and the enumerator's availability edge on a device already in the list (`NativeBackend.swift:8414`). A Bluetooth device the process has never listed takes the other branch of `applyBTSnapshots` (`NativeBackend.swift:8434-8449`), which builds the row and emits `.deviceAdded` and calls nothing. `BTAlignmentFreshness` is in-memory by decision (`AudioutCore/Sources/AudioutCore/BTAlignmentFreshness.swift:15-22`).

So: **a first pairing has no wait, and the first speaker after a Mac app launch has no wait.** That is exactly backwards from the physics. A fresh link is when the Sonos Move 2 was measured jumping for 42 s (`dev/notes/handoff-2026-09-03-settle-window-adaptive.md`, quoting `dev/notes/bt-spike-findings-2026-08-07.md`), and it is the case the gate lets straight through.

**(b) The number on the phone can be far larger than the seconds actually left.**
The Mac broadcasts only on an event, coalesced 50 ms, with no timer at all (`AudioutCore/Sources/AudioutApp/AppDelegate.swift:2535-2544`). `noteConnected` fires one change (`BTAlignmentFreshness.swift:75-82`), which reaches the broadcast through `AppDelegate.swift:2295-2300`. During a quiet minute nothing else fires. The phone seeds its count from whatever snapshot it is holding (`AudioutRemote/UI/Sync/SyncSheet.swift:187-191`) and ticks that down locally (`SyncSheet.swift:213-219`). There is no "send me a fresh snapshot" command in the protocol (`Sources/AudioutProtocol/CompanionCommand.swift:36-86`).

Worked through: link up at t=0, sink renders and broadcasts at about t=5 with 55 s published, then silence. User opens the sheet at t=45. The sheet reads 55, counts 55 down, and the user waits until t=100. **The Mac's window closed at t=60 and the user waited 40 s past it.** The longer someone takes to reach the sheet, the more extra wait they get. This alone may be most of what the owner felt.

**(c) A speaker that power-cycles comes back unselected, so the user's own actions eat the window.**
`PopoverController.swift:880-886` deselects any selected Bluetooth device that loses availability. When it returns the user has to select it again, and only then is it a Main Out member. Group membership is separate and is not deselected, so a group member resumes on its own (read off the same lines: the loop tests `isSpeakerSelected`, not group membership; I did not verify the group resume end to end).

**(d) The run's precondition is Main Out membership, not "music is playing".**
`DeviceRowView.isSounding` is literally `device.isMainOutMember` (`AudioutRemote/UI/Speakers/DeviceRowView.swift:98-100`), and the Mac's gate wants the target audible plus one other audible speaker (`BTAlignmentFreshness.swift:245-264`). The reference is preferentially the Mac's own output (`AudioutCore/Sources/AudioutCore/CompanionSnapshotBuilder.swift:220-231`), and the sweeps are staged on the Mac's own wizard feed (`NativeBackend.swift:10383-10393`). I could not verify whether that feed produces sound with no music playing; the phone's by-ear copy says the ticks ride on top of the music (`SyncSheet.swift:488`).

**(e) Two speakers do not need each other.** Because the reference defaults to the Mac's own output, tuning speaker A is independent of speaker B. Only one run at a time per Mac (`BTAlignmentFreshness.swift:149-152`).

**(f) The phone cannot connect a disconnected speaker.**
An unavailable row is inert on the phone by design (`DeviceRowView.swift:274`, `:289`). The only reconnect affordance is "Try again" on a failure card (`DeviceRowView.swift:726-727`). And `retryConnection` for a device that is neither in the active group nor selected falls through to `setDeviceSelected(id, true)` and never reaches the backend's reconnect (`AudioutCore/Sources/AudioutCore/GroupController.swift:460-472`); only `requestReconnect` (`GroupController.swift:481-483`) is a membership-free connect, and no companion command reaches it. This is the wall the owner's multi-speaker idea hits.

**On the adaptive Mac branch**, the brief's warning is slightly too pessimistic. `report(...)` checks stable first and returns `nil` even inside the 60 s floor (`git show claude/settle-window-adaptive:AudioutCore/Sources/AudioutCore/BTAlignmentFreshness.swift`, the `if stable` arm of `report`). A Sony clears in about 10 s of running audio (`BTClockStability.stableAfterSeconds = 10`). But the detector only samples while the device's sink is doing audio, so a **connected but not playing** speaker accrues no evidence and serves the full 60 s floor.

---

## 1. Scenario map

"Window opened" is when `noteConnected` fired. "Wait seen" is what the phone would put on screen, including fact (b)'s over-count.

| Scenario | When the window opened, relative to the user deciding to tune | Wait actually seen | How often | Evidence |
|---|---|---|---|---|
| First pairing of a speaker, Mac app already running | Never opens | **0 s** | Once per speaker per install | `NativeBackend.swift:8434-8449` takes the new-device branch and calls no `noteConnected` |
| Any speaker, first tune after a Mac app launch or restart | Never opens | **0 s** | Every launch, for every speaker already connected at launch | Same branch; `BTAlignmentFreshness.swift:15-22` (in-memory) |
| Speaker powered on, OS relinks it, app running and listing it | About 20 to 60 s before the user reaches the sheet: they must notice, re-select it (it was deselected), and wait up to 6 s for the sink to render | **10 to 45 s**, plus the over-count from fact (b) | The common case | `NativeBackend.swift:8414`; `PopoverController.swift:880-886`; `btRenderStartTimeout = 6` at `NativeBackend.swift:336` |
| User taps reconnect on the Mac, then goes to the phone | 2 to 10 s before | **50 to 58 s** | The case the owner hit | `NativeBackend.swift:3846` |
| Phone's "Try again" on a failure card, then tune | 2 to 10 s before | **50 to 58 s** | Uncommon; the card only shows after a failure | `DeviceRowView.swift:726-727` into `GroupController.swift:460-472` |
| Group saved that includes a just-connected speaker | 15 to 60 s before, depending on how long naming and picking members took | **0 to 45 s** | Common on the phone; the invite card is the second door | `AudioutRemote/UI/Groups/GroupEditorView.swift:258` into `SyncInviteCard.swift:49-63` |
| Main Out pointed at a group containing a just-connected speaker | 5 to 20 s before | **35 to 55 s** | Common | `AudioutRemote/UI/Speakers/MainOutPicker.swift:136-142` |
| User opens the sheet minutes after connecting | Long closed | **0 s if a snapshot has landed since; otherwise the stale published number, up to 60 s of pure phantom wait** | Common, and the worst experience of the lot | Fact (b): `AppDelegate.swift:2535-2544`, `SyncSheet.swift:187-191` |
| Two to four Bluetooth speakers all powered on together | All windows open within a second or two of each other and run in parallel | First speaker: 30 to 50 s. Second onward: **0 s**, because measuring the first took 60 to 90 s of wall time | The multi-speaker case the owner is asking about | Windows are per device and independent (`BTAlignmentFreshness.swift:59`, `:141-146`); a run takes roughly 10 to 20 s plus the walk |

The last row is the whole answer to the multi-speaker question and I come back to it in Concept 3.

Frequency column is judgement. Nothing measures how users actually arrive; there is no analytics event on the settle window that I could find.

---

## 2. Four concepts

Referred to as Concept 1 to 4 throughout, no names.

Every concept assumes two fixes first, because without them the concepts are decorating a broken number:

- **Fix A (Mac, S).** While any device has an open window, rebroadcast once a second, or publish a deadline the phone can subtract from rather than a countdown. Otherwise fact (b) stands and every concept below inherits a wait that is longer than the truth. `AppDelegate.swift:2535-2544`.
- **Fix B (Mac, S).** Decide whether a first pairing and a post-launch first tune should open a window. Right now they do not. Fact (a).

### Concept 1 — the wait is spent doing the things that had to be done anyway

The placement page becomes three or four short steps, each of which is real preparation, none of which invents progress. The Measure button lives at the end and is live or is not, exactly as today.

**Step by step, from "I want to tune this" to "I heard the result":**

1. Tap the tuning fork on the row, or the invite card. Sheet opens on **"Both speakers need to be playing."** This is today's `macBlocker` (`SyncSheet.swift:204-209`) promoted from a footnote under a dead button to a step with something to do: it names the target and the reference, says which one is not playing, and offers the fix. The phone can already start a speaker (`setDeviceSelected`, `MacSessionProtocol.swift:47`) and point Main Out (`:49`). If both are already playing the step shows as satisfied and the user taps on. Cost: 3 to 20 s.
2. **"Audiout needs to hear the room."** The microphone ask, moved out of the run. Today it is requested inside `AlignmentRunController.start()` (`AudioutRemote/Model/AlignmentRunController.swift:171-174`), so a first-time user gets the system prompt in the middle of a run and a refusal page instead of a measurement. Asking here costs 3 to 8 s of settle time and removes a mid-run failure mode. Skipped silently on every later run.
3. **"Listen to what you'll hear."** One tap plays the chirp pair through the two speakers so the user knows what is about to happen in their room, and hears with their own ears that both speakers are live. This is the strongest wait-filler available because it is a real check of step 1 and it makes the run non-alarming. Needs a Mac-side "play the sweeps without measuring" (NEW, see states below). Cost: 6 to 10 s.
4. **"Go to where you listen."** Today's page, unchanged copy, plus a single button that means "I'm there". This is the step that genuinely takes time: crossing a room is 10 to 25 s.
5. Measure. Run page, verdict, unchanged.

**What fills the wait:** three real preconditions plus a walk. Nothing is fake, nothing is padded, and every step is one the user would have needed anyway. The step the user cannot rush (the walk) is deliberately last, so it overlaps the tail of the window.

**Instant (window already closed, fact (a) or a returning user):** all four steps still appear, but each is one tap and step 1 shows as already satisfied. A hurried user gets from open to run in about 8 s. That is 8 s more than today, which is the honest cost of this concept, and it buys a measurement that is more likely to be good (they are in the right place, the microphone is granted, they know what is coming).

**15 s left:** the walk covers it. The Measure button is live by the time they arrive. The user never sees a number counting down.

**45 s left:** steps 1 to 3 spend 15 to 30 s, the walk spends 15 to 25 s, and the user arrives at Measure with 0 to 15 s left. If time remains, the last step carries one line: the speaker is still settling after connecting, a few seconds to go, with the phone branch's "Measure it now" beside it (`git show claude/settle-window-phone:AudioutRemote/UI/Sync/SyncSheet.swift`, the `Measure it now` button). The difference from today is that the user has spent the wait, not watched it.

**Multi-speaker:** the chain line at the end of the verdict already offers the next untuned speaker (`SyncSheet.swift:338-352`). Under Concept 1 the chain skips steps 2 and 3 for the second speaker (microphone already granted, chirps already heard) and often step 4 as well (already standing in the right place), so speaker two costs one step and a run. Because the windows ran in parallel, speaker two's window is closed by then. This gets the multi-speaker case right without any new machinery.

**States and commands:**

| Need | Status |
|---|---|
| Which speakers are playing | EXISTS, `DeviceState.isMainOutMember`, `Sources/AudioutProtocol/CompanionSnapshot.swift:80` |
| Start a speaker / point Main Out from the sheet | EXISTS, `MacSessionProtocol.swift:47`, `:49` |
| Microphone permission ahead of the run | EXISTS, `ProbeCaptureSession.requestPermission()` called at `AlignmentRunController.swift:171`; moving the call is phone-only |
| Play the chirps as a preview, no measurement | NEW, Mac side and one wire command. Closest existing thing is the A/B demo (`playAlignmentDemo`, `CompanionCommand.swift:80`), which plays two legs on target and reference and would need a variant that plays the sweeps once. Mac work is in `stageBTMicProbe` territory (`NativeBackend.swift:10383-10393`) |
| Settle seconds | EXISTS, `CompanionSnapshot.swift:53`, plus Fix A |

**Conflicts with the design rules:** one, and it needs a ruling. "One gold action per decision screen" (DESIGN.md overview, around line 135). A stepped page has a gold "next" on each step, which is one per screen, so it holds if each step is treated as its own screen. It does not hold if the steps are stacked on one scrolling page with several live buttons. Design the steps as pages. Second: the chirp preview must not read as a run that failed to produce a number, so it needs to be visibly a preview and not the emitter field.

**Effort:** phone M. Mac S to M (the preview). Shared S (one command case, additive, no version bump per `audiout-shared/AGENTS.md` as quoted in the phone's `AGENTS.md`).

### Concept 2 — never show a wait; show a result, then improve it

Delete the gate from the user's view entirely. Measure is always live once the room preconditions are met. If the Mac says the speaker was still settling, the sheet says so on the verdict and checks again by itself when the Mac says it has settled.

This is most of what `claude/settle-window-phone` already builds, moved from a secondary path to the default: the `measuredWhileSettling` mark, the announced and refusable re-check on the verdict page, the "Not now" out, and the row's "Check timing again".

**Step by step:** open, go to where you listen, Measure, run, verdict. Then one footnote under the verdict: the speaker had just connected, the number may drift, the phone will check again in about 30 s, with "Not now" beside it. When the Mac says settled, the sheet re-runs on its own while the verdict page is on screen. Second verdict replaces the first.

**What fills the wait:** nothing, because there is no wait before the result. The wait moves behind a result the user already has. This is the version most likely to feel like delight rather than a gate.

**Instant:** identical to today minus the disabled button. Fastest of the four.

**15 s:** the user measures immediately, gets a number, and the automatic re-check fires while they are still standing there. They see two verdicts about 20 s apart. Needs the second verdict to be worded so it does not read as the first one being wrong.

**45 s:** the user measures, gets a number, and then has to hold the sheet open for 45 s for the re-check, or accept a possibly-wrong tuning and leave. The phone branch keeps the screen awake for exactly this (`keepAwake` in the branch's `SyncSheet.swift`). This is the concept's weak point: a user who walks away keeps a tuning the Mac has marked as unreliable, and the row then says "Check timing again" indefinitely.

**Multi-speaker:** poor. Each speaker gets a first measurement fast, but each also arms a re-check that only runs while its own sheet page is showing. Tuning three speakers leaves two marked and unrechecked. The chain line moves the sheet to the next speaker, which cancels the previous one's re-check.

**States and commands:** all EXISTS on the two branches. `staleReason` is already a wire string (`CompanionSnapshot.swift:47`), the two new values are additive strings, not a new field. Mac needs the clock detector (`git show claude/settle-window-adaptive:AudioutCore/Sources/AudioutCore/BTClockStability.swift`). The owner's compensation idea (correct the early number by the observed clock delta) rests on an assumption the handoff itself says is untested, and is not counted here.

**Conflicts:** the "nothing app-initiated" rule. The re-check is the one sanctioned exception, and it is already written to stay inside it (announced first, refusable, only while the page is showing). Making it the default rather than an edge path raises the stakes on that exception. Second: "the UI never lies" cuts both ways here. Showing a confident verdict the Mac has already marked as possibly wrong is the closest any of these concepts comes to breaking that rule.

**Effort:** phone S (written). Mac M (written on a branch, unmerged, never live-tested against a Sonos). Shared none.

### Concept 3 — The owner's multi-speaker session, and why the connect order should be inverted

The owner's shape: a returning user says which speakers they want set up, those get connected one at a time so the delays can be managed, and then the phone walks them through the speakers.

**The staggering does not work, and it is worth saying plainly.** Every connect starts its own 60 s window from its own link-up (`BTAlignmentFreshness.swift:75-82`, `:141-146`), and every reconnect re-rolls that speaker's latency, so connecting one at a time serialises three windows end to end: speaker 1 measurable at 60 s, speaker 2 connected at 90 s and measurable at 150 s, speaker 3 at 240 s. Connecting all three at once overlaps the windows: all three are measurable at 60 s, and by the time the user has walked and measured speaker 1 (60 to 90 s) speakers 2 and 3 are already clear. **Connect together, measure in sequence.** The sequencing the owner wants belongs on the measurement, not the connection.

There is one real argument for staggering that I could not test: whether several Bluetooth links coming up at once make each other's settling worse. Nothing in `dev/notes/bt-spike-findings-2026-08-07.md` covers two speakers connecting together. Not verified.

**Step by step:**

1. A returning user opens the sheet from a row, or from a new door (see Concept 4). The first page is a list: every Bluetooth speaker whose published status is `notSet` or `stale`. The list already exists as a predicate (`SyncSheet.needsTuning`, `SyncSheet.swift:381-383`) and as a next-one finder (`chainCandidate`, `SyncSheet.swift:374-378`); this is that logic shown as a set instead of one at a time.
2. The user ticks the ones they want. Default all ticked.
3. One button: get them all playing. The phone selects each ticked speaker and, for any that is disconnected, asks the Mac to connect it. All at once. This is where the wire gap is (fact (f)).
4. While they come up, the page is the honest status of each one: connecting, playing, ready to measure, still settling. Nothing counts down; each row says where it is. This is the one place a per-speaker settle number is genuinely useful, because the user can see that waiting for one is not waiting for all.
5. **"Go to where you listen."** Once at least one speaker is ready, the walk step. Same page as Concept 1's step 4.
6. Measure speaker 1. Verdict. "Next: Kitchen." Measure speaker 2. And so on, without leaving the sheet.
7. One closing page: what was set and by how much, with "Hear it".

**What fills the wait:** picking the set, watching the speakers come up (which is real state, not a progress bar), and the walk. For a two-speaker room the picking and the connecting genuinely cost 20 to 40 s.

**Instant:** the list page is pure overhead for someone tuning one speaker. This concept must not be the door for a single speaker; the tuning fork on a row must still go straight to that speaker's sheet.

**15 s:** step 4 shows one speaker still settling and the rest ready. The user starts on a ready one. By the time verdict 1 lands the other is clear. The wait is invisible.

**45 s:** the same, and this is where the concept pays. 45 s of window is spent picking, connecting and walking, and the user measures the moment they arrive.

**Multi-speaker:** this is the concept.

**States and commands:**

| Need | Status |
|---|---|
| Which speakers would benefit | EXISTS, `SyncSheet.swift:381-383` over `DeviceState.alignment.status` |
| Per-speaker settle seconds and stale reason | EXISTS, `CompanionSnapshot.swift:47`, `:53`, plus Fix A |
| Select several speakers / point Main Out | EXISTS, `MacSessionProtocol.swift:47`, `:49` |
| **Connect a disconnected Bluetooth speaker from the phone** | **NEW, wire and Mac.** `retryConnection` reaches `GroupController.retryConnection(for:)` (`CompanionCommandDispatcher.swift:192-193`), which for an unselected device only selects it (`GroupController.swift:460-472`). The membership-free connect is `GroupController.requestReconnect(for:)` (`GroupController.swift:481-483`) and nothing on the wire reaches it. Needs one additive command case and a dispatcher arm |
| Phone UI for an unavailable row | NEW, phone. Unavailable rows are inert by design (`DeviceRowView.swift:274`, `:289`), so this affordance lives inside the sheet's list page, not on the Speakers rows |
| One run at a time | EXISTS and enforced Mac-side (`BTAlignmentFreshness.swift:149-152`); the sequence must respect it |

**Conflicts:** two. "The sheet is one place; the Speakers rows stay exactly as they were unless a speaker is untuned" is fine, since all of this lives in the sheet. But "nothing app-initiated" needs a ruling: connecting four speakers on one tap is user-initiated, yet it makes speakers in other rooms start playing, which is a bigger physical consequence than anything else in the app does on one tap. It needs to say what it will do before it does it. Also the closing summary page is a fifth sheet state, and the sheet is already six.

**Effort:** phone L. Mac S (one dispatcher arm onto an existing method). Shared S (one command case).

### Concept 4 — move the door earlier, and take it off the places it does not belong

Not a wait-filler; a re-sequencing. The cheapest way to make a 60 s window invisible is to start it 60 s before the user wants to measure.

**Where the door should also be:**

- **Inside the group editor, before the group is saved.** The invite card fires after the save (`GroupEditorView.swift:258`). Moving a quiet line into the editor — "the Kitchen's timing isn't set; tune it after you save" — costs nothing and spends the naming, member-picking and icon-picking time, which is 15 to 40 s of window.
- **On the Main Out picker, at the moment of pointing.** Same idea, from `MainOutPicker.swift:136-142`.
- **On the verdict's chain line**, which already exists (`SyncSheet.swift:338-352`) and is the best-placed door in the app because the next speaker's window has already expired.

**Where the door should not appear, and mostly already does not:**

- Not on a tuned row. Already true and already a written decision (DESIGN.md around line 1090).
- Not while the speaker is unavailable, connecting or reconnecting. Already true (`DeviceRowView.swift:769-770`).
- Not when there is no reference. Today the sheet opens and then dead-ends on "Needs another speaker playing" (`SyncSheet.swift:206`). The door should be absent rather than open onto a refusal.
- Not more than once per speaker for the invite card. Already true (`SyncInviteCard.swift:65-73`).
- **Not a second time in a session after the user declined.** The invite card remembers; the row glyph does not, and cannot, because it is a state word rather than an offer.

**Instant / 15 s / 45 s:** this concept does not change what the wait looks like, it changes how much of it is left when the user arrives. On its own it shaves 15 to 40 s off the group-saved scenarios and nothing off the reconnect scenarios.

**Multi-speaker:** neutral.

**States and commands:** all EXISTS. Phone-only.

**Conflicts:** none I can see. The invite card's own doc rule is that it renders only from state the user's own action created (`SyncInviteCard.swift:10-15`); a line inside the group editor is created by the same action, one step earlier.

**Effort:** phone S. Mac none. Shared none.

---

## 3. Ranked pick

**Fix A and Fix B first, then Concept 1, with Concept 4 folded in, then Concept 3, then Concept 2.**

**Fix A before anything.** A user who waits 40 s past the end of the Mac's own window is being lied to by a number, and no amount of screen design fixes that. It is a small Mac change and it makes every concept below honest. **Fix B is the ruling that decides whether the feature protects anyone at all**: today the very first tune of a newly paired speaker, which is the most chaotic clock in the product, has no gate.

**Concept 1 is the pick.** It answers the owner's actual complaint — an empty screen with one CTA — with steps that are all real work, so it does not break "the UI never lies" or invent state. It needs no Mac change beyond the chirp preview and no wire change beyond one command. It survives whatever happens to the settle number: if the adaptive detector or the compensation later kills the wait entirely, the steps are still worth having, because two of them (microphone ahead of the run, both speakers confirmed playing) remove real failure modes that exist today. And it fixes the mid-run microphone prompt, which is a first-run bug in its own right.

**Concept 4 ships with it** because it is small, phone-only, and it is the only thing on the list that reduces the wait rather than dressing it.

**Concept 3 second, with the connect order inverted.** It is the right answer for the returning user the owner described, but it is the largest piece of work, it needs a new wire command, and it is only worth building once single-speaker tuning feels good. Build it as a second door, never as the door.

**Concept 2 last, not because it is wrong but because it is furthest from proven.** Its Mac half is unmerged and has never met a real Sonos; its best version depends on an assumption the handoff explicitly says is untested. Its "measure now, fix later" instinct is right and is already partly built on the phone branch — keep that as the escape hatch inside Concept 1's last step, which is exactly where the phone branch already puts it.

**On Mac and phone parity.** The Mac's by-ear wizard has no gate at all — no reference to `settleSeconds`, `settleRemainingSeconds` or `lastConnectedAt` anywhere in `AudioutCore/Sources/AudioutPopoverUI/`. So the same speaker can be tuned instantly from the Mac and not for a minute from the phone. That is defensible: the Mac's wizard asks a human "which clicked first?" about fifteen times over roughly a minute, so a clock that drifts during it shows up as answers that will not settle, and the wizard already has copy for that (`BTAlignmentWizardView.swift:97-99`). The phone takes one 10 to 20 s reading and keeps the number. The method really is more fragile, not the speaker.

**That decides the phone's wording.** The phone must not say "this speaker isn't ready" — that is a claim about the speaker which the Mac's own wizard contradicts on the same screen-full of hardware. It should say what is true of this measurement: it listens once, and it needs the speaker's clock to hold still for that one listen. Something in the shape of "the Kitchen just connected and its timing is still moving. One quick listen needs it to hold still. About 20 s." If Fix B adds a gate to the Mac wizard too, that changes and the speaker-centred wording becomes honest. Until then it is not.

---

## 4. Three questions only the owner can answer

**1. First pairing and post-launch first tune have no settle window at all today (fact (a)). Bug or intended?**
Fixing it adds a wait where there is none, including to the very first speaker a new customer ever tunes, which is the worst possible place to put one. Leaving it means the feature does not protect the case the spike measured. Either answer is defensible and the concepts above branch on it.

**2. Should the Mac's own by-ear wizard get the same gate?**
Right now it has none. If it stays ungated, the phone's copy has to describe the measurement's own fragility, never the speaker's readiness, or the two surfaces contradict each other in the same room. If it gets one, the phone can say the simpler and more natural thing.

**3. For a paying stranger, which is the worse outcome: a stored tuning that is silently wrong by tens of milliseconds, or 45 s of waiting?**
This is the whole ranking. If the wrong number is worse, the wait is a real gate and Concept 1's steps are the right way to spend it. If the waiting is worse, Concept 2 is the pick and the early measurement stops being an escape hatch and becomes the default. Nothing in the code can decide this.

Bonus, if there is room: may the sheet start a speaker playing that the user has not selected, on one tap, from another room? Concepts 1 and 3 both need it, and it makes noise somewhere the user is not standing.
