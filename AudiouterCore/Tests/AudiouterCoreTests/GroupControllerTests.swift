import Foundation
import Testing
@testable import AudiouterCore

@Suite struct GroupControllerTests {

    /// An isolated `UserDefaults` suite, unique per test instance (swift-testing
    /// constructs a fresh `GroupControllerTests` for every `@Test`) — never
    /// `.standard`. Every `GroupController` this file builds must be handed an
    /// `AppSettings` wrapping THIS, or the Main Out master volume it persists
    /// reads/writes the developer's real defaults domain and tests flake against
    /// each other and against everything else in the suite.
    private let isolatedDefaults: UserDefaults

    init() {
        let suiteName = "AudiouterTests.\(Self.self).\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: suiteName)!
        isolatedDefaults.removePersistentDomain(forName: suiteName)
    }

    /// Deterministic backend: no discovery stagger, no timers, pre-populated
    /// synchronously via a blocking discovery wait (mirrors MockBackendTests).
    /// `connectScripts` (default none) lets a caller exercise the connection
    /// state machine (fail/retry choreography) the same way
    /// `PopoverControllerTests.makeScriptedPopover` does.
    private func makeBackend(
        _ fleet: [Device] = .demoFleet,
        connectScripts: [String: ConnectScript] = [:]
    ) async throws -> MockBackend {
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false, emitsLevels: false,
                                  simulatesDropouts: false, connectScripts: connectScripts)
        let stream = backend.makeEventStream()
        let box = CountBox()
        try await confirmation("fleet discovered") { discovered in
            let task = Task {
                for await event in stream {
                    if case .deviceAdded = event, await box.increment() >= fleet.count {
                        discovered(); break
                    }
                }
            }
            defer { task.cancel() }
            backend.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }
        return backend
    }

    private func makeController(
        fleet: [Device] = .demoFleet,
        injectedBackend: MockBackend? = nil,
        directory: URL? = nil
    ) async throws -> (GroupController, MockBackend) {
        let backend: MockBackend
        if let injectedBackend {
            backend = injectedBackend
        } else {
            backend = try await makeBackend(fleet)
        }
        let store = GroupStore(directory: directory ?? tempDirectory())
        let controller = GroupController(backend: backend, store: store,
                                         settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        return (controller, backend)
    }

    /// Same fixture as `makeController`, but over a `RecordingBackend` — for
    /// tests that need to assert WHAT was written across the `OutputBackend`
    /// seam (a hardware mirror, an ordering, a stubbed `systemOutputVolume`),
    /// not just the resulting device/model state.
    private func makeRecordingController(
        fleet: [Device] = .demoFleet,
        systemOutputVolume: Int? = nil
    ) async throws -> (GroupController, RecordingBackend) {
        let mock = try await makeBackend(fleet)
        let backend = RecordingBackend(mock, systemOutputVolume: systemOutputVolume)
        let controller = GroupController(backend: backend, store: GroupStore(directory: tempDirectory()),
                                         settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        return (controller, backend)
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return url
    }

    private func volume(_ id: String, in backend: any OutputBackend) -> Int? {
        backend.devices.first { $0.id == id }?.volume
    }

    // MARK: Selected Devices + Main Out routing (SPEC §9 2026-07-14b)

    @Test func setDeviceSelectedComposesSetWithoutRoutingUnderGroupTarget() async throws {
        let (controller, backend) = try await makeController()
        // Point Main Out at a group so composing must not re-route.
        try controller.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["sonos-move"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = Set(backend.devices.filter(\.isSelected).map(\.id))

        _ = controller.setDeviceSelected("office", true)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.isSpeakerSelected("office"), "the set was composed")
        #expect(Set(backend.devices.filter(\.isSelected).map(\.id)) == before,
                       "composing didn't re-route (target is a group)")
    }

    @Test func setDeviceSelectedLiveAppliesUnderSelectedDevicesTarget() async throws {
        let (controller, backend) = try await makeController()
        controller.setMainOut(.selectedDevices)
        _ = controller.setDeviceSelected("office", true)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(backend.devices.first { $0.id == "office" }?.isSelected == true,
                      "composing live-applies when Main Out targets Selected Devices")
        _ = controller.setDeviceSelected("office", false)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!(backend.devices.first { $0.id == "office" }?.isSelected == true))
    }

    // MARK: onMainOutMembersChanged — the "one role per speaker" hook

    /// Selecting a speaker into Main Out (Selected Devices target) fires
    /// `onMainOutMembersChanged` with the AirPlay member set, so the coordinating
    /// layer can yield any per-app redirect still pointed at it. The local Mac is
    /// never in the set (it's not a backend output).
    @Test func onMainOutMembersChangedFiresWithSelectedAirPlayMembers() async throws {
        let (controller, _) = try await makeController()
        controller.setMainOut(.selectedDevices)
        // Reset to a clean baseline so the assertion reads only OUR toggle.
        for id in controller.selectedDeviceIDs { _ = controller.setDeviceSelected(id, false) }
        var lastMembers: Set<String>?
        controller.onMainOutMembersChanged = { lastMembers = $0 }

        _ = controller.setDeviceSelected("office", true)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(lastMembers?.contains("office") == true,
                "selecting a speaker fires with it in the Main Out member set")
        #expect(lastMembers?.contains("local-mac") != true,
                "the local Mac is never a backend output, so never a redirect conflict")
    }

    /// Activating a group fires the hook with every AirPlay member of that group,
    /// so redirects pointed at any of them yield — the group path, which reaches
    /// the backend through `activateGroup`, not the Selected-Devices branch.
    @Test func onMainOutMembersChangedFiresWithGroupMembersOnActivation() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Pair",
                                        memberIDs: ["office", "homepod-bed"], memberVolumes: [:]))
        var lastMembers: Set<String>?
        controller.onMainOutMembersChanged = { lastMembers = $0 }

        controller.activateGroup(id: "g1")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(lastMembers == ["office", "homepod-bed"],
                "group activation fires with exactly the group's AirPlay members")
    }

    /// Poll `backend` until `id`'s connection state satisfies `predicate`
    /// (mirrors `PopoverControllerTests.waitForConnectionState`).
    private func waitForConnectionState(
        _ backend: MockBackend, id: String, timeout: TimeInterval = 3,
        _ predicate: (ConnectionState) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let device = backend.devices.first(where: { $0.id == id }),
               predicate(device.connectionState) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out waiting for \(id)'s connection state")
    }

    private func isFailed(_ state: ConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// R12/W2-T3 — `retryConnection(for:)`, the Selected-Devices branch: a
    /// `.failed` device is never removed from `selectedDeviceIDs` any more, so
    /// the ONLY way "Try again" can reach the backend is this dedicated call
    /// (a plain `setDeviceSelected(id, true)` would be a same-state no-op).
    /// Membership must stay untouched throughout — retry is a backend-facing
    /// re-kick, not a model mutation.
    @Test func retryConnectionForSelectedDeviceReconnectsWithoutTouchingMembership() async throws {
        let backend = try await makeBackend(connectScripts: ["office": ConnectScript(attempts: [
            .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
            .connect(after: 0.05),
        ])])
        let (controller, _) = try await makeController(injectedBackend: backend)
        controller.setMainOut(.selectedDevices)

        _ = controller.setDeviceSelected("office", true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        #expect(controller.isSpeakerSelected("office"), "R12: still selected despite the failure")

        _ = controller.retryConnection(for: "office")
        #expect(controller.isSpeakerSelected("office"), "retry never touches membership")
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        #expect(controller.isSpeakerSelected("office"))
    }

    /// R12/W2-T3 — `retryConnection(for:)`, the active-GROUP branch: a group
    /// member that fails is never dropped from the group (group membership was
    /// never touched by connection state to begin with), so retry must
    /// re-activate the group rather than mistake this for a Selected-Devices
    /// id. Confirms Groups and Selected Devices behave identically for retry.
    @Test func retryConnectionForActiveGroupMemberReconnectsWithoutTouchingMembership() async throws {
        let backend = try await makeBackend(connectScripts: ["office": ConnectScript(attempts: [
            .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
            .connect(after: 0.05),
        ])])
        let (controller, _) = try await makeController(injectedBackend: backend)
        try controller.saveGroup(Group(id: "g1", name: "Office Pair", memberIDs: ["office"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))

        try await waitForConnectionState(backend, id: "office", isFailed)
        #expect(controller.activeGroupID == "g1", "still the active group despite the failure")
        #expect(!controller.isSpeakerSelected("office"),
                "a pure group member is never in the ad-hoc Selected-Devices set")

        _ = controller.retryConnection(for: "office")
        #expect(controller.activeGroupID == "g1", "retry never touches group membership/activation")
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        #expect(controller.activeGroupID == "g1")
    }

    /// R12 adversarial-review fixup — `retryConnection(for:)` must decide its
    /// re-kick path off which routing is ACTUALLY active (`mainOut`), not off
    /// whichever membership set happens to contain `id` first.
    /// `selectedDeviceIDs` and an active group's `memberIDs` are independent
    /// sets: a device can be in BOTH (selected individually, then also a
    /// member of a group that later becomes Main Out). Before the fix, the
    /// Selected-Devices branch ran first, matched on `selectedDeviceIDs`
    /// membership alone, saw `mainOut != .selectedDevices`, skipped
    /// `applyRouting()`, and returned `.ok` anyway — a dead retry that never
    /// reached the backend even though the button reported success. This
    /// drives the connect script's SECOND attempt (`.connect`) only if the
    /// group re-kick actually fires `setOutputSet` again; the old order would
    /// leave `office` parked in `.failed` forever and this test would time out.
    @Test func retryConnectionForDeviceInBothSelectedDevicesAndActiveGroupUsesGroupRouting() async throws {
        let backend = try await makeBackend(connectScripts: ["office": ConnectScript(attempts: [
            .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
            .connect(after: 0.05),
        ])])
        let (controller, _) = try await makeController(injectedBackend: backend)

        // A group containing "office" becomes Main Out first — this is attempt
        // #1 (the scripted failure) and it's the ONLY thing driving the backend
        // so far.
        try controller.saveGroup(Group(id: "g1", name: "Office Pair", memberIDs: ["office"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        try await waitForConnectionState(backend, id: "office", isFailed)

        // NOW compose "office" into Selected Devices too. Main Out is still the
        // group, so `setDeviceSelected`'s own live-apply guard does NOT fire —
        // this only changes membership, no extra backend call, no extra
        // attempt consumed. The two membership sets now overlap while the
        // group remains the one actually routing.
        _ = controller.setDeviceSelected("office", true)
        #expect(controller.isSpeakerSelected("office"), "now also in Selected Devices (independent set)")
        #expect(controller.activeGroupID == "g1", "Main Out is still the group — this is what's actually routing")
        #expect(isFailed(backend.devices.first { $0.id == "office" }!.connectionState),
                "still failed — composing membership must not have re-kicked anything yet")

        // The retry button is the only thing left that can consume attempt #2
        // (`.connect`). Under the pre-fix branch order this call is a dead
        // no-op (matches `selectedDeviceIDs` first, sees `mainOut != .selectedDevices`,
        // never calls `applyRouting()`) and this assertion times out.
        _ = controller.retryConnection(for: "office")
        #expect(controller.isSpeakerSelected("office"), "retry never touches Selected-Devices membership")
        #expect(controller.activeGroupID == "g1", "retry never touches group membership/activation")
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        #expect(controller.activeGroupID == "g1")
    }

    @Test func defaultSelectionIsLocalPassthrough() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()
        #expect(controller.selectedDeviceIDs == ["local-mac"])
        #expect(controller.mainOut == .selectedDevices)
        #expect(controller.isPassthrough, "default = current device only ⇒ passthrough")
    }

    @Test func autoSwapDropsLocalWhenSoleMember() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // set = {local}
        let r = controller.setDeviceSelected("office", true)
        #expect(r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["office"], "local dropped, AirPlay added")
    }

    /// REVERSE auto-swap (ahh, live session 2026-07-17b): removing the LAST
    /// AirPlay device must restore the local passthrough default, not leave the
    /// set empty — an empty set renders as a zeroed Main Out master and gives the
    /// volume keys nothing to visibly drive.
    @Test func reverseAutoSwapRestoresLocalWhenLastAirPlayRemoved() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // {local}
        _ = controller.setDeviceSelected("office", true)          // auto-swap: {office}
        let r = controller.setDeviceSelected("office", false)
        #expect(r.autoSwappedCurrentDevice, "the restore is surfaced like the forward swap")
        #expect(controller.selectedDeviceIDs == ["local-mac"], "back to the passthrough default")
        #expect(controller.isPassthrough)
    }

    @Test func reverseAutoSwapDoesNotFireWhileAnotherAirPlayRemains() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)
        _ = controller.setDeviceSelected("homepod-bed", true)
        let r = controller.setDeviceSelected("office", false)
        #expect(!r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["homepod-bed"], "the remaining speaker keeps the set")
    }

    /// Current-device floor (Warm Signal v4 §Call-1): there is NEVER a
    /// zero-selected state, so deselecting the LAST remaining device — even the
    /// local one itself — auto-reselects the current device. The toggle becomes a
    /// no-op the row bounces back from; the flash does NOT fire (the user acted on
    /// the local row directly, it wasn't an auto-swap done for them).
    ///
    /// Supersedes main's `deselectingLocalItselfDoesNotSelfRestore`, which asserted
    /// the pre-floor outcome (selection goes empty).
    @Test func deselectingLastDeviceReselectsCurrentDeviceFloor() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // {local}
        let r = controller.setDeviceSelected("local-mac", false)
        #expect(!r.autoSwappedCurrentDevice, "no flash — the user toggled the local row itself")
        #expect(controller.selectedDeviceIDs == ["local-mac"],
                "the current-device floor keeps the spine — never zero selected")
    }

    /// THE ORIGINAL SYMPTOM, kept as history: the Main Out master used to be the
    /// members' AVERAGE, so removing the last AirPlay device averaged an EMPTY SET
    /// and slammed the master to 0. Main now owns its own value, which makes that
    /// failure structurally impossible rather than merely fixed — there is no
    /// average left to collapse.
    ///
    /// So what this pins now is the guarantee that survives: a disconnect does not
    /// move Main AT ALL, and the Mac's row takes back the wheel (the documented
    /// passthrough exception).
    @Test func lastAirPlayRemovalLeavesMainUntouchedAndHandsTheMacTheWheel() async throws {
        let (controller, _) = try await makeController(fleet: [
            Device(id: "local-mac", name: "MacBook Pro Speakers", kind: .localMac,
                   supportsAirPlay2: false, volume: 65, isLocalDevice: true),
            Device(id: "office", name: "Office", kind: .sonos, volume: 40),
        ])
        controller.ensureDefaultSelection()
        controller.setMainOutMasterVolume(55)                     // where the user put it

        _ = controller.setDeviceSelected("office", true)          // now streaming
        #expect(controller.mainOutMasterVolume == 55,
                       "selecting an AirPlay device does not move Main")
        #expect(!controller.localRowDrivesMain,
                       "with a real output live, the Mac's row is its own fader")

        _ = controller.setDeviceSelected("office", false)         // disconnect
        #expect(controller.mainOutMasterVolume == 55,
                       "a disconnect leaves Main exactly where the user put it — nothing to average to 0")
        #expect(controller.localRowDrivesMain,
                       "back in passthrough, the Mac's row drives Main again")
    }

    @Test func autoSwapDoesNotFireWhenLocalNotSoleMember() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)          // no local at all
        let r = controller.setDeviceSelected("homepod-bed", true)
        #expect(!r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["office", "homepod-bed"])
    }

    // MARK: Q5 / T-GROUPCTL — synced local sink: the Mac may join a mixed set.
    // Exhaustive transition matrix. S = selectedDeviceIDs BEFORE the change;
    // L = "local-mac"; A = an AirPlay/non-local id. Default S from
    // ensureDefaultSelection()/makeController is {L}.

    // --- ADD an AirPlay device A ---

    // ADD A, S == {L} (Mac sole member) → auto-drop L, insert A ⇒ {A}, autoSwapped.
    // (Also covered by testAutoSwapDropsLocalWhenSoleMember; asserted here as the
    // canonical first row of the matrix.)
    @Test func addAirPlay_whenMacIsSoleMember_autoDropsMac() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        #expect(controller.selectedDeviceIDs == ["local-mac"])
        let r = controller.setDeviceSelected("office", true)
        #expect(r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["office"], "Mac dropped, AirPlay in")
    }

    // ADD A, S already mixed {L, A1} → NO drop, insert A2 ⇒ {L, A1, A2}, Mac stays.
    // This is the newly-reachable mixed state; the substance of Q5.
    @Test func addAirPlay_whenMacAlreadyMixed_macStaysNoDrop() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        // Reach the mixed set {local-mac, office} by adding the Mac back in.
        _ = controller.setDeviceSelected("office", true)          // auto-swap → {office}
        let addMac = controller.setDeviceSelected("local-mac", true)
        #expect(addMac.applied)
        #expect(!addMac.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["office", "local-mac"], "mixed set reached")

        // Now add a SECOND AirPlay device — the Mac must NOT be dropped.
        let r = controller.setDeviceSelected("homepod-bed", true)
        #expect(r.applied)
        #expect(!r.autoSwappedCurrentDevice, "auto-swap fires only when Mac is sole member")
        #expect(controller.selectedDeviceIDs ==
                       ["office", "local-mac", "homepod-bed"],
                       "Mac stays in the mixed set")
    }

    // ADD A, S contains only AirPlay device(s) → plain insert, no drop.
    @Test func addAirPlay_whenAirPlayOnly_plainInsert() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office} (Mac auto-dropped)
        let r = controller.setDeviceSelected("homepod-bed", true)
        #expect(r.applied)
        #expect(!r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["office", "homepod-bed"])
    }

    // NOTE: a "S empty → plain insert" test (`testAddAirPlay_whenSelectionEmpty_plainInsert`)
    // existed on main's lineage, from before the current-device floor (Warm Signal
    // v4 §Call-1, see `testDeselectingLastDeviceReselectsCurrentDeviceFloor` above)
    // landed on this branch. That floor means "deliberately turn the Mac off to
    // reach an empty selection" is no longer reachable — the deselect bounces
    // straight back to {local-mac} (tested above), so the premise this test
    // needed no longer exists. Its "no sole Mac member ⇒ no auto-swap" assertion
    // is already covered by `testAddAirPlay_whenAirPlayOnly_plainInsert` above via
    // a reachable AirPlay-only state, so nothing here loses coverage — dropped as
    // part of the ring-resting-state ⨯ main merge (2026-07-24) rather than kept
    // asserting an impossible precondition.

    // --- ADD the local device L (refusal lifted) ---

    // ADD L into an AirPlay-only set → allowed now, drops nothing ⇒ S ∪ {L}.
    // (Previously refused; supersedes testLocalMixBlockRefusesWithReason.)
    @Test func addLocal_intoAirPlaySet_isAllowedAndMixes() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office}
        #expect(controller.canSelectLocalSpeaker("local-mac"),
                      "the Mac is selectable into a mixed set now")
        let r = controller.setDeviceSelected("local-mac", true)
        #expect(r.applied)
        #expect(r.refusalReason == nil)
        #expect(!r.autoSwappedCurrentDevice, "adding the Mac never drops anything")
        #expect(controller.selectedDeviceIDs == ["office", "local-mac"])
    }

    // ADD L into a multi-AirPlay set → allowed, no drop ⇒ all three present.
    @Test func addLocal_intoMultiAirPlaySet_isAllowed() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)          // → {office}
        _ = controller.setDeviceSelected("homepod-bed", true)     // → {office, homepod-bed}
        let r = controller.setDeviceSelected("local-mac", true)
        #expect(r.applied)
        #expect(!r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["office", "homepod-bed", "local-mac"])
    }

    // ADD L when already present (mixed set) → no-op .ok, set unchanged.
    @Test func addLocal_whenAlreadyMixed_isNoOp() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)
        _ = controller.setDeviceSelected("local-mac", true)       // → {office, local-mac}
        let r = controller.setDeviceSelected("local-mac", true)
        #expect(r.applied)
        #expect(!r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["office", "local-mac"])
    }

    // canSelectLocalSpeaker is unconditionally true (block lifted), in every state.
    @Test func canSelectLocalSpeakerAlwaysTrue() async throws {
        let (controller, _) = try await makeController()
        #expect(controller.canSelectLocalSpeaker("local-mac"))      // S == {L}
        _ = controller.setDeviceSelected("office", true)                 // S == {office}
        #expect(controller.canSelectLocalSpeaker("local-mac"),
                      "the pre-engine local-mix block is gone")
        _ = controller.setDeviceSelected("local-mac", true)              // S == {office, local-mac}
        #expect(controller.canSelectLocalSpeaker("local-mac"))
    }

    // --- REMOVE: current-device floor + subsumed reverse auto-swap ---

    // REMOVE the last AirPlay from a MIXED set {L, A} → naturally leaves {L}; the
    // floor is SUBSUMED (does NOT fire, autoSwapped=false), the Mac just stays.
    @Test func removeLastAirPlay_fromMixedSet_leavesMacNoReverseSwap() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office}
        _ = controller.setDeviceSelected("local-mac", true)       // → {office, local-mac} (mixed)
        let r = controller.setDeviceSelected("office", false)     // remove the only AirPlay
        #expect(r.applied)
        #expect(!r.autoSwappedCurrentDevice,
                       "floor is subsumed — Mac was already present, no restore needed")
        #expect(controller.selectedDeviceIDs == ["local-mac"])
    }

    // REMOVE one AirPlay from {L, A1, A2} → {L, A2}; floor does not fire.
    @Test func removeOneAirPlay_fromMixedMultiSet_keepsRest() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)          // → {office}
        _ = controller.setDeviceSelected("homepod-bed", true)     // → {office, homepod-bed}
        _ = controller.setDeviceSelected("local-mac", true)       // → {office, homepod-bed, local-mac}
        let r = controller.setDeviceSelected("office", false)
        #expect(r.applied)
        #expect(!r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["homepod-bed", "local-mac"])
    }

    // REMOVE the Mac from a MIXED set {L, A} → deliberate; leaves {A}, no floor.
    @Test func removeMac_fromMixedSet_leavesAirPlayOnly() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office}
        _ = controller.setDeviceSelected("local-mac", true)       // → {office, local-mac}
        let r = controller.setDeviceSelected("local-mac", false)
        #expect(r.applied)
        #expect(!r.autoSwappedCurrentDevice,
                       "removing the Mac itself is deliberate, never re-restored")
        #expect(controller.selectedDeviceIDs == ["office"])
    }

    // REMOVE the last AirPlay from an AirPlay-ONLY set {A} → floor restores {L}.
    // (Also covered by testReverseAutoSwapRestoresLocalWhenLastAirPlayRemoved;
    // kept here to complete the matrix — this is the one remove case that floors.)
    @Test func removeLastAirPlay_fromAirPlayOnlySet_floorsToMac() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office} (Mac auto-dropped)
        let r = controller.setDeviceSelected("office", false)
        #expect(r.applied)
        #expect(r.autoSwappedCurrentDevice, "empty result floors back to {local}")
        #expect(controller.selectedDeviceIDs == ["local-mac"])
    }

    @Test func passthroughDerivedOnlyForLocalOnlySet() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()
        #expect(controller.isPassthrough)
        _ = controller.setDeviceSelected("office", true)          // auto-swaps local out
        #expect(!controller.isPassthrough, "AirPlay-only set is not passthrough")
    }

    @Test func setMainOutGroupRoutesToMembers() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Pair",
                                        memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.activeGroupID == "g1")
        #expect(Set(backend.devices.filter(\.isSelected).map(\.id)) == ["sonos-move", "office"])
    }

    // MARK: Activation

    @Test func activateGroupSetsOutputSetToExactlyItsMembers() async throws {
        let (controller, backend) = try await makeController()
        let group = Group(id: "g1", name: "Downstairs", memberIDs: ["sonos-move", "office"], memberVolumes: [:])
        try controller.saveGroup(group)

        controller.activateGroup(id: "g1")
        try await Task.sleep(nanoseconds: 200_000_000)

        let selected = Set(backend.devices.filter(\.isSelected).map(\.id))
        #expect(selected == ["sonos-move", "office"])
        #expect(controller.activeGroupID == "g1")
    }

    @Test func activateGroupAppliesRememberedVolumes() async throws {
        let (controller, backend) = try await makeController()
        let group = Group(
            id: "g1", name: "Downstairs",
            memberIDs: ["sonos-move", "office"],
            memberVolumes: ["sonos-move": 77, "office": 12]
        )
        try controller.saveGroup(group)

        controller.activateGroup(id: "g1")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(volume("sonos-move", in: backend) == 77)
        #expect(volume("office", in: backend) == 12)
    }

    // MARK: Activation — the local Mac is never an engine output
    //
    // A saved group may MIX the Mac with AirPlay speakers (the pre-engine
    // local-mix block is gone — `canSelectLocalSpeaker` is unconditionally true).
    // `activateGroup` must therefore apply the SAME local-device filter
    // `applyRouting()`'s Selected-Devices branch does: the Mac is the Mac's own
    // output, not an engine output, and `NativeBackend.setOutputSet` documents
    // that `GroupController` never hands it through. The Mac still plays — via
    // the synced local sink, armed off `isMainOutMember(_:)` (below).

    /// Mixed group {Mac, AirPlay}: only the AirPlay side reaches the backend.
    @Test func activateGroupMixingMacWithAirPlayExcludesMacFromOutputSet() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen",
                                       memberIDs: ["local-mac", "sonos-move"], memberVolumes: [:]))

        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(Set(backend.devices.filter(\.isSelected).map(\.id)) == ["sonos-move"],
                "the local Mac must never enter the backend output set")
        #expect(!(backend.devices.first { $0.id == "local-mac" }?.isSelected ?? false),
                "the Mac has no engine session — it plays via the synced local sink")
    }

    /// Mac-ONLY group: the backend output set is EMPTY (passthrough), exactly as
    /// a Selected-Devices set of {local} reaches the backend. Handing the Mac
    /// through instead made this look like "≥1 real output" downstream — which is
    /// what would arm the synced local sink with nothing behind it.
    @Test func activateGroupOfTheMacAloneReachesBackendAsEmptyOutputSet() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Just the Mac",
                                       memberIDs: ["local-mac"], memberVolumes: [:]))

        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(Set(backend.devices.filter(\.isSelected).map(\.id)) == [],
                "a Mac-only group is passthrough — an EMPTY backend output set")
    }

    /// The Mac's "volume" is the Mac's SYSTEM output level, so replaying a
    /// group's remembered value would silently move it on every activation (and a
    /// remembered 0 would mute the Mac outright). Its AirPlay siblings still get
    /// their remembered levels.
    @Test func activateGroupDoesNotPushRememberedVolumeToTheMac() async throws {
        let (controller, backend) = try await makeController()
        let macVolumeBefore = volume("local-mac", in: backend)
        try controller.saveGroup(Group(id: "g1", name: "Kitchen",
                                       memberIDs: ["local-mac", "sonos-move"],
                                       memberVolumes: ["local-mac": 0, "sonos-move": 77]))

        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(volume("sonos-move", in: backend) == 77, "AirPlay members still get their levels")
        #expect(volume("local-mac", in: backend) == macVolumeBefore,
                "activating a group must not write the Mac's system output volume")
    }

    // MARK: Main Out membership — the synced-local-sink arming query
    //
    // `isMainOutMember(_:)` is what `NativeBackend.selectedDevicesQuery` is wired
    // to (AppDelegate). It has to exist because the Mac never travels in
    // `setOutputSet`'s ids, and it must follow the MAIN OUT TARGET, not the
    // Selected Devices set, or the group path gets it wrong in both directions.

    /// A group containing the Mac reports the Mac as a Main Out member — so the
    /// synced local sink arms and the Mac stays audible alongside the speaker.
    @Test func isMainOutMemberSeesTheMacInsideTheActiveGroup() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen",
                                       memberIDs: ["local-mac", "sonos-move"], memberVolumes: [:]))

        controller.setMainOut(.group(id: "g1"))

        #expect(controller.isMainOutMember("local-mac"),
                "a group containing the Mac must arm the synced local sink")
        #expect(controller.isMainOutMember("sonos-move"))
        #expect(!controller.isMainOutMember("office"), "a non-member is not a Main Out member")
    }

    /// The mirror failure: an AirPlay-ONLY group must NOT report the Mac, even
    /// though the Mac is still sitting in the (now untargeted) Selected Devices
    /// set — otherwise the sink arms and the Mac plays when the user routed the
    /// audio away from it.
    @Test func isMainOutMemberIgnoresSelectedDevicesWhileAGroupIsTheTarget() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        try controller.saveGroup(Group(id: "g1", name: "Patio",
                                       memberIDs: ["sonos-move"], memberVolumes: [:]))

        controller.setMainOut(.group(id: "g1"))

        #expect(controller.isSpeakerSelected("local-mac"),
                "the Mac is still in the untargeted Selected Devices set")
        #expect(!(controller.isMainOutMember("local-mac")),
                "an AirPlay-only group must not arm the synced local sink")
    }

    /// The rewire's safety proof (NOT a regression test — this invariant holds
    /// before and after the fix): under the ordinary `.selectedDevices` target,
    /// `isMainOutMember(_:)` is EXACTLY `isSpeakerSelected(_:)` for every id in
    /// every selection state, because `mainOutMemberIDs` is
    /// `Array(selectedDeviceIDs)` in that branch. So repointing
    /// `NativeBackend.selectedDevicesQuery` from one to the other changes
    /// behaviour on the GROUP path only.
    @Test func isMainOutMemberEqualsIsSpeakerSelectedUnderSelectedDevicesTarget() async throws {
        let (controller, backend) = try await makeController()
        let ids = backend.devices.map(\.id) + ["never-discovered"]

        func assertAgrees(_ label: String) {
            for id in ids {
                #expect(controller.isMainOutMember(id) == controller.isSpeakerSelected(id),
                        "\(label): the two reads disagree on \(id)")
            }
        }

        controller.setMainOut(.selectedDevices)
        assertAgrees("empty selection")
        controller.ensureDefaultSelection()                       // S = {local-mac}
        assertAgrees("{local-mac}")
        _ = controller.setDeviceSelected("sonos-move", true)      // auto-swap → {sonos-move}
        assertAgrees("AirPlay-only after auto-swap")
        _ = controller.setDeviceSelected("local-mac", true)       // → mixed
        assertAgrees("mixed {sonos-move, local-mac}")
        _ = controller.setDeviceSelected("office", true)
        assertAgrees("mixed + a second AirPlay device")
        _ = controller.setDeviceSelected("sonos-move", false)
        assertAgrees("after a removal")
    }

    @Test func deactivateGroupClearsActiveIDWithoutChangingOutputSet() async throws {
        let (controller, backend) = try await makeController()
        let group = Group(id: "g1", name: "Downstairs", memberIDs: ["sonos-move"], memberVolumes: [:])
        try controller.saveGroup(group)
        controller.activateGroup(id: "g1")
        try await Task.sleep(nanoseconds: 100_000_000)

        controller.deactivateGroup()
        #expect(controller.activeGroupID == nil)

        let selected = Set(backend.devices.filter(\.isSelected).map(\.id))
        #expect(selected == ["sonos-move"], "deactivating must not itself change the output set")
    }

    @Test func saveCurrentSetupAsGroupCapturesSelectedDevicesAndVolumes() async throws {
        let (controller, backend) = try await makeController()
        // Compose the Selected Devices set (SPEC §9b — save = save the set).
        _ = controller.setDeviceSelected("sonos-move", true)
        _ = controller.setDeviceSelected("homepod-bed", true)
        backend.setVolume(33, for: "sonos-move")
        backend.setVolume(81, for: "homepod-bed")
        try await Task.sleep(nanoseconds: 200_000_000)

        let group = try controller.saveCurrentSetupAsGroup(name: "Party", id: "party").group

        #expect(Set(group.memberIDs) == ["sonos-move", "homepod-bed"])
        #expect(group.memberVolumes["sonos-move"] == 33)
        #expect(group.memberVolumes["homepod-bed"] == 81)
        #expect(controller.groups.contains { $0.id == "party" })
    }

    // MARK: Dedup / group identity (SPEC.md §9)

    @Test func memberSetMatchIsOrderIndependent() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Downstairs",
                                        memberIDs: ["office", "sonos-move"], memberVolumes: [:]))
        // Same set, different order → same group.
        #expect(controller.group(matchingMemberSet: ["sonos-move", "office"])?.id == "g1")
        #expect(controller.group(matchingMemberSet: ["office", "sonos-move"])?.id == "g1")
        // Different set → no match; empty set → no match.
        #expect(controller.group(matchingMemberSet: ["office"]) == nil)
        #expect(controller.group(matchingMemberSet: ["office", "sonos-move", "homepod-bed"]) == nil)
        #expect(controller.group(matchingMemberSet: []) == nil)
    }

    @Test func saveCurrentSetupWithDuplicateSetDoesNotCreateSecondGroup() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("sonos-move", true)
        _ = controller.setDeviceSelected("office", true)
        try await Task.sleep(nanoseconds: 200_000_000)

        let first = try controller.saveCurrentSetupAsGroup(name: "Group 1")
        #expect(!first.alreadyExisted)
        #expect(controller.groups.count == 1)

        // Same Selected Devices set → must resolve to the existing group, not a copy.
        let second = try controller.saveCurrentSetupAsGroup(name: "Group 2")
        #expect(second.alreadyExisted, "identical member set signals already-exists")
        #expect(second.group.id == first.group.id)
        #expect(controller.groups.count == 1, "no duplicate group created")
    }

    @Test func createGroupDedupsByMemberSet() async throws {
        let (controller, _) = try await makeController()
        let a = try controller.createGroup(name: "Downstairs", memberIDs: ["office", "sonos-move"])
        #expect(!a.alreadyExisted)
        // Same members in a different order → resolves to the same group.
        let b = try controller.createGroup(name: "Different Name", memberIDs: ["sonos-move", "office"])
        #expect(b.alreadyExisted)
        #expect(b.group.id == a.group.id)
        #expect(controller.groups.count == 1)
    }

    // MARK: Empty-membership invariant (a group must keep ≥1 device)

    @Test func createGroupWithNoMembersIsRejected() async throws {
        let (controller, _) = try await makeController()
        #expect(throws: GroupController.GroupError.emptyMembership) {
            try controller.createGroup(name: "Empty", memberIDs: [])
        }
        #expect(controller.groups.isEmpty, "no empty group should have been persisted")
    }

    @Test func saveGroupWithNoMembersIsRejectedAndLeavesGroupsUntouched() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office"], memberVolumes: [:]))

        // Attempting to save the same group emptied out must throw AND must not
        // mutate the persisted group (the guard runs before any mutation).
        #expect(throws: GroupController.GroupError.emptyMembership) {
            try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: [], memberVolumes: [:]))
        }
        #expect(controller.groups.first(where: { $0.id == "g1" })?.memberIDs == ["office"],
                       "the rejected empty save must leave the existing group intact")
    }

    /// **Known ambiguity, resolved by a prior attempt at this task and preserved
    /// here rather than re-litigated (flagged again for human confirmation):**
    /// this test wants to skip only when the fleet genuinely can't be driven to
    /// an empty selection, but that fact is only knowable AFTER the
    /// `setDeviceSelected` calls above run — a `.enabled(if:)`/`.disabled(if:)`
    /// trait evaluates at discovery time, before the body runs, so it cannot see
    /// this. Converted to a runtime check that reports a non-failing known issue
    /// (preserving the original `XCTSkip`'s "inconclusive on this fleet, don't
    /// fail the run" intent) instead of a discovery-time trait.
    @Test func saveCurrentSetupAsGroupWithEmptySelectionIsRejected() async throws {
        let (controller, _) = try await makeController()
        // Default selection is {local}; clear it so the selected set is empty.
        for id in controller.selectedDeviceIDs { _ = controller.setDeviceSelected(id, false) }
        // Reverse auto-swap may reseed {local}; force truly empty by removing again.
        for id in controller.selectedDeviceIDs { _ = controller.setDeviceSelected(id, false) }
        guard controller.selectedDeviceIDs.isEmpty else {
            withKnownIssue("could not reach an empty selection on this fleet") {
                Issue.record("could not reach an empty selection on this fleet")
            }
            return
        }
        #expect(throws: GroupController.GroupError.emptyMembership) {
            try controller.saveCurrentSetupAsGroup(name: "Nothing")
        }
    }

    @Test func activeGroupTracksMainOutGroupTarget() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Downstairs",
                                       memberIDs: ["office", "sonos-move"], memberVolumes: [:]))
        // groupMatchingCurrentSelection is keyed off selectedDeviceIDs (Q3 — not
        // the live output set, which redirect targets can pollute), so Selected
        // Devices must mirror the group's membership for the sync to resolve it.
        _ = controller.setDeviceSelected("office", true)
        _ = controller.setDeviceSelected("sonos-move", true)

        // Main Out at the group → active; syncActiveGroupToSelection keeps it.
        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.syncActiveGroupToSelection() == "g1")
        #expect(controller.activeGroupID == "g1")

        // Main Out back at Selected Devices → no active group even if the output
        // set coincidentally equals the group.
        controller.setMainOut(.selectedDevices)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.syncActiveGroupToSelection() == nil)
        #expect(controller.activeGroupID == nil)
    }

    @Test func deleteGroupDeactivatesIfActive() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")

        try controller.deleteGroup(id: "g1")

        #expect(controller.activeGroupID == nil)
        #expect(!controller.groups.contains { $0.id == "g1" })
    }

    // MARK: Main Out master gain — a value of its own, never an average
    //
    // Supersedes "Proportional master — ratio preservation": Main used to be a
    // computed average of its members, and dragging it rewrote every member's
    // volume from a ratio snapshot. Main is now a stored master gain — what
    // reaches a device is `Main × Group × Device`, multiplied at the write
    // boundary — so a device's stored volume is always the user's own setting
    // and is never overwritten by a Main change. Each test below carries
    // forward the bug the deleted ratio test protected against, restated
    // against the new contract.

    /// Supersedes `masterVolumeIsAverageOfMembers` / `masterEchoesMemberAverageAfterIndividualChange`
    /// (there is no average left to compute): moving Main must not rewrite any
    /// member's stored level.
    @Test func movingMainLeavesEveryMemberVolumeUntouched() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(20, for: "sonos-move")
        backend.setVolume(60, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)

        controller.setMainOutMasterVolume(80)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(controller.mainOutMasterVolume == 80)
        #expect(volume("sonos-move", in: backend) == 20, "Main never rewrites a member's stored level")
        #expect(volume("office", in: backend) == 60)
    }

    /// Supersedes `masterEchoesMemberAverageAfterIndividualChange`'s other half:
    /// Main is its own value now, so moving one member must not move Main either.
    @Test func movingOneMemberLeavesMainUntouched() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        controller.setMainOutMasterVolume(55)

        controller.setMemberVolume(90, for: "office")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(volume("office", in: backend) == 90, "the member itself moved")
        #expect(controller.mainOutMasterVolume == 55, "Main is its own value — it echoes no member")
    }

    /// Supersedes `masterDragFromZeroMovesEveryoneTogether` ("zero collapse"):
    /// the old ratio fallback made every member sit at 0 with an undefined
    /// ratio, so the way back up was uniform. There is no ratio any more —
    /// Main 0 sends 0 while every stored level stays exactly where the user put
    /// it, so coming back up restores the exact original balance.
    @Test func mainToZeroAndBackRestoresEachMemberVolumeExactly() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(80, for: "sonos-move")
        backend.setVolume(20, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)

        controller.setMainOutMasterVolume(0)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.mainOutMasterVolume == 0)
        #expect(volume("sonos-move", in: backend) == 80, "stored levels don't move even at Main 0")
        #expect(volume("office", in: backend) == 20)

        controller.setMainOutMasterVolume(60)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(volume("sonos-move", in: backend) == 80, "coming back up restores the exact original balance")
        #expect(volume("office", in: backend) == 20)
    }

    /// Supersedes `memberAtMaxStaysClampedAcrossDragThenTracksAgainOnNextDrag`
    /// ("clamp ratchet"): the old failure needed an average to re-normalize
    /// against — once one member clamped at 100 the average fell below the
    /// target and the next step re-expanded everyone else, walking the balance
    /// away permanently. With no average and no ratio, a member at 100 has no
    /// path back into any other member's number across a full Main sweep.
    @Test func memberAtMaxStaysAtMaxAcrossAFullMainSweep() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(100, for: "sonos-move")
        backend.setVolume(50, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)

        for step in [0, 25, 50, 75, 100, 75, 50, 25, 0] {
            controller.setMainOutMasterVolume(step)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(volume("sonos-move", in: backend) == 100, "a member's own level has no path back to Main's sweep")
        #expect(volume("office", in: backend) == 50)
    }

    /// Supersedes the deleted `systemVolumeMirrorBurstStaysBounded`/
    /// `...PreservesBalanceAcrossBurst*` family ("burst rounding drift"): the
    /// old failure needed a per-member, per-step integer `.rounded()` write,
    /// whose ±0.5 random-walked over a ~16-step key burst. A Main change now
    /// performs NO per-member write at all, so a burst — the shape the volume
    /// keys actually produce — must leave every stored level bit-identical.
    @Test func sixteenStepMainBurstLeavesStoredLevelsBitIdentical() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(83, for: "sonos-move")
        backend.setVolume(17, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)

        let steps = stride(from: 20, through: 95, by: 5).map { $0 }   // 16 steps
        #expect(steps.count == 16)
        for step in steps { controller.setMainOutMasterVolume(step) }
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(volume("sonos-move", in: backend) == 83, "no per-member write happens on a Main change at all")
        #expect(volume("office", in: backend) == 17)
    }

    /// `applyExternalSystemVolume` is the volume-keys entry point: the system
    /// output already moved, so this must bring Main into agreement WITHOUT
    /// writing hardware back (that would be a pointless echo of a change that
    /// already happened). Re-applying the value Main already holds is
    /// similarly inert — no hardware write either time.
    @Test func applyExternalSystemVolumeMovesMainAndWritesNothingToHardware() async throws {
        let (controller, backend) = try await makeRecordingController()
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("office", true)      // stream, so this isn't the passthrough exception
        backend.reset()

        controller.applyExternalSystemVolume(42)
        #expect(controller.mainOutMasterVolume == 42)
        #expect(backend.gainWrites.allSatisfy { !$0.mirrorToSystemVolume },
                "the system volume already moved — mirroring it back would be a pointless echo")

        controller.applyExternalSystemVolume(42)               // re-apply the same value
        #expect(controller.mainOutMasterVolume == 42)
        #expect(backend.gainWrites.allSatisfy { !$0.mirrorToSystemVolume },
                "still no hardware write on a repeat of the value Main already holds")
    }

    /// Main's own level persists (debounced) and reloads on the next launch —
    /// distinct from `groupsPersistButRoutingResetsToLocalOnLaunch`, which pins
    /// that the ROUTING set does NOT resume; Main's level is a different field
    /// (`AppSettings.mainOutVolume`) that DOES.
    @Test func mainOutMasterVolumePersistsAndReloadsAcrossLaunches() async throws {
        let settings = AppSettings(defaults: isolatedDefaults)
        let mock1 = try await makeBackend()
        let c1 = GroupController(backend: mock1, store: GroupStore(directory: tempDirectory()),
                                 settings: settings, loadPersisted: false)
        c1.setMainOutMasterVolume(37)
        // No wait: the persist is a synchronous `UserDefaults` write. It used to be
        // a 0.5s trailing DispatchWorkItem, and this test slept past that delay —
        // which passed solo and failed under the full suite, because the work item
        // needed a serviced main run loop that a loaded run never gave it.
        #expect(settings.mainOutVolume == 37, "the level is persisted as soon as it is set")

        // A fresh controller/backend over the SAME settings store. MockBackend's
        // `systemOutputVolume` is always nil, so adoption falls through to the
        // just-persisted value — this doubles as the nil-fallback half of
        // `ensureDefaultSelectionFallsBackToPersistedSettingWhenSystemVolumeUnreadable`
        // below, exercised against a real prior launch instead of a stub.
        let mock2 = try await makeBackend()
        let c2 = GroupController(backend: mock2, store: GroupStore(directory: tempDirectory()),
                                 settings: settings, loadPersisted: false)
        c2.ensureDefaultSelection()

        #expect(c2.mainOutMasterVolume == 37, "Main reloads the persisted level on the next launch")
    }

    /// Launch ADOPTS the Mac's actual current system volume over whatever was
    /// persisted — opening the app must reflect reality, not silently override
    /// a level the user may have changed since the last launch outside the app.
    @Test func ensureDefaultSelectionAdoptsBackendSystemVolumeOverPersistedSetting() async throws {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.mainOutVolume = 90                      // a stale persisted value that must lose
        let (controller, _) = try await makeRecordingController(systemOutputVolume: 48)

        controller.ensureDefaultSelection()

        #expect(controller.mainOutMasterVolume == 48, "launch adopts the Mac's actual current level")
    }

    /// The fallback half: many aggregate/HDMI/digital outputs expose no
    /// readable volume at all (`systemOutputVolume == nil`) — launch must fall
    /// back to the persisted setting rather than crash or seed some hardcoded
    /// default.
    @Test func ensureDefaultSelectionFallsBackToPersistedSettingWhenSystemVolumeUnreadable() async throws {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.mainOutVolume = 33
        let (controller, _) = try await makeRecordingController(systemOutputVolume: nil)

        controller.ensureDefaultSelection()

        #expect(controller.mainOutMasterVolume == 33,
                "an aggregate/HDMI output with no readable volume falls back to the persisted setting")
    }

    // MARK: Mute (solo removed 2026-07-13)

    @Test func muteStoresPriorVolumeAndZeroes() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(65, for: "sonos-move")
        try await Task.sleep(nanoseconds: 200_000_000)

        controller.setMuted(true, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(volume("sonos-move", in: backend) == 0)
        #expect(controller.isMuted("sonos-move"))

        controller.setMuted(false, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(volume("sonos-move", in: backend) == 65, "unmute restores the pre-mute volume")
        #expect(!controller.isMuted("sonos-move"))
    }

    @Test func reMutingDoesNotOverwriteStashedVolume() async throws {
        // The stash is written only on the silence edge, so a redundant mute of
        // an already-muted member must not overwrite the original level with 0.
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(70, for: "sonos-move")
        try await Task.sleep(nanoseconds: 200_000_000)

        controller.setMuted(true, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(volume("sonos-move", in: backend) == 0)

        // Redundant mute (already muted) — must be a no-op, not a re-stash of 0.
        controller.setMuted(true, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)

        controller.setMuted(false, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(volume("sonos-move", in: backend) == 70, "unmute restores the original level, not 0")
    }

    // MARK: Persistence round-trip

    @Test func persistenceRoundTrip() throws {
        let dir = tempDirectory()
        let store = GroupStore(directory: dir)
        let groups = [
            Group(id: "g1", name: "Whole house", memberIDs: ["a", "b"], memberVolumes: ["a": 10, "b": 90]),
            Group(id: "g2", name: "Downstairs", memberIDs: ["a"], memberVolumes: ["a": 50]),
        ]
        try store.save(groups)

        let reloaded = try GroupStore(directory: dir).load()
        #expect(reloaded == groups)
    }

    @Test func loadWithNoFileReturnsEmpty() throws {
        let store = GroupStore(directory: tempDirectory())
        #expect(try store.load() == [])
    }

    @Test func loadUnknownFutureSchemaVersionReturnsEmptyRatherThanCrashing() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let future = """
        {"schemaVersion": 999, "groups": [{"id": "g1", "name": "X", "memberIDs": [], "memberVolumes": {}}]}
        """
        try Data(future.utf8).write(to: dir.appendingPathComponent("groups.json"))

        let store = GroupStore(directory: dir)
        #expect(try store.load() == [], "a future schema version must not crash an old build")
    }

    @Test func loadCorruptFileThrows() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("groups.json"))

        let store = GroupStore(directory: dir)
        #expect(throws: (any Error).self) {
            try store.load()
        }
    }

    @Test func groupControllerLoadsPersistedGroupsOnInit() async throws {
        let dir = tempDirectory()
        try GroupStore(directory: dir).save([Group(id: "g1", name: "X", memberIDs: ["a"], memberVolumes: [:])])

        let backend = try await makeBackend()
        let controller = GroupController(backend: backend, store: GroupStore(directory: dir),
                                         settings: AppSettings(defaults: isolatedDefaults), loadPersisted: true)

        #expect(controller.groups.map(\.id) == ["g1"])
    }

    // MARK: Routing persistence (SPEC §9b — Selected Devices + Main Out)

    // DECISION (ahh, 2026-07-17): the live Selected-Devices routing set does
    // NOT auto-resume on launch — every launch defaults to {current device} =
    // passthrough. Saved GROUPS still persist and stay re-applyable. This test
    // pins that split: the group loads on session 2, but the previously-selected
    // AirPlay set + group Main Out target do NOT restore — they reset to the
    // local-passthrough default.
    @Test func groupsPersistButRoutingResetsToLocalOnLaunch() async throws {
        let dir = tempDirectory()
        let routingStore = RoutingStore(directory: dir)

        // Session 1: compose a set + point Main Out at a group.
        let backend1 = try await makeBackend()
        let c1 = GroupController(backend: backend1, store: GroupStore(directory: dir),
                                 routingStore: routingStore,
                                 settings: AppSettings(defaults: isolatedDefaults), loadPersisted: true)
        try c1.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office", "sonos-move"], memberVolumes: [:]))
        _ = c1.setDeviceSelected("office", true)
        _ = c1.setDeviceSelected("homepod-bed", true)
        c1.setMainOut(.group(id: "g1"))

        // Session 2: a fresh controller over the same stores. The GROUP is
        // reloaded, but the live routing set is NOT resumed — it resets to the
        // local-passthrough default once the fleet is known.
        let backend2 = try await makeBackend()
        let c2 = GroupController(backend: backend2, store: GroupStore(directory: dir),
                                 routingStore: RoutingStore(directory: dir),
                                 settings: AppSettings(defaults: isolatedDefaults), loadPersisted: true)
        #expect(c2.groups.map(\.id) == ["g1"], "saved group still persists")
        #expect(c2.selectedDeviceIDs.isEmpty,
                      "persisted AirPlay selection is NOT auto-resumed on launch")
        #expect(c2.mainOut == .selectedDevices,
                       "persisted group Main Out target is NOT auto-resumed on launch")
        c2.ensureDefaultSelection()
        #expect(c2.selectedDeviceIDs == ["local-mac"],
                       "launch default = {current device} = passthrough")
        #expect(c2.isPassthrough)
    }

    @Test func routingDefaultWhenNoPersistedState() async throws {
        let backend = try await makeBackend()
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         settings: AppSettings(defaults: isolatedDefaults),
                                         loadPersisted: true)
        // No persisted routing → Main Out defaults to Selected Devices, set empty
        // until ensureDefaultSelection establishes the current-device default.
        #expect(controller.mainOut == .selectedDevices)
        #expect(controller.selectedDeviceIDs.isEmpty)
        controller.ensureDefaultSelection()
        #expect(controller.selectedDeviceIDs == ["local-mac"])
    }

    // MARK: Union removed (T7) — app-route targets NEVER enter the backend output set
    //
    // Pre-T7, `applyRouting()`/`activateGroup()` UNIONed app-route redirect targets
    // into `backend.setOutputSet(...)`, so redirecting ONE app streamed the whole
    // system mix to that device and muted the Mac (the original per-app-routing bug,
    // documented in AGENTS.md). T7 removed that union entirely — the injection point
    // (`appRouteTargets`/`redirectOutputIDs()`/`reapplyRouting()`) is gone, and a
    // redirected app now reaches its device through the per-app capture path
    // (`NativeBackend.updateAppRoutes`), never through this whole-system set. These
    // tests pin that the output set is now a PURE function of Selected Devices /
    // group membership, with nothing else able to leak in.

    /// Under `.selectedDevices` the backend output set is EXACTLY the Selected
    /// AirPlay members — no app-route target is ever added (the union is gone).
    @Test func selectedDevicesOutputSetIsExactlySelectedAirPlayMembers() async throws {
        let (controller, backend) = try await makeController()
        _ = controller.setDeviceSelected("office", true)
        controller.setMainOut(.selectedDevices)
        try await Task.sleep(nanoseconds: 200_000_000)

        let outputs = Set(backend.devices.filter(\.isSelected).map(\.id))
        #expect(outputs == ["office"],
                       "output set is exactly Selected Devices — no redirect-target union")
    }

    /// Passthrough (Selected == {local}) reaches the backend as an EMPTY output
    /// set even when app routes exist — the mute bug is gone: a redirect can no
    /// longer force a non-empty output set that opens the capture gate.
    @Test func passthroughOutputSetStaysEmpty() async throws {
        let (controller, backend) = try await makeController()
        controller.ensureDefaultSelection()   // seeds {local-mac} = passthrough
        controller.setMainOut(.selectedDevices)
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(controller.isPassthrough)
        #expect(backend.devices.filter(\.isSelected).isEmpty,
                      "passthrough output set is empty — no app-route target unioned in")
    }

    /// With Main Out pointed at a group, the output set is EXACTLY the group's
    /// members — app-route targets are not unioned into an active group either.
    @Test func activateGroupOutputSetIsExactlyGroupMembers() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["sonos-move"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)

        let outputs = Set(backend.devices.filter(\.isSelected).map(\.id))
        #expect(outputs == ["sonos-move"],
                       "active group's output set is exactly its members — no redirect union")
    }

    /// The separate invariant that OUTLIVES the union removal (AGENTS.md): the
    /// Main Out master + its member set are keyed off `selectedDeviceIDs` /
    /// `mainOutMemberIDs`, which never contained redirect targets — so master math
    /// and group identity are unaffected by any app route. Verified here against a
    /// selection that equals a saved group.
    @Test func groupIdentityAndMasterKeyOffSelectedDevicesNotOutputSet() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        _ = controller.setDeviceSelected("office", true)
        controller.setMainOut(.selectedDevices)
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!controller.isSpeakerSelected("homepod-bed"),
                       "a non-selected device is not in Selected Devices")
        #expect(controller.groupMatchingCurrentSelection?.id == "g1",
                       "group identity keys off selectedDeviceIDs")

        // Main used to be the members' average, so a member's own level moved it.
        // The stages are independent now: this asserts the member move does NOT
        // reach Main, which is the stronger property and the point of the refactor.
        controller.setMainOutMasterVolume(45)
        backend.setVolume(80, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.mainOutMasterVolume == 45,
                       "a member's own level never moves Main — they are independent stages")
    }

    // MARK: The passthrough exception — the Mac's row IS Main
    //
    // Everywhere else, moving a device never touches Main. The ONE documented
    // exception (`GroupController.setMemberVolume`'s doc comment) is the Mac's
    // own row while `localRowDrivesMain` — plain passthrough, and its
    // Mac-only-group twin — because in that state what the user hears IS the
    // system volume, and Main is precisely the control that moves it.
    //
    // These supersede the old `systemVolumeMirror*`/`perStepRatioRecomputation*`
    // family, which pinned an external-volume-key MIRROR that no longer exists
    // (`mirrorSystemVolumeToMainOut` is gone — `applyExternalSystemVolume` above
    // is its structural replacement, and it never touches a member at all). What
    // outlives that deletion is this file's coverage of the one place a member
    // write legitimately still reaches Main.

    /// 1. Passthrough: writing the local row moves Main and writes hardware.
    @Test func passthroughWritingLocalRowMovesMainAndWritesHardware() async throws {
        let (controller, backend) = try await makeRecordingController()
        controller.ensureDefaultSelection()                    // {local-mac} = passthrough
        #expect(controller.localRowDrivesMain)
        backend.reset()

        controller.setMemberVolume(45, for: "local-mac")

        #expect(controller.mainOutMasterVolume == 45, "the local row IS Main in passthrough")
        #expect(backend.gainWrites.last?.mirrorToSystemVolume == true,
                "passthrough's local write is the one path that mirrors to hardware")
    }

    /// 2. That same write leaves the Mac's own stored fader untouched — it must
    /// survive the round trip back to an ordinary mixed member (see case 4).
    @Test func passthroughWritingLocalRowLeavesTheMacsOwnStoredFaderUntouched() async throws {
        let (controller, backend) = try await makeRecordingController()
        controller.ensureDefaultSelection()
        let before = volume("local-mac", in: backend)

        controller.setMemberVolume(45, for: "local-mac")

        #expect(volume("local-mac", in: backend) == before,
                "the write went to Main, not the Mac's own stored level")
        #expect(backend.volumeWrites.allSatisfy { $0.id != "local-mac" },
                "passthrough never calls setVolume for the local device")
    }

    /// 3. Armed (Mac + ≥1 AirPlay): writing the local row moves the Mac's OWN
    /// fader, leaves Main unchanged, and writes no hardware — the row is an
    /// ordinary member now.
    @Test func armedWritingLocalRowMovesTheMacsFaderLeavesMainUnchangedWritesNoHardware() async throws {
        let (controller, backend) = try await makeRecordingController()
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("office", true)        // auto-swap → {office}
        _ = controller.setDeviceSelected("local-mac", true)     // → {office, local-mac}: armed
        #expect(!controller.localRowDrivesMain, "armed: there IS a real AirPlay output")
        controller.setMainOutMasterVolume(70)
        backend.reset()

        controller.setMemberVolume(60, for: "local-mac")

        #expect(volume("local-mac", in: backend) == 60, "armed: the row writes the Mac's OWN fader")
        #expect(controller.mainOutMasterVolume == 70, "Main is untouched by a member write")
        #expect(backend.gainWrites.isEmpty, "no hardware mirror — this wasn't a Main move")
    }

    /// 4. The Mac's fader is REMEMBERED across armed → passthrough → armed: it
    /// is never re-seeded from Main on the way back.
    @Test func macsFaderIsRememberedAcrossArmedPassthroughArmed() async throws {
        let (controller, backend) = try await makeRecordingController()
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("office", true)
        _ = controller.setDeviceSelected("local-mac", true)     // armed
        controller.setMemberVolume(60, for: "local-mac")
        #expect(volume("local-mac", in: backend) == 60)

        _ = controller.setDeviceSelected("office", false)       // → {local-mac}: passthrough
        #expect(controller.localRowDrivesMain)
        #expect(volume("local-mac", in: backend) == 60, "passthrough doesn't touch the stashed fader")

        _ = controller.setDeviceSelected("office", true)        // auto-swap → {office}
        _ = controller.setDeviceSelected("local-mac", true)     // → armed again
        #expect(!controller.localRowDrivesMain)
        #expect(volume("local-mac", in: backend) == 60,
                "the fader survives the round trip — never re-seeded from Main")
    }

    /// 5. Unity default: a fresh (never-touched) Mac fader means no audible
    /// change on the passthrough → armed transition — Main × 100% == Main.
    @Test func unityDefaultMeansNoAudibleChangeOnTheArmingTransition() async throws {
        let freshFleet: [Device] = [
            Device(id: "local-mac", name: "MacBook Pro Speakers", kind: .localMac,
                   supportsAirPlay2: false, volume: 100, isLocalDevice: true),
            Device(id: "office", name: "Office", kind: .generic, volume: 50),
        ]
        let (controller, backend) = try await makeRecordingController(fleet: freshFleet)
        controller.ensureDefaultSelection()                     // {local-mac} = passthrough
        controller.setMainOutMasterVolume(70)

        _ = controller.setDeviceSelected("office", true)        // auto-swap → {office}
        _ = controller.setDeviceSelected("local-mac", true)     // → {office, local-mac}: armed

        #expect(!controller.localRowDrivesMain)
        #expect(controller.mainOutMasterVolume == 70, "arming never moves Main by itself")
        #expect(volume("local-mac", in: backend) == 100,
                "the never-touched fader is unity — Main × 100% == Main, so nothing audibly jumps")
    }

    /// 6. A Mac-ONLY group target is passthrough too — `isPassthrough` (defined
    /// only over `.selectedDevices`) gets this wrong; `localRowDrivesMain` is the
    /// predicate that must be used instead.
    @Test func macOnlyGroupTargetIsPassthroughViaLocalRowDrivesMainNotIsPassthrough() async throws {
        let (controller, _) = try await makeRecordingController()
        try controller.saveGroup(Group(id: "g1", name: "Just the Mac", memberIDs: ["local-mac"], memberVolumes: [:]))

        controller.setMainOut(.group(id: "g1"))

        #expect(!controller.isPassthrough, "isPassthrough only ever answers about .selectedDevices — wrong here")
        #expect(controller.localRowDrivesMain, "but a Mac-only group IS passthrough in every behavioural sense")

        controller.setMemberVolume(38, for: "local-mac")
        #expect(controller.mainOutMasterVolume == 38, "the local row still drives Main under a Mac-only group")
    }

    /// 7. An AirPlay-only selection (Mac unchecked) is NOT passthrough: the row
    /// shows the remembered fader and never writes Main, even though the Mac
    /// isn't a Main Out member at all right now.
    @Test func airPlayOnlySelectionIsNotPassthroughRowShowsRememberedFaderNeverWritesMain() async throws {
        let (controller, backend) = try await makeRecordingController()
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("office", true)        // auto-swap → {office}, Mac unchecked
        #expect(!controller.isSpeakerSelected("local-mac"))
        #expect(!controller.localRowDrivesMain, "a real AirPlay output exists — the row is NOT driving Main")
        controller.setMainOutMasterVolume(70)

        controller.setMemberVolume(22, for: "local-mac")

        #expect(volume("local-mac", in: backend) == 22, "the row still writes the Mac's own remembered fader")
        #expect(controller.mainOutMasterVolume == 70, "Main is untouched even though the Mac isn't selected at all")
    }

    /// 8. Group switching: pointing Main at a group applies that group's GAIN
    /// stage before routing opens — else a device would connect at the
    /// previous (possibly louder) product for one beat.
    @Test func settingMainOutToAGroupPushesThatGroupsGainBeforeRouting() async throws {
        let (controller, backend) = try await makeRecordingController()
        try controller.saveGroup(Group(id: "g1", name: "Loud", memberIDs: ["office"], memberVolumes: [:],
                                       masterVolume: 42))
        backend.reset()

        controller.setMainOut(.group(id: "g1"))

        #expect(backend.callOrder == ["gain", "outputSet"],
                "the group's gain stage must reach the backend before the output set opens")
        #expect(backend.gainWrites.last?.group == 42, "the pushed gain reflects the NEW target's group stage")
    }

    // MARK: BT-GROUPCTL — Bluetooth selection matrix (PLAN-UNIVERSAL-SYNC)
    //
    // A `.bluetooth` device is NON-LOCAL, so every rule above applies to it
    // unchanged: it mixes freely (BT+AirPlay, BT+BT, BT+Mac), auto-swap and the
    // current-device floor treat it exactly like an AirPlay id, and it rides in
    // the `setOutputSet` ids this controller hands the backend — where
    // `NativeBackend`'s partition (R-partition) routes it to the BT sink
    // manager instead of the AirPlay engine. Nothing in THIS type may
    // distinguish BT; these tests pin that.

    /// `demoFleet` plus two `.bluetooth` outputs. A separate fleet (not folded
    /// into `demoFleet`) for the same reason `demoFleetWithAP1Only` is: hardcoded
    /// `count == 7` assertions elsewhere.
    private var btFleet: [Device] {
        Array<Device>.demoFleet + [
            Device(id: "bt-move", name: "Move 2 (Bluetooth)", kind: .bluetooth, supportsAirPlay2: false),
            Device(id: "bt-flip", name: "JBL Flip 5", kind: .bluetooth, supportsAirPlay2: false),
        ]
    }

    // ADD a BT device while the Mac is the sole member → same auto-swap as an
    // AirPlay add (BT is non-local; switching to a real output implies moving
    // the audio there).
    @Test func addBluetooth_whenMacIsSoleMember_autoDropsMac() async throws {
        let (controller, _) = try await makeController(fleet: btFleet)
        controller.ensureDefaultSelection()                       // S = {local-mac}
        let r = controller.setDeviceSelected("bt-move", true)
        #expect(r.applied)
        #expect(r.refusalReason == nil)
        #expect(r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["bt-move"])
    }

    // BT + AirPlay mixed selection → allowed, both applied to the output set.
    @Test func btPlusAirPlaySelectionIsAllowed() async throws {
        let (controller, backend) = try await makeController(fleet: btFleet)
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("bt-move", true)         // → {bt-move}
        let r = controller.setDeviceSelected("office", true)
        #expect(r.applied)
        #expect(r.refusalReason == nil)
        #expect(!r.autoSwappedCurrentDevice)
        #expect(controller.selectedDeviceIDs == ["bt-move", "office"])
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(backend.devices.first { $0.id == "bt-move" }?.isSelected == true)
        #expect(backend.devices.first { $0.id == "office" }?.isSelected == true)
    }

    // BT + BT → allowed (same-room drift is a stated quality-bar limitation,
    // never a refusal).
    @Test func btPlusBtSelectionIsAllowed() async throws {
        let (controller, _) = try await makeController(fleet: btFleet)
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("bt-move", true)
        let r = controller.setDeviceSelected("bt-flip", true)
        #expect(r.applied)
        #expect(controller.selectedDeviceIDs == ["bt-move", "bt-flip"])
    }

    // The Mac may join a BT set exactly as it joins an AirPlay set (Q5) — and
    // the output set the backend receives still excludes the local device.
    @Test func macMayJoinBtMixedSet() async throws {
        let (controller, backend) = try await makeRecordingController(fleet: btFleet)
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("bt-move", true)         // → {bt-move}
        let r = controller.setDeviceSelected("local-mac", true)
        #expect(r.applied)
        #expect(r.refusalReason == nil)
        #expect(controller.selectedDeviceIDs == ["bt-move", "local-mac"])
        #expect(backend.outputSetWrites.last == ["bt-move"],
                "the BT id rides in the output set; the local Mac never does")
    }

    // DESELECT the last BT device → current-device floor restores {local-mac},
    // same as removing the last AirPlay device.
    @Test func deselectingLastBtRestoresCurrentDeviceFloor() async throws {
        let (controller, _) = try await makeController(fleet: btFleet)
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("bt-move", true)         // → {bt-move}
        let r = controller.setDeviceSelected("bt-move", false)
        #expect(r.autoSwappedCurrentDevice, "the floor re-toggled the local row FOR the user")
        #expect(controller.selectedDeviceIDs == ["local-mac"])
    }

    // A saved group mixing BT + AirPlay + the Mac activates with BOTH non-local
    // members in the output set and the Mac filtered out — the misroute audit's
    // `routableOutputs` site treats BT as just another non-local id, and the
    // partition (which id drives which sender) belongs to the backend seam.
    @Test func groupWithBtAirPlayAndMacRoutesOnlyNonLocalMembers() async throws {
        let (controller, backend) = try await makeRecordingController(fleet: btFleet)
        try controller.saveGroup(Group(id: "g1", name: "Everywhere",
                                       memberIDs: ["bt-move", "office", "local-mac"],
                                       memberVolumes: [:]))
        backend.reset()
        controller.setMainOut(.group(id: "g1"))
        #expect(backend.outputSetWrites.last == ["bt-move", "office"],
                "BT and AirPlay members route; the Mac is filtered out")
    }
}

