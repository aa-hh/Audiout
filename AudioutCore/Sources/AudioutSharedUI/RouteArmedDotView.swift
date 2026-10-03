// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **gold route-armed corner dot** (Warm Signal v3 §3.3, S2): a small disc
/// riding the device icon's bottom-right corner — the position the retired
/// connection dot (`StatusDotView`) vacated — meaning **"this route is armed
/// and held"**. A PURE MODEL-STATE indicator, NEVER audio/RMS-driven: paused,
/// playing, and freshly-opened render identically here (only the meter differs
/// — house rule R3). The ROW computes the armed predicate (spec §3.3) and
/// pushes the boolean; this view only draws it:
///
/// - **armed** (playing) → a flat `gold` disc with a 1 pt `ember` edge, no
///   halo. The edge keeps the dot ≥3:1 against the ground where light gold
///   alone is 1.77:1.
/// - **shown, not armed** (connected and in the mix, but muted) → a hollow
///   ring in `Tokens.Color.ringConnected`, the connected glyph ring's own
///   colour, so a later change to that colour moves both.
/// - **not shown** (not connected, not in the mix, connecting, failed) → no
///   dot at all (owner's ruling, 2026-10-03; it retires spec §3.3's
///   always-present "dark/empty socket").
///
/// A shown dot sits on a `routeArmedDotCutoutDiameter` disc in the popover
/// ground (`Tokens.Color.panel`, what `ControlPanelBackingView` fills the
/// popover with) that cuts it out of the glyph, so the full
/// 8 pt dot reads as a badge over the glyph, not part of it. A device row
/// paints a 12 % gold wash behind itself while armed; with
/// `armedRowWashes` set, the cut-out carries the same wash so it matches the
/// ground it sits on instead of showing as a lighter (light) or black (dark)
/// ring.
///
/// **Bloom transition** (spec §6 first-light) — a colour transition and
/// nothing more: on a model transition INTO armed while on screen, the fill
/// blooms `ember → gold` over
/// `routeArmedBloomDuration` (≤450 ms, ease-out). Under Reduce Motion the swap
/// is instant. The animation runs OVER a settled model layer (fill already
/// stamped gold), following ``HaloRingView``'s model-layer-settled pattern, so
/// `cacheDisplay` snapshots are deterministic regardless of capture timing.
/// The very first `apply` never blooms — steady states render settled on open
/// (spec §6 "no transient fires on open").
///
/// Appearance-adaptive via `updateLayer`/`viewDidChangeEffectiveAppearance`
/// (CALayer colors are static `CGColor`s), and non-interactive (`hitTest`
/// returns nil) — the dot is decorative to the pointer and to accessibility;
/// the ROW's `accessibilityValue` carries the spoken equivalent ("armed" /
/// "playing here", spec S2).
public final class RouteArmedDotView: NSView {

    private let cutoutLayer = CAShapeLayer()
    private let cutoutWashLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private static let bloomFillKey = "routeArmedDot.bloomFill"

