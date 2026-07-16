// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit

/// The "connected" green dot in the device row's status slot.
///
/// Drawn as a `CAShapeLayer` filled circle centered on the view — NOT an
/// SF-Symbol `circle.fill` in an `NSImageView`, because that symbol's glyph
/// does not land dead-center in its image box: measured against the custom
/// ``ArcSpinnerView`` (which draws at exact center), the symbol dot sat ~0.5pt
/// to the right, reading as misaligned with the arc and warning triangle in the
/// column (Alec, 2026-07-17). Drawing the circle at `bounds` center guarantees
/// it shares the exact optical center of its slot-mates, independent of any
/// SF-Symbol bearing.
final class StatusDotView: NSView {

    private let dotLayer = CAShapeLayer()

    /// Diameter of the drawn dot — matches the prior 8pt `circle.fill` glyph so
    /// only its centering changes, not its weight in the column.
    private let diameter: CGFloat = 8

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(dotLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Layer-backed drawing via `updateLayer` (documented `NSView` pattern) so
    /// the semantic green re-resolves under a live light/dark switch with the
    /// view's `effectiveAppearance` current.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        dotLayer.fillColor = NSColor.systemGreen.cgColor
    }

    override func layout() {
        super.layout()
        let rect = NSRect(x: bounds.midX - diameter / 2,
                          y: bounds.midY - diameter / 2,
                          width: diameter, height: diameter)
        dotLayer.path = CGPath(ellipseIn: rect, transform: nil)
    }
}
