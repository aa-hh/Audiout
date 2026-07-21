// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The approved custom-drawn element of the Groups window (`../../AGENTS.md`):
/// a large glyph with a single, always-present edit affordance, SHARED by the
/// device detail pane and the group editor so the two headers stay
/// pixel-identical (design feedback 2026-07-18: "keep parity between the
/// styling").
///
/// ONE affordance, not two (live-test feedback 2026-07-18b): a small circular
/// "badge" carrying a pencil glyph sits in the well's bottom-trailing corner at
/// ALL times (discoverable without a hover — the earlier hover-only scrim was
/// undiscoverable), and simply steps up in alpha when the pointer enters. The
/// earlier full-coverage hover scrim was REMOVED — a persistent badge PLUS a
/// separate full-cover pencil-on-hover read as two conflicting affordances
/// ("there's a pencil that does nothing, then a different pencil on hover").
/// The whole well is the click target (a camera-badge-style pattern: the badge
/// is the cue, the glyph is the button). Layer-backed properties, not a
/// `draw(_:)` override — the same idiom `StatusDotView` uses.
///
/// The badge step-up goes through `setOverlayVisible(_:)`, so Reduce Motion
/// (`../AGENTS.md`'s system-settings rule) disables the animation in one place:
/// a plain, instant alpha change with Reduce Motion on, a brief fade otherwise.
/// This is the one place hover state changes, so it doubles as the headless
/// test/snapshot hook.
///
/// KEYBOARD/VOICEOVER OPERABLE (A11Y-GROUPS): this is a bare `NSView`, not an
/// `NSButton`, because it needs the badge-over-glyph composition above — so it
/// earns its own first-responder/keyDown/accessibility-press plumbing rather
/// than getting it for free the way a real `NSButton` would. `acceptsFirstResponder`
/// opts it into the window's Tab key-view loop; `keyDown(with:)` maps Space/Return
/// (and the numeric-keypad Enter) onto the same `onClick` a mouse click fires;
/// `accessibilityPerformPress()` is the seam VoiceOver's "press" gesture and Full
/// Keyboard Access both call instead of a real click. Focus is drawn via the
/// standard system focus ring (`drawFocusRingMask()`) AND, like a real hover, a
/// step-up of the corner badge's alpha through the same `setOverlayVisible(_:)`
/// path — so a sighted keyboard user gets the same "this is interactive" cue a
/// mouse user gets on hover, not just the ring.
final class DeviceIconWellView: NSView {

    /// Square side length (approved: "~64pt"), one constant so the detail
    /// pane's and the editor's headers can never drift apart.
    static let size: CGFloat = 64

    private static let fadeDuration: TimeInterval = 0.12

    /// Corner badge — the sole, always-present edit affordance.
    private static let badgeDiameter: CGFloat = 22
    private static let badgeCornerInset: CGFloat = 2
    private static let badgeRestAlpha: CGFloat = 0.7
    private static let badgeHoverAlpha: CGFloat = 1.0
    private static let badgeColor = NSColor(white: 0, alpha: 0.55)
    private static let badgeBorderColor = NSColor(white: 1, alpha: 0.25)

    let iconImageView = NSImageView()
    private let badgeView = NSView()
    private let badgePencilImageView = NSImageView()

    /// Fired on a real click (mouse-down) anywhere in the well.
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = Self.badgeDiameter / 2
        badgeView.layer?.backgroundColor = Self.badgeColor.cgColor
        badgeView.layer?.borderWidth = 1
        badgeView.layer?.borderColor = Self.badgeBorderColor.cgColor
        badgeView.alphaValue = Self.badgeRestAlpha

        let badgePencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        badgePencil?.isTemplate = true
        badgePencilImageView.translatesAutoresizingMaskIntoConstraints = false
        badgePencilImageView.image = badgePencil
        badgePencilImageView.contentTintColor = .white
        badgePencilImageView.imageScaling = .scaleProportionallyUpOrDown

