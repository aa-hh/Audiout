# Proposal B — Rooms first (2026-08-23)

## Thesis

A household member does not reach for the phone to adjust *a device*; they reach
for it because *a room is too loud*. So the first screen becomes a list of
**places** — the Mac's saved groups, a Cast group (which arrives as one device),
and any speaker in no group, which is its own place. Not a drill-down: the
compression is paid for entirely by the **silent** places, because a place making
sound always shows its speakers inline, each with today's fader and mute. One
rule carries the design — **if you can hear it, you can touch it without a tap**
— and it is structural, not discipline: a sounding place has no collapse control
at all. `GroupState` already carries `masterVolume` and `isMuted`, so a place row
is a real fader over a real gain stage rather than a summary; pointing Main Out
at a group stops being a refusal a speaker row must explain and becomes what a
tap on a room obviously does; and unavailable speakers and Cast's delays are
answered where someone can act on them. Groups tab absorbed, tab bar 4 → 3.

## Information architecture

| Level | What it is | How you get there |
|---|---|---|
| Tab **Places** (was Speakers) | Every place, in three sections | Tab bar |
| Inline member rows | The speakers of a *sounding* place | Automatic — never a gesture |
| **Place sheet** | Members, tone, rename, icon, delete | Long-press the place row, or its `⋯` |
| **Speaker sheet** | One speaker's tone + info | Long-press a member row, or its `⋯` |
| Main Out deck | Unchanged, floating, always visible | Always on screen |
| ~~Tab **Groups**~~ | **Absorbed** — its list is this screen, its editor is the Place sheet's Members section, its `+` moves to the toolbar | — |

**Three kinds of place, one row grammar.**

| Kind | Fader drives | Mute writes | Members shown |
|---|---|---|---|
| Group place (saved Audiouter group) | `GroupState.masterVolume` | `setGroupMuted` | Yes, when sounding |
| Speaker place (device in no group) | `DeviceState.volume` | `setDeviceMuted` | n/a — it is one speaker |
| Cast group place (`kind == "cast"`, one device to us) | `DeviceState.volume` | `setDeviceMuted` | **Never** — the Mac cannot see inside it |

**Named rules.**

- **The Sounding Rule.** A place with any speaker making sound is expanded and
  has no chevron while it sounds, so every sounding speaker's fader and mute
  are on screen one, always. The Sonos 2024 sin (hold the group slider to reach
  room volume) made impossible rather than merely avoided.
- **One row per speaker.** In a group → under that group only; in no group →
  its own place row. Never both (the Spotify Cast artefact, research ⛔15).
- **A place is away only when all of it is.** One missing member is a clause on
  the place row (`1 AWAY`), not a row in AWAY.

**Sections** — three, always present, same honesty argument as today's:

| Section | Contents | Default |
|---|---|---|
| `SOUNDING` | Places with any sounding member, Mac's order | Expanded, uncollapsible while non-empty |
| `PLACES` | Group places in the Mac's group order, then speaker places in its device order | Expanded |
| `AWAY n` | Places whose every member is unavailable | **Collapsed**, count in the header |

**No pins, no sort menu, no search, no filter chips.** Grouping *is* the
ordering answer — the household already told the Mac which speakers belong
together. A second, phone-local priority scheme on top would give two phones in
one house two different homes.

## Wireframes — iPhone 15 Pro

### 1. Typical — 6 devices, 2 playing, Main Out points at the place "Kitchen"

