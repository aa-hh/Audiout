import Foundation
import Testing
@testable import AudiouterCore

@Suite struct GroupControllerTests {

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

    /// THE SYMPTOM: the Main Out master must track the Mac's own volume after the
    /// last AirPlay device disconnects — not slam to 0 (the empty-set average).
    @Test func mainOutMasterTracksLocalAfterLastAirPlayRemoved() async throws {
        let (controller, _) = try await makeController(fleet: [
            Device(id: "local-mac", name: "MacBook Pro Speakers", kind: .localMac,
                   supportsAirPlay2: false, volume: 65, isLocalDevice: true),
            Device(id: "office", name: "Office", kind: .sonos, volume: 40),
        ])
        controller.ensureDefaultSelection()
        _ = controller.setDeviceSelected("office", true)          // streaming: master = 40
        #expect(controller.mainOutMasterVolume == 40)

        _ = controller.setDeviceSelected("office", false)         // disconnect
        #expect(controller.mainOutMasterVolume == 65,
                       "the master shows the Mac (what is actually playing), not a zeroed empty set")
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

    // MARK: Proportional master — ratio preservation

    @Test func masterVolumeIsAverageOfMembers() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(20, for: "sonos-move")
        backend.setVolume(60, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(controller.masterVolume == 40)
    }

    @Test func proportionalDragPreservesRelativeBalance() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(20, for: "sonos-move")   // ratio 0.5 of master(40)
        backend.setVolume(60, for: "office")       // ratio 1.5 of master(40)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.masterVolume == 40)

        controller.beginMasterDrag()
        controller.setMasterVolume(80)
        try await Task.sleep(nanoseconds: 200_000_000)
        controller.endMasterDrag()

