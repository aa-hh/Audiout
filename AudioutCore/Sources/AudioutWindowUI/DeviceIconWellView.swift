// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

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
/// is the cue, the glyph is the button). The BADGE stays layer-backed
/// properties; the WELL surface itself draws in `draw(_:)` (see the Warm
/// Signal note below) so its tokens re-resolve live per appearance.
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
/// WARM SIGNAL (spec §1 / §5.3): the well draws itself as a real seat — a
/// rounded rect filled `raised` at the control radius (on light that is the
/// flat ground, so only the edge draws the seat) edged with
/// `containerEdge` — so the 64 pt box reads as one clickable control whose LEFT EDGE
/// aligns with the column (the previous bare glyph floated centered in an
/// invisible box, which read as a left-alignment drift against the labels
/// below it). Hovering (or keyboard focus) adds a neutral wash at
/// `PopoverColumnGrid.rowHoverWashAlpha` — spec §4.8: hover is a neutral wash
/// only, never gold — alongside the existing badge alpha step-up. When the
/// shown group is the ACTIVE Main Out target (`isActiveGroup`, set by the
/// group editor from `GroupController.activeGroupID`), the well's edge
/// becomes the thin gold ring the spec's Groups section describes ("the icon
/// well with its halo ring", §5.3) at 1.5 pt — drawing only, gold on an
/// instrument per house rule 1. The glyph inside is IDENTITY, so it is
/// `labelCool` until the group actually sounds and `label` once it does (C5),
/// and the well owns that tint: no host sets it.
/// All fills/strokes resolve inside `draw(_:)` so every token
/// re-resolves live per appearance + Increase Contrast, never a frozen
/// `.cgColor` (the `WarmCanvasView` pattern).
final class DeviceIconWellView: NSView {

    /// Square side length (approved: "~64pt"), one constant so the detail
    /// pane's and the editor's headers can never drift apart.
    static let size: CGFloat = 64

    /// Corner radius of the raised-well rounded rect (and of the focus ring /
    /// hover wash that trace the same shape) — the control radius.
    private static let wellCornerRadius: CGFloat = Tokens.Layout.Radius.control

    /// Inset from the well's edge to the glyph, so the symbol sits IN the
    /// well rather than spanning the whole box edge-to-edge.
    private static let glyphInset: CGFloat = 9

    /// Stroke widths: the resting hairline edge vs the active-group gold ring
    /// (thin per spec — an indicator, not a beacon; house rule 1 caps gold).
    private static let hairlineWidth: CGFloat = 1
    private static let activeRingWidth: CGFloat = 1.5

    private static let fadeDuration: TimeInterval = 0.12

    /// Corner badge — the sole, always-present edit affordance.
    private static let badgeDiameter: CGFloat = 22
    private static let badgeCornerInset: CGFloat = 2
    /// SHARED with the rename field's trailing pencil (`WarmNameFieldCell`) —
    /// the header carries two edit cues and they must not drift apart, so both
    /// read the same pair of alphas off the grid.
    private static let badgeRestAlpha = PopoverColumnGrid.editAffordanceRestAlpha
    private static let badgeHoverAlpha = PopoverColumnGrid.editAffordanceHoverAlpha

    let iconImageView = NSImageView()
    private let badgeView = NSView()
    private let badgePencilImageView = NSImageView()

    /// Fired on a real click (mouse-down) anywhere in the well.
    var onClick: (() -> Void)?

    /// False turns the well into a pure picture: the corner pencil badge is
    /// hidden and every interaction path (hover, click, Tab focus, Space/
    /// Return, VoiceOver press) refuses, so the well can front something whose
    /// glyph nobody chooses — the Main Audio page's whole-mix icon. Matches the
    /// module's edit-affordance vocabulary (`AGENTS.md`: bordered + pencil =
    /// editable, bare = read-only): with no badge there is no promise to break.
    var isEditable: Bool = true {
        didSet {
            guard isEditable != oldValue else { return }
            badgeView.isHidden = !isEditable
            setAccessibilityRole(isEditable ? .button : .image)
        }
    }

    /// Warm Signal §5.3: true when the group this well fronts is the ACTIVE
    /// Main Out target — the well's edge draws as the thin gold ring instead
    /// of the resting hairline. Pure model-state input (the host sets it from
    /// `GroupController.activeGroupID`), never audio-driven, matching the
    /// §3.3 "state, not signal" discipline. Drawing-only.
    var isActiveGroup: Bool = false {
        didSet {
            guard isActiveGroup != oldValue else { return }
            iconImageView.contentTintColor = isActiveGroup ? Tokens.Color.label
                                                           : Tokens.Color.labelCool
            needsDisplay = true
        }
    }

