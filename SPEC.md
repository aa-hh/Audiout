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
| Distribution | **Direct download, personal use** | No App Store constraints; robustness bar is "works well for me", not "ship to strangers". |
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
   it can't be signal-managed by the user — below our bar.)
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
- [ ] **0d — Per-device volume.** Change one speaker's volume independently via
  OwnTone's JSON API (`PUT /api/outputs/{id}` with `{"volume": N}`). *Confirms the
  core control primitive.* (Near-certain to work — the API exposes per-output
  volume directly and OwnTone already sent distinct volumes per device in logs.)
- [ ] **0e — Capture system audio.** Prototype a Core Audio process tap (macOS
  14.4+) *and/or* install BlackHole; verify we can grab all system output as PCM.
  *Confirms the capture layer.*
- [ ] **0f — End-to-end.** Wire capture → sender: play Spotify on the Mac, hear it
  come out of all three speakers in sync. *This is the whole product in miniature.*

If 0a–0f all pass, we know the product is buildable and move to Phase 1 (the real
app + UI). If 0e or 0f fights us, we reassess the capture approach before investing
in UI.

**Open decision for Phase 0:** do we build the sender *on top of* OwnTone (faster,
but a heavier dependency to embed later) or extract just its AirPlay 2 sender code
into a Swift-friendly library (more work, cleaner final app)? We can defer this —
the spike can use OwnTone as-is to validate, then decide.

---

---

## 9. UI design — pure AppKit, documentation-grounded

**Standing rule (from Alec, 2026-07-09): every UI element must be an actual
documented AppKit control, looked up at
https://developer.apple.com/documentation/AppKit and used/styled exactly as its
documentation and the macOS HIG specify.** Doc URLs below are
`developer.apple.com/documentation/appkit/<class>`.

Decisions: **pure AppKit** (no SwiftUI) · menu-bar extra opens a **true NSMenu**
(HIG: "Display a menu — not a popover — when people click your menu bar extra")
· full window is **sidebar + mixer** · volume is **horizontal rows** (the
system Sound-menu pattern).

### Menu bar extra
| Element | AppKit API | Documented usage we follow |
|---|---|---|
| Status item | `NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)` | Never init `NSStatusItem` directly; customize only via its `button` property (`view`/`title`/`image` on the item are deprecated). Provide a user setting to hide it (HIG). |
| Status icon | `NSImage(systemSymbolName:variableValue:accessibilityDescription:)` | SF Symbol `speaker.wave.3.fill` with `variableValue` = master volume, so the waves fill with level. Template rendering → correct in dark/light menu bar. |
| Dropdown | `NSMenu` + `NSMenuItem.view` | The system Sound-menu pattern: each row is a custom `NSView` assigned to `NSMenuItem.view` (docs: the view then owns all drawing; key equivalents still work). Action items are plain `NSMenuItem`s below a separator. |

### Groups in the menu (decided 2026-07-09)

Groups are first-class in the dropdown — the menu is usable without ever opening
the mixer window. Menu structure, top to bottom:

1. **Groups section.** One row per saved group: chevron (`NSButton`, SF Symbol
   `chevron.right`/`chevron.down`), group name, numeric readout, and a
   **group master slider**. The *active* group shows its slider; inactive groups
   collapse to a single line.
2. **Expansion.** Clicking the chevron expands the group in place, inserting one
   indented device row (`NSMenuItem` + custom view) per member — icon, name,
   individual slider, mute button. Collapse removes them. (Menu items are
   inserted/removed live; verify NSMenu tolerates mutation while open during
   Phase 1 — fallback is `menuNeedsUpdate`.)
3. **Devices section.** Ungrouped speakers each get their own row below the
   groups — everything on the network is reachable from the menu.
4. **Actions.** Separator, then plain items: "Save current setup as group…",
   "Open mixer…".

**Interaction model:**
- **One active group at a time.** Activating a group switches the output set to
  exactly its members (groups behave like output presets — matches the single
  stream → one target-set pipeline). With v2 per-app routing, "active group"
  remains the destination for *default* (unrouted) system audio.
- **Master is proportional.** Dragging the group master scales members while
  preserving their relative balance (ratios snapshotted at drag start; clamped
  at 100).
- **Master echoes.** Adjusting an individual member updates the group master to
  the members' average, so the master is always an honest readout.

### Group setup in the menu (decided 2026-07-09)

Creating and editing groups must be possible entirely from the menu bar extra —
the mixer window is never required. Doc-grounded: `NSMenuItem.view` hosts any
view (Apple's own Help menu embeds a live search field the same way).

- **Entry points:** a "New group…" item in the actions section; a pencil
  `NSButton` revealed on hover of each group row for editing it.
- **Editor mode:** the menu content swaps in place to an editor: back arrow +
  title row, group-name `NSTextField` (placeholder is an example name, HIG),
  a "Speakers" section listing every discovered device with a **checkbox**
  (`NSButton(checkboxWithTitle:)` — HIG toggles: checkboxes for multi-select
  lists, not switches), then Cancel / Save buttons. Editing an existing group
  adds "Delete group…".
- Saving from the current state ("Save current setup as group…") captures the
  live device set + volumes as a new group.

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
