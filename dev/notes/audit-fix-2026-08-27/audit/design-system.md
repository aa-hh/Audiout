# Design-system audit — Audiout shared visual layer

Scope: `AudioutCore/Sources/AudioutSharedUI/` in full, cross-checked against
`docs/FIGMA-DESIGN-SYSTEM.md`, `dev/notes/warm-signal-v3.md`, root `AGENTS.md`
(gold-budget house rules 1–8), `AudioutSharedUI/AGENTS.md`, and `PRODUCT.md`.
Consumption sampled across `AudioutPopoverUI`, `AudioutWindowUI`,
`AudioutSettingsUI`, `AudioutOnboardingUI`, `AudioutApp`.

Read-only audit. Every contrast number below was computed from the literal
hexes in `Tokens.swift` using the WCAG 2.x relative-luminance formula; system
semantic colours were composited at their documented macOS alphas
(secondary .50/.55, tertiary .26/.25, quaternary .10) over the token grounds.

---

## Scores

| # | Dimension | Score |
|---|---|---|
| 1 | Token integrity | 3 / 4 |
| 2 | Appearance correctness | 3 / 4 |
| 3 | Contrast | 2 / 4 |
| 4 | Component consistency | 3 / 4 |
| 5 | Identity discipline | 4 / 4 |
| | **Total** | **15 / 20** |

**Findings: 0 P0 · 4 P1 · 7 P2 · 6 P3**

---

## Verdict

This is an unusually well-governed token layer. `Tokens.swift` is a single
sanctioned palette module with a live dynamic provider per case, an
accent-dial seam inside the provider, per-case written contrast rationales,
and a real Increase-Contrast axis — the discipline the root `AGENTS.md`
demands, actually practised. The Warm Signal identity stays in its lane:
backgrounds and gold only, structure and controls stock AppKit, instruments
authored in every mode, menu-bar icon template-only. Reduce Transparency is
covered at every real `NSVisualEffectView`. Shared components are genuinely
shared rather than re-implemented per host.

Three things pull the score down, and they are all the same shape — the
governance is thorough where someone measured, and absent where nobody did:

1. **Typography never received the colour treatment.** The same governance
   sentence covers "color, type, layout, and material", but ~24 call sites
   across all five UI targets set `NSFont` by hand, including sizes (9.5, 11,
   11.5, 12, 14.5, 20, 24 pt) that no `Tokens.Font` case represents, and at
   least one exact duplicate of an existing token.
2. **Three layer-colour instruments miss the accent-dial broadcast** the
   token module itself documents as mandatory — including `LevelMeterView`,
   which stamps both dial-remapped tokens.
3. **The measured-contrast commitment is honoured per token, not per call
   site.** The authored tokens pass their floors. The *system* semantic
   tokens they sit beside do not: `tertiaryLabel` carries state text and the
   dormant rail at 1.85–2.26:1, and `secondaryLabel` carries body text in
   light at 3.93:1 across 92 sites — while the codebase already contains the
   authored fix (`inkSecondary`, 6.93:1) and applies it in one surface only.

Nothing here is a P0. Nothing ships broken. But the gap between "the tokens
are measured" and "the screen is measured" is the system's real weak seam.

---

## P1 findings

### P1-1 · `LevelMeterView` ignores the accent dial

**Location:** `AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift:126–131`
(observer registration), `:173–178` (the stamp).

The meter stamps three resolved `CGColor`s into a `CAGradientLayer`:

```swift
fillLayer.colors = [
    Tokens.Color.ember.cgColor,
    Tokens.Color.gold.cgColor,
    Tokens.Color.caution.cgColor,
]
```

