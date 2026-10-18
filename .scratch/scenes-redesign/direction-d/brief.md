# Scenes tab, direction D: one matrix of speakers against scenes

Shape brief, Operate mode. No code. Assumptions are marked **[assumed]**; nobody was available to answer them.

## 1. Job and audience

- A Mac user with several speakers who has saved, or wants to save, a few named speaker sets (scenes) to switch to later from Main Audio in the Mixer.
- They come here to answer "which speakers are in which scene?" and to change that answer. Today that takes the card grid, a push into one scene's editor, a back button, and a second push for the next scene.
- They arrive calm: nothing on this tab plays sound. The Mixer is where audio is live.

## 2. Outcome and proof

- Primary task: add or remove a speaker from a scene with one click, with every scene's membership visible on the same screen.
- Success: the screen reads as the Mixer's speaker list with one membership rail per scene beside it. A user who knows the Mixer's rail can read this without being taught.
- Product truths the screen carries: scenes are configuration only; a scene needs at least one speaker; unavailable members stay members and are counted and named; the live scene is the one Main Audio plays to, set only from the Mixer.

## 3. Selected direction

- **Structure.** One screen, no editor push. Rows are the speakers in the Mixer's order and grouping: This Mac first with no header, then the **AirPlay Speakers** and **Bluetooth Speakers** subsection headers, which fold like the Mixer's. Columns are the saved scenes. The top-left corner holds the page title "Scenes" and a count.
- **Each column is a Mixer rail turned to run under one scene.** The rail starts under the scene's icon seat, runs down through every row, bows around each speaker that is not a member (the Mixer's detour arc) and ends at the lowest member. Below that, non-members show their ring with no line. These are the Mixer's rail rules 2, 6 and 8 from DESIGN.md "Membership rail extent", applied per column.
- **Colour follows DESIGN.md's editor rule, not a new one.** The live scene's column is `gold` from seat to last member: line, member discs and a 1.5 pt gold edge on the seat, with "Playing" in `goldText` under its name. Every other column draws its line and member discs in `ember`, which is what `GroupEditorViewController` already does for an inactive scene (`unarmedLineTone = ember`). A non-member is the 11 pt hollow ring in `railDormant`. **[assumed]** The task text said "gold-filled" for every member; drawing inactive members gold would claim audio is flowing to scenes that are not playing, which the temperature rule forbids, and it would leave the live column marked by its line alone.
- **Clicking a point toggles membership in place** and writes through `GroupController.saveGroup`, as the editor's checkboxes do. Nothing on the screen can make a scene live.
- **Focal moment.** The one gold column among ember ones. It is the same picture as the Mixer's gold rail, so the two tabs read as one instrument.

## 4. Scope and boundaries

Every job the four current pieces do keeps a home:

| Job today | Where it lives in D |
|---|---|
| Overview: see every scene, its count, Playing, Feeding, unavailable count | The column headers and the App Routing row (below) |
| Editor: change membership | Click a point |
| Editor: rename | Double-click the name or the header's context menu **Rename…**; the name becomes the existing `WarmNameFieldCell` field in place (Return commits, Escape reverts, empty restores the old name) |
| Editor: change icon | Click the seat, or **Change icon…** in the context menu; `IconPickerViewController` opens as a popover anchored to the seat, unchanged |
| Editor: delete | **Delete scene…** in the context menu, the existing "Delete “Party”?" alert |
| Editor: "Changes are saved as you go" | The surface footer keeps "Set up scenes here, then switch to the Mixer to play" |
| Creation sheet | Gone. A trailing **Add scene** column inserts a new column with its name field focused (next section) |
| Speakers tab "Add scene from N speakers…" | Switches to Scenes and inserts a new column with those N points already on, so it saves at once under "Scene" with the name field focused and selected **[assumed]** |
| Main Audio destination menu, scene entries | Unchanged, including "Save selected speakers as scene" |

