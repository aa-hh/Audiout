# Device detail pane — framework + colour proposal (2026-08-22)

Planning only. Builds on the IA brief (P3 chosen). Two questions: a slot
model that survives new features, and why the colours don't match the app.

## Part 1 — The framework

### Recommendation: four fixed slots, one rule per slot

```
1  Identity    icon well + name. Who this is. Parity-locked, never grows.
2  Controls    one titled box per instrument. Things the user CHANGES here.
              Today: "Equalizer". Rule: a box is named for its one
              instrument; a new instrument gets its own titled box below it.
3  Groups      rows, one per saved group, each a link to that group's editor.
              Membership is read here, edited in the group.
4  About       two-column fact rows ("Status   Connected"). Things the user
              can only KNOW. Always last, always scrolls if it must.
```

"Equalizer", not "Sound". The slot that scales is *Controls*, not the box:
a per-device delay trim is a second instrument → its own box ("Timing") under
Equalizer, exactly as the Bluetooth sync drawer is a separate instrument in
the Mixer. A loudness-only toggle is a tone control → a row inside the
Equalizer box (Loudness already lives there). "Sound" would have to absorb
both and would stop saying what the box does.

### Placement rule for any new feature

1. Does the user change it here? → Controls. Same instrument as an existing
   box (tone, curve, reset) → a row inside it. Different instrument (timing,
   limiter, naming) → a new titled box directly below the last control box.
2. Is it a fact about the speaker? → one About row. Fold, don't add: one row
   per *question* ("Status"), not per model field. `supportsAirPlay2` →
   "AirPlay   AirPlay 2" / "AirPlay 1 — sync not exact".
3. Is it a relationship to another object? → a clickable row in Groups
   (or a new rows-slot between Controls and About, titled for the object).
4. Is it playback — volume, mute, route, Playing now? → not here. Mixer.
5. Is it a warning the user must act on? → a plain-speech caption directly
   under the box it concerns (the EQ bypass line already does this).
   Never a fifth slot, never a banner at the top.

A box earns a title by holding a different instrument, never by being long.

### Budget rules (528 pt content height)

- Column top inset 20 + hero 96 + gap 20 + label 22 + Equalizer collapsed
  ≈ 242 = ~400 pt. The window footer caption takes the rest. **Above the
  fold = Identity + the primary control, collapsed.** That is the promise;
  Groups and About scroll at default height and that is correct for an
  inspector (it already scrolls; "Advanced" already exceeds it).
- One disclosure per page (HIG): "Advanced" owns it. A second control box
  that needs more than ~1/3 of the pane expanded does not get a fold — it
  opens a popover/sheet from a button, the way the icon picker does.
- Off the page: anything rule 4 catches, or anything needing a second
  disclosure. Groups and About never collapse.
