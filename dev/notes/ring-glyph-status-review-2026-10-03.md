# Speaker-row rings, glyphs and status dot: design review (2026-10-03)

Read-only review of `main` at 71d99c73. Nothing in the source was changed.

Method: one reviewer, no second independent pass. The impeccable critique's markup scanner only reads web pages, so it has nothing to scan in AppKit Swift. Every number below comes from rendering the real SF Symbols with the code's exact settings in a scratch Swift program, from WCAG 2.x contrast maths on the token hex values, or from pixels sampled out of the owner's screenshot.

- Glyph renderer: `NSImage(systemSymbolName:)` + `SymbolConfiguration(pointSize:, weight: .regular)`, drawn into a 26 × 26 pt box with the same shrink-to-fit rule as `.scaleProportionallyDown`, at 8 px per point. A pixel counts as ink above 25% opacity.
- Colour-blind check: Machado 2009 full-strength protanopia and deuteranopia matrices (the two common kinds of red-green colour blindness).
- Contrast is measured against the popover ground, `canvas`: `#FAFAFB` in light, `#0A0A0C` in dark. Dark is also checked against `panel` `#15171A`.

## Geometry as built

| Part | Value | Where |
|---|---|---|
| Icon box | 26 × 26 pt, image shrinks to fit, never grows | `PopoverColumnGrid.swift:202`, `DeviceRowView.swift:1544` |
| Glyph | 18 pt, regular weight, every symbol | `PopoverColumnGrid.swift:287`, `DeviceRowView.swift:593-599`, `MainOutRowView.swift:376-381`, `MembershipRowView.swift:315-316` |
| Device ring | 30 pt across the stroke centre, 1.6 pt stroke (failed 1.8). **Inner edge radius 14.2 pt** | `PopoverColumnGrid.swift:332-341` |
| Main Audio ring | 34 pt, 2 pt stroke when connected, otherwise 1.6. Inner edge radius 16.0 pt | `PopoverColumnGrid.swift:164, 172` |
| Ring gap | 70° opening centred on the bottom-right, where the dot sits | `PopoverColumnGrid.swift:354, 361` |
| Status dot | 8 pt disc, centre 10 pt right and 10 pt down from the icon centre, 1.5 pt border **stroked on the 8 pt outline** (so 0.75 pt of the border eats into the fill) | `PopoverColumnGrid.swift:273, 291, 396`; `RouteArmedDotView.swift:52, 143-149` |

## Findings

### P1-1. The Bluetooth glyph is drawn about 27% larger than the AirPlay speaker and touches the ring

Evidence (the full table is in the appendix):

- `radio.fill` (the Bluetooth fallback, `Device.swift:79`) inks a 20.0 × 20.1 pt square at 18 pt. `hifispeaker.fill` (the AirPlay speaker) inks 13.5 × 18.2 pt. Taking the square root of width × height as one size number, that is 20.0 against 15.7: 27% larger edge to edge, with 1.42× the filled area.
- Its farthest ink point sits 13.7 pt from the centre. The ring's inner edge is at 14.2 pt, which leaves 0.5 pt of clearance. After anti-aliasing, the radio's top edge touches the ring.
- The status dot covers 30% of its own area in radio ink. On every other default glyph it covers 0–15%.
- The same over-size, to a lesser degree, hits the other Bluetooth glyphs: `car.fill` 18.2 with 1.3 pt clearance, `headphones` 17.8, `airpodsmax` 18.6, `airpods.gen3` 18.2, `beats.earphones` 18.9. It also hits `appletv.fill` at 17.2.
- The icon-picker list (`DeviceIcon.swift:25-50`) has worse cases than any default glyph. `hifispeaker.2.fill` clears the ring by 0.2 pt and `guitars.fill` by 0.5 pt. Both overlap the dot by 20–27%.

Cause: one point size for every symbol. SF Symbols at the same point size are not the same visual size. A filled, nearly square glyph like `radio.fill` carries far more ink than a tall, narrow one.

Fix: a per-symbol point size, so every glyph lands at about the AirPlay speaker's size (15.7–16.5 by the size number above; wide glyphs settle near 17–18 because their height is what limits them). The farthest ink point stays at 12.0 pt or less from the centre, which keeps at least 2.2 pt clear of the ring.

