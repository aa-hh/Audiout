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
        let result = ctx.dispatcher.execute(.setDeviceVolume(id: "office", volume: 77))
        #expect(result.applied)
        #expect(ctx.backend.devices.first { $0.id == "office" }?.volume == 77)
    }

    @Test func setDeviceMutedStashesAndZeroes() async throws {
        let ctx = try await makeContext()
        let result = ctx.dispatcher.execute(.setDeviceMuted(id: "office", muted: true))
        #expect(result.applied)
        #expect(ctx.groupController.isMuted("office"))
        #expect(ctx.backend.devices.first { $0.id == "office" }?.volume == 0)
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
