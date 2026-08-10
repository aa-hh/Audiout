// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI

/// ``SyncValueFieldEditor`` driven by **real AppKit key dispatch** — a
/// synthesized `NSEvent` posted through a real `NSWindow.sendEvent(_:)` into a
/// real field editor — rather than through the type's `test_performCommand(_:)`
/// seam.
///
/// WHY NOT THE SEAM. `test_performCommand(_:)` calls
/// `control(_:textView:doCommandBy:)` directly, so it proves only that the
/// method returns the right value for a selector someone handed it. It cannot
/// prove the two things a user actually depends on:
///
///  1. that AppKit **routes** a real Return/Escape/arrow keystroke into that
///     method at all (the field must be first responder, a field editor must
///     be installed, and the field's delegate must still be the editor); and
///  2. that returning `true` actually **stops** the key — nothing bubbling
///     past the field to the enclosing `.transient` `NSPopover`, which closes
///     on a stray Return or Escape and takes the half-typed edit with it.
///
/// A live report of exactly that failure passed every seam-level test green,
/// which is the gap this file exists to close. Do not "simplify" these tests
/// back onto `test_performCommand` — the direct call is precisely what cannot
/// see the bug.
///
/// NON-PROPAGATION is observed with ``KeyWitnessView``: the field's own
/// superview, and therefore the FIRST rung of the responder chain above the
/// field editor. Anything that reaches a host popover must pass through here
/// on the way, so "the witness saw nothing" is the honest headless equivalent
/// of "the popover stayed open".
///
/// SCOPE: the field editor in isolation, deliberately hosted on a bare
/// `NSTextField` rather than inside `BTSyncDrawerView`. A failure here is a
/// defect in the editor; a pass here means the editor's contract holds and any
/// remaining live failure comes from the host's mounting context, not this
/// type.
@MainActor
@Suite struct SyncValueFieldLiveKeyTests {

    // MARK: Harness

    /// Records what got past the field. Overrides swallow rather than call
    /// `super` on purpose: the witness stands in for the host that would have
    /// acted on the key, so it must absorb it exactly as that host would.
    private final class KeyWitnessView: NSView {
        var keyDowns: [NSEvent] = []
        var commands: [Selector] = []

        override func keyDown(with event: NSEvent) { keyDowns.append(event) }
        override func doCommand(by selector: Selector) { commands.append(selector) }

        var sawNothing: Bool { keyDowns.isEmpty && commands.isEmpty }
        var summary: String {
            "keyDowns=\(keyDowns.map(\.keyCode)) commands=\(commands.map { String(describing: $0) })"
        }
    }

