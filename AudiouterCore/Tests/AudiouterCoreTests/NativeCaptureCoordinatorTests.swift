import Foundation
import Testing
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
/// bug.
///
/// Nested inside `SerializedSharedState` (cookbook §18): `testStartEmitsCaptureWSTransitionTelemetry`
/// installs `Telemetry`'s process-global test sink, which would otherwise race
/// every other suite doing the same under swift-testing's concurrent-in-one-
/// process model.
extension SerializedSharedState {
    @Suite struct NativeCaptureCoordinatorTests {

    // MARK: Doubles

    /// A tap the test drives directly: `createAndStart` returns a scripted format
    /// (or throws a scripted error), and `pushBuffer`/`fireDeviceChange` inject the
    /// IOProc-thread callbacks. Records teardown so the leak fix is observable.
    /// A process-wide ordered log of tap create/teardown/onBuffer-wire events across
    /// MULTIPLE ``FakeTap`` instances — the only way to observe make-before-break
    /// ordering (new tap created BEFORE old torn down; delivery wired only AFTER old
    /// gone), since a single reused tap can't distinguish "the old" from "the new".
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        func record(_ e: String) { lock.withLock { events.append(e) } }
        var all: [String] { lock.withLock { events } }
        /// First index of an event, or nil. Used to assert relative ordering.
        func index(of e: String) -> Int? { lock.withLock { events.firstIndex(of: e) } }
    }

    /// Hands out a fixed sequence of distinct ``FakeTap`` instances (old, then new,
    /// …), so a make-before-break test can tell the two taps apart. Extra calls
    /// (e.g. a coalesced replay) reuse the last tap.
    private final class SequencedTaps: @unchecked Sendable {
        private let lock = NSLock()
        private let taps: [FakeTap]
        private var i = 0
        init(_ taps: [FakeTap]) { self.taps = taps }
        func next() -> FakeTap { lock.withLock { let t = taps[min(i, taps.count - 1)]; i += 1; return t } }
    }

    private final class FakeTap: SystemAudioTap, @unchecked Sendable {
        /// Records `onBuffer#<id>=<wired?>` to the shared ``EventLog`` on every
        /// assignment, so a test can prove delivery is wired only AFTER the old tap
        /// is torn down (the no-double-capture guardrail).
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)? {
            didSet { eventLog?.record("onBuffer#\(id)=\(onBuffer != nil)") }
        }
        var onDefaultDeviceChanged: (@Sendable () -> Void)?

