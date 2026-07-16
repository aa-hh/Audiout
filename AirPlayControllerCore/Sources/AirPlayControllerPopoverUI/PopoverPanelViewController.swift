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
/// vertical `stackView` holds the cards. The `NSScrollView` is retained (harmless)
/// but the scroll area is pinned to its content height (2026-07-16) — the popover
/// always grows to fit the full content, so it never actually scrolls.
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
    private let scrollView = NSScrollView()

    /// The card currently being filled by `addRow` / `addSubsectionHeader`.
    private var currentCard: CardView?

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

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        container.addSubview(header)
        container.addSubview(scrollView)

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

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // Footer removed 2026-07-14 → the scroll area runs to the bottom.
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // Pin the scroll view to its content height (2026-07-16 — the scroll-height
        // cap was removed). REQUIRED so the scroll area always equals its content:
        // the popover then grows to fit the full content and never scrolls. Without
        // this the scroll view is under-constrained and Auto Layout collapses it to
        // ~0, hiding every card (the empty-popover bug). (T-U8: MUST NOT regress.)
        let fitContent = scrollView.heightAnchor.constraint(equalTo: documentView.heightAnchor)
        fitContent.isActive = true
        scrollView.setContentHuggingPriority(.defaultHigh, for: .vertical)

        view = container
    }

    /// Scroll the document view to the top so the System card is flush with the
    /// top edge. With the fit-height constraint there's no scroll range, but this
    /// is a belt-and-suspenders reset called right after the popover shows.
    func scrollToTop() {
        _ = view   // ensure `loadView` ran
        guard let documentView = scrollView.documentView else { return }
        // In a flipped document (default), the top is y == 0; in an unflipped one
        // it's the max-y edge. Scroll to whichever represents the top so the first
        // card ends up visible.
        let topY = documentView.isFlipped ? 0 : max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: topY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Rows API (called by PopoverController)

    /// Remove every card (used before a rebuild).
    func clearRows() {
        for v in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        currentCard = nil
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
    func beginCard(header: String,
                   volumeTitle: String? = nil,
                   trailingTitle: String? = nil,
                   trailingAccessory accessory: HeaderAccessory? = nil) {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

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
        headerWrap.addSubview(label)
        NSLayoutConstraint.activate([
            headerWrap.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: headerWrap.leadingAnchor,
                                            constant: PopoverColumnGrid.leadingInset),
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
    }

    /// Add a content row (Main Out row, group header, device row) into the
    /// current card, full card width.
    func addRow(_ view: NSView) {
        guard let card = currentCard else { return }
        card.addRow(view)
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
}
