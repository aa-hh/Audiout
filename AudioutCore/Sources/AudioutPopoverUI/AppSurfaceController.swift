// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI
import AudioutSettingsUI

/// The three screens the one-surface app hosts (U3, PLAN-ONE-SURFACE-032).
/// `Int`-raw so the toolbar's tab group can map a segment index to a screen.
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

    /// Defense-in-depth fallbacks so a tab is never glyph-less; ordered
    /// nearest-meaning first.
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

/// The one-surface host (U3): owns ONE `ControlPanelWindowController` shell,
/// the shell window's native toolbar header (`SurfaceToolbarController` —
/// owner decision D1, 2026-08-07: a real `NSToolbar` is the one header strip
/// in both manner profiles), and the three lazily-built screens behind the
/// toolbar's tab group —
///
/// - **Mixer** — the real `PopoverController` panel, claimed through
///   `claimPanelForSurfaceHosting()` and driven through the U2
///   host-agnostic seams: `surfaceDidShow()`/`surfaceDidHide()` on window
///   show/hide/switch, and a `surfaceResizer` that listens to the panel's
///   published size only to notice content the fixed frame cannot show.
/// - **Groups** — the caller-provided content controller
///   (`MixerWindowController.contentController` in the app), seated below the
///   toolbar strip in a `SurfaceScreenViewController`.
/// - **Settings** — a caller-provided `SettingsRootViewController` (a section
///   sidebar plus one scrolling pane), same container.
///
/// Every swap routes through the shell's `setContent` (R3 — assigning
/// `contentViewController` directly snaps the window to a 500×500 fallback).
///
/// **ONE FRAME.** The surface is `SurfaceLayout.width` wide and, for a whole
/// open session, exactly one height: measured on each fresh show from the
/// Mixer's exact fit, floored at `minimumContentSize` and capped to the
/// screen. Every screen wears it, folds and drawers move rows INSIDE it, and
/// nothing resizes the window again until the surface closes — a width change
/// on a screen switch slid the toolbar out from under the cursor and "reads
/// as the surface twitching" (owner, 2026-08-12). The frame is applied
/// top-anchored (the surface hangs from the menu bar and grows downward);
/// the shell's `show` does the positioning, and nothing re-centres it after.
///
/// **Pin** drives U1's `setPinned(_:)` manner flip and persists in
/// `AppSettings.surfacePinned` (restored at construction). The toolbar strip
/// overlaps the content in BOTH profiles (`.fullSizeContentView` never leaves
/// the style mask — R6), so every screen's content is seated below it by a
/// measured chrome inset (`contentLayoutRect`), never a hardcoded strip
/// height. ⌘1/⌘2/⌘3 ride the shell panel's `keyEquivalentHandler` seam — a
/// toolbar item group carries no per-segment key equivalents.
///
/// Lives in AudioutPopoverUI (a library) because `AudioutApp` is invisible
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
    /// The shell window's one header strip (D1): tabs + centered app name +
    /// Pin + Quit, as a real unified `NSToolbar`.
    private let toolbarController = SurfaceToolbarController()
    /// Lazily builds the Groups content the FIRST time the Groups tab is
    /// selected (`MixerWindowController.contentController` in the app — the
    /// surface must not construct window controllers itself).
    private let makeGroupsContent: () -> NSViewController
    /// Lazily builds the Settings root the FIRST time the Settings tab is
    /// selected. The surface subscribes to nothing on it: the frame is fixed,
    /// so no pane size is ever published to a host.
    private let makeSettingsContent: () -> SettingsRootViewController

    /// The Mixer panel, once claimed from its controller (lazy — claiming
    /// also installs the resize hook, so it only happens when the surface
    /// actually hosts the Mixer).
    private var mixerPanel: PopoverPanelViewController?
    private var groupsScreen: SurfaceScreenViewController?
    private var settingsScreen: SurfaceScreenViewController?
    private var settingsRoot: SettingsRootViewController?

    public private(set) var selectedScreen: SurfaceScreen = .mixer

    /// The one frame's content size for THIS open session — measured on every
    /// fresh show, never touched between shows.
    private var sessionContentSize = AppSurfaceController.minimumContentSize

    /// Whether this open session already logged Mixer content taller than the
    /// frame. Once per open: the panel republishes its size on every fold tick.
    private var overflowReported = false

    /// The launch splash while it is on screen. WEAK on purpose: the hosting
    /// content view owns it, and it takes itself off when it leaves — nothing
    /// here has to remember to clear a stale one.
    private weak var splash: SurfaceSplashView?

    /// Debounces the discovery stream to decide when the fleet has quiesced, so
    /// the settled frame is measured behind the splash and the user sees one
    /// frame. Non-nil only while a launch splash is up (the settle wait exists
    /// only to gate that ornament); the headless/Reduce-Motion open never makes
    /// one and keeps the old synchronous timing.
    private var settleTracker: DiscoverySettleTracker?

    /// Whether the surface window is currently presented (show → close). The
    /// Mixer's `surfaceDidShow`/`surfaceDidHide` lifecycle keys off this so
    /// metering/monitors only run while a user can see the panel.
    public private(set) var isShown = false

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

    /// The one frame's width, and the FLOOR of its session height.
    ///
    /// Both are WINDOW CONTENT sizes — the toolbar strip is included, because
    /// the Mixer's fit (`fittingSizeSettled()`) already carries the measured
    /// chrome inset. The Mixer's fit at open raises the height above this
    /// floor; the screen's visible frame caps it. The floor exists for the
    /// screens that cannot scroll: the Groups editor pane has no scroll view,
    /// so a 7-device fleet's editor plus the screen's footer strip must fit
    /// here (`AppSurfaceControllerTests.theSevenDeviceEditorFitsTheMinimumFrame`).
    public static let minimumContentSize = NSSize(width: SurfaceLayout.width, height: 600)

    public init(popoverController: PopoverController,
                settings: AppSettings = AppSettings(),
                groupsContent: @escaping () -> NSViewController,
                settingsContent: @escaping () -> SettingsRootViewController,
                frameAutosaveName: NSWindow.FrameAutosaveName = "ControlPanelSurface") {
        self.popoverController = popoverController
        self.settings = settings
        self.makeGroupsContent = groupsContent
        self.makeSettingsContent = settingsContent
        self.shell = ControlPanelWindowController(title: "Audiout",
                                                  frameAutosaveName: frameAutosaveName)
        // Restore the persisted pin BEFORE anything is on screen: `setPinned`
        // only re-anchors a visible panel, so this is a pure profile stamp.
        shell.setPinned(settings.surfacePinned)
        shell.onClose = { [weak self] in self?.handleShellClosed() }
        // One fixed frame: nothing in the surface resizes, so no screen offers
        // a drag affordance.
        shell.setUserResizable(false)

        // The one header (D1): a real unified NSToolbar on the shell window,
        // both profiles. Attaching here — before anything shows — means the
        // chrome inset is measurable from the first mount.
        toolbarController.onSelectScreen = { [weak self] in self?.select($0) }
        toolbarController.onTogglePin = { [weak self] in self?.togglePin() }
        toolbarController.onQuit = { NSApp?.terminate(nil) }

        // The discovery stream feeds the launch splash's settle tracker (nil
        // outside a splash — a plain no-op then).
        popoverController.onDeviceSnapshot = { [weak self] ids in
            self?.settleTracker?.note(deviceIDs: ids)
        }
        if let window = shell.window {
            toolbarController.attach(to: window)
            // Materialize the toolbar's title-bar machinery NOW (a toolbar on
            // a never-laid-out window reports a title-bar-only
            // `contentLayoutRect` until AppKit's first layout pass), so
            // `chromeTopInset` measures the real strip from the first mount.
            window.layoutIfNeeded()
        }
        syncToolbar()

        // ⌘1/⌘2/⌘3 (the retired header buttons' key equivalents): the shell
        // panel consults this before stock dispatch while the surface is key.
        shell.keyEquivalentHandler = { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let chars = event.charactersIgnoringModifiers,
                  let screen = SurfaceScreen.allCases.first(where: { $0.keyEquivalent == chars })
            else { return false }
            self?.select(screen)
            return true
        }
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
        let wasShown = isShown
        if !wasShown {
            overflowReported = false
            sessionContentSize = measureSessionContentSize()
            mount(selectedScreen)
            // The launch hold, first open of the process only — over the
            // MOUNTED content, so the screen is already built underneath it
            // (`SurfaceSplashView`).
            splash = SurfaceSplashView.present(over: shell.window?.contentView)
            // Only while there IS a splash to hold: gate its dismissal on the
            // fleet quiescing, and measure/apply the settled frame behind it.
            // Headless / Reduce Motion make no splash, so this never runs and
            // the open stays synchronous exactly as before.
            if splash != nil {
                let tracker = DiscoverySettleTracker()
                tracker.onSettled = { [weak self] in self?.handleDiscoverySettled() }
                settleTracker = tracker
                tracker.start()
            } else {
                settleTracker = nil
            }
        }
        shell.show(anchorRect: anchorRect)
        isShown = true
        if !wasShown, selectedScreen == .mixer {
            popoverController.surfaceDidShow()
        }
        publishVisibleScreen()
        // Part of the splash's leave condition: the surface is on screen with
        // its screen shown, so there is something to uncover.
        splash?.noteContentReady()
    }

    /// Discovery has quiesced (`DiscoverySettleTracker`). While the opaque
    /// splash still covers the content, re-measure and re-apply the session
    /// frame ONCE to the settled fleet, feeding the first burst of rows in
    /// un-animated so nothing slides, then release the splash. Net effect: the
    /// one frame the user ever sees is the settled one. A no-op if the cover is
    /// already gone (a click, or the ceiling backstop, revealed it early — the
    /// early frame then stands).
    private func handleDiscoverySettled() {
        guard isShown, splash?.test_isVisible == true else { return }
        overflowReported = false
        sessionContentSize = measureSessionContentSize()
        if selectedScreen == .mixer {
            // First-burst rows settled, not sliding — animated:false through the
            // panel's own re-fit, all behind the cover.
            mixerPanel?.panelContentDidChangeHeight(animated: false)
        }
        // The proper resize path: `applySessionFrame` → `window.setFrame` →
        // `ControlPanelWindowController.windowDidResize`, which keeps the
        // decorative bubble/beak in lockstep. Never a raw desync.
        applySessionFrame()
        splash?.noteDiscoverySettled()
    }

    /// Close through the shell's real-close path (`windowWillClose` →
    /// `handleShellClosed`), exactly as ✕/Esc would.
    /// Close the shell — unless the Mixer's sync drawer is mid-edit, in which
    /// case the edit is committed and the dismissal refused for this one
    /// request (see `PopoverController.surfaceShouldHide()`). Typing a value
    /// and pressing Return must set it, never dismiss the surface.
    public func performClose() {
        guard popoverController.surfaceShouldHide() else { return }
        shell.performClose()
    }

    private func handleShellClosed() {
        if isShown, selectedScreen == .mixer {
            popoverController.surfaceDidHide()
        }
        isShown = false
        // The settle wait belongs to this open's splash; a close ends it.
        settleTracker = nil
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

    /// The one frame's content size for the session about to start.
    ///
    /// Measured from the MIXER even when Groups or Settings is the screen that
    /// opens: the Mixer is the one screen that cannot scroll and cannot be
    /// shortened, so it decides the height and the other two fill it. Hidden
    /// means idle, so the panel is stale between shows — `rebuildForOpen()`
    /// re-ingests everything that arrived meanwhile BEFORE the measure, which
    /// is also why `mount` no longer runs the open ritual itself.
    /// `fittingSizeSettled()` already includes the measured chrome inset, so
    /// this is a window CONTENT size, toolbar strip and all.
    private func measureSessionContentSize() -> NSSize {
        let panel = claimedMixerPanel()
        applyChromeTopInset()
        popoverController.rebuildForOpen()
        var size = panel.fittingSizeSettled()
        size.width = Self.minimumContentSize.width
        size.height = max(size.height, Self.minimumContentSize.height)
        if let window = shell.window, let screen = window.screen ?? NSScreen.main {
            let maxFrame = NSRect(x: 0, y: 0,
                                  width: size.width,
                                  height: screen.visibleFrame.height - 16)
            size.height = min(size.height,
                              window.contentRect(forFrameRect: maxFrame).height)
        }
        return size
    }

    // MARK: Screen switching

    /// Switch to `screen`: lazy-builds it on first visit, swaps it in through
    /// the shell's `setContent` (R3), and confirms the toolbar's tab
    /// selection. The frame never changes — every screen wears the session
    /// size. Selecting the current screen is a no-op.
    public func select(_ screen: SurfaceScreen) {
        guard screen != selectedScreen else { return }
        if selectedScreen == .mixer, isShown {
            // The panel is leaving the window: drop what must not outlive a
            // session (transient selection, stale meter bars) and stop paying
            // for RMS while no meter is visible.
            popoverController.surfaceDidHide()
        }
        selectedScreen = screen
        syncToolbar()
        if screen == .mixer {
            // The Mixer's open ritual — `show` already ran it while measuring,
            // so returning to the screen re-ingests what arrived meanwhile.
            popoverController.rebuildForOpen()
        }
        mount(screen)
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
        // A sheet-bearing surface (e.g. the New Group sheet) can't be
        // dismissed — `performClose` refuses and beeps while the sheet
        // survives untouched (R7 already stops the window from
        // self-dismissing for this reason; this is the same call for a
        // deliberate menu-bar click). Front it instead, bringing the sheet to
        // the user, regardless of pin state.
        if shell.hasAttachedSheet { return shell.isPanelVisible ? .front : .show }
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

    /// Mount `screen` into the shell. Every screen gets the SAME session size:
    /// there is one frame, and a swap is content changing behind fixed glass.
    ///
    /// `setContent` can still move the window — on a controller's FIRST mount
    /// it applies `defaultSize` by snapping (R3), and a freshly mounted split
    /// view can ask AppKit for more — so the session frame is re-asserted
    /// after every swap, instantly, never animated.
    private func mount(_ screen: SurfaceScreen) {
        switch screen {
        case .mixer:
            let panel = claimedMixerPanel()
            // Seat the content below the toolbar strip AFTER the lazy build
            // (a screen that doesn't exist yet can't be seated), BEFORE the
            // size so the fit includes the inset.
            applyChromeTopInset()
            shell.setContent(panel, defaultSize: sessionContentSize)
            panel.panelContentDidChangeHeight(animated: false)
        case .groups:
            let screenVC = builtGroupsScreen()
            applyChromeTopInset()
            shell.setContent(screenVC, defaultSize: sessionContentSize)
        case .settings:
            let screenVC = builtSettingsScreen()
            applyChromeTopInset()
            shell.setContent(screenVC, defaultSize: sessionContentSize)
        }
        applySessionFrame()
    }

    // MARK: Lazy screens

    /// The Mixer panel, claimed from its controller on first use. Claiming
    /// also installs the surface's size LISTENER: the surface never resizes to
    /// the panel — the frame is fixed — it only notices content the frame
    /// cannot show and says so once per open. What to do about it (scroll the
    /// Mixer) is roadmap 039's call; clipping silently is not.
    private func claimedMixerPanel() -> PopoverPanelViewController {
        if let mixerPanel { return mixerPanel }
        let panel = popoverController.claimPanelForSurfaceHosting()
        mixerPanel = panel
        popoverController.surfaceResizer = { [weak self, weak panel] _, apply in
            apply()
            guard let self, let panel, self.isShown else { return }
            let content = panel.preferredContentSize.height
            guard content > self.sessionContentSize.height + 0.5,
                  !self.overflowReported else { return }
            self.overflowReported = true
            Telemetry.log(.surface, "mixer_content_taller_than_frame", [
                "content": String(Int(content.rounded())),
                "frame": String(Int(self.sessionContentSize.height.rounded())),
            ])
        }
        return panel
    }

    private func builtGroupsScreen() -> SurfaceScreenViewController {
        if let groupsScreen { return groupsScreen }
        let screen = SurfaceScreenViewController(content: makeGroupsContent())
        groupsScreen = screen
        return screen
    }

    private func builtSettingsScreen() -> SurfaceScreenViewController {
        if let settingsScreen { return settingsScreen }
        let root = makeSettingsContent()
        settingsRoot = root
        let screen = SurfaceScreenViewController(content: root)
        settingsScreen = screen
        return screen
    }

    private func syncToolbar() {
        toolbarController.setSelectedScreen(selectedScreen)
        toolbarController.setPinned(shell.isPinned)
    }

    // MARK: Pin

    public var isPinned: Bool { shell.isPinned }

    public func togglePin() { setPinned(!shell.isPinned) }

    /// Flip the shell's manner profile (U1) and persist the choice. Also
    /// re-seats every screen's content below the toolbar strip (measured —
    /// the strip's height can differ per profile) and re-asserts the session
    /// frame, which the profile flip can disturb. The SIZE never changes: a
    /// pin is a manner change, not a resize.
    public func setPinned(_ pinned: Bool) {
        guard pinned != shell.isPinned else { return }
        settings.surfacePinned = pinned
        shell.setPinned(pinned)
        syncToolbar()
        applyChromeTopInset()
        if selectedScreen == .mixer {
            mixerPanel?.panelContentDidChangeHeight(animated: false)
        }
        applySessionFrame()
    }

    /// Points of window chrome overlapping the content's TOP: the unified
    /// toolbar strip, in BOTH profiles (`.fullSizeContentView` keeps content
    /// under it — content must inset itself). Measured from the live window
    /// (`contentLayoutRect`), never a hardcoded strip height. The strip is the
    /// gap ABOVE `contentLayoutRect.maxY` — measured, NOT the height
    /// difference: mid-resize the rect's size lags the just-set frame (probed:
    /// a stale bottom offset leaked into the difference and over-inset the
    /// content by 50pt), while the top gap stays true. Deliberately NO
    /// `layoutIfNeeded()` here: forcing window layout mid-mount let a freshly
    /// mounted split view widen the window to its own minimum (probed, 560 →
    /// 707); the one legitimate materialization pass runs at attach time in
    /// `init`.
    private var chromeTopInset: CGFloat {
        guard let window = shell.window,
              let contentView = window.contentView else { return 0 }
        return max(0, contentView.frame.height - window.contentLayoutRect.maxY)
    }

    private func applyChromeTopInset() {
        let inset = chromeTopInset
        mixerPanel?.setContentTopInset(inset)
        groupsScreen?.setContentTopInset(inset)
        settingsScreen?.setContentTopInset(inset)
    }

    // MARK: Sizing

    /// Put the window back on the session frame: `sessionContentSize` as
    /// content, TOP edge anchored (the surface hangs from the menu bar and
    /// grows downward), left edge where it already is, clamped on screen with
    /// the shell's own 8pt margins. Never animated — nothing about the frame
    /// ever changes once a session starts, so there is nothing to animate and
    /// no Reduce Motion or headless branch to take. Never re-centred either:
    /// the shell's `show(anchorRect:)` positions the window once, at open.
    private func applySessionFrame() {
        guard let window = shell.window else { return }
        let frameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: sessionContentSize)).size
        var origin = NSPoint(x: window.frame.minX,
                             y: window.frame.maxY - frameSize.height)
        if let screen = window.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - frameSize.width - 8)
            origin.y = max(vf.minY + 8, origin.y)
        }
        window.setFrame(NSRect(origin: origin, size: frameSize), display: true)
    }

    // MARK: Test-support hooks

    /// The currently hosted content controller (what `setContent` mounted).
    public var test_hostedContentViewController: NSViewController? {
        shell.window?.contentViewController
    }
    /// The window's toolbar header, for item/selection assertions.
    var test_toolbarController: SurfaceToolbarController { toolbarController }
    /// The lazily-built pieces, `nil` until their tab is first selected.
    var test_mixerPanel: PopoverPanelViewController? { mixerPanel }
    var test_groupsScreen: SurfaceScreenViewController? { groupsScreen }
    var test_settingsScreen: SurfaceScreenViewController? { settingsScreen }
    var test_settingsRoot: SettingsRootViewController? { settingsRoot }
    /// The chrome inset screens are currently seated below (0 unpinned).
    var test_chromeTopInset: CGFloat { chromeTopInset }
    /// The launch splash, `nil` when this open showed none or it has left.
    var test_splash: SurfaceSplashView? { splash }
    /// The launch settle tracker, `nil` when no splash gated this open.
    var test_settleTracker: DiscoverySettleTracker? { settleTracker }
    /// Drive the settle path exactly as a quiesced fleet would.
    func test_settleDiscovery() { settleTracker?.test_settleNow() }
}

