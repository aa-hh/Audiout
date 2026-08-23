# Work order — Bayesian alignment wizard (roadmap 056, estimator redesign)

2026-08-22 · scoped by Fable against the worktree at `7968ee29` + the 41
uncommitted files · design locked in
`dev/notes/056-wizard-handoff-2026-08-22.md` §"NOT DONE" — the numbers there
are simulation-backed and NOT to be re-litigated. This document turns that
design into file-by-file instructions. Where this document and the handoff
disagree on a mechanism, this document wins (it is grounded against the
actual code); where it flags an OPEN item, ask Alec, don't guess.

## What is being replaced, in one paragraph

`BTAlignmentConstantStimuli.swift` (search staircase + stimulus blocks,
~30 answers/run, progress bar structurally wrong) is deleted and replaced by
a Bayesian posterior estimator, `BTAlignmentPosterior.swift`. The session
(`BTAlignmentWizardSession`) keeps every exit contract but gains
proposal/kept/unsettled screens and "They sound together" semantics. The
view renders the new screens plus a confidence line, elapsed-time caption,
and keyboard map. The host (`PopoverController`) wires the zero-click path,
the Keep-visible-while-open fix, and "Set it by hand". Telemetry gains three
small additions. Nothing else moves.

## Fences — do not touch

- `AlignmentTickInjector.swift`, `NativeCaptureCoordinator.swift` — the tick
  feed and keep-alive are DONE and stable. No edits.
- `BTSyncedSink.swift` — ONE addition only (T5 telemetry); no other edits.
  Anchor-carry, release-catch-up, participant-hold all stay as built.
- No prior seeding from stored values (flat prior is locked — the zero-click
  path is a UI shortcut, not a statistical one). No per-brand latency table.
- `Config.keepAliveKind` and its `.noise` fallback stay exactly as they are.
- The Mac-row SYNC surface, drawer, `noteExternalTrimChange`, suspend-trim
  mechanics in `startBTAlignmentWizard` — unchanged except where T4 says.

## T1 — `BTAlignmentPosterior.swift` (new; delete `BTAlignmentConstantStimuli.swift`)

Same file location, same LICENSE-CLEAN no-GPL-header posture, pure
Foundation, single-threaded struct, no clocks/audio/queues.

**State**: `belief: [Double]` over whole-ms offsets spanning the `range`
passed to `init` (estimate space, same convention as today — the session's
`estimateRange` conversion is unchanged). Flat at init. Plus the ordered
answer history (for `back()`), a rejection counter, and per-answer-type
likelihood LUTs.

**Listener model constants** (fixed, do not tune): fusion half-window
`c = 6`, slope `sigma = 5`, lapse `lambda = 0.12`.

**Likelihoods** for residual `a = θ − x` (θ grid point, x presented level),
Φ = standard normal CDF via `0.5 * (1 + erf(z / 2.squareRoot()))` (Darwin
`erf`, no dependency):
- P(target first) = Φ((a − c)/σ)
- P(reference first) = Φ((−a − c)/σ)
- P(together) = 1 − the other two
- each lapse-mixed: `p ← (1−λ)·p + λ/3`

Precompute the three curves once at init into LUTs indexed by whole-ms
residual over `−(span + 900)…+(span + 900)` (levels can sit up to 900 ms
from a grid point). Every update and every entropy evaluation reads the
LUT; nothing calls `erf` per-answer.

**Update**: multiply belief by the answer's likelihood row, renormalize.

**Next level**: minimum expected posterior entropy over candidates
`median ± {0, 2, 4, 6, 8, 11, 15, 20, 28, 40, 60, 90, 140, 220, 350, 550,
900}` ms (33 candidates), clamped into `range`, deduplicated after
clamping. Deterministic — the estimator takes NO RandomNumberGenerator
(delete `AnyRandomNumberGenerator` if nothing else uses it — verified: only
the estimator and session reference it today). Ties in expected entropy
break toward the candidate nearest the median.

**Derived reads** (the session and view consume these):
- `medianMs: Double` — posterior median.
- `credibleHalfWidthMs: Double` — half the 95% credible interval width.
- `credibleIntervalMs: ClosedRange<Double>` — the 95% CI itself.
- `progress: Double` = `log(w0/w) / log(w0/6)` clamped 0…1, where `w0` is
  the half-width at init and `w` current. May retreat after a rejected
  proposal — that is correct, do not clamp it monotone.
- `answerCount: Int`.

**Phases** (`enum Phase`):
- `.asking(candidateMs: Double)` — next level to present.
- `.proposing(valueMs: Double)` — stop rule fired: `credibleHalfWidthMs ≤ 6`.
  Proposed value = median, rounded to whole ms.
