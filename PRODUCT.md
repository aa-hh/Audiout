# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

Two native Apple surfaces, one product: a macOS menu-bar app (AppKit) and an iPhone companion remote (SwiftUI, iOS 18+, iPhone-only — iPad runs it in compatibility mode). No Android, no web surface. Each platform speaks its own native design language; the shared identity is the Warm Signal layer (see Brand Commitments).

## Users

**Primary — the design target.** General Mac users with more than one AirPlay speaker at home — people frustrated that Spotify, a browser, or a game can only reach one output while the Music app gets multi-room. Zero audio-engineering vocabulary can be assumed for anything a decision hangs on. Confirmed 2026-08-10; supersedes the spec's original single-user framing.

**Secondary audiences (confirmed 2026-08-12).** Real, worth reaching, but they do not move the design target above:

- **People living the iPhone/Mac AirPlay gap** — users who get real AirPlay control on iOS and find the Mac can't match it. The parity complaint is its own reason to install.
- **Audiophiles and hi-fi listeners** — care about lossless on the wire, per-device EQ, and delay trim. Loud and underserved per the competitor research.
- **Small venues, offices, retail, studios** — one Mac driving multi-room audio all day; uptime and unattended reliability matter more than tinkering.
- **Sonos owners specifically** — people escaping the post-rewrite Sonos app. Large, angry, and findable.

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
- **Release status (2026-08-12): nothing is public.** No download, no public repo release, no TestFlight. The only builds in existence are Alec's own live tests. No product surface, copy, or metric may imply that users, downloads, or reviews exist.

## Capabilities and Constraints

- AirPlay 2 multi-room sync is the shipping path (vendored OwnTone sender); AirPlay 1 (RAOP) supported but excluded from per-app routing.
- **Bluetooth output sync is a shipping capability** (Alec, 2026-08-12): Bluetooth speakers join a synced group like any AirPlay device, and future work may assume it. Roadmap 004; the code lives on `claude/foreman-roadmap-004-bt` awaiting merge, with the phone-side wiring landing separately.
- Volume model: sent level = Main × Group × Device (Main acts as ceiling).
- License: GPL-2.0-or-later (forced by the vendored GPL sender). AirPlayEngine is a separate package as a licensing boundary — no app concepts inside it. This licence is what makes paid enforcement unavailable — see Business Model.
- Distribution: open source, direct download for the Mac app. The Mac App Store is **foreclosed, not merely declined**: detecting the system-audio grant needs a private path with no public API, and Alec confirmed Developer ID only. Alec personally owns App Store Connect/TestFlight for the iOS companion.
- **iPhone companion is mid-build (2026-08-12):** connection and core control work end to end; several screens are still being built. It merges into `main` as one unit from `claude/ios-staging`, on Alec's go-ahead — never per-branch. `main` has no `ios/` directory.
- Terminology in product: "Main Out" (master output), "groups" (saved named speaker sets), "per-app routing". The Mac's snapshot is the single source of truth; the phone renders it and never invents state.

## Business Model

Confirmed 2026-08-12. **The model is "free from source, paid binary" — the Ardour model** (Alec, chosen over an honour-system paid app). It constrains product surfaces (a purchase flow, a download gate, a telemetry consent prompt) that do not exist yet.

- **Two paths to the same software.** The source is free: anyone willing to clone the public repo and build it themselves pays nothing — GPL-2.0-or-later requires that and it is not begrudged. The **product** is the paid thing: a signed, notarised, ready-to-run `.app` (Homebrew-free, dylibs bundled), plus updates and support. What is sold is not the software but the convenience of not compiling it.
- **Why this and not an honour-system lock.** GPL-2.0-or-later forbids adding usage restrictions to the covered work and lets any recipient legally redistribute binary and source, so a "enter your key or it won't run" lock is neither enforceable nor permitted while the vendored sender is in the build. The Ardour model sidesteps that entirely: it charges for genuine work (packaging, signing, notarising, supporting) that a free rebuild does not get, so revenue rests on real value rather than on goodwill or a lock people can strip.
- **Price: a one-time ~$25–35 band** (not yet fixed). One-time versus optional subscription, and whether to offer pay-what-you-want, are open. No subscription is assumed.
- **The app itself never blocks, gates, or nags.** A licence check-in may record how many devices a licence appears on so Alec can *see* sharing, but it is telemetry, not a gate — the paid build runs the same for everyone.
- **A clean-room sender is on the cards, not scheduled.** Replacing the vendored GPL sender would free the licence and open other models. It is a large, separate project; nothing may be planned as if it is happening.
- **Promotion (all three, no priority set):** the marketing site plus organic/AI search visibility (separate repo, `~/Projects/Audiouter Website`); Mac community channels (Hacker News, r/macapps, r/sonos, MacRumors, Mac newsletters); and open-source discovery (the repo itself, Homebrew cask, awesome-lists, word of mouth).

## Data Collection

Confirmed 2026-08-12. **Two separate streams, and users are told about each one plainly.** Neither is built yet.

1. **Anonymous feature telemetry — opt-in, off by default.** Asked once, never re-nagged. Feature counts only: no audio content, no speaker names, no network identifiers, and **no license ID attached**. Answers feature usage, feature discoverability, uninstall rate, and month-over-month users.
2. **License activation check-ins — identified by purchase.** Ties a license ID to a device count. This is not anonymous and must never be described as such.

