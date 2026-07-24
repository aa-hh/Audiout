// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI
import QuartzCore

/// The **under-name VU meter** (Warm Signal v4 §Call-1, relocated from the
/// leading column): a short HORIZONTAL bar (`meterUnderNameWidth` ×
/// `meterUnderNameHeight` ≈ 74 × 3 pt) sitting under the device name, whose fill
/// WIDTH tracks the live per-device RMS the backend emits via
/// `BackendEvent.level(id:rms:)`. It grows LEFT → RIGHT. It is visually distinct
/// from the fader (thin, thumb-less, in the identity cluster not the slider
/// column) — killing the v3 "two gold bars, which is which?" confusion.
///
/// **Warm meter gradient (Warm Signal v3 §1/§3.3, S2):** the fill is the
/// position-fixed warm ramp `ember → gold` with the right zone at `caution` —
/// the meter's CEILING hue. The old green/red vocabulary is retired, and
/// FAILURE RED NEVER APPEARS IN A METER (house rule 8): a loud party can
/// never impersonate a failure; `caution` is as hot as a meter gets. The
/// gradient is anchored to the TRACK, not the bar — a full-width
/// `CAGradientLayer` revealed through a leading-anchored mask — so the hues
/// live at fixed widths (left = ember, right = caution) and the bar
/// "uncovers" them as it grows, like a hardware LED ladder.
///
/// Three layers on one custom `CALayer`-backed view: a faint rounded "track"
/// (the recess the bar sits in), the full-height warm gradient, and the
/// gradient's mask whose height is the displayed level. Only the mask's
/// height changes per frame.
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
/// Mirrors `StatusDotView`'s layer + Reduce-Motion idioms: `updateLayer` /
/// `viewDidChangeEffectiveAppearance` for colour re-resolution, and a Reduce
/// Motion check that snaps instead of animating.
public final class LevelMeterView: NSView {

    /// Thickness (height) of the under-name meter bar — matches
    /// `PopoverColumnGrid.meterUnderNameHeight` (kept as a `public static let`
    /// for the shared symbol contract: it is the DEFAULT thickness every
    /// existing caller gets, and stays the device-row value). Drives the bar's
    /// rounded end caps for any instance that doesn't override ``thickness``.
    public static let columnWidth: CGFloat = PopoverColumnGrid.meterUnderNameHeight

    /// Per-instance bar thickness (Warm Signal v4.1 item 1 — the master
    /// strip): device/app meters keep the shared ``columnWidth`` default, the
    /// Main Audio row's meter passes `PopoverColumnGrid.masterMeterThickness`
    /// (6 pt vs 3 pt) so it reads as a heavier-gauge sibling of the device
    /// meters. Drives both the track/fill corner radius (rounded caps scale
    /// with thickness) and, via ``intrinsicContentSize``, the bar's height.
    private let thickness: CGFloat

    /// Attack coefficient (rising level) — larger than `decay` so the bar
    /// jumps up quickly on a transient.
    private static let attack: CGFloat = 0.5
    /// Decay coefficient (falling level) — smaller than `attack` so the bar
    /// eases down, the classic VU-meter feel.
    private static let decay: CGFloat = 0.12
    /// Below this displayed level (with a zero target) the bar is considered
    /// at rest and the display link is torn down.
    private static let restEpsilon: CGFloat = 0.001

    /// Gradient stop for where `ember` has fully warmed to `gold` (fraction of
    /// the track width). Left of this the bar reads ember-dim; the healthy
    /// listening band reads gold.
    static let meterGoldStop: NSNumber = 0.7
    /// The `caution` right-zone onset: gold blends toward the `caution` ceiling
    /// across the final stretch of the track (spec: "meters top out HERE").
    static let meterCautionStop: NSNumber = 1.0

    private let trackLayer = CALayer()
    /// The full-width, position-fixed warm gradient (`ember → gold →
    /// caution`), revealed through ``fillMaskLayer``.
    private let fillLayer = CAGradientLayer()
    /// Leading-anchored mask over ``fillLayer`` — its width IS the displayed
    /// level; the gradient itself never moves or rescales.
    private let fillMaskLayer = CALayer()

    /// The most recently requested level (post-clamp), i.e. what the display
    /// link eases `displayed` toward.
    private var target: CGFloat = 0
    /// The currently-drawn level, eased toward `target` each frame.
    private var displayed: CGFloat = 0

