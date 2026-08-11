# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

Two native Apple surfaces, one product: a macOS menu-bar app (AppKit) and an iPhone companion remote (SwiftUI, iOS 18+, iPhone-only — iPad runs it in compatibility mode). No Android, no web surface. Each platform speaks its own native design language; the shared identity is the Warm Signal layer (see Brand Commitments).

## Users

General Mac users with more than one AirPlay speaker at home — people frustrated that Spotify, a browser, or a game can only reach one output while the Music app gets multi-room. Zero audio-engineering vocabulary can be assumed for anything a decision hangs on. Confirmed 2026-08-10; supersedes the spec's original single-user framing.

## Product Purpose

Send all system audio (not just Music/TV) to multiple AirPlay 2 speakers in perfect sync, with per-device volume and mute, saved groups, and per-app routing. Success: a household drives its whole speaker set from the menu bar (or the phone) without thinking about how.

## Positioning

**The mixer for your house.** Not just "AirPlay to two speakers": groups, per-device volume/EQ, per-app routing (Spotify → kitchen while Zoom stays local), master volume, and a phone remote — a mixing desk for the home, end to end. (Confirmed 2026-08-10 over the alternatives "free AirPlay 2 sync" and "routing is the moat".)

Design tension to protect, not resolve by accident: mixer-grade capability with general-consumer language. The power is the desk; the words are not allowed to be.

## Operating Context

- Primary surface: macOS menu-bar popover (one-surface direction: pinnable popover hosting Mixer/Groups/Settings — roadmap 032); a fuller window exists for groups/settings.
- Companion: iPhone app discovers the Mac over Bonjour and remote-controls it; it has no audio path of its own.
- Audio is live in other rooms while the UI is used — volume and mute are high-stakes, time-pressured actions (dinner party, blasting speaker).
- macOS TCC permissions gate the core capability (system audio capture, `kTCCServiceAudioCapture` on macOS 14.4+; Local Network on macOS 15+); permission UX is part of the product. The Mac app ships as a signed Developer ID `.app` because those grants require it.
- ~1–2 s AirPlay buffer is accepted; audio only, video explicitly out of scope.

## Capabilities and Constraints

- AirPlay 2 multi-room sync is the shipping path (vendored OwnTone sender); AirPlay 1 (RAOP) supported but excluded from per-app routing. Bluetooth output sync works and is merging now (roadmap 004, confirmed 2026-08-10); the phone-side wiring task is landing separately.
- Volume model: sent level = Main × Group × Device (Main acts as ceiling).
- License: GPL-2.0-or-later (forced by the vendored GPL sender). AirPlayEngine is a separate package as a licensing boundary — no app concepts inside it.
- Distribution: open source, direct download for the Mac app. The Mac App Store is **foreclosed, not merely declined**: detecting the system-audio grant needs a private path with no public API, and Alec confirmed Developer ID only. Alec personally owns App Store Connect/TestFlight for the iOS companion.
- Terminology in product: "Main Out" (master output), "groups" (saved named speaker sets), "per-app routing". The Mac's snapshot is the single source of truth; the phone renders it and never invents state.

## Brand Commitments

- Name: **Audiouter**.
- Visual identity: **Warm Signal** — warm near-black ground with gold signal accent in dark. It owns backgrounds and the gold accent; structure and controls stay native (stock AppKit / SF Symbols / system colors on Mac; HIG-conformant SwiftUI on iOS). Binding per Alec's standing feedback.
- **Light mode is the Circuit theme** (Alec, 2026-08-07; landed in code 2026-08-11, superseding the earlier warm-paper light): the scaffolding tokens — canvas, panels, wells, dividers, sidebar — resolve to Circuit values in light and light-high-contrast, and the light canvas is flat rather than graded.
- **Instruments never theme.** The gold family, failure, caution, rings, meters, fader hardware and permission hues carry meaning, so they keep their authored values in every mode and are never remapped by a theme. Contrast is measured, not eyeballed.
- App icon: flat 2D mark, master in Figma (locked); never AI-generate icons.
- Numeric controls show bare numbers/units rather than named presets (localization stance).
- **Voice: OPEN DECISION (2026-08-10).** The iOS Speakers screen currently uses a hybrid — console flavor on chrome ("MAIN OUT"), plain speech for decision-bearing states ("Playing"/"Ready") — but whether that binds all surfaces (including the Mac app) is explicitly undecided. Future work must not assume either way.

## Evidence on Hand

- Working product: live multi-room playback verified on real hardware repeatedly; first live phone↔Mac connection achieved 2026-08.
- docs/SPEC.md (draft v0.1, 2026-07-09) — original requirements interview; partially superseded (it predates the phone app decision).
- docs/FIGMA-DESIGN-SYSTEM.md — the design system of record, including the Circuit light mapping and its measured contrast; Figma file `aGvr1qZ3tbqGD2e3jmA1Ru`. Design intent notes in dev/notes/warm-signal-v3.md.
- Checked-in snapshot PNGs under dev/notes/*-snapshots/ (popover, window, settings, onboarding — light and dark), regenerated by the `*-snapshot` executables in AudiouterCore.
- No testimonials, case studies, user counts, or press. Do not fabricate any.

## Product Principles

1. **Mixer power, household words.** Capability of a console; vocabulary a first-time Mac user decides with. Jargon may flavor chrome, never carry a decision (pending the open voice question above).
2. **The UI never lies.** What's shown is what's known: optimistic echoes are explicitly bounded, refusals surface with the Mac's own reason, empty states are honest, and the phone never invents server state.
3. **Native first, identity in the open layer.** Platform conventions carry structure, navigation, and controls; Warm Signal expresses through the layer the platform leaves open (ground, accent, type voice, motion).
4. **Live audio is high-stakes.** Sound is playing in other rooms while the user acts; kill-switch controls (mute, master volume) stay one gesture away and are never buried.
5. **Sync is sacred.** Rooms playing together is the product's core promise; no feature ships that audibly breaks it.

## Accessibility & Inclusion

Practiced commitment (no formal standard mandated): WCAG-level contrast floors (4.5:1 text / 3:1 non-text) in both appearances, full Dynamic Type on iOS, VoiceOver parity with visible state (spoken state derives from the same source the screen draws), Reduce Motion honored at every animation site, 44 pt touch floors. A 92-finding accessibility audit and wave plan exists for the Mac app (branch claude/accessibility-compliance-audit-ca6e08, unmerged).
