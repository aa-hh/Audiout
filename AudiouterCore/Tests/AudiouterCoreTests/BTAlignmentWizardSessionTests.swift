import Foundation
import Testing
@testable import AudiouterCore

/// The wizard session (W2): drives the estimator end to end against recording
/// closures — tick lifecycle, live candidate previews relative to the base trim,
/// Back across the search/blocks boundary, Keep persisting, and Try again /
/// cancel / graceful exit / unreachable restoring.
@Suite final class BTAlignmentWizardSessionTests {

    /// SplitMix64 — a seed pins every block's stimulus order, so these tests
    /// read the same run every time.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private final class Recorder {
        var previews: [Double] = []
        var ends: [Double?] = []
        var ticks: [Bool] = []
        var tempos: [Double] = []
        var screens: [BTAlignmentWizardSession.Screen] = []

        func makeSession(baseTrimMs: Double = 0, seed: UInt64 = 42,
                         candidateRangeMs: ClosedRange<Double> =
                            -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs,
                         invertsEstimate: Bool = false,
                         reference: BTAlignmentWizardSession.Reference? =
                            .init(id: "homepod", name: "Kitchen HomePod")) -> BTAlignmentWizardSession {
            let session = BTAlignmentWizardSession(
                deviceID: "AA:BB:output",
                targetName: "Move 2",
                reference: reference,
                baseValueMs: baseTrimMs,
                candidateRangeMs: candidateRangeMs,
                invertsEstimate: invertsEstimate,
                randomNumberGenerator: SeededRNG(seed: seed),
                applyPreviewTrim: { [weak self] in self?.previews.append($0) },
                endPreview: { [weak self] in self?.ends.append($0) },
                setTick: { [weak self] in self?.ticks.append($0) },
                setTempo: { [weak self] in self?.tempos.append($0) })
            session.onScreenChange = { [weak self] in self?.screens.append($0) }
            return session
        }
    }

    /// Answer every question the way a listener with this true offset would.
    /// The candidate is read back off the preview the session just applied —
    /// the only place it is observable, which is also the point: the trim the
    /// device is playing at IS the level being judged.
    @discardableResult
    private func driveTruthfully(
        _ session: BTAlignmentWizardSession, _ recorder: Recorder,
        trueOffsetMs: Double, baseTrimMs: Double = 0, jndMs: Double = 2
    ) -> Int {
        var asked = 0
        while case .question = session.screen, asked < 200 {
            let levelMs = (recorder.previews.last ?? baseTrimMs) - baseTrimMs
            if abs(levelMs - trueOffsetMs) < jndMs {
                session.answer(.cantTell)
            } else {
                session.answer(levelMs < trueOffsetMs ? .target : .reference)
            }
            asked += 1
        }
        return asked
    }

    /// Answer as a listener whose speaker really has `trueLatencyMs` of it. The
    /// mirror of ``driveTruthfully``: a LATENCY level below the truth leaves the
    /// target still late, so the REFERENCE is what is heard first.
    @discardableResult
    private func driveLatencyRun(
        _ session: BTAlignmentWizardSession, _ recorder: Recorder,
        trueLatencyMs: Double, jndMs: Double = 2
    ) -> Int {
        var asked = 0
        while case .question = session.screen, asked < 200 {
            let levelMs = recorder.previews.last ?? 0
            if abs(levelMs - trueLatencyMs) < jndMs {
                session.answer(.cantTell)
            } else {
                session.answer(levelMs < trueLatencyMs ? .reference : .target)
            }
            asked += 1
        }
        return asked
    }

    /// A fresh speaker's latency base is 0, and its range used to bottom out
    /// there too: "target first" means the latency must come DOWN, the candidate
    /// clamped to the same 0, the identical question came back, and the second
    /// identical answer bowed the run out. Two wrong-feeling clicks killed every
    /// first run.
    @Test func aFreshSpeakersFirstTargetAnswersMoveTheRunInsteadOfEndingIt() {
        let recorder = Recorder()
        let session = recorder.makeSession(candidateRangeMs: -500...1_500,
                                           invertsEstimate: true)
        session.start()
        #expect(recorder.previews == [0], "the search opens at the fresh speaker's base")
        session.answer(.target)
        session.answer(.target)
        guard case .question = session.screen else {
            Issue.record("two answers must not end a fresh run, got \(session.screen)")
            return
        }
        #expect(recorder.previews.count == 3, "each answer asks a NEW question")
        #expect(recorder.previews[1] < 0, "the candidate reverses below the base")
        #expect(recorder.previews[2] < recorder.previews[1],
                "…and keeps going: \(recorder.previews)")
        session.cancel()
    }

    /// The other end of that freedom: a run that converges somewhere the Mac
    /// would have to be the LATE one says so instead of storing it. A negative
    /// latency is not a thing a speaker does with the Mac as the zero.
    @Test func aLatencyRunConvergingBelowZeroSaysSoAndPersistsNothing() {
        let recorder = Recorder()
        let session = recorder.makeSession(candidateRangeMs: -500...1_500,
                                           invertsEstimate: true)
        session.start()
        driveLatencyRun(session, recorder, trueLatencyMs: -60)
        #expect(session.screen == .macIsLate, "got \(session.screen)")
        #expect(recorder.ends == [nil], "nothing is persisted")
        #expect(recorder.ticks == [true, false], "and the tick stops with the questions")
    }

    /// The ordinary outcome, unchanged by any of the above.
    @Test func aLatencyRunConvergingAboveZeroPersistsTheMeasurement() {
        let recorder = Recorder()
        let session = recorder.makeSession(candidateRangeMs: -500...1_500,
                                           invertsEstimate: true)
        session.start()
        driveLatencyRun(session, recorder, trueLatencyMs: 640)
        guard case .receipt(let latencyMs) = session.screen else {
            Issue.record("expected a receipt, got \(session.screen)")
            return
        }
        #expect(abs(latencyMs - 640) <= 4, "got \(latencyMs)")
        session.keep()
        #expect(recorder.ends == [latencyMs], "Keep persists the measurement")
    }

    @Test func startTurnsTheTickOnAndAppliesTheFirstCandidate() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 40)
        #expect(session.screen == .intro)
        session.start()
        #expect(recorder.ticks == [true])
        #expect(recorder.previews.count == 1)
        #expect(recorder.previews[0] == 40,
                "the coarse search opens at the device's own trim, got \(recorder.previews[0])")
        #expect(session.screen == .question(progress: 0, answersSoFar: 0, searching: true))
        session.cancel()
    }

    @Test func blockCandidatesAreTheStimuliOffsetFromTheBaseTrim() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 100)
        session.start()
        // One "can't tell" hands the coarse search over with the estimate still
        // at the base trim, so the block's fan is base ± the stimuli.
        session.answer(.cantTell)
        let blockPreviews = recorder.previews.count - 1
        session.answer(.target)
        session.answer(.reference)
        let candidates = Array(recorder.previews.dropFirst(blockPreviews))
        #expect(candidates.count == 3)
        #expect(candidates.allSatisfy {
            BTAlignmentConstantStimuli.stimuliMs.contains($0 - 100)
        }, "every candidate is base + δ: \(candidates)")
        #expect(Set(candidates).count == 3, "no stimulus is repeated inside a block")
        guard case .question(_, let answers, let searching) = session.screen else {
            Issue.record("expected a question, got \(session.screen)")
            return
        }
        #expect(answers == 3, "the count is every question asked, staircase included")
        #expect(searching == false, "and the search is behind us")
        session.cancel()
    }

    @Test func candidatesClampToTheTrimRange() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 490)
        session.start()
        // The first can't-tell ends the search at the base trim; the block that
        // follows is the one whose upper stimuli have nowhere to go.
        for _ in 0..<(BTAlignmentConstantStimuli.stimuliMs.count + 1) {
            session.answer(.cantTell)
        }
        #expect(recorder.previews.allSatisfy { $0 <= BTSyncTrim.rangeMs })
        #expect(recorder.previews.contains(BTSyncTrim.rangeMs),
                "base 490 + the +16/+24 stimuli clamp onto the ceiling")
        session.cancel()
    }

    @Test func convergenceShowsTheReceiptAndStopsTheTick() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        driveTruthfully(session, recorder, trueOffsetMs: 10)
        guard case .receipt(let trimMs) = session.screen else {
            Issue.record("expected receipt, got \(session.screen)")
            return
        }
        #expect(abs(trimMs - 10) <= 4, "the receipt is the true offset, got \(trimMs)")
        #expect(recorder.previews.last == trimMs, "the result is applied live for the receipt audition")
        #expect(recorder.ticks == [true, false], "the tick ends with the questions")
        #expect(recorder.ends.isEmpty, "nothing persisted or restored until Keep/Try again")
        session.cancel()
    }

    @Test func keepPersistsTheResultOnce() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        driveTruthfully(session, recorder, trueOffsetMs: 10)
        guard case .receipt(let trimMs) = session.screen else {
            Issue.record("expected receipt, got \(session.screen)")
            return
        }
        session.keep()
        #expect(recorder.ends == [trimMs], "Keep commits the applied result")
        session.keep()
        session.cancel()
        #expect(recorder.ends == [trimMs], "terminal: neither a second Keep nor cancel does anything")
    }

    @Test func tryAgainRestoresThePriorTrimAndRestarts() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 60)
        session.start()
        driveTruthfully(session, recorder, trueOffsetMs: 10, baseTrimMs: 60)
        guard case .receipt = session.screen else {
            Issue.record("expected receipt, got \(session.screen)")
            return
        }
        session.tryAgain()
        #expect(recorder.ends == [nil], "Try again restores the prior trim first")
        #expect(recorder.ticks == [true, false, true], "and the tick comes back for the fresh run")
        #expect(recorder.previews.last == recorder.previews[0],
                "the restart re-runs from the base trim, at the top of the search")
        #expect(session.screen == .question(progress: 0, answersSoFar: 0, searching: true))
        session.cancel()
    }

    @Test func cancelRestoresThePriorTrimAndSilencesTheTick() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: -30)
        session.start()
        session.answer(.target)
        session.cancel()
        #expect(recorder.ends == [nil])
        #expect(recorder.ticks == [true, false])
        session.answer(.reference)
        #expect(recorder.previews.count == 2, "a cancelled session ignores further answers")
    }

    @Test func twoAllCantTellBlocksExitGracefullyAndRestore() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 25)
        session.start()
        for _ in 0..<(2 * BTAlignmentConstantStimuli.stimuliMs.count + 1) {
            session.answer(.cantTell)
        }
        #expect(session.screen == .gracefulExit)
        #expect(recorder.ends == [nil], "graceful exit restores the prior trim")
        #expect(recorder.ticks == [true, false])

        // The panel's Done button calls `cancel()` on this screen, and the run
        // is already over: a SECOND tick-off edge costs the backend a re-anchor
        // of every sink, for nothing.
        session.cancel()
        #expect(recorder.ticks == [true, false], "exactly one tick-off edge")
        #expect(recorder.ends == [nil], "…and no second restore")
    }

    /// The unreachable exit is terminal in exactly the same way.
    @Test func doneAfterTheUnreachableExitIsInert() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 0)
        session.start()
        var asked = 0
        while case .question = session.screen, asked < 200 {
            session.answer(.target)
            asked += 1
        }
        #expect(session.screen == .unreachable)
        #expect(recorder.ticks == [true, false])
        session.cancel()
        #expect(recorder.ticks == [true, false], "exactly one tick-off edge")
        #expect(recorder.ends == [nil])
    }

    @Test func abandonedSessionCleansUpOnDeinit() {
        let recorder = Recorder()
        do {
            let session = recorder.makeSession()
            session.start()
            session.answer(.target)
        }
        #expect(recorder.ticks == [true, false], "deinit behaves as cancel")
        #expect(recorder.ends == [nil])
    }

    // MARK: The unreachable exit (the honest opposite of the graceful one)

    /// A listener who names the target at every level, all the way to the end of
    /// the usable range: the run says it could not find the alignment and puts
    /// the prior trim back — never "already aligned".
    @Test func aRunPinnedAgainstTheTrimRangeEndsUnreachable() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 0)
        session.start()
        var asked = 0
        while case .question = session.screen, asked < 200 {
            session.answer(.target)
            asked += 1
        }
        #expect(session.screen == .unreachable, "got \(session.screen) after \(asked) answers")
        #expect(recorder.previews.last == BTSyncTrim.rangeMs, "pinned at the range's ceiling")
        #expect(recorder.ends == [nil], "the prior trim is restored, nothing persisted")
        #expect(recorder.ticks == [true, false])
    }

    // MARK: Back

    @Test func backUndoesTheLastAnswerAndReAsksThatQuestion() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 12)
        session.start()
        let first = recorder.previews[0]
        session.answer(.target)
        let second = recorder.previews[1]

        session.back()
        #expect(recorder.previews.last == first, "the undone question is asked again")
        #expect(session.screen == .question(progress: 0, answersSoFar: 0, searching: true))

        session.answer(.target)
        #expect(recorder.previews.last == second, "and the run resumes where it was")
        session.cancel()
    }

    /// Back works across the search/blocks boundary too — the estimator undoes
    /// whole states, so the first block's first question steps back into the
    /// staircase.
    @Test func backCrossesTheSearchBoundary() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 12)
        session.start()
        session.answer(.target)
        let lastSearchCandidate = recorder.previews[1]
        session.answer(.cantTell)   // ends the search; the first block is up
        guard case .question(_, _, let searching) = session.screen, searching == false else {
            Issue.record("expected the blocks to have started, got \(session.screen)")
            return
        }

        session.back()
        #expect(recorder.previews.last == lastSearchCandidate)
        guard case .question(_, let answers, let backSearching) = session.screen else {
            Issue.record("expected a question, got \(session.screen)")
            return
        }
        #expect(answers == 1)
        #expect(backSearching, "back into the coarse search")
        session.cancel()
    }

    @Test func backBeforeAnyAnswerIsInert() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        let screensBefore = recorder.screens.count
        session.back()
        #expect(recorder.previews.count == 1, "nothing re-applied")
        #expect(recorder.screens.count == screensBefore, "and nothing repainted")
        session.cancel()
    }

    // MARK: Reference (the speaker the target is compared against)

    @Test func startIsRefusedWithoutAReference() {
        let recorder = Recorder()
        let session = recorder.makeSession(reference: nil)
        session.start()
        #expect(session.screen == .intro, "nothing to compare against — the run can't begin")
        #expect(recorder.ticks.isEmpty)
        #expect(recorder.previews.isEmpty)
    }

    @Test func namingAReferenceOnTheIntroEnablesTheRun() {
        let recorder = Recorder()
        let session = recorder.makeSession(reference: nil)
        session.setReference(.init(id: "mac", name: "This Mac"))
        #expect(recorder.screens == [.intro], "the intro repaints with the new name")
        session.start()
        #expect(recorder.ticks == [true])
        session.cancel()
    }

    @Test func changingTheReferenceMidRunRestartsTheRun() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 20)
        session.start()
        session.answer(.target)
        guard case .question(_, let before, _) = session.screen, before == 1 else {
            Issue.record("expected one answer folded in, got \(session.screen)")
            return
        }

        session.setReference(.init(id: "mac", name: "This Mac"))
        #expect(session.reference?.name == "This Mac")
        #expect(session.screen == .question(progress: 0, answersSoFar: 0, searching: true),
                "answers given against the old speaker are not evidence about this one")
        #expect(recorder.previews.last == recorder.previews[0],
                "the run starts a fresh block from the base trim")
        session.cancel()
    }

    @Test func reSelectingTheSameReferenceChangesNothing() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        session.answer(.target)
        session.setReference(.init(id: "homepod", name: "Kitchen HomePod"))
        guard case .question(_, let answers, _) = session.screen, answers == 1 else {
            Issue.record("expected the run to continue, got \(session.screen)")
            return
        }
        #expect(recorder.previews.count == 2)
        session.cancel()
    }

    // MARK: The latency run's sign convention (roadmap 056 Part A)

    /// THE sign, pinned. `.target` means the target was heard FIRST, so it is
    /// early and needs MORE delay. A TRIM is added to the delay, so it goes UP.
    /// A measured LATENCY is subtracted from it — a larger latency feeds the
    /// speaker earlier — so it must go DOWN. Getting this backwards compiles
    /// perfectly and converges a run onto the wrong side of the truth.
    @Test func targetFirstRaisesATrimAndLowersAMeasuredLatency() {
        let trimRecorder = Recorder()
        let trim = trimRecorder.makeSession(baseTrimMs: 0)
        trim.start()
        #expect(trimRecorder.previews == [0])
        trim.answer(.target)
        #expect(trimRecorder.previews[1] > 0,
                "the target is early, so its trim grows — got \(trimRecorder.previews[1])")
        trim.cancel()

        let latencyRecorder = Recorder()
        let latency = latencyRecorder.makeSession(
            baseTrimMs: 300, candidateRangeMs: 0...1_500, invertsEstimate: true)
        latency.start()
        #expect(latencyRecorder.previews == [300])
        latency.answer(.target)
        #expect(latencyRecorder.previews[1] < 300,
                "the target is early, so its measured latency SHRINKS and it is fed later — got \(latencyRecorder.previews[1])")
        latency.cancel()
    }

    /// A latency run never presents a value the sink's ≥ 0 delay clamp would
    /// eat: candidates stay inside the range the backend derived.
    @Test func aLatencyRunStaysInsideItsUsableRange() {
        let recorder = Recorder()
        let session = recorder.makeSession(
            baseTrimMs: 40, candidateRangeMs: 0...600, invertsEstimate: true)
        session.start()
        // The reference always sounds first: the speaker is late everywhere, so
        // the run drives the latency up as far as it can go.
        var asked = 0
        while case .question = session.screen, asked < 200 {
            session.answer(.reference)
            asked += 1
        }
        #expect(recorder.previews.allSatisfy { (0...600).contains($0) },
                "every candidate is inside the usable range")
        #expect(recorder.previews.max() ?? 0 > 40, "…and the run did push the latency up")
        session.cancel()
    }

    /// Two tempos, driven by the estimator's STAGE: the coarse search ticks
    /// every 3 s (an unknown 650 ms latency must not alias into an apparent
    /// lead at 833 ms), the blocks at 72 BPM.
    @Test func theTempoFollowsTheEstimatorStage() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        #expect(recorder.tempos == [BTAlignmentWizardSession.searchTickBPM])
        #expect(BTAlignmentWizardSession.searchTickBPM == 20, "one tick every 3 s")
        // The two values are stated twice — this file is LICENSE-CLEAN and must
        // not reach into the GPL-headered injector for a constant — so pin them
        // together here rather than let them drift apart silently.
        #expect(BTAlignmentWizardSession.searchTickBPM == AlignmentTickInjector.wizardSearchBPM)
        #expect(BTAlignmentWizardSession.blocksTickBPM == AlignmentTickInjector.wizardBlocksBPM)

        // Walk the staircase until it hands over to the blocks.
        var asked = 0
        while case .question(_, _, let searching) = session.screen, searching, asked < 30 {
            session.answer(asked.isMultiple(of: 2) ? .target : .reference)
            asked += 1
        }
        guard case .question(_, _, false) = session.screen else {
            Issue.record("expected the blocks stage, got \(session.screen)")
            return
        }
        #expect(recorder.tempos == [BTAlignmentWizardSession.searchTickBPM,
                                    BTAlignmentWizardSession.blocksTickBPM],
                "one push per stage, never one per question")
        session.cancel()
    }

    @Test func screenChangesAreAnnounced() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        let trials = 2 * BTAlignmentConstantStimuli.stimuliMs.count + 1
        for _ in 0..<trials { session.answer(.cantTell) }
        #expect(recorder.screens.count == trials + 1, "start + every answer announced")
        #expect(recorder.screens.last == .gracefulExit)
        session.cancel()
    }
}
