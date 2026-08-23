# Device detail pane — information-architecture brief (2026-08-22)

Discovery for the Groups screen's device detail pane
(`AudiouterWindowUI/DeviceDetailViewController.swift`). Proposals only; nothing
built. Current render (with the Equalizer section, which the checked-in golden
predates): hero box → Status/On the network/Volume/Kind box → In groups box →
Equalizer box → hint line. Four identical unlabeled `GroupedSectionView`s; at
the default 528 pt height the Equalizer starts below the fold.

## What the page is for

It is the speaker's **inspector** (HIG: "displays the details of the currently
selected item"; a split-view pane is a sanctioned host). Configuration-only:
the user can change the icon and the EQ, nothing else. Everything else is
context.

## Evidence that decides the shape

1. **Identity → primary control → facts last.** Every first-party and peer
   device page orders this way: iOS 27 AirPods (live controls top, firmware
   under "About" at the bottom), System Settings › Displays (hero → Resolution/
   Brightness → "Advanced…"), HomePod in Home (tone control third, Wi‑Fi/
   access last), Sonos room settings (EQ first under "Sound"; serial/network
   under "Products"), Logic channel strip (EQ is the first thing on the strip).
2. **Equal boxes = no hierarchy.** NN/g: "make the most important element
   biggest… limit big elements to 2"; pages where everything is equal size and
   colour are clutter. HIG Layout: "content and controls remain clearly
   distinct." Today the facts table and the instrument wear the same box.
3. **Headings are the page's mini-IA.** NN/g layer-cake: users scan headings
   and skip; an unlabeled page has no mini-IA — the direct cause of "doesn't
   say what it's for." HIG Boxes: title a box when it "clarifies the
   relationship." Labels name a *purpose*, never a data type.
4. **Labels are a last resort for facts** (Refactoring UI). "Status: Connected"
   ×4 rows gives every fact equal weight; fold them into a status line
   ("Connected · Sonos · AirPlay 2").
5. **Don't collapse the only control** on a desktop pane (NN/g accordions;
   Baymard: expanded sections match desktop expectations). The existing
   "Advanced" fold is the right *one* disclosure (HIG: no more than one).
6. **No hint text.** Microsoft/GOV.UK: don't teach obvious features; fix the
   label instead. The window footer ("Set up groups here — switch to the
   Mixer to play") already carries the division of labour.
7. **Relationships are navigation** (OOUX: nested objects are links). "In
   groups" should take you to the group, not just name it.

## Codebase facts that bound the proposals

- Section titles are allowed and precedented: the group editor's bare
  "Speakers" label above its box; `GroupsPaneLayout.labelToSectionGap` exists
  for exactly this. `GroupedSectionView` has no title API — a title is a
  sibling label above the box.
- Header geometry (64 pt icon well + heading, 96 pt band) is parity-locked to
  the group editor by test; switching sidebar selection must not jump the
  header. Every proposal keeps the hero as is.
- `EQEditorView` draws no surface and has no nameplate; the design board's
  "EQ — OFFICE" plate was the popover-drawer form and was dropped. Reset lives
  inside the editor on the Loudness row.
- `Device` carries only: name, kind, isAvailable, volume, isMuted,
  connectionState, supportsAirPlay2, eq, eqBypassReason. No model/IP/latency —
  "speaker details" cannot grow.
- The sidebar already shows icon, name, and availability (as dimming).
- Height: 528 pt content; hero band 96 + EQ collapsed ≈ 230 + gaps ≈ 390.
  Roughly 100 pt left for anything else before scrolling.
- Tests to touch on any redesign: `DeviceDetailViewTests` (38 tests: exact
  label strings, hint string, `test_sectionCount == 4`, hint pin order),
  `GroupsHeaderParityTests` (section count, frames). Main Audio page
  (`MainOutDetailViewController`) should follow the same template.

## Proposals

### P1 — Reorder and title (smallest change)

```
┌ [icon] Sonos Move ─────────────────┐
Equalizer
┌ curve / Bass / Treble / Balance … ─┐
Groups
┌ Downstairs                         ┐
Details
┌ Status · On the network · Kind     ┐
```
Same four boxes; EQ moves to second; three titles; hint deleted.
Fixes order and mini-IA. Does **not** fix hierarchy — four equal boxes
remain, and the EQ still reads as "another box." Volume row: drop.

### P2 — Hero carries the facts, EQ is the page (recommended)

```
┌ [icon] Sonos Move                  ┐
│        Connected · Sonos · AirPlay 2│   ← secondary label, one line
│        In Downstairs                │   ← link-styled; click → group editor
└────────────────────────────────────┘
Equalizer                       Reset     ← title + Reset on the title line
┌ curve                               ┐
│ Bass / Treble / Balance / Loudness  │
│ ▸ Advanced                          │
└────────────────────────────────────┘
```
Two sections. Facts become a status subtitle under the name (Apple Displays
pattern: facts live only in the hero). Groups become a second subtitle line
of clickable names. The instrument is the only box below the hero, so content
vs control is distinct by construction. Fits the height budget collapsed.
Drops: Volume (live elsewhere; read-only here misleads), "On the network"
(already the sidebar dimming; "Not connected" covers it), the hint.
Risk: long group lists truncate the second line → "In 3 groups" fallback.

### P3 — Settings page: Equalizer / Groups / About

```
┌ [icon] Sonos Move ─────────────────┐
Equalizer
┌ instrument                          ┐
Groups
┌ ▣ Downstairs                     › ┐   ← rows with group icon, navigable
│ ▣ Kitchen                        › │
About
┌ Status         Connected           ┐
│ Kind           Sonos               │
│ AirPlay        AirPlay 2           │
```
Closest to Sonos / iOS 27 AirPods. Clearest mini-IA, most future room
(an "About" can take a sync-trim or AirPlay-1 warning later). Always scrolls
at default height. Most new layout and the most test churn.

## Cross-cutting decisions (Alec's call)

- **Volume read-only row:** drop (all proposals). It is the one fact that looks
  like it should be adjustable on a page that deliberately can't.
- **Section-title voice:** plain "Equalizer" as a sibling label (matches
  "Speakers"), or a console nameplate inside the box ("EQ — SONOS MOVE", the
  design-board form). Voice rules allow console flavour on chrome; the
  sibling label is the cheaper and already-precedented form.
- **Groups as links:** a small scope add (sidebar select already exists) that
  turns an inert fact into navigation. Recommended in P2/P3.
- **AirPlay 1 vs 2:** `supportsAirPlay2` is the one unshown fact that matters
  (no perfect sync on AP1). Surface it in the status line / About.
- **Main Audio page:** same template (hero → Equalizer → footnote) so the two
  detail panes stay interchangeable behind one sidebar.
- **This Mac:** EQ hidden → hero + status line only (P2) or hero + About (P3).

## Sources (selection)

HIG Layout / Boxes / Disclosure controls / Panels / Lists and tables;
NN/g visual hierarchy, layer-cake scanning, progressive disclosure, accordions
on desktop, scrolling and attention; Refactoring UI "Labels are a last
resort"; Baymard expanded vs collapsed sections; Apple support: Displays
settings, HomePod settings, Use AirPods with Mac; MacRumors iOS 27 AirPods
settings; Sonos room-settings intro; Rogue Amoeba SoundSource manual; Logic
channel-strip docs; 9to5Google Home device-page redesigns; OOUX resources;
Microsoft instructional UI; GOV.UK hint text; Android settings guidelines.
