# Auto sync wizard — the animation chain, exactly as built

Scope: the mic-probe path through the alignment wizard. Start → the Mac listens
→ it proposes a number → "Sounds right" → kept. Three authored moves in that
path, plus everything that rides alongside them.

Every number below is read out of the code, not from the spec. Anchors are
`file:line` in the repo as of 2026-09-14.

---

## 0. The two names that collide

There are two `.listening` cases in this feature and they mean opposite things.
Getting them backwards is the fastest way to misread the whole file.

| Name | Type | Meaning |
|---|---|---|
| `Screen.listening` | `BTAlignmentWizardSession.Screen` | the **microphone** is listening, the run is measuring |
| `State.listening` | `AlignmentStageView.State` | the **user** is listening to the proposal being previewed |

The mapping between them is one function,
`stageState(for:range:)` (`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:987`):

```
Screen.intro           → State.armed(range:)
Screen.listening       → State.measuring(range:)        ← mic probe running
Screen.proposal(v)     → State.listening(valueMs: v, …) ← preview playing
Screen.kept(v)         → State.locked(valueMs: v, …)
```

So when the screen says "listening", the stage says "measuring". They are never
the same word at the same moment.

---

## 1. The chain

Four layers decide what happens, in this order, on every screen change:

**Screen** (session) → **State** (stage) → **Rung** (stage) → **Transition** (stage) → **Script** (timings).

The auto sync path walks it three times:

| Step | Screen | State | Rung | Transition | Total |
|---|---|---|---|---|---|
| user clicks Start | `.listening` | `.measuring` | `.measuring` | `.wake` | 0.45 s |
| probe returns a number | `.proposal(v)` | `.listening(v)` | `.fused` | `.fuse` | 0.40 s |
| user clicks "Sounds right" | `.kept(v)` | `.locked(v)` | `.locked` | `.lock` | 1.62 s |

Rung resolution is
`Rung.resolve` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:177`).
On this path it is trivial — three of the four states map to a fixed rung with
no thresholds involved. The hysteresis in that function only ever fires on the
by-ear question path, where the rung is decided by the credible interval's
half-width.

Transition selection is
`transition(previousState:previousRung:newState:newRung:isFirstApply:)` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:606`),
checked top to bottom:

```swift
if newRung == .locked && previousRung != .locked { return .lock }   // step 3
…
if previousRung == .armed && newRung == .measuring { return .wake } // step 1
…
if newRung == .fused && previousRung != .fused { return .fuse }     // step 2
```

The ladder comparison below those lines (promotion / demotion / slide) is never
reached on the auto sync path. Nothing here is a general "animate to the new
look" — each of the three is a named script with its own timings.

---

## 2. The machinery, before the three moves

Five mechanisms carry all of it. They are worth reading first, because each
move is mostly a table of numbers fed into them.

### 2.1 One animation primitive

`animate(layer:keyPath:to:leg:curve:)` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1172`):

1. read `from` off the **presentation** layer (`layer.presentation() ?? layer`)
2. write the settled value to the model layer inside a
   `CATransaction` with `setDisableActions(true)`
3. add a `CABasicAnimation` from → to, with `beginTime = now + delay`,
   `duration`, the script's curve, and `fillMode = .backwards`

Two consequences that the whole design leans on:

- **The model is always the settled truth.** At any instant, the layer's own
  property values are what the rung says they should be. Only the presentation
  layer is mid-flight. Snapshots, tests, and a resize all read the settled model
  and get a coherent answer.
- **A new transition retargets instead of snapping.** Because `from` comes off
  the presentation layer, interrupting a move halfway starts the next one from
  where the pixels actually are.

`fillMode = .backwards` is what makes a staggered leg wait in place during its
delay rather than jumping to the destination and then animating.

### 2.2 Legs and scripts

A `Script` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:808`)
is one `(duration, delay)` pair per element — camera, halos, span, wire — plus
the tick crossfade time, the two optional flourishes, and whether the camera is
seeded. The three scripts on this path:

