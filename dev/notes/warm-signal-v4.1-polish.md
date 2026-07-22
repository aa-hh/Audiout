# Warm Signal v4.1 — Polish batch + tether wiring + energize

**Status: LOCKED by Alec in the 2026-07-22 design session.** Extends
`warm-signal-v4-rail-and-tether.md` (Calls 1–3). Call 1 is already implemented + committed
(2c3c836): left-gutter continuous rail, spine-to-lowest-selected with detours + node
clearance, current-device floor, meter-under-name, muted-unconnected controls, SYSTEM
AUDIO/Main Audio/Output labels, section titles at the icon column, and the STATIC node
vocabulary (member/nonMember/blocked/connecting/pending/failed/origin). `AppTetherColor`
(bitmap dominant-hue → warm-adapted, off the reserved gold/failure/amber bands) also exists
and is unit-tested. This doc is the remaining locked scope.

---

## 1. Master strip (the Main Audio meter)
The Main Audio row's meter is the terminus the left rail plugs into. Locked treatment:
- **Same length as the device meters (~74pt)** — NOT full-width, NOT spanning to the fader.
- **Thicker (~6pt vs the devices' 3pt)** — thickness is the ONLY signifier of "master bus."
- **Seated below the icon, leading edge at the rail-gutter x**, so the rail rises up the
  gutter and flows straight into its left end (below the icon — never crossing the icon or the
  name). A small filled junction dot sits at the turn.
- Reads as a heavier-gauge sibling of the device meters, not a different UI species.

## 2. Halo breathing room
The connection halo rings currently hug the icon tiles. Enlarge them so there is a clear
~3–4pt visual gap between the icon tile edge and the ring stroke on all sides. Ring remains
connection-state-only (dashed=connecting, solid=connected, red=failed) — no other meaning.

## 3. FEED column (trailing third column on device rows)
Fills the empty trailing column (header `FEED`). **Text, not chips** (pills would blow the
gold-only budget, break the mono-readout alignment, and double-encode the tether tint).

**It is a MULTI-SOURCE COMPOSITE — never collapse to one reason.** A device fed by the main
mix AND a redirected app must show BOTH. Format = source segments joined by " · ":
- **Main-mix source** (neutral secondary text, the word carries the reason): **"System"** when
  the device is manually in the mix; the **group name** ("Downstairs") when the mix target is a
  group. This is how manual-vs-group is distinguished — no extra glyph needed.
- **App redirect(s)** — one **tether-tinted** app name per redirect (via `AppTetherColor`;
  Music sage, Safari teal…), appended.
- Examples: `System · Music` (manual + app), `Downstairs · Music` (group + app), `Safari`
  (app-only, not in mix), `System · Music · Safari` (mix + two apps).
- Neutral segment = "part of the main audio"; tinted segment = "a specific app" — the tints do
  the visual chunking chips would, without pills.

**Precedence / overrides (state, not feed):**
- **Error overrides the feed** with failure-red words: "Couldn't connect" / "Unavailable"
  (a failed device has no active feed — this hides nothing real; pairs with the red ring + the
  existing diagnosis panel).
- **Connecting / reconnecting / buffering are NOT shown here** — the halo ring owns transient
  connection state, and the muted-unconnected rule greys the whole row (incl. its feed text)
  while connecting. Duplicating it here would be noise.
- **Muted is NOT shown here** — it lives at the control (mute pill + the MUTED sublabel token).

**Attributes/flags:** at most ONE small **SF Mono uppercase micro-tag** as a prefix, monochrome
(never colored/filled), and only for a true exception — e.g. `AP1` (AP2 is default, never
badged). Mac-output and group membership are already carried elsewhere (subsection label / rail
/ Groups window) — do not badge them here.

**Overflow:** if the composite exceeds the column, cap visible segments and show "+N"; the rest
on tap/hover (progressive disclosure) — never silent truncation.

**Consequence:** feed text moves OUT of the name-sublabel INTO this column. The sublabel then
carries only state words (MUTED, etc.). Right-aligned, baseline aligned with the mono % readout.
Column color budget: neutral tones + tether tints (app names) + failure-red (errors) only.

## 4. Larger selected nodes
Filled member nodes on the rail render visibly larger (~13pt) than hollow unselected nodes
(~9–10pt) — selection reinforced by size AND fill, so "this is selected, that's why it feeds
up the rail" reads instantly.

## 5. Fader knob centering
`WarmFaderCell`'s thumb currently sits low on the track — a real drawing bug. Fix: thumb
vertically centered on the 4pt track across all rows (device, main, app).

## 6. No tint on rings or meters (guard)
Tether colour lives ONLY on FEED/redirect app-name text. The halo ring stays connection-only;
every meter (device + master) stays gold/ember only. Assert no tether colour reaches a ring or
meter (a mock earlier tinted them — must never ship).

## 7. Tether wiring (Call 2, now landing on the FEED column)
Wire `AppTetherColor` into the live rows: tint the app-name segments in the FEED column AND the
App Exceptions redirect entries (the redirect dropdown keeps its small colour chip; add a
matching chip/tint so the app↔device association reads at both ends). Compute once per bundle-id,
cached; both endpoints share the tint.

## 8. Muted → brighten on connect (device wiring phase)
When a device is connecting, its whole row sits **muted** (the muted-unconnected treatment from
Call 1 — desaturated controls, muted feed text). On successful connect it **brightens** to full
gold/normal. On failure it stays muted and the FEED shows the red error. This is the per-device
counterpart of the energize beat.

## 9. Energize (Call 3) + motion gating
Source switch (Selected Devices ↔ group) plays the energize sequence: rail drops to ember
pending + hollow-pending nodes, each device connects (dashed ring), nodes fill gold + rail
segment brightens top-to-bottom, failed devices stay red.
- **Reduce Motion REMOVES the animation entirely** — no travelling sweep, no muted→brighten
  fade. States snap to their resolved form instantly (form still encodes state: dashed/filled/
  red). This applies to BOTH the energize sweep AND the per-device brighten (item 8).

---

## Build constraints (all items)
- Drawing/geometry + wiring only; no change to the membership/connection/mute/routing MODEL.
- Hot files (serialize same-file tasks): `DeviceRowView`, `MainOutRowView`, `MembershipBusView`,
  `LevelMeterView`, `WarmFaderCell`, `PopoverColumnGrid`, `PopoverController`, `AppRowView`,
  `BusRailOverlayView` (all in AudiouterSharedUI / AudiouterPopoverUI).
- Determinism: settle model layers so `cacheDisplay` snapshots stay byte-identical; animations
  (energize, brighten) run over settled presentation layers (HaloRingView/WarmFaderCell
  precedent).
- Stock AppKit behaviour + keyboard + VoiceOver preserved; every new visual state ships a
  VoiceOver equivalent; new tests use IsolatedTestCase.
- New snapshot fixtures: master strip, FEED composite (multi-source + error + AP1 flag + overflow),
  larger-node selection depth, muted→bright, energize mid-sequence + Reduce-Motion static.
- Verify per task: swift build clean; `swift test --parallel` 0 failures; popover-harness green;
  goldens regenerated + double-run byte-identical. Commit nothing — the staff gate commits.
