// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI
import AudiouterSettingsUI

/// The three screens the one-surface app hosts (U3, PLAN-ONE-SURFACE-032).
/// `Int`-raw so the header's tab buttons can carry a screen in `NSButton.tag`.
public enum SurfaceScreen: Int, CaseIterable, Sendable {
    case mixer, groups, settings

    var label: String {
        switch self {
        case .mixer: return "Mixer"
        case .groups: return "Groups"
        case .settings: return "Settings"
        }
    }

    /// Tab glyphs (plan U3). All three resolve on the macOS 14 deployment
    /// target (verified on this box; each is a macOS 11-era symbol).
    var symbolName: String {
        switch self {
        case .mixer: return "slider.horizontal.3"
        case .groups: return "hifispeaker.2"
        case .settings: return "gearshape"
        }
    }

    /// Defense-in-depth fallbacks so a tab is never glyph-less (the previous
    /// header's idiom); ordered nearest-meaning first.
    var fallbackSymbolNames: [String] {
        switch self {
        case .mixer: return ["slider.horizontal.below.rectangle", "dial.min"]
        case .groups: return ["hifispeaker.2.fill", "hifispeaker"]
        case .settings: return ["gearshape.fill", "gear"]
        }
    }

    /// ⌘1 / ⌘2 / ⌘3, in tab order.
    var keyEquivalent: String { String(rawValue + 1) }
}

/// The one-surface host (U3): owns ONE `ControlPanelWindowController` shell and
/// the three lazily-built screens behind the header's tab-bar switcher —
///
/// - **Mixer** — the real `PopoverController` panel, claimed through
///   `claimPanelForSurfaceHosting()` and driven through the U2
///   host-agnostic seams: `surfaceDidShow()`/`surfaceDidHide()` on window
///   show/hide/switch, and a `surfaceResizer` that animates the SHELL to the
///   panel's exact-fit `preferredContentSize` (the existing
///   `panelContentDidChangeHeight` channel — Mixer is always exact-fit).
/// - **Groups** — the caller-provided content controller
///   (`MixerWindowController.contentController` in the app), seated below a
///   header strip in a `SurfaceScreenViewController`. Fixed default
///   560×516 — the split view's real minimum, measured in the prototype (the
///   plan's 505 is too short) — and the one screen whose user-dragged size is
///   remembered for the session (the shell's own drag-holds philosophy).
/// - **Settings** — a caller-provided `SettingsRootViewController` (in-content
///   tabs, so they render beneath the switcher), same container. Per-tab
///   height rides `onFittedContentSizeChange`, which THIS controller takes
///   over (R5: the standalone Settings window's four sizing traps transfer to
///   whoever hosts these panes — the re-measure triggers live in the root
///   controller and keep firing here).
///
/// Every swap routes through the shell's `setContent` (R3 — assigning
/// `contentViewController` directly snaps the window to a 500×500 fallback).
/// Sizes are applied top-anchored (the surface grows downward from the menu
/// bar) and, unpinned, re-centered on the status-item anchor.
///
/// **Pin** drives U1's `setPinned(_:)` manner flip and persists in
/// `AppSettings.surfacePinned` (restored at construction). Pinned mode's real
/// title bar overlaps the content (`.fullSizeContentView` never leaves the
/// style mask — R6), so each screen's header takes a measured chrome inset
/// rather than a hardcoded title-bar height.
///
/// Lives in AudiouterPopoverUI (a library) because `AudiouterApp` is invisible
/// to the test target (R9) — which is also why the menu-bar click policy
/// (`clickAction(setupIsOpen:)`, U4) is decided here and merely performed by
/// the app.
@MainActor
public final class AppSurfaceController {

    /// The one window shell. Public so the app's click policy (U4) can compose
    /// with `isPanelVisible` / `consumeRecentResignDismissal(within:)`.
    public let shell: ControlPanelWindowController

    private let popoverController: PopoverController
    private let settings: AppSettings
    /// Lazily builds the Groups content the FIRST time the Groups tab is
    /// selected (`MixerWindowController.contentController` in the app — the
    /// surface must not construct window controllers itself).
    private let makeGroupsContent: () -> NSViewController
    /// Lazily builds the Settings root the FIRST time the Settings tab is
    /// selected. The surface takes over the returned controller's
    /// `onFittedContentSizeChange` — don't hand it one whose callback
    /// something else still needs.
    private let makeSettingsContent: () -> SettingsRootViewController

