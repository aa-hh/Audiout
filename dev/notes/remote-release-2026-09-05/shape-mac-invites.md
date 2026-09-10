# Shape brief: the Mac's invitations to Audiout Remote

2026-09-06. Mode: Operate. Surface: the four places the Mac app points a user at the iPhone app (plan D15, T16), plus the row and drawer states the reconnect rule adds (D10, T14, ADR 0001) and the leftover Scene wording (D16, T17). No code was written. Every file and line below was read in the Mac repo at commit 9730479d on branch `claude/remembered-offset-adr`; the phone repo and the shared package were read at their current checkouts.

No interview was possible. Every choice this brief makes without an owner decision is marked "Assumption". Section 8 lists the choices the builder must not make alone.

## 1. The brief

**Job and audience.** A Mac user who has just put a Bluetooth speaker into a mix and can hear it lag, or who is setting the app up for the first time, or who is in Settings with the iPhone switch in front of them. They have no audio vocabulary. They are not looking for a phone app; they are looking for the speaker to stop sounding late. The Mac's job at each of these moments is to say, in one line, that the iPhone app measures this from the room, and to hand them the way in. The visitor mode is Operate: the invitation sits inside a task and must not interrupt it.

**Outcome and proof.** The user scans a code or reads a URL, installs Audiout Remote, connects, and taps the tuning fork on the phone. Proof on the Mac side: the row's offset changes and its source reads "Measured with your iPhone". The one true thing only Audiout can claim (D3): the timing is measured, not guessed. Airfoil and SoundSource measure nothing. The Mac's own click wizard stays and is called Align by ear.

**Selected direction.** Nothing new is drawn. Every invitation reuses a surface that exists: the alignment wizard sheet's first page, a Settings form row, a first-run card, the sync drawer's band. The only new visual element in the whole brief is a QR tile, specified once in section 5 and used at three sizes. Gold keeps its two jobs (audio state, calls to action); the QR tile is never gold and never a button. The Mac and the phone must read as one family: the phone's `DESIGN.md` is the shared authority, and the copy below uses the glossary's words (`audiout-shared/CONTEXT.md`): Scene, Speaker, Measurement, Offset, Settled, First pass, Timing from last time, Align by ear.

**Scope and boundaries.** In scope: the untuned Bluetooth chip and the surfaces it opens; the sync drawer; the row menu; Settings > General under the Allow switch; a seventh first-run card; the row and drawer wording for the three offset sources and the over-40 ms notice; the remaining Group strings. Untouched: the wizard's click run itself, the phone app, the website, the licence email and /thanks (those are D15's fourth place and belong to the site and licence server, T21), the Remembered iPhones list's behaviour, every token value, every row geometry constant except the drawer's height. Anti-goals: no modal that stops audio work; no badge or banner that appears without a user action (the first-join note is the one exception the codebase already makes, and it stays as it is); no copy that names the App Store, a price, "free", or "download" (section 7).

**States and ranges.** A Bluetooth speaker is untuned, tuned, or has its drawer open. A tuned offset came from one of three sources (D10, T2): measured, first pass, from last time. A re-measurement may differ from the stored value by more than 40 ms. The Allow switch is on, off, or forced by a launch option. Zero, one, or several iPhones are connected. The phone app is on the store, or not yet. Speaker names run from "Sony" to "Living Room Sonos Move 2"; phone names are the phone's own display name, already truncated by the approval controller.

**Interaction and layout.** One door for both ways to align: every existing entry point (chip, first-join note, drawer "Align again…", row menu "Align speaker…") opens the wizard sheet, whose first page now offers the iPhone first and the by-ear run second. Settings gets one row under the Allow switch. Setup gets one spine row and one hero stage. The drawer gains one caption line. Nothing else moves.

**Constraints.** AppKit, stock controls, SF Symbols, `Tokens` only. The QR is generated with CoreImage's built-in QR filter (a system framework, no dependency). The sheet is a fixed dark instrument stage that never themes; the Settings pane and the Setup window do theme. Reduce Motion, Increase Contrast, VoiceOver parity with the visible state. The wire change (a source field on `DeviceState.AlignmentState`) is the shared package's T2 and is additive: no `CompanionProto.version` bump.

## 2. The chip, the note, the menu, the drawer

### 2.1 Where the doors go

