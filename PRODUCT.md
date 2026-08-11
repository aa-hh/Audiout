# Product

<!-- impeccable:product-schema 1 -->
<!-- Inferred 2026-08-11 from docs/SPEC.md, AGENTS.md, and project history — no interview
     round was run. Every section is inference from repo evidence; correct freely. -->

## Platform

macos

<!-- Native AppKit menu-bar app. Not one of the schema's web/ios/android/adaptive values;
     recorded truthfully rather than force-fit. -->

## Users

Mac owners with several AirPlay 2 speakers who want *everything* the Mac plays —
Spotify, browser, games, calls — in every room, not just Music-app content.
Today the primary user is the developer-owner; public release via direct
download is the goal.

## Product Purpose

Send all system audio to multiple AirPlay 2 speakers at once, perfectly synced,
with per-device volume/mute, saved groups, and per-app routing. Success: rooms
stay in sync, controls feel native-Mac, and setup (permissions, reconnects)
never turns into debugging.

## Positioning

macOS locks system audio to one output; Music/TV's multi-room is app-locked.
Audiouter is an open-source (GPL-2.0-or-later) native menu-bar app that does
whole-system multi-room AirPlay 2 with its own vendored sender — no virtual
audio driver, no black-box server, one tiny root helper.

## Operating Context

- Menu-bar-first `.accessory` app (no Dock icon): popover panel plus Groups and
  Settings windows.
- Useless until macOS grants permissions: System Audio Recording Only
  (macOS 14.4+ process tap), Local Network (permission exists on macOS 15+
  only), optional Accessibility for media-key remote control.
- Direct-download distribution; Developer ID + notarization planned. Ad-hoc dev
  builds churn TCC grants (grants pin to code signature).

## Capabilities and Constraints

- Perfect sync is non-negotiable; the ~1–2 s AirPlay 2 buffer is accepted.
  Audio only — video is out of scope.
- The AirPlay sender is vendored GPL C code wrapped in a Swift actor
  (`AirPlayEngine/`), kept as a licensing boundary with no app concepts inside.
- No public macOS API exists to preflight or request the system-audio-capture
  grant; a denied tap silently delivers zero-filled buffers. The only honest
  grant check is a self-test tone probe. TCC status reads are cached for the
  process lifetime, so in-process polling for a fresh grant never fires.
- Consequence: permission UX is a first-class product problem here, not a
  checklist item.

## Brand Commitments

- Name: Audiouter (`com.audiouter.Audiouter`).
- Native macOS conventions are binding: stock AppKit, SF Symbols, system
  colors. The "Warm Signal" design system owns backgrounds and the gold accent.
- The existing first-run setup window is deliberately styled in the System
  Settings visual language.

## Evidence on Hand

- `docs/SPEC.md` — product spec, source of truth for what to build.
- Shipped first-run permission flow: design brief at
  `dev/notes/onboarding-setup-brief.md`, snapshots in
  `dev/notes/onboarding-snapshots/`.
- Real-world permission-failure telemetry at
  `~/Library/Logs/Audiouter/telemetry.jsonl`.

## Product Principles

1. Honest state over optimistic state — never show a ✓ the OS hasn't proven.
2. Native first — stock AppKit behavior; brand lives in restrained detail.
3. Nothing privileged that isn't tiny and readable line-by-line.
4. Never present a permission or control the user's OS version doesn't have.
5. The Mac is the whole product — no companion-device dependency.