- `.converged(resultMs: Double)` — proposal accepted.
- `.unreachable` — ≥ 20% of posterior mass in the outermost 20 ms of the
  range (either end) after ≥ 8 answers. Replaces the old "clamped twice"
  definition entirely.
- `.unsettled(bestGuessMs: Double)` — half-width shrank < 20% over the last
  8 answers, or ≥ 40 answers total, or a second rejected proposal. Best
  guess = current median.

There is NO `.gracefulExit`: a genuinely-aligned pair converges near 0 and
proposes 0 — the proposal screen covers it. (The old graceful-exit copy
dies with it; see T3.)

**API**:
- `init(range: ClosedRange<Double>, openingProposalMs: Double? = nil)` —
  non-nil starts in `.proposing(valueMs:)` over a still-flat belief
  (zero-click path).
- `mutating func record(_ answer: Answer)` — `Answer` = `.target` /
  `.reference` / `.together`. Only valid in `.asking`.
- `mutating func back()` — pop the answer history and REFOLD the belief
  from the flat prior (the posterior is order-independent and refolding is
  ~40 × 2001 multiplies — cheap). No state-snapshot Undo class.
- `mutating func acceptProposal()` — multiply belief by the
  fused-within-4-ms likelihood `Φ((4−a)/σ) − Φ((−4−a)/σ)`, 5%-lapse-mixed
  (`p ← 0.95·p + 0.05/2`), renormalize, then `.converged(resultMs:
  medianMs)`. For an opening (zero-click) proposal this converges on the
  proposed value as expected.
- `mutating func rejectProposal()` — multiply by the complement, renormalize,
  count the rejection; second rejection → `.unsettled`, else back to
  `.asking` with a fresh next level.
- Test seams as pure reads, mirroring today's `test_*` style.

## T2 — `BTAlignmentWizardSession.swift`

**Unchanged contracts — keep byte-for-byte behavior**: `cancel()` /
`deinit` / the `ended` single-tick-off-edge rule; `endPreview` commit /
restore semantics and the Keep floor for latency runs; `invertsEstimate`
and `estimateRange` / `candidate(for:)` conversions; `setReference` restart
semantics (including never re-firing the tick — the host re-pushes);
`start()` refused without a reference; `implausibleLatencyMs`.

**Screen enum changes**:
- `.question(progress: Double, answersSoFar: Int, searching: Bool)` →
  `.question(progress: Double, credibleIntervalMs: ClosedRange<Double>,
  answersSoFar: Int)`. `answersSoFar` stays solely to gate Back; the
  question-number caption is gone (T3 renders elapsed time). `searching`
  is gone — tempo is CI-driven (below).
- `.receipt(trimMs:)` → GONE. Replaced by:
- `.proposal(valueMs: Double)` — the tick STAYS ON (the user judges by
  listening); the preview is applied at the proposed value.
- `.kept(valueMs: Double)` — after Keep; terminal for the run's audio (tick
  off, value persisted) but the panel stays up.
- `.unsettled(bestGuessMs: Double)` — new bow-out.
- `.gracefulExit` → GONE. `.unreachable`, `.macIsLate`, `.intro` stay.

**Answer**: `.cantTell` → `.together` (rename in session's public enum and
the estimator mapping).

**New/changed intents**:
- `answer(_:)` — folds into the posterior. On `.proposing(v)`: map to value
  space via `candidate(for:)`; a latency run whose proposal lands below
  `implausibleLatencyMs` goes `endRun()` + `.macIsLate` (same check, new
  location); otherwise `applyPreviewTrim(proposedValue)` and transition to
  `.proposal(valueMs:)` — tick stays on. On `.unreachable`/`.unsettled`:
  `endRun()` + the matching screen (unsettled's best guess mapped through
  `candidate(for:)`).
- `acceptProposal()` — forward to estimator; on `.converged`: `setTick(false)`,
  `endPreview(kept value)` with the existing latency floor, transition
  `.kept(valueMs:)`, log `wizard_proposal` accepted. Sets `ended` the way
  `keep()` does today.
- `rejectProposal()` — forward; log `wizard_proposal` rejected; resume
  `.question` (apply next candidate) or land `.unsettled`.
- `keep()` → DELETE (accept IS keep). `tryAgain()` → keep, but reachable
  from `.proposal` and the terminal screens' Try again; it rebuilds the
  estimator flat (no zero-click on a retry).
- `done()` — from `.kept` (and usable by terminal screens): no-op on state,
  exists so the view has one non-cancel close intent; the host's
  `onFinished` does the teardown as today.
- Zero-click: `init` gains `openingProposalMs: Double? = nil`, forwarded to
  the estimator. `start()` from `.intro` with it set: tick on, preview
  applied at the opening value, transition `.proposal(valueMs:)`.
