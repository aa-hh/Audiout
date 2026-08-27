# Alignment-wizard estimator: is it the most effective equation?

Research brief. No production code changed. Simulation sources live in the
session scratch dir, not the repo.

**Owner's observation (live runs)**: "It takes a while to get a proposal, and
that only really seems to happen once I start saying they sound the same — I'm
mostly the one deciding it's ready."

**Short answer**: the intuition is right and the numbers back it hard. One
"Both at once" answer carries **2.2× the information** of one which-side
answer, and a run that never gets one takes **16–17 answers instead of 9–11**
and **fails to reach a proposal at all 10–14% of the time**. The estimator's
question placement is already near-optimal — that is not the problem. The
recoverable slack is in the **stop rule** and the **listener-model width**,
worth **3 answers of the 9** together.

---

## 1. What the code actually does (verified against source, not docs)

`AudiouterCore/Sources/AudiouterCore/BTAlignmentPosterior.swift`, read in full.
Every claim below is from the source.

| Claim | Verified | Where |
|---|---|---|
| Bayesian posterior over **whole-ms** offsets | yes — `belief` is one `Double` per integer ms across `range` | `init`, lines 163–200 |
| Fixed 3-way listener model, deliberately wide | yes — `c = 6`, `σ = 5`, `λ = 0.12`, mixed as `(1−λ)p + λ/3` | `judgmentProbabilities`, l. 443–451 |
| Next question minimises **expected posterior entropy** | yes — `Σ_a P(a)·H(post|a)` over 33 candidate levels drawn as `median ± candidateStepsMs` | `nextLevelMs` / `expectedEntropy`, l. 347–386 |
| Deterministic, no RNG | yes — no `random`, no clock, no queue anywhere in the file | whole file |
| Stop at 95% credible **half-width ≤ 6 ms** | yes, and it is an **equal-tailed** 2.5/97.5 quantile interval | `proposeHalfWidthMs` l. 83; `phaseAfterAnswer` l. 399; `quantileMs` l. 461 |
| "Both at once" is evidence, not a dead end | yes — its own likelihood table, folded like any other answer | `togetherLikelihoods`, `fold` |
| Flat prior always | yes — `openingProposalMs` moves the *phase*, never the belief | `init` l. 168 + comment l. 155–161 |

Two facts the AGENTS summary does not state that turn out to matter:

- The **confirm step has its own, narrower model**: `fusedHalfWindowMs = 4`,
  `fusedLapseRate = 0.05` (l. 78–79). So accepting a proposal folds in real
  evidence, and rejecting one widens the belief and returns to questions
  (`maxRejections = 2`).
- The grid width is **not fixed**. A Mac-trim run is `−500…500` (1001 points);
  a Bluetooth **latency** run is `−1500…500` (2001 points), from
  `NativeBackend.btWizardLatencyRangeMs` (`−BTSyncTrim.rangeMs …
  btWizardReferenceBufferMs − defaultBTOnlyBufferMs` = `−500…1500` in value
  space). The wider grid costs **2 extra answers** for an identical listener —
  see §3.

Doc drift found: none material. The `proposeHalfWidthMs` comment claims
"median ~13–15 answers, ~20 worst case, 97% within 4 ms of truth". My
re-simulation gets **median 9 (trim) / 11 (latency), p90 13 / 15**, and 97%
within **12 ms**, not 4 ms. The click counts are *better* than the comment
says; the accuracy claim is **optimistic by 3×** and should be corrected
whoever touches that file next.

---

## 2. Simulation setup

The estimator source file was copied verbatim into a scratch directory; the
only edits were `static let` → `static var` on the tuning constants and two
extra acquisition rules behind a flag (mode 0 is byte-identical to shipping).
It was compiled with `swiftc -O` and driven by a synthetic listener. **The
folding, the candidate search and the phase machine are the shipping code.**

**Simulated listener** — same functional form as the model, its own parameters:

```
a = θ − x                       # residual: truth minus presented level
P(target)    = Φ((a − c_L)/σ_L)
P(reference) = Φ((−a − c_L)/σ_L)
P(together)  = 1 − P(target) − P(reference)
then mixed with lapse λ_L uniformly over the available responses
```

