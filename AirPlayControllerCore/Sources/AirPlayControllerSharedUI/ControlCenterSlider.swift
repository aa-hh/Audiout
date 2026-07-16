// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit

/// A macOS Control Center–style horizontal slider: a thick rounded "pill" track
/// with a subtle unfilled portion, an accent-tinted filled portion, and a large
/// white circular knob. Drop-in `NSSlider` subclass — set `integerValue` /
/// `doubleValue`, `minValue`/`maxValue`, `target`/`action`, `isContinuous`, and
/// `isEnabled` exactly as with a stock `NSSlider`.
///
/// Shared by the Main Out row and the device/group rows so every slider in the
/// popover matches. Neither UI agent owns this file — both consume it.
public final class ControlCenterSlider: NSSlider {

    /// Optional SF Symbol drawn inside the track at the leading edge. Kept for
    /// source compatibility with callers (e.g. MainOutRowView) added during the
    /// brief full-height-capsule experiment; currently unused by this simpler
    /// track style (no-op) since Alec reverted to the original slim-track look.
    public var symbolName: String? {
        didSet { needsDisplay = true }
    }

    public init() {
        super.init(frame: .zero)
        let cell = ControlCenterSliderCell()
        cell.minValue = 0
        cell.maxValue = 100
        self.cell = cell
        self.isContinuous = true
        self.sliderType = .linear
        self.controlSize = .regular
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }
}

/// Custom cell that draws the Control-Center pill track + circular knob.
/// `NSSlider` exposes no track-thickness / knob-shape API, so the CC look
/// requires a custom `NSSliderCell` (this is the documented customization path:
/// override `barRect`/`knobRect`/`drawBar`/`drawKnob`).
final class ControlCenterSliderCell: NSSliderCell {

    private let trackHeight: CGFloat = 8
    private let knobDiameter: CGFloat = 18
    /// The track + knob draw at the view's exact geometric center, but every OTHER
    /// row element — text labels, SF-Symbol icons, the NSSwitch, the NSPopUpButton
    /// — renders its content on AppKit's natural content line, which sits ~1.75pt
    /// ABOVE geometric center. Raising the drawn track+knob by that amount lets the
    /// slider share the row's single optical centerline, so alignment is fixed once
    /// HERE (scalable to any future row) instead of nudging every other element
    /// (Alec 2026-07-16). Applied to both `barRect` and `knobRect` so hit-testing
    /// tracks the drawn knob.
    private let opticalRise: CGFloat = 1.75

    // MARK: Geometry

    override func barRect(flipped: Bool) -> NSRect {
        // A pill track centered vertically, inset horizontally by the knob
        // radius so the knob stays fully inside the control at both ends.
        let bounds = controlView?.bounds ?? .zero
        let inset = knobDiameter / 2
        let y = bounds.midY - opticalRise - trackHeight / 2
        return NSRect(x: bounds.minX + inset,
                      y: y,
                      width: max(0, bounds.width - knobDiameter),
                      height: trackHeight)
    }

    override func knobRect(flipped: Bool) -> NSRect {
        let bar = barRect(flipped: flipped)
        let frac = fraction()
        let travel = bar.width
        let cx = bar.minX + travel * CGFloat(frac)
        let bounds = controlView?.bounds ?? .zero
        return NSRect(x: cx - knobDiameter / 2,
                      y: bounds.midY - opticalRise - knobDiameter / 2,
                      width: knobDiameter,
                      height: knobDiameter)
    }

    // MARK: Drawing

