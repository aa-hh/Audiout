import XCTest
@testable import AudiouterCore

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
        var onNominalSampleRateChanged: (@Sendable (UInt32, Double) -> Void)?

        let lock = NSLock()
        var format = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        var startError: NativeCaptureError?
        private(set) var createCount = 0
        private(set) var teardownCount = 0
        private(set) var started = false
        /// The `excludedPIDs` passed to the MOST RECENT `createAndStart` call
        /// (T4) — lets a test assert the tap was (re)created with the right
        /// exclusion set without needing a real Core Audio process object.
        private(set) var lastExcludedPIDs: Set<pid_t> = []

        /// Test-only hook invoked synchronously at the START of `createAndStart`
        /// (before the scripted `startError`/return), i.e. while the coordinator
        /// is `.creatingTap`. Lets a test inject a `fireDeviceChange()` call (or
        /// anything else) DURING a rebuild, deterministically — no real
        /// concurrency/timing needed since `createAndStart` runs synchronously on
        /// the caller's thread in this fake. Mirrors ``FakeProcessTap``.
        var onCreateAndStart: (() -> Void)?

        func createAndStart(muteBehavior: TapMuteBehavior, excludedPIDs: Set<pid_t>) throws -> TapFormat {
            lock.lock(); createCount += 1; lastExcludedPIDs = excludedPIDs; lock.unlock()
            onCreateAndStart?()
            if let startError { throw startError }
            lock.lock(); started = true; lock.unlock()
            return format
        }

        func teardown() {
            lock.lock(); teardownCount += 1; started = false; lock.unlock()
        }

        func pushBuffer(_ b: CapturedBuffer) { onBuffer?(b) }
        func fireDeviceChange() { onDefaultDeviceChanged?() }
        func fireNominalSampleRateChanged(deviceID: UInt32, rate: Double) {
            onNominalSampleRateChanged?(deviceID, rate)
        }

        var teardowns: Int { lock.withLock { teardownCount } }
        var creates: Int { lock.withLock { createCount } }
        var excludedPIDs: Set<pid_t> { lock.withLock { lastExcludedPIDs } }
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

    /// Thread-safe bundle-ID → pid map a test can mutate BETWEEN calls (e.g. to
    /// simulate a relaunch handing out a fresh pid) while still handing a plain
    /// `@Sendable` closure to `resolveProcessSet` — a captured `var` dictionary
    /// doesn't compile under strict concurrency (R14 relaunch tests).
    private final class MutablePIDMap: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: pid_t]
        init(_ initial: [String: pid_t]) { self.map = initial }
        func get(_ bundleID: String) -> pid_t? { lock.withLock { map[bundleID] } }
        func set(_ bundleID: String, _ pid: pid_t) { lock.withLock { map[bundleID] = pid } }
    }

    // MARK: Helpers

    private func makeCoordinator(
        tap: FakeTap,
        sink: SpySink,
        converter: FakeConverter,
        resolveProcessSet: @escaping AppProcessResolver = { _ in [] }
    ) -> NativeCaptureCoordinator {
        NativeCaptureCoordinator(
            makeTap: { tap },
            sink: sink,
            makeConverter: { _ in converter },
            resolveProcessSet: resolveProcessSet,
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

    // Generous ceiling, not an expected wait: returns as soon as `cond()` holds,
    // so a higher bound only helps the slow/failure case. Raised from 2s for
    // headroom under `swift test --parallel` core contention (see the sibling
    // helper in PerAppCaptureCoordinatorTests for the full rationale).
    private func waitFor(timeout: TimeInterval = 8, _ cond: @escaping () -> Bool) {
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
        XCTAssertThrowsError(try tap.createAndStart(muteBehavior: .mutedWhenTapped, excludedPIDs: [])) { error in
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

    // MARK: - C4: a NaN/zero sample-rate tap format lands in .failed, never a trap.

    /// A degenerate tap format (zero sample rate — the value a NaN ASBD rate
    /// collapses to, and the value that makes the converter's resample ratio
    /// infinite / its AVAudioFrameCount conversion trap) must be rejected into
    /// `.failed`, not committed to `.capturing`.
    func testZeroSampleRateFormatLandsInFailed() {
        let tap = FakeTap()
        tap.format = TapFormat(sampleRate: 0, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        let sink = SpySink()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: FakeConverter())

        coordinator.start()
        guard case .failed(.formatReadFailed) = coordinator.state else {
            return XCTFail("a zero/NaN sample-rate format must land in .failed(.formatReadFailed), got \(coordinator.state)")
        }
        // The invalid-format tap must not leak — it is torn down.
        XCTAssertGreaterThanOrEqual(tap.teardowns, 1, "an invalid-format start must tear the tap down (no leak)")
    }

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

    // MARK: - STABILITY(C6) coalescing: a device-change notification arriving mid-rebuild
    // (.creatingTap) must be coalesced (pendingDeviceChange) and replayed once the rebuild
    // lands in .capturing, not dropped. Whole-system port of PerAppCaptureCoordinator's fix.

    func testDeviceChangeDuringRebuildIsCoalescedAndReplayed() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        XCTAssertEqual(tap.creates, 1)

        // Arm the hook: the SECOND createAndStart (the rebuild triggered by the
        // first fireDeviceChange below) fires a SECOND device-change notification
        // while the coordinator is still mid-rebuild (state == .creatingTap, since
        // this hook runs synchronously inside createAndStart, before the commit).
        // That second notification must be coalesced (pendingDeviceChange = true),
        // not dropped.
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

        waitFor { if case .capturing = coordinator.state { return true }; return false }
        XCTAssertEqual(coordinator.state, .capturing(tap.format))

        coordinator.stop()
    }

    // MARK: - T4: exclusion-list wiring (routed apps + user-excluded apps must
    // not leak into the whole-system mix tap).

    /// Changing the routed-apps set recreates the capturing tap with the
    /// correctly updated exclusion pid list.
    func testUpdateRoutingRecreatesTapWithUpdatedExclusionPIDs() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.a": 111]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        coordinator.start()
        XCTAssertEqual(tap.creates, 1)
        XCTAssertEqual(tap.excludedPIDs, [], "no routes yet — nothing excluded")

        let routes = [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))]
        coordinator.updateRouting(appRoutes: routes, excludedBundleIDs: [])

        XCTAssertEqual(tap.creates, 2, "a route change while capturing recreates the tap")
        XCTAssertEqual(tap.excludedPIDs, [111], "the newly-routed app's pid is excluded from the system mix")
        coordinator.stop()
    }

    /// An app flipped from `.device(id:)` back to `.currentDevice` is REMOVED
    /// from the exclusion list — it re-enters the system mix.
    func testAppFlippedBackToCurrentDeviceReentersSystemMix() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.a": 111]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        XCTAssertEqual(tap.excludedPIDs, [111])
        let createsAfterRoute = tap.creates

        // The route flips back to .currentDevice — "no redirect."
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .currentDevice)],
            excludedBundleIDs: [])

        XCTAssertGreaterThan(tap.creates, createsAfterRoute, "the tap is recreated again on the flip back")
        XCTAssertEqual(tap.excludedPIDs, [], "an app back on .currentDevice must re-enter the system mix")
        coordinator.stop()
    }

    /// A `.device`-routed app's pid never appears in the system-mix tap's
    /// exclusion-blind spot — i.e. it IS present in the exclusion list
    /// (so it can never double-send: once to its own destination via
    /// per-app capture, and again via this whole-system mixdown).
    func testDeviceRoutedAppPIDNeverLeaksIntoSystemMix() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.a": 111, "com.app.b": 222]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [
                AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1")),
                AppRoute(bundleID: "com.app.b", displayName: "App B", destination: .currentDevice),
            ],
            excludedBundleIDs: [])

        XCTAssertTrue(tap.excludedPIDs.contains(111), "the .device-routed app's pid must be excluded (no double-send)")
        XCTAssertFalse(tap.excludedPIDs.contains(222), ".currentDevice apps stay in the system mix")
        coordinator.stop()
    }

    /// W1-T3: a bundle ID that resolves to a FULL process set (main + audio-
    /// playing children, e.g. a browser's helper processes) must have EVERY
    /// pid in that set excluded from the whole-system mix — not just the
    /// first/main pid — or the child's audio leaks into the system tap
    /// alongside its own per-app-routed destination (R2/R14).
    func testMultiProcessBundleExcludesEveryPIDFromSystemMix() {
        let tap = FakeTap()
        // A fake browser: main pid + two audio-playing helper/child pids.
        let browserPIDs: [pid_t] = [111, 222, 333]
        let pids: [String: [pid_t]] = ["com.browser.app": browserPIDs, "com.app.b": [999]]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid] ?? [] })

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [
                AppRoute(bundleID: "com.browser.app", displayName: "Browser", destination: .device(id: "speaker-1")),
                AppRoute(bundleID: "com.app.b", displayName: "App B", destination: .currentDevice),
            ],
            excludedBundleIDs: [])

        XCTAssertEqual(tap.excludedPIDs, Set(browserPIDs),
                       "ALL of the browser's process-set pids (main + both helpers) must be excluded, "
                       + "not just the first/main pid")
        XCTAssertFalse(tap.excludedPIDs.contains(999), ".currentDevice apps stay in the system mix")
        coordinator.stop()
    }

    /// `.noRedirect` (the new default/unset state) is exclusion-equivalent to
    /// `.currentDevice`: neither is ever excluded from the system-wide tap. An
    /// app left "unset" must not be accidentally dropped from the system mix.
    func testNoRedirectAppPIDStaysInSystemMixJustLikeCurrentDevice() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.a": 111, "com.app.b": 222, "com.app.c": 333]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [
                AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1")),
                AppRoute(bundleID: "com.app.b", displayName: "App B", destination: .currentDevice),
                AppRoute(bundleID: "com.app.c", displayName: "App C", destination: .noRedirect),
            ],
            excludedBundleIDs: [])

        XCTAssertEqual(tap.excludedPIDs, [111],
                       "only the .device-routed app is excluded; both local states (.currentDevice AND "
                       + ".noRedirect) stay in the system mix identically")
        coordinator.stop()
    }

    /// The existing user-excluded-apps list (Settings › Audio) still works
    /// and composes correctly (UNION) with route-based exclusion.
    func testUserExcludedAppsComposeWithRouteBasedExclusion() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.a": 111, "com.app.c": 333]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        coordinator.start()
        // Only a user-excluded app, no routes yet.
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.c"])
        XCTAssertEqual(tap.excludedPIDs, [333])

        // Add a routed app on top — the union must include BOTH.
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: ["com.app.c"])
        XCTAssertEqual(tap.excludedPIDs, [111, 333], "route-based and user-excluded exclusions compose (union)")
        coordinator.stop()
    }

    /// Calling `updateRouting` with an unchanged union is a no-op — it must
    /// not recreate the tap on every unrelated tick.
    func testUpdateRoutingIsNoOpWhenUnionUnchanged() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.a": 111]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        coordinator.start()
        let route = [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))]
        coordinator.updateRouting(appRoutes: route, excludedBundleIDs: [])
        let createsAfterFirstUpdate = tap.creates

        // Same union again (route list re-passed verbatim, as a caller might
        // do on an unrelated tick) — must NOT recreate.
        coordinator.updateRouting(appRoutes: route, excludedBundleIDs: [])
        XCTAssertEqual(tap.creates, createsAfterFirstUpdate, "an unchanged exclusion union must not recreate the tap")
        coordinator.stop()
    }

    /// `updateRouting` called while NOT capturing doesn't touch any tap, but
    /// the computed exclusion set is applied on the NEXT `start()`.
    func testUpdateRoutingWhileIdleAppliesOnNextStart() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.a": 111]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        // Not capturing yet — updateRouting must not create a tap.
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        XCTAssertEqual(tap.creates, 0)

        coordinator.start()
        XCTAssertEqual(tap.creates, 1)
        XCTAssertEqual(tap.excludedPIDs, [111], "the previously-computed exclusion set is applied on start()")
        coordinator.stop()
    }

    // MARK: - R14: relaunch correctness (`refreshExcludedProcessSet`)

    /// An EXCLUDED app relaunches (old pid dies, a fresh pid takes its place
    /// under the same bundle ID) — the bundle-ID union `updateRouting` tracks
    /// is unchanged, so its own no-op guard would never recreate the tap.
    /// `refreshExcludedProcessSet` must bypass that guard and pick up the
    /// fresh pid so the relaunched app doesn't leak back into the system mix.
    func testRefreshExcludedProcessSetPicksUpRelaunchedExcludedAppPID() {
        let tap = FakeTap()
        let pids = MutablePIDMap(["com.app.excluded": 111])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids.get(bid).map { [$0] } ?? [] })

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        XCTAssertEqual(tap.excludedPIDs, [111])
        let createsAfterExclude = tap.creates

        // The app quits and relaunches with a new pid — same bundle ID.
        pids.set("com.app.excluded", 456)
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")

        XCTAssertGreaterThan(tap.creates, createsAfterExclude, "relaunch must recreate the tap")
        XCTAssertEqual(tap.excludedPIDs, [456], "the relaunched app's FRESH pid is excluded, not the stale one")
        coordinator.stop()
    }

    /// A ROUTED (`.device`) app relaunches — its fresh pid must be excluded
    /// from the system mix too, or it doubles: once via its own target route,
    /// once via the whole-system mixdown.
    func testRefreshExcludedProcessSetPicksUpRelaunchedRoutedAppPID() {
        let tap = FakeTap()
        let pids = MutablePIDMap(["com.app.routed": 111])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids.get(bid).map { [$0] } ?? [] })

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.routed", displayName: "Routed", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        XCTAssertEqual(tap.excludedPIDs, [111])
        let createsAfterRoute = tap.creates

        pids.set("com.app.routed", 777)
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.routed")

        XCTAssertGreaterThan(tap.creates, createsAfterRoute, "relaunch must recreate the tap")
        XCTAssertEqual(tap.excludedPIDs, [777], "the relaunched routed app's fresh pid is excluded — no doubling")
        coordinator.stop()
    }

    /// A bundle ID that ISN'T currently excluded/routed-away must not trigger
    /// any rebuild — cheap to call on every app launch, routed or not.
    func testRefreshExcludedProcessSetIsNoOpForUnrelatedBundleID() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.a": 111]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        let createsAfterRoute = tap.creates

        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.unrelated")
        XCTAssertEqual(tap.creates, createsAfterRoute, "an unrelated bundle ID must not recreate the tap")
        coordinator.stop()
    }

    /// Calling `refreshExcludedProcessSet` while not capturing (e.g. no
    /// device selected yet) must not create a tap — the fresh pid is simply
    /// picked up on the next real `start()`.
    func testRefreshExcludedProcessSetWhileIdleIsNoOp() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.excluded": 111]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        // Excluded set recorded while idle (no start() yet).
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        XCTAssertEqual(tap.creates, 0, "no tap exists yet — refresh must not create one")
    }

    // MARK: - W1-T7 Fix 1: refreshExcludedProcessSet must compare-before-rebuild
    // (the coreaudiod CPU-storm regression it previously reintroduced)

    /// THE storm-prevention property (W1-T7 Fix 1). `refreshExcludedProcessSet`
    /// is wired by R9 (`handlePerAppCaptureHealthChange`) to fire on EVERY per-app
    /// tap `.capturing` transition. With N routed apps re-reaching `.capturing`
    /// after one output-device sample-rate renegotiation, the OLD unconditional
    /// `recreateTap()` drove N full whole-system teardown/recreates on an UNCHANGED
    /// excluded set — the amplified coreaudiod rebuild storm the compare-before-
    /// rebuild discipline exists to prevent. A refresh whose resolved exclusion set
    /// is unchanged must now do ZERO Core Audio work, no matter how many fire.
    func testRefreshOnUnchangedExclusionSetTriggersZeroRebuilds() {
        let tap = FakeTap()
        let pids: [String: pid_t] = ["com.app.excluded": 111]
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids[bid].map { [$0] } ?? [] })

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        XCTAssertEqual(tap.excludedPIDs, [111])
        let createsAfterExclude = tap.creates

        // Simulate the storm: many `.capturing` health-change refreshes for the
        // excluded bundle, all on the SAME unchanged pid.
        for _ in 0..<8 {
            coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        }
        XCTAssertEqual(tap.creates, createsAfterExclude,
                       "an unchanged excluded set must do ZERO rebuilds however many refreshes fire — the storm cannot reignite")
        coordinator.stop()
    }

    /// A GENUINE pid change (a real relaunch: old pid dead, fresh pid) must still
    /// rebuild — but EXACTLY ONCE — and a second refresh on the settled pid is a
    /// no-op. Complements the R14 relaunch tests above by pinning the rebuild count
    /// to exactly one (the guard must not suppress a real change, nor rebuild
    /// twice).
    func testRefreshOnGenuinePIDChangeRebuildsExactlyOnce() {
        let tap = FakeTap()
        let pids = MutablePIDMap(["com.app.excluded": 111])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids.get(bid).map { [$0] } ?? [] })

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        XCTAssertEqual(tap.excludedPIDs, [111])
        let createsAfterExclude = tap.creates

        pids.set("com.app.excluded", 456)
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        XCTAssertEqual(tap.creates, createsAfterExclude + 1, "a genuine pid change rebuilds exactly once")
        XCTAssertEqual(tap.excludedPIDs, [456], "the relaunched app's fresh pid is excluded")

        // Settled: refresh again on the same pid → no further Core Audio work.
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        XCTAssertEqual(tap.creates, createsAfterExclude + 1, "the settled pid must not rebuild again")
        coordinator.stop()
    }

    /// A FAILED rebuild must not leave a baseline that suppresses the next real
    /// change (W1-T7 Fix 1 — the baseline is written ONLY on a successful commit).
    /// A relaunch's rebuild fails mid-flight → the coordinator surfaces `.failed`;
    /// after recovery via `start()` the compare guard is NOT wedged: an unchanged
    /// set still no-ops and a genuine later change still rebuilds exactly once.
    func testFailedRebuildDoesNotSuppressNextRealExclusionChange() {
        let tap = FakeTap()
        let pids = MutablePIDMap(["com.app.excluded": 111])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { bid in pids.get(bid).map { [$0] } ?? [] })

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        XCTAssertEqual(tap.excludedPIDs, [111])

        // The relaunch's rebuild fails (createAndStart throws) → `.failed`.
        tap.startError = .deviceLost(reason: "gone")
        pids.set("com.app.excluded", 456)
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        waitFor { if case .failed = coordinator.state { return true }; return false }
        XCTAssertEqual(coordinator.state, .failed(.deviceLost(reason: "gone")))

        // Recover: app now stable on 456. start() from `.failed` re-derives the
        // baseline from the LIVE set — proving the failed attempt didn't wedge it.
        tap.startError = nil
        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        XCTAssertEqual(tap.excludedPIDs, [456], "recovery excludes the current pid")
        let createsAfterRecover = tap.creates

        // Unchanged set after recovery → no rebuild (baseline is correct, not stale).
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        XCTAssertEqual(tap.creates, createsAfterRecover, "settled set after recovery must not rebuild")

        // A genuine NEW change is still applied — the earlier failure did not
        // permanently suppress future rebuilds.
        pids.set("com.app.excluded", 789)
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        XCTAssertEqual(tap.creates, createsAfterRecover + 1, "a real change after a prior failure still rebuilds once")
        XCTAssertEqual(tap.excludedPIDs, [789])
        coordinator.stop()
    }

    // MARK: - W1-T7 (Gap 1): live exclusion-membership diffing (debounced, compare-before-rebuild)

    #if canImport(AudioToolbox)

    /// Thread-safe mutable process set for the resolver closure, so a test can
    /// model an EXCLUDED browser spawning/killing an audio child between
    /// process-list notifications. Mirrors `PerAppCaptureCoordinatorTests.PidSetBox`.
    private final class PidSetBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [pid_t]
        init(_ value: [pid_t]) { self.value = value }
        func get() -> [pid_t] { lock.withLock { value } }
        func set(_ newValue: [pid_t]) { lock.withLock { value = newValue } }
    }

    private func makeCoordinator(
        tap: FakeTap,
        sink: SpySink,
        converter: FakeConverter,
        resolveProcessSet: @escaping AppProcessResolver,
        membershipDebounceInterval: DispatchTimeInterval
    ) -> NativeCaptureCoordinator {
        NativeCaptureCoordinator(
            makeTap: { tap },
            sink: sink,
            makeConverter: { _ in converter },
            resolveProcessSet: resolveProcessSet,
            muteBehavior: .mutedWhenTapped,
            membershipDebounceInterval: membershipDebounceInterval)
    }

    /// (a) An EXCLUDED app spawns a new audio-playing child mid-session (no
    /// relaunch, no bundle-ID change) → the new child pid is picked up and the
    /// tap is recreated EXACTLY ONCE with the expanded exclusion set, so the new
    /// child's audio stops leaking into the whole-system mix.
    func testExcludedAppSpawningChildMidSessionIsAddedToExclusionExactlyOnce() {
        let tap = FakeTap()
        let box = PidSetBox([111]) // the excluded browser, main pid only so far
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { _ in box.get() },
            membershipDebounceInterval: .milliseconds(300))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.browser"])
        XCTAssertEqual(tap.excludedPIDs, [111])
        let createsAfterExclude = tap.creates

        // A new tab starts playing: a fresh audio child appears under the SAME
        // bundle ID. No relaunch, no union change — only the live process set grew.
        box.set([111, 222])
        coordinator.handleMembershipChange()

        XCTAssertEqual(tap.creates, createsAfterExclude + 1,
                       "a genuine membership change recreates the tap exactly once")
        XCTAssertEqual(tap.excludedPIDs, [111, 222],
                       "the newly-spawned audio child is now excluded from the system mix")

        // Idempotence: re-diffing the now-settled set does no further work.
        coordinator.handleMembershipChange()
        XCTAssertEqual(tap.creates, createsAfterExclude + 1,
                       "the settled set must not trigger a second rebuild")
        coordinator.stop()
    }

    /// (b) THE regression-prevention property: an unchanged excluded-pid set — a
    /// duplicate process-list notification, or churn in some UNRELATED app —
    /// triggers ZERO rebuilds. A wrong equality check here would reintroduce the
    /// coreaudiod CPU storm from rebuild thrashing (the loop-breaker invariant).
    func testUnchangedExclusionSetTriggersZeroRebuilds() {
        let tap = FakeTap()
        let box = PidSetBox([111, 222])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { _ in box.get() },
            membershipDebounceInterval: .milliseconds(300))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.browser"])
        let createsAfterExclude = tap.creates

        // Resolver keeps returning the identical set (including a reorder, which
        // is NOT a change under set semantics).
        coordinator.handleMembershipChange()
        box.set([222, 111]) // same members, different order
        coordinator.handleMembershipChange()

        XCTAssertEqual(tap.creates, createsAfterExclude,
                       "no rebuild for an unchanged (or merely reordered) exclusion set")
        coordinator.stop()
    }

    /// A membership diff must only ever act while CAPTURING — a diff that lands
    /// while idle (no tap) does nothing.
    func testMembershipDiffWhileIdleIsNoOp() {
        let tap = FakeTap()
        let box = PidSetBox([111])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { _ in box.get() },
            membershipDebounceInterval: .milliseconds(300))

        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.browser"])
        box.set([111, 222])
        coordinator.handleMembershipChange()
        XCTAssertEqual(tap.creates, 0, "no tap exists yet — a membership diff must not create one")
    }

    /// Rapid spawn/kill/spawn churn within the debounce window coalesces to a
    /// single settled diff — one rebuild against the FINAL set, not one per Core
    /// Audio notification. Driven through the real debounced
    /// `handleProcessListChanged` entry point with a short injected interval.
    func testRapidExclusionChurnWithinDebounceWindowCoalescesToOneRebuild() {
        let tap = FakeTap()
        let box = PidSetBox([111])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            resolveProcessSet: { _ in box.get() },
            membershipDebounceInterval: .milliseconds(60))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.browser"])
        let createsAfterExclude = tap.creates

        // A burst of three notifications inside the 60ms window, settling on
        // [111, 333].
        box.set([111, 222]); coordinator.handleProcessListChanged()
        box.set([111]);      coordinator.handleProcessListChanged()
        box.set([111, 333]); coordinator.handleProcessListChanged()

        waitFor { tap.creates >= createsAfterExclude + 1 }
        // Give any (erroneously) uncoalesced extra rebuilds a chance to appear.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        XCTAssertEqual(tap.creates, createsAfterExclude + 1,
                       "the burst must coalesce to a single settled rebuild, not one per notification")
        XCTAssertEqual(tap.excludedPIDs, [111, 333],
                       "the coalesced diff applies the SETTLED exclusion set")
        coordinator.stop()
    }

    // MARK: - W1-T7 Fix 2: react to a pid's TRANSLATABILITY, not just pid-set membership

    /// A translator whose "translatable" pid set the test can grow at will —
    /// models an EXCLUDED-only app whose main pid is pre-seeded into the exclusion
    /// union while SILENT (present, but NOT yet translatable to a Core Audio
    /// process object) and then becomes translatable on the SAME pid when it
    /// starts playing.
    private final class TranslatabilityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var translatable: Set<pid_t>
        init(_ initial: Set<pid_t>) { self.translatable = initial }
        func setTranslatable(_ pids: Set<pid_t>) { lock.withLock { translatable = pids } }
        /// Object id for a pid == its bit pattern, but ONLY if currently
        /// translatable; an untranslatable pid contributes nothing (mirrors the
        /// real tap skipping a pid with no audio process object yet).
        func translate(_ pids: Set<pid_t>) -> Set<UInt32> {
            lock.withLock { Set(pids.filter { translatable.contains($0) }.map { UInt32(bitPattern: $0) }) }
        }
    }

    /// THE Fix 2 leak: an EXCLUDED-ONLY app (denylisted, NOT routed → no per-app
    /// tap) whose main pid is pre-seeded into the exclusion union while silent. The
    /// resolved PID SET never changes — the pid was always present — so the OLD
    /// raw-pid membership compare found no change and never rebuilt, and the app's
    /// audio leaked into the whole-system mix the moment it became audible. With
    /// the compare key now the TRANSLATED OBJECT set, the pid becoming translatable
    /// (silent→audible on the SAME pid) IS a change → the tap rebuilds and the
    /// app is re-excluded. Steady state (no translatability change) stays a no-op,
    /// so Fix 1's loop-breaker is preserved.
    func testUntranslatablePIDBecomingTranslatableReExcludesApp() {
        let tap = FakeTap()
        // The excluded-only app's main pid is ALWAYS resolved (the production
        // NSRunningApplication fallback pre-seeds it even while silent)…
        let resolvedPIDs = PidSetBox([111])
        // …but it is NOT translatable to a Core Audio object until it plays.
        let translate = TranslatabilityBox([]) // 111 present but untranslatable
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap },
            sink: SpySink(),
            makeConverter: { _ in FakeConverter() },
            resolveProcessSet: { _ in resolvedPIDs.get() },
            translatePIDs: { translate.translate($0) },
            muteBehavior: .mutedWhenTapped,
            membershipDebounceInterval: .milliseconds(300))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        // The pid is handed to the tap, but the exclusion OBJECT set (the baseline)
        // is empty — nothing translates yet, so the app currently leaks.
        XCTAssertEqual(tap.excludedPIDs, [111], "the pid is passed to the tap, but isn't a translatable object yet")
        let createsBefore = tap.creates

        // Steady-state churn with NO translatability change → ZERO rebuilds
        // (Fix 1's loop-breaker must not be defeated by the object-compare key).
        coordinator.handleMembershipChange()
        XCTAssertEqual(tap.creates, createsBefore, "no translatability change → zero rebuilds")

        // The app starts playing: the SAME main pid becomes translatable. The
        // resolved pid set is UNCHANGED ([111]) — the old compare would miss this.
        translate.setTranslatable([111])
        coordinator.handleMembershipChange()

        XCTAssertEqual(tap.creates, createsBefore + 1,
                       "a pid becoming translatable (silent→audible on the same pid) must rebuild exactly once")
        XCTAssertEqual(tap.excludedPIDs, [111],
                       "the now-translatable app is (re-)excluded from the system mix")

        // Settled: a further diff with no translatability change is a no-op.
        coordinator.handleMembershipChange()
        XCTAssertEqual(tap.creates, createsBefore + 1, "the settled translatable set must not rebuild again")
        coordinator.stop()
    }

    #endif

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

    #if canImport(AudioToolbox)
    // MARK: - pts drift self-heal (B6a): a sleep mid-tap must not silence
    // streaming until relaunch — the offset is per-tap and self-heals.

    /// A simulated 5s sleep (mach halted, CLOCK_MONOTONIC advanced 5s) must be
    /// detected: `machNanos + offset` now trails "now" by 5s, well past the
    /// ~1s threshold, so a caller must resample.
    @available(macOS 14.2, *)
    func testShouldResampleDetectsSleepDrift() {
        let machNanos: UInt64 = 100_000_000_000          // 100s of mach time
        let offsetAtTapStart: Int64 = 0                   // clocks agreed at start
        let monotonicNowAfterFiveSecondSleep: UInt64 = 105_000_000_000
        XCTAssertTrue(CoreAudioSystemTap.shouldResample(
            machNanos: machNanos,
            offset: offsetAtTapStart,
            monotonicNowNanos: monotonicNowAfterFiveSecondSleep))
    }

    /// No sleep, no drift: an offset that still agrees with "now" to well under
    /// 1s must NOT trigger a resample on every single buffer.
    @available(macOS 14.2, *)
    func testShouldResampleToleratesNoDrift() {
        let machNanos: UInt64 = 100_000_000_000
        let offset: Int64 = 0
        let monotonicNow: UInt64 = 100_050_000_000        // 50ms of normal scheduling jitter
        XCTAssertFalse(CoreAudioSystemTap.shouldResample(
            machNanos: machNanos, offset: offset, monotonicNowNanos: monotonicNow))
    }

    /// A negative offset (CLOCK_MONOTONIC behind mach-absolute, i.e. the box
    /// slept before the offset was even sampled) must be handled correctly in
    /// signed space, not wrap or crash.
    @available(macOS 14.2, *)
    func testShouldResampleHandlesNegativeOffset() {
        let machNanos: UInt64 = 50_000_000_000
        let offset: Int64 = -10_000_000_000               // monotonic trails mach by 10s
        let monotonicNowAgreeing: UInt64 = 40_000_000_000  // 50s + (-10s) = 40s: agrees
        XCTAssertFalse(CoreAudioSystemTap.shouldResample(
            machNanos: machNanos, offset: offset, monotonicNowNanos: monotonicNowAgreeing))

        let monotonicNowDrifted: UInt64 = 46_000_000_000   // now 6s off from the 40s prediction
        XCTAssertTrue(CoreAudioSystemTap.shouldResample(
            machNanos: machNanos, offset: offset, monotonicNowNanos: monotonicNowDrifted))
    }

    /// `timespec(machNanos:offset:)` pts math round-trip: a known machNanos +
    /// offset must land on the expected wall-clock seconds/nanos, including the
    /// zero-clamp for a pathological negative result.
    @available(macOS 14.2, *)
    func testTimespecMachNanosOffsetRoundTrip() {
        let ts = CoreAudioSystemTap.timespec(machNanos: 2_500_000_000, offset: 500_000_000)
        // 2.5s + 0.5s = 3.0s exactly.
        XCTAssertEqual(ts.tv_sec, 3)
        XCTAssertEqual(ts.tv_nsec, 0)

        let clamped = CoreAudioSystemTap.timespec(machNanos: 1_000_000_000, offset: -5_000_000_000)
        // Would be -4s; must clamp to zero rather than go negative.
        XCTAssertEqual(clamped.tv_sec, 0)
        XCTAssertEqual(clamped.tv_nsec, 0)
    }
    #endif

    // MARK: - W2-T1: nominal-sample-rate listener (fixes R10)

    /// (a) A nominal-rate change on the tapped device triggers EXACTLY ONE
    /// guarded rebuild — the silent-buffer recovery path (finding R10: a
    /// process tap keeps delivering all-zero buffers when the output device
    /// renegotiates its rate, e.g. a Zoom/FaceTime call grabbing the mic).
    func testNominalSampleRateChangeTriggersExactlyOneRebuild() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.start()
        let createsAfterStart = tap.creates
        XCTAssertTrue(stateIsCapturing(coordinator, sampleRate: 48000))

        tap.fireNominalSampleRateChanged(deviceID: 42, rate: 44100)

        XCTAssertEqual(tap.creates, createsAfterStart + 1,
                       "a genuine rate change recreates the tap exactly once")
        XCTAssertEqual(tap.teardowns, 1, "the stale (silent) tap must be torn down")
        coordinator.stop()
    }

    /// (b) THE regression-prevention property: an unchanged/repeated identical
    /// rate notification triggers ZERO rebuilds. A naive listener that rebuilds
    /// on every notification — even a duplicate for an unchanged rate — is
    /// exactly the failure mode that caused a confirmed coreaudiod CPU storm
    /// elsewhere in this codebase; the `(deviceID, nominalRate)`
    /// compare-before-rebuild guard is the loop-breaker.
    func testUnchangedNominalSampleRateTriggersZeroRebuilds() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.start()
        let createsAfterStart = tap.creates

        tap.fireNominalSampleRateChanged(deviceID: 42, rate: 44100)
        XCTAssertEqual(tap.creates, createsAfterStart + 1)
        let createsAfterFirstChange = tap.creates

        // Duplicate notification for the SAME device at the SAME rate — must
        // not trigger a second rebuild.
        tap.fireNominalSampleRateChanged(deviceID: 42, rate: 44100)
        tap.fireNominalSampleRateChanged(deviceID: 42, rate: 44100)

        XCTAssertEqual(tap.creates, createsAfterFirstChange,
                       "no rebuild for a repeated, unchanged rate notification")
        coordinator.stop()
    }

    /// (c) A rate change reported for an unrelated/untapped device has no
    /// effect — the `(deviceID, nominalRate)` key, not the rate alone, gates
    /// the rebuild, so a notification about some OTHER device's rate can never
    /// masquerade as a change to the tapped device.
    func testNominalSampleRateChangeOnUnrelatedDeviceHasNoEffect() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.start()
        let createsAfterStart = tap.creates

        tap.fireNominalSampleRateChanged(deviceID: 42, rate: 44100)
        let createsAfterChange = tap.creates
        XCTAssertEqual(createsAfterChange, createsAfterStart + 1)

        // A DIFFERENT device reporting the SAME rate is still a distinct key —
        // must still be treated as a change (proves the guard is keyed on the
        // tuple, not the rate alone)...
        tap.fireNominalSampleRateChanged(deviceID: 99, rate: 44100)
        XCTAssertEqual(tap.creates, createsAfterChange + 1,
                       "a different device id at the same rate is still a genuine change")

        // ...but repeating THAT exact (deviceID, rate) again is a true no-op.
        let createsAfterSecondDevice = tap.creates
        tap.fireNominalSampleRateChanged(deviceID: 99, rate: 44100)
        XCTAssertEqual(tap.creates, createsAfterSecondDevice,
                       "repeating the same (deviceID, rate) key is a no-op")
        coordinator.stop()
    }

    /// A rate notification must only ever act while CAPTURING — one that lands
    /// while idle (no tap started) does nothing, mirroring the membership-diff
    /// idle guard.
    func testNominalSampleRateChangeWhileIdleIsNoOp() {
        let tap = FakeTap()
        _ = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        tap.fireNominalSampleRateChanged(deviceID: 42, rate: 44100)
        XCTAssertEqual(tap.creates, 0, "no tap exists yet — a rate notification must not create one")
    }

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
