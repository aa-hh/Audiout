# Roadmap 056 — session handoff, 2026-08-22 evening

Written because two background agents died mid-task when the session hit its
API limit, and the session that was driving them (this one) has no
successor with access to the conversation. Read this before doing anything
else on 056.

## Where the tree stands right now

Worktree: `.claude/worktrees/foreman-roadmap-c1a0f5`, branch
`claude/foreman-roadmap-c1a0f5`, HEAD `7968ee29` (the spec + roadmap-entry
commit — everything since is **uncommitted**, 39 files, nothing pushed
beyond `7968ee29`). **Nobody has committed anything today past that one
commit.** Do not commit without the user's explicit go-ahead per this
project's standing rule.

**Full suite is green right now**, verified this session after fixing one
leftover compile error (below): `bash scripts/run-tests.sh` →
**2477 tests / 142 suites passed**. `bash scripts/build.sh` → clean.

The one thing fixed in this documentation pass: a failed agent left
`AudioutCore/Tests/AudioutCoreTests/AlignmentTickInjectorTests.swift`
with a `#expect(..., "a" + "b")` — Swift Testing's macro can't parse a
string built with `+` as its `Comment` argument. Changed to one string
literal. That was the ONLY thing broken; once fixed, everything the two
failed agents had already written compiled and passed. Do not assume other
silent damage — the full suite result above is the proof, not a guess.

## The arc that got here (context for anyone re-deriving intent)

This is one long live-testing session on the "per-device delay trim"
feature (spec: `dev/notes/per-device-trim-spec.md` — Parts 1–3, still the
design rationale for the SYNC-stepper/Mac-row/anchor-carry/drift-corrector
work, all of which is DONE and tested). Roadmap entry **056** is that
feature; it is still marked `planned` in `ROADMAP.jsonl` because no spawned
session ever ran the `update-status in_progress` step — this handoff marks
it `in_progress` (see bottom).

Sequence of live-test rounds, each triggering an investigate → fix →
verify cycle (all via background `Agent` executors, Opus, full suite green
after each):

1. **Software build of 056** (Parts 1–3): Mac row SYNC stepper, wizard
   rebuilt on "method of constant stimuli" (a fixed engine, NOT the
   Bayesian one below), BT anchor-carry across lineup changes,
   `BTDriftCorrector` deleted (measured inert). Reviewed twice by a Fable
   reviewer; several real defects found and fixed (anchor-carry lost on
   back-to-back rebuilds, telemetry on the RT thread, a flaky pacer test).
2. **First live test** (v1–v3 builds): found the Settings-app aggregate
   "stale twin" trap (unrelated — a leftover `Audiout EQ v2` public
   aggregate blocked routing; documented, not a code bug), the drawer
   stepper not applying live except via typed+Enter (fixed —
   `SyncValueFieldEditor.overrideEditedValue`), the wizard not working with
   music paused (fixed — the wizard now drives its own paced tick feed via
   `NativeCaptureCoordinator`'s pacer), and several wizard timing bugs (a
   BT sink that started its engine late could permanently mis-schedule —
   fixed with a release-catch-up in `BTSyncedSink`).
