# Alignment wizard v2 — "Two Voices, on the Plate" — implementation spec

Consolidated from four design tracks (distill / layout / colorize / animate) after
the 2026-08-23 live test of the v1 window. Owner rulings applied. This document
is the single source of truth for the v2 build; where it conflicts with older
comments in the wizard files, this wins.

## 0. Owner rulings (Alec, 2026-08-23)

1. **Colors = the brand's two secondaries from the website** (`~/Projects/Audiouter
   Website/DESIGN.md`): **Sync Green `#2BFF8F`** (target — the speaker being
   aligned) and **Party Magenta `#FF90E9`** (reference). Gold stays the primary
   voice (CTAs, detent accent, chrome). Fixed dark stage plate approved.
   Additive fusion approved. Doctrine framing: this is the website's
   *group-identity exception* — color names WHICH speaker, never state;
   "is it live" stays gold everywhere else in the app.
2. **All distill cuts approved** ("All of them"), including deleting the visible
   "Which speaker clicked first?" line (plates + stage carry it; the composed
   accessibility label keeps the words).
3. The confidence-state ladder + authored transitions + bigger success sequence
   are the point of the pass ("we need a system: at X confidence it looks like
   THIS, with transitions between states").

## 0b. Owner rulings after the 2026-08-23 critique (supersede where they conflict)

1. **The answer plates are the hero**, the stage a strip: `stageHeight` 112
   (**now 132** — see §0c), answer plates 236×88 (32 gap) with a 15 pt
   semibold title; every other plate stays 220×64. Short screens centre in
   the band under the readout.
2. **The question is on the question screen**: readout = `Which clicked
   first? · <rung word>`; the interval (`Somewhere between −8 and 8 ms`) is
   the stage's tooltip. The elapsed clock is GONE; the nameplate's right
   slot reads `CLICK n OF ABOUT 15` (intro: `ABOUT 15 CLICKS`).
3. **Kept:** the winning message is the hero line — `<Target> is ready to
   play with everything.` — over a caption (`Change it anytime from the
   SYNC control.` / `Fine-tune anytime from the popover.`); `247 ms · kept`
   stays the stage's caption in the caption voice. The number matters
   (users may edit it later without re-running) but it is not the headline.
4. **Colour rule, binding app-wide:** gold is the primary colour, always.
   Sync Green / Party Magenta are the website's two secondaries and may be
   used here because two speakers need two identities. Any future use of
   either hue outside this window requires asking Alec first, with a clear
   rationale — never by analogy to this screen. In dark mode the plate rims
   and keycaps wear the electric value at FULL alpha (§2.1's 0.45 measured
   as olive/mauve, 45% of the lights' chroma); light keeps the Deep
   companions at 0.9. The intro stage stamps each speaker's name under its
   light (`stageInk`, micro-label) so the mapping is taught before the
   first tap. The armed span and the locked wire are neutral (`stageRule`):
   no identity before there is a belief, none after the two have fused.
5. **"Set it manually"** (renamed from "Set it by hand" — it means typing a
   number or tapping the paddles): offered on the PROPOSAL (corner row,
   beside Stop) and on the unsettled bow-out as a secondary. Never a
   primary. Bow-outs share one layout: sentence · `Try again` (gold) ·
   `Done`; unsettled adds `Set it manually` between them.
6. `Back ⌘Z` → `Undo ⌘Z`. Disabled Start wears no keycap. The locked look's
   halo (56 @ 0.55) carries the fusion statically for Reduce Motion. Room
   spill is off in light mode (measured invisible).
7. **Open:** Alec envisioned the wizard as a MODAL over the app surface, not
   a separate window. The window rehost exists because the popover-anchored
   panel died on click-away; a modal over the popover re-opens that. Decision
   owed — see HANDOFF-wizard-v2.md.

## 0c. Ring sizing (owner direction 2026-08-24 — supersedes §5's look table)

**The lights are drawn 1.8× §5's sizes, and `stageHeight` is 132 rather than
112 as the price of it.** §5's table was written before the living-ring port;
the ported wobble is ±3 % of the RADIUS, so on 9–20 pt rings the wavefront's
whole peak-to-peak travel was 1.1–2.4 Retina pixels. The life that had just
been ported could not be seen, and the ring read as a small circle adrift in
its halo rather than as a light. At 16–36 pt that travel is 1.9–4.3 px.

| Rung | armed | open | closing | near | threshold | fused | locked | dormant |
|---|---|---|---|---|---|---|---|---|
| Ring radius | 36 | 32 | 25 | 20 | 16 | 16 (ref +6) | 20 | 18 |
| Halo diameter | 106 | 96 | 76 | 60 | 46 | 50 | 74 | 0 |
| Ring lineWidth | 1.25 | 1.25 | 1.6 | 2.0 | 2.5 | 2.5 | 2.5 | 1.25 |

Opacities, windows, tick gearing and breathing are §5's, untouched. Three
constraints govern any future rescale:

- **Halos scale with rings** or the glow stops being glow — which is what
  forces the taller plate. `stageHeight` feeds `chassisHeight` 1:1, so it is
  the sheet's height too: every screen grew 20 pt, none reflows, and the
  stage goes from 27 % of the question sheet to 30 %. A 2.2× scale wanted 152
  (33 %) and tipped the stage into being the hero, against §0b.1.
- **Line widths rise sub-linearly** (×1.25–1.33, not ×1.8). A stroke scaled
  with the radius reads as a drawn hoop instead of a lit edge.
- **The ladder's gaps grow with everything else**: adjacent rungs sit 4/7/5/4
  pt apart where they sat 2/4/3/2, so each certainty step is twice as legible
  while its ratio to the wobble at that size is unchanged. Radius is how the
  ladder encodes certainty; a scale that let the wobble catch the gap would
  make the instrument lie. Widening the spread instead — the wide rungs at
  1.8× while the tight ones stay near their old sizes (36/32/22/15/11.5) —
  was tried and rejected: it pays the same 132 pt plate but leaves the
  endgame's wobble at 1.4 px, so the light reads as retreating into an empty
  box exactly when the user is most invested.

Reduce Motion, headless and pinned phase are untouched; renders stay
byte-deterministic. Renders per candidate: `dev/notes/wizard-v2-handoff/
ring-size-{baseline,a,b,c,d}/`, each with the `candidate.patch` that produced
it; `b` is what shipped.

## 1. Synthesis rulings (design lead — resolved cross-track conflicts)

- Question line: **deleted** from the visible stack (layout D1 wins over distill).
  The AX group label (already "Which speaker ticked first: A or B?") is the
  spoken carrier.
- Elapsed clock: **kept**, relocated to the nameplate row's right slot (layout's
  home answers distill's objection). Intro shows `USUALLY ~15 CLICKS` in that
  slot instead; question/proposal show `m:ss`.
- Reference picker: **intro only**, conditional — 0 options: `noReferenceCopy`,
  Start disabled; 1 option: plain text "Compare against <name>", no control;
  2+: label + pop-up. Never rendered on question screens.
  **AMENDED TWICE (owner live passes, 2026-08-24). Round 1** — "blends right
  into the background beside this huge CTA" — raised the 2+ case to a body-voice
  label around a regular pop-up in its own `spacingBand`: right direction,
  accepted, not strong enough. **Round 2** — "if we're keeping the CTA the same
  size, then we should definitely do something to bring the fact that this is an
  element you need to interact with further in focus" — makes the 2+ case a
  **FORM FIELD**: the label `Compare against` (`Tokens.Font.body`/`label`, no
  device name — the title and the stage stamps already print it) on its OWN
  line, above a `.large` pop-up pinned to `bodyMeasure` (400), leading-aligned,
  the whole field in its own `spacingBand`. The 0- and 1-option lines are
  statements and keep the caption voice with NO control mounted. Start's own
  220×64 plate does NOT change; the field is wider than the CTA on purpose —
  form above, submit below, gold and height carrying primacy. Rejected in round
  2 with renders (`dev/notes/wizard-v2-handoff/intro-cta-r2-*`): a bordered
  `well` control row (dresses a band that isn't clickable), and that row with
  the reference's identity rim (1 pt of `partySignal` around 400 pt of ground is
  invisible, and identity rims belong to the answer plates).
- Stage plate stops **above** the answer plates (colorize's off-plate variant):
  plates sit on the themed window ground and wear their light's hue as rim +
  keycap tint only.
- Status words: FOUR, matched 1:1 to the ladder rungs (see §5). The view's
  private `nearlyLockedHalfWidthMs` is deleted; word boundaries and look
  boundaries are the same constants, single-owned.
- `macIsLate` gains a real **Try again** button (`session.tryAgain()` already
  accepts it; the locked copy already promised it). Its copy drops the trailing
  "Try again, or set the delay by hand." clause. `unreachable` keeps its copy
  pointing at the SYNC control (no in-window button).
- New tokens follow full governance (light + dark + Increase Contrast + written
  contrast rationale). Electric values are **instruments** (fixed both
  appearances); the two "deep" companions are themed chrome.

## 2. Color

### 2.1 New `Tokens.Color` entries

| Token | Dark | Light | IC | Kind / rationale |
|---|---|---|---|---|
| `stagePlate` | #100B07 | #100B07 | #080604 | Instrument ground (fixed). Background — no floor (canvas precedent). In light mode the plate is a dark screen set into a light chassis. |
| `stageRule` | #6A5F50 | #6A5F50 | #7A6E5C | Wire + ticks + dormant, on the plate. 3.1:1+ on plate (non-text floor); verify measured. |
| `stageInk` | #EFE9DD | #EFE9DD | #FFFFFF | Value stamp on the plate. ≥16:1. |
| `syncSignal` | #2BFF8F | #2BFF8F | #2BFF8F | Instrument (fixed): target light. ~14:1 on plate. Website's Sync Green, one value both themes by owner decision 2026-08-12. |
| `syncSignalDeep` | #2BFF8F | **#0B7A45** | #086237 | Themed chrome companion: target plate rim/keycap on the THEMED ground in light mode (electric green ≈1.3:1 on near-white — invisible). Verify ≥3:1 vs light `canvas` and `raised`. |
| `partySignal` | #FF90E9 | #FF90E9 | #FF90E9 | Instrument (fixed): reference light. ~9:1 on plate. Website's Party Magenta. |
| `partySignalDeep` | #FF90E9 | **#752C68** | #5E2354 | Themed companion (the magenta ramp's own dark end). Verify ≥3:1 on light grounds. |
| `fuseWhite` | #FFF4E2 | #FFF4E2 | #FFF4E2 | The fused/locked hue — additive climax. ~18:1 on plate. Transient + locked ring. |
| `plateRim` | ~#7E7160 | ~#857868 | derive | Neutral plate/together-bar rim. REQUIRED ≥3:1 vs BOTH `raised` and `canvas`, both appearances (fixes layout finding F1 — `faderRim` measures 2.62:1 vs raised). Tune the hex to hit the floor; add a measured contrast test (MembershipWellContrastTests idiom). |

Identity rims on the answer plates: dark = electric value at 0.45 alpha over
`raised` — **SUPERSEDED by §0b ruling 4: dark is FULL alpha** (0.45 measured
olive/mauve); light = the Deep companion at 0.9 alpha. Keycap glyph: electric
on dark, Deep on light. All stage-internal color: electric always (fixed
plate).

### 2.2 Assignments

- Target light (left): `syncSignal` halo + ring. Reference light (right):
  `partySignal` halo + ring.
- Span (credible interval bar): linear gradient `syncSignal → partySignal`,
  glow shadow in `fuseWhite` at low opacity (replaces gold glow on the stage).
- Wire/ticks: `stageRule`. Dormant: everything to `stageRule`, spill off.
- Lock bloom + merged ring: `fuseWhite`. Gather bars: each side keeps its own
  hue (green bar from the left, magenta from the right) fading as they arrive.
- Room spill: two large soft radial washes on the WINDOW ground behind the
  plate — green behind the left half, magenta behind the right, peak alpha
  0.10 dark / 0.07 light (Deep companions in light). Implemented as two blurred
  layers in the window content view (not the stage; the spill is the room).
  Spill intensity tracks each light's halo opacity class; goes white
  (`fuseWhite` ~0.10) for ~0.7 s at the lock, then settles to a faint green.
- Promotion detent accent: `Tokens.Color.glow` (gold — the instrument's own
  voice acknowledging banked progress). 100 ms, span shadow only.
- Demotion: no hue change — geometry + softness only. Failure red never appears.
- Primary plate fill: `goldCTA` + white ink (existing token, second sanctioned
  surface). **SUPERSEDED (owner ruling 2026-08-24): the wizard's primary plate
  fills with `Tokens.Color.gold` resolved under the DARK appearance — one
  bright-gold value pinned in both appearances — and sets its title and keycap
  in `Tokens.Color.inkOnGold` (black, 11.4:1). `goldCTA` is the deepened gold
  built for WHITE ink and read as dark mustard on screen; it keeps the Setup
  finale's CTA and nothing here.** Together bar / secondary plates: no fill, `plateRim` stroke.
- Accent-dial rule: none of the new tokens are dial-remapped. The stage no
  longer uses `gold`/`glow` for the lights, so the dial's `.systemAccent`
  remap cannot collide with the identity hues. `.subtle` dial: detent accent
  falls back to `ember`.
- Colorblind note: green/magenta differ on the blue axis and both carry
  position + keycap + device-name redundancy; the caption remains the
  accessible channel.

## 3. Layout (from wiz-layout, adopted)

Chassis: window content width **560**, controller insets **28 h / 20 v** →
view width **504**; `contentPadding` 0; spacing scale **4 / 12 / 16 / 28**
(28 = the one band break per screen). `stageHeight` **118 → 176**;
`wireYFraction` stays 0.58. Stage internal `horizontalInset` stays 26.
Fixed question-screen height — no reflow during a run.

**SUPERSEDED, geometry (owner rulings 2026-08-23/24):** `stageHeight` is
**112** — a strip, because the answer plates are the hero — and
`wireYFraction` is **0.5**: the wire sits on the plate's own midline, so the
armed halo and the name stamps read as centred rather than crowding the bottom
rim. The readout row COLLAPSES to zero height on the four screens that print no
caption (the stage never moves; only what hangs below it does).

### Question screen (top → bottom)
1. Nameplate row 504×14: `ALIGN · <TARGET>` left (microLabel voice,
   `inkSecondary` — NOT gold), `m:ss` right. Gap 16.
   **SUPERSEDED (owner ruling 2026-08-24): a plain sheet TITLE row 504×18 —
   `Align <device name>` at `bodyEmphasized`/`label` on the left, and the click
   count as a quiet `caption`/`inkSecondary` aside on its right (`Click n of
   about 15` / `About 15 clicks`), sentence case, never mono, never all-caps.
   The mono-caps retirement is WIZARD-ONLY; roadmap 059 covers the rest of the
   app. The stage's in-plate name stamps keep the micro-label voice.**
2. Stage 504×176. Gap 12.
3. Readout caption 504×15, CENTERED: `confidenceCopy · <rung word>`
   (`Tokens.Font.caption`, `inkSecondary`). Gap 28.
4. Plate row: two **220×64** plates, gap 64, edge-anchored (left = target,
   right = reference). Gap 12.
5. Together bar **400×36** centered: "Both at once" + 44×20 `SPACE`
   chip inline. Gap 16.
6. Corner row 504×24: `Back ⌘Z` left, `Stop ESC` right — REAL buttons
   (captionEmphasized + microLabel key suffix, `inkSecondary`, min hit height 24).

Other screens per wiz-layout's tables: intro (brief sentence, conditional
reference row, centered 220×64 **Start** primary plate, `USUALLY ~15 CLICKS`
in nameplate right slot); proposal (copy "Listen — the clicks should land as
one." + **Sounds right** primary / **Still off** secondary as edge plates);
kept (readout `247 ms · kept` under stage; body = the SYNC-zeroed fact for
latency runs / "Fine-tune anytime from the popover." for local; **Done**
primary centered); unsettled (three 160×64 plates: Set it by hand primary,
Try again, Done); unreachable (copy + Done); macIsLate (trimmed copy +
Try again + Done). Education line appears on NO screen (kept's body carries it).

### Plates — `AlignmentPlateButton` + `AlignmentPlateCell` (new files, AudiouterPopoverUI)
- Drawing-only `NSButtonCell` subclass; behavior/AX all stock. **`isBordered`
  stays `true`** (borderless silently discards `drawFocusRingMask` —
  openradar 29465363); `bezelStyle = .push` (never the deprecated `.rounded`);
  `drawBezel` overridden WITHOUT calling super.
- Overrides exactly: `drawBezel` (fill + 1 pt top lip + 1 pt bottom shade +
  rim + keycap chip), `titleRect` (centered title area minus 22 pt chip slot),
  `drawTitle` (state color only), `drawFocusRingMask` + `focusRingMaskBounds`
  (rounded rect, radius 12).
- Cell inputs: `isPrimary`, `isHovered` (tracking area on the button),
  `keycap: String?` ("←"/"→"/"SPACE"/"⏎"), `identityTint: NSColor?`
  (the per-side rim/keycap hue; nil = `plateRim`).
- State paint table (from wiz-layout, verbatim): rest `raised` fill + lit top
  lip (0.35→white blend) + bottom shade (`shadow` 0.18) + rim; hover +
  `engagedChrome` @ `rowHoverWashAlpha`; pressed inverts the bevel
  (top `shadow` 0.22 / bottom lit); disabled interior @ `faderDisabledAlpha`;
  primary = `goldCTA` fill + white ink (disabled primary falls back to
  `raised` + dimmed label, never faded gold). Keycap chip: 22×22 r6, 1 pt rim,
  2 pt inner bottom lip that drops to 1 pt + chip shifts down 1 pt on press.
- No drop shadows, no gradients, no textures (cacheDisplay determinism).
- Corner radius: new `PopoverColumnGrid.alignPlateCornerRadius = 12`.
- New `Tokens.Font.keycap` = monospacedSystemFont(11, .medium).
- Keyboard: `performKeyEquivalent` routes ←/→/space through
  `plateButton.performClick(nil)` so keys visibly depress the plates
  (matches the repo's real-dispatch rule). Return keeps the stock
  default-button path.
- Never pre-focus an answer plate (`initialFirstResponder` = the view);
  key-view order = visual order.
- Keycap chips are drawings — mirror each in `accessibilityHelp`
  ("Press Left Arrow" etc.). The chip must not be an AX element.

## 4. Distill — final per-screen content (all cuts approved)

Exact strings; `[…]` control, ‹…› chrome (console voice OK), else plain speech.

- **intro:** stage `.armed` · ‹USUALLY ~15 CLICKS› · "You'll hear a click from
  each speaker. Tap the one you hear first." · reference row (conditional,
  §1) · [Start]
- **question:** stage `.question` · ‹m:ss› · readout ‹Somewhere between 180
  and 320 ms · <word>› · [Target ‹←›] [Reference ‹→›] · [Both at once
  ‹SPACE›] · [Back ⌘Z] [Stop ESC]
- **proposal:** stage `.listening` · readout ‹247 ms› · "Listen — the clicks
  should land as one." · [Sounds right ⏎] [Still off]
- **kept:** stage `.locked` · readout ‹247 ms · kept› · latency: "The SYNC
  nudge is back to 0 — fine-tune from there anytime." / local: "Fine-tune
  anytime from the popover." · [Done ⏎]
- **unsettled:** stage `.dormant` · `unsettledCopy` verbatim · [Set it by
  hand ⏎] [Try again] [Done]
- **unreachable:** stage `.dormant` · `unreachableCopy` verbatim · [Done ⏎]
- **macIsLate:** stage `.dormant` · "Couldn't get a clean reading — the Mac
  seems to be the late one here." · [Try again] [Done ⏎]

Copy statics removed: `questionCopy` (words live on in the composed AX label),
`educationCopy` + `test_showsEducationLine`, `elapsedCopy` STAYS (nameplate
clock). `proposalCopy`/`keptLatencyCopy`/`keptLocalCopy`/`macIsLateCopy`
replaced by the strings above. The readout is a REAL NSTextField (never layer
text — it is the stage's accessible caption). The proposal/kept AX labels keep
naming the number ("Aligned at 247 milliseconds. Does it sound right?").

## 5. Motion — the ladder + transitions (from wiz-animate, adopted)

### Rungs (95% credible half-width `hw`, hysteresis mandatory)
| Rung | Enter | Demote at | Word (readout) |
|---|---|---|---|
| `armed` | pre-start | — | — |
| `open` | hw > 250 | — | "narrowing in" |
| `closing` | hw ≤ 250 (= `fineTempoHalfWidthMs`, read from the session) | hw > 300 | "closing in" |
| `near` | hw ≤ 60 | hw > 75 | "getting close" |
| `threshold` | hw ≤ 12 | hw > 15 | "nearly there" |
| `fused` | `.listening` | — | — |
| `locked` | `.kept` | — | — |
| `dormant` | bow-outs | — | — |

Boundary ownership: 250 = `BTAlignmentWizardSession.fineTempoHalfWidthMs`
(never retyped); 12/15 = the stage's constants, and the VIEW reads them for
the word (delete `nearlyLockedHalfWidthMs`); add a one-line Core accessor
`BTAlignmentWizardSession.proposeHalfWidthMs` forwarding the posterior's 6.

### Look table (settled model values per rung)
**Sizes here are superseded by §0c** (rings 1.8×, halos with them, line widths
×1.25); everything else in this table stands.
Adopt wiz-animate's parameter table verbatim: halo diameter 84/76/58/42/30/
34/40/0 · halo opacity 0.20/0.40/0.46/0.52/0.58/0.55/0.42/0 · target ring
radius 20/18/14/11/9/9/11/10 · ring opacity 0.18/0.30/0.55/0.78/1.0/1.0/1.0/
0.30 · ring lineWidth 1.0/1.0/1.25/1.5/2.0/2.0/2.0/1.0 · fused: reference
ring +4 pt radius, ring ×0.55, halo hidden · wire opacity 0.55→1.0 by rung ·
tick half-height 4→7 · tick opacity 0.35→0.85 · span opacity 0.22→1.0, height
1.5→3.5, shadowRadius 3→5 · window span: full/full/640/200/64 ms (min-count
4/4/6/6/6 → tick step 250/250/100/25/5, so every rung change re-gears the
ruler) · breathe period 5.2/4.4/3.5/2.7/2.0 s (fused 2.7), amplitude
1.05→1.03 — periods never integer multiples of the click period.
Window floor 40 ms; centre is STICKY (re-frame only when the interval + 15%
margin would escape; re-frame = pan). Clamp-by-sliding vs candidate range
survives.

### Transitions
- All ruler content (ticks, span, halos, rings) moves under one `fieldLayer`
  (`masksToBounds = true`; wire stays outside). Window changes are played as a
  camera gesture: seed `fieldLayer` with the affine transform mapping new→old
  (sx clamped 0.30…3.33), animate to identity. Promotion = push-in;
  demotion = pull-back. This is what stops a zoom reading as regression.
- **Promotion (0.62 s, RATCHET curve 0.16,1.0,0.3,1.0):** push-in leads
  (0.34 s) → rings (0.28 s @ +0.06) → halos lag most (0.32 s @ +0.10) → span →
  tick re-gear crossfade @ +0.28 → DETENT @ 0.34 s (span shadowRadius pulse
  7→table over 0.2 s + target ring lineWidth +0.4 overshoot) landing as the
  push-in settles. Multi-rung: same script ×1.15.
- **Demotion (0.86 s, SETTLE curve 0.33,0,0.25,1.0):** halos lead (soften),
  pull-back 0.62 s, rings/span follow, ruler briefly loses focus, ends with a
  settle-breath (halo 1.04× → table). Never brightens at any frame; no detent;
  ordering inverted from promotion. **⌘Z Back and "Still off" always play the
  demotion.**
- **Slide (0.42 s, GLIDE):** within-rung position-only; pan compensation and
  light travel share one duration/curve.
- Other edges: `armed→open` 0.45 s all-together (no detent — nothing earned);
  `threshold→fused` 0.40 s (span collapses into the ring; reference ring steps
  out to the outer companion); `→dormant` 0.30 s fade; `→armed` (Try again)
  0.50 s pull-back, no settle-breath.
- Every animation retargets from the presentation layer's live value; one
  transition in flight (new apply cancels all); **no-op guard**: identical
  state + window ⇒ stamp colors only, never replay a transition (the
  referenceOptions repaint currently replays — fix).

### The lock (1.62 s, four beats, input never gated)
0 · intake (0.14 s): breathing off, room quiets (fieldLayer 0.88, ticks 0.25).
1 · merge (0.14–0.70): reference ring contracts onto the target's radius,
both to lineWidth 2.0; soft collision pulse (lw 2.0→2.6→2.0, halo 0.55→0.68→
0.55); reference ring removed invisibly once pixel-identical.
2 · gather (0.30–0.90): two transient bars sweep the wire's light INTO the
ring from both sides (green from the left, magenta from the right), width→0
anchored at the outer ends.
3 · contract + bloom (0.78–1.34): ring 11→9.4 then release to 11; halo
30→40 @ 0.42; ONE `fuseWhite` bloom (scale 1.0→1.85, 0.44 s). Room spill
flashes `fuseWhite` and settles.
4 · settle (1.20–1.44): field back to 1.0; `onLockedSettled?()` cues the
driver to crossfade the kept line in.

### Reduce Motion / headless / determinism
Look-states still CHANGE under RM (instant table apply + one 0.12 s
`CATransition` fade only when the look changed; headless: instant, no
transition). Lock = instant + 0.15 s ring fade (RM) / instant (headless).
Field transform never seeded under RM/headless. Transients never created.
Settled model values under everything; `fieldLayer.transform` settles to
identity; existing seams keep reading settled truth. Mid-flight RM/accent
toggles cancel all animations + remove transients (extend the existing
observers). `CATransition` cancels by the literal key "transition".
Ring paths inset by `lineWidth/2` (not the hard-coded 1).

### Implementation shape (stage)
`Rung` enum with `resolve(state, previous)` owning hysteresis; `Look` struct +
static table; `Transition` dispatcher (promotion(steps)/demotion/slide/wake/
fuse/bowOut/rearm/lock/none); one `animate(layer:keyPath:to:delay:duration:
curve:)` helper (settled-write + CABasicAnimation, fillMode .backwards,
presentation-layer from). DELETE `visual()`, all `lerp`, `closeQuarters`,
`displayMarginFactor`/`minDisplaySpanMs` (→ table + sticky centre + 40 ms
floor). KEEP `xFor`, `wireY`, `layoutLight`, `haloImage`, `stampColors`
(re-pointed at the new tokens), observers, `reduceMotion` seam,
`displayWindow`'s clamp block, `fireLockBloom` (retimed, called from beat 3).
New seams: `test_rung`, `test_lastTransition`.

## 6. Tests + docs

- `AlignmentStageViewTests`: update span-floor (36→40) and zoom tests
  (quantized spans 64/200/640/full); add hysteresis (60→70 holds near,
  60→80 demotes), no-op (same apply twice ⇒ no transition), rung resolution,
  and RM-look-change tests via the new seams.
- `PopoverBTAlignmentUITests`: adapt for removed question line / education
  line / caption changes (readout text now `confidenceCopy · word`), the
  macIsLate Try-again button, plate button titles unchanged
  (`test_buttonTitles` order: target, reference, together, Back, Stop), the
  intro conditional reference row (1-option = text, no picker).
- New `AlignmentPlateCellTests` (state paint smoke via cacheDisplay
  determinism + focus-ring mask override present + keycap AX help).
- Contrast tests for every new token (MembershipWellContrastTests idiom),
  including `plateRim` ≥3:1 vs raised+canvas both appearances and the Deep
  companions vs light grounds.
- Docs land with code: `AudiouterPopoverUI/AGENTS.md` (ladder ownership of
  boundaries, identity-color doctrine note, plate cell = drawing-only skin,
  clock now nameplate chrome, reference row intro-only) and
  `AudiouterSharedUI/AGENTS.md` Tokens row (new instrument tokens). Trim to
  stay inside the word discipline. Figma mirror owed (note, don't do).

## 7. Verification

```
bash scripts/build.sh
bash scripts/run-tests.sh --filter AlignmentStageViewTests
bash scripts/run-tests.sh --filter PopoverBTAlignmentUITests
bash scripts/run-tests.sh --filter PopoverLocalSyncTrimTests
bash scripts/run-tests.sh --filter PopoverControllerTests
```
Plus the token-contrast suite added in §6. Live hardware pass owed after.