        // Ratios (0.5x / 1.5x of the master at drag start) should be preserved.
        #expect(volume("sonos-move", in: backend) == 40)
        #expect(volume("office", in: backend) == 100, "1.5x of 80 clamps at 100")
    }

    @Test func memberAtMaxStaysClampedAcrossDragThenTracksAgainOnNextDrag() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(50, for: "sonos-move")   // ratio 1.0
        backend.setVolume(50, for: "office")       // ratio 1.0
        try await Task.sleep(nanoseconds: 200_000_000)

        controller.beginMasterDrag()
        controller.setMasterVolume(100)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(volume("sonos-move", in: backend) == 100)
        #expect(volume("office", in: backend) == 100)

        // Still within the same drag: pushing master back down un-clamps
        // using the *original* drag-start ratio (1.0), not a re-derived one.
        controller.setMasterVolume(60)
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.endMasterDrag()
        #expect(volume("sonos-move", in: backend) == 60)
        #expect(volume("office", in: backend) == 60)
    }

    @Test func masterDragFromZeroMovesEveryoneTogether() async throws {
        // A zero master has no meaningful ratio; document/verify the fallback:
        // every member is treated as ratio 1.0 (moves 1:1 with the master).
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(0, for: "sonos-move")
        backend.setVolume(0, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.masterVolume == 0)

        controller.beginMasterDrag()
        controller.setMasterVolume(30)
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.endMasterDrag()

        #expect(volume("sonos-move", in: backend) == 30)
        #expect(volume("office", in: backend) == 30)
    }

    @Test func masterEchoesMemberAverageAfterIndividualChange() async throws {
        let (controller, backend) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["sonos-move", "office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        backend.setVolume(10, for: "sonos-move")
        backend.setVolume(10, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.masterVolume == 10)

        controller.setMemberVolume(90, for: "office")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(controller.masterVolume == 50, "master should read back as the members' average")
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
        let controller = GroupController(backend: backend, store: GroupStore(directory: dir), loadPersisted: true)

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

        backend.setVolume(80, for: "office")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(controller.mainOutMasterVolume == 80,
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
        #expect(!controller.isPassthrough, "fixture precondition: streaming, not passthrough")
        #expect(controller.mainOutMasterVolume == 60, "fixture precondition: (80+40)/2")
        spy.reset()
        return (controller, spy)
    }

    /// THE FIX: an external system-volume change while streaming drives the Main Out
    /// master, scaling the AirPlay members proportionally — so the volume keys move
    /// the speakers that are actually playing.
    @Test func systemVolumeMirrorDrivesMainOutMasterWhileStreaming() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(controller.mainOutMasterVolume == 30, "the Main Out master follows the system volume")
        #expect(spy.volume(of: "loud") == 40, "80 scaled by 30/60")
        #expect(spy.volume(of: "quiet") == 20, "40 scaled by 30/60 — the 2:1 balance is preserved")
    }

    /// NO FEEDBACK LOOP, structurally: the mirror writes to the AirPlay members and
    /// NOTHING else. The local id is the only one whose `setVolume` reaches the
    /// system volume (`NativeBackend.setVolume`'s `isLocalDevice` branch), so never
    /// writing it means the listener that fired the mirror can never be re-fired by
    /// it. The write count is exactly the member count — one pass, no cascade.
    @Test func systemVolumeMirrorIssuesBoundedWritesAndNeverTouchesLocalDevice() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spy.volumeWrites.count == 2,
                       "exactly one write per Main Out member — a mirrored change must not cascade")
        #expect(Set(spy.volumeWrites.map(\.id)) == ["loud", "quiet"])
        #expect(spy.volumeWrites.allSatisfy { $0.id != "local-mac" },
                      "the mirror must NEVER write the local device — that is the whole no-feedback argument")
    }

    /// A whole BURST of volume-key steps still cannot loop: writes stay bounded at
    /// (steps × members), which is only true if each mirrored change produces one
    /// pass and provokes nothing further.
    @Test func systemVolumeMirrorBurstStaysBounded() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        let steps = [63, 69, 75, 81, 88, 94, 100]
        for step in steps { controller.mirrorSystemVolumeToMainOut(step) }
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(spy.volumeWrites.count == steps.count * 2,
                       "a burst of \(steps.count) steps over 2 members must be exactly \(steps.count * 2) writes")
        #expect(spy.volumeWrites.allSatisfy { $0.id != "local-mac" })
    }

    /// PASSTHROUGH: the local device is the sole Main Out member, so mirroring would
    /// be circular — the keys already moved the only thing Main Out names. Nothing
    /// is written at all.
    @Test func systemVolumeMirrorDoesNotDriveMasterInPassthrough() async throws {
        let mock = try await makeBackend(mirrorFleet)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        controller.ensureDefaultSelection()
        #expect(controller.isPassthrough, "precondition: set == {local}")
        spy.reset()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spy.volumeWrites.isEmpty,
                      "passthrough must not drive the Main Out master — no circular write")
        #expect(spy.volume(of: "local-mac") == 65, "the local device's own volume is untouched")
    }

    /// `isPassthrough` is false for EVERY `.group` target — but a group's members can
    /// include the Mac, and `saveCurrentSetupAsGroup` while in passthrough saves
    /// exactly such a group. Pointing Main Out at it must still not mirror: the local
    /// device is the only member, so the volume key already moved it.
    @Test func systemVolumeMirrorRefusesGroupWhoseOnlyMemberIsLocalDevice() async throws {
        let mock = try await makeBackend(mirrorFleet)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        controller.ensureDefaultSelection()                    // {local}
        let saved = try controller.saveCurrentSetupAsGroup(name: "Just the Mac")
        controller.setMainOut(.group(id: saved.group.id))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!controller.isPassthrough, "a group target is never passthrough — which is exactly the trap")
        spy.reset()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spy.volumeWrites.isEmpty,
                      "a group whose member is the Mac must not be mirrored despite !isPassthrough")
    }

    /// The dangerous shape of the same trap: a group MIXING the Mac with an AirPlay
    /// speaker. Here the local ratio isn't 1, so a mirrored keypress would scale the
    /// Mac to a value the user never asked for and yank the system volume out from
    /// under them. The local-member guard refuses the whole mirror.
    @Test func systemVolumeMirrorRefusesGroupMixingLocalDeviceWithAirPlay() async throws {
        let mock = try await makeBackend(mirrorFleet)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let saved = try controller.createGroup(name: "Everything", memberIDs: ["local-mac", "loud"])
        controller.setMainOut(.group(id: saved.group.id))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!controller.isPassthrough)
        spy.reset()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spy.volumeWrites.isEmpty,
                      "no member may be written when the Mac is one of them — not even the AirPlay member")
        #expect(spy.volume(of: "local-mac") == 65, "the system volume is never written back")
    }

    /// BURST STABILITY through the 100 clamp. The mirror holds ONE ratio snapshot for
    /// the whole burst, so a run of keypresses up into the clamp and back down returns
    /// the members exactly where they started — the drag semantics, applied to keys.
    @Test func systemVolumeMirrorPreservesBalanceAcrossBurstThroughClamp() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        // Up past the point where `loud` (80, ratio 1.333) clamps at 100, then back
        // down to the starting master.
        for step in [69, 75, 81, 88, 94, 100, 94, 88, 81, 75, 69, 63, 60] {
            controller.mirrorSystemVolumeToMainOut(step)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(spy.volume(of: "loud") == 80, "a clamped member un-clamps on the way down, exactly as in a drag")
        #expect(spy.volume(of: "quiet") == 40, "the 2:1 balance survives the whole burst")
    }

    /// The same for a burst down to ZERO and back. Re-deriving ratios at 0 is the
    /// worst case — every member is 0, so `mainOutRatios()`'s `master > 0` fallback
    /// hands out a flat 1.0 and the way back up is uniform instead of proportional.
    /// The held snapshot never consults it.
    @Test func systemVolumeMirrorPreservesBalanceAcrossBurstThroughZero() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        for step in [30, 13, 6, 0, 6, 13, 30, 60] {
            controller.mirrorSystemVolumeToMainOut(step)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(spy.volume(of: "loud") == 80, "a burst through 0 must not collapse the balance to unity")
        #expect(spy.volume(of: "quiet") == 40)
    }

    /// GUARD ON THE GUARD: proves the two tests above aren't vacuous. Driving the
    /// SAME steps through `setMainOutMasterVolume` with no drag open — i.e. re-deriving
    /// ratios every step, which is what the mirror would do without its snapshot —
    /// ratchets 2:1 apart toward unity and never recovers. This is the drift the
    /// snapshot exists to prevent; if this ever starts passing at 80/40, the mirror's
    /// snapshot has stopped being load-bearing.
    @Test func perStepRatioRecomputationDriftsWhichIsWhyTheMirrorSnapshots() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        for step in [69, 75, 81, 88, 94, 100, 94, 88, 81, 75, 69, 63, 60] {
            controller.setMainOutMasterVolume(step)   // no beginMainOutMasterDrag()
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let loud = try #require(spy.volume(of: "loud"))
        let quiet = try #require(spy.volume(of: "quiet"))
        #expect(loud != 80, "per-step recomputation does NOT return to the starting balance")
        #expect(Double(loud) / Double(quiet) < 1.5,
                          "the clamp ratchet compresses 2:1 toward unity (measured ~1.18:1 at \(loud)/\(quiet))")
    }

    /// The snapshot is held on EVIDENCE, not a timer: it survives only while the
    /// members sit exactly where the mirror put them. A user dragging a member's own
    /// slider mid-burst moves one, so the next keypress re-derives from the new
    /// balance rather than scaling from a snapshot that no longer describes reality.
    @Test func systemVolumeMirrorReSnapshotsAfterSomethingElseMovesAMember() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        controller.mirrorSystemVolumeToMainOut(30)          // → loud 40, quiet 20
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(spy.volume(of: "loud") == 40)

        // The user drags `quiet` up to match `loud` — a 1:1 balance at master 40.
        controller.setMemberVolume(40, for: "quiet")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.mainOutMasterVolume == 40)

        controller.mirrorSystemVolumeToMainOut(80)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spy.volume(of: "loud") == 80, "re-derived from the NEW 1:1 balance…")
        #expect(spy.volume(of: "quiet") == 80, "…not from the stale 2:1 snapshot (which would give 40)")
    }

    /// A muted member must stay silent across a mirrored change. Mute realizes as
    /// volume 0 (`applySilence`), which moves a member and so re-derives the snapshot;
    /// the fresh ratio for a 0-volume member is 0, which pins it at 0.
    @Test func systemVolumeMirrorKeepsMutedMemberSilent() async throws {
        let (controller, spy) = try await makeStreamingMirrorController()

        controller.setMuted(true, for: "quiet")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(spy.volume(of: "quiet") == 0, "precondition: mute is volume 0")
        #expect(controller.mainOutMasterVolume == 40,
                       "precondition: the master averages the muted member's 0 in — existing `mainOutMasterVolume` semantics")

        controller.mirrorSystemVolumeToMainOut(20)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spy.volume(of: "quiet") == 0, "a volume key must not resurrect a muted member")
        #expect(spy.volume(of: "loud") == 40,
                       "the unmuted member still follows — halving a master of 40 halves it from 80")
    }

    /// An empty Main Out target has nothing to scale — and must not trap or write.
    @Test func systemVolumeMirrorNoOpsWithEmptyMainOutTarget() async throws {
        let mock = try await makeBackend(mirrorFleet)
        let spy = WriteCountingBackend(mock)
        let controller = GroupController(backend: spy, store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        #expect(!controller.isPassthrough, "an EMPTY set is not passthrough either")
        spy.reset()

        controller.mirrorSystemVolumeToMainOut(30)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spy.volumeWrites.isEmpty)
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
    @Test func systemVolumeMirrorNeverTouchesAnUnselectedDevice() async throws {
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

        #expect(spy.volume(of: "loud") == 40, "80 scaled by 30/60")
        #expect(spy.volumeWrites.allSatisfy { $0.id != "homepod-bed" },
                     "an unselected device — including one an app might be redirected to — is never touched by the mirror")
        #expect(spy.volume(of: "homepod-bed") == 40, "its volume stays exactly at the fixture's untouched value")
        #expect(spy.volume(of: "local-mac") == 65, "the mirror still never writes the local device")
    }

    // MARK: onStateDidChange — change hook (T2, PLAN-COMPANION-APP.md)

    @Test func setDeviceSelectedFiresOnStateDidChangeOnRealChange() async throws {
        let (controller, _) = try await makeController()
        controller.setMainOut(.selectedDevices)
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        _ = controller.setDeviceSelected("office", true)

        #expect(fireCount == 1)
    }

    @Test func setDeviceSelectedDoesNotFireOnStateDidChangeWhenAlreadySelected() async throws {
        let (controller, _) = try await makeController()
        controller.setMainOut(.selectedDevices)
        _ = controller.setDeviceSelected("office", true)
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        _ = controller.setDeviceSelected("office", true)   // already selected — no-op

        #expect(fireCount == 0, "selecting an already-selected device must not fire onStateDidChange")
    }

    @Test func setDeviceSelectedDoesNotFireOnStateDidChangeWhenDeselectingUnselectedDevice() async throws {
        let (controller, _) = try await makeController()
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        _ = controller.setDeviceSelected("office", false)  // never selected — no-op

        #expect(fireCount == 0, "deselecting a device that was never selected must not fire onStateDidChange")
    }

    // `.selectedDevices`, not `.group`: targeting a group routes through
    // `applyRouting()` → `activateGroup(id:)`, which fires this same signal in
    // its own right (see `activateGroupFiresOnStateDidChange`) — isolating the
    // `.selectedDevices` branch here tests `setMainOut`'s own fire alone.
    @Test func setMainOutFiresOnStateDidChange() async throws {
        let (controller, _) = try await makeController()
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        controller.setMainOut(.selectedDevices)

        #expect(fireCount == 1)
    }

    @Test func saveGroupFiresOnStateDidChange() async throws {
        let (controller, _) = try await makeController()
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        try controller.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))

        #expect(fireCount == 1)
    }

    @Test func saveGroupDoesNotFireOnStateDidChangeWhenRejected() async throws {
        let (controller, _) = try await makeController()
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        #expect(throws: GroupController.GroupError.emptyMembership) {
            try controller.saveGroup(Group(id: "g1", name: "Empty", memberIDs: [], memberVolumes: [:]))
        }

        #expect(fireCount == 0, "a rejected (empty-membership) save must not fire onStateDidChange")
    }

    @Test func deleteGroupFiresOnStateDidChangeOnRealDeletion() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["office"], memberVolumes: [:]))
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        try controller.deleteGroup(id: "g1")

        #expect(fireCount == 1)
    }

    @Test func deleteGroupDoesNotFireOnStateDidChangeForUnknownID() async throws {
        let (controller, _) = try await makeController()
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        try controller.deleteGroup(id: "does-not-exist")

        #expect(fireCount == 0, "deleting a group id that was never saved must not fire onStateDidChange")
    }

    @Test func activateGroupFiresOnStateDidChange() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["office"], memberVolumes: [:]))
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        controller.activateGroup(id: "g1")

        #expect(fireCount == 1)
    }

    @Test func activateGroupDoesNotFireOnStateDidChangeForUnknownID() async throws {
        let (controller, _) = try await makeController()
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        controller.activateGroup(id: "does-not-exist")

        #expect(fireCount == 0, "activating an unknown group id is a no-op and must not fire onStateDidChange")
    }

    @Test func deactivateGroupFiresOnStateDidChangeWhenGroupWasActive() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        controller.deactivateGroup()

        #expect(fireCount == 1)
    }

    @Test func deactivateGroupDoesNotFireOnStateDidChangeWhenNoGroupActive() async throws {
        let (controller, _) = try await makeController()
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        controller.deactivateGroup()

        #expect(fireCount == 0, "deactivating when no group is active must not fire onStateDidChange")
    }

    @Test func syncActiveGroupToSelectionDoesNotFireOnStateDidChangeWhenAlreadyInSync() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Downstairs",
                                       memberIDs: ["office", "sonos-move"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))   // activateGroup already settles activeGroupID == "g1"
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        #expect(controller.syncActiveGroupToSelection() == "g1")

        #expect(fireCount == 0, "calling sync when activeGroupID already matches must not fire onStateDidChange")
    }

    /// Group identity is decided by MEMBERSHIP, order-independent (SPEC.md §9
    /// dedup): two saved groups can share an identical member set.
    /// `group(matchingMemberSet:)` resolves such a tie to the FIRST array match,
    /// so activating the second and then reconciling moves `activeGroupID` back
    /// to the first — a genuine change this method must fire for.
    @Test func syncActiveGroupToSelectionFiresOnStateDidChangeWhenDedupResolvesToADifferentGroup() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "First", memberIDs: ["office", "sonos-move"], memberVolumes: [:]))
        try controller.saveGroup(Group(id: "g2", name: "Second", memberIDs: ["office", "sonos-move"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g2"))
        #expect(controller.activeGroupID == "g2")
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        #expect(controller.syncActiveGroupToSelection() == "g1", "dedup resolves to the first array match with an identical member set")

        #expect(fireCount == 1, "reconciling activeGroupID from g2 to g1 is a real state change")
    }

    @Test func ensureDefaultSelectionFiresOnStateDidChangeOnce() async throws {
        let (controller, _) = try await makeController()
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        controller.ensureDefaultSelection()
        #expect(fireCount == 1, "establishing the out-of-the-box default is a real state change")

        controller.ensureDefaultSelection()
        #expect(fireCount == 1, "calling again once the default is established is a no-op and must not fire again")
    }

    @Test func setMutedFiresOnStateDidChangeOnSilenceEdgeOnly() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "X", memberIDs: ["office"], memberVolumes: [:]))
        controller.activateGroup(id: "g1")
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        controller.setMuted(true, for: "office")
        #expect(fireCount == 1, "the false→true mute edge must fire onStateDidChange")

        controller.setMuted(true, for: "office")   // already muted — no edge
        #expect(fireCount == 1, "re-muting an already-muted member is a no-op and must not fire again")

        controller.setMuted(false, for: "office")
        #expect(fireCount == 2, "the true→false unmute edge must fire onStateDidChange")
    }

    /// Pure-backend-write paths echo back as `BackendEvent.deviceUpdated`
    /// instead — firing `onStateDidChange` here too would double-notify.
    @Test func memberAndMasterVolumeWritesDoNotFireOnStateDidChange() async throws {
        let (controller, _) = try await makeController()
        controller.setMainOut(.selectedDevices)
        _ = controller.setDeviceSelected("office", true)
        _ = controller.setDeviceSelected("sonos-move", true)
        try await Task.sleep(nanoseconds: 200_000_000)
        var fireCount = 0
        controller.onStateDidChange = { fireCount += 1 }

        controller.setMemberVolume(70, for: "office")
        controller.beginMainOutMasterDrag()
        controller.setMainOutMasterVolume(80)
        controller.endMainOutMasterDrag()
        controller.mirrorSystemVolumeToMainOut(50)

        #expect(fireCount == 0,
                "member/master volume writes and the volume-key mirror must never fire onStateDidChange")
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
