// SPDX-License-Identifier: GPL-2.0-or-later
//
// Throwaway prototype (see main.swift). Not shipped, not linked by the app.

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// A flipped wrapper so a scroll view's "top" is y = 0 regardless of whether
/// the hosted production view is flipped — which makes "scroll to the top,
/// under the header inset" one deterministic line instead of a coordinate-space
/// case analysis.
@MainActor
final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

/// One screen of the prototype surface: theme canvas at the back, the real
/// production content in the middle, the translucent header floating on top,
/// and the prototype-only theme switch in the bottom-trailing corner.
///
/// A screen is its own `NSViewController` because the shell keys its
/// size-preservation on the hosted controller's identity — three controllers is
/// what gives three per-screen sizes.
@MainActor
final class SurfaceScreenViewController: NSViewController {

    let header = SurfaceHeaderView()
    let themeSwitch = NSSegmentedControl()

    private let content: NSView
    private let scrollsUnderHeader: Bool
    private let contentTopTrim: CGFloat
    private var scrollView: NSScrollView?
    private var background: NSView?
    private var headerTop: NSLayoutConstraint?
    private var theme: MockupTheme = .warmSignal

    var onThemeChange: ((MockupTheme) -> Void)?

    /// - Parameter scrollsUnderHeader: `true` puts the content in a scroll view
    ///   inset by the header height, so it runs edge-to-edge and slides *under*
    ///   the glass. `false` seats the content below the header instead — used
    ///   for Groups, whose split view has to fill rather than scroll, and whose
    ///   sidebar section titles would otherwise sit behind the tabs.
    /// - Parameter contentTopTrim: points of the content's own top scrolled
    ///   away on first paint. The Mixer panel still reserves the space of its
    ///   original header row (hidden, not removed — removing it would break the
    ///   constraints the stack hangs off), and this tucks that dead strip under
    ///   the glass instead of showing it as a gap.
    init(content: NSView, scrollsUnderHeader: Bool, contentTopTrim: CGFloat = 0) {
        self.content = content
        self.scrollsUnderHeader = scrollsUnderHeader
        self.contentTopTrim = contentTopTrim
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 623, height: 623))
        root.wantsLayer = true
        view = root

        header.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        let contentHost: NSView
        if scrollsUnderHeader {
            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: SurfaceHeaderView.height,
                                                left: 0, bottom: 0, right: 0)
            let document = FlippedContainer()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                content.topAnchor.constraint(equalTo: document.topAnchor),
                content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            ])
            scroll.documentView = document
            NSLayoutConstraint.activate([
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            ])
            scrollView = scroll
            contentHost = scroll
        } else {
            contentHost = content
        }

        configureThemeSwitch()

        root.addSubview(makeBackground())
        root.addSubview(contentHost)
        root.addSubview(header)
        root.addSubview(themeSwitch)

        let headerTop = header.topAnchor.constraint(equalTo: root.topAnchor)
        self.headerTop = headerTop
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerTop,
            header.heightAnchor.constraint(equalToConstant: SurfaceHeaderView.height),

            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentHost.topAnchor.constraint(equalTo: scrollsUnderHeader
                                             ? root.topAnchor : header.bottomAnchor),

            themeSwitch.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            themeSwitch.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
    }

    /// The theme canvas. Warm Signal reuses the production `WarmCanvasView`
    /// (gradient + grain, Reduce Transparency/Increase Contrast aware); the
    /// muted-white canvas is a flat fill, which is all Circuit's neutrals are.
    private func makeBackground() -> NSView {
        let fresh: NSView
        switch theme {
        case .warmSignal:
            fresh = WarmCanvasView(frame: view.bounds)
        case .mutedWhite:
            let flat = FlatFillView(frame: view.bounds)
            flat.fill = theme.canvas
            fresh = flat
        }
        fresh.autoresizingMask = [.width, .height]
        background = fresh
        return fresh
    }

    private func configureThemeSwitch() {
        themeSwitch.translatesAutoresizingMaskIntoConstraints = false
        themeSwitch.segmentCount = MockupTheme.allCases.count
        themeSwitch.segmentStyle = .rounded
        themeSwitch.controlSize = .small
        themeSwitch.font = Tokens.Font.caption
        for theme in MockupTheme.allCases {
            themeSwitch.setLabel(theme.title, forSegment: theme.rawValue)
        }
        themeSwitch.selectedSegment = theme.rawValue
        themeSwitch.target = self
        themeSwitch.action = #selector(themeSwitched)
        themeSwitch.toolTip = "Prototype only — swaps the canvas this mockup draws"
        themeSwitch.alphaValue = 0.75
    }

    @objc private func themeSwitched() {
        guard let picked = MockupTheme(rawValue: themeSwitch.selectedSegment) else { return }
        onThemeChange?(picked)
    }

    func setTheme(_ theme: MockupTheme) {
        guard isViewLoaded else { self.theme = theme; return }
        self.theme = theme
        themeSwitch.selectedSegment = theme.rawValue
        header.setTheme(theme)
        background?.removeFromSuperview()
        view.addSubview(makeBackground(), positioned: .below, relativeTo: view.subviews.first)
        setWarmCanvasHidden(theme != .warmSignal, in: content)
    }

    /// The hosted production views paint their OWN Warm Signal canvas, which
    /// covers this screen's canvas completely — so the muted-white comparison
    /// would be invisible on the Mixer. Hiding those canvases (a view-tree
    /// reach, never an edit to `WarmCanvasView` itself) lets the theme canvas
    /// behind them show through. Everything the production views draw ON the
    /// canvas — rows, faders, the gold rail — still reads from `Tokens` and
    /// stays Warm Signal in both themes.
    private func setWarmCanvasHidden(_ hidden: Bool, in view: NSView) {
        if view is WarmCanvasView {
            view.isHidden = hidden
            return
        }
        for subview in view.subviews { setWarmCanvasHidden(hidden, in: subview) }
    }

    /// Slide the header down when the pinned window grows a real title bar, so
    /// the tab row sits under it rather than behind it.
    func setHeaderTopInset(_ inset: CGFloat) {
        headerTop?.constant = inset
        scrollView?.contentInsets = NSEdgeInsets(top: SurfaceHeaderView.height + inset,
                                                 left: 0, bottom: 0, right: 0)
        scrollToTop()
    }

    /// The pieces an offscreen capture composites, back to front. A single
    /// `cacheDisplay` on the root cannot produce this image: it does not
    /// traverse into `NSClipView`'s or `NSSplitView`'s own layer subtree, so
    /// the content comes back blank. Each piece renders correctly on its own —
    /// the generator captures them separately and draws them at these views'
    /// frames in root coordinates (the same composite idiom `window-snapshot`
    /// uses for the shell's two windows).
    var snapshotPieces: [NSView] {
        [background, content, header, themeSwitch].compactMap { $0 }
    }

    /// Park the scroll position at the top of the content-inset region, so the
    /// first paint shows content starting below the header (and everything
    /// above it slides under the glass as you scroll).
    func scrollToTop() {
        guard let scroll = scrollView else { return }
        view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: contentTopTrim - scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// Drives the prototype: one `ControlPanelWindowController` (reused as-is), three
/// screens swapped through its `setContent`, an animated per-screen resize, and
/// an outside-in pin flip.
@MainActor
final class SurfaceMockupController {

    let shell = ControlPanelWindowController()

    private var screens: [SurfaceTab: SurfaceScreenViewController] = [:]
    private var current: SurfaceTab = .mixer
    private var isPinned = false
    private var theme: MockupTheme = .warmSignal
    private let anchorRect: NSRect

    /// The snapshot generator turns the resize animation off so it never
    /// captures a frame mid-flight.
    var animatesResize = true

    /// Per-screen content sizes from the plan's "End state": Mixer exact-fit
    /// (623 wide, and 623 tall is the popover's own settled height), Groups
    /// 560×505, Settings 460 wide by whatever its pane actually measures.
    private let sizes: [SurfaceTab: NSSize]

    /// Height the pinned window's real title bar takes. Prototype constant —
    /// the standard macOS title-bar height; the shell keeps
    /// `.fullSizeContentView`, so the bar overlaps content unless the header
    /// moves down by exactly this.
    private static let pinnedTitleBarHeight: CGFloat = 28

    init(mixer: NSView, mixerTopTrim: CGFloat, groups: NSView,
         settings: NSView, settingsHeight: CGFloat, anchorRect: NSRect) {
        self.anchorRect = anchorRect
        sizes = [
            .mixer: NSSize(width: 623, height: 623),
            .groups: NSSize(width: 560, height: 505),
            .settings: NSSize(width: 460, height: settingsHeight + SurfaceHeaderView.height),
        ]
        screens = [
            .mixer: SurfaceScreenViewController(content: mixer, scrollsUnderHeader: true,
                                                contentTopTrim: mixerTopTrim),
            .groups: SurfaceScreenViewController(content: groups, scrollsUnderHeader: false),
            .settings: SurfaceScreenViewController(content: settings, scrollsUnderHeader: true),
        ]
        for screen in screens.values {
            screen.header.onSelect = { [weak self] in self?.select($0) }
            screen.header.onTogglePin = { [weak self] in self?.togglePin() }
            screen.header.onQuit = { NSApp.terminate(nil) }
            screen.onThemeChange = { [weak self] in self?.setTheme($0) }
            screen.header.setSelected(current)
        }
        shell.setTitle("Audiouter")
        shell.onClose = { NSApp.terminate(nil) }
    }

    /// Which material tier the header actually resolved to on this machine.
    var headerTierDescription: String {
        screens[.mixer].map { $0.header.resolvedTierDescription } ?? "unknown"
    }

    func show() {
        mount(current)
        shell.show(anchorRect: anchorRect)
        screens[current]?.scrollToTop()
    }

    /// The screen controller for a tab, for the snapshot generator.
    func screen(_ tab: SurfaceTab) -> SurfaceScreenViewController? { screens[tab] }

    func select(_ tab: SurfaceTab) {
        guard tab != current, let window = shell.window else { return }
        current = tab
        for screen in screens.values { screen.header.setSelected(tab) }

        // `setContent` snaps the window to the size it decides on. Capture the
        // size first and put it straight back, so the visible change is the
        // animation below rather than a jump — a prototype-only flourish done
        // entirely from outside the shell.
        let previousFrame = window.frame
        mount(tab)
        window.setFrame(previousFrame, display: false)
        animateWindow(to: sizes[tab] ?? previousFrame.size)
        screens[tab]?.scrollToTop()
    }

    private func mount(_ tab: SurfaceTab) {
        guard let screen = screens[tab] else { return }
        // R3: never assign `contentViewController` directly — always `setContent`.
        shell.setContent(screen, defaultSize: sizes[tab] ?? NSSize(width: 623, height: 623))
        screen.setHeaderTopInset(isPinned ? Self.pinnedTitleBarHeight : 0)
    }

    /// Resize the window to a screen's size with the TOP edge and the beak's
    /// anchor held fixed, so the surface grows downward from the status item.
    private func animateWindow(to contentSize: NSSize) {
        guard let window = shell.window else { return }
        var origin = NSPoint(x: (anchorRect.midX - contentSize.width / 2).rounded(),
                             y: window.frame.maxY - contentSize.height)
        if isPinned { origin.x = window.frame.minX }
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - contentSize.width - 8)
        }
        let frame = NSRect(origin: origin, size: contentSize)

        if !animatesResize || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || HeadlessRuntime.isActive {
            window.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        }
    }

    func setTheme(_ theme: MockupTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        for screen in screens.values { screen.setTheme(theme) }
    }

    /// The pin demo: window MANNERS only, flipped from outside the shell —
    /// movable, normal level, no tuck-away on app switch, a real title bar, and
    /// the decorative beak window ordered out. Deliberately not the real U1
    /// implementation (no frame persistence, no close-on-resign policy); this
    /// exists so the feel of the transition can be judged before that lands.
    func togglePin() {
        guard let window = shell.window else { return }
        isPinned.toggle()
        for screen in screens.values { screen.header.setPinned(isPinned) }

        if isPinned {
            window.isMovable = true
            window.level = .normal
            window.hidesOnDeactivate = false
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            shell.test_backingWindow?.orderOut(nil)
            screens[current]?.setHeaderTopInset(Self.pinnedTitleBarHeight)
        } else {
            window.isMovable = false
            window.level = .floating
            window.hidesOnDeactivate = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            screens[current]?.setHeaderTopInset(0)
            shell.show(anchorRect: anchorRect)
        }
    }
}