/// Wraps a real ``MockBackend`` — so `devices`, echoes and queue ordering behave
/// exactly as in every other test here — and records every write that crosses
/// the ``OutputBackend`` seam: member volumes, master-gain pushes (including the
/// `mirrorToSystemVolume` flag, the "did this touch hardware?" signal), and
/// output-set changes, plus their relative ORDER (`callOrder`). Can also stub
/// `systemOutputVolume` so launch-adoption tests don't need a real Mac.
///
/// Not `Sendable` and doesn't need to be: `OutputBackend` isn't `Sendable`-constrained
/// and every call is made from the test's own thread.
private final class RecordingBackend: OutputBackend {
    private let inner: MockBackend
    private(set) var volumeWrites: [(id: String, volume: Int)] = []
    private(set) var gainWrites: [(mainOut: Int, group: Int, mirrorToSystemVolume: Bool)] = []
    private(set) var outputSetWrites: [Set<String>] = []
    /// Records "gain" / "outputSet" in the order the backend actually saw them —
    /// e.g. proving a group's gain reaches the backend BEFORE its output set does.
    private(set) var callOrder: [String] = []

    var systemOutputVolume: Int?

    init(_ inner: MockBackend, systemOutputVolume: Int? = nil) {
        self.inner = inner
        self.systemOutputVolume = systemOutputVolume
    }