```
┌──────────────────────────────────────────────┐
│ CONNECTED TO ALEC'S MAC              ● Live  │
│ Places                                   +   │
│ ▾ SOUNDING 1 ──────────────────────────────  │
│ ┌──────────────────────────────────────────┐ │
│ │ (◕) Kitchen                 [M]  62%  ⋯  │ │
│ │     PLAYING · 2 SPEAKERS                 │ │
│ └──────────────────────────────────────────┘ │
│   ┌────────────────────────────────────────┐ │
│   │ (◔) HomePod Left            [M]  55%   │ │
│   │     PLAYING                            │ │
│   ├────────────────────────────────────────┤ │
│   │ (◕) HomePod Right           [M]  70%   │ │
│   │     PLAYING · SHAPED                   │ │
│   └────────────────────────────────────────┘ │
│ ▾ PLACES 4 ────────────────────────────────  │
│ ( ) Living Room        READY · 3 SPEAKERS ⋯  │
│ ( ) Apple TV                       READY  ⋯  │
│ ( ) Soundcore Flip                 READY  ⋯  │
│ ( ) This Mac                       READY  ⋯  │
│ ▸ AWAY 0 ──────────────────────────────────  │
│ ╭─ MAIN OUT ─────────────────── Kitchen ─╮   │
│ │ [M] ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░ ▮      72%   │   │
│ ╰────────────────────────────────────────╯   │
└──────────────────────────────────────────────┘
```

Three sounding faders on screen (place + two speakers), zero taps spent.
### 2. Heavy — 14 devices, Main Out = Selected Speakers, 3 playing, 4 away, 1 failed

Groups: **Kitchen** (2 HomePods) · **Whole Floor** (Sonos, Study, Patio).
Sounding: both HomePods + Nest Mini Hall. Away: Nest Mini Bath, Nest Hub, JBL
Flip, Patio (inside Whole Floor). Failed: Chromecast TV.

```
┌──────────────────────────────────────────────┐
│ CONNECTED TO ALEC'S MAC              ● Live  │
│ Places                                   +   │
│ ▾ SOUNDING 2 ──────────────────────────────  │
│ ┌──────────────────────────────────────────┐ │
│ │ (◕) Kitchen                 [M]  62%  ⋯  │ │
│ │     PLAYING · 2 SPEAKERS                 │ │
│ └──────────────────────────────────────────┘ │
│   ┌────────────────────────────────────────┐ │
│   │ (◔) HomePod Left            [M]  55%   │ │
│   │ (◕) HomePod Right           [M]  70%   │ │
│   └────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────┐ │
│ │ (◑) Nest Mini Hall          [M]  40%  ⋯  │ │
│ │     PLAYING · CAST                       │ │
│ └──────────────────────────────────────────┘ │
│ ▾ PLACES 6 ────────────────────────────────  │
│ ( ) Whole Floor  READY · 3 SPEAKERS · 1 AWAY ⋯│
│ ( ) Downstairs        READY · CAST GROUP  ⋯  │
│ ( ) Chromecast TV   Couldn't reach it.  ↻ ⋯  │
│ ( ) Apple TV                       READY  ⋯  │
│ ( ) Soundcore Flip                 READY  ⋯  │
│ ( ) This Mac                       READY  ⋯  │
│ ▸ AWAY 3 ──────────────────────────────────  │
│ ╭─ MAIN OUT ──── Selected Speakers ─ 2 s ╮   │
│ │ [M] ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░ ▮      72%   │   │
│ ╰────────────────────────────────────────╯   │
└──────────────────────────────────────────────┘
```

14 devices → 9 rows, no scrolling: two saved groups (5 devices → 2 rows), AWAY
collapsed (3 rows → 1 header), Patio absorbed into its place's `1 AWAY` clause.
### 3. First run — connected, nothing playing, no groups saved yet

