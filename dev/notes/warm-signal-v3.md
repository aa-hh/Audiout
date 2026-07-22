# Warm Signal v3 — LOCKED design spec

**Status: LOCKED contract.** This is the single source of truth that every later
Warm Signal visual task implements. It supersedes the illustrative proposal
(`warm-signal-proposal.html`) wherever they disagree; where the owner's locked
decisions disagree with the proposal mockup, the locked decision wins and the
divergence is called out inline.

Grounded in three inputs, all reconciled against post-merge `main` code:
the code-derived state model + 21-scenario catalog, the 3-lens adversarial stress
test (6 significant breaks + minors), and the owner's locked decisions (a)–(n).
This document is prose only — it changes no code. Section numbers are stable so
the resolution log (§8) and the scenario appendix (§9) can cite them.

Reference geometry lives in
`AudiouterCore/Sources/AudiouterSharedUI/PopoverColumnGrid.swift`; every measured
constant below is that file's, cited by name, never re-hardcoded.

---

## 0. Ground-truth reconciliation (read before anything else)

Three facts on `main` differ from the proposal mockup or the stress-test inputs.
The spec is written to the **code truth**, not the mockup:

1. **The membership control sits in the TRAILING column, not the leading edge.**
   `DeviceRowView.enableCheckbox` is centered on the row's `trailingAnchor`
   (`DeviceRowView.swift` L638–641), under the "Selected" header, at
   `PopoverColumnGrid.trailingControlCenterFromTrailing` (= `trailingInset` +
   `trailingControlWidth`/2 = 14 + 58 = **72 pt inward from the row trailing
   edge**). The proposal's Exhibit A½ drew the bus on the *left* for legibility.
   Locked decision (a) says the bus lives "at the checkbox's current column
   position" — so **the bus is the trailing column** (§4). The bus line drops
   from the Main Out row's destination-dropdown column, because that dropdown
   occupies the same trailing column on the Audio Out row.

2. **AP1 (RAOP) devices are fully supported now.** The `isUnsupported` /
   "AirPlay 1 · coming soon" / whole-row-0.5-alpha treatment (state model's
   "Unsupported (AP1-only)" state, proposal row 7) is **retired**. AP1 rows
   render as ordinary device rows. The reachable body-click "explanation"
   mechanic that AP1 used is inherited by the local-mix **blocked** row (§4.6,
   resolves break f). Dropdown section headers are disabled (non-selectable)
   menu items.

