# Two-tone distinguishability — Sync Green vs Party Magenta

**Question (Alec):** are `syncSignal` `#2BFF8F` (target, left) and `partySignal`
`#FF90E9` (reference, right) the scientifically best pair for this job, and is
there anything cheap to do that makes them easier to tell apart?

**Bottom line: keep the pair as shipped. No colour or shape change is
justified.** The two numbers that matter: CIEDE2000 distance ≈ **86** (a
"just noticeable difference" is ~1–2 — this pair is ~40–80× that), and the
pair survives all three color-vision-deficiency types in simulation because
it differs on **two** cone axes at once, not one.

## Measurements (dark stage plate `#100B07`, full-alpha instrument values)

Converted sRGB → linear → CIELAB (D65):

| | Hex | L* | a* | b* | Contrast vs plate |
|---|---|---|---|---|---|
| `syncSignal` (target) | `#2BFF8F` | 88.9 | −72.3 (green) | +40.0 | 14.7:1 |
| `partySignal` (reference) | `#FF90E9` | 74.3 | +53.7 (red/magenta) | −26.9 | 9.7:1 |

- **ΔE76 (Euclidean Lab distance):** 143.4 — dominated by Δa* (−126), i.e. the
  red‑green axis.
- **ΔE2000 (perceptual, chroma-corrected):** ≈ **86**. Hue term alone
  (ΔH′≈141) accounts for ~98% of the squared distance; the lightness term is
  small (ΔL′=−14.7) and the chroma term smaller still (ΔC′=−22.6).
- **Mutual luminance contrast (the two colors against each other, WCAG
  formula):** only **1.5:1**. Both are near the top of the plate's dynamic
  range (14.7:1 and 9.7:1 individually), so as a *pair* they're nearly
  equally bright.

