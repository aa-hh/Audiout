import Foundation
import Testing
import AirPlayEngine
@testable import AudioutCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// BT-ENUM wiring: `NativeBackend` folds ``BTDeviceEnumerator`` snapshots into
/// the SAME `known`/`order`/`emit` flow AirPlay discovery uses — `.bluetooth`
/// rows appear via `deviceAdded`, flip availability via `deviceUpdated`, and
/// never vanish. Hermetic: an injected ``BTDeviceEnumerating`` fake stands in
/// for the real enumerator (no HAL, no IOBluetooth, no Bluetooth TCC), and
/// every other collaborator is the same kind of no-op double
/// `NativeBackendSyncedLocalSelectionTests` keeps.
@Suite final class NativeBackendBTDevicesTests: IsolatedSuite {

    // MARK: Doubles

    private final class FakeBTEnumerator: BTDeviceEnumerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)?
        private var _startCount = 0
        private var _stopCount = 0

        var onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)? {
            get { lock.withLock { _onSnapshot } }
            set { lock.withLock { _onSnapshot = newValue } }
        }
        var startCount: Int { lock.withLock { _startCount } }
        var stopCount: Int { lock.withLock { _stopCount } }

        func start() { lock.withLock { _startCount += 1 } }
        func stop() { lock.withLock { _stopCount += 1 } }
        func refresh() {}
        func requestAuthorizationForUserAction() {}
        func fire(_ snapshots: [BTDeviceSnapshot]) { onSnapshot?(snapshots) }
    }

    /// Minimal no-op `EngineControlling` — BT ids are never fed to the engine,
    /// so nothing here should ever be called beyond lifecycle.
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
        func makeStateStream() -> AsyncStream<(OutputID, OutputState)> {
            AsyncStream { _ in }
        }
        func makeRemoteEventStream() -> AsyncStream<RemoteEvent> {
            AsyncStream { _ in }
        }
        var dacpID: UInt64 { 0 }
        var ptpClockAvailable: Bool { get async { true } }
    }

    private final class NoOpDiscovery: DiscoverySource, @unchecked Sendable {
        var onEvent: (@Sendable (DiscoveryEvent) -> Void)?
        func start() {}
        func stop() {}
    }

    /// No sockets: the real `DACPServer.start(dacpID:)` binds a live
    /// `NWListener` (Local Network prompt) — same reason `NativeBackendTests`
    /// injects its own copy of this.
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
        // Reports the write as landed: these suites describe an ordinary
        // settable output, not the unwritable case the flag exists for.
        func setVolume(_ volume: Int, didWrite: (@Sendable (Bool) -> Void)?) { didWrite?(true) }
        func setMuted(_ muted: Bool) {}
        func start() {}
        func stop() {}
    }

    /// Never touches the real HAL — `stop()` sweeps aggregates unconditionally
    /// (same hermeticity note as the sibling suites' copies).
    private struct NoOpAggregateControl: AggregateDeviceControlling {
        func resolveDeviceID(forUID uid: String) -> AudioObjectID? { nil }
        func createAggregate(uid: String, name: String, subDeviceUID: String) -> AudioObjectID? { nil }
        func destroyAggregate(_ deviceID: AudioObjectID) -> Bool { false }
        func aggregateDeviceUIDs() -> [String] { [] }
        func deviceUID(_ deviceID: AudioObjectID) -> String? { nil }
        func builtInOutputDeviceUID() -> String? { nil }
        func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool { false }
    }

    // MARK: Helpers

    private func makeBackend(trimStore: BTTrimStore? = nil) -> (NativeBackend, FakeBTEnumerator) {
        let bt = FakeBTEnumerator()
        let backend = NativeBackend(
            engineControl: NoOpEngine(),
            discoverySource: NoOpDiscovery(),
            btEnumerator: bt,
            btTrimStore: trimStore,
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            aggregateControl: NoOpAggregateControl())
        return (backend, bt)
    }

    private func waitFor(timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func device(_ backend: NativeBackend, _ id: String) -> Device? {
        backend.devices.first { $0.id == id }
    }

    private let sonos = BTDeviceSnapshot(
        id: "C4-38-75-0E-BF-4A:output", name: "Sonos Move 2", isConnected: true,
        lastUsed: Date(timeIntervalSince1970: 1_780_000_000))
    private let flip = BTDeviceSnapshot(
        id: "70-99-1C-51-8F-A8:output", name: "JBL Flip 5", isConnected: false)

    // MARK: Tests

    /// A snapshot surfaces `.bluetooth` rows through the shared event flow:
    /// connected → available, paired-but-disconnected → greyed, both
    /// `supportsAirPlay2 == false` and non-local, with the recency stashed.
    @Test func snapshotSurfacesBluetoothRows() {
        let (backend, bt) = makeBackend()
        defer { backend.stop() }
        backend.start()
        #expect(bt.startCount == 1, "start() must start the enumerator")

        bt.fire([sonos, flip])
        waitFor { self.device(backend, self.sonos.id) != nil && self.device(backend, self.flip.id) != nil }

        let connected = device(backend, sonos.id)
        #expect(connected?.kind == .bluetooth)
        #expect(connected?.isAvailable == true)
        #expect(connected?.supportsAirPlay2 == false)
        #expect(connected?.isLocalDevice == false)
        #expect(connected?.name == "Sonos Move 2")

        let disconnected = device(backend, flip.id)
        #expect(disconnected?.kind == .bluetooth)
        #expect(disconnected?.isAvailable == false,
                "a paired-but-disconnected speaker exists as a greyed row, not a missing one")

        #expect(backend.lastUsedDatesForBTDevices()[sonos.id] == sonos.lastUsed,
                "pairing recency is available for the UI wave's ghost-row filtering")
    }

    /// A connect/disconnect edge is an availability flip on the SAME row —
    /// same greyed-not-vanished contract as AirPlay, same stable id.
    @Test func disconnectFlipsAvailabilityAndKeepsTheRow() {
        let (backend, bt) = makeBackend()
        defer { backend.stop() }
        backend.start()

        bt.fire([sonos])
        waitFor { self.device(backend, self.sonos.id)?.isAvailable == true }

        bt.fire([BTDeviceSnapshot(id: sonos.id, name: sonos.name, isConnected: false)])
        waitFor { self.device(backend, self.sonos.id)?.isAvailable == false }
        #expect(device(backend, sonos.id)?.isAvailable == false)

        bt.fire([sonos])
        waitFor { self.device(backend, self.sonos.id)?.isAvailable == true }
        #expect(device(backend, sonos.id)?.isAvailable == true)
        #expect(backend.devices.filter { $0.id == sonos.id }.count == 1,
                "disconnect/rejoin must never split one speaker into two rows")
    }

    /// A device that leaves the merged list entirely (unpaired mid-session)
    /// goes unavailable but keeps its row — mirrors `markDisappeared`.
    @Test func vanishedDeviceGoesUnavailableNotRemoved() {
        let (backend, bt) = makeBackend()
        defer { backend.stop() }
        backend.start()

        bt.fire([sonos, flip])
        waitFor { self.device(backend, self.sonos.id) != nil }

        bt.fire([flip])
        waitFor { self.device(backend, self.sonos.id)?.isAvailable == false }
        #expect(device(backend, sonos.id) != nil, "the row survives")
        #expect(device(backend, sonos.id)?.isAvailable == false)
    }

    /// `stop()` unwires and stops the enumerator symmetrically with discovery.
    @Test func stopStopsTheEnumerator() {
        let (backend, bt) = makeBackend()
        backend.start()
        backend.stop()
        #expect(bt.stopCount == 1)
        #expect(bt.onSnapshot == nil, "stop() must unwire the snapshot callback")
    }

    // MARK: "Not paired" tier (device-tier decision 2)

    /// A BT row whose pairing record was deleted out from under the app (the
    /// id left the enumerator's merged list, the row survives) fails FAST on
    /// retry — `.notPaired`, no baseband attempt, and the copy names the
    /// Bluetooth-Settings fix.
    @Test func retryOnAnUnpairedRowFailsFastAsNotPaired() {
        let (backend, bt) = makeBackend()
        defer { backend.stop() }
        backend.start()

        bt.fire([sonos, flip])
        waitFor { self.device(backend, self.sonos.id) != nil && self.device(backend, self.flip.id) != nil }

        bt.fire([flip])   // sonos's pairing record is gone; its row survives
        waitFor { self.device(backend, self.sonos.id)?.isAvailable == false }

        backend.retryOutput(sonos.id)
        waitFor {
            if case .failed = self.device(backend, self.sonos.id)?.connectionState { return true }
            return false
        }
        guard case .failed(let failure)? = device(backend, sonos.id)?.connectionState else {
            Issue.record("expected a .failed state"); return
        }
        #expect(failure.cause == .notPaired)
        #expect(failure.headline == "Not paired")
        #expect(failure.suggestion.contains("Pair it again in Bluetooth Settings"))
    }

    /// A STILL-paired greyed row's retry is NOT misclassified: with no
    /// connection manager wired, the retry is simply consumed (the BT arm owns
    /// the id) and never lands `.notPaired`.
    @Test func retryOnAPairedRowNeverClassifiesNotPaired() {
        let (backend, bt) = makeBackend()
        defer { backend.stop() }
        backend.start()

        bt.fire([sonos, flip])
        waitFor { self.device(backend, self.flip.id) != nil }

        backend.retryOutput(flip.id)   // flip IS in the merged list (paired)
        waitFor(timeout: 0.3) { false }
        if case .failed(let failure)? = device(backend, flip.id)?.connectionState {
            #expect(failure.cause != .notPaired, "pairedness comes from the merged list, not availability")
        }
    }

    // MARK: SYNC trim persistence (BT-OFFSET-UI)

    /// `setBTSyncTrim` clamps to ±`BTSyncTrim.rangeMs`, and a NEW backend over
    /// the same store reads the value back — the relaunch-restore half of the
    /// round-trip (reconnect-restore is the sink re-push, covered in
    /// `NativeBackendBTSelectionTests`).
    @Test func trimRoundTripsThroughTheStoreAcrossBackendInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bt-trims-\(UUID().uuidString)", isDirectory: true)
        let store = BTTrimStore(directory: directory)

        let (first, _) = makeBackend(trimStore: store)
        first.setBTSyncTrim(620, forDevice: sonos.id, persist: true)   // clamps to 500
        first.setBTSyncTrim(-40, forDevice: flip.id, persist: true)
        #expect(first.btSyncTrim(forDevice: sonos.id) == 500)
        #expect(first.btSyncTrim(forDevice: flip.id) == -40)
        first.stop()

        let (second, _) = makeBackend(trimStore: store)
        #expect(second.btSyncTrim(forDevice: sonos.id) == 500,
                "a relaunched backend restores the persisted trim")
        #expect(second.btSyncTrim(forDevice: flip.id) == -40)
        #expect(second.btSyncTrim(forDevice: "never-set:output") == 0)
        #expect(second.btHasSyncTrim(forDevice: sonos.id))
        #expect(!second.btHasSyncTrim(forDevice: "never-set:output"),
                "D10's honest signal: no ENTRY, not merely a zero value")
        second.stop()
    }

    /// The backend still supports an apply-without-persist write (`persist:
    /// false`) even though the drawer's only controls are now committing
    /// steppers — the seam is kept for a future live control and must behave:
    /// the value updates in memory (quantised to whole ms on the way in, T7
    /// §7) but nothing reaches the JSON store, so a relaunch sees no trim.
    @Test func applyWithoutPersistUpdatesInMemoryButNeverWritesTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bt-trims-\(UUID().uuidString)", isDirectory: true)
        let store = BTTrimStore(directory: directory)

        let (first, _) = makeBackend(trimStore: store)
        first.setBTSyncTrim(31.6, forDevice: sonos.id, persist: false)
        #expect(first.btSyncTrim(forDevice: sonos.id) == 32,
                "quantised to whole ms on the way in (T7 §7), and readable immediately")
        first.stop()

        let (second, _) = makeBackend(trimStore: store)
        #expect(second.btSyncTrim(forDevice: sonos.id) == 0,
                "nothing was written, so a relaunch sees no trim")
        second.stop()
    }

    /// T3: with no `btSyncedSinkFactory` wired (this suite's posture — see
    /// `makeBackend`), `btSink` never exists, so `btUsableTrimRangeMs` must
    /// fall through to the protocol's own full-±range default rather than
    /// crash or hang on the `captureControlQueue.sync` hop.
    @Test func usableTrimRangeMsDefaultsToFullRangeWithNoBTSink() {
        let (backend, _) = makeBackend()
        #expect(backend.btUsableTrimRangeMs(forDevice: sonos.id)
                == -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
        backend.stop()
    }
}
