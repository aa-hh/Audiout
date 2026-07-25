// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// Warm Signal v4 §Call-1 applied to the Groups window's membership checklist
/// (T6): `MembershipRowView` wears the rail/node language on the WARM pane (the
/// group editor) and stays a plain stock checkbox row on the SYSTEM sheet ("New
/// Group") — Alec's Q6 call, because `ember` measures ~2.34–2.48:1 on the
/// sheet's white and the node would be near-invisible there.
///
/// These are structural/geometric assertions against real laid-out frames — no
/// audio, no window, no synthesized clicks.
@MainActor
final class MembershipRailTests: IsolatedTestCase {

    private func tempDirectory() -> URL {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDevice(id: String, name: String, available: Bool = true) -> Device {
        Device(id: id, name: name, kind: .generic, isAvailable: available)
    }

    private func makeRow(_ surface: MembershipRowView.Surface, checked: Bool) -> MembershipRowView {
        let row = MembershipRowView(device: makeDevice(id: "office", name: "Office"),
                                    checked: checked, surface: surface)
        row.layoutSubtreeIfNeeded()
        return row
    }

    // MARK: Node kind tracks membership (warm pane)

    func testWarmPaneNodeTracksIsChecked() {
        let row = makeRow(.warmPane, checked: false)
        XCTAssertEqual(row.test_busNode, .nonMember, "an unchecked row draws the hollow node")

        row.isChecked = true
        XCTAssertEqual(row.test_busNode, .member, "a checked row draws the filled gold node")

        row.isChecked = false
        XCTAssertEqual(row.test_busNode, .nonMember, "unchecking returns it to hollow")
    }

    func testWarmPaneNodeFollowsAUserToggleAndAHostRefresh() {
        let row = makeRow(.warmPane, checked: false)

        // A user toggle (the real checkbox path).
        row.test_toggle()
        XCTAssertTrue(row.test_isChecked)
        XCTAssertEqual(row.test_busNode, .member, "the node follows a user toggle")

        // A host-driven refresh (`apply`) must re-derive it too.
        row.apply(device: makeDevice(id: "office", name: "Office"), checked: false)
        XCTAssertEqual(row.test_busNode, .nonMember, "the node follows a host refresh")
    }

    func testWarmPaneNodeStaysAMemberWhenTheCheckboxIsPinned() {
        // The sole remaining member is pinned (disabled) so it can't be
        // unchecked into an empty group — but it IS still a member, so it keeps
        // the filled gold node rather than dropping to a greyed `.blocked` one.
        let row = makeRow(.warmPane, checked: true)
        row.setCheckboxEnabled(false, tooltip: "A group needs at least one device.")
        XCTAssertEqual(row.test_busNode, .member)
        XCTAssertFalse(row.test_isCheckboxEnabled)
    }

    // MARK: The system sheet draws no node and no rail

    func testSystemSheetRowDrawsNoNodeAndNoRail() {
        for checked in [true, false] {
            let row = makeRow(.systemSheet, checked: checked)
            XCTAssertEqual(row.test_surface, .systemSheet)
            XCTAssertNil(row.test_busNode, "no node is drawn on the Apple sheet")
            XCTAssertFalse(row.test_hasBusNodeView, "no node view is even mounted")
            XCTAssertFalse(row.test_hasInvisibleCheckboxSkin,
                           "the sheet keeps the STOCK checkbox drawing")
            XCTAssertNil(row.railNode, "it contributes no stop to any rail")
            XCTAssertFalse(row.railHasSpine, "and never claims to be inside a spine")
            XCTAssertNil(row.test_nodeCenterX)
        }
    }

    func testSystemSheetIsTheDefaultSurface() {
        let row = MembershipRowView(device: makeDevice(id: "office", name: "Office"), checked: true)
        XCTAssertEqual(row.test_surface, .systemSheet,
                       "stock rows are the default — the rail is opt-in per host")
    }

    func testCreationSheetRowsAreAllPlain() {
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let sheet = GroupCreationSheetController(groupController: controller)
        sheet.loadView()
        sheet.configure(defaultName: "New Group",
                        devices: [makeDevice(id: "a", name: "A"), makeDevice(id: "b", name: "B")])
        sheet.test_setMembership(deviceID: "a", isChecked: true)

        let rows = sheet.view.descendantMembershipRows()
        XCTAssertEqual(rows.count, 2, "both rows were inspected")
        for row in rows {
            XCTAssertEqual(row.test_surface, .systemSheet)
            XCTAssertNil(row.test_busNode)
            XCTAssertFalse(row.test_hasBusNodeView)
        }
    }

    // MARK: Accessibility survives the invisible cell

    func testVoiceOverLabelsAreIdenticalOnBothSurfaces() {
        // Q2/A11Y: the checkbox becomes visually invisible, never functionally
        // absent. Its spoken label — and the row's — must be byte-identical to
        // the stock row's.
        for checked in [true, false] {
            let warm = makeRow(.warmPane, checked: checked)
            let sheet = makeRow(.systemSheet, checked: checked)

            XCTAssertEqual(warm.accessibilityLabel(), sheet.accessibilityLabel())
            XCTAssertEqual(warm.test_checkboxAccessibilityLabel,
                           sheet.test_checkboxAccessibilityLabel)
            XCTAssertEqual(warm.test_checkboxAccessibilityLabel,
                           checked ? "Remove Office from group" : "Add Office to group",
                           "the exact wording shipped before the rail landed")
        }
    }

    func testUnavailableRowSpeaksTheSameOnBothSurfaces() {
        let offline = makeDevice(id: "office", name: "Office", available: false)
        let warm = MembershipRowView(device: offline, checked: true, surface: .warmPane)
        let sheet = MembershipRowView(device: offline, checked: true, surface: .systemSheet)
        XCTAssertEqual(warm.accessibilityLabel(), "Office, unavailable")
        XCTAssertEqual(warm.accessibilityLabel(), sheet.accessibilityLabel())
    }

    func testWarmPaneCheckboxStaysARealOperableControl() {
        let row = makeRow(.warmPane, checked: false)
        XCTAssertTrue(row.test_hasInvisibleCheckboxSkin, "the warm row wears the invisible cell")
        XCTAssertTrue(row.test_isCheckboxEnabled, "it is still enabled/focusable, not decoration")

        var reported: (String, Bool)?
        row.onToggle = { reported = ($0, $1) }
        row.test_toggle()
        XCTAssertEqual(reported?.0, "office")
        XCTAssertEqual(reported?.1, true, "the real control's action path still fires")

        // A programmatic refresh must NOT fire the callback.
        reported = nil
        row.isChecked = false
        XCTAssertNil(reported)
    }

    // MARK: The editor's pane-level rail

    /// A group editor showing `Downstairs` (members: `office`, `mixer`) over a
    /// five-device candidate list, laid out at a realistic pane size.
    private func makeEditor() throws -> (GroupEditorViewController, GroupController, [Device]) {
        let devices = [
            makeDevice(id: "a", name: "Alpha"),
            makeDevice(id: "office", name: "Office"),
            makeDevice(id: "c", name: "Charlie"),
            makeDevice(id: "mixer", name: "Mixer"),
            makeDevice(id: "e", name: "Echo"),
        ]
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let group = try controller.createGroup(name: "Downstairs",
                                               memberIDs: ["office", "mixer"],
                                               memberVolumes: [:]).group
        let editor = GroupEditorViewController(groupController: controller)
        editor.loadView()
        editor.show(groupID: group.id, devices: devices)
        editor.view.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        editor.view.layoutSubtreeIfNeeded()
        return (editor, controller, devices)
    }

    func testEditorRowsCarryNodesMatchingMembership() throws {
        let (editor, _, _) = try makeEditor()
        XCTAssertEqual(editor.test_candidateDeviceIDs, ["a", "office", "c", "mixer", "e"])
        XCTAssertEqual(editor.test_railNodes,
                       [.nonMember, .member, .nonMember, .member, .nonMember])
    }

    func testEditorRailTerminatesAtTheLowestCheckedRow() throws {
        let (editor, _, _) = try makeEditor()
        // Spine runs a…mixer (index 3, the lowest member); `echo` sits below the
        // terminus as a BARE node with no rail through it.
        XCTAssertEqual(editor.test_railExtents.map(\.above), [true, true, true, true, false])
        XCTAssertEqual(editor.test_railExtents.map(\.below), [true, true, true, false, false])
    }

    func testCheckingALowerRowExtendsTheSpineDownToIt() throws {
        let (editor, _, _) = try makeEditor()
        editor.test_setMembership(true, for: "e")
        XCTAssertEqual(editor.test_railExtents.map(\.above), [true, true, true, true, true],
                       "selecting a row below the terminus extends the spine to reach it")
        XCTAssertEqual(editor.test_railExtents.map(\.below), [true, true, true, true, false])
        XCTAssertEqual(editor.test_railNodes.last, .member)
    }

    func testEditorRailPlanResolvesFromTheIconWellOrigin() throws {
        let (editor, _, _) = try makeEditor()
        let plan = try XCTUnwrap(editor.test_railPlan(), "the rail resolves from live frames")

        guard case let .ring(centerY, ringCenterX, ringRadius) = plan.origin else {
            return XCTFail("the origin hooks into the group icon well, not a header dot")
        }
        XCTAssertEqual(ringRadius, DeviceIconWellView.size / 2, accuracy: 0.01)
        XCTAssertEqual(ringCenterX - ringRadius,
                       PopoverColumnGrid.firstElementLeading(indented: false), accuracy: 0.5,
                       "the hook leaves the well's LEFT edge, which sits at the content inset")
        XCTAssertGreaterThan(centerY, plan.railTopY, "the rail drops below the well's centre")

        // Four in-span stops (a, office, c, mixer); `echo` is bare, so it
        // contributes no stop. Nothing cuts the rail short — this pane has no
        // collapsible sections.
        XCTAssertEqual(plan.stops.count, 4)
        XCTAssertEqual(plan.stops.map(\.node), [.nonMember, .member, .nonMember, .member])
        XCTAssertEqual(plan.stops.map(\.below), [true, true, true, false])
        XCTAssertNil(plan.terminusDotY, "no collapsible section cuts the spine here")
        XCTAssertFalse(plan.stops.contains { $0.dimmed }, "membership has no dormant tint")
    }

    func testStopsRunTopToBottomInCandidateOrder() throws {
        let (editor, _, _) = try makeEditor()
        let plan = try XCTUnwrap(editor.test_railPlan())
        // Non-flipped coordinates: earlier candidates sit HIGHER (greater y).
        let ys = plan.stops.map(\.y)
        XCTAssertEqual(ys, ys.sorted(by: >), "stops are ordered down the pane")
        XCTAssertLessThan(ys[0], plan.railTopY, "every stop hangs below the origin hook")
    }

    func testActiveGroupDrivesTheOriginHookTone() throws {
        let (editor, controller, devices) = try makeEditor()
        XCTAssertEqual(editor.test_railPlan()?.gold, false, "an inactive group's hook is ember")

        let group = try XCTUnwrap(controller.groups.first)
        controller.activateGroup(id: group.id)
        editor.show(groupID: group.id, devices: devices)
        editor.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.test_railPlan()?.gold, true,
                       "the ACTIVE group's hook goes gold, like its icon well's ring")
    }

