// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

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
    /// Every permission is in — a calm resting state, no loop.
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
/// snapshot fixtures always capture the settled frame.
///
/// The demo is DECORATIVE: it is excluded from the accessibility tree entirely
/// (the card copy beside it carries every word of the information). Only Replay,
/// a real control, stays accessible.
final class DemoPaneView: NSView {

    /// The elevated surface both mocks sit on — fixed, so consecutive steps
    /// read at the same scale rather than the pane resizing under the user.
    ///
    /// Square since the permission dialog became a portrait card (macOS 26):
    /// 336 is the prompt mock's 288 plus the margin the mock had before, so the
    /// dialog sits ON the surface rather than filling it edge to edge. The
    /// 820 × 560 window leaves 516 pt of pane height, so this still clears the
    /// Replay button underneath it with room to spare.
    static let surfaceSize = NSSize(width: 336, height: 336)

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
        // Remote Control's FIRST ask isn't the privacy card at all: it raises
        // the Accessibility ALERT, and that alert's own button is what opens the
        // pane — two surfaces, two clicks, so its first ask plays both. Every
        // other step's first ask really is the one-surface privacy dialog.
        case .prompt:
            switch step {
            case .remoteControl: return DemoSettingsHandoffMockView(step: step)
            default:             return DemoPromptMockView(step: step)
            }
        // Every retry lands on the pane itself — Remote Control's included, now
        // that its second click deep-links there, and Speaker Sync's, whose
        // "Open Login Items…" opens System Settings directly.
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
    /// Which surface a two-stage mock RESTS on; `nil` for the mocks that only
    /// ever have one. What it pins is the settled frame — a two-stage pass must
    /// rest on the FIRST thing the user will meet, not on the pane it ends at.
    var test_stage: DemoStage? { (mock as? DemoSettingsHandoffMockView)?.test_stage }
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
    /// Sidebar fill — darker than the content pane in BOTH appearances.
    static let sidebar = dynamic(light: 0xE8E8E8, dark: 0x232326)
    /// Content-pane fill.
    static let contentPane = dynamic(light: 0xF4F4F4, dark: 0x2C2C2E)
    /// The grouped list's fill. Real Settings draws the card within one level of
    /// the pane and defines it by its border alone; at mock scale that vanishes,
    /// so this is lifted ~2.5 % — a readability adjustment, not a measurement.
    static let card = dynamic(light: 0xFAFAFA, dark: 0x333336)
    /// A dialog button — BOTH of them: macOS 26's permission dialog has no
    /// accent-filled default. `controlColor` is white-ish in light mode, which
    /// is the SHEET's Cancel button, not a dialog's grey one.
    static let plainButton = dynamic(light: 0xD7D7D7, dark: 0x5A5A5E)

    /// The privacy padlock's gold, top and bottom of its gradient. The same in
    /// both appearances — macOS draws this icon as artwork, not as a tinted
    /// glyph, so it does not re-resolve with the theme. Matched by eye to the
    /// real Accessibility Access alert.
    static let lockGoldTop = solid(0xF9D45C)
    static let lockGoldBottom = solid(0xD79A24)

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

/// A wrapping, LEFT-aligned block of dialog text. Every mock's title and body
/// are real sentences at real sizes — the recognisability of these miniatures is
/// the whole reason they exist, so nothing a user reads is greeked or clipped.
func demoParagraph(_ text: String, font: NSFont, color: NSColor,
                   width: CGFloat) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    field.alignment = .left
    field.maximumNumberOfLines = 0
    field.lineBreakMode = .byWordWrapping
    field.preferredMaxLayoutWidth = width
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
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

// MARK: - Prompt mock

/// A miniature of the macOS 26 privacy dialog for one step — with a drawn cursor
/// gliding to the confirming button, pressing it, and the dialog settling into
/// its granted state.
///
/// **The anatomy is the point.** A dialog the user doesn't recognise is worth
/// nothing, and every part below is one the real one is identified by. A tall
/// portrait card, everything LEFT-aligned under an icon row:
///
/// 1. an icon tile — the app's own for a content-capture grant, a blue system
///    tile for a capability grant (see ``iconView(for:)``) — with the blue
///    `hand.raised.fill` badge overlapping its bottom-trailing corner, the
///    marker that says *privacy prompt*;
/// 2. a small grey Help button in the opposite corner;
/// 3. the bold title, wrapping over two or three lines;
/// 4. the app's own Info.plist purpose string as the body, in
///    `secondaryLabelColor`;
/// 5. two EQUAL, NEUTRAL capsules filling the width — there is no accent-filled
///    default button in this dialog any more.
///
/// Drawn at ~0.85 of the real 283 × 340 pt card: the closest to life size that
/// leaves the whole thing, at real proportions, inside the pane's fixed surface.
/// Nothing is greeked — the purpose string is the sentence the user will
/// actually read, so it is the one thing the mock cannot fake.
final class DemoPromptMockView: DemoMockView {