    /// The Mixer panel, once claimed from its controller (lazy — claiming
    /// also rewires the header and installs the resize hook, so it only
    /// happens when the surface actually hosts the Mixer).
    private var mixerPanel: PopoverPanelViewController?
    private var groupsScreen: SurfaceScreenViewController?
    private var settingsScreen: SurfaceScreenViewController?
    private var settingsRoot: SettingsRootViewController?

    public private(set) var selectedScreen: SurfaceScreen = .mixer

    /// Whether the surface window is currently presented (show → close). The
    /// Mixer's `surfaceDidShow`/`surfaceDidHide` lifecycle keys off this so
    /// metering/monitors only run while a user can see the panel.
    public private(set) var isShown = false

    /// The status-item anchor `show(anchorRect:)` last received — unpinned
    /// resizes re-center on it so the beak keeps pointing at the status item
    /// across per-screen width changes.
    private var lastAnchorRect: NSRect?

    /// The Groups screen's session size memory: captured when switching away,
    /// so a user-dragged Groups size survives Mixer/Settings round-trips.
    /// Never persisted (matches the shell's process-lifetime drag memory).
    private var rememberedGroupsFrameSize: NSSize?

    /// Fired after the shell window really closes (✕ / Esc / `performClose`).
    public var onClose: (() -> Void)?

    /// Fired whenever the screen a user can actually SEE changes — a tab
    /// switch, a show, or a close (`nil` = nothing is on screen). Screen
    /// content that skips work while hidden (the Groups content's B8 gate)
    /// hangs off this; the Mixer needs no subscriber because the surface
    /// drives its `surfaceDidShow`/`surfaceDidHide` pair directly.
    public var onVisibleScreenChange: ((SurfaceScreen?) -> Void)?

    /// The last value `onVisibleScreenChange` published, so a no-op transition
    /// (selecting the screen already selected, showing an already-shown
    /// surface) never re-announces.
    private var publishedVisibleScreen: SurfaceScreen?

    /// Groups' default content size: the split view's real minimum, measured
    /// in the runnable prototype (560×505 per the plan is below the split
    /// view's floor and it fights back — 516 is where it settles).
    public static let groupsDefaultContentSize = NSSize(width: 560, height: 516)

    /// The Mixer panel's width is fixed (623); height is always exact-fit, so
    /// this seed only positions the very first mount before the fit lands.
    static let mixerSeedContentSize = NSSize(width: 623, height: 623)

    public init(popoverController: PopoverController,
                settings: AppSettings = AppSettings(),
                groupsContent: @escaping () -> NSViewController,
                settingsContent: @escaping () -> SettingsRootViewController,
                frameAutosaveName: NSWindow.FrameAutosaveName = "ControlPanelSurface") {
        self.popoverController = popoverController
        self.settings = settings
        self.makeGroupsContent = groupsContent
        self.makeSettingsContent = settingsContent
        self.shell = ControlPanelWindowController(title: "Audiouter",
                                                  frameAutosaveName: frameAutosaveName)
        // Restore the persisted pin BEFORE anything is on screen: `setPinned`
        // only re-anchors a visible panel, so this is a pure profile stamp.
        shell.setPinned(settings.surfacePinned)
        shell.onClose = { [weak self] in self?.handleShellClosed() }
    }

    // MARK: Show / hide

    /// Present the surface anchored under the status item (`nil` centers it;
    /// pinned mode fronts the window wherever the user left it — the shell
    /// owns that distinction). A FRESH show mounts the current screen first so
    /// the window appears at that screen's size with no visible jump; showing
    /// an ALREADY-shown surface (the pinned always-front click) only fronts it
    /// — re-running the Mixer's open ritual there would discard the user's
    /// mid-open collapse toggles for no reason (it is the same open session).
    public func show(anchorRect: NSRect?) {
        lastAnchorRect = anchorRect
        let wasShown = isShown
        if !wasShown {
            mount(selectedScreen, animated: false)
        }
        shell.show(anchorRect: anchorRect)
        isShown = true
        if !wasShown, selectedScreen == .mixer {
            popoverController.surfaceDidShow()
        }
        publishVisibleScreen()
    }

    /// Close through the shell's real-close path (`windowWillClose` →
    /// `handleShellClosed`), exactly as ✕/Esc would.
    public func performClose() { shell.performClose() }

    private func handleShellClosed() {
        if isShown, selectedScreen == .mixer {
            popoverController.surfaceDidHide()
        }
        isShown = false
        publishVisibleScreen()
        onClose?()
    }

    /// The screen a user can currently see, `nil` while the surface is closed.
    public var visibleScreen: SurfaceScreen? { isShown ? selectedScreen : nil }

    private func publishVisibleScreen() {
        let current = visibleScreen
        guard current != publishedVisibleScreen else { return }
        publishedVisibleScreen = current
        onVisibleScreenChange?(current)
    }

