# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native AppKit; not web/ios/android — desktop menu-bar app)

## Users

A Mac owner who wants the whole system's audio — Spotify, browser, games, calls — playing in sync across multiple rooms of AirPlay speakers, controlled from the menu bar without opening Music.app.

## Product Purpose

Audiouter streams **all system audio** to multiple AirPlay 2 receivers simultaneously with per-device volume, mute/solo, master volume, saved named groups, and per-app routing (e.g. Spotify → Kitchen while Zoom stays local). macOS natively allows only one output for system audio; Audiouter removes that limit.

## Positioning

The only path to multi-room *system* audio on macOS: a vendored AirPlay 2 sender (OwnTone-derived) plus a Core Audio process tap, wrapped in a native menu-bar UI. Music/TV can do multi-room for their own content only; Audiouter does it for everything.

## Operating Context

- Menu-bar popover is the primary surface (pinnable; hosts Mixer/Groups/Settings — roadmap 032 "one-surface app").
- Needs TCC grants: system audio capture (macOS 14.4+ kTCCServiceAudioCapture), local network; ships as a signed Developer ID .app.
- Real hardware testing is by ear on live AirPlay/Bluetooth speakers; dev runs use `AIRPLAY_BACKEND=mock`.

## Capabilities and Constraints

- AirPlay 2 (and AirPlay 1/RAOP) receivers; Bluetooth multi-device sync in progress on a branch. Audio only, no video. ~1–2 s buffer is accepted.
- GPL-2.0-or-later (forced by vendored GPL sender); direct download only — App Store is foreclosed (private TCC detection, Alec confirmed Developer ID only).
- Per-app routing excludes AirPlay 1 devices.
- Architecture rules live in AGENTS.md files (read nearest before editing); product truth in docs/SPEC.md.

## Brand Commitments

- Name: **Audiouter** (bundle com.audiouter.Audiouter). Icon: reuse scripts/Audiouter.icon — never AI-generate.
- Visual identity: **Warm Signal** (dark, warm near-black canvas, gold accent as the only brand color; stock AppKit + SF Symbols + system colors everywhere else). Design system mastered in Figma (docs/FIGMA-DESIGN-SYSTEM.md); tokens in `Tokens.swift`.
- **Light mode = Circuit theme** (Alec, 2026-08-07): the 18 scaffolding tokens alias Circuit values in light/lightHC; instruments (gold family, failure, caution, meters, fader hardware, permission hues) are never Circuit-mapped. `accent` keeps the macOS system accent in light.

## Evidence on Hand

- docs/SPEC.md (product spec, source of truth), docs/FIGMA-DESIGN-SYSTEM.md (design system + Circuit mapping and measured contrast), dev/notes/warm-signal-v3.md, snapshot PNGs under dev/notes/*-snapshots/ (light + dark).
- Figma file aGvr1qZ3tbqGD2e3jmA1Ru holds the design system, including Circuit light values ahead of code.

## Product Principles

- Native first: behave like a stock macOS control, brand only in precise details (backgrounds + gold accent).
- Perfect sync outranks latency; audio correctness outranks features.
- Instruments carry meaning — their colors never theme; scaffolding themes freely via tokens.
- Measure contrast, don't eyeball (≥3:1 instruments, ≥4.5:1 body text, both canvases).
- Plain numeric controls over named presets; no invented terminology.

## Accessibility & Inclusion

WCAG contrast bars enforced per token (see FIGMA-DESIGN-SYSTEM.md measurements). A 92-finding accessibility audit exists on branch claude/accessibility-compliance-audit-ca6e08 (unmerged).
