// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerSharedUI

/// The scrollable **Control-Center-style** panel hosted inside the popover's
/// `contentViewController` (SPEC §9 revised, restyled 2026-07-14 — T-U8). Each
/// section ("System / Main Out", "Selected Devices", "Groups") is a rounded-rect
/// **card module**: a translucent `NSVisualEffectView` (material `.menu`,
/// `.withinWindow`, corner radius 11, continuous curve) inset from the popover
/// edges, sitting on the popover's vibrant material with a small uppercase
/// tertiary header ABOVE it, exactly like a macOS Control Center component. Rows
/// live INSIDE the card, which clips to its rounded corners.
///
/// It is a dumb container: `PopoverController` composes the sections and hands in
/// the rows; this controller lays them out and sizes the popover. The outer
/// vertical `stackView` holds the cards (plus the footer card); animating a
/// member row's `isHidden` inside a card animates that card's height, and
/// `stackView.layoutSubtreeIfNeeded()` cascades through — so the group
/// expand/collapse animation still works unchanged.
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

    /// Popover width — widened to ~SoundSource proportions (2026-07-14) so device
    /// names fit in full and the columns (name · Volume · Device) read like
    /// SoundSource. At 690 the flexible name column gets ~330pt even with the
    /// reserved Volume + Device columns — "MacBook Pro Speakers" etc. fit without
    /// truncation. (Footer removed; actions moved to the header + Groups "+".)
    private let panelWidth: CGFloat = 690
    private let maxScrollHeight: CGFloat = 520
    /// Side inset of a card from the popover edge (Control Center–style).
    static let cardMargin: CGFloat = 12

    /// The `<= maxScrollHeight` cap constraint, held so the offscreen snapshot
    /// tool can lift it to capture the full (unscrolled) panel. Runtime behavior
    /// is unchanged.
    private var scrollHeightCap: NSLayoutConstraint?

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

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

        // Cap the scroll height so a huge fleet scrolls instead of a giant popover.
        let cap = scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: maxScrollHeight)
        scrollHeightCap = cap

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: panelWidth),

            // Header bar pinned to the very top (task A), above the System card.
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cap,

            // Footer removed 2026-07-14 → the scroll area runs to the bottom.
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // Size the scroll view to its content height. Without this the scroll
        // view is under-constrained (only bounded above by the cap) and Auto
        // Layout collapses it to ~0, hiding every card while the footer still
        // shows (the empty-popover bug). Priority 999 < the required
        // `<= maxScrollHeight` cap, so content drives the height until it exceeds
        // the cap, then the cap wins and the fleet scrolls. (T-U8: MUST NOT regress.)
        let fitContent = scrollView.heightAnchor.constraint(equalTo: documentView.heightAnchor)
        fitContent.priority = NSLayoutConstraint.Priority(999)
        fitContent.isActive = true
        scrollView.setContentHuggingPriority(.defaultHigh, for: .vertical)

        view = container
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

    /// Start a new section **card** with a prominent Control Center–style header
    /// at the module's top-left, INSIDE the tile (label color, medium weight, ~14pt
    /// — like "Sound" / "Display" in CC, not tiny grey uppercase). Subsequent
    /// `addRow` / `addSubsectionHeader` calls fill this card until the next
    /// `beginCard`.
    ///
    /// `trailingAccessory` optionally mounts a borderless icon button on the RIGHT
    /// of the module header (task D — the Groups section's "+" / New group). The
    /// button's `accessibilityLabel`/`toolTip` are set from `accessory.label`.
    func beginCard(header: String, trailingAccessory accessory: HeaderAccessory? = nil) {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        // The prominent module header is the FIRST element inside the tile.
        let label = NSTextField(labelWithString: header)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        let headerWrap = NSView()
        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        headerWrap.addSubview(label)
        NSLayoutConstraint.activate([
            headerWrap.heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: headerWrap.leadingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: headerWrap.topAnchor, constant: 6),
        ])

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

    /// Add a non-interactive column header row ("Volume" / "Enabled"), aligned to
    /// the shared `PopoverColumnGrid`, into the current card. Passing `nil` for a
    /// title omits that label.
    func addColumnHeader(volumeTitle: String? = "Volume", enabledTitle: String? = "Enabled") {
        addRow(ColumnHeaderRow(volumeTitle: volumeTitle, enabledTitle: enabledTitle))
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

    /// Lift the scroll-height cap so the offscreen snapshot tool can render the
    /// full, unscrolled panel (all sections visible at once). No effect on the
    /// live popover, which never calls this.
    func test_liftScrollHeightCap() {
        scrollHeightCap?.constant = 100_000
        view.layoutSubtreeIfNeeded()
    }

    /// Whether the header exposes a Quit button image (the footer Quit moved to
    /// the header, 2026-07-14).
    var test_headerHasQuit: Bool { header.test_quitButtonHasImage }
    /// Number of section cards currently mounted (footer card removed).
    var test_cardCount: Int {
        stackView.arrangedSubviews.compactMap { $0 as? CardView }.count
    }
}
