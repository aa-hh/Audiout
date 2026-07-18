# CC slider recreation — research note (T-U10, 2026-07-14)

Goal: rebuild `ControlCenterSlider` to match the REAL macOS Control Center
Display/Sound slider — a **full-height white capsule with an in-track glyph**,
not a thin bar with a protruding knob.

## Sources found

- **aditya101099/Big-Sur-Sliders** — SwiftUI recreation of the Big Sur CC slider.
  Source: `Big Sur Slider/BigSurSlider.swift`
  (github.com/aditya101099/Big-Sur-Sliders). This is the closest documented
  recreation; concrete construction extracted below.
- **orchetect/MacControlCenterUI** — SwiftUI DSL + controls mimicking CC menus
  (github.com/orchetect/MacControlCenterUI). Confirms the same capsule-with-glyph
  shape and MenuBarExtra integration, but ships as a package (no single-file spec
  to quote); used as corroboration, not for numbers.
- Apple `NSSlider` docs — confirm there is **no** public track-thickness / knob
  API, so a custom `NSSliderCell` overriding `barRect`/`knobRect`/`drawBar`/
  `drawKnob` is the documented path (which is what we already do).

## Concrete construction from Big-Sur-Sliders (verbatim intent)

- **Track = whole control**: one rounded rect spanning the full frame; height is
  the slider height (a *thick* capsule, not a 6pt bar). Corner radius `20`
  (i.e. effectively height/2 → a capsule) with a gray `0.5` stroke outline.
- **Unfilled**: gray at `0.5` opacity.
- **Filled**: **WHITE**, width = `percentage/100` of the track. NOT accent.
- **Knob**: white **circle sized `height × height`** (diameter == track height,
  flush — no vertical protrusion), `shadow(radius: 5)`. White fill + white knob
  read as ONE continuous white pill.
- **Leading glyph INSIDE the track**: SF Symbol, size `height − 7`, gray `0.5`,
  offset `x: 5` from the leading edge. Non-interactive, drawn above the fill.

## What I adopted vs the image spec

The Big-Sur-Sliders construction and ahh's image-analysis spec agree on every
structural point (full-height capsule, white fill, flush white knob == height,
in-track leading glyph, faint outline). Where they differ I took ahh's
screenshot spec as ground truth because it is macOS 14 Sonoma (the repo targets
Big Sur) and it carries the recessed-3D cue the repo omits:

| Property        | Repo (Big Sur)     | ahh's spec (Sonoma)      | Adopted                          |
|-----------------|--------------------|---------------------------|----------------------------------|
| Track height    | "slider height"    | ~24pt                     | **24pt** (intrinsic 22 → 24)     |
| Radius          | 20 (≈capsule)      | height/2                  | **height/2** (true capsule)      |
| Unfilled        | gray 0.5           | black ~8–12% (light)      | **semantic, ~10% black-equiv**   |
| Top inner shadow| (none)             | subtle recessed top edge  | **added** (the 3D cue)           |
| Outline         | gray 0.5 stroke    | black ~5%, ~1px           | **~5% black, hairline**          |
| Fill            | white              | WHITE (both modes)        | **white** (both modes)           |
| Knob            | height×height,     | == track height, flush,   | **diameter == height, flush,**   |
|                 | shadow r5          | drop y −0.5…−1 blur 2–4   | **shadow y −0.75 blur 3 ~22%**   |
|                 |                    | black 20–25%              |                                  |
| Leading glyph   | height−7, gray 0.5,| ~8–10pt secondary-grey    | **secondaryLabel, ~9pt inset,**  |
|                 | x:5                | inset                     | **glyph ~ height−9**             |

## Dark-mode white-fill contrast

CC's fill is white/near-white in BOTH appearances. On the (now semantic-material)
card the white pill could wash out against a light material, so contrast is
carried by (a) the **top inner shadow** (recessed cue), (b) the **hairline
outline** on the unfilled capsule, and (c) the **knob drop shadow**. In dark mode
the white reads trivially against the dark material; the unfilled portion uses a
white-alpha wash (lighter) instead of black-alpha so it stays visible. All colors
are semantic/dynamic except the deliberate white fill + white knob, which ARE
white in both modes per CC.