3. **Per-app metering has a live data source.** `BackendEvent.appLevel` drives
   `AppRowView.setLevel(_:)` via `PopoverController.updateAppLevel`
   (SharedUI `AGENTS.md`). So app-row meters are real, not dead instruments
   (softens implementation-honesty break #2). The per-app *route-armed* gold dot
   is still pure model state (§3.3), never RMS.

Owner decisions that **supersede the proposal:**

- **Menu bar (h):** KEEP the stock speaker SF Symbol with its `variableValue`
  volume arc + add a routing-active dot. The proposal's bespoke halo glyph
  (its Decision 4) is **dropped** (§5.7). This also erases the
  implementation-honesty concern about hand-authoring `variableValue`.
- **Mute (d):** muted = an engaged **slashed-glyph pill** (accent-tinted). This
  overrides the older "tint only, glyph never slashes" decision recorded in the
  state model (§3.4).
- **Teal (c):** teal is **retired** everywhere. `StatusDotView`'s routing-active
  teal dot is removed; redirect-only devices read via the bus + sublabel + gold
  dot (§3.3, §4.5).

---

## 1. Palette

Two hand-built palettes (dark flagship, warm-paper light). Never a naive
inversion. All values are authored tokens the Wave-2 token module owns; light
mode gets its own full contrast pass before ship (named risk — warm paper drifts
beige if done lazily; fallback is stock system light material + the same gold
instruments).

**Contrast floors are normative.** Non-text UI components (rings, nodes, dots,
meter fills, hairlines carrying meaning) must clear **≥3:1** against every
surface they can sit on (WCAG 1.4.11). Text must clear **≥4.5:1** (≥3:1 for
≥17 pt semibold). Any token below floor is brightened until it passes; the
Wave-5 accessibility sweep verifies each at row size.

### 1.1 Dark palette (flagship)

| Token | Hex | Role | Contrast floor |
|---|---|---|---|
| `canvas` | `#16130F` | popover/content canvas, darkest rung (gradient base) | — (base) |
| `canvas-hi` | `#1B1712` | canvas gradient top | — |
| `panel` | `#1D1915` | card/panel fill; the reference "canvas" a ring sits on | — |
| `raised` | `#241F1A` | raised well (icon well, blocked checkbox fill) | — |
| `well` | `#2B2620` | inset well (slider track trough, dropdown fill) | — |
| `hairline` | `#3A332B` | 1 px separators, card borders | ≥3:1 vs `panel` only where load-bearing |
| `text` | `#EFE9DD` | primary label | ≥4.5:1 vs `panel` |
| `text-2` | `#A89C8A` | secondary label, sublabels, micro-labels | ≥4.5:1 vs `panel` |
| `text-3` | `#7A7062` | tertiary (disabled-ish, idle tokens) | ≥3:1 vs `panel` (non-primary) |
| `gold` | `#E8B84B` | THE accent: bus node fill, route-armed dot, meter hot end | ≥3:1 vs `panel` |
| `ember` | `#8A6A2F` | gold's dim companion: meter low end, bus line ink | ≥3:1 vs `panel` |
| `glow` | `#FFD97A` | gold bloom (first-light, dot halo) — transient only | — |
| `ring-connected` | `#8D7D5E` | **connected** solid ring (warm-grey, hue-neutral) | **≥3:1 vs `panel` AND `raised`, tested at 21 px** |
| `caution` | `#E29A3D` | meter caution/hot zone ceiling — meters top out HERE | ≥3:1 vs `panel` |
| `failure` | `#D9564A` | **FAILURE-EXCLUSIVE**: failed ring, failure sublabel, diagnosis | ≥3:1 vs `panel` |
| `link` | `#D9B45E` | hyperlink text (reference page) | ≥4.5:1 vs `panel` |

The canvas is a **gradient ladder** `canvas-hi → panel` (proposal:
`#1B1712 → #1D1915`) with a faint fractal-noise grain (~5% white alpha), so the
system Liquid Glass shell above it takes a warm tint without us touching the
shell.

### 1.2 Light palette (warm paper, deepened gold)

| Token | Hex | Role | Contrast floor |
|---|---|---|---|
| `canvas` | `#F4EFE7` | canvas base | — |
| `canvas-hi` | `#F7F3EC` | canvas gradient top | — |
| `panel` | `#FBF8F2` | card/panel fill (ring reference) | — |
| `raised` | `#FFFFFF` | raised well | — |
| `well` | `#ECE5D8` | inset well | — |
| `hairline` | `#E2DACC` | separators | — |
| `text` | `#2B2519` | primary label | ≥4.5:1 vs `panel` |
| `text-2` | `#6E6353` | secondary | ≥4.5:1 vs `panel` |
| `text-3` | `#9A8F7D` | tertiary | ≥3:1 vs `panel` |
| `gold` | `#A97F1E` | **deepened** accent (contrast floor for gold-on-paper) | ≥3:1 vs `panel` (instrument) |
| `ember` | `#C2A05A` | gold's dim companion | ≥3:1 vs `panel` |
| `glow` | `#E8B84B` | gold bloom (transient) | — |
| `ring-connected` | `#A08C66` | connected ring | **≥3:1 vs `panel`, tested at 21 px** |
| `caution` | `#B3701C` | meter caution ceiling | ≥3:1 vs `panel` |
| `failure` | `#BB3A2F` | FAILURE-EXCLUSIVE | ≥3:1 vs `panel` |
| `link` | `#8A6A1A` | hyperlink text | ≥4.5:1 vs `panel` |

Theme is driven by the Mac's System/Light/Dark setting **and** the in-app theme
picker, exactly as today. `:root[data-theme]` semantics: the picker's Dark/Light
override wins; System follows the OS.

### 1.3 Accent dial token remap (decision i)

Settings › Appearance › **Accent**: Full gold / Subtle / Follow system accent.
The dial remaps **only the gold/ember/glow channel**. `failure`, `caution`,
`ring-connected`, and all text tokens are **never** remapped — red stays red,
caution stays caution, connected stays hue-neutral, in every mode.

| Instrument token | Full gold (default) | Subtle | Follow system accent |
|---|---|---|---|
| `gold` (node/dot/meter-hot) | `#E8B84B` / `#A97F1E` | `#B99B53` (desaturated) | `NSColor.controlAccentColor` |
| `ember` (meter-low/bus ink) | `#8A6A2F` / `#C2A05A` | `#6D5B34` | accent × 0.55 luminance |
| `glow` (bloom/halo) | `#FFD97A` / `#E8B84B` | **none** (no glow shadow) | accent × 1.25, clamped |
| meter gradient | `ember → gold → caution` | `ember → gold` (no caution kiss unless clipping) | `accentEmber → accent` |

Subtle removes the dot halo and flattens the meter gradient. Follow-system pulls
`controlAccentColor` (e.g. blue `#4F8EF7`) into every gold slot; the design must
be snapshot-tested in all three modes (each is a maintained look, decision 2's
cost).

---

## 2. Typography voices

All type is the system font stack (`-apple-system`/SF Pro) at semantic weights;
**text colors are always semantic tokens above, never hardcoded per-glyph**, so
the OS handles Dark Mode / Increase Contrast text automatically. Four voices:

| Voice | Font / size / weight | Color | Used for |
|---|---|---|---|
| **Name** | SF Pro Text, 13 pt, regular | `text` (member/live), `text-2` (secondary), `text-3` (tertiary/idle) | device & app names, Audio Out |
| **Sublabel** | SF Pro Text, ~9.5–11 pt, regular | `text-2` (feeds), `failure` (failure text), `text-3` (idle) | routing feeds, failure line, idle |
| **Micro-label** | SF Mono, ~8.5–11 pt, 700, tracking +0.09–0.11 em, UPPERCASE | `text-2` | section captions ("OUTPUT DEVICES"), state words (LIVE/MUTED) |
| **Readout** | SF Mono, ~10 pt, 500, tabular-nums | `text-2` | `%` volume readouts (tabular so digits don't jitter under a drag) |

**Small-caps state vocabulary** (decision g) is the micro-label voice: allowed
words are `LIVE`, `MUTED`, `IDLE`. They appear as **leading tokens inside an
existing sublabel** only (§3.5) — never as a standalone line that would grow a
single-line row (R7, §7).

Name color follows **membership/liveness**, not signal: a live redirect target
(unchecked but `liveAppNames` non-empty) keeps its live feed token at full
`text` contrast so the playing row is never the greyest name in the list
(resolves daily-usability minor break — §3.5, §8).

---

## 3. The status cluster — vocabulary, ladder, and matrix

Everything about a device's state lives on the device's own identity:
**ring** (connection) around the icon, **gold corner dot** (route armed & held)
on the icon's corner, **meter** (loudness) directly under the name. Three
independent channels, one rule each. Gold means exactly one thing everywhere.

### 3.1 Per-channel precedence ladder

The global emphasis ladder is
**failure > connecting > configuration > signal > hover**. A lower rung may never
move, recolor, or outrank a higher rung's channel (R2, §7). Applied per channel:

- **Ring channel** (connection lifecycle): `failed` > `connecting/reconnecting`
  > `connected` > `off/none`. Teal is retired, so there is no routing rung on
  the ring (resolves state-collision minor + break on teal precedence). Ring is
  driven by `Device.connectionState` alone.
- **Gold-dot channel** (route armed): binary, pure model state (§3.3). Never
  competes with the ring — different element, different position.
- **Meter channel** (loudness): lowest rung. RMS-driven. Confined to the fixed
  meter column; never restyles, moves, or recolors anything above it.
- **Sublabel slot** precedence (§3.5): failure text > MUTED token > feeds list.
- **Hover**: below everything; a neutral wash only, never on gold.

### 3.2 Ring — connection (decision c)

Replaces the current corner **dot** connection indicator (`StatusDotView`) with
a **ring around the icon**. The corner dot is repurposed to gold route-armed
(§3.3). Ring states:

| Connection state | Ring |
|---|---|
| `.off` | **No ring** (discovered, nothing to report) |
| `.connecting` / `.reconnecting` | **Dashed ring, breathing** (opacity/scale pulse). Under Reduce Motion: the **dashed FORM survives, static** (no animation). Dashed = "incomplete", legible frozen — this is the pending signal, not motion. |
| `.connected` | **Solid quiet ring**, `ring-connected` token, stroke ~1.6 pt. Hue-neutral warm-grey (gold is reserved for the dot/meter). **Tested minimum contrast floor ≥3:1 vs canvas at 21 px, both themes** — connected must be scannable as a column, not discoverable on inspection. |
| `.failed` | **Red solid ring**, `failure` token, stroke ~1.8 pt (redundant extra weight so the failed row wins the scan even beside flickering meters). Failure-exclusive red. |

Why dashed-vs-solid FORM: under Reduce Motion, motion is the only thing today's
breathing dot loses; a form difference keeps pending-vs-connected legible with
zero motion and zero new colors (resolves the **blocking** Reduce-Motion collapse
— break in §8). Ring diameter ≈ the 26 pt icon box; the tested size is 21 pt
(the visible ring circle inside the box).

Ring geometry uses the icon column (`PopoverColumnGrid.iconWidth` = 26,
`iconGlyphPointSize` = 18). No new column.

### 3.3 Gold corner dot — route armed & held (decisions c, d)

The gold dot on the icon's bottom-right corner (the retired connection-dot
position; `statusDotDiameter` = 10, `statusDotInset` = 3,
`statusDotBorderWidth` = 1.5) means **"this route is armed and held"** — a
**pure model-state predicate, NEVER audio-driven**. So paused == playing ==
freshly-opened for the dot (only the meter differs — R3, §7). This is the single
semantic that resolves the LED contradiction (the **blocking** break across all
three stress lenses). The word "audibly" is deleted from the vocabulary.

**Predicate (normative):**

```
routeArmed(device) =
    ( device ∈ activeMainOutTarget
      ∧ device.connectionState == .connected
      ∧ !device.rowMuted
      ∧ !masterMuted )
  ∨ ( !device.liveAppNames.isEmpty )
```

where `activeMainOutTarget` is **the set the Main Out dropdown currently points
at** — the Selected Devices set when Main Out = Selected Devices, or the group's
member set when Main Out = a saved group. **Membership is evaluated against the
active target, not the Selected set** (resolves the group-mode LED-lies break):
a playing group member lights its dot even when its Selected checkbox is dimmed
in a dormant card.

`masterMuted` is folded in so master mute drains **every** device dot, not just
Main Out's — no "four gold lamps on a silent house" contradiction (resolves the
master-mute state-collision break). The per-app `liveAppNames` branch is
independent of master mute (redirect streams bypass the main-out master).

