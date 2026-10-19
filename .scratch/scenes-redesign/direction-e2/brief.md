# Scenes tab, direction E2: one list of scenes that open in place

Shape brief, 2026-10-06, Operate mode. Revision of E after the owner's three notes; `changes.md` beside this file says what moved. No human was available; guesses are marked **Assumption**. The mock is `mock.html` / `mock.png`.

## 1. Job and audience

- A Mac user with two to twelve speakers who has saved, or wants to save, a few named speaker sets. They play a scene from the Mixer's Main Audio menu; they come here to see what is in each scene and to change it, rename it, re-icon it, or delete it.
- Visits are short and rare. Audio may be running in other rooms; nothing here may change what is heard, and nothing here sets where anything is sent.
- They read the Mixer every day. Scenes must need no second reading skill and no vocabulary.

## 2. Outcome and proof

- Primary task: see every scene and who is in it, then change one scene's speakers, name or icon without leaving the list.
- Success: from the Scenes tab alone a user can say which scene Main Audio plays to and which members the Mac can't reach, and can fix membership in two clicks.
- Real content only: member names and counts from the fleet, unavailable members named, "Playing" only while true. No live levels, nothing invented.

## 3. Selected direction

**Thesis.** Scenes is one column of Mixer rows under one card header, separated by hairlines. A scene row carries the group's identity in the icon column, its members in the caption and its status in the trailing slot. Clicking a scene opens it in place: its checklist drops in as a card under the row, the Mixer's own inset-card geometry, holding the module's plain checkbox rows.

**Visual authority.** DESIGN.md and PRODUCT.md as they stand. Nothing new enters `Tokens`. No new custom-drawn piece.

**Structure, top to bottom.**