```swift
wakeScript  = curve ratchet, camera (0.45, 0), halos (0.45, 0),
              span (0.45, 0), wire (0.45, 0),
              tickCrossfade 0.225, detent nil, settleBreath nil, seedsCamera false

fuseScript  = curve glide,   camera (0.40, 0), halos (0.40, 0),
              span (0.40, 0), wire (0.40, 0),
              tickCrossfade 0.20,  detent nil, settleBreath nil, seedsCamera true

// the lock runs its own four beats and takes `instantScript` from the table
```

Curves (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:415`):

- `ratchetCurve` = `cubic(0.16, 1.0, 0.3, 1.0)` — banked progress landing in a notch
- `settleCurve` = `cubic(0.33, 0, 0.25, 1.0)` — gives ground, settles, never snaps back
- `glideCurve` = `.easeInEaseOut`

### 2.3 Transients are additive deltas

A flourish that overlaps a leg cannot be a plain keyframe: a non-additive
keyframe **replaces** the property for its duration and leaves its own final
value standing when removed.
`pulseDelta` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1232`)
solves it — values `[zero, delta, zero]`, `keyTimes [0, 0.5, 1]`,
`isAdditive = true`, so the pulse rides on top of whatever the leg or the model
holds. `pulseHalo` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1247`)
wraps it for `bounds.size`, computing the delta between two halo boxes.

The comment at
`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1217`
names the three bugs this fixed, one of which is directly on this path: the
lock's collide pulse used to yank the light back to 50 pt while the merge leg
was gliding it 50 → 74, then jump to 74 when the pulse was removed.

The one surviving non-additive `pulse` is the detent's shadow **colour**, which
has no meaningful delta. It does not fire on the auto sync path.

### 2.4 The camera

Everything the window moves — ticks, span, both lights — lives inside
`fieldLayer`, which is clipped (`masksToBounds = true`) and anchored at
`.zero` so its transform is a plain `x' = sx·x + tx` in view coordinates. The
wire is deliberately **outside** it: the rail is the fixed thing the ruler
slides under.

A window change is played as a camera gesture
(`seedCamera` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:945`)):
seed the transform that maps the NEW window's screen positions back onto the
OLD window's, then animate to identity.

```
sx = clamp(newSpan / oldSpan, 0.30, 3.33)
tx = inset·(1 − sx) + usable·(newLower − oldLower) / oldSpan
```

Zooming in becomes a push-in, zooming out a pull-back, a pure pan a translate.
The clamp is a deliberate ceiling with a `razor:` marker — its upgrade path is
to chain two gestures, not to widen it. Section 4.2 works out what that clamp
actually does on the fuse, because on this path it is always active.

### 2.5 The lights are a Metal field, driven by invisible carriers

Each light is one source of the emitter field's settled state, drawn by
`SettledLightLayer` (`AudioutCore/Sources/AudioutPopoverUI/SettledLightLayer.swift`) —
a `CAMetalLayer` sitting at index 0 inside `fieldLayer`, so it inherits the
camera transform and the clip for free.

Above it sit two `LightCarrierLayer`s (`targetHalo`, `referenceHalo`). They
draw **nothing**: no contents, `borderWidth = 0` so `borderColor` is a pure
tint channel. Their job is to be animated. Every frame, a `CADisplayLink` at
15–30 fps (preferred 30) calls
`currentLights()` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1749`),
which reads each carrier's **presentation** values:

| Carrier property | Field input |
|---|---|
| `position` | light centre |
| `bounds.width / 2 × transform.m11` | radius (so the breathing scale folds in) |
| `opacity` | brightness |
| `variant` | which seed/density/breathe-rate family the source runs |
| `borderColor` | tint, converted to sRGB components |

That is why there is only ever one choreography. Every transition, pulse and
breath is scripted on two ordinary `CALayer`s; the shader just reads them.

