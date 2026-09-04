// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// The **response curve**: the EQ editor's scope. It plots the magnitude
/// response of the very biquad sections the audio path runs
/// (``EQProcessor/responseDB(for:atHz:sampleRate:)``), so the picture and the
/// sound can never drift apart.
///
/// **It lives inside the editor's Advanced fold**, full width, directly above
/// the ten band faders — and it shares their x-axis: every fader column is
/// centred on the gridline this view draws for that band
/// (``bandCentreX(index:width:)``). A curve bonded to the controls that shape
/// it reads as an instrument; a curve floating over unrelated sliders reads as
/// a black bar with a line through it. A dB ruler ("+12 / 0 / −12") sits in a
/// gutter on the leading edge and a dotted line marks 0 dB; flat draws its
/// hairline ON that dotted line and covers it. There are no Hz ticks inside
/// the figure — the band labels under the faders ARE its Hz ruler.
///
/// **An approved custom-drawn instrument** (SharedUI AGENTS.md): a plotted
/// curve has no stock AppKit equivalent. Everything it draws lives in
/// `draw(_:)` with `NSBezierPath` — no `CALayer`, no animation, no state
/// beyond the last pushed ``DeviceEQ``. The one exception is bookkeeping, not
/// a second surface: the STATIC half of the figure (ground, dB ruler, band
/// grid, 0 dB line) is nothing but a function of the view's size, so it is
/// rasterized once into a cached `NSImage` and only the trace is stroked per
/// drag frame. That cache is dropped on exactly two triggers — a size change,
/// and the accessibility/accent notification that re-tints the tokens.
///
/// **It never themes.** The scope is authored dark in BOTH appearances, the
/// way a hardware analyser's screen is dark whatever room it sits in — a
/// light-mode scope would be a chart, not an instrument. That is enforced by
/// drawing the whole figure inside `NSAppearance(named: .darkAqua)`'s drawing
/// appearance, so every token still resolves LIVE (Increase Contrast and the
/// accent dial reach it) while the light/dark axis is pinned.
///
/// **Gold at rest is forbidden.** Gold means signal, so a flat EQ draws only
/// the neutral ``Tokens/Color/scopeFlatLine`` hairline — nothing pretends to
/// be engaged. Shaping deviates in gold; a bypassed shape goes dashed and
/// hollow, stating that the settings exist but are not reaching the air.
///
/// The iPhone companion's `lampWell` (`#050507` dark / `#14120F` light, dark
/// in both appearances so a lit thing has a dark surround to read against) is
/// the same decision; this scope stays on `scopeGround` for the same reason.
public final class EQResponseCurveView: NSView {

    // MARK: Geometry + sampling constants

    /// The scope's fixed 80 pt height — room for the dB ruler's three labels
    /// to sit clear of one another. The view installs this on itself, so a
    /// host only has to pin its width.
    public static let height: CGFloat = 80

    /// The leading gutter the dB ruler is drawn in: the plot starts this far
    /// in, so 20 Hz is at x = 28 rather than at the view's edge.
    public static let plotLeadingInset: CGFloat = 28

    /// The trailing margin. At least half a band-fader column wide, so the
    /// 16 kHz fader — centred on the last gridline — never overhangs the
    /// editor.
    public static let plotTrailingInset: CGFloat = 14

    /// The rate the response is evaluated at. A fixed reference, not the live
    /// stream rate: the drawn shape is a description of the tone, and it must
    /// not twitch because a speaker renegotiated to 48 kHz mid-song.
    public static let referenceSampleRate: Double = 44_100

    /// How many points the trace is sampled at across the audible decade span.
    /// 129 = 128 intervals, so the plotted x values land on exact fractions.
    private static let sampleCount = 129

    /// The plotted band, 20 Hz … 20 kHz — three decades, which is why the
    /// log mapping divides by 3.
    private static let lowestHz: Double = 20
    private static let decades: Double = 3

    /// The vertical full-scale, in dB. Wider than ``DeviceEQ/gainRangeDB`` on
    /// purpose: stacked stages (bands + shelves + loudness) routinely sum past
    /// ±12, and a trace that flattened against the frame at every strong
    /// setting would stop describing anything.
    private static let fullScaleDB: Double = 13.5

    private static let cornerRadius: CGFloat = 6
    private static let plotInset: CGFloat = 1
    private static let gridAlpha: CGFloat = 0.14
    private static let shapedFillAlpha: CGFloat = 0.13
    private static let shapedLineWidth: CGFloat = 2
    private static let hairlineWidth: CGFloat = 1.5
    private static let bypassDashPattern: [CGFloat] = [4, 3]
    private static let zeroDashPattern: [CGFloat] = [1, 3]
    private static let rulerEdgeInset: CGFloat = 2
    private static let rulerTextGap: CGFloat = 4

