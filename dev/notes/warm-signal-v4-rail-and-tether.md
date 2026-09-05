# Warm Signal v4 — Left-Spine Rail + Derived Tether

**Status: LOCKED by the owner, 2026-07-22.** Supersedes the v3 bus geometry (right-column
membership bus) and the v3 under-fader meter. Everything else in `warm-signal-v3.md`
still holds unless contradicted here. This doc is the single source of truth for the
popover re-architecture; build to it exactly.

Reference mocks (interactive, warm palette): rail study v2, icon-legibility ramp,
derived-tether swatches — authored in the design session, values below are canonical.

---

## Call 1 — Spine & row anatomy (LOCKED)

**The bus rail moves to the LEFT gutter** (leading edge, rail centreline ≈ 18–20pt from
the popover's left content edge). It becomes the panel's structural spine, not a trailing
control column. The old right-column membership bus is retired; the underlying membership
control (the invisible `NSButton` checkbox + its AX + hit-testing) stays exactly as-is —
only the *drawing* moves to the left gutter. Clicks on a left-gutter node still toggle the
same checkbox.

**Rail extent = Main Audio (top anchor) → the LOWEST SELECTED node (bottom terminus).**
Not full height.
- Unselected nodes *within* that span get the wire-hop detour — a **wider, rounder bypass
  arc** than v3 (give skipped nodes generous berth; `busDetourBulge` grows).
- **Larger clearance radius around every node** (owner's call, all sides): widen the left gutter so a
  node never crowds the icon tile to its right, and give each node generous vertical clearance
  along the rail (larger unstroked gap where the rail meets the node + a touch more node-to-node
  rhythm) so the whole spine reads calm/airy, not cramped. Drive from named `PopoverColumnGrid`
  constants (`busNodeClearance` / gutter width / node vertical inset). Must not break column
  alignment — reflow leading columns consistently.
- Nodes *below* the lowest selected node are **bare hollow clickable nodes with no rail
  through them**. Selecting one extends the spine down to reach it.
- The rail's length is information: it reads as "how far down the mix reaches."

**The rail hooks UP into the Main Audio row's meter.** The vertical rail turns and
terminates into Main Audio's level indicator — the selected rooms visibly feed the main
output's level.

**The pipe is one continuous line down a CLEAR left gutter — achieved by moving the titles,
not by threading the rail.** The rail is a single straight vertical element from the Main
Audio anchor to the lowest selected node. To keep its lane clear, the **section header
labels left-align to the DEVICE ICON column** — `SYSTEM AUDIO`, `OUTPUT DEVICES`,
`APP EXCEPTIONS` each start at the same x as the device icon tiles below them, so no title
ever sits in the gutter/rail lane. The pipe is uninterrupted because nothing occupies its
lane (not because it detours around the titles). Where the rail crosses a hairline divider
it renders on top so the line stays unbroken (or start the divider at the icon column too,
leaving the gutter clear). Net: a clean left gutter owned entirely by one continuous rail,
with section titles + device icons sharing a left edge to its right.

**Current-device floor.** Deselecting the last remaining device **auto-reselects the
current device**. There is never a zero-selected state; the spine always exists. (Resolves
the old deselect-to-zero question — no empty "nothing routed" state.)

**Meter relocated: under the NAME, not under the fader.** A short live-level bar (~74pt
wide, 3pt tall) sits directly beneath the device name, left-aligned, in the identity
cluster. It stays gold/ember (it *is* the live signal). It is visually distinct from the
fader by column, width, and the absence of a thumb — killing the v3 "two gold bars, which
is which?" confusion. Row vertical order: **name / meter / sublabel.** Only shown on armed,
unmuted, connected rows.

**Muted-unconnected rule.** A device that is **connecting/pending** or **unavailable/failed**
renders its controls **muted** (desaturated + lower-contrast fader/meter/readout) to signal
"not adjustable right now." A fully connected member is full-gold and adjustable. This is
the *same* visual language as the energize pending state (Call 3) and the connecting halo
ring — one rule, reused.

**Naming + switcher + columns.**
- Section header: **`SYSTEM AUDIO`** (was "System" / "Main Audio").
- The row item title: **`Main Audio`** (was "Audio Out").
- The output dropdown's column header: **`Output`**.
- The **Selected-Devices / group switcher** stays on the Main Audio row (the dropdown that
  picks `Selected Devices` or a saved group).
- **Column alignment is mandatory:** the VOLUME (fader) and the trailing OUTPUT/REDIRECT
  dropdown columns line up across all three sections (System Audio, Output Devices, App
  Exceptions). Device rows leave the trailing dropdown column empty but reserve its width so
  faders/readouts stay on the same x everywhere. Anchor to the trailing edge as
  `PopoverColumnGrid` already does.

---

## Call 2 — Derived-colour name tether (LOCKED)

App→device redirects are shown by **tinting the app NAME (text)** in a link colour. NOT a
separate colour block (no context), NOT an icon echo (icons degrade to mud at ~13pt —
Safari/Firefox especially; verified on the legibility ramp).

**The link colour is DERIVED from the app's own icon:**
1. Extract the **dominant hue** from the app icon bitmap (`NSRunningApplication.icon` /
   `NSWorkspace` icon → sample pixels → most-saturated dominant hue). Computed **once per
   app bundle id, deterministic**, cached.
2. **Warm-adapt** it: desaturate into the warm range and **steer it off the three reserved
   bands** so it can never be confused with a state colour:
   - `gold` (signal) — steer oranges/yellows away (Firefox orange → terracotta).
   - `failure` red — steer pure reds toward rose/pink (YouTube red → dusty rose).
   - `caution` amber — same as gold band.
   - Blue is foreign to the warm palette → safe with light desaturation.
3. **No clear dominant hue** (multi-colour marks like Chrome, or greyscale icons): take the
   most-saturated region; if none, fall back to a neutral link tone.

Canonical warm-adapted examples (from the swatch mock — the algorithm should land near
these): Spotify `#6FA98C`, YouTube `#C56B72`, Firefox `#C08457`, Safari `#5E93A8`,
Apple Music `#C67D97`, Chrome `#7089AE`.

**Both endpoints wear the tint:** the app's name in the App Exceptions row AND the app's
name in the *target device's* sublabel. That shared tint is the tether — no line crosses
the panel.

**Always name + colour, never colour alone.** The word is always present (colourblind-safe,
legible at any size); colour is the scanning accelerant.
- Inter-app collision (two apps share a brand hue — YouTube/Music both rose, Safari/Chrome
  both blue): the name disambiguates, and among the *simultaneously-active* redirects, nudge
  any near-duplicate hues apart.

**Timing (reuses the muted→bright language):** the tinted link appears **muted the instant
the redirect is set** (relationship is real immediately — never gated on connection), and
**brightens when the target device connects** (the "they resolve together" confirmation
beat). On connection failure it **stays muted** (honest: configured, not yet flowing).

---

## Call 3 — Energize on source switch (LOCKED)

Switching the Main Audio source (Selected Devices ↔ a group, or group ↔ group) changes the
whole selection at once and plays a two-layer sequence:

1. **Instant reconfigure.** The rail immediately redraws to the new node set and extent in
   the dim **ember pending** tone; newly-added nodes render **hollow-pending (dashed).** This
   is the "refresh" beat — the whole spine drops to pending the moment the source changes.
2. **Per-device connect.** Each device establishing its session shows its **dashed connecting
   halo ring** (the existing S1 `Device.connectionState` machine — unchanged).
3. **Energize.** As each device connects, **its node fills solid gold and its rail segment
   brightens ember→gold**, top-to-bottom. Full solid-gold spine when all are connected.
4. **Failure.** A device that fails to connect keeps its node in the **failure-red** form and
   its rail segment stays dim — you see exactly which room didn't make it.

**Reduce Motion:** no travelling sweep — nodes flip pending→final as each resolves, no
animation. The state ladder still reads (form-encoded), just static.

---

## Build notes
- Drawing/geometry + one new colour-extraction utility; no change to the membership,
  connection, mute, or routing *model* — the invisible controls and their AX/behaviour stay.
- Determinism: all new drawing must settle model layers so `cacheDisplay` snapshots stay
  byte-identical (follow the `HaloRingView`/`WarmFaderCell` precedent). The energize
  animation and the tether brighten animate over settled model layers.
- New snapshot fixtures: left-rail spine at varying selection depths; a redirect tether
  (muted + connected); the muted-unconnected state; the energize mid-sequence + failure.
