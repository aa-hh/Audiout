// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutedCore
import AudioutedSharedUI

/// The "Groups" window (design revamp): a CONFIGURATION-ONLY host for viewing
/// and editing saved groups. Viewing or editing a group here NEVER activates it
/// or moves audio — activation lives in the app's popover, not this window.
/// Owns:
/// - an `NSWindow` (titled "Groups") with `toolbarStyle = .unified` and a
///   `styleMask` including `.fullSizeContentView`;
/// - an `NSToolbar` (via `ToolbarController`) hosting ONLY a master-volume
///   `NSSlider` (the group-switcher presets popup was removed with the revamp —
///   nothing here switches the active group);
/// - an `NSSplitViewController` whose sidebar item is a source-list
///   `NSOutlineView` (`SidebarViewController`) and whose content item is swapped
///   between three panes as the sidebar selection changes: `MixerViewController`
///   (a device is deselected / nothing selected → all devices), the group editor
///   (`GroupEditorViewController`, when a group is selected), and the read-only
///   device detail pane (`DeviceDetailViewController`, when a device is selected).
///
/// Group creation is a standard macOS sheet (`GroupCreationSheetController`)
/// presented over the window, replacing the old in-pane unsaved-draft flow;
/// creating a group never activates it either — the caller only selects the
/// resolved group in the sidebar and opens its editor.
///
/// Device icons (per-device SF Symbol overrides) resolve through the injected
/// `DeviceIconController`, shared with the sidebar, mixer, editor, creation
/// sheet, and detail pane so every surface renders the same glyph; its
/// `onChange` re-drives `refreshAll()` so a pick anywhere updates everywhere.
///
/// Everything group/master/mute goes through the injected
/// `GroupController` (UI-agnostic, unit-tested in core) — the window never does
/// mixer math itself, exactly like the menu, and never calls `activateGroup`.
/// `@MainActor` because it touches AppKit and the non-`Sendable`
/// `GroupController` only on the main thread; the app folds backend events on
/// `MainActor` before calling `update(devices:)`.
///
/// The window is `public` so both the app (`AppDelegate.openMixer()`) and the
/// headless `window-harness` / tests can build it against a MockBackend-backed
/// `GroupController` and assert its structure. The create sheet is
/// fully constructible and drivable headless (see the `test_*` hooks).
@MainActor
public final class MixerWindowController: NSWindowController {

    /// The UI-agnostic mixer model shared with the menu. Source of truth for
    /// groups, the proportional master, and mute.
    private let groupController: GroupController

    /// Resolves/persists per-device icon overrides, shared with every child
    /// pane so the sidebar, mixer rows, editor/creation checklists, and the
    /// detail pane all render the same glyph for a device.
    private let deviceIconController: DeviceIconController

    /// Latest device snapshot the app pushed via `update(devices:)`, keyed by id.
    private var devicesByID: [String: Device] = [:]

    /// The device the detail pane is currently showing, so `refreshAll()` can
    /// re-render it from a fresher snapshot (or fall back to the mixer when the
    /// device has since disappeared). `nil` when the detail pane isn't showing.
    private var shownDetailDeviceID: String?

    // Child controllers.
    private let splitViewController = NSSplitViewController()
    private let sidebarViewController: SidebarViewController
    private let mixerViewController: MixerViewController
    private let editorViewController: GroupEditorViewController
    private let detailViewController: DeviceDetailViewController
    private let toolbarController: ToolbarController

    /// The content split item — its view controller is swapped between the
    /// mixer pane and the group-editor pane as the sidebar selection changes.
    private let contentSplitItem: NSSplitViewItem

    public init(groupController: GroupController,
               appRouting: AppRoutingController = AppRoutingController(loadPersisted: false),
               deviceIconController: DeviceIconController = DeviceIconController(loadPersisted: false)) {
        self.groupController = groupController
        self.deviceIconController = deviceIconController
        self.sidebarViewController = SidebarViewController()
        self.mixerViewController = MixerViewController(groupController: groupController, appRouting: appRouting)
        self.editorViewController = GroupEditorViewController(groupController: groupController)
        self.detailViewController = DeviceDetailViewController(groupController: groupController)
        self.toolbarController = ToolbarController()

        // Share the one icon controller across every pane so a per-device
        // override picked anywhere renders identically everywhere.
        sidebarViewController.deviceIconController = deviceIconController
        mixerViewController.deviceIconController = deviceIconController
        editorViewController.deviceIconController = deviceIconController
        detailViewController.deviceIconController = deviceIconController

        // Sidebar item — the documented `.sidebar(withViewController:)`
        // constructor applies source-list material/vibrancy + collapse behavior.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 200
        sidebarItem.canCollapse = true

        // Content item — starts on the mixer pane; swapped to the editor when a
        // group is selected.
        contentSplitItem = NSSplitViewItem(viewController: mixerViewController)

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentSplitItem)

