import Foundation
import Testing
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
///
/// Nested inside `SerializedSharedState` (cookbook §18): this suite installs
/// `Telemetry`'s process-global test sink
/// (`testSampleRateChangeEmitsCapturePARateRebuildTelemetry`), which would
/// otherwise race every other suite doing the same under swift-testing's
/// concurrent-in-one-process model.
extension SerializedSharedState {
    @Suite struct PerAppCaptureCoordinatorTests {

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

    /// Collects `Telemetry._installTestSink` lines thread-safely — the sink
    /// runs on Telemetry's own serial writer queue, a different thread than
    /// the test body (same reason `BufferSpy` above needs a lock).
    private final class TelemetryLineSpy: @unchecked Sendable {
        let lock = NSLock()
        private(set) var lines: [String] = []
        func record(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
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

    /// Builds a coordinator the way every test in this file wants it: the
    /// same 3 injected seams every call site already passes
    /// (`makeTap`/`processResolver`/`muteBehavior`) PLUS
    /// `installsProcessListListener: false`, so `start(bundleID:)` never arms
    /// the REAL, live `kAudioHardwarePropertyProcessObjectList` listener on
    /// the actual system Core Audio object. That listener fires on ANY
    /// process anywhere on the machine opening or closing an audio session —
    /// not just bundle IDs this suite drives — and its handler re-enters
    /// `start(bundleID:)` from an internal HAL thread at an unpredictable
    /// moment, which could otherwise transiently flip a slot back through
    /// `.resolvingProcess` right as a test asserts a `.failed(...)` state (a
    /// real flake this helper closes off for good, not just makes less
    /// likely). No coverage is lost by keeping the real listener off here:
    /// ``PerAppCaptureCoordinator/handleProcessListChanged()`` stays directly
    /// callable regardless of this flag, and
    /// `testProcessListChangeReDrivesRetryableFailedSlotButNotNonRetryable`
    /// below exercises the resume-listener's re-drive logic that way —
    /// deterministically — instead of depending on the live listener firing.
    private func makeCoordinator(
        makeTap: @escaping @Sendable () -> ProcessAudioTap,
        processResolver: AudioProcessResolver,
        muteBehavior: TapMuteBehavior = .mutedWhenTapped,
        membershipDebounceInterval: DispatchTimeInterval = .milliseconds(300)
    ) -> PerAppCaptureCoordinator {
        PerAppCaptureCoordinator(
            makeTap: makeTap,
            processResolver: processResolver,
            muteBehavior: muteBehavior,
            installsProcessListListener: false,
            membershipDebounceInterval: membershipDebounceInterval
        )
    }

    // MARK: - Single bundle ID: start -> buffers forwarded (tagged) -> stop -> clean teardown.

    @Test func startForwardsTaggedBuffersThenStopTearsDownAndClearsState() {
        let tap = FakeProcessTap()
        let spy = BufferSpy()
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 10, pid: 4242)
        let coordinator = makeCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.onBuffer = { bundleID, buffer in spy.record(bundleID, buffer) }

        coordinator.start(bundleID: "com.example.music")
        waitFor { coordinator.state(for: "com.example.music") == .capturing(tap.format) }
        #expect(coordinator.state(for: "com.example.music") == .capturing(tap.format))
        #expect(tap.creates == 1)
        #expect(tap.lastProcesses == [AudioProcess(objectID: 10, pid: 4242)])
        #expect(tap.lastBundleID == "com.example.music")
        #expect(coordinator.capturingBundleIDs == ["com.example.music"])

        tap.pushBuffer(buffer(hostTime: 1_000_000_000))
        tap.pushBuffer(buffer(hostTime: 2_000_000_000))
        waitFor { spy.all.count == 2 }
        #expect(spy.all.count == 2)
        #expect(spy.all.allSatisfy { $0.bundleID == "com.example.music" })

        coordinator.stop(bundleID: "com.example.music")
        #expect(coordinator.state(for: "com.example.music") == .idle)
        #expect(tap.teardowns >= 1)
        #expect(coordinator.capturingBundleIDs.isEmpty)

        // stop() removes the slot entirely (clean teardown, no leaked state) —
        // a bundle ID that was never started reports .idle identically to one
        // that was started then fully stopped.
        #expect(coordinator.state(for: "com.example.never-started") == .idle)
    }

