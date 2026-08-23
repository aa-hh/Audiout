import Foundation
import Testing
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
@Suite final class SyncedLocalFanoutTests: IsolatedSuite {

    // MARK: Doubles

    /// A fake whole-system tap that models the ONE property under test: it captures
    /// the mix of every process EXCEPT those whose object id is in
    /// `excludedProcessObjectIDs`. Each "process" is a pid (mapped to an
    /// `AudioObjectID` one-for-one via `objectID(for:)`) emitting a pure tone;
    /// `deliverMix` sums the non-excluded tones into an interleaved-Float32
    /// 44100/2ch buffer and fires `onBuffer`, exactly as a real process tap would
    /// deliver the system mix minus the excluded processes.
    fileprivate final class FeedbackFakeTap: SystemAudioTap, @unchecked Sendable {
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
    fileprivate final class ScriptedEnumerator: AudioProcessEnumerating {
        let pids: [pid_t]
        init(pids: [pid_t]) { self.pids = pids }
        func enumerateProcesses() -> [RawAudioProcess] {
            pids.map { RawAudioProcess(objectID: FeedbackFakeTap.objectID(for: $0), pid: $0, bundleID: nil) }
        }
        func parentPID(of pid: pid_t) -> pid_t? { nil }
    }

    /// Records every forwarded (pcm, pts) pair — what actually reached the engine.
    fileprivate final class SpyPCMSink: PCMSink, @unchecked Sendable {
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
    fileprivate final class FixedConverter: PCMConverting, @unchecked Sendable {
        // 4 interleaved S16LE stereo frames = 16 bytes; values 1…8.
        static let payload = Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00,
                                   0x05, 0x00, 0x06, 0x00, 0x07, 0x00, 0x08, 0x00])
        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? { Self.payload }
    }

    /// The same fixed payload, plus a one-shot action run DURING a conversion.
    /// `handleBuffer` reads its `BufferSnapshot` before calling the converter, so
    /// a rebuild triggered from that action leaves this buffer finishing against
    /// the PRE-rebuild snapshot — which is exactly the in-flight interleaving that
    /// no amount of poking the coordinator from outside can produce deterministically.
    fileprivate final class InterposingConverter: PCMConverting, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (() -> Void)?

