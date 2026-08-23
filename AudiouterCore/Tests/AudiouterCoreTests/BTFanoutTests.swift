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

/// BT-FANOUT: the whole-system tap fans the SAME converted PCM+pts it hands the
/// engine (and the synced-local sink) to the Bluetooth sink manager, and the BT
/// sinks' render process is excluded from the tap so their delayed output never
/// re-enters capture as an echo (PLAN-UNIVERSAL-SYNC risk R-echo).
///
/// Mirrors `SyncedLocalFanoutTests` — same fully-synthetic harness (fake tap
/// modelling per-process capture-with-exclusion, scripted pid→object resolver,
/// Goertzel single-bin tone detection), with its own private doubles per the
/// house convention. The one BT-specific behavior pinned here beyond the
/// mirror: `setBTSink` delegates its rebuild decision to the
/// compare-before-rebuild (`rebuildIfExclusionObjectsChanged`), so attaching
/// with an ALREADY-excluded render pid recreates nothing, while a genuinely new
/// pid still takes effect immediately.
@Suite final class BTFanoutTests: IsolatedSuite {

    // MARK: Doubles (private copies — suites keep their own)

    /// Models the one property under test: captures the mix of every process
    /// EXCEPT those whose object id is in the tap's excluded set.
    private final class FeedbackFakeTap: SystemAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?

        static let sampleRate = 44_100.0
        static let channels = 2
        let format = TapFormat(sampleRate: 44_100, channels: 2, bitsPerSample: 32,
                               isFloat: true, isInterleaved: true)

        private let lock = NSLock()
        private var _processes: [pid_t: Double] = [:]
        private var _excluded: Set<AudioObjectID> = []
        private var _createCount = 0

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

    /// One process object per pid, at `objectID == pid` — the same mapping the
    /// fake tap checks for exclusion.
    private final class ScriptedEnumerator: AudioProcessEnumerating {
        let pids: [pid_t]
        init(pids: [pid_t]) { self.pids = pids }
        func enumerateProcesses() -> [RawAudioProcess] {
            pids.map { RawAudioProcess(objectID: FeedbackFakeTap.objectID(for: $0), pid: $0, bundleID: nil) }
        }
        func parentPID(of pid: pid_t) -> pid_t? { nil }
    }

