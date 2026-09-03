// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **magenta identity light a saved group gives off** — the Mac mirror of
/// the iPhone companion's `GroupIdentityGlow` (audiout-remote GroupsView.swift
/// :205-228). A radial `partyRampDeep` core fading to nothing by the view's
/// edge, mounted BEHIND a group's seat so the magenta reads as light the group
/// emits, never as chrome drawn around it (iOS never puts magenta on text or a
/// border).
///
/// The gradient IS the backing layer, so its unit-coordinate falloff scales
/// with whatever size the host constrains: the Main Out row mounts it at
/// `side` behind the destination icon, the Groups screen behind its seats,
/// with no second recipe. Non-interactive and silent to VoiceOver — the seat
/// in front of it carries the meaning.
public final class GroupIdentityGlowView: NSView {

    /// The mounted size the Main Out row and the Groups card seat both use.
    public static let side: CGFloat = 60

    /// Core opacity of the magenta: a heavier core in dark, where the ground
    /// swallows it, than on the light ground, where it would bloom. Measured
    /// composites: dark 22 % over `panel` 1.561:1 and over `canvas` 1.484:1,
    /// light 10 % over the ground 1.183:1 — under the 3:1 graphic floor by
    /// design, because this is atmosphere, not an instrument, and the seat it
    /// sits behind carries the contrast.
    private static let darkCoreAlpha: CGFloat = 0.22
    private static let lightCoreAlpha: CGFloat = 0.10

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        if let gradient = layer as? CAGradientLayer {
            gradient.type = .radial
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.locations = [0, 1]
        }
        setAccessibilityElement(false)
        // Increase Contrast is NOT part of the effective appearance, so the
        // appearance callback alone would miss it and the glow would keep its
        // standard-contrast magenta — the same second observer every other
        // instrument here registers. Selector-based observation needs no
        // matching removal (post-10.11 AppKit auto-unregisters).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        stamp()
    }

    @objc private func accessibilityDisplayOptionsDidChange() { stamp() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stamp()
    }

    /// Resolve the magenta under the appearance actually on screen and stamp
    /// it — `CGColor`s in a layer are static, so a live light/dark flip has to
    /// re-run this or the glow keeps its build-time core.
    private func stamp() {
        guard let gradient = layer as? CAGradientLayer else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            gradient.colors = [
                Tokens.Color.partyRampDeep
                    .withAlphaComponent(isDark ? Self.darkCoreAlpha : Self.lightCoreAlpha).cgColor,
                NSColor.clear.cgColor,
            ]
        }
    }

    // MARK: Test-support hooks

    /// The stamped core colour, read back — the appearance and
    /// Increase-Contrast splits both land here.
    public var test_coreColor: NSColor? {
        guard let gradient = layer as? CAGradientLayer,
              let colors = gradient.colors as? [CGColor],
              let core = colors.first else { return nil }
        return NSColor(cgColor: core)
    }
    /// The alpha of the stamped core colour — the appearance split, read back.
    public var test_coreAlpha: CGFloat? { test_coreColor?.alphaComponent }
}
