// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **Warm Signal fader skin** (spec §5 "we redraw only the slider
/// track/knob look"): a DRAWING-ONLY `NSSliderCell` subclass installed on the
/// volume sliders in `DeviceRowView`, `MainOutRowView`, and `AppRowView`. Only
/// `drawBar(inside:flipped:)` and `drawKnob(_:)` are overridden — tracking,
/// keyboard operation, scroll-wheel, `isContinuous`, VoiceOver, and the focus
/// ring all come from the un-subclassed `NSSliderCell`/`NSSlider` machinery,
/// untouched (the same "only the DRAWING changes" contract as
/// `MembershipBusView` over its checkbox, spec §4.8).
///
/// What it draws:
/// - **Track**: a flat recessed trough (`PopoverColumnGrid.faderTrackHeight`
///   ≈ 5 pt) filled with the `well` inset token — the exact surface spec §1
///   reserves for "slider track trough" — with a `rim` edge (load-bearing for
///   the recess: 4.38:1 dark / 4.15:1 light vs `well`) and a 1 px inner top
///   shade (drawn, not a layer shadow) so the trough reads inset.
/// - **Filled portion** (min side → thumb): the gold gradient ONLY while the
///   row is **route-armed** (the same §3.3 model predicate the row already
///   pushes to its `RouteArmedDotView`; `AppRowView` uses its routed ∧
///   running equivalent). The gradient's dim end is `ember` pre-blended
///   halfway toward `gold` (`armedDimEndGoldBlend`) so the low-value end
///   still reads against the trough (6.96:1 dark / 3.97:1 light vs `well`).
///   Unarmed or disabled rows fill with the cool `rim` chrome (4.38:1 dark /
///   4.15:1 light vs `well`) — gold stays a signal, never decoration (house
///   rule: the gold budget).
/// - **Thumb**: a capsule cap (`faderThumbWidth × faderThumbHeight`
///   ≈ 10×17 pt) replacing the stock white circle — a `raised` body (1.29:1
///   on the dark trough; the flat ground itself in light) read entirely by
///   its `rim` edge (3.39:1 on the dark body, 4.78:1 on the light ground). It
///   is placed along the track, not the stock knob rect, so at the maximum its
///   trailing edge lands on the track's end and at the minimum its leading
///   edge lands on the start — no strip of trough past the handle.
/// - **Halo room** (`haloRoom`): the trough can stop short of the slider's
///   frame at both ends, so a host that widens its slider by the same amount
///   keeps the trough in place and gains room for the pending glow's halo.
/// - **Pending glow** (Cast volume not yet audible, `isPendingApply`): the
///   thumb lights from inside, with three flat halo rings (1/2/3 pt) and a
///   body blended toward the light: warm white in dark, `glow` in light. It
///   breathes on `PendingPulse`'s curve from a timer the cell owns, rises
///   and goes out when the hold ends, and holds at 0.7 under Reduce Motion.
///
/// Every color goes through `Tokens`, resolved at DRAW time under the
/// control's effective appearance (AppKit sets the drawing appearance before
/// calling the cell), so light/dark, Increase Contrast, and the accent dial
/// (spec §1.3 — `gold`/`ember` remap) all land with no
/// code here knowing about them. Apart from the pending glow's breathing the
/// drawing is steady state with no layers, so `cacheDisplay` snapshots are
/// byte-deterministic (and the glow is too under Reduce Motion).
public final class WarmFaderCell: NSSliderCell {

    /// Whether the OWNING row is currently route-armed (spec §3.3) — the exact
    /// boolean the row computes for its `RouteArmedDotView` (`AppRowView`:
    /// routed ∧ running). The row re-stamps this on every `apply`; the engaged
    /// gold gradient renders iff this is true AND the control is enabled.
    public var isRouteArmed: Bool = false {
        didSet {
            if isRouteArmed != oldValue { controlView?.needsDisplay = true }
        }
    }

    /// Whether the owning row's controls are **muted-unconnected** (Warm Signal
    /// v4 §Call-1): a connecting/pending or unavailable/failed device renders its
    /// fader desaturated + lower-contrast — "not adjustable right now" — while a
    /// connected member is full-gold. The row re-stamps this on every `apply`;
    /// it dims the interior exactly like the disabled state without disabling the
    /// control (the neutral fill already applies, since a non-connected row is
    /// never route-armed).
    public var isMutedControl: Bool = false {
        didSet {
            if isMutedControl != oldValue { controlView?.needsDisplay = true }
        }
    }

