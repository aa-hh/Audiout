// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
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
@Suite final class MembershipRailTests: IsolatedSuite {

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

    @Test func warmPaneNodeTracksIsChecked() {
        let row = makeRow(.warmPane, checked: false)
        #expect(row.test_busNode == .nonMember, "an unchecked row draws the hollow node")

        row.isChecked = true
        #expect(row.test_busNode == .member, "a checked row draws the filled gold node")

        row.isChecked = false
        #expect(row.test_busNode == .nonMember, "unchecking returns it to hollow")
    }

    @Test func warmPaneNodeFollowsAUserToggleAndAHostRefresh() {
        let row = makeRow(.warmPane, checked: false)

        // A user toggle (the real checkbox path).
        row.test_toggle()
        #expect(row.test_isChecked)
        #expect(row.test_busNode == .member, "the node follows a user toggle")

        // A host-driven refresh (`apply`) must re-derive it too.
        row.apply(device: makeDevice(id: "office", name: "Office"), checked: false)
        #expect(row.test_busNode == .nonMember, "the node follows a host refresh")
    }

    @Test func warmPaneNodeStaysAMemberWhenTheCheckboxIsPinned() {
        // The sole remaining member is pinned (disabled) so it can't be
        // unchecked into an empty group — but it IS still a member, so it keeps
        // the filled gold node rather than dropping to a greyed `.blocked` one.
        let row = makeRow(.warmPane, checked: true)
        row.setCheckboxEnabled(false, tooltip: "A group needs at least one device.")
        #expect(row.test_busNode == .member)
        #expect(!row.test_isCheckboxEnabled)
    }

    // MARK: The system sheet draws no node and no rail