- Anti-goals: no editor push, no sheet, no card, no sidebar (A, B and C own those). No drag-and-drop membership (ruled out in the 2026-08-27 brief). No volume, mute or activation on this screen.
- Untouched: toolbar strip, Pin, beak, the 713 pt width, the Mixer, the Speakers tab apart from where its add button lands.

## 5. States and ranges

- **Typical:** 7 to 12 speakers, 2 to 5 scenes. The mock uses the snapshot fleet: 10 speakers, 3 scenes, Downstairs live, Party fed by Music, Whole House holding 2 unavailable speakers.
- **Many scenes.** Columns are a fixed 84 pt. The speaker column is 210 pt, the sidebar width, so the matrix's left edge matches the Speakers tab. That leaves room for five scenes plus the Add scene column at 713 pt. A sixth scene scrolls the scene columns sideways on an overlay scroller. The speaker column stays fixed at the left, and the Add scene column stays fixed at the right edge. While scrolled, each fixed edge gets a 1 pt `containerEdge` rule, and a column passing under one is visibly cut. That follows DESIGN.md's reasoning for the twelfth row: a visibly cut item tells you the list scrolls. **[assumed]** There is no hard limit on scene count.
- **Many speakers.** The same twelve-row ceiling as the Mixer's Output Speakers list (504 pt). Rows scroll under a fixed header band.
- **Unavailable speaker.** The row's name is in `labelCool`, its icon in `labelCool2`, and "Unavailable" (or "Not connected" for Bluetooth) appears under the name, as `MembershipRowView` does now. In a cell, an unavailable member is a 15 pt `socket` disc with a 3 pt rim in the column's colour. That is the editor's existing `emphasizesDimmedMemberRim` treatment. The line still runs through it, because the speaker is still saved in the scene. The header counts it ("2 unavailable"). A speaker the Mac no longer knows keeps the existing "Missing speaker" row.
- **App routing to a scene.** An **App Routing** row under the matrix, behind a `containerEdge` rule, in the Mixer card's own words. A cell shows the icons of the apps routed to that scene (up to two, then "+N"). The tooltip and VoiceOver say "Feeding Music", the overview's existing wording. The row is read-only and its caption says "Set in the Mixer", because app destinations are chosen from the Mixer's App Routing card.
- **Folded subsection.** Each column whose members include a speaker in that subsection shows a 5 pt dot on the header's line, and its rail passes through or ends at that dot. These are rail rules 3 and 4 from DESIGN.md "Membership rail extent", per column.
- **Last member.** A column's only member cannot be turned off. The point takes no hover growth, and its tooltip is the editor's existing "A scene needs at least one speaker. Use “Delete scene…” to remove it."
- **New column.** Clicking Add scene inserts a column before it with the existing name field (placeholder "Scene name") focused. Its seat shows the default `rectangle.3.group` icon with no magenta glow, every point is a dormant ring, and there is no line. The meta line reads "Pick speakers" and the footer reads "Pick at least one speaker to save this scene. Escape cancels." The first point clicked saves the scene through `createGroup`, using "Scene" if the name is empty, as today's sheet does. The glow and the ember line then appear together. While the column is unsaved, Escape or leaving the tab removes it, and the Add scene column is disabled. **[assumed]** Keeping an unsaved column on screen instead of creating a placeholder scene is my reading of "the UI never lies".
- **Duplicate name.** The existing "That name is already taken." alert.
- **Zero scenes.** The speaker rows stay, with no points: the fleet the first scene is built from. Beside the Add scene column, a `CardMessageRow`-style message keeps today's empty copy: "Set up a scene" and "Save a set of speakers as a scene, then switch to it in two clicks from the menu bar."
- **Zero speakers.** The rows area shows the Mixer's existing `CardMessageRow` ("Looking for speakers…", or no speakers found).
- **Save failure.** The existing "Couldn’t save the change." alert, and the point returns to its saved state.

## 6. Interaction and layout

