// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// The group editor's INLINE RENAME FIELD (design review 2026-07-25).
///
/// It is a real `NSTextField` wearing a drawing-only skin
/// (``WarmNameFieldCell``) — filled, bordered, with a trailing pencil — so it
/// reads as an editable control rather than a bare string that happens to
/// accept clicks. The behaviours below are the whole contract:
///
/// - **Return** commits · **focus loss** commits (both already worked; these
///   lock them against the skin regressing them).
/// - **Escape** reverts to the pre-edit name — NOT implemented before this
///   pass; the key did nothing and the half-typed name simply waited to be
///   committed by the next focus loss.
/// - **Emptied** restores the previous name INTO THE FIELD. The rename was
///   already correctly refused, but the field was left blank while the group
///   kept its old name — the UI lied about what was saved.
/// - **Hover** changes drawing only, never geometry (R7).
/// - The field can never collapse (an editable `NSTextField` has no intrinsic
///   width — it rendered invisible once already) and can never overflow its
///   section (it used to be a FIXED 260 pt that hung ~21 pt past it).
@MainActor
final class GroupRenameFieldTests: IsolatedTestCase {

    private func tempDirectory() -> URL {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The editor inside a real window at the shipping default size — the
    /// field's width is clamped by its SECTION, so a test that invents its own
    /// pane width isn't measuring the shipping geometry.
    private func makeWindow(named name: String = "Downstairs")
        throws -> (MixerWindowController, GroupController, Group) {
        let devices = (0..<4).map {
            Device(id: "d\($0)", name: "Device \($0)", kind: .generic, isAvailable: true)
        }
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let group = try controller.createGroup(name: name, memberIDs: ["d0"],
                                               memberVolumes: [:]).group
        let window = MixerWindowController(groupController: controller,
                                           frameAutosaveName: uniqueName("GroupRenameFieldTests"))
        window.update(devices: devices)
        window.test_select(.group(id: group.id))
        window.window?.contentView?.layoutSubtreeIfNeeded()
        return (window, controller, group)
    }

    private func settle(_ window: MixerWindowController) {
        window.window?.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: It is still a real text field, only skinned

    func testFieldKeepsItsRealControlBehaviourUnderTheSkin() throws {
        let (window, _, _) = try makeWindow()
        let editor = window.test_editor
        XCTAssertTrue(editor.test_titleHasWarmSkin, "the cell swap landed")
        XCTAssertTrue(editor.test_titleField.isEditable, "still editable")
        XCTAssertTrue(editor.test_titleField.isSelectable, "still selectable")
        XCTAssertTrue(editor.test_titleField.acceptsFirstResponder,
                      "still a first responder — keyboard and VoiceOver reach it exactly as before")
        // This is the LITERAL name, not `group.name` — deliberately. A real
        // bug (2026-07-26) had `show(groupID:devices:)` correctly write the
        // group's name, only for `loadView()`'s cell swap to run AFTER it (the
        // view isn't embedded, and so never loaded, until `swapContent(to:)`
        // runs — which `showEditor(for:)` calls AFTER `show()`) and silently
        // reset it to a bare `WarmNameFieldCell()`'s own AppKit default
        // ("Field", `NSCell`'s placeholder title). Every other test here
        // compares against `group.name`/`controller.groups...` — a moving
        // target that stayed self-consistent with the bug and never caught
        // it. Asserting the literal is what makes this the regression guard.
        XCTAssertEqual(editor.test_titleField.stringValue, "Downstairs",
                       "must be the group's real name, not the cell's own default")
    }

    // MARK: Commit paths

    func testReturnCommitsTheRename() throws {
        let (window, controller, group) = try makeWindow()
        var edited = 0
        window.test_editor.onDidEditGroup = { edited += 1 }

        window.test_editor.test_commitRenameViaReturn("Kitchen")

        XCTAssertEqual(controller.groups.first(where: { $0.id == group.id })?.name, "Kitchen")
        XCTAssertEqual(window.test_editor.test_nameFieldValue, "Kitchen")
        XCTAssertEqual(edited, 1, "the host is told to refresh the sidebar label")
    }

    func testFocusLossCommitsTheRename() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_commitRenameViaFocusLoss("Studio")
        XCTAssertEqual(controller.groups.first(where: { $0.id == group.id })?.name, "Studio")
        XCTAssertEqual(window.test_editor.test_nameFieldValue, "Studio")
    }

    func testWhitespaceOnlyNameIsTrimmedNotStored() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_commitRenameViaReturn("  Loft  ")
        XCTAssertEqual(controller.groups.first(where: { $0.id == group.id })?.name, "Loft")
        XCTAssertEqual(window.test_editor.test_nameFieldValue, "Loft",
                       "the field shows exactly what was saved, not the untrimmed typing")
    }