Two of those three (`ember`, `gold`) are exactly the tokens the accent dial
remaps. The view observes
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` and
`viewDidChangeEffectiveAppearance`, but **not**
`Tokens.accentStyleDidChangeNotification`.

`Tokens.swift:58–71` states the rule in its own words — "an instrument that
stamps `gold`/`ember`/`glow` into a layer must observe this the same way it
observes the a11y notification" — and names the exact live bug it was written
for. `AudioutSharedUI/AGENTS.md` rule 36 repeats it. `HaloRingView:162`,
`BusRailOverlayView:122`, `EQResponseCurveView:216`, `OnboardingChrome:121`
and `DemoPaneView:1914` all comply.

**Impact:** switching Settings › Appearance › Accent to Subtle or Follow-system
leaves every visible meter drawing the previous gold ramp. `setLevel` only
moves the mask width and `layout()` only re-frames — neither re-stamps
colours — so the stale ramp persists until an appearance flip or an
Increase-Contrast toggle. This is the identical failure the notification was
introduced to fix, reproduced in the app's most visible instrument, right
beside a rail that *does* re-tint.

**Recommendation:** register the same selector-based observer for
`Tokens.accentStyleDidChangeNotification` in `init`, calling
`updateLayerColors()`. Three lines, mirroring `HaloRingView:160–168`.

---

### P1-2 · `RouteArmedDotView` ignores the accent dial

**Location:** `AudioutCore/Sources/AudioutSharedUI/RouteArmedDotView.swift:60–65`
(observer registration), `:120–121`, `:155`.

```swift
dotLayer.fillColor = Tokens.Color.gold.cgColor
dotLayer.shadowColor = Tokens.Color.glow.cgColor
```
…and the bloom's `emberCG = Tokens.Color.ember.cgColor` at `:155`. All three
are dial-remapped; the view observes only the workspace a11y notification.

**Impact:** worse than P1-1 in one respect — under the Subtle dial position
`glow` resolves `.clear` by design ("no glow shadow"). An armed dot that was
stamped under Full-gold therefore keeps a halo the chosen dial position
explicitly removes, so the dial appears not to work at all on the route-armed
lamp. The dot and the meter are the two instruments a user watches while
changing that setting.

**Recommendation:** same three-line observer, calling
`updateLayerAppearance()`.

---

### P1-3 · `tertiaryLabel` carries state text and the dormant rail at 1.85–2.26:1

**Locations (34 sites; the meaning-bearing ones):**
- `AudioutSharedUI/DeviceRowView.swift:972` — the "Unavailable" sublabel.
- `AudioutSharedUI/DeviceRowView.swift:3086` — the UNTUNED sync chip's
  "Not set" text (the D10 discoverability affordance).
- `AudioutSharedUI/MembershipBusView.swift:151, 157, 205` and
  `BusRailOverlayView` (dormancy) — the whole dormant rail, hook, segments and
  terminus dot draw in `Tokens.Color.tertiaryLabel`, per `AGENTS.md` rules 27
  and 30.
- `AudioutPopoverUI/PopoverPanelViewController.swift:1161` — every subsection
  header title.
- `AudioutPopoverUI/PopoverController.swift:2587, 2683` — the popover's
  empty-state placeholder rows and card notes.

**Measured** (`NSColor.tertiaryLabelColor` composited at its macOS alpha):

| Ground | Light | Dark |
|---|---|---|
| `canvas`/`panel` | **1.88:1** | **2.23:1** |
| `raised` | 1.86:1 | — |
| `well` | 1.85:1 | — |
| `feedPillFill` | 1.82:1 | 2.20:1 |

Floors: 4.5:1 for text, 3:1 for a graphical object (WCAG 1.4.11). Every one of
these fails both. WCAG's disabled-control exemption does not cover any of the
sites listed: "Unavailable" and "Not set" are *states*, the dormant rail is a
*state* the whole §4.7 design exists to communicate, subsection headers name
content, and empty-state text is the only content on screen in that state —
which `PRODUCT.md` principle 2 ("The UI never lies… empty states are honest")
makes load-bearing.

**Impact:** the app's contrast commitment ("WCAG-level contrast floors 4.5:1
text / 3:1 non-text in both appearances", `PRODUCT.md` › Accessibility) is not
met on the popover's most common non-primary text, in both appearances. Under
Increase Contrast macOS lifts the system label alphas somewhat, but the base
state — what most users see — does not pass.

**Recommendation:** two separate moves, not one.
(a) Text: add an authored `inkTertiary` alongside the existing `inkSecondary`,
hitting ≥4.5:1 in both grounds, and move the state-bearing sites
(`DeviceRowView:972`, `:3086`, placeholder rows) onto it. Leave genuinely
decorative chevrons on `tertiaryLabel`.
(b) The rail: `tertiaryLabel` is the wrong token for a *graphical object* with
a 3:1 floor. Author a `railDormant` instrument (the rail already refuses
per-stop dimming, so this is one value, not a patchwork) measured ≥3:1 against
`canvas` and `panel` in both appearances. This is the one case where the
design rule ("dormancy is ONE flag, one tone") and the contrast floor are
currently in direct conflict, and the rule won by default.

---

### P1-4 · Typography bypasses `Tokens.Font` at ~24 call sites

**Locations (representative):**
- `AudioutOnboardingUI/SetupRibbonView.swift:256` —
  `NSFont.systemFont(ofSize: 10, weight: .semibold)`, which is
  **character-for-character `Tokens.Font.microLabel`** (`Tokens.swift:1028–1030`).
- `AudioutApp/AppDelegate.swift:1796` and
  `AudioutOnboardingUI/DemoPaneView.swift:1867` —
  `.systemFont(ofSize: NSFont.systemFontSize)` = `Tokens.Font.body`.
- `AudioutSettingsUI/AppearanceSettingsViewController.swift:383` —
  `NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: …)` =
  `Tokens.Font.captionMedium` / `.caption`.
- `AudioutPopoverUI/PopoverPanelViewController.swift:1113` — same, behind a
  `weight:` parameter, for every legend and column-header label in the popover.
- `AudioutSharedUI/DeviceRowView.swift:1736` —
  `NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)`,
  the volume readout — the app's own numeric-readout voice, untokenised, sitting
  one point away from `Tokens.Font.syncReadout`.
- Sizes with no token at all: 9.5 pt (`DemoPaneView:2696`), 11 pt
  (`BTAlignmentPromptView:59`, `ConnectionDiagnosisView:121, 126`,
  `PopoverPanelViewController:1268`, `BTAlignmentWizardView:416, 477`), 11.5 pt
  (`SetupRibbonView:348`), 12 pt (`BTAlignmentWizardView:511`,
  `DemoPaneView:2336`), 14.5 pt (`SetupRibbonView:97`), 20 pt
  (`OnboardingViewController:373`, `SetupRibbonView:91`), 24 pt
  (`DemoPaneView:1863`).
- `AudioutSharedUI/DeviceRowView.swift:1396` — `.systemFont(ofSize: 10)` for
  the status sublabel, a bare literal in the *shared* target itself.

**Impact:** `Tokens.swift:8–13` is explicit — "Every other call site … must
reach color, type, layout, and material through `Tokens`, never through a raw
literal `NSColor`, `NSFont`, or magic number of its own." Colour honours this
almost perfectly; type does not honour it at all outside the shared row views.
Three concrete consequences: (a) the Figma contract's twelve text styles cannot
describe what the app actually renders, so `docs/FIGMA-DESIGN-SYSTEM.md`'s
"Text styles (mirror `Tokens.Font`)" claim is untrue for roughly half the
screens; (b) `Tokens.Font`'s own doc claim — "Every case forwards to the exact
`NSFont…` call and size the codebase already uses (verified via `git grep`)" —
is now stale in the other direction, since the codebase uses eight sizes the
module has never heard of; (c) a future type-scale change has ~24 hand-edit
sites and no compiler help.

**Recommendation:** two steps. First, mechanically replace the exact-duplicate
call sites (`SetupRibbonView:256`, `AppDelegate:1796`, `DemoPaneView:1867`,
`AppearanceSettingsViewController:383`, `PopoverPanelViewController:1113`) with
their existing tokens — no visual change, and it re-establishes the rule.
Second, decide deliberately about the orphan sizes: either promote the ones
with a real role (11 pt "detail" appears at six sites; 20 pt "display" at two)
into named `Tokens.Font` cases, or record in `AudioutOnboardingUI/AGENTS.md`
that the Setup window runs its own display scale — the same way that folder
already ledgers `DemoSystemColor`. Silence is the only outcome that leaves the
governance rule false.

---

## P2 findings

### P2-1 · `secondaryLabel` is under the body floor in light, and the authored fix is confined to one surface

**Location:** 92 call sites; the fix at
`AudioutSharedUI/Tokens.swift:413` (`inkSecondary`), used only in
`AudioutOnboardingUI` (7 sites).

Measured, light appearance:

| Ground | `secondaryLabel` | `inkSecondary` |
|---|---|---|
| `canvas`/`panel` `#FBFBF9` | **3.93:1** | 6.93:1 |
| `raised` `#F2F0EA` | 3.87:1 | 6.30:1 |
| `well` `#E2DFD3` | 3.72:1 | 5.38:1 |
| `feedPillFill` `#D0CDC3` | 3.60:1 | 4.52:1 |

