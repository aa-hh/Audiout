import Foundation
import Testing
@testable import AudioutCore

/// H-4: guards the property the synced-local settle fix (`NativeBackend.swift`,
/// `scheduleSyncedLocalSettleLocked` / `fireSyncedLocalSettle`) depends on but
/// nothing at this layer proved: ONE `GroupController` user action produces AT
/// MOST ONE synced-local desired-state FLIP.
///
/// Why this matters: `syncedLocalCoalescedCount` increments once per
/// desired-state FLIP (`if wantSyncedLocal != self.syncedLocalSinkEnabled`), not
/// once per `setOutputSet` call. `NativeBackend`'s own tests drive `setOutputSet`
/// directly and hand-pick "is the Mac selected," so they can't see a future
/// regression ABOVE the backend where one ordinary user action fans out into 2+
/// `setOutputSet` calls with different `wantSyncedLocal` answers; that fan-out
/// would silently start paying the RTP re-establish
/// (`resetAirPlaySessionForWholeSystem()`) on every ordinary connect. This suite
/// drives `GroupController` (`setDeviceSelected`: plain select/deselect, the
/// auto-swap path, the current-device floor; and group activation) through a spy
/// backend and asserts the fan-out never happens today.
///
/// `wantSyncedLocal` itself (`NativeBackend.swift`:
/// `let macSelected = self.selectedDevicesQuery?(Self.localDeviceID) ?? false;
/// let wantSyncedLocal = macSelected && !ids.isEmpty`) is reproduced here, not
/// imported. `macSelected` is wired in production
/// (`AudioutCore/Sources/AudioutApp/AppDelegate.swift`) to
/// `groupController.isMainOutMember(localDeviceID)` (the active group's members
/// when a group is active, otherwise Selected Devices), so the spy's
/// `macSelectedProvider` closure below mirrors that exactly.
@Suite final class GroupControllerSyncedLocalFlipTests: IsolatedSuite {

    private static let localID = "local"
    private static let airplayA = "airplay-a"
    private static let airplayB = "airplay-b"
    private static let airplayC = "airplay-c"

    private func fleet() -> [Device] {
        [
            Device(id: Self.localID, name: "This Mac", kind: .localMac, isLocalDevice: true),
            Device(id: Self.airplayA, name: "Airplay A", kind: .generic),
            Device(id: Self.airplayB, name: "Airplay B", kind: .generic),
            Device(id: Self.airplayC, name: "Airplay C", kind: .generic),
        ]
    }

