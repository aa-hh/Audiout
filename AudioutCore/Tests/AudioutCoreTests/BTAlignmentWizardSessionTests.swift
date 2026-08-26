import Foundation
import Testing
@testable import AudioutCore

private final class Recorder {
    var previews: [Double] = []
    var halfWidths: [Double?] = []
    var ends: [Double?] = []
    var ticks: [Bool] = []
    var tempos: [Double] = []
    var screens: [BTAlignmentWizardSession.Screen] = []

    func makeSession(deviceID: String = "AA:BB:output",
                     baseTrimMs: Double = 0,
                     candidateRangeMs: ClosedRange<Double> =
                        -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs,
                     invertsEstimate: Bool = false,
                     openingProposalMs: Double? = nil,
                     reference: BTAlignmentWizardSession.Reference? =
                        .init(id: "homepod", name: "Kitchen HomePod"),
                     targetIsBluetooth: Bool = false) -> BTAlignmentWizardSession {
        let session = BTAlignmentWizardSession(
            deviceID: deviceID,
            targetName: "Move 2",
            reference: reference,
            targetIsBluetooth: targetIsBluetooth,
            baseValueMs: baseTrimMs,
            candidateRangeMs: candidateRangeMs,
            invertsEstimate: invertsEstimate,
            openingProposalMs: openingProposalMs,
            applyPreviewTrim: { [weak self] ms, halfWidthMs in
                self?.previews.append(ms)
                self?.halfWidths.append(halfWidthMs)
            },
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
    trueOffsetMs: Double, baseTrimMs: Double = 0, jndMs: Double = 4
) -> Int {
    var asked = 0
    while case .question = session.screen, asked < 100 {
        let levelMs = (recorder.previews.last ?? baseTrimMs) - baseTrimMs
        if abs(levelMs - trueOffsetMs) < jndMs {
            session.answer(.together)
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
    trueLatencyMs: Double, jndMs: Double = 4
) -> Int {
    var asked = 0
    while case .question = session.screen, asked < 100 {
        let levelMs = recorder.previews.last ?? 0
        if abs(levelMs - trueLatencyMs) < jndMs {
            session.answer(.together)
        } else {
            session.answer(levelMs < trueLatencyMs ? .reference : .target)
        }
        asked += 1
    }
    return asked
}

/// Name the target at every level, rejecting whatever the run proposes: the
/// listener whose offset this control cannot reach.
@discardableResult
private func driveAlwaysTarget(_ session: BTAlignmentWizardSession) -> Int {
    var asked = 0
    while asked < 100 {
        switch session.screen {
        case .question:
            session.answer(.target)
            asked += 1
        case .proposal:
            session.rejectProposal()
        default:
            return asked
        }
    }
    return asked
}

/// Two answers one way and one the other, forever, rejecting whatever the run
/// proposes: consistent enough to keep the belief moving, contradictory enough
/// that nothing it names is right.
@discardableResult
private func driveContradictorily(_ session: BTAlignmentWizardSession) -> Int {
    let pattern: [BTAlignmentWizardSession.Answer] = [.target, .target, .reference]
    var asked = 0
    while asked < 120 {
        switch session.screen {
        case .question:
            session.answer(pattern[asked % 3])
            asked += 1
        case .proposal:
            session.rejectProposal()
        default:
            return asked
        }
    }
    return asked
}

private func proposalValue(_ session: BTAlignmentWizardSession) -> Double? {
    guard case .proposal(let valueMs) = session.screen else { return nil }
    return valueMs
}


/// The wizard session (W2): drives the estimator end to end against recording
/// closures — tick lifecycle, live candidate previews relative to the base
/// value, Back, the proposal's accept/reject, and Try again / cancel / the
/// bow-outs restoring.
@Suite final class BTAlignmentWizardSessionTests {

    // MARK: The ordinary run

    @Test func startTurnsTheTickOnAndAppliesTheFirstCandidate() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 40)
        #expect(session.screen == .intro)
        session.start()
        #expect(recorder.ticks == [true])
        #expect(recorder.previews.count == 1)
        guard case .question(let progress, let interval, let answers) = session.screen else {
            Issue.record("expected a question, got \(session.screen)")
            return
        }
        #expect(progress == 0, "nothing learned yet")
        #expect(answers == 0)
        #expect(interval.lowerBound >= -BTSyncTrim.rangeMs,
                "the confidence line never claims more spread than the run has")
        #expect(interval.upperBound <= BTSyncTrim.rangeMs)
        #expect(recorder.halfWidths.last ?? nil != nil,
                "every preview carries how sure the run is")
        session.cancel()
    }

