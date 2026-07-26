// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AudiouterProtocol
@testable import AudiouterCore

/// Coverage for `CompanionCommandDispatcher` (PLAN-COMPANION-APP.md T4): one
/// case per command, plus every refusal the plan calls out. `MockBackend`-backed
/// real `GroupController`/`AppRoutingController` (temp-dir stores, via
/// `IsolatedSuite.scratchDir`) — the same construction pattern
/// `MixerWindowControllerTests`/`GroupControllerTests` use — so this exercises
/// the actual controller methods, not a mock of them.
@MainActor
@Suite final class CompanionCommandDispatcherTests: IsolatedSuite {

    /// Records everything the two injected closures were called with, so tests
    /// can assert on them without a mock framework.
    private final class Spy {
        var excludedBundleIDs: Set<String> = []
        var localPlaybackCalls: [(volume: Int, bundleID: String)] = []
        var appliedStartBufferMs: [Int] = []
        /// While true, the applyStartBuffer closure spins (yielding) instead of
        /// returning — simulates the real ~3-5s teardown/reconnect so tests can
        /// observe the dispatcher's in-flight serialization.
        var holdStartBuffer = false
    }

    private struct Context {
        let dispatcher: CompanionCommandDispatcher
        let groupController: GroupController
        let appRouting: AppRoutingController
        let settings: AppSettings
        let backend: MockBackend
        let spy: Spy
    }

    private func makeContext(fleet: [Device] = .demoFleet) async throws -> Context {
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: fleet.count)

        let groupController = GroupController(backend: backend, store: GroupStore(directory: scratchDir),
                                              routingStore: RoutingStore(directory: scratchDir),
                                              loadPersisted: false)
        let appRouting = AppRoutingController(store: AppRouteStore(directory: scratchDir), loadPersisted: false)
        let settings = AppSettings(defaults: isolatedDefaults)
        let spy = Spy()

        let dispatcher = CompanionCommandDispatcher(
            groupController: groupController,
            appRouting: appRouting,
            settings: settings,
            isExcluded: { spy.excludedBundleIDs.contains($0) },
            setLocalPlaybackVolume: { volume, bundleID in
                spy.localPlaybackCalls.append((volume, bundleID))
            },
            applyStartBuffer: { ms in
                spy.appliedStartBufferMs.append(ms)
                while spy.holdStartBuffer {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        )
        return Context(dispatcher: dispatcher, groupController: groupController, appRouting: appRouting,
                       settings: settings, backend: backend, spy: spy)
    }

    private func waitForFleet(_ backend: MockBackend, count: Int) async throws {
        let stream = backend.makeEventStream()
        let box = DispatcherTestCountBox()
        try await confirmation("fleet discovered") { discovered in
            let task = Task {
                for await event in stream {
                    if case .deviceAdded = event, await box.increment() >= count {
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
    }

    /// Let a fire-and-forget `Task` (the `setStartBufferMs` apply path) run
    /// before asserting on its side effect.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: setDeviceSelected — round-trips SelectionResult, incl. auto-swap

    @Test func setDeviceSelectedRoundTripsPlainOk() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.setDeviceSelected(id: "office", selected: true))
        #expect(result.applied)
        #expect(result.refusalReason == nil)
        #expect(!result.autoSwappedCurrentDevice)
        #expect(ctx.groupController.isSpeakerSelected("office"))
    }

    @Test func setDeviceSelectedRoundTripsAutoSwap() async throws {
        let ctx = try await makeContext()
        ctx.groupController.ensureDefaultSelection() // {local}
        let result = ctx.dispatcher.execute(.setDeviceSelected(id: "office", selected: true))
        #expect(result.applied)
        #expect(result.autoSwappedCurrentDevice, "local was the sole member — dropped by the auto-swap")
        #expect(ctx.groupController.selectedDeviceIDs == ["office"])
    }

    // MARK: retryConnection

    @Test func retryConnectionRoundTripsOk() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.retryConnection(id: "office"))
        #expect(result.applied)
        #expect(ctx.groupController.isSpeakerSelected("office"), "falls back to setDeviceSelected(_, true)")
    }

    // MARK: setMainOut — selected / group / refusals

    @Test func setMainOutSelectedDevices() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        ctx.groupController.setMainOut(.group(id: "g1"))
        let result = ctx.dispatcher.execute(.setMainOut(MainOutState(kind: "selected")))
        #expect(result.applied)
        #expect(ctx.groupController.mainOut == .selectedDevices)
    }

