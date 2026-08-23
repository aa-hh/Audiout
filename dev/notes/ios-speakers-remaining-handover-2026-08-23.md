# Handover — iPhone Speakers/Devices redesign, what's left (2026-08-23)

Written for someone with **no access to the conversation that produced it.**
It tracks the whole plan (slices 1–3), marks what's built, and details
everything remaining. The design decisions are fixed; this is execution.

## The plan in one paragraph

Cast (roadmap 006) and Bluetooth roughly double the phone's speaker list, and
the Mac's per-device EQ has no phone home. The fix, decided with Alec on
2026-08-23 (`dev/notes/mobile-device-list-decision-2026-08-23.md`), is three
slices: **(1)** filter chips + phone-local favourites + collapse Unavailable
on the existing Speakers tab; **(2)** a new **Devices** tab that absorbs Groups
under a segmented control and adds a per-device detail screen with simple-tier
EQ; **(3)** a Cast delay banner + the `Starting…` state + one bug fix. Rejected
alternatives and rationale are in the decision record; the full slice-2 design
is `dev/notes/ios-devices-tab-design-2026-08-23.md`.

## Branches & worktrees (READ FIRST)

- iOS work lives on `claude/ios-staging`, **which merges to `main` as one unit
  later on Alec's go-ahead** — never per-branch. `main` has no `ios/`.
