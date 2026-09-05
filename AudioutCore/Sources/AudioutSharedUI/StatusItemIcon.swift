// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutField

/// Builds the menu-bar status item's `NSImage` from the pure
/// `MenuBarStatus` decision. Extracted out of `AudioutApp.StatusItemController`
/// so the "always template" invariant is unit-testable — `AudioutApp` is the
/// bare executable target, which the test target cannot import.
///
/// **Menu-bar status items must ALWAYS be template images.** That is the
/// macOS platform convention: the system then guarantees legibility against
/// any wallpaper, vibrancy, and menu-bar appearance, light or dark. An earlier
/// version of this rendering layered an
/// `NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])` plus
/// `isTemplate = false` onto the streaming state — on an accent-matched
/// wallpaper (e.g. blue accent, blue desktop) that made the streaming icon
/// nearly unreadable, the exact failure template rendering exists to prevent.
/// Do not reintroduce a palette/accent path here: every state distinction is
/// carried by shape and alpha alone.
///
/// **The glyph is a frozen frame of the brand's emitter field** (decided
/// 2026-09-05, replacing the `speaker.wave.3` SF Symbol that was
/// indistinguishable from the system volume item): one source dot at the
/// left, ring crests radiating right, every radius, stroke width, and
/// opacity solved from `AudioutField.defaults` — never retyped (the field
/// skill's rule; `StatusItemFieldFrame` below is the closed-form port).
/// State mapping:
/// - **level** drives the field's own per-emitter `reach`: waves travel
///   further as master volume rises (1 crest near 30%, 4 at 100%);
/// - **mute** = the caller passes `masterVolume: 0`, reach collapses, and
///   every wave drains away leaving the lone dot — same drain rule as the
///   old `variableValue` arc;
/// - **idle vs streaming** = hollow dot + 45% ink vs solid dot + full ink;
/// - **failure** = few loud marks: solid dot, first crest only, plus an
///   exclamation badge — the only straight lines in an all-curves icon, so
///   a broken speaker never reads as a merely paused one.
public enum StatusItemIcon {

    /// Icon canvas in points. The field math works in uv units of the canvas
    /// height (1 uv = 12 pt), centre origin — same convention as the
    /// website's shader.
    static let canvas = NSSize(width: 18, height: 12)

    /// Builds the status button's image for `state`, with the field's reach
    /// driven by `masterVolume` (0...1, clamping is the caller's job — a
    /// master-muted caller passes 0, which is how mute drains the waves).
    /// `isMuted` reaches only the spoken description; the drained field
    /// already shows it. Always template.
    public static func make(state: MenuBarStatus.State,
                            masterVolume: Double,
                            isMuted: Bool) -> NSImage? {
        let frame: StatusItemFieldFrame
        var badge = false
        switch state {
        case .idle:
            frame = StatusItemFieldFrame(tier: 0.45, volume: masterVolume, solidDot: false)
        case .streaming:
            frame = StatusItemFieldFrame(tier: 1.0, volume: masterVolume, solidDot: true)
        case .failure:
            // Fixed low reach regardless of level: fewer, heavier marks.
            frame = StatusItemFieldFrame(tier: 1.0, volume: 0.3, solidDot: true)
            badge = true
        }
        let showBadge = badge
        let image = NSImage(size: canvas, flipped: true) { _ in
            frame.draw()
            if showBadge { drawBadge() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = MenuBarStatus.accessibilityDescription(
            state: state,
            masterVolumePercent: Int((masterVolume * 100).rounded()),
            isMuted: isMuted)
        return image
    }

    /// The failure exclamation, a badge rather than field math — the parallel
    /// of the old `speaker.badge.exclamationmark`. Right side, ~7.5 pt tall.
    private static func drawBadge() {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 13.75, y: 2, width: 1.5, height: 5.5),
                     xRadius: 0.75, yRadius: 0.75).fill()
        NSBezierPath(ovalIn: NSRect(x: 13.6, y: 8.6, width: 1.8, height: 1.8)).fill()
    }
}

/// One emitter's frozen frame of the field, closed-form: the crest radii,
/// their exact field values, and the wobbled crest contour, all computed from
/// `AudioutField.defaults` (emitter k = 0). Deliberate deviations from the
/// shared defaults, per the field skill's marking rule:
/// - **wobble 0.06** against the shared default 0 (the hero is calm): the
///   owner asked the icon to carry the field's wobble, and 0.06 is the
///   reference implementation's own documented scaling (rings bend ±6% of
///   radius) — chosen over larger amplitudes for 18 pt legibility.
/// Everything else that differs is a per-surface choice from the skill's own
/// list (emitter position, reach mapping, canvas, no colour ramp — a
/// template image is alpha-only, so here alpha IS the ramp).
struct StatusItemFieldFrame {

    /// Per-surface: where the source sits (uv, centre origin, y up) and how
    /// master volume maps onto the field's per-emitter reach knob.
    private static let position = (x: -0.62, y: 0.06)
    private static let reachSpan = 1.9
    /// Deviation (marked above): wobble amplitude.
    private static let wobble = 0.06
    /// Crests dimmer than this draw nothing — below it, template tinting on a
    /// busy wallpaper renders noise, not signal.
    private static let minOpacity = 0.06