    private var displayLink: CVDisplayLink?

    /// - Parameter thickness: bar thickness (height). Defaults to the shared
    ///   ``columnWidth`` — every pre-existing caller (`DeviceRowView`,
    ///   `AppRowView`, tests) is unaffected. `MainOutRowView` is the one
    ///   caller that overrides it, to `PopoverColumnGrid.masterMeterThickness`.
    public init(thickness: CGFloat = LevelMeterView.columnWidth) {
        self.thickness = thickness
        super.init(frame: .zero)
        wantsLayer = true
        trackLayer.cornerRadius = thickness / 2
        // The visible fill's rounded cap comes from the MASK (the moving bar),
        // not the fixed gradient sheet it reveals.
        fillMaskLayer.cornerRadius = thickness / 2
        fillMaskLayer.backgroundColor = NSColor.black.cgColor   // opaque = revealed
        // Left-to-right ramp: startPoint is the bar's base (ember, leading),
        // endPoint the track's ceiling (caution, trailing).
        fillLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fillLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fillLayer.locations = [0, Self.meterGoldStop, Self.meterCautionStop]
        fillLayer.mask = fillMaskLayer
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        updateLayerColors()
        // The warm-token Increase-Contrast variants resolve off the LIVE
        // `NSWorkspace` flag, not the appearance name — so a mid-session
        // Increase Contrast toggle must re-stamp the (static CGColor) gradient
        // directly off the display-options notification rather than trusting
        // an appearance change to arrive (same pattern as `HaloRingView`).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        updateLayerColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        stopDisplayLink()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: PopoverColumnGrid.meterUnderNameWidth, height: thickness)
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
            // The empty track must stay visible at every level so the meter's
            // full scale (the ratio's denominator) always reads — `meterTrack`
            // is a warm recess with a measured floor, replacing the near-
            // invisible `tertiarySystemFill` (UX contrast pass, 2026-07-23).
            trackLayer.backgroundColor = Tokens.Color.meterTrack.cgColor
            // The warm ramp (S2): ember low end → gold body → caution ceiling.
            // NEVER `failure` red (house rule 8). Re-stamped on every
            // appearance/Increase-Contrast change since CGColors are static.
            fillLayer.colors = [
                Tokens.Color.ember.cgColor,
                Tokens.Color.gold.cgColor,
                Tokens.Color.caution.cgColor,
            ]
        }
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        trackLayer.frame = bounds
        // The gradient sheet always spans the FULL track; only the mask moves.
        fillLayer.frame = bounds
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
        let width = bounds.width * Self.displayHeight(forLevel: displayed)
        // Mask coordinates are the gradient layer's own space (same bounds):
        // a leading-anchored reveal window. The gradient never moves (S2 —
        // hues live at fixed track widths).
        fillMaskLayer.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
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
        // Zero-target-while-already-at-rest: nothing to ease — don't spin up a
        // display link just to discover it's at rest one frame later (energy
        // rule; S3's mute drain re-applies target 0 on every model refresh).
        if clamped <= Self.restEpsilon && displayed <= Self.restEpsilon {
            displayed = 0
            redrawFill()
            stopDisplayLink()
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

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<LevelMeterView>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                view.tick()
            }
            return kCVReturnSuccess
        }, context)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    /// One frame of ballistics, called on the main thread by the display link
    /// callback. Stops and releases the link once the bar has eased down to
    /// rest at a zero target — the zero-CPU-at-rest property.
    private func tick() {
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

    /// The current ballistics target (post-clamp). Together with
    /// ``test_displayedLevel`` it distinguishes a mute DRAIN (target 0 while
    /// `displayed` is still easing down — S3's reuse of the decay path) from a
    /// hard ``reset()`` (both snap to 0 instantly).
    public var test_targetLevel: CGFloat { target }

    /// The currently drawn level (what the mask height renders from).
    public var test_displayedLevel: CGFloat { displayed }

    /// The warm gradient's current fill colors, bottom → top (resolved against
    /// the effective appearance) — asserts the `ember → gold → caution` ramp
    /// and that failure red never appears in a meter (house rule 8).
    public var test_gradientColors: [NSColor] {
        (fillLayer.colors as? [CGColor])?.compactMap { NSColor(cgColor: $0) } ?? []
    }
}