    @Test func candidatesStayInsideTheTrimRange() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 490)
        session.start()
        driveTruthfully(session, recorder, trueOffsetMs: 0, baseTrimMs: 490)
        #expect(recorder.previews.allSatisfy { abs($0) <= BTSyncTrim.rangeMs },
                "got \(recorder.previews.filter { abs($0) > BTSyncTrim.rangeMs })")
        session.cancel()
    }

    /// The headline flow: questions narrow, a value is proposed, the tick is
    /// STILL RUNNING while the user judges it, and accepting persists it.
    @Test func answersNarrowToAProposalWhoseTickIsStillRunning() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        driveTruthfully(session, recorder, trueOffsetMs: 60)
        guard let valueMs = proposalValue(session) else {
            Issue.record("expected a proposal, got \(session.screen)")
            return
        }
        #expect(abs(valueMs - 60) <= 6, "the proposal is what the listener heard, got \(valueMs)")
        #expect(recorder.previews.last == valueMs, "the proposal is applied live to be judged")
        #expect(recorder.ticks == [true], "the tick has NOT stopped — there is nothing to hear otherwise")
        #expect(recorder.ends.isEmpty, "nothing persisted or restored until the user answers")

        session.acceptProposal()
        #expect(session.screen == .kept(valueMs: valueMs))
        #expect(recorder.ends == [valueMs], "accepting IS keeping")
        #expect(recorder.ticks == [true, false], "…and the tick stops exactly once")
        session.done()
        session.cancel()
        #expect(recorder.ticks == [true, false], "terminal: no second tick-off edge")
        #expect(recorder.ends == [valueMs], "…and no second write")
    }

    @Test func rejectingAProposalResumesTheQuestions() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        driveTruthfully(session, recorder, trueOffsetMs: 60)
        guard proposalValue(session) != nil else {
            Issue.record("expected a proposal, got \(session.screen)")
            return
        }
        session.rejectProposal()
        guard case .question = session.screen else {
            Issue.record("expected the questions back, got \(session.screen)")
            return
        }
        #expect(recorder.ticks == [true], "the tick never stopped, so it never restarts")
        #expect(recorder.ends.isEmpty, "a rejection persists and restores nothing")
        session.cancel()
    }

    // MARK: The latency run's floor and sign

    /// A fresh speaker's latency base is 0, and its range used to bottom out
    /// there too: "target first" meant the latency had to come DOWN, the
    /// candidate clamped to the same 0, and the run dead-ended on its first
    /// answer. The range gives it somewhere to go.
    @Test func aFreshSpeakersRunCanReverseBelowItsBase() {
        let recorder = Recorder()
        let session = recorder.makeSession(candidateRangeMs: -500...1_500,
                                           invertsEstimate: true)
        session.start()
        session.answer(.target)
        session.answer(.target)
        guard case .question = session.screen else {
            Issue.record("two answers must not end a fresh run, got \(session.screen)")
            return
        }
        #expect(recorder.previews.count == 3, "each answer asks a NEW question")
        #expect(recorder.previews.allSatisfy { (-500...1_500).contains($0) })
        session.cancel()
    }

    /// A run that converges somewhere the Mac would have to be the LATE one
    /// says so instead of storing it. A negative latency is not a thing a
    /// speaker does with the Mac as the zero.
    @Test func aLatencyRunProposingBelowZeroSaysSoAndPersistsNothing() {
        let recorder = Recorder()
        let session = recorder.makeSession(candidateRangeMs: -500...1_500,
                                           invertsEstimate: true)
        session.start()
        driveLatencyRun(session, recorder, trueLatencyMs: -60)
        #expect(session.screen == .macIsLate, "got \(session.screen)")
        #expect(recorder.ends == [nil], "nothing is persisted")
        #expect(recorder.ticks == [true, false], "and the tick stops with the questions")
    }

    @Test func aLatencyRunAboveZeroPersistsTheMeasurementOnAccept() {
        let recorder = Recorder()
        let session = recorder.makeSession(candidateRangeMs: -500...1_500,
                                           invertsEstimate: true)
        session.start()
        driveLatencyRun(session, recorder, trueLatencyMs: 640)
        guard let latencyMs = proposalValue(session) else {
            Issue.record("expected a proposal, got \(session.screen)")
            return
        }
        #expect(abs(latencyMs - 640) <= 6, "got \(latencyMs)")
        session.acceptProposal()
        #expect(recorder.ends == [latencyMs], "accepting persists the measurement")
        #expect(session.measuresLatency, "…and the panel knows which copy to render")
    }

    /// THE sign, pinned. `.target` means the target was heard FIRST, so it is
    /// early and needs MORE delay. A TRIM is added to the delay, so it goes UP.
    /// A measured LATENCY is subtracted from it — a larger latency feeds the
    /// speaker earlier — so it must go DOWN. Getting this backwards compiles
    /// perfectly and converges a run onto the wrong side of the truth.
    @Test func targetFirstRaisesATrimAndLowersAMeasuredLatency() {
        let trimRecorder = Recorder()
        let trim = trimRecorder.makeSession(baseTrimMs: 0)
        trim.start()
        trimRecorder.previews.removeAll()
        trim.answer(.target)
        trim.answer(.target)
        trim.answer(.target)
        #expect(trimRecorder.previews.last ?? 0 > 0,
                "the target is early, so its trim grows — got \(trimRecorder.previews)")
        trim.cancel()

        let latencyRecorder = Recorder()
        let latency = latencyRecorder.makeSession(
            baseTrimMs: 300, candidateRangeMs: 0...1_500, invertsEstimate: true)
        latency.start()
        let opening = latencyRecorder.previews[0]
        latency.answer(.target)
        latency.answer(.target)
        latency.answer(.target)
        #expect(latencyRecorder.previews.last ?? 0 < opening,
                "the target is early, so its latency SHRINKS: \(latencyRecorder.previews)")
        latency.cancel()
    }

    @Test func aLatencyRunStaysInsideItsUsableRange() {
        let recorder = Recorder()
        let session = recorder.makeSession(
            baseTrimMs: 40, candidateRangeMs: 0...600, invertsEstimate: true)
        session.start()
        var asked = 0
        while case .question = session.screen, asked < 100 {
            session.answer(.reference)
            asked += 1
        }
        #expect(recorder.previews.allSatisfy { (0...600).contains($0) },
                "every candidate is inside the usable range")
        session.cancel()
    }

    // MARK: The exit contracts (unchanged behaviour, new screen names)

    @Test func cancelRestoresThePriorTrimAndSilencesTheTick() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: -30)
        session.start()
        session.answer(.target)
        session.cancel()
        #expect(recorder.ends == [nil])
        #expect(recorder.ticks == [true, false])
        let previewCount = recorder.previews.count
        session.answer(.reference)
        #expect(recorder.previews.count == previewCount, "a cancelled session ignores further answers")
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

    /// A listener who names the target at every level runs off the end of the
    /// usable range: the run says it could not find the alignment and puts the
    /// prior trim back. It offers the range's own edge as a proposal on the
    /// way — which the same listener rejects, because it is not what they are
    /// hearing.
    @Test func aRunPinnedAgainstTheTrimRangeEndsUnreachable() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 0)
        session.start()
        let asked = driveAlwaysTarget(session)
        #expect(session.screen == .unreachable, "got \(session.screen) after \(asked) answers")
        #expect(recorder.ends == [nil], "the prior trim is restored, nothing persisted")
        #expect(recorder.ticks == [true, false])

        // The panel's Done button calls `cancel()` on this screen, and the run
        // is already over: a SECOND tick-off edge costs the backend a re-anchor
        // of every sink, for nothing.
        session.cancel()
        #expect(recorder.ticks == [true, false], "exactly one tick-off edge")
        #expect(recorder.ends == [nil], "…and no second restore")
    }

    /// Contradictory answers never land on a value the listener agrees with:
    /// the run offers one, is told it is wrong three times, then bows out and
    /// offers its best guess for the manual control.
    @Test func answersThatNeverSettleBowOutWithABestGuess() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 0)
        session.start()
        let asked = driveContradictorily(session)
        guard case .unsettled(let bestGuessMs) = session.screen else {
            Issue.record("expected unsettled, got \(session.screen) after \(asked)")
            return
        }
        #expect((-BTSyncTrim.rangeMs...BTSyncTrim.rangeMs).contains(bestGuessMs))
        #expect(recorder.ends == [nil], "the prior trim is restored")
        #expect(recorder.ticks == [true, false])
        session.cancel()
        #expect(recorder.ticks == [true, false], "exactly one tick-off edge")
    }

    @Test func tryAgainFromABowOutRestartsWithoutASecondRestore() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 0)
        session.start()
        driveAlwaysTarget(session)
        #expect(session.screen == .unreachable)
        session.tryAgain()
        #expect(recorder.ends == [nil], "the bow-out already restored — no second push")
        #expect(recorder.ticks == [true, false, true], "…and the tick comes back for the fresh run")
        guard case .question(_, _, let answers) = session.screen, answers == 0 else {
            Issue.record("expected a fresh question, got \(session.screen)")
            return
        }
        session.cancel()
    }

    @Test func tryAgainFromAProposalRestoresFirst() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 60)
        session.start()
        driveTruthfully(session, recorder, trueOffsetMs: 10, baseTrimMs: 60)
        guard proposalValue(session) != nil else {
            Issue.record("expected a proposal, got \(session.screen)")
            return
        }
        session.tryAgain()
        #expect(recorder.ends == [nil], "Try again restores the previewed value first")
        #expect(recorder.ticks == [true],
                "the proposal never stopped the tick, so the restart never re-fires it")
        guard case .question(_, _, let answers) = session.screen, answers == 0 else {
            Issue.record("expected a fresh question, got \(session.screen)")
            return
        }
        session.cancel()
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
        guard case .question(_, _, let answers) = session.screen, answers == 0 else {
            Issue.record("expected the first question back, got \(session.screen)")
            return
        }

        session.answer(.target)
        #expect(recorder.previews.last == second, "and the run resumes where it was")
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

    /// The two tick timbres are split by TRANSPORT (the Bluetooth fan-out gets
    /// the bright click, the engine feed the low knock), so whether the pair
    /// sounds different is a fact about the two speakers' transports — and it
    /// follows the reference the user can still swap mid-run.
    @Test func thePairSoundsDifferOnlyAcrossTransports() {
        let recorder = Recorder()
        let session = recorder.makeSession(
            reference: .init(id: "mac", name: "This Mac", isBluetooth: false),
            targetIsBluetooth: true)
        #expect(session.pairSoundsDiffer, "a Bluetooth speaker against the Mac")

        session.setReference(.init(id: "bt-b", name: "Roam", isBluetooth: true))
        #expect(!session.pairSoundsDiffer, "two Bluetooth speakers play one identical click")

        let local = recorder.makeSession(
            reference: .init(id: "homepod", name: "Kitchen HomePod", isBluetooth: false))
        #expect(!local.pairSoundsDiffer, "the Mac against AirPlay is one feed, one sound")
        #expect(!recorder.makeSession(reference: nil).pairSoundsDiffer)
    }

    @Test func changingTheReferenceMidRunRestartsTheRun() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 20)
        session.start()
        session.answer(.target)
        guard case .question(_, _, let before) = session.screen, before == 1 else {
            Issue.record("expected one answer folded in, got \(session.screen)")
            return
        }

        session.setReference(.init(id: "mac", name: "This Mac"))
        #expect(session.reference?.name == "This Mac")
        guard case .question(_, _, let after) = session.screen, after == 0 else {
            Issue.record("answers about the old speaker are dropped, got \(session.screen)")
            return
        }
        #expect(recorder.previews.last == recorder.previews[0],
                "the run starts fresh from the base trim")
        session.cancel()
    }

    @Test func reSelectingTheSameReferenceChangesNothing() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        session.answer(.target)
        session.setReference(.init(id: "homepod", name: "Kitchen HomePod"))
        guard case .question(_, _, let answers) = session.screen, answers == 1 else {
            Issue.record("expected the run to continue, got \(session.screen)")
            return
        }
        #expect(recorder.previews.count == 2)
        session.cancel()
    }

    // MARK: Zero-click

    /// A speaker measured before opens on the PROPOSAL at its stored value —
    /// one click instead of a dozen answers.
    @Test func anOpeningProposalStartsOnTheProposalScreen() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 244,
                                           candidateRangeMs: -500...1_500,
                                           invertsEstimate: true,
                                           openingProposalMs: 244)
        session.start()
        #expect(session.screen == .proposal(valueMs: 244), "got \(session.screen)")
        #expect(recorder.ticks == [true], "the tick runs so the user can judge it")
        #expect(recorder.previews == [244], "…at the stored value")

        session.acceptProposal()
        #expect(session.screen == .kept(valueMs: 244))
        #expect(recorder.ends == [244])
    }

    @Test func rejectingAnOpeningProposalFallsIntoTheOrdinaryQuestions() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 244,
                                           candidateRangeMs: -500...1_500,
                                           invertsEstimate: true,
                                           openingProposalMs: 244)
        session.start()
        session.rejectProposal()
        guard case .question(_, _, let answers) = session.screen, answers == 0 else {
            Issue.record("expected the questions, got \(session.screen)")
            return
        }
        #expect(recorder.ends.isEmpty, "nothing restored — the run is still live")
        session.cancel()
    }

    /// Try again means "that value was wrong", so a restart must never
    /// re-offer it.
    @Test func tryAgainNeverReOffersTheOpeningProposal() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 244,
                                           candidateRangeMs: -500...1_500,
                                           invertsEstimate: true,
                                           openingProposalMs: 244)
        session.start()
        session.tryAgain()
        guard case .question = session.screen else {
            Issue.record("expected questions after a restart, got \(session.screen)")
            return
        }
        session.cancel()
    }

    // MARK: Tempo

    /// Two tempos, driven by how sure the run is: a wide-open run ticks every
    /// 3 s (an unknown 650 ms latency must not alias into an apparent lead at
    /// 833 ms), a closed-in one at 72 BPM.
    @Test func theTempoFollowsTheCredibleIntervalAndOnlyMovesOnAPresentedLevel() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        #expect(recorder.tempos == [BTAlignmentWizardSession.searchTickBPM],
                "a flat prior over ±500 ms is wider than the threshold")
        #expect(BTAlignmentWizardSession.searchTickBPM == 20, "one tick every 3 s")
        // The two values are stated twice — this file is LICENSE-CLEAN and must
        // not reach into the GPL-headered injector for a constant — so pin them
        // together here rather than let them drift apart silently.
        #expect(BTAlignmentWizardSession.searchTickBPM == AlignmentTickInjector.wizardSearchBPM)
        #expect(BTAlignmentWizardSession.blocksTickBPM == AlignmentTickInjector.wizardBlocksBPM)

        driveTruthfully(session, recorder, trueOffsetMs: 10)
        #expect(recorder.tempos == [BTAlignmentWizardSession.searchTickBPM,
                                    BTAlignmentWizardSession.blocksTickBPM],
                "one push per change, never one per question: \(recorder.tempos)")
        session.cancel()
    }

    /// A tight run opens straight on the fine tempo — the threshold is read
    /// off the belief, not off a stage counter that no longer exists.
    @Test func aNarrowRangeOpensOnTheFineTempo() {
        let recorder = Recorder()
        let session = recorder.makeSession(candidateRangeMs: -30...30)
        session.start()
        #expect(recorder.tempos == [BTAlignmentWizardSession.blocksTickBPM],
                "±30 ms is well inside \(BTAlignmentWizardSession.fineTempoHalfWidthMs) ms")
        session.cancel()
    }

    @Test func screenChangesAreAnnounced() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        let asked = driveTruthfully(session, recorder, trueOffsetMs: 10)
        #expect(recorder.screens.count == asked + 1, "start + every answer announced")
        #expect(recorder.screens.last == session.screen)
        session.cancel()
    }
}

