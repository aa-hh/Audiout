# Warm Signal — screens follow-up (onboarding / groups / settings)

**Status: LOCKED by Alec 2026-07-22, sequenced AFTER the v4.1 popover build.** Captured from
the screen review so it isn't lost. These surfaces are file-disjoint from the popover spine.

## Onboarding / Setup
- **Bring back per-permission coloured icons** (the warm pass over-corrected them to neutral).
  Each permission (System Audio / Local Network / Remote Control / Speaker Sync) gets its own
  **distinct colour again — but WARM-HARMONIZED**: toned to sit on the warm canvas like Speaker
  Sync's gold, NOT the raw bright iOS systemBlue/Indigo/Purple. Colour + personality return while
  staying cohesive with the palette. Granted/enabled state still lights per the existing rule.
- Everything else on onboarding stays (copy, Speaker Sync naming, permission mechanics).
- (Separately still outstanding from earlier: the feature-intro reference page + contextual
  first-use hints — a distinct follow-up, not this batch.)

## Groups window
- **Raise content contrast significantly** — the warm-content-on-warm-pane is genuinely too low
  to read (independent of the headless snapshot's dim inactive-window tone). Increase separation
  between text, rows, and the pane.
- **Liquid Glass sidebar on macOS 26+** (the system liquid-glass sidebar material) with a graceful
  **solid warm fallback** on older systems.
- (Also still owed from earlier: member rows should adopt the v4 rail/node language — a
  groups-consistency pass. Can fold in here or stay separate.)

## Settings
- **Add tabs** to kill the long vertical scroll: **General / Appearance / Audio** (the existing
  sections already group that way). Each tab short + scannable.
- **Decouple the panel surfaces so each sizes to its own content.** Root problem Alec spotted:
  Settings, Groups, etc. share one panel shell, so opening tall Settings forces its height onto
  Groups → the narrow-tall Groups bug. Fix: each surface (Groups short-and-wide, Settings
  tab-compact) sizes independently; neither dictates the other's geometry. Mechanism is
  engineering's call (separate right-sized windows, or shell sizes-to-content per surface) — the
  locked OUTCOME is each panel fits what it actually shows.
