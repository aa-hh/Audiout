# Proposal C — The console (iPhone Speakers tab, 2026-08-23)

## Thesis

Make the phone the desk, and make density a **consequence of the list, not a
mode**. Below eight speakers the screen is exactly what ships today — three
state sections, the row-as-fader, the floating deck — plus one trailing `⋯`
per row. At eight the list grows a **console strip** (filter chips, sort,
pins); at twelve, search; compact rows are offered, never imposed. Every
per-speaker control the Mac has, both EQ tiers included, lives one tap down
in a **channel strip** sheet — the phone's equivalent of the Mac's device
detail pane, not of its popover. The household of three never sees a chip, a
sort menu, a search field or a compact row, because at three devices none of
them exist; the venue of twenty gets an instrument instead of a scroll. One
place I do not follow my own lens: **there are no horizontal swipe actions**
— the row's drag is the fader and outranks them; those jobs land on the
visible `⋯` and on long-press.

## Information architecture

```
Speakers tab
├─ Header (eyebrow · "Speakers" · status pill)          unchanged
├─ Status banners                                       unchanged
├─ CONSOLE STRIP  ── scrolls away with the list, appears at ≥8 devices
│   ├─ Search field (≥12 devices) · chips PLAYING · AIRPLAY · BT · CAST
│   └─ Sort ⇅  Recently used / Name / Mac's order · Full or Compact rows
│              · Clear all pins
├─ PLAYING / READY / UNAVAILABLE — unchanged sections; pins sort to the top
│   WITHIN a section; UNAVAILABLE auto-collapses at ≥8 devices
│   └─ Row: halo + level arc · name · sub-label · [mute] · ⋯      ← ⋯ is new
│       └─ CHANNEL STRIP sheet  (the only new screen)
│           ├─ Level · Mute · Pin to top · output facts
│           ├─ Tone — Bass · Treble · Balance · Loudness
│           └─ 10 bands — response curve + ten drag rows
└─ Main Out deck                                        unchanged
    └─ picker menu gains "Main Out tone…" and "Stop everything"
```

Nothing moves: every addition is a strip above the list, a glyph on the row, or a sheet below it.

## Wireframes — iPhone 15 Pro width

### 1. Typical — 6 devices, 2 playing. No strip, full rows.
```
┌──────────────────────────────────────────────┐
│ CONNECTED TO STUDIO MAC               ● Live │
│ Speakers                                     │
│ ⌄ PLAYING 2 ──────────────────────────────── │
│ │ (◕) Kitchen HomePod          [mute]  ⋯   │ │
│ │     PLAYING                              │ │
│ │ (◕) Living Room HomePod      [mute]  ⋯   │ │
│ │     PLAYING                              │ │
│ ⌄ READY 4 ────────────────────────────────── │
│ │ ( ● ) Sonos One                      ⋯   │ │
│ │       READY                              │ │
│ │       … Apple TV · UE Boom · Studio Mac  │ │
│ ⌄ UNAVAILABLE 0 ───────────────────────────  │
│  ╭────────────────────────────────────────╮  │
│  │ MAIN OUT             Selected Speakers⌄│  │
│  │ [mute] ▓▓▓▓▓▓▓▓▓░░░░░░░░░░░  72        │  │
│  ╰────────────────────────────────────────╯  │
└──────────────────────────────────────────────┘
```

