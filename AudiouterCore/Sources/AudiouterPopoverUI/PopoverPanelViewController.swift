// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The panel hosted inside the popover's `contentViewController` (SPEC §9
/// revised, restyled 2026-07-14 — T-U8).
///
/// **De-nested (warm-signal-v2, spec §5.1):** through 2026-07-21 each section
/// ("System / Main Out", "Selected Devices") drew as a separate rounded-rect
/// Control Center-style card module — a translucent `NSVisualEffectView` tile
/// floating on the panel's own vibrant `.behindWindow` background (see git
/// history). The spec's "de-nest" replaces both halves of that: `background`
/// is now a single continuous **warm canvas** (`WarmCanvasView`, always
/// opaque — no vibrancy) and `CardView` no longer draws a tile of its own —
/// every section's rows sit directly on the canvas, separated only by a 1px
/// hairline divider this controller inserts between cards (`beginCard`).
///
/// It is a dumb container: `PopoverController` composes the sections and hands in
/// the rows; this controller lays them out and sizes the popover. The outer
/// vertical `stackView` holds the cards.
///
/// **Exact-fit sizing (T-3, PLAN-POPOVER-ROUTING.md §A/§E risk 1, 2026-07-16):**
/// the popover is exactly the height of its visible content and grows/shrinks
/// as sections expand or collapse. The size flows out through
/// `preferredContentSize` (the DOCUMENTED `NSPopover` channel — it tracks
/// `contentViewController.preferredContentSize` and animates on its own when
/// `popover.animates` is true; see `panelContentDidChangeHeight`).
///
/// **Height overflow (2026-08-10, owner-approved — this SUPERSEDES the original
/// "no `NSScrollView`, ever" rule):** exact fit has no answer for content taller
/// than the screen, and a realistic fleet (10+ device rows + an open sync drawer
/// + diagnosis panels) reaches it — the bottom cards simply became unreachable.
/// The card stack now lives in a **document view inside `contentScrollView`**,
/// and the ONE thing that changes in overflow is that scroll view's own height:
/// it hugs its document (`.defaultHigh`) so a fitting content stays byte-identical
/// to the pre-scroll design, and a REQUIRED `<=` cap — the screen budget the host
/// pushes in through `setMaxContentHeight(_:)` — takes over only once the content
/// outgrows the screen. No budget (headless, snapshot tools, any host that never
/// pushes one) means no cap and therefore never a scroller. Everything the rows
/// depend on — the clip-height reveals, the collapse machinery, and the rail
/// overlay — lives INSIDE the document, so it all scrolls together and none of it
/// had to learn about scrolling.
@MainActor
final class PopoverPanelViewController: NSViewController {

    /// A borderless icon button mounted on the right of a section's module header
    /// (task D — the Groups "+" / New group).
    struct HeaderAccessory {
        /// The SF Symbol name (system-rendered, template).
        let symbol: String
        /// Accessibility label + tooltip.
        let label: String
        /// Tapped handler.
        let action: () -> Void
        /// Whether the accessory button starts enabled (F1 support).
        /// Defaults to `true` so existing call sites are unaffected.
        let isEnabled: Bool

        init(symbol: String, label: String, action: @escaping () -> Void, isEnabled: Bool = true) {
            self.symbol = symbol
            self.label = label
            self.action = action
            self.isEnabled = isEnabled
        }
    }

    weak var controller: PopoverController?

    /// The vertical stack of section **cards** (and the footer card). Public to
    /// the module so the controller can animate `layoutSubtreeIfNeeded()` on it
    /// during a group's expand/collapse. It is also what re-invalidates the rail
    /// overlay — see `RailStackView`.
    let stackView = RailStackView()

    /// The card currently being filled by `addRow` / `addSubsectionHeader`.
    private var currentCard: CardView?

    // MARK: Collapsible-card bookkeeping (T-4)

    /// Cards keyed by their section title, so the controller (and tests) can
    /// toggle/inspect a card by title without holding a view reference.
    private var cardsByHeader: [String: CardView] = [:]
    /// Chevron buttons keyed by section title (for symbol flips + assertions).
    private var chevronsByHeader: [String: NSButton] = [:]
    /// Whole-header-row click recognizers keyed by section title (C4 — the
    /// entire `headerWrap` row is a collapse click target, not just the
    /// chevron + title; kept for the `test_fireHeaderClick` hook).
    private var headerClickRecognizersByHeader: [String: NSClickGestureRecognizer] = [:]
    /// Header accessory buttons keyed by section title (F1).
    private var accessoryButtonsByHeader: [String: NSButton] = [:]
    /// Card-note labels (`addCardNote`) keyed by section title, in add order
    /// (A1 test hook).
    private var notesByHeader: [String: [NSTextField]] = [:]
    /// The SF Symbol name currently assigned to each chevron (there's no public
    /// getter for an `NSImage`'s symbol name pre-macOS-14, so we track it for the
    /// chevron-flip test hook — set wherever the chevron image is assigned).
    private var chevronSymbolByHeader: [String: String] = [:]
    /// Initial collapse states recorded in `beginCard`, applied on the first body
    /// row (a header-only card has nothing to collapse until it has a body).
    private var pendingCollapsed: [String: Bool] = [:]

    // MARK: Collapsible SUBSECTION bookkeeping

    /// A device-type subsection's body: the rows in a stack of their own, inside
    /// a `RowClipView` whose height is the ONE animated dimension of a collapse
    /// (`setSubsectionCollapsed`) — `insertRow`'s choreography applied to a
    /// GROUP of rows instead of one.
    private struct SubsectionBody {
        let clip: RowClipView
        let stack: NSStackView
    }
    /// Subsection bodies keyed by subsection title, so a toggle can find the
    /// clip to animate without the host holding a view reference.
    private var subsectionBodies: [String: SubsectionBody] = [:]
    /// The subsection `addRow` is currently filling. `nil` between subsections,
    /// where rows go into the card body instead (`endSubsection`).
    private weak var currentSubsectionStack: NSStackView?

    /// The card stack's top pin, kept so the surface can seat the whole
    /// content below the window's toolbar strip (`setContentTopInset` — the
    /// one header lives on the WINDOW since the 2026-08-07 live review, so
    /// the panel is pure content). The inset rides the exact-fit measure for
    /// free because the pin is part of `contentContainer`'s required chain.
    private var contentTopConstraint: NSLayoutConstraint?

    /// The content's resting inset from the container top (breathing room the
    /// original layout always had; the surface's chrome inset adds to it).
    private static let contentRestingTopInset: CGFloat = 4

    /// The gap the card stack leaves above the container's bottom edge. Split
    /// out of the old `stackView.bottom == container.bottom - 12` because the
    /// scroll view now carries that pin, and the height cap has to subtract the
    /// same number to convert a WINDOW-content budget into a scroll-view height.
    private static let contentBottomMargin: CGFloat = 12

    /// The floor the screen budget can never push the scrollable region below —
    /// a pathologically short screen must still leave a usable band rather than
    /// collapsing the panel to its chrome. Nothing in the product reaches it.
    private static let minimumScrollableHeight: CGFloat = 120

    /// Popover width — SoundSource-style proportions so the columns
    /// (name · Volume · Device) line up. Narrowed 2026-07-16 (change 5): the
    /// flexible name column was over-wide, so `panelWidth` drops from 690 to 623,
    /// cutting the name column's reserved width ~25% (≈269 → ≈202pt with the fixed
    /// left chrome + slider/readout/trailing columns). Longer device names may
    /// truncate more — accepted. (Footer removed; actions moved to the header +
    /// Groups "+".)
    private let panelWidth: CGFloat = 623
    /// Trailing inset of a header's accessory button ("+", Groups) from the
    /// header row's OWN trailing edge — unrelated to card-tile geometry
    /// (there's no card margin to reuse after V2's de-nest; this keeps the
    /// button's on-screen position unchanged from before that change).
    private static let headerAccessoryTrailingInset: CGFloat = 12

    /// Associated-object key that keeps a chevron/title `ClosureActionTarget` alive
    /// for the lifetime of its button (target/action holds `target` weakly).
    private static var actionTargetKey: UInt8 = 0

    /// How long ANY collapsible element in this surface takes to unfold into —
    /// or fold out of — its host: an inserted row (`insertRow`/`removeRow`), a
    /// device-type subsection, and a card's body (`CardView.setBodyCollapsed`).
    /// ONE value and one curve (`.easeInEaseOut`) for all three, so an expand
    /// and its collapse are exact mirrors and the three read as a single motion
    /// language; a second constant kept in step by hand would silently drift
    /// (the card's own 0.2s was exactly that, live report 2026-08-10 — the cards
    /// "don't follow the same system"). 0.15s: Alec's live call on the previous
    /// 0.22s ("it's also not that snappy"). Short enough to feel immediate, long
    /// enough that the rows below still read as being PUSHED apart rather than
    /// jumping to a new position.
    static let collapseRevealDuration: TimeInterval = 0.15

    /// The panel height the most recent ANIMATED `insertRow` reveal starts FROM,
    /// recorded once the collapsed start state is laid out. A reveal that starts
    /// at the height it is growing TO has nothing left to animate, which is the
    /// whole bug the layout commit in `insertRow` exists to prevent — so the
    /// trajectory's start is worth pinning, exactly as `CardView` pins its
    /// collapse's (`lastAnimatedStartHeight`). `nil` until the first animated
    /// insert.
    private(set) var test_rowRevealStartHeight: CGFloat?

    /// Test seam for Reduce Motion (`nil` = the live system setting) — the
    /// same override pattern `DeviceRowView` and `PopoverController` already
    /// use. Both sides have to be drivable from a test: on a machine with
    /// Reduce Motion switched ON every animated path below short-circuits, so
    /// a regression test for the animated case would pass vacuously.
    var test_reduceMotionOverride: Bool?

