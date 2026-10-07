# Scenes tab, direction F2: F with the app's own membership control, and colour

Delta on `../direction-f/brief.md`, 2026-10-07. Everything F says stands unless a line below replaces it. `changes.md` beside this file gives the reasoning.

## Delight thesis

A scene's page should feel like the Mixer's own instrument with the sound taken out: the same gold disc that says "in" on the Mixer says "in" here, and a change you make is visibly known everywhere at once.

## 3. Selected direction, replaced lines

- **Membership rows (page, item 3).** One `MembershipRowView` per speaker in its `.editor` form, 32 pt: the `MembershipBusView` node over the real `NSButton` wearing `InvisibleSwitchCell`, the glyph, the name. No `BusRailOverlayView` is mounted, so the node stands alone with no line and no detour arc. Node states: in the scene, the filled 15 pt `gold` disc (1 pt `ember` edge in light); not in the scene, the hollow 11 pt ring in `railDormant`; in the scene and unreachable, the dimmed member node (`socket` fill, 3 pt `gold` rim) with "Unavailable" ("Not connected" for Bluetooth) at the trailing edge, `labelCool` name and `labelCool2` glyph. The whole row toggles; the node is the control. The last member refuses with today's tooltip.
- **Sidebar rows.** Each `IconLabelCellView` row's glyph carries `GroupIdentityGlowView` behind it, mounted small as the Main Audio row mounts it behind its 26 pt icon. The selection pill and the glyph ink are unchanged.
- **Empty page.** The "Add scene…" row's button is the gold `ProminentButton`. The second row keeps its stock caption and no button.

## 6. Interaction, replaced and added lines

- Hover on a membership row: the 0.10 `engagedChrome` wash and the node's existing grow (`busNodeHoverGrowDuration`, 0.12 s).
- Toggle: the ring fills from its centre to the disc, or drains back, over `Tokens.Motion.collapseRevealDuration` (0.15 s) on the fold clock. Reduce Motion lands the end state at once.
- **The one touch.** On a toggle the page caption's count and the selected sidebar row's count tick together, digits rolling over the same 0.15 s. Under Reduce Motion both swap with no roll. VoiceOver hears the checkbox's own state change; the counts are not announced.
- Keyboard: Space on a focused row toggles its node, exactly as the editor's rows do today; Tab order is sidebar, well, field, rows, Delete.

## 7. Constraints, added lines

- **Reused:** `MembershipRowView` (`.editor` host), `MembershipBusView`, `InvisibleSwitchCell`, `GroupIdentityGlowView` (two mounts), `ProminentButton`, `FoldAnimator` and `Tokens.Motion.collapseRevealDuration`, `PopoverColumnGrid.busNodeHoverGrowDuration`. Nothing new is drawn; `MembershipBusView` gains no new node kind.
- **Builder note:** `MembershipRowView`'s doc records that the `.editor` host exists for the rail and the `.systemSheet` host for the stock sheet; F2 uses `.editor` on the page without a rail overlay, which the row already supports (the overlay is a pane-level sibling, not part of the row). The sheet keeps `.systemSheet`: `ember` measures 2.3–2.5:1 on the sheet's white, which is why the node never went there.
- **Contrast:** `gold` disc on `raised` dark 7.3:1 as a shape; light disc relies on its `ember` edge, as the Mixer's does; `railDormant` ring 3.47:1 on dark `panel`, about 4.9:1 light.
- **Tests that change:** `DeviceRowMutedStateTests`' file list is unaffected (no new consumer of a fenced hue); `MembershipRailTests` loses the editor's rail cases; a new test pins that a toggle moves both counts in one update.

**Open decisions, for the owner:**
1. Whether the sidebar glyph's glow is wanted at that size, or only behind the header well (drawn: both).
2. Whether the empty page's gold button is welcome, or the stock button F drew.
