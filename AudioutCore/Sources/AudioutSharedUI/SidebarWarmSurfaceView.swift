// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The Groups window sidebar's warm surface (T7, spec Q4-b): a non-
/// interactive view sitting between the sidebar's system material and the
/// outline view. On macOS 26+ the automatic Liquid Glass sidebar material
/// (applied by `NSSplitViewItem(sidebarWithViewController:)` outside this
/// controller's own view — there is no public API to tint it directly) is
/// left completely alone; this draws a LOW-ALPHA warm wash on top of it.
/// Below macOS 26 there is no glass to tint at all, so this draws the SAME
/// color fully opaque as the sidebar's whole backing. Reduce Transparency
/// promotes the 26+ wash to that same opaque backing too — see
/// ``effectiveAlpha``.
///
/// Deliberately NOT drawn by setting `outlineView.backgroundColor` —
/// `NSTableView.h`'s `NSTableViewStyleSourceList` doc comment states that
/// moving a source-list table's background color off the system "source
/// list" color drops the blur/vibrant selection-highlight style entirely.
/// This view is a separate layer behind the (untouched) outline view instead.
public final class SidebarWarmSurfaceView: NSView {

    /// Whether THIS OS renders the automatic Liquid Glass (macOS 26+) that
    /// this view either leaves alone (glass) or stands in for (opaque
    /// fallback) — a static real-OS-value property, injected through the
    /// sidebar controllers' own defaulted init parameters so a test can
    /// construct either branch directly regardless of the machine the suite
    /// runs on.
    public static var osSupportsLiquidGlass: Bool {
        if #available(macOS 26, *) { return true } else { return false }
    }

    /// Whether THIS instance renders atop Apple's automatic glass (true) or
    /// stands in as the opaque fallback (false) — set once at init from the
    /// controller's injected seam value, never re-read live (the OS version
    /// a process runs under doesn't change mid-session).
    public let rendersOnGlass: Bool

    /// The 26+ overlay's alpha — a taste dial, to be judged live against
    /// real glass. The plan's original 0.06–0.10 band was ARITHMETICALLY
    /// TOO WEAK to do the job: the sidebar's base grey is a perfectly
    /// neutral `#F0F0F0`, and `sidebarWarmTint` carries a 22-unit red-to-
    /// blue spread, so an 0.08 wash shifts it by ~2 units — invisible. The
    /// warm cast has to be comparable to the content pane's own (`panel`
    /// `#FBF8F2` spreads 9 units), which needs `22 × alpha ≈ 9`, i.e. ~0.4;
    /// 0.30 sits just under that so the sidebar reads warm without
    /// out-warming the pane it sits beside. Chosen deliberately high rather
    /// than low: dialing DOWN from a visible wash is far easier to judge by
    /// eye than nudging up from no perceptible change.
    public static let tintAlpha: CGFloat = 0.30

    /// `nil` = read the live `accessibilityDisplayShouldReduceTransparency`.
    /// Tests drive both sides of the opaque promotion with this.
    public var test_reduceTransparencyOverride: Bool? {
        didSet { needsDisplay = true }
    }

    /// The alpha ``draw(_:)`` actually uses. On the 26+ glass branch, Reduce
    /// Transparency promotes the wash to the SAME fully-opaque backing the
    /// pre-26 fallback draws — the system flattens its glass underneath, and
    /// a translucent tint over whatever it flattens to would still read as
    /// transparency (A1). The pre-26 branch is already opaque.
    public var effectiveAlpha: CGFloat {
        let reduceTransparency = test_reduceTransparencyOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        return (rendersOnGlass && !reduceTransparency) ? Self.tintAlpha : 1
    }

    public init(rendersOnGlass: Bool) {
        self.rendersOnGlass = rendersOnGlass
        super.init(frame: .zero)
        wantsLayer = true
        // Reconcile live on a mid-session Reduce Transparency / Increase
        // Contrast toggle (`AudioutSharedUI/AGENTS.md`'s instrument rule —
        // neither arrives through this view's own lifecycle otherwise).
        // `draw(_:)` re-reads both flags per repaint via `effectiveAlpha`,
        // so the invalidation is all the reconciliation needed.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Never intercepts a click meant for a sidebar row or the add button —
    /// this view exists purely to paint a tint underneath them.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override var isFlipped: Bool { false }

    @objc private func accessibilityDisplayOptionsDidChange() {
        needsDisplay = true
    }

    /// A light/dark appearance flip re-resolves `Tokens.Color.sidebarWarmTint`
    /// (its dynamic provider reads `effectiveAppearance` at draw time), so
    /// this just needs to trigger the repaint.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let base = Tokens.Color.sidebarWarmTint
        let alpha = effectiveAlpha
        let color = alpha < 1 ? base.withAlphaComponent(alpha) : base
        color.setFill()
        bounds.fill()
    }
}
