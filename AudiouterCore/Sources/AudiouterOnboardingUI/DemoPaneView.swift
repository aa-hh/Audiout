// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// Which miniature the demo pane is showing for the active step. Public only
/// because the Setup window's `test_demoMode` hook exposes it.
public enum DemoMode: Equatable, Sendable {
    /// The step's first ask: a miniature of the system permission DIALOG, with
    /// a cursor pressing Allow.
    case prompt
    /// The retry path (and Speaker Sync always, which has no prompt at all): a
    /// miniature of the System Settings pane, with a toggle switching on.
    case settings
    /// Every permission is in — a calm resting state, no loop.
    case settled
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
/// snapshot fixtures always capture the settled frame.
///
/// The demo is DECORATIVE: it is excluded from the accessibility tree entirely
/// (the card copy beside it carries every word of the information). Only Replay,
/// a real control, stays accessible.
final class DemoPaneView: NSView {

    /// The elevated surface both mocks sit on — fixed, so consecutive steps
    /// read at the same scale rather than the pane resizing under the user.
    static let surfaceSize = NSSize(width: 336, height: 268)

    /// The step-to-step content crossfade.
    static let stepCrossfadeDuration: TimeInterval = 0.22

    private let surface = RoundedContainerView()
    /// Hosts the current mock; the accessibility opt-out lives here so Replay
    /// (outside it) stays reachable.
    private let mockHost = NSView()
    private var mock: NSView?
    private let replayButton: NSButton

    private var step: SetupStep?
    private var mode: DemoMode = .prompt

    private var occlusionObserver: NSObjectProtocol?

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

        surface.addSubview(mockHost)
        addSubview(surface)

        replayButton.bezelStyle = .rounded
        replayButton.controlSize = .small
        replayButton.target = self
        replayButton.action = #selector(replayTapped)
        replayButton.translatesAutoresizingMaskIntoConstraints = false
        replayButton.isHidden = true
        addSubview(replayButton)

        // Only the surface's own size is required: the pane's height comes from
        // the window, and nothing in here may push the fixed window taller.
        let replayBelow = replayButton.topAnchor.constraint(equalTo: surface.bottomAnchor, constant: 14)
        replayBelow.priority = .defaultHigh
        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: centerXAnchor),
            surface.centerYAnchor.constraint(equalTo: centerYAnchor),
            surface.widthAnchor.constraint(equalToConstant: Self.surfaceSize.width),
            surface.heightAnchor.constraint(equalToConstant: Self.surfaceSize.height),

            mockHost.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            mockHost.centerYAnchor.constraint(equalTo: surface.centerYAnchor),

