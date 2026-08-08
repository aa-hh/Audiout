// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// Return/Escape in the sync drawer's value field **as it really mounts** —
/// inserted into the live row stack through
/// `PopoverPanelViewController.insertRow(_:after:animated:)`, animation run
/// out, layout forced — and, for comparison, inside the real
/// `ControlPanelWindowController` panel.
///
/// WHY THIS FILE EXISTS, ON TOP OF ``SyncValueFieldLiveKeyTests``. That file
/// proves the field editor's own contract on a bare `NSTextField` in a bare
/// window. It deliberately cannot see a defect that lives in the MOUNTING
/// CONTEXT: a re-layout that tears the field editor down, a rebuilt drawer
/// that constructs a second editor, or a host view that claims Return before
/// the first responder ever sees it. All three produce the reported symptom
/// ("Return closes the surface and loses the edit") while every isolated test
/// stays green, so the mounted case gets its own coverage.
///
/// WHAT THE TWO SURFACES ARE. `AIRPLAY_CONTROL_PANEL=1` (baked into every
/// bundled `.app` by `scripts/make-app.sh`) re-homes the **Groups** surface
/// into `ControlPanelWindowController`. It does NOT re-home the menu-bar
/// popover, which is the only host that ever mounts a `BTSyncDrawerView` —
/// `PopoverController` owns the single reused instance and is the one call
/// site that passes `showsSyncControls:`. The control-panel case below is
/// therefore a comparison, not the shipping path for this drawer; it is here
/// so the claim is settled in code rather than in prose, and because
/// `ControlPanelPanel` routes Escape straight to `performClose(_:)`, which any
/// text field it ever hosts has to survive.
@MainActor
@Suite(.serialized) struct SyncDrawerMountedKeyTests {

    // MARK: Harness

    /// Records keystrokes that got past the whole responder chain. `NSWindow`
    /// is the LAST rung, so anything logged here was consumed by nobody — the
    /// headless equivalent of "the key escaped the field and the host acted on
    /// it".
    private final class KeyWitnessWindow: NSWindow {
        var unhandled: [NSEvent] = []
        override func keyDown(with event: NSEvent) { unhandled.append(event) }
        var summary: String { "unhandled=\(unhandled.map(\.keyCode))" }
    }

    private final class CommitRecorder: BTSyncDrawerViewDelegate {
        var commits: [Double] = []
        var closeRequests = 0
        func syncDrawer(_ d: BTSyncDrawerView, didChangeTrimMs ms: Double, committed: Bool) {
            commits.append(ms)
        }
        func syncDrawer(_ d: BTSyncDrawerView, didToggleAlignTick active: Bool) {}
        func syncDrawerDidRequestClose(_ d: BTSyncDrawerView) { closeRequests += 1 }
    }

    private enum Key {
        case newline, escape
        var code: UInt16 { self == .newline ? 36 : 53 }
        var characters: String { self == .newline ? "\r" : "\u{1b}" }
    }

