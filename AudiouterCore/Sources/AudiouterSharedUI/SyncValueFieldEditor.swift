// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// Reports a committed edit from a ``SyncValueFieldEditor``.
public protocol SyncValueFieldEditorDelegate: AnyObject {
    /// Fired on every commit — Return, focus loss, ↑/↓, or ⌥↑/↓ — never on a
    /// keystroke alone. Already quantised via `BTSyncTrim.quantise`; the
    /// host is responsible for its own range clamp (see `clamp` below).
    func syncValueFieldEditor(_ editor: SyncValueFieldEditor, didCommit ms: Double)
}

/// Shared decimal-millisecond text-field editing behaviour, lifted out of
/// `DeviceRowView.syncField` (BT-OFFSET-UI) so the drawer's click-to-edit
/// readout (PLAN-BT-SYNC-DRAWER T5) doesn't fork a second copy of the
/// hard-won Return/focus-loss/arrow handling — that behaviour was expensive
/// to get right the first time (see the row's own commit history) and this
/// type exists so a second control never has to re-learn it. `DeviceRowView`
/// keeps its own copy for now; T6 deletes it and switches the row over to
/// this type. The brief duplication between the two commits is expected and
/// fine per the plan.
///
/// Two behaviours the row's field never needed, both required here:
/// - **Tolerant parsing.** Parses `Double(...)` and quantises through
///   `BTSyncTrim.quantise`, so a typed "22.6" (or a stale 0.1 ms value read
///   from an older on-disk store) snaps cleanly to whole ms rather than being
///   rejected. The drawer resolves to whole milliseconds.
/// - **Escape reverts.** The row's field had no call site that ever needed
///   it (Return/blur were the only exits). A free-typing readout does: typed
///   text the user changed their mind about must not evaporate silently on
///   the next blur, it must be discardable on demand.
///
/// **Signed while editing, host-formatted at rest.** The drawer's readout
/// shows a bare magnitude beside a "later"/"earlier" suffix (D7 — never a
/// bare signed number) but the underlying trim IS signed, so a no-op edit
/// (click in, press Return with nothing changed) must not silently flip its
/// direction. The fix: the field shows the host's `displayText` (from
/// ``setCommittedValue(_:displayText:)``) whenever it is not being edited,
/// and switches to a plain signed number (`"-22.4"`) the instant editing
/// begins — round-tripping an untouched edit back to the exact same signed
/// value it started at.
public final class SyncValueFieldEditor: NSObject, NSTextFieldDelegate {

    public weak var delegate: SyncValueFieldEditorDelegate?

    /// Clamps a candidate value (quantised, not yet range-checked) before it
    /// is ever shown or committed — the host's usable-range floor/ceiling
    /// (T3/D11). Defaults to the identity so a host that never sets this
    /// still gets correct (merely unclamped) behaviour. Reads the host's
    /// CURRENT range live on every call rather than a value captured once,
    /// so the host can just close over its own mutable state.
    public var clamp: (Double) -> Double = { $0 }

    private let field: NSTextField
    private var committedMs: Double

    public init(field: NSTextField, initialValue: Double) {
        self.field = field
        self.committedMs = initialValue
        super.init()
        field.delegate = self
    }

    /// Push a fresh model value + the host's formatted resting text (e.g.
    /// magnitude-only, or "Not set"). Guarded exactly like
    /// `DeviceRowView.configure` guards `syncField` — never yanks the
    /// DISPLAYED text out from under an in-progress edit. The internal
    /// baseline (`committedMs`, what an unparseable edit or a nudge falls
    /// back to) updates unconditionally either way — the same split
    /// `DeviceRowView.configure` already makes between `self.syncTrimMs` and
    /// the guarded `syncField.stringValue`.
    public func setCommittedValue(_ ms: Double, displayText: String) {
        committedMs = ms
        guard field.currentEditor() == nil else { return }
        field.stringValue = displayText
    }

    // MARK: NSTextFieldDelegate