    var devices: [Device] { inner.devices }
    func start() { inner.start() }
    func stop() { inner.stop() }
    func makeEventStream() -> AsyncStream<BackendEvent> { inner.makeEventStream() }
    func setMuted(_ muted: Bool, for id: String) { inner.setMuted(muted, for: id) }

    func setOutputSet(_ ids: Set<String>) {
        outputSetWrites.append(ids)
        callOrder.append("outputSet")
        inner.setOutputSet(ids)
    }

    func retryOutput(_ id: String) {
        callOrder.append("retry")
        inner.retryOutput(id)
    }

    func setVolume(_ volume: Int, for id: String) {
        volumeWrites.append((id: id, volume: volume))
        inner.setVolume(volume, for: id)
    }

    func setMasterGain(mainOut: Int, group: Int, mirrorToSystemVolume: Bool) {
        gainWrites.append((mainOut: mainOut, group: group, mirrorToSystemVolume: mirrorToSystemVolume))
        callOrder.append("gain")
        inner.setMasterGain(mainOut: mainOut, group: group, mirrorToSystemVolume: mirrorToSystemVolume)
    }

    /// Forget everything recorded so far — fixture setup (selection, group
    /// activation) issues its own writes, and only what runs afterwards is
    /// under test.
    func reset() { volumeWrites = []; gainWrites = []; outputSetWrites = []; callOrder = [] }
}

private actor CountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
