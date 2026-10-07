# Scenes tab, direction E: one list of scenes that open in place

Shape brief, 2026-10-06, Operate mode. No human was available; every guess is marked **Assumption**. `verdict.md` beside this file says what E took from A–D and why. The mock is `mock.html` / `mock.png`.

## 1. Job and audience

- A Mac user with two to twelve speakers who has saved, or wants to save, a few named speaker sets. They play a scene from the Mixer's Main Audio menu; they come here to see what is in each scene and to change it, rename it, re-icon it, or delete it.
- Visits are short and rare. Audio may be running in other rooms; nothing here may change what is heard.
- They read the Mixer every day. Scenes must need no second reading skill and no vocabulary.

## 2. Outcome and proof

- Primary task: see every scene and who is in it, then change one scene's speakers, name or icon without leaving the list.
- Success: from the Scenes tab alone a user can say which scene Main Audio plays to, which apps feed which scene, and which members the Mac can't reach, and can fix membership in two clicks.
- Real content only: member names from the fleet, counts, unavailable members named, the Mixer's feed pills. No live levels, nothing invented.

## 3. Selected direction

**Thesis.** Scenes is one column of Mixer rows under one card header. A scene row carries the group's identity in the icon column and the Mixer's feed pills in the trailing column. Clicking a scene opens it in place: the fleet folds out beneath it as indented rows on the editor's membership rail. One scene is open at a time, so the tab has one rail, as the Mixer does.

**Visual authority.** DESIGN.md and PRODUCT.md as they stand. Nothing new enters `Tokens`. No new custom-drawn piece.

**Structure, top to bottom.**

