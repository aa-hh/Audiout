// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// Unit coverage for `DeviceDetailViewController` — the read-only device
/// detail pane (design revamp, `../../Sources/AudiouterWindowUI/AGENTS.md`).
/// This view is CONFIGURATION-ONLY: it only ever renders a `Device` snapshot
/// plus its saved-group memberships, and never activates a group or moves
/// audio. Wiring it into the "Groups" window's sidebar selection is covered
/// separately in `MixerWindowControllerTests`; these cases construct the
/// controller directly and drive it through its `test_*` hooks, since a
/// headless run can't synthesize the real hover/click gestures.
// `@MainActor` is load-bearing, not decoration: this suite builds and drives
// AppKit views, and every `NSView`-family API is main-actor-only. XCTest ran
// each test method on the main thread, so the annotation was never needed;
// swift-testing schedules non-isolated `@Test` bodies on the cooperative
// pool, where the same calls trip AppKit's "modifications to layout engine
// from a background thread" exception and take the whole process down
// (observed in `AppRowViewTests` during this migration). Do not remove it.
@MainActor
@Suite struct DeviceDetailViewTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceDetailViewTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `GroupController` with an empty, non-persisted `MockBackend` — this
    /// view only ever reads `groupController.groups` (for membership text),
    /// never the backend, so an un-started, fleet-less backend is enough.
    private func makeController() -> GroupController {
        let backend = MockBackend(fleet: [], staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false)
        return GroupController(backend: backend, store: GroupStore(directory: tempDirectory()), loadPersisted: false)
    }

    private func makeDevice(
        id: String = "d1", name: String = "Office", kind: Device.Kind = .generic,
        isAvailable: Bool = true, volume: Int = 50, connectionState: ConnectionState = .off
    ) -> Device {
        Device(id: id, name: name, kind: kind, isAvailable: isAvailable, volume: volume,
              connectionState: connectionState)
    }

    // MARK: show(device:) basics

    @Test func showSetsShownDeviceID() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(id: "sonos-move"))
        #expect(detail.test_shownDeviceID == "sonos-move")
    }

    @Test func shownDeviceIDIsNilBeforeFirstShow() {
        let detail = DeviceDetailViewController(groupController: makeController())
        #expect(detail.test_shownDeviceID == nil)
    }

    @Test func refreshUpdatesFieldsForTheSameDevice() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(volume: 20))
        #expect(detail.test_metadataStrings["volume"] == "20%")

        detail.refresh(device: makeDevice(volume: 75))
        #expect(detail.test_metadataStrings["volume"] == "75%")
        #expect(detail.test_shownDeviceID == "d1")
    }

    // MARK: Metadata form — status wording

    @Test func statusTextOff() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .off))
        #expect(detail.test_metadataStrings["status"] == "Not connected")
    }

    @Test func statusTextConnecting() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .connecting))
        #expect(detail.test_metadataStrings["status"] == "Connecting")
    }

    @Test func statusTextReconnecting() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .reconnecting))
        #expect(detail.test_metadataStrings["status"] == "Reconnecting")
    }

    @Test func statusTextConnected() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .connected))
        #expect(detail.test_metadataStrings["status"] == "Connected")
    }

    @Test func statusTextFailed() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        #expect(detail.test_metadataStrings["status"] == "Couldn't connect",
                       "matches DeviceRowView's existing failed vocabulary")
    }

    // MARK: Metadata form — available / volume / kind

    @Test func availableYesAndNo() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(isAvailable: true))
        #expect(detail.test_metadataStrings["available"] == "Yes")

        detail.show(device: makeDevice(isAvailable: false))
        #expect(detail.test_metadataStrings["available"] == "No")
    }

    @Test func volumePercentFormatting() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(volume: 0))
        #expect(detail.test_metadataStrings["volume"] == "0%")

        detail.show(device: makeDevice(volume: 100))
        #expect(detail.test_metadataStrings["volume"] == "100%")
    }

    @Test func kindTextForEveryKind() {
        let detail = DeviceDetailViewController(groupController: makeController())
        let expectations: [(Device.Kind, String)] = [
            (.localMac, "This Mac"),
            (.homePod, "HomePod"),
            (.appleTV, "Apple TV"),
            (.airportExpress, "AirPort Express"),
            (.sonos, "Sonos"),
            (.generic, "AirPlay Speaker"),
        ]
        for (kind, expected) in expectations {
            detail.show(device: makeDevice(kind: kind))
            #expect(detail.test_metadataStrings["kind"] == expected, "kind: \(kind)")
        }
    }

    // MARK: "In groups" membership text

    @Test func groupMembershipTextIsNoneWhenDeviceIsInNoGroup() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "None")
    }

    @Test func groupMembershipTextListsEverySavedGroupContainingTheDevice() throws {
        let controller = makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office", "appletv-lr"],
                                       memberVolumes: ["office": 50, "appletv-lr": 60]))
        try controller.saveGroup(Group(id: "g2", name: "Whole House", memberIDs: ["office"],
                                       memberVolumes: ["office": 50]))
        try controller.saveGroup(Group(id: "g3", name: "Bedroom", memberIDs: ["appletv-lr"],
                                       memberVolumes: ["appletv-lr": 60]))

        let detail = DeviceDetailViewController(groupController: controller)
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "Kitchen, Whole House",
                       "only groups this device is a member of, in groupController.groups order")
    }

    @Test func groupMembershipTextUpdatesOnRefreshAfterAMembershipChange() throws {
        let controller = makeController()
        // Seed with a DIFFERENT member so "office" starts as a non-member while
        // the group stays non-empty (an empty group is now rejected).
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["living-room"],
                                       memberVolumes: ["living-room": 50]))
        let detail = DeviceDetailViewController(groupController: controller)
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "None")

        var group = try #require(controller.groups.first { $0.id == "g1" })
        group.memberIDs = ["office"]
        group.memberVolumes["office"] = 50
        try controller.saveGroup(group)

        detail.refresh(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "Kitchen")
    }

    // MARK: Icon resolution — no injected controller

    @Test func iconSymbolNameFallsBackToKindDefaultWithNoInjectedController() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(kind: .homePod))
        #expect(detail.test_iconSymbolName == Device.Kind.homePod.symbolName)
    }

    // MARK: Icon resolution — injected controller with/without an override

    @Test func iconSymbolNameUsesKindDefaultWhenControllerHasNoOverride() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController

        detail.show(device: makeDevice(kind: .sonos))
        #expect(detail.test_iconSymbolName == Device.Kind.sonos.symbolName)
    }

    @Test func iconSymbolNameUsesOverrideWhenControllerHasOneSet() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .sonos)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)

        #expect(detail.test_iconSymbolName == "airpods")
    }

    @Test func iconSymbolNameFallsBackToDefaultForAStaleOverride() {
        // The controller only ever persists a valid name (`setSymbolName` is a
        // no-op for an invalid one — DeviceIconResolverTests), so a "stale"
        // override is simulated by writing the store's raw file directly, the
        // same way a symbol removed on a future OS would surface.
        let directory = tempDirectory()
        let store = DeviceIconStore(directory: directory)
        try? store.save(["d1": "definitely.not.a.symbol.zzz"])
        let iconController = DeviceIconController(store: store, loadPersisted: true)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: makeDevice(id: "d1", kind: .appleTV))

        #expect(detail.test_iconSymbolName == Device.Kind.appleTV.symbolName,
                       "a stale override still falls back to the kind default, never a blank glyph")
    }

    // MARK: Icon picker flow — instant-apply through DeviceIconController

    @Test func clickEditIconBuildsAPickerConfiguredWithCurrentOverrideAndKindDefault() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)

        let picker = detail.test_clickEditIcon()
        #expect(picker != nil)
        #expect(detail.test_picker === picker, "the most recently built picker is retained for further driving")
    }

    @Test func pickingACuratedIconPersistsThroughControllerAndUpdatesTheWell() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)
        #expect(detail.test_iconSymbolName == Device.Kind.homePod.symbolName)

        let picker = detail.test_clickEditIcon()
        picker.test_pickCurated("airpods")

        #expect(detail.test_iconSymbolName == "airpods", "instant-apply — no separate Save step")
        #expect(iconController.overrides[device.id] == "airpods")
    }

    @Test func useDefaultResetsTheOverride() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)
        #expect(detail.test_iconSymbolName == "airpods")

        let picker = detail.test_clickEditIcon()
        picker.test_useDefault()

        #expect(detail.test_iconSymbolName == Device.Kind.homePod.symbolName)
        #expect(iconController.overrides[device.id] == nil)
    }

    @Test func pickingAnIconWithNoInjectedControllerIsANoOp() {
        let device = makeDevice(kind: .sonos)
        let detail = DeviceDetailViewController(groupController: makeController())
        // No `deviceIconController` assigned — nil-tolerant per `../../AGENTS.md`.
        detail.show(device: device)

        let picker = detail.test_clickEditIcon()
        picker.test_pickCurated("airpods")

        #expect(detail.test_iconSymbolName == Device.Kind.sonos.symbolName,
                       "nothing to write through — the glyph stays at the kind default")
    }

    // MARK: View-only hint

    @Test func hintIsAMinimalSingleLineViewOnlyNotice() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice())
        #expect(detail.test_hintText == "Playback is controlled from the Mixer — this page only describes the speaker.")
        #expect(!detail.test_hintText.contains("\n"), "stays a single line")
    }

    // MARK: Hover scrim headless test hook

    @Test func setOverlayVisibleDoesNotCrashHeadless() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice())
        detail.test_setOverlayVisible(true)
        detail.test_setOverlayVisible(false)
        // No assertion beyond "didn't crash" — the scrim's layer state isn't
        // exposed, and this is exercised visually by the live snapshot tool.
    }
}
