import Foundation
import Testing
import AirPlayEngine
@testable import AudiouterCore

/// T-BACKEND: hermetic tests for `NativeBackend`'s "play everywhere" enable/
/// disable decision — Mac + ≥1 AirPlay device selected turns the delayed local
/// sink on; anything else turns it off. No `AVAudioEngine`, no Core Audio tap,
/// no engine/network — a spy `SyncedLocalSinkControlling` stands in for the
/// real `SyncedLocalSink` (constructed via `syncedLocalSinkFactory`), and a
/// plain closure stands in for `GroupController.isSpeakerSelected(_:)` (wired
/// in production via `selectedDevicesQuery`, since `setOutputSet`'s `ids` never
/// carries the local device — `GroupController.applyRouting` always filters it
/// out before calling the backend).
@Suite final class NativeBackendSyncedLocalSelectionTests: IsolatedSuite {

    // MARK: Doubles

    /// A `SyncedLocalSinkControlling` spy: records every call, in order, with no
    /// `AVAudioEngine` or real audio graph in the loop.
    private final class SpySyncedLocalSink: SyncedLocalSinkControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private(set) var enqueueCount = 0

        func start() throws { lock.withLock { _calls.append("start") } }
        func stop() { lock.withLock { _calls.append("stop") } }
        func startObservingLifecycleEvents() { lock.withLock { _calls.append("startObserving") } }
        func stopObservingLifecycleEvents() { lock.withLock { _calls.append("stopObserving") } }
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
            lock.withLock { enqueueCount += 1 }
        }

        var calls: [String] { lock.withLock { _calls } }
    }

    /// A minimal no-op `EngineControlling` — `setOutputSet` with ids that were
    /// never fed through discovery produces no engine calls at all (the loop
    /// only iterates `known`/`order`), so this fake never needs to do anything.
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

    /// Feeds no discovery events — every test here only cares about
    /// `setOutputSet`'s intent-level bookkeeping, never a real device.
    private final class NoOpDiscovery: DiscoverySource, @unchecked Sendable {
        var onEvent: (@Sendable (DiscoveryEvent) -> Void)?
        func start() {}
        func stop() {}
    }

    /// Fakes `SystemVolumeControlling` with no Core Audio HAL reads (same
    /// hermeticity concern `NativeBackendTests.FakeSystemVolume` documents).
    private final class NoOpSystemVolume: SystemVolumeControlling, @unchecked Sendable {
        var onExternalChange: (@Sendable (Int?, Bool?, Bool) -> Void)?
        func currentVolume() -> Int? { nil }
        func currentMuted() -> Bool? { nil }
        func setVolume(_ volume: Int) {}
        func setMuted(_ muted: Bool) {}
        func start() {}
        func stop() {}
    }

    // MARK: Helpers

    private func makeBackend(macSelectedByDefault: Bool = false) -> (NativeBackend, SpySyncedLocalSink, LockedBool) {
        let backend = NativeBackend(
            engineControl: NoOpEngine(),
            discoverySource: NoOpDiscovery(),
            systemVolume: NoOpSystemVolume())
        let sink = SpySyncedLocalSink()
        backend.syncedLocalSinkFactory = { sink }
        let macSelected = LockedBool(macSelectedByDefault)
        backend.selectedDevicesQuery = { id in
            id == NativeBackend.localDeviceID ? macSelected.get() : false
        }
        return (backend, sink, macSelected)
    }

    /// A tiny thread-safe `Bool` box so a test can flip "is the Mac in Selected
    /// Devices" between `setOutputSet` calls, standing in for
    /// `GroupController.selectedDeviceIDs` changing.
    private final class LockedBool: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ v: Bool) { value = v }
        func get() -> Bool { lock.withLock { value } }
        func set(_ v: Bool) { lock.withLock { value = v } }
    }

    private func waitFor(timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    // MARK: Tests

    /// Mac-only → Mac + AirPlay: the sink turns ON — constructed, attached,
    /// started, and its lifecycle observers installed, in that order.
    @Test func macOnlyToMacPlusAirPlayEnablesSyncedLocalSink() {
        let (backend, sink, macSelected) = makeBackend(macSelectedByDefault: true)
        defer { backend.stop() }

        backend.setOutputSet([])   // Mac-only (passthrough): no AirPlay device selected
        waitFor { true }           // let any (there shouldn't be any) async work settle
        #expect(sink.calls.isEmpty, "Mac alone must never enable the synced-local sink")

        backend.setOutputSet(["airplay-1"])   // now Mac + 1 AirPlay device
        waitFor { !sink.calls.isEmpty }

        #expect(sink.calls == ["start", "startObserving"],
                "enabling must start the sink and begin lifecycle observation, in order")
        _ = macSelected   // silence unused-var warning if the compiler flags it
    }

    /// Mac + AirPlay → AirPlay-only (Mac deselected): the sink turns OFF — in
    /// the mirrored order (stop, then stop observing).
    @Test func macPlusAirPlayToAirPlayOnlyDisablesSyncedLocalSink() {
        let (backend, sink, macSelected) = makeBackend(macSelectedByDefault: true)
        defer { backend.stop() }

        backend.setOutputSet(["airplay-1"])   // Mac + AirPlay: enabled
        waitFor { !sink.calls.isEmpty }
        #expect(sink.calls == ["start", "startObserving"])

        macSelected.set(false)                // user deselects the Mac row
        backend.setOutputSet(["airplay-1"])   // same AirPlay membership, Mac dropped
        waitFor { sink.calls.count >= 4 }

        #expect(sink.calls == ["start", "startObserving", "stop", "stopObserving"],
                "disabling must stop the sink and stop lifecycle observation, in order")
    }

    /// Mac + AirPlay → Mac + 2×AirPlay: stays enabled, and — critically — does
    /// NOT re-attach/re-start the sink. A second AirPlay device joining a
    /// selection that's already "Mac + AirPlay" is a no-op for this feature.
    @Test func macPlusAirPlayToMacPlusTwoAirPlayStaysEnabledNoRedundantReattach() {
        let (backend, sink, _) = makeBackend(macSelectedByDefault: true)
        defer { backend.stop() }

        backend.setOutputSet(["airplay-1"])
        waitFor { !sink.calls.isEmpty }
        #expect(sink.calls == ["start", "startObserving"])

        backend.setOutputSet(["airplay-1", "airplay-2"])   // a second AirPlay device joins
        // Give any (incorrect) redundant work a moment to show up.
        waitFor(timeout: 0.3) { false }

        #expect(sink.calls == ["start", "startObserving"],
                "adding a second AirPlay device to an already-enabled selection must not re-attach/re-start the sink")
    }

    /// AirPlay-only (Mac never selected) never enables the sink, regardless of
    /// how many AirPlay devices are selected.
    @Test func airPlayOnlyNeverEnablesSyncedLocalSink() {
        let (backend, sink, _) = makeBackend(macSelectedByDefault: false)
        defer { backend.stop() }

        backend.setOutputSet(["airplay-1"])
        backend.setOutputSet(["airplay-1", "airplay-2"])
        waitFor(timeout: 0.3) { false }

        #expect(sink.calls.isEmpty, "AirPlay selected with the Mac NOT selected must never enable the sink")
    }

    /// Mac + AirPlay → empty selection (both dropped): disables, same as
    /// dropping just the AirPlay side.
    @Test func macPlusAirPlayToEmptySelectionDisablesSyncedLocalSink() {
        let (backend, sink, macSelected) = makeBackend(macSelectedByDefault: true)
        defer { backend.stop() }

        backend.setOutputSet(["airplay-1"])
        waitFor { !sink.calls.isEmpty }

        macSelected.set(false)
        backend.setOutputSet([])
        waitFor { sink.calls.count >= 4 }

        #expect(sink.calls == ["start", "startObserving", "stop", "stopObserving"])
    }

    // MARK: End-to-end over the GroupController → NativeBackend seam
    //
    // The unit tests above stand a closure in for the query. These two wire the
    // REAL `GroupController` to it exactly as `AppDelegate` does
    // (`selectedDevicesQuery = isMainOutMember(_:)`) and drive it from a saved
    // GROUP — the path that was silently dropping the Mac. Still fully hermetic:
    // the routing brain talks to a recording fake, whose output set is forwarded
    // into the backend, and the sink is the same spy. No engine, no audio.

    /// A minimal `OutputBackend` for `GroupController` to route against: it
    /// serves a fixed fleet and forwards each `setOutputSet` onward, which is
    /// exactly the pair of facts the seam under test is made of.
    private final class RecordingBackend: OutputBackend, @unchecked Sendable {
        let devices: [Device]
        var onSetOutputSet: ((Set<String>) -> Void)?
        private(set) var lastOutputSet: Set<String> = []
        private(set) var volumeWrites: [(id: String, volume: Int)] = []

        init(devices: [Device]) { self.devices = devices }

        func start() {}
        func stop() {}
        func makeEventStream() -> AsyncStream<BackendEvent> { AsyncStream { _ in } }
        func setVolume(_ volume: Int, for id: String) { volumeWrites.append((id, volume)) }
        func setMuted(_ muted: Bool, for id: String) {}
        func setOutputSet(_ ids: Set<String>) {
            lastOutputSet = ids
            onSetOutputSet?(ids)
        }
    }

    private func makeRoutingBrain() -> (GroupController, RecordingBackend) {
        let fleet: [Device] = [
            Device(id: NativeBackend.localDeviceID, name: "This Mac", kind: .localMac,
                   supportsAirPlay2: false, volume: 50, isLocalDevice: true),
            Device(id: "airplay-1", name: "Kitchen Speaker", kind: .sonos, volume: 40),
        ]
        let router = RecordingBackend(devices: fleet)
        let controller = GroupController(backend: router,
                                         store: GroupStore(directory: scratchDir),
                                         routingStore: RoutingStore(directory: scratchDir),
                                         loadPersisted: false)
        return (controller, router)
    }

    /// THE BUG: a saved group that mixes the Mac with an AirPlay speaker must
    /// play out of BOTH. The Mac never rides in `setOutputSet`'s ids, so its
    /// membership reaches the backend only through the query — which must read
    /// the ACTIVE GROUP, not the Selected Devices set.
    @Test func groupMixingMacWithAirPlayArmsTheSyncedLocalSink() throws {
        let (controller, router) = makeRoutingBrain()
        let backend = NativeBackend(engineControl: NoOpEngine(),
                                    discoverySource: NoOpDiscovery(),
                                    systemVolume: NoOpSystemVolume())
        defer { backend.stop() }
        let sink = SpySyncedLocalSink()
        backend.syncedLocalSinkFactory = { sink }
        // Exactly `AppDelegate`'s wiring.
        backend.selectedDevicesQuery = { [weak controller] in controller?.isMainOutMember($0) ?? false }
        router.onSetOutputSet = { backend.setOutputSet($0) }

        try controller.saveGroup(Group(id: "g1", name: "Kitchen",
                                       memberIDs: [NativeBackend.localDeviceID, "airplay-1"],
                                       memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        waitFor { !sink.calls.isEmpty }

        #expect(router.lastOutputSet == ["airplay-1"],
                "the Mac is filtered out of the engine output set …")
        #expect(sink.calls == ["start", "startObserving"],
                "… and reaches the backend through the query instead, arming the local sink")
    }

    /// The mirror failure: an AirPlay-ONLY group must NOT arm the sink just
    /// because the Mac is still sitting in the (untargeted) Selected Devices set
    /// — that would play the Mac after the user routed the audio away from it.
    @Test func airPlayOnlyGroupDoesNotArmTheSinkWhileTheMacSitsInSelectedDevices() throws {
        let (controller, router) = makeRoutingBrain()
        let backend = NativeBackend(engineControl: NoOpEngine(),
                                    discoverySource: NoOpDiscovery(),
                                    systemVolume: NoOpSystemVolume())
        defer { backend.stop() }
        let sink = SpySyncedLocalSink()
        backend.syncedLocalSinkFactory = { sink }
        backend.selectedDevicesQuery = { [weak controller] in controller?.isMainOutMember($0) ?? false }
        router.onSetOutputSet = { backend.setOutputSet($0) }

        controller.ensureDefaultSelection()                       // Selected Devices = {the Mac}
        #expect(controller.isSpeakerSelected(NativeBackend.localDeviceID))

        try controller.saveGroup(Group(id: "g1", name: "Patio",
                                       memberIDs: ["airplay-1"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        waitFor(timeout: 0.3) { false }

        #expect(router.lastOutputSet == ["airplay-1"])
        #expect(sink.calls.isEmpty,
                "an AirPlay-only group must not arm the sink off a stale Selected-Devices Mac")
    }

    /// With no factory wired (mirrors the UI-only smoke path / a test that
    /// doesn't care about this feature), a Mac + AirPlay selection is inert —
    /// no crash, nothing to assert against because there's no sink at all.
    @Test func noFactoryWiredIsInert() {
        let backend = NativeBackend(
            engineControl: NoOpEngine(),
            discoverySource: NoOpDiscovery(),
            systemVolume: NoOpSystemVolume())
        backend.selectedDevicesQuery = { $0 == NativeBackend.localDeviceID }
        defer { backend.stop() }

        backend.setOutputSet(["airplay-1"])   // Mac + AirPlay, but no syncedLocalSinkFactory
        waitFor(timeout: 0.2) { false }
        // No crash, nothing to observe — this test passes by not throwing.
    }
}
