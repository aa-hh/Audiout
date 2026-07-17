import XCTest
@testable import AirPlayControllerCore

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Hermetic tests for ``PerAppCaptureCoordinator`` (T3). Every seam is
/// injected — a fake ``ProcessAudioTap`` factory (no TCC, no aggregate
/// device, no real Core Audio) and a scripted `resolvePID` closure (no
/// `NSRunningApplication`) — so the whole per-bundle-ID state machine runs
/// hermetically. Mirrors ``NativeCaptureCoordinatorTests``' doubles/pattern.
final class PerAppCaptureCoordinatorTests: XCTestCase {

    // MARK: Doubles

    /// A tap the test drives directly: `createAndStart` returns a scripted
    /// format (or throws a scripted error), and `pushBuffer`/`fireDeviceChange`
    /// inject the IOProc-thread callbacks. Records the pid/bundleID it was
    /// started with and teardown calls, so leaks and cross-app bleed are
    /// observable.
    private final class FakeProcessTap: ProcessAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?

        let lock = NSLock()
        var format = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        var startError: PerAppCaptureError?
        private(set) var createCount = 0
        private(set) var teardownCount = 0
        private(set) var lastPid: pid_t?
        private(set) var lastBundleID: String?

        func createAndStart(pid: pid_t, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            lock.lock(); createCount += 1; lastPid = pid; lastBundleID = bundleID; lock.unlock()
            if let startError { throw startError }
            return format
        }

        func teardown() {
            lock.lock(); teardownCount += 1; lock.unlock()
        }

        func pushBuffer(_ b: CapturedBuffer) { onBuffer?(b) }
        func fireDeviceChange() { onDefaultDeviceChanged?() }

