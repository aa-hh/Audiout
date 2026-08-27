// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design, like the files under test: no GPL SPDX header.

import Foundation
import Testing
@testable import AudioutCore

/// The mic-probe orchestration: a fake recorder plays the acoustic scene, the
/// session must reduce it to the signed Δ — or to nil on every path that
/// cannot produce a trustworthy number.
@Suite struct MicProbeSessionTests {

    private final class FakeRecorder: MicProbeRecording, @unchecked Sendable {
        let rate: Double
        let scene: [Float]
        let failsToStart: Bool
        private(set) var stopped = false
        init(rate: Double = 8_000, scene: [Float] = [], failsToStart: Bool = false) {
            self.rate = rate
            self.scene = scene
            self.failsToStart = failsToStart
        }
        struct StartFailure: Error {}
        func start() throws -> Double {
            if failsToStart { throw StartFailure() }
            return rate
        }
        func stop() -> [Float] { stopped = true; return scene }
    }

    /// A mic capture holding both sweeps: DOWN (the reference lane) at
    /// `downDelay` samples, UP (the Bluetooth lane) at `upDelay`.
    private func scene(rate: Double, downDelay: Int, upDelay: Int) -> [Float] {
        let down = SyncProbe.SweepDesign.downSweep(sampleRate: rate,
                                                   duration: MicProbeSession.sweepSeconds)
        let up = SyncProbe.SweepDesign.upSweep(sampleRate: rate,
                                               duration: MicProbeSession.sweepSeconds)
        let length = max(downDelay, upDelay) + Int(rate * 1.5)
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let sample = 0.5 * SyncProbe.value(down, at: Double(i - downDelay) / rate)
                + 0.4 * SyncProbe.value(up, at: Double(i - upDelay) / rate)
            out[i] = Float(sample)
        }
        return out
    }

    @Test func aCleanSceneReducesToTheSignedDelta() async {
        // UP (Bluetooth) 60 samples after DOWN (reference) at 8 kHz: +7.5 ms.
        let recorder = FakeRecorder(rate: 8_000,
                                    scene: scene(rate: 8_000, downDelay: 5_600,
                                                 upDelay: 5_660))
        let session = MicProbeSession(recorder: recorder, timeout: 5, pipelineTail: 0.05)
        let result: MicProbeSession.Result? = await withCheckedContinuation { cont in
            session.start(stage: { onStarted, onFinished in
                onStarted()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02, execute: onFinished)
            }, completion: { cont.resume(returning: $0) })
        }
        guard let result else {
            Issue.record("a clean two-sweep scene must measure")
            return
        }
        #expect(abs(result.deltaMs - 7.5) < 0.2,
                "Bluetooth late by 60 samples reads +7.5 ms: got \(result.deltaMs)")
        #expect(result.confidence > 5, "a clean scene is confident")
        #expect(recorder.stopped, "the mic is released")
    }

    @Test func aBluetoothSideArrivingEarlyReadsNegative() async {
        let recorder = FakeRecorder(rate: 8_000,
                                    scene: scene(rate: 8_000, downDelay: 5_660,
                                                 upDelay: 5_560))
        let session = MicProbeSession(recorder: recorder, timeout: 5, pipelineTail: 0.05)
        let result: MicProbeSession.Result? = await withCheckedContinuation { cont in
            session.start(stage: { onStarted, onFinished in
                onStarted(); onFinished()
            }, completion: { cont.resume(returning: $0) })
        }
        #expect(result.map { abs($0.deltaMs - (-12.5)) < 0.2 } == true,
                "Bluetooth early by 100 samples reads −12.5 ms: got \(String(describing: result))")
    }

    @Test func aRunWhoseProbeNeverPlaysTimesOutToNil() async {
        // The wizard was torn down before the gate armed: neither callback
        // ever fires, and the capture holds nothing but room.
        let recorder = FakeRecorder(rate: 8_000,
                                    scene: [Float](repeating: 0.01, count: 16_000))
        let session = MicProbeSession(recorder: recorder, timeout: 0.2, pipelineTail: 0.05)
        let result: MicProbeSession.Result? = await withCheckedContinuation { cont in
            session.start(stage: { _, _ in }, completion: { cont.resume(returning: $0) })
        }
        #expect(result == nil, "no probe in the air can never yield a number")
        #expect(recorder.stopped, "the mic is released even on the timeout path")
    }

    @Test func aRecorderThatCannotStartCompletesNil() async {
        let recorder = FakeRecorder(failsToStart: true)
        let session = MicProbeSession(recorder: recorder, timeout: 1, pipelineTail: 0.05)
        let result: MicProbeSession.Result? = await withCheckedContinuation { cont in
            session.start(stage: { _, _ in
                Issue.record("no recorder means nothing to stage a probe for")
            }, completion: { cont.resume(returning: $0) })
        }
        #expect(result == nil)
        #expect(!recorder.stopped, "a recorder that never started is not stopped")
    }

    @Test func cancelCompletesNilWithoutAnalysis() async {
        let recorder = FakeRecorder(rate: 8_000,
                                    scene: scene(rate: 8_000, downDelay: 5_600,
                                                 upDelay: 5_660))
        let session = MicProbeSession(recorder: recorder, timeout: 5, pipelineTail: 5)
        let result: MicProbeSession.Result? = await withCheckedContinuation { cont in
            session.start(stage: { onStarted, _ in onStarted() },
                          completion: { cont.resume(returning: $0) })
            session.cancel()
        }
        #expect(result == nil, "a cancelled run reports nothing, even over a scene that would measure")
    }

    /// The session's sweep length must stay in lock-step with the injector's —
    /// they render the same probes from two files.
    @Test func sessionAndInjectorAgreeOnTheSweepLength() {
        #expect(MicProbeSession.sweepSeconds == AlignmentTickInjector.probeSweepSeconds)
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
