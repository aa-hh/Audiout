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
        func setGain(_ gain: Float, forDeviceUID uid: String) {
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

    private func makeBackend(
        storeDirectory: URL? = nil
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
        #expect(keepLine?.contains("\"settleRemainingS\":\"nil\"") == true,
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

    /// The Mac's own alignment paths go through the freshness store like the
    /// phone's do: Keep, Reset and a persisted trim each move the row, a
    /// reconnect stales a Keep made before it, and a Keep made while the clock
    /// is still settling is marked early without any extra code at the site.
    @Test func theMacsOwnAlignmentPathsMoveTheRowsFreshness() throws {
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
        func report() -> BTAlignmentReport? { backend.btAlignmentReport(forDevice: uid) }
        /// Eleven advancing samples a second apart: ten stable seconds, and
        /// the store's one publish on arriving there.
        func settleTheClock() {
            let from = Date()
            for s in 0...10 {
                backend.btAlignmentFreshness.noteClockOutcome(
                    uid: uid, outcome: .advanced, at: from.addingTimeInterval(Double(s)))
            }
        }

        settleTheClock()
        let base = changes.value
        backend.endBTWizardLatencyPreview(forDevice: uid, keepMs: 280)
        #expect(report()?.status == .tuned, "a Keep while stable is an ordinary alignment")
        #expect(changes.value == base + 1)

        // The link drops and comes back. Nobody in this process asked, so
        // only the enumerator's availability edge can report it.
        bt.fire([BTDeviceSnapshot(id: uid, name: btMove.name, isConnected: false)])
        waitFor { self.device(backend, uid)?.isAvailable == false }
        bt.fire([btMove])
        waitFor { report()?.status == .stale }
        #expect(report()?.staleReason == BTAlignmentFreshness.staleReasonReconnected)
        #expect(report()?.clockState == .unknown, "a new link, and no verdict on its clock yet")
        #expect(report()?.settleRemainingSeconds == nil)
        #expect(changes.value == base + 2)

        backend.endBTWizardLatencyPreview(forDevice: uid, keepMs: 300)
        #expect(report()?.status == .stale, "a Keep before the clock settles again is early")
        #expect(report()?.staleReason == BTAlignmentFreshness.staleReasonMeasuredWhileSettling)
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
}

} // extension SerializedSharedState