    override func drawBar(inside aRect: NSRect, flipped: Bool) {
        let radius = aRect.height / 2
        // `NSView`/`NSSlider` is NOT flipped by default (origin bottom-left), so
        // in these coords maxY is the visual TOP and minY the visual BOTTOM. The
        // previous attempt inverted this, which (together with a ~0-alpha stroke)
        // is why the recess never showed. All the cues below are drawn as real,
        // clipped fills/strokes — not shadow-of-an-invisible-shape tricks.
        let isDark = (controlView?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

        let track = NSBezierPath(roundedRect: aRect, xRadius: radius, yRadius: radius)

        // 1) RECESS = a real vertical gradient on the unfilled channel: darker at
        //    the TOP, lighter at the BOTTOM. That top-dark→bottom-light ramp is
        //    the classic "concave / carved-in" read.
        NSGraphicsContext.saveGraphicsState()
        track.setClip()
        let recessGradient: NSGradient
        if isDark {
            // On a dark tile the well is clearly darker than the tile at top,
            // lifting to a light rim at the bottom lip — the two extremes give
            // the concave read against the mid-grey tile.
            recessGradient = NSGradient(colors: [
                NSColor(calibratedWhite: 0.0, alpha: 0.70),  // top: deep shadow
                NSColor(calibratedWhite: 0.0, alpha: 0.35),  // mid
                NSColor(calibratedWhite: 1.0, alpha: 0.18),  // bottom: light lip
            ], atLocations: [0.0, 0.55, 1.0], colorSpace: .deviceRGB)!
        } else {
            recessGradient = NSGradient(colors: [
                NSColor(calibratedWhite: 0.0, alpha: 0.26),  // top: shadow
                NSColor(calibratedWhite: 0.0, alpha: 0.10),  // mid
                NSColor(calibratedWhite: 1.0, alpha: 0.45),  // bottom: light lip
            ], atLocations: [0.0, 0.5, 1.0], colorSpace: .deviceRGB)!
        }
        // angle 90° = bottom→top, so the FIRST color lands at the bottom; we want
        // the dark first color at the TOP, so draw from top down with angle -90.
        recessGradient.draw(in: aRect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // 2) Crisp edge lines reinforce the well: a 1px dark line hugging the top
        //    inner arc, a 1px light line hugging the bottom inner arc. Clipped to
        //    the capsule so they read as the inner walls of the channel.
        NSGraphicsContext.saveGraphicsState()
        track.setClip()
        // Top inner shadow line.
        let topLine = NSBezierPath(roundedRect: aRect.offsetBy(dx: 0, dy: 0.75),
                                   xRadius: radius, yRadius: radius)
        topLine.lineWidth = 1
        NSColor.black.withAlphaComponent(isDark ? 0.55 : 0.30).setStroke()
        topLine.stroke()
        // Bottom inner highlight line.
        let bottomLine = NSBezierPath(roundedRect: aRect.offsetBy(dx: 0, dy: -0.75),
                                      xRadius: radius, yRadius: radius)
        bottomLine.lineWidth = 1
        NSColor.white.withAlphaComponent(isDark ? 0.14 : 0.55).setStroke()
        bottomLine.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // 3) Filled portion up to the knob center, accent-tinted. Give it a faint
        //    vertical gradient too (lighter top → darker bottom) so the fill reads
        //    slightly convex/glossy against the concave empty channel.
        let frac = fraction()
        let knobCenterX = aRect.minX + aRect.width * CGFloat(frac)
        let fillWidth = max(aRect.height, knobCenterX - aRect.minX)
        let fillRect = NSRect(x: aRect.minX, y: aRect.minY, width: fillWidth, height: aRect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        fill.setClip()
        let base: NSColor = isEnabled ? .controlAccentColor : .tertiaryLabelColor
        let baseAlpha: CGFloat = isEnabled ? 0.95 : 0.5
        let fillGradient = NSGradient(colors: [
            base.blended(withFraction: 0.18, of: .white)?.withAlphaComponent(baseAlpha) ?? base,
            base.withAlphaComponent(baseAlpha),
            base.blended(withFraction: 0.12, of: .black)?.withAlphaComponent(baseAlpha) ?? base,
        ], atLocations: [0.0, 0.5, 1.0], colorSpace: .deviceRGB)!
        fillGradient.draw(in: fillRect, angle: -90) // light at top → dark at bottom
        // A crisp top highlight line on the fill for the glossy convex read.
        let fillTop = NSBezierPath(roundedRect: fillRect.offsetBy(dx: 0, dy: -0.5),
                                   xRadius: radius, yRadius: radius)
        fillTop.lineWidth = 1
        NSColor.white.withAlphaComponent(0.25).setStroke()
        fillTop.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let inset = knobRect.insetBy(dx: 1, dy: 1)
        let knob = NSBezierPath(ovalIn: inset)
        let isDark = (controlView?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

        // RAISED = a genuinely visible drop shadow. Non-flipped coords → a
        // negative-y offset drops the shadow BELOW the knob (correct light-from-
        // above read). Big enough blur + alpha that it actually shows against the
        // tile, lifting the knob clearly off the recessed channel.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.60 : 0.38)
        shadow.shadowBlurRadius = 3.5
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        // Fill an opaque white base first so the shadow is cast by a solid disc
        // (a gradient fill alone can cast a weaker shadow). CC knobs read white
        // in both appearances.
        (isEnabled ? NSColor.white : NSColor.white.withAlphaComponent(0.6)).setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Subtle vertical gradient on the knob face: bright white at top easing to
        // a faint grey at the bottom — a domed, raised sheen (light from above).
        if isEnabled {
            NSGraphicsContext.saveGraphicsState()
            knob.setClip()
            let knobGradient = NSGradient(colors: [
                NSColor(calibratedWhite: 1.0, alpha: 1.0),   // top: pure white
                NSColor(calibratedWhite: 0.90, alpha: 1.0),  // bottom: soft grey
            ], atLocations: [0.0, 1.0], colorSpace: .deviceRGB)!
            knobGradient.draw(in: inset, angle: -90) // white top → grey bottom
            // Bright top-edge highlight arc for the dome.
            let highlight = NSBezierPath(ovalIn: inset.insetBy(dx: 1.2, dy: 1.2)
                                                       .offsetBy(dx: 0, dy: 1.4))
            NSColor.white.withAlphaComponent(0.9).setStroke()
            highlight.lineWidth = 1
            highlight.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Thin rim so the knob edge stays defined against a white fill.
        NSColor.black.withAlphaComponent(isDark ? 0.22 : 0.16).setStroke()
        knob.lineWidth = 0.75
        knob.stroke()
    }

    // MARK: Helpers

    private func fraction() -> Double {
        guard maxValue > minValue else { return 0 }
        return min(1, max(0, (doubleValue - minValue) / (maxValue - minValue)))
    }
}