    private func press(_ key: Key, into window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.characters,
            isARepeat: false, keyCode: key.code), "AppKit refused to build the key event")
        window.sendEvent(event)
    }

    /// The drawer's one editable field, found by TYPE rather than by a test
    /// hook or a cell class — the drawer's skin is being reworked and this has
    /// to survive that.
    private func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = editableField(in: subview) { return found }
        }
        return nil
    }

    /// Every `NSButton` under `view` that claims a key equivalent.
    private func keyEquivalentClaims(under view: NSView) -> [String] {
        var claims: [String] = []
        if let button = view as? NSButton, !button.keyEquivalent.isEmpty {
            claims.append("\(type(of: button)) → \(button.keyEquivalent.debugDescription)")
        }
        for subview in view.subviews { claims += keyEquivalentClaims(under: subview) }
        return claims
    }

    /// Put the field in the state a live click leaves it in. The begin-editing
    /// notification is supplied explicitly for the reason
    /// ``SyncValueFieldLiveKeyTests`` records: a programmatic
    /// `makeFirstResponder` installs a real field editor but posts no
    /// notification, and AppKit would otherwise fire it from inside the first
    /// insertion.
    private func clickIn(_ field: NSTextField, window: NSWindow) throws {
        #expect(window.makeFirstResponder(field), "the field refused first responder")
        let editor = try #require(field.delegate as? SyncValueFieldEditor,
                                  "the field's delegate is not a SyncValueFieldEditor")
        editor.test_beginEditing()
    }

    private func typeText(_ text: String, into field: NSTextField) throws {
        let editor = try #require(field.currentEditor() as? NSTextView,
                                  "no field editor — nothing can route a keystroke")
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    // MARK: The popover path — the surface the drawer actually ships on

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private let macDevice = Device(id: "mac", name: "This Mac", kind: .localMac,
                                   isLocalDevice: true)
    private let btDevice = Device(id: "bt-a:output", name: "Speaker A", kind: .bluetooth,
                                  isAvailable: true, supportsAirPlay2: false)

    /// A popover whose panel view is hosted in a real (never on-screen) window,
    /// with the sync drawer opened under the Bluetooth row through the real
    /// `insertRow` path — animation included — and the insert animation run to
    /// completion before anything is asserted.
    private func mountedDrawer() throws
        -> (popover: PopoverController, window: KeyWitnessWindow,
            drawer: BTSyncDrawerView, field: NSTextField, host: CommitBox) {
        let backend = MockBackend(fleet: [], staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let groups = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDirectory()),
                                     routingStore: RoutingStore(directory: tempDirectory()),
                                     loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: groups)
        popover.test_isShownOverride = true
        popover.btTrimProvider = { _ in -414 }
        popover.btTrimIsSetProvider = { _ in true }
        let box = CommitBox()
        popover.onSetBTTrim = { ms, _, persist in box.commits.append((ms, persist)) }
        popover.update(devices: [macDevice, btDevice])

        // `.titled` is load-bearing: a borderless window refuses a first
        // responder that wants to edit text.
        let window = KeyWitnessWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = popover.test_panelView

        popover.test_toggleSyncDrawer(deviceID: btDevice.id, animated: true)
        // Let `insertRow`'s NSAnimationContext group finish, then force the
        // layout pass it leaves behind — the two things an isolated test never
        // performs, and the two that could tear a field editor down.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window.contentView?.layoutSubtreeIfNeeded()

        let drawer = try #require(popover.test_syncDrawer, "the drawer never mounted")
        let field = try #require(editableField(in: drawer), "the drawer has no editable field")
        return (popover, window, drawer, field, box)
    }

    /// Boxes the host's commit log so the tuple above can hand it back by
    /// reference (the closure outlives the factory).
    private final class CommitBox { var commits: [(ms: Double, persist: Bool)] = [] }

    /// The precondition every case below rests on: after the real mount — the
    /// insert animation and the layout pass that follows it — the field still
    /// holds a live editing session, that session is the window's first
    /// responder, and the field's delegate is still the SAME editor instance.
    /// A re-layout that tears the field editor down, or a rebuilt drawer
    /// carrying a second editor, both fail here rather than surfacing as a
    /// mysterious key that goes nowhere.
    @Test func theEditingSessionSurvivesTheMountAnimationAndALayoutPass() throws {
        let mounted = try mountedDrawer()
        let editorBefore = try #require(mounted.field.delegate as? SyncValueFieldEditor)
        try clickIn(mounted.field, window: mounted.window)
        mounted.window.contentView?.layoutSubtreeIfNeeded()

        let fieldEditor = try #require(mounted.field.currentEditor(),
                                       "the mount tore the field editor down")
        #expect(mounted.window.firstResponder === fieldEditor,
                "the field editor must hold first responder for real key dispatch")
        #expect(mounted.field.delegate === editorBefore,
                "the drawer built a SECOND SyncValueFieldEditor — the first one's commits go nowhere")
    }

    @Test func returnCommitsTheTypedValueAndNothingEscapesTheField() throws {
        let mounted = try mountedDrawer()
        try clickIn(mounted.field, window: mounted.window)
        try typeText("25", into: mounted.field)

        try press(.newline, into: mounted.window)

        #expect(mounted.host.commits.map(\.ms) == [25],
                "Return must commit the typed value; got \(mounted.host.commits.map(\.ms))")
        #expect(mounted.host.commits.allSatisfy { $0.persist },
                "a typed Return is a committed gesture — it persists")
        #expect(mounted.window.unhandled.isEmpty,
                "Return escaped the whole responder chain — a transient popover closes on that. \(mounted.window.summary)")
        #expect(mounted.popover.test_syncDrawerVisible,
                "the drawer must still be mounted after a commit")
        #expect(mounted.popover.test_expandedSyncDeviceID == btDevice.id)
    }

    @Test func escapeRevertsTheEditAndLeavesTheDrawerOpen() throws {
        let mounted = try mountedDrawer()
        try clickIn(mounted.field, window: mounted.window)
        try typeText("25", into: mounted.field)

        try press(.escape, into: mounted.window)

        #expect(mounted.host.commits.isEmpty,
                "Escape discards the edit, it never commits; got \(mounted.host.commits.map(\.ms))")
        #expect(mounted.field.stringValue == "-414",
                "Escape restores the committed value; got \(mounted.field.stringValue)")
        #expect(mounted.window.unhandled.isEmpty,
                "Escape escaped the field — the host reads that as 'close the drawer'. \(mounted.window.summary)")
        #expect(mounted.popover.test_syncDrawerVisible,
                "an edit-cancel Escape must not also collapse the drawer")
    }

    /// `sendEvent(_:)` runs `performKeyEquivalent(with:)` down the WHOLE view
    /// tree before the first responder sees `keyDown`, so a single button
    /// anywhere in the open popover claiming Return or Escape would take the
    /// key before the field editor could consume it — with no trace at the
    /// field's own seam. Asserted over the live tree with the drawer open, so
    /// a future default button added to any card is caught here.
    @Test func noDescendantOfTheOpenPopoverClaimsReturnOrEscape() throws {
        let mounted = try mountedDrawer()
        let content = try #require(mounted.window.contentView)
        let claims = keyEquivalentClaims(under: content)
            .filter { $0.contains("\\r") || $0.contains("\\u{1B}") || $0.contains("\\u{001B}") }
        #expect(claims.isEmpty, "something claims Return/Escape ahead of the field: \(claims)")
        #expect(mounted.window.defaultButtonCell == nil,
                "a default button cell would fire on Return before the first responder saw it")
    }

    /// FOUND DEFECT, pinned as a known issue rather than asserted away: a
    /// STRUCTURAL repaint — `PopoverController.rebuild()`, which any device
    /// appearing/disappearing or any route change triggers — detaches the one
    /// reused drawer (`syncDrawer.removeFromSuperview()`), which ends the
    /// editing session and drops first responder back to the window. The typed
    /// value is committed on the way out (`controlTextDidEndEditing`), so
    /// nothing is lost, but focus is silently gone: the user's NEXT Return
    /// lands with no first responder at all, which inside a `.transient`
    /// `NSPopover` is exactly the shape of "Return closed my popover".
    ///
    /// Fixed in `PopoverController`: it remembers `isEditingValue` at the
    /// detach and calls `focusValueField()` once the drawer is re-mounted.
    @Test func aStructuralRepaintSilentlyEndsTheEditingSession() throws {
        let mounted = try mountedDrawer()
        try clickIn(mounted.field, window: mounted.window)
        try typeText("25", into: mounted.field)

        // A new AirPlay device appears — the ordinary background event that
        // escalates `update(devices:)` to a full `rebuild()`.
        mounted.popover.update(devices: [macDevice, btDevice,
                                         Device(id: "office", name: "Office", kind: .homePod)])
        mounted.window.contentView?.layoutSubtreeIfNeeded()

        #expect(mounted.field.currentEditor() != nil,
                "a background repaint must not end the user's editing session")
        #expect(mounted.window.firstResponder !== mounted.window,
                "first responder must not fall back to the window — the next Return would have nowhere to go")
        #expect(mounted.host.commits.map(\.ms) == [25],
                "the in-flight edit is at least committed on the way out, not lost")
    }

    // MARK: The control-panel path — the shell the bundled app really uses,
    // for Groups. The drawer never mounts here in production (see the type
    // comment); this pins that Return and Escape would be safe if it did, and
    // in particular that `ControlPanelPanel.cancelOperation(_:)` →
    // `performClose(_:)` cannot fire out from under a text edit.

    private func hostedInControlPanel() throws
        -> (shell: ControlPanelWindowController, panel: NSPanel,
            drawer: BTSyncDrawerView, field: NSTextField, recorder: CommitRecorder) {
        let shell = ControlPanelWindowController()
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
        let drawer = BTSyncDrawerView()
        let recorder = CommitRecorder()
        drawer.delegate = recorder
        drawer.configure(deviceName: "Speaker A", trimMs: -414, isSet: true,
                         usableRangeMs: -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs,
                         alignTickActive: false)
        content.view.addSubview(drawer)
        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            drawer.topAnchor.constraint(equalTo: content.view.topAnchor),
        ])
        shell.setContent(content)
        let panel = try #require(shell.test_panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        let field = try #require(editableField(in: drawer))
        return (shell, panel, drawer, field, recorder)
    }

    @Test func returnInsideTheControlPanelPanelCommitsAndDoesNotCloseIt() throws {
        let hosted = try hostedInControlPanel()
        var closes = 0
        hosted.shell.onClose = { closes += 1 }

        try clickIn(hosted.field, window: hosted.panel)
        try typeText("25", into: hosted.field)
        try press(.newline, into: hosted.panel)

        #expect(hosted.recorder.commits == [25],
                "Return must commit inside the panel too; got \(hosted.recorder.commits)")
        #expect(closes == 0, "Return closed the control panel — the land-home contract fired")
    }

    /// The panel-specific hazard: `ControlPanelPanel` routes `cancelOperation(_:)`
    /// straight to `performClose(_:)`, so an Escape the field editor fails to
    /// consume takes the whole surface down with the edit inside it.
    ///
    /// The control at the end is what gives the assertion teeth — it drives
    /// `cancelOperation(_:)` directly, which is the ONE thing that reaches the
    /// close. A real Escape key with no editing session does NOT get there
    /// (only a responder that runs `interpretKeyEvents` translates the key
    /// into that action message), so pressing the key twice would have proved
    /// nothing at all.
    @Test func escapeIsConsumedByTheFieldAndNeverReachesThePanelsClose() throws {
        let hosted = try hostedInControlPanel()
        var closes = 0
        hosted.shell.onClose = { closes += 1 }

        try clickIn(hosted.field, window: hosted.panel)
        try typeText("25", into: hosted.field)
        try press(.escape, into: hosted.panel)

        #expect(hosted.recorder.commits.isEmpty, "Escape discards, it never commits")
        #expect(closes == 0,
                "Escape while editing closed the panel — an edit-cancel and a close are different gestures")

        // Control: the close path the key would have reached is live.
        hosted.panel.cancelOperation(nil)
        #expect(closes == 1,
                "cancelOperation no longer closes the panel — the assertion above proved nothing")
    }
}