    /// True when the membership rail's origin hook lands on this well — i.e.
    /// the GROUP EDITOR's well, never the device detail pane's. The rail then
    /// visibly terminates INTO a ring of its own tone rather than butting
    /// against a neutral hairline edge (design review 2026-07-25: *"have a gold
    /// border applied around the icon element to make it feel like the rail is
    /// going into something"*).
    ///
    /// It follows the SAME active-group truth the rail does — `gold` when the
    /// group is the live Main Out target, the quiet `ember` when it's idle — so
    /// the spine and the ring it lands on are always the same colour, and the
    /// active/idle distinction the §5.3 gold ring carries is preserved rather
    /// than flattened into "always gold". Drawing-only.
    var isRailOrigin: Bool = false {
        didSet { if isRailOrigin != oldValue { needsDisplay = true } }
    }

    /// Hover/keyboard-focus state — drives the neutral wash (§4.8) drawn in
    /// `draw(_:)`; the badge alpha step-up animates separately.
    private var isHighlighted: Bool = false

    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.contentTintColor = Tokens.Color.labelCool

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = Self.badgeDiameter / 2
        badgeView.layer?.borderWidth = 1
        badgeView.alphaValue = Self.badgeRestAlpha

        let badgePencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        badgePencil?.isTemplate = true
        badgePencilImageView.translatesAutoresizingMaskIntoConstraints = false
        badgePencilImageView.image = badgePencil
        // Deliberately fixed white, not a token: the badge fill it sits on
        // (`Tokens.Color.iconWellBadge`) is itself a fixed dark scrim in both
        // themes (see that case's doc comment) precisely so this glyph never
        // has to flip too — a theme-adaptive badge would force this to chase
        // it every time.
        badgePencilImageView.contentTintColor = .white
        badgePencilImageView.imageScaling = .scaleProportionallyUpOrDown

        addSubview(iconImageView)
        addSubview(badgeView)
        badgeView.addSubview(badgePencilImageView)