    // MARK: Screen switching

    /// Switch to `screen`: lazy-builds it on first visit, swaps it in through
    /// the shell's `setContent` (R3), animates the window to the screen's size
    /// (top edge anchored), and keeps every built header's tab state in sync.
    /// Selecting the current screen is a no-op.
    public func select(_ screen: SurfaceScreen) {
        guard screen != selectedScreen else { return }
        if selectedScreen == .groups {
            rememberedGroupsFrameSize = shell.window?.frame.size
        }
        if selectedScreen == .mixer, isShown {
            // The panel is leaving the window: drop what must not outlive a
            // session (transient selection, stale meter bars) and stop paying
            // for RMS while no meter is visible.
            popoverController.surfaceDidHide()
        }
        selectedScreen = screen
        syncHeaders()
        mount(screen, animated: isShown)
        if screen == .mixer, isShown {
            popoverController.surfaceDidShow()
        }
        publishVisibleScreen()
    }

    // MARK: Menu-bar click policy

    /// What a menu-bar click should do. Decided here rather than in
    /// `AppDelegate` so all four cases are directly testable (R9 — the app
    /// target is invisible to the test target).
    public enum ClickAction: Equatable, Sendable {
        /// Setup is open and owns the click: re-front it, never the surface.
        case refrontSetup
        /// Put the surface on screen — unpinned open, or a pinned surface the
        /// user closed (it reopens at its remembered frame).
        case show
        /// The pinned surface is already open, possibly behind another app:
        /// bring it forward, don't toggle it shut.
        case front
        /// The unpinned surface is open: this click closes it.
        case dismiss
        /// This click is the one that ALREADY dismissed the unpinned surface
        /// (it resigned key before the button action ran) — do nothing, or the
        /// surface can never be toggled shut from the menu bar.
        case ignore
    }

    /// Decide what the menu-bar click does. Pure — no side effects beyond
    /// consuming the shell's resign-dismissal stamp (which must be consumed on
    /// EVERY click, stale or fresh, so a leftover can't swallow a later one).
    /// The caller performs the result, which lets the app run its permission
    /// gates in between exactly where it always did.
    public func clickAction(setupIsOpen: Bool) -> ClickAction {
        if setupIsOpen { return .refrontSetup }
        let dismissedByThisClick = shell.consumeRecentResignDismissal()
        // Pinned is an ordinary window: it never self-dismisses, so a click is
        // only ever "front it" or "reopen it".
        if shell.isPinned { return shell.isPanelVisible ? .front : .show }
        if dismissedByThisClick { return .ignore }
        return shell.isPanelVisible ? .dismiss : .show
    }

    /// Carry out a `clickAction(setupIsOpen:)` result. `refrontSetup` is the
    /// app's to perform — Setup is not a surface screen.
    public func perform(_ action: ClickAction, anchorRect: NSRect?) {
        switch action {
        case .refrontSetup, .ignore: break
        case .dismiss: performClose()
        case .show, .front: show(anchorRect: anchorRect)
        }
    }

    /// Mount `screen` into the shell and drive it to its target size.
    ///
    /// `setContent` is deliberately bracketed by a frame save/restore: on a
    /// controller's FIRST mount it applies `defaultSize` by snapping the
    /// window, and on a re-host it restores the pre-swap size — either way the
    /// window should visibly END UP at the target via ONE animated resize, not
    /// jump-then-glide. So: capture the frame, swap content, put the frame
    /// back, then animate to the target (the prototype's proven dance).
    private func mount(_ screen: SurfaceScreen, animated: Bool) {
        let previousFrame = shell.window?.frame
        switch screen {
        case .mixer:
            let panel = claimedMixerPanel()
            // Re-ingest everything that arrived while the panel was hidden or
            // unmounted (hidden-means-idle, audit B8) and recompute collapse
            // defaults — the Mixer open ritual every host must perform.
            popoverController.rebuildForOpen()
            shell.setContent(panel, defaultSize: Self.mixerSeedContentSize)
            restoreFrameAfterSwap(previousFrame)
            // Exact fit through the panel's own documented size channel; the
            // surfaceResizer assigned at claim time turns it into the shell
            // resize (animated or snap).
            panel.panelContentDidChangeHeight(animated: animated)
        case .groups:
            let screenVC = builtGroupsScreen()
            shell.setContent(screenVC, defaultSize: groupsTargetContentSize())
            restoreFrameAfterSwap(previousFrame)
            applyWindowContentSize(groupsTargetContentSize(), animated: animated)
        case .settings:
            let screenVC = builtSettingsScreen()
            shell.setContent(screenVC, defaultSize: settingsTargetContentSize())
            restoreFrameAfterSwap(previousFrame)
            applyWindowContentSize(settingsTargetContentSize(), animated: animated)
        }
    }

