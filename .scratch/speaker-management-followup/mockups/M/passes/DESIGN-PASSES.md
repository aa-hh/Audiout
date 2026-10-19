# Design passes merged: Speakers tab, direction M with sidebar direction C

Merges `LAYOUT.md`, `AUDIT.md`, `COLORIZE.md` and `TYPESET.md` (impeccable layout, audit, colorize, typeset; 2026-10-04; code at `claude/speakers-nav` b9b70310). Each item names the pass items it comes from. "Conflicts resolved" says which pass wins where they disagree; the merged list already follows those rulings. Line numbers without a file are `SidebarViewController.swift`.

## Conflicts resolved

1. **Ink of the sidebar's headers and caption, and of the overview's labels.** TYPESET kept warm `label2` (section titles, "Available", tile labels, total) and `label3` (subsection headers, row caption, zeros). AUDIT assumed C's `label2` headers. COLORIZE moves all of them to the cool rungs. COLORIZE wins: you rejected the brown, and `label2` light `#6B5F4E` is that brown. TYPESET's own fallback ("if subsection headers turn cool, use `labelCool` and keep `captionMedium`") is what is taken; its weights stand. Result: secondary text `labelCool`, glyphs and zeros `labelCool2`, primary text `label`. The Mixer keeps its warm header pair, because that tab shows sound and this one does not (`Tokens.swift:497-498` defines `labelCool` for exactly this kind of surface).
2. **The 11 pt styles stay distinct once they share one ink.** With everything cool, TYPESET's ink step between the divider label and the row caption is gone. They stay apart by weight, position and what sits beside them:
   - section title: semibold, x 14, 28 pt of space above its text, a plate under it;
   - subsection header: medium, x 14, its own 19 pt row, 16 pt of space above its text;
   - divider label: regular with tabular digits, x 46, the no-signal glyph before it and a rule after it, its own 24 pt row;
   - row caption: regular, x 46, 2 pt under a 13 pt name inside a speaker row, nothing beside it.
3. **Grid and row heights.** TYPESET, COLORIZE and AUDIT used the mockups' 28 pt rows and x 18 / x 48. LAYOUT rebuilt the code's source list (`.sourceList` :174, `.medium` :182) in scratch AppKit programs on macOS 27 and measured 32 pt rows, 13 pt added by the source list above every group row, headers at x 14, icons x 16-38, names x 46. LAYOUT wins; every position and height below is its. The 2026-08-12 window snapshot drew 28 pt rows, so confirm the row height on the live sidebar before building. LAYOUT wrote heights against the outline's row height (R), so plates (R + 8) and the captioned row (R + 12) hold either way.
4. **Name width and truncated strings.** TYPESET used C's 144 pt and simulated "Move 2 (SO… Bedroom)". LAYOUT measured 140 pt (C counted the text field's 2 pt padding on each side), 123 pt when the list scrolls with scroll bars always shown, and rendered middle truncation in AppKit. LAYOUT's table wins.
5. **Space above "Speakers".** AUDIT 2 grew the title row 16 pt; LAYOUT 3 grows it 12, because the source list already adds 13 above every group row. LAYOUT wins.
6. **Selected rows.** All three agree the cell's inks must change when its row is selected. COLORIZE sets `label` and relies on AppKit drawing custom colours white on the accent pill, which it measured on macOS 27 only. AUDIT and TYPESET set `alternateSelectedControlTextColor` on the accent pill and `label` on the grey pill. AUDIT and TYPESET win: the app runs from macOS 14.4, and the explicit colour does not depend on that whitening. The mechanism (a row view that tells its cell when `isSelected` or `isEmphasized` changes, as `PlateRowView` does at :945) is shared by COLORIZE and AUDIT.
7. **Count font.** LAYOUT 7 kept "`heading` with tabular digits" and AUDIT 12 set the en dash in `heading`. `heading` has proportional digits (`Tokens.swift:1269-1271`), so TYPESET's new `Tokens.Font.headingDigits` wins for the counts and the dash.
8. **Header total while loading.** TYPESET 9: the placeholder alone, then "20 speakers" fades in as one string. AUDIT 12: "Looking for speakers…" under Reduce Motion. Both kept, each for its own setting (owner call 3). VoiceOver says "Looking for speakers" in both, replacing BRIEF.md line 186's "still looking".
9. **Heading role on the sidebar titles.** AUDIT 1 adds it only on macOS 26 and later, behind `#available`. The Mixer already sets it on every version with the raw role string: `markAsAccessibilityHeading` calls `setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))` (`PopoverPanelViewController.swift:1379-1381`), used on its subsection headers (`:1421-1423`). Use the same call on all four sidebar titles, no version gate, so the two tabs match. AUDIT's spoken labels stay the main cue.
10. **Sidebar ground for contrast.** AUDIT measured an opaque `#F0F0F0` light and `#282828` dark. COLORIZE read the source-list colour as translucent and bracketed `#E8E8EA`-`#F8F8F8` / `#1E1E20`-`#2C2C2E`. The code says the source list paints its own opaque background (`MixerWindowController.swift:169-171`), so AUDIT's values are the reference on macOS 27 and COLORIZE's bracket covers 14.4 to 26. Every ink assigned below passes on both.
11. **Fonts the code sets on header and plate labels.** LAYOUT measured that at `.medium` the table replaces the font of any cell's `textField` outlet (group rows become 11 pt regular, other rows 13 pt regular). So today's `captionEmphasized` header (:1250), the plate's `bodyEmphasized` (:1285) and TYPESET's new `captionMedium` pool would not show as specified. Resolution: header, plate and divider labels are labels the cell owns but not its `textField` outlet. Speaker names stay in the outlet, where the 13 pt source-list font is wanted and the full-name tooltip needs them. AUDIT's spoken labels go on whichever label shows the text. Check the live sidebar first: if its headers already render semibold, this item drops.

