// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// The align-by-ear tick (BT-OFFSET-UI): the injector's pure beat math, and —
/// through a fully synthetic `NativeCaptureCoordinator` harness (fake tap +
/// scripted converter + spy fan-out consumer, no real audio, no devices, the
/// `BTFanoutTests` house style) — the seam that mixes the tick into the ONE
/// converted feed every consumer shares.
@Suite final class AlignmentTickInjectorTests: IsolatedSuite {

    // MARK: Pure injector — beat spacing, self-limit

    /// S16LE stereo frames of `data` on channel 0.
    private func channel0(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            return stride(from: 0, to: p.count, by: 2).map { Int16(littleEndian: p[$0]) }
        }
    }

    private func zeroBuffer(frames: Int, channels: Int = 2) -> Data {
        Data(count: frames * channels * MemoryLayout<Int16>.size)
    }

    @Test func beatSpacingDodgesTheTrimRangeAlias() {
        let injector = AlignmentTickInjector()
        // 72 BPM at 44.1 kHz — and NEVER 500 ms: a ±500 ms trim range would
        // alias a fully-offset device as aligned one beat late at 120 BPM.
        #expect(injector.test_beatFrames == 36_750)
        let beatMs = Double(injector.test_beatFrames) / 44.1
        #expect(beatMs > BTSyncTrim.rangeMs + 100,
                "the beat interval must clear the whole trim range with margin")
    }

    @Test func ticksLandOnTheConfiguredBeatAndNowhereElse() {
        // Small synthetic clock so one buffer spans several beats: 1 kHz,
        // 600 BPM → a tick every 100 frames; the tick itself is 30 frames.
        let injector = AlignmentTickInjector(sampleRate: 1_000, config: .init(bpm: 600, maxTicks: 3, bedEnabled: false))
        #expect(injector.test_beatFrames == 100)
        var pcm = zeroBuffer(frames: 250)
        injector.mix(into: &pcm)
        let samples = channel0(pcm)

        #expect(samples[1...29].contains { $0 != 0 }, "first tick rings at beat 0")
        #expect(samples[30..<100].allSatisfy { $0 == 0 }, "silence between ticks")
        #expect(samples[100...129].contains { $0 != 0 }, "second tick at exactly one beat")
        #expect(samples[130..<200].allSatisfy { $0 == 0 })
        #expect(samples[200...229].contains { $0 != 0 }, "third tick on the next beat")
    }

    @Test func beatClockCarriesAcrossBufferBoundaries() {
        let injector = AlignmentTickInjector(sampleRate: 1_000, config: .init(bpm: 600, maxTicks: 4, bedEnabled: false))
        // Deliver 60 + 60 frames: the second tick starts at absolute frame 100,
        // i.e. 40 frames INTO the second buffer.
        var first = zeroBuffer(frames: 60)
        injector.mix(into: &first)
        var second = zeroBuffer(frames: 60)
        injector.mix(into: &second)
        let samples = channel0(second)
        #expect(samples[0..<40].allSatisfy { $0 == 0 }, "no tick before the beat boundary")
        #expect(samples[40...59].contains { $0 != 0 }, "the beat lands mid-buffer, on the absolute clock")
    }

    @Test func stopsEmittingAfterMaxTicks() {
        let injector = AlignmentTickInjector(sampleRate: 1_000, config: .init(bpm: 600, maxTicks: 2, bedEnabled: false))
        var pcm = zeroBuffer(frames: 400)
        injector.mix(into: &pcm)
        let samples = channel0(pcm)
        #expect(samples[0...29].contains { $0 != 0 })
        #expect(samples[100...129].contains { $0 != 0 })
        #expect(samples[200...399].allSatisfy { $0 == 0 },
                "the injector self-limits — after maxTicks beats it emits silence")
    }

    @Test func mixAddsOntoProgramAudioInsteadOfReplacingIt() {
        let injector = AlignmentTickInjector(sampleRate: 1_000, config: .init(bpm: 600, maxTicks: 1, bedEnabled: false))
        var pcm = zeroBuffer(frames: 100)
        pcm.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<p.count { p[i] = 1_000 }   // flat program signal
        }
        injector.mix(into: &pcm)
        let samples = channel0(pcm)
        #expect(samples[50..<100].allSatisfy { $0 == 1_000 },
                "off-beat samples keep the program audio untouched")
        #expect(samples[1...29].contains { $0 != 1_000 },
                "on-beat samples are program + tick, never a replacement")
    }

    /// The wizard's opposite rule (owner's call): while the guided run is
    /// going the user is judging which speaker ticked first, so the music is
    /// REPLACED rather than ticked over.
    @Test func wizardModeReplacesTheProgramWithTicksOnly() {
        let injector = AlignmentTickInjector(
            sampleRate: 1_000,
            config: .init(bpm: 600, maxTicks: 1, bedEnabled: false, replacesProgram: true))
        var pcm = zeroBuffer(frames: 100)
        pcm.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<p.count { p[i] = 1_000 }   // flat program signal
        }
        injector.mix(into: &pcm)
        let samples = channel0(pcm)
        #expect(samples[50..<100].allSatisfy { $0 == 0 },
                "off-beat frames carry no music — only the ticks are heard")
        #expect(samples[1...29].contains { $0 != 0 }, "the ticks themselves are still there")
    }

    /// …and the music comes back the moment the run's budget runs out, without
    /// anything having to switch the injector off.
    @Test func theProgramReturnsPastTheWizardBudget() {
        let injector = AlignmentTickInjector(
            sampleRate: 1_000,
            config: .init(bpm: 600, maxTicks: 1, bedEnabled: false, replacesProgram: true))
        var pcm = zeroBuffer(frames: 200)
        pcm.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<p.count { p[i] = 1_000 }
        }
        injector.mix(into: &pcm)
        let samples = channel0(pcm)
        #expect(samples[100..<200].allSatisfy { $0 == 1_000 },
                "past the last beat the captured program passes through untouched")
    }

    // MARK: Keep-alive bed + wake preamble (W2 — the Sonos amp-gate fix)

    /// dBFS RMS of one S16LE channel.
    private func dBFS(_ samples: some Collection<Int16>) -> Double {
        let normalized = samples.map { Double($0) / 32_768.0 }
        let rms = (normalized.map { $0 * $0 }.reduce(0, +) / Double(normalized.count)).squareRoot()
        return 20 * log10(max(rms, 1e-12))
    }

    /// The keep-alive tone's expected sample at absolute frame `position` —
    /// the injector's own loop table, re-derived so a test can both predict it
    /// and subtract it back out.
    private func toneSample(at position: Int, sampleRate: Double = 44_100) -> Int16 {
        let period = Int((sampleRate / AlignmentTickInjector.Config.toneHz).rounded())
        let peak = pow(10, AlignmentTickInjector.Config.toneRMSdBFS / 20) * 2.0.squareRoot()
        return Int16(clamping: Int32(
            (peak * sin(2 * .pi * Double(position % period) / Double(period)) * 32_767.0).rounded()))
    }

    /// One whole run's worth of the wizard's Bluetooth variant, channel 0.
    /// Unarmed, so it is keep-alive and nothing else.
    private func keepAliveRun(blocks: Int, framesPerBlock: Int,
                              sampleRate: Double = 44_100) -> (all: [Int16], boundaries: [Int]) {
        let injector = AlignmentTickInjector(sampleRate: sampleRate, config: .wizard)
        var all: [Int16] = []
        var boundaries: [Int] = []
        for _ in 0..<blocks {
            var pcm = zeroBuffer(frames: framesPerBlock)
            var bedded = Data()
            injector.mixWizardVariants(into: &pcm, bedded: &bedded)
            if !all.isEmpty { boundaries.append(all.count) }
            all += channel0(bedded)
        }
        return (all, boundaries)
    }

    /// The keep-alive the Bluetooth variant carries is a ~20 Hz sine at
    /// −40 dBFS RMS and NOTHING else — the fix for the live run's "the static
    /// gets louder as the test goes on" (2026-08-22). Exact, because the loop
    /// table is one whole cycle indexed by the absolute frame position.
    @Test func theKeepAliveIsALowToneAndNothingElse() {
        let run = keepAliveRun(blocks: 40, framesPerBlock: 512)
        #expect(abs(dBFS(run.all) - AlignmentTickInjector.Config.toneRMSdBFS) < 0.5,
                "keep-alive ≈ −40 dBFS RMS, measured \(dBFS(run.all))")

        #expect(run.all == (0..<run.all.count).map { toneSample(at: $0) },
                "the Bluetooth variant carries the tone and nothing else")

        // DC-free — measured over WHOLE cycles, which is the only window in
        // which "a sine has no DC" is a statement about the signal rather than
        // about where the window happened to stop.
        let period = Int((44_100 / AlignmentTickInjector.Config.toneHz).rounded())
        let wholeCycles = run.all.prefix((run.all.count / period) * period)
        #expect(wholeCycles.count >= period)
        #expect(wholeCycles.reduce(0) { $0 + Int($1) } == 0,
                "no DC offset over \(wholeCycles.count / period) cycles")
    }

    /// Phase-continuous across block boundaries: the pacer renders 512 frames at
    /// a time and the tone must not restart at each one. A 20 Hz sine at this
    /// level moves at most ~1.4 LSB per sample, ANYWHERE — including the step
    /// from the last sample of one block to the first of the next.
    @Test func theKeepAliveHasNoDiscontinuityAtBlockBoundaries() {
        let run = keepAliveRun(blocks: 40, framesPerBlock: 512)
        let maxStep = (1..<run.all.count)
            .map { abs(Int(run.all[$0]) - Int(run.all[$0 - 1])) }.max() ?? 0
        #expect(maxStep <= 2, "largest sample step \(maxStep) — the tone is continuous")
        for boundary in run.boundaries {
            #expect(abs(Int(run.all[boundary]) - Int(run.all[boundary - 1])) <= 2,
                    "step across the block boundary at \(boundary)")
        }
    }

    /// H1, the live run's "the static gets louder": the keep-alive is rendered
    /// from a loop table into a FRESH block every pacer fire, so it is the SAME
    /// signal on the last block of a run as on the first — nothing accumulates
    /// and nothing climbs toward clipping. 2 000 blocks ≈ 23 s of run, across
    /// the search → blocks tempo change.
    ///
    /// Subtracting the expected tone is what makes this exact rather than
    /// statistical: a block that carries no tick must come back ALL ZEROES, at
    /// block 2 000 exactly as at block 1. A keep-alive that grew by even one LSB
    /// would leave a residual in every block and take this count to nothing.
    @Test func theKeepAliveLevelNeverGrowsAcrossALongRun() {
        let injector = AlignmentTickInjector(sampleRate: 44_100, config: .wizard)
        injector.armTicks()
        var position = 0
        var tickFreeBlocks = 0, tickBlocks = 0, loudest = 0
        for block in 0..<2_000 {
            var pcm = zeroBuffer(frames: 512)
            var bedded = Data()
            injector.mixWizardVariants(into: &pcm, bedded: &bedded)
            let samples = channel0(bedded)
            loudest = max(loudest, samples.map { abs(Int($0)) }.max() ?? 0)
            let residual = samples.enumerated().map {
                Int32($0.element) - Int32(toneSample(at: position + $0.offset))
            }
            if residual.allSatisfy({ $0 == 0 }) { tickFreeBlocks += 1 } else { tickBlocks += 1 }
            position += samples.count
            if block == 900 { injector.setTempo(bpm: AlignmentTickInjector.wizardBlocksBPM) }
        }
        #expect(tickFreeBlocks > 1_500,
                "every tick-free block is the keep-alive and nothing else, start to finish — \(tickFreeBlocks) of 2 000")
        #expect(tickBlocks > 0, "…and the run really did tick, so this is not vacuous")
        #expect(loudest < 16_000, "nothing in the run approaches clipping, peak \(loudest)")
    }

    /// `.manual` — the row's metronome — gets the same keep-alive as the
    /// wizard: the Move's amp gate is the same amp gate either way.
    @Test func theManualMetronomeCarriesTheSameKeepAlive() {
        let injector = AlignmentTickInjector(sampleRate: 44_100, config: .manual)
        var pcm = zeroBuffer(frames: 20_000)
        injector.mix(into: &pcm)
        // Past the 30 ms tick body (1 323 frames), only the keep-alive plays.
        let betweenTicks = channel0(pcm)[2_000...]
        #expect(abs(dBFS(betweenTicks) - AlignmentTickInjector.Config.toneRMSdBFS) < 0.5,
                "measured \(dBFS(betweenTicks))")
    }

    /// Both wizard variants render the SAME tick from the same block, and the
    /// keep-alive rides only the Bluetooth one — so subtracting the tone leaves
    /// two blocks whose tick onsets are sample-identical in position.
    @Test func theKeepAliveNeverMovesTheTickOnset() {
        let injector = AlignmentTickInjector(
            sampleRate: 44_100,
            config: .init(bpm: 600, maxTicks: AlignmentTickInjector.unlimitedTicks,
                          armedAtStart: false, replacesProgram: true))
        injector.armTicks()
        var pcm = zeroBuffer(frames: 20_000)
        var bedded = Data()
        injector.mixWizardVariants(into: &pcm, bedded: &bedded)
        let knock = channel0(pcm)
        // Subtract the keep-alive back out (exact — nothing clamps at these
        // levels) and what is left is the bright click alone, so the two onsets
        // can be compared the same first-nonzero way the bed-less pair is.
        let click = channel0(bedded).enumerated().map { (position, sample) in
            Int16(clamping: Int32(sample) - Int32(toneSample(at: position)))
        }
        let onset = { (samples: [Int16]) -> Int? in samples.firstIndex { $0 != 0 } }
        #expect(onset(knock) != nil)
        #expect(onset(knock) == onset(click),
                "the keep-alive must not shift or mask the Bluetooth onset")
    }

    /// The ARM gate replaced the fixed wake preamble (roadmap 056 Part B): a
    /// wizard injector is bed-only until the backend says every participating
    /// sink is playing. The beat grid then opens one WHOLE interval after the
    /// arm — the arm point is wherever the last sink happened to release, and a
    /// tick placed on it can land a few ms behind the previous run's last one,
    /// overlapping two 30 ms tick bodies into one ambiguous smear.
    @Test func aWizardInjectorIsBedOnlyUntilArmed() {
        let injector = AlignmentTickInjector(
            sampleRate: 1_000,
            config: .init(bpm: 600, maxTicks: AlignmentTickInjector.unlimitedTicks,
                          armedAtStart: false))
        #expect(!injector.test_isArmed)
        let tickPeak = Double(0.35 * 0.7 * 32_767)   // the tick's first partial scale
        let isTick = { (s: Int16) in abs(Double(s)) > tickPeak / 8 }
        var pcm = zeroBuffer(frames: 200)
        var bedded = Data()
        injector.mixWizardVariants(into: &pcm, bedded: &bedded)
        #expect(!channel0(bedded).contains(where: isTick),
                "before the arm the run carries only the quiet bed, never a tick")

        injector.armTicks()
        #expect(injector.test_isArmed)
        // 600 BPM at 1 kHz — one beat every 100 frames, so the arm's own
        // interval covers frames 0..<100 of this block and the first tick is at
        // 100.
        var armedPCM = zeroBuffer(frames: 200)
        injector.mixWizardVariants(into: &armedPCM, bedded: &bedded)
        let armed = channel0(bedded)
        #expect(!armed[0..<100].contains(where: isTick),
                "no tick inside the first interval — the arm instant is silent")
        #expect(armed[100..<130].contains(where: isTick),
                "…and the opening tick lands one whole interval later")
    }

    /// Two tempos, one grid: the estimator's coarse search ticks every 3 s and
    /// its blocks at 72 BPM, and the change re-derives the grid rather than
    /// leaving a stale phase behind.
    @Test func theTempoCanChangeMidRun() {
        let injector = AlignmentTickInjector(
            sampleRate: 1_000,
            config: .init(bpm: 60, maxTicks: AlignmentTickInjector.unlimitedTicks,
                          armedAtStart: false))
        #expect(injector.test_beatFrames == 1_000)
        injector.setTempo(bpm: 120)
        #expect(injector.test_beatFrames == 500)

        // The wizard's own two values, as the session drives them.
        let wizard = AlignmentTickInjector(sampleRate: 1_000, config: .wizard)
        #expect(wizard.test_beatFrames == 3_000, "the search ticks every 3 s")
        wizard.setTempo(bpm: AlignmentTickInjector.wizardBlocksBPM)
        #expect(wizard.test_beatFrames == 833, "72 BPM ≈ 833 ms — 833 frames at 1 kHz")
    }

    /// A tempo change lands the next tick a full NEW interval after the LAST
    /// one already heard — never sooner. At the search → blocks handover the
    /// two intervals differ by seconds, and re-deriving the grid from the bare
    /// cursor put the next tick ~20 ms behind the one the listener had just
    /// heard: two overlapping 30 ms tick bodies, an unanswerable first pair.
    @Test func aTempoChangeNeverCrowdsTheTickJustHeard() {
        // 60 BPM at 1 kHz — a beat every 1000 frames — dropping to 120 BPM.
        let injector = AlignmentTickInjector(
            sampleRate: 1_000,
            config: .init(bpm: 60, maxTicks: AlignmentTickInjector.unlimitedTicks,
                          armedAtStart: false, bedEnabled: false, replacesProgram: true))
        injector.armTicks()          // first tick at frame 1000
        var pcm = zeroBuffer(frames: 1_050)
        injector.mix(into: &pcm)
        #expect(channel0(pcm)[1_000..<1_030].contains { $0 != 0 }, "the opening tick")

        // 50 frames past that tick — the crowding case.
        injector.setTempo(bpm: 120)
        #expect(injector.test_beatFrames == 500)
        var after = zeroBuffer(frames: 1_000)
        injector.mix(into: &after)
        let samples = channel0(after)
        // Absolute frames 1050..2049; the last tick was at 1000, so the next
        // may not land before 1500 (local index 450).
        #expect(!samples[0..<450].contains { $0 != 0 },
                "nothing inside one new interval of the tick just heard")
        #expect(samples[450..<480].contains { $0 != 0 },
                "…and the next tick lands exactly one new interval after it")
    }

    /// Two TIMBRES off one beat clock: the Bluetooth fan-out keeps the bright
    /// click, the engine/Mac side gets a low knock, and the onset instant is
    /// sample-identical in both — the question is which side first, never which
    /// side louder.
    @Test func theWizardVariantsCarryDifferentTicksAtTheSameOnset() {
        let injector = AlignmentTickInjector(
            sampleRate: 44_100,
            config: .init(bpm: 60, maxTicks: AlignmentTickInjector.unlimitedTicks,
                          armedAtStart: false, bedEnabled: false, replacesProgram: true))
        injector.armTicks()
        // The first tick is one whole interval after the arm, so the block has
        // to be long enough to contain it.
        var pcm = zeroBuffer(frames: injector.test_beatFrames + 2_000)
        var bedded = Data()
        injector.mixWizardVariants(into: &pcm, bedded: &bedded)
        let low = channel0(pcm)
        let bright = channel0(bedded)
        let onset = { (samples: [Int16]) -> Int? in samples.firstIndex { $0 != 0 } }
        #expect(onset(low) != nil)
        #expect(onset(low) == onset(bright), "sample-exact onset equality")
        #expect(low != bright, "different partials — a low knock against the bright click")
    }

    /// …and they are equally LOUD, not equally scaled. The bright click sits
    /// nearer the ear's most sensitive band, so at equal digital amplitude it is
    /// the louder of the two — and a louder event is perceived as EARLIER,
    /// which the estimator has no counterbalanced condition to cancel: the whole
    /// psychometric fit shifts and the displacement is stored as latency
    /// (`dev/notes/wizard-tick-stimulus-brief.md` §3). A-weighted, the bright
    /// click is +1.28 dB, so it is rendered at ×0.863.
    ///
    /// The RATIO is what is pinned, never either variant's absolute level: the
    /// caller's `amplitude` is free to change and the match has to survive it.
    @Test func theTwoTimbresAreLoudnessMatched() {
        #expect(abs(AlignmentTickInjector.brightLoudnessScale - 0.863) < 0.002,
                "A-weighted correction, computed \(AlignmentTickInjector.brightLoudnessScale)")

        let injector = AlignmentTickInjector(
            sampleRate: 44_100,
            config: .init(bpm: 60, maxTicks: AlignmentTickInjector.unlimitedTicks,
                          armedAtStart: false, bedEnabled: false, replacesProgram: true))
        injector.armTicks()
        var pcm = zeroBuffer(frames: injector.test_beatFrames + 2_000)
        var bedded = Data()
        injector.mixWizardVariants(into: &pcm, bedded: &bedded)
        // Same window, same frame count, so the silence around the tick divides
        // out and the ratio is the two ticks' own.
        let ratio = pow(10, (dBFS(channel0(bedded)) - dBFS(channel0(pcm))) / 20)
        #expect(abs(ratio - AlignmentTickInjector.brightLoudnessScale) < 0.03,
                "the rendered click is quieter than the knock by the correction, measured \(ratio)")

        // Downward, deliberately: the low knock is untouched, so nothing in the
        // run moved closer to the Int16 clamp.
        let knockPeak = channel0(pcm).map { abs(Int($0)) }.max() ?? 0
        #expect(knockPeak > channel0(bedded).map { abs(Int($0)) }.max() ?? 0)
        #expect(knockPeak < 16_000, "peak \(knockPeak) — nowhere near clipping")
    }

    /// The bed stops WITH the tick budget — an expired injector adds nothing,
    /// so a forgotten switch-off leaks silence, not hiss.
    @Test func bedStopsWhenTheTickBudgetExpires() {
        let injector = AlignmentTickInjector(
            sampleRate: 1_000, config: .init(bpm: 600, maxTicks: 2))
        var pcm = zeroBuffer(frames: 400)
        injector.mix(into: &pcm)
        let samples = channel0(pcm)
        #expect(samples[0..<200].contains { $0 != 0 })
        #expect(samples[200..<400].allSatisfy { $0 == 0 },
                "past the budget, neither tick nor bed is emitted")
    }

    /// The wizard config: NO budget, NOT armed at birth (the backend's arm gate
    /// owns that now), opening on the search tempo, bed on.
    @Test func wizardConfigShape() {
        let config = AlignmentTickInjector.Config.wizard
        #expect(config.maxTicks == AlignmentTickInjector.unlimitedTicks)
        #expect(config.armedAtStart == false)
        #expect(config.bpm == AlignmentTickInjector.wizardSearchBPM)
        #expect(config.bedEnabled)
        #expect(config.replacesProgram, "the guided run is ticks only")
        #expect(AlignmentTickInjector.Config.manual.armedAtStart,
                "the row's metronome ticks the moment it is switched on")
        #expect(AlignmentTickInjector.Config.manual.replacesProgram == false,
                "the row's metronome is the nudge-while-listening case")
    }

    /// The wizard's tick has no wall-clock ceiling (live report, 2026-08-22):
    /// the old 360-beat budget ≈ 303 s expired mid-questionnaire and the whole
    /// system went silent with the panel still asking. The session's exit paths
    /// are the one switch-off.
    @Test func aWizardInjectorStillTicksLongPastTheOldBudget() {
        let injector = AlignmentTickInjector(
            sampleRate: 1_000,
            config: .init(bpm: 600, maxTicks: AlignmentTickInjector.unlimitedTicks,
                          bedEnabled: false))
        // 400 beats — well past the 360 the wizard used to stop at.
        var pcm = zeroBuffer(frames: 100)
        for _ in 0..<399 {
            pcm = zeroBuffer(frames: 100)
            injector.mix(into: &pcm)
        }
        var last = zeroBuffer(frames: 100)
        injector.mix(into: &last)
        #expect(channel0(last).contains { $0 != 0 }, "beat 400 still rings")
    }

    /// The bed is a Bluetooth amp's keep-alive, and nothing else's: on the Mac's
    /// own speakers it is audible hiss (live report, 2026-08-22 — "heavy static
    /// during the wizard"). One render, two variants.
    @Test func theWizardsBedGoesToBluetoothOnlyAndTheTickToBoth() {
        let injector = AlignmentTickInjector(
            sampleRate: 1_000, config: .init(bpm: 600, maxTicks: 4))
        var tickOnly = zeroBuffer(frames: 100)
        var bedded = Data()
        injector.mixWizardVariants(into: &tickOnly, bedded: &bedded)

        let plain = channel0(tickOnly)
        let withBed = channel0(bedded)
        #expect(plain[30..<100].allSatisfy { $0 == 0 }, "no bed between the ticks")
        #expect(withBed[30..<100].contains { $0 != 0 }, "the bed rides under the Bluetooth copy")
        #expect(plain[1...29].contains { $0 != 0 }, "the tick is in both…")
        #expect(withBed[1...29].contains { $0 != 0 })

        // …at the SAME instant, in two different timbres (roadmap 056 Part B),
        // and the bed stays far under either of them.
        let bedPeak = withBed[30..<100].map { abs(Int($0)) }.max() ?? 0
        let tickPeak = plain.map { abs(Int($0)) }.max() ?? 0
        #expect(bedPeak > 0)
        // A ratio, not THE ratio: this injector runs at a synthetic 1 kHz where
        // both tick partials are above Nyquist and alias down to a fraction of
        // their real amplitude. `theKeepAliveIsALowToneAndNothingElse` pins the
        // keep-alive's real level at 44.1 kHz.
        #expect(tickPeak > bedPeak * 4, "tick \(tickPeak) vs keep-alive \(bedPeak)")

        // One cursor advance for both variants: the next block starts where a
        // single `mix` would have left off.
        var next = zeroBuffer(frames: 100)
        injector.mix(into: &next)
        #expect(channel0(next)[0...29].contains { $0 != 0 },
                "the following beat lands on time, so the cursor moved exactly once")
    }


    // MARK: Coordinator seam — one mixed feed, every consumer

    private final class FakeTap: SystemAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        let format = TapFormat(sampleRate: 44_100, channels: 2, bitsPerSample: 32,
                               isFloat: true, isInterleaved: true)
        func createAndStart(muteBehavior: TapMuteBehavior,
                            excludedProcessObjectIDs: Set<AudioObjectID>) throws -> TapFormat {
            format
        }
        func teardown() {}
        func deliverSilence(frames: Int, pts: timespec) {
            let data = Data(count: frames * 2 * MemoryLayout<Float>.size)
            onBuffer?(CapturedBuffer(channelData: [data], frameCount: frames, pts: pts))
        }
    }

    /// Converts every captured buffer to SILENT S16LE stereo of the same frame
    /// count — so any non-zero sample downstream can only be the tick.
    private final class SilenceConverter: PCMConverting, @unchecked Sendable {
        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? {
            Data(count: buffer.frameCount * 2 * MemoryLayout<Int16>.size)
        }
    }

    /// Converts every captured buffer to a flat, obviously non-silent S16LE
    /// program — so the DC level of a consumer's samples answers "is the
    /// user's music still in this feed?" (a tick and the bed both average to
    /// ~0; the program does not).
    private final class ConstantConverter: PCMConverting, @unchecked Sendable {
        static let level = 6_000
        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? {
            var data = Data(count: buffer.frameCount * 2 * MemoryLayout<Int16>.size)
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<p.count { p[i] = Int16(Self.level) }
            }
            return data
        }
    }

    private final class SpyPCMSink: PCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [Data] = []
        func write(pcm: Data, pts: timespec) { lock.withLock { writes.append(pcm) } }
        var forwarded: [Data] { lock.withLock { writes } }
    }

    /// Like ``SpyPCMSink`` but keeps each write's `pts` — the pacer's own clock
    /// is the thing under test.
    private final class SpyPtsSink: PCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(pcm: Data, pts: timespec)] = []
        func write(pcm: Data, pts: timespec) { lock.withLock { recorded.append((pcm, pts)) } }
        var writes: [(pcm: Data, pts: timespec)] { lock.withLock { recorded } }
    }

    private final class SpyFanoutSink: SyncedLocalPCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[Float]] = []
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
            let buf = UnsafeBufferPointer(start: interleavedFrames, count: frameCount * 2)
            lock.withLock { calls.append(Array(buf)) }
        }
        var enqueued: [[Float]] { lock.withLock { calls } }
    }

    private final class EmptyEnumerator: AudioProcessEnumerating {
        func enumerateProcesses() -> [RawAudioProcess] { [] }
        func parentPID(of pid: pid_t) -> pid_t? { nil }
    }

    private func waitFor(timeout: TimeInterval = 8, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    @Test func tickReachesEngineAndBTFanoutIdenticallyAndOnlyWhileActive() {
        let tap = FakeTap()
        let engineSink = SpyPCMSink()
        let btSink = SpyFanoutSink()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in SilenceConverter() },
            processResolver: AudioProcessResolver(enumerator: EmptyEnumerator()),
            muteBehavior: .mutedWhenTapped)
        coordinator.setBTSink(btSink, renderProcessPID: 313_131)
        coordinator.start()
        waitFor {
            if case .capturing = coordinator.state { return true }
            return false
        }

        // Inactive: silence in, silence out everywhere.
        tap.deliverSilence(frames: 512, pts: timespec(tv_sec: 1, tv_nsec: 0))
        waitFor { engineSink.forwarded.count == 1 }
        #expect(channel0(engineSink.forwarded[0]).allSatisfy { $0 == 0 })

        // Active: the SAME delivered silence now carries the tick — in the
        // engine's S16LE write AND the BT fan-out's widened floats.
        // (`setAlignTick` is `queue.sync`, so the swap is visible immediately.)
        coordinator.setAlignTick(true)
        tap.deliverSilence(frames: 512, pts: timespec(tv_sec: 2, tv_nsec: 0))
        waitFor { engineSink.forwarded.count == 2 && btSink.enqueued.count == 2 }
        let engineSamples = channel0(engineSink.forwarded[1])
        #expect(engineSamples.contains { $0 != 0 }, "the engine feed carries the tick")
        #expect(btSink.enqueued[1].contains { $0 != 0 }, "the BT fan-out carries the same tick")
        // Same mixed feed, not two parallel renders: the widened floats are
        // exactly the engine's S16 samples / 32768.
        let widened = engineSamples.map { Float($0) / 32_768.0 }
        let btChannel0 = stride(from: 0, to: btSink.enqueued[1].count, by: 2)
            .map { btSink.enqueued[1][$0] }
        #expect(zip(widened, btChannel0).allSatisfy { abs($0 - $1) <= 1e-6 })

        // Off again: back to pure silence.
        coordinator.setAlignTick(false)
        tap.deliverSilence(frames: 512, pts: timespec(tv_sec: 3, tv_nsec: 0))
        waitFor { engineSink.forwarded.count == 3 }
        #expect(channel0(engineSink.forwarded[2]).allSatisfy { $0 == 0 },
                "disabling the tick restores the untouched feed")
    }

    /// The mode difference at the seam every consumer shares. `.manual` rides
    /// OVER the captured music, which keeps flowing. `.wizard` takes the feed
    /// over completely: captured buffers reach NOBODY (the pacer is the single
    /// producer for the run's duration), and switching off restores the
    /// captured feed untouched.
    @Test func wizardModeTakesOverTheSharedFeedAndManualDoesNot() {
        let tap = FakeTap()
        let engineSink = SpyPtsSink()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in ConstantConverter() },
            processResolver: AudioProcessResolver(enumerator: EmptyEnumerator()),
            muteBehavior: .mutedWhenTapped)
        coordinator.start()
        waitFor {
            if case .capturing = coordinator.state { return true }
            return false
        }
        // Each tap buffer is stamped with its own whole second, which is what
        // identifies a delivered CAPTURED buffer downstream — the pacer's pts is
        // a live CLOCK_MONOTONIC reading and can never collide with one.
        func meanOfNextBuffer(second: Int) -> Double {
            let expected = engineSink.writes.count + 1
            tap.deliverSilence(frames: 512, pts: timespec(tv_sec: second, tv_nsec: 0))
            waitFor { engineSink.writes.count == expected }
            let samples = channel0(engineSink.writes[expected - 1].pcm)
            return samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        }
        let program = Double(ConstantConverter.level)

        #expect(abs(meanOfNextBuffer(second: 1) - program) < 1, "idle: the music passes through")

        coordinator.setAlignTickMode(.manual)
        #expect(abs(meanOfNextBuffer(second: 2) - program) < 500,
                "the manual metronome ticks OVER the music, which keeps playing")

        coordinator.setAlignTickMode(.wizard)
        tap.deliverSilence(frames: 512, pts: timespec(tv_sec: 3, tv_nsec: 0))
        waitFor(timeout: 0.3) { engineSink.writes.contains { $0.pts.tv_sec == 3 } }
        #expect(!engineSink.writes.contains { $0.pts.tv_sec == 3 },
                "during a wizard run captured buffers reach no consumer at all")

        coordinator.setAlignTickMode(.off)
        #expect(abs(meanOfNextBuffer(second: 4) - program) < 1,
                "…and the captured feed comes back the instant the run ends")
    }

    /// The wizard's own paced blocks go to the SAME consumers a captured buffer
    /// would, carrying ticks and no program.
    @Test func wizardPacerBlocksReachEveryConsumerWithTicksAndNoProgram() {
        let tap = FakeTap()
        let engineSink = SpyPCMSink()
        let btSink = SpyFanoutSink()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in ConstantConverter() },
            processResolver: AudioProcessResolver(enumerator: EmptyEnumerator()),
            muteBehavior: .mutedWhenTapped)
        coordinator.setBTSink(btSink, renderProcessPID: 313_131)
        coordinator.start()
        waitFor {
            if case .capturing = coordinator.state { return true }
            return false
        }

        coordinator.test_setWizardModeWithoutPacerTimer()
        // The run opens bed-only; the backend's arm gate is what makes it
        // audible (roadmap 056 Part B), and it is the pacer queue that arms.
        coordinator.armWizardTicks()
        for _ in 0..<60 { coordinator.test_pumpWizardTick(frames: 4_096) }
        waitFor { !engineSink.forwarded.isEmpty && !btSink.enqueued.isEmpty }

        let engineSamples = engineSink.forwarded.flatMap { channel0($0) }
        #expect(engineSamples.contains { $0 != 0 }, "the pacer's blocks carry the tick")
        #expect(!engineSamples.contains { $0 == Int16(ConstantConverter.level) },
                "and carry no captured program — the wizard replaces it")
        #expect(engineSink.forwarded.count == btSink.enqueued.count,
                "every pacer block reaches the BT fan-out too, one for one")
        // One render pass, two variants: the Bluetooth copy carries the bright
        // click over the keep-alive bed while the engine gets the low knock.
        // Their sample-exact onset equality is pinned by
        // `theWizardVariantsCarryDifferentTicksAtTheSameOnset` above; what
        // matters here is that BOTH consumers got a tick, block for block.
        let btChannel0 = btSink.enqueued.flatMap { block in
            stride(from: 0, to: block.count, by: 2).map { block[$0] }
        }
        #expect(btChannel0.contains { abs($0) > 0.2 }, "the Bluetooth copy ticks too")
        #expect(engineSamples.map { abs(Float($0) / 32_768.0) }.max() ?? 0 > 0.2)

        coordinator.setAlignTickMode(.off)
    }

    /// The Mac hears TICKS; Bluetooth hears ticks over the keep-alive bed. Same
    /// pacer block, one injector cursor, two variants — the fix for the "heavy
    /// static on the Mac" the live run reported.
    @Test func theWizardPacerFeedsTheMacTicksOnlyAndBluetoothTheBed() {
        let tap = FakeTap()
        let engineSink = SpyPCMSink()
        let localSink = SpyFanoutSink()
        let btSink = SpyFanoutSink()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in ConstantConverter() },
            processResolver: AudioProcessResolver(enumerator: EmptyEnumerator()),
            muteBehavior: .mutedWhenTapped)
        coordinator.setSyncedLocalSink(localSink, renderProcessPID: 212_121)
        coordinator.setBTSink(btSink, renderProcessPID: 313_131)
        coordinator.start()
        waitFor {
            if case .capturing = coordinator.state { return true }
            return false
        }

        coordinator.test_setWizardModeWithoutPacerTimer()
        // Before the arm: bed only, no tick anywhere yet.
        for _ in 0..<8 { coordinator.test_pumpWizardTick(frames: 4_096) }
        waitFor { localSink.enqueued.count == 8 && btSink.enqueued.count == 8 }
        let quietLocal = localSink.enqueued.flatMap { $0 }
        let quietBT = btSink.enqueued.flatMap { $0 }
        #expect(quietLocal.allSatisfy { $0 == 0 },
                "the Mac's own fan-out carries silence between ticks, never the bed")
        #expect(quietBT.contains { $0 != 0 },
                "the Bluetooth fan-out carries the amp's keep-alive bed")
        #expect(engineSink.forwarded.flatMap { channel0($0) }.allSatisfy { $0 == 0 },
                "so does the engine feed — the bed is a Bluetooth-only concern")

        // Armed: the tick reaches both — the Mac's low knock, Bluetooth's
        // bright click over the bed.
        coordinator.armWizardTicks()
        for _ in 0..<60 { coordinator.test_pumpWizardTick(frames: 4_096) }
        waitFor { localSink.enqueued.count == 68 && btSink.enqueued.count == 68 }
        let local = localSink.enqueued.flatMap { $0 }
        let bt = btSink.enqueued.flatMap { $0 }
        #expect(local.count == bt.count)
        let tickPeak = local.map { abs($0) }.max() ?? 0
        #expect(tickPeak > 0.2, "the Mac hears the tick, peak \(tickPeak)")
        #expect(bt.map { abs($0) }.max() ?? 0 > 0.2, "and so does Bluetooth")
        #expect(local != bt, "two timbres — the Mac's knock is not Bluetooth's click")

        coordinator.setAlignTickMode(.off)
    }

    /// The whole point of the pacer (roadmap 040): with the Mac paused the tap
    /// delivers nothing at all, and the wizard still gets a feed — with a pts
    /// that advances.
    @Test func wizardFeedsTicksWithNoTapDeliveryAtAll() {
        let tap = FakeTap()
        let engineSink = SpyPtsSink()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in ConstantConverter() },
            processResolver: AudioProcessResolver(enumerator: EmptyEnumerator()),
            muteBehavior: .mutedWhenTapped)
        coordinator.start()
        waitFor {
            if case .capturing = coordinator.state { return true }
            return false
        }

        // No live pacer timer: the four pumps below are provably the only
        // writes, which is exactly what this test claims.
        coordinator.test_setWizardModeWithoutPacerTimer()
        for _ in 0..<4 { coordinator.test_pumpWizardTick(frames: 4_096) }
        waitFor { engineSink.writes.count == 4 }

        // Not one buffer was ever delivered by the tap.
        #expect(engineSink.writes.count == 4, "the pacer alone fed the graph")
        let stamps = engineSink.writes.map { SyncTiming.monotonicNanos($0.pts) }
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 < $1 },
                "pts must advance monotonically: \(stamps)")
        // 4096 frames at 44.1 kHz ≈ 92.9 ms per block.
        let step = stamps[1] - stamps[0]
        #expect(abs(step - 92_879_818) < 1_000_000, "one block's worth of pts, got \(step) ns")

        coordinator.setAlignTickMode(.off)
    }

    // MARK: Mic-probe lanes (roadmap 064)

    /// The staged calibration sweeps land on their lanes sample-exact: the
    /// engine variant carries the DOWN sweep, the Bluetooth variant the UP
    /// sweep, both from one shared epoch, silence before and after — and the
    /// completion latch reports once.
    @Test func theProbeSweepsLandOnTheirLanesSampleExact() {
        let rate = 8_000.0
        let injector = AlignmentTickInjector(
            sampleRate: rate, channels: 2,
            config: .init(bpm: AlignmentTickInjector.wizardSearchBPM,
                          maxTicks: AlignmentTickInjector.unlimitedTicks,
                          armedAtStart: false, bedEnabled: false,
                          replacesProgram: true))
        let amplitude = 0.35
        injector.stageProbe(amplitude: amplitude)
        #expect(!injector.test_probeArmed, "staging alone makes no sound")
        injector.armProbe()
        #expect(injector.test_probeArmed)

        var engine: [Int16] = []
        var bluetooth: [Int16] = []
        for _ in 0..<9 {
            var pcm = zeroBuffer(frames: 1_600)
            var bedded = Data()
            injector.mixWizardVariants(into: &pcm, bedded: &bedded)
            engine.append(contentsOf: channel0(pcm))
            bluetooth.append(contentsOf: channel0(bedded))
        }

        let epoch = Int(0.5 * rate)
        let down = SyncProbe.samples(.downSweep(sampleRate: rate, duration: 1.0))
        let up = SyncProbe.samples(.upSweep(sampleRate: rate, duration: 1.0))
        func expected(_ sweep: [Float], _ i: Int) -> Int16 {
            Int16(clamping: Int32((Double(sweep[i]) * amplitude * 32_767.0).rounded()))
        }
        #expect(engine[0..<epoch].allSatisfy { $0 == 0 },
                "the lead-in is silent — the sweep never rides the gate's tail")
        #expect((0..<down.count).allSatisfy { engine[epoch + $0] == expected(down, $0) },
                "the engine lane carries the DOWN sweep, sample for sample")
        #expect((0..<up.count).allSatisfy { bluetooth[epoch + $0] == expected(up, $0) },
                "the Bluetooth lane carries the UP sweep, sample for sample")
        #expect(engine[(epoch + down.count)...].allSatisfy { $0 == 0 },
                "after the sweep: silence — the tick grid is the coordinator's to arm")

        #expect(injector.takeProbeCompletion(), "the finished probe reports once")
        #expect(!injector.takeProbeCompletion(), "…and only once")
        #expect(!injector.test_isArmed,
                "the probe never arms the tick grid on its own")
    }

    /// Roadmap 064 end to end at the coordinator: with a probe staged, the
    /// SAME arm gate call starts the sweeps instead of the first tick, the
    /// two fan-outs carry DIFFERENT sweeps, the finish callback fires, and
    /// the tick grid arms itself afterwards.
    @Test func aStagedMicProbeRidesTheArmGateThenHandsOverToTicks() {
        let tap = FakeTap()
        let engineSink = SpyPCMSink()
        let localSink = SpyFanoutSink()
        let btSink = SpyFanoutSink()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in ConstantConverter() },
            processResolver: AudioProcessResolver(enumerator: EmptyEnumerator()),
            muteBehavior: .mutedWhenTapped)
        coordinator.setSyncedLocalSink(localSink, renderProcessPID: 212_121)
        coordinator.setBTSink(btSink, renderProcessPID: 313_131)
        coordinator.start()
        waitFor {
            if case .capturing = coordinator.state { return true }
            return false
        }

        coordinator.test_setWizardModeWithoutPacerTimer()
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var started = 0
            var finished = 0
        }
        let box = Box()
        coordinator.stageWizardMicProbe(
            onStarted: { box.lock.lock(); box.started += 1; box.lock.unlock() },
            onFinished: { box.lock.lock(); box.finished += 1; box.lock.unlock() })
        coordinator.armWizardTicks()

        // 0.5 s lead + 1 s sweep at the 44.1 kHz feed ≈ 66 150 frames.
        for _ in 0..<20 { coordinator.test_pumpWizardTick(frames: 4_096) }
        waitFor { box.lock.withLock { box.finished } == 1 }
        #expect(box.lock.withLock { box.started } == 1,
                "the gate's one arm started the probe, not a tick")

        let localDuringProbe = localSink.enqueued.flatMap { $0 }
        let btDuringProbe = btSink.enqueued.flatMap { $0 }
        #expect(localDuringProbe.contains { abs($0) > 0.2 },
                "the engine/Mac fan-out heard its sweep")
        #expect(btDuringProbe.contains { abs($0) > 0.2 },
                "the Bluetooth fan-out heard its sweep")
        #expect(localDuringProbe != btDuringProbe,
                "two DIFFERENT sweeps — that is the whole separability")

        // After the handover the tick grid is armed: one search-tempo beat
        // (3 s) past the sweep, the feed carries a tick with no probe left.
        let blocksBefore = localSink.enqueued.count
        for _ in 0..<40 { coordinator.test_pumpWizardTick(frames: 4_096) }
        waitFor { localSink.enqueued.count == blocksBefore + 40 }
        let afterHandover = localSink.enqueued[blocksBefore...].flatMap { $0 }
        #expect(afterHandover.contains { abs($0) > 0.2 },
                "the by-ear ticks follow the probe on their own")

        coordinator.setAlignTickMode(.off)
    }
}