/// The last-resort guard: whatever asks the popover to close, it is refused
/// while the drawer's field owns an editing session — and the in-flight edit is
/// committed rather than discarded. Two investigations failed to reproduce the
/// live "Return closes the popover" report because AppKit's real
/// `_NSPopoverWindow` cannot be exercised under `swift test`, so this closes the
/// hole from the other end instead of guessing at the mechanism.
@MainActor
@Suite struct SyncDrawerCloseVetoTests {

    private func btDevice() -> Device {
        Device(id: "C4-38-75-0E-BF-4A:output", name: "Move 2", kind: .bluetooth,
               isAvailable: true, supportsAirPlay2: false, connectionState: .connected)
    }

    @Test func closingIsRefusedWhileTypingAndTheEditIsKept() throws {
        var written: [Double] = []
        let popover = PopoverController()
        popover.test_isShownOverride = true
        popover.onSetBTTrim = { ms, _, _ in written.append(ms) }
        popover.update(devices: [btDevice()])
        popover.test_toggleSyncDrawer(deviceID: btDevice().id)
        let drawer = try #require(popover.test_syncDrawer)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(popover.test_panelView)
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(window.makeFirstResponder(drawer.test_valueField), "the field refused first responder")
        drawer.test_valueFieldEditor.test_beginEditing()
        let editor = try #require(drawer.test_valueField.currentEditor() as? NSTextView)
        editor.insertText("37", replacementRange: editor.selectedRange())
        #expect(drawer.isEditingValue)

        #expect(popover.popoverShouldClose(NSPopover()) == false,
                "a close request mid-edit must be refused — Return must never dismiss the surface")
        #expect(written.last == 37, "…and the in-flight edit is committed, not discarded")
        #expect(!drawer.isEditingValue, "the session ended, so the veto is one-shot")

        #expect(popover.popoverShouldClose(NSPopover()) == true,
                "with no edit in flight the ordinary dismiss gesture is untouched")
    }

    @Test func closingIsAllowedWhenNothingIsBeingEdited() {
        let popover = PopoverController()
        popover.test_isShownOverride = true
        popover.update(devices: [btDevice()])
        #expect(popover.popoverShouldClose(NSPopover()) == true)
    }
}
