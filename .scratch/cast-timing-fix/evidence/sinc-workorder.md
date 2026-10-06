# Work order: replace the Cast feed's 4-tap cubic with a 32-tap windowed-sinc resampler

### Goal
PR #283's speed matching reads each Cast receiver's feed through `FractionalResampler`, a 4-point cubic interpolator. That interpolator cuts the treble by an amount that depends on its fractional position: at 16 kHz, 1.85 dB at a quarter of a frame and 4.58 dB at half a frame (computed this session; the code comment says 4.6). At 10–20 ppm that position sweeps through every value once every 1–2 s, so the TV sounds dull and pumps in level. The fix gives the Cast ring its own windowed-sinc resampler that reads the ring's storage in place, so the existing ring buffer is its history. The design numbers below come from a numeric probe run this session:
- **Taps and window:** 32 taps, Kaiser window with beta 8.0, cutoff at half the sample rate.
- **Phase table:** 256 phase rows plus one extra row, with linear interpolation between adjacent rows.
- **Flatness:** passband flat to within −0.0001/+0.00055 dB at 1, 10, 16 and 18 kHz, at every phase including the points between rows. So it varies with phase by under 0.001 dB up to 18 kHz.
- **Image rejection:** at least 82 dB for anything at or below 18 kHz, because the stopband is at least 82 dB down from 26.1 kHz up.
- **Above 18 kHz:** −0.39 dB at 20 kHz and −6 dB at 22.05 kHz. Above 18 kHz the response still moves with phase: 0 to −0.05 dB at 19 kHz, 0 to −0.8 dB at 20 kHz.

The speed-matching gain, clamp, events and tracking stay unchanged. `FractionalResampler` stays for its other two users.

### Verified facts
Paths are relative to `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cast-timing-fix-r2`. Line numbers are at HEAD `db50e957`, and the worktree was clean at that commit.

**Who uses `FractionalResampler`**
1. It is defined at `AudioutCore/Sources/AudioutCore/SyncCore.swift:158`. It is a 4-tap Catmull-Rom with a 4-sample shift register, and `frac` is advanced lazily before each output (`:241-256`).
2. It has three users:
   - the Cast ring, `CastOutputManager.swift:269`
   - `BTSyncedSink.swift:524,742`
   - `SyncedLocalSink.swift:105,193` (found with grep only; the file itself was not opened)
3. Its own tests are in `PhaseControllerTests.swift:42-138`.
4. Because Bluetooth and the synced Mac sink depend on its behaviour, the decision is a new type used only by the Cast ring. `FractionalResampler` is untouched.

**The ring today**
5. `CastOutputManager.swift` is licence-clean, with no GPL header (`:1-5`).
6. Constants:
   - `capacityFrames = 88_200` (`:222`)
   - `standingQueueMs = 80` (`:233`)
   - production rings use `CastFeedRing(standingQueueMs: CastFeedRing.standingQueueMs)` (`:888`)
7. Where `capacityFrames` is used:
   - as the storage size: allocate, initialize and deinitialize (`:330-331`, `:351`)
   - as the room check (`:393`)
   - as the write modulus (`:394-395`)
   - as the read modulus (`:559`, `:596-597`)
8. The producer writes the ring without taking `lock` (it uses `producerLock`, `:380`). Its room check is `queued + frames <= capacityFrames` (`:393`). So frames before `consumed` can be overwritten, but frames in `[consumed, pushed)` never are.
9. The render path, `render(frames:nowNanos:)` (`:522-633`):
   - At refill end it calls `resampler.reset(); resampling = false` (`:540-542`).
   - `if takes, ratePpm != 0 { resampling = true }` (`:545`).
   - The ratio guard is `available - (ceil(frames*ratio) + 3) < standingQueueFrames → ratio = 1` (`:550-553`).
   - It allocates a `[Float]` scratch (`:555`), calls the resampler through a `pullFrame` closure (`:557-565`), sets `pulled = index - consumed` (`:566`) and converts to Int16 (`:567-572`).
   - The timing stamp uses `consumed` from before the advance (`:575-591`). The plain `memcpy` path runs only when `!resampling` (`:595-604`).
