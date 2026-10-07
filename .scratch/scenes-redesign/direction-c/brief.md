# Scenes tab, direction C: console plates

No human was available to interview (the skill's question step was replaced by the owner's discovery answers in `SHARED-BRIEF.md`). Every guess is marked **Assumption**.

## 1. Job and audience

- A Mac user with several speakers sets up named speaker sets once, then plays to them from the Mixer's Main Audio menu. Scenes is visited rarely, to check, fix or add a scene. Operate mode.
- What they need from the page: which scenes exist, what is in each one, which one Main Audio plays to now, and anything wrong (an unavailable member).

## 2. Outcome and proof

- Success: Scenes reads as a sibling of the Mixer and Speakers. A scene is drawn with the same parts the Mixer uses for a speaker set, so it stops reading as a tile from another app.
- Real content only: member names from the fleet, member counts, unavailable counts and names, "Feeding" app clauses. No live levels, nothing invented.

## 3. Selected direction

A scene is a **plate**: a `GroupedSectionView`-style `.card` holding

- the 48 pt `DeviceIconWellView` with `GroupIdentityGlowView` (magenta) behind it, at the plate's top left;
- the scene name in the page-header voice (`heading`, 16 pt semibold) with one caption line beside the well, laid out exactly as `PageHeaderView` lays out a page header;
- the members as a short vertical run of the Mixer's membership rail: the line hooks out of the well's leading edge (the way the editor's rail climbs to its well), runs down the 20 pt gutter (`railGutterCenterX`), and threads one 18 pt round seat per member, each seat a 1.6 pt ring (`ringStrokeWidth`) with the member's `DeviceIcon` glyph inside and the name beside it in `menuItem` ink.

The rail is `gold` (`spineTone`) on the plate Main Audio plays to and `railDormant` on every other plate. The page reads as a rack of small mixers.

The editor is the same plate opened large: an in-pane push where the plate's header becomes the page header (same well, same size, same name position) and its compact member run becomes the full membership card.

**The one new idea: shorter-column placement.** Plates sit in two 336 pt columns (14 pt margins, 13 pt gutter: 14 + 336 + 13 + 336 + 14 = 713). Each plate, in saved order, drops into whichever column is shorter at that moment. Plate height is 84 + 28 × rows, so an 8-member plate (308 pt) beside a 2-member plate (140 pt) and a 3-member plate (168 pt) balances to 308 / 321 with no holes. One column would put every name 300 pt from its rail end and drift toward direction B. A plain flow grid with row-aligned cells leaves a 170 pt hole beside every large scene.

## 4. Scope and boundaries

In scope: overview, editor, creation, icon picker, the Main Audio menu's scene entries.

| Job today | Home in this direction |
|---|---|
| Overview card grid | Plate field in a custom `NSCollectionViewLayout` (shorter-column placement); cells draw themselves |
| Dashed "Add scene" tile | Removed. A borderless `recessed` "Add scene" button (13 pt medium `plus`, `body`), the same control as the Speakers sidebar's add bar, sits at the trailing edge of the overview's page header. ⌘N reaches it |
| Card context menu (Rename…, Delete scene…) | Unchanged, on the plate |
| Scene editor | Plate opened large (section 6) |
| Creation sheet | **Survives**, recommended for now (open decision 1). It is the one place a scene can be made with no members selected yet, and the Speakers sidebar's "Add scene from N speakers…" already presents it |
| Icon picker | Survives unchanged: the anchored popover from the editor's well. The overview plate's well is a plain picture (`isEditable` off: no badge, no click of its own), so the plate owns the click |
| Main Audio menu scene entries | Each entry gets the scene's icon (12 pt symbol) and a second caption line with the plate's caption ("8 speakers · 1 unavailable"), the two-line entry `AppRowView`'s menu already builds. The tick marks the current one, as today |

Anti-goals: no sidebar (A), no Mixer rows on Scenes (B), no speakers-by-scenes grid (D). No gold wash, no gold plate edge, nothing on a plate that looks pressable to play. No dashed shapes.

## 5. States and ranges

- **Members per plate:** 1 to 8 show every member. Past 8, 7 rows show, then a row "and N more" in `caption` / `labelCool2`; the rail ends on the 7 pt dot the Mixer draws on a collapsed header that hides a reached speaker.
- **Scenes:** 1 to about 3 fit without scrolling at a typical screen height. More scroll inside the collection view (overlay scroller), the page header and footer holding still.
- **Active plate** (the one Main Audio plays to): well edge 1.5 pt `gold` (the well's existing active-scene rule), rail and seat rings `gold`, name and glyphs `label` instead of `labelCool` (the temperature rule `GroupsInkTemperatureTests` pins), and the caption's "Playing" clause with the gold `speaker.wave.2.fill` glyph and the word in `label2` (the editor's existing badge, so one state has one name). Tooltip on that clause: "Playing. Change what Main Audio plays to in the Mixer." Nothing else changes: no wash, no button, no hover difference.
- **Unavailable member:** seat ring `railDormant` and glyph `labelCool2` even on the active plate, name `labelCool`, "Unavailable" in `caption` / `labelCool2` at the row's trailing edge, and counted in the caption ("1 unavailable"). The rail still passes through it.
- **Missing speaker** (an ID the library doesn't know): row reads "Missing speaker", `speaker` glyph, same treatment as unavailable.
- **Feeding:** "Feeding Spotify" / "Feeding 3 apps" in the caption, as the current card's `feedingText` builds it.
- **Long names:** scene name and member names truncate at the tail; the caption truncates last.
- **Empty:** page header reads "Scenes" / "No scenes yet" with "Add scene" still in it. Below, one `.card` of two `ListRowView` rows: "No scenes yet" with a caption saying what a scene is and that it plays from Main Audio in the Mixer, and "Or start from the Mixer" pointing at "Save selected speakers as scene". No second button.
- **Light vs dark:** in light `raised` is the paper ground, so a plate is a `containerEdge` outline; the well, also `raised`, reads by its own edge with the magenta at 10 % around it. Gold on paper is 1.77:1, so in light the active state must never rest on gold alone: the word "Playing" carries it on the plate, and the editor's member discs keep their 1 pt `ember` edge.

## 6. Interaction and layout

**Overview page.** `PageHeaderView` (rail-free inset) with a plain 48 pt well showing `rectangle.3.group`, "Scenes" in `heading`, the count in `captionDigits` / `labelCool`, and "Add scene" trailing. 4 pt below its band, the plate field. Footer caption unchanged.

**Plate geometry (336 wide).** Well at x 34, y 14. Name block centred on the well, starting 12 pt after it (x 94), capped 14 pt from the trailing edge. Rail hook from (34, 38) to the gutter at x 20, radius 8. Member rows start at y 72, 28 pt each; seat 18 pt centred on x 20, the line broken 2 pt above and below each seat; name at x 40. 12 pt bottom padding. Plate radius `row` (16 pt).

**Pointer and keyboard.**
- Hover: the 0.10 `engagedChrome` wash over the plate (`HoverTracker`, `fillRowWash` alpha).
- One Tab stop for the whole field. Arrow keys move spatially (up and down within a column, left and right to the nearest plate across). Return or Space opens. Selection draws the stock `keyboardFocusIndicatorColor` ring around the plate's rounded rect plus the 0.10 wash: never gold.
- Click opens. Right-click gives Rename… and Delete scene….
- VoiceOver: one button per plate, labelled "Downstairs, 2 speakers, Playing, Sonos Move, Office", the members read in rail order and any unavailable one read as "Den, unavailable".

**Editor (plate opened large).**
- Top band unchanged: "‹ Scenes" (`.accessoryBar`) left, Done/Save right. Escape and ⌘[ go back.
- `PageHeaderView` (rail inset) with the editable well (pencil badge, glow), the `WarmNameFieldCell` rename field, and as caption the plate's own caption line ("2 speakers · Playing"), so the plate and the page say the same thing.
- "Speakers" label, then the `GroupedSectionView` `.card` of `MembershipRowView` rows for the whole fleet, rail in the gutter as today: members filled discs, non-members hollow with the detour arc.
- Under the card, `noteLabel`: "Changes are saved as you go." (plus "They don't change what's playing now." on the active scene).
- Then a second `.card` holding one `ListRowView`: "Delete scene", caption "Removes Downstairs from Scenes and from Main Audio's menu. Your speakers stay as they are.", trailing small stock button "Delete…" that runs the existing confirm. This replaces the free-floating delete band the owner flagged, with the speaker page's Forget-row grammar.

**Transition.** Opening tweens the plate's frame to the members card's frame on `FoldAnimator` over `collapseRevealDuration` (0.15 s); the header holds its size and slides to the page header position; the compact seat rows cross-fade into the membership rows; other plates fade. Back reverses it. Reduce Motion: cross-fade only.

## 7. Constraints and open decisions

**Reused, by name:** `DeviceIconWellView`, `GroupIdentityGlowView`, `PageHeaderView`, `GroupedSectionView` (`.card`), `ListRowView`, `MembershipRowView`, `BusRailOverlayView` (line, hook, end dot), `HaloRingView`-style ring at `ringStrokeWidth`, `DeviceIcon`, `HoverTracker` / `PopoverColumnGrid.fillRowWash`, `noteLabel`, `WarmNameFieldCell`, `IconPickerViewController`, `GroupCreationSheetController`, the recessed add button from `SidebarViewController`, `FoldAnimator`, the two-line menu entry from `AppRowView`.

**New custom drawing** (to be named in `AudioutWindowUI/AGENTS.md`): the plate cell view and its compact member seat. The shorter-column layout is a layout subclass, not drawing.

**Accessibility:** names `label` / `labelCool` and captions `labelCool` pass 4.5:1 on `raised` in both appearances. `railDormant` rings pass 3:1 (dark 3.47:1 on `panel`, light about 4.9:1). Gold rings in light do not (1.77:1); covered by words as above. The plate subscribes through `redrawOnAccessibilityDisplayChange()`; the glow and well already re-stamp.

**Open decisions, for the owner:**
1. Fold the creation sheet into the plate? A draft plate opened large with every speaker unchecked, "Create" in place of Done, discarded on Back. It removes the one surface still drawn in stock sheet white. Not recommended yet: the code records that an in-pane draft was replaced by this sheet once already, and a scene can't be saved with no members.
2. Editor rail tone for an inactive scene: today `ember` (`unarmedLineTone`); the plate draws `railDormant`. Matching them means the colour holds through the transition, at the cost of changing `MembershipRailTests`.
3. Should the overview header keep a well at all? Kept for parity with the Speakers Overview header; dropping it lets the plates own the well.
4. Plate order: saved order (assumed) or alphabetical.

**Assumptions marked:**
- **Assumption:** scenes and members come from the snapshot fixtures: Downstairs (Sonos Move, Office, active) and Party (Sonos Move, Office, Bedroom HomePod) from `window-snapshot`'s demo fleet; Whole House is that fleet's 7 speakers plus "Den" from the speaker-management fixture, to show 8 members with one unavailable.
- **Assumption:** "Feeding Spotify" on Party is illustrative; the fixture routes Music to a speaker, not a scene.
- **Assumption:** stock `NSCollectionView` arrow keys follow the custom layout's frames spatially; verify, else the subclass answers arrow keys itself.
- **Assumption:** the Scenes pane uses the full 713 pt (no sidebar), so the editor drops `GroupsPaneLayout.contentMaxWidth`'s 475 pt cap, which is derived from the Speakers split and no longer fits a sidebar-free page. `GroupsOverviewLayout`'s comment still describes a 413 pt pane: a stale doc.
- **Assumption:** the shared toolbar strip in the mock is drawn roughly for context only.