    /// Whether motion should be flattened — System Settings › Accessibility ›
    /// Display › Reduce Motion, through the seam above.
    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The Mixer's canvas — the single continuous surface every de-nested
    /// section sits directly on, filling `container` behind everything else.
    /// Owner decision D2 (live build review 2026-08-07): every surface screen
    /// sits on the GROUPS content pane's flat warm `panel` fill
    /// (`WarmPanelView`), so this supersedes the spec-§5.1 `WarmCanvasView`
    /// gradient+grain here (the Setup window keeps it). Always fully opaque —
    /// no Reduce-Transparency special case needed.
    private let background = WarmPanelView()

    /// The continuous membership-rail spine (Warm Signal v4 §Call-1): drawn once
    /// for the whole panel, ON TOP of every card + divider, so the rail is one
    /// uninterrupted line down a clear left gutter (section titles sit to its
    /// right, at the icon column). Fed the Main Audio row + device rows by the
    /// controller each rebuild; repainted on every layout by `RailStackView`.
    let railOverlay = BusRailOverlayView()

    /// The rigid content column — header + card stack, chained top-to-bottom by
    /// REQUIRED constraints, so its `fittingSize` is exactly the content height.
    /// This, not `view`, is what `fittingSizeSettled` measures: `view` is the
    /// surplus-shield wrapper, and a wrapper's `fittingSize` was MEASURED to keep
    /// a feasible stale frame height rather than minimize down to its `<=` floor
    /// (returned the pre-collapse height after a card collapsed, at every pin
    /// priority tried, and with no pin at all).
    private let contentContainer = NSView()

    /// The scrolling host wrapped around the card stack (height-overflow rule,
    /// class doc). Its own height is the only quantity overflow changes; the
    /// document inside it keeps its natural height either way, so every row's
    /// geometry, every clip animation and the rail are untouched by the cap.
    private let contentScrollView = NSScrollView()

    /// The scrolled document: the card stack AND the rail overlay together, in
    /// exactly the z-order and the pinning they had inside `contentContainer`
    /// before the scroll view existed. The overlay MUST live in here — it draws
    /// one continuous spine through row frames it converts out of their own
    /// coordinate space, so a spine left outside the document would keep the
    /// last painted figure while the rows slid under it (the same displacement
    /// the 2026-08-06 invalidation bug produced, but permanent).
    private let scrollDocument = FlippedDocumentView()

    /// `contentScrollView.height <= budget`, REQUIRED — the cap half, active
    /// only while a host has pushed a screen budget (`setMaxContentHeight`).
    /// Inactive is the pre-scroll behavior exactly: pure exact fit.
    private var scrollHeightCap: NSLayoutConstraint?

    /// The tallest window CONTENT height this panel may publish, as measured by
    /// its host against the anchor screen. `nil` — the default, and what every
    /// headless/offscreen render sees — means UNCAPPED: no cap constraint, no
    /// scroller, byte-identical exact fit.
    private var maxContentHeight: CGFloat?

    override func loadView() {
        let container = contentContainer
        stackView.railOverlay = railOverlay
        container.translatesAutoresizingMaskIntoConstraints = false

        background.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background)   // re-parented onto the wrapper below

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        // Vertical gap BETWEEN sections (V2: cards no longer float as separate
        // tiles with their own margin-created gap — narrowed from 12 to 8pt now
        // that the 1px hairline divider (`beginCard`) carries the separation
        // instead of whitespace-around-a-rounded-tile; a designer's pick, tune
        // live).
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        scrollDocument.translatesAutoresizingMaskIntoConstraints = false
        scrollDocument.addSubview(stackView)
        // The rail overlay is added LAST so it composites ON TOP of the cards +
        // hairline dividers — the continuous spine reads unbroken where it would
        // otherwise be crossed. Non-interactive (`hitTest` returns nil). It is a
        // sibling of the stack INSIDE the scrolled document (see the property's
        // note), not of the scroll view.
        railOverlay.translatesAutoresizingMaskIntoConstraints = false
        scrollDocument.addSubview(railOverlay)

        configureContentScrollView()
        contentScrollView.documentView = scrollDocument
        container.addSubview(contentScrollView)

        // The stack's top pin, kept for the surface's toolbar chrome inset —
        // now carried by the scroll view, which is what sits where the stack
        // used to. `setContentTopInset` still moves exactly this constraint,
        // and it still rides the exact-fit measure.
        let contentTop = contentScrollView.topAnchor.constraint(
            equalTo: container.topAnchor, constant: Self.contentRestingTopInset)
        contentTopConstraint = contentTop

        // "Hug the content": an `NSScrollView` has NO intrinsic size, so without
        // this the whole panel collapses to zero under `fittingSize` (the same
        // pair `GroupCreationSheetController`'s membership checklist relies on).
        // Below required so the cap can out-vote it in overflow — and BELOW the
        // rows' 750 compression resistance, or the broken hug drags the DOCUMENT
        // down to the budget with it (a 750-vs-750 tie the engine resolved by
        // compressing the content, so a capped panel clipped instead of
        // scrolling). 600 keeps it above the ~500 floor `fittingSize` honors.
        let hug = contentScrollView.heightAnchor.constraint(
            equalTo: scrollDocument.heightAnchor)
        hug.priority = NSLayoutConstraint.Priority(600)
        // Built inactive: no host has pushed a budget yet, and a panel with no
        // budget must behave exactly as it did before this scroll view existed.
        let cap = contentScrollView.heightAnchor.constraint(
            lessThanOrEqualToConstant: Self.minimumScrollableHeight)
        cap.isActive = false
        scrollHeightCap = cap

