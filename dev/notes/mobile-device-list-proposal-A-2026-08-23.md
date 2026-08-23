# Proposal A — Fewest gestures for the household (2026-08-23)

Lens: the phone is the dinner-party remote. One of three divergent proposals.

## Thesis

The Speakers tab is not a list of speakers, it is the top four rows. Whoever
picks up the phone mid-dinner wants one of three speakers, and which three is a
fact the phone can *watch* rather than ask about — they usually did not set the
Mac up, so they will never have curated a favourites list (Apple Home's are
entirely manual and buy a never-curating household nothing — research Q3 #2). So
A adds **no pin, no sort menu, no search, no filter chips, no second tab**, and
spends its budget on three moves: order READY by what this phone actually
touches, stop drawing the tail of a long list until asked, start UNAVAILABLE
collapsed with its count showing. Everything else in play — EQ, the Cast delay,
per-speaker detail — goes one level down behind a long press, which costs zero
pixels and matches what every surveyed app does with tone. The phone is for
levels. The Mac is for shaping.

## Information architecture

| Level | Surface | What lives there |
|---|---|---|
| 0 | Speakers tab (unchanged shell) | One scrolling list, three state sections, the floating Main Out deck |
| 0 | PLAYING section | Every sounding speaker, Mac order. Never truncated, never collapsed by default |
| 0 | READY section | Failed rows first (existing rule), then **inferred priority**, then a `SHOW N MORE` tail row once READY exceeds 5 |
| 0 | UNAVAILABLE section | **Collapsed by default**, count in the header |
| 1 | Speaker sheet (the one new screen) | Long press a row: tone (simple tier), delay, what this speaker is, Try Again. Main Out gets the same sheet from one new item in the deck's existing menu |

No new tab, no new heading, no transport heading. Section membership stays "what
is this speaker doing right now", exactly as `SpeakersView.sections` argues.

### Inferred priority — the rule

READY is ordered by a phone-local score recomputed on each snapshot: every
touch on this phone (play, stop, level, mute) counts once, decaying with a
14-day half-life; sounding at any point this session adds one bump; a speaker
never touched scores 0 and falls back to the Mac's own order. A tie keeps the
Mac's order, so the list is stable and never reshuffles under a finger. Nothing
about the score is visible — no badge, no "recent" label, no setting.

**Why inference and not a pin.** A pin is one more thing to teach and dead weight
for whoever did not set the system up. Sonos's 2026 repair shipped pinning *and*
sort-by-frequency-of-use; A takes the half needing no user action. The cost — a
wrong order cannot be corrected — is one flick away, not a dead end. `razor:` if
it misses, the upgrade is a long-press "Keep at top" onto the same store.

## Wireframes — iPhone 15 Pro, 393 pt wide

Legend: `◔` playing halo + level arc · `○` ready · `[M]` mute (sounding rows only) · `≈` shaped mark · `⌄`/`›` chevron open/collapsed.

### 1. Typical — 6 devices, 2 playing

```
┌────────────────────────────────────────────┐
│ CONNECTED TO ALEC'S MAC              ● Live│
│ Speakers                                   │
│                                            │
│ ⌄ PLAYING 2 ─────────────────────────────  │
│ ◔ Kitchen HomePod         PLAYING   62 [M] │
│ ◔ Living Room Sonos       PLAYING   48 [M] │
│ ⌄ READY 4 ───────────────────────────────  │
│ ○ Bedroom HomePod         READY     55     │
│ ○ Office Bluetooth        READY     70     │
│ ○ Apple TV                READY     30     │
│ ○ This Mac                READY     80     │
│ › UNAVAILABLE 0 ─────────────────────────  │
│                                            │
│ ╭────────────────────────────────────────╮ │
│ │ MAIN OUT           Selected Speakers ⌄ │ │
│ │ [M] ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░  ▮     78 │ │
│ ╰────────────────────────────────────────╯ │
└────────────────────────────────────────────┘
```

Identical to today except UNAVAILABLE starts collapsed — the 3-device household pays nothing.

### 2. Heavy — 14 devices, 3 playing, 4 unavailable, 1 failed

```
┌────────────────────────────────────────────┐
│ CONNECTED TO ALEC'S MAC              ● Live│
│ Speakers                                   │
│ ⓘ Everything is delayed about 2 seconds so │
│   Downstairs stays in sync.                │
│ ⌄ PLAYING 3 ─────────────────────────────  │
│ ◔ Kitchen HomePod         PLAYING   62 [M] │
│ ◔ Living Room Sonos    ≈  PLAYING   48 [M] │
│ ◔ Downstairs              PLAYING   55 [M] │
│ ⌄ READY 7 ───────────────────────────────  │
│ ○ Bedroom HomePod                          │
│   Couldn't reach this speaker.  ⌄  Try Again│
│ ○ Office Bluetooth        READY     70     │
│ ○ Apple TV                READY     30     │
│ ○ Study Nest Mini         READY     40     │
│ ○ This Mac                READY     80     │
│           SHOW 2 MORE                      │
│ › UNAVAILABLE 4 ─────────────────────────  │
│ ╭────────────────────────────────────────╮ │
│ │ MAIN OUT           Selected Speakers ⌄ │ │
│ │ [M] ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░  ▮     78 │ │
│ ╰────────────────────────────────────────╯ │
└────────────────────────────────────────────┘
```

Without scrolling: all 3 playing speakers, the one thing asking for help, and the
4 ready speakers this phone uses most. The Cast group `Downstairs` is one row.

### 3. First run — connected, nothing playing, coach showing

```
┌────────────────────────────────────────────┐
│ CONNECTED TO ALEC'S MAC              ● Live│
│ Speakers                                   │
│                                            │
│ ⌄ PLAYING 0 ─────────────────────────────  │
│ ⌄ READY 6 ───────────────────────────────  │
│ ○ Kitchen HomePod         READY     62     │
│  TAP TO PLAY · DRAG TO SET LEVEL           │
│  HOLD FOR TONE & DETAILS          GOT IT   │
│ ○ Living Room Sonos       READY     48     │
│ ○ Bedroom HomePod         READY     55     │
│ ○ Office Bluetooth        READY     70     │
│ ○ Apple TV                READY     30     │
│ ○ This Mac                READY     80     │
│ › UNAVAILABLE 0 ─────────────────────────  │
│                                            │
│ ╭────────────────────────────────────────╮ │
│ │ MAIN OUT           Selected Speakers ⌄ │ │
│ │ [M] ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░  ▮     78 │ │
│ ╰────────────────────────────────────────╯ │
└────────────────────────────────────────────┘
```

The coach grows one line for the third gesture and clears as it does today; with no touch history yet, READY is simply the Mac's own order.

### 4. EQ shaped — a non-flat speaker, playing

```
┌────────────────────────────────────────────┐   long press ↓
│ ⌄ PLAYING 2 ─────────────────────────────  │  ╭──────────────────╮
│ ◔ Kitchen HomePod         PLAYING   62 [M] │  │ Living Room Sonos│
│ ◔ Living Room Sonos    ≈  PLAYING   48 [M] │  │                  │
│ ⌄ READY 4 ───────────────────────────────  │  │ TONE             │
│ ○ Bedroom HomePod         READY     55     │  │ Bass    ──●── +4 │
│ ○ Office Bluetooth        READY     70     │  │ Treble  ─●─── −2 │
│ ○ Apple TV                READY     30     │  │ Balance ──●──  0 │
│ ○ This Mac                READY     80     │  │ Loudness      ON │
│ › UNAVAILABLE 0 ─────────────────────────  │  │                  │
│                                            │  │ Also shaped with │
│                                            │  │ 10 bands on the  │
│                                            │  │ Mac.             │
│                                            │  │                  │
│                                            │  │ Reset tone       │
│ ╭────────────────────────────────────────╮ │  │                  │
│ │ MAIN OUT           Selected Speakers ⌄ │ │  │ AirPlay 2 · no   │
│ │ [M] ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░  ▮     78 │ │  │ added delay      │
│ ╰────────────────────────────────────────╯ │  ╰──────────────────╯
└────────────────────────────────────────────┘   (medium sheet)
```

The list carries one mark, not a readout. Bare numbers, never named presets.

### 5. Cast starting — tapped, ~8 s before sound

```
┌────────────────────────────────────────────┐
│ CONNECTED TO ALEC'S MAC              ● Live│
│ Speakers                                   │
│                                            │
│ ⌄ PLAYING 3 ─────────────────────────────  │
│ ◔ Kitchen HomePod         PLAYING   62 [M] │
│ ◔ Living Room Sonos    ≈  PLAYING   48 [M] │
│ ◑ Study Nest Mini         STARTING…    [M] │
│ ⌄ READY 6 ───────────────────────────────  │
│ ○ Bedroom HomePod         READY     55     │
│ ○ Office Bluetooth        READY     70     │
│ ○ Apple TV                READY     30     │
│ ○ Hallway AirPlay         READY     35     │
│ ○ This Mac                READY     80     │
│           SHOW 1 MORE                      │
│ › UNAVAILABLE 4 ─────────────────────────  │
│ ╭────────────────────────────────────────╮ │
│ │ MAIN OUT           Selected Speakers ⌄ │ │
│ │ [M] ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░  ▮     78 │ │
│ ╰────────────────────────────────────────╯ │
└────────────────────────────────────────────┘
```

`◑` is the existing dashed connecting ring. The row moves to PLAYING at once and
says `STARTING…` for the whole wait, so nobody taps twice; the level readout is
withheld until there is a real level.

## Gesture table

| Target | Gesture | Result | Affordance |
|---|---|---|---|
| Device row | tap | start / stop | coach line 1 (existing) |
| Device row | horizontal drag | set level | coach line 1 (existing) |
| Device row | **long press** | Speaker sheet | **coach line 2 (new)** + the `≈` mark invites it |
| Device row | vertical drag | scroll (inert) | — |
| Mute overlay (sounding rows) | tap | mute / unmute | drawn button |
| Failure card | tap Diagnose / Try Again | disclose / retry | drawn buttons |
| Section header | tap | collapse / expand | chevron + count |
| `SHOW N MORE` row | tap | reveal the READY tail for this launch | it is a labelled row with a real count |
| Main Out picker | tap | menu: targets, **+ "Main Out tone…"** | chevron |
| Main Out fader / mute | drag / tap | master level, kill switch | drawn |
| Swipes, toolbar | — | **deliberately unused** | horizontal is the fader; a swipe action fights it, and there is no toolbar |
| Stop-everything | — | **not added** | the deck's mute already is one, and a second panic control beside the real one invites mis-taps (research Q3 #12) |

No collisions: long press latches before the 5 pt slop that commits a drag, and
the existing axis latch already leaves vertical to the scroll view.

## Preferences and protocol

| Thing | Home | Persists? | Why |
|---|---|---|---|
| Priority score (touch counts, decayed) | phone-local | yes, per phone | Two people in one house use different speakers. Syncing this would average two households into one wrong answer. Nothing audible depends on it |
| Section collapse, `SHOW N MORE` expanded | phone-local, in memory | no — both reset each launch, UNAVAILABLE back to collapsed | Matches today's `razor:` note in `SpeakerConsole`. A section or a tail left folded across launches hides a speaker coming back, and a filter silently left on is a lie about the system (research Q3 #9) |
| Hide unavailable | **not a preference** | — | The Mac owns the grace period before a device stops being reported at all; the phone only collapses. Answers the brief's open question: automatic, Mac-side, never a toggle |
| Search | **does not exist** | — | Answers the open question: no search below 20 devices. Inference plus a collapsed tail does the same job with no permanent header cost |
| Tone values | **protocol** | Mac persists (already does) | They change sound; the phone never invents state. The ten bands cross as **one boolean** — the phone must know they are non-flat to be honest, and never needs the numbers |
| Output delay | **protocol** | Mac computes live | The Mac already resolves delay-to-worst; the phone must not hardcode "Cast = 2 s" |

### Protocol delta

| Field | Where | Type | Note |
|---|---|---|---|
| `eq` | `DeviceState`, and a `mainOutEQ` on `Snapshot` | optional `EQSummary` | `{ bassDB, trebleDB, balance, loudness, bandsAreFlat }` — five values, not thirteen. Optional so an older peer decodes cleanly, as `masterVolume` already is |
| `outputDelayMs` | `DeviceState` | optional `Int` | 0 for a plain AirPlay leg; ~2000 for Cast; whatever the Bluetooth path resolves to |
| `connection.state == "starting"` | existing field, new value | — | Cast's first-play wait. Unknown values must fall back to today's connecting treatment |
| `setDeviceEQ` / `setMainOutEQ` | commands | simple tier only | The phone can never write a band gain |

Mac-side persistence: none new (`DeviceEQ` already persists). The Mac must also
guarantee a Cast group and its members never both appear as rows (research Q3
#15). **Not added:** no pin, no "last used", no favourite.

## Cast

| Question | Answer |
|---|---|
| Where does the ~2 s delay show? | **Not on rows.** When a Cast leg is live *everything* is delayed to match, so a per-row mark would land on every row and say nothing. It shows once, as an existing `label2` status banner — "Everything is delayed about 2 seconds so Downstairs stays in sync" — only while a delayed output is live. The per-device number is the Speaker sheet's last line: "Google Cast · about 2 seconds of added delay" |
| Where does the ~8 s first-play wait show? | On the row, as `STARTING…` with the existing dashed ring, for the whole wait, with the level readout withheld until there is a real level |
| Cast group vs saved Audiouter group? | Structural, not decorated. **If it is a row in the list it is a device**; a saved Audiouter group is never a row — it lives in the Main Out picker and the Groups tab. The sheet for a Cast group says "A Google Cast group. Its members are set up in the Google Home app." |
| Do Cast rows look different? | No. Same row, same gestures, the Mac's own icon symbol. No chip, no transport heading |
| The 3-AirPlay household with no Cast? | Sees nothing — no banner, no chip, no extra sub-label, no new heading. This is the test A is built to pass |

**One bug this exposes.** `DeviceRowView.pendingSelection` times out after two
seconds; Cast's wait is roughly eight. Its bound must become "until a snapshot
moves `isMainOutMember`, or the Mac says starting ended" — not a fixed 2 s.

## EQ

| Question | Answer |
|---|---|
| Where? | One level down, in the long-press Speaker sheet — never inline, never on the deck's face. Main Out's tone is the same sheet, reached from one new item in the deck's existing menu |
| Which tier? | **Simple only** — Bass, Treble, Balance, Loudness. The ten bands are never editable on the phone, but the sheet admits them in one line ("Also shaped with 10 bands on the Mac") rather than lying by silence |
| Shaped mark | One small glyph in `label3` at the row's trailing edge, drawn only when the EQ is non-flat. Not a colour code — it carries a real accessible label, "Shaped" (research Q3 #6: Roon's signal-path light, minus the colour legend problem) |
| Does this contradict the Mac? | No — it agrees with it. The Mac keeps EQ off the menu-bar popover and puts it on the Groups window's detail pane. The phone's list is the popover; the sheet is the detail pane |
| Should the 10-band ever be on the phone? | **No.** Ten faders at ±12 dB in a 393 pt column is a fight against the finger, and the audience holding the phone at 8 p.m. is not shaping a room. This is where lens C will disagree |

## Failure modes

| Situation | What happens | Verdict |
|---|---|---|
| 3-device household | READY never exceeds 5, so `SHOW N MORE` never draws. UNAVAILABLE is usually 0 and collapsed costs one 44 pt header either way. Ordering is invisible at 2 rows. The screen is today's screen | Zero cost — the design constraint, met |
| 20-device venue | One tap on `SHOW N MORE`, then scrolling. No search, no filter, no sort. A rarely-used speaker in a 20-box rig is genuinely slower to find than it would be under lens C | **Accepted loss.** The venue is a secondary audience per PRODUCT.md; the household is the design target |
| Inference is wrong | The speaker sits below the fold and there is no way to promote it | **Accepted loss**, and the riskiest thing in this proposal. Mitigation is the stable-tie rule (the list never reshuffles under a finger) plus the one-tap upgrade path noted above |
| AX3 text (largest accessibility text size) | Rows and the deck already grow via Dynamic Type and the deck's measured height. Perhaps two rows are visible at once — which makes inferred priority worth *more*, not less. The `SHOW N MORE` row is a full-width 44 pt target that grows with the type. The `≈` mark must never be the sole carrier of "shaped": the sheet and VoiceOver both say it in words | Degrades correctly |
| VoiceOver (spoken screen reader) | Long press is not reachable, so the row gains a custom action, "Speaker settings", alongside its existing adjustable level action. The shaped mark is not its own element — it folds into the row's spoken value ("Living Room Sonos, playing, 48, shaped"). `SHOW N MORE` is a button with its real count. A collapsed UNAVAILABLE announces "Unavailable, 4, collapsed". The delay banner is read as the sentence it is | Parity held |

## Cost

| Slice | Work | Protocol? | Mac work? | Days |
|---|---|---|---|---|
| **1 — ships first** | UNAVAILABLE collapsed by default with count; inferred READY ordering + the phone-local score store; `SHOW N MORE` tail past 5 | none | none | 1.5 |
| 2 | `EQSummary` + `outputDelayMs` + `setDeviceEQ`/`setMainOutEQ`; the Speaker sheet (simple tier, info, Try Again); the shaped mark; the coach's third line; the VoiceOver custom action | yes | snapshot builder + command dispatcher | 2.5 |
| 3 | Cast: `"starting"` state, the delayed-together banner, the `pendingSelection` bound fix, the Cast-group-vs-members guarantee | small | yes | 1.5 |
| — | Live pass on the physical iPhone against a real Mac, with a Cast leg | — | — | 0.5 |

**Total ≈ 6 days.** One new screen, zero new tabs, three new protocol fields.
Slice 1 stands alone, needs no Mac change, and answers the brief's primary outcome.

## Three things lenses B and C will get right that this one gives up

1. **B is right that a household says "turn the kitchen down", not "turn those
   three speakers down".** A keeps the device as the only object, so a living
   room with three speakers is muted three times unless someone already made a
   group on the Mac — a different mental model, learned on a different machine,
   by a different person. B's first screen answers it directly.

2. **C is right about the 20-device venue and the audiophile.** PRODUCT.md names
   both as real, underserved audiences. A gives them no search, no filter, no
   sort and no ten-band EQ, and bets they walk to the Mac. If that bet is wrong,
   it is wrong for the two audiences most likely to say so loudly.

3. **B and C let the user say where things go; A only watches.** A list ordered
   by a hidden score can surprise you with no recourse — and Sonos's own repair
   shipped sorting *and* pinning, not one of them. A's refusal of an escape hatch
   is the bet this proposal is most likely to lose.