    @Test func setMainOutKnownGroup() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        let result = ctx.dispatcher.execute(.setMainOut(MainOutState(kind: "group", groupID: "g1")))
        #expect(result.applied)
        #expect(ctx.groupController.mainOut == .group(id: "g1"))
    }

    @Test func setMainOutUnknownGroupIsRefused() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.setMainOut(MainOutState(kind: "group", groupID: "does-not-exist")))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.groupController.mainOut == .selectedDevices, "never applied the dangling target")
    }

    @Test func setMainOutUnknownKindIsRefused() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.setMainOut(MainOutState(kind: "bogus")))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
    }

    // MARK: setDeviceVolume / setDeviceMuted

    @Test func setDeviceVolumeAppliesToBackend() async throws {
        let ctx = try await makeContext()
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "office", selected: true)) // mock connects synchronously
        let result = ctx.dispatcher.execute(.setDeviceVolume(id: "office", volume: 77))
        #expect(result.applied)
        #expect(ctx.backend.devices.first { $0.id == "office" }?.volume == 77)
    }

    @Test func setDeviceMutedStashesAndZeroes() async throws {
        let ctx = try await makeContext()
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "office", selected: true))
        let result = ctx.dispatcher.execute(.setDeviceMuted(id: "office", muted: true))
        #expect(result.applied)
        #expect(ctx.groupController.isMuted("office"))
        #expect(ctx.backend.devices.first { $0.id == "office" }?.volume == 0)
    }

    // MARK: setDeviceVolume / setDeviceMuted — honest refusals (finding 8)

    @Test func setDeviceVolumeRefusedWhenDeviceNotConnected() async throws {
        let ctx = try await makeContext()
        // "office" is undiscovered→off: NativeBackend would drop the write.
        let result = ctx.dispatcher.execute(.setDeviceVolume(id: "office", volume: 77))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.backend.devices.first { $0.id == "office" }?.volume == 50, "the demo volume never moved")
    }

    @Test func setDeviceVolumeRefusedForUnknownDevice() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.setDeviceVolume(id: "no-such-device", volume: 10))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
    }

    @Test func setDeviceMutedRefusedWhenDeviceNotConnected() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.setDeviceMuted(id: "office", muted: true))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(!ctx.groupController.isMuted("office"), "no recorded mute the backend never honored")
        #expect(ctx.backend.devices.first { $0.id == "office" }?.volume == 50)
    }

    @Test func setDeviceVolumeOnLocalDeviceAppliesWithoutConnection() async throws {
        let ctx = try await makeContext()
        // The Mac itself has no engine output — its volume is the system output
        // level and is always writable, connected or not.
        let result = ctx.dispatcher.execute(.setDeviceVolume(id: "local-mac", volume: 33))
        #expect(result.applied)
        #expect(ctx.backend.devices.first { $0.id == "local-mac" }?.volume == 33)
    }

    // MARK: Main Out master drag brackets

    @Test func mainOutDragBracketsCallBeginSetEnd() async throws {
        let ctx = try await makeContext()
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "office", selected: true))
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "sonos-move", selected: true))

        #expect(ctx.dispatcher.execute(.beginMainOutDrag).applied)
        #expect(ctx.dispatcher.execute(.setMainOutMasterVolume(volume: 60)).applied)
        #expect(ctx.dispatcher.execute(.endMainOutDrag).applied)
        // Proportional scaling actually reached the backend.
        #expect(ctx.groupController.mainOutMasterVolume == 60)
    }

    // MARK: setMainOutMuted

    @Test func setMainOutMutedMutesEveryMember() async throws {
        let ctx = try await makeContext()
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "office", selected: true))
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "sonos-move", selected: true))

        let result = ctx.dispatcher.execute(.setMainOutMuted(muted: true))
        #expect(result.applied)
        #expect(ctx.groupController.isMainOutMuted)
    }

    // MARK: createGroup — success + emptyMembership refusal

    @Test func createGroupSucceeds() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.createGroup(name: "Downstairs", memberIDs: ["office"], iconSymbolName: nil))
        #expect(result.applied)
        #expect(ctx.groupController.groups.contains { $0.name == "Downstairs" })
    }

    @Test func createGroupWithEmptyMembershipIsRefused() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.createGroup(name: "Empty", memberIDs: [], iconSymbolName: nil))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.groupController.groups.isEmpty)
    }

    // MARK: updateGroup — success + emptyMembership refusal

    @Test func updateGroupSavesEditedFields() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Old Name", memberIDs: ["office"], memberVolumes: [:]))
        let state = GroupState(id: "g1", name: "New Name", memberIDs: ["office", "sonos-move"],
                               memberVolumes: ["office": 40, "sonos-move": 50], isMuted: false)
        let result = ctx.dispatcher.execute(.updateGroup(state))
        #expect(result.applied)
        let saved = ctx.groupController.groups.first { $0.id == "g1" }
        #expect(saved?.name == "New Name")
        #expect(saved?.memberIDs == ["office", "sonos-move"])
    }

    @Test func updateGroupWithEmptyMembershipIsRefused() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        let state = GroupState(id: "g1", name: "Pair", memberIDs: [], memberVolumes: [:], isMuted: false)
        let result = ctx.dispatcher.execute(.updateGroup(state))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.groupController.groups.first { $0.id == "g1" }?.memberIDs == ["office"], "rejected save left the group untouched")
    }

    // MARK: deleteGroup

    @Test func deleteGroupRemovesIt() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        let result = ctx.dispatcher.execute(.deleteGroup(id: "g1"))
        #expect(result.applied)
        #expect(!ctx.groupController.groups.contains { $0.id == "g1" })
    }

    // MARK: setGroupMuted

    @Test func setGroupMutedMutesEveryMember() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office", "sonos-move"], memberVolumes: [:]))
        let result = ctx.dispatcher.execute(.setGroupMuted(id: "g1", muted: true))
        #expect(result.applied)
        #expect(ctx.groupController.isGroupMuted("g1"))
    }

    // MARK: addAppRoute — success + excluded refusal

    @Test func addAppRouteSucceeds() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.addAppRoute(bundleID: "com.apple.Music", displayName: "Music"))
        #expect(result.applied)
        #expect(ctx.appRouting.appRoutes.contains { $0.bundleID == "com.apple.Music" })
    }

    @Test func addAppRouteRefusesExcludedBundle() async throws {
        let ctx = try await makeContext()
        ctx.spy.excludedBundleIDs.insert("com.apple.Music")
        let result = ctx.dispatcher.execute(.addAppRoute(bundleID: "com.apple.Music", displayName: "Music"))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(!ctx.appRouting.appRoutes.contains { $0.bundleID == "com.apple.Music" })
    }

    // MARK: removeAppRoute

    @Test func removeAppRouteRemovesIt() async throws {
        let ctx = try await makeContext()
        ctx.appRouting.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let result = ctx.dispatcher.execute(.removeAppRoute(bundleID: "com.apple.Music"))
        #expect(result.applied)
        #expect(!ctx.appRouting.appRoutes.contains { $0.bundleID == "com.apple.Music" })
    }

    // MARK: setAppDestination — noRedirect / currentDevice / device + refusals

    @Test func setAppDestinationNoRedirect() async throws {
        let ctx = try await makeContext()
        ctx.appRouting.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        ctx.appRouting.setDestination(.device(id: "office"), for: "com.apple.Music")
        let result = ctx.dispatcher.execute(.setAppDestination(bundleID: "com.apple.Music", kind: "noRedirect", deviceID: nil))
        #expect(result.applied)
        #expect(ctx.appRouting.appRoutes.first?.destination == .noRedirect)
    }

    @Test func setAppDestinationCurrentDevice() async throws {
        let ctx = try await makeContext()
        ctx.appRouting.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let result = ctx.dispatcher.execute(.setAppDestination(bundleID: "com.apple.Music", kind: "currentDevice", deviceID: nil))
        #expect(result.applied)
        #expect(ctx.appRouting.appRoutes.first?.destination == .currentDevice)
    }

    @Test func setAppDestinationKnownDevice() async throws {
        let ctx = try await makeContext()
        ctx.appRouting.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let result = ctx.dispatcher.execute(.setAppDestination(bundleID: "com.apple.Music", kind: "device", deviceID: "office"))
        #expect(result.applied)
        #expect(ctx.appRouting.appRoutes.first?.destination == .device(id: "office"))
    }

    @Test func setAppDestinationUnknownDeviceIsRefused() async throws {
        let ctx = try await makeContext()
        ctx.appRouting.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let result = ctx.dispatcher.execute(.setAppDestination(bundleID: "com.apple.Music", kind: "device", deviceID: "no-such-device"))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.appRouting.appRoutes.first?.destination == .noRedirect, "unresolved — never applied")
    }

    @Test func setAppDestinationUnknownKindIsRefused() async throws {
        let ctx = try await makeContext()
        ctx.appRouting.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let result = ctx.dispatcher.execute(.setAppDestination(bundleID: "com.apple.Music", kind: "bogus", deviceID: nil))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
    }

    // MARK: setAppVolume — plain device route vs. .currentDevice mirror

    @Test func setAppVolumeOnDeviceRouteDoesNotTouchLocalPlayback() async throws {
        let ctx = try await makeContext()
        ctx.appRouting.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        ctx.appRouting.setDestination(.device(id: "office"), for: "com.apple.Music")
        let result = ctx.dispatcher.execute(.setAppVolume(bundleID: "com.apple.Music", volume: 30))
        #expect(result.applied)
        #expect(ctx.appRouting.appRoutes.first?.volume == 30)
        #expect(ctx.spy.localPlaybackCalls.isEmpty)
    }

    @Test func setAppVolumeOnCurrentDeviceRouteAlsoMirrorsLocalPlayback() async throws {
        let ctx = try await makeContext()
        ctx.appRouting.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        ctx.appRouting.setDestination(.currentDevice, for: "com.apple.Music")
        let result = ctx.dispatcher.execute(.setAppVolume(bundleID: "com.apple.Music", volume: 30))
        #expect(result.applied)
        #expect(ctx.appRouting.appRoutes.first?.volume == 30)
        #expect(ctx.spy.localPlaybackCalls.count == 1)
        #expect(ctx.spy.localPlaybackCalls.first?.volume == 30)
        #expect(ctx.spy.localPlaybackCalls.first?.bundleID == "com.apple.Music")
    }

    // MARK: setConnectVolume — clamped write, no push

    @Test func setConnectVolumeWritesClampedSetting() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.setConnectVolume(volume: 500))
        #expect(result.applied)
        #expect(ctx.settings.connectVolume == AppSettings.maxConnectVolume, "clamped by AppSettings' own setter")
    }

    // MARK: setStartBufferMs — validated against options, fire-and-forget apply

    @Test func setStartBufferMsAppliesAValidOption() async throws {
        let ctx = try await makeContext()
        let ms = AppSettings.startBufferOptionsMs[1]
        let result = ctx.dispatcher.execute(.setStartBufferMs(ms: ms))
        #expect(result.applied)
        try await settle()
        #expect(ctx.spy.appliedStartBufferMs == [ms])
    }

    @Test func setStartBufferMsRefusesAnOffListValue() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.setStartBufferMs(ms: 42))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        try await settle()
        #expect(ctx.spy.appliedStartBufferMs.isEmpty, "never fired for a rejected value")
    }

    // MARK: createGroup — trust-boundary validation (findings 1, 6, 7)

    private var maxGroups: Int { CompanionCommandDispatcher.Limits.maxGroups }
    private var maxGroupNameChars: Int { CompanionCommandDispatcher.Limits.maxGroupNameChars }
    private var maxGroupMembers: Int { CompanionCommandDispatcher.Limits.maxGroupMembers }
    private var maxAppRoutes: Int { CompanionCommandDispatcher.Limits.maxAppRoutes }

    @Test func createGroupAtNameLimitApplies() async throws {
        let ctx = try await makeContext()
        let name = String(repeating: "n", count: maxGroupNameChars)
        let result = ctx.dispatcher.execute(.createGroup(name: name, memberIDs: ["office"], iconSymbolName: nil))
        #expect(result.applied)
        #expect(ctx.groupController.groups.first?.name == name)
    }

    @Test func createGroupOverNameLimitIsRefused() async throws {
        let ctx = try await makeContext()
        let name = String(repeating: "n", count: maxGroupNameChars + 1)
        let result = ctx.dispatcher.execute(.createGroup(name: name, memberIDs: ["office"], iconSymbolName: nil))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.groupController.groups.isEmpty)
    }

    @Test func createGroupBlankNameIsRefused() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.createGroup(name: "   ", memberIDs: ["office"], iconSymbolName: nil))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.groupController.groups.isEmpty)
    }

    @Test func createGroupTrimsName() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.createGroup(name: "  Den  ", memberIDs: ["office"], iconSymbolName: nil))
        #expect(result.applied)
        #expect(ctx.groupController.groups.first?.name == "Den")
    }

    @Test func createGroupAtMemberLimitApplies() async throws {
        let ctx = try await makeContext()
        let members = (0..<maxGroupMembers).map { "m\($0)" }
        let result = ctx.dispatcher.execute(.createGroup(name: "Big", memberIDs: members, iconSymbolName: nil))
        #expect(result.applied)
        #expect(ctx.groupController.groups.first?.memberIDs.count == maxGroupMembers)
    }

    @Test func createGroupOverMemberLimitIsRefused() async throws {
        let ctx = try await makeContext()
        let members = (0..<(maxGroupMembers + 1)).map { "m\($0)" }
        let result = ctx.dispatcher.execute(.createGroup(name: "Too Big", memberIDs: members, iconSymbolName: nil))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.groupController.groups.isEmpty)
    }

    @Test func createGroupBeyondGroupCapIsRefused() async throws {
        let ctx = try await makeContext()
        for i in 0..<maxGroups {
            let result = ctx.dispatcher.execute(.createGroup(name: "G\(i)", memberIDs: ["m\(i)"], iconSymbolName: nil))
            #expect(result.applied, "group \(i) is within the cap")
        }
        let over = ctx.dispatcher.execute(.createGroup(name: "One Too Many", memberIDs: ["m-over"], iconSymbolName: nil))
        #expect(!over.applied)
        #expect(over.refusalReason != nil)
        #expect(ctx.groupController.groups.count == maxGroups, "the cap held")
    }

    @Test func createGroupDuplicateMemberSetIsRefused() async throws {
        let ctx = try await makeContext()
        #expect(ctx.dispatcher.execute(.createGroup(name: "A", memberIDs: ["office"], iconSymbolName: nil)).applied)
        // Dedup-by-member-set makes NOTHING — the reply must not claim success.
        let dup = ctx.dispatcher.execute(.createGroup(name: "B", memberIDs: ["office"], iconSymbolName: nil))
        #expect(!dup.applied)
        #expect(dup.refusalReason != nil)
        #expect(ctx.groupController.groups.count == 1)
        #expect(!ctx.groupController.groups.contains { $0.name == "B" })
    }

    // MARK: updateGroup — trust-boundary validation (findings 1, 4, 5, 7)

    @Test func updateGroupUnknownIDIsRefused() async throws {
        let ctx = try await makeContext()
        // A phone acting on a ≤50ms-stale snapshot must not resurrect a group
        // the Mac just deleted (saveGroup would happily append).
        let state = GroupState(id: "ghost", name: "Ghost", memberIDs: ["office"],
                               memberVolumes: [:], isMuted: false)
        let result = ctx.dispatcher.execute(.updateGroup(state))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.groupController.groups.isEmpty, "nothing was created")
    }

    @Test func updateGroupBlankNameIsRefused() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        let state = GroupState(id: "g1", name: "  ", memberIDs: ["office"], memberVolumes: [:], isMuted: false)
        let result = ctx.dispatcher.execute(.updateGroup(state))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
        #expect(ctx.groupController.groups.first { $0.id == "g1" }?.name == "Pair")
    }

    @Test func updateGroupOverNameLimitIsRefused() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        let state = GroupState(id: "g1", name: String(repeating: "n", count: maxGroupNameChars + 1),
                               memberIDs: ["office"], memberVolumes: [:], isMuted: false)
        let result = ctx.dispatcher.execute(.updateGroup(state))
        #expect(!result.applied)
        #expect(ctx.groupController.groups.first { $0.id == "g1" }?.name == "Pair")
    }

    @Test func updateGroupOverMemberLimitIsRefused() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        let state = GroupState(id: "g1", name: "Pair", memberIDs: (0..<(maxGroupMembers + 1)).map { "m\($0)" },
                               memberVolumes: [:], isMuted: false)
        let result = ctx.dispatcher.execute(.updateGroup(state))
        #expect(!result.applied)
        #expect(ctx.groupController.groups.first { $0.id == "g1" }?.memberIDs == ["office"])
    }

    @Test func updateGroupBackfillsMissingMemberVolumes() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: ["office": 33]))
        let state = GroupState(id: "g1", name: "Pair", memberIDs: ["office", "sonos-move"],
                               memberVolumes: ["office": 33], isMuted: false)
        let result = ctx.dispatcher.execute(.updateGroup(state))
        #expect(result.applied)
        let saved = ctx.groupController.groups.first { $0.id == "g1" }
        #expect(saved?.memberVolumes["office"] == 33)
        #expect(saved?.memberVolumes["sonos-move"] == 40,
                "seeded from the device's current level, mirroring the Mac's own editor")
    }

    @Test func updateGroupDropsNonMemberVolumes() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: ["office": 33]))
        let state = GroupState(id: "g1", name: "Pair", memberIDs: ["office"],
                               memberVolumes: ["office": 33, "ghost": 10], isMuted: false)
        let result = ctx.dispatcher.execute(.updateGroup(state))
        #expect(result.applied)
        #expect(ctx.groupController.groups.first { $0.id == "g1" }?.memberVolumes["ghost"] == nil)
    }

    @Test func updateGroupAppliesMuteState() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        // isMuted rides the wire but Group has no mute field — it must reach
        // the controller's group-mute API, not be silently discarded.
        var state = GroupState(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:], isMuted: true)
        #expect(ctx.dispatcher.execute(.updateGroup(state)).applied)
        #expect(ctx.groupController.isGroupMuted("g1"))
        state.isMuted = false
        #expect(ctx.dispatcher.execute(.updateGroup(state)).applied)
        #expect(!ctx.groupController.isGroupMuted("g1"))
    }

    // MARK: addAppRoute — trust-boundary validation (finding 2)

    @Test func addAppRouteRefusesMalformedBundleID() async throws {
        let ctx = try await makeContext()
        for bad in ["", "   ", "not a bundle id!", "com.example/../escape ", String(repeating: "a", count: 129)] {
            let result = ctx.dispatcher.execute(.addAppRoute(bundleID: bad, displayName: "App"))
            #expect(!result.applied, "\(bad.prefix(20))… must be refused")
            #expect(result.refusalReason != nil)
        }
        #expect(ctx.appRouting.appRoutes.isEmpty)
    }

    @Test func addAppRouteAcceptsAtBundleIDLimit() async throws {
        let ctx = try await makeContext()
        let bundleID = String(repeating: "a", count: 128)
        #expect(ctx.dispatcher.execute(.addAppRoute(bundleID: bundleID, displayName: "App")).applied)
        #expect(ctx.appRouting.appRoutes.contains { $0.bundleID == bundleID })
    }

    @Test func addAppRouteRefusesBlankOrOverlongDisplayName() async throws {
        let ctx = try await makeContext()
        for bad in ["   ", String(repeating: "d", count: 129)] {
            let result = ctx.dispatcher.execute(.addAppRoute(bundleID: "com.apple.Music", displayName: bad))
            #expect(!result.applied)
            #expect(result.refusalReason != nil)
        }
        #expect(ctx.appRouting.appRoutes.isEmpty)
    }

    @Test func addAppRouteBeyondRouteCapIsRefused() async throws {
        let ctx = try await makeContext()
        for i in 0..<maxAppRoutes {
            #expect(ctx.dispatcher.execute(.addAppRoute(bundleID: "com.app\(i)", displayName: "App \(i)")).applied)
        }
        let over = ctx.dispatcher.execute(.addAppRoute(bundleID: "com.app.over", displayName: "Over"))
        #expect(!over.applied)
        #expect(over.refusalReason != nil)
        #expect(ctx.appRouting.appRoutes.count == maxAppRoutes)
        // Re-adding an EXISTING route at the cap stays a no-op success.
        #expect(ctx.dispatcher.execute(.addAppRoute(bundleID: "com.app0", displayName: "App 0")).applied)
        #expect(ctx.appRouting.appRoutes.count == maxAppRoutes)
    }

    // MARK: setStartBufferMs — replay/no-op + in-flight serialization (finding 3)

    @Test func setStartBufferMsNoOpsWhenAlreadyCurrent() async throws {
        let ctx = try await makeContext()
        ctx.settings.startBufferMs = AppSettings.startBufferOptionsMs[2]
        let result = ctx.dispatcher.execute(.setStartBufferMs(ms: AppSettings.startBufferOptionsMs[2]))
        #expect(result.applied)
        try await settle()
        #expect(ctx.spy.appliedStartBufferMs.isEmpty, "no ~3-5s stream teardown for a value already in effect")
    }

    @Test func setStartBufferMsRefusesWhileApplyInFlight() async throws {
        let ctx = try await makeContext()
        ctx.spy.holdStartBuffer = true
        let first = ctx.dispatcher.execute(.setStartBufferMs(ms: AppSettings.startBufferOptionsMs[1]))
        #expect(first.applied)
        let second = ctx.dispatcher.execute(.setStartBufferMs(ms: AppSettings.startBufferOptionsMs[2]))
        #expect(!second.applied, "overlapping applies would keep audio dead for the whole flood")
        #expect(second.refusalReason != nil)
        ctx.spy.holdStartBuffer = false
        try await settle()
        #expect(ctx.spy.appliedStartBufferMs == [AppSettings.startBufferOptionsMs[1]], "the refused value never fired")
        let third = ctx.dispatcher.execute(.setStartBufferMs(ms: AppSettings.startBufferOptionsMs[2]))
        #expect(third.applied, "a fresh apply is allowed once the previous one finished")
        try await settle()
        #expect(ctx.spy.appliedStartBufferMs == [AppSettings.startBufferOptionsMs[1], AppSettings.startBufferOptionsMs[2]])
    }

    // MARK: store failures — all-or-nothing + sanitized refusals (findings 9, 10)

    private static let sanitizedStoreRefusal = "The Mac couldn't save that change."

    /// Make every subsequent `GroupStore.save` throw (the directory refuses new
    /// writes). PAIR with `restoreStoreWritable()` so scratch-dir cleanup works.
    private func makeStoreReadOnly() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratchDir.path)
    }

    private func restoreStoreWritable() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratchDir.path)
    }

    @Test func createGroupStoreFailureLeavesNothingBehind() async throws {
        let ctx = try await makeContext()
        try makeStoreReadOnly()
        defer { restoreStoreWritable() }
        let result = ctx.dispatcher.execute(.createGroup(name: "Doomed", memberIDs: ["office"], iconSymbolName: nil))
        #expect(!result.applied)
        #expect(ctx.groupController.groups.isEmpty, "the half-made group was rolled back")
        #expect(result.refusalReason == Self.sanitizedStoreRefusal)
        #expect(result.refusalReason?.contains(scratchDir.path) != true, "no local paths leak to a LAN peer")
    }

    @Test func updateGroupStoreFailureRollsBack() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Old", memberIDs: ["office"], memberVolumes: [:]))
        try makeStoreReadOnly()
        defer { restoreStoreWritable() }
        let state = GroupState(id: "g1", name: "New", memberIDs: ["office"], memberVolumes: [:], isMuted: false)
        let result = ctx.dispatcher.execute(.updateGroup(state))
        #expect(!result.applied)
        #expect(ctx.groupController.groups.first { $0.id == "g1" }?.name == "Old",
                "the refused edit is not visible in the next snapshot")
        #expect(result.refusalReason == Self.sanitizedStoreRefusal)
    }

    @Test func deleteGroupStoreFailureRollsBack() async throws {
        let ctx = try await makeContext()
        try ctx.groupController.saveGroup(Group(id: "g1", name: "Pair", memberIDs: ["office"], memberVolumes: [:]))
        ctx.groupController.setMainOut(.group(id: "g1"))
        try makeStoreReadOnly()
        defer { restoreStoreWritable() }
        let result = ctx.dispatcher.execute(.deleteGroup(id: "g1"))
        #expect(!result.applied)
        #expect(ctx.groupController.groups.contains { $0.id == "g1" }, "the group survived the refused delete")
        #expect(ctx.groupController.mainOut == .group(id: "g1"), "Main Out was not left re-targeted")
        #expect(result.refusalReason == Self.sanitizedStoreRefusal)
    }

    // MARK: endMainOutDrag — ownership gating (finding 11)

    @Test func endMainOutDragFromNonOwnerLeavesBracketOpen() async throws {
        let ctx = try await makeContext()
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "office", selected: true))
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "sonos-move", selected: true))
        _ = ctx.dispatcher.execute(.setDeviceVolume(id: "office", volume: 50))
        _ = ctx.dispatcher.execute(.setDeviceVolume(id: "sonos-move", volume: 40))

        #expect(ctx.dispatcher.execute(.beginMainOutDrag).applied)
        // Clamping at 100 distorts the LIVE ratios, so bracket-vs-no-bracket
        // becomes observable on the next scale.
        _ = ctx.dispatcher.execute(.setMainOutMasterVolume(volume: 100))
        #expect(ctx.dispatcher.execute(.endMainOutDrag, isDragOwner: false).applied, "a stale end is accepted")
        _ = ctx.dispatcher.execute(.setMainOutMasterVolume(volume: 45))
        // The owner's bracket survived: the original 50/40 snapshot still drives scaling.
        #expect(ctx.backend.devices.first { $0.id == "office" }?.volume == 50)
        #expect(ctx.backend.devices.first { $0.id == "sonos-move" }?.volume == 40)
    }

    @Test func endMainOutDragFromOwnerClosesBracket() async throws {
        let ctx = try await makeContext()
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "office", selected: true))
        _ = ctx.dispatcher.execute(.setDeviceSelected(id: "sonos-move", selected: true))
        _ = ctx.dispatcher.execute(.setDeviceVolume(id: "office", volume: 50))
        _ = ctx.dispatcher.execute(.setDeviceVolume(id: "sonos-move", volume: 40))

        #expect(ctx.dispatcher.execute(.beginMainOutDrag).applied)
        _ = ctx.dispatcher.execute(.setMainOutMasterVolume(volume: 100)) // office clamps to 100, sonos-move → 89
        #expect(ctx.dispatcher.execute(.endMainOutDrag).applied) // default: caller owns the drag
        _ = ctx.dispatcher.execute(.setMainOutMasterVolume(volume: 45))
        // Live post-clamp ratios (100/89) drive scaling now — not the 50/40 snapshot.
        #expect(ctx.backend.devices.first { $0.id == "office" }?.volume != 50)
        #expect(ctx.backend.devices.first { $0.id == "sonos-move" }?.volume != 40)
    }

    // MARK: unknown

    @Test func unknownCommandIsRefused() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.unknown(name: "somethingFromANewerPhone"))
        #expect(!result.applied)
        #expect(result.refusalReason != nil)
    }
}

private actor DispatcherTestCountBox {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}
