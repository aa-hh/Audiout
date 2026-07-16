// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerSharedUI

/// The **Control-Center-style** panel hosted inside the popover's
/// `contentViewController` (SPEC §9 revised, restyled 2026-07-14 — T-U8). Each
/// section ("System / Main Out", "Selected Devices") is a rounded-rect **card
/// module**: a translucent `NSVisualEffectView` (material `.menu`,
/// `.withinWindow`, corner radius 11, continuous curve) inset from the popover
/// edges, sitting on the popover's vibrant material with a small uppercase
/// tertiary header ABOVE it, exactly like a macOS Control Center component. Rows
/// live INSIDE the card, which clips to its rounded corners.
///
/// It is a dumb container: `PopoverController` composes the sections and hands in
/// the rows; this controller lays them out and sizes the popover. The outer
/// vertical `stackView` holds the cards.
///
/// **Exact-fit sizing (T-3, PLAN-POPOVER-ROUTING.md §A/§E risk 1, 2026-07-16):**
/// there is **no `NSScrollView`** — the stack is pinned directly inside the
/// container (header bottom → container bottom), so no scroller chrome can ever
/// appear. The popover is exactly the height of its visible content and
/// grows/shrinks as sections expand or collapse. The size flows out through
/// `preferredContentSize` (the DOCUMENTED `NSPopover` channel — it tracks
/// `contentViewController.preferredContentSize` and animates on its own when
/// `popover.animates` is true; see `panelContentDidChangeHeight`).
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
    }

    weak var controller: PopoverController?

    /// The vertical stack of section **cards** (and the footer card). Public to
    /// the module so the controller can animate `layoutSubtreeIfNeeded()` on it
    /// during a group's expand/collapse.
    let stackView = NSStackView()

    /// The card currently being filled by `addRow` / `addSubsectionHeader`.
    private var currentCard: CardView?

    // MARK: Collapsible-card bookkeeping (T-4)

    /// Cards keyed by their section title, so the controller (and tests) can
    /// toggle/inspect a card by title without holding a view reference.
    private var cardsByHeader: [String: CardView] = [:]
    /// Chevron buttons keyed by section title (for symbol flips + assertions).
    private var chevronsByHeader: [String: NSButton] = [:]
    /// The SF Symbol name currently assigned to each chevron (there's no public
    /// getter for an `NSImage`'s symbol name pre-macOS-14, so we track it for the
    /// chevron-flip test hook — set wherever the chevron image is assigned).
    private var chevronSymbolByHeader: [String: String] = [:]
    /// Initial collapse states recorded in `beginCard`, applied on the first body
    /// row (a header-only card has nothing to collapse until it has a body).
    private var pendingCollapsed: [String: Bool] = [:]

    /// The header bar pinned above the scroll area (task A). Now also hosts the
    /// **Quit** button (the footer was removed 2026-07-14).
    let header = PopoverHeaderView()

    /// Popover width — SoundSource-style proportions so the columns
    /// (name · Volume · Device) line up. Narrowed 2026-07-16 (change 5): the
    /// flexible name column was over-wide, so `panelWidth` drops from 690 to 623,
    /// cutting the name column's reserved width ~25% (≈269 → ≈202pt with the fixed
    /// left chrome + slider/readout/trailing columns). Longer device names may
    /// truncate more — accepted. (Footer removed; actions moved to the header +
    /// Groups "+".)
    private let panelWidth: CGFloat = 623
    /// Side inset of a card from the popover edge (Control Center–style).
    static let cardMargin: CGFloat = 12

    /// Associated-object key that keeps a chevron/title `ClosureActionTarget` alive
    /// for the lifetime of its button (target/action holds `target` weakly).
    private static var actionTargetKey: UInt8 = 0

    /// The popover's own BACKGROUND — distinct from the card tiles floating on
    /// top of it. `NSPopover` gives a vibrant frame "for free" only around
    /// `container`'s edges; historically `container` itself was a plain,
    /// materialless `NSView`, so the visible background behind/between cards
    /// was really just that free popover chrome. Alec asked (2026-07-16) for
    /// MORE translucency specifically here (not on the cards, which stay
    /// `.withinWindow` — see `CardView`): this is a real, `.behindWindow`
    /// `NSVisualEffectView` blending against the actual desktop behind the
    /// popover, filling `container` behind everything else.
    private let background = NSVisualEffectView()

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        background.translatesAutoresizingMaskIntoConstraints = false
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        container.addSubview(background)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        // Vertical gap BETWEEN modules (each module's header sits inside the tile).
        stackView.spacing = 12
        stackView.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        container.addSubview(header)
        container.addSubview(stackView)

        // The stack is pinned DIRECTLY inside the container — no `NSScrollView`, so
        // no scroller chrome can ever appear (T-3, PLAN-POPOVER-ROUTING.md §A: the
        // popover is exactly its content height and never scrolls). Pinning all four
        // edges (header bottom → container bottom) makes the container's height a
        // pure function of the stack's fitting height.
        //
        // EMPTY-POPOVER AUTO-LAYOUT TRAP (preserved from the pre-scroll design,
        // T-U8: MUST NOT regress): the stack MUST be pinned top AND bottom so its
        // intrinsic content height drives the container. Historically the scroll
        // area was under-constrained and Auto Layout collapsed it to ~0, hiding
        // every card. Here the same guarantee comes from the bottom pin below —
        // without `stackView.bottomAnchor == container.bottomAnchor` the stack
        // would be free to collapse to zero height and silently hide all cards.
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: panelWidth),

            // The background fills the whole container, behind everything else.
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Header bar pinned to the very top (task A), above the System card.
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // Stack pinned header-bottom → container-bottom, full width. The bottom
            // pin is the anti-collapse guarantee (see the note above).
            stackView.topAnchor.constraint(equalTo: header.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        view = container
    }

    // MARK: Exact-fit sizing (T-3)

    /// The single source of truth for the popover's target size: settle Auto Layout
    /// synchronously (`layoutSubtreeIfNeeded`), then read the container's
    /// `fittingSize`. Callers push this into `preferredContentSize` so the popover
    /// resizes to exactly the visible content (PLAN-POPOVER-ROUTING.md §E risk 1 —
    /// "layout settled synchronously before animating").
    func fittingSizeSettled() -> NSSize {
        _ = view   // ensure `loadView` ran
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
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
    /// `animated` selects the animation via `PopoverController.setPopoverAnimates`
    /// (the controller owns the `NSPopover`): it toggles `popover.animates` around
    /// the `preferredContentSize` assignment. The non-animated path is used for the
    /// initial show and when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
    /// is true (the jank escape hatch); it applies the size with `animates` forced
    /// off so no frame animation runs. Because `NSPopover` retargets a
    /// `preferredContentSize` change mid-flight against its own running animation,
    /// rapid expand/collapse toggles glide rather than fight (PLAN §E risk 1
    /// "retargetable rapid toggles"). T-4 animates a card's clip-height constraint
    /// alongside this so the panel and popover agree.
    func panelContentDidChangeHeight(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wantsAnimation = animated && !reduceMotion
        let target = fittingSizeSettled()
        // Assigning `preferredContentSize` is the sole size channel; NSPopover
        // animates iff `popover.animates` is true when the assignment happens.
        if let controller {
            controller.setPopoverAnimates(wantsAnimation) { [weak self] in
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
        cardsByHeader.removeAll()
        chevronsByHeader.removeAll()
        chevronSymbolByHeader.removeAll()
        pendingCollapsed.removeAll()
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
    /// **Collapsible cards (T-4, PLAN-POPOVER-ROUTING.md decision 5 + §E risk 1).**
    /// When `collapsible` is true the header row gains a leading disclosure chevron
    /// (`chevron.down` expanded / `chevron.right` collapsed, per `GroupRowView`'s
    /// precedent) placed LEFT of the section title, and BOTH the chevron and the
    /// title label become click targets that call `onToggle` (the rest of the
    /// header — column headers, accessory — stays inert). `collapsed` is the
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

        // The combined header row is the FIRST element inside the tile: section
        // title on the left, column headers centered over their columns on the
        // right. Height ~28pt (change 1 — one row instead of title + header).
        let label = NSTextField(labelWithString: header)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        let headerWrap = NSView()
        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        headerWrap.autoresizingMask = [.width]

        // Leading disclosure chevron (decision 5). Placed LEFT of the title; the
        // title's leading anchor shifts to sit after it. Follows GroupRowView's
        // symbol convention (chevron.down expanded / chevron.right collapsed).
        var titleLeadingAnchor = headerWrap.leadingAnchor
        var titleLeadingConstant = PopoverColumnGrid.leadingInset
        if collapsible {
            let chevron = NSButton()
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.bezelStyle = .accessoryBar
            chevron.isBordered = false
            chevron.imagePosition = .imageOnly
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.contentTintColor = .secondaryLabelColor
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
                                                 constant: PopoverColumnGrid.leadingInset),
                chevron.centerYAnchor.constraint(equalTo: headerWrap.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 16),
            ])
            titleLeadingAnchor = chevron.trailingAnchor
            titleLeadingConstant = 4

            // The title label is ALSO a click target (decision 5). A label isn't a
            // control, so a click-recognizer forwards its click to the same toggle.
            let click = NSClickGestureRecognizer(target: onChevron,
                                                 action: #selector(ClosureActionTarget.fire))
            label.addGestureRecognizer(click)
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
            let button = HoverActionButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .secondaryLabelColor
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
            button.onClick = accessory.action
            headerWrap.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: headerWrap.trailingAnchor,
                                                 constant: -Self.cardMargin),
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
        }

        card.addRow(headerWrap)

        // The card fills the panel width minus the side margins.
        stackView.addArrangedSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: Self.cardMargin),
            card.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -Self.cardMargin),
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
    func addRow(_ view: NSView) {
        guard let card = currentCard else { return }
        card.addBodyRow(view)
        applyPendingCollapseIfNeeded(card)
    }

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
    /// popover resize. Drives the card's clip-height animation and the popover's
    /// `preferredContentSize` change in lockstep at the same 0.2s pace so the panel
    /// and popover track (PLAN §E risk 1). `animated == false` (Reduce Motion or
    /// programmatic) applies both end states synchronously. Flips the chevron
    /// symbol to match. No-op if `title` isn't a collapsible card.
    ///
    /// The popover resize runs via `panelContentDidChangeHeight(animated:)`, which
    /// already gates itself on `accessibilityDisplayShouldReduceMotion`; the card
    /// animation is gated the same way here so both honor Reduce Motion together.
    @discardableResult
    func setCardCollapsed(title: String, collapsed: Bool, animated: Bool) -> Bool {
        guard let card = cardsByHeader[title] else { return false }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wantsAnimation = animated && !reduceMotion

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
        // Kick the popover resize in the SAME turn as the card animation so both
        // run together (NSPopover animates its `preferredContentSize` change at its
        // own pace; matching 0.2s keeps them in step — PLAN §E risk 1).
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

    /// A small uppercase secondary column-header label (VOLUME / DEVICE / ENABLED),
    /// centered over its column in the combined header row built by `beginCard`.
    private static func makeColumnHeaderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }

    /// Add a small subsection header ("Current Device" / "AirPlay Devices")
    /// INSIDE the current card (SPEC §9b split).
    func addSubsectionHeader(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2),
        ])
        addRow(wrapper)
    }

    /// Wire the header bar's three icon buttons (task A + the Quit button that
    /// replaced the removed footer, 2026-07-14).
    func setHeaderActions(onOpenGroupsEditor: @escaping () -> Void,
                          onOpenSettings: @escaping () -> Void,
                          onQuit: @escaping () -> Void) {
        header.onOpenGroupsEditor = onOpenGroupsEditor
        header.onOpenSettings = onOpenSettings
        header.onQuit = onQuit
    }

    // MARK: Test-support

    /// Whether the header exposes a Quit button image (the footer Quit moved to
    /// the header, 2026-07-14).
    var test_headerHasQuit: Bool { header.test_quitButtonHasImage }
    /// Number of section cards currently mounted (footer card removed).
    var test_cardCount: Int {
        stackView.arrangedSubviews.compactMap { $0 as? CardView }.count
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
}

/// A tiny reference target that forwards a target/action click (a chevron button
/// tap or a title-label click gesture) to a stored closure — the disclosure
/// toggle. Retained via an associated object on its owning control so it lives as
/// long as the control (T-4; the closure captures the controller's `onToggle`).
private final class ClosureActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
