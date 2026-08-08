// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI

/// A popover **section container** — header row + collapsible body rows.
///
/// **De-nested (spec §5.1):** a card draws **zero chrome of its own** — no
/// shadow, no material backing, no rounded-tile silhouette. Every section sits
/// directly on `PopoverPanelViewController`'s warm canvas (`WarmCanvasView`,
/// spec §5.1), and the ONLY visual separation between cards is the 1px
/// hairline divider `PopoverPanelViewController` inserts into `stackView`
/// between them (`beginCard`). `CardView` itself is just a header +
/// collapsible-body layout container; see `contentStack`/`bodyClip`/
/// `bodyStack` below.
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
    /// The clip height the most recent ANIMATED collapse/expand started from — the
    /// value the height constraint held (and the layer animates FROM) at the
    /// instant the animator retargeted it. Recorded for the regression test that
    /// pins first-collapse-vs-second-collapse trajectory parity: a correct collapse
    /// always begins at the expanded height (`target`), never a stale `0` (see
    /// `setBodyCollapsed`'s collapse branch). `nil` until the first animated toggle.
    private(set) var lastAnimatedStartHeight: CGFloat?

    /// Collapse/expand animation duration — matches the popover's own resize pace
    /// (PLAN §E risk 1: "match your 0.2s so they track").
    static let collapseAnimationDuration: TimeInterval = 0.2

    init() {
        super.init(frame: .zero)
        // No chrome of any kind (de-nest, see the class doc comment): no
        // layer, no mask, no material, no shadow. `contentStack` mounts
        // directly on `self`, which is fully transparent — the panel's
        // `WarmCanvasView` shows through everywhere a row doesn't paint its
        // own content.
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 0
        contentStack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        addSubview(contentStack)

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

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),

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

    /// Test hook: the body rows in display order. An `insertRow` row appears as
    /// its `RowClipView` wrapper, not the row itself.
    var test_bodyRows: [NSView] { bodyStack.arrangedSubviews }

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

    // MARK: Rail terminus geometry (collapse-reactive rail, 2026-07-22)

    /// The always-visible header row (the first content row `beginCard` adds) —
    /// the rail's origin/terminus anchor when this card's body collapses. `nil`
    /// before any row is added.
    var railHeaderRow: NSView? { contentStack.arrangedSubviews.first }
    /// The body clip once its first body row has mounted it (`nil` for a
    /// header-only card) — its LIVE frame drives the rail's in-sync squeeze.
    var mountedBodyClip: NSView? { bodyClip.superview != nil ? bodyClip : nil }

    /// Set the collapsed state.
    ///
    /// Choreography (PLAN §E risk 1):
    /// - **collapse:** SEED the clip-height constraint with the current expanded
    ///   height BEFORE animating it to 0 (symmetric with expand's explicit floor),
    ///   fade the body out in the same `NSAnimationContext` group, and set
    ///   `isHidden` on the body ONLY in the completion handler (so it stays
    ///   rendered — and fading — throughout). The seed is what makes the FIRST
    ///   collapse of a never-toggled card animate rather than snap (see the branch).
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
                // Seed the constraint with the CURRENT expanded height BEFORE
                // animating it to 0 — mirroring the expand branch's explicit floor
                // below. Without this seed, the FIRST collapse of a freshly-built
                // card animates from the constraint's AS-CREATED constant (0):
                // `bodyHeightConstraint`'s constant is only ever set to `target` as
                // a side effect of a prior EXPAND animation, so on a never-expanded
                // card activating it here pins the clip to 0 IMMEDIATELY while
                // `animator().constant = 0` animates 0→0 (a no-op) — the body height
                // SNAPS shut (only its alpha fades), and the rail overlay, which
                // tracks the live clip floor every layout pass, snaps with it. That
                // was the visible "content jumps on the first collapse only" glitch.
                // Seeding `target` gives the first collapse the identical target→0
                // travel every later collapse already gets (a prior expand left the
                // constant at `target`), so all collapses squeeze identically.
                bodyHeightConstraint.constant = target
                bodyHeightConstraint.isActive = true
                layoutSubtreeIfNeeded()
                lastAnimatedStartHeight = target
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
                lastAnimatedStartHeight = 0
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
}

/// A card is a rail SECTION (collapse-reactive rail, 2026-07-22): the overlay
/// reads its collapse state, its always-visible header row (the collapsed
/// origin/terminus anchor), and its body clip's LIVE frame (the in-sync squeeze
/// source). `railSectionCollapsed` reports the TARGET state (set at the start of
/// an animated toggle) — but the overlay leans on the live clip frame, not this
/// flag, to place the rail mid-animation, so the flag flipping early is harmless.
extension CardView: RailSectionProviding {
    var railSectionCollapsed: Bool { isBodyCollapsed }
    var railSectionHeaderView: NSView? { railHeaderRow }
    var railSectionHeaderBounds: NSRect { railHeaderRow?.bounds ?? .zero }
    var railSectionClipView: NSView? { mountedBodyClip }
    var railSectionClipBounds: NSRect { mountedBodyClip?.bounds ?? .zero }
}