    // MARK: - T2: a bundle ID that resolves to MULTIPLE process objects (the
    // Firefox/Chrome multi-process-browser shape — a main process plus a
    // nil-bundle-id audio child attributed via the parent-pid walk) gets ONE
    // tap that is a mixdown of ALL of them, not just the main process. This is
    // the actual leak fix: tapping only the main process silently misses the
    // child the audio actually comes from.

    @Test func multiProcessBundleMixesDownAllResolvedProcessesIntoOneTap() {
        let tap = FakeProcessTap()
        let firefox = "org.mozilla.firefox"
        let enumerator = FakeProcessEnumerator()
        enumerator.setProcesses([
            RawAudioProcess(objectID: 20, pid: 700, bundleID: firefox),   // main process
            RawAudioProcess(objectID: 21, pid: 701, bundleID: nil)        // silent audio child
        ])
        enumerator.parents = [701: 700]
        let resolver = AudioProcessResolver(enumerator: enumerator)
        let coordinator = makeCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )

        coordinator.start(bundleID: firefox)
        waitFor { if case .capturing = coordinator.state(for: firefox) { return true }; return false }

        #expect(tap.creates == 1, "one tap for the bundle ID, mixing down every resolved process")
        #expect(tap.lastProcesses == [
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

    @Test func independentTapsPerBundleIDCoexistWithoutCrossTalk() {
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

        let coordinator = makeCoordinator(
            makeTap: { factory.make() },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.onBuffer = { bundleID, buffer in spy.record(bundleID, buffer) }

        coordinator.start(bundleID: "com.example.a")
        waitFor { if case .capturing = coordinator.state(for: "com.example.a") { return true }; return false }
        coordinator.start(bundleID: "com.example.b")
        waitFor { if case .capturing = coordinator.state(for: "com.example.b") { return true }; return false }

        #expect(factory.byInsertionOrder.count == 2)
        let tapA = factory.byInsertionOrder[0]
        let tapB = factory.byInsertionOrder[1]
        #expect(tapA.lastProcesses == [AudioProcess(objectID: 1, pid: 111)])
        #expect(tapB.lastProcesses == [AudioProcess(objectID: 2, pid: 222)])

        tapA.pushBuffer(buffer(hostTime: 1_000_000_000, frames: 4))
        tapB.pushBuffer(buffer(hostTime: 1_000_000_000, frames: 8))
        waitFor { spy.all.count == 2 }

        let byBundle = Dictionary(uniqueKeysWithValues: spy.all.map { ($0.bundleID, $0.frameCount) })
        #expect(byBundle["com.example.a"] == 4)
        #expect(byBundle["com.example.b"] == 8)

        // Stopping A tears down ONLY A's tap.
        coordinator.stop(bundleID: "com.example.a")
        #expect(tapA.teardowns >= 1)
        #expect(tapB.teardowns == 0)
        waitFor { if case .capturing = coordinator.state(for: "com.example.b") { return true }; return false }

        coordinator.stopAll()
        #expect(tapB.teardowns >= 1)
    }

    // MARK: - An empty AudioProcessResolver result (T2) surfaces as
    // .failed(.processNotYetAudible), retryable — the resolver can't tell "not
    // running" apart from "running but silent", so both retry the same way.

    @Test func emptyResolvedProcessSetSurfacesProcessNotYetAudible() {
        let coordinator = makeCoordinator(
            makeTap: { FakeProcessTap() },
            processResolver: emptyResolver(),
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.missing")
        waitFor {
            if case .failed(.processNotYetAudible) = coordinator.state(for: "com.example.missing") { return true }
            return false
        }
        #expect(coordinator.state(for: "com.example.missing") ==
                       .failed(.processNotYetAudible(bundleID: "com.example.missing")))
        #expect(PerAppCaptureError.processNotYetAudible(bundleID: "x").isRetryable)
    }

    // MARK: - Tap-creation failure (e.g. processNotYetAudible) surfaces as .failed AND tears down.

    @Test func processNotYetAudibleSurfacesErrorAndTearsDown() {
        let tap = FakeProcessTap()
        tap.startError = .processNotYetAudible(bundleID: "com.example.silent")
        let (resolver, _) = makeResolver(bundleID: "com.example.silent", objectID: 1, pid: 999)
        let coordinator = makeCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.silent")
        waitFor {
            if case .failed = coordinator.state(for: "com.example.silent") { return true }
            return false
        }
        #expect(coordinator.state(for: "com.example.silent") ==
                       .failed(.processNotYetAudible(bundleID: "com.example.silent")))
        #expect(tap.teardowns >= 1, "a failed start must tear the tap down (no leak)")
        #expect(PerAppCaptureError.processNotYetAudible(bundleID: "x").isRetryable)

        // Retry: start() from .failed resets and retries.
        tap.startError = nil
        coordinator.start(bundleID: "com.example.silent")
        waitFor { if case .capturing = coordinator.state(for: "com.example.silent") { return true }; return false }
        #expect(coordinator.state(for: "com.example.silent") == .capturing(tap.format))
    }

