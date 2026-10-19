# Scenes tab, direction B: Mixer grammar

Shape brief, 2026-10-06. Operate mode. No human was interviewed; every call I had to make myself is marked **Assumption**. The mock is `mock.html` / `mock.png` beside this file.

## 1. Job and audience

- A Mac user with two to ten speakers who has just used the Mixer and switches to Scenes to save, check or adjust a named set of speakers. They are configuring, not playing: sound may be running in other rooms, so nothing here may change what is heard.
- Visitor mode: Operate. They read the Mixer daily; Scenes should need no second reading skill.

## 2. Outcome and proof

- Primary task: see every scene and who is in it at a glance, then change one scene's speakers, name or icon without leaving the list.
- Success: a user can say, from the Scenes tab alone, which scene Main Audio is playing to, which apps feed which scene, and which members are out of reach, and can fix membership in two clicks.
- Product-specific truth the screen shows: the membership rail is the same instrument the Mixer draws, the Mixer's Source pills report what feeds each scene, and an unreachable member is named, never hidden.

## 3. Selected direction

**Thesis.** Scenes is a single column of Mixer rows. A scene row is built on `PopoverColumnGrid` with the Main Audio row's anatomy; its speakers fold out beneath it as indented rows on the membership rail. One grammar for the whole popover: a ring around a seat means a scene, a dot in the gutter means a speaker.

**Visual authority.** DESIGN.md and PRODUCT.md as they stand. Nothing new enters `Tokens`.

