import XCTest
@testable import AudiouterCore

final class GroupControllerTests: XCTestCase {

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
        let expectation = expectation(description: "fleet discovered")
        let box = CountBox()
        let task = Task {
            for await event in stream {
                if case .deviceAdded = event, await box.increment() >= fleet.count {
                    expectation.fulfill(); break
                }
            }
        }
        backend.start()
        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()
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
        let controller = GroupController(backend: backend, store: store, loadPersisted: false)
        return (controller, backend)
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return url
    }

    private func volume(_ id: String, in backend: MockBackend) -> Int? {
        backend.devices.first { $0.id == id }?.volume
    }

    // MARK: Selected Devices + Main Out routing (SPEC §9 2026-07-14b)

    func testSetDeviceSelectedComposesSetWithoutRoutingUnderGroupTarget() async throws {
        let (controller, backend) = try await makeController()
        // Point Main Out at a group so composing must not re-route.
        try controller.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["sonos-move"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = Set(backend.devices.filter(\.isSelected).map(\.id))

        _ = controller.setDeviceSelected("office", true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(controller.isSpeakerSelected("office"), "the set was composed")
        XCTAssertEqual(Set(backend.devices.filter(\.isSelected).map(\.id)), before,
                       "composing didn't re-route (target is a group)")
    }

    func testSetDeviceSelectedLiveAppliesUnderSelectedDevicesTarget() async throws {
        let (controller, backend) = try await makeController()
        controller.setMainOut(.selectedDevices)
        _ = controller.setDeviceSelected("office", true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(backend.devices.first { $0.id == "office" }?.isSelected == true,
                      "composing live-applies when Main Out targets Selected Devices")
        _ = controller.setDeviceSelected("office", false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(backend.devices.first { $0.id == "office" }?.isSelected == true)
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
        XCTFail("timed out waiting for \(id)'s connection state")
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
    func testRetryConnectionForSelectedDeviceReconnectsWithoutTouchingMembership() async throws {
        let backend = try await makeBackend(connectScripts: ["office": ConnectScript(attempts: [
            .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
            .connect(after: 0.05),
        ])])
        let (controller, _) = try await makeController(injectedBackend: backend)
        controller.setMainOut(.selectedDevices)

        _ = controller.setDeviceSelected("office", true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        XCTAssertTrue(controller.isSpeakerSelected("office"), "R12: still selected despite the failure")

        _ = controller.retryConnection(for: "office")
        XCTAssertTrue(controller.isSpeakerSelected("office"), "retry never touches membership")
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        XCTAssertTrue(controller.isSpeakerSelected("office"))
    }

    /// R12/W2-T3 — `retryConnection(for:)`, the active-GROUP branch: a group
    /// member that fails is never dropped from the group (group membership was
    /// never touched by connection state to begin with), so retry must
    /// re-activate the group rather than mistake this for a Selected-Devices
    /// id. Confirms Groups and Selected Devices behave identically for retry.
    func testRetryConnectionForActiveGroupMemberReconnectsWithoutTouchingMembership() async throws {
        let backend = try await makeBackend(connectScripts: ["office": ConnectScript(attempts: [
            .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
            .connect(after: 0.05),
        ])])
        let (controller, _) = try await makeController(injectedBackend: backend)
        try controller.saveGroup(Group(id: "g1", name: "Office Pair", memberIDs: ["office"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))

        try await waitForConnectionState(backend, id: "office", isFailed)
        XCTAssertEqual(controller.activeGroupID, "g1", "still the active group despite the failure")
        XCTAssertFalse(controller.isSpeakerSelected("office"),
                       "a pure group member is never in the ad-hoc Selected-Devices set")

        _ = controller.retryConnection(for: "office")
        XCTAssertEqual(controller.activeGroupID, "g1", "retry never touches group membership/activation")
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        XCTAssertEqual(controller.activeGroupID, "g1")
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
    func testRetryConnectionForDeviceInBothSelectedDevicesAndActiveGroupUsesGroupRouting() async throws {
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
        XCTAssertTrue(controller.isSpeakerSelected("office"), "now also in Selected Devices (independent set)")
        XCTAssertEqual(controller.activeGroupID, "g1", "Main Out is still the group — this is what's actually routing")
        XCTAssertTrue(isFailed(backend.devices.first { $0.id == "office" }!.connectionState),
                      "still failed — composing membership must not have re-kicked anything yet")

        // The retry button is the only thing left that can consume attempt #2
        // (`.connect`). Under the pre-fix branch order this call is a dead
        // no-op (matches `selectedDeviceIDs` first, sees `mainOut != .selectedDevices`,
        // never calls `applyRouting()`) and this assertion times out.
        _ = controller.retryConnection(for: "office")
        XCTAssertTrue(controller.isSpeakerSelected("office"), "retry never touches Selected-Devices membership")
        XCTAssertEqual(controller.activeGroupID, "g1", "retry never touches group membership/activation")
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        XCTAssertEqual(controller.activeGroupID, "g1")
    }

    func testDefaultSelectionIsLocalPassthrough() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()
        XCTAssertEqual(controller.selectedDeviceIDs, ["local-mac"])
        XCTAssertEqual(controller.mainOut, .selectedDevices)
        XCTAssertTrue(controller.isPassthrough, "default = current device only ⇒ passthrough")
    }

    func testAutoSwapDropsLocalWhenSoleMember() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // set = {local}
        let r = controller.setDeviceSelected("office", true)
        XCTAssertTrue(r.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["office"], "local dropped, AirPlay added")
    }

    /// REVERSE auto-swap (ahh, live session 2026-07-17b): removing the LAST
    /// AirPlay device must restore the local passthrough default, not leave the
    /// set empty — an empty set renders as a zeroed Main Out master and gives the
    /// volume keys nothing to visibly drive.
    func testReverseAutoSwapRestoresLocalWhenLastAirPlayRemoved() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // {local}
        _ = controller.setDeviceSelected("office", true)          // auto-swap: {office}
        let r = controller.setDeviceSelected("office", false)
        XCTAssertTrue(r.autoSwappedCurrentDevice, "the restore is surfaced like the forward swap")
        XCTAssertEqual(controller.selectedDeviceIDs, ["local-mac"], "back to the passthrough default")
        XCTAssertTrue(controller.isPassthrough)
    }

    func testReverseAutoSwapDoesNotFireWhileAnotherAirPlayRemains() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)
        _ = controller.setDeviceSelected("homepod-bed", true)
        let r = controller.setDeviceSelected("office", false)
        XCTAssertFalse(r.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["homepod-bed"], "the remaining speaker keeps the set")
    }

    /// Toggling the LOCAL device itself off is a deliberate act on that row, not a
    /// disconnect — the restore must not fire (it would make the toggle a no-op).
    func testDeselectingLocalItselfDoesNotSelfRestore() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // {local}
        let r = controller.setDeviceSelected("local-mac", false)
        XCTAssertFalse(r.autoSwappedCurrentDevice)
        XCTAssertTrue(controller.selectedDeviceIDs.isEmpty)
    }

    /// THE SYMPTOM: the Main Out master must track the Mac's own volume after the
    /// last AirPlay device disconnects — not slam to 0 (the empty-set average).
    func testMainOutMasterTracksLocalAfterLastAirPlayRemoved() async throws {
        let (controller, _) = try await makeController(fleet: [
            Device(id: "local-mac", name: "MacBook Pro Speakers", kind: .localMac,
                   supportsAirPlay2: false, volume: 65, isLocalDevice: true),
            Device(id: "office", name: "Office", kind: .sonos, volume: 40),
        ])
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("office", true)          // streaming: master = 40
        XCTAssertEqual(controller.mainOutMasterVolume, 40)

        _ = controller.setDeviceSelected("office", false)         // disconnect
        XCTAssertEqual(controller.mainOutMasterVolume, 65,
                       "the master shows the Mac (what is actually playing), not a zeroed empty set")
    }

    func testAutoSwapDoesNotFireWhenLocalNotSoleMember() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)          // no local at all
        let r = controller.setDeviceSelected("homepod-bed", true)
        XCTAssertFalse(r.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["office", "homepod-bed"])
    }

    // MARK: Q5 / T-GROUPCTL — synced local sink: the Mac may join a mixed set.
    // Exhaustive transition matrix. S = selectedDeviceIDs BEFORE the change;
    // L = "local-mac"; A = an AirPlay/non-local id. Default S from
    // ensureDefaultSelection()/makeController is {L}.

    // --- ADD an AirPlay device A ---

    // ADD A, S == {L} (Mac sole member) → auto-drop L, insert A ⇒ {A}, autoSwapped.
    // (Also covered by testAutoSwapDropsLocalWhenSoleMember; asserted here as the
    // canonical first row of the matrix.)
    func testAddAirPlay_whenMacIsSoleMember_autoDropsMac() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        XCTAssertEqual(controller.selectedDeviceIDs, ["local-mac"])
        let r = controller.setDeviceSelected("office", true)
        XCTAssertTrue(r.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["office"], "Mac dropped, AirPlay in")
    }

    // ADD A, S already mixed {L, A1} → NO drop, insert A2 ⇒ {L, A1, A2}, Mac stays.
    // This is the newly-reachable mixed state; the substance of Q5.
    func testAddAirPlay_whenMacAlreadyMixed_macStaysNoDrop() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        // Reach the mixed set {local-mac, office} by adding the Mac back in.
        _ = controller.setDeviceSelected("office", true)          // auto-swap → {office}
        let addMac = controller.setDeviceSelected("local-mac", true)
        XCTAssertTrue(addMac.applied)
        XCTAssertFalse(addMac.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["office", "local-mac"], "mixed set reached")

        // Now add a SECOND AirPlay device — the Mac must NOT be dropped.
        let r = controller.setDeviceSelected("homepod-bed", true)
        XCTAssertTrue(r.applied)
        XCTAssertFalse(r.autoSwappedCurrentDevice, "auto-swap fires only when Mac is sole member")
        XCTAssertEqual(controller.selectedDeviceIDs,
                       ["office", "local-mac", "homepod-bed"],
                       "Mac stays in the mixed set")
    }

    // ADD A, S contains only AirPlay device(s) → plain insert, no drop.
    func testAddAirPlay_whenAirPlayOnly_plainInsert() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office} (Mac auto-dropped)
        let r = controller.setDeviceSelected("homepod-bed", true)
        XCTAssertTrue(r.applied)
        XCTAssertFalse(r.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["office", "homepod-bed"])
    }

    // ADD A, S empty → plain insert, no drop.
    func testAddAirPlay_whenSelectionEmpty_plainInsert() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("local-mac", false)      // → {} (deliberate Mac-off)
        XCTAssertTrue(controller.selectedDeviceIDs.isEmpty)
        let r = controller.setDeviceSelected("office", true)
        XCTAssertTrue(r.applied)
        XCTAssertFalse(r.autoSwappedCurrentDevice, "no sole Mac member ⇒ no auto-swap")
        XCTAssertEqual(controller.selectedDeviceIDs, ["office"])
    }

    // --- ADD the local device L (refusal lifted) ---

    // ADD L into an AirPlay-only set → allowed now, drops nothing ⇒ S ∪ {L}.
    // (Previously refused; supersedes testLocalMixBlockRefusesWithReason.)
    func testAddLocal_intoAirPlaySet_isAllowedAndMixes() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office}
        XCTAssertTrue(controller.canSelectLocalSpeaker("local-mac"),
                      "the Mac is selectable into a mixed set now")
        let r = controller.setDeviceSelected("local-mac", true)
        XCTAssertTrue(r.applied)
        XCTAssertNil(r.refusalReason)
        XCTAssertFalse(r.autoSwappedCurrentDevice, "adding the Mac never drops anything")
        XCTAssertEqual(controller.selectedDeviceIDs, ["office", "local-mac"])
    }

    // ADD L into a multi-AirPlay set → allowed, no drop ⇒ all three present.
    func testAddLocal_intoMultiAirPlaySet_isAllowed() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)          // → {office}
        _ = controller.setDeviceSelected("homepod-bed", true)     // → {office, homepod-bed}
        let r = controller.setDeviceSelected("local-mac", true)
        XCTAssertTrue(r.applied)
        XCTAssertFalse(r.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["office", "homepod-bed", "local-mac"])
    }

    // ADD L when already present (mixed set) → no-op .ok, set unchanged.
    func testAddLocal_whenAlreadyMixed_isNoOp() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)
        _ = controller.setDeviceSelected("local-mac", true)       // → {office, local-mac}
        let r = controller.setDeviceSelected("local-mac", true)
        XCTAssertTrue(r.applied)
        XCTAssertFalse(r.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["office", "local-mac"])
    }

    // canSelectLocalSpeaker is unconditionally true (block lifted), in every state.
    func testCanSelectLocalSpeakerAlwaysTrue() async throws {
        let (controller, _) = try await makeController()
        XCTAssertTrue(controller.canSelectLocalSpeaker("local-mac"))      // S == {L}
        _ = controller.setDeviceSelected("office", true)                 // S == {office}
        XCTAssertTrue(controller.canSelectLocalSpeaker("local-mac"),
                      "the pre-engine local-mix block is gone")
        _ = controller.setDeviceSelected("local-mac", true)              // S == {office, local-mac}
        XCTAssertTrue(controller.canSelectLocalSpeaker("local-mac"))
    }

    // --- REMOVE: current-device floor + subsumed reverse auto-swap ---

    // REMOVE the last AirPlay from a MIXED set {L, A} → naturally leaves {L}; the
    // floor is SUBSUMED (does NOT fire, autoSwapped=false), the Mac just stays.
    func testRemoveLastAirPlay_fromMixedSet_leavesMacNoReverseSwap() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office}
        _ = controller.setDeviceSelected("local-mac", true)       // → {office, local-mac} (mixed)
        let r = controller.setDeviceSelected("office", false)     // remove the only AirPlay
        XCTAssertTrue(r.applied)
        XCTAssertFalse(r.autoSwappedCurrentDevice,
                       "floor is subsumed — Mac was already present, no restore needed")
        XCTAssertEqual(controller.selectedDeviceIDs, ["local-mac"])
    }

    // REMOVE one AirPlay from {L, A1, A2} → {L, A2}; floor does not fire.
    func testRemoveOneAirPlay_fromMixedMultiSet_keepsRest() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)          // → {office}
        _ = controller.setDeviceSelected("homepod-bed", true)     // → {office, homepod-bed}
        _ = controller.setDeviceSelected("local-mac", true)       // → {office, homepod-bed, local-mac}
        let r = controller.setDeviceSelected("office", false)
        XCTAssertTrue(r.applied)
        XCTAssertFalse(r.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["homepod-bed", "local-mac"])
    }

    // REMOVE the Mac from a MIXED set {L, A} → deliberate; leaves {A}, no floor.
    func testRemoveMac_fromMixedSet_leavesAirPlayOnly() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office}
        _ = controller.setDeviceSelected("local-mac", true)       // → {office, local-mac}
        let r = controller.setDeviceSelected("local-mac", false)
        XCTAssertTrue(r.applied)
        XCTAssertFalse(r.autoSwappedCurrentDevice,
                       "removing the Mac itself is deliberate, never re-restored")
        XCTAssertEqual(controller.selectedDeviceIDs, ["office"])
    }

    // REMOVE the last AirPlay from an AirPlay-ONLY set {A} → floor restores {L}.
    // (Also covered by testReverseAutoSwapRestoresLocalWhenLastAirPlayRemoved;
    // kept here to complete the matrix — this is the one remove case that floors.)
    func testRemoveLastAirPlay_fromAirPlayOnlySet_floorsToMac() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()                       // S = {local-mac}
        _ = controller.setDeviceSelected("office", true)          // → {office} (Mac auto-dropped)
        let r = controller.setDeviceSelected("office", false)
        XCTAssertTrue(r.applied)
        XCTAssertTrue(r.autoSwappedCurrentDevice, "empty result floors back to {local}")
        XCTAssertEqual(controller.selectedDeviceIDs, ["local-mac"])
    }

    func testPassthroughDerivedOnlyForLocalOnlySet() async throws {
        let (controller, _) = try await makeController()
        controller.ensureDefaultSelection()
        XCTAssertTrue(controller.isPassthrough)
        _ = controller.setDeviceSelected("office", true)          // auto-swaps local out
        XCTAssertFalse(controller.isPassthrough, "AirPlay-only set is not passthrough")
    }

    func testSetMainOutGroupRoutesToMembers() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Pair",
                                        memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.activeGroupID, "g1")
        XCTAssertEqual(Set(backend.devices.filter(\.isSelected).map(\.id)), ["sonos-move", "office"])
    }

    // MARK: Activation

    func testActivateGroupSetsOutputSetToExactlyItsMembers() async throws {
        let (controller, backend) = try await makeController()
        let group = Group(id: "g1", name: "Downstairs", memberIDs: ["sonos-move", "office"], memberVolumes: [:])
        try controller.saveGroup(group)

        controller.activateGroup(id: "g1")
        try await Task.sleep(nanoseconds: 200_000_000)

        let selected = Set(backend.devices.filter(\.isSelected).map(\.id))
        XCTAssertEqual(selected, ["sonos-move", "office"])
        XCTAssertEqual(controller.activeGroupID, "g1")
    }

    func testActivateGroupAppliesRememberedVolumes() async throws {
        let (controller, backend) = try await makeController()
        let group = Group(
            id: "g1", name: "Downstairs",
            memberIDs: ["sonos-move", "office"],
            memberVolumes: ["sonos-move": 77, "office": 12]
        )
        try controller.saveGroup(group)

        controller.activateGroup(id: "g1")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(volume("sonos-move", in: backend), 77)
        XCTAssertEqual(volume("office", in: backend), 12)
    }

    func testDeactivateGroupClearsActiveIDWithoutChangingOutputSet() async throws {
        let (controller, backend) = try await makeController()
        let group = Group(id: "g1", name: "Downstairs", memberIDs: ["sonos-move"], memberVolumes: [:])
        try controller.saveGroup(group)
        controller.activateGroup(id: "g1")
        try await Task.sleep(nanoseconds: 100_000_000)

        controller.deactivateGroup()
        XCTAssertNil(controller.activeGroupID)

        let selected = Set(backend.devices.filter(\.isSelected).map(\.id))
        XCTAssertEqual(selected, ["sonos-move"], "deactivating must not itself change the output set")
    }

    func testSaveCurrentSetupAsGroupCapturesSelectedDevicesAndVolumes() async throws {
        let (controller, backend) = try await makeController()
        // Compose the Selected Devices set (SPEC §9b — save = save the set).
        _ = controller.setDeviceSelected("sonos-move", true)
        _ = controller.setDeviceSelected("homepod-bed", true)
        backend.setVolume(33, for: "sonos-move")
        backend.setVolume(81, for: "homepod-bed")
        try await Task.sleep(nanoseconds: 200_000_000)

        let group = try controller.saveCurrentSetupAsGroup(name: "Party", id: "party").group

        XCTAssertEqual(Set(group.memberIDs), ["sonos-move", "homepod-bed"])
        XCTAssertEqual(group.memberVolumes["sonos-move"], 33)
        XCTAssertEqual(group.memberVolumes["homepod-bed"], 81)
        XCTAssertTrue(controller.groups.contains { $0.id == "party" })
    }

    // MARK: Dedup / group identity (SPEC.md §9)

    func testMemberSetMatchIsOrderIndependent() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Downstairs",
                                        memberIDs: ["office", "sonos-move"], memberVolumes: [:]))
        // Same set, different order → same group.
        XCTAssertEqual(controller.group(matchingMemberSet: ["sonos-move", "office"])?.id, "g1")
        XCTAssertEqual(controller.group(matchingMemberSet: ["office", "sonos-move"])?.id, "g1")
        // Different set → no match; empty set → no match.
        XCTAssertNil(controller.group(matchingMemberSet: ["office"]))
        XCTAssertNil(controller.group(matchingMemberSet: ["office", "sonos-move", "homepod-bed"]))
        XCTAssertNil(controller.group(matchingMemberSet: []))
    }

    func testSaveCurrentSetupWithDuplicateSetDoesNotCreateSecondGroup() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("sonos-move", true)
        _ = controller.setDeviceSelected("office", true)
        try await Task.sleep(nanoseconds: 200_000_000)

        let first = try controller.saveCurrentSetupAsGroup(name: "Group 1")
        XCTAssertFalse(first.alreadyExisted)
        XCTAssertEqual(controller.groups.count, 1)

        // Same Selected Devices set → must resolve to the existing group, not a copy.
        let second = try controller.saveCurrentSetupAsGroup(name: "Group 2")
        XCTAssertTrue(second.alreadyExisted, "identical member set signals already-exists")
        XCTAssertEqual(second.group.id, first.group.id)
        XCTAssertEqual(controller.groups.count, 1, "no duplicate group created")
    }

    func testCreateGroupDedupsByMemberSet() async throws {
        let (controller, _) = try await makeController()
        let a = try controller.createGroup(name: "Downstairs", memberIDs: ["office", "sonos-move"])
        XCTAssertFalse(a.alreadyExisted)
        // Same members in a different order → resolves to the same group.
        let b = try controller.createGroup(name: "Different Name", memberIDs: ["sonos-move", "office"])
        XCTAssertTrue(b.alreadyExisted)
        XCTAssertEqual(b.group.id, a.group.id)
        XCTAssertEqual(controller.groups.count, 1)
    }

    // MARK: Empty-membership invariant (a group must keep ≥1 device)

    func testCreateGroupWithNoMembersIsRejected() async throws {
        let (controller, _) = try await makeController()
        XCTAssertThrowsError(try controller.createGroup(name: "Empty", memberIDs: [])) { error in
            XCTAssertEqual(error as? GroupController.GroupError, .emptyMembership)
        }
        XCTAssertTrue(controller.groups.isEmpty, "no empty group should have been persisted")
    }

    func testSaveGroupWithNoMembersIsRejectedAndLeavesGroupsUntouched() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office"], memberVolumes: [:]))

        // Attempting to save the same group emptied out must throw AND must not
        // mutate the persisted group (the guard runs before any mutation).
        XCTAssertThrowsError(
            try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: [], memberVolumes: [:]))
        ) { error in
            XCTAssertEqual(error as? GroupController.GroupError, .emptyMembership)
        }
        XCTAssertEqual(controller.groups.first(where: { $0.id == "g1" })?.memberIDs, ["office"],
                       "the rejected empty save must leave the existing group intact")
    }

    func testSaveCurrentSetupAsGroupWithEmptySelectionIsRejected() async throws {
        let (controller, _) = try await makeController()
        // Default selection is {local}; clear it so the selected set is empty.
        for id in controller.selectedDeviceIDs { _ = controller.setDeviceSelected(id, false) }
        // Reverse auto-swap may reseed {local}; force truly empty by removing again.
        for id in controller.selectedDeviceIDs { _ = controller.setDeviceSelected(id, false) }
        guard controller.selectedDeviceIDs.isEmpty else {
            throw XCTSkip("could not reach an empty selection on this fleet")
        }
        XCTAssertThrowsError(try controller.saveCurrentSetupAsGroup(name: "Nothing")) { error in
            XCTAssertEqual(error as? GroupController.GroupError, .emptyMembership)
        }
    }

    func testActiveGroupTracksMainOutGroupTarget() async throws {
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
        XCTAssertEqual(controller.syncActiveGroupToSelection(), "g1")
        XCTAssertEqual(controller.activeGroupID, "g1")

        // Main Out back at Selected Devices → no active group even if the output
        // set coincidentally equals the group.
        controller.setMainOut(.selectedDevices)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(controller.syncActiveGroupToSelection())
        XCTAssertNil(controller.activeGroupID)
    }

    func testDeleteGroupDeactivatesIfActive() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")

        try controller.deleteGroup(id: "g1")

        XCTAssertNil(controller.activeGroupID)
        XCTAssertFalse(controller.groups.contains { $0.id == "g1" })
    }

    // MARK: Proportional master — ratio preservation

    func testMasterVolumeIsAverageOfMembers() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(20, for: "sonos-move")
        backend.setVolume(60, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(controller.masterVolume, 40)
    }

    func testProportionalDragPreservesRelativeBalance() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(20, for: "sonos-move")   // ratio 0.5 of master(40)
        backend.setVolume(60, for: "office")       // ratio 1.5 of master(40)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.masterVolume, 40)

        controller.beginMasterDrag()
        controller.setMasterVolume(80)
        try await Task.sleep(nanoseconds: 200_000_000)
        controller.endMasterDrag()

        // Ratios (0.5x / 1.5x of the master at drag start) should be preserved.
        XCTAssertEqual(volume("sonos-move", in: backend), 40)
        XCTAssertEqual(volume("office", in: backend), 100, "1.5x of 80 clamps at 100")
    }

    func testMemberAtMaxStaysClampedAcrossDragThenTracksAgainOnNextDrag() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(50, for: "sonos-move")   // ratio 1.0
        backend.setVolume(50, for: "office")       // ratio 1.0
        try await Task.sleep(nanoseconds: 200_000_000)

        controller.beginMasterDrag()
        controller.setMasterVolume(100)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(volume("sonos-move", in: backend), 100)
        XCTAssertEqual(volume("office", in: backend), 100)

        // Still within the same drag: pushing master back down un-clamps
        // using the *original* drag-start ratio (1.0), not a re-derived one.
        controller.setMasterVolume(60)
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.endMasterDrag()
        XCTAssertEqual(volume("sonos-move", in: backend), 60)
        XCTAssertEqual(volume("office", in: backend), 60)
    }

    func testMasterDragFromZeroMovesEveryoneTogether() async throws {
        // A zero master has no meaningful ratio; document/verify the fallback:
        // every member is treated as ratio 1.0 (moves 1:1 with the master).
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(0, for: "sonos-move")
        backend.setVolume(0, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.masterVolume, 0)

        controller.beginMasterDrag()
        controller.setMasterVolume(30)
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.endMasterDrag()

        XCTAssertEqual(volume("sonos-move", in: backend), 30)
        XCTAssertEqual(volume("office", in: backend), 30)
    }

    func testMasterEchoesMemberAverageAfterIndividualChange() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(10, for: "sonos-move")
        backend.setVolume(10, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.masterVolume, 10)

        controller.setMemberVolume(90, for: "office")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.masterVolume, 50, "master should read back as the members' average")
    }

    // MARK: Mute (solo removed 2026-07-13)

    func testMuteStoresPriorVolumeAndZeroes() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(65, for: "sonos-move")
        try await Task.sleep(nanoseconds: 200_000_000)

        controller.setMuted(true, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(volume("sonos-move", in: backend), 0)
        XCTAssertTrue(controller.isMuted("sonos-move"))

        controller.setMuted(false, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(volume("sonos-move", in: backend), 65, "unmute restores the pre-mute volume")
        XCTAssertFalse(controller.isMuted("sonos-move"))
    }

    func testReMutingDoesNotOverwriteStashedVolume() async throws {
        // The stash is written only on the silence edge, so a redundant mute of
        // an already-muted member must not overwrite the original level with 0.
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(70, for: "sonos-move")
        try await Task.sleep(nanoseconds: 200_000_000)

        controller.setMuted(true, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(volume("sonos-move", in: backend), 0)

        // Redundant mute (already muted) — must be a no-op, not a re-stash of 0.
        controller.setMuted(true, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)

        controller.setMuted(false, for: "sonos-move")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(volume("sonos-move", in: backend), 70, "unmute restores the original level, not 0")
    }

    // MARK: Persistence round-trip

    func testPersistenceRoundTrip() throws {
        let dir = tempDirectory()
        let store = GroupStore(directory: dir)
        let groups = [
            Group(id: "g1", name: "Whole house", memberIDs: ["a", "b"], memberVolumes: ["a": 10, "b": 90]),
            Group(id: "g2", name: "Downstairs", memberIDs: ["a"], memberVolumes: ["a": 50]),
        ]
        try store.save(groups)

        let reloaded = try GroupStore(directory: dir).load()
        XCTAssertEqual(reloaded, groups)
    }

    func testLoadWithNoFileReturnsEmpty() throws {
        let store = GroupStore(directory: tempDirectory())
        XCTAssertEqual(try store.load(), [])
    }

    func testLoadUnknownFutureSchemaVersionReturnsEmptyRatherThanCrashing() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let future = """
        {"schemaVersion": 999, "groups": [{"id": "g1", "name": "X", "memberIDs": [], "memberVolumes": {}}]}
        """
        try Data(future.utf8).write(to: dir.appendingPathComponent("groups.json"))

        let store = GroupStore(directory: dir)
        XCTAssertEqual(try store.load(), [], "a future schema version must not crash an old build")
    }

    func testLoadCorruptFileThrows() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("groups.json"))

        let store = GroupStore(directory: dir)
        XCTAssertThrowsError(try store.load())
    }

    func testGroupControllerLoadsPersistedGroupsOnInit() async throws {
        let dir = tempDirectory()
        try GroupStore(directory: dir).save([Group(id: "g1", name: "X", memberIDs: ["a"], memberVolumes: [:])])

        let backend = try await makeBackend()
        let controller = GroupController(backend: backend, store: GroupStore(directory: dir), loadPersisted: true)

        XCTAssertEqual(controller.groups.map(\.id), ["g1"])
    }

    // MARK: Routing persistence (SPEC §9b — Selected Devices + Main Out)

    // DECISION (ahh, 2026-07-17): the live Selected-Devices routing set does
    // NOT auto-resume on launch — every launch defaults to {current device} =
    // passthrough. Saved GROUPS still persist and stay re-applyable. This test
    // pins that split: the group loads on session 2, but the previously-selected
    // AirPlay set + group Main Out target do NOT restore — they reset to the
    // local-passthrough default.
    func testGroupsPersistButRoutingResetsToLocalOnLaunch() async throws {
        let dir = tempDirectory()
        let routingStore = RoutingStore(directory: dir)

        // Session 1: compose a set + point Main Out at a group.
        let backend1 = try await makeBackend()
        let c1 = GroupController(backend: backend1, store: GroupStore(directory: dir),
                                 routingStore: routingStore, loadPersisted: true)
        try c1.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office", "sonos-move"], memberVolumes: [:]))
        _ = c1.setDeviceSelected("office", true)
        _ = c1.setDeviceSelected("homepod-bed", true)
        c1.setMainOut(.group(id: "g1"))

        // Session 2: a fresh controller over the same stores. The GROUP is
        // reloaded, but the live routing set is NOT resumed — it resets to the
        // local-passthrough default once the fleet is known.
        let backend2 = try await makeBackend()
        let c2 = GroupController(backend: backend2, store: GroupStore(directory: dir),
                                 routingStore: RoutingStore(directory: dir), loadPersisted: true)
        XCTAssertEqual(c2.groups.map(\.id), ["g1"], "saved group still persists")
        XCTAssertTrue(c2.selectedDeviceIDs.isEmpty,
                      "persisted AirPlay selection is NOT auto-resumed on launch")
        XCTAssertEqual(c2.mainOut, .selectedDevices,
                       "persisted group Main Out target is NOT auto-resumed on launch")
        c2.ensureDefaultSelection()
        XCTAssertEqual(c2.selectedDeviceIDs, ["local-mac"],
                       "launch default = {current device} = passthrough")
        XCTAssertTrue(c2.isPassthrough)
    }

    func testRoutingDefaultWhenNoPersistedState() async throws {
        let backend = try await makeBackend()
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: true)
        // No persisted routing → Main Out defaults to Selected Devices, set empty
        // until ensureDefaultSelection establishes the current-device default.
        XCTAssertEqual(controller.mainOut, .selectedDevices)
        XCTAssertTrue(controller.selectedDeviceIDs.isEmpty)
        controller.ensureDefaultSelection()
        XCTAssertEqual(controller.selectedDeviceIDs, ["local-mac"])
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
    func testSelectedDevicesOutputSetIsExactlySelectedAirPlayMembers() async throws {
        let (controller, backend) = try await makeController()
        _ = controller.setDeviceSelected("office", true)
        controller.setMainOut(.selectedDevices)
        try await Task.sleep(nanoseconds: 200_000_000)

        let outputs = Set(backend.devices.filter(\.isSelected).map(\.id))
        XCTAssertEqual(outputs, ["office"],
                       "output set is exactly Selected Devices — no redirect-target union")
    }

    /// Passthrough (Selected == {local}) reaches the backend as an EMPTY output
    /// set even when app routes exist — the mute bug is gone: a redirect can no
    /// longer force a non-empty output set that opens the capture gate.
    func testPassthroughOutputSetStaysEmpty() async throws {
        let (controller, backend) = try await makeController()
        controller.ensureDefaultSelection()   // seeds {local-mac} = passthrough
        controller.setMainOut(.selectedDevices)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(controller.isPassthrough)
        XCTAssertTrue(backend.devices.filter(\.isSelected).isEmpty,
                      "passthrough output set is empty — no app-route target unioned in")
    }

    /// With Main Out pointed at a group, the output set is EXACTLY the group's
    /// members — app-route targets are not unioned into an active group either.
    func testActivateGroupOutputSetIsExactlyGroupMembers() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["sonos-move"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        try await Task.sleep(nanoseconds: 200_000_000)

        let outputs = Set(backend.devices.filter(\.isSelected).map(\.id))
        XCTAssertEqual(outputs, ["sonos-move"],
                       "active group's output set is exactly its members — no redirect union")
    }

    /// The separate invariant that OUTLIVES the union removal (AGENTS.md): the
    /// Main Out master + its member set are keyed off `selectedDeviceIDs` /
    /// `mainOutMemberIDs`, which never contained redirect targets — so master math
    /// and group identity are unaffected by any app route. Verified here against a
    /// selection that equals a saved group.
    func testGroupIdentityAndMasterKeyOffSelectedDevicesNotOutputSet() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        _ = controller.setDeviceSelected("office", true)
        controller.setMainOut(.selectedDevices)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(controller.isSpeakerSelected("homepod-bed"),
                       "a non-selected device is not in Selected Devices")
        XCTAssertEqual(controller.groupMatchingCurrentSelection?.id, "g1",
                       "group identity keys off selectedDeviceIDs")

        backend.setVolume(80, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.mainOutMasterVolume, 80,
                       "master reflects only Selected members")
    }

    // MARK: System-volume mirror — the volume keys drive what's actually playing
    //
    // The bug (ahh, live session 2026-07-17): the volume keys move the system
    // output = the local "Current Device", but the capture tap mutes that output
    // while streaming — so the keys adjusted a device nobody could hear. The mirror
    // pushes an external system-volume change onto the Main Out master instead.
    //
    // The fixture below fixes the members at 80/40 (a clean 2:1 at master 60) so the
    // proportional assertions are exact rather than approximate.

    /// A local device plus two AirPlay speakers at a clean 2:1 balance.
    private var mirrorFleet: [Device] {
        [
            Device(id: "local-mac", name: "MacBook Pro Speakers", kind: .localMac,
                   supportsAirPlay2: false, volume: 65, isLocalDevice: true),
            Device(id: "loud", name: "Loud Speaker", kind: .sonos, volume: 80),
            Device(id: "quiet", name: "Quiet Speaker", kind: .sonos, volume: 40),
        ]
    }

    /// `mirrorFleet` plus a fourth AirPlay device used only as a redirect target
    /// (never in `selectedDeviceIDs`) — at 40, a clean 2:1 against `loud`'s 80, for
    /// the redirect-mirror tests below.
    private var mirrorFleetWithRedirectTarget: [Device] {
        mirrorFleet + [Device(id: "homepod-bed", name: "Bedroom HomePod", kind: .sonos, volume: 40)]
    }

    /// A controller over a write-recording backend, already streaming to both AirPlay
    /// speakers (selecting the first auto-swaps the local device out, exactly as
    /// toggling a speaker in the popover does).
    private func makeStreamingMirrorController() async throws -> (GroupController, WriteCountingBackend) {
        let mock = try await makeBackend(mirrorFleet)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        controller.ensureDefaultSelection()                    // {local} — passthrough
        _ = controller.setDeviceSelected("loud", true)         // auto-swap drops local
        _ = controller.setDeviceSelected("quiet", true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(controller.isPassthrough, "fixture precondition: streaming, not passthrough")
        XCTAssertEqual(controller.mainOutMasterVolume, 60, "fixture precondition: (80+40)/2")
        spy.reset()
        return (controller, spy)
    }

    /// THE FIX: an external system-volume change while streaming drives the Main Out
    /// master, scaling the AirPlay members proportionally — so the volume keys move
    /// the speakers that are actually playing.
    func testSystemVolumeMirrorDrivesMainOutMasterWhileStreaming() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.mainOutMasterVolume, 30, "the Main Out master follows the system volume")
        XCTAssertEqual(spy.volume(of: "loud"), 40, "80 scaled by 30/60")
        XCTAssertEqual(spy.volume(of: "quiet"), 20, "40 scaled by 30/60 — the 2:1 balance is preserved")
    }

    /// NO FEEDBACK LOOP, structurally: the mirror writes to the AirPlay members and
    /// NOTHING else. The local id is the only one whose `setVolume` reaches the
    /// system volume (`NativeBackend.setVolume`'s `isLocalDevice` branch), so never
    /// writing it means the listener that fired the mirror can never be re-fired by
    /// it. The write count is exactly the member count — one pass, no cascade.
    func testSystemVolumeMirrorIssuesBoundedWritesAndNeverTouchesLocalDevice() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(spy.volumeWrites.count, 2,
                       "exactly one write per Main Out member — a mirrored change must not cascade")
        XCTAssertEqual(Set(spy.volumeWrites.map(\.id)), ["loud", "quiet"])
        XCTAssertTrue(spy.volumeWrites.allSatisfy { $0.id != "local-mac" },
                      "the mirror must NEVER write the local device — that is the whole no-feedback argument")
    }

    /// A whole BURST of volume-key steps still cannot loop: writes stay bounded at
    /// (steps × members), which is only true if each mirrored change produces one
    /// pass and provokes nothing further.
    func testSystemVolumeMirrorBurstStaysBounded() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        let steps = [63, 69, 75, 81, 88, 94, 100]
        for step in steps { controller.mirrorSystemVolumeToMainOut(step) }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spy.volumeWrites.count, steps.count * 2,
                       "a burst of \(steps.count) steps over 2 members must be exactly \(steps.count * 2) writes")
        XCTAssertTrue(spy.volumeWrites.allSatisfy { $0.id != "local-mac" })
    }

    /// PASSTHROUGH: the local device is the sole Main Out member, so mirroring would
    /// be circular — the keys already moved the only thing Main Out names. Nothing
    /// is written at all.
    func testSystemVolumeMirrorDoesNotDriveMasterInPassthrough() async throws {
        let mock = try await makeBackend(mirrorFleet)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        controller.ensureDefaultSelection()
        XCTAssertTrue(controller.isPassthrough, "precondition: set == {local}")
        spy.reset()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(spy.volumeWrites.isEmpty,
                      "passthrough must not drive the Main Out master — no circular write")
        XCTAssertEqual(spy.volume(of: "local-mac"), 65, "the local device's own volume is untouched")
    }

    /// `isPassthrough` is false for EVERY `.group` target — but a group's members can
    /// include the Mac, and `saveCurrentSetupAsGroup` while in passthrough saves
    /// exactly such a group. Pointing Main Out at it must still not mirror: the local
    /// device is the only member, so the volume key already moved it.
    func testSystemVolumeMirrorRefusesGroupWhoseOnlyMemberIsLocalDevice() async throws {
        let mock = try await makeBackend(mirrorFleet)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        controller.ensureDefaultSelection()                    // {local}
        let saved = try controller.saveCurrentSetupAsGroup(name: "Just the Mac")
        controller.setMainOut(.group(id: saved.group.id))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(controller.isPassthrough, "a group target is never passthrough — which is exactly the trap")
        spy.reset()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(spy.volumeWrites.isEmpty,
                      "a group whose member is the Mac must not be mirrored despite !isPassthrough")
    }

    /// The dangerous shape of the same trap: a group MIXING the Mac with an AirPlay
    /// speaker. Here the local ratio isn't 1, so a mirrored keypress would scale the
    /// Mac to a value the user never asked for and yank the system volume out from
    /// under them. The local-member guard refuses the whole mirror.
    func testSystemVolumeMirrorRefusesGroupMixingLocalDeviceWithAirPlay() async throws {
        let mock = try await makeBackend(mirrorFleet)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let saved = try controller.createGroup(name: "Everything", memberIDs: ["local-mac", "loud"])
        controller.setMainOut(.group(id: saved.group.id))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(controller.isPassthrough)
        spy.reset()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(spy.volumeWrites.isEmpty,
                      "no member may be written when the Mac is one of them — not even the AirPlay member")
        XCTAssertEqual(spy.volume(of: "local-mac"), 65, "the system volume is never written back")
    }

    /// BURST STABILITY through the 100 clamp. The mirror holds ONE ratio snapshot for
    /// the whole burst, so a run of keypresses up into the clamp and back down returns
    /// the members exactly where they started — the drag semantics, applied to keys.
    func testSystemVolumeMirrorPreservesBalanceAcrossBurstThroughClamp() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        // Up past the point where `loud` (80, ratio 1.333) clamps at 100, then back
        // down to the starting master.
        for step in [69, 75, 81, 88, 94, 100, 94, 88, 81, 75, 69, 63, 60] {
            controller.mirrorSystemVolumeToMainOut(step)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spy.volume(of: "loud"), 80, "a clamped member un-clamps on the way down, exactly as in a drag")
        XCTAssertEqual(spy.volume(of: "quiet"), 40, "the 2:1 balance survives the whole burst")
    }

    /// The same for a burst down to ZERO and back. Re-deriving ratios at 0 is the
    /// worst case — every member is 0, so `mainOutRatios()`'s `master > 0` fallback
    /// hands out a flat 1.0 and the way back up is uniform instead of proportional.
    /// The held snapshot never consults it.
    func testSystemVolumeMirrorPreservesBalanceAcrossBurstThroughZero() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        for step in [30, 13, 6, 0, 6, 13, 30, 60] {
            controller.mirrorSystemVolumeToMainOut(step)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spy.volume(of: "loud"), 80, "a burst through 0 must not collapse the balance to unity")
        XCTAssertEqual(spy.volume(of: "quiet"), 40)
    }

    /// GUARD ON THE GUARD: proves the two tests above aren't vacuous. Driving the
    /// SAME steps through `setMainOutMasterVolume` with no drag open — i.e. re-deriving
    /// ratios every step, which is what the mirror would do without its snapshot —
    /// ratchets 2:1 apart toward unity and never recovers. This is the drift the
    /// snapshot exists to prevent; if this ever starts passing at 80/40, the mirror's
    /// snapshot has stopped being load-bearing.
    func testPerStepRatioRecomputationDriftsWhichIsWhyTheMirrorSnapshots() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        for step in [69, 75, 81, 88, 94, 100, 94, 88, 81, 75, 69, 63, 60] {
            controller.setMainOutMasterVolume(step)   // no beginMainOutMasterDrag()
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let loud = try XCTUnwrap(spy.volume(of: "loud"))
        let quiet = try XCTUnwrap(spy.volume(of: "quiet"))
        XCTAssertNotEqual(loud, 80, "per-step recomputation does NOT return to the starting balance")
        XCTAssertLessThan(Double(loud) / Double(quiet), 1.5,
                          "the clamp ratchet compresses 2:1 toward unity (measured ~1.18:1 at \(loud)/\(quiet))")
    }

    /// The snapshot is held on EVIDENCE, not a timer: it survives only while the
    /// members sit exactly where the mirror put them. A user dragging a member's own
    /// slider mid-burst moves one, so the next keypress re-derives from the new
    /// balance rather than scaling from a snapshot that no longer describes reality.
    func testSystemVolumeMirrorReSnapshotsAfterSomethingElseMovesAMember() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        controller.mirrorSystemVolumeToMainOut(30)          // → loud 40, quiet 20
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(spy.volume(of: "loud"), 40)

        // The user drags `quiet` up to match `loud` — a 1:1 balance at master 40.
        controller.setMemberVolume(40, for: "quiet")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.mainOutMasterVolume, 40)

        controller.mirrorSystemVolumeToMainOut(80)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(spy.volume(of: "loud"), 80, "re-derived from the NEW 1:1 balance…")
        XCTAssertEqual(spy.volume(of: "quiet"), 80, "…not from the stale 2:1 snapshot (which would give 40)")
    }

    /// A muted member must stay silent across a mirrored change. Mute realizes as
    /// volume 0 (`applySilence`), which moves a member and so re-derives the snapshot;
    /// the fresh ratio for a 0-volume member is 0, which pins it at 0.
    func testSystemVolumeMirrorKeepsMutedMemberSilent() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        controller.setMuted(true, for: "quiet")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(spy.volume(of: "quiet"), 0, "precondition: mute is volume 0")
        XCTAssertEqual(controller.mainOutMasterVolume, 40,
                       "precondition: the master averages the muted member's 0 in — existing `mainOutMasterVolume` semantics")

        controller.mirrorSystemVolumeToMainOut(20)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(spy.volume(of: "quiet"), 0, "a volume key must not resurrect a muted member")
        XCTAssertEqual(spy.volume(of: "loud"), 40,
                       "the unmuted member still follows — halving a master of 40 halves it from 80")
    }

    /// An empty Main Out target has nothing to scale — and must not trap or write.
    func testSystemVolumeMirrorNoOpsWithEmptyMainOutTarget() async throws {
        let mock = try await makeBackend(mirrorFleet)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        XCTAssertFalse(controller.isPassthrough, "an EMPTY set is not passthrough either")
        spy.reset()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(spy.volumeWrites.isEmpty)
    }

    /// T7 NOTE (superseding the pre-merge version of this test, ahh 2026-07-17):
    /// a per-app redirect used to open its AirPlay session via the whole-system
    /// output-set union, so the tap-mute bug this file's mirror fixes ("if nothing
    /// is connected to the audio out and I hit the volume buttons, the audio out
    /// volume doesn't change") applied to a redirected device too, and the mirror
    /// briefly unioned redirect targets in to cover it (`appRouteTargets`,
    /// `redirectOutputIDs()` — both since removed). T7 removed that union — a
    /// redirect now streams via its own dedicated per-app capture path and never
    /// touches the Mac's system output, so there's nothing left for the volume
    /// keys to unstick there; each redirected app already has its own independent
    /// volume control (the Applications card slider). Decision: volume keys drive
    /// Main Out only. `homepod-bed` here stands in for a device an app COULD be
    /// redirected to — it is simply never selected, and the mirror must never
    /// reach it.
    func testSystemVolumeMirrorNeverTouchesAnUnselectedDevice() async throws {
        let mock = try await makeBackend(mirrorFleetWithRedirectTarget)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        _ = controller.setDeviceSelected("loud", true)          // loud=80, quiet=40 → avg 60, a clean 2:1
        _ = controller.setDeviceSelected("quiet", true)
        controller.setMainOut(.selectedDevices)
        try await Task.sleep(nanoseconds: 100_000_000)
        spy.reset()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(spy.volume(of: "loud"), 40, "80 scaled by 30/60")
        XCTAssertTrue(spy.volumeWrites.allSatisfy { $0.id != "homepod-bed" },
                     "an unselected device — including one an app might be redirected to — is never touched by the mirror")
        XCTAssertEqual(spy.volume(of: "homepod-bed"), 40, "its volume stays exactly at the fixture's untouched value")
        XCTAssertEqual(spy.volume(of: "local-mac"), 65, "the mirror still never writes the local device")
    }
}