`variant` is a `@NSManaged CGFloat` with
`needsDisplay(forKey:) == true`, which is what makes it animatable, and
`init(layer:)` copies it by hand because `@NSManaged` storage is not copied
into a presentation layer for you
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:59`).

Headless or without a GPU, `SettledLightLayer.make()` returns `nil` and the
carriers hold a bitmap radial-gradient halo in `contents` instead. Same
geometry, same scripts.

---

## 3. Move 1 — Start pressed: the two lights split apart

`Screen.intro → Screen.listening`, `.armed → .measuring`, transition `.wake`,
0.45 s, ratchet curve, **no camera seed**.

### 3.1 Where the lights go

`lightValues()` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:738`)
for `.measuring(range:)` returns `(range.lowerBound, range.upperBound)` — the
two ends of the whole candidate range. Not an interval, not a belief: the run
has not measured anything yet, so the instrument shows the widest thing it can.

The window is the full range too
(`displayWindow` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:653`)
returns `r` for `.armed` and `.measuring` before the quantized ladder is even
consulted), and `rulerFill = 0.72` widens the mapped range about its centre so
the range occupies 72 % of the wire.

Worked, at the shipping width (sheet 560 pt, wizard view 504 pt, stage
horizontal inset 26 pt, so usable wire = 452 pt) and the Mac target's ±500 ms
range:

```
mapped window   = ±694.4 ms      (1388.9 ms across 452 pt)
low light  −500 ms → x =  89.3 pt   (14 % of the wire)
high light +500 ms → x = 414.7 pt   (86 % of the wire)
```

Unlit wire at both ends is the point: it leaves the interval something to be
narrower **than**. A Bluetooth run's range comes from
`btLatencyRangeProvider` (PopoverController.swift:5051 (`AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:5051`))
and is usually not symmetric, but the mapping is identical.

### 3.2 What actually changes in those 0.45 s

`.armed` → `.measuring` in the look table
(`look(for:)` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:262`)):

| Property | armed | measuring | leg |
|---|---|---|---|
| halo diameter | 106 | 96 | halos |
| halo opacity | 0.55 | 0.65 | halos |
| core radius (clearance only) | 36 | 32 | — |
| wire opacity | 0.55 | 0.66 | wire |
| tick half-height | 4 | 4.75 | (path, instant) |
| tick opacity | 0.35 | 0.48 | span |
| span opacity | 0.22 | 0.22 | span |
| breathe period | 5.2 s | **1.3 s** | reconciled |
| breathe amplitude | 1.05 | 1.08 | reconciled |
| tick step | 250 ms | 250 ms | no crossfade |

The lights do not travel — armed and measuring both park them at the range
ends. The whole move is a brightness and size step plus a tempo change. The
quick 1.3 s breath is the only "busy" cue, and it is chosen so it cannot lock
step with either click period (3 s or 0.833 s).

Two instant, un-animated changes ride along:

- **The name stamps disappear.** `targetNameLabel` / `referenceNameLabel` are
  real `NSTextField`s, shown only while armed
  (`layoutNameStamps` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:760`)
  sets `isHidden = !armed`). No fade — they are gone on the next layout pass.
- **The span stays neutral.** `neutralSpan` covers `.armed` and `.measuring`
  (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1607`),
  so the bar between the lights is four stops of `stageRule` with
  `shadowOpacity = 0` — no speaker identity on it, because nothing is believed
  yet.

### 3.3 Breathing