    private final class SpyPCMSink: PCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [(pcm: Data, pts: timespec)] = []
        func write(pcm: Data, pts: timespec) { lock.withLock { writes.append((pcm, pts)) } }
        var forwarded: [(pcm: Data, pts: timespec)] { lock.withLock { writes } }
    }

    /// Fan-out spy standing in for the BT sink manager (and, where a test wants
    /// both consumers, the synced-local sink too).
    private final class SpyFanoutSink: SyncedLocalPCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(frames: [Float], frameCount: Int, pts: timespec)] = []
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
            let channels = PCMFormat.airplay.channels
            let buf = UnsafeBufferPointer(start: interleavedFrames, count: frameCount * channels)
            lock.withLock { calls.append((Array(buf), frameCount, pts)) }
        }
        var enqueued: [(frames: [Float], frameCount: Int, pts: timespec)] { lock.withLock { calls } }
    }

    /// Deterministic converter emitting a fixed non-empty S16LE payload —
    /// 4 interleaved stereo frames, values 1…8.
    private final class FixedConverter: PCMConverting, @unchecked Sendable {
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

    /// Goertzel single-bin power at `freq` on channel 0 of interleaved S16LE.
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

    // Stand-in for the BT sinks' render process (`getpid()` in production).
    private let btRenderPID: pid_t = 313_131
    // A second, distinct render pid for the synced-local sink slot.
    private let syncedRenderPID: pid_t = 424_242
    // An ordinary app whose audio the tap SHOULD keep capturing.
    private let otherAppPID: pid_t = 100
    private let btFreq = 440.0       // the BT sinks' delayed output tone (the hazard)
    private let otherFreq = 3_000.0  // an unrelated app's tone (positive control)

    // MARK: - Goertzel: no feedback loop when the BT render process is excluded.

    #if canImport(AVFoundation)
    @Test func selfExclude_tapDoesNotRecaptureBTSinkTone_goertzel() throws {
        let tap = FeedbackFakeTap()
        tap.setProcesses([btRenderPID: btFreq, otherAppPID: otherFreq])
        let engineSink = SpyPCMSink()
        let btSink = SpyFanoutSink()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { AVFormatConverter(from: $0) },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [btRenderPID, otherAppPID])),
            muteBehavior: .mutedWhenTapped)

        // Attach BEFORE start() so the very first tap carries the exclusion.
        coordinator.setBTSink(btSink, renderProcessPID: btRenderPID)
        coordinator.start()
        waitForCapturing(coordinator)

        #expect(tap.excludes(pid: btRenderPID),
                "the BT sinks' render process must be excluded from the whole-system tap")

        let frames = 4_096
        let buffers = 8
        for i in 0..<buffers {
            tap.deliverMix(frames: frames, phaseStart: i * frames,
                           pts: timespec(tv_sec: i, tv_nsec: 0))
        }
        waitFor { engineSink.forwarded.count == buffers }
        #expect(engineSink.forwarded.count == buffers)

        let captured = concat(engineSink.forwarded.map { $0.pcm })
        let feedbackPower = goertzelPowerS16LE(captured, freq: btFreq)
        let controlPower = goertzelPowerS16LE(captured, freq: otherFreq)

        // The ordinary app's tone DID reach the engine — pipeline + detector
        // alive, which is what makes the near-zero below meaningful.
        #expect(controlPower > 1e-3,
                "the tap must still capture ordinary (non-excluded) app audio")
        #expect(feedbackPower < controlPower / 1_000.0,
                "the BT sinks' delayed output must not be re-captured as an echo")
    }
    #endif

    // MARK: - Fan-out wiring (gated like the synced-local consumer).

    @Test func btFanOut_deliversToBTSink_onlyWhenAttached() {
        let tap = FeedbackFakeTap()
        let engineSink = SpyPCMSink()
        let btSink = SpyFanoutSink()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in FixedConverter() },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [btRenderPID])),
            muteBehavior: .mutedWhenTapped)
        coordinator.start()
        waitForCapturing(coordinator)

        // Not attached: engine fed, BT slot silent.
        tap.deliverMix(frames: 4, phaseStart: 0, pts: timespec(tv_sec: 1, tv_nsec: 0))
        waitFor { engineSink.forwarded.count == 1 }
        #expect(btSink.enqueued.isEmpty, "no BT fan-out while detached")

        // Attach → subsequent buffers fan out with the capture pts unchanged. This
        // pid is genuinely new, so the attach rebuilds the tap, and the tail also
        // carries that rebuild's silence fill (fix 2) — the program blocks are the
        // non-silent ones.
        coordinator.setBTSink(btSink, renderProcessPID: btRenderPID)
        tap.deliverMix(frames: 4, phaseStart: 4, pts: timespec(tv_sec: 2, tv_nsec: 0))
        waitFor { btSink.enqueued.contains { $0.frames.contains { $0 != 0 } } }

        let program = btSink.enqueued.filter { $0.frames.contains { $0 != 0 } }
        #expect(program.count == 1)
        let call = program[0]
        #expect(call.frameCount == 4, "16-byte S16LE stereo payload = 4 frames")
        #expect(call.pts.tv_sec == 2, "BT fan-out carries the capture pts unchanged")
        // The fixed payload widens 1…8 (Int16) → Float32 / 32768, identity rate.
        let expected = (1...8).map { Float($0) / 32768.0 }
        #expect(call.frames.count == expected.count)
        for (got, want) in zip(call.frames, expected) {
            #expect(abs(got - want) <= 1e-6)
        }

        // Detach → fan-out stops again.
        coordinator.setBTSink(nil, renderProcessPID: nil)
        tap.deliverMix(frames: 4, phaseStart: 8, pts: timespec(tv_sec: 3, tv_nsec: 0))
        waitFor { engineSink.forwarded.filter { $0.pcm == FixedConverter.payload }.count == 3 }
        #expect(btSink.enqueued.filter { $0.frames.contains { $0 != 0 } }.count == 1,
                "no BT fan-out after detach")
    }

    /// BOTH consumers attached: one delivered buffer reaches the engine, the
    /// synced-local sink, AND the BT sink — one capture, three consumers.
    @Test func bothFanoutConsumersReceiveTheSameBuffer() {
        let tap = FeedbackFakeTap()
        let engineSink = SpyPCMSink()
        let localSink = SpyFanoutSink()
        let btSink = SpyFanoutSink()

        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: engineSink,
            makeConverter: { _ in FixedConverter() },
            processResolver: AudioProcessResolver(
                enumerator: ScriptedEnumerator(pids: [btRenderPID, syncedRenderPID])),
            muteBehavior: .mutedWhenTapped)
        coordinator.setSyncedLocalSink(localSink, renderProcessPID: syncedRenderPID)
        coordinator.setBTSink(btSink, renderProcessPID: btRenderPID)
        coordinator.start()
        waitForCapturing(coordinator)
        #expect(tap.excludes(pid: syncedRenderPID))
        #expect(tap.excludes(pid: btRenderPID), "both render processes are excluded together")

        tap.deliverMix(frames: 4, phaseStart: 0, pts: timespec(tv_sec: 7, tv_nsec: 0))
        waitFor { !btSink.enqueued.isEmpty && !localSink.enqueued.isEmpty }

        #expect(engineSink.forwarded.count == 1)
        #expect(localSink.enqueued.count == 1)
        #expect(btSink.enqueued.count == 1)
        #expect(localSink.enqueued[0].frames == btSink.enqueued[0].frames,
                "both consumers receive the identical widened PCM")
        #expect(btSink.enqueued[0].pts.tv_sec == 7)
    }

    // MARK: - Compare-before-rebuild: `setBTSink` never storms the tap.

    /// Attaching the BT sink mid-capture with a render pid the tap ALREADY
    /// excludes (here: the synced-local sink's pid — in production both are the
    /// same `getpid()`) must NOT recreate the tap: the resolved object set is
    /// unchanged, so `rebuildIfExclusionObjectsChanged` no-ops.
    @Test func attachWithAlreadyExcludedPid_doesNotRecreateTap() {
        let tap = FeedbackFakeTap()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: SpyPCMSink(),
            makeConverter: { _ in FixedConverter() },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [syncedRenderPID])),
            muteBehavior: .mutedWhenTapped)
        coordinator.setSyncedLocalSink(SpyFanoutSink(), renderProcessPID: syncedRenderPID)
        coordinator.start()
        waitForCapturing(coordinator)
        #expect(tap.creates == 1)
        #expect(tap.excludes(pid: syncedRenderPID))

        coordinator.setBTSink(SpyFanoutSink(), renderProcessPID: syncedRenderPID)
        waitFor(timeout: 0.3) { false }
        #expect(tap.creates == 1,
                "an already-excluded render pid must not force a tap recreate (no per-toggle rebuild storm)")
    }

    /// A genuinely NEW render pid attached mid-capture still takes effect
    /// immediately: the resolved object set changed, so the tap is recreated
    /// with the BT exclusion in force.
    @Test func attachWithNewPidWhileCapturing_recreatesTapWithExclusion() {
        let tap = FeedbackFakeTap()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: SpyPCMSink(),
            makeConverter: { _ in FixedConverter() },
            processResolver: AudioProcessResolver(enumerator: ScriptedEnumerator(pids: [btRenderPID])),
            muteBehavior: .mutedWhenTapped)
        coordinator.start()
        waitForCapturing(coordinator)
        #expect(tap.creates == 1)
        #expect(!tap.excludes(pid: btRenderPID))

        coordinator.setBTSink(SpyFanoutSink(), renderProcessPID: btRenderPID)
        waitFor { tap.excludes(pid: self.btRenderPID) }
        #expect(tap.creates == 2, "a new BT render pid recreates the tap so the exclusion is live")
        #expect(tap.excludes(pid: btRenderPID))
    }
}
