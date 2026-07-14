// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore
import AirPlayControllerSharedUI

/// Builds and owns the status-item **`NSPopover`** dropdown (SPEC §9 revised —
/// NSMenu → NSPopover; SoundSource-inspired Main Out model, 2026-07-14b).
///
/// Structure, top to bottom:
/// 1. **System section — a single "Main Out" row** (`MainOutRowView`): speaker
///    icon · "Main Out" · proportional master slider + `%` · a trailing
///    `NSPopUpButton` device selector. The selector is THE routing decision, with
///    two sections: "Selected Devices" and each saved Output Group.
/// 2. **"Selected Devices" section** — every discovered device, split into
///    **Current Device** (the Mac) and **AirPlay Devices**. Each row's toggle
///    switch = membership in the persistent Selected Devices set (SPEC §9b). The
///    toggle COMPOSES the set; it routes only when Main Out targets Selected
///    Devices (the default). The current-device toggle enforces the Phase-1
///    local-mix block (disabled + tooltip) and the AirPlay auto-swap rule.
/// 3. **Groups section** — one `GroupRowView` header per saved group (animated
///    expansion, per-group master). Activating a group here sets Main Out to that
///    group.
/// 4. **Actions footer** — "Save Selected Devices as group", "Open Mixer…", "Quit".
///
/// All group/master/mute/selection arithmetic goes through the injected
/// `GroupController` (UI-agnostic, unit-tested in core). `@MainActor`.
@MainActor
public final class PopoverController: NSObject, NSPopoverDelegate {

    public let popover = NSPopover()

    private var groupController: GroupController?
    private var devicesByID: [String: Device] = [:]

    /// Called when the user picks "Open Mixer…", the header's "Open Groups editor"
    /// button (task A — group membership editing lives in the mixer window), or
    /// otherwise wants the mixer window shown.
    public var onOpenMixer: (() -> Void)?

    /// Called when the user taps the Groups section header's "+" button (task D).
    /// The app opens the mixer window's new-group draft (matching how the window's
    /// own "+" works). Falls back to `onOpenMixer` if unset so the "+" always at
    /// least surfaces the editor.
    public var onNewGroup: (() -> Void)?

    /// Called when the user taps the header's Settings button (task A). Stubbed —
    /// no settings surface exists yet (`// TODO: settings`).
    public var onOpenSettings: (() -> Void)?

    private let panel = PopoverPanelViewController()

    /// The single System-section Main Out row.
    private let mainOutRow = MainOutRowView()

    private var expandedGroupIDs: Set<String> = []
    private var memberRowsByGroup: [String: [DeviceRowView]] = [:]
    private var deviceRowsByID: [String: DeviceRowView] = [:]
    private var groupRowsByID: [String: GroupRowView] = [:]

    private(set) public var test_lastAnimatedExpansion = false

    /// The most recent local-mix refusal reason surfaced to the user (so the app
    /// / tests can assert the block was presented). Cleared on the next
    /// successful selection change.
    private(set) public var test_lastRefusalReason: String?