`reconcileBreathing` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1536`)
runs after every `play`. It adds a `transform.scale` animation 1.0 → amplitude,
`autoreverses`, `repeatCount = .infinity`, ease-in-ease-out, with
`timeOffset = period × phase` — phase 0 for the target, 0.5 for the reference,
so the two lights breathe in antiphase (0.65 s apart at the measuring tempo).

It re-adds only when the animation is absent or the **period** changed, so a
repaint does not restart the cycle mid-breath. It is removed entirely when the
rung does not breathe, off screen, headless, or under Reduce Motion.

### 3.4 Alongside, on the screen

The mic symbol on the listening screen is stock AppKit:
`mic.fill` with `addSymbolEffect(.variableColor.iterative.dimInactiveLayers)`
(`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:1145`),
skipped under Reduce Motion and headless. Nothing custom.

The readout row collapses to 0 pt (`applyReadoutHeight`, listening → 0), the
headline and body are rebuilt, and `onContentSizeChange?()` fires — see §6.3.

---

## 4. Move 2 — the probe lands: they come together

`Screen.listening → Screen.proposal(v)`, `.measuring → .listening(v)`,
rung `.measuring → .fused`, transition `.fuse`, 0.40 s, glide curve, camera
seeded.

Trigger:
`offerMeasuredProposal(valueMs:)` (`AudioutCore/Sources/AudioutCore/BTAlignmentWizardSession.swift:420`)
→ `presentEstimatorPhase(measured: true)` → `.proposal`. The value is previewed
audibly at the same moment, which is what the fused, breathing pair is for —
the user is listening to it.

### 4.1 The four things that happen at once

**One.** `lightValues()` for `.listening(value, _)` returns `(value, value)`.
Both lights now resolve to the same x. The target light glides from its end of
the range to that point; the reference glides from the other end. They meet.

**Two.** They do **not** overlap. Fused is drawn as a concentric pair
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1058`):

```swift
layoutLight(halo: targetHalo,    centre: c, haloDiameter: 50,       variant: 0, …)
layoutLight(halo: referenceHalo, centre: c, haloDiameter: 50 × 1.4, variant: 0, …)
```

`fusedReferenceScale = 1.4`
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:405`) is
a fixed constant with a `razor:` marker. Both lights run variant 0, so the
diameter factor is exactly the crest-radius factor, and 1.4 leaves about 2.5 pt
of dark space — roughly one band width — between the target band's outer edge
and the reference band's inner edge. Recompute it if `Look.fused.haloDiameter`,
`SettledLightLayer.crestScale` or `.bandNarrow` change.

Each light keeps its own colour here: green target (`wireCore`), steel-blue
reference (`ring`, pinned to its dark hex in both appearances), both at full
opacity. Nothing has been decided yet — the user has not said "sounds right".

**Three.** The reference's `variant` animates **1 → 0** on the halos leg
(`layoutLight` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1119`)).
That is a crossfade between two sets of shader maths — seed, density and
breathe rate — not a jump between them. It is why the pair reads as one
instrument rather than two lights that happen to be concentric.

**Four.** The span collapses into the light. Width is
`max(highX − lowX, 0)`, which is now 0; `spanOpacity` goes 0.22 → 0; the
position converges on the light's centre. All on the span leg, 0.40 s.

### 4.2 The camera push-in, and the clamp that always fires here

`displayWindow` for `.listening` uses `interval = v...v` and the fused rung's
quantized `windowSpanMs = 64`, clamped to at least `minWindowSpanMs = 40` and
at most the candidate range. The sticky-centre check fails (the span changed by
more than 0.01), so the window re-frames to `v ± 32`, then slides — never
shrinks — if that would cross a range edge.

Fused has `rulerFill = 1`, so 64 ms maps to the whole 452 pt of wire. Continuing
the ±500 ms example with `v = 0`:

```
oldSpan (mapped) = 1388.9 ms
newSpan           =    64 ms
true ratio        = 0.0461   →  clamped to 0.30
tx = 26 × (1 − 0.30) + 452 × (−32 − (−694.4)) / 1388.9
   = 18.2 + 215.6
   = 233.8
seeded transform: x' = 0.30·x + 233.8, animating to identity over 0.40 s
```

Two things to know about that.

The true gesture would be a 21.7× push-in. The clamp caps it at 3.33×, so what
the eye gets is a strong but legible zoom rather than a smear.

Because the clamp changes `sx` but the translation term is computed from the
real windows, **the seeded frame is not the true previous frame** whenever the
clamp is active — which on this path it always is. The fused light's model
position is 252 pt (mid-wire); at t=0 it is drawn at `0.30 × 252 + 233.8 =
309.4 pt`, so it enters about 57 pt right of where the measuring pair's midpoint
sat and travels left as the field expands. That is a deliberate consequence of
the ceiling, not a bug, but it is the one place on this path where the camera
gesture is an approximation of the move it is standing in for.

### 4.3 The wire splits — instantly, not on a leg

