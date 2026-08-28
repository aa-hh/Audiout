// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing
@testable import AudioutCore

/// Hermetic tests for ``LeveledAppInjector`` — the per-app volume path for apps
/// that are NOT redirected anywhere. Every seam is injected (a trivial
/// ``PCMConverting``), so the sample math runs with no Core Audio, no tap and no
/// engine. Same stakes as ``AppRouteMixerTests``: a bug here is audible garbage
/// mixed into the whole-system program.
@Suite struct LeveledAppInjectorTests {

    // MARK: Doubles

    /// Returns the buffer's first channel bytes verbatim as the "converted"
    /// S16LE PCM, so a test's input IS the injector's input.
    private struct IdentityConverter: PCMConverting {
        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? {
            buffer.channelData.first
        }
    }

    /// Thread-safe collector for the `@Sendable` per-app level callback.
    private final class LevelSink: @unchecked Sendable {
        private let lock = NSLock()
        private var levels: [(bundleID: String, rms: Float)] = []
        func append(_ bundleID: String, _ rms: Float) {
            lock.lock(); levels.append((bundleID, rms)); lock.unlock()
        }
        var all: [(bundleID: String, rms: Float)] { lock.lock(); defer { lock.unlock() }; return levels }
        var isEmpty: Bool { all.isEmpty }
    }

    // MARK: Helpers

    /// An ACTIVE injector (the whole-system capture is running) with `apps`
    /// leveled and every one of them already `.capturing`.
    private func injector(_ apps: [(bundleID: String, volume: Int)]) -> LeveledAppInjector {
        let injector = LeveledAppInjector(makeConverter: { _ in IdentityConverter() })
        injector.updateLeveled(apps)
        for app in apps {
            injector.handleStateChange(bundleID: app.bundleID, state: capturing)
        }
        injector.setActive(true)
        return injector
    }

    private var capturing: PerAppCaptureCoordinator.State {
        .capturing(TapFormat(sampleRate: 44_100, channels: 2, bitsPerSample: 16,
                             isFloat: false, isInterleaved: true))
    }

    /// Build an S16LE interleaved-stereo ``CapturedBuffer`` from L/R pairs.
    private func s16Buffer(_ pairs: [(Int16, Int16)]) -> CapturedBuffer {
        CapturedBuffer(channelData: [pcm(pairs)], frameCount: pairs.count,
                       pts: timespec(tv_sec: 0, tv_nsec: 0))
    }