        addSubview(iconImageView)
        addSubview(badgeView)
        badgeView.addSubview(badgePencilImageView)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconImageView.topAnchor.constraint(equalTo: topAnchor),
            iconImageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Rest-state badge, bottom-trailing corner, slightly inset.
            badgeView.widthAnchor.constraint(equalToConstant: Self.badgeDiameter),
            badgeView.heightAnchor.constraint(equalToConstant: Self.badgeDiameter),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.badgeCornerInset),
            badgeView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.badgeCornerInset),

            badgePencilImageView.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            badgePencilImageView.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            badgePencilImageView.widthAnchor.constraint(equalToConstant: Self.badgeDiameter * 0.45),
            badgePencilImageView.heightAnchor.constraint(equalToConstant: Self.badgeDiameter * 0.45),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Edit icon")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setOverlayVisible(true) }
    override func mouseExited(with event: NSEvent) { setOverlayVisible(false) }

    override func mouseDown(with event: NSEvent) {
        // A real click also claims first responder, exactly like a genuine
        // `NSButton` would — otherwise a mouse click leaves whatever was
        // focused before still focused, and the very next Tab jumps from
        // there instead of from the well the user just interacted with.
        window?.makeFirstResponder(self)
        onClick?()
    }

    // MARK: Keyboard / VoiceOver operability (A11Y-GROUPS)
    //
    // This view has no `NSButton` underneath it (see the class doc comment),
    // so none of the following is inherited for free — each override mirrors
    // exactly what `NSButton` would already give it.

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { setOverlayVisible(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setOverlayVisible(false) }
        return resigned
    }

    /// Space, Return, and the numeric-keypad Enter all activate the well —
    /// the same set `NSButton` treats as "press" from the keyboard. Any other
    /// key falls through to `super` so this doesn't swallow e.g. Tab (which
    /// AppKit resolves to key-view-loop traversal before `keyDown` even sees
    /// it, but falling through keeps this view from becoming an unintended
    /// sink for keys it has no opinion on).
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}":   // space, Return, keypad Enter
            onClick?()
        default:
            super.keyDown(with: event)
        }
    }

    /// The VoiceOver / Full Keyboard Access "press" entry point — fired
    /// instead of a real click when the user activates this element via
    /// assistive technology rather than a pointer.
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// Draws the standard system focus ring around the well's full bounds
    /// while this view is the first responder in a key window — the same
    /// automatic ring an `NSButton` gets, computed manually here since a
    /// plain `NSView` has no default focus-ring mask.
    override func drawFocusRingMask() {
        NSBezierPath(rect: bounds).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    /// Step the badge between its rest and hover alpha. Respects Reduce Motion
    /// (`../AGENTS.md`'s system-settings rule): an instant change with Reduce
    /// Motion on, a brief fade otherwise. This is the one place hover OR
    /// keyboard-focus state changes, so it doubles as the headless test/
    /// snapshot hook. (Name kept as `setOverlayVisible` for the existing
    /// test/snapshot call sites; there is no longer a full-coverage overlay —
    /// only the badge.)
    func setOverlayVisible(_ visible: Bool) {
        let badgeAlpha = visible ? Self.badgeHoverAlpha : Self.badgeRestAlpha
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            badgeView.alphaValue = badgeAlpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            badgeView.animator().alphaValue = badgeAlpha
        }
    }

    // MARK: Test-support hooks

    /// The corner badge's current alpha — asserts the hover-OR-focus step-up
    /// (`setOverlayVisible(_:)`), including the keyboard-focus case a headless
    /// run can't observe visually.
    var test_badgeAlpha: CGFloat { badgeView.alphaValue }

    /// Simulate a real Space/Return key press on this view via the actual
    /// `keyDown(with:)` override (not a direct `onClick?()` call) — proves
    /// the key maps to activation the same way a live keypress would.
    /// Mirrors the "no synthesized clicks in headless runs" house rule
    /// (`../AGENTS.md`) for the keyboard path: no real window is needed since
    /// `keyDown(with:)` never touches `window`.
    func test_pressKey(_ characters: String) {
        keyDown(with: Self.keyEvent(charactersIgnoringModifiers: characters))
    }

    private static func keyEvent(charactersIgnoringModifiers: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: charactersIgnoringModifiers,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: 0)!
    }
}