- `measuresLatency: Bool` exposed publicly (== `invertsEstimate`) so the
  view can pick kept-screen copy.

**Tempo**: in `transition(to:)`, when presenting `.question` or `.proposal`:
`searchTickBPM` (20) while `credibleHalfWidthMs > 250`, else `blocksTickBPM`
(72). Constants and `lastTempoBPM` dedupe unchanged. Never re-push tempo
between a presented level and its answer (the existing structure already
guarantees this — tempo only moves inside `transition`).

**Telemetry** (session-side, `Telemetry.log(.localPlayback, …)`):
`wizard_proposal` with `valueMs`, `answers`, `halfWidthMs`, `accepted`
("true"/"false"), logged on each accept/reject.

## T3 — `BTAlignmentWizardView.swift`

Chrome, mounting, reference row, shrinkable-name buttons, test-hook style:
all unchanged. Screens:

- **Question**: body copy stays "Which speaker clicked first?"; confidence
  caption under it — `"Somewhere between X and Y ms"` from
  `credibleIntervalMs` mapped to VALUE space (same `candidate(for:)` sign
  handling the session applies — the session should hand the interval
  already value-mapped; do the mapping in the session, not the view), never
  rendered wider than the opening range. Buttons row 1: target / reference
  (unchanged). Row 2: **"They sound together"** (replaces "Can't tell") /
  Back / Stop. Caption: elapsed `m:ss` since Start (view-owned 1 s `Timer`,
  invalidated whenever the screen isn't `.question` and on unmount — no
  clock in the session). Progress bar: unchanged widget, fed the session's
  progress.
- **Proposal**: body `"Here's the alignment — N ms. Listen: the clicks
  should land as one."`; buttons **Sounds right** (prominent, default) /
  **Still off**. (OPEN-1 below: "Play again" dropped.)
- **Kept**: latency run: `"Kept. ‹Target› now plays N ms early to stay in
  step. Its SYNC is back to 0 — nudge from there if you ever need to."`;
  Mac-row run (`!session.measuresLatency`): `"Kept. This Mac's timing is
  saved."` + the same nudge sentence minus the SYNC-reset claim (its trim
  IS the kept value). Button: Done → `session.done()` + `onFinished`.
- **Unsettled**: `"Your answers aren't settling on one value. Moving closer
  to the speakers usually helps."`; buttons **Set it by hand** / Try again /
  Done. Set it by hand fires a new `onSetByHand: ((Double) -> Void)?` with
  the best guess, then `onFinished`.
- **Unreachable / macIsLate / intro**: unchanged copy and behavior.
- Progress-retreat honesty: when a rejection lowers progress, the question
  screen's confidence caption is the explanation — no extra copy needed
  beyond the interval widening. Do NOT animate the bar backwards specially.

**Keyboard** (question + proposal screens): `←` target, `→` reference,
Space "They sound together", Return default button (Sounds right on
proposal; no default on question), `⌘Z` Back, Esc Stop. Implement via
`performKeyEquivalent(with:)` on the view (arrows/Space/Return only when a
`.question`/`.proposal` screen is mounted); PopoverController must route
Esc to the wizard BEFORE its popover-close handling while the panel is
mounted (find its existing key/cancelOperation path and gate on
`btWizardView != nil`). Do not become first responder by stealing focus
from an open drawer's field editor.

## T4 — host wiring (`PopoverController.swift`, `AppDelegate.swift`, `NativeBackend.swift`)

- **Zero-click**: in `startBTAlignmentWizard`, for a non-local target with
  `btMeasuredLatency(for: deviceID) != nil`, pass
  `openingProposalMs: base` to the session. Local targets: never.
- **Keep visibility** (the locked fix): in the `endPreview` closure's
  `keepMs != nil` branch, after the cache writes, call
  `self?.refreshDeviceRows()` and post the VoiceOver announcement through
  the existing announcement helper (`postAnnouncement`) — e.g.
  `"‹name› aligned at N milliseconds"`. Keep does NOT call `onFinished`
  any more (accept keeps the panel up on `.kept`); the view's Done does.
  Verify `tearDownBTWizard`'s suspended-trim restore still runs on that
  later teardown — it does today, keep it.
- **Set it by hand**: wire `onSetByHand` → tear down the wizard (normal
  finish path), `toggleSyncDrawer(deviceID:animated:)` to open the drawer,
  then hand the best guess to a NEW small drawer affordance:
  `BTSyncDrawerView.beginEditingSuggestedValue(_ ms: Double)` — focuses the
  value field with the suggested value as selected text so Return commits
  it and Esc/blur discards; it must NOT write anything itself (the drawer's
  committed-gestures-only contract holds). For a latency-run best guess,
  convert to the trim the drawer edits: suggested trim =
  `bestGuessValueMs − storedLatency` clamped to the trim range (the drawer
  edits TRIM; the run measured LATENCY; the sum is what aligns).
