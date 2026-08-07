// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

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
///    icon · "Main Out" · master gain slider + `%` · a trailing
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

    /// Called when the user taps the takeover status strip's "Open Login
    /// Items…" button (T6, state 1). The app wires this to
    /// `PTPHelperManaging.openSystemSettingsLoginItems()` — the same seam
    /// `SetupModel.openPTPHelperLoginItems()` already wraps for onboarding;
    /// this is a second call site onto the identical system deep link, not a
    /// new mechanism. `nil` (the default) means the button, if ever rendered,
    /// taps into nothing — the app always wires this in practice.
    public var onOpenPTPHelperLoginItems: (() -> Void)?

    /// Called when the user taps the routing-blocked note's "Use
    /// `AggregateOutputDevice.productName`" button (T-UI) — the app is
    /// actively routing but the aggregate isn't the Mac's current default
    /// output, so audio isn't reaching it. The app wires this to whatever
    /// re-selects the aggregate as the system default output. The user's own
    /// click is the intent here (Alec's Q6 call), so this does NOT violate
    /// the "never auto-reselect" rule elsewhere. `nil` (the default) means
    /// the button, if ever rendered, taps into nothing.
    public var onReselectAudiouter: (() -> Void)?

    /// Called with `true` on `popoverDidShow` and `false` on `popoverDidClose`
    /// (T-GATE): the metering-active gate. The app wires this to
    /// `(backend as? MeteringControlling)?.setMeteringActive(_:)` so the backend
    /// only computes/emits `.level` while a user can actually see a meter. `nil`
    /// means "no backend adopts the capability" — the popover works exactly the
    /// same either way, just without the RMS work switched off underneath it.
    public var onMeteringActiveChange: ((Bool) -> Void)?
    /// Called when an Applications-card slider moves, so the app can push the new
    /// volume straight to a `.currentDevice` app's LOCAL playback stream (Bug T2)
    /// for a low-latency response, in ADDITION to the persisted
    /// `AppRoutingController.setVolume` edit. The app wires this to
    /// `(backend as? AppRouteConfiguring)?.setLocalPlaybackVolume`. Called
    /// unconditionally (for every route kind): the backend no-ops it for a bundle
    /// ID with no live local stream, so the popover needs no destination knowledge.
    public var onSetLocalPlaybackVolume: ((_ volume: Int, _ bundleID: String) -> Void)?

    /// Called when the user picks "Pair a Bluetooth speaker…" from the OUTPUT
    /// DEVICES header's "+" menu (BT-UI, device-tier decision 3: never-paired
    /// speakers get NO rows — pairing is a one-tap Settings trip). The app
    /// wires this to open `SystemSettingsPane.bluetooth`; the fresh row then
    /// auto-appears on return via the enumerator refresh. `nil` = the menu
    /// item still renders but taps into nothing (tests wire a spy).
    public var onPairBluetoothSpeaker: (() -> Void)?

    /// When macOS last used each Bluetooth pairing, keyed by device id — the
    /// Bluetooth subsection's ghost-pairing sort input (stale pairings sink to
    /// the BOTTOM; sort-only in v1, nothing is hidden). The app wires this to
    /// `(backend as? BTOutputControlling)?.lastUsedDatesForBTDevices`. `nil`
    /// (mock/tests without the capability) sorts by name alone.
    public var btLastUsedProvider: (() -> [String: Date])?

    /// Called when a Bluetooth row's SYNC trim changes (BT-OFFSET-UI), already
    /// clamped. The app wires this to
    /// `(backend as? BTOutputControlling)?.setBTSyncTrim` — live-applied to
    /// that device's `BTSyncedSink` delay and persisted per device UID.
    public var onSetBTTrim: ((_ ms: Double, _ deviceID: String) -> Void)?

    /// The saved SYNC trim for a Bluetooth device id — seeds each row's value
    /// (and the read-only display on a disconnected row). Wired to
    /// `(backend as? BTOutputControlling)?.btSyncTrim`. `nil` = 0, and edits
    /// then live only in `btTrimsByID` (mock/dev — nothing persists them).
    public var btTrimProvider: ((_ deviceID: String) -> Double)?

    /// The usable trim range for a Bluetooth device id (D11/T3) — the
    /// drawer's hard-stop, tighter than the nominal ±`BTSyncTrim.rangeMs`
    /// whenever the device's real headroom is smaller. Wired to
    /// `(backend as? BTOutputControlling)?.btUsableTrimRangeMs`. `nil` (mock/
    /// dev builds, or no BT capability) means the full ±range.
    ///
    /// LIVE QUERY, same as the backend seam it wraps: the range moves
    /// whenever AirPlay joins or leaves the group, so callers must invoke
    /// this fresh every time they need it — never cache the result, not even
    /// for the lifetime of one open drawer (T7 re-reads it on every
    /// `update(devices:)`).
    public var btTrimRangeProvider: ((_ deviceID: String) -> ClosedRange<Double>)?

    /// Called with `true`/`false` as the align-by-ear tick starts/stops
    /// (BT-OFFSET-UI). Wired to
    /// `(backend as? BTOutputControlling)?.setBTAlignTickActive`.
    public var onAlignTickActiveChange: ((_ active: Bool) -> Void)?

    /// The freshest trim value per device id (the user's latest edit, or the
    /// provider's persisted value on first read) — the rows' apply source, so
    /// a rebuild never has to round-trip the backend.
    private var btTrimsByID: [String: Double] = [:]

    /// The row whose align-by-ear tick is currently running, if any. One at a
    /// time: toggling another row's button moves the single tick.
    private var alignTickDeviceID: String?
    /// Auto-stop for the align tick (~30 s — mirrors the injector's own tick
    /// budget so the button can't stay lit after the ticks end).
    private var alignTickAutoStop: DispatchWorkItem?
    static let alignTickAutoStopInterval: TimeInterval = 30

    /// Predicate: is `bundleID` excluded from capture (Settings › Audio, "never
    /// captured")? An excluded app is un-routable — dropped from the "+ Add
    /// application…" picker and its route row skipped in `rebuild` (defensive; the
    /// app also prunes the persisted route when an app is excluded). Wired by the
    /// app; defaults to "never excluded" so existing call sites/tests are
    /// unaffected.
    public var isAppExcluded: (String) -> Bool = { _ in false }

    /// Resolves a per-device SF Symbol override for device rows (icon-picker
    /// feature). Injected by the app; `nil` (the default) preserves current
    /// behavior — every `DeviceRowView.apply` call site omits `iconSymbolName`
    /// and falls back to `device.kind.symbolName` exactly as before. Setting
    /// this also chains an `onChange` observer (below) that refreshes the
    /// mounted device rows so an icon-picker edit shows up without a manual
    /// popover reopen.
    public var deviceIconController: DeviceIconController? {
        didSet {
            let previousOnChange = deviceIconController?.onChange
            deviceIconController?.onChange = { [weak self] in
                previousOnChange?()
                self?.refreshDeviceRows()
            }
        }
    }

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

    /// Ids whose diagnosis panel the user explicitly DISMISSED (the ✕, B2)
    /// during the CURRENT failure episode. Distinct from `openDiagnosisIDs` (the
    /// open intent) and mutually exclusive with it: a dismissed id is recorded
    /// here so no mere repaint/rebuild can resurrect its panel, and cleared at
    /// every episode boundary — leaving `.failed` (`→ .connected`/`→ .off`) OR a
    /// fresh `→ .failed` edge (a NEW episode whose auto-expand wins). See
    /// `handleConnectionTransitions` / `dismissDiagnosisPanel`.
    private var dismissedDiagnosisIDs: Set<String> = []

    /// The mounted `ConnectionDiagnosisView` per device id — the view-layer
    /// mirror of `openDiagnosisIDs`, rebuilt by `reconcileDiagnosisPanels`.
    private var diagnosisPanelsByID: [String: ConnectionDiagnosisView] = [:]

    // MARK: Energize (Warm Signal v4.1 item 9 — source-switch "press-play")

    /// The device ids currently showing the energize PENDING beat (item 9): the
    /// members of the just-switched Main-Audio target that hadn't started
    /// connecting yet (`connectionState == .off`) at the switch instant. Their
    /// rows render `MembershipBusView.Node.pending` (ember dashed, on-spine) —
    /// the instant "press-play" drop — until their real `connectionState`
    /// advances (`→ .connecting`, then `→ .member`), at which point
    /// `reconcileEnergize()` prunes them and the model state carries the node.
    /// It is a PRESENTATION set only — it never gates membership/connection/
    /// routing. Empty (and untouched) under Reduce Motion, so the sweep is
    /// removed and every row snaps to its resolved state (spec item 9).
    private var energizePendingIDs: Set<String> = []

    /// Whether an energize sequence is mid-flight (a source switch is still
    /// resolving). Gates the one-shot settle announcement so it fires exactly
    /// once, when the active target stops moving.
    private var energizeActive = false

    /// Display name of the target the current energize is switching TO ("Selected
    /// Devices" or a saved group's name), for the VoiceOver announcements.
    private var energizeTargetName: String?

    /// The last VoiceOver announcement the energize posted — a deterministic
    /// test seam (headless runs can't observe the real accessibility post).
    private var lastEnergizeAnnouncement: String?

    /// The mounted in-place refusal-note row per BLOCKED device id (spec §4.6):
    /// a body-click on a local-mix-blocked row toggles a one-line note carrying
    /// `GroupController.localMixRefusalReason` directly under it — the reachable
    /// trigger the disabled checkbox + tooltip alone lacked (§8.5). Transient
    /// (cleared by every `rebuild()`, like the hover/selection state), so it never
    /// resurrects after a repaint.
    private var blockedNoteByID: [String: NSView] = [:]

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

    /// Whether the LAST `rebuild()` mounted the Devices card's "Looking for
    /// devices…" empty-state placeholder (V2) — recorded per rebuild so tests can
    /// assert it appears with no devices and vanishes once devices arrive.
    private var devicesPlaceholderShown = false

    /// Whether the LAST `rebuild()` mounted the Applications card's "No apps
    /// routed…" empty-state placeholder (V11).
    private var applicationsPlaceholderShown = false

    /// The previous device snapshot's ids-that-were-valid-AirPlay-targets, so
    /// `update(devices:)` can detect a routed device dropping out of the offerable
    /// set. "Valid target" == present AND available AND non-local, exactly the set
    /// `availableAirPlayDestinations` offers as a redirect target. `nil` until the
    /// first snapshot arrives (so the very first `update` never mistakes "not seen
    /// yet" for "went away").
    ///
    /// Leaving this set is NOT on its own grounds to reset a route (R5): only a
    /// device that also left `devicesByID` entirely is gone for good and drives
    /// `appRouting.handleDeviceDisappeared(id:)`. A device that merely went
    /// `isAvailable == false` keeps its route — see `update(devices:)`.
    private var lastValidDestinationIDs: Set<String>?

    /// The set of device ids that were Main Out members at the last `update`
    /// (`GroupController.isMainOutMember`). `nil` until the first snapshot.
    /// A change here means a speaker joined or left the whole-system mix, which
    /// changes what every app row's redirect menu may offer — a speaker now in
    /// Main Out is dropped from the menus (one role per speaker), and one that
    /// just left is offerable again. Without this, selecting a speaker into Main
    /// Out (which fires an `update` but changes neither the route table, the
    /// fleet, nor the valid-target set) would leave the redirect menus stale,
    /// still offering a speaker that is now carrying the mix.
    private var lastMainOutMemberIDs: Set<String>?

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

    /// The sentinel PREFIX a "Resume → <device>" destination entry's id carries
    /// (see `appDestinations(devices:keeping:bundleID:)`) — offered when
    /// `AppRoutingController.clearedDeviceRouteTarget(for:)` names a device the
    /// app-quit reset cleared and that device is currently available again. The
    /// underlying device id is appended after the prefix so `destination(forID:)`
    /// can recover it; prefixed (rather than reusing the plain device id) so this
    /// entry never collides with that same device's own plain entry lower in the
    /// same popup.
    static let resumeDestinationIDPrefix = "\u{0000}resume:"

    /// Builds the destination-popup id for a "Resume → <device>" entry
    /// targeting `deviceID`. Inverse of the prefix-stripping in
    /// `destination(forID:)`.
    static func resumeDestinationID(forDeviceID deviceID: String) -> String {
        resumeDestinationIDPrefix + deviceID
    }

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
        // mixer window (where group membership editing lives); Settings forwards
        // to `onOpenSettings` (the app wires it to the Settings window).
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
        let previousDevices = devicesByID
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        // A SELECTED Bluetooth device that LOSES availability is DESELECTED
        // (Alec's call — off = unselected, replacing the backend's power-off
        // park). Both loss paths — a listed-but-disconnected snapshot AND a
        // vanish (unpair mid-session, sleep) — reach this surface as the same
        // availability edge on a kept row, so one edge covers them. Routed
        // through `setDeviceSelected` (the one selection owner — persist,
        // re-route, current-device floor), the same path a user's toggle-off
        // takes; the mirror of `handleDeviceDisappeared`'s route reset below.
        // Edge-only on purpose: a selection made ON an already-greyed row
        // ("play when up") has no edge and survives, so it still auto-starts
        // on connect; and a `.failed` story alone never deselects (R12) — only
        // the availability fact does.
        if let controller = groupController {
            for device in devices where device.isBluetooth && !device.isAvailable {
                guard previousDevices[device.id]?.isAvailable == true,
                      controller.isSpeakerSelected(device.id) else { continue }
                _ = controller.setDeviceSelected(device.id, false)
            }
        }
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
        // fallback), NARROWED by R5 to the one case that genuinely loses the
        // target. A device that was a valid AirPlay redirect target last snapshot
        // but isn't now falls into two very different situations, and only the
        // second may touch the route table:
        //
        //  1. Still in the snapshot, but `isAvailable == false` (a sticky-AP2
        //     receiver powered off, a Wi-Fi blip, a receiver gone quiet). The
        //     user's intent is intact and the device is expected back, so the route
        //     is KEPT. `NativeBackend`'s effective route table stops excluding the
        //     app for the duration (it rejoins the whole-system mix, so it stays
        //     audible) and re-engages the redirect by itself on recovery — no
        //     route-table edit is involved in either direction. The row still shows
        //     the target thanks to `appDestinations`' offline entry.
        //  2. Gone from the snapshot entirely (`deviceRemoved`). There is nothing
        //     left to come back to, so this — and only this — resets the route.
        //
        // `handleDeviceDisappeared` no-ops when no route targeted the id, so this
        // only mutates when a routed target actually went away for good.
        let nowValid = Set(availableAirPlayDestinations(devices: devices).map(\.id))
        var routesChanged = false
        var validTargetsChanged = false
        if let previous = lastValidDestinationIDs {
            let routedBefore = appRouting.appRoutes
            for goneID in previous.subtracting(nowValid) where devicesByID[goneID] == nil {
                appRouting.handleDeviceDisappeared(id: goneID)
            }
            routesChanged = appRouting.appRoutes != routedBefore
            validTargetsChanged = previous != nowValid
        }
        lastValidDestinationIDs = nowValid

        // One role per speaker: a speaker joining or leaving Main Out changes what
        // the app rows' redirect menus may offer (a Main Out member is excluded as
        // a redirect target). Selecting a speaker fires an `update` but touches
        // none of the three triggers below — no route reset, no fleet change, no
        // valid-target change — so this membership diff is what keeps the menus
        // from going stale (still offering a speaker now carrying the mix, which is
        // the only remaining way to build the exact overlap the exclusion prevents).
        let nowMainOutMembers = Set(devices.compactMap {
            groupController?.isMainOutMember($0.id) == true ? $0.id : nil
        })
        let mainOutMembersChanged = lastMainOutMemberIDs != nil && lastMainOutMemberIDs != nowMainOutMembers
        lastMainOutMemberIDs = nowMainOutMembers

        // A route reset (routesChanged) restructures the Applications card, so it
        // needs a full rebuild — but a rebuild here must NOT reset this open's
        // transient collapse state (it's a mid-open repaint, not a reopen), which
        // a plain `rebuild()` guarantees (only `rebuildForOpen()` clears it).
        //
        // A device being added or removed also restructures the device rows —
        // `refreshDeviceRows()` only repaints EXISTING rows, so a device set
        // change (not just a route change) must force the same full rebuild path.
        //
        // `validTargetsChanged` is the R5 addition: an availability flip that no
        // longer resets any route still changes what every app row's destination
        // menu must offer (an entry drops out, or a kept route's target needs its
        // "Offline" entry injected). Before R5 that flip always came with a route
        // reset, so `routesChanged` covered it; now it has to be its own trigger or
        // the menus go stale until the next reopen.
        // STABILITY(D4): this full rebuild can run mid-slider-drag and detach the row under the cursor — skip or defer while any row's drag flag is live; see dev/notes/stability-audit-2026-07-18.md
        let deviceSetChanged = Set(devicesByID.keys) != Set(deviceRowsByID.keys)
        if isEffectivelyShown {
            if routesChanged || deviceSetChanged || validTargetsChanged || mainOutMembersChanged {
                rebuild()
                panel.panelContentDidChangeHeight(animated: true)
            } else {
                // A failure auto-deselect (handleConnectionTransitions above) can
                // change the checked set under a group target, flipping the
                // Devices card's dormancy note (S5) — the reconciling repaint
                // escalates to a rebuild exactly when the note must change.
                refreshDeviceRowsReconcilingCardNote()
                reconcileDiagnosisPanels(animated: true)
            }
        }
        // Not shown: deliberately NO rebuild. Every open goes through
        // `rebuildForOpen()` (see `toggle(relativeTo:)`), which rebuilds the whole
        // panel from the state ingested above — a closed popover never needs a
        // live view tree, and nothing reads it while closed (`statusMasterVolume`
        // reads `groupController` directly). Rebuilding here made every backend
        // event a hidden full rebuild storm under volume-key repeat (audit B8).
    }

    /// Store the latest CONFIRMED per-device streaming map (T9,
    /// `BackendEvent.routedApps`) and let it feed the next repaint. Called by
    /// the host (`AppDelegate`) directly — unlike `Device` fields this signal
    /// has no home on `Device` (a redirect target is deliberately not
    /// `isSelected`, `AudiouterCore/AGENTS.md`), so it can't ride
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
        if isEffectivelyShown {
            rebuild()
            panel.panelContentDidChangeHeight(animated: false)
        }
    }

    // MARK: Silence-fallback banner (Wave 2 W2-T2, R11)

    /// The exact banner copy from PLAN-RELIABILITY Wave 2.
    static let localFallbackBannerText = "Speakers unreachable — playing on this Mac. Will resume automatically."

    /// Whether the generalized silence watchdog (R11) has fallen back to local
    /// playback because zero desired devices stayed connected. Drives the banner;
    /// re-applied on every `rebuild()` so a rebuild mid-fallback keeps it pinned.
    private var localFallbackActive = false

    /// Show or clear the "Speakers unreachable" banner (`BackendEvent.localFallbackActive`).
    /// Called by the host (`AppDelegate`) directly — a whole-app condition with no home
    /// on `Device`. Idempotent: a repeat of the current state is a no-op.
    public func setLocalFallbackActive(_ active: Bool) {
        guard active != localFallbackActive else { return }
        localFallbackActive = active
        if isEffectivelyShown {
            // Update the banner in place and re-fit; not a full rebuild — the cards are
            // unchanged, only the pinned banner appears/disappears.
            panel.setBanner(active ? Self.localFallbackBannerText : nil)
            panel.panelContentDidChangeHeight(animated: true)
        }
        // When not shown, the next `rebuildForOpen()` re-applies it from
        // `localFallbackActive` (see the tail of `rebuild()`).
    }

    /// Test-only: whether the fallback banner is currently reflected in the panel.
    var test_localFallbackBannerText: String? { panel.test_bannerText }

    // MARK: System-AirPlay guard note (Wave 3 W3-T3) + takeover status strip (T6)
    //        + routing-blocked-needs-default warning (T-UI)
    //
    // All three conditions want the SAME physical note slot (`panel.setSystemAirPlayNote`)
    // — there is only one, never two stacked notes (PLAN-AIRPLAY-COEXISTENCE.md T6).
    // PRECEDENCE, highest first: routing-blocked (T-UI, WARNING severity — audio is
    // dead right now) outranks the takeover status, which outranks the double-path
    // guard note; each lower note reappears underneath the instant the one above it
    // clears. Each condition keeps its own idempotence-check state var
    // (`routingBlockedNeedsDefault` / `takeoverStatus` / `systemAirPlayNoteActive`);
    // `applyNoteSlot()` is the one place that resolves precedence and actually
    // pushes to the panel, called by every setter and by the tail of `rebuild()`.

    /// The exact note copy from PLAN-RELIABILITY Wave 3's "System-AirPlay guard"
    /// bullet: non-blocking, informational — this never changes what's actually
    /// streaming, it only tells the user why they might hear an echo.
    static let systemAirPlayNoteText =
        "Your Mac's system output is also set to AirPlay — audio may play twice. Switch it back to avoid an echo."

    /// Whether the system-AirPlay double-path guard (W3-T3) is currently active:
    /// this app is streaming a whole-system capture AND the macOS system default
    /// output is itself AirPlay-class. Drives the note; re-applied on every
    /// `rebuild()` so a rebuild mid-condition keeps it pinned.
    private var systemAirPlayNoteActive = false

    /// The takeover status strip's current state (T6), or `nil` when there's
    /// nothing to explain. Drives the note (see PRECEDENCE above); re-applied on
    /// every `rebuild()` so a rebuild mid-takeover keeps it pinned.
    private var takeoverStatus: TakeoverStatus?

    /// Whether the routing-blocked-needs-default warning (T-UI) is currently
    /// active: this app is actively routing but `AggregateOutputDevice.productName`
    /// is NOT the Mac's current default output, so nothing actually reaches it.
    /// TOP precedence in the note slot (see PRECEDENCE above) — re-applied on
    /// every `rebuild()` so a rebuild mid-condition keeps it pinned.
    private var routingBlockedNeedsDefault = false

    /// The routing-blocked warning's exact copy (T-UI, locked design): the
    /// "Audiouter" token comes from `AggregateOutputDevice.productName` rather
    /// than a hardcoded string.
    static var routingBlockedNeedsDefaultText: String {
        "\(AggregateOutputDevice.productName) isn't your Mac's output device — audio won't play until you switch back."
    }

    /// Show or clear the routing-blocked-needs-default warning (T-UI). Called
    /// by the host (`AppDelegate`) directly — a whole-app condition with no
    /// home on `Device`, same shape as ``setSystemAirPlayNoteActive(_:)``.
    /// Idempotent: a repeat of the current state is a no-op.
    public func setRoutingBlockedNeedsDefault(_ active: Bool) {
        guard active != routingBlockedNeedsDefault else { return }
        routingBlockedNeedsDefault = active
        applyNoteSlot()
    }

    /// Show or clear the "double-path audio" note
    /// (`BackendEvent.systemDefaultIsAirPlayActive`). Called by the host
    /// (`AppDelegate`) directly — a whole-app condition with no home on `Device`,
    /// same shape as ``setLocalFallbackActive(_:)``. Idempotent: a repeat of the
    /// current state is a no-op.
    public func setSystemAirPlayNoteActive(_ active: Bool) {
        guard active != systemAirPlayNoteActive else { return }
        systemAirPlayNoteActive = active
        applyNoteSlot()
    }

    /// Show, update, or clear the takeover status strip (T6,
    /// `BackendEvent.takeoverStatus`). Called by the host (`AppDelegate`)
    /// directly, same shape as ``setSystemAirPlayNoteActive(_:)``. Idempotent: a
    /// repeat of the current state (including repeated `nil`) is a no-op.
    public func setTakeoverStatus(_ status: TakeoverStatus?) {
        guard status != takeoverStatus else { return }
        takeoverStatus = status
        applyNoteSlot()
    }

    /// Resolve which note currently owns the single note slot (the PRECEDENCE
    /// rule above) and push it to the panel. Not a full rebuild — the cards are
    /// unchanged, only the pinned note appears/disappears/changes.
    private func applyNoteSlot() {
        guard isEffectivelyShown else { return }
        let note = resolvedSystemAirPlayNote
        panel.setSystemAirPlayNote(note.text, action: note.action, severity: note.severity)
        panel.panelContentDidChangeHeight(animated: true)
        // When not shown, the next `rebuildForOpen()` re-applies this from the
        // tail of `rebuild()`.
    }

    /// What the note slot should currently show, highest precedence first:
    /// routing-blocked (T-UI, WARNING — audio is dead right now) outranks a
    /// takeover status (T6), which outranks the double-path guard (W3-T3);
    /// none active means no note. `action` is non-nil for routing-blocked (the
    /// "Use <productName>" button) and for the takeover strip's
    /// `.needsApproval` (state 1) — the only states with an actual remedy a
    /// button can offer.
    private var resolvedSystemAirPlayNote: (text: String?, action: SystemAirPlayNoteBannerView.Action?, severity: SystemAirPlayNoteBannerView.Severity) {
        if routingBlockedNeedsDefault {
            return (Self.routingBlockedNeedsDefaultText, routingBlockedNeedsDefaultAction, .warning)
        }
        if let takeoverStatus {
            return (Self.takeoverStatusText(for: takeoverStatus), takeoverStatusAction(for: takeoverStatus), .info)
        }
        if systemAirPlayNoteActive {
            return (Self.systemAirPlayNoteText, nil, .info)
        }
        return (nil, nil, .info)
    }

    /// The routing-blocked warning's action button (T-UI, Alec's Q6 — the
    /// user's own click is their intent, so re-selecting the aggregate here
    /// does NOT violate "never auto-reselect").
    private var routingBlockedNeedsDefaultAction: SystemAirPlayNoteBannerView.Action {
        SystemAirPlayNoteBannerView.Action(
            title: "Use \(AggregateOutputDevice.productName)",
            accessibilityLabel: "Use \(AggregateOutputDevice.productName) as the Mac's output device",
            handler: { [weak self] in self?.onReselectAudiouter?() })
    }

    /// The takeover strip's copy for each state (T6, PLAN-AIRPLAY-COEXISTENCE.md) —
    /// plain language throughout, never "PTP"/"bind"/"ports 319/320". State 3's
    /// copy is the plan's own exact wording; the others follow its voice.
    static func takeoverStatusText(for status: TakeoverStatus) -> String {
        switch status {
        case .needsApproval:
            return "Speaker Sync needs permission to run. Open Login Items to approve it."
        case .helperMissing:
            return "Speaker Sync is missing from this copy of Audiouter. Reinstall Audiouter to fix it."
        case .takingOver:
            return "Taking audio back from macOS…"
        case .timedOut:
            return "Another app is using AirPlay's timing right now, so this connection couldn't complete. Try again in a moment."
        }
    }

    /// The strip's action button. Only state 1 (`.needsApproval`) has one: state
    /// 2's own doc says plainly there's nothing an approval UX can do about a
    /// missing bundle component; state 3 is transient; state 4 needs a DIFFERENT
    /// app to yield, which no button here can cause.
    private func takeoverStatusAction(for status: TakeoverStatus) -> SystemAirPlayNoteBannerView.Action? {
        guard case .needsApproval = status else { return nil }
        return SystemAirPlayNoteBannerView.Action(
            title: "Open Login Items…",
            accessibilityLabel: "Open Login Items to approve Speaker Sync",
            handler: { [weak self] in self?.onOpenPTPHelperLoginItems?() })
    }

    /// Test-only: whichever note (double-path guard or takeover strip) currently
    /// occupies the slot, or `nil` if neither is active.
    var test_systemAirPlayNoteText: String? { panel.test_systemAirPlayNoteText }
    /// Test-only: whether the currently-shown note has an action button.
    var test_systemAirPlayNoteHasActionButton: Bool { panel.test_systemAirPlayNoteHasActionButton }
    /// Test-only: simulate a click on the note's action button, if any.
    func test_tapSystemAirPlayNoteAction() { panel.test_tapSystemAirPlayNoteAction() }

    /// The master volume (0…1) the status symbol should reflect: the Main Out
    /// master of the current target (SPEC §9b — status icon reflects Main Out).
    public var statusMasterVolume: Double {
        guard let controller = groupController else { return 0 }
        return Double(controller.mainOutMasterVolume) / 100.0
    }

    // MARK: Show / hide

    /// Headless test seam: an `NSPopover` can never actually show under `swift
    /// test`, so tests flip this to exercise the shown-path repaint semantics
    /// (the view tree IS the test suite's rendering surface). Production code
    /// never sets it. `toggle(relativeTo:)` and `setPopoverAnimates` still key
    /// off the real `popover.isShown` — this only affects repaint routing.
    public var test_isShownOverride = false
    private var isEffectivelyShown: Bool { popover.isShown || test_isShownOverride }

    /// Total `rebuild()` calls, for tests asserting a closed popover does NOT
    /// rebuild per backend event (audit B8).
    public private(set) var test_rebuildCount = 0

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
            // Never actually present under `swift test`/a headless tool
            // (`HeadlessRuntime`) — those hold a real WindowServer connection,
            // so an un-gated `popover.show` would flash a real window on the
            // developer's actual screen. No test/tool currently calls
            // `toggle()` (real presentation only happens from the live app's
            // status-item click), but gate it for defense-in-depth.
            guard !HeadlessRuntime.isActive else { return }
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
        test_rebuildCount += 1
        deviceRowsByID.removeAll()
        // The mounted panel views die with their rows; the open-panel INTENT
        // (`openDiagnosisIDs`) survives and is re-applied below (brief §7.3 —
        // "rebuild() restores open panels").
        diagnosisPanelsByID.removeAll()
        blockedNoteByID.removeAll()
        appRowsByBundleID.removeAll()
        panel.clearRows()

        // Prune offline tracking for apps that no longer have a route (T4).
        // A de-routed app can never come back as "online" via `handleAppLaunched`
        // (which only acts on routed bundle IDs), so any stale entry here is
        // dead weight and should not bleed onto a future route for the same id.
        let currentRouteIDs = Set(appRouting.appRoutes.map(\.bundleID))
        offlineBundleIDs = offlineBundleIDs.intersection(currentRouteIDs)

        let allDevices = orderedDevices()

        // 1. Main Audio card — the single Main Out row. Combined header row
        // (change 1): "Main Audio" title (Warm Signal §5.1 silkscreen vocabulary)
        // on the left, "VOLUME" over the slider and "OUTPUT" over the destination
        // dropdown on the right ("Output" framing, decision m).
        //
        // Collapsible (T-4, PLAN decision 5): the chevron/title toggle the body.
        // Collapse-DEFAULT policy (T-5, PLAN §B): defaults are recomputed on
        // every OPEN (Main Audio starts expanded); a rebuild WITHIN one open
        // (backend events, etc.) instead preserves whatever the transient state
        // currently is — `collapsedState(for:default:)` picks the right one.
        panel.beginCard(header: Self.mainAudioCardTitle, volumeTitle: "Volume", trailingTitle: "Output",
                        collapsible: true,
                        collapsed: collapsedState(for: Self.mainAudioCardTitle, default: false),
                        onToggle: { [weak self] in self?.toggleCard(Self.mainAudioCardTitle) })
        panel.addRow(mainOutRow)
        refreshMainOutRow()

        // 2. Selected Devices card — split into Current Device + AirPlay. ALWAYS
        // present now (V2): when no devices have been discovered yet the card
        // still builds, showing a single non-interactive "Looking for devices…"
        // placeholder so it never silently vanishes.
        let locals = allDevices.filter(\.isLocalDevice)
        let airplay = allDevices.filter { !$0.isLocalDevice && !$0.isBluetooth }
        let bluetooth = orderedBluetoothDevices(in: allDevices)
        devicesPlaceholderShown = false
        renderedSubsectionTitles = []
        renderedBluetoothOrder = bluetooth.map(\.id)
        // Combined header row: "Output Devices" title on the left, "VOLUME" over
        // the slider. The membership "Selected" column MOVED to the left spine
        // (v4 §Call-1), so this card no longer heads a membership column — but
        // its device rows' trailing dropdown column, once left empty, now
        // fills the FEED composite (v4.1 item 3), so the header names it
        // "Feed" (`DeviceRowView.updateFeedText`/`feedStack`). The trailing
        // "+" accessory is a MENU now (BT-UI): "Save Selected Devices as
        // group" (enabled iff `canSaveCurrentSetup` — the gating moved off the
        // button onto the item) and "Pair a Bluetooth speaker…", so the button
        // itself stays always-enabled.
        panel.beginCard(header: Self.outputDevicesCardTitle, volumeTitle: "Volume", trailingTitle: "Feed",
                        trailingAccessory: PopoverPanelViewController.HeaderAccessory(
                            symbol: "plus",
                            label: "Save the Selected Devices as a group, or pair a Bluetooth speaker",
                            action: { [weak self] in self?.presentOutputDevicesPlusMenu() },
                            isEnabled: true),
                        collapsible: true,
                        collapsed: collapsedState(for: Self.outputDevicesCardTitle, default: false),
                        onToggle: { [weak self] in self?.toggleCard(Self.outputDevicesCardTitle) })
        // Dormancy note (spec §4.7 FINAL, S5): only a GENUINELY-DIVERGING group
        // target annotates the card ("Inactive — Audio Out is using 'X'", a
        // header-region note that survives collapse). The derived-identity case
        // (checked set == active group's members) posts NO note — the Audio Out
        // dropdown title already carries the group identity, and the rows render
        // at full emphasis. Row de-emphasis is scoped inside `applySelectionState`.
        let devicesCardNote = devicesCardNoteText()
        renderedDevicesCardNote = devicesCardNote
        if let note = devicesCardNote {
            panel.addCardNote(note)
        }
        if locals.isEmpty && airplay.isEmpty && bluetooth.isEmpty {
            panel.addRow(makePlaceholderRow(text: "Looking for devices…"))
            devicesPlaceholderShown = true
        } else {
            if !locals.isEmpty {
                // "This Mac", not "Current Device": once the app inserts its own
                // aggregate ("Audiouter") as the default output, the literal
                // "current device" is the aggregate — a plumbing artifact the user
                // shouldn't see. This section names the Mac's own output honestly;
                // the row under it still shows the real underlying device name
                // (e.g. "MacBook Pro Speakers", via `currentOutputDeviceName`, which
                // resolves through the aggregate to the wrapped speakers).
                addSubsection("This Mac")
                for device in locals { panel.addRow(makeDeviceRow(device, indented: false)) }
            }
            if !airplay.isEmpty {
                addSubsection("AirPlay Devices")
                for device in airplay { panel.addRow(makeDeviceRow(device, indented: false)) }
            }
            // Bluetooth subsection (BT-UI): HIDDEN entirely when no BT devices
            // exist — never an empty grouping label. Rows are ordinary rail
            // rows; recency ordering is `orderedBluetoothDevices`. The SYNC
            // column title lives in THIS subsection's header line only, between
            // VOLUME and FEED (BT-OFFSET-UI).
            if !bluetooth.isEmpty {
                addSubsection(Self.bluetoothSubsectionTitle,
                              columnTitle: "Sync",
                              columnCenterFromTrailing: PopoverColumnGrid.syncCenterFromTrailing)
                for device in bluetooth { panel.addRow(makeDeviceRow(device, indented: false)) }
            }
        }
        // Set each row's rail extent + feed the continuous rail overlay: the
        // spine runs Main Audio → the LOWEST SELECTED node; rows below it render
        // BARE (no rail) — spec v4 §Call-1. Runs even with no devices (the overlay
        // then draws just the Main Audio origin hook).
        updateBusRailExtents()

        // 3. Applications card — rendered LAST (below Selected Devices), one
        // `AppRowView` per routed app in stable `appRoutes` order, then the ±
        // footer (T3, LOCKED DECISION — replaces the old "+ Add application…"
        // row; the card is always present even with no routes since the
        // footer's "+" segment is always available).
        //
        // Collapsible (T-4/T-5): collapse DEFAULT is "expanded iff ≥1 app route
        // exists" (`applicationsDefaultExpanded`, C5), recomputed on every OPEN
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
        let renderedRoutes = appRouting.appRoutes.filter { !isAppExcluded($0.bundleID) }
        for route in renderedRoutes {
            panel.addRow(makeAppRow(route, devices: allDevices))
        }
        // V11 empty state: when no routes actually render (none, or all excluded),
        // show a single non-interactive placeholder BEFORE the ± footer.
        applicationsPlaceholderShown = false
        if renderedRoutes.isEmpty {
            panel.addRow(makePlaceholderRow(text: "No apps routed — use + below to route an app."))
            applicationsPlaceholderShown = true
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

        // Re-pin the silence-fallback banner (R11) above the cards: `clearRows()`
        // above dropped it with everything else, so a rebuild that happens WHILE the
        // fallback is active (e.g. a device set change) must restore it.
        panel.setBanner(localFallbackActive ? Self.localFallbackBannerText : nil)
        // Re-pin the note slot (T-UI routing-blocked / T6 takeover strip / W3-T3
        // double-path guard) the same way — resolved through the same PRECEDENCE
        // `applyNoteSlot()` uses, so a rebuild mid-condition restores the right one.
        let note = resolvedSystemAirPlayNote
        panel.setSystemAirPlayNote(note.text, action: note.action, severity: note.severity)
    }

    private func orderedDevices() -> [Device] {
        devicesByID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The Bluetooth subsection's grouping label (BT-UI) — a constant because,
    /// like the card titles, tests key off the rendered string.
    static let bluetoothSubsectionTitle = "Bluetooth Devices"

    /// Subsection titles the LAST `rebuild()` actually rendered, in order —
    /// the hide-when-empty assertion surface (`test_subsectionTitles`).
    private var renderedSubsectionTitles: [String] = []

    /// The Bluetooth subsection's device ids as the LAST `rebuild()` rendered
    /// them, top to bottom — the recency-sort assertion surface
    /// (`test_bluetoothRowOrder`). Empty when the subsection is hidden.
    private var renderedBluetoothOrder: [String] = []

    /// `panel.addSubsectionHeader` + the rendered-titles record, so the test
    /// surface can never drift from what was actually mounted.
    private func addSubsection(_ title: String,
                               columnTitle: String? = nil,
                               columnCenterFromTrailing: CGFloat = 0) {
        renderedSubsectionTitles.append(title)
        panel.addSubsectionHeader(title, columnTitle: columnTitle,
                                  columnCenterFromTrailing: columnCenterFromTrailing)
    }

    /// The Bluetooth subsection's rows, recency-ordered (BT-UI ghost
    /// pairings): most-recently-used pairing first, so a years-dead ghost
    /// sinks to the BOTTOM — sort only, nothing hidden in v1. A device with
    /// no known `lastUsed` sorts below every dated one; name (then id) breaks
    /// ties deterministically.
    private func orderedBluetoothDevices(in devices: [Device]) -> [Device] {
        let lastUsed = btLastUsedProvider?() ?? [:]
        return devices.filter(\.isBluetooth).sorted { a, b in
            let ua = lastUsed[a.id] ?? .distantPast
            let ub = lastUsed[b.id] ?? .distantPast
            if ua != ub { return ua > ub }
            return (a.name, a.id) < (b.name, b.id)
        }
    }

    // MARK: Collapse-default policy (T-5, PLAN §B)

    /// The three card titles — Warm Signal §5.1's silkscreen vocabulary
    /// ("SYSTEM AUDIO" / "OUTPUT DEVICES" / "APP EXCEPTIONS"; the panel uppercases
    /// the displayed header, the title-case copy lives here). Named constants
    /// because the title string IS the card's lookup/collapse key. The System
    /// Audio card was "Main Audio" pre-v4 (§Call-1 renamed the SECTION header to
    /// "System Audio"; the ROW inside it is now titled "Main Audio").
    static let mainAudioCardTitle = "System Audio"
    static let outputDevicesCardTitle = "Output Devices"
    /// The Applications card's title, so its default is keyed identically to
    /// every other card even though the card itself isn't built yet (T-8).
    static let applicationsCardTitle = "App Exceptions"

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

    /// The Applications card's collapse default (C5): expanded iff ANY app route
    /// exists at all — a routed app is worth surfacing on open even while it's
    /// still on the neutral "No Redirect" default, since the user added it on
    /// purpose. Exposed so the card-wiring only needs `collapsedState(for:
    /// Self.applicationsCardTitle, default: !applicationsDefaultExpanded)`.
    private var applicationsDefaultExpanded: Bool {
        !appRouting.appRoutes.isEmpty
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
        // "Selected Devices" is CLEAN — no live "(n)" count (Warm Signal §5.1,
        // decision m: the dropdown names the current target, the device rows'
        // checkboxes already show the composition). The trailing-control column
        // (`PopoverColumnGrid.trailingControlWidth`) is sized so the full title
        // fits the collapsed button untruncated — no `buttonTitle` short form.
        var options: [MainOutRowView.Option] = [
            .init(title: "Destination", isHeader: true),
            .init(title: "Selected Devices", target: .selectedDevices),
        ]
        // Only groups that actually have a device are offered as routing targets —
        // an empty group can't be activated (and shouldn't exist under the
        // membership invariant, but a group left empty by an older build is
        // filtered here defensively rather than shown as a dead entry).
        let routableGroups = controller.groups.filter { !$0.memberIDs.isEmpty }
        if !routableGroups.isEmpty {
            options.append(.init(title: "Output Groups", isHeader: true))
            for group in routableGroups {
                // A saved GROUP names ITSELF on the collapsed button ("→ Kitchen"),
                // never its member devices — shorter, never truncates, and matches
                // exactly what the user picked from this same menu.
                options.append(.init(title: group.name, target: .group(id: group.id),
                                      buttonTitle: "→ \(group.name)"))
            }
        }
        mainOutRow.apply(options: options,
                         current: controller.mainOut,
                         master: controller.mainOutMasterVolume,
                         isMuted: controller.isMainOutMuted,
                         connectionState: mainOutConnectionState(controller),
                         restingArmed: mainOutIsLocalOnlyArmed(controller),
                         // S5 (spec §4.7 FINAL): the bus origin stub dims only
                         // under a GENUINELY-DIVERGING group target — in the
                         // derived-identity case the whole bus (origin included)
                         // keeps full emphasis, the dropdown title carrying the
                         // group identity.
                         busOriginDimmed: devicesCardDivergence() != nil)
    }

    // MARK: Energize (Warm Signal v4.1 item 9)

    /// Start the energize "press-play" sequence for a Main-Audio source switch
    /// (Selected Devices ↔ a group). Raises the PENDING beat on the target's
    /// members that haven't started connecting yet, so the switch reads as an
    /// instant drop to ember pending; the natural `connectionState` progression
    /// (`.off → .connecting → .connected`) then plays the top-to-bottom fill
    /// over the live model, and `reconcileEnergize()` closes it out. Purely
    /// presentational — it never touches membership/connection/routing.
    ///
    /// **Scope.** The beat is raised on the SELECTED-DEVICES set (the members
    /// the left rail already runs through), so the clean cases — switching TO
    /// Selected Devices, or to a group whose members equal the checked set
    /// (derived identity, §3.4) — light their spine. A switch to a group that
    /// genuinely DIVERGES from the checked set leaves that rail dormant (§4.7)
    /// rather than energizing devices that aren't the ones now playing.
    ///
    /// **Reduce Motion** removes the sweep entirely: the pending set stays
    /// empty, so every row renders its resolved model state immediately (the
    /// rows' own `energizePending` gate makes this belt-and-suspenders).
    private func beginEnergize(to target: MainOutTarget) {
        guard let controller = groupController else { return }
        energizeTargetName = energizeTargetDisplayName(target, controller: controller)
        // Announce the transition FIRST — the spoken equivalent of the visual
        // drop-to-pending is an accessibility affordance, independent of the
        // motion setting: a VoiceOver user with Reduce Motion on still hears the
        // switch even though the sweep isn't drawn.
        announceEnergize("Switching Main Audio to \(energizeTargetName ?? "the new source")")
        // Reduce Motion removes the sweep: raise no beat, so every member snaps
        // straight to its resolved node (the rows' own gate is belt-and-braces).
        guard !reduceMotionActive else {
            energizePendingIDs = []
            energizeActive = false
            return
        }
        // Only members not yet online get the pending beat — a member already
        // `.connecting`/`.connected` shows its real node, no "press-play" drop.
        energizePendingIDs = Set(controller.selectedDeviceIDs.filter { isPreConnect($0) })
        energizeActive = !energizePendingIDs.isEmpty
    }

    /// Prune the pending beat off members that have left `.off`, and — once the
    /// switched target stops moving (no member still `.off`/`.connecting`/
    /// `.reconnecting`) — fire the one-shot settle announcement. Called at the
    /// top of `refreshDeviceRows()` (every in-place repaint / model update), so
    /// the beat tracks the live connection progression with no timers.
    private func reconcileEnergize() {
        guard energizeActive else { return }
        energizePendingIDs = energizePendingIDs.filter { isPreConnect($0) }
        guard energizeTargetSettled() else { return }
        energizeActive = false
        energizePendingIDs = []
        let (connected, failed) = energizeTargetTally()
        var summary = "\(energizeTargetName ?? "Main Audio") ready"
        if connected > 0 { summary += " — \(connected) connected" }
        if failed > 0 { summary += ", \(failed) didn’t connect" }
        announceEnergize(summary)
    }

    /// Whether a device is still waiting to come online (`.off`, or absent from
    /// the current snapshot) — the pending-beat / settle predicate.
    private func isPreConnect(_ id: String) -> Bool {
        switch devicesByID[id]?.connectionState {
        case .some(.off), .none: return true
        default:                 return false
        }
    }

    /// The switched target has stopped moving when none of its members is `.off`
    /// or mid-handshake — every member has landed on `.connected` or `.failed`.
    private func energizeTargetSettled() -> Bool {
        guard let controller = groupController else { return true }
        for id in controller.selectedDeviceIDs {
            switch devicesByID[id]?.connectionState {
            case .some(.off), .some(.connecting), .some(.reconnecting), .none:
                return false
            default:
                continue
            }
        }
        return true
    }

    /// Count the switched target's members that landed connected vs failed, for
    /// the settle announcement.
    private func energizeTargetTally() -> (connected: Int, failed: Int) {
        guard let controller = groupController else { return (0, 0) }
        var connected = 0, failed = 0
        for id in controller.selectedDeviceIDs {
            switch devicesByID[id]?.connectionState {
            case .some(.connected): connected += 1
            case .some(.failed):    failed += 1
            default:                break
            }
        }
        return (connected, failed)
    }

    /// The spoken name for a source-switch target.
    private func energizeTargetDisplayName(_ target: MainOutTarget,
                                           controller: GroupController) -> String {
        switch target {
        case .selectedDevices: return "Selected Devices"
        case .group(let id):   return controller.groups.first { $0.id == id }?.name ?? "the group"
        }
    }

    /// Post a VoiceOver announcement for an energize milestone (the transition's
    /// accessibility equivalent — the visual sweep has no other spoken form), and
    /// record it for the deterministic test seam. High priority so it isn't
    /// dropped mid-scan. No-op-safe headlessly (the post simply reaches no AT).
    private func announceEnergize(_ message: String) {
        lastEnergizeAnnouncement = message
        NSAccessibility.post(
            element: panel.view,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// Live Reduce Motion value, overridable for headless determinism.
    private var reduceMotionActive: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The AGGREGATE connection state driving the Main Out halo ring (spec §3.2
    /// Main Out note / §6): resolved over the ACTIVE target's members (the
    /// Selected Devices set, or the routed group's members), read from the live
    /// device snapshots. Pending/connected only — a failed member shows its own
    /// red ring on its device row, never the Main Out ring:
    ///   - any member `.connected` → `.connected` (solid ring),
    ///   - else any member `.connecting` / `.reconnecting` → `.connecting`
    ///     (dashed pending ring, so a multi-second destination-switch handshake
    ///     never reads as dead/broken),
    ///   - else `.off` (no ring).
    private func mainOutConnectionState(_ controller: GroupController) -> ConnectionState {
        let memberIDs: [String]
        switch controller.mainOut {
        case .selectedDevices: memberIDs = Array(controller.selectedDeviceIDs)
        case .group(let id):   memberIDs = controller.groups.first { $0.id == id }?.memberIDs ?? []
        }
        var anyConnecting = false
        for id in memberIDs {
            switch devicesByID[id]?.connectionState {
            case .connected:                 return .connected
            case .connecting, .reconnecting: anyConnecting = true
            default:                         break
            }
        }
        return anyConnecting ? .connecting : .off
    }

    /// The Main Audio ring's RESTING form predicate (ring-resting-state task,
    /// separate from `mainOutConnectionState` above — which stays untouched):
    /// true iff the active target's members are ALL the local device (the set
    /// non-empty) and the master is unmuted. This is exactly the case where
    /// audio is genuinely playing (locally, through the Mac) but there's no
    /// remote AirPlay handshake for `mainOutConnectionState` to report, so it
    /// correctly falls through to `.off` — leaving the rail's curve into the
    /// ring with nothing to land on unless the ring renders its resting form.
    private func mainOutIsLocalOnlyArmed(_ controller: GroupController) -> Bool {
        let memberIDs: [String]
        switch controller.mainOut {
        case .selectedDevices: memberIDs = Array(controller.selectedDeviceIDs)
        case .group(let id):   memberIDs = controller.groups.first { $0.id == id }?.memberIDs ?? []
        }
        guard !memberIDs.isEmpty,
              memberIDs.allSatisfy({ devicesByID[$0]?.isLocalDevice == true })
        else { return false }
        return !controller.isMainOutMuted
    }

    /// The collapsed destination-button label for the "Selected Devices" target:
    /// names the real destination instead of a bare "Selected (n)" count, which
    /// told the user how many devices were checked but not WHERE audio actually
    /// goes.
    ///
    ///  - ≥1 AirPlay speaker selected: the speaker name(s) themselves, e.g.
    ///    "→ Kitchen + Move 2" (ordered the same way the Devices card lists them;
    ///    joined with " + " — the destination pop-up already tail-truncates long
    ///    titles via `.byTruncatingTail`, so no separate manual truncation is
    ///    needed here for a long list).
    ///  - Only the Mac selected (or the Mac plus nothing else) — pure passthrough:
    ///    "→ This Mac".
    ///  - Nothing selected at all (the local device's own row was toggled off
    ///    directly, `GroupController.setDeviceSelected`'s "deliberate act, not a
    ///    disconnect" case): there is no destination to name, so this preserves
    ///    the pre-existing bare "Selected (n)" (n == 0) copy rather than
    ///    inventing new copy for a state the file already renders.

    // MARK: Device rows

    private func makeDeviceRow(_ device: Device, indented: Bool, showsToggle: Bool = true) -> DeviceRowView {
        // No accent-wash pill in the popover (2026-07-14 — ahh: no longer
        // needed to highlight multiple selected devices at once here; the
        // card already separates rows, and the icon tint + switch state still
        // say "on"). The mixer window keeps the wash (its default `true`).
        // `showsBus: true` — the Selected-Devices rows carry the membership BUS
        // (spec §4) in place of the checkbox's switch drawing; the real checkbox
        // lives on underneath (§4.8). The mixer window / group members keep the
        // default `false` (plain switch), so their rendering is unchanged.
        let view = DeviceRowView(device: device, indented: indented, showsToggle: showsToggle,
                                 paintsSelectionBackground: false, showsMeter: true, showsBus: true,
                                 showsSyncControls: device.isBluetooth)
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

    /// The Devices card's genuinely-DIVERGING dormant state (spec §4.7 FINAL
    /// semantics, S5 — replaces the transitional "any group target dims
    /// everything" treatment): non-`nil` only when Audio Out targets a saved
    /// group AND the checked (Selected Devices) set does NOT equal that group's
    /// member set.
    private struct DevicesCardDivergence {
        /// The active group's display name, for the card note.
        let groupName: String
        /// The ACTIVE target's member ids — rows inside it keep full emphasis;
        /// only rows OUTSIDE it de-emphasize (via node tint, never alpha).
        let targetMemberIDs: Set<String>
    }

    /// Resolve the current divergence, or `nil` in the two full-emphasis cases:
    ///
    /// - Main Out targets Selected Devices (no dormancy at all), or
    /// - the **derived-identity** case (spec §3.4/§4.7): Main Out targets a
    ///   saved group and the checked set EQUALS its member set — the rows ARE
    ///   what's playing, the dropdown title carries the group identity, so there
    ///   is no note and nothing dims.
    ///
    /// A stale group id (no saved group resolves — shouldn't happen, defensive)
    /// counts as fully diverged with an empty target: every row reads as outside
    /// the unknown target, under a generic note.
    private func devicesCardDivergence() -> DevicesCardDivergence? {
        guard let controller = groupController,
              case .group(let id) = controller.mainOut else { return nil }
        guard let group = controller.groups.first(where: { $0.id == id }) else {
            return DevicesCardDivergence(groupName: "a group", targetMemberIDs: [])
        }
        let target = Set(group.memberIDs)
        guard controller.selectedDeviceIDs != target else { return nil }
        return DevicesCardDivergence(groupName: group.name, targetMemberIDs: target)
    }

    /// The "Inactive" card note the Devices card should currently show, or `nil`
    /// (spec §4.7: the note appears only under genuine divergence — the derived
    /// case posts none).
    private func devicesCardNoteText() -> String? {
        devicesCardDivergence().map { "Inactive — Main Audio is using '\($0.groupName)'" }
    }

    /// The note text the LAST `rebuild()` actually rendered onto the Devices card
    /// (`nil` = none). Because the note now depends on the checked set — not just
    /// the Main Out target — a membership toggle or a failure auto-deselect can
    /// flip it, and in-place repaint paths compare against this to decide whether
    /// a structural `rebuild()` is required (see
    /// `refreshDeviceRowsReconcilingCardNote()`).
    private var renderedDevicesCardNote: String?

    /// In-place device-section repaint that escalates to a full `rebuild()` when
    /// the Devices card's dormancy note must appear/disappear/rename (a card-note
    /// change is structural — only `rebuild()` mounts/unmounts it). Everything
    /// else stays the cheap `refreshDeviceRows()` + `refreshMainOutRow()` path.
    private func refreshDeviceRowsReconcilingCardNote() {
        if devicesCardNoteText() != renderedDevicesCardNote {
            rebuild()
            panel.panelContentDidChangeHeight(animated: true)
        } else {
            refreshDeviceRows()
            refreshMainOutRow()
        }
    }

    /// The ACTIVE Main Out target's saved-group name, when it currently
    /// targets a group — `nil` when it targets Selected Devices. Feeds
    /// `DeviceRowView.apply`'s `mainOutTargetsGroupName` (Warm Signal v4.1
    /// item 3 FEED column wording: "System" for a manual member, the group's
    /// name for a group-target member).
    private var activeMainOutGroupName: String? {
        guard let controller = groupController, case .group(let id) = controller.mainOut else { return nil }
        return controller.groups.first { $0.id == id }?.name
    }

    /// Push the current membership + local-block state into a device row.
    private func applySelectionState(to row: DeviceRowView, device: Device) {
        // Dormant de-emphasis (spec §4.7 FINAL, S5): dim ONLY rows that fall
        // OUTSIDE a genuinely-diverging group target — via node TINT, never
        // alpha (DeviceRowView.apply handles that split; the checkbox stays at
        // full alpha and fully clickable). The derived-identity case and rows
        // INSIDE the active target render at full emphasis. A FAILED member is
        // additionally exempted inside `DeviceRowView.updateBus` (failure
        // outranks configuration, R2).
        let divergence = devicesCardDivergence()
        let dimmed = divergence.map { !$0.targetMemberIDs.contains(device.id) } ?? false
        guard let controller = groupController else {
            // No controller ⇒ nothing routable ⇒ not controllable.
            row.apply(device, selected: false, controllable: false,
                      selectionDimmed: dimmed,
                      routedAppNames: appRouting.routedAppNames(for: device.id),
                      liveAppNames: liveRoutedAppNames[device.id] ?? [],
                      appTintColors: appTintColorsByName(),
                      mainOutTargetsGroupName: activeMainOutGroupName,
                      energizePending: energizePendingIDs.contains(device.id),
                      iconSymbolName: deviceIconController?.symbolName(for: device),
                      syncTrimMs: btSyncTrim(for: device),
                      // See the note on the main `apply` below: non-zero == tuned
                      // until T7 supplies a real signal.
                      syncTrimIsSet: btSyncTrim(for: device) != 0)
            return
        }
        let selected = controller.isSpeakerSelected(device.id)
        // Row mute is VOLUME-BASED in `GroupController` (Q4 — `explicitMute`
        // in memberState; the backend `Device.isMuted` flag is never driven by
        // the popover's mute path), so overlay the controller's mute truth
        // onto the snapshot before the row renders (S3): without this the
        // engaged pill / dark armed dot / MUTED token would all silently
        // revert on the first model repaint after a mute click.
        var device = device
        device.isMuted = device.isMuted || controller.isMuted(device.id)
        // Same overlay pattern, for the passthrough exception: with no real output
        // in the current target, the Mac's row IS Main — `setMemberVolume` redirects
        // a local-row write to `setMainOutMasterVolume`, because in passthrough the
        // Mac's audible level is the system volume and the two are physically one
        // control. A row that WRITES Main must also READ it, or the slider would
        // show the Mac's own remembered fader while dragging it moved Main, and the
        // thumb would jump on the first repaint. The Mac's stored fader is
        // deliberately left untouched underneath — it is what the row goes back to
        // showing the moment an AirPlay device joins.
        if device.isLocalDevice, controller.localRowDrivesMain {
            device.volume = controller.mainOutMasterVolume
        }
        // T-UI-ALLOW: the Phase-1 local-mix block is gone — `canSelectLocalSpeaker`
        // is unconditionally `true` now (T-GROUPCTL / Q5, synced local sink), so
        // the Mac row is never blocked/greyed any more. This no longer computes
        // or passes `blocked`/`blockReason` to the row (both default to
        // false/nil in `DeviceRowView.apply`, which is exactly the always-un-blocked
        // behavior this now produces).
        // Route-armed inputs (spec §3.3, S2): membership is evaluated against
        // the ACTIVE Main Out target — the Selected set when Main Out targets
        // Selected Devices, the group's member set when it targets a saved
        // group (so a playing group member lights its dot even while its
        // Selected checkbox dims in the dormant card). Master mute is folded
        // in so it drains every device dot.
        let inActiveTarget: Bool
        switch controller.mainOut {
        case .selectedDevices:
            inActiveTarget = selected
        case .group(let id):
            inActiveTarget = controller.groups.first { $0.id == id }?
                .memberIDs.contains(device.id) ?? false
        }
        row.apply(device,
                  selected: selected,
                  controllable: controller.isSpeakerSelected(device.id) || isRedirectTarget(device.id),
                  selectionDimmed: dimmed,
                  routedAppNames: appRouting.routedAppNames(for: device.id),
                  liveAppNames: liveRoutedAppNames[device.id] ?? [],
                  appTintColors: appTintColorsByName(),
                  masterMuted: controller.isMainOutMuted,
                  inActiveTarget: inActiveTarget,
                  mainOutTargetsGroupName: activeMainOutGroupName,
                  energizePending: energizePendingIDs.contains(device.id),
                  iconSymbolName: deviceIconController?.symbolName(for: device),
                  syncTrimMs: btSyncTrim(for: device),
                  // T6's "tuned vs never tuned" (D10). Until T7 wires a real
                  // has-a-persisted-entry signal, a non-zero trim IS the
                  // evidence the device was tuned; an explicit 0.0 reads as
                  // untuned, which is the honest default for a value nobody
                  // has moved.
                  syncTrimIsSet: btSyncTrim(for: device) != 0)
    }

    /// A Bluetooth row's current SYNC trim: the session cache first (the
    /// user's freshest edit), else the persisted value via `btTrimProvider`,
    /// else 0. Non-BT devices short-circuit to 0 (their rows mount no SYNC
    /// cluster and ignore the value anyway).
    private func btSyncTrim(for device: Device) -> Double {
        guard device.isBluetooth else { return 0 }
        if let cached = btTrimsByID[device.id] { return cached }
        let persisted = btTrimProvider?(device.id) ?? 0
        btTrimsByID[device.id] = persisted
        return persisted
    }

    private func refreshDeviceRows() {
        // Item 9: prune the energize pending beat off any member that has left
        // `.off` (started connecting / resolved) BEFORE re-applying rows, so the
        // repaint reflects the current beat, and fire the one-shot settle
        // announcement when the switch finishes moving.
        reconcileEnergize()
        for (id, row) in deviceRowsByID {
            guard let device = devicesByID[id] else { continue }
            applySelectionState(to: row, device: device)
        }
        // The rail extent tracks the checked set, which a mid-open toggle can
        // change (v4 §Call-1), so recompute it on every in-place repaint too.
        updateBusRailExtents()
        // F1: keep the Devices "Save as group" accessory's enabled state fresh on
        // in-place repaints (a rebuild sets it from `canSaveCurrentSetup` too).
        refreshDevicesAccessory()
    }

    /// Set each mounted device row's membership-rail extent (Warm Signal v4
    /// §Call-1): the spine runs Main Audio (the origin hook) → the LOWEST
    /// SELECTED node. Rows within that span carry a through-rail (the terminus
    /// draws none below it); rows BELOW the lowest selected node render BARE —
    /// a hollow clickable node with no rail — so the rail's length reads as "how
    /// far down the mix reaches." Render order is locals then AirPlay, matching
    /// `rebuild()`.
    private func updateBusRailExtents() {
        let ordered = orderedDevices()
        // Must match `rebuild()`'s render order exactly: locals, AirPlay, then
        // the recency-ordered Bluetooth subsection (BT-UI).
        let renderOrder = ordered.filter(\.isLocalDevice)
            + ordered.filter { !$0.isLocalDevice && !$0.isBluetooth }
            + orderedBluetoothDevices(in: ordered)
        let lastSelected = renderOrder.lastIndex {
            groupController?.isSpeakerSelected($0.id) ?? false
        }
        var railRows: [DeviceRowView] = []
        for (i, device) in renderOrder.enumerated() {
            guard let row = deviceRowsByID[device.id] else { continue }
            if let last = lastSelected {
                // Within the span: rail above through the terminus; rail below
                // only until it. Below the terminus: bare (no rail either side).
                row.setBusRail(above: i <= last, below: i < last)
            } else {
                // Degenerate (no selected device — the floor should prevent this):
                // every node bare, no spine.
                row.setBusRail(above: false, below: false)
            }
            railRows.append(row)
        }
        // Feed the continuous rail overlay the Main Audio row + device rows in
        // display order so it can draw the spine as one line through the gutter.
        panel.setRailRows(mainOut: mainOutRow, deviceRows: railRows,
                          originCardTitle: Self.mainAudioCardTitle,
                          deviceCardTitle: Self.outputDevicesCardTitle)
    }

    /// The Devices card's "+" button stays ALWAYS enabled now that it fronts a
    /// menu (BT-UI): the "Pair a Bluetooth speaker…" item must be reachable
    /// even when nothing is selected, so `canSaveCurrentSetup` gates only the
    /// save ITEM (`makeOutputDevicesPlusMenu` re-reads it per presentation).
    private func refreshDevicesAccessory() {
        panel.setAccessoryEnabled(title: Self.outputDevicesCardTitle, enabled: true)
    }

    // MARK: OUTPUT DEVICES "+" menu (BT-UI)

    /// Build the "+" affordance's menu FRESH per presentation — two items
    /// dispatching through real `NSMenuItem` target/action (tests drive them
    /// via `NSMenu.performActionForItem(at:)`, never a bypass seam):
    /// "Save Selected Devices as group" (enabled iff `canSaveCurrentSetup`)
    /// and "Pair a Bluetooth speaker…" (device-tier decision 3 — never-paired
    /// speakers get NO rows; pairing is a one-tap Settings trip).
    func makeOutputDevicesPlusMenu() -> NSMenu {
        let menu = NSMenu(title: "Add")
        menu.autoenablesItems = false
        let save = NSMenuItem(title: "Save Selected Devices as group",
                              action: #selector(plusMenuSaveGroup(_:)), keyEquivalent: "")
        save.target = self
        save.isEnabled = canSaveCurrentSetup
        menu.addItem(save)
        let pair = NSMenuItem(title: "Pair a Bluetooth speaker…",
                              action: #selector(plusMenuPairBluetooth(_:)), keyEquivalent: "")
        pair.target = self
        menu.addItem(pair)
        return menu
    }

    @objc private func plusMenuSaveGroup(_ sender: Any?) { saveCurrentSetup() }
    @objc private func plusMenuPairBluetooth(_ sender: Any?) { onPairBluetoothSpeaker?() }

    /// The "+" button's click: pop the menu just under the button. The actual
    /// on-screen pop is gated on `HeadlessRuntime.isActive` (house rule — a
    /// blocking `popUp` under `swift test` would also hang the runner);
    /// headless callers assert via `test_outputDevicesPlusMenu()` instead.
    private func presentOutputDevicesPlusMenu() {
        guard !HeadlessRuntime.isActive,
              let button = panel.accessoryButton(title: Self.outputDevicesCardTitle)
        else { return }
        makeOutputDevicesPlusMenu().popUp(
            positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    /// A non-interactive placeholder body row (V2 Devices empty state / V11
    /// Applications empty state): `text` in a tertiary-label, row-height view
    /// whose label leading edge aligns with the name column (past the icon).
    private func makePlaceholderRow(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Tokens.Font.menuItem
        label.textColor = Tokens.Color.tertiaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        let nameColumnLeading = PopoverColumnGrid.leadingInset
            + PopoverColumnGrid.iconWidth + PopoverColumnGrid.iconToName
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: DeviceRowView.rowHeight),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: nameColumnLeading),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor,
                                            constant: -PopoverColumnGrid.leadingInset),
            label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        return wrapper
    }

    // MARK: Blocked local-mix refusal note (spec §4.6)

    /// Toggle the in-place refusal note under the blocked device row `id`: mount
    /// it directly beneath the row when absent, remove it when a second body-click
    /// asks again. No-op if the row isn't currently mounted.
    /// The re-fit is the row primitives' own job now (`insertRow`/`removeRow`) —
    /// this used to re-fit here, which measured the note BEFORE `removeRow`'s
    /// deferred detach actually took it out of the tree and left the popover a row
    /// too tall. Same latent bug the diagnosis panel hit; one fix covers both.
    private func toggleBlockedNote(for id: String, reason: String) {
        if let existing = blockedNoteByID.removeValue(forKey: id) {
            panel.removeRow(existing, animated: true)
            return
        }
        guard let row = deviceRowsByID[id] else { return }
        let note = makeRefusalNoteRow(text: reason)
        blockedNoteByID[id] = note
        panel.insertRow(note, after: row, animated: true)
    }

    /// A one-line refusal-note row (spec §4.6): an `info` glyph + `reason` in
    /// tertiary text, indented to the name column so it reads as annotating the
    /// row above it. Non-interactive.
    private func makeRefusalNoteRow(text: String) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        icon.contentTintColor = Tokens.Color.tertiaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.tertiaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        wrapper.addSubview(icon)
        wrapper.addSubview(label)
        let nameColumnLeading = PopoverColumnGrid.leadingInset
            + PopoverColumnGrid.iconWidth + PopoverColumnGrid.iconToName
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.applicationsFooterRowHeight),
            icon.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: nameColumnLeading),
            icon.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor,
                                            constant: -PopoverColumnGrid.leadingInset),
        ])
        return wrapper
    }

    // MARK: Connection failures + diagnosis panels (brief §7.3)
    //
    // The backend owns the connection state machine; the popover reacts to its
    // TRANSITIONS. On `→ .failed` it auto-expands the diagnosis panel ONCE for
    // that failure episode — it does NOT touch the Selected Devices / group
    // membership set (R12, W2-T3): a device that fails a reconnect KEEPS the
    // user's selection intent, exactly like a still-selected device that's
    // merely unavailable. Two things pick up the slack instead of a silent
    // unselect: the silence watchdog (W2-T2) keeps the Mac audible if this was
    // the only/last connected device, and the backend's converge loop re-kicks
    // automatically once discovery reports the device reachable again
    // (`NativeBackend.addOrUpdate`'s `desiredOn`-driven re-kick) — no user
    // action required. On `→ .connected` / `→ .off` any panel for the id is
    // torn down. "Try again" is `OutputBackend.retryOutput(_:)` via
    // `GroupController.retryConnection(for:)` — a single-device re-kick that
    // never touches membership. The panel is purely auto-driven off these
    // transitions — the manual warning-button toggle was retired 2026-07-17.

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
                // cleanup or force a closed panel back open. This same guard is
                // what keeps a mid-episode dismissal honored — a still-`.failed`
                // re-report breaks here, so the panel never pops back.
                guard !previous.isFailedState else { break }
                // A fresh `→ .failed` edge is a NEW episode: its auto-expand wins
                // over any prior dismissal, so clear the dismissal record before
                // (re)opening. This is what re-surfaces the panel on a
                // "Try again → fails again" (`.failed → .connecting → .failed`).
                dismissedDiagnosisIDs.remove(device.id)
                openDiagnosisIDs.insert(device.id)
            case .connected, .off:
                // Leaving `.failed` ends the episode — clear both the open intent
                // and the dismissal record so a future failure re-expands afresh.
                openDiagnosisIDs.remove(device.id)
                dismissedDiagnosisIDs.remove(device.id)
            case .connecting, .reconnecting:
                // In-flight: leave any open panel alone (a retry keeps its
                // context on screen until the attempt resolves). Deliberately
                // does NOT clear `dismissedDiagnosisIDs` — a retry that fails
                // again resolves through the fresh `→ .failed` edge above.
                break
            }
        }

        // Devices gone from the snapshot: drop their tracking + panel + dismissal.
        let liveIDs = Set(devices.map(\.id))
        for id in lastConnectionStates.keys where !liveIDs.contains(id) {
            lastConnectionStates.removeValue(forKey: id)
            openDiagnosisIDs.remove(id)
            dismissedDiagnosisIDs.remove(id)
        }

        // Devices the user no longer wants audio on: drop the panel even though the
        // backend keeps them `.failed`. `.failed` is STICKY (§1) — deselecting a
        // failed device produces no `→ .off` edge, so without this the panel outlives
        // the intent that justified it and sits under an unselected row forever
        // (found live: select → fail → deselect leaves the panel mounted for the rest
        // of the session, and each round leaves the popover sized for a row that is
        // no longer there). This is the MIRROR of R12, not a violation of it: R12
        // forbids a FAILURE from dropping the user's selection; this drops the
        // failure REPORT when the USER drops the selection. A redirect target counts
        // as intent too — its row is live and "Try again" still means something —
        // so it keeps its panel exactly like a Selected-Devices member.
        for id in openDiagnosisIDs.union(dismissedDiagnosisIDs) where !wantsAudio(id) {
            openDiagnosisIDs.remove(id)
            dismissedDiagnosisIDs.remove(id)
        }
    }

    /// Whether the user currently intends audio on `id` — a Selected-Devices/group
    /// member, or an app-redirect target. The same predicate `applySelectionState`
    /// uses for `controllable:`, so a row that renders live keeps its panel and one
    /// that doesn't loses it.
    private func wantsAudio(_ id: String) -> Bool {
        (groupController?.isSpeakerSelected(id) ?? false) || isRedirectTarget(id)
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
        for id in openDiagnosisIDs where !dismissedDiagnosisIDs.contains(id) {
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
        view.onDismiss = { [weak self] in self?.dismissDiagnosisPanel(for: id) }
        diagnosisPanelsByID[id] = view
        panel.insertRow(view, after: row, animated: animated)
    }

    /// The diagnosis panel's ✕ (B2): retract the open intent and record the
    /// dismissal for this episode, then reconcile so the mounted view is torn
    /// down. The panel won't reappear from repaints/rebuilds (`openDiagnosisIDs`
    /// no longer holds `id`), nor from a mid-episode `→ .failed` re-report (the
    /// still-`.failed` guard in `handleConnectionTransitions` short-circuits) —
    /// but a genuinely NEW failure episode re-expands it.
    private func dismissDiagnosisPanel(for id: String) {
        openDiagnosisIDs.remove(id)
        dismissedDiagnosisIDs.insert(id)
        reconcileDiagnosisPanels(animated: true)
    }

    /// "Try again": under R12 (W2-T3) the id is normally ALREADY selected/a
    /// group member (`.failed` no longer drops it), so this can't ride a
    /// plain `setDeviceSelected(id, true)` off→on edge —
    /// `GroupController.retryConnection(for:)` is the dedicated entry point,
    /// which calls `OutputBackend.retryOutput(id)`: a single-device re-kick
    /// back to `.connecting` that touches no other device (a broad routing
    /// re-apply used to re-kick EVERY parked `.failed` id — the retry storm,
    /// fixed 2026-08-06). Same call whether `id` is a Selected-Devices member
    /// or an active group's member (Groups and Selected Devices behave
    /// identically here). The eager `.failed → .connecting` edge this produces
    /// is also what marks the attempt USER-INITIATED for the episode
    /// semantics above — the backend's autonomous recovery never emits it.
    private func retryConnection(for id: String) {
        let result = groupController?.retryConnection(for: id) ?? .ok
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
    /// The destination popup leads with the standalone "Follows main output"
    /// entry (the default/neutral state), then mirrors `refreshMainOutRow`'s split — a
    /// "Current Device" entry (local, now an explicit pick) then the available
    /// (present + reachable) non-local AirPlay devices, plus this route's own
    /// target if it is currently unreachable (R5). The selected id is
    /// derived from `route.destination`, and the slider dims while local
    /// (decision 3, driven inside `AppRowView` by the selected entry's `isLocal`
    /// — true for both "No Redirect" and "Current Device").
    private func makeAppRow(_ route: AppRoute, devices: [Device]) -> AppRowView {
        let row = AppRowView(showsMeter: true)
        row.delegate = self
        // Tether chip (Warm Signal v4.1 CORRECTIONS, extending item 7): only
        // an actual AirPlay-device redirect has a matching device-row FEED
        // segment to tether to — "No Redirect"/"Current Device" get no chip.
        let tetherColor: NSColor?
        if case .device = route.destination {
            tetherColor = appTintColor(for: route.bundleID)
        } else {
            tetherColor = nil
        }
        row.apply(AppRowView.Configuration(
            appID: route.bundleID,
            name: route.displayName,
            icon: appIcon(for: route.bundleID),
            volume: route.volume,
            selectedDestinationID: destinationID(for: route.destination),
            destinations: appDestinations(devices: devices, keeping: route.destination,
                                         bundleID: route.bundleID),
            isRunning: !offlineBundleIDs.contains(route.bundleID),
            tetherColor: tetherColor),
                  isSelected: route.bundleID == selectedAppBundleID)
        appRowsByBundleID[route.bundleID] = row
        return row
    }

    /// The destination entries for ONE row's popup, in display order: a
    /// "Resume → <device>" entry when one is offerable (see below), then the
    /// standalone unrouted entry — titled with the Warm Signal bridge phrase
    /// **"Follows main output"** (§5.1, decision 3), supplied by the HOST per the
    /// host-supplies-copy doctrine — then the
    /// "Current Device" entry (decision 8, now an explicit pick), then every
    /// AVAILABLE non-local device (`availableAirPlayDestinations`).
    /// Plain values only — `AppRowView` is isolated from Core's `AppRoute` (T-6).
    ///
    /// `keeping` is this row's CURRENT destination, and it earns an entry even when
    /// it isn't offerable any more (R5). A route whose target went
    /// `isAvailable == false` is now kept rather than reset, and without this the
    /// row's `selectedDestinationID` would match nothing in the menu — which
    /// `AppRowView.apply` reads as "No Redirect" (its `?? true` fallback), rendering
    /// a dimmed slider and an unset-looking row for a route that is perfectly
    /// intact. The injected entry names the device and says what is actually
    /// happening to its audio meanwhile. Same inclusion rule
    /// `GroupEditorViewController` uses for its membership list ("available OR
    /// already a member"): what the user chose stays visible even when it has gone
    /// quiet.
    ///
    /// `bundleID` is this row's app identity, used ONLY to look up
    /// `AppRoutingController.clearedDeviceRouteTarget(for:)` — the device an
    /// app-quit `resetDeviceRoute` most recently cleared this app FROM, if any
    /// and if not yet consumed. When that remembered target is also in
    /// `available` (present + reachable now), a "Resume → <device name>" entry
    /// is prepended ahead of every other entry — the one-click way back to
    /// where this app was playing before it quit, without reversing the
    /// 2026-07-22 decision that the redirect itself doesn't survive the quit.
    /// Its id carries `resumeDestinationIDPrefix` rather than the plain device
    /// id so it never collides with that same device's own plain entry further
    /// down this same list; `destination(forID:)` strips the prefix back off,
    /// so picking "Resume" reaches `setDestination(.device(id:), for:)` through
    /// the exact same call site an ordinary device pick does.
    private func appDestinations(devices: [Device], keeping current: AppRouteDestination,
                                bundleID: String) -> [AppRowView.Destination] {
        let available = availableAirPlayDestinations(devices: devices)
        var entries: [AppRowView.Destination] = []
        if let resumeTargetID = appRouting.clearedDeviceRouteTarget(for: bundleID),
           let resumeDevice = available.first(where: { $0.id == resumeTargetID }) {
            entries.append(.init(id: Self.resumeDestinationID(forDeviceID: resumeDevice.id),
                                 title: "Resume → \(resumeDevice.name)",
                                 isLocal: false,
                                 symbolName: resumeDevice.kind.symbolName,
                                 isStandalone: true,
                                 subtitle: "Return to where this app was playing"))
        }
        entries.append(contentsOf: [
            .init(id: Self.noRedirectDestinationID,
                  title: "Follows main output",
                  isLocal: true,
                  symbolName: nil,
                  isStandalone: true,
                  subtitle: "Plays in the main mix"),
            .init(id: Self.currentDeviceDestinationID,
                  title: currentDeviceTitle(devices: devices),
                  isLocal: true,
                  symbolName: Device.Kind.localMac.symbolName,
                  subtitle: "Plays locally with its own volume"),
        ])
        for device in available {
            // One role per speaker: a device currently in Main Out (Selected
            // Devices, or the active group's members) is carrying the
            // whole-system mix, and a receiver holds ONE AirPlay session — it
            // can't ALSO carry a private per-app redirect. So it's simply not
            // offered as a redirect target, the same way an AirPlay-1 device
            // isn't (`availableAirPlayDestinations`). The reverse conflict —
            // selecting a speaker that already has a redirect — is resolved by
            // `AppRoutingController.clearRoutes(toDevices:)` (selection wins), so
            // by the time this renders, no kept route targets a Main Out member.
            // Deliberately NOT filtered inside `availableAirPlayDestinations`:
            // that set also drives R5 disappearance tracking, where a Main Out
            // member must still count as present.
            if groupController?.isMainOutMember(device.id) == true { continue }
            // R3 stopgap: a device already carrying a DIFFERENT app's redirect
            // gets an honest heads-up rather than a silent quality regression —
            // two independently-captured streams mixed onto one speaker warble
            // (`AppRouteMixer`'s multi-contributor path re-grids onto a wall-clock
            // frame index with no fractional interpolation; see the mixer's own
            // comments). Compares by bundleID (not `routedAppNames`' display
            // names) so two apps that happen to share a display name can't hide
            // this row's own route from itself. No engine/routing change — copy
            // only.
            let othersAlreadyRoutedHere = appRouting.appRoutes.contains { other in
                if case .device(let otherID) = other.destination, otherID == device.id,
                   other.bundleID != bundleID { return true }
                return false
            }
            entries.append(.init(id: device.id, title: device.name, isLocal: false,
                                 symbolName: device.kind.symbolName,
                                 subtitle: othersAlreadyRoutedHere ? Self.sameSpeakerQualitySubtitle : nil))
        }
        if case .device(let id) = current,
           !available.contains(where: { $0.id == id }),
           let device = devices.first(where: { $0.id == id && !$0.isLocalDevice }) {
            entries.append(.init(id: device.id, title: device.name, isLocal: false,
                                 symbolName: device.kind.symbolName,
                                 subtitle: Self.offlineDestinationSubtitle))
        }
        return entries
    }

    /// The secondary line on a kept-but-unreachable redirect target's menu entry
    /// (R5). It has to state the AUDIBLE consequence, not just the device's state:
    /// while the target is unreachable the app is no longer excluded from the
    /// whole-system capture tap, so it plays wherever the Mac's current top-level
    /// selection points — and the redirect resumes on its own once the device is
    /// back, with nothing for the user to re-pick.
    static let offlineDestinationSubtitle = "Offline — playing with system audio"

    /// The secondary line on an AirPlay device entry that already carries a
    /// DIFFERENT app's redirect (R3 stopgap). The real fix — resampling
    /// contributors onto one shared capture clock instead of a wall-clock frame
    /// grid — is a separate, larger follow-up; this is the honest heads-up in the
    /// meantime, not a claim the quality issue is solved.
    static let sameSpeakerQualitySubtitle = "Already in use — may reduce quality"

    /// The available AirPlay redirect targets: present, reachable (`isAvailable`),
    /// non-local devices, in the same stable order as the Selected Devices card.
    /// This is what a row may newly be POINTED at; it is not the same question as
    /// what a row may keep SHOWING — a route whose target drops out of this set is
    /// kept and gets an injected offline entry (`appDestinations(devices:keeping:bundleID:)`),
    /// and only an outright disappearance resets it (R5, `update(devices:)`).
    ///
    /// AirPlay-1-only (RAOP) devices are excluded (T4b, a deliberate product
    /// call, not a bug): a per-app rebind (`removeOutput`+`addOutput` on a
    /// route change, `NativeBackend.performBindOp`'s `.rebind`) re-anchors an
    /// AirPlay-1 device's internal clock — it has no shared timing protocol
    /// with AirPlay-2 — causing it to drift out of sync with the rest of a
    /// group, plus some classic receivers briefly reject the RTSP reconnect.
    /// AirPlay-1 speakers can't sync cleanly with per-app routing regardless,
    /// so they're simply not offered as a target rather than worked around.
    private func availableAirPlayDestinations(devices: [Device]) -> [Device] {
        devices.filter { !$0.isLocalDevice && $0.isAvailable && $0.supportsAirPlay2 }
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

    /// Inverse of `destinationID(for:)`: either local sentinel maps back to its
    /// own case; a "Resume → <device>" id has its prefix stripped back down to
    /// the plain device id it named all along; any other id is already a plain
    /// device id, mapping straight to `.device(id:)`. Picking the "Resume" entry
    /// therefore reaches the exact same `.device(id:)` case — and the exact
    /// same `setDestination` call site — an ordinary device pick does.
    private func destination(forID id: String) -> AppRouteDestination {
        if id == Self.noRedirectDestinationID { return .noRedirect }
        if id == Self.currentDeviceDestinationID { return .currentDevice }
        if id.hasPrefix(Self.resumeDestinationIDPrefix) {
            return .device(id: String(id.dropFirst(Self.resumeDestinationIDPrefix.count)))
        }
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

    /// This app's `AppTetherColor` tint (Warm Signal v4.1 CORRECTIONS,
    /// extending T7/item 7) — derived from the same icon `appIcon(for:)`
    /// resolves for the App Exceptions row, so a routed-but-quit app (icon
    /// falls back to the generic placeholder) and a running one resolve
    /// identically to whichever a redirect target's device row shows.
    /// `AppTetherColor.color(forBundleID:icon:)` caches per bundle id itself
    /// (Warm Signal v4 §Call 2), so repeated calls here are cheap.
    private func appTintColor(for bundleID: String) -> NSColor {
        AppTetherColor.color(forBundleID: bundleID, icon: appIcon(for: bundleID))
    }

    /// Every currently-routed app's tether tint, keyed by DISPLAY NAME —
    /// `DeviceRowView`'s FEED column only carries app display names (never
    /// bundle ids), so this is the map its `apply(appTintColors:)` parameter
    /// needs. Built from `appRouting.appRoutes` regardless of each route's
    /// destination (a device row only ever looks up names that are actually
    /// in ITS OWN `feedAppNames`, i.e. routed to that specific device, so an
    /// unrelated "Current Device"/"No Redirect" entry in this map is simply
    /// never read).
    private func appTintColorsByName() -> [String: NSColor] {
        var result: [String: NSColor] = [:]
        for route in appRouting.appRoutes {
            result[route.displayName] = appTintColor(for: route.bundleID)
        }
        return result
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
        makeAddApplicationMenu().popUp(positioning: nil,
                                       at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    /// Build the "+ Add application…" menu (C6): one selectable item per available
    /// app, or — when none are available — a single DISABLED "No applications
    /// available" item so the menu is never blank.
    private func makeAddApplicationMenu() -> NSMenu {
        let menu = NSMenu()
        let available = availableAppsForPicker()
        guard !available.isEmpty else {
            let item = NSMenuItem(title: "No applications available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }
        for app in available {
            let item = NSMenuItem(title: app.displayName, action: #selector(addApplicationMenuItemSelected(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.image = app.icon
            item.representedObject = app
            menu.addItem(item)
        }
        return menu
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
        // must bounce the switch back to its real state). Under a group target a
        // membership toggle can also flip the card between the derived-equal and
        // diverging dormant states (S5), which mounts/unmounts the "Inactive"
        // note — the reconciling repaint escalates to a rebuild exactly then.
        refreshDeviceRowsReconcilingCardNote()

        // A4: an auto-swap toggled the LOCAL row's membership for the user (not a
        // direct click on that row), so flash it once to draw the eye. Must run
        // AFTER the repaint above so it targets the currently-mounted row instance
        // (this path does no rebuild, so `deviceRowsByID`'s local row is live);
        // `flashRow()` is a no-op under Reduce Motion and when no row exists.
        if result.autoSwappedCurrentDevice,
           let localID = devicesByID.values.first(where: \.isLocalDevice)?.id {
            deviceRowsByID[localID]?.flashRow()
        }
    }

    private func presentRefusal(_ reason: String) {
        // A lightweight, non-blocking surface: the tooltip already carries the
        // reason on the disabled control; when a refusal reaches here (manual
        // gesture), we log it so the app layer can show it. Kept minimal so the
        // headless harness/tests can assert `test_lastRefusalReason`.
        FileHandle.standardError.write(Data("[Audiouter] \(reason)\n".utf8))
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

    // MARK: Empty-state / card-note / accessory test hooks (V2 / V11 / A1 / F1)

    /// Whether the Devices card's "Looking for devices…" placeholder is currently
    /// mounted (V2).
    public var test_devicesPlaceholderShown: Bool { devicesPlaceholderShown }
    /// Whether the Applications card's "No apps routed…" placeholder is currently
    /// mounted (V11).
    public var test_applicationsPlaceholderShown: Bool { applicationsPlaceholderShown }
    /// The card-note texts (`addCardNote`) for `title`, in add order — the A1
    /// dormancy annotation's assertion surface.
    public func test_cardNoteTexts(title: String) -> [String] {
        panel.test_cardNotes(title: title).map(\.stringValue)
    }
    /// Whether the header accessory for `title` is enabled (`nil` if none) — F1.
    public func test_cardAccessoryEnabled(title: String) -> Bool? {
        panel.test_accessoryEnabled(title: title)
    }
    /// Fire the header accessory action for `title` the way a real click would
    /// (proves it never triggers the card's collapse) — F1. Returns whether the
    /// card had an accessory to fire.
    @discardableResult
    public func test_fireCardAccessory(title: String) -> Bool {
        panel.test_fireAccessoryAction(title: title)
    }
    /// Whether device row `id`'s Selected checkbox is currently dimmed (A1).
    /// `nil` if no such row.
    public func test_deviceRowSelectionDimmed(id: String) -> Bool? {
        deviceRowsByID[id]?.test_isSelectionDimmed
    }
    /// Whether a blocked-row in-place refusal note (spec §4.6, S4) is currently
    /// mounted under device row `id`.
    public func test_isBlockedNoteShown(id: String) -> Bool {
        blockedNoteByID[id] != nil
    }
    /// Whether device row `id` is mid attention-flash (A4). `nil` if no such row.
    public func test_deviceRowFlashing(id: String) -> Bool? {
        deviceRowsByID[id]?.test_isFlashing
    }
    /// The "+ Add application…" picker's menu item titles, including the disabled
    /// "No applications available" placeholder when nothing is available (C6).
    public func test_addApplicationPickerTitles() -> [String] {
        makeAddApplicationMenu().items.map(\.title)
    }
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

    /// The collapse-reactive rail geometry the overlay resolves from the current
    /// laid-out frames (origin at ring vs collapsed header, the terminus dot, the
    /// visible device stops). Lets the rail-collapse tests assert the drawn shape.
    public func test_railPlan() -> RailPlan? { panel.test_railPlan() }

    /// Select the Main Out destination directly (drives the routing).
    public func test_selectMainOut(_ target: MainOutTarget) {
        groupController?.setMainOut(target)
        rebuild()
    }

    public func test_activate(groupID: String) {
        groupController?.setMainOut(.group(id: groupID))
        rebuild()
    }

    // MARK: Energize test hooks (item 9)

    /// Overrides the live Reduce Motion read for `beginEnergize` (`nil` = use the
    /// real workspace value) so a headless test drives BOTH sides deterministically.
    public var test_reduceMotionOverride: Bool?

    /// Drive a Main-Audio source switch through the EXACT production delegate
    /// path (`setMainOut` + `beginEnergize` + `rebuild`), so tests exercise the
    /// energize start beat + announcement the live dropdown does — unlike
    /// `test_selectMainOut`, which is the older plain-switch hook.
    public func test_switchMainOut(_ target: MainOutTarget) {
        mainOutRow(mainOutRow, didSelect: target)
    }

    /// The device ids currently carrying the energize pending beat (item 9).
    public var test_energizePendingIDs: Set<String> { energizePendingIDs }

    /// Whether an energize sequence is mid-flight.
    public var test_energizeActive: Bool { energizeActive }

    /// The last VoiceOver announcement the energize posted (start or settle).
    public var test_lastEnergizeAnnouncement: String? { lastEnergizeAnnouncement }

    /// Force a specific pending set + repaint — the snapshot harness stages a
    /// frozen mid-sequence frame with it (bypassing the async connection
    /// progression that a headless MockBackend never plays).
    public func test_setEnergizePending(_ ids: Set<String>) {
        energizePendingIDs = ids
        energizeActive = !ids.isEmpty
        refreshDeviceRows()
    }

    public func test_saveCurrentSetup() { saveCurrentSetup() }

    /// Subsection titles the LAST rebuild actually rendered, in order —
    /// asserts the Bluetooth subsection's hide-when-empty rule (BT-UI).
    public func test_subsectionTitles() -> [String] { renderedSubsectionTitles }

    /// The OUTPUT DEVICES "+" menu, built exactly as a live click builds it.
    /// Tests dispatch its items via `NSMenu.performActionForItem(at:)` — real
    /// AppKit menu dispatch, per the row-selection lesson (never a bypass seam).
    public func test_outputDevicesPlusMenu() -> NSMenu { makeOutputDevicesPlusMenu() }

    /// The device id whose align-by-ear tick is currently running, if any
    /// (BT-OFFSET-UI) — asserts one-at-a-time + the close/auto-stop paths.
    public func test_alignTickDeviceID() -> String? { alignTickDeviceID }

    /// The Bluetooth subsection's rendered row order (BT-UI ghost-pairing
    /// sort), top to bottom; empty when the subsection is hidden.
    public func test_bluetoothRowOrder() -> [String] { renderedBluetoothOrder }

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
        groupController?.setMainOutMasterVolume(value)
        refreshMainOutRow()
    }

    public func test_dragMaster(groupID: String, to value: Int) {
        if groupController?.activeGroupID != groupID {
            groupController?.setMainOut(.group(id: groupID))
        }
        groupController?.setMainOutMasterVolume(value)
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

    /// The blocked local-mix row's body-click (spec §4.6): surface the refusal
    /// reason as an in-place one-line note under the row (toggled — a second click
    /// dismisses it), reusing `GroupController.localMixRefusalReason`. This is the
    /// reachable trigger the disabled checkbox + tooltip alone lacked (§8.5).
    public func deviceRowDidRequestBlockedExplanation(_ row: DeviceRowView) {
        let reason = GroupController.localMixRefusalReason
        test_lastRefusalReason = reason
        presentRefusal(reason)
        toggleBlockedNote(for: row.device.id, reason: reason)
    }

    /// A greyed Bluetooth row's click (BT-UI "click connects"): a
    /// membership-FREE reconnect kick — `requestReconnect` goes straight to
    /// `OutputBackend.retryOutput`, never editing selection (selecting a
    /// greyed row separately means "play when up" and stays the node/checkbox's
    /// job, exactly like AirPlay rows).
    public func deviceRowDidRequestReconnect(_ row: DeviceRowView) {
        groupController?.requestReconnect(for: row.device.id)
    }

    public func deviceRow(_ row: DeviceRowView, didSetSyncTrimMs ms: Double, for id: String) {
        btTrimsByID[id] = ms
        onSetBTTrim?(ms, id)
    }

    public func deviceRow(_ row: DeviceRowView, didToggleAlignTick active: Bool, for id: String) {
        setAlignTick(active ? id : nil)
    }

    /// Move/stop the single align-by-ear tick (BT-OFFSET-UI): one row at a
    /// time, auto-stopped after ~30 s, and stopped by the popover closing
    /// (the click-away). `refreshDeviceRows()` re-applies every row so exactly
    /// the active row's button reads ON.
    private func setAlignTick(_ id: String?) {
        alignTickAutoStop?.cancel()
        alignTickAutoStop = nil
        let wasActive = alignTickDeviceID != nil
        alignTickDeviceID = id
        if id != nil {
            onAlignTickActiveChange?(true)
            let work = DispatchWorkItem { [weak self] in self?.setAlignTick(nil) }
            alignTickAutoStop = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.alignTickAutoStopInterval, execute: work)
        } else if wasActive {
            onAlignTickActiveChange?(false)
        }
        refreshDeviceRows()
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
        // Item 9: the source switch plays the energize sequence. Raise the
        // pending beat over the (now-current) member states BEFORE `rebuild()`
        // so the fresh rows render the instant drop-to-pending; the live
        // connection progression + `reconcileEnergize()` carry it to rest.
        beginEnergize(to: target)
        rebuild()
    }

    public func mainOutRow(_ row: MainOutRowView, didSetMaster volume: Int) {
        groupController?.setMainOutMasterVolume(volume)
        refreshDeviceRows()
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

    /// V14 host half: ↑/↓ from the selected app row moves the selection to the
    /// previous/next route in `appRoutes` order, clamped at the ends (no wrap).
    /// The move is relative to `appID` (the first responder that fired the key),
    /// so it works even if that's not `selectedAppBundleID`. Repaints via the
    /// same state-preserving `rebuild()` all app-row callbacks use, then promotes
    /// the newly-selected (freshly-recreated) row to first responder so
    /// Delete/↑/↓ keep working — done AFTER the rebuild so it targets the live
    /// row instance. The footer's remove-enabled stays true (selection moved to
    /// another existing route).
    public func appRow(_ row: AppRowView, didRequestMoveSelection direction: AppRowView.MoveDirection,
                       for appID: String) {
        let routes = appRouting.appRoutes
        guard let index = routes.firstIndex(where: { $0.bundleID == appID }) else { return }
        let targetIndex: Int
        switch direction {
        case .up:   targetIndex = index - 1
        case .down: targetIndex = index + 1
        }
        guard routes.indices.contains(targetIndex) else { return }   // clamp at ends
        let newSelection = routes[targetIndex].bundleID
        guard newSelection != selectedAppBundleID else { return }
        selectedAppBundleID = newSelection
        rebuild()   // re-pushes isSelected into every row and syncs the ± footer
        promoteFirstResponder(toAppRow: newSelection)
    }

    /// Make `bundleID`'s (freshly rebuilt) app row the window's first responder so
    /// keyboard removal/movement continues on it. No-op headless (`window == nil`)
    /// or if the row is missing.
    private func promoteFirstResponder(toAppRow bundleID: String) {
        guard let row = appRowsByBundleID[bundleID], let window = row.window else { return }
        window.makeFirstResponder(row)
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
        onMeteringActiveChange?(true)
    }

    public func popoverDidClose(_ notification: Notification) {
        removeDeselectMonitor()
        selectedAppBundleID = nil
        for row in deviceRowsByID.values { row.resetLevel() }
        mainOutRow.resetLevel()
        for row in appRowsByBundleID.values { row.resetLevel() }
        onMeteringActiveChange?(false)
        // The align-by-ear tick never outlives the surface that started it
        // (BT-OFFSET-UI click-away).
        setAlignTick(nil)
    }

    // MARK: - Live level dispatch (task T5)
    //
    // Fed by the host's per-tick RMS callback, NOT by `update(devices:)` — a
    // level push must never trigger `rebuild()`/`ensureDefaultSelection`, it
    // only forwards to the already-built row views.

    /// Push a live RMS reading for device `id` into its row's meter, and into
    /// the Main Out master meter when `id` is currently selected (Main Out
    /// shares the same level feed as its member device rows, task T4a).
    /// Early-returns while the popover isn't shown — metering only matters
    /// while a user can see it.
    public func updateLevel(_ rms: Float, for id: String) {
        guard popover.isShown else { return }
        dispatchLevel(rms, for: id)
    }

    /// Same dispatch as ``updateLevel(_:for:)`` but WITHOUT the `isShown`
    /// gate — headless snapshots/tests never actually show the popover.
    public func test_pushLevel(_ rms: Float, for id: String) {
        dispatchLevel(rms, for: id)
    }

    private func dispatchLevel(_ rms: Float, for id: String) {
        deviceRowsByID[id]?.setLevel(rms)
        if groupController?.isSpeakerSelected(id) == true {
            mainOutRow.setLevel(rms)
        }
    }

    /// Push a live RMS reading for the app with `bundleID` into its
    /// Applications-row meter (task T5). Unlike device levels, an app level
    /// never feeds Main Out — Main Out mirrors the SELECTED DEVICE's level,
    /// not any one app's contribution. Early-returns while the popover isn't
    /// shown, mirroring ``updateLevel(_:for:)``.
    public func updateAppLevel(_ rms: Float, for bundleID: String) {
        guard popover.isShown else { return }
        dispatchAppLevel(rms, for: bundleID)
    }

    /// Same dispatch as ``updateAppLevel(_:for:)`` but WITHOUT the `isShown`
    /// gate — headless snapshots/tests never actually show the popover.
    public func test_pushAppLevel(_ rms: Float, for bundleID: String) {
        dispatchAppLevel(rms, for: bundleID)
    }

    private func dispatchAppLevel(_ rms: Float, for bundleID: String) {
        appRowsByBundleID[bundleID]?.setLevel(rms)
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
