# Sync sheet waiting state: discovery synthesis (2026-09-04)

Four research lenses (precedent, product flow, the moment itself, honesty/feasibility) plus a Bluetooth-competitor sweep. Every code claim below was re-checked against the two repos by me, not taken from the agents.

## 1. The wait is not what the brief assumed

| Claim in the brief | What the code says |
|---|---|
| Users wait 60 s | On the unmerged Mac branch (`claude/settle-window-adaptive`) the clock detector's verdict is checked before the 60 s floor. A speaker that never jumps (Sony class) goes live about 11 s after music starts; a Sonos Move 2 about 53 s. But the number on screen opens at "about 60 s" for every speaker, because the detector needs 10 quiet seconds before it can say anything. The screen promises five times the usual wait. |
| The countdown is the Mac's number | The Mac broadcasts a snapshot only on events, never on a timer. The phone seeds its countdown from whatever snapshot it holds. Open the sheet 45 s after connecting and the phone can show the number from a snapshot sent at 5 s and count all of it down again. Up to a full minute of wait that the Mac's own window has already closed. This alone may be most of what the owner felt. |
| The window protects the chaotic case | It only starts on a link edge the running Mac process watched. A speaker paired for the first time, or any speaker already connected when the Mac app launched, gets no window at all. That is the case the Sonos was measured jumping for 42 s. |
| The number counts down | It can go up: when the floor expires the detector's own count takes over (jumps from 0 to 10), a jump past 60 s republishes, a reconnect restarts at 60. The phone branch re-seeds up or down on purpose. |
| The Mac gates the measurement | The Mac never refuses an early measurement. The gate is entirely the phone's rendering. |
| "Adjust by ear" is a safe pass-through | The by-ear slider is reachable during the whole wait, and the Mac writes back whatever trim the tick session was holding when it ends. A user can store a number tuned against a moving clock, by the exact path the window exists to prevent. Correctness hole in the shipped sheet. |
| The run just needs the user to tap | The microphone permission is requested inside the run. A first-time user gets the system prompt mid-run and a refusal page instead of a measurement. |
| Connect speakers one at a time to manage delays | Windows are per speaker and run in parallel. Connecting one at a time serialises them (speaker 3 measurable at four minutes). Connect together, measure in sequence: by the time speaker 1 is walked to and measured, the others are clear. And the phone cannot connect a disconnected Bluetooth speaker today; that needs a new wire command. |
| The detector watches the speaker | It samples only while the speaker's audio engine runs. A connected but silent speaker accrues no evidence and serves the full 60 s. The sheet's own "play it first" precondition already covers this, but no waiting screen may tell someone to put the phone down and come back. |

Also true: the phone can run a measurement and not report it (cancel instead of report), so an honest "did the phone hear both speakers from here" check is phone-only work. The phone cannot tell "beside a speaker" from "at the seat"; ProbeKit says so in its own contract. "Both speakers found" is the only honest position claim.

## 2. What precedent says

- Every calibration ritual (Sonos Trueplay, Bose ADAPTiQ, Audyssey, Dirac, Apple spatial audio scan) fills the moment before measuring with a physical act, never with explanation. Our placement page puts about forty words of prose before anything to do, more than any of them.
- Nobody made calibration feel instant. They made it a procedure with a known, stable length quoted up front (Sonos "about 3 minutes", Bose "allow ten"). Ours is 0 to 60 s and unknowable until over. That, not the duration, is the real difference.
- Nobody runs an unattended queue across rooms, because the measurement needs a human standing somewhere specific. Choosing scope up front is fine; automation is not. Our own "nothing app-initiated" rule agrees.
- Explained waits feel shorter, occupied waits feel shorter, a marked ending turns an open wait into a finite one after the fact (Maister; Buell and Norton's labor illusion; Harrison's progress-bar work).
- Against the owner's framing: nothing supports an artificial gate. Sonos's flip, noise sample and technique video all bear load. Ceremony that is really procedure is fine; ceremony for its own sake is a lie by pacing, and on a speaker that settles in 11 s it invents a wait that does not exist.
- **No consumer product gates a measurement on a Bluetooth link settling**, or even tells the user to wait for one (27 products checked: Apple TV Wireless Audio Sync, Roku, AmpMe, Google Home, WiiM, Airfoil, SoundSeeder, Snapcast, Roon, Sonos, JBL, UE, Bose, Sony, Samsung, Auracast, Denon, TuneBlade). The only precedent for showing link readiness is professional audio networking: Dante Controller puts a green/red clock lamp on every device and engineers read the column before doing anything. So our gate has no consumer precedent to copy, and one professional precedent for showing readiness as a per-speaker word.
- Borrowable moves from that sweep: a readiness word per speaker instead of a paragraph (Dante); a short wait attached to the speaker the user just touched reads as the machine doing what they asked (Samsung Sound Tower documents "wait 15 seconds" per added speaker); say the measurement is cheap and repeatable so measuring early stops being a gamble (Roku: "perform it a few times"); give the by-ear page a find-the-direction-first procedure (Google Home, SoundSeeder); put the one-sentence theory next to "Check timing again", not in front of the button.
- Settling evidence outside our two speakers is thin and long-tailed: an Apple developer measured AirPods latency falling from ~220 ms to ~160 ms over 20 to 30 minutes after connecting; SoundSeeder's docs say most speakers re-roll 20 to 70 ms on every playback start. Nobody has a distribution. Two consequences: the wait cannot promise permanence, so the row's "Check timing again" and the A/B "Hear it" are the real safety net; and the multi-speaker list must show each speaker's own state, because their waits differ.

