// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutedCore

/// The full mixer window (SPEC §9 "Full window"). Owns:
/// - an `NSWindow` with `toolbarStyle = .unified` and a `styleMask` including
///   `.fullSizeContentView`;
/// - an `NSToolbar` (via `ToolbarController`) hosting a master-volume
///   `NSSlider` + a presets `NSPopUpButton` (`pullsDown = false`);
/// - an `NSSplitViewController` whose sidebar item is a source-list
///   `NSOutlineView` (`SidebarViewController`) and whose content item is the
///   detail pane (`MixerViewController` for a mixer, or the group editor when a
///   group is selected).
///
/// Everything group/master/mute goes through the injected
/// `GroupController` (UI-agnostic, unit-tested in core) — the window never does
/// mixer math itself, exactly like the menu. `@MainActor` because it touches
/// AppKit and the non-`Sendable` `GroupController` only on the main thread; the
/// app folds backend events on `MainActor` before calling `update(devices:)`.
///
/// The window is `public` so both the app (`AppDelegate.openMixer()`) and the
/// headless `window-harness` / tests can build it against a MockBackend-backed
/// `GroupController` and assert its structure.
@MainActor
public final class MixerWindowController: NSWindowController {

    /// The UI-agnostic mixer model shared with the menu. Source of truth for
    /// groups, the proportional master, and mute.
    private let groupController: GroupController

    /// Latest device snapshot the app pushed via `update(devices:)`, keyed by id.
    private var devicesByID: [String: Device] = [:]

    // Child controllers.
    private let splitViewController = NSSplitViewController()
    private let sidebarViewController: SidebarViewController
    private let mixerViewController: MixerViewController
    private let editorViewController: GroupEditorViewController
    private let toolbarController: ToolbarController

    /// The content split item — its view controller is swapped between the
    /// mixer pane and the group-editor pane as the sidebar selection changes.
    private let contentSplitItem: NSSplitViewItem

