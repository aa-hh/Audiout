// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
import Foundation
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// The group editor's membership rows: what a click lands on, and whether an
/// edit made there reaches the card overview.
@MainActor
struct GroupEditorClickTargetTests {
    private let isolation = TestIsolation(owner: "GroupEditorClickTargetTests")

    // Dropping absent IDs from candidates prevents removing missing members while retaining a nonempty scene.
    @Test func missingMemberRemovalKeepsFinalMemberAndVisibilitySeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = MockBackend(fleet: [])
        let groups = GroupController(backend: backend, store: GroupStore(directory: directory),
                                     routingStore: RoutingStore(directory: directory),
                                     settings: AppSettings(defaults: isolation.isolatedDefaults), loadPersisted: false)
        let bt = Device(id: "bt", name: "Bluetooth", kind: .bluetooth, isAvailable: false)
        let scene = Group(id: "g", name: "Scene", memberIDs: ["bt", "missing"], memberVolumes: [:])
        try groups.saveGroup(scene)
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [bt], groups: [scene])
        library.setVisibility(.hideWhenNotInUse, for: "bt")
        let pane = GroupEditorViewController(groupController: groups)
        pane.speakerLibrary = library
        pane.loadViewIfNeeded()
        pane.show(groupID: "g", devices: [bt])
        #expect(pane.test_candidateDeviceIDs.contains("missing"))
        #expect(pane.test_presentationText(for: "bt") == "Not connected")
        #expect(pane.test_reassuranceText == "Changes are saved as you go.")
        pane.test_setMembership(false, for: "missing")
        #expect(groups.groups.first?.memberIDs == ["bt"])
        #expect(library.visibility(for: "bt") == .hideWhenNotInUse)
        pane.test_setMembership(true, for: "missing")
        pane.test_setMembership(false, for: "bt")
        #expect(groups.groups.first?.memberIDs == ["missing"])
        #expect(!pane.test_isMembershipRowEnabled(for: "missing"))
        #expect(pane.test_deleteButtonVisible)
        pane.test_setMembership(false, for: "missing")
        #expect(groups.groups.first?.memberIDs == ["missing"])
        #expect(groups.activeGroupID == nil)
    }

    // Turns red when the membership row reads availability from discovery alone, dimming a connected Cast member or captioning it unavailable.
    @Test func connectedCastMemberUsesSharedAvailabilityInDrawnNode() throws {
        let device = Device(id: "cast", name: "Cast", kind: .cast, isAvailable: false,
                            connectionState: .connected)
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [device], groups: [])
        let row = MembershipRowView(device: device, checked: true, surface: .warmPane)
        row.applyPresentation(try #require(library.record(for: device.id)))
        #expect(!row.test_isDimmed)
        #expect(row.test_presentationText == "")
    }

    private func warmRow() -> MembershipRowView {
        let device = Device(id: "d1", name: "Speaker", kind: .sonos,
                            isAvailable: true, volume: 50)
        let row = MembershipRowView(device: device, checked: false, surface: .warmPane)
        row.frame = NSRect(x: 0, y: 0, width: 320, height: MembershipRowView.rowHeight)
        row.layoutSubtreeIfNeeded()
        return row
    }

    /// The rail node and the name are ONE click target (live report: the name
    /// toggled membership and the node looked dead). The invisible checkbox's
    /// own frame is narrower than the drawn disc, so a click aimed at the node
    /// used to land on the button or the row depending on a boundary the user
    /// cannot see. Every hit now resolves to the row, which runs the same
    /// `performToggle` the checkbox does.
    @Test func theNodeAndTheNameAreTheSameClickTarget() {
        let row = warmRow()
        let midY = row.bounds.midY
        let node = row.hitTest(NSPoint(x: PopoverColumnGrid.railGutterCenterX, y: midY))
        let name = row.hitTest(NSPoint(x: 200, y: midY))
        #expect(node === row, "a click on the rail node reaches the row")
        #expect(name === row, "so does a click on the name")
    }

    /// The stock sheet keeps AppKit's own hit-testing: its checkbox is visible
    /// and the row is not an affordance.
    @Test func theSystemSheetRowKeepsStockHitTesting() {
        let device = Device(id: "d1", name: "Speaker", kind: .sonos,
                            isAvailable: true, volume: 50)
        let row = MembershipRowView(device: device, checked: false, surface: .systemSheet)
        row.frame = NSRect(x: 0, y: 0, width: 320, height: MembershipRowView.rowHeight)
        row.layoutSubtreeIfNeeded()
        // Its checkbox sits at the leading edge and takes its own clicks.
        let hit = row.hitTest(NSPoint(x: 4, y: row.bounds.midY))
        #expect(hit is NSButton, "the stock row's visible checkbox is the click target")
    }
}
