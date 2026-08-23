# Decision — iPhone Speakers tab, Devices tab, Cast banner (2026-08-23)

Alec's verdict on the three proposals in
`mobile-device-list-proposal-{A,B,C}-2026-08-23.md`. Supersedes the brief's
anti-goals where it says so. This is what gets scoped and built on
`claude/ios-staging`.

## Rejected

| Idea | From | Why not |
|---|---|---|
| Inferred "most used" ordering | A | Alec won't stand behind an invisible score deciding the order. |
| User-chosen sort (name / recent / Mac order) | C | No sorting controls at all. |
| Rooms/groups as the first screen | B | Groups stay a feature, not the structure, unless adoption turns out huge. |
| Delay mark or number on a device row | C | Reads as the per-device trim delay, not the Cast delay. |

## Decided

> **Voice note (corrected 2026-08-23):** iOS uses the **One Case** rule —
> sentence case, never all-caps, no monospaced face (DESIGN.md, PR #36 /
> roadmap 059). The ALL-CAPS chip and state names written below (`ALL`,
> `FAVOURITES`, `STARTING…`, etc.) are **notation only**; the real glyphs are
> sentence case: `All · Favourites · AirPlay · Bluetooth · Cast`, `Starting…`,
> `Playing`/`Ready`/`Unavailable`. Slice 1 shipped this way.


### Speakers tab
- Sections stay by state: **PLAYING · READY · UNAVAILABLE** (collapsed with count). Playing speakers and their mute stay at the top, always.
- **Chip row directly under PLAYING**, scrolls with the list:
  `ALL · FAVOURITES · AIRPLAY · BLUETOOTH · CAST`. Default ALL. A chip filters
  READY and UNAVAILABLE only; PLAYING is never filtered. Chips whose type has
  no devices are not drawn (the 3-AirPlay household sees `ALL · FAVOURITES`
  at most — and if nothing is pinned, no chip row at all).
- **Favourites = pins.** Under ALL, pinned speakers sort to the top of
  READY. Set/unset from the device's detail screen (Devices tab) and from the
  row's long-press. Pins are **phone-local** (`@AppStorage`) for now —
  roadmap **063** syncs them through the Mac, high priority, because two
  phones showing different favourites will read as a bug.
- No transport headings, no search, no sort menu, no "hide unavailable"
  toggle. Chip selection resets to ALL on each launch (a filter left on is a
  lie about the system — research anti-pattern).
- **On pinning a device, switch the chip to Favourites** so the just-pinned
  row stays visible (added 2026-08-23 after phone testing — pinning otherwise
  reads as the item disappearing). Slice 2.

### Devices tab (replaces the Groups tab)
- The Groups tab becomes **Devices**, with a segmented control at the top:
  **Devices | Groups**. Mirrors the Mac, whose Groups window holds both the
  groups list and the device detail pane. Tab bar stays at four:
  **Speakers · Apps · Devices · Connection**. The existing Groups list and
  editor move under the Groups segment unchanged. (Alec, 2026-08-23 —
  supersedes the five-tab version above.) Tab name open: "Devices" is the
  working label; the segment names are the real labels.
- **Mac counterpart: roadmap 064.** The Mac Groups window stacks Groups and
  Speakers in one sidebar and buries Groups at scale; 064 splits them the same
  way. Separate work, Mac-side — do not fold into the iOS branch.
- Devices list: every device the Mac knows, grouped by type (AirPlay,
  Bluetooth, Cast), name + type + availability. Tap → **device detail**.
- Device detail: identity (name, type, what the Mac knows — AirPlay 2 or
  not, Cast group member count, added delay); **Pin to Favourites**; **Tone**
  — Bass, Treble, Balance (±12 dB / −1…+1, bare numbers), Loudness on/off,
  Reset. The 10 bands are a read-only line: "Also shaped with 10 bands on the
  Mac." Main Out tone reachable from the Main Out deck's menu, same controls.
- Protocol (all optional, additive): `DeviceState.eq` = `{bassDB, trebleDB,
  balance, loudness, bandsAreFlat}`, `Snapshot.mainOutEQ`, commands
  `setDeviceEQ` / `setMainOutEQ` (simple tier only; the phone can never write
  a band), `DeviceState.outputDelayMs`. Mac persists nothing new — `DeviceEQ`
  already does.
- A shaped speaker shows one small mark on its Speakers row, spoken as
  "Shaped" by VoiceOver; never a readout.

### Cast
- **One banner** at the top of the Speakers list while any Cast output is
  live, existing `label2` status-banner style. Plain speech, the Mac's own
  number: *"Cast is reporting a {n}-second delay, so everything waits to
  stay in sync. Give it a moment."* Never a per-row number or mark (the
  trim-delay confusion).
- First play: the row reads `STARTING…` with the dashed connecting ring for
  the whole ~8 s wait. Bug to fix with it: `DeviceRowView.pendingSelection`
  times out after 2 s (`Task.sleep(for: .seconds(2))`, DeviceRowView.swift:350)
  — the echo must hold until a snapshot moves `isMainOutMember` or the Mac
  reports the start ended.
- Cast group = one row, `GROUP n` in the sub-label; never also its members.

## Open (decide at scoping)
- Does the FAVOURITES chip remember itself across launches as the one
  exception to "reset to ALL"? Default here: no.
- Tab label for the merged Devices | Groups tab.

## Order of work
1. Chips + pins (phone-local) + UNAVAILABLE collapsed — no protocol change.
2. Devices tab + detail + EQ simple tier + shaped mark — protocol fields above.
3. Cast banner + `STARTING…` + the 2 s echo fix — gated on 006 landing.