        // The stack is pinned to all four edges of the scrolled DOCUMENT, and the
        // document's height is the scroll view's (via `hug`) unless the cap takes
        // over. That keeps the container's height a pure function of the stack's
        // fitting height in the fitting case — the original exact fit, one view
        // deeper.
        //
        // EMPTY-POPOVER AUTO-LAYOUT TRAP (preserved from the pre-scroll design,
        // T-U8: MUST NOT regress): the stack MUST be pinned top AND bottom so its
        // intrinsic content height drives its host. Historically the scroll
        // area was under-constrained and Auto Layout collapsed it to ~0, hiding
        // every card. Here the same guarantee comes from the stack's bottom pin
        // to `scrollDocument` below — without it the stack would be free to
        // collapse to zero height and silently hide all cards, and the document
        // would have no height to give the scroll view either.
        //
        // The document is pinned to the scroll view only on the NON-scrolling
        // axis (`width == scrollView.width`) — the recipe
        // `GroupCreationSheetController` already proves in this codebase.
        // Constraining it to the clip view's top/bottom instead would fight the
        // clip's bounds-origin scrolling.
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: panelWidth),

            // The background fills the whole container, behind everything else.
            // (Its bottom pin moves to the WRAPPER below, so a surplus-taller
            // wrapper still reads as continuous canvas — see the surplus shield.)
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // The scroll view sits exactly where the stack used to: container-top
            // (`contentTop`, kept for the surface's toolbar chrome inset) →
            // container-bottom less `contentBottomMargin`, full width.
            contentTop,
            contentScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // The bottom pin, SPLIT (Alec's call, 2026-08-06). It used to be a
            // single required `==`, which made a container taller than its content
            // unsatisfiable — so Auto Layout deformed the content instead, dumping
            // the surplus into whatever had nothing pinning its height. In practice
            // that was the pinned banner, which ballooned into a tall empty box and
            // pushed every card below it down (the live report). The re-fit in
            // `insertRow`/`removeRow` stops the mismatch arising, but this makes the
            // failure mode boring rather than broken if one ever does:
            contentScrollView.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -Self.contentBottomMargin),
            hug,

            scrollDocument.widthAnchor.constraint(equalTo: contentScrollView.widthAnchor),

            stackView.topAnchor.constraint(equalTo: scrollDocument.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollDocument.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollDocument.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollDocument.bottomAnchor),

            // The rail overlay spans the whole DOCUMENT (it reads row frames in
            // its own coordinate space and draws the spine in the left gutter),
            // so the spine travels with the rows it runs through.
            railOverlay.topAnchor.constraint(equalTo: scrollDocument.topAnchor),
            railOverlay.leadingAnchor.constraint(equalTo: scrollDocument.leadingAnchor),
            railOverlay.trailingAnchor.constraint(equalTo: scrollDocument.trailingAnchor),
            railOverlay.bottomAnchor.constraint(equalTo: scrollDocument.bottomAnchor),
        ])
        // SURPLUS SHIELD (Alec's resilience call, 2026-08-06). The content keeps
        // its original, fully-REQUIRED constraint chain — that rigidity is what
        // makes its fitting height exact — and the popover sizes this WRAPPER
        // instead. The container hangs from the wrapper's top; the required `<=`
        // stops it overflowing; and there is deliberately NO constraint pulling
        // the container's bottom down to the wrapper's. Every in-place softening
        // was measured to fail: a `<=` bottom pin let `fittingSize` return stale
        // frame heights; an added `==` needed priority >500 before `fittingSize`
        // honored it, but anything ≥251 lets an over-tall wrapper stretch the
        // banner (its label hugs at 250) — the live report's tall empty box. No
        // such priority exists, so the wrapper carries no tail pin and the size
        // channel reads `contentContainer.fittingSize` directly (see
        // `fittingSizeSettled`). A wrapper taller than the content — the
        // pathology behind the ballooned banner — now just shows inert warm
        // canvas below the last card (the canvas backs the WRAPPER), with every
        // row's geometry, and therefore the rail's anchoring, untouched.
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)
        NSLayoutConstraint.activate([
            background.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            container.bottomAnchor.constraint(lessThanOrEqualTo: wrapper.bottomAnchor),
        ])
        view = wrapper
    }

    // MARK: Height overflow (2026-08-10, owner-approved)

    /// Configure the scroll view so that, while the content FITS, it is
    /// invisible in every sense that matters: no background of its own (the warm
    /// canvas behind it is the one surface fill), no bezel, no content-inset
    /// adjustment, no scroller and no elasticity — a trackpad flick on a fitting
    /// panel must not shift a pixel. `applyOverflowState()` turns the last two on
    /// only while the content actually overflows. The scroller style is pinned to
    /// `.overlay` so it can never claim layout WIDTH: the panel's 623pt column is
    /// a fixed grid and a legacy scroller gutter would reflow every row.
    private func configureContentScrollView() {
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.drawsBackground = false
        contentScrollView.contentView.drawsBackground = false
        contentScrollView.borderType = .noBorder
        contentScrollView.automaticallyAdjustsContentInsets = false
        contentScrollView.scrollerStyle = .overlay
        contentScrollView.autohidesScrollers = true
        contentScrollView.hasHorizontalScroller = false
        contentScrollView.horizontalScrollElasticity = .none
        contentScrollView.hasVerticalScroller = false
        contentScrollView.verticalScrollElasticity = .none
    }

    /// The tallest window CONTENT height this panel may publish, as measured by
    /// its host against the anchor screen — or `nil` for UNCAPPED.
    ///
    /// The host owns this because the host is the only thing that knows which
    /// screen the surface is anchored to and how much of the window is chrome
    /// (`AppSurfaceController.mixerContentHeightBudget`). Nothing pushes one
    /// headlessly, so `swift test` and the offscreen snapshot tools render the
    /// full natural height and never scroll.
    func setMaxContentHeight(_ height: CGFloat?) {
        _ = view   // ensure `loadView` ran so the cap constraint exists
        guard maxContentHeight != height else { return }
        maxContentHeight = height
        updateContentHeightCap()
    }

    /// Re-derive the scroll view's REQUIRED height cap from the current budget.
    /// The budget is a window-CONTENT height; the scrollable region is what is
    /// left after the container's own top inset (which the surface's toolbar
    /// chrome inflates) and its bottom margin — so this has to re-run whenever
    /// EITHER the budget or `setContentTopInset` changes.
    private func updateContentHeightCap() {
        guard let cap = scrollHeightCap else { return }
        guard let budget = maxContentHeight else {
            cap.isActive = false
            applyOverflowState()
            return
        }
        let chrome = (contentTopConstraint?.constant ?? Self.contentRestingTopInset)
            + Self.contentBottomMargin
        cap.constant = max(Self.minimumScrollableHeight, budget - chrome)
        cap.isActive = true
        applyOverflowState()
    }

    /// Whether the card stack is currently taller than the capped region can
    /// show — the single predicate the scroller, the elasticity and the
    /// scroll-into-view of an inserted row all read. Always `false` uncapped.
    var isContentOverflowing: Bool {
        guard maxContentHeight != nil, let cap = scrollHeightCap, cap.isActive else { return false }
        return scrollDocument.fittingSize.height > cap.constant + 0.5
    }

    /// Turn the scroller and vertical elasticity on exactly while the content
    /// overflows. Called from `publishContentSize` — the one funnel every size
    /// change already goes through — so the affordance can never lag the content
    /// that produced it.
    private func applyOverflowState() {
        let overflowing = isContentOverflowing
        contentScrollView.hasVerticalScroller = overflowing
        contentScrollView.verticalScrollElasticity = overflowing ? .allowed : .none
    }

    /// Put the scrolled content back at the top. Every OPEN of the Mixer starts
    /// there (`AppSurfaceController.mount`, right after the open ritual) — a
    /// reopen that resumed someone's old scroll offset would show a fleet from
    /// the middle with no explanation. The document is flipped, so `.zero` IS
    /// the top.
    func scrollContentToTop() {
        _ = view   // ensure `loadView` ran
        let clip = contentScrollView.contentView
        clip.scroll(to: .zero)
        contentScrollView.reflectScrolledClipView(clip)
    }

    /// Bring a just-inserted row into the visible band when the panel is capped.
    /// A sync drawer or diagnosis panel that unfolds BELOW the fold is worse
    /// than no cap at all — the user clicked a control and nothing appeared to
    /// happen. No-op while the content fits (there is nothing to scroll) and
    /// while the row has already left the tree.
    private func revealInScrollableArea(_ target: NSView) {
        guard isContentOverflowing, target.superview != nil else { return }
        scrollDocument.layoutSubtreeIfNeeded()
        _ = target.scrollToVisible(target.bounds)
    }

    /// Point the continuous rail overlay at the current Main Audio row + device
    /// rows (top-to-bottom display order) AND the two collapsible cards the rail
    /// spans (the origin card holding Main Audio, the device card holding the
    /// rows), then repaint it. The controller calls this at the end of every
    /// rebuild / in-place device repaint. Passing the cards by title lets the
    /// overlay react to a collapse: terminate the rail at the collapsed section's
    /// header, move the origin up when the origin card collapses, and squeeze in
    /// sync with the clip animation (collapse-reactive rail, 2026-07-22).
    func setRailRows(mainOut: RailHookProviding, deviceRows: [RailNodeProviding],
                     originCardTitle: String, deviceCardTitle: String) {
        railOverlay.mainOutRow = mainOut
        railOverlay.deviceRows = deviceRows
        railOverlay.originSection = cardsByHeader[originCardTitle]
        railOverlay.deviceSection = cardsByHeader[deviceCardTitle]
        railOverlay.needsDisplay = true
    }

    // MARK: Exact-fit sizing (T-3)

    /// The single source of truth for the popover's target size: settle Auto Layout
    /// synchronously (`layoutSubtreeIfNeeded`), then read the container's
    /// `fittingSize`. Callers push this into `preferredContentSize` so the popover
    /// resizes to exactly the visible content (PLAN-POPOVER-ROUTING.md §E risk 1 —
    /// "layout settled synchronously before animating").
    ///
    /// The CAP is already folded in, and deliberately so: the scroll view's
    /// REQUIRED `<=` out-votes its `.defaultHigh` hug, so this returns
    /// `min(natural, budget)` without any caller having to know a budget exists.
    /// The DOCUMENT still measures its full natural height — which is why
    /// `insertRow`'s `clip.frame.height` reveal target stays correct in overflow.
    func fittingSizeSettled() -> NSSize {
        _ = view   // ensure `loadView` ran
        view.layoutSubtreeIfNeeded()
        // The RIGID content column, not `view`: the wrapper's own `fittingSize`
        // keeps stale frame heights (see the surplus-shield note in `loadView`).
        return contentContainer.fittingSize
    }

    /// The single resize primitive (T-3 → consumed by the collapsible-sections task
    /// T-4). Settle layout, then publish the new size through the popover's
    /// DOCUMENTED size channel: `contentViewController.preferredContentSize`.
    /// `NSPopover` observes this property and, when `popover.animates` is true,
    /// animates the frame change ON ITS OWN — so we do NOT set `popover.contentSize`
    /// directly, and we do NOT wrap the assignment in an `NSAnimationContext`
    /// (there is no `animator()` proxy on `NSViewController`; the popover, not us,
    /// runs the resize animation). One channel, used consistently: PLAN §E risk 1
    /// "prefer the preferredContentSize channel".
    ///
    /// `animated` selects the animation via `PopoverController.applySurfaceResize`
    /// (the controller, not the panel, knows the current host): under the popover
    /// host that toggles `popover.animates` around the `preferredContentSize`
    /// assignment. The non-animated path is used for the
    /// initial show and when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
    /// is true (the jank escape hatch); it applies the size with `animates` forced
    /// off so no frame animation runs. Because `NSPopover` retargets a
    /// `preferredContentSize` change mid-flight against its own running animation,
    /// rapid expand/collapse toggles glide rather than fight (PLAN §E risk 1
    /// "retargetable rapid toggles"). T-4 animates a card's clip-height constraint
    /// alongside this so the panel and popover agree.
    func panelContentDidChangeHeight(animated: Bool) {
        publishContentSize(fittingSizeSettled(), animated: animated)
    }

    /// Publish an ALREADY-MEASURED size through the same channel. Split out for
    /// `insertRow`, which has to measure the row's final height while the row is
    /// visible but publish it later, once the collapsed start state is laid out —
    /// re-measuring at that point would read the collapsed height and tell the
    /// popover to stay put.
    private func publishContentSize(_ target: NSSize, animated: Bool) {
        let wantsAnimation = animated && !reduceMotion
        // The scroller follows the size that is being published, in the same
        // turn — this is the one funnel every size change reaches.
        applyOverflowState()
        // Assigning `preferredContentSize` is the sole size channel; the
        // controller decides how the current host animates the change.
        if let controller {
            controller.applySurfaceResize(animated: wantsAnimation) { [weak self] in
                self?.preferredContentSize = target
            }
        } else {
            // No controller (offscreen harness/snapshot): still publish the size so
            // `fittingSize`/`preferredContentSize` are exact for the render.
            preferredContentSize = target
        }
    }

    // MARK: Rows API (called by PopoverController)

    /// Remove every card (used before a rebuild).
    func clearRows() {
        for v in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        currentCard = nil
        currentSubsectionStack = nil
        subsectionBodies.removeAll()
        cardsByHeader.removeAll()
        chevronsByHeader.removeAll()
        chevronSymbolByHeader.removeAll()
        pendingCollapsed.removeAll()
        headerClickRecognizersByHeader.removeAll()
        accessoryButtonsByHeader.removeAll()
        notesByHeader.removeAll()
    }

    /// Start a new section **card** whose FIRST element is a single combined
    /// header row (change 1 — save vertical space): the prominent Control
    /// Center–style section title (label color, medium weight, 14pt — like
    /// "Sound" / "Display" in CC) on the LEFT, and the column header labels on the
    /// RIGHT of the SAME row, each centered over its column against the shared
    /// `PopoverColumnGrid` (VOLUME over the slider column, the trailing-column
    /// header over the trailing control). This replaces the old two-row layout (a
    /// ~30pt title row followed by a separate ~22pt column-header row). Subsequent
    /// `addRow` / `addSubsectionHeader` calls fill this card until the next
    /// `beginCard`.
    ///
    /// `volumeTitle` / `trailingTitle` are the two column headers; passing `nil`
    /// omits that label (e.g. the System card has no "Volume"-less variant, but a
    /// card without a trailing control can pass `trailingTitle: nil`). The System
    /// card passes `trailingTitle: "Device"` (over the destination dropdown); the
    /// Selected Devices card passes `"Enabled"` (over the membership toggle).
    ///
    /// `trailingAccessory` optionally mounts a borderless icon button on the RIGHT
    /// of the module header (task D — the Groups section's "+" / New group). The
    /// button's `accessibilityLabel`/`toolTip` are set from `accessory.label`.
    ///
    /// **Collapsible cards (T-4, PLAN-POPOVER-ROUTING.md decision 5 + §E risk 1;
    /// whole-header click target — C4 LOCKED DECISION, 2026-07-18).** When
    /// `collapsible` is true the header row gains a leading disclosure chevron
    /// (`chevron.down` expanded / `chevron.right` collapsed, per `GroupRowView`'s
    /// precedent) placed LEFT of the section title, and the ENTIRE `headerWrap`
    /// row — chevron, title, AND the column-header labels — is a click target
    /// that calls `onToggle`: an `NSClickGestureRecognizer` on `headerWrap` itself
    /// forwards to the same closure the chevron's target/action uses. The
    /// chevron keeps its own working click (a button subview claims its own
    /// click before an ancestor's gesture recognizer ever sees it, so it isn't
    /// double-toggled), and the trailing accessory stays the one INERT control
    /// for the same reason — it's a button too, so its tap is consumed before
    /// reaching `headerWrap`'s recognizer. Column headers, by contrast, are
    /// plain (non-control) labels, so a click there falls through to the
    /// recognizer and DOES toggle — accepted, not a bug. `collapsed` is the
    /// INITIAL state: the card body is laid out collapsed (height 0, hidden) with
    /// no animation. The parameters default so existing (non-collapsible) call
    /// sites compile and behave exactly as before. The host owns the collapse
    /// POLICY (recomputing `collapsed` per open, flipping it in `onToggle` +
    /// re-driving `test_toggleCard`/`setCardCollapsed`); this method only builds
    /// the affordance.
    func beginCard(header: String,
                   volumeTitle: String? = nil,
                   trailingTitle: String? = nil,
                   trailingAccessory accessory: HeaderAccessory? = nil,
                   collapsible: Bool = false,
                   collapsed: Bool = false,
                   onToggle: (() -> Void)? = nil) {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        cardsByHeader[header] = card
        // A new card ends any subsection still being filled — its rows belong to
        // the card body, never to the previous card's last subsection clip.
        currentSubsectionStack = nil

        // The combined header row is the FIRST element inside the tile: section
        // title on the left, column headers centered over their columns on the
        // right. Height ~28pt (change 1 — one row instead of title + header).
        // The section title DISPLAYS uppercased (Warm Signal §5.1 silkscreen
        // vocabulary / v4 §Call-1 "MAIN AUDIO"); the `header` argument stays the
        // title-case lookup/collapse KEY.
        let label = NSTextField(labelWithString: header.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        // The nearest existing token for "emphasized heading at the standard
        // size" — the hand-rolled 14pt/medium it replaces was the last
        // hardcoded font in this file. NOTE the small delta: `bodyEmphasized`
        // is 13pt semibold, so the section title reads one point smaller and a
        // shade heavier than before.
        label.font = Tokens.Font.bodyEmphasized
        label.textColor = Tokens.Color.label
        let headerWrap = NSView()
        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        headerWrap.autoresizingMask = [.width]

        // Leading disclosure chevron (decision 5). Warm Signal v4 §Call-1 (Alec's
        // continuity correction): the whole header group starts at the DEVICE
        // ICON column (`firstElementLeading`), NOT the plain leading inset — so
        // the section title sits to the RIGHT of the rail's left-gutter lane,
        // leaving that lane entirely to the continuous spine. The chevron's left
        // edge aligns with the icon tiles below it; the title follows.
        let sectionLeadingInset = PopoverColumnGrid.firstElementLeading(indented: false)
        var titleLeadingAnchor = headerWrap.leadingAnchor
        var titleLeadingConstant = sectionLeadingInset
        if collapsible {
            let chevron = NSButton()
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.bezelStyle = .accessoryBar
            chevron.isBordered = false
            chevron.imagePosition = .imageOnly
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.contentTintColor = Tokens.Color.secondaryLabel
            chevron.setAccessibilityLabel(collapsed ? "Expand \(header)" : "Collapse \(header)")
            let toggle = onToggle
            let onChevron = ClosureActionTarget { toggle?() }
            chevron.target = onChevron
            chevron.action = #selector(ClosureActionTarget.fire)
            objc_setAssociatedObject(chevron, &Self.actionTargetKey, onChevron, .OBJC_ASSOCIATION_RETAIN)
            headerWrap.addSubview(chevron)
            headerWrap.addSubview(label)
            NSLayoutConstraint.activate([
                chevron.leadingAnchor.constraint(equalTo: headerWrap.leadingAnchor,
                                                 constant: sectionLeadingInset),
                chevron.centerYAnchor.constraint(equalTo: headerWrap.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 16),
            ])
            titleLeadingAnchor = chevron.trailingAnchor
            titleLeadingConstant = 4
            chevronsByHeader[header] = chevron
            assignChevron(chevron, collapsed: collapsed, for: header)
        } else {
            headerWrap.addSubview(label)
        }
        NSLayoutConstraint.activate([
            headerWrap.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: titleLeadingAnchor,
                                            constant: titleLeadingConstant),
            label.centerYAnchor.constraint(equalTo: headerWrap.centerYAnchor),
        ])

        // Column-header labels on the RIGHT of the same row, each centered over
        // its column via the shared grid's trailing-anchored center helpers so
        // they line up with the slider / trailing control in the rows below.
        if let volumeTitle {
            let volumeLabel = Self.makeColumnHeaderLabel(volumeTitle)
            headerWrap.addSubview(volumeLabel)
            NSLayoutConstraint.activate([
                volumeLabel.centerXAnchor.constraint(
                    equalTo: headerWrap.trailingAnchor,
                    constant: -PopoverColumnGrid.sliderCenterFromTrailing),
                volumeLabel.centerYAnchor.constraint(equalTo: headerWrap.centerYAnchor),
            ])
        }
        if let trailingTitle {
            let trailingLabel = Self.makeColumnHeaderLabel(trailingTitle)
            headerWrap.addSubview(trailingLabel)
            NSLayoutConstraint.activate([
                trailingLabel.centerXAnchor.constraint(
                    equalTo: headerWrap.trailingAnchor,
                    constant: -PopoverColumnGrid.trailingControlCenterFromTrailing),
                trailingLabel.centerYAnchor.constraint(equalTo: headerWrap.centerYAnchor),
            ])
        }

        if let accessory {
            // The trailing header accessory (task D — the Groups "+"; F1 — the
            // button is kept alive and keyed by header title so the host can
            // enable/disable it in place later via `setAccessoryEnabled`, without
            // rebuilding the card). Styled with `.accessoryBar` bezel and
            // hover-only border — the popover's one icon-button family.
            let button = NSButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .accessoryBar
            button.isBordered = true
            button.showsBorderOnlyWhileMouseInside = true
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = Tokens.Color.secondaryLabel
            button.isEnabled = accessory.isEnabled
            // System-rendered template SF Symbol (task D — `plus`), verified
            // non-nil with a graceful fallback.
            for name in [accessory.symbol, "plus"] {
                if let image = NSImage(systemSymbolName: name,
                                       accessibilityDescription: accessory.label) {
                    image.isTemplate = true
                    button.image = image
                    break
                }
            }
            button.setAccessibilityLabel(accessory.label)
            button.toolTip = accessory.label
            // Same closure-forwarding idiom as the chevron above (T-4): retain
            // the target via an associated object on the button itself so it
            // lives exactly as long as the button.
            let onAccessory = ClosureActionTarget(accessory.action)
            button.target = onAccessory
            button.action = #selector(ClosureActionTarget.fire)
            objc_setAssociatedObject(button, &Self.actionTargetKey, onAccessory, .OBJC_ASSOCIATION_RETAIN)
            headerWrap.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: headerWrap.trailingAnchor,
                                                 constant: -Self.headerAccessoryTrailingInset),
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
            accessoryButtonsByHeader[header] = button
        }

        // C4 LOCKED DECISION: the whole `headerWrap` row is the collapse click
        // target (see the doc comment above), not just the chevron + title. One
        // `NSClickGestureRecognizer` on `headerWrap` forwards to `onToggle`; the
        // chevron and accessory buttons above claim their own clicks first (an
        // ancestor's gesture recognizer does not intercept a click that lands on
        // an `NSButton` subview), so neither is double-toggled and the accessory
        // never toggles the card.
        if collapsible {
            let onHeaderClick = ClosureActionTarget { onToggle?() }
            let headerClick = NSClickGestureRecognizer(target: onHeaderClick,
                                                        action: #selector(ClosureActionTarget.fire))
            headerWrap.addGestureRecognizer(headerClick)
            objc_setAssociatedObject(headerWrap, &Self.actionTargetKey, onHeaderClick,
                                     .OBJC_ASSOCIATION_RETAIN)
            headerClickRecognizersByHeader[header] = headerClick
        }

        card.addRow(headerWrap)

        // V2 de-nest (spec §5.1): a card no longer floats as its own tile with
        // a side margin — it fills the FULL panel width, edge-to-edge with the
        // stack, so every section sits flush on the continuous warm canvas.
        // The ONLY visual separation from the section before it is a 1px
        // hairline divider, inserted here (not by `CardView` itself — cards
        // draw zero chrome of their own now) BEFORE this card, skipped for the
        // very first section.
        if stackView.arrangedSubviews.contains(where: { $0 is CardView }) {
            let hairline = HairlineView()
            hairline.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(hairline)
            NSLayoutConstraint.activate([
                hairline.heightAnchor.constraint(equalToConstant: 1),
                // Start the divider at the icon column (Warm Signal v4 §Call-1) so
                // the left rail gutter stays clear for the continuous spine.
                hairline.leadingAnchor.constraint(
                    equalTo: stackView.leadingAnchor,
                    constant: PopoverColumnGrid.firstElementLeading(indented: false)),
                hairline.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
            ])
        }

        stackView.addArrangedSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
        ])

        currentCard = card
        // Remember the initial collapse state so the FIRST body row can apply it
        // synchronously (non-animated) once the body exists — the header alone has
        // nothing to collapse yet.
        if collapsible { pendingCollapsed[header] = collapsed }
    }

    /// Add a content row (Main Out row, group header, device row) into the
    /// current card's COLLAPSIBLE body, full card width. On the first body row of
    /// a card that opened collapsed, apply the initial collapsed end state (no
    /// animation).
    ///
    /// While a subsection is open (`addSubsectionHeader` → `endSubsection`) the
    /// row lands in THAT subsection's clip instead, so collapsing the subsection
    /// takes it with it.
    func addRow(_ view: NSView) {
        if let stack = currentSubsectionStack {
            stack.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
            return
        }
        guard let card = currentCard else { return }
        card.addBodyRow(view)
        applyPendingCollapseIfNeeded(card)
    }

    /// Close the subsection currently being filled: later `addRow` calls go back
    /// into the CARD's body. The Devices card's "+" footer strip belongs to the
    /// card, not to the last subsection above it — collapsing Bluetooth must not
    /// take the strip away with it.
    func endSubsection() { currentSubsectionStack = nil }

    /// Apply a card's deferred initial collapse (recorded in `beginCard`) once its
    /// body exists. Synchronous end state, no animation (PLAN §E risk 1 — initial
    /// show uses the non-animated path).
    private func applyPendingCollapseIfNeeded(_ card: CardView) {
        guard let header = cardsByHeader.first(where: { $0.value === card })?.key,
              let collapsed = pendingCollapsed[header] else { return }
        pendingCollapsed[header] = nil
        card.setBodyCollapsed(collapsed, animated: false)
    }

    // MARK: Collapse / expand (T-4, PLAN decision 5 + §E risk 1)

    /// Set a card's collapsed state by section title and follow it with the
    /// surface resize. Drives the card's clip-height animation and the published
    /// content size in lockstep — the body clips at `collapseRevealDuration`, the
    /// same duration and curve a subsection and an inserted row travel on, so
    /// every collapsible thing on this surface reads as one motion language.
    /// `animated == false` (Reduce Motion, headless or programmatic) applies both
    /// end states synchronously. Flips the chevron symbol to match. No-op if
    /// `title` isn't a collapsible card.
    ///
    /// The surface resize runs via `panelContentDidChangeHeight(animated:)`, which
    /// already gates itself on `accessibilityDisplayShouldReduceMotion`; the card
    /// animation is gated the same way here so both honor Reduce Motion together.
    @discardableResult
    func setCardCollapsed(title: String, collapsed: Bool, animated: Bool) -> Bool {
        guard let card = cardsByHeader[title] else { return false }
        // Reduce Motion AND headless resolve instantly and completely, exactly as
        // `setSubsectionCollapsed` does: an `NSAnimationContext` completion handler
        // never fires for a view in no window.
        let wantsAnimation = animated && !reduceMotion && !HeadlessRuntime.isActive

        if let chevron = chevronsByHeader[title] {
            assignChevron(chevron, collapsed: collapsed, for: title)
            chevron.setAccessibilityLabel(collapsed ? "Expand \(title)" : "Collapse \(title)")
        }

        card.setBodyCollapsed(collapsed, animated: wantsAnimation) { [weak self] in
            // Republish the exact-fit size once the card settles (non-animated tail
            // for the completion; the in-flight popover resize below already tracked
            // the animation).
            if !wantsAnimation { self?.panelContentDidChangeHeight(animated: false) }
        }
        // Kick the surface resize in the SAME turn as the card animation so both
        // run together: `animator().constant` sets the model value immediately, so
        // this re-fit measures where the body is GOING and the window travels with
        // it rather than after it (`AppSurfaceController.applyWindowContentSize`
        // runs its own frame animation) — the subsection collapse's rule exactly.
        if wantsAnimation { panelContentDidChangeHeight(animated: true) }
        return true
    }

    /// Toggle a card's collapse state (used by the chevron/title click + tests).
    /// Returns the NEW collapsed state, or `nil` if `title` isn't a collapsible
    /// card.
    @discardableResult
    func toggleCard(title: String, animated: Bool = true) -> Bool? {
        guard let card = cardsByHeader[title] else { return nil }
        let next = !card.isBodyCollapsed
        setCardCollapsed(title: title, collapsed: next, animated: animated)
        return next
    }

    /// Collapse/expand a device-type SUBSECTION by animating its body clip's
    /// height — `insertRow`/`removeRow`'s choreography applied to the whole group
    /// of rows a subsection holds, at the same `collapseRevealDuration` and curve, so
    /// a drawer and a section read as one motion language. Flips the chevron to
    /// match. `false` if `title` has no mounted subsection body.
    ///
    /// This deliberately does NOT rebuild: a rebuild puts the content at its
    /// final size instantly and leaves only the SURFACE animating, which is the
    /// mismatch the live report called a snap/judder.
    ///
    /// `buildRows` runs on an EXPAND only, and BEFORE the measure — rows added
    /// inside it land in this subsection's clip, so the clip's natural height
    /// (and the panel's published height) already includes them. On a COLLAPSE
    /// the rows are torn down when the clip finishes closing; the host is
    /// expected to have dropped them from its MODEL on the click itself, since
    /// no completion handler ever fires for a view in no window.
    @discardableResult
    func setSubsectionCollapsed(title: String, collapsed: Bool, animated: Bool,
                                buildRows: () -> Void) -> Bool {
        guard let body = subsectionBodies[title] else { return false }
        if let chevron = chevronsByHeader[title] {
            assignChevron(chevron, collapsed: collapsed, for: title)
            chevron.setAccessibilityLabel(collapsed ? "Expand \(title)" : "Collapse \(title)")
        }
        // Reduce Motion AND headless resolve instantly and completely: an
        // `NSAnimationContext` completion handler never fires for a view in no
        // window, so a deferred teardown would leave the rows mounted forever.
        let wantsAnimation = animated && !reduceMotion && !HeadlessRuntime.isActive
        if collapsed {
            collapseSubsection(body, animated: wantsAnimation)
        } else {
            expandSubsection(body, animated: wantsAnimation, buildRows: buildRows)
        }
        return true
    }

    /// Fold a subsection shut: seed the clip with its current height, lay THAT
    /// out, then animate it to 0 — the exact mirror of the expand below, and of
    /// `removeRow` for a single row (an inactive or stale constraint would
    /// otherwise animate 0 → 0 and the rows would snap shut). The shrunk size is
    /// published in the same turn: `animator().constant = 0` sets the model value
    /// immediately, so the re-fit measures where the content is GOING and the
    /// surface travels with it rather than after it.
    private func collapseSubsection(_ body: SubsectionBody, animated: Bool) {
        let clip = body.clip
        clip.isClosing = true
        // Tear down only the rows THIS collapse hid: a re-expand inside the
        // animation's own duration refills the stack, and that expand's rows
        // must survive this (now superseded) completion.
        let doomed = body.stack.arrangedSubviews
        let teardown = {
            for row in doomed where row.superview === body.stack {
                body.stack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
        }
        guard animated else {
            teardown()
            clip.heightConstraint.constant = 0
            clip.heightConstraint.isActive = true
            panelContentDidChangeHeight(animated: false)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.collapseRevealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            clip.heightConstraint.constant = clip.frame.height
            clip.heightConstraint.isActive = true
            self.stackView.layoutSubtreeIfNeeded()
            clip.heightConstraint.animator().constant = 0
            self.panelContentDidChangeHeight(animated: true)
        }, completionHandler: teardown)
    }

    /// Unfold a subsection: build its rows so the clip has a natural height,
    /// measure the grown panel, THEN hand the collapsed start state back and lay
    /// it out before animating — the measure settles every row below at its final
    /// position, so without that second layout pass the reveal starts already
    /// arrived (`insertRow`'s documented trap, same fix).
    private func expandSubsection(_ body: SubsectionBody, animated: Bool,
                                  buildRows: () -> Void) {
        let clip = body.clip
        // A collapse whose deferred teardown has not run yet leaves its rows in
        // the stack; they are already out of the host's model, so this expand
        // owns the stack and starts it empty.
        for row in body.stack.arrangedSubviews {
            body.stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        clip.isClosing = false
        currentSubsectionStack = body.stack
        buildRows()
        currentSubsectionStack = nil
        // Natural height governs while the rows are measured.
        clip.heightConstraint.isActive = false
        let target = fittingSizeSettled()
        let revealHeight = clip.frame.height
        guard animated else {
            publishContentSize(target, animated: false)
            return
        }
        clip.heightConstraint.constant = 0
        clip.heightConstraint.isActive = true
        _ = fittingSizeSettled()   // commit the START state; the reveal needs the distance
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.collapseRevealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            clip.heightConstraint.animator().constant = revealHeight
            self.stackView.layoutSubtreeIfNeeded()
            self.publishContentSize(target, animated: true)
        }, completionHandler: {
            // Let the rows flex with their own content again once they have
            // arrived — unless a collapse has since begun on this clip, whose
            // height constraint deactivating here would pop the section back open.
            if !clip.isClosing { clip.heightConstraint.isActive = false }
        })
    }

    /// Assign the disclosure chevron image for a collapse state (GroupRowView
    /// precedent: `chevron.down` expanded / `chevron.right` collapsed),
    /// template-tinted, and record the symbol name for the flip test hook.
    private func assignChevron(_ chevron: NSButton, collapsed: Bool, for header: String) {
        let name = collapsed ? "chevron.right" : "chevron.down"
        let image = NSImage(systemSymbolName: name,
                            accessibilityDescription: collapsed ? "Expand" : "Collapse")
        image?.isTemplate = true
        chevron.image = image
        chevronSymbolByHeader[header] = name
    }

    /// Insert `view` as a row directly UNDER `sibling` (a row already mounted in
    /// one of the cards) — the inline diagnosis panel expanding under a failed
    /// device row (connection-status brief §7.2), and the BT sync drawer. The row
    /// is mounted inside its own `RowClipView`, and `animated` unfolds it
    /// DOWNWARD out of `sibling` by animating that clip's height 0 → natural —
    /// the same clip-height choreography `CardView.setBodyCollapsed` uses for a
    /// whole card's body, and what makes the panel's height an interpolated
    /// quantity the popover's own resize can lead (see `RowClipView`). No-op if
    /// `sibling` isn't currently mounted (i.e. its own superview isn't a stack).
    ///
    /// **Trap (found live, 2026-07-19 — C1):** this used to search
    /// `card.contentStack.arrangedSubviews` for `sibling`, but a device row (or
    /// any other *body* row) never lives directly in `contentStack` — `addRow`
    /// routes it through `CardView.addBodyRow` into `bodyStack`, itself nested
    /// inside `bodyClip`, which is the only thing `contentStack` actually holds
    /// (`CardView.swift`). That lookup could never match a device row, so the
    /// diagnosis panel silently never attached — the dead-feature bug. Insert
    /// into `sibling.superview` itself (whichever stack that really is —
    /// `contentStack` for a header row, `bodyStack` for a body row) instead of
    /// assuming a fixed stack, so the row always lands where its sibling
    /// actually lives.
    func insertRow(_ view: NSView, after sibling: NSView, animated: Bool) {
        // The single reused drawer (D2) can arrive still mounted in a CLOSING
        // clip — `removeRow` defers its detach into the collapse's completion
        // handler. Evict both NOW (before `sibling`'s index is read: the stale
        // clip may sit ABOVE it in the same stack, and removing it shifts every
        // index after it): left in place, the stale clip would sit in its old
        // stack at its mid-close height while `fittingSizeSettled` below
        // measures the panel (a residue nothing ever re-publishes away), and
        // its deferred detach would later find the row still its child and rip
        // it back out of THIS mount. Emptied and un-stacked, that closure's
        // guards make it a no-op instead.
        if let staleClip = view.superview as? RowClipView {
            view.removeFromSuperview()
            (staleClip.superview as? NSStackView)?.removeArrangedSubview(staleClip)
            staleClip.removeFromSuperview()
        }
        guard let stack = sibling.superview as? NSStackView,
              let index = stack.arrangedSubviews.firstIndex(of: sibling)
        else { return }
        let clip = RowClipView(row: view)
        stack.insertArrangedSubview(clip, at: index + 1)
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        // The mounted row's END state is VISIBLE, and that has to be TRUE
        // before the measurement below rather than a consequence of the
        // animation that follows it (live bug, 2026-08-08 — the sync drawer
        // "opens from the top of the screen after the first time"). An
        // `NSStackView` gives a hidden arranged subview zero height, so
        // measuring a row that arrives hidden publishes a size that leaves the
        // row out entirely: the popover is told "no change", the content then
        // grows underneath it, and the panel only catches up on some LATER
        // unrelated re-fit — one disconnected lurch instead of the row opening.
        // The BT sync drawer is a SINGLE reused instance (`PopoverController`,
        // D2), so whatever state a previous mount left on it arrives here.
        view.isHidden = false

        // The size the panel is GROWING TO, measured here (not at the call site —
        // found live 2026-08-06): mounting a row changes the panel's height, and
        // every caller that forgot to republish left the popover sized for the old
        // content. Auto Layout then has to reconcile a container whose height
        // disagrees with its content, and the slack lands wherever nothing pins it
        // — in practice the pinned banner, which balloons into a tall empty box.
        // Measured with the clip at its NATURAL height, so this is both the
        // panel's final height and (via the clip's frame) the reveal's target.
        let target = fittingSizeSettled()
        let revealHeight = clip.frame.height

        // Same Reduce Motion gate `setCardCollapsed` already applies (PLAN §E
        // risk 1 / house rule — "Respect system settings: Reduce Motion"):
        // re-derive `wantsAnimation` here rather than trusting the caller's
        // `animated` alone, since both call sites always pass `animated: true`.
        // Reduce Motion therefore leaves the row already mounted and VISIBLE
        // (the `isHidden = false` above), at its published size — the end state,
        // instantly.
        guard animated && !reduceMotion else {
            publishContentSize(target, animated: false)
            revealInScrollableArea(clip)
            return
        }

        // Collapse the clip AND LAY THAT OUT — an animation cannot travel a
        // distance the layout has already covered (live report, 2026-08-08:
        // "collapsing smooth, expanding abrupt"). The measurement above settled
        // every row below at its FINAL position; without this commit the reveal
        // would start already arrived. `fittingSizeSettled` both runs the layout
        // pass and returns the height it settles on, which is where the reveal
        // starts.
        clip.heightConstraint.constant = 0
        clip.heightConstraint.isActive = true
        test_rowRevealStartHeight = fittingSizeSettled().height

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.collapseRevealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            clip.heightConstraint.animator().constant = revealHeight
            self.stackView.layoutSubtreeIfNeeded()
            // Grow the SURFACE in the same turn, to the height measured above,
            // so the window's frame animation and the clip's height constraint
            // travel together at the same pace. That's the SAFE direction of
            // the surplus shield: a surface briefly taller than its content
            // shows inert canvas, where a surface shorter than its content is
            // the unsatisfiable case that deforms it.
            self.publishContentSize(target, animated: true)
        }, completionHandler: { [weak self] in
            // Let the row flex with its own content again once it has arrived
            // (a mounted drawer/panel can re-lay itself out while open) —
            // unless a close has since begun on this clip: deactivating the
            // very constraint the close is animating would pop the row back
            // open mid-collapse.
            if !clip.isClosing { clip.heightConstraint.isActive = false }
            // Only once the row has its real height is there anything to bring
            // into view; while the panel is uncapped this is a no-op.
            self?.revealInScrollableArea(clip)
        })
    }

    /// Remove a row previously mounted with `insertRow(_:after:animated:)` (or
    /// `addRow`). Animated removal collapses the row first (same animation group
    /// as the insert), then detaches it in the completion handler; un-animated
    /// removal detaches immediately.
    func removeRow(_ view: NSView, animated: Bool) {
        guard let clip = view.superview as? RowClipView,
              let stack = clip.superview as? NSStackView else {
            view.removeFromSuperview()
            panelContentDidChangeHeight(animated: animated)
            return
        }
        // The detach is DEFERRED into the animation's completion handler, so the
        // row is still in the tree while the clip closes — which is exactly why
        // the re-fit has to live in here too (found live 2026-08-06). Measuring at
        // the call site sized the popover for a row that was about to leave, and
        // nothing ever measured again once it did: the popover stayed permanently
        // taller than its content, one row's worth per removal. See `insertRow`.
        let detach = { [weak self] in
            // The clip may have LEFT this stack while the collapse ran (a
            // re-mount's eviction in `insertRow`, or the whole card torn down
            // by a rebuild), and the ROW may have left the clip (`rebuild()`'s
            // explicit drawer detach) — `removeArrangedSubview` against a stack
            // the view no longer belongs to raises, and touching `view` once it
            // is someone else's child would rip it out of its new mount.
            // Whoever moved either of them already owns the height.
            guard clip.superview === stack, view.superview === clip else { return }
            // Hand the row back detached and un-hidden — it is reusable, and the
            // clip is not (a fresh mount builds its own).
            view.removeFromSuperview()
            stack.removeArrangedSubview(clip)
            clip.removeFromSuperview()
            self?.panelContentDidChangeHeight(animated: false)
        }
        // Same Reduce Motion gate as `insertRow` above (and `setCardCollapsed`).
        guard animated && !reduceMotion else { detach(); return }
        // Marks the clip for `insertRow`'s completion handler: a reveal that
        // finishes after this close began must not deactivate the constraint
        // the close is animating.
        clip.isClosing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.collapseRevealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            // Seed the clip with its CURRENT height before retargeting to 0, and
            // lay that seed out — an inactive (or stale) constraint would
            // otherwise animate 0 → 0 and the row would snap shut (`CardView`'s
            // first-collapse trap, same fix).
            clip.heightConstraint.constant = clip.frame.height
            clip.heightConstraint.isActive = true
            self.stackView.layoutSubtreeIfNeeded()
            clip.heightConstraint.animator().constant = 0
            // Re-fit in the same turn; the clip has not shrunk yet, so this
            // republishes the CURRENT height. The `detach` above publishes the
            // shrunk end state once the row is actually gone — the surface
            // trails a shrink.
            self.panelContentDidChangeHeight(animated: true)
        }, completionHandler: detach)
    }

    /// A small uppercase secondary column-header label (VOLUME / DEVICE / ENABLED),
    /// centered over its column in the combined header row built by `beginCard`.
    private static func makeColumnHeaderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Tokens.Font.captionMedium
        label.textColor = Tokens.Color.secondaryLabel
        label.alignment = .center
        return label
    }

    /// Add a small subsection header ("Current Device" / "AirPlay Devices")
    /// INSIDE the current card (SPEC §9b split). Tertiary label color (V10,
    /// 2026-07-18): a grouping label sits one step below the uppercase column
    /// headers (`makeColumnHeaderLabel`, still secondary), so it reads as a
    /// quieter sub-level in the hierarchy rather than competing with them.
    /// `columnTitle`/`columnCenterFromTrailing` optionally add ONE extra
    /// uppercase column-header label on the same line, centered over a column
    /// only this subsection's rows carry — the Bluetooth subsection's "SYNC"
    /// title over its stepper cluster (BT-OFFSET-UI). Same
    /// `makeColumnHeaderLabel` voice as the card header's VOLUME/FEED titles.
    ///
    /// `collapsible` reuses the card header's own affordance verbatim — the
    /// leading `chevron.right`/`chevron.down` button, the whole-row click
    /// recognizer (C4), and the same `chevronsByHeader`/
    /// `headerClickRecognizersByHeader` registries, keyed by the SUBSECTION
    /// title.
    ///
    /// The header is followed by the subsection's own BODY CLIP (`RowClipView`),
    /// which every row added until the next `addSubsectionHeader`/`endSubsection`
    /// goes into — the height a collapse animates (`setSubsectionCollapsed`). The
    /// clip is built even when `collapsed` (empty, pinned to 0), so a later
    /// expand has a clip to fill and travel.
    func addSubsectionHeader(_ title: String,
                             columnTitle: String? = nil,
                             columnCenterFromTrailing: CGFloat = 0,
                             collapsible: Bool = false,
                             collapsed: Bool = false,
                             onToggle: (() -> Void)? = nil) {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Tokens.Font.captionMedium
        label.textColor = Tokens.Color.tertiaryLabel
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        // Align to the icon column (Warm Signal v4 §Call-1) — out of the rail
        // gutter, directly above the device icons. A collapsible subsection puts
        // its chevron on that anchor and the title follows, exactly like a card
        // header.
        let leadingInset = PopoverColumnGrid.firstElementLeading(indented: false)
        var titleLeadingAnchor = wrapper.leadingAnchor
        var titleLeadingConstant = leadingInset
        if collapsible {
            let chevron = NSButton()
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.bezelStyle = .accessoryBar
            chevron.isBordered = false
            chevron.imagePosition = .imageOnly
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.contentTintColor = Tokens.Color.tertiaryLabel
            chevron.setAccessibilityLabel(collapsed ? "Expand \(title)" : "Collapse \(title)")
            let onChevron = ClosureActionTarget { onToggle?() }
            chevron.target = onChevron
            chevron.action = #selector(ClosureActionTarget.fire)
            objc_setAssociatedObject(chevron, &Self.actionTargetKey, onChevron, .OBJC_ASSOCIATION_RETAIN)
            wrapper.addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor,
                                                 constant: leadingInset),
                chevron.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 16),
            ])
            titleLeadingAnchor = chevron.trailingAnchor
            titleLeadingConstant = 4
            chevronsByHeader[title] = chevron
            assignChevron(chevron, collapsed: collapsed, for: title)

            let onHeaderClick = ClosureActionTarget { onToggle?() }
            let headerClick = NSClickGestureRecognizer(target: onHeaderClick,
                                                        action: #selector(ClosureActionTarget.fire))
            wrapper.addGestureRecognizer(headerClick)
            objc_setAssociatedObject(wrapper, &Self.actionTargetKey, onHeaderClick,
                                     .OBJC_ASSOCIATION_RETAIN)
            headerClickRecognizersByHeader[title] = headerClick
        }
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: titleLeadingAnchor,
                                           constant: titleLeadingConstant),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2),
        ])
        if let columnTitle {
            let columnLabel = Self.makeColumnHeaderLabel(columnTitle)
            wrapper.addSubview(columnLabel)
            NSLayoutConstraint.activate([
                columnLabel.centerXAnchor.constraint(
                    equalTo: wrapper.trailingAnchor,
                    constant: -columnCenterFromTrailing),
                columnLabel.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2),
            ])
        }
        // The header itself is a CARD-body row (it stays visible when the
        // subsection collapses), so close any previous subsection first.
        currentSubsectionStack = nil
        addRow(wrapper)
        currentSubsectionStack = mountSubsectionBody(title, collapsed: collapsed)
    }

    /// Build a subsection's body clip + row stack and mount it under the header
    /// just added. The stack is the clip's single "row" — pinned top, bottom at
    /// `.defaultHigh` (`RowClipView`), so an active height-0 constraint wins
    /// without deforming the rows: they hold their place at the top and are
    /// revealed downward as the height grows.
    private func mountSubsectionBody(_ title: String, collapsed: Bool) -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        let clip = RowClipView(row: stack)
        subsectionBodies[title] = SubsectionBody(clip: clip, stack: stack)
        if collapsed {
            // The collapsed END STATE, applied synchronously — the host builds no
            // rows for a collapsed subsection, so this clip stays empty until an
            // expand fills it.
            clip.isClosing = true
            clip.heightConstraint.constant = 0
            clip.heightConstraint.isActive = true
        }
        addRow(clip)
        return stack
    }

    /// Render a small single-line annotation row INSIDE the current card — e.g.
    /// the Devices card's "Inactive — Audio Out is using '<group>'" dormancy
    /// annotation (A1; the host supplies `text`). Mounted with `card.addRow`, a
    /// HEADER row, NOT `addRow`'s collapsible body — so the note stays visible
    /// even when the card's body collapses. No-op if there's no current card.
    func addCardNote(_ text: String) {
        guard let card = currentCard else { return }
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        // `Tokens.Font.caption` IS `systemFont(ofSize: NSFont.smallSystemFontSize)`
        // = the 11pt this line hardcoded — a rename, not a restyle.
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.tertiaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: 18),
            // Align to the icon column (Warm Signal v4 §Call-1) — clear of the rail gutter.
            label.leadingAnchor.constraint(
                equalTo: wrapper.leadingAnchor,
                constant: PopoverColumnGrid.firstElementLeading(indented: false)),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor,
                                            constant: -PopoverColumnGrid.leadingInset),
            label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        card.addRow(wrapper)
        if let header = cardsByHeader.first(where: { $0.value === card })?.key {
            notesByHeader[header, default: []].append(label)
        }
    }

    // MARK: Silence-fallback banner (Wave 2 W2-T2, R11)

    private weak var bannerLabel: NSTextField?

    /// Show (or, with `nil`, clear) a full-width warning banner PINNED above every
    /// card — used by the generalized silence watchdog to say "Speakers unreachable
    /// — playing on this Mac. Will resume automatically." A stock system-orange
    /// rounded inset card with a warning glyph and a wrapping label; system colors
    /// only, no custom drawing. `clearRows()` drops it along with the cards, so the
    /// host re-applies it at the tail of every `rebuild()`.
    func setBanner(_ text: String?) {
        if let existing = stackView.arrangedSubviews.first(where: { $0 is SilenceFallbackBannerView }) {
            stackView.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }
        bannerLabel = nil
        guard let text else { return }
        let banner = SilenceFallbackBannerView(
            text: text,
            maxTextWidth: panelWidth - 28 - 30)
        bannerLabel = banner.label
        stackView.insertArrangedSubview(banner, at: 0)
        NSLayoutConstraint.activate([
            // Flush to the stack edges, matching the cards (Warm Signal dropped
            // the old `cardMargin` side inset; a banner must not float inside it).
            banner.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
        ])
    }

    /// Test-only: the banner's copy, or `nil` when no banner is shown.
    var test_bannerText: String? { bannerLabel?.stringValue }

    // MARK: System-AirPlay guard note (Wave 3 W3-T3)

    private weak var systemAirPlayNoteLabel: NSTextField?

    /// Show (or, with `nil`, clear) the "double-path audio" informational note,
    /// PINNED above every card alongside (never at the same time as — the two
    /// conditions are mutually exclusive, see `NativeBackend.reconcileCaptureGate`)
    /// the silence-fallback banner above. Mirrors `setBanner`'s shape exactly,
    /// keyed on `SystemAirPlayNoteBannerView` instead so the two banners never
    /// interfere with each other's add/remove. `clearRows()` drops it along with
    /// the cards, so the host re-applies it at the tail of every `rebuild()`.
    private weak var systemAirPlayNoteView: SystemAirPlayNoteBannerView?

    /// `action`, when non-nil, renders a trailing call-to-action button (T6,
    /// takeover status strip state 1 — "needs permission" deep-links to Login
    /// Items & Extensions). Every other note (the double-path guard, and
    /// takeover states 2-4) passes `nil` and gets the plain note this method
    /// has always rendered. `severity` (T-UI) selects the tint tier — `.info`
    /// (default) for the double-path guard and takeover strip, `.warning` for
    /// the routing-blocked-needs-default note.
    func setSystemAirPlayNote(_ text: String?,
                               action: SystemAirPlayNoteBannerView.Action? = nil,
                               severity: SystemAirPlayNoteBannerView.Severity = .info) {
        if let existing = stackView.arrangedSubviews.first(where: { $0 is SystemAirPlayNoteBannerView }) {
            stackView.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }
        systemAirPlayNoteLabel = nil
        systemAirPlayNoteView = nil
        guard let text else { return }
        let note = SystemAirPlayNoteBannerView(
            text: text,
            maxTextWidth: panelWidth - 28 - 30,
            action: action,
            severity: severity)
        systemAirPlayNoteLabel = note.label
        systemAirPlayNoteView = note
        stackView.insertArrangedSubview(note, at: 0)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
        ])
    }

    /// Test-only: the note's copy, or `nil` when no note is shown.
    var test_systemAirPlayNoteText: String? { systemAirPlayNoteLabel?.stringValue }
    /// Test-only: whether the currently-shown note has an action button.
    var test_systemAirPlayNoteHasActionButton: Bool { systemAirPlayNoteView?.test_hasActionButton ?? false }
    /// Test-only: simulate a click on the note's action button, if any.
    func test_tapSystemAirPlayNoteAction() { systemAirPlayNoteView?.test_tapActionButton() }

    /// Seat the card stack below the surface window's toolbar strip. The
    /// caller republishes the exact-fit size afterward; this only moves the
    /// pin — and re-derives the height cap, which is expressed against the
    /// SCROLLABLE region and so shrinks by whatever this inset takes.
    func setContentTopInset(_ inset: CGFloat) {
        _ = view // ensure loadView ran so the constraint exists
        contentTopConstraint?.constant = Self.contentRestingTopInset + inset
        updateContentHeightCap()
    }

    /// The content's current extra top inset, for structural tests.
    var test_contentTopInset: CGFloat {
        (contentTopConstraint?.constant ?? Self.contentRestingTopInset) - Self.contentRestingTopInset
    }

    // MARK: Test-support

    /// Number of section cards currently mounted (footer card removed).
    var test_cardCount: Int {
        stackView.arrangedSubviews.compactMap { $0 as? CardView }.count
    }

    /// The collapse-reactive rail geometry the overlay would draw from the CURRENT
    /// (settled) layout — settles layout first so the plan reflects final frames.
    /// `nil` if the origin anchor can't resolve. Used by the rail collapse tests.
    func test_railPlan() -> RailPlan? {
        view.layoutSubtreeIfNeeded()
        return railOverlay.test_resolvePlan()
    }

    // MARK: Collapsible-card test hooks (T-4)

    /// Whether the card with `title` is currently collapsed (body pinned to 0 /
    /// hidden). `nil` if there's no such card.
    func test_isCardCollapsed(title: String) -> Bool? {
        cardsByHeader[title]?.isBodyCollapsed
    }
    /// Toggle the card with `title` (drives the chevron/title click path). Returns
    /// the new collapsed state, or `nil` if `title` isn't a card.
    @discardableResult
    func test_toggleCard(title: String, animated: Bool = false) -> Bool? {
        toggleCard(title: title, animated: animated)
    }
    /// The card's laid-out body-clip height (0 when collapsed, else the body's
    /// fitting height). `nil` if there's no such card.
    func test_cardBodyClipHeight(title: String) -> CGFloat? {
        guard let card = cardsByHeader[title] else { return nil }
        view.layoutSubtreeIfNeeded()
        return card.bodyClipHeight
    }
    /// The card's expanded body height (its content's fitting height, independent
    /// of the current collapse state). `nil` if there's no such card.
    func test_cardBodyFittingHeight(title: String) -> CGFloat? {
        cardsByHeader[title]?.bodyFittingHeight
    }
    /// The chevron's current SF Symbol name for `title` (`chevron.down` expanded /
    /// `chevron.right` collapsed), for the flip assertion. `nil` if not collapsible.
    func test_cardChevronSymbolName(title: String) -> String? {
        chevronSymbolByHeader[title]
    }

    // MARK: Whole-header click test hooks (C4)

    /// Fire the whole-header-row collapse click for `title` exactly as a real
    /// click landing anywhere on the header row OTHER than a button (chevron or
    /// accessory) would — drives the `NSClickGestureRecognizer` added in
    /// `beginCard` via its own target/action. Returns whether `title` has a
    /// collapsible header (and so a recognizer) to fire.
    @discardableResult
    func test_fireHeaderClick(title: String) -> Bool {
        guard let recognizer = headerClickRecognizersByHeader[title],
              let action = recognizer.action,
              let target = recognizer.target as? NSObjectProtocol else { return false }
        target.perform(action)
        return true
    }

    // MARK: Header accessory test hooks (F1)

    /// Whether the header accessory button for `title` is currently enabled.
    /// `nil` if `title` has no accessory button.
    func test_accessoryEnabled(title: String) -> Bool? {
        accessoryButtonsByHeader[title]?.isEnabled
    }

    /// Fire the header accessory button's own action for `title`, the same way a
    /// real click on it would — proves an accessory click reaches ONLY the
    /// accessory's action, never the card's `onToggle` (C4 requirement (b)).
    /// Returns whether `title` has an accessory button to fire.
    @discardableResult
    func test_fireAccessoryAction(title: String) -> Bool {
        guard let button = accessoryButtonsByHeader[title],
              let action = button.action,
              let target = button.target as? NSObjectProtocol else { return false }
        target.perform(action)
        return true
    }

    // MARK: Card-note test hooks (A1)

    /// The note labels added via `addCardNote` for `title`, in add order. Empty
    /// if none were added or `title` isn't a card.
    func test_cardNotes(title: String) -> [NSTextField] {
        notesByHeader[title] ?? []
    }

    /// The body rows of card `title` in display order. Empty if `title` isn't a
    /// card — the assertion surface for a row's POSITION within its card.
    func test_cardRows(title: String) -> [NSView] {
        cardsByHeader[title]?.test_bodyRows ?? []
    }

    // MARK: Height-overflow test hooks

    /// The budget a host has pushed (`nil` = uncapped, the headless default).
    var test_maxContentHeight: CGFloat? { maxContentHeight }
    /// Whether the vertical scroller is currently mounted — the "conditionally
    /// active" half of the rule. `false` whenever the content fits.
    var test_hasVerticalScroller: Bool { contentScrollView.hasVerticalScroller }
    /// The card stack's NATURAL height, ignoring any cap — what the panel would
    /// have published before this rule existed.
    var test_documentNaturalHeight: CGFloat {
        view.layoutSubtreeIfNeeded()
        return scrollDocument.fittingSize.height
    }
    /// The clip's current scroll offset (0 = top; the document is flipped).
    var test_scrollOffsetY: CGFloat { contentScrollView.contentView.bounds.origin.y }
    /// Drive a scroll exactly as a trackpad would, so a test can prove the reset
    /// actually moves something. Interactive scrolling runs through
    /// `NSClipView.constrainBoundsRect` — a bare programmatic `scroll(to:)` does
    /// NOT, so this hook constrains explicitly or a fitting panel would happily
    /// hold an out-of-range offset no flick could ever produce.
    func test_scrollContent(toY y: CGFloat) {
        let clip = contentScrollView.contentView
        view.layoutSubtreeIfNeeded()
        var target = clip.bounds
        target.origin.y = y
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        contentScrollView.reflectScrolledClipView(clip)
    }
}