        func runOnNextConvert(_ action: @escaping () -> Void) {
            lock.withLock { pending = action }
        }

        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? {
            let action = lock.withLock { () -> (() -> Void)? in
                defer { pending = nil }
                return pending
            }
            action?()
            return FixedConverter.payload
        }
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
    @Test func selfExclude_tapDoesNotRecaptureSinkTone_goertzel() throws {
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
        #expect(tap.excludes(pid: sinkRenderPID),
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
        #expect(engineSink.forwarded.count == buffers)

        let captured = concat(engineSink.forwarded.map { $0.pcm })
        let feedbackPower = goertzelPowerS16LE(captured, freq: sinkFreq)
        let controlPower = goertzelPowerS16LE(captured, freq: otherFreq)

        // The ordinary app's tone DID reach the engine — the pipeline is alive and
        // the detector works (this is what makes the near-zero below meaningful).
        #expect(controlPower > 1e-3,
                             "the tap must still capture ordinary (non-excluded) app audio")
        // The sink's OWN output did NOT — no feedback loop. Orders of magnitude
        // below the captured control tone.
        #expect(feedbackPower < controlPower / 1_000.0,
                          "the sink's delayed output must not be re-captured as an echo")
    }

    /// Negative control proving the Goertzel detector (and the fake tap) really do
    /// surface the sink's tone when it is NOT excluded — so the test above's
    /// near-zero is the self-exclude working, not a dead pipeline.
    @Test func withoutSelfExclude_sinkToneFeedsBack_provingDetector() throws {
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
        #expect(!tap.excludes(pid: sinkRenderPID))

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
        #expect(feedbackPower > 1e-3,
                             "without the self-exclude the sink's tone re-enters capture (the loop)")
    }
    #endif

    // MARK: - Fan-out wiring (gated like metering).

    @Test func fanOut_deliversToSink_onlyWhenAttached() {
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
        #expect(localSink.enqueued.count == 0, "no fan-out while the sink is detached")

        // Attach → subsequent buffers fan out to the sink with the same pts. This
        // pid is genuinely new, so the attach rebuilds the tap, and the tail also
        // carries that rebuild's silence fill (fix 2) — the program blocks are the
        // non-silent ones.
        coordinator.setSyncedLocalSink(localSink, renderProcessPID: sinkRenderPID)
        tap.deliverMix(frames: 4, phaseStart: 4, pts: timespec(tv_sec: 2, tv_nsec: 0))
        waitFor { localSink.enqueued.contains { $0.frames.contains { $0 != 0 } } }

        let program = localSink.enqueued.filter { $0.frames.contains { $0 != 0 } }
        #expect(program.count == 1)
        let call = program[0]
        #expect(call.frameCount == 4, "16-byte S16LE stereo payload = 4 frames")
        #expect(call.pts.tv_sec == 2, "fan-out carries the capture pts unchanged")
        // The fixed payload widens 1…8 (Int16) → Float32 / 32768.
        let expected = (1...8).map { Float($0) / 32768.0 }
        #expect(call.frames.count == expected.count)
        for (got, want) in zip(call.frames, expected) {
            #expect(abs(got - want) <= 1e-6)
        }

        // Detach → fan-out stops again.
        coordinator.setSyncedLocalSink(nil, renderProcessPID: nil)
        tap.deliverMix(frames: 4, phaseStart: 8, pts: timespec(tv_sec: 3, tv_nsec: 0))
        waitFor { engineSink.forwarded.filter { $0.pcm == FixedConverter.payload }.count == 3 }
        #expect(localSink.enqueued.filter { $0.frames.contains { $0 != 0 } }.count == 1,
                "no fan-out after detach")
    }

    /// Attaching a GENUINELY NEW render pid while already capturing recreates the
    /// tap so the new self-exclude takes effect immediately (mirrors the
    /// routing-exclusion recreate). An already-excluded pid does not — see
    /// `attachWithAlreadyExcludedPid_doesNotRecreateTap` below.
    @Test func attachWhileCapturing_recreatesTapWithSelfExclude() {
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
        #expect(tap.creates == 1)
        #expect(!tap.excludes(pid: sinkRenderPID))

        coordinator.setSyncedLocalSink(localSink, renderProcessPID: sinkRenderPID)
        waitFor { tap.excludes(pid: self.sinkRenderPID) }
        #expect(tap.creates == 2, "attaching a sink while capturing recreates the tap")
        #expect(tap.excludes(pid: sinkRenderPID))
    }

    /// Attaching the Mac's own sink mid-capture with a render pid the tap ALREADY
    /// excludes (in production: our own `getpid()`, self-excluded on every tap
    /// creation) must NOT recreate the tap. That rebuild's ~200 ms feed hole is what
    /// permanently retarded every AirPlay receiver on each Mac-join
    /// (`dev/notes/test3-mac-join-desync-diagnosis.md`).
    @Test func attachWithAlreadyExcludedPid_doesNotRecreateTap() {
        let tap = FeedbackFakeTap()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: SpyPCMSink(),
            makeConverter: { _ in FixedConverter() },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [sinkRenderPID])),
            muteBehavior: .mutedWhenTapped)
        // The BT sink attach puts the pid into the exclusion set BEFORE the first
        // tap is created — in production both sinks render in our own process, so
        // the first tap already excludes it either way.
        coordinator.setBTSink(SpySyncedSink(), renderProcessPID: sinkRenderPID)
        coordinator.start()
        waitForCapturing(coordinator)
        #expect(tap.creates == 1)
        #expect(tap.excludes(pid: sinkRenderPID))

        coordinator.setSyncedLocalSink(SpySyncedSink(), renderProcessPID: sinkRenderPID)
        waitFor(timeout: 0.3) { false }
        #expect(tap.creates == 1,
                "an already-excluded render pid must not force a tap recreate (the Mac-join feed hole)")
    }

    // MARK: - Fix 2: a tap rebuild's feed hole is filled with silence.

    /// A rebuild that DOES happen still stops delivery for however long the HAL
    /// takes. The sender anchors rtptime↔walltime to samples-sent, so the missing
    /// samples must be handed to the same delivery tail as silence — otherwise
    /// every receiver comes back permanently late by the hole's length
    /// (`dev/notes/test3-mac-join-desync-diagnosis.md`).
    @Test func aTapRebuildsFeedHoleIsFilledWithSilenceThroughTheNormalTail() {
        let tap = FeedbackFakeTap()
        let engineSink = SpyPCMSink()
        let localSink = SpySyncedSink()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in FixedConverter() },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [sinkRenderPID])),
            muteBehavior: .mutedWhenTapped)
        // Attached BEFORE start, so the only rebuild in this test is the routing one.
        coordinator.setSyncedLocalSink(localSink, renderProcessPID: sinkRenderPID)
        coordinator.start()
        waitForCapturing(coordinator)

        tap.deliverMix(frames: 4, phaseStart: 0, pts: timespec(tv_sec: 1, tv_nsec: 0))
        waitFor { engineSink.forwarded.count == 1 }

        // A genuinely changed exclusion union → a real `.exclusionChange` rebuild.
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.example.x"])
        waitFor { tap.creates == 2 }
        waitForCapturing(coordinator)
        #expect(tap.creates == 2)

        // 500 ms after the first buffer's pts: the hole is that half-second minus
        // the 4 frames buffer 1 itself covered.
        tap.deliverMix(frames: 4, phaseStart: 4,
                       pts: timespec(tv_sec: 1, tv_nsec: 500_000_000))
        waitFor { engineSink.forwarded.last?.pcm == FixedConverter.payload
                  && engineSink.forwarded.count > 2 }

        let bytesPerFrame = PCMFormat.airplay.channels * MemoryLayout<Int16>.size
        let forwarded = engineSink.forwarded
        #expect(forwarded.first?.pcm == FixedConverter.payload, "buffer 1, unchanged")
        #expect(forwarded.last?.pcm == FixedConverter.payload, "buffer 2, unchanged")

        let fill = Array(forwarded.dropFirst().dropLast())
        #expect(!fill.isEmpty, "the rebuild's hole must be filled, not skipped")
        #expect(fill.allSatisfy { $0.pcm.allSatisfy { $0 == 0 } }, "the fill is S16LE silence")
        #expect(fill.allSatisfy { $0.pcm.count / bytesPerFrame <= 4_096 },
                "chunked, so no single write floods a downstream ring")
        let fillFrames = fill.reduce(0) { $0 + $1.pcm.count / bytesPerFrame }
        // round((0.5 s − 4/44100 s) × 44100).
        #expect(fillFrames == 22_046, "the fill is exactly the hole, in frames")

        // The fill starts where buffer 1's audio ended, so the timeline is unbroken.
        let buffer1EndNanos = Int64(1_000_000_000)
            + Int64((4.0 * 1_000_000_000 / 44_100.0).rounded())
        #expect(fill.first.map { SyncTiming.monotonicNanos($0.pts) } == buffer1EndNanos)

        // Every consumer of the tail gets it, not just the engine.
        let fanoutFillFrames = localSink.enqueued
            .filter { $0.frameCount != 4 }
            .reduce(0) { $0 + $1.frameCount }
        #expect(fanoutFillFrames == 22_046, "the synced-local fan-out receives the same fill")
    }

    /// A buffer that cleared `handleBuffer`'s converter guard just BEFORE a rebuild
    /// claimed is still in flight when the arm goes up. It must not consume that
    /// arm: it would measure a ~0 ms gap against its own predecessor and leave the
    /// real rebuild hole disarmed — unfilled and unmeasured, i.e. the receiver slip
    /// the fill exists to prevent (`dev/notes/test3-mac-join-desync-diagnosis.md`).
    @Test func aBufferInFlightWhenTheRebuildClaimsDoesNotConsumeTheArm() {
        let tap = FeedbackFakeTap()
        let engineSink = SpyPCMSink()
        let converter = InterposingConverter()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in converter },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [sinkRenderPID])),
            muteBehavior: .mutedWhenTapped)
        defer { coordinator.stop() }
        coordinator.start()
        waitForCapturing(coordinator)

        tap.deliverMix(frames: 4, phaseStart: 0, pts: timespec(tv_sec: 1, tv_nsec: 0))
        waitFor { engineSink.forwarded.count == 1 }

        // Buffer 2 reads the pre-rebuild snapshot, then the whole rebuild — claim,
        // arm, commit — runs while it sits inside the converter.
        converter.runOnNextConvert {
            coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.example.x"])
        }
        tap.deliverMix(frames: 4, phaseStart: 4, pts: timespec(tv_sec: 1, tv_nsec: 100_000_000))
        waitFor { engineSink.forwarded.count >= 2 }
        #expect(tap.creates == 2, "the rebuild must have run inside buffer 2's conversion")
        #expect(engineSink.forwarded.count == 2,
                "an in-flight pre-rebuild buffer must not consume the arm (no fill of its own)")
        #expect(engineSink.forwarded.allSatisfy { $0.pcm == FixedConverter.payload })

        // The arm is still standing, so the FIRST genuinely post-rebuild buffer
        // fills the whole hole — measured from the in-flight buffer's end, because
        // that audio really did go downstream.
        tap.deliverMix(frames: 4, phaseStart: 8, pts: timespec(tv_sec: 1, tv_nsec: 600_000_000))
        waitFor { engineSink.forwarded.count > 3 }

        let bytesPerFrame = PCMFormat.airplay.channels * MemoryLayout<Int16>.size
        let forwarded = engineSink.forwarded
        #expect(forwarded.last?.pcm == FixedConverter.payload, "buffer 3, unchanged")
        let fill = Array(forwarded.dropFirst(2).dropLast())
        #expect(!fill.isEmpty, "the arm must survive for the real post-rebuild buffer")
        #expect(fill.allSatisfy { $0.pcm.allSatisfy { $0 == 0 } }, "the fill is S16LE silence")
        let fillFrames = fill.reduce(0) { $0 + $1.pcm.count / bytesPerFrame }
        // round((0.5 s − 4/44100 s) × 44100) — measured from buffer 2's end at 1.1 s.
        #expect(fillFrames == 22_046, "the fill is the hole after buffer 2, not after buffer 1")
    }

    /// `stop()` must clear the tracker outright, not just disarm it. The
    /// coordinator outlives a capture session, so a surviving `lastEndPts` lets the
    /// first rebuild of the NEXT session measure its hole against the PREVIOUS
    /// session's final buffer — injecting a stop-length slab of stale-pts silence
    /// that mis-anchors every FIFO sink's one-shot anchor.
    @Test func aRebuildInAFreshSessionNeverFillsAgainstThePreviousSession() {
        let tap = FeedbackFakeTap()
        let engineSink = SpyPCMSink()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in FixedConverter() },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [sinkRenderPID])),
            muteBehavior: .mutedWhenTapped)
        defer { coordinator.stop() }
        coordinator.start()
        waitForCapturing(coordinator)

        tap.deliverMix(frames: 4, phaseStart: 0, pts: timespec(tv_sec: 1, tv_nsec: 0))
        waitFor { engineSink.forwarded.count == 1 }

        coordinator.stop()
        coordinator.start()
        waitForCapturing(coordinator)
        #expect(tap.creates == 2)

        // A rebuild racing the new session up, before it has delivered anything.
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.example.x"])
        waitFor { tap.creates == 3 }
        waitForCapturing(coordinator)

        // 1.5 s past the OLD session's last buffer — inside the 2 s fill cap, so a
        // surviving `lastEndPts` would inject ~66 000 frames of stale-pts silence
        // ahead of the new capture session's very first write.
        tap.deliverMix(frames: 4, phaseStart: 4, pts: timespec(tv_sec: 2, tv_nsec: 500_000_000))
        waitFor { engineSink.forwarded.count >= 2 }
        waitFor(timeout: 0.3) { false }

        let forwarded = engineSink.forwarded
        #expect(forwarded.count == 2, "a new session must start from 'nothing ever delivered'")
        #expect(forwarded.allSatisfy { $0.pcm == FixedConverter.payload },
                "no silence fill may bridge two capture sessions")
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
    @Test func baseResampler_identityRatio_isBitExactPassthrough() {
        let resampler = SyncedLocalBaseResampler(inputRate: 44_100, outputRate: 44_100, channelCount: 2)
        #expect(resampler.isIdentity)
        #expect(abs(resampler.ratio - 1.0) <= 1e-12)

        let input: [Float] = (0..<40).map { Float($0) * 0.01 - 0.2 }
        let out = input.withUnsafeBufferPointer { buf in
            resampler.resample(input: buf.baseAddress!, frameCount: 20)
        }
        #expect(out == input, "identity ratio must be a bit-exact passthrough")
    }

    /// Upsampling 44.1 kHz → 48 kHz must produce a frame count matching the rate
    /// ratio (never a hardcoded assumption) — the frame-count half of T5's
    /// "correct frame counts, no pitch shift" check.
    @Test func baseResampler_upsample44_1to48_producesRateScaledFrameCount() {
        let inputRate = 44_100.0, outputRate = 48_000.0
        let resampler = SyncedLocalBaseResampler(inputRate: inputRate, outputRate: outputRate, channelCount: 1)
        #expect(!resampler.isIdentity)
        #expect(abs(resampler.ratio - inputRate / outputRate) <= 1e-12)

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
        #expect(abs(Double(out.count) - outputRate) <= 8,
                       "1 s of 44.1 kHz input must resample to ~1 s of 48 kHz output frames")
    }

    /// The pitch half: resampling 44.1 kHz → 48 kHz must NOT shift the tone's
    /// frequency. A naive "play the 44.1 kHz samples out at 48 kHz with no rate
    /// conversion" bug (the diagnosed dropout symptom: "AirPlay plays pitched up
    /// ~+8.8%" = 48000/44100) would leave a 440 Hz input sounding like ~479 Hz once
    /// played back at 48 kHz. Goertzel at both frequencies over the ACTUAL
    /// resampled output proves the tone landed at 440 Hz, not the pitched one.
    @Test func baseResampler_upsample_doesNotPitchShift_goertzel() {
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
        #expect(!out.isEmpty)

        let correctPower = goertzelPowerFloat(out, freq: freq, sampleRate: outputRate)
        let pitchedFreq = freq * outputRate / inputRate // ~479 Hz — the un-resampled bug's symptom
        let pitchedPower = goertzelPowerFloat(out, freq: pitchedFreq, sampleRate: outputRate)

        #expect(correctPower > 0.05,
                             "the resampled output must retain the original 440 Hz tone")
        #expect(pitchedPower < correctPower / 50.0,
                          "the output must not show the ~+8.8% pitched-up frequency a missing base resample would produce")
    }

    /// Downsampling direction too (a device running SLOWER than 44.1 kHz is rare
    /// but not impossible): ratio > 1, still no pitch shift, frame count still
    /// rate-scaled — proves the resampler isn't secretly only correct in the
    /// up-sample direction the dropout bug exercises.
    @Test func baseResampler_downsample48to44_1_producesRateScaledFrameCount_noPitchShift() {
        let inputRate = 48_000.0, outputRate = 44_100.0, freq = 440.0
        let resampler = SyncedLocalBaseResampler(inputRate: inputRate, outputRate: outputRate, channelCount: 1)
        #expect(!resampler.isIdentity)
        #expect(abs(resampler.ratio - inputRate / outputRate) <= 1e-12)

        let frameCount = Int(inputRate * 0.5)
        var input = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            input[i] = Float(sin(2.0 * Double.pi * freq * Double(i) / inputRate))
        }
        let out = input.withUnsafeBufferPointer { buf in
            resampler.resample(input: buf.baseAddress!, frameCount: frameCount)
        }
        #expect(abs(Double(out.count) - outputRate * 0.5) <= 8)

        let correctPower = goertzelPowerFloat(out, freq: freq, sampleRate: outputRate)
        let pitchedFreq = freq * outputRate / inputRate
        let pitchedPower = goertzelPowerFloat(out, freq: pitchedFreq, sampleRate: outputRate)
        #expect(correctPower > 0.05)
        #expect(pitchedPower < correctPower / 50.0)
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
    @Test func fanOutThroughResample_thenSink_releasesAtComputedTarget_noExtraDelay() throws {
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
        #expect(!resampled.isEmpty)

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

        let hostTime = try #require(firstNonSilenceHostTime, "audio was never released")
        #expect(max(hostTime, expectedTargetNanos) - min(hostTime, expectedTargetNanos) <= Int64(nsPerFrame.rounded()) * 2,
                                 "resampled fan-out must still release within ~1 output frame of the SAME computed target — the base resample must not need its own delay term")
        // The anchor property: the Catmull-Rom kernel collapses to input[0] at
        // frac 0 in BOTH resample stages (base resample, then the sink's own
        // ppm-correction resampler at its initial ratio ≈ 1), so the very first
        // released sample is exactly the base resampler's own output[0] — no
        // reordering, no dropped lead-in.
        let realSample = try #require(firstRealSample, "a non-silent sample must have been captured")
        #expect(abs(realSample - resampled[0]) <= 1e-6)
    }
    #endif
}

