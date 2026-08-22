// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The Settings screen: a source-list sidebar of sections on the left, one
/// pane on the right — the Groups screen's own arrangement, so the app has
/// exactly ONE tab level (the surface's screen switcher) instead of a second
/// strip nested inside the first.
///
/// The pane sits TOP-ALIGNED inside a transparent overlay-scroller scroll
/// view (the Groups detail panes' idiom) and is never sized to the window: the
/// surface frame is fixed, so nothing here publishes a size to a host. A short
/// pane leaves calm canvas below it; a tall one scrolls.
///
/// Every view this controller adds sets
/// `translatesAutoresizingMaskIntoConstraints = false`. That rule is not
/// stylistic — an autoresized subview of an engine-managed superview makes
/// AppKit synthesise mask constraints from whatever margins it holds at
/// synthesis time, and a transient construction size frozen into REQUIRED
/// constraints once shipped a 116pt dead gap under "Launch at login" with no
/// conflict ever logged.
@MainActor
public final class SettingsRootViewController: NSSplitViewController {

    /// One section's definition. The SF Symbol is required, not decorative:
    /// a sidebar row with no glyph reads as a blank slot next to its siblings.
    public struct Section {
        let title: String
        let symbolName: String
        let viewController: NSViewController

        public init(title: String, symbolName: String, viewController: NSViewController) {
            self.title = title
            self.symbolName = symbolName
            self.viewController = viewController
        }
    }

    private let sections: [Section]
    private let sidebar: SettingsSidebarViewController
    private let paneHost = SettingsPaneHostViewController()

    /// The section the pane is currently showing; `-1` with no sections.
    public private(set) var selectedSectionIndex: Int = -1

    /// The sidebar's row titles, in order.
    public var sectionTitles: [String] { sections.map(\.title) }

    public init(sections: [Section]) {
        self.sections = sections
        self.sidebar = SettingsSidebarViewController(
            sections: sections.map { (title: $0.title, symbolName: $0.symbolName) })
        super.init(nibName: nil, bundle: nil)

        // The documented `.sidebar(withViewController:)` constructor applies
        // the source-list material/vibrancy, and the thickness is PINNED
        // min == max at `SurfaceLayout.sidebarWidth` so this screen's split
        // asks for exactly the same width the Groups screen's does.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = SurfaceLayout.sidebarWidth
        sidebarItem.maximumThickness = SurfaceLayout.sidebarWidth
        // NOT collapsible: a collapse here is a ONE-WAY DOOR — the sidebar is
        // the only way to change section, and the surface has no sidebar
        // toggle and no View menu to bring it back.
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: paneHost))

        // Load the whole split tree here, inside `init`: a host must never
        // wrap an empty controller (AppKit's 500×500 fallback for an empty
        // container never self-corrects), and the sidebar's outline view has
        // to exist before the first selection below.
        loadViewIfNeeded()

        sidebar.onSelect = { [weak self] index in self?.showSection(at: index) }
        // Settings always opens on General; no persisted section.
        if !sections.isEmpty { selectSection(at: 0) }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Select a section through the sidebar's REAL outline selection, exactly
    /// as a click on the row does — the pane swap then arrives back through
    /// `onSelect`. Tests drive this rather than a direct swap on purpose: a
    /// `test_` hook that bypassed real AppKit dispatch once let genuinely
    /// broken UI stay green across 78 tests (`MainOutRowView.selectionChanged`).
    public func selectSection(at index: Int) {
        sidebar.select(index: index)
    }

    private func showSection(at index: Int) {
        guard sections.indices.contains(index) else { return }
        paneHost.setContent(sections[index].viewController)
        selectedSectionIndex = index
    }

    /// One section's pane view, laid out (for `settings-snapshot` — the live
    /// surface isn't visible to an agent shell).
    public func paneView(at index: Int) -> NSView {
        let paneView = sections[index].viewController.view
        paneView.layoutSubtreeIfNeeded()
        return paneView
    }

    /// The pane host's `WarmPanelView` canvas, for structural tests asserting
    /// D2's one-background rule.
    public var test_background: NSView? { paneHost.view }

    /// The pane view currently mounted in the host.
    public var test_hostedPaneView: NSView? { paneHost.hostedPaneView }

    /// The scroll view's document height — what a tall pane actually scrolls.
    public var test_scrollDocumentHeight: CGFloat { paneHost.documentHeight }

    /// The sidebar's split item, for the pinned-thickness/no-collapse guard.
    public var test_sidebarSplitItem: NSSplitViewItem { splitViewItems[0] }
}

/// A document view whose origin is at its TOP, so a pane shorter than the
/// scroll view starts at the top rather than bottom-gravitating.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The right-hand side: the warm canvas, a transparent overlay-scroller scroll
/// view, and whichever section's pane is mounted — pinned on all four edges to
/// the flipped document at REQUIRED priority, so the document is exactly as
/// tall as the pane needs and never stretches it.
@MainActor
private final class SettingsPaneHostViewController: NSViewController {

    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private var currentChild: NSViewController?

    /// The pane view currently mounted, if any.
    var hostedPaneView: NSView? { currentChild?.viewIfLoaded }

    var documentHeight: CGFloat {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        return document.frame.height
    }

    override func loadView() {
        // The ONE surface canvas (owner decision D2): every screen sits on the
        // Groups content pane's flat warm `panel` fill. Opaque by
        // construction, so no Reduce Transparency cover is needed.
        let background = WarmPanelView()

        document.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        background.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),

            // As wide as the pane column, as tall as the pane needs —
            // vertical scrolling only, never horizontal.
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        view = background
    }

    /// Swap the hosted section, re-parenting it as a real child controller
    /// (not just a subview) so the responder chain stays correct.
    func setContent(_ child: NSViewController) {
        loadViewIfNeeded()
        guard currentChild !== child else { return }
        if let currentChild {
            currentChild.view.removeFromSuperview()
            currentChild.removeFromParent()
        }
        addChild(child)
        let paneView = child.view
        paneView.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: document.topAnchor),
            paneView.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            paneView.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        currentChild = child
        // A section always opens at its top, never wherever the previous one
        // happened to be scrolled to.
        scrollView.contentView.scroll(to: .zero)
    }
}