            replayButton.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            replayBelow,
        ])
    }

    /// A layer-colour instrument has to reconcile its live re-resolution triggers
    /// itself (SharedUI AGENTS.md), because none of them reach a view through
    /// `viewDidChangeEffectiveAppearance` or a model push. Two apply here: a
    /// mid-session Reduce Motion toggle, which changes the motion POLICY, and the
    /// user's macOS accent, which the mock's confirming button stamps as a
    /// resolved `CGColor`. The app's OWN accent dial is deliberately not one of
    /// them — nothing inside a mock is painted from `Tokens`, that is the point of
    /// the system-look rule.
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
    func show(step: SetupStep?, mode: DemoMode, animated: Bool) {
        let changed = step != self.step || mode != self.mode || mock == nil
        self.step = step
        self.mode = mode
        guard changed else { return }

        let outgoing = mock
        let incoming = Self.makeMock(step: step, mode: mode)
        mock = incoming
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

    /// Take a whole drawn mock out of the accessibility tree, view by view. The
    /// container-level opt-out hoists rather than prunes, and these subtrees
    /// carry real `NSTextField`s and images that are elements by default.
    private static func installAccessibilityOptOut(_ view: NSView) {
        view.setAccessibilityElement(false)
        view.setAccessibilityChildren([])
        view.subviews.forEach(installAccessibilityOptOut)
    }

    private static func makeMock(step: SetupStep?, mode: DemoMode) -> NSView {
        guard let step, mode != .settled else { return DemoSettledMockView() }
        switch mode {
        case .prompt:   return DemoPromptMockView(step: step)
        case .settings: return DemoSettingsMockView(step: step)
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
        guard let timeline = mock as? DemoMockView else {
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
    var test_isAnimating: Bool { (mock as? DemoMockView)?.isTimelineRunning ?? false }
    var test_isLooping: Bool { (mock as? DemoMockView)?.isLooping ?? false }
    var test_showsReplay: Bool { !replayButton.isHidden }
    /// `nil` = the live system setting (the shared override seam).
    var test_reduceMotionOverride: Bool?
    /// `nil` = the live window/headless check.
    var test_canAnimateOverride: Bool?
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
        Self.removeAnimations(from: layer)
        applySettledState()
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
    func keyframes(_ keyPath: String,
                   _ score: [(time: TimeInterval, value: Any)],
                   timing: CAMediaTimingFunctionName = .easeInEaseOut) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.duration = timelineDuration
        animation.values = score.map(\.value)
        animation.keyTimes = score.map { NSNumber(value: $0.time / timelineDuration) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: timing),
                                          count: max(score.count - 1, 0))
        animation.calculationMode = .linear
        // The settled model value is the pass's last value, so letting the
        // animation be removed on completion lands exactly there.
        animation.fillMode = .backwards
        return animation
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
/// These five can't be: System Settings paints its sidebar DARKER than its
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
    /// Sidebar fill — darker than the content pane in BOTH appearances.
    static let sidebar = dynamic(light: 0xE8E8E8, dark: 0x232326)
    /// Content-pane fill.
    static let contentPane = dynamic(light: 0xF4F4F4, dark: 0x2C2C2E)
    /// The grouped list's fill. Real Settings draws the card within one level of
    /// the pane and defines it by its border alone; at mock scale that vanishes,
    /// so this is lifted ~2.5 % — a readability adjustment, not a measurement.
    static let card = dynamic(light: 0xFAFAFA, dark: 0x333336)
    /// A plain push button. `controlColor` is white-ish in light mode, which is
    /// the SHEET's Cancel button, not an alert's grey one.
    static let plainButton = dynamic(light: 0xD7D7D7, dark: 0x5A5A5E)
    /// The default button's gradient top — the accent about 8 % lighter. The
    /// gradient is what makes an AppKit accent button read as one.
    static let accentGradientTop = dynamic(light: 0x2A8CFB, dark: 0x2E90FF)

    static let trafficRed = solid(0xFF5F57)
    static let trafficYellow = solid(0xFEBC2E)
    static let trafficGreen = solid(0x28C840)

    /// The mock's accent. **Never `controlAccentColor`:** that follows the user's
    /// Appearance setting, so on a Mac set to pink this "system" dialog would come
    /// out pink — the exact opposite of a generic macOS read.
    static var accent: NSColor { .systemBlue }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return solid(isDark ? dark : light)
        }
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
    static let changeEnd: TimeInterval = 2.08
    static let holdEnd: TimeInterval = 3.48
    static let resetEnd: TimeInterval = 3.78
    static let loop: TimeInterval = 4.50
}

// MARK: - Prompt mock

/// A miniature of the TCC permission dialog for one step: the app icon on top,
/// the ask, and a two-up button row — with a drawn cursor gliding to the
/// confirming button, pressing it, and the dialog settling into its granted
/// state.
///
/// Drawn at 1:1 with the real alert (256 × 231 pt), which is the single most
/// important scale finding in the reference: at this size real text at real
/// sizes is what sells it, so nothing here is greeked or shrunk. The centred,
/// icon-on-top layout is the TCC/privacy shape — NOT `NSAlert`'s left-icon one —
/// and the wording is a recognisable likeness rather than verbatim OS text, which
/// would go stale against a macOS release.
final class DemoPromptMockView: DemoMockView {

    static let size = NSSize(width: 260, height: 210)
    /// Content inset on all four sides.
    private static let inset: CGFloat = 16

    private let step: SetupStep
    private let askStack = NSStackView()
    private let grantedStack = NSStackView()
    /// ~1.5× life size: readable at this scale without dominating a 210 pt-tall
    /// dialog the way the old drawing (a third of its height) did.
    private let cursor = DemoCursorView(pointerHeight: 24)
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
        let icon = NSImageView()
        icon.image = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let ask = NSTextField(labelWithString: Self.askText(for: step))
        ask.font = .boldSystemFont(ofSize: 13)
        ask.textColor = .labelColor
        ask.alignment = .center
        ask.maximumNumberOfLines = 2
        ask.lineBreakMode = .byWordWrapping
        ask.preferredMaxLayoutWidth = Self.size.width - Self.inset * 2

        // Negative on the left, default on the right, filling the content width.
        let deny = DemoPushButtonView(title: "Don't Allow", isDefault: false)
        confirmButton = DemoPushButtonView(title: Self.confirmTitle(for: step), isDefault: true)
        let buttons = NSStackView(views: [deny, confirmButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillEqually

        askStack.orientation = .vertical
        askStack.alignment = .centerX
        askStack.spacing = 14
        askStack.translatesAutoresizingMaskIntoConstraints = false
        askStack.addArrangedSubview(icon)
        askStack.addArrangedSubview(ask)
        askStack.addArrangedSubview(buttons)
        askStack.setCustomSpacing(18, after: ask)

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 28, weight: .semibold)
        check.contentTintColor = .systemGreen
        check.translatesAutoresizingMaskIntoConstraints = false

        let capability = NSTextField(labelWithString: Self.grantedText(for: step))
        capability.font = .systemFont(ofSize: 13, weight: .medium)
        capability.textColor = .labelColor
        capability.alignment = .center

        grantedStack.orientation = .vertical
        grantedStack.alignment = .centerX
        grantedStack.spacing = 10
        grantedStack.translatesAutoresizingMaskIntoConstraints = false
        grantedStack.addArrangedSubview(check)
        grantedStack.addArrangedSubview(capability)

        let dialog = DemoWindowSurfaceView()
        dialog.addSubview(askStack)
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

            // Real alerts use a 64 pt icon box; 48 buys back the height a 2-line
            // title costs.
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            buttons.widthAnchor.constraint(equalTo: dialog.widthAnchor,
                                           constant: -Self.inset * 2),

            askStack.centerXAnchor.constraint(equalTo: dialog.centerXAnchor),
            askStack.centerYAnchor.constraint(equalTo: dialog.centerYAnchor),
            askStack.topAnchor.constraint(greaterThanOrEqualTo: dialog.topAnchor,
                                          constant: Self.inset),

            grantedStack.centerXAnchor.constraint(equalTo: dialog.centerXAnchor),
            grantedStack.centerYAnchor.constraint(equalTo: dialog.centerYAnchor),
            grantedStack.leadingAnchor.constraint(greaterThanOrEqualTo: dialog.leadingAnchor,
                                                 constant: Self.inset),

            // The cursor's resting position; the timeline moves it by TRANSFORM
            // (AutoLayout owns its frame and would reset an animated position).
            // The arrow's TIP is the anchor, so the view's top-left is the hot spot.
            cursor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            cursor.topAnchor.constraint(equalTo: topAnchor, constant: 24),
        ])
        applySettledState()
    }

    /// The settled frame is the dialog AS THE USER WILL FIND IT — the ask, with
    /// the cursor waiting. Deliberately NOT the granted end state: the pane
    /// always shows the ACTIVE step's mock, so resting on "allowed" would sit
    /// beside a card that is still asking for that very permission and claim it
    /// was already given. Every pass therefore returns here, which also makes
    /// the loop seamless.
    override func applySettledState() {
        askStack.alphaValue = 1
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

        // Press: the real button darkens about 4 % for ~100 ms.
        confirmButton.layer?.add(keyframes("opacity", [
            (0, 1), (DemoBeat.travelEnd, 1), (DemoBeat.pressEnd, 0.85),
            (DemoBeat.pressEnd + 0.08, 1), (end, 1),
        ]), forKey: "press")

        askStack.layer?.add(keyframes("opacity", [
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

    /// The ask, per step — quoted-app-name style, sentence case, full stop, and
    /// recognisably the shape of the real dialog without quoting OS text that
    /// changes between releases.
    static func askText(for step: SetupStep) -> String {
        switch step {
        case .audio:         return "“Audiouter” would like to\nrecord this Mac's audio."
        case .localNetwork:  return "“Audiouter” would like to find\nspeakers on your network."
        case .bluetooth:     return "“Audiouter” would like to\nuse Bluetooth."
        case .remoteControl: return "“Audiouter” would like to\ncontrol this Mac."
        // Speaker Sync has no prompt (it is a Login Items approval) and never
        // reaches the prompt mock; the settings mock is its only mode.
        case .speakerSync:   return "“Audiouter” would like to\nrun in the background."
        }
    }

    static func confirmTitle(for step: SetupStep) -> String {
        switch step {
        case .audio, .localNetwork: return "Allow"
        case .bluetooth, .remoteControl, .speakerSync: return "OK"
        }
    }

    static func grantedText(for step: SetupStep) -> String {
        switch step {
        case .audio:         return "Sound access allowed"
        case .localNetwork:  return "Network access allowed"
        case .bluetooth:     return "Bluetooth allowed"
        case .remoteControl: return "Control allowed"
        case .speakerSync:   return "Background use allowed"
        }
    }
}

// MARK: - Settings mock

/// A miniature of the System Settings pane a retry lands on: the window's
/// traffic lights, the sidebar with its blue selected row, the pane title, and a
/// grouped list whose third row is Audiouter — with a drawn cursor switching it
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

    static let size = NSSize(width: 300, height: 190)
    /// The reference puts the sidebar at 80 pt (27 % of 300, deliberately less
    /// than the real 30 % so it isn't mostly empty chrome). 76 here: the longest
    /// real pane title ("Screen & System Audio Recording") needs every point the
    /// content side can spare, and the title is the one string that has to be
    /// legible and complete — it is what says WHICH pane this is.
    private static let sidebarWidth: CGFloat = 76

    private let step: SetupStep
    private var toggle: DemoSwitchView!
    /// Slightly smaller than the prompt mock's, in step with this mock's own
    /// tighter scale.
    private let cursor = DemoCursorView(pointerHeight: 22)

    init(step: SetupStep) {
        self.step = step
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

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
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),

            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            sidebar.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: shell.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: shell.topAnchor),
            divider.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            header.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),
            // Required, not `<=`: the title has to be clipped by the pane's own
            // edge rather than drawn past it.
            header.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: shell.topAnchor, constant: 14),

            card.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            card.bottomAnchor.constraint(lessThanOrEqualTo: shell.bottomAnchor, constant: -12),

            // Parked low in the content pane, clear of the title and the card's
            // first row — a cursor sitting on top of text read as a mistake.
            cursor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 110),
            cursor.topAnchor.constraint(equalTo: topAnchor, constant: 138),
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
        back.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        back.contentTintColor = .tertiaryLabelColor
        back.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: Self.paneTitle(for: step))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.allowsDefaultTighteningForTruncation = true

        let row = NSStackView(views: [back, title])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
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

        let caption = DemoGreekBarView(width: 96)
        card.addSubview(caption)

        let rows: [NSView] = [
            DemoSettingsRowView.placeholder(labelWidth: 58, isOn: true),
            DemoSettingsRowView.placeholder(labelWidth: 44, isOn: true),
            DemoSettingsRowView.app(name: "Audiouter", switchView: toggle),
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
                row.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 6).isActive = true
            }
            previous = row
        }

        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            caption.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            previous!.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    /// Settled: the switch OFF, cursor waiting — the pane as the user will find
    /// it (see ``DemoPromptMockView/applySettledState()`` for why the rest state
    /// is never the finished one).
    override func applySettledState() {
        toggle.setOn(false)
        cursor.alphaValue = 1
        cursor.layer?.transform = CATransform3DIdentity
    }

    override func addTimelineAnimations() {
        let end = timelineDuration
        let delta = cursorTravel()
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

        toggle.addTimeline(on: self)
    }

    private func cursorTravel() -> CGPoint {
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
        }
    }
}

