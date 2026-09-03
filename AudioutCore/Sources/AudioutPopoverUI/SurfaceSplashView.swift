// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The branded hold the surface shows the FIRST time it opens in a process:
/// the brand mark over the wordmark on the one warm canvas, covering the
/// surface's content area for a beat and then fading out of the way.
///
/// A menu-bar app has no launch window, so first-open IS the moment this app
/// gets to say its name. It is ORNAMENT and nothing else — it carries no
/// state, blocks nothing the user asked for, and is skipped entirely under
/// Reduce Motion (a hold that exists to be looked at is exactly what that
/// setting turns off) and in every headless run, so the snapshot tools render
/// the screens they were pointed at.
///
/// It leaves on whichever comes LAST of the hold elapsing, the content being
/// in place, and network discovery having QUIESCED — so it never uncovers a
/// half-built panel or rows still sliding in. The host defers the whole
/// on-screen reveal until discovery settles (`DiscoverySettleTracker`), so this
/// hold is laid over an ALREADY-settled list at the settled size — content-ready
/// and settled are both true the instant it appears, leaving only the hold to
/// gate the cross-fade. A raised ``ceilingDuration`` is the backstop, because a
/// network that never quiets must not hold the hold forever. A click anywhere
/// dismisses it at once: the user who is already reaching for a fader has said
/// what they think of the ornament.
///
/// Composed of stock pieces (`WarmPanelView` ground, `NSImageView`,
/// `NSTextField`) — nothing here draws its own chrome, and the name is set in
/// the wordmark face (`Tokens.Font.wordmark`), which falls back to system bold
/// outside an assembled `.app`.
@MainActor
final class SurfaceSplashView: NSView {

    /// The MINIMUM the mark holds before it may start leaving.
    static let holdDuration: TimeInterval = 0.7
    /// The backstop: it fades at this point whatever else has happened. Raised
    /// from 1.2 s so a cold open's discovery (Bonjour/AirPlay/Cast/BT, which
    /// streams in over ~1–2 s) has room to quiet behind the cover before the
    /// settled frame is revealed — while still capping the wait so a network
    /// that never quiets can't trap the user behind the curtain.
    static let ceilingDuration: TimeInterval = 2.7
    /// The fade itself.
    static let fadeDuration: TimeInterval = 0.25
    /// Side of the mark's square image box.
    static let markSide: CGFloat = 96
    /// Size of the name beside the mark: the iPhone companion sets its wordmark
    /// at 32 pt against a 100 pt mark, so 96 × 0.32 = 30.72, rounded to a whole
    /// point.
    static let wordmarkSize: CGFloat = 31

    /// Once per PROCESS, never once per open: the second time a user summons
    /// the surface in a session they came for the mixer, not for the name.
    private(set) static var hasShownThisProcess = false

    /// `nil` = the live headless answer. A test run IS headless, so a test
    /// that wants a splash says so here.
    static var test_headlessOverride: Bool?

    /// `nil` = the live Reduce Motion setting.
    static var test_reduceMotionOverride: Bool?

    private static var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Install the splash over `host` if this open earns one. `nil` when it
    /// does not — the caller has nothing to hold on to and nothing to do.
    @discardableResult
    static func present(over host: NSView?) -> SurfaceSplashView? {
        guard let host,
              shouldPresent(headless: test_headlessOverride ?? HeadlessRuntime.isActive,
                            reduceMotion: reduceMotion,
                            alreadyShown: hasShownThisProcess)
        else { return nil }
        hasShownThisProcess = true
        let splash = SurfaceSplashView()
        splash.install(in: host)
        return splash
    }

    /// The whole decision, pure: ornament for a real run's first open only.
    static func shouldPresent(headless: Bool, reduceMotion: Bool, alreadyShown: Bool) -> Bool {
        !headless && !reduceMotion && !alreadyShown
    }

    /// Would `present(over:)` install a splash right now? The SAME decision, read
    /// with NO side effects (it does not set `hasShownThisProcess`), so the host
    /// can decide to defer the on-screen reveal until discovery settles BEFORE
    /// committing to the ornament.
    static var wouldPresent: Bool {
        shouldPresent(headless: test_headlessOverride ?? HeadlessRuntime.isActive,
                      reduceMotion: reduceMotion,
                      alreadyShown: hasShownThisProcess)
    }

    private var holdElapsed = false
    private var contentReady = false
    private var discoverySettled = false
    private var isLeaving = false
    private var timers: [Timer] = []

    private init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        // Opaque warm ground: the surface's own canvas, so the hold reads as
        // the surface arriving rather than as a sheet over it.
        let ground = WarmPanelView()
        ground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ground)

        let mark = NSImageView()
        mark.image = BrandMark.image
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.setAccessibilityElement(false)
        mark.translatesAutoresizingMaskIntoConstraints = false

        let wordmark = NSTextField(labelWithString: "Audiout")
        wordmark.font = Tokens.Font.wordmark(size: Self.wordmarkSize)
        wordmark.textColor = Tokens.Color.label
        wordmark.alignment = .center

        let stack = NSStackView(views: [mark, wordmark])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.widthAnchor.constraint(equalToConstant: Self.markSide),
            mark.heightAnchor.constraint(equalToConstant: Self.markSide),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func install(in host: NSView) {
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.holdDuration,
                                 repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdFinished() }
            },
            Timer.scheduledTimer(withTimeInterval: Self.ceilingDuration,
                                 repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.leave(animated: true) }
            },
        ]

        // A mid-hold Reduce Motion switch takes the ornament away at once —
        // the same answer as never having shown it (SharedUI AGENTS.md: an
        // accessibility-display change arrives through this notification and
        // nowhere else).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    /// The host's content is built and on screen. Part of the leave condition.
    func noteContentReady() {
        contentReady = true
        leaveIfReady()
    }

    /// Network discovery has quiesced and the settled frame has been applied
    /// behind this cover (`DiscoverySettleTracker`). The last part of the leave
    /// condition: the mark holds until the frame the user will see is settled,
    /// so it never uncovers rows still sliding into place.
    func noteDiscoverySettled() {
        discoverySettled = true
        leaveIfReady()
    }

    private func holdFinished() {
        holdElapsed = true
        leaveIfReady()
    }

    private func leaveIfReady() {
        guard holdElapsed, contentReady, discoverySettled else { return }
        leave(animated: true)
    }

    /// A click anywhere is a dismissal, and an immediate one: this view is
    /// over the control the user was reaching for.
    override func mouseDown(with event: NSEvent) {
        leave(animated: false)
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        guard Self.reduceMotion else { return }
        leave(animated: false)
    }

    private func leave(animated: Bool) {
        guard !isLeaving else { return }
        isLeaving = true
        timers.forEach { $0.invalidate() }
        timers = []
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Headless there is no run loop to carry the fade, so the terminal
        // state has to be applied in this turn or it is stranded. This one
        // reads the REAL answer, never the presentation seam: the seam says
        // whether this run deserves ornament, and this asks whether anything
        // will animate.
        guard animated, !HeadlessRuntime.isActive else {
            removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeFromSuperview()
        }
    }

    // MARK: Test-support hooks

    /// Forget that this process has shown a splash (one per process is a
    /// static fact, and a test process runs many opens).
    static func test_resetProcessFlag() { hasShownThisProcess = false }
    /// On screen and not yet faded away.
    var test_isVisible: Bool { superview != nil && alphaValue > 0 }
    /// The same paths the hold timer, the ceiling timer and a click take.
    func test_fireHoldTimer() { holdFinished() }
    func test_fireCeilingTimer() { leave(animated: true) }
    func test_click() { leave(animated: false) }
}
