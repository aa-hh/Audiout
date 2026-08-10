import Foundation
import Testing
import AirPlayEngine
@testable import AudiouterCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// W3 — the first-mix alignment intercept, hermetic (`NativeBackendBTSelectionTests`
/// double style): the trigger matrix (never-aligned + first-mix fires; solo BT
/// never; saved trim never; dismissed never; once per launch), the
/// held-silent join (sink gain 0 before audio, 1 on resolve), dismissal
/// finality across backend instances, the give-up watchdog, and the W2 wizard
/// trim preview/restore/persist plumbing.
@Suite final class NativeBackendBTAlignmentInterceptTests: IsolatedSuite {

    // MARK: Doubles (per-suite copies, house style)

    private final class RecordingEngine: EngineControlling, @unchecked Sendable {
        func start() async throws {}
        func stop() async {}
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            descriptor.parsedID ?? OutputID(rawValue: 0)
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
        func start() {}
        func stop() {}
        func setDevices(_ specs: [BTSyncedSink.DeviceSpec]) {}
        func setComposition(_ composition: BTGroupComposition) {}
        func renderingDeviceUIDs() -> Set<String> { [] }
        func setTrimMs(_ ms: Double, forDeviceUID uid: String) {
            lock.withLock { _trims.append((ms, uid)) }
        }
        func setGain(_ gain: Float, forDeviceUID uid: String) {
            lock.withLock { _gains.append((gain, uid)) }
        }
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {}
        var trims: [(ms: Double, uid: String)] { lock.withLock { _trims } }
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

    private func makeBackend(
        storeDirectory: URL? = nil,
        holdTimeout: TimeInterval = 120
    ) -> (NativeBackend, FakeBTEnumerator, SpyBTSink, EventCollector) {
        let bt = FakeBTEnumerator()
        let backend = NativeBackend(
            engineControl: RecordingEngine(),
            discoverySource: FakeDiscovery(),
            btEnumerator: bt,
            btTrimStore: storeDirectory.map { BTTrimStore(directory: $0) },
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            ptpHelperActivator: AlwaysReadyPTPHelperActivator(),
            systemDefaultOutputIsAirPlayClass: { false },
            aggregateControl: NoOpAggregateControl(),
            handoffWatcherFactory: { onBlockedAttempt in
                AirPlayHandoffWatcher(spawn: NoOpLogStream(), onBlockedAttempt: onBlockedAttempt)
            })
        let sink = SpyBTSink()
        backend.btSyncedSinkFactory = { sink }
        backend.btAlignmentHoldTimeout = holdTimeout
        backend.btDeviceIDForUID = { uid in AudioObjectID(1000 + UInt32(abs(uid.hashValue % 1000))) }
        let collector = EventCollector()
        collector.attach(to: backend)
        return (backend, bt, sink, collector)
    }

    private func waitFor(timeout: TimeInterval = 3, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
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

    // MARK: - Trigger matrix

    /// Never-aligned + first mix (two BT devices) → both prompt and both join
    /// held silent (gain 0 lands at the sink).
    @Test func neverAlignedFirstMixFiresAndHoldsSilent() {
        let (backend, bt, sink, events) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btMove.id) != nil && self.device(backend, self.btFlip.id) != nil }

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 && sink.gains.count >= 2 }

        #expect(Set(events.promptedDeviceIDs()) == [btMove.id, btFlip.id])
        #expect(sink.lastGain(for: btMove.id) == 0, "held silent while the card is up")
        #expect(sink.lastGain(for: btFlip.id) == 0)
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
        waitFor(timeout: 0.5) { false }   // settle; nothing should fire
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

    /// "Not now" is FINAL: the dismissal persists, and a FRESH backend over
    /// the same store never re-fires.
    @Test func dismissalIsFinalAcrossBackendInstances() {
        let dir = scratchDir
        do {
            let (backend, bt, sink, events) = makeBackend(storeDirectory: dir)
            backend.start()
            bt.fire([btMove, btFlip])
            waitFor { self.device(backend, self.btFlip.id) != nil }
            setFullVolume(backend, btMove.id, btFlip.id)
            backend.setOutputSet([btMove.id, btFlip.id])
            waitFor { events.promptedDeviceIDs().count == 2 }

            backend.resolveBTAlignmentPrompt(forDevice: btMove.id, dismissed: true)
            backend.resolveBTAlignmentPrompt(forDevice: btFlip.id, dismissed: true)
            waitFor { sink.lastGain(for: self.btMove.id) == 1 && sink.lastGain(for: self.btFlip.id) == 1 }
            #expect(sink.lastGain(for: btMove.id) == 1, "resolving releases the hold")
            backend.stop()
        }

        let (backend, bt, sink, events) = makeBackend(storeDirectory: dir)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id)
        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { !sink.gains.isEmpty }

