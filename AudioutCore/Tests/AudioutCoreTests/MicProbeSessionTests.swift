// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design, like the files under test: no GPL SPDX header.

import Foundation
import ProbeKit
import Testing
@testable import AudioutCore

/// The mic-probe orchestration: a fake recorder plays the acoustic scene, the
/// session must reduce it to the signed Δ — or to nil on every path that
/// cannot produce a trustworthy number.
@Suite struct MicProbeSessionTests {

    /// SplitMix64 — a seed pins the scene, so a failure is reproducible.
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

    private final class FakeRecorder: MicProbeRecording, @unchecked Sendable {
        let rate: Double
        let scene: [Float]
        let failsToStart: Bool
        let firstSampleHostNanos: Int64?
        let roomSlices: [Double]
        private(set) var stopped = false
        init(rate: Double = 8_000, scene: [Float] = [], failsToStart: Bool = false,
             firstSampleHostNanos: Int64? = nil, roomSlices: [Double] = []) {
            self.rate = rate
            self.scene = scene
            self.failsToStart = failsToStart
            self.firstSampleHostNanos = firstSampleHostNanos
            self.roomSlices = roomSlices
        }
        func recentRMSdBFS(seconds: Double, slices: Int) -> [Double] { Array(roomSlices.prefix(slices)) }
        struct StartFailure: Error {}
        func start() throws -> Double {
            if failsToStart { throw StartFailure() }
            return rate
        }
        func stop() -> [Float] { stopped = true; return scene }
        func samplesSoFar() -> [Float] { scene }
    }

    /// A mic capture holding both probe lanes (`SyncProbe.lane`, drone and
    /// glide): the reference lane at `referenceDelay` samples, the Bluetooth
    /// lane at `targetDelay` — one lane spacing earlier, plus the skew under
    /// test. 8 kHz is enough: the glide's top partial is 1 800 Hz.
    private func scene(rate: Double, targetDelay: Int, referenceDelay: Int,
                       targetLevel: Float = 0.4) -> [Float] {
        let lane = SyncProbe.lane(sampleRate: rate)
        let length = max(targetDelay, referenceDelay) + lane.count + Int(rate * 0.5)
        var out = [Float](repeating: 0, count: length)
        for (i, v) in lane.enumerated() {
            out[referenceDelay + i] += 0.5 * v
            out[targetDelay + i] += targetLevel * v
        }
        return out
    }