    @Test func systemSheetRowDrawsNoNodeAndNoRail() {
        for checked in [true, false] {
            let row = makeRow(.systemSheet, checked: checked)
            #expect(row.test_surface == .systemSheet)
            #expect(row.test_busNode == nil, "no node is drawn on the Apple sheet")
            #expect(!row.test_hasBusNodeView, "no node view is even mounted")
            #expect(!row.test_hasInvisibleCheckboxSkin,
                    "the sheet keeps the STOCK checkbox drawing")
            #expect(row.railNode == nil, "it contributes no stop to any rail")
            #expect(row.test_nodeCenterX == nil)
        }
    }

    @Test func systemSheetIsTheDefaultSurface() {
        let row = MembershipRowView(device: makeDevice(id: "office", name: "Office"), checked: true)
        #expect(row.test_surface == .systemSheet,
                "stock rows are the default — the rail is opt-in per host")
    }

    @Test func creationSheetRowsAreAllPlain() {
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let sheet = GroupCreationSheetController(groupController: controller)
        sheet.loadView()
        sheet.configure(defaultName: "New Group",
                        devices: [makeDevice(id: "a", name: "A"), makeDevice(id: "b", name: "B")])
        sheet.test_setMembership(deviceID: "a", isChecked: true)

        let rows = sheet.view.descendantMembershipRows()
        #expect(rows.count == 2, "both rows were inspected")
        for row in rows {
            #expect(row.test_surface == .systemSheet)
            #expect(row.test_busNode == nil)
            #expect(!row.test_hasBusNodeView)
        }
    }

    // MARK: Accessibility survives the invisible cell

    @Test func voiceOverLabelsAreIdenticalOnBothSurfaces() {
        // Q2/A11Y: the checkbox becomes visually invisible, never functionally
        // absent. Its spoken label — and the row's — must be byte-identical to
        // the stock row's.
        for checked in [true, false] {
            let warm = makeRow(.warmPane, checked: checked)
            let sheet = makeRow(.systemSheet, checked: checked)

            #expect(warm.accessibilityLabel() == sheet.accessibilityLabel())
            #expect(warm.test_checkboxAccessibilityLabel
                    == sheet.test_checkboxAccessibilityLabel)
            #expect(warm.test_checkboxAccessibilityLabel
                    == (checked ? "Remove Office from group" : "Add Office to group"),
                    "the exact wording shipped before the rail landed")
        }
    }

    @Test func unavailableRowSpeaksTheSameOnBothSurfaces() {
        let offline = makeDevice(id: "office", name: "Office", available: false)
        let warm = MembershipRowView(device: offline, checked: true, surface: .warmPane)
        let sheet = MembershipRowView(device: offline, checked: true, surface: .systemSheet)
        #expect(warm.accessibilityLabel() == "Office, unavailable")
        #expect(warm.accessibilityLabel() == sheet.accessibilityLabel())
    }

    @Test func warmPaneCheckboxStaysARealOperableControl() {
        let row = makeRow(.warmPane, checked: false)
        #expect(row.test_hasInvisibleCheckboxSkin, "the warm row wears the invisible cell")
        #expect(row.test_isCheckboxEnabled, "it is still enabled/focusable, not decoration")

        var reported: (String, Bool)?
        row.onToggle = { reported = ($0, $1) }
        row.test_toggle()
        #expect(reported?.0 == "office")
        #expect(reported?.1 == true, "the real control's action path still fires")

        // A programmatic refresh must NOT fire the callback.
        reported = nil
        row.isChecked = false
        #expect(reported == nil)
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

    @Test func editorRowsCarryNodesMatchingMembership() throws {
        let (editor, _, _) = try makeEditor()
        #expect(editor.test_candidateDeviceIDs == ["a", "office", "c", "mixer", "e"])
        #expect(editor.test_railNodes
                == [.nonMember, .member, .nonMember, .member, .nonMember])
    }

    @Test func editorSignalEndsAtTheLowestCheckedRowInAFullBandChannel() throws {
        let (editor, _, _) = try makeEditor()
        let plan = try #require(editor.test_railPlan())
        // The channel runs the WHOLE candidate list — every row is a stop …
        #expect(plan.stops.count == 5, "every candidate row sits on the channel")
        // … while the signal inside it ends at `mixer` (index 3, the lowest
        // member); `echo` below it is a socket on an empty stretch of channel.
        #expect(plan.signalTerminusIndex == 3)
        #expect(plan.stops[3].node == .member)
        #expect(plan.grooveEndY < plan.stops[4].y,
                "the channel is milled past the last row's socket, not cut at the signal's end")
    }

    @Test func checkingALowerRowExtendsTheSignalDownToIt() throws {
        let (editor, _, _) = try makeEditor()
        let before = try #require(editor.test_railPlan())
        editor.test_setMembership(true, for: "e")
        let after = try #require(editor.test_railPlan())
        #expect(after.signalTerminusIndex == 4,
                "selecting the bottom row runs the signal down to reach it")
        #expect(editor.test_railNodes.last == .member)
        #expect(after.stops.count == before.stops.count,
                "the CHANNEL never changed — only how far the signal runs inside it")
        let padR = PopoverColumnGrid.railSocketPadRadius
        #expect(before.grooveEndY <= before.stops[4].y + padR + 0.01
                && after.grooveEndY <= after.stops[4].y + padR + 0.01,
                "…and it reaches the bottom row's socket whether or not that row is a member")
    }

    @Test func editorRailPlanResolvesFromTheIconWellOrigin() throws {
        let (editor, _, _) = try makeEditor()
        let plan = try #require(editor.test_railPlan(), "the rail resolves from live frames")

        guard case let .ring(centerY, ringCenterX, ringRadius) = plan.origin else {
            Issue.record("the origin hooks into the group's icon well, not a header dot")
            return
        }
        // The hook is back on the ICON WELL. It hooked the TITLE while the
        // header stacked icon-over-name; now that the header is SIDE BY SIDE
        // the two share one horizontal band, so hooking the icon hooks the
        // name's line too — and the well is a fixed 64 pt tile rather than a
        // field whose width changes with the name it holds. The protocol is
        // ring-shaped because the popover's origin is a ring, so a rounded-rect
        // tile reports its inscribed circle and only the left edge is drawn to.
        #expect(abs(ringRadius - DeviceIconWellView.size / 2) <= 0.01)
        // Tolerance is half a POINT, not 0.01: the plan resolves from LIVE
        // frames, and AppKit pixel-aligns them — a view tree that has never
        // been in a window resolves at integral alignment while one whose
        // process has touched a 2x-scale window context lands on half-point
        // boundaries. Under the full suite (shared process, AppKit suites run
        // first) the well's converted X came out exactly 0.5 off the isolated
        // value and Guard 4 refused unrelated commits (2026-08-07); ±0.5 still
        // pins "the hook lands on the well's LEFT edge at the content inset".
        #expect(abs((ringCenterX - ringRadius)
                    - PopoverColumnGrid.firstElementLeading(indented: false)) <= 0.5,
                Comment(rawValue: "the hook lands on the well's LEFT edge, at the content inset — " +
                "measured in the OVERLAY's space, which is pinned to the column, not the pane"))
        #expect(centerY > plan.railTopY, "the rail drops below the well's centre")

        // Five stops — every candidate row, member or not, sits on the channel.
        // Nothing cuts the rail short: this pane has no collapsible sections.
        #expect(plan.stops.count == 5)
        #expect(plan.stops.map(\.node)
                == [.nonMember, .member, .nonMember, .member, .nonMember])
        #expect(plan.terminusDotY == nil, "no collapsible section cuts the spine here")
        #expect(!plan.dormant, "membership has no dormant-divergent concept")
    }

    @Test func stopsRunTopToBottomInCandidateOrder() throws {
        let (editor, _, _) = try makeEditor()
        let plan = try #require(editor.test_railPlan())
        // Non-flipped coordinates: earlier candidates sit HIGHER (greater y).
        let ys = plan.stops.map(\.y)
        #expect(ys == ys.sorted(by: >), "stops are ordered down the pane")
        #expect(ys[0] < plan.railTopY, "every stop hangs below the origin hook")
    }

    @Test func activeGroupDrivesTheOriginHookTone() throws {
        let (editor, controller, devices) = try makeEditor()
        #expect(editor.test_railPlan()?.gold == false, "an inactive group's hook is ember")

        let group = try #require(controller.groups.first)
        controller.activateGroup(id: group.id)
        editor.show(groupID: group.id, devices: devices)
        editor.view.layoutSubtreeIfNeeded()
        #expect(editor.test_railPlan()?.gold == true,
                "the ACTIVE group's hook goes gold, like its icon well's ring")
    }

    /// The one geometry invariant that can break silently: `BusRailOverlayView`
    /// draws the spine at the literal `railGutterCenterX` in ITS coordinate
    /// space, while each row places its node at that x from the ROW's leading
    /// edge. If the two leading edges ever stop coinciding, the nodes float off
    /// the line and nothing else in the suite notices.
    @Test func everyNodeCentreLandsOnTheOverlaysGutterLine() throws {
        let (editor, _, _) = try makeEditor()
        for id in editor.test_candidateDeviceIDs {
            let x = try #require(editor.test_nodeCenterXInOverlaySpace(for: id))
            #expect(abs(x - PopoverColumnGrid.railGutterCenterX) <= 0.01,
                    "\(id)'s node must sit exactly on the drawn spine")
        }
    }

    @Test func nodeClearsTheIconColumn() {
        // The gutter reserve must keep the node — and the SOCKET it is seated in,
        // which is wider than any node — from crowding the glyph.
        let row = makeRow(.warmPane, checked: true)
        let nodeRightEdge = PopoverColumnGrid.railGutterCenterX
            + PopoverColumnGrid.railSocketPadRadius
        let iconLeading = PopoverColumnGrid.firstElementLeading(indented: false)
        #expect(iconLeading - nodeRightEdge > 8,
                "the node keeps clear negative space before the icon tile")
        #expect(abs((row.test_nodeCenterX ?? -1) - PopoverColumnGrid.railGutterCenterX) <= 0.01)
    }

    // MARK: Geometry cascade

    @Test func sevenDeviceFleetFitsTheCreationSheetWithoutScrolling() {
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let sheet = GroupCreationSheetController(groupController: controller)
        sheet.loadView()
        sheet.configure(defaultName: "New Group",
                        devices: (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") })
        sheet.view.layoutSubtreeIfNeeded()

        #expect(!sheet.test_checklistScrolls,
                "a 7-device fleet must not scroll in the create sheet")
    }

    /// The editor pane has NO scroll view, so its fitting height is a hard
    /// budget — and the budget is NOT the whole Groups screen's height.
    ///
    /// This guard used to compare the pane against the whole content height
    /// and passed while the pane was ~22 pt too tall to actually fit: the
    /// chrome above the pane and the persistent footer strip both come out of
    /// that number first. At a 7-device fleet the bottom of the list and the
    /// "Delete group…" button fell below the screen's edge with nothing to
    /// scroll them back. Under the one surface (U6) the budget is the Groups
    /// screen's content area — `AppSurfaceController.groupsDefaultContentSize`
    /// (already below the window's toolbar strip) minus the footer strip.
    ///
    /// Every term is DERIVED, not typed in: the surface's shipping constants
    /// and the footer strip measured off the real host.
    @Test func editorFitsTheHeightTheWindowActuallyGivesIt() throws {
        let devices = (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") }
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let group = try controller.createGroup(name: "Downstairs", memberIDs: ["d0"],
                                               memberVolumes: [:]).group

        let window = MixerWindowController(groupController: controller)
        window.setHostVisible(true)
        window.update(devices: devices)
        window.test_select(.group(id: group.id))

        // `groupsDefaultContentSize` is the content area BELOW the window's
        // toolbar strip (live-review D1), so only the footer subtracts.
        let footerStrip = window.test_contentPaneChromeHeight
        #expect(footerStrip > 0, "the footer strip must cost real height")
        let available = AppSurfaceController.groupsDefaultContentSize.height - footerStrip

        let editor = GroupEditorViewController(groupController: controller)
        editor.loadView()
        editor.show(groupID: group.id, devices: devices)
        editor.view.layoutSubtreeIfNeeded()

        #expect(
            editor.view.fittingSize.height <= available,
            Comment(rawValue: "a 7-device editor needs \(editor.view.fittingSize.height)pt but the Groups screen's default " +
            "gives the pane only \(available)pt (\(AppSurfaceController.groupsDefaultContentSize.height) " +
            "− \(footerStrip) footer). The pane has no scroll view, so this " +
            "is an overflow, not a preference."))
    }

    /// The same budget, from the other end: with the content laid out at the
    /// Groups screen's shipping content area and a full fleet selected, the
    /// pane the split view actually hands the editor must still hold the
    /// editor's laid-out content, and nothing may need more width than the
    /// screen provides.
    @Test func defaultWindowSizeIsWideEnoughThatNothingForcesItWider() throws {
        let devices = (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") }
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let group = try controller.createGroup(name: "Downstairs", memberIDs: ["d0"],
                                               memberVolumes: [:]).group
        let window = MixerWindowController(groupController: controller)
        window.setHostVisible(true)
        window.update(devices: devices)
        window.test_select(.group(id: group.id))
        let size = AppSurfaceController.groupsDefaultContentSize
        let content = window.contentController.view
        content.setFrameSize(size)
        content.layoutSubtreeIfNeeded()

        #expect(content.fittingSize.width <= size.width,
                "no required content constraint may need more than the screen's default width")
        let pane = window.test_editor.view.frame
        #expect(pane.width > 0)
        #expect(window.test_editor.view.fittingSize.height <= pane.height,
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