**Verdict on separation:** the pair's distance is carried almost entirely by
**hue**, not luminance. WCAG's own "color alone" exception requires a ≥3:1
lightness difference between the two colors to count their distinction as
non-color-dependent ([1.4.1 Use of Color](https://www.digitala11y.com/understanding-sc-1-4-1-use-of-color/)) — this pair is well under that (1.5:1). On its
own, this pair would be a textbook fragile hue-only encoding. It isn't fragile
in practice only because of the non-color redundancy already built into the
wizard (position, name stamps, keycaps, device names on the plates) — that
redundancy is doing real, necessary work, not decoration.

## Color-vision-deficiency verdicts

Simulated with the Machado/Oliveira/Fernandes (2009) physiologically-based
CVD matrices ([IEEE TVCG](https://www.inf.ufrgs.br/~oliveira/pubs_files/CVD_Simulation/CVD_Simulation.html)), applied to linear-light RGB, both colors at 100% severity:

| CVD type | ~prevalence | `syncSignal` renders as | `partySignal` renders as | Verdict |
|---|---|---|---|---|
| Protanopia | 1.0% of men | pale gold `≈(255,233,135)` | periwinkle blue `≈(144,172,236)` | **Survives** — reads as yellow vs blue |
| Deuteranopia | 1.3% of men | tan/khaki `≈(232,217,151)` | light blue `≈(174,189,230)` | **Survives** — same yellow/blue split, slightly softer |
| Tritanopia | <0.01%, both sexes | bright cyan-green `≈(0,252,228)` | warm pink/salmon `≈(255,149,178)` | **Survives easily** — barely perturbed, this axis isn't where the pair's information lives |

Why it survives: protanopia and deuteranopia collapse the **L–M (red-green)
cone** axis, but `syncSignal` and `partySignal` also differ hard on the
**S-cone (blue)** axis (linear blue channel 0.27 vs 0.81) — that secondary
axis carries the distinction through as a yellow-ish vs blue-ish split. A
"pure" red-vs-green pair (equal blue channel) would have collapsed to near-
identical gray under protan/deutan; this pair, being spring-green and
magenta-pink rather than red and green, does not. ~8% of men (1 in 12) have
some red-green deficiency ([colorblind.io](https://colorblind.io/learn/statistics)); this pair was — likely
unintentionally, given it's the marketing brand pair, not a chosen a11y pair
— a reasonably good draw for that population.

## Best-practice context

- **Okabe-Ito** ([2002 CUD palette](https://www.reed.edu/economics/parker/311/Creating-Color-Blind-Accessible-Figures-ProfHacker---Blogs---The-Chronicle-of-Higher-Education.pdf)), the standard colorblind-safe categorical
  palette, is built from CVD-simulator-verified hues but explicitly still
  pairs color with label/shape/pattern — hue alone is never treated as
  sufficient, regardless of how well it survives simulation.
- Dataviz literature: hue is the primary categorical channel, but "lightness
  and saturation also contribute to people's ability to distinguish"
  categories, and **redundant encoding (shape, position) gives the largest
  accuracy gains** ([CatPAW](https://arxiv.org/html/2602.06792), [Accessible Color Sequences](https://arxiv.org/pdf/2107.02270)) — which is exactly the pattern
  this wizard already follows (fixed left/right, names, keycaps).
- JND for CIEDE2000 is ~1–2; values above 5 are "clearly visible" ([MetricGate](https://metricgate.com/docs/delta-e-ciede2000/)). At 86, this pair is not in a regime where perceptual
  science has anything more to add — it's an extreme-contrast pair by
  construction (it's a brand pair chosen for punch, not a muted categorical
  set).

## Options, costed

| Option | What | Cost | Verdict |
|---|---|---|---|
| **(a) Keep as-is** | Ship the current pair, current redundancy | None | **Recommended.** ΔE2000 ≈86, survives all 3 CVD types, WCAG 1.4.1 already satisfied via non-color cues (position/names/keycaps) independent of the hue pair |
| (b) Tune luminance/chroma | Nudge one or both L* to push mutual contrast toward 3:1, same hue family | Touches the two "instrument, fixed both appearances" tokens (§2.1) — needs the same Alec sign-off as any wizard-color change, plus a re-run of `AlignmentTokenContrastTests`. Small brand risk (these are the marketing site's literal secondary hexes) | Not justified — the gap it closes (1.5:1→3:1 luminance-only contrast) is already covered by the existing non-color redundancy; nothing in the CVD sim or the ΔE number is actually failing |
| (c) Add a per-light shape/stroke cue | Distinct dash pattern or ring style for target vs reference | Real engineering cost — the rings are now `CADisplayLink`-driven living rings with wobble/squash/breathing (bullet 44); a shape cue has to survive that motion and be re-verified across all 8 rungs' radii/line-widths, and against Reduce Motion's pinned-phase path | Not justified — position (always left/right) already *is* the non-hue geometric cue the WCAG exception is asking for; a second one is redundant-on-redundant |
| (d) Swap a hue | Replace green or magenta with a different identity color | Brand cost — these are the marketing site's sanctioned secondaries (owner rule, 2026-08-23) | **Flagging only, not recommending.** No measurement here calls for it; raise with Alec only if he wants a design reason unrelated to distinguishability |

## Recommendation

**Ship the pair unchanged.** The color science says this is not a fragile
pair — CIEDE2000 ≈86 (vs a ~1–2 JND) and it degrades gracefully under
protanopia, deuteranopia, and tritanopia alike because the hues differ on two
cone axes, not one. The one number that looks weak in isolation — 1.5:1
mutual luminance contrast, under WCAG's 3:1 "lightness alone" bar — doesn't
matter here because the wizard was already built with independent non-color
redundancy (fixed left/right position, name stamps under the lights, device
names on the plates, ←/→ keycaps), which is what WCAG 1.4.1 actually asks
for. Spending brand risk (d) or engineering effort (c) buys nothing measurable;
a luminance nudge (b) closes a number that isn't the bottleneck. No action
needed.

## Sources

- [Okabe-Ito / Color Universal Design](https://www.reed.edu/economics/parker/311/Creating-Color-Blind-Accessible-Figures-ProfHacker---Blogs---The-Chronicle-of-Higher-Education.pdf)
- [Machado, Oliveira & Fernandes 2009, "A Physiologically-Based Model for Simulation of Color Vision Deficiency," IEEE TVCG 15(6)](https://www.inf.ufrgs.br/~oliveira/pubs_files/CVD_Simulation/CVD_Simulation.html)
- [WCAG 2 SC 1.4.1 Use of Color — the ≥3:1 lightness exception](https://www.digitala11y.com/understanding-sc-1-4-1-use-of-color/)
- [CIEDE2000 JND / practical thresholds](https://metricgate.com/docs/delta-e-ciede2000/)
- [Color blindness prevalence statistics](https://colorblind.io/learn/statistics)
- [CatPAW — redundant color+shape categorical encoding](https://arxiv.org/html/2602.06792)
- [Accessible Color Sequences for Data Visualization](https://arxiv.org/pdf/2107.02270)

## Method note

Lab/ΔE figures were computed by hand (sRGB→linear→XYZ→Lab, D65, full
CIEDE2000) rather than pulled from a tool; the WCAG contrast ratios
cross-check against the spec's own stated figures (`~14:1`/`~9:1` on the
plate, §2.1) within rounding, which is the sanity check for the rest of the
arithmetic. CVD RGB outputs are from the published Machado/Oliveira/Fernandes
100%-severity matrices applied to this repo's exact linearized hex values,
not run through an interactive simulator — treat the simulated hex triplets
as approximate, the pass/fail read (still two clearly different colors, still
split on the yellow/blue axis) as the reliable part.
