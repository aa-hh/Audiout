// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import QuartzCore

/// What lays itself out from an in-flight fold on every tick — the popover
/// panel re-fits and republishes its size; the Settings Audio pane republishes
/// its `preferredContentSize`. Weakly held by the driver.
@MainActor
public protocol FoldFollowing: AnyObject {
    func foldAnimatorDidTick()
}

/// The ONE clock every fold in the app runs on — a popover card body
/// (`CardView.setBodyCollapsed`), a device-type subsection, a single-row
/// reveal (`insertRow`/`removeRow`), and the Settings Advanced disclosure.
///
/// A fold used to be TWO separately-clocked animations: the clip-height
/// constraint under `NSAnimationContext` (easeInOut) and the surface window
/// under `setFrame(_:display:animate:)` (AppKit's own resize curve, stepped on
/// the runloop). Two clocks running two curves cannot stay in phase, and the
/// drift showed for the whole travel — the rail overlay overshooting, the
/// content shifting against the window (live captures, 2026-08-11).
///
/// So a fold now has exactly ONE animated value, the clip height, and
/// everything else is laid out FROM it, synchronously, every tick: the panel
/// re-fits and publishes that size. The window is not the second clock any
/// more because it is not a clock at all — the surface frame is FIXED for the
/// whole open session, so the rows travel inside it and the panel's surplus
/// shield absorbs whatever gap the fold opens at the bottom. A web accordion,
/// not two animations agreeing to travel at the same pace.
///
/// Constants are set DIRECTLY: never through `animator()`, never inside an
/// `NSAnimationContext`, never with `allowsImplicitAnimation`. Any of those
/// puts a second clock back on the one value this driver owns.
///
/// The one clock is a `CADisplayLink`, so ticks land on the display's vsync
/// instead of on a fixed 120 Hz timer that fires whether or not a frame is
/// coming. A screenless process (a headless test host) has no display link to
/// take, so a coalescing `Timer` stands in as the fallback clock there.
@MainActor
public final class FoldAnimator: NSObject {

    /// One driver for the process: a `CardView` can be folded without a panel
    /// (the trajectory unit tests build a bare card), so the fold clock cannot
    /// hang off the panel.
    public static let shared = FoldAnimator()

    /// Whether any fold is in flight. Surface subscribers use this to publish
    /// per-tick sizes INSTANTLY during a fold instead of starting a window
    /// animation of their own — the second clock this driver exists to forbid.
    public var isFolding: Bool { !tweens.isEmpty }

    /// One in-flight fold.
    private struct Tween {
        /// Weak: the clip that owns it can be torn down mid-fold, and a
        /// vanished constraint has no terminal state left to apply.
        weak var constraint: NSLayoutConstraint?
        let start: CGFloat
        let target: CGFloat
        let startTime: CFTimeInterval
        /// What lays itself out from this fold each tick. `nil` when there is
        /// nothing above the folding view to keep in step.
        weak var follower: (any FoldFollowing)?
        let completion: () -> Void
    }

    private var tweens: [Tween] = []
    /// The vsync clock. `NSScreen.displayLink` keeps a strong reference to its
    /// target (self) while active — the same retention contract `LevelMeterView`
    /// documents for the view-side call.
    private var link: CADisplayLink?
    /// Fallback clock only: used when the process has no screen to take a
    /// display link from.
    private var timer: Timer?