/// Wraps a real ``MockBackend`` — so `devices`, echoes and queue ordering behave
/// exactly as in every other test here — and records every `setVolume` that reaches
/// it. `MockBackend` alone can't express "how many writes did that provoke?", which
/// is precisely the assertion a no-feedback-loop proof needs.
///
/// Not `Sendable` and doesn't need to be: `OutputBackend` isn't `Sendable`-constrained
/// and every call is made from the test's own thread.
private final class WriteCountingBackend: OutputBackend {
    private let inner: MockBackend
    private(set) var volumeWrites: [(id: String, volume: Int)] = []

    init(_ inner: MockBackend) { self.inner = inner }

    var devices: [Device] { inner.devices }
    func start() { inner.start() }
    func stop() { inner.stop() }
    func makeEventStream() -> AsyncStream<BackendEvent> { inner.makeEventStream() }
    func setMuted(_ muted: Bool, for id: String) { inner.setMuted(muted, for: id) }
    func setOutputSet(_ ids: Set<String>) { inner.setOutputSet(ids) }

    func setVolume(_ volume: Int, for id: String) {
        volumeWrites.append((id: id, volume: volume))
        inner.setVolume(volume, for: id)
    }

    /// Forget recorded writes — fixture setup (selection, group activation) issues
    /// its own, and only what the mirror does afterwards is under test.
    func reset() { volumeWrites = [] }

    /// The device's CURRENT volume as the backend actually holds it (not what was
    /// commanded) — so clamping and the no-op guard are reflected honestly.
    func volume(of id: String) -> Int? { inner.devices.first { $0.id == id }?.volume }
}

private actor CountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