// MARK: - Settled mock

/// The completion state: the app's own icon and one calm line. No loop, and none
/// of the shadow-heavy window chrome — nothing is being asked for any more.
final class DemoSettledMockView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let icon = NSImageView()
        icon.image = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let line = NSTextField(labelWithString: "Every speaker is ready.")
        line.font = .systemFont(ofSize: NSFont.systemFontSize)
        line.textColor = .labelColor
        line.alignment = .center

        let stack = NSStackView(views: [icon, line])
        stack.orientation = .vertical
        stack.alignment = .centerX
        // Nothing is being asked for here, so the one thing on the surface may
        // take the room: a larger icon and more air under it than the mocks,
        // which are packed to mimic a real dialog's density.
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: DemoPromptMockView.size.width),
            heightAnchor.constraint(equalToConstant: DemoPromptMockView.size.height),
            icon.widthAnchor.constraint(equalToConstant: 88),
            icon.heightAnchor.constraint(equalToConstant: 88),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
    }
}

// MARK: - Drawn parts

/// A macOS window body: opaque, rounded, no border, with the wide soft drop
/// shadow a real alert or Settings window casts.
///
/// Deliberately NOT an `NSVisualEffectView`, even though both real surfaces are
/// vibrant: vibrancy samples the app's own window behind the mock and instantly
/// re-attaches it to Audiouter's design. Flat and opaque reads more like a system
/// window than a real material does at this size.
final class DemoWindowSurfaceView: NSView {