    /// What a run reported, written from the session's queue and from main.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var completed: MicProbeSession.Result??
        private var lanes: [(lane: MicProbeSession.Lane, heard: Bool)] = []
        private var feedEnd: (() -> Void)?
        func complete(_ result: MicProbeSession.Result?) { lock.withLock { completed = .some(result) } }
        func record(_ lane: MicProbeSession.Lane, _ heard: Bool) { lock.withLock { lanes.append((lane, heard)) } }
        var isComplete: Bool { lock.withLock { completed != nil } }
        var result: MicProbeSession.Result? { lock.withLock { completed ?? nil } }
        var verdicts: [(lane: MicProbeSession.Lane, heard: Bool)] { lock.withLock { lanes } }
        var onFinished: (() -> Void)? {
            get { lock.withLock { feedEnd } }
            set { lock.withLock { feedEnd = newValue } }
        }
    }

    /// Where the target lane sits for a given skew, in samples.
    private func targetDelay(referenceDelay: Int, rate: Double, skewSamples: Int) -> Int {
        referenceDelay - Int(SyncProbe.Layout.laneSpacingSeconds * rate) + skewSamples
    }

    @Test func aCleanSceneReducesToTheSignedDelta() async {
        // Bluetooth lane 60 samples late against its slot at 8 kHz: +7.5 ms.
        let recorder = FakeRecorder(
            rate: 8_000,
            scene: scene(rate: 8_000,
                         targetDelay: targetDelay(referenceDelay: 41_600, rate: 8_000, skewSamples: 60),
                         referenceDelay: 41_600))
        let session = MicProbeSession(recorder: recorder, timeout: 5, pipelineTail: 0.05)
        let result: MicProbeSession.Result? = await withCheckedContinuation { cont in
            session.start(stage: { _, onStarted, onFinished in
                onStarted(0)
                onFinished()
            }, completion: { cont.resume(returning: $0) })
        }
        guard let result else {
            Issue.record("a clean two-lane scene must measure")
            return
        }
        #expect(abs(result.deltaMs - 7.5) < 0.2,
                "Bluetooth late by 60 samples reads +7.5 ms: got \(result.deltaMs)")
        #expect(result.confidence > 5, "a clean scene is confident")
        #expect(recorder.stopped, "the mic is released")
    }

    @Test func aBluetoothSideArrivingEarlyReadsNegative() async {
        let recorder = FakeRecorder(
            rate: 8_000,
            scene: scene(rate: 8_000,
                         targetDelay: targetDelay(referenceDelay: 41_600, rate: 8_000, skewSamples: -100),
                         referenceDelay: 41_600))
        let session = MicProbeSession(recorder: recorder, timeout: 5, pipelineTail: 0.05)
        let result: MicProbeSession.Result? = await withCheckedContinuation { cont in
            session.start(stage: { _, onStarted, onFinished in
                onStarted(0); onFinished()
            }, completion: { cont.resume(returning: $0) })
        }
        #expect(result.map { abs($0.deltaMs - (-12.5)) < 0.2 } == true,
                "Bluetooth early by 100 samples reads −12.5 ms: got \(String(describing: result))")
    }

    /// Turns red if the session stops a fixed margin after the feed end
    /// instead of waiting the reported pipeline delay.
    @Test func theRecordingWaitsTheReportedPipelineDelay() async {
        let recorder = FakeRecorder(rate: 24_000,
                                    scene: [Float](repeating: 0.01, count: 48_000))
        let session = MicProbeSession(recorder: recorder, timeout: 60, pipelineTail: 0.05)
        let clock = ManualDelayClock()
        session.delayClock = clock.queueHoppingClock
        let outcome = Outcome()
        session.start(stage: { _, onStarted, onFinished in
            onStarted(2)
            onFinished()
        }, completion: { outcome.complete($0) })
        await SuiteWait.until("the timeout, both lane checks and the tail to be scheduled") {
            clock.pendingCount == 4
        }
        clock.advance(by: MicProbeSession.pipelineTailMarginSeconds)
        #expect(clock.pendingCount == 4, "the tail still waits out the reported 2 s")
        clock.advance(by: 2)
        await SuiteWait.until("the run to complete") { outcome.isComplete }
    }

    @Test func aRunWhoseProbeNeverPlaysTimesOutToNil() async {
        // The wizard was torn down before the gate armed: neither callback
        // ever fires, and the capture holds nothing but room.
        let recorder = FakeRecorder(rate: 24_000,
                                    scene: [Float](repeating: 0.01, count: 48_000))
        let session = MicProbeSession(recorder: recorder, timeout: 60, pipelineTail: 0.05)
        let clock = ManualDelayClock()
        session.delayClock = clock.queueHoppingClock
        let outcome = Outcome()
        session.start(stage: { _, _, _ in }, completion: { outcome.complete($0) })
        await SuiteWait.until("the timeout to be scheduled") { clock.pendingCount == 1 }
        clock.advance(by: 60)
        await SuiteWait.until("the run to time out") { outcome.isComplete }
        #expect(outcome.result == nil, "no probe in the air can never yield a number")
        #expect(recorder.stopped, "the mic is released even on the timeout path")
    }

    /// Plays a run on a manual clock: both lane checks come due while the mic
    /// still records, then the feed ends and the tail finishes the run.
    private func laneCheckedRun(_ recorder: FakeRecorder) async -> Outcome {
        let session = MicProbeSession(recorder: recorder, timeout: 60)
        let clock = ManualDelayClock()
        session.delayClock = clock.queueHoppingClock
        let outcome = Outcome()
        session.onLaneVerdict = { outcome.record($0, $1) }
        session.start(stage: { _, onStarted, onFinished in
            outcome.onFinished = onFinished
            onStarted(0)
        }, completion: { outcome.complete($0) })
        await SuiteWait.until("the timeout and both lane checks to be scheduled") {
            clock.pendingCount == 3
        }
        clock.advance(by: 10)
        await SuiteWait.until("both lanes to be checked") { outcome.verdicts.count == 2 }
        outcome.onFinished?()
        await SuiteWait.until("the tail to be scheduled") { clock.pendingCount == 2 }
        clock.advance(by: 2)
        await SuiteWait.until("the run to complete") { outcome.isComplete }
        return outcome
    }

    /// Turns red if a lane check reads the wrong window, demands the wrong
    /// confidence, or the mid-run check alters the final measurement.
    @Test func bothLanesAreHeardMidRunAndTheMeasurementStands() async {
        let recorder = FakeRecorder(
            rate: 8_000,
            scene: scene(rate: 8_000,
                         targetDelay: targetDelay(referenceDelay: 41_600, rate: 8_000, skewSamples: 60),
                         referenceDelay: 41_600))
        let outcome = await laneCheckedRun(recorder)
        #expect(outcome.verdicts.map(\.lane) == [.bluetooth, .engine])
        #expect(outcome.verdicts.map(\.heard) == [true, true], "both lanes are in the capture")
        #expect(outcome.result.map { abs($0.deltaMs - 7.5) < 0.2 } == true,
                "the final reading is still +7.5 ms: got \(String(describing: outcome.result))")
    }

    /// Turns red if a silent lane is reported heard or a missing lane stops
    /// being a refused measurement.
    @Test func aMissingBluetoothLaneIsReportedMissedAndRefused() async {
        let recorder = FakeRecorder(
            rate: 8_000,
            scene: scene(rate: 8_000,
                         targetDelay: targetDelay(referenceDelay: 41_600, rate: 8_000, skewSamples: 60),
                         referenceDelay: 41_600, targetLevel: 0))
        let outcome = await laneCheckedRun(recorder)
        #expect(outcome.verdicts.map(\.lane) == [.bluetooth, .engine])
        #expect(outcome.verdicts.map(\.heard) == [false, true], "only the engine lane sounded")
        #expect(outcome.isComplete && outcome.result == nil, "one lane is no measurement")
    }

    @Test func aRecorderThatCannotStartCompletesNil() async {
        let recorder = FakeRecorder(failsToStart: true)
        let session = MicProbeSession(recorder: recorder, timeout: 1, pipelineTail: 0.05)
        let result: MicProbeSession.Result? = await withCheckedContinuation { cont in
            session.start(stage: { _, _, _ in
                Issue.record("no recorder means nothing to stage a probe for")
            }, completion: { cont.resume(returning: $0) })
        }
        #expect(result == nil)
        #expect(!recorder.stopped, "a recorder that never started is not stopped")
    }

    @Test func cancelCompletesNilWithoutAnalysis() async {
        let recorder = FakeRecorder(
            rate: 8_000,
            scene: scene(rate: 8_000,
                         targetDelay: targetDelay(referenceDelay: 41_600, rate: 8_000, skewSamples: 60),
                         referenceDelay: 41_600))
        let session = MicProbeSession(recorder: recorder, timeout: 5, pipelineTail: 5)
        let result: MicProbeSession.Result? = await withCheckedContinuation { cont in
            session.start(stage: { _, onStarted, _ in onStarted(0) },
                          completion: { cont.resume(returning: $0) })
            session.cancel()
        }
        #expect(result == nil, "a cancelled run reports nothing, even over a scene that would measure")
    }

    /// The level step follows the room the lead-in heard: quiet rooms play at
    /// the staged level, louder ones 6 or 12 dB up. Turns red if
    /// `MicProbeSession.levelStepDB(ambientRMSdBFS:)` moves a threshold or
    /// stops treating an unreadable room as quiet.
    @Test func theLevelStepFollowsTheRoom() {
        let step = MicProbeSession.levelStepDB
        #expect(step(nil) == 0)
        #expect(step(-75) == 0)
        #expect(step(-68) == 0)
        #expect(step(-67.9) == 6)
        #expect(step(-62) == 6)
        #expect(step(-61.9) == 12)
        #expect(step(-50) == 12)
    }

    /// The stage closure's level question is answered from the recorder's own
    /// reading of the room. Turns red if `MicProbeSession.start` stops passing
    /// `recentRMSdBFS(seconds:slices:)` through `levelStepDB(ambientRMSdBFS:)`.
    @Test func theStageClosureAsksTheRecorderForTheRoom() async {
        let recorder = FakeRecorder(rate: 8_000, scene: [], roomSlices: [-55])
        let session = MicProbeSession(recorder: recorder, timeout: 1, pipelineTail: 0.05)
        final class Box: @unchecked Sendable { var step: Int? }
        let box = Box()
        _ = await withCheckedContinuation { (cont: CheckedContinuation<MicProbeSession.Result?, Never>) in
            session.start(stage: { levelStepDB, onStarted, onFinished in
                box.step = levelStepDB()
                onStarted(0); onFinished()
            }, completion: { cont.resume(returning: $0) })
        }
        #expect(box.step == 12, "a −55 dBFS room asks for the +12 dB step")
    }

    /// The live read is the newest 0.1 s level minus the room the level step measured.
    /// Turns red if `levelAboveRoomDB` stops subtracting the measured room level, or answers before the room was measured.
    @Test func theLiveLevelReadSubtractsTheMeasuredRoom() async {
        let recorder = FakeRecorder(rate: 8_000, scene: [], roomSlices: [-50, -70, -72])
        let session = MicProbeSession(recorder: recorder, timeout: 60)
        let clock = ManualDelayClock()
        session.delayClock = clock.queueHoppingClock
        let outcome = Outcome()
        #expect(session.levelAboveRoomDB() == nil, "no room level before the level step ran")
        // The room level is written inside the level step itself, so the read
        // right after it needs no clock.
        let above: Double? = await withCheckedContinuation { cont in
            session.start(stage: { levelStepDB, _, _ in
                _ = levelStepDB()
                cont.resume(returning: session.levelAboveRoomDB())
            }, completion: { outcome.complete($0) })
        }
        #expect(above != nil && abs(above! - 22) < 0.01, "newest −50 over the quietest −72 is 22 dB")
        session.cancel()
        await SuiteWait.until("the cancelled run to complete") { outcome.isComplete }
    }

    /// Music the wizard just silenced is still loud in the newest half second
    /// while an older slice already hears the quiet room. Turns red if
    /// `MicProbeSession.start` reads the room from the newest slice alone (or
    /// any slice but the quietest) instead of the minimum of the last three.
    @Test func aLoudNewestSliceOverAQuietRoomKeepsTheStagedLevel() async {
        let recorder = FakeRecorder(rate: 8_000, scene: [], roomSlices: [-50, -75, -55])
        let session = MicProbeSession(recorder: recorder, timeout: 1, pipelineTail: 0.05)
        final class Box: @unchecked Sendable { var step: Int? }
        let box = Box()
        _ = await withCheckedContinuation { (cont: CheckedContinuation<MicProbeSession.Result?, Never>) in
            session.start(stage: { levelStepDB, onStarted, onFinished in
                box.step = levelStepDB()
                onStarted(0); onFinished()
            }, completion: { cont.resume(returning: $0) })
        }
        #expect(box.step == 0, "the quietest slice, −75 dBFS, is the room: no level step")
    }

    /// The live 2026-08-28 refusal: the ambient slice carries the tail of the
    /// user's music (loud, broadband, gone by probe time), the SNR weighting
    /// crushes the probe band, and the weighted pass finds nothing. The
    /// unweighted fallback must still measure.
    @Test func aMusicTailInTheAmbientSliceCannotRefuseTheMeasurement() throws {
        let rate = 8_000.0
        var scene = scene(rate: rate,
                          targetDelay: targetDelay(referenceDelay: 52_000, rate: rate, skewSamples: 60),
                          referenceDelay: 52_000)
        // Two seconds of loud broadband "music" at the head — ambient only,
        // absent during the probe.
        var rng = SeededRNG(seed: 42)
        for i in 0..<16_000 {
            let u1 = Double.random(in: 1e-12..<1, using: &rng)
            let u2 = Double.random(in: 0..<1, using: &rng)
            scene[i] += Float(0.5 * (-2 * Foundation.log(u1)).squareRoot()
                              * Foundation.cos(2 * .pi * u2))
        }
        let result = try #require(
            MicProbeSession.analyze(recording: scene, sampleRate: rate,
                                    ambientEnd: 15_000),
            "stale ambient noise must never veto a clean lane pair")
        #expect(abs(result.deltaMs - 7.5) < 0.3,
                "the fallback still measures the true Δ: got \(result.deltaMs)")
    }

    /// Live, 2026-09-26, with the Bluetooth speaker silent: false matches at
    /// confidence 7.2 (−4,876 ms) and 55.3 (668 ms). The speaker's real
    /// arrivals that day scored 684 to 1,724.
    @Test func aWeakOrImpossibleMeasurementIsRefused() {
        let accept = MicProbeSession.accepting
        #expect(accept(.init(deltaMs: -4_876.46, confidence: 7.2, peakMargin: 10)) == nil,
                "the live false match is refused")
        #expect(accept(.init(deltaMs: 441.28, confidence: 7.2, peakMargin: 10)) == nil,
                "a weak match is refused even at a plausible delay")
        #expect(accept(.init(deltaMs: -4_876.46, confidence: 683.8, peakMargin: 10)) == nil,
                "a delay beyond the reference buffer is refused however strong")
        #expect(accept(.init(deltaMs: 441.28, confidence: 683.8, peakMargin: 10)) != nil,
                "the weakest true reading of the day still lands")
        #expect(accept(.init(deltaMs: 441.28, confidence: 683.8, peakMargin: 1.9)) == nil,
                "a rival within 6 dB of the winner is refused however strong")
        #expect(accept(.init(deltaMs: 441.28, confidence: 683.8, peakMargin: 2.0)) != nil,
                "a winner just past 6 dB over its rival lands")
    }

    /// A 15 s capture whose first sample was taken 3 s before the arm gate
    /// opened, on a pinned clock (not wall time): two seconds of loud broadband sound at the head (music still
    /// draining out of the speakers), then quiet room, the reference lane at
    /// 3.6 s + one lane spacing and, when `bluetoothSkewMs` is set, the
    /// Bluetooth lane one spacing earlier, late by that skew.
    private func loudHeadRun(bluetoothSkewMs: Double?) async -> MicProbeSession.Result? {
        let rate = 8_000.0
        let lane = SyncProbe.lane(sampleRate: rate)
        let referenceAt = Int((3.6 + SyncProbe.Layout.laneSpacingSeconds) * rate)
        var rng = SeededRNG(seed: 7)
        func gauss() -> Double {
            let u1 = Double.random(in: 1e-12..<1, using: &rng)
            let u2 = Double.random(in: 0..<1, using: &rng)
            return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
        var scene: [Float] = (0..<Int(15 * rate)).map { i in
            let t = Double(i) / rate
            return Float(0.002 * gauss() + (t < 2 ? 0.05 * gauss() : 0))
        }
        for (i, v) in lane.enumerated() { scene[referenceAt + i] += 0.0875 * v }
        if let bluetoothSkewMs {
            let targetAt = targetDelay(referenceDelay: referenceAt, rate: rate,
                                       skewSamples: Int(bluetoothSkewMs / 1000 * rate))
            for (i, v) in lane.enumerated() { scene[targetAt + i] += 0.02 * v }
        }
        let armGateNanos: Int64 = 1_000_000_000_000
        let recorder = FakeRecorder(rate: rate, scene: scene,
                                    firstSampleHostNanos: armGateNanos - 3_000_000_000)
        let session = MicProbeSession(recorder: recorder, timeout: 5, pipelineTail: 0.05,
                                      now: { armGateNanos })
        return await withCheckedContinuation { cont in
            session.start(stage: { _, onStarted, onFinished in onStarted(0); onFinished() },
                          completion: { cont.resume(returning: $0) })
        }
    }

    /// Customer, v1.2.0: the Bluetooth probe never reached the mic, and the
    /// loudest stretch of what played BEFORE the probe was taken for it —
    /// `ok=1 confidence=5.9–7.9`, Δ −778 to −3748 ms, shown as "implausible".
    /// Nothing before the probe can be a lane, so the run must fail.
    @Test func soundBeforeTheSweepsIsNeverTakenForAMissingSweep() async {
        let result = await loudHeadRun(bluetoothSkewMs: nil)
        #expect(result == nil,
                "a missing Bluetooth lane is a failed listen, not a Δ: got \(String(describing: result))")
    }

    @Test func aRealPairAfterALoudHeadStillMeasures() async {
        let result = await loudHeadRun(bluetoothSkewMs: 300)
        #expect(result.map { abs($0.deltaMs - 300) < 0.5 } == true,
                "the lanes themselves are still found: got \(String(describing: result))")
    }
}