3. **Second live test** (v4): the wizard used every OTHER Bluetooth speaker
   as a "decoy" (unmuted, ticking at its own stale trim) which made the
   user judge the wrong pair; fixed with a participant-hold (mute
   non-target/non-reference BT sinks for the run's duration). Also fixed a
   dead-end where a fresh speaker's first two answers could seek its ring
   completely dry (permanent silence, no telemetry) — added range
   clamping + a seek-safety-margin + per-trial telemetry
   (`wizard_latency_preview`).
4. **Keep bug** (v5): pressing Keep after a successful run silently did
   NOT update the visible SYNC value. Root cause: the SYNC drawer, if left
   open under the row during the run, kept displaying the pre-run trim and
   wrote it back over Keep's zero a few seconds later. Fixed
   (`BTSyncDrawerView.noteExternalTrimChange`) — Keep now pushes its
   committed value into an open drawer instead of leaving it stale.
5. **Static + mid-run silence** (this round, v5 still): the owner reported
   "static gets louder as the test goes on" and "the Bluetooth speaker
   just stopped in the middle." Root cause was the wizard's Sonos
   keep-alive noise bed (−47 dBFS broadband noise, mixed in to stop the
   Sonos Move's amp from power-gating between ticks) — **this is now
   FIXED and verified** (see next section). The mid-run silence report
   turned out to be explained by the same root cause investigation; no
   separate defect was found once the bed was fixed (see caveat below).

Alongside all this, the owner asked a design question ("why does the
speaker sound like it's ahead when physics says it must be behind?") that
turned into a whole live-instrumented investigation (tick aliasing at a
fixed 833 ms period — the phenomenon is real and explained, not a bug) and
then a request for "something intelligent" instead of ~30 raw clicks. That
spawned three parallel research briefs (estimator, priors, UX — all
delivered, summarized below) and a **not-yet-scoped, not-yet-built**
redesign of the wizard's estimator. That is the actual remaining work.

## DONE and verified this session — the keep-alive fix (H1/H2 from the last live report)

Files touched (all already in the 39-file uncommitted set, verify with
`git diff` if unsure what's new): `AlignmentTickInjector.swift`,
`BTSyncedSink.swift`, plus their test files.

**Root cause of the growing static**: nothing accumulated across the run
in the way first suspected — a `theKeepAliveLevelNeverGrowsAcrossALongRun`
regression test drives 2000 consecutive pacer blocks (≈23 s, crossing the
search→blocks tempo change) and asserts the non-tick blocks are bit-exact
across the whole run. It passes. Read the test and its doc comment in
`AlignmentTickInjectorTests.swift` before re-investigating — it already
proves the *old* noise-bed implementation was NOT growing, so if static
recurs after the fix below, look elsewhere (most likely: the actual A2DP
codec/link doing something under sustained broadband noise, which is a
hardware fact the fix below sidesteps rather than explains).

**The actual fix, shipped**: replaced the audible broadband noise
keep-alive with an **inaudible ~20 Hz sine tone** at −40 dBFS
(`AlignmentTickInjector.Config.keepAliveKind`, default `.lowTone`; the old
`.noise` bed is kept as a one-line fallback — flip the enum back if the
20 Hz tone proves not to hold a real Sonos Move's amp gate open). This is
**UNVALIDATED ON HARDWARE** — say so explicitly if reporting this as fixed
to the user. It is validated only by unit tests:
`theKeepAliveIsALowToneAndNothingElse`,
`theKeepAliveHasNoDiscontinuityAtBlockBoundaries` (phase-continuous across
pacer block boundaries, so no clicking), `theKeepAliveNeverMovesTheTickOnset`
(tick timing is unaffected by the tone swap),
`theManualMetronomeCarriesTheSameKeepAlive` (`.manual` mode — the row's
plain metronome button — gets the same tone).

Also added: `bt_sink_ring_drops` telemetry now fires at **session end**
too (`ringDropsAreAlsoReportedWhenTheSessionEnds`), not only at gate
opening — previously a whole wizard run's drop count was silently
unreported because a run has exactly one gate-opening event, at the start.

**Open question for the next live test**: does the 20 Hz tone actually
keep a real Sonos Move's amp awake between the 3 s coarse-phase ticks? If
the speaker goes silent again in the same way, the fastest diagnostic is
`Config.keepAliveKind = .noise` (revert one line) to check whether the
issue is "wrong keep-alive" vs. something else in the pacer/fan-out path.
No code currently proves the 20 Hz choice works on hardware — it is an
engineering bet based on "a small woofer can't reproduce 20 Hz, but a
digital silence-gate still sees non-zero samples."

## NOT DONE — the Bayesian wizard redesign (the big remaining piece)

**Nothing has been built for this yet.** The `fable-scoper` agent that was
supposed to produce a work order for it died before writing anything (its
last logged action was "I'll start by reading the required docs and the
current code" — zero work product, nothing to salvage). Whoever picks this
up needs to **re-run the scoping step from scratch**, using the design
below (already fully locked with the owner across three research briefs —
do not re-litigate the numbers, they are backed by a real simulation, not
guesses).

### Why: the current wizard costs too many answers

Live-measured this session: a real run took ~30 answers and the (old)
progress bar sat at ~40% when the run actually finished — the bar's
denominator was structurally wrong for a variable-length estimator. The
owner does not want a fixed-step algorithm; they want something that
"understands" answers and proposes a value early, which the user then
confirms or rejects.

### What it is: Bayesian adaptive estimation, NOT machine learning

Explicitly told to the owner and accepted: no training data, no model
file — this is the same ~40-year-old technique hearing/vision tests use
(QUEST, the "psi method"). A probability curve over "what the true offset
is," updated by each answer's likelihood, with the next click chosen to
be maximally informative. Full citation list is in the research brief
(below); the key one motivating why this replaces the *current* method-of-
constant-stimuli design specifically: García-Pérez 2014 (*Atten Percept
Psychophys* 76:621) — classic monotonic-staircase methods choke on a
non-monotonic "sounds together" answer, which is exactly why the current
code uses constant stimuli instead of a staircase. **A Bayesian posterior
does not have that limitation** — it just multiplies likelihoods, so
"sounds together" becomes informative evidence instead of a dead end, and
the constraint that justified the current design's complexity goes away.

### The locked design (from the estimator research brief — simulation-backed)

**Belief**: `[Double]` over whole-ms offsets across the caller's usable
range (today roughly −500…+1500 relative to a device's reference — size
the grid from the range actually passed in, not a hardcoded constant).
Flat prior.

**Listener model** (fixed constants, deliberately WIDER than the owner's
measured values — this is the published-robust choice, see
Alcalá-Quintana & García-Pérez 2004, *Psych Methods* 9:250 — an
over-broad model is unbiased within ~10 trials; an under-broad one is
not):
- fusion half-window `c = 6 ms`
- slope `σ = 5 ms`
- lapse rate `λ = 0.12` (must be non-zero — Wichmann & Hill 2001 showed
  fixing λ=0 biases the result once real lapses exceed ~2%, and *more*
  trials makes the bias worse, not better)

**Residual** `a = θ − x` for a presented level `x`. Likelihoods (Φ =
standard normal CDF, precompute into a lookup table indexed by whole-ms
residual — Foundation has `erf`, no dependency needed):
- P(target first) = Φ((a−c)/σ)
- P(reference first) = Φ((−a−c)/σ)
- P(together) = 1 − both
- each mixed with the lapse: `p ← (1−λ)·p + λ/3`

**Update**: multiply the belief by the answer's likelihood, renormalize.

**Next stimulus**: minimum-expected-posterior-entropy over ~34 candidate
levels at `median ± {0,2,4,6,8,11,15,20,28,40,60,90,140,220,350,550,900}`
ms, clamped to the usable range.

**Stop rule — the owner's explicit answer to "where should it stop"**:
*"propose as soon as its confidence is high"* — i.e. driven by the
posterior's own credible-interval width, not a fixed answer count. The
simulation's recommended threshold is a **95% credible-interval half-width
≤ 6 ms** (median ~13–15 answers, ~20 worst case, 97% land within 4 ms of
truth on the owner's measured listener profile — the simulation table for
±3/±4/±5/±6/±8/±12/±20 ms thresholds is in the brief text quoted below if
a different trade-off is wanted later; 6 ms was the one recommended and
not overridden). **Do not hardcode a fixed answer count anywhere** — the
whole point is that it varies with how clear the listener's answers are.

**Confirm step** (the owner's "user accepts or rejects" requirement): at
the stop point, present the proposed value and ask "Does this sound
right?" — Yes multiplies the belief by
`Φ((4−a)/σ) − Φ((−4−a)/σ)` (fused-within-4ms likelihood, 5% lapse-mixed)
and converges; No multiplies by the complement, widens the belief, and
resumes questions. Two rejections → bow out.

**`.unreachable` redefinition**: ≥20% of posterior mass sits in the
outermost 20 ms of the range after ≥8 answers (today's bisection-style
"clamped twice" definition no longer applies to a posterior).

**New bow-out case, `.unsettled(bestGuessMs:)`**: credible half-width
hasn't shrunk ≥20% over the last 8 answers, or ≥40 answers total. Offers
"Set it by hand" → opens that row's SYNC drawer with the best guess
prefilled (reuse the existing `toggleSyncDrawer` path).

**Zero-click path** (small, worth including): if
`NativeBackend.btMeasuredLatencyMs(forDevice:)` already has a stored value
for this device, open directly on the PROPOSAL screen at that value
("Still sounds right?") instead of starting from a flat prior. "Not quite"
falls through to the normal flat-prior flow. Do NOT seed a narrow Gaussian
prior from the stored value instead — flat + over-broad likelihood is the
robust choice per the citation above; the zero-click path is a UI
shortcut, not a statistical one.

**Tempo**: no longer tied to estimator "stages" (there are none in a
posterior). Session picks coarse (20 BPM / 3 s) when credible half-width
> 250 ms, fine (72 BPM) otherwise — using the *existing* `setTempo`
closure and BPM constants unchanged. A tempo switch must only happen when
presenting the NEXT level, never between a trial's preview and its
answer (this was a real bug fixed earlier in the session for the old
estimator — the same care applies here).

**Progress bar**: `log(openingHalfWidth / halfWidth) / log(openingHalfWidth / 6)`,
clamped 0…1, monotone except it may retreat after a rejected proposal
(which is honest, not a bug — say so in the UI copy, don't hide it).

**Rename**: "Can't tell" → **"They sound together"** — same button slot,
but now it's real evidence (residual is inside the fusion window), not a
dead end. This is the direct fix for "it sounded perfect to me but I had
no way of saying so."

### Session/view layer (from the UX research brief)

`BTAlignmentWizardSession.swift` — keep ALL existing exit contracts
unchanged (cancel/Stop/✕/click-away restore-and-tick-off; Try again;
`macIsLate` floor; `invertsEstimate` sign convention for BT latency
candidates vs. Mac trim). Add: `Screen.question` gains
`credibleIntervalMs: ClosedRange<Double>` and drops question-numbering;
new `Screen.proposal(valueMs:)`, `Screen.kept(latencyMs:)`,
`Screen.unsettled(bestGuessMs:)`; `answer(.together)` replaces
`.cantTell`; `acceptProposal()` / `rejectProposal()` / `replayProposal()`;
`keep()` transitions to `.kept` instead of finishing (a new `done()`
finishes) — **this is also the fix for the Keep-visibility complaint**:
the host must call `refreshDeviceRows()` on Keep so the row's chip flips
to 0 ms *while the panel is still open*, not after dismissal, so the user
watches it happen instead of having to go check.

`BTAlignmentWizardView.swift` — question screen: confidence line under
the question, e.g. "Somewhere between 180 and 320 ms" (never render wider
than the opening range even if the model technically would); "They sound
together" / Back / Stop row; elapsed "m:ss" caption instead of a question
count. Proposal screen: "Here's the alignment — N ms. Listen: the clicks
should land as one." with Sounds right (default button) / Still off / Play
again. Kept screen: "Kept. ‹Target› now plays N ms early to stay in step.
Its SYNC is back to 0 — nudge from there if you ever need to." + Done,
plus a VoiceOver announcement on the same beat via the existing
`PopoverController` announcement helper. Unsettled screen: honest copy
("Your answers aren't settling on one value…") + Set it by hand / Try
again / Done. Keyboard: ← target, → reference, Space = They sound
together, Return = Sounds right / default, ⌘Z = Back, Esc = Stop.

### Telemetry additions (small)
`wizard_latency_preview` gains `halfWidthMs`; new `wizard_proposal`
(valueMs, answers, halfWidthMs, accepted: Bool); at BT connect, log
`bt_device_reported_latency` (uid + ms) using the already-existing
`LocalOutputLatency.measure(deviceID:)` called against the BT device id —
this is pure diagnostics for comparing macOS's own (under-)reported
latency against what the wizard measures, no behavior change.

### Concurrency note for whoever schedules this

At the time both agents failed, one was mid-edit on
`AlignmentTickInjector.swift` / `NativeCaptureCoordinator.swift` /
`BTSyncedSink.swift` (the keep-alive fix — now DONE, see above) and the
other (the scoper) was told explicitly not to touch those three files.
**That constraint no longer applies** — the keep-alive fix is finished and
those files are stable. The Bayesian redesign work order can now touch
`BTAlignmentConstantStimuli.swift` (→ delete, replace with
`BTAlignmentPosterior.swift` or similar), `BTAlignmentWizardSession.swift`,
`BTAlignmentWizardView.swift`, `PopoverController.swift`'s wizard block,
and `NativeBackend.swift`'s wizard closures freely — nothing else is
mid-flight on them now.

### Not part of this: the two priors-brief findings worth knowing

From the "zero-click priors" research brief (verified live on this Mac,
not guessed):
- macOS's own `kAudioDevicePropertyLatency` for the connected Sonos Move
  reported **160.9 ms**; the wizard measured **244 ms** live the same
  night — macOS under-reports by ~35%. Not zero, not useless, not
  trustworthy alone. `LocalOutputLatency.measure(deviceID:)` already
  reads this; nothing currently calls it for a BT device id (see the
  `bt_device_reported_latency` telemetry addition above — that is step
  one toward eventually using this as a prior, NOT decided as a shipped
  prior yet).
- No usable per-brand/per-model latency table exists publicly for
  Bluetooth *speakers* (only headphones are measured by review sites).
  Do not invent one. A population-learned table (from opt-in telemetry,
  roadmap 037) is the only realistic path there, and needs ~5 confirmed
  samples per model before it's worth using — out of scope for this
  round.

## Still owed — live re-tests not yet done (unrelated to the wizard estimator work)

From the spec (`per-device-trim-spec.md` §Verification), still untested by
the owner this session:
- Alignment surviving a lineup change (add a third speaker mid-play,
  confirm the first two don't shift) — the anchor-carry code for this is
  built and unit-tested, never live-verified.
- Reconnect survival (disconnect/reconnect an aligned speaker) — spec
  Part 3(b), explicitly deferred, needs the band-split-chirp measurement
  tool that doesn't exist yet.

## Roadmap bookkeeping

Entry **056** is still `status: "planned"` in `ROADMAP.jsonl` despite all
this work — no spawned session ever ran the `in_progress` update. This
handoff marks it `in_progress` with a note pointing here. Whoever finishes
the Bayesian redesign and the remaining live tests should close it with
the real outcome (`done` once live-verified, or split into a follow-up
entry if the estimator work is substantial enough to deserve its own —
that's a judgment call for whoever scopes it, not decided here).