/// The scroll view's document view. Flipped so a document SHORTER than its clip
/// (every transient moment during a resize) hangs from the TOP rather than the
/// bottom, and so "scrolled to the top" is simply `bounds.origin == .zero`.
/// Flipping the document does NOT flip the card stack or the rail overlay — both
/// keep their own coordinate systems, and every rail measurement already goes
/// through `convert(_:from:)`, which is flip-aware.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// The card stack (Warm Signal v4 §Call-1), which also repaints the continuous
/// rail overlay on every layout pass so the spine always reflects the current row
/// frames (collapse / expand / resize) with no cached geometry. The overlay draws
/// from settled frames, so `cacheDisplay` snapshots stay deterministic.
///
/// **Why the STACK and not the container** (live bug, 2026-08-06): this hook used
/// to live on the panel's top-level container (`RailHostView`), whose `layout()`
/// runs only when the CONTAINER's own frame changes — not when its descendants
/// re-lay out inside a container of unchanged size. That is exactly the state a
/// too-tall popover produces: the container's frame is constant while the banner
/// swells and every card below it slides. Nothing re-invalidated the overlay, so
/// it composited its last painted figure — hook, spine and arcs together — over
/// rows that had since moved, displacing the whole rail by the surplus. The stack
/// re-lays out in BOTH cases (its frame is pinned to the container's four edges,
/// so a container resize moves it too), which is why the container hook is gone
/// rather than doubled up.
///
/// Do NOT move this to an ancestor's `viewWillDraw()`: an ancestor is drawn on
/// every display pass, so dirtying a subview from there schedules another pass
/// forever. Dirtying from `layout()` cannot loop — `needsDisplay` does not
/// invalidate layout.
final class RailStackView: NSStackView {
    weak var railOverlay: BusRailOverlayView?
    override func layout() {
        super.layout()
        railOverlay?.needsDisplay = true
    }
}

