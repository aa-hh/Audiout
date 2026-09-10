# Shape brief: the phone's first launch

*2026-09-06. Impeccable `shape` with `onboard` and `animate` guidance, iOS platform reference loaded. Surface: Audiout Remote from first launch to the first screen of the shell. Mode: Operate, with a Persuade opening (the three intro cards). No code written. Every file fact below was read in source this session; line numbers are from `audiout-remote` at the plan's branch unless a path says otherwise.*

Covers plan decisions D2, D5, D6, D8 and tasks T5, T6, T8, plus the gesture coach on Speakers. Nothing in the sync sheet.

Assumptions are marked "assumed" inline and gathered again at the end. No interview was possible, so each is a call the builder should not silently overturn.

---

## 1. Job and audience

Two people arrive at this screen.

The Mac-first buyer (D2). Owns Audiout on the Mac, opened the store link from the licence email, the Mac's Settings pane, or the untuned-speaker chip. Knows what Audiout does. Wants the phone on the Mac in under a minute. Has probably never measured a speaker and does not know the phone can.

The cold downloader. Found Audiout Remote in the App Store or through the site's `/remote` page. May not own the Mac app. Needs to learn in one line that the phone does nothing without it, and needs somewhere to go when no Mac turns up: the demo.

Both are standing up, phone in one hand, at home. The Apple reviewer is a third reader with no Mac at all; the demo exists for them (D6) and for the cold downloader.

Mode: Operate. The cards are the one Persuade beat, and they are skippable.

## 2. Outcome and proof

The moment that proves the app: the Mac's name turns gold on the phone with the word Connected above it, the phone taps once, and the speakers list appears already earned. Time to that moment for a Mac-first buyer with the Allow switch already on: three taps (Next, Next, Find my Mac), one system prompt, one click on the Mac.

Second outcome, for the demo path: the user is looking at six pretend speakers within two taps of the checklist appearing, and every screen says so.

What the surface must carry that a generic onboarding could not:

- The lead claim (D3): the phone measures. The third card says it, and it is the only card the differentiator lives on.
- The requirement (D2): this app needs Audiout on your Mac. The first card says it plainly, so the Local Network prompt and the searching junction land on a reader who knows why.
- The demo is labelled on every screen (D6) and is offered, never forced. The house rule in `RootView.swift:15-18` holds: demo is opt-in only, never a fallback.

## 3. Selected direction

Visual authority is `DESIGN.md` as it stands. Nothing here changes the palette, the type voices, or the gate's rules: one junction at a time, one gold action, the field is the screen and not a panel on it. The intro reuses the primer's own parts (`AppIconMark`, `JunctionCopy`, `IntroField`, `GoldGlassAction`, `QuietAction`) and the demo entry reuses the row already built under `#if DEBUG` (`ConnectGateView.swift:381-429`).

The structural thesis, in order:

1. One room, three sentences. The field and the app mark are the stage and never move. Only the copy pages. Three cards do not mean three screens; they mean one screen said three ways, which is what keeps the field calm: it never re-enters, never reacts to paging, and the eye has one thing to track.
2. One button, three labels. The bottom-pinned gold capsule stays where the thumb is and reads Next, Next, then Find my Mac. The way in is the button the thumb is already on. Skip on cards one and two is the gate's quiet action, top trailing, and it goes straight to the same place Find my Mac does.
3. The demo is a row, not a mode switch. It appears under the checklist at 8 s, styled as the Mac list's rows are styled (a gate panel you tap), and never on the intro.
4. The connected moment is the field arriving somewhere. Everywhere else the rings leave a speaker. On arrival they run the other way and close on the Mac's name, and the phone taps once as they land. It is the phone's counterpart to the Mac licence window's `surge()` (`EmitterFieldView.swift:250-257` in the Mac repo): the same field, one authored beat at the success moment, but a convergence rather than a swell because on the phone there is a named thing to arrive at.
5. The Demo pill is a strip above the shell, not a badge inside one tab. One implementation, four tabs, and it holds the offer of the real Mac when one appears.

