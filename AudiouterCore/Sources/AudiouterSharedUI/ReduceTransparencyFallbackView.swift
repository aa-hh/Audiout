// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The Reduce Transparency stand-in for an `NSVisualEffectView` (A1,
/// PLAN-ONE-SURFACE-032): an opaque fill covering the blur while the
/// accessibility setting is on, hidden otherwise, re-resolved LIVE off
/// `accessibilityDisplayOptionsDidChangeNotification` (the A1 idiom) —
/// packaged once for the effect views that host real content (About
/// background, the quit indicator) instead of hand-rolled copies.
///
/// Install with ``install(in:fill:)`` immediately after creating the effect
/// view, BEFORE its content subviews — the cover must composite above the
/// blur and below the content. Non-interactive (`hitTest` returns `nil`).
///
/// The fill resolves through a provider at draw time, never a stored color,
/// so appearance flips and Increase Contrast land on every repaint (the
/// layer-stamp trap — see this folder's AGENTS.md).
@MainActor
public final class ReduceTransparencyFallbackView: NSView {

    private let fillProvider: () -> NSColor

    /// `nil` = read the live `accessibilityDisplayShouldReduceTransparency`.
    /// Tests drive both sides of the fallback with this.
    public var test_reduceTransparencyOverride: Bool? {
        didSet { reconcile() }
    }

    /// Whether the opaque cover is currently standing in for the blur.
    public var test_isCoveringOpaquely: Bool { !isHidden }

    public init(fill: @escaping () -> NSColor = { Tokens.Color.windowBackground }) {
        self.fillProvider = fill
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        reconcile()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Builds the cover, pins it edge-to-edge inside `effectView` (four
    /// zero-constant edge constraints — never an autoresizing mask, per
    /// `AudiouterSettingsUI`'s trap 4), and returns it for a test seam to
    /// hold.
    @discardableResult
    public static func install(
        in effectView: NSVisualEffectView,
        fill: @escaping () -> NSColor = { Tokens.Color.windowBackground }
    ) -> ReduceTransparencyFallbackView {
        let cover = ReduceTransparencyFallbackView(fill: fill)
        effectView.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            cover.topAnchor.constraint(equalTo: effectView.topAnchor),
            cover.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        return cover
    }

    private var reduceTransparency: Bool {
        test_reduceTransparencyOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private func reconcile() {
        isHidden = !reduceTransparency
        needsDisplay = true
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        reconcile()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        fillProvider().setFill()
        dirtyRect.fill()
    }

    /// Never intercepts a click meant for the content above it — this view
    /// exists purely to paint an opaque backing.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
