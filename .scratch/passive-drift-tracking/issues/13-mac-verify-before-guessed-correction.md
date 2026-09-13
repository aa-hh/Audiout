# 13 — Make the verify real, and decide whether it runs before or after the guess

Status: planned
Blocked by: (none)

Decision 7 promises a guessed correction is re-sampled and swapped if wrong. Nothing schedules that window today, so a guess is applied and never checked.

- **Wire it.** `DriftCorrectionApplier.swift:107` drops `.scheduleVerify` on the floor,
  so the only window that can act as a verify is the next periodic one, 180 s later.
  Give the applier a
  `scheduleVerify: @Sendable ([String]) -> Void` closure, filled in at
  `NativeBackend.swift:11077` with `driftTracker?.trigger(.verify)` (new case beside
  `PassiveDriftSampler.swift:316`; the tracker is built after the applier at
  `NativeBackend.swift:11090`, so capture the backend weakly).
  **Delay: fire once every device in the batch has landed, plus 5 s.** A slew moves
  2 ms/s (`DriftCorrectionApplier.swift:32`), so live test 2's −47.6 ms took ~24 s and a
  fixed timer would measure a half-applied move; `drift_correction_landed`
  (`:179`) is that moment. Trap: a trigger during an in-flight window is logged
  skipped and lost.
- **Decision 17, two options.** *Apply then verify* (today's shape, verify running):
  reacts one window sooner, and a wrong move is live and persisted to
  `bt-sync-trims.json` for the whole slew plus 5 s — live test 2 held −11.5 ms then
  −47.6 ms on an in-sync pair and only the owner caught it. *Verify before apply*: hold
  a guessed correction until a second window agrees within ~1.5 ms. Nothing has to
  settle first, so the extra wait is one 4 s window, not 180 s, and wrong-correction
  exposure drops to zero. **Recommend verify before apply**, and say so to Alec.
- **Fix the swap label.** `DriftCorrectionPolicy.swift:164` emits `.swapAndRecorrect`
  even when `corrections` is empty, or holds one device because the group's other member
  gave no observation. No reattribution happened, and the field log counts swaps as wrong
  attributions. Emit `.correct` for a lone move, nothing for none.
- **What is still a guess** after decision 14 (a merged peak returns at
  `PassiveDriftSampler.swift:181` and never reaches the policy): two speakers each moved
  ≥ 10 ms onto separate peaks (`movedCount > 1`, `:224`); a baseline whose nearest peak
  was taken by another (`:258`); a baseline left unmatched because its nearest peak went
  elsewhere (`:266`). One test each in `PassiveDriftSamplerTests.swift`.
- `drift_correction_started` already carries `kind`; add `verify_scheduled` and
  `verify_result` (agree / disagree).

Done when: `DriftCorrectionPolicyTests.swift` and `DriftCorrectionApplierTests.swift`
cover schedule → verify window → agrees (nothing moves) and → disagrees (swap and
re-correct, labelled correctly), the applier is asserted to call its verify closure for
every `.scheduleVerify`, and no path applies a guess without a verify.

## Comments

- 2026-09-13: drafted from live test 2 (HANDOFF.md), spec decisions 7, 14 and 17 (17 is a proposal awaiting Alec's ruling), ticket 05 comments.