    /// Interleaved S16LE `Data` from L/R pairs.
    private func pcm(_ pairs: [(Int16, Int16)]) -> Data {
        var data = Data(count: pairs.count * 4)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var i = 0
            for (l, r) in pairs {
                let lb = UInt16(bitPattern: l), rb = UInt16(bitPattern: r)
                raw[i] = UInt8(lb & 0xFF); raw[i + 1] = UInt8(lb >> 8)
                raw[i + 2] = UInt8(rb & 0xFF); raw[i + 3] = UInt8(rb >> 8)
                i += 4
            }
        }
        return data
    }

    /// Decode interleaved S16LE `Data` back to a flat sample list (L, R, L, R…).
    private func samples(_ data: Data) -> [Int16] {
        var out: [Int16] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i + 1 < raw.count {
                out.append(Int16(bitPattern: UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)))
                i += 2
            }
        }
        return out
    }

    /// A block of `count` identical program frames to mix into.
    private func program(_ value: Int16, frames count: Int) -> Data {
        pcm(Array(repeating: (value, value), count: count))
    }

    // MARK: - 1. Convert, scale, sum

    @Test func scalesEachAppByItsOwnVolumeAndSumsOntoTheProgram() {
        let injector = injector([("a", 50), ("b", 100)])
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(1000, 2000)]))
        injector.handleBuffer(bundleID: "b", buffer: s16Buffer([(4, 6)]))

        var block = program(100, frames: 1)
        injector.mix(into: &block, frameCount: 1)

        // 100 (program) + 500 (1000 at 50%) + 4 (b at 100%) = 604 / 1106.
        #expect(samples(block) == [604, 1106])
    }

    @Test func anAppThatIsNotLeveledContributesNothing() {
        let injector = injector([("a", 50)])
        injector.handleStateChange(bundleID: "stranger", state: capturing)
        injector.handleBuffer(bundleID: "stranger", buffer: s16Buffer([(9000, 9000)]))

        var block = program(0, frames: 1)
        injector.mix(into: &block, frameCount: 1)
        #expect(samples(block) == [0, 0], "only leveled apps may reach the program")
    }

    @Test func aBufferBeforeItsCapturingTransitionIsDropped() {
        let injector = LeveledAppInjector(makeConverter: { _ in IdentityConverter() })
        injector.updateLeveled([("a", 80)])
        injector.setActive(true)
        // No `.capturing` yet ⇒ no converter ⇒ nothing to bank.
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(1000, 1000)]))
        #expect(injector.test_pendingSamples(for: "a") == 0)
    }

    // MARK: - 2. Clipping

    @Test func summedSamplesSaturateInsteadOfWrapping() {
        let injector = injector([("a", 100), ("b", 100)])
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(30_000, -30_000)]))
        injector.handleBuffer(bundleID: "b", buffer: s16Buffer([(30_000, -30_000)]))

        var block = program(0, frames: 1)
        injector.mix(into: &block, frameCount: 1)
        #expect(samples(block) == [32_767, -32_768], "a hard limiter, never a wrap into noise")
    }

    // MARK: - 3. Underrun

    @Test func aRingWithFewerFramesThanAskedContributesSilenceForTheRest() {
        let injector = injector([("a", 100)])
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(10, 10), (20, 20)]))

        var block = program(7, frames: 4)
        injector.mix(into: &block, frameCount: 4)
        #expect(samples(block) == [17, 17, 27, 27, 7, 7, 7, 7],
                "the frames the app could not fill must be left as the program alone")
    }

    @Test func aDrainedRingLeavesTheNextBlockUntouched() {
        let injector = injector([("a", 100)])
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(10, 10)]))

        var first = program(0, frames: 1)
        injector.mix(into: &first, frameCount: 1)
        var second = program(0, frames: 1)
        injector.mix(into: &second, frameCount: 1)

        #expect(samples(first) == [10, 10])
        #expect(samples(second) == [0, 0], "a frame is consumed once, never replayed")
    }

    // MARK: - 4. Ring cap

    @Test func aFullRingDropsItsOldestSamples() {
        let injector = injector([("a", 100)])
        let capacityFrames = LeveledAppInjector.ringCapacitySamples / 2
        injector.handleBuffer(
            bundleID: "a",
            buffer: s16Buffer(Array(repeating: (1, 1), count: capacityFrames)))
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(2, 2), (2, 2), (2, 2)]))

        #expect(injector.test_pendingSamples(for: "a") == LeveledAppInjector.ringCapacitySamples,
                "the ring is capped, so an overflowing writer can never grow it")

        var block = program(0, frames: capacityFrames)
        injector.mix(into: &block, frameCount: capacityFrames)
        let out = samples(block)
        #expect(out.count == capacityFrames * 2)
        #expect(Array(out.prefix(2)) == [1, 1], "three of the oldest frames went, not the newest")
        #expect(Array(out.suffix(6)) == [2, 2, 2, 2, 2, 2],
                "the freshest audio survives an overflow")
    }

    // MARK: - 5. The capture gate

    @Test func inactiveDropsBuffersAndClearsWhatWasBanked() {
        let injector = injector([("a", 100)])
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(10, 10)]))
        #expect(injector.test_pendingSamples(for: "a") == 2)

        injector.setActive(false)
        #expect(injector.test_pendingSamples(for: "a") == 0, "the flip empties every ring")

        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(10, 10)]))
        #expect(injector.test_pendingSamples(for: "a") == 0, "and nothing accumulates while inactive")

        injector.setActive(true)
        var block = program(0, frames: 1)
        injector.mix(into: &block, frameCount: 1)
        #expect(samples(block) == [0, 0], "audio captured while inactive never plays late")
    }

    @Test func mixIsInertWhileInactive() {
        let injector = injector([("a", 100)])
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(10, 10)]))
        injector.setActive(false)

        var block = program(5, frames: 1)
        injector.mix(into: &block, frameCount: 1)
        #expect(samples(block) == [5, 5])
    }

    @Test func aSameValueSetActiveKeepsThePendingAudio() {
        let injector = injector([("a", 100)])
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(10, 10)]))
        // A route edit mid-stream re-asserts the gate's current value; that must
        // not throw away audio that is about to play.
        injector.setActive(true)
        #expect(injector.test_pendingSamples(for: "a") == 2)
    }

    // MARK: - 6. Volume refresh

    @Test func updateLeveledRefreshesVolumeWithoutLosingTheApp() {
        let injector = injector([("a", 100)])
        injector.updateLeveled([("a", 25)])
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(1000, 1000)]))

        var block = program(0, frames: 1)
        injector.mix(into: &block, frameCount: 1)
        #expect(samples(block) == [250, 250])
    }

    @Test func setVolumeAppliesToTheNextBuffer() {
        let injector = injector([("a", 100)])
        injector.setVolume(50, for: "a")
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(1000, 1000)]))

        var block = program(0, frames: 1)
        injector.mix(into: &block, frameCount: 1)
        #expect(samples(block) == [500, 500])
    }

    @Test func setVolumeForAnUnknownBundleIsANoOp() {
        let injector = injector([("a", 100)])
        injector.setVolume(10, for: "stranger")
        injector.handleStateChange(bundleID: "stranger", state: capturing)
        injector.handleBuffer(bundleID: "stranger", buffer: s16Buffer([(1000, 1000)]))

        var block = program(0, frames: 1)
        injector.mix(into: &block, frameCount: 1)
        #expect(samples(block) == [0, 0], "a volume must never enrol an app into the leveled set")
    }

    // MARK: - 7. Metering

    @Test func preVolumeSourceRMSIsEmittedOnlyWhileMeteringIsActive() {
        let injector = injector([("a", 10)])
        let sink = LevelSink()
        injector.onAppLevel = { bundleID, rms in sink.append(bundleID, rms) }

        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(16_000, 16_000)]))
        #expect(sink.isEmpty, "no meter is shown, so nothing is measured")

        injector.setMeteringActive(true)
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(16_000, 16_000)]))

        let levels = sink.all
        #expect(levels.count == 1)
        #expect(levels.first?.bundleID == "a")
        // ~16000/32768 ≈ 0.49: the SOURCE level, not the 10%-attenuated output
        // (which would read ≈ 0.05).
        #expect((levels.first?.rms ?? 0) > 0.4,
                "the meter shows how loud the app plays, not how far its slider is down")
    }

    // MARK: - 8. Removal

    @Test func removingAnAppDropsItsRingAndConverter() {
        let injector = injector([("a", 50), ("b", 50)])
        injector.handleBuffer(bundleID: "a", buffer: s16Buffer([(1000, 1000)]))
        #expect(injector.test_hasRing(for: "a"))
        #expect(injector.test_hasConverter(for: "a"))

        injector.updateLeveled([("b", 50)])
        #expect(!injector.test_hasRing(for: "a"), "the ring goes with the app")
        #expect(!injector.test_hasConverter(for: "a"), "and so does its converter")
        #expect(injector.test_hasRing(for: "b"), "the app that stayed keeps both")
        #expect(injector.test_hasConverter(for: "b"))
    }

    @Test func leavingCapturingDropsTheConverter() {
        let injector = injector([("a", 50)])
        injector.handleStateChange(bundleID: "a", state: .idle)
        #expect(!injector.test_hasConverter(for: "a"))
        #expect(injector.test_hasRing(for: "a"),
                "the app is still leveled — only its format knowledge is gone")
    }
}