    // MARK: - Degenerate format (architecture review 2026-07-26, defect A):
    // a tap that hands back a non-positive sample rate must be rejected
    // BEFORE the coordinator commits it to `.capturing`, not left to trap
    // downstream — ported from NativeCaptureCoordinator's equivalent guard.

    @Test func degenerateSampleRateIsRejectedBeforeCapturing() {
        let tap = FakeProcessTap()
        tap.format = TapFormat(sampleRate: 0, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        let (resolver, _) = makeResolver(bundleID: "com.example.degenerate", objectID: 1, pid: 555)
        let coordinator = makeCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.degenerate")
        waitFor {
            if case .failed = coordinator.state(for: "com.example.degenerate") { return true }
            return false
        }
        #expect(coordinator.state(for: "com.example.degenerate") ==
                       .failed(.formatReadFailed(reason: "invalid tap sample rate 0")))
        #expect(tap.teardowns >= 1, "a rejected format must still tear the tap down (no leak)")

        // A negative rate is rejected the same way.
        tap.format = TapFormat(sampleRate: -1, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        coordinator.start(bundleID: "com.example.degenerate")
        waitFor {
            if case .failed(.formatReadFailed(let reason)) = coordinator.state(for: "com.example.degenerate") {
                return reason == "invalid tap sample rate -1"
            }
            return false
        }
    }

    // MARK: - UnavailableProcessTap (macOS < 14.2) surfaces .osUnsupported, not retryable.

    #if canImport(AudioToolbox)
    @Test func unavailableProcessTapSurfacesOSUnsupported() {
        let tap = UnavailableProcessTap()
        let processes: Set<AudioProcess> = [AudioProcess(objectID: 1, pid: 1)]
        #expect(throws: PerAppCaptureError.osUnsupported(minimum: "14.2")) {
            try tap.createAndStart(processes: processes, bundleID: "com.example.old", muteBehavior: .mutedWhenTapped)
        }
        #expect(!PerAppCaptureError.osUnsupported(minimum: "14.2").isRetryable)
    }

    @Test func unavailableProcessTapDrivenThroughCoordinatorSurfacesOSUnsupported() {
        let (resolver, _) = makeResolver(bundleID: "com.example.old", objectID: 1, pid: 1)
        let coordinator = makeCoordinator(
            makeTap: { UnavailableProcessTap() },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.old")
        waitFor {
            if case .failed(.osUnsupported) = coordinator.state(for: "com.example.old") { return true }
            return false
        }
        #expect(coordinator.state(for: "com.example.old") == .failed(.osUnsupported(minimum: "14.2")))
    }
    #endif

    // MARK: - Default-device change recreates the tap, re-resolving the process set.

    @Test func deviceChangeRecreatesTapAndReResolvesProcessSet() {
        let tap = FakeProcessTap()
        let (resolver, enumerator) = makeResolver(bundleID: "com.example.music", objectID: 10, pid: 500)
        let coordinator = makeCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        #expect(tap.lastProcesses == [AudioProcess(objectID: 10, pid: 500)])

        // The app relaunched with a new pid (and object id) before the device change fired.
        enumerator.setProcesses([RawAudioProcess(objectID: 11, pid: 501, bundleID: "com.example.music")])
        tap.format = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()
        waitFor {
            if case .capturing(let f) = coordinator.state(for: "com.example.music") { return f.sampleRate == 44100 }
            return false
        }
        #expect(tap.lastProcesses == [AudioProcess(objectID: 11, pid: 501)],
                       "device-change recreation re-resolves the process set")
        #expect(tap.teardowns >= 1, "the old tap is torn down on device change")
        #expect(tap.creates >= 2)

        coordinator.stop(bundleID: "com.example.music")
    }

