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

    /// One COLLAPSED tab's hit area, and the size of the highlight drawn
    /// behind it. Two of the three tabs are always this size; the current one
    /// grows to the right of it to show its name (`tabWidth`).
    static let size = NSSize(width: 30, height: 26)

    /// The gap after a revealed name, between the last letter and the end of
    /// the highlight it sits in. Mirrors the ~7.5 pt the glyph already has on
    /// its own left, so an expanded tab is padded evenly.
    static let nameTrailingPadding: CGFloat = 10

    /// The HARD ceiling on a revealed name, whatever language it is in. A name
    /// longer than this truncates with an ellipsis rather than widening the
    /// strip, which is the whole reason names could come back at all: three
    /// translated labels on three tabs is what swept the tabs into the
    /// overflow chevron on 2026-09-03, and primary navigation cannot live
    /// behind a chevron.
    ///
    /// 120 pt is about two and a half times the widest English name: measured
    /// at `Tokens.Font.captionMedium`, "Mixer" takes 34 pt, "Groups" 43 and
    /// "Settings" 49. A translation would have to be well over twice as wide
    /// as "Settings" before it even reached the ceiling — and reaching it
    /// costs nothing, because the arithmetic does not depend on any of those
    /// numbers: only ONE tab is ever expanded, so the widest the strip can be
    /// is `widestCapsuleWidth` plus Pin, 226 + 30 = 256 pt against a fixed
    /// 653 pt surface.
    /// `SurfaceToolbarTests.theStripCannotOutgrowTheSurfaceInAnyLanguage`
    /// asserts that with a name no language could produce.
    static let maxNameWidth: CGFloat = 120

    /// The name's face: 11 pt medium, the caption voice the popover's own
    /// section sub-headers use. Small enough to sit beside a 15 pt glyph
    /// without competing with it, heavy enough to hold at that size.
    static var nameFont: NSFont { Tokens.Font.captionMedium }

    /// One tab's width with `nameWidth` points of name revealed — the glyph
    /// keeps its own collapsed slot and the name is added to the right of it,
    /// so revealing a name never moves the glyph.
    static func tabWidth(nameWidth: CGFloat) -> CGFloat {
        nameWidth <= 0 ? size.width : size.width + nameWidth + nameTrailingPadding
    }

    /// The gap between the capsule's edge and the tabs inside it, on all four
    /// sides. It is what keeps a selected end tab's highlight from touching
    /// the pill's rounded end.
    static let capsulePadding: CGFloat = 3

    /// The capsule holding all three tabs with every one of them COLLAPSED —
    /// the floor its width can never go below, and its height in every state.
    static var capsuleSize: NSSize {
        NSSize(width: size.width * 3 + capsulePadding * 2,
               height: size.height + capsulePadding * 2)
    }

    /// The capsule's width with one tab showing `nameWidth` points of name.
    /// At most ONE tab is ever expanded, so one name is all this ever adds.
    static func capsuleWidth(nameWidth: CGFloat) -> CGFloat {
        capsuleSize.width + (nameWidth <= 0 ? 0 : nameWidth + nameTrailingPadding)
    }

    /// The widest the capsule can get in ANY language: two collapsed tabs plus
    /// one expanded to the name ceiling. The guard that keeps the strip out of
    /// the overflow chevron is this number, not the length of the English
    /// words — a name past the ceiling truncates instead of pushing.
    static var widestCapsuleWidth: CGFloat { capsuleWidth(nameWidth: maxNameWidth) }

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

    /// The glyph stays in the tab's COLLAPSED slot however wide the seat grows,
    /// so revealing a name opens space to the right of the icon instead of
    /// sliding the icon along with it. Stock `.imageOnly` centres the image in
    /// the whole cell, which would drift every glyph as its own name appeared.
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        let slot = NSRect(x: controlView.bounds.minX, y: frame.minY,
                          width: SurfaceToolbarSeat.size.width, height: frame.height)
        super.drawImage(image, withFrame: slot, in: controlView)
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

    /// The name, drawn to the right of the glyph and revealed by the seat
    /// growing past it. It is NOT an accessibility element: the button already
    /// speaks this exact string as its accessibility label, and a second copy
    /// inside the radio button would make VoiceOver say it twice.
    private let nameLabel = NSTextField(labelWithString: "")

    /// The seat's own width — the ONE value the reveal animates. Held so
    /// `SurfaceToolbarSeat.tabWidth` can be written into it.
    private var widthConstraint: NSLayoutConstraint!

    /// The name's own width, pinned to the clamped measurement so the letters
    /// keep their shape while the seat slides open past them.
    private var nameLabelWidth: NSLayoutConstraint?

    /// How much room this tab's name needs, already clamped to
    /// `SurfaceToolbarSeat.maxNameWidth`. Zero until `configure` sets a name.
    private(set) var nameWidth: CGFloat = 0

    /// Whether the name is showing. The three tabs are one radio group and the
    /// capsule expands only for the current screen, so at most one is `true`.
    private(set) var isNameRevealed = false

    /// What re-lays-itself-out on every tick of a reveal — the capsule, which
    /// has to re-measure and let the toolbar re-place it as this seat grows.
    /// Weak, the same contract `FoldAnimator` holds its followers under.
    weak var revealFollower: (any FoldFollowing)?

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
        // The name is parked OUTSIDE a collapsed seat's bounds and clipped
        // away, so growing the seat wipes it into view instead of squeezing
        // the letters open. Without this it would be drawn in full beside a
        // 30 pt tab, spilling across its neighbour.
        clipsToBounds = true

        nameLabel.font = SurfaceToolbarSeat.nameFont
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setAccessibilityElement(false)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        widthConstraint = widthAnchor.constraint(equalToConstant: SurfaceToolbarSeat.size.width)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: SurfaceToolbarSeat.size.height),
            // Pinned to the seat's leading edge past the glyph's own slot, and
            // never to its trailing edge: a trailing pin would let Auto Layout
            // compress the name as the seat grows, so the reveal would read as
            // letters unsqueezing rather than a name sliding out.
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: SurfaceToolbarSeat.size.width),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshEngagedAppearance()
    }

    /// The whole seat is one control, including the part of it the name
    /// occupies: without this a click that lands on the letters would hit the
    /// text field and go nowhere.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
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
        // Only a tab has a name to reveal. Pin's own label already flips
        // between "Pin" and "Unpin" to say what it is, and it stands outside
        // the capsule, so nothing about it expands.
        setName(isTab ? label : "")
        refreshEngagedAppearance()
    }

    /// Measure the name once, clamp it, and hold that width — the reveal then
    /// animates between two numbers instead of re-measuring text on every
    /// frame. A name past the ceiling truncates, which is what makes the
    /// strip's width independent of the language it is read in.
    private func setName(_ name: String) {
        nameLabel.stringValue = name
        nameLabelWidth?.isActive = false
        guard !name.isEmpty else {
            nameWidth = 0
            widthConstraint.constant = SurfaceToolbarSeat.tabWidth(nameWidth: 0)
            return
        }
        nameWidth = min(ceil(nameLabel.fittingSize.width), SurfaceToolbarSeat.maxNameWidth)
        let width = nameLabel.widthAnchor.constraint(equalToConstant: nameWidth)
        width.isActive = true
        nameLabelWidth = width
        widthConstraint.constant = SurfaceToolbarSeat.tabWidth(
            nameWidth: isNameRevealed ? nameWidth : 0)
    }

    /// Show or hide this tab's name by growing or shrinking the seat itself.
    ///
    /// Travel runs on `FoldAnimator` — the app's ONE reveal clock, at the one
    /// `Tokens.Motion.collapseRevealDuration` every other clip in the app
    /// opens at, and the place Reduce Motion is already answered: under it the
    /// driver settles the width synchronously in this caller's own turn, so
    /// the name is simply there, with no frame of travel. Passing
    /// `animated: false` is the same terminal state without going near the
    /// clock, which is what the strip is built with.
    func setNameRevealed(_ revealed: Bool, animated: Bool) {
        guard revealed != isNameRevealed else { return }
        isNameRevealed = revealed
        let target = SurfaceToolbarSeat.tabWidth(nameWidth: revealed ? nameWidth : 0)
        guard animated else {
            widthConstraint.constant = target
            revealFollower?.foldAnimatorDidTick()
            return
        }
        FoldAnimator.shared.animate(widthConstraint, to: target, follower: revealFollower) {}
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
        // The name is ink on the same seat as the glyph, so it steps with it.
        nameLabel.textColor = SurfaceToolbarSeat.glyphTint(isEngaged: seatCell.isEngaged)
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

    /// The name this seat CARRIES, whether or not the seat is currently wide
    /// enough to show it. Empty on Pin.
    var test_name: String { nameLabel.stringValue }

    /// How much of the name the seat's own bounds actually let through —
    /// 0 while collapsed, the full clamped name width once open, and a real
    /// in-between number mid-travel. This is the drawn result, not the intent.
    var test_visibleNameWidth: CGFloat {
        max(0, min(nameWidth,
                   widthConstraint.constant - SurfaceToolbarSeat.size.width))
    }

    /// The seat's live width, which is what the reveal animates.
    var test_width: CGFloat { widthConstraint.constant }
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
/// Its HEIGHT is fixed and its width is derived from the three tabs, so it is
/// exactly as wide as they are and no wider: the highlight moving cannot
/// resize it, and only a tab opening to show its name can. Nothing here is
/// behind `#available`: the package deploys to 14.2.
final class SurfaceToolbarTabCapsule: NSView, FoldFollowing {

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
            // No width constraint: the pill is exactly as wide as the three
            // tabs plus its padding, so the one that is open pushes it out and
            // nothing else can. Height stays pinned — a reveal is horizontal.
            heightAnchor.constraint(equalToConstant: SurfaceToolbarSeat.capsuleSize.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            row.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
        for tab in tabs { tab.revealFollower = self }

        // Three radio buttons in a group is what this is, so say so: VoiceOver
        // then announces the set the tabs belong to before their own names.
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Screens")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// One tick of a name reveal. The pill is repainted at its new width and
    /// the toolbar re-places the item around it, so the whole strip travels on
    /// the tab's single animated width rather than on a clock of its own —
    /// `FoldAnimator`'s standing rule that a reveal has exactly one animated
    /// value and everything else is laid out FROM it.
    func foldAnimatorDidTick() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        superview?.needsLayout = true
        window?.layoutIfNeeded()
    }

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
