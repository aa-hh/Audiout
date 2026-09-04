// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The header strip's ONE seat: the shape, the size and the wash strengths
/// every item in `SurfaceToolbarController` draws itself with — the three
/// screen tabs AND Pin, all of them, which is the whole point.
///
/// **The defect this replaces** (Alec, 2026-09-04). The items were bordered
/// `NSToolbarItem`s, and AppKit draws a bordered item's HOVER state as a
/// circle and its SELECTED state as a rounded square: two shapes for two
/// states of one control. Owning the drawing is the only way to make one
/// shape carry every state, because neither shape is settable.
///
/// **Why all four items and not just the tabs.** Converting only the tabs is
/// exactly what failed live review on 2026-08-30 — three bare glyphs beside
/// two bordered circles, two styles in one header. The strip is converted
/// whole or not at all.
///
/// Every number below is a plain value drawn with `NSBezierPath` on every
/// macOS the package supports. **Nothing here is behind `#available`**, and
/// nothing may be: the package deploys to 14.2, and the version this replaces
/// put its every cue inside `if #available(macOS 26.0, *)`, so macOS 14–25
/// showed three identical circles and no current screen at all.
enum SurfaceToolbarSeat {

    /// The one rounded rectangle every seat is, in every state. No circles
    /// anywhere in the strip. 10 pt on a 26 pt-tall seat leaves 6 pt of
    /// straight edge top and bottom and 10 pt across, so it reads as a
    /// rounded rectangle rather than the capsule a larger radius would give.
    static let cornerRadius: CGFloat = Tokens.Layout.Radius.control

    /// Each item's fixed seat. Fixed, and icon-only, so the strip's width
    /// cannot change with the selection, the appearance or the language —
    /// which is what would sweep the tabs behind the overflow chevron, and
    /// primary navigation cannot live behind a chevron.
    static let size = NSSize(width: 30, height: 26)

    /// The glyph size inside that seat.
    static let glyphPointSize: CGFloat = 15

    /// How much stronger every seat draws while Increase Contrast is on. One
    /// factor over the whole ladder, so the three strengths keep their
    /// spacing instead of collapsing into each other. Read LIVE at draw time
    /// (see `SurfaceToolbarSeatCell.drawBezel`), never snapshotted.
    static let increaseContrastGain: CGFloat = 1.5

    /// The strength of the neutral wash a seat fills with, or `nil` when no
    /// seat is drawn at all.
    ///
    /// Three rungs of the ladder `Tokens.Color.engagedChrome` already
    /// documents, in the order that token names them, so the header's
    /// "this control is engaged" weights are the mixer's:
    ///
    /// - **rest** — no seat. An idle tab is its glyph, and so is an unpinned
    ///   Pin: one style across the strip.
    /// - **hover** — `PopoverColumnGrid.rowHoverWashAlpha` (0.10), the wash
    ///   every row in the app already uses under the pointer.
    /// - **engaged** — `rowSelectionWashAlpha` (0.18): the current screen,
    ///   and Pin while pinned.
    /// - **pressed** — `mutePillFillAlpha` (0.22), one rung above engaged, so
    ///   a press reads under the finger wherever it lands.
    ///
    /// NEUTRAL, never gold: gold means audio in the mix, and a header seat is
    /// navigation. `engagedChrome` is dynamic, so the wash is white-on-dark
    /// and black-on-light — the selected seat is LIGHTER than the strip in
    /// dark mode, which the authored fill this replaces got backwards.
    static func fillAlpha(isEngaged: Bool, isHovered: Bool, isPressed: Bool,
                          increaseContrast: Bool) -> CGFloat? {
        let base: CGFloat
        if isPressed {
            base = PopoverColumnGrid.mutePillFillAlpha
        } else if isEngaged {
            base = PopoverColumnGrid.rowSelectionWashAlpha
        } else if isHovered {
            base = PopoverColumnGrid.rowHoverWashAlpha
        } else {
            return nil
        }
        return increaseContrast ? min(base * increaseContrastGain, 1) : base
    }

    /// The glyph's ink. It steps with the seat rather than against it, so the
    /// current screen is marked twice — a seat and a full-strength glyph —
    /// and stays legible where the 0.18 wash alone is subtle.
    static func glyphTint(isEngaged: Bool) -> NSColor {
        isEngaged ? Tokens.Color.label : Tokens.Color.label2
    }
}

/// The seat's paint, as a DRAWING-ONLY `NSButtonCell` subclass — the house
/// idiom `WarmFaderCell`, `WarmNameFieldCell` and `AlignmentPlateCell` all
/// follow (`AudioutSharedUI/AGENTS.md`: only the drawing changes; tracking,
/// keyboard operation, target/action and VoiceOver stay stock).
///
/// `drawBezel` never calls `super`, so AppKit's own circle-on-hover /
/// rounded-square-on-selection bezel is fully replaced.
final class SurfaceToolbarSeatCell: NSButtonCell {

