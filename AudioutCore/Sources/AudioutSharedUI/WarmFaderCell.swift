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
///   slides inside the stock knob rect rather than centring on it, so at the
///   maximum its trailing edge lands on the track's end and at the minimum its
///   leading edge lands on the start — no strip of trough past the handle.
///
/// Every color goes through `Tokens`, resolved at DRAW time under the
/// control's effective appearance (AppKit sets the drawing appearance before
/// calling the cell), so light/dark, Increase Contrast, and the accent dial
/// (spec §1.3 — `gold`/`ember` remap) all land with no
/// code here knowing about them. The drawing is steady state — no animation,
/// no layers — so `cacheDisplay` snapshots are byte-deterministic.
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
    /// re-stamps this on every `apply`). While true, the engaged fill draws
    /// as DASHED gold segments — the app's connecting/"in flight" vocabulary
    /// — instead of the solid gradient: the "not yet landed" signal.
    public var isPendingApply: Bool = false {
        didSet {
            if isPendingApply != oldValue { controlView?.needsDisplay = true }
        }
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
                if isPendingApply {
                    // Pending Cast feed-gain apply: the level is real but not
                    // audible yet, so the gold renders in the app's "in
                    // flight" vocabulary — DASHED, the same form the
                    // connecting halo ring and bus node already use — until
                    // the lag elapses and the solid bar returns. Two flat
                    // tones were tried first and were LIVE-INVISIBLE at this
                    // 5 pt track size (2026-08-23, mock-window pixel probe):
                    // the ember-blend is indistinguishable from the gradient,
                    // and the unarmed neutral is a same-luminance warm fill —
                    // byte-identical to every unarmed row's fader, so a tint
                    // swap reads as "no change". A broken bar cannot be
                    // mistaken for a solid one. Dash phase anchors to the
                    // TRACK, not the fill, so segments hold still while the
                    // thumb drags. Static drawing — no animation, so Reduce
                    // Motion and snapshot determinism are untouched.
                    let dashes = NSBezierPath()
                    var x = track.minX
                    while x < fillRect.maxX {
                        dashes.appendRect(NSRect(x: x, y: track.minY,
                                                 width: Self.pendingDashLength,
                                                 height: track.height))
                        x += Self.pendingDashLength + Self.pendingDashGap
                    }
                    NSBezierPath(rect: fillRect).addClip()
                    dashes.addClip()
                    if let gradient = NSGradient(starting: dimEnd,
                                                 ending: Tokens.Color.gold) {
                        let leftToRight = fillRect.minX == track.minX
                        gradient.draw(in: fillRect, angle: leftToRight ? 0 : 180)
                    }
                } else if let gradient = NSGradient(starting: dimEnd,
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
        // The thumb slides INSIDE `knobRect` rather than centring on it. Stock
        // `knobRect` is `knobThickness` wide (20 pt on a 150 pt regular slider)
        // and its EDGES already sit flush with the track at both extremes —
        // 0…20 at the minimum, 130…150 at the maximum. Centring our narrower
        // 10 pt thumb on that rect leaves 5 pt of trough showing past the
        // handle at each end; offsetting it by the value's fraction of the
        // slack lands the thumb's trailing edge on the track's end at the
        // maximum and its leading edge on the start at the minimum. `knobRect`
        // itself — the rect `NSSliderCell` maps mouse tracking against — is
        // untouched, so this moves paint only.
        let slack = max(0, knobRect.width - size.width)
        let offset = (controlView?.userInterfaceLayoutDirection == .rightToLeft)
            ? 1 - valueFraction : valueFraction
        let thumb = NSRect(x: (knobRect.minX + slack * offset).rounded(),
                           y: (knobRect.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        let radius = PopoverColumnGrid.faderThumbCornerRadius
        let path = NSBezierPath(roundedRect: thumb, xRadius: radius, yRadius: radius)

        // The raised cap body…
        Tokens.Color.raised.withAlphaComponent(interiorAlpha).setFill()
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
    /// the cell's bar rect, full width.
    private func trackRect(inside rect: NSRect) -> NSRect {
        NSRect(x: rect.minX,
               y: rect.midY - PopoverColumnGrid.faderTrackHeight / 2,
               width: rect.width,
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
    /// The pending-apply fill's dash geometry: painted / gap run lengths in
    /// points. 6-on/4-off gives a ~90 pt fill about nine clearly separated
    /// gold segments — coarse enough to read at the 5 pt track height.
    private static let pendingDashLength: CGFloat = 6
    private static let pendingDashGap: CGFloat = 4

    // MARK: Test-support hooks

    /// Whether the ENGAGED (gold-gradient) fill would render right now —
    /// armed ∧ enabled, the exact gate `drawBar` uses, so tests can't drift
    /// from the pixels.
    public var test_isEngagedFill: Bool { isRouteArmed && isEnabled }
    public var test_isPendingFill: Bool { isPendingApply && isRouteArmed && isEnabled }

    /// The fill rect `drawBar` would paint for `track`, at the cell's current
    /// `doubleValue`/`minValue`/`maxValue` — same geometry, so a test can
    /// assert the fill reaches the track's real ends without going through
    /// the drawing chain.
    public func test_fillRect(track: NSRect) -> NSRect { fillRect(track: track) }
}