    /// Whether the owning row's volume/mute gesture is still pending its
    /// feed-gain apply moment (Cast fixed-volume receivers only — the row
    /// re-stamps this on every `apply`). While true, an armed thumb glows
    /// and breathes: the "not yet landed" signal.
    public var isPendingApply: Bool = false {
        didSet {
            guard isPendingApply != oldValue else { return }
            let now = CACurrentMediaTime()
            if isPendingApply {
                pulse.begin(at: now)
            } else {
                pulse.finish(at: now, reduceMotion: reduceMotion)
            }
            reconcilePulseTimer()
            onPulse?(pulseStrength)
            controlView?.needsDisplay = true
        }
    }

    /// Clear space left between the slider's frame and each end of the
    /// trough, so the pending glow's 3 pt halo is not cut off when the thumb
    /// sits at 0 % or 100 %. A host that sets it widens its slider by twice
    /// this, keeping the trough where it was. `DeviceRowView` sets 3; the
    /// other faders never glow and leave it 0.
    public var haloRoom: CGFloat = 0 {
        didSet {
            if haloRoom != oldValue { controlView?.needsDisplay = true }
        }
    }

    /// Drop a pending hold at once, with no arrival: for a surface that is
    /// going away, where a rise-and-fade nobody sees would only keep the
    /// timer running.
    public func cancelPendingHold() {
        isPendingApply = false
        pulse = PendingPulse()
        reconcilePulseTimer()
        onPulse?(nil)
        controlView?.needsDisplay = true
    }

    /// Called with the glow's strength on every pulse tick and on each
    /// pending edge (`nil` once the light is out), so the row's readout
    /// breathes in step with the thumb.
    public var onPulse: ((CGFloat?) -> Void)?

    private var pulse = PendingPulse()

    /// Repaints the glow. Runs while the hold breathes and through its
    /// arrival; Reduce Motion's static glow needs no frames.
    private var pulseTimer: Timer?

    deinit { pulseTimer?.invalidate() }