    public override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = panel
        panel.controller = self
        mainOutRow.delegate = self
        // Header bar actions (task A): the "Open Groups editor" button opens the
        // mixer window (where group membership editing lives); Settings is stubbed.
        panel.setHeaderActions(
            onOpenGroupsEditor: { [weak self] in self?.onOpenMixer?() },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onQuit: { NSApp.terminate(nil) })
        rebuild()
    }

    // MARK: Injection from the app

    public func configure(groupController: GroupController) {
        self.groupController = groupController
        rebuild()
    }

    /// Push the latest device snapshot and repaint. Re-derives active-group state
    /// (defensive under a group target) and repaints mounted rows in place.
    public func update(devices: [Device]) {
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        groupController?.syncActiveGroupToSelection()
        if popover.isShown {
            refreshDeviceRows()
            refreshGroupRows()
            refreshMainOutRow()
        } else {
            rebuild()
        }
    }

    /// The master volume (0…1) the status symbol should reflect: the Main Out
    /// master of the current target (SPEC §9b — status icon reflects Main Out).
    public var statusMasterVolume: Double {
        guard let controller = groupController else { return 0 }
        return Double(controller.mainOutMasterVolume) / 100.0
    }

    // MARK: Show / hide

    public func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            rebuild()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: Build

    public func rebuild() {
        deviceRowsByID.removeAll()
        groupRowsByID.removeAll()
        memberRowsByGroup.removeAll()
        panel.clearRows()

        let groups = groupController?.groups ?? []
        let allDevices = orderedDevices()

        // 1. System card — the single Main Out row.
        panel.beginCard(header: "System")
        panel.addColumnHeader(volumeTitle: "Volume", enabledTitle: nil)
        panel.addRow(mainOutRow)
        refreshMainOutRow()

        // 2. Selected Devices card — split into Current Device + AirPlay.
        let locals = allDevices.filter(\.isLocalDevice)
        let airplay = allDevices.filter { !$0.isLocalDevice }
        if !locals.isEmpty || !airplay.isEmpty {
            panel.beginCard(header: "Selected Devices")
            panel.addColumnHeader(volumeTitle: "Volume", enabledTitle: "Enabled")
            if !locals.isEmpty {
                panel.addSubsectionHeader("Current Device")
                for device in locals { panel.addRow(makeDeviceRow(device, indented: false)) }
            }
            if !airplay.isEmpty {
                panel.addSubsectionHeader("AirPlay Devices")
                for device in airplay { panel.addRow(makeDeviceRow(device, indented: false)) }
            }
        }

        // 3. Groups card — with a trailing "+" accessory (task D) that opens the
        // mixer window's new-group draft (matching the window's own "+").
        if !groups.isEmpty {
            let activeID = groupController?.activeGroupID
            panel.beginCard(header: "Groups",
                            trailingAccessory: .init(
                                symbol: "plus",
                                label: "New group",
                                action: { [weak self] in self?.createNewGroup() }))
            panel.addColumnHeader(volumeTitle: "Volume", enabledTitle: nil)
            for group in groups {
                let header = makeGroupHeader(group, isActive: group.id == activeID)
                panel.addRow(header)
                let expanded = expandedGroupIDs.contains(group.id)
                var memberRows: [DeviceRowView] = []
                for memberID in group.memberIDs {
                    guard let device = devicesByID[memberID] else { continue }
                    // Group members hide the on/off toggle (task C) — membership
                    // in a group is fixed here; the toggle is only for the
                    // Selected Devices section.
                    let row = makeDeviceRow(device, indented: true, showsToggle: false)
                    row.isHidden = !expanded
                    panel.addRow(row)
                    memberRows.append(row)
                }
                memberRowsByGroup[group.id] = memberRows
            }
        }

        // Footer removed (2026-07-14): Open Mixer → header Groups button;
        // Save-as-group → Groups "+"; Quit → header Quit button.
    }

    private func orderedDevices() -> [Device] {
        devicesByID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: Main Out row

    private func refreshMainOutRow() {
        guard let controller = groupController else { return }
        var options: [MainOutRowView.Option] = [
            .init(title: "Destination", isHeader: true),
            .init(title: "Selected Devices", target: .selectedDevices),
        ]
        if !controller.groups.isEmpty {
            options.append(.init(title: "Output Groups", isHeader: true))
            for group in controller.groups {
                options.append(.init(title: group.name, target: .group(id: group.id)))
            }
        }
        mainOutRow.apply(options: options,
                         current: controller.mainOut,
                         master: controller.mainOutMasterVolume,
                         isMuted: controller.isMainOutMuted)
    }

    // MARK: Group + device rows

    private func makeGroupHeader(_ group: Group, isActive: Bool) -> GroupRowView {
        let master = (isActive ? groupController?.masterVolume : nil) ?? averageVolume(of: group)
        let view = GroupRowView(group: group,
                                isActive: isActive,
                                isExpanded: expandedGroupIDs.contains(group.id),
                                masterVolume: master,
                                isMuted: groupController?.isGroupMuted(group.id) ?? false)
        view.delegate = self
        groupRowsByID[group.id] = view
        return view
    }

    private func makeDeviceRow(_ device: Device, indented: Bool, showsToggle: Bool = true) -> DeviceRowView {
        let view = DeviceRowView(device: device, indented: indented, showsToggle: showsToggle)
        view.delegate = self
        applySelectionState(to: view, device: device)
        deviceRowsByID[device.id] = view
        return view
    }

    /// Push the current membership + local-block state into a device row.
    private func applySelectionState(to row: DeviceRowView, device: Device) {
        guard let controller = groupController else { row.apply(device, selected: false); return }
        let selected = controller.isSpeakerSelected(device.id)
        // Block only the local device when it can't currently be turned ON.
        let blocked = device.isLocalDevice && !selected && !controller.canSelectLocalSpeaker(device.id)
        row.apply(device,
                  selected: selected,
                  blocked: blocked,
                  blockReason: blocked ? GroupController.localMixRefusalReason : nil)
    }

    private func averageVolume(of group: Group) -> Int {
        let vols = group.memberIDs.compactMap { devicesByID[$0]?.volume }
        guard !vols.isEmpty else { return 0 }
        return Int((Double(vols.reduce(0, +)) / Double(vols.count)).rounded())
    }

    private func refreshDeviceRows() {
        for (id, row) in deviceRowsByID {
            guard let device = devicesByID[id] else { continue }
            applySelectionState(to: row, device: device)
        }
        for rows in memberRowsByGroup.values {
            for row in rows {
                guard let device = devicesByID[row.device.id] else { continue }
                applySelectionState(to: row, device: device)
            }
        }
    }

    // MARK: Expansion (animated — the reason for NSMenu → NSPopover)

    private func toggleExpansion(groupID: String) {
        let willExpand = !expandedGroupIDs.contains(groupID)
        if willExpand { expandedGroupIDs.insert(groupID) }
        else { expandedGroupIDs.remove(groupID) }

        let rows = memberRowsByGroup[groupID] ?? []
        if let header = groupRowsByID[groupID] { refreshGroupRow(header) }

        test_lastAnimatedExpansion = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            for row in rows { row.animator().isHidden = !willExpand }
            self.panel.stackView.layoutSubtreeIfNeeded()
        }, completionHandler: {
            for row in rows { row.isHidden = !willExpand }
        })
    }

    private func refreshGroupRows() {
        for view in groupRowsByID.values { refreshGroupRow(view) }
    }

    private func refreshGroupRow(_ view: GroupRowView) {
        let groupID = view.group.id
        guard let group = groupController?.groups.first(where: { $0.id == groupID }) else { return }
        let isActive = groupController?.activeGroupID == groupID
        let master = (isActive ? groupController?.masterVolume : nil) ?? averageVolume(of: group)
        view.apply(group: group,
                   isActive: isActive,
                   isExpanded: expandedGroupIDs.contains(groupID),
                   masterVolume: master,
                   isMuted: groupController?.isGroupMuted(groupID) ?? false)
    }

    // MARK: Actions

    /// "Save Selected Devices as group" is enabled iff there's a controller, the
    /// Selected Devices set is non-empty, and it doesn't already equal a saved
    /// group (SPEC §9 dedup).
    private var canSaveCurrentSetup: Bool {
        guard let controller = groupController else { return false }
        guard !controller.selectedDeviceIDs.isEmpty else { return false }
        return controller.group(matchingMemberSet: controller.selectedDeviceIDs) == nil
    }

    private func saveCurrentSetup() {
        guard let controller = groupController else { return }
        let name = "Group \(controller.groups.count + 1)"
        _ = try? controller.saveCurrentSetupAsGroup(name: name)
        rebuild()
    }

    /// The Groups header "+" (task D): open the mixer window's new-group draft —
    /// the same manual-creation flow the window's own "+" runs (SPEC §9 "manual
    /// creation is the PRIMARY path, in the window"). Group membership editing
    /// lives in that window, so a popover "+" routes there rather than creating a
    /// nameless group inline. Falls back to just opening the mixer if the app
    /// hasn't wired a dedicated new-group callback.
    private func createNewGroup() {
        if let onNewGroup { onNewGroup() }
        else { onOpenMixer?() }
    }

    // MARK: Local-mix block presentation
    //
    // The current-device toggle is disabled (greyed + tooltip) whenever it can't
    // currently be turned ON — so the block is presented BEFORE the click. If a
    // refusal still comes back from the model (belt-and-suspenders), we surface
    // the reason and repaint the row so the switch bounces back.

    private func handleSelection(_ result: GroupController.SelectionResult, deviceID: String) {
        if let reason = result.refusalReason {
            test_lastRefusalReason = reason
            presentRefusal(reason)
        } else {
            test_lastRefusalReason = nil
        }
        // Repaint device rows (auto-swap may have flipped the local row; a refusal
        // must bounce the switch back to its real state).
        refreshDeviceRows()
        refreshMainOutRow()
    }

    private func presentRefusal(_ reason: String) {
        // A lightweight, non-blocking surface: the tooltip already carries the
        // reason on the disabled control; when a refusal reaches here (manual
        // gesture), we log it so the app layer can show it. Kept minimal so the
        // headless harness/tests can assert `test_lastRefusalReason`.
        FileHandle.standardError.write(Data("[AirPlayController] \(reason)\n".utf8))
    }

    // MARK: Test-support hooks

    public func test_groupRow(for groupID: String) -> GroupRowView? { groupRowsByID[groupID] }

    public func test_deviceRow(for id: String) -> DeviceRowView? {
        if let row = deviceRowsByID[id] { return row }
        for rows in memberRowsByGroup.values {
            if let row = rows.first(where: { $0.device.id == id }) { return row }
        }
        return nil
    }

    public func test_memberRowCount(groupID: String) -> Int {
        memberRowsByGroup[groupID]?.count ?? 0
    }

    /// The specific group-**member** row for `deviceID` under `groupID` (distinct
    /// from the Selected-Devices row for the same device). Used to assert the
    /// member row hides its toggle (task C).
    public func test_memberRow(groupID: String, deviceID: String) -> DeviceRowView? {
        memberRowsByGroup[groupID]?.first { $0.device.id == deviceID }
    }

    public func test_visibleMemberRowCount(groupID: String) -> Int {
        guard expandedGroupIDs.contains(groupID) else { return 0 }
        return memberRowsByGroup[groupID]?.count ?? 0
    }

    public func test_renderedVisibleMemberRowCount(groupID: String) -> Int {
        (memberRowsByGroup[groupID] ?? []).filter { !$0.isHidden }.count
    }

    public var test_expandedGroupIDs: Set<String> { expandedGroupIDs }
    /// Whether saving the current selection as a group is possible (the footer
    /// "Save" button was removed; this now reflects the Groups "+" affordance's
    /// underlying condition).
    public var test_saveCurrentSetupEnabled: Bool { canSaveCurrentSetup }
    public var test_headerHasQuit: Bool { panel.test_headerHasQuit }
    public var test_groupRowCount: Int { groupRowsByID.count }

    // Header (task A) + Groups "+" (task D) test hooks.
    public var test_headerTitle: String { panel.header.test_title }
    public var test_headerGroupsButtonHasImage: Bool { panel.header.test_groupsButtonHasImage }
    public var test_headerSettingsButtonHasImage: Bool { panel.header.test_settingsButtonHasImage }
    /// Simulate tapping the header's "Open Groups editor" button.
    public func test_tapHeaderGroupsEditor() { panel.header.test_tapGroupsEditor() }
    /// Simulate tapping the header's Settings button.
    public func test_tapHeaderSettings() { panel.header.test_tapSettings() }
    /// Simulate tapping the Groups section header's "+" (task D).
    public func test_tapNewGroup() { createNewGroup() }

    /// Count of device rows in the Selected Devices section (not group members).
    public var test_deviceSectionRowCount: Int { deviceRowsByID.count }
    /// The Main Out row (for selector / master assertions).
    public var test_mainOutRow: MainOutRowView { mainOutRow }

    /// The assembled panel content view (for offscreen snapshot rendering). Forces
    /// its layout before returning so callers get final geometry.
    public var test_panelView: NSView {
        let v = panel.view   // accessing `.view` loads it if needed
        v.layoutSubtreeIfNeeded()
        return v
    }

    /// Lift the panel's scroll-height cap so an offscreen snapshot can render the
    /// full unscrolled panel. Snapshot tooling only — no effect on the live popover.
    public func test_liftScrollHeightCap() {
        _ = panel.view   // ensure `loadView` ran so the cap constraint exists
        panel.test_liftScrollHeightCap()
    }

    public func test_toggleExpansion(groupID: String) { toggleExpansion(groupID: groupID) }

    /// Select the Main Out destination directly (drives the routing).
    public func test_selectMainOut(_ target: MainOutTarget) {
        groupController?.setMainOut(target)
        rebuild()
    }

    public func test_activate(groupID: String) {
        groupController?.setMainOut(.group(id: groupID))
        rebuild()
    }

    public func test_saveCurrentSetup() { saveCurrentSetup() }

    /// Simulate flipping a device row's membership switch through its delegate.
    /// Returns the model's `SelectionResult` so tests can assert refusal/auto-swap.
    @discardableResult
    public func test_toggleDeviceEnabled(deviceID: String, on: Bool) -> GroupController.SelectionResult {
        let result = groupController?.setDeviceSelected(deviceID, on) ?? .ok
        handleSelection(result, deviceID: deviceID)
        return result
    }

    public func test_toggleMute(deviceID: String, muted: Bool) {
        groupController?.setMuted(muted, for: deviceID)
    }

    public func test_dragMainOutMaster(to value: Int) {
        groupController?.beginMainOutMasterDrag()
        groupController?.setMainOutMasterVolume(value)
        groupController?.endMainOutMasterDrag()
        refreshMainOutRow()
    }

    public func test_dragMaster(groupID: String, to value: Int) {
        if groupController?.activeGroupID != groupID {
            groupController?.setMainOut(.group(id: groupID))
        }
        groupController?.beginMasterDrag()
        groupController?.setMasterVolume(value)
        groupController?.endMasterDrag()
    }
}

