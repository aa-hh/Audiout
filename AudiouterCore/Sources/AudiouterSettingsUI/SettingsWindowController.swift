// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// The Settings window (the header gear's destination — previously a `// TODO:
/// settings` stub).
///
/// **One screen, not tabs** (design revision 2026-07-17 — ahh: "this feels
/// like it should maybe just be one screen at the moment"): with three
/// single-control sections, a tab bar was pure navigation overhead, and it was
/// also the proximate cause of a real bug — see below. General / Appearance /
/// Audio now render as bold-labeled sections stacked in one scrolling-free
/// column, divided by hairlines, in a single fixed-size window. Each section
/// keeps its own `NSViewController` (`GeneralSettingsViewController`, etc.) so
/// re-splitting into tabs later (if a section grows enough to want its own
/// screen) only touches this file, not the sections themselves.
///
/// **The sizing bug this replaced:** the previous `NSTabViewController` build
/// called `NSWindow(contentViewController: tabController)` *before* any tabs
/// were added (`addTab` ran after `super.init`), so the window's initial size
/// was AppKit's fallback for an empty, content-less tab controller — much
/// larger than any real pane. `setFrameAutosaveName` then persisted that
/// oversized frame, and nothing ever forced a correct resize afterward (unlike
/// the popover, which explicitly recomputes its size before every show via
/// `panelContentDidChangeHeight`). The result: a mostly-empty giant window on
/// every tab, every launch. The fix here has the same shape as the popover's:
/// ``showWindow()`` explicitly measures the assembled content and calls
/// `setContentSize` immediately before every show, so no stale saved frame (or
/// AppKit fallback) can ever stick.
///
/// Sibling to `MixerWindowController`: same lazy-create-then-reuse lifecycle
/// at the call site, a no-arg `showWindow()`, and `test_` structure hooks (the
/// window isn't visible to a headless harness).
@MainActor
public final class SettingsWindowController: NSWindowController {

    private let rootVC: SettingsRootViewController
    private let generalVC: GeneralSettingsViewController
    private let appearanceVC: AppearanceSettingsViewController
    private let audioVC: AudioSettingsViewController

    /// Forwarded from the Appearance section: fired when the user changes the
    /// theme so the app can apply it app-wide (`NSApp.appearance`).
    public var onThemeChanged: ((AppearanceTheme) -> Void)? {
        get { appearanceVC.onThemeChanged }
        set { appearanceVC.onThemeChanged = newValue }
    }

    /// Forwarded from the Audio section: fired when the excluded-apps list
    /// changes so the app can enforce the "excluded ⇒ un-routable" precedence
    /// (prune routes) and refresh the popover.
    public var onExcludedAppsChanged: (() -> Void)? {
        get { audioVC.onChange }
        set { audioVC.onChange = newValue }
    }

    /// Forwarded from the General section: fired when "Run Setup Again…" is
    /// clicked so the app can re-present the first-run onboarding flow.
    public var onRunSetupAgain: (() -> Void)? {
        get { generalVC.onRunSetupAgain }
        set { generalVC.onRunSetupAgain = newValue }
    }