    private func reconcilePulseTimer() {
        let needsFrames = pulse.isArriving || (isPendingApply && !reduceMotion)
        guard needsFrames else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            return
        }
        guard pulseTimer == nil else { return }
        let timer = Timer(timeInterval: PendingPulse.frameInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let strength = self.pulseStrength
            self.onPulse?(strength)
            self.controlView?.needsDisplay = true
            if strength == nil { self.reconcilePulseTimer() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The glow's strength right now, or nil when it is out.
    var pulseStrength: CGFloat? {
        pulse.value(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
    }

    // MARK: Drawing

    public override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = trackRect(inside: rect)
        let radius = PopoverColumnGrid.faderTrackCornerRadius
        let trough = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)

        // Recessed trough: the `well` inset fill…
        Tokens.Color.well.setFill()
        trough.fill()

        // …an inner top shade for the inset feel (drawn, not a layer shadow:
        // a 1 px band clipped to the trough along its visual top edge)…
        NSGraphicsContext.current?.saveGraphicsState()
        trough.addClip()
        Tokens.Color.shadow.withAlphaComponent(Self.insetShadeAlpha).setFill()
        let topEdgeY = flipped ? track.minY : track.maxY - Self.hairlineWidth
        NSRect(x: track.minX, y: topEdgeY,
               width: track.width, height: Self.hairlineWidth).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // …then the filled portion, min-value side up to a point DERIVED FROM
        // THE VALUE — not the knob's center. Stock `NSSliderCell` insets the
        // knob's travel by half the stock knob width at each end (measured on
        // a 150 pt regular slider, min 0 / max 100: knob center at 10.0 at
        // value 0, 140.0 at value 100), so anchoring the fill to `knobRect`
        // left it 10 pt short of the trough at 100% — and painted a phantom
        // 10 pt fill at 0%. Nothing on record defends that; it was inherited
        // AppKit geometry, not a decision.
        let fillRect = self.fillRect(track: track)
        if fillRect.width > 0 {
            NSGraphicsContext.current?.saveGraphicsState()
            trough.addClip()
            if isRouteArmed && isEnabled {
                // Engaged: the gold instrument gradient (accent-dial aware via
                // the tokens themselves). The dim end
                // is `ember` pre-blended toward `gold` so the low-value end of
                // the fill clears the trough (ratios in the header doc);
                // blending two live tokens at draw time keeps the accent dial
                // and IC variants authoritative (same derivation idiom as the
                // thumb highlight).
                let dimEnd = Tokens.Color.ember
                    .blended(withFraction: Self.armedDimEndGoldBlend,
                             of: Tokens.Color.gold) ?? Tokens.Color.ember
                // A pending Cast apply keeps this solid fill; the hold shows
                // on the thumb instead (2026-10-06, owner's call). It used to
                // dash this fill because flat tints were live-invisible on the
                // 5 pt track; the 10×17 pt thumb has room to carry a glow.
                if let gradient = NSGradient(starting: dimEnd,
                                             ending: Tokens.Color.gold) {
                    let leftToRight = fillRect.minX == track.minX
                    gradient.draw(in: fillRect, angle: leftToRight ? 0 : 180)
                }
            } else {
                // Unarmed (or disabled — enabled-ness also dims via
                // `interiorAlpha` below): the hue-neutral warm fill. Gold is a
                // signal; a level alone is not.
                Tokens.Color.rim
                    .withAlphaComponent(interiorAlpha).setFill()
                fillRect.fill()
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Trough rim (`rim` — the recess's load-bearing edge; `hairline`
        // measured 1.21:1 vs `well`, invisible), inset half a hairline so the
        // stroke stays inside.
        Tokens.Color.rim.withAlphaComponent(interiorAlpha).setStroke()
        let rimPath = NSBezierPath(
            roundedRect: track.insetBy(dx: Self.hairlineWidth / 2, dy: Self.hairlineWidth / 2),
            xRadius: radius, yRadius: radius)
        rimPath.lineWidth = Self.hairlineWidth
        rimPath.stroke()
    }

    /// Stock `NSSliderCell` computes the knob's vertical position from its own
    /// (much taller) default knob geometry, which sits it visibly LOW against
    /// our thin (`faderTrackHeight` ≈ 5 pt) recessed trough — a real drawing
    /// bug (v4.1 polish item 5). Re-centering only the Y here, on the same
    /// `trackRect` midline `drawBar` fills against, keeps X (the value
    /// position along the track) and width entirely stock.
    public override func knobRect(flipped: Bool) -> NSRect {
        var rect = super.knobRect(flipped: flipped)
        let track = trackRect(inside: barRect(flipped: flipped))
        rect.origin.y = (track.midY - rect.height / 2).rounded()
        return rect
    }

    public override func drawKnob(_ knobRect: NSRect) {
        let size = NSSize(width: PopoverColumnGrid.faderThumbWidth,
                          height: PopoverColumnGrid.faderThumbHeight)
        // The thumb is placed on the TRACK, not on `knobRect`: its leading
        // edge lands on the track's start at the minimum and its trailing
        // edge on the track's end at the maximum, so no trough shows past the
        // handle. Stock `knobRect` (20 pt on a 150 pt slider, 0…20 at the
        // minimum, 130…150 at the maximum) is the rect `NSSliderCell` maps
        // mouse tracking against and stays untouched; with `haloRoom` the
        // two differ by that many points at the extremes, in paint only.
        let track = trackRect(inside: barRect(flipped: controlView?.isFlipped ?? false))
        let offset = (controlView?.userInterfaceLayoutDirection == .rightToLeft)
            ? 1 - valueFraction : valueFraction
        let thumb = NSRect(x: (track.minX + (track.width - size.width) * offset).rounded(),
                           y: (knobRect.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        let radius = PopoverColumnGrid.faderThumbCornerRadius
        let path = NSBezierPath(roundedRect: thumb, xRadius: radius, yRadius: radius)

        // The raised cap body, lit from inside while a Cast apply is pending
        // and through its arrival. Flat fills, never an `NSShadow` (folder
        // rule). The 3 pt outer ring needs a 23 pt slider; `DeviceRowView`
        // gives its slider 24.
        var body = Tokens.Color.raised
        if isRouteArmed && isEnabled, let g = pulseStrength {
            let appearance = NSAppearance.currentDrawing()
            let dark = PendingPulse.isDark(appearance)
            let light = PendingPulse.light(in: appearance)
            let rings = dark ? Self.pendingHaloAlphasDark : Self.pendingHaloAlphasLight
            for (index, alpha) in rings.enumerated().reversed() {
                let outset = CGFloat(index + 1)
                light.withAlphaComponent(alpha * g).setFill()
                NSBezierPath(roundedRect: thumb.insetBy(dx: -outset, dy: -outset),
                             xRadius: radius + outset, yRadius: radius + outset).fill()
            }
            let toward = (dark ? Self.pendingBodyBlendDark : Self.pendingBodyBlendLight) * g
            body = body.blended(withFraction: toward, of: light) ?? body
        }
        body.withAlphaComponent(interiorAlpha).setFill()
        path.fill()

        // …read by its `rim` edge, the one thing that defines it against both
        // the trough and the gold fill (the body alone measures 1.29:1 dark
        // and equals the ground in light).
        Tokens.Color.rim.withAlphaComponent(interiorAlpha).setStroke()
        let outline = NSBezierPath(
            roundedRect: thumb.insetBy(dx: Self.hairlineWidth / 2, dy: Self.hairlineWidth / 2),
            xRadius: radius, yRadius: radius)
        outline.lineWidth = Self.hairlineWidth
        outline.stroke()
    }

    // MARK: Geometry / constants

    /// The filled portion's rect for the CURRENT slider value, from the
    /// min-value end of `track` to a point at `fraction` of the track's
    /// width — factored out so `drawBar` and `test_fillRect` below compute
    /// IDENTICAL geometry. Mirrored for right-to-left: the min-value end
    /// sits at `track.maxX` and the fill grows leftward.
    private func fillRect(track: NSRect) -> NSRect {
        let fraction = valueFraction
        if controlView?.userInterfaceLayoutDirection == .rightToLeft {
            let fillStartX = track.maxX - track.width * fraction
            return NSRect(x: fillStartX, y: track.minY,
                          width: max(0, track.maxX - fillStartX), height: track.height)
        } else {
            let fillEndX = track.minX + track.width * fraction
            return NSRect(x: track.minX, y: track.minY,
                          width: max(0, fillEndX - track.minX), height: track.height)
        }
    }

    /// How far along its range the current value sits, 0…1 — the one number
    /// the fill's end and the thumb's position both derive from, so they can
    /// never disagree about where the value is.
    private var valueFraction: CGFloat {
        guard maxValue > minValue else { return 0 }
        let fraction = (doubleValue - minValue) / (maxValue - minValue)
        return CGFloat(min(1, max(0, fraction)))
    }

    /// The recessed trough: `faderTrackHeight` tall, vertically centered in
    /// the cell's bar rect, full width less `haloRoom` at each end.
    private func trackRect(inside rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + haloRoom,
               y: rect.midY - PopoverColumnGrid.faderTrackHeight / 2,
               width: max(0, rect.width - 2 * haloRoom),
               height: PopoverColumnGrid.faderTrackHeight)
    }

    /// A disabled OR muted-unconnected (v4 §Call-1) fader dims its interior
    /// drawing (fill, rim, thumb) instead of greying per-part — mirrors how the
    /// row already dims its `%` readout in lockstep with `slider.isEnabled`.
    private var interiorAlpha: CGFloat {
        (isEnabled && !isMutedControl) ? 1.0 : PopoverColumnGrid.faderDisabledAlpha
    }

    /// 1 px in points at 1x — hairline shading/highlight/outline width.
    private static let hairlineWidth: CGFloat = 1
    /// Alpha of the trough's inner top shade (`shadow` token over `well`).
    private static let insetShadeAlpha: CGFloat = 0.18
    /// How far the armed gradient's dim end pre-blends `ember` toward `gold`
    /// (0 = raw ember). At 0.5 the dim end measures 6.96:1 (dark) / 3.97:1
    /// (light) vs `well` — raw ember measured 3.86:1 / 1.98:1, muddy at the
    /// track's low-value end in light.
    private static let armedDimEndGoldBlend: CGFloat = 0.5
    /// The pending glow's halo alphas at full strength for the rings 1, 2
    /// and 3 pt out, and how far the body blends toward the light. Light
    /// mode runs stronger because `glow` on the near-white ground is the
    /// faintest pairing.
    private static let pendingHaloAlphasDark: [CGFloat] = [0.34, 0.16, 0.07]
    private static let pendingHaloAlphasLight: [CGFloat] = [0.50, 0.26, 0.11]
    private static let pendingBodyBlendDark: CGFloat = 0.85
    private static let pendingBodyBlendLight: CGFloat = 0.42

    // MARK: Test-support hooks

    /// Whether the ENGAGED (gold-gradient) fill would render right now —
    /// armed ∧ enabled, the exact gate `drawBar` uses, so tests can't drift
    /// from the pixels.
    public var test_isEngagedFill: Bool { isRouteArmed && isEnabled }
    public var test_isPendingGlow: Bool { isPendingApply && isRouteArmed && isEnabled }
    /// Stands in for the system Reduce Motion setting; `true` holds the
    /// glow at 0.7 so a pending render is deterministic.
    public var test_reduceMotionOverride: Bool? {
        didSet { reconcilePulseTimer() }
    }

    /// The fill rect `drawBar` would paint for `track`, at the cell's current
    /// `doubleValue`/`minValue`/`maxValue` — same geometry, so a test can
    /// assert the fill reaches the track's real ends without going through
    /// the drawing chain.
    public func test_fillRect(track: NSRect) -> NSRect { fillRect(track: track) }

    /// The trough rect `drawBar` paints, in the slider's coordinates.
    public var test_trackRect: NSRect {
        trackRect(inside: barRect(flipped: controlView?.isFlipped ?? false))
    }
    public var test_isPulseTimerRunning: Bool { pulseTimer != nil }
}
