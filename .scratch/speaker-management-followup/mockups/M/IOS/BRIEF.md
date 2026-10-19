# Speakers tab on iPhone: what to take from the Mac redesign

Design only. Source: `../FINAL/BRIEF.md`, `../OWNER-BRIEF.md`, `../FINAL/mockup.png`, `../FINAL/pages-greys.png`. Target: `~/Projects/audiout-remote` at `cf608e0` (its `PRODUCT.md`, `DESIGN.md`, `AGENTS.md`, `AudioutRemote/UI/Speakers/`). Protocol: `~/Projects/audiout-shared` at `origin/main` `cc29e52` (tag 0.19.0; the local `main` checkout there is behind). Mac code read on `claude/speakers-nav` `dd88e645` and `origin/main` `56c96a6d`.

Mockup: `mockup.html` → `mockup.png` (light), `mockup-dark.png` (dark). Four iPhone 17 screens with the owner's fleet as the Mac sends it to the phone: A today, B and C proposed, D the long-press menu if question 2 is a yes.

## What the phone already has

The phone's Speakers tab is the phone's Mixer: rows are faders, tap plays, Main Audio is the floating deck. Its owner-approved structure (`PRODUCT.md`, confirmed 2026-08-30) already matches most of the Mac redesign:

- Main Audio has been its own warm, always-visible panel since the restyle (`SpeakersView.swift:537-604`). The Mac redesign moves the Mac toward what the phone already does.
- Reachable speakers come first (Playing, Ready) and unreachable ones last, under one "Unavailable" heading with a count that starts folded (`SpeakersView.swift:175`, `:335-347`). That is direction C's order and divider, with the phone's own heading.

## 1. Adopt, adapt, leave out