    // MARK: Escape

    func testEscapeRevertsToThePreEditName() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_cancelRename(after: "Half-typed nam")

        XCTAssertEqual(window.test_editor.test_nameFieldValue, "Downstairs",
                       "Escape puts the pre-edit name back in the field")
        XCTAssertEqual(controller.groups.first(where: { $0.id == group.id })?.name, "Downstairs",
                       "…and nothing was persisted")
    }

    func testEscapeThenFocusLossStillCommitsNothing() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_cancelRename(after: "Discarded")
        // Whatever happens next must not resurrect the discarded text.
        window.test_editor.test_commitRenameViaFocusLoss(window.test_editor.test_nameFieldValue)
        XCTAssertEqual(controller.groups.first(where: { $0.id == group.id })?.name, "Downstairs")
    }

    // MARK: Emptied

    func testEmptyingTheFieldRestoresThePreviousNameInsteadOfLeavingItBlank() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_commitRenameViaReturn("")

        XCTAssertEqual(controller.groups.first(where: { $0.id == group.id })?.name, "Downstairs",
                       "an empty rename is still refused")
        XCTAssertEqual(window.test_editor.test_nameFieldValue, "Downstairs",
                       "and the field is put BACK — it used to sit blank while the group kept its " +
                       "old name, which is the UI lying about what was saved")
    }

    func testWhitespaceOnlyNameAlsoRestores() throws {
        let (window, _, _) = try makeWindow()
        window.test_editor.test_commitRenameViaFocusLoss("   ")
        XCTAssertEqual(window.test_editor.test_nameFieldValue, "Downstairs")
    }

    // MARK: Width — never collapses, never overflows

    func testShortNameHoldsTheMinimumWidth() throws {
        let (window, _, _) = try makeWindow(named: "Hi")
        let width = window.test_editor.test_titleFieldFrame.width
        XCTAssertGreaterThanOrEqual(width, 140,
                                    "an editable NSTextField has NO intrinsic width — without the " +
                                    "required floor auto layout collapses it to nothing (it " +
                                    "rendered invisible once already, snapshot-caught 2026-07-18)")
    }

    func testLongNameStopsAtTheSectionEdgeInsteadOfOverflowingIt() throws {
        let (window, _, _) = try makeWindow()
        window.test_editor.test_commitRenameViaReturn(
            "A very very long group name that could never fit in this header band")
        settle(window)

        let field = window.test_editor.test_titleFieldFrame
        let section = window.test_editor.test_headerSectionFrame
        XCTAssertLessThanOrEqual(field.maxX, section.maxX,
                                 "the field is capped by its section — the old FIXED 260pt width " +
                                 "hung roughly 21pt past the section's own edge")
        XCTAssertGreaterThan(field.width, 140, "…but it did grow to use the room it has")
    }

    func testALongNameNeverWidensThePane() throws {
        let (window, _, _) = try makeWindow()
        settle(window)
        let paneBefore = window.test_editor.view.frame.width
        let windowBefore = window.window?.frame.width

        window.test_editor.test_commitRenameViaReturn(
            String(repeating: "Extremely long group name ", count: 4))
        settle(window)

        XCTAssertEqual(window.test_editor.view.frame.width, paneBefore, accuracy: 0.01,
                       "the field's width is a WEAK preference: satisfied at a higher priority it " +
                       "was answered by growing the whole content pane, squeezing the sidebar past " +
                       "its own minimum thickness")
        XCTAssertEqual(window.window?.frame.width, windowBefore)
    }

    func testTheFieldGrowsWithTheNameItHolds() throws {
        let (window, _, _) = try makeWindow(named: "Hi")
        let short = window.test_editor.test_titleFieldFrame.width
        window.test_editor.test_commitRenameViaReturn("A considerably longer name")
        settle(window)
        let long = window.test_editor.test_titleFieldFrame.width
        XCTAssertGreaterThan(long, short,
                             "the field hugs its name (measured by hand — an editable field has no " +
                             "intrinsic width to hug with) rather than sitting at one fixed size")
    }

    // MARK: Hover

    func testHoverChangesDrawingButNoGeometry() throws {
        let (window, _, _) = try makeWindow()
        let editor = window.test_editor
        settle(window)
        let restFrame = editor.test_titleFieldFrame
        XCTAssertFalse(editor.test_isTitleHovered)

        editor.test_setTitleHovered(true)
        settle(window)
        XCTAssertTrue(editor.test_isTitleHovered, "the wash + pencil step-up are on")
        XCTAssertEqual(editor.test_titleFieldFrame, restFrame,
                       "hover never moves geometry (R7) — it is a wash and an alpha, nothing else")

        editor.test_setTitleHovered(false)
        XCTAssertFalse(editor.test_isTitleHovered)
        XCTAssertEqual(editor.test_titleFieldFrame, restFrame)
    }

    // MARK: Real AppKit dispatch (not just the delegate seam)

    /// Escape driven through a REAL field editor, so the test exercises the
    /// dispatch AppKit performs (`NSTextView` → `control(_:textView:
    /// doCommandBy:)`) rather than the delegate method in isolation — the
    /// house lesson from the group-activation regression that stayed green for
    /// 78 tests because they all called the delegate directly.
    func testEscapeThroughTheRealFieldEditorReverts() throws {
        let (window, controller, group) = try makeWindow()
        let editor = window.test_editor
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = editor.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              let fieldEditor = editor.test_titleField.currentEditor() as? NSTextView else {
            throw XCTSkip("no field editor available in this environment")
        }

        fieldEditor.string = "Typed but discarded"
        fieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertEqual(editor.test_nameFieldValue, "Downstairs")
        XCTAssertEqual(controller.groups.first(where: { $0.id == group.id })?.name, "Downstairs")
    }

    /// Finder-style: taking focus selects the whole name, so typing replaces it.
    func testTakingFocusSelectsTheWholeName() throws {
        let (window, _, _) = try makeWindow()
        let editor = window.test_editor
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = editor.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              let fieldEditor = editor.test_titleField.currentEditor() else {
            throw XCTSkip("no field editor available in this environment")
        }
        XCTAssertEqual(fieldEditor.selectedRange,
                       NSRange(location: 0, length: ("Downstairs" as NSString).length),
                       "the whole name is selected on first focus, so typing replaces it")
    }

    // MARK: The pencil

    func testPencilShowsAtRestAndHidesWhileEditing() throws {
        let (window, _, _) = try makeWindow()
        let editor = window.test_editor
        XCTAssertTrue(editor.test_titleShowsPencil, "at rest the pencil says the name is editable")

        // A real field editor: hosting window + first responder, the same path
        // a click or a Tab takes.
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = editor.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              editor.test_titleField.currentEditor() != nil else {
            throw XCTSkip("no field editor available in this environment")
        }
        XCTAssertFalse(editor.test_titleShowsPencil,
                       "while editing the caret is the affordance — the glyph would collide with " +
                       "it at the end of a long name")

        host.makeFirstResponder(nil)
        XCTAssertTrue(editor.test_titleShowsPencil, "…and comes back when editing ends")
    }

    /// The two edit cues in the header — the icon well's corner badge and the
    /// rename field's pencil — read the SAME pair of alphas, so they can't
    /// drift apart into two different-looking affordances.
    func testBothEditAffordancesShareOneRestAndHoverAlpha() {
        XCTAssertEqual(PopoverColumnGrid.editAffordanceRestAlpha, 0.7, accuracy: 0.001)
        XCTAssertEqual(PopoverColumnGrid.editAffordanceHoverAlpha, 1.0, accuracy: 0.001)

        let well = DeviceIconWellView()
        well.setOverlayVisible(false)
        XCTAssertEqual(well.test_badgeAlpha, PopoverColumnGrid.editAffordanceRestAlpha,
                       accuracy: 0.001, "the icon badge reads the shared rest alpha")
        well.setOverlayVisible(true)
        XCTAssertEqual(well.test_badgeAlpha, PopoverColumnGrid.editAffordanceHoverAlpha,
                       accuracy: 0.001, "…and the shared hover alpha")
    }

    /// The DEVICE detail pane's title is deliberately BARE — no fill, no
    /// border, no pencil. Bordered + pencil means "editable"; that vocabulary
    /// only works if the read-only pane never borrows it.
    func testDeviceDetailTitleWearsNoEditAffordance() throws {
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let detail = DeviceDetailViewController(groupController: controller)
        detail.loadView()
        detail.show(device: Device(id: "office", name: "Office", kind: .generic, isAvailable: true))
        detail.view.layoutSubtreeIfNeeded()

        let titles = detail.view.descendantTextFields().filter { $0.stringValue == "Office" }
        XCTAssertEqual(titles.count, 1, "exactly one label carries the device name")
        let title = try XCTUnwrap(titles.first)
        XCTAssertFalse(title.cell is WarmNameFieldCell,
                       "a device's name is not renameable, so it must not wear the editable skin")
        XCTAssertFalse(title.isEditable)
        XCTAssertFalse(title.isBordered)
        XCTAssertFalse(title.drawsBackground)
    }
}

private extension NSView {
    func descendantTextFields() -> [NSTextField] {
        var result: [NSTextField] = []
        if let field = self as? NSTextField { result.append(field) }
        for sub in subviews { result.append(contentsOf: sub.descendantTextFields()) }
        return result
    }
}