### 2. Heavy — 14 devices, 3 playing, 4 unavailable, 1 failed. Strip on, compact rows.
```
┌──────────────────────────────────────────────┐
│ CONNECTED TO STUDIO MAC               ● Live │
│ Speakers                                     │
│ ┌ PLAYING ┐┌ AIRPLAY ┐┌ BT ┐┌ CAST ┐     ⇅  │
│ ⌄ PLAYING 3 ──────────────────────────────── │
│ │ (◕) Kitchen HomePod      68  [mute]  ⋯   │ │
│ │ (◕) Living Room HomePod  54  [mute]  ⋯   │ │
│ │ (◕) Downstairs  GROUP 3  40  [mute] ⌁⋯   │ │
│ ⌄ READY 6 ────────────────────────────────── │
│ │ (✕) Sonos One  Couldn't connect       ⋯   │ │
│ │     Try again                             │ │
│ │ (●) Nest Mini Bedroom    30          ⌁⋯   │ │
│ │ (●) Apple TV             50           ⋯   │ │
│ │ (●) Nest Hub · UE Boom · Studio Mac …     │ │
│ › UNAVAILABLE 4 ──────────────────────────── │
│  ╭────────────────────────────────────────╮  │
│  │ MAIN OUT             Selected Speakers⌄│  │
│  │ [mute] ▓▓▓▓▓▓▓░░░░░░░░░░░░  61         │  │
│  ╰────────────────────────────────────────╯  │
└──────────────────────────────────────────────┘
```

Without scrolling: all 3 playing, the failure card, and 5–6 ready rows at
compact 44 pt (4 at full 60 pt). `⌁` is the one "not the plain path" mark —
shaped tone or added delay; its spoken label names which.

### 3. First run — connected, nothing playing, coach showing.
```
┌──────────────────────────────────────────────┐
│ CONNECTED TO STUDIO MAC               ● Live │
│ Speakers                                     │
│ ⌄ PLAYING 0 ──────────────────────────────── │
│ ⌄ READY 6 ────────────────────────────────── │
│ │ ( ● ) Kitchen HomePod                ⋯   │ │
│ │       READY                              │ │
│ │  TAP TO PLAY · DRAG TO SET LEVEL  GOT IT │ │
│ │ ( ● ) Living Room HomePod            ⋯   │ │
│ │       READY                              │ │
│ │       … Sonos One · Apple TV · UE Boom   │ │
│ │         · Studio Mac                     │ │
│ ⌄ UNAVAILABLE 0 ───────────────────────────  │
│  ╭────────────────────────────────────────╮  │
│  │ MAIN OUT             Selected Speakers⌄│  │
│  │ [mute] ▓▓▓▓▓▓▓▓▓░░░░░░░░░░░  72        │  │
│  ╰────────────────────────────────────────╯  │
└──────────────────────────────────────────────┘
```

No strip, no chips, no `⋯` coaching — the console does not introduce itself on day one.

### 4. EQ shaped — the channel strip sheet, both tiers.
```
┌──────────────────────────────────────────────┐
│  ╌╌                                    Done  │
│  Kitchen HomePod                             │
│  PLAYING · AIRPLAY 2                         │
│  ╭──────────────────────────────────────────╮│
│  │ [mute]  ▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░  68          ││
│  ╰──────────────────────────────────────────╯│
│  Pin to top ( )                    Reset tone│
│  TONE                                        │
│  Bass      ────────●─────────        +4 dB   │
│  Treble    ─────●────────────        −2 dB   │
│  Balance  L─────────●────────R          0    │
│  Loudness                                (x) │
│  10 BANDS                                    │
│  +12 ·   ·   ·  ·  ·  ·  ·  ·  ·  ·          │
│    0 ─────╱‾╲──────────────╱‾‾╲──────        │
│  −12 ·   ·   ·  ·  ·  ·  ·  ·  ·  ·          │
│      31  63 125 250 500 1k 2k 4k 8k 16k      │
│  31 Hz    ──────●────────────       +3 dB    │
│  63 Hz    ────────●──────────        +1 dB   │
│  DRAG A BAND · DOUBLE-TAP TO ZERO IT         │
└──────────────────────────────────────────────┘
```

