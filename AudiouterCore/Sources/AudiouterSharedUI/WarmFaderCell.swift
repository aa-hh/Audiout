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
/// What it draws (contrast floors re-measured in the fader-legibility pass,
/// 2026-07-22 — ratios live on the `faderThumb`/`faderRim`/`well` tokens):
/// - **Track**: a flat recessed trough (`PopoverColumnGrid.faderTrackHeight`
///   ≈ 5 pt) filled with the `well` inset token — the exact surface spec §1
///   reserves for "slider track trough" — with a `faderRim` rim (load-bearing
///   for the recess: ≈3.1:1 dark / 2.6:1 light vs `well`) and a 1 px inner
///   top shade (drawn, not a layer shadow) so the trough reads inset.
/// - **Filled portion** (min side → thumb): the gold gradient ONLY while the
///   row is **route-armed** (the same §3.3 model predicate the row already
///   pushes to its `RouteArmedDotView`; `AppRowView` uses its routed ∧
///   running equivalent). The gradient's dim end is `ember` pre-blended
///   halfway toward `gold` (`armedDimEndGoldBlend`) so the low-value end
///   still reads against the trough (raw light `ember` measured 1.98:1 vs
///   `well`; the blend lifts it to 2.38:1, dark to 6.62:1). Unarmed or
///   disabled rows fill with the hue-neutral warm `ringConnected` grey
///   (4.82:1 dark / 2.60:1 light vs `well` — both clear the ≥2.5:1 unarmed
///   floor) — gold stays a signal, never decoration (house rule: the gold
///   budget).
/// - **Thumb**: a rounded-rect handle (`faderThumbWidth × faderThumbHeight`
///   ≈ 10×17 pt) replacing the stock white circle — the dedicated
///   `faderThumb` warm neutral (≥3:1 vs BOTH `canvas` and `well`, both
///   themes; see the token's measured table), edged by a derived darkened
///   outline and a 1 px top highlight so it reads as a grabbable raised
///   object.
///
/// Every color goes through `Tokens`, resolved at DRAW time under the
/// control's effective appearance (AppKit sets the drawing appearance before
/// calling the cell), so light/dark, Increase Contrast, and the accent dial
/// (spec §1.3 — `gold`/`ember` remap; under `.systemAccent` the engaged fill
/// resolves to `controlAccentColor` and its ×0.55 companion) all land with no
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

        // …then the filled portion, min-value side up to the thumb's center.
        let knobMidX = knobRect(flipped: flipped).midX
        let fillRect: NSRect
        if controlView?.userInterfaceLayoutDirection == .rightToLeft {
            fillRect = NSRect(x: knobMidX, y: track.minY,
                              width: max(0, track.maxX - knobMidX), height: track.height)
        } else {
            fillRect = NSRect(x: track.minX, y: track.minY,
                              width: max(0, knobMidX - track.minX), height: track.height)
        }
        if fillRect.width > 0 {
            NSGraphicsContext.current?.saveGraphicsState()
            trough.addClip()
            if isRouteArmed && isEnabled {
                // Engaged: the gold instrument gradient (accent-dial aware via
                // the tokens themselves — under `.systemAccent` this resolves
                // to controlAccentColor and its dimmed companion). The dim end
                // is `ember` pre-blended toward `gold` so the low-value end of
                // the fill clears the trough (ratios in the header doc);
                // blending two live tokens at draw time keeps the accent dial
                // and IC variants authoritative (same derivation idiom as the
                // thumb highlight).
                let dimEnd = Tokens.Color.ember
                    .blended(withFraction: Self.armedDimEndGoldBlend,
                             of: Tokens.Color.gold) ?? Tokens.Color.ember
                if let gradient = NSGradient(starting: dimEnd,
                                             ending: Tokens.Color.gold) {
                    let leftToRight = fillRect.minX == track.minX
                    gradient.draw(in: fillRect, angle: leftToRight ? 0 : 180)
                }
            } else {
                // Unarmed (or disabled — enabled-ness also dims via
                // `interiorAlpha` below): the hue-neutral warm fill. Gold is a
                // signal; a level alone is not.
                Tokens.Color.ringConnected
                    .withAlphaComponent(interiorAlpha).setFill()
                fillRect.fill()
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Trough rim (`faderRim` — the recess's load-bearing edge; `hairline`
        // measured 1.21:1 vs `well`, invisible), inset half a hairline so the
        // stroke stays inside.
        Tokens.Color.faderRim.withAlphaComponent(interiorAlpha).setStroke()
        let rimPath = NSBezierPath(
            roundedRect: track.insetBy(dx: Self.hairlineWidth / 2, dy: Self.hairlineWidth / 2),
            xRadius: radius, yRadius: radius)
        rimPath.lineWidth = Self.hairlineWidth
        rimPath.stroke()
    }

    public override func drawKnob(_ knobRect: NSRect) {
        let size = NSSize(width: PopoverColumnGrid.faderThumbWidth,
                          height: PopoverColumnGrid.faderThumbHeight)
        let thumb = NSRect(x: (knobRect.midX - size.width / 2).rounded(),
                           y: (knobRect.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        let radius = PopoverColumnGrid.faderThumbCornerRadius
        let path = NSBezierPath(roundedRect: thumb, xRadius: radius, yRadius: radius)

        // Grabbable warm-neutral body — the dedicated `faderThumb` instrument
        // token (≥3:1 vs canvas AND trough, both themes; `raised` measured
        // 1.09:1 dark / 1.25:1 light and sank into the surfaces)…
        Tokens.Color.faderThumb.withAlphaComponent(interiorAlpha).setFill()
        path.fill()

        // …a 1 px top highlight (clipped to the rounded body) so the handle
        // reads raised — `faderThumb` lightened, derived from the token so
        // the IC variants stay authoritative…
        let flipped = controlView?.isFlipped ?? false
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        let highlight = Tokens.Color.faderThumb
            .blended(withFraction: Self.thumbHighlightFraction, of: .white) ?? Tokens.Color.faderThumb
        highlight.withAlphaComponent(interiorAlpha).setFill()
        let highlightY = flipped ? thumb.minY : thumb.maxY - Self.hairlineWidth
        NSRect(x: thumb.minX, y: highlightY,
               width: thumb.width, height: Self.hairlineWidth).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // …and a darkened outline (thumb blended toward `shadow`, derived so
        // IC tracks) that separates the bright handle from the gold fill in
        // dark mode and defines its edge on the paper surfaces in light.
        let outlineColor = Tokens.Color.faderThumb
            .blended(withFraction: Self.thumbOutlineDarkenFraction,
                     of: Tokens.Color.shadow) ?? Tokens.Color.faderThumb
        outlineColor.withAlphaComponent(interiorAlpha).setStroke()
        let outline = NSBezierPath(
            roundedRect: thumb.insetBy(dx: Self.hairlineWidth / 2, dy: Self.hairlineWidth / 2),
            xRadius: radius, yRadius: radius)
        outline.lineWidth = Self.hairlineWidth
        outline.stroke()
    }

    // MARK: Geometry / constants

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
    /// How far the thumb's top highlight lightens `faderThumb` toward white
    /// (raised 0.4 → 0.5 in the legibility pass — the brighter catch-light is
    /// part of what makes the handle read as a grabbable object).
    private static let thumbHighlightFraction: CGFloat = 0.5
    /// How far the thumb's outline darkens `faderThumb` toward `shadow`.
    private static let thumbOutlineDarkenFraction: CGFloat = 0.4
    /// How far the armed gradient's dim end pre-blends `ember` toward `gold`
    /// (0 = raw ember). At 0.5 the dim end measures 6.62:1 (dark) / 2.38:1
    /// (light) vs `well` — raw ember measured 3.86:1 / 1.98:1, muddy at the
    /// track's low-value end in light.
    private static let armedDimEndGoldBlend: CGFloat = 0.5

    // MARK: Test-support hooks

    /// Whether the ENGAGED (gold-gradient) fill would render right now —
    /// armed ∧ enabled, the exact gate `drawBar` uses, so tests can't drift
    /// from the pixels.
    public var test_isEngagedFill: Bool { isRouteArmed && isEnabled }
}
