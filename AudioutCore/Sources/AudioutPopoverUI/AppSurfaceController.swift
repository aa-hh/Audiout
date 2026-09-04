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

    /// Asked when Escape reaches the surface while the Groups screen is
    /// showing. Return `true` when the screen stepped back a level (the app
    /// wires `MixerWindowController.dismissEditor()`); `false` lets the press
    /// close the surface.
    public var groupsCancelHandler: (() -> Bool)?

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
    /// the window is REVEALED (fronted) already at the settled size and the user
    /// sees one frame, never a resize. Non-nil only while a first-open reveal is
    /// pending (the settle wait exists only to gate that first ornament); the
    /// headless/Reduce-Motion open never makes one and keeps the old synchronous
    /// timing.
    private var settleTracker: DiscoverySettleTracker?

    /// While a first-open splash reveal is pending: whether one is pending, the
    /// anchor to reveal at, and the backstop timer that reveals anyway if
    /// discovery never quiets. The window is NOT on screen during this wait — it
    /// is fronted once, at the settled size, so nothing ever resizes in front of
    /// the user (a downward window grow can't be hidden by an internal cover; the
    /// only fix is to not grow it on screen at all — front it already settled).
    private var isRevealPending = false
    private var pendingRevealAnchor: NSRect?
    private var revealCeilingTimer: Timer?

    /// Work handed to ``whenRevealed(_:)`` while that wait was still on — run at
    /// the end of the reveal, dropped if the wait is cancelled (a close during
    /// the wait means the user has moved on).
    private var pendingRevealWork: (() -> Void)?

    /// The most recent device-id snapshot from discovery, kept across opens so a
    /// warm first open (fleet already known) can seed the settle tracker at once.
    private var lastDeviceIDs: Set<String> = []

    /// Whether the surface window is currently presented (show → close). The
    /// Mixer's `surfaceDidShow`/`surfaceDidHide` lifecycle keys off this so
    /// metering/monitors only run while a user can see the panel.
    public private(set) var isShown = false

    /// Whether the Mixer was put to sleep because its pixels stopped being
    /// visible — the surface fully covered by another window, or the app
    /// hidden. A PINNED surface is an ordinary window the user can leave open
    /// for days behind a browser, and "open" was the only question anyone
    /// asked: metering, monitors and repaints all ran full tilt against a
    /// surface nobody could see.
    ///
    /// A LATCH, not a mirror of the occlusion state: `surfaceDidHide()` /
    /// `surfaceDidShow()` are edge calls (they drop transient state and re-run
    /// the open ritual), so firing them per notification would tear the panel
    /// down repeatedly. It also keeps the ordinary close/tab-switch paths from
    /// hiding a Mixer that is already asleep.
    private var surfaceCoveredHidden = false

    /// The occlusion/app-hide observers, kept only so they can be dropped.
    private var pixelVisibilityObservers: [NSObjectProtocol] = []

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
    /// floor; the screen's visible frame caps it. The Groups editor pane now
    /// SCROLLS (roadmap 039), so a fleet it cannot fit overflows into its
    /// scroller instead of asking this floor to grow — guarded by
    /// `AppSurfaceControllerTests.theSevenDeviceEditorScrollsInsideTheMinimumFrame`.
    public static let minimumContentSize = NSSize(width: SurfaceLayout.width, height: 600)

    /// How long the fleet must stop changing before the first-open reveal fires.
    /// Wider than discovery's between-device gap so a device-at-a-time stream
    /// does not read as "settled" in a lull mid-stream.
    static let revealQuietWindow: TimeInterval = 0.5
    /// The backstop, and a bound on how long a menu-bar click can appear to do
    /// NOTHING. It is above `revealQuietWindow` (0.5 s), so a warm open still
    /// settles first and fronts at the settled size exactly as before. A COLD
    /// open now reveals here rather than waiting out a whole discovery: the
    /// splash covers the content churn, and whatever frame growth still arrives
    /// late is bounded and brief — strictly better than a click that shows
    /// nothing for three seconds. A repeat click cuts the wait short on demand
    /// (`show(anchorRect:)`).
    static let revealCeiling: TimeInterval = 0.6

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

        // The discovery stream feeds the first-open reveal's settle tracker (nil
        // outside a first open — a plain no-op then), and is remembered so a
        // warm open (fleet already known) can seed the tracker at once instead
        // of waiting on the next event. EMPTY snapshots are NOT fed: at a cold
        // launch discovery starts empty and streams in, and an empty set would
        // settle the tracker instantly (0.3 s) — fronting the surface at the
        // floor, then growing it as the real fleet arrives, which is exactly the
        // open jump. A genuinely empty network reveals on the ceiling backstop.
        popoverController.onDeviceSnapshot = { [weak self] ids in
            guard let self else { return }
            self.lastDeviceIDs = ids
            guard !ids.isEmpty else { return }
            self.settleTracker?.note(deviceIDs: ids)
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

        // Pixel visibility (perf P2-12): a covered or hidden surface is idle.
        // AppKit answers both halves — the window's own occlusion state, and
        // the app being hidden (⌘H / Hide Others), which occlusion alone does
        // not report.
        let center = NotificationCenter.default
        var observers: [NSObjectProtocol] = []
        if let window = shell.window {
            observers.append(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassessPixelVisibility() }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassessPixelVisibility() }
            })
        }
        pixelVisibilityObservers = observers

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
        // Escape on the Groups screen steps back one level first (a group
        // editor pops to the overview); anything else, and the next Escape,
        // closes the surface.
        shell.cancelHandler = { [weak self] in
            guard let self, selectedScreen == .groups else { return false }
            return groupsCancelHandler?() ?? false
        }
    }

    deinit {
        for observer in pixelVisibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Pixel visibility (perf P2-12)

    /// Ask AppKit whether any of the surface's pixels are actually on screen,
    /// and hand the answer to the latch. Never runs headless — neither
    /// notification fires with no window server — which is why the seam below
    /// exists.
    private func reassessPixelVisibility() {
        let visible = (shell.window?.occlusionState.contains(.visible) ?? true)
            && !(NSApp?.isHidden ?? false)
        applyPixelVisibility(visible)
    }

    /// Put the Mixer to sleep while its pixels are gone, and wake it properly
    /// when they come back. Waking is the full Mixer open ritual the folder's
    /// rules require of ANY re-entry — the panel is stale by design while it is
    /// hidden, so re-showing it without `rebuildForOpen()` would put a stale
    /// list back on screen.
    ///
    /// Only the Mixer sleeps: Groups and Settings run no metering and no
    /// monitors, and a reveal-pending surface is not on screen yet.
    private func applyPixelVisibility(_ visible: Bool) {
        guard isShown, selectedScreen == .mixer, !isRevealPending else { return }
        if !visible, !surfaceCoveredHidden {
            surfaceCoveredHidden = true
            popoverController.surfaceDidHide()
        } else if visible, surfaceCoveredHidden {
            surfaceCoveredHidden = false
            popoverController.rebuildForOpen()
            popoverController.surfaceDidShow()
            mixerPanel?.panelContentDidChangeHeight(animated: false)
        }
    }

    // MARK: Show / hide

    /// Present the surface anchored under the status item (`nil` centers it;
    /// pinned mode fronts the window wherever the user left it — the shell
    /// owns that distinction). A FRESH show mounts the current screen; on the
    /// first-open splash path it does NOT front the window yet — it waits for
    /// discovery to settle and fronts once, already at the settled size
    /// (`revealFirstOpen`), so the window never resizes in front of the user.
    /// Showing an ALREADY-shown surface (the pinned always-front click) only
    /// fronts it — re-running the Mixer's open ritual there would discard the
    /// user's mid-open collapse toggles for no reason (it is the same open
    /// session).
    public func show(anchorRect: NSRect?) {
        // A repeat click DURING a first-open reveal wait is the user asking for
        // the surface NOW — the wait has visibly done nothing, so clicking again
        // must not be swallowed (it used to `return`, and every further click
        // vanished until the ceiling fired). Reveal at the size measured so far:
        // `revealFirstOpen` disarms the backstop, fronts once, and lays the
        // splash over whatever is in place, and its own `guard isRevealPending`
        // makes this call safe.
        if isRevealPending {
            revealFirstOpen()
            return
        }
        let wasShown = isShown
        if !wasShown {
            Analytics.capture("surface:shown", ["screen": String(describing: selectedScreen)])
            // A fresh show starts awake, whatever a previous session latched.
            surfaceCoveredHidden = false
            overflowReported = false
            sessionContentSize = measureSessionContentSize()
            mount(selectedScreen)
            // First open of the process only: DEFER the on-screen reveal until
            // discovery quiets, so the window is fronted ONCE, already at the
            // settled size, and the branded hold's centred mark never slides.
            // Headless / Reduce Motion earn no ornament, so this never runs and
            // the open stays synchronous exactly as before.
            if SurfaceSplashView.wouldPresent {
                isRevealPending = true
                pendingRevealAnchor = anchorRect
                // A quiet window wider than the discovery trickle's gap between
                // devices, so a stream that arrives one device at a time does
                // NOT settle in a gap mid-stream (0.3 s settled between the
                // ~0.35 s-spaced fake speakers — the surface fronted at the floor
                // and grew as the rest arrived, the jump again). It settles once
                // the fleet has genuinely stopped changing for this long.
                let tracker = DiscoverySettleTracker(quietWindow: Self.revealQuietWindow)
                tracker.onSettled = { [weak self] in self?.revealFirstOpen() }
                settleTracker = tracker
                // Seed with the fleet already known (a warm open): it settles on
                // its own quiet window and reveals promptly. A cold open has an
                // empty fleet here, so the tracker is NOT armed — it waits for
                // the first real device (or the ceiling), never settling on the
                // empty pre-discovery state. (Deliberately not `start()`, which
                // arms an empty-fleet settle — the source of the early reveal.)
                if !lastDeviceIDs.isEmpty {
                    tracker.note(deviceIDs: lastDeviceIDs)
                }
                // The backstop: a network that never quiets must still reveal
                // the surface, or the user is trapped waiting on a click that
                // seemed to do nothing.
                revealCeilingTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.revealCeiling,
                    repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.revealFirstOpen() }
                }
                return
            }
            settleTracker = nil
        }
        shell.show(anchorRect: anchorRect)
        isShown = true
        if !wasShown, selectedScreen == .mixer {
            popoverController.surfaceDidShow()
        }
        publishVisibleScreen()
    }

    /// Discovery has quiesced (or the backstop fired): re-measure the SETTLED
    /// fleet, size the still-off-screen window to it, THEN front it once and lay
    /// the branded hold over the already-settled content. The user's very first
    /// sight of the surface is the settled frame — nothing resizes, and the
    /// mark holds still because the frame it centres in never changes. Fires at
    /// most once (the tracker settles once, and this disarms the backstop).
    private func revealFirstOpen() {
        guard isRevealPending else { return }
        isRevealPending = false
        revealCeilingTimer?.invalidate()
        revealCeilingTimer = nil
        settleTracker = nil

        overflowReported = false
        sessionContentSize = measureSessionContentSize()
        if selectedScreen == .mixer {
            // Settled rows, not sliding — animated:false through the panel's own
            // re-fit, still off screen.
            mixerPanel?.panelContentDidChangeHeight(animated: false)
            // Front at the FLOORED session size, not the Mixer's raw fit. AppKit
            // resizes the shell window to the content controller's
            // `preferredContentSize` and does so DEFERRED — a plain `setFrame`
            // here is overridden a runloop later (verified live) — so this
            // LAST write pins the size the window actually opens at. Below the
            // 600 floor (a small fleet) the raw fit would otherwise shrink the
            // window under the splash right after it fronts.
            mixerPanel?.preferredContentSize = sessionContentSize
        }
        applySessionFrame()

        let anchor = pendingRevealAnchor
        pendingRevealAnchor = nil
        shell.show(anchorRect: anchor)
        isShown = true
        if selectedScreen == .mixer {
            popoverController.surfaceDidShow()
        }
        publishVisibleScreen()

        // The branded hold, over the settled content at the settled size:
        // content is already in place and discovery already quiet, so only the
        // hold gates its cross-fade — "splash solid, then cross-fade onto an
        // already-settled list" (owner).
        splash = SurfaceSplashView.present(over: shell.window?.contentView)
        splash?.noteContentReady()
        splash?.noteDiscoverySettled()

        // Anything that was waiting for a window to exist (the deep link's
        // license sheet) — last, so it lands on the fronted, settled surface.
        let deferred = pendingRevealWork
        pendingRevealWork = nil
        deferred?()
    }

    /// Run `work` once the surface is genuinely on screen: straight away when it
    /// already is, otherwise at the end of the deferred first-open reveal. Call
    /// it AFTER ``show(anchorRect:)`` — a sheet presented during the reveal wait
    /// would never appear, because the window has not been fronted yet.
    /// Last ask wins; the wait's only caller is a deep link, and a newer link
    /// supersedes an older one.
    public func whenRevealed(_ work: @escaping () -> Void) {
        guard isRevealPending else { return work() }
        pendingRevealWork = work
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
        // A Mixer already asleep behind the latch has had its `surfaceDidHide()`;
        // a second one would run the teardown twice.
        if isShown, selectedScreen == .mixer, !surfaceCoveredHidden {
            popoverController.surfaceDidHide()
        }
        surfaceCoveredHidden = false
        isShown = false
        // The settle wait belongs to this open's first-reveal; a close ends it.
        cancelPendingReveal()
        publishVisibleScreen()
        onClose?()
    }

    /// Drop a pending first-open reveal (a close during the settle wait). The
    /// window was never fronted, so there is nothing to hide — just stop the
    /// wait from later fronting a surface the user has moved on from.
    private func cancelPendingReveal() {
        isRevealPending = false
        pendingRevealAnchor = nil
        pendingRevealWork = nil
        revealCeilingTimer?.invalidate()
        revealCeilingTimer = nil
        settleTracker = nil
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
        Analytics.capture("surface:screen_selected", ["screen": String(describing: screen)])
        if selectedScreen == .mixer, isShown, !surfaceCoveredHidden {
            // The panel is leaving the window: drop what must not outlive a
            // session (transient selection, stale meter bars) and stop paying
            // for RMS while no meter is visible. A Mixer already asleep behind
            // the occlusion latch has had exactly this call already.
            popoverController.surfaceDidHide()
        }
        // Whichever direction this switch goes, the latch is spent: leaving the
        // Mixer hides it anyway, and arriving at it below shows it awake.
        surfaceCoveredHidden = false
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

    public func togglePin() {
        let newValue = !shell.isPinned
        Analytics.capture("surface:pin_toggled", ["pinned": newValue ? "true" : "false"])
        setPinned(newValue)
    }

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
    /// Whether the first-open reveal is waiting on discovery to settle.
    var test_isRevealPending: Bool { isRevealPending }
    /// Drive the settle path exactly as a quiesced fleet would.
    func test_settleDiscovery() { settleTracker?.test_settleNow() }
    /// Fire the first-open reveal backstop exactly as its ceiling timer would.
    func test_fireRevealCeiling() { revealFirstOpen() }
    /// Drive the pixel-visibility latch exactly as an occlusion change would —
    /// the live read never runs headless (no window server, no notification).
    func test_notePixelVisibility(_ visible: Bool) { applyPixelVisibility(visible) }
    /// Whether the Mixer is currently asleep behind the occlusion latch.
    var test_surfaceCoveredHidden: Bool { surfaceCoveredHidden }
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
