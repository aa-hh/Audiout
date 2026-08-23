# Design spec — iPhone Devices | Groups tab + device detail (2026-08-23)

Build-ready design for the new **Devices** tab from the decision record
(`mobile-device-list-decision-2026-08-23.md`). Slice 2 of the iOS work. This
is the design; a scoping pass turns it into a work order. Target branch:
`claude/ios-staging` (via a feature branch). Mode: **Operate**.

## Thesis

The Speakers tab is the live mixer — grab it while sound is playing. The
**Devices** tab is where you *manage* the things that make sound: read a
device's identity, pin it, shape its tone, and organise devices into groups.
Devices and Groups are two lists you switch between with a segmented control,
never one stacked list (the mistake we're fixing on the Mac too — roadmap 064).
The tab bar stays at four: **Speakers · Apps · Devices · Connection**.

The device-detail screen follows the Mac's own slot model (Identity /
Controls / Groups / About — `dev/notes/device-detail-framework-2026-08-22.md`)
so the two platforms read the same, with EQ as the page's one raised
"instrument" card and everything else bare with hairline dividers.

## Tab shell change (`RootView.swift`)

- `Tab.groups` → `Tab.devices`. `GroupsView(...)` tab item is replaced by
  `DevicesTabView(session:)`. Label **"Devices"**, working icon
  `hifispeaker.2` (open — see §Open decisions).
- `DevicesTabView` owns one `NavigationStack`. A segmented `Picker`
  (`.pickerStyle(.segmented)`, two cases **Devices | Groups**) sits in the
  nav bar as `ToolbarItem(placement: .principal)`. Selection is in-memory
  `@State`, default **Devices**.
- The trailing `+` (new group) toolbar item shows **only** while the Groups
  segment is active.

## Groups segment (absorbs the current `GroupsView`)

`GroupsView` today is `NavigationStack { List {…} .navigationTitle("Groups")
.toolbar { + } .sheet … }` (180 lines). Refactor: lift the `List`, the two
sheets, and the delete confirmation into a `GroupsSegment` subview that lives
**inside** the parent `NavigationStack` — drop its own `NavigationStack` and
`navigationTitle` (the segmented control is the title now), and surface its
`+` through the parent toolbar when active. `GroupRow`, the editor, and the
creation sheet are unchanged. No behaviour change — this is a re-host.

## Devices segment (new)

A `List` of every device the Mac reports, in `.insetGrouped` sections **by
type**, matching the Mac's Speakers-by-type overview:

| Section header | Contents |
|---|---|
| `AirPlay` | every device whose `kind` is an AirPlay kind (not bluetooth/cast), incl. `isLocalDevice` "This Mac" |
| `Bluetooth` | `kind == "bluetooth"` |
| `Cast` | `kind == "cast"` |

- A section is drawn only if it has ≥1 device (a pure-AirPlay home sees one
  section, no headers competing for space). Within a section: available
  devices first, then unavailable; alphabetical within each. This is a
  *management* list, so type-grouping + alpha is right here — unlike the
  Speakers tab, which stays cut by state.
- **Row:** the device's `iconSymbolName` glyph in a small halo (reuse the
  Speakers halo vocabulary at rest — no level arc here), `name`, a
  right-side availability word in the micro-label voice (`Ready` /
  `Unavailable`), a `Shaped` micro-label when EQ is non-flat, and a
  disclosure chevron. A pinned device shows a small filled star before the
  name. Tap → push `DeviceDetailView`.
- No faders here. Volume/mute stay on the Speakers tab (Live audio is
  high-stakes — the kill switches live on the control surface, not two taps
  into a settings list).

## Device detail screen (`DeviceDetailView`)

Pushed from a Devices-segment row. Slot order top→bottom, one raised card
(Tone) on a bare panel with hairline dividers:

1. **Identity** (bare header block)
   - Large halo + `iconSymbolName`; `name` as the title.
   - Type sub-label, sentence case (the app's own words): "AirPlay 2 speaker"
     (`supportsAirPlay2`), "AirPlay speaker", "Bluetooth speaker", "Google
     Cast", "This Mac" (`isLocalDevice`).
   - Status line: "Ready", "Unavailable", or the Mac's own
     `connection.failureHeadline` + `failureSuggestion` when failed (reuse
     the Speakers failure-card copy, read-only here).
   - **Cast only:** "Group of {n}" (needs `memberCount`, §Protocol) and
     "About {n} seconds of added delay" (needs `outputDelayMs`, §Protocol).
2. **Favourite** — a single toggle row, "Pin to Favourites" (writes the same
   phone-local `@AppStorage` pin set slice 1 introduced; this is the second,
   discoverable entry point the decision asked for).
3. **Tone** — the page's one raised instrument card. Bass, Treble, Balance,
   Loudness, Reset (§Tone). Requires the EQ protocol fields.
4. **In groups** (bare, read-only) — "In: Kitchen, Whole Floor", or "In no
   groups." Computed from `GroupState.memberIDs` already in the snapshot —
   **no new protocol**. A group name may deep-link to the Groups segment
   (nice-to-have, not required for v1).
5. **About** (quiet footer) — the honest facts: "Supports AirPlay 2." /
   "Shaped, so it won't sound identical to others in a group." / for This
   Mac, what routing to the Mac's own output means.

### Tone card (the instrument)

Simple tier only, bare numbers, no named presets (localization stance):

| Control | Range / readout |
|---|---|
| Bass | slider, −12…+12, readout `+4 dB` |
| Treble | slider, −12…+12, readout `−2 dB` |
| Balance | slider, L…R, readout `0` (or `L15` / `R15`) |
| Loudness | toggle |
| Reset | button, on the "Tone" title line (matches the Mac's placement, roadmap 059 note) |

- Below the card, only when bands are non-flat: "Also shaped with 10 bands on
  the Mac." — never editable on the phone (ten ±12 dB faders in a phone column
  fight the finger; the audience holding the phone is setting levels, not
  shaping a room — this is the settled split, see the Mac's own EQ-off-the-
  quick-surface decision).
- Writes are the live-scrub / commit split the Mac editor already uses
  (`setDeviceEQ(id:eq:committed:)`): `committed:false` while dragging,
  `committed:true` on release. Flat + committed IS reset (the Mac drops flat
  entries).

### Main Out tone
Not in this tab. Reached from the Speakers tab's Main Out deck menu → "Main
Out tone…", presenting the same Tone card for the whole mix
(`Snapshot.mainOutEQ` + `setMainOutEQ`).

## Wireframes — iPhone 15 Pro

### Devices segment — heavy (14 devices)
```
┌──────────────────────────────────────────────┐
│           [ Devices | Groups ]            +  │  ← segmented; + hidden here
│ AirPlay ──────────────────────────────────── │
│ ★ (◦) Kitchen HomePod          Ready      ›  │
│   (◦) Living Room Sonos   Shaped Ready    ›  │
│   (◦) Bedroom HomePod          Ready      ›  │
│   (◦) Apple TV                 Ready      ›  │
│   (◦) This Mac                 Ready      ›  │
│   (◦) Hallway AirPlay          Unavailable ›  │
│ Bluetooth ─────────────────────────────────  │
│   (◦) Office Speaker           Ready      ›  │
│ Cast ────────────────────────────────────── │
│   (◦) Downstairs        Group  Ready      ›  │
│   (◦) Study Nest Mini          Ready      ›  │
│   (◦) Kitchen Nest Hub         Unavailable ›  │
└──────────────────────────────────────────────┘
```

### Groups segment
```
┌──────────────────────────────────────────────┐
│           [ Devices | Groups ]            +  │
│  (▦) Kitchen              2 speakers      ›  │
│  (▦) Whole Floor          3 speakers      ›  │
│  (▦) Movie Night          2 speakers      ›  │
│                                              │
│  (empty) No groups yet. Tap + to make one    │
│          from your speakers.                 │
└──────────────────────────────────────────────┘
```
(Exactly today's `GroupsView`, re-hosted under the segment.)

### Device detail — AirPlay, shaped
```
┌──────────────────────────────────────────────┐
│  ‹ Devices                                   │
│                                              │
│            ( ◉ )   Living Room Sonos         │
│            AirPlay 2 speaker · Ready          │
│ ───────────────────────────────────────────  │
│  Pin to Favourites                     ( ●)  │
│ ───────────────────────────────────────────  │
│ ╭─ Tone ───────────────────────── Reset ──╮  │
│ │ Bass      ───────●────────        +4 dB  │  │
│ │ Treble    ────●───────────        −2 dB  │  │
│ │ Balance  L──────●─────────R          0   │  │
│ │ Loudness                          ( ●)   │  │
│ ╰──────────────────────────────────────────╯  │
│  Also shaped with 10 bands on the Mac.       │
│ ───────────────────────────────────────────  │
│  In groups                                   │
│  Living Room, Whole Floor                    │
│ ───────────────────────────────────────────  │
│  About                                       │
│  Shaped, so it won't sound identical to the  │
│  other speakers in a group.                  │
└──────────────────────────────────────────────┘
```

### Device detail — Cast group
```
│            ( ◉ )   Downstairs                │
│            Google Cast · Group of 3           │
│            About 2 seconds of added delay     │
│ ───────────────────────────────────────────  │
│  Pin to Favourites                     ( )   │
│ ───────────────────────────────────────────  │
│ ╭─ Tone ───────────────────────── Reset ──╮  │
│ │ … same four controls …                   │  │
│ ╰──────────────────────────────────────────╯  │
│  In groups   In no groups                     │
│  About  A Google Cast group. Its members are  │
│         set up in the Google Home app.        │
```

## Protocol prerequisites

| Need | Field / command | Already there? |
|---|---|---|
| Tone card | `DeviceState.eq {bassDB,trebleDB,balance,loudness,bandsAreFlat}`, `Snapshot.mainOutEQ`, `setDeviceEQ(id:eq:committed:)`, `setMainOutEQ(eq:committed:)` | **New** (simple tier only; phone never writes a band) |
| `Shaped` mark, Tone | `bandsAreFlat` (part of `eq`) | via `eq` |
| Cast "Group of n" | `DeviceState.memberCount: Int?` | **New** |
| Cast delay line | `DeviceState.outputDelayMs: Int?` | **New** |
| "In groups" | `GroupState.memberIDs` | **Present — free** |
| Identity, status, pin | `name/kind/supportsAirPlay2/isLocalDevice/isAvailable/connection`, `@AppStorage` pins | **Present** |

Mac persists nothing new — `DeviceEQ`/`DeviceEQStore` already store per-device
and Main Out. Mac work is snapshot-builder mapping + two dispatcher cases.

## Gesture / navigation map

| Surface | Gesture | Result |
|---|---|---|
| Segmented control | tap | switch Devices ⇄ Groups |
| Devices row | tap | push `DeviceDetailView` |
| Groups row | tap | present the group editor (unchanged) |
| Toolbar `+` (Groups only) | tap | new-group sheet (unchanged) |
| Tone slider | drag / release | `setDeviceEQ` committed:false / true |
| Pin toggle | tap | write phone-local pin set |

## States, accessibility, voice

- **Empty:** no devices → "No devices. Connect to a Mac to manage speakers
  and groups." (mirrors the Speakers empty state). Groups empty → today's
  copy.
- **Dynamic Type to AX3:** a `List` handles growth; the Tone card's rows
  stack label-over-slider at accessibility sizes; the segmented control is a
  standard control that adapts. Nothing is fixed-width.
- **VoiceOver:** rows read "name, type, ready/unavailable, shaped, button";
  the star is folded into the row value ("Favourite"), not a lone element;
  the segmented control announces the selected segment; Tone sliders are
  adjustable with dB values from the same source the label draws.
- **Voice: One Case (sentence case), the live iOS rule** (DESIGN.md, PR #36 /
  roadmap 059 — the all-caps monospaced micro-voice was retired). Every
  string is authored sentence case and never transformed: section headers
  read "AirPlay", state words read "Ready"/"Unavailable"/"Shaped"/"Group",
  slot headers read "Tone"/"In groups"/"About". Set `.textCase(nil)` on List
  sections so iOS does not auto-uppercase them. Numeric readouts use tabular
  digits (`.monospacedDigit()`), never a monospaced face.
- **Reduce Motion:** the push and segment switch honour it (no custom
  transitions beyond the system's).

## Cost (design → build)

| Piece | Protocol? | Rough days |
|---|---|---|
| Tab shell swap + segmented control + re-host GroupsView | none | 1 |
| Devices segment (sections by type, rows, empty state) | none | 1.5 |
| `DeviceDetailView` identity + pin + "In groups" + About | none | 1.5 |
| Tone card + EQ protocol both sides + `Shaped` mark + Main Out tone menu item | yes | 2.5 |
| Cast identity (memberCount, outputDelayMs) | yes (gated on 006) | 0.5 |
| VoiceOver + Dynamic Type + phone live pass | — | 1 |

≈ 8 days. The first three rows (no protocol) ship a usable Devices|Groups tab
before any EQ wiring — a natural sub-slice.

## Open decisions (for Alec)

1. **Tab label.** "Devices" holding both Devices and Groups risks reading as
   a near-synonym of the "Speakers" tab (Speakers = live control; Devices =
   manage). Alternatives: "Manage", "Setup", "Library". Recommend keeping
   **Devices** and letting the Speakers-vs-Devices split be *control vs
   manage*; decide the word.
2. **Tab icon** for the merged tab (`hifispeaker.2`? `slider.horizontal.3`?).
3. **Does the detail show volume/mute at all**, or stay settings-only?
   Recommend settings-only — the fader lives on Speakers.
4. **Deep-link** from a detail's "In groups" name to the Groups segment —
   v1 or later? Recommend later.
