# AirPlay Controller — Product Spec & Feasibility Plan

*Draft v0.1 — 2026-07-09. Based on our interview. Everything here is up for revision.*

---

## 1. The problem

macOS only lets you send **system audio** to **one** output at a time. The Music
and TV apps can drive multiple AirPlay 2 speakers with per-device volume, but
*everything else* (Spotify, browser, YouTube, games, calls) is locked to a single
output. You want a single app that:

- discovers available AirPlay devices,
- lets you pick **several at once**,
- controls **each device's volume individually**,
- and keeps the rooms **in sync**.

---

## 2. What you told me (confirmed requirements)

| Decision | Your choice | Consequence |
|---|---|---|
| Audio source | **All system audio** | Hardest path — needs an audio-capture layer + a custom AirPlay sender. |
| Grouping | **Save named presets** ("Whole house", "Downstairs") | Persisted groups w/ per-device volume + membership. |
| Sync | **Perfect sync required** | Must use AirPlay 2's synchronized multi-room timing. The ~1–2s buffer is fine now that video is out of scope. |
| Video | **Dropped — audio only** | Removes the hardest requirement. No low-latency mode needed. |
| Form factor | **Menu bar + full window** | Quick menu-bar panel; richer window for groups/EQ. |
| Remote control | **Mac only** (no phone app) | No companion app / network server needed. Simpler. |
| Device types | **AirPlay only** | No Bluetooth/Sonos-native/wired in v1. (Sonos speakers are used *via their AirPlay 2 support*, not the Sonos API.) |
| Distribution | **Direct download; OPEN SOURCE (decided 2026-07-13)** | Alec may redistribute → project licensed GPL-2.0-or-later (required by the vendored AirPlay-2 sender cluster from OwnTone, which is GPL; libairptp/pair_ap are MIT, evrtsp BSD — kept separately marked). No App Store. |
| Extra controls | Per-device **mute/solo**, **master volume**, **EQ/balance** | Mixer-style UI. |
| Power features | **Per-app routing**, **auto-reconnect** | Route Spotify→kitchen while Zoom stays local; re-activate groups when devices reappear. |

---

## 3. Feature list

### v1 (core — proves the concept)
- Discover AirPlay / AirPlay 2 receivers on the network (Bonjour).
- Select multiple devices; stream **all system audio** to them.
- **Synchronized** playback across selected devices.
- Per-device **volume** + **mute/solo**; **master** volume.
- Menu-bar panel with the device list + sliders.
- Save/activate **named groups** with remembered volumes.

### v2 (the differentiators)
- **Per-app routing** (Spotify → Kitchen while Zoom stays on the Mac): per-app
  destination pickers in the window's Applications view; overlapping routes are
  **mixed per speaker**; "This Mac (don't stream)" bypass keeps an app local.
- **Auto-reconnect** a group when its devices come back online.
- Full **window app** with a proper mixer, per-device **EQ / L-R balance**.

### Later / nice-to-have
- Volume calibration (loudness-match mismatched speakers).
- Sleep timer + fade in/out.
- Global keyboard shortcuts.
- Phone remote (you said no for now, but the architecture can leave room).

---

## 4. Technical architecture (proposed)

```
 ┌─────────────────────────────────────────────────────────┐
 │  System audio (Spotify, browser, games, calls, …)        │
 └───────────────────────────┬─────────────────────────────┘
                             │  capture
        ┌────────────────────▼─────────────────────┐
        │  Audio capture layer                      │
        │  • Core Audio process tap (macOS 14.4+)   │
        │    OR a virtual output device (BlackHole- │
        │    style AudioServerPlugIn)               │
        └────────────────────┬─────────────────────┘
                             │  PCM frames + clock
        ┌────────────────────▼─────────────────────┐
        │  AirPlay 2 sender engine                  │
        │  • per-device RTP streams                 │
        │  • shared timeline → synchronized play    │
        │  • per-stream volume                      │
        └────────────────────┬─────────────────────┘
             ┌───────────────┼───────────────┐
        ┌────▼────┐     ┌─────▼────┐     ┌────▼────┐
        │ HomePod │     │ Apple TV │     │ AirPlay │
        └─────────┘     └──────────┘     └─────────┘
                             ▲
        ┌────────────────────┴─────────────────────┐
        │  AppKit app: NSStatusItem menu + full     │
        │  window, groups, mixer, presets, routing  │
        └───────────────────────────────────────────┘
```

### Security & trust principles (added 2026-07-09 after Phase 0 findings)

