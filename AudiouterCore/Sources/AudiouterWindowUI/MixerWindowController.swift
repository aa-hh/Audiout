// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The "Groups" window (design revamp): a CONFIGURATION-ONLY host for viewing
/// and editing saved groups. Viewing or editing a group here NEVER activates it
/// or moves audio — activation lives in the app's popover, not this window.
///
/// Live-test feedback 2026-07-18 removed the window's last two live-audio
/// surfaces: the "All Devices" mixer pane and the toolbar master slider are
/// GONE (volume lives in the popover). The window now owns:
/// - an `NSWindow` (titled "Groups", no toolbar) with a `styleMask` including
///   `.fullSizeContentView`;
/// - an `NSSplitViewController` whose sidebar item is a source-list
///   `NSOutlineView` (`SidebarViewController`) and whose content item is swapped
///   between three panes: the group editor (`GroupEditorViewController`, when a
///   group is selected), the read-only device detail pane
///   (`DeviceDetailViewController`, when a device is selected), and an empty
///   "No groups yet" pane (nothing to select).
///
/// AUTO-SELECT: with no sidebar selection the window selects the FIRST saved
/// group and shows its editor; with no groups at all it shows the empty pane.
/// The content area is never a no-op view.
///
/// Group creation is a standard macOS sheet (`GroupCreationSheetController`)
/// presented over the window; creating a group never activates it either — the
/// caller only selects the resolved group in the sidebar and opens its editor.
///
/// Device icons (per-device SF Symbol overrides) resolve through the injected
/// `DeviceIconController`, shared with the sidebar, editor, creation sheet, and
/// detail pane so every surface renders the same glyph; its `onChange`
/// re-drives `refreshAll()` so a pick anywhere updates everywhere.
///
/// Everything group-related goes through the injected `GroupController`
/// (UI-agnostic, unit-tested in core) — the window never does mixer math and
/// never calls `activateGroup`. `@MainActor` because it touches AppKit and the
/// non-`Sendable` `GroupController` only on the main thread; the app folds
/// backend events on `MainActor` before calling `update(devices:)`.
///
/// The window is `public` so both the app (`AppDelegate.openMixer()`) and the
/// headless `window-harness` / tests can build it against a MockBackend-backed
/// `GroupController` and assert its structure. The create sheet is
/// fully constructible and drivable headless (see the `test_*` hooks).
@MainActor
public final class MixerWindowController: NSWindowController {

    /// The UI-agnostic group model shared with the menu. Source of truth for
    /// groups; the window reads it and writes through it, never around it.
    private let groupController: GroupController

    /// Resolves/persists per-device icon overrides, shared with every child
    /// pane so the sidebar, editor/creation checklists, and the detail pane all
    /// render the same glyph for a device.
    private let deviceIconController: DeviceIconController

    /// Latest device snapshot the app pushed via `update(devices:)`, keyed by id.
    private var devicesByID: [String: Device] = [:]

    /// The device the detail pane is currently showing, so `refreshAll()` can
    /// re-render it from a fresher snapshot (or fall back to the default
    /// content when the device has since disappeared). `nil` when the detail
    /// pane isn't showing.
    private var shownDetailDeviceID: String?

    // Child controllers.
    private let splitViewController = NSSplitViewController()
    private let sidebarViewController: SidebarViewController
    private let editorViewController: GroupEditorViewController
    private let detailViewController: DeviceDetailViewController
    private let emptyStateViewController = GroupsEmptyStateViewController()

    /// Hosts the swapped content pane (editor / detail / empty) PLUS the
    /// persistent footer caption pinned beneath it. SCOPED TO THE CONTENT
    /// SPLIT ITEM ONLY — the sidebar split item runs the full height of the
    /// split view down to its own "New Group" bar, with no footer stealing
    /// its bottom space (design review 2026-07-18: the footer used to wrap
    /// the whole split view, which left a gap above it under the sidebar
    /// too). The footer is content, not chrome, so it is NEVER flag-gated by
    /// `AIRPLAY_CONTROL_PANEL` and shows identically in the standalone window
    /// and the control-panel shell. See `AudiouterWindowUI/AGENTS.md`.
    private let contentHostViewController = ContentPaneHostViewController()

