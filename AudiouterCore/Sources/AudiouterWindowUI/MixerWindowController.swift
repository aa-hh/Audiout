// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The Groups SCREEN's content controller (one-surface app, roadmap 032): a
/// CONFIGURATION-ONLY owner of the groups sidebar/editor plumbing. Viewing or
/// editing a group here NEVER activates it or moves audio — activation lives
/// in the Mixer screen.
///
/// It owns an `NSSplitViewController` whose sidebar item is a source-list
/// `NSOutlineView` (`SidebarViewController`) and whose content item is swapped
/// between four panes: the group editor (`GroupEditorViewController`, when a
/// group is selected), the device detail pane (`DeviceDetailViewController`,
/// when a device is selected), the whole-mix `MainOutDetailViewController`
/// (the sidebar's "Main Audio" row), and an empty "No groups yet" pane
/// (nothing to select). It owns NO window: the app's
/// `AppSurfaceController` hosts `contentController` as the surface's Groups
/// screen and tells this controller when that screen is visible via
/// `setHostVisible(_:)` (the standalone Groups window was retired in U6).
///
/// AUTO-SELECT: with no sidebar selection the controller selects the FIRST
/// saved group and shows its editor; with no groups at all it shows the empty
/// pane. The content area is never a no-op view.
///
/// Group creation is a standard macOS sheet (`GroupCreationSheetController`)
/// presented over the hosting window; creating a group never activates it
/// either — the caller only selects the resolved group in the sidebar and
/// opens its editor.
///
/// Device icons (per-device SF Symbol overrides) resolve through the injected
/// `DeviceIconController`, shared with the sidebar, editor, creation sheet, and
/// detail pane so every surface renders the same glyph; its `onChange`
/// re-drives `refreshAll()` so a pick anywhere updates everywhere.
///
/// Everything group-related goes through the injected `GroupController`
/// (UI-agnostic, unit-tested in core) — this controller never does mixer math
/// and never calls `activateGroup`. `@MainActor` because it touches AppKit and
/// the non-`Sendable` `GroupController` only on the main thread; the app folds
/// backend events on `MainActor` before calling `update(devices:)`.
///
/// `public` so both the app and the headless `window-harness` / tests can
/// build it against a MockBackend-backed `GroupController` and assert its
/// structure. The create sheet is fully constructible and drivable headless
/// (see the `test_*` hooks).
@MainActor
public final class MixerWindowController {

    /// The UI-agnostic group model shared with the menu. Source of truth for
    /// groups; the screen reads it and writes through it, never around it.
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
    private let mainOutDetailViewController = MainOutDetailViewController()
    private let emptyStateViewController = GroupsEmptyStateViewController()

    /// Tone seams, wired by the app to the backend. This controller never
    /// calls a backend itself (`AGENTS.md`) — it only forwards what the two
    /// detail panes report.
    ///
    /// `onSetDeviceEQ` carries (eq, device id, committed); `onSetMainOutEQ`
    /// carries (eq, committed) — no id, it is the whole mix.
    public var onSetDeviceEQ: ((DeviceEQ, String, Bool) -> Void)?
    public var onSetMainOutEQ: ((DeviceEQ, Bool) -> Void)?
    /// Reads the whole mix's current tone when the Main Audio page opens.
    /// Pulled rather than pushed: the value lives on the backend, and this
    /// screen has no event to receive it on.
    public var mainOutEQProvider: (() -> DeviceEQ)?

    /// A selection that arrived before the snapshot carrying its device did —
    /// the popover's "Equalizer…" deep link can name a speaker this screen has
    /// never been told about (it is built lazily, on first open). Held here and
    /// applied at the end of the first `refreshAll()` in which the id exists.
    /// Only `.device` ever pends: `.group` and `.mainOut` resolve immediately
    /// or not at all.
    private var pendingSelection: SidebarSelection?

    /// Hosts the swapped content pane (editor / detail / empty) PLUS the
    /// persistent footer caption pinned beneath it. SCOPED TO THE CONTENT
    /// SPLIT ITEM ONLY — the sidebar split item runs the full height of the
    /// split view down to its own "New Group…" bar, with no footer stealing
    /// its bottom space (design review 2026-07-18: the footer used to wrap
    /// the whole split view, which left a gap above it under the sidebar
    /// too). The footer is content, not chrome — it ships wherever the
    /// content is hosted. See `AudiouterWindowUI/AGENTS.md`.
    private let contentHostViewController = ContentPaneHostViewController()

