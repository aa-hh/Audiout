// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import XCTest
@testable import AirPlayControllerCore

/// Hermetic tests for ``AppRouteMixer`` (T5). Every seam is injected — a
/// trivial ``PCMConverting`` (identity, no AVFoundation) — so the
/// destination-set topology AND the sample math run without Core Audio, a real
/// tap, or the engine. These are the highest-stakes tests in the routing plan:
/// a mixing bug is audible garbage.
final class AppRouteMixerTests: XCTestCase {

    // MARK: Doubles

    /// A converter that returns the buffer's first channel bytes verbatim as the
    /// "converted" S16LE PCM. Tests build ``CapturedBuffer``s already in S16LE
    /// stereo so the identity converter's output is exactly the test's input —
    /// keeping the sample-math assertions exact.
    private struct IdentityConverter: PCMConverting {
        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? {
            buffer.channelData.first
        }
    }

    /// Thread-safe collector for the `@Sendable` mixed-buffer callback.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [AppRouteMixer.MixedBuffer] = []
        func append(_ b: AppRouteMixer.MixedBuffer) { lock.lock(); buffers.append(b); lock.unlock() }
        var all: [AppRouteMixer.MixedBuffer] { lock.lock(); defer { lock.unlock() }; return buffers }
        var isEmpty: Bool { all.isEmpty }
        var combined: Data { all.reduce(Data()) { $0 + $1.pcm } }
    }

    /// Thread-safe counter for the `@Sendable` topology callback.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func mixer() -> AppRouteMixer {
        AppRouteMixer(makeConverter: { _ in IdentityConverter() })
    }

    /// Build an S16LE interleaved-stereo ``CapturedBuffer`` from L/R sample
    /// pairs, tagged at a whole-second pts (so its first frame lands on a clean
    /// frame index the tests can predict).
    private func s16Buffer(frames pairs: [(Int16, Int16)], atSecond sec: Int) -> CapturedBuffer {
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
        return CapturedBuffer(channelData: [data], frameCount: pairs.count,
                              pts: timespec(tv_sec: sec, tv_nsec: 0))
    }

    /// Decode interleaved S16LE `Data` back to L/R pairs for assertions.
    private func pairs(_ data: Data) -> [(Int16, Int16)] {
        var out: [(Int16, Int16)] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i + 3 < raw.count {
                let l = Int16(bitPattern: UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8))
                let r = Int16(bitPattern: UInt16(raw[i + 2]) | (UInt16(raw[i + 3]) << 8))
                out.append((l, r)); i += 4
            }
        }
        return out
    }

    private func route(_ bundle: String, to deviceID: String?, volume: Int = 100) -> AppRoute {
        AppRoute(bundleID: bundle, displayName: bundle,
                 destination: deviceID.map { .device(id: $0) } ?? .currentDevice,
                 volume: volume)
    }

    private func capturing(_ format: TapFormat = TapFormat(
        sampleRate: 44100, channels: 2, bitsPerSample: 16, isFloat: false, isInterleaved: true)
    ) -> PerAppCaptureCoordinator.State { .capturing(format) }

    // MARK: - 1. Destination-set computation

    func testDisjointRoutesProduceSeparateSets() {
        let m = mixer()
        m.updateRoutes([route("a", to: "dev1"), route("b", to: "dev2")])
        let sets = m.destinationSets
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(Set(sets.flatMap { $0.deviceIDs }), ["dev1", "dev2"])
        XCTAssertTrue(sets.allSatisfy { $0.bundleIDs.count == 1 && $0.deviceIDs.count == 1 })
    }

    /// `.noRedirect` and `.currentDevice` are mixer-equivalent: neither ever
    /// participates in a destination set, and neither gets a stream id.
    func testNoRedirectAndCurrentDeviceAreBothExcludedFromMixerTopology() {
        let m = mixer()
        m.updateRoutes([
            route("com.spotify.client", to: "kitchen"),
            AppRoute(bundleID: "us.zoom.xos", displayName: "Zoom", destination: .noRedirect),
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .currentDevice),
        ])
        let sets = m.destinationSets
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].bundleIDs, ["com.spotify.client"],
                       "neither .noRedirect nor .currentDevice ever joins a destination set")
        XCTAssertNil(m.streamID(for: "us.zoom.xos"))
        XCTAssertNil(m.streamID(for: "com.apple.Music"))
    }

    func testDevicesWithIdenticalMembershipShareOneStream() {
        let m = mixer()
        m.updateRoutes([
            route("a", to: "dev1"), route("b", to: "dev1"),
            route("a", to: "dev2"), route("b", to: "dev2"),
        ])
        let sets = m.destinationSets
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].bundleIDs, ["a", "b"])
        XCTAssertEqual(sets[0].deviceIDs, ["dev1", "dev2"])
    }

    func testOverlappingButUnequalMembershipStayDistinct() {
        let m = mixer()
        m.updateRoutes([
            route("a", to: "dev1"), route("b", to: "dev1"),
            route("b", to: "dev2"),
        ])
        let sets = m.destinationSets.sorted { $0.bundleIDs.count > $1.bundleIDs.count }
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets[0].bundleIDs, ["a", "b"])
        XCTAssertEqual(sets[0].deviceIDs, ["dev1"])
        XCTAssertEqual(sets[1].bundleIDs, ["b"])
        XCTAssertEqual(sets[1].deviceIDs, ["dev2"])
    }

    func testNoRoutesProducesZeroSets() {
        let m = mixer()
        m.updateRoutes([route("a", to: nil), route("b", to: nil)])
        XCTAssertTrue(m.destinationSets.isEmpty)
    }

    func testStreamIDsStartAtOne() {
        let m = mixer()
        m.updateRoutes([route("a", to: "dev1")])
        XCTAssertEqual(m.destinationSets.map { $0.streamID }, [1])
    }

    // MARK: - 2. Stream_id stability

    func testSameSignatureKeepsStreamIDAcrossRecompute() {
        let m = mixer()
        m.updateRoutes([route("a", to: "dev1"), route("b", to: "dev2")])
        let firstA = m.streamID(for: "a")
        let firstB = m.streamID(for: "b")

        m.updateRoutes([route("a", to: "dev1", volume: 50), route("b", to: "dev2")])
        XCTAssertEqual(m.streamID(for: "a"), firstA)
        XCTAssertEqual(m.streamID(for: "b"), firstB)
    }

    func testChangedMembershipGetsDifferentStreamID() {
        let m = mixer()
        m.updateRoutes([route("a", to: "dev1")])
        let original = m.streamID(for: "a")!

        m.updateRoutes([route("a", to: "dev1"), route("b", to: "dev1")])
        let changed = m.destinationSets.first { $0.bundleIDs == ["a", "b"] }!.streamID
        XCTAssertNotEqual(changed, original, "a new membership must not reuse the old set's id blindly")
        XCTAssertNil(m.destinationSets.first { $0.bundleIDs == ["a"] })
    }

    func testUnchangedSetKeepsIDWhenAnotherSetChanges() {
        let m = mixer()
        m.updateRoutes([route("a", to: "dev1"), route("b", to: "dev2")])
        let bID = m.destinationSets.first { $0.bundleIDs == ["b"] }!.streamID

        m.updateRoutes([route("a", to: "dev1"), route("c", to: "dev1"), route("b", to: "dev2")])
        let bIDAfter = m.destinationSets.first { $0.bundleIDs == ["b"] }!.streamID
        XCTAssertEqual(bID, bIDAfter, "an unrelated set must not be reassigned")
    }

    func testTopologyCallbackFiresOnlyOnRealChange() {
        let m = mixer()
        let count = Counter()
        m.onDestinationSetsChanged = { _ in count.bump() }

        m.updateRoutes([route("a", to: "dev1")])             // change -> fire
        m.updateRoutes([route("a", to: "dev1", volume: 20)]) // volume only -> no fire
        m.updateRoutes([route("a", to: "dev2")])             // device change -> fire
        XCTAssertEqual(count.value, 2)
    }

    // MARK: - 3. Summing correctness + clipping

    func testTwoAppsToSameDeviceSumSampleAccurately() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }

        m.updateRoutes([route("a", to: "dev1"), route("b", to: "dev1")])
        m.handleStateChange(bundleID: "a", state: capturing())
        m.handleStateChange(bundleID: "b", state: capturing())

        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(100, 200), (300, 400)], atSecond: 1))
        m.handleBuffer(bundleID: "b", buffer: s16Buffer(frames: [(10, 20), (30, 40)], atSecond: 1))
        m.flush()

        let all = pairs(sink.combined)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].0, 110); XCTAssertEqual(all[0].1, 220)
        XCTAssertEqual(all[1].0, 330); XCTAssertEqual(all[1].1, 440)
        XCTAssertTrue(sink.all.allSatisfy { $0.streamID == m.streamID(for: "a") })
    }

    func testClippingEngagesAtBoundaryWithoutWrapping() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }

        m.updateRoutes([route("a", to: "dev1"), route("b", to: "dev1")])
        m.handleStateChange(bundleID: "a", state: capturing())
        m.handleStateChange(bundleID: "b", state: capturing())

        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(30000, -30000)], atSecond: 1))
        m.handleBuffer(bundleID: "b", buffer: s16Buffer(frames: [(30000, -30000)], atSecond: 1))
        m.flush()

        let all = pairs(sink.combined)
        XCTAssertEqual(all[0].0, 32767, "positive overflow clamps to Int16.max")
        XCTAssertEqual(all[0].1, -32768, "negative overflow clamps to Int16.min")
    }

    func testStaticClipHelperBoundaries() {
        XCTAssertEqual(AppRouteMixer.clip(40000), 32767)
        XCTAssertEqual(AppRouteMixer.clip(-40000), -32768)
        XCTAssertEqual(AppRouteMixer.clip(0), 0)
        XCTAssertEqual(AppRouteMixer.clip(32767), 32767)
        XCTAssertEqual(AppRouteMixer.clip(-32768), -32768)
    }

    // MARK: - 4. Per-app volume scaling

    func testVolumeScalesAppContributionBeforeSumming() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }

        // a at 50% (1000 -> 500), b at 100% (2000). Sum = 2500.
        m.updateRoutes([route("a", to: "dev1", volume: 50), route("b", to: "dev1", volume: 100)])
        m.handleStateChange(bundleID: "a", state: capturing())
        m.handleStateChange(bundleID: "b", state: capturing())

        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(1000, 1000)], atSecond: 1))
        m.handleBuffer(bundleID: "b", buffer: s16Buffer(frames: [(2000, 2000)], atSecond: 1))
        m.flush()

        let all = pairs(sink.combined)
        XCTAssertEqual(all[0].0, 2500)
        XCTAssertEqual(all[0].1, 2500)
    }

    func testZeroVolumeContributesSilence() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }

        m.updateRoutes([route("a", to: "dev1", volume: 0), route("b", to: "dev1", volume: 100)])
        m.handleStateChange(bundleID: "a", state: capturing())
        m.handleStateChange(bundleID: "b", state: capturing())
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(9999, 9999)], atSecond: 1))
        m.handleBuffer(bundleID: "b", buffer: s16Buffer(frames: [(1234, 5678)], atSecond: 1))
        m.flush()

        let all = pairs(sink.combined)
        XCTAssertEqual(all[0].0, 1234, "muted app adds nothing")
        XCTAssertEqual(all[0].1, 5678)
    }

    func testStaticScaledSamplesRoundsToNearest() {
        var data = Data(count: 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let bits = UInt16(bitPattern: 3)
            raw[0] = UInt8(bits & 0xFF); raw[1] = UInt8(bits >> 8)
        }
        XCTAssertEqual(AppRouteMixer.scaledStereoSamples(data, volumePercent: 50), [2]) // 1.5 -> 2
        XCTAssertEqual(AppRouteMixer.scaledStereoSamples(data, volumePercent: 100), [3])
        XCTAssertEqual(AppRouteMixer.scaledStereoSamples(data, volumePercent: 0), [0])
    }

    // MARK: - 5. Composite plan scenario (Spotify -> Kitchen, Zoom local)

    func testSpotifyRoutedZoomLocalYieldsExactlyOneSetWithoutZoom() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }

        m.updateRoutes([
            route("com.spotify.client", to: "kitchen"),
            route("us.zoom.xos", to: nil),   // .currentDevice
        ])

        let sets = m.destinationSets
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].bundleIDs, ["com.spotify.client"])
        XCTAssertEqual(sets[0].deviceIDs, ["kitchen"])
        XCTAssertNil(m.streamID(for: "us.zoom.xos"))

        // Even a defensive Zoom buffer (never happens — no tap) produces nothing.
        m.handleStateChange(bundleID: "com.spotify.client", state: capturing())
        m.handleStateChange(bundleID: "us.zoom.xos", state: capturing())
        m.handleBuffer(bundleID: "us.zoom.xos", buffer: s16Buffer(frames: [(500, 500)], atSecond: 1))
        m.handleBuffer(bundleID: "com.spotify.client", buffer: s16Buffer(frames: [(500, 500)], atSecond: 1))
        m.flush()

        XCTAssertTrue(sink.all.allSatisfy { $0.streamID == sets[0].streamID })
        let all = pairs(sink.combined)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].0, 500)
        XCTAssertEqual(all[0].1, 500)
    }

    // MARK: - pts alignment + emission behaviour

    func testBuffersAtDifferentTimesLandAtCorrectFrameOffsets() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }

        m.updateRoutes([route("a", to: "dev1")])
        m.handleStateChange(bundleID: "a", state: capturing())

        // Two buffers a full second apart -> the second lands 44100 frames later,
        // so the flushed stream is 44101 frames long (1 + gap + 1).
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(111, 111)], atSecond: 1))
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(222, 222)], atSecond: 2))
        m.flush()

        let all = pairs(sink.combined)
        XCTAssertEqual(all.count, 44101)
        XCTAssertEqual(all.first!.0, 111)
        XCTAssertEqual(all[44100].0, 222)          // exactly one second later
        XCTAssertEqual(all[1].0, 0, "the gap between the two buffers is silence")
        XCTAssertEqual(sink.all.first!.pts.tv_sec, 1) // first emitted frame is at 1.0 s
    }

    func testNoOutputBeforeFlushWhenWithinHoldWindow() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }
        m.updateRoutes([route("a", to: "dev1")])
        m.handleStateChange(bundleID: "a", state: capturing())

        // A single tiny buffer (< holdFrames) is held, not emitted, until flush.
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(1, 1), (2, 2)], atSecond: 1))
        XCTAssertTrue(sink.isEmpty, "frames within the hold window aren't final yet")
        m.flush()
        XCTAssertEqual(pairs(sink.combined).count, 2)
    }

    func testFrameIndexRoundTrips() {
        let ts = timespec(tv_sec: 3, tv_nsec: 500_000_000)
        let frame = AppRouteMixer.frameIndex(of: ts)
        XCTAssertEqual(frame, Int64(3 * 44100 + 22050))
        let back = AppRouteMixer.timestamp(ofFrame: frame)
        XCTAssertEqual(back.tv_sec, 3)
        XCTAssertEqual(back.tv_nsec, 500_000_000, accuracy: 30_000) // sub-frame rounding
    }

    // MARK: - Robustness: no converter / not routed

    func testBufferDroppedWhenNoConverterYet() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }
        m.updateRoutes([route("a", to: "dev1")])
        // No handleStateChange(.capturing) -> no converter learned yet.
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(1, 1)], atSecond: 1))
        m.flush()
        XCTAssertTrue(sink.isEmpty, "a buffer before format is known is dropped, not crashed")
    }

    func testStopClearsConverterSoLaterBuffersDrop() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }
        m.updateRoutes([route("a", to: "dev1")])
        m.handleStateChange(bundleID: "a", state: capturing())
        m.handleStateChange(bundleID: "a", state: .idle)   // stopped
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(7, 7)], atSecond: 1))
        m.flush()
        XCTAssertTrue(sink.isEmpty)
    }
}
