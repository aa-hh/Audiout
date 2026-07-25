// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// T3 — regression lock for a deliberate, DOCUMENTED decision (screens-followup
/// batch, 2026-07-25): the Groups window keeps Apple's stock semantic text
/// colors (`labelColor`/`secondaryLabelColor`/`tertiaryLabelColor`/
/// `disabledControlTextColor`/`controlTextColor`) on every label, EVERYWHERE,
/// even though light-mode secondary text measures ~3.91:1 and tertiary ~1.87:1
/// against the warm pane — both under common readability floors. Alec accepted
/// that debt in exchange for simplicity and zero regression risk: surfaces
/// (`Tokens.Color.well`/`.hairline`, T5) carry the separation instead of text
/// color. This is easy for a future "helpful" contrast pass to quietly undo by
/// repointing a Groups-window label at a warm `Tokens.Color` token — this file
/// makes that change fail a test instead of merging silently.
///
/// Two halves, matching the deal:
///   1. NEGATIVE — every label actually rendered by the Groups window
///      (`DeviceDetailViewController`, `MembershipRowView`,
///      `SidebarViewController`'s outline cells, `GroupEditorViewController`,
///      `MixerWindowController`/`GroupsEmptyStateViewController`,
///      `IconPickerViewController`, `GroupCreationSheetController`) resolves to
///      a stock system color and NEVER to a warm palette token.
///   2. POSITIVE — `GroupEditorViewController`'s membership checklist (T5)
///      really does paint its recessed background and divider in
///      `Tokens.Color.well`/`.hairline` — surfaces changed, text didn't.
///
/// Deliberately exercises real production view/controller instances (their
/// public `init`s, `show`/`apply` methods, and — for the sidebar — the actual
/// `NSOutlineViewDataSource` delegate method) rather than re-typing the
/// expected colors into a parallel fixture, so a call-site edit anywhere in
/// these seven files is caught the same way a real screenshot would catch it.
@MainActor
final class GroupsWindowTextColorLockTests: IsolatedTestCase {

    // MARK: WCAG-adjacent color-identity helpers (mirrors `NoTintOnRingsOrMetersGuardTests`/
    // `ControlPanelBackingViewTests`' resolved-component-comparison idiom)

    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor? {
        var result: NSColor?
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return result
    }

    private func sameColor(_ a: NSColor?, _ b: NSColor?, tolerance: CGFloat = 0.01) -> Bool {
        guard let a, let b else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    /// The full warm palette (every `Tokens.Color` case added since the
    /// design-system-redesign, per `Tokens.swift`'s "Warm Signal custom
    /// palette" section) — NONE of these may ever back a Groups-window label.
    private var warmTokens: [(name: String, color: NSColor)] {
        [
            ("canvas", Tokens.Color.canvas),
            ("canvasHi", Tokens.Color.canvasHi),
            ("panel", Tokens.Color.panel),
            ("raised", Tokens.Color.raised),
            ("well", Tokens.Color.well),
            ("hairline", Tokens.Color.hairline),
            ("meterTrack", Tokens.Color.meterTrack),
            ("sidebarWarmTint", Tokens.Color.sidebarWarmTint),
            ("ringConnected", Tokens.Color.ringConnected),
            ("failure", Tokens.Color.failure),
            ("gold", Tokens.Color.gold),
            ("ember", Tokens.Color.ember),
            ("caution", Tokens.Color.caution),
            ("glow", Tokens.Color.glow),
            ("dotSocket", Tokens.Color.dotSocket),
            ("faderThumb", Tokens.Color.faderThumb),
            ("faderRim", Tokens.Color.faderRim),
        ]
    }

    /// The stock AppKit semantics the locked decision allows. `controlTextColor`
    /// is included because plain unstyled `NSTextField`s (e.g. an editable name
    /// field nobody explicitly re-colors) default to it — still a stock system
    /// semantic, still within the deal.
    private var stockSemantics: [(name: String, color: NSColor)] {
        [
            ("labelColor", .labelColor),
            ("secondaryLabelColor", .secondaryLabelColor),
            ("tertiaryLabelColor", .tertiaryLabelColor),
            ("quaternaryLabelColor", .quaternaryLabelColor),
            ("disabledControlTextColor", .disabledControlTextColor),
            ("controlTextColor", .controlTextColor),
        ]
    }

    /// Assert `color` (as actually resolved off a live label in the Groups
    /// window) is a stock semantic and never a warm token, in BOTH
    /// appearances. This is the enforcement point: it fails loudly and names
    /// the frozen decision so whoever breaks it understands why it's here.
    private func assertFrozenToStock(_ color: NSColor?, _ label: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        guard let color else {
            return XCTFail("\(label): no textColor to check", file: file, line: line)
        }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let resolvedColor = resolved(color, appearanceName: appearanceName) else {
                return XCTFail("\(label): color did not resolve under \(appearanceName.rawValue)",
                               file: file, line: line)
            }

            let matchesStock = stockSemantics.contains {
                sameColor(resolvedColor, resolved($0.color, appearanceName: appearanceName))
            }
            XCTAssertTrue(matchesStock,
                "\(label) is not a stock AppKit semantic color under \(appearanceName.rawValue). " +
                "Groups-window text colors are FROZEN to stock AppKit greys (screens-followup " +
                "contrast decision, 2026-07-25) — separation comes from surfaces (T5's well/" +
                "hairline), never from recoloring text. Do not repoint this label to a warm " +
                "Tokens.Color token.", file: file, line: line)

            for warm in warmTokens {
                let resolvedWarm = resolved(warm.color, appearanceName: appearanceName)
                XCTAssertFalse(sameColor(resolvedColor, resolvedWarm),
                    "\(label) matches the warm token Tokens.Color.\(warm.name) under " +
                    "\(appearanceName.rawValue) — Groups-window text colors must stay stock " +
                    "AppKit greys (screens-followup contrast decision, 2026-07-25); do not " +
                    "repoint text to a warm palette token.", file: file, line: line)
            }
        }
    }

