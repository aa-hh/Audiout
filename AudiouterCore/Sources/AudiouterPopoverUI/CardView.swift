// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI

/// A rounded-rect **Control Center module** container (SPEC §9 restyle; T-U10
/// semantic-first pass; raised 3D chrome added 2026-07-14 per ahh's request).
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
///      the rounded corners. (2026-07-16 — ahh confirmed his earlier "flat"
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

    // MARK: Collapsible body (T-4, PLAN-POPOVER-ROUTING.md decision 5 + §E risk 1)
    //
    // A card is split into a **header** area (always visible — the title row +
    // its chevron/column-headers) and a **collapsible body** (every content row
    // added after the header). The body rows do NOT live directly in
    // `contentStack`; they live in `bodyStack`, itself hosted inside a
    // **clipping container** (`bodyClip`) whose height constraint animates to 0
    // on collapse and back to the body's fitting height on expand. Clipping (not
    // just hiding) is what makes the collapse animate smoothly: the rows slide up
    // behind the clip's top edge while the constraint shrinks, and only the
    // container's own height changes drive the card's — and the popover's — size
    // (PLAN §E risk 1: "clip + fade instead of hide"). `bodyClip` is an arranged
    // subview of `contentStack`, so an empty (header-only) card still lays out.

    /// The clip container that masks the collapsing body. Its height is the single
    /// animated dimension; `bodyStack` is pinned inside it (top-anchored, so the
    /// rows slide up under the clip edge as the height shrinks).
    private let bodyClip = NSView()
    /// The vertical stack the collapsible content rows live in.
    private let bodyStack = NSStackView()
    /// The animated height constraint on `bodyClip`. Active with `constant == 0`
    /// while collapsed; deactivated while expanded (so the body's own fitting
    /// height flows through). Toggled via the constraint's `animator()` proxy so
    /// rapid collapse/expand retarget cleanly (PLAN §E risk 1).
    private var bodyHeightConstraint: NSLayoutConstraint!
    /// The body stack's bottom pin to the clip, at `.defaultHigh` so a required
    /// height-0 constraint can override it during a collapse (see the init note).
    private lazy var bodyClipBottomPin: NSLayoutConstraint = {
        let c = bodyStack.bottomAnchor.constraint(equalTo: bodyClip.bottomAnchor)
        c.priority = .defaultHigh
        return c
    }()
    /// Whether the body is currently collapsed (height pinned to 0 + hidden).
    private(set) var isBodyCollapsed = false
    /// Bumped on every animated toggle so a stale completion handler (from an
    /// animation a rapid retarget superseded) can no-op instead of applying a
    /// terminal `isHidden`/constraint change against a newer in-flight animation
    /// (PLAN §E risk 1: "rapid toggles retarget cleanly, never queue or fight").
    private var collapseGeneration = 0

    /// CC modules use generous, continuous rounding (~13pt).
    static let cornerRadius: CGFloat = 13

    /// Collapse/expand animation duration — matches the popover's own resize pace
    /// (PLAN §E risk 1: "match your 0.2s so they track").
    static let collapseAnimationDuration: TimeInterval = 0.2

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

        // The collapsible body: a clip container hosting the body stack. The clip
        // container is an arranged subview of `contentStack` (added lazily on the
        // first body row via `bodyClipContainer`), so header rows added before it
        // stay above it and always visible.
        bodyClip.translatesAutoresizingMaskIntoConstraints = false
        bodyClip.wantsLayer = true
        bodyClip.layer?.masksToBounds = true   // clip the sliding rows

        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.distribution = .fill
        bodyStack.spacing = 0
        bodyClip.addSubview(bodyStack)

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

            // The body stack is TOP-pinned strongly inside the clip; the BOTTOM pin
            // is `.defaultHigh` (not required) so an active height-0 constraint can
            // override it during collapse. When expanded (that constraint inactive)
            // the bottom pin drives the clip's height to the content. Because the
            // top pin is the strong one, a collapse clips the rows from the BOTTOM
            // (they hold their position at the top and vanish under the shrinking
            // clip edge — the CC-style disclosure), not by compressing.
            bodyStack.topAnchor.constraint(equalTo: bodyClip.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: bodyClip.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: bodyClip.trailingAnchor),
            bodyClipBottomPin,

            rim.topAnchor.constraint(equalTo: topAnchor),
            rim.leadingAnchor.constraint(equalTo: leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: trailingAnchor),
            rim.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Add a full-width **header** row into the card (the title row built by
    /// `beginCard`). Header rows sit above the collapsible body and stay visible
    /// when the card is collapsed.
    func addRow(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor).isActive = true
    }

    /// Add a full-width **body** row into the card — a row that collapses/expands
    /// with the chevron (device rows, subsection headers, app rows). The first
    /// body row lazily mounts the clip container into `contentStack` (below the
    /// header rows added so far). Full width, exactly like `addRow`.
    func addBodyRow(_ view: NSView) {
        mountBodyClipIfNeeded()
        bodyStack.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: bodyStack.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: bodyStack.trailingAnchor).isActive = true
    }

    /// Mount `bodyClip` as an arranged subview of `contentStack` on first use, and
    /// create its animated height constraint. Deferred so a card with header rows
    /// only (no body) never introduces the clip container.
    private func mountBodyClipIfNeeded() {
        guard bodyClip.superview == nil else { return }
        contentStack.addArrangedSubview(bodyClip)
        NSLayoutConstraint.activate([
            bodyClip.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            bodyClip.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])
        // Height constraint used ONLY while collapsed (constant 0). While expanded
        // it is inactive so the body's own fitting height governs. Created eagerly
        // so `setBodyCollapsed` can flip its `isActive`/`constant` cleanly.
        bodyHeightConstraint = bodyClip.heightAnchor.constraint(equalToConstant: 0)
        bodyHeightConstraint.isActive = isBodyCollapsed
    }

    // MARK: Collapse / expand (T-4, PLAN §E risk 1)

    /// The body's natural (expanded) height — the fitting height of the body stack.
    /// Used both to report state to tests and as the animation's expand target.
    var bodyFittingHeight: CGFloat {
        guard bodyClip.superview != nil else { return 0 }
        bodyStack.layoutSubtreeIfNeeded()
        return bodyStack.fittingSize.height
    }

    /// The clip container's current laid-out height (0 when collapsed).
    var bodyClipHeight: CGFloat {
        bodyClip.superview != nil ? bodyClip.frame.height : 0
    }

    /// Set the collapsed state.
    ///
    /// Choreography (PLAN §E risk 1):
    /// - **collapse:** fade the body out and animate the clip height to 0 in the
    ///   same `NSAnimationContext` group; set `isHidden` on the body ONLY in the
    ///   completion handler (so it stays rendered — and fading — throughout).
    /// - **expand:** clear `isHidden` and restore `alphaValue` to 1 BEFORE
    ///   animating, then animate the clip height from 0 up to the body's fitting
    ///   height (deactivating the pinned-0 constraint at the end).
    ///
    /// `animated == false` (initial build + Reduce Motion) applies the end state
    /// synchronously with no animation. All constraint changes go through the
    /// `animator()` proxy so rapid toggles retarget the in-flight animation rather
    /// than queueing or fighting (PLAN §E risk 1: "retargetable rapid toggles").
    ///
    /// `onComplete` fires when the animation settles (or immediately on the
    /// non-animated path) — the panel uses it to publish the final popover size.
    func setBodyCollapsed(_ collapsed: Bool, animated: Bool, onComplete: (() -> Void)? = nil) {
        // A header-only card has no body to move.
        guard bodyClip.superview != nil else {
            isBodyCollapsed = collapsed
            onComplete?()
            return
        }
        // An animated toggle to the state we're already in is a no-op; the
        // non-animated path always (re)applies the end state so the initial build
        // can force it regardless of the current flag.
        if animated && collapsed == isBodyCollapsed {
            onComplete?()
            return
        }
        isBodyCollapsed = collapsed

        // Settle the body's natural height BEFORE animating so the expand target is
        // exact (PLAN §E risk 1: "layout settled synchronously before animating").
        let target = bodyFittingHeight

        if !animated {
            // End state applied directly (initial show + Reduce Motion).
            if collapsed {
                bodyHeightConstraint.constant = 0
                bodyHeightConstraint.isActive = true
                bodyStack.alphaValue = 0
                bodyClip.isHidden = true
            } else {
                bodyClip.isHidden = false
                bodyStack.alphaValue = 1
                bodyHeightConstraint.isActive = false
            }
            onComplete?()
            return
        }

        collapseGeneration += 1
        let generation = collapseGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.collapseAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            if collapsed {
                // Pin to 0 and animate DOWN. Body fades during the shrink; it is
                // hidden only in the completion handler so it renders throughout.
                bodyHeightConstraint.isActive = true
                bodyHeightConstraint.animator().constant = 0
                bodyStack.animator().alphaValue = 0
            } else {
                // Clear hidden + restore alpha BEFORE animating up to the fitting
                // height, then let the pinned constraint go inactive at the end.
                bodyClip.isHidden = false
                // Start from 0 explicitly so the up-animation has a floor even if a
                // prior expand left the constraint inactive.
                bodyHeightConstraint.isActive = true
                bodyHeightConstraint.constant = 0
                layoutSubtreeIfNeeded()
                bodyHeightConstraint.animator().constant = target
                bodyStack.animator().alphaValue = 1
            }
            layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self else { onComplete?(); return }
            // A superseded animation's completion must NOT touch the terminal state
            // — the newest animation owns it (and will fire its own completion).
            guard generation == self.collapseGeneration else { onComplete?(); return }
            if self.isBodyCollapsed {
                self.bodyClip.isHidden = true
            } else {
                // Expanded: drop the pinned constraint so the body flexes with its
                // content again (e.g. a later row change).
                self.bodyHeightConstraint.isActive = false
            }
            onComplete?()
        })
    }

    // MARK: Raised-module chrome (shadow)

    /// CC's module shadow is tight and quiet — small blur, low opacity, a slight
    /// downward offset (light from above). Dark mode needs a deeper shadow to
    /// separate the tile from an already-dark popover.
    private func updateShadow() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowColor = Tokens.Color.shadow.cgColor
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
            Tokens.Color.shadow.setFill()
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