The "no cloud" advantage over Sonos survives but must be stated precisely: **no cloud in the audio or control path.** Discovery, routing, volume, and playback stay entirely local and keep working with the machine offline. Telemetry and activation are the only network calls that leave the LAN, and the first is optional.

## Success Metrics

Confirmed as the metrics that matter (2026-08-12). **No numeric bar is set for any of them — the bar is owed.** Future work must not invent a target and must not claim one is met.

- **Product:** feature usage, feature discoverability, uninstall rate, month-over-month users, and license-ID device spread (how widely a single license travels).
- **Technical:** room-to-room sync accuracy, end-to-end latency and buffer, CPU / memory / battery cost of running the tap and senders all day, and reliability (dropouts per hour, reconnect success, speakers silently vanishing).

Measurements exist in the repo but were never promoted to targets — see `dev/notes/audio-scheduling-measurement.md` and the judder diagnosis notes. Setting the bars is open work.

## Brand Commitments

- Name: **Audiouter**.
- Visual identity: **Warm Signal** — warm near-black ground with gold signal accent in dark. It owns backgrounds and the gold accent; structure and controls stay native (stock AppKit / SF Symbols / system colors on Mac; HIG-conformant SwiftUI on iOS). Binding per Alec's standing feedback.
- **Light mode is the Circuit theme** (Alec, 2026-08-07; landed in code 2026-08-11, superseding the earlier warm-paper light): the scaffolding tokens — canvas, panels, wells, dividers, sidebar — resolve to Circuit values in light and light-high-contrast, and the light canvas is flat rather than graded.
- **Instruments never theme.** The gold family, failure, caution, rings, meters, fader hardware and permission hues carry meaning, so they keep their authored values in every mode and are never remapped by a theme. Contrast is measured, not eyeballed.
- App icon: flat 2D mark, master in Figma (locked); never AI-generate icons.
- Numeric controls show bare numbers/units rather than named presets (localization stance).
- **Voice: the hybrid, and it binds both platforms** (confirmed 2026-08-12; closes the open decision of 2026-08-10). Console flavor is allowed on chrome — fixed labels, section headers, hardware nameplates like "MAIN OUT" — where it sets the mixing-desk tone and nothing is being decided. Anything a user acts on reads in plain speech: states ("Playing", "Ready"), failures, permission prompts, empty states, buttons, and every decision-bearing string. This governs the Mac app and the iPhone app alike; the Mac's Settings and Groups work already behaves this way ("one header voice, one readout voice", the "Playing now" badge).

## Evidence on Hand

- Working product: live multi-room playback verified on real hardware repeatedly; first live phone↔Mac connection achieved 2026-08.
- docs/SPEC.md (draft v0.1, 2026-07-09) — original requirements interview; partially superseded (it predates the phone app decision).
- docs/FIGMA-DESIGN-SYSTEM.md — the design system of record, including the Circuit light mapping and its measured contrast; Figma file `aGvr1qZ3tbqGD2e3jmA1Ru`. Design intent notes in dev/notes/warm-signal-v3.md.
- Checked-in snapshot PNGs under dev/notes/*-snapshots/ (popover, window, settings, onboarding — light and dark), regenerated by the `*-snapshot` executables in AudiouterCore.
- **Competitor and feature-parity research:** `dev/notes/competitor-parity-research-2026-08-05.md` — 80 findings across Sonos, Rogue Amoeba, open-source multiroom, native platform baselines, and small-vendor casting peers, with per-finding evidence URLs in `competitor-sweeps-raw-2026-08-05.json`. It is the market-position evidence base; point-in-time as of 2026-08-05, so re-verify any specific competitor claim before building or marketing against it.
- **No users, no downloads, no reviews, no press, no testimonials, no case studies — nothing has shipped.** Do not fabricate any, and do not write copy that implies an installed base.

## Product Principles

1. **Mixer power, household words.** Capability of a console; vocabulary a first-time Mac user decides with. Jargon may flavor chrome, never carry a decision — settled 2026-08-12, see Voice under Brand Commitments.
2. **The UI never lies.** What's shown is what's known: optimistic echoes are explicitly bounded, refusals surface with the Mac's own reason, empty states are honest, and the phone never invents server state.
3. **Native first, identity in the open layer.** Platform conventions carry structure, navigation, and controls; Warm Signal expresses through the layer the platform leaves open (ground, accent, type voice, motion).
4. **Live audio is high-stakes.** Sound is playing in other rooms while the user acts; kill-switch controls (mute, master volume) stay one gesture away and are never buried.
5. **Sync is sacred.** Rooms playing together is the product's core promise; no feature ships that audibly breaks it.

## Accessibility & Inclusion

Practiced commitment (no formal standard mandated): WCAG-level contrast floors (4.5:1 text / 3:1 non-text) in both appearances, full Dynamic Type on iOS, VoiceOver parity with visible state (spoken state derives from the same source the screen draws), Reduce Motion honored at every animation site, 44 pt touch floors. A 92-finding accessibility audit and wave plan exists for the Mac app (branch claude/accessibility-compliance-audit-ca6e08, unmerged).
