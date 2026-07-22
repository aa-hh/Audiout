import XCTest
import AirPlayEngine
@testable import AudiouterCore

/// Hermetic tests for ``NativeBackend`` (T-NB-BACKEND-1): a spy ``EngineControlling``
/// (records ops, fires synthetic state transitions) + an injected ``DiscoverySource``
/// double (feeds `DiscoveryEvent`s synchronously). No engine thread, no C cluster,
/// no `NWBrowser`, no network, no TCC.
///
/// Covers: `deviceAdded` on discovery, AP1 surfaced-available-and-engine-driven,
/// `deviceUpdated` on an out-of-band engine state transition, best-effort
/// convergence (D4), and the mute stash/restore shim.
final class NativeBackendTests: XCTestCase {

    // MARK: AirPlay-1 perceptual volume curve (the "cliff at ~50%" fix, 2026-07-22)

    /// The AP1 curve must keep the WHOLE slider audible: it compresses UI 0–100
    /// onto the top of the AirPlay range so the C map (`-30 + 0.3·pct`) never
    /// lands below `airPlay1MinVolumeDB`. Endpoints, monotonicity, and the "never
    /// below the floor" invariant are the contract; the exact floor is tuned by ear.
    func testEngineVolumeAP1KeepsWholeSliderAudible() {
        // Helper: normalized 0…1 → the AirPlay dB the C layer will send.
        func dB(_ normalized: Double) -> Double { -30.0 + 0.3 * (normalized * 100.0) }

        // 100% → 0 dB (full), 0% → the floor (not −30 dB).
        XCTAssertEqual(NativeBackend.engineVolumeAP1(100), 1.0, accuracy: 0.001)
        XCTAssertEqual(dB(NativeBackend.engineVolumeAP1(0)),
                       NativeBackend.airPlay1MinVolumeDB, accuracy: 0.2)

        // Every position, including the bottom, stays at or above the floor —
        // this is exactly what the linear map failed to do (0% → −30 dB → silent).
        for pct in 0...100 {
            XCTAssertGreaterThanOrEqual(
                dB(NativeBackend.engineVolumeAP1(pct)),
                NativeBackend.airPlay1MinVolumeDB - 0.001,
                "AP1 volume at \(pct)% dropped below the perceptual floor")
        }

        // Monotonically non-decreasing across the slider.
        for pct in 1...100 {
            XCTAssertGreaterThanOrEqual(
                NativeBackend.engineVolumeAP1(pct),
                NativeBackend.engineVolumeAP1(pct - 1),
                "AP1 volume curve is not monotonic at \(pct)%")
        }

        // AP2 path is untouched: linear 0…1 (0% → −30 dB is fine on AP2 receivers).
        XCTAssertEqual(NativeBackend.engineVolume(0), 0.0, accuracy: 0.001)
        XCTAssertEqual(NativeBackend.engineVolume(50), 0.5, accuracy: 0.001)
        XCTAssertEqual(NativeBackend.engineVolume(100), 1.0, accuracy: 0.001)
    }

    // MARK: Doubles

    /// Records every engine op and lets a test drive the device-state stream.
    private final class SpyEngine: EngineControlling, @unchecked Sendable {
        let lock = NSLock()
        private(set) var started = false
        private(set) var stopped = false
        private(set) var discoveryFed: [OutputID] = []
        /// The full descriptors handed to `updateDiscovery`, in order — lets an
        /// integration test assert the ENGINE-facing `kind`/`name`/`parsedID` that
        /// route a device to `output_raop` vs `output_airplay`, not just its id.
        private(set) var fedDescriptors: [DeviceDescriptor] = []
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
        private var remoteContinuation: AsyncStream<RemoteEvent>.Continuation?

        var dacpID: UInt64 { 0x1122334455667788 }

        func start() async throws { lock.withLock { started = true } }
        func stop() async { lock.withLock { stopped = true } }

        @discardableResult
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            let id = descriptor.parsedID ?? OutputID(rawValue: 0)
            lock.withLock {
                discoveryFed.append(id)
                fedDescriptors.append(descriptor)
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
        func makeRemoteEventStream() -> AsyncStream<RemoteEvent> {
            AsyncStream { continuation in
                lock.withLock { self.remoteContinuation = continuation }
            }
        }
        /// Push a synthetic out-of-band transition through the state stream.
        func pushState(_ id: OutputID, _ state: OutputState) {
            let c = lock.withLock { continuation }
            c?.yield((id, state))
        }
        /// Push a synthetic remote-control event (a speaker transport key or a
        /// change to the speaker's own volume) through the remote-event stream.
        func pushRemoteEvent(_ event: RemoteEvent) {
            let c = lock.withLock { remoteContinuation }
            c?.yield(event)
        }

        // Thread-safe snapshots for assertions.
        var addedIDs: [OutputID] { lock.withLock { added } }
        var removedIDs: [OutputID] { lock.withLock { removed } }
        var fedIDs: [OutputID] { lock.withLock { discoveryFed } }
        var fedDescriptorList: [DeviceDescriptor] { lock.withLock { fedDescriptors } }
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

    /// A no-socket ``DACPEndpoint`` double: the REAL `DACPServer.start(dacpID:)`
    /// binds an `NWListener` and advertises `_dacp._tcp` over Bonjour, which fires
    /// the macOS Local Network permission prompt once per `--parallel` worker
    /// process. Every backend this file constructs gets this fake instead (via
    /// `makeBackend` or explicitly), so the hermetic suite opens zero sockets.
    /// The volume-report handling stays covered: tests drive
    /// `applyDacpVolume`/`applyDacpVolumeStep` — the exact closures
    /// `NativeBackend.start()` wires to `onVolume`/`onVolumeStep` — directly.
    private final class FakeDACPEndpoint: DACPEndpoint, @unchecked Sendable {
        var onVolume: (@Sendable (_ activeRemote: UInt32, _ level: Double) -> Void)?
        var onVolumeStep: (@Sendable (_ activeRemote: UInt32, _ direction: Int) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start(dacpID: UInt64) { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    /// A minimal ``ServiceBrowsing`` that lets a test push a resolved service
    /// through the REAL ``NativeDiscovery`` production pipeline (identity →
    /// `descriptor(from:)` → `buildDevice`), so the end-to-end AP1 test exercises
    /// the actual descriptor construction rather than a hand-built fixture.
    private final class ScriptedBrowser: ServiceBrowsing, @unchecked Sendable {
        var onResolve: (@Sendable (ResolvedService) -> Void)?
        var onRemove: (@Sendable (RemovedService) -> Void)?
        var onStateChange: (@Sendable (BrowserState) -> Void)?
        func start() {}
        func stop() {}
        func resolve(_ service: ResolvedService) { onResolve?(service) }
    }

    /// A tiny thread-safe holder for the `DiscoveredDevice` that
    /// `NativeDiscovery.onEvent` (called on its own serial queue) produces.
    private final class DiscoveredBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DiscoveredDevice?
        func set(_ d: DiscoveredDevice) { lock.withLock { value = d } }
        func get() -> DiscoveredDevice? { lock.withLock { value } }
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
    /// A minimal thread-safe `Int` box, so a test can script the injected
    /// `connectVolume` provider across reconnect episodes (the seed reads it on
    /// `stateQueue`, off the test's thread).
    private final class LockedInt: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ v: Int) { value = v }
        func get() -> Int { lock.withLock { value } }
        func set(_ v: Int) { lock.withLock { value = v } }
    }

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
        connectVolume: @escaping @Sendable () -> Int = { AppSettings.defaultConnectVolume },
        resolvePID: @escaping @Sendable (String) -> pid_t? = { _ in nil },
        injectedPerAppCapture: PerAppCaptureCoordinator? = nil,
        injectedMeteringCapture: PerAppCaptureCoordinator? = nil
    ) -> (NativeBackend, SpyEngine, FakeDiscovery) {
        let engine = SpyEngine()
        let discovery = FakeDiscovery()
        let backend = NativeBackend(
            engineControl: engine, discoverySource: discovery, dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: systemVolume, connectVolume: connectVolume, resolvePID: resolvePID,
            injectedPerAppCapture: injectedPerAppCapture,
            injectedMeteringCapture: injectedMeteringCapture)
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

    /// An AP1-only device is surfaced `deviceAdded` AVAILABLE (it drives through the
    /// shared engine now, T7) but with `supportsAirPlay2 == false` — the flag stays
    /// false because it means "no perfect multi-room sync", not "unsupported". Its
    /// descriptor is fed to the engine exactly like an AP2 device's.
    func testAirPlay1SurfacedAvailableAndFed() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap1 = ap1Device()
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap1.id } else { return false } }
        } after: { discovery.fire(.appeared(ap1)) }

        let d = events.compactMap { if case .deviceAdded(let x) = $0 { return x } else { return nil } }.first { $0.id == ap1.id }
        XCTAssertEqual(d?.supportsAirPlay2, false, "AP1 keeps supportsAirPlay2==false — it means 'no perfect sync', still true")
        XCTAssertEqual(d?.isAvailable, true, "an AP1 receiver is reachable and engine-driveable now (T7)")