10. `reset()` sets `consumed = pushed` and resets the resampler (`:725-753`, `:749-750`).
11. `render` runs on `CastLiveAudioServer`'s dispatch queue (`CastSender/CastLiveAudioServer.swift:114,342,389`), not on a Core Audio thread. `Data(count:)` at `:524` and the `[Float]` at `:555` already allocate on every render.
12. Telemetry reads the ring's own counters:
   - `cast_stage_timing` and `cast_lead_sample` read `session.ring.timing` and `.stats` (`:1351,1364-1368`).
   - `stats.achievedDelayMs` is the delay line plus the queue (`:472`).
   - `timing` is built from `lastRender` and the queue (`:486-508`).
13. The doc comment that describes the cubic, its dip and the "up to 3 frames late" stamp is at `:197-214`. `CastRoomDelay.swift:144-146` mentions "±200 ppm ``FractionalResampler`` was validated for".
14. `CastRoomDelay.speedMatch` (`CastRoomDelay.swift:351-366`), gain 10 (`:140`) and clamp 100 (`:147`) are not touched.

**Tests that pin the cubic** (in `AudioutCore/Tests/AudioutCoreTests/CastFeedDelayTests.swift`; numbers re-simulated for the new design this session)
15. `aFeedRateConsumesItsShareOfCapturedFramesExactlyOverALongRun` (`:443-455`) expects `44_010`. The new design gives `44_012`. With the rate ignored, or with the fraction dropped at each render, it gives `44_100`.
16. `aFeedRateOfZeroIsTheByteForBytePathAndAGETReturnsToIt` (`:457-481`): the values are unchanged. Its red sentence names a "2-frame silent tail". With the new design a zero rate sent through the resampler leaves a 16-frame tail.
17. `aFasterFeedRateNeverTakesTheStandingQueue` (`:483-496`) expects `3_526`. The new design gives `3_528`; without the guard it gives `3_264`. The underrun stays `3_528` either way.
18. `aBlockPastCapacityIsDroppedAndCounted` (`:154-163`) needs the room check to stay at exactly 88,200 frames.
19. The wrap test (`:180-219`) passes a ramp across wraps on the plain path.
20. Helpers: `tone(frames:)` (`:28`) and `frameValues(_:)`, which returns channel 0 (`:44-47`). The suite uses `@testable import AudioutCore` (`:8`).

**Docs**
21. The folder `AudioutCore/Sources/AudioutCore/AGENTS.md` is 919 words. Guard 12 blocks growth over 300 words (`AGENTS.md:351-353`), so that file is not edited.
22. `AGENTS-HISTORY.md:353` describes speed matching "through `FractionalResampler`". History files are append-only.
23. Tests must carry a "Turns red if" sentence, must not use `print`, and must not be added as a new one-test file (`AGENTS.md:342-350`).

### Steps
All code edits are in `AudioutCore/Sources/AudioutCore/CastOutputManager.swift` unless a step says otherwise.

1. **Add `final class CastSincResampler`**, placed directly above the `/// One Cast receiver's feed` doc comment (`:168`).
   - Internal constants:
     - `taps = 32`
     - `historyFrames = 15`
     - `lookAheadFrames = 16`
     - `phases = 256`
     - `kaiserBeta = 8.0`
   - Internal `static let table: [Float]` of `(phases + 1) * taps` entries, built in Double:
     - Row `r` is phase `mu = r / 256`.
     - Entry `j` (0..<32) reads input offset `j - 15`, with `t = Double(j - 15) - mu`.
     - Coefficient = `sinc(t) * kaiser(t)`, where `sinc(0) = 1`, `sinc(t) = sin(πt)/(πt)`, and `kaiser(t) = I0(8.0 * sqrt(1 - (t/16)^2)) / I0(8.0)`.
     - `I0` is a private static power series: sum the squares of `(x/2)^k / k!` until a term is below 1e-17 of the sum.
     - Each row is divided by its own Double sum, then stored as Float.
     - Row 0 is written as exactly 1 at `j = 15` and 0 elsewhere. Row 256 is exactly 1 at `j = 16` and 0 elsewhere.
   - Instance state is `private var frac: Double = 0` and nothing else.
   - `init()` reads `Self.table.count`, so the table is built when the ring is constructed and never inside `render`.
   - `reset()` sets `frac = 0`.
