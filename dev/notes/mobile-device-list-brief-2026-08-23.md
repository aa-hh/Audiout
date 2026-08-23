# Brief — iPhone Speakers tab: room for Cast, a home for EQ (2026-08-23)

Shape brief for three divergent proposals. Shared ground; each proposal gets
its own lens (see "Lenses" at the end). No code.

## 1. Job and audience

- **Surface:** the iPhone companion's Speakers tab (and whatever it needs to
  reach). Mode: **Operate** — the phone is the remote you grab while sound is
  already playing in another room.
- **Who:** a household member, often not the person who set the Mac up.
  Dinner party, kid asleep upstairs, speaker blasting in the kitchen. One hand,
  a few seconds, no audio vocabulary.
- **The problem:** Cast support (roadmap 006) and Bluetooth roughly double the
  speaker count a typical home shows. The list already carries three sections
  (PLAYING / READY / UNAVAILABLE) and each row is tall because the row *is*
  the fader. The Mac's per-device EQ has no phone home at all.

## 2. Outcome and proof

Primary task, in order: (1) find *my* speaker and change its level or mute it
in one gesture; (2) start/stop a speaker; (3) everything else. Success = the
three speakers a household actually uses are reachable without scrolling on a
14-device list, and nothing about that costs the 3-device household anything.

Secondary outcome: a user who touched EQ on the Mac can see that a speaker is
"shaped" from the phone and, at minimum, knows where to change it.

## 3. What exists (read before proposing)

