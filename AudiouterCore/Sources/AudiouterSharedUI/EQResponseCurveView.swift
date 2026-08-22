// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// The **response curve**: the EQ editor's scope. It plots the magnitude
/// response of the very biquad sections the audio path runs
/// (``EQProcessor/responseDB(for:atHz:sampleRate:)``), so the picture and the
/// sound can never drift apart.
///
/// **An approved custom-drawn instrument** (SharedUI AGENTS.md): a plotted
/// curve has no stock AppKit equivalent. Everything it draws lives in
/// `draw(_:)` with `NSBezierPath` — no `CALayer`, no animation, no state
/// beyond the last pushed ``DeviceEQ``.
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
public final class EQResponseCurveView: NSView {

    // MARK: Geometry + sampling constants

    /// The scope's fixed height. The view installs this on itself, so a host
    /// only has to pin its width.
    public static let height: CGFloat = 64

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
    private static let gridAlpha: CGFloat = 0.10
    private static let shapedFillAlpha: CGFloat = 0.13
    private static let shapedLineWidth: CGFloat = 2
    private static let hairlineWidth: CGFloat = 1.5
    private static let bypassDashPattern: [CGFloat] = [4, 3]

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

    /// Resolve what to draw. A FLAT eq is flat whatever the bypass state says:
    /// "not applied" is only worth saying about shaping that exists, and a
    /// dashed straight line would just look broken.
    public static func resolve(eq: DeviceEQ, bypassed: Bool) -> Plan {
        let gridX = DeviceEQ.bandCentresHz.map { normalizedX(hz: $0) }
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

    @objc private func displayOptionsDidChange() { needsDisplay = true }

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
        Tokens.Color.scopeGround.setFill()
        ground.fill()

        let plot = bounds.insetBy(dx: Self.plotInset, dy: Self.plotInset)
        guard plot.width > 0, plot.height > 0 else { return }

        // Clipped to the ground so a clamped trace can never paint over the
        // rounded corners.
        NSGraphicsContext.saveGraphicsState()
        ground.setClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        drawGrid(in: plot)
        drawTrace(in: plot)
    }

    private func drawGrid(in plot: NSRect) {
        let gridColor = (Tokens.Color.gold.usingColorSpace(.sRGB) ?? Tokens.Color.gold)
            .withAlphaComponent(Self.gridAlpha)
        gridColor.setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for x in plan.gridX {
            let px = plot.minX + x * plot.width
            grid.move(to: NSPoint(x: px, y: plot.minY))
            grid.line(to: NSPoint(x: px, y: plot.maxY))
        }
        grid.stroke()

        Tokens.Color.scopeZeroLine.setStroke()
        let zero = NSBezierPath()
        zero.lineWidth = 1
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
