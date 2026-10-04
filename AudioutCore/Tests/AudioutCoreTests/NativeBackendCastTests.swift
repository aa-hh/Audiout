import Foundation
import Testing
import AirPlayEngine
import CastSender
import Network
@testable import AudioutCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// CAST-OUT / CAST-ENUM wiring: `NativeBackend` folds Cast browse records into
/// the SAME `known`/`order`/`emit` flow AirPlay and Bluetooth rows use, and
/// drives the Cast session manager as the THIRD routing partition — no
/// `outputIDs` entry, never the engine. Hermetic: injected
/// ``CastDeviceEnumerating`` and ``CastOutputControlling`` fakes stand in for
/// the real browse and the real sockets, and every other collaborator is the
/// same no-op double the sibling backend suites keep.
@Suite final class NativeBackendCastTests: IsolatedSuite {

    // MARK: Doubles

    private final class FakeCastEnumerator: CastDeviceEnumerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _onSnapshot: (@Sendable ([CastDeviceRecord]) -> Void)?
        private var _startCount = 0
        private var _stopCount = 0

        var onSnapshot: (@Sendable ([CastDeviceRecord]) -> Void)? {
            get { lock.withLock { _onSnapshot } }
            set { lock.withLock { _onSnapshot = newValue } }
        }
        var startCount: Int { lock.withLock { _startCount } }
        var stopCount: Int { lock.withLock { _stopCount } }

