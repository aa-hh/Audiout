import Foundation
import Testing
import AirPlayEngine
@testable import AudioutCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// Wired outputs in `NativeBackend`: ``WiredOutputEnumerator`` snapshots fold
/// into the same `known`/`order`/`emit` flow Bluetooth rows use. Hermetic: an
/// injected ``WiredOutputEnumerating`` fake stands in for the HAL, and every
/// other collaborator is the no-op double `NativeBackendBTDevicesTests` keeps.
@Suite final class NativeBackendWiredDevicesTests: IsolatedSuite {

    // MARK: Doubles

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

    /// Minimal no-op `EngineControlling` — wired ids are never fed to the engine,
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

    /// A scripted `AudioProcessEnumerating` fake: hands back a fixed process
    /// list so an `AudioProcessResolver` built on it resolves deterministically,
    /// with no live Core Audio. Copied from `NativeBackendBTSelectionTests`.
    private struct FakeProcessEnumerator: AudioProcessEnumerating {
        let processes: [RawAudioProcess]
        var parents: [pid_t: pid_t] = [:]
        func enumerateProcesses() -> [RawAudioProcess] { processes }
        func parentPID(of pid: pid_t) -> pid_t? { parents[pid] }
    }

    /// A `ProcessAudioTap` that always succeeds: `createAndStart` never throws,
    /// so a coordinator built over it takes every bundle ID all the way to
    /// `.capturing` and keeps it there. Copied from `NativeBackendBTSelectionTests`.
    private final class AlwaysSucceedsTap: ProcessAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        func createAndStart(processes: Set<AudioProcess>, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
            TapFormat(sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        }
        func teardown() {}
    }

    /// Records the gate's capture ops in order, plus every route table +
    /// denylist handed to `updateRouting`, with no Core Audio tap / TCC prompt.
    /// Copied from `NativeBackendTests.swift`'s `FakeCapture`.
    private final class FakeCapture: CaptureControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _onLevel: (@Sendable (Float) -> Void)?
        private var _onStateChange: (@Sendable (NativeCaptureCoordinator.State) -> Void)?
        private var _onDeviceRateRebuild: (@Sendable () -> Void)?
        private var _ops: [String] = []
        private var _meteringActive = false

        var onLevel: (@Sendable (_ rms: Float) -> Void)? {
            get { lock.withLock { _onLevel } }
            set { lock.withLock { _onLevel = newValue } }
        }
        var onStateChange: (@Sendable (NativeCaptureCoordinator.State) -> Void)? {
            get { lock.withLock { _onStateChange } }
            set { lock.withLock { _onStateChange = newValue } }
        }
        var onDeviceRateRebuild: (@Sendable () -> Void)? {
            get { lock.withLock { _onDeviceRateRebuild } }
            set { lock.withLock { _onDeviceRateRebuild = newValue } }
        }
        func start() { lock.withLock { _ops.append("start") } }
        func stop() { lock.withLock { _ops.append("stop") } }
        func setEQPlan(_ plan: WholeSystemEQPlan) {}
        func setMeteringActive(_ active: Bool) { lock.withLock { _meteringActive = active } }
        func refreshExcludedProcessSet(forRelaunchedBundleID bundleID: String) {}