    // MARK: The plan — pure, testable without a single pixel

    /// Everything the scope draws, resolved from a ``DeviceEQ`` alone. Pure
    /// values in normalized coordinates, so the shape can be asserted in a
    /// test with no window, no appearance and no drawing context.
    public struct Plan: Equatable, Sendable {

        /// Which of the three figures the scope is showing.
        public enum State: Equatable, Sendable {
            /// No shaping at all: the neutral hairline on the zero line.
            case flat
            /// Shaping that is reaching the audio: the gold trace + fill.
            case shaped
            /// Shaping that is stored but inaudible right now: dashed, hollow.
            case bypassed
        }

        public let state: State
        /// The trace, `x` in `0…1` (left = 20 Hz) and `y` in `-1…1`
        /// (positive = boost), one per sample.
        public let points: [CGPoint]
        /// The vertical gridlines' `x` values, one per ten-band centre, on the
        /// same `0…1` scale as `points`.
        public let gridX: [CGFloat]
    }

    /// Map a frequency onto the plot's `0…1` horizontal scale.
    private static func normalizedX(hz: Double) -> CGFloat {
        CGFloat(log10(hz / lowestHz) / decades)
    }

    /// The ten band centres on the plot's `0…1` horizontal scale — the
    /// gridlines the scope draws and, through ``bandCentreX(index:width:)``,
    /// the x-axis the editor's faders are laid out on.
    public static let bandGridX: [CGFloat] = DeviceEQ.bandCentresHz.map { normalizedX(hz: $0) }

    /// The x, in the view's own coordinates at `width`, of band `index`'s
    /// grid line — the editor centres each fader column on it.
    public static func bandCentreX(index: Int, width: CGFloat) -> CGFloat {
        plotLeadingInset + bandGridX[index] * (width - plotLeadingInset - plotTrailingInset)
    }

    /// Resolve what to draw. A FLAT eq is flat whatever the bypass state says:
    /// "not applied" is only worth saying about shaping that exists, and a
    /// dashed straight line would just look broken.
    public static func resolve(eq: DeviceEQ, bypassed: Bool) -> Plan {
        let gridX = bandGridX
        guard !eq.isFlat else {
            let flatPoints = (0..<sampleCount).map { index in
                CGPoint(x: CGFloat(index) / CGFloat(sampleCount - 1), y: 0)
            }
            return Plan(state: .flat, points: flatPoints, gridX: gridX)
        }

        // The coefficient array is the expensive half of a response query — one
        // filter design serves every sampled point instead of ~129 rebuilds.
        let sections = EQProcessor.responseSections(for: eq, sampleRate: referenceSampleRate)
        let points = (0..<sampleCount).map { index -> CGPoint in
            let fraction = Double(index) / Double(sampleCount - 1)
            let hz = lowestHz * pow(10, fraction * decades)
            let db = EQProcessor.responseDB(sections: sections, atHz: hz,
                                            sampleRate: referenceSampleRate)
            let clamped = min(max(db, -fullScaleDB), fullScaleDB)
            return CGPoint(x: CGFloat(fraction), y: CGFloat(clamped / fullScaleDB))
        }
        return Plan(state: bypassed ? .bypassed : .shaped, points: points, gridX: gridX)
    }

    /// What VoiceOver reads instead of the picture. Three named points is what
    /// the shape actually communicates at a glance — bass, mids, treble — and
    /// they come off the SAME response the trace is plotted from.
    public static func summary(eq: DeviceEQ, bypassed: Bool) -> String {
        guard !eq.isFlat else { return "Flat" }
        let sections = EQProcessor.responseSections(for: eq, sampleRate: referenceSampleRate)
        func gain(_ hz: Double) -> String {
            EQEditorView.gainText(
                EQProcessor.responseDB(sections: sections, atHz: hz, sampleRate: referenceSampleRate))
        }
        let body = "Bass \(gain(100)), mids \(gain(1_000)), treble \(gain(10_000))"
        return bypassed ? "Not applied. " + body : body
    }

    // MARK: State — pushed by `apply`, never read from a model

    private var appliedEQ: DeviceEQ = .flat
    private var appliedBypassed = false

    /// The 129-point plan, resolved LAZILY: `apply` only stores the new inputs
    /// and invalidates this, so a drag frame that never gets painted (the
    /// window is occluded, or a later frame supersedes it before `draw` runs)
    /// never pays for a curve nobody saw. `draw` and `test_plan` are the only
    /// two readers and both go through this one accessor.
    private var cachedPlan: Plan?

