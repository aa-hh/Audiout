# Scenes tab, direction A: the sibling of Speakers

Shape brief, 2026-10-06. No human was available to interview; every guess is marked **Assumption**.

## 1. Job and audience

- A general Mac user with several AirPlay speakers opens Scenes to save, rename, re-icon, re-member or delete a named set of speakers. They play it later from the Mixer's Main Audio menu.
- Visits are rare and short: set up once, adjust when a speaker is added or moved. Mode is Operate.
- They have usually already used the Speakers tab. Today Scenes looks like a different app: a card grid with a dashed tile, then an editor reached by an in-pane push with its own back button, Done button, rail-inset icon well and delete band.

## 2. Outcome and proof

- Success: someone who has used Speakers finds every Scenes action where the Speakers tab taught them to look, with no second layout to learn.
- Proof the screen must carry: which scene Main Audio is playing now, how many speakers each scene has, how many of them the Mac can't reach (named on the page), and which apps are sent to it.

## 3. Selected direction

The Scenes tab takes the Speakers tab's exact layout.

- **Sidebar (210 pt) lists the saved scenes.** It uses the Speakers sidebar's parts: `SidebarHeaderCellView` for the one section title, **Scenes**; `IconLabelCellView` rows; `SidebarRowView` with the stock selection pill; the same bottom add bar.
- **Each scene row has two lines.** The scene's icon, its name, and a caption saying "4 speakers" or "3 speakers · 1 unavailable" (the cards' existing wording). It reuses the row that is 12 pt taller, which the Speakers sidebar already uses for "Shown while in use".
- **The scene Main Audio is playing gets two marks.** Its name and icon are drawn in `label` while every other scene uses `labelCool`. Decision C5 already sets this, and `GroupsInkTemperatureTests` pins it. The row also ends in a gold `speaker.wave.2.fill` glyph (11 pt semibold), the marker the sidebar's group row wore before 2026-08-27 (`mixer-7-edit-active-group-dark.png`). The glyph sits on the name's line, so the caption keeps the row's full width. It is drawn in `goldText`, which equals `gold` in dark and is the darker text gold in light, where plain gold measures 1.77:1. Rows stay in name order: their position never says what is playing.
- **The content pane is a page,** laid out like the speaker page:
  1. `PageHeaderView` at the rail-free 14 pt inset, the same inset the speaker page uses. Under it sit `GroupIdentityGlowView` (magenta, all scenes) and `DeviceIconWellView` (1.5 pt gold edge on the playing scene; the pencil badge opens `IconPickerViewController`). The title is the existing rename field (`WarmNameFieldCell`). The caption reads "4 speakers", "3 speakers · 1 unavailable", or, on the playing scene, the gold wave glyph, then **Playing** in `goldText`, then " · 4 speakers". This matches the speaker page's caption pattern, where "Ready" is drawn in green.
  2. A **Speakers** title (body, `label2`), then one `GroupedSectionView` `.card` of `MembershipRowView` rows. Corners are `row` (16 pt) so the page has one corner radius, as on the speaker page.
  3. On the playing scene only, a `noteLabel` under the card: "Changes are saved as you go. They don't change what's playing now." (existing copy).
  4. Shown only while it is true: a `.card` holding one `ListRowView`, **Apps**, captioned "Sent to this scene from the Mixer", with the app names on the right. This gives the card's old "Feeding Safari" clause a home.
  5. A **Delete scene…** stock rounded button in an action band. The speaker page's Forget button sits in a band the same way.
- **What the Mixer lends: the membership rail, kept inside the card.** `BusRailOverlayView` stops climbing from the list up to the icon well. It runs inside the members card only, from the first member's node to the last. A non-member between them gets the Mixer's detour arc (rule 6). Rows below the last member show only their own circle. The colours stay as they are: `ember` on a saved scene; `gold` on the playing scene, with a gold disc only for a member the backend is actually sending to. A member added after the scene started playing keeps an `ember` disc on the gold line, which is the fact the note under the card states in words.
- **The one invention is that card-only rail extent,** a ninth rule for "Membership rail extent": on a scene page the rail starts at the first member's node, not at the icon well. With it, the header has no rail gutter, so the icon well sits at the same x on a scene page and a speaker page. `GroupsHeaderParityTests` can then hold the x equal, which it cannot do today.
- **Membership rows grow from 32 pt to 42 pt,** the Mixer's row height, so the rail's nodes are spaced as they are in the Mixer. Row order follows the Speakers sidebar: This Mac first, reachable speakers by name, then members the Mac can't reach. A speaker sits in the same order on both tabs.

## 4. Scope and boundaries