### 5. Cast starting — tapped, ~8 s before sound.
```
┌──────────────────────────────────────────────┐
│ CONNECTED TO STUDIO MAC               ● Live │
│ Speakers                                     │
│ ┌ PLAYING ┐┌ AIRPLAY ┐┌ BT ┐┌ CAST ┐     ⇅  │
│ ⌄ PLAYING 2 ──────────────────────────────── │
│ │ (◕) Kitchen HomePod      68  [mute]  ⋯   │ │
│ │ (◕) Living Room HomePod  54  [mute]  ⋯   │ │
│ ⌄ READY 7 ────────────────────────────────── │
│ │ (⋯) Nest Mini Bedroom                ⌁⋯  │ │
│ │     About 8 seconds before sound.        │ │
│ │ (●) Nest Hub             45          ⌁⋯   │ │
│ │ (●) Chromecast           50          ⌁⋯   │ │
│ │ (●) Downstairs  GROUP 3  40          ⌁⋯   │ │
│ │ (●) Sonos One · Apple TV · Studio Mac …   │ │
│ › UNAVAILABLE 3 ──────────────────────────── │
│  ╭────────────────────────────────────────╮  │
│  │ MAIN OUT             Selected Speakers⌄│  │
│  │ [mute] ▓▓▓▓▓▓▓░░░░░░░░░░░░  61         │  │
│  ╰────────────────────────────────────────╯  │
└──────────────────────────────────────────────┘
```

The existing dashed connecting ring; the sub-label replaced by the Mac's own
sentence. The row stays in READY until sound starts — the screen does not
promise PLAYING eight seconds early.

## Gesture map

| Surface | Gesture | Does | Affordance |
|---|---|---|---|
| Row | Tap | Start / stop | Coach line, first run |
| Row | Horizontal drag | Level | Coach line; row tints its own remainder |
| Row | Vertical drag | Scroll | — |
| Row | Long-press | Context menu: Pin to top · Speaker settings · Stop | The `⋯` is its visible twin |
| Row | Tap on mute overlay | Mute / unmute | 28 pt drawn control, sounding rows only |
| Row | Tap on `⋯` | Opens the channel strip sheet | The glyph itself |
| Row | Drag **starting on** `⋯` | Level | Existing 5 pt axis latch: a tap opens, a drag fades |
| Row | Horizontal swipe action | **Nothing — refused** | The fader owns the axis |
| Section header | Tap | Collapse / expand | Chevron + count |
| Strip — chip | Tap | Filter on / off | Filled when on; resets each launch |
| Strip — sort `⇅` · search | Tap / type | Order, row height, clear pins · filter by name | Menu glyph; field |
| Deck — fader | Horizontal drag | Main Out level | Drawn fader |
| Deck — mute | Tap | Mute everything | Drawn button |
| Deck — picker | Tap | Menu + "Main Out tone…" + "Stop everything" | Chevron |
| Sheet — band row | Horizontal drag · double-tap | Sets that band's gain · zeroes it | Sheet coach line |

No collisions: every new gesture sits on a surface that had none — except the `⋯`, where the existing axis latch already separates tap from drag.

## Preferences and protocol

| Thing | Home | Why |
|---|---|---|
| Pins | Phone-local (`@AppStorage`, device ids) | A pin is "the speaker *I* reach for", not a fact about the house. Two phones differing is correct: the kid pins the bedroom, the cook pins the kitchen. Syncing it makes one person's curation everyone's. Pins sort **within** a section, never above a playing speaker. |
| Sort order · row height | Phone-local | Display choices with no audible effect. Row height is never inferred — a row that changes height under a finger is a lie in miniature. |
| Section collapse | Phone-local, in-memory (as today) | Matches the existing `razor:` note in `SpeakerConsole`. |
| Filter chips | In-memory, cleared each launch | A filter left on silently is a lie about the system (research anti-pattern). |
| "Recently used" order | Phone-local, derived | The phone stamps a device when it watches `isMainOutMember` go false→true in any snapshot — so it records the Mac starting a speaker too, not just this phone. *Ceiling: empty on a fresh install; falls back to the Mac's order until it fills.* |
| Hide unavailable | **Not offered** | The console shows everything. UNAVAILABLE auto-collapses with a count at ≥8 devices; pruning is the Mac's grace policy, not a phone switch. |
| **EQ values** | **Protocol** | The Mac owns and persists them (`DeviceEQStore`); the phone renders and writes. It cannot be phone-local — the audio is the Mac's. |
| **EQ bypass note** | **Protocol** | The reason a stored EQ is inaudible is the Mac's own sentence (`EQEditorView.bypassNoteText`), never composed on the phone. |
| **Output delay · Cast group size** | **Protocol** | Only the Mac knows a Cast leg costs ~2 s, or that a virtual device has three members. |