// MARK: - DeviceRowView.Delegate

extension PopoverController: DeviceRowView.Delegate {

    public func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {
        groupController?.setMemberVolume(volume, for: id)
        refreshGroupRows()
        refreshMainOutRow()
    }

    public func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {
        groupController?.setMuted(muted, for: id)
        // A per-device mute may flip a master (Main Out / group) to fully-muted or
        // back, so refresh those glyphs live.
        refreshDeviceRows()
        refreshMainOutRow()
        refreshGroupRows()
    }

    public func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
        // Compose the Selected Devices set (SPEC §9b). Does NOT route unless Main
        // Out targets Selected Devices; the model handles the local-mix block +
        // auto-swap and returns a result we present.
        let result = groupController?.setDeviceSelected(id, on) ?? .ok
        handleSelection(result, deviceID: id)
    }
}

// MARK: - GroupRowView.Delegate

extension PopoverController: GroupRowView.Delegate {

    func groupRowToggleExpansion(_ row: GroupRowView, groupID: String) {
        toggleExpansion(groupID: groupID)
    }

    func groupRowActivate(_ row: GroupRowView, groupID: String) {
        // Activating a group = pointing Main Out at it (SPEC §9b).
        groupController?.setMainOut(.group(id: groupID))
        rebuild()
    }