Dark is fine (6.06–6.19:1). `inkSecondary`'s own doc comment names the problem
precisely ("measures 3.95:1 vs `panel` in light, under floor for body text")
and then solves it for the Setup window only. `feedPillText`
(`Tokens.swift:956`) solves the same problem a second time, differently, for a
single pill. Every other light-mode sublabel, hint, readout and footer in the
popover, Groups screen and Settings still sits at 3.6–3.9:1.

**Impact:** the largest single body of text in the app is under the stated 4.5:1
floor in one of the two appearances. Two independent point-fixes exist, which
means the problem is understood and the systemic fix was never taken.

**Recommendation:** make `secondaryLabel` itself mode-aware — the pattern the
Figma doc already blesses ("when one token cannot serve both grounds, make it
mode-aware… two modes, one component") and `feedPillText` already implements:
resolve `NSColor.secondaryLabelColor` in dark and `inkSecondary`'s light hex
(`#5C574C`) in light. One token edit, 92 call sites fixed, no component forks,
and it retires the `inkSecondary`/`feedPillText` special cases into consistency.

---

### P2-2 · The Subtle accent dial's `ember` falls below the instrument floor on `well`

**Location:** `AudioutSharedUI/Tokens.swift:509–521`
(`ember`, `subtle:` column), consumed by
`AudioutSharedUI/WarmFaderCell.swift:125–127` (the armed fader gradient's dim
end, drawn on the `well` trough).

The Full column was deliberately re-tuned on 2026-08-12 *against `well`*
because "the rail and its nodes run over the darker of the two surfaces"
(`Tokens.swift:446–455`), and again when Direction 04 deepened light `well` to
`#E2DFD3` (`:511–515`). The **Subtle column was never re-measured against
`well`** — its documented numbers are all vs `panel`.

Measured on `well`:

| Dial | Appearance | vs `well` | vs `panel` |
|---|---|---|---|
| Subtle `ember` `#AE9668` | light | **2.14:1** | 2.75:1 |
| Subtle `ember` `#6D5B34` | dark | 2.95:1 | 2.66:1 |
| Subtle `gold` `#8F7B4A` | light | 3.08:1 | 3.97:1 |
| Subtle `gold` `#B99B53` | dark | 7.27:1 | 6.55:1 |

Dark Subtle ember is knowingly under floor with the IC variant as the spec's
escape valve (documented). **Light Subtle ember at 2.14:1 on `well` is not
documented anywhere** and is the worst instrument-on-ground number in the
system.

**Impact:** a user on Subtle + light mode gets a fader whose gradient dim end
is effectively invisible against its own trough — the low-volume end of the
control, which is exactly where the thumb sits when it matters.

**Recommendation:** re-tune light Subtle `ember` to ≥3:1 on `#E2DFD3` (the Full
column's `#947637` measures 3.21:1 there and is a starting point), and extend
`MembershipWellContrastTests`' pinned floor to cover the Subtle column so the
next re-tune of `well` cannot silently break it again — that test already
exists and already caught this class of drift once for the Full column.

---

### P2-3 · `ringConnected` and `faderRim` in light are below 3:1 on the re-tuned `well`

**Location:** `Tokens.swift:372` (`ringConnected`), `:643` (`faderRim`).

| Token | Light hex | vs `panel` | vs `well` `#E2DFD3` | Documented |
|---|---|---|---|---|
| `ringConnected` | `#A08C66` | 3.15:1 | **2.44:1** | panel only, "passes, tight" |
| `faderRim` | `#9E8D6B` | 3.13:1 | **2.43:1** | "2.59:1 vs `well`" |

`faderRim`'s stated 2.59:1 was measured against the *previous* light `well`
`#E8E6DC`; the Direction-04 deepening to `#E2DFD3` moved it to 2.43:1 without
the rationale being updated. `faderThumb`'s comment *was* updated in the same
pass (its stated 3.12:1 matches exactly), so this is a partial update, not a
policy. `faderRim` is a deliberate sub-3:1 value ("kept just under strict 3:1
in light so a 1 px ring reads as a rim, not a stripe") — the concern is the
undisclosed drift, not the choice.

`ringConnected` is different: `warm-signal-v3.md:96` sets it a **normative**
"≥3:1 vs `panel` AND `raised`, tested at 21 px" floor, `:218` extends that to
"vs canvas… both themes", and it is the connection ring that must be
"scannable as a column". It is never measured against `well`. That is defensible
only while no ring is drawn on a `well` surface — which is true today
(`AGENTS.md` rule 46 retired `.well` from Groups) but is not stated anywhere as
a constraint, and `well` still backs the fader trough, the BT sync drawer,
Settings readouts and the alignment wizard panels.

**Impact:** low today, latent tomorrow. The next surface that fills with `well`
and hosts a device row silently ships a 2.44:1 connection ring against a
normative 3:1 floor.

**Recommendation:** re-measure and update both rationales against the current
`well`; state explicitly in `ringConnected`'s doc which grounds it is
guaranteed against, so a future consumer knows `well` is not one of them.

---

### P2-4 · `sidebarWarmTint`'s contrast rationale describes hexes the code does not ship

**Location:** `AudioutSharedUI/Tokens.swift:332`, `:342` (the prose) vs `:346`
(the values).

The comment measures light `#F2EBDC` and light-IC `#E9DFC9`. The code ships
`light: 0xF5F4ED, lightHighContrast: 0xE8E6DC`. Every light number in that
rationale — 1.04:1 vs canvas, 1.12:1 vs panel, 1.04:1 vs the neutral sidebar
grey it replaces, 1.25:1 IC — describes a colour that is not in the file, and
all of them are measured against the retired warm-paper grounds
(`#F4EFE7` / `#FBF8F2`) besides.

Actual, against the shipped Circuit grounds: light `#F5F4ED` is **1.064:1** vs
`canvas`/`panel` `#FBFBF9`; light IC `#E8E6DC` is 1.211:1 vs `well`.

**Impact:** house rule 3 requires "a documented contrast rationale" per case.
This case has a rationale for a different colour. An agent re-tuning the
sidebar would reason from numbers that never applied to the shipped value.

**Recommendation:** rewrite the light half of the rationale against the shipped
hexes and the Circuit grounds. While there: the same stale-ground problem
affects `meterTrack` (`:305`, cites `canvas #F4EFE7`; real is 1.77:1 vs
`#FBFBF9`), `caution` (`:552`, cites `panel #FBF8F2`; real is 3.86:1 vs
`#FBFBF9`) and `faderThumb` (`:626`, cites `canvas #F4EFE7`; real is 4.02:1).
The file's own blanket note at `:178–184` covers the *direction* of the drift
("Circuit grounds are LIGHTER, so every such ratio only improves") but does not
excuse a rationale attached to the wrong hex.

---

### P2-5 · `FeedPillView` never re-stamps under Increase Contrast

**Location:** `AudioutSharedUI/FeedPillView.swift:83–92`.

The pill stamps `Tokens.Color.feedPillFill` into `layer.backgroundColor` and
observes `viewDidChangeEffectiveAppearance` only. Its own doc comment states
the requirement — "a live light/dark **or Increase-Contrast** switch needs a
manual re-stamp" — and then registers no
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` observer.
`feedPillFill` has real IC variants (`#423B33` dark, `#C7C3B3` light,
`Tokens.swift:942–945`), so there is a visible difference to miss.

**Impact:** a mid-session Increase Contrast toggle leaves every FEED pill on
its base wash. Small, but it is one of only two per-row surfaces with an IC
variant, and the sibling instruments (`LevelMeterView`, `RouteArmedDotView`,
`HaloRingView`, `SidebarWarmSurfaceView`) all register the observer.

**Recommendation:** add the workspace observer calling `updateAppearance()`.

---

### P2-6 · Three competing vocabularies for "this thing is picked out"

**Locations:**
- `Tokens.Color.engagedChrome` (`Tokens.swift:100–116`) — mute pill, sync-chip
  engaged fill, row hover and selection washes. Declared as *the* one tone for
  every engaged/picked-out surface, "deliberately NEUTRAL, and deliberately not
  the gold family".
- `Tokens.Color.accent` (system accent) — `GroupRowView.swift:99` (the active
  group's button tint), `AppearanceSettingsViewController.swift:367` (the
  selected theme tile's ring), `DeviceRowView.swift:2809` (the attention flash,
  which carries an explicit and convincing justification).
- `Tokens.Color.gold` — `IconPickerViewController.swift:277` (the current
  icon's selection ring), described in-line as "a sanctioned gold use —
  selection state on the icon instrument itself, not chrome".

**Impact:** three different colours mean "selected" on three surfaces the user
reaches within one session. `engagedChrome`'s doc argues at length that a gold
wash "claims membership the pointer has not granted"; the icon picker then uses
gold for exactly a selection state. Each site is individually reasoned; the set
is not.

There is also a stale rule in the shared AGENTS.md: rule 33 describes the
drawer-open sync chip as "the mute pill's engaged recipe: translucent `accent`
fill at `mutePillFillAlpha` + accent glyph", but the code
(`BTSyncDrawerView.swift:412`, `:511`; `DeviceRowView.swift:898`, `:903`) uses
`engagedChrome`. The rule describes the pre-`engagedChrome` world.

**Recommendation:** pick one. The cheapest coherent answer is
`engagedChrome` everywhere selection/engagement is meant, keeping
`Tokens.Color.accent` for the attention flash alone (that one earns its
exception in writing) — and updating `AGENTS.md` rule 33's wording to match
the shipped tokens.

---

### P2-7 · `docs/FIGMA-DESIGN-SYSTEM.md` describes a code state that no longer exists

**Location:** `docs/FIGMA-DESIGN-SYSTEM.md`, "Light mode = Circuit theme" section.

Three concrete untruths:

1. "**Figma light is AHEAD of code.** `Tokens.swift`'s light/lightHC columns
   still hold the original warm-paper values (canvas `#F4EFE7` …), so the
   shipping app is unchanged." — Code ships `canvas` light `#FBFBF9`
   (`Tokens.swift:210`). The Circuit pull landed;
   `PRODUCT.md` dates it 2026-08-11.
2. "**Two NEW tokens the code does not have yet** … `feedPillFill` …
   `feedPillText`." — Both exist (`Tokens.swift:942`, `:956`).
3. The mapping table says `well`, `sidebarWarmTint` → Circuit `bg/subtle` and
   `hairline` → `border/divider`. The code deliberately took neither:
   `well` went to `bg/highlight` and was then re-tuned off-sheet to `#E2DFD3`
   (`Tokens.swift:246–253`), and `hairline` took `border/normal` `#D0CDC3`
   because `border/divider` measured 1.21:1 (`:280–284`). Both departures are
   recorded in the code and not in the doc.

**Impact:** the doc is labelled "the design system of record" by `PRODUCT.md`
and defines a Figma → code pull direction. An agent following it would pull
warm-paper hexes over shipped Circuit values, re-add two tokens that exist, and
regress two deliberate contrast-driven departures. The doc's own "Code wins
over spec" rule is the right instinct but does not protect against a doc that
*claims* to describe the code.

**Recommendation:** update those three passages to the shipped values and record
the two departures (`well` → deepened `bg/highlight`, `hairline` →
`border/normal`) with their measured reasons in the mapping table.

---

## P3 findings

### P3-1 · `bluetoothBrand` bypasses the file's own hex constructor and ships no IC variant
`Tokens.swift:917–919` builds `NSColor(srgbRed:green:blue:alpha:)` directly
rather than the `NSColor(warmSignalHex:)` convenience declared at `:1290` as
"the only place in the codebase a hex literal is permitted to become a color",
and returns a **static** colour rather than a dynamic provider — so unlike
every other case it cannot respond to anything. The omission of IC variants is
self-declared ("it has no Increase-Contrast variants to match"), which house
rule 3 does not actually permit. Measured 3.62:1 vs light `panel` / 3.29:1 vs
light `raised` — passes 3:1, with little headroom and no IC step.
**Recommendation:** route it through `warmDynamic` with identical hexes in all
four slots (preserving the fixed brand hue), or add a one-step IC lift; either
way it then matches the module's shape.

### P3-2 · `warningText`, `inkSecondary` and `success` ship no Increase-Contrast variants
`Tokens.swift:401`, `:413`, `:424`. All three are *foreground* tokens with
stated text/glyph floors, and `warmDynamic` silently falls back to the base hex
when the IC argument is omitted. The background cases (`canvas`, `panel`,
`raised`, `well`) document their exemption; these three do not mention IC at
all. House rule 3 has no foreground exemption.
**Recommendation:** add IC variants, or state the exemption in each rationale.

### P3-3 · Two dead tokens
`Tokens.Color.tertiarySystemFill` (`:139`) has **zero** consumers — its
documented consumer, `LevelMeterView`'s track layer, moved to `meterTrack` in
the 2026-07-23 contrast pass. `Tokens.Material.sidebar` (`:1136`) has **zero**
consumers — both sidebars became plain split items with no system material
behind them (`AGENTS.md` rule 45). The file's own governing comment
(`:24–27`) forbids exactly this: "Do not add a case here for a
color/font/material combination that isn't already used… it documents and
centralizes what exists."
**Recommendation:** delete both, and their Figma variables.

### P3-4 · Raw alphas and radii outside the token layer
`AudioutPopoverUI/SilenceFallbackBannerView.swift:41–42, 68–69` —
`.withAlphaComponent(0.14)` / `(0.40)` for the banner fill and border, with the
identical recipe duplicated between `init` and `updateLayer`;
`SystemAirPlayNoteBannerView` carries its own copy of the same pair.
`AudioutSettingsUI/SettingsForm.swift:209` — `xRadius: 5, yRadius: 5`;
`AudioutSettingsUI/AppearanceSettingsViewController.swift:426` —
`NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.35)`, an undocumented
grey with no ledger entry. `PopoverColumnGrid` has a named alpha family
(`rowHoverWashAlpha`, `rowSelectionWashAlpha`, `mutePillFillAlpha`,
`faderDisabledAlpha`, `editAffordance*Alpha`) that these sites do not extend.
`Tokens.Layout` already exists as the home for a radius shared by two call
sites — the banner corner radius is there; the banner *tint* recipe is not.
**Recommendation:** promote the banner's fill/border alpha pair to
`PopoverColumnGrid` (two constants, two files de-duplicated) and give the
Appearance divider grey a ledger line in `AudioutSettingsUI/AGENTS.md`.

### P3-5 · `IconPickerViewController` misses both live re-resolution triggers
`AudioutWindowUI/IconPickerViewController.swift:270–279` resolves the gold
selection ring correctly under the picker's effective appearance — the careful
part — but registers neither `accentStyleDidChangeNotification` nor the
workspace a11y notification, and `refreshSelectionRingColor()` is called only
at build time and from `viewDidChangeEffectiveAppearance`. Low impact (a modal
picker rarely outlives a settings change), but it is the same class as P1-1/P1-2
and completes the pattern.

### P3-6 · `FoldAnimator` has no Reduce Motion handling or test seam of its own
`AudioutSharedUI/FoldAnimator.swift` is "the ONE clock every fold in the app
runs on" and contains no reference to Reduce Motion. Every caller must remember
the gate independently, and they do so three different ways:
`PopoverPanelViewController:209–210` via a `test_reduceMotionOverride` seam,
`EQEditorView:627` and `AudioSettingsViewController:482` by reading
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` inline, and
`CardView` not at all (it relies on its host passing `animated:` already gated —
correct today, but `PopoverPanelViewController:773`'s comment claims "the card
already gates itself on `accessibilityDisplayShouldReduceMotion`", which is not
true of `CardView.swift`).
**Recommendation:** move the gate into `FoldAnimator.animate` (settle
instantly when Reduce Motion is on) with the same `test_reduceMotionOverride`
seam every other shared instrument exposes. One clock, one gate. Fix the stale
comment either way.

---

## Systemic patterns

**1. Contrast is measured per token, not per screen.** Every authored token
carries a real measurement. But the *pairs that actually appear together on
screen* — system semantic text on warm grounds, an instrument on the surface it
is drawn over rather than the one it was designed against — are measured only
when a specific bug forced someone to. Hence P1-3, P2-1, P2-2 and P2-3: four
independent failures, all of the shape "the token passed its own test; the
composition was never tested". The two point-fixes that do exist
(`inkSecondary`, `feedPillText`) prove the team knows the shape of the problem.
The missing artefact is a contrast matrix — every foreground token × every
ground it can be drawn on × 4 appearance modes — computed in a test rather than
in prose. `MembershipWellContrastTests` and `AppTetherColorTests` are the right
idea at two isolated sites; the idea just never generalised.

**2. Rationale comments drift from the values they justify.** `sidebarWarmTint`
cites hexes the file does not ship; `faderRim`, `meterTrack`, `caution` and
`faderThumb` cite retired warm-paper grounds; `Tokens.Font`'s "verified via git
grep" claim is stale in both directions; `AGENTS.md` rule 33 describes the
pre-`engagedChrome` sync chip; the Figma doc describes a pre-Circuit
`Tokens.swift`. The rationale-per-case rule is genuinely valuable and genuinely
practised — but nothing verifies a rationale against its own value, so prose
rots at a different rate than code. A cheap fix for the highest-value subset:
have the contrast test suite emit the measured ratio it asserts, so a stale
number in a comment is visible next to a live one in test output.

**3. The accent dial has three broadcast subscribers and three non-subscribers.**
`Tokens.swift:58–71` and `AGENTS.md` rule 36 state the rule clearly and name the
live bug. Five sites comply; three (`LevelMeterView`, `RouteArmedDotView`,
`IconPickerViewController`) do not, and two of those are primary instruments.
The rule is correct and well-written; it is simply unenforced. A test that
sweeps every `CALayer`-stamping view for the observer, or — better — a small
`AccentReactiveLayerView` base class that registers all three triggers
(appearance, a11y, dial) once, would make the omission impossible rather than
merely documented. `RingRailToneLockTests` already proves this class of
invariant is testable here.

**4. Colour got governance; type, spacing and alpha did not.** The same
governance sentence covers all four. Colour has a module, a dynamic provider, an
IC axis, per-case rationales, pinned tests and a Figma contract. Type has twelve
alias cases and ~24 call sites that ignore them. Alphas have a named family in
`PopoverColumnGrid` for rows and inline literals everywhere else. Layout has
three real constants and `SurfaceLayout`'s six, with magic numbers alongside
them in the same files. This is the single highest-leverage structural gap: the
colour layer shows exactly what "done" looks like, and three of the four axes
have not been taken there.

---

## Positive findings

- **`Tokens.swift` is a genuinely well-built token module.** One sanctioned
  palette file, one hex→colour constructor, every custom case a live
  `NSColor(name:dynamicProvider:)` that re-resolves against appearance *and*
  the live `accessibilityDisplayShouldIncreaseContrast` flag on every access —
  never a frozen snapshot. The pattern is stated once and followed 40+ times.

- **The accent dial lives inside the provider, not at the call sites.** A
  stored `NSColor` re-resolves against the current `Tokens.accentStyle` on its
  next resolution, so surfaces pick up a dial change with no colour re-fetch.
  The `didSet` broadcast means "no call site can forget to announce it" is true
  by construction. `permissionDynamic` (`:1272`) is a deliberate *sibling* of
  `accentDynamic` rather than a caller, with both reasons written out and
  verified against the code — an exemplary piece of design-system reasoning.

- **"Instruments never theme" holds everywhere I checked.** `failure`,
  `caution` and `ringConnected` are exempt from the dial by construction, not
  convention. `EQResponseCurveView:252` forces `.darkAqua` so the scope is a
  scope in both appearances. The four permission hues resolve their authored
  Full column under both `.fullGold` and `.systemAccent`, specifically so
  Follow-System cannot collapse four identities into one accent. Meters top out
  at `caution` and never reach `failure` (house rule 8), enforced in
  `LevelMeterView`'s gradient and documented at three separate sites.

- **`spineTone(armed:)` (`:534`) is the right shape of fix.** The rail's hook,
  its member segments and the Main Audio ring take their tone from one function
  instead of three call sites each naming `gold`/`ember` — the exact drift that
  let the dial move one and not the other. Scoped tightly ("Nothing else may
  consume this"), and swept by `RingRailToneLockTests` across every dial
  position × appearance × armed state against real drawn pixels.

- **Reduce Transparency coverage is complete and packaged once.** There are
  exactly two content-bearing `NSVisualEffectView`s in shipping code
  (`AppDelegate:1777`, `AboutView:218`) and both install
  `ReduceTransparencyFallbackView` (`:1787`, `:224`). `WarmCanvasView` and
  `WarmPanelView` sidestep the requirement entirely by never being translucent,
  which the former's doc comment argues for explicitly. No hand-rolled copies.

- **The drawing-only cell pattern is disciplined and consistently applied.**
  `WarmFaderCell`, `WarmNameFieldCell`, `SyncChipCell` and `InvisibleSwitchCell`
  each override *only* drawing, leaving tracking, keyboard, scroll-wheel,
  focus ring, field editor and VoiceOver stock. Warm Signal paints; AppKit
  behaves. This is precisely the "native first, identity in the open layer"
  commitment, implemented rather than asserted.

- **`StatusItemIcon`** refuses a palette/accent path with the failure mode
  written down (an accent-matched wallpaper made the streaming icon
  unreadable). Template-only, extracted out of the executable target purely so
  the invariant is testable. Exactly the right call.

- **`WarmSignalGrain`** is deterministic by construction — a pure coordinate
  hash, no RNG, no time, no object-address seeding — so snapshot PNGs stay
  byte-identical run to run. The determinism contract is stated where a future
  agent will read it before reaching for `arc4random`.

- **Sharing is real, not aspirational.** `DeviceRowView` serves the popover,
  the menu and the Groups window from one implementation with a live
  `isInMenu` branch; `InvisibleSwitchCell` is explicitly shared rather than
  duplicated; `LevelMeterView` and the `identityStack` are identical between
  `DeviceRowView` and `AppRowView`; `SurfaceLayout` holds the six numbers both
  sidebars would otherwise each declare. I found no shared component
  re-implemented locally in a surface target.

- **The two hardcoded palettes are ledgered, not stray.**
  `AppearanceSettingsViewController`'s theme-tile palette is documented as an
  absolute (non-adaptive) preview — correct, since a Light tile must look light
  in dark mode — *and* pinned against the live tokens by
  `PreviewPaletteTokenPinTests`, which the comment notes already caught one
  silent drift (`well`). `DemoSystemColor` is ledgered in
  `AudioutOnboardingUI/AGENTS.md` as a documented exception with its reasoning.
  Both satisfy house rule 8.

- **`engagedChrome`'s reasoning is the best single comment in the module**
  (`:100–116`): why the mixer's engaged states are neutral rather than the
  system accent, why they are not gold ("gold means signal — painting MUTE gold
  states the opposite of what mute does"), and how strength rather than hue
  separates the four sites. That it is not yet universally applied (P2-6) does
  not diminish the reasoning.