1. **Card header**, the Mixer's 28 pt rank: "Scenes" in `captionEmphasized` / `label2` at the name column, no chevron (the tab's only card; folding it would empty the tab), legends "Speakers" over the 40 pt readout column and "Source" over the 200 pt trailing column in `captionMedium` / `label2`. The title never turns gold: audio does not come out of these rows.
2. **One scene row per saved scene**, 42 pt (`bodyRowHeight`), saved order, on `PopoverColumnGrid`:
   - Icon column: the scene's `DeviceIcon` glyph with `GroupIdentityGlowView` behind it at its 60 pt size, the treatment the Main Audio row gives a scene destination. No ring.
   - Name in `menuItem`: `label` on the scene Main Audio plays to, `labelCool` otherwise (`GroupsInkTemperatureTests`' rule).
   - Caption under the name, `caption` / `labelCool`: the member names, comma-separated, truncating at the tail. An unreachable member is named first ("Bedroom HomePod unavailable · Office, Sonos Move"); two or more read "2 unavailable"; the tooltip names them all.
   - Readout column: the member count, `readout` font, `label` on the playing scene, `labelCool` otherwise. Not gold or ember: a count is not a level.
   - Source column: `FeedPillView` pills exactly as on a Mixer device row. "System" while Main Audio plays to this scene, one pill per app routed here. Text `goldText` while sounding, `labelCool` idle. Read-only, as in the Mixer. Tooltip and spoken value on "System": "Main Audio is playing to this scene. Change it in the Mixer."
   - A 10 pt semibold `chevron.right` in `labelCool2` at the trailing inset (the sidebar plate's chevron), `chevron.down` while open.
3. **An open scene** adds, under its row:
   - The row's name becomes the editor's `WarmNameFieldCell` field (filled, bordered, trailing pencil), followed by a small "Change icon…" text action in `menuItem` / `.accessoryBar`, the Mixer card header's "Manage speakers…" grammar. The field commits on Return or focus loss, reverts on Escape, restores the old name when emptied.
   - The fleet as indented rows (42 pt, icon at `firstElementLeading(indented: true)`), in the Mixer's order: This Mac, then the Mixer's `AirPlay Speakers` and `Bluetooth Speakers` subsection headers (22 pt, `captionMedium` / `label3`, folding as they do on the Mixer), each speaker by name. Every speaker is listed, unavailable ones included. Each row's rail node is the editor's membership checkbox (`MembershipBusView` over `InvisibleSwitchCell`); clicking the row also toggles it. Name `label`; an unreachable speaker keeps `labelCool` name, `labelCool2` icon and "Unavailable" ("Not connected" for Bluetooth) at the trailing edge; an unknown id reads "Missing speaker".
   - The rail: the editor's own. It hooks out of the seat's leading edge (`railRingHookBulge` / `railRingHookLandingDrop`), runs down `railGutterCenterX`, and ends at the lowest member (rail-extent rule 6). Member: filled 15 pt disc. Non-member above the end: hollow 11 pt node with the detour arc. Below the end: the node alone, no line. Unreachable member: the dimmed node (`socket` fill, 3 pt rim, `emphasizesDimmedMemberRim`), the line passing through it. One tone per rail: `gold` on the scene Main Audio plays to, `ember` otherwise (`unarmedLineTone`, as the editor sets today). In light a gold disc keeps its 1 pt `ember` edge. A folded scene row draws no rail at all.
   - A closing `CardMessageRow` on the indented name column: one small stock rounded "Delete scene…" button and the message "Changes are saved as you go." ("…They don't change what's playing now." on the playing scene). Delete raises the existing confirmation alert.
4. **"Add scene"** closes the list: `plus` glyph and `menuItem` in `label2` on the icon and name columns, built like the Mixer's "Pair Bluetooth speaker…" row (`makePairBluetoothRow`). It opens `GroupCreationSheetController` unchanged; ⌘N reaches it. After Create, the new scene opens in place.
5. The host footer stays: "Set up scenes here, then switch to the Mixer to play".

**Focal moment.** The one gold rail hanging from the playing scene's seat, among rows that show no rail: the same picture as the Mixer's rail, in the same gutter.

**Implementation consequence.** `GroupsOverviewViewController`'s grid, `GroupCardView`, `NewGroupTileView`, `MemberChipView` and `GroupsOverviewLayout` go. `GroupEditorViewController` stops being a pushed page: the back band, Done/Save and `PageHeaderView` go; its rename, icon, membership, rail and delete logic move into the open row. `GroupCreationSheetController` and `IconPickerViewController` are unchanged. `SidebarSelection.groupsOverview` and `.group(id:)` collapse into "which scene is open".

## 4. Scope and boundaries

- In: the Scenes overview, the editor, the creation sheet's door, the icon picker's anchor, the Main Audio menu's scene entries (open decision).
- Untouched: the toolbar strip, beak, Pin, the 713 pt width, the Mixer, the Speakers tab including its "Add scene from N speakers…" bar (it still presents the sheet, then switches to Scenes with the new scene open), Settings, every token, the icon picker's contents, every Analytics event name (`scene:created`, `scene:renamed`, `scene:membership_changed`, `scene:deleted` move to the new choke points; the card grid had no events).
- Anti-goals: no sidebar, no grid, no cards, no plates; no slider, mute, volume or activation on Scenes; no ring on a scene row; no gold title; no new gold site (every gold mark here already means the same thing on the Mixer); no green; no magenta outside the glow behind the seat; no dashed shapes.

| Job today | Home in E |
|---|---|
| Overview cards | Scene rows |
| Open the editor | Click the row, → or Return |
| Rename | The open row's name field; "Rename…" in the context menu focuses it |
| Change icon | "Change icon…" after the field, a click on the seat, or the context menu; `IconPickerViewController` anchored to the seat |
| Membership | Node or row click inside the open scene |
| Delete | The closing row's button, "Delete scene…" in the context menu (`failure` ink), ⌘⌫ on a selected scene; all raise today's alert |
| Create (sheet) | "Add scene" row, ⌘N, the Speakers sidebar's bar |
| Playing / Feeding | "System" and app pills |
| Unavailable count and names | Caption (named first), member row annotation |
| Main Audio menu scene entries | Unchanged; subtitles are an open decision |

## 5. States and ranges

- Range: 0 to about 8 scenes, 1 to about 12 speakers. One scene open: 8 × 42 + 12 × 42 + 2 × 22 + 2 × 42 ≈ 970 pt worst case. Past the Mixer's twelve-row ceiling (504 pt) the list scrolls under the card header on overlay scrollers, the Mixer's own mechanism; the header and footer hold still.
- Empty: the card header, a `CardMessageRow` ("No scenes yet", hint "Save a set of speakers as a scene, then switch to it in two clicks from the menu bar.", today's copy), then "Add scene". No rail.
- Playing scene folded: `label` inks, "System" pill, no rail. Open: the same plus the gold rail and the playing note.
- App-fed scene: app pills; the rail stays `ember` (**Assumption:** an app feed does not arm a scene's rail, matching today's editor).
- Unavailable member: counted and named first in the caption; dimmed node and "Unavailable" in the open scene. Unavailable non-member: listed, `labelCool`, still joinable (owner's call 2026-08-28).
- Last member: the node refuses with today's tooltip ("A scene needs at least one speaker. Use "Delete scene…" to remove it.").
- Errors: today's alerts, unchanged ("That name is already taken.", "Couldn't save the change.", "Couldn't delete the scene.").
- Rename in progress; picker open; a scene opening or folding.

## 6. Interaction and layout

- The whole scene row is one click target that opens or folds it, except the seat (icon picker) and, when open, the name field and "Change icon…". Opening another scene folds the open one. Hover is the 0.10 `engagedChrome` wash via `HoverTracker` / `fillRowWash`; a keyboard-selected row takes 0.18. Never gold.
- Folding runs on `FoldAnimator` (`collapseRevealDuration`, 0.15 s); the rail resolves per tick through `RailPlan` as the Mixer's card folds do. Reduce Motion lands the fold at once and the rail's connect pulse never runs here (nothing connects).
- Keyboard: ↑/↓ move between rows (scenes and, inside an open scene, speakers), → opens, ← folds or returns to the scene from a speaker row, Space toggles a speaker's membership, Return on a scene focuses its name field, ⌘N adds a scene, ⌘⌫ deletes after the alert. Escape folds the open scene, then closes the bubble, keeping the surface's Escape order.
- VoiceOver: outline semantics. A scene row speaks "Downstairs, scene, 2 speakers, Main Audio is playing to it, collapsed"; a speaker row "Office, in Downstairs, checkbox, checked", adding "unavailable" where true. The card title is a heading. The rail is hidden; its nodes speak as today's editor checkboxes ("Add Office to scene").
- Context menu on a scene row: Rename…, Change icon…, separator, Delete scene… (`failure`).
- Light: the ground is flat `#FAFAFB`; the glow drops to 10 %; a gold disc gets its 1 pt `ember` edge; the gold line is the same 1.77:1 the Mixer's rail accepts, with the "System" pill and the `label` ink carrying the state in words.

## 7. Constraints and open decisions

- Platform: AppKit, macOS 14.4 deployment, Warm Signal tokens through `Tokens`. Contrast: every ink is an existing token on `panel`.
- **Reused, by name:** `PopoverColumnGrid`, the Mixer card header and subsection header (`PopoverPanelViewController`), `GroupIdentityGlowView`, `DeviceIcon`, `FeedPillView`, `BusRailOverlayView` / `RailPlan` / `MembershipBusView`, `MembershipRowView`'s checkbox wiring (`InvisibleSwitchCell`), `WarmNameFieldCell`, `CardMessageRow`, the Pair Bluetooth row recipe (`makePairBluetoothRow`), `HoverTracker`, `FoldAnimator`, `IconPickerViewController`, `GroupCreationSheetController`, `ContentPaneHostViewController`'s footer, the `.accessoryBar` text action.
- **New:** nothing drawn. One container that lays Mixer rows out as an outline and hands row frames to the rail overlay. **Builder's scoper decides, not the builder:** a view-based `NSOutlineView` (free outline keyboard handling and VoiceOver levels, stock disclosure hidden behind the row's chevron) versus the Mixer's stack with `insertRow` / `removeRow`. The rail overlay reads row frames either way.
- **Assumption:** one scene open at a time. Two open scenes would be two rails and two origins.
- **Assumption:** the mock marks Bedroom HomePod unavailable to show the unavailable states; the demo fleet marks every speaker available. Party's "Music" pill is illustrative; the fixture routes Music to a speaker, not a scene.
- **Assumption:** `GroupsPaneLayout.contentMaxWidth` (475 pt, derived from the Speakers split) no longer applies to a sidebar-free Scenes pane; the rows take the full 713 pt column grid. `GroupsOverviewLayout`'s comment still describes a 413 pt pane: a stale doc, report it, don't fix it here.
- **Tests that change:** `GroupsHeaderParityTests` (no scene header to hold level), `MembershipRailTests` (the rail starts at a row seat), the overview tests (deleted), the window snapshot for state 8.

**Open decisions, for the owner:**
1. Keep the creation sheet (recommended, as drawn) or fold creation into an unsaved row opened in place (B's recipe), later and separately.
2. Main Audio menu: add the row caption as a subtitle to each scene entry (recommended: the menu then shows an unavailable count before you pick) and whether an "Edit scenes…" item is wanted (not recommended; the tab is ⌘2 away).
3. Whether a folded playing scene should carry any rail mark at all (drawn with none: the pill and the ink carry it).
4. Scene order: saved order, which is the Main Audio menu's (drawn), or name order.