At fused and locked the rail stops short of the light on both sides
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1008`):

```swift
let gap = fused || locked ? look.coreRadius + 6 : 0   // fused: 16 + 6 = 22 pt
let midX = fused || locked ? lowX : bounds.midX
```

so `wireLeft` runs from the inset to `lowX − 22` and `wireRight` from
`lowX + 22` to the far inset. The rule never runs through the one light the run
has earned.

Both paths are written inside a `CATransaction` with `setDisableActions(true)`
— the **geometry change is instantaneous on the first frame of the fuse**. Only
the wires' `opacity` (0.66 → 1.0) animates, on the wire leg. The gap simply
appears; it does not open.

The colours change with it
(`stampColors` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1599`)):
fused is the only rung where `asOne` is true, so the left half of the wire
carries `wireCore` at 0.5 alpha and the right half `ring` at 0.5 — each
speaker's own voice running up to the light from its own side. `stampColors` is
called before `cancelInFlight` and `play` in `apply`, and writes stamped
`CGColor`s outside any animation, so this too lands on frame one.

### 4.4 The ruler re-gears

Tick step goes 250 ms → 10 ms, and the window 1000 ms → 64 ms. Because
`lastTickStep != step`, `layoutTicks` adds a `CATransition` on `tickLayer` with
`beginTime = now + 0.20` (the script's `tickCrossfade`), `duration = 0.3`,
`fillMode = .backwards`
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1152`).
The path itself is swapped with actions disabled; the crossfade is what stops
that swap reading as a teleport. Tick opacity (0.48 → 0.85) rides the **span**
leg, not a leg of its own.

Ticks within `coreRadius + 3` of either light's x are skipped entirely, so no
tick ever crosses a light's core.

### 4.5 Settled state at the end of the fuse

| | value |
|---|---|
| halo diameter | target 50, reference 70 |
| halo box height | diameter ÷ `squash` (1.12) |
| halo opacity | 1.0 both |
| span opacity | 0 |
| wire opacity | 1.0, split, two-toned |
| tick step / window | 10 ms / 64 ms |
| breathe | 2.7 s, amplitude 1.03, antiphase |

The pair keeps breathing while the preview plays. That is the whole point of
the `.fused` rung having a period at all — it is the one rung where the user is
being asked to sit and listen.

---

## 5. Move 3 — "Sounds right": the confirmation

`Screen.proposal → Screen.kept`, `.listening(v) → .locked(v)`, transition
`.lock`. Four beats over 1.62 s, hand-scripted in
`playLock()` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1314`).
It is the one transition that does not take its timings from the script table —
`script(for:)` hands `.lock` the `instantScript` and `play` branches out before
it is used.

Input is never gated during it. The value is already persisted by the time the
sequence starts (`acceptProposal` → `endPreview(keptMs)` → `.kept`), so the
animation is an acknowledgement, not a progress indicator.

### 5.1 The timeline

| Time (s) | Beat | What | Mechanism |
|---|---|---|---|
| 0.00 | 0 | breathing removed | `reconcileBreathing` — `.locked` has `breathePeriod: nil` |
| 0.00–0.14 | 0 | field dims 1.0 → 0.88; ticks 0.85 → 0.25 | keyframes on `fieldLayer.opacity` and `tickLayer.opacity`, `keyTimes [0, 0.14, 1.20, 1.44] / 1.62` |
| 0.14–0.70 | 1 | **merge leg**: target box 50 → 74, reference box 70 → 74 while its opacity goes 1 → 0; span and wire follow | `applyGeometry` with `halos = span = wire = (0.56, 0.14)`, settle curve |
| 0.30–0.90 | 2 | **gather bars**: two 2.5 pt bars collapse from the wire's outer ends into the light | two transient `CALayer`s, `bounds.size.width → 0` + `opacity 0.85 → 0`, settle curve |
| 0.56–0.76 | 1 | **collide**: +8 % swell on the target | `pulseHalo` additive, peak `haloBox(50 × 1.08)` vs settled `haloBox(50)` |
| 0.78–1.34 | 3 | **contract**: target box 74 → ~34.8 → 74, deepest at 1.06 | `pulseHalo` additive, peak `haloBox(74 × 9.4/20)` |
| 0.78–1.22 | 3 | **bloom**: one `fuseWhite` glow, scale 1.0 → 1.85, opacity 0.9 → 0 | transient `CALayer`, ease-out |
| 0.78–1.22 | 3 | **colour cross**: target tint green → `fuseWhite` | `CABasicAnimation` on `borderColor`, ease-out, backwards fill |
| 1.20–1.44 | 4 | field back to 1.0, ticks back to 0.85 | tail of the beat-0 keyframes |
| **1.44** | 4 | `onLockedSettled()` fires | `DispatchQueue.main.asyncAfter`, generation-guarded |
| 1.62 | — | transients removed | `removeTransients()`, generation-guarded |

