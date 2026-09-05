# HANDOFF — Alignment wizard v2 ("Two Voices, on the Plate")

Written 2026-08-23 for someone with NO access to the working conversation.
Everything you need is in this worktree. Read this file top to bottom before
touching anything.

## Where you are

- Worktree: `.claude/worktrees/wizard-ui`, branch `claude/wizard-ui`
  (HEAD `202dc4e4`, pushed). **Everything described below is UNCOMMITTED
  working-tree state.** Do not restore from HEAD; the tree is the truth.
  Nobody has committed on purpose: Guard 7 (self-review) is the owner's step.
- `main` is merge-only; work stays on this branch until the owner merges.
- Build/tests go through the wrappers ONLY (`bash scripts/build.sh`,
  `bash scripts/run-tests.sh --filter <Suite>`) — never bare
  `swift build`/`swift test`. TRAP: piping build output to `| tail` returns
  tail's exit code — check exit codes unpiped.
- Read `AGENTS.md` (root) and
  `AudiouterCore/Sources/AudiouterPopoverUI/AGENTS.md` before editing;
  they are binding.

## What this feature is

The Bayesian speaker-alignment wizard (user answers "which speaker clicked
first?" ~15×; a posterior narrows; a proposal plays; they confirm by ear) was
rehosted from a cramped popover panel into a dedicated floating window with a
live visualization ("the stage"): two lights on a wire = the two ends of the
95% credible interval, riding a fixed dark plate. Sync Green `#2BFF8F` = the
target speaker, Party Magenta `#FF90E9` = the reference (the brand's two
website secondaries; identity-not-state doctrine — "is it live" stays gold).
Confidence climbs a 4-rung ladder with authored transitions; the lock fuses
the two lights into warm white `#FFF4E2`.

**Design authority, in priority order:**
1. `dev/notes/wizard-stage-v2-spec.md` — the binding consolidated spec
   (owner rulings applied; §2 color, §3 layout with exact pt values,
   §4 exact strings, §5 the rung look table + choreography).
2. `dev/notes/wizard-v2-handoff/wizard-mock-v2.html` — the approved mock.
   Open in a browser; the section "v2 · Two Voices, on the Plate" is the
   target look. (Earlier sections are design history.)

## State of the build

- v2 is implemented end to end and ALL suites are green:
  build + AlignmentStageViewTests 19 · PopoverBTAlignmentUITests 50 ·
  PopoverLocalSyncTrim 6 · PopoverControllerTests 119 ·
  AlignmentTokenContrastTests+AlignmentPlateCellTests 13. Two code-review
  cycles already ran and their findings are fixed.
- **BUT the owner's live test verdict was "technically right, visually
  amateur — the implementation does not match the mock."** A four-agent
  visual critique of actual renders confirmed it and found the causes.
  That critique is the section below, and finishing it is the job.
- Key files (all in `AudiouterCore/Sources/AudiouterPopoverUI/` unless
  noted): `AlignmentStageView.swift` (the stage: rung ladder, transitions,
  lock sequence), `BTAlignmentWizardView.swift` (window content: bands,
  plates, copy, keyboard), `AlignmentPlateCell.swift` +
  `AlignmentPlateButton.swift` (the drawn tactile buttons),
  `AlignmentWizardWindowController.swift` (window + room-spill washes),
  `AudiouterSharedUI/Tokens.swift` (8 new tokens §2.1),
  `AudiouterCore/BTAlignmentWizardSession.swift` (2 tiny accessors only).
  Tests: `AlignmentStageViewTests`, `AlignmentPlateCellTests`,
  `AlignmentTokenContrastTests`, `PopoverBTAlignmentUITests`.
- Known traps already learned the hard way, do not relearn:
  `NSButton` is FLIPPED — all cell y-math is flipped-coords;
  `isBordered` must stay `true` on the plates or the focus-ring mask dies
  (openradar 29465363); explicit `CATransition` ignores
  `setDisableActions` — gate manually; the stage's settled-model-values
  invariant keeps snapshots deterministic — never animate without writing
  the settled value.

## Seeing it

- Offscreen renders (no window shown):
  `cd AudiouterCore && swift run wizard-snapshot <output-dir>` — renders
  9 states as PNGs. The current renders the critique below refers to are in
  `dev/notes/wizard-v2-handoff/`.
- Live hand-test builds: `APP_NAME="Audiouter Wizard v3"
  BUNDLE_ID="com.audiouter.Audiouter.wizardv3" bash scripts/make-app.sh`
  then `open` the produced .app. **Every handover build needs a FRESH
  bundle id** (TCC grants are pinned to id+signature; v1/v2 ids are used).
  Wizard entry: right-click a Bluetooth row (or the Mac's row) in the
  popover → "Align speaker…".
- Note: `wizard-snapshot` required making `BTAlignmentWizardView` and
  `AlignmentWizardWindowController` public (repo precedent: the other
  `*-snapshot` executables). Those visibility changes are part of the tree.

## STATUS 2026-08-23 (third pass) — critique rulings applied

`/impeccable critique` scored the second pass 26/40 (snapshot in
`.impeccable/critique/`). The owner ruled on its five questions; spec §0b records
the rulings. Applied, 210 tests green, renders refreshed in `after/`:
plates hero (236×88) over a 112 pt stage strip · `Which clicked first? ·
<word>` readout, interval on the stage tooltip · click count replaces the
clock · kept hero line "<Target> is ready to play with everything." · full
electric rims/keycaps in dark · names stamped under the lights on the
intro · neutral armed span + neutral locked wire · "Set it manually" on the
proposal corner row + unsettled secondary; Try again is every bow-out's
default · `Undo ⌘Z` · light spill off · locked halo 56 @ 0.55 (static
carrier for Reduce Motion) · short screens centred in the band.

**Open decision (owner):** modal-over-the-app vs the current floating window
(spec §0b.7). Not built. Also not done: "Set it manually" behind Stop (would
need a new session screen — Stop stays an immediate exit); stock pop-up
chrome on the intro; WarmCanvasView grain.

Live build: `build/Audiouter Wizard v4.app` (`com.audiouter.Audiouter.wizardv4`).

## STATUS 2026-08-23 (second pass) — fix list executed

All six root causes and most of the area findings are fixed in the tree;
all six verification suites are green (stage 21 · plate cell 9 · token
contrast 5 · BT alignment UI 50 · local sync trim 6 · popover 119 — 210
tests). Renders AFTER the pass are in `dev/notes/wizard-v2-handoff/after/`
(18 states, incl. the coverage gaps B listed: light proposal/kept/unsettled,
unreachable, macIsLate, pressed, 0-/1-option intro). The pre-pass renders
stay at the top level as the critique's evidence.

What changed, by cause (all in `AudiouterPopoverUI/` unless noted):
- RC1: `AlignmentPlateButton.alignmentRectInsets` = zero (the `.push`
  bezel's insets were what outset the frame). Plates 220×64, gaps restored.
- RC2: `.trailing` chip now 22×22 at `maxX − 14`, midline-centred; title
  centred in the width left of it. Chip has NO fill; ink = white on gold,
  identity tint at full alpha, `inkSecondary` on neutral plates.
- RC3: inline title width measured off `attributedTitle` — an
  `NSButtonCell`'s `attributedStringValue` is its STATE ("0"), hence "T".
  Test asserts drawn title width ≥ title width.
- RC4: content stack alignment `.width` → `.centerX`; corner row pinned to
  the content width (Back at 28, Stop at 532); bodies `Tokens.Font.body`
  regular, `inkSecondary`, centred, wrapping at 400.
- RC5: bevel lips moved one hairline INSIDE the rim (they were under the
  rim stroke); lip strengths to the mock's (0.12 lit / 0.30 shade); the
  view hands the tint WITH its rim alpha (0.45 / 0.9) and the cell now
  multiplies rather than resets alpha. Ground-vs-fill: the room spill was
  r = 336 pt (60% of the window) and lifted the whole ground above
  `raised` — now r = 140, centred on the stage's thirds.
- RC6: `stampColors` stamps `fuseWhite` on ring + halo at `.locked`;
  `playLock` holds green and crosses to white with the beat-3 bloom. The
  snapshot tool runs HEADLESS now (settle lands synchronously) and drives
  a simulated listener at 247 ms, so the kept render reads `248 ms · kept`
  (hero: semibold tabular digits in `label`; body demoted).
- Stage: span = two hard half-bars (crisp seam, no third colour);
  `Look.rulerFill` 0.72 on armed/open (whole range on ~70% of the wire);
  ticks clipped to the candidate range and skipped under lights; wire is
  two stubs that stop short of the ring fused/locked, each in its own hue;
  dormant keeps the previous tick gearing; tight rungs step 10 ms (7
  ticks, not 13); threshold sub-signal (ring +0.5 pt, halo +0.10 over hw
  12→6); fused reference ring ×0.85; plate gets a 1 pt `plateRim` border
  (0.35 dark / 0.9 light).
- Chassis: height floored at the question screen's 413 pt (no lurch);
  readout in tabular digits; U+2212 minus; curly apostrophes; light spill
  at 0.12 with the Deep companions; spill re-stamps on appearance change.

NOT done (owner calls or out of scope): copy changes (magnitude phrasing
"Within 8 ms", "Compare against ⟨name⟩", answer-grammar parallelism,
unsettled primary choice); the stock `NSPopUpButton` chrome on the intro;
`WarmCanvasView` grain tiling / no grain in light (shared, app-wide view);
the 2 pt ragged-right of label padding; the intro's stage-to-copy band
(structural: the empty readout slot + the 28 band).

## THE FIX LIST — visual critique results (2026-08-23)

Method: three independent design-review agents over the 9 renders + the
spec + the mock, plus one mechanical measurement pass (partial; see end).
Findings verified against the renders by the design lead. Renders are 2x;
px÷2 = pt; window content = 560 pt wide.

### Six root causes explain ~80% of everything

- **RC1 — The plate cell draws ~7 pt outside its frame** (likely
  `drawBezel` using an outset rect, or `.push` bezel alignment insets
  ignored). Consequence chain: plates render 234×76 vs spec 220×64, the
  plate row overhangs the 28 pt content column by ~7 pt each side, the
  2-up gap collapses 64→50.5, the 3-up gaps collapse 12→~1 (the three
  unsettled plates TOUCH and read as a segmented control), the together
  bar renders 414×48 vs 400×36 and welds to the plates (gap 12→0.5).
  The stage band, by contrast, is pixel-exact — layout constraints are
  right; the CELL is drawing outside them. One fix collapses ~10 findings.
- **RC2 — The keycap chip is stacked bottom-CENTER under the title instead
  of trailing-right, vertically centered** (`titleRect` isn't subtracting a
  trailing chip slot; chip origin math centers x). This forces the 76 pt
  plate height, pushes titles above center, and on gold primaries renders
  the chip as a dark hole (`#292520` chip + low-contrast glyph on gold —
  a secondary-plate recipe applied to the primary; primary chips need the
  primary's white ink). Spec: chip 22×22 at `maxX − 14 − 22`, centerY =
  plate midline; title centered in the remaining area.
- **RC3 — "They sound together" renders as the single letter "T"** in
  every question state (P0: one of the three answers is unlabeled, and
  it's the one that ends runs). The inline-chip `titleRect` hands the
  title ~4 pt of width; the chip is winning the width fight. Fix the
  inline title width computation; add a test asserting the DRAWN title
  width ≥ the string's width.
- **RC4 — Text rows are right-aligned where the spec says centered.**
  Intro sentence and reference row (right-hugging, 77–93 pt off-center
  vs a correctly centered Start below); body copy on proposal / kept /
  unsettled (all measured right edge ≈530 — on the proposal the
  instruction visually captions the *Still off* reject button); and
  `Back ⌘Z` sits bottom-RIGHT next to Stop (spec: Back at the leading
  28 pt edge — two exits 21 pt apart is a mis-click generator that can
  throw away a whole run). One alignment-bug class, four visible failures.
- **RC5 — The plates are wireframes, not instruments.** Three compounding
  defects in `AlignmentPlateCell.drawBezel`: (a) NO bevel is drawn at all
  (interiors measure perfectly flat rim-to-rim; the spec'd 1 pt lit top
  lip + 1 pt bottom shade are absent, so the pressed bevel-invert has
  nothing to invert); (b) identity rims render at ~0.95 alpha instead of
  the spec'd 0.45 (measured `(123,251,154)` = full-strength Sync Green —
  neon tubing, brighter than the stage lights they echo; NOTE: the LIGHT
  branch got the alpha right — copy it); (c) the plate fill is DARKER than
  the window ground behind it (fill `(35,31,27)` vs ground `(45,44,38)`)
  so "raised" reads as recessed — check which token the ground vs the fill
  actually resolve. In light mode it's worse: fill-to-chassis contrast is
  1.01:1 — pure outlines.
- **RC6 — The lock never turns white, and the kept readout is wrong.**
  The kept screen's ring measures pure Sync Green with zero magenta or
  warm-white anywhere: the reference light just disappears and the target
  survives — reads as "the green one won," not "two became one." The
  entire emotional thesis is unbuilt on screen. `fuseWhite #FFF4E2` must
  be stamped on ring + halo at `.locked` (spec §5 beat 3) and the settled
  room spill must land. Also the readout shows `0 ms`, not `247 ms ·
  kept` — the word "kept" appears nowhere (spec §4); verify whether the
  `0 ms` is fixture data or the live path.

### Remaining findings by area (dedup'd, severity in brackets)

**Stage:**
- [P1] Span gradient's sRGB midpoint is a pale grey-mint at every rung —
  the instrument looks half-fused all run and the lock's warm white
  becomes a hue shift instead of an arrival (two different whites).
  Recommended fix: draw the span as two hard half-bars (green from the
  left light, magenta from the right, crisp seam in the middle) so no
  third color exists until the lock — the seam disappearing IS fusion.
- [P1] Stage emptiness: 504×176 with a 16 pt signal band. At `.armed`/
  `.open` the lights sit ~10 pt from the plate edges (the interval IS the
  ruler — no unlit wire to be narrower than; floor the display window so
  the open span ≤ ~70% of the wire). At `.listening`/`.locked`/dormant
  the ticks vanish and the plate is a void with a crosshair (the wire +
  center tick run straight THROUGH the fused ring — mask the wire under
  the ring and hue the two stubs per side). Dormant should keep the dim
  tick ruler (spec: everything to `stageRule`, not gone).
- [P1] `threshold` rung has no internal signal: from hw 12 → 6 (the
  hardest-clicked stretch) only the span shrinks ~20 pt; ticks/zoom/halo
  frozen. Give the top rung a continuous sub-signal (let the window keep
  tightening inside threshold, or interpolate ring lineWidth/halo opacity
  over hw 12→6).
- [P2] Tick behavior: `open` renders only 3 ticks (sparse + featureless);
  `threshold` renders 13 (busiest at the calmest moment) and the count
  wobbles 13→12 when a light covers one. Clamp to ~6–8 ticks, dim them as
  rungs rise, draw ticks above/clipped against lights.
- [P2] Reference ring at `.listening` measures dusty mauve `#B488A7`,
  not Party Magenta — it's compositing under the green halo; raise alpha
  or reorder layers so "two voices about to merge" reads.
- [P3] Halo diameter at threshold measures ~24 pt vs table 30.

**Window / chassis:**
- [P1] Light mode: the stage plate is a naked black rectangle on white
  (18:1 cliff, no rim/bezel — reads as a failed video embed). Give it a
  recessed-screen bezel: 1 pt warm dark rim + 1 pt inner top shadow +
  1 pt light bottom lip (inverse of the plates' raised bevel).
- [P2] Room spill: in light mode it's invisible as hue but visible as
  blur-boundary banding (and it uses the electric values, not the Deep
  companions the spec requires); in dark it reads as corner smudges.
  Use Deep companions in light at higher alpha (~0.12) or drop the spill
  in light mode; in dark, center the washes behind the plate and soften.
- [P2] Intro has a ~53 pt dead band between stage and copy (content is
  bottom-anchored into the question-screen chassis height); also the
  window lurches 423→453 pt on Start — size the chassis once at the
  question height for the whole session.
- [P2] The reference `NSPopUpButton` is stock cool-gray chrome — the
  brightest control after Start in dark mode; consider borderless or the
  app's warm control treatment. Also shorten the label: "Compare against
  ⟨name⟩" (drop "Comparing Kitchen HomePod against" — the target is in
  the nameplate).
- [P2] Dark grain texture visibly tiles at 48 pt; light mode has no grain
  at all (the two appearances read as different products).
- [P3] Right-aligned text rows land at x=530 vs the 532 column edge —
  2 pt ragged right across nameplate clock / ESC / stage edge.

**Type & copy (copy changes need the owner's sign-off — locked-string
governance):**
- [P1] Kept-screen hierarchy is inverted: bold near-white body ("Fine-tune
  anytime…" — the fine print) outranks the achievement; promote the
  readout (`247 ms · kept`) to hero weight/ink, demote the body to
  `inkSecondary`. Same bold-white-body problem on unsettled (the failure
  is the loudest text) and its 471 pt single-line measure (wrap to two
  centered lines).
- [P2] Signed intervals read as bugs to the design target ("between -8
  and 8 ms", "-7 and 6"): recommend magnitude phrasing at straddling
  rungs ("Within 8 ms") — needs owner approval as a copy change; at
  minimum use U+2212, not hyphen-minus.
- [P2] Caption digits: use `monospacedDigitSystemFont` so the centered
  caption doesn't shimmy on every answer.
- [P2] Together-bar title color: renders pure `#FFFFFF` (dark) /
  `#000000` (light) — off-token; should be `inkSecondary`-family; a
  secondary control must not own the brightest text.
- [P3] Straight apostrophes (`'` U+0027) in "You'll" / "aren't" → U+2019.
- [P3] Intro sentence is the heaviest type in the window (semibold ~15);
  body regular is enough.
- [P2] Answer grammar: "Kitchen HomePod" / "Office Sonos One" / "They
  sound together" mixes nouns with a sentence; consider parallel forms
  (owner call).
- [P3] Unsettled primary: gold plate = "Set it by hand" makes the loudest
  offer more manual work; "Try again" may be the kinder default. Design
  question for the owner, not a bug (spec currently says Set-by-hand primary).

**What already works (do not break):** the stage band geometry is
pixel-exact (504×176 on the 28 pt column, wire at 0.58, correct rung
gearing per the §5 table, sticky-center drift behaving); the two-voice
color mapping (green-left/magenta-right, plate rims + chips echoing the
lights) reads instantly with zero explanation; the nameplate row is
correct console chrome (`inkSecondary`, never gold); token plumbing is
sound (the failures are alpha/geometry, not wrong tokens); transitions
were praised by the owner as "extremely smooth and well implemented."

### Fix order (dependency-aware)

1. RC3 (the "T") — a P0 unlabeled answer.
2. RC4 (alignment class) — one bug, four screens.
3. RC1 (outset drawing) — restores every dimension and gap at once.
4. RC2 (chip trailing) — restores the 64 pt height; with RC1 the whole
   4/12/16/28 rhythm returns.
5. RC5 (bevel + 0.45 rims + raised-vs-ground) — turns wireframes into
   the instrument.
6. RC6 (fuseWhite lock + `· kept` readout + kept hierarchy) — the
   emotional payoff.
7. Then the stage list (span seam, emptiness, threshold sub-signal,
   ticks), then chassis (light-mode bezel, spill, intro band), then
   type/copy (copy items via the owner).

After fixing: re-run `swift run wizard-snapshot`, EYEBALL the renders
against `wizard-mock-v2.html` (this step was skipped before and is
exactly how the gap shipped), then run the six verification suites, then
a fresh-bundle-id live build for the owner.

## Assessment B (mechanical measurement pass) — completed before the stop

B independently confirms the P0s: the "T" truncation on every question
render ("Critical"), the stacked keycap chip on every keycapped plate
(only the together bar's chip is correctly inline), plates ≈233 wide with
collapsed gaps (three-plate gaps ≈0–2 px, "suggesting width computed as
available-space/N rather than the fixed 160/220+gap formula"), the kept
readout missing "· kept", and the kept ring sampling #7BFB9A green where
`fuseWhite` is specced. It also confirms MATCHES worth protecting: stage
plate exactly 504×176 @ #100B07 r12, wire at 0.58, armed halo/ring per
the look table, band rhythm 16/12/28/12/16 within ~1 pt, `plateRim`
exact, status words correctly paired to rungs.

**B's additional flags to verify during the fix pass:**
- `goldCTA` interior samples ≈ #785F22 vs token #815E0E (blue channel
  high — maybe AA/compositing, maybe a wrong stamp).
- Light-mode `syncSignalDeep` rim back-solves nearer #206936 than
  #0B7A45 (magenta Deep matches exactly).
- The Start plate's ⏎ chip isn't in §4's string list (informational —
  deliberate default-button affordance).

**Cross-agent contradictions — re-measure before trusting either side:**
- Back/Stop placement: A1 and A2 both measured Back at x≈419–461 (bottom-
  RIGHT, beside Stop) with pt coordinates; B says "Back leading / Stop
  trailing correct." Two precise independent measurements beat one
  summary judgment — treat RC4's Back finding as real, but re-measure.
- Secondary-plate fill: A2 sampled interiors at (35,31,27) = `raised`
  (i.e., FILLED, while spec §2.2 says secondary = no fill, rim only);
  B says "stroke-only — matches." A2's pixel probe is the harder
  evidence. Decide the intended answer first: the spec says no fill,
  the current dark render's fill is ALSO darker than the window ground
  (RC5c) — fixing RC5c may make a fill correct and desirable; that's a
  design call for the owner.
- Bevel lips: A1/A2 probes say absent; B says "too subtle to confirm at
  this resolution." The probes are dispositive: treat as absent.

**B's coverage gaps (nobody has verified these):** no renders exist for
`unreachable` / `macIsLate` screens, no light-mode renders for
proposal/kept/unsettled, no pressed-state render (the chip press-lip
behavior is entirely unverified visually), no Increase Contrast renders,
and the 0-option / 1-option reference-picker branches were never
rendered. Extend `wizard-snapshot` to cover these before calling the
visual pass done.

## Owed beyond the fix list

- Commit (the owner runs Guard 7 self-review), merge + PR per repo workflow.
- Live hardware pass incl. one REAL ✕ window-close mid-run (the
  re-entrant AppKit close path is only headlessly tested).
- Purge test-build residue: bundle ids `com.audiouter.Audiouter.wizardv1`
  and `.wizardv2` (`scripts/purge-dev-installs.sh`, dry-run first).
- `.impeccable/critique/` snapshot was not yet persisted (critique was
  interrupted for this handover).
- Three stale worktrees `wizui-t1/2/3` are flagged `.prunable`;
  housekeeping collects them on the next build.