    /// Stands in for ``SyncValueFieldEditor`` as the field's delegate to record
    /// the raw selector AppKit routes for a keystroke. Returns `false` so the
    /// field editor keeps its stock behaviour and the recording never changes
    /// what the key does.
    private final class SelectorProbe: NSObject, NSTextFieldDelegate {
        var selectors: [Selector] = []

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            selectors.append(commandSelector)
            return false
        }
    }

    private final class CommitRecorder: SyncValueFieldEditorDelegate {
        var commits: [Double] = []
        func syncValueFieldEditor(_ editor: SyncValueFieldEditor, didCommit ms: Double) {
            commits.append(ms)
        }
    }

    /// The keys under test, paired with the `keyCode`/`characters` a real
    /// keyboard sends. `NSTextView.interpretKeyEvents` resolves these through
    /// the standard key bindings, so both halves have to be right — a bare
    /// `characters` string with a zero keyCode is not the same event.
    private enum Key {
        case newline, escape, up, down

        var code: UInt16 {
            switch self {
            case .newline: return 36
            case .escape: return 53
            case .up: return 126
            case .down: return 125
            }
        }

        var characters: String {
            switch self {
            case .newline: return "\r"
            case .escape: return "\u{1b}"
            case .up: return "\u{F700}"      // NSUpArrowFunctionKey
            case .down: return "\u{F701}"    // NSDownArrowFunctionKey
            }
        }
    }

    @MainActor
    private final class Harness {
        let window: NSWindow
        let witness: KeyWitnessView
        let field: NSTextField
        let editor: SyncValueFieldEditor
        let recorder = CommitRecorder()

        /// Never ordered on screen — `HeadlessRuntime` bars a real window from
        /// flashing during `swift test`, and none of this needs one. A
        /// `.titled` mask is load-bearing anyway: a borderless window refuses
        /// to take a first responder that wants to edit text.
        init(initialValue: Double = 0, restingText: String = "Not set") {
            let frame = NSRect(x: 0, y: 0, width: 240, height: 48)
            witness = KeyWitnessView(frame: frame)
            window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.contentView = witness

            field = NSTextField(frame: NSRect(x: 12, y: 12, width: 120, height: 22))
            field.isEditable = true
            field.isSelectable = true
            witness.addSubview(field)

            editor = SyncValueFieldEditor(field: field, initialValue: initialValue)
            editor.delegate = recorder
            editor.setCommittedValue(initialValue, displayText: restingText)
        }

        @discardableResult
        func focusField() -> Bool { window.makeFirstResponder(field) }

        /// Focus the field AND put it in the state a live click leaves it in.
        ///
        /// TRAP: a programmatic `makeFirstResponder` installs the field editor
        /// and selects its text, but does NOT post AppKit's begin-editing
        /// notification — a real click does. Without it the delegate's
        /// resting-text → signed-number swap is deferred until AppKit fires
        /// the notification from inside the FIRST insertion, which rewrites
        /// the storage mid-transaction and aborts the process with an
        /// `NSRangeException` (the pending replacement range still describes
        /// the longer resting string). Supplying the one missing notification
        /// here is the whole simulation; every keystroke after it is real.
        @discardableResult
        func clickIn() -> Bool {
            let focused = focusField()
            editor.test_beginEditing()
            return focused
        }

        /// The live field editor, i.e. what AppKit actually installed —
        /// `nil` means editing never began and every assertion below is
        /// meaningless.
        var fieldEditor: NSTextView? { field.currentEditor() as? NSTextView }

        /// Text goes in through the field editor's own `insertText`, the exact
        /// call `interpretKeyEvents` makes for a printable character. The keys
        /// under test here are the COMMAND keys, so per-digit key events would
        /// only add a second way for the test to fail.
        func type(_ text: String) {
            guard let fieldEditor else { return }
            fieldEditor.insertText(text, replacementRange: fieldEditor.selectedRange())
        }

        func press(_ key: Key, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: key.characters,
                charactersIgnoringModifiers: key.characters,
                isARepeat: false,
                keyCode: key.code), "AppKit refused to build the key event")
            window.sendEvent(event)
        }
    }

    // MARK: The routing precondition every case below rests on

    /// If AppKit never installs a field editor, no keystroke can reach
    /// `control(_:textView:doCommandBy:)` and the rest of this file proves
    /// nothing. Asserted on its own so a harness failure never reads as a
    /// product failure.
    @Test func focusInstallsARealFieldEditorAsFirstResponder() throws {
        let harness = Harness()
        #expect(harness.focusField(), "the window refused to give the field first responder")
        let fieldEditor = try #require(harness.fieldEditor,
                                       "no field editor installed — nothing can route a keystroke to the delegate")
        #expect(harness.window.firstResponder === fieldEditor,
                "the field editor, not the field, must hold first responder for real key dispatch")
        #expect(harness.field.delegate === harness.editor,
                "the editor is still the field's delegate — the seam AppKit routes commands through")
    }

    // MARK: Return — the reported live failure

    @Test func returnCommitsTheTypedValue() throws {
        let harness = Harness()
        harness.clickIn()
        harness.type("25")

        try harness.press(.newline)

        #expect(harness.recorder.commits == [25],
                "Return must commit the typed value; got \(harness.recorder.commits)")
    }

    @Test func returnIsConsumedAndNeverReachesTheHost() throws {
        let harness = Harness()
        harness.clickIn()
        harness.type("25")

        try harness.press(.newline)

        #expect(harness.witness.sawNothing,
                "Return escaped the field — a transient popover would have closed on this. \(harness.witness.summary)")
    }

    // MARK: Escape — reverts the edit, never closes the host

    @Test func escapeRevertsTheEditAndIsConsumed() throws {
        let harness = Harness(initialValue: 12, restingText: "12 ms later")
        harness.clickIn()
        harness.type("25")

        try harness.press(.escape)

        #expect(harness.recorder.commits.isEmpty,
                "Escape discards, it never commits; got \(harness.recorder.commits)")
        #expect(harness.editor.test_fieldText == "12",
                "Escape restores the committed value in its signed editing form; got \(harness.editor.test_fieldText)")
        #expect(harness.witness.sawNothing,
                "Escape escaped the field — the host would have read it as 'close the drawer'. \(harness.witness.summary)")
    }

    // MARK: Arrows — the nudge contract, at real resolution

    @Test func upArrowNudgesByOneResolutionStep() throws {
        let harness = Harness(initialValue: 12, restingText: "12 ms later")
        harness.clickIn()

        try harness.press(.up)

        #expect(harness.recorder.commits == [12 + BTSyncTrim.resolutionMs],
                "↑ nudges by resolutionMs; got \(harness.recorder.commits)")
        #expect(harness.witness.sawNothing, "\(harness.witness.summary)")
    }

    @Test func downArrowNudgesByOneResolutionStep() throws {
        let harness = Harness(initialValue: 12, restingText: "12 ms later")
        harness.clickIn()

        try harness.press(.down)

        #expect(harness.recorder.commits == [12 - BTSyncTrim.resolutionMs],
                "↓ nudges by resolutionMs; got \(harness.recorder.commits)")
        #expect(harness.witness.sawNothing, "\(harness.witness.summary)")
    }

    /// ⇧↑ / ⇧↓ take the coarse step. WHICH SPELLING ARRIVES is the thing only
    /// real dispatch can answer, and it decides whether the editor's switch
    /// statement has a limb for the key at all — see
    /// ``shiftArrowsArriveAsTheSelectionModifyingSelectors``, which pins the
    /// answer. The modifier-reading `moveUp:`/`moveDown:` limbs cannot be the
    /// live path here: `NSApp.currentEvent` stays nil under
    /// `NSWindow.sendEvent(_:)`, so a coarse-sized commit proves a
    /// modifier-free selector did the work.
    @Test func shiftUpArrowTakesTheCoarseStep() throws {
        let harness = Harness(initialValue: 12, restingText: "12 ms later")
        harness.clickIn()

        try harness.press(.up, modifiers: .shift)

        #expect(harness.recorder.commits == [12 + BTSyncTrim.coarseStepMs],
                "⇧↑ nudges by coarseStepMs; got \(harness.recorder.commits)")
        #expect(harness.witness.sawNothing, "\(harness.witness.summary)")
    }

    @Test func shiftDownArrowTakesTheCoarseStep() throws {
        let harness = Harness(initialValue: 12, restingText: "12 ms later")
        harness.clickIn()

        try harness.press(.down, modifiers: .shift)

        #expect(harness.recorder.commits == [12 - BTSyncTrim.coarseStepMs],
                "⇧↓ nudges by coarseStepMs; got \(harness.recorder.commits)")
        #expect(harness.witness.sawNothing, "\(harness.witness.summary)")
    }

    /// ⇧↑/⇧↓ must ALSO leave the text selection alone. The selectors Cocoa
    /// binds them to exist to EXTEND a selection; if the editor ever stops
    /// intercepting them the visible symptom is not a wrong number but a
    /// silently selected field, which is easy to miss by eye.
    @Test func shiftArrowsNudgeInsteadOfExtendingTheSelection() throws {
        let harness = Harness(initialValue: 12, restingText: "12 ms later")
        harness.clickIn()
        harness.type("25")
        let caret = try #require(harness.fieldEditor).selectedRange()

        try harness.press(.up, modifiers: .shift)

        #expect(try #require(harness.fieldEditor).selectedRange().length == caret.length,
                "⇧↑ extended the text selection instead of nudging the value")
    }

    // MARK: What AppKit actually delivers

    /// The empirical record of which selectors reach a field editor's delegate
    /// for each key under test — the fact the editor's `switch` is written
    /// against, and the one thing `test_performCommand(_:)` can never tell you
    /// (it takes the selector as an argument, so it assumes the answer).
    /// A binding change in a future macOS shows up here as a failure rather
    /// than as a dead `case` nobody notices.
    @Test func shiftArrowsArriveAsTheSelectionModifyingSelectors() throws {
        let harness = Harness()
        let probe = SelectorProbe()
        harness.field.delegate = probe
        harness.clickIn()

        try harness.press(.newline)
        try harness.press(.escape)
        try harness.press(.up)
        try harness.press(.down)
        try harness.press(.up, modifiers: .shift)
        try harness.press(.down, modifiers: .shift)

        #expect(probe.selectors.map { String(describing: $0) } == [
            "insertNewline:",
            "cancelOperation:",
            "moveUp:",
            "moveDown:",
            "moveUpAndModifySelection:",
            "moveDownAndModifySelection:",
        ], "got \(probe.selectors.map { String(describing: $0) })")
    }

    // MARK: Focus loss

    /// Clicking away must not evaporate the edit. Driven by a real first
    /// responder change so AppKit tears the field editor down itself and posts
    /// the end-editing notification — the same sequence a click on another
    /// control produces.
    @Test func losingFirstResponderCommitsTheTypedValue() throws {
        let harness = Harness()
        harness.clickIn()
        harness.type("25")

        #expect(harness.window.makeFirstResponder(nil),
                "could not move first responder away — the commit path was never exercised")

        #expect(harness.recorder.commits == [25],
                "focus loss must commit whatever was typed; got \(harness.recorder.commits)")
    }

    // MARK: The edit-begin swap, driven WITHOUT the harness's `clickIn`
    //
    // Every case above supplies the begin-editing notification itself, before
    // any text goes in. These four do the opposite on purpose: they let AppKit
    // fire it from INSIDE the first insertion, which is when
    // `controlTextDidBeginEditing` is rewriting the field's text out from
    // under a live edit. The resting text is deliberately LONGER than the
    // signed replacement, so the swap shortens the storage while the field
    // editor still holds a selection describing the longer string — the exact
    // shape that raises `NSRangeException` and takes the whole process down
    // when the swap re-states that selection by hand instead of through
    // `selectAll(nil)`. There is nothing to assert about an abort: a raised
    // NSException kills the test runner, so REACHING the expectations at all
    // is the result. They ran green against a hand-rolled explicit range and
    // caught it aborting.

    @Test func firstKeystrokeOnLongerRestingTextSurvivesTheEditBeginSwap() throws {
        let harness = Harness(initialValue: 0, restingText: "Not set")
        harness.focusField()   // NOT clickIn — AppKit posts begin-editing itself
        harness.type("25")

        #expect(harness.editor.test_fieldText == "25",
                "the whole resting string was selected, so typing replaces it; got \(harness.editor.test_fieldText)")
        try harness.press(.newline)
        #expect(harness.recorder.commits == [25],
                "the value still commits after the mid-insertion swap; got \(harness.recorder.commits)")
    }

    /// The caret placed past the replacement's length — what a real click into
    /// the middle or end of a long resting string leaves behind, and the range
    /// least likely to still be valid after the swap.
    @Test func firstKeystrokeWithTheCaretPastTheReplacementLengthSurvives() throws {
        let harness = Harness(initialValue: -500, restingText: "500 ms earlier")
        harness.focusField()
        try #require(harness.fieldEditor).selectedRange = NSRange(location: 14, length: 0)
        harness.type("7")

        // Whatever AppKit settles on, an unparseable result must fall back to
        // the committed value rather than commit garbage.
        try harness.press(.newline)
        #expect(harness.recorder.commits == [-500] || harness.recorder.commits == [7],
                "commit is either the typed value or the unchanged baseline, never garbage; got \(harness.recorder.commits)")
    }

    /// The drawer's own case: the host's resting text ALREADY is the signed
    /// number, so the swap has nothing to do. It must then leave the live edit
    /// completely alone — no storage rewrite, no re-selection.
    @Test func aNoOpSwapDoesNotDisturbALiveEdit() throws {
        let harness = Harness(initialValue: -414, restingText: "-414")
        harness.focusField()
        let editor = try #require(harness.fieldEditor)
        editor.selectedRange = NSRange(location: 4, length: 0)   // caret at the end

        harness.editor.test_beginEditing()

        #expect(editor.selectedRange() == NSRange(location: 4, length: 0),
                "an identical resting text must not re-select the field; got \(editor.selectedRange())")
        #expect(harness.editor.test_fieldText == "-414")
    }

    /// And the swap still does its job when it genuinely has one: a resting
    /// string the user should not be typing into gets replaced and selected,
    /// so the first character wipes it.
    @Test func aRealSwapReplacesTheRestingTextAndSelectsIt() throws {
        let harness = Harness(initialValue: 12, restingText: "12 ms later")
        harness.focusField()

        harness.editor.test_beginEditing()

        #expect(harness.editor.test_fieldText == "12",
                "the prose resting form is replaced by the plain signed number")
        #expect(try #require(harness.fieldEditor).selectedRange()
                == NSRange(location: 0, length: 2),
                "…and it is fully selected, so typing replaces it")
    }
}