### 5.2 Beat 1 — the merge

The reference light does not vanish. `applyGeometry` is called with the merge
leg as every element's leg, and the locked branch
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1070`)
gives the reference the target's centre, the target's diameter (74) and
**opacity 0**. So its fused 70 pt box animates up to 74 as it fades, rather than
snapping to a size nobody sees. Only the target ring survives to carry the
flash.

The collide swell at 0.56 is where the two lights are felt to meet. It is
additive precisely because the merge leg is still running underneath it — the
light keeps growing 50 → 74 through the collision. It is over by 0.76, before
beat 3 adds its own delta to the same property.

### 5.3 Beat 2 — the gather bars

`fireGatherBars` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1420`):
one bar per side, 2.5 pt tall, corner radius 1.25, coloured with that side's own
speaker hue — green from the left, steel blue from the right.

The **anchor point is the inner edge** (`x: 1` on the left bar, `x: 0` on the
right), so shrinking the width collapses the bar **into** the light. The beat is
a gather; light draining outward would read as its opposite.

`fromValue` is supplied on both animations and `fillMode` is deliberately left
at its default (not `.backwards`), because the layers are added to the tree at
t=0 but must not be visible until 0.30. Their settled model values — zero width,
zero opacity — are the truth outside their own interval.

### 5.4 Beat 3 — contract, bloom, cross

The light draws breath before it releases. The contraction is expressed as the
old outline ring's 20 → 9.4 pt, applied to the whole light's box
(`74 × 9.4/20 ≈ 34.8 pt`) so the light draws in rather than a stroke inside it.
Additive again, so it composes with whatever the merge leg left.

The bloom is a separate transient layer carrying a radial-gradient image
(`haloImage` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1663`),
64×64, `fuseWhite` at 0.9 → transparent), scaled 1.85× as it fades. One glow,
contained, not a stroke — nothing on this stage draws an outline on any rung.

The colour cross runs on `borderColor` only when the Metal field is present. The
`contents` cross is appended **only** when `settledLights == nil`
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1386`) —
with the field up, `contents` is nil and crossing it would park a green blob
over the light for 0.44 s.

Settled colours are already `fuseWhite` from `stampColors` before the sequence
starts; the cross exists to hold the green until the bloom releases it.

### 5.5 The wire at locked

`asOne` is false at `.locked`, so both halves revert to `stageRule`. The
two-toned rail is a fused-only state: under a white light it would say the two
voices never met. The gap widens slightly, to `coreRadius + 6 = 26 pt`.

### 5.6 The cue, and why it is a cue

`onLockedSettled` fires at 1.44 s, not at 1.62 s, and not on the screen change.
`armKeptReadout` (`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:1067`)
wires it to
`crossfadeReadout` (`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:1097`),
which swaps "`123 ms`" for "`123 ms · kept`" under a 0.25 s `CATransition`.

Three details:

- `armKeptReadout` is called **before** `stage.apply` in `render`
  (`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:735`),
  because under Reduce Motion and headless the lock settles *synchronously
  inside* `apply`. Wiring it after would drop the cue.
- The readout row's height is driven off the **screen**, never off
  `readout.stringValue` — a string test would have collapsed the row to zero and
  then crossfaded words in behind it.
