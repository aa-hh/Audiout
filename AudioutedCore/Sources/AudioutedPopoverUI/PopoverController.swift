// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutedCore
import AudioutedSharedUI

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

/// The Applications card's **± footer** (T3, LOCKED DECISION): a single
/// `NSSegmentedControl` (`.momentaryAccelerator`) with two segments — "plus"
/// opens the existing running-app picker, "minus" removes the currently
/// selected app row. Pure UI: both actions route back through `onAdd`/
/// `onRemove` closures so `PopoverController` stays the only thing that talks
/// to `AppRoutingController`. Replaces the retired full-width "Add
/// application…" row as the card's sole add affordance.
private final class ApplicationsFooterView: NSView {

    private enum Segment: Int { case add = 0, remove = 1 }

    var onAdd: (() -> Void)?
    var onRemove: (() -> Void)?

    private let segmented = NSSegmentedControl()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320,
                                 height: PopoverColumnGrid.applicationsFooterRowHeight))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildSubviews() {
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.segmentStyle = .texturedRounded
        segmented.trackingMode = .momentaryAccelerator
        segmented.segmentCount = 2
        let addSymbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add application")
        let removeSymbol = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove application")
        segmented.setImage(addSymbol, forSegment: Segment.add.rawValue)
        segmented.setImage(removeSymbol, forSegment: Segment.remove.rawValue)
        segmented.setWidth(PopoverColumnGrid.applicationsFooterControlWidth / 2, forSegment: Segment.add.rawValue)
        segmented.setWidth(PopoverColumnGrid.applicationsFooterControlWidth / 2, forSegment: Segment.remove.rawValue)
        segmented.target = self
        segmented.action = #selector(segmentTapped(_:))
        segmented.setAccessibilityLabel("Add or remove application")

        addSubview(segmented)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: PopoverColumnGrid.applicationsFooterRowHeight),
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: PopoverColumnGrid.leadingInset),
            segmented.centerYAnchor.constraint(equalTo: centerYAnchor),
            segmented.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.applicationsFooterControlWidth),
            segmented.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.applicationsFooterControlHeight),
        ])
    }

    /// Whether the "−" segment is enabled — false when nothing is selected
    /// (LOCKED DECISION: disabled with no selection).
    var isRemoveEnabled: Bool {
        get { segmented.isEnabled(forSegment: Segment.remove.rawValue) }
        set { segmented.setEnabled(newValue, forSegment: Segment.remove.rawValue) }
    }

    @objc private func segmentTapped(_ sender: NSSegmentedControl) {
        switch Segment(rawValue: sender.selectedSegment) {
        case .add: onAdd?()
        case .remove: onRemove?()
        case nil: break
        }
    }

    // MARK: Test-support hooks

    /// Simulate tapping the "+" segment.
    func test_tapAdd() { onAdd?() }
    /// Simulate tapping the "−" segment.
    func test_tapRemove() { onRemove?() }
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

    /// Live per-device "which apps are actually streaming here now" map (T9),
    /// keyed by device id — driven entirely by `BackendEvent.routedApps` via
    /// ``applyRoutedApps(deviceID:appNames:)``. This is the CONFIRMED signal
    /// (T6/T8: only apps whose per-app capture is actually alive), distinct
    /// from `AppRoutingController.routedAppNames(for:)` which reflects routing
    /// INTENT (what's configured) regardless of whether it's live. A device
    /// with no entry here has nothing confirmed streaming to it — either
    /// because it was never a redirect target, or because a route exists but
    /// hasn't started producing audio yet (e.g. still connecting). See
    /// `DeviceRowView.apply`'s `liveAppNames` doc for the precedence rule this
    /// feeds into.
    private var liveRoutedAppNames: [String: [String]] = [:]

    /// Bundle IDs of routed apps whose process is currently NOT running (T4).
    /// Populated by `BackendEvent.routedAppRunning(isRunning: false)` and
    /// cleared by `isRunning: true`. An app row with its bundle ID in this set
    /// renders an offline indicator so the user knows the redirect is saved but
    /// inactive. The row stays interactive — the user can still change the
    /// route destination while the app is offline.
    private var offlineBundleIDs: Set<String> = []

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

    /// Called when the user taps the header's Settings button (task A). The app
    /// wires this to open the Settings window.
    public var onOpenSettings: (() -> Void)?

    /// Called when an Applications-card slider moves, so the app can push the new
    /// volume straight to a `.currentDevice` app's LOCAL playback stream (Bug T2)
    /// for a low-latency response, in ADDITION to the persisted
    /// `AppRoutingController.setVolume` edit. The app wires this to
    /// `(backend as? AppRouteConfiguring)?.setLocalPlaybackVolume`. Called
    /// unconditionally (for every route kind): the backend no-ops it for a bundle
    /// ID with no live local stream, so the popover needs no destination knowledge.
    public var onSetLocalPlaybackVolume: ((_ volume: Int, _ bundleID: String) -> Void)?

    /// Predicate: is `bundleID` excluded from capture (Settings › Audio, "never
    /// captured")? An excluded app is un-routable — dropped from the "+ Add
    /// application…" picker and its route row skipped in `rebuild` (defensive; the
    /// app also prunes the persisted route when an app is excluded). Wired by the
    /// app; defaults to "never excluded" so existing call sites/tests are
    /// unaffected.
    public var isAppExcluded: (String) -> Bool = { _ in false }

    private let panel = PopoverPanelViewController()

    /// The single System-section Main Out row.
    private let mainOutRow = MainOutRowView()

    private var deviceRowsByID: [String: DeviceRowView] = [:]

    /// The transient "AirPlay 1 support is coming soon" explanation popover
    /// (T-UI-AP1-1). Held so a second click can close/reopen it rather than
    /// leaking a stray `NSPopover`; entirely separate from `popover` (the main
    /// dropdown), which stays exactly content-sized and is never touched here.
    private var unsupportedExplanationPopover: NSPopover?

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

    /// The Applications card's single selection (T1/T3 seam): the bundle id of
    /// the currently selected app row, or `nil` when nothing is selected. This
    /// is the HOST's source of truth — `AppRowView` only renders whatever
    /// `isSelected` it's pushed. Survives `rebuild()` (which recreates every
    /// row) exactly like `transientCollapsed`: it is NEVER cleared by a
    /// rebuild, only by an explicit selection change or the selected app being
    /// removed. Cleared when the selected app no longer has a route (removed
    /// via any of the three remove paths, or dropped for some other reason).
    private var selectedAppBundleID: String?

    /// Active only while the popover is open: a local mouse-down monitor that
    /// clears `selectedAppBundleID` when the user clicks outside any app row or
    /// the ± footer (deselect-on-outside-click). Installed in `popoverDidShow`,
    /// removed in `popoverDidClose`.
    private var deselectClickMonitor: Any?

    /// The Applications card's ± footer row (T3, LOCKED DECISION — replaces
    /// the retired "+ Add application…" row as the card's add affordance).
    private let applicationsFooter = ApplicationsFooterView()

    /// The previous device snapshot's ids-that-were-valid-AirPlay-targets, so
    /// `update(devices:)` can detect a routed device disappearing or going
    /// unavailable and drive `appRouting.handleDeviceUnavailable(id:)` (PLAN
    /// decision 7 — silent fallback). "Valid target" == present AND available AND
    /// non-local, exactly the set `availableAirPlayDestinations` offers as a
    /// redirect target. `nil` until the first snapshot arrives (so the very first
    /// `update` never mistakes "not seen yet" for "went away").
    private var lastValidDestinationIDs: Set<String>?

    /// The sentinel destination id the Applications card's "Current Device" entry
    /// carries (T-8). `AppRouteDestination.currentDevice` names no specific device,
    /// but `AppRowView` works in plain string ids; this sentinel bridges the two
    /// and is chosen so it can never collide with a real `Device.id`.
    static let currentDeviceDestinationID = "\u{0000}current-device"

    /// The sentinel destination id the Applications card's standalone "No
    /// Redirect" entry carries — the new default/neutral state for a newly-added
    /// app (`AppRouteDestination.noRedirect`), distinct from the now-explicit
    /// "Current Device" pick. Chosen so it can never collide with a real
    /// `Device.id` or with `currentDeviceDestinationID`.
    static let noRedirectDestinationID = "\u{0000}no-redirect"

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
        applicationsFooter.onAdd = { [weak self] in
            guard let self else { return }
            self.presentAddApplicationPicker(relativeTo: self.applicationsFooter)
        }
        applicationsFooter.onRemove = { [weak self] in self?.removeSelectedApp() }
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
        // Drop any live-streaming entry (T9) for a device that vanished from the
        // snapshot entirely. Defensive: a normal route-change already clears the
        // entry itself (a redirect leaving X emits `.routedApps(X, [])`), but a
        // device that drops off the network without a route-table change first
        // (e.g. no app was ever routed to it) should never let a stale confirmed
        // name resurface if the same device id reappears later.
        liveRoutedAppNames = liveRoutedAppNames.filter { devicesByID[$0.key] != nil }
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
        //
        // A device being added or removed also restructures the device rows —
        // `refreshDeviceRows()` only repaints EXISTING rows, so a device set
        // change (not just a route change) must force the same full rebuild path.
        // STABILITY(D4): this full rebuild can run mid-slider-drag and detach the row under the cursor — skip or defer while any row's drag flag is live; see dev/notes/stability-audit-2026-07-18.md
        let deviceSetChanged = Set(devicesByID.keys) != Set(deviceRowsByID.keys)
        if popover.isShown {
            if routesChanged || deviceSetChanged {
                rebuild()
                panel.panelContentDidChangeHeight(animated: true)
            } else {
                refreshDeviceRows()
                refreshMainOutRow()
                reconcileDiagnosisPanels(animated: true)
            }
        } else {
            rebuild()
        }
    }

    /// Store the latest CONFIRMED per-device streaming map (T9,
    /// `BackendEvent.routedApps`) and let it feed the next repaint. Called by
    /// the host (`AppDelegate`) directly — unlike `Device` fields this signal
    /// has no home on `Device` (a redirect target is deliberately not
    /// `isSelected`, `AudioutedCore/AGENTS.md`), so it can't ride
    /// `update(devices:)`'s snapshot and gets its own entry point instead. An
    /// empty `appNames` clears the mapping for `deviceID` (the live set went
    /// back to empty — connecting, stopped, or the route was removed), which
    /// drops the row back to the intent-based label rather than showing a
    /// stale confirmed app. Doesn't repaint itself — callers already fall
    /// through to the shared `update(devices:)` repaint tail, same as every
    /// other `BackendEvent` case (see `AppDelegate.apply(_:)`); tests/harness
    /// code calling this directly should follow with `update(devices:)` or rely
    /// on the next natural repaint.
    public func applyRoutedApps(deviceID: String, appNames: [String]) {
        if appNames.isEmpty {
            liveRoutedAppNames.removeValue(forKey: deviceID)
        } else {
            liveRoutedAppNames[deviceID] = appNames
        }
    }

    /// Record a routed-app process-lifecycle change (T4, `BackendEvent.routedAppRunning`).
    /// Called by the host (`AppDelegate`) directly — the signal has no home on
    /// `Device` and can't ride `update(devices:)`. Stores the offline state and
    /// triggers a rebuild so the app row's indicator refreshes. If the popover is
    /// not currently shown, the rebuild is deferred to the next `update(devices:)`
    /// via the standard `rebuild()` path that always runs off device events.
    public func applyRoutedAppRunning(bundleID: String, isRunning: Bool) {
        if isRunning {
            offlineBundleIDs.remove(bundleID)
        } else {
            offlineBundleIDs.insert(bundleID)
        }
        // Rebuild in place (not a reopen) so this open's transient collapse state
        // is preserved — same discipline as `applyRoutedApps`.
        if popover.isShown {
            rebuild()
            panel.panelContentDidChangeHeight(animated: false)
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

        // Prune offline tracking for apps that no longer have a route (T4).
        // A de-routed app can never come back as "online" via `handleAppLaunched`
        // (which only acts on routed bundle IDs), so any stale entry here is
        // dead weight and should not bleed onto a future route for the same id.
        let currentRouteIDs = Set(appRouting.appRoutes.map(\.bundleID))
        offlineBundleIDs = offlineBundleIDs.intersection(currentRouteIDs)

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
            // "VOLUME" over the slider and "Selected" over the membership
            // checkbox on the right. Collapsible (main merge) — the collapse key
            // must equal the display header, since cards are looked up by header
            // title.
            panel.beginCard(header: "Devices", volumeTitle: "Volume", trailingTitle: "Selected",
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
        // `AppRowView` per routed app in stable `appRoutes` order, then the ±
        // footer (T3, LOCKED DECISION — replaces the old "+ Add application…"
        // row; the card is always present even with no routes since the
        // footer's "+" segment is always available).
        //
        // Collapsible (T-4/T-5): collapse DEFAULT is "expanded iff ≥1 app is
        // redirected" (`applicationsDefaultExpanded`), recomputed on every OPEN
        // and preserved across mid-open rebuilds by `collapsedState(for:default:)`
        // — same machinery as the other two cards. `collapsed:` is the negation of
        // the expanded default.
        //
        // Selection (T1/T3 seam): a stale `selectedAppBundleID` (its route was
        // removed by some other path, e.g. the device-drop fallback) is pruned
        // BEFORE building rows, so no row is ever pushed a selection that no
        // longer exists and the "−" segment correctly disables.
        if let selected = selectedAppBundleID,
           !appRouting.appRoutes.contains(where: { $0.bundleID == selected }) {
            selectedAppBundleID = nil
        }
        let title = Self.applicationsCardTitle
        panel.beginCard(header: title, volumeTitle: "Volume", trailingTitle: "Redirect",
                        collapsible: true,
                        collapsed: collapsedState(for: title, default: !applicationsDefaultExpanded),
                        onToggle: { [weak self] in self?.toggleCard(title) })
        for route in appRouting.appRoutes where !isAppExcluded(route.bundleID) {
            panel.addRow(makeAppRow(route, devices: allDevices))
        }
        applicationsFooter.isRemoveEnabled = selectedAppBundleID != nil
        panel.addRow(applicationsFooter)

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
    private var applicationsDefaultExpanded: Bool {
        appRouting.appRoutes.contains { $0.destination != .noRedirect }
    }

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
        // No accent-wash pill in the popover (2026-07-14 — ahh: no longer
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

    /// Whether an app route currently redirects to this device — the canonical
    /// `isRedirectTarget` source (backs `controllable` and the Q4 retry path).
    private func isRedirectTarget(_ id: String) -> Bool {
        !appRouting.routedAppNames(for: id).isEmpty
    }

    /// Push the current membership + local-block state into a device row.
    private func applySelectionState(to row: DeviceRowView, device: Device) {
        guard let controller = groupController else {
            // No controller ⇒ nothing routable ⇒ not controllable.
            row.apply(device, selected: false, controllable: false,
                      routedAppNames: appRouting.routedAppNames(for: device.id),
                      liveAppNames: liveRoutedAppNames[device.id] ?? [])
            return
        }
        let selected = controller.isSpeakerSelected(device.id)
        // Block only the local device when it can't currently be turned ON.
        let blocked = device.isLocalDevice && !selected && !controller.canSelectLocalSpeaker(device.id)
        row.apply(device,
                  selected: selected,
                  controllable: controller.isSpeakerSelected(device.id) || isRedirectTarget(device.id),
                  blocked: blocked,
                  blockReason: blocked ? GroupController.localMixRefusalReason : nil,
                  routedAppNames: appRouting.routedAppNames(for: device.id),
                  liveAppNames: liveRoutedAppNames[device.id] ?? [])
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

    // MARK: Applications card ± footer (T3, LOCKED DECISION)

    /// The footer's "−" segment: remove the currently selected app (no-op if
    /// nothing is selected — the segment is disabled in that state, but this
    /// guard keeps `test_tapRemove` safe to call unconditionally too).
    private func removeSelectedApp() {
        guard let bundleID = selectedAppBundleID else { return }
        removeApp(bundleID: bundleID)
    }

    /// Remove `bundleID`'s route via the SAME path all three removal
    /// affordances funnel through (± footer "−", context-menu "Remove from
    /// list", Delete/Backspace — `AppRowView.Delegate.appRow(_:didRemoveFor:)`
    /// calls this too). If the removed app was selected, selection advances to
    /// its neighbor in `appRoutes` order (LOCKED DECISION) — preferring the
    /// row that slides into the removed row's old position (the next route),
    /// falling back to the previous one, and clearing selection entirely when
    /// the list becomes empty.
    private func removeApp(bundleID: String) {
        if selectedAppBundleID == bundleID {
            selectedAppBundleID = neighborBundleID(of: bundleID)
        }
        appRouting.removeRoute(bundleID: bundleID)
        rebuild()
    }

    /// The bundle id that should become selected after `bundleID` is removed:
    /// the route immediately after it in `appRoutes` order, else the one
    /// immediately before, else `nil` (the list is now empty).
    private func neighborBundleID(of bundleID: String) -> String? {
        let routes = appRouting.appRoutes
        guard let index = routes.firstIndex(where: { $0.bundleID == bundleID }) else { return nil }
        if index + 1 < routes.count { return routes[index + 1].bundleID }
        if index - 1 >= 0 { return routes[index - 1].bundleID }
        return nil
    }

    // MARK: Applications card rows (T-8, PLAN §C decisions 3/4/6/8)

    /// Build one `AppRowView` for `route` against the discovered device `devices`.
    /// The destination popup leads with the standalone "No Redirect" entry (the
    /// new default/neutral state), then mirrors `refreshMainOutRow`'s split — a
    /// "Current Device" entry (local, now an explicit pick) then the available
    /// (present + reachable) non-local AirPlay devices. The selected id is
    /// derived from `route.destination`, and the slider dims while local
    /// (decision 3, driven inside `AppRowView` by the selected entry's `isLocal`
    /// — true for both "No Redirect" and "Current Device").
    private func makeAppRow(_ route: AppRoute, devices: [Device]) -> AppRowView {
        let row = AppRowView()
        row.delegate = self
        row.apply(AppRowView.Configuration(
            appID: route.bundleID,
            name: route.displayName,
            icon: appIcon(for: route.bundleID),
            volume: route.volume,
            selectedDestinationID: destinationID(for: route.destination),
            destinations: appDestinations(devices: devices),
            isRunning: !offlineBundleIDs.contains(route.bundleID)),
                  isSelected: route.bundleID == selectedAppBundleID)
        appRowsByBundleID[route.bundleID] = row
        return row
    }

    /// The destination entries for the Applications popup, in display order:
    /// the standalone "No Redirect" entry (the default/neutral state) first,
    /// then the "Current Device" entry (decision 8, now an explicit pick),
    /// then every AVAILABLE non-local device (`availableAirPlayDestinations`).
    /// Plain values only — `AppRowView` is isolated from Core's `AppRoute` (T-6).
    private func appDestinations(devices: [Device]) -> [AppRowView.Destination] {
        var entries: [AppRowView.Destination] = [
            .init(id: Self.noRedirectDestinationID,
                  title: "No Redirect",
                  isLocal: true,
                  symbolName: nil,
                  isStandalone: true),
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
    /// by: one of the two local sentinels for `.noRedirect`/`.currentDevice`, or
    /// the device id for `.device(id:)`.
    private func destinationID(for destination: AppRouteDestination) -> String {
        switch destination {
        case .noRedirect:          return Self.noRedirectDestinationID
        case .currentDevice:       return Self.currentDeviceDestinationID
        case .device(let id):      return id
        }
    }

    /// Inverse of `destinationID(for:)`: either sentinel maps back to its own
    /// local case, any other id to `.device(id:)`.
    private func destination(forID id: String) -> AppRouteDestination {
        if id == Self.noRedirectDestinationID { return .noRedirect }
        if id == Self.currentDeviceDestinationID { return .currentDevice }
        return .device(id: id)
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
        // Also drop excluded apps (Settings › Audio, "never captured") — routing
        // an app the user has excluded would contradict the exclusion.
        return runningAppsProvider().filter { !routed.contains($0.bundleID) && !isAppExcluded($0.bundleID) }
    }

    /// Add a route for `bundleID`/`displayName` (defaults to `.noRedirect` —
    /// the new neutral/unset state for a newly-added app) and rebuild,
    /// preserving this open's transient collapse state (a plain `rebuild()`,
    /// not `rebuildForOpen()`).
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
        FileHandle.standardError.write(Data("[Audiouted] \(reason)\n".utf8))
    }

    // MARK: AP1-only "coming soon" explanation (T-UI-AP1-1, PLAN-PHASE-2B D6)

    /// Present the small transient content-sized explanation popover anchored
    /// to `row`. Closes any previous instance first (repeat clicks reposition
    /// rather than stack popovers). No-ops off-screen (`row.window == nil`,
    /// e.g. a headless test harness that never attaches the panel to a real
    /// window) — `test_lastUnsupportedExplanationDeviceID` is the headless
    /// assertion surface instead of a real `NSPopover.show`.
    private func presentUnsupportedExplanation(anchoredTo row: DeviceRowView) {
        unsupportedExplanationPopover?.performClose(nil)

        let explanationController = NSViewController()
        let label = NSTextField(wrappingLabelWithString: DeviceRowView.unsupportedExplanation)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 20))
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            content.widthAnchor.constraint(equalToConstant: 220),
        ])
        explanationController.view = content

        let explanationPopover = NSPopover()
        explanationPopover.behavior = .transient   // dismisses on outside click/Esc
        explanationPopover.contentViewController = explanationController
        explanationPopover.contentSize = content.fittingSize
        unsupportedExplanationPopover = explanationPopover

        test_lastUnsupportedExplanationDeviceID = row.device.id
        // A headless harness/test never attaches the panel to a real
        // `NSWindow`; guard so this stays crash-free there while still
        // recording the intent above for `test_` assertions.
        guard row.window != nil else { return }
        explanationPopover.show(relativeTo: row.bounds, of: row, preferredEdge: .maxY)
    }

    // MARK: Test-support hooks

    public func test_deviceRow(for id: String) -> DeviceRowView? {
        deviceRowsByID[id]
    }

    /// The device id of the row a "coming soon" explanation was last shown for
    /// (T-UI-AP1-1), `nil` until one has fired. The headless assertion surface
    /// for `presentUnsupportedExplanation` — no real `NSWindow` is required.
    public private(set) var test_lastUnsupportedExplanationDeviceID: String?

    /// Simulate clicking `id`'s row (drives the real `mouseDown:` path via
    /// `DeviceRowView.test_simulateClick`). No-op if the row is missing or
    /// isn't currently rendered as unsupported.
    public func test_clickDeviceRow(id: String) {
        deviceRowsByID[id]?.test_simulateClick()
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
    /// routed app; excludes the ± footer row).
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

    // MARK: Applications card ± footer test hooks (T3)

    /// The Applications card's current single selection, or `nil` (the HOST's
    /// source of truth — survives `rebuild()`).
    public var test_selectedAppBundleID: String? { selectedAppBundleID }

    /// Whether `bundleID`'s row currently renders the selected-row highlight.
    /// `nil` if no such row.
    public func test_appRowIsSelected(for bundleID: String) -> Bool? {
        appRowsByBundleID[bundleID]?.test_isSelected
    }

    /// Whether the footer's "−" segment is currently enabled (LOCKED DECISION —
    /// disabled iff nothing is selected).
    public var test_applicationsFooterRemoveEnabled: Bool { applicationsFooter.isRemoveEnabled }

    /// Simulate the row's body being clicked, requesting selection — drives
    /// the same `AppRowView.Delegate.appRow(_:didRequestSelect:)` path a real
    /// click takes. No-op if `bundleID` has no row.
    public func test_selectAppRow(bundleID: String) {
        guard let row = appRowsByBundleID[bundleID] else { return }
        appRow(row, didRequestSelect: bundleID)
    }

    /// Simulate tapping the footer's "+" segment — opens the same running-app
    /// picker the header would.
    public func test_tapApplicationsFooterAdd() { applicationsFooter.test_tapAdd() }

    /// Simulate tapping the footer's "−" segment — removes the selected app
    /// (no-op if nothing is selected, matching the real disabled-segment
    /// behavior).
    public func test_tapApplicationsFooterRemove() { applicationsFooter.test_tapRemove() }

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

    /// T-UI-AP1-1 (PLAN-PHASE-2B D6): an AP1-only row was clicked. Present a
    /// SMALL TRANSIENT content-sized `NSPopover` anchored to `row` with the
    /// "coming soon" explanation — independent of the main popover (which
    /// stays exactly content-sized and never gets a scrollbar).
    public func deviceRowDidRequestUnsupportedExplanation(_ row: DeviceRowView) {
        presentUnsupportedExplanation(anchoredTo: row)
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
        // Drive `.currentDevice` local stream immediately (low-latency path).
        // `appRouting.setVolume` fires `onRoutesDidChange` which re-pushes volumes
        // to the mixer/engine — no rebuild needed here; a rebuild would replace
        // the AppRowView mid-drag and break the NSSlider tracking loop.
        onSetLocalPlaybackVolume?(volume, appID)
        appRouting.setVolume(volume, for: appID)
    }

    public func appRow(_ row: AppRowView, didSelectDestination destinationID: String, for appID: String) {
        appRouting.setDestination(destination(forID: destinationID), for: appID)
        rebuild()
    }

    public func appRow(_ row: AppRowView, didRemoveFor appID: String) {
        removeApp(bundleID: appID)
    }

    /// T1/T3 selection seam: the row's body (or a right-click) was clicked,
    /// requesting single-selection. The HOST owns `selectedAppBundleID` — set
    /// it and rebuild so `isSelected` is re-pushed into every row (including
    /// the newly-deselected previous selection) and the footer's "−" segment
    /// enables.
    public func appRow(_ row: AppRowView, didRequestSelect appID: String) {
        guard selectedAppBundleID != appID else { return }
        selectedAppBundleID = appID
        rebuild()
    }

    // MARK: - App-row selection lifecycle (deselect discipline)
    //
    // App-row selection is TRANSIENT to a single open session and exists only
    // to target the ± footer's "−" (and Delete/Backspace). Two rules keep it
    // from feeling like a permanent, un-clearable state:
    //   1. It resets when the popover closes, so a fresh open never shows a
    //      selection carried over from a previous session.
    //   2. A mouse-down anywhere OUTSIDE an `AppRowView` or the ± footer clears
    //      it — empty space, a device row, the header, etc. all deselect, like
    //      clicking away from a table row.

    public func popoverDidShow(_ notification: Notification) {
        installDeselectMonitor()
    }

    public func popoverDidClose(_ notification: Notification) {
        removeDeselectMonitor()
        selectedAppBundleID = nil
    }

    private func installDeselectMonitor() {
        removeDeselectMonitor()
        deselectClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.deselectIfClickOutsideSelectedRow(event)
            return event
        }
    }

    private func removeDeselectMonitor() {
        if let monitor = deselectClickMonitor {
            NSEvent.removeMonitor(monitor)
            deselectClickMonitor = nil
        }
    }

    /// Clears the app-row selection when `event` is a click that is neither on
    /// an `AppRowView` (which selects it) nor on the ± footer (whose "−"/"+"
    /// must see the selection intact). The rebuild is deferred to the next
    /// runloop tick so the click still reaches its target view first — a
    /// synchronous rebuild here would destroy the very view being clicked.
    private func deselectIfClickOutsideSelectedRow(_ event: NSEvent) {
        guard selectedAppBundleID != nil,
              let window = popover.contentViewController?.view.window,
              event.window === window else { return }
        let hit = window.contentView?.hitTest(event.locationInWindow)
        if let hit,
           enclosingView(of: hit, ofType: AppRowView.self) != nil
               || enclosingView(of: hit, ofType: ApplicationsFooterView.self) != nil {
            return
        }
        selectedAppBundleID = nil
        DispatchQueue.main.async { [weak self] in self?.rebuild() }
    }

    private func enclosingView<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        var current: NSView? = view
        while let node = current {
            if let match = node as? T { return match }
            current = node.superview
        }
        return nil
    }

    /// Test hook: clear the app-row selection as an outside click would.
    public func test_deselectApp() {
        selectedAppBundleID = nil
        rebuild()
    }

    /// The set of bundle IDs currently tracked as offline (T4). Lets tests assert
    /// that `applyRoutedAppRunning` updated the tracking set correctly.
    public var test_offlineBundleIDs: Set<String> { offlineBundleIDs }

    /// Whether `bundleID`'s row is currently showing the offline badge (T4).
    /// `nil` if no such row exists in the Applications card.
    public func test_isAppRowOffline(bundleID: String) -> Bool? {
        appRowsByBundleID[bundleID]?.test_isOfflineBadgeVisible
    }
}