        /// R5: records the route table + denylist handed to `updateRouting`, in
        /// order, so a test can assert exactly WHICH bundle IDs the whole-system
        /// tap was told to exclude.
        private var _routingUpdates: [(appRoutes: [AppRoute], excludedBundleIDs: Set<String>)] = []
        func updateRouting(appRoutes: [AppRoute], excludedBundleIDs: Set<String>) {
            lock.withLock { _routingUpdates.append((appRoutes, excludedBundleIDs)) }
        }
        var routingUpdates: [(appRoutes: [AppRoute], excludedBundleIDs: Set<String>)] {
            lock.withLock { _routingUpdates }
        }
        /// The bundle IDs the LAST `updateRouting` call would have the
        /// whole-system tap exclude: every `.device`-routed bundle ID unioned
        /// with the denylist.
        var lastExcludedBundleIDs: Set<String>? {
            guard let last = routingUpdates.last else { return nil }
            let routedAway = last.appRoutes
                .filter(\.destination.isDeviceRoute)
                .map(\.bundleID)
            return last.excludedBundleIDs.union(routedAway)
        }
        func setAirPlayPreDelay(ms: Int) {}
        var ops: [String] { lock.withLock { _ops } }
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
        var events: [BackendEvent] { lock.withLock { _events } }
        deinit { task?.cancel() }
    }

    // MARK: Helpers

    /// Builds an `AudioProcessResolver` where each bundle id resolves to
    /// exactly ONE process object, at `pid = objectID`. Copied from
    /// `NativeBackendBTSelectionTests`.
    private func singleProcessResolver(_ bundleIDsToObjectIDs: [String: AudioObjectID]) -> AudioProcessResolver {
        let processes = bundleIDsToObjectIDs.map { bundleID, objectID in
            RawAudioProcess(objectID: objectID, pid: pid_t(objectID), bundleID: bundleID)
        }
        return AudioProcessResolver(enumerator: FakeProcessEnumerator(processes: processes))
    }

    /// A `PerAppCaptureCoordinator` whose every `start(bundleID:)` reaches
    /// `.capturing` and stays there. Copied from `NativeBackendBTSelectionTests`.
    private func workingPerAppCapture(bundleIDs: [String]) -> PerAppCaptureCoordinator {
        var mapping: [String: AudioObjectID] = [:]
        for (offset, bundleID) in bundleIDs.enumerated() {
            mapping[bundleID] = AudioObjectID(9000 + offset)
        }
        return PerAppCaptureCoordinator(
            makeTap: { AlwaysSucceedsTap() }, processResolver: singleProcessResolver(mapping), muteBehavior: .mutedWhenTapped)
    }

    /// A `.device(id:)` route fixture. Copied from `NativeBackendBTSelectionTests`.
    private func route(_ bundleID: String, name: String, toDevice deviceID: String, volume: Int = 100) -> AppRoute {
        AppRoute(bundleID: bundleID, displayName: name, destination: .device(id: deviceID), volume: volume)
    }

    private func makeBackend(
        injectedPerAppCapture: PerAppCaptureCoordinator? = nil
    ) -> (NativeBackend, FakeWiredEnumerator) {
        let wired = FakeWiredEnumerator()
        let backend = NativeBackend(
            engineControl: NoOpEngine(),
            discoverySource: NoOpDiscovery(),
            wiredEnumerator: wired,
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            injectedPerAppCapture: injectedPerAppCapture,
            aggregateControl: NoOpAggregateControl())
        return (backend, wired)
    }

    private func waitFor(timeout: TimeInterval? = nil,
                         sourceLocation: SourceLocation = #_sourceLocation,
                         _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    private func device(_ backend: NativeBackend, _ id: String) -> Device? {
        backend.devices.first { $0.id == id }
    }

    private let dac = WiredOutputSnapshot(id: "AppleUSBAudioEngine:DAC:1", name: "USB DAC", transport: .usb)
    private let jack = WiredOutputSnapshot(id: "BuiltInHeadphoneOutputDevice", name: "Headphones",
                                           transport: .headphoneJack)

    // MARK: Tests

    /// Defect: a wired row keyed by anything but the Core Audio UID (an
    /// `AudioObjectID` is reused across hotplugs) or fed as AirPlay.
    @Test func snapshotBecomesAWiredRowKeyedByUID() {
        let (backend, wired) = makeBackend()
        defer { backend.stop() }
        backend.start()

        wired.fire([dac])
        waitFor { self.device(backend, self.dac.id) != nil }

        let row = device(backend, dac.id)
        #expect(row?.id == dac.id)
        #expect(row?.kind == .wired)
        #expect(row?.supportsAirPlay2 == false)
        #expect(row?.isLocalDevice == false)
        #expect(row?.isAvailable == true)
        #expect(row?.wiredTransport == dac.transport)
    }

    /// Defect: an UNUSED unplugged output leaving a ghost row. Not selected,
    /// not app-routed, not a saved-group member — the row goes unavailable
    /// first (the edge the popover deselects on), then leaves.
    @Test func unpluggedOutputLeavesTheList() {
        let (backend, wired) = makeBackend()
        defer { backend.stop() }
        let collector = EventCollector()
        collector.attach(to: backend)
        backend.start()

        wired.fire([dac, jack])
        waitFor { self.device(backend, self.dac.id) != nil && self.device(backend, self.jack.id) != nil }

        wired.fire([dac])
        waitFor { self.device(backend, self.jack.id) == nil }
        let jackID = jack.id
        waitFor {
            collector.events.contains { if case .deviceRemoved(jackID) = $0 { return true }; return false }
        }

        let events = collector.events
        let unavailable = events.firstIndex {
            if case .deviceUpdated(let d) = $0 { return d.id == jackID && !d.isAvailable }
            return false
        }
        let removed = events.firstIndex { if case .deviceRemoved(jackID) = $0 { return true }; return false }
        #expect(unavailable != nil, "the unplug must first commit the row unavailable")
        #expect(removed != nil)
        if let unavailable, let removed { #expect(unavailable < removed) }
    }

    /// Defect: an unplugged SELECTED headphone row vanishing and taking its
    /// selection with it. A used row stays greyed instead of being removed.
    @Test func usedUnpluggedRowStaysGreyedUntilReleased() {
        let (backend, wired) = makeBackend()
        defer { backend.stop() }
        let collector = EventCollector()
        collector.attach(to: backend)
        backend.start()

        wired.fire([dac, jack])
        waitFor { self.device(backend, self.dac.id) != nil && self.device(backend, self.jack.id) != nil }

        backend.setOutputSet([jack.id])

        wired.fire([dac])
        waitFor {
            let row = self.device(backend, self.jack.id)
            return row?.isAvailable == false && row?.connectionState == .off
        }
        SuiteWait.settle(0.3)
        let jackID = jack.id
        #expect(!collector.events.contains { if case .deviceRemoved(jackID) = $0 { return true }; return false },
                "a used (selected) row must not be removed on unplug")

        backend.setOutputSet([])
        waitFor {
            collector.events.contains { if case .deviceRemoved(jackID) = $0 { return true }; return false }
        }
        #expect(device(backend, jack.id) == nil)
    }

    /// Defect: a saved-group member vanishing on unplug because the backend
    /// only read selection, not group membership, for "used".
    @Test func groupMemberUnpluggedRowStaysUntilGroupReleasesIt() {
        let (backend, wired) = makeBackend()
        defer { backend.stop() }
        let collector = EventCollector()
        collector.attach(to: backend)
        backend.start()

        wired.fire([dac, jack])
        waitFor { self.device(backend, self.dac.id) != nil && self.device(backend, self.jack.id) != nil }

        backend.updateAppRoutes([], groupTargets: ["g1": GroupRouteTarget(memberVolumes: [jack.id: 100])])

        wired.fire([dac])
        waitFor { self.device(backend, self.jack.id)?.isAvailable == false }
        let jackID = jack.id
        #expect(!collector.events.contains { if case .deviceRemoved(jackID) = $0 { return true }; return false },
                "a saved-group member must not be removed on unplug")

        backend.updateAppRoutes([], groupTargets: [:])
        waitFor {
            collector.events.contains { if case .deviceRemoved(jackID) = $0 { return true }; return false }
        }
    }

    /// Defect: a kept greyed row never coming back after replug — the update
    /// branch used to write only `name`/`wiredTransport`, never `isAvailable`.
    @Test func replugRestoresAvailability() {
        let (backend, wired) = makeBackend()
        defer { backend.stop() }
        let collector = EventCollector()
        collector.attach(to: backend)
        backend.start()

        wired.fire([dac, jack])
        waitFor { self.device(backend, self.dac.id) != nil && self.device(backend, self.jack.id) != nil }

        backend.setOutputSet([jack.id])
        wired.fire([dac])
        waitFor { self.device(backend, self.jack.id)?.isAvailable == false }

        wired.fire([dac, jack])
        waitFor { self.device(backend, self.jack.id)?.isAvailable == true }

        let jackID = jack.id
        let events = collector.events
        #expect(!events.contains { if case .deviceRemoved(jackID) = $0 { return true }; return false })
        let addedCount = events.filter {
            if case .deviceAdded(let d) = $0 { return d.id == jackID }
            return false
        }.count
        #expect(addedCount == 1, "the row was updated on replug, not re-added")
    }

    /// Defect: `isRouteTargetReachableLocked` returns false for a wired UID (it
    /// never holds an `outputIDs` entry — that's engine-only), so a route to the
    /// headphones is silently demoted and the app keeps playing in the system
    /// mix instead of being honoured on the wired row.
    @Test func routeToAWiredRowIsHonouredUntilWholeSystemClaimsIt() {
        let capture = workingPerAppCapture(bundleIDs: ["com.foo"])
        let (backend, wired) = makeBackend(injectedPerAppCapture: capture)
        defer { backend.stop() }
        let fakeCapture = FakeCapture()
        backend.captureCoordinator = fakeCapture
        backend.start()

        wired.fire([jack])
        waitFor { self.device(backend, self.jack.id) != nil }

        backend.updateAppRoutes([route("com.foo", name: "Foo", toDevice: jack.id)])
        waitFor { fakeCapture.lastExcludedBundleIDs?.contains("com.foo") == true }
        #expect(fakeCapture.lastExcludedBundleIDs?.contains("com.foo") == true)

        backend.setOutputSet([jack.id])
        waitFor { backend.test_scopeConflict(deviceID: self.jack.id) != nil }
        let conflict = backend.test_scopeConflict(deviceID: jack.id)
        #expect(conflict?.bundleIDs == ["com.foo"])
        waitFor { fakeCapture.lastExcludedBundleIDs?.contains("com.foo") == false }

        backend.setOutputSet([])
        waitFor { fakeCapture.lastExcludedBundleIDs?.contains("com.foo") == true }
    }
}
