// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import QuartzCore

/// The **leading-column VU meter** (task T1): a thin vertical bar whose green
/// fill height tracks the live per-device RMS the backend emits via
/// `BackendEvent.level(id:rms:)`. v1 is deliberately minimal — SINGLE GREEN
/// fill (`.systemGreen`), no yellow/red ramp, no peak-hold marker.
///
/// Two layers on one custom `CALayer`-backed view: a faint rounded "track"
/// (the recess the bar sits in) and a green "fill" layer that grows from the
/// bottom. Only the fill layer's height changes per frame.
///
/// **Ballistics, not a snap-to-target bar**: `setLevel` only records a target;
/// a `CVDisplayLink`-driven loop eases the *displayed* level toward it every
/// frame via ``ballisticsStep(displayed:target:)``, with a faster attack
/// (rising) than decay (falling) — the classic VU-meter feel where the needle
/// jumps up but eases down. The pure step function is exposed standalone so it
/// can be unit-tested without a live display link.
///
/// **Self-stopping is the whole point of this being a custom view instead of
/// `NSLevelIndicator`**: once the displayed level has eased down to ~0 and the
/// target is also 0 (silence, or the meter went idle), the display link is
/// invalidated and released — zero CPU at rest. The next `setLevel(>0)`
/// restarts it. Every popover row gets one of these, so an always-running
/// per-row display link would be a real cost with several devices visible.
///
/// Mirrors ``StatusDotView``'s layer + Reduce-Motion idioms: `updateLayer` /
/// `viewDidChangeEffectiveAppearance` for colour re-resolution, and a Reduce
/// Motion check that snaps instead of animating.
public final class LevelMeterView: NSView {

    /// Width of the meter column — matches `PopoverColumnGrid.meterWidth`
    /// (duplicated here as a `public static let` per the shared symbol
    /// contract; `AirPlayControllerSharedUI` does not import the grid type).
    public static let columnWidth: CGFloat = 8

    /// Attack coefficient (rising level) — larger than `decay` so the bar
    /// jumps up quickly on a transient.
    private static let attack: CGFloat = 0.5
    /// Decay coefficient (falling level) — smaller than `attack` so the bar
    /// eases down, the classic VU-meter feel.
    private static let decay: CGFloat = 0.12
    /// Below this displayed level (with a zero target) the bar is considered
    /// at rest and the display link is torn down.
    private static let restEpsilon: CGFloat = 0.001

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    /// The most recently requested level (post-clamp), i.e. what the display
    /// link eases `displayed` toward.
    private var target: CGFloat = 0
    /// The currently-drawn level, eased toward `target` each frame.
    private var displayed: CGFloat = 0