    /// The one geometry invariant that can break silently: `BusRailOverlayView`
    /// draws the spine at the literal `railGutterCenterX` in ITS coordinate
    /// space, while each row places its node at that x from the ROW's leading
    /// edge. If the two leading edges ever stop coinciding, the nodes float off
    /// the line and nothing else in the suite notices.
    func testEveryNodeCentreLandsOnTheOverlaysGutterLine() throws {
        let (editor, _, _) = try makeEditor()
        for id in editor.test_candidateDeviceIDs {
            let x = try XCTUnwrap(editor.test_nodeCenterXInOverlaySpace(for: id))
            XCTAssertEqual(x, PopoverColumnGrid.railGutterCenterX, accuracy: 0.01,
                           "\(id)'s node must sit exactly on the drawn spine")
        }
    }

    func testNodeClearsTheIconColumn() {
        // The gutter reserve must keep the node from crowding the glyph.
        let row = makeRow(.warmPane, checked: true)
        let nodeRightEdge = PopoverColumnGrid.railGutterCenterX
            + PopoverColumnGrid.busNodeDiameterSelected / 2
        let iconLeading = PopoverColumnGrid.firstElementLeading(indented: false)
        XCTAssertGreaterThan(iconLeading - nodeRightEdge, 8,
                             "the node keeps clear negative space before the icon tile")
        XCTAssertEqual(row.test_nodeCenterX ?? -1,
                       PopoverColumnGrid.railGutterCenterX, accuracy: 0.01)
    }