- **Header band, 100 pt.** From the bottom up: the 30 pt seat (a `well` square, `control` radius, with `GroupIdentityGlowView` behind it at its 60 pt size), then an optional status line ("Playing" in `goldText`, or "N unavailable" in `labelCool`), then "N speakers" in `captionDigits` / `labelCool`, then the name in `captionEmphasized`: `label` for the live scene and `labelCool` for the others, per `GroupsInkTemperatureTests`. The stack is bottom-aligned so every seat sits on one line and every rail starts at the same height, the way channel labels sit above jacks on a console. Long names wrap to two lines and then truncate, with the full name in the tooltip.
- **Rows.** The Mixer's 42 pt body row and 22 pt subsection header, the 14 pt leading inset, the 26 pt icon column and the name in `menuItem`. There are no fills or borders, and one `containerEdge` rule sits under the header band starting at the icon column.
- **Hover.** Pointing at a cell lights its row with the Mixer's 0.10 hover wash (inset 5 × 2 pt, `control` radius) and its column header with the same wash, so the speaker and the scene are both marked. The point grows by the existing `busNodeHoverGrowDuration` (0.12 s). The tooltip says the action: "Add Move 2 to Party" or "Remove Office from Party".
- **Keyboard.** The matrix is one Tab stop, like the current grid. Arrow keys move between cells and Space toggles. Up from the top row lands on the column header, where Return renames, Space opens the icon picker, and ⌘⌫ (Command-Delete) asks to delete. ⌘N adds a scene. The focused cell gets the stock focus ring, drawn as a circle around its point. Arrow-key focus also scrolls the columns sideways. **[assumed]** These key bindings are mine.
- **VoiceOver.** The matrix reports itself as a table. Each cell is a checkbox, read as "Office, Party, in scene", with the row and column as its headers. Each column header carries the overview's full meta line: "Party, 4 speakers, Feeding Music".
- **Motion.** A toggle redraws the line on the fold clock (0.15 s). Under Reduce Motion it changes at once. The rail's connect pulse does not run here, because nothing connects.
- **Light mode.** The ground is one flat `#FAFAFB`, so separation comes from rules alone. A gold member disc gets its 1 pt `ember` edge, because light gold measures 1.77:1 against the ground. The glow drops to 10 % magenta, and the hover wash is `label` at 0.10 on white.

## 7. Constraints and open decisions

- **Components reused:** `BusRailOverlayView` and `RailPlan` (one per column, with no sections, as the editor already passes), `MembershipBusView` nodes with `InvisibleSwitchCell` checkboxes, `GroupIdentityGlowView`, `WarmNameFieldCell`, `IconPickerViewController`, `CardMessageRow`, `HoverTracker` with `PopoverColumnGrid.fillRowWash`, `RuleView`, the Mixer's subsection header, and `FoldAnimator`. The `PopoverColumnGrid` constants are used as they are. The new code is a container that lays out one rail per column. It owns no drawing of its own, so DESIGN.md's list of custom-drawn pieces does not grow.
- **To retire:** `GroupsOverviewViewController`, `GroupEditorViewController`, `GroupCreationSheetController`, and the "‹ Scenes" back band.
- **Open, for the owner:**
  1. Whether inactive scenes' members stay `ember` (as drawn here, and as the editor does today) or go gold as the task text said.
  2. Whether a toggle that makes two scenes hold the same speakers is allowed. `createGroup` merges duplicate sets today; `saveGroup` from the editor is unchecked here.
  3. Scene order. Columns follow the saved order, which is also the Main Audio menu's order. Reordering by dragging a column header is not in this brief.
  4. Whether the App Routing row earns its 40 pt when no app is routed to any scene. Drawn here as hidden when empty **[assumed]**.
- **Risk.** At 84 pt a column cannot show "Feeding 3 apps" in the header, which is why app routing moved to its own row. If the owner wants everything a scene says in its header, the columns have to widen and the five-scene fit drops to four.
