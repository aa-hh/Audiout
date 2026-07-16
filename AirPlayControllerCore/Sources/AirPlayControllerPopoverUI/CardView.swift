// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit

/// A rounded-rect **Control Center module** container (SPEC §9 restyle; T-U10
/// semantic-first pass; raised 3D chrome added 2026-07-14 per Alec's request).
///
/// The card reads as a *raised tile*, exactly like a Control Center module. CC
/// carries that depth with edge cues, not surface tweaks, so the card is now a
/// plain layer-backed container composing three pieces:
///
///   1. **Shadow** — a soft drop shadow on the card's own layer (path-based,
///      slight downward offset — overhead light). The card view itself never
///      clips, so the shadow can escape its bounds.
///   2. **`backing`** — the semantic-material `NSVisualEffectView` (`.menu`,
///      `.withinWindow`, active), masked to the continuous ~13pt corner. This
///      is byte-for-byte the pre-chrome card: the *surface* still comes only
///      from the system material (the "semantic-first" decision stands — no
///      hand-mixed tint that would freeze one OS version's look). Rows still
///      live inside it so they keep the vibrant blending context and clip to
///      the rounded corners. (2026-07-16 — Alec confirmed his earlier "flat"
///      report was his own Reduce Transparency accessibility setting, not a
///      bug; he wants MORE translucency on the popover's own BACKGROUND, not
///      these foreground card tiles, so this stays `.withinWindow` — see
///      `PopoverPanelViewController`'s `container` for that change instead.)
///   3. **`rim`** — a hit-test-transparent overlay stroking the raised-edge
///      lighting: a 1pt inner highlight, brightest along the top edge and
///      fading down (light-from-above rim light), plus a 0.5pt hairline at the
///      outermost edge that seats the tile against the popover background.
///
/// All chrome values are appearance-adaptive (resolved from
/// `effectiveAppearance`, re-applied on appearance change); no forced
/// `NSAppearance`.
final class CardView: NSView {

    /// The vertical stack the rows live in. `contentView` is an alias used by the
    /// footer, which lays out its own stack directly.
    let contentStack = NSStackView()
    var contentView: NSView { self }

    /// CC modules use generous, continuous rounding (~13pt).
    static let cornerRadius: CGFloat = 13

    /// The semantic-material surface (see the class comment) — the pre-chrome
    /// card, unchanged.
    private let backing = NSVisualEffectView()
    /// The raised-edge lighting overlay, kept above `backing` (and outside its
    /// vibrant blending context, so the stroke colors render literally).
    private let rim = CardRimView()

    init() {
        super.init(frame: .zero)
        // The card layer carries only the drop shadow; it must not clip.
        wantsLayer = true
        layer?.masksToBounds = false
        updateShadow()

        // Semantic material only — the supported way to track OS styling. `.menu`
        // reads as a raised CC module tile and seats the white slider fills.
        backing.translatesAutoresizingMaskIntoConstraints = false
        backing.material = .menu
        backing.blendingMode = .withinWindow
        backing.state = .active
        // Clip rows to the rounded corners with a continuous (squircle) curve —
        // the Control Center card shape.
        backing.wantsLayer = true
        backing.layer?.cornerRadius = Self.cornerRadius
        backing.layer?.cornerCurve = .continuous
        backing.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        addSubview(backing)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 0
        contentStack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        backing.addSubview(contentStack)

        rim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rim)

        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: backing.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: backing.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: backing.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: backing.bottomAnchor),

            rim.topAnchor.constraint(equalTo: topAnchor),
            rim.leadingAnchor.constraint(equalTo: leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: trailingAnchor),
            rim.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Add a full-width row into the card.
    func addRow(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor).isActive = true
    }

    /// Insert a full-width row at `index` in the card's stack — the inline
    /// diagnosis panel mounts directly under its failed device row
    /// (connection-status brief §7.2), so appending isn't enough.
    func insertRow(_ view: NSView, at index: Int) {
        contentStack.insertArrangedSubview(view, at: index)
        view.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor).isActive = true
    }

    // MARK: Raised-module chrome (shadow)

    /// CC's module shadow is tight and quiet — small blur, low opacity, a slight
    /// downward offset (light from above). Dark mode needs a deeper shadow to
    /// separate the tile from an already-dark popover.
    private func updateShadow() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isDark ? 0.45 : 0.22
        layer?.shadowRadius = isDark ? 6 : 5
        // Non-flipped layer geometry: negative height drops the shadow BELOW.
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadow()
        rim.needsDisplay = true
    }

    override func layout() {
        super.layout()
        // Path-based shadow: cheap, and exact for the rounded-rect silhouette.
        layer?.shadowPath = CGPath(roundedRect: bounds,
                                   cornerWidth: Self.cornerRadius,
                                   cornerHeight: Self.cornerRadius,
                                   transform: nil)
    }

    /// A resizable rounded-rect mask so the `NSVisualEffectView` itself clips to
    /// the card's rounded corners (the material, not just the layer, is masked —
    /// the documented way to round a visual-effect view).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The raised-edge lighting of a CC module: a top-lit 1pt inner rim highlight
/// (vertical white gradient, brightest at the top edge) plus a 0.5pt hairline
/// at the outermost edge. Purely decorative — transparent to hit-testing.
private final class CardRimView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let radius = CardView.cornerRadius

        // 1. Rim highlight: a 1pt stroke straddling the very edge (CC's bright
        //    line sits AT the module boundary, not inset), clipped to its own
        //    outline and filled with a vertical gradient so it is brightest
        //    along the top edge and fades down the sides — the light-from-above
        //    cue that makes the tile read as raised.
        let rimRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let rimPath = CGPath(roundedRect: rimRect,
                             cornerWidth: radius - 0.5, cornerHeight: radius - 0.5,
                             transform: nil)
        let strokedRim = rimPath.copy(strokingWithWidth: 1.0, lineCap: .butt,
                                      lineJoin: .round, miterLimit: 10)
        let top = NSColor(white: 1.0, alpha: isDark ? 0.25 : 0.90).cgColor
        let bottom = NSColor(white: 1.0, alpha: isDark ? 0.06 : 0.20).cgColor
        if let gradient = CGGradient(colorsSpace: nil,
                                     colors: [top, bottom] as CFArray,
                                     locations: [0, 1]) {
            ctx.saveGState()
            ctx.addPath(strokedRim)
            ctx.clip()
            // Non-flipped view: the visual top edge is maxY.
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: bounds.midX, y: bounds.maxY),
                                   end: CGPoint(x: bounds.midX, y: bounds.minY),
                                   options: [])
            ctx.restoreGState()
        }

        // 2. Outermost hairline: seats the tile against the popover background
        //    (near-invisible in light mode, a dark seam in dark mode).
        let outlineRect = bounds.insetBy(dx: 0.25, dy: 0.25)
        ctx.addPath(CGPath(roundedRect: outlineRect,
                           cornerWidth: radius - 0.25, cornerHeight: radius - 0.25,
                           transform: nil))
        ctx.setLineWidth(0.5)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: isDark ? 0.30 : 0.06))
        ctx.strokePath()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
