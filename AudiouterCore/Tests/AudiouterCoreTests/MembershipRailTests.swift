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
            return XCTFail("the origin hooks into the group's icon well, not a header dot")
        }
        // The hook is back on the ICON WELL. It hooked the TITLE while the
        // header stacked icon-over-name; now that the header is SIDE BY SIDE
        // the two share one horizontal band, so hooking the icon hooks the
        // name's line too — and the well is a fixed 64 pt tile rather than a
        // field whose width changes with the name it holds. The protocol is
        // ring-shaped because the popover's origin is a ring, so a rounded-rect
        // tile reports its inscribed circle and only the left edge is drawn to.
        XCTAssertEqual(ringRadius, DeviceIconWellView.size / 2, accuracy: 0.01)
        XCTAssertEqual(ringCenterX - ringRadius,
                       PopoverColumnGrid.firstElementLeading(indented: false), accuracy: 0.01,
                       "the hook lands on the well's LEFT edge, exactly at the content inset — " +
                       "measured in the OVERLAY's space, which is pinned to the column, not the pane")
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

    /// The editor pane has NO scroll view, so its fitting height is a hard
    /// budget — and the budget is NOT the window's height.
    ///
    /// This guard used to compare the pane against the whole 505 pt content
    /// height and passed while the pane was ~22 pt too tall to actually fit:
    /// the title bar (~32 pt — the window is `.fullSizeContentView`, so the
    /// pane starts at its SAFE AREA, not its top) and the persistent footer
    /// strip (~28 pt) both come out of that number first. At a 7-device fleet
    /// the bottom of the list and the "Delete group…" button fell below the
    /// window's edge with nothing to scroll them back.
    ///
    /// Every term is DERIVED from the real window, not typed in: the default
    /// content size the controller ships, the title-bar height measured off the
    /// live window, and the footer strip measured off the real host.
    func testEditorFitsTheHeightTheWindowActuallyGivesIt() throws {
        let devices = (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") }
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let group = try controller.createGroup(name: "Downstairs", memberIDs: ["d0"],
                                               memberVolumes: [:]).group

        let window = MixerWindowController(groupController: controller,
                                           frameAutosaveName: uniqueName("MembershipRailTests"))
        window.update(devices: devices)
        window.test_select(.group(id: group.id))

        let titleBar = window.test_titleBarHeight
        let footerStrip = window.test_contentPaneChromeHeight
        XCTAssertGreaterThan(titleBar, 0, "a titled window must report a real title-bar height")
        XCTAssertGreaterThan(footerStrip, 0, "the footer strip must cost real height")
        let available = MixerWindowController.defaultContentSize.height - titleBar - footerStrip

        let editor = GroupEditorViewController(groupController: controller)
        editor.loadView()
        editor.show(groupID: group.id, devices: devices)
        editor.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            editor.view.fittingSize.height, available,
            "a 7-device editor needs \(editor.view.fittingSize.height)pt but the window's default " +
            "gives the pane only \(available)pt (\(MixerWindowController.defaultContentSize.height) " +
            "− \(titleBar) title bar − \(footerStrip) footer). The pane has no scroll view, so this " +
            "is an overflow, not a preference.")
    }

    /// The same budget, from the other end: with the window at its shipping
    /// default and a full fleet selected, the pane it actually hands the editor
    /// must still hold the editor's laid-out content.
    func testDefaultWindowSizeIsWideEnoughThatNothingForcesItWider() throws {
        let devices = (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") }
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let group = try controller.createGroup(name: "Downstairs", memberIDs: ["d0"],
                                               memberVolumes: [:]).group
        let window = MixerWindowController(groupController: controller,
                                           frameAutosaveName: uniqueName("MembershipRailTests"))
        window.update(devices: devices)
        window.test_select(.group(id: group.id))
        window.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(window.window?.frame.width, MixerWindowController.defaultContentSize.width,
                       "no required content constraint may grow the window past its default width")
        XCTAssertEqual(window.window?.frame.height, MixerWindowController.defaultContentSize.height,
                       "…nor past its default height")
        let pane = window.test_editor.view.frame
        XCTAssertGreaterThan(pane.width, 0)
        XCTAssertLessThanOrEqual(window.test_editor.view.fittingSize.height, pane.height,
                                 "the editor's content fits the pane the split view gives it")
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