### Exact protocol delta (all additive, all optional → no version bump)

| Where | Field / case | Type | Note |
|---|---|---|---|
| New type | `EQState` | `bassDB, trebleDB, balance: Double`, `loudness: Bool`, `bandGainsDB: [Double]` (10) | A mirror of `DeviceEQ` living in `AudiouterProtocol`. It cannot *be* `DeviceEQ` — iOS may never depend on `AudiouterCore` (`ios/AGENTS.md`). Mac maps one to the other. |
| `DeviceState` | `eq: EQState?` | optional | `nil` = flat. |
| `DeviceState` | `eqBypassNote: String?` | optional | The Mac's sentence, or `nil` when the EQ is actually reaching the audio. |
| `DeviceState` | `outputDelayMs: Int?` | optional | ~2000 for Cast, ~500 BT, AirPlay per the Mac's model. Drives the `⌁` mark and the sheet's readout. |
| `DeviceState` | `memberCount: Int?` | optional | `nil` for a single box; `3` for a Cast group. |
| `ConnectionInfo` | `stateNote: String?` | optional | "About 8 seconds before sound." Same idiom as `failureHeadline`. |
| `Snapshot` | `mainOutEQ: EQState?` | optional | Main Out's whole-mix tone. |
| `CompanionCommand` | `setDeviceEQ(id:eq:committed:)`, `setMainOutEQ(eq:committed:)` | two new cases | `committed == false` is a live scrub (apply, don't persist); `true` persists — the exact split `EQEditorViewDelegate` already uses. |

**No reset command** — flat + `committed: true` is one, because
`DeviceEQStore.save` already drops flat entries. **No new Mac-side
persistence**: `DeviceEQStore` already keys per-device plus Main Out. The Mac
work is snapshot-builder mapping and two dispatcher cases.

## Cast

| Question | Answer |
|---|---|
| The ~2 s delay | Not a number on the row. The row carries `⌁`, one small mark for "this output is not the plain path"; the channel strip sheet spells it: `DELAY 2.0 s` plus one plain sentence — "Everything else waits for this speaker, so the rooms stay together." Research pattern 6 (Roon's signal-path light), with a spoken label instead of a colour code. |
| The ~8 s first play | The existing dashed connecting ring, sub-label replaced by the Mac's own sentence (fixture 5). The row does **not** move to PLAYING until sound starts. |
| Cast group vs Audiouter group | They never compete: an Audiouter saved group is never a row in Speakers — it is a target in the Main Out picker and a row in the Groups tab. A Cast group is a device row saying `GROUP 3`. Per research 15, a Cast group and its members must never both be rows; the Mac's snapshot sends one or the other. |
| Do Cast rows differ? | Only by icon (already the Mac's `iconSymbolName`), the `⌁` mark, and `GROUP n`. No transport heading, no transport tint. |

## EQ

**Where:** the channel strip sheet, per device; Main Out's tone in the deck's
picker menu. Never on the row, never inline in the list.

**Does that contradict the Mac?** No. The Mac's decision was between *two Mac
surfaces* — off the menu-bar popover, on the Groups window's device detail
pane. The phone has no second window, so it must grow that pane inside itself
or EQ has no home at all. The channel strip **is** the pane; the list stays
exactly as bare as the popover.

**Which tier: both**, and only the second reason is about audiophiles.
(1) `DeviceEQ` keeps both tiers live at once, so a phone showing only Bass and
Treble would silently hide ten band gains the Mac has set — "the UI never
lies" forbids that. (2) The secondary audience will ask.

**Ten bands at iPhone width.** The Mac's ten vertical faders in 26 pt columns
do not survive: 393 pt minus margins is ~36 pt a column, under the 44 pt floor
before Dynamic Type touches it. So the bands become **ten horizontal rows**,
the row-is-the-fader grammar restated — band label, drag anywhere across, bare
`+3 dB` readout. It is the only form that survives AX3: rows grow in height
and nothing has to fit sideways. The curve sits above, non-interactive, bonded
to the controls not by a shared x-axis (rows break that) but by lighting the
gridline of whichever band is under the finger.

**Marking a shaped row:** the same `⌁` as delay, spoken as "Tone shaped" or
"Delayed 2 seconds" so the cause is never a colour riddle. Bare numbers, no
named presets; balance reads exactly as the Mac's editor reads it.

## Failure modes

| Case | What happens | Cost, honestly |
|---|---|---|
| 3-device household | No strip, no chips, no search, no compact rows, no sort menu. The screen is today's screen. | One `⋯` glyph per row that was not there before — ~44 pt of trailing width on a row that had none. That is the whole price, and it buys the visible half of long-press (research 4, the best-fit pattern in the file). |
| 20-device venue | Strip, chips, search, compact rows, pins. **Trap:** Cast devices churn between READY and UNAVAILABLE, which re-sorts the list under a finger. Fix: ordering freezes for any drag and for 400 ms after — the list never re-sorts while someone is holding it. | Pins are per-phone, so a venue on one shared iPad gets one person's curation. Accepted. |
| AX3 type | The strip wraps: search on its own line, chips scroll horizontally, sort stays trailing. Compact rows are **unavailable** and the menu item says so rather than going dead. The sheet's band rows each grow; the curve scales to a 1.5× ceiling. | The strip can eat two lines of a short screen — which is why it scrolls away instead of pinning. |
| VoiceOver | Chips are buttons carrying the selected trait; sort is a menu; `⋯` is a button reading "Speaker settings, Kitchen HomePod"; the `⌁` mark is never a lone glyph — it is a clause in the row's existing single value. **Trap:** the rows are hand-drawn, not `List`, so long-press menu items get no rotor actions for free — each one needs an explicit `.accessibilityAction(named:)`, or the context menu is unreachable without sight. | Every new control is a new element to keep in parity; the row itself stays one element with one value, as today. |

## Cost

| Slice | Work | Protocol | Days |
|---|---|---|---|
| **1 — ships first** | Console strip (chips, sort, pins) · UNAVAILABLE auto-collapse at ≥8 · drag-freeze on re-sort | none | 3 |
| 2 | `⋯` accessory · channel strip sheet (level, mute, pin, output facts) · long-press context menu | none | 3 |
| 3 | EQ: `EQState`, four snapshot fields, two commands, Mac snapshot-builder + dispatcher, both tiers on the sheet, the `⌁` mark | yes | 5 |
| 4 | Cast: `outputDelayMs`, `stateNote`, `memberCount`, delay readouts | yes (gated on 006) | 2 |
| 5 | Response curve on the phone · search at ≥12 · compact rows | none | 4 |
| | | | **17** |

New screens: **one**. New protocol fields: six, all optional. New Mac-side
persistence: **none**. Slice 1 ships alone, and is where the density promise is kept or broken.

## Three things A and B get right that this gives up

1. **A keeps the household's screen literally untouched.** C adds a glyph to
   every row on day one and a strip the moment a Cast box appears. A pays
   nothing for a list it will never have.
2. **B answers "which room" structurally.** C answers it with sort, filter
   and search — machinery. A person who thinks "kitchen, upstairs, garden"
   still has to read names, and names are only as good as whoever set the Mac up.
3. **A leaves EQ on the Mac, and that is a lot of surface not signed up
   for.** No `EQState`, no dispatcher cases, no second editor to keep in step
   with the Mac's, no two-writer question over `device-eq.json`, no phone
   screen that can misreport the audio. C takes it on because the audiophile
   audience will ask — but that ask is a secondary audience's, and the bill is
   the primary audience's to carry.