    /// The content split item — wraps `contentHostViewController`, which is
    /// never itself swapped; only its inner child (editor / detail / empty)
    /// changes as the sidebar selection changes.
    private let contentSplitItem: NSSplitViewItem

    public init(groupController: GroupController,
               appRouting: AppRoutingController = AppRoutingController(loadPersisted: false),
               deviceIconController: DeviceIconController = DeviceIconController(loadPersisted: false),
               frameAutosaveName: NSWindow.FrameAutosaveName = "MixerWindow") {
        self.groupController = groupController
        self.deviceIconController = deviceIconController
        self.sidebarViewController = SidebarViewController()
        self.editorViewController = GroupEditorViewController(groupController: groupController)
        self.detailViewController = DeviceDetailViewController(groupController: groupController)
        _ = appRouting   // kept for call-site compatibility; the mixer pane that used it is gone

        // Share the one icon controller across every pane so a per-device
        // override picked anywhere renders identically everywhere.
        sidebarViewController.deviceIconController = deviceIconController
        editorViewController.deviceIconController = deviceIconController
        detailViewController.deviceIconController = deviceIconController

        // Sidebar item — the documented `.sidebar(withViewController:)`
        // constructor applies source-list material/vibrancy + collapse behavior.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 200
        sidebarItem.canCollapse = true

        // Content item — wraps the footer-bearing host, which starts on the
        // empty pane; the first refresh auto-selects a group when one exists.
        contentHostViewController.setContent(emptyStateViewController)
        contentSplitItem = NSSplitViewItem(viewController: contentHostViewController)

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentSplitItem)

        // Window chrome: full-size content view, NO toolbar (the master slider
        // left with the mixer pane — live-test feedback 2026-07-18). The split
        // view IS the window's content controller now — the sidebar item runs
        // the full window height; only the content item hosts the footer.
        let (window, hasSavedFrame) = Self.makeContainer(autosaveName: frameAutosaveName)
        // `setFrameAutosaveName` (inside `makeContainer()`) already restored the
        // user's last frame into `window.frame` SYNCHRONOUSLY if one was saved —
        // capture it now, before `contentViewController` is assigned, because
        // assigning a content view controller whose view hasn't been laid out
        // yet collapses the window to that view's near-zero intrinsic size.
        // Re-apply the restored frame explicitly afterward so a real user's
        // saved position/size survive a relaunch; only a truly first-ever
        // window (no saved frame yet) falls back to the default size +
        // `center()`. Skipping this check and unconditionally calling
        // `setContentSize`/`center()` here silently discarded every restored
        // frame on every launch — the window LOOKED like it remembered its
        // position only because `AppDelegate` builds this controller once and
        // reuses it for the rest of the process's life, so closing/reopening
        // the window within one run never re-ran this code at all.
        let restoredFrame = window.frame
        window.contentViewController = splitViewController
        if hasSavedFrame {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.setContentSize(NSSize(width: 720, height: 460))
            window.center()
        }
        // No forced `NSAppearance` — dark/light "just work" (SPEC §9).

        super.init(window: window)

