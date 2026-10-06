# Scenes tab, direction F: the sibling of Speakers, showing only what a scene contains

Shape brief, 2026-10-06, Operate mode. Built on the owner's two rulings: A's topology, no status. `changes.md` beside this file says what came from A and from E2. Guesses are marked **Assumption**. The mock is `mock.html` / `mock.png`.

## 1. Job and audience

- A Mac user with two to twelve speakers who saves named speaker sets and plays them from the Mixer's Main Audio menu. They come here to see what is in a scene and to change it, rename it, re-icon it, or delete it.
- Visits are short and rare. They have used the Speakers tab; Scenes must put every action where Speakers taught them to look, with no second layout and no vocabulary.

## 2. Outcome and proof

- Primary task: pick a scene, change its speakers, name or icon, leave. Two clicks to a membership change.
- Success: someone who has used Speakers finds every Scenes action in the same place, and nothing on the tab makes them ask what a state word means.
- Real content only: scene names, member names and counts from the fleet; an unreachable member named plainly in its row. Nothing about playback, routing or levels.

## 3. Selected direction

**Thesis.** The Scenes tab is the Speakers tab's layout with scenes in the sidebar and one scene's setup on the page. The page is the editor.

**Visual authority.** DESIGN.md and PRODUCT.md as they stand. Nothing new enters `Tokens`; nothing new is drawn.