    private let fill: NSColor

    init(fill: NSColor = .windowBackgroundColor) {
        self.fill = fill
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
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        // A dark window needs a heavier shadow to separate from a dark canvas.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowOpacity = isDark ? 0.55 : 0.28
    }
}

/// A macOS push button. `isDefault` is the accent-filled one, which carries the
/// top-to-bottom gradient that makes an AppKit accent button look like one rather
/// than like a flat web button.
///
/// A 6 pt ROUNDED RECT, not a capsule: capsules arrived with macOS 26's Liquid
/// Glass, and at this size a capsule reads as an iOS or web control — exactly the
/// failure this mock exists to avoid.
final class DemoPushButtonView: NSView {

    static let height: CGFloat = 28
    private static let radius: CGFloat = 6

    private let isDefault: Bool

    init(title: String, isDefault: Bool) {
        self.isDefault = isDefault
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        label.textColor = isDefault ? .white : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius)
        guard isDefault else {
            DemoSystemColor.plainButton.setFill()
            path.fill()
            return
        }
        NSGradient(starting: DemoSystemColor.accentGradientTop,
                   ending: DemoSystemColor.accent)?.draw(in: path, angle: -90)
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

        let pill = DemoPillView(radius: 5, fill: isSelected ? DemoSystemColor.accent : .clear)
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
    func addTimeline(on host: DemoMockView) {
        let end = host.timelineDuration
        let off = Self.offTrackColor.cgColor, on = DemoSystemColor.accent.cgColor
        layer?.add(host.keyframes("backgroundColor", [
            (0, off), (DemoBeat.pressEnd, off), (DemoBeat.changeEnd, on),
            (DemoBeat.holdEnd, on), (DemoBeat.resetEnd, off), (end, off),
        ]), forKey: "tint")

        let offCentre = NSValue(point: CGPoint(x: knobFrame(on: false).midX,
                                              y: knobFrame(on: false).midY))
        let onCentre = NSValue(point: CGPoint(x: knobFrame(on: true).midX,
                                             y: knobFrame(on: true).midY))
        knobLayer.add(host.keyframes("position", [
            (0, offCentre), (DemoBeat.pressEnd, offCentre), (DemoBeat.changeEnd, onCentre),
            (DemoBeat.holdEnd, onCentre), (DemoBeat.resetEnd, offCentre), (end, offCentre),
        ]), forKey: Self.knobAnimationKey)
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
        layer?.backgroundColor = (isOn ? DemoSystemColor.accent : Self.offTrackColor).cgColor
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

/// One row of the grouped list: either the Audiouter row (real icon, real name,
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
            // Settings shows the app's REAL icon beside its name, and so does
            // this row.
            let icon = NSImageView()
            icon.image = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
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

    init(width: CGFloat, fill: NSColor = .tertiaryLabelColor) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = 1.5
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 3),
        ])
        self.fill = fill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var fill: NSColor = .tertiaryLabelColor

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = 1.5
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
/// pointer legible over the accent-filled default button.
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
}

// MARK: - Small helper

extension NSView {
    /// Every descendant, for the "re-stamp resolved colours" sweep.
    var subviewsRecursively: [NSView] { subviews + subviews.flatMap(\.subviewsRecursively) }
}