    /// The content split item — wraps `contentHostViewController`, which is
    /// never itself swapped; only its inner child (editor / detail / empty)
    /// changes as the sidebar selection changes.
    private let contentSplitItem: NSSplitViewItem

    /// The sidebar split item, kept so `refreshAll()` can re-assert that it is
    /// expanded. Collapsing it is unrecoverable — see the setup in `init`.
    private let sidebarSplitItem: NSSplitViewItem

    public init(groupController: GroupController,
               deviceIconController: DeviceIconController = DeviceIconController(loadPersisted: false)) {
        self.groupController = groupController
        self.deviceIconController = deviceIconController
        self.sidebarViewController = SidebarViewController()
        self.editorViewController = GroupEditorViewController(groupController: groupController)
        self.detailViewController = DeviceDetailViewController(groupController: groupController)

        // Share the one icon controller across every pane so a per-device
        // override picked anywhere renders identically everywhere.
        sidebarViewController.deviceIconController = deviceIconController
        editorViewController.deviceIconController = deviceIconController
        detailViewController.deviceIconController = deviceIconController

        // A PLAIN split item, NOT `.sidebar(withViewController:)` — the one
        // thing that keeps the surface's tab strip still. A split item with
        // `.sidebar` behavior anywhere in the window makes AppKit reserve the
        // toolbar's whole leading region for it, so every toolbar item starts
        // at the CONTENT pane's edge instead of the window's for as long as
        // this screen is mounted; the strip jumped ~210pt on every visit here
        // and jumped back on the Mixer (live build, 2026-08-22). Probed on a
        // real on-screen window, this is the ONLY cure: not
        // `allowsFullHeightLayout`, not a tracking separator item, not any
        // `toolbarStyle`, and not un-parenting the split controller — all of
        // those still reserve. The source-list LOOK is unaffected because it
        // never came from here: `SidebarViewController` sets
        // `outlineView.style = .sourceList` itself. What the constructor did
        // supply is the system sidebar material, and the sidebar's own
        // `SidebarWarmSurfaceView` draws its opaque backing instead (the
        // branch that already shipped to everyone below macOS 26).
        let sidebarItem = NSSplitViewItem(viewController: sidebarViewController)
        // PINNED at `SurfaceLayout.sidebarWidth` — minimum AND maximum,
        // deliberately (2026-08-12). The sidebar's own fitting width is
        // ≥260, and the split view hands an item its fitting width clamped
        // to `maximumThickness`; pinning min == max makes the split's whole
        // fitting width exactly `SurfaceLayout.width` (sidebar +
        // `GroupsPaneLayout.contentMaxWidth` + both column margins), which is
        // what lets it sit inside the one fixed surface frame without
        // widening it. 210, not the old 200 floor: 200 truncated "MacBook
        // Pro Speakers", the longest name every Mac has. The cost is a
        // divider the user can no longer drag; a longer name still
        // truncates, which is what a source list does anyway.
        sidebarItem.minimumThickness = SurfaceLayout.sidebarWidth
        sidebarItem.maximumThickness = SurfaceLayout.sidebarWidth
        // NOT collapsible: a collapse here is a ONE-WAY DOOR. The sidebar is
        // the only way to change selection, and nothing can bring it back —
        // the surface has no toolbar sidebar toggle and no View menu, and this
        // controller is built once and reused for the process lifetime — so a
        // collapsed sidebar strands the user on one group's editor for the
        // rest of the session. `refreshAll()` re-asserts it too: `canCollapse`
        // only refuses the USER's divider drag, and AppKit still auto-collapses
        // a sidebar item laid out narrower than its items' minimums.
        sidebarItem.canCollapse = false
        sidebarSplitItem = sidebarItem

        // Content item — wraps the footer-bearing host, which starts on the
        // empty pane; the first refresh auto-selects a group when one exists.
        contentHostViewController.setContent(emptyStateViewController)
        contentSplitItem = NSSplitViewItem(viewController: contentHostViewController)

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentSplitItem)

        // Load the split tree eagerly — the retired window's
        // `contentViewController` assignment used to do this
        // implicitly. The sidebar's outline view must exist before the first
        // `refreshAll()`/auto-select runs, and those run on `update(devices:)`
        // before any host has mounted the content.
        splitViewController.loadViewIfNeeded()

