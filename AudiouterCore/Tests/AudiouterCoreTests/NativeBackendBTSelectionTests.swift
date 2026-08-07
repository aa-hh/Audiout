import Foundation
import Testing
import AirPlayEngine
@testable import AudiouterCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// BT-BACKEND (R-partition): `setOutputSet` splits the expected set into
/// {AirPlay ids → engine converge} and {`.bluetooth` ids → `BTSyncedSink`
/// enable/disable}, recomputes the group composition (BT-REFSEL) on every
/// selection change, and the capture gate/silence fallback treat a BT-only
/// selection correctly. Hermetic: a recording engine, an injected
/// ``BTDeviceEnumerating`` fake feeding `.bluetooth` rows, a
/// ``BTSyncedSinkControlling`` spy behind `btSyncedSinkFactory`, and a
/// recording ``CaptureControlling`` fake — the same double style the sibling
/// `NativeBackendSyncedLocalSelectionTests` keeps.
@Suite final class NativeBackendBTSelectionTests: IsolatedSuite {

    // MARK: Doubles

    /// Records engine ops — the "no BT id ever reaches the AirPlay engine"
    /// assertions read `addedIDs`/`fedIDs`.
    private final class RecordingEngine: EngineControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _fed: [OutputID] = []
        private var _added: [OutputID] = []
        private var _removed: [OutputID] = []

        var fedIDs: [OutputID] { lock.withLock { _fed } }
        var addedIDs: [OutputID] { lock.withLock { _added } }
        var removedIDs: [OutputID] { lock.withLock { _removed } }

