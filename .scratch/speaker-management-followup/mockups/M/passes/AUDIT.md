# Audit: Speakers tab, direction M with sidebar C

Method: impeccable `audit` (its VoiceOver, keyboard, contrast and Reduce Motion checks, read as AppKit), 2026-10-04, code at `claude/speakers-nav` HEAD b9b70310. The window UI files are unchanged since 95f5fa60, so the briefs' line numbers hold; the line numbers below are on b9b70310. Ratios are WCAG 2.x relative luminance. The sidebar ground and the blue selection pill were rendered offscreen on this Mac (macOS 27.0, Increase Contrast off); nothing went on screen. "Element" below means one thing VoiceOver stops on and reads.

## Amendments

1. **"Shown in Mixer" and "Hidden unless in use" are heard as part of Speakers** (P2)
   - Decision: the two subsection headers carry "Speakers" in their spoken label, and the tree stays flat. Spoken: "Speakers shown in Mixer" and "Speakers hidden unless in use" ("Speakers hidden unless playing" if you keep your wording; that call is already open). "System Audio" and "Speakers" are spoken as shown.
   - Code: `makeHeaderLabel` (SidebarViewController.swift:1234-1240) sets `cell.textField?.setAccessibilityLabel(_:)` on every call. All header cells share one reuse pool (`"header"`, :1235), so a label set for some titles only would carry over to the next header, the trap :1308-1311 already guards against for speaker rows.
   - On macOS 26 and later, also `textField.setAccessibilityRole(.heading)` (`NSAccessibilityHeadingRole`, NSAccessibilityConstants.h:553) on all four titles, inside `if #available(macOS 26.0, *)`. VoiceOver's heading keys (Control-Option-Command-H) and its rotor (the Control-Option-U list of a window's headings and landmarks) then reach them. No heading level: AppKit ships only the attribute name (NSAccessibilityConstants.h:98), no setter. The package runs on macOS 14.4 and later (Package.swift:79), so the spoken label is the cue everywhere and the role is an addition.
   - Tree: the "Speakers" title node holds the Overview plate as its child, the way "System Audio" holds Main Audio (:529). The two subsection headers stay top-level nodes.
   - Why not nest them under "Speakers" at zero indent: VoiceOver speaks a row's own text, not its parent's, so only the label puts "Speakers" in what Sam hears. Nesting would also put speaker rows on the third level, so the outline's indentation (`indentationPerLevel`) would need zeroing for every level; make "Hidden unless in use" a nested group row whose stock Show/Hide control has never run there; send drag proposals between the two subsections to "Speakers", which `movers` refuses (:491-492), leaving a strip that takes no drop; and change the shape `reload` builds (:528-535) and `test_sectionTitles` reads (:630-638).
   - Folding guard: add `outlineView(_:shouldCollapseItem:)` returning `isHiddenHeader(item)`. "The first group never folds" (:1119-1121) is held only by hiding the Show/Hide control (:1122-1124). Every header with rows is expandable (:1076-1078), so VoiceOver's disclosure command (Control-Option-\) can still fold "Shown in Mixer", "System Audio" or the new "Speakers" title and hide their rows.
   - Brief: M BRIEF.md "Sidebar accessibility" gains these bullets; C BRIEF.md "Drag, selection, keyboard, VoiceOver", bullet "VoiceOver", gains the two header labels; COPY.md gains the two spoken strings.

2. **No blank spacer row between the two sections** (P2)
   - Change: M BRIEF.md structure table, row 3 (the 16 pt non-selectable spacer row), goes. The "Speakers" title row grows 16 pt instead, through `outlineView(_:heightOfRowByItem:)` (:1142-1152), with its text held at the bottom of the row rather than centred (:1262). Exact numbers belong to the layout pass.
   - Why: every node is a row VoiceOver's cursor stops on (rows come from the data source, :1066-1074), so a spacer is a stop that says nothing. It is not a group row either, so `shouldSelectItem` (:1134-1137) would let arrow keys and clicks select it unless it got its own exception.
   - Mockups: no visual change.

