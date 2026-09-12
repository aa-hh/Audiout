import AirPlayEngine
import Foundation
import ProbeKit
import Testing
@testable import AudioutCore

/// Roadmap 085 ticket 03: attribution of correlation peaks to speakers, and the
/// loop that feeds it. Synthetic scenes only — no mic, no devices.
@Suite struct PassiveDriftSamplerTests {

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

    private static let rate = 16_000.0

    /// Broadband program audio: the one thing music has to be for any of this
    /// to work, and what the correlator's suitability checks demand.
    private static func program(seconds: Double, seed: UInt64 = 7) -> [Float] {
        var rng = SeededRNG(seed: seed)
        return (0..<Int(seconds * rate)).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
    }

    /// What the mic hears: every speaker playing the same program, each at its
    /// own delay.
    private static func capture(of reference: [Float], delaysMs: [Double],
                                tailSeconds: Double = 0.3) -> [Float] {
        var out = [Float](repeating: 0, count: reference.count + Int(tailSeconds * rate))
        for delayMs in delaysMs {
            let delay = Int((delayMs / 1000 * rate).rounded())
            for i in 0..<reference.count where delay + i < out.count {
                out[delay + i] += reference[i] * 0.6
            }
        }
        return out
    }

    private static func sampler(_ baselines: [PassiveDriftSampler.Baseline])
        -> PassiveDriftSampler {
        var sampler = PassiveDriftSampler(baselines: baselines)
        // Narrower than the 120 ms product default so two synthetic speakers
        // 120 ms apart cannot sit inside each other's search window.
        sampler.searchHalfWidthMs = 30
        return sampler
    }

    private static func analyze(_ sampler: inout PassiveDriftSampler,
                                delaysMs: [Double],
                                hostNanos: Int64 = 1_000) -> PassiveDriftSampler.Outcome {
        let reference = program(seconds: 1)
        return sampler.analyze(reference: reference, referenceRate: rate,
                               capture: capture(of: reference, delaysMs: delaysMs),
                               captureRate: rate, hostNanos: hostNanos)
    }

    private static func bluetooth(_ uid: String, _ ms: Double) -> PassiveDriftSampler.Baseline {
        .init(deviceUID: uid, kind: .bluetooth, expectedDelayMs: ms)
    }

    // MARK: -

    /// THE DEFECT. Attribution is the whole reason this ticket exists: if the
    /// moved peak is matched to the wrong baseline, the tracker corrects a
    /// speaker that was in sync and pushes the one that jumped further out.
    @Test func oneMovedPeakIsAttributedToThatSpeakerAlone() {
        var sampler = Self.sampler([Self.bluetooth("A", 60), Self.bluetooth("B", 180)])
        let outcome = Self.analyze(&sampler, delaysMs: [60, 200], hostNanos: 42)
        guard case .observations(let observations) = outcome else {
            Issue.record("expected observations, got \(outcome)")
            return
        }
        #expect(observations.count == 2)
        let a = try? #require(observations.first { $0.deviceUID == "A" })
        let b = try? #require(observations.first { $0.deviceUID == "B" })
        #expect(abs(a?.errorMs ?? 99) < 2, "the speaker that did not move reads ~0")
        #expect(abs((b?.errorMs ?? 0) - 20) < 2, "B sounded 20 ms late")
        #expect(b?.isBestGuess == false, "one peak moved: the match is unambiguous")
        #expect(b?.hostNanos == 42)
    }

