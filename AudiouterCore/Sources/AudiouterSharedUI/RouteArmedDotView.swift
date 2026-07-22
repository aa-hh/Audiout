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
/// - **armed** → a `gold` disc with a subtle STATIC `glow` halo (a resting
///   shadow, not an animation — the energy rule holds: nothing runs at rest).
/// - **not armed** → the dark/empty `dotSocket` disc (spec §3.3's "dark/empty
///   socket"), so the corner reads as an unlit lamp, not an absence.
///
/// Both states keep the punch-out border (`underPageBackground`, the
/// `statusDotBorderWidth` ring the retired corner dot pioneered) so the dot
/// reads as a badge over the glyph, not part of it.
///
/// **Bloom transition** (spec §6 first-light): on a model transition INTO
/// armed while on screen, the fill blooms `ember → gold` over
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

    private let dotLayer = CAShapeLayer()
    private static let bloomFillKey = "routeArmedDot.bloomFill"
    private static let bloomGlowKey = "routeArmedDot.bloomGlow"

    /// The armed state currently rendered (model truth, stamped by `apply`).
    private var isArmed = false
    /// Whether `apply` has run at least once — the first application renders
    /// settled with no bloom (spec §6: transients fire only on transitions
    /// observed while already open, never on initial render).
    private var hasApplied = false

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        dotLayer.lineWidth = PopoverColumnGrid.statusDotBorderWidth
        layer?.addSublayer(dotLayer)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Non-interactive: never intercept clicks/hover meant for the row.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Point the dot at an armed state. Idempotent; a repeated same-state
    /// apply re-stamps colors (cheap) and never re-triggers the bloom. The
    /// bloom fires only on a false→true transition after the first apply,
    /// while in a window, with Reduce Motion off.
    public func apply(armed: Bool) {
        let wasArmed = isArmed
        let firstApply = !hasApplied
        isArmed = armed
        hasApplied = true
        updateLayerAppearance()
        if armed && !wasArmed && !firstApply && window != nil && !reduceMotion {
            bloom()
        } else if !armed {
            // Leaving armed (or re-confirming unarmed): make sure no stale
            // bloom keeps playing over the socket (energy rule / idempotence).
            dotLayer.removeAnimation(forKey: Self.bloomFillKey)
            dotLayer.removeAnimation(forKey: Self.bloomGlowKey)
        }
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() { updateLayerAppearance() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerAppearance()
    }

    /// Stamp the MODEL layer fully settled for the current state — fill, punch-
    /// out border, and static glow — against the current effective appearance.
    /// The bloom (if any) animates over these settled values, so a snapshot
    /// always captures the final state.
    private func updateLayerAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isArmed {
                dotLayer.fillColor = Tokens.Color.gold.cgColor
                dotLayer.shadowColor = Tokens.Color.glow.cgColor
                dotLayer.shadowOpacity = PopoverColumnGrid.routeArmedGlowOpacity
                dotLayer.shadowRadius = PopoverColumnGrid.routeArmedGlowRadius
                dotLayer.shadowOffset = .zero
            } else {
                dotLayer.fillColor = Tokens.Color.dotSocket.cgColor
                dotLayer.shadowOpacity = 0
            }
            // Punch-out border in the under-page hue so the badge separates
            // from the glyph beneath it, lit or dark.
            dotLayer.strokeColor = Tokens.Color.underPageBackground.cgColor
        }
    }

    public override func layout() {
        super.layout()
        dotLayer.frame = bounds
        let d = PopoverColumnGrid.routeArmedDotDiameter
        let rect = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        dotLayer.path = CGPath(ellipseIn: rect, transform: nil)
    }

    // MARK: Bloom (arm transition, spec §6)

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// One-shot `ember → gold` fill bloom + glow fade-in, ease-out, over the
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

        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = 0
        glow.duration = PopoverColumnGrid.routeArmedBloomDuration
        glow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dotLayer.add(glow, forKey: Self.bloomGlowKey)
    }

    // MARK: Test-support hooks

    /// Whether the dot is currently rendered LIT (armed) — the same state the
    /// drawing reads, so it can't drift from the pixels.
    public var test_isLit: Bool { isArmed }

    /// The dot's current fill (resolved against the effective appearance) —
    /// asserts gold-when-armed / socket-when-dark.
    public var test_fillColor: NSColor? {
        guard let cg = dotLayer.fillColor else { return nil }
        return NSColor(cgColor: cg)
    }

    /// Whether the one-shot arm bloom is currently mid-flight (present on the
    /// layer the instant it's added, same idiom as `HaloRingView`'s breathing
    /// hook — no run loop needed to assert it fired).
    public var test_isBlooming: Bool {
        dotLayer.animation(forKey: Self.bloomFillKey) != nil
    }

    /// Whether the static glow halo is currently on (armed state's resting
    /// shadow) — `shadowOpacity` > 0.
    public var test_hasGlow: Bool { dotLayer.shadowOpacity > 0 }
}
