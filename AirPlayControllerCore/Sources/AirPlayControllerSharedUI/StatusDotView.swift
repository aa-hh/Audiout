// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore

/// The on-icon **connection-status badge** (2026-07-17 redesign): a small dot
/// overlapping the device icon's bottom-right corner (a notification-badge
/// position), replacing the retired right-side status slot. It renders one of
/// four states derived from `Device.connectionState`:
///
/// - `.off` → hidden (the badge shows nothing).
/// - `.connecting` / `.reconnecting` → a **breathing** (pulsing) neutral dot in
///   `.secondaryLabelColor` (adaptive: dark-on-light, light-on-dark), animated
///   with a `CABasicAnimation` on opacity + scale (auto-reversed, forever). If
///   Reduce Motion is on it shows a STATIC neutral dot (no animation).
/// - `.connected` → a solid `.systemGreen` dot.
/// - `.failed` → a solid `.systemOrange` dot.
///
/// Drawn as a `CAShapeLayer` filled circle at the view's exact center, ringed by
/// a ~1.5pt punch-out border in the card/window background colour so the badge
/// reads as its own thing over the icon glyph beneath it.
///
/// Appearance-adaptive: colours re-resolve on a live light/dark switch via
/// `updateLayer` / `viewDidChangeEffectiveAppearance` (the documented `NSView`
/// pattern). Core Animation strips animations when a layer leaves the tree, so
/// the breathing animation is re-added in `viewDidMoveToWindow` when appropriate
/// (the same pattern the retired `ArcSpinnerView` demonstrated).
///
/// Sizes come from `PopoverColumnGrid` NAMED CONSTANTS (badge diameter, border
/// width, breathing timing) so a future compact/normal/large density setting can
/// swap them in one place.
final class StatusDotView: NSView {

    private let dotLayer = CAShapeLayer()
    private static let breathKey = "statusDot.breathe"

    /// The state currently being rendered — drives the dot colour, visibility,
    /// and whether the breathing animation should be installed.
    private var state: ConnectionState = .off

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        dotLayer.borderWidth = 0
        layer?.addSublayer(dotLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Point the badge at a connection state. Fully resets the layer (colour,
    /// visibility, animation) so a repeated `apply` after an unrelated re-render
    /// can never leave a stale breathing animation running under a since-changed
    /// state.
    func apply(_ state: ConnectionState) {
        self.state = state
        isHidden = !isVisibleForState
        updateLayerColors()
        reconcileBreathing()
    }

    /// Whether the badge shows at all for the current state (`.off` hides it).
    private var isVisibleForState: Bool {
        if case .off = state { return false }
        return true
    }

    /// Whether the current state calls for the breathing pulse (connecting /
    /// reconnecting), subject to Reduce Motion below.
    private var wantsBreathing: Bool {
        switch state {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    /// Layer-backed drawing via `updateLayer` (documented `NSView` pattern) so
    /// the semantic colours re-resolve under a live light/dark switch with the
    /// view's `effectiveAppearance` current.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        updateLayerColors()
    }

    /// Resolve the fill (per state) + the punch-out border colour against the
    /// current effective appearance and stamp them on the layer. `CALayer`
    /// colours are static `CGColor`s, so this must re-run on every appearance
    /// change, not just at build time.
    private func updateLayerColors() {
        let fill: NSColor
        switch state {
        case .off:                        fill = .clear
        case .connecting, .reconnecting:  fill = .secondaryLabelColor
        case .connected:                  fill = .systemGreen
        case .failed:                     fill = .systemOrange
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dotLayer.fillColor = fill.cgColor
            // Best-effort punch-out ring in the card/window background so the dot
            // reads as a separate badge over the icon (tuned live later).
            dotLayer.borderColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func layout() {
        super.layout()
        let diameter = PopoverColumnGrid.statusDotDiameter
        let border = PopoverColumnGrid.statusDotBorderWidth
        // Draw the fill circle centered, with the punch-out border as a layer
        // border ringing it. Sizing the layer to the dot (not the whole view)
        // keeps the border a clean ring around the visible dot.
        let rect = NSRect(x: bounds.midX - diameter / 2,
                          y: bounds.midY - diameter / 2,
                          width: diameter, height: diameter)
        dotLayer.frame = rect
        dotLayer.path = CGPath(ellipseIn: dotLayer.bounds, transform: nil)
        dotLayer.cornerRadius = diameter / 2
        dotLayer.borderWidth = border
        // Scale animations pulse about the dot's own center.
        dotLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    // MARK: Breathing pulse (connecting / reconnecting)

    /// True when the OS is set to reduce motion — a static dot must be shown then.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Add or remove the breathing animation to match the current state, honoring
    /// Reduce Motion (static dot when reduced) and window presence (CA strips the
    /// animation when the layer leaves the tree — re-added in
    /// ``viewDidMoveToWindow()``).
    private func reconcileBreathing() {
        guard wantsBreathing, !reduceMotion, window != nil else {
            dotLayer.removeAnimation(forKey: Self.breathKey)
            return
        }
        guard dotLayer.animation(forKey: Self.breathKey) == nil else { return }

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = PopoverColumnGrid.statusDotBreathMinOpacity
        opacity.toValue = 1.0

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = PopoverColumnGrid.statusDotBreathMinScale
        scale.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [opacity, scale]
        group.duration = PopoverColumnGrid.statusDotBreathDuration
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        dotLayer.add(group, forKey: Self.breathKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-add after re-parenting: CA removed the animation with the layer.
        reconcileBreathing()
    }

    // MARK: Test-support hooks

    /// Whether the breathing pulse is currently installed (connecting/reconnecting
    /// AND on screen AND Reduce Motion off) — lets tests assert the animation is
    /// present without reaching into Core Animation internals.
    var test_isBreathing: Bool { dotLayer.animation(forKey: Self.breathKey) != nil }
}