        // Window chrome (SPEC §9): unified toolbar + full-size content view so
        // the content extends under the titlebar; `.titled/.closable/.resizable/
        // .miniaturizable` for a normal document-style window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Groups"
        window.toolbarStyle = .unified
        window.contentViewController = splitViewController
        window.setContentSize(NSSize(width: 720, height: 460))
        window.center()
        window.setFrameAutosaveName("MixerWindow")
        // No forced `NSAppearance` — dark/light "just work" (SPEC §9).

        super.init(window: window)

        // Toolbar (master slider only). The controller is the toolbar's
        // delegate; assign after the window exists.
        toolbarController.delegate = self
        let toolbar = NSToolbar(identifier: "MixerToolbar")
        toolbar.delegate = toolbarController
        toolbar.displayMode = .iconOnly
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        // Sidebar selection drives the detail pane.
        sidebarViewController.onSelect = { [weak self] selection in
            self?.handleSidebarSelection(selection)
        }
        // "+" with no selection → new-group creation sheet (revamp: standard
        // macOS sheet, PRIMARY path).
        sidebarViewController.onAddGroup = { [weak self] in
            self?.presentCreateSheet(preselected: [])
        }
        // "+" / context menu with devices multi-selected → creation sheet
        // pre-populated with exactly those speakers ("click on speakers and
        // multiselect to create a group").
        sidebarViewController.onNewGroupFromSelection = { [weak self] deviceIDs in
            self?.presentCreateSheet(preselected: deviceIDs)
        }
        // The editor's "Delete group…" pops us back to the mixer + a fresh
        // sidebar (the group is gone).
        editorViewController.onDidDeleteGroup = { [weak self] in
            self?.refreshAll()
            self?.showMixer(for: nil)
        }
        // Renames / membership edits refresh the sidebar labels + the toolbar
        // presets in place.
        editorViewController.onDidEditGroup = { [weak self] in
            self?.refreshSidebarAndToolbar()
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

    // MARK: App integration

    /// Push the latest device snapshot. Refreshes the sidebar, the visible
    /// detail pane, and the toolbar's master readout / presets.
    public func update(devices: [Device]) {
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        refreshAll()
    }

    /// Bring the window to front (called from the menu's "Open Mixer…").
    public func showWindow() {
        refreshAll()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open the window and immediately present the new-group creation sheet —
    /// the public entry the popover's Groups "+" uses, reusing the exact same
    /// sheet flow the sidebar "+" runs.
    public func beginNewGroup() {
        showWindow()
        presentCreateSheet(preselected: [])
    }

    // MARK: Selection → detail pane

    private func handleSidebarSelection(_ selection: SidebarSelection?) {
        switch selection {
        case .group(let id):
            // Selecting a group ONLY shows its editor (rename / membership /
            // delete). CONFIG-ONLY: selection never activates the group or moves
            // audio — activation lives in the popover, not this window.
            showEditor(for: id)
            refreshSidebarAndToolbar()
        case .device(let id):
            // Selecting a device shows its read-only detail pane. CONFIG-ONLY:
            // this never activates a group, changes routing, or moves audio.
            showDetail(for: id)
        case .none:
            showMixer(for: nil)
        }
    }

    /// Show the read-only detail pane for `deviceID`. Falls back to the mixer
    /// pane when the id isn't in the current snapshot (a stale selection) so the
    /// content area is never left on a device that no longer exists.
    private func showDetail(for deviceID: String) {
        guard let device = devicesByID[deviceID] else {
            shownDetailDeviceID = nil
            showMixer(for: nil)
            return
        }
        shownDetailDeviceID = deviceID
        detailViewController.show(device: device)
        swapContent(to: detailViewController)
    }

    /// Show the mixer pane. `groupID == nil` → "all devices"; otherwise the
    /// group's members. (The window's mixer always shows all known devices so
    /// individual ungrouped speakers are reachable — SPEC §9.)
    private func showMixer(for groupID: String?) {
        shownDetailDeviceID = nil
        mixerViewController.show(groupID: groupID, devices: orderedDevices())
        swapContent(to: mixerViewController)
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
        // Present as a sheet only when there's a window on screen to host it;
        // headless runs keep the reference and drive it via the test hooks.
        if let contentVC = window?.contentViewController, window?.isVisible == true {
            contentVC.presentAsSheet(sheet)
        }
    }

    private func swapContent(to controller: NSViewController) {
        let live = currentContentItem
        guard live.viewController !== controller else { return }
        let newItem = NSSplitViewItem(viewController: controller)
        splitViewController.removeSplitViewItem(live)
        splitViewController.addSplitViewItem(newItem)
        // Keep the reference current for the next swap.
        contentSplitItemRef = newItem
    }

    /// `NSSplitViewItem` is a wrapper we swap out; track the live content item so
    /// we can compare/replace it. `contentSplitItem` is the initial one; after
    /// the first swap `contentSplitItemRef` holds the current.
    private var contentSplitItemRef: NSSplitViewItem?
    private var currentContentItem: NSSplitViewItem { contentSplitItemRef ?? contentSplitItem }

    // MARK: Refresh

    private func refreshAll() {
        let devices = orderedDevices()
        sidebarViewController.reload(groups: groupController.groups,
                                     activeGroupID: groupController.activeGroupID,
                                     devices: devices)
        toolbarController.reload(activeGroupID: groupController.activeGroupID,
                                 masterVolume: groupController.masterVolume)
        // Refresh whichever detail pane is showing. The create sheet is a
        // separate presentation (not the content pane) — it is never disturbed
        // here. Group creation now lives in that sheet, so the editor always has
        // a persisted `editingGroupID` when it's up.
        if currentContentItem.viewController === editorViewController {
            if let id = editorViewController.editingGroupID {
                editorViewController.show(groupID: id, devices: devices)
            }
        } else if currentContentItem.viewController === detailViewController {
            // Re-render the detail pane from the fresher snapshot; if the shown
            // device has since disappeared, fall back to the mixer pane.
            if let id = shownDetailDeviceID, let device = devicesByID[id] {
                detailViewController.refresh(device: device)
            } else {
                showMixer(for: nil)
            }
        } else {
            mixerViewController.refresh(devices: devices)
        }
    }

    private func refreshSidebarAndToolbar() {
        let devices = orderedDevices()
        sidebarViewController.reload(groups: groupController.groups,
                                     activeGroupID: groupController.activeGroupID,
                                     devices: devices)
        toolbarController.reload(activeGroupID: groupController.activeGroupID,
                                 masterVolume: groupController.masterVolume)
    }

    private func orderedDevices() -> [Device] {
        devicesByID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: Test-support hooks
    //
    // The window isn't visible to a headless process, and AppKit won't
    // synthesize the clicks/drags a real interaction needs. These mirror exactly
    // what the toolbar / sidebar / editor actions call, so `window-harness` and
    // XCTest can drive the same paths and assert structure + model state.

    /// The live toolbar item identifiers, so a test can assert the window
    /// actually mounts the master-volume item (the `NSToolbar` delegate vends
    /// it lazily — an empty toolbar is a real bug).
    public var test_toolbarItemIdentifiers: [String] {
        (window?.toolbar?.items ?? []).map(\.itemIdentifier.rawValue)
    }

    /// The window's `toolbarStyle` (SPEC §9 asserts `.unified`).
    public var test_toolbarStyle: NSWindow.ToolbarStyle? { window?.toolbarStyle }

    /// True when the window's `styleMask` includes `.fullSizeContentView`
    /// (SPEC §9 window chrome).
    public var test_hasFullSizeContentView: Bool {
        window?.styleMask.contains(.fullSizeContentView) ?? false
    }

    /// The child controllers, for structural assertions.
    public var test_sidebar: SidebarViewController { sidebarViewController }
    public var test_mixer: MixerViewController { mixerViewController }
    public var test_editor: GroupEditorViewController { editorViewController }
    public var test_detail: DeviceDetailViewController { detailViewController }
    public var test_toolbar: ToolbarController { toolbarController }

    /// True when the editor pane is the visible content (vs the mixer/detail pane).
    public var test_isShowingEditor: Bool {
        currentContentItem.viewController === editorViewController
    }

    /// True when the read-only device detail pane is the visible content.
    public var test_isShowingDetail: Bool {
        currentContentItem.viewController === detailViewController
    }

    /// Simulate the user selecting a sidebar row.
    public func test_select(_ selection: SidebarSelection?) {
        handleSidebarSelection(selection)
    }

    /// Drive the new-group creation path directly (mirrors the sidebar "+" /
    /// "New Group from Selection" gestures and the popover's public
    /// `beginNewGroup()`). Builds and wires the sheet controller; headless it
    /// stays unpresented but fully drivable via `test_createSheet`.
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
}

// MARK: - ToolbarController.Delegate

extension MixerWindowController: ToolbarController.Delegate {

    public func toolbarDidBeginMasterDrag(_ controller: ToolbarController) {
        groupController.beginMasterDrag()
    }

    public func toolbarController(_ controller: ToolbarController, didSetMaster volume: Int) {
        groupController.setMasterVolume(volume)
        // The master echoes back into the toolbar readout + member rows once the
        // backend echoes `deviceUpdated` → `update(devices:)`.
    }

    public func toolbarDidEndMasterDrag(_ controller: ToolbarController) {
        groupController.endMasterDrag()
    }
}