    /// THE DEFECT. A mic that cannot hear the speakers must go quiet, and it
    /// must never emit a delta on the way there — a correction computed from
    /// an unusable window moves a speaker on noise.
    @Test func unusableWindowsDisableTrackingAndNeverEmit() {
        var sampler = Self.sampler([Self.bluetooth("A", 60)])
        let silence = [Float](repeating: 0, count: Int(Self.rate))
        for window in 1...PassiveDriftSampler.blindAfterUnusableWindows {
            let outcome = sampler.analyze(reference: silence, referenceRate: Self.rate,
                                          capture: silence, captureRate: Self.rate,
                                          hostNanos: 0)
            #expect(outcome == .unusable(.referenceTooQuiet))
            #expect(sampler.isBlind == (window == PassiveDriftSampler.blindAfterUnusableWindows))
        }
        #expect(Self.analyze(&sampler, delaysMs: [60]) == .blind,
                "a blind sampler measures nothing until it is re-armed")
        sampler.reArm()
        #expect(sampler.isBlind == false)
    }

    /// THE DEFECT (spec decision 13). An AirPlay or Cast receiver runs on the
    /// room reference clock and cannot drift, so a peak of one that is off
    /// baseline measures the MIC. Correcting that device would fight the
    /// reference clock, and leaving the offset in would push every Bluetooth
    /// speaker by the amount the mic moved.
    @Test func anAirPlayPeakCalibratesTheMicAndIsNeverCorrected() {
        var sampler = Self.sampler([
            Self.bluetooth("bt", 60),
            .init(deviceUID: "homepod", kind: .homePod, expectedDelayMs: 180),
        ])
        // The mic moved ~5 m further away: every arrival is 15 ms later.
        let outcome = Self.analyze(&sampler, delaysMs: [75, 195])
        guard case .observations(let observations) = outcome else {
            Issue.record("expected observations, got \(outcome)")
            return
        }
        #expect(observations.map(\.deviceUID) == ["bt"], "the anchor is read-only")
        #expect(abs(observations[0].errorMs) < 2,
                "the anchor's own deviation is the mic offset, taken out of the BT error")
        #expect(abs((sampler.baselines.first { $0.deviceUID == "bt" }?.expectedDelayMs ?? 0) - 75) < 2,
                "the mic offset is folded into the baselines")
    }

    /// THE DEFECT (spec decision 8). The Mac has no motion sensor, so a mic
    /// that was moved looks exactly like every speaker jumping at once. Acting
    /// on it would trim every speaker by the mic's displacement and leave the
    /// room genuinely out of sync.
    @Test func everySpeakerShiftedTogetherRebaselinesInsteadOfCorrecting() {
        var sampler = Self.sampler([Self.bluetooth("A", 60), Self.bluetooth("B", 180)])
        let outcome = Self.analyze(&sampler, delaysMs: [75, 195])
        guard case .rebaselined(let shiftMs) = outcome else {
            Issue.record("expected a re-baseline, got \(outcome)")
            return
        }
        #expect(abs(shiftMs - 15) < 2)
        #expect(sampler.baselines.allSatisfy { $0.expectedDelayMs > 70 })
    }
}

/// The tracker end to end: the retained program out of ``ReferenceAudioRing``,
/// a mic capture beside it, and the pts arithmetic that has to put the two on
/// one timeline.
@Suite struct PassiveDriftTrackerTests {

    /// A recorder whose `start()` feeds the ring — the tracker arms the ring
    /// just before it, so this is the race-free moment to put program audio in.
    private final class FeedingRecorder: MicProbeRecording, @unchecked Sendable {
        let rate: Double
        let startNanos: Int64
        let scene: @Sendable () -> [Float]
        let feed: @Sendable () -> Void
        init(rate: Double, startNanos: Int64,
             scene: @escaping @Sendable () -> [Float],
             feed: @escaping @Sendable () -> Void) {
            self.rate = rate
            self.startNanos = startNanos
            self.scene = scene
            self.feed = feed
        }
        func start() throws -> Double { feed(); return rate }
        func stop() -> [Float] { scene() }
        var firstSampleHostNanos: Int64? { startNanos }
    }

    /// THE DEFECT. The alignment arithmetic is this side's job per the
    /// correlator's contract: if the reference slice does not start at the
    /// mic's own first sample, or the ring's interleaved S16LE is unpacked
    /// wrongly, every measured delay is biased and every correction is wrong
    /// by the same amount.
    @Test func aDelayedSpeakerInTheRingProducesAnAttributedObservation() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000
        let frames = Int(rate)                 // one second of program
        let delayFrames = Int(0.120 * rate)    // heard 120 ms after it was sent