    private func restoreFrameAfterSwap(_ frame: NSRect?) {
        guard let frame else { return }
        shell.window?.setFrame(frame, display: false)
    }

    // MARK: Lazy screens

    /// The Mixer panel, claimed from its controller on first use. Claiming
    /// also installs the surface's resize behavior and takes over the header's
    /// switcher wiring (pre-claim the Groups/Settings tabs forward through
    /// `onOpenMixer`/`onOpenSettings`; under the surface a tab IS the screen
    /// switch).
    private func claimedMixerPanel() -> PopoverPanelViewController {
        if let mixerPanel { return mixerPanel }
        let panel = popoverController.claimPanelForSurfaceHosting()
        mixerPanel = panel
        popoverController.surfaceResizer = { [weak self, weak panel] animated, apply in
            apply()
            guard let self, let panel else { return }
            self.applyWindowContentSize(panel.preferredContentSize, animated: animated)
        }
        wireHeader(panel.header)
        syncHeaders()
        return panel
    }

    private func builtGroupsScreen() -> SurfaceScreenViewController {
        if let groupsScreen { return groupsScreen }
        let screen = SurfaceScreenViewController(content: makeGroupsContent())
        wireHeader(screen.header)
        groupsScreen = screen
        syncHeaders()
        return screen
    }

    private func builtSettingsScreen() -> SurfaceScreenViewController {
        if let settingsScreen { return settingsScreen }
        let root = makeSettingsContent()
        settingsRoot = root
        // Re-measure trigger for a pane that grows at runtime and for tab
        // switches (R5 trigger 2+3 live inside SettingsRootViewController;
        // this is the surface-side subscriber the window controller used to be).
        root.onFittedContentSizeChange = { [weak self] _ in
            guard let self, self.selectedScreen == .settings else { return }
            self.applyWindowContentSize(self.settingsTargetContentSize(),
                                        animated: self.isShown)
        }
        let screen = SurfaceScreenViewController(content: root)
        wireHeader(screen.header)
        settingsScreen = screen
        syncHeaders()
        return screen
    }

    private func wireHeader(_ header: PopoverHeaderView) {
        header.onSelectScreen = { [weak self] in self?.select($0) }
        header.onTogglePin = { [weak self] in self?.togglePin() }
        header.onQuit = { NSApp.terminate(nil) }
    }

    private var builtHeaders: [PopoverHeaderView] {
        [mixerPanel?.header, groupsScreen?.header, settingsScreen?.header].compactMap { $0 }
    }

    private func syncHeaders() {
        for header in builtHeaders {
            header.setSelectedScreen(selectedScreen)
            header.setPinned(shell.isPinned)
        }
    }

    // MARK: Pin

    public var isPinned: Bool { shell.isPinned }

    public func togglePin() { setPinned(!shell.isPinned) }

    /// Flip the shell's manner profile (U1) and persist the choice. Also
    /// re-seats every screen's header below the pinned title bar (measured,
    /// not hardcoded) and re-applies the current screen's size, whose target
    /// height includes that chrome.
    public func setPinned(_ pinned: Bool) {
        guard pinned != shell.isPinned else { return }
        settings.surfacePinned = pinned
        shell.setPinned(pinned)
        syncHeaders()
        applyChromeTopInset()
        reapplyCurrentScreenSize()
    }

    /// Points of window chrome overlapping the content's top: the real title
    /// bar in PINNED mode (`.fullSizeContentView` keeps content under it —
    /// content must inset itself, per U1). Measured from the live window
    /// (`contentLayoutRect`), never a hardcoded 28. Unpinned is 0 BY DESIGN —
    /// the invisible title-bar strip only carries the floating close button,
    /// which the header's `closeButtonReserve` already clears.
    private var chromeTopInset: CGFloat {
        guard shell.isPinned, let window = shell.window,
              let contentView = window.contentView else { return 0 }
        return max(0, contentView.frame.height - window.contentLayoutRect.height)
    }

    private func applyChromeTopInset() {
        let inset = chromeTopInset
        mixerPanel?.setHeaderTopInset(inset)
        groupsScreen?.setHeaderTopInset(inset)
        settingsScreen?.setHeaderTopInset(inset)
    }

