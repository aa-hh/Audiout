# Shared brief: the sync sheet's waiting state (iPhone companion)

Read this whole file before doing anything. It is the ground truth; the code paths at the end are for verification and detail.

## The product in two lines

Audiout: a Mac menu-bar app that sends all system audio to many AirPlay 2 and Bluetooth speakers in sync. A paid iPhone companion (SwiftUI, "audiout-remote") remote-controls the Mac and carries the one thing the Mac cannot do: a microphone. The phone's **sync sheet** measures how late a Bluetooth speaker plays versus another speaker (the "reference") by having the Mac play chirps while the phone listens from the listening position, then tells the Mac the correction. It is the product's answer to Bluetooth speakers being out of step with AirPlay speakers.

## The problem the owner stated (verbatim)

> audit the waiting state in the sync wizard as we wait for the connection to stabilize. At the moment, it's just text-heavy and an empty screen with a single CTA that gives you the option to pass through if you feel like it. But most users have no understanding as to what exactly it is they need to wait for and the benefit of waiting, their interest is playing their speakers now, syncing it now. They don't really want to understand that there's variance until the connection settles. Nor will they have necessarily the patience for it. So we need to introduce essentially an experience that gives them a feeling of control while we wait for what we need to settle down so that we can give them that control.
>
> What comes to mind is an almost artificial gate of introducing them to how the system works, what it does. And pushing them towards ensuring they're in an optimal position for the test, or if they've done it before have them essentially define which speakers they want to set up so that all get connected one at a time, so we can start to kind of manage the delays and then we get them through the speakers after they've gone through that process. I don't know. I think we really need to do some divergent discovery here because what we have is just unintuitive and overly complex. And will not be a moment of delight for users because they have to wait 60 seconds for something they do not know why they have to wait for.

## What the wait actually is (engineering truth)

- When a Bluetooth speaker's link comes up (user reconnects it, the OS relinks it after a power cycle, first pairing), the speaker's Bluetooth stack re-buffers for a while. During that time its audio clock jumps around. A measurement taken then measures the jumping, not the speaker, and stores a latency that can be wrong by tens to hundreds of ms. That is **worse than no calibration** because the number looks plausible and is kept.
- Measured (dev/notes/bt-spike-findings-2026-08-07.md, "Pacing-clock probe"): **Sonos Move 2: 0–42 s chaotic**, 32 clock re-anchor jumps, net shift about −353 ms, then pinned to ±0.01 ms. **Sony WH-1000XM3: zero jumps, settled from second one.** The settling window is strongly brand-dependent. Nobody knows the distribution across the speakers users own.
- Bluetooth latency is **per connection, not per device**: every reconnect re-rolls it (one day −410 ms, next day ~46 ms). So a stored tuning goes stale on every reconnect, and the Mac marks it "stale, reason: reconnected". After a mid-stream disruption the latency can also walk over minutes (17→61→86 ms).
- **Today on main:** a fixed 60 s countdown from link-up (`BTAlignmentFreshness.settleSeconds = 60`). The Mac publishes `settleRemainingSeconds` on the wire; the phone counts it down locally. The phone is the only consumer. **The Mac's own alignment wizard (the by-ear one in the popover) has no gate at all** — the same speaker can be measured at once from the Mac and not for a minute from the phone.
- **Unmerged Mac branch `claude/settle-window-adaptive`** (commit 0465183f): adds `BTClockStability`, a detector that watches the speaker's pacing clock and reports when it has gone 10 s without a jump. The 60 s floor still holds until the detector has evidence; a clock that settles early clears the window early; one still jumping past 60 s keeps counting. A measurement applied while still settling is marked `measuredWhileSettling`; a chunky clock step after alignment marks it `moved`. Both are stale reasons on the wire so the phone can ask for a re-check. **Read this critically: as written, the floor means a Sony still waits up to 60 s unless the detector clears it sooner — check `BTAlignmentFreshness.swift` on that branch for what "evidence" means.**
- **Unmerged phone branch `claude/settle-window-phone`** (commit 65a1dbc): the Measure button waits on the Mac's clock verdict rather than a timer; a footnote says why and roughly how long; a gold "Measure it now" line lets the user measure early; an early measurement is marked and the sheet re-checks automatically once the Mac says the speaker settled (announced on the verdict page, refusable with "Not now", only while that page is on screen); the row says "Check timing again"; a light haptic when the button goes live; screen kept awake while counting/running. The owner has most likely seen a build of this or of main; their "single CTA that gives you the option to pass through" is that "Measure it now" line or the "Adjust by ear" link.
- The settle number the Mac sends is its own estimate of seconds left, sent when it changes; the phone ticks it down between snapshots. `nil` means settled.
- A measurement run takes roughly 10–20 s: phases "Hearing the room" → "Chirping" → "Letting it land" → "Measuring". Music must be playing on both speakers during it (the chirps ride on the feed). The phone measures the room from where it stands; standing beside a speaker gives a wrong answer.

## The current phone screen (what the owner is reacting to)

The sync sheet (`SyncSheet.swift`) has pages: placement → run → verdict → fine-tune, plus refusal and microphone states. Entered from: the row's `tuningfork` glyph (only on untuned/stale Bluetooth rows), the row's long-press "Tune…", and an invite card after the user saves a group or points Main Out at one. After a verdict, one line offers the next untuned speaker ("X isn't set either — tune it next?").