    // MARK: - Telemetry (T3): a sample-rate-triggered rebuild emits a
    // capturePA/rate_rebuild line with old/new rate fields populated.
    //
    // The real HAL detection point (CoreAudioProcessTap.subscribeToDefaultOutput,
    // PerAppCaptureCoordinator.swift) isn't reachable hermetically — this
    // suite never touches that concrete Core Audio class (no live Core Audio
    // here; see that file's own doc comment on why FakeProcessTap exists).
    // This asserts the coordinator-level emission in handleDeviceChange(bundleID:)
    // instead, using this file's own established "mutate tap.format then
    // fireDeviceChange()" convention (see
    // testDeviceChangeRecreatesTapAndReResolvesProcessSet above) to simulate
    // the rate change the real listener would have detected.

    @Test func sampleRateChangeEmitsCapturePARateRebuildTelemetry() throws {
        let tap = FakeProcessTap()
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 10, pid: 500)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        #expect(tap.format.sampleRate == 48000, "sanity: the fake tap's rate before the simulated change")

        let spy = TelemetryLineSpy()
        Telemetry._installTestSink { line in spy.record(line) }
        defer { Telemetry._installTestSink(nil) }

        // Simulate the tapped output device renegotiating its nominal rate
        // (44.1 <-> 48 kHz) — the documented process-tap silent-buffer bug
        // this event exists to surface (see the "Nominal-sample-rate
        // listener" doc comment on CoreAudioProcessTap).
        tap.format = TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        tap.fireDeviceChange()
        waitFor {
            if case .capturing(let f) = coordinator.state(for: "com.example.music") { return f.sampleRate == 44100 }
            return false
        }

        // Flush barrier + clear (Telemetry's writer queue is serial/FIFO, so
        // this guarantees every write enqueued above has landed in `spy` —
        // mirrors TelemetryTests' own `drain()` helper).
        Telemetry._installTestSink(nil)

        let rebuildLine = try #require(
            spy.all.first { $0.contains("\"evt\":\"rate_rebuild\"") },
            "expected a capturePA/rate_rebuild line among: \(spy.all)")
        let obj = try #require(
            JSONSerialization.jsonObject(with: Data(rebuildLine.utf8)) as? [String: Any],
            "not a JSON object: \(rebuildLine)")
        #expect(obj["cat"] as? String == "capturePA")
        #expect(obj["bundleID"] as? String == "com.example.music")
        #expect(obj["oldRate"] as? String == "48000")
        #expect(obj["newRate"] as? String == "44100")

