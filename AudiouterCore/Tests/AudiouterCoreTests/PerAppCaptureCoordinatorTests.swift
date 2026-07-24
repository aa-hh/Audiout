import XCTest
@testable import AudiouterCore

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

        /// Real storage for the protocol's ``ProcessAudioTap/targetProcessObjects``
        /// (overriding the default no-op) — the coordinator assigns this from its
        /// resolver BEFORE `createAndStart`, so recording it proves the resolved
        /// process-object set actually reached the tap.
        private var _targetProcessObjects: Set<AudioObjectID> = []
        var targetProcessObjects: Set<AudioObjectID> {
            get { lock.withLock { _targetProcessObjects } }
            set { lock.withLock { _targetProcessObjects = newValue } }
        }
        /// The `targetProcessObjects` seen by the MOST RECENT `createAndStart`.
        private(set) var lastTargetProcessObjects: Set<AudioObjectID>?
        var lastTargets: Set<AudioObjectID>? { lock.withLock { lastTargetProcessObjects } }

        /// Test-only hook invoked synchronously at the START of `createAndStart`
        /// (before the scripted `startError`/return), i.e. while the coordinator's
        /// slot is `.creatingTap`. Lets a test inject a `fireDeviceChange()` call
        /// (or anything else) DURING a rebuild, deterministically — no real
        /// concurrency/timing needed since `createAndStart` runs synchronously on
        /// the caller's thread in this fake.
        var onCreateAndStart: (() -> Void)?

        func createAndStart(pid: pid_t, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            lock.lock()
            createCount += 1; lastPid = pid; lastBundleID = bundleID
            lastTargetProcessObjects = _targetProcessObjects
            lock.unlock()
            onCreateAndStart?()
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

    // Default timeout is a generous ceiling, not an expected wait: the loop
    // returns the instant `cond()` holds, so a higher bound only adds headroom
    // for the FAILURE/slow case and costs nothing on the happy path. Raised from
    // 2s so it doesn't spuriously time out under `swift test --parallel`, where
    // ~8 test processes contend for cores and an async state transition can take
    // longer than 2s of wall-clock to land.
    private func waitFor(timeout: TimeInterval = 8, _ cond: @escaping () -> Bool) {
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

    // MARK: - STABILITY(C6) coalescing: a device-change notification arriving mid-rebuild
    // (.creatingTap) must be coalesced (Slot.pendingDeviceChange) and replayed once the
    // rebuild lands in .capturing, not dropped.

    func testDeviceChangeDuringRebuildIsCoalescedAndReplayed() {
        let tap = FakeProcessTap()
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in 4242 },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        XCTAssertEqual(tap.creates, 1)

        // Arm the hook: the SECOND createAndStart (the rebuild triggered by the
        // first fireDeviceChange below) fires a SECOND device-change notification
        // while the slot is still mid-rebuild (state == .creatingTap, since this
        // hook runs synchronously inside createAndStart, before the coordinator
        // commits the new state). That second notification must be coalesced
        // (Slot.pendingDeviceChange = true), not dropped.
        tap.onCreateAndStart = { [weak tap] in
            guard let tap, tap.creates == 2 else { return }
            tap.fireDeviceChange()
        }

        tap.fireDeviceChange() // first notification -> triggers rebuild (create #2)

        // If the second (coalesced) notification were dropped, `creates` would
        // stop at 2 once the rebuild lands in .capturing. A THIRD create proves
        // the coalesced notification was replayed after the rebuild completed.
        waitFor { tap.creates >= 3 }
        XCTAssertGreaterThanOrEqual(
            tap.creates, 3,
            "a device-change notification arriving mid-rebuild (.creatingTap) must be "
            + "coalesced and replayed once the rebuild lands in .capturing, not dropped")

        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        XCTAssertEqual(coordinator.state(for: "com.example.music"), .capturing(tap.format))

        coordinator.stop(bundleID: "com.example.music")
    }

    // MARK: - T3 resume self-heal: a system process-list change re-drives dead-but-retryable
    // slots through start() to .capturing; a NON-retryable dead slot is left untouched.

    func testProcessListChangeReDrivesRetryableFailedSlotButNotNonRetryable() {
        // Slot A: fails with a RETRYABLE error (processNotYetAudible), then the
        // app "resumes" (startError cleared) — a process-list change must re-drive
        // it to .capturing.
        let tapA = FakeProcessTap()
        tapA.startError = .processNotYetAudible(bundleID: "com.example.paused")
        // Slot B: fails with a NON-retryable error (osUnsupported) — a process-list
        // change must NOT re-drive it (an OS-version gate never resolves itself).
        let tapB = FakeProcessTap()
        tapB.startError = .osUnsupported(minimum: "14.2")

        final class Factory: @unchecked Sendable {
            let a: FakeProcessTap; let b: FakeProcessTap
            init(_ a: FakeProcessTap, _ b: FakeProcessTap) { self.a = a; self.b = b }
            func make(for bundleID: String) -> FakeProcessTap {
                bundleID == "com.example.paused" ? a : b
            }
        }
        let factory = Factory(tapA, tapB)
        // makeTap has no bundleID param, so route by the pid the resolver hands
        // back: paused -> 100 (tapA), old -> 200 (tapB). The factory returns the
        // right fake per next-started bundle ID via a tiny shared box.
        let nextBundleID = NSMutableString(string: "")
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { factory.make(for: nextBundleID as String) },
            resolvePID: { bundleID in
                nextBundleID.setString(bundleID)
                return bundleID == "com.example.paused" ? 100 : 200
            },
            muteBehavior: .mutedWhenTapped
        )

        coordinator.start(bundleID: "com.example.paused")
        waitFor {
            if case .failed(.processNotYetAudible) = coordinator.state(for: "com.example.paused") { return true }
            return false
        }
        coordinator.start(bundleID: "com.example.old")
        waitFor {
            if case .failed(.osUnsupported) = coordinator.state(for: "com.example.old") { return true }
            return false
        }

        // The paused app resumes: its next tap creation will succeed.
        tapA.startError = nil

        // A process connected to / disconnected from the audio system.
        coordinator.handleProcessListChanged()

        // The retryable slot self-heals to .capturing...
        waitFor { if case .capturing = coordinator.state(for: "com.example.paused") { return true }; return false }
        XCTAssertEqual(coordinator.state(for: "com.example.paused"), .capturing(tapA.format),
                       "a process-list change must re-drive a retryable .failed slot to .capturing")

        // ...while the non-retryable slot is left exactly where it was.
        XCTAssertEqual(coordinator.state(for: "com.example.old"), .failed(.osUnsupported(minimum: "14.2")),
                       "a non-retryable .failed slot (osUnsupported) must NOT be re-driven")

        coordinator.stop(bundleID: "com.example.paused")
        coordinator.stop(bundleID: "com.example.old")
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

    // MARK: - A1 gap: a device-change notification arriving during the VERY FIRST
    // .creatingTap (beginStart, the initial start — NOT a handleDeviceChange rebuild)
    // must be coalesced and replayed once capturing is reached, exactly like
    // handleDeviceChange's own replay. Before the fix, beginStart's success commit
    // never checked slot.pendingDeviceChange, so this notification was silently dropped.

    func testBeginStartReplaysPendingDeviceChangeFromInitialStart() {
        let tap = FakeProcessTap()
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in 4242 },
            muteBehavior: .mutedWhenTapped
        )

        // Fire a device-change notification DURING the first createAndStart, i.e.
        // while the slot is in its initial `.creatingTap` (before beginStart commits
        // `.capturing`). handleDeviceChange sees `.creatingTap` and coalesces it into
        // slot.pendingDeviceChange rather than acting immediately. Guarded to the
        // FIRST create so the replayed rebuild's own createAndStart doesn't re-fire.
        tap.onCreateAndStart = { [weak tap] in
            guard let tap, tap.creates == 1 else { return }
            tap.fireDeviceChange()
        }

        coordinator.start(bundleID: "com.example.music")

        // The coalesced change must be replayed once capturing is reached, driving a
        // SECOND tap creation. Without the beginStart replay fix, `creates` stops at 1
        // (the notification dropped) and no rebuild ever happens.
        waitFor { tap.creates >= 2 }
        XCTAssertGreaterThanOrEqual(
            tap.creates, 2,
            "a device change arriving during the initial-start .creatingTap must be "
            + "coalesced and replayed once capturing is reached, not dropped")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        XCTAssertEqual(coordinator.state(for: "com.example.music"), .capturing(tap.format))

        coordinator.stop(bundleID: "com.example.music")
    }

    // MARK: - T2 (PLAN-FIREFOX-ROUTING-LEAK): the per-app tap targets the FULL
    // process-object set resolved across the app's process tree, not just the
    // main pid's object; an empty resolution surfaces the retryable
    // `.processNotYetAudible` WITHOUT ever building a zero-process tap. The
    // single-pid state-machine tests above are the unchanged regression guard —
    // they run on the injected default (one object per pid) resolver.

    #if canImport(AudioToolbox)

    /// Records the pids the injected resolver was asked about, returning a fixed
    /// object set — proof of "called with the right pid, and its result reached
    /// the tap."
    private final class ResolverSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [pid_t] = []
        private let result: Set<AudioObjectID>
        init(returning result: Set<AudioObjectID>) { self.result = result }
        func resolve(_ pid: pid_t) -> Set<AudioObjectID> {
            lock.withLock { _asked.append(pid) }
            return result
        }
        var asked: [pid_t] { lock.withLock { _asked } }
    }

    /// A mutable resolver result so a test can flip empty -> non-empty and prove
    /// the `.processNotYetAudible` retry re-resolves.
    private final class ObjectsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Set<AudioObjectID>
        init(_ value: Set<AudioObjectID>) { self.value = value }
        func get() -> Set<AudioObjectID> { lock.withLock { value } }
        func set(_ newValue: Set<AudioObjectID>) { lock.withLock { value = newValue } }
    }

    /// Single-process app: resolves to exactly ONE object, and THAT one reaches
    /// the tap — the pre-widening behavior, preserved for the common case (Q3).
    func testSingleProcessAppTargetsExactlyItsOneProcessObject() {
        let tap = FakeProcessTap()
        let pid: pid_t = 800
        // AudioProcessResolver returns {root's object} for a childless process.
        let single: Set<AudioObjectID> = [8080]
        let spy = ResolverSpy(returning: single)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in pid },
            resolveProcessObjects: { spy.resolve($0) },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.single")
        waitFor { if case .capturing = coordinator.state(for: "com.example.single") { return true }; return false }

        XCTAssertEqual(spy.asked, [pid], "the resolver is invoked once, with the app's main pid")
        XCTAssertEqual(tap.lastTargets, single,
                       "a single-process app resolves to exactly one process object — unchanged from the pre-widening behavior")
        coordinator.stop(bundleID: "com.example.single")
    }

    /// Multi-process browser (main pid + child pids, audio living in a child):
    /// the tap must target the FULL resolved set — the Firefox leak fix. The main
    /// pid's object alone would have captured silence.
    func testMultiProcessAppTargetsFullResolvedProcessObjectSet() {
        let tap = FakeProcessTap()
        let mainPID: pid_t = 700
        // main's object + two child objects, as the resolver yields for a real
        // multi-process browser.
        let fullSet: Set<AudioObjectID> = [7001, 7002, 7003]
        let spy = ResolverSpy(returning: fullSet)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in mainPID },
            resolveProcessObjects: { spy.resolve($0) },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "org.mozilla.firefox")
        waitFor { if case .capturing = coordinator.state(for: "org.mozilla.firefox") { return true }; return false }

        XCTAssertEqual(spy.asked, [mainPID], "the resolver is invoked with the app's MAIN pid; it widens to the tree")
        XCTAssertEqual(
            tap.lastTargets, fullSet,
            "the FULL multi-process object set (main + children) must reach the tap description — "
            + "not just the main pid's object, which is the whole point of the routing-leak fix")
        coordinator.stop(bundleID: "org.mozilla.firefox")
    }

    /// Empty resolution (nothing in the tree is audible yet): surface the
    /// retryable `.processNotYetAudible` and build NO tap (the coordinator throws
    /// before any CATapDescription). Then a retry, once a process becomes
    /// audible, re-resolves and reaches `.capturing`.
    func testEmptyResolutionSurfacesProcessNotYetAudibleWithoutBuildingATapThenRetries() {
        let tap = FakeProcessTap()
        let box = ObjectsBox([])  // no audible process in the tree yet
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            resolvePID: { _ in 900 },
            resolveProcessObjects: { _ in box.get() },
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.silent")
        waitFor {
            if case .failed(.processNotYetAudible) = coordinator.state(for: "com.example.silent") { return true }
            return false
        }
        XCTAssertEqual(coordinator.state(for: "com.example.silent"),
                       .failed(.processNotYetAudible(bundleID: "com.example.silent")),
                       "an empty resolution must surface the RETRYABLE .processNotYetAudible, not a hard failure")
        XCTAssertEqual(tap.creates, 0,
                       "no tap may be created for an empty process set — the coordinator throws BEFORE building any CATapDescription")
        XCTAssertTrue(PerAppCaptureError.processNotYetAudible(bundleID: "x").isRetryable)

        // The app becomes audible; start() from .failed re-resolves (now non-empty)
        // and reaches .capturing, tapping the now-live object.
        box.set([9001])
        coordinator.start(bundleID: "com.example.silent")
        waitFor { if case .capturing = coordinator.state(for: "com.example.silent") { return true }; return false }
        XCTAssertEqual(coordinator.state(for: "com.example.silent"), .capturing(tap.format))
        XCTAssertEqual(tap.lastTargets, [9001], "the retry taps the now-audible process object")
        XCTAssertEqual(tap.creates, 1, "exactly one tap is created — only after the resolution became non-empty")
        coordinator.stop(bundleID: "com.example.silent")
    }

    #endif

    // MARK: - Compare-before-rebuild decision (TapRebuildDecision): the pure logic
    // BOTH per-app listener guards call after their live HAL read. Testing the
    // DECISION here is what makes the storm guard meaningful without mocking Core
    // Audio — the live reads (defaultOutputDeviceID / readNominalSampleRate) stay a
    // thin wrapper, while the part that's easy to get subtly wrong is fully covered.

    #if canImport(AudioToolbox)

    /// RATE guard (Fix 2 / installSampleRateListener). Cases (c), (d), (e).
    /// (d) — a genuinely CHANGED rate must STILL fire the rebuild — is the one
    /// regression that would silently reintroduce the process-tap silent-buffer bug
    /// (a rate renegotiation with the device UID unchanged, which only THIS listener
    /// catches). The guard must therefore compare the RATE, never device identity.
    func testRateGuardFiresOnlyOnGenuineRateChange() {
        // (c) unchanged rate -> NO rebuild (drops the no-op notification that would
        // otherwise storm across every live tap).
        XCTAssertFalse(TapRebuildDecision.shouldRebuild(currentRate: 48000, trackedRateInt: 48000),
                       "an identical nominal rate must NOT trigger a rebuild (storm guard)")

        // (d) CHANGED rate -> rebuild MUST fire. If a real rate change stopped firing,
        // the tap would go silent (all-zero PCM) with no recovery — the exact bug this
        // listener exists to fix.
        XCTAssertTrue(TapRebuildDecision.shouldRebuild(currentRate: 44100, trackedRateInt: 48000),
                      "a genuinely changed nominal rate MUST still trigger a rebuild (silent-tap regression)")
        XCTAssertTrue(TapRebuildDecision.shouldRebuild(currentRate: 96000, trackedRateInt: 48000))

        // (e) failed live read (nil) -> treat as changed -> fire. A failed read is
        // never evidence of "no change."
        XCTAssertTrue(TapRebuildDecision.shouldRebuild(currentRate: nil, trackedRateInt: 48000),
                      "a failed rate read must be treated as changed (fire), not suppressed")

        // Sub-Hz driver jitter that rounds to the SAME Int rate must NOT rebuild —
        // matching how TapFormat.sampleRate is computed via Int(mSampleRate.rounded());
        // a rounded value that lands on a different Int must.
        XCTAssertFalse(TapRebuildDecision.shouldRebuild(currentRate: 48000.4, trackedRateInt: 48000),
                       "sub-Hz jitter that rounds to the same rate must not rebuild")
        XCTAssertTrue(TapRebuildDecision.shouldRebuild(currentRate: 48000.6, trackedRateInt: 48000),
                      "a rounded rate that lands on a different Int must rebuild")
    }

    /// DEVICE-IDENTITY guard (Fix 1 / installDefaultDeviceListener). Cases (a), (b), (e).
    func testDeviceGuardFiresOnlyOnGenuineDeviceChange() {
        // (a) unchanged pinned device -> NO rebuild.
        XCTAssertFalse(TapRebuildDecision.shouldRebuild(currentDeviceID: 77, trackedDeviceID: 77),
                       "an unchanged pinned device must NOT trigger a rebuild (storm guard)")
        // (b) the pinned device actually changed -> rebuild fires.
        XCTAssertTrue(TapRebuildDecision.shouldRebuild(currentDeviceID: 88, trackedDeviceID: 77),
                      "the pinned device actually changing MUST trigger a rebuild")
        // (e) failed live read (nil) -> treat as changed -> fire.
        XCTAssertTrue(TapRebuildDecision.shouldRebuild(currentDeviceID: nil, trackedDeviceID: 77),
                      "a failed device read must be treated as changed (fire), not suppressed")
    }

    #endif
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
