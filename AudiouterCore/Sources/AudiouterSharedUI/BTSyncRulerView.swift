// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// Continuous scrub feedback from a ``BTSyncRulerView`` — the fine-adjustment
/// control PLAN-BT-SYNC-DRAWER's T4 introduces.
public protocol BTSyncRulerViewDelegate: AnyObject {
    /// Fired continuously during a drag/keyboard/scroll nudge (D6 — the whole
    /// point is judging by ear while the value is moving). Already quantised
    /// to ``BTSyncTrim/resolutionMs`` and clamped to ``BTSyncRulerView/usableRangeMs``.
    func syncRuler(_ ruler: BTSyncRulerView, didScrubTo ms: Double)
    /// Fired once when a gesture ends — the commit/persist point (T5/T7:
    /// apply-and-persist happens here, not on every ``syncRuler(_:didScrubTo:)``).
    func syncRulerDidEndScrub(_ ruler: BTSyncRulerView)
}

/// The **fine-adjustment ruler** (PLAN-BT-SYNC-DRAWER §3 T4, D3/D4/D5): a
/// horizontal tape of tick marks that slides under a **fixed centre
/// pointer**. Deliberately NOT a slider with a thumb travelling a track —
/// that shape is already spoken for by the row's volume sliders, and a
/// travelling-thumb control needs endpoints, which this control must not
/// have (range and precision have to coexist: D4's ±6 ms visible window
/// scrolls, it does not run out).
///
/// **Direction (D3, the plan's "50/50 that compiles either way" trap):**
/// dragging **right** means a **larger** value (the device plays later),
/// which means the tape slides **left** under the pointer — exactly like a
/// normal left-to-right ruler where the reading you're centred on gets
/// pulled toward you as the numbers underneath it grow. `BTSyncRulerViewTests`
/// pins this.
///
/// **Gearing (D5):** ms-per-point of drag is a function of the drag's
/// instantaneous speed (points moved in the most recent `mouseDragged`
/// event) — flat and fine below the slow anchor, flat and coarse above the
/// fast anchor, ramped in between (``msPerPoint(forSpeed:)``). Holding ⌥
/// forces the fine anchor regardless of how fast the mouse is actually
/// moving, mirroring `DeviceRowView`'s ⌥-for-fine-step stepper convention.
///
/// **No inertial glide.** The tape moves exactly 1:1 with the drag/keyboard/
/// scroll input and nothing else — D6 requires the trim to apply
/// continuously *during* the gesture, so a release-time momentum animation
/// would move the value after the user stopped judging by ear, which is the
/// one thing this control must never do. Reduce Motion therefore has no
/// glide to disable; there is none to begin with.
///
/// Drawing is a plain `draw(_:)` override, not a `CALayer`-stamped
/// instrument, so it needs no ``Tokens/accentStyleDidChangeNotification``
/// observer (root AGENTS.md / `Tokens.swift`): every pass re-reads
/// `Tokens.Color.gold` live.
public final class BTSyncRulerView: NSView {

    // MARK: Local drawing constants (view-private — not shared column
    // geometry, so these stay out of `PopoverColumnGrid`)

    /// Major (labeled) ticks land on every 5th millisecond; every other
    /// integer millisecond in the draw loop is a minor tick.
    private static let majorTickEveryMs = 5
    /// Width of a single tick line.
    private static let tickLineWidth: CGFloat = 1
    /// Gap between a major tick's top and its numeric label's baseline.
    private static let labelGap: CGFloat = 2
    /// Base width of the centre pointer's downward-pointing cap triangle.
    private static let pointerCapWidth: CGFloat = 8
    /// Height (drop) of the centre pointer's cap triangle.
    private static let pointerCapHeight: CGFloat = 6
    /// Off-screen culling margin so a partially visible label at the view's
    /// edge is never skipped mid-draw.
    private static let offscreenCullMargin: CGFloat = 24
    /// Tick label font — tabular digits so a shifting number never rewidens
    /// its column (D5's numeric labels, spec: `.monospacedDigitSystemFont`).
    private static let tickLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