/// A tiny reference target that forwards a target/action click (a chevron button
/// tap, the whole-header-row click gesture, or an accessory button tap) to a
/// stored closure — the disclosure toggle or the accessory's own handler.
/// Retained via an associated object on its owning control so it lives as long
/// as the control (T-4; the closure captures the controller's `onToggle`).
private final class ClosureActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// A 1px section-divider hairline (spec §5.1: "separated by 1px hairline
/// dividers") — the ONLY visual separation between de-nested cards now that
/// they no longer draw their own material/shadow/rim (`CardView`). Purely
/// decorative and non-interactive; `beginCard` inserts one into `stackView`
/// before every card after the first.
private final class HairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Tokens.Color.hairline.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Tokens.Color.hairline.cgColor
    }
}

/// The clipping host one `insertRow` row unfolds inside — `CardView`'s
/// collapsible body, per row.
///
/// The row is pinned to the clip's TOP strongly and to its bottom only at
/// `.defaultHigh`, so an active height-0 constraint overrides the bottom pin
/// instead of squeezing the row: the row holds its place at the top and is
/// revealed downward from under the sibling above it as the clip's height
/// grows, pushing every row below it down by the same amount. That height is
/// the ONE animated dimension, and it is what makes the panel's height a
/// genuinely interpolated quantity — the popover, told its final size up front,
/// then leads the content the whole way rather than being asked to hold content
/// it has not grown to yet.
final class RowClipView: NSView {
    /// The animated height. Active only while a reveal/collapse is in flight or
    /// pinned at 0; inactive once expanded, so the row flexes with its content.
    private(set) var heightConstraint: NSLayoutConstraint!

    /// Set the moment an animated close begins (`removeRow`, or a subsection's
    /// `collapseSubsection`), so a still-pending reveal completion knows not to
    /// deactivate `heightConstraint` out from under the close. A row's clip never
    /// clears it — every mount builds a new one — but a SUBSECTION's clip
    /// outlives its rows and is reset by the next expand.
    var isClosing = false

    init(row: NSView) {
        super.init(frame: .zero)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true      // mask the part of the row not yet revealed
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let bottomPin = row.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomPin.priority = .defaultHigh
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomPin,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