    func groupRowBeginMasterDrag(_ row: GroupRowView, groupID: String) {
        if groupController?.activeGroupID != groupID {
            groupController?.setMainOut(.group(id: groupID))
        }
        groupController?.beginMasterDrag()
    }

    func groupRow(_ row: GroupRowView, didSetMaster volume: Int, groupID: String) {
        groupController?.setMasterVolume(volume)
        refreshMainOutRow()
    }

    func groupRowEndMasterDrag(_ row: GroupRowView, groupID: String) {
        groupController?.endMasterDrag()
    }

    func groupRow(_ row: GroupRowView, didSetMuted muted: Bool, groupID: String) {
        groupController?.setGroupMuted(muted, groupID: groupID)
        refreshGroupRows()
        refreshMainOutRow()
        refreshDeviceRows()
    }
}

// MARK: - MainOutRowView.Delegate

extension PopoverController: MainOutRowView.Delegate {

    public func mainOutRow(_ row: MainOutRowView, didSelect target: MainOutTarget) {
        groupController?.setMainOut(target)
        rebuild()
    }

    public func mainOutRowBeginMasterDrag(_ row: MainOutRowView) {
        groupController?.beginMainOutMasterDrag()
    }

    public func mainOutRow(_ row: MainOutRowView, didSetMaster volume: Int) {
        groupController?.setMainOutMasterVolume(volume)
        refreshDeviceRows()
        refreshGroupRows()
    }

    public func mainOutRowEndMasterDrag(_ row: MainOutRowView) {
        groupController?.endMainOutMasterDrag()
    }

    public func mainOutRow(_ row: MainOutRowView, didSetMuted muted: Bool) {
        groupController?.setMainOutMuted(muted)
        refreshDeviceRows()
        refreshMainOutRow()
        refreshGroupRows()
    }
}
