# Sidebar reachability marks: variety sheet

`variants.html` / `variants.png` / `variants-dark.png`. Fourteen options, each drawn as the same four sidebar rows at rest plus the same two speakers selected on the grey pill and the accent pill, in light and dark side by side. Option 14 (empty slot) is the owner's ruled-out case, kept only as the baseline. Device icons and SF Symbols marks are the real system glyphs, rendered through the macOS scripting bridge and embedded in the page.

Rules applied: filled means reachable (owner, 2026-10-04); no hollow ring (the Mixer's connected-and-silent mark, `RouteArmedDotView.swift:184-185`); no dashed ring (the Mixer's connecting ring); no red, no gold; the two states differ in shape. A selected row draws its mark in the row's text colour, because `rim` measures 1.04 (light) and 1.37 (dark) on the accent pill. Unreachable names and icons dim to `labelCool2` in every option (critique problem 6).

Contrast is measured against an estimated sidebar ground (light `#E8E8EA`-`#F5F5F6`, dark `#1E1E20`-`#2C2C2E`). Nobody has measured the real source-list ground since 2026-09-03.

## Top 3

### 1. Disc, dash (option 1). Recommended.

- Reachable: the 9 pt `rim` disc it has today. Not reachable: a 7 × 2 pt `rim` dash with round ends, centred in the same slot.
- The dash is the ordinary sign for "nothing here". It has less ink than the disc, so in the owner's fleet (8 reachable, 12 not) the reachable rows lead the eye and the 12 recede.
- Nothing like it exists in the Mixer, so it can't be read in the Mixer's terms.
- On both pills the disc and dash stay distinct by shape alone.
- Builder change is one case in `SidebarPresenceDotView.draw` (`SidebarViewController.swift:981`, the `.away` case) plus the selected-row ink the brief already specifies. No new token, no width change.
- Contrast: light 4.08-4.58, dark 2.99-3.58 at standard contrast. If the measured dark ground lands under 3:1, draw both marks in `labelCool2` (dark 4.06-4.84). Don't mix them: a `labelCool2` dash beside a `rim` disc is brighter than the disc in dark.
- Risk: next to a list item a dash can read as "remove".

### 2. Disc, slash (option 2)

- Same disc. Not reachable: a 1.75 pt diagonal stroke inside the 9 pt box.
- The slash says "not" outright, the way SF Symbols' `.slash` variants do. It explains itself better than the dash.
- Second because the Mixer's mute glyph is `speaker.slash`, so a slash in a speaker list can read as "muted". A thin diagonal also renders lighter than its colour at 1x, so in dark it falls under 3:1 sooner than the dash does.

### 3. Large dot, small dot (option 3)

- Same disc. Not reachable: a 3 pt dot in the same slot.
- The quietest unreachable mark on the sheet: it reads as a light that has gone out. With most of the fleet unreachable, this one makes the reachable speakers stand out most.
- It strains the owner's "filled means reachable", because the small mark is still a filled dot. That is his call. It can also pass for a list bullet.
- Drawn here in `labelCool2`. Shipped, it should take whatever ink option 1 lands on.

## Why the others lost

- **Antenna struck through (7):** explains itself, but at 8.5 pt the two glyphs are hard to tell apart at a glance, and the struck glyph carries more ink than the unstruck one. Twelve struck glyphs make the list busier where it should get quieter.
- **Wi-Fi struck through (8):** wrong for Bluetooth speakers and This Mac.
- **Waves, minus (9):** waves suggest the speaker is playing.
- **Tall bar, short bar (4):** reads as a level meter, and the stub reads as a full stop.
- **Pill, thin line (5):** `label2` is the warm brown the owner turned down, and the 1.5 pt line disappears at 1x.
- **Square, underline (6):** the underline looks like an underscore, and it isn't the Mixer's connected colour.
- **Badge on the icon (10):** sits exactly where the Mixer's status dot sits (8 pt on the icon's bottom-right corner, 10.5 pt cut-out, `PopoverColumnGrid.swift:387-391`). The dash badge also merges into icon lines.
- **After the name (11):** saves no width, and it loses the 16 pt step the subsection headers use to line up with the device icons. It is the best choice if the owner wants the mark off the leading edge.
- **Icon filled vs outline (12):** the best idea on the sheet, with nothing added to the row and 16 pt back for names. But 14 of the 28 symbols in `DeviceIcon.swift` have no filled or outline twin, including headphones, every AirPods and Beats symbol, and `laptopcomputer`. That's 7 of the owner's 20 speakers as `../../mockup.html` draws their icons, which would be left with colour alone.
- **Icon heavy vs light (13):** stroke weight at 16 pt is too small a difference, especially on a selection pill.

Left out entirely: chevron (disclosure, close to play), xmark (close or error), and the empty socket fill (`Tokens.Color.socket`, 1.02-1.20 on the sidebar, so it disappears).