    /// Display link driven by the modern NSView.displayLink API (macOS 14.0+),
    /// eliminating manual Unmanaged pointer management. The API keeps a strong
    /// reference to the target (self) while the display link is active.
    private var activeLink: CADisplayLink?

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        trackLayer.cornerRadius = Self.columnWidth / 2
        fillLayer.cornerRadius = Self.columnWidth / 2
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        updateLayerColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        stopDisplayLink()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.columnWidth, height: 22)
    }

    /// Non-interactive: the meter never intercepts clicks/hover meant for the
    /// row beneath it.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Colours

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        updateLayerColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor = NSColor.tertiarySystemFill.cgColor
            fillLayer.backgroundColor = NSColor.systemGreen.cgColor
        }
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        trackLayer.frame = bounds
        redrawFill()
    }

    /// Sizes the fill layer's height to the current `displayed` level,
    /// growing from the bottom, inside a disabled-action transaction so
    /// per-frame updates never trigger implicit Core Animation animations or
    /// Auto Layout passes.
    /// The quietest level (dBFS) shown as any fill. Raw RMS for normal program
    /// material reads very low (music RMS ≈ 0.03–0.15 ≈ −30…−16 dBFS), so mapping
    /// it LINEARLY onto the bar made real audio a near-invisible sliver
    /// (live-observed 2026-07-22). Tunable by eye.
    static let meterFloorDB: Float = -54

    /// Map a raw linear RMS level (0…1) to a bar-fill fraction (0…1) on a
    /// perceptual dB scale — dBFS across [`meterFloorDB`, 0] → [0, 1] — so typical
    /// listening levels fill a healthy portion of the meter, like a hardware
    /// VU/PPM meter, instead of a linear sliver. Ballistics still ease in raw-RMS
    /// space (`displayed`/`target` are unchanged); only the final HEIGHT is shaped,
    /// so `setLevel`/`test_meterLevel` keep round-tripping the raw value.
    static func displayHeight(forLevel rms: CGFloat) -> CGFloat {
        let x = Float(rms)
        guard x > 0 else { return 0 }
        let dbfs = 20 * log10(x)
        if dbfs <= meterFloorDB { return 0 }
        if dbfs >= 0 { return 1 }
        return CGFloat((dbfs - meterFloorDB) / (0 - meterFloorDB))
    }

    private func redrawFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = bounds.height * Self.displayHeight(forLevel: displayed)
        fillLayer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        CATransaction.commit()
    }

    // MARK: Public API

    /// Push a new RMS reading. Clamps to `0...1`, records it as the ballistics
    /// target, and starts the display link if it isn't already running.
    /// Reduce Motion snaps `displayed` to the target immediately instead of
    /// easing (mirrors `StatusDotView`).
    public func setLevel(_ rms: Float) {
        let clamped = CGFloat(min(max(rms, 0), 1))
        target = clamped
        if reduceMotion {
            displayed = clamped
            redrawFill()
            if clamped <= Self.restEpsilon {
                stopDisplayLink()
            }
            return
        }
        startDisplayLinkIfNeeded()
    }

    /// Zero the meter immediately (no ease-out) and stop the display link —
    /// used when a row/device goes away or metering turns off.
    public func reset() {
        target = 0
        displayed = 0
        redrawFill()
        stopDisplayLink()
    }

    /// True while the OS is set to reduce motion — a static bar is shown then
    /// (mirrors `StatusDotView.reduceMotion`).
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Ballistics

    /// One ease step from `displayed` toward `target`. Pure and static so it
    /// can be unit-tested without a live display link. The attack coefficient
    /// (rising) is larger than the decay coefficient (falling) — the bar
    /// jumps up on a transient and eases back down.
    public static func ballisticsStep(displayed: CGFloat, target: CGFloat) -> CGFloat {
        let coefficient = target > displayed ? attack : decay
        return displayed + (target - displayed) * coefficient
    }

    // MARK: Display link

    /// Create and activate a display link using the modern NSView.displayLink API
    /// (macOS 14.0+). This API manages strong references to the target
    /// automatically, eliminating the manual Unmanaged pointer dance and its
    /// dependency on precise cleanup ordering.
    private func startDisplayLinkIfNeeded() {
        guard activeLink == nil else { return }
        let link = self.displayLink(target: self, selector: #selector(tick))
        link.add(to: RunLoop.main, forMode: .default)
        activeLink = link
    }

    /// Stop and invalidate the display link. The modern NSView.displayLink API
    /// handles cleanup of the target reference automatically upon invalidation.
    private func stopDisplayLink() {
        guard let link = activeLink else { return }
        link.invalidate()
        activeLink = nil
    }

    /// One frame of ballistics, called on the main thread by the display link
    /// callback. Stops and releases the link once the bar has eased down to
    /// rest at a zero target — the zero-CPU-at-rest property.
    /// Marked @objc to enable selector-based callback from CADisplayLink via
    /// NSView.displayLink(target:selector:).
    @objc private func tick() {
        displayed = Self.ballisticsStep(displayed: displayed, target: target)
        redrawFill()
        if target <= Self.restEpsilon && displayed <= Self.restEpsilon {
            displayed = 0
            redrawFill()
            stopDisplayLink()
        }
    }

    // MARK: Test-support hooks

    /// Sets `displayed` synchronously and redraws inside a disabled-action
    /// transaction WITHOUT starting the display link — deterministic for
    /// snapshots/tests that can't wait on a live animation loop.
    public func test_setDisplayedLevel(_ level: CGFloat) {
        displayed = min(max(level, 0), 1)
        redrawFill()
    }
}
