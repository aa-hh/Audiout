// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Which miniature the demo pane is showing for the active step. Public only
/// because the Setup window's `test_demoMode` hook exposes it.
public enum DemoMode: Equatable, Sendable {
    /// The step's first ask: a miniature of whatever surface that ask raises,
    /// with a cursor pressing its confirming button — the privacy dialog for
    /// most steps, the Accessibility alert and the pane it hands off to for
    /// Remote Control.
    case prompt
    /// The retry path (and Speaker Sync always, which has no prompt at all): a
    /// miniature of the System Settings pane, with a toggle switching on.
    case settings
    /// Every permission is in — the finale: a one-shot gold signal ripple on
    /// the transition in, then a fully static resting frame. No loop.
    case settled
}

/// Where a TWO-STAGE mock is in its pass. One step has one — Remote Control,
/// whose first ask raises the system alert before the Settings pane it opens.
/// Public only because the Setup window's `test_demoStage` hook exposes it.
public enum DemoStage: Equatable, Sendable {
    /// The system ALERT that hands the user off to Settings — the first of the
    /// two clicks, and the thing a two-stage pass rests on.
    case alert
    /// The Settings pane that alert opens, with the switch to flip.
    case settingsPane
}

/// The Setup window's right pane: a native-drawn miniature of the exact surface
/// the active step's Allow button is about to put in front of the user, so the
/// dialog or Settings pane is already familiar when it appears.
///
/// **Everything here is drawn in code** — no screenshots, no recordings, no
/// bundled images (`NSApp.applicationIconImage` and SF Symbols aside). That is
/// the whole point: a captured GIF of a macOS dialog goes stale the release
/// after it ships (Wispr's mic-prompt GIF already has), while drawn chrome
/// re-resolves its tokens per appearance and never claims to be a screenshot.
/// This is an approved custom-drawn exception to the stock-controls house rule,
/// confined to this file — see this folder's AGENTS.md.
///
/// **Motion policy** (owner rule, binding): Reduce Motion OFF → the active
/// step's mock loops, but ONLY while its window is on screen (occlusion state);
/// it stops the moment the window is hidden or the pane has nothing active, so
/// an idle Setup window burns no CPU. Reduce Motion ON → the mock plays ONCE
/// when the step becomes active, rests at its settled final frame, and offers a
/// Replay button. Off-window and headless runs never animate at all, so the
/// snapshot fixtures always capture the settled frame. The settled finale is
/// the one exception to the loop rule: a ONE-SHOT celebration, never a loop
/// and never a Replay — see ``DemoSettledMockView``.
///
/// The demo is DECORATIVE: it is excluded from the accessibility tree entirely
/// (the card copy beside it carries every word of the information). Only Replay,
/// a real control, stays accessible.
final class DemoPaneView: NSView {

    /// The STAGE the mocks play on — fixed, so consecutive steps read at the
    /// same scale rather than the pane resizing under the user.
    ///
    /// There is no drawn surface under it any more (Direction 04, the
    /// rehearsal-led restructure): the HERO PANE owns the chrome, and this view
    /// is the bare stage inside it. The WIDTH is that pane's interior — 462
    /// hero pane − 2 × 22 interior padding = 418 — but the FINALE's ripple is no
    /// longer bounded by this stage OR the hero panel: it radiates across the
    /// WHOLE Setup window, crossing the stage frame and the hero panel's edges
    /// on every side with nothing clipping or feathering it (owner calls
    /// 2026-08-11: first "grow the stage, don't shrink the wave" after a live
    /// hard clip, then rejecting the shrunken-travel fix as "one little line";
    /// owner call 2026-08-12: fill the panel, not the stage; then, the panel
    /// gaining almost nothing over the stage, radiate across the whole window and
    /// fade to nothing BEFORE the window's nearest edge — see
    /// `DemoSettledMockView.ringEndScale()` / `rippleFadeFraction`). The HEIGHT
    /// is what the preview FRAME really has
    /// to give on a two-line why line — 278 — rather than the 330 the frame was
    /// silently cropping 50 pt off. Every mock is smaller than the stage and
    /// centred on it, so the slack is simply margin for them, and Replay still
    /// fits below at +14.
    static let surfaceSize = NSSize(width: 418, height: 278)

    /// The step-to-step content crossfade.
    static let stepCrossfadeDuration: TimeInterval = 0.22

    /// How long the waiting beat's dim takes.
    static let stageDimDuration: TimeInterval = 0.2
    /// How far the stage dims while a real system dialog is on screen — the
    /// rehearsal steps back when the real thing is in front of the user.
    static let stageDimmedAlpha: CGFloat = 0.5

    /// Hosts the current mock; the accessibility opt-out lives here so Replay
    /// (outside it) stays reachable.
    private let mockHost = NSView()
    private var mock: NSView?
    private let replayButton: NSButton

    private var step: SetupStep?
    private var mode: DemoMode = .prompt
    /// Whether what's on stage is a read-only BROWSE of an already-decided
    /// step. A browse never animates — only the active step's rehearsal loops.
    private var isBrowse = false
    /// Whether a browsed Settings mock rests with its switch already ON.
    private var restingSwitchOn = false

    private var occlusionObserver: NSObjectProtocol?

    /// The window-spanning view the finale ripple radiates across — the Setup
    /// window's whole content, wired by the view controller so the rings sweep
    /// the entire window and fade out before its nearest edge, rather than
    /// halting at the hero panel (a whole-window celebration, owner call
    /// 2026-08-12). Handed to each settled mock as it is built. Nothing between
    /// the stage and this host clips in the finale state — the chromeless well,
    /// the (unmasked) hero panel and the canvas all pass the rings through — so
    /// widening the reach needed only this re-pointing, no reparenting.
    weak var finaleRippleBounds: NSView?

    init() {
        replayButton = NSButton(title: "Replay", target: nil, action: nil)
        super.init(frame: .zero)
        build()
        registerForLiveDisplayChanges()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    // MARK: Build

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        mockHost.translatesAutoresizingMaskIntoConstraints = false
        // Decorative: the whole mock subtree is invisible to VoiceOver.
        // Un-electing the HOST alone is not enough — an ignored container HOISTS
        // its children, which leaves the mock's real `NSTextField`s ("Allow",
        // "Don't Allow", the pane title) reachable. Every descendant is un-elected
        // too, as it is installed (`installAccessibilityOptOut`).
        mockHost.setAccessibilityElement(false)
        mockHost.setAccessibilityChildren([])

        addSubview(mockHost)

        replayButton.bezelStyle = .rounded
        replayButton.controlSize = .small
        replayButton.target = self
        replayButton.action = #selector(replayTapped)
        replayButton.translatesAutoresizingMaskIntoConstraints = false
        replayButton.isHidden = true
        addSubview(replayButton)

        // Nothing in here may push the fixed window taller, so Replay's own
        // placement is the breakable one.
        let replayBelow = replayButton.topAnchor.constraint(equalTo: mockHost.bottomAnchor, constant: 14)
        replayBelow.priority = .defaultHigh
        NSLayoutConstraint.activate([
            // The STAGE is a fixed size — the finale fills it exactly, and a
            // stage that resized per mock would move the ribbon under it every
            // time the step changed.
            widthAnchor.constraint(equalToConstant: Self.surfaceSize.width),
            heightAnchor.constraint(equalToConstant: Self.surfaceSize.height),

            mockHost.centerXAnchor.constraint(equalTo: centerXAnchor),
            mockHost.centerYAnchor.constraint(equalTo: centerYAnchor),

            replayButton.centerXAnchor.constraint(equalTo: mockHost.centerXAnchor),
            replayBelow,
        ])
    }

    /// A layer-colour instrument has to reconcile its live re-resolution triggers
    /// itself (SharedUI AGENTS.md), because none of them reach a view through
    /// `viewDidChangeEffectiveAppearance` or a model push. Three apply here: a
    /// mid-session Reduce Motion toggle, which changes the motion POLICY; the
    /// user's macOS accent, which the mock's confirming button stamps as a
    /// resolved `CGColor`; and Increase Contrast, which `DemoSystemColor`'s
    /// surface-ladder and button-emphasis values resolve differently (see the
    /// enum's doc comment) but which — like the accent — doesn't touch
    /// `effectiveAppearance`, so a toggle mid-session needs its own trigger too.
    /// The app's OWN accent dial is deliberately not one of them — nothing
    /// inside a mock is painted from `Tokens`, that is the point of the
    /// system-look rule.
    private func registerForLiveDisplayChanges() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged),
            name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        // The policy itself changed — re-derive it from scratch.
        reconcileMotion(restartUnderReduceMotion: false)
        // Increase Contrast doesn't change `effectiveAppearance`, so the mock's
        // `DemoSystemColor` fills won't otherwise re-resolve until something else
        // forces a repaint — same reasoning as `systemColorsChanged` below.
        mock?.subviewsRecursively.forEach { $0.needsDisplay = true }
        mock?.needsDisplay = true
    }

    @objc private func systemColorsChanged() {
        // Stamped CGColors don't track the system accent on their own.
        mock?.subviewsRecursively.forEach { $0.needsDisplay = true }
        mock?.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window = window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcileMotion(restartUnderReduceMotion: false) }
                }
        }
        reconcileMotion(restartUnderReduceMotion: false)
    }

    // MARK: Content

    /// Show the miniature for `step` in `mode`. `animated` crossfades the swap
    /// (the grant choreography's last beat); pass false for the first build,
    /// Reduce Motion, and any off-screen window.
    ///
    /// - Parameters:
    ///   - restingSwitchOn: the browsed Settings pane rests with its switch
    ///     already ON — the scoped amendment to "a pass ends where it started".
    ///     A granted step really would be found switched on.
    ///   - asBrowse: this is a read-only look at an already-decided step, not
    ///     the live rehearsal. It never animates.
    func show(step: SetupStep?, mode: DemoMode, animated: Bool,
              restingSwitchOn: Bool = false, asBrowse: Bool = false) {
        let changed = step != self.step || mode != self.mode || mock == nil
            || restingSwitchOn != self.restingSwitchOn || asBrowse != self.isBrowse
        self.step = step
        self.mode = mode
        self.restingSwitchOn = restingSwitchOn
        self.isBrowse = asBrowse
        guard changed else { return }

        let outgoing = mock
        let incoming = Self.makeMock(step: step, mode: mode, restingSwitchOn: restingSwitchOn)
        mock = incoming
        // The finale's rings fade out before the whole window's edges, so the
        // settled mock needs to know the window-spanning host it radiates across.
        (incoming as? DemoSettledMockView)?.rippleBoundsView = finaleRippleBounds
        incoming.translatesAutoresizingMaskIntoConstraints = false
        Self.installAccessibilityOptOut(incoming)
        mockHost.addSubview(incoming)
        NSLayoutConstraint.activate([
            incoming.leadingAnchor.constraint(equalTo: mockHost.leadingAnchor),
            incoming.trailingAnchor.constraint(equalTo: mockHost.trailingAnchor),
            incoming.topAnchor.constraint(equalTo: mockHost.topAnchor),
            incoming.bottomAnchor.constraint(equalTo: mockHost.bottomAnchor),
        ])

        guard animated, let outgoing else {
            outgoing?.removeFromSuperview()
            reconcileMotion(restartUnderReduceMotion: true)
            return
        }
        incoming.alphaValue = 0
        // The finale's one-shot rides the crossfade itself: its text lands
        // while the pane fades in. Started from the completion handler instead,
        // the pane fades in fully settled and then re-reveals its own text —
        // a double reveal. Timelines keep the after-the-fade start (a loop's
        // first beat is idle anyway).
        if incoming is DemoSettledMockView { reconcileMotion(restartUnderReduceMotion: true) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.stepCrossfadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            outgoing.animator().alphaValue = 0
            incoming.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            outgoing.removeFromSuperview()
            self?.reconcileMotion(restartUnderReduceMotion: true)
        })
    }

    /// The final-check beat: no step is active, but the payoff hasn't been
    /// earned yet — the current mock rests at its settled frame instead of
    /// swapping to the finale. The finale (and its one-shot) arrives only via
    /// a later `show(step:nil, mode:.settled)`, on the check's pass.
    func holdCurrentFrame() {
        (mock as? DemoMockView)?.stopTimeline()
        replayButton.isHidden = true
    }

    /// The WAITING beat: a real system dialog is on screen now, so the
    /// rehearsal of it steps back rather than competing with it.
    func setStageDimmed(_ dimmed: Bool, animated: Bool) {
        let target = dimmed ? Self.stageDimmedAlpha : 1
        guard animated else { mockHost.alphaValue = target; return }
        guard mockHost.alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.stageDimDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            mockHost.animator().alphaValue = target
        }
    }

    /// Take a whole drawn mock out of the accessibility tree, view by view. The
    /// container-level opt-out hoists rather than prunes, and these subtrees
    /// carry real `NSTextField`s and images that are elements by default.
    private static func installAccessibilityOptOut(_ view: NSView) {
        view.setAccessibilityElement(false)
        view.setAccessibilityChildren([])
        view.subviews.forEach(installAccessibilityOptOut)
    }

    private static func makeMock(step: SetupStep?, mode: DemoMode,
                                 restingSwitchOn: Bool = false) -> NSView {
        guard let step, mode != .settled else { return DemoSettledMockView() }
        switch mode {
        // Remote Control's FIRST ask isn't the privacy card at all: it raises
        // the Accessibility ALERT, and that alert's own button is what opens the
        // pane — two surfaces, two clicks, so its first ask plays both. Every
        // other step's first ask really is the one-surface privacy dialog.
        case .prompt:
            switch step {
            case .remoteControl: return DemoSettingsHandoffMockView(step: step)
            // The one ask whose surface is OURS, so the rehearsal is the real
            // view rather than a drawing of one.
            case .usageStats:    return DemoConsentCardMockView()
            // No dialog to rehearse: this ask raises a page on the user's
            // PHONE, so the stage is the code that gets them there.
            case .audioutRemote: return DemoRemoteInviteMockView()
            default:             return DemoPromptMockView(step: step)
            }
        // Every retry lands on the pane itself — Remote Control's included, now
        // that its second click deep-links there, and Speaker Sync's, whose
        // "Open Login Items…" opens System Settings directly. Standing alone
        // (rather than as the handoff's nested stage two) it plays at 1.35×,
        // which is what fills the bigger stage a landscape pane leaves half
        // empty at life scale.
        case .settings:
            return DemoSettingsMockView(step: step, switchRestsOn: restingSwitchOn,
                                        metricScale: 1.35)
        case .settled:  return DemoSettledMockView()
        }
    }

    // MARK: Motion policy

    /// Whether Reduce Motion is on — through the override seam every animated
    /// instrument in this codebase uses, so a headless test can drive both sides.
    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Whether this pane may animate at all: a real window, actually on screen,
    /// and not a headless run (`cacheDisplay` snapshots must be settled). The
    /// override is the seam a headless test drives the motion POLICY through —
    /// nothing here ever animates for real under `swift test`.
    private var canAnimate: Bool {
        if let test_canAnimateOverride { return test_canAnimateOverride }
        guard !HeadlessRuntime.isActive else { return false }
        guard let window = window, window.isVisible else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Apply the motion policy to whatever is currently showing.
    ///
    /// - Parameter restartUnderReduceMotion: true only when the STEP just
    ///   changed — that is the one moment a Reduce Motion user gets their single
    ///   play-through. An occlusion or preference change must not re-trigger it.
    private func reconcileMotion(restartUnderReduceMotion: Bool) {
        if let settled = mock as? DemoSettledMockView {
            replayButton.isHidden = true
            // The finale is a one-shot, not a loop, so it takes its own branch
            // of the policy: play the first time the settled frame is really
            // visible (the grant transition, or the first presentation of a
            // window opened already complete); Reduce Motion spends the shot
            // without motion; off-window and headless leave it UNSPENT so the
            // presentation that can show it still gets it.
            guard canAnimate else { return }
            if reduceMotion { settled.skipCelebration() } else { settled.playCelebration() }
            return
        }
        guard let timeline = mock as? DemoMockView else {
            replayButton.isHidden = true
            return
        }
        // A BROWSE is a read-only look at a step already decided — it rests at
        // its settled frame and offers no Replay. Only the ACTIVE step's
        // rehearsal ever loops, so browsing three granted rows in a row can
        // never put three timelines' worth of motion on screen.
        guard !isBrowse else {
            timeline.stopTimeline()
            replayButton.isHidden = true
            return
        }
        guard canAnimate else {
            timeline.stopTimeline()
            replayButton.isHidden = true
            return
        }
        if reduceMotion {
            replayButton.isHidden = false
            if restartUnderReduceMotion { timeline.startTimeline(loop: false) }
        } else {
            replayButton.isHidden = true
            timeline.startTimeline(loop: true)
        }
    }

    @objc private func replayTapped() {
        (mock as? DemoMockView)?.startTimeline(loop: false)
    }

    // MARK: Test-support hooks

    var test_mode: DemoMode { mode }
    var test_step: SetupStep? { step }
    /// Which surface a two-stage mock RESTS on; `nil` for the mocks that only
    /// ever have one. What it pins is the settled frame — a two-stage pass must
    /// rest on the FIRST thing the user will meet, not on the pane it ends at.
    var test_stage: DemoStage? { (mock as? DemoSettingsHandoffMockView)?.test_stage }
    var test_isAnimating: Bool { (mock as? DemoMockView)?.isTimelineRunning ?? false }
    /// Whether the stage is standing back for a real dialog (the waiting beat).
    var test_isStageDimmed: Bool { mockHost.alphaValue < 1 }
    /// Whether the mock on stage rests with its switch already on (a browse of
    /// a granted step).
    var test_restingSwitchOn: Bool { (mock as? DemoSettingsMockView)?.test_switchRestsOn ?? false }
    /// The invitation on stage, when the iPhone card is the one showing —
    /// `nil` for every other rehearsal.
    var test_remoteInvite: RemoteInviteView? {
        (mock as? DemoRemoteInviteMockView)?.test_invite
    }
    /// Whether what's on stage is a read-only browse.
    var test_isBrowse: Bool { isBrowse }
    var test_isLooping: Bool { (mock as? DemoMockView)?.isLooping ?? false }
    var test_showsReplay: Bool { !replayButton.isHidden }
    /// `nil` = the live system setting (the shared override seam).
    var test_reduceMotionOverride: Bool?
    /// `nil` = the live window/headless check. Setting it re-runs the motion
    /// policy, standing in for the occlusion notification a real visibility
    /// change delivers — the only way a headless test can reach the "window
    /// became visible on an already-settled finale" moment.
    var test_canAnimateOverride: Bool? {
        didSet { reconcileMotion(restartUnderReduceMotion: false) }
    }
    /// How many times the finale's one-shot actually ran (the once-only rule).
    var test_celebrationRunCount: Int { (mock as? DemoSettledMockView)?.celebrationRunCount ?? 0 }
    /// Whether the finale's one-shot is spent — played, or skipped under
    /// Reduce Motion.
    var test_celebrationConsumed: Bool { (mock as? DemoSettledMockView)?.celebrationConsumed ?? false }
    func test_tapReplay() { replayTapped() }
    /// Anything in the mock subtree VoiceOver would still reach — described so a
    /// failure names the offender.
    ///
    /// Two signals, because one alone is not enough: a view that is its own
    /// accessibility ELEMENT is reachable directly, and a view that still
    /// publishes accessibility CHILDREN is reachable through the hoist an ignored
    /// container performs. Both have to be empty for the subtree to be gone.
    var test_accessibleDemoDescendants: [String] {
        ([mockHost] + mockHost.subviewsRecursively)
            .filter { $0.isAccessibilityElement() || $0.accessibilityChildren()?.isEmpty == false }
            .map { ($0 as? NSTextField)?.stringValue ?? String(describing: type(of: $0)) }
    }

    /// Replay is a real control and must survive the purge beside it. Headless
    /// AppKit reports every view as `element=false` with an unknown role, so what
    /// distinguishes "left alone" from "pruned" is that it still publishes its own
    /// accessibility children and label.
    var test_replayIsAccessible: Bool {
        replayButton.accessibilityChildren()?.isEmpty == false
            && replayButton.accessibilityLabel() == "Replay"
    }
}