/// The proposal telemetry, in the SERIALIZED parent because it installs the
/// process-global capture sink (`SerializedSharedStateSuite.swift`).
extension SerializedSharedState {
    @Suite final class BTAlignmentWizardProposalTelemetryTests {

        /// Collects the lines the sink emits.
        private final class LineCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.withLock { lines.append(line) } }
            func lines(evt: String) -> [String] {
                lock.withLock { lines.filter { $0.contains("\"evt\":\"\(evt)\"") } }
            }
            /// The sink hands lines over on Telemetry's own serial queue, so a
            /// synchronous read races the flush — poll, like the BTSyncedSink
            /// capture does.
            func pollForLines(evt: String, containing needle: String, count: Int,
                              timeout: TimeInterval = 3) async -> [String] {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    let hits = lines(evt: evt).filter { $0.contains(needle) }
                    if hits.count >= count { return hits }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return lines(evt: evt).filter { $0.contains(needle) }
            }
        }

        @Test func acceptAndRejectEachLogTheProposal() async {
            let capture = LineCapture()
            Telemetry._installTestSink { capture.append($0) }
            defer { Telemetry._installTestSink(nil) }

            // The sink is process-global and other suites drive wizards of
            // their own, so the lines are filtered by THIS run's device id.
            let deviceID = "telemetry:output"
            let recorder = Recorder()
            let session = recorder.makeSession(deviceID: deviceID)
            session.start()
            driveTruthfully(session, recorder, trueOffsetMs: 60)
            guard let valueMs = proposalValue(session) else {
                Issue.record("expected a proposal, got \(session.screen)")
                return
            }
            session.rejectProposal()
            driveTruthfully(session, recorder, trueOffsetMs: 60)
            guard proposalValue(session) != nil else {
                Issue.record("expected a second proposal, got \(session.screen)")
                return
            }
            session.acceptProposal()

            let lines = await capture.pollForLines(
                evt: "wizard_proposal", containing: "\"uid\":\"\(deviceID)\"", count: 2)
            guard lines.count == 2 else {
                Issue.record("one line per proposal answered, got \(lines)")
                return
            }
            #expect(lines[0].contains("\"accepted\":\"false\""), "\(lines[0])")
            #expect(lines[0].contains("\"valueMs\":\"\(Int(valueMs.rounded()))\""), "\(lines[0])")
            #expect(lines[0].contains("\"halfWidthMs\""), "\(lines[0])")
            #expect(lines[0].contains("\"answers\""), "\(lines[0])")
            #expect(lines[1].contains("\"accepted\":\"true\""), "\(lines[1])")
        }
    }
}