    private static let F = AudioutField.defaults
    private static let seed = 1.7 // k = 0 in the field's seed formula
    /// Frozen time, pinned so the first crest sits at r = 0.24 uv (2.9 pt),
    /// clear of the source dot.
    private static let t = (0.24 * F.densBase - .pi / 2 + seed) / F.speedBase
    /// The crest band's full width at half max (uv): the rings term
    /// `(0.5 + 0.5 sin φ)^sharp` falls to half its peak where
    /// `sin φ = 2·0.5^(1/sharp) − 1`.
    private static let halfMaxPhase =
        2 * (Double.pi / 2 - asin(2 * pow(0.5, 1 / F.sharp) - 1))
    /// Breathing swell at the frozen t.
    private static let swell = F.breatheFloor
        + F.breatheDepth * (0.5 + 0.5 * sin(t * F.breatheRate + seed * 2.3))
    /// Shared normalisation: the streaming-at-100% peak crest lands at
    /// opacity 0.95, and every state divides by the same factor so the sheet
    /// is comparable across states.
    private static let norm = (rawCrests(reach: reachSpan).map(\.raw).max() ?? 1) / 0.95

    let crests: [(radiusUv: Double, opacity: Double)]
    let solidDot: Bool
    let tier: Double

    init(tier: Double, volume: Double, solidDot: Bool) {
        self.tier = tier
        self.solidDot = solidDot
        let reach = Self.reachSpan * min(1, max(0, volume))
        self.crests = Self.rawCrests(reach: reach).compactMap { crest in
            let opacity = min(1, max(0, crest.raw / Self.norm * tier))
            return opacity < Self.minOpacity ? nil : (crest.r, opacity)
        }
    }

    /// Crest radii where the rings term peaks —
    /// `sin(r·dens − t·speed + seed) = 1` — with the exact field value at
    /// each: falloff × swell × gain × the reach cap's smoothstep fade-out.
    private static func rawCrests(reach: Double) -> [(r: Double, raw: Double)] {
        guard reach > 0 else { return [] }
        var out: [(Double, Double)] = []
        for m in 0..<12 {
            let r = (.pi / 2 + 2 * .pi * Double(m) + t * F.speedBase - seed) / F.densBase
            guard r > 0.06 else { continue } // inside the source dot
            let cap = 1 - smoothstep(0.55 * reach, reach, r)
            let raw = exp(-r * F.fade) * swell * F.gain * cap
            guard raw > 0 else { continue }
            out.append((r, raw))
        }
        return out
    }

    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// The wobble modulation W(θ): the field's exact two-harmonic bend,
    /// three and five lobes, phased by the seed.
    private static func wob(_ th: Double) -> Double {
        (sin(3 * th + t * F.wobbleRate + seed)
            + 0.5 * sin(5 * th - t * F.wobbleRate * 0.73 + seed * 1.3)) / 1.5
    }

    /// uv → points in the icon's flipped coordinate space (1 uv = 12 pt,
    /// centre (9, 6), y down).
    private static func point(_ x: Double, _ y: Double) -> NSPoint {
        NSPoint(x: 9 + x * 12, y: 6 - y * 12)
    }

    /// Draws the frame in black-with-alpha into the current (flipped)
    /// graphics context — the caller owns `isTemplate`.
    func draw() {
        let F = Self.F
        // Step 1: orbit — the centre at the frozen t.
        let cx = Self.position.x + F.orbit * sin(Self.t * 0.03 + Self.seed)
        let cy = Self.position.y + F.orbit * cos(Self.t * 0.026 + Self.seed * 1.7)
        let strokeWidth = max(Self.halfMaxPhase / F.densBase * 12, 0.9)

        for crest in crests {
            // A crest at modulated radius r is the locus d(θ) = r/(1 + w·W(θ)),
            // y divided by squash (steps 2 + 3) — one closed curve, because the
            // wobble scales radius by angle only.
            let path = NSBezierPath()
            for i in 0...128 {
                let th = Double(i) / 128 * 2 * .pi
                let d = crest.radiusUv / (1 + Self.wobble * Self.wob(th))
                let p = Self.point(cx + d * cos(th), cy + d * sin(th) / F.squash)
                i == 0 ? path.move(to: p) : path.line(to: p)
            }
            path.close()
            path.lineWidth = strokeWidth
            path.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(crest.opacity).setStroke()
            path.stroke()
        }

        // The source: the emitter itself at the orbited centre.
        let c = Self.point(cx, cy)
        if solidDot {
            NSColor.black.withAlphaComponent(tier).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.2, y: c.y - 1.2, width: 2.4, height: 2.4)).fill()
        } else {
            NSColor.black.withAlphaComponent(tier).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 0.95, y: c.y - 0.95, width: 1.9, height: 1.9))
            ring.lineWidth = 1
            ring.stroke()
        }
    }
}