1. **Card header**, the Mixer's 28 pt rank: "Scenes" in `captionEmphasized` / `label2` at the name column, no chevron (the tab's only card), no legends (there are no columns). It never turns gold.
2. **One scene row per saved scene**, 42 pt, saved order, on `PopoverColumnGrid`, a 1 pt `hairline` under each starting at the icon column (`GroupedSectionView` `.bare`):
   - Icon column: the scene's `DeviceIcon` glyph with `GroupIdentityGlowView` behind it at its 60 pt size, as the Main Audio row draws a scene destination. No ring.
   - Name in `menuItem`: `label` on the scene Main Audio plays to, `labelCool` otherwise.
   - Caption, `caption` / `labelCool`: the count, then the members, an unreachable one named first: "3 speakers · Bedroom HomePod unavailable · Office, Sonos Move". Two or more unreachable read "2 unavailable". Names truncate at the tail; the count never does. The tooltip names everyone.
   - Trailing status caption, right-aligned before the chevron: on the playing scene the gold `speaker.wave.2.fill` glyph and "Playing" in `goldText` (the editor's `buildPlayingBadge`); when apps are routed here, "Feeding Music" / "Feeding 3 apps" in `labelCool`, the card's old clause; both joined by " · " when both hold. Tooltip and spoken value on "Playing": "Main Audio is playing to this scene. Change it in the Mixer."
   - A 10 pt semibold `chevron.right` in `labelCool2` at the trailing inset, `chevron.down` while open.
3. **An open scene** adds, under its row:
   - The row's name becomes the editor's `WarmNameFieldCell` field, followed by a small "Change icon…" text action in `menuItem` / `.accessoryBar`. Commit on Return or focus loss, revert on Escape, restore the old name when emptied.
   - A `GroupedSectionView` `.card` mounted like the Mixer's inset card under a device row: from the icon column to the row's trailing inset, 4 pt above and below, `control` radius, 6 pt vertical padding, `containerEdge` dividers. Inside, one `MembershipRowView` per speaker in its plain checkbox form (the creation sheet's `.systemSheet` host), 32 pt: stock checkbox, glyph, name in `label`, and for an unreachable speaker `labelCool` name, `labelCool2` glyph and "Unavailable" ("Not connected" for Bluetooth) at the trailing edge; an unknown id reads "Missing speaker". Every speaker is listed in the Mixer's order (This Mac first, then by name), unavailable ones included. The row is one click target; the checkbox is the control.
   - Under the card, outside it, a `CardMessageRow` on the indented name column: one small stock rounded "Delete scene…" button and "Changes are saved as you go." ("…They don't change what's playing now." on the playing scene). Then the scene list's hairline.
4. **"Add scene"** closes the list: `plus` glyph and `menuItem` in `label2` on the icon and name columns, the Mixer's Pair row recipe. It opens `GroupCreationSheetController` unchanged; ⌘N reaches it. After Create, the new scene opens in place.
5. The host footer stays: "Set up scenes here, then switch to the Mixer to play".

**Focal moment.** The one open scene: its checklist card dropped into the list, every speaker ticked or not, with the same checkbox rows the sheet showed when the scene was made.

**Implementation consequence.** `GroupsOverviewViewController`'s grid, `GroupCardView`, `NewGroupTileView`, `MemberChipView` and `GroupsOverviewLayout` go. `GroupEditorViewController` stops being a pushed page: back band, Done/Save, `PageHeaderView`, the rail overlay and `.editor`-host membership rows go; rename, icon, membership and delete logic move into the open row, with `MembershipRowView` built as the sheet builds it. `GroupCreationSheetController` and `IconPickerViewController` are unchanged.

## 4. Scope and boundaries

- In: the Scenes overview, the editor, the creation sheet's door, the icon picker's anchor.
- Untouched: the toolbar strip, beak, Pin, the 713 pt width, the Mixer, the Speakers tab including its "Add scene from N speakers…" bar (presents the sheet, then switches to Scenes with the new scene open), Settings, the Main Audio menu, every token, the icon picker's contents, every Analytics event name (`scene:created`, `scene:renamed`, `scene:membership_changed`, `scene:deleted` move to the new choke points; the grid had no events).
- Anti-goals: no sidebar, grid, cards per scene, plates or rail; no slider, mute, volume, routing or activation on Scenes; no pills; no ring on a scene row; no gold beyond the "Playing" glyph and word; no green; no magenta outside the glow; no dashed shapes.

| Job today | Home in E2 |
|---|---|
| Overview cards | Scene rows |
| Open the editor | Click the row, → or Return |
| Rename | The open row's name field; "Rename…" in the context menu focuses it |
| Change icon | "Change icon…" after the field, a click on the seat, or the context menu; picker anchored to the seat |
| Membership | Checkbox rows in the open scene's card |
| Delete | The closing row's button, "Delete scene…" in the context menu (`failure` ink), ⌘⌫; today's alert |
| Create (sheet) | "Add scene" row, ⌘N, the Speakers sidebar's bar |
| Playing / Feeding / unavailable count | The trailing status caption and the row caption |

## 5. States and ranges

- Range: 0 to about 8 scenes, 1 to about 12 speakers. One scene open: 8 × 42 + 12 × 32 + 20 + 42 ≈ 780 pt worst case; past the Mixer's twelve-row ceiling (504 pt) the list scrolls under the card header on overlay scrollers, the header and footer holding still.
- Empty: the card header, a `CardMessageRow` ("No scenes yet", today's hint), then "Add scene".
- Playing scene: `label` inks and the trailing "Playing"; open, the note under the card adds "They don't change what's playing now."
- App-fed scene: "Feeding Music" trailing.
- Unavailable member: counted and named first in the caption; dimmed row with "Unavailable" in the card. Unavailable non-member: listed, still joinable (owner's call 2026-08-28).
- Last member: the checkbox refuses with today's tooltip ("A scene needs at least one speaker. Use "Delete scene…" to remove it.").
- Errors: today's alerts, unchanged.

## 6. Interaction and layout

- The whole scene row opens or folds it, except the seat (picker) and, when open, the field and "Change icon…". Opening another scene folds the open one. Hover is the 0.10 `engagedChrome` wash via `HoverTracker`; a keyboard-selected row takes 0.18. Never gold.
- The card drops in on `FoldAnimator` (0.15 s) through `insertRow` / `removeRow`; Reduce Motion lands it at once.
- Keyboard: ↑/↓ move between rows (scenes, then the open scene's speakers), → opens, ← folds or returns to the scene, Space toggles a checkbox, Return on a scene focuses its name field, ⌘N adds, ⌘⌫ deletes after the alert. Escape folds the open scene, then closes the bubble.
- VoiceOver: outline semantics. A scene row speaks "Downstairs, scene, 2 speakers, playing, collapsed"; a speaker row is the stock checkbox, "Office, checkbox, checked", adding "unavailable". The card title is a heading.
- Context menu on a scene row: Rename…, Change icon…, separator, Delete scene… (`failure`).
- Light: flat `#FAFAFB`; the glow at 10 %; the card reads by its `containerEdge` outline; hairlines `#CBCED4`; "Playing" in the darker text gold.

## 7. Constraints and open decisions

- Platform: AppKit, macOS 14.4 deployment, Warm Signal tokens through `Tokens`. Every ink is an existing token on `panel` or `raised`.
- **Reused, by name:** `PopoverColumnGrid`, the Mixer card header, `GroupIdentityGlowView`, `DeviceIcon`, `GroupedSectionView` (`.bare` dividers, `.card` box), the Mixer inset-card mount (`insertRow` / `removeRow`), `MembershipRowView` (`.systemSheet` form), `WarmNameFieldCell`, `CardMessageRow`, the Pair Bluetooth row recipe, `HoverTracker`, `FoldAnimator`, `IconPickerViewController`, `GroupCreationSheetController`, the editor's playing badge, the host footer, the `.accessoryBar` text action.
- **New:** nothing drawn. One container that lays Mixer rows out as an outline. **Builder's scoper decides:** view-based `NSOutlineView` versus the Mixer's stack.
- **Assumption:** one scene open at a time.
- **Assumption:** the mock marks Bedroom HomePod unavailable; the demo fleet marks every speaker available. Party's "Feeding Music" is illustrative.
- **Assumption:** `GroupsPaneLayout.contentMaxWidth` (475 pt) no longer applies to a sidebar-free pane. `GroupsOverviewLayout`'s comment still describes a 413 pt pane: stale, report, don't fix here.
- **Assumption:** the card's trailing edge uses the row's 14 pt inset rather than the Mixer inset card's 10 pt, so its edge lands under the chevron and the hairlines.
- **Tests that change:** `GroupsHeaderParityTests` (no scene header), `MembershipRailTests` and `BusRailCollapseResolveTests` (the editor's rail is gone; the Mixer's stays), the overview tests (deleted), the window snapshot for state 8.

**Open decisions, for the owner:**
1. Keep the creation sheet (drawn) or fold creation into an unsaved open row later.
2. Whether "Feeding Music" belongs on this tab at all, now that routing has no other presence here (drawn, in `labelCool`, as the card shows it today).
3. Scene order: saved order (drawn) or name order.