        #expect(events.promptedDeviceIDs().isEmpty, "dismissed devices are never auto-prompted again")
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
        waitFor(timeout: 0.5) { false }   // settle

        #expect(events.promptedDeviceIDs().count == 2, "no re-prompt on re-forming the mix")
    }

    /// Deselecting a held device releases its hold (gain back to 1) so the
    /// next select — never re-intercepted — plays audibly.
    @Test func deselectReleasesTheHold() {
        let (backend, bt, sink, events) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id)

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 }
        backend.setOutputSet([btFlip.id])
        waitFor { sink.lastGain(for: self.btMove.id) == 1 }
        #expect(sink.lastGain(for: btMove.id) == 1)
    }

    /// The give-up watchdog: an unanswered hold un-mutes on its own — a
    /// silent speaker with no visible cause must be impossible.
    @Test func watchdogReleasesAnUnansweredHold() {
        let (backend, bt, sink, events) = makeBackend(holdTimeout: 0.2)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id)

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 }
        waitFor { sink.lastGain(for: self.btMove.id) == 1 && sink.lastGain(for: self.btFlip.id) == 1 }
        #expect(sink.lastGain(for: btMove.id) == 1)
        #expect(sink.lastGain(for: btFlip.id) == 1)
    }

    // MARK: - Hold × user volume (one composed product)

    /// A slider write DURING the hold cannot un-mute: the composed gain is 0
    /// for a held uid regardless of the level — and the resolve then pushes
    /// the level the user chose mid-hold, never a hardcoded 1.
    @Test func volumeDuringHoldStaysSilentAndResolvePushesComposed() {
        let (backend, bt, sink, events) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 }
        waitFor { sink.lastGain(for: self.btMove.id) == 0 }

        backend.setVolume(40, for: btMove.id)
        waitFor { self.device(backend, self.btMove.id)?.volume == 40 }
        #expect(sink.lastGain(for: btMove.id) == 0, "held stays silent through a slider write")

        backend.resolveBTAlignmentPrompt(forDevice: btMove.id, dismissed: false)
        waitFor { sink.lastGain(for: self.btMove.id).map { abs($0 - 0.4) < 0.001 } == true }
        #expect(sink.lastGain(for: btMove.id).map { abs($0 - 0.4) < 0.001 } == true,
                "the release pushes the composed user gain, not 1")
    }

    /// The watchdog release is composed too — giving up on the card must not
    /// blow away the user's level.
    @Test func watchdogReleasePushesComposedNotUnity() {
        let (backend, bt, sink, events) = makeBackend(holdTimeout: 0.2)
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }
        backend.setVolume(40, for: btMove.id)
        setFullVolume(backend, btFlip.id)

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 }
        waitFor { sink.lastGain(for: self.btMove.id).map { abs($0 - 0.4) < 0.001 } == true }
        #expect(sink.lastGain(for: btMove.id).map { abs($0 - 0.4) < 0.001 } == true)
        #expect(sink.lastGain(for: btFlip.id) == 1)
    }

    /// The wizard's entry release, end to end: the popover answers the prompt
    /// with `dismissed: false` before the run starts, and the target must come
    /// out of the hold AUDIBLE. A guided run against a gain-0 sink asks the
    /// user which speaker ticked first while one of them is muted.
    @Test func theWizardsReleaseLeavesTheTargetAudible() {
        let (backend, bt, sink, events) = makeBackend()
        defer { backend.stop() }
        backend.start()
        bt.fire([btMove, btFlip])
        waitFor { self.device(backend, self.btFlip.id) != nil }
        setFullVolume(backend, btMove.id, btFlip.id)

        backend.setOutputSet([btMove.id, btFlip.id])
        waitFor { events.promptedDeviceIDs().count == 2 }
        waitFor { sink.lastGain(for: self.btMove.id) == 0 }

        // What `PopoverController.startBTAlignmentWizard` sends on every door
        // into the wizard.
        backend.resolveBTAlignmentPrompt(forDevice: btMove.id, dismissed: false)
        waitFor { sink.lastGain(for: self.btMove.id) == 1 }
        #expect(sink.lastGain(for: btMove.id) == 1, "the wizard's target ticks audibly")
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
}
