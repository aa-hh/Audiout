// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The approved custom-drawn element of the Groups window (`../../AGENTS.md`):
/// a large glyph with a Contacts-style hover scrim, SHARED by the device
/// detail pane and the group editor so the two headers stay pixel-identical
/// (design feedback 2026-07-18: "keep parity between the styling").
///
/// Hovering the well shows a translucent rounded-RECT scrim covering the
/// ENTIRE well (an earlier circular scrim left the glyph's corners uncovered —
/// live-test feedback) with a centered white "pencil" glyph; the scrim colour
/// is a fixed translucent black rather than switching per light/dark
/// appearance, because it sits ON the icon (not the window chrome) and a
/// white pencil reads clearly against it either way. Layer-backed properties,
/// not a `draw(_:)` override — the same idiom `StatusDotView` uses.
/// `setOverlayVisible(_:)` respects Reduce Motion (plain show/hide, no fade)
/// and doubles as the headless test/snapshot hook.
final class DeviceIconWellView: NSView {

    /// Square side length (approved: "~64pt"), one constant so the detail
    /// pane's and the editor's headers can never drift apart.
    static let size: CGFloat = 64

    private static let fadeDuration: TimeInterval = 0.12
    private static let scrimColor = NSColor(white: 0, alpha: 0.55)
    /// Rounded-rect radius for the full-coverage scrim (~app-tile curvature).
    private static let scrimCornerRadius: CGFloat = 14

    let iconImageView = NSImageView()
    private let overlayView = NSView()
    private let pencilImageView = NSImageView()

    /// Fired on a real click (mouse-down) anywhere in the well.
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown

        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.wantsLayer = true
        overlayView.layer?.cornerRadius = Self.scrimCornerRadius
        overlayView.layer?.backgroundColor = Self.scrimColor.cgColor
        overlayView.isHidden = true
        overlayView.alphaValue = 0

        let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        pencil?.isTemplate = true
        pencilImageView.translatesAutoresizingMaskIntoConstraints = false
        pencilImageView.image = pencil
        pencilImageView.contentTintColor = .white
        pencilImageView.imageScaling = .scaleProportionallyUpOrDown

        addSubview(iconImageView)
        addSubview(overlayView)
        overlayView.addSubview(pencilImageView)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconImageView.topAnchor.constraint(equalTo: topAnchor),
            iconImageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Full-bleed: the scrim covers the ENTIRE well, corners included.
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

            pencilImageView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            pencilImageView.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            pencilImageView.widthAnchor.constraint(equalToConstant: Self.size * 0.36),
            pencilImageView.heightAnchor.constraint(equalToConstant: Self.size * 0.36),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Edit icon")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setOverlayVisible(true) }
    override func mouseExited(with event: NSEvent) { setOverlayVisible(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }

    /// Show/hide the scrim. Respects Reduce Motion (`../AGENTS.md`'s system-
    /// settings rule): a plain, instant show/hide with Reduce Motion on, a
    /// brief cross-fade otherwise. This is the one place hover state changes,
    /// so it doubles as the headless test hook.
    func setOverlayVisible(_ visible: Bool) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            overlayView.alphaValue = visible ? 1 : 0
            overlayView.isHidden = !visible
            return
        }
        overlayView.isHidden = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            overlayView.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            if !visible { self?.overlayView.isHidden = true }
        })
    }
}