```swift
// DeviceIcon.swift — next to mainAudioSymbolName
/// Point size giving `name` the AirPlay speaker's visual size inside the 30 pt ring.
public static func glyphPointSize(_ name: String) -> CGFloat {
    glyphPointSizes[name] ?? PopoverColumnGrid.iconGlyphPointSize
}
static let glyphPointSizes: [String: CGFloat] = [ /* "Proposed" column below */ ]
```

Use it at the three places that size a row glyph: `DeviceRowView.swift:597`, `MainOutRowView.swift:376` (with `DeviceIcon.mainAudioSymbolName`) and `MembershipRowView.swift:316`. A test earns its place by naming this defect: render every `Kind` glyph, every Bluetooth product glyph and every icon-picker glyph at its table size, and assert that the farthest ink point is 12.0 pt or less from the centre.

| Type | Symbol | Now | Ink W×H at 18 pt | Size number | Ink to ring inner edge | Dot on ink | Verdict | Proposed pt → size number, clearance |
|---|---|---|---|---|---|---|---|---|
| AirPlay generic / Sonos | `hifispeaker.fill` | 18 | 13.5×18.2 | 15.7 | 3.5 pt | 3% | Reference | 18 (unchanged) |
| HomePod | `homepod.fill` | 18 | 14.1×18.1 | 16.0 | 4.4 | 0% | OK | 17.5 → 15.6, 4.9 |
| Apple TV | `appletv.fill` | 18 | 16.9×17.5 | 17.2 | 3.1 | 5% | A little big | 16.5 → 16.0, 3.5 |
| AirPort Express | `wifi.router.fill` | 18, box shrinks it to 15.6 | 21.8×14.4 | 17.7 | 1.7 | 12% | Wide; tight to the ring at the corners | 15 → 17.1, 2.0 |
| This Mac | `laptopcomputer` | 18, box shrinks it to 15.6 | 22.0×12.4 | 16.5 | 1.8 | 6% | OK; the box was already shrinking it | 15.5 → 16.5, 1.6 (no visible change) |
| Cast | `tv.and.hifispeaker.fill` | 18, box shrinks it to 15.6 | 21.6×15.5 | 18.3 | 1.4 | 15% | The dot sits on the speaker cabinet (P2-1) | 15 → 18.1, 1.7 |
| **Bluetooth fallback** | **`radio.fill`** | 18 | **20.0×20.1** | **20.0** | **0.5** | **30%** | **Too big; touches the ring** | **14.5 → 16.9, 2.7, dot 7%** |
| Bluetooth headset | `headphones` | 18 | 17.1×18.6 | 17.8 | 3.5 | 2% | A little big | 16 → 16.2, 4.5 |
| Bluetooth car | `car.fill` | 18 | 20.1×16.4 | 18.2 | 1.3 | 15% | Too big | 15.5 → 16.3, 2.8 |
| AirPods / Pro / Max / 3 / 4 | `airpods*` | 18 | up to 21.5×15.4 | 17.3–18.6 | 3.2–3.6 | 0–4% | A little big | 16.5 / 15 / 15.5 / 15.5 / 16 → 15.3–16.1 |
| Beats (5 glyphs) | `beats.*` | 18 | up to 21.6×14.5 | 14.6–18.9 | 1.9–5.4 | 0–7% | Mixed | powerbeatspro 14.5, earphones 15, fit.pro 14.5, studiobud 18, headphones 16 |
| Main Audio | `hifispeaker.arrow.forward.fill` | 18 | 15.1×18.2 | 16.6 | 5.3 (34 pt ring) | 1% | OK | 17 → 16.1 |
| Picker | `hifispeaker.2.fill` | 18 | 20.0×20.4 | 20.2 | **0.2** | 27% | Touches the ring | 14 |
| Picker | `homepod.2.fill` | 18 | 21.1×20.5 | 20.8 | 1.0 | 11% | Too big | 13.5 |
| Picker | `tv.fill`, `house.fill`, `music.note.house.fill` | 18 | ~21×18 | 19.3 | 2.8–1.1 | 1–6% | Too big | 14.5 |
| Picker | `guitars.fill` | 18 | 20.9×18.0 | 19.4 | **0.5** | 20% | Touches the ring | 14 |
| Picker | `desktopcomputer`, `sofa.fill`, `gamecontroller.fill`, `bed.double.fill`, `speaker.wave.3.fill` | 18 | — | 16.8–19.0 | 1.4–2.4 | 0–7% | Mixed | 15, 14, 14.5, 16, 14.2 |
| Picker | `music.note`, `fork.knife` | 18 | 10.1×17.6, 12.1×20.4 | 13.3, 15.7 | 4.4, 2.7 | 0–1% | `music.note` is thin and reads small at any size | 18 (leave) |