// MARK: - SurfaceScreenViewController

/// One surface screen (Groups, Settings): a thin container that seats the
/// content controller — a real CHILD view controller, so the responder chain
/// and appearance plumbing stay stock — below the window's toolbar strip by
/// the surface-pushed chrome inset. (The Mixer panel is hosted directly
/// instead: it seats its own content via `setContentTopInset`, so the inset
/// participates in the exact-fit measure.)
///
/// The root view paints NOTHING: the shell's backing bubble (unpinned) and
/// the pinned window's own background both fill the one warm `panel` canvas
/// behind transparent content, and content that paints its own background
/// (Groups' content pane, Settings' root) paints that same canvas — one
/// background across the surface (owner decision D2, 2026-08-07). Each screen
/// is its own controller instance because the shell keys size preservation on
/// the hosted controller's identity.
@MainActor
final class SurfaceScreenViewController: NSViewController {

    let content: NSViewController
    private var contentTopConstraint: NSLayoutConstraint?

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        addChild(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero,
                                        size: AppSurfaceController.minimumContentSize))
        let contentView = content.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)

        let contentTop = contentView.topAnchor.constraint(equalTo: root.topAnchor)
        contentTopConstraint = contentTop
        NSLayoutConstraint.activate([
            contentTop,
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Seat the content below the window's toolbar strip (the measured chrome
    /// inset — `.fullSizeContentView` content spans under the strip).
    func setContentTopInset(_ inset: CGFloat) {
        _ = view // ensure loadView ran so the constraint exists
        contentTopConstraint?.constant = inset
    }

    /// The current content inset, for structural tests.
    var test_contentTopInset: CGFloat { contentTopConstraint?.constant ?? 0 }
}