    private func reapplyCurrentScreenSize() {
        switch selectedScreen {
        case .mixer:
            // The inset changed the panel's fitting height; republish it.
            mixerPanel?.panelContentDidChangeHeight(animated: isShown)
        case .groups:
            applyWindowContentSize(groupsTargetContentSize(), animated: isShown)
        case .settings:
            applyWindowContentSize(settingsTargetContentSize(), animated: isShown)
        }
    }

    // MARK: Sizing

    private func groupsTargetContentSize() -> NSSize {
        if let remembered = rememberedGroupsFrameSize { return remembered }
        var size = Self.groupsDefaultContentSize
        size.height += chromeTopInset
        return size
    }

    private func settingsTargetContentSize() -> NSSize {
        guard let settingsRoot else { return Self.groupsDefaultContentSize }
        let fitted = settingsRoot.fittedContentSize
        return NSSize(width: fitted.width,
                      height: fitted.height + SurfaceScreenViewController.headerHeight
                              + chromeTopInset)
    }

    /// Resize the shell to `contentSize`, TOP edge anchored (the surface hangs
    /// from the menu bar and grows downward) and, unpinned, re-centered on the
    /// status-item anchor so the beak keeps pointing at it across per-screen
    /// width changes; pinned keeps the user's left edge. Clamped on screen
    /// with the shell's own 8pt margins. Snaps (no animation) under Reduce
    /// Motion and headless (`HeadlessRuntime` — `swift test` and the harness
    /// tools must never animate real window frames).
    private func applyWindowContentSize(_ contentSize: NSSize, animated: Bool) {
        guard let window = shell.window else { return }
        let frameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)).size
        var origin = NSPoint(x: window.frame.minX,
                             y: window.frame.maxY - frameSize.height)
        if !shell.isPinned, let anchor = lastAnchorRect {
            origin.x = (anchor.midX - frameSize.width / 2).rounded()
        }
        if let screen = window.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - frameSize.width - 8)
            origin.y = max(vf.minY + 8, origin.y)
        }
        let frame = NSRect(origin: origin, size: frameSize)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated || reduceMotion || HeadlessRuntime.isActive {
            window.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        }
    }

    // MARK: Test-support hooks

    /// The currently hosted content controller (what `setContent` mounted).
    public var test_hostedContentViewController: NSViewController? {
        shell.window?.contentViewController
    }
    /// The built screens' headers, for tier/tab-state assertions.
    var test_builtHeaders: [PopoverHeaderView] { builtHeaders }
    /// The lazily-built pieces, `nil` until their tab is first selected.
    var test_mixerPanel: PopoverPanelViewController? { mixerPanel }
    var test_groupsScreen: SurfaceScreenViewController? { groupsScreen }
    var test_settingsScreen: SurfaceScreenViewController? { settingsScreen }
    var test_settingsRoot: SettingsRootViewController? { settingsRoot }
    /// The chrome inset screens are currently seated below (0 unpinned).
    var test_chromeTopInset: CGFloat { chromeTopInset }
}

// MARK: - SurfaceScreenViewController

/// One surface screen for content that doesn't carry its own header strip
/// (Groups, Settings): the shared header pinned on top, the content
/// controller — a real CHILD view controller, so the responder chain and
/// appearance plumbing stay stock — seated BELOW it. (The Mixer panel is
/// hosted directly instead: its header lives inside the panel and its height
/// participates in the exact-fit measure.)
///
/// The root view paints NOTHING: the shell's backing bubble already fills the
/// live warm canvas behind transparent content (Warm Signal §5.4), and content
/// that paints its own background (Settings' visual-effect root) covers it —
/// both intended. Each screen is its own controller instance because the shell
/// keys size preservation on the hosted controller's identity.
@MainActor
final class SurfaceScreenViewController: NSViewController {

    /// The header strip's height — `PopoverHeaderView.barHeight`, re-exported
    /// so sizing math doesn't reach into the view class.
    static var headerHeight: CGFloat { PopoverHeaderView.barHeight }

    let header = PopoverHeaderView()
    let content: NSViewController
    private var headerTopConstraint: NSLayoutConstraint?

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        addChild(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 516))
        let contentView = content.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)
        root.addSubview(header)

        let headerTop = header.topAnchor.constraint(equalTo: root.topAnchor)
        headerTopConstraint = headerTop
        NSLayoutConstraint.activate([
            headerTop,
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            contentView.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Seat the header below the pinned title bar (0 unpinned). The content
    /// rides the header's bottom anchor, so it moves with it.
    func setHeaderTopInset(_ inset: CGFloat) {
        _ = view // ensure loadView ran so the constraint exists
        headerTopConstraint?.constant = inset
    }

    /// The current header inset, for structural tests.
    var test_headerTopInset: CGFloat { headerTopConstraint?.constant ?? 0 }
}
