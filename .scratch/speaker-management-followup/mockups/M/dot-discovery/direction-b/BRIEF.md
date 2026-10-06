# Direction B: reachability drawn on the device icon, no dot

Made with impeccable `shape`. Inputs: `../../OWNER-BRIEF.md` (its rulings stand in for the interview), `../../BRIEF.md`, `../../CRITIQUE.md`, `../../mockup.html`. Line numbers are on `claude/speakers-nav` at 050ba9a0.

Mockup: `mockup.html`, `mockup.png`, `mockup-dark.png`. The full 653 pt Speakers tab with the owner's 20 speakers, Overview selected. Beside it: every row state with both selection pills and Increase Contrast, the overview's fifth count next to two rows, what VoiceOver says, and the three options below. Glyphs are the real SF Symbols the code names, rendered flat.

## Job

The sidebar answers "which speakers can I use right now?" with nothing in front of the icon. Two states (owner's ruling): reachable on the network, or not. Filled and strong means reachable, in the Mixer's connected colour; no red, no gold, not colour alone, and the Mixer's hollow ring keeps its one meaning.

## Options looked at

| | What changes on the row | Verdict |
|---|---|---|
| A | Reachable rows draw the symbol's filled form, unreachable rows its outline form. | **Fails.** The glyphs already use filled and outline for identity: `Device.Kind.symbolName` puts `homepod.fill` beside `laptopcomputer` (`Device.swift:59-82`), and Bluetooth products draw outline `airpods` and `headphones` (`Device.swift:203-217, 254-263`). Checked with `NSImage(systemSymbolName:)` on this Mac: no filled form for `laptopcomputer`, `headphones`, `airpods`, `airpodspro`, `airpodsmax`, `desktopcomputer`, `music.note`, `fork.knife`; no outline form for `tv.and.hifispeaker`, the Cast glyph. This Mac would always look unreachable and Cast always reachable. |
| **B** | **Reachable: the glyph sits on a filled rounded square. Not reachable: the same glyph with no square.** | **Chosen.** Works for every glyph, including any the icon picker offers (`DeviceIcon.swift:25`), because the glyph itself never changes. |
| C | Only the ink changes: name and icon go from `label` to `labelCool2`. | **Colour alone:** 3.04:1 between the two inks in light, 2.83:1 in dark. Adding weight would not fix it: a bold name means "unread" in Mail's sidebar, and it widens 8 names. |

Dropped without drawing: a fill behind each reachable row (the owner took the row wash out of the Mixer in PR #272, and a filled row reads as the selection pill or as the two plates); a trailing "Unavailable" word (12 of 20 rows, and about 60 pt the name column doesn't have).

## The direction

### Row

No mark before the icon. The icon box stays 22 pt at the cell's leading edge (`SurfaceLayout.sidebarIconSize`, `SurfaceLayout.swift:24`), 8 pt to the name (`:28`).

| Row | Icon | Name |
|---|---|---|
| Reachable on the network, connected and playing included; This Mac | glyph on a 20 pt rounded square (radius 5, continuous corners) filled with `rim`; glyph white, fitted to a 12.5 pt box | `label` |
| Not reachable: unavailable or can't be found | the same glyph, same size and place, no square, in `labelCool2` | `labelCool2` |
| Reachable, selected (grey pill) | square filled with `label`, glyph in the pill's colour, so it reads cut out | `label` |
| Not reachable, selected (grey pill) | glyph in `label` | `label` |
| Reachable, selected, list in focus (accent pill) | white square, glyph in the accent colour | white |
| Not reachable, selected, list in focus | glyph white | white |

- **Why `rim`.** It is the Mixer's connected colour: a connected speaker's glyph sits inside a `rim` ring (`HaloRingView.swift:243-249`). The sidebar keeps that colour and that place, around the glyph, but fills it as a square, so nothing in the sidebar is a hollow ring. A bare glyph is how the Mixer already draws a speaker with no connection: no ring.
- **Why `labelCool2`.** It is the Mixer's ink for a speaker with no live connection (`DeviceRowView.swift:2443-2447`). It replaces the warm `label3` the sidebar dims to today (`SidebarViewController.swift:1298, 1300`), so the brown the owner disliked leaves the 12 unreachable rows too (critique problem 6).
- **Same glyph size in both states.** Only the square comes and goes; the name never moves.
- **Names get 16 pt back.** The dot (9 pt, `SidebarViewController.swift:955`) and its gap (7 pt, `:1330`) go, so the name column is 144 pt and "MacBook Pro Speakers" (139.9 pt) fits again.
- **The two plates** (Main Audio, Overview) keep a bare glyph in `label`. Their own fill and edge set them apart from speaker rows.
- **Selected rows** switch ink because the resting colours fail on the pills: `labelCool2` measures 4.04:1 on the grey pill in light and 2.75:1 in dark; `rim` measures 3.43 and 2.03 there (M), and about 1.2 on the accent pill. The cell reads its `backgroundStyle` (`.emphasized` is the accent pill), as M already required for its dot.
- **Nothing animates.**

### Contrast (WCAG ratios; sidebar ground bracketed as in M: `#E8E8EA`–`#F5F5F6` light, `#1E1E20`–`#2C2C2E` dark)

| | Light | Light, Increase Contrast | Dark | Dark, Increase Contrast |
|---|---|---|---|---|
| Square (`rim`) against the ground | 4.08–4.58 | 5.10–5.73 | 2.99–3.58 | 4.00–4.78 |
| White glyph on the square | 4.99 | 6.24 | 4.65 | 3.48 |
| `labelCool2` name and glyph against the ground | 4.52–5.08 | 6.92–7.77 | 4.06–4.84 | 6.19–7.39 |
| `label` square on the grey pill | 12.29 | | 7.78 | |
| White square on the accent pill | 4.78 | | 6.40 | |

### Increase Contrast

`rim` and `labelCool2` resolve their own Increase Contrast values (`Tokens.swift:311-314`, `:527-529`); the cell already repaints on the display-options change (`SidebarViewController.swift:965`). The shapes do not change.

### A hidden speaker that is playing

Fancyy: the 40 pt row with the caption "Shown while playing" (M's string; critique problem 8 proposes "Shown while in use", not yet decided). It is reachable, so it draws the square. Playing adds nothing: the sidebar shows presence, never routing (`AudioutWindowUI/AGENTS.md:12`), and gold stays in the Mixer.

### VoiceOver

Unchanged from M. The square is drawing only; the icon is already decorative (`SidebarViewController.swift:1287-1297`) and the row's label carries the state (`:1312-1321`): nothing added for a reachable row, ", unavailable", ", can't be found" once the first search has settled, ", shown in the Mixer while playing". The overview's fifth count says "12 speakers unavailable".

## Overview page

M's page, with only the glyphs changed:

- **The four available counts** draw their kind glyph on the same 20 pt `rim` square, glyph white: `airplayaudio`, `radio.fill`, `tv.and.hifispeaker.fill`, `laptopcomputer`. A count of 0 keeps its square; the square says what the number counts.
- **Unavailable, the fifth count** (owner's ruling) draws `hifispeaker.fill` with no square, in `labelCool2`: what an unreachable row looks like. Sidebar and page agree: 8 squares = 4 + 0 + 3 + 1; 12 bare glyphs = 12.
- **The can't-be-found row** takes `magnifyingglass` in `label2`, M's glyph ink for list rows. M gave it the ring; a second bare speaker glyph under the Unavailable count would read as 6 more unavailable speakers (critique problem 4).
- **Correction to M's decision 10:** `tv.and.hifispeaker` (no `.fill`) does not resolve on this Mac. The squares use the filled forms, so nothing here needs it.

## Builder notes

- `SidebarPresenceDotView` and the dot branch of `newCell(withDot:)` go. The square is a layer-backed view behind the image view, resolving `rim` in `updateLayer` the way `HaloRingView` does (`wantsUpdateLayer`), radius 5 with continuous corners. The glyph comes from `DeviceIcon` fitted to a 12.5 pt box, using `rowGlyphFits` scaled down for optical centring.
- One input drives it: the `dimmed` flag the device row already computes from `record.isAvailable` (`SidebarViewController.swift:1188-1190`) picks square or no square and `label` or `labelCool2`.
- `SidebarActionsTests.swift:123-124` pins `.playing` and `.lost` dot states; they become square / no square.
- Docs that change: `AudioutWindowUI/AGENTS.md:12` ("The sidebar's dot shows presence") and its map line ("presence dots"); DESIGN.md "Speakers Sidebar and Pages" (`:678`).
- DESIGN.md asks for any new custom drawing to be named in the owning folder's `AGENTS.md` (`DESIGN.md:1020-1022`). The square is one.
- Radius 5 is off the 10/16/26 ladder. At 20 pt, radius 10 would make a circle, a filled version of the Mixer's ring, which this direction exists to avoid. Name the radius with the square.
- Analytics: no event changes.

## Main risk

Eight grey squares can read as an icon style rather than a state. System Settings puts every sidebar icon on a coloured square, so a reader may take the squares as decoration. The meaning shows only by contrast with the bare rows and the overview's matching glyphs. When every speaker is reachable, every row has a square and nothing on screen says what it means.

## Open questions for the owner

1. **The System Settings likeness.** Accept grey squares that may read as decoration until a speaker drops off? Default: yes; judge it in the live build.
2. **Dark ground for `labelCool2`.** It falls under 4.5:1 if the real dark sidebar ground is lighter than about `#242426` (4.06 at the light end of the estimate). Default: measure once on a real window; if under, unreachable names in dark use `labelCool` (6.54–7.81) and the glyph keeps `labelCool2`.
3. **Dark Increase Contrast glyph.** White on the lighter Increase Contrast square drops to 3.48:1, below the 4.65 it has without Increase Contrast. Default: keep white (passes 3:1 for graphics, one rule everywhere). Alternative: `canvas` ink there, 5.67:1.