    /// How many times the 129-point plan has actually been resolved — proves
    /// the laziness above: repeated reads of the same applied tone must never
    /// re-resolve.
    public private(set) var test_planResolveCount = 0

    /// Ground + ruler + grid + 0 dB line, rasterized once. Everything in it is a
    /// function of `bounds.size` and the resolved tokens — the applied tone
    /// reaches none of it — so a drag frame re-lays-out no ruler text and
    /// re-strokes no gridlines.
    private var staticFigure: NSImage?

    /// How many times the static figure has been rasterized — the mirror of
    /// `test_planResolveCount`, proving a repeated draw reuses it.
    public private(set) var test_staticFigureBuildCount = 0

    private var plan: Plan {
        if let cachedPlan { return cachedPlan }
        let resolved = Self.resolve(eq: appliedEQ, bypassed: appliedBypassed)
        cachedPlan = resolved
        test_planResolveCount += 1
        return resolved
    }

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Response curve")
        setAccessibilityValue(Self.summary(eq: .flat, bypassed: false))

        // Mid-session accessibility-display and accent-dial changes reconcile
        // LIVE (SharedUI AGENTS.md rules 35/36): neither arrives through
        // `apply`, and this instrument's tokens are re-read every draw, so an
        // invalidation is the whole fix. Selector-based observation needs no
        // matching removal (post-10.11 AppKit auto-unregisters).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayOptionsDidChange),
            name: Tokens.accentStyleDidChangeNotification,
            object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Non-interactive: it is a readout, so clicks fall through to whatever
    /// hosts it.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func displayOptionsDidChange() {
        // The static figure has resolved tokens baked into it — re-tinting means
        // re-rasterizing.
        staticFigure = nil
        needsDisplay = true
    }

    // MARK: Public API

    /// Push a fresh tone. `bypassed` is the host's "these settings exist but
    /// are not reaching the air" verdict — the same one the editor's sentence
    /// spells out in words. A no-op when neither input changed — a drag frame
    /// that re-sends the value already on screen must cost nothing.
    public func apply(eq: DeviceEQ, bypassed: Bool) {
        guard eq != appliedEQ || bypassed != appliedBypassed else { return }
        appliedEQ = eq
        appliedBypassed = bypassed
        cachedPlan = nil
        setAccessibilityValue(Self.summary(eq: eq, bypassed: bypassed))
        needsDisplay = true
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        // Authored dark in both appearances — see the type's doc comment. The
        // tokens still resolve live inside this block, they just resolve
        // against a pinned appearance.
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            drawScope()
        }
    }

    private func drawScope() {
        let ground = NSBezierPath(roundedRect: bounds,
                                  xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        // The plot does not span the view: the leading gutter is the dB
        // ruler's, and the trailing margin keeps the 16 kHz fader — centred on
        // the last gridline — inside the editor. `drawGrid`/`drawTrace` map
        // their `0…1` values across THIS rect, so a gridline lands exactly
        // where `bandCentreX` says its fader goes.
        guard plotRect() != nil else { return }

        if staticFigure?.size != bounds.size { staticFigure = makeStaticFigure() }
        staticFigure?.draw(in: bounds)

        // Clipped to the ground so a clamped trace can never paint over the
        // rounded corners.
        NSGraphicsContext.saveGraphicsState()
        ground.setClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        if let plot = plotRect() { drawTrace(in: plot) }
    }

    /// The plot rect inside the current bounds, or `nil` when there is no room
    /// to plot in (a view that has not been laid out yet).
    private func plotRect() -> NSRect? {
        var plot = bounds.insetBy(dx: 0, dy: Self.plotInset)
        plot.origin.x += Self.plotLeadingInset
        plot.size.width -= Self.plotLeadingInset + Self.plotTrailingInset
        guard plot.width > 0, plot.height > 0 else { return nil }
        return plot
    }

    /// Rasterize the size-only half of the figure. `NSImage`, not a `CALayer`
    /// (the type forbids one) — AppKit caches the rasterization per backing
    /// scale, so a Retina redraw is not a re-render.
    private func makeStaticFigure() -> NSImage {
        test_staticFigureBuildCount += 1
        let size = bounds.size
        let ground = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                                  xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        return NSImage(size: size, flipped: false) { [weak self] _ in
            guard let self, let plot = self.plotRect() else { return true }
            // The handler can run outside `draw`'s pinned block, so it pins the
            // scope's authored-dark appearance itself.
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                Tokens.Color.scopeGround.setFill()
                ground.fill()
                NSGraphicsContext.saveGraphicsState()
                ground.setClip()
                self.drawRuler(beside: plot)
                self.drawGrid(in: plot)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    /// The dB ruler in the leading gutter: the vertical scale, stated once, so
    /// the trace's height means something without a caption row under the
    /// card. `secondaryLabel` rather than `tertiaryLabel` — over this ground
    /// the tertiary tone falls to ~2.2:1, well under the 4.5:1 text floor.
    private func drawRuler(beside plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Tokens.Font.caption,
            .foregroundColor: Tokens.Color.secondaryLabel,
        ]
        // The typographic MINUS, matching `EQEditorView.gainText`, so "−12"
        // keeps the digit width "+12" has.
        let rows: [(String, CGFloat)] = [
            ("+12", plot.maxY - Self.rulerEdgeInset),
            ("0", plot.midY),
            ("\u{2212}12", plot.minY + Self.rulerEdgeInset),
        ]
        for (index, (text, anchor)) in rows.enumerated() {
            let string = NSAttributedString(string: text, attributes: attributes)
            let size = string.size()
            // Top-anchored, centred, bottom-anchored — the three labels pin
            // the two ends of the scale and its middle.
            let y: CGFloat
            switch index {
            case 0: y = anchor - size.height
            case 1: y = anchor - size.height / 2
            default: y = anchor
            }
            // Right-aligned against the gutter, so the digits line up whatever
            // their widths.
            string.draw(at: NSPoint(x: plot.minX - Self.rulerTextGap - size.width, y: y))
        }
    }

    private func drawGrid(in plot: NSRect) {
        let gridColor = (Tokens.Color.gold.usingColorSpace(.sRGB) ?? Tokens.Color.gold)
            .withAlphaComponent(Self.gridAlpha)
        gridColor.setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        // `Self.bandGridX` directly, not `plan.gridX`: the grid is the same ten
        // band centres whatever the tone, and this runs inside the static
        // figure, which must not depend on the applied EQ.
        for x in Self.bandGridX {
            let px = plot.minX + x * plot.width
            grid.move(to: NSPoint(x: px, y: plot.minY))
            grid.line(to: NSPoint(x: px, y: plot.maxY))
        }
        grid.stroke()

        // 0 dB, DOTTED in the flat trace's own tone: `drawTrace` paints the
        // solid 1.5 pt hairline over exactly this line when the tone is flat,
        // so the dots read as "the reference" and the hairline reads as "you
        // are on it" without ever being two competing lines at once.
        Tokens.Color.scopeFlatLine.setStroke()
        let zero = NSBezierPath()
        zero.lineWidth = 1
        zero.setLineDash(Self.zeroDashPattern, count: Self.zeroDashPattern.count, phase: 0)
        zero.move(to: NSPoint(x: plot.minX, y: plot.midY))
        zero.line(to: NSPoint(x: plot.maxX, y: plot.midY))
        zero.stroke()
    }

    private func drawTrace(in plot: NSRect) {
        let trace = NSBezierPath()
        for (index, point) in plan.points.enumerated() {
            let target = NSPoint(x: plot.minX + point.x * plot.width,
                                 y: plot.midY + point.y * (plot.height / 2))
            if index == 0 { trace.move(to: target) } else { trace.line(to: target) }
        }
        trace.lineJoinStyle = .round

        switch plan.state {
        case .flat:
            trace.lineWidth = Self.hairlineWidth
            Tokens.Color.scopeFlatLine.setStroke()
            trace.stroke()

        case .shaped:
            let gold = Tokens.Color.gold
            let fill = (gold.usingColorSpace(.sRGB) ?? gold)
                .withAlphaComponent(Self.shapedFillAlpha)
            let area = NSBezierPath()
            area.append(trace)
            area.line(to: NSPoint(x: plot.maxX, y: plot.midY))
            area.line(to: NSPoint(x: plot.minX, y: plot.midY))
            area.close()
            fill.setFill()
            area.fill()

            trace.lineWidth = Self.shapedLineWidth
            gold.setStroke()
            trace.stroke()

        case .bypassed:
            // No fill: the hollow shape IS the statement that nothing is
            // reaching the air.
            trace.lineWidth = Self.hairlineWidth
            trace.setLineDash(Self.bypassDashPattern, count: Self.bypassDashPattern.count, phase: 0)
            Tokens.Color.scopeBypassLine.setStroke()
            trace.stroke()
        }
    }

    // MARK: Test hooks

    public var test_plan: Plan { plan }
    public var test_axValue: String? { accessibilityValue() as? String }
}
