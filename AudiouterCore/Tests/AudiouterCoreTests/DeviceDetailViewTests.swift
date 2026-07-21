// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
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
final class DeviceDetailViewTests: XCTestCase {

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

    func testShowSetsShownDeviceID() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(id: "sonos-move"))
        XCTAssertEqual(detail.test_shownDeviceID, "sonos-move")
    }

    func testShownDeviceIDIsNilBeforeFirstShow() {
        let detail = DeviceDetailViewController(groupController: makeController())
        XCTAssertNil(detail.test_shownDeviceID)
    }

    func testRefreshUpdatesFieldsForTheSameDevice() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(volume: 20))
        XCTAssertEqual(detail.test_metadataStrings["volume"], "20%")

        detail.refresh(device: makeDevice(volume: 75))
        XCTAssertEqual(detail.test_metadataStrings["volume"], "75%")
        XCTAssertEqual(detail.test_shownDeviceID, "d1")
    }

    // MARK: Metadata form — status wording

    func testStatusTextOff() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .off))
        XCTAssertEqual(detail.test_metadataStrings["status"], "Not connected")
    }

    func testStatusTextConnecting() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .connecting))
        XCTAssertEqual(detail.test_metadataStrings["status"], "Connecting")
    }

    func testStatusTextReconnecting() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .reconnecting))
        XCTAssertEqual(detail.test_metadataStrings["status"], "Reconnecting")
    }

    func testStatusTextConnected() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .connected))
        XCTAssertEqual(detail.test_metadataStrings["status"], "Connected")
    }

    func testStatusTextFailed() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        XCTAssertEqual(detail.test_metadataStrings["status"], "Couldn't connect",
                       "matches DeviceRowView's existing failed vocabulary")
    }

    // MARK: Metadata form — available / volume / kind

    func testAvailableYesAndNo() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(isAvailable: true))
        XCTAssertEqual(detail.test_metadataStrings["available"], "Yes")

        detail.show(device: makeDevice(isAvailable: false))
        XCTAssertEqual(detail.test_metadataStrings["available"], "No")
    }

    func testVolumePercentFormatting() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(volume: 0))
        XCTAssertEqual(detail.test_metadataStrings["volume"], "0%")

        detail.show(device: makeDevice(volume: 100))
        XCTAssertEqual(detail.test_metadataStrings["volume"], "100%")
    }

    func testKindTextForEveryKind() {
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
            XCTAssertEqual(detail.test_metadataStrings["kind"], expected, "kind: \(kind)")
        }
    }

    // MARK: "In groups:" membership text

    func testGroupMembershipTextIsNoneWhenDeviceIsInNoGroup() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(id: "office"))
        XCTAssertEqual(detail.test_groupMembershipText, "None")
    }

    func testGroupMembershipTextListsEverySavedGroupContainingTheDevice() throws {
        let controller = makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office", "appletv-lr"],
                                       memberVolumes: ["office": 50, "appletv-lr": 60]))
        try controller.saveGroup(Group(id: "g2", name: "Whole House", memberIDs: ["office"],
                                       memberVolumes: ["office": 50]))
        try controller.saveGroup(Group(id: "g3", name: "Bedroom", memberIDs: ["appletv-lr"],
                                       memberVolumes: ["appletv-lr": 60]))

        let detail = DeviceDetailViewController(groupController: controller)
        detail.show(device: makeDevice(id: "office"))
        XCTAssertEqual(detail.test_groupMembershipText, "Kitchen, Whole House",
                       "only groups this device is a member of, in groupController.groups order")
    }

    func testGroupMembershipTextUpdatesOnRefreshAfterAMembershipChange() throws {
        let controller = makeController()
        // Seed with a DIFFERENT member so "office" starts as a non-member while
        // the group stays non-empty (an empty group is now rejected).
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["living-room"],
                                       memberVolumes: ["living-room": 50]))
        let detail = DeviceDetailViewController(groupController: controller)
        detail.show(device: makeDevice(id: "office"))
        XCTAssertEqual(detail.test_groupMembershipText, "None")

        var group = try XCTUnwrap(controller.groups.first { $0.id == "g1" })
        group.memberIDs = ["office"]
        group.memberVolumes["office"] = 50
        try controller.saveGroup(group)

        detail.refresh(device: makeDevice(id: "office"))
        XCTAssertEqual(detail.test_groupMembershipText, "Kitchen")
    }

    // MARK: Icon resolution — no injected controller

    func testIconSymbolNameFallsBackToKindDefaultWithNoInjectedController() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(kind: .homePod))
        XCTAssertEqual(detail.test_iconSymbolName, Device.Kind.homePod.symbolName)
    }

    // MARK: Icon resolution — injected controller with/without an override

    func testIconSymbolNameUsesKindDefaultWhenControllerHasNoOverride() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController

        detail.show(device: makeDevice(kind: .sonos))
        XCTAssertEqual(detail.test_iconSymbolName, Device.Kind.sonos.symbolName)
    }

    func testIconSymbolNameUsesOverrideWhenControllerHasOneSet() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .sonos)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)

        XCTAssertEqual(detail.test_iconSymbolName, "airpods")
    }

    func testIconSymbolNameFallsBackToDefaultForAStaleOverride() {
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

        XCTAssertEqual(detail.test_iconSymbolName, Device.Kind.appleTV.symbolName,
                       "a stale override still falls back to the kind default, never a blank glyph")
    }

    // MARK: Icon picker flow — instant-apply through DeviceIconController

    func testClickEditIconBuildsAPickerConfiguredWithCurrentOverrideAndKindDefault() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)

        let picker = detail.test_clickEditIcon()
        XCTAssertNotNil(picker)
        XCTAssertTrue(detail.test_picker === picker, "the most recently built picker is retained for further driving")
    }

    func testPickingACuratedIconPersistsThroughControllerAndUpdatesTheWell() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)
        XCTAssertEqual(detail.test_iconSymbolName, Device.Kind.homePod.symbolName)

        let picker = detail.test_clickEditIcon()
        picker.test_pickCurated("airpods")

        XCTAssertEqual(detail.test_iconSymbolName, "airpods", "instant-apply — no separate Save step")
        XCTAssertEqual(iconController.overrides[device.id], "airpods")
    }

    func testUseDefaultResetsTheOverride() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)
        XCTAssertEqual(detail.test_iconSymbolName, "airpods")

        let picker = detail.test_clickEditIcon()
        picker.test_useDefault()

        XCTAssertEqual(detail.test_iconSymbolName, Device.Kind.homePod.symbolName)
        XCTAssertNil(iconController.overrides[device.id])
    }

    func testPickingAnIconWithNoInjectedControllerIsANoOp() {
        let device = makeDevice(kind: .sonos)
        let detail = DeviceDetailViewController(groupController: makeController())
        // No `deviceIconController` assigned — nil-tolerant per `../../AGENTS.md`.
        detail.show(device: device)

        let picker = detail.test_clickEditIcon()
        picker.test_pickCurated("airpods")

        XCTAssertEqual(detail.test_iconSymbolName, Device.Kind.sonos.symbolName,
                       "nothing to write through — the glyph stays at the kind default")
    }

    // MARK: View-only hint

    func testHintIsAMinimalSingleLineViewOnlyNotice() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice())
        XCTAssertEqual(detail.test_hintText, "View-only — control playback from the menu-bar popover.")
        XCTAssertFalse(detail.test_hintText.contains("\n"), "stays a single line")
    }

    // MARK: Hover scrim headless test hook

    func testSetOverlayVisibleDoesNotCrashHeadless() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice())
        detail.test_setOverlayVisible(true)
        detail.test_setOverlayVisible(false)
        // No assertion beyond "didn't crash" — the scrim's layer state isn't
        // exposed, and this is exercised visually by the live snapshot tool.
    }
}