- **`wizard_latency_preview` gains `halfWidthMs`**: thread one optional
  through the chain — session's `applyPreviewTrim` closure signature
  becomes `(Double, _ halfWidthMs: Double?) -> Void`;
  `onBTWizardLatencyPreview` and `onLocalTrimPreview` calls pass it
  (`onLocalTrimPreview` ignores it — do not change the local seam);
  `AppDelegate` forwards; `setBTWizardLatencyPreview(_:forDevice:halfWidthMs:)`
  adds it to the existing log line (omit the key when nil). The `stage`
  field's tempo-based derivation still works (coarse/fine) — leave it.
- Delete `keep()`-era code paths that no longer exist (`.receipt` handling,
  `questionCountCopy`, graceful-exit copy) rather than stranding them.

## T5 — `bt_device_reported_latency` (one telemetry line)

In `BTSyncedSink`, at the point a device's `AudioObjectID` is resolved for
a sink start (the control-path device setup around the `deviceID` member —
NOT any RT/render callback), log once per uid per connect:
`Telemetry.log(.localPlayback, "bt_device_reported_latency", ["uid": …,
"ms": …])` using `LocalOutputLatency.measure(deviceID:)` (already
internal to AudiouterCore; wrap in `try?` — a failed read logs nothing).
Pure diagnostics; no behavior change; no store.

## T6 — tests

- **Delete** `BTAlignmentConstantStimuliTests.swift`; **new**
  `BTAlignmentPosteriorTests.swift`:
  - Simulated observer (seeded RNG lives in the TEST, answering by the same
    3-way model with true c=4, σ=3, λ=0.10 — narrower than the estimator's
    model, which is the realistic case): over ≥ 200 seeded runs at true
    offsets across the range (include 0, ±3, ±180, ±450), ≥ 95% of runs
    reach `.proposing` within 4 ms of truth, median answers ≤ 20.
  - "Together" moves the posterior (posterior mass concentrates around the
    presented level after repeated together answers).
  - Accept converges on the proposal; two rejects → `.unsettled`; a reject
    widens the CI (progress retreats).
  - `.unreachable` fires on the mass-in-the-wings rule and NOT before 8
    answers; `.unsettled` fires on the stagnation and 40-answer rules.
  - `back()` refold: answer A, answer B, back, answer B ⇒ identical belief
    to answer A, answer B (bitwise on the belief array).
  - `openingProposalMs` starts `.proposing`; reject falls into `.asking`
    from flat.
  - Determinism: same answers ⇒ same levels (no RNG anywhere).
- **`BTAlignmentWizardSessionTests`** (25 tests): rewrite flow tests to the
  new screens; KEEP the exit-contract tests asserting cancel/deinit
  restore + single tick-off, macIsLate floor, reference-swap restart,
  start-refused-without-reference — same assertions, new screen names.
  Add: tick stays ON through `.proposal` and goes off exactly once on
  accept; tempo flips at the 250 ms CI threshold and only when presenting;
  `wizard_proposal` logged on accept and reject.
- **`PopoverBTAlignmentUITests`** (41 tests): update copy/buttons; add:
  Keep repaints the row while the panel shows `.kept`; zero-click opens on
  proposal; Set it by hand opens the drawer with the suggested value
  focused-not-committed; Esc stops the wizard and does not close the
  popover while the panel is mounted; keyboard map on the question screen.
- **`NativeBackendBTAlignmentInterceptTests`**: extend the
  `wizard_latency_preview` assertions with `halfWidthMs`.
- Full suite green via `bash scripts/run-tests.sh` (never bare swift test);
  compile via `bash scripts/build.sh`.

## OPEN items — Alec's call, do not decide silently

1. **"Play again" on the proposal screen is dropped** in this work order:
   the tick keeps running through `.proposal`, so there is nothing to
   replay — and re-firing the tick gate costs a full re-anchor of every
   sink (documented in the session's `ended` comment). The handoff's locked
   button row said Sounds right / Still off / Play again. If Alec wants the
   button anyway, the honest implementation is a finite tick burst, which
   means new injector surface — currently fenced off.
2. **Kept-screen copy for the Mac row** is drafted here (the handoff only
   locked the BT wording). One sentence, needs his eye, not his time.
3. **`.gracefulExit` is absorbed** by the proposal flow (converge near 0 →
   "Sounds right?"). Its copy dies. Flagging because it was once locked UX.

## Not in this work order (stays owed elsewhere)

Live tests: 20 Hz keep-alive on the real Sonos Move; lineup add/remove
by-ear; the new wizard end-to-end. Reconnect chirp measurement (spec Part
3b). Roadmap 056 close-out happens only after those.