        // The panes report tone gestures; this controller forwards them
        // untouched to whoever owns the backend.
        detailViewController.onSetEQ = { [weak self] eq, id, committed in
            self?.onSetDeviceEQ?(eq, id, committed)
        }
        mainOutDetailViewController.onSetEQ = { [weak self] eq, committed in
            self?.onSetMainOutEQ?(eq, committed)
        }

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
        // Context-menu "Rename…" / double-click on a group row: open its
        // editor and drop focus straight into the rename field.
        sidebarViewController.onRequestRename = { [weak self] groupID in
            guard let self else { return }
            self.sidebarViewController.select(.group(id: groupID), notify: false)
            self.showEditor(for: groupID)
            self.editorViewController.focusRenameField()
        }
        // Context-menu "Delete Group…": open the group's editor and run the
        // same confirm-then-delete flow its button does.
        sidebarViewController.onRequestDelete = { [weak self] groupID in
            guard let self else { return }
            self.sidebarViewController.select(.group(id: groupID), notify: false)
            self.showEditor(for: groupID)
            self.editorViewController.requestDelete()
        }
        // The empty pane's call-to-action runs the same creation sheet.
        emptyStateViewController.onNewGroup = { [weak self] in
            self?.presentCreateSheet(preselected: [])
        }
        // The editor's "Delete Group…" falls back to the default content (the
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

    // MARK: App integration

    /// Test seam: simulate the content being visible so `update(devices:)`
    /// exercises its refresh path headlessly (no real WindowServer window in
    /// `swift test`). Mirrors `PopoverController.test_isShownOverride` exactly
    /// (same B8 problem, same fix shape, one host each).
    public var test_isVisibleOverride = false

    private var hostIsVisible = false

    /// Set by the host showing ``contentController`` (the one surface's Groups
    /// screen), so the refresh gate below asks about the content the user is
    /// actually looking at. Turning it on
    /// refreshes immediately: `update(devices:)` kept storing snapshots while
    /// hidden, so there is always a current one to catch up to.
    /// `PopoverController.surfaceDidShow()` is the same idea, one host over.
    public func setHostVisible(_ visible: Bool) {
        hostIsVisible = visible
        if visible { refreshAll() }
    }

    /// Whether the content should be treated as visible for refresh-gating
    /// purposes — a host showing this content, or the test override. Mirrors
    /// `PopoverController.isEffectivelyShown`.
    private var isEffectivelyVisible: Bool {
        hostIsVisible || test_isVisibleOverride
    }

    /// Push the latest device snapshot. Refreshes the sidebar and the visible
    /// content pane (auto-selecting a group if nothing was selected yet) —
    /// but ONLY while a host is showing the content (or the test override is
    /// set): this is called on every backend event for the app's entire
    /// lifetime once the Groups screen has been built once, so skipping the
    /// full rebuild while hidden avoids doing real work (sidebar node-tree
    /// rebuild + `NSOutlineView` reload + content-pane re-render) that nobody
    /// can see (B8, mirrors `PopoverController`'s identical fix for the same
    /// problem). `setHostVisible(true)` still refreshes unconditionally, so
    /// the screen always shows current data the moment it appears.
    public func update(devices: [Device]) {
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        guard isEffectivelyVisible else { return }
        refreshAll()
    }

    /// The root content view controller — the split view (sidebar full-height
    /// + the footer-bearing content host swapping editor/detail/empty panes).
    /// This is what the app's surface hosts as the Groups screen — one
    /// controller, whatever the host, footer included. Refreshing the content
    /// before handing it off keeps a freshly-hosted screen correct.
    public var contentController: NSViewController {
        refreshAll()
        return splitViewController
    }

    // MARK: Selection → content pane

    private func handleSidebarSelection(_ selection: SidebarSelection?) {
        switch selection {
        case .group(let id):
            // Selecting a group ONLY shows its editor (rename / membership /
            // delete). CONFIG-ONLY: selection never activates the group or moves
            // audio — activation lives in the Mixer screen, not here.
            showEditor(for: id)
            refreshSidebar()
        case .device(let id):
            // Selecting a device shows its detail pane. CONFIG-ONLY: this never
            // activates a group, changes routing, or moves audio.
            showDetail(for: id)
        case .mainOut:
            showMainOut()
        case .none:
            showDefaultContent()
        }
    }

