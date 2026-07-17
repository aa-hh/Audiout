import XCTest
@testable import AirPlayControllerCore

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Hermetic tests for ``NativeCaptureCoordinator`` (T-NB-CAPTURE-1). Every seam is
/// injected — a fake ``SystemAudioTap`` (no TCC, no aggregate device), a spy
/// ``PCMSink`` (records forwarded buffers + their pts), and a fake
/// ``PCMConverting`` — so the whole state machine runs with NO real tap, engine,
/// or Core Audio object.
///
/// Covers the plan-required path: create → buffers with advancing `mHostTime` →
/// converted → forwarded → device-change → stop → error surfaced. Plus a focused
/// pts-clock-domain test that would have caught the mHostTime-vs-CLOCK_MONOTONIC
/// bug (finding 2).
final class NativeCaptureCoordinatorTests: XCTestCase {

    // MARK: Doubles

    /// A tap the test drives directly: `createAndStart` returns a scripted format
    /// (or throws a scripted error), and `pushBuffer`/`fireDeviceChange` inject the
    /// IOProc-thread callbacks. Records teardown so the leak fix is observable.
    private final class FakeTap: SystemAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?

        let lock = NSLock()
        var format = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        var startError: NativeCaptureError?
        private(set) var createCount = 0
        private(set) var teardownCount = 0
        private(set) var started = false

        func createAndStart(muteBehavior: TapMuteBehavior) throws -> TapFormat {
            lock.lock(); createCount += 1; lock.unlock()
            if let startError { throw startError }
            lock.lock(); started = true; lock.unlock()
            return format
        }

        func teardown() {
            lock.lock(); teardownCount += 1; started = false; lock.unlock()
        }

        func pushBuffer(_ b: CapturedBuffer) { onBuffer?(b) }
        func fireDeviceChange() { onDefaultDeviceChanged?() }