## Merged amendments

### Sidebar structure and geometry
1. Redraw both mockups on the measured grid: rows 32, 13 pt above every group row, headers x 14, icons x 16-38 (13 pt medium symbols), names and divider label x 46, text ends x 186, plate chevrons end x 192. C BRIEF "Geometry" and "New grid" change to match; M BRIEF line 29 (128 pt column) is stale. (LAYOUT 1)
2. Row heights through `heightOfRowByItem` (:1142-1151): titles and subsection headers 19, text 3 pt above the row's bottom (pinned, not centred, :1262); "Speakers" title 31 (19 + 12); Main Audio and Overview plates R + 8 (40 at R = 32); speaker row R; row with "Shown while in use" R + 12; divider 24; Add scene bar R. Space from the row above to heading text: 28 before a section title, 16 before a subsection header, 8 before a divider label; each heading's text sits 3 pt above the first row it heads. (LAYOUT 2)
3. The 16 pt spacer row goes; the space lives inside the "Speakers" title row. No blank row for arrow keys or VoiceOver to stop on. (LAYOUT 3, AUDIT 2)
4. Tree: the "Speakers" title holds the Overview plate as its child, as "System Audio" holds Main Audio (:529). The two subsection headers stay top-level. (AUDIT 1)
5. Add scene bar: plus centred on x 27, "Add scene" from x 46.5, one `NSButton` with a padded 26 × 22 pt template image; pin its leading edge at x 16. Take the hairline above the bar out of the mockups; the code draws none. (LAYOUT 5)
6. Names: middle truncation on the name field only (:1343), `allowsExpansionToolTips = true` on the outline (set nowhere today). At 140 pt / 123 pt: "Move 2 (S…Bedroom)" / "Move 2 (…Bedroom)"; "Sonos Mo…S Kitchen)" / "Sonos M…Kitchen)"; "MacBook Pro Speakers" whole / "MacBook…Speakers". Headers, caption and plates keep tail truncation; nothing else truncates in English. Mockups draw the Sonos rows middle-truncated at 140 and add one panel at 123. (LAYOUT 6, TYPESET 4)

### Sidebar divider row
7. 24 pt row, child of its group, not a group item. Glyph `antenna.radiowaves.left.and.right.slash`, 11 pt regular, `labelCool`, in a 22 pt box centred on x 27, sitting on the label's first baseline. Label "N unavailable" in `captionDigits` (new, item 20) and `labelCool` at x 46, its box 3 pt above the row's bottom. Rule 1 pt `Tokens.Color.separator` from 8 pt after the label to x 192, centred 3 pt above the label's baseline (replaces C's "vertically centred"). Glyph and label are not the cell's outlets (conflict 11). (LAYOUT 4, COLORIZE 5, TYPESET 6)
8. Never selectable: `shouldSelectItem` returns false for it by name (today it returns `!isGroupItem`, :1134-1137, and the divider is not a group item). No menu; `selection(for:)` returns nil. One spoken element, "8 unavailable speakers" / "1 unavailable speaker", set on every reuse; glyph and rule hidden from VoiceOver. The rule measures 1.24 / 1.36:1 and is decoration, exempt from 3:1. (AUDIT 5)