    /// Test seam for Reduce Motion (`nil` = the live system setting).
    public var test_reduceMotionOverride: Bool?

    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Fold `constraint` to `target`, calling `completion` once it arrives.
    ///
    /// Under Reduce Motion nothing travels: every in-flight fold — including the
    /// one just added — is settled to its terminal state synchronously, in the
    /// caller's own turn, follower ticked once and completions fired. That is
    /// the same synchronous-terminal contract every caller's `animated: false`
    /// branch already has, so callers need no extra handling.
    ///
    /// Retarget: a constraint that is already folding has its running tween
    /// REPLACED, and the replaced tween's completion never fires — the terminal
    /// state belongs to whichever fold arrives last. The replacement starts at
    /// the constraint's LIVE constant, never at a rest height: jumping the
    /// content to a rest height first makes it momentarily TALLER than the
    /// surface, the one deformation the panel's surplus shield cannot absorb
    /// (rows riding up to the window top on rapid toggles).
    public func animate(_ constraint: NSLayoutConstraint,
                        to target: CGFloat,
                        follower: (any FoldFollowing)?,
                        completion: @escaping () -> Void) {
        tweens.removeAll { $0.constraint === constraint }
        tweens.append(Tween(constraint: constraint,
                            start: constraint.constant,
                            target: target,
                            startTime: CACurrentMediaTime(),
                            follower: follower,
                            completion: completion))
        // Sample tick 0 in the caller's own turn: the surface has to be sized
        // from the fold's START state before anything displays, or the first
        // clock tick lands as a step instead of a frame of travel.
        //
        // razor: deliberate ceiling — no observer for a Reduce Motion toggle
        // flipped MID-fold. A fold lasts `Tokens.Motion.collapseRevealDuration`,
        // and every caller gates on Reduce Motion too, so the window is
        // vanishingly small. Upgrade path: observe
        // `accessibilityDisplayOptionsDidChangeNotification` and settle the
        // in-flight tweens from it.
        advance(to: reduceMotion ? .greatestFiniteMagnitude : CACurrentMediaTime())
        startClockIfNeeded()
    }

    /// Test hook: run every in-flight fold straight to its end state — the
    /// runloop time a headless test cannot spend. Same tick order as the clock.
    public func test_settleNow() { advance(to: .greatestFiniteMagnitude) }

    private func startClockIfNeeded() {
        guard link == nil, timer == nil, !tweens.isEmpty else { return }
        // `.common` mode: a fold started by a mouse-down that is still held (a
        // header-row click) has to keep ticking inside event tracking.
        //
        // The link is per-`NSScreen` vsync and this driver has no view to hang
        // it off (a torn-down view's link would pause mid-fold and strand the
        // other tweens), so it takes the main screen's. A fold shown on another
        // screen is still frame-paced, just to the wrong display's rhythm.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let l = screen.displayLink(target: self, selector: #selector(clockDidTick))
            l.add(to: RunLoop.main, forMode: .common)
            link = l
        } else {
            let ticker = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advance(to: CACurrentMediaTime()) }
            }
            // Let the runloop coalesce these ticks: the fallback clock has no
            // vsync to align to, so exact 120 Hz buys nothing and costs wakeups.
            ticker.tolerance = 1.0 / 240.0
            RunLoop.main.add(ticker, forMode: .common)
            timer = ticker
        }
    }

    /// Marked `@objc` for the selector-based `NSScreen.displayLink` callback.
    @objc private func clockDidTick() { advance(to: CACurrentMediaTime()) }

    private func stopClock() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    /// One tick, in the order the whole design rests on: (1) set every animated
    /// value, (2) ONE layout + surface-follow per panel, (3) terminal states.
    /// Any other order lets the window be sized from a value the content has
    /// not been laid out at.
    private func advance(to now: CFTimeInterval) {
        let duration = Tokens.Motion.collapseRevealDuration
        var running: [Tween] = []
        var arrived: [Tween] = []

        for tween in tweens {
            // A constraint whose views are gone is dropped silently: whoever
            // tore them down owns the height now.
            guard let constraint = tween.constraint else { continue }
            let t: CGFloat = duration > 0
                ? CGFloat(min(1, max(0, (now - tween.startTime) / duration)))
                : 1
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            constraint.constant = tween.start + (tween.target - tween.start) * e
            if t >= 1 { arrived.append(tween) } else { running.append(tween) }
        }

        // The follow step, once per panel however many folds it is running.
        var followed = Set<ObjectIdentifier>()
        for tween in running + arrived {
            guard let follower = tween.follower,
                  followed.insert(ObjectIdentifier(follower)).inserted else { continue }
            follower.foldAnimatorDidTick()
        }

        // Published BEFORE the completions run, so a completion is free to
        // start a fold of its own without this pass discarding it.
        tweens = running
        for tween in arrived { tween.completion() }

        if tweens.isEmpty { stopClock() } else { startClockIfNeeded() }
    }
}