    /// The screen's AUTO-SELECT rule (live-test feedback 2026-07-18): with no
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

    /// Show the detail pane for `deviceID` — the page that DESCRIBES and TUNES
    /// that speaker. Falls back to the default
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

    /// Show the whole-mix page. Nothing to look up — the one thing it renders
    /// is pulled from the app through `mainOutEQProvider` at open time.
    private func showMainOut() {
        shownDetailDeviceID = nil
        mainOutDetailViewController.show(eq: mainOutEQProvider?() ?? .flat)
        swapContent(to: mainOutDetailViewController)
    }

    private func showEditor(for groupID: String) {
        shownDetailDeviceID = nil
        editorViewController.show(groupID: groupID, devices: orderedDevices())
        swapContent(to: editorViewController)
    }

    /// Select `selection` from OUTSIDE the sidebar — the popover's
    /// "Equalizer…" deep link. Highlights the sidebar row (without re-firing
    /// `onSelect`, which would just call back into here) and shows the pane.
    ///
    /// A device this screen has not been told about yet PENDS rather than
    /// falling back to the default content: the Groups screen is built lazily,
    /// so the very first deep link can easily arrive before its first
    /// `update(devices:)`. The pending selection is applied at the end of the
    /// first `refreshAll()` whose snapshot carries the id.
    public func select(_ selection: SidebarSelection) {
        if case .device(let id) = selection, devicesByID[id] == nil {
            pendingSelection = selection
            return
        }
        pendingSelection = nil
        sidebarViewController.select(selection, notify: false)
        handleSidebarSelection(selection)
    }

    /// Apply a deep link that was waiting for its device to show up. Runs at
    /// the END of `refreshAll()` so it wins over the auto-select rule that ran
    /// earlier in the same pass.
    private func applyPendingSelection() {
        guard case .device(let id)? = pendingSelection, devicesByID[id] != nil else { return }
        let selection = pendingSelection!
        pendingSelection = nil
        sidebarViewController.select(selection, notify: false)
        handleSidebarSelection(selection)
    }

    /// The live group-creation sheet while it's up, so `refreshAll()` can leave
    /// it undisturbed and tests can drive it. `nil` when no sheet is presenting.
    private var createSheetController: GroupCreationSheetController?

