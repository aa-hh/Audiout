import XCTest
@testable import AudiouterCore

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Hermetic tests for ``PerAppCaptureCoordinator`` (T3, T2 full-process-set).
/// Every seam is injected — a fake ``ProcessAudioTap`` factory (no TCC, no
/// aggregate device, no real Core Audio) and an ``AudioProcessResolver``
/// built over a scripted ``FakeProcessEnumerator`` (no `NSRunningApplication`,
/// no live Core Audio) — so the whole per-bundle-ID state machine runs
/// hermetically. Mirrors ``NativeCaptureCoordinatorTests``' doubles/pattern.
final class PerAppCaptureCoordinatorTests: XCTestCase {

    // MARK: Doubles

    /// A tap the test drives directly: `createAndStart` returns a scripted
    /// format (or throws a scripted error), and `pushBuffer`/`fireDeviceChange`
    /// inject the IOProc-thread callbacks. Records the resolved processes/bundleID
    /// it was started with and teardown calls, so leaks and cross-app bleed are
    /// observable.
    private final class FakeProcessTap: ProcessAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?

        let lock = NSLock()
        var format = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        var startError: PerAppCaptureError?
        private(set) var createCount = 0
        private(set) var teardownCount = 0
        private(set) var lastProcesses: Set<AudioProcess>?
        private(set) var lastBundleID: String?

        /// Test-only hook invoked synchronously at the START of `createAndStart`
        /// (before the scripted `startError`/return), i.e. while the coordinator's
        /// slot is `.creatingTap`. Lets a test inject a `fireDeviceChange()` call
        /// (or anything else) DURING a rebuild, deterministically — no real
        /// concurrency/timing needed since `createAndStart` runs synchronously on
        /// the caller's thread in this fake.
        var onCreateAndStart: (() -> Void)?

