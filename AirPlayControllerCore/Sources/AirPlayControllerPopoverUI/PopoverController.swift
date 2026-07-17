// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore
import AirPlayControllerSharedUI

/// A plain-value snapshot of one running application, for the "+ Add
/// application…" picker (T-7, PLAN-POPOVER-ROUTING.md decision 6). Kept
/// independent of `NSRunningApplication` so tests can supply a fixed list
/// without touching the real workspace.
public struct RunningAppInfo: Equatable {
    public let bundleID: String
    public let displayName: String
    public let icon: NSImage?

    public init(bundleID: String, displayName: String, icon: NSImage?) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.icon = icon
    }

    /// `Equatable` ignores `icon` (`NSImage` isn't meaningfully comparable and
    /// tests only care about identity/name).
    public static func == (lhs: RunningAppInfo, rhs: RunningAppInfo) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.displayName == rhs.displayName
    }
}

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

    /// Backs the Applications card's collapse default (PLAN §B decision:
    /// "Applications expanded iff ≥1 app is redirected" — T-5). Injected with a
    /// default so every existing call site (AppDelegate, popover-harness,
    /// popover-snapshot, tests) keeps compiling unchanged; the Applications card
    /// itself is wired by a later task (T-8) — this controller only needs
    /// `routedAppCount` to compute the default.
    private let appRouting: AppRoutingController

    /// Source of the running-app list for the "+ Add application…" picker
    /// (T-7). Defaults to real `.regular`-policy apps with a bundle id, mirroring
    /// how a Dock-visible app would be discovered; tests inject a fixed list so
    /// they don't depend on whatever's actually running.
    private let runningAppsProvider: () -> [RunningAppInfo]

    /// Collapse-default policy (PLAN §B, T-5): defaults are recomputed on EVERY
    /// popover OPEN and manual toggles during that open are transient — they are
    /// DISCARDED the next time the popover opens. Rebuilds WITHIN one open
    /// (backend events pushing `update(devices:)`, Main Out changes, etc.) must
    /// instead preserve whatever the transient state currently is, so a user's
    /// mid-session toggle doesn't get stomped by an unrelated repaint.
    ///
    /// `transientCollapsed` holds the current-open override per card title, keyed
    /// the same way `PopoverPanelViewController` keys its cards (by section
    /// title) — so this applies uniformly to any collapsible card, including the
    /// Applications card once T-8 wires it in. `nil` means "no override yet —
    /// use the computed default".
    private var transientCollapsed: [String: Bool] = [:]

    /// True only while `rebuild()` is running as part of a popover OPEN
    /// (`toggle()`'s show path) — the one moment the defaults get recomputed and
    /// `transientCollapsed` is cleared. Every other `rebuild()` call (device
    /// updates, Main Out selection, etc.) leaves the transient state alone.
    private var isRebuildingForOpen = false

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

    /// The Applications card's `AppRowView`s, keyed by bundle id (stable identity —
    /// `AppRoute.bundleID`). Populated by `rebuild()` in `appRoutes` order (T-8,
    /// PLAN §C). Lets `test_` hooks look a row up by bundle id.
    private var appRowsByBundleID: [String: AppRowView] = [:]

    /// The previous device snapshot's ids-that-were-valid-AirPlay-targets, so
    /// `update(devices:)` can detect a routed device disappearing or going
    /// unavailable and drive `appRouting.handleDeviceUnavailable(id:)` (PLAN
    /// decision 7 — silent fallback). "Valid target" == present AND available AND
    /// non-local, exactly the set `availableAirPlayDestinations` offers as a
    /// redirect target. `nil` until the first snapshot arrives (so the very first
    /// `update` never mistakes "not seen yet" for "went away").
    private var lastValidDestinationIDs: Set<String>?

    /// The sentinel destination id the Applications card's "Current Device" entry
    /// carries (T-8). `AppRouteDestination.currentDevice` names no specific device
    /// (decision 8 — "current device" == "no redirect"), but `AppRowView` works in
    /// plain string ids; this sentinel bridges the two and is chosen so it can
    /// never collide with a real `Device.id`.
    static let currentDeviceDestinationID = "\u{0000}current-device"

    /// The SF Symbol shown for a routed app that isn't currently running (its icon
    /// can't be resolved) — routes persist across app quits (T-8, PLAN §C). A
    /// documented AppKit-usable symbol.
    static let missingAppIconSymbolName = "app.dashed"

    /// The most recent local-mix refusal reason surfaced to the user (so the app
    /// / tests can assert the block was presented). Cleared on the next
    /// successful selection change.
    private(set) public var test_lastRefusalReason: String?

    /// - Parameters:
    ///   - appRouting: backs the Applications card's collapse default (T-5) and
    ///     the running-app picker (T-7). Defaulted so existing call sites
    ///     (AppDelegate, popover-harness, popover-snapshot, tests) compile
    ///     unchanged; tests inject one over a temp store.
    ///   - runningAppsProvider: supplies the "+ Add application…" picker's
    ///     candidate list (T-7). Defaults to `NSWorkspace.shared
    ///     .runningApplications` filtered to `.regular`-activation-policy apps
    ///     with a non-nil bundle id; tests inject a fixed list.
    public init(appRouting: AppRoutingController = AppRoutingController(),
                runningAppsProvider: @escaping () -> [RunningAppInfo] = PopoverController.defaultRunningAppsProvider) {
        self.appRouting = appRouting
        self.runningAppsProvider = runningAppsProvider
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

        // Device-lifecycle → per-app routes (T-8, PLAN decision 7 — silent
        // fallback). A device that was a valid AirPlay redirect target last
        // snapshot but isn't now (dropped entirely via `deviceRemoved`, or present
        // but `isAvailable == false`) resets any route pointed at it to Current
        // Device. `handleDeviceUnavailable` no-ops when no route targeted the id, so
        // this only mutates when a routed target actually went away.
        let nowValid = Set(availableAirPlayDestinations(devices: devices).map(\.id))
        var routesChanged = false
        if let previous = lastValidDestinationIDs {
            let routedBefore = appRouting.appRoutes
            for goneID in previous.subtracting(nowValid) {
                appRouting.handleDeviceUnavailable(id: goneID)
            }
            routesChanged = appRouting.appRoutes != routedBefore
        }
        lastValidDestinationIDs = nowValid

        // A route reset (routesChanged) restructures the Applications card, so it
        // needs a full rebuild — but a rebuild here must NOT reset this open's
        // transient collapse state (it's a mid-open repaint, not a reopen), which
        // a plain `rebuild()` guarantees (only `rebuildForOpen()` clears it).
        if popover.isShown {
            if routesChanged {
                rebuild()
            } else {
                refreshDeviceRows()
                refreshMainOutRow()
                reconcileDiagnosisPanels(animated: true)
            }
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
            rebuildForOpen()
            // Exact-fit initial size (T-3): settle layout and set the popover's
            // content size while it is still HIDDEN, so it opens at exactly the
            // content height with no scrollbar (PLAN-POPOVER-ROUTING.md §E risk 1 —
            // non-animated path for initial show). A `preferredContentSize` change
            // on a not-yet-shown popover never animates, so this is safe to do with
            // `animates` left true — the show fade below still plays; only later,
            // IN-PLACE resizes (T-4 expand/collapse) animate the frame.
            panel.panelContentDidChangeHeight(animated: false)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Set the popover's resize animation for the NEXT `preferredContentSize`
    /// change, then restore. The panel's resize primitive
    /// (`panelContentDidChangeHeight`) calls this so the DOCUMENTED
    /// `preferredContentSize` size channel animates (or not) exactly as the caller
    /// asked — `NSPopover` animates a `preferredContentSize` change iff `animates`
    /// is true (T-3, PLAN §E risk 1). The panel owns no `NSPopover` reference; this
    /// controller does. Only meaningful while the popover is shown; a resize on a
    /// hidden popover never animates, so this is a no-op then (and must NOT clobber
    /// `animates`, which also gates the show/hide fade). The `apply` closure makes
    /// the size assignment inside the temporarily-set flag.
    func setPopoverAnimates(_ animates: Bool, whileApplying apply: () -> Void) {
        guard popover.isShown else { apply(); return }
        let previous = popover.animates
        popover.animates = animates
        apply()
        popover.animates = previous
    }

    /// Rebuild as an OPEN (T-5, PLAN §B): recompute every collapsible card's
    /// default and discard manual toggles from the previous open, THEN rebuild.
    /// Shared by `toggle()`'s show path and `test_simulateOpen()`.
    private func rebuildForOpen() {
        isRebuildingForOpen = true
        transientCollapsed.removeAll()
        rebuild()
        isRebuildingForOpen = false
    }

    // MARK: Build

    public func rebuild() {
        deviceRowsByID.removeAll()
        // The mounted panel views die with their rows; the open-panel INTENT
        // (`openDiagnosisIDs`) survives and is re-applied below (brief §7.3 —
        // "rebuild() restores open panels").
        diagnosisPanelsByID.removeAll()
        appRowsByBundleID.removeAll()
        panel.clearRows()

        let allDevices = orderedDevices()

        // 1. System card — the single Main Out row. Combined header row (change
        // 1): "System" title on the left, "VOLUME" over the slider and "DEVICE"
        // over the destination dropdown on the right (change 2).
        //
        // Collapsible (T-4, PLAN decision 5): the chevron/title toggle the body.
        // Collapse-DEFAULT policy (T-5, PLAN §B): defaults are recomputed on
        // every OPEN (System starts expanded); a rebuild WITHIN one open (backend
        // events, etc.) instead preserves whatever the transient state currently
        // is — `collapsedState(for:default:)` picks the right one.
        panel.beginCard(header: "System", volumeTitle: "Volume", trailingTitle: "Device",
                        collapsible: true, collapsed: collapsedState(for: "System", default: false),
                        onToggle: { [weak self] in self?.toggleCard("System") })
        panel.addRow(mainOutRow)
        refreshMainOutRow()

        // 2. Selected Devices card — split into Current Device + AirPlay.
        let locals = allDevices.filter(\.isLocalDevice)
        let airplay = allDevices.filter { !$0.isLocalDevice }
        if !locals.isEmpty || !airplay.isEmpty {
            // Combined header row (change 1): "Devices" title on the left,
            // "VOLUME" over the slider and "ENABLED" over the membership toggle
            // on the right. Collapsible (main merge) — the collapse key must equal
            // the display header, since cards are looked up by header title.
            panel.beginCard(header: "Devices", volumeTitle: "Volume", trailingTitle: "Enabled",
                            collapsible: true,
                            collapsed: collapsedState(for: "Devices", default: false),
                            onToggle: { [weak self] in self?.toggleCard("Devices") })
            if !locals.isEmpty {
                panel.addSubsectionHeader("Current Device")
                for device in locals { panel.addRow(makeDeviceRow(device, indented: false)) }
            }
            if !airplay.isEmpty {
                panel.addSubsectionHeader("AirPlay Devices")
                for device in airplay { panel.addRow(makeDeviceRow(device, indented: false)) }
            }
        }

        // 3. Applications card — rendered LAST (below Selected Devices), one
        // `AppRowView` per routed app in stable `appRoutes` order, then the
        // "+ Add application…" row (PLAN decision 6 — it doubles as the empty
        // state, so the card is always present even with no routes).
        //
        // Collapsible (T-4/T-5): collapse DEFAULT is "expanded iff ≥1 app is
        // redirected" (`applicationsDefaultExpanded`), recomputed on every OPEN
        // and preserved across mid-open rebuilds by `collapsedState(for:default:)`
        // — same machinery as the other two cards. `collapsed:` is the negation of
        // the expanded default.
        let title = Self.applicationsCardTitle
        panel.beginCard(header: title, volumeTitle: "Volume", trailingTitle: "Redirect",
                        collapsible: true,
                        collapsed: collapsedState(for: title, default: !applicationsDefaultExpanded),
                        onToggle: { [weak self] in self?.toggleCard(title) })
        for route in appRouting.appRoutes {
            panel.addRow(makeAppRow(route, devices: allDevices))
        }
        panel.addRow(makeAddApplicationRow())

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

    // MARK: Collapse-default policy (T-5, PLAN §B)

    /// The Applications card's title, so its default is keyed identically to
    /// every other card even though the card itself isn't built yet (T-8).
    static let applicationsCardTitle = "Applications"

    /// The collapsed state `rebuild()` should hand `beginCard` for the card
    /// titled `title`: on an OPEN-triggered rebuild, the freshly computed
    /// `default` (recorded into `transientCollapsed` so later mid-open rebuilds
    /// in the SAME open see the same value, not a re-derived one); otherwise the
    /// existing transient override if the user has already toggled this card
    /// this open, else the same computed default.
    private func collapsedState(for title: String, default defaultValue: @autoclosure () -> Bool) -> Bool {
        if !isRebuildingForOpen, let existing = transientCollapsed[title] {
            return existing
        }
        let value = defaultValue()
        transientCollapsed[title] = value
        return value
    }

    /// The Applications card's collapse default (PLAN §B): expanded iff at
    /// least one app is currently redirected. Exposed so the later task that
    /// wires the card (T-8) only needs to call `collapsedState(for:
    /// Self.applicationsCardTitle, default: !applicationsDefaultExpanded)`.
    private var applicationsDefaultExpanded: Bool { appRouting.routedAppCount > 0 }

    /// Chevron/title click handler for a card (T-4 affordance): flips the
    /// TRANSIENT collapse state (never the default) and drives the panel's own
    /// collapse/expand — no `rebuild()` here, so no OTHER card's transient
    /// state or mounted view is disturbed by this click.
    private func toggleCard(_ title: String, animated: Bool = true) {
        let next = !(transientCollapsed[title] ?? false)
        transientCollapsed[title] = next
        panel.setCardCollapsed(title: title, collapsed: next, animated: animated)
    }

    // MARK: Main Out row

    private func refreshMainOutRow() {
        guard let controller = groupController else { return }
        var options: [MainOutRowView.Option] = [
            .init(title: "Destination", isHeader: true),
            .init(title: "Enabled Devices", target: .selectedDevices),
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

    // MARK: Applications card rows (T-8, PLAN §C decisions 3/4/6/8)

    /// Build one `AppRowView` for `route` against the discovered device `devices`.
    /// The destination popup mirrors `refreshMainOutRow`'s split — a single
    /// "Current Device" entry (local, decision 8 — "no redirect") first, then the
    /// available (present + reachable) non-local AirPlay devices. The selected id
    /// is derived from `route.destination`, and the slider dims while local
    /// (decision 3, driven inside `AppRowView` by the selected entry's `isLocal`).
    private func makeAppRow(_ route: AppRoute, devices: [Device]) -> AppRowView {
        let row = AppRowView()
        row.delegate = self
        row.apply(AppRowView.Configuration(
            appID: route.bundleID,
            name: route.displayName,
            icon: appIcon(for: route.bundleID),
            volume: route.volume,
            selectedDestinationID: destinationID(for: route.destination),
            destinations: appDestinations(devices: devices)))
        appRowsByBundleID[route.bundleID] = row
        return row
    }

    /// The "+ Add application…" row (PLAN decision 6). Wires its tap to the same
    /// running-app picker the header would (`presentAddApplicationPicker`), anchored
    /// to the row itself.
    private func makeAddApplicationRow() -> AddApplicationRowView {
        let row = AddApplicationRowView()
        row.onAdd = { [weak self, weak row] in
            guard let self, let row else { return }
            self.presentAddApplicationPicker(relativeTo: row)
        }
        return row
    }

    /// The destination entries for the Applications popup, in display order: the
    /// single "Current Device" entry (decision 8) first, then every AVAILABLE
    /// non-local device (`availableAirPlayDestinations`). Plain values only —
    /// `AppRowView` is isolated from Core's `AppRoute` (T-6).
    private func appDestinations(devices: [Device]) -> [AppRowView.Destination] {
        var entries: [AppRowView.Destination] = [
            .init(id: Self.currentDeviceDestinationID,
                  title: currentDeviceTitle(devices: devices),
                  isLocal: true,
                  symbolName: Device.Kind.localMac.symbolName),
        ]
        for device in availableAirPlayDestinations(devices: devices) {
            entries.append(.init(id: device.id, title: device.name, isLocal: false,
                                 symbolName: device.kind.symbolName))
        }
        return entries
    }

    /// The available AirPlay redirect targets: present, reachable (`isAvailable`),
    /// non-local devices, in the same stable order as the Selected Devices card.
    /// PLAN decision 7 pairs with this — a routed device that drops out of this set
    /// falls back to Current Device (see `update(devices:)`).
    private func availableAirPlayDestinations(devices: [Device]) -> [Device] {
        devices.filter { !$0.isLocalDevice && $0.isAvailable }
    }

    /// Title for the "Current Device" entry — the local device's own name when the
    /// fleet includes it, else a generic fallback so the entry always reads
    /// sensibly (decision 8 — the app plays on this Mac).
    private func currentDeviceTitle(devices: [Device]) -> String {
        devices.first(where: \.isLocalDevice)?.name ?? "Current Device"
    }

    /// Map an `AppRoute.destination` onto the plain-string id `AppRowView` selects
    /// by: the sentinel for `.currentDevice`, or the device id for `.device(id:)`.
    private func destinationID(for destination: AppRouteDestination) -> String {
        switch destination {
        case .currentDevice:       return Self.currentDeviceDestinationID
        case .device(let id):      return id
        }
    }

    /// Inverse of `destinationID(for:)`: the sentinel maps back to `.currentDevice`,
    /// any other id to `.device(id:)`.
    private func destination(forID id: String) -> AppRouteDestination {
        id == Self.currentDeviceDestinationID ? .currentDevice : .device(id: id)
    }

    /// Resolve a routed app's icon lazily (T-8): the live `NSRunningApplication`'s
    /// icon when the app is running, else a generic placeholder — routes persist
    /// across app quits, so a routed-but-quit app must still render. Prefers the
    /// injected `runningAppsProvider` (so tests/headless runs stay off the real
    /// workspace), falling back to `NSRunningApplication(bundleIdentifier:)`.
    private func appIcon(for bundleID: String) -> NSImage? {
        if let running = runningAppsProvider().first(where: { $0.bundleID == bundleID }),
           let icon = running.icon {
            return icon
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            return icon
        }
        // Not currently running (route persisted across a quit) — generic
        // placeholder (PLAN §C: "a routed app that is NOT currently running shows a
        // generic placeholder").
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        return NSImage(systemSymbolName: Self.missingAppIconSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
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

    // MARK: Running-app picker (T-7, PLAN decision 6)

    /// The default `runningAppsProvider`: real `.regular`-activation-policy apps
    /// (Dock-visible, not background/accessory agents) with a non-nil bundle id,
    /// mapped to the plain-value `RunningAppInfo` this controller works with.
    /// `static` (not a stored closure) so it can serve as the init's default
    /// parameter.
    public nonisolated static func defaultRunningAppsProvider() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return RunningAppInfo(bundleID: bundleID,
                                      displayName: app.localizedName ?? bundleID,
                                      icon: app.icon)
            }
    }

    /// The picker's candidate list (PLAN decision 6): every running app from
    /// `runningAppsProvider`, EXCLUDING ones that already have a route (adding a
    /// second route for the same bundle id would collide with `AppRoute`'s
    /// bundle-id identity — `AppRoutingController.addRoute` already no-ops on a
    /// duplicate, but filtering here keeps the menu from offering a dead choice).
    private func availableAppsForPicker() -> [RunningAppInfo] {
        let routed = Set(appRouting.appRoutes.map(\.bundleID))
        return runningAppsProvider().filter { !routed.contains($0.bundleID) }
    }

    /// Add a route for `bundleID`/`displayName` (defaults to `.currentDevice` —
    /// PLAN decision 8, "no redirect") and rebuild, preserving this open's
    /// transient collapse state (a plain `rebuild()`, not `rebuildForOpen()`).
    private func pickApp(bundleID: String, displayName: String) {
        appRouting.addRoute(bundleID: bundleID, displayName: displayName)
        rebuild()
    }

    /// Build and pop up the "+ Add application…" menu at `view` (PLAN decision
    /// 6): one item per available app, icon + `localizedName`-equivalent title.
    /// Already-routed apps are excluded entirely (`availableAppsForPicker`), so
    /// there's nothing to additionally disable. Choosing an item calls
    /// `pickApp`.
    func presentAddApplicationPicker(relativeTo view: NSView) {
        let menu = NSMenu()
        for app in availableAppsForPicker() {
            let item = NSMenuItem(title: app.displayName, action: #selector(addApplicationMenuItemSelected(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.image = app.icon
            item.representedObject = app
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    @objc private func addApplicationMenuItemSelected(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? RunningAppInfo else { return }
        pickApp(bundleID: app.bundleID, displayName: app.displayName)
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

    /// Simulate the popover being opened (T-5): recomputes collapse defaults and
    /// discards this open's manual toggles, exactly like `toggle()`'s show path,
    /// without needing a real `NSStatusBarButton`/`NSPopover.show`.
    public func test_simulateOpen() { rebuildForOpen() }

    // MARK: Running-app picker test hooks (T-7)

    /// The "+ Add application…" picker's current candidate list — every running
    /// app from `runningAppsProvider` except ones that already have a route.
    public func test_availableAppsForPicker() -> [RunningAppInfo] { availableAppsForPicker() }

    /// Simulate picking `bundleID` from the picker (looked up in
    /// `runningAppsProvider()`'s current list for its display name; no-op if
    /// `bundleID` isn't in that list). Drives the same `AppRoutingController
    /// .addRoute` + `rebuild()` path a real menu selection would.
    public func test_pickApp(bundleID: String) {
        guard let app = runningAppsProvider().first(where: { $0.bundleID == bundleID }) else { return }
        pickApp(bundleID: app.bundleID, displayName: app.displayName)
    }

    // MARK: Applications card test hooks (T-8)

    /// Number of `AppRowView`s currently mounted in the Applications card (one per
    /// routed app; excludes the "+ Add application…" row).
    public var test_appRowCount: Int { appRowsByBundleID.count }

    /// The `AppRowView` for `bundleID`, or `nil` if that app isn't routed / the
    /// card isn't built (structural + config assertions).
    public func test_appRow(for bundleID: String) -> AppRowView? { appRowsByBundleID[bundleID] }

    /// The ordered bundle ids of the mounted app rows — proves stable
    /// `appRoutes`-order rendering.
    public func test_appRowBundleIDs() -> [String] { appRouting.appRoutes.map(\.bundleID) }

    /// The destination menu titles for `bundleID`'s row (including the disabled
    /// section headers), so tests can assert the "Current Device" / "AirPlay
    /// Devices" split. `nil` if no such row.
    public func test_appRowDestinationTitles(for bundleID: String) -> [String]? {
        appRowsByBundleID[bundleID]?.test_menuTitles
    }

    /// The currently selected destination id for `bundleID`'s row (the sentinel
    /// `currentDeviceDestinationID` when local, else a device id). `nil` if no row.
    public func test_appRowSelectedDestinationID(for bundleID: String) -> String? {
        appRowsByBundleID[bundleID]?.test_selectedDestinationID
    }

    /// Whether `bundleID`'s volume slider is dimmed/disabled (decision 3 — true iff
    /// the destination is Current Device/local). `nil` if no row.
    public func test_appRowSliderDimmed(for bundleID: String) -> Bool? {
        appRowsByBundleID[bundleID]?.test_isSliderDimmed
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

    /// Exact-fit sizing hooks (T-3). `test_panelFittingSize` is the settled
    /// `fittingSize` the resize primitive publishes; `test_preferredContentSize` is
    /// what the popover actually tracks. After a rebuild they must be equal (no
    /// clipping, no scrollbar).
    public var test_panelFittingSize: NSSize { panel.fittingSizeSettled() }
    public var test_preferredContentSize: NSSize { panel.preferredContentSize }

    // MARK: Collapsible-card test hooks (T-4)

    /// Whether the card titled `title` is currently collapsed (`nil` if no card).
    public func test_isCardCollapsed(title: String) -> Bool? {
        panel.test_isCardCollapsed(title: title)
    }
    /// Toggle the card titled `title` (drives the chevron/title-click path,
    /// including the T-5 transient-state bookkeeping so a later mid-open
    /// `rebuild()` preserves it). Returns the new collapsed state (`nil` if no
    /// card).
    @discardableResult
    public func test_toggleCard(title: String, animated: Bool = false) -> Bool? {
        guard panel.test_isCardCollapsed(title: title) != nil else { return nil }
        toggleCard(title, animated: animated)
        return panel.test_isCardCollapsed(title: title)
    }
    /// The card's laid-out body-clip height — 0 when collapsed (`nil` if no card).
    public func test_cardBodyClipHeight(title: String) -> CGFloat? {
        panel.test_cardBodyClipHeight(title: title)
    }
    /// The card's expanded body height, independent of state (`nil` if no card).
    public func test_cardBodyFittingHeight(title: String) -> CGFloat? {
        panel.test_cardBodyFittingHeight(title: title)
    }
    /// The chevron's current SF Symbol name for `title` (`nil` if not collapsible).
    public func test_cardChevronSymbolName(title: String) -> String? {
        panel.test_cardChevronSymbolName(title: title)
    }
    /// Drive the resize primitive directly (offscreen; no live popover) so tests can
    /// assert the published size equals the content's fitting height.
    public func test_applyExactFitSize() { panel.panelContentDidChangeHeight(animated: false) }

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

// MARK: - AppRowView.Delegate (T-8, PLAN §C decisions 3/4/6/8)
//
// Each callback drives the corresponding `AppRoutingController` mutation, then
// the SAME state-preserving `rebuild()` the running-app picker uses (a plain
// `rebuild()`, NOT `rebuildForOpen()`, so this open's transient collapse state
// survives). The panel stays a pure function of controller state — no in-place
// row mutation.

extension PopoverController: AppRowView.Delegate {

    public func appRow(_ row: AppRowView, didSetVolume volume: Int, for appID: String) {
        appRouting.setVolume(volume, for: appID)
        rebuild()
    }

    public func appRow(_ row: AppRowView, didSelectDestination destinationID: String, for appID: String) {
        appRouting.setDestination(destination(forID: destinationID), for: appID)
        rebuild()
    }

    public func appRow(_ row: AppRowView, didRemoveFor appID: String) {
        appRouting.removeRoute(bundleID: appID)
        rebuild()
    }
}