```
│ CONNECTED TO ALEC'S MAC              ● Live  │
│ Places                                   +   │
│ ▾ SOUNDING 0 ──────────────────────────────  │
│     Nothing is playing.                      │
│ ▾ PLACES 6 ────────────────────────────────  │
│ ( ) HomePod Left                   READY  ⋯  │
│  TAP A PLACE TO PLAY IT · DRAG TO SET LEVEL  │
│  GROUP SPEAKERS WITH +           GOT IT      │
│ ( ) HomePod Right                  READY  ⋯  │
│ ( ) Apple TV                       READY  ⋯  │
│ ( ) Sonos One                      READY  ⋯  │
│ ( ) Soundcore Flip                 READY  ⋯  │
│ ( ) This Mac                       READY  ⋯  │
│ ▸ AWAY 0 ──────────────────────────────────  │
│ ╭─ MAIN OUT ──── Selected Speakers ──────╮   │
│ │ [M] ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░ ▮      72%   │   │
│ ╰────────────────────────────────────────╯   │
```

With no groups this is today's list plus a `⋯` and a third coach line — one line of cost, no benefit until a group exists.

### 4. EQ shaped — the Place sheet over a sounding one-speaker place

```
│  ✕                Sonos One                  │
│ ─────────────────────────────────────────── │
│  PLACE                                       │
│  Name          Sonos One                     │
│  Icon          🔊                            │
│  Add to a group…                         >   │
│  TONE                                        │
│  Bass                    −  +3.0 dB  +       │
│  Treble                  −  −1.5 dB  +       │
│  Balance                 −   0.00    +       │
│  Loudness                        ( ●)        │
│  Reset tone                                  │
│  10 bands set on the Mac. Change them there. │
│  This speaker is shaped, so it won't sound   │
│  identical to the others in a group.         │
```

On the list the same fact costs no pixels: the sub-label reads
`PLAYING · SHAPED`. No badge, no new hue, VoiceOver gets it free.
### 5. Cast starting — "Downstairs" just tapped

```
│ ▾ SOUNDING 1 ──────────────────────────────  │
│ ┌──────────────────────────────────────────┐ │
│ │ (┄◌┄) Downstairs                      ⋯  │ │
│ │       STARTING…                          │ │
│ │       About 8 seconds before it starts.  │ │
│ └──────────────────────────────────────────┘ │
│ ▾ PLACES 5 ────────────────────────────────  │
│ ( ) Kitchen           READY · 2 SPEAKERS  ⋯  │
│ ╭─ MAIN OUT ──── Downstairs ──────── 2 s ╮   │
│ │ [M] ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░ ▮      72%   │   │
│ ╰────────────────────────────────────────╯   │
```

Dashed ring = today's connecting grammar; no fader or mute while it is silent.
The deck's `2 s` appears whenever a Cast output is in the mix — a system fact.

## Gesture map

