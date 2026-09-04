# DESIGN.md delta — Track 4, item 4B (Equalizer card recess)

Do not edit DESIGN.md directly; this is the replacement text for the coordinator
to apply centrally.

## Section: "Elevation & Depth" (root `DESIGN.md`)

Replace the paragraph that currently reads:

> Mostly flat, matching iOS: the dark ground ladder (canvas → panel → raised)
> and, in light, edge weight alone carry depth. `Tokens.Color.shadow` (an
> alias of `NSColor.black`) has two real consumers, both control cells rather
> than the popover's card chrome: `AlignmentPlateCell` (the wizard's answer-
> plate lip shading, rim shadow blend, and chip shadow fill) and
> `WarmFaderCell` (the fader trough's inset shade). The popover's own
> `ControlPanelBackingView` (a custom-drawn bubble-plus-beak shape, because
> `NSPanel` has no arrow) is a separate, named custom-drawn exception that
> does not itself draw a shadow.

with:

> Mostly flat, matching iOS: the dark ground ladder (canvas → panel → raised)
> and, in light, edge weight alone carry depth. `Tokens.Color.shadow` (an
> alias of `NSColor.black`) has three real consumers: `AlignmentPlateCell`
> (the wizard's answer-plate lip shading, rim shadow blend, and chip shadow
> fill), `WarmFaderCell` (the fader trough's inset shade), and —
> since 2026-09-04 — `GroupedSectionView`'s new `.well` style (the device
> detail page's Equalizer recess): a 1 pt band at 0.18 alpha, clipped inside
> the shape's top edge, the same flat recipe the other two already draw. The
> device detail page's Equalizer switched from `.card` to `.well` because
> `.card`'s `raised` fill is the flat `#FAFAFB` ground in light — identical
> to the `canvas`/`panel` it sits on — leaving a 1 pt outline around nothing;
> `well` (`#E9EAEC` light / `#050507` dark) is the one neutral that stays
> visibly recessed on the flat chassis. Measured separation: light `well` on
> the flat ground is 1.154:1; dark `well` on `panel` is 1.134:1 (`Tokens.swift`'s
> own doc comment on `well` carries both figures). The popover's own
> `ControlPanelBackingView` (a custom-drawn bubble-plus-beak shape, because
> `NSPanel` has no arrow) is a separate, named custom-drawn exception that
> does not itself draw a shadow.

### Why

`DeviceDetailViewController.swift:83` built `eqWell` as a `GroupedSectionView`
and never set its style, so it stayed the default `.card`. In light mode
`.card`'s `raised` fill resolves to the same flat `#FAFAFB` as the pane's own
`canvas`/`panel` ground, so the Equalizer card was a 1 pt `containerEdge`
outline around nothing. `GroupedSectionView` gained a fourth `Style` case,
`.well`, which fills with `Tokens.Color.well` instead of `raised`, keeps the
same `containerEdge` stroke and panel radius as `.card`, and adds a flat,
clipped inset-shade band along the visual top edge — the same recipe already
shipping in `WarmFaderCell.swift:87-95` (the fader trough's inset shade) and
`AlignmentPlateCell.swift:23-39`/`:184-198` (the wizard plate's bevel lips):
a 1 pt rect filled at `Tokens.Color.shadow` alpha 0.18, clipped to the
shape's own path, no blur, no `NSShadow`. Only `DeviceDetailViewController`'s
`eqWell` was switched to `.well` — `MainOutDetailViewController`'s own
`eqWell` (the Main Audio page) still defaults to `.card` and carries the
identical defect; that file is outside this track's scope and is called out
separately in the track report.

Measured, independently recomputed from the WCAG relative-luminance formula
against the hex values in `Tokens.swift`:
- light `well` (`#E9EAEC`) vs the flat `canvas`/`panel`/`raised` ground
  (`#FAFAFB`): **1.154:1**
- dark `well` (`#050507`) vs `panel` (`#15171A`): **1.134:1**

Both match the figures already recorded in `Tokens.swift`'s own doc comment on
`well`.
