// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The header strip's geometry and wash strengths: the ONE capsule that holds
/// the three screen tabs, the highlight drawn inside it for the current tab,
/// and the same highlight worn by Pin, which stands outside the capsule.
///
/// **The shape the owner asked for** (Alec, 2026-09-04, second pass). One
/// continuous pill-shaped surface behind all three glyphs — a single drawn
/// thing, not three. The current tab is marked by a soft rounded highlight
/// INSIDE that pill; hover is the same highlight, weaker; an idle tab draws
/// nothing of its own. What that replaces: three separate circular seats, one
/// per tab, each its own island, which failed review the same day.
///
/// **The defect underneath both passes.** The items were bordered
/// `NSToolbarItem`s, and AppKit draws a bordered item's HOVER state as a
/// circle and its SELECTED state as a rounded square: two shapes for two
/// states of one control. Owning the drawing is the only way to make one
/// shape carry every state, because neither shape is settable.
///
/// Every number below is a plain value drawn with `NSBezierPath` on every
/// macOS the package supports. **Nothing here is behind `#available`**, and
/// nothing may be: the package deploys to 14.2, and an earlier version put
/// its every cue inside `if #available(macOS 26.0, *)`, so macOS 14–25 showed
/// no current screen at all.
enum SurfaceToolbarSeat {

    /// The one rounded rectangle every HIGHLIGHT is, in every state — the
    /// current tab's, a hovered tab's, a pressed tab's, and Pin's while
    /// pinned. 10 pt on a 26 pt-tall highlight leaves 6 pt of straight edge
    /// top and bottom, so it reads as a soft rounded highlight sitting inside
    /// the pill rather than as a second pill or a separate seat.
    static let cornerRadius: CGFloat = Tokens.Layout.Radius.control

    /// One tab's fixed hit area, and the size of the highlight drawn behind
    /// it. Fixed, and icon-only, so the strip's width cannot change with the
    /// selection, the appearance or the language — which is what would sweep
    /// the tabs behind the overflow chevron, and primary navigation cannot
    /// live behind a chevron.
    static let size = NSSize(width: 30, height: 26)

    /// The gap between the capsule's edge and the tabs inside it, on all four
    /// sides. It is what keeps a selected end tab's highlight from touching
    /// the pill's rounded end.
    static let capsulePadding: CGFloat = 3

    /// The capsule holding all three tabs. Derived from the three fixed tabs,
    /// so it is fixed too: the highlight moving cannot resize it, and nothing
    /// about the capsule reflows when the selection moves.
    static var capsuleSize: NSSize {
        NSSize(width: size.width * 3 + capsulePadding * 2,
               height: size.height + capsulePadding * 2)
    }

    /// Half the capsule's height, so the capsule reads as a pill.
    static var capsuleCornerRadius: CGFloat { capsuleSize.height / 2 }

    /// The capsule's own wash, one rung BELOW the hover weight
    /// (`rowHoverWashAlpha`, 0.10) so a hovered tab still separates from the
    /// surface it sits on. Same `engagedChrome` tone as every highlight — one
    /// neutral family across the strip, never gold.
    static let capsuleRestFillAlpha: CGFloat = 0.06

    /// The capsule's wash for the accessibility settings in force. Increase
    /// Contrast lifts it by the same factor the highlights use, so the whole
    /// ladder keeps its spacing. Reduce Transparency does NOT lift it — the
    /// capsule answers that setting with a heavier edge instead (see
    /// `capsuleEdgeColor`), because raising the fill toward 0.10 would close
    /// the gap to the hover rung.
    static func capsuleFillAlpha(increaseContrast: Bool) -> CGFloat {
        increaseContrast ? min(capsuleRestFillAlpha * increaseContrastGain, 1) : capsuleRestFillAlpha
    }

    /// The capsule's hairline edge. With Reduce Transparency on, the system
    /// material under the strip goes flat, so the pill loses the depth that
    /// made it read as a surface; the heavier `rim` edge is what carries it
    /// instead. Read LIVE at draw time, like every other accessibility flag
    /// here.
    static func capsuleEdgeColor(reduceTransparency: Bool) -> NSColor {
        reduceTransparency ? Tokens.Color.rim : Tokens.Color.containerEdge
    }

    /// The glyph size inside a tab.
    static let glyphPointSize: CGFloat = 15

