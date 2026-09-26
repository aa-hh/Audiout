import Foundation
import Testing
import AirPlayEngine
@testable import AudioutCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// A selected `.wired` row plays through the same `BTSyncedSink` manager the
/// Bluetooth rows use, keyed by its Core Audio UID. Hermetic: the doubles and
/// `makeBackend` of `NativeBackendBTSelectionTests`, fed by a
/// ``WiredOutputEnumerating`` fake instead of a Bluetooth enumerator.
@Suite final class NativeBackendWiredSinkTests: IsolatedSuite {


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

    private final class FakeWiredEnumerator: WiredOutputEnumerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _onSnapshot: (@Sendable ([WiredOutputSnapshot]) -> Void)?

        var onSnapshot: (@Sendable ([WiredOutputSnapshot]) -> Void)? {
            get { lock.withLock { _onSnapshot } }
            set { lock.withLock { _onSnapshot = newValue } }
        }

        func start() {}
        func stop() {}
        func refresh() {}
        func fire(_ snapshots: [WiredOutputSnapshot]) { onSnapshot?(snapshots) }
    }

    /// The UID → `AudioObjectID` table `btDeviceIDForUID` reads, edited by the
    /// test off the backend's queues — hence the lock.
    private final class DeviceIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String: AudioObjectID]
        init(_ ids: [String: AudioObjectID]) { self.ids = ids }
        func get(_ uid: String) -> AudioObjectID? { lock.withLock { ids[uid] } }
        func set(_ uid: String, _ id: AudioObjectID?) { lock.withLock { ids[uid] = id } }
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
        func setOffsetMs(_ ms: Int, forDeviceUID uid: String) {
            lock.withLock { _offsets.append((ms: ms, uid: uid)) }
        }
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {}
        func setPerAppClaimedUIDs(_ uids: Set<String>) {
            lock.withLock { _calls.append("setPerAppClaimedUIDs"); _perAppClaimedUIDCalls.append(uids) }
        }
        /// The UID-scoped per-app feed (BT-BACKEND, per-app half) — records the
        /// UIDs and frame count of every call, never `_calls`: like the
        /// whole-system `enqueue` above, this is the per-buffer hot path, not a
        /// lifecycle event.
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec,
                     forDeviceUIDs uids: [String]) {
            lock.withLock { _perAppEnqueues.append((uids: uids, frameCount: frameCount)) }
        }

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
        private var _offsets: [(ms: Int, uid: String)] = []
        var offsets: [(ms: Int, uid: String)] { lock.withLock { _offsets } }
        private var _gains: [(gain: Float, uid: String)] = []
        var gains: [(gain: Float, uid: String)] { lock.withLock { _gains } }
        func lastGain(for uid: String) -> Float? {
            lock.withLock { _gains.last { $0.uid == uid }?.gain }
        }
        private var _perAppClaimedUIDCalls: [Set<String>] = []
        var perAppClaimedUIDCalls: [Set<String>] { lock.withLock { _perAppClaimedUIDCalls } }
        private var _perAppEnqueues: [(uids: [String], frameCount: Int)] = []
        var perAppEnqueues: [(uids: [String], frameCount: Int)] { lock.withLock { _perAppEnqueues } }
        /// Call order with the per-device gain seeds stripped — for the
        /// lifecycle-order assertions, which don't care how many uids got a
        /// gain pushed between `setComposition` and `setDevices`.
        var lifecycleCalls: [String] { calls.filter { $0 != "setGain" } }
    }

    /// A `ProcessAudioTap` that always succeeds, self-registers with an
    /// external registry keyed by the bundle ID it was started for (so a test
    /// can grab a handle to THIS app's specific tap instance and `push(_:)`
    /// content into it directly), and uses the engine's exact output format
    /// (44100/16-bit interleaved S16) so buffers round-trip through the real
    /// `AVFormatConverter` essentially unchanged. Per-suite copy of
    /// `NativeBackendTests.BundleTaggingTap` (house convention: doubles are
    /// per-suite, not shared).
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

    /// A scripted `AudioProcessEnumerating` fake: hands back a fixed process
    /// list so an `AudioProcessResolver` built on it resolves deterministically,
    /// with no live Core Audio.
    private struct FakeProcessEnumerator: AudioProcessEnumerating {
        let processes: [RawAudioProcess]
        var parents: [pid_t: pid_t] = [:]
        func enumerateProcesses() -> [RawAudioProcess] { processes }
        func parentPID(of pid: pid_t) -> pid_t? { parents[pid] }
    }

    /// A `ProcessAudioTap` that always succeeds: `createAndStart` never throws,
    /// so a coordinator built over it takes every bundle ID all the way to
    /// `.capturing` and keeps it there — unlike the default empty-resolver setup
    /// (`EmptyAudioProcessEnumerator`), which fails fast at `.processNotYetAudible` and
    /// then marks the bundle dead, retracting its route from the mixer
    /// (`handlePerAppCaptureHealthChange`). A per-app BT claim armed over that
    /// default is torn back down within milliseconds by that cascade — tests
    /// that need the claim to STAY armed use this tap instead.
    private final class AlwaysSucceedsTap: ProcessAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        func createAndStart(processes: Set<AudioProcess>, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        }
        func teardown() {}
    }

    // MARK: Fixtures + helpers

    private let jack = WiredOutputSnapshot(id: "BuiltInHeadphoneOutputDevice", name: "External Headphones",
                                           transport: .headphoneJack)
    private lazy var deviceIDs = DeviceIDBox([jack.id: 1042])

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

    /// Builds an `AudioProcessResolver` where each bundle id resolves to
    /// exactly ONE process object, at `pid = objectID`.
    private func singleProcessResolver(_ bundleIDsToObjectIDs: [String: AudioObjectID]) -> AudioProcessResolver {
        let processes = bundleIDsToObjectIDs.map { bundleID, objectID in
            RawAudioProcess(objectID: objectID, pid: pid_t(objectID), bundleID: bundleID)
        }
        return AudioProcessResolver(enumerator: FakeProcessEnumerator(processes: processes))
    }

    /// A `PerAppCaptureCoordinator` whose every `start(bundleID:)` reaches
    /// `.capturing` and stays there — pass as `injectedPerAppCapture:` to
    /// `makeBackend` for a test that needs a per-app BT claim to stay armed
    /// rather than get torn down by the dead-bundle cascade. Every bundle id
    /// the test will route needs its own resolvable process, so callers list
    /// them.
    private func workingPerAppCapture(bundleIDs: [String]) -> PerAppCaptureCoordinator {
        var mapping: [String: AudioObjectID] = [:]
        for (offset, bundleID) in bundleIDs.enumerated() {
            mapping[bundleID] = AudioObjectID(9000 + offset)
        }
        return PerAppCaptureCoordinator(
            makeTap: { AlwaysSucceedsTap() }, processResolver: singleProcessResolver(mapping), muteBehavior: .mutedWhenTapped)
    }

    /// A per-app capture over `BundleTaggingTap`s that self-register so a test
    /// can push content into a specific bundle's tap. Every bundle id the test
    /// will start needs its own resolvable process, so callers list them.
    private func registeringPerAppCapture(
        muteBehavior: TapMuteBehavior, bundleIDs: [String], into registry: TapRegistry
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
            processResolver: singleProcessResolver(mapping),
            muteBehavior: muteBehavior)
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

    private func makeBackend(
        silenceFallbackDelay: TimeInterval = NativeBackend.defaultSilenceFallbackDelay,
        btConnection: BTConnectionManaging? = nil,
        btRenderStartTimeout: TimeInterval = 6,
        injectedPerAppCapture: PerAppCaptureCoordinator? = nil
    ) -> (NativeBackend, RecordingEngine, FakeDiscovery, FakeWiredEnumerator, SpyBTSink, FakeCapture) {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let wired = FakeWiredEnumerator()
        let backend = NativeBackend(
            engineControl: engine,
            discoverySource: discovery,
            btConnectionManager: btConnection,
            wiredEnumerator: wired,
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            ptpHelperActivator: AlwaysReadyPTPHelperActivator(),
            injectedPerAppCapture: injectedPerAppCapture,
            silenceFallbackDelay: silenceFallbackDelay,
            systemDefaultOutputIsAirPlayClass: { false },
            aggregateControl: NoOpAggregateControl(),
            handoffWatcherFactory: { onBlockedAttempt in
                AirPlayHandoffWatcher(spawn: NoOpLogStream(), onBlockedAttempt: onBlockedAttempt)
            })
        let sink = SpyBTSink()
        backend.btSyncedSinkFactory = { sink }
        backend.btRenderStartTimeout = btRenderStartTimeout
        // UID → AudioObjectID from the box the test edits, no HAL: removing a
        // uid models the HAL no longer translating it (unplugged).
        let deviceIDs = self.deviceIDs
        backend.btDeviceIDForUID = { uid in deviceIDs.get(uid) }
        let capture = FakeCapture()
        backend.captureCoordinator = capture
        return (backend, engine, discovery, wired, sink, capture)
    }

    private func waitFor(timeout: TimeInterval? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation,
                     _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    private func device(_ backend: NativeBackend, _ id: String) -> Device? {
        backend.devices.first { $0.id == id }
    }

    // MARK: - Tests

    /// Defect: a selected wired row never reaches the sink manager, so it
    /// plays nothing.
    @Test func selectedWiredRowArmsTheSinkManagerByUID() {
        let (backend, engine, _, wired, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        wired.fire([jack])
        waitFor { self.device(backend, self.jack.id) != nil }

        backend.setOutputSet([jack.id])
        waitFor { sink.calls.contains("start") }

        #expect(sink.deviceSets.last?.map(\.uid) == [jack.id])
        #expect(sink.compositions.last == BTGroupComposition(airPlayPresent: false, macLocalPresent: false),
                "a wired row is not AirPlay")
        #expect(engine.addedIDs.isEmpty, "a wired id never reaches the AirPlay engine")
        #expect(device(backend, jack.id)?.connectionState == .connecting)

        sink.renderingUIDs = [jack.id]
        waitFor { self.device(backend, self.jack.id)?.connectionState == .connected }
    }

    /// Defect: a wired row scheduled at offset 0 plays late by its reported
    /// latency, and a wizard-measured chain latency would have the reported
    /// figure subtracted on top.
    @Test func reportedLatencySeedsTheOffsetUnlessMeasured() {
        let (backend, _, _, wired, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.wiredReportedLatencyMs = { _ in 9 }
        backend.start()
        wired.fire([jack])
        waitFor { self.device(backend, self.jack.id) != nil }

        backend.setOutputSet([jack.id])
        waitFor { sink.offsets.last { $0.uid == self.jack.id }?.ms == 9 }

        backend.btTrimLock.withLock { backend.btLatencyMsByUID[jack.id] = 600 }
        backend.setOutputSet([])
        backend.setOutputSet([jack.id])
        waitFor { sink.offsets.last { $0.uid == self.jack.id }?.ms == 600 }

        let jackOffsets = sink.offsets.filter { $0.uid == jack.id }.map(\.ms)
        let afterMeasured = jackOffsets[(jackOffsets.firstIndex(of: 600) ?? 0)...]
        #expect(!afterMeasured.contains(9), "a measured latency is never followed by the reported seed")
    }

    /// Defect: after an unplug the manager keeps an engine pinned to an
    /// `AudioObjectID` the HAL reuses for the next device, and a replugged
    /// selected row stays silent.
    @Test func unpluggedWiredRowLeavesTheSinkSetAndReplugRearmsIt() {
        let (backend, _, _, wired, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        wired.fire([jack])
        waitFor { self.device(backend, self.jack.id) != nil }
        backend.setOutputSet([jack.id])
        waitFor { sink.deviceSets.last?.map(\.uid) == [self.jack.id] }

        deviceIDs.set(jack.id, nil)
        wired.fire([])
        waitFor { sink.deviceSets.last?.isEmpty == true }
        #expect(device(backend, jack.id)?.isAvailable == false, "the selected row is kept, greyed")

        deviceIDs.set(jack.id, 1042)
        wired.fire([jack])
        waitFor { sink.deviceSets.last?.map(\.uid) == [self.jack.id] }
        waitFor { self.device(backend, self.jack.id)?.connectionState == .connecting }
    }

    /// Defect: a jack unplugged inside the render-start ceiling keeps its
    /// deadline, and when it expires the greyed row flips to `.connected`, so
    /// its dot lights and its meter animates with nothing plugged in.
    @Test func unplugInsideTheRenderStartCeilingLeavesTheRowOff() {
        let (backend, _, _, wired, sink, _) = makeBackend(btRenderStartTimeout: 0.3)
        defer { backend.stop() }
        sink.anchoredUIDs = []            // a real sink: anchored set known, jack absent
        backend.start()
        wired.fire([jack])
        waitFor { self.device(backend, self.jack.id) != nil }
        backend.setOutputSet([jack.id])
        waitFor { self.device(backend, self.jack.id)?.connectionState == .connecting }

        deviceIDs.set(jack.id, nil)
        wired.fire([])
        waitFor { self.device(backend, self.jack.id)?.isAvailable == false }
        SuiteWait.settle(0.8)             // well past the 0.3 s ceiling
        #expect(device(backend, jack.id)?.connectionState == .off,
                "an unplugged row never lands connected")
    }

    /// Defect: the phone's "Fix timing" on a wired row fails at activation
    /// with "The speaker pair changed before clicks could start." because the
    /// live-pair check only looked for Bluetooth rows in the sink selection.
    @Test @MainActor func companionAuditionStartsWithWiredRows() async {
        let usb = WiredOutputSnapshot(id: "AppleUSBAudioEngine:DAC:1", name: "USB DAC", transport: .usb)
        deviceIDs.set(usb.id, 1043)
        let (backend, _, _, wired, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        wired.fire([jack, usb])
        await SuiteWait.until { self.device(backend, usb.id) != nil && self.device(backend, self.jack.id) != nil }
        backend.setOutputSet([jack.id, usb.id])
        await SuiteWait.until { Set(sink.deviceSets.last?.map(\.uid) ?? []) == [self.jack.id, usb.id] }

        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: jack.id, referenceID: usb.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil), "a wired pair starts clicks")

        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: jack.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
    }

    /// Defect: cancelling a latency preview restores `measured ?? 0`, so a
    /// wired row with only its reported latency plays late by that latency.
    @Test func cancelledLatencyPreviewRestoresTheReportedSeed() {
        let (backend, _, _, wired, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.wiredReportedLatencyMs = { _ in 9 }
        backend.start()
        wired.fire([jack])
        waitFor { self.device(backend, self.jack.id) != nil }
        backend.setOutputSet([jack.id])
        waitFor { sink.offsets.last { $0.uid == self.jack.id }?.ms == 9 }

        backend.setBTWizardLatencyPreview(250, forDevice: jack.id)
        waitFor { sink.offsets.last { $0.uid == self.jack.id }?.ms == 250 }
        backend.endBTWizardLatencyPreview(forDevice: jack.id, keepMs: nil)
        SuiteWait.settle(0.3)
        #expect(sink.offsets.last { $0.uid == jack.id }?.ms == 9,
                "the cancel returns the jack to its reported-latency seed")
    }

    /// Defect: the wired UID never reaches the sink manager's per-app claim
    /// set, so the app's stream has no delivery path and plays nowhere.
    @Test func routeToAWiredRowClaimsItForPerAppDelivery() {
        let capture = workingPerAppCapture(bundleIDs: ["com.foo"])
        let (backend, _, _, wired, sink, _) = makeBackend(injectedPerAppCapture: capture)
        defer { backend.stop() }
        backend.start()
        wired.fire([jack])
        waitFor { self.device(backend, self.jack.id) != nil }

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: jack.id)])
        waitFor { sink.perAppClaimedUIDCalls.last == [self.jack.id] }

        #expect(sink.calls.contains("start"))
        #expect(sink.deviceSets.last?.map(\.uid) == [jack.id])
    }

    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