### Sidebar type and colour
9. Changes from today's code (full spec in "Final style table"): section titles `label2` → `labelCool` (:1251); subsection headers move to their own cell pool in `captionMedium` / `labelCool` (TYPESET 2); unreachable names `label3` → `labelCool`, icons `label3` → `labelCool2` (:1298-1300); "Shown while in use" `label3` → `labelCool` (:850); plate chevrons `label3` → `labelCool2` (:838). `labelCool2` is never used for sidebar text: 4.06-4.29:1 on the dark ground. (COLORIZE 1-6, TYPESET 1-2)
10. Leaving with M and C: the gold active marker (:815-828), the dot's ember and gold states (:978-992), the failure triangle (:993-1000). No gold, red or green in the sidebar. (COLORIZE 10)

### Selection, updates and repaint
11. Selected cells: name, icon, caption and chevron take `alternateSelectedControlTextColor` on the accent pill and `label` on the grey pill. Speaker rows and the Main Audio plate get a row view that re-applies its cell's colours when `isSelected` or `isEmphasized` changes; today only the Overview plate has one (:1157-1166). Check on macOS 14 with `scripts/run-on-vm.sh`. Mockup: add an unreachable row selected on the grey pill. (AUDIT 3, COLORIZE 7, TYPESET 3)
12. The same colour code runs over the visible rows on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`. Today only the dot listens for Increase Contrast (:965), and C removes the dot. (AUDIT 7)
13. P1. The sidebar keeps one `Node` per device id across every update and applies moves, inserts and removes inside `beginUpdates`/`endUpdates` from the first build, not only after the first search. Today `reload` calls `reloadData` (:528-538) and restores only the first selected row (:546), which collapses C's "select the unavailable speakers, then Hide or Forget" and loses VoiceOver's place. Drop `isPlaying` from `SidebarProjection` (`MixerWindowController.swift:782, :798`). (AUDIT 4)
14. Moves wait for the pointer, an open menu or a drag only (C rule 3); nothing waits on VoiceOver or keyboard focus. With rows kept, the VoiceOver cursor travels with its speaker. One low-priority announcement when the only selected row changes state while the sidebar has focus: "Mac Cast Receiver, unavailable" / "…, available"; Bluetooth "connected" / "not connected". Under Reduce Motion, moves, inserts and removes run with no animation. (AUDIT 6)

### Sidebar VoiceOver and keyboard
15. Subsection headers speak "Speakers shown in Mixer" and "Speakers hidden unless in use" ("…unless playing" if you keep your wording), set on every reuse. All four titles get the Mixer's heading role (conflict 9). Add `shouldCollapseItem` returning `isHiddenHeader(item)` so VoiceOver's disclosure command cannot fold the other headers. (AUDIT 1)
16. The "Shown while in use" caption is hidden from VoiceOver (`setAccessibilityElement(false)`); the name's spoken label already ends with that clause (:1319). (AUDIT 8)
17. Keyboard: arrow keys skip titles, subsection headers and the divider; Shift ranges cross the divider; `selectionIndexesForProposedSelection` drops plate rows from any multi-row selection (today Shift-Up from the first speaker adds Overview and switches the page); `typeSelectStringFor` returns names, "Main Audio" and "Overview", and nil for headers and dividers. (AUDIT 9)
18. Record in C BRIEF, no change: colour is the only visible cue for up to 10 s before the first search settles and while a move waits for the pointer (accepted; the spoken suffix is right throughout); every tooltip fact is reachable another way; rows (32) and plates (40) meet the macOS 28 pt default target. (AUDIT 13)

### Overview card
19. Strip: a horizontal stack aligned on last baseline. First an "Available" group: the caption with a 1 pt rule after it, over the four kind tiles (`.fillEqually`, 4 × 77.4 pt). Then the Unavailable tile (at least 77.4 pt) with a 1 pt full-height rule on its leading edge. Caption rule `containerEdge` (`hairline` is not allowed on `raised`), from caption + 8 to the kind tiles' trailing edge − 12, centred 3 pt above the caption's baseline. English positions: caption x 18-67, rule x 75-315.6, vertical rule x 327.6. Both rules hidden from VoiceOver. Long translations: Unavailable tile = 13 + the wider of its label and its glyph-and-count; kind tiles at least 62; the caption rule follows the kind tiles' width; past 126 pt the Unavailable label truncates at the tail. Nothing truncates in English. (LAYOUT 7-8)
20. Type: two new styles, `Tokens.Font.headingDigits` (`monospacedDigitSystemFont`, 16 pt semibold) for counts and the Reduce Motion dash, and `Tokens.Font.captionDigits` (11 pt regular, tabular) for the divider label and the header total. "Available" `captionEmphasized`; tile labels `caption`. Pin each count's first baseline to AirPlay's count and each label's to AirPlay's label (15 pt apart). (TYPESET 6-8, 10)
21. Ink: counts `label`, zeros `labelCool2` (4.59:1 on dark `raised`, the tightest pass); "Available", kind labels, "Unavailable" and the header total `labelCool` (through `captionField`, `SpeakersPageViewController.swift:314`); count glyphs including Unavailable's, row glyphs (`questionmark.circle`, Bluetooth, Local Network, Pair's `plus.circle`) and Pair's chevron `labelCool2`. Change at the call sites, not `ListRowView`'s defaults. Both mockups draw the header icon well in `label2`; the code already uses `labelCool` (`DeviceIconWellView.swift:154`), so fix the mockups. (COLORIZE 8)
22. Placeholders: the count field stays in its tile as an invisible "00" under the 20 × 12 pt placeholder, so the line height never changes when the number lands. The header total shows a 14 × 8 pt placeholder alone, then "20 speakers" fades in as one string. Mockup: drop the word "speakers" beside the loading placeholder. (TYPESET 9)
23. Reduce Motion: each unknown count shows "–" in `headingDigits` / `labelCool2` (5.30 / 4.59 / 8.11 / 7.00:1 across light, dark and both Increase Contrast modes) instead of the still `meter` bar (1.59-2.30:1, under 3:1 in all four). The header reads "Looking for speakers…" in `caption` / `labelCool` (owner call 3). VoiceOver for an unknown count: "AirPlay, still looking". Mockup: one Reduce Motion row in "How the numbers fill in". (AUDIT 12)
24. P1. The Speakers page builds its header, strip and rows once and updates text, spoken values and the Forget button's title in place; a problem row is inserted or removed only when its condition changes. Today `reload()` removes and rebuilds every row on every backend event (`SpeakersPageViewController.swift:228-275`, called through `MixerWindowController.swift:729-730`), dropping keyboard focus and sending `.valueChanged` to views VoiceOver was never on. Each tile: static-text role, its sentence as `accessibilityValue`. (AUDIT 11)

### Docs, briefs and tests
25. Update with the build: M BRIEF.md lines 24, 29, 44, 46, 165-171, 179, 186, sidebar table rows 1-7, the row-states table and resolved conflict 13; C BRIEF.md Geometry, the divider row, its contrast table, "Drag, selection, keyboard, VoiceOver" and builder notes; DESIGN.md :403-417 (two new tabular styles, two sidebar header levels), :497-513 and :678-717 (search caption, dots, `systemGreen`), :510 (`heading` → `headingDigits`), :641 and :766 (14.2 → 14.4), :688 (40 pt row); `Tokens.swift:116-117` and `:1294-1295` (doc lists of jobs); COPY.md gains the new spoken strings and its DESIGN.md references move to :679-694 and :707-713. (all four passes)
26. Stale history lines, flag only (Guard 12 forbids rewriting them; add dated lines instead): `AudioutWindowUI/AGENTS-HISTORY.md:91-94` (`claimKeyboardFocus()` no longer exists), `:165-182` (the sidebar sorts alphabetically itself; you accepted moving rows on 2026-08-28), `:278` (the sidebar is not stock). (AUDIT 15, COLORIZE 12)
27. Tests that name a defect: two selected rows stay selected when one moves under the divider (fails if the update falls back to `reloadData`); no sidebar or overview element is set in `label2`, `label3`, `ember` or `gold` (fails if the brown comes back). `SidebarActionsTests.swift:123-124` pins dot states and goes with the dot. (AUDIT 4, COLORIZE 12, C)

## Final style table

| Element | Font | Ink, unselected | Position, row height |
|---|---|---|---|
| Section title ("System Audio", "Speakers") | `captionEmphasized`, 11 semibold | `labelCool` | x 14; 19, "Speakers" 31 |
| Subsection header ("Shown in Mixer", "Hidden unless in use") | `captionMedium`, 11 medium | `labelCool` | x 14; 19 |
| Plate label ("Main Audio", "Overview") | `bodyEmphasized`, 13 semibold | `label`; chevron `labelCool2` | x 46; R + 8 |
| Speaker name, reachable | source-list font, 13 regular | `label`; icon `label` | x 46; R |
| Speaker name, unreachable | source-list font, 13 regular | `labelCool`; icon `labelCool2` | x 46; R |
| Row caption ("Shown while in use") | `caption`, 11 regular | `labelCool` | x 46, 2 under the name; R + 12 |
| Divider ("8 unavailable") | `captionDigits` (new), 11 regular, tabular | label and glyph `labelCool`; rule `separator` | glyph centred x 27, label x 46; 24 |
| Page title ("Overview") | `heading`, 16 semibold | `label` | |
| Header total ("20 speakers") | `captionDigits` (new) | `labelCool` | |
| "Available" | `captionEmphasized` | `labelCool`; rule `containerEdge` | |
| Count | `headingDigits` (new), 16 semibold, tabular | `label`; 0 and Reduce Motion dash `labelCool2` | |
| Tile label ("AirPlay" … "Unavailable") | `caption`, 11 regular | `labelCool`; glyph `labelCool2` | |
| Card row title | `body`, 13 regular | `label`; glyph `labelCool2` | |
| Any text or icon on a selected sidebar row | unchanged | `alternateSelectedControlTextColor` on the accent pill, `label` on the grey pill | |

## Contrast, worst case per ink

Full tables: `AUDIT.md` "Contrast" and `COLORIZE.md` "Contrast". Worst figure across light, dark, both Increase Contrast modes and both grounds:
- `labelCool` text on the sidebar: 5.79:1 (floor 4.5). On `raised`: 6.79.
- `labelCool2` glyphs on the sidebar: 4.06:1 (floor 3). Under 4.5 in dark, so never sidebar text.
- `labelCool2` zeros and dash on `raised`: 4.59:1 in dark (floor 4.5). The tightest pass.
- `label` on the grey pill: 7.33:1. White on the accent pill: 4.02-6.27 in dark on the offscreen render. That low end is AppKit's own selected text, the same in every Mac sidebar.
- Increase Contrast figures for system colours (`label`, `separator`, the pills, the ground) are estimates or repeat the standard figure: macOS will not render its high-contrast appearances offscreen while the setting is off.

## Left for the polish pass

In dark, the plates' `raised` fill `#1F232A` (`Tokens.swift:218-220`) is darker than the measured sidebar ground `#282828`, so both plates read as sunk rather than raised; their edge measures 1.45:1. No pass owned it (AUDIT "Touches other passes"). The critique already lists dark-mode plate edges for polish.

