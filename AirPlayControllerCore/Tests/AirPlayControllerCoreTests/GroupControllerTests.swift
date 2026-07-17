import XCTest
@testable import AirPlayControllerCore

final class GroupControllerTests: XCTestCase {

    /// Deterministic backend: no discovery stagger, no timers, pre-populated
    /// synchronously via a blocking discovery wait (mirrors MockBackendTests).
    private func makeBackend(_ fleet: [Device] = .demoFleet) async throws -> MockBackend {
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false)
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

    func testAutoSwapDoesNotFireWhenLocalNotSoleMember() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)          // no local at all
        let r = controller.setDeviceSelected("homepod-bed", true)
        XCTAssertFalse(r.autoSwappedCurrentDevice)
        XCTAssertEqual(controller.selectedDeviceIDs, ["office", "homepod-bed"])
    }

    func testLocalMixBlockRefusesWithReason() async throws {
        let (controller, _) = try await makeController()
        _ = controller.setDeviceSelected("office", true)          // mixed AirPlay set, no local
        XCTAssertFalse(controller.canSelectLocalSpeaker("local-mac"))
        let r = controller.setDeviceSelected("local-mac", true)
        XCTAssertFalse(r.applied)
        XCTAssertEqual(r.refusalReason, GroupController.localMixRefusalReason)
        XCTAssertFalse(controller.isSpeakerSelected("local-mac"))
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

    func testActiveGroupTracksMainOutGroupTarget() async throws {
        let (controller, _) = try await makeController()
        try controller.saveGroup(Group(id: "g1", name: "Downstairs",
                                       memberIDs: ["office", "sonos-move"], memberVolumes: [:]))

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

    // DECISION (Alec, 2026-07-17): the live Selected-Devices routing set does
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
}

private actor CountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