- `CATransition` is filed under the literal reserved key `"transition"`
  whatever key you pass to `add(_:forKey:)`. Both call sites carry that note.

The kept screen's own hero line ("… is ready to play with everything.") and its
Done plate are built immediately on the screen change, not on the cue. Only the
readout waits.

---

## 6. What runs alongside the three moves

### 6.1 The room spill

The sheet ground carries two radial washes behind the stage — green
(`wireCore`) behind the left third, steel blue (`ring`) behind the right — in
`RoomSpillView` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentWizardViewController.swift:155`).
It is a sibling `NSView`, not a sublayer of the canvas, because
`WarmCanvasView.draw(_:)` repaints its full bounds on every appearance flip.

It is driven by `stage.onRungChange`, wired in the controller's `init`
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentWizardViewController.swift:54`).
Peak alpha 0.10 in dark, **0 in light** (measured at 0.07 and 0.12 the wash was
under 1 % neutral darkening with no chroma — invisible as a tint, visible only
as banding).

Per-rung intensity is `haloOpacity(rung) / 0.58 × peak`:

| rung | factor |
|---|---|
| armed | 0.20 |
| measuring | 0.40 |
| fused | 0.55 |
| locked | 0.42 |

Every ordinary rung change crossfades over 0.6 s ease-in-ease-out. `.locked` is
the exception — `performLockFlash` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentWizardViewController.swift:305`):

```
t=0      both spills restamped to fuseWhite, actions disabled
0–0.2    opacity → 0.10, ease-in-ease-out
0.2–0.7  hold
0.7      settleAfterLockFlash: 0.3 s CATransition back to the tints,
         left → locked's faint green, right → 0
```

The settle is guarded on `lastRung == .locked`, so a rung change inside the
0.7 s hold supersedes it. Locked is the only asymmetric rung: green-only wash,
right spill at zero.

### 6.2 The order inside `apply`

`apply(_:animated:)` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:558`),
in sequence:

1. resolve the new rung and the new window
2. **no-op guard** — identical state and window re-stamps colours and returns.
   This is what stopped the stage twitching on unrelated repaints (the reference
   picker rebuilding, an appearance flip)
3. commit `state`, `rung`, `displayRange`
4. pick the transition
5. `stampColors()` — instant, outside any animation
6. `cancelInFlight()` — see §7
7. `needsLayout = true`
8. `play(...)`, gated on `animated && !reduceMotion && !HeadlessRuntime.isActive`
9. `reconcileBreathing()`
10. `onRungChange?(rung)` if the rung changed, or on the first apply

`play` seeds the camera (if the script asks) and then calls `applyGeometry`,
which is also what `layout()` calls with `instantScript`. A later layout pass
rewrites the same settled values with zero-duration legs; the in-flight
animations carry explicit from/to values and keep playing.

### 6.3 The sheet resize

`render` ends with `onContentSizeChange?()`
(`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:919`),
which reaches
`fitToContent` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentWizardViewController.swift:96`):
measure the canvas's fitting height, publish it as `preferredContentSize`.
**AppKit animates an attached sheet to that size on its own** — there is no
hand-written height animation anywhere in this feature.

The stage never moves during it. The chassis is fixed — title row, stage,
readout caption — and only the band below changes per screen
(`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:369`).
The readout row is the one chassis element whose height changes: 0 on the
listening screen, 15 pt on proposal and kept.

So on the fuse, the sheet's height change and the stage's 0.40 s transition run
concurrently and independently, and the stage's y is unaffected by either.

---

## 7. Cancellation, retargeting, and the obligations they carry

`cancelInFlight` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1515`)
runs at the top of every `apply`:

```swift
fireLockSettled()          // honour the pending cue rather than dropping it
transientGeneration &+= 1  // invalidate the two deferred lock cleanups
removeTransients()         // gather bars, bloom
for sub in [...] { sub.removeAllAnimations() }
```

One transition is on the stage at a time; a new apply drops whatever was
running. Because `animate` reads `from` off the presentation layer, that is a
retarget, not a snap.

