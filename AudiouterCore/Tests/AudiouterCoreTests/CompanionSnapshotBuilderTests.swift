// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `CompanionSnapshotBuilder` is a pure mapper, but every field it maps has a
/// specific, easy-to-get-wrong source (PLAN-COMPANION-APP.md T3). These tests
/// exist to pin the traps the plan calls out — each one starts from a fixture
/// where the "obvious" (wrong) source and the real source actively disagree,
/// so a regression to the wrong source fails loudly rather than by
/// coincidence.
///
/// NOTE: every call to `CompanionSnapshotBuilder.build(...)` below is written
/// out in full rather than behind a local wrapper. A wrapper `func` would
/// have to spell `-> Snapshot` (or any `AudiouterProtocol` type) as an
/// explicit return-type annotation, which requires `import AudiouterProtocol`
/// — a module this test target does not (and per this task, should not)
/// depend on directly. `let snapshot = CompanionSnapshotBuilder.build(...)`
/// with no annotation, followed by plain member access, needs no such import
/// (the type is only ever inferred, never spelled).
@Suite struct CompanionSnapshotBuilderTests {

    // MARK: Shared inert defaults (plain stdlib types only — see the note above)

    private let noExcludedBundleIDs: Set<String> = []
    private let noAddableApps: [(bundleID: String, displayName: String)] = []
    private let noRunningRouted: Set<String> = []
    private let noLiveRoutedAppNames: [String: [String]] = [:]
    private let defaultServerName = "Test Mac"
    private let defaultConnectVolume = 35
    private let defaultConnectVolumeMin = 5
    private let defaultConnectVolumeMax = 100
    private let defaultStartBufferMs = 1000
    private let defaultStartBufferOptionsMs = [1000, 1500, 2250]

    // MARK: Fixture fleet
    //
    // `speaker-a` bakes in `isSelected: true` / `isMuted: true` directly on
    // the `Device` value — the backend's own passthrough notions — while
    // nothing in this suite ever tells `GroupController` to select or mute
    // it. That makes the two sources disagree from the moment the fleet is
    // discovered, with no extra setup required (mirrors `.demoFleet`'s own
    // sonos-move fixture, which bakes in the same disagreement).

    private static let fixtureFleet: [Device] = [
        Device(id: "local", name: "Mac", kind: .localMac, isLocalDevice: true),
        Device(id: "speaker-a", name: "Speaker A", kind: .sonos, isMuted: true, isSelected: true),
        Device(id: "speaker-b", name: "Speaker B", kind: .homePod,
               connectionState: .failed(ConnectionFailure(cause: .refusedOrBusy))),
    ]

    /// Deterministic backend, pre-populated synchronously via a blocking
    /// discovery wait — same pattern as `GroupControllerTests.makeBackend`.
    private func makeBackend(_ fleet: [Device] = fixtureFleet) async throws -> MockBackend {
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false, emitsLevels: false,
                                  simulatesDropouts: false)
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

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// A marker icon closure — `CompanionSnapshotBuilder` never inspects the
    /// device beyond identity here, so a fixed per-id string is enough to
    /// prove the closure's return value (not some hardcoded fallback) reaches
    /// the snapshot.
    private func iconFor(_ device: Device) -> String { "icon:\(device.id)" }

    private func makeAppRouting() -> AppRoutingController {
        AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
    }

    private func makeGroupController(backend: MockBackend) -> GroupController {
        GroupController(backend: backend, store: GroupStore(directory: tempDirectory()),
                        routingStore: RoutingStore(directory: tempDirectory()), loadPersisted: false)
    }

    // MARK: Trap 1 — isSelected

    @Test func deviceIsSelectedComesFromGroupControllerNeverDeviceIsSelected() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        // Sanity: the fixture really does bake `isSelected: true` into the
        // raw Device — if this ever stops being true the test proves nothing.
        #expect(backend.devices.first { $0.id == "speaker-a" }?.isSelected == true)
        // GroupController never selected it (loadPersisted: false, no
        // ensureDefaultSelection call) — its own notion disagrees.
        #expect(controller.isSpeakerSelected("speaker-a") == false)

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        let speakerA = try #require(snapshot.devices.first { $0.id == "speaker-a" })
        #expect(speakerA.isSelected == false, "must follow GroupController.isSpeakerSelected, not Device.isSelected")