Placement page today (main):
- Title: "Go to where you listen."
- Body: "You should hear both the {target} and the {reference} from there. The phone measures the room from where you're standing — beside a speaker it gets the wrong answer."
- (spacer, empty screen)
- Optional blocker footnote: "Needs another speaker playing." / "Play it first — the room has to hear both speakers."
- Gold CTA: "Measure", or disabled reading "Ready in 47s" while the window is open.
- Beside it a plain gold-text link: "Adjust by ear".

On the phone branch the disabled button becomes a footnote explaining the settling plus a gold "Measure it now" line for measuring early.

Run page: the site's emitter field (concentric rings radiating from two emitters, in the green ramp) fills the screen; still while only listening or thinking, moving while sound is in the room; one micro-label phase word; a Cancel link. Verdict: two rings converging into register, one plain sentence ("Kitchen was trailing. Fixed." / "Kitchen is in step."), gold "Hear it" (A/B demo), "Adjust by ear", ms behind a "Details" disclosure, chain line to the next untuned speaker.

## What the phone can see and do (state and commands)

Snapshot per device: id, name, Bluetooth or not, sounding or not, selected/routed, `alignment {status: notSet|tuned|stale, staleReason, referenceID, settleRemainingSeconds}`. Also: groups, Main Out target, mic permission (local). Commands: start probe, tick on/off, nudge trim ±5 ms, revert, clear tuning, play A/B demo, cancel; plus the ordinary remote commands (select speakers / route Main Out / volume / mute / groups). The phone **renders state and never computes it**: staleness, reference choice and the settle window all come from the Mac. Any new fact the phone shows needs a Mac-side source and a wire field (additive fields are cheap; `audiout-shared` is the shared protocol package, MIT).

## Design rules that bind (from the phone's DESIGN.md and PRODUCT.md)

- Warm Signal: cool near-neutral chassis; warmth only where sound is going; **gold has two jobs only: audio state and calls to action**; one gold action per decision screen.
- **Green is allowed only as the Settings wire lamp and inside the sync sheet** (the run page's emitter field and the verdict rings, drawn from the site's "Movie night" ramp). Green never on rows, never type, never flat fill.
- **Plain speech for anything the user acts on**; console flavour only on fixed chrome. No jargon carrying a decision. Bare numbers over named presets.
- **The UI never lies**: no fake progress, no invented state, no promise the Mac can't keep. Refusals say the Mac's own reason.
- **No red and no failure styling anywhere in the sync sheet.** Every non-measurement ending is a result plus a way past (the by-ear page).
- **Nothing app-initiated**: no notifications, no banner on a timer or on a connection, no run the user did not start — the one sanctioned exception is the announced, refusable re-check on the verdict page.
- Reduce Motion honoured (emitter field holds still); Dynamic Type; 44 pt touch floor; VoiceOver parity with visible state.
- The sheet is one place; the Speakers rows stay exactly as they were unless a speaker is untuned.
- Terminology: "Main Out", "groups", "speakers", "tuning"/"timing" for the Bluetooth alignment. Never coin new product terms in your write-up — describe mechanisms in plain words; refer to your concepts as Concept 1/2/3.

## Writing rules for your report

Plain words a non-specialist understands; no invented names for things (no "the Handoff Layer" style capitalised coinage, no acronyms of your own); concrete over abstract; short sentences; no em dashes; no hype words. Cite files with path:line when you assert what the code does. Say "I could not verify" where you could not.

## Code and notes to read (read-only; never edit, never build, never check out a branch)

Phone repo, main checkout: `~/Projects/audiout-remote/`
- `AudioutRemote/UI/Sync/SyncSheet.swift` (the whole sheet), `AudioutRemote/UI/Sync/SyncInviteCard.swift`
- `AudioutRemote/Model/AlignmentRunController.swift` (run phases, refusals, copy)
- `AudioutRemote/UI/Speakers/DeviceRowView.swift` (row glyph, alignment word, ~lines 455–480 and 750–810), `AudioutRemote/UI/Speakers/SpeakersView.swift` (what the phone can select/route)
- `DESIGN.md` lines 120–175 (overview), 308–338 (green), 978–1004 (haptics), 1079–1141 (decision record + sync surfaces), 1141–1204 (do/don't)
- Phone branch, via `git -C ~/Projects/audiout-remote show claude/settle-window-phone:AudioutRemote/UI/Sync/SyncSheet.swift` and `git -C ~/Projects/audiout-remote diff main claude/settle-window-phone -- DESIGN.md`

Mac repo, this worktree: `~/Projects/AirPlay Controller/.claude/worktrees/sync-wizard-waiting-ux-b93148/`
- `dev/notes/handoff-2026-09-03-settle-window-adaptive.md` (the full problem statement and the owner's own engineering proposal)
- `dev/notes/bt-spike-findings-2026-08-07.md` (search "Pacing-clock probe")
- `AudioutCore/Sources/AudioutCore/BTAlignmentFreshness.swift`, `AudioutCore/Sources/AudioutCore/CompanionSnapshotBuilder.swift` (~line 200–260)
- Mac branch: `git show claude/settle-window-adaptive:AudioutCore/Sources/AudioutCore/BTClockStability.swift` and `git show claude/settle-window-adaptive:AudioutCore/Sources/AudioutCore/BTAlignmentFreshness.swift`
- `PRODUCT.md` (users, principles, voice)
- The Mac's own by-ear wizard for voice parity: `AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift` (copy constants near the top) and its look: `dev/notes/wizard-v2-handoff/1-intro-dark.png`, `3-question-mid-dark.png`, `6-kept-dark.png`
- Wire struct: `~/Projects/audiout-shared/Sources/AudioutProtocol/CompanionSnapshot.swift` (~lines 40–70)
