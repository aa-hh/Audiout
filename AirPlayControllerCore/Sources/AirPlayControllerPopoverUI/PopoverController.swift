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
///
/// The popover no longer renders a Groups SECTION (2026-07-16). Group ROUTING
/// stays — the Main Out selector still offers each saved group as a destination
/// (`refreshMainOutRow`), and the header's Groups-editor button still opens the
/// mixer window where group membership is edited.
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

    /// Called when the user taps the header's Settings button (task A). Stubbed —
    /// no settings surface exists yet (`// TODO: settings`).
    public var onOpenSettings: (() -> Void)?

    private let panel = PopoverPanelViewController()

    /// The single System-section Main Out row.
    private let mainOutRow = MainOutRowView()

    private var deviceRowsByID: [String: DeviceRowView] = [:]

    /// Each device's connection state as of the LAST `update(devices:)`, so the
    /// next update can detect transitions (connection-status brief §7.3). The
    /// backend owns the state machine; the popover only reacts to edges —
    /// `→ .failed` (honest-toggle cleanup + auto-expand) and `→ .connected` /
    /// `→ .off` (panel teardown).
    private var lastConnectionStates: [String: ConnectionState] = [:]

    /// Ids whose diagnosis panel should currently be OPEN. This is the
    /// persistent intent — it survives `rebuild()` (which recreates the panel
    /// views). Seeded automatically on a `→ .failed` transition (auto-expand ONCE
    /// per failure episode) and cleared when the device leaves `.failed`
    /// (`→ .connected` / `→ .off`). The manual warning-button toggle was retired
    /// with the right-side status slot (2026-07-17); the panel is now purely
    /// auto-driven off the connection-state transitions.
    private var openDiagnosisIDs: Set<String> = []

    /// The mounted `ConnectionDiagnosisView` per device id — the view-layer
    /// mirror of `openDiagnosisIDs`, rebuilt by `reconcileDiagnosisPanels`.
    private var diagnosisPanelsByID: [String: ConnectionDiagnosisView] = [:]

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
        handleConnectionTransitions(devices)
        groupController?.syncActiveGroupToSelection()
        if popover.isShown {
            refreshDeviceRows()
            refreshMainOutRow()
            reconcileDiagnosisPanels(animated: true)
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
            // With fit-height there's no scroll range, but reset to the top so the
            // System card is flush with the top edge (belt-and-suspenders — the old
            // scroll cap could otherwise leave the panel opening mid-scroll).
            panel.scrollToTop()
        }
    }

    // MARK: Build

    public func rebuild() {
        deviceRowsByID.removeAll()
        // The mounted panel views die with their rows; the open-panel INTENT
        // (`openDiagnosisIDs`) survives and is re-applied below (brief §7.3 —
        // "rebuild() restores open panels").
        diagnosisPanelsByID.removeAll()
        panel.clearRows()

        let allDevices = orderedDevices()

        // 1. System card — the single Main Out row. Combined header row (change
        // 1): "System" title on the left, "VOLUME" over the slider and "DEVICE"
        // over the destination dropdown on the right (change 2).
        panel.beginCard(header: "System", volumeTitle: "Volume", trailingTitle: "Device")
        panel.addRow(mainOutRow)
        refreshMainOutRow()

        // 2. Selected Devices card — split into Current Device + AirPlay.
        let locals = allDevices.filter(\.isLocalDevice)
        let airplay = allDevices.filter { !$0.isLocalDevice }
        if !locals.isEmpty || !airplay.isEmpty {
            // Combined header row (change 1): "Selected Devices" title on the
            // left, "VOLUME" over the slider and "ENABLED" over the membership
            // toggle on the right.
            panel.beginCard(header: "Selected Devices", volumeTitle: "Volume", trailingTitle: "Enabled")
            if !locals.isEmpty {
                panel.addSubsectionHeader("Current Device")
                for device in locals { panel.addRow(makeDeviceRow(device, indented: false)) }
            }
            if !airplay.isEmpty {
                panel.addSubsectionHeader("AirPlay Devices")
                for device in airplay { panel.addRow(makeDeviceRow(device, indented: false)) }
            }
        }

        // Groups card removed (2026-07-16): the popover no longer renders a Groups
        // SECTION. Group ROUTING lives in the Main Out selector (refreshMainOutRow)
        // and membership editing lives in the mixer window (header Groups button).

        // Footer removed (2026-07-14): Open Mixer → header Groups button;
        // Save-as-group → Groups "+"; Quit → header Quit button.

        // Restore any open diagnosis panels under their (freshly created) rows
        // (brief §7.3 — a failure that arrived while the popover was closed goes
        // through this path). Un-animated: the whole panel is being (re)built.
        reconcileDiagnosisPanels(animated: false)
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

    // MARK: Device rows

    private func makeDeviceRow(_ device: Device, indented: Bool, showsToggle: Bool = true) -> DeviceRowView {
        // No accent-wash pill in the popover (2026-07-14 — Alec: no longer
        // needed to highlight multiple selected devices at once here; the
        // card already separates rows, and the icon tint + switch state still
        // say "on"). The mixer window keeps the wash (its default `true`).
        let view = DeviceRowView(device: device, indented: indented, showsToggle: showsToggle,
                                 paintsSelectionBackground: false)
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

    private func refreshDeviceRows() {
        for (id, row) in deviceRowsByID {
            guard let device = devicesByID[id] else { continue }
            applySelectionState(to: row, device: device)
        }
    }

    // MARK: Connection failures + diagnosis panels (brief §7.3)
    //
    // The backend owns the connection state machine; the popover reacts to its
    // TRANSITIONS. On `→ .failed` it (a) removes the device from the Selected
    // Devices set — the honest toggle animates back OFF via ordinary membership
    // repaint, and the backend keeps `.failed` sticky through the resulting
    // cleanup `setOutputSet` (§1) so the warning survives — and (b) auto-expands
    // the diagnosis panel ONCE for that failure episode. On `→ .connected` /
    // `→ .off` any panel for the id is torn down. "Try again" re-adds membership
    // (the toggle-on path IS the retry path). The panel is purely auto-driven off
    // these transitions — the manual warning-button toggle was retired 2026-07-17.

    /// Diff the new snapshot's connection states against the last one and run
    /// the edge-triggered reactions above. Also prunes state for devices that
    /// vanished from the snapshot entirely (`deviceRemoved` — `.failed → .off`
    /// per §1, so the panel goes too).
    private func handleConnectionTransitions(_ devices: [Device]) {
        for device in devices {
            let previous = lastConnectionStates[device.id] ?? .off
            let current = device.connectionState
            lastConnectionStates[device.id] = current

            switch current {
            case .failed:
                // Edge-triggered on ENTERING failed: a later in-episode update
                // (the diagnosis replacing the backend's first guess is still
                // `.failed`, just with a better cause) must not re-run the
                // cleanup or force a closed panel back open.
                guard !previous.isFailedState else { break }
                if groupController?.isSpeakerSelected(device.id) == true {
                    groupController?.setDeviceSelected(device.id, false)
                }
                openDiagnosisIDs.insert(device.id)
            case .connected, .off:
                openDiagnosisIDs.remove(device.id)
            case .connecting, .reconnecting:
                // In-flight: leave any open panel alone (a retry keeps its
                // context on screen until the attempt resolves).
                break
            }
        }

        // Devices gone from the snapshot: drop their tracking + panel.
        let liveIDs = Set(devices.map(\.id))
        for id in lastConnectionStates.keys where !liveIDs.contains(id) {
            lastConnectionStates.removeValue(forKey: id)
            openDiagnosisIDs.remove(id)
        }
    }

    /// Make the mounted panel views match `openDiagnosisIDs`: tear down panels
    /// that should be closed (or whose device/row vanished), refresh the failure
    /// copy on ones staying up (the diagnosis-replacement path), and mount
    /// missing ones under their device row.
    private func reconcileDiagnosisPanels(animated: Bool) {
        for (id, view) in diagnosisPanelsByID where !openDiagnosisIDs.contains(id) {
            diagnosisPanelsByID.removeValue(forKey: id)
            panel.removeRow(view, animated: animated)
        }
        for id in openDiagnosisIDs {
            guard let device = devicesByID[id],
                  case .failed(let failure) = device.connectionState else { continue }
            if let view = diagnosisPanelsByID[id] {
                view.apply(failure: failure, deviceName: device.name)
            } else {
                mountDiagnosisPanel(for: id, failure: failure, device: device, animated: animated)
            }
        }
    }

    /// Create a `ConnectionDiagnosisView` for `id` and insert it directly under
    /// the device's row.
    private func mountDiagnosisPanel(for id: String, failure: ConnectionFailure,
                                     device: Device, animated: Bool) {
        guard let row = deviceRowsByID[id] else { return }
        let view = ConnectionDiagnosisView(failure: failure, deviceName: device.name)
        view.onRetry = { [weak self] in self?.retryConnection(for: id) }
        view.onCopyDetails = { [weak self] in self?.copyDiagnosisDetails(for: id) }
        diagnosisPanelsByID[id] = view
        panel.insertRow(view, after: row, animated: animated)
    }

    /// "Try again": re-adding the id to the Selected Devices set IS the retry
    /// path (§1 — a `.failed` id re-appearing in `setOutputSet` → `.connecting`).
    private func retryConnection(for id: String) {
        let result = groupController?.setDeviceSelected(id, true) ?? .ok
        handleSelection(result, deviceID: id)
    }

    /// "Copy details": the raw evidence when the diagnosis captured any, else
    /// the user-facing copy. The HOST owns the pasteboard write (§7.1 — the
    /// panel view never touches `NSPasteboard`).
    private func copyDiagnosisDetails(for id: String) {
        guard let device = devicesByID[id],
              case .failed(let failure) = device.connectionState else { return }
        let text = failure.detail ?? "\(failure.headline). \(failure.suggestion)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    public func test_deviceRow(for id: String) -> DeviceRowView? {
        deviceRowsByID[id]
    }

    /// Whether saving the current selection as a group is possible (this backs the
    /// Main Out selector's group-routing entries — a saved group becomes a
    /// destination even though the popover no longer renders a Groups section).
    public var test_saveCurrentSetupEnabled: Bool { canSaveCurrentSetup }
    public var test_headerHasQuit: Bool { panel.test_headerHasQuit }

    // Header (task A) test hooks.
    public var test_headerTitle: String { panel.header.test_title }
    public var test_headerGroupsButtonHasImage: Bool { panel.header.test_groupsButtonHasImage }
    public var test_headerSettingsButtonHasImage: Bool { panel.header.test_settingsButtonHasImage }
    /// Simulate tapping the header's "Open Groups editor" button.
    public func test_tapHeaderGroupsEditor() { panel.header.test_tapGroupsEditor() }
    /// Simulate tapping the header's Settings button.
    public func test_tapHeaderSettings() { panel.header.test_tapSettings() }

    /// Count of device rows in the Selected Devices section.
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

    /// The mounted diagnosis panel for a device, or `nil` when closed/absent
    /// (brief §7.3 test hook).
    public func test_diagnosisPanel(for id: String) -> ConnectionDiagnosisView? {
        diagnosisPanelsByID[id]
    }

    /// Simulate clicking "Try again" in the device's open diagnosis panel.
    public func test_tapRetry(for id: String) {
        diagnosisPanelsByID[id]?.test_tapRetry()
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
        refreshMainOutRow()
    }

    public func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {
        groupController?.setMuted(muted, for: id)
        // A per-device mute may flip the Main Out master to fully-muted or back, so
        // refresh those glyphs live.
        refreshDeviceRows()
        refreshMainOutRow()
    }

    public func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
        // Compose the Selected Devices set (SPEC §9b). Does NOT route unless Main
        // Out targets Selected Devices; the model handles the local-mix block +
        // auto-swap and returns a result we present.
        let result = groupController?.setDeviceSelected(id, on) ?? .ok
        handleSelection(result, deviceID: id)
    }
}

// MARK: - ConnectionState helpers

private extension ConnectionState {
    /// Whether this is `.failed` regardless of the attached failure — the edge
    /// detector must treat a diagnosis REPLACEMENT (`.failed(guess)` →
    /// `.failed(diagnosed)`, unequal under `Equatable`) as the same episode.
    var isFailedState: Bool {
        if case .failed = self { return true }
        return false
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
    }

    public func mainOutRowEndMasterDrag(_ row: MainOutRowView) {
        groupController?.endMainOutMasterDrag()
    }

    public func mainOutRow(_ row: MainOutRowView, didSetMuted muted: Bool) {
        groupController?.setMainOutMuted(muted)
        refreshDeviceRows()
        refreshMainOutRow()
    }
}
