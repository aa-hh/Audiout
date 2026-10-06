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
        private var _onLeadSample: (@Sendable (String, Int, Int, Int?, Int) -> Void)?
        private var _deviceSets: [[CastDeviceRecord]] = []
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
        var onLeadSample: (@Sendable (String, Int, Int, Int?, Int) -> Void)? {
            get { lock.withLock { _onLeadSample } }
            set { lock.withLock { _onLeadSample = newValue } }
        }
        var deviceSets: [[CastDeviceRecord]] { lock.withLock { _deviceSets } }
        var levels: [(level: Double, id: String)] { lock.withLock { _levels } }
        var retries: [String] { lock.withLock { _retries } }
        var stopAllCount: Int { lock.withLock { _stopAllCount } }
        /// CAST-SYNC: every by-ear offset written onto the live feed, in order.
        var castUserOffsets: [(ms: Int, id: String)] { lock.withLock { _castUserOffsets } }
        private var _castUserOffsets: [(ms: Int, id: String)] = []
        /// Every room-delay share, feed-gate decision and plays-alone flag the
        /// backend handed the manager, in order.
        var castRoomDelays: [(ms: Int, id: String)] { lock.withLock { _castRoomDelays } }
        private var _castRoomDelays: [(ms: Int, id: String)] = []
        var feedGates: [(open: Bool, id: String)] { lock.withLock { _feedGates } }
        private var _feedGates: [(open: Bool, id: String)] = []
        var playsAlone: [(alone: Bool, id: String)] { lock.withLock { _playsAlone } }
        private var _playsAlone: [(alone: Bool, id: String)] = []

        func setDevices(_ records: [CastDeviceRecord]) { lock.withLock { _deviceSets.append(records) } }
        func setLevel(_ level: Double, forDevice id: String) { lock.withLock { _levels.append((level, id)) } }
        func setCastUserOffsetMs(_ ms: Int, forDeviceID id: String) {
            lock.withLock { _castUserOffsets.append((ms, id)) }
        }
        func setCastRoomDelayMs(_ ms: Int, forDeviceID id: String) {
            lock.withLock { _castRoomDelays.append((ms, id)) }
        }
        func setCastFeedGate(open: Bool, forDeviceID id: String, generation: Int) {
            lock.withLock { _feedGates.append((open, id)) }
        }
        func setCastPlaysAlone(_ alone: Bool, forDeviceID id: String) {
            lock.withLock { _playsAlone.append((alone, id)) }
        }
        /// Every feed rate the backend handed the manager, in order.
        var castRates: [(ppm: Double, id: String)] { lock.withLock { _castRates } }
        private var _castRates: [(ppm: Double, id: String)] = []
        func setCastRatePpm(_ ppm: Double, forDeviceID id: String) {
            lock.withLock { _castRates.append((ppm, id)) }
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
        func fireLead(id: String, leadMs: Int, count: Int = 1, feedDelayMs: Int = 0, holdMs: Int? = nil) {
            let handler = lock.withLock { _onLeadSample }
            for _ in 0..<count { handler?(id, leadMs, feedDelayMs, holdMs, 0) }
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

    private final class NoOpEngine: EngineControlling, @unchecked Sendable {
        func start() async throws {}
        func stop() async {}
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            OutputID(rawValue: 0)
        }
        func removeDiscovery(_ descriptor: DeviceDescriptor) async {}
        func addOutput(_ id: OutputID) async throws {}
        func addOutput(_ id: OutputID, streamId: UInt32) async throws {}
        func removeOutput(_ id: OutputID) async throws {}
        func setVolume(_ id: OutputID, _ volume: Double) async throws {}
        func setStartBufferMs(_ ms: Int) async {}
        func write(pcm: Data, streamId: UInt32, pts: timespec) {}
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
    }

    /// `castAbsenceGrace` defaults SHORT so the browse-debounce never adds
    /// seconds to a test that isn't about it; the tests that ARE about it pass
    /// their own value.
    private func makeBackend(
        withBT: Bool = false,
        silenceFallbackDelay: TimeInterval = NativeBackend.defaultSilenceFallbackDelay,
        castAbsenceGrace: TimeInterval = 0.05,
        castOffsetStore: BTTrimStore? = nil,
        delayClock: @escaping NativeBackend.DelayClock = NativeBackend.dispatchDelayClock
    ) -> Rig {
        let cast = FakeCastEnumerator()
        let manager = FakeCastOutputManager()
        let capture = FakeCapture()
        let bt = FakeBTEnumerator()
        let discovery = NoOpDiscovery()
        let backend = NativeBackend(
            engineControl: NoOpEngine(),
            discoverySource: discovery,
            btEnumerator: withBT ? bt : nil,
            castEnumerator: cast,
            castOutputManager: manager,
            castOffsetStore: castOffsetStore,
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            delayClock: delayClock,
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
                   discovery: discovery)
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
        let clock = ManualDelayClock()
        let rig = makeBackend(castAbsenceGrace: 1, delayClock: hopToQueue(clock))
        let id = Self.graceRecord.id
        rig.cast.fire([Self.graceRecord])
        waitFor { Self.device(rig.backend, id)?.isAvailable == true }

        rig.cast.fire([])
        waitFor { clock.pendingCount == 1 }
        clock.advance(by: 0.5)
        #expect(Self.device(rig.backend, id)?.isAvailable == true,
                "one omitted browse must not grey the row")

        // Back inside the grace: the pending flip is cancelled, so waiting the
        // whole grace out from here changes nothing.
        rig.cast.fire([Self.graceRecord])
        _ = rig.backend.devices  // stateQueue.sync: the re-listing is applied before the clock moves
        clock.advance(by: 1.0)
        #expect(Self.device(rig.backend, id)?.isAvailable == true,
                "a receiver that comes back inside the grace stays available")

        // Missing for the whole grace: now it really has left the network.
        rig.cast.fire([])
        waitFor { clock.pendingCount == 1 }
        clock.advance(by: 1.0)
        waitFor { Self.device(rig.backend, id)?.isAvailable == false }
        #expect(Self.device(rig.backend, id)?.isAvailable == false)
        #expect(rig.backend.devices.filter { $0.id == id }.count == 1, "the row never vanishes")
    }

    /// The manual clock performs jobs on the caller's thread, but `expireCastAbsence`
    /// must run on `stateQueue`, so each fired job re-enqueues the original work there.
    private func hopToQueue(_ manual: ManualDelayClock) -> NativeBackend.DelayClock {
        return { delay, queue, work in
            manual.clock(delay, queue, DispatchWorkItem { queue.async(execute: work) })
        }
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
    private func castRoom(
        delayClock: @escaping NativeBackend.DelayClock = NativeBackend.dispatchDelayClock
    ) -> (rig: Rig, ap: DiscoveredDevice) {
        let rig = makeBackend(delayClock: delayClock)
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
        let assumed = CastRoomDelay.defaultLeadMs + CastFeedRing.macHoldMs
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
        waitFor { rig.backend.localSinkReferenceDelayMs() == CastRoomDelay.defaultLeadMs + CastFeedRing.macHoldMs }
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
        waitFor { rig.capture.preDelayMs.last == late + CastFeedRing.macHoldMs - rig.backend.startBufferMs }
        #expect(rig.backend.localSinkReferenceDelayMs() == late + CastFeedRing.macHoldMs)

        // Still there, still reporting: a settled receiver is left alone.
        rig.manager.fireLead(id: Self.record.id, leadMs: late, count: 30)
        SuiteWait.settle(0.3)
        #expect(rig.capture.preDelayMs.count == published + 1, "got \(rig.capture.preDelayMs)")
    }

    /// A receiver that settles EARLIER than assumed brings the room down to
    /// it once, and its own share goes to 0.
    /// Turns red if a settle more than `raiseThresholdMs` below the term leaves the room where it is.
    @Test func anEarlyReceiversSettleLowersTheRoomToIt() {
        let (rig, ap) = castRoom()
        rig.backend.setOutputSet([ap.id, Self.record.id])
        waitFor { !rig.capture.preDelayMs.isEmpty }
        let published = rig.capture.preDelayMs.count

        rig.manager.fireLead(id: Self.record.id, leadMs: 4_000,
                             count: CastRoomDelay.settleSampleCount)
        waitFor { rig.capture.preDelayMs.last == 4_000 + CastFeedRing.macHoldMs - rig.backend.startBufferMs }
        #expect(rig.capture.preDelayMs.count == published + 1, "got \(rig.capture.preDelayMs)")
        #expect(rig.backend.localSinkReferenceDelayMs() == 4_115)
        waitFor { rig.manager.castRoomDelays.last?.ms == 0 }
        #expect(rig.manager.castRoomDelays.last?.ms == 0)
        #expect(rig.manager.castRoomDelays.last?.id == Self.record.id)
    }

    /// A receiver's measured hold replaces the fallback hold both in its share
    /// and in the term it raises, and a share of 0 is still handed over.
    /// Turns red if the share or the room keeps the fixed `macHoldMs` where the receiver's measured hold belongs, or a zero share stops being pushed.
    @Test func aMeasuredHoldSetsTheReceiversShareAndTheRoom() {
        let (rig, ap) = castRoom()
        rig.backend.setOutputSet([ap.id, Self.record.id])
        waitFor { !rig.capture.preDelayMs.isEmpty }
        let id = Self.record.id
        let room0 = CastRoomDelay.defaultLeadMs + CastFeedRing.macHoldMs

        rig.manager.fireLead(id: id, leadMs: 5_520, count: CastRoomDelay.settleSampleCount, holdMs: 84)
        waitFor { rig.manager.castRoomDelays.last?.ms == 11 }
        #expect(rig.manager.castRoomDelays.last?.ms == 11)
        #expect(rig.backend.localSinkReferenceDelayMs() == room0)

        rig.manager.fireLead(id: id, leadMs: 5_700, count: CastRoomDelay.settleSampleCount, holdMs: 84)
        waitFor { rig.backend.localSinkReferenceDelayMs() == 5_784 }
        #expect(rig.backend.localSinkReferenceDelayMs() == 5_784)
        #expect(rig.manager.castRoomDelays.last?.ms == 0)
    }

    /// A settled receiver that drifts inside its share has the share follow
    /// it with the room and its gate left alone; drift that would need more
    /// than `raiseThresholdMs` of negative share moves the room once.
    /// Turns red if a settled receiver's tracked drift moves the room while its share can absorb it, leaves its share where its settle put it, or fails to move the room once the drift passes `raiseThresholdMs`.
    @Test func aSettledReceiversTrackedDriftMovesItsShareAndTheRoomOnlyPastTheRaiseBand() {
        let (rig, ap) = castRoom()
        let id = Self.record.id
        rig.backend.setOutputSet([ap.id, id])
        waitFor { !rig.capture.preDelayMs.isEmpty }

        rig.manager.fireLead(id: id, leadMs: 5_500, count: CastRoomDelay.settleSampleCount)
        waitFor { rig.manager.castRoomDelays.last?.ms == 0 }
        rig.backend.stateQueue.sync {}
        rig.backend.captureControlQueue.sync {}
        let published = rig.capture.preDelayMs.count

        rig.manager.fireLead(id: id, leadMs: 5_479, count: CastRoomDelay.trackingWindowSamples)
        waitFor { rig.manager.castRoomDelays.last?.ms == 21 }
        rig.backend.stateQueue.sync {}
        rig.backend.captureControlQueue.sync {}
        #expect(rig.capture.preDelayMs.count == published, "got \(rig.capture.preDelayMs)")
        #expect(rig.backend.localSinkReferenceDelayMs() == 5_615)
        #expect(rig.manager.feedGates.suffix(10).allSatisfy { $0.open }, "got \(rig.manager.feedGates)")

        rig.manager.fireLead(id: id, leadMs: 5_530, count: CastRoomDelay.trackingWindowSamples)
        waitFor { rig.capture.preDelayMs.last == 5_645 - rig.backend.startBufferMs }
        #expect(rig.capture.preDelayMs.count == published + 1, "got \(rig.capture.preDelayMs)")
        #expect(rig.backend.localSinkReferenceDelayMs() == 5_645)
        waitFor { rig.manager.castRoomDelays.last?.ms == 0 }
        #expect(rig.manager.castRoomDelays.last?.ms == 0)
    }

    /// A settled receiver's feed rate follows what the listener hears from it
    /// against the room plus its by-ear trim: lead, Mac hold and applied feed
    /// delay, with a negative trim the floor at 0 swallowed still counted.
    /// Turns red if the backend's error drops the Mac hold, the applied feed delay or the by-ear trim, lets the floor at 0 hide a negative trim, or feeds the speed window the sample that settled.
    @Test func aSettledReceiversErrorAgainstTheRoomAndTrimSetsItsFeedRate() {
        let clock = ManualDelayClock()
        let (rig, ap) = castRoom(delayClock: clock.clock)
        let id = Self.record.id
        rig.backend.setOutputSet([ap.id, id])
        waitFor { !rig.capture.preDelayMs.isEmpty }

        rig.manager.fireLead(id: id, leadMs: 5_500, count: CastRoomDelay.settleSampleCount, holdMs: 115)
        waitFor { rig.manager.castRoomDelays.last?.ms == 0 }
        rig.manager.fireLead(id: id, leadMs: 5_500, count: CastRoomDelay.speedMatchMinimumSamples - 1, holdMs: 120)
        rig.backend.stateQueue.sync {}
        #expect(rig.manager.castRates.isEmpty, "got \(rig.manager.castRates)")

        rig.manager.fireLead(id: id, leadMs: 5_500, holdMs: 120)
        rig.backend.stateQueue.sync {}
        #expect(rig.manager.castRates.count == 1)
        #expect(rig.manager.castRates.last?.ppm == 50)
        #expect(rig.manager.castRates.last?.id == id)

        rig.backend.setCastUserOffsetMs(-3, forDevice: id)
        rig.manager.fireLead(id: id, leadMs: 5_500, count: CastRoomDelay.trackingWindowSamples, holdMs: 120)
        rig.backend.stateQueue.sync {}
        #expect(rig.manager.castRates.last?.ppm == 80)

        rig.backend.setCastUserOffsetMs(4, forDevice: id)
        rig.manager.fireLead(id: id, leadMs: 5_500, count: CastRoomDelay.trackingWindowSamples, holdMs: 120)
        rig.backend.stateQueue.sync {}
        #expect(rig.manager.castRates.last?.ppm == 50)
        #expect(rig.backend.localSinkReferenceDelayMs() == 5_615)
    }

    /// Every by-ear offset reaches the receiver's feed at once, but the room
    /// moves only when the dial has been still: one move for a burst, one
    /// back for a clear, none for a delay, and none after a deselect.
    /// Turns red if an offset change moves the room before the settle fires, a burst moves it more than once, or a deselect stops cancelling the pending settle.
    @Test func aNegativeOffsetRaisesTheRoomOnceTheDialIsStill() {
        let clock = ManualDelayClock()
        let (rig, ap) = castRoom(delayClock: clock.clock)
        let id = Self.record.id
        let startBuffer = rig.backend.startBufferMs
        rig.backend.setOutputSet([ap.id, id])
        rig.manager.fireLead(id: id, leadMs: CastRoomDelay.defaultLeadMs, count: CastRoomDelay.settleSampleCount)
        waitFor { rig.manager.castRoomDelays.last?.ms == 0 }
        let room0 = CastRoomDelay.defaultLeadMs + CastFeedRing.macHoldMs
        waitFor { rig.capture.preDelayMs.last == room0 - startBuffer }
        // The arm re-pushes the stored offsets on this queue; let it land first.
        rig.backend.captureControlQueue.sync {}
        let published = rig.capture.preDelayMs.count

        // B3: a burst.
        for offset in [-30, -60, -80] {
            rig.backend.setCastUserOffsetMs(Double(offset), forDevice: id)
            #expect(rig.manager.castUserOffsets.last?.ms == offset)
        }
        #expect(rig.backend.localSinkReferenceDelayMs() == room0)
        #expect(clock.pendingCount == 1)
        rig.backend.stateQueue.sync { clock.fireAll() }
        #expect(rig.backend.localSinkReferenceDelayMs() == room0 + 80)
        waitFor { rig.capture.preDelayMs.last == room0 + 80 - startBuffer }
        #expect(rig.capture.preDelayMs.count == published + 1, "got \(rig.capture.preDelayMs)")
        #expect(rig.manager.castRoomDelays.last?.ms == 80)

        // B4: a clear.
        rig.backend.clearCastUserOffset(forDevice: id)
        #expect(rig.manager.castUserOffsets.last?.ms == 0)
        #expect(rig.backend.localSinkReferenceDelayMs() == room0 + 80)
        #expect(clock.pendingCount == 1)
        rig.backend.stateQueue.sync { clock.fireAll() }
        #expect(rig.backend.localSinkReferenceDelayMs() == room0)
        waitFor { rig.capture.preDelayMs.last == room0 - startBuffer }
        #expect(rig.capture.preDelayMs.count == published + 2, "got \(rig.capture.preDelayMs)")
        #expect(rig.manager.castRoomDelays.last?.ms == 0)

        // B5: a delay fits inside the receiver's own share.
        rig.backend.setCastUserOffsetMs(40, forDevice: id)
        #expect(rig.manager.castUserOffsets.last?.ms == 40)
        rig.backend.stateQueue.sync { clock.fireAll() }
        #expect(rig.backend.localSinkReferenceDelayMs() == room0)
        rig.backend.captureControlQueue.sync {}
        #expect(rig.capture.preDelayMs.count == published + 2, "got \(rig.capture.preDelayMs)")

        // B6: a deselect mid-drag.
        rig.backend.setCastUserOffsetMs(-80, forDevice: id)
        rig.backend.setOutputSet([ap.id])
        waitFor { rig.capture.preDelayMs.last == 0 }
        rig.backend.stateQueue.sync {}
        #expect(clock.pendingCount == 0)
        rig.backend.stateQueue.sync { clock.fireAll() }
        #expect(rig.backend.localSinkReferenceDelayMs() == startBuffer)
    }

    /// An unsettled receiver's feed opens when what it plays (its lead, plus
    /// the Mac hold, plus the feed delay the manager reported with the
    /// sample) lands on the room, and stays shut otherwise.
    /// Turns red if the gate decision drops the Mac hold or the reported feed delay before comparing the play-out with the room.
    @Test func aLeadSampleOpensTheFeedGateOnlyWhenItsPlayOutMeetsTheRoom() {
        let (rig, ap) = castRoom()
        rig.backend.setOutputSet([ap.id, Self.record.id])
        waitFor { !rig.capture.preDelayMs.isEmpty }
        let id = Self.record.id

        rig.manager.fireLead(id: id, leadMs: CastRoomDelay.defaultLeadMs)
        waitFor { rig.manager.feedGates.count == 1 }
        #expect(rig.manager.feedGates.last?.open == true)
        #expect(rig.manager.feedGates.last?.id == id)
        rig.manager.fireLead(id: id, leadMs: 4_000)
        waitFor { rig.manager.feedGates.count == 2 }
        #expect(rig.manager.feedGates.last?.open == false)

        rig.manager.fireLead(id: id, leadMs: 2_885, feedDelayMs: 2_615)
        waitFor { rig.manager.feedGates.count == 3 }
        #expect(rig.manager.feedGates.last?.open == true, "2885 + 115 + 2615 is the room")
        rig.manager.fireLead(id: id, leadMs: 2_885)
        waitFor { rig.manager.feedGates.count == 4 }
        #expect(rig.manager.feedGates.last?.open == false)
    }

    /// A settle that moves the receiver's share past the band keeps its feed
    /// shut until the audio still queued on the Mac under the old share has
    /// drained, the measured hold later; a sample in between does not open it.
    /// Turns red if the gate opens at that settle or on a later sample before the held-back open fires, or that open waits anything but the receiver's measured hold.
    @Test func aSettleThatMovesTheShareOpensTheGateOnlyWhenTheHeldBackOpenFires() {
        let clock = ManualDelayClock()
        // Only a job asked to wait the hold reaches the clock.
        let wait = Double(84) / 1000
        let (rig, ap) = castRoom(delayClock: { seconds, queue, work in
            guard seconds == wait else { return }
            clock.clock(seconds, queue, work)
        })
        let id = Self.record.id
        rig.backend.setOutputSet([ap.id, id])
        waitFor { !rig.capture.preDelayMs.isEmpty }

        rig.manager.fireLead(id: id, leadMs: 4_000, count: CastRoomDelay.settleSampleCount,
                             feedDelayMs: 1_000, holdMs: 84)
        waitFor { rig.manager.castRoomDelays.last?.ms == 0 }
        rig.manager.fireLead(id: id, leadMs: 4_000, count: 3, feedDelayMs: 0)
        waitFor { rig.manager.feedGates.count == CastRoomDelay.settleSampleCount + 3 }
        rig.backend.stateQueue.sync {}
        #expect(rig.manager.feedGates.allSatisfy { !$0.open }, "got \(rig.manager.feedGates)")
        #expect(clock.pendingCount == 1)

        rig.backend.stateQueue.sync { clock.fireAll() }
        #expect(rig.manager.feedGates.last?.open == true)
        #expect(rig.manager.feedGates.last?.id == id)
    }

    /// A receiver that is the only output has nothing to fall out of step
    /// with, so its feed plays from the first byte; another output joining
    /// takes that back.
    /// Turns red if the selection pass stops telling the manager a lone Cast receiver plays alone, or stops withdrawing it when another output joins.
    @Test func aLoneCastReceiverIsToldItPlaysAlone() {
        let (rig, ap) = castRoom()
        rig.backend.setOutputSet([Self.record.id])
        waitFor { rig.manager.playsAlone.last?.alone == true }
        #expect(rig.manager.playsAlone.last?.alone == true)
        #expect(rig.manager.playsAlone.last?.id == Self.record.id)

        rig.backend.setOutputSet([ap.id, Self.record.id])
        waitFor { rig.manager.playsAlone.last?.alone == false }
        #expect(rig.manager.playsAlone.last?.alone == false)
        #expect(rig.manager.playsAlone.last?.id == Self.record.id)
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
}