The `fireLockSettled()` call is load-bearing. `isLockSettlePending` is set when
the lock starts and cleared by the first settle, so the cue fires exactly once
whether the script ran to 1.44 s or a cancel cut it short. Without it, a Reduce
Motion or accent toggle landing mid-lock swallowed the cue and left the readout
on the proposal's number forever.

The two `asyncAfter` blocks at 1.44 s and 1.62 s both capture
`transientGeneration` and bail if it has moved, so a superseded sequence cannot
reach in later and remove a live transient.

---

## 8. Reduce Motion and headless

One gate, three behaviours
(`play` (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:914`)):

| | Reduce Motion | Headless |
|---|---|---|
| geometry | `instantScript` — settled look, immediately | same |
| carrier | one `CATransition` on `fieldLayer`, 0.12 s (0.15 s for the lock), only if the rung changed | nothing |
| lock cue | `onLockedSettled?()` called synchronously | same |
| breathing | off | off |
| Metal clock | display link invalidated, one still frame drawn | layer is `nil`, bitmap halos instead |
| room spill | stamped instantly, no flash | same |
| mic symbol effect | not added | not added |
| readout cross | plain string assignment | plain string assignment |

Reduce Motion **removes the travel, not the information**. The locked look
deliberately carries a larger halo than the spec's table (74 vs 40) so a user
who never sees the lock sequence still sees the bloom as a settled state
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:315`).

A live toggle of either accessibility setting goes through
`accessibilityDisplayOptionsDidChange`
(`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1701`):
cancel, restamp, apply instant geometry, reconcile breathing and the Metal
clock. Half a script is never left running over the settled model.

---

## 9. Where each number lives

| Thing | Owner |
|---|---|
| look per rung (sizes, opacities, tempos, window spans, tick steps) | `AlignmentStageView.look(for:)` |
| leg timings and curves per transition | the eight `…Script` statics, `AlignmentStageView.script(for:)` |
| lock beat times | literals inside `playLock()` |
| concentric gap factor | `fusedReferenceScale = 1.4` |
| camera scale ceiling | `seedCamera`'s `0.30…3.33` clamp |
| window quantization | `Look.windowSpanMs` + `minWindowSpanMs = 40` |
| sticky-centre dead band | `stickyMarginFraction = 0.15` |
| light scale (1.8× the spec) | folded into `look(for:)`, forces `stageHeight = 132` |
| shader constants | `SettledLightLayer` (`crestScale`, `reach`, `exposure`, `bandNarrow`) |
| spill intensity per rung | `RoomSpillView.haloOpacity(for:)` |
| readout cue time | `lockSettledAt = 1.44` |

Two of the ladder's boundaries are read from the session rather than retyped:
`fineTempoHalfWidthMs` (the number that also quickens the audible clicks) and
`proposeHalfWidthMs = 8` (the run's own stop). Neither is consulted on the auto
sync path, but both bound the rung ladder the by-ear path walks.

---

## 10. The traps, collected

1. `Screen.listening` is the mic; `State.listening` is the user. The stage
   state for the mic screen is `.measuring`.
2. A non-additive keyframe replaces the property and leaves its own value
   standing. Every transient overlapping a leg must go through `pulseDelta`.
3. `fillMode = .backwards` on a delayed leg holds it in place; on a transient
   layer added early it parks the `fromValue` on screen for the whole delay.
   Legs want it, the gather bars and bloom must not have it.
4. `CATransition` is filed under the literal key `"transition"`, whatever key
   you pass.
5. `@NSManaged` properties are not copied into the presentation layer for you —
   `LightCarrierLayer.init(layer:)` does it by hand, and `variant` would animate
   to nothing without it.
6. The camera clamp changes `sx` but not the translation term, so a seeded
   frame is only the true previous frame when the clamp is inactive. On the
   fuse it never is.
7. `armKeptReadout` must be wired before `stage.apply`, or the Reduce Motion
   and headless paths lose the kept line.
8. The readout row's height is driven off the screen, never off its string.
9. Cancelling mid-lock must still fire the settle cue.
10. Crossing `contents` during the lock is correct only when there is no Metal
    field; with the field up it paints a green blob over the light.