    /// Recursively collect every `NSTextField` in `view`'s subtree — catches a
    /// label whether it's a named stored property or built inline (e.g.
    /// `DeviceDetailViewController`'s per-row caption labels), and reads
    /// exactly what a real screenshot would show, not a re-typed expectation.
    private func allTextFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        if let field = view as? NSTextField { result.append(field) }
        for sub in view.subviews { result.append(contentsOf: allTextFields(in: sub)) }
        return result
    }

    private func assertAllLabelsFrozen(in view: NSView, host: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let fields = allTextFields(in: view)
        XCTAssertFalse(fields.isEmpty, "\(host): expected at least one label to check", file: file, line: line)
        for field in fields {
            assertFrozenToStock(field.textColor, "\(host) label \"\(field.stringValue)\"",
                                file: file, line: line)
        }
    }

    // MARK: Fixtures

    private func makeDevice(id: String = "dev-1", name: String = "Kitchen", isAvailable: Bool = true) -> Device {
        Device(id: id, name: name, kind: .generic, isAvailable: isAvailable)
    }

    private func makeGroupController() -> GroupController {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return GroupController(backend: MockBackend(fleet: []), store: GroupStore(directory: dir), loadPersisted: false)
    }

    // MARK: 1. NEGATIVE — DeviceDetailViewController

    func testDeviceDetailViewControllerLabelsStayStock() throws {
        let controller = makeGroupController()
        let vc = DeviceDetailViewController(groupController: controller)
        vc.loadView()
        vc.show(device: makeDevice())
        vc.view.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
        vc.view.layoutSubtreeIfNeeded()
        assertAllLabelsFrozen(in: vc.view, host: "DeviceDetailViewController")
    }

    // MARK: 2. NEGATIVE — MembershipRowView (both available + unavailable/dimmed)

    func testMembershipRowViewLabelsStayStockWhenAvailable() {
        let row = MembershipRowView(device: makeDevice(isAvailable: true), checked: true, surface: .warmPane)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 32)
        row.layoutSubtreeIfNeeded()
        assertAllLabelsFrozen(in: row, host: "MembershipRowView(available)")
    }

    func testMembershipRowViewLabelsStayStockWhenUnavailable() {
        let row = MembershipRowView(device: makeDevice(isAvailable: false), checked: false, surface: .warmPane)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 32)
        row.layoutSubtreeIfNeeded()
        assertAllLabelsFrozen(in: row, host: "MembershipRowView(unavailable, disabledControlTextColor path)")
    }

    // MARK: 3. NEGATIVE — SidebarViewController's outline cells (all four Node payloads)

    func testSidebarOutlineCellsStayStock() throws {
        let sidebar = SidebarViewController()
        let group = Group(name: "Downstairs", memberIDs: [], memberVolumes: [:])
        let device = makeDevice()

        let headerCell = try XCTUnwrap(
            sidebar.outlineView(NSOutlineView(), viewFor: nil, item: SidebarViewController.Node(.header("Groups"))) as? NSTableCellView)
        assertFrozenToStock(headerCell.textField?.textColor, "Sidebar header cell")

        let groupCell = try XCTUnwrap(
            sidebar.outlineView(NSOutlineView(), viewFor: nil, item: SidebarViewController.Node(.group(group))) as? NSTableCellView)
        assertFrozenToStock(groupCell.textField?.textColor, "Sidebar group row cell")

        let deviceCell = try XCTUnwrap(
            sidebar.outlineView(NSOutlineView(), viewFor: nil, item: SidebarViewController.Node(.device(device))) as? NSTableCellView)
        assertFrozenToStock(deviceCell.textField?.textColor, "Sidebar device row cell")

        let unavailableCell = try XCTUnwrap(
            sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                item: SidebarViewController.Node(.device(makeDevice(isAvailable: false)))) as? NSTableCellView)
        assertFrozenToStock(unavailableCell.textField?.textColor, "Sidebar unavailable-device row cell (dimmed path)")

        let emptyStateCell = try XCTUnwrap(
            sidebar.outlineView(NSOutlineView(), viewFor: nil, item: SidebarViewController.Node(.emptyState("No groups yet"))) as? NSTableCellView)
        assertFrozenToStock(emptyStateCell.textField?.textColor, "Sidebar empty-state placeholder cell")
    }

    // MARK: 4. NEGATIVE — GroupEditorViewController (name field, "Speakers" label, checklist rows)

    private func makeEditor() throws -> GroupEditorViewController {
        let devices = [
            Device(id: "a", name: "Alpha", kind: .generic, isAvailable: true),
            Device(id: "b", name: "Bravo", kind: .generic, isAvailable: true),
            Device(id: "c", name: "Charlie", kind: .generic, isAvailable: true),
            Device(id: "d", name: "Delta", kind: .generic, isAvailable: true),
        ]
        let controller = makeGroupController()
        let group = try controller.createGroup(name: "Downstairs", memberIDs: ["a", "b"], memberVolumes: [:]).group
        let editor = GroupEditorViewController(groupController: controller)
        editor.loadView()
        editor.show(groupID: group.id, devices: devices)
        editor.view.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        editor.view.layoutSubtreeIfNeeded()
        return editor
    }

    func testGroupEditorViewControllerLabelsStayStock() throws {
        let editor = try makeEditor()
        assertAllLabelsFrozen(in: editor.view, host: "GroupEditorViewController")
    }

    // MARK: 5. NEGATIVE — MixerWindowController's footer + empty-state pane

    private func makeMixerWindow() -> MixerWindowController {
        let controller = makeGroupController()
        return MixerWindowController(groupController: controller,
                                     frameAutosaveName: uniqueName("GroupsWindowTextColorLockTests"))
    }

    func testMixerWindowFooterAndEmptyStateLabelsStayStock() {
        let window = makeMixerWindow()
        window.update(devices: [])
        // Zero groups + zero devices selects the empty state (per AGENTS.md's
        // auto-select rule) — walking `contentController`'s whole tree
        // exercises both the persistent footer (`ContentPaneHostViewController
        // .footerLabel`) AND `GroupsEmptyStateViewController`'s message/
        // subtitle in one pass, via the real public hosting API rather than
        // reaching for a private view.
        let content = window.contentController
        content.view.frame = NSRect(x: 0, y: 0, width: 720, height: 460)
        content.view.layoutSubtreeIfNeeded()
        assertAllLabelsFrozen(in: content.view, host: "MixerWindowController content (footer + empty state)")
        XCTAssertTrue(window.test_isShowingEmptyState, "expected the empty state pane with zero groups/devices")
        XCTAssertEqual(window.test_emptyState.test_messageText, "No groups yet.")
        XCTAssertEqual(window.test_emptyState.test_subtitleText, "Music first — rooms can come later.")
    }

    // MARK: 6. NEGATIVE — IconPickerViewController

    func testIconPickerViewControllerLabelsStayStock() {
        let picker = IconPickerViewController()
        picker.loadView()
        picker.test_setSearchText("zzz-no-such-symbol-zzz") // forces the "No matches" empty-results label on screen
        picker.view.frame = NSRect(x: 0, y: 0, width: 320, height: 360)
        picker.view.layoutSubtreeIfNeeded()
        assertAllLabelsFrozen(in: picker.view, host: "IconPickerViewController")
    }

    // MARK: 7. NEGATIVE — GroupCreationSheetController

    func testGroupCreationSheetControllerLabelsStayStock() {
        let controller = makeGroupController()
        let sheet = GroupCreationSheetController(groupController: controller)
        sheet.loadView()
        sheet.view.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
        sheet.view.layoutSubtreeIfNeeded()
        assertAllLabelsFrozen(in: sheet.view, host: "GroupCreationSheetController")
    }

    // MARK: 8. POSITIVE — the membership checklist's well/hairline really are
    // Tokens.Color.well/.hairline (T5) — surfaces changed, text didn't.
    //
    // `GroupedSectionView` is `private` to GroupEditorViewController.swift, so
    // it can't be named or constructed here even under `@testable import` —
    // access control on the TYPE still applies; only the stored-property
    // VALUE is reachable via runtime reflection, and only as its public `NSView`
    // superclass. That's exactly enough to drive the same `cacheDisplay`
    // offscreen-render-and-sample idiom `ControlPanelBackingViewTests`/
    // `WarmFaderCellTests` already use elsewhere in this suite — this
    // exercises the REAL `draw(_:)` call, not a re-typed expectation.

    private func membershipWellView(of editor: GroupEditorViewController) throws -> NSView {
        let mirror = Mirror(reflecting: editor)
        guard let child = mirror.children.first(where: { $0.label == "membershipWell" }),
              let view = child.value as? NSView else {
            throw XCTSkip("membershipWell stored property not found via reflection — GroupEditorViewController's internal layout changed")
        }
        return view
    }

    private func sampledColumnColors(of view: NSView, appearanceName: NSAppearance.Name) throws -> [NSColor] {
        view.appearance = NSAppearance(named: appearanceName)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw XCTSkip("no bitmap rep available in this environment")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let x = rep.pixelsWide / 2
        var colors: [NSColor] = []
        for y in 0..<rep.pixelsHigh {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                colors.append(c)
            }
        }
        return colors
    }

    func testMembershipWellFillIsWellTokenBothAppearances() throws {
        let editor = try makeEditor()
        let well = try membershipWellView(of: editor)
        XCTAssertGreaterThan(well.bounds.width, 0, "well must have real layout to sample")

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let colors = try sampledColumnColors(of: well, appearanceName: appearanceName)
            guard let expectedWell = resolved(Tokens.Color.well, appearanceName: appearanceName) else {
                throw XCTSkip("well token did not resolve under \(appearanceName.rawValue)")
            }
            let matches = colors.filter { sameColor($0, expectedWell, tolerance: 0.02) }
            XCTAssertFalse(matches.isEmpty,
                "GroupedSectionView's fill under \(appearanceName.rawValue) never matched " +
                "Tokens.Color.well — the T5 recessed checklist background must stay the well " +
                "token; if this legitimately changed, that's a design decision for Alec, not a " +
                "silent repaint.")
        }
    }

    func testMembershipWellHasHairlineTokenDividerBothAppearances() throws {
        let editor = try makeEditor()
        XCTAssertGreaterThan(editor.test_membershipWellRowCount, 1,
                             "need >1 row for a hairline divider to exist at all")
        let well = try membershipWellView(of: editor)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let colors = try sampledColumnColors(of: well, appearanceName: appearanceName)
            guard let expectedHairline = resolved(Tokens.Color.hairline, appearanceName: appearanceName) else {
                throw XCTSkip("hairline token did not resolve under \(appearanceName.rawValue)")
            }
            let matches = colors.filter { sameColor($0, expectedHairline, tolerance: 0.02) }
            XCTAssertFalse(matches.isEmpty,
                "GroupedSectionView never painted a Tokens.Color.hairline-colored pixel under " +
                "\(appearanceName.rawValue) despite \(editor.test_membershipWellRowCount) rows — " +
                "the T5 divider between adjacent rows must stay the hairline token.")
        }
    }
}
