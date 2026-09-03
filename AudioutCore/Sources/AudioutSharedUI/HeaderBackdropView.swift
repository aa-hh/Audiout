// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The ground behind the one surface's header strip.
///
/// The strip used to take whatever macOS painted there, which in dark mode is
/// a NEUTRAL grey against the warm near-black body — a hard horizontal seam
/// under the header (live check, 2026-09-03). Warm Signal owns backgrounds, so
/// the header has to carry the same warm ground the body does.
///
/// It carries it as REAL GLASS wherever the OS has glass, because that is the
/// only way to follow the reader's own glass setting. There is no API that
/// reports it: the macOS 27 and iOS 27 SDKs expose `style` (`.regular` /
/// `.clear`), `tintColor`, `cornerRadius` and `effectIsInteractive`, and
/// nothing resembling a level, an intensity, or a `reduceGlass` preference
/// (searched both SDKs' framework headers, 2026-09-03). An app follows the
/// setting by USING the system material and letting the system render it —
/// authoring a flat fill is precisely how an app opts OUT of it. So
/// `NSGlassEffectView` does the work, and `tintColor` pulls it warm; the
/// system keeps control of how much glass the reader actually sees.
///
/// Two cases fall back to a flat fill, and both are the same code path:
/// macOS 14–25, which have no `NSGlassEffectView` at all, and Reduce
/// Transparency, where a blur is the thing the reader asked not to have. The
/// fill is ``Tokens/Color/canvasHi`` — one rung off the body's `panel`, so the
/// header still reads as its own layer rather than dissolving into the body.
///
/// The fill resolves at DRAW time, never as a stored colour, so an appearance
/// flip or Increase Contrast lands on the next repaint (the layer-stamp trap —
/// see this folder's AGENTS.md), and the glass/flat choice re-resolves live off
/// `accessibilityDisplayOptionsDidChangeNotification`.
@MainActor
public final class HeaderBackdropView: NSView {

    /// The glass, when the OS has it and the reader has not asked for less.
    /// Held so the accessibility flip can hide it without rebuilding the view.
    private var glass: NSView?

    /// `nil` = read the live accessibility setting. Tests drive both sides.
    public var test_reduceTransparencyOverride: Bool? {
        didSet { reconcile() }
    }

    /// Whether the reader is seeing real glass rather than the flat fallback.
    public var test_isShowingGlass: Bool { glass?.isHidden == false }

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            // Warm, not the system's neutral: this tint IS the seam fix.
            effect.tintColor = Tokens.Color.panel
            effect.style = .regular
            effect.translatesAutoresizingMaskIntoConstraints = false
            addSubview(effect)
            NSLayoutConstraint.activate([
                effect.leadingAnchor.constraint(equalTo: leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: trailingAnchor),
                effect.topAnchor.constraint(equalTo: topAnchor),
                effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            glass = effect
        }
        reconcile()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    /// The header is chrome, never a click target — every gesture in the strip
    /// belongs to a toolbar item sitting above it.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        // Painted whether or not the glass is up: the glass tints TOWARD its
        // colour rather than replacing the ground, so the fill underneath is
        // what keeps the strip warm at every glass setting.
        Tokens.Color.canvasHi.setFill()
        dirtyRect.fill()
    }

    private var reduceTransparency: Bool {
        test_reduceTransparencyOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private func reconcile() {
        glass?.isHidden = reduceTransparency
        needsDisplay = true
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        reconcile()
    }
}