        var teardowns: Int { lock.withLock { teardownCount } }
        var creates: Int { lock.withLock { createCount } }
    }

    /// Records every (bundleID, buffer) delivery.
    private final class BufferSpy: @unchecked Sendable {
        let lock = NSLock()
        private(set) var deliveries: [(bundleID: String, frameCount: Int)] = []
        func record(_ bundleID: String, _ buffer: CapturedBuffer) {
            lock.withLock { deliveries.append((bundleID, buffer.frameCount)) }
        }
        var all: [(bundleID: String, frameCount: Int)] { lock.withLock { deliveries } }
    }

    // MARK: Helpers

    private func buffer(hostTime: UInt64, frames: Int = 4) -> CapturedBuffer {
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

    // MARK: - Single bundle ID: start -> buffers forwarded (tagged) -> stop -> clean teardown.

    func testStartForwardsTaggedBuffersThenStopTearsDownAndClearsState() {
        let tap = FakeProcessTap()
        let spy = BufferSpy()
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in 4242 },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.onBuffer = { bundleID, buffer in spy.record(bundleID, buffer) }

        coordinator.start(bundleID: "com.example.music")
        waitFor { coordinator.state(for: "com.example.music") == .capturing(tap.format) }
        XCTAssertEqual(coordinator.state(for: "com.example.music"), .capturing(tap.format))
        XCTAssertEqual(tap.creates, 1)
        XCTAssertEqual(tap.lastPid, 4242)
        XCTAssertEqual(tap.lastBundleID, "com.example.music")
        XCTAssertEqual(coordinator.capturingBundleIDs, ["com.example.music"])

        tap.pushBuffer(buffer(hostTime: 1_000_000_000))
        tap.pushBuffer(buffer(hostTime: 2_000_000_000))
        waitFor { spy.all.count == 2 }
        XCTAssertEqual(spy.all.count, 2)
        XCTAssertTrue(spy.all.allSatisfy { $0.bundleID == "com.example.music" })

        coordinator.stop(bundleID: "com.example.music")
        XCTAssertEqual(coordinator.state(for: "com.example.music"), .idle)
        XCTAssertGreaterThanOrEqual(tap.teardowns, 1)
        XCTAssertTrue(coordinator.capturingBundleIDs.isEmpty)

        // stop() removes the slot entirely (clean teardown, no leaked state) —
        // a bundle ID that was never started reports .idle identically to one
        // that was started then fully stopped.
        XCTAssertEqual(coordinator.state(for: "com.example.never-started"), .idle)
    }

    // MARK: - Multiple bundle IDs coexist independently: separate taps, no cross-talk.
    //
    // Each start(bundleID:) call gets its own fresh tap instance in
    // production (`makeTap` is invoked once per call); the test factory below
    // records instances in call order so each app's buffers/teardown are
    // asserted against ITS OWN fake, not a shared one.

    func testIndependentTapsPerBundleIDCoexistWithoutCrossTalk() {
        final class KeyedFactory: @unchecked Sendable {
            let lock = NSLock()
            var byInsertionOrder: [FakeProcessTap] = []
            func make() -> FakeProcessTap {
                let t = FakeProcessTap()
                lock.withLock { byInsertionOrder.append(t) }
                return t
            }
        }
        let factory = KeyedFactory()
        let spy = BufferSpy()

        let coordinator = PerAppCaptureCoordinator(
            makeTap: { factory.make() },
            resolvePID: { bundleID in bundleID == "com.example.a" ? 111 : 222 },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.onBuffer = { bundleID, buffer in spy.record(bundleID, buffer) }

        coordinator.start(bundleID: "com.example.a")
        waitFor { if case .capturing = coordinator.state(for: "com.example.a") { return true }; return false }
        coordinator.start(bundleID: "com.example.b")
        waitFor { if case .capturing = coordinator.state(for: "com.example.b") { return true }; return false }

        XCTAssertEqual(factory.byInsertionOrder.count, 2)
        let tapA = factory.byInsertionOrder[0]
        let tapB = factory.byInsertionOrder[1]
        XCTAssertEqual(tapA.lastPid, 111)
        XCTAssertEqual(tapB.lastPid, 222)

        tapA.pushBuffer(buffer(hostTime: 1_000_000_000, frames: 4))
        tapB.pushBuffer(buffer(hostTime: 1_000_000_000, frames: 8))
        waitFor { spy.all.count == 2 }

        let byBundle = Dictionary(uniqueKeysWithValues: spy.all.map { ($0.bundleID, $0.frameCount) })
        XCTAssertEqual(byBundle["com.example.a"], 4)
        XCTAssertEqual(byBundle["com.example.b"], 8)

        // Stopping A tears down ONLY A's tap.
        coordinator.stop(bundleID: "com.example.a")
        XCTAssertGreaterThanOrEqual(tapA.teardowns, 1)
        XCTAssertEqual(tapB.teardowns, 0)
        waitFor { if case .capturing = coordinator.state(for: "com.example.b") { return true }; return false }

        coordinator.stopAll()
        XCTAssertGreaterThanOrEqual(tapB.teardowns, 1)
    }

    // MARK: - resolvePID failure surfaces as .failed(.appNotRunning), retryable.

    func testUnresolvedBundleIDSurfacesAppNotRunning() {
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { FakeProcessTap() },
            resolvePID: { _ in nil },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.missing")
        waitFor {
            if case .failed(.appNotRunning) = coordinator.state(for: "com.example.missing") { return true }
            return false
        }
        XCTAssertEqual(coordinator.state(for: "com.example.missing"),
                       .failed(.appNotRunning(bundleID: "com.example.missing")))
        XCTAssertTrue(PerAppCaptureError.appNotRunning(bundleID: "x").isRetryable)
    }

    // MARK: - Tap-creation failure (e.g. processNotYetAudible) surfaces as .failed AND tears down.

    func testProcessNotYetAudibleSurfacesErrorAndTearsDown() {
        let tap = FakeProcessTap()
        tap.startError = .processNotYetAudible(bundleID: "com.example.silent")
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in 999 },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.silent")
        waitFor {
            if case .failed = coordinator.state(for: "com.example.silent") { return true }
            return false
        }
        XCTAssertEqual(coordinator.state(for: "com.example.silent"),
                       .failed(.processNotYetAudible(bundleID: "com.example.silent")))
        XCTAssertGreaterThanOrEqual(tap.teardowns, 1, "a failed start must tear the tap down (no leak)")
        XCTAssertTrue(PerAppCaptureError.processNotYetAudible(bundleID: "x").isRetryable)

        // Retry: start() from .failed resets and retries.
        tap.startError = nil
        coordinator.start(bundleID: "com.example.silent")
        waitFor { if case .capturing = coordinator.state(for: "com.example.silent") { return true }; return false }
        XCTAssertEqual(coordinator.state(for: "com.example.silent"), .capturing(tap.format))
    }

    // MARK: - UnavailableProcessTap (macOS < 14.2) surfaces .osUnsupported, not retryable.

    #if canImport(AudioToolbox)
    func testUnavailableProcessTapSurfacesOSUnsupported() {
        let tap = UnavailableProcessTap()
        XCTAssertThrowsError(try tap.createAndStart(pid: 1, bundleID: "com.example.old", muteBehavior: .mutedWhenTapped)) { error in
            XCTAssertEqual(error as? PerAppCaptureError, .osUnsupported(minimum: "14.2"))
        }
        XCTAssertFalse(PerAppCaptureError.osUnsupported(minimum: "14.2").isRetryable)
    }

    func testUnavailableProcessTapDrivenThroughCoordinatorSurfacesOSUnsupported() {
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { UnavailableProcessTap() },
            resolvePID: { _ in 1 },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.old")
        waitFor {
            if case .failed(.osUnsupported) = coordinator.state(for: "com.example.old") { return true }
            return false
        }
        XCTAssertEqual(coordinator.state(for: "com.example.old"), .failed(.osUnsupported(minimum: "14.2")))
    }
    #endif

    // MARK: - Default-device change recreates the tap, re-resolving the pid.

    func testDeviceChangeRecreatesTapAndReResolvesPID() {
        final class PidBox: @unchecked Sendable {
            let lock = NSLock()
            private var value: pid_t
            init(_ value: pid_t) { self.value = value }
            func get() -> pid_t { lock.withLock { value } }
            func set(_ newValue: pid_t) { lock.withLock { value = newValue } }
        }
        let tap = FakeProcessTap()
        let resolvedPid = PidBox(500)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in resolvedPid.get() },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        XCTAssertEqual(tap.lastPid, 500)

        // The app relaunched with a new pid before the device change fired.
        resolvedPid.set(501)
        tap.format = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()
        waitFor {
            if case .capturing(let f) = coordinator.state(for: "com.example.music") { return f.sampleRate == 44100 }
            return false
        }
        XCTAssertEqual(tap.lastPid, 501, "device-change recreation re-resolves the pid")
        XCTAssertGreaterThanOrEqual(tap.teardowns, 1, "the old tap is torn down on device change")
        XCTAssertGreaterThanOrEqual(tap.creates, 2)

        coordinator.stop(bundleID: "com.example.music")
    }

    // MARK: - Idempotency: start() while capturing is a no-op; stop() on unstarted bundle ID is a no-op.

    func testStartIsIdempotentAndStopOnUnstartedBundleIDIsNoOp() {
        let tap = FakeProcessTap()
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in 1 },
            muteBehavior: .mutedWhenTapped
        )

        coordinator.stop(bundleID: "com.example.never")
        XCTAssertEqual(coordinator.state(for: "com.example.never"), .idle)
        XCTAssertEqual(tap.creates, 0)

        coordinator.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        coordinator.start(bundleID: "com.example.music") // already capturing -> no second tap
        XCTAssertEqual(tap.creates, 1)
        coordinator.stop(bundleID: "com.example.music")
    }

    // MARK: - Coordinator deinit tears down any still-active taps (no leak backstop).

    func testCoordinatorDeinitTearsDownRemainingTaps() {
        let tap = FakeProcessTap()
        var coordinator: PerAppCaptureCoordinator? = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in 1 },
            muteBehavior: .mutedWhenTapped
        )
        coordinator?.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator?.state(for: "com.example.music") { return true }; return false }
        XCTAssertEqual(tap.teardowns, 0)

        coordinator = nil
        XCTAssertGreaterThanOrEqual(tap.teardowns, 1, "dropping the coordinator without stop() must not leak the tap")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