3. **A selected row draws its name, icon, caption and chevron in the selection's colour** (P1)
   - Rule: list focused (blue pill; the cell's `backgroundStyle` is `.emphasized`): `NSColor.alternateSelectedControlTextColor`. List not focused (grey pill): `Tokens.Color.label`. Unselected rows keep C's colours. Covers speaker rows, C's dimmed rows, the "Shown while in use" caption (`label3`, :850) and the plates' chevron (`label3`, :838).
   - Why: C makes "select the unavailable block, then Hide or Forget" a documented move, and those selected names are unreadable. On the blue pill `labelCool` names measure 1.56:1 light and 1.88:1 dark, `labelCool2` icons 1.22 and 1.17. On the grey pill in dark, `labelCool` measures 4.43, `labelCool2` 2.75 and `label3` 3.14, all under their floors. The fix measures white 4.53 to 5.37 light and 4.02 to 6.27 dark (AppKit's own selected text, the same in every Mac sidebar) and `label` 11.65 light, 7.33 dark on grey.
   - Code: the colours are set once when the cell is built (:1297-1300) and nothing re-sets them when selection changes. The grey pill leaves the cell's `backgroundStyle` unchanged, so speaker rows need a row view whose `isSelected` didSet re-applies its cell's colours, the pattern `PlateRowView` already uses (:945), plus a `backgroundStyle` didSet on `IconLabelCellView`. M BRIEF.md line 44 states this for the dot; under C it covers text and icons.
   - Mockup: C's "Shift-click across the divider" panel already draws white on blue. Add one row selected with the list not focused: grey pill, name in `label`.

4. **The sidebar keeps its rows and the whole selection across every update** (P1)
   - Today: `reload` builds new nodes for every row and calls `reloadData` (:528-538) whenever anything the cells draw changes (MixerWindowController.swift:747-753, comparing the fields at :774-801), then restores only the first selected row (:546; `currentSelection` reads `selectedRow`, :553-557).
   - Effect: a multi-selection collapses to its first row whenever any speaker answers, drops or connects, which breaks C's "one click and one shift-click" bulk Hide or Forget. VoiceOver's cursor loses its row because every row is rebuilt.
   - Change, C BRIEF.md "Builder notes", second bullet: from the first build on, not only after the first search. One `Node` per device id, kept across updates (the outline keys rows by node identity, :49-50). Changes applied with `moveItem(at:inParent:to:inParent:)`, `insertItems` and `removeItems` inside `beginUpdates`/`endUpdates`. Changed colours and labels re-applied to the visible cell (`outlineView.view(atColumn: 0, row:, makeIfNecessary: false)`), never through `reloadItem` or `reloadData`. C's rule 1 ("a speaker that answers brightens in place") then holds before the first search too.
   - Drop `isPlaying` from `SidebarProjection` (MixerWindowController.swift:782, :798) along with the dot's playing state: once the dot goes nothing draws it, and it triggers an update on every connect and disconnect.
   - Test that buys its place: two rows selected, one of the speakers goes unavailable and its row moves; both ids are still selected. Turns red if the update falls back to `reloadData`.

5. **The divider row is one spoken element and is never selectable** (P2)
   - Spoken: the label's text field gets `setAccessibilityLabel("8 unavailable speakers")` ("1 unavailable speaker"), set on every call. The visible text stays "8 unavailable". The glyph's image view and the rule view get `setAccessibilityElement(false)`.
   - Code: `shouldSelectItem` returns `!isGroupItem` (:1134-1137), and C keeps the divider out of the group rows, so without a change it is selectable by click, arrow key, shift range and type-to-select. Return `false` for it by name. `selection(for:)` (:559-566) returns nil for it, and `menuNeedsUpdate` puts it with the rows that get no menu (:1050-1052).
   - Contrast: label and glyph in `labelCool`, 6.21 light and 6.92 dark on the measured ground. The rule in `separatorColor` measures 1.24 and 1.36; it is decoration and exempt from 3:1, because the words and the glyph carry the boundary.
   - Brief: C BRIEF.md "The divider row" and "Builder notes".

6. **How VoiceOver users meet the split, and what is said when rows move** (P2)
   - Meeting the split, no new strings. The VoiceOver cursor (Control-Option with the arrow keys) stops on "8 unavailable speakers" between the last reachable row and the first unreachable one. Plain arrow keys skip the divider, so every unreachable row keeps its suffix: ", unavailable"; ", not connected" for Bluetooth (CLARIFY.md 2); ", can't be found" (:1313-1318). The first suffix heard marks where that part starts. The overview tile says "12 speakers unavailable". Reachable rows add nothing, as in the Mixer, which speaks "Unavailable" only on unreachable rows (DeviceRowView.swift:2905-2911).
   - C's rule 3 stays: moves wait while the pointer is over the sidebar, a menu from it is open, or a drag is running. Nothing waits on VoiceOver or the keyboard. AppKit gives no way to read where the VoiceOver cursor is, and waiting on keyboard focus would never end, because the sidebar takes focus whenever the window appears (:155-162). With item 4 a moved row keeps its element, so the VoiceOver cursor and the selection travel with the speaker and never end up on a different one.
   - One announcement: when the only selected row changes state while the sidebar has keyboard focus in the key window, post `.announcementRequested` at low priority with its new state: "Mac Cast Receiver, unavailable", and on its return "Mac Cast Receiver, available" (Bluetooth: "connected", "not connected"). That row is where a keyboard or VoiceOver user is working; a sighted user sees its colour change at once (C rule 2). Nothing else about moves is announced.
   - Reduce Motion: read `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` when the update runs. When it is on, run the update inside `NSAnimationContext.runAnimationGroup { $0.duration = 0 }` and pass `[]` as the animation to `insertItems` and `removeItems` (Forget, a divider appearing or going), so rows change place without sliding.
   - Brief: C BRIEF.md "When rows move" (rules 3 and 5) and "Drag, selection, keyboard, VoiceOver".

7. **Sidebar text and icons repaint when Increase Contrast changes** (P2)
   - Today the only listener in a speaker cell is the dot (`redrawOnAccessibilityDisplayChange()`, :965), and C removes the dot. Names and icons coloured `labelCool`, `labelCool2` or `label3` then keep their standard-contrast colours after Increase Contrast is turned on under the Light or Dark theme setting (AppDelegate.swift:2641-2643), because the Increase Contrast colour is picked inside the token, not by the appearance (AccessibilityDisplayRedraw.swift:14-25). Item 4 removes the full rebuilds that used to hide this.
   - Change: the sidebar controller observes `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` once and re-applies colours to the visible rows (`enumerateAvailableRowViews`), with the same code as item 3.
   - `IncreaseContrastLiveReconcileTests` will not catch it: it checks only views that override `draw` or `drawBackground` (IncreaseContrastLiveReconcileTests.swift:94-116).
   - Brief: M BRIEF.md "Sidebar accessibility", bullet 3, cites the dot's repaint, which C deletes; this replaces it.

8. **The hidden-and-in-use caption is spoken twice** (P3)
   - `statusLabel` (:847-855) is a plain label, so VoiceOver reads it as text of its own, and the name's label already ends with the same clause (:1319). The row is heard as "Fancyy, shown in the Mixer while in use, Shown while in use". Set `statusLabel.setAccessibilityElement(false)`. Brief: M BRIEF.md "Sidebar accessibility".

9. **Keyboard: arrows, ranges, type-to-select, Tab, folding** (P3)
   - Arrow keys skip the section titles and subsection headers (group rows, :1113-1117, :1134-1137) and the divider (item 5). Both plates stay on the arrow path, which is how the keyboard reaches Main Audio and Overview.
   - Shift-click and Shift-arrow skip rows that cannot be selected, so a range crosses the divider (as C draws it). Keep the plates out of ranges with `outlineView(_:selectionIndexesForProposedSelection:)`, dropping plate rows from any proposal of more than one row. Today Shift-Up from the first speaker adds the Overview plate, and because the page follows the first selected row (:553-557) it switches to Overview while the speakers stay selected.
   - Type-to-select: implement `outlineView(_:typeSelectStringFor:item:)`, returning the speaker's display name, "Main Audio" or "Overview", and nil for titles, subsection headers and dividers. Without it AppKit searches every cell with text (NSTableView.h:668), so typing "S" can land on "Shown in Mixer" and "8" on the divider. Middle truncation (HARDEN.md 12) does not matter: the text field holds the full name.
   - Tab: the sidebar is the first stop (:155-162), then the page. On the overview, Tab reaches Forget, the access rows' buttons and Pair only with macOS Keyboard navigation turned on (System Settings › Keyboard). The count tiles are text and are correctly not Tab stops.
   - Folding: "Hidden unless in use" opens and closes only by pointer (the stock Show/Hide) or VoiceOver's disclosure command; headers take no selection, so arrow keys cannot. Accepted: the fold resets every launch (`hiddenGroupCollapsed`, :115; `autosaveExpandedItems = false`, :183).
   - Brief: C BRIEF.md "Drag, selection, keyboard, VoiceOver", bullets "Keyboard" and "Multiple selection".

10. **Forget from the keyboard** (P3)
    - Today the sidebar's Forget sits in the right-click menu only (:388-391, :412-417). Without VoiceOver (Control-Option-Shift-M opens it) no key opens that menu. The keyboard paths that exist: select the speaker, then its page's Forget button (DeviceDetailViewController.swift:612), or the overview's "Forget 6 speakers…"; both need Keyboard navigation on for Tab.
    - Add: Command-Delete with the sidebar focused forgets the selected speakers that are in `lostIDs` (HARDEN.md 5), through the same `onForget` and the same sheet that names them (CLARIFY.md 1). With none of those selected, it beeps. It reaches `requestForget` (MixerWindowController.swift:224, :530), so `speaker:forgotten` (SpeakerLibraryController.swift:273) fires exactly as now; no new event. Command-Delete is the key Finder uses for Move to Trash.
    - Brief: C BRIEF.md "Drag, selection, keyboard, VoiceOver". Owner call 2.

11. **The Speakers page updates in place instead of rebuilding** (P1)
    - Today `reload()` removes every row, strip included, and builds new ones (SpeakersPageViewController.swift:228-275; also on each Bluetooth access change, :222-225). The host calls it from `refreshAll()` while the page shows (MixerWindowController.swift:729-730), and `update(devices:)` runs `refreshAll()` whenever the surface is visible (:380-384), which "fires on every backend event" (:756-757).
    - Effect: each rebuild deletes the element VoiceOver is on and the button holding keyboard focus. Focus falls back to the window, the dead-Tab state the sidebar's focus code was written to end (SidebarViewController.swift:126-142). M's `.valueChanged` on a tile (BRIEF.md line 187) goes to a tile created that instant, which VoiceOver was never on, so nothing is spoken.
    - Change: build the header, the strip and the rows once. On update, set each count's text, each tile's spoken sentence and the header caption on the existing views; insert or remove a problem row only when its "shown only when true" condition changes; keep the Forget button and retitle it. Each tile: `setAccessibilityRole(.staticText)`, no label, its sentence as `accessibilityValue`; `.valueChanged` posted on that same tile is then spoken when VoiceOver is on it.
    - Brief: M BRIEF.md "Overview accessibility"; HARDEN.md 11, last bullet ("the page rebuilds a handful of rows per change"), changes to this.

12. **Reduce Motion: a cool dash for each count, and words in the header** (P2)
    - Count placeholder under Reduce Motion: an en dash "–" in the count's own font (`Tokens.Font.heading`, 16 pt semibold, tabular digits) and `Tokens.Color.labelCool2`, instead of the still `meter` bar. On `raised` the dash measures 5.30 light, 4.59 dark, 8.11 and 7.00 with Increase Contrast: over the 4.5:1 text floor in all four. The bar measures 1.59, 1.82, 1.91 and 2.30: under 3:1 in all four. Cool grey, no brown, no new token. The 180 ms crossfade to the number stays (opacity only).
    - Header caption under Reduce Motion: "Looking for speakers…" in `caption` / `label2` until the total is known, then "20 speakers". It is the app's own search string (COPY.md line 40); a dash in front of "speakers" does not read as a number still coming.
    - VoiceOver, whatever the motion setting: a count not yet known reads "AirPlay, still looking" (COPY.md line 27; same pattern for Bluetooth, Cast and Unavailable). The header reads "Looking for speakers", replacing BRIEF.md line 186's "still looking", which has no subject.
    - Rows moving under Reduce Motion: item 6.
    - Brief: M BRIEF.md "Motion", Reduce Motion bullet (line 179); "Tokens and geometry", placeholder bullet (line 171); "Overview accessibility" (line 186). Mockup: M's "How the numbers fill in" panel gains one Reduce Motion row with dashes and "Looking for speakers…". Owner call 1.

13. **Three checks that pass or are accepted, recorded in the brief** (P3)
    - Colour alone: after the first search, position, the divider's words and its glyph carry reachability, and colour is the second cue (C). Colour is the only visible cue in two short spells: before the first search settles (up to 10 s, C rule 1) and while a move waits for the pointer to leave (C rule 3). `label` and `labelCool` differ by only 2.2:1 light and 1.6:1 dark. Accepted: both spells end on their own, and the spoken suffix is right throughout.
    - Tooltips: the sidebar's state tooltip (CLARIFY.md 2), the full name of a cut-off row (HARDEN.md 12) and the overview's help texts show only under the pointer. Each fact is reachable another way: VoiceOver speaks the suffix and the full name (:1312-1320); the speaker's page says "Can't be found" (DeviceDetailViewController.swift:647-648); the Forget sheet names the speakers (CLARIFY.md 1); VoiceOver reads the help as a hint (SpeakersPageViewController.swift:387). No change.
    - Click targets: speaker rows span the sidebar at the outline's row height (28 pt as drawn); plates are 36 pt (`PlateRowView.rowHeight`, :917); overview rows at least 44 pt (ListRowView.swift:17); Forget and Open Privacy Settings… are AppKit's regular rounded buttons (SpeakersPageViewController.swift:391-395). All meet Apple's macOS minimum of 20 × 20 pt, and rows and plates meet its 28 × 28 pt default. The divider and the headers are not click targets apart from the stock drop and Show/Hide.
    - Brief: three bullets under C BRIEF.md "Drag, selection, keyboard, VoiceOver".

14. **If a count becomes clickable** (P3)
    - None is today (M: "No new focusable controls"). If the layout pass or you make Unavailable select its rows (the critique's power-user ask), each clickable tile becomes a borderless `NSButton`: button role, the tile's sentence as its label, the tile's help as its help, a focus ring and a Tab stop, pressed by Space and Return. Pressing it selects the matching sidebar rows and gives the sidebar keyboard focus. It is a new user action, so it needs its own `Analytics.capture` and, first, a row in audiout-shared's `docs/analytics-events.md`.

15. **Stale docs and briefs** (P3)
    - M BRIEF.md line 46 and C BRIEF.md's contrast table call the sidebar ground unmeasured. It is measured now: opaque `#F0F0F0` light and `#282828` dark (table below). C's mockup.html `--sidebar` (`#EEEEEF` / `#232325`) takes those values.
    - M BRIEF.md "Sidebar accessibility" describes the dot and its repaint; C removes both. Items 1 to 9 replace it.
    - AudioutWindowUI/AGENTS-HISTORY.md:91-94 says exactly two places call `makeFirstResponder`, one being `SidebarViewController.claimKeyboardFocus()`. That method no longer exists, and the window UI calls `makeFirstResponder` in five places.
    - AGENTS-HISTORY.md:165-182 says the sidebar lists available speakers first through `orderedDevices()`. The sidebar sorts itself alphabetically (SidebarViewController.swift:510-523; MixerWindowController.swift:806). The same entry records you accepting, on 2026-08-28, rows that move when availability changes, so C's "no row has ever moved" is true of today's code only. Guard 12 forbids rewriting history lines; a new dated line records the change.
    - DESIGN.md:641 and :766 say the package deploys to macOS 14.2; Package.swift:79 says 14.4.

## Contrast

Floors: 4.5:1 for text at 11 to 13 pt, 3:1 for glyphs and other non-text. "est." marks an estimate; every other figure is measured or computed from exact token values.

| Ink (where it is used) | Floor | Light | Light, Increase Contrast | Dark | Dark, Increase Contrast |
|---|---|---|---|---|---|
| **On the sidebar ground** (`#F0F0F0` / `#282828`) | | | | | |
| `labelCool` (unreachable names; divider label and glyph) | 4.5 | 6.21 | 7.08–8.54 est. | 6.92 | 7.45–9.83 est. |
| `labelCool2` (unreachable icons) | 3 | 4.85 | 6.72–8.11 est. | 4.29 | 5.61–7.40 est. |
| `label2` (section titles; C's subsection headers) | 4.5 | 5.46 | 6.70–8.08 est. | 6.56 | 7.06–9.31 est. |
| `label3` (M's subsection headers; "Shown while in use"; plate chevron) | 4.5 | 5.13 | 6.73–8.13 est. | 4.91 | 5.65–7.46 est. |
| `label` (reachable names) | 4.5 | 13.50 | 16.67–20.12 est. | 10.97 | 12.63–16.67 est. |
| `separatorColor` (divider rule; decoration) | none | 1.24 | unknown | 1.36 | unknown |
| `containerEdge` (plate edge; the row's text names it) | none | 1.85 | 4.36–5.26 est. | 1.45 | 2.46–3.24 est. |
| `raised` (plate fill against the ground) | none | 1.09 | 1.00–1.21 est. | 1.07 | 1.06–1.25 est. |
| `rim` (only if C's "Your filled mark kept" panel is chosen) | 3 | 4.38 | 4.95–5.98 est. | 3.17 | 3.63–4.79 est. |
| **On the grey pill** (list not focused; system `#DCDCDC` / `#464646`, est. in all modes) | | | | | |
| `labelCool` | 4.5 | 5.16 | 5.78–6.50 | 4.43 fails | 4.40–5.57 |
| `labelCool2` | 3 | 4.03 | 5.49–6.17 | 2.75 fails | 3.31–4.19 |
| `label3` | 4.5 | 4.26 fails | 5.50–6.18 | 3.14 fails | 3.34–4.22 fails |
| `label` (item 3) | 4.5 | 11.65 | 13.62–15.31 | 7.33 | 7.46–9.44 |
| **On the blue pill** (list focused; rendered `#0070F5` / `#007AFF`) | | | | | |
| `labelCool` | 4.5 | 1.56 fails | 1.66–1.97 est., fails | 1.88 fails | 2.37–3.70 est., fails |
| `labelCool2` | 3 | 1.22 fails | 1.58–1.87 est., fails | 1.17 fails | 1.78–2.78 est., fails |
| `label3` | 4.5 | 1.29 fails | 1.58–1.87 est., fails | 1.34 fails | 1.80–2.81 est., fails |
| white, `alternateSelectedControlTextColor` (item 3; AppKit's own) | 4.5 | 4.53–5.37 | 4.53–5.37 est. | 4.02–6.27 | 4.02–6.27 est. |
| **On the overview card, `raised`** (token values, exact) | | | | | |
| `meter` still placeholder (today's Reduce Motion) | 3 | 1.59 fails | 1.91 fails | 1.82 fails | 2.30 fails |
| `labelCool2` en dash (item 12) | 4.5 | 5.30 | 8.11 | 4.59 | 7.00 |

- Light and Dark grounds: measured on macOS 27.0. An offscreen `NSOutlineView` with `.sourceList` paints the same opaque pixel over white and over black, matching the code's own note that the source list "paints its OWN opaque background whatever sits behind it" (MixerWindowController.swift:170). The blue pill is the offscreen render; a key window may draw `selectedContentBackgroundColor` (`#0064E1` / `#0059D1`) instead, which is why white shows a range. The grey pill draws through a material the offscreen render cannot show, so it is the system colour value.
- Increase Contrast columns: with Increase Contrast off, AppKit hands back plain Aqua when asked for its high-contrast appearance, so system colours cannot be read in that mode. The ground bracket is the measured value ±10 levels (`#E5E5E5`–`#FAFAFA`, `#1E1E1E`–`#333333`), with system label text taken as opaque. Token inks are exact in all four modes (Tokens.swift: `label2` :113-115, `label3` :129-131, `containerEdge` :295-298, `rim` :311-314, `meter` :327-330, `labelCool` :511-513, `labelCool2` :527-529).
- On macOS 14.4 to 26 the ground is unmeasured. Across M's old bracket (`#E8E8EA`–`#F5F5F6`, `#1E1E20`–`#2C2C2E`) `labelCool` stays 5.79–6.50 light and 6.54–7.81 dark, and `labelCool2` 4.52–5.08 and 4.06–4.84.

## Touches other passes

- Colorize: assumed C's colours (`labelCool` names, `labelCool2` icons, `label2` subsection headers; M had `label3`). Zero counts and the caption still use the warm `label3`; if colorize moves them to the cool inks, the table already covers those. Item 3's selected-row rule applies to whatever colorize picks. If colorize wants the moving placeholder bar itself above 3:1, `rim` on `raised` measures 4.78, 3.39, 5.98 and 4.53. The plates barely separate from the ground (edge 1.85 light, 1.45 dark; fill 1.09, 1.07), and in dark the `raised` fill `#1F232A` is darker than the ground `#282828`, so a plate reads as sunk rather than raised.
- Typeset: the en dash takes the count's font (16 pt semibold, tabular digits); typeset may pick the dash glyph, as long as its ink stays `labelCool2`. The heading role and spoken labels do not depend on the subsection header's visual style.
- Layout: item 2 assumes the gap becomes height on the "Speakers" title row; layout owns the numbers. Offscreen on macOS 27.0, a `.sourceList` outline at `.medium` reports `rowHeight` 32, not the 28 the mockups draw; check the live sidebar before fixing the 24 pt divider and the 40 pt captioned row against it. If layout gives Unavailable its own row or makes counts clickable, item 14 applies.
- Copy: the new spoken strings ("Speakers shown in Mixer", "Speakers hidden unless in use", "8 unavailable speakers", "Mac Cast Receiver, available", "Looking for speakers") go into COPY.md.

## Owner calls

1. Under Reduce Motion only, the overview header says "Looking for speakers…" while counts are unknown: a status line you dropped, kept for people who turned motion off. Default: yes.
2. Command-Delete in the sidebar forgets the selected speakers that can't be found, through the same sheet that names them. Default: add it.