| Surface | Gesture | Action | Affordance |
|---|---|---|---|
| Place row | Tap | Make this place the output; tap again to stop | Coach line, halo state |
| Place row | Horizontal drag | Place level (group master, or the one device) | Row tints its own remainder, as today |
| Place row | Long-press / trailing `⋯` | Place sheet | `⋯` visible, own 44 pt carve-out |
| Place row | Tap mute `[M]` | Mute the whole place | Drawn only while sounding |
| Any row | Vertical | Scroll | — |
| Member row | Tap | Start/stop that speaker; refused with the Mac's reason while a group is the target | Same as today |
| Member row | Horizontal drag | That speaker's level | Row tints its remainder |
| Member row | Long-press / `⋯` | Speaker sheet (tone, info) | `⋯` visible |
| Member row | Tap mute `[M]` | Mute that speaker | Drawn only while sounding |
| Section header | Tap | Collapse / expand — **no-op on SOUNDING while non-empty** | Chevron, count |
| Main Out deck | Drag fader / tap mute | Unchanged | Unchanged |
| Main Out picker / menu | Tap | Choose Selected Speakers or a place; "Main Out tone…" | Menu |
| Toolbar `+` | Tap | New place from selected speakers (was Groups' `+`) | Visible |

Nothing moved: tap, drag and scroll keep their meanings one tier up. Swipe
actions stay unused — horizontal is the fader.

## Preferences and protocol

| Thing | Home | Why |
|---|---|---|
| Which places exist — names, icons, order | **Protocol; the Mac already owns it** (`GroupState`, snapshot order) | A room is a household fact. Phone-local places would let two phones in one house disagree about what the kitchen is — a bug, not a preference. This is the lens's answer to the brief's pin question: pins must be phone-local, so rooms replace them. |
| Place level | **Protocol, exists** (`GroupState.masterVolume`) — needs one command | The gain stage is real (`Main × Group × Device`); only the live-drag write is missing. `updateGroup` is a whole-object write with no `isFinal`, so it cannot carry a drag. |
| Place mute | **Protocol, exists** (`GroupState.isMuted` + `setGroupMuted`) | Already wired end to end. |
| Which place is playing | **Protocol, exists** (`mainOut`, `activeGroupID`, `isMainOutMember`) | Snapshot is truth; the phone invents nothing. |
| AWAY collapsed | **Phone-local** (`@AppStorage`) | Pure view state; two phones may honestly differ. |
| Section collapse, gesture coach | **In-memory / phone-local**, as today | Per-reader, not per-house. |
| Per-speaker tone | **Protocol — new** | The Mac persists `DeviceEQ` already; the phone has no view of it at all. |

**Protocol delta — four additions, all additive.**

| # | Addition | Shape | Mac must persist |
|---|---|---|---|
| 1 | `setGroupVolume(id:volume:isFinal:)` | Mirrors `setDeviceVolume` | Nothing new — `GroupState.masterVolume` already persists |
| 2 | `setPlaceActive(kind:id:)` | One atomic Mac-side switch of the Main Out target *and* the selected set | Nothing new |
| 3 | `DeviceState.connection.note: String?` | The Mac's own sentence, e.g. "About 8 seconds before it starts." | Nothing — computed |
| 4 | `DeviceState.eq` (`bassDB`, `trebleDB`, `balance`, `loudness`, `bandsAreFlat: Bool`), `Snapshot.mainOutEQ`, `setDeviceEQ(...)`, `setMainOutEQ(...)` | Simple tier over the wire; bands reduced to one boolean | Nothing new — `DeviceEQ` already persists |

#2 earns its keep on the "never invent state" rule: tapping a speaker place
while a group is the target needs both `setMainOut(.selected)` and
`setDeviceSelected` — two writes the phone would sequence, inventing an
intermediate state the Mac never had. The Mac owns both stores and the switch.

## Cast

| Question | Answer |
|---|---|
| Cast group vs saved group | A Cast group is a **place with no members list** — the Mac genuinely cannot see inside it, so it never expands. Sub-label `CAST GROUP` where a saved place says `3 SPEAKERS`. |
| Do Cast rows look different? | Only the sub-label word and the Mac-supplied icon. No transport heading, colour or chip. |
| The ~2 s delay | On the **Main Out deck**, as a `2 s` micro-label beside the place name, present whenever any Cast output is in the mix. It is a whole-system fact (everything is delayed to match), so putting it on a row would say it N times and imply it is that row's problem. VoiceOver: "everything is delayed about 2 seconds to stay in sync". |
| The ~8 s first play | The place row's own `STARTING…` state — today's dashed connecting ring — with the Mac's sentence underneath from `connection.note`. Sentence case, `label2`: it is the Mac's own words, per the Sentence-Case Exception. |
| Cast disappearing often | The place row is the grace unit — a Cast group that goes away is one row moving into `AWAY 4`, not five rows vanishing. Pruning policy stays the Mac's (research pattern 7). |

## EQ

| Question | Answer |
|---|---|
| Where | On the **Place sheet**, second section, under Members. Never on a row, never in the deck's face. One level down, exactly like every app surveyed. |
| Which tier | **Simple only, editable** — Bass, Treble, Balance, Loudness, bare numbers, ±12 dB. The 10 bands are a **read-only line**: "10 bands set on the Mac." The Mac keeps bands off its own quick surface; the phone is quicker still, so it keeps them off harder. |
| Per device or per place | Per **device**, reached **through** the place. The Mac has no group EQ object and this proposal does not invent one. A one-speaker place shows the sliders directly; a multi-speaker place lists members with `SHAPED`/`FLAT` and a "Shape all alike" action that writes the same four values to each member (a convenience write, not a stored group EQ — the sheet says `Mixed` when members differ). |
| Main Out EQ | The deck's menu → "Main Out tone…", same four controls. |
| How a shaped row is marked | The sub-label gains a clause: `PLAYING · SHAPED`. No badge, no glyph, no new hue — research pattern 6's "one mark, not a readout", taken to its cheapest form. On a place, `SHAPED` appears on the member row that is shaped, never on the place row, because a place has no tone of its own. |

## Failure modes

| Case | What breaks | Answer |
|---|---|---|
| 3-device household, no groups | The lens buys nothing: 3 speakers = 3 places = today's list. Cost is one `⋯` per row and one extra coach line. | Accepted, and stated honestly. The `+` in the toolbar is the only nudge; nothing nags. This is the proposal's weakest fixture. |
| 20-device venue, ungrouped | 20 place rows with more chrome than today, and no search, sort or filter to fall back on. | AWAY collapse helps; only grouping really answers it. A venue that never groups is better served by lens C. |
| AX3 Dynamic Type | Place rows carry three lines; at AX3 a sounding place plus two members fills the screen. | Place rows grow past the fixed 60 pt, and at accessibility sizes the place row **drops its member-count clause**, keeping name and state. Members are never dropped — they are the constraint. |
| VoiceOver | Two row tiers risk sounding like one flat list. | Member rows prefix the place: "Kitchen, HomePod Left, playing, 55 percent". Sections are rotor headings; the place row is one element with `⋯` as a sibling button, as mute is today. `SOUNDING` says "cannot be collapsed" rather than going silently dead. |
| A grouped speaker sounding while its place isn't the target | It would hide under a collapsed place. | Impossible: the place enters SOUNDING expanded the moment any member sounds, reading `PLAYING · 1 OF 3`. |

## Cost

| Slice | Work | Days |
|---|---|---|
| **1 — ships first** | Places screen: three place kinds, the Sounding Rule with inline member rows, AWAY collapse and the `1 AWAY` clause, place fader + mute. Groups tab absorbed — `GroupEditorView`'s body becomes the Place sheet's Members section, `+` moves to the toolbar. Protocol #1 (`setGroupVolume`) both sides. | 4 |
| **2** | Protocol #2 (`setPlaceActive`) and #3 (`connection.note`); Cast place presentation, `STARTING…`, the deck's `2 s`. | 2 |
| **3** | Protocol #4 (EQ both directions), tone section on both sheets, `SHAPED` clause, Main Out tone menu item. Mac side is exposure only — `DeviceEQ` and its persistence exist. | 3 |
| **Total** incl. tests, VoiceOver and AX3 passes | | **10–11** |

New screens: **one** (the Place sheet, absorbing an existing editor). One tab
removed. New Mac-side persistence: **none** — every value written is one the Mac
already stores. Slice 1 ships alone and is the whole rooms-first claim.

## Three things lenses A and C will get right that this one gives up

1. **The household that never makes a group (A).** Inferred priority — recency,
   most-used — pays on first launch with zero setup, for everyone. B pays
   nothing until someone has curated rooms on the Mac.
2. **The 20-speaker venue, and anyone who knows a speaker by name (C).** Search,
   sort and filter chips beat structure on a long ungrouped list every time. B
   refuses all three and has no fallback when the grouping isn't there.
3. **Fewer concepts, and depth for the audiophile (A and C).** A keeps one flat
   list where every row is the same object — one tier, one model, one gesture
   set; B adds a second tier and a place/speaker distinction to learn. C puts
   the full ten bands on the phone, which B answers with a read-only sentence.