    /// Editing began (the user clicked in): switch from the host's resting
    /// format to a plain signed number and select it all, so typing
    /// immediately replaces it — the click-to-edit affordance the drawer's
    /// visual contract calls for.
    ///
    /// **TRAP — AppKit posts this notification from INSIDE the first text
    /// change, so the swap must never run synchronously here.** At this
    /// instant the field editor still holds the host's resting string and is
    /// part-way through replacing a range of it with the character the user
    /// just typed. Rewriting the text now shortens the storage under that
    /// range ("Not set" → "0"), and AppKit's completion of the same keystroke
    /// then reads it back and aborts the process:
    /// `NSRangeException … Range {0, 7} out of bounds; string length 1`.
    /// Nothing done inside this call can repair that — the range was captured
    /// before the delegate ran — so the swap is deferred one turn instead, by
    /// which point the keystroke has landed.
    ///
    /// Deferring costs nothing: if the user typed, AppKit's own replacement
    /// already put the typed characters in place of the resting text, which is
    /// exactly what the swap existed to arrange, and the guard below leaves
    /// them alone. If they only clicked in, the text is untouched and the swap
    /// runs a frame later. `test_beginEditing()` applies it synchronously —
    /// there is no in-flight change to stay out of the way of.
    public func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === field else { return }
        let resting = field.stringValue
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.field.currentEditor(),
                  editor.string == resting else { return }
            self.applyEditingForm()
        }
    }

    /// Replace the host's resting text with the plain signed number and select
    /// it, so the next character typed replaces it. A no-op when the resting
    /// text already IS that number — the drawer's ordinary case — so a live
    /// selection is never disturbed for nothing.
    private func applyEditingForm() {
        let signed = Self.signedText(committedMs)
        guard field.stringValue != signed else { return }
        field.stringValue = signed
        field.currentEditor()?.selectAll(nil)
    }

    /// The field editor's command dispatch — the one seam AppKit routes
    /// Return, the arrow keys, and Escape through while editing.
    ///
    /// - Return COMMITS and returns `true`: consumed, so the key never
    ///   bubbles past the field (un-consumed it closes the host popover with
    ///   the edit lost — the row field's own live finding, BT-OFFSET-UI).
    /// - ↑/↓ nudge by `resolutionMs` (1 ms); ⇧↑/↓ by `coarseStepMs` (10 ms) —
    ///   ⇧ is macOS's standard 10× stepper modifier, and the drawer's −/+
    ///   buttons take the same modifier for the same step, so one gesture
    ///   never means two things inside one control.
    ///   ⇧-arrows arrive as the SELECTION-MODIFYING selectors (Cocoa's
    ///   standard key bindings: in a text view ⇧↑ extends the selection), not
    ///   as `moveUp:`/`moveDown:` carrying the modifier — so those spellings
    ///   are the live path and must be intercepted, or ⇧↑ silently selects
    ///   text instead of nudging. The plain `moveUp:`/`moveDown:` limbs still
    ///   consult the modifier, since a remapped key binding can deliver
    ///   either.
    /// - Escape REVERTS the typed-but-uncommitted text back to the last
    ///   committed value (still in its signed editing form, since focus
    ///   remains) and returns `true`: consumed, so it does not also bubble
    ///   up as `cancelOperation:` and trigger a host's "close the whole
    ///   drawer" handling (`BTSyncDrawerView.cancelOperation`) — an edit
    ///   escape and a drawer-close escape are different gestures that happen
    ///   to share a key.
    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        guard control === field else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit(parsing: field.stringValue)
            return true
        case #selector(NSResponder.moveUp(_:)):
            nudge(by: shiftIsHeld ? BTSyncTrim.coarseStepMs : BTSyncTrim.resolutionMs)
            return true
        case #selector(NSResponder.moveDown(_:)):
            nudge(by: -(shiftIsHeld ? BTSyncTrim.coarseStepMs : BTSyncTrim.resolutionMs))
            return true
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            nudge(by: BTSyncTrim.coarseStepMs)
            return true
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            nudge(by: -BTSyncTrim.coarseStepMs)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            revert()
            return true
        default:
            return false
        }
    }

    /// Focus loss (click-away, Tab) commits whatever was typed — an edit
    /// must never silently evaporate because the user clicked another
    /// control.
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === field else { return }
        commit(parsing: field.stringValue)
    }

    // MARK: Commit / revert

    private func commit(parsing text: String) {
        let cleaned = text
            .replacingOccurrences(of: "ms", with: "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")   // typography minus
        let next = Double(cleaned).map(BTSyncTrim.quantise) ?? committedMs
        apply(clamp(next))
    }

    private func nudge(by deltaMs: Double) {
        apply(clamp(BTSyncTrim.quantise(committedMs + deltaMs)))
    }

    private func apply(_ ms: Double) {
        committedMs = ms
        field.stringValue = Self.signedText(ms)
        delegate?.syncValueFieldEditor(self, didCommit: ms)
    }

    private func revert() {
        field.stringValue = Self.signedText(committedMs)
        field.currentEditor()?.selectAll(nil)
    }

    private static func signedText(_ ms: Double) -> String {
        String(format: "%.0f", ms)   // whole ms — decimals were cut (see BTSyncTrim)
    }

    // MARK: ⇧ modifier seam. Even a REAL key event dispatched through
    // `NSWindow.sendEvent(_:)` leaves `NSApp.currentEvent` unset — it is
    // populated by the run loop's `nextEventMatchingMask:`, not by delivery —
    // and in a narrowly filtered `swift test` run `NSApp` itself (an
    // implicitly-unwrapped optional) can still be nil, so this reads it via
    // `?` and never force-unwraps. The override is how a headless test drives
    // the modifier limb at all.
    public var test_shiftModifierOverride: Bool?

    private var shiftIsHeld: Bool {
        test_shiftModifierOverride ?? (NSApp?.currentEvent?.modifierFlags.contains(.shift) ?? false)
    }

    // MARK: Test hooks — real dispatch through the exact delegate seam
    // (house convention, `AudiouterSharedUI/AGENTS.md`)

    public var test_fieldText: String { field.stringValue }

    public func test_setFieldText(_ text: String) { field.stringValue = text }

    /// The "user clicked in" transition, applied SYNCHRONOUSLY. It runs the
    /// same `applyEditingForm()` the notification path ends at, minus that
    /// path's one-turn deferral — which exists only to stay out of AppKit's
    /// in-flight keystroke and has nothing to stay out of the way of here.
    public func test_beginEditing() { applyEditingForm() }

    /// Drives `control(_:textView:doCommandBy:)` with the real field — the
    /// identical call the field editor makes for Return/arrows/Escape.
    /// Returns the consumed flag.
    @discardableResult
    public func test_performCommand(_ commandSelector: Selector) -> Bool {
        control(field, textView: NSTextView(), doCommandBy: commandSelector)
    }

    /// Drives `controlTextDidEndEditing` with the real field (focus loss).
    public func test_endEditing() {
        controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification, object: field))
    }
}