Dot appearance: `gold` fill + `glow` halo (Full-gold mode) when armed; dark/empty
socket (`#34302A` dark) when not armed. Cap the lit dot's size and luminance so
it reads as an indicator, not a beacon beside the bus scan (R1, §7).

### 3.4 Mute (decision d)

Muting is config-adjacent, not connection. When a row is muted:

- The mute button shows an **engaged slashed-glyph pill** — `speaker.slash.fill`,
  accent-tinted (gold/accent), inside a subtle pill. (Supersedes the old
  "tint-only, no slash" rule — §0.)
- The **meter drains** (mute removes the row from `routeArmed`'s unmuted
  condition, so `routeArmed` is false → meter empty).
- The **gold corner dot goes dark** (same reason).
- The **bus node stays FILLED** — membership ≠ mute (a muted device is still in
  the mix set).
- The **connection ring is unchanged** (still connected).
- The **slider stays live** and the **`%` readout keeps its number at normal
  (controllable) treatment** — mute never dims the readout (resolves the
  channel-4-vs-5 dimming contradiction; A5: the user pre-sets the unmute level).
- **No row reflow** — height and column x unchanged (R7).

A single-line muted member relies on pill + drained meter + dark dot (three
cues). The MUTED word only appears when the row already has a sublabel (§3.5).

### 3.5 Sublabel slot (decisions a, g)

The bus (§4) now carries membership, so **every "Main Out" sublabel disappears**
— a member with no extra feeds is single-line. The sublabel lists **only
additional feeds (app names) or failure text or a state word.** Slot precedence:

1. **Failure** — `Couldn't connect` (`failure` token). Outranks all.
2. **Unavailable** — `Unavailable` (`text-3`), when `!isAvailable`.
3. **MUTED token** — leading `MUTED ·` prepended to the feed list, **only if a
   feed list exists** (`MUTED · Spotify`); never added to an otherwise
   single-line row (no height change — R7).
4. **Feeds list** — live app names, `·`-joined (e.g. `Spotify`, or
   `Spotify · Podcasts`). A live-confirmed feed token renders at full `text`
   contrast (the live redirect target's text anchor). Intent-only (routed but
   not live) renders `AppName (idle)` in `text-3` so an enabled-but-quiet
   slider always has a visible cause (resolves the idle-redirect nitpick).

