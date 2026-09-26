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

    private func makeBackend() -> (NativeBackend, FakeWiredEnumerator) {
        let wired = FakeWiredEnumerator()
        let backend = NativeBackend(
            engineControl: NoOpEngine(),
            discoverySource: NoOpDiscovery(),
            wiredEnumerator: wired,
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
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
}
