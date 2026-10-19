# 01 — EQ makeup headroom: a boost must not clip at full scale (roadmap 087)

Status: REJECTED — built, reviewed, failed the live test, reverted (see Outcome below); PR #203 closed
Worktree: `.claude/worktrees/eq-headroom-087` (branch `claude/eq-headroom-087`, from main)

Evidence: owner session 2026-09-14 23:55Z, `stream_health` on the shaped stream read
`peak_dbfs=-0.0` for the whole session while stream 0 sat at −2.1 dBFS.
`EQProcessor` runs widen → biquads → balance → clip → requantize
(`AudioutCore/Sources/AudioutCore/EQProcessor.swift:150-165`, `:214-240`), so any net
boost on near-full-scale program saturates.

## Change (one file + one test file)

`EQProcessor.swift`:

1. Add `public static func headroomDB(for eq: DeviceEQ, sampleRate: Double) -> Double`:
   the peak of `responseDB(sections:atHz:sampleRate:)` over a log-spaced grid of 64
   points from 20 Hz to `nyquistFraction * sampleRate`, clamped at `>= 0`. Balance is
   attenuate-only and excluded (it already is in `responseDB`). Flat → 0.
2. In `Engine.init`, fold the headroom into the existing channel gains:
   `let trim = Float(pow(10, -EQProcessor.headroomDB(for: eq, sampleRate: sampleRate) / 20))`
   then `leftGain = gains.left * trim`, `rightGain = gains.right * trim`. That is the
   whole DSP change — `filterBalanceAndClip` already multiplies by these gains AFTER the
   biquads and BEFORE the clip, in float, so the cascade may exceed ±1 internally and
   the trim brings it back under before `vDSP_vclip`. Post-filter placement keeps the
   carried delay memory in input units, so `retarget(to:)` is unaffected.
3. Update the class doc comment (one sentence): a shaped curve is trimmed by its peak
   response so a boost never nets above 0 dB at any frequency; the response curve the
   UI draws is the untrimmed shape.

No UI change. The Equalizer page keeps drawing the relative shape (eqMac/EasyEffects
do the same); loudness on = 6 dB trim, by design.

## Tests (`AudioutCore/Tests/AudioutCoreTests/EQProcessorTests.swift`)

- Change the `gain(_:atHz:amplitude:)` helper to divide the measured ratio by the trim:
  `/ pow(10, -EQProcessor.headroomDB(for: eq, sampleRate: sampleRate) / 20)` — every
  existing response test then still asserts the SHAPE and stays green unchanged.
- `fullScaleInputWithABoostClipsInsteadOfWrapping` (`:129`): its input no longer
  clips after the trim. Feed a full-scale SQUARE wave instead (add a `square(hz:)`
  helper next to `sine`): its fundamental is 4/π ≈ 1.27, so +12 dB at 1 kHz still
  exceeds full scale after a 12 dB trim, and the wrap assertions keep their meaning.
- New `aBoostedFullScaleSineNeverClips`: +12 dB at 1 kHz on a full-scale 1 kHz sine;
  assert no run of ≥ 3 consecutive samples at exactly ±32_767 (a flat top), and output
  RMS within 0.5 dB of input RMS. Defect it names: dropping the trim from `Engine.init`.
- New `aCutOnlyCurveGetsNoTrim`: `DeviceEQ(bandGainsDB:)` with one −6 dB band;
  `headroomDB == 0` and `gain(atHz: 8_000) ≈ 1` within 1%. Defect: clamping the peak
  at 0 the wrong way round.
- Run: `bash scripts/run-tests.sh --filter EQProcessorTests` (must print
  `Test run with 22 tests`, 20 existing + 2 new).

Edits in this worktree must go through Bash (heredoc / python) — the Edit/Write tools
refuse paths outside the session's own worktree.

Commit on `claude/eq-headroom-087`, push to origin, open a PR to main titled
"EQ: trim a shaped curve by its peak response so a boost never clips". Do not merge.

## Outcome — REJECTED 2026-09-15

Built, reviewed twice, then failed the owner's live test and reverted. The trim is folded into the
channel gains, so a +6 dB bass boost attenuates the whole stream 6 dB: the bass lands back at its
original level and every other frequency drops. Owner: "I put up the bass, the volume goes down and
the bass stays where it was."

A boost must raise the band it names and leave the rest alone. Clipping on a boosted stream is
ordinary EQ behaviour, and `filterBalanceAndClip`'s float→S16 clamp already prevents wrap-into-noise.
`stream_health peak_dbfs=-0.0` on a shaped stream is that clamp working, not a defect. If boosts ever
crunch audibly, the fix is a user-controlled preamp, not an automatic trim.

PR #203 closed, roadmap 087 rejected. The branch `claude/eq-headroom-087` is kept for reference.