Failure never silently drops the feed truth: a device that is failing whole-mix
but still carries a live redirect may compose `Couldn't connect · Spotify` so a
loud room never reads as fully dead (resolves the failed-while-routing break).

### 3.6 Ring × Dot × Meter matrix (over the state model's real states)

Every combination below is a real orthogonal state from the inventory.
"armed" = §3.3 predicate. "meter" is loudness only and additionally requires the
popover open + RMS>0. Bus node covered in §4.

| Real state | Ring | Gold dot | Meter | Bus node | Sublabel |
|---|---|---|---|---|---|
| Member, connected, playing | solid `ring-connected` | **gold** | fill (to caution ceiling) | **filled** | — |
| Member, connected, **paused** | solid | **gold** | empty | filled | — |
| Member, connecting | **dashed breathing** | dark (not yet connected) | empty | filled | — |
| Member, reconnecting (wake) | dashed breathing | dark | empty | filled | — |
| Member, **failed** | **red** | dark | empty | filled (membership held until honest toggle-off) | `Couldn't connect` |
| Member, connected, **muted** | solid | dark | drained | filled | MUTED (if feeds) |
| Member, connected, **master-muted** | solid | dark | drained | filled | — |
| **Redirect-only** (unchecked, live app) | solid | **gold** (`liveAppNames`≠∅) | fill | **hollow, line detours** | `Spotify` (full contrast) |
| Redirect-only, connecting | dashed breathing | dark | empty | hollow, detour | `Spotify (idle)` |
| Standing route, **idle** (app not running) | none/solid per conn | dark | empty | hollow, detour | `Podcasts (idle)` |
| Not member, disconnected | none | dark | empty | hollow, detour | — |
| **Blocked** (local-mix, the Mac) | none | dark | empty | **hollow, greyed node**, body-click explains (§4.6) | — |
| **Unavailable** | none (row-level tint dim) | dark | empty | hollow, tinted | `Unavailable` |
| Group member (dormant card, active group, playing) | solid | **gold** (armed vs active target) | fill | **filled, full emphasis** (§4.7) | — |

The matrix is exhaustive over `connection × armed × muted × membership ×
availability × blocked`; §9 walks all 21 catalog scenarios against it.

---

## 4. The bus — membership control (decision a)

Replaces the membership **checkbox's drawing** with a **bus**: a continuous
vertical line dropping from the Audio Out row down one fixed column, past every
device row. A device in the mix has a **filled gold node ON the line**; a device
not in the mix has a **hollow node the line visibly DETOURS around** (a
wire-hop arc, the circuit-diagram idiom). **Only the drawing changes** — the same
`NSButton` checkbox, action path (`enableToggled(_:)` → delegate), keyboard, and
VoiceOver live underneath (§4.8).

### 4.1 Geometry (off PopoverColumnGrid)

- **Column x:** the node column is centered at
  `PopoverColumnGrid.trailingControlCenterFromTrailing` (= `trailingInset` +
  `trailingControlWidth`/2 = **72 pt inward from the row trailing edge**) — the
  checkbox's real current position (§0.1). The bus is the **trailing column**.
- **Node diameter:** ~13 pt (matching the current `.switch` checkbox visual box),
  a named constant added to `PopoverColumnGrid` in Wave 2 (e.g. `busNodeDiameter`).
- **Line width:** ~2 pt, `ember` token (Full-gold), remapped per §1.3.
- **Origin:** the bus starts at the Audio Out (Main Out) row, at the same column
  where its destination dropdown sits, and runs to the last device row's node.
- **Every node sits at exactly the same x** — toggling changes only **fill** and
  **line path**, never position. Zero layout shift (R7, §7).

### 4.2 Drawing rules

- **Line:** a single vertical stroke at the column x. Between two consecutive
  filled (member) nodes it runs straight. Approaching a **hollow** node, the line
  **bows outward into a small semicircular hop arc** around the node (the wire
  detour), then returns to the column x — the node is visibly *skipped*, not
  connected. Order-proof: tapping devices 1 and 3 makes the line bypass device 2.
- **Filled node:** solid `gold` disc with `ember` rim, sitting **on** the line.
- **Hollow node:** `panel`-filled disc with a `ember`/`hairline` rim, the line
  arcing around it.
