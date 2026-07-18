import XCTest
import AirPlayEngine
@testable import AudioutedCore

/// Hermetic tests for ``NativeBackend`` (T-NB-BACKEND-1): a spy ``EngineControlling``
/// (records ops, fires synthetic state transitions) + an injected ``DiscoverySource``
/// double (feeds `DiscoveryEvent`s synchronously). No engine thread, no C cluster,
/// no `NWBrowser`, no network, no TCC.
///
/// Covers: `deviceAdded` on discovery, AP1 surfaced-unavailable-and-never-added,
/// `deviceUpdated` on an out-of-band engine state transition, best-effort
/// convergence (D4), and the mute stash/restore shim.
final class NativeBackendTests: XCTestCase {

    // MARK: Doubles

    /// Records every engine op and lets a test drive the device-state stream.
    private final class SpyEngine: EngineControlling, @unchecked Sendable {
        let lock = NSLock()
        private(set) var started = false
        private(set) var stopped = false
        private(set) var discoveryFed: [OutputID] = []
        private(set) var discoveryRemoved: [String] = []   // descriptor names
        private(set) var added: [OutputID] = []
        private(set) var removed: [OutputID] = []
        private(set) var volumes: [(OutputID, Double)] = []
        private(set) var bufferSets: [Int] = []
        /// Interleaved op order (`remove:N` / `setBuffer:N` / `add:N` /
        /// `volume:N`) — the applyStartBuffer invariant is about ORDER across
        /// op kinds (all removes, then the buffer set, then re-adds), which the
        /// per-kind arrays above can't express.
        private(set) var opLog: [String] = []

        /// Ids that should THROW on `addOutput` (best-effort partial-failure test).
        var addFailures: Set<UInt64> = []
        /// Ids that should THROW on `removeOutput`.
        var removeFailures: Set<UInt64> = []

        /// Optional hook run INSIDE `addOutput`'s op body, after the add is recorded
        /// but before it returns successfully. Lets a test deterministically inject
        /// an out-of-band state transition in the window between addOutput resolving
        /// and NativeBackend's post-success write (medium finding).
        var onAddOutputBody: (@Sendable (OutputID) -> Void)?

        /// Artificial per-op latency (ns). Used by the toggle-spam test to force
        /// slow op completions to race fast toggle flips, so a broken (unserialized)
        /// converge would issue overlapping ops for the same device.
        var opDelayNanos: UInt64 = 0

        /// Count of `updateDiscovery` calls per parsed OutputID (root cause 2: assert
        /// no re-feed of an unchanged descriptor per toggle).
        private var feedCounts: [UInt64: Int] = [:]
        /// The max number of ops (add or remove) observed IN FLIGHT concurrently for
        /// any single device — must stay 1 with per-device serialization.
        private var inFlightByID: [UInt64: Int] = [:]
        private(set) var maxConcurrentPerDevice = 0

        private var continuation: AsyncStream<(OutputID, OutputState)>.Continuation?

        func start() async throws { lock.withLock { started = true } }
        func stop() async { lock.withLock { stopped = true } }

        @discardableResult
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            let id = descriptor.parsedID ?? OutputID(rawValue: 0)
            lock.withLock {
                discoveryFed.append(id)
                feedCounts[id.rawValue, default: 0] += 1
            }
            return id
        }
        func removeDiscovery(_ descriptor: DeviceDescriptor) async {
            lock.withLock { discoveryRemoved.append(descriptor.name) }
        }
        func addOutput(_ id: OutputID) async throws {
            try await runOp(id) {
                self.lock.withLock { self.added.append(id); self.opLog.append("add:\(id.rawValue)") }
                let hook = self.lock.withLock { self.onAddOutputBody }
                hook?(id)
                if self.addFailures.contains(id.rawValue) { throw AirPlayEngineError.sessionFailed }
            }
        }
        func removeOutput(_ id: OutputID) async throws {
            try await runOp(id) {
                self.lock.withLock { self.removed.append(id); self.opLog.append("remove:\(id.rawValue)") }
                if self.removeFailures.contains(id.rawValue) { throw AirPlayEngineError.sessionFailed }
            }
        }

        /// Per-app stream bind (T6). Recorded SEPARATELY from the legacy `added`
        /// (stream_id 0) so per-app assertions never perturb the whole-system tests.
        private(set) var streamAdds: [(OutputID, UInt32)] = []
        func addOutput(_ id: OutputID, streamId: UInt32) async throws {
            try await runOp(id) {
                self.lock.withLock {
                    self.streamAdds.append((id, streamId))
                    self.opLog.append("streamAdd:\(id.rawValue):\(streamId)")
                }
                if self.addFailures.contains(id.rawValue) { throw AirPlayEngineError.sessionFailed }
            }
        }

        /// Per-app mixed-buffer writes (T6), tagged with stream id + byte count.
        private(set) var writes: [(streamId: UInt32, byteCount: Int)] = []
        /// Same writes, but with the FULL pcm payload retained (not just its
        /// count) — lets a cross-stream-leakage test assert on actual byte
        /// CONTENT, not just size/streamId bookkeeping (T10).
        private(set) var rawWrites: [(streamId: UInt32, pcm: Data)] = []
        func write(pcm: Data, streamId: UInt32, pts: timespec) {
            lock.withLock {
                writes.append((streamId, pcm.count))
                rawWrites.append((streamId, pcm))
            }
        }

        /// Run a device op, tracking concurrent-in-flight-per-device (to catch
        /// overlapping ops) and applying the artificial latency.
        private func runOp(_ id: OutputID, _ body: () throws -> Void) async throws {
            lock.withLock {
                let n = (inFlightByID[id.rawValue] ?? 0) + 1
                inFlightByID[id.rawValue] = n
                maxConcurrentPerDevice = max(maxConcurrentPerDevice, n)
            }
            defer { lock.withLock { inFlightByID[id.rawValue, default: 1] -= 1 } }
            let delay = lock.withLock { opDelayNanos }
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            try body()
        }

        func feedCount(for id: OutputID) -> Int { lock.withLock { feedCounts[id.rawValue] ?? 0 } }
        func setVolume(_ id: OutputID, _ volume: Double) async throws {
            lock.withLock { volumes.append((id, volume)); opLog.append("volume:\(id.rawValue)") }
        }
        func setStartBufferMs(_ ms: Int) async {
            lock.withLock { bufferSets.append(ms); opLog.append("setBuffer:\(ms)") }
        }
        func makeStateStream() -> AsyncStream<(OutputID, OutputState)> {
            AsyncStream { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }
        /// Push a synthetic out-of-band transition through the state stream.
        func pushState(_ id: OutputID, _ state: OutputState) {
            let c = lock.withLock { continuation }
            c?.yield((id, state))
        }

        // Thread-safe snapshots for assertions.
        var addedIDs: [OutputID] { lock.withLock { added } }
        var removedIDs: [OutputID] { lock.withLock { removed } }
        var fedIDs: [OutputID] { lock.withLock { discoveryFed } }
        var discoveryRemovedNames: [String] { lock.withLock { discoveryRemoved } }
        var volumeCalls: [(OutputID, Double)] { lock.withLock { volumes } }
        var bufferSetCalls: [Int] { lock.withLock { bufferSets } }
        var ops: [String] { lock.withLock { opLog } }
        var didStart: Bool { lock.withLock { started } }
        var maxConcurrent: Int { lock.withLock { maxConcurrentPerDevice } }
        var streamAddCalls: [(OutputID, UInt32)] { lock.withLock { streamAdds } }
        var writeCalls: [(streamId: UInt32, byteCount: Int)] { lock.withLock { writes } }
        var rawWriteCalls: [(streamId: UInt32, pcm: Data)] { lock.withLock { rawWrites } }
    }

    /// Feeds `DiscoveryEvent`s to the backend synchronously.
    private final class FakeDiscovery: DiscoverySource, @unchecked Sendable {
        var onEvent: (@Sendable (DiscoveryEvent) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
        func fire(_ event: DiscoveryEvent) { onEvent?(event) }
    }

    /// Fakes the Mac's own default-output volume/mute (``SystemVolumeControlling``)
    /// with NO Core Audio HAL reads and NO property listeners on real hardware.
    ///
    /// This closes a hermeticity gap: `NativeBackend`'s designated init defaults
    /// `systemVolume` to a real `SystemOutputVolume()`, so every one of this
    /// file's ~34 `backend.start()` calls used to construct a real one — reading
    /// the developer's actual default output device and installing real
    /// `AudioObjectAddPropertyListenerBlock` registrations on it. No test writes
    /// volume, so there was no hardware-slamming risk, but if the machine's
    /// volume/output changed mid-run, `onExternalChange` would fire and emit a
    /// genuine `local-mac` `deviceUpdated`, perturbing an event-sequence
    /// assertion elsewhere in the suite — the prime suspect for a real, one-off,
    /// never-reproduced flake (358 tests / 2 skips / 1 unnamed failure). Injecting
    /// this fake as `makeBackend()`'s default takes real hardware out of every
    /// test's path unconditionally.
    ///
    /// Records every `setVolume`/`setMuted` call, serves scripted
    /// `currentVolume()`/`currentMuted()` reads (independent of what was written —
    /// a test dials in whatever the "hardware" currently reports), and lets a
    /// test fire `onExternalChange` on demand to simulate a change made outside
    /// the app (media keys, the Sound menu, a default-output-device switch).
    /// Mutable state is guarded by `lock`, matching `SpyEngine`/`FakeCapture`'s
    /// discipline.
    private final class FakeSystemVolume: SystemVolumeControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _volume: Int?
        private var _muted: Bool?
        private var _volumeCalls: [Int] = []
        private var _mutedCalls: [Bool] = []
        private var _onExternalChange: (@Sendable (Int?, Bool?, Bool) -> Void)?
        private var _startCount = 0
        private var _stopCount = 0

        /// Seeds the scripted hardware reads `NativeBackend.surfaceLocalDevice()`
        /// consults via `currentVolume()`/`currentMuted()`. Both default `nil` —
        /// the "unreadable control" case a real aggregate/HDMI output can hit,
        /// which exercises the `?? 65` / `?? false` fallback.
        init(volume: Int? = nil, muted: Bool? = nil) {
            _volume = volume
            _muted = muted
        }

        func currentVolume() -> Int? { lock.withLock { _volume } }
        func currentMuted() -> Bool? { lock.withLock { _muted } }

        /// Re-script what the "hardware" reports for `currentVolume()`, simulating
        /// the user turning the Mac's system volume knob between connect episodes.
        /// (`setVolume` records the app's WRITES; this changes what a subsequent
        /// `currentVolume()` READ returns — the two are independent, matching real
        /// hardware where a read reflects the device's live level.)
        func scriptVolume(_ v: Int?) { lock.withLock { _volume = v } }

        func setVolume(_ volume: Int) {
            lock.withLock { _volumeCalls.append(volume) }
        }
        func setMuted(_ muted: Bool) {
            lock.withLock { _mutedCalls.append(muted) }
        }

        var onExternalChange: (@Sendable (Int?, Bool?, Bool) -> Void)? {
            get { lock.withLock { _onExternalChange } }
            set { lock.withLock { _onExternalChange = newValue } }
        }

        func start() { lock.withLock { _startCount += 1 } }
        func stop() { lock.withLock { _stopCount += 1 } }

        // Thread-safe snapshots for assertions.
        var volumeCalls: [Int] { lock.withLock { _volumeCalls } }
        var mutedCalls: [Bool] { lock.withLock { _mutedCalls } }
        var startCount: Int { lock.withLock { _startCount } }
        var stopCount: Int { lock.withLock { _stopCount } }

        /// Simulate a change made OUTSIDE this app by firing the callback
        /// `NativeBackend.start()` registered. A harmless no-op if nothing is
        /// registered yet (e.g. fired before `backend.start()`, or after
        /// `backend.stop()` cleared it).
        ///
        /// `defaultDeviceChanged` defaults to `false` — a volume/mute gesture on the
        /// device that was already the default, which is what every pre-existing
        /// caller here means. Pass `true` to simulate the default output device
        /// itself switching (speakers → AirPods), which reports the NEW device's
        /// state and must not be mistaken for a gesture.
        func fireExternalChange(volume: Int?, muted: Bool?, defaultDeviceChanged: Bool = false) {
            let handler = lock.withLock { _onExternalChange }
            handler?(volume, muted, defaultDeviceChanged)
        }
    }

    // MARK: Fixtures

    private func ap2Device(id: String = "AA:BB:CC:DD:EE:01", name: String = "Sonos Move", model: String = "S13") -> DiscoveredDevice {
        let txt = ["deviceid": id, "model": model, "features": "0x445F8A00,0x1C340"]
        let (parsedID, outputID) = NativeDiscovery.parseDeviceID(txt)!
        let desc = DeviceDescriptor(name: name, address: "192.168.1.10", family: .ipv4, port: 7000, txtRecord: txt)
        return DiscoveredDevice(id: parsedID, descriptor: desc, outputID: outputID, isAirPlay2Supported: true)
    }

    private func ap1Device(id: String = "AA:BB:CC:DD:EE:99", name: String = "Old Express") -> DiscoveredDevice {
        let txt = ["deviceid": id, "model": "AirPort4,107"]
        let (parsedID, outputID) = NativeDiscovery.parseDeviceID(txt)!
        let desc = DeviceDescriptor(name: name, address: "192.168.1.20", family: .ipv4, port: 5000, txtRecord: txt)
        return DiscoveredDevice(id: parsedID, descriptor: desc, outputID: outputID, isAirPlay2Supported: false)
    }

    /// `systemVolume` defaults to a fresh ``FakeSystemVolume`` so EVERY call
    /// site — all ~34 of them, unchanged — gets a hermetic double with no
    /// explicit opt-in; NO test in this file ever constructs a real
    /// `SystemOutputVolume` (see `FakeSystemVolume`'s doc comment for why that
    /// matters). Tests that need to script a readback or fire
    /// `onExternalChange` construct their own `FakeSystemVolume` and pass it
    /// explicitly to get a handle on it.
    private func makeBackend(
        systemVolume: SystemVolumeControlling = FakeSystemVolume(),
        resolvePID: @escaping @Sendable (String) -> pid_t? = { _ in nil },
        injectedPerAppCapture: PerAppCaptureCoordinator? = nil
    ) -> (NativeBackend, SpyEngine, FakeDiscovery) {
        let engine = SpyEngine()
        let discovery = FakeDiscovery()
        let backend = NativeBackend(
            engineControl: engine, discoverySource: discovery,
            systemVolume: systemVolume, resolvePID: resolvePID,
            injectedPerAppCapture: injectedPerAppCapture)
        return (backend, engine, discovery)
    }