Rendered comparison (light and dark, today's size above the proposed size, with the real ring, gap and dot): `/private/tmp/claude-501/…/scratchpad/sheet.png`. That file is in a temporary folder and will not last. Regenerate it with `sheet.swift` from the same folder.

### P1-2. "Connecting" is blue on the glyph ring and gold on the rail node, side by side on one row

- The glyph ring's connecting form uses `Tokens.Color.ring`, a steel blue (`HaloRingView.swift:249-252`).
- The rail node's connecting form uses `Tokens.Color.gold` (`MembershipBusView.swift:305`).
- The screenshot's TV row shows both at once: a dashed blue ring round the glyph, and a dashed yellow node 60 pt to its left. Same state, two colours.
- Main Audio has the same split. Its ring is dashed blue while connecting, and the brown rail curves straight into it. The code already rules out two colours meeting at that join for the connected and resting forms (`HaloRingView.swift:262-268`: "A grey rim here while the wire curving into it was gold read as two unrelated things touching"). The connecting form skips that rule because it ignores `connectedSpineArmed`.
- The meaning is off too. `ring` is documented as "the informational steel-blue … 'here is a fact about the system' mark" (`Tokens.swift:359-368`) and as the wizard's reference light (`DESIGN.md:291`). DESIGN.md's colour-temperature rule says warm means sound is flowing and cool means silent. A speaker that is connecting is about to carry sound, so a cool colour says the wrong thing. The ring is the only Mixer-row use of `ring` outside the wizard and the system-note banner.

Fix: one connecting colour, `Tokens.Color.ember` dashed, for both the glyph ring and the rail node. The dimmer gold companion reads as "the wire is there, not lit yet", and it is what the rail already wears when idle. Contrast against the ground: Full 5.82:1 light, 3.94:1 dark (3.58:1 on `panel`). Subtle 5.79:1 light, 3.01:1 dark (2.73:1 on `panel`, the same documented under-floor case `ember` already carries at `Tokens.swift:641-648`). The dash stays the cue that does not depend on colour. Change `HaloRingView.swift:250` and `MembershipBusView.swift:305`. `MembershipBusView.swift:27-29` says an ember dashed node cannot be told from a gold dashed one at node size. That is no longer a problem once gold dashed stops existing.

### P1-3. The gold dashed rail node almost disappears in light mode

- Light Full `gold` `#E8B84B` measures 1.77:1 on `canvas`. The darkest pixel on the TV row's dashed node in the screenshot is `#D6B777`, 1.85:1. That is the faint yellow ring the owner noticed.
- The 1.77:1 is the owner's accepted exception for gold fills (`Tokens.swift:593-599`, 2026-09-17). Here, though, a 1.5 pt dashed line is the only thing on the rail saying "this one is connecting".

Fix: the P1-2 change (ember) fixes this too. Nothing else is needed.

### P1-4. Failed and connected glyph rings differ only by hue, and not at all for red-green colour-blind users

- Connected `rim` grey against failed `failure` red: 1.26:1 apart in brightness in light, 1.19:1 in dark. Simulated deuteranopia puts them 1.08:1 apart in light. Simulated protanopia puts them 1.10:1 apart in dark.
- Their only other difference is stroke width, 1.8 pt against 1.6 pt (`PopoverColumnGrid.swift:334, 341`). A 0.2 pt difference cannot be seen at row scale.
- Each ring on its own clears 3:1 against the ground (rim 4.78 / 4.25, failure 6.01 / 5.07), so visibility is fine. Telling them apart is the problem.
- Connecting against connected is fine: the dash carries it.
- Not P0: a failed row also shows the FEED pill's `exclamationmark.triangle` (DESIGN.md:713), so a second non-colour cue exists elsewhere on the row.

Fix: make the failed form a different shape as well as a different hue. Smallest change: `haloRingFailedStroke` from 1.8 to 2.6 pt, about 1.6 × the connected weight, which is visible at 30 pt across. Also check the 2.6 pt stroke still clears the glyph. With the P1-1 sizes the worst clearance is 1.6 pt; it would drop to 1.2 pt for `laptopcomputer`, which is acceptable for a failure state. Apply the same weight to the failed rail node (`MembershipBusView.swift:285-286`).

### P1-5. The status dot's "punch-out" border is a grey outline in light mode and invisible in dark mode

The dot is meant to sit on a border "drawn in the card/window background colour so the dot reads as a separate badge over the icon" (`PopoverColumnGrid.swift:270-273`). It uses `NSColor.underPageBackgroundColor` (`RouteArmedDotView.swift:139`, `Tokens.swift:165`), which is not the popover ground.

- **Light, live:** the screenshot's border pixels are `#9D9F9E`. That is darker than both the ground `#FAFAFA` and the fill `#DFE1E3`. So the dot reads as a grey outlined "o", which is exactly what the owner sees, and the border adds an edge instead of cutting one. Border against ground: 2.55:1.
- **Dark (resolved under dark appearance; a live dark screenshot was not available):** the border is `#282828`, 1.08:1 against the `socket` fill and 1.34:1 against the ground. With no armed light, the dot is 1.45:1 against the ground, so it vanishes off the glyph and reads as a bite taken out of the glyph where it overlaps.
- **Stroke centred on the 8 pt outline:** the visible fill is only 6.5 pt across.
- **Armed (gold) contrast, by appearance and accent setting:**

  | Appearance and accent | Gold vs ground | Gold vs glyph ink (`label2`) | Gold vs border |
  |---|---|---|---|
  | Light, Full | 1.77 | 3.38 | 1.44 |
  | Light, Subtle (`#8F7B4A`) | 3.95 | **1.51** | 1.55 |
  | Light, Increase Contrast, Full (`#8A6614`) | 5.04 | **1.18** | 1.98 |
  | Dark, Full | 10.73 | **1.22** | 8.00 |
  | Dark, Subtle | 7.42 | **1.19** | 5.53 |

  Wherever the dot overlaps the glyph (up to 30% of its area today, 0–14% after P1-1), the gold blends into the glyph in four of those five cases. Only the border can separate them, and in light the border is the wrong colour.
- **No information on screen right now:** all six rows in the screenshot show the same grey dot.

Fix, in `RouteArmedDotView.swift` only:

1. Real punch-out. Draw a 10.5 pt disc in `Tokens.Color.canvas` (the ground the rows actually sit on) behind the dot, and stop stroking the dot itself. That gives a clean 1.25 pt gap between dot and glyph in every state, appearance and accent setting. Canvas against the gold is 1.77–10.73:1, against the glyph ink 5.97 / 8.81:1. The fill keeps its full 8 pt. Replace `underPageBackground` at line 139. Its doc comment at `Tokens.swift:159-164` names this dot as its only consumer.
2. Armed: gold fill with a 1 pt `ember` rim. Its edge then clears 3:1 against the ground in every case: Full 5.82 / 3.94, Subtle 5.79 / 3.01. That matches the `ember` doc's own description: "the filled node's rim" (`Tokens.swift:635-636`).
3. Not armed: a hollow 6 pt ring, 1 pt, in `rim` (4.78 / 4.25:1), instead of the near-invisible `socket` fill. It reads as an unlit lamp in both appearances, and turning on fills the same shape gold. The owner may prefer to hide the dot when not armed. The glyph ring, the meter and the gold row wash already say "armed", and six identical grey circles carry no information. That is a one-line change (`isHidden = !armed`), but it reverses the spec's deliberate "dark/empty socket" (spec §3.3), so it is the owner's call.

### P2-1. On Cast rows the dot covers the speaker cabinet, the part that tells Cast apart from a plain TV

`tv.and.hifispeaker.fill` puts its small speaker cabinet in the bottom-right, exactly under the dot (15% of the dot is on ink at 18 pt, 14% at 15 pt). The screenshot's TV crop shows the cabinet half hidden. The 26 pt box also shrinks this glyph to 87%, so the cabinet is the smallest part of the smallest glyph. The P1-5 punch-out keeps the cabinet's top half clean. Fully fixing it means a different glyph or moving the dot, and moving the dot would also move the ring gap (`PopoverColumnGrid.swift:354`). Leave this until the owner has seen P1-5 live.

### P2-2. Main Audio's connected and resting rings differ only by 0.4 pt of stroke

Both use the spine colour. Connected is 2 pt, resting is 1.6 pt (`HaloRingView.swift:253-272`). Nobody can see 0.4 pt at 34 pt across. Today the rail's own colour tells the two apart, so this is low priority. If it matters, give resting the ember colour and connected the spine colour.

### P2-3. No wired or HDMI glyph exists on `main` yet

`Device.Kind` (`Device.swift:14-32`) has eight kinds and none of them is wired. The local wired outputs work is not merged. When it lands, its glyph needs a P1-1 table entry. `cable.connector` inks 5.2 × 20.0 pt at 18 pt (size number 10.2), and no point size makes it match the others inside the 26 pt box. `display` or `tv` at 14.5–15 pt fits the table.

## Ring states, complete list (for reference)

| Ring | State | Colour token | Light / dark hex | Form | vs ground, light / dark (dark `panel`) | 3:1 |
|---|---|---|---|---|---|---|
| Glyph ring | off | none | none | hidden | none | n/a |
| Glyph ring | connecting / reconnecting | `ring` | `#2C6E86` / `#7FB4C4` | dashed 2.6/2.6, pulsing, 1.6 pt | 5.47 / 8.69 (7.89) | yes |
| Glyph ring | connected | `rim` | `#66717A` / `#6B767D` | solid 1.6 | 4.78 / 4.25 (3.86) | yes |
| Glyph ring | failed | `failure` | `#B03327` / `#D9564A` | solid 1.8 | 6.01 / 5.07 (4.60) | yes |
| Main Audio ring | connected, armed | `gold` (Full / Subtle) | `#E8B84B` / `#E8B84B`; Subtle `#8F7B4A` / `#B99B53` | solid 2.0 | **1.77** / 10.73; Subtle 3.95 / 7.42 | light Full **no** (documented exception) |
| Main Audio ring | connected, not armed | `ember` | `#7A5E2A` / `#8A6A2F`; Subtle `#71613B` / `#6D5B34` | solid 2.0 | 5.82 / 3.94; Subtle 5.79 / 3.01 (**2.73**) | Subtle dark on `panel` no (documented) |
| Main Audio ring | resting | spine colour, as above | as above | solid 1.6 | as above | as above |
| Main Audio ring | connecting / failed | `ring` / `failure` | as the glyph ring | as the glyph ring | as the glyph ring | yes |
| Rail node | member | spine colour fill and rim (`socket` fill when dimmed) | as above | filled 15 pt | as above | as above |
| Rail node | connecting | `gold` | `#E8B84B` | dashed, hollow, 1.5 | **1.77** / 10.73 | light Full **no** (P1-3) |
| Rail node | failed | `failure` | as above | solid, hollow, 1.8 | 6.01 / 5.07 | yes |
| Rail node | not a member | `ember` | as above | hollow 11 pt, 1.5 | 5.82 / 3.94 | yes (Subtle dark 2.73 on `panel`) |
| Status dot | armed | `gold`, border `underPageBackground` | see P1-5 | 8 pt disc | see P1-5 | see P1-5 |
| Status dot | not armed | `socket`, border `underPageBackground` | `#DFE1E4` / `#2A2E33` | 8 pt disc | **1.26 / 1.45** | **no**, and the code exempts it on purpose (`Tokens.swift:794-797`) |

Not used on the Mixer rows: green, magenta and every `permission*` colour. The gold-first rule holds everywhere except the steel-blue connecting ring (P1-2).