The focal moment is the arrival. Nothing else on this surface gets authored motion.

Implementation consequence: the primer junction (`ConnectGateView.swift:198-212`) becomes a pager whose pages are `JunctionCopy` blocks; `IntroField` and `AppIconMark` lift out of the page; the `#if DEBUG` around the demo row and around `enterDemo` drops; the arrival junction (`:256-261`) gains a field behind it for 550 ms; `RootView`'s shell gains a top safe-area inset holding the Demo pill.

## 4. Scope and boundaries

In scope: the intro cards; Skip, Next and Find my Mac; the demo row's release appearance and copy; the Demo pill and the Your Mac is here offer in the shell; the arrival junction's rings and haptic; the gesture coach's verdict.

Untouched: the other ten junctions' copy and layout; `SearchWaves`; the checklist's three steps; the Settings tab; the tab bar; the sync sheet; the coach's visibility rule (`SpeakerCoach`, `DeviceRowView.swift:964-990`); every shared knob in `field.json`.

Anti-goals:

- No tour, spotlight, or modal after the cards. The coach stays inline.
- No claim on the cards the app cannot show: no speaker counts, no "no other app", no latency numbers.
- No gold on the cards except the one capsule. Page dots, Skip and the mark carry no gold.
- No new haptic family. One new event, the connect, in the existing `.impact` vocabulary.
- No hand-drawn rings. The arrival draws the shared field or nothing.
- The demo never enters by itself, never on the intro, never on the Switch Mac sheet.

Fidelity: production screens, one flow, on the phone's existing components.

## 5. States and ranges

Intro. Three pages. Dynamic Type from default to accessibility 5: at accessibility 1 and above the field stands down (existing rule, `ConnectGateView.swift:51-54`) and each page's copy scrolls on its own; the capsule keeps its `minimumScaleFactor(0.6)`. Reduce Motion on and off. Light and dark (the field lifts on paper through `paperLift`, already handled). VoiceOver: each instruction is a header (existing trait), the page control announces "page 1 of 3", Skip and Next are buttons with the obvious labels. The `-uitest-primer` and `replayPrimer` paths show the cards; `-uitest-isolated` never does.

Searching. The 8 s wait, then the checklist and the demo row together. Both the field-on and accessibility-size layouts (`:305-323`).

Macs found while the gate is up: zero, one compatible (first launch auto-connects, `RootView.swift:195-206`, so the user may never see the Mac found junction), one incompatible, several. The arrival rings play for every route into `.arrived`, auto-connect included.

Arrival. Mac names from "Alec's Mac" to "Living Room iMac (2)": the instruction is 32 pt bold and wraps; the rings centre on the wrapped block's centre. Arrival reached from Connecting or from Awaiting approval. The 800 ms hold cancelled by a drop (`RootView.swift:177-193`): rings stop, no tap.