| Mac piece | Phone | Why |
|---|---|---|
| Main Audio as its own section, at the top | **Leave as is** | Already its own panel: the deck at the bottom, labelled "Main Audio", the tab's one shadow, in thumb reach. Moving it to the top would cost reach for no new meaning. No "System Audio" heading. |
| "Speakers" title + Overview plate | **Leave out** | No Overview page on the phone; the tab is already called Speakers. |
| The two groups "Shown in Mixer" / "Hidden unless in use" | **Adapt: apply the setting, drop the headings** | The phone should list what the Mac's Mixer lists. Today it lists every speaker the Mac has seen, so the four headphones the owner hid on the Mac fill its Unavailable section (panel A). Headings would split the list on a second axis beside Playing / Ready / Unavailable and turn the remote into a place to manage the library. A hidden speaker in use still shows, in Playing, as on the Mac (Fancyy, panel B). One line at the end says how many are hidden (panel C). |
| Reachable first + "N unavailable" divider (direction C) | **Adopt the order, keep the phone's form** | Already the phone's order. Changes: the Unavailable count follows the filter above (6 → 2 for the owner's fleet); Bluetooth rows say "Not connected", the Mac's word, where today every row says "Unavailable"; a row that goes unavailable travels on the tab's 0.25 s spring like Ready ↔ Playing (today only `playingIDs` animates, `SpeakersView.swift:378`). No `antenna.radiowaves.left.and.right.slash` glyph: the heading is the shared `SectionHeader` on three tabs (chevron, word, count), and its word already says it. |
| Five-count overview with loading placeholders | **Leave out** | It answers "did my Mac find my speakers?". The phone can't see the Mac's search (nothing on the wire), isn't where speakers are found, and its transport chips (All · AirPlay · Bluetooth · Cast) already split by kind. Placeholders on the phone would suggest the phone is searching. |
| Forget | **Leave out** | It applies only to speakers the Mac hasn't seen since it opened, and those never reach the phone: the Mac sends `devicesByID.values` (`AppDelegate.swift:3373` via `CompanionCoordinator.swift:572-574`). It also removes the speaker from scenes, which the Mac's sheet names. |
| Hide / Show actions | **Leave out by default** (question 2) | If added: long-press menu only, never a swipe (see section 2). |
| Headings role on section titles | **Adopt** | iOS form: `.isHeader` (section 2). |
| Middle truncation of names | **Adopt** | `.truncationMode(.middle)` on the row name, so "Sonos Move (SONOS Kitchen)" and "(SONOS Bedroom)" stay apart at large text sizes. |
| Cool ink for unreachable speakers | **Already there** | `labelCool2` name and sub-label, halo at 0.45 (`DeviceRowView.swift:296`, `:863-884`). |

## 2. The iOS form

**Container.** Keep `ScrollView` + `LazyVStack`, not `List`. `DESIGN.md` bans `List` here because its swipe handling fights the row's own horizontal drag, which is the fader. The three headings stay the shared `SectionHeader`.

**Filter.** `SpeakerConsole.devices(in:)` (`SpeakersView.swift:227-229`) drops devices whose `isVisibleInMixer == false`. `nil` (an older Mac) shows the speaker. `presentTransports` and `hasAnyPinned` (`:237-244`) read the same filtered list, so no chip appears for a transport only hidden speakers have. Apps (`AppsView.swift:157-161`) and the Scenes editor (`GroupEditorView.swift:88`) keep the full list: a hidden speaker is still a routing target and a scene member.

**The line at the end.** After the last section, inside the list, before the deck's clearance:
- `eye.slash` at 11 pt in a 13 pt box centred on the chevron column, then "4 speakers hidden unless in use" / "1 speaker hidden unless in use" in `.microLabel()`, `labelCool2` (5.76:1 dark, 5.30:1 light on `canvas`), 6 pt gap, 28 pt tall, 6 pt above. The words reuse the Mac's own heading, "Hidden unless in use".
- Text, not a control: the setting is changed on the Mac. Absent when the count is 0 or the Mac sends no flags.
- Count: devices with `isVisibleInMixer == false`. Hidden speakers in use are visible, so they don't count.

**Long-press menu** (`DeviceRowView.swift:463-479`). Stays the home of a row's secondary actions: Add to Favourites, and Align… for speakers the Mac can align. If question 2 is a yes, a third item after a separator: "Hide unless in use" with `eye.slash`, on any shown speaker except This Mac. The row leaves when the Mac's next snapshot says so, never on the tap (the phone's rule for anything with live sound). VoiceOver gets the same item as a named action beside the Favourites one (`:358`). Swipe actions are out in every case: a sideways drag on a row sets its volume, and Apps and Scenes already dropped swipe actions for the same reason (`DESIGN.md:842-843`, `:1184`).

**SF Symbols.** `eye.slash` (the line, and the optional menu item); `star` / `star.slash` and `tuningfork` unchanged; row glyphs come from the Mac's `iconSymbolName`. The mockup's glyphs are hand-drawn stand-ins for these.

**Dynamic Type.** The line takes `.microLabel()` (scaled from `.caption2`) and wraps at accessibility sizes. Names keep `lineLimit(1)` and truncate in the middle.

**VoiceOver.**
- `SectionHeader` adds `.isHeader` next to its `.isButton` (`SectionHeader.swift:44-45`), so the rotor's Headings setting jumps Playing → Ready → Unavailable. Today it carries the button trait only. This is the iOS form of the Mac's heading role on its sidebar titles.
- Bluetooth rows that aren't available: value "Not connected" (`playingWord`, `DeviceRowView.swift:229-237`), hint "This speaker isn't connected to your Mac." (`disabledReason`, `:187-192`; today "This speaker isn't on the network." for every speaker).
- The line: one static text element, "4 speakers hidden unless in use", hint "Change this in Audiout on your Mac."
- No announcement when a row moves. The Mac announces a change on the selected row; the phone has no selection.

**Haptics.** None new. The app's haptics fire on the user's own act or the Mac's confirmation of it (`DESIGN.md` Haptics); a speaker leaving the network is neither. If Hide is added, the system menu gives its own feedback and the row leaves on the Mac's answer.

**Reachable rule.** `SpeakerSection.of` (`SpeakersView.swift:82-86`) reads `device.isAvailable`. The Mac's dividers read `isAvailable || connection is connected` (`SpeakerLibraryController.swift:105-107`). Reading `isAvailable || connection.state == "connected"` on the phone makes the two counts agree, with no wire change.

## 3. Protocol gaps

What the phone already receives per speaker: `isAvailable`, `kind`, `isLocalDevice`, `connection.state`, and (since 0.18.0 / 0.19.0) `failureCause`, `credentialKind`, `access`. Mac `origin/main` already sends the last three (`CompanionSnapshotBuilder.swift:286-308`). The phone pins 0.15.0 and reads none of them; they belong to the password work, not this change.

**Gap 1: the Mixer's visibility. Needed.** The phone has no way to know which speakers the Mac's Mixer shows.
- audiout-shared `Sources/AudioutProtocol/CompanionSnapshot.swift`: `DeviceState` gains `public var isVisibleInMixer: Bool?` and a defaulted `init` parameter. Doc: the Mac's answer to whether its Mixer shows this speaker right now (its Show in Mixer setting, This Mac, or in use); `nil` from an older Mac, treat as shown.
- `Tests/AudioutProtocolTests/CompanionMessageTests.swift`: round trip, and a snapshot without the key decodes to `nil`.
- One field carrying the Mac's answer, not the raw setting: the rule (`isVisibleInMixer || in use`, `PopoverController.swift:2275-2276`) then has one definition, on the Mac.
- Mac: `CompanionSnapshotBuilder.deviceState(for:groupController:iconFor:alignment:)` (`:255-283` on speakers-nav) sets it from the visible-id set the Mixer uses; `CompanionCoordinator`'s host protocol (`:32`) gains a read of that set, and a library or in-use change calls `scheduleBroadcast()`.

**Gap 2: remembered speakers not seen since the Mac opened. Recommended (question 3).** The Mac's Mixer draws a speaker set to "Show even when unavailable" even before it has appeared this launch (through `SpeakerPresentationRecord.renderingDevice`). The phone never gets it: the wire carries only devices seen this launch. Fix on the Mac alone, no new field: add a `DeviceState` for each library record with no live device whose `isVisibleInMixer` is true, with `isAvailable: false` and `connection.state "off"`. An older phone shows it under Unavailable, which is true; Apps never offers it (it filters on `isAvailable`, `AppsView.swift:158-160`).

**Not gaps.** Reachable or not: `isAvailable` plus `connection.state`. Bluetooth "not connected": `kind == "bluetooth"`. The can't-be-found set and search progress: not on the wire and not needed, since Forget and the Overview stay on the Mac.

**Only if question 2 is a yes.** `Sources/AudioutProtocol/CompanionCommand.swift` gains `setSpeakerVisibility(id:visibility:)`, and `DeviceState` gains `mixerVisibility: String?` (`whenAvailable` | `always` | `hideWhenNotInUse`, the raw values of the Mac's `SpeakerMixerVisibility`) so the menu shows the right item. A new analytics event row goes into `docs/analytics-events.md` first.

**Version.** No `CompanionProto.version` bump for any of it. Each change adds an optional field, a new command case or extra unavailable rows; audiout-shared's own rule bumps only when an older peer would misread an existing case. Synthesized `Decodable` ignores unknown keys, so an older phone reads a newer Mac, and an absent key decodes as `nil` the other way. Tag 0.20.0, then bump both apps' pins in the same session.

**Order.** The visibility setting exists only on `claude/speakers-nav` (PR #271); `origin/main` has no `SpeakerMixerVisibility`. The Mac half lands after #271. The phone's pin goes 0.15.0 → 0.20.0 (`project.pbxproj` minimum version, `Package.resolved`); that working tree already has another session's uncommitted 0.14.0 → 0.15.0 bump, so merge with it, don't overwrite it. The jump brings 0.16-0.19's additive changes along; none needs handling here.

## 4. Screens in the mockup

| Panel | Shows |
|---|---|
| A · Today | End of the list, Unavailable open: 6 rows, 4 of them headphones hidden on the Mac, all "Unavailable". |
| B · Proposed, as opened | Playing 3 (Sonos Move, TV, Fancyy, hidden on the Mac but in use), chips, Ready 5, Unavailable 2 folded, the deck. |
| C · Proposed, end of list | Unavailable open: JBL Flip 5 and Move 2 (SONOS Bedroom), "Not connected"; then "4 speakers hidden unless in use". |
| D · If question 2 is yes | Long press on Alec's MacBook Pro: Add to Favourites, then Hide unless in use. |

The owner's six can't-be-found speakers appear on no panel: the Mac doesn't send them, and none is set to "Show even when unavailable". Playing rows draw the 6 % gold tint from the 2026-10-04 ruling (not yet built on iOS). Light gold text follows the code (`#E8B84B` in both modes, owner's call 2026-09-17), not `DESIGN.md`'s older `#825E0F`.

## Owner questions

1. **Should the phone hide what the Mac's Mixer hides, with a line saying how many?** Default: yes. If no, the phone keeps listing every speaker the Mac has seen, and hidden headphones keep filling Unavailable.
2. **Hide from the phone's long-press menu?** Default: no. Showing a speaker again would need a list of hidden speakers on the phone, which is the Mac's "Hidden unless in use" group again, and it costs a new command. Change it on the Mac.
3. **Send speakers set to "Show even when unavailable" that haven't appeared since the Mac opened?** Default: yes, in the same shared release, so the phone's Unavailable matches the Mixer.
