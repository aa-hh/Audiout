# Typeset: Speakers tab, direction M with sidebar direction C

Made with impeccable `typeset`, 2026-10-04, against `claude/speakers-nav` HEAD b9b70310. Widths and line heights are AppKit's own `NSFont` metrics at 1x (they reproduce BRIEF.md's 139.9 pt and HARDEN.md's 161.7 pt); the subsection-header change was checked in a scratch render of `dot-discovery/direction-c/mockup.html`, light and dark.

## Amendments

### 1. The sidebar's four 11 pt styles: weight marks structure, regular weight marks state

- **Section title** ("System Audio", "Speakers"): unchanged. `Tokens.Font.captionEmphasized` (11 pt semibold, `Tokens.swift:1302-1304`) in `label2`, flush at x 18 (`SidebarViewController.swift:1250-1251`, `:1260`).
- **Subsection header** ("Shown in Mixer", "Hidden unless in use"): **`Tokens.Font.captionMedium`** (11 pt medium, `Tokens.swift:1296-1298`) in **`label3`**, x 18. Before: `caption` + `label3` in M (identical to the row caption, CRITIQUE.md's typeset note); `caption` + `label2` in direction C.
- **Divider label** ("8 unavailable"): 11 pt regular with tabular digits, the new `Tokens.Font.captionDigits` (item 6), in `labelCool`, x 48. Direction C already asks for tabular digits; this names the font.
- **Row caption** ("Shown while in use"): unchanged. `Tokens.Font.caption` (11 pt regular) in `label3` (`SidebarViewController.swift:849-850`), x 48, 2 pt under the name (`:862`).

The rule: semibold for a section, medium for a subsection, regular for anything that describes a speaker's state. How each pair differs:
- Title against subsection header: weight (600 to 500) and ink (`label2` to `label3`). This is the Mixer's own pair, one tab away: its card title is `captionEmphasized` in `label2` (`PopoverPanelViewController.swift:723-724`), its subsection headers ("AirPlay Speakers", "Bluetooth Speakers") are `captionMedium` in `label3` (`:1419-1420`, through the old alias `inkTertiary`). The token's own doc lists subsection headers as a `label3` job (`Tokens.swift:117`).
- Subsection header against row caption: weight (500 to 400) and position (its own 28 pt row at x 18, against x 48 and 2 pt under a 13 pt name).
- Divider against row caption: ink (cool `labelCool` against warm `label3`), the glyph in the icon column and the rule after the label. Both describe state, so both stay regular.
- None of the four adds tracking (no `.kern`; AppKit applies SF Pro's own 11 pt spacing), none changes case, all truncate at the tail (`:1252`, `:852`).
- Widths at 11 pt medium: "Shown in Mixer" 81.1 pt, "Hidden unless in use" 111.0 pt ("Hidden unless playing" 118.0), in a header column of about 174 pt, so the stock Show/Hide control still fits beside the second header.
- In light mode `label2` and `label3` measure 5.97:1 and 5.60:1 on the flat ground (`Tokens.swift:111`, `:125-126`), nearly one ink, so there the weight step carries the difference. The scratch render shows medium sitting between the semibold title and the regular captions in both modes.
- Mockup: `dot-discovery/direction-c/mockup.html`, rule `.sub`: add `font-weight:500`, colour `var(--label3)`. Every frame that draws a group header picks it up (window, launch, drag, set-aside options). Same change in `M/mockup.html`'s "Sidebar strings that change" panel.

### 2. Builder: subsection headers get their own cell pool

- Today one factory and one reuse pool, identifier "header", serve every header (`makeHeaderLabel`, `SidebarViewController.swift:1234-1266`). Give subsection headers a second identifier whose cell sets `captionMedium` / `label3`, so a reused cell never carries the other level's font. `makeIconLabel` already keeps one setting per pool for the same reason (`:1281-1284`).
- Both levels stay `isGroupItem` (`:1113-1117`): not selectable, skipped by arrow keys, and the stock Show/Hide fold on the second subsection (`:1122-1124`).
- Native behaviour: a `.sourceList` outline has one header level. Finder, Mail and Music show nesting by indenting rows under a header, never by a second header style, and AppKit offers no sub-header style to borrow. This header cell is already custom (`newHeaderCell`, `:1243-1266`), so the second level costs a font and a colour, not a break from a stock look.

### 3. Selected rows: every text ink becomes the row's text colour

- Today the row caption is fixed `label3` (`:850`), a dimmed name and icon are fixed inks (`:1298-1300`), and nothing in `SidebarViewController.swift` reads `backgroundStyle`. On the accent pill `label3` measures about 1.2:1 (light) and 2.1:1 (dark) against the mockup's estimated blues.
- Rule: BRIEF.md line 44's rule for the dot, extended to text. On the accent pill (`backgroundStyle == .emphasized`) name, caption and icon take `NSColor.alternateSelectedControlTextColor`; on the grey pill (row selected, list not focused) they take `label`. Fonts never change with selection.
- Direction C's mockup already draws this (`.row.sel .c`); only the code lacks it.

### 4. Speaker row names

- 13 pt regular: the `.medium` source-list row font (`rowSizeStyle`, `:182`; the code leaves this field's font to the source list, `:1281-1284`), the same as `Tokens.Font.body`. Ink `label`; unreachable rows `labelCool` (direction C). State changes ink only, never weight or size, so a row that moves under the divider keeps its exact width.
- Middle truncation (owner call carried from HARDEN.md 12, default yes): set `lineBreakMode = .byTruncatingMiddle` once in `newCell` (`:1343`, tail today). Every field that factory makes is a name, and the two plate labels never reach the column edge (Main Audio 69.9 pt, Overview 59.0 pt). The header (`:1252`) and the caption (`:852`) keep tail truncation.
- In direction C's 144 pt name column (its Geometry section): "MacBook Pro Speakers" (139.9 pt) fits. "Move 2 (SONOS Bedroom)" (161.7) becomes "Move 2 (SO… Bedroom)"; "Sonos Move (SONOS Kitchen)" (182.6) becomes "Sonos Move… Kitchen)". Tail truncation today gives "Move 2 (SONOS Bedr…" and "Sonos Move (SONOS …". Simulated with AppKit's metrics; the real split can differ by one character. The room, which tells the two Sonos apart, survives whole; the cut falls inside "SONOS", the part both names share.
- HARDEN.md 12's results ("Move 2 (…Bedroom)", "MacBook …Speakers") were measured in M's 128 pt column; direction C's wider column replaces them.
- Mockup: `direction-c/mockup.html`, the two Sonos rows drawn with the middle cut (the tail cut is drawn now).

### 5. Plates and the page title

- "Main Audio" and "Overview": `Tokens.Font.bodyEmphasized` (13 pt semibold, `Tokens.swift:1260-1262`) in `label`, unchanged (`SidebarViewController.swift:1285`). Same size as the speaker names, one weight step heavier, plus the raised plate and the chevron. The 11 pt semibold `label2` section title above each plate is smaller and dimmer, so it reads as the plate's label, the way Finder's section headers sit over its 13 pt items.
- Builder: Main Audio moves onto a plate (BRIEF.md row 2), so its pool ("mainOut") passes `emphasized: true` as well; rewrite the comment at `:1281-1284`, which says "speakersOverview" is the only pool that asks.
- No second line on Main Audio (owner call carried from CLARIFY.md 5, default none).
- Page title "Overview" (CLARIFY.md 4) in `Tokens.Font.heading` (`SpeakersPageViewController.swift:146`), 70.9 pt. The plate and the page it opens carry one word.
- Mockup: the window's page title in `direction-c/mockup.html` and the four state panels in `M/mockup.html`: "Speakers" becomes "Overview".

### 6. Two new styles with tabular digits

Both reuse a size already on the scale and add only the tabular-digit feature, as `readout` (`Tokens.swift:1291-1293`) and `syncReadout` (`:1329-1331`) do. DESIGN.md's One Case rule allows tabular digits (`DESIGN.md:421-423`).
- **New: `Tokens.Font.headingDigits`** = `NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize + 3, weight: .semibold)`. 16 pt, semibold, tabular digits, default tracking. For the five overview counts.
- **New: `Tokens.Font.captionDigits`** = `NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)`. 11 pt, regular, tabular digits, default tracking. For the sidebar divider label and the overview's header total. `DeviceRowView` already builds this exact font privately for its sync chip (`DeviceRowView.swift:2066-2067`); leave that site alone in this change.
- Why: SF Pro's default digits are proportional. At 16 pt semibold "1" is 7.59 pt wide and "4" is 10.42; tabular makes every digit 10.19, so "1 This Mac" stops looking pinched beside "4 AirPlay", and a count that changes live never changes width. In the divider the rule starts 8 pt after the label: proportional "1 unavailable" is 66.9 pt and "8 unavailable" 68.9, so the rule's start would jump 2 pt when a speaker drops off; tabular holds it at 68.8 for every one-digit count.
- Today the counts use `Tokens.Font.heading` (`SpeakersPageViewController.swift:352`), whose digits are proportional (`Tokens.swift:1269-1271`).

### 7. Overview counts

- `headingDigits` in `label`; a 0 in `label3` (BRIEF.md decision 9). A zero is quieter by ink only, in the same font, so a 0 becoming 1 moves nothing.
- 16 pt stays. It is the heading step, one above body; the only size between 13 and 16 is `plateTitle` (15 pt, `Tokens.swift:1344`), single-use by its own doc. The counts share the page title's size and weight; the card around them and the label under each keep the two apart.
- Mockup: `.num` is already 16 pt semibold with tabular digits; no change.

### 8. One baseline for the five numbers, one for the five labels

- Today the strip aligns its tiles at the top (`SpeakersPageViewController.swift:343`), and the numbers line up only because every tile is the same stack: glyph and count centred on one line (`:357`), label 1 pt under (`:364`). M's "Available" caption over four tiles, the full-height rule before Unavailable and HARDEN.md 13's wider Unavailable tile end that sameness.
- Pin it: each count's `firstBaselineAnchor` equals the AirPlay count's; each label's `firstBaselineAnchor` equals the AirPlay label's. That holds whatever the layout pass does with Unavailable.
- Count baseline to label baseline: 15.0 pt (16 pt semibold descent 3.38 + the 1 pt gap + 11 pt ascent 10.63).
- The 16 pt glyph stays centred on the count's line. The digits' visual centre sits 0.4 pt below the centre of the 18.84 pt line; leave it.
- Mockup: the CSS grid already shares rows; no change.

### 9. Placeholders that move nothing when their number lands

- **Counts.** Keep the count field in the tile while its number is unknown, text "00" at `alphaValue` 0 with the placeholder drawn over it; on arrival set the real number and fade it in (M's 180 ms). The tile's top line is then 18.84 pt tall from the first frame. A hidden field would leave the stack, the line would shrink to the 16 pt glyph, and the label would jump about 3 pt when the number arrived. The field is already hidden from VoiceOver (`:354`).
- Placeholder 20 × 12 pt (M) is "00" in `headingDigits` (20.37 pt), so a two-digit count lands on it exactly. Nothing sits to a count's right, so one- and three-digit counts move nothing either.
- **Header total.** Before (M): "▭ speakers", a 16 × 8 pt placeholder, a 4 pt gap, then the word. When "20 speakers" lands the word jumps left from 20 pt to 16.8 pt in, and to 10.2 pt for "9 speakers". After: while loading, the line holds the placeholder alone, 14 × 8 pt (two tabular 11 pt digits, 13.99 pt), radius 2.5, and "20 speakers" fades in as one string. Nothing sits to the placeholder's right, so nothing moves. VoiceOver still says "still looking" (BRIEF.md line 186).
- Mockup: `M/mockup.html`, "How the numbers fill in" header lines at 0.0, 0.6 and 1.5 s and state panel 1: drop the word "speakers" beside the placeholder; `.tot` gains `font-variant-numeric: tabular-nums`.

### 10. "Available"

- `Tokens.Font.captionEmphasized` in `label2`, 49.0 pt (BRIEF.md decision 2, kept). On this tab that style names a group: the sidebar's section titles, and the Mixer's card titles. The tile labels under the numbers stay `caption` / `label2` (`captionField`, `SpeakersPageViewController.swift:312-314`), so "Available" (semibold) reads as the four tiles' name and "AirPlay" (regular) as one tile's.
- "Unavailable" is the fifth tile's own label and takes the tile style, not "Available"'s, although the two words pair.

### 11. Case: no string changes

- The app's practice (One Case, `DESIGN.md:421-423`): text renders as authored; names of places, products and settings are capitalised (System Audio, Main Audio, This Mac, AirPlay, Bluetooth, Cast, Mixer, Local Network, Privacy Settings) and everything else is sentence case, buttons and menu items included: "Add scene" (`SidebarViewController.swift:223`), "Speaker settings…" (`:371`), "Pair Bluetooth speaker…" (`SpeakersPageViewController.swift:408`). The macOS HIG asks for title case on buttons and menu items; the app chose sentence case, and this tab follows the app.
- Every string in these places passes: System Audio, Main Audio, Speakers, Overview, Shown in Mixer, Hidden unless in use, 8 unavailable, Shown while in use, 20 speakers / 1 speaker / No speakers, Available, AirPlay, Bluetooth, Cast, This Mac, Unavailable, 6 speakers can't be found, Forget 6 speakers…, Local Network access is off, Open Privacy Settings…, Bluetooth access is off, Allow Bluetooth…, Pair Bluetooth speaker….
- "Shown in Mixer" reads the same in both case styles, since title case leaves "in" lower case. Title case would make the second header "Hidden Unless in Use"; sentence case suits a phrase.
- A string that starts with a count stays lower case after the number, as the scene cards' "2 unavailable" does (`GroupsOverviewViewController.swift:637`).

### 12. Docs and briefs that go stale

- `Tokens.swift:1294-1295`: `captionMedium`'s doc lists its users; add sidebar subsection headers.
- `DESIGN.md:403-417` (Typography, Hierarchy): add the two tabular styles beside Readout, and one line for the sidebar's two header levels, matching the Mixer's.
- `DESIGN.md:510` "the count in `Tokens.Font.heading`" becomes `headingDigits`. `DESIGN.md:679` calls System Audio a row; it is a header (`SidebarViewController.swift:529`).
- `M/BRIEF.md` line 24 (subsection header in `caption` / `label3`, 16 pt in) and line 167 ("`Tokens.Font.heading` … with tabular digits", which that token cannot give): replaced by items 1 and 6. `dot-discovery/direction-c/BRIEF.md`, Geometry ("`caption` and `label2`" for group headers): replaced by item 1.
- `copy/COPY.md` cites `DESIGN.md:670-682` and `:699-705`; at b9b70310 those paragraphs sit at `:679-694` and `:707-713`.

## Final type scale, Speakers tab

| Element | Style | Size | Weight | Digits | Ink assumed |
|---|---|---|---|---|---|
| Sidebar section title ("System Audio", "Speakers") | `captionEmphasized` | 11 | semibold | proportional | `label2` |
| Plate label ("Main Audio", "Overview") | `bodyEmphasized` | 13 | semibold | proportional | `label` |
| Subsection header ("Shown in Mixer", "Hidden unless in use") | `captionMedium` | 11 | medium | proportional | `label3` |
| Speaker name, reachable | source-list `.medium` font (= `body`) | 13 | regular | proportional | `label` |
| Speaker name, unreachable | source-list `.medium` font (= `body`) | 13 | regular | proportional | `labelCool` |
| Row caption ("Shown while in use") | `caption` | 11 | regular | proportional | `label3` |
| Divider label ("8 unavailable") | `captionDigits` (new) | 11 | regular | tabular | `labelCool` |
| Any text on a selected row | unchanged | | | | `label` on the grey pill, `alternateSelectedControlTextColor` on the accent pill |
| Page title ("Overview") | `heading` | 16 | semibold | proportional | `label` |
| Header total ("20 speakers") | `captionDigits` (new) | 11 | regular | tabular | `label2` |
| "Available" | `captionEmphasized` | 11 | semibold | no digits | `label2` |
| Count | `headingDigits` (new) | 16 | semibold | tabular | `label`; 0 in `label3` |
| Tile label ("AirPlay" … "Unavailable") | `caption` | 11 | regular | no digits | `label2` |
| Card row title ("6 speakers can't be found", "Pair Bluetooth speaker…") | `body` (`ListRowView.swift:58-59`) | 13 | regular | proportional | `label` |

## Touches other passes

- **colorize:** every ink in the table is an assumption. If subsection headers turn cool, use `labelCool`, not `labelCool2` (4.06:1 for 11 pt text on the darkest dark ground, direction C's contrast table), and keep `captionMedium`.
- **layout:** in light mode the title-to-subsection step also leans on space: a gap above each section title and none above a subsection header. Item 8's baseline anchors hold for one strip or for Unavailable on its own row. The 174 pt header column assumes 18 pt side insets.
- **audit:** mark subsection headers as VoiceOver headings under their section title, as the Mixer does (`PopoverPanelViewController.swift:1421-1423`); measure item 3's selected-row inks on the real pills (the mockup's blues and greys are estimates).
- **clarify / harden:** strings assumed: "Hidden unless in use", "Shown while in use", page title "Overview", "No speakers" at zero.

## Owner calls

1. "Hidden unless in use" or your "Hidden unless playing" (CLARIFY.md, default "in use"). The type is the same either way; both fit at 11 pt medium (111.0 / 118.0 pt).
2. A state line on the Main Audio plate (CLARIFY.md 5, default none). If yes: `caption` 11 pt regular in `goldText`, 2 pt under "Main Audio" like the speaker row caption, plate 44 pt tall.
3. Middle-truncated speaker names (HARDEN.md 12, default yes): "Move 2 (SO… Bedroom)" instead of "Move 2 (SONOS Bedr…".
