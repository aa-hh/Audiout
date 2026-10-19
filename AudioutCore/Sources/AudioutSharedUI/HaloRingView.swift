// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// The **connection halo ring** (Warm Signal v3 §3.2): a ring drawn AROUND the
/// device icon that carries the connection lifecycle. The corner position the
/// retired connection dot held now hosts the gold route-armed dot
/// (`RouteArmedDotView`, spec §3.3) — this view owns ONLY the connection
/// channel, driven by `Device.connectionState` alone (teal is retired, so
/// there is no routing/teal rung on the ring — spec §0 decision c / §3.1).
///
/// The FORM carries the state, not just the color — so the ladder survives
/// Reduce Motion (the **blocking** stress-test break §8.2):
///
/// - `.off` → **no ring** (hidden — discovered, nothing to report), UNLESS
///   the caller passes `restingArmed: true` (Main Audio only — see
///   `apply(_:restingArmed:)`), in which case it renders the **resting**
///   form instead.
/// - `.connecting` / `.reconnecting` → **dashed `rim` ring, breathing**
///   (opacity + radius pulse that only ever GROWS the ring outward from its
///   resting radius, so it can never touch the glyph). Under Reduce Motion
///   the dashed FORM survives, STATIC (no animation) — "incomplete", legible
///   frozen. The rail's connecting node is a plain gold circle and the
///   line stops short of it, so the break carries the state, not the colour.
/// - `.connected` → **solid quiet ring**, `Tokens.Color.rim`.
///   Tested ≥3:1 vs the panel at `haloRingDiameter`, both themes.
/// - `.failed` → **red solid ring**, `failure` token.
/// - **`.resting`** (Main Audio only) — a rail exists (speakers are selected
///   and not failed) but no member has connected, so `connectionState` is
///   `.off` (the `mainOutConnectionState` fallthrough is correct and
///   untouched). Without this form the rail's curve into the ring
///   (`BusRailOverlayView`) lands on a hidden ring and reads as unfinished.
///   Wears the rail's own ink through `joinsSpine`, exactly as `.connected`
///   does. Since the line went always-gold (owner's ruling, 2026-10-04) the
///   ring alone no longer tells the two apart; the status dot in its gap
///   still follows whether the spine is live.
///
/// Every form strokes at the one shared `PopoverColumnGrid.ringStrokeWidth`
/// (owner's ruling, 2026-10-03): weight never carries state.
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
///
/// **Permanent gap (ported from the iOS companion's ring treatment):** every
/// drawn form is an open arc, not a full circle — a fixed 70°
/// (`haloRingGapWidth`) dead zone centered on the gold route-armed dot's
/// corner seat (`haloRingGapCenterAngle`) so the dot sits IN the ring's gap
/// rather than nearly touching the stroke, separated only by its own
/// punch-out border. The gap's geometry never varies by state or form, and
/// whenever a ring is drawn its gap holds the dot (`cutoutDot`).
public final class HaloRingView: NSView {

    /// Which ring form is currently rendered — mirrors the four connection
    /// renderings so a row can assert the ring without reaching into the layer.
    public enum Form: Equatable {
        /// `.off` — no ring (hidden).
        case none
        /// `.connecting` / `.reconnecting` — dashed, breathing (static under
        /// Reduce Motion).
        case connecting
        /// `.connected` — solid quiet ring, `rim`.
        case connected
        /// `.failed` — solid red ring, `failure`.
        case failed
        /// Main Audio only: the rail exists but nothing has connected
        /// (`state == .off && restingArmed == true`) — the rail's own ink.
        case resting
    }

