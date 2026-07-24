import XCTest
@testable import AudiouterCore
import AirPlayEngine

#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// T-FANOUT: prove that fanning the captured whole-system audio to the delayed
/// local sink (``SyncedLocalSink``) does NOT create a feedback loop — the tap
/// must exclude the sink's own render process so the delayed output is never
/// re-captured as an echo (plan risk R2 / brief §8).
///
/// The established codebase pattern for proving a tap does/does-not carry a
/// specific signal is a Goertzel single-bin tone test (see
/// `AirPlayEngineTests.ShimUnitTests` — "Goertzel spike ~400x over neighbouring
/// bins"). We reuse it here, fully synthetic: a fake ``SystemAudioTap`` models
/// Core Audio's per-process capture-with-exclusion by summing only the tones of
/// processes NOT in the tap's excluded process-object set. No real audio, no
/// `AVAudioEngine` start, no hardware — exactly the offline harness the plan's
/// verify step calls for.
///
/// Post-Firefox-routing-leak-fix, the real coordinator excludes by
/// ``AudioObjectID`` (resolved from a pid via ``AudioProcessResolver``), not raw
/// pid directly — this fake models that one level too, via a scripted
/// pid → `AudioObjectID` resolver, so the self-exclude assertions exercise the
/// SAME resolution path production code does.
final class SyncedLocalFanoutTests: IsolatedTestCase {

    // MARK: Doubles

    /// A fake whole-system tap that models the ONE property under test: it captures
    /// the mix of every process EXCEPT those whose object id is in
    /// `excludedProcessObjectIDs`. Each "process" is a pid (mapped to an
    /// `AudioObjectID` one-for-one via `objectID(for:)`) emitting a pure tone;
    /// `deliverMix` sums the non-excluded tones into an interleaved-Float32
    /// 44100/2ch buffer and fires `onBuffer`, exactly as a real process tap would
    /// deliver the system mix minus the excluded processes.
    private final class FeedbackFakeTap: SystemAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?

        static let sampleRate = 44_100.0
        static let channels = 2
        let format = TapFormat(sampleRate: 44_100, channels: 2, bitsPerSample: 32,
                               isFloat: true, isInterleaved: true)

        private let lock = NSLock()
        /// pid → tone frequency present in that process's output.
        private var _processes: [pid_t: Double] = [:]
        private var _excluded: Set<AudioObjectID> = []
        private var _createCount = 0

        /// One-for-one, deterministic pid → object-id mapping for this fake:
        /// `AudioObjectID(pid)`, so tests can assert exclusion either way.
        static func objectID(for pid: pid_t) -> AudioObjectID { AudioObjectID(pid) }

        func setProcesses(_ p: [pid_t: Double]) { lock.withLock { _processes = p } }
        var excludedObjectIDs: Set<AudioObjectID> { lock.withLock { _excluded } }
        func excludes(pid: pid_t) -> Bool { excludedObjectIDs.contains(Self.objectID(for: pid)) }
        var creates: Int { lock.withLock { _createCount } }

        func createAndStart(muteBehavior: TapMuteBehavior, excludedProcessObjectIDs: Set<AudioObjectID>) throws -> TapFormat {
            lock.withLock { _createCount += 1; _excluded = excludedProcessObjectIDs }
            return format
        }
        func teardown() {}