        coordinator.stop(bundleID: "com.example.music")
    }

    // MARK: - Telemetry (T2): a resolve emits a capturePA/process_resolved line
    // with each resolved pid's attribution layer — the per-app analog of
    // NativeCaptureCoordinator's exclusion_resolved. Diagnostic gap this closes:
    // before this, telemetry showed a route/exclusion CHANGE happened but never
    // which concrete processes (or none) a bundle id actually resolved to.

    @Test func startEmitsCapturePAProcessResolvedTelemetry() throws {
        let tap = FakeProcessTap()
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 10, pid: 500)
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )

        let spy = TelemetryLineSpy()
        Telemetry._installTestSink { line in spy.record(line) }
        defer { Telemetry._installTestSink(nil) }

        coordinator.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }

        Telemetry._installTestSink(nil)

        let resolvedLine = try #require(
            spy.all.first { $0.contains("\"evt\":\"process_resolved\"") },
            "expected a capturePA/process_resolved line among: \(spy.all)")
        let obj = try #require(
            JSONSerialization.jsonObject(with: Data(resolvedLine.utf8)) as? [String: Any],
            "not a JSON object: \(resolvedLine)")
        #expect(obj["cat"] as? String == "capturePA")
        #expect(obj["bundleID"] as? String == "com.example.music")
        #expect(obj["processCount"] as? String == "1")
        #expect(obj["processes"] as? String == "500:own")

        coordinator.stop(bundleID: "com.example.music")
    }

    /// A bundle id that resolves to ZERO processes — the exact leak signature
    /// this whole task exists to surface — must be reported explicitly, not
    /// silently folded into `.processNotYetAudible` with no detail.
    @Test func startWithUnresolvableBundleEmitsZeroProcessCountTelemetry() throws {
        let tap = FakeProcessTap()
        let coordinator = PerAppCaptureCoordinator(
            makeTap: { tap },
            processResolver: emptyResolver(),
            muteBehavior: .mutedWhenTapped
        )

        let spy = TelemetryLineSpy()
        Telemetry._installTestSink { line in spy.record(line) }
        defer { Telemetry._installTestSink(nil) }

        coordinator.start(bundleID: "com.example.ghost")
        waitFor {
            if case .failed(.processNotYetAudible) = coordinator.state(for: "com.example.ghost") { return true }
            return false
        }

        Telemetry._installTestSink(nil)

        let resolvedLine = try #require(
            spy.all.first { $0.contains("\"evt\":\"process_resolved\"") },
            "expected a capturePA/process_resolved line among: \(spy.all)")
        let obj = try #require(
            JSONSerialization.jsonObject(with: Data(resolvedLine.utf8)) as? [String: Any],
            "not a JSON object: \(resolvedLine)")
        #expect(obj["bundleID"] as? String == "com.example.ghost")
        #expect(obj["processCount"] as? String == "0")
    }


    // MARK: - Telemetry: two coordinator instances must be tellable apart.
    //
    // The app runs TWO PerAppCaptureCoordinators over the SAME bundle IDs
    // (NativeBackend.perAppCapture, routing; NativeBackend.meteringCapture,
    // the `.unmuted` metering-only one), both emitting `capturePA` transitions
    // into one telemetry stream. Undiscriminated, their lines interleave into
    // a sequence no single state machine could produce — a `from: capturing`
    // with no preceding `to: capturing` — which is exactly the "unexplained"
    // anomaly chased in docs/plans/PLAN-LIVE-TEST-HANDOFF-2026-07-25.md. The
    // `coordinator` field is what makes the two streams separable again.

    @Test func transitionTelemetryIdentifiesWhichCoordinatorInstanceEmittedIt() throws {
        let routingTap = FakeProcessTap()
        let meteringTap = FakeProcessTap()
        let (routingResolver, _) = makeResolver(bundleID: "com.example.music", objectID: 10, pid: 500)
        let (meteringResolver, _) = makeResolver(bundleID: "com.example.music", objectID: 10, pid: 500)
        let routing = makeCoordinator(
            makeTap: { routingTap }, processResolver: routingResolver, muteBehavior: .mutedWhenTapped)
        let metering = PerAppCaptureCoordinator(
            makeTap: { meteringTap }, processResolver: meteringResolver,
            muteBehavior: .unmuted, name: "AudiouterMeter", installsProcessListListener: false)

        let spy = TelemetryLineSpy()
        Telemetry._installTestSink { line in spy.record(line) }
        defer { Telemetry._installTestSink(nil) }

        // Both instances drive the SAME bundle ID, as production does.
        routing.start(bundleID: "com.example.music")
        metering.start(bundleID: "com.example.music")
        waitFor { if case .capturing = routing.state(for: "com.example.music") { return true }; return false }
        waitFor { if case .capturing = metering.state(for: "com.example.music") { return true }; return false }
        // Only the metering instance stops — the interleaving that produced the
        // "capturing -> stopping with no prior -> capturing" misread.
        metering.stop(bundleID: "com.example.music")

        Telemetry._installTestSink(nil) // flush barrier

        let transitions: [[String: Any]] = spy.all.compactMap {
            guard let obj = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
                  obj["evt"] as? String == "transition" else { return nil }
            return obj
        }
        #expect(!transitions.isEmpty, "expected capturePA transition lines among: \(spy.all)")
        for line in transitions {
            #expect(line["coordinator"] != nil, "every transition must name its instance: \(line)")
        }
        let names = Set(transitions.compactMap { $0["coordinator"] as? String })
        #expect(names == ["AirPlayController", "AudiouterMeter"],
                "the two instances must be distinguishable, got \(names)")
        // The stop belongs to the metering instance ALONE — the whole point.
        let stopping = transitions.filter { $0["to"] as? String == "stopping" }
        #expect(stopping.count == 1)
        #expect(stopping.first?["coordinator"] as? String == "AudiouterMeter")

        routing.stop(bundleID: "com.example.music")
    }

    // MARK: - STABILITY(C6) coalescing: a device-change notification arriving mid-rebuild
    // (.creatingTap) must be coalesced (Slot.pendingDeviceChange) and replayed once the
    // rebuild lands in .capturing, not dropped.

    @Test func deviceChangeDuringRebuildIsCoalescedAndReplayed() {
        let tap = FakeProcessTap()
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 1, pid: 4242)
        let coordinator = makeCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        #expect(tap.creates == 1)

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
        #expect(
            tap.creates >= 3,
            "a device-change notification arriving mid-rebuild (.creatingTap) must be coalesced and replayed once the rebuild lands in .capturing, not dropped")

        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        #expect(coordinator.state(for: "com.example.music") == .capturing(tap.format))

        coordinator.stop(bundleID: "com.example.music")
    }

    // MARK: - T3 resume self-heal: a system process-list change re-drives dead-but-retryable
    // slots through start() to .capturing; a NON-retryable dead slot is left untouched.

    @Test func processListChangeReDrivesRetryableFailedSlotButNotNonRetryable() {
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
        let coordinator = makeCoordinator(
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
        #expect(coordinator.state(for: "com.example.paused") == .capturing(tapA.format),
                       "a process-list change must re-drive a retryable .failed slot to .capturing")

        // ...while the non-retryable slot is left exactly where it was.
        #expect(coordinator.state(for: "com.example.old") == .failed(.osUnsupported(minimum: "14.2")),
                       "a non-retryable .failed slot (osUnsupported) must NOT be re-driven")

        coordinator.stop(bundleID: "com.example.paused")
        coordinator.stop(bundleID: "com.example.old")
    }

    // MARK: - Idempotency: start() while capturing is a no-op; stop() on unstarted bundle ID is a no-op.

    @Test func startIsIdempotentAndStopOnUnstartedBundleIDIsNoOp() {
        let tap = FakeProcessTap()
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 1, pid: 1)
        let coordinator = makeCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )

        coordinator.stop(bundleID: "com.example.never")
        #expect(coordinator.state(for: "com.example.never") == .idle)
        #expect(tap.creates == 0)

        coordinator.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator.state(for: "com.example.music") { return true }; return false }
        coordinator.start(bundleID: "com.example.music") // already capturing -> no second tap
        #expect(tap.creates == 1)
        coordinator.stop(bundleID: "com.example.music")
    }

    // MARK: - Coordinator deinit tears down any still-active taps (no leak backstop).

    @Test func coordinatorDeinitTearsDownRemainingTaps() {
        let tap = FakeProcessTap()
        let (resolver, _) = makeResolver(bundleID: "com.example.music", objectID: 1, pid: 1)
        var coordinator: PerAppCaptureCoordinator? = makeCoordinator(
            makeTap: { tap },
            processResolver: resolver,
            muteBehavior: .mutedWhenTapped
        )
        coordinator?.start(bundleID: "com.example.music")
        waitFor { if case .capturing = coordinator?.state(for: "com.example.music") { return true }; return false }
        #expect(tap.teardowns == 0)

        coordinator = nil
        #expect(tap.teardowns >= 1, "dropping the coordinator without stop() must not leak the tap")
    }

    // MARK: - W1-T4: live per-slot membership diffing (browser tab churn)
    //
    // A CAPTURING slot's app spawns/kills an audio child mid-session (a browser
    // opening/closing a tab) — the process set the slot should tap changes, but the
    // slot is `.capturing`, so the resume self-heal (which only re-drives DEAD
    // slots) never fires. `handleMembershipChange` diffs each capturing slot's
    // resolved process-object set against the baseline its live tap was built
    // against and RECREATES the tap on a genuine change (this coordinator's tap has
    // no in-place update path — the recreate goes through the proven
    // `handleDeviceChange` machinery), compare-before-rebuild so an unchanged set
    // does ZERO work.

    /// A child spawns under a capturing slot → the tap is recreated EXACTLY ONCE
    /// against the expanded process set (main + the new child), so the child's
    /// audio is captured too.
    @Test func childSpawnRecreatesTapWithExpandedProcessSet() {
        let tap = FakeProcessTap()
        let (resolver, enumerator) = makeResolver(bundleID: "org.mozilla.firefox", objectID: 20, pid: 700)
        let coordinator = makeCoordinator(makeTap: { tap }, processResolver: resolver)

        coordinator.start(bundleID: "org.mozilla.firefox")
        waitFor { coordinator.state(for: "org.mozilla.firefox") == .capturing(tap.format) }
        #expect(tap.lastProcesses == [AudioProcess(objectID: 20, pid: 700)])
        let createsAfterStart = tap.creates

        // A new tab starts playing: a fresh audio child (objectID 21) appears under
        // the same bundle id.
        enumerator.setProcesses([
            RawAudioProcess(objectID: 20, pid: 700, bundleID: "org.mozilla.firefox"),
            RawAudioProcess(objectID: 21, pid: 701, bundleID: "org.mozilla.firefox"),
        ])
        coordinator.handleMembershipChange()

        #expect(tap.creates == createsAfterStart + 1, "a genuine membership change recreates the tap exactly once")
        #expect(tap.lastProcesses == [AudioProcess(objectID: 20, pid: 700), AudioProcess(objectID: 21, pid: 701)],
                "the recreated tap covers the expanded process set")

        // Idempotence: re-diffing the settled set does no further work.
        coordinator.handleMembershipChange()
        #expect(tap.creates == createsAfterStart + 1, "the settled set must not trigger a second rebuild")
        coordinator.stop(bundleID: "org.mozilla.firefox")
    }

    /// A child dies under a capturing slot → the tap is recreated once against the
    /// shrunk process set.
    @Test func childKillRecreatesTapWithShrunkProcessSet() {
        let tap = FakeProcessTap()
        let (resolver, enumerator) = makeResolver(processes: [
            RawAudioProcess(objectID: 20, pid: 700, bundleID: "org.mozilla.firefox"),
            RawAudioProcess(objectID: 21, pid: 701, bundleID: "org.mozilla.firefox"),
        ])
        let coordinator = makeCoordinator(makeTap: { tap }, processResolver: resolver)

        coordinator.start(bundleID: "org.mozilla.firefox")
        waitFor { coordinator.state(for: "org.mozilla.firefox") == .capturing(tap.format) }
        #expect(tap.lastProcesses?.count == 2)
        let createsAfterStart = tap.creates

        enumerator.setProcesses([RawAudioProcess(objectID: 20, pid: 700, bundleID: "org.mozilla.firefox")]) // child gone
        coordinator.handleMembershipChange()

        #expect(tap.creates == createsAfterStart + 1)
        #expect(tap.lastProcesses == [AudioProcess(objectID: 20, pid: 700)])
        coordinator.stop(bundleID: "org.mozilla.firefox")
    }

    /// THE regression-prevention property: an unchanged process set — a duplicate
    /// notification, or churn in an unrelated app — triggers ZERO rebuilds.
    @Test func unchangedProcessSetTriggersZeroRebuilds() {
        let tap = FakeProcessTap()
        let (resolver, enumerator) = makeResolver(bundleID: "org.mozilla.firefox", objectID: 20, pid: 700)
        let coordinator = makeCoordinator(makeTap: { tap }, processResolver: resolver)

        coordinator.start(bundleID: "org.mozilla.firefox")
        waitFor { coordinator.state(for: "org.mozilla.firefox") == .capturing(tap.format) }
        let createsAfterStart = tap.creates

        coordinator.handleMembershipChange()
        // Reorder is not a change under set semantics.
        enumerator.setProcesses([RawAudioProcess(objectID: 20, pid: 700, bundleID: "org.mozilla.firefox")])
        coordinator.handleMembershipChange()

        #expect(tap.creates == createsAfterStart, "no rebuild for an unchanged process set")
        coordinator.stop(bundleID: "org.mozilla.firefox")
    }

    /// A membership diff only ever acts on CAPTURING slots — a diff while a slot is
    /// not capturing touches no tap.
    @Test func membershipDiffIgnoresNonCapturingSlots() {
        let tap = FakeProcessTap()
        // Enumerator reports nothing → start lands the slot in `.failed(.processNotYetAudible)`.
        let resolver = emptyResolver()
        let coordinator = makeCoordinator(makeTap: { tap }, processResolver: resolver)

        coordinator.start(bundleID: "org.mozilla.firefox")
        waitFor { if case .failed = coordinator.state(for: "org.mozilla.firefox") { return true }; return false }
        #expect(tap.creates == 0)

        coordinator.handleMembershipChange()
        #expect(tap.creates == 0, "a non-capturing slot must not be touched by a membership diff")
    }

    /// Rapid churn within the debounce window coalesces to a single settled diff —
    /// one recreate against the FINAL set, not one per notification. Driven through
    /// the real debounced `handleProcessListChanged` entry point.
    @Test func rapidChurnWithinDebounceWindowCoalescesToOneRebuild() {
        let tap = FakeProcessTap()
        let (resolver, enumerator) = makeResolver(bundleID: "org.mozilla.firefox", objectID: 20, pid: 700)
        let coordinator = makeCoordinator(
            makeTap: { tap }, processResolver: resolver, membershipDebounceInterval: .milliseconds(60))

        coordinator.start(bundleID: "org.mozilla.firefox")
        waitFor { coordinator.state(for: "org.mozilla.firefox") == .capturing(tap.format) }
        let createsAfterStart = tap.creates

        func procs(_ ids: [(AudioObjectID, pid_t)]) -> [RawAudioProcess] {
            ids.map { RawAudioProcess(objectID: $0.0, pid: $0.1, bundleID: "org.mozilla.firefox") }
        }
        // Three notifications inside the 60ms window, settling on {20, 22}.
        enumerator.setProcesses(procs([(20, 700), (21, 701)])); coordinator.handleProcessListChanged()
        enumerator.setProcesses(procs([(20, 700)]));            coordinator.handleProcessListChanged()
        enumerator.setProcesses(procs([(20, 700), (22, 702)])); coordinator.handleProcessListChanged()

        waitFor { tap.creates >= createsAfterStart + 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2)) // let any extra rebuilds surface

        #expect(tap.creates == createsAfterStart + 1, "the burst coalesces to a single settled rebuild")
        #expect(tap.lastProcesses == [AudioProcess(objectID: 20, pid: 700), AudioProcess(objectID: 22, pid: 702)],
                "the coalesced diff applies the SETTLED process set")
        coordinator.stop(bundleID: "org.mozilla.firefox")
    }

    // MARK: - DefaultOutputDeviceMonitor subscription (T2 consolidation)

    /// GUARD SEMANTICS, per-app side. Same contract the whole-system tap is held
    /// to (`wholeSystemTapReportsItsOwnStateLiveToTheMonitor`): the tap reports
    /// its OWN live device/rate at every notification. The middle expectation is
    /// the load-bearing one — the tap's format drifts while the device's rate
    /// stays put, which only a fresh read can see.
    @available(macOS 14.2, *)
    @Test func perAppTapReportsItsOwnStateLiveToTheMonitor() {
        let hal = TapMonitorFakeHAL(deviceID: 7, rate: 48_000)
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        let tap = CoreAudioProcessTap(name: "test", monitor: monitor)
        let fires = TapMonitorFireCounter()
        tap.onDefaultDeviceChanged = { fires.bump() }

        tap.test_seedTrackedState(deviceID: 7, sampleRate: 48_000)
        tap.subscribeToDefaultOutput(bundleID: "com.example.app")

        hal.fire(kAudioDevicePropertyNominalSampleRate)
        #expect(fires.count == 0, "a no-op re-announcement must not rebuild this per-app tap")

        tap.test_seedTrackedState(deviceID: 7, sampleRate: 44_100)
        hal.fire(kAudioDevicePropertyNominalSampleRate)
        #expect(fires.count == 1,
            "a per-app tap whose own format drifted must still be told — proves `tracked` is read live, not captured at subscribe time")

        tap.test_seedTrackedState(deviceID: 7, sampleRate: 48_000)
        hal.deviceID = 8
        hal.fire(kAudioHardwarePropertyDefaultOutputDevice)
        #expect(fires.count == 2, "a genuine default-output-device change must rebuild the per-app tap")

        tap.teardown()
    }

    @available(macOS 14.2, *)
    @Test func perAppTapTeardownUnsubscribesFromTheMonitor() {
        let hal = TapMonitorFakeHAL(deviceID: 7, rate: 48_000)
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        let tap = CoreAudioProcessTap(name: "test", monitor: monitor)
        tap.test_seedTrackedState(deviceID: 7, sampleRate: 48_000)
        tap.subscribeToDefaultOutput(bundleID: "com.example.app")
        #expect(monitor.subscriberCount == 1)

        tap.teardown()
        #expect(monitor.subscriberCount == 0, "teardown must release the tap's monitor subscription")
        tap.teardown()
        #expect(monitor.subscriberCount == 0, "a second teardown must stay a no-op")
    }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
