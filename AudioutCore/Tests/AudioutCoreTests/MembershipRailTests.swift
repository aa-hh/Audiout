// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// The scene page uses membership nodes; the creation sheet keeps stock checkboxes.
/// These checks use laid-out views without showing windows or moving audio.
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
        // the filled gold node rather than dropping to a hollow `.nonMember` one.
        let row = makeRow(.warmPane, checked: true)
        row.setCheckboxEnabled(false, tooltip: "A group needs at least one device.")
        #expect(row.test_busNode == .member)
        #expect(!row.test_isCheckboxEnabled)
    }

    // MARK: The whole row is the click target (warm pane only)

    @Test func aRowClickTogglesMembershipExactlyOnce() {
        let row = makeRow(.warmPane, checked: false)
        var reported: [(String, Bool)] = []
        row.onToggle = { reported.append(($0, $1)) }

        row.test_clickRow()
        #expect(row.test_isChecked, "the body click flipped the real control")
        #expect(row.test_busNode == .member, "…and the node followed it")
        #expect(reported.count == 1, "one click, one report — never the checkbox's AND the row's")
        #expect(reported.first?.0 == "office")
        #expect(reported.first?.1 == true)

        row.test_clickRow()
        #expect(!row.test_isChecked, "a second click toggles back")
        #expect(reported.count == 2)
    }

    @Test func aPinnedRowRefusesARowClick() {
        // The sole remaining member's checkbox is honestly disabled, so the row
        // body must refuse the click too — otherwise the body is a way around
        // the "a group needs at least one device" rule.
        let row = makeRow(.warmPane, checked: true)
        row.setCheckboxEnabled(false, tooltip: "A group needs at least one device.")
        var fired = 0
        row.onToggle = { _, _ in fired += 1 }

        row.test_clickRow()
        #expect(fired == 0)
        #expect(row.test_isChecked, "it is still a member")
    }

    @Test func aSystemSheetRowIgnoresARowClick() {
        // The sheet's checkbox is VISIBLE, so the row is not an affordance —
        // stock behaviour, unchanged by the warm pane's whole-row target.
        let row = makeRow(.systemSheet, checked: false)
        var fired = 0
        row.onToggle = { _, _ in fired += 1 }

        row.test_clickRow()
        #expect(fired == 0)
        #expect(!row.test_isChecked)
    }

    // MARK: The hover resize — the row's "this is clickable" affordance

    @Test func hoveringAWarmRowPreviewsItsClick() {
        let row = makeRow(.warmPane, checked: false)
        #expect(!row.test_nodePreviewsClick, "resting size at rest")

        row.test_setHovered(true)
        #expect(row.test_nodePreviewsClick,
                "the whole row is clickable now, so a pointer anywhere on it previews the click")

        row.test_setHovered(false)
        #expect(!row.test_nodePreviewsClick)
    }

    @Test func aPinnedRowNeverResizesItself() {
        // A PINNED row keeps its `.member` node (it IS a member) — so the
        // refusal for that case has to come from the row's checkbox enablement,
        // not from `MembershipBusView`'s own node-based gate.
        let row = makeRow(.warmPane, checked: true)
        row.test_setHovered(true)
        #expect(row.test_nodePreviewsClick)

        row.setCheckboxEnabled(false, tooltip: "A group needs at least one device.")
        #expect(!row.test_nodePreviewsClick,
                "pinning happens under a stationary pointer — the invitation is withdrawn there")

        row.test_setHovered(true)
        #expect(!row.test_nodePreviewsClick, "and a fresh hover never revives it")
    }

    @Test func aSystemSheetRowNeverResizesANode() {
        let row = makeRow(.systemSheet, checked: true)
        row.test_setHovered(true)
        #expect(!row.test_nodePreviewsClick, "no node on the Apple sheet, so nothing to resize")
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
                                         routingStore: RoutingStore(directory: scratchDir),
                                         settings: AppSettings(defaults: isolatedDefaults),
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
                    == (checked ? "Remove Office from scene" : "Add Office to scene"),
                    "the exact wording shipped before the rail landed")
        }
    }

    /// The checkbox's VERB follows the toggle. It used to be written once, at
    /// build/refresh time, so a row toggled in place kept offering to "Add" a
    /// device it had just added.
    @Test func checkboxLabelFollowsTheToggle() {
        let row = makeRow(.warmPane, checked: false)
        #expect(row.test_checkboxAccessibilityLabel == "Add Office to scene")

        row.test_toggle()
        #expect(row.test_checkboxAccessibilityLabel == "Remove Office from scene",
                "a user toggle re-announces the verb")

        row.isChecked = false
        #expect(row.test_checkboxAccessibilityLabel == "Add Office to scene",
                "…and so does a host-driven refresh")
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

    // MARK: The scene page's membership rows

    /// A group editor showing `Downstairs` (members: `office`, `mixer`) over a
    /// five-device candidate list, laid out at a realistic pane size.
    private func makeEditor() throws -> (GroupEditorViewController, GroupController, [Device]) {
        let devices = [
            makeDevice(id: "a", name: "Alpha"),
            makeDevice(id: "office", name: "Bravo"),
            makeDevice(id: "c", name: "Charlie"),
            makeDevice(id: "mixer", name: "Delta"),
            makeDevice(id: "e", name: "Echo"),
        ]
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: scratchDir),
                                         settings: AppSettings(defaults: isolatedDefaults),
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

    // Removing membership state from the row node turns it red.
    @Test func editorRowsCarryNodesMatchingMembership() throws {
        let (editor, _, _) = try makeEditor()
        let nodes = try editor.test_candidateDeviceIDs.map { id in
            try #require(editor.test_membershipRow(for: id) as? MembershipRowView).test_busNode
        }
        #expect(nodes == [.nonMember, .member, .nonMember, .member, .nonMember])
    }







    // Tying membership node gold to scene activation turns it red.
    @Test func everyMembershipNodeIsArmedWithoutPlayback() throws {
        let (editor, controller, devices) = try makeEditor()
        func expectArmed() throws {
            for id in editor.test_candidateDeviceIDs {
                let row = try #require(editor.test_membershipRow(for: id) as? MembershipRowView)
                #expect(row.test_nodeArmed)
            }
        }
        try expectArmed()
        let group = try #require(controller.groups.first)
        controller.activateGroup(id: group.id)
        editor.show(groupID: group.id, devices: devices)
        try expectArmed()
    }



    @Test func aRowClickInTheEditorPersistsLikeACheckboxClick() throws {
        let (editor, controller, _) = try makeEditor()
        #expect(editor.test_checkedDeviceIDs == ["office", "mixer"])

        editor.test_clickRow(for: "a")
        #expect(editor.test_checkedDeviceIDs.contains("a"))
        let group = try #require(controller.groups.first)
        #expect(group.memberIDs.contains("a"),
                "the row body reaches the same save path the checkbox does")
    }

    @Test func hoveringAnEditorRowPreviewsItsClick() throws {
        let (editor, _, _) = try makeEditor()
        #expect(!editor.test_rowNodePreviewsClick(for: "a"))
        editor.test_setRowHovered(true, for: "a")
        #expect(editor.test_rowNodePreviewsClick(for: "a"))
        editor.test_setRowHovered(false, for: "a")
        #expect(!editor.test_rowNodePreviewsClick(for: "a"))
    }

    // Dropping the hover wash or drawing it on a pinned row turns it red.
    @Test func hoverWashRequiresAnEnabledRow() throws {
        let row = makeRow(.warmPane, checked: true)
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 32)
        row.layoutSubtreeIfNeeded()
        func sampledAlpha() throws -> CGFloat {
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = try #require(NSGraphicsContext(bitmapImageRep: rep))
            NSColor.clear.setFill()
            row.bounds.fill(using: .copy)
            row.draw(row.bounds)
            return try #require(rep.colorAt(x: 280, y: 16)).alphaComponent
        }
        #expect(try sampledAlpha() == 0)
        row.test_setHovered(true)
        #expect(try sampledAlpha() > 0.05)
        row.setCheckboxEnabled(false, tooltip: "A scene needs at least one speaker.")
        #expect(try sampledAlpha() == 0)
    }

    // MARK: The reassurance line

    // Adding playback-dependent text to the reassurance line turns it red.
    @Test func theReassuranceLineNeverMentionsPlayback() throws {
        let (editor, controller, devices) = try makeEditor()
        #expect(editor.test_reassuranceText == "Changes are saved as you go.")
        let group = try #require(controller.groups.first)
        controller.activateGroup(id: group.id)
        editor.show(groupID: group.id, devices: devices)
        #expect(editor.test_reassuranceText == "Changes are saved as you go.")
    }





    @Test func pinnedSoleMemberExplanationReachesVoiceOver() {
        // The tooltip alone is not reliably announced; the "why is this
        // disabled" line must travel as accessibilityHelp too.
        let row = makeRow(.warmPane, checked: true)
        row.setCheckboxEnabled(false, tooltip: "A group needs at least one device.")
        #expect(row.test_checkboxAccessibilityHelp == "A group needs at least one device.")
    }


    @Test func nodeClearsTheIconColumn() {
        // The gutter reserve must keep the node — at the widest it ever draws,
        // the size a hovered non-member grows into — from crowding the glyph.
        let row = makeRow(.warmPane, checked: true)
        let nodeRightEdge = PopoverColumnGrid.railGutterCenterX
            + PopoverColumnGrid.busNodeDiameterSelected / 2
        let iconLeading = PopoverColumnGrid.firstElementLeading(indented: false)
        #expect(iconLeading - nodeRightEdge > 8,
                "the node keeps clear negative space before the icon tile")
        #expect(abs((row.test_nodeCenterX ?? -1) - PopoverColumnGrid.railGutterCenterX) <= 0.01)
    }

    // MARK: Geometry cascade

    @Test func sevenDeviceFleetFitsTheCreationSheetWithoutScrolling() {
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: scratchDir),
                                         settings: AppSettings(defaults: isolatedDefaults),
                                         loadPersisted: false)
        let sheet = GroupCreationSheetController(groupController: controller)
        sheet.loadView()
        sheet.configure(defaultName: "New Group",
                        devices: (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") })
        sheet.view.layoutSubtreeIfNeeded()

        #expect(!sheet.test_checklistScrolls,
                "a 7-device fleet must not scroll in the create sheet")
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