        // Deliberately selecting it brings the two into agreement — proving
        // the snapshot tracks the controller's notion, not a frozen copy.
        controller.setDeviceSelected("speaker-a", true)
        let after = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(after.devices.first { $0.id == "speaker-a" }?.isSelected == true)
    }

    // MARK: Trap 2 — isMuted

    @Test func deviceIsMutedComesFromGroupControllerNeverDeviceIsMuted() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        // Sanity: speaker-a's raw Device bakes in isMuted: true.
        #expect(backend.devices.first { $0.id == "speaker-a" }?.isMuted == true)
        #expect(controller.isMuted("speaker-a") == false)

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        let speakerA = try #require(snapshot.devices.first { $0.id == "speaker-a" })
        #expect(speakerA.isMuted == false, "must follow GroupController.isMuted, not Device.isMuted")

        // Reverse direction: mute a device via the controller. `setMuted`
        // never calls `backend.setMuted` (it zeroes the volume instead), so
        // the raw Device's `isMuted` field never moves — only the snapshot
        // built from the controller should reflect the mute.
        controller.setMuted(true, for: "speaker-b")
        #expect(backend.devices.first { $0.id == "speaker-b" }?.isMuted == false, "backend field never written")
        let after = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(after.devices.first { $0.id == "speaker-b" }?.isMuted == true)
    }

    // MARK: Trap 3 — isMainOutMember

    @Test func deviceIsMainOutMemberComesFromGroupControllerIsMainOutMemberNotSelectedDevices() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        try controller.saveGroup(Group(id: "g1", name: "Group 1", memberIDs: ["speaker-b"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        // Composes the (independent) Selected Devices set without re-routing,
        // since Main Out currently targets the group, not `.selectedDevices`.
        controller.setDeviceSelected("speaker-a", true)

        #expect(controller.isSpeakerSelected("speaker-a") == true)
        #expect(controller.isMainOutMember("speaker-a") == false, "not a member of the active group")
        #expect(controller.isSpeakerSelected("speaker-b") == false, "never added to Selected Devices")
        #expect(controller.isMainOutMember("speaker-b") == true, "the active group's only member")

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        let speakerA = try #require(snapshot.devices.first { $0.id == "speaker-a" })
        let speakerB = try #require(snapshot.devices.first { $0.id == "speaker-b" })
        #expect(speakerA.isSelected == true)
        #expect(speakerA.isMainOutMember == false)
        #expect(speakerB.isSelected == false)
        #expect(speakerB.isMainOutMember == true)
    }

    // MARK: Trap 3b — the Mac's own volume under passthrough

    /// While nothing but the Mac sits behind Main Out, a write to the Mac's row
    /// goes to the MASTER — `setMemberVolume` redirects it — and never touches
    /// that device's stored fader. A row reporting the raw `Device.volume` there
    /// shows the phone a different number than the Mac's own popover shows for
    /// the same row (`PopoverController.applySelectionState` overlays Main onto
    /// it), and moving the phone's slider makes them disagree further.
    @Test func localDeviceVolumeReadsTheMasterWhileTheMacsRowDrivesMain() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        controller.setDeviceSelected("local", true)
        #expect(controller.localRowDrivesMain, "precondition: nothing but the Mac is behind Main Out")
        // The redirect the overlay exists for: this moves Main, not the fader.
        controller.setMemberVolume(37, for: "local")
        #expect(controller.mainOutMasterVolume == 37)
        #expect(backend.devices.first { $0.id == "local" }?.volume == 50,
                "precondition: the stored fader is untouched, so the two sources disagree")

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(snapshot.devices.first { $0.id == "local" }?.volume == 37,
                "the Mac's row must show what its own slider actually writes")
        #expect(snapshot.devices.first { $0.id == "speaker-a" }?.volume == 50,
                "and no other row is overlaid — the master is not a device level")

        // A real output behind Main Out ends the exception (the auto-swap drops
        // the Mac from the set): its row goes back to its own stored fader.
        controller.setDeviceSelected("speaker-a", true)
        #expect(controller.localRowDrivesMain == false)
        let mixed = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(mixed.devices.first { $0.id == "local" }?.volume == 50,
                "the fader the overlay left untouched is what the row returns to")
    }

    // MARK: Trap 4 — excluded apps

    @Test func excludedAppsAreAbsentFromAddableAppsAndAppRoutes() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()
        appRouting.addRoute(bundleID: "com.excluded.app", displayName: "Excluded")
        appRouting.addRoute(bundleID: "com.kept.app", displayName: "Kept")

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: ["com.excluded.app"], iconFor: iconFor,
            addableApps: [
                (bundleID: "com.excluded.app", displayName: "Excluded"),
                (bundleID: "com.addable.app", displayName: "Addable"),
            ],
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )

        #expect(!snapshot.appRoutes.contains { $0.bundleID == "com.excluded.app" })
        #expect(snapshot.appRoutes.contains { $0.bundleID == "com.kept.app" }, "non-excluded route survives")
        #expect(!snapshot.addableApps.contains { $0.bundleID == "com.excluded.app" })
        #expect(snapshot.addableApps.contains { $0.bundleID == "com.addable.app" }, "non-excluded addable app survives")
    }

    // MARK: Connection fields (D9 full parity)

    @Test func connectionCarriesFailureHeadlineAndSuggestion() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        let speakerB = try #require(snapshot.devices.first { $0.id == "speaker-b" })
        let failure = ConnectionFailure(cause: .refusedOrBusy)
        #expect(speakerB.connection.state == "failed")
        #expect(speakerB.connection.failureHeadline == failure.headline)
        #expect(speakerB.connection.failureSuggestion == failure.suggestion)

        // A device with no failure carries no headline/suggestion.
        let local = try #require(snapshot.devices.first { $0.id == "local" })
        #expect(local.connection.state == "off")
        #expect(local.connection.failureHeadline == nil)
        #expect(local.connection.failureSuggestion == nil)
    }

    // MARK: Passthrough fields

    @Test func passthroughFieldsReachTheSnapshotUnchanged() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: ["speaker-b": ["Some App"]],
            localFallbackActive: true, takeoverStatus: "taking over", serverName: "Alec's Mac",
            connectVolume: 42, connectVolumeMin: 5, connectVolumeMax: 100,
            startBufferMs: 1500, startBufferOptionsMs: [1000, 1500, 2250]
        )

        #expect(snapshot.serverName == "Alec's Mac")
        #expect(snapshot.liveRoutedAppNames == ["speaker-b": ["Some App"]])
        #expect(snapshot.localFallbackActive == true)
        #expect(snapshot.takeoverStatus == "taking over")
        // FIX-B2 finding 7a: not passed above, so the default must be the
        // safe "not double-pathed" reading, and passing true must survive.
        #expect(snapshot.systemDefaultIsAirPlayActive == false)
        #expect(snapshot.settings.connectVolume == 42)
        #expect(snapshot.settings.connectVolumeMin == 5)
        #expect(snapshot.settings.connectVolumeMax == 100)
        #expect(snapshot.settings.startBufferMs == 1500)
        #expect(snapshot.settings.startBufferOptionsMs == [1000, 1500, 2250])
        #expect(snapshot.devices.first { $0.id == "speaker-a" }?.iconSymbolName == "icon:speaker-a")
    }

    // MARK: Main Out target mapping

    @Test func mainOutStateReflectsSelectedDevicesOrGroupTarget() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        let selectedSnapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(selectedSnapshot.mainOut.kind == "selected")
        #expect(selectedSnapshot.mainOut.groupID == nil)

        try controller.saveGroup(Group(id: "g1", name: "Group 1", memberIDs: ["speaker-b"], memberVolumes: [:]))
        controller.setMainOut(.group(id: "g1"))
        let groupSnapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(groupSnapshot.mainOut.kind == "group")
        #expect(groupSnapshot.mainOut.groupID == "g1")
    }

    // MARK: Group mute mapping (same trap shape as device mute — GroupState.isMuted
    // must read GroupController.isGroupMuted, not a hardcoded default)

    @Test func groupStateIsMutedComesFromGroupControllerIsGroupMuted() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()
        try controller.saveGroup(Group(id: "g1", name: "Group 1", memberIDs: ["speaker-b"], memberVolumes: [:]))

        let before = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(before.groups.first { $0.id == "g1" }?.isMuted == false)

        controller.setGroupMuted(true, groupID: "g1")
        let after = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(after.groups.first { $0.id == "g1" }?.isMuted == true)
    }

    /// The group's own gain stage (volume decoupling) rides the snapshot as a
    /// stored value — never derived from members.
    @Test func groupStateCarriesTheGroupsOwnMasterVolume() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()
        try controller.saveGroup(Group(id: "g1", name: "Group 1", memberIDs: ["speaker-b"],
                                       memberVolumes: ["speaker-b": 20], masterVolume: 70))

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(snapshot.groups.first { $0.id == "g1" }?.masterVolume == 70)
    }

    // MARK: addableApps ordering (FIX-B2 finding 3 — array order is part of
    // Snapshot's Equatable, and `runningApplications` order is unspecified,
    // so an unsorted list defeats identical-snapshot suppression)

    @Test func addableAppsAreSortedByBundleIDRegardlessOfInputOrder() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor,
            addableApps: [
                (bundleID: "com.zebra.app", displayName: "Zebra"),
                (bundleID: "com.apple.Safari", displayName: "Safari"),
                (bundleID: "com.middle.app", displayName: "Middle"),
            ],
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(snapshot.addableApps.map(\.bundleID) ==
                ["com.apple.Safari", "com.middle.app", "com.zebra.app"])
    }

    // MARK: Size ceilings (FIX-A handoff — an over-1MB snapshot kills the
    // phone's connection deterministically, so the two running-app-scaled
    // lists carry documented caps applied deterministically post-sort)

    @Test func addableAppsAndLiveRoutedAppNamesAreCapped() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        let manyApps = (0..<(CompanionSnapshotBuilder.maxAddableApps + 50)).map {
            (bundleID: String(format: "com.app.%04d", $0), displayName: "App \($0)")
        }
        let manyNames = (0..<(CompanionSnapshotBuilder.maxLiveRoutedAppNamesPerDevice + 10)).map { "App \($0)" }

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor,
            addableApps: manyApps.shuffled(),
            runningRouted: noRunningRouted, liveRoutedAppNames: ["speaker-b": manyNames],
            localFallbackActive: false, takeoverStatus: nil, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        // Deterministic cut: the FIRST `maxAddableApps` in bundleID order,
        // regardless of input order — so a capped snapshot still suppresses
        // as identical between rebuilds.
        #expect(snapshot.addableApps.count == CompanionSnapshotBuilder.maxAddableApps)
        #expect(snapshot.addableApps.map(\.bundleID) ==
                manyApps.prefix(CompanionSnapshotBuilder.maxAddableApps).map(\.bundleID))
        #expect(snapshot.liveRoutedAppNames["speaker-b"] ==
                Array(manyNames.prefix(CompanionSnapshotBuilder.maxLiveRoutedAppNamesPerDevice)))
    }

    // MARK: systemDefaultIsAirPlayActive passthrough (FIX-B2 finding 7a)

    @Test func systemDefaultIsAirPlayActiveReachesTheSnapshot() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil,
            systemDefaultIsAirPlayActive: true, serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        #expect(snapshot.systemDefaultIsAirPlayActive == true)
    }

    // MARK: Group member names (FIX-B2 finding 7b — the Groups tab must be
    // able to label a member that is not currently discovered)

    @Test func groupMemberNamesCoverOfflineMembersAndPreferLiveNames() async throws {
        let backend = try await makeBackend()
        let controller = makeGroupController(backend: backend)
        let appRouting = makeAppRouting()

        // "ghost" is a saved member no longer discovered; "never-seen" has no
        // name anywhere. The caller's map also carries a STALE name for the
        // live speaker-b, which the live device list must override.
        try controller.saveGroup(Group(
            id: "g1", name: "Group 1",
            memberIDs: ["speaker-b", "ghost", "never-seen"], memberVolumes: [:]))

        let snapshot = CompanionSnapshotBuilder.build(
            devices: backend.devices, groupController: controller, appRouting: appRouting,
            excludedBundleIDs: noExcludedBundleIDs, iconFor: iconFor, addableApps: noAddableApps,
            runningRouted: noRunningRouted, liveRoutedAppNames: noLiveRoutedAppNames,
            localFallbackActive: false, takeoverStatus: nil,
            knownDeviceNames: ["ghost": "Old Kitchen", "speaker-b": "Stale Name"],
            serverName: defaultServerName,
            connectVolume: defaultConnectVolume, connectVolumeMin: defaultConnectVolumeMin,
            connectVolumeMax: defaultConnectVolumeMax, startBufferMs: defaultStartBufferMs,
            startBufferOptionsMs: defaultStartBufferOptionsMs
        )
        let group = try #require(snapshot.groups.first { $0.id == "g1" })
        #expect(group.memberNames == ["speaker-b": "Speaker B", "ghost": "Old Kitchen"],
                "offline member keeps its last-known name; live name wins; unnamed member is absent")
    }
}

private actor CountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