**Structure, top to bottom.**
1. One card header in the Mixer's voice (`PopoverPanelViewController` card-header rank, 28 pt): title "Scenes" at `headerTitleLeading`, column legends "Speakers" (over the readout column) and "Source" (over the trailing 200 pt column) in `captionMedium` / `label2`. The title turns `goldText` while Main Audio plays to a scene, the Mixer Card Header rule applied unchanged. The header has no chevron: it is the tab's only card and folding it would empty the tab. **Assumption.**
2. One scene row per saved scene, 44 pt (`mainAudioRowHeight`), in saved order:
   - Seat: the scene's glyph in the 26 pt icon column, `GroupIdentityGlowView` (magenta, identity) behind it, and the Main Audio row's 34 pt ring around it (`mainAudioRingDiameter`, `ringStrokeWidth` 1.6).
   - Name in `menuItem`: `label` while Main Audio plays to this scene, `labelCool` otherwise (`GroupsInkTemperatureTests`' rule).
   - Line under the name, `caption` / `labelCool`: the member names, comma-separated, truncating at the tail. An unreachable member is named FIRST ("Den unavailable · Bedroom HomePod, Office, Sonos Move") so truncation can never hide it; two or more read "2 unavailable", and the tooltip names them all.
   - Readout column (40 pt, `readout` font): the member count as a bare number, ink by the Row Fader rule: `goldText` for the scene Main Audio plays to, `emberText` otherwise.
   - Source column (200 pt): `FeedPillView` pills exactly as on a Mixer device row. "System" when Main Audio plays to this scene; one pill per app routed here ("Music", "Safari"). Text is `goldText` while that source is sounding, cool while idle. Pills are read-only, as in the Mixer.
   - A 10 pt semibold `chevron.right` in `labelCool2` closes the row (the sidebar plate's chevron), turning to `chevron.down` when open.
3. Expanded, a scene shows every speaker in the fleet as indented rows (42 pt, icon at `firstElementLeading(indented: true)`), in the Mixer's own speaker order, so no row ever moves when membership changes. Each row's rail node is the membership checkbox (`MembershipBusView` over `InvisibleSwitchCell`, as in today's editor rows); clicking the row also toggles it.
4. Below the speakers, one body row on the indented name column: a small stock rounded "Delete scene…" button and the existing reassurance line in `noteLabel` style ("Changes are saved as you go." / "…They don't change what's playing now." for the playing scene).
5. "Add scene" closes the list: `plus` glyph and `menuItem` in `label2` at `firstElementLeading`, built like the Mixer's "Pair Bluetooth speaker…" row. It is always last and never moves.
6. The host footer stays: "Set up scenes here, then switch to the Mixer to play".

**How the rail tells scene from speaker.** The scene's ring is an origin, drawn with the Main Audio hook (`railRingHookBulge`, `railRingHookLandingDrop`) leaving the ring and turning down the gutter at `railGutterCenterX`.
- Folded: the hook lands on the Mixer's 5 pt collapsed-section dot (`railCollapsedTerminusDotDiameter`), which in the Mixer already means "the rail continues inside here". **This is the one invented piece:** a ring and hook on a row that is not Main Audio, so every scene row is its own small origin.
- Open: the line runs down through the members. Member: filled 15 pt disc on the line. Not a member: hollow 11 pt node with the detour arc. Unreachable member: the dimmed member node (`socket` fill, 3 pt rim, `emphasizesDimmedMemberRim`). The line ends at the last member (rail-extent rule 6); speakers below it show their own hollow circle and no line.
- Tone: one colour per rail (`BusRailOverlayView.originColor`). `gold` (`spineTone`) for the scene Main Audio plays to; `ember` (`unarmedLineTone`, what the editor sets today) for every other scene. Ring, hook, dot, line and member discs share it.

**How the playing scene reads without being playable here.** Four marks, none of them a control: the gold ring and rail, the "System" pill, `label` name ink and a `goldText` count. The pill's tooltip and spoken value say "Main Audio is playing to this scene. Change it in the Mixer." There is no play, select or activate affordance anywhere on the tab.

**Implementation consequence.** `GroupsOverviewViewController`'s grid, `GroupCardView`, `NewGroupTileView` and `MemberChipView` go. `GroupEditorViewController` stops being a pushed page: its back band, Done/Save button and `PageHeaderView` header go; its membership, rename, icon and delete logic move into the expanded row. `GroupCreationSheetController` goes.

## 4. Scope and boundaries

- In: the Scenes overview, the editor, the creation sheet, the icon picker's anchor, the Main Audio menu's scene entries.
- Untouched: the toolbar strip, beak, Pin, surface width (713 pt), the Mixer, Speakers, Settings, every token, the icon picker's own contents.
- Anti-goals: no sliders, mute or volume on Scenes; no activation; no grid, no sidebar, no cards; no new gold site (every gold mark here already means the same thing in the Mixer); no green.

Where each job lands:

| Job today | Where it lives in B |
|---|---|
| Overview cards | Scene rows |
| Open the editor | Expand the row (click, → key) |
| Rename | Inline: double-click the name, Return on a selected scene row, or "Rename" in the context menu. The name becomes a `WarmNameFieldCell` field in place; Return commits, Escape reverts, empty restores. |
| Change icon | Click the seat, or "Change icon…" in the context menu. `IconPickerViewController` opens anchored to the seat, unchanged. |
| Membership | Node or row click on an expanded scene's speaker rows |
| Delete | Context menu "Delete scene…" (in `failure` ink, as the App Row's "Remove from list") and the body button; both raise today's confirm alert |
| Create (sheet) | "Add scene" row. See below. |
| "Add scene from N speakers…" (Speakers sidebar) | Switches to Scenes and runs the same inline creation with those speakers checked |
| Playing / Feeding labels | "System" and app Source pills |
| Unavailable count | Named in the line under the name; member row caption |
| Main Audio menu scene entries | Unchanged list and "Save selected speakers as scene"; add "Edit scenes…" last in the Scenes section, opening the tab with the current scene open. **Open decision.** |

**Creation folds into the row.** "Add scene" inserts a new scene row directly above itself, already open, its name field focused with the placeholder "Scene name" selected for typing, and the speakers Main Audio is currently sending to already checked (the menu's "Save selected speakers as scene" rule). It saves as soon as it has a name and one speaker, like every other edit here. With nothing checked the row stays unsaved, its line reads "Check a speaker to save this scene", and leaving it removes it. **Assumption:** the owner accepts losing the sheet's explicit Cancel/Add in exchange; Escape on the unsaved row is the cancel.

## 5. States and ranges

- Range: 0 to about 8 scenes, 1 to about 12 speakers. One scene open at a time, so the list height stays bounded (8 × 44 + 12 × 42 + 84 ≈ 940 pt worst case); past the Mixer's twelve-row ceiling the list scrolls on overlay scrollers. **Assumption:** one-at-a-time is right; opening another scene folds the first.
- Empty: the card header, then a `CardMessageRow` ("No scenes yet", hint "Save a set of speakers as a scene, then switch to it in two clicks from the menu bar." — today's copy), then "Add scene". No rail draws, because nothing is reached.
- Playing scene; app-fed scene (pills, rail stays `ember`; **Assumption:** an app feed does not turn a scene's rail gold, matching today's editor); both at once.
- Unavailable member: "Unavailable", "Not connected" for Bluetooth, "Missing speaker" for an unknown id, as caption in the Source column of its member row, name `labelCool`, icon `labelCool2`.
- Last member: its node refuses with today's tooltip ("A scene needs at least one speaker…").
- Errors: today's alerts, unchanged ("That name is already taken.", "Couldn't save the change.", "Couldn't delete the scene.").
- Rename in progress; unsaved new scene; picker open.

## 6. Interaction and layout

- Whole scene row is one click target that folds the body (Mixer header behaviour), except the seat, which opens the picker. Hover is the 0.10 wash (`HoverTracker`, `fillRowWash`); a keyboard-selected row takes 0.18. Never gold.
- Folding runs on `FoldAnimator` (0.15 s); the rail resolves per tick through `RailPlan` like the Mixer's card folds. Reduce Motion lands the fold at once and skips the rail's connect pulse.
- Keyboard: ↑/↓ move between rows, → opens, ← folds (or jumps to the parent from a speaker row), Space toggles a speaker's membership, Return renames a scene, ⌘N adds a scene, ⌘⌫ deletes after the alert. Escape folds the open scene, keeping the surface's Escape order (thank-you card, then the open scene, then the bubble closes).
- VoiceOver: outline semantics. A scene row speaks "Downstairs, scene, 2 speakers, Main Audio is playing to it, expanded"; a speaker row "Office, in Downstairs, checkbox, checked"; an unreachable one adds "unavailable". The card title is a heading.
- Context menu on a scene row: Rename, Change icon…, separator, Delete scene… (`failure`).

## 7. Constraints and open decisions

- Native: builder should consider a view-based `NSOutlineView` for free outline keyboard handling and VoiceOver levels, with the stock disclosure button hidden in favour of the row's chevron. The rail overlay then needs row frames from the outline instead of the Mixer's stack. **Open decision for the builder's scoper**, not to be invented mid-build.
- Contrast: every ink is an existing token on `panel`; light `gold` member discs sit on the same 1.77:1 the Mixer already accepts with the rim carrying the shape.
- Reused, by name: `PopoverColumnGrid`, the Mixer card header (`PopoverPanelViewController`), `MainOutRowView`'s ring and hook geometry, `GroupIdentityGlowView`, `BusRailOverlayView` / `RailPlan` / `MembershipBusView`, `MembershipRowView`'s checkbox wiring (`InvisibleSwitchCell`), `FeedPillView`, `CardMessageRow`, `WarmNameFieldCell`, `IconPickerViewController`, the Pair Bluetooth row recipe (`makePairBluetoothRow`), `noteLabel`, `HoverTracker`, `FoldAnimator`, `ContentPaneHostViewController`'s footer.
- Open decisions for the owner: (a) "Edit scenes…" in the Main Audio menu; (b) losing the creation sheet; (c) one scene open at a time; (d) whether the header title's gold is welcome here or reads as a second Mixer.
- Analytics: the creation, rename, icon, membership and delete events keep their names and move to the new choke points; the sheet's own open event, if any, ends.
