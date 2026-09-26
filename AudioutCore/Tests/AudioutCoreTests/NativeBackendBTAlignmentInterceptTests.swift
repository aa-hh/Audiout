import Foundation
import Testing
import AirPlayEngine
@testable import AudioutCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// W3 — the first-mix alignment intercept, hermetic (`NativeBackendBTSelectionTests`
/// double style): the trigger matrix (never-aligned + first-mix fires; solo BT
/// never; saved trim never; dismissed never; once per launch), the
/// held-silent join (sink gain 0 before audio, 1 on resolve), dismissal
/// finality across backend instances, the give-up watchdog, and the W2 wizard
/// trim preview/restore/persist plumbing.
///
/// Nested under ``SerializedSharedState`` because these tests install the
/// process-global `Telemetry._installTestSink(_:)`. Outside that parent they
/// race every other suite that installs it — one suite's `nil` teardown tears
/// another's sink out mid-test, and the loser reads back nothing.
extension SerializedSharedState {

@Suite final class NativeBackendBTAlignmentInterceptTests: IsolatedSuite {

    // MARK: Doubles (per-suite copies, house style)

    private final class RecordingEngine: EngineControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var held: [CheckedContinuation<Void, Error>] = []
        private var _writes: [(OutputID, Double)] = []
        private var _blockWrites = false
        private var _failNextWrite = false
        var blockWrites: Bool {
            get { lock.withLock { _blockWrites } }
            set { lock.withLock { _blockWrites = newValue } }
        }
        var writes: [(OutputID, Double)] { lock.withLock { _writes } }
        var heldCount: Int { lock.withLock { held.count } }
        var failNextWrite: Bool {
            get { lock.withLock { _failNextWrite } }
            set { lock.withLock { _failNextWrite = newValue } }
        }
        func releaseWrites() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                _blockWrites = false
                let pending = held
                held = []
                return pending
            }
            pending.forEach { $0.resume() }
        }
        /// Fail every held write. A real engine reports a write's outcome only
        /// when the op finishes, so a hold that is going to fail can fail long
        /// after it was issued — which is the ordering the preparation-failure
        /// tests need and `failNextWrite` (throws at once) cannot produce.
        func releaseWritesFailing() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                _blockWrites = false
                let pending = held
                held = []
                return pending
            }
            pending.forEach { $0.resume(throwing: NSError(domain: "AuditionTest", code: 2)) }
        }
        func start() async throws {}
        func stop() async {}
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            descriptor.parsedID ?? OutputID(rawValue: 0)
        }
        func removeDiscovery(_ descriptor: DeviceDescriptor) async {}
        func addOutput(_ id: OutputID) async throws {}
        func addOutput(_ id: OutputID, streamId: UInt32) async throws {}
        func removeOutput(_ id: OutputID) async throws {}
        func setVolume(_ id: OutputID, _ volume: Double) async throws {
            let (shouldBlock, shouldFail) = lock.withLock { () -> (Bool, Bool) in
                _writes.append((id, volume))
                let fail = _failNextWrite
                _failNextWrite = false
                return (_blockWrites, fail)
            }
            if shouldFail { throw NSError(domain: "AuditionTest", code: 1) }
            if shouldBlock {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { held.append(continuation) }
                }
            }
        }
        func setStartBufferMs(_ ms: Int) async {}
        func write(pcm: Data, streamId: UInt32, pts: timespec) {}
        func makeStateStream() -> AsyncStream<(OutputID, OutputState)> { AsyncStream { _ in } }
        func makeRemoteEventStream() -> AsyncStream<RemoteEvent> { AsyncStream { _ in } }
        var dacpID: UInt64 { 0 }
        var ptpClockAvailable: Bool { get async { true } }
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

    /// Enough of the coordinator for a phone-driven run to reach the apply
    /// path: it renders nothing and reports the sweeps started at once.
    private final class ProbeStagingCapture: CaptureControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _modes: [AlignTickMode] = []
        private var _stages = 0
        var modes: [AlignTickMode] { lock.withLock { _modes } }
        var stages: Int { lock.withLock { _stages } }
        var onLevel: (@Sendable (_ rms: Float) -> Void)?
        var onStateChange: (@Sendable (_ state: NativeCaptureCoordinator.State) -> Void)?
        func start() {}
        func stop() {}
        func setAlignTickMode(_ mode: AlignTickMode) { lock.withLock { _modes.append(mode) } }
        func stageCompanionMicProbe(staggered: Bool, referenceOnEngine: Bool,
                                    downWindowUID: String?, upWindowUID: String?,
                                    onStarted: @escaping () -> Void,
                                    onFinished: @escaping () -> Void) {
            lock.withLock { _stages += 1 }
            onStarted()
        }
    }

    private final class ScriptedLocalPlayback: LocalPlaybackControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks: [@Sendable () -> Void] = []
        private var _suppressions: [Bool] = []
        private var _received: [CapturedBuffer] = []
        var holdsCompletions = false
        var suppressions: [Bool] { lock.withLock { _suppressions } }
        var received: [CapturedBuffer] { lock.withLock { _received } }
        var onAppLevel: (@Sendable (String, Float) -> Void)?
        func addApp(bundleID: String, tapFormat: TapFormat, volume: Float) throws {}
        func removeApp(bundleID: String) {}
        func setVolume(_ volume: Float, for bundleID: String) {}
        func receive(buffer: CapturedBuffer, for bundleID: String) {
            lock.withLock { _received.append(buffer) }
        }
        func start() throws {}
        func stop() {}
        func setOutputSuppressed(_ suppressed: Bool,
                                 completion: @escaping @Sendable () -> Void) {
            let hold = lock.withLock { () -> Bool in
                _suppressions.append(suppressed)
                if holdsCompletions { callbacks.append(completion) }
                return holdsCompletions
            }
            if !hold { completion() }
        }
        func release() {
            let ready = lock.withLock { () -> [@Sendable () -> Void] in
                let ready = callbacks
                _lastCompletion = ready.last ?? _lastCompletion
                callbacks = []
                return ready
            }
            ready.forEach { $0() }
        }
        private var _lastCompletion: (@Sendable () -> Void)?
        /// Deliver the most recent suppression completion a SECOND time. The
        /// protocol promises nothing about once-only delivery, and the backend
        /// must not let a repeat acknowledgement stand in for one that has not
        /// arrived.
        func replayLastCompletion() {
            lock.withLock { _lastCompletion }?()
        }
    }

    private final class NoOpLogStream: LogStreamSpawning, @unchecked Sendable {
        func start(onLine: @escaping @Sendable (String) -> Void,
                   onTermination: @escaping @Sendable () -> Void) throws {}
        func stop() {}
        var isRunning: Bool { false }
    }

    /// Records trims and per-device gains, in call order.
    private final class SpyBTSink: BTSyncedSinkControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _trims: [(ms: Double, uid: String)] = []
        private var _gains: [(gain: Float, uid: String)] = []
        private var _offsets: [(ms: Int, uid: String)] = []
        private var _buffers: [Int] = []
        func start() {}
        func stop() {}
        func setDevices(_ specs: [BTSyncedSink.DeviceSpec]) {}
        func setComposition(_ composition: BTGroupComposition) {}
        private var _rendering: Set<String> = []
        var rendering: Set<String> {
            get { lock.withLock { _rendering } }
            set { lock.withLock { _rendering = newValue } }
        }
        func renderingDeviceUIDs() -> Set<String> { rendering }
        func setOffsetMs(_ ms: Int, forDeviceUID uid: String) {
            lock.withLock { _offsets.append((ms, uid)) }
        }
        func setBTOnlyBufferMs(_ ms: Int) {
            lock.withLock { _buffers.append(ms) }
        }
        func setTrimMs(_ ms: Double, forDeviceUID uid: String) {
            lock.withLock { _trims.append((ms, uid)) }
        }
        private var _clampChecks: [String] = []
        func reanchorIfTrimClamped(forDeviceUID uid: String) {
            lock.withLock { _clampChecks.append(uid) }
        }
        var clampChecks: [String] { lock.withLock { _clampChecks } }
        /// Hold every `setGain` on the queue that calls it, so a test can assert
        /// what happens while a Bluetooth hold has not yet reached the sink.
        private let gate = NSCondition()
        private var gateClosed = false
        func closeGainGate() { gate.lock(); gateClosed = true; gate.unlock() }
        func openGainGate() { gate.lock(); gateClosed = false; gate.broadcast(); gate.unlock() }
        func setGain(_ gain: Float, forDeviceUID uid: String) {
            gate.lock()
            while gateClosed { gate.wait() }
            gate.unlock()
            lock.withLock { _gains.append((gain, uid)) }
        }
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {}
        private var _reanchors: [String] = []
        func reanchorAll(cause: String) { lock.withLock { _reanchors.append(cause) } }
        var reanchors: [String] { lock.withLock { _reanchors } }
        var trims: [(ms: Double, uid: String)] { lock.withLock { _trims } }
        var offsets: [(ms: Int, uid: String)] { lock.withLock { _offsets } }
        var buffers: [Int] { lock.withLock { _buffers } }
        var gains: [(gain: Float, uid: String)] { lock.withLock { _gains } }
        func lastGain(for uid: String) -> Float? {
            lock.withLock { _gains.last { $0.uid == uid }?.gain }
        }
    }

    /// Collects emitted `BackendEvent`s off the real event stream.
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [BackendEvent] = []
        private var task: Task<Void, Never>?
        func attach(to backend: NativeBackend) {
            let stream = backend.makeEventStream()
            task = Task { [weak self] in
                for await event in stream {
                    self?.lock.withLock { self?._events.append(event) }
                }
            }
        }
        func promptedDeviceIDs() -> [String] {
            lock.withLock {
                _events.compactMap {
                    if case .btFirstMixAlignmentPrompt(let id) = $0 { return id }
                    return nil
                }
            }
        }
        deinit { task?.cancel() }
    }

    // MARK: Fixtures

    private let btMove = BTDeviceSnapshot(id: "C4-38-75-0E-BF-4A:output", name: "Move 2", isConnected: true)
    private let btFlip = BTDeviceSnapshot(id: "70-99-1C-51-8F-A8:output", name: "Flip 5", isConnected: true)
    private let btExtra = BTDeviceSnapshot(id: "AA-BB-CC-DD-EE-77:output", name: "Extra", isConnected: true)

    private func airPlay1() -> DiscoveredDevice {
        let txt = ["deviceid": "AA:BB:CC:DD:EE:99", "model": "AirPort4,107"]
        let (id, outputID) = NativeDiscovery.parseDeviceID(txt)!
        let descriptor = DeviceDescriptor(name: "Old Express", address: "192.168.1.20",
            family: .ipv4, port: 5000, txtRecord: txt)
        return DiscoveredDevice(id: id, descriptor: descriptor,
                                outputID: outputID, isAirPlay2Supported: false)
    }

    private func airPlay2() -> DiscoveredDevice {
        let txt = ["deviceid": "AA:BB:CC:DD:EE:88", "model": "AudioAccessory5,1"]
        let (id, outputID) = NativeDiscovery.parseDeviceID(txt)!
        let descriptor = DeviceDescriptor(name: "New Speaker", address: "192.168.1.21",
            family: .ipv4, port: 7000, txtRecord: txt)
        return DiscoveredDevice(id: id, descriptor: descriptor,
                                outputID: outputID, isAirPlay2Supported: true)
    }

    private func makeBackend(
        storeDirectory: URL? = nil,
        engine: RecordingEngine? = nil,
        discovery: FakeDiscovery? = nil,
        perAppCapture: PerAppCaptureCoordinator? = nil
    ) -> (NativeBackend, FakeBTEnumerator, SpyBTSink, EventCollector) {
        let bt = FakeBTEnumerator()
        let backend = NativeBackend(
            engineControl: engine ?? RecordingEngine(),
            discoverySource: discovery ?? FakeDiscovery(),
            btEnumerator: bt,
            btTrimStore: storeDirectory.map { BTTrimStore(directory: $0) },
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            ptpHelperActivator: AlwaysReadyPTPHelperActivator(),
            injectedPerAppCapture: perAppCapture,
            systemDefaultOutputIsAirPlayClass: { false },
            aggregateControl: NoOpAggregateControl(),
            handoffWatcherFactory: { onBlockedAttempt in
                AirPlayHandoffWatcher(spawn: NoOpLogStream(), onBlockedAttempt: onBlockedAttempt)
            })
        let sink = SpyBTSink()
        backend.btSyncedSinkFactory = { sink }
        backend.btDeviceIDForUID = { uid in AudioObjectID(1000 + UInt32(abs(uid.hashValue % 1000))) }
        let collector = EventCollector()
        collector.attach(to: backend)
        return (backend, bt, sink, collector)
    }

    private func waitFor(timeout: TimeInterval? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation,
                     _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    private func device(_ backend: NativeBackend, _ id: String) -> Device? {
        backend.devices.first { $0.id == id }
    }

    /// The sink gain is the composed `Main × Group × Device` product; drive the
    /// device faders to 100 so "released / never held" reads as exactly 1 in
    /// these lifecycle tests (the fresh-row default is 50 → 0.5).
    private func setFullVolume(_ backend: NativeBackend, _ ids: String...) {
        for id in ids { backend.setVolume(100, for: id) }
    }

    /// Removing audition reservation ownership lets a probe consume a pending or draining click run.
    @Test @MainActor func auditionReservesTheTickSlotUntilStopCompletes() async {
        let (backend, bt, _, _) = makeBackend()
        defer { backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btMove.id) != nil && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])

        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))
        #expect(backend.startCompanionAlignmentProbe(targetID: btMove.id,
            referenceID: btFlip.id, onStarted: {}, onFinished: {}) != nil)

        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil))
    }

    /// Replacing the wizard pacer with capture-fed companion ticks loses clicks when music is paused.
    @Test @MainActor func auditionUsesIndependentWizardPacerAndKeepsOnlyPairAudible() async {
        let dir = scratchDir
        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        let capture = ProbeStagingCapture()
        backend.captureCoordinator = capture
        backend.start()
        bt.fire([btMove, btFlip, btExtra])
        await SuiteWait.until { self.device(backend, self.btExtra.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id, btExtra.id)
        backend.setOutputSet([btMove.id, btFlip.id, btExtra.id])
        await SuiteWait.until { sink.lastGain(for: self.btExtra.id) == 1 }
        backend.endBTWizardLatencyPreview(forDevice: btMove.id, keepMs: 300)
        let latency = backend.btMeasuredLatencyMs(forDevice: btMove.id)
        let trim = backend.btSyncTrim(forDevice: btMove.id)
        let bufferCount = sink.buffers.count

        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))
        await SuiteWait.until { sink.lastGain(for: self.btExtra.id) == 0 }
        #expect(sink.lastGain(for: btMove.id) == 1)
        #expect(sink.lastGain(for: btFlip.id) == 1)
        #expect(capture.modes.contains(.wizard), "the independent pacer starts with no program feed")
        #expect(capture.stages == 0, "audition never stages a probe")
        #expect(sink.buffers.count == bufferCount, "audition does not raise the BT reference")
        #expect(backend.btMeasuredLatencyMs(forDevice: btMove.id) == latency)
        #expect(backend.btSyncTrim(forDevice: btMove.id) == trim)

        let again = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            again.value = .some($0)
        }
        await SuiteWait.until { again.value != nil }
        #expect(again.value == .some(nil))
        #expect(capture.modes.filter { $0 == .wizard }.count == 1,
                "a repeated active start does not reanchor or reset the lease")

        backend.setVolume(75, for: btExtra.id)
        await SuiteWait.until { self.device(backend, self.btExtra.id)?.volume == 75 }
        #expect(sink.lastGain(for: btExtra.id) == 0,
                "a user edit during isolation cannot lift a nonparticipant hold")
        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil))
        await SuiteWait.until { sink.lastGain(for: self.btExtra.id) == 0.75 }
        #expect(backend.btMeasuredLatencyMs(forDevice: btMove.id) == latency)
        #expect(backend.btSyncTrim(forDevice: btMove.id) == trim)
    }

    @Test @MainActor func auditionZerosRedirectedCaptureWithoutDroppingFrames() async {
        let perApp = PerAppCaptureCoordinator(
            processResolver: AudioProcessResolver(enumerator: EmptyAudioProcessEnumerator()))
        let (backend, bt, _, _) = makeBackend(perAppCapture: perApp)
        defer { backend.stop() }
        let local = ScriptedLocalPlayback()
        backend.localPlaybackEngine = local
        backend.captureCoordinator = ProbeStagingCapture()
        // Preparation waits for every Bluetooth hold to reach the sink on
        // `captureControlQueue`. That queue is immediate on a real Mac but can
        // be starved for seconds under a full parallel test run, and this test
        // is not about the deadline — so it does not race one.
        backend.companionAuditionPreparationSeconds = 60
        backend.companionAuditionStopSeconds = 60
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))
        let original = CapturedBuffer(channelData: [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])],
                                      frameCount: 2, pts: timespec(tv_sec: 12, tv_nsec: 34))
        perApp.onBuffer?("com.example.redirected", original)
        await SuiteWait.until { local.received.count == 1 }
        let held = local.received[0]
        #expect(held.frameCount == original.frameCount)
        #expect(held.pts.tv_sec == original.pts.tv_sec && held.pts.tv_nsec == original.pts.tv_nsec)
        #expect(held.channelData.map(\.count) == original.channelData.map(\.count))
        #expect(held.channelData.allSatisfy { $0.allSatisfy { $0 == 0 } })
        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil))
        perApp.onBuffer?("com.example.redirected", original)
        await SuiteWait.until { local.received.count == 2 }
        #expect(local.received[1].channelData == original.channelData)
    }

    /// Dropping a pending start callback after cancellation can rearm the pacer behind the closed sheet.
    @Test @MainActor func pendingStartsJoinAndLatePreparationCannotReactivate() async {
        let (backend, bt, _, _) = makeBackend()
        defer { backend.stop() }
        let capture = ProbeStagingCapture()
        let local = ScriptedLocalPlayback()
        local.holdsCompletions = true
        backend.captureCoordinator = capture
        backend.localPlaybackEngine = local
        // Not a deadline test: see the note in
        // `auditionZerosRedirectedCaptureWithoutDroppingFrames`.
        backend.companionAuditionPreparationSeconds = 60
        backend.companionAuditionStopSeconds = 60
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        let first = LockedBox<String??>(nil)
        let second = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            first.value = .some($0)
        }
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            second.value = .some($0)
        }
        await SuiteWait.until { local.suppressions.contains(true) }
        #expect(first.value == nil && second.value == nil)
        #expect(backend.startCompanionAlignmentProbe(targetID: btMove.id,
            referenceID: btFlip.id, onStarted: {}, onFinished: {}) != nil)
        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { first.value != nil && second.value != nil && local.suppressions.contains(false) }
        #expect(first.value.flatMap { $0 } != nil && second.value.flatMap { $0 } != nil)
        #expect(capture.modes.isEmpty, "the pacer never starts while preparation is pending")
        #expect(backend.startCompanionAlignmentProbe(targetID: btMove.id,
            referenceID: btFlip.id, onStarted: {}, onFinished: {}) != nil,
            "cleaning retains the .tick reservation")
        local.release()
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil))
        #expect(capture.modes.isEmpty, "a retired local suppression callback cannot start clicks")
    }

    @Test @MainActor func preparationDeadlineRejectsJoinedStartsAndLateLocalCompletion() async {
        let (backend, bt, _, _) = makeBackend()
        defer { backend.stop() }
        let capture = ProbeStagingCapture()
        let local = ScriptedLocalPlayback()
        local.holdsCompletions = true
        backend.captureCoordinator = capture
        backend.localPlaybackEngine = local
        backend.companionAuditionPreparationSeconds = 0.1
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        let first = LockedBox<String??>(nil)
        let second = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            first.value = .some($0)
        }
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            second.value = .some($0)
        }
        await SuiteWait.until { first.value != nil && second.value != nil }
        #expect(first.value.flatMap { $0 }?.contains("too long") == true)
        #expect(second.value.flatMap { $0 }?.contains("too long") == true)
        #expect(capture.modes.isEmpty)
        local.release()
        #expect(capture.modes.isEmpty)
    }

    /// A repeat suppression acknowledgement standing in for a hold that never
    /// answered starts the clicks with a speaker still at full level, and a
    /// hold failure arriving after that can no longer stop them.
    @Test @MainActor func lateDuplicateAcknowledgementCannotOutrunAFailedHold() async {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let (backend, bt, _, _) = makeBackend(engine: engine, discovery: discovery)
        defer { engine.releaseWrites(); backend.stop() }
        let capture = ProbeStagingCapture()
        let local = ScriptedLocalPlayback()
        local.holdsCompletions = true
        backend.captureCoordinator = capture
        backend.localPlaybackEngine = local
        backend.start()
        let ap1 = airPlay1()
        discovery.fire(.appeared(ap1))
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, ap1.id) != nil && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id, ap1.id])
        await SuiteWait.until { engine.writes.contains { $0.0 == ap1.outputID } }
        // The AirPlay 1 hold is issued but does not answer yet.
        engine.blockWrites = true

        let first = LockedBox<String??>(nil)
        let second = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            first.value = .some($0)
        }
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            second.value = .some($0)
        }
        await SuiteWait.until { engine.heldCount > 0 && local.suppressions.contains(true) }

        // The local setter answers, then answers again. The repeat must not
        // stand in for the AirPlay 1 hold, which is still outstanding.
        local.release()
        local.replayLastCompletion()
        #expect(capture.modes.isEmpty, "a repeat acknowledgement cannot complete preparation")
        #expect(first.value == nil && second.value == nil)

        // Now the outstanding hold fails. It must win: no clicks, one refusal
        // per joined start.
        engine.releaseWritesFailing()
        await SuiteWait.until { first.value != nil && second.value != nil }
        #expect(first.value.flatMap { $0 } != nil, "a failed hold refuses the start")
        #expect(second.value.flatMap { $0 } != nil)
        #expect(capture.modes.isEmpty, "a failed preparation never starts the pacer")
        #expect(backend.startCompanionAlignmentProbe(targetID: btMove.id,
            referenceID: btFlip.id, onStarted: {}, onFinished: {}) != nil,
            "the reservation is held until cleanup finishes")
        engine.releaseWrites()
        local.release()   // the cleanup's own suppression callback
        await SuiteWait.until { backend.startCompanionAlignmentProbe(targetID: self.btMove.id,
            referenceID: self.btFlip.id, onStarted: {}, onFinished: {}) == nil }
        #expect(first.value.flatMap { $0 } != nil && second.value.flatMap { $0 } != nil,
                "each joined start is answered exactly once")
        backend.cancelCompanionAlignmentProbe(targetID: btMove.id)
    }

    /// A hold failure that lands before the last acknowledgement must still be
    /// the outcome, and a repeat acknowledgement after it cannot revive the run.
    @Test @MainActor func aFailedHoldBeforeTheLastAcknowledgementRefusesOnce() async {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let (backend, bt, _, _) = makeBackend(engine: engine, discovery: discovery)
        defer { engine.releaseWrites(); backend.stop() }
        let capture = ProbeStagingCapture()
        let local = ScriptedLocalPlayback()
        local.holdsCompletions = true
        backend.captureCoordinator = capture
        backend.localPlaybackEngine = local
        backend.start()
        let ap1 = airPlay1()
        discovery.fire(.appeared(ap1))
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, ap1.id) != nil && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id, ap1.id])
        await SuiteWait.until { engine.writes.contains { $0.0 == ap1.outputID } }
        engine.blockWrites = true

        let first = LockedBox<String??>(nil)
        let second = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            first.value = .some($0)
        }
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            second.value = .some($0)
        }
        await SuiteWait.until { engine.heldCount > 0 && local.suppressions.contains(true) }

        // Reverse order: the hold fails while the local setter is still held.
        engine.releaseWritesFailing()
        await SuiteWait.until { first.value != nil && second.value != nil }
        #expect(first.value.flatMap { $0 } != nil && second.value.flatMap { $0 } != nil)
        #expect(capture.modes.isEmpty)

        // The late local acknowledgement, and a repeat of it, arrive after the
        // refusal. Neither may start clicks or answer a start a second time.
        local.release()
        local.replayLastCompletion()
        #expect(capture.modes.isEmpty, "a late acknowledgement cannot start clicks behind a refusal")
        engine.releaseWrites()
        await SuiteWait.until { backend.startCompanionAlignmentProbe(targetID: self.btMove.id,
            referenceID: self.btFlip.id, onStarted: {}, onFinished: {}) == nil }
        backend.cancelCompanionAlignmentProbe(targetID: btMove.id)
    }

    /// Counting only the engine outputs and the local setter lets the clicks
    /// start before another Bluetooth speaker's hold has reached the sink, so
    /// music bursts out of it at the top of the audition.
    @Test @MainActor func aBluetoothHoldThatAnswersLastGatesTheClicks() async {
        let (backend, bt, sink, _) = makeBackend()
        let capture = ProbeStagingCapture()
        let local = ScriptedLocalPlayback()
        defer { sink.openGainGate(); backend.stop() }
        backend.captureCoordinator = capture
        backend.localPlaybackEngine = local
        backend.start()
        bt.fire([btMove, btFlip, btExtra])
        await SuiteWait.until { self.device(backend, self.btExtra.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id, btExtra.id)
        backend.setOutputSet([btMove.id, btFlip.id, btExtra.id])
        await SuiteWait.until { sink.lastGain(for: self.btExtra.id) == 1 }

        // No Bluetooth hold can reach the sink from here.
        sink.closeGainGate()
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        // The local setter answers immediately; it is the only hold that can.
        await SuiteWait.until { local.suppressions.contains(true) }
        #expect(start.value == nil,
                "the start is not answered while a Bluetooth hold is outstanding")
        #expect(capture.modes.isEmpty,
                "clicks cannot start before every speaker's gain has reached the sink")
        #expect(sink.lastGain(for: btExtra.id) == 1, "the held speaker is still at its old gain")

        sink.openGainGate()
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))
        #expect(sink.lastGain(for: btExtra.id) == 0)
        #expect(capture.modes.contains(.wizard))

        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil))
    }

    @Test @MainActor func failedAirPlayHoldRefusesAuditionAndRestoresOutput() async {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let (backend, bt, _, _) = makeBackend(engine: engine, discovery: discovery)
        defer { backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        let ap1 = airPlay1()
        discovery.fire(.appeared(ap1))
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, ap1.id) != nil && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id, ap1.id])
        await SuiteWait.until { engine.writes.contains { $0.0 == ap1.outputID } }
        engine.failNextWrite = true
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value.flatMap { $0 }?.contains("Couldn't quiet") == true)
        await SuiteWait.until { engine.writes.last { $0.0 == ap1.outputID }?.1 != -1.0 }
        await SuiteWait.until { backend.startCompanionAlignmentProbe(targetID: self.btMove.id,
            referenceID: self.btFlip.id, onStarted: {}, onFinished: {}) == nil }
        backend.cancelCompanionAlignmentProbe(targetID: btMove.id)
    }

    /// Treating a timed-out or superseded volume callback as drainage lets a second run overlap restoration.
    @Test @MainActor func timedOutStopKeepsReservationUntilAirPlayRestorationDrains() async {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let (backend, bt, _, _) = makeBackend(engine: engine, discovery: discovery)
        defer { engine.releaseWrites(); backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.companionAuditionStopSeconds = 0.1
        backend.start()
        let ap1 = airPlay1()
        discovery.fire(.appeared(ap1))
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, ap1.id) != nil && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id, ap1.id])
        await SuiteWait.until { engine.writes.contains { $0.0 == ap1.outputID } }
        engine.blockWrites = true
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { engine.heldCount > 0 }
        #expect(engine.writes.last { $0.0 == ap1.outputID }?.1 == -1.0,
                "an AirPlay 1 hold uses the true-silence sentinel")
        backend.setVolume(75, for: ap1.id)
        await SuiteWait.until { self.device(backend, ap1.id)?.volume == 75 }
        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value.flatMap { $0 }?.contains("took too long") == true)
        #expect(backend.startCompanionAlignmentProbe(targetID: btMove.id,
            referenceID: btFlip.id, onStarted: {}, onFinished: {}) != nil,
            "the timeout may answer once but must keep the busy reservation")
        engine.releaseWrites()
        await SuiteWait.until { backend.startCompanionAlignmentProbe(targetID: self.btMove.id,
            referenceID: self.btFlip.id, onStarted: {}, onFinished: {}) == nil }
        #expect(engine.writes.last { $0.0 == ap1.outputID }?.1 != -1.0,
                "the final write uses the user's current level, after the old hold finishes")
        backend.cancelCompanionAlignmentProbe(targetID: btMove.id)
        #expect(start.value != .some(nil), "the cancelled preparation cannot report success late")
    }

    @Test @MainActor func timedOutLocalRestorationNamesTheLocalOutputAndStaysBusy() async {
        let (backend, bt, _, _) = makeBackend()
        defer { backend.stop() }
        let local = ScriptedLocalPlayback()
        backend.localPlaybackEngine = local
        backend.captureCoordinator = ProbeStagingCapture()
        backend.companionAuditionStopSeconds = 0.1
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btFlip.id) != nil }
        let localName = self.device(backend, NativeBackend.localDeviceID)?.name ?? "This Mac"
        backend.setOutputSet([btMove.id, btFlip.id])
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))
        local.holdsCompletions = true
        let replies = LockedBox<[String?]>([])
        backend.endCompanionAlignmentAudition(targetID: btMove.id) {
            replies.value = replies.value + [$0]
        }
        await SuiteWait.until { replies.value.count == 1 }
        #expect(replies.value[0]?.contains(localName) == true)
        #expect(backend.startCompanionAlignmentProbe(targetID: btMove.id,
            referenceID: btFlip.id, onStarted: {}, onFinished: {}) != nil)
        local.release()
        await SuiteWait.until { backend.startCompanionAlignmentProbe(targetID: self.btMove.id,
            referenceID: self.btFlip.id, onStarted: {}, onFinished: {}) == nil }
        #expect(replies.value.count == 1, "a timed-out stop answers only once after real drain")
        backend.cancelCompanionAlignmentProbe(targetID: btMove.id)
    }

    /// Restoring the STASHED level to a muted speaker turns it back on: the
    /// stash is what an unmute owes, never what the speaker is owed now.
    @Test @MainActor func cleanupRestoresTheMuteRatherThanTheStashedLevel() async {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let (backend, bt, _, _) = makeBackend(engine: engine, discovery: discovery)
        defer { backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        let ap1 = airPlay1()
        let ap2 = airPlay2()
        discovery.fire(.appeared(ap1))
        discovery.fire(.appeared(ap2))
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, ap1.id) != nil && self.device(backend, ap2.id) != nil
            && self.device(backend, self.btFlip.id) != nil }
        setFullVolume(backend, ap1.id, ap2.id)
        backend.setOutputSet([btMove.id, btFlip.id, ap1.id, ap2.id])
        await SuiteWait.until { engine.writes.contains { $0.0 == ap1.outputID }
            && engine.writes.contains { $0.0 == ap2.outputID } }

        // One speaker is muted before the clicks, the other during them.
        backend.setMuted(true, for: ap1.id)
        await SuiteWait.until { self.device(backend, ap1.id)?.isMuted == true }

        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))
        backend.setMuted(true, for: ap2.id)
        await SuiteWait.until { self.device(backend, ap2.id)?.isMuted == true }

        let faderBefore = (device(backend, ap1.id)?.volume, device(backend, ap2.id)?.volume)

        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil))

        #expect(engine.writes.last { $0.0 == ap1.outputID }?.1 == -1.0,
                "a muted AirPlay 1 speaker is left at the true-silence sentinel")
        #expect(engine.writes.last { $0.0 == ap2.outputID }?.1 == 0.0,
                "a muted AirPlay 2 speaker is left at zero")
        #expect(device(backend, ap1.id)?.isMuted == true, "cleanup never clears a mute")
        #expect(device(backend, ap2.id)?.isMuted == true)
        #expect(device(backend, ap1.id)?.volume == faderBefore.0, "cleanup never moves the stored fader")
        #expect(device(backend, ap2.id)?.volume == faderBefore.1)
    }

    /// Discarding the audition's live trim throws away every nudge the user
    /// made by ear the moment the sheet closes.
    @Test @MainActor func aByEarNudgeIsSavedWhenTheAuditionStops() async {
        let dir = scratchDir
        let (backend, bt, _, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        #expect(backend.btHasSyncTrim(forDevice: btMove.id) == false)

        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))
        #expect(backend.nudgeCompanionAlignmentTrim(targetID: btMove.id, deltaMs: 5) == nil)

        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil))
        #expect(backend.btSyncTrim(forDevice: btMove.id) == BTSyncTrim.quantise(5))
        // The saved value has to survive the process, not just this instance.
        let reloaded = try? BTTrimStore(directory: dir).load()
        #expect(reloaded?[btMove.id] == BTSyncTrim.quantise(5))
    }

    /// Backend shutdown is an ordinary exit too — quitting mid-audition must
    /// not be the one way to lose a by-ear nudge.
    @Test @MainActor func aByEarNudgeIsSavedWhenTheBackendShutsDown() async {
        let dir = scratchDir
        let (backend, bt, _, _) = makeBackend(storeDirectory: dir)
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(backend.nudgeCompanionAlignmentTrim(targetID: btMove.id, deltaMs: -3) == nil)
        backend.stop()
        #expect(backend.btSyncTrim(forDevice: btMove.id) == BTSyncTrim.quantise(-3))
        let reloaded = try? BTTrimStore(directory: dir).load()
        #expect(reloaded?[btMove.id] == BTSyncTrim.quantise(-3))
    }

    /// Opening and closing the clicks without touching the ruler, or undoing
    /// every nudge, must not mint an alignment entry for a speaker that had none.
    @Test @MainActor func anUnchangedOrRevertedTrimWritesNothing() async {
        let dir = scratchDir
        let (backend, bt, _, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])

        for nudgeThenRevert in [false, true] {
            let start = LockedBox<String??>(nil)
            backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
                start.value = .some($0)
            }
            await SuiteWait.until { start.value != nil }
            #expect(start.value == .some(nil))
            if nudgeThenRevert {
                #expect(backend.nudgeCompanionAlignmentTrim(targetID: btMove.id, deltaMs: 7) == nil)
                #expect(backend.revertCompanionAlignmentNudge(targetID: btMove.id) == nil)
            }
            let stop = LockedBox<String??>(nil)
            backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
            await SuiteWait.until { stop.value != nil }
            #expect(stop.value == .some(nil))
            #expect(backend.btHasSyncTrim(forDevice: btMove.id) == false,
                    nudgeThenRevert ? "an undone nudge writes nothing"
                                    : "an untouched ruler writes nothing")
            #expect((try? BTTrimStore(directory: dir).load())?[btMove.id] == nil)
        }
    }

    /// A Clear that follows the stop acknowledgement must leave no entry — a
    /// drain that writes the nudge back would put the row straight back to
    /// "tuned" a moment after it read "Timing not set".
    @Test @MainActor func aClearAfterTheStopLeavesNoEntry() async {
        let dir = scratchDir
        let (backend, bt, _, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(backend.nudgeCompanionAlignmentTrim(targetID: btMove.id, deltaMs: 9) == nil)
        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil))
        #expect(backend.btHasSyncTrim(forDevice: btMove.id) == true)

        backend.clearCompanionAlignmentTuning(targetID: btMove.id)
        SuiteWait.settle(0.3)
        #expect(backend.btHasSyncTrim(forDevice: btMove.id) == false)
        #expect((try? BTTrimStore(directory: dir).load())?[btMove.id] == nil)
    }

    /// Reading `lastVolumeOutcome` as proof of restoration blames the
    /// restoration for whatever wrote last — including the user's own failed
    /// edit, which says nothing about whether the speaker was put back.
    @Test @MainActor func aFailedUserEditDuringCleanupIsNotBlamedOnTheRestoration() async {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let (backend, bt, _, _) = makeBackend(engine: engine, discovery: discovery)
        defer { engine.releaseWrites(); backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        let ap1 = airPlay1()
        discovery.fire(.appeared(ap1))
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, ap1.id) != nil && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id, ap1.id])
        await SuiteWait.until { engine.writes.contains { $0.0 == ap1.outputID } }
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))

        // The restoration write is in flight; the user's edit queues behind it
        // and is the one that fails.
        engine.blockWrites = true
        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { engine.heldCount > 0 }
        engine.failNextWrite = true
        backend.setVolume(60, for: ap1.id)
        engine.releaseWrites()

        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil),
                "the restoration completed; the user's own failed edit is not its failure")
        await SuiteWait.until { backend.startCompanionAlignmentProbe(targetID: self.btMove.id,
            referenceID: self.btFlip.id, onStarted: {}, onFinished: {}) == nil }
        backend.cancelCompanionAlignmentProbe(targetID: btMove.id)
    }

    /// Without a lifetime signal the executable has to guess when cleanup
    /// ended, and a stop that refused on its timeout looks like the end.
    @Test @MainActor func theLifetimeCallbackFiresOnceAfterTheRealDrainNotTheTimeout() async {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let (backend, bt, _, _) = makeBackend(engine: engine, discovery: discovery)
        defer { engine.releaseWrites(); backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.companionAuditionStopSeconds = 0.1
        backend.start()
        let ap1 = airPlay1()
        discovery.fire(.appeared(ap1))
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, ap1.id) != nil && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id, ap1.id])
        await SuiteWait.until { engine.writes.contains { $0.0 == ap1.outputID } }

        let released = LockedBox<Int>(0)
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(
            targetID: btMove.id, referenceID: btFlip.id,
            onReleased: { released.value = released.value + 1 },
            completion: { start.value = .some($0) })
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))

        // A second start for a DIFFERENT pair is refused before it claims
        // anything, so its own lifetime callback is answered right away.
        let refusedReleased = LockedBox<Int>(0)
        let refused = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(
            targetID: btFlip.id, referenceID: btMove.id,
            onReleased: { refusedReleased.value = refusedReleased.value + 1 },
            completion: { refused.value = .some($0) })
        await SuiteWait.until { refused.value != nil && refusedReleased.value == 1 }
        #expect(refused.value.flatMap { $0 } != nil)
        #expect(released.value == 0, "the live audition's own signal is untouched")

        engine.blockWrites = true
        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { stop.value != nil }
        #expect(stop.value.flatMap { $0 }?.contains("took too long") == true)
        #expect(released.value == 0, "a refused stop does not consume the lifetime signal")
        #expect(backend.startCompanionAlignmentProbe(targetID: btMove.id,
            referenceID: btFlip.id, onStarted: {}, onFinished: {}) != nil)

        engine.releaseWrites()
        await SuiteWait.until { released.value == 1 }
        await SuiteWait.until { backend.startCompanionAlignmentProbe(targetID: self.btMove.id,
            referenceID: self.btFlip.id, onStarted: {}, onFinished: {}) == nil }
        SuiteWait.settle(0.3)
        #expect(released.value == 1, "the lifetime signal fires exactly once")
        #expect(refusedReleased.value == 1)
        backend.cancelCompanionAlignmentProbe(targetID: btMove.id)
    }

    /// Backend teardown is the other honest end of a reservation: the engine
    /// sessions are gone, so no late write can reach a new one.
    @Test @MainActor func theLifetimeCallbackFiresOnceAfterBackendTeardown() async {
        let (backend, bt, _, _) = makeBackend()
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        let released = LockedBox<Int>(0)
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(
            targetID: btMove.id, referenceID: btFlip.id,
            onReleased: { released.value = released.value + 1 },
            completion: { start.value = .some($0) })
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))
        backend.stop()
        await SuiteWait.until { released.value == 1 }
        SuiteWait.settle(0.3)
        #expect(released.value == 1)
    }

    /// The level a speaker is owed can change while cleanup is draining; the
    /// value pushed when cleanup began is then simply stale.
    @Test @MainActor func cleanupFollowsAnUnmuteAndAFaderEditMadeWhileItDrains() async {
        let engine = RecordingEngine()
        let discovery = FakeDiscovery()
        let (backend, bt, _, _) = makeBackend(engine: engine, discovery: discovery)
        defer { engine.releaseWrites(); backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        let ap1 = airPlay1()
        discovery.fire(.appeared(ap1))
        bt.fire([btMove, btFlip])
        await SuiteWait.until { self.device(backend, ap1.id) != nil && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id, ap1.id])
        await SuiteWait.until { engine.writes.contains { $0.0 == ap1.outputID } }
        backend.setMuted(true, for: ap1.id)
        await SuiteWait.until { self.device(backend, ap1.id)?.isMuted == true }

        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))

        engine.blockWrites = true
        let stop = LockedBox<String??>(nil)
        backend.endCompanionAlignmentAudition(targetID: btMove.id) { stop.value = .some($0) }
        await SuiteWait.until { engine.heldCount > 0 }
        // A fader edit while muted writes nothing at all — it only moves the
        // stash — and the unmute behind it is what changes the level owed.
        backend.setVolume(70, for: ap1.id)
        backend.setMuted(false, for: ap1.id)
        await SuiteWait.until { self.device(backend, ap1.id)?.isMuted == false }
        engine.releaseWrites()

        await SuiteWait.until { stop.value != nil }
        #expect(stop.value == .some(nil))
        #expect(device(backend, ap1.id)?.volume == 70)
        #expect(device(backend, ap1.id)?.isMuted == false)
        #expect(engine.writes.last { $0.0 == ap1.outputID }?.1 == NativeBackend.engineVolumeAP1(70),
                "the speaker is left at the level it is owed now, not the one cleanup began with")
    }

    @Test @MainActor func backendShutdownClearsTemporaryParticipantHoldBeforeRestart() async {
        let (backend, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        bt.fire([btMove, btFlip, btExtra])
        await SuiteWait.until { self.device(backend, self.btExtra.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id, btExtra.id)
        backend.setOutputSet([btMove.id, btFlip.id, btExtra.id])
        let start = LockedBox<String??>(nil)
        backend.startCompanionAlignmentAudition(targetID: btMove.id, referenceID: btFlip.id) {
            start.value = .some($0)
        }
        await SuiteWait.until { start.value != nil }
        #expect(start.value == .some(nil))
        await SuiteWait.until { sink.lastGain(for: self.btExtra.id) == 0 }
        backend.stop()
        backend.start()
        bt.fire([btMove, btFlip, btExtra])
        await SuiteWait.until { self.device(backend, self.btExtra.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id, btExtra.id)
        backend.setOutputSet([btMove.id, btFlip.id, btExtra.id])
        await SuiteWait.until { sink.lastGain(for: self.btExtra.id) == 1 }
    }

    // MARK: - Trigger matrix

    /// Never-aligned + first mix (two BT devices) → both offer alignment and
    /// both PLAY: the offer never silences a speaker, it only asks the UI to
    /// put a note under the row.
    @Test func neverAlignedFirstMixFiresAndStaysAudible() {
        let (backend, bt, sink, events) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btMove.id) != nil && self.device(backend, self.btFlip.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id)

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 && sink.gains.count >= 2 }
        waitFor { sink.lastGain(for: self.btMove.id) == 1 && sink.lastGain(for: self.btFlip.id) == 1 }

        #expect(Set(events.promptedDeviceIDs()) == [btMove.id, btFlip.id])
        #expect(sink.lastGain(for: btMove.id) == 1, "the offer plays the speaker as-is")
        #expect(sink.lastGain(for: btFlip.id) == 1)
    }

    /// Solo BT never fires — a lone speaker has nothing to align with.
    @Test func soloBTNeverFires() {
        let (backend, bt, sink, events) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        setFullVolume(backend, btMove.id)

        backend.setOutputSet([btMove.id])
        waitFor { !sink.gains.isEmpty }

        #expect(events.promptedDeviceIDs().isEmpty)
        #expect(sink.lastGain(for: btMove.id) == 1, "a solo select plays at full gain")
    }

    /// The same solo speaker later joined by a second device IS the first
    /// mix — the intercept fires then, not at the solo select.
    @Test func mixFormingLaterFiresThePrompt() {
        let (backend, bt, _, events) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }

        backend.setOutputSet([btMove.id])
        SuiteWait.settle(0.5)   // settle; nothing should fire
        #expect(events.promptedDeviceIDs().isEmpty)

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 }
        #expect(Set(events.promptedDeviceIDs()) == [btMove.id, btFlip.id])
    }

    /// A device with a SAVED trim is aligned — never intercepted.
    @Test func alignedDeviceNeverFires() throws {
        let dir = scratchDir
        var trims: [String: Double] = [:]
        trims[btMove.id] = 80
        try BTTrimStore(directory: dir).save(trims)

        let (backend, bt, sink, events) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id)

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 1 }

        #expect(events.promptedDeviceIDs() == [btFlip.id],
                "only the never-aligned device prompts; the trimmed one plays")
        waitFor { sink.lastGain(for: self.btMove.id) == 1 }
        #expect(sink.lastGain(for: btMove.id) == 1)
    }

    /// Un-resolved (abandoned) prompts don't re-fire within the session —
    /// once ever per device on its own.
    @Test func promptFiresOncePerSession() {
        let (backend, bt, _, events) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 }
        backend.setOutputSet([btMove.id])
        backend.setOutputSet([btMove.id, btFlip.id])
        SuiteWait.settle(0.5)   // settle

        #expect(events.promptedDeviceIDs().count == 2, "no re-prompt on re-forming the mix")
    }

    /// The wizard's own hold, end to end: nothing holds the target on the way
    /// IN (there is no first-mix hold any more), and the run's hold on the
    /// other speakers clears when the run ends. A guided run against a gain-0
    /// sink asks the user which speaker ticked first while one of them is muted.
    @Test func theWizardsReleaseLeavesTheTargetAudible() {
        let (backend, bt, sink, events) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id)

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 }
        waitFor { sink.lastGain(for: self.btMove.id) == 1 }
        #expect(sink.lastGain(for: btMove.id) == 1, "the offer never held the target")

        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id,
                                      btReferenceDeviceID: "mac")
        waitFor { sink.lastGain(for: self.btFlip.id) == 0 }
        #expect(sink.lastGain(for: btMove.id) == 1, "the wizard's target ticks audibly")

        backend.endBTWizardRun()
        waitFor { sink.lastGain(for: self.btFlip.id) == 1 }
        #expect(sink.lastGain(for: btFlip.id) == 1, "the wizard's own hold clears on end-run")
    }

    // MARK: - Wizard preview plumbing (W2)

    /// A preview pushes the live trim but never the store; ending with `nil`
    /// re-pushes the stored value; keeping persists through the normal path.
    @Test func wizardPreviewRestoreAndKeep() throws {
        let dir = scratchDir
        try BTTrimStore(directory: dir).save([btMove.id: 40])
        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.trims.isEmpty }   // the enable re-pushed the stored 40

        backend.setBTWizardTrimPreview(150, forDevice: btMove.id)
        waitFor { sink.trims.last?.ms == 150 }
        #expect(sink.trims.last?.ms == 150)
        #expect(try BTTrimStore(directory: dir).load()?[btMove.id] == 40,
                "a preview never touches the store")
        #expect(backend.btSyncTrim(forDevice: btMove.id) == 40,
                "nor the stored trim table")

        backend.endBTWizardTrimPreview(forDevice: btMove.id, keepMs: nil)
        waitFor { sink.trims.last?.ms == 40 }
        #expect(sink.trims.last?.ms == 40, "cancel restores the stored trim live")

        backend.setBTWizardTrimPreview(-90, forDevice: btMove.id)
        waitFor { sink.trims.last?.ms == -90 }
        backend.endBTWizardTrimPreview(forDevice: btMove.id, keepMs: -90)
        waitFor { backend.btSyncTrim(forDevice: self.btMove.id) == -90 }
        #expect(backend.btSyncTrim(forDevice: btMove.id) == -90)
        #expect(try BTTrimStore(directory: dir).load()?[btMove.id] == -90,
                "Keep persists through the ordinary trim path")
    }

    // MARK: - Measured latency (roadmap 056 Part A)

    /// The wizard's Bluetooth run writes the device's MEASURED LATENCY, live and
    /// without a rebuild, and leaves the user's trim exactly where it was.
    @Test func wizardLatencyPreviewRestoreAndKeep() throws {
        let dir = scratchDir
        try BTTrimStore(directory: dir).save([btMove.id: 40])
        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.trims.isEmpty }

        backend.setBTWizardLatencyPreview(320, forDevice: btMove.id)
        waitFor { sink.offsets.last?.ms == 320 }
        #expect(sink.offsets.last?.ms == 320)
        #expect(backend.btMeasuredLatencyMs(forDevice: btMove.id) == nil,
                "a preview never enters the stored latency table")

        backend.endBTWizardLatencyPreview(forDevice: btMove.id, keepMs: nil)
        waitFor { sink.offsets.last?.ms == 0 }
        #expect(sink.offsets.last?.ms == 0, "cancel restores the stored latency (none yet)")

        backend.setBTWizardLatencyPreview(280, forDevice: btMove.id)
        waitFor { sink.offsets.last?.ms == 280 }
        let capture = LineCapture()
        Telemetry._installTestSink { capture.append($0) }
        defer { Telemetry._installTestSink(nil) }
        backend.endBTWizardLatencyPreview(forDevice: btMove.id, keepMs: 280)
        waitFor { backend.btMeasuredLatencyMs(forDevice: self.btMove.id) == 280 }
        #expect(try BTTrimStore(directory: dir).loadLatencies()?[btMove.id] == 280,
                "Keep persists the measurement")
        // The run measured with the trim SUSPENDED, and the trim was a manual
        // stand-in for exactly this latency — keeping both would double the
        // correction, so Keep zeroes the nudge and it starts fresh.
        waitFor { backend.btSyncTrim(forDevice: self.btMove.id) == 0 }
        #expect(backend.btSyncTrim(forDevice: btMove.id) == 0)
        #expect(try BTTrimStore(directory: dir).load()?[btMove.id] == 0,
                "…and the zeroed trim is persisted with it")
        waitFor { sink.trims.last?.ms == 0 }
        let latencyIndex = sink.offsets.lastIndex { $0.ms == 280 }
        #expect(sink.trims.last?.ms == 0, "the sink hears the cleared trim too")
        #expect(latencyIndex != nil, "the measurement reached the sink")
        // The run's receipt in the log: both halves of the delay term Keep
        // wrote, so a live report never has to infer one from the other.
        waitFor { !capture.lines(evt: "wizard_keep").isEmpty }
        let keepLine = capture.lines(evt: "wizard_keep").first
        #expect(keepLine?.contains("\"uid\":\"\(btMove.id)\"") == true,
                "Keep logs its own line: \(keepLine ?? "none")")
        #expect(keepLine?.contains("\"latencyMs\":\"280\"") == true)
        #expect(keepLine?.contains("\"trimMs\":\"0\"") == true)
        #expect(keepLine?.contains("\"clockState\":\"unknown\"") == true,
                "the Mac publishes a clock verdict, never a number of seconds")
    }

    /// A first pairing, and any speaker already connected when the app
    /// launched, are the only link-up this process will ever see for that
    /// device — so the first listing of a CONNECTED speaker opens a settle
    /// window too (owner's call, 2026-09-04). It stales nothing: with no
    /// alignment instant recorded there is nothing for the connect to be after.
    /// A speaker listed disconnected gets no window; its link-up comes later.
    @Test func theFirstListingOfAConnectedSpeakerOpensASettleWindow() throws {
        let dir = scratchDir
        try BTTrimStore(directory: dir).save([btMove.id: 40])
        let (backend, bt, _, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, BTDeviceSnapshot(id: btFlip.id, name: btFlip.name, isConnected: false)])
        waitFor { self.device(backend, self.btFlip.id) != nil }

        let move = backend.btAlignmentReport(forDevice: btMove.id)
        #expect(move?.clockState == .unknown, "the launch-time link-up opens the window")
        #expect(move?.status == .tuned, "…and stales nothing: no alignment instant to be after")
        #expect(backend.btAlignmentReport(forDevice: btFlip.id)?.clockState == .steady,
                "a speaker that is not connected has had no link-up to settle from")
    }

    /// The release event names a speaker by an index this install hands out,
    /// because the UID is derived from the speaker's MAC address. The index
    /// has to survive a reconnect, or one speaker's history splits in two, and
    /// two speakers must never share one, or two histories merge. Mint it from
    /// the map's count instead of its highest value and a cleared entry does
    /// exactly that.
    @Test func eachSpeakerKeepsOneIndexAndNoTwoShareIt() throws {
        let dir = scratchDir
        let (backend, bt, _, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        let capture = LineCapture()
        Telemetry._installTestSink { capture.append($0) }
        defer { Telemetry._installTestSink(nil) }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btMove.id) != nil
            && self.device(backend, self.btFlip.id) != nil }

        // Each link drops before its clock settles, so each closes its record
        // on the way out.
        backend.btSpeakerTiming.noteDisconnected(uid: btMove.id)
        backend.btSpeakerTiming.noteConnected(uid: btMove.id)
        backend.btSpeakerTiming.noteDisconnected(uid: btMove.id)
        backend.btSpeakerTiming.noteDisconnected(uid: btFlip.id)
        waitFor { capture.lines(evt: "bt_link_settled").count == 3 }

        func speakerKeys(in lines: [String]) -> [String] {
            lines.compactMap { line in
                line.split(separator: ",")
                    .first { $0.contains("\"speaker\":") }?
                    .split(separator: ":").last.map { $0.replacingOccurrences(of: "\"", with: "") }
            }
        }
        let keys = speakerKeys(in: capture.lines(evt: "bt_link_settled"))
        try #require(keys.count == 3)
        #expect(keys[0] == keys[1], "the same speaker keeps its index across two link-ups")
        #expect(keys[2] != keys[0], "and the other speaker has one of its own")
        #expect(try BTTrimStore(directory: dir).loadSpeakerIndex()?.count == 2,
                "the index outlives the process that minted it")
    }

    /// The Mac's own alignment paths go through the timing store like the
    /// phone's do: Keep, Reset and a persisted trim each move the row, a
    /// reconnect leaves it tuned on last time's number, and a Keep made while
    /// the clock is still settling is marked early without any extra code at
    /// the site.
    @Test func theMacsOwnAlignmentPathsMoveWhatTheRowPublishes() throws {
        let (backend, bt, _, _) = makeBackend(storeDirectory: scratchDir)
        defer { backend.stop() }
        final class ChangeCount: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int { lock.withLock { _value } }
            func bump() { lock.withLock { _value += 1 } }
        }
        let changes = ChangeCount()
        backend.onBTAlignmentChanged = { changes.bump() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        let uid = btMove.id
        func report() -> BTSpeakerTimingReport? { backend.btAlignmentReport(forDevice: uid) }
        /// Eleven advancing samples a second apart: ten stable seconds, and
        /// the store's one publish on arriving there.
        func settleTheClock() {
            let from = Date()
            for s in 0...10 {
                backend.btSpeakerTiming.noteClockOutcome(
                    uid: uid, outcome: .advanced, at: from.addingTimeInterval(Double(s)))
            }
        }

        settleTheClock()
        let base = changes.value
        backend.endBTWizardLatencyPreview(forDevice: uid, keepMs: 280)
        #expect(report()?.status == .tuned, "a Keep while stable is an ordinary alignment")
        #expect(report()?.source == .byEar, "the Mac's own wizard has no microphone")
        #expect(changes.value == base + 1)

        // The link drops and comes back. Nobody in this process asked, so
        // only the enumerator's availability edge can report it.
        bt.fire([BTDeviceSnapshot(id: uid, name: btMove.name, isConnected: false)])
        waitFor { self.device(backend, uid)?.isAvailable == false }
        bt.fire([btMove])
        waitFor { report()?.source == .fromLastTime }
        #expect(report()?.status == .tuned, "the stored offset is applied again, so nothing is asked")
        #expect(report()?.staleReason == nil)
        #expect(report()?.clockState == .unknown, "a new link, and no verdict on its clock yet")
        #expect(report()?.settleRemainingSeconds == nil)
        #expect(changes.value == base + 2)

        backend.endBTWizardLatencyPreview(forDevice: uid, keepMs: 300)
        #expect(report()?.status == .stale, "a Keep before the clock settles again is early")
        #expect(report()?.staleReason == BTSpeakerTiming.staleReasonMeasuredWhileSettling)
        #expect(report()?.source == .firstPass)
        #expect(changes.value == base + 3)

        settleTheClock()
        backend.endBTWizardLatencyPreview(forDevice: uid, keepMs: 310)
        #expect(report()?.status == .tuned, "…and one after it settles clears the mark")
        #expect(report()?.staleReason == nil)
        #expect(changes.value == base + 5, "the arrival at stable, then the Keep")

        backend.resetBTAlignment(forDevice: uid)
        #expect(report()?.status == .notSet)
        #expect(changes.value == base + 6)

        backend.setBTSyncTrim(12, forDevice: uid, persist: true)
        #expect(report()?.status == .tuned, "a persisted nudge is an alignment")
        #expect(changes.value == base + 7)
        backend.setBTSyncTrim(13, forDevice: uid, persist: false)
        #expect(changes.value == base + 7, "a scrub is not")
    }

    /// ADR 0001's 10 ms line, down the path the phone actually uses: a
    /// re-measurement that disagrees replaces the stored offset, one that
    /// agrees leaves it where it is and tells the phone nothing moved. Drop
    /// the decision and every re-check rewrites the speaker's latency by
    /// whatever the room's scatter was that time.
    @Test func aReportedMeasurementReplacesTheStoredOffsetOrKeepsIt() throws {
        let dir = scratchDir
        try BTTrimStore(directory: dir).save([btMove.id: 40])
        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.captureCoordinator = ProbeStagingCapture()
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.trims.isEmpty }
        let uid = btMove.id
        // Ten jump-free seconds first, so what follows is measured against a
        // clock the Mac calls steady rather than filed as a first pass.
        let from = Date()
        for second in 0...10 {
            backend.btSpeakerTiming.noteClockOutcome(
                uid: uid, outcome: .advanced, at: from.addingTimeInterval(Double(second)))
        }
        backend.endBTWizardLatencyPreview(forDevice: uid, keepMs: 300)
        waitFor { backend.btMeasuredLatencyMs(forDevice: uid) == 300 }
        let capture = LineCapture()
        Telemetry._installTestSink { capture.append($0) }
        defer { Telemetry._installTestSink(nil) }

        func measure(offsetMs: Double) -> CompanionAlignmentApplyResult {
            #expect(backend.startCompanionAlignmentProbe(
                targetID: uid, referenceID: "local", onStarted: {}, onFinished: {}) == nil)
            return backend.applyCompanionAlignmentMeasurement(
                targetID: uid, offsetMs: offsetMs, confidence: 40)
        }

        #expect(measure(offsetMs: 11) == .applied(measuredMs: 11, correctedMs: 11))
        #expect(backend.btMeasuredLatencyMs(forDevice: uid) == 311)
        #expect(backend.btAlignmentReport(forDevice: uid)?.source == .measured,
                "the microphone found this one, not the ear")

        #expect(measure(offsetMs: 9) == .applied(measuredMs: 9, correctedMs: 0),
                "under the line the stored offset stands, and the phone is told nothing moved")
        #expect(backend.btMeasuredLatencyMs(forDevice: uid) == 311)

        waitFor { capture.lines(evt: "bt_align_measurement").count == 2 }
        let measurements = capture.lines(evt: "bt_align_measurement")
        #expect(measurements.first?.contains("\"replaced\":\"1\"") == true,
                "the log says which way each measurement went: \(measurements)")
        #expect(measurements.first?.contains("\"keptMs\":\"311.0\"") == true)
        #expect(measurements.last?.contains("\"replaced\":\"0\"") == true)
        #expect(measurements.last?.contains("\"keptMs\":\"311.0\"") == true)
    }

    /// The candidate range a run may present ignores the device's trim, because
    /// the run suspends it. Reading it back in used to pollute the measurement
    /// (a level judged at `latency + trim`) and, for a trim more negative than
    /// the hardware latency, collapse the range onto 0 — a run that bowed out
    /// `.unreachable` before it could ask anything.
    @Test func theWizardLatencyRangeIgnoresTheDevicesTrim() throws {
        let dir = scratchDir
        try BTTrimStore(directory: dir).save([btMove.id: -300])
        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.trims.isEmpty }

        #expect(backend.btSyncTrim(forDevice: btMove.id) == -300, "the trim is really there")
        #expect(backend.btWizardLatencyRangeMs(forDevice: btMove.id) == -500...1_500,
                "the reference less one BT-only buffer is reachable — the trim steps aside")
    }

    /// The BT-only reference timeline must clear the slowest KNOWN speaker,
    /// otherwise its delay hits the ≥ 0 clamp and no trim can reach the group.
    @Test func theBTOnlyReferenceClearsTheSlowestMeasuredSpeaker() {
        #expect(NativeBackend.btOnlyReferenceMs(latencies: [:], uids: ["a"]) == 500,
                "nothing measured — the floor stands")
        #expect(NativeBackend.btOnlyReferenceMs(latencies: ["a": 150], uids: ["a"]) == 500,
                "inside the floor — still the floor")
        #expect(NativeBackend.btOnlyReferenceMs(latencies: ["a": 650], uids: ["a"]) == 750,
                "past the floor — the slowest speaker plus headroom")
        #expect(NativeBackend.btOnlyReferenceMs(latencies: ["a": 650, "b": 900],
                                                uids: ["a", "b"]) == 1_000,
                "the SLOWEST of the selected devices sets it")
        #expect(NativeBackend.btOnlyReferenceMs(latencies: ["a": 650, "b": 900],
                                                uids: ["a"]) == 750,
                "…and only the selected ones count")
    }

    /// A negative trim is a speaker asking to play earlier, which on the
    /// speaker that sets the floor only "every other speaker later" can give:
    /// it counts as extra latency when the floor is chosen.
    @Test func aNegativeTrimRaisesTheBTOnlyReferenceLikeLatency() {
        let latencies = ["move2": 483.0, "move": 295.0]
        #expect(NativeBackend.btOnlyReferenceMs(latencies: latencies, trims: ["move2": -10],
                                                uids: ["move2", "move"]) == 593)
        #expect(NativeBackend.btOnlyReferenceMs(latencies: latencies, trims: ["move2": 40],
                                                uids: ["move2", "move"]) == 583,
                "a positive trim plays later — it never needs the floor to move")
        #expect(NativeBackend.btOnlyReferenceMs(latencies: latencies, trims: ["move": -150],
                                                uids: ["move2", "move"]) == 583,
                "a speaker still inside the floor leaves it alone")
    }

    /// DEFECT (customer, 1.2.0): Move 2 set the floor (483 + 100 = 583), sat
    /// 100 ms behind it, and every committed −10 ms was stored while the sink
    /// applied none of it. The commit must raise the floor so the trim plays.
    /// A speaker whose trim leaves the floor where it is gets the sink's own
    /// clamp check instead; the one that moved the floor does not need it — a
    /// floor move re-anchors every sink already.
    @Test func aCommittedNegativeTrimOnTheFloorSpeakerRaisesTheReference() throws {
        let dir = scratchDir
        try BTTrimStore(directory: dir).saveLatencies([btMove.id: 483, btFlip.id: 295])
        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btMove.id) != nil
            && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { sink.buffers.last == 583 }

        backend.setBTSyncTrim(-10, forDevice: btMove.id, persist: false)
        backend.setBTSyncTrim(-10, forDevice: btMove.id, persist: true)
        waitFor { sink.buffers.last == 593 }
        #expect(sink.buffers.last == 593, "483 + 10 + 100: the other speaker plays 10 ms later")

        backend.setBTSyncTrim(-20, forDevice: btFlip.id, persist: true)
        waitFor { sink.clampChecks.contains(self.btFlip.id) }
        #expect(sink.clampChecks == [btFlip.id],
                "only the commit that left the floor alone asks the sink")
        #expect(sink.buffers.last == 593)
    }

    // MARK: - Passive drift tracking (roadmap 085 ticket 05)

    /// DEFECT: the baseline guard asked `btStoredAlignmentOffsetMs`, which
    /// counts a bare by-ear trim as calibration. A baseline is `room + trim`,
    /// which presumes a measured latency the sink subtracts; on a trim-only
    /// speaker the trim IS the stand-in for that unmeasured latency, so the
    /// speaker really arrives a whole true latency off the baseline. Within the
    /// sampler's search width the first window "corrected" it — writing a
    /// measured latency while the stand-in trim stayed, which is the double
    /// compensation the wizard's Keep zeroes the trim to avoid — and beyond it,
    /// left a baseline no peak matches for nearest-peak attribution to hand
    /// another speaker's jump to.
    @Test func onlyMeasuredSpeakersBecomeDriftBaselines() {
        let baselines = NativeBackend.btDriftBaselines(
            uids: ["measured", "trim-only", "untouched"],
            latencies: ["measured": 300],
            trims: ["measured": -5, "trim-only": -120],
            roomMs: 500)

        #expect(baselines.map(\.deviceUID) == ["measured"],
                "a trim is not a measurement, and an untouched speaker is neither")
        #expect(baselines.first?.expectedDelayMs == 495,
                "room + trim — the measured latency cancels against the sink's own subtraction")
    }

    /// DEFECT: one Bluetooth speaker with no anchor ran anyway. Its whole
    /// evidence is that one peak moved, which is equally the speaker drifting
    /// and the microphone moving, and the sampler's shared-shift guard needs a
    /// second speaker to tell the two apart. Worse, the correction cancelled
    /// itself whenever that speaker's latency set the reference floor — raising
    /// the latency raised the floor by the same amount, the hold never moved,
    /// and every window re-corrected the surviving error, marching the latency
    /// and the buffer up together.
    @Test func driftTrackingNeedsSomethingToAlignAgainst() {
        #expect(NativeBackend.driftTrackingRuns(bluetoothCount: 0, anchorCount: 0) == false)
        #expect(NativeBackend.driftTrackingRuns(bluetoothCount: 0, anchorCount: 2) == false,
                "anchors alone measure only the microphone")
        #expect(NativeBackend.driftTrackingRuns(bluetoothCount: 1, anchorCount: 0) == false,
                "one speaker, nothing to align it against")
        #expect(NativeBackend.driftTrackingRuns(bluetoothCount: 1, anchorCount: 1) == true,
                "an AirPlay receiver is the reference the lone speaker lacked")
        #expect(NativeBackend.driftTrackingRuns(bluetoothCount: 2, anchorCount: 0) == true,
                "two speakers: a shift they share is the microphone's, and re-baselines")
    }

    /// DEFECT: every drift write recomputed the reference floor, slew steps
    /// included. A slew steps twice a second, and a floor move is not a quiet
    /// bookkeeping change — it rebuilds every Bluetooth sink and re-anchors the
    /// Mac's own, a full-delay silence each time, inside a move whose whole
    /// point is to be inaudible. The floor now moves once, on the committed
    /// write that ends the slew.
    @Test func aSlewStepLeavesTheReferenceFloorAlone() throws {
        let dir = scratchDir
        try BTTrimStore(directory: dir).saveLatencies([btMove.id: 640, btFlip.id: 640])
        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        backend.attachPassiveDriftTracking(ring: ReferenceAudioRing())
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btMove.id) != nil
            && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { sink.buffers.last == 740 }
        let floorMoves = sink.buffers.count

        // Nothing has rendered, so the program reads as playing and the
        // correction slews. The first step lands at once.
        let applier = try #require(backend.driftApplier)
        applier.handle([.init(deviceUID: btMove.id, errorMs: 20,
                              hostNanos: 0, isBestGuess: false)])
        waitFor { sink.offsets.contains { $0.uid == self.btMove.id && $0.ms == 641 } }

        #expect(sink.buffers.count == floorMoves,
                "the step reached the sink, the floor did not move")
        #expect(sink.buffers.last == 740)
    }

    /// DEFECT (customer log, 1.2.0): deselecting one of two measured speakers
    /// moved the reference, and the move rebuilt EVERY sink the manager still
    /// held, the departing one included, before `setDevices` dropped it. So a
    /// speaker the user had just turned off restarted its engine once, and on
    /// that night the restart failed with -10851 into the log.
    @Test func aDeselectedSpeakerIsDroppedBeforeTheReferenceMoves() throws {
        let dir = scratchDir
        try BTTrimStore(directory: dir).saveLatencies([btMove.id: 583, btFlip.id: 527])
        let (backend, bt, _, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        let real = BTSyncedSink(renderSampleRate: 48_000, channelCount: 1, presentationDelayMs: { 100 })
        backend.btSyncedSinkFactory = { real }
        backend.btDeviceIDForUID = { _ in AudioObjectID(0) }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btMove.id) != nil
            && self.device(backend, self.btFlip.id) != nil }
        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { real.sinkForTesting(uid: self.btMove.id) != nil
            && real.sinkForTesting(uid: self.btFlip.id) != nil }
        real.sinkForTesting(uid: btMove.id)?.test_waitForPendingRebuild()
        real.sinkForTesting(uid: btFlip.id)?.test_waitForPendingRebuild()

        let capture = LineCapture()
        Telemetry._installTestSink { capture.append($0) }
        defer { Telemetry._installTestSink(nil) }
        backend.setOutputSet([btFlip.id])   // reference 683 → 627 ms
        waitFor { real.sinkForTesting(uid: self.btMove.id) == nil
            && capture.lines(evt: "bt_sink_rebuild").contains { $0.contains(self.btFlip.id) } }
        Telemetry._installTestSink(nil)     // flush barrier

        let rebuilds = capture.lines(evt: "bt_sink_rebuild")
        #expect(!rebuilds.contains { $0.contains(btMove.id) },
                "the deselected speaker must not be rebuilt on its way out: \(rebuilds)")
        #expect(rebuilds.contains { $0.contains(btFlip.id) },
                "positive control: the reference moved, so the remaining speaker re-anchors")
    }

    /// Selecting a device whose measured latency is past the floor moves the
    /// reference for the BT sinks AND for the Mac's own, which rides it.
    @Test func aStoredLatencyRaisesTheReferenceOnSelect() throws {
        let dir = scratchDir
        try BTTrimStore(directory: dir).saveLatencies([btMove.id: 640])
        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { sink.buffers.last == 740 }
        #expect(sink.buffers.last == 740, "640 ms measured + 100 ms headroom")
        #expect(sink.offsets.contains { $0.uid == self.btMove.id && $0.ms == 640 },
                "the measurement reaches the sink on arm")
        #expect(backend.localSinkReferenceDelayMs() == 740,
                "the Mac schedules against the same reference in this composition")
    }

    /// A Bluetooth-target wizard run pins the reference wide open — the latency
    /// it is measuring is unknown, so the search needs room to reach it — and it
    /// STAYS pinned through the receipt. The tick stops when the questions do,
    /// and lowering the reference there dropped the very result the user was
    /// being asked to judge onto a timeline that clamps it: "Aligned — 640 ms"
    /// on screen over a speaker no longer aligned. Only the run ending lowers it.
    @Test func aBluetoothWizardRunPinsTheReferenceThroughTheReceipt() {
        let (backend, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.buffers.isEmpty }   // applyBTSinkTransition has begun: it pushes the buffer
                                    // right after creating the sink and setting composition.
                                    // NOT a claim that the sink is fully engaged — gains, EQ,
                                    // setDevices and start() all follow. The old
                                    // `!sink.trims.isEmpty` barrier could never fire here: that
                                    // loop only runs for PERSISTED trims, and this test stores none.

        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        waitFor { sink.buffers.last == NativeBackend.btWizardReferenceBufferMs }
        #expect(sink.buffers.last == 2_000)
        #expect(backend.btWizardLatencyRangeMs(forDevice: btMove.id) == -500...1_500,
                "the usable latency range is derived from the wizard's reference")

        // Convergence: the questions end, the tick stops — and the reference
        // does not move, so the receipt plays on the timeline it was judged on.
        backend.setBTWizardTickActive(false, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        #expect(backend.localSinkReferenceDelayMs() == 2_000,
                "the receipt runs on the raised reference")
        #expect(sink.buffers.last == 2_000)

        backend.endBTWizardRun()
        waitFor { sink.buffers.last == BTSyncedSink.defaultBTOnlyBufferMs }
        #expect(sink.buffers.last == 500, "the run ending is what puts it back")

        // A Mac-target run leaves the reference alone. `localSinkReferenceDelayMs`
        // reads on the same serial queue the raise is dispatched to, so this is
        // ordered after it without waiting on anything.
        backend.setBTWizardTickActive(true, btTargetDeviceID: nil, btReferenceDeviceID: nil)
        #expect(backend.localSinkReferenceDelayMs() == 500)
        backend.setBTWizardTickActive(false, btTargetDeviceID: nil, btReferenceDeviceID: nil)
    }

    /// Keep writes the measurement BEFORE the reference comes down, so the new
    /// floor is computed with it already in the table. The other order pushed a
    /// 640 ms latency against a 500 ms reference and the delay sat on its ≥ 0
    /// clamp until the two agreed again.
    @Test func keepLandsTheMeasurementBeforeTheReferenceDrops() throws {
        let dir = scratchDir
        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.buffers.isEmpty }   // applyBTSinkTransition has begun: it pushes the buffer
                                    // right after creating the sink and setting composition.
                                    // NOT a claim that the sink is fully engaged — gains, EQ,
                                    // setDevices and start() all follow. The old
                                    // `!sink.trims.isEmpty` barrier could never fire here: that
                                    // loop only runs for PERSISTED trims, and this test stores none.

        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        waitFor { sink.buffers.last == 2_000 }
        backend.setBTWizardTickActive(false, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        backend.endBTWizardLatencyPreview(forDevice: btMove.id, keepMs: 640)
        waitFor { backend.btMeasuredLatencyMs(forDevice: self.btMove.id) == 640 }
        backend.endBTWizardRun()

        waitFor { sink.buffers.last == 740 }
        #expect(sink.buffers.last == 740, "640 ms measured + 100 ms headroom")
        #expect(Array(sink.buffers.drop { $0 != 2_000 }) == [2_000, 740],
                "one move down, straight onto the new floor — a dip to the bare 500 is the clamp window; got \(sink.buffers)")
    }

    /// A redundant tick edge does NOTHING. Both edges re-anchor every FIFO sink,
    /// and the panel's Done button fires a second `false` after a terminal
    /// screen already stopped the tick — a whole composition re-anchor bought
    /// with a click that means "close this panel".
    @Test func aRedundantTickEdgeReanchorsNothing() {
        let (backend, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.buffers.isEmpty }   // applyBTSinkTransition has begun: it pushes the buffer
                                    // right after creating the sink and setting composition.
                                    // NOT a claim that the sink is fully engaged — gains, EQ,
                                    // setDevices and start() all follow. The old
                                    // `!sink.trims.isEmpty` barrier could never fire here: that
                                    // loop only runs for PERSISTED trims, and this test stores none.
        let baseline = sink.reanchors.count

        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        waitFor { sink.reanchors.count == baseline + 1 }
        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        backend.setBTWizardTickActive(false, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        waitFor { sink.reanchors.count == baseline + 2 }

        // The Done click.
        backend.setBTWizardTickActive(false, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        waitFor(timeout: 0.2) { sink.reanchors.count > baseline + 2 }
        #expect(sink.reanchors.count == baseline + 2,
                "one edge on, one edge off — got \(sink.reanchors)")
        #expect(backend.localSinkReferenceDelayMs() == 2_000,
                "…and the redundant edge left the reference alone too")
    }

    // MARK: - The wizard's first-tick ARM gate (roadmap 056 Part B)

    /// The run opens on the keep-alive bed and the ticks arm only once every
    /// participating sink is actually playing — the fix for the Mac ticking
    /// alone at the start while a Bluetooth engine was still coming up.
    @Test func theTicksArmOnlyOnceEverySinkIsPlaying() {
        let capture = LineCapture()
        let (backend, bt, sink, _) = makeBackend()
        defer { backend.stop(); Telemetry._installTestSink(nil) }
        backend.wizardArmPollInterval = 0.01
        backend.wizardArmMinimumBedSeconds = 0
        backend.wizardArmCeilingSeconds = 60      // far out of reach: only a
                                                  // real release can arm here
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.buffers.isEmpty }   // applyBTSinkTransition has begun: it pushes the buffer
                                    // right after creating the sink and setting composition.
                                    // NOT a claim that the sink is fully engaged — gains, EQ,
                                    // setDevices and start() all follow. The old
                                    // `!sink.trims.isEmpty` barrier could never fire here: that
                                    // loop only runs for PERSISTED trims, and this test stores none.

        Telemetry._installTestSink { capture.append($0) }
        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        // Nothing is rendering yet, so the gate keeps polling.
        waitFor(timeout: 0.3) { !capture.armedLines().isEmpty }
        #expect(capture.armedLines().isEmpty, "no tick while a participant is silent")

        sink.rendering = [btMove.id]
        waitFor { !capture.armedLines().isEmpty }
        let line = capture.armedLines().first
        #expect(line != nil, "the ticks arm once everyone is playing")
        #expect(line?.contains("\"released\":\"\(btMove.id)\"") == true,
                "…and the line names who released: \(line ?? "none")")
        #expect(line?.contains("\"waitedMs\"") == true)
        #expect(line?.contains("\"timedOut\":\"0\"") == true, "released, not timed out")

        backend.setBTWizardTickActive(false, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
    }

    /// A speaker that never reports rendering must not stall the run: the
    /// ceiling arms it anyway, and says so.
    @Test func theArmGateHasACeiling() {
        let capture = LineCapture()
        let (backend, bt, sink, _) = makeBackend()
        defer { backend.stop(); Telemetry._installTestSink(nil) }
        backend.wizardArmPollInterval = 0.01
        backend.wizardArmMinimumBedSeconds = 0
        backend.wizardArmCeilingSeconds = 0.05
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.buffers.isEmpty }   // applyBTSinkTransition has begun: it pushes the buffer
                                    // right after creating the sink and setting composition.
                                    // NOT a claim that the sink is fully engaged — gains, EQ,
                                    // setDevices and start() all follow. The old
                                    // `!sink.trims.isEmpty` barrier could never fire here: that
                                    // loop only runs for PERSISTED trims, and this test stores none.

        Telemetry._installTestSink { capture.append($0) }
        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        waitFor { !capture.armedLines().isEmpty }
        #expect(capture.armedLines().first?.contains("\"timedOut\":\"1\"") == true,
                "the ceiling arms regardless, and the line records that it did")

        backend.setBTWizardTickActive(false, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
    }

    /// Collects telemetry lines for the arm-gate tests.
    private final class LineCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        func armedLines() -> [String] { lines(evt: "wizard_ticks_armed") }
        func lines(evt: String) -> [String] {
            lock.withLock { lines.filter { $0.contains("\"evt\":\"\(evt)\"") } }
        }
    }

    // MARK: - The run is a TWO-speaker comparison (roadmap 056 live fix)

    /// THE DEFECT. The wizard pacer's bedded block fans into every BT delay
    /// line, so a third selected speaker went on ticking at its own trim — 400
    /// ms behind the fused Mac + target pair, which made it the conspicuous
    /// "second tone" and got judged for the whole run.
    @Test func aBluetoothRunHoldsEveryNonParticipantSilentAndGivesThemBack() {
        let (backend, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btMove.id) != nil
            && self.device(backend, self.btFlip.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id)
        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { sink.gains.count >= 2 }
        waitFor { sink.lastGain(for: self.btMove.id) == 1
            && sink.lastGain(for: self.btFlip.id) == 1 }

        // The Mac is the reference, so every OTHER Bluetooth speaker goes quiet.
        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id,
                                      btReferenceDeviceID: "mac")
        waitFor { sink.lastGain(for: self.btFlip.id) == 0 }
        #expect(sink.lastGain(for: btFlip.id) == 0, "the decoy is silent for the run")
        #expect(sink.lastGain(for: btMove.id) == 1, "the target keeps playing")

        backend.setBTWizardTickActive(false, btTargetDeviceID: btMove.id,
                                      btReferenceDeviceID: "mac")
        waitFor { sink.lastGain(for: self.btFlip.id) == 1 }
        #expect(sink.lastGain(for: btFlip.id) == 1,
                "…and comes back at its own volume, not a hardcoded 1 — got \(sink.gains)")
    }

    /// The one exemption: a reference that is ITSELF a Bluetooth speaker is
    /// half the comparison and has to stay audible.
    @Test func aBluetoothReferenceStaysAudibleWhileTheRestAreHeld() {
        let btThird = BTDeviceSnapshot(id: "11-22-33-44-55-66:output", name: "Era 100",
                                       isConnected: true)
        let (backend, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip, btThird])
        waitFor { self.device(backend, btThird.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id, btThird.id)
        backend.setOutputSet([btMove.id, btFlip.id, btThird.id])
        waitFor { sink.gains.count >= 3 }
        waitFor { sink.lastGain(for: btThird.id) == 1 }

        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id,
                                      btReferenceDeviceID: btFlip.id)
        waitFor { sink.lastGain(for: btThird.id) == 0 }
        #expect(sink.lastGain(for: btFlip.id) == 1,
                "a Bluetooth REFERENCE is half the comparison — holding it kills the run")
        #expect(sink.lastGain(for: btMove.id) == 1)
        #expect(sink.lastGain(for: btThird.id) == 0, "everyone else is held")

        backend.endBTWizardRun()
        waitFor { sink.lastGain(for: btThird.id) == 1 }
        #expect(sink.lastGain(for: btThird.id) == 1, "the run ending releases the hold too")
    }

    // MARK: - Range ceiling + per-trial telemetry (roadmap 056 live fix)

    /// The ceiling used to BE the reference, which is a delay of 0: the ring
    /// gets seeked completely dry and the speaker is silent for the rest of the
    /// session with no way back. It now stops a whole BT-only buffer short.
    @Test func theWizardLatencyCeilingLeavesABufferOfContentAhead() {
        let (backend, bt, sink, _) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.buffers.isEmpty }   // applyBTSinkTransition has begun: it pushes the buffer
                                    // right after creating the sink and setting composition.
                                    // NOT a claim that the sink is fully engaged — gains, EQ,
                                    // setDevices and start() all follow. The old
                                    // `!sink.trims.isEmpty` barrier could never fire here: that
                                    // loop only runs for PERSISTED trims, and this test stores none.

        backend.setBTWizardTickActive(true, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        waitFor { sink.buffers.last == NativeBackend.btWizardReferenceBufferMs }
        let reference = Double(NativeBackend.btWizardReferenceBufferMs)
        let range = backend.btWizardLatencyRangeMs(forDevice: btMove.id)
        #expect(reference - range.upperBound >= Double(BTSyncedSink.defaultBTOnlyBufferMs),
                "a candidate at the ceiling still leaves ≥ 500 ms buffered, got \(range)")
        #expect(range.upperBound >= 1_500, "…and the reachable latency span stays ~1.5 s")
        #expect(range.lowerBound == -BTSyncTrim.rangeMs,
                "…and the run can reverse BELOW the base instead of dead-ending")

        backend.setBTWizardTickActive(false, btTargetDeviceID: btMove.id, btReferenceDeviceID: nil)
        backend.endBTWizardRun()
    }

    /// A trial used to leave no trace at all: the one thing a run does twenty
    /// times had no line saying what the user was asked to judge.
    @Test func everyTrialEmitsItsCandidateAndTheStepThatReachedIt() {
        let capture = LineCapture()
        let (backend, bt, sink, _) = makeBackend()
        defer { backend.stop(); Telemetry._installTestSink(nil) }
        backend.start()
        bt.fire([btMove])
        waitFor { self.device(backend, self.btMove.id) != nil }
        backend.setOutputSet([btMove.id])
        waitFor { !sink.buffers.isEmpty }   // applyBTSinkTransition has begun: it pushes the buffer
                                    // right after creating the sink and setting composition.
                                    // NOT a claim that the sink is fully engaged — gains, EQ,
                                    // setDevices and start() all follow. The old
                                    // `!sink.trims.isEmpty` barrier could never fire here: that
                                    // loop only runs for PERSISTED trims, and this test stores none.

        Telemetry._installTestSink { capture.append($0) }
        backend.setBTWizardTickTempo(bpm: BTAlignmentWizardSession.searchTickBPM)
        backend.setBTWizardLatencyPreview(0, forDevice: btMove.id, halfWidthMs: 475)
        backend.setBTWizardLatencyPreview(-96, forDevice: btMove.id, halfWidthMs: 210.4)
        backend.setBTWizardTickTempo(bpm: BTAlignmentWizardSession.blocksTickBPM)
        // No half-width: the Mac's own run has no posterior behind it.
        backend.setBTWizardLatencyPreview(120, forDevice: btMove.id)

        waitFor { capture.lines(evt: "wizard_latency_preview").count == 3 }
        let lines = capture.lines(evt: "wizard_latency_preview")
        #expect(lines.count == 3, "one line per trial, got \(lines)")
        #expect(lines[0].contains("\"candidateMs\":\"0\""), "\(lines[0])")
        #expect(lines[0].contains("\"deltaMs\":\"0\""), "the first trial steps from itself")
        #expect(lines[0].contains("\"stage\":\"search\""), "\(lines[0])")
        #expect(lines[1].contains("\"candidateMs\":\"-96\""), "\(lines[1])")
        #expect(lines[1].contains("\"deltaMs\":\"-96\""), "\(lines[1])")
        #expect(lines[2].contains("\"candidateMs\":\"120\""), "\(lines[2])")
        #expect(lines[2].contains("\"deltaMs\":\"216\""), "\(lines[2])")
        #expect(lines[2].contains("\"stage\":\"blocks\""), "the tempo names the stage")
        #expect(lines[0].contains("\"halfWidthMs\":\"475.0\""), "\(lines[0])")
        #expect(lines[1].contains("\"halfWidthMs\":\"210.4\""), "\(lines[1])")
        #expect(!lines[2].contains("halfWidthMs"),
                "the key is ABSENT rather than zero when the caller has none: \(lines[2])")
        #expect(lines.allSatisfy { $0.contains("\"uid\":\"\(btMove.id)\"") })

        // A candidate BELOW zero really does reach the sink — the floor lives at
        // Keep, not on the preview path.
        #expect(sink.offsets.contains { $0.uid == self.btMove.id && $0.ms == -96 },
                "got \(sink.offsets)")
    }

    /// A customer's 1.2.0 session (two Sonos Moves) replayed: deselecting and
    /// reselecting a speaker keeps both stored halves, and the reselected sink
    /// is handed reference − latency + trim. That trim was −205, reached by 76
    /// persisted steps the live sink refused, so the reselect anchored at 0 —
    /// the formula doing its job on a trim nobody heard.
    @Test @MainActor func aReselectedSpeakerKeepsItsStoredAlignment() async throws {
        let dir = scratchDir
        let sonos = BTDeviceSnapshot(id: "54-2A-1B-79-08-9E:output", name: "Sonos Move", isConnected: true)
        let move2 = BTDeviceSnapshot(id: "C4-38-75-0E-BF-4A:output", name: "Move 2", isConnected: true)
        let store = BTTrimStore(directory: dir)
        try store.saveLatencies([sonos.id: 295, move2.id: 483])
        try store.save([sonos.id: 80, move2.id: 0])
        try store.saveSpeakerIndex([move2.id: 1, sonos.id: 2])

        let (backend, bt, sink, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([move2, sonos])
        await SuiteWait.until { self.device(backend, sonos.id) != nil && self.device(backend, move2.id) != nil }
        backend.setOutputSet([move2.id, sonos.id])
        await SuiteWait.until { sink.offsets.contains { $0.uid == sonos.id } }
        backend.setOutputSet([sonos.id])                                 // 19:59:41
        backend.setBTSyncTrim(-205, forDevice: sonos.id, persist: true)  // 21:36:52
        backend.setOutputSet([])                                         // 21:46:57
        SuiteWait.settle(0.3)
        let pushesBefore = sink.offsets.count
        backend.setOutputSet([sonos.id])                                 // 21:54:24
        await SuiteWait.until { sink.offsets.count > pushesBefore }
        SuiteWait.settle(0.3)

        #expect(try store.loadLatencies()?[sonos.id] == 295, "deselect/reselect kept the latency")
        #expect(try store.load()?[sonos.id] == -205, "deselect/reselect kept the trim")
        let offset = try #require(sink.offsets.last { $0.uid == sonos.id }?.ms)
        let trim = try #require(sink.trims.last { $0.uid == sonos.id }?.ms)
        let buffer = try #require(sink.buffers.last)
        #expect((offset, trim, buffer) == (295, -205, 500))
        // 500 − 295 + (−205): the stored trim is honoured, and it lands on 0.
        let delay = BTReferenceTimeline.delayNanos(
            composition: BTGroupComposition(airPlayPresent: false, macLocalPresent: false),
            presentationDelayMs: 0, btOnlyBufferMs: buffer,
            deviceOffsetMs: offset, trimMs: trim)
        #expect(delay == 0)
    }

    /// A Reset on a playing speaker left no line at all (both of its seeks run
    /// backward, and only a clamped forward seek logs), so a customer's emptied
    /// trims file was first blamed on a code path that never ran.
    @Test @MainActor func aResetLeavesALineNamingWhoAskedAndWhatItDeleted() async throws {
        let dir = scratchDir
        let store = BTTrimStore(directory: dir)
        try store.saveLatencies([btMove.id: 295, btFlip.id: 483])
        try store.save([btMove.id: -205, btFlip.id: 0])
        let (backend, _, _, _) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        let capture = LineCapture()
        Telemetry._installTestSink { capture.append($0) }
        defer { Telemetry._installTestSink(nil) }

        backend.resetBTAlignment(forDevice: btMove.id)
        backend.clearCompanionAlignmentTuning(targetID: btFlip.id)

        await SuiteWait.until { capture.lines(evt: "bt_alignment_reset").count == 2 }
        let lines = capture.lines(evt: "bt_alignment_reset")
        #expect(lines.count == 2, "got \(lines)")
        let drawer = try #require(lines.first { $0.contains(btMove.id) })
        #expect(drawer.contains("\"source\":\"drawer\""), "\(drawer)")
        #expect(drawer.contains("\"latencyMs\":\"295\""), "\(drawer)")
        #expect(drawer.contains("\"trimMs\":\"-205\""), "\(drawer)")
        let phone = try #require(lines.first { $0.contains(btFlip.id) })
        #expect(phone.contains("\"source\":\"phone\""), "\(phone)")
    }
}

} // extension SerializedSharedState