        func start() async throws {}
        func stop() async {}
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            let id = descriptor.parsedID ?? OutputID(rawValue: 0)
            lock.withLock { _fed.append(id) }
            return id
        }
        func removeDiscovery(_ descriptor: DeviceDescriptor) async {}
        func addOutput(_ id: OutputID) async throws { lock.withLock { _added.append(id) } }
        func addOutput(_ id: OutputID, streamId: UInt32) async throws { lock.withLock { _added.append(id) } }
        func removeOutput(_ id: OutputID) async throws { lock.withLock { _removed.append(id) } }
        func setVolume(_ id: OutputID, _ volume: Double) async throws {}
        func setStartBufferMs(_ ms: Int) async {}
        func write(pcm: Data, streamId: UInt32, pts: timespec) {}
        func makeStateStream() -> AsyncStream<(OutputID, OutputState)> { AsyncStream { _ in } }
        func makeRemoteEventStream() -> AsyncStream<RemoteEvent> { AsyncStream { _ in } }
        var dacpID: UInt64 { 0 }
        var ptpClockAvailable: Bool { get async { true } }
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
        func fire(_ snapshots: [BTDeviceSnapshot]) { onSnapshot?(snapshots) }
    }

    private final class FakeDiscovery: DiscoverySource, @unchecked Sendable {
        var onEvent: (@Sendable (DiscoveryEvent) -> Void)?
        func start() {}
        func stop() {}
        func fire(_ event: DiscoveryEvent) { onEvent?(event) }
    }

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
        func setVolume(_ volume: Int) {}
        func setMuted(_ muted: Bool) {}
        func start() {}
        func stop() {}
    }

    private struct NoOpAggregateControl: AggregateDeviceControlling {
        func resolveDeviceID(forUID uid: String) -> AudioObjectID? { nil }
        func createAggregate(uid: String, name: String, subDeviceUID: String) -> AudioObjectID? { nil }
        func destroyAggregate(_ deviceID: AudioObjectID) -> Bool { false }
        func aggregateDeviceUIDs() -> [String] { [] }
        func deviceUID(_ deviceID: AudioObjectID) -> String? { nil }
        func builtInOutputDeviceUID() -> String? { nil }
        func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool { false }
    }

    private struct AlwaysReadyPTPHelperActivator: PTPHelperActivating {
        var willWaitForClock: Bool { false }
        func activate(timeout: TimeInterval) async -> PTPHelperActivationOutcome { .ready }
    }

    /// Records the whole-system capture gate + the BT fan-out attach seam.
    private final class FakeCapture: CaptureControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _ops: [String] = []
        var onLevel: (@Sendable (_ rms: Float) -> Void)? {
            get { nil }
            set { }
        }
        var onStateChange: (@Sendable (_ state: NativeCaptureCoordinator.State) -> Void)? {
            get { nil }
            set { }
        }
        func start() { lock.withLock { _ops.append("start") } }
        func stop() { lock.withLock { _ops.append("stop") } }
        func setBTSink(_ sink: SyncedLocalPCMSink?, renderProcessPID: pid_t?) {
            lock.withLock { _ops.append(sink == nil ? "btDetach" : "btAttach:\(renderProcessPID ?? -1)") }
        }
        var ops: [String] { lock.withLock { _ops } }
    }

    /// Inert `LogStreamSpawning` stand-in (same D7 hermeticity convention as
    /// `NativeBackendTests`): a non-empty selection starts the handoff watcher,
    /// whose production factory posix_spawns `/usr/bin/log stream`.
    private final class NoOpLogStream: LogStreamSpawning, @unchecked Sendable {
        func start(onLine: @escaping @Sendable (String) -> Void,
                   onTermination: @escaping @Sendable () -> Void) throws {}
        func stop() {}
        var isRunning: Bool { false }
    }

    /// A `BTSyncedSinkControlling` spy recording every call, in order.
    private final class SpyBTSink: BTSyncedSinkControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _deviceSets: [[BTSyncedSink.DeviceSpec]] = []
        private var _compositions: [BTGroupComposition] = []

        func start() { lock.withLock { _calls.append("start") } }
        func stop() { lock.withLock { _calls.append("stop") } }
        func setDevices(_ specs: [BTSyncedSink.DeviceSpec]) {
            lock.withLock { _calls.append("setDevices"); _deviceSets.append(specs) }
        }
        func setComposition(_ composition: BTGroupComposition) {
            lock.withLock { _calls.append("setComposition"); _compositions.append(composition) }
        }
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {}

        var calls: [String] { lock.withLock { _calls } }
        var deviceSets: [[BTSyncedSink.DeviceSpec]] { lock.withLock { _deviceSets } }
        var compositions: [BTGroupComposition] { lock.withLock { _compositions } }
    }

    // MARK: Fixtures + helpers

    private let btMove = BTDeviceSnapshot(id: "C4-38-75-0E-BF-4A:output", name: "Move 2", isConnected: true)
    private let btFlip = BTDeviceSnapshot(id: "70-99-1C-51-8F-A8:output", name: "Flip 5", isConnected: true)

    private func ap2Device(id: String = "AA:BB:CC:DD:EE:01", name: String = "Sonos Move") -> DiscoveredDevice {
        let txt = ["deviceid": id, "model": "S13", "features": "0x445F8A00,0x1C340"]
        let (parsedID, outputID) = NativeDiscovery.parseDeviceID(txt)!
        let desc = DeviceDescriptor(name: name, address: "192.168.1.10", family: .ipv4, port: 7000, txtRecord: txt)
        return DiscoveredDevice(id: parsedID, descriptor: desc, outputID: outputID, isAirPlay2Supported: true)
    }

    private func makeBackend(
        silenceFallbackDelay: TimeInterval = NativeBackend.defaultSilenceFallbackDelay
    ) -> (NativeBackend, RecordingEngine, FakeDiscovery, FakeBTEnumerator, SpyBTSink, FakeCapture) {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let bt = FakeBTEnumerator()
        let backend = NativeBackend(
            engineControl: engine,
            discoverySource: discovery,
            btEnumerator: bt,
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            ptpHelperActivator: AlwaysReadyPTPHelperActivator(),
            silenceFallbackDelay: silenceFallbackDelay,
            systemDefaultOutputIsAirPlayClass: { false },
            aggregateControl: NoOpAggregateControl(),
            handoffWatcherFactory: { onBlockedAttempt in
                AirPlayHandoffWatcher(spawn: NoOpLogStream(), onBlockedAttempt: onBlockedAttempt)
            })
        let sink = SpyBTSink()
        backend.btSyncedSinkFactory = { sink }
        // Deterministic UID → AudioObjectID mapping, no HAL: hash of the uid.
        backend.btDeviceIDForUID = { uid in AudioObjectID(1000 + UInt32(abs(uid.hashValue % 1000))) }
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        return (backend, engine, discovery, bt, sink, capture)
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

    // MARK: - Partition: BT-only selection

    /// BT-only selection: the sink manager is armed (composition → devices →
    /// attach → start), the capture tap turns ON (the gate's `!isLocalDevice`
    /// intent test includes BT ids), and the AirPlay engine sees NOTHING.
    @Test func btOnlySelectionEnablesSinkAndCaptureNeverTheEngine() {
        let (backend, engine, _, bt, sink, capture) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }

        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }

        #expect(sink.calls == ["setComposition", "setDevices", "start"],
                "enable order: reference first, then the device set, then start")
        #expect(sink.compositions.last == BTGroupComposition(airPlayPresent: false, macLocalPresent: false))
        #expect(sink.deviceSets.last?.map(\.uid) == [btMove.id])
        #expect(capture.ops.contains("start"), "a BT-only selection trips the whole-system capture gate")
        #expect(capture.ops.contains { $0.hasPrefix("btAttach") }, "the fan-out is attached")
        #expect(engine.addedIDs.isEmpty, "no BT id may ever reach the AirPlay engine")
        #expect(engine.fedIDs.isEmpty, "BT devices are never fed to engine discovery either")
    }

    /// Deselecting the last BT device disables the sink (stop → drop devices →
    /// detach) and releases the capture gate.
    @Test func deselectingLastBTDisablesSinkAndStopsCapture() {
        let (backend, _, _, bt, sink, capture) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }

        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }

        backend.setOutputSet([])
        waitFor { sink.calls.contains("stop") }

        #expect(sink.calls == ["setComposition", "setDevices", "start", "stop", "setDevices"],
                "disable mirrors enable: stop, then drop the per-device sinks")
        #expect(sink.deviceSets.last?.isEmpty == true)
        #expect(capture.ops.contains("stop"), "an empty selection releases the capture gate")
        #expect(capture.ops.contains("btDetach"), "the fan-out is detached")
    }

    /// Mixed selection routes each id to exactly one owner: the AirPlay id
    /// converges through the engine, the BT id lands in the sink's device set,
    /// and neither crosses over.
    @Test func mixedSelectionRoutesEachIdToExactlyOneOwner() {
        let (backend, engine, discovery, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()

        let ap = ap2Device()
        discovery.fire(.appeared(ap))
        bt.fire([btMove])
        waitFor { self.device(backend, ap.id) != nil && self.device(backend, self.btMove.id) != nil }
        waitFor { engine.fedIDs.contains(ap.outputID) }

        backend.setOutputSet([ap.id, btMove.id])
        waitFor { engine.addedIDs.contains(ap.outputID) && sink.calls.contains("start") }

        #expect(engine.addedIDs == [ap.outputID],
                "exactly the AirPlay id converges through the engine — never the BT id")
        #expect(sink.deviceSets.last?.map(\.uid) == [btMove.id],
                "exactly the BT id lands in the sink manager — never the AirPlay id")
        #expect(sink.compositions.last?.airPlayPresent == true,
                "an AirPlay member makes the AirPlay presentation timeline the reference")
    }

    /// The composition is recomputed on every selection change: AirPlay
    /// joining/leaving a BT-containing selection re-feeds the sink manager.
    @Test func compositionRecomputesOnSelectionChange() {
        let (backend, engine, discovery, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()

        let ap = ap2Device()
        discovery.fire(.appeared(ap))
        bt.fire([btMove])
        waitFor { self.device(backend, ap.id) != nil && self.device(backend, self.btMove.id) != nil }
        waitFor { engine.fedIDs.contains(ap.outputID) }

        backend.setOutputSet([btMove.id])                     // BT-only
        waitFor { sink.compositions.count == 1 }
        #expect(sink.compositions.last?.airPlayPresent == false)

        backend.setOutputSet([btMove.id, ap.id])              // AirPlay joins
        waitFor { sink.compositions.count == 2 }
        #expect(sink.compositions.last?.airPlayPresent == true)

        backend.setOutputSet([btMove.id])                     // AirPlay leaves
        waitFor { sink.compositions.count == 3 }
        #expect(sink.compositions.last?.airPlayPresent == false)
    }

    /// BT+BT: both selected BT devices land in ONE device set (one manager, N
    /// sinks), and reconciling to one keeps the sink armed with the remainder.
    @Test func multiBTSelectionReconcilesDeviceSet() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btMove.id) != nil && self.device(backend, self.btFlip.id) != nil }

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { sink.calls.contains("start") }
        #expect(sink.deviceSets.last?.map(\.uid).sorted() == [btFlip.id, btMove.id].sorted())

        backend.setOutputSet([btFlip.id])
        waitFor { sink.deviceSets.count >= 2 }
        #expect(sink.deviceSets.last?.map(\.uid) == [btFlip.id],
                "dropping one BT device reconciles the set; the manager stays armed")
        #expect(!sink.calls.contains("stop"), "a non-empty BT selection never disables the manager")
    }

    /// A membership-neutral routing call (same set re-applied) enqueues NO BT
    /// work — the running sinks are never touched by unrelated traffic.
    @Test func unchangedSelectionReappliesNothing() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }

        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        let callsAfterEnable = sink.calls.count

        backend.setOutputSet([btMove.id])   // membership-neutral
        waitFor(timeout: 0.3) { false }
        #expect(sink.calls.count == callsAfterEnable,
                "an unchanged BT decision must not re-drive the sink manager")
    }

    /// `retryOutput` on a BT id is engine-inert: no engine handle, no converge.
    @Test func retryOfBTIdNeverReachesEngine() {
        let (backend, engine, _, bt, _, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }

        backend.setOutputSet([btMove.id])
        backend.retryOutput(btMove.id)
        waitFor(timeout: 0.3) { false }
        #expect(engine.addedIDs.isEmpty, "a BT retry must not invent an engine op")
    }

    /// No factory wired: a BT selection is inert (no crash) — the UI-only
    /// smoke posture, mirroring the synced-local sibling.
    @Test func noFactoryWiredIsInert() {
        let (backend, _, _, bt, _, _) = makeBackend()
        backend.btSyncedSinkFactory = nil
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor(timeout: 0.2) { false }
        // Passes by not crashing; nothing to observe without a sink.
    }

    // MARK: - Silence fallback partition (R-partition)

    /// An AVAILABLE BT-only selection is NOT stranded: its audible fact is
    /// `isAvailable` (a BT id never reaches `.connected`), so the silence
    /// fallback must not un-mute the Mac mid-playback.
    @Test func availableBTOnlySelectionDoesNotTripSilenceFallback() {
        let (backend, _, _, bt, sink, capture) = makeBackend(silenceFallbackDelay: 0.1)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])   // connected → isAvailable
        waitFor { self.device(backend, self.btMove.id)?.isAvailable == true }

        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        waitFor(timeout: 0.5) { false }   // give a (wrong) fallback time to fire

        #expect(!capture.ops.contains("stop"),
                "an audible BT-only selection must never un-gate capture (the Mac stays muted)")
    }

    /// The converse: a selected-but-DISCONNECTED BT speaker is genuine silence,
    /// so the fallback fires — and the speaker reconnecting clears it again
    /// (the availability edge re-runs the watchdog reconcile).
    @Test func unavailableBTSelectionTripsFallbackAndReconnectClearsIt() {
        let (backend, _, _, bt, sink, capture) = makeBackend(silenceFallbackDelay: 0.1)
        defer { backend.stop() }
        backend.start()
        bt.fire([BTDeviceSnapshot(id: btMove.id, name: btMove.name, isConnected: false)])
        waitFor { self.device(backend, self.btMove.id) != nil }

        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        // Stranded: nothing audible → the watchdog fires and un-gates capture.
        waitFor { capture.ops.contains("stop") }
        #expect(capture.ops.contains("stop"),
                "a dead BT-only selection falls back to the Mac's own speakers")

        // The speaker reconnects: the availability edge re-reconciles and the
        // gate re-engages (audio moves back to the BT sink; Mac re-mutes).
        bt.fire([btMove])
        waitFor { capture.ops.filter { $0 == "start" }.count >= 2 }
        #expect(capture.ops.filter { $0 == "start" }.count >= 2,
                "the BT speaker returning re-engages the capture gate")
    }
}