/// The one fan-out case that touches `Telemetry`'s process-global test sink, so
/// it lives under `SerializedSharedState` (cookbook §18) while the suite above
/// stays parallel. Named to keep `--filter SyncedLocalFanoutTests` matching both.
extension SerializedSharedState {

    @Suite final class SyncedLocalFanoutTestsFeedGapTelemetry: IsolatedSuite {

        private final class LineCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.withLock { lines.append(line) } }

            /// Poll (never sleep a fixed amount): the line is emitted from the
            /// coordinator's own queue, not from the delivery call that measured it.
            /// Matches on the whole `fields` set, because the sink is process-global
            /// and a concurrently-running suite can land its own lines here too.
            func pollForLine(evt: String, containing fields: [String],
                             timeout: TimeInterval = 5) async -> String? {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    let hit = lock.withLock { lines }.first {
                        $0.contains("\"evt\":\"\(evt)\"") && fields.allSatisfy($0.contains)
                    }
                    if let hit { return hit }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return nil
            }
        }

        private let sinkRenderPID: pid_t = 424_242

        private func waitForCapturing(_ c: NativeCaptureCoordinator) async {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if case .capturing = c.state { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        /// The measurement half of fix 2: whatever the fill decides to do, the hole
        /// itself is always on the record, so the next live repro reads as facts
        /// rather than inference (`dev/notes/test3-mac-join-desync-diagnosis.md`).
        @Test func aTapRebuildLogsTheFeedGapItLeft() async throws {
            let capture = LineCapture()
            Telemetry._installTestSink { capture.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let tap = SyncedLocalFanoutTests.FeedbackFakeTap()
            let engineSink = SyncedLocalFanoutTests.SpyPCMSink()
            let coordinator = NativeCaptureCoordinator(
                makeTap: { tap },
                sink: engineSink,
                makeConverter: { _ in SyncedLocalFanoutTests.FixedConverter() },
                processResolver: AudioProcessResolver(
                    enumerator: SyncedLocalFanoutTests.ScriptedEnumerator(pids: [sinkRenderPID])),
                muteBehavior: .mutedWhenTapped)
            defer { coordinator.stop() }

            coordinator.start()
            await waitForCapturing(coordinator)

            tap.deliverMix(frames: 4, phaseStart: 0, pts: timespec(tv_sec: 1, tv_nsec: 0))
            #expect(engineSink.forwarded.count == 1)

            coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.example.x"])
            await waitForCapturing(coordinator)
            #expect(tap.creates == 2)

            tap.deliverMix(frames: 4, phaseStart: 4,
                           pts: timespec(tv_sec: 1, tv_nsec: 500_000_000))

            // The gap: 500 ms minus the 4 frames buffer 1 already covered.
            _ = try #require(
                await capture.pollForLine(
                    evt: "tap_feed_gap",
                    containing: ["\"cause\":\"exclusionChange\"", "\"gapMs\":\"499.9\""]),
                "no tap_feed_gap line for the rebuild's hole")
        }
    }
}
