// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

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
    // container's own height changes drive the card's — and the surface's — size
    // (PLAN §E risk 1: clip instead of hide). The clip height is the ONLY animated
    // dimension: the body does not fade (live report 2026-08-10 — a fade the row
    // reveal and the subsection collapse don't do is what made the cards read as a
    // different, less pretty system). `bodyClip` is an arranged subview of
    // `contentStack`, so an empty (header-only) card still lays out.

    /// The clip container that masks the collapsing body. Its height is the single
    /// animated dimension; `bodyStack` is pinned inside it (top-anchored, so the
    /// rows slide up under the clip edge as the height shrinks).
    private let bodyClip = NSView()
    /// The vertical stack the collapsible content rows live in.
    private let bodyStack = NSStackView()
    /// The animated height constraint on `bodyClip`. Active with `constant == 0`
    /// while collapsed; deactivated while expanded (so the body's own fitting
    /// height flows through). Driven by `FoldAnimator`, which retargets a rapid
    /// collapse/expand from the live constant (PLAN §E risk 1).
    private var bodyHeightConstraint: NSLayoutConstraint!
    /// The body stack's bottom pin to the clip, at `.defaultHigh` so a required
    /// height-0 constraint can override it during a collapse (see the init note).
    private lazy var bodyClipBottomPin: NSLayoutConstraint = {
        let c = bodyStack.bottomAnchor.constraint(equalTo: bodyClip.bottomAnchor)
        c.priority = .defaultHigh
        return c
    }()
    /// The scrolling host between `bodyClip` and `bodyStack`, for a card built
    /// with `scrollingBody: true` (the Output Devices card — roadmap 039).
    /// `nil` for every other card, which keeps the original direct pin.
    private(set) var bodyScrollView: NSScrollView?
    /// The scrolling body's own height, `min(rows, bodyMaxHeight)`, recomputed by
    /// ``reconcileBodyHeight()``. Priority 999, not required, for the same reason
    /// the bottom pin below is `.defaultHigh`: a collapse's required height-0
    /// constraint has to win over it.
    private var bodyScrollHeight: NSLayoutConstraint?
    /// The tallest a SCROLLING body may draw before its rows start scrolling
    /// inside it instead of growing the card. Ignored by a non-scrolling card,
    /// whose body has no ceiling at all.
    var bodyMaxHeight: CGFloat = .greatestFiniteMagnitude {
        didSet {
            guard bodyMaxHeight != oldValue else { return }
            reconcileBodyHeight()
        }
    }
    /// Whether the body is currently collapsed (height pinned to 0 + hidden).
    private(set) var isBodyCollapsed = false
    /// The panel this card is mounted in, which re-fits itself (and the surface
    /// window with it) on every tick of this card's fold. Set by `beginCard`;
    /// `nil` for a bare card built outside a panel.
    weak var foldFollower: PopoverPanelViewController?
    /// Bumped on every animated toggle so a stale completion handler (from a
    /// fold a non-animated end state superseded) can no-op instead of applying a
    /// terminal `isHidden`/constraint change against a newer in-flight fold
    /// (PLAN §E risk 1: "rapid toggles retarget cleanly, never queue or fight").
    private var collapseGeneration = 0
    /// The clip height the most recent ANIMATED collapse/expand started from — the
    /// value the height constraint held at the instant the driver took it over.
    /// Recorded for the regression test that
    /// pins first-collapse-vs-second-collapse trajectory parity: a collapse from
    /// rest always begins at the expanded height (`target`), never a stale `0`;
    /// a retarget mid-flight begins at the live height (see `setBodyCollapsed`'s
    /// collapse branch). `nil` until the first animated toggle.
    private(set) var lastAnimatedStartHeight: CGFloat?

    /// `scrollingBody` seats the body rows in an `NSScrollView` instead of pinning
    /// them straight into the clip (roadmap 039 — the Output Devices card is the
    /// one card whose list can outgrow the surface). The card's own header row
    /// stays outside it, so the section title and the "Source"/"Offset" column
    /// legends hold still while the speakers scroll under them.
    init(scrollingBody: Bool = false) {
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

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if scrollingBody {
            mountScrollingBody()
        } else {
            bodyClip.addSubview(bodyStack)
            NSLayoutConstraint.activate([
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
    }

    /// Seat `bodyStack` inside a scroll view filling `bodyClip`, and give the
    /// scroll view the explicit height the clip then wears.
    ///
    /// A scroll view has NO natural height — left to itself it would collapse the
    /// clip to nothing, and with it the panel's measured fit. So the height is a
    /// constraint this card recomputes (`reconcileBodyHeight`) from the ROWS'
    /// fitting height, capped at `bodyMaxHeight`: the measure still comes from the
    /// content, exactly as it did when the rows were pinned here directly.
    ///
    /// The scroll view keeps the clip's own constraint SHAPE — top/leading/trailing
    /// required, bottom `.defaultHigh` — so a collapse's required height-0
    /// constraint still wins and the rows still slide up under the shrinking clip
    /// edge rather than compressing.
    ///
    /// Overlay scrollers, forced (see `preferredScrollerStyleDidChange`): a legacy
    /// scroller takes real width out of the clip view, and every column in the
    /// popover is measured inward from the row's trailing edge
    /// (`PopoverColumnGrid`), so a scroller that ate width would shift the whole
    /// grid the moment the list outgrew its ceiling.
    private func mountScrollingBody() {
        // A FLIPPED document, holding the stack unchanged. `NSStackView` is not
        // flipped, and a non-flipped document view puts the scroller's resting
        // position (`bounds.origin.y == 0`) at the BOTTOM of the content — the
        // list would open showing its last rows. Flipping a wrapper rather than
        // the stack itself leaves every row's own coordinate space exactly as it
        // is everywhere else in the panel.
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(bodyStack)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        bodyClip.addSubview(scroll)
        bodyScrollView = scroll

        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        height.priority = NSLayoutConstraint.Priority(999)
        bodyScrollHeight = height
        let bottom = scroll.bottomAnchor.constraint(equalTo: bodyClip.bottomAnchor)
        bottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: bodyClip.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: bodyClip.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bodyClip.trailingAnchor),
            bottom,
            height,
            // The document is exactly as wide as the scroll view — with overlay
            // scrollers that is the clip view's width too, so the columns land
            // where they always did — and exactly as tall as the rows.
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            bodyStack.topAnchor.constraint(equalTo: document.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferredScrollerStyleDidChange),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    /// Plugging in a mouse flips the system's preferred scroller style to
    /// `.legacy`, and AppKit re-applies that preference to every scroll view.
    /// Force `.overlay` straight back: a legacy scroller would narrow the clip
    /// view and drag every trailing-anchored column left with it.
    @objc private func preferredScrollerStyleDidChange() {
        bodyScrollView?.scrollerStyle = .overlay
    }

    /// Bring the scrolling body's height back in line with its rows — the rows'
    /// fitting height, capped at `bodyMaxHeight`. A no-op for a non-scrolling
    /// card (its clip already flexes with the rows pinned inside it) and for a
    /// height that has not moved.
    func reconcileBodyHeight() {
        guard let bodyScrollHeight else { return }
        bodyStack.layoutSubtreeIfNeeded()
        let target = min(bodyStack.fittingSize.height, bodyMaxHeight)
        guard abs(bodyScrollHeight.constant - target) > 0.5 else { return }
        bodyScrollHeight.constant = target
    }

    /// Scroll `view` into the visible part of the list, when the list scrolls and
    /// `view` is one of its rows (or lives inside one). The keyboard's answer to a
    /// list taller than its ceiling: tabbing to a row off the bottom brings it up.
    @discardableResult
    func revealBodyRow(_ view: NSView) -> Bool {
        guard bodyScrollView != nil, view.isDescendant(of: bodyStack) else { return false }
        layoutSubtreeIfNeeded()
        return view.scrollToVisible(view.bounds)
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
        // Capped for a scrolling body: the expand target is how tall the clip
        // actually settles at, which is the ceiling once the rows pass it.
        return min(bodyStack.fittingSize.height, bodyMaxHeight)
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
    /// Choreography (PLAN §E risk 1) — a clip height and nothing else, exactly
    /// like a subsection collapse and a row reveal:
    /// - **collapse:** SEED the clip-height constraint with the current expanded
    ///   height BEFORE animating it to 0 (symmetric with expand's explicit floor),
    ///   and set `isHidden` on the body ONLY in the completion handler (so it
    ///   stays rendered throughout). The seed is what makes the FIRST collapse of
    ///   a never-toggled card animate rather than snap (see the branch).
    /// - **expand:** clear `isHidden` BEFORE animating, then animate the clip
    ///   height from 0 up to the body's fitting height (deactivating the pinned-0
    ///   constraint at the end).
    ///
    /// `animated == false` (initial build + Reduce Motion) applies the end state
    /// synchronously with no animation. The animated path hands the clip height
    /// to `FoldAnimator` — the ONE driver every fold on this surface shares — so
    /// rapid toggles retarget from the live constant rather than queueing or
    /// fighting (PLAN §E risk 1: "retargetable rapid toggles"), and the panel's
    /// size (and the window's) is laid out FROM that height every tick rather
    /// than pre-measured and animated alongside it.
    ///
    /// `onComplete` fires when the fold settles (or immediately on the
    /// non-animated path) — the panel uses it to publish the final popover size
    /// on the paths the driver isn't following.
    func setBodyCollapsed(_ collapsed: Bool, animated: Bool,
                          onComplete: (() -> Void)? = nil) {
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
                bodyClip.isHidden = true
            } else {
                bodyClip.isHidden = false
                bodyHeightConstraint.isActive = false
            }
            onComplete?()
            return
        }

        collapseGeneration += 1
        let generation = collapseGeneration

        // START state committed and LAID OUT before the fold begins, so it
        // SNAPS into place and the fold has the full distance left to travel.
        // `insertRow` and `expandSubsection` commit their start state the same
        // way.
        //
        // Both seeds take the height the body is AT: the live (possibly
        // mid-flight) constant when this toggle retargets a running one —
        // the fold/reveal must continue from where the body is, because
        // jumping it to a rest height first makes the content momentarily
        // TALLER than the mid-flight window, the one deformation the surplus
        // shield cannot absorb (rows riding up to the window top on rapid
        // toggles). At rest the seeds are exactly the old values: collapse
        // starts at `target` (covering the first-collapse trap — a
        // never-expanded card's constraint holds its AS-CREATED constant 0,
        // and animating 0→0 would snap the body shut); expand floors at 0 (a
        // completed collapse leaves the constraint active at 0).
        let start: CGFloat
        if collapsed {
            start = bodyHeightConstraint.isActive
                ? bodyHeightConstraint.constant : target
        } else {
            // Clear hidden BEFORE the seed layout — a hidden arranged subview
            // is detached from stack layout entirely.
            bodyClip.isHidden = false
            start = bodyHeightConstraint.isActive
                ? bodyHeightConstraint.constant : 0
        }
        bodyHeightConstraint.constant = start
        bodyHeightConstraint.isActive = true
        lastAnimatedStartHeight = start
        layoutSubtreeIfNeeded()

        FoldAnimator.shared.animate(bodyHeightConstraint,
                                    to: collapsed ? 0 : target,
                                    follower: foldFollower) { [weak self] in
            guard let self else { onComplete?(); return }
            // A superseded fold's completion must NOT touch the terminal state
            // — the newest fold owns it (and will fire its own completion).
            guard generation == self.collapseGeneration else { onComplete?(); return }
            if self.isBodyCollapsed {
                self.bodyClip.isHidden = true
            } else {
                // Expanded: drop the pinned constraint so the body flexes with its
                // content again (e.g. a later row change).
                self.bodyHeightConstraint.isActive = false
            }
            onComplete?()
        }
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

/// The scrolling device list's document view: a plain container whose only job
/// is to be FLIPPED, so the list rests at its first row instead of its last.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