    public init(groupController: GroupController,
               appRouting: AppRoutingController = AppRoutingController(loadPersisted: false)) {
        self.groupController = groupController
        self.sidebarViewController = SidebarViewController()
        self.mixerViewController = MixerViewController(groupController: groupController, appRouting: appRouting)
        self.editorViewController = GroupEditorViewController(groupController: groupController)
        self.toolbarController = ToolbarController()

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
        window.title = "Audiouted"
        window.toolbarStyle = .unified
        window.contentViewController = splitViewController
        window.setContentSize(NSSize(width: 720, height: 460))
        window.center()
        window.setFrameAutosaveName("MixerWindow")
        // No forced `NSAppearance` — dark/light "just work" (SPEC §9).

        super.init(window: window)

        // Toolbar (master slider + presets popup). The controller is the
        // toolbar's delegate; assign after the window exists.
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
        // "+" with no selection → new empty draft group (SPEC.md §9 manual
        // creation, PRIMARY path).
        sidebarViewController.onAddGroup = { [weak self] in
            self?.beginNewGroupDraft(preselected: [])
        }
        // "+" / context menu with devices multi-selected → draft pre-populated
        // with exactly those speakers (SPEC.md §9 — "click on speakers and
        // multiselect to create a group").
        sidebarViewController.onNewGroupFromSelection = { [weak self] deviceIDs in
            self?.beginNewGroupDraft(preselected: deviceIDs)
        }
        // Draft Save → activate + select the resolved group (dedup: an identical
        // set resolves to the existing group).
        editorViewController.onDidCreateGroup = { [weak self] group, _ in
            guard let self else { return }
            self.groupController.activateGroup(id: group.id)
            self.refreshAll()
            self.sidebarViewController.select(.group(id: group.id), notify: false)
            self.showEditor(for: group.id)
        }
        // Draft Cancel → discard, pop back to the mixer.
        editorViewController.onDidCancelCreate = { [weak self] in
            self?.showMixer(for: nil)
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

    /// Open the window and immediately begin a new-group draft — the public entry
    /// the popover's Groups "+" uses (task D), reusing the exact same
    /// manual-creation flow the sidebar "+" runs.
    public func beginNewGroup() {
        showWindow()
        beginNewGroupDraft(preselected: [])
    }

    // MARK: Selection → detail pane

    private func handleSidebarSelection(_ selection: SidebarSelection?) {
        switch selection {
        case .group(let id):
            // Selecting a group shows its editor (rename / membership / delete)
            // AND makes it the active output preset (SPEC §9 — one active group).
            groupController.activateGroup(id: id)
            showEditor(for: id)
            refreshSidebarAndToolbar()
        case .device, .none:
            showMixer(for: nil)
        }
    }

    /// Show the mixer pane. `groupID == nil` → "all devices"; otherwise the
    /// group's members. (The window's mixer always shows all known devices so
    /// individual ungrouped speakers are reachable — SPEC §9.)
    private func showMixer(for groupID: String?) {
        mixerViewController.show(groupID: groupID, devices: orderedDevices())
        swapContent(to: mixerViewController)
    }

    private func showEditor(for groupID: String) {
        editorViewController.show(groupID: groupID, devices: orderedDevices())
        swapContent(to: editorViewController)
    }

    /// Open the editor on a fresh empty draft (SPEC.md §9 manual creation). The
    /// name is prefilled with the next "Group N"; `preselected` seeds the
    /// membership checklist (from a device multi-selection, or empty).
    private func beginNewGroupDraft(preselected: [String]) {
        let name = "Group \(groupController.groups.count + 1)"
        editorViewController.showNewDraft(defaultName: name,
                                          devices: orderedDevices(),
                                          preselected: preselected)
        swapContent(to: editorViewController)
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
        toolbarController.reload(groups: groupController.groups,
                                 activeGroupID: groupController.activeGroupID,
                                 masterVolume: groupController.masterVolume)
        // Refresh whichever detail pane is showing. Don't rebuild an in-progress
        // draft (it has no persisted id yet and the user is mid-edit).
        if currentContentItem.viewController === editorViewController {
            if let id = editorViewController.editingGroupID {
                editorViewController.show(groupID: id, devices: devices)
            }
            // else: draft in progress — leave the editor untouched.
        } else {
            mixerViewController.refresh(devices: devices)
        }
    }

    private func refreshSidebarAndToolbar() {
        let devices = orderedDevices()
        sidebarViewController.reload(groups: groupController.groups,
                                     activeGroupID: groupController.activeGroupID,
                                     devices: devices)
        toolbarController.reload(groups: groupController.groups,
                                 activeGroupID: groupController.activeGroupID,
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
    /// actually mounts the master-volume + presets items (the `NSToolbar`
    /// delegate vends them lazily — an empty toolbar is a real bug).
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
    public var test_toolbar: ToolbarController { toolbarController }

    /// True when the editor pane is the visible content (vs the mixer pane).
    public var test_isShowingEditor: Bool {
        currentContentItem.viewController === editorViewController
    }

    /// Simulate the user selecting a sidebar row.
    public func test_select(_ selection: SidebarSelection?) {
        handleSidebarSelection(selection)
    }

    /// Simulate the presets popup picking a group (activates it — SPEC §9).
    public func test_selectPreset(groupID: String) {
        groupController.activateGroup(id: groupID)
        refreshAll()
    }

    /// Simulate clicking the sidebar "+" with no selection → new empty draft.
    public func test_tapAddGroup() {
        sidebarViewController.test_tapAdd()
    }

    /// Simulate multi-selecting devices then "New Group from Selection" (the
    /// "+"/context-menu gesture) — opens the draft editor pre-populated.
    public func test_newGroupFromSelection(_ deviceIDs: [String]) {
        sidebarViewController.test_selectDevices(deviceIDs)
        sidebarViewController.test_tapAdd()
    }

    /// True when the editor is showing an unsaved draft (create mode).
    public var test_isShowingDraft: Bool {
        test_isShowingEditor && editorViewController.isCreatingDraft
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

    public func toolbarController(_ controller: ToolbarController, didSelectPresetGroupID groupID: String?) {
        if let groupID {
            groupController.activateGroup(id: groupID)
        } else {
            groupController.deactivateGroup()
        }
        refreshAll()
    }
}