        /// Deliver one capture buffer = the SUM of every non-excluded process's
        /// tone, over `frames` frames starting at sample index `phaseStart` (so a
        /// sequence of buffers is phase-continuous).
        func deliverMix(frames: Int, phaseStart: Int, pts: timespec) {
            let (procs, exc) = lock.withLock { (_processes, _excluded) }
            var interleaved = [Float](repeating: 0, count: frames * Self.channels)
            for (pid, freq) in procs where !exc.contains(Self.objectID(for: pid)) {
                for f in 0..<frames {
                    let t = Double(phaseStart + f) / Self.sampleRate
                    let v = Float(0.5 * sin(2.0 * Double.pi * freq * t))
                    interleaved[f * Self.channels + 0] += v
                    interleaved[f * Self.channels + 1] += v
                }
            }
            let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
            onBuffer?(CapturedBuffer(channelData: [data], frameCount: frames, pts: pts))
        }
    }

    /// A scripted ``AudioProcessEnumerating`` reporting exactly one process object
    /// per pid this test cares about, via the same deterministic mapping the fake
    /// tap uses (`FeedbackFakeTap.objectID(for:)`) — so
    /// `processResolver.resolve(pid:)` inside the real coordinator resolves the
    /// sink's render pid to the SAME object id the fake tap checks for exclusion.
    private final class ScriptedEnumerator: AudioProcessEnumerating {
        let pids: [pid_t]
        init(pids: [pid_t]) { self.pids = pids }
        func enumerateProcesses() -> [RawAudioProcess] {
            pids.map { RawAudioProcess(objectID: FeedbackFakeTap.objectID(for: $0), pid: $0, bundleID: nil) }
        }
        func parentPID(of pid: pid_t) -> pid_t? { nil }
    }

    /// Records every forwarded (pcm, pts) pair — what actually reached the engine.
    private final class SpyPCMSink: PCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [(pcm: Data, pts: timespec)] = []
        func write(pcm: Data, pts: timespec) { lock.withLock { writes.append((pcm, pts)) } }
        var forwarded: [(pcm: Data, pts: timespec)] { lock.withLock { writes } }
    }

    /// Records every fan-out `enqueue` (the second consumer).
    private final class SpySyncedSink: SyncedLocalPCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(frames: [Float], frameCount: Int, pts: timespec)] = []
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
            let channels = PCMFormat.airplay.channels
            let buf = UnsafeBufferPointer(start: interleavedFrames, count: frameCount * channels)
            lock.withLock { calls.append((Array(buf), frameCount, pts)) }
        }
        var enqueued: [(frames: [Float], frameCount: Int, pts: timespec)] { lock.withLock { calls } }
    }

    /// Deterministic converter emitting a fixed non-empty S16LE payload, so the
    /// fan-out delivery tests don't need AVFoundation.
    private final class FixedConverter: PCMConverting, @unchecked Sendable {
        // 4 interleaved S16LE stereo frames = 16 bytes; values 1…8.
        static let payload = Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00,
                                   0x05, 0x00, 0x06, 0x00, 0x07, 0x00, 0x08, 0x00])
        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? { Self.payload }
    }

    // MARK: Helpers

    private func waitFor(timeout: TimeInterval = 8, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func waitForCapturing(_ c: NativeCaptureCoordinator) {
        waitFor {
            if case .capturing = c.state { return true }
            return false
        }
    }

    /// Goertzel single-bin power at `freq` of an interleaved S16LE buffer, read off
    /// channel 0 (both channels carry the same mono-summed tone here). Normalized
    /// by frame count so buffers of different length compare directly.
    private func goertzelPowerS16LE(_ data: Data, freq: Double,
                                    sampleRate: Double = FeedbackFakeTap.sampleRate,
                                    channels: Int = PCMFormat.airplay.channels) -> Double {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard channels > 0, sampleCount >= channels else { return 0 }
        let frames = sampleCount / channels
        let k = 2.0 * Double.pi * freq / sampleRate
        let coeff = 2.0 * cos(k)
        var s1 = 0.0, s2 = 0.0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for f in 0..<frames {
                let x = Double(Int16(littleEndian: p[f * channels])) / 32768.0
                let s0 = x + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return power / Double(max(1, frames))
    }

    private func concat(_ chunks: [Data]) -> Data {
        var out = Data()
        for c in chunks { out.append(c) }
        return out
    }

    // Stand-in for the sink's render process (would be `getpid()` in production).
    private let sinkRenderPID: pid_t = 424_242
    // An ordinary app whose audio the tap SHOULD keep capturing.
    private let otherAppPID: pid_t = 100
    private let sinkFreq = 440.0     // the delayed sink's output tone (the hazard)
    private let otherFreq = 3_000.0  // an unrelated app's tone (positive control)

    // MARK: - Goertzel: no feedback loop when the sink's process is self-excluded.

    #if canImport(AVFoundation)
    func test_selfExclude_tapDoesNotRecaptureSinkTone_goertzel() throws {
        let tap = FeedbackFakeTap()
        tap.setProcesses([sinkRenderPID: sinkFreq, otherAppPID: otherFreq])
        let engineSink = SpyPCMSink()
        let localSink = SpySyncedSink()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { AVFormatConverter(from: $0) },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [sinkRenderPID, otherAppPID])),
            muteBehavior: .mutedWhenTapped)

        // Attach the delayed local sink, declaring its render process pid. Done
        // BEFORE start() so the very first tap is created with the self-exclude.
        coordinator.setSyncedLocalSink(localSink, renderProcessPID: sinkRenderPID)
        coordinator.start()
        waitForCapturing(coordinator)

        // The whole-system tap was created excluding the sink's render process (R2).
        XCTAssertTrue(tap.excludes(pid: sinkRenderPID),
                      "the sink's render process must be excluded from the whole-system tap")

        // Deliver the mix the tap would actually capture (non-excluded processes
        // only → the sink's own tone is absent, the ordinary app's tone present).
        let frames = 4_096
        let buffers = 8
        for i in 0..<buffers {
            tap.deliverMix(frames: frames, phaseStart: i * frames,
                           pts: timespec(tv_sec: i, tv_nsec: 0))
        }
        waitFor { engineSink.forwarded.count == buffers }
        XCTAssertEqual(engineSink.forwarded.count, buffers)

        let captured = concat(engineSink.forwarded.map { $0.pcm })
        let feedbackPower = goertzelPowerS16LE(captured, freq: sinkFreq)
        let controlPower = goertzelPowerS16LE(captured, freq: otherFreq)

        // The ordinary app's tone DID reach the engine — the pipeline is alive and
        // the detector works (this is what makes the near-zero below meaningful).
        XCTAssertGreaterThan(controlPower, 1e-3,
                             "the tap must still capture ordinary (non-excluded) app audio")
        // The sink's OWN output did NOT — no feedback loop. Orders of magnitude
        // below the captured control tone.
        XCTAssertLessThan(feedbackPower, controlPower / 1_000.0,
                          "the sink's delayed output must not be re-captured as an echo")
    }

    /// Negative control proving the Goertzel detector (and the fake tap) really do
    /// surface the sink's tone when it is NOT excluded — so the test above's
    /// near-zero is the self-exclude working, not a dead pipeline.
    func test_withoutSelfExclude_sinkToneFeedsBack_provingDetector() throws {
        let tap = FeedbackFakeTap()
        tap.setProcesses([sinkRenderPID: sinkFreq, otherAppPID: otherFreq])
        let engineSink = SpyPCMSink()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { AVFormatConverter(from: $0) },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [sinkRenderPID, otherAppPID])),
            muteBehavior: .mutedWhenTapped)

        // No sink attached → no self-exclude → the sink's process stays in the mix.
        coordinator.start()
        waitForCapturing(coordinator)
        XCTAssertFalse(tap.excludes(pid: sinkRenderPID))

        let frames = 4_096
        let buffers = 8
        for i in 0..<buffers {
            tap.deliverMix(frames: frames, phaseStart: i * frames,
                           pts: timespec(tv_sec: i, tv_nsec: 0))
        }
        waitFor { engineSink.forwarded.count == buffers }

        let captured = concat(engineSink.forwarded.map { $0.pcm })
        let feedbackPower = goertzelPowerS16LE(captured, freq: sinkFreq)
        // WITHOUT the exclude, the 440 Hz tone is plainly present — the loop the
        // self-exclude prevents.
        XCTAssertGreaterThan(feedbackPower, 1e-3,
                             "without the self-exclude the sink's tone re-enters capture (the loop)")
    }
    #endif

    // MARK: - Fan-out wiring (gated like metering).

    func test_fanOut_deliversToSink_onlyWhenAttached() {
        let tap = FeedbackFakeTap()
        let engineSink = SpyPCMSink()
        let localSink = SpySyncedSink()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in FixedConverter() },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [sinkRenderPID])),
            muteBehavior: .mutedWhenTapped)
        coordinator.start()
        waitForCapturing(coordinator)

        // No sink attached: the second consumer is NOT fed (gated off), the engine
        // still is.
        tap.deliverMix(frames: 4, phaseStart: 0, pts: timespec(tv_sec: 1, tv_nsec: 0))
        waitFor { engineSink.forwarded.count == 1 }
        XCTAssertEqual(localSink.enqueued.count, 0, "no fan-out while the sink is detached")

        // Attach → subsequent buffers fan out to the sink with the same pts.
        coordinator.setSyncedLocalSink(localSink, renderProcessPID: sinkRenderPID)
        tap.deliverMix(frames: 4, phaseStart: 4, pts: timespec(tv_sec: 2, tv_nsec: 0))
        waitFor { localSink.enqueued.count == 1 }

        let call = localSink.enqueued[0]
        XCTAssertEqual(call.frameCount, 4, "16-byte S16LE stereo payload = 4 frames")
        XCTAssertEqual(call.pts.tv_sec, 2, "fan-out carries the capture pts unchanged")
        // The fixed payload widens 1…8 (Int16) → Float32 / 32768.
        let expected = (1...8).map { Float($0) / 32768.0 }
        XCTAssertEqual(call.frames.count, expected.count)
        for (got, want) in zip(call.frames, expected) {
            XCTAssertEqual(got, want, accuracy: 1e-6)
        }

        // Detach → fan-out stops again.
        coordinator.setSyncedLocalSink(nil, renderProcessPID: nil)
        tap.deliverMix(frames: 4, phaseStart: 8, pts: timespec(tv_sec: 3, tv_nsec: 0))
        waitFor { engineSink.forwarded.count == 3 }
        XCTAssertEqual(localSink.enqueued.count, 1, "no fan-out after detach")
    }

    /// Attaching while already capturing recreates the tap so the new self-exclude
    /// takes effect immediately (mirrors the routing-exclusion recreate).
    func test_attachWhileCapturing_recreatesTapWithSelfExclude() {
        let tap = FeedbackFakeTap()
        let engineSink = SpyPCMSink()
        let localSink = SpySyncedSink()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in FixedConverter() },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [sinkRenderPID])),
            muteBehavior: .mutedWhenTapped)
        coordinator.start()
        waitForCapturing(coordinator)
        XCTAssertEqual(tap.creates, 1)
        XCTAssertFalse(tap.excludes(pid: sinkRenderPID))

        coordinator.setSyncedLocalSink(localSink, renderProcessPID: sinkRenderPID)
        waitFor { tap.excludes(pid: self.sinkRenderPID) }
        XCTAssertEqual(tap.creates, 2, "attaching a sink while capturing recreates the tap")
        XCTAssertTrue(tap.excludes(pid: sinkRenderPID))
    }

    // MARK: - T3 Part B: base-rate resample (44.1 kHz airplay feed → device-native rate)

    /// Goertzel single-bin power on raw Float samples (no Int16 decode) — same
    /// math as `goertzelPowerS16LE` above, for asserting directly on
    /// ``SyncedLocalBaseResampler``'s Float output.
    private func goertzelPowerFloat(_ samples: [Float], freq: Double, sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let k = 2.0 * Double.pi * freq / sampleRate
        let coeff = 2.0 * cos(k)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s0 = Double(x) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return power / Double(samples.count)
    }

    /// Identity ratio (input rate == output rate, e.g. a 44.1 kHz output device):
    /// the base resampler must pass every sample through bit-for-bit — no
    /// interpolation, no priming lag — mirroring the engine converter's own
    /// "resample only when the rate differs from 44100" discipline (T3 Part B).
    func test_baseResampler_identityRatio_isBitExactPassthrough() {
        let resampler = SyncedLocalBaseResampler(inputRate: 44_100, outputRate: 44_100, channelCount: 2)
        XCTAssertTrue(resampler.isIdentity)
        XCTAssertEqual(resampler.ratio, 1.0, accuracy: 1e-12)

        let input: [Float] = (0..<40).map { Float($0) * 0.01 - 0.2 }
        let out = input.withUnsafeBufferPointer { buf in
            resampler.resample(input: buf.baseAddress!, frameCount: 20)
        }
        XCTAssertEqual(out, input, "identity ratio must be a bit-exact passthrough")
    }

    /// Upsampling 44.1 kHz → 48 kHz must produce a frame count matching the rate
    /// ratio (never a hardcoded assumption) — the frame-count half of T5's
    /// "correct frame counts, no pitch shift" check.
    func test_baseResampler_upsample44_1to48_producesRateScaledFrameCount() {
        let inputRate = 44_100.0, outputRate = 48_000.0
        let resampler = SyncedLocalBaseResampler(inputRate: inputRate, outputRate: outputRate, channelCount: 1)
        XCTAssertFalse(resampler.isIdentity)
        XCTAssertEqual(resampler.ratio, inputRate / outputRate, accuracy: 1e-12)

        let durationSeconds = 1.0
        let frameCount = Int(inputRate * durationSeconds)
        var input = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            input[i] = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / inputRate))
        }
        let out = input.withUnsafeBufferPointer { buf in
            resampler.resample(input: buf.baseAddress!, frameCount: frameCount)
        }
        // One second of audio in ⇒ ~one second out at the OUTPUT rate — 48,000
        // frames, not 44,100 — proving the frame math is keyed off the real
        // rates, never a hardcoded 44100 (plan T3 verify step).
        XCTAssertEqual(Double(out.count), outputRate, accuracy: 8,
                       "1 s of 44.1 kHz input must resample to ~1 s of 48 kHz output frames")
    }

    /// The pitch half: resampling 44.1 kHz → 48 kHz must NOT shift the tone's
    /// frequency. A naive "play the 44.1 kHz samples out at 48 kHz with no rate
    /// conversion" bug (the diagnosed dropout symptom: "AirPlay plays pitched up
    /// ~+8.8%" = 48000/44100) would leave a 440 Hz input sounding like ~479 Hz once
    /// played back at 48 kHz. Goertzel at both frequencies over the ACTUAL
    /// resampled output proves the tone landed at 440 Hz, not the pitched one.
    func test_baseResampler_upsample_doesNotPitchShift_goertzel() {
        let inputRate = 44_100.0, outputRate = 48_000.0, freq = 440.0
        let resampler = SyncedLocalBaseResampler(inputRate: inputRate, outputRate: outputRate, channelCount: 1)

        let frameCount = Int(inputRate * 0.5) // 0.5 s
        var input = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            input[i] = Float(sin(2.0 * Double.pi * freq * Double(i) / inputRate))
        }
        let out = input.withUnsafeBufferPointer { buf in
            resampler.resample(input: buf.baseAddress!, frameCount: frameCount)
        }
        XCTAssertFalse(out.isEmpty)

        let correctPower = goertzelPowerFloat(out, freq: freq, sampleRate: outputRate)
        let pitchedFreq = freq * outputRate / inputRate // ~479 Hz — the un-resampled bug's symptom
        let pitchedPower = goertzelPowerFloat(out, freq: pitchedFreq, sampleRate: outputRate)

        XCTAssertGreaterThan(correctPower, 0.05,
                             "the resampled output must retain the original 440 Hz tone")
        XCTAssertLessThan(pitchedPower, correctPower / 50.0,
                          "the output must not show the ~+8.8% pitched-up frequency a missing base resample would produce")
    }

    /// Downsampling direction too (a device running SLOWER than 44.1 kHz is rare
    /// but not impossible): ratio > 1, still no pitch shift, frame count still
    /// rate-scaled — proves the resampler isn't secretly only correct in the
    /// up-sample direction the dropout bug exercises.
    func test_baseResampler_downsample48to44_1_producesRateScaledFrameCount_noPitchShift() {
        let inputRate = 48_000.0, outputRate = 44_100.0, freq = 440.0
        let resampler = SyncedLocalBaseResampler(inputRate: inputRate, outputRate: outputRate, channelCount: 1)
        XCTAssertFalse(resampler.isIdentity)
        XCTAssertEqual(resampler.ratio, inputRate / outputRate, accuracy: 1e-12)

        let frameCount = Int(inputRate * 0.5)
        var input = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            input[i] = Float(sin(2.0 * Double.pi * freq * Double(i) / inputRate))
        }
        let out = input.withUnsafeBufferPointer { buf in
            resampler.resample(input: buf.baseAddress!, frameCount: frameCount)
        }
        XCTAssertEqual(Double(out.count), outputRate * 0.5, accuracy: 8)

        let correctPower = goertzelPowerFloat(out, freq: freq, sampleRate: outputRate)
        let pitchedFreq = freq * outputRate / inputRate
        let pitchedPower = goertzelPowerFloat(out, freq: pitchedFreq, sampleRate: outputRate)
        XCTAssertGreaterThan(correctPower, 0.05)
        XCTAssertLessThan(pitchedPower, correctPower / 50.0)
    }

    /// Full pipeline (fan-out resample → `SyncedLocalSink`) at a NON-identity
    /// device rate (48 kHz, resampled up from the 44.1 kHz airplay feed): the
    /// base resample's Catmull-Rom interpolation has NO whole-sample group delay
    /// (`output[0] == input[0]` exactly — the class doc's anchor property), so
    /// `SyncTiming`'s `totalDelayNanos` needs no extra term to compensate for it.
    /// The release must still land within about a frame of the SAME computed
    /// target as the identity-rate case (`SyncedLocalSinkTests`'s
    /// `test_rampReleasesAtComputedHostTime_withinOneFrame`) — the "latency folds
    /// into the sync budget" half of T5, not just the pitch check above.
    #if canImport(AVFoundation)
    func test_fanOutThroughResample_thenSink_releasesAtComputedTarget_noExtraDelay() throws {
        let inputRate = 44_100.0
        let outputRate = 48_000.0
        let baseResampler = SyncedLocalBaseResampler(
            inputRate: inputRate, outputRate: outputRate, channelCount: 1)

        // A real S16LE ramp (mono) — every real sample strictly increasing and
        // non-zero, so "first non-silence" is unambiguous, same discipline as
        // the identity-rate ramp test.
        let rampCount = 20_000
        var s16 = [Int16](repeating: 0, count: rampCount)
        for i in 0..<rampCount { s16[i] = Int16(clamping: i + 1) }
        let s16le = s16.withUnsafeBufferPointer { Data(buffer: $0) }

        // Widen S16LE → Float and base-resample 44.1 → 48 kHz — the same two
        // steps `NativeCaptureCoordinator.fanOutToSyncedLocal` performs (mono here
        // to keep the ramp math simple; the coordinator's own stereo path is
        // covered by the Goertzel self-exclude tests above).
        var floats = [Float](repeating: 0, count: rampCount)
        let scale: Float = 1.0 / 32768.0
        s16le.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<rampCount { floats[i] = Float(Int16(littleEndian: p[i])) * scale }
        }
        let resampled = floats.withUnsafeBufferPointer { buf in
            baseResampler.resample(input: buf.baseAddress!, frameCount: rampCount)
        }
        XCTAssertFalse(resampled.isEmpty)

        // 100 ms presentation − 10 ms measured latency − 3 ms safety = 87 ms —
        // the SAME formula/constants as the identity-rate sink test, with no
        // extra term for the base resample.
        let latency = LocalOutputLatencyMeasurement(
            safetyOffsetFrames: 0, deviceLatencyFrames: 480, streamLatencyFrames: 0,
            bufferFrameSizeFrames: 0, nominalSampleRate: outputRate) // 480/48000 = 10 ms
        let sink = SyncedLocalSink(
            renderSampleRate: outputRate, channelCount: 1, safetyMarginMs: 3,
            presentationDelayMs: { 100 }, localOutputLatency: { latency })

        let anchorPtsSec = 2_000
        let anchorNanos = Int64(anchorPtsSec) * 1_000_000_000
        resampled.withUnsafeBufferPointer { buf in
            sink.enqueue(interleavedFrames: buf.baseAddress!, frameCount: buf.count,
                        pts: timespec(tv_sec: anchorPtsSec, tv_nsec: 0))
        }

        let expectedTargetNanos = anchorNanos + 87_000_000
        let nsPerFrame = 1_000_000_000.0 / outputRate
        let framesPerCycle = 512
        var firstNonSilenceHostTime: Int64?
        var firstRealSample: Float?
        var out = [Float](repeating: .nan, count: framesPerCycle)

        for cycle in 0..<80 {
            let cycleStart = anchorNanos + Int64((Double(cycle * framesPerCycle) * nsPerFrame).rounded())
            _ = out.withUnsafeMutableBufferPointer { ob in
                sink.renderInterleaved(into: ob, frameCount: framesPerCycle, cycleStartMonotonicNanos: cycleStart)
            }
            if firstNonSilenceHostTime == nil, let idx = out.firstIndex(where: { $0 != 0 }) {
                firstNonSilenceHostTime = cycleStart + Int64((Double(idx) * nsPerFrame).rounded())
                firstRealSample = out[idx]
            }
        }

        let hostTime = try XCTUnwrap(firstNonSilenceHostTime, "audio was never released")
        XCTAssertLessThanOrEqual(abs(hostTime - expectedTargetNanos), Int64(nsPerFrame.rounded()) * 2,
                                 "resampled fan-out must still release within ~1 output frame of the SAME "
                                 + "computed target — the base resample must not need its own delay term")
        // The anchor property: the Catmull-Rom kernel collapses to input[0] at
        // frac 0 in BOTH resample stages (base resample, then the sink's own
        // ppm-correction resampler at its initial ratio ≈ 1), so the very first
        // released sample is exactly the base resampler's own output[0] — no
        // reordering, no dropped lead-in.
        let realSample = try XCTUnwrap(firstRealSample, "a non-silent sample must have been captured")
        XCTAssertEqual(realSample, resampled[0], accuracy: 1e-6)
    }
    #endif
}
