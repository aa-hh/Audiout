# AirPlay Controller

## Purpose

A macOS app (native AppKit, planned) for sending system audio to multiple AirPlay
2 speakers at once with per-device volume, mute/solo, saved groups, and perfect
multi-room sync — capabilities Apple's own Music/TV apps have but the rest of macOS
lacks. The product requirements, phased build plan, and UI design are fully
specified in [SPEC.md](SPEC.md); this file only orients an agent to *where things
live in the repo*, not what the product should do.

Status (see SPEC.md §5 "Phased build plan" and §8 for detail): Phase 0 feasibility
spike is complete — the hard technical risks (AirPlay-2 sender path, OwnTone pipe
input, single-machine dev limitations) have been proven out. Physical speakers are
currently unavailable, so the mock backend is the primary development target.
Phase 1 (the actual AppKit app) has not been started — there is no UI code in this
repo yet.

Keep this file up to date when: a new top-level folder is added (e.g. the AppKit
app target), SPEC.md's phase status materially changes, or the dev tooling gains a
new layer.

## Folder Map

- [AirPlayControllerCore/](AirPlayControllerCore/AGENTS.md) — the Swift package: the
  `Device` model, the `OutputBackend` protocol seam, a fully-working `MockBackend`
  for offline UI work, and a not-yet-implemented `OwnToneBackend` stub. This is the
  only code in the repo today; a future AppKit app target will link against it.
- [dev/](dev/AGENTS.md) — offline dev tooling: an optional shairport-sync "fake
  speaker" script for sanity-checking the real Bonjour/AirPlay-1 wire path
  (single-device only — see that folder's docs for why).
- [SPEC.md](SPEC.md) — the product spec: problem statement, confirmed requirements,
  feature list (v1/v2/later), technical architecture, phased build plan, Phase 0
  feasibility findings, and the full UI design (menu bar, groups, mixer window).
  Treat this as the source of truth for *what* to build; code comments across the
  repo cite specific sections (e.g. "SPEC.md §9") for the reasoning behind a
  decision.

## Notable Patterns

- **No speakers, by design.** There are no real AirPlay devices in this dev
  environment. Anything that needs to "see" a device — UI work, control logic,
  discovery — should be developed and tested against `MockBackend`
  ([AirPlayControllerCore/AGENTS.md](AirPlayControllerCore/AGENTS.md)), not assumed
  to require hardware.
- **The core package knows nothing about AppKit.** `AirPlayControllerCore` is pure
  logic (`Foundation` only); UI code, when it exists, will be a separate target that
  depends on it — not the other way around.

## UI / Design Conventions (all targets)

This app should look and feel like a native macOS citizen, not a cross-platform
port. When building or reviewing ANY UI code in `AirPlayControllerPopoverUI`,
`AirPlayControllerWindowUI`, `AirPlayControllerSharedUI`, or `AirPlayControllerApp`:

- **Prefer stock AppKit components over custom-drawn ones.** Reach for
  `NSSwitch`, `NSSlider`, `NSPopUpButton`, `NSStackView`, `NSTextField`,
  `NSButton` (bezel styles), `NSVisualEffectView`, `NSSplitViewController`,
  toolbar items, etc. before writing a custom `NSView` subclass with manual
  `draw(_:)`. Custom drawing is justified only when no system control expresses
  the design (e.g. `StatusDotView`'s on-icon badge, `CardView`'s Control-Center
  chrome) — and even then, compose system chrome (`NSVisualEffectView`,
  system colors/materials) rather than hand-rolling colors.
- **Use SF Symbols for every glyph.** Any icon/glyph should be
  `NSImage(systemSymbolName:accessibilityDescription:)`, template-rendered so it
  tracks appearance/tint automatically (see `StatusItemController`'s
  `speaker.wave.3.fill` with `variableValue`). Don't ship custom icon assets for
  something SF Symbols already covers.
- **Use system colors and materials, not hardcoded hex/RGB.** `.labelColor`,
  `.secondaryLabelColor`, `.controlAccentColor`, `.windowBackgroundColor`,
  semantic materials (`.sidebar`, `.headerView`, `.hudWindow`) — so Dark Mode,
  accent color, and accessibility contrast settings all work for free.
- **Respect system-level user settings.** Reduce Motion (see
  `StatusDotView`'s static fallback), Increase Contrast, Reduce Transparency,
  and Dynamic Type-equivalent text scaling should all be checked, not assumed
  off.
- **When in doubt, match Control Center / System Settings**, since this app's
  design brief (SPEC.md §9) is explicitly modeled on them — not a bespoke
  design language.
- Deviating from any of the above (a genuinely custom control, a one-off
  color) is fine when the system has no equivalent, but note *why* in the
  nearest AGENTS.md so the next agent doesn't "fix" it back to a system control
  that doesn't actually fit.