    static let size = NSSize(width: 240, height: 288)
    /// Content inset on all four sides.
    private static let inset: CGFloat = 16
    private static let iconSide: CGFloat = 56
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
        let badge = DemoDotView(diameter: Self.badgeSide, fill: DemoSystemColor.accent)
        let badgeGlyph = demoGlyph("hand.raised.fill", pointSize: 9,
                                   weight: .semibold, color: .white)

        let help = DemoDotView(diameter: Self.helpSide, fill: .quaternaryLabelColor)
        let helpGlyph = demoGlyph("questionmark", pointSize: 9,
                                  weight: .semibold, color: .secondaryLabelColor)

        // The real dialog's 15 pt title, taken down by this mock's scale and
        // rounded UP rather than down — these two blocks are the only things in
        // here the user actually reads, and the 9 pt floor is a floor, not a
        // target.
        let title = demoParagraph(Self.askText(for: step),
                                  font: .boldSystemFont(ofSize: 14),
                                  color: .labelColor, width: Self.contentWidth)
        let body = demoParagraph(Self.bodyText(for: step),
                                 font: .systemFont(ofSize: 11),
                                 color: .secondaryLabelColor, width: Self.contentWidth)

        // Two EQUAL neutral capsules filling the content width: refusal on the
        // left, the confirming one on the right.
        let deny = DemoPushButtonView(title: "Don't Allow")
        confirmButton = DemoPushButtonView(title: Self.confirmTitle(for: step))
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

    /// The tile in the dialog's top-left corner. macOS does NOT always put the
    /// asking app's icon there: the app's own icon appears for the grants that
    /// are about capturing that app's content (System Audio), while the
    /// CAPABILITY grants show a generic SYSTEM tile — the same one for every
    /// app. Verified from the real Local Network dialog, which draws the
    /// Network pane's blue globe rather than Audiouter's icon. The badge, the
    /// size and the slot are identical either way; only the tile's contents
    /// change.
    private static func iconView(for step: SetupStep) -> NSView {
        switch step {
        case .localNetwork:
            return systemTile(symbol: "network")
        // razor: a NAMED APPROXIMATION on two counts — no screenshot of the
        // real Bluetooth dialog was available, so the system tile is inferred
        // from Local Network's; and SF Symbols carries no Bluetooth rune, so
        // the glyph is the `dot.radiowaves.right` the Bluetooth setup card
        // beside it already uses. Upgrade path: a real screenshot, or a rune
        // symbol, changes this one line.
        case .bluetooth:
            return systemTile(symbol: "dot.radiowaves.right")
        // System Audio is a content-capture grant and really does show the
        // app's icon. The other two never reach this mock; the app icon is the
        // safe default for them.
        case .audio, .remoteControl, .speakerSync:
            let icon = NSImageView()
            icon.image = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            return icon
        }
    }