        // Fed to the engine so it becomes addOutput-able, same as an AP2 device.
        await pollUntil { engine.fedIDs.contains(ap1.outputID) }
        XCTAssertTrue(engine.fedIDs.contains(ap1.outputID), "AP1 device must be fed to the shared engine (T7)")
    }

    /// Selecting an AP1 device converges it through the SAME engine surface as AP2:
    /// it is `addOutput`-ed, marked selected/available/connected, and accepts
    /// volume + mute control (which reach `engine.setVolume`). `supportsAirPlay2`
    /// stays false throughout — the flag is not a gate any more (T7).
    func testAirPlay1ConvergesAndDrives() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap1 = ap1Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap1.id } else { return false } }
        } after: { discovery.fire(.appeared(ap1)) }

        // Select it → converge → addOutput.
        backend.setOutputSet([ap1.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == ap1.id }
            return d?.isSelected == true && engine.addedIDs.contains(ap1.outputID)
        }
        let selected = backend.devices.first { $0.id == ap1.id }
        XCTAssertEqual(selected?.isSelected, true, "a selected AP1 device converges on (T7)")
        XCTAssertEqual(selected?.isAvailable, true)
        XCTAssertEqual(selected?.supportsAirPlay2, false, "converging must NOT flip the AP1 sync flag")
        XCTAssertEqual(selected?.connectionState, .connected, "a driven AP1 device reaches .connected")
        XCTAssertTrue(engine.addedIDs.contains(ap1.outputID), "AP1 device must be addOutput-ed (T7)")

        // Volume + mute reach the engine through the ordinary surface.
        backend.setVolume(42, for: ap1.id)
        await pollUntil { engine.volumeCalls.contains { $0.0 == ap1.outputID } }
        XCTAssertTrue(engine.volumeCalls.contains { $0.0 == ap1.outputID },
                      "setVolume on an AP1 device must reach engine.setVolume (T7)")

        backend.setMuted(true, for: ap1.id)
        await pollUntil { backend.devices.first { $0.id == ap1.id }?.isMuted == true }
        XCTAssertEqual(backend.devices.first { $0.id == ap1.id }?.isMuted, true,
                       "mute works on an AP1 device (stashed-volume shim, shared path)")
    }

    /// END-TO-END AP1 (classic RAOP) LIVE-PATH INTEGRATION TEST — the test that
    /// would have caught the two live-feed gaps (kind never `.raop`; `parsedID`
    /// nil for name-derived gear). It drives a REALISTIC classic-RAOP service —
    /// `"<12-hex>@<display>"` instance name, `_raop._tcp`, NO `deviceid` TXT, NO
    /// `features` TXT (exactly what shairport-sync / AirPort Express advertise) —
    /// through the ACTUAL `NativeDiscovery` → `descriptor(from:)` production, then
    /// as far through `NativeBackend`'s converge/feed toward the engine as the
    /// harness allows, and asserts the ENGINE-facing descriptor routes to
    /// `output_raop`. Fully deterministic: no live network, no real engine.
    func testClassicRaopDiscoversAndFeedsEngineAsRaopEndToEnd() async {
        // A realistic classic-RAOP advert: MAC-prefixed instance name, _raop._tcp,
        // and an EMPTY TXT record — no `deviceid`, no `features`.
        let instanceName = "6B2E52B73717@Kitchen Speaker"
        let service = ResolvedService(
            serviceType: .raop,
            name: instanceName,
            hostname: "kitchen.local",
            address: "192.168.1.77",
            family: .ipv4,
            port: 5000,
            txtRecord: [:]
        )

        // (1) Drive the REAL NativeDiscovery → descriptor(from:) production.
        let browser = ScriptedBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let box = DiscoveredBox()
        discovery.onEvent = { if case .appeared(let d) = $0 { box.set(d) } }
        discovery.start()
        browser.resolve(service)                    // re-dispatched onto discovery's serial queue
        await pollUntil { box.get() != nil }
        discovery.stop()
        guard let discovered = box.get() else {
            return XCTFail("a classic-RAOP service must surface as .appeared (not be dropped)")
        }

        // The produced engine-facing DeviceDescriptor:
        let descriptor = discovered.descriptor
        //  - routes to output_raop, not the AP2 gate (Gap A).
        XCTAssertEqual(descriptor.kind, .raop,
                       "a _raop._tcp service must produce kind == .raop so feedDescriptor targets output_raop")
        //  - keeps the raw "<12-hex>@…" prefix so raop_device_cb can parse the id.
        XCTAssertEqual(descriptor.name, instanceName,
                       "the raw 12-hex '@' prefix must survive to the engine for raop_device_cb's safe_hextou64")
        //  - has a non-nil parsedID (Gap B: updateDiscovery throws invalidDescriptor otherwise).
        XCTAssertNotNil(descriptor.parsedID,
                        "parsedID must be non-nil (deviceid injected from the name) or updateDiscovery rejects it")
        //  - three-way sync: parsedID == the name-derived OutputID == the raw hex.
        XCTAssertEqual(descriptor.parsedID, discovered.outputID,
                       "parsedID (from injected deviceid) must equal the name-derived OutputID")
        XCTAssertEqual(discovered.outputID.rawValue, 0x6B2E52B73717,
                       "OutputID is the 12-hex prefix the C side parses from the name")
        XCTAssertEqual(descriptor.txtRecord["deviceid"], "6B:2E:52:B7:37:17",
                       "the injected deviceid is the canonical colon-hex form parsedID/raop_device_cb agree on")
        //  - classified AP1-only and available.
        XCTAssertFalse(discovered.isAirPlay2Supported, "a raop-only device classifies AP1-only")
        XCTAssertTrue(discovered.isAvailable, "a live AP1 receiver is available")

        // (2) Drive that DiscoveredDevice through NativeBackend toward the engine
        // and assert the descriptor the ENGINE actually receives still routes to
        // output_raop (kind == .raop) with the raw name intact.
        let (backend, engine, fakeDiscovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == discovered.id } else { return false } }
        } after: { fakeDiscovery.fire(.appeared(discovered)) }

        // The mapped, user-facing device is AP1-only and available.
        let mapped = backend.devices.first { $0.id == discovered.id }
        XCTAssertEqual(mapped?.supportsAirPlay2, false, "AP1 stays AP1-only through the backend")
        XCTAssertEqual(mapped?.isAvailable, true)
        XCTAssertEqual(mapped?.name, "Kitchen Speaker", "the user-facing name is the stripped display name")

        // Select it → converge → updateDiscovery + addOutput on the shared engine.
        backend.setOutputSet([discovered.id])
        await pollUntil {
            engine.fedIDs.contains(discovered.outputID) && engine.addedIDs.contains(discovered.outputID)
        }

        let fed = engine.fedDescriptorList.first { $0.parsedID == discovered.outputID }
        XCTAssertNotNil(fed, "the AP1 device must be fed to engine.updateDiscovery")
        XCTAssertEqual(fed?.kind, .raop,
                       "the engine feed routes AP1 to airplayengine_feed_raop_device (output_raop), NOT output_airplay")
        XCTAssertEqual(fed?.name, instanceName,
                       "the raw hex-prefixed name reaches the engine so raop_device_cb parses the id from it")
        XCTAssertTrue(engine.addedIDs.contains(discovered.outputID),
                      "the AP1 device is addOutput-ed on the shared engine")
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
    /// volume to the engine, sourced from the CONFIGURED connect-volume default —
    /// NOT the Mac's current system level (G1-N1: Mac speakers often run loud, so
    /// inheriting the system level could BLAST a real AirPlay speaker on connect).
    /// Without the seed at all, the engine's zero-initialized volume field leaves
    /// the session at ≈ −30 dB (silent) until the first slider drag — the −30 dB
    /// trap. The system level here is set deliberately LOUD (90) to prove the seed
    /// ignores it.
    func testConnectSeedsEngineVolumeFromConfiguredDefault() async {
        let systemVolume = FakeSystemVolume(volume: 90)   // loud — must NOT be inherited
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume, connectVolume: { 35 })
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }

        await pollUntil { engine.volumeCalls.contains { $0.0 == device.outputID } }
        XCTAssertTrue(engine.volumeCalls.contains { $0.0 == device.outputID && abs($0.1 - 0.35) < 0.001 },
                      "connect must seed the engine volume from the configured connect default (35% → 0.35), not the loud system level")
        XCTAssertFalse(engine.volumeCalls.contains { $0.0 == device.outputID && abs($0.1 - 0.90) < 0.001 },
                       "the loud system level (90%) must NEVER reach the wire on connect")
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 35,
                       "the model row must reflect the seeded connect default")
    }

    /// The seed must NEVER be 0/silent — the −30 dB trap — even when the configured
    /// connect volume is 0 (a bad/out-of-range provider value) AND the system
    /// volume is unreadable. The seed clamps to `AppSettings.minConnectVolume`, so
    /// what reaches the wire is always audible (> 0).
    func testConnectSeedIsNeverSilentEvenWhenConfiguredZero() async {
        let systemVolume = FakeSystemVolume(volume: nil)
        let (backend, engine, discovery) = makeBackend(systemVolume: systemVolume, connectVolume: { 0 })
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }

        await pollUntil { engine.volumeCalls.contains { $0.0 == device.outputID } }
        XCTAssertTrue(engine.volumeCalls.contains { $0.0 == device.outputID && $0.1 > 0.0 },
                      "the connect seed must be audible (> 0) — never the 0/silent −30 dB trap")
        XCTAssertFalse(engine.volumeCalls.contains { $0.0 == device.outputID && $0.1 == 0.0 },
                       "a 0 configured value must be clamped up to the audible floor, never pushed as silence")
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, AppSettings.minConnectVolume,
                       "the model must reflect the clamped audible floor, not 0")
    }

    /// The carve-out: a buffer-size change tears every streaming device down and
    /// re-adds it through the SAME add-success branch a reconnect uses — but it is
    /// NOT a reconnect. The user's in-session level (80%) must survive; the connect
    /// default (30%) must NOT leak onto the re-added session.
    func testApplyStartBufferPreservesInSessionVolumeNotConnectDefault() async {
        let (backend, engine, discovery) = makeBackend(connectVolume: { 30 })
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }

        // User dials in an in-session level distinct from the connect default.
        backend.setVolume(80, for: device.id)
        await pollUntil { backend.devices.first { $0.id == device.id }?.volume == 80 }

        await backend.applyStartBuffer(ms: 1500)

        // If the re-add had reseeded from the connect default, the model would read 30.
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 80,
                       "a buffer change must preserve the in-session level, not reset to the connect default")
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
    /// connect default (35).
    func testAutoRecoveryReconnectReseedsEngineVolume() async {
        let (backend, engine, discovery) = makeBackend(connectVolume: { 35 })
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }
        await pollUntil { engine.volumeCalls.contains { $0.0 == device.outputID } }

        // User dials in an in-session level distinct from the connect default.
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

        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 35,
                       "an auto-recovery reconnect must reseed from the connect default (35), not preserve the pre-drop in-session level (75)")
        XCTAssertTrue(engine.volumeCalls.last.map { $0.0 == device.outputID && abs($0.1 - 0.35) < 0.001 } ?? false,
                      "the auto-recovery reconnect must push the connect default to the engine, not skip the seed")
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
        let (backend, engine, discovery) = makeBackend(connectVolume: { 55 })
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
    /// CURRENT connect volume on EVERY reconnect — not just the first. The original
    /// bug: the connect-time seed was de-duped via a hand-maintained `volumeSeeded`
    /// set that had to be cleared at every teardown path; the FIRST reconnect
    /// reseeded, but a SECOND disconnect→reconnect cycle kept the first reconnect's
    /// stale level (the set was still marked "seeded this session"), so the device
    /// came back at the wrong volume. The fix keys the seed on the `added` false→
    /// true edge — the connection ground truth already cleared at every teardown —
    /// so a missed/reordered clear can't silently skip a reseed.
    ///
    /// This drives TWO full disconnect / setting-change / reconnect cycles with the
    /// dispatcher's state-stream mirror ACTIVE (every `addOutput` also yields a
    /// `.connected` on the state stream, exactly as the vendored dispatcher does —
    /// so BOTH add-success seed sites are exercised on every connect), and asserts
    /// each reconnect reflects the CURRENT configured connect volume (scripted via a
    /// mutable box between episodes), on both the model and the wire. It is the
    /// `added`-edge de-dup — not the seed source — that this guards, so it now
    /// drives the connect-volume setting rather than the (no-longer-inherited)
    /// system level.
    func testSecondReconnectReseedsFromCurrentConnectVolume() async {
        let connectVolume = LockedInt(50)
        let (backend, engine, discovery) = makeBackend(connectVolume: { connectVolume.get() })
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

        // Drives one connect (setOutputSet ON) at a scripted connect volume and
        // returns once the seed for THIS episode has landed on model + engine.
        func connect(at level: Int) async {
            connectVolume.set(level)
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
                       "initial connect must seed the current connect volume (50)")

        // Cycle 1: disconnect, raise the connect volume to 75, reconnect.
        await disconnect()
        await connect(at: 75)
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.volume, 75,
                       "the FIRST reconnect must reseed from the new connect volume (75)")
        XCTAssertTrue(engine.volumeCalls.last.map { $0.0 == device.outputID && abs($0.1 - 0.75) < 0.001 } ?? false,
                      "the first reconnect must push 0.75 to the engine")

        // Cycle 2: disconnect, DROP the connect volume to 25, reconnect. THIS is the
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
    /// its stashed/intended level is updated to track the CURRENT connect volume,
    /// so a later unmute restores to that level rather than whatever the device
    /// happened to hold before it was muted.
    func testMutedDeviceStaysEffectiveZeroAfterConnectTimeSeed() async {
        let (backend, engine, discovery) = makeBackend(connectVolume: { 60 })
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

    /// Teardown-on-leave keys on REACHABILITY, not the AP2 flag (T7). The
    /// "AP2→AP1 downgrade" scenario the sticky rule now prevents at the discovery
    /// layer is no longer a teardown trigger: a same-id `.updated` that is still
    /// AVAILABLE keeps its live engine session (AP1 is a valid engine target now),
    /// even if it were to report `isAirPlay2Supported == false`. Only an
    /// unavailable update tears the session down — see
    /// `testAP2GoingOfflineStaysAP2Unavailable`.
    func testAvailableUpdateKeepsEngineSession() async {
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

        // A still-available `.updated` for the same id (whatever the AP2 flag) must
        // NOT tear the session down.
        let stillAvailable = DiscoveredDevice(
            id: ap2.id,
            descriptor: ap2.descriptor,
            outputID: ap2.outputID,
            isAirPlay2Supported: false,
            isAvailable: true)
        discovery.fire(.updated(stillAvailable))

        // Give any (erroneous) teardown a window to happen, then assert it did not.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(engine.removedIDs.contains(ap2.outputID),
                       "an available `.updated` must NOT removeOutput the live session (T7)")
        XCTAssertFalse(engine.discoveryRemovedNames.contains(ap2.descriptor.name),
                       "an available `.updated` must NOT deregister the engine descriptor (T7)")
        XCTAssertEqual(backend.devices.first { $0.id == ap2.id }?.isAvailable, true,
                       "the device stays available and driven")
    }

    /// THE BUG (live-gated 2026-07-17): a real AP2 device (Sonos Move) powered OFF
    /// loses its `_airplay._tcp` advert while `_raop._tcp` lingers. Discovery now
    /// reports this as an `.updated` with `isAirPlay2Supported == true` (STICKY)
    /// and `isAvailable == false`. The backend must: keep `supportsAirPlay2 == true`
    /// (so the device isn't misreported as AP1-only — `supportsAirPlay2` is now
    /// purely informational, since AP1 rows render live/enabled the same as AP2,
    /// T10), mark the device `isAvailable == false` and deselected, tear down any
    /// live engine session/descriptor, and surface a `.failed` (retry-on-click)
    /// dot — NOT the AP1 `.off` state.
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

    /// An AP1 device rides the SAME connection-state hooks as AP2 now (T7): it rests
    /// `.off` until selected, goes `.connecting` immediately on select, and settles
    /// `.connected` once the engine confirms the add.
    func testConnectionStateAP1DrivesLikeAP2() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap1 = ap1Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap1.id } else { return false } }
        } after: { discovery.fire(.appeared(ap1)) }
        XCTAssertEqual(backend.devices.first { $0.id == ap1.id }?.connectionState, .off,
                       "an unselected AP1 device rests .off")

        backend.setOutputSet([ap1.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == ap1.id }
            return d?.connectionState == .connected && engine.addedIDs.contains(ap1.outputID)
        }
        let d = backend.devices.first { $0.id == ap1.id }
        XCTAssertEqual(d?.connectionState, .connected, "a selected AP1 device converges to .connected (T7)")
        XCTAssertTrue(engine.addedIDs.contains(ap1.outputID))
    }

    // MARK: Capture gate
    //
    // The tap is `.mutedWhenTapped` — while it runs, the Mac's own speakers are
    // SILENT. `start()` used to run it unconditionally, so the default
    // out-of-the-box state (passthrough: no AirPlay outputs selected) muted system
    // audio and sent the capture nowhere: total silence. Capture must run IF AND
    // ONLY IF at least one real receiver output (AP1 or AP2) is selected.

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

    /// The gate keys on ids that could actually be streamed to. The local Mac device
    /// (`isLocalDevice`, no engine handle) and an id we've never discovered may NOT
    /// start the tap — selecting either would mute the Mac with the audio going
    /// nowhere, which is the original bug wearing a different hat. (An AP1 receiver
    /// IS streamable now and DOES start the tap — see `testCaptureStartsOnAP1Selection`.)
    func testNonStreamableSelectionNeverStartsCapture() async {
        let (backend, engine, _) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        // The local device + an id we've never discovered — neither is a real output.
        backend.setOutputSet([NativeBackend.localDeviceID, "AA:BB:CC:DD:EE:FF"])
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(capture.ops, [], "only a real, discovered receiver may start capture")
    }

    /// Selecting an AP1 receiver starts capture (mutes the Mac) just like an AP2
    /// one — it is a real engine output now (T7).
    func testCaptureStartsOnAP1Selection() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap1 = ap1Device(id: "AA:BB:CC:DD:EE:41")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap1.id } else { return false } }
        } after: { discovery.fire(.appeared(ap1)) }
        XCTAssertFalse(capture.isCapturing, "discovery alone must not start capture")

        backend.setOutputSet([ap1.id])
        await pollUntil { capture.isCapturing }
        XCTAssertTrue(capture.isCapturing, "a selected AP1 output must start capture (T7)")

        backend.setOutputSet([])
        await pollUntil { !capture.isCapturing }
        XCTAssertFalse(capture.isCapturing, "deselecting the last AP1 output stops capture (unmuting the Mac)")
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

    /// T-GATE: `NativeBackend.setMeteringActive` forwards to the capture
    /// coordinator, and a level fired while inactive must never reach the
    /// backend's event stream — the whole point of the gate is that the RMS
    /// work stays switched off (here: the fake never even calls `onLevel`) while
    /// the popover is closed.
    func testNoLevelEmittedWhileMeteringInactive() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:55", name: "Gate Test")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil { capture.isCapturing }

        // Default state: metering inactive until explicitly turned on.
        XCTAssertFalse(capture.meteringActive, "metering must default to inactive")
        capture.fireLevelIfActive(0.5)

        let stream = backend.makeEventStream()
        let box = EventBox()
        let collector = Task {
            for await event in stream { _ = await box.append(event) }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        capture.fireLevelIfActive(0.5)   // still inactive — must be a no-op
        try? await Task.sleep(nanoseconds: 50_000_000)
        var seen = await box.snapshot()
        XCTAssertFalse(seen.contains { if case .level = $0 { return true } else { return false } },
                        "no .level may be emitted while metering is inactive")

        // Flip it on: NativeBackend must forward to the coordinator.
        (backend as MeteringControlling).setMeteringActive(true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(capture.meteringActive, "setMeteringActive(true) must reach the coordinator")
        capture.fireLevelIfActive(0.5)
        try? await Task.sleep(nanoseconds: 50_000_000)
        seen = await box.snapshot()
        XCTAssertTrue(seen.contains { if case .level = $0 { return true } else { return false } },
                       "a level fired while active must reach the event stream")

        collector.cancel()

        // stop() must leave metering inactive (teardown discipline).
        backend.stop()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(capture.meteringActive, "stop() must leave metering inactive")
    }

    /// D3: a burst of rapid capture-buffer RMS callbacks (far above the ~25 Hz
    /// display cadence) must be coalesced per device — not fanned out 1:1 as
    /// `.level` events — while still guaranteeing the burst's final value lands
    /// (the trailing-edge flush), so the meter never freezes on a stale value.
    func testLevelEmissionIsCoalescedToDisplayCadence() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:45", name: "Meter Speaker")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        // This backend's `emitLevel` is metering-gated, so turn metering ON for
        // levels to flow at all (the gate defaults off).
        (backend as MeteringControlling).setMeteringActive(true)
        await pollUntil { engine.addedIDs.contains(device.outputID) }
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }

        // Collect .level events on our own stream (the shared `collect` helper
        // filters .level out).
        let stream = backend.makeEventStream()
        actor LevelBox {
            private(set) var levels: [Float] = []
            func append(_ v: Float) { levels.append(v) }
        }
        let box = LevelBox()
        let collector = Task {
            for await event in stream {
                if case .level(let id, let rms) = event, id == device.id {
                    await box.append(rms)
                }
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)   // let the subscription register

        // Fire a burst: 40 callbacks over ~100ms (every ~2.5ms) — far above the
        // 40ms/~25Hz coalescing window. Last value is a distinctive sentinel so we
        // can confirm the trailing-edge flush delivers it.
        let burstDuration: UInt64 = 100_000_000
        let steps = 40
        let finalValue: Float = 0.987
        for i in 0..<steps {
            let value: Float = i == steps - 1 ? finalValue : Float(i) / Float(steps)
            capture.onLevel?(value)
            try? await Task.sleep(nanoseconds: burstDuration / UInt64(steps))
        }

        // Give the trailing flush (scheduled up to ~40ms after the last coalesced
        // leading edge) time to deliver the final value.
        try? await Task.sleep(nanoseconds: 80_000_000)
        collector.cancel()

        let levels = await box.levels
        // Burst spans ~100ms at a 40ms cadence: the ideal count is ceil(100/40)+1
        // = 4, generously bounded to allow for scheduler/timer jitter — the point
        // is coalescing to well below 40 (one event per callback), not a razor's
        // edge on exact timer firing.
        XCTAssertLessThanOrEqual(levels.count, 8,
            "level emission must be coalesced to ~25Hz, not fanned out per capture buffer (D3): got \(levels.count) events for \(steps) callbacks")
        XCTAssertGreaterThan(levels.count, 0, "meter must still receive events")
        XCTAssertEqual(levels.last, finalValue,
            "the burst's final value must eventually land via the trailing-edge flush, so the meter never freezes on a stale pre-quiet value")
    }

    // MARK: Sleep/wake (B6b)

    /// Discover an AP2 device, select it, and wait until it's streaming (`added`).
    /// Returns once `engine.addedIDs` contains the device and its row is selected.
    private func connectAP2(
        _ backend: NativeBackend, _ engine: SpyEngine, _ discovery: FakeDiscovery,
        _ device: DiscoveredDevice
    ) async {
        await startAndDiscover(backend, engine, discovery, device)
        backend.setOutputSet([device.id])
        await pollUntil { engine.addedIDs.contains(device.outputID) }
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }
    }

    /// A willSleep → didWake cycle PRESERVES the selection intent and re-kicks
    /// convergence: the device is torn down on sleep and re-added on wake, with no
    /// intervening `setOutputSet`.
    func testSleepWakePreservesIntentAndReconverges() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:60", name: "Sleep Speaker")
        await connectAP2(backend, engine, discovery, device)
        await pollUntil { capture.isCapturing }

        // Sleep: the engine output is removed, intent (isSelected) is preserved, and
        // the tap stops (Mac un-muted while asleep).
        backend.handleSystemWillSleep()
        await pollUntil { engine.removedIDs.contains(device.outputID) }
        await pollUntil { !capture.isCapturing }
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.isSelected, true,
                       "sleep must NOT clear the selection intent")

        let addsBeforeWake = engine.addedIDs.filter { $0 == device.outputID }.count

        // Wake: convergence re-kicks with no new setOutputSet, re-adding the device
        // and re-muting the Mac.
        backend.handleSystemDidWake()
        await pollUntil { engine.addedIDs.filter { $0 == device.outputID }.count > addsBeforeWake }
        await pollUntil { capture.isCapturing }
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.isSelected, true)
    }

    /// The sleep teardown must NOT emit a `deviceUpdated` deselect — that's what
    /// GroupController's reverse auto-swap keys off, and firing it would clear the
    /// user's intent (the whole thing sleep preserves).
    func testSleepDoesNotEmitDeselectEvent() async {
        let (backend, engine, discovery) = makeBackend()
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:61", name: "No Swap Speaker")
        await connectAP2(backend, engine, discovery, device)

        // Collect every event over a fixed window straddling the sleep, then assert
        // none is a deselect/unavailable echo for our device (the predicate here can
        // never be "satisfied", so we drain manually rather than via `collect`).
        let box = EventBox()
        let stream = backend.makeEventStream()
        let task = Task {
            for await event in stream {
                if case .level = event { continue }
                _ = await box.append(event)
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)   // let the subscription go live
        backend.handleSystemWillSleep()
        await pollUntil { engine.removedIDs.contains(device.outputID) }   // teardown really happened
        try? await Task.sleep(nanoseconds: 200_000_000)   // give any stray echo time to arrive
        task.cancel()
        let events = await box.snapshot()

        XCTAssertFalse(
            events.contains {
                if case .deviceUpdated(let d) = $0 { return d.id == device.id && (!d.isSelected || !d.isAvailable) }
                return false
            },
            "sleep teardown must emit no deselect — reverse auto-swap must not fire")
    }

    /// With a 1-minute (here: sub-second) fallback and no reconnect after wake, the
    /// watchdog un-gates capture so the Mac's own output un-mutes — WITHOUT clearing
    /// the selection intent.
    func testWakeWatchdogUnGatesCaptureWhenNoReconnect() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:62", name: "Watchdog Speaker")
        await connectAP2(backend, engine, discovery, device)
        await pollUntil { capture.isCapturing }

        // Short fallback so the test doesn't wait real minutes.
        backend.setWakeAudioRestoreDelay(0.1)
        // Make re-adds fail so NOTHING reconnects after wake.
        engine.addFailures = [device.outputID.rawValue]

        backend.handleSystemWillSleep()
        await pollUntil { !capture.isCapturing }
        backend.handleSystemDidWake()

        // The watchdog fires (~0.1s) and un-gates: capture stays/returns to OFF even
        // though the device is still selected (intent), so the Mac un-mutes.
        await pollUntil { capture.ops.last == "stop" }
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(capture.isCapturing, false,
                       "watchdog must leave capture off so the Mac un-mutes when no speaker returns")
        XCTAssertTrue(backend.test_expectedSelected.contains(device.id),
                      "watchdog must un-gate capture WITHOUT clearing the selection intent")
    }

    /// A successful reconnect after wake disarms the watchdog: capture stays gated
    /// (Mac muted, streaming) and never un-gates.
    func testWakeWatchdogDisarmedOnReconnect() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:63", name: "Reconnect Speaker")
        await connectAP2(backend, engine, discovery, device)
        await pollUntil { capture.isCapturing }

        backend.setWakeAudioRestoreDelay(0.15)
        backend.handleSystemWillSleep()
        await pollUntil { !capture.isCapturing }
        backend.handleSystemDidWake()

        // The re-add succeeds (default engine), so capture returns and stays ON well
        // past the watchdog window.
        await pollUntil { capture.isCapturing }
        try? await Task.sleep(nanoseconds: 400_000_000)   // outlast the 0.15s watchdog
        XCTAssertTrue(capture.isCapturing,
                      "a successful reconnect must keep capture gated on (Mac muted), not un-gate")
    }

    /// Setting = Never (nil delay) arms no watchdog: even with no reconnect after
    /// wake, capture stays gated (the intent-keyed gate holds, un-muting deferred to
    /// the user).
    func testWakeWatchdogNeverArmsNothing() async {
        let (backend, engine, discovery) = makeBackend()
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:64", name: "Never Speaker")
        await connectAP2(backend, engine, discovery, device)
        await pollUntil { capture.isCapturing }

        backend.setWakeAudioRestoreDelay(nil)   // "Never"
        engine.addFailures = [device.outputID.rawValue]   // nothing reconnects

        backend.handleSystemWillSleep()
        await pollUntil { !capture.isCapturing }
        let stopsAfterSleep = capture.ops.filter { $0 == "stop" }.count
        backend.handleSystemDidWake()

        // No watchdog: the gate is driven only by suspend lifting. With intent still
        // set and suspend cleared, the gate wants ON again (even though the re-add
        // fails); it must NOT be un-gated by any watchdog. Give it time to (not) fire.
        try? await Task.sleep(nanoseconds: 300_000_000)
        // Intent intact, and no watchdog-driven extra stop beyond the sleep one.
        XCTAssertTrue(backend.test_expectedSelected.contains(device.id))
        XCTAssertEqual(capture.ops.filter { $0 == "stop" }.count, stopsAfterSleep,
                       "Never must arm no watchdog — no extra un-gate stop after wake")
    }

    // MARK: Helpers

    /// Records the gate's capture ops in order, with no Core Audio tap / TCC prompt.
    private final class FakeCapture: CaptureControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _onLevel: (@Sendable (Float) -> Void)?
        private var _ops: [String] = []
        private var _meteringActive = false

        var onLevel: (@Sendable (_ rms: Float) -> Void)? {
            get { lock.withLock { _onLevel } }
            set { lock.withLock { _onLevel = newValue } }
        }
        func start() { lock.withLock { _ops.append("start") } }
        func stop() { lock.withLock { _ops.append("stop") } }
        func setMeteringActive(_ active: Bool) { lock.withLock { _meteringActive = active } }

        /// Every start/stop, in the order they executed.
        var ops: [String] { lock.withLock { _ops } }
        /// Whether the tap is running right now — i.e. exactly when the real
        /// `.mutedWhenTapped` tap has the Mac's speakers muted.
        var isCapturing: Bool { lock.withLock { _ops.last == "start" } }
        /// The last value passed to `setMeteringActive`, `false` until called.
        var meteringActive: Bool { lock.withLock { _meteringActive } }
        /// Fire `onLevel` as the real coordinator would — but only if metering is
        /// active, mirroring `NativeCaptureCoordinator.handleBuffer`'s gate so this
        /// fake is a faithful stand-in for the T-GATE test below.
        func fireLevelIfActive(_ rms: Float) {
            let (handler, active) = lock.withLock { (_onLevel, _meteringActive) }
            if active { handler?(rms) }
        }
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

    /// T4b defensive guard: a per-app route that targets an AirPlay-1-only
    /// (RAOP) device must never reach the engine's `addOutput`/`removeOutput`
    /// — the UI already refuses to offer one as a destination
    /// (`PopoverController.availableAirPlayDestinations`), but if a stale/racing
    /// route table hands one down anyway, `NativeBackend` must refuse it rather
    /// than proceed into the `.bind`/`.rebind` path (a rebind re-anchors an AP1
    /// device's clock — no shared timing protocol with AP2 — drifting it out of
    /// sync with the rest of a group, and some classic receivers briefly reject
    /// the RTSP reconnect).
    func testAppRouteToAirPlay1OnlyDeviceIsRefused() async {
        let pids = PIDRecorder()
        let (backend, engine, discovery) = makeBackend(resolvePID: { pids.resolve($0) })
        defer { backend.stop() }
        let device = ap1Device()
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo.player", name: "Foo", toDevice: device.id)])

        // Give the async bind-tail a moment to run, then assert it never touched
        // the engine for this device — no bind, no rebind, no removeOutput.
        await pollUntil(timeout: 1) { pids.asked.contains("com.foo.player") }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(engine.streamAddCalls.filter { $0.0 == device.outputID }.isEmpty,
                     "an AirPlay-1-only device must never be bound to a per-app stream")
        XCTAssertFalse(engine.removedIDs.contains(device.outputID),
                       "an AirPlay-1-only device that was never bound should not be torn down either")
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
    func testAppTerminatedMidStreamRebindsDeviceToSurvivingSiblingsStream() async throws {
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
        // `.routedApps` is emitted on stateQueue but the engine bind runs later on
        // the bindTail FIFO, so the event alone doesn't imply the addOutput landed.
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }
        let firstStream = try XCTUnwrap(engine.streamAddCalls.first { $0.0 == device.outputID }).1

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
            engineControl: engine, discoverySource: discovery, dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: FakeSystemVolume(),
            resolvePID: { _ in 4242 }, injectedPerAppCapture: perAppCapture,
            processNotYetAudibleRetryDelay: 0.05, processNotYetAudibleMaxBackoff: 0.2)
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

    /// T2 fix: `.processNotYetAudible` retries INDEFINITELY (capped-exponential
    /// backoff), no longer giving up after the old hardcoded cap of 5 attempts
    /// (`processNotYetAudibleMaxRetries` was removed). Scripts 7 scripted
    /// failures (past the old cap) then a success on the 8th, proving the
    /// backend's own retry loop chases it down with no user action.
    func testProcessNotYetAudibleRetriesPastOldCapOfFiveAttempts() async {
        let tap = FlakyThenSucceedsTap(failuresBeforeSuccess: 7)
        let perAppCapture = PerAppCaptureCoordinator(
            makeTap: { tap }, resolvePID: { _ in 4242 }, muteBehavior: .mutedWhenTapped)
        let engine = SpyEngine()
        let discovery = FakeDiscovery()
        let backend = NativeBackend(
            engineControl: engine, discoverySource: discovery, dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: FakeSystemVolume(),
            resolvePID: { _ in 4242 }, injectedPerAppCapture: perAppCapture,
            processNotYetAudibleRetryDelay: 0.02, processNotYetAudibleMaxBackoff: 0.08)
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:85", name: "Unbounded Retry Speaker")
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])

        // 7 scripted failures + 1 success = at least 8 attempts — strictly past
        // the OLD hardcoded cap of 5, proving the retry is no longer bounded.
        await pollUntil(timeout: 5) { tap.attemptsMade >= 8 }
        XCTAssertGreaterThanOrEqual(tap.attemptsMade, 8,
                                    "retries must continue past the old cap of 5 attempts")

        await pollUntil(timeout: 5) { engine.streamAddCalls.contains { $0.0 == device.outputID } }
        XCTAssertTrue(engine.streamAddCalls.contains { $0.0 == device.outputID },
                      "the eventual success must still rejoin the live mixer topology")
    }

    /// T2 fix: retries must STOP once the route is dropped (bundle ID removed
    /// from `routedBundleIDs`) — a de-routed app must not be probed forever.
    /// Any retry already IN FLIGHT when the route is dropped is tolerated (it
    /// was scheduled before the drop), but no FURTHER retry may be scheduled.
    func testProcessNotYetAudibleRetriesStopOnDeRoute() async {
        // Never succeeds within the test window — every attempt fails.
        let tap = FlakyThenSucceedsTap(failuresBeforeSuccess: 10_000)
        let perAppCapture = PerAppCaptureCoordinator(
            makeTap: { tap }, resolvePID: { _ in 4242 }, muteBehavior: .mutedWhenTapped)
        let engine = SpyEngine()
        let discovery = FakeDiscovery()
        let backend = NativeBackend(
            engineControl: engine, discoverySource: discovery, dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: FakeSystemVolume(),
            resolvePID: { _ in 4242 }, injectedPerAppCapture: perAppCapture,
            processNotYetAudibleRetryDelay: 0.02, processNotYetAudibleMaxBackoff: 0.05)
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:86", name: "De-routed Retry Speaker")
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])

        // Let a couple of retries happen first.
        await pollUntil(timeout: 5) { tap.attemptsMade >= 2 }

        // De-route: drop the route entirely.
        backend.updateAppRoutes([])

        // Give any already-in-flight retry (scheduled before the drop) time to
        // land, then snapshot.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let afterDropSnapshot = tap.attemptsMade

        // Wait several more backoff periods — if retries were still scheduling,
        // this window (well past several 0.02-0.05s backoff cycles) would show
        // growth. It must NOT.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(tap.attemptsMade, afterDropSnapshot,
                       "no further retry may be scheduled once the route has been dropped")
    }

    /// A `ProcessAudioTap` that always succeeds and stores the
    /// `onDefaultDeviceChanged` closure it was handed, so a test can force a
    /// tap rebuild (`fireDeviceChange()`) at will — the per-app analogue of
    /// `PerAppCaptureCoordinatorTests.FakeProcessTap`, needed here to drive
    /// `NativeBackend`'s T4 rebind-recovery path (a rebuild with no death in
    /// between is a "recapture", which triggers `resetAirPlaySessionForRoutedApp`).
    private final class RebindTriggerTap: ProcessAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        func createAndStart(pid: pid_t, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        }
        func teardown() {}
        func fireDeviceChange() { onDefaultDeviceChanged?() }
    }

    /// T4 fix: `resetAirPlaySessionForRoutedApp`'s bounded rebind recovery
    /// (`enqueueRebindRecovery`/`performRebindRecovery`) retries a failing
    /// `addOutput` with backoff and eventually re-binds once the engine starts
    /// succeeding again — all within `maxRebindRecoveryAttempts`.
    func testRebindRecoveryRetriesThenSucceedsWithinBoundedAttempts() async {
        let tap = RebindTriggerTap()
        let perAppCapture = PerAppCaptureCoordinator(
            makeTap: { tap }, resolvePID: { _ in 4242 }, muteBehavior: .mutedWhenTapped)
        let engine = SpyEngine()
        let discovery = FakeDiscovery()
        let backend = NativeBackend(
            engineControl: engine, discoverySource: discovery, dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: FakeSystemVolume(),
            resolvePID: { _ in 4242 }, injectedPerAppCapture: perAppCapture,
            maxRebindRecoveryAttempts: 3, rebindRecoveryRetryDelay: 0.02)
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:87", name: "Rebind Recovery Speaker")
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }
        let firstBindCount = engine.streamAddCalls.filter { $0.0 == device.outputID }.count

        // Every addOutput for this device fails until we flip it back off —
        // simulating a receiver that's rejecting the rebind at first.
        engine.addFailures = [device.outputID.rawValue]

        // A tap rebuild with no death in between is a "recapture" — this drives
        // resetAirPlaySessionForRoutedApp -> enqueueRebindRecovery(attempt: 1).
        tap.fireDeviceChange()

        // Attempt 1 is recorded (and fails, since addFailures is still set).
        await pollUntil(timeout: 5) {
            engine.streamAddCalls.filter { $0.0 == device.outputID }.count > firstBindCount
        }

        // Let it succeed on the next attempt.
        engine.addFailures = []

        // Attempt 2 (or later, bounded by maxRebindRecoveryAttempts=3) succeeds.
        await pollUntil(timeout: 5) {
            engine.streamAddCalls.filter { $0.0 == device.outputID }.count > firstBindCount + 1
        }
        let finalCount = engine.streamAddCalls.filter { $0.0 == device.outputID }.count
        XCTAssertGreaterThan(finalCount, firstBindCount + 1,
                             "rebind recovery must retry the failing addOutput and eventually re-bind")
        XCTAssertLessThanOrEqual(finalCount, firstBindCount + 3,
                                 "recovery must stay within maxRebindRecoveryAttempts, not retry forever")
    }

    /// T4 fix: rebind recovery gives up LOUDLY (and stops retrying) once
    /// `maxRebindRecoveryAttempts` is exhausted — it must not thrash the engine
    /// with unbounded removeOutput/addOutput pairs against a receiver that's
    /// genuinely gone.
    func testRebindRecoveryGivesUpAfterMaxAttempts() async {
        let tap = RebindTriggerTap()
        let perAppCapture = PerAppCaptureCoordinator(
            makeTap: { tap }, resolvePID: { _ in 4242 }, muteBehavior: .mutedWhenTapped)
        let engine = SpyEngine()
        let discovery = FakeDiscovery()
        let backend = NativeBackend(
            engineControl: engine, discoverySource: discovery, dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: FakeSystemVolume(),
            resolvePID: { _ in 4242 }, injectedPerAppCapture: perAppCapture,
            maxRebindRecoveryAttempts: 2, rebindRecoveryRetryDelay: 0.02)
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:88", name: "Gone Receiver")
        await startAndDiscover(backend, engine, discovery, device)

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }
        let firstBindCount = engine.streamAddCalls.filter { $0.0 == device.outputID }.count

        // Every addOutput for this device fails, PERMANENTLY — the receiver is
        // genuinely gone.
        engine.addFailures = [device.outputID.rawValue]
        tap.fireDeviceChange()

        // Both bounded attempts (2) get recorded (and fail).
        await pollUntil(timeout: 5) {
            engine.streamAddCalls.filter { $0.0 == device.outputID }.count >= firstBindCount + 2
        }
        let countAtCeiling = engine.streamAddCalls.filter { $0.0 == device.outputID }.count
        XCTAssertEqual(countAtCeiling, firstBindCount + 2,
                       "exactly maxRebindRecoveryAttempts (2) rebind attempts must be made")

        // Wait several more backoff periods — recovery must have given up, so
        // no further addOutput attempts for this device should appear.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.streamAddCalls.filter { $0.0 == device.outputID }.count, countAtCeiling,
                       "recovery must give up after maxRebindRecoveryAttempts, not retry forever")
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
        var onAppLevel: (@Sendable (_ bundleID: String, _ rms: Float) -> Void)?
        private var _meteringActive = false
        func setMeteringActive(_ active: Bool) { lock.withLock { _meteringActive = active } }
        var meteringActive: Bool { lock.withLock { _meteringActive } }

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

    // MARK: - Metering: three real level sources (T3)

    /// Records `.level`/`.appLevel` events (the two the other `collect` helpers
    /// deliberately skip) with sync accessors so `pollUntil` can inspect them.
    private final class LevelSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _device: [(id: String, rms: Float)] = []
        private var _app: [(bundleID: String, rms: Float)] = []
        func record(_ e: BackendEvent) {
            switch e {
            case .level(let id, let rms): lock.withLock { _device.append((id, rms)) }
            case .appLevel(let b, let rms): lock.withLock { _app.append((b, rms)) }
            default: break
            }
        }
        /// The most recent `.level` for `id`, or nil if none seen.
        func lastDeviceLevel(_ id: String) -> Float? { lock.withLock { _device.last { $0.id == id }?.rms } }
        /// Whether any `.appLevel` has been seen for `bundleID`.
        func hasAppLevel(_ bundleID: String) -> Bool { lock.withLock { _app.contains { $0.bundleID == bundleID } } }
        /// The most recent `.appLevel` for `bundleID`, or nil.
        func lastAppLevel(_ bundleID: String) -> Float? { lock.withLock { _app.last { $0.bundleID == bundleID }?.rms } }
    }

    /// Subscribe and record every `.level`/`.appLevel`. Caller cancels the task.
    private func subscribeLevels(_ backend: NativeBackend) -> (LevelSink, Task<Void, Never>) {
        let sink = LevelSink()
        let stream = backend.makeEventStream()
        let task = Task { for await event in stream { sink.record(event) } }
        return (sink, task)
    }

    /// A per-app capture over `BundleTaggingTap`s that self-register so a test can
    /// push content into a specific bundle's tap — same shape the cross-stream
    /// leakage test uses, factored out for the metering tests.
    private func registeringPerAppCapture(
        muteBehavior: TapMuteBehavior, into registry: TapRegistry
    ) -> PerAppCaptureCoordinator {
        PerAppCaptureCoordinator(
            makeTap: {
                let tap = BundleTaggingTap()
                tap.onRegister = { bundleID in registry.register(bundleID, tap) }
                return tap
            },
            resolvePID: { _ in 4242 },
            muteBehavior: muteBehavior)
    }

    /// A CapturedBuffer whose RAW bytes are Float32 samples all equal to
    /// `amplitude` — so `NativeCaptureCoordinator.rmsOfFloat32` (the metering-only
    /// source's RMS) yields exactly `amplitude`. Used to drive `meteringCapture`
    /// deterministically (its RMS reads Float32, unlike the S16 stream path).
    private func float32Buffer(amplitude: Float, frames: Int, atSecond sec: Int) -> CapturedBuffer {
        let samples = [Float32](repeating: amplitude, count: frames * 2 /* stereo */)
        let data = samples.withUnsafeBytes { Data($0) }
        return CapturedBuffer(channelData: [data], frameCount: frames, pts: timespec(tv_sec: sec, tv_nsec: 0))
    }

    /// T3: a device that is ONLY a per-app redirect target (never a Selected
    /// Device, so `isSelected == false`) still gets a `.level` — driven by the RMS
    /// of the per-app stream bound to it. Pre-T3 the sole `.level` source was the
    /// whole-system tap fanned to selected devices, so a redirect-only device's
    /// meter was permanently dead; now `onMixedBuffer` → `emitStreamLevel` feeds it.
    func testRedirectOnlyDeviceReceivesLevelFromItsStream() async {
        let registry = TapRegistry()
        let perAppCapture = registeringPerAppCapture(muteBehavior: .mutedWhenTapped, into: registry)
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: perAppCapture)
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:81", name: "Redirect Only")
        await startAndDiscover(backend, engine, discovery, device)

        backend.setMeteringActive(true)
        let (sink, task) = subscribeLevels(backend); defer { task.cancel() }
        try? await Task.sleep(nanoseconds: 20_000_000)   // let the subscription register

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }
        await pollUntil {
            if case .capturing = perAppCapture.state(for: "com.foo") { return true }; return false
        }
        guard let tap = registry.tap(for: "com.foo") else {
            return XCTFail("the routed app's per-app tap must have registered")
        }

        // Precondition: the redirect target is NOT a Selected Device.
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.isSelected, false,
                       "a redirect target must not be in the output set (AGENTS.md)")

        tap.push(fingerprintedBuffer(fill: 0xAA, frames: 1000, atSecond: 1))

        await pollUntil { (sink.lastDeviceLevel(device.id) ?? 0) > 0 }
        XCTAssertGreaterThan(sink.lastDeviceLevel(device.id) ?? 0, 0,
                             "a redirect-only device must receive a .level from its per-app stream")
    }

    /// T3: a device fed by BOTH the whole-system mix (it's a Selected Device) AND a
    /// per-app stream (it's also a redirect target) reports the MAX of the two
    /// contributions — the documented product decision. Proven in both directions:
    /// system-high beats a present stream, and when the system drops the stream
    /// drives the meter.
    func testDeviceFedBySystemAndStreamReportsMax() async {
        let registry = TapRegistry()
        let perAppCapture = registeringPerAppCapture(muteBehavior: .mutedWhenTapped, into: registry)
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: perAppCapture)
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        defer { backend.stop() }

        let device = ap2Device(id: "AA:BB:CC:DD:EE:82", name: "Both Sources")
        await startAndDiscover(backend, engine, discovery, device)

        // Make it a Selected Device (system contribution) …
        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }
        backend.setMeteringActive(true)
        await pollUntil { capture.meteringActive }

        // … AND a per-app redirect target (stream contribution).
        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }
        let stream = engine.streamAddCalls.first { $0.0 == device.outputID }!.1
        await pollUntil {
            if case .capturing = perAppCapture.state(for: "com.foo") { return true }; return false
        }
        guard let tap = registry.tap(for: "com.foo") else {
            return XCTFail("the routed app's per-app tap must have registered")
        }

        let (sink, task) = subscribeLevels(backend); defer { task.cancel() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Phase A — system HIGH (0.95) over a present stream (0xAA ≈ 0.667):
        // the device level is the system value (the max), and the stream RMS is
        // now cached (a write reached the engine).
        capture.fireLevelIfActive(0.95)
        tap.push(fingerprintedBuffer(fill: 0xAA, frames: 1000, atSecond: 1))
        await pollUntil { engine.rawWriteCalls.contains { $0.streamId == stream } }
        await pollUntil { (sink.lastDeviceLevel(device.id) ?? 0) > 0.9 }
        XCTAssertGreaterThan(sink.lastDeviceLevel(device.id) ?? 0, 0.9,
                             "system 0.95 must win over the ~0.667 stream (MAX)")

        // Phase B — system drops to 0: the cached stream RMS now drives the meter,
        // proving the MAX flips to the stream side rather than sticking at 0.95.
        capture.fireLevelIfActive(0.0)
        await pollUntil {
            let l = sink.lastDeviceLevel(device.id) ?? 0
            return l > 0.4 && l < 0.9
        }
        let settled = sink.lastDeviceLevel(device.id) ?? 0
        XCTAssertTrue(settled > 0.4 && settled < 0.9,
                      "with system at 0 the stream (~0.667) must drive the level — MAX(0, stream)")
    }

    /// T3: unbinding a device's per-app stream (a destination-set change) emits a
    /// FINAL combined `.level` for it — dropping to its system contribution, here 0
    /// because it's unselected — so a torn-down stream can't leave a stuck meter.
    func testUnbindingStreamZeroesDeviceLevel() async {
        let registry = TapRegistry()
        let perAppCapture = registeringPerAppCapture(muteBehavior: .mutedWhenTapped, into: registry)
        let (backend, engine, discovery) = makeBackend(injectedPerAppCapture: perAppCapture)
        defer { backend.stop() }
        let device = ap2Device(id: "AA:BB:CC:DD:EE:83", name: "Unbind Target")
        await startAndDiscover(backend, engine, discovery, device)

        backend.setMeteringActive(true)
        let (sink, task) = subscribeLevels(backend); defer { task.cancel() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: device.id)])
        await pollUntil { engine.streamAddCalls.contains { $0.0 == device.outputID } }
        await pollUntil {
            if case .capturing = perAppCapture.state(for: "com.foo") { return true }; return false
        }
        guard let tap = registry.tap(for: "com.foo") else {
            return XCTFail("the routed app's per-app tap must have registered")
        }
        tap.push(fingerprintedBuffer(fill: 0xAA, frames: 1000, atSecond: 1))
        await pollUntil { (sink.lastDeviceLevel(device.id) ?? 0) > 0 }

        // Fully de-route the app: the device unbinds its stream.
        backend.updateAppRoutes([])
        await pollUntil { engine.removedIDs.contains(device.outputID) }

        // The device's meter must settle back to 0 (no stream, not selected).
        await pollUntil { sink.lastDeviceLevel(device.id) == 0 }
        XCTAssertEqual(sink.lastDeviceLevel(device.id), 0,
                       "a torn-down stream must emit a final .level of 0, not leave a stuck bar")
    }

    /// T3: `.appLevel` for a `.noRedirect` LISTED app comes from a dedicated
    /// metering-only tap that is started ONLY while metering is active. Nothing is
    /// captured (and no `.appLevel` fires) while metering is off; turning it on
    /// starts the tap and the app's raw RMS flows as `.appLevel`.
    func testNoRedirectAppLevelOnlyWhileMeteringActive() async {
        let registry = TapRegistry()
        let metering = registeringPerAppCapture(muteBehavior: .unmuted, into: registry)
        let (backend, engine, discovery) = makeBackend(injectedMeteringCapture: metering)
        defer { backend.stop() }
        backend.start(); await waitUntilStarted(engine)
        _ = discovery

        let (sink, task) = subscribeLevels(backend); defer { task.cancel() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Listed but metering INACTIVE: no metering-only tap, no .appLevel.
        backend.updateAppRoutes([AppRoute(bundleID: "com.plain", displayName: "Plain")])
        try? await Task.sleep(nanoseconds: 60_000_000)
        if case .idle = metering.state(for: "com.plain") {} else {
            XCTFail("no metering-only tap may start while metering is inactive")
        }
        XCTAssertNil(registry.tap(for: "com.plain"), "no tap should exist for com.plain yet")
        XCTAssertFalse(sink.hasAppLevel("com.plain"), "no .appLevel may fire while metering is inactive")

        // Turn metering on: its metering-only tap starts and reaches capturing.
        backend.setMeteringActive(true)
        await pollUntil {
            if case .capturing = metering.state(for: "com.plain") { return true }; return false
        }
        guard let tap = registry.tap(for: "com.plain") else {
            return XCTFail("the metering-only tap must register once metering is active")
        }
        tap.push(float32Buffer(amplitude: 0.5, frames: 512, atSecond: 1))

        await pollUntil { sink.hasAppLevel("com.plain") }
        XCTAssertGreaterThan(sink.lastAppLevel("com.plain") ?? 0, 0,
                             "a .noRedirect listed app must emit .appLevel from its metering-only tap")
    }

    /// T3 PRIVACY: a user-EXCLUDED app is NEVER metered — no metering-only tap is
    /// started and no `.appLevel` fires for it — even while it is a listed
    /// `.noRedirect` app and metering is active. A non-excluded sibling proves
    /// metering is otherwise working, and excluding an app that WAS being metered
    /// stops its tap immediately.
    func testExcludedAppIsNeverMetered() async {
        let registry = TapRegistry()
        let metering = registeringPerAppCapture(muteBehavior: .unmuted, into: registry)
        let (backend, engine, discovery) = makeBackend(injectedMeteringCapture: metering)
        defer { backend.stop() }
        backend.start(); await waitUntilStarted(engine)
        _ = discovery

        let (sink, task) = subscribeLevels(backend); defer { task.cancel() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        backend.setMeteringActive(true)
        backend.updateAppRoutes(
            [AppRoute(bundleID: "com.ok", displayName: "OK"),
             AppRoute(bundleID: "com.secret", displayName: "Secret")],
            excludedBundleIDs: ["com.secret"])

        // The non-excluded app IS metered …
        await pollUntil {
            if case .capturing = metering.state(for: "com.ok") { return true }; return false
        }
        // … the excluded app is NEVER even started.
        if case .idle = metering.state(for: "com.secret") {} else {
            XCTFail("an excluded app must never have a metering-only tap started")
        }
        XCTAssertNil(registry.tap(for: "com.secret"), "no tap may be created for an excluded app")

        // Push into the non-excluded app; assert its .appLevel fires and the
        // excluded app's never does.
        registry.tap(for: "com.ok")?.push(float32Buffer(amplitude: 0.5, frames: 512, atSecond: 1))
        await pollUntil { sink.hasAppLevel("com.ok") }
        XCTAssertFalse(sink.hasAppLevel("com.secret"),
                       "PRIVACY: an excluded app must never emit .appLevel")

        // Excluding the app that WAS being metered stops its tap immediately.
        backend.updateAppRoutes(
            [AppRoute(bundleID: "com.ok", displayName: "OK"),
             AppRoute(bundleID: "com.secret", displayName: "Secret")],
            excludedBundleIDs: ["com.ok", "com.secret"])
        await pollUntil {
            if case .idle = metering.state(for: "com.ok") { return true }; return false
        }
    }

    /// T3: turning metering OFF stops every metering-only tap (teardown discipline
    /// — a closed popover has nobody to render the app meter for).
    func testMeteringOnlyTapsStopWhenMeteringDeactivated() async {
        let registry = TapRegistry()
        let metering = registeringPerAppCapture(muteBehavior: .unmuted, into: registry)
        let (backend, engine, discovery) = makeBackend(injectedMeteringCapture: metering)
        defer { backend.stop() }
        backend.start(); await waitUntilStarted(engine)
        _ = discovery

        backend.setMeteringActive(true)
        backend.updateAppRoutes([AppRoute(bundleID: "com.plain", displayName: "Plain")])
        await pollUntil {
            if case .capturing = metering.state(for: "com.plain") { return true }; return false
        }

        backend.setMeteringActive(false)
        await pollUntil {
            if case .idle = metering.state(for: "com.plain") { return true }; return false
        }
        if case .idle = metering.state(for: "com.plain") {} else {
            XCTFail("metering-only taps must stop when metering is deactivated")
        }
    }

    private func pollUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Remote-control stream (speaker transport keys + the speaker's own volume)

    /// The speaker changing its OWN volume moves that one device's slider: a
    /// `RemoteEvent.volume(level: 0.5)` becomes a `deviceUpdated` with volume 50
    /// for that id (0.0…1.0 → 0…100).
    func testSpeakerVolumeMovesThatDeviceSlider() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        // Discover the device first so the id↔OutputID mapping exists.
        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // 0.8 → 80, deliberately different from a discovered device's default 50
        // (mapDiscovered) so the change actually emits rather than being de-duped.
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == device.id && d.volume == 80 } else { return false } }
        } after: { engine.pushRemoteEvent(.volume(device.outputID, level: 0.8)) }

        let updated = events.compactMap { event -> Device? in
            if case .deviceUpdated(let d) = event, d.id == device.id { return d } else { return nil }
        }
        XCTAssertEqual(updated.last?.volume, 80, "the speaker's knob should move its slider to 80")
    }

    /// A volume report for an OutputID the backend never mapped is dropped — it
    /// must not fabricate a device or crash. We prove it by confirming a LATER
    /// event for a real device still flows (the stream wasn't wedged) and no
    /// deviceUpdated arrived for the bogus id.
    func testSpeakerVolumeForUnknownOutputIsIgnored() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        let bogus = OutputID(rawValue: 0xDEADBEEF)
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: {
            engine.pushRemoteEvent(.volume(bogus, level: 0.9)) // dropped
            discovery.fire(.appeared(device))                  // still flows
        }

        XCTAssertFalse(
            events.contains { if case .deviceUpdated = $0 { return true } else { return false } },
            "an unknown-output volume must not produce any deviceUpdated"
        )
    }

    /// Each transport key pressed on the speaker surfaces the matching
    /// device-agnostic `remoteTransport` backend event (play/pause/next/previous).
    func testSpeakerTransportKeysEmitRemoteTransport() async {
        let (backend, engine, _) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        @Sendable func sawTransport(_ events: [BackendEvent], _ command: RemoteTransportCommand) -> Bool {
            events.contains { if case .remoteTransport(let c) = $0 { return c == command } else { return false } }
        }

        let events = await collect(from: backend) { events in
            sawTransport(events, .playPause) && sawTransport(events, .next) && sawTransport(events, .previous)
        } after: {
            engine.pushRemoteEvent(.transport(.playPause))
            engine.pushRemoteEvent(.transport(.next))
            engine.pushRemoteEvent(.transport(.previous))
        }

        XCTAssertTrue(sawTransport(events, .playPause))
        XCTAssertTrue(sawTransport(events, .next))
        XCTAssertTrue(sawTransport(events, .previous))
    }

    // MARK: DACP volume routing (a volume change made ON THE SPEAKER)

    /// A DACP volume report whose Active-Remote token matches a device's id (low
    /// 32 bits) moves that device's slider.
    func testDacpVolumeMovesMatchingDeviceSlider() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Active-Remote is the low 32 bits of the device id (airplay.c). 0.8 → 80,
        // deliberately != the discovered default of 50 so the change actually emits.
        let token = UInt32(truncatingIfNeeded: device.outputID.rawValue)
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == device.id && d.volume == 80 } else { return false } }
        } after: { backend.applyDacpVolume(activeRemote: token, level: 0.8) }

        let updated = events.compactMap { event -> Device? in
            if case .deviceUpdated(let d) = event, d.id == device.id { return d } else { return nil }
        }
        XCTAssertEqual(updated.last?.volume, 80, "a DACP volume for this speaker's token moves its slider")
    }

    /// A DACP volume for a token that matches no known device is dropped (no
    /// deviceUpdated), while a real device still flows — the stream isn't wedged.
    func testDacpVolumeForUnknownTokenIsIgnored() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: {
            backend.applyDacpVolume(activeRemote: 0xDEADBEEF, level: 0.9) // no such token
            discovery.fire(.appeared(device))
        }
        XCTAssertFalse(
            events.contains { if case .deviceUpdated = $0 { return true } else { return false } },
            "an unknown DACP token must not move any slider"
        )
    }

    /// Poll the spy until a `setVolume(outputID, value)` call lands (the push is
    /// fire-and-forget through a Task, so it's not synchronous with the apply).
    private func waitForVolumePush(
        _ engine: SpyEngine, _ outputID: OutputID, _ value: Double, timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.volumeCalls.contains(where: { $0.0 == outputID && abs($0.1 - value) < 0.001 }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// Closing the loop: a speaker-requested volume must be written BACK out to
    /// the engine (→ SET_PARAMETER to the receiver), not just move our slider.
    /// The sender owns AirPlay volume — without the write-back the speaker's own
    /// baseline never advances, which is exactly the first-live-test bug (a full
    /// swipe moved a few points and every new swipe re-based on the stale level).
    func testDacpVolumeIsPushedBackToTheEngine() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        let token = UInt32(truncatingIfNeeded: device.outputID.rawValue)
        backend.applyDacpVolume(activeRemote: token, level: 0.8)

        let pushed = await waitForVolumePush(engine, device.outputID, 0.8)
        XCTAssertTrue(pushed, "a speaker-requested volume must be pushed back to the engine so the speaker actually changes level")
    }

    /// A receiver reflecting our own write back (a value equal to what the slider
    /// already holds) must NOT trigger another push — that would ping-pong
    /// forever. The same-value guard in `setSpeakerVolume` breaks the cycle.
    func testDacpVolumeEchoOfCurrentValueDoesNotRePush() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        let token = UInt32(truncatingIfNeeded: device.outputID.rawValue)
        backend.applyDacpVolume(activeRemote: token, level: 0.8)
        _ = await waitForVolumePush(engine, device.outputID, 0.8)
        let countAfterFirst = engine.volumeCalls.count

        // The "echo": same level again. Give any (wrong) push time to land.
        backend.applyDacpVolume(activeRemote: token, level: 0.8)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.volumeCalls.count, countAfterFirst,
                       "an echo of the current value must not push again (feedback loop)")
    }

    /// Relative `volumeup`/`volumedown` verbs step from the level the app
    /// CURRENTLY holds, so consecutive presses accumulate instead of re-basing:
    /// 50 → 52 → 54 → 52 with the ±2-point step.
    func testDacpVolumeStepsAccumulate() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        let token = UInt32(truncatingIfNeeded: device.outputID.rawValue)
        let step = NativeBackend.speakerVolumeStep
        let deviceID = device.id
        let volumesOf: @Sendable ([BackendEvent]) -> [Int] = { events in
            events.compactMap { event -> Int? in
                if case .deviceUpdated(let d) = event, d.id == deviceID { return d.volume } else { return nil }
            }
        }
        let events = await collect(from: backend) { events in
            volumesOf(events).count >= 3
        } after: {
            backend.applyDacpVolumeStep(activeRemote: token, direction: 1)
            backend.applyDacpVolumeStep(activeRemote: token, direction: 1)
            backend.applyDacpVolumeStep(activeRemote: token, direction: -1)
        }

        let volumes = volumesOf(events)
        XCTAssertEqual(volumes, [50 + step, 50 + 2 * step, 50 + step],
                       "steps must accumulate from the current level, up then back down")
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
