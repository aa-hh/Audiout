// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import XCTest
@testable import AudioutedCore

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

    /// Build an S16LE interleaved-stereo ``CapturedBuffer`` of `count` identical
    /// `(value, value)` frames whose first frame lands at the ABSOLUTE output
    /// frame index `frame` (pts = ``AppRouteMixer/timestamp(ofFrame:)``). Lets a
    /// test place a buffer at a precise sub-second frame offset — the realistic
    /// case two independently-clocked taps produce (unlike the whole-second
    /// helper above, whose buffers always align exactly on a 44100-frame grid).
    private func s16BufferAtFrame(value: Int16, count: Int, atFrame frame: Int64) -> CapturedBuffer {
        let buf = s16Buffer(frames: Array(repeating: (value, value), count: count), atSecond: 0)
        return CapturedBuffer(channelData: buf.channelData, frameCount: count,
                              pts: AppRouteMixer.timestamp(ofFrame: frame))
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

    /// Regression for Bug T1 ("two apps routed -> audio extremely compressed or
    /// slowed down"). Two apps sharing one stream deliver 500-frame buffers
    /// covering the SAME real-time ranges, interleaved so app "a" always drains a
    /// stream's head (advancing `startFrame` past the 441-frame hold window)
    /// before app "b" delivers its contribution for that same range. The mixer
    /// MUST NOT re-emit already-sent frames at a rewound pts: doing so
    /// over-delivers frames (playback slows) and hands the receiver overlapping
    /// RTP timestamps (audible corruption). A single stream driven by real time
    /// must emit exactly one real-time's worth of frames with contiguous,
    /// never-rewound presentation timestamps.
    func testTwoInterleavedAppsNeitherOverDeliverNorRewindPTS() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }

        m.updateRoutes([route("a", to: "dev1"), route("b", to: "dev1")])
        m.handleStateChange(bundleID: "a", state: capturing())
        m.handleStateChange(bundleID: "b", state: capturing())

        let bufFrames = 500                   // > holdFrames (441): each buffer drains a head
        let stride = Int64(bufFrames)
        let start: Int64 = 44_100
        let iterations = 10
        var frame = start
        for _ in 0..<iterations {
            // "a" arrives first and drains; "b" then contributes the same range.
            m.handleBuffer(bundleID: "a", buffer: s16BufferAtFrame(value: 100, count: bufFrames, atFrame: frame))
            m.handleBuffer(bundleID: "b", buffer: s16BufferAtFrame(value: 10, count: bufFrames, atFrame: frame))
            frame += stride
        }
        m.flush()

        // 1. Presentation timestamps must be contiguous and strictly forward —
        //    no emission may start before the previous one ended (that is the
        //    duplicate/rewound-pts corruption).
        var expectedNextFrame: Int64?
        for emitted in sink.all {
            let startFrame = AppRouteMixer.frameIndex(of: emitted.pts)
            if let expected = expectedNextFrame {
                XCTAssertEqual(startFrame, expected,
                               "emissions must be contiguous; a rewound/overlapping pts is receiver corruption")
            }
            expectedNextFrame = startFrame + Int64(emitted.frameCount)
        }

        // 2. Exactly one real-time span of frames (no over-delivery == no slow-down).
        let totalEmitted = sink.all.reduce(0) { $0 + $1.frameCount }
        let realSpan = Int(frame - start)     // iterations * bufFrames
        XCTAssertEqual(totalEmitted, realSpan,
                       "two mixed apps must emit exactly one real-time's worth of frames, not more")
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

    func testSingleStreamPassesBuffersThroughVerbatimWithOwnPTS() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }

        m.updateRoutes([route("a", to: "dev1")])
        m.handleStateChange(bundleID: "a", state: capturing())

        // A single-contributor stream passes each converted buffer STRAIGHT
        // through with its own capture pts — no wall-clock re-gridding, so NO
        // synthetic silence gap between buffers (that re-gridding was the
        // drift/warble bug). Two buffers a second apart yield two separate
        // one-frame emissions, each keeping its own pts — NOT a 44101-frame
        // gap-filled stream.
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(111, 111)], atSecond: 1))
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(222, 222)], atSecond: 2))

        XCTAssertEqual(sink.all.count, 2, "each buffer passes straight through")
        XCTAssertEqual(pairs(sink.all[0].pcm).map(\.0), [111])
        XCTAssertEqual(pairs(sink.all[1].pcm).map(\.0), [222])
        XCTAssertEqual(sink.all[0].pts.tv_sec, 1, "buffer keeps its own capture pts")
        XCTAssertEqual(sink.all[1].pts.tv_sec, 2)
        XCTAssertEqual(pairs(sink.combined).count, 2, "no synthetic silence gap")
    }

    func testSingleStreamEmitsImmediatelyWithNoHoldWindow() {
        let m = mixer()
        let sink = Sink()
        m.onMixedBuffer = { sink.append($0) }
        m.updateRoutes([route("a", to: "dev1")])
        m.handleStateChange(bundleID: "a", state: capturing())

        // Pass-through: a single-contributor stream emits each buffer IMMEDIATELY
        // — the hold window only applies to the 2+-app summing path, so the
        // common single-redirect case carries no added latency.
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(1, 1), (2, 2)], atSecond: 1))
        XCTAssertEqual(pairs(sink.combined).count, 2, "single-stream buffer emits immediately")
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

    // MARK: - 6. Per-app POST-volume metering (T2)

    /// Single-contributor helper: routes "a" alone to "dev1" at `volume`,
    /// feeds one fixed buffer, and returns the RMS reported to `onAppLevel`.
    /// `setMeteringActive` is submitted to the mixer's serial queue before
    /// `handleBuffer` is (both from this same thread), so by FIFO ordering on
    /// that serial queue the flag is guaranteed live before the buffer lands.
    private func singleContributorLevel(forVolume volume: Int) -> Float {
        let m = mixer()
        let levels = LevelSink()
        m.onAppLevel = { levels.append($0, $1) }
        m.setMeteringActive(true)

        m.updateRoutes([route("a", to: "dev1", volume: volume)])
        m.handleStateChange(bundleID: "a", state: capturing())
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(16000, -16000), (12000, -12000)], atSecond: 1))

        return levels.all.last!.rms
    }

    func testMeteringOnFiresPlausibleSourceRMSForSingleContributor() {
        let level = singleContributorLevel(forVolume: 100)
        XCTAssertGreaterThan(level, 0, "a non-silent buffer must report a non-zero RMS")
        XCTAssertLessThanOrEqual(level, 1.0, "RMS is normalized to 0...1")
    }

    /// Proves the reported level is a SOURCE/program level (PRE-volume): the app's
    /// routing-volume slider must NOT change it, so a low slider can't leave the
    /// bar stuck near-empty while the source is loud (Alec's meter feedback).
    func testMeteringReportsSourceLevelIndependentOfRoutingVolume() {
        let fullVolume = singleContributorLevel(forVolume: 100)
        let halfVolume = singleContributorLevel(forVolume: 50)
        let mutedVolume = singleContributorLevel(forVolume: 0)

        XCTAssertEqual(halfVolume, fullVolume, accuracy: 0.0001,
            "halving the routing volume must NOT change the reported source RMS")
        XCTAssertEqual(mutedVolume, fullVolume, accuracy: 0.0001,
            "even a 0% routing volume still reports the app's true source level")
    }

    func testMeteringOffNeverFiresAppLevel() {
        let m = mixer()
        let levels = LevelSink()
        m.onAppLevel = { levels.append($0, $1) }
        // Metering defaults to off; setMeteringActive is never called.
        m.updateRoutes([route("a", to: "dev1")])
        m.handleStateChange(bundleID: "a", state: capturing())
        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(16000, 16000)], atSecond: 1))
        m.flush()
        XCTAssertTrue(levels.isEmpty, "onAppLevel must not fire while metering is inactive (default state)")
    }

    /// Two apps sharing one device's stream (the multi-contributor path) must each
    /// report THEIR OWN source RMS, not a value derived from the summed mix -- a
    /// loud "a" and a quiet "b" (distinct source buffers) must yield distinct
    /// levels keyed to their own bundle IDs.
    func testMeteringOnMultiContributorFiresPerAppNotMixedSum() {
        let m = mixer()
        let levels = LevelSink()
        m.onAppLevel = { levels.append($0, $1) }
        m.setMeteringActive(true)

        m.updateRoutes([route("a", to: "dev1", volume: 100), route("b", to: "dev1", volume: 100)])
        m.handleStateChange(bundleID: "a", state: capturing())
        m.handleStateChange(bundleID: "b", state: capturing())

        m.handleBuffer(bundleID: "a", buffer: s16Buffer(frames: [(20000, 20000)], atSecond: 1))
        m.handleBuffer(bundleID: "b", buffer: s16Buffer(frames: [(1000, 1000)], atSecond: 1))

        let recorded = levels.all
        XCTAssertEqual(recorded.count, 2, "each app's own buffer must fire its own onAppLevel call")
        let aLevel = recorded.first { $0.bundleID == "a" }!.rms
        let bLevel = recorded.first { $0.bundleID == "b" }!.rms
        XCTAssertGreaterThan(aLevel, bLevel,
            "the louder app's OWN source RMS must be reported per bundle ID -- if levels came from " +
            "the summed accumulator instead of each app's own buffer, both would report the same value")
    }
}