    /// The armed state currently rendered (model truth, stamped by `apply`).
    private var isArmed = false
    /// Whether `apply` has run at least once — the first application renders
    /// settled with no bloom (spec §6: transients fire only on transitions
    /// observed while already open, never on initial render).
    private var hasApplied = false

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(cutoutLayer)
        layer?.addSublayer(cutoutWashLayer)
        layer?.addSublayer(dotLayer)
        // Mid-session accessibility-display changes reconcile LIVE (same
        // pattern as `HaloRingView`): Increase Contrast re-stamps the token
        // colors, and Reduce Motion cancels any in-flight arm bloom — the
        // model layer is already settled gold, so removing the animation IS
        // the instant swap Reduce Motion asks for. Selector-based observation
        // needs no matching removal (post-10.11 AppKit auto-unregisters).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        // A layer-color instrument: `dotLayer.fillColor` is
        // stamped once and won't re-resolve on their own, so the accent dial
        // (AGENTS.md rule 36 / Tokens.swift's accentStyleDidChangeNotification
        // doc) needs its own observer alongside the a11y one above.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accentStyleDidChange),
            name: Tokens.accentStyleDidChangeNotification,
            object: nil)
    }

    /// Live accessibility-display reconcile: re-resolve colors (IC variants)
    /// and, if Reduce Motion just turned ON, strip the one-shot bloom so the
    /// dot lands on its settled state immediately instead of finishing a
    /// transition the user asked not to see.
    @objc private func accessibilityDisplayOptionsDidChange() {
        updateLayerAppearance()
        if reduceMotion {
            dotLayer.removeAnimation(forKey: Self.bloomFillKey)
        }
    }

    /// A live accent-dial change: re-stamp the layer so an armed dot follows
    /// the dial in the same instant every other gold instrument does.
    @objc private func accentStyleDidChange() {
        updateLayerAppearance()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Whether the host row paints the gold live wash behind itself while
    /// armed (`DeviceRowView` does; Main Audio's row does not).
    public var armedRowWashes = false {
        didSet { updateLayerAppearance() }
    }

    /// Non-interactive: never intercept clicks/hover meant for the row.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Point the dot at an armed state. Idempotent; a repeated same-state
    /// apply re-stamps colors (cheap) and never re-triggers the bloom. The
    /// bloom fires only on a false→true transition after the first apply,
    /// while in a window, with Reduce Motion off.
    /// - Parameter shown: whether the speaker is connected and in the mix;
    ///   `false` hides the dot whatever `armed` says.
    public func apply(armed: Bool, shown: Bool = true) {
        let wasArmed = isArmed
        let firstApply = !hasApplied
        isArmed = armed
        hasApplied = true
        isHidden = !shown
        updateLayerAppearance()
        needsLayout = true
        if armed && !wasArmed && !firstApply && window != nil && !reduceMotion {
            bloom()
        } else if !armed {
            // Leaving armed (or re-confirming unarmed): make sure no stale
            // bloom keeps playing over the socket (energy rule / idempotence).
            dotLayer.removeAnimation(forKey: Self.bloomFillKey)
        }
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() { updateLayerAppearance() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerAppearance()
    }

    /// Stamp the MODEL layer fully settled for the current state — cut-out,
    /// fill and edge — against the current effective appearance.
    /// The bloom (if any) animates over these settled values, so a snapshot
    /// always captures the final state.
    private func updateLayerAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cutoutLayer.fillColor = Tokens.Color.panel.cgColor
            cutoutWashLayer.fillColor = isArmed && armedRowWashes
                ? Tokens.Color.gold.withAlphaComponent(PopoverColumnGrid.rowLiveWashAlpha).cgColor
                : nil
            if isArmed {
                dotLayer.fillColor = Tokens.Color.gold.cgColor
                dotLayer.strokeColor = Tokens.Color.ember.cgColor
            } else {
                dotLayer.fillColor = nil
                dotLayer.strokeColor = Tokens.Color.ringConnected.cgColor
            }
        }
        dotLayer.lineWidth = strokeWidth
    }

    /// The edge (armed) or hollow ring (not armed) width.
    private var strokeWidth: CGFloat {
        isArmed ? PopoverColumnGrid.routeArmedDotEdgeWidth : PopoverColumnGrid.routeArmedDotRingWidth
    }

    public override func layout() {
        super.layout()
        cutoutLayer.frame = bounds
        cutoutWashLayer.frame = bounds
        dotLayer.frame = bounds
        cutoutLayer.path = Self.circle(PopoverColumnGrid.routeArmedDotCutoutDiameter, in: bounds)
        cutoutWashLayer.path = cutoutLayer.path
        // The stroke sits INSIDE the 8 pt outline, so the dot's outer edge is
        // the full `routeArmedDotDiameter` in both states.
        dotLayer.path = Self.circle(PopoverColumnGrid.routeArmedDotDiameter - strokeWidth, in: bounds)
    }

    private static func circle(_ diameter: CGFloat, in bounds: NSRect) -> CGPath {
        CGPath(ellipseIn: NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                                 width: diameter, height: diameter), transform: nil)
    }

    // MARK: Bloom (arm transition, spec §6)

    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// One-shot `ember → gold` fill bloom, ease-out, over the
    /// already-settled model layer. Self-removing (`isRemovedOnCompletion`
    /// stays true), so nothing animates at rest.
    private func bloom() {
        var emberCG: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            emberCG = Tokens.Color.ember.cgColor
        }
        let fill = CABasicAnimation(keyPath: "fillColor")
        fill.fromValue = emberCG
        fill.duration = PopoverColumnGrid.routeArmedBloomDuration
        fill.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dotLayer.add(fill, forKey: Self.bloomFillKey)
    }

    // MARK: Test-support hooks

    /// Overrides the live `accessibilityDisplayShouldReduceMotion` read for
    /// tests (`nil` = real workspace value). Tests flip it and then post
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on
    /// `NSWorkspace.shared.notificationCenter` — exercising the same
    /// notification path a real System Settings toggle takes.
    public var test_reduceMotionOverride: Bool?

    /// Whether the dot is currently rendered LIT (armed) — the same state the
    /// drawing reads, so it can't drift from the pixels.
    public var test_isLit: Bool { isArmed }

    /// The dot's current fill (resolved against the effective appearance) —
    /// gold when armed, `nil` (hollow) otherwise.
    public var test_fillColor: NSColor? {
        guard let cg = dotLayer.fillColor else { return nil }
        return NSColor(cgColor: cg)
    }

    /// The dot's current edge / hollow-ring colour.
    public var test_strokeColor: NSColor? {
        guard let cg = dotLayer.strokeColor else { return nil }
        return NSColor(cgColor: cg)
    }

    /// Whether the one-shot arm bloom is currently mid-flight (present on the
    /// layer the instant it's added, same idiom as `HaloRingView`'s breathing
    /// hook — no run loop needed to assert it fired).
    public var test_isBlooming: Bool {
        dotLayer.animation(forKey: Self.bloomFillKey) != nil
    }

}