// MARK: - Timeline base

/// A mock that plays one restartable timeline.
///
/// The timeline is built as a set of keyframe animations laid out over ONE
/// duration and driven by a single sentinel animation whose completion decides
/// whether to loop, so play / play-once / stop are the same code path with a
/// flag. Every animation ENDS at the mock's settled frame — which is also the
/// model-layer state — so removing the animations (stop, off-window, Reduce
/// Motion, headless) leaves the settled frame rather than a half-played pose.
class DemoMockView: NSView {

    /// One pass of the loop.
    var timelineDuration: TimeInterval { 4.0 }

    /// Set when this mock plays as one STAGE inside a longer host timeline: the
    /// host's whole pass, and where along it this stage's own score begins.
    /// `nil` — the default — means the mock owns the whole pass.
    ///
    /// A stage keeps writing its score in its OWN seconds, so a mock never has
    /// to know whether it is playing alone or as part of a sequence;
    /// ``keyframes(_:_:timing:)`` is the one place that maps one onto the other.
    var stageWindow: (hostDuration: TimeInterval, start: TimeInterval)?

    private(set) var isLooping = false
    private(set) var isTimelineRunning = false
    private static let sentinelKey = "demoTimeline"

    /// Subclass hook: add every animation for one pass.
    func addTimelineAnimations() {}

    /// Subclass hook: put every layer at the pass's FINAL (settled) values.
    func applySettledState() {}

    func startTimeline(loop: Bool) {
        stopTimeline()
        layoutSubtreeIfNeeded()   // the animations measure resolved frames
        isLooping = loop
        isTimelineRunning = true
        addTimelineAnimations()

        // The sentinel animates nothing; it exists to tell us the pass ended.
        let sentinel = CABasicAnimation(keyPath: "opacity")
        sentinel.fromValue = 1
        sentinel.toValue = 1
        sentinel.duration = timelineDuration
        sentinel.delegate = self
        layer?.add(sentinel, forKey: Self.sentinelKey)
    }

    func stopTimeline() {
        isTimelineRunning = false
        Self.removeAnimations(from: self)
        applySettledState()
    }

    /// Walks the VIEW tree as well as each view's layer tree: headless (no
    /// window), a subview's backing layer is not yet a sublayer of its
    /// superview's, so a layer-only walk misses the animations on the drawn
    /// cursor — invisible in the settled model state, but still attached.
    private static func removeAnimations(from view: NSView) {
        removeAnimations(from: view.layer)
        view.subviews.forEach { removeAnimations(from: $0) }
    }

    private static func removeAnimations(from layer: CALayer?) {
        guard let layer else { return }
        layer.removeAllAnimations()
        layer.sublayers?.forEach { removeAnimations(from: $0) }
    }

    /// Build a keyframe animation whose `values`/`keyTimes` are expressed in
    /// SECONDS along the pass, so a subclass writes a readable score instead of
    /// hand-normalized fractions. `timing` applies to every segment — the cursor's
    /// travel decelerates into its target (`.easeOut`), everything else eases both
    /// ends.
    ///
    /// Under a ``stageWindow`` the same score is laid onto the host's longer
    /// pass at the stage's start offset, and HELD at its first and last values
    /// through the host time on either side — Core Animation wants a linear
    /// score to span the whole animation, and holding is what "this stage isn't
    /// on screen yet" has to look like anyway.
    func keyframes(_ keyPath: String,
                   _ score: [(time: TimeInterval, value: Any)],
                   timing: CAMediaTimingFunctionName = .easeInEaseOut) -> CAKeyframeAnimation {
        let span = stageWindow?.hostDuration ?? timelineDuration
        let start = stageWindow?.start ?? 0
        var values = score.map(\.value)
        var keyTimes = score.map { ($0.time + start) / span }
        if let first = keyTimes.first, first > 0 {
            keyTimes.insert(0, at: 0)
            values.insert(values[0], at: 0)
        }
        if let last = keyTimes.last, last < 1 {
            keyTimes.append(1)
            values.append(values[values.count - 1])
        }

        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.duration = span
        animation.values = values
        animation.keyTimes = keyTimes.map { NSNumber(value: $0) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: timing),
                                          count: max(values.count - 1, 0))
        animation.calculationMode = .linear
        // The settled model value is the pass's last value, so letting the
        // animation be removed on completion lands exactly there.
        animation.fillMode = .backwards
        return animation
    }

    /// Hold a score's last value out to the end of the pass.
    ///
    /// A score that finishes EARLY is what a multi-stage timeline writes — one
    /// stage's animations are laid out over its own slice and have nothing to
    /// say about the rest. Core Animation would otherwise be handed key times
    /// that stop short of 1.0, so this repeats the final value at the end and
    /// the stage simply rests.
    func held(_ score: [(time: TimeInterval, value: Any)]) -> [(time: TimeInterval, value: Any)] {
        guard let last = score.last, last.time < timelineDuration else { return score }
        return score + [(timelineDuration, last.value)]
    }

    // MARK: Test-support hooks

    /// Every drawn cursor in this mock — nested stages included — with its
    /// click splash at rest. What the settled frame (and every snapshot
    /// fixture) must find: no ring visible, no splash score attached.
    var test_clickSplashesAreSettled: Bool {
        subviewsRecursively.compactMap { $0 as? DemoCursorView }
            .allSatisfy(\.test_splashIsSettled)
    }

    /// Every drawn cursor mid-pass carrying its splash score — what pins that
    /// each press site actually wired the splash in.
    var test_clickSplashesAreArmed: Bool {
        let cursors = subviewsRecursively.compactMap { $0 as? DemoCursorView }
        return !cursors.isEmpty && cursors.allSatisfy(\.test_splashIsArmed)
    }
}

extension DemoMockView: CAAnimationDelegate {
    func animationDidStop(_ anim: CAAnimation, finished: Bool) {
        MainActor.assumeIsolated {
            guard finished, isTimelineRunning else { return }
            guard isLooping else { isTimelineRunning = false; return }
            // Re-arm on the next turn rather than from inside a Core Animation
            // callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isTimelineRunning else { return }
                self.startTimeline(loop: true)
            }
        }
    }
}


// MARK: - The mimic's own palette

/// The greys macOS has no semantic colour for.
///
/// Everything in the mocks that CAN be a semantic system colour is one
/// (`labelColor`, `separatorColor`, `windowBackgroundColor`, `systemBlue`, …).
/// These four can't be: System Settings paints its sidebar DARKER than its
/// content pane, and the obvious semantic pair (`windowBackgroundColor` vs
/// `controlBackgroundColor`) inverts that relationship in dark mode — the one
/// structural cue that says "System Settings" would flip. So they are measured
/// values, wrapped in a dynamic provider so both appearances are real.
///
/// This is the ONE place outside `Tokens` where this codebase holds colour
/// literals, and deliberately so: these are a mimic of ANOTHER app's chrome, not
/// palette values, and putting them in `Tokens` would invite something in the
/// app proper to paint with them. Measured from real Settings recordings —
/// `dev/notes/wispr-permissions-brief.md` names the source.
enum DemoSystemColor {
    /// Sidebar fill — darker than the content pane in BOTH appearances, and
    /// pushed a further step darker under Increase Contrast: the sidebar/
    /// content/card ladder and the button-emphasis pair below are the values
    /// that carry this mock's STRUCTURE (which surface is which, which button
    /// is correct), so they are the ones Increase Contrast separates further —
    /// exactly what the setting is for, and unlike the real macOS chrome this
    /// mock paints (a permission alert, a Settings pane), which visibly widens
    /// its own greys and adds control outlines under the same setting; a mock
    /// that stayed flat under it would be the one surface in this rehearsal
    /// that didn't look like macOS. `DemoButtonEmphasis`'s ghost/marked pair
    /// gets the same treatment for the same reason.
    static let sidebar = dynamic(light: 0xE8E8E8, dark: 0x232326,
                                  lightHighContrast: 0xD2D2D2, darkHighContrast: 0x18181A)
    /// Content-pane fill.
    static let contentPane = dynamic(light: 0xF4F4F4, dark: 0x2C2C2E)
    /// The grouped list's fill. Real Settings draws the card within one level of
    /// the pane and defines it by its border alone; at mock scale that vanishes,
    /// so this is lifted ~2.5 % — a readability adjustment, not a measurement.
    /// Pushed a step lighter under Increase Contrast, widening it from the
    /// sidebar the same way the real pane does.
    static let card = dynamic(light: 0xFAFAFA, dark: 0x333336,
                               lightHighContrast: 0xFFFFFF, darkHighContrast: 0x3D3D40)
    /// A WRONG button — the one the rehearsal is telling the user not to press.
    /// It is drawn as a ghost (see ``DemoPushButtonView``), so this is only its
    /// hairline; the fill is clear. Darkened/lightened under Increase Contrast
    /// so the ghost's rim doesn't fade against the marked button's brighter fill.
    static let ghostButtonRim = dynamic(light: 0xC4C4C4, dark: 0x5A5A5E,
                                         lightHighContrast: 0xA0A0A0, darkHighContrast: 0x7A7A80)
    /// The CORRECT button's fill — the same grey family a step brighter, so the
    /// button the pointer is going to press is the lit one in the row without
    /// borrowing an accent the real dialog doesn't have. Lifted further under
    /// Increase Contrast, same reasoning as the ghost rim above.
    static let markedButton = dynamic(light: 0xE4E2DC, dark: 0x6E6E74,
                                       lightHighContrast: 0xEDEBE4, darkHighContrast: 0x86868C)
    /// The thin ring around that fill, one further step again — also widened
    /// under Increase Contrast.
    static let markedButtonRim = dynamic(light: 0xA8A6A0, dark: 0x8E8E96,
                                          lightHighContrast: 0x88867E, darkHighContrast: 0xACACB4)

    /// The privacy padlock's gradient, top and bottom. Warm GREY, not the real
    /// icon's gold: gold is spent entirely on the one button the step wants
    /// pressed, and a gold padlock inside the rehearsal competed with it (owner
    /// decision 2026-08-12). The gradient itself stays — the real icon is
    /// artwork with some dimension in it, and a flat symbol at this size reads
    /// as a toolbar glyph.
    static let lockTop = solid(0xD8D6D0)
    static let lockBottom = solid(0x9C9A94)

    static let trafficRed = solid(0xFF5F57)
    static let trafficYellow = solid(0xFEBC2E)
    static let trafficGreen = solid(0x28C840)

    /// The privacy/system-dialog accent — TRUE `NSColor.systemBlue`, not
    /// `controlAccentColor` (which follows the user's Appearance setting, so on
    /// a Mac set to pink this "system" surface would come out pink; `systemBlue`
    /// is fixed regardless of the user's accent). Owner decision 2026-08-13,
    /// reversing an 2026-08-12 desaturation: the icon symbols, colours, shape and
    /// CTA words of a real macOS surface are the four things this rehearsal must
    /// get right, so the privacy hand badge and the Local Network / Bluetooth /
    /// Accessibility system tiles read at the same saturation macOS actually
    /// draws them at. Everything else in the mock (title, body, gist copy) stays
    /// abstract — the desaturation was masking the wrong thing.
    static let systemBlue = NSColor.systemBlue