Demo in the shell. Zero Macs; one compatible Mac appears (the offer shows); the Mac leaves again (the offer withdraws); several Macs (the offer opens the list); an incompatible Mac only (no offer; the Settings tab's Switch Mac sheet still lists it with its warning). Note that `ConnectionController.disconnect()` (`ConnectionController.swift:316-324`) leaves the Bonjour browser running, so `handleMacsChanged` keeps firing during demo. That is what makes the offer possible; it must stay that way.

Speakers after arrival. The coach under the first visible row, its existing rule.

## 6. Interaction and layout

### The intro

Layout, top to bottom, inside the gate's 22 pt gutters and 44 pt top padding:

- Skip, top trailing, on cards one and two only. `QuietAction` sized to its label (the gate's "action the screen is not asking for" recipe: `label2` on `raised` with a `rim` stroke at control radius, 44 pt floor). Card three has no Skip; its capsule is the way in.
- The field, edge to edge, behind everything: `IntroField` as shipped (its three emitters and the Movie night ramp, `:481-492`). It is outside the pager, so it does not page.
- The mark, `AppIconMark` as shipped, also outside the pager, above it.
- The pager: three pages, horizontal, system page style, filling the region from under the mark to above the capsule so a swipe anywhere below the mark pages. Each page is a centred `JunctionCopy`: instruction at the Junction Instruction size, supporting line under it, top-aligned inside the page so all three instructions sit at one y. Card one's instruction is the wordmark, so `instructionIsAppName` is true there and false on the other two, which keeps the Name Only Rule and the no-jump rule at once.
- Page dots: the system page control, current page `label`, the others `labelCool2`, set through the appearance proxy the tab bar already uses (`RootView.swift:244-259`). Never gold: which page you are on is chrome.
- The capsule, bottom-pinned as today (`:107-114`): `GoldGlassAction`. Label Next on pages one and two, Find my Mac on page three, one object whose label crossfades.

Behaviour:

- Next advances one page. Find my Mac and Skip both call `completePrimer()` (`RootView.swift:146-149`), which sets `hasSeenConnectPrimer` and starts browsing. Neither may start browsing by another route: the Local Network prompt must land after the cards, which is the whole reason the primer exists (`RootView.swift:31-35`).
- The flag stays `hasSeenConnectPrimer` (T5). No per-card flag. A user who quits on card two sees card one next launch; that is fine and cheaper than remembering.
- `enterDemo()` keeps calling `markPrimerSeen()` only because the demo row is unreachable before the cards are done; T6 says it must not set the flag on its own, and this layout makes that a no-op either way.

Copy is in section 8.

### The searching junction and the demo row

At 8 s the checklist unfolds (existing). At the same instant the demo row appears at the bottom of the screen, where the debug build already puts its promoted band (`:120-125`, `:388-398`). The whisper state before 8 s goes: before the checklist there is no demo row at all. Never on the intro. Never on the Switch Mac sheet (`isFullScreen` guard, existing).

The row keeps its recipe: a gate panel at row radius, the `sparkles.tv` glyph in `label2`, a semibold `label` title, a footnote `label2` sub-line, `PressFade`, 44 pt floor. Its copy changes (section 8). Tapping it enters the demo: the existing gate-to-shell crossfade, Speakers selected, no haptic (nothing answered), no rings.

### The Demo pill in the shell

I'll call it the Demo pill, after the plan's own wording, unless you'd rather something else.

A strip across the top of the shell, above all four tabs, as a top safe-area inset on the `TabView` so Speakers' own header, Apps' header, and the Scenes and Settings navigation bars all start below it. `canvas` ground, nothing drawn but the pill, 44 pt tall so the strip never changes height when the offer joins it. Only present while `isDemoActive`.

State one: the existing `DemoBadge` recipe (`SettingsTabView.swift:235-247`), centred. A label, not a button: a capsule that looks pressable promises a press, the same reasoning the Speakers status pill was built on. Leaving the demo stays on the Settings tab.

State two, when `handleMacsChanged` sees at least one compatible Mac: a second pill joins it, "Your Mac is here", in the coach's Got it recipe (micro label in `inkOnFill` on a `gold` fill at control radius, 10 pt by 6 pt padding, drawn inside the 44 pt slab). Gold because it is a call to action, the second of gold's two jobs. The Demo badge stays beside it, colourless: demo is still what the screen is showing, and D6 says every screen says so. The two sit 8 pt apart, centred as a pair.

Tapping the offer presents `ConnectGateView` as a sheet with `isFullScreen: false`, exactly as the Settings tab's Switch Mac does (`SettingsTabView.swift:77-94`). One place in the app knows how to pick a Mac. The sheet shows the one Mac found junction or the list; Connect there drops the demo (`AppSessionModel.connect(to:)`, `RootView.swift:114-117`); the sheet closes on `.live` and the strip goes with the demo session.

The offer never appears for an incompatible Mac alone: it would lead to a row with no Connect. It withdraws when the Mac leaves the network. It never connects on its own; `handleMacsChanged`'s `!isDemoActive` guard already forbids that.

VoiceOver: the badge reads "Demo. Pretend speakers, not your Mac." The offer is a button, "Your Mac is here", hint "Opens the Mac list." When the offer appears, post an announcement, "Your Mac is on the network," because it arrives silently and far from the finger (the ToastBanner precedent).

### The arrival

I'll call them the arrival rings, after the code's `.arrived` junction and `arrivalBeat`, unless you'd rather something else.

Trigger: the full-screen gate's junction becomes `.arrived`. The eyebrow crossfades to Connected and the name's ink warms to `gold` on the gate's existing tempo (`:133-135`), so the name is fully gold before the rings land. The name does not move; it stays exactly where Connecting or Awaiting approval had it.

What the eye sees: the field's own ring crests, in the gate's green ramp, travelling inward from beyond the screen's edges toward the centre of the name's block, decelerating, and dimming as they close, so that as the last crest reaches the name it has nothing left and the screen is the plain canvas with a gold name on it. Roughly three crests pass a given point. Nothing else in the field moves: no breathing, no orbit drift, because a swell during a convergence reads as two events.

Then the tap. Then 250 ms of nothing. Then the existing gate-to-shell crossfade at 800 ms.

Timing, easing and the haptic are in section 9. Guardrails on how the rings are drawn are in section 10.

### The gesture coach on Speakers

It survives. The cards say what the phone is for; the coach says how the row works, at the row, at the moment the row is first seen. Those are different lessons, and the second one is forgotten if it is taught on a card ten seconds before there is a row to try it on. Card two therefore does not mention tap or drag. The coach's rule stays: one line under the first visible row, gone once both gestures have been used or on Got it (`SpeakersView.swift:596-635`). It shows in demo too, which is right; the demo is for looking around.

One copy fix while the builder is there: "Tap to play · Drag to set level" says "level", and the copy review skill's terminology table settles loudness as "volume", never "level". It becomes "Tap to play · Drag to set volume", and the VoiceOver label "Drag across a speaker to set its volume."

## 7. Constraints

- iOS 18.0 deployment, iPhone only. The gold capsule's Liquid Glass on iOS 26 and the flat fallback below it are as shipped.
- Every string goes into the String Catalog (T12), English only (D14). Sentence case, no `.textCase`.
- The field reads `AudioutField.defaults` and `AudioutField.ramps`; nothing from `field.json` is retyped. A deviation on a shared knob is marked inline with its reason, as `SearchWaves` marks its gain (`:631-639`), or it does not happen.
- The field stands down at accessibility text sizes and holds `EmitterField.stillT` under Reduce Motion (`EmitterField.swift:171-196`). The arrival rings are the one field appearance with no still: see section 9.
- Haptics through `.sensoryFeedback`, keyed to a value that changes once per event, the way `faderRail` is built.
- Verification is on the physical iPhone 15 Pro (`AGENTS.md`). The haptic's weight, the field's calm across three cards, and the ring landing cannot be judged in the Simulator.
- Analytics (T11): `intro_card_seen` with the page index on each page's appearance; `find_mac_tapped`, with a property saying whether it came from Skip; `demo_entered` from the row; `connected` at `.live`.
- Reduce Motion: a Next tap crossfades pages; a user's own swipe may slide, since the motion is theirs.

---

## 8. Card-by-card copy

Voice: the gate's. Eyebrow in console voice is allowed but the cards have none, like the primer (`:199-203`). The instruction is a short declarative line with no full stop; the supporting line is one or two literal sentences with full stops. Where a line is a figure of speech ("the ear") the sentence under it is entirely literal, which is the site's payoff rule applied to the only two slots the app has for it. Terms follow the copy review skill's table: "this iPhone", "Audiout on your Mac", "speaker", "volume", "in sync".

### Card 1: the Mac plays

Mark. Wordmark instruction (open decision 1: "Audiout" as today, or "Audiout Remote" per D4).

Supporting line:

> The sound comes from your Mac, where Audiout plays to your speakers. This app needs it running.

Two sentences. The first settles who plays. The second is the requirement, stated plainly for the cold downloader and harmless to the Mac-first buyer. "Running" matches the checklist's own words at `:348`.

### Card 2: this iPhone is the remote

Instruction:

> This iPhone is the remote

Supporting line:

> Volume and mute for every speaker, and which speaker each app plays to. From whichever room you are in.

"Every speaker" is a verified absolute: it is every speaker the Mac can reach. No gesture teaching here; the coach owns that.

### Card 3: this iPhone is the ear

Instruction:

> This iPhone is the ear

Supporting line:

> Hold it near a Bluetooth speaker. Audiout plays a short sound, this iPhone hears it, and that speaker is put in sync with the rest.

This card carries the differentiator and the Find my Mac capsule. "The ear" is the owner's word (plan T20). The sentence under it is the measurement mechanism from the glossary in plain words, and it primes the microphone without asking for it: the microphone prompt still waits for the sync sheet. "Bluetooth" is assumed (open decision 3): the app offers measurement only on Bluetooth rows today, and a card that implied AirPlay speakers get measured would be a claim the app cannot show.

### The buttons and the rest

- Capsule on cards 1 and 2: `Next`
- Capsule on card 3: `Find my Mac` (open decision 2: the code and the plan say "Find My Mac")
- Skip, cards 1 and 2: `Skip`
- Page control: system, "page 1 of 3" spoken

### The demo row under the checklist

Title: `Try the demo`
Sub-line: `Look around with a pretend Mac. Nothing plays out loud.`
VoiceOver label: `Try the demo`. Hint: `Shows the app with a pretend Mac. Nothing plays out loud.`

The plan's line was "No Mac nearby? Try the demo." The row appears only after 8 s of finding no Mac, so the situation states itself, and the copy review skill flags self-answered questions. "Pretend Mac" is the glossary's own phrase for the demo. "Demo system" (the debug title, `:409`) goes: the terminology table bars it. (Open decision 7 if the question form is wanted back.)

### The Demo pill

Badge: `Demo` (unchanged). Offer: `Your Mac is here` (the plan's words). Announcement when the offer appears: `Your Mac is on the network.`

### The arrival junction

Unchanged: eyebrow `Connected`, instruction the Mac's name.

---

## 9. Motion and haptics

One tempo for every change on the gate, as today: `.snappy(duration: 0.35)`, or `.easeInOut(duration: 0.25)` under Reduce Motion (`:133-135`). The shell's one spring, `.spring(duration: 0.25)`, for anything that moves inside the shell.

### Paging

A swipe pages with the system slide. Next pages with the same slide; under Reduce Motion, a crossfade. The capsule's label crossfades from Next to Find my Mac on arrival at page three; nothing else about the capsule changes. Skip leaves the intro by the existing junction crossfade into Searching.

### The field on the cards

Continuous, unchanged by paging, the `IntroField` as shipped. Under Reduce Motion, the one still at `stillT`. At accessibility sizes, absent. "Calm" is achieved by the field not reacting, not by retuning it. If on hardware three cards' worth of it reads as too lively, the levers are per-surface and in this order: the three emitters' `size`, their positions, their count. A shared knob is not a lever here.

### The checklist and the demo row at 8 s

Both fade in together (`.transition(.opacity)`, as the checklist already does at `:315`). The row does not slide up from the edge; a thing sliding in after a screen has settled reads as an alert.

### The arrival rings

- 0 ms: `.live`. The junction becomes `.arrived`; the eyebrow and the name's ink crossfade on the gate's tempo. The rings begin at the screen's edges at full ramp brightness.
- 0 to 550 ms: the crests travel inward to the centre of the name's block on a deceleration curve (fast start, slow landing; the site's confident-arrival ease, not a bounce). Brightness falls with distance travelled so the last crest arrives dark.
- 550 ms: the crests meet the name and are gone. The haptic fires here.
- 550 to 800 ms: nothing moves. The name sits gold on the canvas.
- 800 ms: the existing gate-to-shell crossfade.

Cancelled arrival (the status leaves `.live` inside the hold): the rings fade out over 150 ms, exit faster than entrance, and the haptic does not fire if it has not already.

Reduce Motion: no rings at all. Nothing is drawn behind the name. A frozen ring set around a name would read as a mark, and green marks nothing. The name's crossfade is the 0.25 s ease, the haptic fires at 0 ms, and the hold is still 800 ms.

Accessibility text sizes: no rings, for the same reason the other fields stand down there.

Ramp: the Movie night green, the light the gate already runs on the intro and the searching junction (assumed, open decision 4). The name stays gold. A gold ramp was considered and rejected: on the gate gold is the name or the action, and a gold field would make the whole screen read as something to press.

Demo: no rings, no haptic. The demo enters the shell through `enterDemo()`, which never passes `.arrived`, and no Mac answered.

### The Demo pill

Present from the shell's first frame, inside the gate-to-shell crossfade, never entering on its own afterwards. When the offer joins: the badge moves left on the shell's spring and the offer fades in over 0.25 s; under Reduce Motion, the offer fades in and the badge jumps. When the Mac leaves: the reverse, faster. No haptic either way. The change is not the user's action and not the Mac answering one; a tap for it would be a notification.

### Haptics

One new event, and it is the sixth in DESIGN.md's list.

**Connected.** A single `.impact(weight: .soft)`, full intensity, when the arrival rings land on the Mac's name, about 550 ms after the session goes live; at once under Reduce Motion or at accessibility sizes, where there is no landing. It is the Mac's `welcome` answering the dial, the same footing as mute's confirm and the sync sheet's Ready: never on the tap that started the dial, never on first appear. It also fires when the Switch Mac sheet's session goes live, at 0 ms, since that sheet closes at once and has no landing. It never fires on the controller's own redials with the shell up (the shell's banners own those), and never in demo.

A new weight rather than the rails' `.light`, because the connect is a different subject from a fader stop. The weight is a hardware judgement, exactly as the detents' 0.52 was: if on the iPhone 15 Pro `.soft` cannot be told from a rail arrival, the fallback is `.impact(weight: .light, intensity: WarmSignal.FaderDetents.intensity)`, an existing strength, rather than a third one.

Not this brief's, but the builder of T8 will hit it: D8 says level-drag detents at 0/50/100, and the code and DESIGN.md have a detent every 5 units with rails at 0 and 100 (`WarmSignal.swift:445-470`). That is a conflict between the plan and the shipped design, to be settled before T8 touches `DeviceRowView.swift:291`.

---

## 10. Design system delta

Exact additions to `audiout-remote/DESIGN.md`. Wording matches the file's own register; the builder pastes, then reads the surrounding paragraph once for fit.

### Frontmatter

Under `components:`, after `status-banner`:

```yaml
  demo-pill:
    backgroundColor: "{colors.well}"
    textColor: "{colors.label2}"
    rounded: "999pt"
    padding: "3pt 8pt"
    size: "in a 44pt strip above the shell, present only in demo"
  your-mac-pill:
    backgroundColor: "{colors.gold}"
    textColor: "{colors.inkOnFill}"
    rounded: "{rounded.control}"
    padding: "6pt 10pt"
    size: "drawn inside the same 44pt strip, 8pt trailing the demo pill"
```

No new colour, radius, spacing or type token. The arrival's 550 ms and the shell strip's 44 pt are stated in prose below, where the file states its other durations.

### Overview, Key Characteristics

Replace the last bullet:

> - The gate shows exactly one junction at a time, carrying at most one gold action, the single live thing to press. The intro is three pages of one junction, not three junctions: the field and the mark hold still and only the copy pages.

### Typography, Hierarchy, Wordmark

Append to the Wordmark bullet:

> On the intro it sets page one's instruction only; pages two and three draw the system face at the same size.

### Layout, the gate paragraph

Replace the sentence beginning "The searching junction and the primer take the whole viewport":

> The searching junction and the intro take the whole viewport as their minimum height, so the emitter field behind them has the room it wants; every other junction sizes to its content. The intro's pager fills the viewport from under the app mark to above the bottom capsule, so a swipe anywhere below the mark turns the page.

### Components, Connect Gate

In the "One junction at a time" bullet, replace "primer" with "intro" in the list of eleven. Then add, after the "Gate panels" bullet:

> - **The intro is three pages, one stage.** `IntroField` and `AppIconMark` sit outside the pager and never move; three `JunctionCopy` blocks page under them, top-aligned so the instruction stays at one height. The bottom capsule is one object with three labels, Next, Next, Find my Mac, and Skip is a `QuietAction` top trailing on the first two pages only. Skip and Find my Mac both go through `completePrimer()`; nothing starts browsing by another route, so the Local Network prompt still lands after the copy that explains it. Page dots are the system page control in `label` and `labelCool2`: which page you are on is chrome, never gold.
> - **The demo row appears with the checklist and never before it.** The searching junction's 8 s patience is the one moment "try it without a Mac" becomes a useful offer; the row waits for it, and never shows on the intro or on the Switch Mac sheet. It is a gate panel at row radius, the same shape as a `MacBand`, because it is a row you tap.

### Components, new entry after Gold Action (Connect gate)

> ### Arrival Rings (Connect gate)
>
> The connected moment. When the full-screen gate reaches the arrived junction, the emitter field draws behind the copy for 550 ms with one source at the centre of the Mac's name and its crests running inward, from the screen's edges to the name, decelerating and dimming so the last crest arrives with nothing left. Green ramp, the gate's own light; the name stays `gold`. Nothing else in the field moves during it: no breathing, no drift. The Connected haptic fires as the rings land, and the 800 ms arrival beat then holds the plain canvas for the last quarter second before the shell crossfades in.
>
> It is the phone's counterpart to the Mac licence window's one-shot surge: the same field, one authored beat at the success moment, a convergence here because there is a named thing to arrive at. It is built from `EmitterField`, never from hand-drawn circles. The source's position, size, reach, the direction of travel and its rate are this surface's choices; every shared knob stays `field.json`'s, and a deviation on one is marked inline with its reason or does not happen. The reference's crest speed (`speedBase` over `densBase`, about 0.065 uv per second) is far too slow for a half-second landing, so the surface runs its ring phase on a clock of its own and says so where it sets it.
>
> Under Reduce Motion and at accessibility text sizes there are no rings at all. This is the one field with no still: a frozen ring set around a name reads as a mark, and green marks nothing. A drop inside the hold fades the rings out in 150 ms and withholds the haptic.

### Components, new entry after DemoBadge (Settings)

> ### Demo Pill (shell)
>
> A 44 pt strip on the `canvas` ground across the top of the shell, above all four tabs, present only while a demo session is active. It carries `DemoBadge` centred, colourless as ever, as a label and not a button: leaving the demo stays on Settings. D6's "labelled on every screen" is this strip; the Speakers status pill's " · Demo" suffix never shows in demo in practice, because the demo session is live with the name "Demo Mac" and the named branch wins (`SpeakersView.swift:116-118`).
>
> When a compatible Mac appears on the network, "Your Mac is here" joins the badge 8 pt trailing, in the coach's Got it recipe: `inkOnFill` on a `gold` fill at control radius. Gold because it is a call to action. Tapping it presents the Connect gate as the same sheet Settings' Switch Mac uses, so one place in the app still knows how to pick a Mac; the sheet closes on `.live` and the strip goes with the demo session. The offer withdraws when the Mac leaves, never appears for an incompatible Mac alone, and never connects by itself. The strip is 44 pt in both states so its height never changes; the badge slides on the shell's spring and the offer fades, or under Reduce Motion the offer fades and the badge jumps. No haptic: the change is neither the user's act nor the Mac answering one.

### Components, One-Time Gesture Coach

Append:

> It survives the three-page intro on purpose: the intro says what the phone is for, the coach says how the row works, at the row. Page two does not mention tap or drag. The line reads "Tap to play · Drag to set volume"; "level" was corrected to the terminology table's word.

### Haptics

Replace the opening line "Five feedback events, and they are telling the finger different things." with "Six feedback events, and they are telling the finger different things." Then append after the Ready bullet:

> - **Connected:** a single `.impact(weight: .soft)` when the arrival rings land on the Mac's name, about 550 ms after the session goes live, and at once under Reduce Motion or at accessibility sizes, where nothing lands. It is the Mac's `welcome` answering the dial, on the same footing as mute's confirm and Ready: never on the tap that started the dial. It also fires when the Switch Mac sheet's session goes live, at once, since that sheet closes without a landing. Never on the controller's own redials with the shell up, and never in demo, where no Mac answered. `.soft` rather than the rails' `.light` because the connect is a different subject from a fader stop; like the detents' 0.52 it is judged on hardware, and if the iPhone cannot tell it from a rail arrival the fallback is `.light` at the detent intensity, an existing strength rather than a third.

### Do's and Don'ts

Add under Do:

> - **Do** send Skip and Find my Mac through `completePrimer()`. The Local Network prompt lands after the intro or the intro is not doing its job.
> - **Do** keep the intro's field and mark outside the pager. The copy pages; the room does not.

Add under Don't:

> - **Don't** teach tap or drag on an intro card. The coach says it at the row, once, when there is a row to try.
> - **Don't** draw a still of the arrival rings. Under Reduce Motion the arrival is a gold name on the canvas and one tap.
> - **Don't** put the Demo badge inside a tab's header. It is one strip above all four, so demo is labelled the same way everywhere.

### Decision Record

Add at the top:

> **2026-09-06, the first launch shaped for release (plan D5, D6, D8).** The primer became three pages of one junction; the demo row left `#if DEBUG` and appears with the checklist; the shell gained the Demo pill strip and the Your Mac is here offer; the arrived junction gained the arrival rings and the sixth haptic, Connected. Open at the time of writing: the wordmark on page one (Audiout or Audiout Remote), the capsule's case (Find My Mac or Find my Mac), and whether page three names Bluetooth.

---

## 11. Open decisions the builder must not invent

1. **The wordmark on card 1.** The code says "Audiout" (`:207`); D4 names the app Audiout Remote; the copy review skill lists the name as open. Recommendation: "Audiout Remote", because the first screen should match the store listing the buyer just left, and the Name Only Rule sets the product's name, whichever it is. Two words at 32 pt fit one line at default size.
2. **The capsule's label case.** The code and plan say "Find My Mac". The app's One Case rule and the copy review skill say sentence case for buttons, which gives "Find my Mac", and that also stops it reading as Apple's Find My feature. This brief writes "Find my Mac" throughout; revert in one place if the owner wants the plan's form.
3. **Card 3 naming Bluetooth.** Assumed, because the app offers measurement only on Bluetooth rows today (DESIGN.md, the sync surfaces). If the owner would rather the card not narrow the claim, the line becomes "Hold it near a speaker that sounds late." and the Bluetooth scope waits for the row.
4. **The arrival rings' ramp.** Assumed green (Movie night), the gate's existing light. Gold was considered and rejected in section 9.
5. **How the rings are drawn inside `EmitterField`.** The builder chooses between running the ring phase backward on a per-surface clock and porting the reference's `emerge` front in reverse. Either is a per-surface behaviour by the field skill's own list. If either turns out to need a shared knob changed, stop and ask; do not mark a deviation to get past it.
6. **The field's calm across three cards.** Judged on the iPhone 15 Pro. The levers are the three emitters' `size`, position and count, in that order. Not `gain`.
7. **The demo row's wording.** This brief drops the plan's "No Mac nearby?" question for the reason in section 8. If the owner wants it, it goes in the sub-line, not the title.
8. **Leaving the demo in release.** The exit lives on Settings, where a `#if DEBUG` currently wraps it (`SettingsTabView.swift:42-44`). T6 does not list dropping that wrap. A shipping demo with no way out is a trap; the builder of T6 needs a ruling that the wrap goes, and the button's label ("Leave demo" is the plain form).
9. **The Speakers status pill's "Live · " wording.** The copy review skill bars "Live" as a connection state. Not this brief's, but the pill is the only other place demo is named on Speakers, and it will be reviewed alongside.
10. **The Connected haptic's weight.** `.soft` is the spec; the fallback is stated in section 9. The choice between them is made on hardware, not in code review.
11. **D8's detents at 0/50/100 versus the shipped every-5 detents.** Not this surface. Flagged so T8 does not silently pick one.
