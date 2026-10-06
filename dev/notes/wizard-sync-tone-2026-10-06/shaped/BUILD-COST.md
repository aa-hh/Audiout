# Build cost of changing the wizard's sounds

Every claim below was read from the code on 2026-10-06. Paths:

- Mac app = `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/wizard-sync-tone-research-000c03` (paths below are relative to it unless they start with `audiout-shared/` or `audiout-remote/`)
- `audiout-shared/` = `/Users/alechenderson/Projects/audiout-shared` (both apps pin tag `0.19.0`, which is that repo's `main`)
- `audiout-remote/` = `/Users/alechenderson/Projects/audiout-remote` (the iPhone app)

## Summary

| Class | Files touched (count) | Ships as | Tests affected | Effort | Main risk |
|---|---|---|---|---|---|
| A. New band, direction or fade, still two exponential sweeps | 1 source file (`SyncProbeCorrelator.swift`, 2 factory lines + type note), 2 test files, 1 new ADR, `AGENTS.md` line 13 in audiout-shared; 2 pin files per app (4 total). No app source changes. | Package tag + 2 pins | `ProbeAnalyzerTests.swift:209-215` pins the four band numbers; `SyncProbeCorrelatorTests.swift:221-233` keeps the guard gap at 1.25x or more; `ProbeAnalyzerTests` renders at 24 kHz, so the top edge must stay under 12 kHz. Every Mac and phone test follows the factories with no edit. | **S**: two constants, one ADR, one pinned test, a tag, two pin bumps, one live listen. | A Mac and a phone on different tags correlate a sweep against a sweep with different edges; nothing on the wire says which design is playing, and a mismatched sweep template shifts the peak instead of losing it. Confident wrong number. |
| B. Sweeps replaced by band-limited noise ("whoosh") on one or both lanes | audiout-shared: `SyncProbeCorrelator.swift` (new synthesis + seeded generator), `ProbeAnalyzer.swift`, both ProbeKit test files, ADR, AGENTS.md. Mac: `AlignmentTickInjector.swift`, `MicProbeSession.swift`, `mic-probe-spike/main.swift`, `AlignmentTickInjectorTests.swift`, `MicProbeSessionTests.swift`. Phone: `AlignmentRunController.swift` (gate), `RoomListening.swift` (demo score), its gate test. About 12 files plus 4 pin files. | All three repos | ProbeKit: 25 tests, most of which render scenes through `SyncProbe.value(_:at:)`, which a per-sample noise does not have. Mac: 3 staging tests and 3 scene builders. Phone: `AlignmentRunControllerTests.swift:130-144` if the gate moves. | **L**: new synthesis that must come out identical at three different sample rates, a production seeded generator, rewritten test scene helpers, both apps' acceptance floors re-set from new live data, and level rules redone for a signal that peaks 12-17 dB above its average. | The 1 s whoosh's reference lane scored 16 in the bench and 17 with **no** room noise at all (`04-experiments.md` row 2a): its own random correlation background caps it. The Mac refuses below 20 (`MicProbeSession.swift:496`) and the phone below 25 (`audiout-remote/AudioutRemote/Model/AlignmentRunController.swift:149`), so as specified every run would fall back to the by-ear questions. |
| C. Musical or stepped sweep on the Mac lane, plus a guard against a second peak near the true one | Stepped sweep alone: `SyncProbeCorrelator.swift` (`value(_:at:)` gains a note table), tests, ADR. Guard: `SyncProbeCorrelator.swift` (~12 lines), `ProbeAnalyzer.swift` (~3), `MicProbeSession.swift` (~8), phone `AlignmentRunController.swift` + `RoomListening.swift` (~6), one new test in each repo. | Stepped sweep alone: package tag + 2 pins. With the guard: all three repos. | Stepped sweep: same as A, plus any test that pins a sweep's shape. Guard: additive, breaks nothing; needs 3 new tests. | **M**: a stepped sweep keeps a closed-form `value(_:at:)`, so the test helpers and rate independence survive; the guard is ~30 lines but its threshold has to be set from real captures. Plucked melodies inside today's bands (bench row 4c) would be **L**. | Pentatonic stepping left a rival peak at 76% of the true one (peak margin 1.32). Nothing in either app reads `peakMargin` today. A guard threshold strict enough to catch that also risks refusing a clean sweep with a strong early wall or desk reflection, unless it looks only ahead of the peak (see section C). |
| D. Tick timbre (by-ear clicks) | `AlignmentTickInjector.swift` (constants and `renderTick`), `BTAlignmentWizardView.swift:69-70` (copy names the two sounds), `AlignmentTickInjectorTests.swift`, `PopoverBTAlignmentUITests.swift:254`, `dev/notes/wizard-tick-stimulus-brief.md`. 5 files. | Mac only | Colour-only change: `AlignmentTickInjectorTests.swift:394-419` (pins 0.863). Envelope or length change: also `:45-56`, `:247`, `:290`. Copy change: `PopoverBTAlignmentUITests.swift:254`. | **S** for new partials at the same envelope; **M** if the envelope or length changes, because the by-ear estimator's listener model was tuned on this tick and the swap test (two wizard runs) has to be re-run. | The tick is also the row's "Play ticks" metronome and the phone's by-ear session (both rendered by the Mac), so a change reaches three places at once. A shape difference between the two sides biases the stored latency by the perceived-onset difference, permanently. |
| E. Cross-cutting (copy, analytics, spike, night driver, fixtures) | Copy: only tick copy on the Mac names a sound. Analytics: no event names a stimulus. Spike CLI: 6 call sites. Night driver and fixtures: none. | Follows the class | None of their own. | **S** | No analytics property says which stimulus produced a measurement, so a before/after comparison of `bt_sync:listening_ended` outcomes cannot separate versions without a new property (which must be added to `audiout-shared/docs/analytics-events.md` first). |

Two numbers from the bench need care before reading confidence figures against the app gates. The bench set its room noise so today's sweep scores about 30 (`04-experiments.md` method step 6). Live genuine readings score far higher: 96.1 to 3425 on the phone (`AlignmentRunController.swift:141-143`), 684 to 1724 on the Mac (`MicProbeSession.swift:487-490`). So compare candidates to today's sweep as ratios, and treat the no-noise column as a hard ceiling that no room improves.

## A. New band, direction or fade

**Where the numbers live.** Only one place in all three repos:

- `audiout-shared/Sources/ProbeKit/SyncProbeCorrelator.swift:77-80`: `upSweep` = 3,200 to 10,000 Hz, fade 0.08 s.
- `audiout-shared/Sources/ProbeKit/SyncProbeCorrelator.swift:84-87`: `downSweep` = 2,000 to 500 Hz, fade 0.08 s.
- The type note at `SyncProbeCorrelator.swift:38-59` explains the disjoint bands, the guard gap, the high band going to the far speaker and the 500 Hz-10 kHz limits. It has to be rewritten to match.

Grep for `3_200`, `10_000`, `2_000`, `500` near probe code found no other copy: none in the Mac app (`MicProbeSession.swift`, `AlignmentTickInjector.swift`, `NativeBackend+Bluetooth.swift`, `mic-probe-spike/main.swift`, `dev/drift-window-analysis.py`), none in the phone (`AudioutRemote/Model/*`). Both apps call `SyncProbe.SweepDesign.downSweep/upSweep` and get whatever the package says:

- Mac staging: `AudioutCore/Sources/AudioutCore/AlignmentTickInjector.swift:449-458`.
- Mac analysis: `AudioutCore/Sources/AudioutCore/MicProbeSession.swift:462-465`.
- Phone analysis: `audiout-shared/Sources/ProbeKit/ProbeAnalyzer.swift:102-105`, called from `audiout-remote/AudioutRemote/Model/ProbeSession.swift:246`.
- Dev CLI: `AudioutCore/Sources/mic-probe-spike/main.swift:81-82, 116-117, 331-332`.

**Prose that restates today's bands** (update with the change, no code effect): `audiout-shared/AGENTS.md:13` (`CLAUDE.md` is a symlink to it), and `audiout-shared/docs/adr/0001-quieter-sweeps.md`, which ends "never a change to the bands or the sweep direction, which the lane separation depends on". A band change overrides that sentence, so it needs a new ADR (`docs/adr/0002-...`) saying why.

**Fade and level.** The fade is in `SweepDesign` (`SyncProbeCorrelator.swift:73`), so it ships as a tag. The level is not: `SweepDesign` has no amplitude (ADR 0001). Level lives in the Mac only, `AlignmentTickInjector.swift:481` (`probeEngineLaneScale` 0.5) and `:489` (`probeAmplitude` 0.175), and can change without a tag.

**Tests.**

- `audiout-shared/Tests/ProbeKitTests/ProbeAnalyzerTests.swift:209-215` pins `2_000`, `500`, `3_200`, `10_000` by value. Edit it.
- `audiout-shared/Tests/ProbeKitTests/SyncProbeCorrelatorTests.swift:221-233` requires the high band's bottom to be at least 1.25x the low band's top (today 3,200 / 2,000 = 1.6).
- `ProbeAnalyzerTests.swift:34-37` renders most scenes at 24 kHz "while still clearing the 10 kHz top". A top edge at or above 12 kHz would alias in those scenes.
- `SyncProbeCorrelatorTests.swift:193-219` and `:235-272` (the 23 dB imbalance scene) use the shipping designs and re-validate the new bands for free.
- Mac `AlignmentTickInjectorTests.swift:857-858, 908-909, 957-958` and `MicProbeSessionTests.swift:57-65, 197-211` build their expectations from the same factories and need no edit.

**How it ships** (`audiout-shared/AGENTS.md` "Rules", Mac `AGENTS.md:53-68`, `audiout-remote/AGENTS.md` "Shared-code changes"):

1. Edit in `~/Projects/audiout-shared`, never in a consumer.
2. `swift test` there by hand. That repo has no hooks and no wrapper scripts.
3. `git tag 0.20.0 && git push origin main --tags`. No `CompanionProto.version` bump: no message changes.
4. In the same session, bump both pins:
   - Mac: `AudioutCore/Package.swift:182-183` (`from: "0.19.0"`) and `AudioutCore/Package.resolved:5-11`. Lands through a pull request, `scripts/review-branch.sh` and the merge queue. Guard 4 runs the matching suites on commit.
   - Phone: `audiout-remote/AudioutRemote.xcodeproj/project.pbxproj:613-616` (`upToNextMajorVersion`, `minimumVersion = 0.19.0`) and `audiout-remote/AudioutRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:5-11`. No CI. Verified on the owner's physical iPhone 15 Pro (standing rule in `audiout-remote/AGENTS.md`); `scripts/mule-test.sh` for headless runs.

**Effort: S.** The cost is the release ceremony and a live listen, not the code.

## B. Band-limited noise ("whoosh")

**What assumes a sweep today.**

- Synthesis is a closed formula evaluated at time `t` (`SyncProbeCorrelator.swift:94-114`, Farina's phase law in plain Foundation `sin`/`exp`, no vDSP). `samples(_:)` (`:117-126`) is `value` on a sample grid and carries a sweep-only precondition (`:118-119`, "an exponential sweep needs two positive, distinct band edges").
- `value(_:at:)` is public so tests can place an arrival at a fractional sample delay analytically (`:90-93`). Every scene builder uses it: `SyncProbeCorrelatorTests.swift:44-69`, `ProbeAnalyzerTests.swift:42-73`, Mac `MicProbeSessionTests.swift:57-65` and `:197-211`. A noise generated sample by sample has no value between samples, so either the generator is made continuous (below) or every one of those helpers is rewritten to resample.
- The correlator itself is signal-agnostic: FFT cross-correlation, optional ambient-noise weighting, whitening exponent left at 0 for the probe (`:420-426`). The reverb shadow (`:197`, 250 ms after the peak) and sidelobe exclusion (`:186`, 5 ms) were sized for a sweep's narrow peak. Neither has to change for a noise in today's bands; the comment at `:184-185` names "the sweep autocorrelation's own skirt" and needs rewording.
- The confidence score (`:374-379`) assumes the background is mostly room noise. A random probe adds its own correlation ripple, which is why the bench's whoosh reference lane stops at 16-17 with no room noise (`04-experiments.md` row 2a). The two-swell and three-swell variants reached 13 and 22.

**The acceptance floors are where B fails as specified.**

- Mac: `MicProbeSession.swift:487-500`, `minConfidence = 20`, applied in `accepting(_:)` together with `|deltaMs| <= 2,000` (`NativeBackend+Bluetooth.swift:174`). Its comment records two false matches from 2026-09-26, at 7.2 and 55.3, and a true reading under a music tail at about 23, so 20 is already squeezed between them. Lowering it for a noise probe moves it toward the 7.2 false match.
- Phone: `AlignmentRunController.swift:138-155`, `minConfidence = 25`, set from twelve logged sweep runs. `RoomListening.swift:144` (`CannedRoom.demoMeasurement`, confidence 30) has to stay above it. Its test: `AlignmentRunControllerTests.swift:130-144` pins 24.9 / 25 / 5.1 / 96.1.
- Both floors were set from sweep data. A noise probe needs new live runs on both mics to set new floors, or a longer or wider noise whose no-noise ceiling clears 25 with room to spare.

**Three sample rates are in play, and a noise must match at all three.**

- Mac staging renders at the injector's rate: `AlignmentTickInjector(config:)` at `NativeCaptureCoordinator.swift:1375` takes the default `sampleRate: 44_100` (`AlignmentTickInjector.swift:278`).
- Mac analysis re-renders the template at the built-in mic's hardware rate (`MicProbeSession.swift:124, 462-465`).
- Phone analysis renders at its input tap's own rate, 48 kHz or 44.1 kHz (`audiout-remote/AudioutRemote/Model/ProbeCaptureSession.swift:60-67`; `ProbeAnalyzer.swift:50-52`: "recreated locally at the capture's own sample rate").

A sweep survives this because it is a formula in `t`. A noise drawn from a seeded per-sample generator at 44.1 kHz is a different signal from the same seed at 48 kHz. Two workable shapes, both inside ProbeKit:

1. Generate the noise once at a fixed design rate from a fixed seed, and make `value(_:at:)` reconstruct between samples with a windowed-sinc kernel. Keeps the test helpers and rate independence; costs about 32 multiply-adds per output sample.
2. Define it as a sum of sinusoids with seeded phases on a grid no coarser than 1 / duration (1 Hz for 1 s). Exact at any rate. A coarser grid repeats inside the search window: the bench's 50 Hz multisine locked exactly 20.00 ms off once (`04-experiments.md`, row 5). At 1 Hz across 3.2-10 kHz that is about 6,800 sines per sample, too slow on a phone without a recurrence.

vDSP: the correlator uses `vDSP.DFT` only (`SyncProbeCorrelator.swift:449-453`), and each app's correlation is self-contained, so arm64 Mac versus iPhone rounding does not matter there. Synthesis must not depend on vDSP or on stdlib randomness (see Traps).

**Level.** The Mac scales the unit-peak template by `probeAmplitude` (`AlignmentTickInjector.swift:445-448`). A noise at today's peak plays about 12 dB lower in average level (crest factor 15-20 dB against the sweep's 3.5 dB, `04-experiments.md`), cutting confidence about 4x. Matching today's average level instead needs about 5x the peak, which hits `Int16(clamping:)` in `render` (`AlignmentTickInjector.swift:703, 711`) once ticks or the keep-alive are summed in. Clipped peaks make the played signal differ from the template. ProbeKit has to state whether its template is peak- or average-normalised, and the Mac's two level constants get re-judged by ear (ADR 0001's method).

**Call sites that change if the API changes** (they survive untouched if the noise hides behind the same `downSweep`/`upSweep` factory names, which would be misleading naming):

- `AlignmentTickInjector.swift:445-458` (stageProbe), `MicProbeSession.swift:462-465`, `ProbeAnalyzer.swift:102-105`, `mic-probe-spike/main.swift:81-82, 116-117, 331-332`.
- The shared-leak guards in the Mac (`.githooks/guard-shared-leak.sh:31`) and the phone (`audiout-remote/.githooks/guard-shared-leak.sh:30`) list ProbeKit's public type names. A new public type (for example a stimulus enum) should be added to both lists, or a hand-copy of it will not be caught.

**Tests that break.** ProbeKit: every test using `SyncProbe.value` (all of `ProbeAnalyzerTests`, 11 tests; the shipping-design scenes in `SyncProbeCorrelatorTests`, `:193-272`; `:84-95` pins "samples(_:) is value(_:at:) on the sample grid"; `:221-233` reads `startHz/endHz`). The fast 8 kHz sweeps (`:71-80`) only exercise the filter and can stay. Mac: `AlignmentTickInjectorTests.swift:832-990` (three staging tests compare against `SyncProbe.samples`), `MicProbeSessionTests.swift:57-65, 197-211` (scene builders). Phone: the gate test above if the floor moves.

**Effort: L.**

## C. Musical or stepped sweep, and a second-peak guard

**Stepped sweep (semitones or a scale) on the Mac lane.** The frequency path becomes a list of held notes joined by 10 ms glides. Phase is the integral of frequency, so it stays a closed form: a precomputed table of each segment's start time and start phase, and `value(_:at:)` finds the segment and evaluates it. That keeps rate independence and every test helper. Changes:

- `SyncProbeCorrelator.swift:64-88` (`SweepDesign` gains a note list or a step rule; `:94-114` evaluates it). The precondition at `:118-119` still holds.
- Same tests as A, plus a new test that a stepped design's `samples` equal `value` on the grid.
- Ships as a tag + 2 pins, no app source change, if it stays behind `downSweep()`.

Bench (`04-experiments.md` rows 3a, 3b): semitones scored 141 / 29 against today's 150 / 31; pentatonic 105 / 23 with a peak margin of 1.32. Plucked phrases kept inside today's bands (row 4c) scored 53 / 14 with a no-noise ceiling of 63 / 24, so the target lane cannot reach the phone's floor of 25 in any room: that variant is class B's problem, effort L.

**Where confidence is computed and where it is judged.**

- Computed: `SyncProbeCorrelator.swift:301-370`, `arrival(inCorrelation:...)`. Score at `:318-327` (background outside [peak - 5 ms, peak + 250 ms], `score` at `:374-379`). `peakMargin` already exists at `:344-353`: peak over the best lag more than 3 ms away (`peakMarginSeparationSeconds`, `:216`) anywhere in the searched range.
- Reduced: `ProbeAnalyzer.swift:120-122` (phone) and `MicProbeSession.swift:476-478` (Mac) keep only `min(peakToSidelobe)` of the two lanes. `peakMargin` is dropped on both paths. The only reader of `peakMargin` is `PassiveDriftCorrelator.swift:581` (drift tracking, not the wizard).
- Accept/refuse: Mac `MicProbeSession.accepting(_:)` at `MicProbeSession.swift:494-500` (confidence 20, plausibility 2,000 ms); result handed to `PopoverController+BTWizard.swift:389-397` → `BTAlignmentWizardSession.offerMeasuredProposal`. Phone `AlignmentRunController.isMeasurable(confidence:)` at `:153-155`, called at `:298`.

**What a "nearest rival within ±50 ms" guard needs.**

1. `SyncProbeCorrelator.swift`: one property beside `:216` (`nearRivalHalfWidthSeconds = 0.05`), one field on `Arrival` (`:223-252`), and a second runner-up loop next to `:347-353` restricted to `max(lo, peak - w) ..< min(hi, peak + w + 1)`. About 12 lines. Additive: `Arrival` is only constructed at `:368`, and `PassiveDriftCorrelator` keeps reading the old field.
2. `ProbeAnalyzer.swift:10-20, 120-122`: add the weaker lane's value to `ProbeAnalysis`. About 3 lines. Public API addition, so a minor tag.
3. Mac `MicProbeSession.swift:288-296` (`Result` field), `:476-478`, and a check in `accepting` at `:496`. About 8 lines.
4. Phone `RoomListening.swift:61` and `:118` (carry the field), `:144` (demo value), `AlignmentRunController.swift:153-155` and `:298`. About 6 lines.
5. Tests: one ProbeKit scene with a planted rival at +10 ms, one `MicProbeSessionTests` accept/refuse case beside `:178-188`, one phone case beside `AlignmentRunControllerTests.swift:130-144`. Mac Guard 11 wants each new test's "turns red" sentence.

Total roughly 30 lines of code over three repos.

**The threshold is the hard part.** Real reflections are rivals too. The bench's echoes (gain 0.2-0.5) already hold today's sweep at a median margin of 3.64; a desk bounce at -3 dB would put a clean sweep near 1.4, close to the pentatonic's 1.32. Option worth testing: search for the rival only **before** the peak. The correlator already reasons that nothing physical arrives ahead of the direct path (`:188-197`), while a stepped sweep's own false peaks sit on both sides. Calibrate against real captures: three dumps from 2026-08-28 are in `~/Library/Logs/Audiout/mic-probe-*.f32` (written when `AUDIOUT_MIC_PROBE_DUMP=1`, `MicProbeSession.swift:369-386`).

**Effort: M** (stepped sweep S, guard plus calibration M).

## D. Tick timbre

All in the Mac, `AudioutCore/Sources/AudioutCore/AlignmentTickInjector.swift`:

- `:121` `brightPartialHz = (1_800, 2_900)`, `:126` `lowPartialHz = (900, 1_450)`.
- `:151-152` `brightLoudnessScale`, computed from A-weighting (`:161-174`) at the 0.7 / 0.3 partial mix. It follows new partials automatically, but the doc comment at `:128-149` quotes the measured A-weights and the 0.863 result.
- `:157-158` `swapsWizardTimbres` (`AUDIOUTER_DEBUG_TICK_SWAP=1`), the bias measurement described at `:59-66`.
- `:303-325` `renderTick`: 30 ms, tau 6 ms, 8 attack samples, `0.7 sin(f1) + 0.3 sin(f2)`. The comment at `:303-312` is the rule: both timbres share one envelope and frame count so their onsets are sample-identical.
- `:278-301` `init`: amplitude 0.35, rendered at 44.1 kHz.
- Who hears which: `mixWizardVariants` at `:636-637` (engine side low, Bluetooth side bright). The row metronome and the phone's by-ear session use the bright tick only (`mix` at `:593`).

Copy that names the sounds: `AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:69-70` ("a bright click", "a low knock"), used at `:61-66`. Generic click copy (`:49`, `:138`, `:157`, `:174`, the drawer's "Play ticks" at `BTSyncDrawerView.swift:310`) survives any timbre.

Tests that pin the waveform (`AudioutCore/Tests/AudioutCoreTests/`):

- `AlignmentTickInjectorTests.swift:394-419`: `brightLoudnessScale` within 0.002 of 0.863, and the rendered ratio matches it.
- `:365-382`: the two variants share an onset sample and differ. Must stay true.
- `:43-56`: at 1 kHz the tick is 30 frames (`samples[30..<100]` silent). Breaks on a longer tick.
- `:247`: "Past the 30 ms tick body (1 323 frames)".
- `:290`: `tickPeak = 0.35 * 0.7 * 32_767`, the first partial's weight.
- `PopoverBTAlignmentUITests.swift:254`: the full "You'll hear a bright click from ... and a low knock from ..." sentence.

The iPhone does **not** render or play ticks. Grep of `audiout-remote/AudioutRemote` for `renderTick`, `metronome`, `AVAudioPlayerNode`, `AudioServicesPlay` returns nothing; its tick code (`SyncSheetModel.swift:262, 482-504`) only asks the Mac to start and stop a tick session. Phone copy says "speaker clicks" (`SyncSheetCopy.swift:44-81`, `SyncSheet.swift:481-482`), which survives any timbre.

Design record: `dev/notes/wizard-tick-stimulus-brief.md` (§1 waveform, §3 bias analysis, §5 recommendation: "Do not widen the difference between the two sounds"). The by-ear estimator's listener model (`c = 4 / λ = 0.06`, `AudioutCore/Sources/AudioutPopoverUI/AGENTS-HISTORY.md:57`) was tuned with this tick.

**Effort: S** for new partials, **M** if the envelope or length changes. Ships Mac only.

## E. Cross-cutting

**Copy.** The Mac's probe screens never describe the sound ("Listening to your speakers", "Keep the room quiet for a few seconds", `BTAlignmentWizardView.swift:243-249`). The phone says "Playing the test sounds" (`AlignmentRunController.swift:56`) and "Audiout plays short sounds" (`ConnectGateView.swift:1014`). No probe change needs copy, unless it grows long enough that "short" stops being true. The phone's "About N seconds" is derived: `SyncSheetCopy.swift:253-256` = lead-in + `ProbeAnalyzer.sweepSeconds * 2` + tail. Only tick copy names sounds (class D).

**Analytics.** Event names untouched by any class. Relevant events: Mac `bt_sync:wizard_started` (`PopoverController+BTWizard.swift:345`), `bt_sync:listening_ended` with `outcome` measured / implausible / failed (`BTAlignmentWizardSession.swift:407, 482`), `bt_sync:mic_retried` (`:552, 574`); phone `sync:measure_tapped` and `sync:verdict` (`SyncSheetModel.swift:759, 830, 844`). The `failed` share of `listening_ended` and the `refused` share of `sync:verdict` are the before/after measure for a probe change. Neither carries a stimulus version; adding one is an additive property, listed first in `audiout-shared/docs/analytics-events.md` (rows at `:91-95, :116-117`). No `Telemetry.fail` sits on the probe path; `MicProbeSession.swift:388-399` writes local `Telemetry.log` lines only.

**mic-probe-spike CLI.** `AudioutCore/Sources/mic-probe-spike/main.swift` plays and correlates the sweeps itself (`:81-82, 116-117, 331-332`) with its own `--duration` (`:39`). Follows class A for free; needs edits for B or a renamed API.

**Night driver on the mule.** `dev/listening/unattended-night.sh` plays its own click-track WAV (`:75-79`, `click-track-3s.wav`) and synthesises fallback clicks in Python (`:458-467`). It stages neither the wizard probe nor the wizard tick. Unaffected.

**Fixtures.** `audiout-shared/Tests/ProbeKitTests/Fixtures/*.i16` are passive-drift music windows (`audiout-shared/AGENTS.md`, "Tests"), not sweep captures, read by `PassiveDriftFixtureTests`. No test fixture embeds today's sweep. The only recorded sweep captures are the three local dumps in `~/Library/Logs/Audiout/`, untracked.

## Traps

1. **Three hand-copied sweep lengths.** `AlignmentTickInjector.probeSweepSeconds` (`AlignmentTickInjector.swift:380`), `MicProbeSession.sweepSeconds` (`MicProbeSession.swift:303`, test `MicProbeSessionTests.swift:147-149`) and `ProbeAnalyzer.sweepSeconds` (`ProbeAnalyzer.swift:62`, test `ProbeAnalyzerTests.swift:201-204` pins it to 1.0 by value). The package cannot import the Mac (`audiout-shared/AGENTS.md`, ProbeKit rules), so all three move by hand. `probeStaggerSeconds` (2.0, `AlignmentTickInjector.swift:390`) must stay longer than the sweep, and the Mac subtracts it from the phone's report (`NativeBackend+Bluetooth.swift:1758`).
2. **No version check between the two apps' probes.** `AudioutProtocol` has no field saying which probe design is playing (`alignmentProbeStarted(deviceID:)` only, `CompanionMessage.swift:59`). ADR 0001: "A Mac on the old sweep and a phone on the new one correlate against different signals and report a confident wrong number." The Mac ships through Sparkle and the phone through the App Store, so users will run mixed versions. A class A edge change is the worst case (a mismatched sweep moves the peak); a class B or C change mostly produces a refusal. Fix options: an additive message field carrying a design number (no `CompanionProto.version` bump), or accept the window as ADR 0001 did.
3. **Lane assignment flips the sign silently.** DOWN is reference, UP is target (`ProbeAnalyzer.swift:95-105`, `audiout-shared/AGENTS.md`). Swapping which design goes to which lane reverses every measurement with no failure. `ProbeAnalyzerTests.swift:209-215` is the only pin.
4. **Disjoint bands with a guard gap are mandatory** whatever the sound (`SyncProbeCorrelator.swift:38-50`; `04-experiments.md`: shared-band whoosh, Golay and plucks all fail under the 23 dB imbalance). `SyncProbeCorrelatorTests.swift:221-233` enforces 1.25x.
5. **Determinism of a noise probe.** Three different render rates (trap 6 below). Swift's `Double.random(in:using:)` maps generator bits to a double by a stdlib algorithm with no promise of stability across Swift releases, and the Mac and phone build with different Xcode versions (the mule runs the Xcode 27 beta, CLAUDE.md). Turn the seed's `UInt64` into a `Double` by hand. The seeded generator (SplitMix64) exists only as a private test type today (`SyncProbeCorrelatorTests.swift:20-30`, `ProbeAnalyzerTests.swift:22-32`); production needs its own copy inside ProbeKit.
6. **Sample rate.** Mac stages at 44.1 kHz (`NativeCaptureCoordinator.swift:1375` → `AlignmentTickInjector.swift:278`), Mac analyses at the mic's rate (`MicProbeSession.swift:124`), phone at its tap's rate (`ProbeCaptureSession.swift:60-67`, which warns that a 48,000 vs 44,100 slip scales every reading by 8.8%). Any stimulus must be defined in continuous time.
7. **Level is the Mac's, not the package's** (ADR 0001). A peakier stimulus needs a written normalisation rule in ProbeKit and a new by-ear level in `AlignmentTickInjector.swift:481, 489`, and the sum with ticks and keep-alive is clamped to `Int16` (`:703, 711`). The phone run plays the engine lane at full level (`engineLaneScale: 1`, `NativeCaptureCoordinator.swift:1478-1481`).
8. **The flat-prior fence.** A probe measurement becomes the wizard's PROPOSAL, never part of the estimator's belief (`BTAlignmentPosterior.swift:320-330`; `MicProbeSessionTests.swift:242-245`). That limits the damage of a confident wrong reading from a new stimulus: the user hears the proposal with ticks and can reject it. Do not answer a lower-confidence stimulus by feeding its score into the prior.
9. **The acceptance floors were set from sweep data.** Mac 20 (`MicProbeSession.swift:487-492`), phone 25 (`AlignmentRunController.swift:138-149`, marked `razor:` pending more logged runs). Any class B or C change re-opens both.
10. **Licence.** ProbeKit is MIT and every file carries `SPDX-License-Identifier: MIT`. The Mac's `AlignmentTickInjector.swift` is GPL (`:1`). Moving tick or level code into ProbeKit means retyping it fresh, never copying (`audiout-shared/AGENTS.md`: "never copy code in from a GPL sibling"). Single authorship: no outside patches. Zero dependencies in the package, ever, so no DSP library for noise generation. The phone may never take code from `AudioutCore` (`audiout-remote/AGENTS.md`).
11. **Shared-leak guards list public type names by hand** (`.githooks/guard-shared-leak.sh:31` in the Mac; `audiout-remote/.githooks/guard-shared-leak.sh:30` in the phone). A new public ProbeKit type is not protected until it is added to both lists.
12. **Tick shape is the one thing the two sides may never differ in** (`AlignmentTickInjector.swift:303-312`). Change partials freely; change the envelope only on both timbres together, then re-run the swap test (`:59-66`): half the difference between a normal and a swapped run is the bias, and it must stay under about 2 ms.
13. **audiout-shared's working tree is not clean.** `CONTEXT.md` and `docs/analytics-events.md` carry uncommitted edits from another session. A builder tagging a release there must not sweep them into the tag commit.
14. **audiout-shared has no hooks and no CI for these tests** (`audiout-shared/AGENTS.md`, "Tests"). Nothing runs `swift test` for you before the tag.
