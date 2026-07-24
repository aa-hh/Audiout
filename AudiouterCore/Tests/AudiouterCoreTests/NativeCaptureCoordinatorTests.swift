import XCTest
@testable import AudiouterCore

#if canImport(CoreAudio)
import CoreAudio
#endif

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
        /// The `excludedProcessObjectIDs` passed to the MOST RECENT
        /// `createAndStart` call (T4/leak-fix) — lets a test assert the tap
        /// was (re)created with the right exclusion set without needing a
        /// real Core Audio process object.
        private(set) var lastExcludedProcessObjectIDs: Set<AudioObjectID> = []

        /// Test-only hook invoked synchronously at the START of `createAndStart`
        /// (before the scripted `startError`/return), i.e. while the coordinator
        /// is `.creatingTap`. Lets a test inject a `fireDeviceChange()` call (or
        /// anything else) DURING a rebuild, deterministically — no real
        /// concurrency/timing needed since `createAndStart` runs synchronously on
        /// the caller's thread in this fake. Mirrors ``FakeProcessTap``.
        var onCreateAndStart: (() -> Void)?

        func createAndStart(muteBehavior: TapMuteBehavior, excludedProcessObjectIDs: Set<AudioObjectID>) throws -> TapFormat {
            lock.lock(); createCount += 1; lastExcludedProcessObjectIDs = excludedProcessObjectIDs; lock.unlock()
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

        var teardowns: Int { lock.withLock { teardownCount } }
        var creates: Int { lock.withLock { createCount } }
        var excludedProcessObjectIDs: Set<AudioObjectID> { lock.withLock { lastExcludedProcessObjectIDs } }
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

    /// A scripted ``AudioProcessEnumerating``: hands back a fixed process list
    /// (and parent-pid map) so an ``AudioProcessResolver`` built on it resolves
    /// deterministically, with no live Core Audio.
    private struct FakeProcessEnumerator: AudioProcessEnumerating {
        let processes: [RawAudioProcess]
        var parents: [pid_t: pid_t] = [:]
        func enumerateProcesses() -> [RawAudioProcess] { processes }
        func parentPID(of pid: pid_t) -> pid_t? { parents[pid] }
    }

    /// Convenience: an ``AudioProcessResolver`` where each bundle id resolves to
    /// exactly ONE process object, at `pid = objectID` — the shape every
    /// pre-multi-process test used before the leak fix.
    private func singleProcessResolver(_ bundleIDsToObjectIDs: [String: AudioObjectID]) -> AudioProcessResolver {
        let processes = bundleIDsToObjectIDs.map { bundleID, objectID in
            RawAudioProcess(objectID: objectID, pid: pid_t(objectID), bundleID: bundleID)
        }
        return AudioProcessResolver(enumerator: FakeProcessEnumerator(processes: processes))
    }

    private func makeCoordinator(
        tap: FakeTap,
        sink: SpySink,
        converter: FakeConverter,
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: NoAudioProcesses())
    ) -> NativeCaptureCoordinator {
        NativeCaptureCoordinator(
            makeTap: { tap },
            sink: sink,
            makeConverter: { _ in converter },
            processResolver: processResolver,
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

    // MARK: - onDeviceRateRebuild fires only for a device/rate rebuild, never an
    //         exclusion-set rebuild (the "connects fast, then long silence" fix).

    /// The whole-system AirPlay session reset must fire ONLY when a device/nominal-
    /// rate change rebuilt the tap — NOT when the tap was rebuilt because the
    /// exclusion set changed. Attaching the synced-local sink adds its render pid to
    /// the exclusion set on EVERY Mac+AirPlay connect, recreating the tap; an
    /// app-route change does the same. Treating those benign rebuilds as a rate-
    /// renegotiation recapture fired a redundant removeOutput→addOutput RTP
    /// re-establish on every connect — the long silence Alec heard after an
    /// already-fast connect. `recreateTap(cause: .exclusionChange)` must stay silent;
    /// only `recreateTap(cause: .deviceOrRateChange)` (the device-change/nominal-rate
    /// listener path) may fire `onDeviceRateRebuild`.
    func testExclusionChangeRebuildDoesNotFireDeviceRateRebuildButDeviceChangeDoes() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())
        let lock = NSLock()
        var deviceRateRebuilds = 0
        coordinator.onDeviceRateRebuild = { lock.withLock { deviceRateRebuilds += 1 } }

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        XCTAssertEqual(tap.creates, 1, "first capture — no rebuild yet")
        XCTAssertEqual(lock.withLock { deviceRateRebuilds }, 0,
                       "the initial start must NOT fire onDeviceRateRebuild")

        // Exclusion-set change (models the synced-local sink attach on connect / an
        // app-route change): the tap rebuilds, but the tapped device and its clock
        // are unchanged, so NO session reset.
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.test.excluded"])
        waitFor { tap.creates >= 2 }
        XCTAssertEqual(coordinator.state, .capturing(tap.format), "the exclusion rebuild lands in .capturing")
        // Give any erroneous callback a chance to fire before asserting it didn't.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(lock.withLock { deviceRateRebuilds }, 0,
                       "an exclusion-set rebuild must NOT fire onDeviceRateRebuild — no AirPlay session reset")

        // A genuine device/nominal-rate change (the default-device / sample-rate
        // listener path) DOES fire it — the dropout the reset was built for.
        tap.fireDeviceChange()
        waitFor { lock.withLock { deviceRateRebuilds } == 1 }
        XCTAssertEqual(lock.withLock { deviceRateRebuilds }, 1,
                       "a device/nominal-rate rebuild MUST fire onDeviceRateRebuild exactly once")
        XCTAssertGreaterThanOrEqual(tap.creates, 3, "the device-change rebuild created a fresh tap")
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
        XCTAssertThrowsError(try tap.createAndStart(muteBehavior: .mutedWhenTapped, excludedProcessObjectIDs: [])) { error in
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

    // MARK: - T1: nominal-sample-rate renegotiation drives a tap rebuild (Part A1).
    //
    // The tapped output device's nominal-sample-rate renegotiation (44.1<->48kHz —
    // e.g. synced-local opening the built-in speakers at a different rate than the
    // tapped device) leaves the device's UID UNCHANGED, so the identity listener
    // (`kAudioHardwarePropertyDefaultOutputDevice`) never fires and the coordinator
    // would otherwise never recover (the tap keeps delivering buffers, but silent
    // all-zero PCM — Developer Forums 825780). `CoreAudioSystemTap.installSampleRateListener`
    // (T1) closes that gap by listening on the tapped device's own
    // `kAudioDevicePropertyNominalSampleRate` and routing the notification onto the
    // EXACT SAME `onDefaultDeviceChanged` closure `installDefaultDeviceListener` already
    // uses (see NativeCaptureCoordinator.swift: the listener block calls
    // `self?.onDefaultDeviceChanged?()`, identical to the identity listener's callback).
    // That closure is exactly what `FakeTap.fireDeviceChange()` fires — so it is the
    // correct and only hermetically-fakeable stand-in for "the nominal-rate listener
    // fired": the real listener registration itself lives on a live `AudioObjectID`
    // inside `CoreAudioSystemTap` and isn't reachable through the `SystemAudioTap`
    // seam `NativeCaptureCoordinator` is built against.

    /// A simulated nominal-sample-rate notification (fired through the same seam
    /// the real listener funnels into) drives a full tap rebuild: `recreateTap`
    /// tears the stale tap down and creates a fresh one against the new format —
    /// with NO identity/device-change API involved, mirroring the real bug where
    /// only the rate changed.
    func testNominalSampleRateNotificationTriggersTapRecreate() {
        let tap = FakeTap()
        let sink = SpySink()
        let converter = FakeConverter()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: converter)

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        XCTAssertEqual(tap.creates, 1)
        XCTAssertEqual(tap.teardowns, 0)

        // Simulate the device's nominal rate flipping (e.g. 44.1 -> 48kHz) with the
        // device UID unchanged — the fake models this as just a format change, since
        // the coordinator only sees it via the shared callback either way.
        tap.format = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()   // the nominal-sample-rate listener's real callback path

        waitFor { self.stateIsCapturing(coordinator, sampleRate: 48000) }
        XCTAssertEqual(coordinator.state, .capturing(tap.format),
                       "a nominal-rate renegotiation must rebuild the tap against the new format")
        XCTAssertEqual(tap.creates, 2, "recreateTap must create a fresh tap")
        XCTAssertGreaterThanOrEqual(tap.teardowns, 1, "the stale (silent-PCM) tap must be torn down first")

        coordinator.stop()
    }

    /// Two back-to-back nominal-rate notifications (a rapid 44.1->48->44.1 bounce,
    /// e.g. synced-local toggling the local sink on/off quickly) must each drive
    /// their own rebuild in turn — the C6 `pendingDeviceChange` coalescing guard
    /// (already covered generically by
    /// `testDeviceChangeDuringRebuildIsCoalescedAndReplayed`) rides this exact same
    /// seam, so a rate bounce is never dropped or thrashed into a stuck state.
    func testRapidNominalSampleRateBounceDrivesSequentialRebuilds() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        XCTAssertEqual(tap.creates, 1)

        tap.format = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()   // 44.1 -> 48
        waitFor { self.stateIsCapturing(coordinator, sampleRate: 48000) }

        tap.format = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()   // 48 -> 44.1, back again
        waitFor { self.stateIsCapturing(coordinator, sampleRate: 44100) }

        XCTAssertEqual(tap.creates, 3, "each rate flip must drive its own rebuild — no bounce dropped")
        XCTAssertEqual(coordinator.state, .capturing(tap.format))

        coordinator.stop()
    }

    // MARK: - T4: exclusion-list wiring (routed apps + user-excluded apps must
    // not leak into the whole-system mix tap).

    /// Changing the routed-apps set recreates the capturing tap with the
    /// correctly updated exclusion object-id list.
    func testUpdateRoutingRecreatesTapWithUpdatedExclusionObjectIDs() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111]))

        coordinator.start()
        XCTAssertEqual(tap.creates, 1)
        XCTAssertEqual(tap.excludedProcessObjectIDs, [], "no routes yet — nothing excluded")

        let routes = [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))]
        coordinator.updateRouting(appRoutes: routes, excludedBundleIDs: [])

        XCTAssertEqual(tap.creates, 2, "a route change while capturing recreates the tap")
        XCTAssertEqual(tap.excludedProcessObjectIDs, [111], "the newly-routed app's process object is excluded from the system mix")
        coordinator.stop()
    }

    /// An app flipped from `.device(id:)` back to `.currentDevice` is REMOVED
    /// from the exclusion list — it re-enters the system mix.
    func testAppFlippedBackToCurrentDeviceReentersSystemMix() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111]))

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        XCTAssertEqual(tap.excludedProcessObjectIDs, [111])
        let createsAfterRoute = tap.creates

        // The route flips back to .currentDevice — "no redirect."
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .currentDevice)],
            excludedBundleIDs: [])

        XCTAssertGreaterThan(tap.creates, createsAfterRoute, "the tap is recreated again on the flip back")
        XCTAssertEqual(tap.excludedProcessObjectIDs, [], "an app back on .currentDevice must re-enter the system mix")
        coordinator.stop()
    }

    /// A `.device`-routed app's process object never appears in the
    /// system-mix tap's exclusion-blind spot — i.e. it IS present in the
    /// exclusion list (so it can never double-send: once to its own
    /// destination via per-app capture, and again via this whole-system
    /// mixdown).
    func testDeviceRoutedAppProcessNeverLeaksIntoSystemMix() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111, "com.app.b": 222]))

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [
                AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1")),
                AppRoute(bundleID: "com.app.b", displayName: "App B", destination: .currentDevice),
            ],
            excludedBundleIDs: [])

        XCTAssertTrue(tap.excludedProcessObjectIDs.contains(111), "the .device-routed app's process must be excluded (no double-send)")
        XCTAssertFalse(tap.excludedProcessObjectIDs.contains(222), ".currentDevice apps stay in the system mix")
        coordinator.stop()
    }

    /// `.noRedirect` (the new default/unset state) is exclusion-equivalent to
    /// `.currentDevice`: neither is ever excluded from the system-wide tap. An
    /// app left "unset" must not be accidentally dropped from the system mix.
    func testNoRedirectAppStaysInSystemMixJustLikeCurrentDevice() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111, "com.app.b": 222, "com.app.c": 333]))

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [
                AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1")),
                AppRoute(bundleID: "com.app.b", displayName: "App B", destination: .currentDevice),
                AppRoute(bundleID: "com.app.c", displayName: "App C", destination: .noRedirect),
            ],
            excludedBundleIDs: [])

        XCTAssertEqual(tap.excludedProcessObjectIDs, [111],
                       "only the .device-routed app is excluded; both local states (.currentDevice AND "
                       + ".noRedirect) stay in the system mix identically")
        coordinator.stop()
    }

    /// The existing user-excluded-apps list (Settings › Audio) still works
    /// and composes correctly (UNION) with route-based exclusion.
    func testUserExcludedAppsComposeWithRouteBasedExclusion() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111, "com.app.c": 333]))

        coordinator.start()
        // Only a user-excluded app, no routes yet.
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.c"])
        XCTAssertEqual(tap.excludedProcessObjectIDs, [333])

        // Add a routed app on top — the union must include BOTH.
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: ["com.app.c"])
        XCTAssertEqual(tap.excludedProcessObjectIDs, [111, 333], "route-based and user-excluded exclusions compose (union)")
        coordinator.stop()
    }

    /// Calling `updateRouting` with an unchanged union is a no-op — it must
    /// not recreate the tap on every unrelated tick.
    func testUpdateRoutingIsNoOpWhenUnionUnchanged() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111]))

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
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111]))

        // Not capturing yet — updateRouting must not create a tap.
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        XCTAssertEqual(tap.creates, 0)

        coordinator.start()
        XCTAssertEqual(tap.creates, 1)
        XCTAssertEqual(tap.excludedProcessObjectIDs, [111], "the previously-computed exclusion set is applied on start()")
        coordinator.stop()
    }

    /// THE LEAK FIX (T3): a multi-process app (Firefox-shaped — a silent main
    /// process plus an audio-emitting child with no bundle id of its own) must
    /// have BOTH process objects excluded from the whole-system mix. Excluding
    /// only the main process (the old single-pid behavior) named the wrong
    /// process and left the real audio leaking into the system mix alongside
    /// wherever it was redirected to.
    func testMultiProcessBundleExclusionUnionsAllProcessObjects() {
        let tap = FakeTap()
        let mainPID: pid_t = 100
        let childPID: pid_t = 200
        let processResolver = AudioProcessResolver(enumerator: FakeProcessEnumerator(
            processes: [
                RawAudioProcess(objectID: 1, pid: mainPID, bundleID: "org.mozilla.firefox"),
                RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil),
            ],
            parents: [childPID: mainPID]))
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(), processResolver: processResolver)

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "org.mozilla.firefox", displayName: "Firefox", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])

        XCTAssertEqual(tap.excludedProcessObjectIDs, [1, 2],
            "both the silent main process AND the audio-emitting child must be excluded — "
            + "excluding only the main process is exactly the leak this primitive exists to fix")
        coordinator.stop()
    }

    /// The multi-process union composes correctly across MULTIPLE excluded
    /// bundle ids: each bundle's full process set contributes to the union,
    /// with no cross-bundle bleed.
    func testMultiProcessUnionAcrossMultipleExcludedBundles() {
        let tap = FakeTap()
        let processResolver = AudioProcessResolver(enumerator: FakeProcessEnumerator(
            processes: [
                RawAudioProcess(objectID: 1, pid: 100, bundleID: "org.mozilla.firefox"),
                RawAudioProcess(objectID: 2, pid: 200, bundleID: nil),
                RawAudioProcess(objectID: 3, pid: 300, bundleID: "com.google.Chrome"),
            ],
            parents: [200: 100]))
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(), processResolver: processResolver)

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [
                AppRoute(bundleID: "org.mozilla.firefox", displayName: "Firefox", destination: .device(id: "speaker-1")),
                AppRoute(bundleID: "com.google.Chrome", displayName: "Chrome", destination: .device(id: "speaker-2")),
            ],
            excludedBundleIDs: [])

        XCTAssertEqual(tap.excludedProcessObjectIDs, [1, 2, 3],
            "the union spans every excluded bundle's full process set")
        coordinator.stop()
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

    // MARK: - Telemetry (T2): start -> capturing emits captureWS/transition lines.

    /// Thread-safe capture box for a `Telemetry` test sink: the sink runs on
    /// Telemetry's own serial writer queue (a different thread than the test
    /// body), so a plain `[String]` here would race the read after
    /// `_installTestSink(nil)` drains it. Mirrors `TelemetryTests`' own
    /// `Locked<Value>`, built on this file's existing `NSLock.withLock`.
    private final class TelemetryLineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var snapshot: [String] { lock.withLock { lines } }
    }

    /// A `start()` → `.capturing` sequence must emit `captureWS`/`transition`
    /// lines for BOTH hops (`idle` → `creatingTap`, `creatingTap` →
    /// `capturing`), the second carrying the tap's format — the minimum an
    /// agent needs to reconstruct "capture came up" from the log alone, cold,
    /// with no repro (PLAN-TELEMETRY-SYSTEM.md §A).
    ///
    /// Uses `Telemetry._installTestSink` — the lightweight, no-disk seam —
    /// rather than `_resetForTesting`; never touches a real directory.
    /// Cleaned up via `addTeardownBlock` (runs even if an assertion above
    /// fails) so the sink can never leak forward into whatever test runs next
    /// in this same process (`swift test --parallel` runs one class's
    /// methods serially in one process — AGENTS.md / TelemetryTests.swift).
    func testStartEmitsCaptureWSTransitionTelemetry() {
        let capturedLines = TelemetryLineBox()
        Telemetry._installTestSink { capturedLines.append($0) }
        addTeardownBlock { Telemetry._installTestSink(nil) }

        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.start()
        XCTAssertEqual(coordinator.state, .capturing(tap.format))

        // `_installTestSink(nil)` is a synchronous barrier on Telemetry's
        // writer queue (mirrors TelemetryTests' own `drain()`) — guarantees
        // both lines above are fully written before we inspect them.
        Telemetry._installTestSink(nil)

        let lines = capturedLines.snapshot
        let idleToCreating = lines.first {
            $0.contains("\"cat\":\"captureWS\"") && $0.contains("\"evt\":\"transition\"")
                && $0.contains("\"from\":\"idle\"") && $0.contains("\"to\":\"creatingTap\"")
        }
        XCTAssertNotNil(idleToCreating, "expected an idle -> creatingTap captureWS/transition line, got: \(lines)")

        let creatingToCapturing = lines.first {
            $0.contains("\"cat\":\"captureWS\"") && $0.contains("\"evt\":\"transition\"")
                && $0.contains("\"from\":\"creatingTap\"") && $0.contains("\"to\":\"capturing\"")
        }
        XCTAssertNotNil(creatingToCapturing, "expected a creatingTap -> capturing captureWS/transition line, got: \(lines)")
        XCTAssertTrue(
            creatingToCapturing?.contains("\"format\":\"\(tap.format.sampleRate)/\(tap.format.channels)\"") ?? false,
            "the capturing transition must carry the tap format, got: \(creatingToCapturing ?? "nil")")

        coordinator.stop()
    }

    // MARK: - RMS metering (pure).

    func testRMSOfS16LE() {
        XCTAssertEqual(NativeCaptureCoordinator.rmsOfS16LE(Data()), 0)
        // A constant full-scale signal → RMS ~1.0.
        var full = Data()
        for _ in 0..<64 { withUnsafeBytes(of: Int16(32767).littleEndian) { full.append(contentsOf: $0) } }
        XCTAssertEqual(NativeCaptureCoordinator.rmsOfS16LE(full), 1.0, accuracy: 0.01)
    }

    // MARK: - Compare-before-rebuild decision (TapRebuildDecision), whole-system tap
    // (Fix 3 / CoreAudioSystemTap.installDefaultDeviceListener). The whole-system tap
    // rebuilds on device-IDENTITY change only (it has no sample-rate listener), so its
    // guard is the device variant, fed by the new `tappedOutputDeviceID` property.
    // Testing the pure decision is what makes the storm guard meaningful without a real
    // HAL — the live `defaultOutputDeviceID()` read stays a thin wrapper around it.

    #if canImport(AudioToolbox)
    func testSystemTapDeviceGuardFiresOnlyOnGenuineDeviceChange() {
        // Unchanged pinned device -> NO rebuild: the no-op notification that another
        // live tap's own rebuild fires on THIS tap must be dropped, or the taps storm
        // each other into the diagnosed coreaudiod live-lock.
        XCTAssertFalse(TapRebuildDecision.shouldRebuild(currentDeviceID: 42, trackedDeviceID: 42),
                       "an unchanged default output device must NOT rebuild the whole-system tap")
        // Genuine default-output-device change -> rebuild fires.
        XCTAssertTrue(TapRebuildDecision.shouldRebuild(currentDeviceID: 43, trackedDeviceID: 42),
                      "a genuine default-output-device change MUST rebuild the whole-system tap")
        // Failed live read (nil) -> treat as changed -> fire (never suppress on a
        // failed read).
        XCTAssertTrue(TapRebuildDecision.shouldRebuild(currentDeviceID: nil, trackedDeviceID: 42),
                      "a failed device read must be treated as changed (fire), not suppressed")
        // Fresh-tap edge: trackedDeviceID is kAudioObjectUnknown until createAggregate
        // pins a device, so a real current device must then read as changed.
        XCTAssertTrue(
            TapRebuildDecision.shouldRebuild(
                currentDeviceID: 42, trackedDeviceID: AudioObjectID(kAudioObjectUnknown)),
            "before the aggregate pins a device (tracked == unknown), a real device reads as changed")
    }
    #endif

    // MARK: - isRetryable (T16, E10 — the whole-system-tap `.failed` retry
    // `NativeBackend` drives off `onStateChange`; see `NativeBackendTests`'
    // "Whole-system capture retry" section for the end-to-end wiring tests).

    /// Every `NativeCaptureError` case is retryable except `.osUnsupported` —
    /// mirrors `PerAppCaptureError.isRetryable`'s exact split: an OS-version
    /// gate never resolves itself no matter how many times `start()` is
    /// retried, while every other failure is a plausible transient HAL hiccup
    /// (permission not yet re-granted, a device disappearing mid-setup, a bad
    /// ASBD read) worth chasing with a bounded backoff.
    func testIsRetryableExcludesOnlyOSUnsupported() {
        XCTAssertTrue(NativeCaptureError.tapCreationFailed(reason: "x").isRetryable)
        XCTAssertTrue(NativeCaptureError.aggregateDeviceFailed(reason: "x").isRetryable)
        XCTAssertTrue(NativeCaptureError.formatReadFailed(reason: "x").isRetryable)
        XCTAssertTrue(NativeCaptureError.deviceLost(reason: "x").isRetryable)
        XCTAssertFalse(NativeCaptureError.osUnsupported(minimum: "14.2").isRetryable,
                       "an OS-version gate can never be fixed by retrying — no backoff should spin on it")
    }

    // MARK: - Aggregate-rate reconciliation (converter input-rate correctness).
    //
    // ROOT CAUSE of the single-AirPlay pitch-shift bug: `CoreAudioSystemTap` reads
    // `kAudioTapPropertyFormat` off the BARE tap before it joins the aggregate, but
    // the IOProc then delivers buffers on the AGGREGATE's clock (its main sub-device
    // = the tapped output device, with sub-tap drift compensation resampling the tap
    // ONTO that clock). When those rates differ, the converter is built from a stale
    // rate and reinterprets every buffer — a sustained pitch shift. The fix reads the
    // aggregate's REAL nominal rate and corrects the format BEFORE the converter is
    // built (`reconcileFormatWithAggregate`). The reconciliation and compare-before-
    // rebuild DECISIONS are pure and pinned here; the live-aggregate divergence
    // itself (real AudioHardwareCreateProcessTap/AggregateDevice) can only be
    // exercised on real Core Audio, so end-to-end correctness rests on the live
    // re-test (plan T7). The `FakeTap` above deliberately can't reproduce it — it
    // returns a format directly with no aggregate — which is exactly why the fix and
    // its unit coverage live at the pure-decision seam.

    #if canImport(AudioToolbox)
    /// The bug direction heard live: the bare tap declares 44100 while the aggregate
    /// actually delivers 48000. `reconciledFormat` must rewrite the rate to the
    /// aggregate's 48000 so the converter is built on the real delivered rate — NOT
    /// the stale pre-aggregate 44100 that pitched playback UP ~8.8% (48000/44100).
    @available(macOS 14.2, *)
    func testReconciledFormatCorrectsStalePreAggregateRate() {
        let declared = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        let reconciled = CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: 48000)
        XCTAssertEqual(reconciled.sampleRate, 48000,
            "the converter's input rate must follow the aggregate's real delivered rate, not the pre-aggregate tap read")
        // Every rate-INDEPENDENT field is preserved (drift compensation only resamples).
        XCTAssertEqual(reconciled.channels, 2)
        XCTAssertEqual(reconciled.bitsPerSample, 32)
        XCTAssertTrue(reconciled.isFloat)
        XCTAssertFalse(reconciled.isInterleaved)
    }

    /// The reverse divergence (declared 48000, aggregate 44100) is corrected too —
    /// the fix is symmetric: it always snaps to the aggregate's real rate.
    @available(macOS 14.2, *)
    func testReconciledFormatCorrectsEitherDirection() {
        let declared = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        XCTAssertEqual(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: 44100).sampleRate, 44100)
    }

    /// When the pre-aggregate read already matches the aggregate (the common case),
    /// the format is returned UNCHANGED — no needless rewrite.
    @available(macOS 14.2, *)
    func testReconciledFormatUnchangedWhenRatesMatch() {
        let declared = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        XCTAssertEqual(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: 48000), declared)
    }

    /// An unreadable / degenerate aggregate rate must NOT clobber the format — we
    /// keep the pre-aggregate read (no regression vs. the prior behaviour).
    @available(macOS 14.2, *)
    func testReconciledFormatIgnoresUnreadableAggregateRate() {
        let declared = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        XCTAssertEqual(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: nil), declared)
        XCTAssertEqual(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: 0), declared)
        XCTAssertEqual(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: -48000), declared)
        XCTAssertEqual(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: .nan), declared)
        XCTAssertEqual(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: .infinity), declared)
    }

    /// Compare-before-rebuild loop-breaker: a nominal-rate notification that
    /// re-announces the SAME rate the converter already runs at must NOT rebuild.
    @available(macOS 14.2, *)
    func testShouldRebuildForNominalRateSkipsNoOpNotification() {
        XCTAssertFalse(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: 48000, currentEffectiveRate: 48000),
            "a set-to-same-value notification must be a no-op — no teardown+rebuild churn")
        XCTAssertFalse(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: 48000.4, currentEffectiveRate: 48000),
            "sub-Hz jitter that rounds to the same integer rate is still a no-op")
    }

    /// A genuinely different notified rate DOES rebuild; an unreadable rate falls
    /// back to the safe rebuild (can't prove it's a no-op).
    @available(macOS 14.2, *)
    func testShouldRebuildForNominalRateRebuildsOnRealChangeOrUnreadable() {
        XCTAssertTrue(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: 44100, currentEffectiveRate: 48000))
        XCTAssertTrue(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: nil, currentEffectiveRate: 48000))
        XCTAssertTrue(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: 0, currentEffectiveRate: 48000))
        XCTAssertTrue(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: .nan, currentEffectiveRate: 48000))
    }

    /// Mechanism proof with the REAL `AVFormatConverter`: the declared input rate is
    /// exactly the pitch lever. The same captured bytes, converted to the fixed 44100
    /// output, yield FEWER total frames when declared at 48000 than at 44100 — by the
    /// 44100/48000 ratio. So a converter left on a stale 44100 while the aggregate
    /// really delivers 48000 would stretch the audio (shift pitch); feeding it the
    /// reconciled real rate is what keeps playback at the correct pitch.
    ///
    /// Summed over many small buffers rather than one big one: a single
    /// `AVAudioConverter.convert` caps output at an internal ~4096-frame quantum, so
    /// one large buffer clips identically for both rates and hides the ratio. Small
    /// buffers stay under the quantum and the sum converges on the steady-state
    /// rate ratio (per-call priming latency washes out over the run).
    @available(macOS 14.2, *)
    func testConverterOutputLengthScalesWithDeclaredInputRate() {
        let framesPerBuffer = 2048
        let iterations = 32
        let planar = Self.planarFloat32Stereo(frameCount: framesPerBuffer)
        let buffer = CapturedBuffer(channelData: planar, frameCount: framesPerBuffer, pts: timespec())

        let at44100 = AVFormatConverter(from: TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false))
        let at48000 = AVFormatConverter(from: TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false))

        var frames44 = 0   // interleaved S16LE stereo = 4 bytes/frame
        var frames48 = 0
        for _ in 0..<iterations {
            if let out = at44100.convertToAirPlayPCM(buffer) { frames44 += out.count / 4 }
            if let out = at48000.convertToAirPlayPCM(buffer) { frames48 += out.count / 4 }
        }
        XCTAssertGreaterThan(frames44, 0)
        XCTAssertGreaterThan(frames48, 0)
        XCTAssertLessThan(frames48, frames44,
            "a higher declared input rate yields fewer 44100 output frames — the exact pitch lever this fix corrects")
        let ratio = Double(frames48) / Double(frames44)
        XCTAssertEqual(ratio, 44100.0 / 48000.0, accuracy: 0.01,
            "total output length must scale by the declared-rate ratio (44100/48000), confirming rate == pitch")
    }
    #endif

    // MARK: - utils

    private func timespecToNanos(_ ts: timespec) -> UInt64 {
        UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    private func stateIsCapturing(_ c: NativeCaptureCoordinator, sampleRate: Int) -> Bool {
        if case .capturing(let f) = c.state { return f.sampleRate == sampleRate }
        return false
    }

    /// Two planar Float32 stereo channel buffers of `frameCount` frames each (a mild
    /// sine, so it's non-degenerate signal), for the real-`AVFormatConverter`
    /// mechanism test. Non-interleaved = one `Data` per channel, matching the tap's
    /// stereo-mixdown layout.
    private static func planarFloat32Stereo(frameCount: Int) -> [Data] {
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let s = Float(sin(Double(i) * 0.05)) * 0.25
            left[i] = s
            right[i] = s
        }
        return [left.withUnsafeBytes { Data($0) }, right.withUnsafeBytes { Data($0) }]
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