        func createAndStart(processes: Set<AudioProcess>, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            lock.lock(); createCount += 1; lastProcesses = processes; lastBundleID = bundleID; lock.unlock()
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

    /// A scriptable ``AudioProcessEnumerating`` fake: hands back whatever
    /// `RawAudioProcess` array is currently set, with no parent-pid chain
    /// (every process reports its own bundle id directly) unless a test
    /// overrides `parents`/`bundleIDForPID`. Lets a test build an
    /// ``AudioProcessResolver`` whose `resolve(bundleID:)` result it fully
    /// controls, without any live Core Audio.
    private final class FakeProcessEnumerator: AudioProcessEnumerating, @unchecked Sendable {
        let lock = NSLock()
        var processes: [RawAudioProcess] = []
        var parents: [pid_t: pid_t] = [:]

        func enumerateProcesses() -> [RawAudioProcess] { lock.withLock { processes } }
        func parentPID(of pid: pid_t) -> pid_t? { lock.withLock { parents[pid] } }

        func setProcesses(_ new: [RawAudioProcess]) { lock.withLock { processes = new } }
    }

    /// Builds an ``AudioProcessResolver`` over a `FakeProcessEnumerator` seeded
    /// with a single process object (`objectID`/`pid`) reporting `bundleID` as
    /// its own — the common single-process-per-app test shape. Returns the
    /// enumerator too so a test can mutate it later (e.g. simulate a relaunch
    /// with a new pid, or the app quitting).
    private func makeResolver(
        bundleID: String, objectID: AudioObjectID, pid: pid_t
    ) -> (resolver: AudioProcessResolver, enumerator: FakeProcessEnumerator) {
        let enumerator = FakeProcessEnumerator()
        enumerator.setProcesses([RawAudioProcess(objectID: objectID, pid: pid, bundleID: bundleID)])
        return (AudioProcessResolver(enumerator: enumerator), enumerator)
    }

    /// Builds an ``AudioProcessResolver`` over a `FakeProcessEnumerator` seeded
    /// with exactly the given processes (own-bundle-id reporting) — for tests
    /// that need multiple bundle IDs' processes coexisting in one enumerator.
    private func makeResolver(processes: [RawAudioProcess]) -> (resolver: AudioProcessResolver, enumerator: FakeProcessEnumerator) {
        let enumerator = FakeProcessEnumerator()
        enumerator.setProcesses(processes)
        return (AudioProcessResolver(enumerator: enumerator), enumerator)
    }

    /// An ``AudioProcessResolver`` whose enumerator always reports zero
    /// processes — every `resolve(bundleID:)` call returns the empty set,
    /// simulating "not running / not yet audible".
    private func emptyResolver() -> AudioProcessResolver {
        AudioProcessResolver(enumerator: FakeProcessEnumerator())
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
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 10, pid: 4242)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.onBuffer = { bundleID, buffer in spy.record(bundleID, buffer) }

        coordinator.start(bundleID: "com.example.music")
        waitFor { coordinator.state(for: "com.example.music") == .capturing(tap.format) }
        XCTAssertEqual(coordinator.state(for: "com.example.music"), .capturing(tap.format))
        XCTAssertEqual(tap.creates, 1)
        XCTAssertEqual(tap.lastProcesses, [AudioProcess(objectID: 10, pid: 4242)])
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

    // MARK: - T2: a bundle ID that resolves to MULTIPLE process objects (the
    // Firefox/Chrome multi-process-browser shape — a main process plus a
    // nil-bundle-id audio child attributed via the parent-pid walk) gets ONE
    // tap that is a mixdown of ALL of them, not just the main process. This is
    // the actual leak fix: tapping only the main process silently misses the
    // child the audio actually comes from.

    func testMultiProcessBundleMixesDownAllResolvedProcessesIntoOneTap() {
        let tap = FakeProcessTap()
        let firefox = "org.mozilla.firefox"
        let enumerator = FakeProcessEnumerator()
        enumerator.setProcesses([
            RawAudioProcess(objectID: 20, pid: 700, bundleID: firefox),   // main process
            RawAudioProcess(objectID: 21, pid: 701, bundleID: nil)        // silent audio child
        ])
        enumerator.parents = [701: 700]
        let resolver = AudioProcessResolver(enumerator: enumerator)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )

        coordinator.start(bundleID: firefox)
        waitFor { if case .capturing = coordinator.state(for: firefox) { return true }; return false }

        XCTAssertEqual(tap.creates, 1, "one tap for the bundle ID, mixing down every resolved process")
        XCTAssertEqual(tap.lastProcesses, [
            AudioProcess(objectID: 20, pid: 700),
            AudioProcess(objectID: 21, pid: 701)
        ], "both the main process and the nil-bundle-id audio child must be tapped")

        coordinator.stop(bundleID: firefox)
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
        let (resolver, _) = makeResolver(processes: [
            RawAudioProcess(objectID: 1, pid: 111, bundleID: "com.example.a"),
            RawAudioProcess(objectID: 2, pid: 222, bundleID: "com.example.b")
        ])

        let coordinator = PerAppCaptureCoordinator(
            makeTap: { factory.make() },
            processResolver: resolver,
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
        XCTAssertEqual(tapA.lastProcesses, [AudioProcess(objectID: 1, pid: 111)])
        XCTAssertEqual(tapB.lastProcesses, [AudioProcess(objectID: 2, pid: 222)])

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

    // MARK: - An empty AudioProcessResolver result (T2) surfaces as
    // .failed(.processNotYetAudible), retryable — the resolver can't tell "not
    // running" apart from "running but silent", so both retry the same way.

    func testEmptyResolvedProcessSetSurfacesProcessNotYetAudible() {
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { FakeProcessTap() },
            processResolver: emptyResolver(),
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.missing")
        waitFor {
            if case .failed(.processNotYetAudible) = coordinator.state(for: "com.example.missing") { return true }
            return false
        }
        XCTAssertEqual(coordinator.state(for: "com.example.missing"),
                       .failed(.processNotYetAudible(bundleID: "com.example.missing")))
        XCTAssertTrue(PerAppCaptureError.processNotYetAudible(bundleID: "x").isRetryable)
    }

    // MARK: - Tap-creation failure (e.g. processNotYetAudible) surfaces as .failed AND tears down.

    func testProcessNotYetAudibleSurfacesErrorAndTearsDown() {
        let tap = FakeProcessTap()
        tap.startError = .processNotYetAudible(bundleID: "com.example.silent")
        let (resolver, _) = makeResolver(bundleID: "com.example.silent", objectID: 1, pid: 999)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: resolver,
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
        let processes: Set<AudioProcess> = [AudioProcess(objectID: 1, pid: 1)]
        XCTAssertThrowsError(try tap.createAndStart(processes: processes, bundleID: "com.example.old", muteBehavior: .mutedWhenTapped)) { error in
            XCTAssertEqual(error as? PerAppCaptureError, .osUnsupported(minimum: "14.2"))
        }
        XCTAssertFalse(PerAppCaptureError.osUnsupported(minimum: "14.2").isRetryable)
    }

    func testUnavailableProcessTapDrivenThroughCoordinatorSurfacesOSUnsupported() {
        let (resolver, _) = makeResolver(bundleID: "com.example.old", objectID: 1, pid: 1)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { UnavailableProcessTap() },
            processResolver: resolver,
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

    // MARK: - Default-device change recreates the tap, re-resolving the process set.

    func testDeviceChangeRecreatesTapAndReResolvesProcessSet() {
        let tap = FakeProcessTap()
        let (resolver, enumerator) = makeResolver(bundleID: "com.example.music", objectID: 10, pid: 500)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        XCTAssertEqual(tap.lastProcesses, [AudioProcess(objectID: 10, pid: 500)])

        // The app relaunched with a new pid (and object id) before the device change fired.
        enumerator.setProcesses([RawAudioProcess(objectID: 11, pid: 501, bundleID: "com.example.music")])
        tap.format = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()
        waitFor {
            if case .capturing(let f) = coordinator.state(for: "com.example.music") { return f.sampleRate == 44100 }
            return false
        }
        XCTAssertEqual(tap.lastProcesses, [AudioProcess(objectID: 11, pid: 501)],
                       "device-change recreation re-resolves the process set")
        XCTAssertGreaterThanOrEqual(tap.teardowns, 1, "the old tap is torn down on device change")
        XCTAssertGreaterThanOrEqual(tap.creates, 2)

        coordinator.stop(bundleID: "com.example.music")
    }

    // MARK: - STABILITY(C6) coalescing: a device-change notification arriving mid-rebuild
    // (.creatingTap) must be coalesced (Slot.pendingDeviceChange) and replayed once the
    // rebuild lands in .capturing, not dropped.

    func testDeviceChangeDuringRebuildIsCoalescedAndReplayed() {
        let tap = FakeProcessTap()
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 1, pid: 4242)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: resolver,
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
        let (resolver, _) = makeResolver(processes: [
            RawAudioProcess(objectID: 1, pid: 100, bundleID: "com.example.paused"),
            RawAudioProcess(objectID: 2, pid: 200, bundleID: "com.example.old")
        ])
        // makeTap has no bundleID param, so route by which bundle ID the test
        // is currently driving through the coordinator — the fake tap the
        // resolver hands processes for is not otherwise observable from here.
        let nextBundleID = NSMutableString(string: "")
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { factory.make(for: nextBundleID as String) },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )

        nextBundleID.setString("com.example.paused")
        coordinator.start(bundleID: "com.example.paused")
        waitFor {
            if case .failed(.processNotYetAudible) = coordinator.state(for: "com.example.paused") { return true }
            return false
        }
        nextBundleID.setString("com.example.old")
        coordinator.start(bundleID: "com.example.old")
        waitFor {
            if case .failed(.osUnsupported) = coordinator.state(for: "com.example.old") { return true }
            return false
        }

        // The paused app resumes: its next tap creation will succeed.
        tapA.startError = nil

        // A process connected to / disconnected from the audio system. The
        // re-drive replays start(bundleID: "com.example.paused") internally.
        nextBundleID.setString("com.example.paused")
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
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 1, pid: 1)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: resolver,
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
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 1, pid: 1)
        var coordinator: PerAppCaptureCoordinator? = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: resolver,
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