    /// Present the standard macOS "New Group" sheet over the hosting window
    /// (revamp: replaces the old in-pane draft). The name is prefilled with the next
    /// "Group N"; `preselected` seeds the membership checklist (from a device
    /// multi-selection, or empty). On create: refresh, select the resolved group
    /// in the sidebar, and open its editor — NO activation, CONFIG-ONLY.
    ///
    /// Fully constructible/drivable headless: the controller is built and its
    /// `onComplete` wired unconditionally, but the actual sheet is only
    /// presented when the hosting window is on screen. Headless tests reach the live
    /// controller via `test_createSheet` and drive `test_commit()`/`test_cancel()`
    /// directly (the controller's `finish` skips `dismiss` when unhosted).
    private func presentCreateSheet(preselected: [String]) {
        let sheet = GroupCreationSheetController(groupController: groupController,
                                                deviceIconController: deviceIconController)
        let devices = orderedDevices()
        sheet.configure(defaultName: suggestedGroupName(preselected: preselected, devices: devices),
                        devices: devices,
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
        // whichever window currently hosts the content (the one surface's
        // shell). Gate on the split VC's OWN host window (`view.window`): an
        // on-screen host means there's a real sheet parent; headless runs
        // (host never shown) keep the reference and drive it via the test
        // hooks instead.
        if let host = splitViewController.view.window, host.isVisible {
            splitViewController.presentAsSheet(sheet)
        }
    }

    /// The name the create sheet prefills. A selection-seeded sheet names the
    /// group after what's in it ("Office + Sonos Move") instead of the
    /// meaningless "Group N" — the field is auto-focused with the text
    /// selected either way, so keeping the suggestion is one glance and
    /// replacing it is zero extra work.
    private func suggestedGroupName(preselected: [String], devices: [Device]) -> String {
        let names = preselected.compactMap { id in devices.first(where: { $0.id == id })?.name }
        switch names.count {
        case 0:  return "Group \(groupController.groups.count + 1)"
        case 1:  return names[0]
        case 2:  return "\(names[0]) + \(names[1])"
        default: return "\(names[0]) + \(names.count - 1) more"
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
        // A collapsed sidebar is unrecoverable (see the split-item setup), and
        // `canCollapse` does not stop AppKit collapsing it on its own. This
        // runs on mount and whenever the screen becomes visible — exactly when
        // it has to be whole.
        if sidebarSplitItem.isCollapsed { sidebarSplitItem.isCollapsed = false }

        let devices = orderedDevices()
        reloadSidebarIfNeeded(groups: groupController.groups,
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
        } else if currentContent === mainOutDetailViewController {
            // Nothing in a snapshot can invalidate the whole mix, and the page
            // owns its own in-flight tone state now (`MainOutDetailViewController
            // .pendingEdit`) — a per-event re-pull here bought nothing but a
            // `stateQueue.sync` on the main thread for every backend event
            // during a drag. The one legitimate pull is at `showMainOut()`,
            // on open.
        } else {
            // Empty pane showing: AUTO-SELECT kicks in as soon as a group
            // exists (first launch with persisted groups, or one created from
            // the popover's quick-save while this screen sat empty).
            if sidebarViewController.currentSelection == nil {
                showDefaultContent()
            }
        }

        applyPendingSelection()
    }

    /// Unconditional — callers of this one reach it after a user ACTION
    /// (renaming, deleting, group selection), so the sidebar must always
    /// reflect it immediately. Still records the projection reload gates on,
    /// so the NEXT `update(devices:)` compares against the truth rather than
    /// whatever the last snapshot-driven reload happened to see.
    private func refreshSidebar() {
        let groups = groupController.groups
        let activeGroupID = groupController.activeGroupID
        let devices = orderedDevices()
        lastSidebarProjection = sidebarProjection(groups: groups, activeGroupID: activeGroupID, devices: devices)
        sidebarViewController.reload(groups: groups, activeGroupID: activeGroupID, devices: devices)
        test_sidebarReloadCount += 1
    }

    /// Reload the sidebar only when what its cells actually RENDER changed.
    /// `update(devices:)` fires on every backend event for the app's whole
    /// lifetime, including an EQ-only change that no sidebar cell shows
    /// (SharedUI's device/group cells draw icon, name, membership/active
    /// marker, availability — never a tone value) — comparing this plain
    /// projection instead of rebuilding the node tree unconditionally is what
    /// turns that flood back into a no-op. Not a general diffing framework:
    /// one struct, one equality check.
    private func reloadSidebarIfNeeded(groups: [Group], activeGroupID: String?, devices: [Device]) {
        let projection = sidebarProjection(groups: groups, activeGroupID: activeGroupID, devices: devices)
        guard projection != lastSidebarProjection else { return }
        lastSidebarProjection = projection
        sidebarViewController.reload(groups: groups, activeGroupID: activeGroupID, devices: devices)
        test_sidebarReloadCount += 1
    }

    /// Exactly what the sidebar's cells render (`SidebarViewController`'s
    /// device/group row cell), named as one Equatable value so a reload can be
    /// gated on it changing rather than on the raw model arrays changing.
    private struct SidebarProjection: Equatable {
        struct GroupCell: Equatable {
            let id: String
            let name: String
            let iconSymbolName: String?
        }
        struct DeviceCell: Equatable {
            let id: String
            let name: String
            let kind: Device.Kind
            let isAvailable: Bool
            let iconSymbolName: String
        }
        let groups: [GroupCell]
        let activeGroupID: String?
        let devices: [DeviceCell]
    }

    private var lastSidebarProjection: SidebarProjection?

    private func sidebarProjection(
        groups: [Group], activeGroupID: String?, devices: [Device]
    ) -> SidebarProjection {
        SidebarProjection(
            groups: groups.map {
                .init(id: $0.id, name: $0.name, iconSymbolName: $0.iconSymbolName)
            },
            activeGroupID: activeGroupID,
            devices: devices.map {
                .init(id: $0.id, name: $0.name, kind: $0.kind, isAvailable: $0.isAvailable,
                      iconSymbolName: deviceIconController.symbolName(for: $0))
            })
    }

    private func orderedDevices() -> [Device] {
        devicesByID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: Test-support hooks
    //
    // The content isn't visible to a headless process, and AppKit won't
    // synthesize the clicks/drags a real interaction needs. These mirror exactly
    // what the sidebar / editor actions call, so `window-harness` and the test
    // suites can drive the same paths and assert structure + model state.

    /// The child controllers, for structural assertions.
    public var test_sidebar: SidebarViewController { sidebarViewController }
    public var test_editor: GroupEditorViewController { editorViewController }
    public var test_detail: DeviceDetailViewController { detailViewController }
    public var test_mainOutDetail: MainOutDetailViewController { mainOutDetailViewController }
    public var test_emptyState: GroupsEmptyStateViewController { emptyStateViewController }

    /// How many times the sidebar has actually been reloaded — proves the
    /// change-gate in ``reloadSidebarIfNeeded`` : an EQ-only `update(devices:)`
    /// must leave this unchanged, and a real sidebar-visible change must bump
    /// it exactly once.
    public private(set) var test_sidebarReloadCount = 0

    /// True when the editor pane is the visible content (vs detail/empty pane).
    public var test_isShowingEditor: Bool {
        currentContent === editorViewController
    }

    /// True when the read-only device detail pane is the visible content.
    public var test_isShowingDetail: Bool {
        currentContent === detailViewController
    }

    /// True when the whole-mix Main Audio page is the visible content.
    public var test_isShowingMainOut: Bool {
        currentContent === mainOutDetailViewController
    }

    /// The deep link still waiting for the device it names, or nil.
    public var test_pendingSelection: SidebarSelection? { pendingSelection }

    /// True when the "No groups yet" empty pane is the visible content.
    public var test_isShowingEmptyState: Bool {
        currentContent === emptyStateViewController
    }

    /// Simulate the user selecting a sidebar row (nil = deselect → AUTO-SELECT).
    public func test_select(_ selection: SidebarSelection?) {
        handleSidebarSelection(selection)
    }

    /// Drive the new-group creation path directly (mirrors the sidebar "+" and
    /// the empty pane's button).
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

    /// The persistent footer caption's text (always present, whatever hosts
    /// the content — see `ContentPaneHostViewController`).
    public var test_footerText: String { contentHostViewController.test_footerText }

    /// The height the persistent footer strip takes out of the screen's
    /// content area, so a test can derive the budget a swapped content pane
    /// actually gets: `screen content height − this`. The editor pane has
    /// no scroll view, so that budget is a hard ceiling, not a preference.
    public var test_contentPaneChromeHeight: CGFloat {
        contentHostViewController.test_chromeHeight
    }
}

// `WarmPanelView` — the flat `Tokens.Color.panel` canvas this screen's content
// pane introduced (Warm Signal §5.3, decision j) — moved to `AudiouterSharedUI`
// when the owner picked it as the ONE background every surface screen sits on
// (live build review 2026-08-07). This file keeps using it unchanged.

/// A one-token divider line. `draw(_:)`-based rather than a frozen layer color
/// for the same reason as `WarmPanelView`: `Tokens.Color.hairline` re-resolves
/// per appearance and Increase Contrast on every paint. Non-interactive — it is
/// pure chrome and must never swallow a click meant for what it borders.
final class HairlineView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Tokens.Color.hairline.setFill()
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
    /// visible. Pairs with, but
    /// doesn't duplicate, the empty state's lighter nudge
    /// (`GroupsEmptyStateViewController.subtitleLabel`): the footer is the one
    /// full teaching line; the empty-state subtitle is a shorter contextual
    /// nudge shown only when there's nothing else on screen.
    private let footerLabel = NSTextField(labelWithString: "Set up groups here — switch to the Mixer to play")

    /// The container the swapped child view fills; sits above the footer.
    private let contentContainer = NSView()

    /// Gap between the swapped content pane's bottom and the footer caption.
    private static let footerGap: CGFloat = 6
    /// Gap between the footer caption and the pane's bottom edge.
    private static let footerBottomInset: CGFloat = 8

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
        // sits on the warm `panel` canvas; the split view / sidebar / chrome
        // around it stay stock. The root of this host is that canvas.
        let root = WarmPanelView()
        // The seam between the chrome above and this warm pane (design
        // review 2026-07-25). Without it the two surfaces just abut: tolerable
        // in light mode, where both are near-white, but in dark mode the
        // chrome's COOL grey meets the pane's WARM near-black and the join
        // reads muddy rather than deliberate. A hairline makes it an edge on
        // purpose. Scoped to the content pane only — the sidebar runs the full
        // split-view height by design, so a border there would cut across it.
        let titleBarSeam = HairlineView()
        titleBarSeam.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)
        root.addSubview(footerLabel)
        root.addSubview(titleBarSeam)
        NSLayoutConstraint.activate([
            // The SAFE-AREA top, not the root's: in a `.fullSizeContentView`
            // host this pane extends UNDER the title bar and a seam at
            // `root.topAnchor` would be hidden behind it; with no overlapping
            // chrome the safe-area top IS the root's top.
            titleBarSeam.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            titleBarSeam.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBarSeam.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBarSeam.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: footerLabel.topAnchor,
                                                     constant: -Self.footerGap),
            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            footerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            footerLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                                constant: -Self.footerBottomInset),
        ])
        view = root
    }

    /// How much of this pane's height the persistent footer strip takes,
    /// leaving the rest to the swapped content pane. Derived from the real
    /// caption's fitting height plus the two gaps its constraints use — the
    /// height budget a content pane has to fit inside is
    /// `screen content height − THIS`.
    var test_chromeHeight: CGFloat {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        return footerLabel.fittingSize.height + Self.footerGap + Self.footerBottomInset
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
        // Re-seed Tab traversal after the swap (closes the KNOWN GAP the
        // A11Y-GROUPS seed left): re-parenting the content pane invalidates
        // the window's automatic key-view loop, and recalculation is reactive
        // — without this nudge Tab could die right after a sidebar selection
        // change. No-op headless (no window).
        view.window?.recalculateKeyViewLoop()
    }

    /// The persistent footer caption's text (structural test hook).
    var test_footerText: String { footerLabel.stringValue }
}