    private let ringLayer = CAShapeLayer()
    private static let breathKey = "haloRing.breathe"
    private static let receiveKey = "haloRing.receive"
    /// The transient rail-arrival bloom currently playing, if any. Nothing
    /// exists at rest — it is mounted by ``receiveRailPulse()`` and removed by
    /// its own run-loop timer (or any cancel).
    private var receiveLayer: CAShapeLayer?

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
    /// Makes the **connected** form wear the rail's SPINE TONE instead of the
    /// shared `rim` token (Warm Signal nitpicks): the Main Audio ring
    /// is the rail's terminus, so its connected color must match the tone the
    /// rail's curve is drawn in for the join to read as one continuous line
    /// rather than two different colors touching. `false` (every device row)
    /// keeps the shared `Tokens.Color.rim`, untouched by the accent dial.
    ///
    /// It is a flag, never a resolved color: the tone itself comes from
    /// `Tokens.Color.spineTone` at stamp time — the same token
    /// `BusRailOverlayView` reads for the hook — so the ring and the rail
    /// cannot pick different tokens, and a dial change re-resolves both.
    public var joinsSpine = false {
        didSet { updateLayerAppearance() }
    }
    /// The status dot sitting in this ring's gap. Every stamp hands it the
    /// ring's own stroke token (or `nil` while no ring is drawn), so the dot's
    /// hollow ring reads from the same resolution as the ring and a ring with
    /// no dot, or a dot with no ring, cannot happen.
    public weak var cutoutDot: RouteArmedDotView?

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
        // The accent dial is the THIRD live re-resolution trigger, alongside
        // appearance and the a11y options: the ring's stroke is a stamped
        // static `CGColor`, so — unlike the `draw(_:)`-based rail it joins —
        // a dial change leaves it showing the old accent until something
        // re-stamps it. Re-stamping here is what keeps the ring and the rail's
        // hook one continuous line THROUGH the flip, with no rebuild.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accentStyleDidChange),
            name: Tokens.accentStyleDidChangeNotification,
            object: nil)
    }

    /// A live accent-dial change: re-stamp the stroke so a spine-toned ring
    /// follows the dial in the same instant the rail does.
    @objc private func accentStyleDidChange() {
        updateLayerAppearance()
        // The transient bloom stamped the OLD accent's `glow`; it can't
        // re-tint mid-flight, so it drops rather than finish in a dead hue.
        cancelReceiveBloom()
    }

    /// A mid-session Reduce Motion / Increase Contrast toggle: re-stamp colors
    /// (the Increase-Contrast token variants resolve live) and re-reconcile the
    /// breathing pulse (a connecting ring goes static under Reduce Motion, and
    /// resumes breathing the moment it's switched back off) — spec §3.2's
    /// dashed-form guarantee holds through the toggle, not just across `apply`s.
    @objc private func accessibilityDisplayOptionsDidChange() {
        updateLayerAppearance()
        reconcileBreathing()
        // Reduce Motion turning ON strips an in-flight bloom, same as the rail
        // drops its bead — the ring lands on its settled stroke instantly.
        if reduceMotion { cancelReceiveBloom() }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Point the ring at a connection state. Fully resets the layer (color,
    /// stroke, dashing, visibility, animation) so a repeated `apply` after an
    /// unrelated re-render can never leave a stale breathing animation running
    /// under a since-changed state (the same idempotent-reset discipline the
    /// retired corner dot used).
    /// - Parameter restingArmed: Main Audio's host-computed bit (default
    ///   `false`, a no-op everywhere else): when `state == .off`, `true` here
    ///   renders the `.resting` form instead of hiding the ring — the caller
    ///   passes whether a rail exists at all. Every device row call site omits
    ///   this, so their `.off` handling is unchanged.
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
        case .connecting, .reconnecting, .awaitingPassword: return .connecting
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

    /// Resolve the stroke color + dash pattern for the current form and stamp
    /// them on the layer against the current effective appearance. `CALayer`
    /// colors are static `CGColor`s, so this must re-run on every appearance
    /// change, not just at build time.
    private func updateLayerAppearance() {
        let strokeToken: NSColor
        switch form {
        case .none:
            // Hidden anyway; nothing meaningful to stamp.
            strokeToken = .clear
        case .connecting:
            strokeToken = Tokens.Color.rim
        case .connected, .resting:
            // The resting ring appears exactly when the rail does, so it wears
            // the rail's own ink, as Main Audio's connected ring does. A grey
            // rim there while the wire curving into it was gold read as two
            // unrelated things touching.
            strokeToken = joinsSpine ? Tokens.Color.spineTone : Tokens.Color.rim
        case .failed:
            strokeToken = Tokens.Color.failure
        }
        let dashed = form == .connecting
        ringLayer.lineWidth = form == .none ? 0 : PopoverColumnGrid.ringStrokeWidth
        ringLayer.lineDashPattern = dashed
            ? [NSNumber(value: Double(PopoverColumnGrid.haloRingDashLength)),
               NSNumber(value: Double(PopoverColumnGrid.haloRingDashGap))]
            : nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ringLayer.strokeColor = strokeToken.cgColor
        }
        cutoutDot?.ringColor = form == .none ? nil : strokeToken
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerAppearance()
    }

    /// The visible ring circle (the stroke centerline) inscribed in the view's
    /// box — one definition shared by the settled ring and the transient
    /// rail-arrival bloom, so the bloom can never sit off the ring it belongs to.
    private var ringRect: NSRect {
        let diameter = diameterOverride ?? PopoverColumnGrid.haloRingDiameter
        return NSRect(x: bounds.midX - diameter / 2,
                      y: bounds.midY - diameter / 2,
                      width: diameter, height: diameter)
    }

    /// The ring's own path: the circle inscribed in `rect`, open across the
    /// permanent gap centered on `haloRingGapCenterAngle`. Shared by the
    /// settled ring (`layout()`) and the rail-arrival bloom
    /// (`receiveRailPulse()`) so the two can never disagree about where the
    /// gap sits. `HaloRingView` is a plain, non-flipped `NSView`, so this is a
    /// y-up layer: the arc sweeps with INCREASING angle (mathematically
    /// counterclockwise), which is what `clockwise: false` draws here — the
    /// opposite of the visual sense `clockwise` carries in a flipped
    /// (y-down) view. Proven by `HaloRingGapTests`, which asserts the LONG
    /// (290°) side is what actually gets stroked.
    private func ringPath(in rect: NSRect, growth: CGFloat = 0) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 + growth
        let halfGap = PopoverColumnGrid.haloRingGapWidth / 2
        let startAngle = PopoverColumnGrid.haloRingGapCenterAngle + halfGap
        let endAngle = startAngle + (2 * .pi - PopoverColumnGrid.haloRingGapWidth)
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }

    public override func layout() {
        super.layout()
        // The visible ring circle sits centered in the view at `haloRingDiameter`
        // (the stroke centerline), regardless of the view's own box size (which
        // matches the 26 pt icon box). The layer fills the view; the path is the
        // inscribed circle, open across the permanent gap.
        ringLayer.frame = bounds
        ringLayer.path = ringPath(in: ringRect)
        // The breathing pulse animates between paths built from the ring's
        // box; only a box that actually moved rebuilds it, so an unrelated
        // layout pass never restarts a breath.
        if ringRect != breathRect {
            ringLayer.removeAnimation(forKey: Self.breathKey)
            reconcileBreathing()
        }
    }

    /// The ring box the installed breathing pulse was built from.
    private var breathRect: NSRect = .zero

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

        // The radius breathes OUT from the resting circle and back, never in:
        // a ring that shrank toward the glyph would cut through it. Animating
        // the path (not `transform.scale`) keeps the stroke at
        // `ringStrokeWidth` and the dashes at their own length through the
        // whole breath.
        let radius = CABasicAnimation(keyPath: "path")
        radius.fromValue = ringPath(in: ringRect, growth: PopoverColumnGrid.haloRingBreathGrowth)
        radius.toValue = ringPath(in: ringRect)

        breathRect = ringRect

        let group = CAAnimationGroup()
        group.animations = [opacity, radius]
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
        // A remount renders settled — a bloom from the previous mount dies with it.
        cancelReceiveBloom()
    }

    // MARK: Rail-arrival bloom (the ring receives the bead)

    /// The receiving end of the rail's connect pulse (`BusRailOverlayView`):
    /// the bead melts INTO this ring, so the acknowledgment is the RING's own
    /// stroke blooming — a `glow`-toned copy of the ring's circle that starts
    /// a touch wide of the circumference and CONTRACTS onto it as it fades.
    /// A stroke, never a shadow: the instruments carry no blooms. Light
    /// spreading inward, not an explosion outward, and quiet (peak opacity
    /// well under 1): the desk taking the room in.
    ///
    /// Same settled-model contract as every other transient here
    /// (`RouteArmedDotView`, the rail's own bead): the bloom layer's MODEL
    /// opacity stays 0 (invisible) and only its presentation plays, so a
    /// `cacheDisplay` at any instant captures the settled ring. Self-removing
    /// on a run-loop timer — CA completion blocks never fire without an
    /// app-driven commit loop — so nothing exists at rest.
    ///
    /// Gone entirely under Reduce Motion, and off-screen (no window = nothing
    /// to acknowledge).
    public func receiveRailPulse() {
        guard window != nil, !reduceMotion, let hostLayer = layer else { return }
        test_receivedRailPulses += 1
        cancelReceiveBloom()

        let bloom = CAShapeLayer()
        bloom.frame = bounds
        // Same inscribed circle (and same permanent gap) as the settled ring,
        // and the layer's own centre is the ring's centre — so the scale
        // animation contracts ONTO the stroke rather than sliding the halo
        // across the view.
        bloom.path = ringPath(in: ringRect)
        bloom.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.fillColor = nil
        bloom.lineWidth = ringLayer.lineWidth * 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bloom.strokeColor = Tokens.Color.glow.cgColor
        }
        bloom.opacity = 0
        hostLayer.addSublayer(bloom)
        receiveLayer = bloom

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0
        let settle = CABasicAnimation(keyPath: "transform.scale")
        settle.fromValue = 1.22
        settle.toValue = 1.0
        let receive = CAAnimationGroup()
        receive.animations = [fade, settle]
        receive.duration = PopoverColumnGrid.railConnectPulseArrivalDuration
        receive.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bloom.add(receive, forKey: Self.receiveKey)

        Timer.scheduledTimer(withTimeInterval: receive.duration, repeats: false) { [weak self, weak bloom] _ in
            MainActor.assumeIsolated {
                bloom?.removeFromSuperlayer()
                if let self, self.receiveLayer === bloom { self.receiveLayer = nil }
            }
        }
    }

    /// Drop an in-flight bloom (Reduce Motion turning on, an accent-dial change
    /// its stamped `CGColor` can't follow, a remount, or a replacement).
    private func cancelReceiveBloom() {
        receiveLayer?.removeFromSuperlayer()
        receiveLayer = nil
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

    /// The ring's current stroke width.
    public var test_lineWidth: CGFloat { ringLayer.lineWidth }

    /// The radii the breathing pulse's path animation moves between (empty
    /// when not breathing) — read off the installed animation itself.
    public var test_breathRadii: [CGFloat] {
        guard let group = ringLayer.animation(forKey: Self.breathKey) as? CAAnimationGroup,
              let path = group.animations?.first(where: { ($0 as? CABasicAnimation)?.keyPath == "path" })
                as? CABasicAnimation
        else { return [] }
        return [path.fromValue, path.toValue].compactMap { value in
            guard let value, CFGetTypeID(value as CFTypeRef) == CGPath.typeID else { return nil }
            return (value as! CGPath).boundingBoxOfPath.width / 2
        }
    }

    /// The resting ring's radius (stroke centreline).
    public var test_restingRadius: CGFloat { ringRect.width / 2 }

    /// Whether the rail-arrival bloom is currently mounted on the ring
    /// (present the instant ``receiveRailPulse()`` returns — no run loop needed).
    public var test_isReceivingRailPulse: Bool { receiveLayer != nil }

    /// How many rail-arrival blooms have PLAYED. Survives the bloom's own
    /// (fast, headless-timing-dependent) self-removal, so tests assert on this
    /// rather than racing the transient layer.
    public private(set) var test_receivedRailPulses = 0

    /// The bloom's MODEL opacity — the settled-model-layer contract says it is
    /// always 0 (invisible) while the presentation plays.
    public var test_receiveModelOpacity: Float? { receiveLayer?.opacity }

    /// Whether the ring is currently dashed (the connecting "incomplete" form),
    /// including under Reduce Motion where the dash survives without the pulse.
    public var test_isDashed: Bool { (ringLayer.lineDashPattern?.isEmpty == false) }

    /// The exact path the ring layer strokes (structural hook — the same
    /// `CGPath` `layout()` stamps, so it can never drift from the drawing).
    public var test_ringPath: CGPath? { ringLayer.path }
}