    /// Instantaneous drag speed (points/event) at or below which gearing is
    /// pinned to ``PopoverColumnGrid/syncRulerSlowMsPerPoint``.
    private static let speedFloorPtPerEvent: Double = 1
    /// Instantaneous drag speed (points/event) at or above which gearing is
    /// pinned to ``PopoverColumnGrid/syncRulerFastMsPerPoint``.
    private static let speedCeilingPtPerEvent: Double = 40

    // MARK: Public surface

    public weak var delegate: BTSyncRulerViewDelegate?

    /// Current value. Setting it externally (the drawer pushing a fresh
    /// `configure`) repositions the tape without firing the delegate — the
    /// delegate exists solely to report a USER gesture, and an external set
    /// is the host telling the ruler what the model already says, not a
    /// gesture the ruler itself originated.
    public var valueMs: Double {
        didSet {
            guard valueMs != oldValue else { return }
            needsDisplay = true
            updateAccessibilityValue()
        }
    }

    /// Hard stops (T3's per-device usable floor/ceiling). The tape refuses
    /// to scroll a committed value past these — every emitted value is
    /// clamped here before it reaches ``valueMs`` or the delegate. Ticks
    /// beyond the bound still draw (dimmed), so a user dragging toward the
    /// floor can see it coming rather than hitting an invisible wall.
    public var usableRangeMs: ClosedRange<Double> {
        didSet {
            guard usableRangeMs != oldValue else { return }
            needsDisplay = true
        }
    }

    public init() {
        self.valueMs = 0
        self.usableRangeMs = -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs
        super.init(frame: .zero)
        commonInit()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Sync offset")
        updateAccessibilityValue()
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }

        let halfSpanMs = PopoverColumnGrid.syncRulerVisibleSpanMs / 2
        let pointsPerMs = b.width / PopoverColumnGrid.syncRulerVisibleSpanMs
        let value = CGFloat(valueMs)

        // One extra millisecond of padding on each side so an edge label
        // never pops in/out mid-drag.
        let lowMs = Int((value - halfSpanMs).rounded(.down)) - 1
        let highMs = Int((value + halfSpanMs).rounded(.up)) + 1