## 3. Recommendation

Three phases. Phase 0 makes any screen honest; without it every concept decorates a wrong number. Phase 1 is the screen. Phase 2 is the owner's multi-speaker idea, corrected, and gated on evidence.

### Phase 0: make the number true (Mac + wire, all small)

1. **Kill the stale countdown.** While any speaker's window is open, republish the settle number on a cadence (one to five seconds), or publish a deadline the phone subtracts from. Today the phone can count down a number that expired long ago.
2. **Never show "about 60 s" to a speaker that will be ready in 11.** Add one additive wire boolean: has the detector actually seen this clock jump since link-up. Inside the first ten seconds the Mac has no verdict, and the phone must be able to say "getting ready" rather than name a minute it invented. A number appears only once the Mac has a real one (the detector's own count past the floor, or a jump it watched).
3. **Decide the first-pairing case.** Today a first pairing and any speaker already connected at Mac launch get no window. That is the most chaotic clock in the product, unprotected. Adding the window there adds a wait to the very first tune a new customer ever does; on the adaptive branch that wait is about 11 s for a clean speaker. The owner's call.
4. **Lock the by-ear slider while settling** (phone only). Revert and Clear stay reachable; the slider waits, with one line saying why.
5. **Move the microphone prompt ahead of the run** (phone only). One screen, one gold button, only when permission is undetermined. Removes a first-run failure and spends a few seconds of the window on something that had to happen anyway.

### Phase 1: the screen becomes a short sequence of real acts (phone only)

One thing per screen, each a thing the user does, each load-bearing for the measurement, paced by the user's own taps. The Measure button lives at the end and is live or not, exactly as today. On a clean speaker the sequence takes longer than the settle, so the user never sees a wait. On a Sonos they arrive at the last screen with about twenty seconds left, having spent the rest walking and listening.

- **A. "Both speakers need to be playing."** Shown only when the Mac's precondition is unmet. Names which one is silent, and the gold button fixes it (the phone can select a speaker and point Main Out today). Today this is a footnote under a dead button.
- **B. "Audiout needs to hear the room."** Shown only when the microphone permission is undetermined. One gold button, then the system prompt.
- **C. "Take the phone to where you listen."** One line under it: "Not next to a speaker. Where you actually sit." Gold button: "I'm there." Nothing gated here; only the user knows when they have walked.
- **D. "Can you hear both from here?"** The Mac's existing metronome clicks on both speakers as this screen appears (the same command the by-ear page already starts on appear). Two neutral chips: "Both" and "Only one". "Only one" shows "Move somewhere both reach you, or turn the quiet one up. The clicks keep going." No timer, no advance. This is the honest position check, and it is also where the user hears the problem: two clicks that land apart are the thing about to be fixed. Nothing is stored.
- **E. "Hold still."** "You'll hear two quick sweeps over the music. Stay quiet while they play." Gold "Measure". While the speaker is still settling the button is not live and one line sits above it, without a number until the Mac has a real one: "Getting the {name} ready. A few more seconds." Once the Mac has watched the clock jump past the floor: "The {name} is still settling after connecting. About 10 s from the last wobble." The gold-text "Measure it now" escape appears only in that earned case, never on the 11-second path. The clicks keep going until the button goes live; their stopping, the fill turning gold, the light haptic and the VoiceOver line are the one "it happened" moment. Optional and cheap: a small framed emitter field behind this screen, two emitters in separate families while settling, falling into lock-step on the Mac's verdict; still frame under Reduce Motion; the word under it carries the state.
- **Run, verdict, "Hear it": unchanged.** The chain line to the next untuned speaker skips C and D (the user has not moved) and opens on E.

What this answers: the owner's "empty screen with a CTA" (five acts, none empty), "no idea what they're waiting for" (the clicks make the problem audible before the word "settling" ever appears), "feeling of control" (every screen advances on their tap and their ears, and the walk they had to do anyway is the wait). What it refuses: fake progress, a countdown to an unknown, a screen that flashes and vanishes, a run nobody started, a second gold button.

### Phase 2: the multi-speaker session, corrected (phone L, Mac S, wire S)

The owner's returning-user idea, with the connect order inverted. A list door reached from the invite card after a group is saved or Main Out is pointed at a group: every Bluetooth speaker whose published status is not set or stale, ticked by default. One gold button gets them all playing at once (needs a new wire command so the phone can ask the Mac to reconnect a disconnected speaker; today it can only select connected ones). While they come up, each row shows its own honest state: connecting, playing, still settling, ready. Then screens C and D once, then E per speaker, advancing only on the user's tap, with "Next: {name}" between them. Never the door for a single speaker; the row glyph still goes straight to that speaker.

Gate it on one fact nobody has: how many Bluetooth speakers a buyer owns. With one, the list is dead weight.

### Also worth doing, cheap, adjacent

- The verdict for a measurement the Mac marked as taken while settling says "a first reading" and that the phone will check again, never "Fixed." (Roku's framing: the measurement is cheap and repeatable.)
- The by-ear page gains one instruction of the find-the-direction shape: slide well over one way, then the other, keep the side where the two clicks got closer, then work in small moves. No numbers, no new state.
- The one-sentence theory (a Bluetooth speaker picks a fresh delay every time it reconnects, so the old number no longer fits) moves to the "Check timing again" moment, off the placement page.

### Dropped, with reasons

- **Measure-early as the default.** The stored number is wrong and audible for minutes; the verdict says "Fixed." next to a line saying it may move; the automatic re-check needs the verdict page on screen, which is exactly the user who would not wait; it doubles the chirps in the room. Keep it as the earned escape in screen E, and change the verdict sentence for a marked number so it stops claiming a fix.
- **A live graph of the clock jumping.** Technically possible with a new wire message; editorially wrong. A picture of the speaker misbehaving that the user can do nothing about.
- **Phone in your pocket, we tell you when it is done.** No background audio mode, no notifications (by rule and by code), and a pocket measures a pocket.
- **Tips and explanation to read.** That is the current screen's failure, more of it.
- **Staggered connecting.** Serialises the waits.
- **The Mac's own wizard gets the same gate.** It asks a human "which clicked first" fifteen times over a minute, so a drifting clock shows up as answers that will not settle, and it already has copy for that. The phone takes one 15 s reading and keeps it. The method is the fragile thing, so the phone's wording describes the measurement ("one quick listen needs the timing to hold still"), never the speaker's readiness. Two surfaces in one room must not contradict each other.

## 4. Decisions only the owner can make

1. For a paying stranger, which is worse: a stored tuning that is silently wrong by tens of milliseconds for a few minutes, or up to fifty seconds of waiting? This is the whole ranking. Recommendation: the wrong number is worse, so measure-early stays an escape hatch, not the default.
2. May the sheet make a sound in the room once the user has tapped "I'm there"? The by-ear page already starts clicks on appear. Recommendation: yes, the tap is the consent.
3. First pairing and the first tune after a Mac launch: add the window (protects the most chaotic case, costs about 11 s on a clean speaker) or leave them ungated? Recommendation: add it.
4. Build the multi-speaker list now, or after single-speaker tuning has been live-tested on real speakers? Recommendation: after.

Assumed unless overruled: the Mac wizard stays ungated and the phone's copy describes the measurement, not the speaker; the walk-through (C and D) runs once per sheet and the chain skips it; the design assumes the wait exists, and if the clock-delta compensation experiment later removes it, screens A to D still earn their place because they fix placement, playback and the microphone prompt.

## 5. Evidence

- Agent reports: `research/precedent.md`, `research/flow.md`, `research/moment.md`, `research/honesty.md`, `research/bluetooth-precedent.md`.
- Mac: `AudioutCore/Sources/AudioutCore/BTAlignmentFreshness.swift` (main and `claude/settle-window-adaptive`), `BTClockStability.swift` (branch), `NativeBackend.swift:3846`, `:8414`, `:8434-8449`, `AppDelegate.swift:2535-2544`, `CompanionSnapshotBuilder.swift:236-250`, `dev/notes/handoff-2026-09-03-settle-window-adaptive.md`, `dev/notes/bt-spike-findings-2026-08-07.md`.
- Phone: `AudioutRemote/UI/Sync/SyncSheet.swift` (main and `claude/settle-window-phone`), `Model/AlignmentRunController.swift:171-174`, `DESIGN.md` "The sync surfaces", `GroupController.swift:460-483` (Mac).
