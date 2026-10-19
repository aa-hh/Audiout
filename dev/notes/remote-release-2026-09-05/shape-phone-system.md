# Shape brief: the phone shell's shared parts

2026-09-06. Impeccable `shape`, then `extract` planning, on `~/Projects/audiout-remote`. Mode: Operate. No interview was possible, so every guess is marked "Assumed". Line numbers are from the tree at commit 3979365's sibling state on 2026-09-06 and will drift by a few lines.

Words follow `audiout-shared/CONTEXT.md`: Scene, Main Audio, Speaker, Measurement, Offset, Settled, First pass, Timing from last time, Demo, Align by ear.

## Brief

**Job and audience.** A Mac-first buyer, mid-song, phone in one hand, on a tab that has nothing to show. They need to read in one glance which of four things is true (the link dropped, the Mac has nothing of that kind, the app is in the Demo, or nothing is connected) and what, if anything, to press.

**Outcome and proof.** Each of five shared things has exactly one home. Proof is a grep on the phone repo: one `EmptyStateView`, one `GoldCTALabel` face, one `StatusBanner` family, every refusal sentence passing through `AlignmentRunController.macRefusal` or `commandRefusalLine`, and no `hittable(drawn:)` on a word. D13 closes when those hold and DESIGN.md matches the code.

**Selected direction.** The incumbent world, unchanged: Warm Signal tokens, cool chassis, gold for audio state and calls to action, `ring` for a link being made, `fail` for the one real problem, colourless Demo. No new palette, no new radius, no new shadow. Every proposal below reuses a recipe that already ships: the Speakers status-banner strip, the recessed `well` + `rim` pill (the Apps destination pill and `DemoBadge`), the connecting lamp on Settings, the Scenes hero. The one structural addition is a top slot in the tab shell that all four tabs share, so the link's state and the Demo are said once, above the tab, instead of inside each one.

**Scope and boundaries.** Shared parts only. Untouched: the gate's junction logic, the row-as-fader rows, the sync sheet's page order (that is T7), the Main Audio deck, the tab bar, Settings' stock list, `GoldGlassAction` on the primer. Anti-goals: a third banner hue, green outside the wire's own subject, magenta on anything that reports, a spinner, a modal, a "Try again" that looks different in three places.