    /// The current screen, or Pin while pinned.
    var isEngaged = false {
        didSet { if isEngaged != oldValue { controlView?.needsDisplay = true } }
    }

    /// Pointer-over. `SurfaceToolbarSeatButton`'s tracking area sets it; the
    /// cell owns no tracking of its own.
    var isHovered = false {
        didSet { if isHovered != oldValue { controlView?.needsDisplay = true } }
    }

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        // Read live, every draw — the app never snapshots this flag.
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        guard let alpha = SurfaceToolbarSeat.fillAlpha(isEngaged: isEngaged,
                                                       isHovered: isHovered,
                                                       isPressed: isHighlighted,
                                                       increaseContrast: increaseContrast)
        else { return }
        // Resolved at draw time, so the appearance and the Increase Contrast
        // variant of the token are both current (Tokens' governance rule:
        // never cache a resolved colour outside a live draw).
        Tokens.Color.engagedChrome.withAlphaComponent(alpha).setFill()
        Self.seatPath(in: frame).fill()
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        Self.seatPath(in: cellFrame).fill()
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        cellFrame
    }

    /// The one shape, for the fill and for the focus ring alike.
    static func seatPath(in frame: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: frame,
                     xRadius: SurfaceToolbarSeat.cornerRadius,
                     yRadius: SurfaceToolbarSeat.cornerRadius)
    }
}

/// One item of the header strip: an `NSButton` wearing `SurfaceToolbarSeatCell`,
/// seated in an `NSToolbarItem` as its custom view.
///
/// It carries the selection state to VoiceOver itself. The bordered items
/// this replaces got that from `NSToolbar.selectedItemIdentifier`, which
/// AppKit speaks — but AppKit only draws a selection for the item styles it
/// owns, so taking the drawing means taking the spoken state too. A tab is a
/// radio button (one of three, exactly one on) and reports selected both as
/// its accessibility value and through `isAccessibilitySelected`.
final class SurfaceToolbarSeatButton: NSButton {

    private let seatCell = SurfaceToolbarSeatCell()
    private var hoverTrackingArea: NSTrackingArea?
    private var isTab = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        cell = seatCell // the cell goes in FIRST, then every config call lands on it
        setButtonType(.momentaryPushIn)
        bezelStyle = .push // never the deprecated `.rounded`
        // Bordered so the cell's `drawBezel` is called at all, and because a
        // BORDERLESS button silently discards `drawFocusRingMask` (openradar
        // 29465363) — the same reason `AlignmentPlateButton` keeps the bit.
        isBordered = true
        title = ""
        imagePosition = .imageOnly
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SurfaceToolbarSeat.size.width),
            heightAnchor.constraint(equalToConstant: SurfaceToolbarSeat.size.height),
        ])
        refreshEngagedAppearance()
    }

    /// The `.push` bezel style carries AppKit's own alignment-rect insets,
    /// which Auto Layout would apply OUTSIDE the constrained seat. The cell
    /// paints the whole frame, so the frame IS the alignment rect.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    // MARK: Configuration

    /// `isTab` marks the three screen tabs, which are one radio group; Pin is
    /// an ordinary button whose own label ("Pin" / "Unpin") speaks its state.
    func configure(symbol: NSImage?, label: String, toolTip: String?, isTab: Bool) {
        self.isTab = isTab
        image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: SurfaceToolbarSeat.glyphPointSize,
                                        weight: .regular)) ?? symbol
        self.toolTip = toolTip
        setAccessibilityLabel(label)
        if isTab { setAccessibilityRole(.radioButton) }
        refreshEngagedAppearance()
    }

    /// The current screen, or Pin while pinned: the drawn seat, the glyph's
    /// ink and the spoken selection all move together.
    var isEngaged: Bool {
        get { seatCell.isEngaged }
        set {
            seatCell.isEngaged = newValue
            refreshEngagedAppearance()
        }
    }

    private func refreshEngagedAppearance() {
        contentTintColor = SurfaceToolbarSeat.glyphTint(isEngaged: seatCell.isEngaged)
        setAccessibilityValue(NSNumber(value: seatCell.isEngaged))
        setAccessibilitySelected(seatCell.isEngaged)
        needsDisplay = true
    }

    // MARK: Hover tracking (feeds the cell)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // MARK: Test-support hooks

    var isHovered: Bool {
        get { seatCell.isHovered }
        set {
            seatCell.isHovered = newValue
            needsDisplay = true
        }
    }

    /// Press the seat without an event loop, so the pressed weight can be
    /// drawn and sampled.
    var test_isPressed: Bool {
        get { seatCell.isHighlighted }
        set { seatCell.isHighlighted = newValue; needsDisplay = true }
    }
}