        // Sidebar selection drives the content pane.
        sidebarViewController.onSelect = { [weak self] selection in
            self?.handleSidebarSelection(selection)
        }
        // "+" with no selection → new-group creation sheet (revamp: standard
        // macOS sheet, PRIMARY path).
        sidebarViewController.onAddGroup = { [weak self] in
            self?.presentCreateSheet(preselected: [])
        }
        // "+" with devices multi-selected → creation sheet pre-populated with
        // exactly those speakers.
        sidebarViewController.onNewGroupFromSelection = { [weak self] deviceIDs in
            self?.presentCreateSheet(preselected: deviceIDs)
        }
        // The empty pane's call-to-action runs the same creation sheet.
        emptyStateViewController.onNewGroup = { [weak self] in
            self?.presentCreateSheet(preselected: [])
        }
        // The editor's "Delete group…" falls back to the default content (the
        // next remaining group's editor, or the empty pane).
        editorViewController.onDidDeleteGroup = { [weak self] in
            self?.refreshAll()
            self?.showDefaultContent()
        }
        // Renames / membership edits refresh the sidebar labels in place.
        editorViewController.onDidEditGroup = { [weak self] in
            self?.refreshSidebar()
        }
        // An icon override picked in any pane repaints every surface. Chain onto
        // any existing observer rather than clobbering it — the controller is
        // shared and another owner may already be listening.
        let previousIconChange = deviceIconController.onChange
        deviceIconController.onChange = { [weak self] in
            previousIconChange?()
            self?.refreshAll()
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Build the shipping document-style `NSWindow` container. The control-panel
    /// rollout hosts this same content in a sticky floating panel instead — that
    /// shell (`ControlPanelWindowController` in `AudiouterSharedUI`) is a separate
    /// type that hosts `contentViewController`; this controller only ever builds
    /// the window.
    ///
    /// Returns whether a previously-saved frame under the given autosave
    /// name was found and synchronously applied, so the caller knows whether
    /// it's safe to fall back to the default size + `center()` — a caller that
    /// unconditionally re-sizes/re-centers afterward silently throws the
    /// restore away.
    ///
    /// Deliberately calls `setFrameUsingName` FIRST, not `setFrameAutosaveName`
    /// alone: `setFrameAutosaveName`'s own Bool return is NOT a trustworthy
    /// signal for "was a frame actually restored" — verified empirically, it
    /// returns `true` even for a brand-new name with nothing ever saved (its
    /// return value means something else undocumented, not "restored").
    /// `setFrameUsingName` is the API that both restores a saved frame AND
    /// reliably reports whether it found one. `setFrameAutosaveName` is called
    /// afterward purely to ARM ongoing autosave-on-move/resize for this window
    /// going forward; re-applying an already-restored frame is a harmless no-op.
    private static func makeContainer(autosaveName: NSWindow.FrameAutosaveName) -> (window: NSWindow, hasSavedFrame: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Groups"
        let hasSavedFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        // Summon onto the CURRENT Space (and over a fullscreen app) instead of
        // switching Spaces to the window's home — reopening a config window must
        // not yank the user out of what they're doing (window-panel.md M1).
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        return (window, hasSavedFrame)
    }

    // MARK: App integration

    /// Test seam: simulate the window being visible so `update(devices:)`
    /// exercises its refresh path headlessly (no real WindowServer window in
    /// `swift test`). Mirrors `PopoverController.test_isShownOverride` exactly
    /// (same B8 problem, same fix shape, one host each).
    public var test_isWindowVisibleOverride = false

    /// Whether the window should be treated as visible for refresh-gating
    /// purposes — the real `window?.isVisible` OR the test override above.
    /// Mirrors `PopoverController.isEffectivelyShown`.
    private var isEffectivelyVisible: Bool { (window?.isVisible ?? false) || test_isWindowVisibleOverride }

    /// Push the latest device snapshot. Refreshes the sidebar and the visible
    /// content pane (auto-selecting a group if nothing was selected yet) —
    /// but ONLY while the window is actually visible (or the test override is
    /// set): this is called on every backend event for the app's entire
    /// lifetime once the window has been opened once, so skipping the full
    /// rebuild while closed avoids doing real work (sidebar node-tree rebuild
    /// + `NSOutlineView` reload + content-pane re-render) that nobody can see
    /// (B8, mirrors `PopoverController`'s identical fix for the same problem).
    /// `showWindow()` below still refreshes unconditionally on open, so the
    /// window always shows current data the moment it appears.
    public func update(devices: [Device]) {
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        guard isEffectivelyVisible else { return }
        refreshAll()
    }

    /// Bring the window to front (called from the popover's Groups button).
    /// Never actually orders the window on screen under `swift test` or a
    /// harness/snapshot tool (`HeadlessRuntime`) — those hold a real
    /// WindowServer connection, so an un-gated order-front here would flash a
    /// real, empty window on the developer's actual screen. `refreshAll()`
    /// still runs so headless assertions stay exactly as strong.
    public func showWindow() {
        refreshAll()
        guard !HeadlessRuntime.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The root content view controller — the split view (sidebar full-height
    /// + the footer-bearing content host swapping editor/detail/empty panes).
    /// Exposed so the shared control-panel shell (`ControlPanelWindowController`)
    /// can host the exact same content the standalone window shows — one
    /// controller, two possible hosts, footer included in both (it is not
    /// flag-gated; it lives under the content pane only, not the sidebar).
    /// Refreshing the content before handing it off keeps a freshly-hosted
    /// panel correct.
    /// (Named `contentController`, not `contentViewController`, to avoid
    /// overriding `NSWindowController`'s optional `contentViewController`.)
    public var contentController: NSViewController {
        refreshAll()
        return splitViewController
    }

    /// Open the window and immediately present the new-group creation sheet —
    /// the public entry the popover's Groups "+" uses, reusing the exact same
    /// sheet flow the sidebar "+" runs.
    public func beginNewGroup() {
        showWindow()
        presentCreateSheet(preselected: [])
    }

    // MARK: Selection → content pane

    private func handleSidebarSelection(_ selection: SidebarSelection?) {
        switch selection {
        case .group(let id):
            // Selecting a group ONLY shows its editor (rename / membership /
            // delete). CONFIG-ONLY: selection never activates the group or moves
            // audio — activation lives in the popover, not this window.
            showEditor(for: id)
            refreshSidebar()
        case .device(let id):
            // Selecting a device shows its read-only detail pane. CONFIG-ONLY:
            // this never activates a group, changes routing, or moves audio.
            showDetail(for: id)
        case .none:
            showDefaultContent()
        }
    }

    /// The window's AUTO-SELECT rule (live-test feedback 2026-07-18): with no
    /// explicit selection, select the first saved group and show its editor;
    /// with no groups at all, show the empty "No groups yet" pane.
    private func showDefaultContent() {
        if let first = groupController.groups.first {
            sidebarViewController.select(.group(id: first.id), notify: false)
            showEditor(for: first.id)
        } else {
            shownDetailDeviceID = nil
            swapContent(to: emptyStateViewController)
        }
    }

    /// Show the read-only detail pane for `deviceID`. Falls back to the default
    /// content when the id isn't in the current snapshot (a stale selection) so
    /// the content area is never left on a device that no longer exists.
    private func showDetail(for deviceID: String) {
        guard let device = devicesByID[deviceID] else {
            shownDetailDeviceID = nil
            showDefaultContent()
            return
        }
        shownDetailDeviceID = deviceID
        detailViewController.show(device: device)
        swapContent(to: detailViewController)
    }

    private func showEditor(for groupID: String) {
        shownDetailDeviceID = nil
        editorViewController.show(groupID: groupID, devices: orderedDevices())
        swapContent(to: editorViewController)
    }

    /// The live group-creation sheet while it's up, so `refreshAll()` can leave
    /// it undisturbed and tests can drive it. `nil` when no sheet is presenting.
    private var createSheetController: GroupCreationSheetController?

    /// Present the standard macOS "New Group" sheet over the window (revamp:
    /// replaces the old in-pane draft). The name is prefilled with the next
    /// "Group N"; `preselected` seeds the membership checklist (from a device
    /// multi-selection, or empty). On create: refresh, select the resolved group
    /// in the sidebar, and open its editor — NO activation, CONFIG-ONLY.
    ///
    /// Fully constructible/drivable headless: the controller is built and its
    /// `onComplete` wired unconditionally, but the actual sheet is only
    /// presented when the window is on screen. Headless tests reach the live
    /// controller via `test_createSheet` and drive `test_commit()`/`test_cancel()`
    /// directly (the controller's `finish` skips `dismiss` when unhosted).
    private func presentCreateSheet(preselected: [String]) {
        let sheet = GroupCreationSheetController(groupController: groupController,
                                                deviceIconController: deviceIconController)
        sheet.configure(defaultName: "Group \(groupController.groups.count + 1)",
                        devices: orderedDevices(),
                        preselected: Set(preselected))
        sheet.onComplete = { [weak self] result in
            guard let self else { return }
            self.createSheetController = nil
            guard let result else { return }   // cancelled
            self.refreshAll()
            self.sidebarViewController.select(.group(id: result.group.id), notify: false)
            self.showEditor(for: result.group.id)
        }
        createSheetController = sheet
        // Present the sheet over the split view controller so it re-parents to
        // whichever window currently hosts the content — the standalone window
        // OR the shared control-panel shell. Gate on the split VC's OWN host
        // window (`view.window`), NOT `self.window?.isVisible`: when the content
        // is hosted in the shell, this controller's own `window` is off screen
        // but the content is on screen in the panel, so `self.window` is the
        // wrong window to consult. An on-screen host means there's a real sheet
        // parent; headless runs (host never shown) keep the reference and drive
        // it via the test hooks instead.
        if let host = splitViewController.view.window, host.isVisible {
            splitViewController.presentAsSheet(sheet)
        }
    }

    /// Swap the pane shown INSIDE `contentHostViewController` (editor / detail
    /// / empty). The content split item itself is never swapped anymore — only
    /// its inner child changes — so the footer beneath it never moves and the
    /// sidebar item is untouched by any of this.
    private func swapContent(to controller: NSViewController) {
        contentHostViewController.setContent(controller)
    }

    /// The view controller currently shown inside the content host (editor /
    /// detail / empty pane), for structural comparisons.
    private var currentContent: NSViewController? { contentHostViewController.currentChild }

    // MARK: Refresh

    private func refreshAll() {
        let devices = orderedDevices()
        sidebarViewController.reload(groups: groupController.groups,
                                     activeGroupID: groupController.activeGroupID,
                                     devices: devices)
        // Refresh whichever content pane is showing. The create sheet is a
        // separate presentation (not the content pane) — it is never disturbed
        // here.
        if currentContent === editorViewController {
            if let id = editorViewController.editingGroupID,
               groupController.groups.contains(where: { $0.id == id }) {
                editorViewController.show(groupID: id, devices: devices)
            } else {
                // The edited group disappeared (deleted elsewhere) — fall back.
                showDefaultContent()
            }
        } else if currentContent === detailViewController {
            // Re-render the detail pane from the fresher snapshot; if the shown
            // device has since disappeared, fall back to the default content.
            if let id = shownDetailDeviceID, let device = devicesByID[id] {
                detailViewController.refresh(device: device)
            } else {
                showDefaultContent()
            }
        } else {
            // Empty pane showing: AUTO-SELECT kicks in as soon as a group
            // exists (first launch with persisted groups, or one created from
            // the popover's quick-save while this window sat empty).
            if sidebarViewController.currentSelection == nil {
                showDefaultContent()
            }
        }
    }

    private func refreshSidebar() {
        sidebarViewController.reload(groups: groupController.groups,
                                     activeGroupID: groupController.activeGroupID,
                                     devices: orderedDevices())
    }

    private func orderedDevices() -> [Device] {
        devicesByID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: Test-support hooks
    //
    // The window isn't visible to a headless process, and AppKit won't
    // synthesize the clicks/drags a real interaction needs. These mirror exactly
    // what the sidebar / editor actions call, so `window-harness` and XCTest can
    // drive the same paths and assert structure + model state.

    /// True when the window's `styleMask` includes `.fullSizeContentView`
    /// (SPEC §9 window chrome).
    public var test_hasFullSizeContentView: Bool {
        window?.styleMask.contains(.fullSizeContentView) ?? false
    }

    /// True when the window mounts no toolbar (live-test feedback 2026-07-18:
    /// the master slider left with the mixer pane — nothing here touches audio).
    public var test_hasNoToolbar: Bool { window?.toolbar == nil }

    /// The child controllers, for structural assertions.
    public var test_sidebar: SidebarViewController { sidebarViewController }
    public var test_editor: GroupEditorViewController { editorViewController }
    public var test_detail: DeviceDetailViewController { detailViewController }
    public var test_emptyState: GroupsEmptyStateViewController { emptyStateViewController }

    /// True when the editor pane is the visible content (vs detail/empty pane).
    public var test_isShowingEditor: Bool {
        currentContent === editorViewController
    }

    /// True when the read-only device detail pane is the visible content.
    public var test_isShowingDetail: Bool {
        currentContent === detailViewController
    }

    /// True when the "No groups yet" empty pane is the visible content.
    public var test_isShowingEmptyState: Bool {
        currentContent === emptyStateViewController
    }

    /// Simulate the user selecting a sidebar row (nil = deselect → AUTO-SELECT).
    public func test_select(_ selection: SidebarSelection?) {
        handleSidebarSelection(selection)
    }

    /// Drive the new-group creation path directly (mirrors the sidebar "+" /
    /// the empty pane's button and the popover's public `beginNewGroup()`).
    /// Builds and wires the sheet controller; headless it stays unpresented but
    /// fully drivable via `test_createSheet`.
    public func test_presentCreateSheet(preselected: [String]) {
        presentCreateSheet(preselected: preselected)
    }

    /// The live group-creation sheet controller, or nil when none is up — so a
    /// headless test can drive `test_commit()` / `test_cancel()` on it.
    public var test_createSheet: GroupCreationSheetController? {
        createSheetController
    }

    /// True while a group-creation sheet is presenting (or, headless, wired).
    public var test_isPresentingCreateSheet: Bool {
        createSheetController != nil
    }

    /// The persistent footer caption's text (always present, window or panel,
    /// scoped to the content pane — see `ContentPaneHostViewController`).
    public var test_footerText: String { contentHostViewController.test_footerText }
}

// MARK: - WarmPanelView

/// The Groups window's CONTENT-PANE canvas (Warm Signal spec §5.3, decision
/// j: "content pane warm, chrome stock"): a flat, fully opaque fill of
/// `Tokens.Color.panel` — the warm surface one rung LIGHTER than the
/// popover's `canvas` gradient — with **no grain** (grain is the popover's
/// density texture, §1.1; a configuration window doesn't carry it) and no
/// gradient. The window CHROME around it (title bar, split view, sidebar
/// material, sheets) stays fully native and untouched; because the window is
/// `.fullSizeContentView`, the system title bar takes its tint from this
/// warm surface beneath it, exactly the §5 "the shell samples us" mechanism.
///
/// A `draw(_:)` override — deliberately NOT a frozen layer color — so the
/// token re-resolves live per appearance flip and Increase Contrast on every
/// paint (`WarmCanvasView`'s pattern; always opaque, so Reduce Transparency
/// needs no fallback branch).
final class WarmPanelView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Tokens.Color.panel.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - ContentPaneHostViewController

/// Hosts the swapped content pane (editor / detail / empty) plus the
/// persistent footer caption pinned beneath it. This exists so the footer is
/// scoped to the CONTENT split item only — the sidebar split item runs the
/// full height of the split view, with no footer stealing its bottom space
/// (design review 2026-07-18). `setContent(_:)` swaps the inner child view
/// controller; this host controller itself is never swapped, so the footer
/// never moves as the sidebar selection changes.
final class ContentPaneHostViewController: NSViewController {

    /// Persistent secondary-color caption beneath the content pane. ALWAYS
    /// visible — never gated by `AIRPLAY_CONTROL_PANEL`. Pairs with, but
    /// doesn't duplicate, the empty state's lighter nudge
    /// (`GroupsEmptyStateViewController.subtitleLabel`): the footer is the one
    /// full teaching line; the empty-state subtitle is a shorter contextual
    /// nudge shown only when there's nothing else on screen.
    private let footerLabel = NSTextField(labelWithString: "Set up here — play from the menu-bar icon")

    /// The container the swapped child view fills; sits above the footer.
    private let contentContainer = NSView()

    /// The currently-hosted child (editor / detail / empty pane), for
    /// structural comparisons. `nil` only before the first `setContent(_:)`.
    private(set) var currentChild: NSViewController?

    override func loadView() {
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = Tokens.Font.caption
        footerLabel.textColor = Tokens.Color.secondaryLabel
        footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byTruncatingTail

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        // Warm Signal §5.3: the CONTENT pane (swapped pane + footer strip)
        // sits on the warm `panel` canvas; the split view / sidebar / title
        // bar around it stay stock. The root of this host is that canvas.
        let root = WarmPanelView()
        root.addSubview(contentContainer)
        root.addSubview(footerLabel)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -6),
            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            footerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            footerLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root
    }

    /// Swap the hosted child, re-parenting it as a real child controller (not
    /// just a subview) so the responder chain stays correct.
    func setContent(_ child: NSViewController) {
        loadViewIfNeeded()
        guard currentChild !== child else { return }
        if let currentChild {
            currentChild.view.removeFromSuperview()
            currentChild.removeFromParent()
        }
        addChild(child)
        let childView = child.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            childView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        currentChild = child
    }

    /// The persistent footer caption's text (structural test hook).
    var test_footerText: String { footerLabel.stringValue }
}

// MARK: - GroupsEmptyStateViewController

/// The "No groups yet" pane shown when there is nothing to select (stock
/// AppKit): a centered primary message, a light secondary nudge in the
/// Warm Signal house voice (§5.9's "warm, concrete, one idea per line"
/// register), and a "New Group" button running the same creation sheet as
/// the sidebar's bottom-bar button. The whole message block is one vertical
/// stack centered on BOTH axes so it sits truly centered in the pane rather
/// than hanging off a hand-tuned offset.
public final class GroupsEmptyStateViewController: NSViewController {

    /// Fired when the call-to-action button is clicked.
    var onNewGroup: (() -> Void)?

    private let messageLabel = NSTextField(labelWithString: "No groups yet.")
    private let subtitleLabel = NSTextField(labelWithString: "Music first — rooms can come later.")
    private let newGroupButton = NSButton()

    public override func loadView() {
        messageLabel.font = Tokens.Font.titleLarge
        messageLabel.textColor = Tokens.Color.secondaryLabel
        messageLabel.alignment = .center

        subtitleLabel.font = Tokens.Font.subtitleLarge
        subtitleLabel.textColor = Tokens.Color.tertiaryLabel
        subtitleLabel.alignment = .center

        newGroupButton.title = "New Group"
        newGroupButton.bezelStyle = .rounded
        newGroupButton.target = self
        newGroupButton.action = #selector(newGroupTapped(_:))

        let stack = NSStackView(views: [messageLabel, subtitleLabel, newGroupButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(12, after: subtitleLabel)

        let container = NSView()
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])

        view = container
    }

    @objc private func newGroupTapped(_ sender: NSButton) {
        onNewGroup?()
    }

    /// Simulate clicking the call-to-action (headless test hook).
    public func test_tapNewGroup() { onNewGroup?() }

    /// The visible message text (for structural assertions).
    public var test_messageText: String { messageLabel.stringValue }

    /// The visible subtitle text (for structural assertions).
    public var test_subtitleText: String { subtitleLabel.stringValue }
}