- **True offset θ**: 0, 5, 12, 25, 60, 150, 400 ms (sign flipped on latency runs)
- **Listener fusion half-window c_L (the "JND")**: 2, 4, 8, 20 ms
- **Listener slope σ_L**: `max(1, c_L/3)`
- **Listener lapse λ_L**: 0, 5%, 10%
- **Listener kind**: *ternary* (can answer "together") vs *side-only* (never
  does — the owner's felt pattern)
- **Grid**: trim (`−500…500`) and latency (`−1500…500`)
- 40 reps per cell for the headline sweep (1 for λ=0, which is deterministic);
  25 for the variant sweeps. ~48k runs total, seeded LCG, fully reproducible.
- The **confirm-by-ear step is simulated**: at a proposal the listener judges
  fusion under its own parameters, and a rejection sends the run back exactly
  as a real user's "Still off" does. So "total clicks" includes the confirm
  clicks and any second round.

Caveat: the simulated listener shares the model's functional *form*. A real
listener whose judgment is shaped differently (asymmetric, drifting with
fatigue) is not covered. Every number below is relative-comparison-grade, not
absolute-prediction-grade.

---

## 3. Results

### 3.1 Headline — the "together" answer is the whole game

Shipping config, all cells pooled (n = 2268 runs per line):

| Grid | Listener | median answers | p90 | median total clicks | median error | p90 error | reaches a proposal |
|---|---|---|---|---|---|---|---|
| trim | **ternary** | **9** | 13 | 10 | 2 ms | 7 ms | **99.9%** |
| trim | **side-only** | **16** | 23 | 17 | 2 ms | 4 ms | **90.3%** |
| latency | **ternary** | **11** | 15 | 12 | 2 ms | 8 ms | **99.6%** |
| latency | **side-only** | **17** | 24 | 19 | 2 ms | 5 ms | **86.0%** |

A run that never hears "together" takes **~78% more answers** and bows out as
`.unsettled` 10–14% of the time instead of 0.1–0.4%. The owner is not
imagining it.

### 3.2 Why — one answer's worth, in bits

Fresh flat prior on the 1001-point trim grid (entropy 9.97 bits). One answer,
folded:

| Answer | posterior entropy after | information gained | 95% half-width after |
|---|---|---|---|
| flat prior | 9.97 bits | — | 475 ms |
| one **side** answer | 7.30 bits | **2.67 bits** | 345 ms |
| one **"together"** | 4.21 bits | **5.76 bits** | 469 ms |

**2.16× the information per click.** The mechanism is exactly the owner's
intuition: a side answer is a half-line constraint (`θ > x` or `θ < x`), so at
best it halves the space; "together" is a two-sided bracket
(`x − c < θ < x + c`), so it names an interval outright.

The half-width column shows the second half of the story and explains the
*felt* delay. After ONE "together" the credible interval has barely moved
(475 → 469 ms) even though 5.8 bits went in, because the model's 12% lapse
leaves a flat pedestal holding **74% of the mass** spread across the whole
grid. It takes three consecutive "together" answers to burn it off:

| consecutive "together" answers | half-width | mass further than 30 ms from median |
|---|---|---|
| 1 | 469 ms | 0.743 |
| 2 | 382 ms | 0.199 |
| 3 | **8 ms** | 0.017 |
| 4 | 6.5 ms | 0.001 |

That cliff at answer 3 is why the wizard feels like it does nothing and then
suddenly finishes. It is not a bug — it is the assumed lapse rate demanding
corroboration before it believes a single answer.

Forced-script traces confirm the shape (`E5` in the raw results): six
"all target" answers walk the median out to 494 ms and propose at answer 7;
alternating sides needs 11; "all together" proposes at 5.

### 3.3 Where the questions are placed — not the problem

| Acquisition rule | median answers | p90 | median error | `.unsettled` |
|---|---|---|---|---|
| **expected entropy** (shipping) | **9** | 13 | 2 ms | 3.2% |
| expected 95%-interval width | 13 | 16 | 2 ms | **28%** |
| **always ask at the posterior median** | **9** | 13 | **1 ms** | **2.0%** |

Entropy minimisation is already placing levels at `median ± 5…6 ms` — i.e.
right on the fusion boundary, where "together" is maximally elicitable. There
is no faster placement available. Note the third row: a one-line rule matches
the 33-candidate × 3-table × full-grid scan exactly. Matching the stop rule's
own metric (interval width) as the acquisition utility is **actively worse** —
it is greedy against the lapse pedestal and picks levels far out.

### 3.4 Listener-model width — what the deliberate broadness costs

Trim grid, ternary listener, n = 1400 per row. `c/σ/λ` are the **model's**
assumed values; the listener's own stay swept as above.

| Model | median answers | p90 | median clicks | p90 error (accepted) | P(error > 10 ms) | `.unsettled` |
|---|---|---|---|---|---|---|
| **6 / 5 / 0.12 (shipping)** | 9 | 13 | 10 | 7 ms | 5.1% | 2.7% |
| 4 / 5 / 0.12 | 9 | 12 | 10 | 8 ms | 5.7% | 1.8% |
| 6 / 3 / 0.12 | 8 | 12 | 9 | 6 ms | 5.6% | **6.2%** |
| 6 / 5 / 0.06 | 9 | 12 | 10 | 6 ms | **3.4%** | 5.7% |
| **4 / 5 / 0.06** | **7** | 11 | 9 | **5 ms** | **3.7%** | **2.0%** |
| 4 / 3 / 0.06 | 6 | 10 | 7 | 6 ms | 4.8% | 3.7% |
| 3 / 2 / 0.03 | 6 | 9 | 7 | 7 ms | — | 2.8% |

Same variants on the **latency** grid (the wide one), where the broadness
earns its keep:

| Model | median answers | p90 error (accepted) | P(error > 10 ms) |
|---|---|---|---|
| **6 / 5 / 0.12 (shipping)** | 11 | 8 ms | **6.3%** |
| 4 / 5 / 0.12 | 10 | 8 ms | 6.3% |
| 4 / 5 / 0.06 | 10 | 8 ms | 8.6% |
| 4 / 3 / 0.06 | 10 | 11 ms | 10.7% |

**The trade, quantified**: on the 1001-point trim grid the shipping width costs
**2 answers for nothing** — `4/5/0.06` is strictly better on every axis
(fewer answers, tighter p90 error, fewer bad results, fewer bow-outs). On the
2001-point latency grid the same change saves 1 answer and raises bad results
from 6.3% to 8.6%. Narrowing the **slope** (σ 5→3) is the risky component: it
raises `.unsettled` from 2.7% to 6.2%. Narrowing the **fusion window** alone
(c 6→4) is free everywhere.

### 3.5 Stop rule — the cheapest 3 answers on the table

Clicks to first reach a given 95% half-width, with the bow-outs disabled so
the measurement is pure (n = 2240):

| Stop at half-width ≤ | median clicks | p90 clicks | median error | p90 error | p97 error |
|---|---|---|---|---|---|
| 4 ms | 15 | 19 | 1 ms | 6 ms | 11 ms |
| **6 ms (shipping)** | **9** | 13 | 2 ms | 7 ms | 12 ms |
| 8 ms | 7 | 11 | 1 ms | 8 ms | 12 ms |
| 10 ms | 6 | 11 | 2 ms | 8 ms | 12 ms |
| 12 ms | 6 | 10 | 2 ms | 9 ms | 12 ms |
| 20 ms | 6 | 9 | 2 ms | 10 ms | 12 ms |
| 30 ms | 6 | 9 | 2 ms | 10 ms | 15 ms |

Two things fall out. **Tightening** is brutally expensive: 6 → 4 ms costs 6
extra answers, +67%. **Loosening** hits a floor at ~6 answers around 10–12 ms
— past that the run cannot go faster no matter how loose the rule, because it
still needs the three corroborating answers of §3.2. And p97 error is *flat at
12 ms* from 6 ms all the way out to 20 ms: the tail is set by the listener's
own resolution, not by the stop rule.

End-to-end (confirm loop included), n = 1400 per row:

| Variant | trim: answers / clicks / P(err>10) | latency: answers / clicks / P(err>10) |
|---|---|---|
| **shipping** | 9 / 10 / 5.1% | 11 / 12 / 6.3% |
| stop 8 ms | 7 / 8 / 6.0% | 9 / 10 / 8.5% |
| stop 12 ms | 6 / 7 / 6.1% | 8 / 9 / 9.0% |
| stop 12 ms + 3 rejections | 6 / 7 / 5.9% | 8 / 9 / 9.0% |
| stop 10 ms + 4 rejections | 6 / 8 / 6.2% | 8 / 9 / 8.5% |
| **model 4/5/0.06 + stop 8 + 3 rejections** | **6 / 8 / 4.3%** | **9 / 10 / 8.3%** |

Raising `maxRejections` from 2 to 3 is free: it costs no accuracy and halves
the `.unsettled` rate (5.6% → 2.9% at stop 12).

### 3.6 Things that turned out NOT to be the problem

- **Highest-density interval instead of equal-tailed.** I expected the lapse
  pedestal to be inflating the 2.5/97.5 quantile interval at the endgame. It
  is not: at the moment the run proposes, the mass beyond ±30 ms of the median
  is **0.0001**, and the HDI half-width is 5.5 ms against the equal-tailed 6.0
  (mean ratio 1.05). Zero answers saved. The pedestal only matters for the
  first two or three answers, where the interval is huge anyway. **Rejected.**
- **Entropy is the wrong utility.** Also no — see §3.3, the alternative is worse.
- **The estimator is slow near zero.** The opposite: θ = 0 converges in 5
  answers, the slowest true offsets are 25–60 ms (11 and 10).

---

## 4. Literature (2026 scan)

Delegated scan; every citation below was located by that scan, with its own
confidence flags preserved.

**Ternary responses are the right call, and it is a published result.**
García-Pérez & Alcalá-Quintana (2017), *Frontiers in Psychology* 8:1142,
DOI 10.3389/fpsyg.2017.01142 — comparing response formats at matched trial
counts, they state directly that estimates from 2AFC data are less accurate
than estimates from ternary data, and call ternary the most efficient way to
collect psychophysical data. That is §3.1's finding, independently. The
foundational model is García-Pérez & Alcalá-Quintana (2012), *Frontiers in
Psychology* 3:94 — response errors, not a broken sensory model, explain
non-monotonic ternary psychometric functions. The modern parameterisation
(Kelber & Ulrich 2024, *Atten Percept Psychophys*,
https://pmc.ncbi.nlm.nih.gov/articles/PMC11410913/) uses μ∆L, σ∆L, a criterion
**c** — the direct analogue of `fusionHalfWindowMs` — plus ε/κ response-error
terms. The file's naming maps onto the field's cleanly.

**The flat prior is correct and the citation in the source is real.**
Alcalá-Quintana & García-Pérez (2004), *Psychological Methods* 9(2):250–271
(https://pubmed.ncbi.nlm.nih.gov/15137892/): uniform priors outperformed
narrower alternatives; unbiased by trial 10; standard error stabilised by
trial 20, scaling ≈ 0.617/√N. **Do not seed a narrow prior.** Hierarchical /
population priors (Mezzetti et al. 2023, *Front. Comput. Neurosci.* 17:1108311)
address pooling *across participants*, which is a different problem from a
single-session single-listener estimate, and I found nothing testing them
against a flat prior in an adaptive TOJ context. Not a defensible route here.

**~9–20 answers is not, by the field's standards, slow.** Kontsevich & Tyler
(1999), *Vision Research* 39(16):2729–2737 — the psi method this file is
descended from — needs **under 30 trials** for a threshold and ~300 for a
slope. Chopin et al. (2026), *Frontiers in Neuroscience*
(doi 10.3389/fnins.2026.1760278) — the most current comparative study — reports
unbiased estimates from ~30 trials and finds psi-marginal at 60 trials matches
plain psi at 120. AEPsych's own 1-D demo (Owen et al. 2021, arXiv:2104.09549)
converges in ~20 trials. **The wizard at a median of 9 is already faster than
the published baselines**, because it estimates one parameter with a
three-way response instead of a two-parameter psychometric function.

**Lapse handling.** Wichmann & Hill (2001), *Percept Psychophys* 63(8):
fixing lapse at 0 biases threshold and slope. Prins (2012), *JOV* 12(6):25:
freeing it does not fully fix the bias either. Prins (2013), *JOV* 13(7):3
(psi-marginal): **marginalise** nuisance parameters rather than fix or estimate
them. That is the one methodologically superior alternative to this file's
fixed `c/σ/λ` — but it costs trials rather than saving them, so it is the wrong
lever for this complaint. Noted and rejected on those grounds.

**Nothing newer helps.** Gaussian-process adaptive psychophysics (AEPsych),
Deep Adaptive Design (Foster et al. 2021, arXiv:2103.02438) and RL-BOED (Blau
et al. 2022, ICML) all target either **multi-dimensional** stimulus spaces or
**amortising computation** across thousands of runs. For one scalar parameter
over 33 candidate levels with a grid posterior, exhaustive expected-entropy
search is already near-optimal and cheap. §3.3's result — that a one-line
"ask at the median" ties the full search — is the empirical confirmation.
**No 2020+ method would buy clicks here.**

**Not found**: any psychophysics-specific paper quantifying trial savings from
decision-theoretic stopping versus fixed credible-interval-width stopping.
§3.5's numbers are the only evidence available on that question and they are
mine, not the literature's.

---

## 5. Diagnosis

Of the four hypotheses:

**(a) Inherent to side-only evidence — CONFIRMED, and dominant.** A which-side
answer is a one-sided constraint worth 2.67 bits; "together" is a two-sided
bracket worth 5.76. A run that never gets one takes 16 answers instead of 9
and fails outright 10% of the time. Nothing in the equation can fix this — it
is the geometry of the question. What *can* be fixed is how easily a real user
reaches the "Both at once" button, and how early the levels get close enough
for it to be a truthful answer. The estimator already places levels at
`median ± 5 ms`, so the placement is right; the constraint is that the median
has to travel there first, which takes 3–5 side answers from a flat prior.

**(b) Likelihood-model width — REAL, worth 2 answers, and free on the trim
grid.** Shipping `6/5/0.12` versus `4/5/0.06`: 9 answers → 7, p90 error 7 ms →
5 ms, bad results 5.1% → 3.7%, bow-outs 2.7% → 2.0%. Strictly better on the
Mac-trim run. On the wide latency grid the same change is 11 → 10 answers and
bad results 6.3% → 8.6%, so the breadth is buying something there. The slope
(σ) is the component that must not move: dropping it 5 → 3 doubles the
`.unsettled` rate.

**(c) Question placement — NOT the problem, but the search is dead weight.**
Expected-entropy minimisation ties a one-line "ask at the posterior median" on
clicks and loses slightly on accuracy and bow-out rate. Matching the utility to
the stop rule (expected interval width) is worse. There are no clicks here —
only ~40 lines and a per-question full-grid scan that could go.

**(d) Stopping rule — REAL, worth 3 answers, with an honest accuracy cost.**
6 ms → 12 ms takes the median from 9 answers to 6 and total clicks from 10 to
7. The p97 error is unchanged (12 ms) across that whole range; the p90 error
goes 7 ms → 9 ms and the share of results more than 10 ms off goes 5.1% → 6.1%
(trim) or 6.3% → 9.0% (latency). Since the proposal **is confirmed by ear
before anything is persisted**, and a rejection folds in real evidence rather
than discarding the run, a looser stop is a defensible trade — but it is a
trade, not a free win, and the latency run pays more for it.

**One more finding worth acting on**: the latency run's grid is twice as wide
as the trim run's (2001 vs 1001 ms) and costs **2 extra answers** for an
identical listener. The ceiling comes from `btWizardReferenceBufferMs` (2000)
minus `defaultBTOnlyBufferMs` (500). Real Bluetooth latencies are 150–700 ms;
the run spends two clicks ruling out a kilosecond of range nothing will ever
occupy. Narrowing the *range* is not the same as seeding a narrow *prior* — the
prior stays flat over whatever range is presented — but it is the same failure
mode if the range excludes the truth, so it needs the same care.

---

## 6. Recommendations, ranked

All respect the hard rules: deterministic, no RNG, honest interval, no seeded
prior.

### R1 — Loosen the stop rule to 8–10 ms and raise `maxRejections` to 3
**Expected saving: 2–3 answers (9 → 6–7 median trim; 11 → 8–9 latency), ~3
total clicks.**
**Risk**: results more than 10 ms off go from 5.1% to ~6% (trim) / 6.3% to
~8.5% (latency). The p97 error does not move at all. The confirm-by-ear step
is the backstop and the rejection path already folds in evidence; raising
`maxRejections` 2 → 3 costs nothing measurable and *halves* the `.unsettled`
rate (5.6% → 2.9%), which is what pays for the looser threshold.
**Size**: two constants (`proposeHalfWidthMs`, `maxRejections`) plus their
comments and the tests that assert on them. `BTAlignmentWizardSession`
forwards `proposeHalfWidthMs` already, so the wizard stage's threshold rung
follows for free. Under 20 lines.
**Caveat**: the interval reported to the user widens with it. That is honest —
the run really is less sure — but the stage's confidence line will read wider,
and that is a design call, not a maths one.

### R2 — Narrow the model's fusion window and lapse to `c = 4`, `λ = 0.06`; leave `σ = 5` alone
**Expected saving: 2 answers on the trim grid (9 → 7), 1 on latency.**
**Risk**: on the trim grid, none — it is strictly better on every measured
axis (p90 error 7 → 5 ms, bad results 5.1% → 3.7%, bow-outs 2.7% → 2.0%). On
the latency grid it costs accuracy (bad results 6.3% → 8.6%) for one answer,
so it may be worth applying **only to the non-inverted (trim) run**, which the
session already distinguishes via `invertsEstimate`.
**Risk of getting it wrong**: `σ` must not move. Dropping it to 3 doubles the
`.unsettled` rate. And the file's own citation (Alcalá-Quintana &
García-Pérez 2004) is about *priors*, not the likelihood — the "over-broad is
safer" claim for the likelihood is Wichmann & Hill's lapse argument, which
0.06 still satisfies (non-zero, and above any lapse rate I simulated).
**Size**: two constants and their justification comment. Under 10 lines.
**Do not** combine R1 and R2 at their most aggressive on the latency run: the
combination lands at 8.3% bad results there.

### R3 — Ask the user for "Both at once" more directly, and earlier
Not simulatable, and therefore the recommendation I am least able to price —
but §3.1 says it is worth **7 answers**, more than R1 and R2 combined. The
estimator already does its half: levels sit at `median ± 5 ms` once the median
is close. The gap is on the human side. Candidates, in order of how cheap they
are: (i) check that "Both at once" is not visually subordinate to the two
side buttons in the wizard stage — a user who reads it as "I give up" will not
press it; (ii) once the credible half-width is inside ~20 ms, the copy could
say so ("these should be close now — do they land as one?") since that is
exactly when the answer becomes truthful and worth 5.8 bits; (iii) the tempo
already closes up at 250 ms half-width (`fineTempoHalfWidthMs`) — a second
step much later, near fusion, would make "together" audibly easier to judge.
**Size**: copy and layout in `BTAlignmentWizardView.swift`; no estimator
change. **Risk**: pushing users toward "together" when it is not true biases
the result — the wording has to invite it, not lead it.

### R4 — Delete the 33-candidate entropy search; ask at the posterior median
**Expected saving: zero clicks.** It ties the full search (9 answers both
ways) and is *slightly* better on accuracy (median error 1 vs 2 ms) and
bow-out rate (2.0% vs 3.2%).
**What it buys**: ~40 lines gone, `candidateStepsMs` gone, and the
per-question `O(33 × 3 × gridPoints)` scan gone — which on the 2001-point
latency grid is ~200k multiplies per question, on the main thread, between a
click and the next level being applied.
**Risk**: it removes the file's headline claim to being a psi-method
descendant, and the tie is measured only against *this* listener model. If the
listener model ever changes, the tie may not hold. **Do this only if the
simplification is wanted for its own sake** — and if so, keep the entropy
function in a test so the tie is asserted rather than assumed.

### Rejected
- **HDI instead of equal-tailed interval** — measured, saves nothing (§3.6).
- **Acquisition on expected interval width** — measured, actively worse (§3.3).
- **Marginalising `c/σ/λ` (psi-marginal, Prins 2013)** — methodologically
  superior, but it spends trials to buy robustness. Wrong direction for this
  complaint.
- **GP active learning / DAD / RL-BOED** — built for multi-dimensional stimulus
  spaces or amortised compute. No benefit for one scalar parameter.
- **Any seeded or narrowed prior** — Alcalá-Quintana & García-Pérez (2004) and
  the file's own comment both stand.

---

## 7. Loose end for whoever owns the file next

`proposeHalfWidthMs`'s comment claims "median ~13–15 answers, ~20 worst case,
97% within 4 ms of truth". Measured: median 9 / p90 13 (trim), median 11 /
p90 15 (latency), and 97% within **12 ms**. The click figures are better than
advertised; the accuracy figure is 3× optimistic. Fix the comment whether or
not any recommendation here is taken.