    /// - Returns: a fresh `GroupController` wired to a fresh
    ///   `SyncedLocalFlipRecordingBackend`, with `macSelectedProvider` bound
    ///   back to the controller exactly as `AppDelegate` wires the real thing.
    private func makeController() -> (GroupController, SyncedLocalFlipRecordingBackend) {
        let backend = SyncedLocalFlipRecordingBackend(devices: fleet())
        let controller = GroupController(
            backend: backend,
            store: GroupStore(directory: scratchDir),
            routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: makeDefaults()),
            loadPersisted: false
        )
        backend.macSelectedProvider = { [weak controller] in
            controller?.isMainOutMember(Self.localID) ?? false
        }
        return (controller, backend)
    }

    /// Runs `action`, drains whatever `setOutputSet` calls it produced, and
    /// returns how many times the synced-local desired-state predicate
    /// CHANGED, mirroring `syncedLocalCoalescedCount`'s per-flip increment,
    /// not a raw call count (multiple calls landing on the same answer are
    /// harmless and legitimate; only a CHANGE matters).
    ///
    /// `state` is the test's own persistent mirror of `syncedLocalSinkEnabled`,
    /// carried across calls within one test the same way the real field
    /// persists across `setOutputSet` invocations.
    @discardableResult
    private func flips(_ backend: SyncedLocalFlipRecordingBackend,
                        state: inout Bool,
                        _ action: () -> Void) -> (flips: Int, calls: Int) {
        backend.drainDesiredStates()
        action()
        let desired = backend.drainDesiredStates()
        var flipCount = 0
        for wanted in desired where wanted != state {
            flipCount += 1
            state = wanted
        }
        return (flipCount, desired.count)
    }

    // MARK: Plain select / deselect

    @Test func plainMacSelectProducesAtMostOneFlip() {
        let (controller, backend) = makeController()
        var syncedLocalState = false
        // Seed: an AirPlay device already selected, Mac not yet in the set,
        // so selecting the Mac lands on a non-empty output set and can
        // actually flip `wantSyncedLocal` true.
        _ = controller.setDeviceSelected(Self.airplayA, true)
        _ = flips(backend, state: &syncedLocalState) {}

        let result = flips(backend, state: &syncedLocalState) {
            _ = controller.setDeviceSelected(Self.localID, true)
        }
        #expect(result.calls <= 1, "one user action must issue at most one setOutputSet call")
        #expect(result.flips <= 1, "one user action must flip the synced-local decision at most once")
    }

    @Test func plainMacDeselectProducesAtMostOneFlip() {
        let (controller, backend) = makeController()
        var syncedLocalState = false
        _ = controller.setDeviceSelected(Self.airplayA, true)
        _ = controller.setDeviceSelected(Self.localID, true)
        _ = flips(backend, state: &syncedLocalState) {}

        let result = flips(backend, state: &syncedLocalState) {
            _ = controller.setDeviceSelected(Self.localID, false)
        }
        #expect(result.calls <= 1)
        #expect(result.flips <= 1)
    }

    // MARK: Auto-swap (Mac-only -> AirPlay turned on)

    @Test func autoSwapFromMacOnlyProducesAtMostOneFlip() {
        let (controller, backend) = makeController()
        var syncedLocalState = false
        // Mac-only selected (the auto-swap precondition: selectedDeviceIDs == [local]).
        _ = controller.setDeviceSelected(Self.localID, true)
        _ = flips(backend, state: &syncedLocalState) {}

        let result = flips(backend, state: &syncedLocalState) {
            let outcome = controller.setDeviceSelected(Self.airplayA, true)
            #expect(outcome.autoSwappedCurrentDevice, "precondition: this must exercise the auto-swap path")
        }
        #expect(result.calls <= 1, "the auto-swap composes membership before the single routing call")
        #expect(result.flips <= 1)
    }

    // MARK: Current-device floor (deselecting the last remaining device)

    @Test func currentDeviceFloorProducesAtMostOneFlip() {
        let (controller, backend) = makeController()
        var syncedLocalState = false
        // Only an AirPlay device selected, Mac not in the set.
        _ = controller.setDeviceSelected(Self.airplayA, true)
        _ = flips(backend, state: &syncedLocalState) {}

        let result = flips(backend, state: &syncedLocalState) {
            let outcome = controller.setDeviceSelected(Self.airplayA, false)
            #expect(controller.isSpeakerSelected(Self.localID), "precondition: the floor must have re-inserted the local device")
            #expect(outcome.autoSwappedCurrentDevice)
        }
        #expect(result.calls <= 1, "the floor re-insertion happens before the single routing call")
        #expect(result.flips <= 1)
    }

    // MARK: Group activation changing several members at once

    @Test func groupActivationWithSeveralMembersProducesAtMostOneFlip() throws {
        let (controller, backend) = makeController()
        var syncedLocalState = false
        try controller.saveGroup(Group(id: "trio", name: "Trio",
                                        memberIDs: [Self.localID, Self.airplayA, Self.airplayB, Self.airplayC],
                                        memberVolumes: [:]))
        _ = flips(backend, state: &syncedLocalState) {}

        let result = flips(backend, state: &syncedLocalState) {
            controller.setMainOut(.group(id: "trio"))
        }
        #expect(result.calls <= 1,
                "activating a group must issue exactly one setOutputSet call for all its members combined")
        #expect(result.flips <= 1)
    }

    @Test func switchingBetweenTwoActiveGroupsProducesAtMostOneFlip() throws {
        let (controller, backend) = makeController()
        var syncedLocalState = false
        try controller.saveGroup(Group(id: "g1", name: "One", memberIDs: [Self.airplayA, Self.airplayB], memberVolumes: [:]))
        try controller.saveGroup(Group(id: "g2", name: "Two", memberIDs: [Self.localID, Self.airplayC], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        _ = flips(backend, state: &syncedLocalState) {}

        // Swapping the active group changes several members' membership at
        // once (both drop A/B and gain local+C), still exactly one call.
        let result = flips(backend, state: &syncedLocalState) {
            controller.activateGroup(id: "g2")
        }
        #expect(result.calls <= 1,
                "swapping active groups must coalesce into one setOutputSet call, not one per changed member")
        #expect(result.flips <= 1)
    }

    // NOTE: the review also asked to cover "the multi-device failure cleanup
    // path if you can reach it from this layer." That loop
    // (`PopoverController.handleConnectionTransitions`) lives one layer above
    // `GroupController` and is not reachable from here: every
    // `GroupController` entry point that routes (`setDeviceSelected`,
    // `setMainOut`, `activateGroup`) already calls `backend.setOutputSet`
    // exactly once per invocation (confirmed above), so `GroupController`
    // itself cannot fan a single action into multiple backend calls. The
    // fan-out risk the review is worried about, if it exists, would have to
    // be introduced at the `PopoverController` layer instead (e.g. its
    // per-device failure loop calling `setDeviceSelected` more than once per
    // user gesture). That layer has no equivalent flip-counting coverage
    // today and is a live gap, not something this file can close.
}

// MARK: - Spy backend

/// Records every `setOutputSet` call and, per call, the synced-local
/// desired-state predicate `NativeBackend` derives from it
/// (`wantSyncedLocal = macSelected && !ids.isEmpty`), evaluated AT CALL TIME
/// via `macSelectedProvider`, never cached, exactly like the real backend
/// queries `selectedDevicesQuery` inside its own `setOutputSet`. Everything
/// else is the minimum `OutputBackend` conformance `GroupController` actually
/// exercises: synchronous `devices` snapshot + volume writes, no discovery,
/// no async echo. `GroupController` never awaits anything from the backend
/// for the methods under test here, so `MockBackend`'s staggered discovery /
/// event stream is deliberately not reproduced.
final class SyncedLocalFlipRecordingBackend: OutputBackend, @unchecked Sendable {

    private(set) var devices: [Device]

    /// Answers "is the local device currently a Main Out member", bound by
    /// the test to the controller under test, mirroring
    /// `AppDelegate`'s `selectedDevicesQuery` wiring.
    var macSelectedProvider: () -> Bool = { false }

    private(set) var outputSetCalls: [Set<String>] = []
    private var desiredStates: [Bool] = []

    init(devices: [Device]) {
        self.devices = devices
    }

    /// Returns and clears everything recorded since the last drain.
    @discardableResult
    func drainDesiredStates() -> [Bool] {
        defer { desiredStates.removeAll(); outputSetCalls.removeAll() }
        return desiredStates
    }

    func start() {}
    func stop() {}
    func makeEventStream() -> AsyncStream<BackendEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func setVolume(_ volume: Int, for id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].volume = volume.clampedToVolume
    }

    func setMuted(_ muted: Bool, for id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].isMuted = muted
    }

    func setOutputSet(_ ids: Set<String>) {
        outputSetCalls.append(ids)
        desiredStates.append(macSelectedProvider() && !ids.isEmpty)
    }

    func retryOutput(_ id: String) {}
}