        var teardowns: Int { lock.withLock { teardownCount } }
        var creates: Int { lock.withLock { createCount } }
    }

    /// Records every forwarded (pcm, pts) pair.
    private final class SpySink: PCMSink, @unchecked Sendable {
        let lock = NSLock()
        private(set) var writes: [(pcm: Data, pts: timespec)] = []
        func write(pcm: Data, pts: timespec) { lock.withLock { writes.append((pcm, pts)) } }
        var forwarded: [(pcm: Data, pts: timespec)] { lock.withLock { writes } }
    }

    /// Deterministic converter: emits a fixed non-empty S16LE payload per buffer so
    /// the test can assert "converted-and-forwarded" without AVFoundation, and can
    /// be scripted to drop (return nil) a buffer.
    private final class FakeConverter: PCMConverting, @unchecked Sendable {
        let lock = NSLock()
        var dropAll = false
        private(set) var convertCount = 0
        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? {
            lock.withLock { convertCount += 1 }
            if lock.withLock({ dropAll }) { return nil }
            // 4 interleaved S16LE stereo frames = 16 bytes.
            return Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00,
                         0x05, 0x00, 0x06, 0x00, 0x07, 0x00, 0x08, 0x00])
        }
        var converts: Int { lock.withLock { convertCount } }
    }

    // MARK: Helpers

    private func makeCoordinator(
        tap: FakeTap,
        sink: SpySink,
        converter: FakeConverter
    ) -> NativeCaptureCoordinator {
        NativeCaptureCoordinator(
            makeTap: { tap },
            sink: sink,
            makeConverter: { _ in converter },
            muteBehavior: .mutedWhenTapped
        )
    }

    private func buffer(hostTime: UInt64, frames: Int = 4) -> CapturedBuffer {
        // planar stereo Float32: two channel buffers, `frames` samples each.
        let bytesPerChannel = frames * MemoryLayout<Float32>.size
        let ch = Data(count: bytesPerChannel)
        let pts = timespec(tv_sec: Int(hostTime / 1_000_000_000), tv_nsec: Int(hostTime % 1_000_000_000))
        return CapturedBuffer(channelData: [ch, ch], frameCount: frames, pts: pts)
    }

    private func waitFor(timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    // MARK: - Full lifecycle: create → convert+forward → device-change → stop.

    func testCreateBuffersConvertForwardDeviceChangeStop() {
        let tap = FakeTap()
        let sink = SpySink()
        let converter = FakeConverter()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: converter)

        // 1) create
        coordinator.start()
        XCTAssertEqual(coordinator.state, .capturing(tap.format))
        XCTAssertEqual(tap.creates, 1)

        // 2) buffers with ADVANCING mHostTime are converted and forwarded, pts intact.
        tap.pushBuffer(buffer(hostTime: 1_000_000_000))
        tap.pushBuffer(buffer(hostTime: 2_000_000_000))
        waitFor { sink.forwarded.count == 2 }
        XCTAssertEqual(sink.forwarded.count, 2, "each converted buffer is forwarded to the sink")
        XCTAssertEqual(converter.converts, 2)
        // The pts the coordinator forwards is the buffer's own capture-clock pts.
        XCTAssertEqual(sink.forwarded[0].pts.tv_sec, 1)
        XCTAssertEqual(sink.forwarded[1].pts.tv_sec, 2)
        XCTAssertGreaterThan(
            timespecToNanos(sink.forwarded[1].pts), timespecToNanos(sink.forwarded[0].pts),
            "pts must advance with the capture clock")

        // 3) default-output-device change recreates the tap against the new format.
        tap.format = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()
        waitFor { self.stateIsCapturing(coordinator, sampleRate: 44100) }
        XCTAssertEqual(coordinator.state, .capturing(tap.format))
        XCTAssertGreaterThanOrEqual(tap.teardowns, 1, "the old tap is torn down on device change")
        XCTAssertEqual(tap.creates, 2, "a fresh tap is created for the new device")

        // 4) stop tears the tap down and returns to idle.
        coordinator.stop()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertGreaterThanOrEqual(tap.teardowns, 2)
    }

    // MARK: - A dropped (nil) conversion is not forwarded.

    func testDroppedConversionIsNotForwarded() {
        let tap = FakeTap()
        let sink = SpySink()
        let converter = FakeConverter()
        converter.dropAll = true
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: converter)

        coordinator.start()
        tap.pushBuffer(buffer(hostTime: 1_000_000_000))
        // Give the delivery a beat; nothing should be forwarded.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(sink.forwarded.isEmpty, "a nil conversion must be dropped, not forwarded")
        coordinator.stop()
    }

    // MARK: - Tap-creation failure surfaces as .failed AND tears the tap down.

    func testTapCreationFailureSurfacesErrorAndTearsDown() {
        let tap = FakeTap()
        tap.startError = .tapCreationFailed(reason: "denied")
        let sink = SpySink()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: FakeConverter())

        coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.tapCreationFailed(reason: "denied")))
        // Finding 3: a failed createAndStart must not leak the tap — teardown is called.
        XCTAssertGreaterThanOrEqual(tap.teardowns, 1, "a failed start must tear the tap down (no leak)")
    }

    // MARK: - UnavailableSystemTap (macOS < 14.2) surfaces .osUnsupported, not
    // .tapCreationFailed — the userMessage must not carry permission advice for
    // a version-gate failure.

    #if canImport(AudioToolbox)
    func testUnavailableSystemTapSurfacesOSUnsupported() {
        let tap = UnavailableSystemTap()
        XCTAssertThrowsError(try tap.createAndStart(muteBehavior: .mutedWhenTapped)) { error in
            XCTAssertEqual(error as? NativeCaptureError, .osUnsupported(minimum: "14.2"))
        }
    }

    func testOSUnsupportedUserMessageHasNoPermissionAdvice() {
        let message = NativeCaptureError.osUnsupported(minimum: "14.2").userMessage
        XCTAssertTrue(message.contains("14.2"), "message should state the version requirement")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("permission"),
            "an OS-version failure is not fixable by granting permission")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("System Settings"),
            "an OS-version failure should not send the user to the TCC panel")
    }

    func testUnavailableSystemTapDrivenThroughCoordinatorSurfacesOSUnsupported() {
        // Route the real UnavailableSystemTap through the coordinator's start
        // sequence (not just a scripted FakeTap) so the case flows end-to-end.
        let sink = SpySink()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { UnavailableSystemTap() },
            sink: sink,
            makeConverter: { _ in FakeConverter() },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start()
        XCTAssertEqual(coordinator.state, .failed(.osUnsupported(minimum: "14.2")))
    }
    #endif

    // MARK: - Device-change recreation failure surfaces as .failed.

    func testDeviceChangeRecreationFailureSurfacesError() {
        let tap = FakeTap()
        let sink = SpySink()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: FakeConverter())

        coordinator.start()
        XCTAssertEqual(coordinator.state, .capturing(tap.format))

        // Next createAndStart (the recreation) fails.
        tap.startError = .deviceLost(reason: "gone")
        tap.fireDeviceChange()
        waitFor { if case .failed = coordinator.state { return true } else { return false } }
        XCTAssertEqual(coordinator.state, .failed(.deviceLost(reason: "gone")))
    }

    // MARK: - Idempotency: start() while capturing is a no-op; stop() from idle is a no-op.

    func testStartIsIdempotentAndStopFromIdleIsNoOp() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.stop()  // idle → no-op
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(tap.creates, 0)

        coordinator.start()
        coordinator.start()  // already capturing → no second tap
        XCTAssertEqual(tap.creates, 1)
        coordinator.stop()
    }

    // MARK: - pts clock domain (finding 2): mHostTime must map onto CLOCK_MONOTONIC.

    #if canImport(AudioToolbox)
    /// The real pts derivation (`CoreAudioSystemTap.timespec(fromHostTime:)`) must
    /// land on the CLOCK_MONOTONIC timescale the engine consumes it on — NOT the
    /// raw mach-absolute timescale, which trails CLOCK_MONOTONIC by the machine's
    /// accumulated sleep and made every sync packet advertise a position receding
    /// into the past (Sonos green-never-white, no audio).
    @available(macOS 14.2, *)
    func testHostTimeMapsOntoClockMonotonic() {
        // Convert "now" (mach_absolute_time) and compare against a CLOCK_MONOTONIC
        // reading taken at the same instant. On a box that has ever slept, a raw
        // mach-time conversion would be off by the total sleep (millions of
        // seconds); the rebased conversion must agree with CLOCK_MONOTONIC to well
        // under a second.
        let host = mach_absolute_time()
        let pts = CoreAudioSystemTap.timespec(fromHostTime: host)

        var mono = timespec()
        clock_gettime(CLOCK_MONOTONIC, &mono)

        let ptsNanos = timespecToNanos(pts)
        let monoNanos = timespecToNanos(mono)
        let deltaNanos = abs(Int64(ptsNanos) - Int64(monoNanos))
        XCTAssertLessThan(deltaNanos, 1_000_000_000,
            "pts must be on the CLOCK_MONOTONIC timescale (within 1s of it), not raw mach-absolute time")
    }

    /// The conversion is monotonic and linear in the host time: two host times a
    /// known delta apart map to pts the same delta apart.
    @available(macOS 14.2, *)
    func testHostTimeConversionPreservesDeltas() {
        let base = mach_absolute_time()
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        // Add 500ms worth of mach ticks.
        let halfSecondTicks = UInt64(500_000_000) * UInt64(max(1, tb.denom)) / UInt64(max(1, tb.numer))
        let a = CoreAudioSystemTap.timespec(fromHostTime: base)
        let b = CoreAudioSystemTap.timespec(fromHostTime: base &+ halfSecondTicks)
        let delta = Int64(timespecToNanos(b)) - Int64(timespecToNanos(a))
        XCTAssertEqual(Double(delta), 500_000_000, accuracy: 2_000_000,
            "a 500ms host-time delta must map to ~500ms of pts")
    }
    #endif

    // MARK: - RMS metering (pure).

    func testRMSOfS16LE() {
        XCTAssertEqual(NativeCaptureCoordinator.rmsOfS16LE(Data()), 0)
        // A constant full-scale signal → RMS ~1.0.
        var full = Data()
        for _ in 0..<64 { withUnsafeBytes(of: Int16(32767).littleEndian) { full.append(contentsOf: $0) } }
        XCTAssertEqual(NativeCaptureCoordinator.rmsOfS16LE(full), 1.0, accuracy: 0.01)
    }

    // MARK: - utils

    private func timespecToNanos(_ ts: timespec) -> UInt64 {
        UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    private func stateIsCapturing(_ c: NativeCaptureCoordinator, sampleRate: Int) -> Bool {
        if case .capturing(let f) = c.state { return f.sampleRate == sampleRate }
        return false
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