## Owner calls

New from these passes (default in brackets):
1. The speaker pages and the Main Audio page, in the same tab, go cool in the same build: nine `label2` sites plus `ListRowView`'s caption default. Otherwise clicking from Overview to a speaker switches from cool captions to warm ones. [yes] (COLORIZE 11)
2. A speaker page's red "Can't be found" glyph (`DeviceDetailViewController.swift:216`) becomes `questionmark.circle` in `labelCool2`, matching the overview. [yes] (COLORIZE)
3. Under Reduce Motion only, the overview header says "Looking for speakers…" while counts are unknown: a status line you dropped, kept for people who turn motion off. [yes] (AUDIT 12)
4. Command-Delete in the sidebar forgets the selected speakers that can't be found, through the sheet that names them. Today Forget is reachable from the keyboard only through a speaker's page. [add] (AUDIT 10)

Still open from earlier briefs; these passes only sharpened them:
5. Middle-truncated names [yes]. What you would see: "Move 2 (S…Bedroom)", or "Move 2 (…Bedroom)" when the list scrolls with scroll bars always shown (this Mac).
6. "Hidden unless in use" or "Hidden unless playing" [in use]. Both fit at 11 pt medium.
7. A state line on the Main Audio plate [none]. If yes: `caption` in `goldText`, plate height R + 12.
8. The 10 s wait before Forget appears [keep].
9. Direction C's own questions: divider wording "8 unavailable" or "8 not available right now" [the first]; the filled `rim` disc on reachable rows as well [no]; no time limit on holding moves while the pointer is over the sidebar [none].
