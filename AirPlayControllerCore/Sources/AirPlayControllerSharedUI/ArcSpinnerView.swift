// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit

/// The connecting/reconnecting spinner in the device row's status slot: a thin
/// 270° arc rotating about its center.
///
/// **This is the one deliberate, Alec-sanctioned exception to SPEC §9's
/// documented-controls standing rule** (2026-07-17: "in this one instance i
/// prefer your spinner to what is natively there"). The native candidates were
/// evaluated first — `NSProgressIndicator`'s spinning style (the stock gear),
/// and SF Symbols animated with the macOS 14 symbol-effects API (`rays` +
/// `.variableColor`, since verified that `circle.dotted` has no variable
/// layers and the true ring symbol `progress.indicator.spinner` is macOS 15+)
/// — and Alec chose the mockup's arc over both. Recorded in SPEC §9's device
/// row table. Revisit `progress.indicator.spinner` + the `.rotate` symbol
/// effect when the deployment floor reaches macOS 15.
///
/// Built from documented Core Animation API — a `CAShapeLayer` stroking a
/// partial circle (`strokeEnd = 0.75`, round caps, matching the approved
/// mockup glyph) driven by an infinitely repeating `CABasicAnimation` on
/// `transform.rotation.z`. Works on every supported macOS, so it replaces both
/// the prior macOS-14 rays symbol-effect view AND the pre-14
/// `NSProgressIndicator` fallback — no availability split.
final class ArcSpinnerView: NSView {

    private let arcLayer = CAShapeLayer()
    private static let rotationKey = "arcSpinner.rotation"

    /// Whether the arc is *supposed* to be spinning. Kept separate from the
    /// presence of the CA animation because Core Animation strips animations
    /// whenever the layer leaves the layer tree (popover close, row
    /// re-parenting) — ``viewDidMoveToWindow()`` re-adds it from this flag.
    private(set) var isSpinning = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        arcLayer.fillColor = nil
        arcLayer.lineWidth = 1.5          // matches the mockup's stroke weight at slot size
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0
        arcLayer.strokeEnd = 0.75         // 270° arc — the mockup's open ring
        layer?.addSublayer(arcLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Layer-backed drawing via `updateLayer` (documented `NSView` pattern:
    /// with `wantsUpdateLayer == true` AppKit calls `updateLayer` instead of
    /// `draw(_:)`, with the view's `effectiveAppearance` current — so the
    /// semantic color re-resolves correctly on a live light/dark switch, the
    /// exact bug class the 2026-07-16 review caught in ConnectionDiagnosisView).
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        arcLayer.strokeColor = NSColor.secondaryLabelColor.cgColor
    }

    override func layout() {
        super.layout()
        // Size via bounds + position, NOT `frame` — Apple docs: a layer's
        // `frame` is undefined while a transform (our rotation) is applied.
        arcLayer.bounds = bounds
        arcLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let inset = arcLayer.lineWidth / 2 + 0.5
        arcLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
    }

    func startSpinning() {
        isSpinning = true
        addRotationIfNeeded()
    }

    func stopSpinning() {
        isSpinning = false
        arcLayer.removeAnimation(forKey: Self.rotationKey)
    }

    private func addRotationIfNeeded() {
        guard isSpinning, window != nil,
              arcLayer.animation(forKey: Self.rotationKey) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        // Negative z-rotation reads clockwise on screen in a non-flipped view,
        // matching the direction of every stock macOS spinner.
        spin.toValue = -2 * Double.pi
        spin.duration = 1.0               // the mockup's 1s linear revolution
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arcLayer.add(spin, forKey: Self.rotationKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-add after re-parenting: CA removed the animation with the layer.
        addRotationIfNeeded()
    }
}
