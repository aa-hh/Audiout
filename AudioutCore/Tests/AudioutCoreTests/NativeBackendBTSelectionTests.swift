import Foundation
import Testing
import AirPlayEngine
@testable import AudioutCore

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
        private var _userActionAsks = 0
        /// How often a user gesture asked for the Bluetooth grant (the ask the
        /// enumerator no longer fires at backend start).
        var userActionAsks: Int { lock.withLock { _userActionAsks } }
        func start() {}
        func stop() {}
        func refresh() {}
        func requestAuthorizationForUserAction() { lock.withLock { _userActionAsks += 1 } }
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
        // Reports the write as landed: these suites describe an ordinary
        // settable output, not the unwritable case the flag exists for.
        func setVolume(_ volume: Int, didWrite: (@Sendable (Bool) -> Void)?) { didWrite?(true) }
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
        private var _onLevel: (@Sendable (_ rms: Float) -> Void)?
        /// Stored, not discarded: the BT-METER tests call it to push one RMS
        /// sample down the real metering path.
        var onLevel: (@Sendable (_ rms: Float) -> Void)? {
            get { lock.withLock { _onLevel } }
            set { lock.withLock { _onLevel = newValue } }
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
        func setAlignTick(_ active: Bool) {
            lock.withLock { _ops.append(active ? "tickOn" : "tickOff") }
        }
        /// CAST-SYNC: every AirPlay pre-delay the backend asks for, in order.
        private var _preDelayMs: [Int] = []
        func setAirPlayPreDelay(ms: Int) { lock.withLock { _preDelayMs.append(ms) } }
        var preDelayMs: [Int] { lock.withLock { _preDelayMs } }
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

    /// The Mac's own membership, flipped mid-test: `setOutputSet` reads it
    /// through `selectedDevicesQuery` (the local device has no engine handle,
    /// so it is never in the output set itself), and that read happens on the
    /// backend's own queue — hence the lock.
    private final class LockedBool: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        func get() -> Bool { lock.withLock { value } }
        func set(_ v: Bool) { lock.withLock { value = v } }
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
        func setTrimMs(_ ms: Double, forDeviceUID uid: String) {
            lock.withLock { _calls.append("setTrimMs"); _trims.append((ms: ms, uid: uid)) }
        }
        func setGain(_ gain: Float, forDeviceUID uid: String) {
            lock.withLock { _calls.append("setGain"); _gains.append((gain: gain, uid: uid)) }
        }
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {}

        /// Which devices are "audible" right now — the test drives the render
        /// signal a real `BTSyncedSink` reads off its per-device delay gates.
        var renderingUIDs: Set<String> {
            get { lock.withLock { _rendering } }
            set { lock.withLock { _rendering = newValue } }
        }
        func renderingDeviceUIDs() -> Set<String> { renderingUIDs }
        private var _rendering: Set<String> = []
        /// `nil` (the protocol default) means "can't tell", which the backend
        /// reads as anchored — set this to an explicit set to model a SILENT
        /// Mac, where no sink is ever handed a buffer.
        var anchoredUIDs: Set<String>? {
            get { lock.withLock { _anchored } }
            set { lock.withLock { _anchored = newValue } }
        }
        func anchoredDeviceUIDs() -> Set<String>? { anchoredUIDs }
        private var _anchored: Set<String>?

        var calls: [String] { lock.withLock { _calls } }
        var deviceSets: [[BTSyncedSink.DeviceSpec]] { lock.withLock { _deviceSets } }
        var compositions: [BTGroupComposition] { lock.withLock { _compositions } }
        private var _trims: [(ms: Double, uid: String)] = []
        var trims: [(ms: Double, uid: String)] { lock.withLock { _trims } }
        private var _gains: [(gain: Float, uid: String)] = []
        var gains: [(gain: Float, uid: String)] { lock.withLock { _gains } }
        func lastGain(for uid: String) -> Float? {
            lock.withLock { _gains.last { $0.uid == uid }?.gain }
        }
        /// Call order with the per-device gain seeds stripped — for the
        /// lifecycle-order assertions, which don't care how many uids got a
        /// gain pushed between `setComposition` and `setDevices`.
        var lifecycleCalls: [String] { calls.filter { $0 != "setGain" } }
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

    /// A `BTConnectionManaging` fake with a scriptable outcome (BT-RECONNECT).
    private final class FakeBTConnectionManager: BTConnectionManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var _outcome: BTConnectOutcome = .connected
        private var _connects: [String] = []
        var onConnectionsChanged: (@Sendable () -> Void)?
        var onFallbackSuggested: (@Sendable (String) -> Void)?
        var outcome: BTConnectOutcome {
            get { lock.withLock { _outcome } }
            set { lock.withLock { _outcome = newValue } }
        }
        var connects: [String] { lock.withLock { _connects } }
        func connect(address: String) async -> BTConnectOutcome {
            lock.withLock { _connects.append(address) }
            return outcome
        }
        func disconnect(address: String) {}
        func startObservingConnections() {}
        func stopObservingConnections() {}
    }

    private func makeBackend(
        silenceFallbackDelay: TimeInterval = NativeBackend.defaultSilenceFallbackDelay,
        btConnection: BTConnectionManaging? = nil,
        btRenderStartTimeout: TimeInterval = 6
    ) -> (NativeBackend, RecordingEngine, FakeDiscovery, FakeBTEnumerator, SpyBTSink, FakeCapture) {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let bt = FakeBTEnumerator()
        let backend = NativeBackend(
            engineControl: engine,
            discoverySource: discovery,
            btEnumerator: bt,
            btConnectionManager: btConnection,
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
        backend.btRenderStartTimeout = btRenderStartTimeout
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

        #expect(sink.lifecycleCalls == ["setComposition", "setDevices", "start"],
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

        #expect(sink.lifecycleCalls == ["setComposition", "setDevices", "start", "stop", "setDevices"],
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

    /// Fix 3 (Mac-join desync): a Mac toggle alone — `selectedDevicesQuery`
    /// flips but `setOutputSet` re-runs with the SAME AirPlay+BT ids (the
    /// `add=[] rm=[]` shape) — must not push a composition. `macLocalPresent`
    /// never changes a BT delay, so a spurious push would rebuild every BT
    /// sink into ~570 ms of silence for no reason.
    @Test func macToggleAloneDoesNotPushComposition() {
        let (backend, _, discovery, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        let macSelected = LockedBool(false)
        backend.selectedDevicesQuery = { id in
            id == NativeBackend.localDeviceID ? macSelected.get() : false
        }
        backend.start()

        let ap = ap2Device()
        discovery.fire(.appeared(ap))
        bt.fire([btMove])
        waitFor { self.device(backend, ap.id) != nil && self.device(backend, self.btMove.id) != nil }

        backend.setOutputSet([btMove.id, ap.id])
        waitFor { sink.calls.contains("start") }
        let compositionPushes = sink.calls.filter { $0 == "setComposition" }.count

        macSelected.set(true)
        backend.setOutputSet([btMove.id, ap.id])   // same ids — the Mac-toggle shape
        waitFor(timeout: 0.3) { false }

        #expect(sink.calls.filter { $0 == "setComposition" }.count == compositionPushes,
                "a Mac toggle alone must not push a composition")
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

    // MARK: - BT-RECONNECT (Wave 4)

    /// `retryOutput` on a BT id runs the connect flow: eager `.connecting`,
    /// then `.connected` once the sink is audible — and the sink decision is
    /// re-applied so a selected id re-enters the per-device set without a
    /// selection change.
    @Test func btRetrySuccess_connectingThenConnected_andSinkReapplied() {
        let manager = FakeBTConnectionManager()
        let (backend, _, _, bt, sink, _) = makeBackend(btConnection: manager)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        // Let the SELECT's own hold settle first: a row that is already
        // breathing refuses a retry (never two attempts in flight), so the
        // retry path is only reachable from a settled row.
        sink.renderingUIDs = [btMove.id]
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connected }
        sink.renderingUIDs = []
        let appliesBefore = sink.deviceSets.count

        backend.retryOutput(btMove.id)
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connecting }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.connecting,
                "a baseband connect is not yet audio — the row keeps breathing")
        sink.renderingUIDs = [btMove.id]
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connected }

        #expect(manager.connects == ["C4-38-75-0E-BF-4A"],
                "the uid's :output suffix is stripped to the bare MAC")
        #expect(device(backend, btMove.id)?.connectionState == .connected)
        waitFor { sink.deviceSets.count > appliesBefore }
        #expect(sink.deviceSets.count > appliesBefore,
                "a successful reconnect re-applies the sink decision (Wave-3 gap closed)")
    }

    /// The enumerator no longer asks for the Bluetooth grant at backend start
    /// (setup's own card owns the prompt), so a user reaching for a Bluetooth row
    /// is the fallback asker — otherwise someone who skipped that card has no
    /// in-app path to the prompt and every attempt is a silent `.unauthorized`.
    @Test func btRetryAsksForTheGrantOnTheUserGesture() {
        let manager = FakeBTConnectionManager()
        let (backend, _, _, bt, _, _) = makeBackend(btConnection: manager)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        #expect(bt.userActionAsks == 0, "no gesture yet ⇒ no ask")

        backend.retryOutput(btMove.id)
        waitFor { bt.userActionAsks == 1 }
        #expect(bt.userActionAsks == 1)
    }

    /// A FAST refusal is the live-measured signature of a speaker another host
    /// holds — `.failed(.connectedElsewhere)`; the slow OS horizon (or our
    /// ceiling) reads `.failed(.timedOut)`.
    @Test func btRetryFailureClassification_fastVsSlow() {
        let manager = FakeBTConnectionManager()
        let (backend, _, _, bt, _, _) = makeBackend(btConnection: manager)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }

        manager.outcome = .failed(elapsed: 1.2, reason: "0xe00002d6")
        backend.retryOutput(btMove.id)
        waitFor {
            if case .failed(let f) = self.device(backend, self.btMove.id)?.connectionState {
                return f.cause == .connectedElsewhere
            }
            return false
        }
        guard case .failed(let fast) = device(backend, btMove.id)?.connectionState else {
            Issue.record("expected .failed"); return
        }
        #expect(fast.cause == .connectedElsewhere)

        manager.outcome = .failed(elapsed: 15.4, reason: "0xe00002d6")
        backend.retryOutput(btMove.id)
        waitFor {
            if case .failed(let f) = self.device(backend, self.btMove.id)?.connectionState {
                return f.cause == .unknown
            }
            return false
        }
        guard case .failed(let slow) = device(backend, btMove.id)?.connectionState else {
            Issue.record("expected .failed"); return
        }
        #expect(slow.cause == .unknown, #""Couldn't connect", matching AirPlay's generic failure"#)
    }

    /// Availability-loss handling moved UPSTREAM (Alec's deselect-on-power-off
    /// decision: the popover deselects on the loss edge via
    /// `GroupController.setDeviceSelected` — see `BTPopoverRowsTests`). The
    /// backend contract that remains: a loss reads `.off` and, once the
    /// routing brain's deselect lands as a plain `setOutputSet` drop, the sink
    /// set empties — while a return with the selection STILL intact resumes,
    /// because intact selection is deliberate intent (the greyed-row "play
    /// when up" select).
    @Test func btLossReadsOffDeselectDropsTheSinkAndIntactSelectionResumes() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        sink.renderingUIDs = [btMove.id]

        // Power off: the row reads .off; the routing brain's deselect (the
        // popover's loss-edge reaction) reaches the backend as a plain drop.
        bt.fire([BTDeviceSnapshot(id: btMove.id, name: btMove.name, isConnected: false)])
        waitFor { self.device(backend, self.btMove.id)?.isAvailable == false }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.off)
        backend.setOutputSet([])
        waitFor { sink.calls.contains("stop") }
        waitFor { sink.deviceSets.last?.isEmpty == true }

        // Return while UNselected: available, .off, sink set stays empty.
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id)?.isAvailable == true }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.off,
                "returning unselected must not read .connected")
        #expect(sink.deviceSets.last?.isEmpty == true, "…and must not re-enter the sink set")

        // The user selects again → plays.
        backend.setOutputSet([btMove.id])
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connected }
        waitFor { sink.deviceSets.last?.map(\.uid) == [self.btMove.id] }
        #expect(sink.deviceSets.last?.map(\.uid) == [btMove.id])
    }

    /// The other half of the contract: a return while the selection is STILL
    /// intact (nothing deselected it — the user picked a greyed row, "play
    /// when up") auto-starts. This was the park's false negative: it also
    /// blocked exactly this deliberate intent after a power-off round-trip.
    @Test func btReturnWhileStillSelectedResumes() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        sink.renderingUIDs = [btMove.id]

        bt.fire([BTDeviceSnapshot(id: btMove.id, name: btMove.name, isConnected: false)])
        waitFor { self.device(backend, self.btMove.id)?.isAvailable == false }
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connected }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.connected,
                "selection intact across the loss = deliberate intent — the return resumes")
        waitFor { sink.deviceSets.last?.map(\.uid) == [self.btMove.id] }
        #expect(sink.deviceSets.last?.map(\.uid) == [btMove.id],
                "the reconnect-reapply re-enters the applied set")
    }

    // MARK: - BT-LIFECYCLE: breathing until the music starts

    /// Selecting an ALREADY-AVAILABLE BT speaker still runs a full connect
    /// story: the row breathes from the click until that device's own sink is
    /// audible, then lands `.connected` — the state the armed dot and the meter
    /// both gate on.
    @Test func selectingAvailableBTBreathesUntilTheSinkRenders() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id)?.isAvailable == true }

        backend.setOutputSet([btMove.id])
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connecting }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.connecting,
                "the ring breathes from the click, not from a later edge")

        // The engine being up is not yet audio: the hold survives a started
        // sink and ends only when the delay gate opens.
        waitFor(timeout: 0.3) { false }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.connecting,
                "a started-but-silent sink must not light the armed dot")

        sink.renderingUIDs = [btMove.id]
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connected }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.connected)
    }

    /// Only the device that is actually rendering is promoted — a second BT
    /// speaker whose sink is still silent keeps breathing on its own.
    @Test func onlyTheRenderingDeviceIsPromoted() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id)?.isAvailable == true }

        backend.setOutputSet([btMove.id, btFlip.id])
        sink.renderingUIDs = [btMove.id]
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connected }
        #expect(device(backend, btFlip.id)?.connectionState == ConnectionState.connecting,
                "the silent speaker keeps its own spinner")
    }

    /// A successful connect on an UNSELECTED row goes straight to `.off`:
    /// nothing will ever flow to it by design, so a hold could only spin
    /// forever.
    @Test func connectWhileUnselectedReadsOffNotConnecting() {
        let manager = FakeBTConnectionManager()
        let (backend, _, _, bt, _, _) = makeBackend(btConnection: manager)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }

        backend.retryOutput(btMove.id)          // never selected
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .off }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.off)
        waitFor(timeout: 0.3) { false }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.off,
                "an unselected connect must never leave a row spinning")
    }

    /// The hold is capped: a sink that never starts rendering degrades to
    /// `.failed` rather than spinning forever.
    @Test func sinkThatNeverRendersDegradesToFailedWithinTheCap() {
        let (backend, _, _, bt, _, _) = makeBackend(btRenderStartTimeout: 0.2)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id)?.isAvailable == true }

        backend.setOutputSet([btMove.id])
        waitFor {
            if case .failed = self.device(backend, self.btMove.id)?.connectionState { return true }
            return false
        }
        guard case .failed = device(backend, btMove.id)?.connectionState else {
            Issue.record("expected the capped hold to degrade to .failed"); return
        }
    }

    /// A speaker selected while the Mac is SILENT must land `.connected`, not
    /// `.failed`. Nothing is playing, so the capture fan-out hands the sink no
    /// buffers, so it can never anchor and can never render — the ceiling
    /// expiring says only "there was nothing to play", which is an idle
    /// speaker, not a broken one. Live-found: selecting a healthy, already
    /// connected Move 2 with the Mac paused reported "no audio started" six
    /// seconds later, every time.
    @Test func speakerSelectedWithNothingPlayingLandsConnectedNotFailed() {
        let (backend, _, _, bt, sink, _) = makeBackend(btRenderStartTimeout: 0.2)
        defer { backend.stop() }
        sink.anchoredUIDs = []            // a silent Mac: no sink ever anchors
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id)?.isAvailable == true }

        backend.setOutputSet([btMove.id])
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connected }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.connected,
                "a silent Mac must not turn a healthy speaker into a failed row")
    }

    /// Deselecting mid-hold ends the spinner at once — the poll must not
    /// resurrect it as either `.connected` or `.failed`.
    @Test func deselectingMidHoldEndsTheSpinner() {
        let (backend, _, _, bt, sink, _) = makeBackend(btRenderStartTimeout: 0.2)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id)?.isAvailable == true }

        backend.setOutputSet([btMove.id])
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connecting }
        backend.setOutputSet([])
        sink.renderingUIDs = [btMove.id]        // the sink kept rendering briefly
        waitFor(timeout: 0.5) { false }
        #expect(device(backend, btMove.id)?.connectionState == ConnectionState.off,
                "a deselected row is off — never connected, never failed")
    }

    // MARK: - Wave-4 delay agreement (Mac + BT without AirPlay)

    /// The LOCAL sink's reference delay follows the composition: BT-only (no
    /// AirPlay) → the BT-only buffer both sink families share; AirPlay present
    /// (or no BT) → the live start-buffer.
    @Test func localSinkReferenceDelay_followsComposition() {
        let (backend, engine, discovery, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        let ap = ap2Device()
        discovery.fire(.appeared(ap))
        bt.fire([btMove])
        waitFor { self.device(backend, ap.id) != nil && self.device(backend, self.btMove.id) != nil }
        waitFor { engine.fedIDs.contains(ap.outputID) }

        #expect(backend.localSinkReferenceDelayMs() == backend.startBufferMs,
                "no BT selected → the start-buffer reference")

        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        #expect(backend.localSinkReferenceDelayMs() == BTSyncedSink.defaultBTOnlyBufferMs,
                "BT without AirPlay → the shared BT-only reference")

        backend.setOutputSet([btMove.id, ap.id])
        waitFor { sink.compositions.last?.airPlayPresent == true }
        #expect(backend.localSinkReferenceDelayMs() == backend.startBufferMs,
                "AirPlay joining moves the local reference back to the start-buffer")
    }

    // MARK: - CAST-SYNC: the timeline stays inert without a Cast device

    /// The Bluetooth half of the Phase (ii) invariant: across BT-only and
    /// AirPlay+BT, every composition the backend publishes carries
    /// `castPresent == false` and no AirPlay pre-delay is ever installed — so
    /// each sink's reference is the number it was before Cast existed.
    /// (No BT+Mac stage: a macLocalPresent-only flip deliberately publishes
    /// no composition — "Mac joining changes nothing for BT", the narrowed
    /// trigger in `setOutputSet` — so there is nothing to observe there.)
    @Test func noCastSelectionLeavesEveryCompositionCastFree() {
        let (backend, engine, discovery, bt, sink, capture) = makeBackend()
        defer { backend.stop() }
        let macSelected = LockedBool(false)
        backend.selectedDevicesQuery = { id in
            id == NativeBackend.localDeviceID ? macSelected.get() : false
        }
        backend.start()
        let ap = ap2Device()
        discovery.fire(.appeared(ap))
        bt.fire([btMove])
        waitFor { self.device(backend, ap.id) != nil && self.device(backend, self.btMove.id) != nil }
        waitFor { engine.fedIDs.contains(ap.outputID) }

        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        backend.setOutputSet([btMove.id, ap.id])
        waitFor { sink.compositions.last?.airPlayPresent == true }

        #expect(sink.compositions.count >= 2, "BT-only and AirPlay+BT must both have been published")
        #expect(sink.compositions.allSatisfy { $0.castPresent == false },
                "no Cast id selected ⇒ no composition claims a Cast device")
        #expect(sink.compositions.allSatisfy { $0.usesPresentationReference == $0.airPlayPresent },
                "so the widened reference predicate reduces to today's airPlayPresent")
        #expect(capture.preDelayMs.allSatisfy { $0 == 0 },
                "and the AirPlay feed is never held back, got \(capture.preDelayMs)")
    }

    // MARK: - BT volume/mute (composed sink gain, `Main × Group × Device`)

    /// A BT slider write echoes optimistically (no snap-back — the old
    /// `outputIDs` guard dropped it before the echo) and pushes the composed
    /// `Main × Group × Device` gain to the live sink.
    @Test func btSliderWriteEchoesAndPushesComposedGain() {
        let (backend, engine, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }

        backend.setVolume(40, for: btMove.id)
        waitFor { self.device(backend, self.btMove.id)?.volume == 40 }
        #expect(device(backend, btMove.id)?.volume == 40, "the echo sticks — no snap-back to 50")
        waitFor { sink.lastGain(for: self.btMove.id).map { abs($0 - 0.4) < 0.001 } == true }
        #expect(sink.lastGain(for: btMove.id).map { abs($0 - 0.4) < 0.001 } == true,
                "Main 100 × Group 100 × Device 40 → sink gain 0.4")
        #expect(engine.addedIDs.isEmpty, "a BT volume write never invents an engine op")
    }

    /// Mute pushes the composed 0 (stashing the level); unmute restores the
    /// stashed level and its composed gain — the engine arm's shim, mirrored.
    @Test func btMutePushesZeroAndUnmuteRestoresStashedComposed() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        backend.setVolume(40, for: btMove.id)
        waitFor { self.device(backend, self.btMove.id)?.volume == 40 }

        backend.setMuted(true, for: btMove.id)
        waitFor { self.device(backend, self.btMove.id)?.isMuted == true }
        #expect(device(backend, btMove.id)?.volume == 0, "muted reads as 0, like the engine arm")
        waitFor { sink.lastGain(for: self.btMove.id) == 0 }
        #expect(sink.lastGain(for: btMove.id) == 0)

        backend.setMuted(false, for: btMove.id)
        waitFor { self.device(backend, self.btMove.id)?.isMuted == false }
        #expect(device(backend, btMove.id)?.volume == 40, "unmute restores the stashed level")
        waitFor { sink.lastGain(for: self.btMove.id).map { abs($0 - 0.4) < 0.001 } == true }
        #expect(sink.lastGain(for: btMove.id).map { abs($0 - 0.4) < 0.001 } == true)
    }

    /// A slider write WHILE muted stashes and echoes but pushes nothing; the
    /// unmute pushes the new level's composed gain.
    @Test func btVolumeWhileMutedStashesAndUnmutePushesIt() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        backend.setMuted(true, for: btMove.id)
        waitFor { sink.lastGain(for: self.btMove.id) == 0 }
        let pushesWhileMuted = sink.gains.count

        backend.setVolume(70, for: btMove.id)
        waitFor { self.device(backend, self.btMove.id)?.volume == 70 }
        #expect(sink.gains.count == pushesWhileMuted, "a muted device's slider pushes no gain")

        backend.setMuted(false, for: btMove.id)
        waitFor { sink.lastGain(for: self.btMove.id).map { abs($0 - 0.7) < 0.001 } == true }
        #expect(sink.lastGain(for: btMove.id).map { abs($0 - 0.7) < 0.001 } == true)
    }

    /// A Main/Group master change re-pushes every selected BT uid's composed
    /// gain — the `setMasterGain` re-push no longer stops at `outputIDs`.
    @Test func masterGainChangeRePushesComposedToBT() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setVolume(100, for: btMove.id)
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }

        backend.setMasterGain(mainOut: 50, group: 80, mirrorToSystemVolume: false)
        waitFor { sink.lastGain(for: self.btMove.id).map { abs($0 - 0.4) < 0.001 } == true }
        #expect(sink.lastGain(for: btMove.id).map { abs($0 - 0.4) < 0.001 } == true,
                "Main 50 × Group 80 × Device 100 → 0.4")
    }

    /// Sink (re)arm seeds the composed gain, not 1: a level set before any
    /// sink exists is in force from the first arm, and a deselect→reselect
    /// (the reconnect shape) comes back at the user's level.
    @Test func btEnableSeedsComposedGainAndReselectRestoresIt() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }

        backend.setVolume(40, for: btMove.id)   // no sink yet — state only
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        #expect(sink.lastGain(for: btMove.id).map { abs($0 - 0.4) < 0.001 } == true,
                "the arm seeds the composed gain, never a hardcoded 1")

        backend.setOutputSet([])
        waitFor { sink.calls.contains("stop") }
        backend.setOutputSet([btMove.id])
        waitFor { sink.gains.count >= 2 }
        #expect(sink.lastGain(for: btMove.id).map { abs($0 - 0.4) < 0.001 } == true,
                "a re-arm comes back at the user's level")
    }

    // MARK: SYNC trim → sink (BT-OFFSET-UI)

    /// A trim set BEFORE any sink exists is re-pushed on arm (ahead of the
    /// device set, so the first anchor already samples it), and a trim set
    /// WHILE armed reaches the live sink — the reconnect-restore half of the
    /// round-trip (the relaunch half is `NativeBackendBTDevicesTests`).
    @Test func trimsReachTheSinkOnArmAndLive() {
        let (backend, _, _, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }

        backend.setBTSyncTrim(-120, forDevice: btMove.id, persist: true)   // no sink yet — stored only
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        #expect(sink.trims.contains { $0.ms == -120 && $0.uid == btMove.id },
                "the stored trim is pushed when the sink arms")
        if let trimIndex = sink.calls.firstIndex(of: "setTrimMs"),
           let devicesIndex = sink.calls.firstIndex(of: "setDevices") {
            #expect(trimIndex < devicesIndex, "trims land before the device set arms")
        }

        backend.setBTSyncTrim(60, forDevice: btMove.id, persist: true)
        waitFor { sink.trims.contains { $0.ms == 60 } }
        #expect(sink.trims.last?.ms == 60, "a live edit reaches the armed sink directly")
    }

    /// The align-by-ear gate is a straight pass-through to the capture
    /// coordinator's tick seam.
    @Test func alignTickGateReachesTheCaptureCoordinator() {
        let (backend, _, _, _, _, capture) = makeBackend()
        defer { backend.stop() }
        backend.setBTAlignTickActive(true)
        #expect(capture.ops.contains("tickOn"))
        backend.setBTAlignTickActive(false)
        #expect(capture.ops.last == "tickOff")
    }

    // MARK: - BT-METER (roadmap 038)
    //
    // A BT id is excluded from the AirPlay engine by the converge loop's
    // `!device.isBluetooth` guard, so `Device.isSelected` is structurally never
    // true for one — and `isMeterable` asked exactly that, which is why every BT
    // row's bar was dark from the day the meter shipped. The fix substitutes the
    // BT "rendering now" fact, `.connected`, the same way the local device
    // substitutes `syncedLocalSinkEnabled`.

    /// The core fix: a BT device whose delay gate has opened must receive the
    /// SAME whole-system-tap RMS that feeds every other output's bar — the BT
    /// fan-out is handed that identical buffer, so reusing it is exact.
    @Test func connectedBTDeviceReceivesTheWholeSystemLevel() {
        let (backend, _, _, bt, sink, capture) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        sink.renderingUIDs = [btMove.id]
        waitFor { self.device(backend, self.btMove.id)?.connectionState == .connected }

        let (levels, task) = subscribeLevels(backend); defer { task.cancel() }
        backend.setMeteringActive(true)
        // Re-fire while polling: one RMS sample is consumed by a single drain, so
        // a sample dropped before the subscription registers must not fail the test.
        waitFor { capture.onLevel?(0.6); return (levels.lastDeviceLevel(self.btMove.id) ?? 0) > 0 }

        #expect(abs((levels.lastDeviceLevel(btMove.id) ?? 0) - 0.6) <= 0.001,
                "a rendering BT device must be metered from the whole-system tap it is fanned out from")
    }

    /// Selection is INTENT, not audio: a BT device that is selected but has not
    /// yet started rendering must stay unmetered, or the bar moves while the
    /// speaker is still silent. Pins the choice of `.connected` over
    /// `btSelectedUIDs`.
    @Test func selectedButNotYetRenderingBTDeviceIsNotMetered() {
        let (backend, _, _, bt, sink, capture) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { sink.calls.contains("start") }
        // Deliberately never announce render start: the row stays `.connecting`.
        #expect(device(backend, btMove.id)?.connectionState != .connected)

        let (levels, task) = subscribeLevels(backend); defer { task.cancel() }
        backend.setMeteringActive(true)
        waitFor(timeout: 0.3) { capture.onLevel?(0.6); return false }

        #expect(levels.lastDeviceLevel(btMove.id) == nil,
                "a selected-but-silent BT speaker must not light its bar")
    }
}