    // MARK: Geometry cascade

    func testSevenDeviceFleetFitsTheCreationSheetWithoutScrolling() {
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let sheet = GroupCreationSheetController(groupController: controller)
        sheet.loadView()
        sheet.configure(defaultName: "New Group",
                        devices: (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") })
        sheet.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(sheet.test_checklistScrolls,
                       "a 7-device fleet must not scroll in the create sheet")
    }

    func testEditorStillFitsTheGroupsWindowDefaultHeight() throws {
        // `MixerWindowController` opens at 720×460 and the editor pane has no
        // scroll view, so its fitting height is a hard budget. A 7-device fleet
        // is the demo fleet AND a realistic household ceiling.
        let devices = (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") }
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let group = try controller.createGroup(name: "Downstairs", memberIDs: ["d0"],
                                               memberVolumes: [:]).group
        let editor = GroupEditorViewController(groupController: controller)
        editor.loadView()
        editor.show(groupID: group.id, devices: devices)
        editor.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(editor.view.fittingSize.height, 460,
                                 "the editor must still fit the window's default content height")
    }
}

private extension NSView {
    /// Every `MembershipRowView` in this view's subtree.
    func descendantMembershipRows() -> [MembershipRowView] {
        subviews.flatMap { view -> [MembershipRowView] in
            if let row = view as? MembershipRowView { return [row] }
            return view.descendantMembershipRows()
        }
    }
}