- `ios/AudiouterRemote/AudiouterRemote/UI/Speakers/SpeakersView.swift`,
  `DeviceRowView.swift`, `MainOutPicker.swift`, `StatusBanners.swift` on the
  `claude/ios-staging` branch (worktree `.claude/worktrees/ios-staging`).
  `ios/AudiouterRemote/DESIGN.md` is the visual contract ("Warm Signal under
  Liquid Glass"); `ios/AGENTS.md` has the rules.
- One list, three collapsible sections by *state*, never by transport
  (PINNED and BLUETOOTH headings were explicitly removed — see the comment
  above `sections` in SpeakersView). Floating frosted Main Out deck.
- Row gestures already spent: **tap** = play/stop, **horizontal drag** =
  volume, **vertical** = scroll. Mute is a 28pt overlay on sounding rows.
  **Free:** long-press, leading/trailing swipe, a trailing accessory, the
  section header, the Main Out deck's menu, toolbar.
- Protocol (`AudiouterProtocol/Sources/AudiouterProtocol/CompanionSnapshot.swift`):
  `DeviceState` has `kind: String`, `iconSymbolName`, `isAvailable`,
  `supportsAirPlay2`, `volume`, `isMuted`, `isSelected`, `isMainOutMember`,
  `connection`. **No** pin/favourite, **no** EQ, **no** "last used", **no**
  latency/delay field. Cast will arrive as `kind == "cast"` (Mac side:
  `Device.Kind.cast`). The phone renders the Mac's snapshot and never invents
  state; UI *preferences* (what's hidden, pinned, collapsed) are allowed to be
  phone-local via `@AppStorage`.
- Mac EQ (`AudiouterCore/Sources/AudiouterCore/DeviceEQ.swift`): two tiers
  that both apply — simple (Bass ±12 dB, Treble ±12 dB, Balance −1…+1,
  Loudness on/off) and a 10-band graphic (31.5 Hz…16 kHz, ±12 dB). Per
  device and for Main Out. `isFlat` exists. On the Mac it lives only on the
  Groups window's device detail pane — the menu-bar popover deliberately has
  none. Research behind that placement: `dev/notes/eq-rendering-research-2026-08-22.md`.
- Cast facts that may need to show: ~2 s fixed delay (everything else is
  delayed to match), ~8 s first-play wait, a Cast *group* arrives as one
  device. Source: `dev/notes/006-cast-output-scope-2026-08-22.md`.
- Peer-app research (patterns, anti-patterns, evidence):
  `dev/notes/mobile-device-list-research-2026-08-23.md`.

## 4. Scope and boundaries

- **In:** the Speakers tab's list, its sections, rows, any new detail
  surface, the Main Out deck, and any phone-side preference. Protocol
  additions are allowed if the proposal argues they earn their keep (say
  exactly which fields, and what the Mac must persist).
- **Fidelity:** proposal, not code — IA, screen-by-screen description, ASCII
  wireframes for the named states, gesture map, protocol delta, cost.
- **Untouched:** the row-is-the-fader interaction, the tap/drag gesture
  assignments, mute one gesture away on any sounding row, Main Out always
  visible, the Warm Signal palette and micro-label voice, HIG structure,
  44 pt targets, Dynamic Type, VoiceOver parity, Reduce Motion.
- **Anti-goals:** a Bluetooth/Cast/AirPlay heading (transport is not what
  anyone scans for); burying mute or Main Out behind a tap (Sonos 2024's
  sin); named EQ presets ("Rock", "Jazz") — bare numbers only; a second
  "Devices" tab; any claim of an installed base.

## 5. States and ranges

Every proposal shows these, with the same fixtures so they compare:

| State | Fixture |
|---|---|
| Typical | 6 devices: 2 HomePods, Apple TV, a Sonos (AirPlay), a Bluetooth speaker, this Mac. 2 playing. |
| Heavy | 14 devices: the 6 above + 5 Cast (2 Nest minis, Nest Hub, Chromecast, a Cast group "Downstairs"), 2 more AirPlay, 1 more BT. 3 playing, 4 unavailable, 1 failed. |
| First run | Just connected, nothing playing, gesture coach showing. |
| EQ shaped | A speaker with non-flat EQ, playing. |
| Cast starting | A Cast device tapped; ~8 s before sound. |

Ranges: 1–20 devices; 0–6 playing; 0–10 unavailable (Cast devices disappear
often); names up to ~30 chars; Dynamic Type up to AX3 must still work.

## 6. Interaction and layout — what a proposal must answer

1. **Ordering & priority:** what's on screen without scrolling for the
   Heavy fixture? Pins/favourites, recency, most-used, auto-collapse, hide
   unavailable — which, and who sets it (user, inferred, or both)?
2. **Preference home:** each preference is phone-local or in the protocol —
   say which and why (a pin that's different on two phones in one house may
   be correct or may be a bug; decide).
3. **Cast specifics:** where the ~2 s delay and the ~8 s first-play wait
   show, if at all; how a Cast group is distinguished from a saved
   Audiouter group; whether Cast rows look any different.
4. **EQ:** where it lives (inline, long-press sheet, detail screen, Main Out
   deck, "on the Mac only" with a pointer), which tier (simple only, both,
   none), how a shaped row is marked, per-device vs Main Out. Honour the
   Mac's own decision to keep EQ out of the quick surface — or argue why the
   phone differs.
5. **Gesture map:** a table of every gesture on the row, section header, and
   deck after the proposal — no collisions, no gesture without a visible
   affordance or a coach.
6. **Failure modes:** what breaks for the 3-device household; for the
   20-device venue; at AX3 type; with VoiceOver.
7. **Cost:** new screens, new protocol fields, Mac-side persistence, rough
   effort in days, and what can ship first.

## 7. Constraints and open decisions (decide, don't dodge)

- Binding: iOS 18+, SwiftUI, iPhone-only; PRODUCT.md voice rule (console
  labels on chrome, plain speech on anything acted on); snapshot is truth.
- Open, and proposals may answer differently: should the 10-band EQ ever be
  on the phone; should pins sync through the Mac; is "hide unavailable" a
  toggle, a default, or automatic after N days unseen; does the phone need
  search at all below ~15 devices.

## Lenses — one per proposal

Each agent takes one lens and commits to it fully. Do not hedge toward the
others; the point is distance between the three.

- **A — Fewest gestures for the household.** The phone is the dinner-party
  remote. Optimise ruthlessly for the 2–3 speakers a person actually uses;
  everything else earns its pixels or leaves. Prefer inferred priority
  (recency, most used) over asking. EQ is a secondary place, simple tier at
  most — the phone is for levels, the Mac is for shaping.
- **B — Rooms first.** People think in rooms and groups, not devices.
  Restructure so the first screen is places (Audiouter groups, Cast groups,
  single rooms) and devices are one level down — while keeping a sounding
  speaker's mute and level one gesture away. EQ lives with the place.
- **C — The console.** Lean into the mixer. Everything visible, dense
  rows, filter/sort controls, search, swipe actions; full EQ (both tiers)
  reachable from the phone because the audiophile audience will ask. Prove
  density doesn't cost the 3-device household.

## Deliverable per proposal

`dev/notes/mobile-device-list-proposal-<A|B|C>-2026-08-23.md`, 150–300
lines: one-paragraph thesis, IA, ASCII wireframes for the five fixture
states (iPhone 15 Pro width, ~20 rows tall), the gesture table, the
preference/protocol table, Cast and EQ answers, failure modes, cost, and
three things the other two lenses will get right that this one gives up.