    /// A macOS system-pane tile: a blue rounded square carrying one white
    /// glyph, drawn at the app icon's size so the badge lands where it always
    /// does. Corner and glyph are fractions of the side rather than points, so
    /// changing `iconSide` alone keeps the tile in proportion; both are matched
    /// by eye to the Local Network screenshot, not measured.
    private static func systemTile(symbol: String) -> NSView {
        let tile = DemoPillView(radius: iconSide * 0.23, fill: DemoSystemColor.accent)
        let mark = demoGlyph(symbol, pointSize: iconSide * 0.55, weight: .regular, color: .white)
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

    /// The dialog's TITLE, per step — quoted app name, sentence case, full stop.
    /// It wraps on its own now that the layout is left-aligned; a hard line
    /// break would fight the wrap at any other text size.
    static func askText(for step: SetupStep) -> String {
        switch step {
        // Verbatim, because macOS composes this one from the permission itself
        // and the owner checked it against the real dialog.
        case .audio:         return "“Audiouter” would like access to record your system audio."
        // Local Network is the odd one out: macOS phrases it as a QUESTION
        // opening on "Allow", not the "would like to…" pattern. Verbatim from
        // the real dialog.
        case .localNetwork:  return "Allow “Audiouter” to find devices on local networks?"
        case .bluetooth:     return "“Audiouter” would like to use Bluetooth."
        // Neither of these reaches this mock: Remote Control raises the system
        // ALERT (``DemoSystemAlertMockView``), which words its own ask, and
        // Speaker Sync has no prompt at all. Kept so the table stays exhaustive
        // and readable.
        case .remoteControl: return "“Audiouter” would like to control this Mac."
        case .speakerSync:   return "“Audiouter” would like to run in the background."
        }
    }

    /// The dialog's BODY: the app's own purpose string, which is exactly what
    /// macOS puts in the dialog — not a paraphrase. The first three are
    /// word-for-word the `*_USAGE` strings `scripts/make-app.sh` stamps into the
    /// bundle's Info.plist; change one there and change it here, because this
    /// sentence is what the user reads before deciding. The last two have no
    /// Info.plist string to quote (Accessibility's wording is the OS's own, and
    /// Login Items has no dialog at all), so they are a likeness.
    static func bodyText(for step: SetupStep) -> String {
        switch step {
        case .audio:
            return "Audiouter needs to capture your Mac's audio so it can send it to the "
                + "AirPlay speakers you choose. Audio goes only to those speakers — it is "
                + "never recorded, saved, or sent anywhere else."
        case .localNetwork:
            return "Audiouter looks for AirPlay speakers on your local network so you can "
                + "play your Mac's audio to them. It only finds speakers — it doesn't read "
                + "or collect anything else about your network."
        case .bluetooth:
            return "Audiouter connects to Bluetooth speakers you've already paired so it can "
                + "play your Mac's audio on them. It only reaches speakers you choose — it "
                + "never scans for or reads anything else."
        case .remoteControl:
            return "Audiouter needs to control this Mac so the keys on your keyboard can "
                + "start, pause and skip what is playing. It watches for those keys and "
                + "nothing else."
        case .speakerSync:
            return "Audiouter runs a small background helper that keeps your speakers in "
                + "step with each other. It starts with your Mac and does nothing else."
        }
    }

    /// The button the cursor presses.
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
/// 2. a plain (not bold) header line naming the access being asked for;
/// 3. a full-bleed hairline DIVIDER under it — the one structural element the
///    privacy card has nothing like, and the fastest way to tell them apart;
/// 4. a two-column body, gold privacy PADLOCK left and text right, the two
///    centred against each other as a group;
/// 5. a Help circle bottom-LEFT, and two buttons bottom-RIGHT of which the
///    REFUSAL is the accent-filled default — the opposite emphasis from the
///    card's two equal neutral capsules, and the reason the demo's pointer goes
///    for the quiet button.
///
/// It is a passive SURFACE, not a timeline: it draws itself and exposes the
/// button a pointer should press, while the host two-stage mock owns the one
/// cursor and the crossfade — a stage that owned a cursor would put a second
/// pointer on screen.
final class DemoSystemAlertMockView: NSView {

    /// Fixed width; the HEIGHT comes from the copy, so a longer sentence sits
    /// taller instead of being clipped by a magic number. 288 leaves shadow room
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
    /// The button the demo's pointer presses — deliberately NOT the accent-filled
    /// one. The real alert makes "Deny" the default, so the button that actually
    /// moves the user forward is the quiet one, and the mock has to say so.
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

        let header = NSTextField(labelWithString: Self.headerText(for: step))
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .labelColor
        header.lineBreakMode = .byTruncatingTail
        header.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let icon = DemoLockIconView()
        let ask = demoParagraph(Self.askText(for: step), font: .boldSystemFont(ofSize: 11),
                                color: .labelColor, width: Self.textWidth)
        let body = demoParagraph(Self.bodyText(for: step), font: .systemFont(ofSize: 10),
                                 color: .secondaryLabelColor, width: Self.textWidth)
        let text = NSStackView(views: [ask, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5
        text.translatesAutoresizingMaskIntoConstraints = false

        let help = DemoDotView(diameter: Self.helpSide, fill: .quaternaryLabelColor)
        let helpGlyph = demoGlyph("questionmark", pointSize: 9,
                                  weight: .semibold, color: .secondaryLabelColor)

        pressTarget = DemoPushButtonView(title: "Open System Settings",
                                         height: Self.buttonHeight,
                                         cornerRadius: Self.buttonRadius)
        let deny = DemoPushButtonView(title: "Deny", emphasis: .accent,
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

    // MARK: Copy

    /// The header line — the ACCESS being asked for, which is how macOS titles
    /// these panels ("Accessibility Access"). Only Remote Control ever raises
    /// this alert; the rest fall back to the name of their own pane.
    static func headerText(for step: SetupStep) -> String {
        switch step {
        case .remoteControl: return "Accessibility Access"
        case .audio, .localNetwork, .bluetooth, .speakerSync:
            return DemoSettingsMockView.paneTitle(for: step)
        }
    }

    /// The bold first line. Verbatim from the real Accessibility panel, with the
    /// same quoted app-name placeholder every other mock's copy uses.
    static func askText(for step: SetupStep) -> String {
        switch step {
        case .remoteControl:
            return "“Audiouter” would like to control this computer using accessibility features."
        case .audio, .localNetwork, .bluetooth, .speakerSync:
            return DemoPromptMockView.askText(for: step)
        }
    }

    /// The instruction under it: where the grant actually gets made. Verbatim
    /// from the real Accessibility panel.
    static func bodyText(for step: SetupStep) -> String {
        "Grant access to this application in Privacy & Security settings, "
            + "located in System Settings."
    }

    /// The blue circular badge overlapping the padlock, if this step has one.
    ///
    /// Accessibility's is the accessibility figure — the badge is what says
    /// WHICH capability the padlock is standing for. No other step raises this
    /// alert, so no other step earns a marker.
    private static func badge(for step: SetupStep) -> (circle: NSView, glyph: NSView)? {
        guard step == .remoteControl else { return nil }
        return (DemoDotView(diameter: badgeSide, fill: DemoSystemColor.accent),
                demoGlyph("accessibility", pointSize: 9, weight: .semibold, color: .white))
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

    /// Where the pointer waits: low in the content pane, clear of the title and
    /// the card's first row — a cursor sitting on top of text read as a mistake.
    private let cursorPark = CGPoint(x: 110, y: 138)

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

            cursor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: cursorPark.x),
            cursor.topAnchor.constraint(equalTo: topAnchor, constant: cursorPark.y),
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
        }
    }
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
/// flipping the Audiouter toggle on. Stage two is the mock every other step
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

/// How a drawn dialog button is filled.
enum DemoButtonEmphasis {
    /// The neutral grey both of the privacy dialog's buttons wear, and the one
    /// the system alert's "Open System Settings" wears.
    case neutral
    /// Accent-filled with a white title — the alert's DEFAULT button, which on
    /// the Accessibility panel is the refusal.
    case accent
}

/// A drawn dialog button.
///
/// Two shapes, because the two surfaces this file mimics genuinely differ: the
/// macOS 26 privacy dialog's are full CAPSULES and both the same grey (Liquid
/// Glass has no accent-filled default there, and painting one would send the
/// user looking for a blue button that won't be there), while the older system
/// ALERT panel's are shorter rounded rects with an accent-filled default. The
/// defaults here are the capsule, so the privacy dialog's call sites say
/// nothing extra.
final class DemoPushButtonView: NSView {

    static let height: CGFloat = 28
    /// Air either side of the label.
    private static let labelInset: CGFloat = 10

    private let emphasis: DemoButtonEmphasis
    private let cornerRadius: CGFloat

    init(title: String,
         emphasis: DemoButtonEmphasis = .neutral,
         height: CGFloat = DemoPushButtonView.height,
         cornerRadius: CGFloat? = nil) {
        self.emphasis = emphasis
        self.cornerRadius = cornerRadius ?? height / 2
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.textColor = emphasis == .accent ? .white : .labelColor
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
        layer?.backgroundColor = (emphasis == .accent ? DemoSystemColor.accent
                                                      : DemoSystemColor.plainButton).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }
}

/// The gold privacy PADLOCK the system alert leads with.
///
/// `lock.fill` filled with a warm vertical gradient rather than a flat tint: the
/// real icon is artwork with a little dimension in it, and a flat amber SF
/// Symbol at this size reads as a toolbar glyph instead. The symbol IS the mask,
/// so there is no second drawn shape to keep in step with it.
///
/// **TRAP: the mask has to be built in an image of its own.** Painting the
/// gradient `.sourceAtop` straight into `draw(_:)` does not clip to the symbol —
/// the view's backing store is not the empty destination that composite mode
/// needs, and the whole icon rect comes out solid gold. Drawing the gradient
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

        let gold = NSImage(size: drawn.size, flipped: false) { rect in
            // Negative angle so the LIGHTER gold is at the top, as it is on the
            // real icon.
            NSGradient(starting: DemoSystemColor.lockGoldTop,
                       ending: DemoSystemColor.lockGoldBottom)?.draw(in: rect, angle: -90)
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        gold.draw(in: drawn)
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
    /// A staged host (Remote Control's handoff) shifts this score through its
    /// ``DemoMockView/stageWindow``, so there is nothing per-stage in here.
    func addTimeline(on host: DemoMockView) {
        let off = Self.offTrackColor.cgColor, on = DemoSystemColor.accent.cgColor
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
}
