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
        var deviceSets: [[CastDeviceRecord]] { lock.withLock { _deviceSets } }
        var levels: [(level: Double, id: String)] { lock.withLock { _levels } }
        var retries: [String] { lock.withLock { _retries } }
        var stopAllCount: Int { lock.withLock { _stopAllCount } }
        /// CAST-SYNC: every by-ear offset written onto the live feed, in order.
        var castUserOffsets: [(ms: Int, id: String)] { lock.withLock { _castUserOffsets } }
        private var _castUserOffsets: [(ms: Int, id: String)] = []

        func setDevices(_ records: [CastDeviceRecord]) { lock.withLock { _deviceSets.append(records) } }
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
    }

    /// Records the Cast fan-out attaches/detaches; every other capture op is a
    /// no-op, exactly like `NativeBackendTests`' own `FakeCapture`.
    private final class FakeCapture: CaptureControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _onLevel: (@Sendable (Float) -> Void)?
        private var _onStateChange: (@Sendable (NativeCaptureCoordinator.State) -> Void)?
        private var _castSinkCalls: [(isNil: Bool, pid: pid_t?)] = []

        var onLevel: (@Sendable (_ rms: Float) -> Void)? {
            get { lock.withLock { _onLevel } }
            set { lock.withLock { _onLevel = newValue } }
        }
        var onStateChange: (@Sendable (NativeCaptureCoordinator.State) -> Void)? {
            get { lock.withLock { _onStateChange } }
            set { lock.withLock { _onStateChange = newValue } }
        }
        var castSinkCalls: [(isNil: Bool, pid: pid_t?)] { lock.withLock { _castSinkCalls } }

        func start() {}
        func stop() {}
        func setCastSink(_ sink: PCMSink?, renderProcessPID: pid_t?) {
            lock.withLock { _castSinkCalls.append((sink == nil, renderProcessPID)) }
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
    }

    /// `castAbsenceGrace` defaults SHORT so the browse-debounce never adds
    /// seconds to a test that isn't about it; the tests that ARE about it pass
    /// their own value.
    private func makeBackend(
        withBT: Bool = false,
        silenceFallbackDelay: TimeInterval = NativeBackend.defaultSilenceFallbackDelay,
        castAbsenceGrace: TimeInterval = 0.05,
        castOffsetStore: BTTrimStore? = nil
    ) -> Rig {
        let cast = FakeCastEnumerator()
        let manager = FakeCastOutputManager()
        let capture = FakeCapture()
        let bt = FakeBTEnumerator()
        let backend = NativeBackend(
            engineControl: NoOpEngine(),
            discoverySource: NoOpDiscovery(),
            btEnumerator: withBT ? bt : nil,
            castEnumerator: cast,
            castOutputManager: manager,
            castOffsetStore: castOffsetStore,
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            silenceFallbackDelay: silenceFallbackDelay,
            castAbsenceGrace: castAbsenceGrace,
            aggregateControl: NoOpAggregateControl())
        backend.captureCoordinator = capture
        backend.start()
        return Rig(backend: backend, cast: cast, manager: manager, capture: capture, bt: bt)
    }

    private func waitFor(timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
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
        waitFor(timeout: 0.3) { false }
        #expect(Self.device(rig.backend, id)?.isAvailable == true,
                "one omitted browse must not grey the row")

        // Back inside the grace: the pending flip is cancelled, so waiting the
        // whole grace out from here changes nothing.
        rig.cast.fire([Self.graceRecord])
        waitFor(timeout: 1.3) { false }
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
        waitFor(timeout: 0.3) { false }
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
        waitFor(timeout: 0.3) { false }
        rig.backend.setOutputSet([])
        waitFor(timeout: 0.3) { false }

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
        waitFor(timeout: 0.3) { false }
        #expect(Self.device(rig.backend, Self.record.id)?.connectionState == .off,
                "a PLAYING that lands after deselect must not show the row as connected")

        rig.manager.fire(id: Self.record.id, state: .idle)
        waitFor(timeout: 0.3) { false }
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
        waitFor(timeout: 0.5) { false }
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
        waitFor(timeout: 0.3) { false }
        #expect(rig.manager.retries == [Self.record.id], "an unselected receiver has nothing to retry")
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
}