/// A measured value arriving mid-run becomes the wizard's proposal — the
/// mic probe's landing spot (roadmap 064). The flat-prior fence holds: the
/// belief is untouched, the proposal is a UI shortcut.
@Suite struct WizardMeasuredProposalTests {

    private func makeSession(invertsEstimate: Bool = true,
                             baseValueMs: Double = 100) -> BTAlignmentWizardSession {
        BTAlignmentWizardSession(
            deviceID: "dev",
            targetName: "Speaker",
            reference: .init(id: "ref", name: "Mac", isBluetooth: false),
            targetIsBluetooth: true,
            baseValueMs: baseValueMs,
            candidateRangeMs: invertsEstimate ? -500...500 : -500...500,
            invertsEstimate: invertsEstimate,
            applyPreviewTrim: { _, _ in },
            endPreview: { _ in },
            setTick: { _ in })
    }

    @Test func aMeasuredValueBecomesTheProposalMidQuestions() {
        let session = makeSession()
        session.start()
        guard case .question = session.screen else {
            Issue.record("a fresh run opens on questions; got \(session.screen)")
            return
        }
        session.offerMeasuredProposal(valueMs: 240)
        #expect(session.screen == .proposal(valueMs: 240),
                "the measurement is presented at its own value, in value space")
    }

    @Test func theMeasuredProposalWorksInBothValueSpaces() {
        let trimRun = makeSession(invertsEstimate: false, baseValueMs: 10)
        trimRun.start()
        trimRun.offerMeasuredProposal(valueMs: 25)
        #expect(trimRun.screen == .proposal(valueMs: 25),
                "a non-inverted (Mac trim) run presents the same value")
    }

    @Test func anOutOfRangeMeasurementIsClampedNotTrusted() {
        let session = makeSession()
        session.start()
        session.offerMeasuredProposal(valueMs: 9_999)
        guard case .proposal(let valueMs) = session.screen else {
            Issue.record("expected a proposal; got \(session.screen)")
            return
        }
        #expect(valueMs <= 500, "the sink's usable range bounds every proposal")
    }

    @Test func aMeasurementBeforeStartOrAfterProposingIsDropped() {
        let session = makeSession()
        session.offerMeasuredProposal(valueMs: 240)
        #expect(session.screen == .intro, "no run yet — nothing to propose into")

        session.start()
        session.offerMeasuredProposal(valueMs: 240)
        session.offerMeasuredProposal(valueMs: 300)
        #expect(session.screen == .proposal(valueMs: 240),
                "a second measurement cannot shove aside the one being judged")
    }

    @Test func rejectingTheMeasuredProposalResumesTheQuestions() {
        let session = makeSession()
        session.start()
        session.offerMeasuredProposal(valueMs: 240)
        session.rejectProposal()
        guard case .question = session.screen else {
            Issue.record("a rejected measurement hands back to the by-ear run; got \(session.screen)")
            return
        }
    }

    @Test func acceptingTheMeasuredProposalKeepsItsExactValue() {
        var kept: Double?
        let session = BTAlignmentWizardSession(
            deviceID: "dev", targetName: "Speaker",
            reference: .init(id: "ref", name: "Mac", isBluetooth: false),
            targetIsBluetooth: true,
            baseValueMs: 100,
            invertsEstimate: true,
            applyPreviewTrim: { _, _ in },
            endPreview: { kept = $0 },
            setTick: { _ in })
        session.start()
        session.offerMeasuredProposal(valueMs: 240)
        session.acceptProposal()
        #expect(kept == 240, "the value heard is the value persisted")
        #expect(session.screen == .kept(valueMs: 240))
    }
}