- The bus is drawn once per rebuild as a layer behind the row nodes; each row
  contributes its node + its segment (top-half / bottom-half rails so the line is
  continuous across rows — mirrors the proposal's `.rail rt/.rail rb/.bypass`).

### 4.3 Filled (member / tapped-in)

Gold node on the line. `enableCheckbox.state == .on`. Drops "Main Out" sublabel
(the bus says it). See matrix §3.6.

### 4.4 Hollow (not a member / tapped-out)

Hollow node, line detours. `enableCheckbox.state == .off`. If the device is
nonetheless playing via app routes, it names its own feed in the sublabel
(§3.5) and lights its gold dot — the "loud unchecked Office" state now *looks*
different (hollow node + detour + named feed) instead of contradictory.

### 4.5 Redirect-only target

A specific hollow case: unchecked (line detours the node) + `liveAppNames`
non-empty → gold corner dot on + live meter + full-contrast feed token. Teal is
retired; the hollow-detoured node plus the named source explain it better than a
second accent color (decision 8 / c).

### 4.6 Blocked (local-mix) — the reachable-trigger fix (decisions a, f)

When the local Mac cannot join a mixed set (`apply(blocked:)`, only the Mac,
`!canSelectLocalSpeaker`): the node renders **hollow and greyed** (distinct from
an ordinary hollow node), and the underlying checkbox is **honestly disabled**
(`isEnabled = false`) — no bouncing dishonest toggle.

**The refusal note has a reachable trigger** (resolves the significant break f):
the blocked row **adopts the AP1 body-click signature** — a `mouseDown` on the
row body / name / node area presents an **in-place one-line refusal note**
(sourced from `GroupController.localMixRefusalReason`), reusing the proven
`deviceRowDidRequestUnsupportedExplanation` host mechanic. A disabled control +
hover tooltip is **never** the only surfacing. Signature stays distinct from
unavailable (which shows an `Unavailable` sublabel and dims at the row level,
not a node-grey + tap-to-explain).

### 4.7 Dormant / derived-group scope (decision e)

When the Main Out target is a saved group and **the checked set equals the active
group** (the derived-identity / dedup case):

- Member rows render at **FULL emphasis** — bus nodes full gold, gold dots lit
  (armed vs the active target, §3.3), meters live, **no "Inactive" note** (the
  Audio Out dropdown title carries the group identity — resolves the
  dormant-card-vs-active-group break).
- Dim **only** rows that fall **outside a genuinely-diverging target**, and dim
  via **tint** (node → `text-3`/off tint, checkbox at full alpha — not a
  0.4-alpha competition with the AP1 signature; resolves the stacked-dim break),
  never via whole-row alpha.
- A **failed** group member always renders at **full failure emphasis**
  regardless of dormancy (ladder rung 1 exempts it — resolves the
  failure-inside-inactive-card break). The card note, if shown, gains a
  failure-aware variant. Failure in group mode **never silently edits the saved
  group**; retry re-joins the group session.

### 4.8 Hover & AX contract

- **Hover:** the row's neutral hover wash only (§7 R7);
  `PopoverColumnGrid.rowHoverWashAlpha` = 0.10. Never gold, never on the node.
- **AX:** the node **is** the `enableCheckbox` — unchanged role
  (`.checkBox`), unchanged label ("include in main audio"), unchanged
  value (checked/unchecked), unchanged keyboard (Space toggles), unchanged
  name-click convenience path. VoiceOver reads "include in main audio, checked".
  The `test_*` hooks drive the same delegate path (SharedUI `AGENTS.md`). The
  drawing is a pure visual skin over the real control; snapshot fixtures must
  cover filled / hollow / greyed-blocked / dormant-tinted / hover.

---

## 5. Per-surface treatments

The strategy everywhere: **Apple owns every container and every control; we own
only what's painted inside the content area** (the Liquid Glass map). Glass takes
its tint from the warm canvas beneath it, so Apple's chrome reads warm without us
touching it; a macOS update restyles the shell on recompile and nothing of ours
is in its way. Nothing we own is a control — checkbox, slider, dropdown, switch
stay real AppKit with behavior/keyboard/VoiceOver intact; we redraw only the
slider track/knob look and the bus/ring/dot/meter instruments.

### 5.1 Popover

Warm canvas (`canvas` gradient + grain) inside the system Liquid Glass popover
shell (untinted, untouched). Three cards top-to-bottom, section micro-labels:

- **MAIN AUDIO** → single Audio Out (Main Out) row. Full control set: gold dot
  (armed = active target has ≥1 live member), meter under the name, mute
  button, real slider + readout, and the **destination dropdown** in the trailing
  column (the bus originates here). Dropdown title names the current target
  ("Selected Devices" clean — **no `(n)` count**, decision m — or a group name).
- **OUTPUT DEVICES — the main mix plays here** → `DeviceRowView`s (Current Device
  + AirPlay). Bus runs down the trailing column. "Output" framing (decision m);
  AirPlay wording kept in device context.
- **APP EXCEPTIONS — route one app elsewhere** → `AppRowView`s + `±` footer. App
  rows carry a **dropdown** (not a bus node) — a device is a *place* you include,
  an app is a *source* you redirect. An unrouted app's dropdown default reads
  **"Follows main output"** (decision 3 — names the relationship). App-row gold
  dot armed = destination ≠ standalone ∧ app running (pure model); app-row meter
  = `BackendEvent.appLevel`.

Empty states: §5.9.

### 5.2 Settings (decisions i, j — chrome stays system-native)

Settings is **stock macOS window chrome**: standard material, tabs, radio
buttons, dropdowns, typography — **no warm canvas, no gold on the chrome.** What
makes it premium: every consequential control self-explains with a live hint, and
the **theme tiles preview the actual product** (the only warm/gold pixels are
inside those tiles, because they depict the product).

New **Appearance › Accent** row (decision i): three radios — **Full gold** /
**Subtle** / **Follow system accent** — hint: "How strongly meters, dots, and
rings use the brand gold." Token remap per §1.3.

### 5.3 Groups (decisions j — content pane warm, chrome stock)

Native window shell (title bar, traffic lights, glass sidebar, sidebar selection,
"New Group" sheets — all Apple's). The **content pane** is ours: warm canvas, the
icon well with its halo ring, the same status-cluster + meter + fader language as
the popover. A group visibly plays while you edit it; the group master glides its
members when dragged (§6). Day-to-day you never open this to *use* a group —
activation is two clicks in the popover's Audio Out dropdown; this window makes
and tunes them.

### 5.4 Shell — the control-panel host (decision j, k)

In **release** the control-panel shell (`ControlPanelWindowController` +
`ControlPanelBackingView`) hosts Groups/Settings content. The shell's
`ControlPanelBackingView` bubble fill currently draws `windowBackgroundColor`
(L73). **Repoint the bubble fill to the warm `canvas` token** so bubble + beak +
content pane are **one continuous warm shape with no seam**, light AND dark. The
hosted content is left transparent so the live warm fill shows through
(`configureContentAppearance` already relies on a live fill tracking theme
flips — keep it live, never a frozen snapshot). This is the one approved
custom-drawn shell exception; the repoint changes the fill token only, not the
two-window architecture. Settings content, when hosted, still paints its own
system material over the warm fill (§5.2) — that's intended.

### 5.5 Menu bar (decision h — supersedes proposal Decision 4)

**Stock speaker SF Symbol**, template-rendered, with its **`variableValue`
volume arc KEPT** (the arc fills with master volume — free system machinery, no
hand-authored variants). Plus a **small routing-active dot** (mandatory, not
optional — resolves the menu-bar-glance break): **present = ≥1 live
route/broadcast, absent = passthrough/idle.** Because template images are
monochrome, the dot is **presence/absence only, never a color.**
**Master-mute drains the arc** (mirrors the meter-drain rule) so the closed-popover
glance never lies "80% and broadcasting" while silent (resolves the menu-bar
mute break). The dot answers "am I still broadcasting?"; the arc answers "how
loud?".

### 5.6 Diagnosis panel (`ConnectionDiagnosisView`)

Restyle only: warm-tinted inset card (`failure` at ~12% alpha), bold headline,
`text-2` suggestion body, **Try again** / **Copy details** / quiet `✕`. Auto-
expands once per failure episode under a `.failed` row; dismissal recorded per
episode; `Copy details` disabled when `failure.detail == nil`. Failure red here
is the same failure-exclusive token — never shared with meters. Full emphasis
even inside a dormant card (§4.7).

### 5.7 (reserved — menu-bar halo glyph dropped, see §5.5)

The proposal's bespoke halo glyph is not built (decision h). No custom menu-bar
drawing task exists in the waved plan.

### 5.8 Onboarding (decisions k, l)

Warm canvas + permission tiles that unify a warm-neutral resting state with
**gold-lit granted icons** (a granted permission's icon warms to gold — the one
place gold marks success outside the instruments, justified as the setup
"power-on"). Copy uses plain **"speakers"** (not "AirPlay") in onboarding
context (decision m). One-time **power-on meter sweep at Done** — a single left-
to-right meter bloom across the tiles (Reduce Motion skips it entirely). After
the popover redesign lands, onboarding gains a short **capability tour** (groups,
per-app routing) in the new visual language (decision 7); permission mechanics
stay exactly as built.

### 5.9 Empty states + feature teaching (decision l)

- **Devices empty:** honest, distinguishable — "Looking for speakers…"
  (discovery running) vs a "none found" resting state that hints at Local Network
  permission (a real onboarding failure mode). Never bare whitespace.
- **Applications empty (contextual hint):** first-use hint — copy voice:
  *"Route one app somewhere else — music to the house, calls on your Mac. Use +
  to pick an app."* Teaches the feature at the moment of emptiness, not a modal.
- **Groups empty (contextual hint):** *"Save a set of speakers as a group, then
  switch to it in two clicks from the menu bar."*
- **"How Audiouter works" reference page:** a plain, calm explainer (its own
  view or Settings pane) covering the three planes — main output, groups, app
  exceptions — and the bus idiom. **Spec the copy voice, not the layout**: warm,
  concrete, second person, one idea per line, no marketing. This spec does not
  fix its implementation; a later task owns it.

---

## 6. Motion vocabulary (decision n)

Energy-gated: **all animation self-stops at rest** (the metering/display-link
discipline `LevelMeterView` already embodies). Reduce Motion = instant swaps +
static forms everywhere.

| Trigger class | Motion |
|---|---|
| **User-driven** (tap a node, toggle mute) | spring, **response 0.30, damping 0.80** |
| **System-driven** (model change not from this user's direct input) | **180–260 ms easeOut** |
| **Direct slider drag** | **NEVER animated** — zero added latency; knob tracks the finger 1:1 |
| **Glide-to-value** (system-driven group/preset apply, with counting readouts) | **220 ms**, readouts count up/down in step |
| **First-light bloom** | LED/dot `ember → gold` bloom, **450 ms**, **only on a model transition INTO route-live while the popover is open** — never on initial open (steady states render settled); never RMS-triggered |
| **Connecting ring** | breathing pulse (`statusDotBreathDuration` timing); static dashed under Reduce Motion |

**Live data is never eased** (R6, §7): slider positions from the model —
**including remote/echo volume events** (speaker-side button presses) — **snap
with zero easing**; a held hardware button must not rubber-band the slider.
Glide applies only to user/system group-preset activation, not to per-event
volume echoes. During a Main Out **destination switch**, the Main Out instrument
adopts the **pending** vocabulary — the dot breathes at low alpha (static dim
under Reduce Motion), settling to lit on first light — so the multi-second
handshake gap never reads as dead/broken (resolves the Main-Out-pending break).

**No transient fires on open:** on popover open every steady state renders
settled with no entrance animation; transients fire only on model transitions
observed **while already open** (resolves the "three blooms on every open" break).

Release gate includes **zero idle CPU** and **zero added latency on the volume
path**.

---

## 7. The eight checkable house rules

Each is a pass/fail gate for every surface and every snapshot fixture.

1. **Gold budget.** Gold appears only on **instruments** — bus nodes, route-armed
   dots, meter hot end, and the onboarding granted-icon success state. Chrome and
   text stay semantic tokens. A lit dot's size/luminance is capped so it reads as
   an indicator, not a beacon. No gold "at rest" on containers or hover.
2. **Emphasis ladder.** failure > connecting > configuration > signal > hover. A
   lower rung never moves, recolors, or outranks a higher rung's channel.
3. **Paused test.** Config, connection, bus, and armed-dot render **identically**
   playing vs paused vs freshly-opened. **Only meter fills may differ** between
   those three.
4. **State-driven vs signal-driven.** Words, rings, bus nodes, and gold dots
   render from model state in the **first frame** on open; only meters wait on
   RMS. RMS is confined to the fixed meter column.
5. **Distinct negative signatures.** Blocked (local-mix) and unavailable render
   distinctly, and **each has a reachable in-place explanation** (blocked = grey
   node + body-click note; unavailable = `Unavailable` sublabel + row-tint dim).
   No two "can't" states look alike; no dead-end disabled control.
6. **Live data is never eased.** Slider positions from the model (incl. remote
   echo events) snap; direct drags are never animated.
7. **No reflow / no row-scale motion.** Toggling membership, mute, connection, or
   armed state never changes row height or any column x. The bus changes only
   fill and line path. Meter level never drives layout, row height, or emphasis.
8. **Failure red is exclusive.** `failure` (`#D9564A` / `#BB3A2F`) appears **only**
   on failure surfaces (failed ring, failure sublabel, diagnosis). Meters top out
   at `caution`; a loud party can never impersonate a failure.

---

## 8. Resolution log — every stress-test break

The stress test raised **6 significant/blocking breaks** (some counted once
across lenses) plus minors/nitpicks. Each is resolved here with a citation.
**Zero unresolved.**

### Significant / blocking

1. **LED predicate self-contradictory ("audibly-streaming" vs model state); R3
   incoherent; breaks the paused killer case** (all 3 lenses; blocking).
   → **Resolved §3.3:** the gold dot is a pure model-state "route armed & held"
   predicate; the word "audibly" is deleted; §7 R3 amended to "only meter fills
   may differ" between playing/paused/freshly-opened. §6: first-light triggers on
   the model transition, never on sound.

2. **Reduce-Motion collapses connecting-vs-connected into two static grey rings**
   (state-collision, blocking; daily-usability + implementation-honesty).
   → **Resolved §3.2:** pending is a **dashed FORM** (static under Reduce Motion),
   connected is **solid**; form, not motion, carries pending.

3. **Connected ring too quiet to scan on the dark canvas; no-ring vs
   quiet-ring near-indistinguishable** (daily-usability; state-collision).
   → **Resolved §1.1/§1.2/§3.2:** `ring-connected` token with a **normative ≥3:1
   contrast floor tested at 21 px in both themes**; the armed gold dot carries the
   confirmation scan alongside the ring.

4. **Shared `#D9564A` "peak-and-failure" hue lets meters flash the failure color
   during loud playback, devaluing the top ladder rung** (all 3 lenses;
   significant).
   → **Resolved §1 (`caution` = meter ceiling, `failure` = exclusive) + §7 R8:**
   meters top out at `caution` `#E29A3D`; `failure` red appears only on failure
   surfaces, always steady, with redundant ring weight.

5. **Local-mix refusal note has no reachable trigger (disabled checkbox emits
   nothing; name-click is a no-op)** (daily-usability + implementation-honesty;
   significant).
   → **Resolved §4.6:** blocked rows adopt the AP1 **body-click** signature →
   in-place one-line refusal note from `localMixRefusalReason`; checkbox stays
   honestly disabled.

6. **Dormant-card treatment contradicts an active group's own live member rows
   ("Inactive" note over playing rows); group-mode failure + membership term
   undefined** (all 3 lenses; significant).
   → **Resolved §3.3 (membership vs active target) + §4.7:** derived-identity case
   renders members at full emphasis, no "Inactive" note; dim only genuinely-
   diverging rows via tint; failed member always full emphasis; failure never
   edits the saved group.

### Minor / nitpick

- **Teal ring precedence/driver undefined** → §3.1/§3.2: **teal retired**; ring
  ladder is failed > connecting > connected > off.
- **Redirect target's name greyed (hardest to find while playing)** → §2/§3.5:
  live feed token at full `text` contrast; the row's scan signature = gold dot +
  bright feed token + hollow-detoured node.
- **Main Out has no pending vocabulary for the destination-switch gap** → §6:
  Main Out dot breathes low-alpha during the handshake, settles on first light.
- **Menu-bar routing dot optional; arc lies under master mute** → §5.5: dot is
  **mandatory** (present=live route, absent=passthrough); **master-mute drains
  the arc.**
- **Remote/echo volume events unassigned in the motion rules** → §6: they are
  live data → **snap, no easing.**
- **MUTED word contends for the sublabel slot / could reflow a single-line row**
  → §3.5: MUTED is a **leading token** in an existing feed sublabel only, ranked
  below failure; single-line rows never gain it (no height change).
- **Party-mode: lit gold dots compete with the checkbox scan** → §3.3 (cap
  dot luminance/size) + §7 R1; the bus (not a checkbox) is now the config scan,
  and it lives in the trailing column with the meter+dot grouped in the leading
  region.
- **App-row instruments promised without a signal** → §0.3: `appLevel` is wired;
  the app-row armed dot is pure model state (destination ≠ standalone ∧ running),
  meter = `appLevel`; fixed columns reserved so nothing reflows.
- **Idle redirect target: enabled slider with no visible cause** → §3.5:
  `AppName (idle)` token in `text-3` gives the slider a visible cause.
- **`%` readout double-assigned (mute-dim vs controllable-dim)** → §3.4: mute
  never dims the readout; dimming stays controllability-only.
- **App-row selection vs hover both "neutral"** → §7 R5 / §5.1: hover = neutral
  wash, selection = **system-accent** wash (accent is permitted; the gold budget
  governs gold, not chrome accent). Distinct, load-bearing selection preserved.
- **First-light could fire on every open** → §6: transients fire only on model
  transitions while already open; open renders settled.
- **`variableValue` cost misstated for a bespoke glyph** → §5.5: bespoke glyph
  dropped; stock SF Symbol keeps `variableValue` for free.
- **Blocked vs unavailable vs AP1 dim taxonomy blurred** → §0.2 (AP1 retired,
  taxonomy shrinks to blocked + unavailable) + §4.6/§4.7 (each distinct,
  non-alpha-competing).

---

## 9. Scenario → rendering appendix (all 21)

Every catalog scenario walked against §3.6 + §4. Format: the load-bearing render.

1. **Party mode** — 4 filled gold bus nodes (config scan = the bus, trailing
   column), 4 solid connected rings, 4 gold dots, 4 meters filling to `caution`
   ceiling, Mac node hollow. Master slider = the one pull-down. R1/R3/R8 hold.
2. **Paused, fully configured** — identical to #1 **except every meter empty**
   (R3). Nodes, rings, gold dots all lit — armed ≠ audible (§3.3). Reads intact.
3. **One muted among live** — bedroom: filled node, solid ring, **dark dot,
   drained meter, engaged slashed-pill**; slider live, `%` normal (§3.4). Others
   metering. No reflow, no false "died".
4. **Connecting while others play** — new row: filled node, **dashed breathing
   ring**, dark dot, empty meter; two playing rows untouched. Reduce Motion →
   static dashed (§3.2). Honest toggle (bus node reflects real state).
5. **Failure mid-playback** — garage: **red ring (thick)**, dark dot, empty
   meter, `Couldn't connect` sublabel, diagnosis panel; node held until honest
   toggle-off. Only red on the panel (R8). Others unaffected.
6. **Redirect-only Mac silent, AirPlay playing** — Sonos: filled node, solid
   ring, gold dot, meter. Current Device: **hollow node, full standing** (not
   faded — recovery path stays findable). One click re-taps the Mac node.
7. **Destination switch (headphones→Sonos)** — Main Out dropdown title names the
   real target; during the gap the **Main Out dot breathes low-alpha** (§6), no
   error color. Sonos node fills on connect.
8. **Group active, members visible** — Main Out title = "Downstairs"; both member
   rows **full emphasis, filled nodes, gold dots, live meters, no "Inactive"
   note** (§4.7). Uncheck one → set ≠ group → title falls back honestly.
9. **Spotify routed away, system local** — Kitchen: **hollow node, line detours**,
   solid ring, **gold dot** (`liveAppNames`), **live meter**, `Spotify` at full
   contrast. Reads "receiving a per-app stream", not a bug (§4.5).
10. **App routed but silent** — Podcasts row: dropdown = "Bedroom" (the info);
    Bedroom device row hollow node, dark dot, empty meter, `Podcasts (idle)`
    token gives the enabled slider a cause (§3.5).
11. **Mixed AP1/AP2** — **all render as ordinary rows** (§0.2, AP1 supported).
    No dim taxonomy needed; any genuinely `Unavailable` device shows the
    unavailable signature (§3.6), distinct from blocked.
12. **Local-mix block** — Mac node **hollow + greyed**, checkbox disabled;
    **body-click → in-place refusal note** (§4.6). "Mac alone = passthrough" path
    stays evident. Distinct from unavailable.
13. **Volume drag under load** — dragged row **stable, no reflow, no meter layout
    shift**; knob 1:1, `%` tabular (§2). Other meters are quiet background (R7).
14. **First launch, zero devices** — Current Device filled node (proof of life);
    AirPlay section honest "Looking for speakers…" vs "none found" (§5.9). Not
    bare whitespace.
15. **Reconnecting after wake** — both rows: filled nodes, **dashed breathing
    rings**, dark dots, empty meters — intent+progress+no-audio-yet, per row.
    Split outcome (one → solid, one → red) readable row-by-row. Reduce Motion →
    static dashed (§3.2).
16. **Per-app target disappears** — dropdown re-renders from persisted truth to
    "Current device" on open (§6 live data, no cached old value); device row
    drops its gold dot as `liveAppNames` empties.
17. **Group master drag** — member sliders move **1:1 with the master, no easing**
    (R6); ratios hold; readouts count. Post-drag numbers reconcile.
18. **Speaker-side volume change** — slider **snaps** to the reported level, no
    flash/pulse; a local drag wins for its duration (§6).
19. **Everything at once** — failure red (thick ring + sublabel + diagnosis)
    **outranks** the 3 caution-ceiling meters and the redirect target's gold dot;
    drag target stable; count mismatch resolvable by scanning rings + bus nodes.
    The exact frame the ladder (R2) is judged against.
20. **Excluded app (Zoom) local** — no Zoom row, no meter/route implying it's
    streamed; Main Out meter reports the true system mix only (R4 exact meter
    semantics). No see/hear contradiction.
21. **Menu-bar glance** — stock SF Symbol arc = master volume; **routing dot
    present = broadcasting, absent = passthrough** (§5.5); master-mute drains the
    arc. On open, steady states render settled (no false-silence flash — meters
    are late garnish, R4).

All 21 walk cleanly against §3.6/§4/§5. No scenario produces an undefined or
contradictory render.

---

## 10. Invented decisions (not covered by the locked inputs)

Flagged for owner review; each is a reasonable reading, not an owner ruling:

- **Bus column = trailing column.** The locked decision says "the checkbox's
  current column position"; the code truth is the trailing column (§0.1), which
  contradicts the proposal mockup's leading-edge drawing. I chose code truth. If
  the owner wants the bus on the *leading* edge (as drawn), that is a column move
  and a `PopoverColumnGrid` change — flag before Wave 3.
- **`ring-connected` exact hex** (`#8D7D5E` dark / `#A08C66` light) and the **21 px
  tested size** are my picks to satisfy the ≥3:1 floor; the Wave-5 sweep may
  brighten them. Owner may prefer a warmer tint.
- **Subtle/Follow-accent exact remap values** (§1.3) are derived from the
  proposal's `.v-subtle`/`.v-accent` CSS; the `ember`/`glow` accent derivations
  (×0.55, ×1.25) are my formulas, not owner-specified.
- **Sublabel MUTED-token rule** (token only when a feed sublabel exists, never on
  a single-line row) is my anti-reflow reading of decisions (d)+(g); the owner
  allowed small-caps state words without specifying the no-reflow constraint.
- **Onboarding "granted icon warms to gold"** is my reading of decision (k)'s
  "gold-lit granted icons" — it puts gold outside the instrument set (success
  state), a deliberate, flagged exception to R1.
- **Reference page + empty-state copy** are voiced, not authored — a later task
  owns final wording (decision l says spec the voice, not the implementation).
- **Bus hop-arc exact radius / node diameter** (~13 pt) are visual picks for the
  Wave-2 `PopoverColumnGrid` constants; tune live.