Today `PopoverController.startBTAlignmentWizard(deviceID:door:)` (`AudioutPopoverUI/PopoverController.swift:4799`) is reached from four doors, named in `BTAlignmentWizardDoor` (`AudioutCore/BTAlignmentWizardSession.swift:11`): the untuned chip, the first-join note, the drawer's "Align again…", and the row menu's "Align speaker…". Keep all four. Keep their wording. Change what the sheet's first page shows.

The chip on an untuned Bluetooth speaker keeps "Align" behind the tuning fork in a dashed border (`DeviceRowView.updateSyncChip`, `AudioutSharedUI/DeviceRowView.swift:1970` onward) and its tooltip `chipAlignTooltip` (`:1904`). The first-join note keeps "X plays a little behind the other speakers until it's aligned. Align it now." (`AudioutPopoverUI/BTAlignmentNoteView.swift:18-22`). The row menu keeps "Align speaker…" (`DeviceRowView.swift:2157`). The drawer keeps "Align again…" (`AudioutSharedUI/BTSyncDrawerView.swift:313`).

A fourth button in the drawer band was measured and rejected. The band is 653 pt wide and already spends about 600 pt (three leading buttons at 104, 104 and 108 pt with 6 pt gaps, the value cluster at 146 pt, the shift hint, and 12 pt insets, `PopoverColumnGrid.swift:725-761`). "Measure with your iPhone…" at the band's caption font needs about 150 pt. So the iPhone offer lives on the page the drawer's one door opens, not in the band.

### 2.2 The wizard sheet's first page

`BTAlignmentWizardView` (`AudioutPopoverUI/BTAlignmentWizardView.swift`) opens on an intro: the target's name as the sheet title ("Align X", `:182`), the line "You'll hear a click from each speaker. Tap the one you hear first." (`:49`), "About 15 clicks" (`:174`), the Start plate with its Return keycap (`:661`), and the Compare-against picker (`:148`). The sheet is 560 pt wide (`AlignmentWizardViewController.swift:18`), the view 504 (`BTAlignmentWizardView.swift:239`), the answer plates 236 pt (`:260`).

The first page becomes two panels side by side on the plate, the iPhone panel leading:

**Leading panel, not pressable.** Heading, in `Tokens.Font.plateTitle` and `stageInk`: "Measure with your iPhone". One line under it in `Tokens.Font.detail`, `stageInk` at the plate's secondary alpha: "Audiout Remote listens from where you sit and sets the offset in seconds." Below that the QR tile at 96 pt (section 5.1) with the text "audiout.app/remote" under it in `Tokens.Font.caption`, `stageInk`. The panel has no button, no gold, no keycap. It is information the user takes to their phone.

**Trailing panel, pressable, unchanged in function.** Heading "Align by ear". Under it the existing "You'll hear a click from each speaker. Tap the one you hear first." and "About 15 clicks". The existing Start plate with its Return keycap stays the page's one primary control, gold as it is now. The Compare-against picker stays where it is.

Only Start is gold on this page. The plan's word "before" is met by position and by reading order: the iPhone panel leads, the by-ear run follows, and VoiceOver reads the iPhone panel first.

The leading panel has four states, read live from the app layer through a value the sheet's host pushes, the way `BTSyncDrawerView.configure` takes `canAlignAgain`:

1. **Allow off.** `AppSettings.allowRemoteControl` resolves false, or a launch option forces it off. No QR. Heading unchanged. The line reads: "To measure with your iPhone, turn on Allow control from iPhone in Audiout's settings, under General." Nothing else on the panel.
2. **Allow on, no iPhone connected.** The full panel above: heading, line, QR, URL.
3. **Allow on, an iPhone connected.** `CompanionServer.onClientCountChanged` (`AudioutCore/CompanionServer.swift:122`) reports one or more clients. No QR. The line reads: "Open Audiout Remote on Alec's iPhone and tap the tuning fork beside X." With more than one client, or no name on file: "Open Audiout Remote on your iPhone and tap the tuning fork beside X." The phone's name is the approval's `lastKnownName`, the only identity the Mac ever shows (`GeneralSettingsViewController.swift:544`).
4. **A phone-driven run starts for this speaker.** The sheet closes. The Mac allows one alignment run at a time (`CompanionAlignmentRun`'s doc in `AudioutCore/BTAlignmentFreshness.swift`), and a by-ear run and a phone run both engage the wizard feed. Closing is the honest answer: the page's job was to get the phone to take over, and it did. Assumption: close rather than show a "Measuring from your iPhone…" state. See section 8.

Copy the page never carries: "App Store", "free", "download", a price, "app" without the product name.

### 2.3 The drawer band

The drawer band (`BTSyncDrawerView.swift:45` for its shape) reads today:

`[Align again…] [Align by ear] [Reset alignment]   hold ⇧ for 10 ms   [ − | −414 ms | + ]`

Two changes.

**Rename the metronome toggle.** The toggle titled "Align by ear" (`BTSyncDrawerView.swift:286`, accessibility label `:301`) plays the alignment ticks while the user works the steppers. The glossary now reserves "Align by ear" for the click wizard (D3, `CONTEXT.md`), so the toggle needs its own name. Title: "Play ticks". Accessibility label: "Play ticks". The phone's fine-tune page calls the same thing "Start the ticks" / "Stop the ticks" (`audiout-remote/AudioutRemote/UI/Sync/SyncSheet.swift:1147`); both apps now say "ticks". `syncDrawerAlignButtonWidth` (104 pt) has room to spare.

**Retitle its tooltip.** `DeviceRowView.alignTooltip` (`DeviceRowView.swift:1899`), read by the drawer at `BTSyncDrawerView.swift:300` and `:302`, says "Play alignment ticks on this speaker and the rest of the group. Adjust sync until they land as one". New: "Play alignment ticks on this speaker and the other speakers. Adjust the offset until they land as one." "Group" is out (section 4); "offset" is the glossary's word.

**Add one caption line under the band** for the offset's source and the over-40 ms notice (section 3.3). `PopoverColumnGrid.syncDrawerHeight` (`:761`) grows from insets plus control height to insets plus control height plus a 4 pt gap plus one caption line. The popover grows and shrinks by that constant already (`PopoverController` T7), so no other geometry moves.

"Align again…" keeps its title and tooltip ("Measure this speaker again. Opens on the last result.", `BTSyncDrawerView.swift:113`). It opens the sheet's first page as in 2.2. On a tuned speaker the by-ear panel's line adds the last result, as it does today.

## 3. Settings > General, and the three sources

### 3.1 Under the Allow switch

The switch row (`AudioutSettingsUI/GeneralSettingsViewController.swift:216-219`) is a `SettingsForm.row` with title "Allow control from iPhone on this network" and subtitle "Lets the Audiout companion app on your iPhone see and control this Mac's speakers."

**Subtitle, renamed for D4:** "Lets Audiout Remote on your iPhone control this Mac's speakers and measure their timing from the room."

**New row directly under it**, before the override note and the Remembered iPhones list (`:337-340`), built with the same `SettingsForm.row(title:subtitle:control:)`:

- Title: "Get Audiout Remote for iPhone"
- Subtitle: "Scan with your iPhone's camera, or open audiout.app/remote."
- Control: the QR tile at 72 pt (section 5.1). The row idiom centres the control on the title's baseline (`SettingsForm.swift:170`); a 72 pt control must not overflow the row, so the row container sizes its height to the control as well as the text. That is a builder detail, not a design change.
- Under the subtitle, one small stock push button in the pane's existing small-button style ("Open Login Items…", "Check again"): title "Open audiout.app/remote", `bezelStyle = .rounded`, `controlSize = .small`, routed through the pane's injected `openURL` seam the way "Buy Audiout…" is (`:120-125`), so tests never launch a browser. This is the one-line link the plan asks for. A text hyperlink was considered and rejected: this pane has no hyperlink idiom, every link in it is a button, and Operate mode says the same control looks the same everywhere.

**Visibility.**

- The row is mounted only while the switch is on. Off, it is unmounted (the pane's rule: never hide a stack child in place, `AudioutSettingsUI/AGENTS.md`). A Mac that refuses phones should not invite one.
- Once at least one iPhone is remembered (`approvals.approvals` non-empty, the same read that shows the Remembered iPhones list, `:524`), the QR tile is dropped and the row shrinks to title, subtitle and button. Assumption: a second phone in the house still needs the URL but not the code taking up the pane. See section 8.

### 3.2 The Remembered iPhones list

Unchanged. Heading "Remembered iPhones" (`:65`), rows "name · Allowed/Denied · remove" (`:492` onward). The list is what the new row turns into once a phone exists, so the two must sit together: switch, invitation row, list.

### 3.3 The three offset sources and the over-40 ms notice

**The wire.** T2 adds a source to `DeviceState.AlignmentState` (`audiout-shared/Sources/AudioutProtocol/CompanionSnapshot.swift:43-81`). The Mac publishes it from `CompanionSnapshotBuilder.alignmentState` (`AudioutCore/CompanionSnapshotBuilder.swift:236-250`) off a new field on `BTAlignmentReport`. Raw values proposed: `"measured"`, `"firstPass"`, `"fromLastTime"`. The phone renders words, never computes them, as its row already does for status (`audiout-remote/AudioutRemote/UI/Speakers/DeviceRowView.swift:766-780`).

**What the Mac already does.** The Mac row already applies a reconnected speaker's stored offset: the chip shows the number because `syncTrimIsSet || syncMeasuredLatencyMs != nil` (`DeviceRowView.swift:1976`), and nothing on the Mac row ever said "stale". Only the wire status did, which is what the phone turned into "Reconnected, timing not set" (`audiout-remote/.../DeviceRowView.swift:778`). T14 changes the wire status; the Mac row gains source words, not a new state.

**Where the source shows on the Mac.** Not in the chip: the chip is 84 pt and holds a number and a chevron. Not in the row's sub-label: that line carries connection and routing ("Couldn't connect", "Unavailable", the routing text, `DeviceRowView.swift:1062-1075`), and a timing word there would collide with them. The source lives in two places the user already reaches for the offset:

- **The chip's tooltip and VoiceOver value** (`DeviceRowView.swift:2019-2032`), which today read "Sync offset: 22 ms later. Click to adjust." plus the measured split. Prepend nothing; append one sentence by source:
  - measured: "Measured with your iPhone."
  - first pass: "First pass. Your iPhone checks again once the speaker has settled."
  - from last time: "Timing from last time, applied again when the speaker reconnected."
  - A by-ear result from the Mac's own wizard needs its own sentence, "Aligned by ear on this Mac.", and that needs a source value the wire does not yet have. See section 8.
- **The drawer's new caption line** (2.3), `Tokens.Font.caption` in `Tokens.Color.label2`, leading-aligned at `syncDrawerHorizontalInset`, the same sentence shortened to its first clause:
  - measured: "Measured with your iPhone"
  - first pass: "First pass. Your iPhone checks again once the speaker has settled."
  - from last time: "Timing from last time"
  - never measured: the line is empty and the drawer still reserves it, so the band never jumps.

**The phone's row words** (its brief, but the two apps must agree): "Timing not set" stays; "Reconnected, timing not set" becomes "Timing from last time"; "Check timing again" stays for the moved and measured-while-settling reasons; a first pass reads "First pass" until the re-check lands. The phone hand-copies these words, so they belong in `MacCopyTripwireTests.asTheMacSaysThem` (`audiout-remote/AudioutRemoteTests/MacCopyTripwireTests.swift:26-33`) and its Mac mirror.

**The over-40 ms notice (D10).** When a re-measurement replaces a stored value and the two differ by more than 40 ms, the Mac shows, on the drawer's caption line in place of the source until the drawer next closes: "Moved 46 ms since last time. That's more than a reconnect usually shifts; measure again if it still sounds off." The number is the whole-millisecond difference. It is session state like the first-join note (`PopoverController.swift:4787`): the drawer closing clears it, and nothing is written down. The chip's tooltip carries the same sentence for as long as the line stands. Colour stays `label2`: this is a note, not a failure, and `failure` is never a sentence (phone `DESIGN.md`, rule 5).

## 4. Scene wording

The plan's T17 names "‹ Groups", "New Group" and "Delete Group…". Those strings do not exist on `main`. Commit 907ed5a6 (2026-09-05 07:03, "Copy: one name per thing") renamed them, and it is an ancestor of the plan's own commit 9730479d (22:59 the same day), so the plan's list is stale. Verified now in source: the back button reads "Scenes" (`AudioutWindowUI/GroupEditorViewController.swift:388`, accessibility "Back to Scenes" `:400`), the tile reads "Add scene" (`AudioutWindowUI/GroupsOverviewViewController.swift:1041`), the button and context item read "Delete scene…" (`GroupEditorViewController.swift:360`, `GroupsOverviewViewController.swift:318`), the tab reads "Scenes" (`AudioutPopoverUI/AppSurfaceController.swift:16`), the menu bar item reads "Scenes" (`AudioutApp/AppDelegate.swift:1884`), the destination menu header reads "Scenes" (`AudioutPopoverUI/PopoverController.swift:2317`, `AudioutSharedUI/AppRowView.swift:488`), and every refusal the Mac sends the phone says "scene" (`AudioutCore/CompanionCommandDispatcher.swift:368-568`).

Every string literal under `AudioutCore/Sources` containing the word group or groups was listed. One user-facing string remains:

| File:line | String | Change |
|---|---|---|
| `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:1899` | "Play alignment ticks on this speaker and the rest of the group. Adjust sync until they land as one" | "Play alignment ticks on this speaker and the other speakers. Adjust the offset until they land as one." Reaches the drawer through the shared constant at `BTSyncDrawerView.swift:300` and `:302`; no second edit. |

Not user-facing, leave as code: the identifier "NewGroupTileItem" (`GroupsOverviewViewController.swift:77`), the analytics property values "group" (`PopoverController.swift:5276`, `:5343`, `:5356`), the wire and store kinds "group" (`RoutingStore.swift:33-48`, `AppRouteStore.swift:125-154`, `CompanionSnapshotBuilder.swift:308`, `:324`, `CompanionCommandDispatcher.swift:565`), the file name "groups.json" (`GroupStore.swift:94`), the SF Symbol name "rectangle.3.group", and the dev harness print strings in `window-harness/main.swift:101, 144, 223, 241, 244, 291` and `popover-harness/main.swift:332`.

Documentation that still says Groups where the app says Scenes, for the documenter rather than by hand (root `AGENTS.md`: DESIGN.md is regenerated by `impeccable-documenter`, never hand-mirrored): the Mac `DESIGN.md` at lines 375 ("Output Groups", "AirPlay Devices" as section headers; the code says "Scenes"), 131, 204, 301, 402, 431, 476, 490, 512, 550 and 669 (the screen called Groups). The doc comments in `GroupEditorViewController.swift:39, 83, 107, 139, 1476, 1627, 1753` still say "‹ Groups"; they describe the control that now says "Scenes".

## 5. Design system delta

### 5.1 New component: QR tile (Mac `DESIGN.md`, Components)

A square white tile carrying a QR code for `https://audiout.app/remote`, generated with CoreImage's QR filter at error-correction level M, drawn at an integer scale with no interpolation so modules stay crisp, with a quiet zone of four modules on every side. Modules are `#000000`, the tile `#FFFFFF`, and both are fixed in every appearance, every accent dial position and under Increase Contrast: a QR code is a print artifact a camera reads, not chrome, so it joins the wizard stage and the EQ scope under "instruments never theme" (PRODUCT.md Brand Commitments). No corner radius, no edge, no shadow: on the flat light ground the quiet zone merges with the paper, which is what a quiet zone is for; on dark grounds and on the wizard's fixed dark plate the tile carries itself.

Three sizes, one per surface: 72 pt (a Settings form row's trailing control), 96 pt (the wizard sheet's iPhone panel), 160 pt (the Setup hero stage). Each is always paired with the URL as text directly beneath it, in the surface's own caption voice, so a person who cannot or will not scan can type it, and so VoiceOver has something to read. The tile itself is hidden from accessibility; the URL text is the element. It is never a button and never gold.

### 5.2 Changed components and states

- **Sync drawer** (`BTSyncDrawerView`): gains a caption line under the band, `Tokens.Font.caption` in `label2`, leading-aligned, carrying the applied offset's source or the over-40 ms notice; reserved when empty. `PopoverColumnGrid.syncDrawerHeight` grows by 4 pt plus one caption line height. The metronome toggle is titled "Play ticks".
- **Sync chip tooltip and spoken value**: one appended sentence per source (3.3).
- **Alignment wizard sheet, first page**: two panels, the iPhone panel leading and not pressable, the by-ear panel trailing with the existing Start plate as the page's only gold control. The iPhone panel has four states (2.2).
- **Settings form row with an image control**: `SettingsForm.row` must size its height to a control taller than the title line. Today every control is a switch or a button.
- **Setup spine**: seven rows plus the final check. A seventh row is a `SetupStep` case (`AudioutCore/SetupFlowModel.swift:9-16`) with a `SetupCardContent` entry (`OnboardingViewController.swift:675`); its glyph is SF Symbol `iphone`; its hue is an open decision (section 8). Position: after Remote Control, before Usage counts, so Usage counts stays the last card as PRODUCT.md promises.

### 5.3 Copy rules to add to the Mac `DESIGN.md`

- The iPhone app is "Audiout Remote" in full at its first mention on a surface, "your iPhone" after that. Never "the companion app", never "the app".
- The address is always "audiout.app/remote", with no scheme, in caption voice, beside every QR tile and in every invitation line.
- No invitation names the App Store, a price, "free", or "download". The website says what the store's state is; the Mac does not know and does not guess.
- Source words are the glossary's, verbatim: "Measured", "First pass", "Timing from last time". Every string that carries one is a hand-copy on both sides and belongs in the two tripwire tests.
- The glossary's "Align by ear" names the Mac's click wizard and nothing else; the tick toggle is "Play ticks" on the Mac and "Start the ticks" / "Stop the ticks" on the phone.

### 5.4 What the phone's `DESIGN.md` should share

- The three source words and the over-40 ms sentence shape ("Moved N ms since last time. …"), so the two rows read alike.
- "ticks" as the shared word for the alignment clicks the user works against by ear.
- The rule that "Audiout Remote" is written in full at first mention, then "your iPhone" or "this iPhone".
- The stale sub-label "Reconnected, timing not set" (`audiout-remote/.../DeviceRowView.swift:778`, `DESIGN.md:1119-1121`) is retired by D10 and becomes "Timing from last time".
- The phone's `DESIGN.md` Decision Record (`:1055-1071`) still says the Mac ships warm light values and the Circuit light theme. The Mac migrated onto the phone's cool chassis on 2026-09-03 (Mac `DESIGN.md`, Overview). That paragraph is stale and should be corrected in T10's DESIGN.md pass.

## 6. The seventh first-run card

`SetupStep` gains a case between `remoteControl` and `usageStats`. Its `SetupCardContent`, in the pattern of the six at `OnboardingViewController.swift:675-811`:

- `symbolName`: `iphone`
- `iconColor`: open (section 8)
- `activeTitle`: "Tune your speakers from your iPhone"
- `completedTitle`: "Your iPhone can tune your speakers"
- `detail` (recovery and non-first states): "Audiout Remote measures each speaker's timing from where you sit and controls this Mac. Get it at audiout.app/remote."
- `heroHeadline`: "Measure with your iPhone"
- `whyLine`: "Audiout Remote listens from where you sit and sets each speaker's timing in seconds. Scan to get it."
- `allowTitle`: "Open audiout.app/remote"
- `isSkippable`: true, with the shared "Skip for now" (`SetupRibbonView.swift:575`); a skipped row re-arms on click like Bluetooth and Remote Control, and the app asks again only through the other three invitations, never by re-opening Setup.
- `spineAskTitle`: "iPhone remote"
- `spineDoneTitle`: "iPhone remote"

**The hero stage.** `DemoPaneView` draws a rehearsal of the surface each ask raises (`DemoPaneView.swift:319-345`). This ask raises no dialog, so its stage is the QR tile at 160 pt on a `raised` tile with the URL in caption beneath, and nothing else. `DemoPaneView` is the approved custom-drawn exception for this window (`AudioutOnboardingUI/AGENTS.md`), and a generated code is drawn, never a bundled picture. Static under every motion setting.

**The primary button** opens `https://audiout.app/remote` in the browser through the window's existing URL seam. It is the one card whose gold button is not the completion: it exists so a person who would rather read on the Mac can, and so the ribbon keeps its shape. The click logs `setup_allow` with a new outcome the way `consentSheetRaised` is its own outcome (`SetupFlowModel.swift:58`).

**Completion** is real or nothing: the step reads `completed` when an iPhone is connected, read from `CompanionServer.onClientCountChanged` through `SetupModel`, which does not know about the companion server today (nothing in `AudioutCore/SetupModel.swift` mentions it). A phone connecting while the card is up fires the grant choreography and the completed title, and the ribbon's status line says "Alec's iPhone is connected." The completed sentence for the browse-back state (`OnboardingViewController.swift:1521-1537` table): "Audiout Remote is connected. Manage iPhones in Audiout's settings, under General." Pane name (`:1545` table): "Audiout ▸ Settings ▸ General".

**Dropped, not auto-passed**, when the Allow switch resolves off or is forced off, the same way Usage counts is dropped in a build with no analytics sink (`SetupFlowModel.swift:183-184`). A checkmark or an invitation on a Mac that refuses phones would be a claim that is not real.

**Never gates Done.** The card is outside `RequiredPermission`.

**Height check.** The spine holds six rows and the final check in 560 pt (`OnboardingViewController.swift:54`). A seventh row must be confirmed in the onboarding snapshot before the card lands; if it does not fit, that is a decision for the owner, not a smaller row.

## 7. How each invitation degrades before the phone app is on the store

The address is stable across the launch. Before the store link exists, `audiout.app/remote` shows "Coming soon to the App Store" and a notify-me email form (`Audiouter Website/src/pages/remote.astro:112-135`, gated on `PUBLIC_APP_STORE_URL`); after it, the same page carries the store badge and T21 redirects it to the store. Because no Mac string names the store, the Mac needs no build flag and no copy change on launch day.

- **Wizard sheet, Settings row, Setup card:** unchanged before and after. A scan lands on a page that either takes an email or opens the store. The invitation was never "install now"; it was "this is where the measuring app lives".
- **Setup card in a release that ships before the store link:** the release order forbids it (T24: the Mac release ships the same day as store approval), so the only builds that show the card pre-store are the owner's own and TestFlight's. No gating is built for a state the shipped product never has.
- **Connected-phone states** (sheet state 3, Settings without a QR, the completed card) cannot occur before the store exists except on a phone running a TestFlight build, where they are correct.
- **Allow off** hides the Settings row and the Setup card and turns the sheet's iPhone panel into the one-line pointer at the switch (2.2 state 1), in every era.

## 8. Open decisions the builder must not invent

1. **The seventh spine hue.** The Permission-Hue Fence (Mac `DESIGN.md`, Colors) holds five identity hues plus the fixed Bluetooth brand blue, each 47° or more from the others and clear of the gold band [28°, 68°) and the red band. `Tokens.swift:871-882` records them at about 24° (brass), 208° (slate), 268° (plum), 322° (mauve), plus verdigris. The only band with room is roughly 100° to 115°, a moss green, and it must be measured against `panel` and `canvas` in all four appearance cells before it exists, not picked by eye. The alternative is a neutral `label2` glyph, which the spine's locked rows already use for dimming and would read as unavailable. Owner's call.
2. **The wire's source values**, and whether a result from the Mac's own by-ear wizard is `"measured"` or a fourth value such as `"byEar"`. The glossary says a measurement is a probe run, so calling a by-ear result measured would be wrong on the phone's row. This is a shared-package decision (T2) and changes the Mac's tooltip sentence in 3.3.
3. **Whether the Settings QR hides once a phone is remembered** (3.1). Assumed yes.
4. **Whether the seventh card is dropped when Allow is off** and whether its completion is a live connection or an existing approval. Assumed dropped, and live connection.
5. **Whether the sheet closes when a phone run starts** for the speaker it is open on (2.2 state 4). Assumed close.
6. **Whether the over-40 ms notice shows the number** and how long it stands. Assumed the whole-ms difference, until the drawer next closes.
7. **The drawer's second line versus hover only.** Assumed the line, because a first pass is a state the user should see without hovering.
8. **Analytics event names for the four invitations.** The Mac's convention is `area:action` (`mixer:…`, `bt_sync:…`, `license:…`, `settings:…`). Proposed: `remote_invite:sheet_shown` with a `state` property (allow_off, qr, connected), `remote_invite:settings_link_opened`, `remote_invite:setup_card_shown`, `remote_invite:setup_link_opened`, and `setup_allow` outcome `remote_page_opened`. Plan T11 lists the phone's events and none for the Mac.
9. **The sheet's "Align X" title** with two methods on the page: keep it, or "Align X" over the by-ear panel only. Assumed keep.

## 9. Stale documents found on the way

- Plan T17's three strings were already renamed on `main` by 907ed5a6 before the plan was written (section 4).
- Mac `DESIGN.md:511` onward describes the surface header strip as custom-drawn seats; `AudioutPopoverUI/AGENTS.md` records that bordered `NSToolbarItem`s replaced them on 2026-09-05. Not this brief's surface; the documenter should regenerate.
- Mac `DESIGN.md:375` names section headers "Output Groups" and "AirPlay Devices"; the code says "Scenes" (section 4).
- Phone `DESIGN.md:1055-1071` says the Mac still ships the warm light chassis; it does not (5.4).
- Phone `DESIGN.md:1119-1121` still records "Reconnected — timing not set" with an em dash; the code says "Reconnected, timing not set", and D10 retires both.