        var state: UInt64 = 99
        var mono = [Float](repeating: 0, count: frames)
        var pcm = Data(count: frames * 2 * MemoryLayout<Int16>.size)
        pcm.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let samples = buffer.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = Int16(truncatingIfNeeded: Int(state >> 33) % 12_000 - 6_000)
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
                mono[frame] = Float(value) / 32_768
            }
        }
        var scene = [Float](repeating: 0, count: frames)
        for i in 0..<(frames - delayFrames) { scene[delayFrames + i] = mono[i] * 0.6 }

        let ring = ReferenceAudioRing()
        let observations = UncheckedBox<[DriftCorrectionPolicy.Observation]>([])
        let done = DispatchSemaphore(value: 0)
        let program = pcm
        let tracker = PassiveDriftTracker(
            ring: ring,
            windowSeconds: 0.4,
            // The ring retains nothing until the window arms it, and the window
            // closes on its own clock: feeding from `start()` — which the
            // tracker calls just after arming — is the only point that cannot
            // race the window shut under a loaded machine.
            makeRecorder: {
                FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { scene },
                                feed: { ring.append(program, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            onObservations: { observations.value = $0; done.signal() })
        // Baseline 100 ms; the speaker is heard at 120 ms.
        tracker.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])

        tracker.trigger(.reconnect)
        #expect(done.wait(timeout: .now() + 10) == .success, "no observation was emitted")

        let emitted = try #require(observations.value.first)
        #expect(emitted.deviceUID == "bt")
        #expect(abs(emitted.errorMs - 20) < 2, "120 ms heard against a 100 ms baseline")
        #expect(emitted.hostNanos == startNanos)
    }

    /// THE DEFECT. Going blind cancels the periodic timer; a re-calibration
    /// re-arms the sampler but used to leave the timer dead, so after one blind
    /// spell the tracker only ever sampled on an event trigger — for the rest
    /// of the session.
    @Test func reArmingAfterABlindSpellRestartsPeriodicSampling() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000
        let frames = Int(rate)
        let delayFrames = Int(0.120 * rate)

        var state: UInt64 = 99
        var mono = [Float](repeating: 0, count: frames)
        var pcm = Data(count: frames * 2 * MemoryLayout<Int16>.size)
        pcm.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let samples = buffer.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = Int16(truncatingIfNeeded: Int(state >> 33) % 12_000 - 6_000)
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
                mono[frame] = Float(value) / 32_768
            }
        }
        var heard = [Float](repeating: 0, count: frames)
        for i in 0..<(frames - delayFrames) { heard[delayFrames + i] = mono[i] * 0.6 }
        let silence = [Float](repeating: 0, count: frames)

        let ring = ReferenceAudioRing()
        let program = pcm
        // The mic hears nothing until the re-arm, so the first windows are
        // unusable and the tracker goes blind.
        let micIsDeaf = UncheckedBox<Bool>(true)
        let observations = UncheckedBox<[DriftCorrectionPolicy.Observation]>([])
        let done = DispatchSemaphore(value: 0)
        let tracker = PassiveDriftTracker(
            ring: ring,
            windowSeconds: 0.05,
            intervalSeconds: 0.1,
            makeRecorder: {
                FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { micIsDeaf.value ? silence : heard },
                                feed: { ring.append(program, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            onObservations: { observations.value = $0; done.signal() })
        let baseline = PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)
        tracker.setBaselines([baseline])
        tracker.start()

        // A trigger landing while a window is already in flight is dropped, so
        // drive until it goes quiet rather than counting triggers.
        for _ in 1...(PassiveDriftSampler.blindAfterUnusableWindows * 4)
        where !tracker.isBlind {
            tracker.trigger(.reconnect)
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        #expect(tracker.isBlind, "unusable windows should have gone quiet")

        micIsDeaf.value = false
        tracker.setBaselines([baseline])
        // No trigger from here on: only the periodic timer can produce this.
        #expect(done.wait(timeout: .now() + 10) == .success,
                "periodic sampling never resumed after the re-arm")
        #expect(observations.value.first?.deviceUID == "bt")
    }
}

/// A box for a value two queues touch in a test.
private final class UncheckedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