- Long lists: every group row shown at 28 pt (the sidebar's pitch). Six
  groups cost 168 pt and scroll. No "and N more".

### Labelling rules

- Slot titles are **sibling labels above the box**: title case, single noun,
  `Tokens.Color.secondaryLabel`, the editor's "Speakers" precedent,
  `labelToSectionGap` (6) below, `sectionGap` (20) above. Never uppercase,
  never inside the box. Identity has no label.
- Facts are two-column rows: caption `secondaryLabel` left, value `label`
  right. Status folds `connectionState` + `isAvailable` into one value:
  "Connected" / "Ready" / "Not on the network". "On the network" row goes.
- Voice: titles are chrome (bare noun); values and empty states are plain
  speech.
- Empty states: Groups → one quiet row "Not in any group". This Mac → the
  Equalizer slot is **omitted**, not shown empty (an unusable control is a
  lie; a missing fact is information). About never empties.
- Captions: an optional one-line `secondaryLabel` sentence under a box, about
  that box only (Settings precedent).

### The sibling pages

- **Main Audio** = slots 3 and 4 empty, so they vanish: Identity
  (non-editable) → "Equalizer" box → its caption "Applies to audio sent to
  speakers." The floating footnote becomes the box's caption.
- **Group editor** already conforms: Identity → "Speakers" → action band.
- All three: the one box on the page is the page's instrument.

### Squint test on P3, and rhythm

Squinted: lit scope (primary) → icon + name (secondary) → three quiet
labels → rows. Today: four equal slabs; Part 2 fixes that. Rhythm: 6 / 20 /
22 is enough — 6 binds a label to its box, 20 separates blocks; the detail
pane loses its action band with the hint, so 22 stays the editor's. No new
step: 22-vs-20 is already the scale's weakest interval.

```
   [icon]  Sonos Move                      ← Identity, bare, no box

   Equalizer
   ┌────────────────────────────────────┐  ← the ONE box: raised + hairline
   │ ▐  scope  (near-black screen)     ▌ │
   │  20 Hz      +12 dB · −12 dB   20 kHz│
   │  Bass      ───────●───────    0 dB  │
   │  Treble    ───────●───────    0 dB  │
   │  Balance   L ─────●───── R  Center  │
   │  Loudness  ☐                 Reset  │
   │  ▸ Advanced                         │
   └────────────────────────────────────┘

   Groups
    ▣ Downstairs                        ›
   ─────────────────────────────────────   ← inset hairline, no box
    ▣ Kitchen                           ›

   About
    Status                     Connected
   ─────────────────────────────────────
    Kind                           Sonos
   ─────────────────────────────────────
    AirPlay                    AirPlay 2
```

## Part 2 — Colour

### Recommendation

Not a hue problem. `Tokens.Color.well` — the app's word for *a recess a
control sits in* — fills every container on the page. Nowhere else does
content sit in a well: Mixer rows sit on `panel` with one `hairline` between
sections; Settings rows sit on `panel` with `separator` rules; `well` is only
the fader trough and the readout chip. Four wells punched into the panel is
why the page reads as another product. Fix: one housing for the one
instrument, everything else on bare panel.

### What the pane uses today (Tokens.swift)

| Role | Dark | Light |
|---|---|---|
| Canvas (`WarmPanelView` → `panel`) | `#1D1915` | `#FBFBF9` |
| Every box fill (`GroupedSectionView` → `well`) | `#100D0A` (1.109:1 vs panel — darker than canvas) | `#E2DFD3` (1.289:1 — a beige tile) |
| Box border + dividers (`hairline`) | `#3A332B` | `#D0CDC3` |
| Icon well (`DeviceIconWellView` → `raised`) | `#241F1A` | `#F2F0EA` |
| Scope ground (`scopeGround`, fixed) | `#14110C` | `#14110C` |
| Text | stock `label` / `secondaryLabel` / `tertiaryLabel`, frozen | same |

Mixer and Settings: canvas `panel`; no container fills; dividers only;
`well` for troughs and chips; same text tiers.

### Mismatches, checked

1. **Holes (dark) / tiles (light) — real.** Dark `well` sits *below*
   canvas; light `well` is the page's strongest fill step. Same code, two
   structures — the popover is flat in both.
2. **Bordered boxes vs borderless rows — real.** Only this page strokes
   containers.
3. **Scope loses its edge in dark — real.** `scopeGround` vs `well` is
   **1.029:1**: screen and housing merge; only the grid marks the edge. In
   light it sits at 14:1. The design board puts the scope on a *lifted* card.
4. **Black sidebar pill / white toolbar pill — not real.** Both are stock
   (`.sourceList`, real `NSToolbar`); the solid fills are the
   `window-snapshot` artefact DESIGN.md documents. Don't chase.
5. Text tiers, gold, icon well: already shared. Not the problem.

### Surface recipe (all existing tokens, no new token)

| Slot | Surface | Why |
|---|---|---|
| Identity | bare `panel`; icon well stays `raised` | same as the Mixer's Main Audio row; parity geometry untouched |
| Equalizer (and the editor's Speakers list) | `raised` fill + 1 pt `hairline` edge, 10 pt radius; scope keeps `scopeGround` | the one lifted card; hairline vs raised 1.31 dark / 1.40 light clears the 1.25 separator floor; scope vs raised 1.153 dark clears 1.10 |
| Groups | bare `panel`, inset `hairline` dividers, chevron `tertiaryLabel`, hover wash `engagedChrome` at `rowHoverWashAlpha` | Settings rows, Mixer hover |
| About | bare `panel`, inset `hairline` dividers | Settings rows |
| Captions | `secondaryLabel` | frozen text |
| Gold | inside the scope only (plus the sidebar's Playing now marker) | gold means signal |

Light then shares dark's structure: one faint warm card holding a black
screen, everything else white with dividers. Instruments on `raised` clear
3:1 (light gold 3.64, ember 3.76; dark 8.86 / 3.25). If `containerEdge`
(unmerged `claude/edge-weight-mac`) lands, it takes the card's outer edge.

### Alternatives

- **A — One housing (recommended):** above. Fixes hierarchy and colour at
  once; `GroupedSectionView` becomes the instrument card, rows get a
  divider-only list.
- **B — Keep boxes, swap the fill:** `GroupedSectionView` fills `raised`, not
  `well`. One line; kills the holes; keeps four equal boxes, so the scope
  still competes with the facts. A fair first step.

## Decisions for the owner

1. Hero loses its box on all three pages (A) — or keeps it (B)?
2. Groups and About as bare divider rows (A) vs kept in boxes (B)?
3. Label "Equalizer" (recommended) or "Sound"?
4. Status folds to one row ("Connected" / "Ready" / "Not on the network");
   "On the network" goes.
5. Main Audio's note becomes the Equalizer caption, not a page footnote.
6. Group rows at 28 pt compact height, all shown, no cap.

## Open risks

- Dark `raised` vs `panel` is 1.070:1, under the 1.10 surface floor — the
  card's separation rides on its `hairline` edge. `MembershipWellContrastTests`
  pins well-based floors and must be restated, not loosened.
- `window-snapshot` goldens cannot be regenerated; verification is live only.
- `GroupsWindowTextColorLockTests` reaches the editor's fill via
  `membershipWell`; keep the name.
- `DeviceDetailViewTests` (38) assert exact strings, `test_sectionCount == 4`
  and hint pins — all churn.
- Group-row click = `SidebarViewController.select(_:)`; needs a `test_` mirror.
- About always below the fold at default height — by design, but the owner may
  want Status visible; the fallback is a one-line status under the name.