    /// A `ProcessAudioTap` that always succeeds (T8): `createAndStart` never
    /// throws, so a coordinator built over it takes every bundle ID all the way
    /// to `.capturing` — unlike the default `resolvePID`-returns-nil setup
    /// (`PIDRecorder`), which fails fast at `.appNotRunning` by design and is
    /// what most of this file uses to exercise routing TOPOLOGY independent of
    /// real capture. Tests that need `.routedApps`/the mixer to reflect an app
    /// that's actually (fakely) streaming — e.g. it must NOT be excluded as
    /// "dead" — construct a coordinator with this tap instead.
    private final class AlwaysSucceedsTap: ProcessAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        func createAndStart(pid: pid_t, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        }
        func teardown() {}
    }

    /// A `PerAppCaptureCoordinator` whose every `start(bundleID:)` reaches
    /// `.capturing` (T8) — pass as `injectedPerAppCapture:` to `makeBackend`.
    private func workingPerAppCapture() -> PerAppCaptureCoordinator {
        PerAppCaptureCoordinator(
            makeTap: { AlwaysSucceedsTap() }, resolvePID: { _ in 4242 }, muteBehavior: .mutedWhenTapped)
    }

    /// Thread-safe recorder for the bundle IDs a per-app capture asked to resolve —
    /// proof that `updateAppRoutes` spun up (`start(bundleID:)`) the right capture.
    /// Always returns `nil` (no pid), so no real Core Audio tap is ever created:
    /// the routing TOPOLOGY (`addOutput(_:streamId:)` + `.routedApps`) still runs.
    private final class PIDRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [String] = []
        var asked: [String] { lock.withLock { _asked } }
        func resolve(_ bundleID: String) -> pid_t? {
            lock.withLock { _asked.append(bundleID) }
            return nil
        }
    }

    /// A `.device(id:)` route fixture.
    private func route(_ bundleID: String, name: String, toDevice deviceID: String, volume: Int = 100) -> AppRoute {
        AppRoute(bundleID: bundleID, displayName: name, destination: .device(id: deviceID), volume: volume)
    }

    // MARK: T10 cross-component doubles
    //
    // The fakes below back the T10 full-chain tests: they let a test push
    // ACTUAL captured buffers through the real per-app pipeline (PerAppCaptureCoordinator
    // -> AppRouteMixer -> engine.write) and exercise the real NativeCaptureCoordinator's
    // T4 exclusion logic through NativeBackend.updateAppRoutes, rather than only
    // asserting on topology (streamAddCalls) as the existing T6/T7 tests do.

    /// A `ProcessAudioTap` that always succeeds, self-registers with an external
    /// registry keyed by the bundle ID it was started for (so a test can grab a
    /// handle to THIS app's specific tap instance and `push(_:)` content into
    /// it directly), and uses the engine's exact output format (44100/16-bit
    /// interleaved S16) so buffers round-trip through the real `AVFormatConverter`
    /// essentially unchanged — letting a test assert on exact byte content.
    private final class BundleTaggingTap: ProcessAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        var onRegister: (@Sendable (String) -> Void)?
        func createAndStart(pid: pid_t, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            onRegister?(bundleID)
            return TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 16, isFloat: false, isInterleaved: true)
        }
        func teardown() {}
        func push(_ buffer: CapturedBuffer) { onBuffer?(buffer) }
    }

    /// Thread-safe bundleID -> tap registry, populated by ``BundleTaggingTap/onRegister``.
    private final class TapRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var byBundleID: [String: BundleTaggingTap] = [:]
        func register(_ bundleID: String, _ tap: BundleTaggingTap) { lock.withLock { byBundleID[bundleID] = tap } }
        func tap(for bundleID: String) -> BundleTaggingTap? { lock.withLock { byBundleID[bundleID] } }
    }

    /// A single-second, fixed-fill-byte, interleaved-S16-stereo `CapturedBuffer` —
    /// every byte is `fill`, so a downstream write can be checked for cross-app
    /// contamination with a trivial byte scan (0xAA never appears in app B's
    /// stream, 0xBB never appears in app A's).
    private func fingerprintedBuffer(fill: UInt8, frames: Int, atSecond sec: Int) -> CapturedBuffer {
        let data = Data(repeating: fill, count: frames * 2 /* ch */ * 2 /* bytes/sample */)
        return CapturedBuffer(channelData: [data], frameCount: frames, pts: timespec(tv_sec: sec, tv_nsec: 0))
    }

    /// A `SystemAudioTap` (the WHOLE-SYSTEM tap seam, not the per-app one) that
    /// records the `excludedPIDs` it was last created with — lets a test drive
    /// the REAL ``NativeCaptureCoordinator`` (not a direct call to its
    /// `updateRouting`) through `NativeBackend.updateAppRoutes` and observe T4's
    /// exclusion list end to end.
    private final class RecordingSystemTap: SystemAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        private let lock = NSLock()
        private var _excludedPIDs: Set<pid_t> = []
        private var _createCount = 0
        func createAndStart(muteBehavior: TapMuteBehavior, excludedPIDs: Set<pid_t>) throws -> TapFormat {
            lock.withLock { _excludedPIDs = excludedPIDs; _createCount += 1 }
            return TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 16, isFloat: false, isInterleaved: true)
        }
        func teardown() {}
        var excludedPIDs: Set<pid_t> { lock.withLock { _excludedPIDs } }
        var createCount: Int { lock.withLock { _createCount } }
    }

    private final class NoOpSink: PCMSink {
        func write(pcm: Data, pts: timespec) {}
    }

    private struct PassthroughConverter: PCMConverting {
        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? { buffer.channelData.first }
    }

    /// A `ProcessAudioTap` whose `createAndStart` throws `.processNotYetAudible`
    /// for the first `failuresBeforeSuccess` attempts, then succeeds — scripts
    /// T8's bounded-retry recovery path (`NativeBackend.scheduleProcessNotYetAudibleRetry`)
    /// deterministically.
    private final class FlakyThenSucceedsTap: ProcessAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        private let lock = NSLock()
        private var attempts = 0
        let failuresBeforeSuccess: Int
        init(failuresBeforeSuccess: Int) { self.failuresBeforeSuccess = failuresBeforeSuccess }
        func createAndStart(pid: pid_t, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            let n = lock.withLock { attempts += 1; return attempts }
            if n <= failuresBeforeSuccess {
                throw PerAppCaptureError.processNotYetAudible(bundleID: bundleID)
            }
            return TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 16, isFloat: false, isInterleaved: true)
        }
        func teardown() {}
        var attemptsMade: Int { lock.withLock { attempts } }
    }

    /// Collect non-level events until `predicate` holds or timeout.
    private func collect(
        from backend: NativeBackend,
        timeout: TimeInterval = 3,
        until predicate: @escaping @Sendable ([BackendEvent]) -> Bool
    ) async -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let done = expectation(description: "predicate satisfied")
        let box = EventBox()
        let task = Task {
            for await event in stream {
                if case .level = event { continue }
                let all = await box.append(event)
                if predicate(all) { done.fulfill(); break }
            }
        }
        await fulfillment(of: [done], timeout: timeout)
        task.cancel()
        return await box.snapshot()
    }

    private actor EventBox {
        private var events: [BackendEvent] = []
        func append(_ e: BackendEvent) -> [BackendEvent] { events.append(e); return events }
        func snapshot() -> [BackendEvent] { events }
    }

    private func waitUntilStarted(_ engine: SpyEngine) async {
        for _ in 0..<200 {
            if engine.didStart { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Tests

    /// An AP2 discovery `.appeared` surfaces `deviceAdded` (available, AP2) and
    /// feeds the engine's descriptor so it becomes addOutput-able.
    func testDiscoveryAppearedEmitsDeviceAddedAndFeedsEngine() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        let added = events.compactMap { if case .deviceAdded(let d) = $0 { return d } else { return nil } }
        let d = added.first { $0.id == device.id }
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.supportsAirPlay2, true)
        XCTAssertEqual(d?.isAvailable, true)
        XCTAssertEqual(d?.name, "Sonos Move")
        XCTAssertEqual(d?.kind, .sonos)

        // The engine got the AP2 descriptor.
        await pollUntil { engine.fedIDs.contains(device.outputID) }
        XCTAssertTrue(engine.fedIDs.contains(device.outputID), "AP2 device should be fed to the engine")
    }

    /// An AP1-only device is surfaced `deviceAdded` with supportsAirPlay2=false AND
    /// isAvailable=false, is NEVER fed to the engine, and is NEVER addOutput-ed even
    /// when included in a `setOutputSet`.
    func testAirPlay1SurfacedUnavailableNeverAdded() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap1 = ap1Device()
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap1.id } else { return false } }
        } after: { discovery.fire(.appeared(ap1)) }

        let d = events.compactMap { if case .deviceAdded(let x) = $0 { return x } else { return nil } }.first { $0.id == ap1.id }
        XCTAssertEqual(d?.supportsAirPlay2, false)
        XCTAssertEqual(d?.isAvailable, false, "AP1-only device must be surfaced unavailable (D6)")

        // Never fed to the engine.
        XCTAssertTrue(engine.fedIDs.isEmpty, "AP1 device must NOT be fed to the AP2 engine")

        // Even if the app tries to select it, it is never addOutput-ed.
        backend.setOutputSet([ap1.id])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(engine.addedIDs.isEmpty, "AP1 device must NEVER be addOutput-ed (D6)")
    }

    // MARK: Current (local) device (BUG B)

    /// `start()` surfaces the Mac's own output as a local device: isLocalDevice,
    /// kind == .localMac, available, supportsAirPlay2 == false — mirroring
    /// MockBackend's local fixture so the popover renders a "Current Device" row.
    func testStartSurfacesLocalCurrentDevice() async {
        let (backend, engine, _) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        // Poll: the local device is added on stateQueue at start().
        await pollUntil { backend.devices.contains { $0.isLocalDevice } }
        let local = backend.devices.first { $0.isLocalDevice }
        XCTAssertNotNil(local, "NativeBackend must surface a current/local device")
        XCTAssertEqual(local?.kind, .localMac)
        XCTAssertEqual(local?.isAvailable, true)
        XCTAssertEqual(local?.supportsAirPlay2, false, "local device mirrors MockBackend: not AP2")
        XCTAssertEqual(local?.id, NativeBackend.localDeviceID)
        XCTAssertFalse(local?.name.isEmpty ?? true, "local device must have a name")
    }

    /// The local device is emitted as a `deviceAdded` event to subscribers.
    func testLocalDeviceEmittedAsDeviceAdded() async {
        let (backend, _, _) = makeBackend()
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.isLocalDevice } else { return false } }
        } after: { backend.start() }
        defer { backend.stop() }

        let local = events.compactMap { if case .deviceAdded(let d) = $0, d.isLocalDevice { return d } else { return nil } }.first
        XCTAssertNotNil(local, "local device should arrive as deviceAdded")
        XCTAssertEqual(local?.kind, .localMac)
    }

    /// The local device is NEVER fed to the engine nor addOutput-ed, even when a
    /// `setOutputSet` names it (it is not AP2, so it is structurally skipped).
    func testLocalDeviceNeverReachesEngine() async {
        let (backend, engine, _) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.contains { $0.isLocalDevice } }

        backend.setOutputSet([NativeBackend.localDeviceID])
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(engine.fedIDs.isEmpty, "local device must NOT be fed to the engine")
        XCTAssertTrue(engine.addedIDs.isEmpty, "local device must NEVER be addOutput-ed")
    }

    // MARK: Current (local) device — volume/mute (SystemVolumeControlling)
    //
    // The local row's slider/mute drive `SystemVolumeControlling` directly
    // (`NativeBackend.setVolume`/`setMuted`'s `id == localDeviceID` branch),
    // never the engine. `FakeSystemVolume` (MARK: Doubles, above) keeps every
    // one of these hermetic — no Core Audio HAL read/write, no property
    // listener, ever touches the developer's real Mac.

    /// `setVolume` on the local id writes through the fake's hardware seam
    /// (recorded) and optimistically echoes the model — and never touches the
    /// engine (the local id has no `outputIDs` entry).
    func testSetVolumeOnLocalDeviceWritesHardwareAndEchoesModel() async {
        let volume = FakeSystemVolume()
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.contains { $0.isLocalDevice } }

        let events = await collect(from: backend) { events in
            events.contains {
                if case .deviceUpdated(let d) = $0 { return d.isLocalDevice && d.volume == 70 }
                return false
            }
        } after: { backend.setVolume(70, for: NativeBackend.localDeviceID) }

        XCTAssertTrue(events.contains {
            if case .deviceUpdated(let d) = $0 { return d.isLocalDevice && d.volume == 70 }
            return false
        }, "setVolume on the local id must echo the model")
        XCTAssertEqual(volume.volumeCalls, [70], "setVolume on the local id must write through the hardware seam")
        XCTAssertTrue(engine.volumeCalls.isEmpty, "local volume must never reach the engine")
    }

    /// `setMuted` on the local id goes through REAL hardware mute — deliberately
    /// NOT the engine path's volume-0-with-stash shim. Proven two ways: the
    /// engine never sees a `setVolume` call, and the model's `volume` field is
    /// untouched by the mute (the shim would have forced it to 0).
    func testSetMutedOnLocalDeviceUsesRealHardwareMuteNotVolumeShim() async {
        let volume = FakeSystemVolume(volume: 55, muted: false)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.volume == 55 }

        backend.setMuted(true, for: NativeBackend.localDeviceID)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.isMuted == true }

        XCTAssertEqual(volume.mutedCalls, [true], "local mute must go through the real hardware mute path")
        let d = backend.devices.first { $0.isLocalDevice }
        XCTAssertEqual(d?.isMuted, true)
        XCTAssertEqual(d?.volume, 55, "local mute must NOT run the engine's volume-0 shim — the slider position is untouched")
        XCTAssertTrue(engine.volumeCalls.isEmpty, "local mute must never push a volume to the engine (no outputIDs entry for local-mac)")
    }

    /// The local row seeds its volume/isMuted from `currentVolume()`/
    /// `currentMuted()` (scripted here), not a fabricated default — the row must
    /// open showing where the Mac's volume actually is.
    func testLocalDeviceSeedsFromScriptedHardwareState() async {
        let volume = FakeSystemVolume(volume: 42, muted: true)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.contains { $0.isLocalDevice } }

        let local = backend.devices.first { $0.isLocalDevice }
        XCTAssertEqual(local?.volume, 42, "the local row must seed from currentVolume(), not a fabricated default")
        XCTAssertEqual(local?.isMuted, true, "the local row must seed from currentMuted(), not a fabricated default")
    }

    /// When the hardware read is unreadable (`nil` — many aggregate/HDMI
    /// outputs), the local row falls back to 65/false rather than propagating
    /// `nil` (which would either crash or render as a fabricated 0).
    func testLocalDeviceSeedFallsBackWhenHardwareUnreadable() async {
        let volume = FakeSystemVolume(volume: nil, muted: nil)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.contains { $0.isLocalDevice } }

        let local = backend.devices.first { $0.isLocalDevice }
        XCTAssertEqual(local?.volume, 65, "an unreadable currentVolume() must fall back to 65")
        XCTAssertEqual(local?.isMuted, false, "an unreadable currentMuted() must fall back to false")
    }

    /// The local id's volume clamps 0–100 exactly like the AirPlay path
    /// (`Int.clampedToVolume`), and the fake receives the CLAMPED value, not the
    /// raw input.
    func testLocalDeviceVolumeClampingMatchesAirPlayPath() async {
        let volume = FakeSystemVolume()
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.contains { $0.isLocalDevice } }

        backend.setVolume(150, for: NativeBackend.localDeviceID)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.volume == 100 }
        XCTAssertEqual(backend.devices.first { $0.isLocalDevice }?.volume, 100, "150 must clamp to 100")
        XCTAssertEqual(volume.volumeCalls.last, 100, "the fake must receive the CLAMPED value, matching the AirPlay path")

        backend.setVolume(-5, for: NativeBackend.localDeviceID)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.volume == 0 }
        XCTAssertEqual(backend.devices.first { $0.isLocalDevice }?.volume, 0, "-5 must clamp to 0")
        XCTAssertEqual(volume.volumeCalls.last, 0)
    }

    /// TWO-WAY SYNC: a change made outside the app (media keys, Sound menu, a
    /// default-device switch) flows back in as a `local-mac` `deviceUpdated`
    /// carrying both fresh values.
    func testLocalDeviceExternalChangeEmitsDeviceUpdated() async {
        let volume = FakeSystemVolume(volume: 50, muted: true)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil {
            let d = backend.devices.first { $0.isLocalDevice }
            return d?.volume == 50 && d?.isMuted == true
        }

        let events = await collect(from: backend) { events in
            events.contains {
                if case .deviceUpdated(let d) = $0 { return d.isLocalDevice && d.volume == 30 && d.isMuted == false }
                return false
            }
        } after: { volume.fireExternalChange(volume: 30, muted: false) }

        XCTAssertTrue(events.contains {
            if case .deviceUpdated(let d) = $0 { return d.isLocalDevice && d.volume == 30 && d.isMuted == false }
            return false
        }, "an external hardware change must sync back to the local row as a deviceUpdated")
    }

    /// A `nil` field in `onExternalChange` (a control that's unreadable at that
    /// instant) must be SKIPPED, not applied — a nil volume must not zero the
    /// row, and symmetrically a nil mute must not reset the last-known mute.
    func testLocalDeviceExternalChangeSkipsNilFields() async {
        let volume = FakeSystemVolume(volume: 55, muted: false)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil {
            let d = backend.devices.first { $0.isLocalDevice }
            return d?.volume == 55 && d?.isMuted == false
        }

        // nil VOLUME must not zero the row.
        volume.fireExternalChange(volume: nil, muted: true)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.isMuted == true }
        var d = backend.devices.first { $0.isLocalDevice }
        XCTAssertEqual(d?.isMuted, true)
        XCTAssertEqual(d?.volume, 55, "a nil volume in onExternalChange must not zero the row")

        // nil MUTE must not reset the last-known mute state.
        volume.fireExternalChange(volume: 99, muted: nil)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.volume == 99 }
        d = backend.devices.first { $0.isLocalDevice }
        XCTAssertEqual(d?.volume, 99)
        XCTAssertEqual(d?.isMuted, true, "a nil mute in onExternalChange must not reset the last-known mute state")
    }

    /// NO-OP SUPPRESSION: `onExternalChange` firing with values equal to the
    /// row's current state must emit NOTHING — `applyLocal`'s `device != before`
    /// guard swallows it (nothing legitimately changed).
    func testLocalDeviceExternalChangeNoOpSuppressesEmit() async {
        let volume = FakeSystemVolume(volume: 42, muted: false)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil {
            let d = backend.devices.first { $0.isLocalDevice }
            return d?.volume == 42 && d?.isMuted == false
        }

        // Subscribe BEFORE firing so the (absence of an) emit is actually observed.
        let stream = backend.makeEventStream()
        let box = EventBox()
        let task = Task {
            for await event in stream {
                if case .level = event { continue }
                _ = await box.append(event)
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000) // let the subscription register

        volume.fireExternalChange(volume: 42, muted: false) // == current state exactly
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        let events = await box.snapshot()
        XCTAssertFalse(events.contains {
            if case .deviceUpdated(let d) = $0 { return d.isLocalDevice }
            return false
        }, "onExternalChange with unchanged volume/mute must emit nothing")
    }

    // MARK: Volume-key mirror — `BackendEvent.systemVolumeChanged`
    //
    // The volume keys move the system output = the local "Current Device", which the
    // capture tap MUTES while streaming — so they adjusted a device nobody could hear
    // (ahh, live session 2026-07-17). This backend republishes a genuine external
    // change as `.systemVolumeChanged` and `AppDelegate` hands it to
    // `GroupController.mirrorSystemVolumeToMainOut(_:)`. The backend must NOT know
    // `GroupController` exists — it only states the fact.
    //
    // What these pin down is WHICH facts qualify: the filters are the whole safety
    // story, since anything emitted here ends up scaling real speakers.

    private func systemVolumeEvents(in events: [BackendEvent]) -> [Int] {
        events.compactMap { if case .systemVolumeChanged(let v) = $0 { return v } else { return nil } }
    }

    /// A genuine external volume change (media keys / Sound menu) republishes as
    /// `.systemVolumeChanged` alongside the local row's `deviceUpdated`.
    func testExternalVolumeChangeEmitsSystemVolumeChanged() async {
        let volume = FakeSystemVolume(volume: 50, muted: false)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.volume == 50 }

        let events = await collect(from: backend) { events in
            events.contains { if case .systemVolumeChanged = $0 { return true } else { return false } }
        } after: { volume.fireExternalChange(volume: 30, muted: false) }

        XCTAssertEqual(systemVolumeEvents(in: events), [30],
                       "an external volume change must republish for the Main Out mirror")
    }

    /// A DEFAULT-DEVICE SWITCH (speakers → AirPods) also reports a fresh volume, but
    /// that's the new device's pre-existing level — not a user gesture. It must
    /// relabel/sync the row and emit NOTHING for the mirror: mirroring it would slam
    /// every AirPlay speaker to whatever the headphones happened to be set to.
    func testDefaultDeviceSwitchSyncsRowButDoesNotEmitSystemVolumeChanged() async {
        let volume = FakeSystemVolume(volume: 50, muted: false)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.volume == 50 }

        // The row still syncs (that's the two-way sync's job) — wait on THAT, so the
        // absence of the mirror event below is observed after the work is done.
        let events = await collect(from: backend) { events in
            events.contains {
                if case .deviceUpdated(let d) = $0 { return d.isLocalDevice && d.volume == 90 }
                return false
            }
        } after: { volume.fireExternalChange(volume: 90, muted: false, defaultDeviceChanged: true) }

        XCTAssertTrue(events.contains {
            if case .deviceUpdated(let d) = $0 { return d.isLocalDevice && d.volume == 90 }
            return false
        }, "a default-device switch must still sync the local row")
        XCTAssertEqual(systemVolumeEvents(in: events), [],
                       "a device switch is NOT a volume gesture — it must never drive the mirror")
    }

    /// `onExternalChange` also fires for a mute-only change. The volume didn't move,
    /// so there is nothing to mirror — emitting would write the same values back to
    /// every speaker for a keypress that wasn't about volume.
    func testMuteOnlyExternalChangeDoesNotEmitSystemVolumeChanged() async {
        let volume = FakeSystemVolume(volume: 50, muted: false)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.volume == 50 }

        let events = await collect(from: backend) { events in
            events.contains {
                if case .deviceUpdated(let d) = $0 { return d.isLocalDevice && d.isMuted }
                return false
            }
        } after: { volume.fireExternalChange(volume: 50, muted: true) }   // volume UNCHANGED

        XCTAssertEqual(systemVolumeEvents(in: events), [],
                       "a mute-only change must not republish an unmoved volume")
    }

    /// OUR OWN WRITES MUST NOT MIRROR. Dragging the Current Device slider goes through
    /// `setVolume(_:for:)` on the local id; that must never come back as an external
    /// change, or the slider would scale the AirPlay speakers too.
    ///
    /// On real hardware `SystemOutputVolume` is what guarantees it — its echo
    /// suppression compares a fresh read against its last-known state (updated on
    /// every write), so `onExternalChange` never fires for a value we set. This pins
    /// the other half: the backend doesn't manufacture the event on its own.
    func testOwnLocalVolumeWriteDoesNotEmitSystemVolumeChanged() async {
        let volume = FakeSystemVolume(volume: 50, muted: false)
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.volume == 50 }

        let events = await collect(from: backend) { events in
            events.contains {
                if case .deviceUpdated(let d) = $0 { return d.isLocalDevice && d.volume == 70 }
                return false
            }
        } after: { backend.setVolume(70, for: NativeBackend.localDeviceID) }

        XCTAssertEqual(volume.volumeCalls, [70], "precondition: the write did reach the hardware seam")
        XCTAssertEqual(systemVolumeEvents(in: events), [],
                       "our own local write must not be republished as an external change")
    }

    /// END-TO-END NO-FEEDBACK PROOF, across the real seam rather than by inspection:
    /// backend event → `AppDelegate`'s one-line wiring → `GroupController` mirror →
    /// `backend.setVolume`. A volume key while streaming must move the AirPlay
    /// device's volume and write NOTHING back to the system volume — if it did, the
    /// listener that started this would re-fire and the loop would spin.
    func testVolumeKeyMirrorDrivesAirPlayAndNeverWritesBackToSystemVolume() async throws {
        let systemVolume = FakeSystemVolume(volume: 50, muted: false)
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let speaker = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == speaker.id } else { return false } }
        } after: { discovery.fire(.appeared(speaker)) }
        await pollUntil { backend.devices.contains { $0.isLocalDevice } }

        let controller = GroupController(
            backend: backend,
            store: GroupStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)),
            loadPersisted: false)
        controller.ensureDefaultSelection()                     // {local} — passthrough
        _ = controller.setDeviceSelected(speaker.id, true)      // auto-swap drops local ⇒ streaming
        XCTAssertFalse(controller.isPassthrough, "precondition: streaming to the AirPlay speaker")

        // Exactly what AppDelegate.apply(_:) does with this event, and nothing more.
        let stream = backend.makeEventStream()
        let mirrored = expectation(description: "system volume mirrored")
        let task = Task {
            for await event in stream {
                if case .systemVolumeChanged(let v) = event {
                    controller.mirrorSystemVolumeToMainOut(v)
                    mirrored.fulfill()
                }
            }
        }
        defer { task.cancel() }
        try? await Task.sleep(nanoseconds: 20_000_000)          // let the subscription register

        systemVolume.fireExternalChange(volume: 25, muted: false)   // ← the volume key
        await fulfillment(of: [mirrored], timeout: 3)
        await pollUntil { backend.devices.first { $0.id == speaker.id }?.volume == 25 }

        XCTAssertEqual(backend.devices.first { $0.id == speaker.id }?.volume, 25,
                       "the volume key drove the speaker that is actually playing")
        XCTAssertTrue(systemVolume.volumeCalls.isEmpty,
                      "THE NO-FEEDBACK PROOF: the mirror wrote nothing back to the system volume, so the listener cannot re-fire")
        XCTAssertEqual(backend.devices.first { $0.isLocalDevice }?.volume, 25,
                       "the local row still tracks the system volume via the two-way sync — it just isn't written TO")
    }

    /// INVARIANT: the local id is NEVER fed to the engine and never added as an
    /// output, across volume writes, mute writes, AND an explicit attempt to
    /// select it — no `updateDiscovery`/`addOutput`/engine `setVolume`, ever.
    func testLocalDeviceNeverReachesEngineAcrossVolumeMuteAndSelection() async {
        let volume = FakeSystemVolume()
        let (backend, engine, _) = makeBackend(systemVolume: volume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        await pollUntil { backend.devices.contains { $0.isLocalDevice } }

        backend.setVolume(80, for: NativeBackend.localDeviceID)
        backend.setMuted(true, for: NativeBackend.localDeviceID)
        backend.setOutputSet([NativeBackend.localDeviceID])
        await pollUntil { backend.devices.first { $0.isLocalDevice }?.volume == 80 }
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(engine.fedIDs.isEmpty, "local-mac must never be fed to engine.updateDiscovery")
        XCTAssertTrue(engine.addedIDs.isEmpty, "local-mac must never be addOutput-ed")
        XCTAssertTrue(engine.volumeCalls.isEmpty, "local-mac must never push a volume to the engine")
    }

    /// An out-of-band engine state transition (`.streaming` → `.failed` after the
    /// op resolved) emits a `deviceUpdated` marking the device unavailable.
    func testEngineStateTransitionEmitsDeviceUpdated() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Out-of-band failure arrives on the state stream (receiver dropped RTSP).
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == device.id && !d.isAvailable } else { return false } }
        } after: { engine.pushState(device.outputID, .failed) }

        XCTAssertTrue(events.contains {
            if case .deviceUpdated(let d) = $0 { return d.id == device.id && !d.isAvailable && !d.isSelected }
            else { return false }
        }, "an out-of-band .failed transition should mark the device unavailable + deselected")
    }

    /// `setOutputSet` best-effort convergence (D4): with two AP2 devices where one
    /// add fails, the succeeding one stays selected, the failing one is marked
    /// unavailable + not selected, and NOTHING is rolled back.
    func testBestEffortConvergencePartialFailure() async {
        let (backend, engine, discovery) = makeBackend()
        let ok = ap2Device(id: "AA:BB:CC:DD:EE:01", name: "Good")
        let bad = ap2Device(id: "AA:BB:CC:DD:EE:02", name: "Bad")
        engine.addFailures = [bad.outputID.rawValue]

        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        _ = await collect(from: backend) { events in
            events.filter { if case .deviceAdded = $0 { return true } else { return false } }.count >= 2
        } after: {
            discovery.fire(.appeared(ok))
            discovery.fire(.appeared(bad))
        }

        backend.setOutputSet([ok.id, bad.id])

        // Both adds were ATTEMPTED (no rollback of the good one).
        await pollUntil { engine.addedIDs.contains(ok.outputID) && engine.addedIDs.contains(bad.outputID) }
        XCTAssertTrue(engine.addedIDs.contains(ok.outputID))
        XCTAssertTrue(engine.addedIDs.contains(bad.outputID))
        XCTAssertFalse(engine.removedIDs.contains(ok.outputID), "the succeeding add must NOT be rolled back (D4)")

        // Final model: good = selected/available; bad = unavailable/not selected.
        await pollUntil {
            let devs = backend.devices
            let g = devs.first { $0.id == ok.id }
            let b = devs.first { $0.id == bad.id }
            return g?.isSelected == true && b?.isSelected == false && b?.isAvailable == false
        }
        let devs = backend.devices
        XCTAssertEqual(devs.first { $0.id == ok.id }?.isSelected, true)
        XCTAssertEqual(devs.first { $0.id == bad.id }?.isSelected, false)
        XCTAssertEqual(devs.first { $0.id == bad.id }?.isAvailable, false)
    }

    /// applyStartBuffer's core invariant (PLAN-LATENCY-SETTING.md §2): ALL
    /// streaming outputs are removed BEFORE the engine buffer set, which
    /// precedes every re-add — otherwise a surviving session keeps the shared
    /// master session (and its old buffer) alive and the re-adds silently join
    /// it. Also: volumes re-pushed after re-add, model re-selected, and the
    /// stored `startBufferMs` reflects the new value.
    func testApplyStartBufferRemovesAllThenSetsThenReadds() async {
        let (backend, engine, discovery) = makeBackend()
        let d1 = ap2Device(id: "AA:BB:CC:DD:EE:01", name: "Kitchen")
        let d2 = ap2Device(id: "AA:BB:CC:DD:EE:02", name: "Lounge")

        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        _ = await collect(from: backend) { events in
            events.filter { if case .deviceAdded = $0 { return true } else { return false } }.count >= 2
        } after: {
            discovery.fire(.appeared(d1))
            discovery.fire(.appeared(d2))
        }

        backend.setOutputSet([d1.id, d2.id])
        await pollUntil {
            let devs = backend.devices
            return devs.first { $0.id == d1.id }?.isSelected == true
                && devs.first { $0.id == d2.id }?.isSelected == true
        }

        // Baseline AFTER the initial converge — its add/volume ops are not part
        // of the apply sequence under test.
        let baseline = engine.ops.count
        await backend.applyStartBuffer(ms: 1500)

        XCTAssertEqual(backend.startBufferMs, 1500)
        XCTAssertEqual(engine.bufferSetCalls, [1500])

        let ops = Array(engine.ops.dropFirst(baseline))
        guard let setIndex = ops.firstIndex(of: "setBuffer:1500") else {
            return XCTFail("engine never saw the buffer set; ops: \(ops)")
        }
        let before = ops[..<setIndex]
        let after = ops[setIndex...]
        XCTAssertTrue(before.contains("remove:\(d1.outputID.rawValue)")
                   && before.contains("remove:\(d2.outputID.rawValue)"),
                      "ALL removals must precede the buffer set; ops: \(ops)")
        XCTAssertFalse(before.contains { $0.hasPrefix("add:") },
                       "no re-add may precede the buffer set; ops: \(ops)")
        XCTAssertTrue(after.contains("add:\(d1.outputID.rawValue)")
                   && after.contains("add:\(d2.outputID.rawValue)"),
                      "both devices must be re-added after the buffer set; ops: \(ops)")
        XCTAssertTrue(after.contains("volume:\(d1.outputID.rawValue)")
                   && after.contains("volume:\(d2.outputID.rawValue)"),
                      "volumes must be re-pushed after re-add; ops: \(ops)")

        // Model converged back: both selected again.
        let devs = backend.devices
        XCTAssertEqual(devs.first { $0.id == d1.id }?.isSelected, true)
        XCTAssertEqual(devs.first { $0.id == d2.id }?.isSelected, true)
    }

    /// With nothing streaming, applyStartBuffer reduces to the engine set —
    /// no removals, no re-adds (the silent/instant idle path the CTA relies on).
    func testApplyStartBufferWhileIdleOnlySetsBuffer() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        await backend.applyStartBuffer(ms: 2250)

        XCTAssertEqual(backend.startBufferMs, 2250)
        XCTAssertEqual(engine.bufferSetCalls, [2250])
        XCTAssertTrue(engine.removedIDs.isEmpty, "idle apply must not tear anything down")
        XCTAssertTrue(engine.addedIDs.isEmpty, "idle apply must not add anything")
    }

    /// A device that fails its re-add follows D4 best-effort: it ends
    /// unavailable + deselected, the other device comes back streaming.
    func testApplyStartBufferReaddFailureIsBestEffort() async {
        let (backend, engine, discovery) = makeBackend()
        let ok = ap2Device(id: "AA:BB:CC:DD:EE:01", name: "Good")
        let bad = ap2Device(id: "AA:BB:CC:DD:EE:02", name: "Bad")

        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        _ = await collect(from: backend) { events in
            events.filter { if case .deviceAdded = $0 { return true } else { return false } }.count >= 2
        } after: {
            discovery.fire(.appeared(ok))
            discovery.fire(.appeared(bad))
        }

        backend.setOutputSet([ok.id, bad.id])
        await pollUntil {
            let devs = backend.devices
            return devs.first { $0.id == ok.id }?.isSelected == true
                && devs.first { $0.id == bad.id }?.isSelected == true
        }

        // Fail only the RE-add (the initial converge above succeeded).
        engine.addFailures = [bad.outputID.rawValue]
        await backend.applyStartBuffer(ms: 1500)

        let devs = backend.devices
        XCTAssertEqual(devs.first { $0.id == ok.id }?.isSelected, true,
                       "the succeeding re-add must not be affected (D4)")
        XCTAssertEqual(devs.first { $0.id == bad.id }?.isSelected, false)
        XCTAssertEqual(devs.first { $0.id == bad.id }?.isAvailable, false)
    }

    /// Connecting a device with NO prior slider touch must push a real starting
    /// volume to the engine, sourced from the Mac's CURRENT system output level.
    /// Without it the engine's zero-initialized volume field leaves the session at
    /// ≈ −30 dB (silent) until the first manual slider drag — the −30 dB trap.
    func testConnectSeedsEngineVolumeFromSystemLevel() async {
        let systemVolume = FakeSystemVolume(volume: 42)
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }

        await pollUntil { engine.volumeCalls.contains { $0.0 == device.outputID } }
        XCTAssertTrue(engine.volumeCalls.contains { $0.0 == device.outputID && abs($0.1 - 0.42) < 0.001 },
                      "connect must seed the engine volume from the system level (42% → 0.42)")
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 42,
                       "the model row must reflect the seeded level")
    }

    /// When the system output volume is unreadable (`currentVolume()` == nil), the
    /// connect seed is 0% — deliberate silence, NOT a guessed non-zero level.
    func testConnectSeedsZeroWhenSystemVolumeUnreadable() async {
        let systemVolume = FakeSystemVolume(volume: nil)
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }

        await pollUntil { engine.volumeCalls.contains { $0.0 == device.outputID } }
        XCTAssertTrue(engine.volumeCalls.contains { $0.0 == device.outputID && $0.1 == 0.0 },
                      "an unreadable system volume must seed 0%, not a guess")
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 0)
    }

    /// The carve-out: a buffer-size change tears every streaming device down and
    /// re-adds it through the SAME add-success branch a reconnect uses — but it is
    /// NOT a reconnect. The user's in-session level (80%) must survive; the system
    /// level (30%) must NOT leak onto the re-added session.
    func testApplyStartBufferPreservesInSessionVolumeNotSystemLevel() async {
        let systemVolume = FakeSystemVolume(volume: 30)
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }

        // User dials in an in-session level distinct from the system level.
        backend.setVolume(80, for: device.id)
        await pollUntil { backend.devices.first { $0.id == device.id }?.volume == 80 }

        await backend.applyStartBuffer(ms: 1500)

        // If the re-add had reseeded from the system level, the model would read 30.
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 80,
                       "a buffer change must preserve the in-session level, not reset to the system level")
        XCTAssertTrue(engine.volumeCalls.last.map { $0.0 == device.outputID && abs($0.1 - 0.80) < 0.001 } ?? false,
                      "the re-push after the buffer set must restore the in-session level (0.80)")
    }

    /// Auto-recovery is NOT excluded from the connect-time reseed (product
    /// decision) — only `applyStartBuffer`'s internal re-add carve-out is. This
    /// exercises `applyEngineState`'s `.connected`/`.streaming` add-success
    /// branch directly (via `engine.pushState`), never going through
    /// `convergeDevice`'s add path, to prove the OTHER seed call site also fires.
    /// The device had a distinct in-session level (75) before it dropped; if the
    /// auto-recovery seed were (wrongly) suppressed like the buffer carve-out,
    /// the model/engine would still read 75 after the reconnect instead of the
    /// current system level (42).
    func testAutoRecoveryReconnectReseedsEngineVolume() async {
        let systemVolume = FakeSystemVolume(volume: 42)
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }
        await pollUntil { engine.volumeCalls.contains { $0.0 == device.outputID } }

        // User dials in an in-session level distinct from the system level.
        backend.setVolume(75, for: device.id)
        await pollUntil { backend.devices.first { $0.id == device.id }?.volume == 75 }

        // Receiver drops out of band (NOT a user toggle) — e.g. the RTSP
        // session died. desiredOn[id] stays true (the user never deselected).
        engine.pushState(device.outputID, .failed)
        await pollUntil { backend.devices.first { $0.id == device.id }?.isAvailable == false }

        // It auto-recovers: the engine reports a good transition on its own —
        // this never travels through convergeDevice's add-success branch.
        engine.pushState(device.outputID, .connected)
        await pollUntil { backend.devices.first { $0.id == device.id }?.isAvailable == true }

        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 42,
                       "an auto-recovery reconnect must reseed from the system level (42), not preserve the pre-drop in-session level (75)")
        XCTAssertTrue(engine.volumeCalls.last.map { $0.0 == device.outputID && abs($0.1 - 0.42) < 0.001 } ?? false,
                      "the auto-recovery reconnect must push the system volume to the engine, not skip the seed")
    }

    /// Regression (live Sonos Move test, 2026-07-17): the vendored C dispatcher
    /// always mirrors an armed `addOutput` completion onto the engine's
    /// device-state stream too (shims/outputs.c's `outputs_cb_deferred_drain`
    /// fires the completion hook, THEN the state hook, for the SAME report), so
    /// an ordinary user-initiated connect reaches BOTH connect-seed sites —
    /// `convergeDevice`'s post-`addOutput` write AND `applyEngineState`'s
    /// `.connected`/`.streaming` branch — not just the out-of-band auto-recovery
    /// case the latter exists for. Before the fix this fired TWO concurrent
    /// `engine.setVolume` calls for the SAME output; the vendored dispatcher's
    /// "one pending callback per device" `outputs_callback_add` contract turns a
    /// second concurrent call into a clobbered/leaked waiter for the first
    /// (`SWIFT TASK CONTINUATION MISUSE`), and in the live test enough of those
    /// piled up that the device eventually disconnected.
    ///
    /// This deterministically reproduces the exact race — the state-stream
    /// mirror of the connect arriving BEFORE `convergeDevice`'s own post-success
    /// write, via the same `onAddOutputBody` interleave technique
    /// `testOutOfBandFailedNotClobberedByAddSuccessWrite` uses above — and
    /// asserts the engine sees at most ONE `setVolume` call for the device, not
    /// two, no matter which of the two add-success sites gets there first.
    func testNormalConnectDoesNotDoubleSeedEngineVolumeAcrossBothSites() async {
        let systemVolume = FakeSystemVolume(volume: 55)
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:24", name: "Double Seed Race")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Force the race: the state-stream mirror of THIS SAME connect (what the
        // real dispatcher always sends) lands from inside addOutput's body — i.e.
        // before addOutput returns and before convergeDevice's own post-success
        // `stateQueue.sync` write runs — so `applyEngineState` observes
        // `wasAdded == false` and is a live candidate to seed, exactly like the
        // production race between the op-continuation resume and the state-hook
        // yield.
        engine.onAddOutputBody = { [weak engine] id in
            engine?.pushState(id, .connected)
            Thread.sleep(forTimeInterval: 0.1) // let applyEngineState run first
        }

        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }

        // Let any (wrongly) second fire-and-forget push land.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let callsForDevice = engine.volumeCalls.filter { $0.0 == device.outputID }
        XCTAssertEqual(callsForDevice.count, 1,
                       "a single connect event must push volume to the engine exactly once, even though both add-success sites raced for it")
        XCTAssertTrue(callsForDevice.first.map { abs($0.1 - 0.55) < 0.001 } ?? false,
                      "the single push must still carry the correct seeded level")
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 55,
                       "the model must reflect the seeded level regardless of which site won the race")
    }

    /// Regression (live Move 2 test, 2026-07-17): a device connected, disconnected,
    /// and reconnected MULTIPLE times in one running session must reseed from the
    /// CURRENT system volume on EVERY reconnect — not just the first. The original
    /// bug: the connect-time seed was de-duped via a hand-maintained `volumeSeeded`
    /// set that had to be cleared at every teardown path; the FIRST reconnect
    /// reseeded, but a SECOND disconnect→reconnect cycle kept the first reconnect's
    /// stale level (the set was still marked "seeded this session"), so the device
    /// came back at the wrong volume. The fix keys the seed on the `added` false→
    /// true edge — the connection ground truth already cleared at every teardown —
    /// so a missed/reordered clear can't silently skip a reseed.
    ///
    /// This drives TWO full disconnect / volume-change / reconnect cycles with the
    /// dispatcher's state-stream mirror ACTIVE (every `addOutput` also yields a
    /// `.connected` on the state stream, exactly as the vendored dispatcher does —
    /// so BOTH add-success seed sites are exercised on every connect), and asserts
    /// each reconnect reflects the new system level, on both the model and the wire.
    func testSecondReconnectReseedsFromCurrentSystemVolume() async {
        let systemVolume = FakeSystemVolume(volume: 50)
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        // Model the vendored dispatcher: every armed addOutput completion is ALSO
        // mirrored onto the device-state stream, so an ordinary connect reaches
        // `applyEngineState`'s add-success branch too (not just convergeDevice's).
        engine.onAddOutputBody = { [weak engine] id in engine?.pushState(id, .connected) }

        let device = ap2Device(id: "AA:BB:CC:DD:EE:2C", name: "Move 2")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Drives one connect (setOutputSet ON) at a scripted system level and
        // returns once the seed for THIS episode has landed on model + engine.
        func connect(at level: Int) async {
            systemVolume.scriptVolume(level)
            let baselineVolumeCalls = engine.volumeCalls.count
            backend.setOutputSet([device.id])
            await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }
            // Wait for a NEW push (this episode's seed), not a stale earlier one.
            await pollUntil { engine.volumeCalls.count > baselineVolumeCalls }
        }
        func disconnect() async {
            backend.setOutputSet([])
            await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == false }
            // Model the dispatcher mirroring the teardown too.
            engine.pushState(device.outputID, .stopped)
            await pollUntil { !Self.netAdded(engine, device.outputID) }
        }

        // Initial connect at 50.
        await connect(at: 50)
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 50,
                       "initial connect must seed the current system level (50)")

        // Cycle 1: disconnect, raise system volume to 75, reconnect.
        await disconnect()
        await connect(at: 75)
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 75,
                       "the FIRST reconnect must reseed from the new system level (75)")
        XCTAssertTrue(engine.volumeCalls.last.map { $0.0 == device.outputID && abs($0.1 - 0.75) < 0.001 } ?? false,
                      "the first reconnect must push 0.75 to the engine")

        // Cycle 2: disconnect, DROP system volume to 25, reconnect. THIS is the
        // exact step that regressed live — the second reconnect kept 75.
        await disconnect()
        await connect(at: 25)
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 25,
                       "the SECOND reconnect must ALSO reseed — from 25, not keep the first reconnect's stale 75")
        XCTAssertTrue(engine.volumeCalls.last.map { $0.0 == device.outputID && abs($0.1 - 0.25) < 0.001 } ?? false,
                      "the second reconnect must push 0.25 to the engine, proving the reseed wasn't skipped")
    }

    /// Requirement: a device muted BEFORE it (re)connects must stay effective-0
    /// on the wire — the connect-time seed must never audibly un-mute it — while
    /// its stashed/intended level is updated to track the CURRENT system volume,
    /// so a later unmute restores to that level rather than whatever the device
    /// happened to hold before it was muted.
    func testMutedDeviceStaysEffectiveZeroAfterConnectTimeSeed() async {
        let systemVolume = FakeSystemVolume(volume: 60)
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume)
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Mute BEFORE connecting (e.g. a group-mute applied ahead of selection).
        backend.setMuted(true, for: device.id)
        await pollUntil { backend.devices.first { $0.id == device.id }?.isMuted == true }

        // Now connect.
        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }
        await pollUntil { engine.volumeCalls.contains { $0.0 == device.outputID } }

        // (a) The device is not audibly un-muted: the engine must never see the
        // seeded system level (0.60) on the wire for this output, only 0.
        XCTAssertFalse(engine.volumeCalls.contains { $0.0 == device.outputID && abs($0.1 - 0.60) < 0.001 },
                       "a muted device's connect-time seed must never push the unmuted level to the engine")
        XCTAssertTrue(engine.volumeCalls.allSatisfy { $0.0 != device.outputID || $0.1 == 0.0 },
                      "every engine push for a muted device must stay 0")

        // (b) The intended level tracks the CURRENT system level (60) — proven
        // by unmuting and observing the restore. Before the connect-time seed,
        // the pre-mute stash would have been 50 (the device's default), so
        // restoring 60 here proves the seed updated the stash, not left it stale.
        backend.setMuted(false, for: device.id)
        await pollUntil { backend.devices.first { $0.id == device.id }?.isMuted == false }
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 60,
                       "unmuting after a connect-time seed must restore the current system level (60), not a stale pre-mute value")
        XCTAssertTrue(engine.volumeCalls.last.map { $0.0 == device.outputID && abs($0.1 - 0.60) < 0.001 } ?? false,
                      "unmute must push the seeded system level (0.60) to the engine")
    }

    /// Mute stashes the pre-mute volume and pushes 0 to the engine; unmute restores
    /// the stashed level and pushes it back (shim pattern).
    func testMuteStashAndRestore() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Set a known level first.
        backend.setVolume(70, for: device.id)
        await pollUntil { backend.devices.first { $0.id == device.id }?.volume == 70 }

        // Mute: model shows volume 0 + isMuted; engine pushed 0.0.
        backend.setMuted(true, for: device.id)
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isMuted == true && d?.volume == 0
        }
        XCTAssertTrue(engine.volumeCalls.contains { $0.0 == device.outputID && $0.1 == 0.0 },
                      "mute should push engine volume 0.0")

        // Unmute: restores 70 in the model AND pushes 0.7 to the engine.
        backend.setMuted(false, for: device.id)
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isMuted == false && d?.volume == 70
        }
        XCTAssertTrue(engine.volumeCalls.contains { $0.0 == device.outputID && abs($0.1 - 0.7) < 0.001 },
                      "unmute should restore the stashed level (0.7) to the engine")
    }

    /// A disappeared AP2 device is marked unavailable (kept in the model) and its
    /// descriptor is removed from the engine's discovery.
    func testDisappearedMarksUnavailableAndRemovesFromEngine() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        let events = await collect(from: backend) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == device.id && !d.isAvailable } else { return false } }
        } after: { discovery.fire(.disappeared(id: device.id, wasAirPlay2Supported: true)) }

        XCTAssertTrue(events.contains { if case .deviceUpdated(let d) = $0 { return d.id == device.id && !d.isAvailable } else { return false } })
        // Still present in the model (not removed).
        XCTAssertTrue(backend.devices.contains { $0.id == device.id })
        // Engine discovery got the removal.
        await pollUntil { engine.discoveryRemovedNames.contains(device.descriptor.name) }
        XCTAssertTrue(engine.discoveryRemovedNames.contains(device.descriptor.name))
    }

    /// Finding 6: an AP2 device that downgrades to AP1 (loses `_airplay._tcp` but
    /// stays on `_raop._tcp`) arrives as `.updated` with isAirPlay2Supported=false.
    /// The backend must tear down the live engine session (removeOutput) AND
    /// deregister the engine descriptor — otherwise it leaks a live RTSP/PTP
    /// session while the UI flips the device to unavailable.
    func testAP2ToAP1DowngradeTearsDownEngineSession() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap2 = ap2Device(id: "AA:BB:CC:DD:EE:07", name: "Flipper")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap2.id } else { return false } }
        } after: { discovery.fire(.appeared(ap2)) }

        // Select it so it is a live engine output.
        backend.setOutputSet([ap2.id])
        await pollUntil { engine.addedIDs.contains(ap2.outputID) }

        // Now it downgrades to AP1-only (same id, isAirPlay2Supported=false).
        let downgraded = DiscoveredDevice(
            id: ap2.id,
            descriptor: ap2.descriptor,
            outputID: ap2.outputID,
            isAirPlay2Supported: false)
        discovery.fire(.updated(downgraded))

        // The engine session is torn down and the descriptor deregistered.
        await pollUntil { engine.removedIDs.contains(ap2.outputID) }
        XCTAssertTrue(engine.removedIDs.contains(ap2.outputID),
                      "an AP2→AP1 downgrade must removeOutput the live engine session (finding 6)")
        await pollUntil { engine.discoveryRemovedNames.contains(ap2.descriptor.name) }
        XCTAssertTrue(engine.discoveryRemovedNames.contains(ap2.descriptor.name),
                      "an AP2→AP1 downgrade must deregister the engine descriptor (finding 6)")
    }

    /// THE BUG (live-gated 2026-07-17): a real AP2 device (Sonos Move) powered OFF
    /// loses its `_airplay._tcp` advert while `_raop._tcp` lingers. Discovery now
    /// reports this as an `.updated` with `isAirPlay2Supported == true` (STICKY)
    /// and `isAvailable == false`. The backend must: keep `supportsAirPlay2 == true`
    /// (so the UI never shows the AP1 "coming soon" row — `isUnsupported` keys off
    /// `supportsAirPlay2`), mark the device `isAvailable == false` and deselected,
    /// tear down any live engine session/descriptor, and surface a `.failed`
    /// (retry-on-click) dot — NOT the AP1 `.off` "coming soon" state.
    func testAP2GoingOfflineStaysAP2Unavailable() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap2 = ap2Device(id: "AA:BB:CC:DD:EE:08", name: "Sonos Move")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap2.id } else { return false } }
        } after: { discovery.fire(.appeared(ap2)) }

        // Stream to it (live engine output).
        backend.setOutputSet([ap2.id])
        await pollUntil { engine.addedIDs.contains(ap2.outputID) }

        // Power OFF: airplay advert dropped, raop lingers → sticky-AP2 offline.
        let offline = DiscoveredDevice(
            id: ap2.id,
            descriptor: ap2.descriptor,
            outputID: ap2.outputID,
            isAirPlay2Supported: true,   // STICKY — did NOT downgrade
            isAvailable: false)          // but went offline
        discovery.fire(.updated(offline))

        // Engine session torn down + descriptor deregistered (no leaked RTSP/PTP).
        await pollUntil { engine.removedIDs.contains(ap2.outputID) }
        XCTAssertTrue(engine.removedIDs.contains(ap2.outputID),
                      "an AP2 device going offline must removeOutput the live engine session")
        await pollUntil { engine.discoveryRemovedNames.contains(ap2.descriptor.name) }
        XCTAssertTrue(engine.discoveryRemovedNames.contains(ap2.descriptor.name),
                      "an AP2 device going offline must deregister the engine descriptor")

        // Model: STILL AP2, now unavailable, deselected, resting .failed dot.
        await pollUntil {
            let d = backend.devices.first { $0.id == ap2.id }
            return d?.supportsAirPlay2 == true && d?.isAvailable == false && d?.isSelected == false
        }
        let d = backend.devices.first { $0.id == ap2.id }
        XCTAssertEqual(d?.supportsAirPlay2, true,
                       "an offline AP2 device MUST stay supportsAirPlay2==true — NOT reclassified AP1-only (the bug)")
        XCTAssertEqual(d?.isAvailable, false, "an offline AP2 device is unavailable")
        XCTAssertEqual(d?.isSelected, false)
        XCTAssertEqual(d?.connectionState, .failed(ConnectionFailure(cause: .unknown)),
                       "an offline AP2 device shows a retry-on-click .failed dot, not the AP1 .off state")
    }

    /// An offline AP2 device coming back (airplay advert re-resolves → `.updated`
    /// with `isAvailable == true`) recovers to available AP2 and is re-feedable.
    func testAP2OfflineThenBackRecoversAvailable() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap2 = ap2Device(id: "AA:BB:CC:DD:EE:09", name: "Sonos")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap2.id } else { return false } }
        } after: { discovery.fire(.appeared(ap2)) }

        // Offline.
        discovery.fire(.updated(DiscoveredDevice(
            id: ap2.id, descriptor: ap2.descriptor, outputID: ap2.outputID,
            isAirPlay2Supported: true, isAvailable: false)))
        await pollUntil { backend.devices.first { $0.id == ap2.id }?.isAvailable == false }

        // Back online (available AP2 again).
        discovery.fire(.updated(ap2))   // ap2Device() is available by default
        await pollUntil { backend.devices.first { $0.id == ap2.id }?.isAvailable == true }
        let d = backend.devices.first { $0.id == ap2.id }
        XCTAssertEqual(d?.isAvailable, true, "a returning AP2 device is available again")
        XCTAssertEqual(d?.supportsAirPlay2, true)
    }

    /// Finding 7: selecting an AP2 device immediately after it appears must not
    /// spuriously fail. The fire-and-forget `updateDiscovery` feed may not have
    /// resolved yet, so converge re-feeds the descriptor and awaits it before
    /// addOutput — the device ends up selected/available, never failed.
    func testSelectImmediatelyAfterAppearDoesNotSpuriouslyFail() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:08", name: "Quick")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Select right away — converge must feed the engine before addOutput.
        backend.setOutputSet([device.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && d?.isAvailable == true
        }
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isSelected, true, "a quickly-selected fresh AP2 device must not be surfaced failed (finding 7)")
        XCTAssertEqual(d?.isAvailable, true)
        XCTAssertTrue(engine.addedIDs.contains(device.outputID))
        // The descriptor was fed to the engine (converge re-feeds before addOutput).
        XCTAssertTrue(engine.fedIDs.contains(device.outputID))
    }

    // MARK: Toggle-spam converge race (2026-07-17 gated session)

    /// Rapid enable/disable spam on one device — N fast toggle flips racing slow op
    /// completions — must (a) never run overlapping add/removeOutput for the same
    /// device (at most one op in flight), (b) coalesce to the LATEST desired state
    /// (intermediate flips dropped), and (c) leave the engine holding the device
    /// IFF the final toggle was ON (no zombie session, no wedge).
    func testToggleSpamCoalescesToLatestNoOverlap() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 20_000_000 // 20ms/op: ops complete slower than the flips
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:11", name: "Spam Target")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Spam 12 alternating flips with no waits between: on,off,on,off,…,on.
        // Final desired = ON (even count of "off"s ⇒ last op is on).
        let flips = 12
        for i in 0..<flips {
            let on = (i % 2 == 0)
            backend.setOutputSet(on ? [device.id] : [])
        }
        // Final flip explicitly ON so the settled state is deterministic.
        backend.setOutputSet([device.id])

        // Let all ops drain.
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && engine.addedIDs.contains(device.outputID)
        }

        // (a) never overlapped ops for the one device.
        XCTAssertLessThanOrEqual(engine.maxConcurrent, 1,
                                 "at most one add/removeOutput may be in flight per device (root cause 1)")

        // (b) coalesced: far fewer engine ops than the ~13 flips issued (intermediate
        // flips dropped, not one op per flip).
        let totalOps = engine.addedIDs.count + engine.removedIDs.count
        XCTAssertLessThan(totalOps, flips,
                          "rapid flips must coalesce, not issue one engine op per flip (got \(totalOps))")

        // (c) final engine state == final toggle state (ON): the engine holds it.
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isSelected, true, "final desired ON ⇒ device selected, no wedge")
        XCTAssertEqual(d?.isAvailable, true)
        XCTAssertTrue(engine.addedIDs.contains(device.outputID),
                      "engine holds the device iff final state is on (no zombie)")
    }

    /// The mirror case: spam ending OFF must leave the engine NOT holding the device
    /// (a removeOutput reached it) — no zombie session that keeps streaming while the
    /// UI shows it off.
    func testToggleSpamEndingOffTearsDownSession() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 15_000_000
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:12", name: "End Off")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        for i in 0..<10 { backend.setOutputSet((i % 2 == 0) ? [device.id] : []) }
        backend.setOutputSet([]) // final: OFF

        // Settled: deselected AND every add was matched by a remove (net not added).
        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.isSelected == false
                && Self.netAdded(engine, device.outputID) == false
        }

        XCTAssertLessThanOrEqual(engine.maxConcurrent, 1)
        XCTAssertFalse(Self.netAdded(engine, device.outputID),
                       "spam ending OFF must not leave a live engine session (no zombie)")
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.isSelected, false)
    }

    /// True iff the engine is NET holding `id` (more adds than removes observed).
    /// The converge loop issues one add per on-transition and one remove per
    /// off-transition, so an equal count means the last op was a remove.
    private static func netAdded(_ engine: SpyEngine, _ id: OutputID) -> Bool {
        let adds = engine.addedIDs.filter { $0 == id }.count
        let removes = engine.removedIDs.filter { $0 == id }.count
        return adds > removes
    }

    /// Root cause 2: repeatedly toggling a device with an UNCHANGED descriptor must
    /// not re-feed the engine's discovery per toggle — the duplicate "Adding AirPlay
    /// device" storm. After a fresh appear + several on/off cycles, updateDiscovery
    /// for that id was called at most once (the initial discovery feed).
    func testNoDiscoveryRefeedForUnchangedDescriptor() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 5_000_000
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:13", name: "No Refeed")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Wait for the initial discovery-driven feed to land.
        await pollUntil { engine.feedCount(for: device.outputID) >= 1 }

        // Several on/off cycles with the SAME descriptor (no discovery updates).
        for i in 0..<8 { backend.setOutputSet((i % 2 == 0) ? [device.id] : []) }
        backend.setOutputSet([device.id])

        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.isSelected == true
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertLessThanOrEqual(engine.feedCount(for: device.outputID), 1,
                                 "an unchanged descriptor must NOT be re-fed per toggle (root cause 2), got \(engine.feedCount(for: device.outputID))")
    }

    /// Root cause 4 + 5: a device whose add fails (engine NACKs SETPEERS under a
    /// session storm) is marked unavailable and PARKED (converge stops issuing
    /// sessions), but must be RECOVERABLE — a subsequent discovery re-resolution
    /// clears the park and a user re-toggle re-enables it, with the retry succeeding.
    func testSetPeersFailureRecoversNotWedged() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:14", name: "NACKer")
        engine.addFailures = [device.outputID.rawValue]  // first add throws (SETPEERS negative)
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Select it: the add fails, device goes unavailable + deselected (wedged look).
        backend.setOutputSet([device.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isAvailable == false && d?.isSelected == false
        }
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.isAvailable, false)

        // RECOVERY: the receiver settles; discovery re-resolves it (clears the park),
        // and the engine now accepts the add.
        engine.addFailures = []
        discovery.fire(.updated(device))
        await pollUntil {
            backend.devices.first { $0.id == device.id }?.isAvailable == true
        }

        // A user re-toggle now succeeds — the device is not permanently wedged.
        backend.setOutputSet([device.id])
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && d?.isAvailable == true
        }
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isSelected, true, "a NACKed device must be re-enableable after recovery (root cause 4)")
        XCTAssertEqual(d?.isAvailable, true)
        XCTAssertTrue(engine.addedIDs.contains(device.outputID))
    }

    // MARK: State-stream vs converge ordering (2026-07-17 findings)

    /// High finding: a stale `.streaming`/`.connected` state event that arrives AFTER
    /// a successful OFF converge must NOT re-wedge the device ON. The real engine
    /// yields the good transition on the state stream behind the op completion (STATE
    /// STREAM contract), so an OFF that lands before the queued `.streaming` is
    /// processed could otherwise leave the device selected+available+metering with
    /// desiredOn=false and no converge scheduled — a session shown on while the user
    /// turned it off. The state-stream event must reconcile against `desiredOn`.
    func testStaleStreamingAfterOffDoesNotReWedge() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:21", name: "Stale Streamer")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Turn it ON: converge issues addOutput; it succeeds and the device selects.
        backend.setOutputSet([device.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && engine.addedIDs.contains(device.outputID)
        }

        // Turn it OFF: converge issues removeOutput; it succeeds and the device
        // deselects. desiredOn[id] is now false and no loop is scheduled.
        backend.setOutputSet([])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == false && engine.removedIDs.contains(device.outputID)
        }

        // The real engine now yields the queued `.streaming` from the ON op (which
        // resolved behind the op completion). It is STALE — the user turned the
        // device off. It must NOT re-select / re-mark-available the device.
        engine.pushState(device.outputID, .streaming)
        // Give the state-stream consumer time to (mis)handle it.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isSelected, false,
                       "a stale .streaming after a successful OFF must not re-select the device")
        // And no phantom re-add of the engine session: removes >= adds (net off).
        XCTAssertFalse(Self.netAdded(engine, device.outputID),
                       "a stale .streaming must not leave a live engine session the user turned off")
    }

    /// High finding, in-flight variant: a stale `.streaming` arrives while the device
    /// is STILL in `added` (the OFF converge hasn't torn it down yet, e.g. the good
    /// transition raced ahead) and desiredOn is false. The state-stream handler must
    /// re-kick converge so the stale session is torn down, not leave it selected.
    func testStaleStreamingWhileAddedReKicksTeardown() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 30_000_000 // slow ops so we can wedge a stale event mid-flight
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:22", name: "InFlight Stale")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // ON, let it fully settle (added contains id, selected).
        backend.setOutputSet([device.id])
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && engine.addedIDs.contains(device.outputID)
        }

        // Turn OFF but push the stale .streaming immediately, BEFORE the (slow)
        // removeOutput completes. At this instant desiredOn=false and the device is
        // still in `added`. The handler must re-kick converge to tear it down rather
        // than re-selecting it.
        backend.setOutputSet([])
        engine.pushState(device.outputID, .streaming)

        // Eventually the device is off and the engine holds no session.
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == false && !Self.netAdded(engine, device.outputID)
        }
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.isSelected, false,
                       "a stale .streaming with desiredOn=false must converge OFF, not re-wedge ON")
        XCTAssertFalse(Self.netAdded(engine, device.outputID))
        XCTAssertLessThanOrEqual(engine.maxConcurrent, 1,
                                 "the re-kick must not overlap ops for the same device")
    }

    /// Medium finding: an out-of-band `.failed` that lands between addOutput returning
    /// and its post-success write must not be clobbered. The post-write must respect
    /// the interim failure park instead of force-selecting a dead session — otherwise
    /// the device shows selected+available while the engine session actually failed,
    /// with no scheduled recovery.
    func testOutOfBandFailedNotClobberedByAddSuccessWrite() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:23", name: "Racey Fail")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Deterministically reproduce the interleave: inject the out-of-band `.failed`
        // from INSIDE addOutput's body (after the add is recorded, before it returns),
        // then block briefly so the state-stream consumer runs `applyEngineState` and
        // sets the failure park BEFORE addOutput returns and NativeBackend's
        // post-success write executes. The post-write must respect that park.
        engine.onAddOutputBody = { [weak engine] id in
            engine?.pushState(id, .failed)
            Thread.sleep(forTimeInterval: 0.1) // let applyEngineState park the id
        }

        backend.setOutputSet([device.id])

        // Let everything settle: the post-write should have deferred to the park.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isAvailable, false,
                       "an interim .failed must not be clobbered by the add-success write")
        XCTAssertEqual(d?.isSelected, false,
                       "a failed session must not be shown selected")
    }

    // MARK: connectionState wiring (mirrors OwnToneBackend's T2 state machine semantics)

    /// add → connecting → connected: `setOutputSet` flips the id ON, which must go
    /// `.connecting` immediately (before the engine op resolves), then `.connected`
    /// once `addOutput` succeeds and the post-success write lands.
    func testConnectionStateAddGoesConnectingThenConnected() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 30_000_000 // slow enough to observe the connecting frame
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:30", name: "State Machine")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.connectionState, .off)

        let events = await collect(from: backend) { events in
            events.contains {
                if case .deviceUpdated(let d) = $0 { return d.id == device.id && d.connectionState == .connecting }
                else { return false }
            }
        } after: { backend.setOutputSet([device.id]) }
        XCTAssertTrue(events.contains {
            if case .deviceUpdated(let d) = $0 { return d.id == device.id && d.connectionState == .connecting }
            else { return false }
        }, "a newly-desired-on device must go .connecting immediately, before the op resolves")

        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.connectionState == .connected
        }
        let final = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(final?.connectionState, .connected, "a successful addOutput must land .connected")
        XCTAssertEqual(final?.isSelected, true)
    }

    /// NACK → failed: an `addOutput` throw (engine NACK) must land `.failed`, not
    /// just `isAvailable = false` — the status dot must light up amber.
    func testConnectionStateAddFailureGoesFailed() async {
        let (backend, engine, discovery) = makeBackend()
        let device = ap2Device(id: "AA:BB:CC:DD:EE:31", name: "NACKer")
        engine.addFailures = [device.outputID.rawValue]
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            if case .failed = d?.connectionState { return true }
            return false
        }
        let d = backend.devices.first { $0.id == device.id }
        guard case .failed(let failure) = d?.connectionState else {
            XCTFail("expected .failed after a NACKed addOutput, got \(String(describing: d?.connectionState))")
            return
        }
        XCTAssertEqual(failure.cause, .unknown, "NativeBackend has no diagnostics seam — always .unknown")
        XCTAssertEqual(d?.isAvailable, false)
        XCTAssertEqual(d?.isSelected, false)
    }

    /// Recovery clears to connecting/connected: after a NACK parks the device
    /// `.failed`, a discovery re-resolution clears the park (root cause 4) and a
    /// user re-toggle retries — the connection dot must follow through
    /// `.failed → .connecting → .connected`, not stay stuck amber.
    func testConnectionStateRecoveryClearsFailedThenReconnects() async {
        let (backend, engine, discovery) = makeBackend()
        let device = ap2Device(id: "AA:BB:CC:DD:EE:32", name: "Recoverer")
        engine.addFailures = [device.outputID.rawValue]
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil {
            if case .failed = backend.devices.first(where: { $0.id == device.id })?.connectionState { return true }
            return false
        }

        // The receiver settles; discovery re-resolves it. This clears the park but
        // is not itself a retry, so the dot should NOT jump to .connecting on its
        // own here — it stays .failed (sticky) until the user re-toggles.
        engine.addFailures = []
        discovery.fire(.updated(device))
        await pollUntil { backend.devices.first { $0.id == device.id }?.isAvailable == true }

        // User re-toggle: the dot must move .failed → .connecting → .connected.
        backend.setOutputSet([device.id])
        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.connectionState == .connected
        }
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.connectionState, .connected, "a retry after recovery must reach .connected")
        XCTAssertEqual(d?.isSelected, true)
    }

    /// toggle-off → off: deselecting a connected device must clear the dot back to
    /// `.off` (NativeBackend has no sticky-failed-survives-deselect behavior — its
    /// failure park is unconditionally cleared on any toggle, so the connection dot
    /// mirrors that and does not stay amber after the user turns the device off).
    func testConnectionStateToggleOffGoesOff() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:33", name: "Toggle Off")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.connectionState == .connected
        }

        backend.setOutputSet([])
        // The dot goes .off eagerly (synchronously, ahead of the removeOutput op
        // resolving) — wait for isSelected to catch up too so the assertion below
        // isn't racing the in-flight removal.
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.connectionState == .off && d?.isSelected == false
        }
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.connectionState, .off)
        XCTAssertEqual(d?.isSelected, false)
    }

    /// AP1-only devices are never routed (D6: never fed to the engine, never
    /// addOutput-ed even if included in `setOutputSet`) and must stay `.off`
    /// permanently — no connecting/failed dot for a device that can't be enabled.
    func testConnectionStateAP1StaysOffPermanently() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap1 = ap1Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap1.id } else { return false } }
        } after: { discovery.fire(.appeared(ap1)) }
        XCTAssertEqual(backend.devices.first { $0.id == ap1.id }?.connectionState, .off)

        // Attempting to select it must not move the dot — it's never addOutput-ed.
        backend.setOutputSet([ap1.id])
        try? await Task.sleep(nanoseconds: 150_000_000)
        let d = backend.devices.first { $0.id == ap1.id }
        XCTAssertEqual(d?.connectionState, .off, "an AP1-only device must never show connecting/failed")
        XCTAssertTrue(engine.addedIDs.isEmpty)
    }

    // MARK: Capture gate
    //
    // The tap is `.mutedWhenTapped` — while it runs, the Mac's own speakers are
    // SILENT. `start()` used to run it unconditionally, so the default
    // out-of-the-box state (passthrough: no AirPlay outputs selected) muted system
    // audio and sent the capture nowhere: total silence. Capture must run IF AND
    // ONLY IF at least one real AP2 output is selected.

    /// THE BUG: passthrough (the default launch state — `start()` with no
    /// selection, and the empty `setOutputSet` GroupController.applyRouting sends
    /// when Selected Devices == {local Mac}) must NEVER run the tap.
    func testPassthroughNeverStartsCapture() async {
        let (backend, engine, _) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        // start() alone: nothing selected yet.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(capture.ops, [], "start() must not run the tap — nothing is selected, so it would mute the Mac and send audio nowhere")

        // ...and the empty set GroupController sends for {local Mac} passthrough.
        backend.setOutputSet([])
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(capture.ops, [], "passthrough (empty output set) must not run the tap")
        XCTAssertFalse(capture.isCapturing)
    }

    /// Selecting a real AP2 output starts capture; deselecting stops it.
    func testCaptureStartsOnAP2SelectionAndStopsOnDeselect() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:40", name: "Gate Speaker")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }
        XCTAssertFalse(capture.isCapturing, "discovery alone must not start capture")

        backend.setOutputSet([device.id])
        await pollUntil { capture.isCapturing }
        XCTAssertTrue(capture.isCapturing, "a selected AP2 output must start capture")

        backend.setOutputSet([])
        await pollUntil { !capture.isCapturing }
        XCTAssertFalse(capture.isCapturing, "deselecting the last AP2 output must stop capture (unmuting the Mac)")
        XCTAssertEqual(capture.ops, ["start", "stop"], "no redundant ops — the gate dedups against its own last decision")
    }

    /// The gate keys on ids that could actually be streamed to. Neither the local
    /// Mac device (`supportsAirPlay2 == false`) nor an AP1-only receiver (D6, never
    /// addOutput-ed) may start the tap — selecting either would mute the Mac with
    /// the audio going nowhere, which is the original bug wearing a different hat.
    func testNonStreamableSelectionNeverStartsCapture() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap1 = ap1Device(id: "AA:BB:CC:DD:EE:41")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap1.id } else { return false } }
        } after: { discovery.fire(.appeared(ap1)) }

        // The local device + an AP1-only receiver + an id we've never discovered.
        backend.setOutputSet([NativeBackend.localDeviceID, ap1.id, "AA:BB:CC:DD:EE:FF"])
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(capture.ops, [], "only a real, discovered AP2 output may start capture")
    }

    /// Toggle spam: the gate's start/stop calls must replay in the order
    /// `stateQueue` decided them (no stale start landing after a stop and re-muting
    /// the Mac), and settle on the LAST intent.
    func testCaptureGateToggleSpamSettlesOnLastIntent() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        engine.opDelayNanos = 5_000_000 // slow ops race the fast flips
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:42", name: "Spam Target")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        for _ in 0..<10 {
            backend.setOutputSet([device.id])
            backend.setOutputSet([])
        }
        backend.setOutputSet([device.id])   // last intent: ON

        await pollUntil { capture.isCapturing }
        XCTAssertTrue(capture.isCapturing, "capture must settle ON — the last intent selected an AP2 output")
        // Strictly alternating: the gate never issues start-after-start or
        // stop-after-stop, so the sequence is exactly the decision sequence.
        XCTAssertEqual(capture.ops.first, "start")
        for (i, op) in capture.ops.enumerated() {
            XCTAssertEqual(op, i.isMultiple(of: 2) ? "start" : "stop", "capture ops must alternate, in decision order")
        }
    }

    /// `stop()` must leave the tap stopped — the Mac must never stay muted after
    /// the backend is torn down, even if a start was still queued behind it.
    func testStopStopsCapture() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        backend.start()
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:43", name: "Teardown")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        backend.stop()
        await pollUntil { !capture.isCapturing }
        XCTAssertFalse(capture.isCapturing, "stop() must leave the tap stopped, whichever way it raced the queued start")
        XCTAssertEqual(capture.ops.last, "stop")
    }

    /// `applyStartBuffer` flaps `desiredOn` internally (remove-all → set → re-add)
    /// but never touches `expectedSelected` — so it must NOT stop/restart capture.
    /// A tap bounce here would drop audio and briefly unmute the Mac mid-apply.
    func testApplyStartBufferDoesNotBounceCapture() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:44", name: "Buffer Apply")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { capture.isCapturing }

        await backend.applyStartBuffer(ms: 1500)
        XCTAssertEqual(capture.ops, ["start"], "applyStartBuffer must not bounce the tap — it re-adds outputs, it doesn't change the selection")
        XCTAssertTrue(capture.isCapturing)
    }

    // MARK: Helpers

    /// Records the gate's capture ops in order, with no Core Audio tap / TCC prompt.
    private final class FakeCapture: CaptureControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _onLevel: (@Sendable (Float) -> Void)?
        private var _ops: [String] = []

        var onLevel: (@Sendable (_ rms: Float) -> Void)? {
            get { lock.withLock { _onLevel } }
            set { lock.withLock { _onLevel = newValue } }
        }
        func start() { lock.withLock { _ops.append("start") } }
        func stop() { lock.withLock { _ops.append("stop") } }

        /// Every start/stop, in the order they executed.
        var ops: [String] { lock.withLock { _ops } }
        /// Whether the tap is running right now — i.e. exactly when the real
        /// `.mutedWhenTapped` tap has the Mac's speakers muted.
        var isCapturing: Bool { lock.withLock { _ops.last == "start" } }
    }

    // MARK: Per-app routing (T6)

    /// Discover an AP2 device and wait until the backend knows it (so `outputIDs`
    /// is populated and a route can bind to it).
    private func startAndDiscover(
        _ backend: NativeBackend, _ engine: SpyEngine, _ discovery: FakeDiscovery,
        _ device: DiscoveredDevice
    ) async {
        backend.start()
        await waitUntilStarted(engine)
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }
        await pollUntil { engine.fedIDs.contains(device.outputID) }
    }

    /// A `.device(id:)` route spins up that app's per-app capture (the resolver is
    /// asked for its pid) and binds the destination device to a NON-ZERO stream id
    /// via the engine's per-app `addOutput(_:streamId:)`.
    func testAppRouteBindsDeviceToNonZeroStream() async {
        let pids = PIDRecorder()
        let (backend, engine, discovery) = makeBackend(resolvePID: { pids.resolve($0) })
        defer { backend.stop() }
        let device = ap2Device()
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo.player", name: "Foo", toDevice: device.id)])

        // The per-app capture spun up for the routed bundle ID.
        await pollUntil { pids.asked.contains("com.foo.player") }
        XCTAssertTrue(pids.asked.contains("com.foo.player"),
                      "the routed app's per-app capture must be started (pid resolved)")

        // The destination device was bound to a non-zero per-app stream.
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID && $0.1 >= 1 } }
        let binds = engine.streamAddCalls.filter { $0.0 == device.outputID }
        XCTAssertEqual(binds.count, 1, "device should be bound exactly once")
        XCTAssertGreaterThanOrEqual(binds.first?.1 ?? 0, 1,
                                    "per-app stream id must be >= 1 (0 is the legacy whole-system path)")
    }

    /// A route reverting to `.currentDevice` tears the capture bookkeeping down and
    /// releases the device's stream binding (a `removeOutput`), and no per-app stream
    /// remains bound.
    func testRouteRevertReleasesStreamBinding() async {
        let (backend, engine, discovery) = makeBackend()
        defer { backend.stop() }
        let device = ap2Device()
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo.player", name: "Foo", toDevice: device.id)])
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }

        // Revert the app to local playback (no device route).
        backend.updateAppRoutes([
            AppRoute(bundleID: "com.foo.player", displayName: "Foo", destination: .currentDevice)
        ])

        // The device's per-app session was torn down (stop → nothing re-added).
        await pollUntil { engine.removedIDs.contains(device.outputID) }
        XCTAssertTrue(engine.removedIDs.contains(device.outputID),
                      "reverting to .currentDevice must release the device's stream binding")
        // Exactly one bind ever happened; it wasn't re-added after the release.
        XCTAssertEqual(engine.streamAddCalls.filter { $0.0 == device.outputID }.count, 1,
                       "no new stream bind after the revert")
    }

    /// A route reverting to `.noRedirect` (the new default/unset state) tears
    /// the capture bookkeeping down identically to reverting to `.currentDevice`
    /// — same `removeOutput`, no new stream bind.
    func testRouteRevertToNoRedirectReleasesStreamBindingJustLikeCurrentDevice() async {
        let (backend, engine, discovery) = makeBackend()
        defer { backend.stop() }
        let device = ap2Device()
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo.player", name: "Foo", toDevice: device.id)])
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }

        // Revert the app to local playback via the NEW default state.
        backend.updateAppRoutes([
            AppRoute(bundleID: "com.foo.player", displayName: "Foo", destination: .noRedirect)
        ])

        await pollUntil { engine.removedIDs.contains(device.outputID) }
        XCTAssertTrue(engine.removedIDs.contains(device.outputID),
                      "reverting to .noRedirect must release the device's stream binding")
        XCTAssertEqual(engine.streamAddCalls.filter { $0.0 == device.outputID }.count, 1,
                       "no new stream bind after the revert")
    }

    /// Two different apps routed to two different devices get two DISTINCT non-zero
    /// stream ids, each bound to its own device.
    func testTwoAppsTwoDevicesDistinctStreams() async {
        let (backend, engine, discovery) = makeBackend()
        defer { backend.stop() }
        let devA = ap2Device(id: "AA:BB:CC:DD:EE:01", name: "Speaker A")
        let devB = ap2Device(id: "AA:BB:CC:DD:EE:02", name: "Speaker B")
        await startAndDiscover(backend, engine, discovery, devA)
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == devB.id } else { return false } }
        } after: { discovery.fire(.appeared(devB)) }
        await pollUntil { engine.fedIDs.contains(devB.outputID) }

        backend.updateAppRoutes([
            route("com.foo", name: "Foo", toDevice: devA.id),
            route("com.bar", name: "Bar", toDevice: devB.id),
        ])

        await pollUntil {
            engine.streamAddCalls.contains { $0.0 == devA.outputID }
                && engine.streamAddCalls.contains { $0.0 == devB.outputID }
        }
        let sA = engine.streamAddCalls.first { $0.0 == devA.outputID }?.1
        let sB = engine.streamAddCalls.first { $0.0 == devB.outputID }?.1
        XCTAssertNotNil(sA); XCTAssertNotNil(sB)
        XCTAssertGreaterThanOrEqual(sA ?? 0, 1)
        XCTAssertGreaterThanOrEqual(sB ?? 0, 1)
        XCTAssertNotEqual(sA, sB, "distinct app-sets on distinct devices must get distinct stream ids")
    }

    /// `.routedApps` fires with the destination device + the routed app's display
    /// name on a route change, and fires AGAIN with the updated app list when a
    /// second app is added to the same device.
    ///
    /// Uses `workingPerAppCapture()` (T8), not the default `resolvePID`-returns-nil
    /// setup: `.routedApps` now reflects apps that are ACTUALLY capturing, not just
    /// routed intent (T8 excludes a `.failed` bundle ID — e.g. `.appNotRunning`,
    /// which the default setup always hits immediately — from the mixer topology so
    /// a silent app is never claimed as streaming). This test verifies the
    /// event-firing/topology logic under the condition it's meant to hold for: the
    /// capture actually succeeds.
    func testRoutedAppsEventFiresAndUpdates() async {
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: workingPerAppCapture())
        defer { backend.stop() }
        let device = ap2Device()
        await startAndDiscover(backend, engine, discovery, device)

        // First route: one app → the device.
        let first = await collect(from: backend) { events in
            events.contains {
                if case .routedApps(let id, let names) = $0 { return id == device.id && names == ["Foo"] }
                return false
            }
        } after: { backend.updateAppRoutes([self.route("com.foo", name: "Foo", toDevice: device.id)]) }
        XCTAssertTrue(first.contains {
            if case .routedApps(let id, let names) = $0 { return id == device.id && names == ["Foo"] }
            return false
        }, "routedApps must carry the device id and the routed app's display name")

        // Add a second app to the SAME device → the map updates (sorted names).
        let second = await collect(from: backend) { events in
            events.contains {
                if case .routedApps(let id, let names) = $0 { return id == device.id && names == ["Bar", "Foo"] }
                return false
            }
        } after: {
            backend.updateAppRoutes([
                self.route("com.foo", name: "Foo", toDevice: device.id),
                self.route("com.bar", name: "Bar", toDevice: device.id),
            ])
        }
        XCTAssertTrue(second.contains {
            if case .routedApps(let id, let names) = $0 { return id == device.id && names == ["Bar", "Foo"] }
            return false
        }, "routedApps must re-fire with the updated, sorted app list when the mapping changes")
    }

    /// Per-app routing is ADDITIVE: an app route neither issues a legacy
    /// (stream_id 0) `addOutput` nor touches the whole-system Selected Devices set —
    /// only the per-app `addOutput(_:streamId:)` path runs.
    func testAppRouteDoesNotTouchLegacyOutputSet() async {
        let (backend, engine, discovery) = makeBackend()
        defer { backend.stop() }
        let device = ap2Device()
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }

        // The legacy stream_id-0 path was never invoked for this device.
        XCTAssertFalse(engine.addedIDs.contains(device.outputID),
                       "an app route must NOT go through the legacy addOutput(_:) path (that's T7's union, out of scope for T6)")
        // And the device is not reported selected (redirect targets stay out of the
        // Selected Devices set — AGENTS.md invariant).
        XCTAssertFalse(backend.devices.first { $0.id == device.id }?.isSelected ?? true,
                       "a redirect target must not be marked isSelected by the per-app path")
    }

    // MARK: T10 cross-component gap coverage
    //
    // The T6/T7 tests above prove routing TOPOLOGY (which streamId a device is
    // bound to) at the NativeBackend level, and AppRouteMixerTests/
    // MultiStreamWriteRoutingTests separately prove sample-accurate mixing and
    // C-level write isolation in ISOLATION. Nothing previously pushed real
    // captured buffers through the FULL NativeBackend chain (PerAppCaptureCoordinator
    // -> AppRouteMixer -> engine.write) or exercised the real NativeCaptureCoordinator
    // through NativeBackend.updateAppRoutes (as opposed to calling
    // NativeCaptureCoordinator.updateRouting directly, which NativeCaptureCoordinatorTests
    // already does at that single-component level).

    /// Headline invariant 1, at the FULL NativeBackend level: two apps routed to
    /// two different devices get two independent streams, and pushing distinctly
    /// FINGERPRINTED content into each app's own tap proves the content that
    /// reaches `engine.write` for one stream never contains so much as a byte of
    /// the other stream's content. Exercises the real wiring
    /// (`perAppCapture.onBuffer` -> `routeMixer.handleBuffer` -> `onMixedBuffer`
    /// -> `engine.write(pcm:streamId:pts:)`), including the real production
    /// `AppRouteMixer` (real `AVFormatConverter`, not the mixer unit tests'
    /// injected identity converter).
    func testCrossStreamNoLeakageThroughFullBackendPipeline() async {
        let registry = TapRegistry()
        let perAppCapture = PerAppCaptureCoordinator(
            makeTap: {
                let tap = BundleTaggingTap()
                tap.onRegister = { bundleID in registry.register(bundleID, tap) }
                return tap
            },
            resolvePID: { _ in 4242 },
            muteBehavior: .mutedWhenTapped)
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: perAppCapture)
        defer { backend.stop() }

        let devA = ap2Device(id: "AA:BB:CC:DD:EE:60", name: "Speaker A")
        let devB = ap2Device(id: "AA:BB:CC:DD:EE:61", name: "Speaker B")
        await startAndDiscover(backend, engine, discovery, devA)
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == devB.id } else { return false } }
        } after: { discovery.fire(.appeared(devB)) }
        await pollUntil { engine.fedIDs.contains(devB.outputID) }

        backend.updateAppRoutes([
            route("com.a", name: "A", toDevice: devA.id),
            route("com.b", name: "B", toDevice: devB.id),
        ])

        await pollUntil {
            engine.streamAddCalls.contains { $0.0 == devA.outputID }
                && engine.streamAddCalls.contains { $0.0 == devB.outputID }
        }
        let streamA = engine.streamAddCalls.first { $0.0 == devA.outputID }!.1
        let streamB = engine.streamAddCalls.first { $0.0 == devB.outputID }!.1
        XCTAssertNotEqual(streamA, streamB)

        // Wait for BOTH per-app taps to actually be capturing before pushing —
        // the mixer only learns a converter (and can accept buffers) on the
        // `.capturing` transition.
        await pollUntil {
            if case .capturing = perAppCapture.state(for: "com.a"),
               case .capturing = perAppCapture.state(for: "com.b") { return true }
            return false
        }
        guard let tapA = registry.tap(for: "com.a"), let tapB = registry.tap(for: "com.b") else {
            return XCTFail("both per-app taps must have registered themselves by the time capture started")
        }

        // Distinct fingerprinted content, well over the mixer's 441-frame hold
        // window so most of each buffer auto-drains without an explicit flush.
        tapA.push(fingerprintedBuffer(fill: 0xAA, frames: 1000, atSecond: 1))
        tapB.push(fingerprintedBuffer(fill: 0xBB, frames: 1000, atSecond: 1))

        await pollUntil {
            engine.rawWriteCalls.contains { $0.streamId == streamA }
                && engine.rawWriteCalls.contains { $0.streamId == streamB }
        }

        let writesToA = engine.rawWriteCalls.filter { $0.streamId == streamA }
        let writesToB = engine.rawWriteCalls.filter { $0.streamId == streamB }
        XCTAssertFalse(writesToA.isEmpty, "app A's stream must have received mixed audio")
        XCTAssertFalse(writesToB.isEmpty, "app B's stream must have received mixed audio")
        XCTAssertTrue(writesToA.allSatisfy { !$0.pcm.contains(0xBB) },
                      "app B's content (0xBB) must NEVER appear in app A's stream write")
        XCTAssertTrue(writesToB.allSatisfy { !$0.pcm.contains(0xAA) },
                      "app A's content (0xAA) must NEVER appear in app B's stream write")
    }

    /// Headline invariant 2, through the FULL `updateAppRoutes` call (not a
    /// direct `NativeCaptureCoordinator.updateRouting` call, which
    /// `NativeCaptureCoordinatorTests.testDeviceRoutedAppPIDNeverLeaksIntoSystemMix`
    /// already covers at that single-component level). Also the composite
    /// scenario the plan calls out: a "Selected Devices" whole-system capture is
    /// ALREADY ACTIVE when an app gets individually routed to its own device —
    /// both streams must coexist, and the routed app's pid must drop out of the
    /// whole-system tap's exclusion-blind spot without disturbing the
    /// whole-system stream's own device.
    func testUpdateAppRoutesExcludesRoutedAppFromSystemMixWhileSelectedDevicesActive() async {
        let pids: [String: pid_t] = ["com.routed": 111, "com.other": 222]
        let resolvePID: @Sendable (String) -> pid_t? = { pids[$0] }
        let (backend, engine, discovery) = makeBackend(resolvePID: resolvePID)
        let tap = RecordingSystemTap()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { tap }, sink: NoOpSink(), makeConverter: { _ in PassthroughConverter() },
            resolvePID: resolvePID, muteBehavior: .mutedWhenTapped)
        backend.captureCoordinator = coordinator
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let systemDevice = ap2Device(id: "AA:BB:CC:DD:EE:62", name: "Whole System Speaker")
        await startAndDiscover(backend, engine, discovery, systemDevice)

        // Selected Devices active BEFORE any per-app route: the whole-system tap
        // starts capturing with nobody excluded.
        backend.setOutputSet([systemDevice.id])
        await pollUntil { tap.createCount >= 1 }
        XCTAssertEqual(tap.excludedPIDs, [], "nothing routed yet -> the system mix must include every app")

        // NOW route one app to its OWN device while Selected Devices stays active.
        let routedDevice = ap2Device(id: "AA:BB:CC:DD:EE:63", name: "Per-App Target")
        await startAndDiscover(backend, engine, discovery, routedDevice)
        backend.updateAppRoutes([route("com.routed", name: "Routed App", toDevice: routedDevice.id)])

        await pollUntil { tap.excludedPIDs.contains(111) }
        XCTAssertEqual(tap.excludedPIDs, [111],
                       "the individually-routed app's pid must be excluded from the whole-system tap — " +
                       "through the FULL updateAppRoutes call, not a direct coordinator call — " +
                       "while an unrouted app's pid stays included")

        // Both streams coexist: the per-app path bound its own dedicated stream…
        await pollUntil { engine.streamAddCalls.contains { $0.0 == routedDevice.outputID } }
        XCTAssertTrue(engine.streamAddCalls.contains { $0.0 == routedDevice.outputID })
        // …and the whole-system stream (stream_id 0) is still streaming to ITS
        // device throughout — the routed app's exclusion never touched it.
        XCTAssertTrue(engine.addedIDs.contains(systemDevice.outputID),
                      "the whole-system stream must keep streaming to its own device the whole time")
    }

    /// Plan item: 3+ apps across 2+ devices, with two devices sharing an
    /// IDENTICAL app-set (so they must be bound to the SAME non-zero stream_id —
    /// `AppRouteMixer.DestinationSet.deviceIDs` fanning out to more than one
    /// device), a third device with a distinct app-set (its own stream), and a
    /// `.noRedirect` app in the same table. `AppRouteMixerTests.
    /// testDevicesWithIdenticalMembershipShareOneStream` proves the TOPOLOGY math
    /// for shared membership in isolation; nothing previously proved
    /// `NativeBackend` actually issues `addOutput(_:streamId:)` with the SAME
    /// stream_id to BOTH devices of a shared set (`testTwoAppsTwoDevicesDistinctStreams`
    /// only covers the DISTINCT-streams shape) — this closes that.
    ///
    /// (Two devices sharing an app-set requires the same bundle ID to appear
    /// twice with two different `.device` destinations — `AppRoutingController`
    /// never produces that shape itself, since it holds one route per bundle ID,
    /// but `NativeBackend.updateAppRoutes` doesn't require or enforce that
    /// invariant on its input, so this is still a real robustness property of
    /// the seam, exercised the same way `AppRouteMixerTests` exercises it.)
    func testMultiAppMultiDeviceSharedStreamAndNoRedirectCoexist() async {
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: workingPerAppCapture())
        defer { backend.stop() }

        let devA = ap2Device(id: "AA:BB:CC:DD:EE:70", name: "Kitchen")
        let devB = ap2Device(id: "AA:BB:CC:DD:EE:71", name: "Kitchen Extra")
        let devC = ap2Device(id: "AA:BB:CC:DD:EE:72", name: "Office")
        await startAndDiscover(backend, engine, discovery, devA)
        for dev in [devB, devC] {
            _ = await collect(from: backend) { events in
                events.contains { if case .deviceAdded(let d) = $0 { return d.id == dev.id } else { return false } }
            } after: { discovery.fire(.appeared(dev)) }
        }
        await pollUntil { engine.fedIDs.contains(devB.outputID) && engine.fedIDs.contains(devC.outputID) }

        // Foo + Bar -> BOTH devA and devB (identical app-set => shared stream).
        // Baz -> devC alone (distinct app-set => its own stream).
        // Zoom stays .noRedirect (the tri-state default) — must never bind or appear.
        backend.updateAppRoutes([
            route("com.foo", name: "Foo", toDevice: devA.id),
            route("com.bar", name: "Bar", toDevice: devA.id),
            route("com.foo", name: "Foo", toDevice: devB.id),
            route("com.bar", name: "Bar", toDevice: devB.id),
            route("com.baz", name: "Baz", toDevice: devC.id),
            AppRoute(bundleID: "us.zoom.xos", displayName: "Zoom", destination: .noRedirect),
        ])

        await pollUntil {
            engine.streamAddCalls.contains { $0.0 == devA.outputID }
                && engine.streamAddCalls.contains { $0.0 == devB.outputID }
                && engine.streamAddCalls.contains { $0.0 == devC.outputID }
        }
        let streamA = engine.streamAddCalls.first { $0.0 == devA.outputID }!.1
        let streamB = engine.streamAddCalls.first { $0.0 == devB.outputID }!.1
        let streamC = engine.streamAddCalls.first { $0.0 == devC.outputID }!.1
        XCTAssertEqual(streamA, streamB,
                       "two devices with the identical routed app-set must share ONE stream_id")
        XCTAssertNotEqual(streamA, streamC, "a distinct app-set must get a distinct stream_id")

        // Zoom (.noRedirect) never gets a stream binding of its own — the only
        // stream ids ever bound are the two above.
        let allStreams = Set(engine.streamAddCalls.map(\.1))
        XCTAssertEqual(allStreams, [streamA, streamC])
    }

    /// T8 lifecycle edge case, MULTI-APP scenario (the existing T8 coverage only
    /// exercises this with a single routed app): two apps share a device (one
    /// stream); one app's process quits mid-stream. The device must REBIND
    /// (stop -> re-add) to a fresh stream containing only the surviving app —
    /// not simply unbind — and `.routedApps` must drop the terminated app's name
    /// while keeping the survivor's.
    func testAppTerminatedMidStreamRebindsDeviceToSurvivingSiblingsStream() async {
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: workingPerAppCapture())
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:80", name: "Shared Speaker")
        await startAndDiscover(backend, engine, discovery, device)

        _ = await collect(from: backend) { events in
            events.contains {
                if case .routedApps(let id, let names) = $0 { return id == device.id && names == ["Bar", "Foo"] }
                return false
            }
        } after: {
            backend.updateAppRoutes([
                self.route("com.foo", name: "Foo", toDevice: device.id),
                self.route("com.bar", name: "Bar", toDevice: device.id),
            ])
        }
        let firstStream = engine.streamAddCalls.first { $0.0 == device.outputID }!.1

        // Foo's process quits mid-stream.
        let afterTermination = await collect(from: backend) { events in
            events.contains {
                if case .routedApps(let id, let names) = $0 { return id == device.id && names == ["Bar"] }
                return false
            }
        } after: { backend.handleAppTerminated(bundleID: "com.foo") }

        XCTAssertTrue(afterTermination.contains {
            if case .routedApps(let id, let names) = $0 { return id == device.id && names == ["Bar"] }
            return false
        }, "the terminated app must drop out of .routedApps while the surviving sibling stays")

        await pollUntil { engine.streamAddCalls.filter { $0.0 == device.outputID }.count >= 2 }
        let binds = engine.streamAddCalls.filter { $0.0 == device.outputID }
        XCTAssertEqual(binds.count, 2, "a membership change rebinds the device: stop, then re-add")
        XCTAssertNotEqual(binds.last?.1, firstStream,
                          "the surviving-only app-set is a different signature and must get a fresh stream id")
        XCTAssertTrue(engine.removedIDs.contains(device.outputID),
                      "the old (two-app) session must be torn down before the rebind")
    }

    /// T8 lifecycle edge case, cross-device isolation: an app routed to device A
    /// quits mid-stream while a sibling app is independently routed to device B.
    /// The unrelated device's binding must be completely undisturbed.
    func testAppTerminatedOnOneDeviceDoesNotAffectSiblingAppOnAnotherDevice() async {
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: workingPerAppCapture())
        defer { backend.stop() }
        let devA = ap2Device(id: "AA:BB:CC:DD:EE:81", name: "Speaker A")
        let devB = ap2Device(id: "AA:BB:CC:DD:EE:82", name: "Speaker B")
        await startAndDiscover(backend, engine, discovery, devA)
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == devB.id } else { return false } }
        } after: { discovery.fire(.appeared(devB)) }
        await pollUntil { engine.fedIDs.contains(devB.outputID) }

        backend.updateAppRoutes([
            route("com.foo", name: "Foo", toDevice: devA.id),
            route("com.bar", name: "Bar", toDevice: devB.id),
        ])
        await pollUntil {
            engine.streamAddCalls.contains { $0.0 == devA.outputID }
                && engine.streamAddCalls.contains { $0.0 == devB.outputID }
        }

        backend.handleAppTerminated(bundleID: "com.foo")
        await pollUntil { engine.removedIDs.contains(devA.outputID) }

        // devB's binding must be completely untouched: exactly one bind, no removal.
        XCTAssertEqual(engine.streamAddCalls.filter { $0.0 == devB.outputID }.count, 1,
                       "an unrelated app's termination must not perturb a sibling device's binding")
        XCTAssertFalse(engine.removedIDs.contains(devB.outputID),
                       "device B must never be torn down by device A's app terminating")
    }

    // MARK: T4 terminate → relaunch cycle

    /// T4 bug fix: `handleAppTerminated` emits `.routedAppRunning(isRunning: false)`
    /// so the UI can show an offline indicator, and `handleAppLaunched` emits
    /// `.routedAppRunning(isRunning: true)` to clear it. End-to-end event assertion.
    func testTerminateAndRelaunchEmitsRoutedAppRunningEvents() async {
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: workingPerAppCapture())
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:90", name: "Relaunch Speaker")
        await startAndDiscover(backend, engine, discovery, device)

        // Install a route so the app is known to the backend as `.device(id:)`.
        backend.updateAppRoutes([route("com.foo.music", name: "Music", toDevice: device.id)])
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }

        // Step 1: app quits — expect .routedAppRunning(isRunning: false).
        let terminateEvents = await collect(from: backend) { events in
            events.contains {
                if case .routedAppRunning(let id, let running) = $0 {
                    return id == "com.foo.music" && !running
                }
                return false
            }
        } after: { backend.handleAppTerminated(bundleID: "com.foo.music") }

        XCTAssertTrue(terminateEvents.contains {
            if case .routedAppRunning(let id, let running) = $0 { return id == "com.foo.music" && !running }
            return false
        }, "handleAppTerminated must emit .routedAppRunning(isRunning: false)")

        // Step 2: app relaunches — expect .routedAppRunning(isRunning: true).
        let relaunchEvents = await collect(from: backend) { events in
            events.contains {
                if case .routedAppRunning(let id, let running) = $0 {
                    return id == "com.foo.music" && running
                }
                return false
            }
        } after: { backend.handleAppLaunched(bundleID: "com.foo.music") }

        XCTAssertTrue(relaunchEvents.contains {
            if case .routedAppRunning(let id, let running) = $0 { return id == "com.foo.music" && running }
            return false
        }, "handleAppLaunched must emit .routedAppRunning(isRunning: true)")
    }

    /// T4 bug fix: after a terminate + relaunch, the backend restarts the per-app
    /// capture tap so audio flows to the redirect target again without the user
    /// touching the route table.
    func testRelaunchRestartsCaptureAndRebindsDevice() async {
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: workingPerAppCapture())
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:91", name: "Restart Speaker")
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.bar.player", name: "Player", toDevice: device.id)])
        // Wait for the first bind.
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }
        let firstBindCount = engine.streamAddCalls.filter { $0.0 == device.outputID }.count

        // Terminate the app (tears down the tap and kills the stream binding).
        backend.handleAppTerminated(bundleID: "com.bar.player")
        await pollUntil { engine.removedIDs.contains(device.outputID) }

        // Relaunch: the backend must restart capture and re-bind the device.
        backend.handleAppLaunched(bundleID: "com.bar.player")
        await pollUntil {
            engine.streamAddCalls.filter { $0.0 == device.outputID }.count > firstBindCount
        }

        let totalBinds = engine.streamAddCalls.filter { $0.0 == device.outputID }.count
        XCTAssertGreaterThan(totalBinds, firstBindCount,
                             "handleAppLaunched must re-bind the device after the relaunch")
    }

    /// T4 bug fix: `handleAppLaunched` is a no-op for a bundle ID that has no
    /// active `.device(id:)` route — non-routed app launches must never perturb
    /// the backend.
    func testRelaunchOfNonRoutedAppIsNoOp() async {
        let (backend, engine, discovery) = makeBackend()
        defer { backend.stop() }
        let device = ap2Device()
        await startAndDiscover(backend, engine, discovery, device)

        // A route exists for com.foo but NOT for com.unrelated.
        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])
        // com.foo's bind is issued asynchronously (bindTail Task); wait for it to
        // settle so the baseline below is stable and not racing that bind.
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }

        let streamCountBefore = engine.streamAddCalls.count
        // Launching an unrouted app must be silent (no stream ops, no events).
        backend.handleAppLaunched(bundleID: "com.unrelated.app")
        // Give any async side effects time to propagate.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(engine.streamAddCalls.count, streamCountBefore,
                       "a launch for a non-routed bundle ID must not issue any engine ops")
    }

    /// T8 lifecycle edge case: `.processNotYetAudible` bounded retry, previously
    /// only exercised at the `PerAppCaptureCoordinator` level
    /// (`testProcessNotYetAudibleSurfacesErrorAndTearsDown`). This proves
    /// `NativeBackend`'s OWN retry scheduling (`scheduleProcessNotYetAudibleRetry`,
    /// `deadBundleIDs`) actually drives a failed capture all the way to a
    /// successful retry and rejoins the live mixer topology (the device gets
    /// bound to the app's stream) — with no further user action after the
    /// original route.
    ///
    /// Polls on side effects (`tap.attemptsMade`, `engine.streamAddCalls`)
    /// rather than an event-stream race: the FIRST `.routedApps` fire for this
    /// route is the OPTIMISTIC one `updateAppRoutes` publishes from route-table
    /// membership alone, before the capture has even attempted once — it does
    /// not by itself prove the retry mechanism ran.
    func testProcessNotYetAudibleBoundedRetryRecoversAndRejoinsMixerTopology() async {
        let tap = FlakyThenSucceedsTap(failuresBeforeSuccess: 2)
        let perAppCapture = PerAppCaptureCoordinator(
            makeTap: { tap }, resolvePID: { _ in 4242 }, muteBehavior: .mutedWhenTapped)
        let engine = SpyEngine()
        let discovery = FakeDiscovery()
        let backend = NativeBackend(
            engineControl: engine, discoverySource: discovery, systemVolume: FakeSystemVolume(),
            resolvePID: { _ in 4242 }, injectedPerAppCapture: perAppCapture,
            processNotYetAudibleRetryDelay: 0.05, processNotYetAudibleMaxRetries: 5)
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:83", name: "Retry Speaker")
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])

        // The scripted tap fails twice (processNotYetAudible) before succeeding —
        // the bounded retry must chase it down to a 3rd, successful attempt with
        // NO further updateAppRoutes call.
        await pollUntil(timeout: 5) { tap.attemptsMade >= 3 }
        XCTAssertGreaterThanOrEqual(tap.attemptsMade, 3,
                                    "2 scripted failures + at least 1 successful retry, all self-driven")

        // Once recovered, the app rejoins the live mixer topology: the device
        // gets bound to a per-app stream — which only happens for a bundle ID
        // NOT excluded as dead.
        await pollUntil(timeout: 5) { engine.streamAddCalls.contains { $0.0 == device.outputID } }
        XCTAssertTrue(engine.streamAddCalls.contains { $0.0 == device.outputID },
                      "after the bounded retry recovers the capture, the device must be bound to the app's stream")
    }

    /// T8 edge case 2 (device disappears while routed), driven through the REAL
    /// cross-controller chain rather than a direct `updateAppRoutes` call: a
    /// stale doc comment in `NativeBackend.swift` (`MARK: Per-app routing edge
    /// cases (T8)`, case 2) names a test —
    /// `testDeviceUnavailableTearsDownBackendCaptureViaAppRoutingController` —
    /// that does not actually exist anywhere in the suite (only
    /// `AppRoutingController`-only-level coverage exists:
    /// `testHandleDeviceUnavailableResetsMatchingRoutesAndPersists`). This is
    /// that missing test: `AppRoutingController.handleDeviceUnavailable` must
    /// reach all the way through `onRoutesDidChange` into a REAL
    /// `NativeBackend.updateAppRoutes` and tear down the per-app stream binding
    /// — not just reset the persisted route in isolation.
    func testDeviceUnavailableTearsDownBackendCaptureViaAppRoutingController() async throws {
        let (backend, engine, discovery) = makeBackend()
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:84", name: "Vanishing Speaker")
        await startAndDiscover(backend, engine, discovery, device)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.onRoutesDidChange = {
            backend.updateAppRoutes(controller.appRoutes, excludedBundleIDs: [])
        }
        controller.addRoute(bundleID: "com.foo.player", displayName: "Foo")
        controller.setDestination(.device(id: device.id), for: "com.foo.player")

        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }

        // The device the route targets disappears. In production this is
        // `PopoverController.update(devices:)` calling `handleDeviceUnavailable`
        // (PLAN decision 7); here we call it directly, exactly as that boundary
        // does, to prove the layers beneath it stay in sync.
        controller.handleDeviceUnavailable(id: device.id)

        await pollUntil { engine.removedIDs.contains(device.outputID) }
        XCTAssertTrue(engine.removedIDs.contains(device.outputID),
                      "a device disappearing while routed must tear down its per-app stream binding, " +
                      "driven through the REAL AppRoutingController -> NativeBackend chain, not a direct call")
        XCTAssertEqual(controller.appRoutes.first { $0.bundleID == "com.foo.player" }?.destination, .noRedirect,
                       "the persisted route must fall back to .noRedirect")
    }

    // MARK: Local playback (Bug T2 — .currentDevice as an independent local stream)

    /// A ``LocalPlaybackControlling`` double: records every call so a test can
    /// assert the NativeBackend wiring without an `AVAudioEngine` or audio
    /// hardware (mirrors `FakeCapture` for the whole-system tap seam).
    private final class SpyLocalPlayback: LocalPlaybackControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _added: [(bundleID: String, volume: Float)] = []
        private var _removed: [String] = []
        private var _volumes: [(bundleID: String, volume: Float)] = []
        private var _receiveCount = 0
        private var _started = false

        func addApp(bundleID: String, tapFormat: TapFormat, volume: Float) throws {
            lock.withLock { _added.append((bundleID, volume)) }
        }
        func removeApp(bundleID: String) { lock.withLock { _removed.append(bundleID) } }
        func setVolume(_ volume: Float, for bundleID: String) {
            lock.withLock { _volumes.append((bundleID, volume)) }
        }
        func receive(buffer: CapturedBuffer, for bundleID: String) {
            lock.withLock { _receiveCount += 1 }
        }
        func start() throws { lock.withLock { _started = true } }
        func stop() { lock.withLock { _started = false } }

        var addedApps: [(bundleID: String, volume: Float)] { lock.withLock { _added } }
        var removedApps: [String] { lock.withLock { _removed } }
        var volumeSets: [(bundleID: String, volume: Float)] { lock.withLock { _volumes } }
        var receiveCount: Int { lock.withLock { _receiveCount } }
        var didStart: Bool { lock.withLock { _started } }
        /// The volume the player for `bundleID` was most recently ADDED at.
        func addedVolume(for bundleID: String) -> Float? {
            lock.withLock { _added.last { $0.bundleID == bundleID }?.volume }
        }
    }

    /// Routing an app to `.currentDevice` (Bug T2) must (1) exclude it from the
    /// whole-system AirPlay tap — so it doesn't ALSO play in the AirPlay mix — and
    /// (2) start its per-app capture and hand it to the local playback engine as
    /// its own independent stream. Driven through the FULL `updateAppRoutes` call
    /// against the REAL `NativeCaptureCoordinator` (exclusion observed end to end)
    /// with a scripted per-app tap + a local-playback spy.
    func testCurrentDeviceRouteExcludesAppFromSystemMixAndStartsLocalStream() async {
        let resolvePID: @Sendable (String) -> pid_t? = { $0 == "com.local" ? 111 : nil }
        // Per-app tap that always reaches `.capturing` (no real Core Audio).
        let perAppCapture = PerAppCaptureCoordinator(
            makeTap: { AlwaysSucceedsTap() }, resolvePID: { _ in 4242 }, muteBehavior: .mutedWhenTapped)
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: perAppCapture)

        // Real whole-system coordinator over a recording tap, so its exclusion set
        // is observable end to end (as opposed to a direct updateRouting call).
        let systemTap = RecordingSystemTap()
        let coordinator = NativeCaptureCoordinator(
            makeTap: { systemTap }, sink: NoOpSink(), makeConverter: { _ in PassthroughConverter() },
            resolvePID: resolvePID, muteBehavior: .mutedWhenTapped)
        backend.captureCoordinator = coordinator
        let localPlayback = SpyLocalPlayback()
        backend.localPlaybackEngine = localPlayback
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        // Bring up the whole-system capture (a Selected Device) so the tap is
        // running and its exclusion set is observable on the recording tap.
        let systemDevice = ap2Device(id: "AA:BB:CC:DD:EE:70", name: "Whole System Speaker")
        await startAndDiscover(backend, engine, discovery, systemDevice)
        backend.setOutputSet([systemDevice.id])
        await pollUntil { systemTap.createCount >= 1 }
        XCTAssertEqual(systemTap.excludedPIDs, [], "nothing local yet -> the system mix must include every app")

        // Route an app to .currentDevice (deliberately "play here, on the Mac").
        backend.updateAppRoutes([
            AppRoute(bundleID: "com.local", displayName: "Local App", destination: .currentDevice),
        ])

        // 1) EXCLUDED from the whole-system AirPlay tap (so it plays locally, not
        //    ALSO in the AirPlay mix).
        await pollUntil { systemTap.excludedPIDs.contains(111) }
        XCTAssertTrue(systemTap.excludedPIDs.contains(111),
                      "a .currentDevice app's pid must be excluded from the whole-system tap")

        // 2) Its per-app capture started …
        await pollUntil {
            if case .capturing = perAppCapture.state(for: "com.local") { return true }
            return false
        }
        // … and it was handed to the local playback engine as its own stream.
        await pollUntil { localPlayback.addedApps.contains { $0.bundleID == "com.local" } }
        XCTAssertTrue(localPlayback.addedApps.contains { $0.bundleID == "com.local" },
                      "a .currentDevice app must be added to the local playback engine (its own stream)")
        XCTAssertTrue(localPlayback.didStart,
                      "the local playback engine must be started for the first .currentDevice app")
        // The whole-system stream keeps streaming to its own device throughout.
        XCTAssertTrue(engine.addedIDs.contains(systemDevice.outputID),
                      "the whole-system stream must be unaffected by the local route")
    }

    /// A volume change for a `.currentDevice` app reaches the local playback engine
    /// (Bug T2). The player is first ADDED at the route's own volume when its tap
    /// starts capturing; a later `setLocalPlaybackVolume` (the popover slider's
    /// low-latency path) maps the 0–100 int onto the engine's 0.0…1.0 contract.
    func testSetLocalPlaybackVolumeReachesLocalEngine() async {
        let perAppCapture = PerAppCaptureCoordinator(
            makeTap: { AlwaysSucceedsTap() }, resolvePID: { _ in 4242 }, muteBehavior: .mutedWhenTapped)
        let (backend, engine, _) = makeBackend(injectedPerAppCapture: perAppCapture)
        let localPlayback = SpyLocalPlayback()
        backend.localPlaybackEngine = localPlayback
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        backend.updateAppRoutes([
            AppRoute(bundleID: "com.local", displayName: "Local App", destination: .currentDevice, volume: 80),
        ])

        // Added at the route's own volume (80% -> 0.8) once its tap is capturing.
        await pollUntil { localPlayback.addedApps.contains { $0.bundleID == "com.local" } }
        XCTAssertEqual(localPlayback.addedVolume(for: "com.local") ?? -1, 0.8, accuracy: 0.001,
                       "the local player must be added at the route's volume (80% -> 0.8)")

        // A later slider-driven change reaches the engine as a 0.0…1.0 set.
        backend.setLocalPlaybackVolume(volume: 40, bundleID: "com.local")
        XCTAssertTrue(
            localPlayback.volumeSets.contains { $0.bundleID == "com.local" && abs($0.volume - 0.4) < 0.001 },
            "setLocalPlaybackVolume(40) must reach the local engine as 0.4 for com.local")
    }

    private func pollUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - collect(after:) convenience

private extension NativeBackendTests {
    /// Subscribe, run `after` (which fires the stimulus once the subscription is
    /// live), then collect until `predicate`.
    func collect(
        from backend: NativeBackend,
        timeout: TimeInterval = 3,
        until predicate: @escaping @Sendable ([BackendEvent]) -> Bool,
        after stimulus: @escaping () -> Void
    ) async -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let done = expectation(description: "predicate satisfied")
        let box = EventBox()
        let task = Task {
            for await event in stream {
                if case .level = event { continue }
                let all = await box.append(event)
                if predicate(all) { done.fulfill(); break }
            }
        }
        // Give the subscription a beat to register on stateQueue before stimulating.
        try? await Task.sleep(nanoseconds: 20_000_000)
        stimulus()
        await fulfillment(of: [done], timeout: timeout)
        task.cancel()
        return await box.snapshot()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