**States and ranges.** Link: live; reconnecting (a drop the controller will redial); waiting for approval again; not connected (the Mac's user turned control off, or the server is full); Demo. Content: zero routed apps, zero scenes, zero speakers to pick in the scene editor, no Mac settings before the first snapshot, six pretend speakers in the Demo, real fleets of one to a dozen. Mac name 1 to 30 characters ("Alec's MacBook Pro"). A refusal from the Mac: 15 to 120 characters, sometimes carrying "trim", "offset", "latency", "calibration" or a signed millisecond count.

**Interaction and layout.** One top slot under the status bar, above every tab's header, holding at most one notice. Empty states centre in the space left under it. Every action is gold when it is the thing to press and quiet text when it is the way out. A text action never misses at 44 pt. Transitions run on the app's one tempo: spring 0.25 s, ease-in-out 0.25 s under Reduce Motion.

**Constraints and open decisions.** iOS 18, iPhone only. Dynamic Type through stock styles or `@ScaledMetric`, as the code does. Reduce Motion honoured everywhere the code already checks it. VoiceOver announcement for anything that appears far from the finger. Open decisions are collected at the end, each with the answer the builder takes unless Alec says otherwise.

## What the code shows today

Five shapes for one idea. Speakers and Apps draw stock `ContentUnavailableView` (`SpeakersView.swift:31-36`, `AppsView.swift:129-135`, `AppsView.swift:168-173`), which ignores every token: system secondary grey, title2 bold, and no room for a button or the field. Scenes draws a hero with the emitter field, title2 semibold `label`, subheadline `label2`, and a `GoldCTALabel` (`GroupsView.swift:158-196`). The scene editor and Mac settings draw a bare `Text` in a `PanelRow` or a `Form` section (`GroupEditorView.swift:136-138`, `RemoteSettingsView.swift:52-57`). `LockedView.swift` and `AddAppSheet.swift:39-43` are two more `ContentUnavailableView`s. `LockedView.swift:12` already refers to an `EmptyStateView` that does not exist, so the name is the code's, not a coinage.

None of them can tell a drop from a first run. `RemoteSession.applyConnectionState` clears `snapshot` on every `.disconnected` (`RemoteSession.swift:214-218`), and `RootView.noteConnectionStatusChanged` keeps the shell up for any non-terminal drop (`RootView.swift:177-193`). So mid-song, after a Wi-Fi hiccup, Speakers says "No speakers. Connect to a Mac to see its speakers here." and Scenes shows the "Create a scene" hero, while the controller is redialing with backoff. Nothing says the link dropped; the Speakers pill's word changes to "Disconnected" or "Connecting…" in 12 pt cool ink, and Apps and Scenes say nothing at all.

Three gold faces. `GoldCTALabel` (`SettingsTabView.swift:255-275`): control radius, subheadline semibold, 20 pt horizontal, 44 pt `minHeight`, optional `fillsWidth`. `GoldAction` (`ConnectGateView.swift:757-775`): capsule, 17 pt scaled from headline, 20/14 padding, fills width. `GoldCTA` (`SyncSheet.swift:1262-1293`): control radius, 13 pt micro label, 16/10 padding, a disabled state (`well` fill, `labelCool2` ink, 0.25 s ease-out, none under Reduce Motion), and a `minHeight` frame applied outside the button so the drawn pill is 33 pt on a 44 pt target. Three sizes, two shapes, one of them with the only disabled state in the app. `GoldCTALabel` is consumed by Scenes (`GroupsView.swift:189`) and Mac settings (`RemoteSettingsView.swift:161`) only; DESIGN.md:848 lists Settings as a consumer, which is where it is defined, not used.

Banners. `StatusBanners.swift:52-66` is a private `banner(text:symbol:tint:)`: SF Symbol in the tint, footnote `label`, 10 pt padding, tint at 12% in a 10 pt rounded rect. It draws three Mac-wide notes on Speakers only. `DemoBadge` (`SettingsTabView.swift:235-246`) is a `well` capsule, `rim` stroke, `label2` micro label, drawn only on the Settings status row and only in DEBUG. In the Demo the Speakers pill reads "Live · Demo Mac" because `DemoMacSession` reports `.live` with `serverName` "Demo Mac", so the " · Demo" suffix at `SpeakersView.swift:118` never shows. Apps and Scenes carry no Demo label.

Toast. `ToastCenter` holds one `ToastEvent` at a time, 3 to 6 s by message length; `ToastBanner` is a subheadline on `.regularMaterial` in a capsule with a 4 pt shadow, 24 pt above the bottom, rising or fading under Reduce Motion, with a VoiceOver announcement. It carries the Mac's `refusalReason` verbatim (`RemoteSession.swift:286`) and a phone-authored auto-swap line.

Refusal copy. `AlignmentRunController.macRefusal` (`:351-364`) sentence-cases the Mac's reason, files it under Details when it speaks machine ("trim", "offset", "latenc", "calibrat", or a signed number) and leads with a sentence the user can act on; `commandRefusalLine` (`:366-374`) is the one-line form for places with no Details, falling back to "The Mac didn't do that." The sync sheet uses both; the toast uses neither.

Tap targets. `hittable(drawn:)` (`WarmSignal.swift:554-559`) pads outward by (44 minus drawn) / 2 on all four sides. It is exact for a glyph control whose painted size is a constant: mute at 28 and 38, the Apps add button at 34, the invite card's dismiss in its 20 pt frame. It is wrong for a word. A 13 pt semibold line sets about 16 pt tall; `drawn: 22` pads 11 pt and lands at 38, which is the same 38 `MainOutPicker.swift:29-40` documents having fixed for its own label. Sites passing a guessed size to a word: `SyncSheet.swift:464, 485, 695, 764, 810, 835, 863, 1084, 1154, 1170, 1183` (all `drawn: 22`) and `DeviceRowView.swift:695` (`drawn: 20` on "Diagnose"). `SyncInviteCard.swift:126` measures 44 exactly, but its padded rect reaches 12 pt left into a 10 pt gap and over the sentence button beside it.

The stock button. `DeviceRowView.swift:726-732` draws "Try again" with `.buttonStyle(.bordered).controlSize(.small)`: the only stock button face in the shell, in the system tint, on a row whose other two "Try again"s (the gate's denied junction, the sheet's refusal page) are gold.

## Design system delta

### Front matter additions and changes

Add to `components:` and change `cta-gold` and `status-banner` as shown. `cta-gate` is removed as a separate entry; it becomes the capsule shape of `cta-gold`.

```yaml
components:
  empty-state:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.label} title, {colors.label2} sentence, {colors.labelCool2} glyph"
    typography: "title2 semibold; subheadline; the glyph is an SF Symbol at a bare 40pt"
    padding: "32pt horizontal, centred in the space under the shell's top slot"
    states: "reconnecting, notConnected, nothingHere (optional gold action, optional field)"
  cta-gold:
    backgroundColor: "{colors.gold}; {colors.well} while disabled"
    textColor: "{colors.inkOnFill}; {colors.labelCool2} while disabled"
    typography: "subheadline semibold inline; headline semibold when it fills the width"
    rounded: "{rounded.control} in the shell and the sheet; capsule on the gate only"
    padding: "20pt horizontal; 14pt vertical when it fills the width"
    height: "44pt minimum, built in, never padded up to from outside"
    motion: "disabled to live is a 0.25s ease-out on fill and ink; none under Reduce Motion"
  text-action:
    textColor: "{colors.goldText} when it moves forward, {colors.labelCool} when it is the way out"
    typography: "footnote semibold"
    height: "44pt minimum from a minHeight frame plus a content shape; never hittable(drawn:)"
  status-banner:
    backgroundColor: "{colors.fail} at 12% for the one real problem; {colors.ring} at 12% for a note or the link"
    textColor: "{colors.label} sentence; {colors.goldText} trailing action word"
    rounded: "{rounded.control}"
    padding: "10pt"
    mark: "SF Symbol in the tint; for the link, the connection lamp at 12pt in a 20pt well"
    height: "44pt minimum when it carries an action"
  demo-pill:
    backgroundColor: "{colors.well}"
    textColor: "{colors.label2}; {colors.goldText} action word"
    rounded: "999pt"
    edge: "{colors.rim} 1pt"
    padding: "8pt horizontal, 3pt vertical; the 44pt target padded outward"
```

No colour token is added. Two literals become token reads: the banner's `cornerRadius: 10` is `Radius.control`, and the banner stack's `spacing: 8` is `rowGap`.

### EmptyStateView (shared)

One view in `UI/Shared/EmptyStateView.swift`, drawn on `canvas`, centred in whatever space the screen leaves it. Anatomy top to bottom: a mark, a title, one sentence, an optional gold action. The mark is an SF Symbol at a bare 40 pt in `labelCool2` (a glyph, so a bare size is allowed; cool, because nothing here is sounding), or, on Scenes only, the emitter field in the Dinner party ramp behind the copy in place of a glyph, exactly as `GroupsView.swift:158-196` draws it today. Title `title2` semibold `label`; sentence `subheadline` `label2`, centred, wrapping; action a `GoldCTALabel` at 12 pt below. 32 pt horizontal padding. Appearance and disappearance ride the shell's tempo.

Three states, and the caller picks one:

| State | When (in code terms) | Title | Sentence | Action |
|---|---|---|---|---|
| `reconnecting(macName)` | shell is up, session is real, `connectionStatus` is not `.live`, and the drop will redial: `.connecting`, `.handshaking`, `.awaitingApproval`, or `.disconnected(r)` where `r.reconnectClass` is `.retry`, `.longBackoff` or `.repairIdentity` | the screen's own name: "Speakers", "Apps", "Scenes", "Mac settings" | "Back once {name} is." with the last known Mac name, or "your Mac" when there is none | none; the banner above owns the link |
| `notConnected` | `.idle`, or `.disconnected(r)` where `r.reconnectClass` is `.waitForReadvertise` or `.quiet` | "Not connected" | "Connect to a Mac from the Settings tab." | none (Assumed: no button, because switching tabs from inside a tab needs a binding threaded from RootView that does not exist; the sentence names the tab instead) |
| `nothingHere(title, sentence, mark, action?)` | `snapshot` is present and the list is empty | per surface, below | per surface | per surface |

`nothingHere` copy per surface:

- Apps: "No routed apps" / "Add an app to send its audio to a specific speaker." / action "Add app", opening `AddAppSheet`. Assumed: the button is added; today the only way in is the header disc, and an empty state should carry its own press.
- Scenes: "Create a scene" / "Play several speakers together and control them as one." / action "Add scene", with the field. Unchanged copy, one component.
- Scene editor, members section: "No speakers to add" / "Audiout on your Mac hasn't found a speaker yet." / no action. Mark `speaker.wave.2`. Drawn inside the `PanelRow` section at the section's width, not full screen.
- Add app sheet: "Nothing to add" / "Nothing else is playing audio on the Mac right now." / no action. Mark `square.grid.2x2`.
- Locked: "This Mac isn't linked to an Audiout licence" / the existing sentence / no action, mark `lock`. Copy and the no-button rule stay (App Store Guideline 3.1.3(f)).
- Speakers, connected: not used. The three always-present sections are the honest empty answer and stay.
- Mac settings, connected: not used; a snapshot always carries settings.

Demo is not a state of this view. The Demo pill above labels every tab; a second label inside the empty state would say it twice. No reachable `nothingHere` sentence says "your Mac", so no Demo wording swap is needed today. If one is ever added, it says "the demo Mac" and the rule lives here.

VoiceOver reads the title and sentence as one element, the action as a button. Dynamic Type: stock styles throughout; at accessibility sizes the field stands down as the gate's does (`typeSize < .accessibility1`), and the glyph keeps its 40 pt.

Requires one model addition: `RemoteSession` keeps `lastServerName: String?`, set from every snapshot's `serverName`, kept across a drop, cleared on `disconnect()`. Today the name dies with the snapshot, so nothing under the shell can say which Mac it is waiting for. `MacSessionProtocol` gains the property; `DemoMacSession` returns "Demo Mac".

### GoldCTALabel (shared), the one gold face

`GoldCTALabel` stays where it is and grows two things: `shape: .control | .capsule` (default `.control`) and `enabled: Bool` (default true). `fillsWidth` stays. A `Button` wraps it at every site with `.buttonStyle(.plain)`, as Scenes and Mac settings already do; the site adds `.disabled(!enabled)` and any accessibility value. The face carries the look of disabled (`well` fill, `labelCool2` ink, 0.25 s ease-out, none under Reduce Motion), taken from `GoldCTA`.

Size follows width: inline is `subheadline` semibold (15 pt, today's `GoldCTALabel`); full width is `headline` semibold (17 pt, today's `GoldAction`), with 14 pt vertical padding. The 44 pt floor is the label's own `minHeight`, never a frame outside the button, so the drawn fill is the target.

Shape follows the screen: the capsule is the gate's and only the gate's, because there it is the one object on the screen; everywhere else the control radius, so a button sits in a row of chrome the way the mute buttons and chips do. That is DESIGN.md's existing reasoning at "Gold Action (Connect gate)", now stated as a parameter of one view instead of a second view.

What this changes on screen: the sheet's nine buttons go from a 13 pt micro label at 33 pt drawn to 15 pt semibold at 44 pt drawn (a primary action should not be the smallest text on its page); Mac settings' "Apply & reconnect" goes from 15 to 17 pt because it fills the width; the gate is pixel-identical.

`GoldGlassAction` (`ConnectGateView.swift:782-819`) is left alone. It is the primer's only button, its material is the system's, and DESIGN.md already names it as the one sanctioned glass. It shares the capsule's label geometry by hand today and may keep doing so.

DESIGN.md prose: merge "Gold Action (Connect gate)" and "GoldCTALabel (shared)" into one section, "GoldCTALabel (shared, one face, two shapes)", and correct the consumer list to Scenes, Mac settings, the sync sheet, the gate, and the failed device row.

### TextAction (shared), the quiet way out and the small forward step

The sheet draws the same text button eleven times: `.buttonStyle(.plain)`, a 13 pt micro label or a footnote, `goldText` or `labelCool`, `hittable(drawn: 22)`. That is one component: `TextAction(title, tone: .forward | .quiet, action)` in `UI/Shared/`. Footnote semibold (weight, not size, is what separates an action from the note beside it, which is footnote regular); `goldText` when the tap moves forward ("Adjust by ear", "Measure it now", the chain line, "Start the ticks"), `labelCool` when it is the way out ("Not now", "Revert", "Clear this speaker's tuning", "Stop"). Hit target: `.frame(minHeight: 44)` plus `.contentShape(Rectangle())`, no outward padding. Everywhere it sits today it either has its own line or shares an `HStack` with a 44 pt gold button, so the frame pushes nothing. Dynamic Type grows the text and the frame follows.

The row's "Diagnose" (`DeviceRowView.swift:690-696`) is the same component in `.forward` tone, which also retires the `diagnoseSize` `@ScaledMetric` and its bare `.system(size:)` on a word.

The gate's `QuietAction` (a `raised` panel with a `rim` edge at control radius) is a different thing, a recessed control beside the one capsule, and stays private to the gate.

### StatusBanner (shared) and the shell's top slot

Extract `StatusBanner(text:mark:tint:action:)` from `StatusBanners.swift:52-66` into `UI/Shared/StatusBanner.swift`. Same anatomy: mark, footnote `label` sentence, 10 pt padding, tint at 12% on `Radius.control`. Two additions: the mark may be a view rather than a symbol name, and an optional trailing action word in `goldText` (footnote semibold, `TextAction` inside the strip) that makes the whole strip a 44 pt target. `StatusBanners` keeps its three Mac-wide notes and consumes it.

Two tints, unchanged: `fail` for the one thing actually going wrong, `ring` for notes and for the link. Reconnecting is `ring` by the token's own definition ("the connecting/reconnecting dashed ring and the tint behind a note banner"). No third hue.

The shell gets a top slot: `ShellBanners` in `RootView`, attached to the `TabView` with `.safeAreaInset(edge: .top)`, so every tab's content, including the two `NavigationStack` titles, sits below it and nothing inside a tab has to know. It holds one thing or nothing:

1. The reconnecting banner. Mark: `ConnectionLamp(mode: .connecting)`, the Settings lamp itself at 12 pt in its 20 pt well, breathing by crossfade, held at half under Reduce Motion. Sentence by class: "Reconnecting to {name}…" for `.retry`, `.longBackoff` and `.repairIdentity`; `ApprovalStatus.waitingForApproval.headline` ("Waiting for approval") plus the Mac name for `.awaitingApproval`; for `.waitForReadvertise`, "{Name} turned off control from iPhone." (Assumed wording, built from the checklist's own phrase "Allow control from iPhone on this network"; the gate has no sentence for this goodbye either). It shows whenever the session is real and `EmptyStateView`'s `reconnecting` or `notConnected` condition holds. No action word: the controller is already doing the only useful thing, and Settings is one tab away. VoiceOver announces the sentence once per appearance.
2. The Demo pill. `DemoPill` in `UI/Shared/`, replacing `DemoBadge`: the same `well` capsule, `rim` edge, `label2` micro label "Demo", centred in the slot, on every tab, for the whole Demo. When `AppSessionModel.macs` contains a compatible Mac it becomes "Your Mac is here · Connect", with "Connect" in `goldText` and the whole pill a 44 pt target (padded outward, the way the chips reach the floor). One Mac: tapping connects to it. Several: tapping opens the gate as the switch sheet, which already knows how to list them. It never connects on its own (D6). The word change is a crossfade on the app's tempo; VoiceOver announces "Your Mac is here" once. The `#if DEBUG` around the badge, the gate's Demo row and `enterDemo` goes (T6).

The two never coexist: the Demo reports `.live` and never drops.

The sync re-check banner belongs to Speakers, not the shell, because it is Mac-reported state about one speaker: T2's offset source is "from last time" and the Mac's clock verdict is Settled. It joins `StatusBanners`' stack as a `ring` note with an action: mark `tuningfork`, sentence "The {speaker} is using timing from last time.", action word "Check now", which opens `SyncSheet` for that speaker straight to the run page. One banner, the first such speaker in fleet order; the other speakers keep their row sub-label and glyph, which already carry the same fact. It leaves when a Measurement replaces the stored Offset or the user taps the row's glyph. Assumed: one at a time, because the top of Speakers already holds up to three Mac notes and the invite card, and a fourth strip per speaker would push the first row under the fold on a six-speaker fleet.

Order at the top of Speakers, top to bottom: the shell slot (link or Demo), then `fail` problem, then the two `ring` Mac notes, then the re-check banner, then the invite card. `SyncInviteCard` keeps its own panel shape (a user-created offer with a dismiss, not a Mac-reported fact) with one fix: the dismiss glyph gets its own 44 pt column (`.frame(width: 44, height: 44)`) so its target stops overlapping the sentence button beside it.

Banner and toast, one rule: a fact with a duration is a banner at the top and stays until the fact changes; an answer to a tap is a toast at the bottom and goes by itself. A refusal never becomes a banner. A drop never becomes a toast (`RemoteSession.swift:219-221` already suppresses the timeout toast on disconnect; the rule makes that a design fact). `ToastBanner` keeps its capsule, material and 4 pt shadow: it floats over moving content for the same reason the deck does, and DESIGN.md already lists it as the second exception. Its text takes `label` so it stops being the one string in the app in a system colour. Nothing else about it moves.

### The refusal copy rule

The Mac's sentence, sentence-cased, ending in a full stop. Machine words ("trim", "offset", "latency", "calibration", a signed millisecond count) go under a "Details" disclosure where one exists and are dropped where none does, in favour of the one sentence the user can act on. Never a code, never a raw enum name, never the phone guessing at a reason the Mac did not give. Phone-authored sentences follow the same shape.

That is what `AlignmentRunController.macRefusal` and `commandRefusalLine` already do. The rule is applied by calling them:

- `RemoteSession.swift:286` becomes `toasts.show(.refusal(reason: AlignmentRunController.commandRefusalLine(reason)))`. A toast has no Details, so the one-line form is the right one; a reason that is only machine wording shows "The Mac didn't do that."
- `ToastCenter.swift:24`, the auto-swap line, becomes "Main Audio switched to the speaker that just connected." (glossary: Speaker, never Device).
- `DeviceRowView.swift:690-696`: the failure card's disclosure word "Diagnose" becomes "Details", the word the sheet uses for the same thing (Assumed; the content behind it is the Mac's suggestion sentence, which is details, not a diagnosis).
- The two functions stay in `AlignmentRunController` as `nonisolated static`; moving them buys nothing today. The `razor:` note there (a stem list, share one list with the Mac if its copy grows) stands.

### Tap targets

The rule: `hittable(drawn:)` takes the size a glyph control paints, and only that. A word has no drawn size; a text button reaches the floor with a `minHeight` frame and a content shape (`TextAction`). Sites and fixes:

| Site | Today | Fix |
|---|---|---|
| `SyncSheet.swift:464, 485, 695, 764, 810, 835, 863, 1084, 1154, 1170, 1183` | `drawn: 22` on a word; lands at about 38 pt | `TextAction` |
| `DeviceRowView.swift:695` "Diagnose" | `drawn: 20` on a word; about 39 pt | `TextAction(.forward)` |
| `DeviceRowView.swift:731` "Try again" | `drawn: 28` on a `.bordered` small button | `GoldCTALabel`, 44 pt built in, no `hittable` |
| `SyncInviteCard.swift:126` dismiss | 44 pt, but the padded rect overlaps the sentence button | own 44 pt column, no `hittable` |
| `SyncSheet.swift:437` (38), `SpeakersView.swift:810` (38), `AppsView.swift:86` (34), `DeviceRowView.swift:540, 561` (28) | glyph controls with constant drawn sizes | correct; unchanged |

`MainOutPicker.swift:29-40` already does the right arithmetic for its word by hand and documents why; it can adopt `TextAction`'s frame if the `Menu` allows it, or stay.

### The stock `.bordered` button

`DeviceRowView.swift:726-732` "Try again" becomes a `Button { } label: { GoldCTALabel("Try again") }` at control radius, inline size. On a failed row the retry is the one thing to press, and the app's other two "Try again"s (gate, sheet) are already gold. No `.controlSize`, no `hittable`.

### Rule amendments in DESIGN.md

- Rule 3 (Green owns agreement in time): the lamp draws wherever the link itself is the subject: the Settings status row, the Speakers pill's dot, and the shell's reconnecting banner. The sentence "never on any other screen" becomes "never where the link is not the subject". Widened by exactly one surface, the way the sync sheet widened it. Assumed; the fallback if Alec keeps the rule tight is `arrow.triangle.2.circlepath` in `ring` as the banner's mark, and nothing else in this brief changes.
- Do's: "hold every tappable control to the 44pt floor via padding outward (`hittable(drawn:)`)" gains its second half: "for a glyph; a word takes a `minHeight` frame."
- Components: `ContentUnavailableView` leaves the vocabulary. The Locked State section says "a stock `ContentUnavailableView`"; it becomes `EmptyStateView` with the same copy.
- Don'ts: "Don't invent a third status-banner hue" stays and now covers the shell slot.

### Corrections where DESIGN.md disagrees with the code (T10's list, read against source)

- `:479-482` One Case: the example "No groups" is "Create a scene" (`GroupsView.swift:179`).
- `:655` the deck header reads "Main Audio" (`SpeakersView.swift:700`), not "Main Out"; `:744` the follow note reads "Apps without a route follow Main Audio" (`AppsView.swift:109`). The token names (`MainOutRow`, `MainOutPicker`, `deckFill`) are code and stay.
- `:691-692` the status pill: " · Demo" is appended only when no Mac is named, and the Demo always names "Demo Mac", so the suffix never shows. With the Demo pill in the shell, delete the suffix at `SpeakersView.swift:118` and the sentence in the doc.
- `:848-851` GoldCTALabel: consumers and sibling, per the section above.
- `:860` the active scene's meta line trailing half is "Playing" (`GroupsView.swift:330`), not "· Playing now".
- `:881-899` Empty State (Groups): the headline is "Create a scene", the button "Add scene", the tab "Scenes"; the section and every "Groups"/"group" in it takes the Scene word (D16). The list's last row is a dashed "Add scene" tile (`GroupsView.swift:385`), not "New group".
- `:1119-1121` the row's word is "Reconnected, timing not set" (`DeviceRowView.swift:778`); the doc has an em dash.
- `:1165` the forward line does not count seconds; it says the phone "will check again once it's steady" (`SyncSheet.swift:966`). Delete "in about N s".
- The sheet's gutter: five `.padding(20)` in `SyncSheet.swift`. Document it under Layout as the sheet's own: 20 pt, between the list's 14 and the gate's 22, chosen so a sheet reads as neither. Keep it.
- The sheet's third button: "Hold still" carries Measure (gold), "Adjust by ear" (forward text action) and, only while the Mac says Settling, "Measure it now" (forward text action). The rule "at most one gold action" holds on every page; the doc says so and lists the text actions as the sheet's quiet vocabulary.
- `LockedView.swift:12` names `EmptyStateView` before it exists; it becomes true with this work.
- `RootView.swift:15-18` and `ConnectGateView.swift:380-398` say the Demo never ships; T6 changes that and both comments go with the `#if DEBUG`.

## Migration

Every call site each component replaces. Paths under `AudioutRemote/`.

**EmptyStateView** (new, `UI/Shared/EmptyStateView.swift`; `lastServerName` added to `RemoteSession`, `DemoMacSession`, `MacSessionProtocol`)

- `UI/Speakers/SpeakersView.swift:27-37`: the `else` branch's `ContentUnavailableView` becomes `EmptyStateView` in `reconnecting` or `notConnected` by session state.
- `UI/Apps/AppsView.swift:129-135`: `nothingHere` "No routed apps" with the "Add app" action bound to `isPresentingAddSheet`.
- `UI/Apps/AppsView.swift:166-174`: the no-snapshot branch becomes `reconnecting` or `notConnected`. The "Apps / Connecting…" copy goes.
- `UI/Groups/GroupsView.swift:44-50` and `:158-196`: the `groups.isEmpty` test splits into no snapshot (`reconnecting`/`notConnected`) and empty list (`nothingHere` with the field); the private `emptyState` and its `EmitterField` move into the component's field option.
- `UI/Groups/GroupEditorView.swift:136-138`: `nothingHere` "No speakers to add", drawn inside the section.
- `UI/Connect/RemoteSettingsView.swift:52-57`: the placeholder section becomes `reconnecting`/`notConnected`.
- `UI/Shared/LockedView.swift:21-25`: `nothingHere` with the lock copy; the view can stay as a one-line wrapper or go.
- `UI/Apps/AddAppSheet.swift:39-43`: `nothingHere` "Nothing to add".

**GoldCTALabel** (changed in place, `UI/Connect/SettingsTabView.swift:255-275`; consider moving the type to `UI/Shared/GoldCTALabel.swift` since Settings no longer uses it)

- `UI/Connect/ConnectGateView.swift:757-775` `GoldAction`: delete; sites at `:253, :274, :284` become `Button { } label: { GoldCTALabel(title, fillsWidth: true, shape: .capsule) }`.
- `UI/Sync/SyncSheet.swift:1262-1293` `GoldCTA`: delete; sites at `:312, :319, :358, :379, :469, :757, :1072, :1077` become `Button { } label: { GoldCTALabel(title, enabled:) }` with `.disabled(!enabled)` and the accessibility value at the site. `:469` is the one that passes `enabled: ctaReady`.
- `UI/Groups/GroupsView.swift:189` and `UI/Connect/RemoteSettingsView.swift:161`: unchanged calls.
- `UI/Speakers/DeviceRowView.swift:726-732`: the `.bordered` "Try again".

**TextAction** (new, `UI/Shared/TextAction.swift`)

- `UI/Sync/SyncSheet.swift:464` "Measure it now" (forward), `:485` and `:764` and `:1084` "Adjust by ear" (forward), `:695` the run page's back-out (quiet), `:810` the chain line (forward), `:835` "Not now" (quiet), `:863` `offerButton` (forward), `:1154` "Start the ticks"/"Stop the ticks" (forward), `:1170` "Revert" (quiet), `:1183` "Clear this speaker's tuning" (quiet).
- `UI/Speakers/DeviceRowView.swift:690-696` "Diagnose" becomes "Details" (forward); `diagnoseSize` at `:62` goes.

**StatusBanner** (extracted to `UI/Shared/StatusBanner.swift`) and **ShellBanners** (new, in `RootView.swift`)

- `UI/Speakers/StatusBanners.swift:52-66`: the private `banner` becomes the shared view; `:34-46` consume it; the re-check banner is added to the same stack, reading the offset source and clock verdict off `snapshot.devices`.
- `RootView.swift:328-376`: `.safeAreaInset(edge: .top) { ShellBanners(...) }` on the `TabView`, fed `model.activeSession`, `model.macs`, `model.lastUsedMacID`, `model.connect(to:)` and a binding to open the switch sheet.
- `RootView.swift:15-18`, `:130-138`, `ConnectGateView.swift:380-398`: `#if DEBUG` removed (T6); `enterDemo` stops calling `markPrimerSeen()`.

**DemoPill** (new, `UI/Shared/DemoPill.swift`, replacing `DemoBadge`)

- `UI/Connect/SettingsTabView.swift:115-120`: the badge and its `#if DEBUG` go; the status row's name already says "Demo Mac".
- `UI/Connect/SettingsTabView.swift:230-246`: `DemoBadge` deleted.
- `UI/Speakers/SpeakersView.swift:118`: the " · Demo" suffix goes.

**Refusal copy**

- `Model/RemoteSession.swift:286`: wrap `reason` in `AlignmentRunController.commandRefusalLine`.
- `UI/Shared/ToastCenter.swift:24`: the auto-swap sentence.
- `UI/Shared/ToastBanner.swift:15-16`: `.foregroundStyle(WarmSignal.label)`.

**Tap targets**

- `UI/Sync/SyncInviteCard.swift:116-127`: the dismiss button's `hittable(drawn: 20)` becomes `.frame(width: 44, height: 44)`.
- Every other `hittable(drawn:)` on a word is covered by `TextAction` above.

**DESIGN.md**: the front matter block, the rule amendments and the corrections listed above, plus the `EmptyStateView`, `GoldCTALabel`, `TextAction`, `StatusBanner`, `ShellBanners` and `DemoPill` sections replacing "Locked State", "Gold Action (Connect gate)", "GoldCTALabel (shared)", "DemoBadge (Settings)", "Status Banners (Speakers)", "Empty State (Groups)" and the empty-state sentences in "Follow Note and Add Button (Apps)".

## Open decisions, with the answer taken

1. The reconnecting banner's mark is the connection lamp (rule 3 widened by one surface). Fallback: `arrow.triangle.2.circlepath` in `ring`.
2. `notConnected` carries no button; its sentence names the Settings tab. Alternative: thread the tab selection from RootView as an environment action and give it "Open Settings".
3. Apps' empty state gains an "Add app" gold button.
4. The re-check banner shows one speaker at a time, first in fleet order.
5. "Diagnose" becomes "Details" on the failed row.
6. The `.waitForReadvertise` sentence is phone-authored: "{Name} turned off control from iPhone."
7. `GoldGlassAction` stays as the primer's own capsule and is not folded.
8. The sheet's 20 pt gutter is documented, not changed.