        func start() { lock.withLock { _startCount += 1 } }
        func stop() { lock.withLock { _stopCount += 1 } }
        func fire(_ records: [CastDeviceRecord]) { onSnapshot?(records) }
    }

    /// The fan-out slot's stand-in: the backend only ever hands this to the
    /// capture coordinator, so it never has to do anything.
    private final class NullSink: PCMSink, @unchecked Sendable {
        func write(pcm: Data, pts: timespec) {}
    }

    private final class FakeCastOutputManager: CastOutputControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _onStateChange: (@Sendable (String, CastSessionState) -> Void)?
        private var _onVolumeLagChange: (@Sendable (String, Int?) -> Void)?
        private var _onLeadSample: (@Sendable (String, Int) -> Void)?
        private var _deviceSets: [[CastDeviceRecord]] = []
        private var _sourceSets: [[String: CastFeedSource]] = []
        private var _perAppWrites: [(id: String, bytes: Int, fills: Set<UInt8>)] = []
        private var _levels: [(level: Double, id: String)] = []
        private var _retries: [String] = []
        private var _stopAllCount = 0

        let feed: PCMSink = NullSink()

        var onStateChange: (@Sendable (String, CastSessionState) -> Void)? {
            get { lock.withLock { _onStateChange } }
            set { lock.withLock { _onStateChange = newValue } }
        }
        var onVolumeLagChange: (@Sendable (String, Int?) -> Void)? {
            get { lock.withLock { _onVolumeLagChange } }
            set { lock.withLock { _onVolumeLagChange = newValue } }
        }
        var onLeadSample: (@Sendable (String, Int) -> Void)? {
            get { lock.withLock { _onLeadSample } }
            set { lock.withLock { _onLeadSample = newValue } }
        }
        var deviceSets: [[CastDeviceRecord]] { lock.withLock { _deviceSets } }
        /// The ownership handed over with each ``deviceSets`` entry, in step.
        var sourceSets: [[String: CastFeedSource]] { lock.withLock { _sourceSets } }
        /// Every per-app block, by device id, byte count and the distinct byte
        /// values it carried (an app's fingerprint fill).
        var perAppWrites: [(id: String, bytes: Int, fills: Set<UInt8>)] { lock.withLock { _perAppWrites } }
        var levels: [(level: Double, id: String)] { lock.withLock { _levels } }
        var retries: [String] { lock.withLock { _retries } }
        var stopAllCount: Int { lock.withLock { _stopAllCount } }
        /// CAST-SYNC: every by-ear offset written onto the live feed, in order.
        var castUserOffsets: [(ms: Int, id: String)] { lock.withLock { _castUserOffsets } }
        private var _castUserOffsets: [(ms: Int, id: String)] = []

        func setDevices(_ records: [CastDeviceRecord], sources: [String: CastFeedSource]) {
            lock.withLock {
                _deviceSets.append(records)
                _sourceSets.append(sources)
            }
        }
        func writePerApp(pcm: Data, toDevice id: String) {
            lock.withLock { _perAppWrites.append((id, pcm.count, Set(pcm))) }
        }
        func setLevel(_ level: Double, forDevice id: String) { lock.withLock { _levels.append((level, id)) } }
        func setCastUserOffsetMs(_ ms: Int, forDeviceID id: String) {
            lock.withLock { _castUserOffsets.append((ms, id)) }
        }
        func retry(deviceID: String) { lock.withLock { _retries.append(deviceID) } }
        func stopAll() { lock.withLock { _stopAllCount += 1 } }

        func fire(id: String, state: CastSessionState) {
            let handler = lock.withLock { _onStateChange }
            handler?(id, state)
        }

        func fireLag(id: String, lag: Int?) {
            let handler = lock.withLock { _onVolumeLagChange }
            handler?(id, lag)
        }

        /// CAST-SYNC: `count` believed lead measurements, as the real manager
        /// delivers them — one a second, already gated on PLAYING and on a
        /// round trip fast enough to trust.
        func fireLead(id: String, leadMs: Int, count: Int = 1) {
            let handler = lock.withLock { _onLeadSample }
            for _ in 0..<count { handler?(id, leadMs) }
        }
    }

    /// Records the Cast fan-out attaches/detaches; every other capture op is a
    /// no-op, exactly like `NativeBackendTests`' own `FakeCapture`.
    private final class FakeCapture: CaptureControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _onLevel: (@Sendable (Float) -> Void)?
        private var _onStateChange: (@Sendable (NativeCaptureCoordinator.State) -> Void)?
        private var _castSinkCalls: [(isNil: Bool, pid: pid_t?)] = []
        private var _preDelayMs: [Int] = []

        var onLevel: (@Sendable (_ rms: Float) -> Void)? {
            get { lock.withLock { _onLevel } }
            set { lock.withLock { _onLevel = newValue } }
        }
        var onStateChange: (@Sendable (NativeCaptureCoordinator.State) -> Void)? {
            get { lock.withLock { _onStateChange } }
            set { lock.withLock { _onStateChange = newValue } }
        }
        var castSinkCalls: [(isNil: Bool, pid: pid_t?)] { lock.withLock { _castSinkCalls } }
        /// CAST-SYNC: every AirPlay pre-delay the backend published, in order.
        var preDelayMs: [Int] { lock.withLock { _preDelayMs } }

        func start() {}
        func stop() {}
        func setCastSink(_ sink: PCMSink?, renderProcessPID: pid_t?) {
            lock.withLock { _castSinkCalls.append((sink == nil, renderProcessPID)) }
        }
        func setAirPlayPreDelay(ms: Int) {
            lock.withLock { _preDelayMs.append(ms) }
        }
    }

    /// Counts the two engine calls a Cast-only per-app stream must never make.
    private final class NoOpEngine: EngineControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _writes = 0
        private var _streamAdds = 0
        var writes: Int { lock.withLock { _writes } }
        var streamAdds: Int { lock.withLock { _streamAdds } }

        func start() async throws {}
        func stop() async {}
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            OutputID(rawValue: 0)
        }
        func removeDiscovery(_ descriptor: DeviceDescriptor) async {}
        func addOutput(_ id: OutputID) async throws {}
        func addOutput(_ id: OutputID, streamId: UInt32) async throws {
            lock.withLock { _streamAdds += 1 }
        }
        func removeOutput(_ id: OutputID) async throws {}
        func setVolume(_ id: OutputID, _ volume: Double) async throws {}
        func setStartBufferMs(_ ms: Int) async {}
        func write(pcm: Data, streamId: UInt32, pts: timespec) {
            lock.withLock { _writes += 1 }
        }
        func makeStateStream() -> AsyncStream<(OutputID, OutputState)> { AsyncStream { _ in } }
        func makeRemoteEventStream() -> AsyncStream<RemoteEvent> { AsyncStream { _ in } }
        var dacpID: UInt64 { 0 }
        var ptpClockAvailable: Bool { get async { true } }
    }

    private final class NoOpDiscovery: DiscoverySource, @unchecked Sendable {
        var onEvent: (@Sendable (DiscoveryEvent) -> Void)?
        func start() {}
        func stop() {}
        func fire(_ event: DiscoveryEvent) { onEvent?(event) }
    }

    /// One AirPlay 2 speaker, for the CAST-SYNC tests: the room delay only
    /// reaches the AirPlay feed when there is an AirPlay session to feed.
    private static func ap2Device(id: String = "AA:BB:CC:DD:EE:01",
                                  name: String = "Sonos Move") -> DiscoveredDevice {
        let txt = ["deviceid": id, "model": "S13", "features": "0x445F8A00,0x1C340"]
        let (parsedID, outputID) = NativeDiscovery.parseDeviceID(txt)!
        let desc = DeviceDescriptor(
            name: name, address: "192.168.1.10", family: .ipv4, port: 7000, txtRecord: txt)
        return DiscoveredDevice(
            id: parsedID, descriptor: desc, outputID: outputID, isAirPlay2Supported: true)
    }

    /// No sockets: the real `DACPServer.start(dacpID:)` binds a live
    /// `NWListener` (Local Network prompt).
    private final class FakeDACPEndpoint: DACPEndpoint, @unchecked Sendable {
        var onVolume: (@Sendable (_ activeRemote: UInt32, _ level: Double) -> Void)?
        var onVolumeStep: (@Sendable (_ activeRemote: UInt32, _ direction: Int) -> Void)?
        func start(dacpID: UInt64) {}
        func stop() {}
    }

    private final class NoOpSystemVolume: SystemVolumeControlling, @unchecked Sendable {
        var onExternalChange: (@Sendable (Int?, Bool?, Bool) -> Void)?
        func currentVolume() -> Int? { nil }
        func currentMuted() -> Bool? { nil }
        func setVolume(_ volume: Int, didWrite: (@Sendable (Bool) -> Void)?) { didWrite?(true) }
        func setMuted(_ muted: Bool) {}
        // Target-resolving pair: the resolver is CALLED (a test can observe what
        // was resolved) and the outcome then matches the plain writes above.
        func setVolume(_ volume: Int, resolvingTarget: @escaping @Sendable () -> AudioObjectID?,
                       didWrite: (@Sendable (Bool) -> Void)?) {
            _ = resolvingTarget()
            didWrite?(true)
        }
        func setMuted(_ muted: Bool, resolvingTarget: @escaping @Sendable () -> AudioObjectID?) {
            _ = resolvingTarget()
        }
        func start() {}
        func stop() {}
    }

    /// Never touches the real HAL — `stop()` sweeps aggregates unconditionally.
    private struct NoOpAggregateControl: AggregateDeviceControlling {
        func resolveDeviceID(forUID uid: String) -> AudioObjectID? { nil }
        func createAggregate(uid: String, name: String, subDeviceUID: String) -> AudioObjectID? { nil }
        func destroyAggregate(_ deviceID: AudioObjectID) -> Bool { false }
        func aggregateDeviceUIDs() -> [String] { [] }
        func deviceUID(_ deviceID: AudioObjectID) -> String? { nil }
        func builtInOutputDeviceUID() -> String? { nil }
        func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool { false }
    }

    private final class FakeBTEnumerator: BTDeviceEnumerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)?
        var onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)? {
            get { lock.withLock { _onSnapshot } }
            set { lock.withLock { _onSnapshot = newValue } }
        }
        func start() {}
        func stop() {}
        func refresh() {}
        func requestAuthorizationForUserAction() {}
        func fire(_ snapshots: [BTDeviceSnapshot]) { onSnapshot?(snapshots) }
    }

    // MARK: Helpers

    private struct Rig {
        let backend: NativeBackend
        let cast: FakeCastEnumerator
        let manager: FakeCastOutputManager
        let capture: FakeCapture
        let bt: FakeBTEnumerator
        let discovery: NoOpDiscovery
        let engine: NoOpEngine
    }

    /// `castAbsenceGrace` defaults SHORT so the browse-debounce never adds
    /// seconds to a test that isn't about it; the tests that ARE about it pass
    /// their own value.
    private func makeBackend(
        withBT: Bool = false,
        silenceFallbackDelay: TimeInterval = NativeBackend.defaultSilenceFallbackDelay,
        castAbsenceGrace: TimeInterval = 0.05,
        castOffsetStore: BTTrimStore? = nil,
        injectedPerAppCapture: PerAppCaptureCoordinator? = nil
    ) -> Rig {
        let engine = NoOpEngine()
        let cast = FakeCastEnumerator()
        let manager = FakeCastOutputManager()
        let capture = FakeCapture()
        let bt = FakeBTEnumerator()
        let discovery = NoOpDiscovery()
        let backend = NativeBackend(
            engineControl: engine,
            discoverySource: discovery,
            btEnumerator: withBT ? bt : nil,
            castEnumerator: cast,
            castOutputManager: manager,
            castOffsetStore: castOffsetStore,
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            injectedPerAppCapture: injectedPerAppCapture,
            silenceFallbackDelay: silenceFallbackDelay,
            castAbsenceGrace: castAbsenceGrace,
            aggregateControl: NoOpAggregateControl(),
            // D7 (adversarial review, Seamless handoff T3): this suite drives
            // `expectedSelected` non-empty via `setOutputSet` — without this
            // override the real default factory would posix_spawn
            // `/usr/bin/log stream` here too. Same fix as `NativeBackendTests`.
            handoffWatcherFactory: { onBlockedAttempt in
                AirPlayHandoffWatcher(spawn: NoOpLogStream(), onBlockedAttempt: onBlockedAttempt)
            })
        backend.captureCoordinator = capture
        backend.start()
        return Rig(backend: backend, cast: cast, manager: manager, capture: capture, bt: bt,
                   discovery: discovery, engine: engine)
    }

    // MARK: Per-app capture doubles (per-suite copies of `NativeBackendTests`')

    /// A `ProcessAudioTap` that always succeeds, registers itself under the
    /// bundle id it was started for, and speaks the engine's S16 format, so a
    /// test can push a fingerprinted buffer into one app's tap.
    private final class BundleTaggingTap: ProcessAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        var onRegister: (@Sendable (String) -> Void)?
        func createAndStart(processes: Set<AudioProcess>, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            onRegister?(bundleID)
            return TapFormat(sampleRate: 44100, channels: 2, bitsPerSample: 16, isFloat: false, isInterleaved: true)
        }
        func teardown() {}
        func push(_ buffer: CapturedBuffer) { onBuffer?(buffer) }
    }

    /// Thread-safe bundleID -> tap registry, populated by `BundleTaggingTap.onRegister`.
    private final class TapRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var byBundleID: [String: BundleTaggingTap] = [:]
        func register(_ bundleID: String, _ tap: BundleTaggingTap) { lock.withLock { byBundleID[bundleID] = tap } }
        func tap(for bundleID: String) -> BundleTaggingTap? { lock.withLock { byBundleID[bundleID] } }
    }

    /// A scripted process list; settable, so a test can launch an app that was
    /// not running when its route was pushed.
    private final class FakeProcessEnumerator: AudioProcessEnumerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _processes: [RawAudioProcess]
        init(processes: [RawAudioProcess]) { _processes = processes }
        var processes: [RawAudioProcess] {
            get { lock.withLock { _processes } }
            set { lock.withLock { _processes = newValue } }
        }
        func enumerateProcesses() -> [RawAudioProcess] { processes }
        func parentPID(of pid: pid_t) -> pid_t? { nil }
    }

    /// Builds an `AudioProcessResolver` where each bundle id resolves to
    /// exactly ONE process object, at `pid = objectID`.
    private func singleProcessResolver(_ bundleIDsToObjectIDs: [String: AudioObjectID]) -> AudioProcessResolver {
        let processes = bundleIDsToObjectIDs.map { bundleID, objectID in
            RawAudioProcess(objectID: objectID, pid: pid_t(objectID), bundleID: bundleID)
        }
        return AudioProcessResolver(enumerator: FakeProcessEnumerator(processes: processes))
    }

    /// A per-app capture over registering taps. Each listed bundle id resolves
    /// to its own process; pass `enumerator` instead to script the list.
    private func registeringPerAppCapture(
        bundleIDs: [String], into registry: TapRegistry,
        enumerator: FakeProcessEnumerator? = nil
    ) -> PerAppCaptureCoordinator {
        var mapping: [String: AudioObjectID] = [:]
        for (offset, bundleID) in bundleIDs.enumerated() {
            mapping[bundleID] = AudioObjectID(9500 + offset)
        }
        return PerAppCaptureCoordinator(
            makeTap: {
                let tap = BundleTaggingTap()
                tap.onRegister = { bundleID in registry.register(bundleID, tap) }
                return tap
            },
            processResolver: enumerator.map { AudioProcessResolver(enumerator: $0) }
                ?? singleProcessResolver(mapping),
            muteBehavior: .mutedWhenTapped)
    }

    /// A single-second, fixed-fill-byte, interleaved-S16-stereo `CapturedBuffer`.
    private func fingerprintedBuffer(fill: UInt8, frames: Int, atSecond sec: Int) -> CapturedBuffer {
        let data = Data(repeating: fill, count: frames * 2 /* ch */ * 2 /* bytes/sample */)
        return CapturedBuffer(channelData: [data], frameCount: frames, pts: timespec(tv_sec: sec, tv_nsec: 0))
    }

    /// A `.device(id:)` route fixture.
    private func route(_ bundleID: String, name: String, toDevice deviceID: String, volume: Int = 100) -> AppRoute {
        AppRoute(bundleID: bundleID, displayName: name, destination: .device(id: deviceID), volume: volume)
    }

    /// Inert `LogStreamSpawning` stand-in (D7) — see `NativeBackendTests`' twin.
    private final class NoOpLogStream: LogStreamSpawning, @unchecked Sendable {
        func start(onLine: @escaping @Sendable (String) -> Void,
                    onTermination: @escaping @Sendable () -> Void) throws {}
        func stop() {}
        var isRunning: Bool { false }
    }

    private func waitFor(timeout: TimeInterval? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation,
                     _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    private static func device(_ backend: NativeBackend, _ id: String) -> Device? {
        backend.devices.first { $0.id == id }
    }

    private static let record = CastDeviceRecord(
        id: "abc123", friendlyName: "Living Room TV", model: "Google TV Streamer",
        endpoint: .hostPort(host: "192.168.4.54", port: 8009))

    /// The absence-debounce test's own receiver, so its timings never
    /// interleave with a sibling test driving ``record``.
    private static let graceRecord = CastDeviceRecord(
        id: "grace456", friendlyName: "Kitchen TV", model: "Google TV Streamer",
        endpoint: .hostPort(host: "192.168.4.55", port: 8009))

    // MARK: - CAST-ENUM

    @Test func snapshotSurfacesCastRowsAndKeepsVanishedOnes() {
        let rig = makeBackend()

        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }
        let row = Self.device(rig.backend, Self.record.id)
        #expect(row?.kind == .cast)
        #expect(row?.isCast == true)
        #expect(row?.name == "Living Room TV")
        #expect(row?.isAvailable == true)
        #expect(row?.supportsAirPlay2 == false)
        #expect(row?.isLocalDevice == false)

        // Dropping off the network greys the row; it never vanishes.
        rig.cast.fire([])
        waitFor { Self.device(rig.backend, Self.record.id)?.isAvailable == false }
        #expect(Self.device(rig.backend, Self.record.id)?.isAvailable == false)
        #expect(rig.backend.devices.filter { $0.isCast }.count == 1)
    }

    /// A wired receiver's Bonjour advert reaches the Mac only intermittently, and
    /// a greyed row reads as disabled in the popover. One browse that omits a
    /// known receiver is a blip, not a departure — the flip waits out
    /// ``NativeBackend/castAbsenceGrace``, and a reappearance inside it cancels.
    @Test func oneMissedBrowseKeepsTheCastRowAvailable() {
        let rig = makeBackend(castAbsenceGrace: 1)
        let id = Self.graceRecord.id
        rig.cast.fire([Self.graceRecord])
        waitFor { Self.device(rig.backend, id)?.isAvailable == true }

        rig.cast.fire([])
        SuiteWait.settle(0.3)
        #expect(Self.device(rig.backend, id)?.isAvailable == true,
                "one omitted browse must not grey the row")

        // Back inside the grace: the pending flip is cancelled, so waiting the
        // whole grace out from here changes nothing.
        rig.cast.fire([Self.graceRecord])
        SuiteWait.settle(1.3)
        #expect(Self.device(rig.backend, id)?.isAvailable == true,
                "a receiver that comes back inside the grace stays available")

        // Missing for the whole grace: now it really has left the network.
        rig.cast.fire([])
        waitFor(timeout: 3) { Self.device(rig.backend, id)?.isAvailable == false }
        #expect(Self.device(rig.backend, id)?.isAvailable == false)
        #expect(rig.backend.devices.filter { $0.id == id }.count == 1, "the row never vanishes")
    }

    // MARK: - CAST-OUT selection

    @Test func selectingACastDeviceDrivesTheManagerAndAttachesTheFeedOnce() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }

        rig.backend.setOutputSet([Self.record.id])
        waitFor { rig.manager.deviceSets.last == [Self.record] }
        #expect(rig.manager.deviceSets.last == [Self.record])
        #expect(rig.capture.castSinkCalls.count == 1)
        #expect(rig.capture.castSinkCalls.first?.isNil == false)
        #expect(rig.capture.castSinkCalls.first?.pid == getpid())
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connecting }
        #expect(Self.device(rig.backend, Self.record.id)?.connectionState == .connecting)

        // A membership-neutral re-push re-applies nothing.
        let setsAfterSelect = rig.manager.deviceSets.count
        rig.backend.setOutputSet([Self.record.id])
        SuiteWait.settle(0.3)
        #expect(rig.capture.castSinkCalls.count == 1, "the feed attaches exactly once per armed stretch")
        #expect(rig.manager.deviceSets.count == setsAfterSelect, "an unchanged id list enqueues nothing")

        rig.backend.setOutputSet([])
        waitFor { rig.manager.deviceSets.last == [] }
        #expect(rig.manager.deviceSets.last == [])
        #expect(rig.capture.castSinkCalls.count == 2)
        #expect(rig.capture.castSinkCalls.last?.isNil == true)
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .off }
        #expect(Self.device(rig.backend, Self.record.id)?.connectionState == .off)
    }

    // MARK: - CAST-SYNC by-ear offset

    /// The manual offset round-trips through its OWN file (never the Bluetooth
    /// trims') and reaches the capture path as whole milliseconds.
    @Test func theByEarOffsetPersistsToItsOwnFileAndReachesTheCapturePath() {
        let store = BTTrimStore(directory: scratchDir, fileName: BTTrimStore.castFileName)
        let rig = makeBackend(castOffsetStore: store)

        rig.backend.setCastUserOffsetMs(-180, forDevice: Self.record.id)
        #expect(rig.backend.castUserOffsetMs(forDevice: Self.record.id) == -180)
        #expect(rig.backend.castHasUserOffset(forDevice: Self.record.id))
        #expect(rig.manager.castUserOffsets.last?.ms == -180)
        #expect(rig.manager.castUserOffsets.last?.id == Self.record.id)
        #expect((try? store.load())?[Self.record.id] == -180)
        #expect(FileManager.default.fileExists(
            atPath: scratchDir.appendingPathComponent(BTTrimStore.bluetoothFileName).path) == false,
            "the Bluetooth trims' file is untouched")

        // A fresh backend over the same file starts carrying the offset.
        let reopened = makeBackend(castOffsetStore: store)
        #expect(reopened.backend.castUserOffsetMs(forDevice: Self.record.id) == -180)

        // Cleared, not zeroed: "tuned" is answered by existence.
        rig.backend.clearCastUserOffset(forDevice: Self.record.id)
        #expect(!rig.backend.castHasUserOffset(forDevice: Self.record.id))
        #expect((try? store.load())?[Self.record.id] == nil)
        #expect(rig.manager.castUserOffsets.last?.ms == 0, "the live feed goes back to no correction")
    }

    /// The value covers a TV's HDMI-to-soundbar chain, which passes the
    /// Bluetooth trim's own ±500 ms bound.
    @Test func theByEarOffsetReachesPastTheBluetoothBoundAndStopsAtTheCastOne() {
        let rig = makeBackend()
        rig.backend.setCastUserOffsetMs(800, forDevice: Self.record.id)
        #expect(rig.backend.castUserOffsetMs(forDevice: Self.record.id) == 800)

        rig.backend.setCastUserOffsetMs(5_000, forDevice: Self.record.id)
        #expect(rig.backend.castUserOffsetMs(forDevice: Self.record.id) == BTSyncTrim.castRangeMs,
                "it is a residue dial, not a seconds dial")
    }

    /// Arming re-states the stored offset, so a receiver the user reselects
    /// comes back carrying what it was tuned to.
    @Test func armingAReceiverRePushesItsStoredOffset() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }
        rig.backend.setCastUserOffsetMs(-180, forDevice: Self.record.id)

        rig.backend.setOutputSet([Self.record.id])
        waitFor { rig.manager.deviceSets.last == [Self.record] }
        rig.backend.setOutputSet([])
        waitFor { rig.manager.deviceSets.last == [] }

        let beforeReselect = rig.manager.castUserOffsets.count
        rig.backend.setOutputSet([Self.record.id])
        waitFor { rig.manager.castUserOffsets.count > beforeReselect }
        #expect(rig.manager.castUserOffsets.last?.ms == -180)
        #expect(rig.manager.castUserOffsets.last?.id == Self.record.id)
    }

    /// THE Phase (i) invariant at the backend seam: a selection with no Cast id
    /// in it must never touch a Cast seam at all.
    @Test func noCastSelectionNeverTouchesTheCastSeams() {
        let rig = makeBackend(withBT: true)
        let btID = "C4-38-75-0E-BF-4A:output"
        rig.bt.fire([BTDeviceSnapshot(
            id: btID, name: "Sonos Move 2", isConnected: true,
            lastUsed: Date(timeIntervalSince1970: 1_780_000_000))])
        waitFor { Self.device(rig.backend, btID) != nil }

        rig.backend.setOutputSet([btID])
        SuiteWait.settle(0.3)
        rig.backend.setOutputSet([])
        SuiteWait.settle(0.3)

        #expect(rig.capture.castSinkCalls.isEmpty, "no Cast id selected ⇒ the fan-out slot is never touched")
        #expect(rig.manager.deviceSets.isEmpty, "nor the session manager")
        #expect(rig.manager.castUserOffsets.isEmpty, "nor the by-ear offset seam (CAST-SYNC)")
    }

    // MARK: - Session state → row

    @Test func sessionStatesMapOntoTheRow() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }
        rig.backend.setOutputSet([Self.record.id])
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connecting }

        rig.manager.fire(id: Self.record.id, state: .playing)
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connected }
        #expect(Self.device(rig.backend, Self.record.id)?.connectionState == .connected)

        func failureCause() -> ConnectionFailure? {
            if case .failed(let failure) = Self.device(rig.backend, Self.record.id)?.connectionState {
                return failure
            }
            return nil
        }

        rig.manager.fire(id: Self.record.id, state: .failed(.appUnavailable(reason: "NOT_FOUND")))
        waitFor { failureCause()?.cause == .castAppUnavailable }
        #expect(failureCause()?.cause == .castAppUnavailable)
        #expect(failureCause()?.detail == "NOT_FOUND")

        rig.manager.fire(id: Self.record.id, state: .failed(.connectionFailed("refused")))
        waitFor { failureCause()?.cause == .castConnectionFailed }
        #expect(failureCause()?.cause == .castConnectionFailed)
        #expect(failureCause()?.detail == "refused")

        rig.manager.fire(id: Self.record.id, state: .failed(.timedOut))
        waitFor { failureCause()?.cause == .timedOut }
        #expect(failureCause()?.cause == .timedOut)

        rig.manager.fire(id: Self.record.id, state: .failed(.dropped(nil)))
        waitFor { failureCause()?.cause == .droppedMidStream }
        #expect(failureCause()?.cause == .droppedMidStream)
    }

    @Test func volumeLagReachesTheDeviceAndClears() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }

        rig.manager.fireLag(id: Self.record.id, lag: 6)
        waitFor { Self.device(rig.backend, Self.record.id)?.castVolumeLagSeconds == 6 }
        #expect(Self.device(rig.backend, Self.record.id)?.castVolumeLagSeconds == 6)

        rig.manager.fireLag(id: Self.record.id, lag: nil)
        waitFor { Self.device(rig.backend, Self.record.id)?.castVolumeLagSeconds == nil }
        #expect(Self.device(rig.backend, Self.record.id)?.castVolumeLagSeconds == nil)
    }

    /// A receiver's first PLAYING can land after the user has already deselected
    /// the row mid-spinner (`setOutputSet` wrote `.off`, teardown still in
    /// flight). That late state must leave the row alone — otherwise a
    /// deselected device reads "connected", and it counts as audible for the
    /// silence watchdog.
    @Test func aLatePlayingAfterDeselectLeavesTheRowOff() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }
        rig.backend.setOutputSet([Self.record.id])
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connecting }
        rig.manager.fire(id: Self.record.id, state: .connecting)

        rig.backend.setOutputSet([])
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .off }

        rig.manager.fire(id: Self.record.id, state: .playing)
        SuiteWait.settle(0.3)
        #expect(Self.device(rig.backend, Self.record.id)?.connectionState == .off,
                "a PLAYING that lands after deselect must not show the row as connected")

        rig.manager.fire(id: Self.record.id, state: .idle)
        SuiteWait.settle(0.3)
        #expect(Self.device(rig.backend, Self.record.id)?.connectionState == .off)

        // Audibility is private state; the watchdog is its one observable — and
        // under the Cast-connecting gate a re-select breathes (`.connecting`),
        // which is deliberately NOT stranded, so the countdown stays disarmed
        // (`connectingCastSessionDoesNotArmTheSilenceWatchdog`). R11 still lands
        // the moment the session gives up, which is what the leak would have
        // suppressed: a receiver left in `castPlaying` reads audible even at
        // `.failed`, and the countdown would never arm.
        rig.backend.setOutputSet([Self.record.id])
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connecting }
        #expect(!rig.backend.test_silenceWatchdogArmed, "a starting Cast session is not stranded")

        rig.manager.fire(id: Self.record.id, state: .failed(.timedOut))
        waitFor { rig.backend.test_silenceWatchdogArmed }
        #expect(rig.backend.test_silenceWatchdogArmed,
                "the late PLAYING must not have marked the receiver audible")
    }

    /// The live-run regression (2026-08-22). A Cast receiver needs ~10 s to reach
    /// PLAYING — connect + launch + LOAD + receiver buffering — which is a dead
    /// heat with the silence fallback's own 10 s. Reading a still-`.connecting`
    /// session as stranded armed the countdown at select, and firing it stopped
    /// the capture tap the Cast feed is fed from, starving the receiver into a
    /// rebuffer stall it never recovered from.
    @Test func connectingCastSessionDoesNotArmTheSilenceWatchdog() {
        let rig = makeBackend(silenceFallbackDelay: 0.05)
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }

        rig.backend.setOutputSet([Self.record.id])
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connecting }
        rig.manager.fire(id: Self.record.id, state: .connecting)

        // Well past the (shrunk) fallback delay: nothing armed, nothing fired.
        SuiteWait.settle(0.5)
        #expect(Self.device(rig.backend, Self.record.id)?.connectionState == .connecting)
        #expect(!rig.backend.test_silenceWatchdogArmed, "a starting Cast session is not stranded")
        #expect(!rig.backend.test_silenceFallbackActive,
                "so the Mac never takes the audio back mid-startup")
    }

    /// R11 intact: the session's own play deadline is what ends a dead receiver,
    /// and the `.failed` row it leaves behind arms the countdown as designed.
    /// (Default fallback delay, so the armed countdown is still observable —
    /// firing it would clear the token.)
    @Test func failedCastSessionStillArmsTheWatchdog() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }

        rig.backend.setOutputSet([Self.record.id])
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connecting }
        #expect(!rig.backend.test_silenceWatchdogArmed)

        rig.manager.fire(id: Self.record.id, state: .failed(.timedOut))
        waitFor { rig.backend.test_silenceWatchdogArmed }
        #expect(rig.backend.test_silenceWatchdogArmed,
                "a failed receiver IS stranded — the fallback must still arm")
    }

    // MARK: - Composed level

    @Test func volumeAndMuteReachTheManagerComposed() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }
        rig.backend.setOutputSet([Self.record.id])
        waitFor { rig.manager.deviceSets.last == [Self.record] }

        rig.backend.setVolume(50, for: Self.record.id)
        waitFor { rig.manager.levels.last?.level == 0.5 }
        #expect(rig.manager.levels.last?.level == 0.5)
        #expect(rig.manager.levels.last?.id == Self.record.id)

        rig.backend.setMasterGain(mainOut: 50, group: 100, mirrorToSystemVolume: false)
        waitFor { rig.manager.levels.last?.level == 0.25 }
        #expect(rig.manager.levels.last?.level == 0.25)

        rig.backend.setMuted(true, for: Self.record.id)
        waitFor { rig.manager.levels.last?.level == 0 }
        #expect(rig.manager.levels.last?.level == 0, "a Cast mute IS level 0, never SET_VOLUME muted")

        rig.backend.setMuted(false, for: Self.record.id)
        waitFor { rig.manager.levels.last?.level == 0.25 }
        #expect(rig.manager.levels.last?.level == 0.25, "unmute comes back at the user's composed level")
    }

    // MARK: - Retry

    @Test func retryReachesTheManagerOnlyWhileSelected() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }
        rig.backend.setOutputSet([Self.record.id])
        waitFor { rig.manager.deviceSets.last == [Self.record] }
        rig.manager.fire(id: Self.record.id, state: .failed(.timedOut))
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState != .connecting }

        rig.backend.retryOutput(Self.record.id)
        waitFor { rig.manager.retries == [Self.record.id] }
        #expect(rig.manager.retries == [Self.record.id])
        #expect(Self.device(rig.backend, Self.record.id)?.connectionState == .connecting)

        rig.backend.setOutputSet([])
        waitFor { rig.manager.deviceSets.last == [] }
        rig.backend.retryOutput(Self.record.id)
        SuiteWait.settle(0.3)
        #expect(rig.manager.retries == [Self.record.id], "an unselected receiver has nothing to retry")
    }

    // MARK: - CAST-SYNC (room delay)

    /// An AirPlay speaker and a Cast receiver, selected together, and the
    /// receiver already playing — the room every CAST-SYNC test below is set in.
    private func castRoom() -> (rig: Rig, ap: DiscoveredDevice) {
        let rig = makeBackend()
        let ap = Self.ap2Device()
        rig.discovery.fire(.appeared(ap))
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil
            && Self.device(rig.backend, ap.id) != nil }
        return (rig, ap)
    }

    /// The whole point of the activation phase: selecting a Cast receiver
    /// makes the room play at the receiver's pace, and the AirPlay feed is
    /// held back by the difference between that and its own start buffer.
    /// Deselecting hands the room back on the very next buffer.
    @Test func selectingACastDeviceHoldsTheAirPlayFeedBack() {
        let (rig, ap) = castRoom()
        rig.backend.setOutputSet([ap.id])
        SuiteWait.settle(0.3)
        #expect(rig.backend.localSinkReferenceDelayMs() == rig.backend.startBufferMs)
        #expect(rig.capture.preDelayMs.isEmpty, "AirPlay alone is never held back")

        rig.backend.setOutputSet([ap.id, Self.record.id])
        waitFor { !rig.capture.preDelayMs.isEmpty }
        let assumed = CastRoomDelay.defaultLeadMs
        #expect(rig.backend.localSinkReferenceDelayMs() == assumed,
                "the room now plays at the receiver's assumed lead")
        #expect(rig.capture.preDelayMs.last == assumed - rig.backend.startBufferMs,
                "and AirPlay is held back by the part it does not already have")

        rig.backend.setOutputSet([ap.id])
        waitFor { rig.capture.preDelayMs.last == 0 }
        #expect(rig.capture.preDelayMs.last == 0, "0 removes the line rather than emptying it")
        #expect(rig.backend.localSinkReferenceDelayMs() == rig.backend.startBufferMs)
    }

    /// THE INVARIANT, at this seam: with no Cast device in the selection the
    /// backend never so much as mentions a pre-delay, so the AirPlay path is
    /// the one that shipped. (Its AirPlay+BT sibling, which also pins every
    /// published composition, is `NativeBackendBTSelectionTests`.)
    @Test func aCastFreeSelectionNeverPublishesAPreDelay() {
        let rig = makeBackend(withBT: true)
        let ap = Self.ap2Device()
        rig.discovery.fire(.appeared(ap))
        rig.cast.fire([Self.record])
        let btID = "C4-38-75-0E-BF-4A:output"
        rig.bt.fire([BTDeviceSnapshot(id: btID, name: "Move 2", isConnected: true)])
        waitFor { Self.device(rig.backend, btID) != nil && Self.device(rig.backend, ap.id) != nil }

        rig.backend.setOutputSet([btID])
        rig.backend.setOutputSet([btID, ap.id])
        rig.backend.setOutputSet([ap.id])
        SuiteWait.settle(0.3)
        #expect(rig.capture.preDelayMs.isEmpty, "got \(rig.capture.preDelayMs)")
    }

    /// A Cast receiver in a room with no AirPlay device in it installs no line
    /// either: nothing would read it, and it costs a megabyte and a memcpy per
    /// buffer. The room delay itself still moves — the Mac's own sink meets it.
    @Test func aCastRoomWithNoAirPlayDeviceInstallsNoLine() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }

        rig.backend.setOutputSet([Self.record.id])
        waitFor { rig.backend.localSinkReferenceDelayMs() == CastRoomDelay.defaultLeadMs }
        #expect(rig.capture.preDelayMs.allSatisfy { $0 == 0 }, "got \(rig.capture.preDelayMs)")
    }

    /// A room held back by a slow Bluetooth speaker alone (the Cast receiver
    /// has failed, so its term is gone) still owes an AirPlay speaker that
    /// joins it the line from its first buffer. Turns red if the selection
    /// path re-publishes the AirPlay line only for a standing Cast term and
    /// not for a standing Bluetooth term.
    @Test func anAirPlaySpeakerJoiningABluetoothTermRoomGetsTheLine() {
        let rig = makeBackend(withBT: true)
        let ap = Self.ap2Device()
        rig.discovery.fire(.appeared(ap))
        rig.cast.fire([Self.record])
        let btID = "C4-38-75-0E-BF-4A:output"
        rig.bt.fire([BTDeviceSnapshot(id: btID, name: "Move 2", isConnected: true)])
        waitFor { Self.device(rig.backend, btID) != nil && Self.device(rig.backend, ap.id) != nil }

        rig.backend.setOutputSet([Self.record.id, btID])
        rig.manager.fire(id: Self.record.id, state: .failed(.timedOut))
        waitFor { rig.backend.localSinkReferenceDelayMs() == rig.backend.startBufferMs }
        let slow = rig.backend.startBufferMs + 300
        rig.backend.endBTWizardLatencyPreview(forDevice: btID, keepMs: Double(slow))
        waitFor { rig.backend.btReferenceDelayMs() == slow + NativeBackend.btReferenceHeadroomMs }
        #expect(rig.capture.preDelayMs.allSatisfy { $0 == 0 }, "got \(rig.capture.preDelayMs)")

        rig.backend.setOutputSet([Self.record.id, btID, ap.id])
        waitFor { rig.capture.preDelayMs.last == slow + NativeBackend.btReferenceHeadroomMs - rig.backend.startBufferMs }
        #expect(rig.capture.preDelayMs.last == slow + NativeBackend.btReferenceHeadroomMs - rig.backend.startBufferMs,
                "got \(rig.capture.preDelayMs)")
    }

    /// A receiver that turns out to play LATER than assumed moves the whole
    /// room once more — and a settled one that stays where it is moves nothing
    /// at all, however many samples it reports.
    @Test func aLateReceiverMovesTheRoomOnceAndThenStops() {
        let (rig, ap) = castRoom()
        rig.backend.setOutputSet([ap.id, Self.record.id])
        waitFor { !rig.capture.preDelayMs.isEmpty }
        let published = rig.capture.preDelayMs.count

        let late = 7_000
        rig.manager.fireLead(id: Self.record.id, leadMs: late,
                             count: CastRoomDelay.settleSampleCount)
        waitFor { rig.capture.preDelayMs.last == late - rig.backend.startBufferMs }
        #expect(rig.backend.localSinkReferenceDelayMs() == late)

        // Still there, still reporting: a settled receiver is left alone.
        rig.manager.fireLead(id: Self.record.id, leadMs: late, count: 30)
        SuiteWait.settle(0.3)
        #expect(rig.capture.preDelayMs.count == published + 1, "got \(rig.capture.preDelayMs)")
    }

    /// A receiver that plays EARLIER than assumed is delayed on its own feed
    /// instead — the rest of the house is not dragged forward for it.
    @Test func anEarlyReceiverLeavesTheRoomWhereItIs() {
        let (rig, ap) = castRoom()
        rig.backend.setOutputSet([ap.id, Self.record.id])
        waitFor { !rig.capture.preDelayMs.isEmpty }
        let published = rig.capture.preDelayMs.count

        rig.manager.fireLead(id: Self.record.id, leadMs: 4_000,
                             count: CastRoomDelay.settleSampleCount)
        SuiteWait.settle(0.3)
        #expect(rig.capture.preDelayMs.count == published, "got \(rig.capture.preDelayMs)")
        #expect(rig.backend.localSinkReferenceDelayMs() == CastRoomDelay.defaultLeadMs)
    }

    /// A receiver that fails stops holding the room back — the others must not
    /// keep playing seconds late for a device that is no longer playing at all.
    @Test func aFailedReceiverHandsTheRoomBack() {
        let (rig, ap) = castRoom()
        rig.backend.setOutputSet([ap.id, Self.record.id])
        waitFor { rig.capture.preDelayMs.last ?? 0 > 0 }

        rig.manager.fire(id: Self.record.id, state: .failed(.timedOut))
        waitFor { rig.capture.preDelayMs.last == 0 }
        #expect(rig.capture.preDelayMs.last == 0)
        #expect(rig.backend.localSinkReferenceDelayMs() == rig.backend.startBufferMs)
    }

    /// Past `R_max` the receiver is refused for sync: it keeps playing, and
    /// the room is handed back rather than held that far behind live.
    @Test func aReceiverPastTheCapIsRefusedForSync() {
        let (rig, ap) = castRoom()
        rig.backend.setOutputSet([ap.id, Self.record.id])
        waitFor { rig.capture.preDelayMs.last ?? 0 > 0 }

        rig.manager.fireLead(id: Self.record.id, leadMs: CastRoomDelay.maxTermMs + 1_000,
                             count: CastRoomDelay.settleSampleCount)
        waitFor { rig.capture.preDelayMs.last == 0 }
        #expect(rig.capture.preDelayMs.last == 0)
        #expect(rig.backend.localSinkReferenceDelayMs() == rig.backend.startBufferMs)
        #expect(rig.manager.deviceSets.last == [Self.record], "and it is still being fed")
    }

    // MARK: - Lifecycle

    @Test func stopStopsTheEnumeratorAndDetachesTheFeed() {
        let rig = makeBackend()
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }
        rig.backend.setOutputSet([Self.record.id])
        waitFor { rig.capture.castSinkCalls.count == 1 }

        rig.backend.stop()
        waitFor { rig.cast.stopCount == 1 }
        #expect(rig.cast.stopCount == 1)
        waitFor { rig.manager.deviceSets.last == [] }
        #expect(rig.manager.deviceSets.last == [])
        waitFor { rig.capture.castSinkCalls.last?.isNil == true }
        #expect(rig.capture.castSinkCalls.last?.isNil == true)
    }

    // MARK: - CAST-METER
    //
    // Cast is the third R-partition: the converge loop's `!device.isCast` guard
    // keeps a Cast id out of the AirPlay engine, so `Device.isSelected` is never
    // true for one and `isMeterable` — which asked exactly that — left every Cast
    // bar dark. `castPlaying` is the Cast "rendering now" fact, the same shape as
    // the local device's `syncedLocalSinkEnabled`.

    /// A receiver that has reported PLAYING must be metered from the SAME
    /// whole-system RMS every other output's bar is fed from — the Cast fan-out
    /// is handed that identical buffer, so reusing it is exact, not an estimate.
    @Test func playingCastReceiverReceivesTheWholeSystemLevel() {
        let rig = makeBackend()
        defer { rig.backend.stop() }
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }
        rig.backend.setOutputSet([Self.record.id])
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connecting }
        rig.manager.fire(id: Self.record.id, state: .playing)
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connected }

        let (levels, task) = subscribeLevels(rig.backend); defer { task.cancel() }
        rig.backend.setMeteringActive(true)
        // Re-fire while polling: one RMS sample is consumed by a single drain, so
        // a sample dropped before the subscription registers must not fail the test.
        waitFor { rig.capture.onLevel?(0.6); return (levels.lastDeviceLevel(Self.record.id) ?? 0) > 0 }

        #expect(abs((levels.lastDeviceLevel(Self.record.id) ?? 0) - 0.6) <= 0.001,
                "a PLAYING Cast receiver must be metered from the whole-system tap it is fanned out from")
    }

    /// A receiver that is selected but has not reported PLAYING is not yet making
    /// sound, so its bar must stay empty. Pins `castPlaying` over mere selection.
    @Test func selectedButNotPlayingCastReceiverIsNotMetered() {
        let rig = makeBackend()
        defer { rig.backend.stop() }
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, Self.record.id) != nil }
        rig.backend.setOutputSet([Self.record.id])
        waitFor { Self.device(rig.backend, Self.record.id)?.connectionState == .connecting }
        // Deliberately never fire `.playing`.

        let (levels, task) = subscribeLevels(rig.backend); defer { task.cancel() }
        rig.backend.setMeteringActive(true)
        waitFor(timeout: 0.3) { rig.capture.onLevel?(0.6); return false }

        #expect(levels.lastDeviceLevel(Self.record.id) == nil,
                "a selected-but-silent Cast receiver must not light its bar")
    }

    // MARK: - Per-app Cast routes
    //
    // A Cast receiver can be one app's `.device` destination: its session is
    // owned by the per-app mixer (`CastFeedSource.perApp`) unless whole-system
    // selection claims it, and it never joins `castSelectedIDs`.

    /// A second receiver, for the tests that address two at once.
    private static let otherRecord = CastDeviceRecord(
        id: "def789", friendlyName: "Bedroom TV", model: "Google TV Streamer",
        endpoint: .hostPort(host: "192.168.4.56", port: 8009))

    /// Every connection state the backend reports for one id, in order.
    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [ConnectionState] = []
        var states: [ConnectionState] { lock.withLock { _states } }
        func record(_ event: BackendEvent, id: String) {
            if case .deviceUpdated(let device) = event, device.id == id {
                lock.withLock { _states.append(device.connectionState) }
            }
        }
    }

    private func logStates(_ backend: NativeBackend, id: String) -> (StateLog, Task<Void, Never>) {
        let log = StateLog()
        let stream = backend.makeEventStream()
        let task = Task { for await event in stream { log.record(event, id: id) } }
        return (log, task)
    }

    private static func isCapturing(_ capture: PerAppCaptureCoordinator, _ bundleID: String) -> Bool {
        if case .capturing = capture.state(for: bundleID) { return true }
        return false
    }

    /// Row 1: two apps on two receivers get two per-app sessions, and each
    /// receiver hears only its own app with nothing written to the engine.
    /// Turns red if `onMixedBuffer` stops addressing `writePerApp` by the
    /// stream's own Cast ids (`PerAppStreamDelivery.castIDs`).
    @Test func twoAppsOnTwoCastReceiversEachHearOnlyTheirOwnApp() {
        let registry = TapRegistry()
        let capture = registeringPerAppCapture(bundleIDs: ["com.a", "com.b"], into: registry)
        let rig = makeBackend(injectedPerAppCapture: capture)
        defer { rig.backend.stop() }
        let x = Self.record.id, y = Self.otherRecord.id
        rig.cast.fire([Self.record, Self.otherRecord])
        waitFor { Self.device(rig.backend, x) != nil && Self.device(rig.backend, y) != nil }

        rig.backend.updateAppRoutes([
            route("com.a", name: "A", toDevice: x), route("com.b", name: "B", toDevice: y),
        ])
        waitFor { rig.manager.sourceSets.last == [x: .perApp, y: .perApp] }
        waitFor { Self.isCapturing(capture, "com.a") && Self.isCapturing(capture, "com.b") }
        registry.tap(for: "com.a")?.push(fingerprintedBuffer(fill: 0xAA, frames: 1000, atSecond: 1))
        registry.tap(for: "com.b")?.push(fingerprintedBuffer(fill: 0xBB, frames: 1000, atSecond: 1))
        waitFor { Set(rig.manager.perAppWrites.map(\.id)) == [x, y] }

        let toX = rig.manager.perAppWrites.filter { $0.id == x }
        let toY = rig.manager.perAppWrites.filter { $0.id == y }
        #expect(toX.contains { $0.fills.contains(0xAA) } && !toX.contains { $0.fills.contains(0xBB) },
                "receiver X hears app A and never app B")
        #expect(toY.contains { $0.fills.contains(0xBB) } && !toY.contains { $0.fills.contains(0xAA) },
                "receiver Y hears app B and never app A")
        #expect(rig.manager.deviceSets.count == 1, "both sessions start in one decision")
        #expect(rig.engine.writes == 0, "a Cast-only stream never writes to the engine")
        #expect(rig.backend.test_castSelectedIDs.isEmpty)
    }

    /// Row 3: whole-system claims a receiver an app is routed to, then lets it
    /// go. Every call keeps the session; only its producer flips, and the row
    /// never goes `.off`. Turns red if `reconcileCastSessionsLocked` drops a
    /// receiver that changes producer instead of re-labelling it.
    @Test func aWholeSystemClaimAndReleaseKeepsTheRoutedReceiversSession() {
        let rig = makeBackend()
        defer { rig.backend.stop() }
        let x = Self.record.id
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, x) != nil }
        let (log, task) = logStates(rig.backend, id: x); defer { task.cancel() }

        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        waitFor { rig.manager.sourceSets.count == 1 }
        rig.backend.setOutputSet([x])
        waitFor { rig.manager.sourceSets.count == 2 }
        rig.backend.setOutputSet([])
        waitFor { rig.manager.sourceSets.count == 3 }
        SuiteWait.settle(0.3)

        #expect(rig.manager.sourceSets == [[x: .perApp], [x: .wholeSystem], [x: .perApp]])
        #expect(rig.manager.deviceSets.allSatisfy { $0 == [Self.record] },
                "no call ever leaves the receiver out, so its session is never torn down")
        #expect(!log.states.contains(.off), "got \(log.states)")
        #expect(Self.device(rig.backend, x)?.connectionState == .connecting)
        #expect(rig.backend.test_castSelectedIDs.isEmpty)
    }

    /// Row 4: turning whole-system Cast off while an app stays routed to the
    /// receiver keeps its session as per-app and detaches the fan-out slot.
    /// Turns red if `applyCastTransition` keeps the slot attached with no
    /// whole-system receiver, or tears the session down on deselect.
    @Test func wholeSystemCastOffHandsTheReceiverToItsRouteAndDetachesTheFanOut() {
        let rig = makeBackend()
        defer { rig.backend.stop() }
        let x = Self.record.id
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, x) != nil }

        rig.backend.setOutputSet([x])
        waitFor { rig.manager.sourceSets.last == [x: .wholeSystem] }
        #expect(rig.capture.castSinkCalls.last?.isNil == false)
        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        SuiteWait.settle(0.3)
        #expect(rig.manager.sourceSets.count == 1, "a claimed receiver stays whole-system")

        rig.backend.setOutputSet([])
        waitFor { rig.manager.sourceSets.last == [x: .perApp] }
        #expect(rig.manager.deviceSets.last == [Self.record])
        waitFor { rig.capture.castSinkCalls.last?.isNil == true }
        #expect(rig.capture.castSinkCalls.count == 2)
        #expect(rig.backend.test_castSelectedIDs.isEmpty)
    }

    /// Row 5: the session follows the route, not the app. It arms while the
    /// app is not running, survives the app quitting, and is fed again after
    /// a relaunch with no new `setDevices`. Turns red if Cast desire in
    /// `reconcileCastSessionsLocked` keys on capture state instead of the route.
    @Test func aRoutedReceiverKeepsItsSessionAcrossTheAppQuittingAndRelaunching() {
        let registry = TapRegistry()
        let processes = FakeProcessEnumerator(processes: [])
        let capture = registeringPerAppCapture(bundleIDs: [], into: registry, enumerator: processes)
        let rig = makeBackend(injectedPerAppCapture: capture)
        defer { rig.backend.stop() }
        let x = Self.record.id
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, x) != nil }

        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        waitFor { rig.manager.sourceSets.last == [x: .perApp] }
        waitFor { if case .failed = capture.state(for: "com.a") { return true }; return false }
        let armed = rig.manager.deviceSets.count

        rig.backend.handleAppTerminated(bundleID: "com.a")
        SuiteWait.settle(0.2)
        #expect(rig.manager.deviceSets.count == armed, "a quit app keeps its receiver's session")

        processes.processes = [RawAudioProcess(objectID: 9500, pid: 9500, bundleID: "com.a")]
        rig.backend.handleAppLaunched(bundleID: "com.a")
        waitFor { Self.isCapturing(capture, "com.a") }
        registry.tap(for: "com.a")?.push(fingerprintedBuffer(fill: 0xAA, frames: 1000, atSecond: 1))
        waitFor { rig.manager.perAppWrites.contains { $0.id == x && $0.bytes > 0 } }
        #expect(rig.manager.deviceSets.count == armed, "nor does the relaunch restart it")
    }

    /// Row 6: a route pushed before its receiver is discovered arms nothing,
    /// then engages the moment the browse finds it. Turns red if
    /// `applyCastSnapshots` stops replaying routes for a NEW receiver.
    @Test func aRoutePushedBeforeDiscoveryEngagesWhenTheReceiverAppears() {
        let rig = makeBackend()
        defer { rig.backend.stop() }
        let x = Self.record.id

        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        SuiteWait.settle(0.3)
        #expect(rig.manager.deviceSets.isEmpty, "an unknown receiver gets no session")

        rig.cast.fire([Self.record])
        waitFor { rig.manager.deviceSets.last == [Self.record] }
        #expect(rig.manager.sourceSets.last == [x: .perApp])
    }

    /// Row 7: a routed receiver that leaves the network past the grace loses
    /// its session and goes `.off`; the route stays, so its return re-arms it.
    /// Turns red if `reconcileCastSessionsLocked` stops requiring the receiver
    /// to be reachable.
    @Test func aRoutedReceiverThatLeavesLosesItsSessionAndGetsItBackOnReturn() {
        let rig = makeBackend(castAbsenceGrace: 0.05)
        defer { rig.backend.stop() }
        let x = Self.record.id
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, x) != nil }
        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        waitFor { rig.manager.deviceSets.last == [Self.record] }

        rig.cast.fire([])
        waitFor { Self.device(rig.backend, x)?.isAvailable == false }
        waitFor { rig.manager.deviceSets.last == [] }
        #expect(rig.manager.sourceSets.last == [:])
        waitFor { Self.device(rig.backend, x)?.connectionState == .off }
        #expect(Self.device(rig.backend, x)?.connectionState == .off)

        rig.cast.fire([Self.record])
        waitFor { rig.manager.deviceSets.last == [Self.record] }
        #expect(rig.manager.sourceSets.last == [x: .perApp], "the kept route re-arms the receiver")
    }

    /// Row 8: rapid route edits between two receivers end on the last one, and
    /// every call in between hands over records and sources for the same ids.
    /// Turns red if `reconcileCastSessionsLocked` builds `records` from a
    /// different id list than `sources`.
    @Test func rapidRouteEditsEndOnTheLastReceiverWithEveryCallConsistent() {
        let rig = makeBackend()
        defer { rig.backend.stop() }
        let x = Self.record.id, y = Self.otherRecord.id
        rig.cast.fire([Self.record, Self.otherRecord])
        waitFor { Self.device(rig.backend, x) != nil && Self.device(rig.backend, y) != nil }

        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: y)])
        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        waitFor { rig.manager.sourceSets.count == 3 }
        SuiteWait.settle(0.3)

        #expect(rig.manager.sourceSets.last == [x: .perApp])
        #expect(rig.manager.deviceSets.last == [Self.record])
        for (records, sources) in zip(rig.manager.deviceSets, rig.manager.sourceSets) {
            #expect(Set(records.map(\.id)) == Set(sources.keys), "records \(records) vs sources \(sources)")
        }
    }

    /// Row 9: a stream whose only destination is a Cast receiver never binds
    /// an engine stream and never writes to the engine, yet reaches the
    /// receiver. Turns red if a delivery with no engine-bound device keeps
    /// the engine write (`PerAppStreamDelivery.engine`).
    @Test func aCastOnlyStreamNeverTouchesTheEngine() {
        let registry = TapRegistry()
        let capture = registeringPerAppCapture(bundleIDs: ["com.a"], into: registry)
        let rig = makeBackend(injectedPerAppCapture: capture)
        defer { rig.backend.stop() }
        let x = Self.record.id
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, x) != nil }

        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        waitFor { Self.isCapturing(capture, "com.a") }
        registry.tap(for: "com.a")?.push(fingerprintedBuffer(fill: 0xAA, frames: 1000, atSecond: 1))
        waitFor { rig.manager.perAppWrites.contains { $0.id == x && $0.bytes > 0 } }
        SuiteWait.settle(0.2)

        #expect(rig.engine.writes == 0)
        #expect(rig.engine.streamAdds == 0)
    }

    /// Row 11: a per-app-only receiver never joins the room. Its lead samples
    /// move no AirPlay pre-delay even with an AirPlay speaker selected. Turns
    /// red if a per-app receiver enters `castSelectedIDs`.
    @Test func aPerAppReceiverNeverSetsTheRoomsTiming() {
        let (rig, ap) = castRoom()
        defer { rig.backend.stop() }
        let x = Self.record.id
        rig.backend.setOutputSet([ap.id])
        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        waitFor { rig.manager.sourceSets.last == [x: .perApp] }

        rig.manager.fireLead(id: x, leadMs: 7_000, count: CastRoomDelay.settleSampleCount)
        SuiteWait.settle(0.3)
        #expect(rig.capture.preDelayMs.isEmpty, "got \(rig.capture.preDelayMs)")
        #expect(rig.backend.localSinkReferenceDelayMs() == rig.backend.startBufferMs)
        #expect(rig.backend.test_castSelectedIDs.isEmpty)
    }

    /// Row 12: a per-app-owned receiver gets master level changes, retries,
    /// and its PLAYING. Turns red if the master loop, `retryCastOutput` or
    /// `applyCastSessionState` go back to reading whole-system selection only.
    @Test func aPerAppReceiverGetsLevelsRetryAndPlaying() {
        let rig = makeBackend()
        defer { rig.backend.stop() }
        let x = Self.record.id
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, x) != nil }
        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        waitFor { rig.manager.sourceSets.last == [x: .perApp] }

        rig.backend.setMasterGain(mainOut: 50, group: 100, mirrorToSystemVolume: false)
        waitFor { rig.manager.levels.last?.level == 0.5 }
        #expect(rig.manager.levels.last?.id == x)

        rig.manager.fire(id: x, state: .failed(.timedOut))
        waitFor { Self.device(rig.backend, x)?.connectionState != .connecting }
        rig.backend.retryOutput(x)
        waitFor { rig.manager.retries == [x] }
        #expect(Self.device(rig.backend, x)?.connectionState == .connecting)

        rig.manager.fire(id: x, state: .playing)
        waitFor { Self.device(rig.backend, x)?.connectionState == .connected }
        #expect(Self.device(rig.backend, x)?.connectionState == .connected)
    }

    /// Row 13: a playing per-app-only receiver meters its routed app's source
    /// level, never the whole-system RMS it is not fed from. Turns red if
    /// `isMeterable` drops its `castSelectedIDs` test for Cast.
    @Test func aPerAppReceiverMetersItsAppNotTheSystem() {
        let registry = TapRegistry()
        let capture = registeringPerAppCapture(bundleIDs: ["com.a"], into: registry)
        let rig = makeBackend(injectedPerAppCapture: capture)
        defer { rig.backend.stop() }
        let x = Self.record.id
        rig.cast.fire([Self.record])
        waitFor { Self.device(rig.backend, x) != nil }
        rig.backend.updateAppRoutes([route("com.a", name: "A", toDevice: x)])
        waitFor { Self.isCapturing(capture, "com.a") }
        rig.manager.fire(id: x, state: .playing)
        waitFor { Self.device(rig.backend, x)?.connectionState == .connected }

        let (levels, task) = subscribeLevels(rig.backend); defer { task.cancel() }
        rig.backend.setMeteringActive(true)
        waitFor(timeout: 0.3) { rig.capture.onLevel?(0.6); return false }
        #expect(levels.lastDeviceLevel(x) == nil, "the system RMS never reaches a per-app-only receiver")

        waitFor { rig.backend.routeMixer.onAppLevel?("com.a", 0.4); return levels.lastDeviceLevel(x) != nil }
        #expect(abs((levels.lastDeviceLevel(x) ?? 0) - 0.4) <= 0.001,
                "its bar is the routed app's source level")
    }
}
