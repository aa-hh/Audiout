// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// The **connection halo ring** (Warm Signal v3 §3.2): a ring drawn AROUND the
/// device icon that carries the connection lifecycle, replacing the retired
/// corner connection dot (`StatusDotView`, deleted 2026-07-22). The corner
/// position is repurposed for the gold route-armed dot in a later task (spec
/// §3.3) — this view owns ONLY the connection channel, driven by
/// `Device.connectionState` alone (teal is retired, so there is no
/// routing/teal rung on the ring — spec §0 decision c / §3.1).
///
/// The FORM carries the state, not just the color — so the ladder survives
/// Reduce Motion (the **blocking** stress-test break §8.2):
///
/// - `.off` → **no ring** (hidden — discovered, nothing to report), UNLESS
///   the caller passes `restingArmed: true` (Main Audio only — see
///   `apply(_:restingArmed:)`), in which case it renders the **resting**
///   form instead.
/// - `.connecting` / `.reconnecting` → **dashed ring, breathing** (opacity +
///   scale pulse). Under Reduce Motion the dashed FORM survives, STATIC (no
///   animation) — "incomplete", legible frozen. Same `ringConnected` hue as
///   connected: form, not color, carries pending (spec §3.2 "zero new colors").
/// - `.connected` → **solid quiet ring**, `ringConnected` token (hue-neutral
///   warm-grey), stroke ~1.6 pt. Tested ≥3:1 vs the panel at `haloRingDiameter`
///   (26 px, Warm Signal v4.1 item 2), both themes.
/// - `.failed` → **red solid ring**, `failure` token, stroke ~1.8 pt (heavier so
///   the failed row wins the scan beside flickering meters).
/// - **`.resting`** (Main Audio only, ring-resting-state task) — audio is
///   genuinely playing to the local Mac and unmuted, but `connectionState` is
///   `.off` because there's no remote AirPlay handshake to track (the
///   `mainOutConnectionState` fallthrough is correct and untouched). Without
///   this form the rail's curve into the ring (`BusRailOverlayView`) lands on
///   a hidden ring and reads as unfinished. Renders the SHARED, hue-neutral
///   `ringConnected` token at the SHARED `haloRingConnectedStroke` (1.6 pt) —
///   deliberately thinner than Main Audio's bespoke gold/ember
///   `mainAudioRingConnectedStroke` (2 pt, matched to the rail's own
///   `busLineWidth`) and never recolored via `connectedStrokeColorOverride`/
///   `connectedStrokeWidthOverride` (those apply to `.connected` only), so a
///   quiet thin neutral ring is visually distinct from any real remote
///   `.connected` ring, which always wears the gold/ember override.
///
/// Geometry comes from `PopoverColumnGrid` NAMED CONSTANTS (`haloRingDiameter`,
/// stroke widths, dash lengths, breathing timing) so a future density setting
/// swaps ring + icon sizing in one place (spec §3.2 "geometry off
/// PopoverColumnGrid").
///
/// Appearance-adaptive: colors re-resolve on a live light/dark or Increase
/// Contrast switch via `updateLayer` / `viewDidChangeEffectiveAppearance` (the
/// documented `NSView` pattern) — `CALayer` colors are static `CGColor`s, so
/// they must re-stamp on every appearance change. Core Animation strips
/// animations when a layer leaves the tree, so the breathing pulse is re-added
/// in `viewDidMoveToWindow` when appropriate (the idiom the retired
/// `StatusDotView` demonstrated).
///
/// **Determinism:** the breathing pulse animates OVER the model layer without
/// changing the model's `opacity`/`transform` (which stay settled at 1.0 /
/// identity), so `cacheDisplay(in:to:)` — the offscreen snapshot path — captures
/// the settled ring, never a mid-pulse frame. The connecting ring therefore
/// renders identically in the deterministic snapshot regardless of when it's
/// captured.
public final class HaloRingView: NSView {

    /// Which ring form is currently rendered — mirrors the four connection
    /// renderings so a row can assert the ring without reaching into the layer.
    public enum Form: Equatable {
        /// `.off` — no ring (hidden).
        case none
        /// `.connecting` / `.reconnecting` — dashed, breathing (static under
        /// Reduce Motion).
        case connecting
        /// `.connected` — solid quiet ring, `ringConnected`.
        case connected
        /// `.failed` — solid red ring, `failure`, heavier stroke.
        case failed
        /// Main Audio only: armed local-only playback with no remote target
        /// to track (`state == .off && restingArmed == true`) — solid quiet
        /// ring at the shared `ringConnected` hue and shared (thinner)
        /// `haloRingConnectedStroke`, never the Main Audio gold/ember
        /// override, so it reads as distinct from a real `.connected` ring.
        case resting
    }

    private let ringLayer = CAShapeLayer()
    private static let breathKey = "haloRing.breathe"