2. **Add the render method** to `CastSincResampler`.
   - Parameters: the output Float pointer (interleaved stereo), `frames`, `ratio`, `start` (Int, the ring's `consumed`), `pushed` (Int), `storage` (`UnsafePointer<Int16>`, interleaved stereo) and `storageFrames` (Int).
   - Returns `(written: Int, advanced: Int)`.
   - Body:
     - Clamp `ratio` to `[0.5, 2.0]` as `FractionalResampler` does (`SyncCore.swift:230`).
     - Set `position = start`.
     - Take the table's buffer pointer once, outside the loop.
   - For each output frame:
     1. Stop if `position + 16 >= pushed`.
     2. Compute `p = Int(frac * 256)` and `w = Float(frac * 256 - Double(p))`.
     3. Compute the slot as `(position - 15)` modulo `storageFrames`, made non-negative.
     4. For `j` in 0..<32:
        - `c = row_p[j] + w * (row_{p+1}[j] - row_p[j])`
        - add `c * Float(storage[slot*2])` to the left sum and `c * Float(storage[slot*2+1])` to the right sum
        - step `slot` by 1, wrapping to 0 at `storageFrames`
     5. Write left and right as Float.
     6. `frac += ratio`, `adv = Int(frac)`, `position += adv`, `frac -= Double(adv)`.
   - Return the frames written and `position - start`.
   - The loop uses no allocation, no locks and no Foundation calls.
   - Cost is about 32 × 8 operations per frame, about 11 million per second for stereo at 44.1 kHz. That is under 1% of one core. This is an arithmetic estimate, not a measurement.
3. **`CastFeedRing` storage size.** Add `private static let storageFrames = capacityFrames + CastSincResampler.historyFrames`. Use it for the allocate, initialize and deinitialize counts (`:330-331`, `:351`) and for the modulus and run length at `:394-395` and `:596-597`. Leave the room check at `:393` on `capacityFrames`. With that, the 15 frames before `consumed` are never overwritten.
4. **`CastFeedRing` resampler property** (`:269`): change it to `CastSincResampler()`. The calls at `:541` and `:749` stay `resampler.reset()`.
5. **`render`, resampling branch** (`:548-573`):
   - The ratio guard becomes `available - Int((Double(frames) * ratio).rounded(.up)) < standingQueueFrames`. The `+ 3` is dropped because the look-ahead no longer leaves the ring.
   - Keep the `[Float]` scratch.
   - Replace the closure call and the `index` variable with one call to `resampler.render`, passing `start: consumed`, `pushed`, `storage`, `Self.storageFrames`.
   - Set `written` from the result, and set `pulled` from `advanced`.
   - Keep the Int16 conversion loop.
6. **`CastFeedRing` doc comment** (`:197-214`): rewrite the speed-matching paragraph from the shipped code.
   - The resampled read goes through `CastSincResampler`: 32-tap Kaiser windowed sinc, reading the ring in place.
   - Its 16-frame look-ahead comes out of the queued audio, so there is no added delay. The timing stamp is within one frame.
   - Switch-on is seamless because phase 0 is an exact copy.
   - It stays on the resampler until `reset()` or a refill, and holds its phase at rate 0.
   - Flat within 0.001 dB to 18 kHz at every phase.
   - Remove the cubic dip text and the "up to 3 frames late" sentence.
   - Add a `razor:` sentence: above 18 kHz the response varies with phase (0 to −0.8 dB at 20 kHz); a longer kernel narrows it.
7. **`CastRoomDelay.swift:144-146`:** delete the clause ", inside the ±200 ppm ``FractionalResampler`` was validated for". The sentence ends at "0.17 cents of pitch."
8. **Update the three tests in `CastFeedDelayTests.swift`.**
   - `:452`: expect `44_012`. The red sentence becomes: "Turns red if the rate stops reaching the render or a render drops the fractional position instead of carrying it (44,100 left both ways)."
   - `:460`: replace "(its primed frames leave a 2-frame silent tail)" with "(its 16-frame look-ahead leaves a 16-frame silent tail)".
   - `:494`: expect `3_528`. The red sentence becomes: "Turns red if a rate above 1 is applied when it would take the ring below its standing queue (3,264 left)."
9. **Add four `@Test`s** to the "The feed rate" section of `CastFeedDelayTests.swift`.
   - **Shared rules for all four:**
     - Add one private sine fixture: S16LE stereo, both channels `Int16((A * sin(2π f k / 44100)).rounded())` for stream frame `k`, given a start frame and a frame count. Add one RMS-in-dB helper over channel 0.
     - Each ring is a plain `CastFeedRing()`.
   - **Test (a), level at fixed phases.**
     - For each mu in {0.25, 0.5, 0.75} and each f in {1000, 10000, 16000, 18000} Hz:
       1. Make a fresh ring and push 7,056 frames of sine at amplitude 16384.
       2. `setRatePpm(mu * 1_000_000)` and render 1 frame.
       3. `setRatePpm(0)` and render 64 frames, which are discarded.
       4. Render 4,410 frames.
     - Expect the output RMS to be within ±0.05 dB of the input RMS over 4,410 frames.
     - This also covers item 5 of the request: rate 0 at a frozen phase is transparent.
     - Red sentence: "Turns red if the Cast feed's interpolator returns to the 4-tap cubic (−4.58 dB at 16 kHz and −0.74 dB at 10 kHz at half a frame) or its cutoff drops below half the sample rate."
   - **Test (b), phase independence. This is the regression test for the owner's complaint.**
     1. Push 5 blocks of 882 frames of 16 kHz sine at amplitude 16384, then `setRatePpm(20)`.
     2. Loop 150 times: push the next 882-frame block, then render 882 frames.
     3. Compute RMS in dB per consecutive 4,410-frame window.
     - Expect max minus min below 0.1 dB, and an underrun count of 0.
     - Red sentence: "Turns red if the Cast feed is read through the 4-tap cubic again, whose 16 kHz level swings 4.6 dB each time the phase passes half a frame."
   - **Test (c), continuity across render calls, the switch-on and the ring's wrap.**
     1. Push 5 blocks of 1 kHz sine at amplitude 10000.
     2. Render 1,000 frames at rate 0.
     3. `setRatePpm(100)`.
     4. Loop 130 times: push the next 882-frame block, then render chunks cycling through 441, 1323, 7 and 1757 frames.
     - Expect:
       - output frames 32..<1000 equal the input exactly
       - every later frame `j` is within 2 LSB of `10000 * sin(2π * 1000 * (1000 + (j - 1000) * (1 + 100e-6)) / 44100)`
       - an underrun count of 0
     - Red sentence: "Turns red if switching onto the resampler skips or repeats a frame, the fractional position restarts at a render boundary, or a tap read across the ring's wrap comes from the wrong slot."
   - **Test (d), unity DC gain.** Expect every row of `CastSincResampler.table` to sum to 1 within 2e-6.
     - Red sentence: "Turns red if the rows stop being scaled to sum to 1 (raw windowed-sinc rows miss by up to 3.4e-5)."
10. **Append one line** to the end of `AudioutCore/Sources/AudioutCore/AGENTS-HISTORY.md`, dated 2026-10-06. It says the Cast speed-matching read moved from `FractionalResampler` to `CastSincResampler` because the cubic's phase-dependent treble dip was heard as dullness and pumping in the live A/B. Give the new figures from Step 6. Do not edit any existing line.

### Out of scope: do not touch
- `SyncCore.swift`, `FractionalResampler`, `PhaseController`, `BTSyncedSink.swift`, `SyncedLocalSink.swift` (never open it), `PhaseControllerTests.swift`.
- Anything in `CastRoomDelay.swift` except the Step 7 comment, including the speed-match gain, clamp and window.
- `CastLiveAudioServer`.
- The folder `AGENTS.md`. `dev/notes/`.
- Removing the existing `[Float]` and `Data(count:)` allocations in `render`. They predate this work and run on the HTTP server's queue.
- No crossfade, no extra priming, no switching back to the plain copy, no SIMD or Accelerate rewrite.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compatibility shims.

### Retired terms
none

### Verification
- `bash scripts/build.sh` → exits 0.
- `bash scripts/run-tests.sh --filter 'CastFeedDelayTests|CastOutputManagerTests'` → all pass, 0 failures. `CastFeedDelayTests` has 4 more tests than before.
- If a number in Step 8 or a test in Step 9 comes out different, STOP and report the value. Do not retune the constants or tolerances.

### Execution plan
- **One track**, run in parallel with nothing else. Model: opus. Effort: high, for the DSP table, in-place ring indexing and the test numbers.
- **Files:** `CastOutputManager.swift`, `CastRoomDelay.swift`, `Tests/AudioutCoreTests/CastFeedDelayTests.swift`, `Sources/AudioutCore/AGENTS-HISTORY.md`.
- **Starting point:** the branch has no uncommitted work. The track works directly in the `cast-timing-fix-r2` worktree at `db50e957`.

### Executor rules (copy verbatim into the handoff prompt)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
> - If a step changes code that another screen, window or surface also draws or calls and the work order does not name that surface, STOP and report it as a discrepancy before editing. Flagging it and continuing is not enough; the owner decides whether the change applies there.
> - When the work order lists Retired terms, after the last step run `git grep -n -i` for each term across `AudioutCore/Sources`, `AudioutCore/Tests`, `DESIGN.md` and every `*.md`, fix the hits a step covers, and list every other hit with file:line in your report. A new or moved test carries one comment sentence naming the code change that turns it red.
> - A test you add or move carries one comment sentence naming the code change that turns it red; a new test extends an existing suite before it starts a new file; folder AGENTS.md lines carry no dates, rulings or decision ids, and AGENTS-HISTORY.md is only appended to; DESIGN.md sections are rewritten from the shipped code, never from the plan.
> - Work only in `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cast-timing-fix-r2`. Do not commit or push.
> - Never open or read `SyncedLocalSink.swift`.
> - Build and test only through `scripts/build.sh` and `scripts/run-tests.sh`, never a bare `swift` command.
> - Any subagent you start must be started with `run_in_background: false`.
### Corrections appendix (from the spec check; OVERRIDES the steps above where they differ)
C1. Step 8, first test: the `== 44_010` check is at `CastFeedDelayTests.swift:454` (not :452); its red sentence is at `:445`. Change 44_010 → 44_012 at :454 and replace the sentence at :445.
C2. Step 8, third test: change `#expect(ring.bufferedFrames == 3_526)` at `:495` to `== 3_528`. Leave `:494` (`underrunFrames == 3_528`) as is. Replace the red sentence at `:485` with the Step 8 sentence (the "(3,528 left)" rate-ignored clause is dropped).
C3. Line numbers: SyncCore advance is `:253-264`; `standingQueueMs` at `:237`; `[Float]` scratch `:554`; closure `:556-565`; timing stamp `:577-594`; the `/// One Cast receiver's feed` doc comment starts at `:169`. Locate by content, not by number.
C4. `CastLiveAudioServer.swift` is at `AudioutCore/Sources/CastSender/CastLiveAudioServer.swift` (read-only context; do not edit).
C5. Do not copy the Goal's "-0.39 dB at 20 kHz" or "-6 dB at 22.05 kHz" into any doc or history line. Use only the figures given in Step 6.
C6. Step 1 constants are `static let` (taps, historyFrames, lookAheadFrames, phases, kaiserBeta, table). The Step 2 loop uses the named constants, never bare 15/16/32/256.
C7. Test (a): compare against the exact input RMS 16384/√2 (i.e. 20·log10 of output RMS vs 16384/√2), not a measured input.
C8. Test (c): assert output frames 0..<1000 equal the input exactly (that render is the plain copy); then the sine check for every later frame.
C9. Out of scope also: `NativeCaptureCoordinator.swift` (its own Catmull-Rom at ~:2977 for the synced Mac sink). Do not touch it.