**Sidebar (210 pt, `SidebarViewController`'s parts).**
- One section title, **Scenes** (`SidebarHeaderCellView`, `captionEmphasized` / `labelCool`, spoken as a heading).
- One `IconLabelCellView` row per saved scene, saved order: the scene's `DeviceIcon` glyph, the name in the row's own font, and under it the count in `caption` / `labelCool` ("3 speakers"), on the 12 pt taller captioned row the Speakers sidebar already uses. All names and glyphs in `label`; no mark of any kind distinguishes one scene from another.
- The stock selection pill. A selected row's inks take the pill's text colour (`applySelectionInks`).
- The bottom add bar, **Add scene** (`recessed`, `plus`), ⌘N. It opens `GroupCreationSheetController` unchanged; after Create the new scene is selected.
- Row menu: **Rename…** (focuses the page's field), **Delete scene…**; ⌘⌫ on the selected row. All use the existing confirmation alert.

**Page (the selected scene, `ContentPaneHostViewController` on `WarmPanelView`).**
1. `PageHeaderView` at the rail-free 14 pt inset (`railFreeContentLeadingInset`), the same band height and centring `GroupsHeaderParityTests` holds for a speaker's page: `DeviceIconWellView` (48 pt, `containerEdge` edge, pencil badge, `GroupIdentityGlowView` behind it at its 60 pt size), the `WarmNameFieldCell` rename field as the title, and the caption "3 speakers" in `caption` / `labelCool`. Commit on Return or focus loss; Escape reverts; empty restores the old name. The well opens `IconPickerViewController`.
2. `sectionGap` (20 pt) below the band, a **Speakers** title in `body` / `label2`, spoken as a heading; `labelToSectionGap` (6 pt) to the card.
3. One `GroupedSectionView` `.card` at the `row` radius (16 pt), the radius every box on a speaker's page takes, on the page's 14 pt lane. Inside, one `MembershipRowView` per speaker in its plain checkbox form (the creation sheet's `.systemSheet` host), 32 pt, `containerEdge` dividers: stock checkbox, glyph, name in `label`. Every speaker is listed, in the Speakers sidebar's order: This Mac, then the speakers the Mac can reach by name, then the ones it can't by name. An unreachable speaker keeps `labelCool` name, `labelCool2` glyph and "Unavailable" ("Not connected" for Bluetooth) at the trailing edge; an unknown id reads "Missing speaker". The whole row toggles; the checkbox is the control. The last member refuses with today's tooltip.
4. `actionBandGap` (22 pt) below the card, the action band: a small stock rounded **Delete scene…** button on the lane, and beside it "Changes are saved as you go." in `noteLabel`'s style. This is where the speaker page hangs Forget.
5. The host footer: "Set up scenes here, then switch to the Mixer to play".

**Focal moment.** None by design. A page of checkboxes under a name you can type in: the same picture as the sheet that made the scene.

**Implementation consequence.** `GroupsOverviewViewController`, `GroupCardView`, `NewGroupTileView`, `MemberChipView`, `GroupsOverviewLayout` and `SidebarSelection.groupsOverview` go. `GroupEditorViewController` loses the back band, Done/Save, `onBack`, ⌘[, the rail overlay, the playing badge, `isActiveGroup` on the well and the `.editor`-host membership rows; its header, field, card, delete band and persistence stay, with rows built as the sheet builds them. A scenes sidebar is a sibling controller built from `SidebarViewController`'s cell classes (**builder's scoper decides** sibling versus mode; recommendation: sibling, so the speaker sidebar's reachability rules never see scenes). `MixerWindowController` routes the scenes host between the page and the empty page.

## 4. Scope and boundaries

- In: the Scenes sidebar, the page, the empty page, the creation sheet's doors, the icon picker's anchor.
- Untouched: the toolbar strip, beak, Pin, the 713 pt width, the Mixer, the Speakers tab including "Add scene from N speakers…" (presents the sheet, then switches to Scenes with the new scene selected), Settings, the Main Audio menu, every token, the sheet's and picker's contents, every Analytics event name (`scene:created`, `scene:renamed`, `scene:membership_changed`, `scene:deleted` stay at their call sites; the grid had no events).
- Anti-goals: no state text or glyph on any row or on the page ("Playing", "Feeding", a wave, a gold edge, warm-versus-cool ink by playback); no routing, volume, mute or activation; no rail, no pills, no grid, no push, no Done; no gold anywhere on the tab; no green; no magenta outside the glow behind the well.

| Job today | Home in F |
|---|---|
| Overview cards | Sidebar rows |
| Open the editor | Select a row |
| Rename | The page's field; Rename… in the row menu |
| Change icon | The well's pencil badge; the picker |
| Membership | Checkbox rows on the page |
| Delete | The action band, the row menu, ⌘⌫; today's alert |
| Create (sheet) | Add scene, ⌘N, the Speakers sidebar's bar |
| Playing / Feeding | Dropped from this tab; the Mixer shows them |
| Unavailable member | Its row's annotation |

## 5. States and ranges

| State | Sidebar | Page |
|---|---|---|
| No scenes | The **Scenes** title, one inert caption row "No scenes yet" in `labelCool`, the add bar | Plain well (`rectangle.3.group`, `isEditable` off), "Scenes" in `heading`, caption "No scenes yet". A `.card` of two `ListRowView` rows: **Add scene…** with a stock button, caption "Pick the speakers that play together. You switch to a scene from Main Audio in the Mixer."; **Or start from the Mixer**, caption "Select speakers there, then choose Save selected speakers as scene from Main Audio's menu." |
| First scene saved | One row, selected | Its page |
| 2–5 scenes, 5–10 speakers | All rows visible | Page fits without scrolling |
| More than about 14 scenes | Stock scrolling | — |
| More than about 12 speakers | — | The page scrolls (a `FlippedView` column) |
| Unavailable member | Nothing | Row last in the list, annotated, still checkable |
| Unknown member id | Counted | "Missing speaker" row |
| Last remaining member | — | Checkbox pinned, existing tooltip |
| Save fails | — | The existing "couldn't be updated" alert |

## 6. Interaction and layout

- Selecting a scene shows its page and never activates it. ↑/↓ move the sidebar, Tab enters the page, Return on a row focuses the field. The tab opens with the first scene selected (**Assumption:** saved order, the Main Audio menu's order).
- Hover on a membership row is the 0.10 `engagedChrome` wash (`HoverTracker`); the well steps up its badge on hover or focus. Never gold.
- VoiceOver reads a sidebar row as "Party, 3 speakers"; the page name and **Speakers** are headings; each checkbox is stock ("Office, checkbox, checked", adding "unavailable" where true). Reduce Motion: sidebar moves with no animation; the well's badge changes alpha with no fade.
- Light: the flat `#FAFAFB` ground; the card and the well read by their `containerEdge` outline; the glow at 10 %; the sidebar's stock material.

## 7. Constraints and open decisions

- Platform: AppKit, macOS 14.4 deployment, tokens through `Tokens`. Every ink is an existing token on `panel` or `raised`.
- **Reused, by name:** `SidebarViewController`'s `SidebarHeaderCellView`, `IconLabelCellView`, `SidebarRowView` and add bar; `PageHeaderView`; `DeviceIconWellView`; `GroupIdentityGlowView`; `WarmNameFieldCell`; `GroupedSectionView` (`.card`, `row` radius); `MembershipRowView` (`.systemSheet` form); `ListRowView`; `noteLabel`; `GroupsPaneLayout`'s cadence (`columnTopInset`, `sectionGap`, `labelToSectionGap`, `actionBandGap`); `ContentPaneHostViewController` and its footer; `GroupCreationSheetController`; `IconPickerViewController`; `DeviceIcon`.
- **Assumption:** the page's column keeps `GroupsPaneLayout.contentMaxWidth` (475 pt), which is derived from exactly this sidebar split, so the card is the same width as a speaker page's list.
- **Assumption:** Bedroom HomePod is drawn unavailable to show that state; the demo fleet marks every speaker available.
- **Tests that change:** `GroupsHeaderParityTests` (the well's x is now equal on both tabs, which it could not be while the editor kept its rail inset), `MembershipRailTests` and `BusRailCollapseResolveTests` (the editor's rail is gone; the Mixer's stays), `GroupsInkTemperatureTests` (no temperature on this tab), the overview tests (deleted), the window snapshots for states 3, 7 and 8.

**Open decisions, for the owner:**
1. Whether the Speakers sidebar keeps its plain **Add scene** now that Scenes has its own, or shows the bar only as "Add scene from N speakers…" with two or more selected.
2. Keep the creation sheet (drawn) or, later, let the page itself be the draft for a new scene.
3. Scene order in the sidebar: saved order (drawn) or name order.
4. Whether the sidebar caption should also carry "· 1 unavailable" (not drawn: the ruling says the count and nothing more).