// MARK: - GroupsEmptyStateViewController

/// The "No groups yet" pane shown when there is nothing to select (stock
/// AppKit): a centered primary message, a secondary line teaching the
/// feature per §5.9's locked copy, and a "New Group…" button running the
/// same creation sheet as the sidebar's bottom-bar button. The whole message
/// block is one vertical stack centered on BOTH axes so it sits truly
/// centered in the pane rather than hanging off a hand-tuned offset.
public final class GroupsEmptyStateViewController: NSViewController {

    /// Fired when the call-to-action button is clicked.
    var onNewGroup: (() -> Void)?

    // Deliberately NOT "No groups yet" — the sidebar's own placeholder row
    // (a different file/owner) already says that right above this pane, so
    // repeating it here read as the same message twice on one screen. This
    // headline instead states the feature promise the subtitle explains.
    private let messageLabel = NSTextField(labelWithString: "Group your speakers")
    /// A PARAGRAPH, not a width driver. On one line this sentence measures
    /// ~480 pt, which made it the widest required thing on the whole Groups
    /// screen — AppKit widened the window to fit it, so the empty screen
    /// mounted ~85 pt wider than every other one (probed 2026-08-12). It wraps
    /// inside the form column's own measure instead (see `loadView`).
    private let subtitleLabel = NSTextField(wrappingLabelWithString:
        "Save a set of speakers as a group, then switch to it in two clicks from the menu bar.")
    private let newGroupButton = NSButton()

    /// The measure this pane's copy wraps to: the form column the editor and
    /// detail panes use, less this pane's own 16pt margins.
    private static let emptyPaneTextWidth: CGFloat = GroupsPaneLayout.contentMaxWidth - 32

    public override func loadView() {
        messageLabel.font = Tokens.Font.titleLarge
        messageLabel.textColor = Tokens.Color.secondaryLabel
        messageLabel.alignment = .center

        subtitleLabel.font = Tokens.Font.subtitleLarge
        subtitleLabel.textColor = Tokens.Color.tertiaryLabel
        subtitleLabel.alignment = .center
        subtitleLabel.isSelectable = false
        // Wraps within the form column's measure, minus this pane's own 16pt
        // margins — so the empty screen is exactly as wide as every other
        // Groups screen instead of setting the window's width by itself.
        subtitleLabel.preferredMaxLayoutWidth = Self.emptyPaneTextWidth
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        newGroupButton.title = "New Group…"
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
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.emptyPaneTextWidth),
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