    /// How much stronger every seat draws while Increase Contrast is on. One
    /// factor over the whole ladder, so the three strengths keep their
    /// spacing instead of collapsing into each other. Read LIVE at draw time
    /// (see `SurfaceToolbarSeatCell.drawBezel`), never snapshotted.
    static let increaseContrastGain: CGFloat = 1.5

    /// The strength of the neutral wash a highlight fills with, or `nil` when
    /// no highlight is drawn at all.
    ///
    /// Three rungs of the ladder `Tokens.Color.engagedChrome` already
    /// documents, in the order that token names them, so the header's
    /// "this control is engaged" weights are the mixer's:
    ///
    /// - **rest** — no highlight. An idle tab is its glyph on the bare
    ///   capsule, and an unpinned Pin is its glyph on the bare strip.
    /// - **hover** — `PopoverColumnGrid.rowHoverWashAlpha` (0.10), the wash
    ///   every row in the app already uses under the pointer.
    /// - **engaged** — `rowSelectionWashAlpha` (0.18): the current screen,
    ///   and Pin while pinned.
    /// - **pressed** — `mutePillFillAlpha` (0.22), one rung above engaged, so
    ///   a press reads under the finger wherever it lands.
    ///
    /// NEUTRAL, never gold: gold means audio in the mix, and a header
    /// highlight is navigation. `engagedChrome` is dynamic, so the wash is
    /// white-on-dark and black-on-light. In dark mode the highlight therefore
    /// lands LIGHTER than the capsule it is painted over — an earlier attempt
    /// got that backwards and rendered the user's own location as the darkest
    /// thing on the strip. It cannot recur here: the highlight is drawn ON the
    /// capsule, never instead of it, so it can only add.
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

/// The ONE capsule the three screen tabs sit in: a single pill-shaped surface
/// drawn once, behind all three glyphs, with the tabs as its subviews.
///
/// Three separate circular seats — one per tab, each its own island — is what
/// failed review on 2026-09-04. The owner asked for the grouping macOS 26 uses
/// in its own toolbars: a pill holding several icon buttons side by side, each
/// still independently clickable, with the current one marked by a soft
/// rounded highlight INSIDE the shared pill. Pin stays outside it.
///
/// The capsule draws only itself. The tabs are real buttons layered over it,
/// so a highlight can only ADD to the capsule's wash — which is what makes the
/// current screen lighter than its surroundings in dark mode without any
/// per-appearance branch.
///
/// Its size is derived from three fixed tabs plus fixed padding, so the
/// highlight moving cannot resize it and the selection moving cannot reflow
/// it. Nothing here is behind `#available`: the package deploys to 14.2.
final class SurfaceToolbarTabCapsule: NSView {

    private let tabs: [SurfaceToolbarSeatButton]

    /// `tabs` in tab order. The capsule takes them as subviews; the caller
    /// keeps them to push selection into.
    init(tabs: [SurfaceToolbarSeatButton]) {
        self.tabs = tabs
        super.init(frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.capsuleSize))
        translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: tabs)
        row.orientation = .horizontal
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let padding = SurfaceToolbarSeat.capsulePadding
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SurfaceToolbarSeat.capsuleSize.width),
            heightAnchor.constraint(equalToConstant: SurfaceToolbarSeat.capsuleSize.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            row.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])

        // Three radio buttons in a group is what this is, so say so: VoiceOver
        // then announces the set the tabs belong to before their own names.
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Screens")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func draw(_ dirtyRect: NSRect) {
        // Both accessibility flags read live, every draw — the app never
        // snapshots either.
        let workspace = NSWorkspace.shared
        let path = Self.capsulePath(in: bounds)
        // Resolved at draw time, so the appearance and the Increase Contrast
        // variants of both tokens are current (Tokens' governance rule).
        Tokens.Color.engagedChrome
            .withAlphaComponent(SurfaceToolbarSeat.capsuleFillAlpha(
                increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast))
            .setFill()
        path.fill()
        SurfaceToolbarSeat.capsuleEdgeColor(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency).setStroke()
        path.stroke()
    }

    /// The pill, inset by half the stroke so the edge lands inside `bounds`
    /// rather than straddling it.
    static func capsulePath(in bounds: NSRect) -> NSBezierPath {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: rect.height / 2,
                                yRadius: rect.height / 2)
        path.lineWidth = 1
        return path
    }
}