The guiding rule: **no large or third-party component ever runs privileged, and
everything privileged is small enough to read line-by-line.**

1. **One tiny root helper, nothing else.** AirPlay 2's PTP clock must bind UDP
   319/320 (privileged). Only a minimal, single-purpose PTP daemon gets root —
   extracted from OwnTone's `libairptp` (a few hundred lines, no dynamic
   allocation-heavy parsing, fixed-size packets) — installed via Apple's official
   `SMAppService` launchd-daemon mechanism. This mirrors shairport-sync's `nqptp`
   design, chosen for exactly this reason.
2. **The app, capture layer, and AirPlay sender all run unprivileged** as the
   logged-in user. The sender is code we extract and own (OwnTone's `airplay.c`,
   `pair_ap/`, `evrtsp/`), not a black-box server we shell out to.
3. **OwnTone itself is spike scaffolding only.** It never ships. (Phase 0 also
   showed why: its root-drop leaves the saved-UID as root, so even "deprivileged"
   it can't be signal-managed by the user — below our bar.) **Decided 2026-07-13:
   the final product contains NO OwnTone references at all — naming included.**
   The interim `OwnToneBackend` (dev-only, drives the local OwnTone server while
   the native engine is built) and `dev/owntone/` are deleted when the native
   sender lands; the shipped backend is named neutrally (e.g. `NativeBackend`),
   and the `AIRPLAY_BACKEND=owntone` env value goes with it.
4. **Signed + firewall-registered at install** so the Application Firewall
   allowlists the helper once, correctly (Phase 0 lost an hour to silent PTP
   drops from the firewall).

**The three layers:**

1. **Audio capture.** Two viable routes:
   - *Core Audio process taps* (`AudioHardwareCreateProcessTap`, public since
     macOS 14.4) — capture system/per-process audio with no kernel extension.
     Cleanest, and it's what enables per-app routing.
   - *Virtual output device* (a userspace `AudioServerPlugIn`, the same
     mechanism BlackHole uses) — the user selects it as their output; we grab
     everything. More brute-force but rock-solid for "all audio".

2. **AirPlay 2 sender engine** — the hard core. There is **no public Apple API**
   to send audio to AirPlay devices; the Music app uses private frameworks. A
   real implementation reuses the reverse-engineered AirPlay 2 sender from open
   source — **[OwnTone](https://github.com/owntone/owntone-server)** (formerly
   forked-daapd) implements synchronized AirPlay 1 & 2 multi-room output and is
   the best reference/foundation. This layer owns the per-device streams, the
   shared clock (which is what makes "perfect sync" possible), and per-stream
   volume.

3. **App UI** — **pure AppKit** (decided 2026-07-09; see §9). Every visible
   element is a documented AppKit control used per its documentation — no custom
   lookalikes. Device discovery via `NWBrowser`/Bonjour (`_airplay._tcp`,
   `_raop._tcp`).

---

## 5. Phased build plan

- **Phase 0 — Feasibility spike (recommended first).** Prove we can (a) capture
  system audio, and (b) send synced audio to two real AirPlay 2 devices with
  independent volume. This de-risks the whole project before committing to UI.
- **Phase 1 — Core (v1).** Capture → sender → menu-bar UI → multi-device select,
  per-device volume/mute, master volume, saved groups.
- **Phase 2 — Differentiators (v2).** Per-app routing, auto-reconnect, full
  window + mixer + EQ, video/low-latency mode.
- **Phase 3 — Polish.** Calibration, sleep timer, fades, shortcuts.

---

## 6. Honest feasibility truths (read this part)

These are the things most likely to bite us — better to face them now.

1. **The AirPlay sender is reverse-engineered, not sanctioned.** Apple gives no
   public API. We lean on community work (OwnTone/shairport lineage). It works,
   but Apple can change the protocol in an OS/firmware update and break us. This
   is the single biggest ongoing risk.

2. **The ~1–2s sync buffer is now a non-issue.** Video is out of scope, so the
   inherent AirPlay 2 multi-room buffer is invisible — this stopped being a risk
   the moment we dropped video.

3. **Distribution.** A virtual audio driver / system audio tap needs one-time user
   approval in System Settings, and ideally Developer ID signing so macOS doesn't
   block it. Since this is a personal, direct-download tool, we can keep signing
   lightweight. Not App Store material — which is fine.

4. **Effort.** This is a real project, not a weekend script — the sender engine
   alone is substantial. Phase 0 tells us how substantial before we over-invest.

5. **Test devices.** Your set is 2× Sonos (via AirPlay 2) + 1 other third-party
   receiver. Good coverage of the reverse-engineered path; the one gap is no real
   HomePod/Apple TV, which can behave slightly differently. Confirm the Sonos
   models support AirPlay 2 (2018+ models do; Play:1/Play:3 don't).

---

## 7. Resolved

1. **Video** — dropped. Audio only. (Kills the biggest technical risk.)
2. **Distribution** — direct download, personal use. Fine.
3. **Test devices** — 2× Sonos (AirPlay 2) + 1 third-party receiver.
4. **Scope** — personal tool. Polish bar: "works well for me."

---

## 8. Phase 0 — feasibility spike (next up)

Goal: **before writing any UI**, prove the two riskiest things work on your
machine and your speakers. Each step is a throwaway command-line experiment.

- [x] **0a — Discover devices.** ✅ `dns-sd -B _airplay._tcp` (zero install) sees
  AirPlay devices. Found: `teevee`, `Mixer`, `Sonos Move` (+ the Mac itself). Note:
  only 1 of 2 Sonos was advertising — second may have been asleep/off. Toolchain
  confirmed: Swift 5.10, Xcode, Homebrew, **macOS 14.4.1** (meets the 14.4+ minimum
  for Core Audio process taps, so 0e may not need a virtual driver).
- [~] **0b — Send to ONE speaker.** Partial. Findings so far (2026-07-09):
  - Test hardware identified: `Sonos Move` (192.168.4.27), `Move 2` (Sonos Move 2,
    192.168.4.37), `Mixer` = **AirPort Express gen 2** (fw 7.8.1, 192.168.4.29).
    `teevee` is an LG TV (no RAOP, pairing required) — out of scope.
  - **pyatv** (pipx, Python 3.12 — 3.14 breaks its CLI): plays to the AirPort
    Express ✅, but Sonos stays silent ❌ — debug logs show pyatv opens an
    AirPlay 2 session but declares `timingProtocol: SNTP`; **Sonos requires PTP**
    and silently discards SNTP-timed audio.
  - **libraop/cliraop** (prebuilt macos-arm64 in repo): AirPlay 1 only — Sonos
    rejects handshake with RTSP 403. Dead end for our targets, though its
    fork-N-instances-with-shared-NTP-start trick is a useful sync reference.
  - ⇒ **The sender MUST implement true AirPlay 2 with PTP timing.** This is the
    same machinery that provides multi-room sync, so it was always required —
    Sonos just makes it mandatory even for one speaker.
  - ✅ **RESOLVED: OwnTone 29.2 built natively on macOS** (arm64, `--without-avahi`
    → Apple dns_sd; binary at `scratchpad/owntone-build/owntone-server/src/owntone`;
    see build notes below) and **successfully played to both Sonos Moves + the
    AirPort Express simultaneously, user-confirmed in sync** (metronome test
    track, no audible echo/drift walking between rooms).

- [x] **0c — Send to ALL THREE, synced.** ✅ **PASSED 2026-07-09.** All three
  devices played the 1 Hz click track in sync (user walked between rooms).
  `timing=PTP` confirmed in OwnTone debug logs for both Sonos devices.
  **Two gotchas that cost hours — bake into the final app:**
  1. **PTP needs root** (binds UDP 319/320). OwnTone runs as root and drops
     privileges. Final app needs the same, a root helper (like shairport-sync's
     `nqptp` daemon), or OwnTone's bundled `airptpd`.
  2. **macOS Application Firewall silently blocks inbound PTP** (peer-initiated
     UDP, not stateful return traffic) → speakers accept the session but play
     silence. Must allowlist the binary **and restart it** (the verdict sticks to
     already-bound sockets). The final app must be signed + firewall-registered
     at install.
- [x] **0d — Per-device volume.** ✅ **PASSED 2026-07-13** (fake-receiver form;
  speakers no longer available — see §8.1). `PUT /api/outputs/{id}` with
  `{"volume": 0-100}` → 204; wire-verified live `SET_PARAMETER` at the receiver
  (linear 0–100 maps to −30…0 dB). Audible-on-Sonos form → deferred checkpoint.
- [x] **0e — Capture system audio.** ✅ **PASSED 2026-07-13.** Swift CLI at
  `dev/audiocap/` using Core Audio process taps (no virtual driver, no BlackHole):
  - **Global tap** (all system audio): non-silent capture verified (peak 0.36).
    Tap ASBD on this machine: 44.1 kHz Float32 LE interleaved stereo — **rate
    tracks the default output device; always read the real ASBD.**
  - **Per-app tap** (`--pid`/`--bundle`) and **process exclusion** (`--exclude`)
    verified by Goertzel tone tests — the foundations of §9 per-app routing and
    the "This Mac (don't stream)" bypass. **Exclusion resolves lazily:** a pid is
    only excludable after it opens an audio stream.
  - **TCC UX:** capture permission prompts on first run ("record this computer's
    audio"; System Settings → Privacy & Security → Screen & System Audio
    Recording). The grant attaches to the CLI's parent app and **resets on every
    rebuild** of an ad-hoc-signed binary. No public preflight API exists — the
    app must prompt-on-first-capture and handle denial gracefully.
- [x] **0f — End-to-end.** ✅ **PASSED 2026-07-13** (fake-receiver form). Chain:
  system audio → global tap → Float32→S16LE → named FIFO → OwnTone pipe input →
  AirPlay → shairport receiver. 30 s check plus a **10-minute soak: stable,
  no underruns, output stayed selected** (`dev/verify-0f3-soak.sh`). Pipe
  latency ≈ 0.12 s; audible end-to-end is dominated by the ~2 s AirPlay sync
  buffer (fine for audio-only scope). Key pipe facts (dev/notes/0f-pipe-brief.md):
  `pipe_sample_rate` is a GLOBAL OwnTone config with **no autodetection** (wrong
  rate = silent pitch shift) — **config-follows-tap** is an app invariant;
  autostart silently no-ops when the pipe is already the current item (always
  drive playback explicitly); after long stalls OwnTone can deselect an output
  while still reporting "play" (watch `outputs[].selected`).

### 8.1 Phase 0 close-out (2026-07-13)

**Phase 0 is COMPLETE. The product is buildable — proceed to Phase 1.**
Execution details and per-task reports: `PLAN-0e-0f.md`; research briefs in
`dev/notes/`; spike tooling in `dev/` (audiocap CLI, OwnTone at `dev/owntone/`,
verify scripts, fake receiver).

**Sender decision (was an open question): extract, don't embed.** OwnTone
validated the protocol but never ships (§4) — Phase 2 extracts `airplay.c` +
`libairptp` + `pair_ap` + `evrtsp` into our own engine; no OwnTone references
in the final product, naming included.

**Changed circumstances:** Alec lost access to the test speakers mid-spike
(2026-07-13) — 0d/0f passed in fake-receiver form; 0b/0c had already passed on
real Sonos + AirPort Express. **Deferred real-hardware checkpoints** (run when
speakers return, before calling v1 done): audible per-device volume; multi-room
sync walk test; 48 kHz-pipeline-on-Sonos check; real end-to-end latency +
stability.

**FULL end-to-end un-defer (2026-07-13):** on a live network with real AirPlay 2
devices (Sonos Port "Pool", Yamaha RX-A4A "Cinema"), the COMPLETE Phase 1 path
ran on real hardware, **user-confirmed audible on Cinema**: Mac system audio →
audiocap Core-Audio tap → S16LE FIFO → OwnTone → **AirPlay 2 + PTP → Cinema**
(`dev/verify-realpath-cinema.sh`). Both the capture half and the AirPlay-2-send
half, together, on a genuine receiver. ⇒ every core technical bet is now proven
on real gear.
- **Config finding (shipped-app requirement):** OwnTone's `pipe_autostart`
  defaults ON and RACES the explicit clear→add→play sequence when the FIFO
  starts filling (DB-lock + failed start → silent speaker). MUST be OFF; drive
  playback explicitly (T-C2 already does). Set in `dev/owntone/etc/owntone.conf`.
- **Local-output behavior (DECIDED 2026-07-13 — a toggle, and sync is required):**
  two modes: (1) **Mute the Mac** — local goes silent, audio only on the AirPlay
  speakers (tap `muteBehavior = .mutedWhenTapped`); (2) **Play everywhere** — Mac
  speakers AND AirPlay speakers together. Default = mute; a UI switch enables
  "also play here."
  - **HARD REQUIREMENT: in "play everywhere" mode the Mac's local output MUST be
    synced with the AirPlay receivers.** Observed 2026-07-13: raw local output
    plays ~2s AHEAD of AirPlay (AirPlay 2's ~2s sync buffer vs real-time local).
  - **Implementation:** the Mac's own speakers become another *synchronized
    endpoint* — mute the live OS output and render a DELAYED local copy scheduled
    on the same PTP presentation clock as the remote receivers (delay local by the
    AirPlay latency so all endpoints align).
  - **This is a NATIVE-ENGINE (Phase 2) capability** — the engine owns the PTP
    timeline, so it can schedule a local Core Audio sink at the remote presentation
    timestamp. OwnTone can't do synced local output on macOS (no working local
    backend), which is why the current prototype's local sound is unsynced OS
    leakage. ⇒ add "synced local Core Audio endpoint" to the AirPlayEngine API
    (it's a first-class output alongside the AirPlay outputs, on the shared clock).
- STILL deferred: multi-room SYNC (needs 2+ real receivers together) and our own
  extracted engine (Phase 2, not yet runnable). Devices are on a transient/shared
  network — opportunistic only. The mock rig is primary in the meantime: `MockBackend`
(control/state), `dev/fake-speakers.sh` + verify scripts (audio path),
`AIRPLAY_BACKEND=mock|owntone` env toggle (default mock).

---

## 9. UI design — pure AppKit, documentation-grounded

**Standing rule (from Alec, 2026-07-09): every UI element must be an actual
documented AppKit control, looked up at
https://developer.apple.com/documentation/AppKit and used/styled exactly as its
documentation and the macOS HIG specify.** Doc URLs below are
`developer.apple.com/documentation/appkit/<class>`.

Decisions: **pure AppKit** (no SwiftUI) · **dropdown is a Control-Center-style
NSPopover** (REVISED 2026-07-13 — see below) · full window is **sidebar + mixer**
· volume is **horizontal rows**.

> **REVISED 2026-07-16 — Applications card + collapsible sections + exact-fit
> popover SHIPPED.** Per-app routing (previously a "Future (v2)" note below)
> is now a third popover card with full UI, model, and persistence; sections
> are individually collapsible with per-open-recomputed defaults; the popover
> dropped its `NSScrollView` in favor of exact content-fit sizing with no
> scrollbar. Full authoritative decision record: PLAN-POPOVER-ROUTING.md §B.
> Details inline below.

> **DROPDOWN REVISED 2026-07-13 — NSMenu → NSPopover.** The first build used a
> true NSMenu (HIG's default for menu-bar extras). Hands-on use exposed hard
> NSMenu limits: **no animated inline expand/collapse** (menus can't animate
> row insertion — that smooth expansion is a Control-Center behavior, and
> Control Center is a popover, not a menu), awkward click targets (only the
> chevron toggled, not the row), and inconsistent custom-view layout. The HIG
> sanctions a popover when a menu-bar extra is "too complex for a menu" —
> grouped speakers with sliders, per-row controls, and animated expansion
> qualifies. So the dropdown becomes an **`NSStatusItem` button → `NSPopover`**
> hosting a custom view hierarchy (Control-Center style). This unlocks:
> animations, click-anywhere-on-row to toggle, keyboard/text (so even in-panel
> group naming is now possible), and consistent layout. Row/group views
> (`DeviceRowView`, `GroupRowView`) and all group/volume logic carry over
> unchanged; only the container swaps NSMenu → NSPopover. Quick-create is no
> longer forced by the no-keyboard-in-menu limit, but manual creation stays the
> primary path per the group-setup section.

### Menu bar extra
| Element | AppKit API | Documented usage we follow |
|---|---|---|
| Status item | `NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)` | Customize only via its `button` property; the button's action toggles the popover. Provide a user setting to hide it (HIG). |
| Status icon | `NSImage(systemSymbolName:variableValue:accessibilityDescription:)` | SF Symbol `speaker.wave.3.fill` with `variableValue` = master volume. Template rendering → correct in dark/light menu bar. |
| Dropdown | **`NSPopover`** (`.transient`/`.semitransient` behavior) anchored to the status button, hosting an exact-content-fit custom-view panel (no `NSScrollView`, no scrollbar — REVISED 2026-07-16, see below) | Control-Center-style. Groups + devices are stacked custom views; expansion animates; click anywhere on a row toggles it. |

### Groups in the menu (decided 2026-07-09)

Groups are first-class in the dropdown — the menu is usable without ever opening
the mixer window. Menu structure, top to bottom:

1. **Groups section.** One row per saved group: disclosure chevron, group name,
   numeric readout, and a **group master slider**. **REVISED 2026-07-13: EVERY
   group row shows its master slider consistently** (not just the active one —
   the active-only rule was confusing in practice). A non-active group's master
   sets its members' preset levels; activating it applies them.
2. **Expansion.** **Clicking anywhere on the group header row** (not just the
   chevron) toggles expansion, which **animates** open/closed (popover custom
   views — the reason for the NSMenu→NSPopover switch), revealing one indented
   device row per member (icon, name, slider, mute). Chevron state always
   reflects actual expansion.
3. **Devices section.** Ungrouped speakers each get their own row below the
   groups — everything on the network is reachable from the panel.
4. **Actions.** Separator, then plain items: "Save current setup as group…",
   "Open mixer…".

**Interaction / routing model (REVISED 2026-07-14 — SoundSource-inspired; this is
the CORE model, superseding the 07-13 free-on/off version):**

Design cues from Rogue Amoeba's SoundSource (Alec's reference, screenshots
2026-07-14): sectioned card layout, rows of icon · name · volume slider+% ·
trailing control, a device-selector dropdown as THE routing control.

**Popover structure (SIMPLIFIED 2026-07-14b — two-section selector):**
1. **System section — a single "Main Out" row** (name · volume · device
   selector). The device selector is THE routing decision. Its dropdown has
   **TWO** option sections:
   - **§1 "Selected Devices"** — the set composed by the toggles below. The
     Mac's own speakers are NOT a special selector entry — the current device is
     just one more device in the set. Passthrough is DERIVED: when the selected
     set is exactly {current device}, the app captures/streams nothing.
   - **§2 Output Groups** — the saved groups.
   The Main Out **volume = proportional master of the current target**.
2. **"Selected Devices" section** (below System): every discovered device, split
   into two subsections: **Current Device** (the Mac, by its real name) and
   **AirPlay Devices**. Row: name · volume · **toggle switch** (Alec explicitly
   prefers toggles, not checkmarks) = membership in the Selected Devices set.
   Toggles compose the set; routing is applied when Main Out targets Selected
   Devices (the default).
   - **Default state: Current Device toggled ON**, Main Out = Selected Devices ⇒
     out-of-the-box the app is passthrough (normal local playback).
   - **Auto-swap rule:** toggling an AirPlay device ON while the current device
     is the ONLY selected device auto-untoggles the current device (switching to
     AirPlay implies moving the audio there). The user may manually re-toggle
     the current device afterwards to have both (Phase 1: that re-add hits the
     local-sync block below; the gesture exists, the engine unlocks it).
3. Groups keep expansion (animated) + per-group master; group editing stays in
   the mixer window; "Save current setup as group" quick-create remains (now =
   "save Selected Speakers as a group").
4. **Applications card — SHIPPED 2026-07-16** (see PLAN-POPOVER-ROUTING.md §B
   for the full resolved-decisions record; this supersedes the prior "Future
   (v2)" note). The popover now has a third card, **rendered last**, below
   Selected Devices: one row per user-routed app — app icon · name ·
   **always-visible** volume slider (`ControlCenterSlider`, dimmed/disabled
   while the destination is "Current device," matching `DeviceRowView`
   dimming) · a "redirect audio to…" `NSPopUpButton` with **exactly two
   sections, Current Device and AirPlay Devices** (no Groups — Main Out's
   Output Groups entries are unaffected). A hover-revealed **✕** removes the
   route (`HoverActionButton` idiom, same discipline as other rows). A
   full-width **"+ Add application…"** row sits at the card's bottom; it is
   also the card's empty state, and opens a running-app picker sourced from
   `NSWorkspace.shared.runningApplications` (`.regular` apps only). Picking an
   app creates a route with destination **Current device** (§ "Current device
   == no redirect" below).
   - **"Current device" is not a distinct state — it IS "no redirect."** The
     app just plays locally; there is no separate no-redirect flag to track.
   - **Lost-device fallback is silent.** If a route's target device
     disappears from the network, the route resets to Current device
     (persisted immediately) — no greyed-out placeholder, no error UI.
   - **Scope honesty: this is UI + model + persistence only.** Routes are
     wired against `MockBackend` today; no `OutputBackend` changes shipped
     with this work. Redirects persist and render correctly, but **move no
     audio** until the native AirPlay engine (Phase 2) supports per-app
     capture streams — per-process Core Audio taps are already proven
     (`dev/audiocap`, §8.1 0e), but `CaptureCoordinator` today is a single
     global tap. Treat every redirect as "recorded intent," not "live
     routing," until the engine lands.

   **Collapsible sections (shipped alongside the Applications card).** Every
   card — System, Selected Devices, Applications — gets a leading chevron
   (`chevron.down`/`chevron.right`) next to its title; clicking **either the
   chevron or the title** (decision 5, PLAN §B) toggles that card's body
   collapsed/expanded with an animated resize (rest of the header is inert).
   Collapse **defaults are recomputed every time the popover opens** — System
   and Selected Devices start expanded; Applications starts expanded **iff**
   at least one app currently has a non-"Current device" redirect
   (`routedAppCount > 0`), collapsed otherwise. Manual toggles during a
   popover session are transient UI state only — they are never persisted and
   are discarded the next time the popover opens.

   **Exact-fit, no-scrollbar popover.** The popover's `NSScrollView` was
   removed: the popover is always sized to exactly its content's fitting
   size — it grows and shrinks as cards collapse/expand, and **never shows a
   scrollbar**, matching the Control-Center reference (§9 intro). Resizing is
   driven through the documented `preferredContentSize` tracking channel (with
   an explicit `contentSize` fallback) and animated in a single
   `NSAnimationContext` group alongside each card's collapse animation, with a
   non-animated path for initial show and for Reduce Motion.

   Owning types: `AppRoutingController` (model/persistence logic, sibling of
   `GroupController`) and `AppRouteStore` (versioned-JSON persistence,
   `app-routes.json`) — see `AirPlayControllerCore/AGENTS.md` Key Types.
   `AppRowView` / `AddApplicationRowView` (`AirPlayControllerSharedUI`) render
   the rows; `PopoverController` wires the card and the running-app picker.

**Rules:**
- **Mute stays secondary** on device rows (session-preserving quick silence).
  Solo remains removed.
- **Master math unchanged:** proportional, ratios snapshotted at drag start,
  clamped at 100; masters echo member averages; every group row shows its master.
- **Phase 1 local-speaker rule:** the Mac's own speakers are selectable ALONE
  (= passthrough) but are BLOCKED from joining a mixed Selected Speakers set,
  with a short note ("synced everywhere-audio arrives with the new engine") —
  because pre-engine, local can't sync with AirPlay (~2s buffer; §8.1). The
  native engine's synced localOutput lifts this.
- Selecting a group/Selection in Main Out maps to OwnTone's output "selected"
  set (Phase 1) / the native engine's active output list (Phase 2).

### Group setup (REVISED 2026-07-13 — quick-create in menu, edit in window)

The original in-menu editor (menu swaps to a form with a name `NSTextField`) is
**not buildable**: Apple's docs state menu item views "receive all mouse
events … but keyboard events are not supported" — no typing during menu
tracking (see dev/notes/p1-menu-brief.md). Alec chose **quick-create**, REFINED 2026-07-13 after using the app (two gaps
found: no manual creation, and duplicate groups):

- **Manual creation is the PRIMARY path, in the window.** A "New Group"
  affordance (a "+" at the bottom of the sidebar source list, standard macOS
  pattern) opens the editor on an EMPTY group: name `NSTextField` + a checklist
  of ALL discovered devices to pick members + Save/Cancel. This is how you
  define "Downstairs = these two speakers" directly. Renaming, membership
  checkboxes, reorder, and "Delete group…" edit existing groups the same way.
- **Menu quick-create is a SHORTCUT only:** "Save current setup as group"
  captures the currently selected devices + volumes, auto-named. Secondary
  convenience, not the only path.
- **DEDUP / group identity (required):** a group is identified by its member
  SET (order-independent). The app must NOT create a duplicate group whose
  members equal an existing group's. Consequences:
  - When the current active output set exactly matches a saved group's members,
    the app recognizes THAT group as active (`activeGroupID` derived from the
    selection) — it does not treat it as a nameless ad-hoc selection.
  - The menu's "Save current setup as group" is HIDDEN/DISABLED when the current
    selection already equals a saved group (it's already that group); if it
    matches partially/differently it stays available.
  - `GroupController` gains member-set matching (find group by member set) and
    saveCurrentSetup dedups: identical set → resolve to the existing group
    (activate it), never a second copy.

### Applications routing view — main window, v2 (decided 2026-07-09)

A "Routing" section in the sidebar opens the Applications view: one row per
running audio app — icon + name from `NSWorkspace.shared.runningApplications` /
`NSRunningApplication.icon` (documented AppKit API) — with an `NSPopUpButton`
(pop-up style: "choose one from a set", shows current selection) offering:
each group, each individual speaker, and **"This Mac (don't stream)"**. A final
"Everything else" row sets the default destination (normally the active group).

**Routing audio model (decided with Alec):**
- **Overlaps mix.** Every speaker receives exactly one stream: the mix of all
  audio routed to any destination containing it. No exclusive claims, no
  "speaker busy" states. Requires per-app capture taps (Core Audio process
  taps support this directly) and a per-speaker mix stage before the sender.
- **Local bypass.** "This Mac (don't stream)" excludes an app from capture so
  it plays on the Mac's own output — calls stay local while music streams.

### Device row (shared by menu and window)
| Element | AppKit API | Documented usage we follow |
|---|---|---|
| Row container | `NSStackView` | Docs position it for "simple, linear layouts" without recycling — right for ≤10 rows (vs `NSTableView` for scrolling data grids, `NSCollectionView` explicitly overkill). |
| Device icon | `NSImage(systemSymbolName:variableValue:…)` | Speaker symbol; `variableValue` mirrors that device's volume. |
| Enable toggle | `NSSwitch`, mini size | HIG toggles: "within a grouped form, consider using a mini switch to control the setting in a single row" — sanctioned for per-device on/off. Never in toolbar/status areas (HIG). |
| Volume | `NSSlider(value:minValue:maxValue:target:action:)`, horizontal | `isContinuous = true` for live drag feedback (HIG sliders: live feedback required). Min at leading edge, speaker icons at ends per HIG. (HIG's "don't use a slider for volume" is iOS-only — macOS's own Sound menu is a slider.) |
| Mute / Solo | `NSButton`, `bezelStyle = .accessoryBar`, `setButtonType(.pushOnPushOff)` | `.accessoryBar` is documented for on/off-style buttons; NOT `NSSwitch` (HIG: switches only for emphasized settings, don't replace checkbox-like toggles). SF Symbols `speaker.slash.fill` / `headphones`. |
| Level meter | `NSLevelIndicator`, `.discreteCapacity` | Docs describe this style as "similar to audio level indicators in audio playback applications" — with `warningValue`/`criticalValue` for free green/yellow/red. Display-only. |

### Full window (Mixer)
| Element | AppKit API | Documented usage we follow |
|---|---|---|
| Window chrome | `NSWindow.toolbarStyle = .unified`, `styleMask` incl. `.fullSizeContentView` | Modern unified toolbar; use `contentLayoutGuide` to keep content clear of the titlebar. (`unifiedTitleAndToolbar` mask is deprecated/no-op.) |
| Toolbar | `NSToolbar(identifier:)` + delegate | `displayMode`, `autosavesConfiguration`. Hosts master-volume slider + presets control. |
| Sidebar | `NSSplitViewController` + `NSSplitViewItem.sidebar(withViewController:)` | Docs: this constructor automatically applies sidebar material/vibrancy and collapse behavior (`toggleSidebar(_:)`). |
| Sidebar list | `NSOutlineView`, source-list style | Hierarchy: saved groups → member devices, Finder-favorites style; `autosaveExpandedItems`. |
| Mixer pane | `NSStackView` of device rows | Same row component as the menu. Swap to `NSTableView` (`.inset` style, `usesAutomaticRowHeights`) only if the device list ever needs scrolling. |
| Presets picker | `NSPopUpButton` with `pullsDown = false` | Docs: pop-up (not pull-down) is for "choosing one item from a set" and shows the current selection. Saving/renaming presets are separate menu/toolbar actions, not mixed into the picker (pull-down semantics). |
| Master volume | `NSSlider`, horizontal, in toolbar | Speaker SF Symbols at both ends (HIG: icons at slider ends convey meaning). |
| Balance (v2) | `NSSlider` with `neutralValue` at center | `neutralValue` is the documented API for a centered rest point — exactly a balance control. Tick mark at center, `allowsTickMarkValuesOnly` off. |
| Appearance | System-adaptive; no forced `NSAppearance` | Docs: prefer semantic/asset-catalog colors so dark/light "just work"; override `appearance` only for branding — we don't. |

### Explicitly avoided (deprecated / HIG-contra)
- `NSStatusItem.view` / `.title` / `.image` (deprecated — use `.button`).
- `NSPopover` for the menu bar extra (HIG prefers a menu; revisit only if the
  menu proves genuinely too constrained).
- `NSVisualEffectView` legacy materials (`.light`, `.dark`, …) — semantic
  materials only, and `NSMenu`/sidebar supply their own automatically.
- Switches for mute/solo, switches in toolbars (HIG toggles).
- Cell-based `NSTableView` (view-based only).

---

*Next up: Phase 0d (per-device volume — one API call), then 0e (Core Audio
process-tap capture prototype) and 0f (end-to-end system audio → three speakers).*
