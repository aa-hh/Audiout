# Layout: Speakers tab, direction M with sidebar direction C

Made with impeccable `layout`, 2026-10-04, against `claude/speakers-nav` HEAD b9b70310 (`SidebarViewController.swift` and `SpeakersPageViewController.swift` are unchanged since 95f5fa60, so the earlier briefs' line numbers hold). Geometry was measured by rebuilding the sidebar's source-list setup in scratch AppKit programs on this Mac (macOS 27.0, build 26A5388g, 27.0 SDK; offscreen, nothing in the repo) and rendering it. Layout detector: 0 findings on both mockups. Line numbers without a file name are `SidebarViewController.swift`.

## Amendments

### 1. Draw the sidebar on the grid AppKit produces

Both mockups draw 28 pt rows and an x 18 / x 48 grid. The code's source list (`style = .sourceList` :174, `rowSizeStyle = .medium` :182, 210 pt wide `SurfaceLayout.swift:17`) measures:

| | M and C mockups | Measured |
|---|---|---|
| Speaker row | 28 | **32**. The code reads `outlineView.rowHeight` (:1148-1150), never a literal. The 2026-08-12 window snapshot draws 28 pt rows, so the system value changed between macOS 27 builds. |
| Space above every group row (titles and subsection headers, the first one included) | 0 between sections; 6 at the top of the list | **13**, added by the source list itself, outside any row |
| Group row height with no height delegate | | **19** |
| Header text | x 18 | **x 14**, the header cell's leading edge (:1260) |
| Icon column | x 18-40 | **x 16-38**, centre x 27 (:1361, 22 pt `SurfaceLayout.sidebarIconSize`) |
| Names, plate labels | x 48 | **x 46** (icon + `sidebarIconToLabelGap` 8, :1369-1370; the label's 2 pt padding puts its frame at 44) |
| Trailing edges | 192 | text ends x 186 (:1372); plate chevrons end x 192 (:1375) |
| Plate fill and selection pill | x 10-200 | x 10-200 (`selectionInsetX`, :921). The pill fills the row's full height. |
| Row icons | "16 pt" (task wording) | **13 pt SF Symbols, medium weight.** At `.medium` the table sets this on every cell's `imageView`, whatever image the code passes (:1297). The 16 pt glyphs are the overview card's (`ListRowView.glyph`). |

Changes: in both `mockup.html` files, `.list` padding-top 6 → 13; `.row` 28 → 32; `.title`/`.sub` x 18 → 14; `.cell` left padding so icons sit at 16-38 and names at 46; heights per amendment 2. C `BRIEF.md` "Geometry", "New grid": x 18 → x 14 for titles and headers, icons at x 16-38 (centre 27), names and the divider label at x 46. M `BRIEF.md` line 29 (128 pt name column) is stale; amendment 6 replaces it.

### 2. One set of row heights for the whole sidebar

Every number is either the source list's own (13 pt gap above group rows, 19 pt group row, `outlineView.rowHeight`, written R below) or R plus a multiple of 4. Every heading's text sits 3 pt above the row it heads: that is the stock group row's own margin, (19 − 13) / 2.

`outlineView(_:heightOfRowByItem:)` (:1142-1151), values on macOS 27 (R = 32):

| Row | Code today | M / C mockups | After |
|---|---|---|---|
| "System Audio" title (first row) | R = 32, text centred (:1149, :1262) | 28 | **19**, text 3 pt above the row's bottom |
| Main Audio plate | R, flat row | 36 | **R + 8 = 40** |
| Spacer row | none | 16 | **none** (amendment 3) |
| "Speakers" title | | 28 | **31** (19 + 12 top padding), text 3 pt above the row's bottom |
| Overview plate | 36 (`PlateRowView.rowHeight`, :917) | 36 | **R + 8 = 40** |
| "Shown in Mixer", "Hidden unless in use" | R = 32, text centred | 28 | **19**, text 3 pt above the row's bottom |
| Speaker row | R | 28 | **R = 32** |
| Hidden speaker with "Shown while in use" | 40 (:1148) | 40 | **R + 12 = 44** |
| Divider row | | 24 | **24** (amendment 4) |
| Add scene bar | 28 (:248) | 28 | **R = 32** (amendment 5) |

The source list adds its 13 pt above each of the four title and header rows on top of these.

Distance from the row above to a heading's text, before (M as specified, built on these metrics) → after:
- Main Audio plate → "Speakers": 38.5 (16 spacer + 13 + 9.5) → **28**
- Overview plate → "Shown in Mixer", last speaker → "Hidden unless in use": 22.5 → **16**
- Last reachable speaker → divider label: **8**
- Heading text → the first row it heads: 9.5 → **3**

So the gaps step 28 / 16 / 8 / 0 from section to row. Today a header floats 9.5 pt above and below its text, as close to the rows above it as to its own.

- **Plates at R + 8.** `PlateRowView.rowHeight`'s own comment defines it as "the `.medium` source-list row plus breathing room" (:915-917): 36 was 28 + 8. At 32 pt rows a 36 pt plate is only 4 pt taller than a row. The pill fills the full row height, so the plate and pill still share one footprint at 40.
- **Captioned row at R + 12.** Its two lines take 31 pt (16 + 2 + 13). At 40 pt they sit 4.5 pt from the row's edges against 8 pt on a one-line row; at 44 pt, 6.5 pt.
- **Headers at 19.** The code gives header rows a full 32 pt row (:1149). The stock height is 19 pt (measured with no height delegate), the spacing Finder uses.
- **Length.** The owner's 20 speakers measure 930 pt of list. The window is never shorter than 600 pt (`AppSurfaceController.minimumContentSize`, `AppSurfaceController.swift:239`). With the 52 pt header band the mockups draw, a 600 pt window holds about 10 speakers before the list scrolls.

Changes: M `BRIEF.md` sidebar table rows 1, 2, 4, 5, 6 and 7 (heights); DESIGN.md:688 "on a 40 pt row" → "on a row 12 pt taller than the others". Mockups: every sidebar panel in both files.

### 3. Top padding on the "Speakers" title replaces the spacer row

- Delete M `BRIEF.md` sidebar row 3 ("16 pt gap", a non-selectable spacer row). No spacer node goes in the tree, so arrow keys and VoiceOver never meet a blank row.
- Build: `heightOfRowByItem` returns `headerRowHeight` (19) for every header and `headerRowHeight + sectionTopPadding` (19 + 12 = 31) for the "Speakers" title. In the header cell, pin the text's bottom to the cell's bottom − 3 instead of centring it (:1262). In a 19 pt row that equals centring, so one constraint serves every header. (`headerRowHeight` and `sectionTopPadding` are proposed names.)
- Result: "Speakers" text 28 pt below the Main Audio plate: 13 from the source list plus 15 inside its own row.
- "System Audio" stays 19. The source list already leaves 13 pt above the first row, 16 pt to its text.
- The stock Show/Hide button on "Hidden unless in use" and the drop outline on a header are both drawn for the stock 19 pt group row.

### 4. The divider row

Changes C `BRIEF.md` "The divider row" and the C mockup's `.dv`, `.dvc`, `.dg`, `.rule`.

- **Height: 24 pt, kept.** Against the real 32 pt rows it is three quarters of a row. It heads rows like a subsection header does, but it is quieter, so it takes less height than a header (13 + 19 = 32) and more than a plain rule would.
- **Vertical:** label box 3 pt above the row's bottom (the headings' rule from amendment 2), so the label sits 8 pt under the last reachable row and 11 pt above the first unavailable name. This replaces the mockup's `padding-top: 3px`.
- **Glyph:** `antenna.radiowaves.left.and.right.slash`, 11 pt, regular weight, in a 22 pt wide box over the icon column (x 16-38). Its centre is x 27, the same as every row icon. It sits on the label's first baseline (`firstBaselineAnchor`), the way SF Symbols are drawn to sit with text. The image measures 14 × 15 pt with an 8 pt alignment height against the row icons' 9 pt, one step smaller, matching its 11 pt label.
- **Label:** "N unavailable", 11 pt, tabular digits, leading edge at the icon column's trailing edge + 8 = x 46, the names' x. Widest likely: "12 unavailable", 73.6 pt.
- **Rule:** 1 pt `Tokens.Color.separator` (`Tokens.swift:151`), from 8 pt after the label to x 192, the cell's trailing edge − 2, where the plates' chevrons end (:1375). It is centred 3 pt above the label's baseline: the middle of the 11 pt x-height (5.8 pt measured), so the line continues the text instead of floating at the row's centre. This replaces C's "vertically centred".
- **Build:** the glyph and the label must not be the cell's `imageView` or `textField` outlets. At `.medium` the table resets an outlet image view to a 13 pt medium symbol and an outlet text field to 13 pt (measured). The cell carries its own accessibility label ("8 unavailable speakers", C).
- Rendered on these metrics: the glyph and label sit level, and the rule runs through the label's x-height.

### 5. The "+ Add scene" bar joins the grid

- Today the bar is 28 pt with the button at x 8 (:248, :250). The plus measures x 9.5-20 and "Add scene" starts at x 26, on neither the icon column (centre 27) nor the name line (46).
- After: bar height `outlineView.rowHeight` (32); plus centred on x 27; "Add scene" ink starting at x 46.5, with the names.
- Build: the same single `NSButton`. Its image becomes a 26 × 22 pt template image with `plus` (13 pt, medium weight, like the row icons) drawn centred at the image's x 11. `DeviceIcon.rowGlyph` pads its glyphs the same way (`DeviceIcon.swift:128-153`). Pin the button's leading edge at x 16. Measured: plus centre 26.75, text from 46.5.
- No hairline above the bar. The code builds a plain `NSView` (:224-253) and both mockups draw one (`.addbar` border-top); take it out of the mockups.

### 6. Names: real width and middle truncation

- The text width without the dot is **140 pt** (x 46-186), measured; 124 pt with M's dot. C's 144 counts the text field's frame, which includes 2 pt of padding each side. "MacBook Pro Speakers" (139.9 pt) fits by 0.1 pt.
- When the list scrolls (amendment 2: always, for the owner's fleet) on a Mac set to show scroll bars all the time, the outline narrows to 193 pt and names get **123 pt**. This Mac reads `NSScroller.preferredScrollerStyle == .legacy`, which is that setting.
- Middle truncation (`lineBreakMode = .byTruncatingMiddle` on the name field only, :1343; HARDEN 12), rendered with AppKit at 13 pt:

| Name (full width) | 140 pt, tail (today) | 140 pt, middle | 123 pt (scroll bar showing), middle |
|---|---|---|---|
| MacBook Pro Speakers (139.9) | whole | whole | MacBook…Speakers |
| Move 2 (SONOS Bedroom) (161.7) | Move 2 (SONOS Bed… | Move 2 (S…Bedroom) | Move 2 (…Bedroom) |
| Sonos Move (SONOS Kitchen) (182.6) | Sonos Move (SONOS… | Sonos Mo…S Kitchen) | Sonos M…Kitchen) |

  At 123 pt, tail truncation gives "MacBook Pro Spe…", "Move 2 (SONOS B…", "Sonos Move (SON…".
- **Full name on hover:** set `outlineView.allowsExpansionToolTips = true` (set nowhere today; HARDEN 12). `expansionFrame(withFrame:in:)` returns a frame for a middle-truncated name and none for a name that fits (measured), so the full-name tooltip still appears. Keep the name in the cell's `textField` slot as today (:1346). Not tried in a live window.
- **Nothing else in the sidebar truncates in English:** "Shown while in use" 99.5 pt in 140; "Hidden unless in use" 108.6 pt in a 194 pt header cell; divider labels as in amendment 4.
- **Plates:** label room is about 133 pt (x 46 to 6 pt before the chevron). "Main Audio" is 69.9 pt and "Overview" 59.0 pt at 13 pt semibold; "Vue d'ensemble" (100.5) still fits. Keep tail truncation.
- Replace HARDEN 12's results (measured at 128 pt, with the dot) with this table. Mockups: draw the two Sonos rows middle-truncated at 140 pt, and add one small panel at the 123 pt width.

### 7. Overview: one caption that spans the four available counts

The card is 415 pt (`GroupsPaneLayout.contentMaxWidth` = 443 − 14 − 14, `GroupsPaneLayout.swift:61`). The strip sits 18 pt from its leading edge and 10 pt from its trailing edge (`SpeakersPageViewController.swift:375-378`): 387 pt.

**How "Available" covers all four:** the caption is followed by a 1 pt rule that runs over the four tiles and stops 12 pt short of the Unavailable rule. It is the sidebar divider's own construction (label, 8 pt, a rule on the x-height), so across the tab one mark means "this word names what sits under it". M's full-height rule before Unavailable stays (decision 2).

Structure, replacing the single `.fillEqually` stack (`SpeakersPageViewController.swift:331-381`); stack names are proposed:

```
strip            NSStackView, horizontal, distribution .fill, alignment .lastBaseline, spacing 0     387 pt
├ availableGroup NSStackView, vertical, alignment .leading, spacing 4                              309.6 pt
│ ├ caption + rule  plain NSView: "Available" + rule view (constraints below)
│ └ kindTiles    NSStackView, horizontal, .fillEqually, spacing 0:
│                AirPlay · Bluetooth · Cast · This Mac                                              4 × 77.4
└ unavailable    tile, content inset 13 (1 pt rule + 12)                                            77.4 pt
  + rule         1 pt view on the tile's leading edge, strip top + 2 to strip bottom − 2
```

- **Caption:** "Available", `Tokens.Font.captionEmphasized`, `label2`, at the strip's leading edge.
- **Caption rule:** 1 pt `Tokens.Color.containerEdge` (`hairline` is not allowed on `raised`, DESIGN.md Don'ts). Leading = caption trailing + 8; trailing = kindTiles trailing − 12; centre 3 pt above the caption's baseline. Minimum width 0, low compression resistance.
- **Card coordinates, English:** caption x 18-67; rule x 75-315.6; vertical rule at x 327.6; Unavailable glyph at x 340.6.
- `.lastBaseline` lines up the five labels' baselines. The vertical rule is not an arranged view, so it does not take part in that alignment.
- Kept from M: tile internals (16 pt glyph, 6 pt, count in `heading` with tabular digits, 1 pt, label), 12 pt top and 11 pt bottom padding, 4 pt under the caption, the placeholder positions.
- Both rules are decoration only: `setAccessibilityElement(false)`.
- Mockups: M `.kinds .capt` gains the rule in the window, the four state panels and "How the numbers fill in"; the same in C's window and its "12 Unavailable" map.

### 8. Overview: long translations and what can truncate

This is HARDEN 13's rule, placed in amendment 7's structure:
- **Unavailable tile:** 13 + the wider of its label and its glyph-and-count, at least 77.4 pt; hugging and compression resistance required.
- **kindTiles** takes the rest, `.fillEqually`, each tile at least 62 pt ("Dieser Mac" is 58.8). A tile label keeps 3 pt clear of the next tile.
- **The caption rule follows kindTiles' width**, so "Available" spans exactly the four whatever width they get. German: Unavailable 95.2 pt ("Nicht verfügbar", 82.2), kind tiles 72.95 pt each, caption rule ending at card x 297.8.
- **Past 126 pt** (387 − 4 × 62 − 13) the Unavailable label truncates at the tail; the tile's VoiceOver value is a full sentence.
- **The caption:** "Available" is 49.0 pt, "Beschikbaar" 67.5. With the kind tiles at their 62 pt floor the rule still gets 160 pt. A caption that outgrows its group squeezes the rule to 0 first, then truncates at the tail.
- **Nothing in the card truncates in English.** The widest kind label, "Bluetooth", is 50.7 pt in 77.4. "100" is 30.6 pt, so glyph, gap and count take 52.6 pt, under the 62 pt floor. Kind labels truncate only in a translation wider than about 59 pt at the floor.
- Mockups: HARDEN 14's German zoom, drawn with the caption rule ending at x 297.8.

## Touches other passes

- **Typeset.** TYPESET.md keeps the section titles, subsection headers and divider label at 11 pt, which every height here assumes (13 pt line); a 13 pt header would need a 22 pt row. Its x 18 / x 48 positions become x 14 / x 46 (amendment 1). At `.medium` the table replaces the font of any cell's `textField` outlet (measured: group rows become 11 pt regular, other rows 13 pt regular). So `captionEmphasized` on headers (:1250), `bodyEmphasized` on the plates (:1285) and TYPESET.md's new `captionMedium` header pool do not survive on this macOS unless they are set after the table sets its font, or on labels that are not the outlet.
- **Colorize.** Assumed, and matching COLORIZE.md item 5 and its layout note: divider glyph and label in `labelCool`, divider rule in `Tokens.Color.separator`, both overview rules in `containerEdge`.
- **Audit.** AUDIT.md item 1 keeps the two subsections top-level, with Overview as the "Speakers" title's child; these numbers assume that tree. Nesting deeper would need `outlineView.indentationPerLevel = 0`: at the default 13 (measured), an expandable second-level group shifts every speaker row 9 pt right. AUDIT.md item 2's "grows 16 pt" is 12 pt here, because the source list already puts 13 pt above the title. The divider row and both title rows stay unselectable, and with no spacer row there is nothing blank to hide.

## Owner calls

1. **Middle-truncated sidebar names** (carried from HARDEN; default yes). What you would see on this Mac, where the list scrolls and a scroll bar takes 17 pt: "MacBook…Speakers", "Move 2 (…Bedroom)", "Sonos M…Kitchen)". Today's tail truncation shows "MacBook Pro Spe…", "Move 2 (SONOS B…", "Sonos Move (SON…".
