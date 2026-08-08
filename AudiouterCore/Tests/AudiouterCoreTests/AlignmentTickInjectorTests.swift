// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

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

    // MARK: Keep-alive bed + wake preamble (W2 — the Sonos amp-gate fix)

    /// The bed rides under every active frame at ~−47 dBFS RMS — present, but
    /// far below the tick.
    @Test func bedIsPresentAtTheTargetLevel() {
        let injector = AlignmentTickInjector(
            sampleRate: 1_000, config: .init(bpm: 600, maxTicks: 4))
        var pcm = zeroBuffer(frames: 100)
        injector.mix(into: &pcm)
        let samples = channel0(pcm)
        // Between ticks (frames 30..<100) only the bed plays.
        let bedOnly = samples[30..<100].map { Double($0) / 32_768.0 }
        #expect(bedOnly.contains { $0 != 0 }, "the bed keeps signal flowing between ticks")
        let rms = (bedOnly.map { $0 * $0 }.reduce(0, +) / Double(bedOnly.count)).squareRoot()
        let dBFS = 20 * log10(max(rms, 1e-12))
        #expect(dBFS > -53 && dBFS < -41, "bed ≈ −47 dBFS RMS, measured \(dBFS)")
    }

    /// The wizard's wake preamble: bed only — no tick — for the configured
    /// stretch, then the first tick lands on already-awake amps.
    @Test func preambleIsBedOnlyBeforeTheFirstTick() {
        let injector = AlignmentTickInjector(
            sampleRate: 1_000,
            config: .init(bpm: 600, maxTicks: 2, preambleSeconds: 0.2))
        #expect(injector.test_preambleFrames == 200)
        var pcm = zeroBuffer(frames: 300)
        injector.mix(into: &pcm)
        let samples = channel0(pcm)
        let tickPeak = Double(0.35 * 0.7 * 32_767)   // the tick's first partial scale
        #expect(samples[0..<200].allSatisfy { abs(Double($0)) < tickPeak / 8 },
                "the preamble carries only the quiet bed, never a tick")
        #expect(samples[200...229].contains { abs(Double($0)) > tickPeak / 8 },
                "the first tick starts right after the preamble")
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

    /// The wizard config: long budget, ~3 s preamble, bed on.
    @Test func wizardConfigShape() {
        let config = AlignmentTickInjector.Config.wizard
        #expect(config.maxTicks == 360)
        #expect(config.preambleSeconds == 3)
        #expect(config.bedEnabled)
        #expect(AlignmentTickInjector.Config.manual.preambleSeconds == 0)
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

    private final class SpyPCMSink: PCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [Data] = []
        func write(pcm: Data, pts: timespec) { lock.withLock { writes.append(pcm) } }
        var forwarded: [Data] { lock.withLock { writes } }
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
}