- **Branch every iOS feature from `origin/claude/ios-staging`, not the local
  `claude/ios-staging` worktree** — the local worktree has been seen running
  *behind* origin (e.g. missing the One Case voice, PR #36). Verify with
  `git rev-list local..origin`.
- Slice 1 **is merged** into ios-staging (PR #40, origin `0ecf10e3`); its
  worktree `.claude/worktrees/ios-speakers-chips-pins` is marked `.prunable`.
- Do iOS feature work in its own worktree branched from origin ios-staging;
  merge finished, phone-verified slices into ios-staging on Alec's word.

## Status

| Slice | State | Verify owed |
|---|---|---|
| 1 — chips + pins + collapse Unavailable | **MERGED** to ios-staging (PR #40, `0ecf10e3`); phone-tested, Alec go-ahead | done — one refinement moved to slice 2 (below) |
| 2 — Devices\|Groups tab + device detail + EQ | **Designed, not built** | — |
| 3 — Cast banner + `Starting…` + echo-timeout fix | **Designed, not built**; gated on 006 landing on ios-staging | — |

## The One Case voice (binds everything below)

iOS uses **sentence case, never all-caps, no monospaced face** (DESIGN.md /
PR #36 / roadmap 059). Section headers read "AirPlay", state words read
"Ready"/"Unavailable"/"Shaped". Set `.textCase(nil)` on `List` sections so iOS
doesn't auto-uppercase them. Numbers use `.monospacedDigit()`, not a mono face.

## Slice 2 — remaining work

Full design + wireframes: `dev/notes/ios-devices-tab-design-2026-08-23.md`.
Build order (the first three rows need **no protocol change** and ship a usable
tab on their own):

1. **Tab shell** (`ios/AudiouterRemote/AudiouterRemote/RootView.swift`).
   `Tab.groups` → `Tab.devices`; replace the `GroupsView` tab item with a new
   `DevicesTabView(session:)`. One `NavigationStack`; a segmented `Picker`
   (Devices | Groups) as `ToolbarItem(placement: .principal)`, default
   Devices, selection in-memory. The `+` (new group) toolbar item shows only
   under the Groups segment. Label "Devices" (see open decisions), icon TBD.
2. **Re-host Groups** (`UI/Groups/GroupsView.swift`, 180 lines). Lift its
   `List` + two sheets + delete confirmation into a `GroupsSegment` subview
   inside the parent stack; drop its own `NavigationStack`/`navigationTitle`;
   route its `+` through the parent toolbar. `GroupRow`, editor, creation
   sheet unchanged. **No behaviour change** — pure re-host.
3. **Devices segment** (new). `List`, `.insetGrouped`, sections by type
   (AirPlay / Bluetooth / Cast), drawn only when non-empty, `.textCase(nil)`.
   Row: halo + `iconSymbolName`, name, right-side "Ready"/"Unavailable",
   "Shaped" when EQ non-flat, star if pinned, chevron → push `DeviceDetailView`.
   Available-first then alphabetical. No faders here.
4. **Device detail** (`DeviceDetailView`, new). Slot model: Identity · Pin ·
   Tone card · In groups · About (see the spec for exact copy). Identity, the
   Pin toggle, and "In groups" (from `GroupState.memberIDs`) need **no
   protocol**. Ship these before EQ if useful.
5. **Tone card + EQ wiring** (needs protocol, below). Bass/Treble/Balance/
   Loudness/Reset, bare numbers; live-scrub vs commit split; "Also shaped with
   10 bands on the Mac" line when bands non-flat; the `Shaped` row mark.
   Main Out tone via the Speakers deck menu ("Main Out tone…").
6. **A11y/Dynamic Type/phone pass.**

### Slice-1 refinement (from Alec's phone test, 2026-08-23)

- **On pin-add, switch the active chip to Favourites.** Today, favouriting a
  row (long-press → Pin) re-sorts it but the view stays on the current chip, so
  the item can move/scroll and the pin feels like it made the item *disappear*.
  Fix: when a pin is **added**, set the active chip to `Favourites` (the
  Favourites chip becomes visible on the first pin, so switch to it then) so the
  just-pinned item stays on screen and the action is confirmed. On **unpin**, no
  forced switch. Announce the switch for VoiceOver. Small change to the slice-1
  chip/pin code in `SpeakersView.swift` / `DeviceRowView.swift`; Alec placed it
  in slice 2.

### Protocol delta slice 2 needs (`AudiouterProtocol`, all additive/optional)

| Field / command | Where | For |
|---|---|---|
| `eq: EQSummary?` where `EQSummary = {bassDB, trebleDB, balance: Double, loudness: Bool, bandsAreFlat: Bool}` | `DeviceState`, and `mainOutEQ: EQSummary?` on `Snapshot` | Tone card, `Shaped` mark |
| `setDeviceEQ(id:eq:committed:)`, `setMainOutEQ(eq:committed:)` | `CompanionCommand` | write tone (simple tier only; phone never writes a band). Flat + `committed:true` = reset |
| `memberCount: Int?` | `DeviceState` | Cast "Group of n" |
| `outputDelayMs: Int?` | `DeviceState` | Cast delay line (also feeds slice 3's banner) |

`EQSummary` must be its own type in `AudiouterProtocol` (iOS may never depend on
`AudiouterCore` — `ios/AGENTS.md`); the Mac maps `DeviceEQ` ↔ `EQSummary`. Mac
persists nothing new — `DeviceEQ`/`DeviceEQStore` already store per-device and
Main Out; Mac work is snapshot-builder mapping + two dispatcher cases. Keep the
band array **off** the wire — only `bandsAreFlat` crosses.

## Slice 3 — remaining work (gated on 006 reaching ios-staging)

1. **Cast delay banner.** One `StatusBanners` entry at the top of the Speakers
   list, shown only while any Cast output is live (drive off `outputDelayMs`
   present on a selected device). Copy, sentence case, the Mac's own number:
   "Cast is reporting a {n}-second delay, so everything waits to stay in sync.
   Give it a moment." Never per-row.
2. **`Starting…` state.** During the ~8 s Cast first-play, the row shows
   "Starting…" with the existing dashed connecting ring; row does not claim
   "Playing" until sound starts.
3. **Echo-timeout bug fix (confirmed).**
   `DeviceRowView.pendingSelection` times out after 2 s
   (`Task.sleep(for: .seconds(2))`, ~`DeviceRowView.swift:350`) — shorter than
   Cast's ~8 s. Change the bound to hold until a snapshot moves
   `isMainOutMember`, or the Mac reports the start ended — not a fixed 2 s.
   This is worth its own roadmap note under 006 if not folded into this slice.

## Open decisions (Alec)

1. **Tab label** — "Devices" (holds Devices|Groups) vs "Manage"/"Setup"/
   "Library". Recommend "Devices" (Speakers = control, Devices = manage).
2. **Tab icon** for the merged tab.
3. Detail shows volume/mute, or stays settings-only? Recommend settings-only.
4. "In groups" name deep-links to the Groups segment — v1 or later? Later.

## Related roadmap

- **063** — sync pinned favourites through the Mac (pins are phone-local now;
  two phones showing different favourites will read as a bug). High priority
  after slice 1 ships.
- **064** — Mac Groups window: split Groups and Speakers (same disease, Mac
  side). Separate work; do not fold into iOS.

## How to verify (the only real check)

Physical iPhone 15 Pro, always (`ios/AGENTS.md`). From the feature worktree:
`bash scripts/ios.sh device` builds, signs, installs to the phone (phone
connected + unlocked; first run on a new signing identity needs the cert
trusted once under Settings › General › VPN & Device Management). `ios.sh
build` is compile-only and proves nothing about behaviour. End-to-end
checklist: `dev/notes/companion-live-test-checklist.md`.