- **Overview card grid:** deleted. The sidebar does its job, listing scenes with member and unavailable counts and marking the one playing. Deleted with it: `GroupsOverviewViewController`, `NewGroupTileView`, `MemberChipView`, the card's `IconSeatView`, `GroupsOverviewLayout`, and `SidebarSelection.groupsOverview`.
- **Editor:** becomes the page. Removed: the "‹ Scenes" back button, Done/Save, `onBack`, ⌘[ and the in-pane push. Rename commits on Return or when the field loses focus, so changing the sidebar selection commits it; Escape reverts. Escape outside the field closes the bubble, as on Speakers.
- **Creation:** the bottom add bar reads **Add scene** (⌘N), the place where the Speakers sidebar puts it. It opens the existing `GroupCreationSheetController` sheet unchanged. After Create, the new scene is selected in the sidebar.
- **Deletion:** the row menu (**Rename…**, **Delete scene…**), ⌘⌫ on the selected row, and the page's button. All three use the existing confirmation alert. This is where the Speakers tab puts Forget.
- **Icon picker:** unchanged, opened from the well.
- **Main Audio destination menu:** scene entries keep their place under the Scenes section header. Each gains the sidebar caption as a subtitle, using the menu-item subtitle the App Routing menu already uses. A last item, **Edit scenes…**, opens the Scenes tab with the current scene selected. It mirrors "Manage speakers…".
- **Untouched:** shared chrome (toolbar strip, beak, pin), the Speakers tab including its own "Add scene from N speakers…" bar, the Mixer, the creation sheet's layout, all Analytics event names (`scene:created`, `scene:renamed`, `scene:membership_changed`, `scene:deleted` stay at their current call sites; the card grid had no events, so no event stream ends).
- **Anti-goals:** no activation anywhere on the tab, no dashed tiles, no green, no magenta outside the glow behind the well, no new gold beyond the three places listed above.

## 5. States and ranges

| State | Sidebar | Page |
|---|---|---|
| No scenes | The **Scenes** title, one inert caption row "No scenes yet" in `labelCool`, the add bar | Header with a plain well (`isEditable` off, `rectangle.3.group`), title "Set up a scene", caption "Save a set of speakers, then play it from the Mixer." Below it, a `.card` of `ListRowView` rows: "Save the speakers selected in the Mixer", captioned with their names, gold `ProminentButton` **Save as scene…** (shown only while at least one speaker is selected); and "Choose speakers", captioned "Pick from every speaker, even ones that are off.", stock button **Add scene…**. Both open the existing sheet, the first with those speakers checked and the name prefilled. |
| First scene saved | One row, selected | Its page |
| Typical: 2–5 scenes, 5–10 speakers | All rows visible | Page fits without scrolling |
| More than about 12 scenes | Stock scrolling | — |
| More than about 9 speakers | — | The page scrolls (it is already a `FlippedView` scrolling column) |
| Playing scene | Gold wave glyph, `label` inks | Gold well edge, Playing caption, gold rail, note under the card |
| Unavailable member | Counted in the caption | Row in `labelCool` with a `labelCool2` icon and "Unavailable" ("Not connected" for Bluetooth). Still checkable. |
| Unknown member id | Counted | "Missing speaker" row, no transport shown |
| Last remaining member | — | Its checkbox is pinned, with the existing tooltip |
| Save fails | — | The existing "couldn't be updated" alert |

## 6. Interaction and layout

- Clicking a scene shows its page and never activates it. Arrow keys move through the sidebar, Tab moves into the page, Return on a row focuses the rename field. The tab opens with the playing scene selected, otherwise the first scene.
- Selected-row inks take the selection pill's text colour (existing `applySelectionInks`). The gold glyph stays gold on the grey unfocused pill and takes the pill's text colour on the blue focused pill, where gold measures about 1.9:1 against the blue.
- VoiceOver reads a row as "Downstairs, 4 speakers, playing". The page name and **Speakers** are headings. The rail stays hidden from VoiceOver, and each node's checkbox says "Add Office to scene" or "Remove Office from scene", as today.
- Reduce Motion: no connect pulse on the rail. Sidebar moves happen with no animation.
- The footer caption stays: "Set up scenes here, then switch to the Mixer to play".

## 7. Constraints and open decisions

- Platform: AppKit, macOS 14.4 deployment, Warm Signal tokens through `Tokens`. Reused unchanged: `PageHeaderView`, `DeviceIconWellView`, `GroupIdentityGlowView`, `GroupedSectionView`, `ListRowView`, `MembershipRowView`, `BusRailOverlayView`, `noteLabel`, `ProminentButton`, `IconLabelCellView`, `SidebarHeaderCellView`, `SidebarRowView`, `ContentPaneHostViewController`, `GroupCreationSheetController`, `IconPickerViewController`.
- **Assumption:** "marked the way the Speakers sidebar marks what is sounding" means the old sidebar group-row marker. Today's Speakers sidebar marks reachability only ("The sidebar shows reachability, never routing", `AudioutWindowUI/AGENTS.md`). One stale comment: `GroupEditorViewController.buildPlayingBadge` says the sidebar's `IconLabelCellView` uses this glyph. It stopped doing so when direction C landed.
- **Assumption:** the reason scenes left the sidebar on 2026-08-27 was a growing fleet pushing them off the top of a shared list. With a sidebar of its own on its own tab, that reason no longer applies.
- **Assumption:** in the mock, Bedroom HomePod is unavailable, to show the unavailable states. The demo fleet marks every speaker available.
- **Assumption:** the empty-state caption is new copy. The current two-line subtitle does not fit on one caption line.
- **Open (owner):** whether the Speakers sidebar keeps a plain **Add scene** now that Scenes has its own, or shows only "Add scene from N speakers…" while two or more speakers are selected.
- **Open (owner):** the menu subtitles and **Edit scenes…**. Both are small additions, and the direction holds without them.
- **Open (builder must not decide alone):** whether the scenes sidebar is a sibling controller built from `SidebarViewController`'s cell classes or a mode on that controller. Recommendation: a sibling, so the speaker sidebar's reachability rules never see scenes.
- **Measured in the mock:** "7 speakers · 1 unavailable" takes about 136 pt of the caption's roughly 150 pt. A translation that runs longer would truncate. The fallback is the Speakers sidebar divider's slashed-antenna glyph plus the count at the trailing edge, with the words kept in the spoken label.
- **Tests that change:** `GroupsHeaderParityTests` (icon x now equal across both tabs), `MembershipRailTests` and `BusRailCollapseResolveTests` (the card-only start), sidebar tests for the new controller, the overview tests (deleted), and the window snapshot for state 8.