    /// - Parameters:
    ///   - settings: the scalar preference store (theme lives here).
    ///   - loginItem: the launch-at-login seam; defaults to the real
    ///     `SMAppService` impl, injected as a fake in tests.
    ///   - excludedApps: the excluded-apps denylist model (Audio section);
    ///     defaults to the on-disk store, injected over a temp store in tests.
    ///   - runningAppsProvider: candidate list for the Audio "Add application…"
    ///     picker; defaults to the real running apps, injected as a fixed list in
    ///     tests.
    ///   - latency: the Advanced › Audio buffer model (PLAN-LATENCY-SETTING.md);
    ///     nil (the default) when the backend isn't `LatencyConfigurable`, in
    ///     which case the Audio section renders no Advanced sub-section at all.
    public init(settings: AppSettings,
                loginItem: LoginItemManaging = SMAppServiceLoginItem(),
                excludedApps: ExcludedAppsController = ExcludedAppsController(),
                runningAppsProvider: @escaping () -> [AppPickerItem] = RunningApps.regularRunningApps,
                latency: LatencySettingModel? = nil,
                wakeRestore: WakeAudioRestoreModel? = nil) {
        generalVC = GeneralSettingsViewController(loginItem: loginItem)
        appearanceVC = AppearanceSettingsViewController(settings: settings)
        audioVC = AudioSettingsViewController(excluded: excludedApps,
                                              runningAppsProvider: runningAppsProvider,
                                              latency: latency,
                                              wakeRestore: wakeRestore)
        rootVC = SettingsRootViewController(sections: [
            ("General", generalVC),
            ("Appearance", appearanceVC),
            ("Audio", audioVC),
        ])

        let window = NSWindow(contentViewController: rootVC)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Settings"
        window.setFrameAutosaveName("SettingsWindow")
        // No forced `NSAppearance` — the app applies the theme override on
        // `NSApp`, and this window inherits it like everything else.

        super.init(window: window)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Open/focus the window (mirrors `MixerWindowController.showWindow()`).
    /// Explicitly re-measures and applies the content size on every call — see
    /// the sizing-bug note on the type — so a stale autosaved frame can never
    /// leave stray empty space below the content.
    public func showWindow() {
        // Sizing always runs headlessly too — `testContentSizeIsFittedNotDegenerate`
        // depends on it. Only the actual on-screen presentation is gated: never
        // order a real window on screen under `swift test`/a headless tool
        // (`HeadlessRuntime`) — those hold a real WindowServer connection, so an
        // un-gated order-front here would flash a real, empty window on the
        // developer's actual screen.
        rootVC.view.layoutSubtreeIfNeeded()
        window?.setContentSize(rootVC.view.fittingSize)
        guard !HeadlessRuntime.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The content view controller set as the window's `contentViewController`
    /// (`rootVC`) — exposed so the shared control-panel shell
    /// (`AudiouterSharedUI.ControlPanelWindowController`) can host this same
    /// assembled content inside its own panel later, without this controller
    /// creating a second copy of the sections. Does not affect the existing
    /// window path: `showWindow()`/`window` are unchanged, and this accessor
    /// is purely additive.
    public var settingsContentViewController: NSViewController { rootVC }

    // MARK: Test-support hooks

    public var test_general: GeneralSettingsViewController { generalVC }
    public var test_appearance: AppearanceSettingsViewController { appearanceVC }
    public var test_audio: AudioSettingsViewController { audioVC }

    /// The assembled single-screen content's fitting size — the same value
    /// `showWindow()` applies via `setContentSize`. Lets a test assert sizing is
    /// deterministic and non-degenerate without a live window.
    public var test_contentFittingSize: NSSize {
        rootVC.view.layoutSubtreeIfNeeded()
        return rootVC.view.fittingSize
    }

    /// The section header labels, in order (structural sanity check that all
    /// three sections mounted — the single-screen replacement for the old
    /// `test_tabLabels`).
    public var test_sectionTitles: [String] { rootVC.sectionTitles }

    /// The assembled single-screen content view, laid out (for offscreen
    /// snapshot rendering — mirrors `PopoverController.test_panelView`; the
    /// window isn't visible to an agent shell).
    public var test_rootView: NSView {
        rootVC.view.layoutSubtreeIfNeeded()
        return rootVC.view
    }
}

/// The single-screen content: `(title, viewController)` pairs stacked
/// vertically as **bold label → that section's view → hairline divider**,
/// fixed at `SettingsForm.contentWidth`. Each section view controller is added
/// as a proper child (`addChild`) so its own lifecycle events fire normally.
@MainActor
final class SettingsRootViewController: NSViewController {

    private let sections: [(title: String, viewController: NSViewController)]

    init(sections: [(title: String, viewController: NSViewController)]) {
        self.sections = sections
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var sectionTitles: [String] { sections.map(\.title) }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)

        for (index, section) in sections.enumerated() {
            addChild(section.viewController)
            let header = SettingsForm.sectionHeaderLabel(section.title)
            stack.addArrangedSubview(header)
            stack.addArrangedSubview(section.viewController.view)
            stack.setCustomSpacing(6, after: header)
            if index < sections.count - 1 {
                let divider = SettingsForm.divider()
                stack.addArrangedSubview(divider)
                stack.setCustomSpacing(16, after: section.viewController.view)
                stack.setCustomSpacing(16, after: divider)
            }
        }

        stack.widthAnchor.constraint(equalToConstant: SettingsForm.contentWidth).isActive = true

        // An explicit opaque, appearance-adaptive background — matching the
        // popover's own `PopoverPanelViewController`/`CardView` convention of
        // never relying on the ambient window fill. Confirmed necessary by
        // rendering this in dark mode (`settings-snapshot`): without it, child
        // controls draw with dark-adapted (light) text/colors over whatever
        // happens to sit behind the window, which is illegible.
        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        view = background
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }
}