    /// The Settings mock's switch track and the sidebar's selected-row pill —
    /// kept at the DESATURATED slate from the 2026-08-12 pass. The owner named
    /// the Settings mock the reference for "just right" when reversing the
    /// privacy-dialog desaturation (2026-08-13), so this surface is explicitly
    /// OUT of scope for that reversal and keeps its muted value.
    static let settingsAccent = dynamic(light: 0x8A97A6, dark: 0x6C7684)

    /// The recording mark's tile — TRUE `NSColor.systemRed`. Owner decision
    /// 2026-08-13, reversing the 2026-08-12 desaturation: macOS leads the
    /// system-audio ask with a vivid red record mark, not a dusty rose.
    static let recordTile = NSColor.systemRed

    /// `lightHighContrast`/`darkHighContrast` default to `nil` (no change under
    /// Increase Contrast) because most of these values are already the OS's own
    /// semantic-adjacent greys, not the structural ladder Increase Contrast
    /// exists to separate. Increase Contrast is a WORKSPACE setting, not an
    /// appearance, so it can't be read from `appearance` the way light/dark can
    /// — `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` is read
    /// directly instead (the same seam `Tokens.swift`'s `warmDynamic` uses), and
    /// the caller must force a repaint on
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` for a
    /// mid-session toggle to actually show — see `accessibilityDisplayOptionsChanged`.
    private static func dynamic(light: Int, dark: Int,
                                 lightHighContrast: Int? = nil, darkHighContrast: Int? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            solid(resolvedHex(light: light, dark: dark,
                              lightHighContrast: lightHighContrast,
                              darkHighContrast: darkHighContrast,
                              isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                              increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast))
        }
    }

    /// Which of the four values wins, as a PURE function of the two axes.
    ///
    /// Split out of the resolver above so the choice is testable without the
    /// ambient settings it normally reads: Increase Contrast is a workspace
    /// setting with no override seam, and faking it through a mutable static
    /// would leak across this suite's parallel tests. Passing both axes in
    /// leaves nothing global to leak.
    ///
    /// A token with no high-contrast variant falls back to its normal value, so
    /// only the cases that carry structure need to declare one.
    static func resolvedHex(light: Int, dark: Int,
                            lightHighContrast: Int?, darkHighContrast: Int?,
                            isDark: Bool, increaseContrast: Bool) -> Int {
        if isDark { return increaseContrast ? (darkHighContrast ?? dark) : dark }
        return increaseContrast ? (lightHighContrast ?? light) : light
    }

    private static func solid(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

/// The loop's beats, in seconds along one pass — the shape both recordings share
/// (the longest beat is on the RESULT, not on the motion; the motion only
/// explains what changed).
enum DemoBeat {
    static let idle: TimeInterval = 0.80
    static let travelEnd: TimeInterval = 1.80
    static let pressEnd: TimeInterval = 1.90
    // The gap between press and the granted crossfade is a deliberate DWELL,
    // not the fastest possible flip — too tight and the click doesn't read
    // before the reward. Everything after it shifts by the same amount so the
    // hold (1.40s) and reset (0.30s) keep their own length.
    static let changeEnd: TimeInterval = 2.95
    static let holdEnd: TimeInterval = 4.35
    static let resetEnd: TimeInterval = 4.65
    static let loop: TimeInterval = 5.37
}

/// The two-stage retry's beats, in seconds along ONE pass of
/// ``DemoSettingsHandoffMockView``. Stage one is only as long as it takes to
/// press a button — nothing is granted on the alert, so there is no result to
/// hold on; stage two then plays its whole ordinary pass inside this longer one.
enum DemoHandoffBeat {
    /// The press has landed and the two surfaces start to cross.
    static let handoff: TimeInterval = DemoBeat.pressEnd + 0.22
    static let crossfade: TimeInterval = 0.28
    /// Where stage two's own 0-based score is laid down.
    static let settingsStart: TimeInterval = handoff + crossfade
    static let settingsEnd: TimeInterval = settingsStart + DemoBeat.loop
    /// Back to stage one, so the pass ends where it started.
    static let loop: TimeInterval = settingsEnd + crossfade
}

// MARK: - Shared text parts

/// A block of GIST bars where a paragraph of dialog copy would be — a ragged
/// stack of rounded bars, last line short, like the Settings mock's greeked
/// labels.
///
/// **A mock's prose is abstracted, never verbatim** (owner decision 2026-08-12;
/// this folder's AGENTS.md carries the full rationale, including the verbatim
/// Info.plist purpose strings this REPLACES). What makes the surface
/// recognisable is its anatomy — the icon, a title band, two buttons with their
/// real labels — and two dense paragraphs of small type inside the rehearsal
/// only sent the eye reading the words instead of the shape. The sentences are
/// "close enough" as bars, exactly as the Settings mock's rows already were.
///
/// `widths` is the ragged run, longest first is NOT required — write the shape
/// you want. Everything is leading-aligned, because the real copy is.
func demoGistBlock(widths: [CGFloat], height: CGFloat, spacing: CGFloat,
                   fill: NSColor = .tertiaryLabelColor) -> NSStackView {
    let stack = NSStackView(views: widths.map {
        DemoGreekBarView(width: $0, height: height, fill: fill)
    })
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

/// A tinted SF Symbol sized in points — a badge's glyph, a Help button's
/// question mark. Symbols, not text, so the 9 pt legibility floor the labels
/// obey doesn't apply.
func demoGlyph(_ name: String, pointSize: CGFloat,
               weight: NSFont.Weight, color: NSColor) -> NSImageView {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    view.symbolConfiguration = .init(pointSize: pointSize, weight: weight)
    view.contentTintColor = color
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

/// The app's OWN icon, exactly as a THIRD-PARTY process reads it. The real TCC
/// alert and System Settings are drawn by processes other than this one, so
/// they cannot call `NSApp.applicationIconImage` — that only resolves inside
/// the process that owns it. They ask Launch Services for the icon at our
/// bundle's path instead, which is a SEPARATE cache from what this process
/// already knows to be current, and a notoriously sticky one. A mock whose
/// whole job is to preview "the surface you're about to see" has to ask the
/// same way the real surface will, staleness included: showing our own
/// fresher in-process icon here would make the preview WRONG on a Mac where
/// Launch Services hasn't caught up to the latest build yet (verified against
/// live testing, where the real dialog and this mock visibly disagreed).
/// Intentionally exempt from the `BrandMark` swap: a mock of an OS surface has
/// to show what the OS will show, which is this icon.
func demoIconAsAThirdPartyProcessSeesIt() -> NSImage {
    NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
}

// MARK: - Prompt mock

/// A miniature of the macOS 26 privacy dialog for one step — with a drawn cursor
/// gliding to the confirming button, pressing it, and the dialog settling into
/// its granted state.
///
/// **The anatomy is the point.** A dialog the user doesn't recognise is worth
/// nothing, and every part below is one the real one is identified by. A
/// portrait card, everything LEFT-aligned under an icon row:
///
/// 1. an icon tile — the app's own for a content-capture grant, a system tile
///    for a capability grant (see ``iconView(for:)``) — with the
///    `hand.raised.fill` badge overlapping its bottom-trailing corner, the
///    marker that says *privacy prompt*;
/// 2. a small grey Help button in the opposite corner;
/// 3. a heavier two-bar title band;
/// 4. a lighter gist block where the purpose string goes;
/// 5. two EQUAL capsules filling the width, carrying their REAL labels — the
///    confirming one MARKED (brighter fill, thin ring), "Don't Allow" ghosted.
///
/// The copy is abstracted but the colour is TRUE (owner decision 2026-08-13,
/// reversing the 2026-08-12 desaturation) — see
/// ``demoGistBlock(widths:height:spacing:fill:)`` for the copy and
/// ``DemoSystemColor/systemBlue`` for the colour. What the copy abstraction
/// buys is the CARD: with the two paragraphs gone it fits the preview frame's
/// real 278 pt at 240 tall, where
/// the near-life-size drawing was being cropped by ~50 pt at the bottom — the
/// buttons the rehearsal exists to point at were the part going off the edge.
final class DemoPromptMockView: DemoMockView {

    /// PORTRAIT, like the dialog it mimics. macOS's privacy card is taller than
    /// it is wide (roughly 0.8 w∶h — icon, then a title, then a four-line
    /// purpose string stacked above the buttons), and this was drawn wider than
    /// tall, which read as a different KIND of window (owner, 2026-08-13: "too
    /// wide and not tall enough"). The width floor is the button row: two
    /// side-by-side 12 pt labels, and "Don't Allow" is the long one — go much
    /// under 228 and the CTA words, which must stay true, start truncating.
    /// The height ceiling is ``DemoPaneView/surfaceSize`` (278) less a margin.
    static let size = NSSize(width: 228, height: 264)
    /// Content inset on all four sides.
    private static let inset: CGFloat = 17
    private static let iconSide: CGFloat = 60
    private static let badgeSide: CGFloat = 20
    private static let helpSide: CGFloat = 18
    private static var contentWidth: CGFloat { size.width - inset * 2 }

    private let step: SetupStep
    /// Everything the dialog ASKS with, in one layer — so the swap to the
    /// granted state stays a single opacity crossfade.
    private let ask = NSView()
    private let grantedStack = NSStackView()
    private let cursor = DemoCursorView(pointerHeight: 22)
    private var confirmButton: DemoPushButtonView!

    init(step: SetupStep) {
        self.step = step
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var timelineDuration: TimeInterval { DemoBeat.loop }

    private func build() {
        let icon = Self.iconView(for: step)

        // The privacy marker: a blue hand badge overlapping the icon's
        // bottom-trailing corner. It is what distinguishes this dialog from any
        // other alert at a glance, so it is drawn before anything else is.
        let badge = DemoDotView(diameter: Self.badgeSide, fill: DemoSystemColor.systemBlue)
        let badgeGlyph = demoGlyph("hand.raised.fill", pointSize: 9,
                                   weight: .semibold, color: .white)

        let help = DemoDotView(diameter: Self.helpSide, fill: .quaternaryLabelColor)
        let helpGlyph = demoGlyph("questionmark", pointSize: 9,
                                  weight: .semibold, color: .secondaryLabelColor)

        // Where the real dialog's title and purpose string were. Two tiers, so
        // the band still reads as a bold heading over lighter body: the title's
        // bars are taller, darker and nearly full width; the body's are thinner
        // and ragged.
        let title = demoGistBlock(widths: [Self.contentWidth, Self.contentWidth * 0.58],
                                  height: 6, spacing: 8, fill: .secondaryLabelColor)
        let body = demoGistBlock(widths: [Self.contentWidth, Self.contentWidth,
                                          Self.contentWidth, Self.contentWidth * 0.46],
                                 height: 4, spacing: 7)

        // Two EQUAL capsules filling the content width: the refusal on the left,
        // ghosted, and the confirming one on the right, MARKED — the whole
        // reason the rehearsal is on screen is to say which of the two to press.
        let deny = DemoPushButtonView(title: "Don't Allow")
        confirmButton = DemoPushButtonView(title: Self.confirmTitle(for: step),
                                           emphasis: .correct)
        let buttons = NSStackView(views: [deny, confirmButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false

        ask.wantsLayer = true
        ask.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, badge, badgeGlyph, help, helpGlyph, title, body, buttons] {
            ask.addSubview(view)
        }

        // The granted state — what the pass crossfades to once the pointer has
        // pressed the confirming button.
        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 28, weight: .semibold)
        check.contentTintColor = .systemGreen
        check.translatesAutoresizingMaskIntoConstraints = false

        // The checkmark already says "granted"; the line under it is a gist bar
        // like every other line inside a mock.
        let capability = DemoGreekBarView(width: 116, height: 5, fill: .secondaryLabelColor)

        grantedStack.orientation = .vertical
        grantedStack.alignment = .centerX
        grantedStack.spacing = 10
        grantedStack.translatesAutoresizingMaskIntoConstraints = false
        grantedStack.addArrangedSubview(check)
        grantedStack.addArrangedSubview(capability)

        // The real card's corner is ~24 pt at life size — big, and one of the
        // things that dates a Liquid Glass dialog.
        let dialog = DemoWindowSurfaceView(radius: 20)
        dialog.addSubview(ask)
        dialog.addSubview(grantedStack)
        addSubview(dialog)
        addSubview(cursor)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),

            dialog.leadingAnchor.constraint(equalTo: leadingAnchor),
            dialog.trailingAnchor.constraint(equalTo: trailingAnchor),
            dialog.topAnchor.constraint(equalTo: topAnchor),
            dialog.bottomAnchor.constraint(equalTo: bottomAnchor),

            ask.leadingAnchor.constraint(equalTo: dialog.leadingAnchor),
            ask.trailingAnchor.constraint(equalTo: dialog.trailingAnchor),
            ask.topAnchor.constraint(equalTo: dialog.topAnchor),
            ask.bottomAnchor.constraint(equalTo: dialog.bottomAnchor),

            icon.leadingAnchor.constraint(equalTo: ask.leadingAnchor, constant: Self.inset),
            icon.topAnchor.constraint(equalTo: ask.topAnchor, constant: Self.inset),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSide),

            // Overlapping, not tucked inside: the badge hangs off the icon's
            // bottom-trailing corner, the way macOS draws it.
            badge.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -5),
            badge.centerYAnchor.constraint(equalTo: icon.bottomAnchor, constant: -5),
            badgeGlyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeGlyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            help.trailingAnchor.constraint(equalTo: ask.trailingAnchor, constant: -Self.inset),
            help.topAnchor.constraint(equalTo: ask.topAnchor, constant: Self.inset),
            helpGlyph.centerXAnchor.constraint(equalTo: help.centerXAnchor),
            helpGlyph.centerYAnchor.constraint(equalTo: help.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: ask.leadingAnchor, constant: Self.inset),
            title.trailingAnchor.constraint(equalTo: ask.trailingAnchor, constant: -Self.inset),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),

            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            // The copy is allowed to take the slack, never to run into the
            // buttons — a step with a longer purpose string just sits lower.
            body.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -14),

            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: ask.bottomAnchor, constant: -Self.inset),

            grantedStack.centerXAnchor.constraint(equalTo: dialog.centerXAnchor),
            grantedStack.centerYAnchor.constraint(equalTo: dialog.centerYAnchor),
            grantedStack.leadingAnchor.constraint(greaterThanOrEqualTo: dialog.leadingAnchor,
                                                 constant: Self.inset),

            // The cursor's resting position — parked in the band between the
            // copy and the buttons, never on top of text, and anchored to the
            // BUTTON row so a longer body can't push the text under it. The
            // timeline moves it by TRANSFORM (AutoLayout owns its frame and
            // would reset an animated position); the arrow's TIP is the anchor,
            // so the view's top-left is the hot spot.
            cursor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cursor.bottomAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 6),
        ])
        applySettledState()
    }

    /// The tile in the dialog's top-left corner. macOS does NOT put the asking
    /// app's icon there: every grant that reaches this dialog leads with a
    /// SYSTEM tile — the same one for every app, in the colour of the thing
    /// being asked for. Verified from the real dialogs (owner screenshots and a
    /// live run, 2026-08-11): Local Network draws the Network pane's blue globe
    /// and System Audio draws macOS's RED RECORD glyph — NOT Audiout's icon,
    /// which is what this table used to return for it. The badge, the size and
    /// the slot are identical either way; only the tile's contents change.
    /// `.remoteControl`, `.speakerSync` and `.usageStats` never reach this mock
    /// (the first raises the Accessibility alert, the second has no dialog at
    /// all, and the third draws its own real card — `DemoConsentCardMockView`)
    /// and keep the app icon as the safe default for a branch nothing takes.
    private static func iconView(for step: SetupStep) -> NSView {
        switch step {
        // The live-confirmed red record tile: macOS leads its system-audio ask
        // with the recording mark, not with the asking app.
        case .audio:
            return systemTile(fill: DemoSystemColor.recordTile) {
                demoGlyph("record.circle", pointSize: iconSide * 0.55,
                          weight: .regular, color: .white)
            }
        case .localNetwork:
            return systemTile { demoGlyph("network", pointSize: iconSide * 0.55,
                                          weight: .regular, color: .white) }
        // Verified against the real Bluetooth dialog (owner screenshot,
        // 2026-08-11): the tile IS the same blue system tile Local Network
        // uses, carrying the actual Bluetooth rune. SF Symbols carries no
        // such glyph, but AppKit itself does — `bluetoothRuneImage` wraps the
        // stock `NSImage.bluetoothTemplateName`.
        case .bluetooth:
            return systemTile {
                let rune = NSImageView()
                rune.image = bluetoothRuneImage(height: iconSide * 0.55)
                rune.contentTintColor = .white
                rune.translatesAutoresizingMaskIntoConstraints = false
                return rune
            }
        // Neither step reaches this mock. When the app icon IS drawn it is the
        // DIALOG'S icon — the one a separate system process reads out of Launch
        // Services, not this process's own fresher `NSApp.applicationIconImage`
        // (see `demoIconAsAThirdPartyProcessSeesIt`).
        case .remoteControl, .speakerSync, .usageStats, .audioutRemote:
            let icon = NSImageView()
            icon.image = demoIconAsAThirdPartyProcessSeesIt()
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            return icon
        }
    }

    /// A macOS system-pane tile: a rounded square carrying one white glyph,
    /// drawn at the app icon's size so the badge lands where it always does.
    /// Corner and glyph are fractions of the side rather than points, so
    /// changing `iconSide` alone keeps the tile in proportion; both are matched
    /// by eye to the Local Network screenshot, not measured. `fill` is the
    /// pane's own colour — blue for the capability panes, red for recording.
    /// `glyph` is a builder rather than a plain view so a caller can hand it a
    /// plain SF Symbol OR a hand-drawn one (Bluetooth's rune has no symbol to
    /// name).
    private static func systemTile(fill: NSColor = DemoSystemColor.systemBlue,
                                   glyph: () -> NSView) -> NSView {
        let tile = DemoPillView(radius: iconSide * 0.23, fill: fill)
        let mark = glyph()
        tile.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    /// The settled frame is the dialog AS THE USER WILL FIND IT — the ask, with
    /// the cursor waiting. Deliberately NOT the granted end state: the pane
    /// always shows the ACTIVE step's mock, so resting on "allowed" would sit
    /// beside a card that is still asking for that very permission and claim it
    /// was already given. Every pass therefore returns here, which also makes
    /// the loop seamless.
    override func applySettledState() {
        ask.alphaValue = 1
        grantedStack.alphaValue = 0
        cursor.alphaValue = 1
        cursor.layer?.transform = CATransform3DIdentity
        confirmButton.alphaValue = 1
    }

    override func addTimelineAnimations() {
        let end = timelineDuration
        let delta = cursorTravel()
        let moved = NSValue(caTransform3D: CATransform3DMakeTranslation(delta.x, delta.y, 0))
        let still = NSValue(caTransform3D: CATransform3DIdentity)

        // Press: the real button darkens about 4 % for ~100 ms.
        confirmButton.layer?.add(keyframes("opacity", [
            (0, 1), (DemoBeat.travelEnd, 1), (DemoBeat.pressEnd, 0.85),
            (DemoBeat.pressEnd + 0.08, 1), (end, 1),
        ]), forKey: "press")
        cursor.addClickSplash(on: self, at: DemoBeat.pressEnd)

        // The travel decelerates into the target — 80 % of the distance early,
        // then it eases in over the last third.
        cursor.layer?.add(keyframes("transform", [
            (0, still), (DemoBeat.idle, still), (DemoBeat.travelEnd, moved),
            (DemoBeat.resetEnd, moved), (end, still),
        ], timing: .easeOut), forKey: "cursorGlide")
        cursor.layer?.add(keyframes("opacity", [
            (0, 1), (DemoBeat.changeEnd - 0.1, 1), (DemoBeat.changeEnd, 0),
            (DemoBeat.resetEnd, 0), (end, 1),
        ]), forKey: "cursorFade")

        ask.layer?.add(keyframes("opacity", [
            (0, 1), (DemoBeat.pressEnd, 1), (DemoBeat.changeEnd, 0),
            (DemoBeat.holdEnd, 0), (DemoBeat.resetEnd, 1), (end, 1),
        ]), forKey: "askFade")
        grantedStack.layer?.add(keyframes("opacity", [
            (0, 0), (DemoBeat.pressEnd, 0), (DemoBeat.changeEnd, 1),
            (DemoBeat.holdEnd, 1), (DemoBeat.resetEnd, 0), (end, 0),
        ]), forKey: "grantedFade")
    }

    /// How far the cursor has to travel, in this view's own coordinates, from
    /// where AutoLayout parked its TIP to the confirming button's centre.
    private func cursorTravel() -> CGPoint {
        let from = cursor.convert(cursor.tipPoint, to: self)
        let to = confirmButton.convert(NSPoint(x: confirmButton.bounds.midX,
                                               y: confirmButton.bounds.midY), to: self)
        return CGPoint(x: to.x - from.x, y: to.y - from.y)
    }

    // MARK: Copy

    /// The button the cursor presses. Every step that reaches this mock uses
    /// the same TCC-family dialog shape, and Apple's own confirming button
    /// across that family is "Allow" (verified against the real audio and
    /// Local Network dialogs) — never "OK", which was an unverified guess
    /// from before any real dialog had been checked.
    static func confirmTitle(for step: SetupStep) -> String { "Allow" }
}

// MARK: - System alert mock

/// A miniature of the macOS ALERT PANEL that hands a grant over to System
/// Settings — a completely different animal from the portrait privacy card
/// ``DemoPromptMockView`` draws, and the first surface of Remote Control's
/// two-stage pass, its one client.
///
/// Drawn from the real "Accessibility Access" alert. Every part below is one
/// the real panel is identified by, and the contrast with the privacy card is
/// the point — a user who has seen this
/// miniature will not mistake the panel for the dialog they were shown earlier:
///
/// 1. LANDSCAPE, with a small ~12 pt corner, not the card's tall portrait and
///    its ~24 pt one;
/// 2. a short header BAND naming the access being asked for;
/// 3. a full-bleed hairline DIVIDER under it — the one structural element the
///    privacy card has nothing like, and the fastest way to tell them apart;
/// 4. a two-column body, the privacy PADLOCK left and a gist block right, the
///    two centred against each other as a group;
/// 5. a Help circle bottom-LEFT, and two buttons bottom-RIGHT.
///
/// **The marking is the deliberate departure from the real panel.** On the real
/// alert the REFUSAL is the accent-filled default, and drawing that faithfully
/// put the emphasis on the one button the user must not press — the deleted
/// warning line was what carried the correction, and with that line gone the
/// mock has to carry it itself. So "Open System Settings" is the MARKED button
/// here and "Deny" is a ghost: the shape still tells the two surfaces apart,
/// and the emphasis now tells the truth about which one moves the user forward.
///
/// It is a passive SURFACE, not a timeline: it draws itself and exposes the
/// button a pointer should press, while the host two-stage mock owns the one
/// cursor and the crossfade — a stage that owned a cursor would put a second
/// pointer on screen.
final class DemoSystemAlertMockView: NSView {

    /// Fixed width; the HEIGHT comes from the content, so the gist block sets it
    /// rather than a magic number. 288 leaves shadow room
    /// inside both hosts — the Login Items pane it stands in front of is 300.
    static let width: CGFloat = 288
    private static let inset: CGFloat = 12
    private static let iconSide: CGFloat = 38
    private static let badgeSide: CGFloat = 16
    private static let helpSide: CGFloat = 16
    private static let buttonHeight: CGFloat = 24
    /// The real panel's buttons are ordinary rounded rects, nowhere near the
    /// privacy dialog's full capsule.
    private static let buttonRadius: CGFloat = 6
    /// What is left for the text column once the icon and the insets have had
    /// their share.
    private static var textWidth: CGFloat { width - inset * 2 - iconSide - 11 }

    /// Where a host parks its pointer while this alert is the settled frame:
    /// inside the panel's bottom-left, in the button row's band but clear of
    /// both buttons and of the Help circle. Resting it ON "Open System Settings"
    /// reads as a press that already happened. In the HOST's coordinates — the
    /// host centres this alert in its 300 × 190 frame.
    static let pointerRest = CGPoint(x: 66, y: 150)

    private let step: SetupStep
    /// The button the demo's pointer presses, and the MARKED one — the real
    /// alert makes "Deny" its default, so the button that actually moves the
    /// user forward is the one the panel de-emphasises, and the mock has to say
    /// so the other way round.
    private(set) var pressTarget: DemoPushButtonView!

    init(step: SetupStep) {
        self.step = step
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        // Smaller corner than the privacy card's 20: this is the old alert
        // shape, and a big continuous corner is exactly what would blur the two.
        let panel = DemoWindowSurfaceView(radius: 12)

        let header = DemoGreekBarView(width: 86, height: 5, fill: .secondaryLabelColor)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let icon = DemoLockIconView()
        // The bold ask over the Settings instruction, as two tiers of bars.
        let ask = demoGistBlock(widths: [Self.textWidth, Self.textWidth * 0.66],
                                height: 5, spacing: 7, fill: .secondaryLabelColor)
        let body = demoGistBlock(widths: [Self.textWidth, Self.textWidth * 0.52],
                                 height: 3.5, spacing: 6)
        let text = NSStackView(views: [ask, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        text.translatesAutoresizingMaskIntoConstraints = false

        let help = DemoDotView(diameter: Self.helpSide, fill: .quaternaryLabelColor)
        let helpGlyph = demoGlyph("questionmark", pointSize: 9,
                                  weight: .semibold, color: .secondaryLabelColor)

        pressTarget = DemoPushButtonView(title: "Open System Settings",
                                         emphasis: .correct,
                                         height: Self.buttonHeight,
                                         cornerRadius: Self.buttonRadius)
        let deny = DemoPushButtonView(title: "Deny",
                                      height: Self.buttonHeight,
                                      cornerRadius: Self.buttonRadius)
        let buttons = NSStackView(views: [pressTarget, deny])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(header)
        panel.addSubview(divider)
        panel.addSubview(icon)
        panel.addSubview(text)
        panel.addSubview(help)
        panel.addSubview(helpGlyph)
        panel.addSubview(buttons)
        addSubview(panel)

        if let badge = Self.badge(for: step) {
            panel.addSubview(badge.circle)
            panel.addSubview(badge.glyph)
            NSLayoutConstraint.activate([
                badge.circle.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -3),
                badge.circle.centerYAnchor.constraint(equalTo: icon.bottomAnchor, constant: -3),
                badge.glyph.centerXAnchor.constraint(equalTo: badge.circle.centerXAnchor),
                badge.glyph.centerYAnchor.constraint(equalTo: badge.circle.centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),

            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),

            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: Self.inset),
            header.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor,
                                             constant: -Self.inset),
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),

            // Full bleed, edge to edge: the real panel's rule runs the whole
            // width of the alert, which is what makes it read as a header band
            // rather than as a gap in the copy.
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),

            icon.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: Self.inset),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            // Icon and text are centred against each OTHER, and the taller of
            // the two is what sets the body band's height.
            icon.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            icon.topAnchor.constraint(greaterThanOrEqualTo: divider.bottomAnchor, constant: 12),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
            text.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -Self.inset),
            text.topAnchor.constraint(greaterThanOrEqualTo: divider.bottomAnchor, constant: 12),

            help.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: Self.inset),
            help.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            helpGlyph.centerXAnchor.constraint(equalTo: help.centerXAnchor),
            helpGlyph.centerYAnchor.constraint(equalTo: help.centerYAnchor),

            buttons.trailingAnchor.constraint(equalTo: panel.trailingAnchor,
                                              constant: -Self.inset),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: help.trailingAnchor,
                                             constant: 8),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: 12),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -Self.inset),
        ])
        setPressed(false)
    }

    // MARK: The host's handles

    /// The settled (unpressed) state, applied without animation.
    func setPressed(_ pressed: Bool) { pressTarget.alphaValue = pressed ? 0.85 : 1 }

    /// The press dip, as a slice of the host's one pass. Only the BUTTON dims —
    /// the panel's own opacity belongs to the host's crossfade, and two
    /// animations on one property fight.
    func addPressAnimation(on host: DemoMockView, pressedAt time: TimeInterval) {
        pressTarget.layer?.add(host.keyframes("opacity", host.held([
            (0, 1), (time - 0.10, 1), (time, 0.85), (time + 0.12, 1),
        ])), forKey: "press")
    }

    /// Where the pointer's tip has to land, in `view`'s coordinates.
    func pressPoint(in view: NSView) -> NSPoint {
        pressTarget.convert(NSPoint(x: pressTarget.bounds.midX, y: pressTarget.bounds.midY),
                            to: view)
    }

    /// The blue circular badge overlapping the padlock, if this step has one.
    ///
    /// Accessibility's is the accessibility figure — the badge is what says
    /// WHICH capability the padlock is standing for. No other step raises this
    /// alert, so no other step earns a marker.
    private static func badge(for step: SetupStep) -> (circle: NSView, glyph: NSView)? {
        guard step == .remoteControl else { return nil }
        return (DemoDotView(diameter: badgeSide, fill: DemoSystemColor.systemBlue),
                demoGlyph("accessibility", pointSize: 9, weight: .semibold, color: .white))
    }
}

// MARK: - Settings mock

/// A miniature of the System Settings pane a retry lands on: the window's
/// traffic lights, the sidebar with its blue selected row, the pane title, and a
/// grouped list whose third row is Audiout — with a drawn cursor switching it
/// on. Speaker Sync uses this mock always: its approval only exists in Login
/// Items, so there is no prompt to mirror.
///
/// **The sidebar sliver is load-bearing, not decoration.** At this width the
/// content alone (a card with three rows) could be any app's settings list; the
/// three things that say "System Settings" are the traffic lights, the sidebar's
/// blue selected pill, and the switch — and two of those live in the sidebar.
///
/// Scale is NOT uniform (a uniform 0.42 would put labels at 5.5 pt). Three tiers:
/// the elements a viewer identifies the UI BY stay near-real (switch, traffic
/// lights, pane title, row labels), the structural rhythm shrinks ~0.65, and
/// anything that would land under 9 pt of text is REPLACED rather than shrunk —
/// greeked bars and flat tinted tiles, because text between 6 and 8.5 pt
/// antialiases into mush that reads as a rendering bug.
final class DemoSettingsMockView: DemoMockView {

    /// The BASE size, at `metricScale` 1. An instance draws at
    /// ``scaledSize``; this static is what the handoff container (which nests
    /// an unscaled stage two) sizes itself from.
    static let size = NSSize(width: 300, height: 190)
    /// The reference puts the sidebar at 80 pt (27 % of 300, deliberately less
    /// than the real 30 % so it isn't mostly empty chrome). 76 here: the longest
    /// real pane title ("Screen & System Audio Recording") needs every point the
    /// content side can spare, and the title is the one string that has to be
    /// legible and complete — it is what says WHICH pane this is.
    private static let sidebarWidth: CGFloat = 76

    private let step: SetupStep
    /// Whether the SETTLED frame rests with the Audiout switch already ON.
    ///
    /// The standing rule is that a pass ends where it started — the surface as
    /// the user will FIND it, which for an ask is the switch off. This is the
    /// one scoped amendment: a read-only BROWSE of an already-granted step is
    /// not an ask, and showing that pane with the switch off would claim the
    /// user still has something to flip. Ask, denied and requested all rest OFF
    /// exactly as before.
    private let switchRestsOn: Bool
    /// Multiplies every point metric this view authors. The standalone pane
    /// plays at 1.35 to fill the rehearsal-led stage; nested as the handoff's
    /// stage two it stays at 1, where it shares a frame with the alert.
    private let metricScale: CGFloat
    private var toggle: DemoSwitchView!
    /// Slightly smaller than the prompt mock's, in step with this mock's own
    /// tighter scale.
    private let cursor = DemoCursorView(pointerHeight: 22)

    /// Where the pointer waits: low in the content pane, clear of the title and
    /// the card's first row — a cursor sitting on top of text read as a mistake.
    private let cursorPark = CGPoint(x: 110, y: 138)

    init(step: SetupStep, switchRestsOn: Bool = false, metricScale: CGFloat = 1) {
        self.step = step
        self.switchRestsOn = switchRestsOn
        self.metricScale = metricScale
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    /// This instance's drawn size.
    var scaledSize: NSSize { NSSize(width: m(Self.size.width), height: m(Self.size.height)) }

    /// A point metric at this instance's scale, on the half-point grid — the
    /// finest division AppKit lays out cleanly on a 2× display.
    private func m(_ points: CGFloat) -> CGFloat { (points * metricScale * 2).rounded() / 2 }

    /// A font size at this instance's scale, rounded DOWN to a whole point: type
    /// sizes are whole numbers, and rounding up is what pushes a pane title into
    /// truncation.
    private func t(_ points: CGFloat) -> CGFloat { (points * metricScale).rounded(.down) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var timelineDuration: TimeInterval { DemoBeat.loop }

    private func build() {
        let shell = DemoWindowSurfaceView(fill: DemoSystemColor.contentPane)
        let sidebar = DemoSidebarView()
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let card = makeCard()

        shell.addSubview(sidebar)
        shell.addSubview(divider)
        shell.addSubview(header)
        shell.addSubview(card)
        addSubview(shell)
        addSubview(cursor)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: scaledSize.width),
            heightAnchor.constraint(equalToConstant: scaledSize.height),

            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            sidebar.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: shell.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: m(Self.sidebarWidth)),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: shell.topAnchor),
            divider.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            // A HAIRLINE, not a metric: separators stay one point at any scale,
            // the way macOS draws them.
            divider.widthAnchor.constraint(equalToConstant: 1),

            header.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: m(12)),
            // Required, not `<=`: the title has to be clipped by the pane's own
            // edge rather than drawn past it.
            header.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -m(12)),
            header.topAnchor.constraint(equalTo: shell.topAnchor, constant: m(14)),

            card.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: m(12)),
            card.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -m(12)),
            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: m(12)),
            card.bottomAnchor.constraint(lessThanOrEqualTo: shell.bottomAnchor, constant: -m(12)),

            cursor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m(cursorPark.x)),
            cursor.topAnchor.constraint(equalTo: topAnchor, constant: m(cursorPark.y)),
        ])
        applySettledState()
    }

    /// The back chevron and the pane title — the one string in this mock that must
    /// be real text, because it says WHICH pane this is.
    ///
    /// The reference also draws a disabled FORWARD chevron. Dropped: it is dead
    /// chrome that adds no recognisability, and the 17 pt it costs is the
    /// difference between the longest pane title fitting and truncating.
    private func makeHeader() -> NSView {
        let back = NSImageView()
        back.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
        back.symbolConfiguration = .init(pointSize: t(9), weight: .semibold)
        back.contentTintColor = .tertiaryLabelColor
        back.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: Self.paneTitle(for: step))
        title.font = .systemFont(ofSize: t(11), weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.allowsDefaultTighteningForTruncation = true

        let row = NSStackView(views: [back, title])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = m(8)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// The grouped list: a caption band, three rows, hairline separators inset to
    /// the labels and full-bleed to the right — the shape that makes it a macOS
    /// grouped list rather than a stack of tiles.
    private func makeCard() -> NSView {
        let card = RoundedContainerView(fill: DemoSystemColor.card,
                                        border: .separatorColor,
                                        radius: 6)
        toggle = DemoSwitchView()

        let caption = DemoGreekBarView(width: m(96))
        card.addSubview(caption)

        let rows: [NSView] = [
            DemoSettingsRowView.placeholder(labelWidth: m(58), isOn: true),
            DemoSettingsRowView.placeholder(labelWidth: m(44), isOn: true),
            DemoSettingsRowView.app(name: "Audiout", switchView: toggle),
        ]
        var previous: NSView?
        for row in rows {
            card.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            ])
            if let previous {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(separator)
                NSLayoutConstraint.activate([
                    separator.topAnchor.constraint(equalTo: previous.bottomAnchor),
                    separator.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                                       constant: DemoSettingsRowView.labelInset),
                    separator.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                    row.topAnchor.constraint(equalTo: previous.bottomAnchor),
                ])
            } else {
                row.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: m(6)).isActive = true
            }
            previous = row
        }

        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: m(10)),
            caption.topAnchor.constraint(equalTo: card.topAnchor, constant: m(8)),
            previous!.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    /// Settled: the pane as the user will FIND it — switch off for an ask (see
    /// ``DemoPromptMockView/applySettledState()`` for why the rest state is
    /// never the finished one), switch ON for the browse of a step that is
    /// already granted, where "as the user will find it" means on.
    override func applySettledState() {
        toggle.setOn(switchRestsOn)
        cursor.alphaValue = 1
        cursor.layer?.transform = CATransform3DIdentity
    }

    override func addTimelineAnimations() {
        let end = timelineDuration
        let delta = switchTravel()
        let moved = NSValue(caTransform3D: CATransform3DMakeTranslation(delta.x, delta.y, 0))
        let still = NSValue(caTransform3D: CATransform3DIdentity)
        cursor.layer?.add(keyframes("transform", [
            (0, still), (DemoBeat.idle, still), (DemoBeat.travelEnd, moved),
            (DemoBeat.resetEnd, moved), (end, still),
        ], timing: .easeOut), forKey: "cursorGlide")
        cursor.layer?.add(keyframes("opacity", [
            (0, 1), (DemoBeat.holdEnd - 0.3, 1), (DemoBeat.holdEnd, 0),
            (DemoBeat.resetEnd, 0), (end, 1),
        ]), forKey: "cursorFade")
        // The flip's press moment: the beat the track starts crossing to blue.
        cursor.addClickSplash(on: self, at: DemoBeat.pressEnd)

        toggle.addTimeline(on: self)
    }

    /// How far the cursor's TIP has to travel to the switch, in this view's own
    /// coordinates.
    private func switchTravel() -> CGPoint {
        let from = cursor.convert(cursor.tipPoint, to: self)
        let to = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: self)
        return CGPoint(x: to.x - from.x, y: to.y - from.y)
    }

    /// The pane each step's retry actually lands on. Speaker Sync's is Login
    /// Items — "Login Items", not the 15+ "Login Items & Extensions", which is too
    /// long to read at 11 pt.
    static func paneTitle(for step: SetupStep) -> String {
        switch step {
        // The pane macOS actually shows is "Screen & System Audio Recording", but
        // the mock uses the SUBSECTION heading our own row lives under (owner
        // decision): we don't ask for the screen, and "Screen" is the very word
        // the card copy exists to defuse. Still a real string from that pane.
        case .audio:         return "System Audio Recording Only"
        case .localNetwork:  return "Local Network"
        case .bluetooth:     return "Bluetooth"
        case .remoteControl: return "Accessibility"
        case .speakerSync:   return "Login Items"
        // Never reached: Usage Statistics has no System Settings pane to land
        // on, so nothing ever asks this mock to draw one for it.
        case .usageStats, .audioutRemote: return "General"
        }
    }

    // MARK: Test-support hooks

    /// Whether this instance's settled frame rests with the switch on.
    var test_switchRestsOn: Bool { switchRestsOn }
}

// MARK: - Two-stage first-ask mock

/// Remote Control's FIRST ask, which is TWO surfaces rather than one.
///
/// Its Allow doesn't raise a privacy dialog the user answers in place: it raises
/// the Accessibility Access ALERT, whose only forward button opens System
/// Settings, where the actual toggle lives. So the user has two clicks to make,
/// on two different surfaces, and a demo that opened straight onto the Settings
/// pane skipped the first one — it showed the toggle without showing how the
/// pane carrying it is reached. (The RETRY does land on the pane directly, and
/// gets the one-stage mock like every other step.)
///
/// One pass, one clock: the system ALERT with the pointer pressing **Open System
/// Settings**, a crossfade, then the ordinary Settings pass with the pointer
/// flipping the Audiout toggle on. Stage two is the mock every other step
/// already uses; this view sequences the two, owns the crossfade and owns the
/// stage-one pointer, laying stage two's own 0-based score onto this longer pass
/// through ``DemoMockView/stageWindow``.
final class DemoSettingsHandoffMockView: DemoMockView {

    /// As wide as the wider stage and as tall as the taller one, so neither
    /// moves when the other takes over. Both are the Settings pane's now that
    /// stage one is a landscape alert rather than the portrait privacy card.
    static let size = DemoSettingsMockView.size

    private let alert: DemoSystemAlertMockView
    private let settings: DemoSettingsMockView
    /// Stage one's pointer. Stage two draws its own inside the Settings mock, and
    /// the two never share a frame — this one is invisible from the crossfade
    /// until the alert comes back.
    private let cursor = DemoCursorView(pointerHeight: 22)

    init(step: SetupStep) {
        alert = DemoSystemAlertMockView(step: step)
        settings = DemoSettingsMockView(step: step)
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var timelineDuration: TimeInterval { DemoHandoffBeat.loop }

    private func build() {
        for stage in [alert as NSView, settings] {
            // A mock is normally installed by the pane, which turns this off for
            // it; nested one stage deep, that is this view's job.
            stage.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stage)
            NSLayoutConstraint.activate([
                stage.centerXAnchor.constraint(equalTo: centerXAnchor),
                stage.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        addSubview(cursor)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),

            cursor.leadingAnchor.constraint(equalTo: leadingAnchor,
                                            constant: DemoSystemAlertMockView.pointerRest.x),
            cursor.topAnchor.constraint(equalTo: topAnchor,
                                        constant: DemoSystemAlertMockView.pointerRest.y),
        ])
        applySettledState()
    }

    /// Settled: stage one, as the user will find it. Both stages settle
    /// themselves too, so a stopped pass leaves neither half-played.
    override func applySettledState() {
        alert.alphaValue = 1
        alert.setPressed(false)
        settings.alphaValue = 0
        settings.applySettledState()
        cursor.alphaValue = 1
        cursor.layer?.transform = CATransform3DIdentity
    }

    override func addTimelineAnimations() {
        let end = timelineDuration
        alert.layer?.add(keyframes("opacity", [
            (0, 1), (DemoHandoffBeat.handoff, 1), (DemoHandoffBeat.settingsStart, 0),
            (DemoHandoffBeat.settingsEnd, 0), (end, 1),
        ]), forKey: "alertStage")
        settings.layer?.add(keyframes("opacity", [
            (0, 0), (DemoHandoffBeat.handoff, 0), (DemoHandoffBeat.settingsStart, 1),
            (DemoHandoffBeat.settingsEnd, 1), (end, 0),
        ]), forKey: "settingsStage")

        // Stage one's pointer: glide to "Open System Settings", press, then walk
        // home while it is INVISIBLE — the pass has to end at the settled frame,
        // and a pointer visibly retracing its steps would read as a second
        // instruction.
        let from = cursor.convert(cursor.tipPoint, to: self)
        let to = alert.pressPoint(in: self)
        let moved = NSValue(caTransform3D:
            CATransform3DMakeTranslation(to.x - from.x, to.y - from.y, 0))
        let still = NSValue(caTransform3D: CATransform3DIdentity)
        cursor.layer?.add(keyframes("transform", [
            (0, still), (DemoBeat.idle, still), (DemoBeat.travelEnd, moved),
            (DemoHandoffBeat.settingsStart, moved),
            (DemoHandoffBeat.settingsStart + 0.4, still), (end, still),
        ], timing: .easeOut), forKey: "cursorGlide")
        cursor.layer?.add(keyframes("opacity", [
            (0, 1), (DemoHandoffBeat.handoff, 1), (DemoHandoffBeat.settingsStart, 0),
            (DemoHandoffBeat.settingsEnd, 0), (end, 1),
        ]), forKey: "cursorFade")
        alert.addPressAnimation(on: self, pressedAt: DemoBeat.pressEnd)
        cursor.addClickSplash(on: self, at: DemoBeat.pressEnd)

        // Stage two is written in its own seconds and mapped onto the window it
        // plays in. Its cursor's own click splash comes along with the rest of
        // its score — this view adds nothing for it.
        settings.stageWindow = (hostDuration: end, start: DemoHandoffBeat.settingsStart)
        settings.addTimelineAnimations()
    }

    // MARK: Test-support hooks

    /// Which surface is up. The settled frame must be ``DemoStage/alert`` — the
    /// first of the two clicks the user still has to make.
    var test_stage: DemoStage {
        settings.alphaValue > alert.alphaValue ? .settingsPane : .alert
    }
}

// MARK: - Usage-statistics consent card

/// Usage Statistics' stage: the REAL ``UsageStatsConsentCard``, inert, with the
/// pointer gliding to Share and pressing it.
///
/// Every other mock in this file is a drawing of a surface macOS owns, which is
/// the best that can be done for something another process renders. This step's
/// surface is Audiout's, so the rehearsal is not a drawing at all — it is the
/// same view the sheet presents, built by the same initialiser, with its two
/// buttons switched off. There is nothing to keep in step and nothing to get
/// subtly wrong (owner: "why can't you make it look exactly like your
/// mock-up").
///
/// The pass ends where it started, like every other ask: the card at rest with
/// nothing pressed, because that is how the user will FIND it.
final class DemoConsentCardMockView: DemoMockView {

    private let card = UsageStatsConsentCard()
    private let cursor = DemoCursorView(pointerHeight: 22)

    /// Where the pointer waits: bottom-left, level with the buttons and clear
    /// of every line of copy. A cursor resting on top of text reads as a
    /// drawing mistake rather than a pointer.
    private let cursorParkLeading: CGFloat = 34
    private let cursorParkAboveBottom: CGFloat = 34

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        card.makeDecorative()
        addSubview(card)
        addSubview(cursor)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalTo: card.widthAnchor),
            heightAnchor.constraint(equalTo: card.heightAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            cursor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: cursorParkLeading),
            cursor.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -cursorParkAboveBottom),
        ])
        applySettledState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The rehearsal takes no clicks. Its buttons are real, undimmed AppKit
    /// controls — that is what makes it accurate — so the refusal has to be
    /// here, or a pointer over the stage would light up a hover state on a
    /// button that answers nobody.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var timelineDuration: TimeInterval { DemoBeat.loop }

    override func applySettledState() {
        cursor.alphaValue = 1
        cursor.layer?.transform = CATransform3DIdentity
    }

    override func addTimelineAnimations() {
        let end = timelineDuration
        let delta = travelToShare()
        let moved = NSValue(caTransform3D: CATransform3DMakeTranslation(delta.x, delta.y, 0))
        let still = NSValue(caTransform3D: CATransform3DIdentity)
        cursor.layer?.add(keyframes("transform", [
            (0, still), (DemoBeat.idle, still), (DemoBeat.travelEnd, moved),
            (DemoBeat.resetEnd, moved), (end, still),
        ], timing: .easeOut), forKey: "cursorGlide")
        cursor.layer?.add(keyframes("opacity", [
            (0, 1), (DemoBeat.holdEnd - 0.3, 1), (DemoBeat.holdEnd, 0),
            (DemoBeat.resetEnd, 0), (end, 1),
        ]), forKey: "cursorFade")
        cursor.addClickSplash(on: self, at: DemoBeat.pressEnd)
    }

    /// How far the pointer's TIP has to travel to the Share button's middle.
    private func travelToShare() -> CGPoint {
        let from = cursor.convert(cursor.tipPoint, to: self)
        let button = card.shareButton
        let to = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
        return CGPoint(x: to.x - from.x, y: to.y - from.y)
    }

    // MARK: Test-support hooks

    /// The card the sheet would show, so a test can prove the two are the same
    /// view rather than two drawings that happen to agree.
    var test_card: UsageStatsConsentCard { card }
}

// MARK: - Settled mock

/// The finale: the app's own icon resting in a soft warm-gold aura under a
/// display-weight "You're all set." — a payoff frame that reads rich on its
/// own, never like a paused animation. None of the mocks' shadow-heavy window
/// chrome: nothing is being asked for any more.
///
/// On the TRANSITION into the complete state it plays a ONE-SHOT celebration:
/// concentric gold signal rings ripple outward from the icon — the Warm Signal
/// made literal — while the aura blooms and the two text lines rise in. One
/// shot, then fully static: an idle Setup window burns no CPU, so there is no
/// loop and no idle motion of any kind. The shot is CONSUMED (played, or spent
/// without motion under Reduce Motion), so a repaint that changes nothing can
/// never re-fire it. The pane decides WHEN (`DemoPaneView.reconcileMotion`):
/// the first time this frame is on a really-visible window — the grant
/// transition normally, or the first presentation of a window opened with
/// everything already granted. Off-window and headless runs render the settled
/// frame and leave the shot unspent.
///
/// Every animation ends at the settled MODEL values and auto-removes, so an
/// interrupted or hidden run still lands on the exact resting frame — the same
/// rule the timeline mocks follow.
///
/// This is Audiout's own moment, not a macOS mimic, so unlike the mocks its
/// colours come from `Tokens`. The aura and rings STAMP resolved gold/glow
/// `CGColor`s onto layers, so the view observes the accent dial and the a11y
/// display notification and re-stamps (SharedUI's layer-colour instrument
/// rule); light/dark re-stamps arrive through `updateLayer`.
final class DemoSettledMockView: NSView {

    /// Fills the demo surface exactly: the ripple needs the whole stage. This
    /// view draws WITHOUT a clip of its own — the wave leaves the stage and
    /// keeps going into the (chromeless) hero pane, which is the whole point
    /// of the moment. Still the pane's fixed geometry — the surface itself
    /// never resizes.
    static let size = DemoPaneView.surfaceSize

    private static let iconSide: CGFloat = 88
    /// Rings start just outside the icon and travel PAST every frame edge —
    /// full-stage energy, derived (never authored) in ``ringEndScale()``. The
    /// ring's own fade to zero, not a mask, is what keeps the exit soft.
    private static let ringBaseDiameter: CGFloat = 104
    /// Seconds into the shot each ring launches — staggered, like a broadcast.
    private static let ringStarts: [TimeInterval] = [0.10, 0.28, 0.46]
    private static let ringTravelDuration: TimeInterval = 1.05
    /// Uniform tempo for the whole finale. Every beat's delay AND duration is
    /// multiplied by this in ``addCelebrationAnimation``, so the choreography
    /// stays in proportion: 1.0 is the authored speed, higher is slower
    /// (owner, live-tuned to 1.5625 — a calm, unhurried celebration). razor:
    /// the single tempo knob — retune here, never per-beat, or the stagger and
    /// the travel drift out of sync.
    private static let celebrationTimeScale: TimeInterval = 1.5625
    private static let auraDiameter: CGFloat = 184

    private let icon = NSImageView()
    private let headline = NSTextField(labelWithString: "You're all set.")
    // The payoff line lives HERE, not in the header (owner decision
    // 2026-08-11): the header keeps its welcome subtitle in every state.
    private let line = NSTextField(labelWithString: "Your Mac's sound can reach every room.")
    /// The static warm aura behind the icon — part of the RESTING frame, not
    /// the celebration. It is born HIDDEN (model opacity 0) and revealed to its
    /// resting opacity of 1 by ``layout()``, but ONLY once the icon has a real
    /// centre: unlike the rings (whose model opacity 0 keeps them safe on their
    /// own), a visible aura painted before layout resolves the centre blooms
    /// from the bottom-left origin — the launch bug the recording caught. Only
    /// its entrance animates from there.
    private let auraLayer = CAGradientLayer()
    /// The ripple rings. Model opacity 0 — they exist only during the shot.
    private let ringLayers: [CAShapeLayer]

    /// One-shot bookkeeping: `celebrationConsumed` is "the moment happened"
    /// (played, or skipped under Reduce Motion) and is what stops a repaint
    /// from re-firing it; `celebrationRunCount` counts real plays for the
    /// once-only assertion.
    private(set) var celebrationConsumed = false
    private(set) var celebrationRunCount = 0

    /// Set when `playCelebration()` fired before layout had resolved the icon's
    /// frame: the shot is SPENT (consumed) at the call, but its launch waits for
    /// the first real `layout()` so the ripple blooms from the icon centre, not
    /// the collapsed bottom-left origin the first synchronous play would see.
    private var pendingLaunch = false

    /// The view whose edges the RINGS must be fully faded out before they cross
    /// — the window-spanning host (the Setup window's whole content), wired by
    /// the pane. It lets the wave sweep the entire window yet never visibly
    /// terminate against a boundary; the rings pass faintly over the left spine
    /// on the way out, already dissolving by then. `nil` (a mock built with no
    /// host wired — a headless unit test) falls back to the stage-bound travel.
    weak var rippleBoundsView: NSView?

    init() {
        ringLayers = Self.ringStarts.map { _ in CAShapeLayer() }
        super.init(frame: .zero)
        wantsLayer = true
        build()
        registerForLiveColourChanges()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func build() {
        // NOTHING here clips: no `masksToBounds`, no corner rounding, no mask.
        // This card is ours and draws unframed, and the ripple has to cross
        // the stage edge rather than end at it.
        // The finale card is OURS, not a mock of a macOS surface, so it wears
        // the BRAND MARK rather than the OS app icon (see `BrandMark`); the
        // icon stays as the fallback for a build with no bundled asset.
        icon.image = BrandMark.image
            ?? NSApp?.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        headline.font = .systemFont(ofSize: 24, weight: .bold)
        headline.textColor = Tokens.Color.label
        headline.alignment = .center

        line.font = Tokens.Font.body
        line.textColor = Tokens.Color.label2
        line.alignment = .center

        let stack = NSStackView(views: [icon, headline, line])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(18, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Under the views: aura at the very back, rings between it and the
        // icon. Sublayers this view owns, never subviews — nothing else
        // manages their geometry, so the celebration can move them freely.
        layer?.insertSublayer(auraLayer, at: 0)
        for ring in ringLayers { layer?.insertSublayer(ring, above: auraLayer) }

        auraLayer.type = .radial
        auraLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        auraLayer.endPoint = CGPoint(x: 1, y: 1)
        // Hidden until layout sits it on the icon centre — see the property doc.
        auraLayer.opacity = 0
        for ring in ringLayers {
            ring.fillColor = nil
            ring.lineWidth = 2
            ring.opacity = 0
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
    }

    /// The aura/ring colours are STAMPED `CGColor`s: light/dark re-stamps
    /// arrive through `updateLayer`, but the accent dial and Increase Contrast
    /// change what the tokens resolve to without touching
    /// `effectiveAppearance`, so each needs its own trigger.
    private func registerForLiveColourChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(stampedColoursChanged),
            name: Tokens.accentStyleDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(stampedColoursChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @objc private func stampedColoursChanged() { needsDisplay = true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // `glow` for the aura (its whole job — and the Subtle dial resolves it
        // clear, so that dial's "no glow" rule lands here for free); `gold` for
        // the rings, which keep a real muted value under Subtle. Light glow is
        // a paper-soft hue (floor-exempt by spec), so light takes more ALPHA
        // to read as an aura at all — the same call-site alpha dial the
        // sidebar wash and the mock switch's off track already use.
        let glow = Tokens.Color.glow
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // The peak is scaled PER APPEARANCE: light glow is a paper-soft hue
        // (floor-exempt by spec) with nothing but alpha to read as an aura at
        // all, so it carries a much higher one — the same call-site alpha dial
        // the sidebar wash and the mock switch's off track already use. The
        // finale draws unframed, with no well fill under it to lift it.
        let peak: CGFloat = isDark ? 0.40 : 0.70
        auraLayer.colors = [glow.withAlphaComponent(peak).cgColor,
                            glow.withAlphaComponent(peak * 0.46).cgColor,
                            glow.withAlphaComponent(0).cgColor]
        auraLayer.locations = [0, 0.55, 1]
        let gold = Tokens.Color.gold.cgColor
        for ring in ringLayers { ring.strokeColor = gold }
    }

    override func layout() {
        super.layout()
        // The aura and rings anchor on the ICON's centre, which only layout
        // knows. Actions disabled: repositioning decoration is never a slide.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let centre = iconCentre
        auraLayer.bounds = CGRect(x: 0, y: 0, width: Self.auraDiameter, height: Self.auraDiameter)
        auraLayer.position = centre
        // Commit the aura's resting opacity ONLY now that it sits on a real
        // centre — actions disabled, so no slide and no un-suppressed fade. Held
        // at 0 (from `build()`) through every layout that hasn't resolved the
        // icon yet, so it can never paint at the bottom-left origin; the bloom's
        // own 0→1 keyframe still owns the animated entrance from here.
        if hasResolvedIconCentre { auraLayer.opacity = 1 }
        let ringRect = CGRect(x: 0, y: 0, width: Self.ringBaseDiameter, height: Self.ringBaseDiameter)
        for ring in ringLayers {
            ring.bounds = ringRect
            ring.position = centre
            ring.path = CGPath(ellipseIn: ringRect.insetBy(dx: 1, dy: 1), transform: nil)
        }
        CATransaction.commit()

        // A one-shot deferred because `playCelebration()` ran before this view
        // had a resolved icon fires now — the first layout with a real centre,
        // exactly once. Every later play (and Replay) is already laid out and
        // launches straight from `playCelebration()`.
        if pendingLaunch, hasResolvedIconCentre {
            pendingLaunch = false
            launchCelebration()
        }
    }

    /// The icon's centre in this view's coordinates — where the aura and rings
    /// anchor. Collapses to ~`.zero` (bottom-left) until layout resolves the
    /// icon's frame; ``hasResolvedIconCentre`` is the guard against reading it
    /// too early.
    private var iconCentre: CGPoint {
        icon.superview.map {
            convert(NSPoint(x: icon.frame.midX, y: icon.frame.midY), from: $0)
        } ?? .zero
    }

    /// Whether layout has given the icon a real frame. `DemoSettledMockView`
    /// does not override `isFlipped`, so an unresolved icon frame leaves the
    /// centre at the bottom-left origin — launching the ripple from there is the
    /// first-play bug this guards.
    private var hasResolvedIconCentre: Bool {
        bounds.width > 0 && icon.frame.width > 0 && icon.frame.height > 0
    }

    // MARK: The one-shot

    /// Spend the shot without motion — Reduce Motion's path. The settled frame
    /// is already the model state, so there is nothing else to apply.
    func skipCelebration() { celebrationConsumed = true }

    /// Spend the one-shot. The shot is CONSUMED here (so a repaint can never
    /// re-fire it), but it only LAUNCHES once the icon has a real frame: the
    /// shot starts ON the step crossfade, before the enclosing pass has
    /// positioned this view, so its centres are still collapsed at the
    /// bottom-left origin. When that is the case the launch is DEFERRED to the
    /// first real ``layout()``; every later play (and Replay) is already laid
    /// out and launches immediately.
    func playCelebration() {
        guard !celebrationConsumed else { return }
        celebrationConsumed = true
        guard hasResolvedIconCentre else {
            pendingLaunch = true
            needsLayout = true
            return
        }
        launchCelebration()
    }

    /// The one-shot itself: rings ripple out staggered, the aura blooms, the
    /// icon takes a small press of emphasis, and the text lands with the ripple.
    /// Only ever reached with a resolved icon frame — from ``playCelebration()``
    /// when the view is already laid out, or from ``layout()`` when a deferred
    /// launch comes due — so the ripple always blooms from the icon centre.
    private func launchCelebration() {
        celebrationRunCount += 1

        let endScale = ringEndScale()
        let fadeFraction = rippleFadeFraction(endScale: endScale)
        for (ring, start) in zip(ringLayers, Self.ringStarts) {
            addRipple(to: ring, delay: start, endScale: endScale, fadeFraction: fadeFraction)
        }

        // The aura swells past its resting size as it fades up, then settles
        // back onto it. The overshoot is in SCALE, never opacity: the settled
        // alpha IS the model value, so the shot still ends exactly on the
        // resting frame an interrupted or headless run renders.
        let bloomFade = CAKeyframeAnimation(keyPath: "opacity")
        bloomFade.values = [0, 1, 1]
        bloomFade.keyTimes = [0, 0.45, 1]
        let bloomSwell = CAKeyframeAnimation(keyPath: "transform.scale")
        bloomSwell.values = [0.86, 1.16, 1.0]
        bloomSwell.keyTimes = [0, 0.45, 1]
        let bloom = CAAnimationGroup()
        bloom.animations = [bloomFade, bloomSwell]
        addCelebrationAnimation(bloom, to: auraLayer, delay: 0.12, duration: 0.7, key: "bloom")

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.92, 1.04, 1.0]
        pop.keyTimes = [0, 0.55, 1]
        if let iconLayer = icon.layer {
            addCelebrationAnimation(pop, to: iconLayer, delay: 0, duration: 0.55, key: "pop")
        }
        addTextLanding(headline, delay: 0.34)
        addTextLanding(line, delay: 0.48)
    }

    /// How far a ring scales before it dies. It fills the whole WINDOW now, not
    /// the 418×278 stage or even the hero panel (which gained almost nothing over
    /// the stage): the leading edge travels to the window's farthest
    /// icon-centre-to-edge distance (``rippleBoundsView``), so the wave washes
    /// the entire Setup window rather than halting at the invisible stage
    /// boundary the owner saw partway across it. Nothing along the way clips —
    /// the chromeless well, the unmasked hero panel and the canvas all pass the
    /// ring through — and it is already fully faded before the NEAREST window
    /// edge (``rippleFadeFraction(endScale:)``), so no side ever shows it hit a
    /// wall. Derived per play rather than authored, so a resized window keeps
    /// full travel. With no host wired (a headless unit test) it falls back to
    /// the old stage-bound cap. At scale 1 the stroke's outer edge sits at
    /// `ringBaseDiameter / 2` (the path is inset 1 pt and half the 2 pt stroke
    /// rides back outside it), and the whole assembly scales together.
    private func ringEndScale() -> CGFloat {
        let base = Self.ringBaseDiameter / 2
        if let radii = boundsEdgeRadii() {
            return max(radii.farthest / base, 1)
        }
        let centre = ringLayers.first?.position ?? .zero
        let farthestEdge = max(centre.x, bounds.width - centre.x,
                               centre.y, bounds.height - centre.y)
        return max(farthestEdge / base, 1)
    }

    /// The travel FRACTION at which a ring's opacity must already be 0 — the
    /// point where its radius equals the window's NEAREST icon-centre-to-edge
    /// distance. The nearest edge governs, so no side ever shows a ring hitting
    /// a wall; the ring keeps expanding (invisibly) past it, out to
    /// ``ringEndScale()``. Because the window is so much bigger than the panel,
    /// this fraction now spreads the fade over a far longer travel, which is what
    /// keeps the pass over the left spine a soft glow rather than a hard line.
    /// `1` (no compression — the old full-length fade) when no host is wired.
    private func rippleFadeFraction(endScale: CGFloat) -> CGFloat {
        let base = Self.ringBaseDiameter / 2
        guard let radii = boundsEdgeRadii(), endScale > 1 else { return 1 }
        let scaleAtNearest = radii.nearest / base
        let fraction = (scaleAtNearest - 1) / (endScale - 1)
        return min(max(fraction, 0.05), 1)
    }

    /// The icon centre's distances to the window-spanning host's four edges, in
    /// this view's coordinates (`rippleBoundsView` converted into `self`). `nil`
    /// when no host is wired. Distances are clamped at 0 so a centre that
    /// momentarily resolves outside the host can't produce a negative radius.
    private func boundsEdgeRadii() -> (nearest: CGFloat, farthest: CGFloat)? {
        guard let host = rippleBoundsView else { return nil }
        let centre = iconCentre
        let rect = convert(host.bounds, from: host)
        let edges = [centre.x - rect.minX, rect.maxX - centre.x,
                     centre.y - rect.minY, rect.maxY - centre.y].map { max($0, 0) }
        guard let nearest = edges.min(), let farthest = edges.max(), farthest > 0 else { return nil }
        return (nearest, farthest)
    }

    /// One ring's flight: scale out to death while the stroke swells and fades.
    /// The fade completes at `fadeFraction` of the travel — the moment the ring
    /// reaches the window's nearest edge — then holds 0 while the ring keeps
    /// expanding to fill the window, so a wave dissipates in open air and never
    /// visibly terminates against a boundary. `fadeFraction == 1` restores the
    /// old full-length fade (the no-host fallback), byte for byte.
    private func addRipple(to ring: CAShapeLayer, delay: TimeInterval,
                           endScale: CGFloat, fadeFraction: CGFloat) {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = endScale
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        if fadeFraction >= 1 {
            // Rise fast, hold bright, then fade across the back half of the
            // flight — the ring is past the stage edges by then.
            fade.values = [0, 0.95, 0.95, 0]
            fade.keyTimes = [0, 0.12, 0.5, 1]
        } else {
            // Same rise/hold/fade shape, compressed into [0, fadeFraction] so
            // opacity is 0 by the nearest panel edge; 0 held to the end while
            // the ring keeps growing invisibly to fill the panel.
            let f = fadeFraction
            fade.values = [0, 0.95, 0.95, 0, 0]
            fade.keyTimes = [0, 0.12 * f, 0.5 * f, f, 1].map { NSNumber(value: Double($0)) }
        }
        let flight = CAAnimationGroup()
        flight.animations = [scale, fade]
        addCelebrationAnimation(flight, to: ring, delay: delay,
                                duration: Self.ringTravelDuration, key: "ripple")
    }

    /// A text line's landing: fade up from a few points below its resting spot.
    private func addTextLanding(_ label: NSTextField, delay: TimeInterval) {
        guard let layer = label.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -10
        rise.toValue = 0
        let landing = CAAnimationGroup()
        landing.animations = [fade, rise]
        addCelebrationAnimation(landing, to: layer, delay: delay, duration: 0.45, key: "land")
    }

    /// Shared send-off: delayed via `beginTime` with `.backwards` fill so the
    /// element holds its start value until its beat, ease-out, and removed on
    /// completion so the layer lands back on its settled model value.
    private func addCelebrationAnimation(_ animation: CAAnimation, to layer: CALayer,
                                         delay: TimeInterval, duration: TimeInterval, key: String) {
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            + delay * Self.celebrationTimeScale
        animation.duration = duration * Self.celebrationTimeScale
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: key)
    }

    // MARK: Test-support hooks

    var test_headlineText: String { headline.stringValue }
    var test_lineText: String { line.stringValue }

    /// The icon centre and the aura's launch anchor, for the first-play origin
    /// regression: after a real layout the aura sits ON the icon centre, never
    /// the bottom-left origin the first synchronous play used to bloom from.
    var test_iconCentre: CGPoint { iconCentre }
    var test_auraPosition: CGPoint { auraLayer.position }
    /// The aura's MODEL opacity: 0 until layout has committed it onto the icon
    /// centre, 1 afterwards. The transient corner-bloom the recording caught is
    /// a pre-layout paint no headless frame can see, so this is what pins the
    /// fix — the aura is never visible (opacity > 0) at the origin.
    var test_auraOpacity: Float { auraLayer.opacity }

    /// The nearest / farthest icon-centre-to-window-edge distances the ripple is
    /// tuned against — `nil` with no host wired. Exposed so a test computes them
    /// from the same real geometry the launch does.
    var test_nearestEdgeRadius: CGFloat? { boundsEdgeRadii()?.nearest }
    var test_farthestEdgeRadius: CGFloat? { boundsEdgeRadii()?.farthest }

    /// The ripple's maximum radius (fill reach), to prove the rings now travel
    /// PAST the 418×278 stage and the hero panel, out across the whole window.
    var test_rippleEndRadius: CGFloat? {
        ringEndScale(from: ringLayers.first).map { (Self.ringBaseDiameter / 2) * $0 }
    }

    /// The radius (icon-centre distance, this view's coordinates) at which each
    /// launched ripple's opacity first reaches 0. Each must be ≤ the nearest
    /// window edge so no ring is ever seen hitting a wall.
    var test_rippleFadeOutRadii: [CGFloat] {
        let base = Self.ringBaseDiameter / 2
        return ringLayers.compactMap { ring -> CGFloat? in
            guard let group = ring.animation(forKey: "ripple") as? CAAnimationGroup,
                  let anims = group.animations else { return nil }
            let scale = anims.compactMap { $0 as? CABasicAnimation }
                .first { $0.keyPath == "transform.scale" }
            let fade = anims.compactMap { $0 as? CAKeyframeAnimation }
                .first { $0.keyPath == "opacity" }
            let values = (fade?.values ?? []).compactMap { $0 as? NSNumber }.map { CGFloat(truncating: $0) }
            let keyTimes = (fade?.keyTimes ?? []).map { CGFloat(truncating: $0) }
            guard let endScale = (scale?.toValue as? NSNumber).map({ CGFloat(truncating: $0) }),
                  values.count == keyTimes.count,
                  let zeroIndex = Self.firstZeroAfterPeak(values)
            else { return nil }
            let scaleAtZero = 1 + keyTimes[zeroIndex] * (endScale - 1)
            return base * scaleAtZero
        }
    }

    /// The launched scale factor of one ring (`nil` if it has no ripple).
    private func ringEndScale(from ring: CAShapeLayer?) -> CGFloat? {
        guard let group = ring?.animation(forKey: "ripple") as? CAAnimationGroup,
              let scale = group.animations?.compactMap({ $0 as? CABasicAnimation })
                  .first(where: { $0.keyPath == "transform.scale" }),
              let end = (scale.toValue as? NSNumber).map({ CGFloat(truncating: $0) })
        else { return nil }
        return end
    }

    /// Index of the first opacity keyframe that is 0 after the ring has risen to
    /// its peak — the moment the ring goes invisible.
    private static func firstZeroAfterPeak(_ values: [CGFloat]) -> Int? {
        guard let peak = values.firstIndex(where: { $0 > 0 }) else { return nil }
        return values[peak...].firstIndex(where: { $0 == 0 })
    }
}

// MARK: - Drawn parts

/// A macOS window body: opaque, rounded, no border, with the wide soft drop
/// shadow a real alert or Settings window casts.
///
/// Deliberately NOT an `NSVisualEffectView`, even though both real surfaces are
/// vibrant: vibrancy samples the app's own window behind the mock and instantly
/// re-attaches it to Audiout's design. Flat and opaque reads more like a system
/// window than a real material does at this size.
final class DemoWindowSurfaceView: NSView {

    private let fill: NSColor
    /// The Settings window's corner; the permission dialog passes its own, much
    /// larger one.
    private let radius: CGFloat

    init(fill: NSColor = .windowBackgroundColor, radius: CGFloat = 10) {
        self.fill = fill
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        // A dark window needs a heavier shadow to separate from a dark canvas.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowOpacity = isDark ? 0.55 : 0.28
    }
}

/// How a drawn dialog button is marked.
///
/// The rehearsal's job is to say WHICH button to press, so the two cases are
/// not "how macOS fills this button" any more — they are right answer and wrong
/// answer. That is the one place the mock deliberately departs from the real
/// surface: on the real Accessibility alert the refusal is the accent-filled
/// DEFAULT, and drawing that faithfully emphasised exactly the button the user
/// must not press.
enum DemoButtonEmphasis {
    /// The button this step wants pressed: a slightly brighter fill and a thin
    /// ring around it.
    case correct
    /// Every other button: a ghost — no fill, just a hairline, so it still
    /// reads as a button without competing.
    case ghost
}

/// A drawn dialog button.
///
/// Two SHAPES, because the two surfaces this file mimics genuinely differ: the
/// macOS 26 privacy dialog's are full CAPSULES, while the older system ALERT
/// panel's are shorter rounded rects. The defaults here are the capsule, so the
/// privacy dialog's call sites say nothing extra. The MARKING is orthogonal to
/// the shape — see ``DemoButtonEmphasis``.
final class DemoPushButtonView: NSView {

    static let height: CGFloat = 28
    /// Air either side of the label.
    private static let labelInset: CGFloat = 10

    /// The real label this button carries — the one string a mock never fakes.
    let buttonTitle: String
    private let emphasis: DemoButtonEmphasis
    private let cornerRadius: CGFloat

    /// Whether this is the button the step wants pressed.
    var isMarked: Bool { emphasis == .correct }

    init(title: String,
         emphasis: DemoButtonEmphasis = .ghost,
         height: CGFloat = DemoPushButtonView.height,
         cornerRadius: CGFloat? = nil) {
        self.buttonTitle = title
        self.emphasis = emphasis
        self.cornerRadius = cornerRadius ?? height / 2
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // The LABEL is the one thing in a mock that is never abstracted: the
        // user has to recognise the words on the buttons when the real surface
        // arrives, and a greeked "Don't Allow" would teach them nothing.
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.textColor = emphasis == .correct ? .labelColor : .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.labelInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isCorrect = emphasis == .correct
        layer?.backgroundColor = isCorrect ? DemoSystemColor.markedButton.cgColor
                                           : NSColor.clear.cgColor
        // One hairline either way, so a ghost keeps a button's outline and the
        // marked one gets its ring — the difference is the fill behind it.
        layer?.borderWidth = 1
        layer?.borderColor = (isCorrect ? DemoSystemColor.markedButtonRim
                                        : DemoSystemColor.ghostButtonRim).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }
}

/// The privacy PADLOCK the system alert leads with.
///
/// `lock.fill` filled with a vertical gradient rather than a flat tint: the real
/// icon is artwork with a little dimension in it, and a flat symbol at this size
/// reads as a toolbar glyph instead. The symbol IS the mask, so there is no
/// second drawn shape to keep in step with it. The gradient is warm GREY, not
/// the real icon's gold — gold is spent on the CTA alone now (see
/// ``DemoSystemColor/lockTop``).
///
/// **TRAP: the mask has to be built in an image of its own.** Painting the
/// gradient `.sourceAtop` straight into `draw(_:)` does not clip to the symbol —
/// the view's backing store is not the empty destination that composite mode
/// needs, and the whole icon rect comes out a solid rectangle. Drawing the gradient
/// into a fresh `NSImage` and knocking the symbol's alpha out of it with
/// `.destinationIn` gives a surface nobody else has touched.
final class DemoLockIconView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: bounds.height, weight: .medium)) else { return }
        let size = symbol.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let drawn = NSRect(x: bounds.midX - size.width * scale / 2,
                           y: bounds.midY - size.height * scale / 2,
                           width: size.width * scale,
                           height: size.height * scale)

        let shaded = NSImage(size: drawn.size, flipped: false) { rect in
            // Negative angle so the LIGHTER end is at the top, as it is on the
            // real icon.
            NSGradient(starting: DemoSystemColor.lockTop,
                       ending: DemoSystemColor.lockBottom)?.draw(in: rect, angle: -90)
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        shaded.draw(in: drawn)
    }
}

/// The Settings sidebar sliver: traffic lights, a greeked search field, and a few
/// greeked rows one of which carries the blue selected pill. No legible text —
/// every label here would land under the 9 pt floor, so all of them are bars.
final class DemoSidebarView: NSView {

    /// Which row shows as selected. Middle of the list, so the pill has rows above
    /// and below it and reads as a selection rather than as a header.
    private static let selectedRow = 2
    private static let rowPitch: CGFloat = 17

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        // Traffic lights: no semantic colours exist for these.
        var previousDot: NSView?
        for colour in [DemoSystemColor.trafficRed, DemoSystemColor.trafficYellow,
                       DemoSystemColor.trafficGreen] {
            let dot = DemoDotView(diameter: 7, fill: colour)
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.centerYAnchor.constraint(equalTo: topAnchor, constant: 11),
                previousDot.map { dot.leadingAnchor.constraint(equalTo: $0.trailingAnchor, constant: 4) }
                    ?? dot.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            ])
            previousDot = dot
        }

        let search = DemoPillView(radius: 5, fill: .quaternaryLabelColor)
        addSubview(search)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            search.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            search.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Flat tinted squares, never glyphs: at 11 pt a symbol inside a coloured
        // tile turns to noise.
        let tints: [NSColor] = [.systemGray, .systemBlue, .systemBlue, .systemPink, .systemGray]
        var top: NSLayoutYAxisAnchor = search.bottomAnchor
        var gap: CGFloat = 10
        for (index, tint) in tints.enumerated() {
            let isSelected = index == Self.selectedRow
            let row = DemoSidebarRowView(tint: tint,
                                         labelWidth: [40, 46, 34, 44, 38][index],
                                         isSelected: isSelected)
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                row.topAnchor.constraint(equalTo: top, constant: gap),
                row.heightAnchor.constraint(equalToConstant: Self.rowPitch),
            ])
            top = row.bottomAnchor
            // One blank row's worth of air where Settings groups its sections.
            gap = index == 2 ? 8 : 0
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = DemoSystemColor.sidebar.cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        // Only the window's LEFT corners are the sidebar's to round.
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    }
}

/// One sidebar row: a flat tinted tile and a greeked label, inside the blue
/// selection pill when it's the selected one.
final class DemoSidebarRowView: NSView {

    init(tint: NSColor, labelWidth: CGFloat, isSelected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let pill = DemoPillView(radius: 5, fill: isSelected ? DemoSystemColor.settingsAccent : .clear)
        let tile = DemoPillView(radius: 3, fill: isSelected ? .white : tint)
        // A selected row's label goes white, like its text would.
        let label = DemoGreekBarView(width: labelWidth, fill: isSelected ? .white : .tertiaryLabelColor)
        for view in [pill, tile, label] { addSubview(view) }

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),

            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 11),
            tile.heightAnchor.constraint(equalToConstant: 11),

            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The macOS switch — the hero element of the Settings mock, kept near real size
/// because it is one of the three things that identify the UI.
final class DemoSwitchView: NSView {

    /// Track 22 × 13 keeps AppKit's small `NSSwitch` ratio (26 × 15 ≈ 1.78 : 1).
    static let size = NSSize(width: 22, height: 13)
    private static let knobInset: CGFloat = 1.5
    /// How far the knob slides: track minus the knob and both insets.
    static var knobTravel: CGFloat { size.width - knobDiameter - knobInset * 2 }
    static var knobDiameter: CGFloat { size.height - knobInset * 2 }

    /// **TRAP: the knob is a CALayer this view owns, not a subview.** AppKit owns
    /// a layer-backed VIEW's layer geometry — `position`, `bounds`, `transform` —
    /// and rewrites it on the next layout pass. An earlier version positioned an
    /// `NSView` knob by constraint and offset it with `layer.transform` for the ON
    /// state; layout wiped the transform, so an ON switch rendered with a blue
    /// track and the knob still parked at the LEFT — the off position, on a
    /// switch claiming to be on. A layer nobody else manages keeps the static
    /// state and the animation on the same property, with nothing to fight.
    private let knobLayer = CALayer()
    private static let knobAnimationKey = "knob"
    private var isOn = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.addSublayer(knobLayer)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Settled state, applied without animation.
    func setOn(_ on: Bool) {
        isOn = on
        needsLayout = true
        needsDisplay = true
        positionKnob()
        updateLayer()
    }

    /// The knob's resting frame for a state: ON slides it the full travel toward
    /// the trailing edge, OFF leaves it against the leading inset.
    private func knobFrame(on: Bool) -> CGRect {
        CGRect(x: Self.knobInset + (on ? Self.knobTravel : 0),
               y: Self.knobInset,
               width: Self.knobDiameter,
               height: Self.knobDiameter)
    }

    private func positionKnob() {
        // While the flip is running, the animation owns the knob.
        guard knobLayer.animation(forKey: Self.knobAnimationKey) == nil else { return }
        knobLayer.frame = knobFrame(on: isOn)
        knobLayer.cornerRadius = Self.knobDiameter / 2
    }

    /// This switch's part of the pass: the press dip, the flip (the knob sliding
    /// leading → trailing while the track CROSS-FADES to blue, never wipes), the
    /// hold, and back off — a pass has to end where it started, both so the loop is
    /// seamless and so the resting frame is the state the user will really find.
    /// A staged host (Remote Control's handoff) shifts this score through its
    /// ``DemoMockView/stageWindow``, so there is nothing per-stage in here.
    func addTimeline(on host: DemoMockView) {
        let off = Self.offTrackColor.cgColor, on = DemoSystemColor.settingsAccent.cgColor
        layer?.add(host.keyframes("backgroundColor", host.held([
            (0, off), (DemoBeat.pressEnd, off),
            (DemoBeat.changeEnd, on), (DemoBeat.holdEnd, on),
            (DemoBeat.resetEnd, off), (DemoBeat.loop, off),
        ])), forKey: "tint")

        let offCentre = NSValue(point: CGPoint(x: knobFrame(on: false).midX,
                                              y: knobFrame(on: false).midY))
        let onCentre = NSValue(point: CGPoint(x: knobFrame(on: true).midX,
                                             y: knobFrame(on: true).midY))
        knobLayer.add(host.keyframes("position", host.held([
            (0, offCentre), (DemoBeat.pressEnd, offCentre),
            (DemoBeat.changeEnd, onCentre), (DemoBeat.holdEnd, onCentre),
            (DemoBeat.resetEnd, offCentre), (DemoBeat.loop, offCentre),
        ])), forKey: Self.knobAnimationKey)
    }

    /// The off track.
    ///
    /// `quaternaryLabelColor` is what the frames measure and it reads correctly in
    /// dark. In LIGHT it is too faint for this job — a white knob on a near-white
    /// track over an already-light card, on the row the whole mock exists for — so
    /// light takes one step more contrast.
    static var offTrackColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .quaternaryLabelColor
                : .tertiaryLabelColor
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isOn ? DemoSystemColor.settingsAccent : Self.offTrackColor).cgColor
        // No hairline border: the real one is dropped below a ~13 pt track.
        layer?.cornerRadius = bounds.height / 2
        // The knob is white in BOTH appearances.
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.25
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: -0.5)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        positionKnob()
    }

    // MARK: Test-support hooks

    /// Where the knob actually sits, so a test can pin that ON means the trailing
    /// end — the exact thing that regressed.
    var test_knobIsAtTrailingEnd: Bool { knobLayer.frame.minX > Self.knobInset }
    var test_isOn: Bool { isOn }
}

/// One row of the grouped list: either the Audiout row (real icon, real name,
/// the live switch) or an anonymous one — a flat tinted tile and a greeked label,
/// enough for the list to read as a list of apps without inventing another app's
/// name to put in it.
final class DemoSettingsRowView: NSView {

    static let height: CGFloat = 26
    /// Where the label starts, and therefore where the separators are inset to.
    static let labelInset: CGFloat = 26

    static func placeholder(labelWidth: CGFloat, isOn: Bool) -> DemoSettingsRowView {
        DemoSettingsRowView(name: nil, labelWidth: labelWidth, switchView: nil, isOn: isOn)
    }

    static func app(name: String, switchView: DemoSwitchView) -> DemoSettingsRowView {
        DemoSettingsRowView(name: name, labelWidth: 0, switchView: switchView, isOn: false)
    }

    private init(name: String?, labelWidth: CGFloat, switchView: DemoSwitchView?, isOn: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let leading: NSView
        if name != nil {
            // Settings shows the app's REAL icon beside its name, read the
            // same way System Settings itself reads it — see
            // `demoIconAsAThirdPartyProcessSeesIt`.
            let icon = NSImageView()
            icon.image = demoIconAsAThirdPartyProcessSeesIt()
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            leading = icon
        } else {
            leading = DemoPillView(radius: 3.5, fill: .tertiaryLabelColor)
        }

        // 9.5 pt clears the 9 pt floor; anything smaller is greeked instead.
        let identity: NSView
        if let name {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 9.5)
            label.textColor = .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            identity = label
        } else {
            identity = DemoGreekBarView(width: labelWidth)
        }

        let trailing: NSView = switchView ?? {
            let other = DemoSwitchView()
            other.setOn(isOn)
            return other
        }()

        for view in [leading, identity, trailing] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.widthAnchor.constraint(equalToConstant: 14),
            leading.heightAnchor.constraint(equalToConstant: 14),

            identity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelInset),
            identity.centerYAnchor.constraint(equalTo: centerYAnchor),

            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            identity.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A greeked line of text: one rounded bar where a label would be. Used wherever
/// real text would land under 9 pt — between 6 and 8.5 pt text antialiases into
/// mush and reads as a rendering bug rather than as words.
final class DemoGreekBarView: NSView {

    init(width: CGFloat, height: CGFloat = 3, fill: NSColor = .tertiaryLabelColor) {
        self.fill = fill
        self.barHeight = height
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let fill: NSColor
    private let barHeight: CGFloat

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = barHeight / 2
    }
}

/// A plain rounded rectangle — the sidebar's selection pill, its search field,
/// and the flat tinted tiles that stand in for icons.
final class DemoPillView: NSView {

    private let radius: CGFloat
    private let fill: NSColor

    init(radius: CGFloat, fill: NSColor) {
        self.radius = radius
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }
}

/// A filled circle — the window's traffic lights.
final class DemoDotView: NSView {

    private let fill: NSColor

    init(diameter: CGFloat, fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = bounds.height / 2
    }
}

/// The demo pointer: the REAL macOS arrow, `NSCursor.arrow.image`, drawn at
/// about 1.5× life size — big enough to follow at mock scale, small enough to be
/// a pointer rather than a prop.
///
/// The system image, not a drawn silhouette: it is the same artwork the user is
/// about to see under their own hand, it carries its own outline and shape, and it
/// re-resolves per macOS release for free. The drop shadow is what keeps the
/// pointer legible over the grey capsule it presses.
final class DemoCursorView: NSView {

    private static let cursor = NSCursor.arrow
    private static var image: NSImage { cursor.image }
    /// Where the cursor is positioned FROM, in the image's own (top-left origin)
    /// coordinates — the tip, for the arrow.
    private static var hotSpot: NSPoint { cursor.hotSpot }

    /// The arrow's artwork sits in the TOP-LEFT of its image box and fills about
    /// HALF of it (measured: ink y 3…22 of a 28 × 40 pt image). So the view is
    /// sized from the POINTER height the caller wants, not from the box — asking
    /// for a 24 pt pointer and getting a 12 pt one is how the sizing goes wrong.
    private static let inkHeightFraction: CGFloat = 0.5

    /// View points per image point, so the hot spot scales with the artwork.
    private let scale: CGFloat

    init(pointerHeight: CGFloat) {
        let imageSize = Self.image.size
        let height = (pointerHeight / Self.inkHeightFraction).rounded()
        scale = height / max(imageSize.height, 1)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            widthAnchor.constraint(equalToConstant: max((imageSize.width * scale).rounded(), 1)),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The hot spot in this view's own coordinates — what every motion path
    /// anchors on, because that is the point a real cursor is aligned by (the
    /// image's centre would land the press off the button).
    var tipPoint: NSPoint { NSPoint(x: Self.hotSpot.x * scale, y: Self.hotSpot.y * scale) }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        Self.image.draw(in: bounds)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // MARK: The click splash

    /// One ring of the splash: when it sets off after the press, and how far it
    /// gets before it is gone.
    private struct SplashRing {
        let delay: TimeInterval
        let startRadius: CGFloat
        let endRadius: CGFloat
        let lineWidth: CGFloat
    }

    /// Two concentric hairline rings, the second a beat behind and smaller —
    /// a sound wave leaving the click, which is the one place this audio app's
    /// own character may show inside a mock of somebody else's chrome. Two, not
    /// a burst of dots or a filled pulse: at pointer scale anything heavier
    /// reads as a screen-recording tap indicator.
    private static let splashRings = [
        SplashRing(delay: 0, startRadius: 3, endRadius: 10, lineWidth: 1.25),
        SplashRing(delay: 0.06, startRadius: 2, endRadius: 6.5, lineWidth: 1),
    ]

    /// Press to gone. Sized to the TIGHTEST press-to-cursor-fade window any
    /// pass has — the prompt mock presses at 1.90 s and its cursor is fully
    /// faded by 2.08 s — so the ripple always completes before the pointer it
    /// belongs to disappears.
    static let splashDuration: TimeInterval = 0.18

    private var splashLayers: [CAShapeLayer] = []

    /// The press flourish: rings ripple out FROM THE TIP at `time` (seconds
    /// along `host`'s pass, mapped through its ``DemoMockView/stageWindow``
    /// like every other score). The layers live inside this view, anchored on
    /// ``tipPoint``, so they ride the cursor's transform — the splash follows
    /// the pointer wherever the glide has taken it, with no coordinates for a
    /// call site to keep in step.
    ///
    /// The layers' MODEL opacity is 0 and nothing ever changes it: only the
    /// pass's keyframes make a ring visible, so a stopped, settled or headless
    /// frame cannot carry one by construction. Pure `CALayer`s, so nothing here
    /// can enter the accessibility tree either.
    func addClickSplash(on host: DemoMockView, at time: TimeInterval) {
        guard let layer else { return }
        if splashLayers.isEmpty {
            splashLayers = Self.splashRings.map { ring in
                let shape = CAShapeLayer()
                shape.fillColor = nil
                shape.lineWidth = ring.lineWidth
                shape.opacity = 0   // the model value — never anything else
                layer.addSublayer(shape)
                return shape
            }
        }
        // Neutral ink, deliberately: the splash is narration, but it plays over
        // surfaces that must read as macOS, and a gold or accent burst would
        // claim macOS draws coloured feedback. Re-stamped per pass (like the
        // switch tint), so an appearance change is picked up on the next one.
        let ink = NSColor.labelColor.cgColor
        for (ring, shape) in zip(Self.splashRings, splashLayers) {
            shape.position = tipPoint
            shape.strokeColor = ink
            let circle = { (radius: CGFloat) in
                CGPath(ellipseIn: CGRect(x: -radius, y: -radius,
                                         width: radius * 2, height: radius * 2),
                       transform: nil)
            }
            let small = circle(ring.startRadius)
            let large = circle(ring.endRadius)

            let start = time + ring.delay
            let end = time + Self.splashDuration
            shape.add(host.keyframes("opacity", [
                (start - 0.01, 0), (start, 0.65), (end, 0),
            ], timing: .easeOut), forKey: "splashFade")
            shape.add(host.keyframes("path", [
                (start - 0.01, small), (start, small), (end, large),
            ], timing: .easeOut), forKey: "splashGrow")
        }
    }

    // MARK: Test-support hooks

    /// At rest: invisible and free of animations — what every settled frame
    /// (and therefore every snapshot fixture) must find.
    var test_splashIsSettled: Bool {
        splashLayers.allSatisfy { $0.opacity == 0 && ($0.animationKeys() ?? []).isEmpty }
    }

    /// Mid-pass: every ring is carrying its score — what pins that a press site
    /// actually wired the splash in.
    var test_splashIsArmed: Bool {
        !splashLayers.isEmpty
            && splashLayers.allSatisfy { ($0.animationKeys() ?? []).contains("splashGrow") }
    }
}

// MARK: - Small helper

extension NSView {
    /// Every descendant, for the "re-stamp resolved colours" sweep.
    var subviewsRecursively: [NSView] { subviews + subviews.flatMap(\.subviewsRecursively) }

    // MARK: Test-support hooks

    /// Every drawn dialog button in this surface, leading to trailing — one
    /// walk that serves the prompt card, the alert panel and the two-stage host
    /// alike, so no mock needs a hook of its own.
    private var demoButtons: [DemoPushButtonView] {
        subviewsRecursively.compactMap { $0 as? DemoPushButtonView }
    }

    /// The REAL labels this surface's buttons carry.
    var test_demoButtonTitles: [String] { demoButtons.map(\.buttonTitle) }

    /// The one button marked as the right answer — `nil` if none is, and a
    /// crash-free way to catch two being marked (the array would have two).
    var test_demoMarkedButtonTitle: String? {
        let marked = demoButtons.filter(\.isMarked)
        return marked.count == 1 ? marked[0].buttonTitle : nil
    }
}

// MARK: - The iPhone card's stage

/// Audiout Remote's rehearsal: the invitation itself, at 160 pt on a
/// `raised` tile with the address in caption under it.
///
/// Every other stage draws the DIALOG a click raises. This ask raises no
/// dialog — the next surface is a page on the user's phone — so the stage
/// shows the one thing that gets them there. Static under every motion
/// setting: there is no gesture to rehearse and a code that moves is a code
/// nobody can scan.
final class DemoRemoteInviteMockView: DemoMockView {

    private let invite = RemoteInviteView(tileSide: RemoteInviteView.setupTileSide)
    private let tilePadding: CGFloat = 24
    private let tileCornerRadius: CGFloat = 12

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(invite)
        NSLayoutConstraint.activate([
            invite.topAnchor.constraint(equalTo: topAnchor, constant: tilePadding),
            invite.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -tilePadding),
            invite.leadingAnchor.constraint(equalTo: leadingAnchor, constant: tilePadding),
            invite.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -tilePadding),
        ])
        // The `raised` fill and its edge are drawn, not stamped, so they
        // re-resolve on every pass; this is the other half of the trigger —
        // Increase Contrast fires no appearance change of its own.
        redrawOnAccessibilityDisplayChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The rehearsal takes no clicks, exactly as the consent card's does not.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: tileCornerRadius, yRadius: tileCornerRadius)
        Tokens.Color.raised.setFill()
        tile.fill()
        Tokens.Color.containerEdge.setStroke()
        tile.lineWidth = 1
        tile.stroke()
    }

    // MARK: Test-support hooks

    /// The invitation the card really carries, so a test can prove the stage
    /// and the other two hosts mount the same view.
    var test_invite: RemoteInviteView { invite }
}