        for t in lowMs...highMs {
            let x = b.midX + (CGFloat(t) - value) * pointsPerMs
            guard x >= b.minX - Self.offscreenCullMargin, x <= b.maxX + Self.offscreenCullMargin else { continue }

            let isMajor = t % Self.majorTickEveryMs == 0
            let inUsableRange = usableRangeMs.contains(Double(t))
            let baseColor: NSColor = isMajor ? Tokens.Color.tertiaryLabel : .quaternaryLabelColor
            let color = inUsableRange ? baseColor : baseColor.withAlphaComponent(PopoverColumnGrid.faderDisabledAlpha)
            let tickHeight = isMajor ? PopoverColumnGrid.syncRulerMajorTickHeight : PopoverColumnGrid.syncRulerMinorTickHeight

            color.setFill()
            NSRect(x: x - Self.tickLineWidth / 2, y: b.minY, width: Self.tickLineWidth, height: tickHeight).fill()

            guard isMajor else { continue }
            let label = "\(t)"
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.tickLabelFont, .foregroundColor: color]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: x - size.width / 2, y: b.minY + tickHeight + Self.labelGap), withAttributes: attrs)
        }

        // Centre pointer: a full-height accent line plus a small downward
        // cap at the top edge (D3) — the gold token, never `accent`, so a
        // user who chose "Follow system accent" sees the ruler track the
        // live system highlight color (`Tokens.swift`'s accent-dial comment).
        let pointerColor = Tokens.Color.gold
        pointerColor.setFill()
        NSRect(x: b.midX - PopoverColumnGrid.syncRulerPointerWidth / 2, y: b.minY,
               width: PopoverColumnGrid.syncRulerPointerWidth, height: b.height).fill()

        let cap = NSBezierPath()
        cap.move(to: NSPoint(x: b.midX - Self.pointerCapWidth / 2, y: b.maxY))
        cap.line(to: NSPoint(x: b.midX + Self.pointerCapWidth / 2, y: b.maxY))
        cap.line(to: NSPoint(x: b.midX, y: b.maxY - Self.pointerCapHeight))
        cap.close()
        cap.fill()
    }

    /// Traces the whole control for the standard system focus ring (same
    /// plain-`NSView` pattern as `DeviceIconWellView.drawFocusRingMask`) —
    /// AppKit draws/erases it automatically on first-responder transitions.
    public override func drawFocusRingMask() {
        NSBezierPath(rect: bounds).fill()
    }

    public override var focusRingMaskBounds: NSRect { bounds }

    // MARK: Drag (mouseDown → mouseDragged → mouseUp, tracked manually — D5/D6)

    private var isDragging = false

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
    }

    public override func mouseDragged(with event: NSEvent) {
        applyDrag(deltaX: event.deltaX, speedOverride: nil)
    }

    public override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    private func applyDrag(deltaX: CGFloat, speedOverride: Double?) {
        guard isDragging else { return }
        let perPoint = optionIsHeld
            ? PopoverColumnGrid.syncRulerSlowMsPerPoint
            : msPerPoint(forSpeed: speedOverride ?? Double(abs(deltaX)))
        emit(valueMs + Double(deltaX) * Double(perPoint), endScrub: false)
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        delegate?.syncRulerDidEndScrub(self)
    }

    /// D5's gearing curve: flat at the slow anchor at/below the speed floor,
    /// flat at the fast anchor at/above the speed ceiling, linear in
    /// log-speed between the two so gearing ramps rather than steps.
    private func msPerPoint(forSpeed speed: Double) -> CGFloat {
        let slow = PopoverColumnGrid.syncRulerSlowMsPerPoint
        let fast = PopoverColumnGrid.syncRulerFastMsPerPoint
        let clampedSpeed = max(speed, .leastNonzeroMagnitude)
        guard clampedSpeed > Self.speedFloorPtPerEvent else { return slow }
        guard clampedSpeed < Self.speedCeilingPtPerEvent else { return fast }
        let t = (log(clampedSpeed) - log(Self.speedFloorPtPerEvent))
              / (log(Self.speedCeilingPtPerEvent) - log(Self.speedFloorPtPerEvent))
        return slow + CGFloat(t) * (fast - slow)
    }

    /// ⌥ seam — same idiom as `DeviceRowView.test_optionModifierOverride`: a
    /// headless drag/keystroke carries no real `NSApp.currentEvent` — and, in
    /// a filtered `swift test` run where nothing else has yet touched
    /// `NSApplication.shared`, the `NSApp` global (`NSApplication!`, an
    /// implicitly-unwrapped optional) is still nil, so this reads it via `?`
    /// rather than `NSApp.currentEvent`'s implicit force-unwrap.
    public var test_optionModifierOverride: Bool?

    private var optionIsHeld: Bool {
        test_optionModifierOverride ?? (NSApp?.currentEvent?.modifierFlags.contains(.option) ?? false)
    }

    // MARK: Keyboard (←/→ resolutionMs, ⌥←/→ coarseStepMs)

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .some(.leftArrow):
            nudgeAndCommit(by: -(optionIsHeld ? BTSyncTrim.coarseStepMs : BTSyncTrim.resolutionMs))
        case .some(.rightArrow):
            nudgeAndCommit(by: optionIsHeld ? BTSyncTrim.coarseStepMs : BTSyncTrim.resolutionMs)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Scroll wheel (free — "trackpad users will try it")

    public override func scrollWheel(with event: NSEvent) {
        // Prefer the horizontal component (this is a horizontal ruler);
        // fall back to vertical for a plain mouse wheel. Either way, one
        // `scrollWheel` delivery is treated as one detent, matching the
        // resolution step regardless of how large that delivery's delta is.
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        guard delta != 0 else { return }
        nudgeAndCommit(by: delta > 0 ? BTSyncTrim.resolutionMs : -BTSyncTrim.resolutionMs)
    }

    // MARK: Accessibility (role/label/value set in `commonInit`; increment/decrement here)

    public override func accessibilityPerformIncrement() -> Bool {
        nudgeAndCommit(by: BTSyncTrim.resolutionMs)
        return true
    }

    public override func accessibilityPerformDecrement() -> Bool {
        nudgeAndCommit(by: -BTSyncTrim.resolutionMs)
        return true
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(Self.accessibilityValueDescription(for: valueMs))
    }

    /// D7's "22.4 ms later" readout, spelled out for VoiceOver ("22.4
    /// milliseconds later") — never a bare signed number, which spec D7
    /// calls out as ambiguous ("−22.4 vs +22.4 and users get the direction
    /// backwards").
    static func accessibilityValueDescription(for ms: Double) -> String {
        if ms == 0 { return "In sync" }
        let magnitude = String(format: "%.1f", abs(ms))
        return ms > 0 ? "\(magnitude) milliseconds later" : "\(magnitude) milliseconds earlier"
    }

    // MARK: Shared commit path (keyboard / AX increment-decrement / scroll —
    // each is a complete, discrete gesture, so each fires BOTH delegate
    // calls in one step, unlike a drag's many-scrubs-then-one-end shape)

    private func nudgeAndCommit(by deltaMs: Double) {
        emit(valueMs + deltaMs, endScrub: true)
    }

    /// The one path every gesture funnels through before touching
    /// ``valueMs`` or the delegate: quantise to `BTSyncTrim.resolutionMs`,
    /// then clamp to ``usableRangeMs`` (T3's hard stop, D11) — never emit a
    /// raw drag/nudge delta.
    private func emit(_ candidateMs: Double, endScrub: Bool) {
        let clamped = clampToUsableRange(BTSyncTrim.quantise(candidateMs))
        valueMs = clamped
        delegate?.syncRuler(self, didScrubTo: clamped)
        if endScrub {
            delegate?.syncRulerDidEndScrub(self)
        }
    }

    private func clampToUsableRange(_ ms: Double) -> Double {
        Swift.min(usableRangeMs.upperBound, Swift.max(usableRangeMs.lowerBound, ms))
    }

    // MARK: Test-support hooks (house convention: test_* drives the exact
    // same path the live gesture does, per `AudiouterSharedUI/AGENTS.md`'s
    // warning that a hook bypassing real dispatch can hide a real break —
    // these differ only in NOT synthesizing an `NSEvent`, since a drag/
    // scroll gesture can't be synthesized headlessly)

    /// Starts a drag, exactly as a real `mouseDown` would.
    public func test_beginScrub() {
        isDragging = true
    }

    /// One drag increment, as if `deltaX` points arrived in a single
    /// `mouseDragged` event. `speed` overrides the measured speed (default:
    /// `abs(deltaX)`, matching a real single-event drag) so a test can pin
    /// the slow/fast gearing bands independently of the distance dragged.
    public func test_scrub(byPoints deltaX: CGFloat, speed: CGFloat? = nil) {
        applyDrag(deltaX: deltaX, speedOverride: speed.map(Double.init))
    }

    /// Ends the drag, exactly as a real `mouseUp` would — fires
    /// `syncRulerDidEndScrub` exactly once.
    public func test_endScrub() {
        endDrag()
    }

    /// Drives the ←/→ keyboard-nudge path without synthesizing a real
    /// `NSEvent`.
    public func test_pressArrowKey(_ direction: TestArrowDirection, optionHeld: Bool = false) {
        let step = optionHeld ? BTSyncTrim.coarseStepMs : BTSyncTrim.resolutionMs
        nudgeAndCommit(by: direction == .right ? step : -step)
    }

    public enum TestArrowDirection {
        case left, right
    }
}