        /// Optional shared ordering log + per-instance id (default 0 / nil → the
        /// single-reused-tap tests below are unaffected).
        var id = 0
        var eventLog: EventLog?

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
            eventLog?.record("create#\(id)")
            onCreateAndStart?()
            if let startError { throw startError }
            // Faithful to the real IOProc: it snapshots `onBuffer` BY VALUE at start
            // (`let onBuffer = self.onBuffer`) and delivers through that snapshot, so a
            // handler assigned AFTER createAndStart is NEVER seen. Capturing it here
            // (not reading the live property in `pushBuffer`) is what lets a test catch
            // the "onBuffer wired too late → permanent silence" class of bug.
            lock.lock(); started = true; capturedOnBuffer = onBuffer; lock.unlock()
            return format
        }

        /// The IOProc's start-time snapshot of `onBuffer` — see `createAndStart`.
        private var capturedOnBuffer: (@Sendable (CapturedBuffer) -> Void)?

        func teardown() {
            lock.lock(); teardownCount += 1; started = false; lock.unlock()
            eventLog?.record("teardown#\(id)")
        }

        /// What this fake reports as the device it's anchored to
        /// (``SystemAudioTap/tappedDeviceID``). Left nil by default, modelling a tap
        /// that can't say — the protocol's own default. A test that cares about clock
        /// re-anchoring sets it, and may change it from inside `onCreateAndStart` to
        /// model the default output device moving mid-rebuild.
        private var _deviceID: AudioObjectID?
        var tappedDeviceID: AudioObjectID? { lock.withLock { _deviceID } }
        func setTappedDeviceID(_ id: AudioObjectID?) { lock.withLock { _deviceID = id } }
        func setFormat(_ f: TapFormat) { lock.withLock { format = f } }

        /// Deliver through the START-TIME snapshot, not the live property — the real
        /// IOProc only ever calls the handler it captured at createAndStart.
        func pushBuffer(_ b: CapturedBuffer) { lock.withLock { capturedOnBuffer }?(b) }
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

    /// A MUTABLE ``AudioProcessEnumerating`` for the W1-T7 relaunch/membership
    /// tests: the returned process list can be swapped mid-test (an excluded app
    /// relaunching with a new pid, or spawning an audio child) so the resolver's
    /// output genuinely CHANGES across calls, driving a compare-before-rebuild.
    private final class MutableProcessEnumerator: AudioProcessEnumerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _processes: [RawAudioProcess]
        init(_ processes: [RawAudioProcess]) { _processes = processes }
        func set(_ processes: [RawAudioProcess]) { lock.withLock { _processes = processes } }
        func enumerateProcesses() -> [RawAudioProcess] { lock.withLock { _processes } }
        func parentPID(of pid: pid_t) -> pid_t? { nil }
    }

    /// One process object for bundle `bundleID`, with `pid == objectID` — the same
    /// shape ``singleProcessResolver`` uses, but as a raw value the mutable
    /// enumerator can hold and swap.
    private func rawProcess(_ objectID: AudioObjectID, _ bundleID: String) -> RawAudioProcess {
        RawAudioProcess(objectID: objectID, pid: pid_t(objectID), bundleID: bundleID)
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
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: NoAudioProcesses()),
        membershipDebounceInterval: DispatchTimeInterval = .milliseconds(300)
    ) -> NativeCaptureCoordinator {
        NativeCaptureCoordinator(
            makeTap: { tap },
            sink: sink,
            makeConverter: { _ in converter },
            processResolver: processResolver,
            muteBehavior: .mutedWhenTapped,
            membershipDebounceInterval: membershipDebounceInterval,
            // Hermetic: never register the real HAL process-object-list listener in
            // tests. Membership diffing is driven directly via
            // `handleMembershipChange()` / `handleProcessListChanged()`.
            installsProcessListListener: false
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

    @Test func createBuffersConvertForwardDeviceChangeStop() {
        let tap = FakeTap()
        let sink = SpySink()
        let converter = FakeConverter()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: converter)

        // 1) create
        coordinator.start()
        #expect(coordinator.state == .capturing(tap.format))
        #expect(tap.creates == 1)

        // 2) buffers with ADVANCING mHostTime are converted and forwarded, pts intact.
        tap.pushBuffer(buffer(hostTime: 1_000_000_000))
        tap.pushBuffer(buffer(hostTime: 2_000_000_000))
        waitFor { sink.forwarded.count == 2 }
        #expect(sink.forwarded.count == 2, "each converted buffer is forwarded to the sink")
        #expect(converter.converts == 2)
        // The pts the coordinator forwards is the buffer's own capture-clock pts.
        #expect(sink.forwarded[0].pts.tv_sec == 1)
        #expect(sink.forwarded[1].pts.tv_sec == 2)
        #expect(
            timespecToNanos(sink.forwarded[1].pts) > timespecToNanos(sink.forwarded[0].pts),
            "pts must advance with the capture clock")

        // 3) default-output-device change recreates the tap against the new format.
        tap.format = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()
        waitFor { self.stateIsCapturing(coordinator, sampleRate: 44100) }
        #expect(coordinator.state == .capturing(tap.format))
        #expect(tap.teardowns >= 1, "the old tap is torn down on device change")
        #expect(tap.creates == 2, "a fresh tap is created for the new device")

        // 4) stop tears the tap down and returns to idle.
        coordinator.stop()
        #expect(coordinator.state == .idle)
        #expect(tap.teardowns >= 2)
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
    @Test func exclusionChangeRebuildDoesNotFireDeviceRateRebuildButDeviceChangeDoes() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())
        let lock = NSLock()
        var deviceRateRebuilds = 0
        coordinator.onDeviceRateRebuild = { lock.withLock { deviceRateRebuilds += 1 } }

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        #expect(tap.creates == 1, "first capture — no rebuild yet")
        #expect(lock.withLock { deviceRateRebuilds } == 0,
                "the initial start must NOT fire onDeviceRateRebuild")

        // Exclusion-set change (models the synced-local sink attach on connect / an
        // app-route change): the tap rebuilds, but the tapped device and its clock
        // are unchanged, so NO session reset.
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.test.excluded"])
        waitFor { tap.creates >= 2 }
        #expect(coordinator.state == .capturing(tap.format), "the exclusion rebuild lands in .capturing")
        // Give any erroneous callback a chance to fire before asserting it didn't.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        #expect(lock.withLock { deviceRateRebuilds } == 0,
                "an exclusion-set rebuild must NOT fire onDeviceRateRebuild — no AirPlay session reset")

        // A genuine device/nominal-rate change (the default-device / sample-rate
        // listener path) DOES fire it — the dropout the reset was built for.
        tap.fireDeviceChange()
        waitFor { lock.withLock { deviceRateRebuilds } == 1 }
        #expect(lock.withLock { deviceRateRebuilds } == 1,
                "a device/nominal-rate rebuild MUST fire onDeviceRateRebuild exactly once")
        #expect(tap.creates >= 3, "the device-change rebuild created a fresh tap")
    }

    /// The completeness gap in the surgical reset trigger: an exclusion-cause rebuild
    /// that re-anchors the clock ANYWAY must still reset the AirPlay session.
    ///
    /// The old tap's `teardown()` takes its default-device listener with it, and the
    /// new tap only arms one inside `createAndStart`. A default-output-device change
    /// landing in that window is delivered to nobody: the rebuild silently comes back
    /// up on a different device's clock while the receivers hold the old timeline, and
    /// because the rebuild was nominally an `.exclusionChange` (a plain connect, an
    /// exclusion toggle) nothing reset them. The result is silence that only heals if
    /// some later device/rate event happens to fire a reset.
    ///
    /// Modelled by moving the fake's device id from INSIDE `createAndStart` — exactly
    /// the un-listened window — during a rebuild triggered by an exclusion change.
    @Test func exclusionRebuildThatReAnchorsOntoADifferentDeviceStillResets() {
        let tap = FakeTap()
        tap.setTappedDeviceID(AudioObjectID(71))     // built-in, say
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())
        let lock = NSLock()
        var deviceRateRebuilds = 0
        coordinator.onDeviceRateRebuild = { lock.withLock { deviceRateRebuilds += 1 } }

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        #expect(lock.withLock { deviceRateRebuilds } == 0, "the initial start never resets")

        // The default output device moves while neither tap holds a listener: the
        // rebuild's own createAndStart is that window.
        tap.onCreateAndStart = { tap.setTappedDeviceID(AudioObjectID(72)) }   // now the USB DAC
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.test.excluded"])
        waitFor { tap.creates >= 2 }
        waitFor { lock.withLock { deviceRateRebuilds } == 1 }

        #expect(lock.withLock { deviceRateRebuilds } == 1,
                Comment(rawValue: "an exclusion-cause rebuild that came up on a DIFFERENT device must still reset the whole-system AirPlay session — the receivers are anchored to the old device's clock, and no cause-based trigger can see this because the device moved while nothing was "
                    + "listening"))
    }

    /// The other half of the same guarantee, and the regression guard for the fix
    /// above not undoing what the surgical trigger bought: an exclusion rebuild that
    /// comes back up on the SAME device at the SAME rate must still stay silent. This
    /// asserts it with a tap that positively REPORTS its device, so the silence is a
    /// real like-for-like compare rather than the `nil`-abstains default doing the
    /// work (which is all `testExclusionChangeRebuildDoesNotFireDeviceRateRebuildButDeviceChangeDoes`
    /// can prove).
    @Test func exclusionRebuildOnTheSameDeviceStillDoesNotReset() {
        let tap = FakeTap()
        tap.setTappedDeviceID(AudioObjectID(71))
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())
        let lock = NSLock()
        var deviceRateRebuilds = 0
        coordinator.onDeviceRateRebuild = { lock.withLock { deviceRateRebuilds += 1 } }

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }

        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.test.excluded"])
        waitFor { tap.creates >= 2 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))   // let a wrong reset arrive

        #expect(lock.withLock { deviceRateRebuilds } == 0,
                Comment(rawValue: "a like-for-like exclusion rebuild must NOT reset — that spurious per-connect RTP re-establish is the \"connects fast, then a long silence\" bug"))
    }

    /// A rate renegotiation that slips through the same un-listened window (the tap
    /// comes back up at 48 kHz where it was at 44.1) must reset too — the documented
    /// dropout cause, arriving without a device-change notification to announce it.
    @Test func exclusionRebuildThatComesUpAtADifferentRateStillResets() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())
        let lock = NSLock()
        var deviceRateRebuilds = 0
        coordinator.onDeviceRateRebuild = { lock.withLock { deviceRateRebuilds += 1 } }

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }

        tap.onCreateAndStart = {
            tap.setFormat(TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32,
                                    isFloat: true, isInterleaved: false))
        }
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.test.excluded"])
        waitFor { tap.creates >= 2 }
        waitFor { lock.withLock { deviceRateRebuilds } == 1 }

        #expect(lock.withLock { deviceRateRebuilds } == 1,
                Comment(rawValue: "a rebuild that came up at a different nominal rate must reset the session, whatever the rebuild was nominally for"))
    }

    // MARK: - A dropped (nil) conversion is not forwarded.

    @Test func droppedConversionIsNotForwarded() {
        let tap = FakeTap()
        let sink = SpySink()
        let converter = FakeConverter()
        converter.dropAll = true
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: converter)

        coordinator.start()
        tap.pushBuffer(buffer(hostTime: 1_000_000_000))
        // Give the delivery a beat; nothing should be forwarded.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(sink.forwarded.isEmpty, "a nil conversion must be dropped, not forwarded")
        coordinator.stop()
    }

    // MARK: - Tap-creation failure surfaces as .failed AND tears the tap down.

    @Test func tapCreationFailureSurfacesErrorAndTearsDown() {
        let tap = FakeTap()
        tap.startError = .tapCreationFailed(reason: "denied")
        let sink = SpySink()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: FakeConverter())

        coordinator.start()
        #expect(coordinator.state == .failed(.tapCreationFailed(reason: "denied")))
        // A failed createAndStart must not leak the tap — teardown is called.
        #expect(tap.teardowns >= 1, "a failed start must tear the tap down (no leak)")
    }

    // MARK: - UnavailableSystemTap (macOS < 14.2) surfaces .osUnsupported, not
    // .tapCreationFailed — the userMessage must not carry permission advice for
    // a version-gate failure.

    #if canImport(AudioToolbox)
    @Test func unavailableSystemTapSurfacesOSUnsupported() {
        let tap = UnavailableSystemTap()
        #expect(throws: NativeCaptureError.osUnsupported(minimum: "14.2")) {
            try tap.createAndStart(muteBehavior: .mutedWhenTapped, excludedProcessObjectIDs: [])
        }
    }

    @Test func osUnsupportedUserMessageHasNoPermissionAdvice() {
        let message = NativeCaptureError.osUnsupported(minimum: "14.2").userMessage
        #expect(message.contains("14.2"), "message should state the version requirement")
        #expect(!message.localizedCaseInsensitiveContains("permission"),
                "an OS-version failure is not fixable by granting permission")
        #expect(!message.localizedCaseInsensitiveContains("System Settings"),
                "an OS-version failure should not send the user to the TCC panel")
    }

    @Test func unavailableSystemTapDrivenThroughCoordinatorSurfacesOSUnsupported() {
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
        #expect(coordinator.state == .failed(.osUnsupported(minimum: "14.2")))
    }
    #endif

    // MARK: - C4: a NaN/zero sample-rate tap format lands in .failed, never a trap.

    /// A degenerate tap format (zero sample rate — the value a NaN ASBD rate
    /// collapses to, and the value that makes the converter's resample ratio
    /// infinite / its AVAudioFrameCount conversion trap) must be rejected into
    /// `.failed`, not committed to `.capturing`.
    @Test func zeroSampleRateFormatLandsInFailed() {
        let tap = FakeTap()
        tap.format = TapFormat(sampleRate: 0, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        let sink = SpySink()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: FakeConverter())

        coordinator.start()
        guard case .failed(.formatReadFailed) = coordinator.state else {
            Issue.record("a zero/NaN sample-rate format must land in .failed(.formatReadFailed), got \(coordinator.state)")
            return
        }
        // The invalid-format tap must not leak — it is torn down.
        #expect(tap.teardowns >= 1, "an invalid-format start must tear the tap down (no leak)")
    }

    // MARK: - Device-change recreation failure surfaces as .failed.

    @Test func deviceChangeRecreationFailureSurfacesError() {
        let tap = FakeTap()
        let sink = SpySink()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: FakeConverter())

        coordinator.start()
        #expect(coordinator.state == .capturing(tap.format))

        // Next createAndStart (the recreation) fails.
        tap.startError = .deviceLost(reason: "gone")
        tap.fireDeviceChange()
        waitFor { if case .failed = coordinator.state { return true } else { return false } }
        #expect(coordinator.state == .failed(.deviceLost(reason: "gone")))
    }

    // MARK: - Make-before-break tap rebuild for device-IDENTITY changes
    //         (audio-leak-on-device-switch fix).

    /// Builds a coordinator over a SEQUENCE of distinct fake taps (old, then new)
    /// sharing one ``EventLog``, with an injected default-output-device resolver —
    /// the seams a make-before-break ordering test needs.
    private func makeSequencedCoordinator(
        _ taps: SequencedTaps,
        sink: PCMSink = SpySink(),
        resolveDefaultOutputDeviceID: @escaping @Sendable () -> AudioObjectID?
    ) -> NativeCaptureCoordinator {
        NativeCaptureCoordinator(
            makeTap: { taps.next() },
            sink: sink,
            makeConverter: { _ in FakeConverter() },
            resolveDefaultOutputDeviceID: resolveDefaultOutputDeviceID,
            muteBehavior: .mutedWhenTapped,
            installsProcessListListener: false
        )
    }

    /// A device-IDENTITY change (new default output device != the one the old tap was
    /// anchored to) rebuilds MAKE-BEFORE-BREAK: the new tap/aggregate is created and
    /// started — muting the NEW device — BEFORE the old tap is torn down, so the new
    /// default device is never left untapped/unmuted for the whole old-teardown gap
    /// (the `.mutedWhenTapped` leak). Delivery (`onBuffer`) is wired BEFORE
    /// `createAndStart`, because the real IOProc snapshots the handler at start — a
    /// handler wired later is never seen and the tap goes permanently silent (the
    /// bug an adversarial review caught). Double-capture during the overlap is
    /// prevented not by deferring `onBuffer` but by `handleBuffer`'s empty-converter
    /// gate, so the new tap must ACTUALLY DELIVER once the rebuild commits.
    @Test func identityChangeRebuildsMakeBeforeBreak() {
        let log = EventLog()
        let sink = SpySink()
        let old = FakeTap(); old.id = 1; old.eventLog = log; old.setTappedDeviceID(AudioObjectID(71))
        let new = FakeTap(); new.id = 2; new.eventLog = log; new.setTappedDeviceID(AudioObjectID(72))
        let coordinator = makeSequencedCoordinator(
            SequencedTaps([old, new]), sink: sink,
            // The new default output device (72) differs from the old tap's (71).
            resolveDefaultOutputDeviceID: { AudioObjectID(72) })

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        #expect(old.creates == 1)

        old.fireDeviceChange()   // identity change -> recreateTap(.deviceOrRateChange)
        waitFor { self.stateIsCapturing(coordinator, sampleRate: new.format.sampleRate) && new.creates == 1 }

        guard let createNew = log.index(of: "create#2"),
              let teardownOld = log.index(of: "teardown#1"),
              let wireNew = log.index(of: "onBuffer#2=true") else {
            Issue.record("expected new-tap create, old-tap teardown, and new-tap onBuffer wiring; log = \(log.all)")
            return
        }
        #expect(createNew < teardownOld,
                "MAKE-BEFORE-BREAK: the new tap must be created+started BEFORE the old is torn down (log = \(log.all))")
        #expect(wireNew < createNew,
                "SNAPSHOT SAFETY: onBuffer must be wired BEFORE createAndStart — the real IOProc snapshots it at start (log = \(log.all))")

        // The regression guard for the permanent-silence bug: a buffer captured AFTER
        // the make-before-break rebuild must actually reach the sink. Against the
        // buggy (deferred-onBuffer) ordering the fake's start-time snapshot is nil, so
        // this delivers nothing and the assertion fails.
        let before = sink.writes.count
        new.pushBuffer(buffer(hostTime: 1_000_000))
        #expect(sink.writes.count > before,
                "the rebuilt tap must DELIVER buffers to the sink, not go silent")

        coordinator.stop()
    }

    /// The deliberate scope limit: a SAME-device rebuild (rate-only renegotiation —
    /// the default output device id is unchanged) must KEEP break-before-make, so two
    /// aggregates never sit on ONE physical device mid-rate-renegotiation. Old tap
    /// torn down BEFORE the new one is created.
    @Test func sameDeviceRateRebuildStaysBreakBeforeMake() {
        let log = EventLog()
        let old = FakeTap(); old.id = 1; old.eventLog = log; old.setTappedDeviceID(AudioObjectID(71))
        let new = FakeTap(); new.id = 2; new.eventLog = log; new.setTappedDeviceID(AudioObjectID(71))
        let coordinator = makeSequencedCoordinator(
            SequencedTaps([old, new]),
            // Same default output device (71) as the old tap: a rate-only rebuild.
            resolveDefaultOutputDeviceID: { AudioObjectID(71) })

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }

        old.fireDeviceChange()   // same-device rebuild
        waitFor { new.creates == 1 }
        waitFor { if case .capturing = coordinator.state { return true }; return false }

        guard let teardownOld = log.index(of: "teardown#1"),
              let createNew = log.index(of: "create#2") else {
            Issue.record("expected an old-tap teardown and a new-tap create; log = \(log.all)")
            return
        }
        #expect(teardownOld < createNew,
                "BREAK-BEFORE-MAKE (unchanged): a same-device rate rebuild must tear the old tap down BEFORE creating the new one (log = \(log.all))")

        coordinator.stop()
    }

    /// Failure unwind on the make-before-break path: if the new tap's `createAndStart`
    /// throws, the old tap is still alive — BOTH must be torn down (never two taps,
    /// never a dangling one) and the coordinator lands in `.failed`.
    @Test func identityChangeCreateFailureTearsDownBothTaps() {
        let log = EventLog()
        let old = FakeTap(); old.id = 1; old.eventLog = log; old.setTappedDeviceID(AudioObjectID(71))
        let new = FakeTap(); new.id = 2; new.eventLog = log; new.setTappedDeviceID(AudioObjectID(72))
        new.startError = .deviceLost(reason: "gone")
        let coordinator = makeSequencedCoordinator(
            SequencedTaps([old, new]),
            resolveDefaultOutputDeviceID: { AudioObjectID(72) })

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }

        old.fireDeviceChange()   // identity change; the new createAndStart throws
        waitFor { if case .failed = coordinator.state { return true }; return false }
        #expect(coordinator.state == .failed(.deviceLost(reason: "gone")))
        // No tap left dangling: the failed new tap AND the still-alive old tap are both torn down.
        #expect(new.teardowns >= 1, "the failed new tap must be torn down")
        #expect(old.teardowns >= 1, "the old tap (still alive on the make-before-break path) must be torn down too")
    }

    // MARK: - STABILITY(C6) coalescing: a device-change notification arriving mid-rebuild
    // (.creatingTap) must be coalesced (pendingDeviceChange) and replayed once the rebuild
    // lands in .capturing, not dropped. Whole-system port of PerAppCaptureCoordinator's fix.

    @Test func deviceChangeDuringRebuildIsCoalescedAndReplayed() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        #expect(tap.creates == 1)

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
        #expect(
            tap.creates >= 3,
            "a device-change notification arriving mid-rebuild (.creatingTap) must be coalesced and replayed once the rebuild lands in .capturing, not dropped")

        waitFor { if case .capturing = coordinator.state { return true }; return false }
        #expect(coordinator.state == .capturing(tap.format))

        coordinator.stop()
    }

    // MARK: - T1: nominal-sample-rate renegotiation drives a tap rebuild (Part A1).
    //
    // The tapped output device's nominal-sample-rate renegotiation (44.1<->48kHz —
    // e.g. synced-local opening the built-in speakers at a different rate than the
    // tapped device) leaves the device's UID UNCHANGED, so the identity listener
    // (`kAudioHardwarePropertyDefaultOutputDevice`) never fires and the coordinator
    // would otherwise never recover (the tap keeps delivering buffers, but silent
    // all-zero PCM — Developer Forums 825780). `CoreAudioSystemTap.subscribeToDefaultOutput`
    // (T1) closes that gap by observing the tapped device's own
    // `kAudioDevicePropertyNominalSampleRate` through ``DefaultOutputDeviceMonitor``
    // and routing the notification onto the EXACT SAME `onDefaultDeviceChanged`
    // closure the device-identity change uses (see NativeCaptureCoordinator.swift:
    // the single `onChange` closure calls
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
    @Test func nominalSampleRateNotificationTriggersTapRecreate() {
        let tap = FakeTap()
        let sink = SpySink()
        let converter = FakeConverter()
        let coordinator = makeCoordinator(tap: tap, sink: sink, converter: converter)

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        #expect(tap.creates == 1)
        #expect(tap.teardowns == 0)

        // Simulate the device's nominal rate flipping (e.g. 44.1 -> 48kHz) with the
        // device UID unchanged — the fake models this as just a format change, since
        // the coordinator only sees it via the shared callback either way.
        tap.format = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()   // the nominal-sample-rate listener's real callback path

        waitFor { self.stateIsCapturing(coordinator, sampleRate: 48000) }
        #expect(coordinator.state == .capturing(tap.format),
                "a nominal-rate renegotiation must rebuild the tap against the new format")
        #expect(tap.creates == 2, "recreateTap must create a fresh tap")
        #expect(tap.teardowns >= 1, "the stale (silent-PCM) tap must be torn down first")

        coordinator.stop()
    }

    /// Two back-to-back nominal-rate notifications (a rapid 44.1->48->44.1 bounce,
    /// e.g. synced-local toggling the local sink on/off quickly) must each drive
    /// their own rebuild in turn — the C6 `pendingDeviceChange` coalescing guard
    /// (already covered generically by
    /// `testDeviceChangeDuringRebuildIsCoalescedAndReplayed`) rides this exact same
    /// seam, so a rate bounce is never dropped or thrashed into a stuck state.
    @Test func rapidNominalSampleRateBounceDrivesSequentialRebuilds() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        #expect(tap.creates == 1)

        tap.format = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()   // 44.1 -> 48
        waitFor { self.stateIsCapturing(coordinator, sampleRate: 48000) }

        tap.format = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()   // 48 -> 44.1, back again
        waitFor { self.stateIsCapturing(coordinator, sampleRate: 44100) }

        #expect(tap.creates == 3, "each rate flip must drive its own rebuild — no bounce dropped")
        #expect(coordinator.state == .capturing(tap.format))

        coordinator.stop()
    }

    // MARK: - T4: exclusion-list wiring (routed apps + user-excluded apps must
    // not leak into the whole-system mix tap).

    /// Changing the routed-apps set recreates the capturing tap with the
    /// correctly updated exclusion object-id list.
    @Test func updateRoutingRecreatesTapWithUpdatedExclusionObjectIDs() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111]))

        coordinator.start()
        #expect(tap.creates == 1)
        #expect(tap.excludedProcessObjectIDs == [], "no routes yet — nothing excluded")

        let routes = [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))]
        coordinator.updateRouting(appRoutes: routes, excludedBundleIDs: [])

        #expect(tap.creates == 2, "a route change while capturing recreates the tap")
        #expect(tap.excludedProcessObjectIDs == [111], "the newly-routed app's process object is excluded from the system mix")
        coordinator.stop()
    }

    /// An app flipped from `.device(id:)` back to `.currentDevice` is REMOVED
    /// from the exclusion list — it re-enters the system mix.
    @Test func appFlippedBackToCurrentDeviceReentersSystemMix() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111]))

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        #expect(tap.excludedProcessObjectIDs == [111])
        let createsAfterRoute = tap.creates

        // The route flips back to .currentDevice — "no redirect."
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .currentDevice)],
            excludedBundleIDs: [])

        #expect(tap.creates > createsAfterRoute, "the tap is recreated again on the flip back")
        #expect(tap.excludedProcessObjectIDs == [], "an app back on .currentDevice must re-enter the system mix")
        coordinator.stop()
    }

    /// LIVE BUG (2026-07-26): a `.currentDevice` per-app route is rendered by
    /// `LocalPlaybackEngine` through THIS app's own `AVAudioEngine`, into the very
    /// device the whole-system tap taps. If our own process isn't excluded, the
    /// `.mutedWhenTapped` tap re-captures that render and MUTES it — the app went
    /// silent on the Mac's speakers and came out the AirPlay selection instead.
    ///
    /// The guard that closes this is the UNCONDITIONAL self-exclude in the shared
    /// resolve helper, so the whole `.currentDevice` lifecycle is covered without
    /// anyone staging a render pid. This pins the two properties that fall out of
    /// that and that a conditional, separately-staged render pid would break:
    /// the exclusion survives the route going AWAY (nothing has to remember to
    /// re-arm it), and arming a `.currentDevice` route costs the tap EXACTLY ONE
    /// rebuild — a second staging call for our own pid would rebuild the tap a
    /// second time against a byte-identical exclusion set, which on this code path
    /// is an audible dropout for nothing.
    @Test func currentDeviceRouteLifecycleKeepsOwnProcessExcludedWithOneRebuild() {
        let tap = FakeTap()
        let ownProcess = RawAudioProcess(objectID: 900, pid: getpid(), bundleID: "com.audiouter.test-host")
        let routedProcess = RawAudioProcess(objectID: 111, pid: 111, bundleID: "com.app.a")
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(
                enumerator: FakeProcessEnumerator(processes: [ownProcess, routedProcess])))

        coordinator.start()
        #expect(tap.excludedProcessObjectIDs == [900],
                "our own process is excluded from the first tap on, before anything routes")
        let createsBeforeLocal = tap.creates

        // A `.currentDevice` route goes live. `NativeBackend` unions those bundle
        // ids into the exclusion set (they play via `localPlaybackEngine`, not the
        // AirPlay mix) — one call, one rebuild.
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .currentDevice)],
            excludedBundleIDs: ["com.app.a"])

        #expect(tap.creates == createsBeforeLocal + 1,
                "arming a .currentDevice route must rebuild the tap exactly once")
        #expect(tap.excludedProcessObjectIDs == [111, 900],
                "the locally-rendered app AND our own render process must both be excluded")

        // The route goes away. Our own process stays excluded regardless — the
        // guard is unconditional, so nothing can strand the echo back on.
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: [])
        #expect(tap.excludedProcessObjectIDs == [900],
                "the app re-enters the system mix; our own process never does")
        coordinator.stop()
    }

    /// A `.device`-routed app's process object never appears in the
    /// system-mix tap's exclusion-blind spot — i.e. it IS present in the
    /// exclusion list (so it can never double-send: once to its own
    /// destination via per-app capture, and again via this whole-system
    /// mixdown).
    @Test func deviceRoutedAppProcessNeverLeaksIntoSystemMix() {
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

        #expect(tap.excludedProcessObjectIDs.contains(111), "the .device-routed app's process must be excluded (no double-send)")
        #expect(!tap.excludedProcessObjectIDs.contains(222), ".currentDevice apps stay in the system mix")
        coordinator.stop()
    }

    /// `.noRedirect` (the new default/unset state) is exclusion-equivalent to
    /// `.currentDevice`: neither is ever excluded from the system-wide tap. An
    /// app left "unset" must not be accidentally dropped from the system mix.
    @Test func noRedirectAppStaysInSystemMixJustLikeCurrentDevice() {
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

        #expect(tap.excludedProcessObjectIDs == [111],
                "only the .device-routed app is excluded; both local states (.currentDevice AND .noRedirect) stay in the system mix identically")
        coordinator.stop()
    }

    /// The existing user-excluded-apps list (Settings › Audio) still works
    /// and composes correctly (UNION) with route-based exclusion.
    @Test func userExcludedAppsComposeWithRouteBasedExclusion() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111, "com.app.c": 333]))

        coordinator.start()
        // Only a user-excluded app, no routes yet.
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.c"])
        #expect(tap.excludedProcessObjectIDs == [333])

        // Add a routed app on top — the union must include BOTH.
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: ["com.app.c"])
        #expect(tap.excludedProcessObjectIDs == [111, 333], "route-based and user-excluded exclusions compose (union)")
        coordinator.stop()
    }

    /// Calling `updateRouting` with an unchanged union is a no-op — it must
    /// not recreate the tap on every unrelated tick.
    @Test func updateRoutingIsNoOpWhenUnionUnchanged() {
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
        #expect(tap.creates == createsAfterFirstUpdate, "an unchanged exclusion union must not recreate the tap")
        coordinator.stop()
    }

    /// `updateRouting` called while NOT capturing doesn't touch any tap, but
    /// the computed exclusion set is applied on the NEXT `start()`.
    @Test func updateRoutingWhileIdleAppliesOnNextStart() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111]))

        // Not capturing yet — updateRouting must not create a tap.
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        #expect(tap.creates == 0)

        coordinator.start()
        #expect(tap.creates == 1)
        #expect(tap.excludedProcessObjectIDs == [111], "the previously-computed exclusion set is applied on start()")
        coordinator.stop()
    }

    /// THE LEAK FIX (T3): a multi-process app (Firefox-shaped — a silent main
    /// process plus an audio-emitting child with no bundle id of its own) must
    /// have BOTH process objects excluded from the whole-system mix. Excluding
    /// only the main process (the old single-pid behavior) named the wrong
    /// process and left the real audio leaking into the system mix alongside
    /// wherever it was redirected to.
    @Test func multiProcessBundleExclusionUnionsAllProcessObjects() {
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

        #expect(tap.excludedProcessObjectIDs == [1, 2],
            "both the silent main process AND the audio-emitting child must be excluded — excluding only the main process is exactly the leak this primitive exists to fix")
        coordinator.stop()
    }

    /// The multi-process union composes correctly across MULTIPLE excluded
    /// bundle ids: each bundle's full process set contributes to the union,
    /// with no cross-bundle bleed.
    @Test func multiProcessUnionAcrossMultipleExcludedBundles() {
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

        #expect(tap.excludedProcessObjectIDs == [1, 2, 3],
            "the union spans every excluded bundle's full process set")
        coordinator.stop()
    }

    // MARK: - Idempotency: start() while capturing is a no-op; stop() from idle is a no-op.

    @Test func startIsIdempotentAndStopFromIdleIsNoOp() {
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.stop()  // idle → no-op
        #expect(coordinator.state == .idle)
        #expect(tap.creates == 0)

        coordinator.start()
        coordinator.start()  // already capturing → no second tap
        #expect(tap.creates == 1)
        coordinator.stop()
    }

    // MARK: - pts clock domain: mHostTime must map onto CLOCK_MONOTONIC.

    #if canImport(AudioToolbox)
    /// The real pts derivation (`CoreAudioSystemTap.timespec(fromHostTime:)`) must
    /// land on the CLOCK_MONOTONIC timescale the engine consumes it on — NOT the
    /// raw mach-absolute timescale, which trails CLOCK_MONOTONIC by the machine's
    /// accumulated sleep and made every sync packet advertise a position receding
    /// into the past (Sonos green-never-white, no audio).
    @available(macOS 14.2, *)
    @Test func hostTimeMapsOntoClockMonotonic() {
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
        #expect(deltaNanos < 1_000_000_000,
            "pts must be on the CLOCK_MONOTONIC timescale (within 1s of it), not raw mach-absolute time")
    }

    /// The conversion is monotonic and linear in the host time: two host times a
    /// known delta apart map to pts the same delta apart.
    @available(macOS 14.2, *)
    @Test func hostTimeConversionPreservesDeltas() {
        let base = mach_absolute_time()
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        // Add 500ms worth of mach ticks.
        let halfSecondTicks = UInt64(500_000_000) * UInt64(max(1, tb.denom)) / UInt64(max(1, tb.numer))
        let a = CoreAudioSystemTap.timespec(fromHostTime: base)
        let b = CoreAudioSystemTap.timespec(fromHostTime: base &+ halfSecondTicks)
        let delta = Int64(timespecToNanos(b)) - Int64(timespecToNanos(a))
        #expect(abs(Double(delta) - 500_000_000) <= 2_000_000,
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
    @Test func shouldResampleDetectsSleepDrift() {
        let machNanos: UInt64 = 100_000_000_000          // 100s of mach time
        let offsetAtTapStart: Int64 = 0                   // clocks agreed at start
        let monotonicNowAfterFiveSecondSleep: UInt64 = 105_000_000_000
        #expect(CoreAudioSystemTap.shouldResample(
            machNanos: machNanos,
            offset: offsetAtTapStart,
            monotonicNowNanos: monotonicNowAfterFiveSecondSleep))
    }

    /// No sleep, no drift: an offset that still agrees with "now" to well under
    /// 1s must NOT trigger a resample on every single buffer.
    @available(macOS 14.2, *)
    @Test func shouldResampleToleratesNoDrift() {
        let machNanos: UInt64 = 100_000_000_000
        let offset: Int64 = 0
        let monotonicNow: UInt64 = 100_050_000_000        // 50ms of normal scheduling jitter
        #expect(!CoreAudioSystemTap.shouldResample(
            machNanos: machNanos, offset: offset, monotonicNowNanos: monotonicNow))
    }

    /// A negative offset (CLOCK_MONOTONIC behind mach-absolute, i.e. the box
    /// slept before the offset was even sampled) must be handled correctly in
    /// signed space, not wrap or crash.
    @available(macOS 14.2, *)
    @Test func shouldResampleHandlesNegativeOffset() {
        let machNanos: UInt64 = 50_000_000_000
        let offset: Int64 = -10_000_000_000               // monotonic trails mach by 10s
        let monotonicNowAgreeing: UInt64 = 40_000_000_000  // 50s + (-10s) = 40s: agrees
        #expect(!CoreAudioSystemTap.shouldResample(
            machNanos: machNanos, offset: offset, monotonicNowNanos: monotonicNowAgreeing))

        let monotonicNowDrifted: UInt64 = 46_000_000_000   // now 6s off from the 40s prediction
        #expect(CoreAudioSystemTap.shouldResample(
            machNanos: machNanos, offset: offset, monotonicNowNanos: monotonicNowDrifted))
    }

    /// `timespec(machNanos:offset:)` pts math round-trip: a known machNanos +
    /// offset must land on the expected wall-clock seconds/nanos, including the
    /// zero-clamp for a pathological negative result.
    @available(macOS 14.2, *)
    @Test func timespecMachNanosOffsetRoundTrip() {
        let ts = CoreAudioSystemTap.timespec(machNanos: 2_500_000_000, offset: 500_000_000)
        // 2.5s + 0.5s = 3.0s exactly.
        #expect(ts.tv_sec == 3)
        #expect(ts.tv_nsec == 0)

        let clamped = CoreAudioSystemTap.timespec(machNanos: 1_000_000_000, offset: -5_000_000_000)
        // Would be -4s; must clamp to zero rather than go negative.
        #expect(clamped.tv_sec == 0)
        #expect(clamped.tv_nsec == 0)
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
    /// Cleaned up via `defer` (runs even if an assertion above fails, since a
    /// failed `#expect` does not unwind) so the sink can never leak forward
    /// into whatever test runs next in this same process. This suite is
    /// nested inside `SerializedSharedState`, so no other suite touching the
    /// same process-global sink can run concurrently with this test either.
    @Test func startEmitsCaptureWSTransitionTelemetry() {
        let capturedLines = TelemetryLineBox()
        Telemetry._installTestSink { capturedLines.append($0) }
        defer { Telemetry._installTestSink(nil) }

        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, sink: SpySink(), converter: FakeConverter())

        coordinator.start()
        #expect(coordinator.state == .capturing(tap.format))

        // `_installTestSink(nil)` is a synchronous barrier on Telemetry's
        // writer queue (mirrors TelemetryTests' own `drain()`) — guarantees
        // both lines above are fully written before we inspect them.
        Telemetry._installTestSink(nil)

        let lines = capturedLines.snapshot
        let idleToCreating = lines.first {
            $0.contains("\"cat\":\"captureWS\"") && $0.contains("\"evt\":\"transition\"")
                && $0.contains("\"from\":\"idle\"") && $0.contains("\"to\":\"creatingTap\"")
        }
        #expect(idleToCreating != nil, "expected an idle -> creatingTap captureWS/transition line, got: \(lines)")

        let creatingToCapturing = lines.first {
            $0.contains("\"cat\":\"captureWS\"") && $0.contains("\"evt\":\"transition\"")
                && $0.contains("\"from\":\"creatingTap\"") && $0.contains("\"to\":\"capturing\"")
        }
        #expect(creatingToCapturing != nil, "expected a creatingTap -> capturing captureWS/transition line, got: \(lines)")
        #expect(
            creatingToCapturing?.contains("\"format\":\"\(tap.format.sampleRate)/\(tap.format.channels)\"") ?? false,
            "the capturing transition must carry the tap format, got: \(creatingToCapturing ?? "nil")")

        coordinator.stop()
    }

    /// The generalized echo guard (live find, 2026-07-26): the whole-system
    /// tap's exclusion set must ALWAYS contain THIS process's own audio
    /// process objects — `LocalPlaybackEngine` renders `.currentDevice` apps
    /// from this process onto the very device the tap captures, so without the
    /// self-exclude a "play on this Mac" exception echoed into the AirPlay mix
    /// (Spotify → Mac speakers audibly replayed on the selected Sonos). The
    /// enumerator here lists a process at OUR pid alongside an unrelated one;
    /// only ours must be excluded, with no excluded bundles configured at all.
    @Test func exclusionAlwaysContainsOwnProcessObjects() {
        let ownProcess = RawAudioProcess(objectID: 900, pid: getpid(), bundleID: "com.audiouter.test-host")
        let otherProcess = RawAudioProcess(objectID: 901, pid: 4242, bundleID: "com.other.app")
        let tap = FakeTap()
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(
                enumerator: FakeProcessEnumerator(processes: [ownProcess, otherProcess])))

        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: [])
        coordinator.start()

        #expect(tap.excludedProcessObjectIDs.contains(900),
                "our own process object must always be excluded from the whole-system tap (echo guard)")
        #expect(!tap.excludedProcessObjectIDs.contains(901),
                "an unrelated process must not be swept up by the self-exclude")

        coordinator.stop()
    }

    /// T2: every exclusion resolve emits `captureWS`/`exclusion_resolved` with
    /// each resolved bundle's pids + attribution layer, AND calls out a bundle
    /// that resolved to ZERO processes — the diagnostic gap the 2026-07-26
    /// catch-all-attribution live leak exposed: `exclusion_changed` alone shows
    /// only excluded bundle-id INTENT, never which concrete processes (or none)
    /// a bundle id actually resolved to.
    @Test func startEmitsExclusionResolvedTelemetryWithLayerDetailAndZeroBundles() {
        let capturedLines = TelemetryLineBox()
        Telemetry._installTestSink { capturedLines.append($0) }
        defer { Telemetry._installTestSink(nil) }

        let coordinator = makeCoordinator(
            tap: FakeTap(), sink: SpySink(), converter: FakeConverter(),
            processResolver: singleProcessResolver(["com.app.a": 111]))

        coordinator.updateRouting(
            appRoutes: [],
            excludedBundleIDs: ["com.app.a", "com.app.missing"])
        coordinator.start()

        Telemetry._installTestSink(nil)

        let lines = capturedLines.snapshot
        let resolved = lines.first {
            $0.contains("\"cat\":\"captureWS\"") && $0.contains("\"evt\":\"exclusion_resolved\"")
        }
        #expect(resolved != nil, "expected a captureWS/exclusion_resolved line, got: \(lines)")
        #expect(
            resolved?.contains("com.app.a=[111:own]") ?? false,
            "expected the resolved pid + attribution layer, got: \(resolved ?? "nil")")
        #expect(
            resolved?.contains("\"zeroBundles\":\"com.app.missing\"") ?? false,
            "expected the zero-resolution bundle called out explicitly, got: \(resolved ?? "nil")")

        coordinator.stop()
    }

    // MARK: - RMS metering (pure).

    @Test func rmsOfS16LE() {
        #expect(NativeCaptureCoordinator.rmsOfS16LE(Data()) == 0)
        // A constant full-scale signal → RMS ~1.0.
        var full = Data()
        for _ in 0..<64 { withUnsafeBytes(of: Int16(32767).littleEndian) { full.append(contentsOf: $0) } }
        #expect(abs(NativeCaptureCoordinator.rmsOfS16LE(full) - 1.0) <= 0.01)
    }

    // MARK: - Compare-before-rebuild decision (TapRebuildDecision), whole-system tap
    // (Fix 3). Both guards are now evaluated per subscriber inside
    // ``DefaultOutputDeviceMonitor``, against the device/rate each tap reports for
    // itself via `subscribeToDefaultOutput`'s `tracked` closure.
    // Testing the pure decision is what makes the storm guard meaningful without a real
    // HAL — the live `defaultOutputDeviceID()` read stays a thin wrapper around it.

    #if canImport(AudioToolbox)
    @Test func systemTapDeviceGuardFiresOnlyOnGenuineDeviceChange() {
        // Unchanged pinned device -> NO rebuild: the no-op notification that another
        // live tap's own rebuild fires on THIS tap must be dropped, or the taps storm
        // each other into the diagnosed coreaudiod live-lock.
        #expect(!(TapRebuildDecision.shouldRebuild(currentDeviceID: 42, trackedDeviceID: 42)), "an unchanged default output device must NOT rebuild the whole-system tap")
        // Genuine default-output-device change -> rebuild fires.
        #expect(TapRebuildDecision.shouldRebuild(currentDeviceID: 43, trackedDeviceID: 42), "a genuine default-output-device change MUST rebuild the whole-system tap")
        // Failed live read (nil) -> treat as changed -> fire (never suppress on a
        // failed read).
        #expect(TapRebuildDecision.shouldRebuild(currentDeviceID: nil, trackedDeviceID: 42), "a failed device read must be treated as changed (fire), not suppressed")
        // Fresh-tap edge: trackedDeviceID is kAudioObjectUnknown until createAggregate
        // pins a device, so a real current device must then read as changed.
        #expect(TapRebuildDecision.shouldRebuild(
                currentDeviceID: 42, trackedDeviceID: AudioObjectID(kAudioObjectUnknown)), "before the aggregate pins a device (tracked == unknown), a real device reads as changed")
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
    @Test func isRetryableExcludesOnlyOSUnsupported() {
        #expect(NativeCaptureError.tapCreationFailed(reason: "x").isRetryable)
        #expect(NativeCaptureError.aggregateDeviceFailed(reason: "x").isRetryable)
        #expect(NativeCaptureError.formatReadFailed(reason: "x").isRetryable)
        #expect(NativeCaptureError.deviceLost(reason: "x").isRetryable)
        #expect(!(NativeCaptureError.osUnsupported(minimum: "14.2").isRetryable), "an OS-version gate can never be fixed by retrying — no backoff should spin on it")
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
    @Test func reconciledFormatCorrectsStalePreAggregateRate() {
        let declared = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        let reconciled = CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: 48000)
        #expect(reconciled.sampleRate == 48000,
            "the converter's input rate must follow the aggregate's real delivered rate, not the pre-aggregate tap read")
        // Every rate-INDEPENDENT field is preserved (drift compensation only resamples).
        #expect(reconciled.channels == 2)
        #expect(reconciled.bitsPerSample == 32)
        #expect(reconciled.isFloat)
        #expect(!reconciled.isInterleaved)
    }

    /// The reverse divergence (declared 48000, aggregate 44100) is corrected too —
    /// the fix is symmetric: it always snaps to the aggregate's real rate.
    @available(macOS 14.2, *)
    @Test func reconciledFormatCorrectsEitherDirection() {
        let declared = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        #expect(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: 44100).sampleRate == 44100)
    }

    /// When the pre-aggregate read already matches the aggregate (the common case),
    /// the format is returned UNCHANGED — no needless rewrite.
    @available(macOS 14.2, *)
    @Test func reconciledFormatUnchangedWhenRatesMatch() {
        let declared = TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        #expect(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: 48000) == declared)
    }

    /// An unreadable / degenerate aggregate rate must NOT clobber the format — we
    /// keep the pre-aggregate read (no regression vs. the prior behaviour).
    @available(macOS 14.2, *)
    @Test func reconciledFormatIgnoresUnreadableAggregateRate() {
        let declared = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        #expect(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: nil) == declared)
        #expect(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: 0) == declared)
        #expect(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: -48000) == declared)
        #expect(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: .nan) == declared)
        #expect(CoreAudioSystemTap.reconciledFormat(declared: declared, aggregateRate: .infinity) == declared)
    }

    /// Compare-before-rebuild loop-breaker: a nominal-rate notification that
    /// re-announces the SAME rate the converter already runs at must NOT rebuild.
    @available(macOS 14.2, *)
    @Test func shouldRebuildForNominalRateSkipsNoOpNotification() {
        #expect(!CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: 48000, currentEffectiveRate: 48000),
            "a set-to-same-value notification must be a no-op — no teardown+rebuild churn")
        #expect(!CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: 48000.4, currentEffectiveRate: 48000),
            "sub-Hz jitter that rounds to the same integer rate is still a no-op")
    }

    /// A genuinely different notified rate DOES rebuild; an unreadable rate falls
    /// back to the safe rebuild (can't prove it's a no-op).
    @available(macOS 14.2, *)
    @Test func shouldRebuildForNominalRateRebuildsOnRealChangeOrUnreadable() {
        #expect(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: 44100, currentEffectiveRate: 48000))
        #expect(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: nil, currentEffectiveRate: 48000))
        #expect(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: 0, currentEffectiveRate: 48000))
        #expect(CoreAudioSystemTap.shouldRebuildForNominalRate(notifiedRate: .nan, currentEffectiveRate: 48000))
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
    @Test func converterOutputLengthScalesWithDeclaredInputRate() {
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
        #expect(frames44 > 0)
        #expect(frames48 > 0)
        #expect(frames48 < frames44,
            "a higher declared input rate yields fewer 44100 output frames — the exact pitch lever this fix corrects")
        let ratio = Double(frames48) / Double(frames44)
        #expect(abs(ratio - 44100.0 / 48000.0) <= 0.01,
            "total output length must scale by the declared-rate ratio (44100/48000), confirming rate == pitch")
    }

    /// The converter's silent nil-return sites are counted, grouped by reason
    /// (whole-system dropout investigation): before this, a converter dropping
    /// every buffer was indistinguishable from healthy silence. A converter
    /// built from a degenerate tap format fails every buffer as
    /// `.converterAbsent`; a frameless buffer counts `.emptyInput`; an
    /// interleaved buffer with no channel data counts `.missingChannelData`;
    /// and a healthy conversion counts nothing.
    @available(macOS 14.2, *)
    @Test func converterFailureCountersGroupByReason() {
        let planar = Self.planarFloat32Stereo(frameCount: 64)
        let buffer = CapturedBuffer(channelData: planar, frameCount: 64, pts: timespec())

        // Degenerate format -> AVAudioFormat/AVAudioConverter never construct,
        // so EVERY convert fails as converterAbsent.
        let broken = AVFormatConverter(from: TapFormat(
            sampleRate: 0, channels: 2, bitsPerSample: 0, isFloat: true, isInterleaved: true))
        #expect(broken.convertToAirPlayPCM(buffer) == nil)
        #expect(broken.convertToAirPlayPCM(buffer) == nil)
        #expect(broken.conversionFailureCount(.converterAbsent) == 2)

        // A frameless buffer through a HEALTHY converter counts emptyInput.
        let healthy = AVFormatConverter(from: TapFormat(
            sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false))
        #expect(healthy.convertToAirPlayPCM(
            CapturedBuffer(channelData: planar, frameCount: 0, pts: timespec())) == nil)
        #expect(healthy.conversionFailureCount(.emptyInput) == 1)

        // An interleaved source with no channel data counts missingChannelData.
        let interleaved = AVFormatConverter(from: TapFormat(
            sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: true))
        #expect(interleaved.convertToAirPlayPCM(
            CapturedBuffer(channelData: [], frameCount: 64, pts: timespec())) == nil)
        #expect(interleaved.conversionFailureCount(.missingChannelData) == 1)

        // A successful conversion moves NO counter.
        #expect(healthy.convertToAirPlayPCM(buffer) != nil)
        for reason in ConversionFailureReason.allCases where reason != .emptyInput {
            #expect(healthy.conversionFailureCount(reason) == 0,
                "a healthy conversion must not count \(reason)")
        }
        #expect(healthy.conversionFailureCount(.emptyInput) == 1)
    }

    /// `sampleConversionFailuresIfDue()` (the whole-system sampler family):
    /// throttled to its interval, delta-gated to genuinely NEW failures — a
    /// failing converter emits ONE `convert_failure` event per accrual, a
    /// converter with no new failures emits nothing, ever. Test-sink idiom and
    /// serialization rationale identical to
    /// `startEmitsCaptureWSTransitionTelemetry` above.
    @available(macOS 14.2, *)
    @Test func converterFailureSamplerEmitsOnlyOnNewFailures() {
        let capturedLines = TelemetryLineBox()
        Telemetry._installTestSink { capturedLines.append($0) }
        defer { Telemetry._installTestSink(nil) }

        let broken = AVFormatConverter(from: TapFormat(
            sampleRate: 0, channels: 2, bitsPerSample: 0, isFloat: true, isInterleaved: true))
        let buffer = CapturedBuffer(
            channelData: Self.planarFloat32Stereo(frameCount: 64), frameCount: 64, pts: timespec())

        func failureLines() -> [String] {
            capturedLines.snapshot.filter { $0.contains("\"evt\":\"convert_failure\"") }
        }

        // One failing convert + a full sampler interval -> exactly one event
        // (the delta-gate blocks every later tick with no NEW failures).
        #expect(broken.convertToAirPlayPCM(buffer) == nil)
        for _ in 0..<1000 { broken.sampleConversionFailuresIfDue() }
        Telemetry._installTestSink { capturedLines.append($0) } // flush barrier
        #expect(failureLines().count == 1,
            "one accrual across many sampler ticks must emit exactly one event, got: \(failureLines())")
        #expect(failureLines().first?.contains("\"converterAbsent\":\"1\"") == true)

        // A NEW failure re-arms the delta gate: next interval emits again.
        #expect(broken.convertToAirPlayPCM(buffer) == nil)
        for _ in 0..<500 { broken.sampleConversionFailuresIfDue() }
        Telemetry._installTestSink(nil) // synchronous flush barrier
        #expect(failureLines().count == 2)
        #expect(failureLines().last?.contains("\"failedTotal\":\"2\"") == true)
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

    // MARK: - R14: relaunch correctness (`refreshExcludedProcessSet`, W1-T7 Fix 1)

    /// An EXCLUDED app relaunches (old process gone, a fresh one under the same
    /// bundle ID). The bundle-ID union `updateRouting` tracks is unchanged, so its
    /// own no-op guard would never recreate the tap — `refreshExcludedProcessSet`
    /// bypasses it and picks up the fresh process so it can't leak back in.
    @Test func refreshExcludedProcessSetPicksUpRelaunchedExcludedAppProcess() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.excluded")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        #expect(tap.excludedProcessObjectIDs == [111])
        let createsAfterExclude = tap.creates

        enumerator.set([rawProcess(456, "com.app.excluded")]) // relaunch: fresh pid
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")

        #expect(tap.creates > createsAfterExclude, "relaunch must recreate the tap")
        #expect(tap.excludedProcessObjectIDs == [456], "the relaunched app's fresh process is excluded, not the stale one")
        coordinator.stop()
    }

    /// A ROUTED (`.device`) app relaunches — its fresh process must be excluded
    /// from the system mix too, or it doubles: once via its target route, once via
    /// the whole-system mixdown.
    @Test func refreshExcludedProcessSetPicksUpRelaunchedRoutedAppProcess() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.routed")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.routed", displayName: "Routed", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        #expect(tap.excludedProcessObjectIDs == [111])
        let createsAfterRoute = tap.creates

        enumerator.set([rawProcess(777, "com.app.routed")])
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.routed")

        #expect(tap.creates > createsAfterRoute, "relaunch must recreate the tap")
        #expect(tap.excludedProcessObjectIDs == [777], "the relaunched routed app's fresh process is excluded — no doubling")
        coordinator.stop()
    }

    /// A bundle ID that ISN'T currently excluded/routed-away triggers no rebuild —
    /// cheap to call on every app launch.
    @Test func refreshExcludedProcessSetIsNoOpForUnrelatedBundleID() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.a")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.app.a", displayName: "App A", destination: .device(id: "speaker-1"))],
            excludedBundleIDs: [])
        let createsAfterRoute = tap.creates

        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.unrelated")
        #expect(tap.creates == createsAfterRoute, "an unrelated bundle ID must not recreate the tap")
        coordinator.stop()
    }

    /// Calling `refreshExcludedProcessSet` while not capturing must not create a
    /// tap — the fresh process is picked up on the next real `start()`.
    @Test func refreshExcludedProcessSetWhileIdleIsNoOp() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.excluded")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        #expect(tap.creates == 0, "no tap exists yet — refresh must not create one")
    }

    /// THE storm-prevention property (W1-T7 Fix 1): `refreshExcludedProcessSet` is
    /// wired (R9) to fire on EVERY per-app tap `.capturing` transition. With N
    /// routed apps re-reaching `.capturing` after one output-rate renegotiation, an
    /// unconditional recreate drove N whole-system rebuilds on an UNCHANGED excluded
    /// set — the amplified coreaudiod storm. A refresh whose resolved object set is
    /// unchanged must do ZERO Core Audio work however many fire.
    @Test func refreshOnUnchangedExclusionSetTriggersZeroRebuilds() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.excluded")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        #expect(tap.excludedProcessObjectIDs == [111])
        let createsAfterExclude = tap.creates

        for _ in 0..<8 {
            coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        }
        #expect(tap.creates == createsAfterExclude,
                "an unchanged excluded set must do ZERO rebuilds however many refreshes fire")
        coordinator.stop()
    }

    /// A genuine process change rebuilds EXACTLY ONCE; a second refresh on the
    /// settled set is a no-op.
    @Test func refreshOnGenuineProcessChangeRebuildsExactlyOnce() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.excluded")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        let createsAfterExclude = tap.creates

        enumerator.set([rawProcess(456, "com.app.excluded")])
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        #expect(tap.creates == createsAfterExclude + 1, "a genuine process change rebuilds exactly once")
        #expect(tap.excludedProcessObjectIDs == [456])

        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        #expect(tap.creates == createsAfterExclude + 1, "the settled set must not rebuild again")
        coordinator.stop()
    }

    /// A FAILED rebuild must not leave a baseline that suppresses the next real
    /// change — the baseline advances ONLY on a successful `.capturing` commit.
    @Test func failedRebuildDoesNotSuppressNextRealExclusionChange() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.excluded")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.excluded"])
        #expect(tap.excludedProcessObjectIDs == [111])

        // The relaunch's rebuild fails (createAndStart throws) → `.failed`.
        tap.startError = .deviceLost(reason: "gone")
        enumerator.set([rawProcess(456, "com.app.excluded")])
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        waitFor { if case .failed = coordinator.state { return true }; return false }

        // Recover: start() from `.failed` re-derives the baseline from the LIVE set,
        // proving the failed attempt didn't wedge it.
        tap.startError = nil
        coordinator.start()
        waitFor { if case .capturing = coordinator.state { return true }; return false }
        #expect(tap.excludedProcessObjectIDs == [456], "recovery excludes the current process")
        let createsAfterRecover = tap.creates

        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        #expect(tap.creates == createsAfterRecover, "settled set after recovery must not rebuild")

        enumerator.set([rawProcess(789, "com.app.excluded")])
        coordinator.refreshExcludedProcessSet(forRelaunchedBundleID: "com.app.excluded")
        #expect(tap.creates == createsAfterRecover + 1, "a real change after a prior failure still rebuilds once")
        #expect(tap.excludedProcessObjectIDs == [789])
        coordinator.stop()
    }

    // MARK: - W1-T7 (Gap 1): live exclusion-membership diffing (debounced, compare-before-rebuild)

    /// An EXCLUDED app spawns a new audio-playing child mid-session (no relaunch,
    /// no bundle-ID change) → the new child's process object is picked up and the
    /// tap recreated EXACTLY ONCE with the expanded exclusion set, so the child's
    /// audio stops leaking into the whole-system mix. (On the object-based resolver
    /// this also covers Fix 2: a process only appears once it is audible — a
    /// silent→audible transition is exactly a membership change here.)
    @Test func excludedAppSpawningChildMidSessionIsAddedToExclusionExactlyOnce() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.browser")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.browser"])
        #expect(tap.excludedProcessObjectIDs == [111])
        let createsAfterExclude = tap.creates

        // A new tab starts playing: a fresh audio child appears under the SAME
        // bundle ID. No relaunch, no union change — only the live process set grew.
        enumerator.set([rawProcess(111, "com.app.browser"), rawProcess(222, "com.app.browser")])
        coordinator.handleMembershipChange()

        #expect(tap.creates == createsAfterExclude + 1, "a genuine membership change recreates the tap exactly once")
        #expect(tap.excludedProcessObjectIDs == [111, 222], "the newly-spawned audio child is now excluded")

        coordinator.handleMembershipChange()
        #expect(tap.creates == createsAfterExclude + 1, "the settled set must not trigger a second rebuild")
        coordinator.stop()
    }

    /// The regression-prevention property: an unchanged excluded object set — a
    /// duplicate notification, or churn in an UNRELATED app — triggers ZERO
    /// rebuilds (the CPU-storm loop-breaker).
    @Test func unchangedExclusionMembershipTriggersZeroRebuilds() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([
            rawProcess(111, "com.app.browser"), rawProcess(222, "com.app.browser"),
        ])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.browser"])
        let createsAfterExclude = tap.creates

        coordinator.handleMembershipChange()
        enumerator.set([rawProcess(222, "com.app.browser"), rawProcess(111, "com.app.browser")]) // reorder = same set
        coordinator.handleMembershipChange()

        #expect(tap.creates == createsAfterExclude, "no rebuild for an unchanged (or reordered) exclusion set")
        coordinator.stop()
    }

    /// A membership diff that lands while idle (no tap) does nothing.
    @Test func membershipDiffWhileIdleIsNoOp() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.browser")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator))

        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.browser"])
        enumerator.set([rawProcess(111, "com.app.browser"), rawProcess(222, "com.app.browser")])
        coordinator.handleMembershipChange()
        #expect(tap.creates == 0, "no tap exists yet — a membership diff must not create one")
    }

    /// Rapid spawn/kill/spawn churn within the debounce window coalesces to a
    /// single settled diff — one rebuild against the FINAL set, not one per
    /// notification. Driven through the real debounced `handleProcessListChanged`
    /// entry point with a short injected interval.
    @Test func rapidExclusionChurnWithinDebounceWindowCoalescesToOneRebuild() {
        let tap = FakeTap()
        let enumerator = MutableProcessEnumerator([rawProcess(111, "com.app.browser")])
        let coordinator = makeCoordinator(
            tap: tap, sink: SpySink(), converter: FakeConverter(),
            processResolver: AudioProcessResolver(enumerator: enumerator),
            membershipDebounceInterval: .milliseconds(60))

        coordinator.start()
        coordinator.updateRouting(appRoutes: [], excludedBundleIDs: ["com.app.browser"])
        let createsAfterExclude = tap.creates

        // A burst of three notifications inside the 60ms window, settling on {111,333}.
        enumerator.set([rawProcess(111, "com.app.browser"), rawProcess(222, "com.app.browser")]); coordinator.handleProcessListChanged()
        enumerator.set([rawProcess(111, "com.app.browser")]);                                     coordinator.handleProcessListChanged()
        enumerator.set([rawProcess(111, "com.app.browser"), rawProcess(333, "com.app.browser")]); coordinator.handleProcessListChanged()

        waitFor { tap.creates >= createsAfterExclude + 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2)) // let any extra (erroneous) rebuilds appear

        #expect(tap.creates == createsAfterExclude + 1, "the burst must coalesce to a single settled rebuild")
        #expect(tap.excludedProcessObjectIDs == [111, 333], "the coalesced diff applies the SETTLED exclusion set")
        coordinator.stop()
    }

    // MARK: - DefaultOutputDeviceMonitor subscription (T2 consolidation)

    /// GUARD SEMANTICS. The whole-system tap must report its OWN live device/rate
    /// to the monitor at every notification, never a snapshot taken once at
    /// subscribe time. The middle expectation is the one that matters: the tap's
    /// format drifts while the DEVICE's rate stays put, and only a fresh read of
    /// the tap's own state can see that divergence. A captured snapshot would
    /// silently reintroduce the per-subscriber blindness (the silent-tap dropout)
    /// the monitor exists to prevent.
    @available(macOS 14.2, *)
    @Test func wholeSystemTapReportsItsOwnStateLiveToTheMonitor() {
        let hal = TapMonitorFakeHAL(deviceID: 42, rate: 48_000)
        // Long settle window + explicit flush: fan-out happens only where this
        // test asks for it, never on the monitor's real trailing-edge timer.
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: 60)
        let tap = CoreAudioSystemTap(name: "test", monitor: monitor)
        let fires = TapMonitorFireCounter()
        tap.onDefaultDeviceChanged = { fires.bump() }

        tap.test_seedTrackedState(deviceID: 42, sampleRate: 48_000)
        tap.subscribeToDefaultOutput()

        // Converged: the tap is built on exactly what the HAL reports.
        hal.fire(kAudioDevicePropertyNominalSampleRate)
        monitor._drainForTesting()
        #expect(fires.count == 0, "a no-op re-announcement must not rebuild the tap — the storm loop-breaker still holds")

        // The TAP drifts; the device's reported rate never moves.
        tap.test_seedTrackedState(deviceID: 42, sampleRate: 44_100)
        hal.fire(kAudioDevicePropertyNominalSampleRate)
        monitor._drainForTesting()
        #expect(fires.count == 1,
            "a tap whose own format drifted must still be told, even though the device's rate is unchanged — proves `tracked` is read live, not captured at subscribe time")

        // A genuine default-output-device identity change fires too.
        tap.test_seedTrackedState(deviceID: 42, sampleRate: 48_000)
        hal.deviceID = 43
        hal.fire(kAudioHardwarePropertyDefaultOutputDevice)
        monitor._drainForTesting()
        #expect(fires.count == 2, "a genuine default-output-device change must rebuild the tap")

        tap.teardown()
    }

    /// Teardown replaces the old paired listener removal: it must drop the
    /// subscription (releasing everything its closures capture) and stay
    /// idempotent, since `teardown()` also runs from `deinit`.
    @available(macOS 14.2, *)
    @Test func wholeSystemTapTeardownUnsubscribesFromTheMonitor() {
        let hal = TapMonitorFakeHAL(deviceID: 42, rate: 48_000)
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        let tap = CoreAudioSystemTap(name: "test", monitor: monitor)
        tap.test_seedTrackedState(deviceID: 42, sampleRate: 48_000)
        tap.subscribeToDefaultOutput()
        #expect(monitor.subscriberCount == 1)

        tap.teardown()
        #expect(monitor.subscriberCount == 0, "teardown must release the tap's monitor subscription")
        tap.teardown()
        #expect(monitor.subscriberCount == 0, "a second teardown must stay a no-op")
    }
    }
}