        NSLayoutConstraint.activate([
            // Glyph inset from the well edge so the symbol reads as sitting
            // IN a raised well, not spanning an invisible box.
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.glyphInset),
            iconImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.glyphInset),
            iconImageView.topAnchor.constraint(equalTo: topAnchor, constant: Self.glyphInset),
            iconImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.glyphInset),

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

        restampBadgeLayerColors()
        // A mid-session Increase Contrast toggle arrives via neither `apply`
        // nor `viewDidChangeEffectiveAppearance` (AudioutSharedUI/AGENTS.md
        // — the same reason `HaloRingView` et al. observe this notification):
        // the badge's fill/border are stamped `CGColor`s on a `CALayer`, so
        // without this they would keep showing the pre-toggle alpha until
        // the next full rebuild. No matching `removeObserver` needed — AppKit
        // auto-unregisters on dealloc (post-10.11).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-stamps the corner badge's fill/border from the live
    /// `Tokens.Color.iconWellBadge`/`.iconWellBadgeBorder` — unlike the well
    /// itself (which reads `Tokens.Color` live inside `draw(_:)`, so it
    /// re-resolves on every repaint for free), the badge is a plain
    /// `CALayer` whose `backgroundColor`/`borderColor` are frozen `CGColor`
    /// snapshots that only this call updates.
    private func restampBadgeLayerColors() {
        badgeView.layer?.backgroundColor = Tokens.Color.iconWellBadge.cgColor
        badgeView.layer?.borderColor = Tokens.Color.iconWellBadgeBorder.cgColor
        test_restampCount += 1
    }

    /// Counts `restampBadgeLayerColors()` calls — a colour-equality check
    /// alone can't tell "correct already" from "never re-stamped, but
    /// happened to start correct," so the appearance-change/Increase-Contrast
    /// tests assert this instead.
    private(set) var test_restampCount = 0

    @objc private func accessibilityDisplayOptionsDidChange() {
        restampBadgeLayerColors()
        // The badge is stamped above; the WELL is drawn in `draw(_:)` off the
        // same live tokens, so it needs the repaint or it keeps its
        // standard-contrast fill and edge until something else dirties it.
        needsDisplay = true
    }

    // MARK: Warm-well drawing (Warm Signal §1/§5.3)

    /// Paints the seat: `raised` fill, `containerEdge` edge (or the thin
    /// gold ring while `isActiveGroup`), plus the neutral hover/focus wash.
    /// A `draw(_:)` override — not frozen layer colors — so every token
    /// re-resolves per appearance and Increase Contrast on every paint
    /// (`WarmCanvasView`'s pattern). Static drawing: Reduce Motion /
    /// Transparency need no special casing here (nothing animates, nothing
    /// is translucent over foreign content).
    override func draw(_ dirtyRect: NSRect) {
        // A rail origin wears the ring at its full width even when idle — the
        // spine has to land on something, and a 1pt hairline reads as an edge
        // the rail stops AT rather than one it plugs INTO.
        let wearsRing = isActiveGroup || isRailOrigin
        let strokeWidth = wearsRing ? Self.activeRingWidth : Self.hairlineWidth
        // Inset by half the stroke so the edge draws fully inside bounds.
        let rect = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: Self.wellCornerRadius,
                                yRadius: Self.wellCornerRadius)

        Tokens.Color.raised.setFill()
        path.fill()

        if isHighlighted {
            // Neutral wash only, never gold (§4.8) — `label` at the shared
            // hover alpha flips light/dark with the appearance for free.
            Tokens.Color.label.withAlphaComponent(PopoverColumnGrid.rowHoverWashAlpha).setFill()
            path.fill()
        }

        // Gold when the group is the live target; the quiet `ember` when it's
        // an idle rail origin — the exact tone the rail itself draws in, so the
        // spine and the ring it lands on never disagree. Everything else keeps
        // the neutral resting edge.
        let edge: NSColor
        if isActiveGroup {
            edge = Tokens.Color.gold
        } else if isRailOrigin {
            edge = Tokens.Color.ember
        } else {
            edge = Tokens.Color.containerEdge
        }
        edge.setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        restampBadgeLayerColors()
    }

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

    override func mouseEntered(with event: NSEvent) {
        guard isEditable else { return }
        setOverlayVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isEditable else { return }
        setOverlayVisible(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
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

    override var acceptsFirstResponder: Bool { isEditable }

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
        guard isEditable else {
            super.keyDown(with: event)
            return
        }
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
        guard isEditable else { return false }
        onClick?()
        return true
    }

    /// Draws the standard system focus ring around the well's rounded-rect
    /// shape while this view is the first responder in a key window — the
    /// same automatic ring an `NSButton` gets, computed manually here since a
    /// plain `NSView` has no default focus-ring mask. Traces the same rounded
    /// rect the warm well paints so the ring hugs the visible control.
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds,
                     xRadius: Self.wellCornerRadius,
                     yRadius: Self.wellCornerRadius).fill()
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
        // Neutral hover/focus wash on the well itself (§4.8) — an instant
        // repaint (no animation), so Reduce Motion needs no branch for it.
        if isHighlighted != visible {
            isHighlighted = visible
            needsDisplay = true
        }
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

    /// The badge layer's currently-stamped fill/border, read back as
    /// `NSColor` — asserts `restampBadgeLayerColors()` actually wrote
    /// `Tokens.Color.iconWellBadge`/`.iconWellBadgeBorder` into the layer,
    /// and that an appearance/Increase-Contrast change re-stamps them rather
    /// than leaving the layer frozen at its init-time value.
    var test_badgeFillColor: NSColor? {
        guard let cgColor = badgeView.layer?.backgroundColor else { return nil }
        return NSColor(cgColor: cgColor)
    }
    var test_badgeBorderColor: NSColor? {
        guard let cgColor = badgeView.layer?.borderColor else { return nil }
        return NSColor(cgColor: cgColor)
    }

    /// Re-stamps the badge layer as if the OS posted a live Increase Contrast
    /// toggle — exercises `accessibilityDisplayOptionsDidChange` through the
    /// real notification path, the same way `HaloRingView`'s tests drive it
    /// (`test_reduceMotionOverride`'s doc comment), rather than calling the
    /// private re-stamp method directly.
    func test_postAccessibilityDisplayOptionsChanged() {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    /// Whether the well is currently drawing the active-group gold ring
    /// (Warm Signal §5.3) instead of the resting hairline edge.
    var test_isDrawingActiveRing: Bool { isActiveGroup }

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
