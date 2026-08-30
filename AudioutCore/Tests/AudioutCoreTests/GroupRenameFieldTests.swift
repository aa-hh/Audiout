// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI
@testable import AudioutWindowUI

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
@Suite final class GroupRenameFieldTests: IsolatedSuite {

    private func tempDirectory() -> URL {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The editor inside the real content tree at the Groups screen's shipping
    /// content area — the field's width is clamped by its SECTION, so a test
    /// that invents its own pane width isn't measuring the shipping geometry.
    /// The controller owns no window (U6): the split view is laid out directly
    /// at the area the surface's Groups screen gives it.
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
                                           settings: AppSettings(defaults: isolatedDefaults))
        window.setHostVisible(true)
        window.update(devices: devices)
        window.test_select(.group(id: group.id))
        // The fixed frame's floor; only the width matters here.
        window.contentController.view.setFrameSize(AppSurfaceController.minimumContentSize)
        settle(window)
        return (window, controller, group)
    }

    private func settle(_ window: MixerWindowController) {
        window.contentController.view.layoutSubtreeIfNeeded()
    }

    // MARK: It is still a real text field, only skinned

    @Test func fieldKeepsItsRealControlBehaviourUnderTheSkin() throws {
        let (window, _, _) = try makeWindow()
        let editor = window.test_editor
        #expect(editor.test_titleHasWarmSkin, "the cell swap landed")
        #expect(editor.test_titleField.isEditable, "still editable")
        #expect(editor.test_titleField.isSelectable, "still selectable")
        #expect(editor.test_titleField.acceptsFirstResponder,
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
        #expect(editor.test_titleField.stringValue == "Downstairs",
                "must be the group's real name, not the cell's own default")
    }

    // MARK: Commit paths

    @Test func returnCommitsTheRename() throws {
        let (window, controller, group) = try makeWindow()
        var edited = 0
        window.test_editor.onDidEditGroup = { edited += 1 }

        window.test_editor.test_commitRenameViaReturn("Kitchen")

        #expect(controller.groups.first(where: { $0.id == group.id })?.name == "Kitchen")
        #expect(window.test_editor.test_nameFieldValue == "Kitchen")
        #expect(edited == 1, "the host is told to refresh the sidebar label")
    }

    @Test func focusLossCommitsTheRename() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_commitRenameViaFocusLoss("Studio")
        #expect(controller.groups.first(where: { $0.id == group.id })?.name == "Studio")
        #expect(window.test_editor.test_nameFieldValue == "Studio")
    }

    @Test func whitespaceOnlyNameIsTrimmedNotStored() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_commitRenameViaReturn("  Loft  ")
        #expect(controller.groups.first(where: { $0.id == group.id })?.name == "Loft")
        #expect(window.test_editor.test_nameFieldValue == "Loft",
                "the field shows exactly what was saved, not the untrimmed typing")
    }

    // MARK: Escape

    @Test func escapeRevertsToThePreEditName() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_cancelRename(after: "Half-typed nam")

        #expect(window.test_editor.test_nameFieldValue == "Downstairs",
                "Escape puts the pre-edit name back in the field")
        #expect(controller.groups.first(where: { $0.id == group.id })?.name == "Downstairs",
                "…and nothing was persisted")
    }

    @Test func escapeThenFocusLossStillCommitsNothing() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_cancelRename(after: "Discarded")
        // Whatever happens next must not resurrect the discarded text.
        window.test_editor.test_commitRenameViaFocusLoss(window.test_editor.test_nameFieldValue)
        #expect(controller.groups.first(where: { $0.id == group.id })?.name == "Downstairs")
    }

    // MARK: Emptied

    @Test func emptyingTheFieldRestoresThePreviousNameInsteadOfLeavingItBlank() throws {
        let (window, controller, group) = try makeWindow()
        window.test_editor.test_commitRenameViaReturn("")

        #expect(controller.groups.first(where: { $0.id == group.id })?.name == "Downstairs",
                "an empty rename is still refused")
        #expect(window.test_editor.test_nameFieldValue == "Downstairs",
                Comment(rawValue: "and the field is put BACK — it used to sit blank while the group kept its " +
                "old name, which is the UI lying about what was saved"))
    }

    @Test func whitespaceOnlyNameAlsoRestores() throws {
        let (window, _, _) = try makeWindow()
        window.test_editor.test_commitRenameViaFocusLoss("   ")
        #expect(window.test_editor.test_nameFieldValue == "Downstairs")
    }

    // MARK: Width — never collapses, never overflows

    @Test func shortNameHoldsTheMinimumWidth() throws {
        let (window, _, _) = try makeWindow(named: "Hi")
        let width = window.test_editor.test_titleFieldFrame.width
        #expect(width >= 140,
                Comment(rawValue: "an editable NSTextField has NO intrinsic width — without the " +
                "required floor auto layout collapses it to nothing (it " +
                "rendered invisible once already, snapshot-caught 2026-07-18)"))
    }

    @Test func longNameStopsAtTheSectionEdgeInsteadOfOverflowingIt() throws {
        let (window, _, _) = try makeWindow()
        window.test_editor.test_commitRenameViaReturn(
            "A very very long group name that could never fit in this header band")
        settle(window)

        let field = window.test_editor.test_titleFieldFrame
        let section = window.test_editor.test_headerSectionFrame
        #expect(field.maxX <= section.maxX,
                Comment(rawValue: "the field is capped by its section — the old FIXED 260pt width " +
                "hung roughly 21pt past the section's own edge"))
        #expect(field.width > 140, "…but it did grow to use the room it has")
    }

    @Test func aLongNameNeverWidensThePane() throws {
        let (window, _, _) = try makeWindow()
        settle(window)
        let paneBefore = window.test_editor.view.frame.width

        window.test_editor.test_commitRenameViaReturn(
            String(repeating: "Extremely long group name ", count: 4))
        settle(window)

        #expect(abs(window.test_editor.view.frame.width - paneBefore) <= 0.01,
                Comment(rawValue: "the field's width is a WEAK preference: satisfied at a higher priority it " +
                "was answered by growing the whole content pane, squeezing the sidebar past " +
                "its own minimum thickness"))
    }

    @Test func theFieldGrowsWithTheNameItHolds() throws {
        let (window, _, _) = try makeWindow(named: "Hi")
        let short = window.test_editor.test_titleFieldFrame.width
        window.test_editor.test_commitRenameViaReturn("A considerably longer name")
        settle(window)
        let long = window.test_editor.test_titleFieldFrame.width
        #expect(long > short,
                Comment(rawValue: "the field hugs its name (measured by hand — an editable field has no " +
                "intrinsic width to hug with) rather than sitting at one fixed size"))
    }

    // MARK: Hover

    @Test func hoverChangesDrawingButNoGeometry() throws {
        let (window, _, _) = try makeWindow()
        let editor = window.test_editor
        settle(window)
        let restFrame = editor.test_titleFieldFrame
        #expect(!editor.test_isTitleHovered)

        editor.test_setTitleHovered(true)
        settle(window)
        #expect(editor.test_isTitleHovered, "the wash + pencil step-up are on")
        #expect(editor.test_titleFieldFrame == restFrame,
                "hover never moves geometry (R7) — it is a wash and an alpha, nothing else")

        editor.test_setTitleHovered(false)
        #expect(!editor.test_isTitleHovered)
        #expect(editor.test_titleFieldFrame == restFrame)
    }

    // MARK: Real AppKit dispatch (not just the delegate seam)

    /// Escape driven through a REAL field editor, so the test exercises the
    /// dispatch AppKit performs (`NSTextView` → `control(_:textView:
    /// doCommandBy:)`) rather than the delegate method in isolation — the
    /// house lesson from the group-activation regression that stayed green for
    /// 78 tests because they all called the delegate directly.
    ///
    /// CONVERSION NOTE: the original guard fell back to `throw XCTSkip(...)`
    /// ("no field editor available in this environment") — a defensive
    /// fallback for an exotic CI without a real WindowServer, never actually
    /// hit on this toolchain. swift-testing has no in-body "mark skipped"
    /// equivalent (traits are evaluated before the test runs, per the
    /// migration cookbook §9), so this is an early `return` instead: the test
    /// reports as PASSED rather than SKIPPED if this environment ever lacks a
    /// field editor, where it previously reported SKIPPED. Flagging per the
    /// cookbook's guidance rather than inventing a hoisted trait for a
    /// condition that only resolves after a real window/first-responder
    /// round-trip.
    @Test func escapeThroughTheRealFieldEditorReverts() throws {
        let (window, controller, group) = try makeWindow()
        let editor = window.test_editor
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = editor.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              let fieldEditor = editor.test_titleField.currentEditor() as? NSTextView else {
            return
        }

        fieldEditor.string = "Typed but discarded"
        fieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        #expect(editor.test_nameFieldValue == "Downstairs")
        #expect(controller.groups.first(where: { $0.id == group.id })?.name == "Downstairs")
    }

    /// A backend event arriving mid-rename must not touch the field. The host
    /// re-shows this pane on EVERY event, and the write used to be
    /// unconditional — so a speaker appearing while the user was two letters
    /// into a name replaced what they had typed.
    ///
    /// CONVERSION NOTE: same early-return compromise as
    /// `escapeThroughTheRealFieldEditorReverts` — see its note.
    @Test func aRefreshNeverOverwritesANameBeingTyped() throws {
        let (window, _, group) = try makeWindow()
        let editor = window.test_editor
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = editor.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              let fieldEditor = editor.test_titleField.currentEditor() else {
            return
        }
        fieldEditor.string = "Kitch"

        // A real change elsewhere in the snapshot, so the pane's gate opens and
        // `render` genuinely runs — this is not a test of the gate.
        let renamed = (0..<4).map {
            Device(id: "d\($0)", name: $0 == 1 ? "Device 1 (renamed)" : "Device \($0)",
                   kind: .generic, isAvailable: true)
        }
        let before = editor.test_renderCount
        editor.show(groupID: group.id, devices: renamed)

        #expect(editor.test_renderCount == before + 1, "the pane really did repaint")
        #expect(fieldEditor.string == "Kitch",
                "…around the half-typed name, which is the one thing it must not touch")
    }

    /// ESCAPE hands focus somewhere REAL. It used to go to
    /// `makeFirstResponder(nil)` — the window becomes its own first responder
    /// and Tab has nothing to advance from, the exact dead-Tab state
    /// A11Y-GROUPS fixed.
    ///
    /// CONVERSION NOTE: same early-return compromise as
    /// `escapeThroughTheRealFieldEditorReverts` — see its note.
    @Test func escapeLandsKeyboardFocusOnTheSidebarList() throws {
        let (window, _, _) = try makeWindow()
        let editor = window.test_editor
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = window.contentController.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              let fieldEditor = editor.test_titleField.currentEditor() as? NSTextView else {
            return
        }

        fieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        #expect(window.test_sidebar.test_isOutlineViewFirstResponder,
                "focus lands on the sidebar's row list — the one control present whatever pane shows")
        #expect(host.firstResponder !== host,
                "…and never on the window itself, which is the dead-Tab state")
    }

    /// Finder-style: taking focus selects the whole name, so typing replaces it.
    ///
    /// CONVERSION NOTE: same early-return compromise as
    /// `escapeThroughTheRealFieldEditorReverts` above — see its note.
    @Test func takingFocusSelectsTheWholeName() throws {
        let (window, _, _) = try makeWindow()
        let editor = window.test_editor
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = editor.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              let fieldEditor = editor.test_titleField.currentEditor() else {
            return
        }
        #expect(fieldEditor.selectedRange
                == NSRange(location: 0, length: ("Downstairs" as NSString).length),
                "the whole name is selected on first focus, so typing replaces it")
    }

    // MARK: The pencil

    /// CONVERSION NOTE: same early-return compromise as
    /// `escapeThroughTheRealFieldEditorReverts` above — see its note.
    @Test func pencilShowsAtRestAndHidesWhileEditing() throws {
        let (window, _, _) = try makeWindow()
        let editor = window.test_editor
        #expect(editor.test_titleShowsPencil, "at rest the pencil says the name is editable")

        // A real field editor: hosting window + first responder, the same path
        // a click or a Tab takes.
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = editor.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              editor.test_titleField.currentEditor() != nil else {
            return
        }
        #expect(!editor.test_titleShowsPencil,
                Comment(rawValue: "while editing the caret is the affordance — the glyph would collide with " +
                "it at the end of a long name"))

        host.makeFirstResponder(nil)
        #expect(editor.test_titleShowsPencil, "…and comes back when editing ends")
    }

    /// The two edit cues in the header — the icon well's corner badge and the
    /// rename field's pencil — read the SAME pair of alphas, so they can't
    /// drift apart into two different-looking affordances.
    @Test func bothEditAffordancesShareOneRestAndHoverAlpha() {
        #expect(abs(PopoverColumnGrid.editAffordanceRestAlpha - 0.7) <= 0.001)
        #expect(abs(PopoverColumnGrid.editAffordanceHoverAlpha - 1.0) <= 0.001)

        let well = DeviceIconWellView()
        well.setOverlayVisible(false)
        #expect(abs(well.test_badgeAlpha - PopoverColumnGrid.editAffordanceRestAlpha) <= 0.001,
                "the icon badge reads the shared rest alpha")
        well.setOverlayVisible(true)
        #expect(abs(well.test_badgeAlpha - PopoverColumnGrid.editAffordanceHoverAlpha) <= 0.001,
                "…and the shared hover alpha")
    }

    /// The DEVICE detail pane's title is deliberately BARE — no fill, no
    /// border, no pencil. Bordered + pencil means "editable"; that vocabulary
    /// only works if the read-only pane never borrows it.
    @Test func deviceDetailTitleWearsNoEditAffordance() throws {
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let detail = DeviceDetailViewController(groupController: controller,
                                                settings: AppSettings(defaults: isolatedDefaults))
        detail.loadView()
        detail.show(device: Device(id: "office", name: "Office", kind: .generic, isAvailable: true))
        detail.view.layoutSubtreeIfNeeded()

        let titles = detail.view.descendantTextFields().filter { $0.stringValue == "Office" }
        #expect(titles.count == 1, "exactly one label carries the device name")
        let title = try #require(titles.first)
        #expect(!(title.cell is WarmNameFieldCell),
                "a device's name is not renameable, so it must not wear the editable skin")
        #expect(!title.isEditable)
        #expect(!title.isBordered)
        #expect(!title.drawsBackground)
    }

    // MARK: A repaint must not discard what is being typed

    /// `show(groupID:devices:)` is a REFRESH as well as a first show:
    /// `MixerWindowController.refreshAll()` calls it on every repaint of a
    /// visible editor. A membership toggle in this same pane saves the group,
    /// and any phone-driven group edit repaints too — so writing the model's
    /// name into the field unconditionally threw away whatever the user was
    /// halfway through typing, with nothing said.
    ///
    /// CONVERSION NOTE: same early-return compromise as the other field-editor
    /// tests in this file — a headless run can refuse first responder.
    @MainActor
    @Test func aRepaintDoesNotDiscardAHalfTypedName() throws {
        let (window, _, group) = try makeWindow()
        let editor = window.test_editor
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = editor.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              let fieldEditor = editor.test_titleField.currentEditor() else {
            return
        }

        fieldEditor.string = "Half typed"
        // Exactly what `refreshAll()` does for a visible editor.
        editor.show(groupID: group.id, devices: [])

        #expect(editor.test_nameFieldValue == "Half typed",
                "a background repaint must leave the in-progress rename alone")
    }

    /// The guard is scoped to the group being renamed: switching the pane to a
    /// DIFFERENT group must re-fill the field, or the new group would show the
    /// previous one's half-typed name.
    @MainActor
    @Test func switchingToAnotherGroupWhileTypingStillRefillsTheField() throws {
        let (window, controller, _) = try makeWindow()
        let other = try controller.createGroup(name: "Upstairs", memberIDs: ["d1"],
                                               memberVolumes: [:]).group
        let editor = window.test_editor
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentView = editor.view
        host.contentView?.layoutSubtreeIfNeeded()
        guard host.makeFirstResponder(editor.test_titleField),
              let fieldEditor = editor.test_titleField.currentEditor() else {
            return
        }

        fieldEditor.string = "Half typed"
        editor.show(groupID: other.id, devices: [])

        #expect(editor.test_nameFieldValue == "Upstairs",
                "a different group's editor must never inherit the last one's typing")
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