    /// The connection state currently being rendered — drives the ring's form,
    /// visibility, color, stroke, dashing, and whether the breathing animation
    /// should be installed.
    private var state: ConnectionState = .off
    /// Main Audio's host-computed bit (ring-resting-state task): true iff the
    /// active target's members are all the local device (non-empty) and the
    /// master is unmuted — the `.resting` form fires only when this is true
    /// AND `state == .off`. Every device row (and any caller using the
    /// single-argument `apply(_:)`) leaves this `false`, so `.resting` is
    /// reachable ONLY through Main Audio's own call site — existing behavior
    /// elsewhere is unchanged.
    private var restingArmed = false

    /// Bespoke ring diameter override (Warm Signal nitpicks — the Main Audio
    /// ring is the rail's terminus, not a peer of the device rows' rings, so
    /// it owns its own size rather than sharing `haloRingDiameter`). `nil`
    /// (every device row) keeps the shared `PopoverColumnGrid.haloRingDiameter`
    /// unchanged.
    public var diameterOverride: CGFloat? {
        didSet { needsLayout = true }
    }
    /// Bespoke stroke-width override for the **connected** form only (Warm
    /// Signal nitpicks — the Main Audio ring's stroke is set to match the
    /// rail's own `busLineWidth` so the two read as one continuous line where
    /// they meet). `nil` keeps the shared per-form widths
    /// (`haloRingConnectedStroke`/`haloRingConnectingStroke`/`haloRingFailedStroke`).
    public var connectedStrokeWidthOverride: CGFloat? {
        didSet { updateLayerAppearance() }
    }
    /// Bespoke stroke-COLOR override for the **connected** form only (Warm
    /// Signal nitpicks): the Main Audio ring is the rail's terminus, so its
    /// connected color must match whatever tone the rail's curve is drawn in
    /// (gold when armed, ember otherwise — the same two-tone the rail itself
    /// uses, not the device rows' hue-neutral `ringConnected` token) for the
    /// join to read as one continuous line rather than two different colors
    /// touching. `nil` keeps the shared `Tokens.Color.ringConnected`.
    public var connectedStrokeColorOverride: NSColor? {
        didSet { updateLayerAppearance() }
    }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.lineCap = .round
        layer?.addSublayer(ringLayer)
        // A mid-session accessibility-display change (Reduce Motion toggled in
        // System Settings, Increase Contrast flipped) must reconcile LIVE — the
        // breathing pulse starts/stops and the token colors re-stamp without
        // waiting for the next `apply`. Selector-based observation on the
        // workspace center needs no matching removal (post-10.11 AppKit
        // auto-unregisters on dealloc).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    /// A mid-session Reduce Motion / Increase Contrast toggle: re-stamp colors
    /// (the Increase-Contrast token variants resolve live) and re-reconcile the
    /// breathing pulse (a connecting ring goes static under Reduce Motion, and
    /// resumes breathing the moment it's switched back off) — spec §3.2's
    /// dashed-form guarantee holds through the toggle, not just across `apply`s.
    @objc private func accessibilityDisplayOptionsDidChange() {
        updateLayerAppearance()
        reconcileBreathing()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Point the ring at a connection state. Fully resets the layer (color,
    /// stroke, dashing, visibility, animation) so a repeated `apply` after an
    /// unrelated re-render can never leave a stale breathing animation running
    /// under a since-changed state (the same idempotent-reset discipline the
    /// retired corner dot used).
    /// - Parameter restingArmed: Main Audio's host-computed bit (default
    ///   `false`, a no-op everywhere else): when `state == .off`, `true` here
    ///   renders the `.resting` form instead of hiding the ring. Every device
    ///   row call site omits this, so their `.off` handling is unchanged.
    public func apply(_ state: ConnectionState, restingArmed: Bool = false) {
        self.state = state
        self.restingArmed = restingArmed
        isHidden = form == .none
        updateLayerAppearance()
        reconcileBreathing()
    }

    /// The ring form for the current connection state.
    public var form: Form {
        switch state {
        case .off:                        return restingArmed ? .resting : .none
        case .connecting, .reconnecting:  return .connecting
        case .connected:                  return .connected
        case .failed:                     return .failed
        }
    }

    /// Whether the current form calls for the breathing pulse (connecting /
    /// reconnecting), subject to Reduce Motion below.
    private var wantsBreathing: Bool { form == .connecting }

    /// Layer-backed drawing via `updateLayer` (documented `NSView` pattern) so
    /// the semantic tokens re-resolve under a live light/dark or Increase
    /// Contrast switch with the view's `effectiveAppearance` current.
    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        updateLayerAppearance()
    }

    /// Resolve the stroke color + width + dash pattern for the current form and
    /// stamp them on the layer against the current effective appearance. `CALayer`
    /// colors are static `CGColor`s, so this must re-run on every appearance
    /// change, not just at build time.
    private func updateLayerAppearance() {
        let strokeToken: NSColor
        let width: CGFloat
        let dashed: Bool
        switch form {
        case .none:
            // Hidden anyway; nothing meaningful to stamp.
            strokeToken = .clear
            width = 0
            dashed = false
        case .connecting:
            strokeToken = Tokens.Color.ringConnected
            width = PopoverColumnGrid.haloRingConnectingStroke
            dashed = true
        case .connected:
            strokeToken = connectedStrokeColorOverride ?? Tokens.Color.ringConnected
            width = connectedStrokeWidthOverride ?? PopoverColumnGrid.haloRingConnectedStroke
            dashed = false
        case .failed:
            strokeToken = Tokens.Color.failure
            width = PopoverColumnGrid.haloRingFailedStroke
            dashed = false
        case .resting:
            // Deliberately NOT `connectedStrokeColorOverride`/
            // `connectedStrokeWidthOverride` — those exist so a real
            // `.connected` ring can match the rail's gold/ember + matched
            // stroke. `.resting` stays the shared hue-neutral token at the
            // shared (thinner) stroke so it never wears that combination —
            // the one visual signature Main Audio's real connected ring
            // always carries.
            strokeToken = Tokens.Color.ringConnected
            width = PopoverColumnGrid.haloRingConnectedStroke
            dashed = false
        }
        ringLayer.lineWidth = width
        ringLayer.lineDashPattern = dashed
            ? [NSNumber(value: Double(PopoverColumnGrid.haloRingDashLength)),
               NSNumber(value: Double(PopoverColumnGrid.haloRingDashGap))]
            : nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ringLayer.strokeColor = strokeToken.cgColor
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerAppearance()
    }

    public override func layout() {
        super.layout()
        // The visible ring circle sits centered in the view at `haloRingDiameter`
        // (the stroke centerline), regardless of the view's own box size (which
        // matches the 26 pt icon box). The layer fills the view; the path is the
        // inscribed circle.
        ringLayer.frame = bounds
        let diameter = diameterOverride ?? PopoverColumnGrid.haloRingDiameter
        let rect = NSRect(x: bounds.midX - diameter / 2,
                          y: bounds.midY - diameter / 2,
                          width: diameter, height: diameter)
        ringLayer.path = CGPath(ellipseIn: rect, transform: nil)
        // Scale animation pulses about the ring's own center.
        ringLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ringLayer.frame = bounds
    }

    // MARK: Breathing pulse (connecting / reconnecting)

    /// True when the OS is set to reduce motion — a static dashed ring must be
    /// shown then (the dashed FORM still carries "pending"; only the pulse drops).
    /// Consults ``test_reduceMotionOverride`` first so headless tests can drive
    /// both sides of a mid-session toggle (the real workspace value can't be
    /// flipped from a test process).
    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Add or remove the breathing animation to match the current form, honoring
    /// Reduce Motion (static dashed ring when reduced) and window presence (CA
    /// strips the animation when the layer leaves the tree — re-added in
    /// ``viewDidMoveToWindow()``).
    private func reconcileBreathing() {
        guard wantsBreathing, !reduceMotion, window != nil else {
            ringLayer.removeAnimation(forKey: Self.breathKey)
            return
        }
        guard ringLayer.animation(forKey: Self.breathKey) == nil else { return }

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
        ringLayer.add(group, forKey: Self.breathKey)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-add after re-parenting: CA removed the animation with the layer.
        reconcileBreathing()
    }

    // MARK: Test-support hooks

    /// Overrides the live `accessibilityDisplayShouldReduceMotion` read for
    /// tests (`nil` = use the real workspace value). Setting it does NOT
    /// reconcile by itself — tests post
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on
    /// `NSWorkspace.shared.notificationCenter` exactly as the OS would, so the
    /// notification path itself is what's under test.
    public var test_reduceMotionOverride: Bool?

    /// The ring form currently rendered (structural hook — derived from the same
    /// `state` the layer renders from, so it can never drift from the drawing).
    public var test_form: Form { form }

    /// Whether the connecting/reconnecting breathing pulse is currently installed
    /// (connecting AND on screen AND Reduce Motion off) — lets tests assert the
    /// animation is present without reaching into Core Animation internals.
    public var test_isBreathing: Bool { ringLayer.animation(forKey: Self.breathKey) != nil }

    /// The ring's current stroke color (resolved against the effective
    /// appearance) — lets tests assert connected vs failed use different hues.
    public var test_strokeColor: NSColor? {
        guard let cg = ringLayer.strokeColor else { return nil }
        return NSColor(cgColor: cg)
    }

    /// The ring's current stroke width — lets tests assert the failed ring's
    /// heavier weight vs the connected ring.
    public var test_lineWidth: CGFloat { ringLayer.lineWidth }

    /// Whether the ring is currently dashed (the connecting "incomplete" form),
    /// including under Reduce Motion where the dash survives without the pulse.
    public var test_isDashed: Bool { (ringLayer.lineDashPattern?.isEmpty == false) }
}
