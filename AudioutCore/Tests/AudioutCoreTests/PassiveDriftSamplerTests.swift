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

    /// THE DEFECT. Two speakers that each moved onto a peak of their own could
    /// equally have moved onto each other's. The assignment is the likeliest
    /// of several, and a correction taken on it without a verify moves both
    /// speakers the wrong way (spec decision 7).
    @Test func twoSpeakersThatBothMovedAreMatchedByGuess() {
        var sampler = Self.sampler([Self.bluetooth("A", 60), Self.bluetooth("B", 180)])
        let outcome = Self.analyze(&sampler, delaysMs: [85, 195])
        guard case .observations(let observations) = outcome else {
            Issue.record("expected observations, got \(outcome)")
            return
        }
        #expect(observations.count == 2)
        #expect(observations.allSatisfy { $0.isBestGuess })
    }

    /// THE DEFECT. A speaker left with no peak at all, because the one nearest
    /// it went to another speaker, is the same ambiguity seen from the other
    /// side: the speaker that DID take that peak may be sitting on the wrong
    /// one.
    @Test func aSpeakerLeftWithNoPeakMakesTheOtherMatchAGuess() {
        var sampler = Self.sampler([Self.bluetooth("A", 60), Self.bluetooth("B", 100)])
        let outcome = Self.analyze(&sampler, delaysMs: [85, 120])
        guard case .observations(let observations) = outcome else {
            Issue.record("expected observations, got \(outcome)")
            return
        }
        #expect(observations.map { $0.deviceUID } == ["B"], "A was left unmatched")
        #expect(observations.first?.isBestGuess == true)
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

    /// THE DEFECT (live, 2026-09-13): two speakers the user had trimmed into
    /// sync by ear arrive as ONE peak. Nearest-baseline assignment gave it to
    /// one of them and corrected that speaker 11.5 ms out of the sync the
    /// user had just set. A merged arrival is the sync point, not drift.
    @Test func speakersArrivingTogetherAreTakenAsTheSyncPointAndNeverCorrected() {
        var sampler = Self.sampler([Self.bluetooth("A", 60), Self.bluetooth("B", 80)])
        let outcome = Self.analyze(&sampler, delaysMs: [55])
        guard case .merged(let deviceUIDs, let delayMs) = outcome else {
            Issue.record("expected a merged arrival, got \(outcome)")
            return
        }
        #expect(deviceUIDs == ["A", "B"])
        #expect(abs(delayMs - 55) < 2)
        #expect(sampler.baselines.allSatisfy { abs($0.expectedDelayMs - 55) < 2 })
        // The next window measures against the sync point: the same arrival
        // is "aligned", and only a speaker that leaves it is an observation.
        let next = Self.analyze(&sampler, delaysMs: [55])
        #expect(next == .merged(deviceUIDs: ["A", "B"], delayMs: delayMs)
                || next == .observations([]))
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

    private struct WaitTimedOut: Error, CustomStringConvertible {
        let description: String
    }

    /// Wait for something the tracker itself reports rather than for a fixed
    /// stretch of wall clock. The ceiling is a hang-stop: a machine sharing its
    /// cores with three other test runs takes longer and still passes, and only
    /// a tracker that never gets there fails.
    private static func waitUntil(_ what: String, seconds: Double = 30,
                                  _ isDone: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !isDone() {
            guard Date() < deadline else {
                throw WaitTimedOut(
                    description: "waited \(seconds) s for \(what) and it never happened")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
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

        // .reconnect now waits 15 s inside the tracker before its window, so
        // an immediate-window test uses .verify instead.
        tracker.trigger(.verify)
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
            firstWindowSeconds: 0.1,
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
        // drive until it goes quiet rather than counting triggers. .verify
        // takes its window immediately; .reconnect now waits 15 s.
        for _ in 1...(PassiveDriftSampler.blindAfterUnusableWindows * 4)
        where !tracker.isBlind {
            tracker.trigger(.verify)
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

    /// A silent-mic program buffer shared by the cadence tests below: real
    /// program audio in the ring, a mic that never hears it, so every window
    /// comes back unusable without the tracker going blind mid-test.
    private static func silenceProgram(rate: Double) -> (ring: ReferenceAudioRing, program: Data) {
        let frames = Int(rate)
        var state: UInt64 = 99
        var pcm = Data(count: frames * 2 * MemoryLayout<Int16>.size)
        pcm.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let samples = buffer.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = Int16(truncatingIfNeeded: Int(state >> 33) % 12_000 - 6_000)
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
        }
        return (ReferenceAudioRing(), pcm)
    }

    /// THE DEFECT. The first window used to land at the periodic interval
    /// itself (decision 18 wants a window soon after start, then far apart),
    /// or the periodic timer kept firing every interval from the start
    /// instead of just once inside the test window.
    @Test func firstWindowRunsAtTheStartDelayThenNothingUntilThePeriodicInterval() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000
        let (ring, program) = Self.silenceProgram(rate: rate)
        let silence = [Float](repeating: 0, count: Int(rate))
        let windowCount = UncheckedBox<Int>(0)
        let tracker = PassiveDriftTracker(
            ring: ring,
            windowSeconds: 0.05,
            intervalSeconds: 10,
            firstWindowSeconds: 0.1,
            makeRecorder: {
                windowCount.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ring.append(program, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            onObservations: { _ in })
        tracker.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])
        tracker.start()

        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(windowCount.value == 1)
    }

    /// THE DEFECT. Every clock step used to take its own window; the rate
    /// limit caps one window per speaker per minute.
    @Test func clockStepsOnOneSpeakerTakeAtMostOneWindowPerMinute() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000
        let (ring, program) = Self.silenceProgram(rate: rate)
        let silence = [Float](repeating: 0, count: Int(rate))
        let windowCount = UncheckedBox<Int>(0)
        let now = UncheckedBox<Double>(0)
        let tracker = PassiveDriftTracker(
            ring: ring,
            windowSeconds: 0.05,
            intervalSeconds: 1000,
            firstWindowSeconds: 1000,
            makeRecorder: {
                windowCount.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ring.append(program, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            now: { now.value },
            onObservations: { _ in })
        tracker.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])

        // `trigger` hands the step to the tracker's own queue; reading a
        // queue-synchronised property waits for that queue, so every step is
        // handled — and counted — at the clock value it was sent with. Fixed
        // sleeps here instead made the whole test flake under load.
        func step(_ uid: String, at seconds: Double) {
            now.value = seconds
            tracker.trigger(.clockJump(uid: uid))
            _ = tracker.isBlind
        }
        // A window still in flight skips the next step for its own reason, so
        // each window is closed out before the step that tests the rate limit.
        // The mic hears silence, so every window ends unusable and the
        // tracker's own count says when it is done.
        func waitForWindow(_ count: Int) async throws {
            try await Self.waitUntil("window \(count) to finish") {
                tracker.consecutiveUnusableWindows >= count
            }
        }

        step("A", at: 0)
        #expect(windowCount.value == 1, "the first step takes a window")
        try await waitForWindow(1)

        step("A", at: 30)
        #expect(windowCount.value == 1, "the t=30 step should have been rate-limited")

        step("A", at: 61)
        #expect(windowCount.value == 2, "60 s after its last window the speaker may take another")
        try await waitForWindow(2)

        step("B", at: 61)
        #expect(windowCount.value == 3, "a different speaker has its own limit")
    }

    /// THE DEFECT. A reconnecting speaker's pacing clock keeps stepping while
    /// the sink re-buffers — up to 42 s on a Sonos Move — and the first of
    /// those steps passed the rate limit, because nothing had used that
    /// speaker's allowance in a minute. That window measured a sink that was
    /// not rendering yet, spent one of the five that blind the mic, and on a
    /// Move the burst marked the link bad as well, so the deliberate reconnect
    /// window landed inside the same burst and was wasted too. Delete the
    /// settling suppression and the first two counts below go to 1 and 2.
    @Test func aReconnectingSpeakersClockStepsWaitForItsSettledWindow() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000
        let (ring, program) = Self.silenceProgram(rate: rate)
        let silence = [Float](repeating: 0, count: Int(rate))
        let windowCount = UncheckedBox<Int>(0)
        let now = UncheckedBox<Double>(0)
        let tracker = PassiveDriftTracker(
            ring: ring,
            windowSeconds: 0.05,
            intervalSeconds: 1000,
            firstWindowSeconds: 1000,
            reconnectDelaySeconds: 1,
            makeRecorder: {
                windowCount.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ring.append(program, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            now: { now.value },
            isNearMiss: { _, _ in false },
            onObservations: { _ in })
        tracker.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])

        // Reading a queue-synchronised property waits for the trigger already
        // handed to the tracker's queue.
        func send(_ reason: PassiveDriftTracker.Trigger, at seconds: Double) {
            now.value = seconds
            tracker.trigger(reason)
            _ = tracker.isBlind
        }

        send(.reconnect(uid: "A"), at: 0)
        #expect(windowCount.value == 0, "the reconnect window is deliberately delayed")

        send(.clockJump(uid: "A"), at: 1)
        #expect(windowCount.value == 0, "a step from a sink still re-buffering takes no window")

        send(.clockJump(uid: "B"), at: 1)
        #expect(windowCount.value == 1, "another speaker's steps are untouched by A's reconnect")
        try await Self.waitUntil("B's window to finish") {
            tracker.consecutiveUnusableWindows >= 1
        }

        try await Self.waitUntil("A's delayed reconnect window") { windowCount.value == 2 }
        try await Self.waitUntil("the reconnect window to finish") {
            tracker.consecutiveUnusableWindows >= 2
        }

        send(.clockJump(uid: "A"), at: 2)
        #expect(windowCount.value == 3, "a step after the settled window is served normally")
    }

    /// THE DEFECT. The clear used to be measured from the step that declared
    /// the storm rather than from the last step of any kind, so a link stepping
    /// every few seconds — the real bad-link case — cleared on schedule, took an
    /// unusable window, re-stormed, and repeated until the mic went blind. Only
    /// a stretch with no step at all may release the speaker.
    @Test func aBadLinkClearsOnlyAfterTheSpacingWindowWithNoStepAtAll() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000
        let (ring, program) = Self.silenceProgram(rate: rate)
        let silence = [Float](repeating: 0, count: Int(rate))
        let windowCount = UncheckedBox<Int>(0)
        let now = UncheckedBox<Double>(0)
        let tracker = PassiveDriftTracker(
            ring: ring,
            windowSeconds: 0.02,
            intervalSeconds: 1000,
            firstWindowSeconds: 1000,
            clockStepWindowSpacingSeconds: 60,
            clockStepStormCount: 3,
            makeRecorder: {
                windowCount.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ring.append(program, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            now: { now.value },
            isNearMiss: { _, _ in false },
            onObservations: { _ in })
        tracker.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])

        // `trigger` hands the step to the tracker's own queue; reading a
        // queue-synchronised property waits for that queue, so every step is
        // handled at the clock value it was sent with.
        func step(at seconds: Double) {
            now.value = seconds
            tracker.trigger(.clockJump(uid: "A"))
            _ = tracker.isBlind
        }

        step(at: 0)
        step(at: 1)
        step(at: 2)
        #expect(windowCount.value == 1, "only the first step of the storm takes a window")

        // The first window has to close before the stepping below, or a wrongly
        // cleared link is skipped for a window in flight and reads as suppressed.
        // The mic hears silence, so that window ends unusable and the tracker's
        // own count says when it is done.
        try await Self.waitUntil("the storm's first window to finish") {
            tracker.consecutiveUnusableWindows >= 1
        }

        // A link stepping every 5 s for five minutes is never quiet, so it is
        // never released — not even 60 s after the step that declared the storm.
        for seconds in stride(from: 7.0, through: 300.0, by: 5) { step(at: seconds) }
        #expect(windowCount.value == 1, "continuous stepping must never clear the bad link")

        step(at: 365)
        #expect(windowCount.value == 2,
                "60 s with no step at all should have cleared the bad-link classification")
    }

    /// THE DEFECT. The once-a-minute slot was spent before the window ran, so a
    /// step arriving while another window was in flight was logged as skipped
    /// and still silenced that speaker for a minute — the jump it named got no
    /// window at all.
    @Test func aStepSkippedForAWindowInFlightDoesNotSpendTheRateLimitSlot() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000
        let (ring, program) = Self.silenceProgram(rate: rate)
        let silence = [Float](repeating: 0, count: Int(rate))
        let windowCount = UncheckedBox<Int>(0)
        let now = UncheckedBox<Double>(0)
        let tracker = PassiveDriftTracker(
            ring: ring,
            windowSeconds: 0.3,
            intervalSeconds: 1000,
            firstWindowSeconds: 1000,
            makeRecorder: {
                windowCount.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ring.append(program, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            now: { now.value },
            isNearMiss: { _, _ in false },
            onObservations: { _ in })
        tracker.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])

        // Reading a queue-synchronised property waits for the trigger already
        // handed to the tracker's queue.
        tracker.trigger(.verify)
        _ = tracker.isBlind
        #expect(windowCount.value == 1, "the verify window is in flight")

        tracker.trigger(.clockJump(uid: "A"))
        _ = tracker.isBlind
        #expect(windowCount.value == 1, "a step landing on a window in flight takes none of its own")

        // That window closes when the tracker has recorded its result, and the
        // silent mic guarantees that result is an unusable one.
        try await Self.waitUntil("the verify window to finish") {
            tracker.consecutiveUnusableWindows >= 1
        }
        now.value = 10
        tracker.trigger(.clockJump(uid: "A"))
        _ = tracker.isBlind
        #expect(windowCount.value == 2,
                "a window that never ran must not consume the once-a-minute slot")
    }

    /// THE DEFECT. `stop()` cancelled the silence poll but kept the silent
    /// spell, and the backend stops and restarts the tracker on every selection
    /// change: music paused for a minute, a speaker deselected and reselected,
    /// and the first poll after the restart read that stale silence as an edge —
    /// a window on a sink rebuilt one second earlier.
    @Test func silenceFromBeforeAStopTakesNoWindowAfterTheNextStart() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000
        let (ring, program) = Self.silenceProgram(rate: rate)
        let silence = [Float](repeating: 0, count: Int(rate))
        let windowCount = UncheckedBox<Int>(0)
        let isSilent = UncheckedBox<Bool>(true)
        // Every poll is counted, because the conclusion here is a zero: without
        // proof that a poll ran while the program was silent — and that another
        // ran after the restart — the zero holds for a tracker that never
        // cleared the spell at all.
        let polls = UncheckedBox<Int>(0)
        let now = UncheckedBox<Double>(0)
        let tracker = PassiveDriftTracker(
            ring: ring,
            windowSeconds: 0.02,
            intervalSeconds: 1000,
            firstWindowSeconds: 1000,
            silenceEdgeSeconds: 0.2,
            pollIntervalSeconds: 0.02,
            makeRecorder: {
                windowCount.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ring.append(program, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            programIsSilent: { polls.value += 1; return isSilent.value },
            now: { now.value },
            onObservations: { _ in })
        tracker.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])

        tracker.start()
        // A poll taken while the program is silent always leaves the spell's
        // start set, so one such poll IS the precondition. Reading a
        // queue-synchronised property afterwards waits for that poll to finish,
        // so the spell is stamped with the clock it was taken at rather than
        // with the 90 below.
        try await Self.waitUntil("a poll to record the silent spell") { polls.value >= 1 }
        _ = tracker.isBlind
        now.value = 90                                   // a minute and a half of it
        tracker.stop()

        // The stop has to be through the queue before the program turns
        // audible, or a poll still queued behind it reads the stale spell and
        // takes the window whether or not the stop clears it.
        _ = tracker.isBlind
        isSilent.value = false
        tracker.start()
        let pollsBeforeRestart = polls.value
        // At most one poll of the cancelled timer can still be pending here, so
        // three more means the restarted poll has run — and a tracker that kept
        // the pre-stop spell takes its window on the first of them.
        try await Self.waitUntil("the restarted silence poll to run") {
            polls.value >= pollsBeforeRestart + 3
        }
        #expect(windowCount.value == 0,
                "silence measured before the stop is not an edge after the restart")
    }

    /// THE DEFECT. A refused near-miss window used to wait the full periodic
    /// interval before trying again, or a retry counted toward the blind
    /// budget, or a retry itself retried.
    @Test func aNearMissRetriesOnceAfterTheRetryDelayWithoutCountingTowardBlind() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000

        let (ringA, programA) = Self.silenceProgram(rate: rate)
        let silence = [Float](repeating: 0, count: Int(rate))
        let windowCountA = UncheckedBox<Int>(0)
        let trackerA = PassiveDriftTracker(
            ring: ringA,
            windowSeconds: 0.05,
            intervalSeconds: 1000,
            firstWindowSeconds: 1000,
            retryDelaySeconds: 0.1,
            makeRecorder: {
                windowCountA.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ringA.append(programA, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            isNearMiss: { _, _ in true },
            onObservations: { _ in })
        trackerA.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])

        trackerA.trigger(.verify)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(windowCountA.value == 2, "a near miss should retry once")
        #expect(trackerA.consecutiveUnusableWindows == 1, "the retry must not count toward blind")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(windowCountA.value == 2, "a retry must never itself retry")

        let (ringB, programB) = Self.silenceProgram(rate: rate)
        let windowCountB = UncheckedBox<Int>(0)
        let trackerB = PassiveDriftTracker(
            ring: ringB,
            windowSeconds: 0.05,
            intervalSeconds: 1000,
            firstWindowSeconds: 1000,
            retryDelaySeconds: 0.1,
            makeRecorder: {
                windowCountB.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ringB.append(programB, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            isNearMiss: { _, _ in false },
            onObservations: { _ in })
        trackerB.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])

        trackerB.trigger(.verify)
        try await Self.waitUntil("the refused window to finish") {
            trackerB.consecutiveUnusableWindows >= 1
        }
        // A retry would land `retryDelaySeconds` after that refusal: wait
        // several times as long, so a tracker that wrongly retries has taken
        // its second window by the time the count is read.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(windowCountB.value == 1, "a plain refusal never retries")
        #expect(trackerB.consecutiveUnusableWindows == 1)
    }

    /// THE DEFECT. ``PassiveDriftSampler/isNearMiss`` names the wrong gates,
    /// or counts whole-tape confidence instead of the three the ticket says
    /// (margin, local score, agreeing bands).
    @Test func aNearMissClearsTwoOfTheThreeGates() {
        let correlator = PassiveDriftCorrelator()
        let clearsMarginAndLocal = DriftPeak(
            delayMs: 0, confidence: 1, localConfidence: 2.4, margin: 1.2, agreeingBands: 1)
        #expect(PassiveDriftSampler.isNearMiss(candidates: [clearsMarginAndLocal], correlator: correlator))

        let clearsOnlyLocal = DriftPeak(
            delayMs: 0, confidence: 1, localConfidence: 2.4, margin: 1.0, agreeingBands: 1)
        #expect(!PassiveDriftSampler.isNearMiss(candidates: [clearsOnlyLocal], correlator: correlator))

        // Whole-tape confidence is excluded on purpose (decision 15): a peak
        // that scores high against the whole tape and clears only one of the
        // three real gates is a plain refusal, not a near miss. With every
        // candidate above scoring 1, an implementation counting confidence as a
        // gate passes them all.
        let loudButOnlyLocal = DriftPeak(
            delayMs: 0, confidence: 10, localConfidence: 2.4, margin: 1.0, agreeingBands: 1)
        #expect(!PassiveDriftSampler.isNearMiss(candidates: [loudButOnlyLocal], correlator: correlator))

        #expect(!PassiveDriftSampler.isNearMiss(candidates: [], correlator: correlator))
    }

    /// THE DEFECT. A short gap between tracks (silence under the 60 s edge)
    /// used to take a window, or a real minute-plus silence ending on audio
    /// never did.
    @Test func silenceOfAMinuteFollowedByAudioTakesAWindow() async throws {
        let rate = Double(PCMFormat.airplay.sampleRate)
        let startNanos: Int64 = 500 * 1_000_000_000
        let (ring, program) = Self.silenceProgram(rate: rate)
        let silence = [Float](repeating: 0, count: Int(rate))
        let windowCount = UncheckedBox<Int>(0)
        let isSilent = UncheckedBox<Bool>(true)
        let polls = UncheckedBox<Int>(0)
        // Both spells here are measured on an injected clock: read from
        // `systemUptime`, the spell starts at the first poll after `start()` and
        // a stall before that poll makes it shorter than the 0.2 s edge, failing
        // a correct implementation.
        let now = UncheckedBox<Double>(0)
        let tracker = PassiveDriftTracker(
            ring: ring,
            windowSeconds: 0.02,
            intervalSeconds: 1000,
            firstWindowSeconds: 100,
            silenceEdgeSeconds: 0.2,
            pollIntervalSeconds: 0.02,
            makeRecorder: {
                windowCount.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ring.append(program, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            programIsSilent: { polls.value += 1; return isSilent.value },
            now: { now.value },
            onObservations: { _ in })
        tracker.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])
        tracker.start()

        // Reading a queue-synchronised property waits for that poll to finish,
        // so the spell is stamped with the clock it was taken at rather than
        // with the 90 below.
        try await Self.waitUntil("a poll to record the silent spell") { polls.value >= 1 }
        _ = tracker.isBlind
        now.value = 90                                   // a minute and a half of it
        isSilent.value = false
        try await Self.waitUntil("the silence-to-audio window") { windowCount.value >= 1 }
        #expect(windowCount.value == 1, "silence past the edge followed by audio should take a window")

        tracker.stop()

        let (ring2, program2) = Self.silenceProgram(rate: rate)
        let windowCount2 = UncheckedBox<Int>(0)
        let isSilent2 = UncheckedBox<Bool>(true)
        let polls2 = UncheckedBox<Int>(0)
        let now2 = UncheckedBox<Double>(0)
        let tracker2 = PassiveDriftTracker(
            ring: ring2,
            windowSeconds: 0.02,
            intervalSeconds: 1000,
            firstWindowSeconds: 100,
            silenceEdgeSeconds: 0.2,
            pollIntervalSeconds: 0.02,
            makeRecorder: {
                windowCount2.value += 1
                return FeedingRecorder(rate: rate, startNanos: startNanos,
                                scene: { silence },
                                feed: { ring2.append(program2, pts: timespec(tv_sec: 500, tv_nsec: 0)) })
            },
            permissionIsGranted: { true },
            programIsSilent: { polls2.value += 1; return isSilent2.value },
            now: { now2.value },
            onObservations: { _ in })
        tracker2.setBaselines([PassiveDriftSampler.Baseline(
            deviceUID: "bt", kind: .bluetooth, expectedDelayMs: 100)])
        tracker2.start()

        try await Self.waitUntil("a poll to record the short gap") { polls2.value >= 1 }
        _ = tracker2.isBlind
        now2.value = 0.05          // 50 ms of silence, well short of the edge
        isSilent2.value = false
        let pollsBeforeAudio = polls2.value
        // Three polls on the audible program, so the edge this gap is too short
        // for has been offered to the tracker and declined.
        try await Self.waitUntil("the polls that follow the short gap") {
            polls2.value >= pollsBeforeAudio + 3
        }
        #expect(windowCount2.value == 0, "a gap short of the edge is not a silence-to-audio event")
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