/// Shared fake ``DefaultOutputHAL`` for the two capture taps' monitor-subscription
/// tests (this file and `PerAppCaptureCoordinatorTests`). No live Core Audio, no
/// real device, no audio played. `fire` delivers on the very queue the monitor
/// handed over — the real HAL's contract — so it returns only once the monitor has
/// finished handling the notification.
final class TapMonitorFakeHAL: DefaultOutputHAL, @unchecked Sendable {

    private final class Token: DefaultOutputHALListenerToken, @unchecked Sendable {
        let selector: AudioObjectPropertySelector
        let queue: DispatchQueue
        let handler: @Sendable () -> Void
        init(selector: AudioObjectPropertySelector, queue: DispatchQueue,
             handler: @escaping @Sendable () -> Void) {
            self.selector = selector
            self.queue = queue
            self.handler = handler
        }
    }

    private let lock = NSLock()
    private var _deviceID: AudioObjectID?
    private var _rate: Double?
    private var tokens: [ObjectIdentifier: Token] = [:]

    init(deviceID: AudioObjectID?, rate: Double?) {
        _deviceID = deviceID
        _rate = rate
    }

    var deviceID: AudioObjectID? {
        get { lock.withLock { _deviceID } }
        set { lock.withLock { _deviceID = newValue } }
    }

    var rate: Double? {
        get { lock.withLock { _rate } }
        set { lock.withLock { _rate = newValue } }
    }

    func defaultOutputDeviceID() -> AudioObjectID? { deviceID }
    func nominalSampleRate(of deviceID: AudioObjectID) -> Double? { rate }

    func addListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> DefaultOutputHALListenerToken? {
        let token = Token(selector: selector, queue: queue, handler: handler)
        lock.withLock { tokens[ObjectIdentifier(token)] = token }
        return token
    }

    func removeListener(_ token: DefaultOutputHALListenerToken) {
        lock.withLock { tokens[ObjectIdentifier(token as AnyObject)] = nil }
    }

    func fire(_ selector: AudioObjectPropertySelector) {
        let matching = lock.withLock { tokens.values.filter { $0.selector == selector } }
        for token in matching { token.queue.sync { token.handler() } }
    }
}

/// Counts `onDefaultDeviceChanged` fires from the monitor's queue.
final class TapMonitorFireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func bump() { lock.withLock { _count += 1 } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
