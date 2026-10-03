// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

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

/// A card's bottom **± footer strip** (T3, LOCKED DECISION): a single
/// `NSSegmentedControl` (`.momentaryAccelerator`) pinned to the card's leading
/// inset — the macOS list-management shape (System Settings / Contacts /
/// Keychain sidebars), never a full-width labelled button. Pure UI: both
/// actions route back through `onAdd`/`onRemove` closures so
/// `PopoverController` stays the only thing that talks to the controllers.
///
/// Two users, ONE construction so the popover has a single "add a thing to
/// this list" affordance: Applications ("+" opens the running-app picker, "−"
/// removes the selected row) and Output Devices ("+" fronts the add MENU, "−"
/// fronts the hide menu — 2026-09-15, replacing the add-only strip: a device
/// still leaves the LIST by going away; "−" only hides it from display).
/// Segment metrics are identical either way, so the two "+" glyphs sit on the
/// same left edge at the same size.
final class CardFooterView: NSView {

    enum Segment: Int { case add = 0, remove = 1 }

    var onAdd: (() -> Void)?
    var onRemove: (() -> Void)?

    private let segmented = NSSegmentedControl()
    let label: String

    init(label: String) {
        self.label = label
        super.init(frame: NSRect(x: 0, y: 0, width: 320,
                                 height: PopoverColumnGrid.applicationsFooterRowHeight))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildSubviews() {
        let segmentWidth = PopoverColumnGrid.applicationsFooterControlWidth / 2
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.segmentStyle = .texturedRounded
        segmented.trackingMode = .momentaryAccelerator
        segmented.segmentCount = 2
        let addSymbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        segmented.setImage(addSymbol, forSegment: Segment.add.rawValue)
        segmented.setWidth(segmentWidth, forSegment: Segment.add.rawValue)
        let removeSymbol = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")
        segmented.setImage(removeSymbol, forSegment: Segment.remove.rawValue)
        segmented.setWidth(segmentWidth, forSegment: Segment.remove.rawValue)
        segmented.target = self
        segmented.action = #selector(segmentTapped(_:))
        // The caller names the pair: the devices "+" fronts a MENU (save the
        // selected devices as a group, pair a Bluetooth speaker, connect a
        // known one) and its "−" fronts the hide menu, so the spoken name and
        // tooltip must cover more than "add/remove a device".
        segmented.setAccessibilityLabel(label)
        segmented.toolTip = label

        addSubview(segmented)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: PopoverColumnGrid.applicationsFooterRowHeight),
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: PopoverColumnGrid.leadingInset),
            segmented.centerYAnchor.constraint(equalTo: centerYAnchor),
            segmented.widthAnchor.constraint(equalToConstant: segmentWidth * 2),
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

/// Builds and owns the **Mixer panel** (SPEC §9 revised — SoundSource-inspired
/// Main Out model, 2026-07-14b). The panel is put on screen by the one-surface
/// host (`AppSurfaceController`), which claims it via
/// ``claimPanelForSurfaceHosting()``; this controller never presents anything
/// itself.
///
/// Structure, top to bottom:
/// 1. **System section — a single "Main Audio" row** (`MainOutRowView`): speaker
///    icon · "Main Audio" · master gain slider + `%` · a trailing
///    `NSPopUpButton` device selector. The selector is THE routing decision, with
///    two sections: "Selected Speakers" and each saved scene.
/// 2. **"Selected Speakers" section** — every discovered device, split into
///    **This Mac** (the Mac) and **AirPlay Speakers**. Each row's toggle
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
public final class PopoverController: NSObject {

    var groupController: GroupController?
    var devicesByID: [String: Device] = [:]

    /// `mixer:volume_adjusted` fires once per control kind ("device" /
    /// "master" / "app") per surface session — the sliders are continuous,
    /// so per-tick capture is forbidden. Cleared in `surfaceDidShow()`.
    var volumeAdjustedControls: Set<String> = []

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
    var offlineBundleIDs: Set<String> = []

    /// Backs the Applications card's collapse default (PLAN §B decision:
    /// "Applications expanded iff ≥1 app is redirected" — T-5). Injected with a
    /// default so every existing call site (AppDelegate, popover-harness,
    /// popover-snapshot, tests) keeps compiling unchanged; the Applications card
    /// itself is wired by a later task (T-8) — this controller only needs
    /// `routedAppCount` to compute the default.
    let appRouting: AppRoutingController

    /// Source of the running-app list for the "+ Add application…" picker
    /// (T-7). Defaults to real `.regular`-policy apps with a bundle id, mirroring
    /// how a Dock-visible app would be discovered; tests inject a fixed list so
    /// they don't depend on whatever's actually running.
    let runningAppsProvider: () -> [RunningAppInfo]

    /// The user's hidden-speakers list (display-only: never selection, groups
    /// or routing). `deviceSections()` drops a hidden UNSELECTED device; a
    /// hidden device that is selected — a saved scene can select one — still
    /// renders, so nothing ever plays from an invisible row.
    private let hiddenSpeakers: HiddenSpeakersController

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
    /// click is the intent here (the owner's Q6 call), so this does NOT violate
    /// the "never auto-reselect" rule elsewhere. `nil` (the default) means
    /// the button, if ever rendered, taps into nothing.
    public var onReselectAudiout: (() -> Void)?

    /// Called when the user taps the takeover status strip's "Try again"
    /// button (T6, state 4 — `.timedOut`): the bounded wait for the clock
    /// ran out, so the device the strip was explaining is now `.failed`
    /// (`enterFailure(_:cause:.timingUnavailable)`). The app wires this to
    /// the same sanctioned single-device re-kick the "Speakers unreachable"
    /// fallback banner's own "Try again" already drives
    /// (`GroupController.requestReconnect(for:)` per not-yet-connected Main
    /// Out member) — never a broad routing re-apply. `nil` (the default)
    /// means the button, if ever rendered, taps into nothing.
    public var onRetryTakeover: (() -> Void)?

    /// Called with `true` on `surfaceDidShow()` and `false` on
    /// `surfaceDidHide()` (T-GATE): the metering-active gate. The app wires this to
    /// `(backend as? MeteringControlling)?.setMeteringActive(_:)` so the backend
    /// only computes/emits `.level` while a user can actually see a meter. `nil`
    /// means "no backend adopts the capability" — the popover works exactly the
    /// same either way, just without the RMS work switched off underneath it.
    public var onMeteringActiveChange: ((Bool) -> Void)?
    /// The device-id set of every `update(devices:)`, fired regardless of
    /// visibility — the discovery stream the surface's launch `DiscoverySettleTracker`
    /// debounces to decide when the fleet has quiesced. `nil` when no host cares.
    public var onDeviceSnapshot: ((Set<String>) -> Void)?
    /// Called when an Applications-card slider moves, so the app can push the new
    /// volume straight to whichever renderer holds that app — a `.currentDevice`
    /// app's LOCAL playback stream (Bug T2), or the leveled intercept for an
    /// un-redirected one — for a low-latency response, in ADDITION to the persisted
    /// `AppRoutingController.setVolume` edit. The app wires this to
    /// `(backend as? AppRouteConfiguring)?.setLocalPlaybackVolume`. Called
    /// unconditionally (for every route kind): the backend no-ops it for a bundle
    /// ID with no live local stream, so the popover needs no destination knowledge.
    public var onSetLocalPlaybackVolume: ((_ volume: Int, _ bundleID: String) -> Void)?

    /// Called when the user picks "Pair a Bluetooth speaker…" from the Output
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

    /// Called when a Bluetooth device's Sync trim changes, already quantised.
    /// The app wires this to
    /// `(backend as? BTOutputControlling)?.setBTSyncTrim` — live-applied to
    /// that device's `BTSyncedSink` delay, and written to disk only when
    /// `persist` is true.
    ///
    /// `persist == false` is the drawer's live ruler scrub (D6): apply to
    /// audio, do NOT write the JSON store. Every discrete gesture — drag end,
    /// a stepper click, a typed commit — arrives with `true`.
    public var onSetBTTrim: ((_ ms: Double, _ deviceID: String, _ persist: Bool) -> Void)?

    /// The saved Sync trim for a Bluetooth device id — seeds each row's value
    /// (and the read-only display on a disconnected row). Wired to
    /// `(backend as? BTOutputControlling)?.btSyncTrim`. `nil` = 0, and edits
    /// then live only in `btTrimsByID` (mock/dev — nothing persists them).
    public var btTrimProvider: ((_ deviceID: String) -> Double)?

    /// Whether a Bluetooth device has a saved trim ENTRY at all — D10's
    /// "tuned vs never tuned", which `btTrimProvider`'s value alone cannot
    /// answer: a device deliberately tuned to exactly 0.0 ms is tuned, and
    /// must read "0.0 ms", not "Not set". Wired to
    /// `(backend as? BTOutputControlling)?.btHasSyncTrim`. `nil` = nothing is
    /// persisted, so every chip starts untuned and only a live edit
    /// (`btTunedDeviceIDs`) marks one tuned.
    public var btTrimIsSetProvider: ((_ deviceID: String) -> Bool)?

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

    /// The Mac's own SYNC trim (roadmap 056 Part 1). It is the SAME affordance
    /// the Bluetooth rows carry, but a different store: one local device, so
    /// the value lives in `AppSettings.syncOffsetMs` rather than `BTTrimStore`
    /// and these closures take no device id. Settings reads/writes work under
    /// any backend; only the live apply is native-gated.
    public var localTrimProvider: (() -> Double)?
    /// The local twin of ``btTrimIsSetProvider`` — "tuned or never tuned?".
    public var localTrimIsSetProvider: (() -> Bool)?
    /// One committed local trim edit: write the setting AND apply it live.
    /// There is no `persist` flag — the drawer emits only committed gestures.
    public var onSetLocalTrim: ((_ ms: Double) -> Void)?
    /// The local twin of ``onResetBTAlignment``: delete the stored
    /// `AppSettings.syncOffsetMs` entry (never write 0 — that is a tuned
    /// value) and bring the running local sink onto the cleared setting.
    public var onResetLocalTrim: (() -> Void)?
    /// The wizard's per-trial preview on a LOCAL target, never persisted —
    /// the local twin of `onBTWizardTrimPreview`.
    public var onLocalTrimPreview: ((_ ms: Double) -> Void)?
    /// End a local preview: non-nil keeps (and persists) it, `nil` restores.
    public var onLocalTrimEndPreview: ((_ keepMs: Double?) -> Void)?

    /// Whether the Mixer's first-run membership hint is still owed. `nil` — the
    /// default, and what the tests and the snapshot tools leave it at — means
    /// never show it, so no headless render can grow a card note.
    public var membershipHintShownProvider: (() -> Bool)?
    /// The user has just made their first membership toggle in the Mixer: the
    /// host persists the dismissal, so the provider above reads `false` from
    /// here on (including the reconcile that runs later in the same toggle).
    public var onMembershipHintDismissed: (() -> Void)?

    /// A CAST receiver's BY-EAR offset (CAST-SYNC). Third store, same
    /// affordance: the chip and drawer are the Bluetooth ones, the value lives
    /// in its own file keyed by receiver id, and the range is
    /// `BTSyncTrim.castRangeMs` rather than `rangeMs` — a Cast row corrects
    /// what the protocol cannot report (the receiver's output stage, its DAC,
    /// and a TV's HDMI → soundbar chain), not the receiver's own buffer, which
    /// is measured and removed automatically. No `persist` flag, for the same
    /// reason the local closures have none: the drawer emits committed
    /// gestures only. Wired to `(backend as? CastSyncOffsetControlling)`.
    public var onSetCastOffset: ((_ ms: Double, _ deviceID: String) -> Void)?
    /// The Cast twin of ``btTrimProvider``.
    public var castOffsetProvider: ((_ deviceID: String) -> Double)?
    /// The Cast twin of ``btTrimIsSetProvider`` — "tuned or never tuned?".
    public var castOffsetIsSetProvider: ((_ deviceID: String) -> Bool)?
    /// The Cast twin of ``onResetBTAlignment``: delete the stored entry (never
    /// write 0 — that is a tuned value) and put the live feed back on no
    /// correction.
    public var onResetCastOffset: ((_ deviceID: String) -> Void)?

    /// Delete a Bluetooth device's STORED alignment — its measured latency AND
    /// its trim — and re-push the live sink so a playing speaker reverts
    /// audibly to unaligned scheduling. The drawer's "Reset alignment" (roadmap
    /// 056); wired to `(backend as? BTOutputControlling)?.resetBTAlignment`.
    /// Distinct from `onSetBTTrim(0, …)`, which stores a deliberate 0 and would
    /// leave the chip reading "0 ms" rather than "Not set".
    public var onResetBTAlignment: ((_ deviceID: String) -> Void)?

    /// Called with `true`/`false` as the align-by-ear tick starts/stops
    /// (BT-OFFSET-UI). Wired to
    /// `(backend as? BTOutputControlling)?.setBTAlignTickActive`.
    public var onAlignTickActiveChange: ((_ active: Bool) -> Void)?

    /// The freshest trim value per device id (the user's latest edit, or the
    /// provider's persisted value on first read) — the rows' apply source, so
    /// a rebuild never has to round-trip the backend.
    var btTrimsByID: [String: Double] = [:]

    /// Device ids known to carry a deliberate trim (D10). Seeded from
    /// `btTrimIsSetProvider` the first time a row reads its trim, and joined
    /// by any device the user edits — an edit IS the act of tuning, so a
    /// scrub down to exactly 0.0 leaves a tuned chip reading "0.0 ms", never
    /// a chip that flips back to "Not set" under the user's hand.
    var btTunedDeviceIDs: Set<String> = []

    /// The Bluetooth device whose Sync drawer is currently open, or `nil`
    /// (D2 — at most one, ever). This is the INTENT; it survives `rebuild()`,
    /// which recreates rows, exactly like `openDiagnosisIDs`.
    var expandedSyncDeviceID: String?

    /// The device the mounted drawer view currently sits under — the view-layer
    /// mirror of `expandedSyncDeviceID`, rebuilt by `reconcileSyncDrawer`. A
    /// separate field rather than reading `syncDrawer.superview`, because
    /// `removeRow` defers its detach into an animation completion handler and
    /// the superview lingers for the length of the fade.
    var mountedSyncDrawerID: String?

    /// Whether the expanded drawer's device was selected the last time we
    /// looked. This turns "is selected" into an EDGE: a drawer opened on an
    /// available-but-unselected row (tuning a speaker before adding it to the
    /// mix — the chip is live whenever the device is available) survives,
    /// while a device the user drops OUT of the mix takes its drawer with it.
    /// Same edge discipline as `update(devices:)`'s Bluetooth availability
    /// deselect, and the mirror of the diagnosis panel's `wantsAudio` prune.
    var expandedSyncDeviceWasSelected = false
    /// Whether the drawer's value field was mid-edit when `rebuild()` detached
    /// it, so `reconcileSyncDrawer` can hand focus back after re-mounting.
    /// See the detach site in `rebuild()` for why this exists.
    var syncDrawerWasEditing = false

    /// The single reused drawer (D2): one instance reconfigured across
    /// devices, never one per row. Created lazily so a popover that never
    /// meets a Bluetooth device never builds it.
    lazy var syncDrawer: BTSyncDrawerView = {
        let view = BTSyncDrawerView()
        view.delegate = self
        return view
    }()

    // MARK: The Equalizer door (owner decision 2026-08-22)

    /// The id ``onOpenEqualizer`` passes for Main Audio. A sentinel, never a
    /// real device id — the whole mix is not a device, but the Main Audio row
    /// sits in the same stack and offers the same door, so one callback has to
    /// be able to name either.
    public static let mainOutEQID = "mainOut"

    /// Open the Equalizer page for this device id or ``mainOutEQID``; wired by
    /// the app to the Groups screen. The popover carries no tone state and no
    /// tone controls — it hands the id over and forgets it.
    public var onOpenEqualizer: ((String) -> Void)?

    /// Whether a device's saved curve is anything but flat — read from the
    /// SAME `DeviceEQStore` the Groups screen's detail pane writes through, so
    /// there is one answer and no second store. The row's Equalizer door wears
    /// its one mark from this; nothing else on the Mixer reads tone.
    public var deviceEQIsShaped: ((String) -> Bool)?

    // MARK: First-join alignment note + wizard (W3/W4)

    /// The wizard's live candidate push (never persisted). Wired to
    /// `setBTWizardTrimPreview`.
    public var onBTWizardTrimPreview: ((_ ms: Double, _ deviceID: String) -> Void)?
    /// End of a wizard preview: keep (persist) or restore. Wired to
    /// `endBTWizardTrimPreview`.
    public var onBTWizardEndPreview: ((_ deviceID: String, _ keepMs: Double?) -> Void)?
    /// The wizard-shaped tick gate (continuous, armed by the backend once every
    /// participating sink is playing). `btTargetDeviceID` names the Bluetooth
    /// device being measured, `nil` for a Mac-target run;
    /// `btReferenceDeviceID` names the speaker it is being compared against, so
    /// the backend can hold every OTHER Bluetooth speaker silent for the run.
    /// Wired to `setBTWizardTickActive`.
    public var onBTWizardTickActive: ((_ active: Bool, _ btTargetDeviceID: String?,
                                       _ btReferenceDeviceID: String?) -> Void)?
    /// The wizard panel is gone for good (every exit funnels through
    /// `tearDownBTWizard`). Wired to `endBTWizardRun` — it lowers the wide-open
    /// reference a Bluetooth run pinned, which the tick's `false` edge
    /// deliberately leaves standing so the receipt plays on the timeline the
    /// trials were judged on.
    public var onBTWizardEndRun: (() -> Void)?
    /// The wizard's stimulus tempo (BPM), driven by the estimator's stage.
    /// Wired to `setBTWizardTickTempo`.
    public var onBTWizardTempo: ((_ bpm: Double) -> Void)?
    /// Stage the mic-probe calibration sweeps on the live wizard feed
    /// (roadmap 064). Wired to `stageBTMicProbe`; nil (mock/dev backends)
    /// means no probe and the run stays purely by-ear.
    public var onStageBTMicProbe: ((_ onStarted: @escaping () -> Void,
                                    _ onFinished: @escaping () -> Void) -> Void)?
    /// The mic permission answer, asked from the wizard's Start (the system
    /// prompt when it is still undecided). Overridden in tests so no suite
    /// ever raises a real prompt.
    var ensureMicPermission: (@escaping (Bool) -> Void) -> Void = MicCapturePermission.ensure
    /// Whether Start is about to raise the system mic prompt. Overridden in
    /// tests so a listening run reads deterministically either way.
    var micPermissionIsUndecided: () -> Bool = { MicCapturePermission.isUndecided }
    /// The system mic prompt is about to be raised (`true`) or its answer has
    /// landed (`false`). The host suspends and restores the shell's tuck-away.
    var onMicPromptInFlightChanged: ((Bool) -> Void)?
    /// The mic prompt's answer landed and the run that asked is still live.
    /// The host brings the app back to front.
    var onMicPromptAnswered: (() -> Void)?
    /// The probe itself, so a test can hand the run a silent recorder.
    var makeMicProbe: () -> MicProbeSession = { MicProbeSession() }

    // MARK: Measured latency (roadmap 056 Part A)

    /// A Bluetooth device's MEASURED output latency (ms), or `nil` when the
    /// wizard has never run against it. Wired to `btMeasuredLatencyMs`; the
    /// row's SYNC tooltip and the wizard's base value both read it.
    public var btLatencyProvider: ((_ deviceID: String) -> Double?)?
    /// The latency values a run may present for a device. Wired to
    /// `btWizardLatencyRangeMs`.
    public var btLatencyRangeProvider: ((_ deviceID: String) -> ClosedRange<Double>)?
    /// The wizard's live latency candidate (never persisted), with how sure
    /// the run is about it — the half-width rides along purely so the trial's
    /// telemetry line can carry it. Wired to `setBTWizardLatencyPreview`.
    public var onBTWizardLatencyPreview:
        ((_ ms: Double, _ deviceID: String, _ halfWidthMs: Double?) -> Void)?
    /// End of a latency preview: keep (persist as the measured latency) or
    /// restore. Wired to `endBTWizardLatencyPreview`.
    public var onBTWizardEndLatencyPreview: ((_ deviceID: String, _ keepMs: Double?) -> Void)?
    /// Freshest-write-wins cache of measured latencies, so a row repaints
    /// straight after a run without waiting for the backend read-back.
    var btLatenciesByID: [String: Double] = [:]

    /// The Bluetooth device whose TRIM the running wizard has suspended to 0,
    /// or `nil` (a Mac-target run never suspends anything). Latency and trim are
    /// the same linear term in the delay, so a run made with the trim still
    /// applied converges on `trueLatency + trim` and stores the workaround as
    /// the measurement. `tearDownBTWizard` puts the STORE's value back — after a
    /// Keep that is the freshly-zeroed one, after every other exit the user's.
    var btWizardSuspendedTrimDeviceID: String?

    /// Devices the backend has offered alignment for since launch
    /// (`BackendEvent.btFirstMixAlignmentPrompt`) and the ones whose note the
    /// user hid. Neither is written down: the backend offers again on the next
    /// launch while the speaker stays unmeasured.
    var btAlignmentOfferedIDs: Set<String> = []
    var btAlignmentNoteHiddenIDs: Set<String> = []
    var btAlignmentNoteViews: [String: BTAlignmentNoteView] = [:]
    /// The device whose wizard is open, its live session, the view, and the
    /// floating window hosting it. Session lifetime == WINDOW lifetime: the
    /// wizard is no longer a row in the card stack, so it survives a popover
    /// close and ends only with its own window or its target.
    var btWizardDeviceID: String?
    var btWizardSession: BTAlignmentWizardSession?
    /// The in-flight mic-probe measurement, if this run has one (roadmap 064).
    var btWizardMicProbe: MicProbeSession?
    /// Bumped on every live preview push. The probe result is only trusted if
    /// the preview it was measured under is STILL the one applied — an answer
    /// (or a reference swap) mid-probe moves the sink under the sweep, and a
    /// measurement across that splice would be about two different timelines.
    var btWizardPreviewGeneration = 0
    /// The preview value in force when the probe's sweeps started — the
    /// measured Δ corrects THIS value into the proposal.
    var btWizardLastPreviewMs: Double = 0
    var btWizardView: BTAlignmentWizardView?
    var btWizardSheet: AlignmentWizardViewController?
    /// The reference device this run SELECTED for itself, so every exit path
    /// can put the user's Selected Devices set back. `nil` when the reference
    /// was already audible and nothing had to change.
    var btWizardEngagedReferenceID: String?

    /// The row whose align-by-ear tick is currently running, if any. One at a
    /// time: toggling another row's button moves the single tick.
    var alignTickDeviceID: String?
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

    let panel = PopoverPanelViewController()

    /// The single System-section Main Out row.
    let mainOutRow = MainOutRowView()

    var deviceRowsByID: [String: DeviceRowView] = [:]

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
    var diagnosisPanelsByID: [String: ConnectionDiagnosisView] = [:]

    /// Bluetooth devices the user explicitly asked to connect from the "+" menu
    /// during THIS popover session — listed while the attempt is in flight and
    /// while its outcome is still on screen, then dropped on close.
    ///
    /// This is why the listing predicate does NOT simply take any device whose
    /// `connectionState != .off`. `.failed` is STICKY and clears only on an
    /// availability edge or a full disappearance, and a paired Bluetooth device
    /// reaches neither: macOS keeps pairing records forever. A failed attempt — an
    /// off speaker, a deleted pairing's `.notPaired`, `.unauthorized` with no
    /// Bluetooth grant — would mint a row that never leaves, and one carrying no
    /// diagnosis panel either (that intent is pruned for anything failing
    /// `wantsAudio`), so the user could neither understand it nor dismiss it.
    /// Session-scoped instead: the outcome is visible while you are looking at
    /// it, and the list is clean again on the next open.
    var btConnectAttemptIDs: Set<String> = []

    // MARK: Energize (Warm Signal v4.1 item 9 — source-switch "press-play")

    /// The device ids currently showing the energize PENDING beat (item 9): the
    /// members of the just-switched Main-Audio target that hadn't started
    /// connecting yet (`connectionState == .off`) at the switch instant. Their
    /// rows render `MembershipBusView.Node.connecting` (gold dashed, on-spine) —
    /// the instant "press-play" drop — until their real `connectionState`
    /// advances (`→ .connecting`, then `→ .member`), at which point
    /// `reconcileEnergize()` prunes them and the model state carries the node.
    /// It is a PRESENTATION set only — it never gates membership/connection/
    /// routing. Empty (and untouched) under Reduce Motion, so the sweep is
    /// removed and every row snaps to its resolved state (spec item 9).
    var energizePendingIDs: Set<String> = []

    /// Whether an energize sequence is mid-flight (a source switch is still
    /// resolving). Gates the one-shot settle announcement so it fires exactly
    /// once, when the active target stops moving.
    var energizeActive = false

    /// Display name of the target the current energize is switching TO ("Selected
    /// Devices" or a saved group's name), for the VoiceOver announcements.
    private var energizeTargetName: String?

    /// The last VoiceOver announcement posted — the energize milestones and the
    /// live-removal offer share this one channel. A deterministic test seam
    /// (headless runs can't observe the real accessibility post).
    var lastEnergizeAnnouncement: String?

    /// The device currently offering the transient "Removed — Undo" (the
    /// live-removal safety net), and the timer that retires the offer.
    ///
    /// The OFFER IS HOST STATE, not row state, on purpose: a membership toggle
    /// repaints — and sometimes rebuilds — the whole card, so a row-owned pill
    /// would be destroyed by the very click that raised it. Keyed by device id,
    /// it also expires for free on the cases that must end it: a row rebuilt for
    /// a different device never matches the id, and a device that becomes a
    /// member again renders no offer (`applySelectionState`).
    var removalUndoDeviceID: String?
    private var removalUndoTimer: Timer?

    /// How long the live-removal offer stands before it retires itself.
    private static let removalUndoWindow: TimeInterval = 5

    /// Cast fixed-volume (feed-gain) receivers whose fader is currently
    /// holding the pending "not yet gold" tone, keyed by device id — HOST
    /// state, mirroring the removal-undo idiom above. Each id's own timer
    /// self-expires it after the measured stream lag.
    var castVolumePendingIDs: Set<String> = []
    var castVolumePendingTimers: [String: Timer] = [:]

    /// The Applications card's `AppRowView`s, keyed by bundle id (stable identity —
    /// `AppRoute.bundleID`). Populated by `rebuild()` in `appRoutes` order (T-8,
    /// PLAN §C). Lets `test_` hooks look a row up by bundle id.
    var appRowsByBundleID: [String: AppRowView] = [:]

    /// The Applications card's single selection (T1/T3 seam): the bundle id of
    /// the currently selected app row, or `nil` when nothing is selected. This
    /// is the HOST's source of truth — `AppRowView` only renders whatever
    /// `isSelected` it's pushed. Survives `rebuild()` (which recreates every
    /// row) exactly like `transientCollapsed`: it is NEVER cleared by a
    /// rebuild, only by an explicit selection change or the selected app being
    /// removed. Cleared when the selected app no longer has a route (removed
    /// via any of the three remove paths, or dropped for some other reason).
    var selectedAppBundleID: String?

    /// Active only while the popover is open: a local mouse-down monitor that
    /// clears `selectedAppBundleID` when the user clicks outside any app row or
    /// the ± footer (deselect-on-outside-click). Installed in `surfaceDidShow()`,
    /// removed in `surfaceDidHide()`.
    var deselectClickMonitor: Any?

    /// The Applications card's ± footer row (T3, LOCKED DECISION — replaces
    /// the retired "+ Add application…" row as the card's add affordance).
    let applicationsFooter = CardFooterView(label: "Add or remove application")

    /// The Output Devices card's footer row: the "+" that fronts
    /// `makeOutputDevicesPlusMenu()` and the "−" that fronts
    /// `makeOutputDevicesMinusMenu()` (2026-09-15 — hide a shown speaker).
    /// Lives at the BOTTOM of the card, below every subsection (the owner's
    /// call, 2026-08-08 — a list-management control belongs under the list,
    /// not in the column-title header row).
    let devicesFooter = CardFooterView(label: "Add, save or hide speakers")

    /// Whether the LAST `rebuild()` mounted the Applications card's "No apps
    /// routed…" empty-state placeholder (V11).
    var applicationsPlaceholderShown = false

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

    /// The device ids that were BOTH members of the active Main Out target AND
    /// `.connected` at the last `update(devices:)` — the rail connect pulse's
    /// firing baseline. `nil` until the first snapshot. Deliberately persists
    /// across `rebuild()`/`rebuildForOpen()`/open/close (it is model state), and
    /// keeps advancing while the surface is hidden — which is exactly what makes
    /// a reopen non-firing: a device that connected while closed is already
    /// settled state by the next open.
    private var lastConnectedMemberIDs: Set<String>?

    /// The sentinel destination id the Applications card's "This Mac" entry
    /// carries (T-8). `AppRouteDestination.currentDevice` names no specific device,
    /// but `AppRowView` works in plain string ids; this sentinel bridges the two
    /// and is chosen so it can never collide with a real `Device.id`.
    static let currentDeviceDestinationID = "\u{0000}current-device"

    /// The sentinel destination id the Applications card's standalone "Follows
    /// main output" entry carries — the new default/neutral state for a newly-added
    /// app (`AppRouteDestination.noRedirect`), distinct from the now-explicit
    /// "This Mac" pick. Chosen so it can never collide with a real
    /// `Device.id` or with `currentDeviceDestinationID`.
    static let noRedirectDestinationID = "\u{0000}no-redirect"

    /// The sentinel PREFIX a "Resume → <device or group>" destination entry's id
    /// carries
    /// (see `appDestinations(devices:keeping:bundleID:)`) — offered when
    /// `AppRoutingController.clearedRouteDestination(for:)` names a target the
    /// app-quit reset cleared and that target is currently offerable again. The
    /// underlying destination id is appended after the prefix so
    /// `destination(forID:)`
    /// can recover it; prefixed (rather than reusing the plain id) so this
    /// entry never collides with that same target's own plain entry lower in the
    /// same popup.
    static let resumeDestinationIDPrefix = "\u{0000}resume:"

    /// The sentinel PREFIX a saved-group destination entry's id carries — a
    /// group id and a `Device.id` are both opaque strings, so the two spaces are
    /// kept apart by construction rather than by hoping they never collide.
    static let groupDestinationIDPrefix = "\u{0000}group:"

    /// Builds the destination-popup id for a "Resume → <device>" entry
    /// targeting `deviceID`. Inverse of the prefix-stripping in
    /// `destination(forID:)`.
    static func resumeDestinationID(forDeviceID deviceID: String) -> String {
        resumeDestinationIDPrefix + deviceID
    }

    /// Builds the destination-popup id for a saved-group entry.
    static func groupDestinationID(forGroupID groupID: String) -> String {
        groupDestinationIDPrefix + groupID
    }

    /// The SF Symbol shown for a routed app that isn't currently running (its icon
    /// can't be resolved) — routes persist across app quits (T-8, PLAN §C). A
    /// documented AppKit-usable symbol.
    static let missingAppIconSymbolName = "app.dashed"

    /// The most recent local-mix refusal reason surfaced to the user (so the app
    /// / tests can assert the block was presented). Cleared on the next
    /// successful selection change.
    public var test_lastRefusalReason: String?

    /// - Parameters:
    ///   - appRouting: backs the Applications card's collapse default (T-5) and
    ///     the running-app picker (T-7). Defaulted so existing call sites
    ///     (AppDelegate, popover-harness, popover-snapshot, tests) compile
    ///     unchanged; tests inject one over a temp store. The default does NOT
    ///     load persistence, for the same reason `hiddenSpeakers` below does
    ///     not: a bare `PopoverController()` must never read the machine's real
    ///     `app-routes.json`. It used to, and a developer's own saved route
    ///     tinted the Applications card gold in a suite that had seeded none —
    ///     a failure that reproduced only on a machine that had used the app.
    ///   - runningAppsProvider: supplies the "+ Add application…" picker's
    ///     candidate list (T-7). Defaults to `NSWorkspace.shared
    ///     .runningApplications` filtered to `.regular`-activation-policy apps
    ///     with a non-nil bundle id; tests inject a fixed list.
    ///   - hiddenSpeakers: backs the devices footer's "−" (hide a shown
    ///     speaker) and the "+" menu's "Hidden speakers" section. The default
    ///     deliberately does NOT load persistence — the many bare
    ///     `PopoverController()` call sites (tests, harnesses) must never read
    ///     the machine's real hidden list; the app injects a persisted one.
    public init(appRouting: AppRoutingController = AppRoutingController(loadPersisted: false),
                runningAppsProvider: @escaping () -> [RunningAppInfo] = PopoverController.defaultRunningAppsProvider,
                hiddenSpeakers: HiddenSpeakersController = HiddenSpeakersController(loadPersisted: false)) {
        self.appRouting = appRouting
        self.runningAppsProvider = runningAppsProvider
        self.hiddenSpeakers = hiddenSpeakers
        super.init()
        panel.controller = self
        mainOutRow.delegate = self
        applicationsFooter.onAdd = { [weak self] in
            guard let self else { return }
            self.presentAddApplicationPicker(relativeTo: self.applicationsFooter)
        }
        applicationsFooter.onRemove = { [weak self] in self?.removeSelectedApp() }
        devicesFooter.onAdd = { [weak self] in self?.presentOutputDevicesPlusMenu() }
        devicesFooter.onRemove = { [weak self] in self?.presentOutputDevicesMinusMenu() }
        rebuild()
    }

    // MARK: Live slider drag (STABILITY D4, controller half)

    /// When the current volume drag stops counting as live. A structural
    /// `rebuild()` tears out and recreates every row, so one landing mid-drag
    /// detaches the very slider the mouse is tracking and the fader dies under
    /// the cursor. The rows report every drag step through the three volume
    /// delegate methods, so the controller can see a drag WITHOUT reading the
    /// row's own (private) flag — and a DEADLINE rather than a boolean is what
    /// makes the state self-healing: an Esc-cancelled drag, a row that never
    /// sends its mouse-up, a device that vanishes mid-gesture all expire on
    /// their own within the grace, so no stuck flag can freeze the panel.
    private var liveSliderDragUntil: CFTimeInterval = 0

    /// How long after the last drag step a rebuild still counts as mid-drag.
    private static let sliderDragGraceSeconds: TimeInterval = 0.3

    /// A structural rebuild that was refused mid-drag and still owes itself.
    /// A drag always produces further backend echoes, so the debt is paid by
    /// the next `update(devices:)` once the grace lapses — no timer needed.
    private var structuralRebuildDeferred = false

    /// Record what the CURRENT event says about the user's mouse, from inside a
    /// volume delegate callback. `NSApp` is optional-chained deliberately: it is
    /// nil under filtered test runs (see `DeviceRowView`), and a nil or
    /// uninteresting event must leave the deadline exactly as it was.
    func noteSliderGesture() {
        switch NSApp?.currentEvent?.type {
        case .leftMouseDragged, .leftMouseDown:
            liveSliderDragUntil = CACurrentMediaTime() + Self.sliderDragGraceSeconds
        case .leftMouseUp:
            liveSliderDragUntil = 0
        default:
            break
        }
    }

    /// Whether a volume drag is live right now.
    private var isSliderDragLive: Bool { CACurrentMediaTime() < liveSliderDragUntil }

    /// Test-only: pin (or release) the drag deadline without a real event.
    public func test_setLiveSliderDrag(_ active: Bool) {
        liveSliderDragUntil = active ? .greatestFiniteMagnitude : 0
    }

    /// Test-only: whether a structural rebuild is currently owed.
    public var test_structuralRebuildDeferred: Bool { structuralRebuildDeferred }

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
        // The raw discovery stream (visibility-independent): the launch splash's
        // settle tracker debounces this to know when the fleet has quiesced.
        onDeviceSnapshot?(Set(devicesByID.keys))
        // A SELECTED Bluetooth device that LOSES availability is DESELECTED
        // (the owner's call — off = unselected, replacing the backend's power-off
        // park). Both loss paths — a listed-but-disconnected snapshot AND a
        // vanish (unpair mid-session, sleep) — reach this surface as the same
        // availability edge on a kept row, so one edge covers them. Routed
        // through `setDeviceSelected` (the one selection owner — persist,
        // re-route, current-device floor), the same path a user's toggle-off
        // takes; the mirror of `handleDeviceDisappeared`'s route reset below.
        // Edge-only on purpose: a selection made ON an already-greyed row
        // ("play when up") has no edge and survives, so it still auto-starts
        // on connect; and a `.failed` story alone never deselects (R12) — only
        // the availability fact does. Bluetooth-only, deliberately: a wired
        // row keeps its selection through unplug, because the backend keeps
        // the greyed row and re-arms it on replug.
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

        // The rail's connect pulse fires from THIS diff — the model fact "a
        // device became a connected member of the active Main Out target" —
        // never from the overlay's own draws, so a layout-only change (open,
        // rebuild, collapse/expand) cannot fire it by construction. Not the
        // row's `.member`-node predicate: that one includes `.off` (it would
        // double-fire across the `.off → .connecting → .connected` dip) and
        // keys off `isSpeakerSelected`, which would let a per-app-redirect
        // connect pulse the Main-Audio wire. The stored set always advances,
        // hidden updates included, so a connect that lands while the surface is
        // closed is settled state by the next open.
        let nowConnectedMembers = Set(devices.compactMap {
            groupController?.isMainOutMember($0.id) == true && $0.connectionState == .connected
                ? $0.id : nil
        })
        if let previousConnected = lastConnectedMemberIDs {
            let newlyJoined = nowConnectedMembers.subtracting(previousConnected)
            if !newlyJoined.isEmpty, isEffectivelyShown {
                panel.playRailConnectPulse(joinedDeviceIDs: newlyJoined,
                                           cameToLife: previousConnected.isEmpty)
            }
        }
        lastConnectedMemberIDs = nowConnectedMembers

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
        if isEffectivelyShown {
            // Compared against what SHOULD render, not against every known device:
            // an unlisted Bluetooth device (or one in a collapsed subsection)
            // deliberately has no row, and comparing the whole fleet would read
            // that as a permanent structural change and rebuild on every backend
            // event. Headers are structure too: a COLLAPSED subsection contributes
            // no rows to the compare, but its header must still appear the moment
            // its type gains a first device, and go when the last one does — and
            // Bluetooth's header is ALWAYS expected (`rendersHeader`), never only
            // when it has rows.
            //
            // Both reads walk the whole fleet and rebuild the section list, and
            // nothing outside this gate consumes them — a hidden surface used to
            // pay for a diff no one read, on every backend event.
            let expectedSubsections = deviceSections().filter { rendersHeader($0) }.map(\.title)
            let deviceSetChanged = Set(renderedDeviceOrder().map(\.id)) != Set(deviceRowsByID.keys)
                || expectedSubsections != renderedSubsectionTitles
            let wantsStructuralRebuild = routesChanged || deviceSetChanged
                || validTargetsChanged || mainOutMembersChanged
            if (wantsStructuralRebuild || structuralRebuildDeferred) && !isSliderDragLive {
                rebuild()
                panel.panelContentDidChangeHeight(animated: true)
            } else {
                // Mid-drag (or nothing structural to do): take the repaint path
                // instead. A rebuild here would detach the slider the mouse is
                // tracking — the debt is recorded and paid by the next echo the
                // drag itself produces, once the grace lapses.
                if wantsStructuralRebuild { structuralRebuildDeferred = true }
                // A failure auto-deselect (handleConnectionTransitions above) can
                // change the checked set under a group target, flipping the
                // Devices card's dormancy note (S5) — the reconciling repaint
                // escalates to a rebuild exactly when the note must change.
                refreshDeviceRowsReconcilingCardNote()
                reconcileDiagnosisPanels(animated: true)
                reconcileBTAlignmentNotes(animated: true)
                // Re-reads the usable range from the provider (T3's trap) and
                // auto-collapses a drawer whose device has gone unavailable or
                // left the mix. The rebuild branch above reaches the same call
                // through `rebuild()`.
                reconcileSyncDrawer(animated: true)
            }
        }
        // Not shown: deliberately NO rebuild. Every open goes through
        // `rebuildForOpen()` (see `toggle(relativeTo:)`), which rebuilds the whole
        // panel from the state ingested above — a closed popover never needs a
        // live view tree, and nothing reads it while closed (`statusMasterVolume`
        // reads `groupController` directly). Rebuilding here made every backend
        // event a hidden full rebuild storm under volume-key repeat (audit B8).
        //
        // The ONE exception to hidden-means-idle: the wizard's own window is a
        // surface of its own and stays up through a popover close, so its
        // target check and its reference picker run unconditionally. The CARD's
        // reconcile stays inside the gate above — it IS a row in the panel.
        reconcileBTWizardLiveness()
    }

    /// Store the latest CONFIRMED per-device streaming map (T9,
    /// `BackendEvent.routedApps`) and let it feed the next repaint. Called by
    /// the host (`AppDelegate`) directly — unlike `Device` fields this signal
    /// has no home on `Device` (a redirect target is deliberately not
    /// `isSelected`, `AudioutCore/AGENTS.md`), so it can't ride
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

    /// Repaint the Main Out readouts from the model, for a master move that did
    /// NOT originate in this popover — a phone command (T7), or the Mac's own
    /// volume keys. A user-driven master change emits no `BackendEvent` (see
    /// `GroupController.setMain`), so `update(devices:)`'s repaint tail never
    /// runs for one; `GroupController.onStateDidChange` calls this instead.
    /// In-place only, never a `rebuild()` (audit B8), and it only READS the
    /// controller — no re-entrant mutation, unlike `update(devices:)`. Mid-drag
    /// thumb writes are already suppressed by `MainOutRowView`/`DeviceRowView`'s
    /// own drag guards.
    public func refreshMainOutMaster() {
        // Closed: nothing to repaint — every open goes through `rebuildForOpen()`,
        // whose `rebuild()` re-applies the Main Out row from the model.
        guard isEffectivelyShown else { return }
        refreshMainOutRow()
        // Deliberately NOT `refreshDeviceRows()`: no device row's paint depends on
        // the master EXCEPT the Mac's own while `localRowDrivesMain`, where the row
        // and Main are one control and `applySelectionState` overlays Main onto it.
        // The full sweep would re-run the energize reconcile, the rail extents and
        // the card accessory on every step of a volume-key hold, for one row's
        // number. (Everything else this hook can also announce — mute, membership,
        // groups — reaches the rows through the backend echo and its
        // `update(devices:)` tail, as it did before this repaint existed.)
        guard groupController?.localRowDrivesMain == true,
              let local = devicesByID.values.first(where: \.isLocalDevice),
              let row = deviceRowsByID[local.id] else { return }
        applySelectionState(to: row, device: local)
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

    /// The saved groups changed under us — created, renamed, deleted, or a
    /// membership edit, all of which happen in the Groups window while this
    /// surface may be on screen (pinned mode never self-dismisses). Both the
    /// Main Out selector and every app row's destination menu are built from
    /// `groupController.groups` at `rebuild()` time, and nothing else in
    /// `update(devices:)`'s structural triggers notices a group edit — so
    /// without this a group created next to an open surface is missing from the
    /// App Exceptions menus until the next reopen. Called by the host
    /// (`AppDelegate`), the owner of `GroupController.onGroupsDidChange`, the
    /// same way `applyRoutedAppRunning` is.
    ///
    /// A closed surface needs nothing: every open goes through
    /// `rebuildForOpen()`. Mid-drag it records the debt instead of rebuilding,
    /// which would detach the slider the mouse is tracking (see
    /// `update(devices:)`'s own drag gate).
    public func groupsDidChange() {
        guard isEffectivelyShown else { return }
        guard !isSliderDragLive else {
            structuralRebuildDeferred = true
            return
        }
        rebuild()
        panel.panelContentDidChangeHeight(animated: true)
    }

    // MARK: Silence-fallback banner (Wave 2 W2-T2, R11)

    /// The exact banner copy from PLAN-RELIABILITY Wave 2.
    static let localFallbackBannerText = "Speakers unreachable. Playing on your Mac. Will resume automatically."

    /// Whether the generalized silence watchdog (R11) has fallen back to local
    /// playback because zero desired devices stayed connected. Drives the banner;
    /// re-applied on every `rebuild()` so a rebuild mid-fallback keeps it pinned.
    var localFallbackActive = false

    /// Show or clear the "Speakers unreachable" banner (`BackendEvent.localFallbackActive`).
    /// Called by the host (`AppDelegate`) directly — a whole-app condition with no home
    /// on `Device`. Idempotent: a repeat of the current state is a no-op.
    public func setLocalFallbackActive(_ active: Bool) {
        guard active != localFallbackActive else { return }
        localFallbackActive = active
        if isEffectivelyShown {
            // Update the banner in place and re-fit; not a full rebuild — the cards are
            // unchanged, only the pinned banner appears/disappears.
            panel.setBanner(active ? Self.localFallbackBannerText : nil,
                            action: active ? localFallbackRetryAction : nil)
            panel.panelContentDidChangeHeight(animated: true)
            // The Mac's row joins or leaves the rail on this edge, and the Main
            // Audio row is re-applied with it, so the ring re-resolves too.
            refreshDeviceRows()
            refreshMainOutRow()
        }
        // When not shown, the next `rebuildForOpen()` re-applies it from
        // `localFallbackActive` (see the tail of `rebuild()`).
    }

    /// The banner's one way out. Without it "Speakers unreachable" states a
    /// problem and offers nothing — the user's only recourse is re-toggling
    /// rows one at a time.
    private var localFallbackRetryAction: SystemAirPlayNoteBannerView.Action {
        SystemAirPlayNoteBannerView.Action(
            title: "Try again",
            accessibilityLabel: "Try reconnecting to the unreachable speakers",
            handler: { [weak self] in self?.retryUnreachableMembers() })
    }

    /// Re-kick every Main-Out member that isn't up. N DELIBERATE per-device
    /// attempts through `requestReconnect` — the sanctioned single-device path —
    /// never a broad routing re-apply, which is what caused the 2026-08-06 retry
    /// storm. `.connecting` members are left alone: an attempt is already in
    /// flight for them.
    private func retryUnreachableMembers() {
        guard let controller = groupController else { return }
        for device in devicesByID.values
        where controller.isMainOutMember(device.id)
            && device.connectionState != .connected
            && device.connectionState != .connecting {
            controller.requestReconnect(for: device.id)
        }
    }

    // MARK: System-AirPlay guard note (Wave 3 W3-T3) + takeover status strip (T6)
    //        + routing-blocked-needs-default warning (T-UI)
    //
    // All these conditions want the SAME physical note slot (`panel.setSystemAirPlayNote`)
    // — there is only one, never two stacked notes (PLAN-AIRPLAY-COEXISTENCE.md T6).
    // PRECEDENCE, highest first: capture-failed (WARNING — the tap is dead, so every
    // speaker is silent while its row still says Connected) outranks routing-blocked
    // (T-UI, WARNING — audio is dead right now), which outranks the takeover status,
    // which outranks the double-path guard note, which outranks a one-time trial
    // banner, which outranks the trial pill, which outranks the unregistered-build
    // note (lowest — it is a standing condition, never something happening right now);
    // each lower note reappears underneath the instant the one above it clears. Each
    // condition keeps its own idempotence-check state var (`captureFailureMessage` /
    // `routingBlockedNeedsDefault` / `takeoverStatus` / `systemAirPlayNoteActive` /
    // `raisedTrialBanner` / `trialDaysLeft` / `unregisteredNoteActive`);
    // `applyNoteSlot()` is the one place that resolves precedence and actually
    // pushes to the panel, called by every setter and by the tail of `rebuild()`.

    /// The exact note copy from PLAN-RELIABILITY Wave 3's "System-AirPlay guard"
    /// bullet: non-blocking, informational — this never changes what's actually
    /// streaming, it only tells the user why they might hear an echo.
    static let systemAirPlayNoteText =
        "Your Mac's system output is also set to AirPlay. Audio may play twice. Switch it back to avoid an echo."

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
    /// "Audiout" token comes from `AggregateOutputDevice.productName` rather
    /// than a hardcoded string.
    static var routingBlockedNeedsDefaultText: String {
        "\(AggregateOutputDevice.productName) isn't your Mac's output device. Audio won't play until you switch back."
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

    /// The whole-system capture failure's message (`NativeCaptureError.userMessage`),
    /// or `nil` when the tap is healthy. Rendered verbatim — the error type owns
    /// this copy, including the remedy it names. TOP precedence in the note slot
    /// (see PRECEDENCE above); re-applied on every `rebuild()` so a rebuild
    /// mid-condition keeps it pinned.
    private var captureFailureMessage: String?

    /// Show or clear the whole-system capture-failure note
    /// (`BackendEvent.captureFailed`). Called by the host (`AppDelegate`)
    /// directly — a whole-app condition with no home on `Device`, same shape as
    /// ``setRoutingBlockedNeedsDefault(_:)``. Idempotent: a repeat of the current
    /// message is a no-op.
    public func setCaptureFailureMessage(_ message: String?) {
        guard message != captureFailureMessage else { return }
        captureFailureMessage = message
        applyNoteSlot()
    }

    /// The unregistered-build note's copy: a standing fact stated once, not a
    /// nag — the app is doing everything it always does either way.
    static let unregisteredNoteText = "Audiout is unregistered. Buying a license keeps it updated and funds the work of improving it."

    /// Whether this build has a license server but no key the server honours.
    /// Drives the LOWEST-precedence note (see PRECEDENCE above); re-applied on
    /// every `rebuild()` so a rebuild while unregistered keeps it pinned.
    private var unregisteredNoteActive = false

    /// Opens the purchase page. The host owns the URL (`AppSettings.buyURL`),
    /// exactly as it owns every other note action's remedy.
    public var onBuyAudiout: (() -> Void)?

    /// Show or clear the unregistered-build note. Called by the host
    /// (`AppDelegate`) directly — a whole-app condition with no home on
    /// `Device`, same shape as ``setSystemAirPlayNoteActive(_:)``. Idempotent:
    /// a repeat of the current state is a no-op.
    public func setUnregisteredNoteActive(_ active: Bool) {
        guard active != unregisteredNoteActive else { return }
        unregisteredNoteActive = active
        applyNoteSlot()
    }

    // MARK: Trial pill + the two one-time trial banners
    //
    // Both take the SAME single note slot as everything above, at their own
    // rungs of the PRECEDENCE list: a one-time banner outranks the standing
    // pill, and the pill outranks the unregistered-build note — a Mac on day 9
    // of its trial is not an unregistered install and must never be told it is.
    // Anything actually happening right now still outranks all three.

    /// Where this Mac's trial stands, asked fresh on every `rebuild()` — so the
    /// pill follows every open with no clock of its own. `nil` — the default,
    /// and what the tests and the snapshot tools leave it at — means this build
    /// has no trial to talk about, so no headless render can grow a note.
    public var trialStateProvider: (() -> TrialState)?

    /// The one-time banner this Mac is still owed, asked only while the trial
    /// is running. `nil` (either the closure or its answer) means none is due.
    public var trialBannerOwedProvider: (() -> TrialBanner?)?

    /// A one-time banner just went on screen. The host writes its flag down
    /// immediately — the banner is spent by being SHOWN, not by being dismissed,
    /// or a quit before reading it would bring it back — and reports it.
    public var onTrialBannerShown: ((TrialBanner) -> Void)?

    /// Days left in the running trial as of the last `rebuild()`, or `nil` when
    /// none is running. Recorded rather than re-derived, so the pinned note and
    /// the pill the last build rendered can never disagree.
    private var trialDaysLeft: Int?

    /// The one-time banner raised during THIS open. Session state, exactly like
    /// the first-join alignment note: nothing is written down here — the host
    /// persisted the flag the instant the banner was raised, and that is what
    /// stops it coming back on the next open.
    var raisedTrialBanner: TrialBanner?

    /// The pill's copy. Singular on the last day: the spec's example reads
    /// "Trial · 9 days left", and "1 days left" is not English.
    static func trialPillText(daysLeft: Int) -> String {
        "Trial · \(daysLeft) day\(daysLeft == 1 ? "" : "s") left"
    }

    /// Each banner's copy, verbatim from the trial spec's § Copy.
    static func trialBannerText(for banner: TrialBanner) -> String {
        switch banner {
        case .threeDays:
            return "Your trial ends in 3 days. €30 once keeps everything, including updates."
        case .lastDay:
            return "Last day of your trial. Tomorrow Audiout asks for a key."
        }
    }

    /// Re-read the trial and raise a one-time banner if one is owed. Runs from
    /// the tail of `rebuild()`, which is the same cycle every open already goes
    /// through — a pill a few hours stale until the next open is the whole
    /// accuracy this needs, and a countdown timer would be a second clock for
    /// nothing.
    private func refreshTrialNudge() {
        guard case .active(let daysLeft, _, _)? = trialStateProvider?() else {
            trialDaysLeft = nil
            raisedTrialBanner = nil
            return
        }
        trialDaysLeft = daysLeft
        guard raisedTrialBanner == nil, let owed = trialBannerOwedProvider?() else { return }
        raisedTrialBanner = owed
        onTrialBannerShown?(owed)
    }

    /// The trial nudges' action button — the same remedy the unregistered note
    /// offers, through the same host closure, under the spec's own words.
    private var trialBuyAction: SystemAirPlayNoteBannerView.Action {
        SystemAirPlayNoteBannerView.Action(
            title: "Buy Audiout",
            accessibilityLabel: "Buy an Audiout license",
            handler: { [weak self] in self?.onBuyAudiout?() })
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
    /// capture-failed (WARNING — the tap is dead, so the speakers are silent
    /// behind rows that still read Connected) outranks routing-blocked (T-UI,
    /// WARNING — audio is dead right now), which outranks a takeover status
    /// (T6), which outranks the double-path guard (W3-T3), which outranks a
    /// one-time trial banner, then the trial pill, then the unregistered-build
    /// note; none active means no note. `action` is non-nil for routing-blocked
    /// (the "Use <productName>" button), for the takeover strip's
    /// `.needsApproval` (state 1) and `.timedOut` (state 4, "Try Again"), for
    /// both trial nudges ("Buy Audiout") and for the unregistered note
    /// ("Buy…") — the states with an actual remedy a button can offer. The
    /// capture-failure message names its own remedy in prose, so it has none.
    private var resolvedSystemAirPlayNote: (text: String?, action: SystemAirPlayNoteBannerView.Action?, severity: SystemAirPlayNoteBannerView.Severity) {
        if let captureFailureMessage {
            return (captureFailureMessage, nil, .warning)
        }
        if routingBlockedNeedsDefault {
            return (Self.routingBlockedNeedsDefaultText, routingBlockedNeedsDefaultAction, .warning)
        }
        if let takeoverStatus {
            // State 4 (`.timedOut`) is a genuine failure — the connection did
            // NOT complete — so it takes the same warning tier routing-blocked
            // uses, rather than the informational tier the other three
            // (still-in-progress or explains-a-remedy) states keep.
            let severity: SystemAirPlayNoteBannerView.Severity = takeoverStatus == .timedOut ? .warning : .info
            return (Self.takeoverStatusText(for: takeoverStatus), takeoverStatusAction(for: takeoverStatus), severity)
        }
        if systemAirPlayNoteActive {
            return (Self.systemAirPlayNoteText, nil, .info)
        }
        if let raisedTrialBanner {
            return (Self.trialBannerText(for: raisedTrialBanner), trialBuyAction, .info)
        }
        if let trialDaysLeft {
            return (Self.trialPillText(daysLeft: trialDaysLeft), trialBuyAction, .info)
        }
        if unregisteredNoteActive {
            return (Self.unregisteredNoteText, unregisteredNoteAction, .info)
        }
        return (nil, nil, .info)
    }

    /// The unregistered note's action button.
    private var unregisteredNoteAction: SystemAirPlayNoteBannerView.Action {
        SystemAirPlayNoteBannerView.Action(
            title: "Buy…",
            accessibilityLabel: "Buy an Audiout license",
            handler: { [weak self] in self?.onBuyAudiout?() })
    }

    /// The routing-blocked warning's action button (T-UI, the owner's Q6 — the
    /// user's own click is their intent, so re-selecting the aggregate here
    /// does NOT violate "never auto-reselect").
    private var routingBlockedNeedsDefaultAction: SystemAirPlayNoteBannerView.Action {
        SystemAirPlayNoteBannerView.Action(
            title: "Use \(AggregateOutputDevice.productName)",
            accessibilityLabel: "Use \(AggregateOutputDevice.productName) as the Mac's output device",
            handler: { [weak self] in self?.onReselectAudiout?() })
    }

    /// The takeover strip's copy for each state (T6, PLAN-AIRPLAY-COEXISTENCE.md) —
    /// plain language throughout, never "PTP"/"bind"/"ports 319/320". State 3's
    /// copy is the plan's own exact wording; the others follow its voice. State
    /// 4's copy is honest about the outcome — the wait ran out and the
    /// connection genuinely failed (`enterFailure(_:cause:.timingUnavailable)`),
    /// so it no longer promises the app will "try again" on its own; the "Try
    /// Again" button below is what actually does that, on the user's own ask.
    static func takeoverStatusText(for status: TakeoverStatus) -> String {
        switch status {
        case .needsApproval:
            return "Speaker Sync needs permission to run. Open Login Items to approve it."
        case .helperMissing:
            return "Speaker Sync is missing from this copy of Audiout. Reinstall Audiout to fix it."
        case .takingOver:
            return "Taking audio back from macOS…"
        case .timedOut:
            return "Speaker Sync couldn't get the speakers' clocks in step, so this connection couldn't complete."
        }
    }

    /// The strip's action button. States 1 (`.needsApproval`) and 4
    /// (`.timedOut`) have one: state 2's own doc says plainly there's nothing
    /// an approval UX can do about a missing bundle component, and state 3 is
    /// transient. State 4's device is genuinely `.failed` by the time the
    /// state shows, so "Try again" gives the user the same single-device
    /// re-kick a `.failed` row's own diagnosis panel offers.
    private func takeoverStatusAction(for status: TakeoverStatus) -> SystemAirPlayNoteBannerView.Action? {
        switch status {
        case .needsApproval:
            return SystemAirPlayNoteBannerView.Action(
                title: "Open Login Items…",
                accessibilityLabel: "Open Login Items to approve Speaker Sync",
                handler: { [weak self] in self?.onOpenPTPHelperLoginItems?() })
        case .timedOut:
            return SystemAirPlayNoteBannerView.Action(
                title: "Try again",
                accessibilityLabel: "Try connecting again",
                handler: { [weak self] in self?.onRetryTakeover?() })
        case .helperMissing, .takingOver:
            return nil
        }
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
    ///
    /// Master-mute reports 0, which DRAINS the menu-bar arc, so the
    /// closed-panel glance never lies "80% and broadcasting" while the mix is
    /// silent (mirrors the row meter-drain rule).
    public var statusMasterVolume: Double {
        guard let controller = groupController else { return 0 }
        guard !controller.isMainOutMuted else { return 0 }
        return Double(controller.mainOutMasterVolume) / 100.0
    }

    // MARK: Show / hide

    /// Whether the HOST currently has this panel on screen. Owned by
    /// ``surfaceDidShow()`` / ``surfaceDidHide()`` — the two calls a host makes
    /// around putting the panel on/off screen.
    var hostIsShown = false

    /// Headless test seam: no host can actually put the panel on screen under
    /// `swift test`, so tests flip this to exercise the shown-path repaint
    /// semantics (the view tree IS the test suite's rendering surface).
    /// Production code never sets it.
    public var test_isShownOverride = false

    /// The ONE visibility question this controller asks. Every
    /// skip-work-while-hidden gate reads this and nothing else, which is what
    /// lets any host present the same panel content.
    var isEffectivelyShown: Bool { hostIsShown || test_isShownOverride }

    /// Total `rebuild()` calls, for tests asserting a closed popover does NOT
    /// rebuild per backend event (audit B8).
    public private(set) var test_rebuildCount = 0

    /// The host's size hook. A host assigns this to hear every size publish
    /// and run `apply` (the `preferredContentSize` assignment) — the
    /// one-surface host assigns it at claim time, and uses it ONLY to notice
    /// content taller than its fixed frame (logged once per open), never to
    /// resize. `nil` means NO host is listening (pre-claim, or headless
    /// tests/tools): the size change applies immediately, which is exactly
    /// right for a panel nothing is showing.
    var surfaceResizer: ((_ animated: Bool, _ apply: () -> Void) -> Void)?

    /// Hand the panel to the one-surface host (U3, `AppSurfaceController`) —
    /// the single door through which a host may take the panel. A plain
    /// accessor today, but the name is the contract: taking the panel is a
    /// CLAIM (the caller must install `surfaceResizer` and run the open
    /// ritual), not a peek — so `panel` itself stays private.
    func claimPanelForSurfaceHosting() -> PopoverPanelViewController {
        panel
    }

    /// Apply the panel's next `preferredContentSize` change in front of the
    /// current host. The panel's resize primitive
    /// (`panelContentDidChangeHeight`) calls this so the DOCUMENTED
    /// `preferredContentSize` size channel stays the one channel; `animated`
    /// is carried for the caller and never animates a window under the
    /// one-surface host, whose frame is fixed. The panel itself holds no
    /// reference to any host.
    func applySurfaceResize(animated: Bool, whileApplying apply: () -> Void) {
        if let surfaceResizer {
            surfaceResizer(animated, apply)
            return
        }
        apply()
    }

    /// Rebuild as an OPEN (T-5, PLAN §B): recompute every collapsible card's
    /// default and discard manual toggles from the previous open, THEN rebuild.
    /// Shared by `test_simulateOpen()` and the surface host's mount path
    /// (`AppSurfaceController`), which must run this open ritual before
    /// putting the panel on screen (hidden means idle, so an open re-ingests
    /// everything that arrived meanwhile).
    func rebuildForOpen() {
        isRebuildingForOpen = true
        transientCollapsed.removeAll()
        // Every open starts the search story over: an empty AirPlay section
        // reads as "looking" again rather than inheriting a previous session's
        // verdict. Armed BEFORE the rebuild so the first render sees the state.
        armSpeakerSearchGrace()
        rebuild()
        isRebuildingForOpen = false
    }

    // MARK: Build

    public func rebuild() {
        test_rebuildCount += 1
        // Any rebuild satisfies a deferred one (D4) — including `rebuildForOpen()`
        // and the delegate paths, which reach here too.
        structuralRebuildDeferred = false
        deviceRowsByID.removeAll()
        // The mounted panel views die with their rows; the open-panel INTENT
        // (`openDiagnosisIDs`) survives and is re-applied below (brief §7.3 —
        // "rebuild() restores open panels").
        diagnosisPanelsByID.removeAll()
        // Same lifetime rule for the W3 notes: the views die with the row tree
        // here; the intent (`btAlignmentOfferedIDs`) survives and remounts
        // below. The W4 wizard is NOT in this tree — it lives in its own
        // window and a rebuild does not touch it.
        btAlignmentNoteViews.removeAll()
        // The ONE reused drawer view (D2) can't just be forgotten the way the
        // per-id panels above are: `clearRows()` drops the cards, but the
        // drawer stays parented to the orphaned body stack it was inserted
        // into. Detach it explicitly; the INTENT (`expandedSyncDeviceID`)
        // survives and `reconcileSyncDrawer` re-mounts it under the fresh row.
        if mountedSyncDrawerID != nil {
            // Detaching a view that is BEING EDITED ends its field-editor
            // session and drops first responder back to the window (measured).
            // The typed value still commits on the way out, so nothing is lost
            // — but focus silently vanishes, and inside a `.transient` popover
            // the user's NEXT Return then lands with no first responder and
            // closes the whole surface. That is the live "Return closes the
            // popover and my edit goes nowhere" report: not the field's key
            // handling (which consumes Return correctly — proven by real event
            // dispatch in `SyncValueFieldLiveKeyTests`), but a background
            // repaint pulling the field out from under the user mid-type. Any
            // structural repaint runs this: a device appearing, a route
            // change, a valid-target flip. Remember the editing state here and
            // restore it once `reconcileSyncDrawer` has re-mounted the drawer.
            syncDrawerWasEditing = syncDrawer.isEditingValue
            syncDrawer.removeFromSuperview()
            mountedSyncDrawerID = nil
        }
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
        // on the left, "Output" over the destination dropdown on the right
        // ("Output" framing, decision m).
        //
        // NO card names the SLIDER column. All three share ONE trailing-anchored
        // slider column, so a title over it prints the same word three times —
        // and a horizontal fader with a live `%` beside it is the most
        // self-evident control on the surface. The TRAILING titles stay: Output /
        // Source / Offset / Redirect each name a different, genuinely non-obvious
        // thing occupying one shared column. The asymmetry is the point; don't
        // restore a slider title for symmetry.
        //
        // Collapsible (T-4, PLAN decision 5): the chevron/title toggle the body.
        // Collapse-DEFAULT policy (T-5, PLAN §B): defaults are recomputed on
        // every OPEN (Main Audio starts expanded); a rebuild WITHIN one open
        // (backend events, etc.) instead preserves whatever the transient state
        // currently is — `collapsedState(for:default:)` picks the right one.
        panel.beginCard(header: Self.mainAudioCardTitle, trailingTitle: "Output",
                        collapsible: true,
                        collapsed: collapsedState(for: Self.mainAudioCardTitle, default: false),
                        onToggle: { [weak self] in self?.toggleCard(Self.mainAudioCardTitle) })
        panel.addRow(mainOutRow)
        refreshMainOutRow()

        // 2. Selected Devices card — split into Current Device + AirPlay. ALWAYS
        // present now (V2): with an empty fleet the card still builds, and the
        // always-rendered Bluetooth subsection's own Connect affordance is the
        // card's empty-state message — no separate placeholder row (a "Looking
        // for devices…" line above an actionable Connect button said two
        // contradictory things at once; removed 2026-08-08).
        let sections = deviceSections()
        renderedSubsectionTitles = []
        renderedBluetoothOrder = []
        renderedBTConnectShown = false
        renderedSpeakerSearchText = nil
        bluetoothConnectButton = nil
        // Combined header row: "Output Speakers" title on the left. The
        // membership "Selected" column MOVED to the left spine
        // (v4 §Call-1), so this card no longer heads a membership column — but
        // its device rows' trailing dropdown column, once left empty, now
        // fills the FEED composite (v4.1 item 3), so the header names it
        // "Source" (renamed from "Feed", 2026-08-28 — the column carries
        // `DeviceRowView.updateFeedText`/`feedStack`; the internal FEED
        // vocabulary stays). The header row carries NO accessory: the "+"
        // that fronts the add MENU is the card's bottom footer strip now
        // (`devicesFooter`, added after every subsection below).
        // The FEED pills are LEFT-ALIGNED in their slot, so the "Source"
        // title left-aligns on the same leading anchor the pills use
        // (`feedColumnLeadingFromTrailing`) — centered over the whole reserved
        // column it floated ~46 pt right of a single pill.
        //
        // The "Offset" column legend (renamed from "Sync", 2026-08-28) rides
        // this SAME header line — moved up from the subsection header lines
        // when the This Mac subsection was dissolved, and printed exactly
        // once. Same has-rows gate as before, now card-wide: only when a row
        // carrying the sync chip (`showsSyncControls`: the Mac's own row, or
        // a listed Bluetooth row) actually renders under it — chrome must
        // never name absent content. Gated on the SECTIONS, not on collapse
        // (a collapsed subsection still has its rows, exactly as a collapsed
        // card keeps its own column titles). Left-aligns in its own column
        // on `offsetTitleLeadingFromTrailing`, matching how "Source"
        // left-aligns above, over the SYNC chip it names.
        let showsOffsetTitle = sections.contains {
            ($0.title == Self.thisMacSubsectionTitle
                || $0.title == Self.bluetoothSubsectionTitle) && !$0.devices.isEmpty
        }
        renderedOffsetColumnTitle = showsOffsetTitle
        panel.beginCard(header: Self.outputDevicesCardTitle, trailingTitle: "Source",
                        trailingTitleLeadingFromTrailing:
                            PopoverColumnGrid.feedColumnLeadingFromTrailing,
                        trailingTitleToolTip: Self.sourceColumnHelp,
                        secondTrailingTitle: showsOffsetTitle ? "Offset" : nil,
                        secondTrailingTitleLeadingFromTrailing:
                            PopoverColumnGrid.offsetTitleLeadingFromTrailing,
                        secondTrailingTitleToolTip: showsOffsetTitle ? Self.offsetColumnHelp : nil,
                        collapsible: true,
                        collapsed: collapsedState(for: Self.outputDevicesCardTitle, default: false),
                        // The one card whose list can outgrow the surface (roadmap
                        // 039): past its ceiling the speakers scroll, while this
                        // header — "Source", "Offset" — holds still above them.
                        scrollsBody: true,
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
        // The first-run hint yields to the dormancy note: "Inactive" and "click
        // a name to play here" cannot both be true of the same card.
        let showsHint = membershipHintShouldShow(sections: sections)
        renderedMembershipHint = showsHint
        if showsHint {
            panel.addCardNote(Self.membershipHintText)
        }
        // The Mac's own row is PINNED directly under the card header (header
        // decision 2026-08-28): no "This Mac" subsection wrapper any more — no
        // grouping label, no chevron, no per-subsection collapse. The row
        // lands in the CARD's body (`currentSubsectionStack` is nil here), so
        // collapsing "Output Speakers" still folds it with everything else,
        // and the rail's order is untouched (`deviceSections()` still lists
        // it first). "AirPlay Speakers" is therefore the first subsection.
        if let macSection = sections.first(where: { $0.title == Self.thisMacSubsectionTitle }) {
            for device in macSection.devices {
                panel.addRow(makeDeviceRow(device, indented: false))
            }
        }
        // A subsection is HIDDEN entirely when it has no rows to show — never
        // an empty grouping label — except Bluetooth, whose header always
        // renders (BT-LIST): its empty body IS content, the Connect
        // affordance (`rendersHeader`). A COLLAPSED one keeps its header and
        // renders no rows. Subsection headers carry no column titles — the
        // "Offset" legend lives on the card header line above (printed once).
        // `rendersHeader` is also `update(devices:)`'s structural-compare
        // filter, so what renders and what is expected can't drift — This Mac
        // answers false there (pinned row, never a grouping header).
        for section in sections where rendersHeader(section) {
            let collapsed = addSubsection(section.title)
            guard !collapsed else { continue }
            addSubsectionRows(section)
        }
        // The "+" footer belongs to the CARD, not to any one subsection, so it
        // is added after ALL of them (AirPlay / Cast / Bluetooth) — last
        // thing in the card body, and hidden with it when the card collapses.
        // `endSubsection()` is what keeps it out of the last subsection's clip,
        // where collapsing Bluetooth would take the strip with it. A sync drawer
        // opens via `insertRow` directly under ITS device row, so it can never
        // land below this strip.
        panel.endSubsection()
        // The "−" pops a menu of the shown speakers; with none to offer (only
        // the Mac's row, or nothing) the segment disables like the
        // Applications "−" does with no selection.
        devicesFooter.isRemoveEnabled = sections.contains {
            $0.title != Self.thisMacSubsectionTitle && !$0.devices.isEmpty
        }
        panel.addRow(devicesFooter)
        // Set each row's rail extent + feed the continuous rail overlay: the
        // spine runs Main Audio → the LOWEST SELECTED node; rows below it render
        // BARE (no rail) — spec v4 §Call-1. Runs even with no devices (the overlay
        // then draws just the Main Audio origin hook).
        updateRailRows()

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
        panel.beginCard(header: title, trailingTitle: "Output",
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
            panel.addRow(makePlaceholderRow(text: Self.applicationsEmptyPlaceholderText))
            applicationsPlaceholderShown = true
        }
        applicationsFooter.isRemoveEnabled = selectedAppBundleID != nil
        panel.addRow(applicationsFooter)
        // Every card exists now, so the titles can take their liveness tint.
        refreshCardHeaderLiveness()

        // Groups card removed (2026-07-16): the popover no longer renders a Groups
        // SECTION. Group ROUTING lives in the Main Out selector (refreshMainOutRow)
        // and membership editing lives in the mixer window (header Groups button).

        // Footer removed (2026-07-14): Open Mixer → header Groups button;
        // Save-as-group → Groups "+"; Quit → header Quit button.

        // Restore any open diagnosis panels under their (freshly created) rows
        // (brief §7.3 — a failure that arrived while the popover was closed goes
        // through this path). Un-animated: the whole panel is being (re)built.
        reconcileDiagnosisPanels(animated: false)
        // Same restore for the first-mix alignment card / wizard panel (W3/W4):
        // their intent survives the rebuild; the mounted views don't.
        reconcileBTAlignmentNotes(animated: false)
        // Same restore for the Sync drawer, and the same un-animated reasoning.
        reconcileSyncDrawer(animated: false)

        // Re-pin the silence-fallback banner (R11) above the cards: `clearRows()`
        // above dropped it with everything else, so a rebuild that happens WHILE the
        // fallback is active (e.g. a device set change) must restore it.
        panel.setBanner(localFallbackActive ? Self.localFallbackBannerText : nil,
                        action: localFallbackActive ? localFallbackRetryAction : nil)
        // Re-pin the note slot (T-UI routing-blocked / T6 takeover strip / W3-T3
        // double-path guard) the same way — resolved through the same PRECEDENCE
        // `applyNoteSlot()` uses, so a rebuild mid-condition restores the right one.
        // The trial's own two rungs are re-read first: this is the cycle the pill
        // follows, and the one that raises a one-time banner.
        refreshTrialNudge()
        let note = resolvedSystemAirPlayNote
        panel.setSystemAirPlayNote(note.text, action: note.action, severity: note.severity)
        // The device list this rebuild just re-mounted is a fresh scrolling card,
        // and a fresh one starts at height 0. Callers that publish a size get the
        // reconcile from `fittingSizeSettled`; the app-routing callbacks don't
        // publish, so without this the list stays collapsed to nothing under its
        // own header until the next device event. Reconciling here covers every
        // rebuild path at once, and changes no publish policy.
        panel.reconcileScrollingBodyHeight()
    }

    func orderedDevices() -> [Device] {
        devicesByID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The device-type subsection labels — constants because, like the card
    /// titles, the string IS the collapse key and tests assert the rendered
    /// text. "This Mac" is no longer a RENDERED header (its row is pinned
    /// directly under the card header since 2026-08-28) — the constant
    /// survives as `deviceSections()`'s grouping key for the local band, which
    /// keeps the rail's full order and the section machinery on one list.
    static let thisMacSubsectionTitle = "This Mac"
    static let airPlaySubsectionTitle = "AirPlay Speakers"
    static let bluetoothSubsectionTitle = "Bluetooth Speakers"
    static let castSubsectionTitle = "Cast Speakers"

    /// One device-type subsection and the rows it would render, the Bluetooth
    /// connected-only filter already applied.
    struct DeviceSection {
        let title: String
        let devices: [Device]
    }

    /// Bluetooth renders its header even with nothing listed — its empty
    /// state IS content (the Connect affordance). AirPlay does the same while a
    /// search state is active: the state line needs the "AirPlay Speakers"
    /// grouping label above it to say WHAT was not found. The rest stay
    /// hidden-when-empty — and This Mac NEVER renders one (2026-08-28: its row
    /// is pinned directly under the card header, no subsection). This answer
    /// is shared by `rebuild()`'s section loop and `update(devices:)`'s
    /// structural compare; splitting them made every backend event read as a
    /// structural change and rebuild the whole panel.
    private func rendersHeader(_ section: DeviceSection) -> Bool {
        if section.title == Self.thisMacSubsectionTitle { return false }
        if !section.devices.isEmpty { return true }
        if section.title == Self.bluetoothSubsectionTitle { return true }
        return section.title == Self.airPlaySubsectionTitle && speakerSearchState() != nil
    }

    // MARK: Speaker search / empty / permission state (P1-1)

    /// What the AirPlay subsection should SAY when it has nothing in it.
    enum SpeakerSearchState {
        case searching
        case noneFound
        case permissionDenied
    }

    /// Host seam: whether macOS has denied this app permission to see devices on
    /// the local network. `nil` or `false` means "not known denied" — the popover
    /// has no way to ask on its own (the signal lives in the app layer's
    /// `SetupModel`), so the permission variant stays dormant until a host wires
    /// this up.
    public var localNetworkDeniedProvider: (() -> Bool)?

    /// How long an empty AirPlay section reads as "still looking" before it
    /// admits it found nothing.
    static let speakerSearchGraceSeconds: TimeInterval = 3.0

    /// Whether this open's search grace has elapsed, and the one-shot timer that
    /// sets it. Re-armed on every open (`rebuildForOpen`), dropped when the
    /// surface goes away.
    private var speakerSearchGraceElapsed = false
    private var speakerSearchGraceTimer: Timer?

    /// The state line the LAST `rebuild()` actually rendered, or `nil` when it
    /// rendered none — recorded rather than re-derived, so the test surface can
    /// never drift from what was mounted (the `renderedSubsectionTitles` idiom).
    var renderedSpeakerSearchText: String?

    /// The AirPlay section's empty-state story, or `nil` when there is nothing
    /// to tell. Cast counts too: a browsed receiver means the network is
    /// visibly working, so "no speakers found" would be a lie.
    private func speakerSearchState() -> SpeakerSearchState? {
        let sections = deviceSections()
        let hasNetworkSpeaker = sections.contains {
            ($0.title == Self.airPlaySubsectionTitle || $0.title == Self.castSubsectionTitle)
                && !$0.devices.isEmpty
        }
        if hasNetworkSpeaker { return nil }
        if localNetworkDeniedProvider?() == true { return .permissionDenied }
        return speakerSearchGraceElapsed ? .noneFound : .searching
    }

    /// Arm (or drop) this open's search grace. Only armed when there is actually
    /// a state to age — a fleet with speakers in it needs no timer.
    private func armSpeakerSearchGrace() {
        speakerSearchGraceTimer?.invalidate()
        speakerSearchGraceTimer = nil
        speakerSearchGraceElapsed = false
        guard speakerSearchState() != nil else { return }
        speakerSearchGraceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.speakerSearchGraceSeconds,
            repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireSpeakerSearchGrace() }
        }
    }

    func cancelSpeakerSearchGrace() {
        speakerSearchGraceTimer?.invalidate()
        speakerSearchGraceTimer = nil
    }

    /// The grace elapsed: "Looking for speakers…" becomes "none found". Only
    /// the SEARCHING line needs the explicit rebuild — every other flip rides a
    /// device arrival/departure, which is already a structural change.
    func fireSpeakerSearchGrace() {
        speakerSearchGraceTimer = nil
        guard !speakerSearchGraceElapsed else { return }
        let wasSearching = renderedSpeakerSearchText == Self.speakerSearchingText
        speakerSearchGraceElapsed = true
        guard isEffectivelyShown, wasSearching else { return }
        rebuild()
        panel.panelContentDidChangeHeight(animated: true)
    }

    static let speakerSearchingText = "Looking for speakers…"
    static let speakerNoneFoundText = "No AirPlay speakers found on your Wi-Fi network."
    static let speakerNoneFoundHintText =
        "Make sure your speakers are awake and on the same Wi-Fi network as this Mac."
    static let speakerPermissionDeniedText =
        "Audiout doesn\u{2019}t have permission to see speakers on your Wi-Fi network."
    static let speakerPermissionDeniedHintText =
        "Allow Local Network for Audiout in System Settings \u{203A} Privacy & Security."

    /// The AirPlay subsection's empty body, built the same way the Bluetooth
    /// Connect row is: a wrapper on the name column whose CONTENT is the empty
    /// state. Secondary, never tertiary — this is live state text explaining why
    /// the list is empty, and dimming the explanation of the dimming reads as
    /// broken (folder rule).
    private func makeSpeakerSearchStateRow(_ state: SpeakerSearchState) -> NSView {
        let message: String
        let hint: String?
        switch state {
        case .searching:
            message = Self.speakerSearchingText
            hint = nil
        case .noneFound:
            message = Self.speakerNoneFoundText
            hint = Self.speakerNoneFoundHintText
        case .permissionDenied:
            message = Self.speakerPermissionDeniedText
            hint = Self.speakerPermissionDeniedHintText
        }
        renderedSpeakerSearchText = message

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Tokens.Font.menuItem
        label.textColor = Tokens.Color.secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        let nameColumnLeading = PopoverColumnGrid.nameColumnLeading
        let trailingInset = -PopoverColumnGrid.leadingInset
        var constraints: [NSLayoutConstraint] = [
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: nameColumnLeading),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor,
                                            constant: trailingInset),
        ]

        if let hint {
            // Two stacked labels: the wrapper GROWS to fit rather than being
            // pinned to `rowHeight`, or the hint would be clipped out of a row
            // sized for one line.
            let hintLabel = NSTextField(wrappingLabelWithString: hint)
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            hintLabel.font = Tokens.Font.captionMedium
            hintLabel.textColor = Tokens.Color.secondaryLabel
            hintLabel.isSelectable = false
            hintLabel.preferredMaxLayoutWidth =
                SurfaceLayout.width - nameColumnLeading - PopoverColumnGrid.leadingInset
            wrapper.addSubview(hintLabel)
            constraints += [
                label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
                hintLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
                hintLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor,
                                                    constant: trailingInset),
                hintLabel.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -8),
            ]
        } else {
            // One line: a spinner beside it, so "looking" is visibly a process
            // and not a stuck string. Reduce Motion gets the words alone.
            constraints += [
                wrapper.heightAnchor.constraint(equalToConstant: DeviceRowView.rowHeight),
                label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            ]
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let spinner = NSProgressIndicator()
                spinner.translatesAutoresizingMaskIntoConstraints = false
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.isIndeterminate = true
                wrapper.addSubview(spinner)
                spinner.startAnimation(nil)
                constraints += [
                    spinner.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
                    spinner.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
                ]
            }
        }
        NSLayoutConstraint.activate(constraints)
        return wrapper
    }

    /// The four subsections in RENDER order — the one place the order and the
    /// BT-LIST connected-only filter are expressed, so the rail's render order
    /// can never drift from the rows' (the terminus would land on the wrong
    /// row). A wired output lists under the Mac's own pinned row, name-sorted
    /// after it, rather than under AirPlay.
    /// Whether `device` is dropped from the list by the user's hidden set.
    /// The Mac's own row is never hideable, and a SELECTED device always
    /// renders regardless (a saved scene can select a hidden speaker — the
    /// row must be visible while it plays; the footer "−" menu disables
    /// selected speakers so the direct path can't get here).
    private func isHiddenFromList(_ device: Device) -> Bool {
        !device.isLocalDevice
            && hiddenSpeakers.isHidden(device.id)
            && !(groupController?.isSpeakerSelected(device.id) ?? false)
    }

    func deviceSections() -> [DeviceSection] {
        let visible = orderedDevices().filter {
            (!$0.isBluetooth || isBluetoothRowListed($0)) && !isHiddenFromList($0)
        }
        return [
            DeviceSection(title: Self.thisMacSubsectionTitle,
                          devices: visible.filter(\.isLocalDevice) + visible.filter(\.isWired)),
            DeviceSection(title: Self.airPlaySubsectionTitle,
                          devices: visible.filter { !$0.isLocalDevice && !$0.isBluetooth && !$0.isCast && !$0.isWired }),
            DeviceSection(title: Self.castSubsectionTitle,
                          devices: visible.filter(\.isCast)),
            DeviceSection(title: Self.bluetoothSubsectionTitle,
                          devices: orderedBluetoothDevices(in: visible)),
        ]
    }

    /// The devices `rebuild()` would mount rows for right now: visible, and
    /// inside an EXPANDED subsection. Compared against `deviceRowsByID` to
    /// decide whether `update(devices:)` needs a structural rebuild. The rail
    /// deliberately does NOT read this — its cut follows the lowest reached device
    /// in the FULL order (`updateRailRows`).
    func renderedDeviceOrder() -> [Device] {
        deviceSections().filter { !isSubsectionCollapsed($0.title) }.flatMap(\.devices)
    }

    func isSubsectionCollapsed(_ title: String) -> Bool {
        transientCollapsed[title] ?? false
    }

    /// Subsection titles the LAST `rebuild()` actually rendered, in order —
    /// the hide-when-empty assertion surface (`test_subsectionTitles`).
    var renderedSubsectionTitles: [String] = []

    /// The Bluetooth subsection's device ids as the LAST `rebuild()` rendered
    /// them, top to bottom — the recency-sort assertion surface
    /// (`test_bluetoothRowOrder`). Empty when the subsection is hidden.
    var renderedBluetoothOrder: [String] = []

    /// Whether the LAST `rebuild()` mounted the Bluetooth empty-state Connect
    /// row (BT-LIST) — `test_bluetoothConnectRowShown()`.
    var renderedBTConnectShown = false

    /// Whether the LAST `rebuild()` printed the card header's "Offset" column
    /// title — `test_offsetColumnTitleShown()`. Recorded rather than derived
    /// because the title is a RENDER decision (it must never name a column with
    /// no rows under it), and nothing else on this surface would notice it
    /// silently going missing. One card-level Bool since the 2026-08-28 header
    /// decision moved the legend off the subsection header lines: it prints on
    /// the card header, exactly once.
    var renderedOffsetColumnTitle = false

    /// The mounted Bluetooth empty-state Connect button, for
    /// `test_fireBluetoothConnectClick()` to drive real target/action dispatch.
    weak var bluetoothConnectButton: NSButton?

    /// `panel.addSubsectionHeader` + the rendered-titles record, so the test
    /// surface can never drift from what was actually mounted. Returns whether
    /// the subsection is COLLAPSED, i.e. whether the caller must skip its rows.
    ///
    /// Collapse rides the same `collapsedState(for:default:)` machinery the
    /// cards use, keyed by the exact subsection title — so a manual toggle is
    /// transient within one open and `rebuildForOpen()` resets it to the
    /// expanded default, identically to a card.
    @discardableResult
    private func addSubsection(_ title: String) -> Bool {
        renderedSubsectionTitles.append(title)
        let collapsed = collapsedState(for: title, default: false)
        panel.addSubsectionHeader(title, collapsible: true, collapsed: collapsed,
                                  onToggle: { [weak self] in self?.toggleSubsection(title) })
        return collapsed
    }

    /// Build one subsection's rows into the panel — the Bluetooth empty state's
    /// Connect affordance (BT-LIST) or one `DeviceRowView` per member. Shared by
    /// `rebuild()` and the EXPAND half of `toggleSubsection`, so a section built
    /// by a toggle can never differ from the same section built by a rebuild.
    private func addSubsectionRows(_ section: DeviceSection) {
        if section.title == Self.bluetoothSubsectionTitle {
            renderedBluetoothOrder = section.devices.map(\.id)
            if section.devices.isEmpty {
                panel.addRow(makeBluetoothConnectRow())
                renderedBTConnectShown = true
                return
            }
        }
        // The AirPlay section's empty body is its own content too (P1-1): the
        // searching / nothing-found / permission-denied line, the exact shape of
        // the Bluetooth branch above. Scoped to AirPlay by copy AND by its own
        // header, so it can never contradict the Bluetooth Connect affordance.
        if section.title == Self.airPlaySubsectionTitle, section.devices.isEmpty,
           let state = speakerSearchState() {
            panel.addRow(makeSpeakerSearchStateRow(state))
            return
        }
        for device in section.devices { panel.addRow(makeDeviceRow(device, indented: false)) }
    }

    /// Chevron/header click on a device-type subsection: flip the TRANSIENT
    /// collapse state, then let the subsection's own clip carry the travel
    /// (`setSubsectionCollapsed` — the row-reveal mechanism over a GROUP of
    /// rows, at the same duration and curve). Never a `rebuild()`: a rebuild
    /// puts the content at its final size instantly, leaving only the surface
    /// animating — the live snap/judder report.
    ///
    /// The MODEL flips on the click even though the collapsed rows' views only
    /// leave when the clip finishes closing: `renderedDeviceOrder()` feeds
    /// `update(devices:)`'s structural compare and the drawer reconcile, and the
    /// rail's own extents (which read the collapse state directly) re-run in the
    /// same turn — none of them may wait on an animation.
    ///
    /// Consequences of the rows leaving, both intended: an open sync drawer
    /// under one of them loses its row, so `reconcileSyncDrawer` retracts the
    /// drawer INTENT and stops the align-by-ear tick with it; and a diagnosis
    /// panel is simply unmounted, while its open/dismissed INTENT is untouched —
    /// collapse is a display action, never a membership one, so the panel
    /// returns on expand if its episode is still open.
    private func toggleSubsection(_ title: String) {
        let collapsed = !isSubsectionCollapsed(title)
        transientCollapsed[title] = collapsed
        guard let section = deviceSections().first(where: { $0.title == title }) else { return }
        if collapsed {
            dropSubsectionRowModel(section)
            reconcileSyncDrawer(animated: false)
            updateRailRows()
        }
        panel.setSubsectionCollapsed(title: title, collapsed: collapsed, animated: true) {
            // EXPAND only, and before the panel measures: the rows, then the
            // panels whose intent survived the collapse, so the clip's natural
            // height is the whole subsection's.
            addSubsectionRows(section)
            reconcileDiagnosisPanels(animated: false)
            reconcileBTAlignmentNotes(animated: false)
            reconcileSyncDrawer(animated: false)
            updateRailRows()
        }
    }

    /// Drop the MODEL for a subsection collapsing away: its rows, the panels
    /// mounted under them, and the ONE reused sync drawer (D2), which — exactly
    /// as in `rebuild()` — cannot be left parented to a tree that is about to be
    /// torn down. The INTENTS (`openDiagnosisIDs`, `btAlignmentOfferedIDs`)
    /// are deliberately untouched: collapse is display only, and the expand's
    /// reconcile remounts from them. The wizard's window is not in this tree at
    /// all, so a collapse never reaches it.
    private func dropSubsectionRowModel(_ section: DeviceSection) {
        for device in section.devices {
            deviceRowsByID.removeValue(forKey: device.id)
            diagnosisPanelsByID.removeValue(forKey: device.id)
            btAlignmentNoteViews.removeValue(forKey: device.id)
            if mountedSyncDrawerID == device.id {
                mountedSyncDrawerID = nil
                syncDrawer.removeFromSuperview()
            }
        }
        if section.title == Self.bluetoothSubsectionTitle {
            renderedBluetoothOrder = []
            renderedBTConnectShown = false
            bluetoothConnectButton = nil
        }
    }

    /// The Bluetooth subsection's rows, recency-ordered (BT-UI ghost
    /// pairings): most-recently-used pairing first, so a years-dead ghost
    /// sinks to the BOTTOM — sort only, nothing hidden in v1. A device with
    /// no known `lastUsed` sorts below every dated one; name (then id) breaks
    /// ties deterministically.
    func orderedBluetoothDevices(in devices: [Device]) -> [Device] {
        let lastUsed = btLastUsedProvider?() ?? [:]
        return devices.filter(\.isBluetooth).sorted { byBTRecency($0, $1, lastUsed: lastUsed) }
    }

    /// The Bluetooth recency comparator, shared by the subsection's row order
    /// and the "+" menu's unlisted-pairings Connect section (BT-LIST): a device
    /// with no known `lastUsed` sorts below every dated one; name (then id)
    /// breaks ties deterministically.
    private func byBTRecency(_ a: Device, _ b: Device, lastUsed: [String: Date]) -> Bool {
        let ua = lastUsed[a.id] ?? .distantPast
        let ub = lastUsed[b.id] ?? .distantPast
        if ua != ub { return ua > ub }
        return (a.name, a.id) < (b.name, b.id)
    }

    // MARK: Collapse-default policy (T-5, PLAN §B)

    /// The three card titles — Warm Signal §5.1's silkscreen vocabulary
    /// ("System Audio" / "Output Speakers" / "App Routing"; the panel renders as-is
    /// the displayed header, the title-case copy lives here). Named constants
    /// because the title string IS the card's lookup/collapse key. The System
    /// Audio card was "Main Audio" pre-v4 (§Call-1 renamed the SECTION header to
    /// "System Audio"; the ROW inside it is now titled "Main Audio").
    static let mainAudioCardTitle = "System Audio"
    static let outputDevicesCardTitle = "Output Speakers"
    /// Hover help for the Output Devices card's "Source" column legend.
    static let sourceColumnHelp =
        "What each speaker is playing. System is your Mac's audio. "
        + "An app name means only that app is sent to this speaker."
    /// Hover help for the same card's "Offset" column legend.
    static let offsetColumnHelp =
        "Shifts a speaker's timing so it plays in step with the others. "
        + "Not set means it has never been tuned."
    /// The first-run hint on the Output Devices card: the Mixer's rows are all
    /// affordances and none of them says so.
    static let membershipHintText =
        "Click a speaker's name to play your audio on it. Click it again to stop."
    /// The Applications card's title, so its default is keyed identically to
    /// every other card even though the card itself isn't built yet (T-8).
    static let applicationsCardTitle = "App Routing"

    /// Warm Signal §5.9's locked empty-state copy for the Applications card.
    static let applicationsEmptyPlaceholderText =
        "Route one app somewhere else — music to the house, calls on your Mac. Use + to pick an app."

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
    /// still on the neutral "Follows main output" default, since the user added it on
    /// purpose. Exposed so the card-wiring only needs `collapsedState(for:
    /// Self.applicationsCardTitle, default: !applicationsDefaultExpanded)`.
    private var applicationsDefaultExpanded: Bool {
        !appRouting.appRoutes.isEmpty
    }

    /// Chevron/title click handler for a card (T-4 affordance): flips the
    /// TRANSIENT collapse state (never the default) and drives the panel's own
    /// collapse/expand — no `rebuild()` here, so no OTHER card's transient
    /// state or mounted view is disturbed by this click.
    func toggleCard(_ title: String, animated: Bool = true) {
        let next = !(transientCollapsed[title] ?? false)
        transientCollapsed[title] = next
        panel.setCardCollapsed(title: title, collapsed: next, animated: animated)
    }

    /// Repaint the Applications card when the routing table gained or lost a
    /// route under the popover rather than through it — the phone's add and
    /// remove, which reach `AppRoutingController` through the companion
    /// dispatcher and used to leave the card painting a stale list until the
    /// next open re-read it.
    ///
    /// MEMBERSHIP ONLY, and that is the whole safety of it. `onRoutesDidChange`
    /// is source-blind: it also fires for the popover's OWN continuous volume
    /// drag, once per tick (`AppRowView`'s slider is `isContinuous`), and a
    /// `rebuild()` there would replace the `AppRowView` under the mouse and
    /// break the NSSlider tracking loop — the invariant
    /// `appRow(_:didSetVolume:for:)` documents and deliberately protects. A
    /// volume or destination write never changes which rows exist, so keying
    /// off the rendered row set skips every one of those without needing to
    /// know where the mutation came from.
    ///
    /// Closed is a no-op: every open runs `rebuildForOpen()`, which re-reads
    /// the table anyway (audit B8 — a closed popover never rebuilds).
    ///
    /// A phone-driven VOLUME or DESTINATION change still doesn't repaint the
    /// Mac's row live; that is pre-existing and unchanged here, and fixing it
    /// needs an in-place `AppRowView.apply` sweep rather than a rebuild.
    public func refreshAppRoutes() {
        guard isEffectivelyShown else { return }
        guard Set(appRouting.appRoutes.map(\.bundleID)) != Set(appRowsByBundleID.keys) else { return }
        rebuild()
    }

    /// Repaint every device row's membership state in place, for the changes
    /// that reach the model WITHOUT a backend echo behind them.
    ///
    /// `update(devices:)` is how a row normally learns anything, and it rides
    /// a `BackendEvent`. But `GroupController.setDeviceSelected` only calls
    /// `applyRouting()` — the sole path that can produce an event — while Main
    /// Out targets Selected Devices. With a GROUP as the target it mutates
    /// `selectedDeviceIDs` and announces `onStateDidChange` alone, so a phone
    /// toggling a speaker left the checkbox stale with nothing on the way to
    /// correct it. Group edits reach the rows the same way (the rail's dormant
    /// dimming is derived from the active target's membership).
    ///
    /// The caller gates this on the selection or the groups having actually
    /// changed — `refreshMainOutMaster` documents why the full sweep must not
    /// ride every `onStateDidChange` (it would re-run the energize reconcile
    /// and the rail extents on every tick of a volume-key hold).
    public func refreshDeviceMembership() {
        guard isEffectivelyShown else { return }
        refreshDeviceRows()
    }

    // MARK: Main Out row

    func refreshMainOutRow() {
        guard let controller = groupController else { return }
        // "Selected Speakers" is CLEAN — no live "(n)" count (Warm Signal §5.1,
        // decision m: the dropdown names the current target, the device rows'
        // checkboxes already show the composition). The trailing-control column
        // (`PopoverColumnGrid.trailingControlWidth`) is sized so the full title
        // fits the collapsed button untruncated — no `buttonTitle` short form.
        var options: [MainOutRowView.Option] = [
            .init(title: "Destination", isHeader: true),
            .init(title: "Selected Speakers", target: .selectedDevices),
        ]
        // Only groups that actually have a device are offered as routing targets —
        // an empty group can't be activated (and shouldn't exist under the
        // membership invariant, but a group left empty by an older build is
        // filtered here defensively rather than shown as a dead entry).
        let routableGroups = controller.groups.filter { !$0.memberIDs.isEmpty }
        if !routableGroups.isEmpty {
            options.append(.init(title: "Scenes", isHeader: true))
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
                         localOnlyArmed: mainOutIsLocalOnlyArmed(controller),
                         // S5 (spec §4.7 FINAL): the bus origin stub dims only
                         // under a GENUINELY-DIVERGING group target — in the
                         // derived-identity case the whole bus (origin included)
                         // keeps full emphasis, the dropdown title carrying the
                         // group identity.
                         busOriginDimmed: devicesCardDivergence() != nil)
        refreshCardHeaderLiveness()
    }

    /// Push each card title's "is this section sounding" state into the panel
    /// (iOS Section Header rule: a sounding section's title reads `goldText`).
    /// The three predicates are computed HERE, from this controller's own
    /// model — the same inputs the rows render from — never read back off a
    /// row, so the title and the rows below it can never disagree.
    ///
    /// With no `groupController` the main-mix terms are all false and only a
    /// live app feed can arm a device row, which is exactly what the
    /// no-controller branch of `applySelectionState` renders.
    func refreshCardHeaderLiveness() {
        let controller = groupController
        let mainOutSounding: Bool = {
            guard let controller else { return false }
            if case .connected = mainOutConnectionState(controller), !controller.isMainOutMuted {
                return true
            }
            return mainOutIsLocalOnlyArmed(controller)
        }()
        let anyDeviceSounding = deviceRowsByID.keys.contains { id in
            guard let device = devicesByID[id] else { return false }
            if !(liveRoutedAppNames[id] ?? []).isEmpty { return true }
            guard let controller, controller.isMainOutMember(id) else { return false }
            guard case .connected = device.connectionState else { return false }
            return !(device.isMuted || controller.isMuted(id)) && !controller.isMainOutMuted
        }
        let anyRouteSounding = appRouting.appRoutes.contains { route in
            !isAppExcluded(route.bundleID)
                && route.destination != .noRedirect
                && !offlineBundleIDs.contains(route.bundleID)
        }
        panel.setCardHeaderLive(title: Self.mainAudioCardTitle, live: mainOutSounding)
        panel.setCardHeaderLive(title: Self.outputDevicesCardTitle, live: anyDeviceSounding)
        panel.setCardHeaderLive(title: Self.applicationsCardTitle, live: anyRouteSounding)
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
    func beginEnergize(to target: MainOutTarget) {
        guard let controller = groupController else { return }
        energizeTargetName = energizeTargetDisplayName(target, controller: controller)
        // Announce the transition FIRST — the spoken equivalent of the visual
        // drop-to-pending is an accessibility affordance, independent of the
        // motion setting: a VoiceOver user with Reduce Motion on still hears the
        // switch even though the sweep isn't drawn.
        postAnnouncement("Switching Main Audio to \(energizeTargetName ?? "the new source")")
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
    func reconcileEnergize() {
        guard energizeActive else { return }
        energizePendingIDs = energizePendingIDs.filter { isPreConnect($0) }
        guard energizeTargetSettled() else { return }
        energizeActive = false
        energizePendingIDs = []
        let (connected, failed) = energizeTargetTally()
        var summary = "\(energizeTargetName ?? "Main Audio") ready"
        if connected > 0 { summary += ", \(connected) connected" }
        if failed > 0 { summary += ", \(failed) didn’t connect" }
        postAnnouncement(summary)
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
        case .selectedDevices: return "Selected Speakers"
        case .group(let id):   return controller.groups.first { $0.id == id }?.name ?? "the scene"
        }
    }

    /// Post a VoiceOver announcement for a Main-Audio milestone — the energize
    /// transition/settle, or the live-removal offer — and record it for the
    /// deterministic test seam. These states have no other spoken form. High
    /// priority so it isn't dropped mid-scan. No-op-safe headlessly (the post
    /// simply reaches no AT).
    func postAnnouncement(_ message: String) {
        lastEnergizeAnnouncement = message
        NSAccessibility.post(
            element: panel.view,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    // MARK: Live-removal undo (the "Removed — Undo" offer)

    /// Whether unchecking `id` right now would silence a room that is AUDIBLE
    /// this instant — the only case that earns the transient undo. All three
    /// terms are read before the edit:
    ///
    ///   liveRemoval = isMainOutMember(id) ∧ id is `.connected`
    ///               ∧ the Main Audio spine is armed
    ///
    /// The spine term is `MainOutRowView`'s own `isSpineLive` recipe (a
    /// connected, unmuted target — or the local-only resting case, where audio
    /// genuinely plays with no AirPlay handshake to report). An idle removal
    /// gets nothing: no pill, no timer, no announcement.
    private func isLiveMainAudioRemoval(_ id: String) -> Bool {
        guard let controller = groupController, controller.isMainOutMember(id) else { return false }
        guard case .connected = devicesByID[id]?.connectionState else { return false }
        if case .connected = mainOutConnectionState(controller), !controller.isMainOutMuted {
            return true
        }
        return mainOutIsLocalOnlyArmed(controller)
    }

    /// Raise the offer on `id` and start its 5 s retirement timer. The pill's
    /// spoken equivalent goes out on the same channel the energize milestones
    /// use — the visual has no other spoken form.
    private func offerRemovalUndo(for id: String) {
        removalUndoTimer?.invalidate()
        removalUndoDeviceID = id
        postAnnouncement("Removed \(devicesByID[id]?.name ?? "speaker") from Main Audio")
        removalUndoTimer = Timer.scheduledTimer(withTimeInterval: Self.removalUndoWindow,
                                                repeats: false) { [weak self] _ in
            self?.expireRemovalUndo()
        }
    }

    /// The timer's end of the offer: drop it, then repaint so the pill goes.
    func expireRemovalUndo() {
        guard removalUndoDeviceID != nil else { return }
        clearRemovalUndo()
        refreshDeviceRows()
    }

    /// Drop the offer without repainting — for callers that repaint anyway (a
    /// membership edit) or that are tearing the surface down.
    func clearRemovalUndo() {
        removalUndoTimer?.invalidate()
        removalUndoTimer = nil
        removalUndoDeviceID = nil
    }

    /// Raise (or re-arm) the Cast feed-gain pending fill on `id`'s fader after
    /// a volume/mute gesture, for the measured stream lag. A continuous drag
    /// re-arms the timer on every tick, so `refreshDeviceRows()` only runs on
    /// the id's FIRST insertion, not every re-arm.
    private func raiseCastVolumePending(for id: String) {
        guard let device = devicesByID[id], device.isCast,
              let lag = device.castVolumeLagSeconds,
              device.connectionState == .connected else {
            // Which guard refused — the fact the next live diagnosis needs.
            if let d = devicesByID[id], d.isCast {
                Telemetry.log(.cast, "cast_pending_refused", [
                    "device": id,
                    "lag": d.castVolumeLagSeconds.map(String.init) ?? "nil",
                    "state": String(describing: d.connectionState),
                ])
            }
            return
        }
        Telemetry.log(.cast, "cast_pending_raised", ["device": id, "lag": String(lag)])
        castVolumePendingTimers[id]?.invalidate()
        castVolumePendingTimers[id] = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, lag)),
                                                            repeats: false) { [weak self] _ in
            self?.expireCastVolumePending(for: id)
        }
        if castVolumePendingIDs.insert(id).inserted {
            refreshDeviceRows()
        }
    }

    /// The timer's end of the pending fill: drop it, then repaint so the
    /// fader returns to gold.
    func expireCastVolumePending(for id: String) {
        castVolumePendingIDs.remove(id)
        castVolumePendingTimers[id]?.invalidate()
        castVolumePendingTimers[id] = nil
        refreshDeviceRows()
    }

    /// Live Reduce Motion value, overridable for headless determinism.
    var reduceMotionActive: Bool {
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

    /// The rail's ARMED predicate for local playback (separate from
    /// `mainOutConnectionState` above — which stays untouched): true iff the
    /// local device is AMONG the active target's members and the master is
    /// unmuted. This is exactly the case where audio is genuinely playing
    /// (locally, through the Mac) but there's no remote AirPlay handshake for
    /// `mainOutConnectionState` to report, so it correctly falls through to
    /// `.off` while the wire — and the ring it lands on — must still read gold.
    /// Whether that ring is drawn at ALL is a different question, answered by
    /// the rail's own reach (`updateRailRows`).
    ///
    /// AMONG, not "all of": the mixed set {local, AirPlay…} is reachable
    /// (`GroupController.setDeviceSelected` auto-swaps the Mac out only when it
    /// is the SOLE member), and the Mac keeps rendering audio in it. Requiring
    /// every member to be local dropped the wire to its idle tone for the whole
    /// time a speaker sat selected-but-not-connected beside the Mac, while the
    /// Mac was audibly playing. When a member does connect,
    /// `mainOutConnectionState` reports `.connected` and the armed term above
    /// covers it regardless of what this returns.
    private func mainOutIsLocalOnlyArmed(_ controller: GroupController) -> Bool {
        let memberIDs: [String]
        switch controller.mainOut {
        case .selectedDevices: memberIDs = Array(controller.selectedDeviceIDs)
        case .group(let id):   memberIDs = controller.groups.first { $0.id == id }?.memberIDs ?? []
        }
        // The fallback is the same condition arriving from the other side: the
        // engine is playing through the Mac even though the Mac is not in the
        // target set, so the wire into its row — and the ring above it — read
        // gold for as long as the banner stands.
        guard localFallbackActive
                || memberIDs.contains(where: { devicesByID[$0]?.isLocalDevice == true })
        else { return false }
        return !controller.isMainOutMuted
    }

    /// The collapsed destination-button label for the "Selected Speakers" target:
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
                                 showsMeter: true, showsBus: true,
                                 // Roadmap 056 Part 1: the Mac's own output is
                                 // a trimmable device too, and gets the identical
                                 // chip/drawer/wizard surface. CAST-SYNC adds
                                 // Cast rows — chip and drawer, no wizard.
                                 showsSyncControls: isTrimmable(device))
        view.delegate = self
        applySelectionState(to: view, device: device)
        deviceRowsByID[device.id] = view
        return view
    }

    /// The saved groups resolved against the current fleet — what turns a
    /// `.group` app route into the speakers whose FEED column names that app.
    /// Recomputed per read rather than cached: it is a small pure fold over
    /// state that several unrelated paths mutate, and a stale copy would show a
    /// speaker feeding an app it no longer carries.
    /// App display name → the saved group whose membership carries it, for
    /// every app currently on a `.group` route. Feeds the device rows' spoken
    /// FEED clause ("Safari, through Kitchen"), which is the only place the
    /// difference between a group route and a direct one is stated.
    private func appRouteGroupNames() -> [String: String] {
        guard let controller = groupController else { return [:] }
        var names: [String: String] = [:]
        for route in appRouting.appRoutes {
            if case .group(let groupID) = route.destination,
               let group = controller.groups.first(where: { $0.id == groupID }) {
                names[route.displayName] = group.name
            }
        }
        return names
    }

    private func groupRouteTargets() -> [String: GroupRouteTarget] {
        guard let controller = groupController else { return [:] }
        return AppRoutingController.resolveGroupTargets(
            controller.groups, devices: Array(devicesByID.values))
    }

    /// Whether an app route currently redirects to this device — the canonical
    /// `isRedirectTarget` source (backs `controllable` and the Q4 retry path).
    private func isRedirectTarget(_ id: String) -> Bool {
        !appRouting.routedAppNames(for: id, groupTargets: groupRouteTargets()).isEmpty
    }

    /// The Devices card's genuinely-DIVERGING dormant state (spec §4.7 FINAL
    /// semantics, S5 — replaces the transitional "any group target dims
    /// everything" treatment): non-`nil` only when Audio Out targets a saved
    /// group AND the checked (Selected Devices) set does NOT equal that group's
    /// member set.
    struct DevicesCardDivergence {
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
    func devicesCardDivergence() -> DevicesCardDivergence? {
        guard let controller = groupController,
              case .group(let id) = controller.mainOut else { return nil }
        guard let group = controller.groups.first(where: { $0.id == id }) else {
            return DevicesCardDivergence(groupName: "a scene", targetMemberIDs: [])
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

    /// Whether the LAST `rebuild()` rendered the first-run membership hint —
    /// the hint's twin of `renderedDevicesCardNote`, for the same reason.
    private var renderedMembershipHint = false

    /// Whether the Devices card should currently carry the first-run hint: the
    /// host still owes it, no dormancy note is taking the same slot, and there
    /// is at least one speaker row besides the Mac to click.
    private func membershipHintShouldShow(sections: [DeviceSection]) -> Bool {
        guard membershipHintShownProvider?() == true else { return false }
        guard devicesCardNoteText() == nil else { return false }
        return sections.contains { $0.title != Self.thisMacSubsectionTitle && !$0.devices.isEmpty }
    }

    /// In-place device-section repaint that escalates to a full `rebuild()` when
    /// the Devices card's dormancy note must appear/disappear/rename (a card-note
    /// change is structural — only `rebuild()` mounts/unmounts it). Everything
    /// else stays the cheap `refreshDeviceRows()` + `refreshMainOutRow()` path.
    func refreshDeviceRowsReconcilingCardNote() {
        if devicesCardNoteText() != renderedDevicesCardNote
            || membershipHintShouldShow(sections: deviceSections()) != renderedMembershipHint {
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
    func applySelectionState(to row: DeviceRowView, device: Device) {
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
                      routedAppNames: appRouting.routedAppNames(for: device.id,
                                                              groupTargets: groupRouteTargets()),
                      liveAppNames: liveRoutedAppNames[device.id] ?? [],
                      appRouteGroupNames: appRouteGroupNames(),
                      mainOutTargetsGroupName: activeMainOutGroupName,
                      energizePending: energizePendingIDs.contains(device.id),
                      iconSymbolName: deviceIconController?.symbolName(for: device),
                      syncTrimMs: btSyncTrim(for: device),
                      syncTrimIsSet: btSyncTrimIsSet(for: device),
                      syncMeasuredLatencyMs: (device.isBluetooth || device.isWired) ? btMeasuredLatency(for: device.id) : nil,
                      alignmentSource: btOffsetSourceProvider?(device.id),
                      movedSinceLastTimeMs: btMovedNoticeMsByID[device.id],
                      syncDrawerExpanded: expandedSyncDeviceID == device.id,
                      isEQShaped: deviceEQIsShaped?(device.id) ?? false)
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
        // T-UI-ALLOW: the Phase-1 local-mix block is gone — the Mac row's
        // select-ability gate went with it (T-GROUPCTL / Q5, synced local sink),
        // so the Mac row is never blocked/greyed any more. This no longer computes
        // or passes `blocked`/`blockReason` to the row (both default to
        // false/nil in `DeviceRowView.apply`, which is exactly the always-un-blocked
        // behavior this now produces).
        // Route-armed inputs (spec §3.3, S2): membership against the ACTIVE Main
        // Out target is `isMainOutMember` — the Selected set when Main Out
        // targets Selected Devices, the group's member set when it targets a
        // saved group (so a playing group member lights its dot even while its
        // Selected checkbox dims in the dormant card). The SAME predicate drives
        // `controllable:` below: a playing group member's slider and mute stay
        // live, while a device stranded in the dormant Selected set — which Main
        // Out sends nothing to — does not. Master mute is folded in so it drains
        // every device dot.
        let inActiveTarget = controller.isMainOutMember(device.id)
        row.apply(device,
                  selected: selected,
                  controllable: controller.isMainOutMember(device.id) || isRedirectTarget(device.id),
                  selectionDimmed: dimmed,
                  routedAppNames: appRouting.routedAppNames(for: device.id,
                                                              groupTargets: groupRouteTargets()),
                  liveAppNames: liveRoutedAppNames[device.id] ?? [],
                  appRouteGroupNames: appRouteGroupNames(),
                  masterMuted: controller.isMainOutMuted,
                  inActiveTarget: inActiveTarget,
                  mainOutTargetsGroupName: activeMainOutGroupName,
                  energizePending: energizePendingIDs.contains(device.id),
                  iconSymbolName: deviceIconController?.symbolName(for: device),
                  syncTrimMs: btSyncTrim(for: device),
                  syncTrimIsSet: btSyncTrimIsSet(for: device),
                  syncMeasuredLatencyMs: (device.isBluetooth || device.isWired) ? btMeasuredLatency(for: device.id) : nil,
                  alignmentSource: btOffsetSourceProvider?(device.id),
                  movedSinceLastTimeMs: btMovedNoticeMsByID[device.id],
                  syncDrawerExpanded: expandedSyncDeviceID == device.id,
                  // The offer stands only while the device is genuinely OUT —
                  // re-joining the mix (undo, or a re-select from anywhere)
                  // withdraws it without needing its own edge to watch.
                  removalUndoOffered: removalUndoDeviceID == device.id && !selected,
                  // A stale id (device no longer Cast/lagged) renders nothing;
                  // its own timer self-expires it — no pruning machinery needed.
                  volumePendingApply: castVolumePendingIDs.contains(device.id)
                      && device.castVolumeLagSeconds != nil
                      && device.connectionState == .connected,
                  isEQShaped: deviceEQIsShaped?(device.id) ?? false,
                  // The Mac's row draws as a rail member while the engine is
                  // falling back to it, so the wire shows where audio actually
                  // comes out. Nothing about the selection changes.
                  localFallbackOutput: localFallbackActive && device.isLocalDevice)
    }

    /// A trimmable row's current Sync trim: the session cache first (the
    /// user's freshest edit), else the persisted value — via `btTrimProvider`
    /// for a Bluetooth row, `localTrimProvider` for the Mac's own,
    /// `castOffsetProvider` for a Cast receiver. Rows with no Sync chip
    /// short-circuit to 0 (they ignore the value anyway).
    func btSyncTrim(for device: Device) -> Double {
        guard isTrimmable(device) else { return 0 }
        if let cached = btTrimsByID[device.id] { return cached }
        let persisted: Double
        let isSet: Bool
        if device.isLocalDevice {
            persisted = localTrimProvider?() ?? 0
            isSet = localTrimIsSetProvider?() ?? false
        } else if device.isCast {
            persisted = castOffsetProvider?(device.id) ?? 0
            isSet = castOffsetIsSetProvider?(device.id) == true
        } else {
            persisted = btTrimProvider?(device.id) ?? 0
            isSet = btTrimIsSetProvider?(device.id) == true
        }
        btTrimsByID[device.id] = persisted
        if isSet { btTunedDeviceIDs.insert(device.id) }
        return persisted
    }

    /// Which rows carry the SYNC chip and drawer: every Bluetooth speaker, the
    /// Mac's own output (roadmap 056), every wired output, and every Cast
    /// receiver (CAST-SYNC). AirPlay rows still carry none, by locked
    /// Decision 1 — their timing is the reference everything else is aligned
    /// to.
    func isTrimmable(_ device: Device) -> Bool {
        device.isBluetooth || device.isLocalDevice || device.isCast || device.isWired
    }

    /// A Bluetooth row's MEASURED latency (roadmap 056 Part A): the session
    /// cache first (the freshest run's result), else the persisted value.
    /// `nil` — never measured — is what the tooltip leaves unsaid.
    func btMeasuredLatency(for deviceID: String) -> Double? {
        if let cached = btLatenciesByID[deviceID] { return cached }
        guard let measured = btLatencyProvider?(deviceID) else { return nil }
        btLatenciesByID[deviceID] = measured
        return measured
    }

    /// Whether this device has been tuned at all (D10 — "Not set" otherwise).
    /// Reads the trim first so both caches seed together on a row's first paint.
    func btSyncTrimIsSet(for device: Device) -> Bool {
        guard isTrimmable(device) else { return false }
        _ = btSyncTrim(for: device)
        return btTunedDeviceIDs.contains(device.id)
    }

    /// What the wizard's iPhone panel says — asked of the app layer, which is
    /// the only place that can see the Allow switch and the companion
    /// server's clients. Unset (a headless build, the harnesses) reads as
    /// "Allow is on, no phone here", the state that shows the code.
    public var remoteInviteStateProvider:
        (() -> BTAlignmentWizardView.RemoteInviteState)?

    /// Where a speaker's applied offset came from, asked of the app layer on
    /// every push. Unset until T14 publishes a source, and the drawer's
    /// caption line is then empty and still reserved.
    public var btOffsetSourceProvider: ((String) -> BTOffsetSource?)?

    /// The over-40 ms notice, per device. Session state, exactly like the
    /// first-join note: the drawer closing clears it and nothing is written
    /// down. T14's apply path is what puts a number in here.
    var btMovedNoticeMsByID: [String: Double] = [:]

    // MARK: Output Devices "+" menu (BT-UI / BT-LIST)

    /// Build the "+" affordance's menu FRESH per presentation — two items
    /// dispatching through real `NSMenuItem` target/action (tests drive them
    /// via `NSMenu.performActionForItem(at:)`, never a bypass seam):
    /// "Save Selected Speakers as scene" (enabled iff `canSaveCurrentSetup`),
    /// "Pair a Bluetooth speaker…" (device-tier decision 3 — never-paired
    /// speakers get NO rows; pairing is a one-tap Settings trip), and — the
    /// BT-LIST connected-only list's history surface — one "Connect '<name>'"
    /// item per paired-but-unlisted Bluetooth device.
    func makeOutputDevicesPlusMenu() -> NSMenu {
        let menu = NSMenu(title: "Add")
        menu.autoenablesItems = false
        let save = NSMenuItem(title: "Save Selected Speakers as scene",
                              action: #selector(plusMenuSaveGroup(_:)), keyEquivalent: "")
        save.target = self
        save.isEnabled = canSaveCurrentSetup
        menu.addItem(save)
        let pair = NSMenuItem(title: "Pair a Bluetooth speaker…",
                              action: #selector(plusMenuPairBluetooth(_:)), keyEquivalent: "")
        pair.target = self
        menu.addItem(pair)
        // Connect items for the pairing HISTORY the list no longer shows (BT-LIST):
        // every known-but-unlisted BT device, most recent first — the same
        // membership-free reconnect a greyed row's click fires, so the attempt
        // surfaces as a live `.connecting` row and resolves to connected or failed.
        let lastUsed = btLastUsedProvider?() ?? [:]
        let unlisted = devicesByID.values
            .filter { $0.isBluetooth && !isBluetoothRowListed($0) && !hiddenSpeakers.isHidden($0.id) }
            .sorted { byBTRecency($0, $1, lastUsed: lastUsed) }
        if !unlisted.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Bluetooth pairings", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for device in unlisted {
                let item = NSMenuItem(title: "Connect '\(device.name)'",
                                      action: #selector(menuConnectBluetoothDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.id
                menu.addItem(item)
            }
        }
        // The way back for the footer "−": every hidden speaker still in the
        // discovery snapshot, one "Show" item each. A hidden speaker not
        // currently discovered has no row to restore, so it isn't offered —
        // its id stays in the store and it reappears here when it's back on
        // the network. A hidden BT pairing lands here (as "Show"), never in
        // the "Bluetooth pairings" connect list above, so one device never
        // gets two items.
        let hidden = devicesByID.values
            .filter { !$0.isLocalDevice && hiddenSpeakers.isHidden($0.id) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        if !hidden.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Hidden speakers", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for device in hidden {
                let item = NSMenuItem(title: "Show '\(device.name)'",
                                      action: #selector(menuShowSpeaker(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.id
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Build the "−" affordance's menu FRESH per presentation: one "Hide"
    /// item per shown non-Mac speaker, in the list's own rendered order. A
    /// speaker that is currently SELECTED (playing in the broadcast) is
    /// disabled — deselect first, then hide (owner's call, 2026-09-15) — so
    /// hiding can never take a playing speaker off screen.
    func makeOutputDevicesMinusMenu() -> NSMenu {
        let menu = NSMenu(title: "Hide")
        menu.autoenablesItems = false
        let shown = deviceSections()
            .filter { $0.title != Self.thisMacSubsectionTitle }
            .flatMap(\.devices)
        for device in shown {
            let selected = groupController?.isSpeakerSelected(device.id) ?? false
            let item = NSMenuItem(title: "Hide '\(device.name)'",
                                  action: #selector(menuHideSpeaker(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.isEnabled = !selected
            if selected { item.toolTip = "Playing now — turn it off first to hide it." }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuHideSpeaker(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let device = devicesByID[id], !device.isLocalDevice,
              !(groupController?.isSpeakerSelected(id) ?? false) else { return }
        hiddenSpeakers.hide(deviceID: id)
        Analytics.capture("mixer:speaker_hidden", ["kind": device.kind.rawValue])
        rebuild()
        panel.panelContentDidChangeHeight(animated: true)
    }

    @objc private func menuShowSpeaker(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              hiddenSpeakers.isHidden(id) else { return }
        hiddenSpeakers.show(deviceID: id)
        Analytics.capture("mixer:speaker_shown", ["kind": devicesByID[id]?.kind.rawValue ?? "unknown"])
        rebuild()
        panel.panelContentDidChangeHeight(animated: true)
    }

    @objc private func plusMenuSaveGroup(_ sender: Any?) { saveCurrentSetup() }
    @objc private func plusMenuPairBluetooth(_ sender: Any?) { onPairBluetoothSpeaker?() }
    @objc private func menuConnectBluetoothDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // List the row BEFORE the attempt so the outcome has somewhere to land.
        btConnectAttemptIDs.insert(id)
        groupController?.requestReconnect(for: id)
        rebuild()
        panel.panelContentDidChangeHeight(animated: true)
    }

    /// The footer "+"'s click: pop the menu off the footer strip, the same way
    /// the Applications "+" pops its picker. The actual on-screen pop is gated
    /// on `HeadlessRuntime.isActive` (house rule — a blocking `popUp` under
    /// `swift test` would also hang the runner); headless callers assert via
    /// `test_outputDevicesPlusMenu()` instead.
    private func presentOutputDevicesPlusMenu() {
        guard !HeadlessRuntime.isActive else { return }
        makeOutputDevicesPlusMenu().popUp(
            positioning: nil, at: NSPoint(x: 0, y: devicesFooter.bounds.height), in: devicesFooter)
    }

    /// The footer "−"'s click: same pop as the "+", headless-gated the same
    /// way; headless callers assert via `test_outputDevicesMinusMenu()`.
    func presentOutputDevicesMinusMenu() {
        guard !HeadlessRuntime.isActive else { return }
        makeOutputDevicesMinusMenu().popUp(
            positioning: nil, at: NSPoint(x: 0, y: devicesFooter.bounds.height), in: devicesFooter)
    }

    /// A non-interactive placeholder body row (V2 Devices empty state / V11
    /// Applications empty state; copy carried by both to the §5.9 spec text
    /// under V9): `text` in a tertiary-label, row-height view whose label
    /// leading edge aligns with the name column (past the icon).
    private func makePlaceholderRow(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Tokens.Font.menuItem
        label.textColor = Tokens.Color.inkTertiary
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        let nameColumnLeading = PopoverColumnGrid.nameColumnLeading
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: DeviceRowView.rowHeight),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: nameColumnLeading),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor,
                                            constant: -PopoverColumnGrid.leadingInset),
            label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        return wrapper
    }

    /// The Bluetooth subsection's empty state (BT-LIST): pairing/connecting is
    /// Apple-owned, so the affordance is the Settings trip — the fresh row then
    /// arrives through the ordinary connected-only listing.
    ///
    /// The row names the ACTION only: the "Bluetooth Speakers" header directly
    /// above it already names the kind, so the word on both lines would make an
    /// empty section say the same thing twice. VoiceOver hears the full phrase
    /// through `accessibilityLabel` — a button announced on its own has no
    /// header to lean on. The header itself stays: it is the collapse key, it
    /// is the shape the AirPlay empty state uses too, and dropping it would
    /// only push "Bluetooth" back down into this row.
    ///
    /// A LINK, never a push button: a bordered pill is the only chrome-drawn
    /// control in a card of borderless rows, which lets an ABSENCE — a section
    /// with nothing in it — pull more eye than the live speakers above it.
    /// Borderless at `menuItem`/secondary puts it in the same voice as
    /// `makePlaceholderRow`'s "no apps" line, one step quieter than a device
    /// name, while staying a real `NSButton` (same action, same focus ring, same
    /// `test_fireBluetoothConnectClick`). Deliberately NOT accent-tinted: gold is
    /// spoken for here — it means "in the mix" — and a gold link in a device list
    /// would claim a membership it doesn't have.
    ///
    /// Leading edge sits on `firstElementLeading(indented: false)` (38.5), the
    /// same x a device row's ICON starts at — not `nameColumnLeading` (73.5),
    /// which is where the NAME starts, one column further in. With no device
    /// rows present under the subsection title to compare against, the deeper
    /// anchor would read as an indent nested inside another indent; the "+"
    /// sits exactly where a device icon would instead.
    private func makeBluetoothConnectRow() -> NSView {
        let button = PointingHandButton(title: "Connect a speaker",
                                        target: self, action: #selector(bluetoothConnectRowClicked(_:)))
        button.setAccessibilityLabel("Connect a Bluetooth speaker")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.controlSize = .small
        // A leading "+" glyph so the row reads as an ACTION rather than a
        // greyed-out placeholder line. `contentTintColor` reliably tints a
        // button's template IMAGE (the comment below covers why the TITLE takes
        // a different route), so the glyph carries the same neutral secondary
        // tone the title does. Filled (`plus.circle.fill`) rather than outlined,
        // for a simpler, more inviting mark.
        button.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.contentTintColor = Tokens.Color.secondaryLabel
        // The title's colour is set through `attributedTitle`, not
        // `contentTintColor` — that property reliably tints a button's template
        // IMAGE, but its effect on a title varies by bezel style. The dynamic
        // token resolves per appearance at draw time (the same way the FEED
        // pills' attributed colours do), so a live light/dark switch follows.
        // The TITLE reads at full `label` while the GLYPH stays `secondaryLabel`
        // — the weight difference between the two carries the row's appeal,
        // instead of a bordered pill.
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.font: Tokens.Font.menuItem,
                         .foregroundColor: Tokens.Color.label])
        bluetoothConnectButton = button
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(button)
        let leading = PopoverColumnGrid.firstElementLeading(indented: false)
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: DeviceRowView.rowHeight),
            button.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: leading),
            button.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        return wrapper
    }

    @objc private func bluetoothConnectRowClicked(_ sender: Any?) { onPairBluetoothSpeaker?() }

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
                // Only a speaker the user asked for is worth an event —
                // selected, a redirect target, or a member of the playing
                // group. The backend fails every speaker it can see, wanted or
                // not, so ungated this bills an install for the whole network's
                // mDNS churn: one install sent 357 `connection:failed` on
                // 2026-09-09, 356 of them `vanished`, in bursts of 16 inside
                // 20 ms, with no user action anywhere near them. `wantsAudio`
                // covers the first two; the group membership is the read it
                // deliberately lacks, and narrowing to it alone would silence a
                // group member that never appears in Selected Devices.
                if case .failed(let failure) = current,
                   wantsAudio(device.id) || (groupController?.isMainOutMember(device.id) ?? false) {
                    Analytics.capture("connection:failed", ["kind": device.kind.rawValue,
                                                              "cause": String(describing: failure.cause)])
                }
                // A fresh `→ .failed` edge is a NEW episode: its auto-expand wins
                // over any prior dismissal, so clear the dismissal record before
                // (re)opening. This is what re-surfaces the panel on a
                // "Try again → fails again" (`.failed → .connecting → .failed`).
                dismissedDiagnosisIDs.remove(device.id)
                openDiagnosisIDs.insert(device.id)
            case .connected, .off:
                // Same gate as the failure above, for the same reason: a
                // speaker nobody asked for is the backend's business.
                if current == .connected && previous != .connected && !device.isLocalDevice
                    && (wantsAudio(device.id) || (groupController?.isMainOutMember(device.id) ?? false)) {
                    Analytics.capture("connection:connected", ["kind": device.kind.rawValue])
                }
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

    /// Whether the user currently intends audio on `id` — a Selected-Devices
    /// member, or an app-redirect target. Deliberately NOT the same predicate
    /// `applySelectionState` uses for `controllable:`: that one is group-aware
    /// (`isMainOutMember`, so a playing group member stays adjustable), while
    /// this still reads the Selected set plus redirect targets.
    func wantsAudio(_ id: String) -> Bool {
        (groupController?.isSpeakerSelected(id) ?? false) || isRedirectTarget(id)
    }

    /// BT-LIST (connected-only): a Bluetooth row renders iff the device can carry
    /// audio right now, the user explicitly asked to connect it while the popover
    /// has been open (`btConnectAttemptIDs`, cleared on close — scoped that way
    /// rather than to "state != .off", because `.failed` is sticky and never
    /// clears for a paired device, so a failed attempt would mint a permanent
    /// unexplained row), or the user still
    /// intends audio on it (Selected Devices, app-redirect, or the active Main Out
    /// group — `isMainOutMember`, the group-aware read `wantsAudio` lacks). The
    /// paired-but-idle history macOS keeps forever stays off screen — the "+"
    /// menu's Connect items are its surface.
    private func isBluetoothRowListed(_ device: Device) -> Bool {
        device.isAvailable
            || btConnectAttemptIDs.contains(device.id)
            || wantsAudio(device.id)
            || (groupController?.isMainOutMember(device.id) ?? false)
    }

    /// Make the mounted panel views match `openDiagnosisIDs`: tear down panels
    /// that should be closed (or whose device/row vanished), refresh the failure
    /// copy on ones staying up (the diagnosis-replacement path), and mount
    /// missing ones under their device row.
    func reconcileDiagnosisPanels(animated: Bool) {
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
        Analytics.capture("connection:diagnosis_shown", ["cause": String(describing: failure.cause)])
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
        Analytics.capture("connection:retry_clicked")
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

    /// Whether the last "Save Selected Speakers as scene" failed to persist —
    /// the headless-observable half of the alert below (hardening 11).
    public var test_saveGroupFailureReported = false

    /// Overrides the live Reduce Motion read for `beginEnergize` (`nil` = use the
    /// real workspace value) so a headless test drives BOTH sides deterministically.
    public var test_reduceMotionOverride: Bool?

}

// MARK: - DeviceRowView.Delegate

extension PopoverController: DeviceRowView.Delegate {

    public func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {
        if volumeAdjustedControls.insert("device").inserted {
            Analytics.capture("mixer:volume_adjusted", ["control": "device"])
        }
        noteSliderGesture()
        groupController?.setMemberVolume(volume, for: id)
        refreshMainOutRow()
        raiseCastVolumePending(for: id)
    }

    public func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {
        Analytics.capture("mixer:device_mute_toggled", ["muted": muted ? "true" : "false"])
        groupController?.setMuted(muted, for: id)
        // A per-device mute may flip the Main Out master to fully-muted or back, so
        // refresh those glyphs live.
        refreshDeviceRows()
        refreshMainOutRow()
        raiseCastVolumePending(for: id)
    }

    public func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
        // Read the "was this room live?" facts BEFORE the edit — after it, the
        // removed device is no longer a member and the spine it was feeding may
        // already have gone quiet.
        let wasLiveRemoval = !on && isLiveMainAudioRemoval(id)
        // Compose the Selected Devices set (SPEC §9b). Does NOT route unless Main
        // Out targets Selected Devices; the model handles the local-mix block +
        // auto-swap and returns a result we present.
        let result = groupController?.setDeviceSelected(id, on) ?? .ok
        var props: [String: String] = [:]
        if let kind = devicesByID[id]?.kind { props["kind"] = kind.rawValue }
        if let transport = devicesByID[id]?.wiredTransport { props["transport"] = transport.rawValue }
        if let reason = result.refusalReason { props["refusal_reason"] = reason }
        Analytics.capture(on ? "mixer:device_selected" : "mixer:device_deselected", props)
        // The first membership toggle made in the Mixer retires the first-run
        // hint. The host flips the stored flag synchronously, so the reconcile
        // inside `handleSelection` below already sees the provider go false.
        if membershipHintShownProvider?() == true {
            onMembershipHintDismissed?()
            Analytics.capture("mixer:membership_hint_dismissed")
        }
        // Any membership edit retires a standing offer; a live removal raises a
        // fresh one. A refused edit changed nothing, so it offers nothing.
        if wasLiveRemoval && result.refusalReason == nil {
            offerRemovalUndo(for: id)
        } else {
            clearRemovalUndo()
        }
        handleSelection(result, deviceID: id)
    }

    /// The user clicked the transient offer: put the membership back through
    /// the checkbox's OWN delegate path, so there is no second re-add
    /// implementation that could diverge from a plain re-check. The membership
    /// change speaks through the existing row plumbing — no extra announcement.
    public func deviceRowDidRequestUndoRemoval(_ row: DeviceRowView) {
        let id = row.device.id
        clearRemovalUndo()
        deviceRow(row, didToggleEnabled: true, for: id)
    }

    /// A greyed Bluetooth row's click (BT-UI "click connects"): a
    /// membership-FREE reconnect kick — `requestReconnect` goes straight to
    /// `OutputBackend.retryOutput`, never editing selection (selecting a
    /// greyed row separately means "play when up" and stays the node/checkbox's
    /// job, exactly like AirPlay rows).
    public func deviceRowDidRequestReconnect(_ row: DeviceRowView) {
        Analytics.capture("mixer:reconnect_requested")
        groupController?.requestReconnect(for: row.device.id)
    }

    /// The row's SYNC value chip (T6's only sync delegate method): the chip is
    /// read-only, so the one gesture it reports is "show/hide my drawer".
    public func deviceRow(_ row: DeviceRowView, didToggleSyncDrawerFor id: String) {
        toggleSyncDrawer(deviceID: id, animated: true)
    }

    /// The row's two direct doors into the guided wizard: the "Align by ear…"
    /// context-menu item, and the untuned Bluetooth chip.
    public func deviceRow(_ row: DeviceRowView,
                          didRequestAlignmentWizardFor id: String,
                          door: BTAlignmentWizardDoor) {
        startBTAlignmentWizard(deviceID: id, door: door)
    }

    /// The row's two Equalizer doors — the button beside mute and the
    /// "Equalizer…" menu item (which the row ICON also pops). Both are deep
    /// links, nothing more: the Mixer edits no tone.
    public func deviceRowDidRequestEqualizer(_ row: DeviceRowView, fromButton: Bool) {
        Analytics.capture("eq:opened", ["door": fromButton ? "row_button" : "menu"])
        onOpenEqualizer?(row.device.id)
    }

    /// Move/stop the single align-by-ear tick (BT-OFFSET-UI): one device at a
    /// time, auto-stopped after ~30 s, and stopped by the popover closing
    /// (the click-away) or by its drawer collapsing. `refreshDeviceRows()`
    /// re-applies every row so the drawer's button reads the live state.
    func setAlignTick(_ id: String?) {
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
        // The button lives in the drawer now (D9), so the drawer is what has
        // to un-light when the 30 s auto-stop fires.
        if let mounted = mountedSyncDrawerID, let device = devicesByID[mounted] {
            pushSyncDrawerState(device)
        }
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
        let targetProp: String
        switch target {
        case .selectedDevices: targetProp = "selected_devices"
        case .group: targetProp = "group"
        }
        Analytics.capture("main_out:target_selected", ["target": targetProp])
        groupController?.setMainOut(target)
        // Item 9: the source switch plays the energize sequence. Raise the
        // pending beat over the (now-current) member states BEFORE `rebuild()`
        // so the fresh rows render the instant drop-to-pending; the live
        // connection progression + `reconcileEnergize()` carry it to rest.
        beginEnergize(to: target)
        rebuild()
    }

    public func mainOutRow(_ row: MainOutRowView, didSetMaster volume: Int) {
        if volumeAdjustedControls.insert("master").inserted {
            Analytics.capture("mixer:volume_adjusted", ["control": "master"])
        }
        noteSliderGesture()
        groupController?.setMainOutMasterVolume(volume)
        refreshDeviceRows()
    }

    public func mainOutRow(_ row: MainOutRowView, didSetMuted muted: Bool) {
        Analytics.capture("main_out:mute_toggled", ["muted": muted ? "true" : "false"])
        groupController?.setMainOutMuted(muted)
        refreshDeviceRows()
        refreshMainOutRow()
    }

    /// Main Audio's "Equalizer…" door, addressed by the ``mainOutEQID``
    /// sentinel because the whole mix has no device id.
    public func mainOutRowDidRequestEqualizer(_ row: MainOutRowView) {
        Analytics.capture("eq:opened", ["door": "main_out_menu"])
        onOpenEqualizer?(Self.mainOutEQID)
    }
}

// MARK: - PointingHandButton

/// A borderless button that says so with the cursor: the same
/// `resetCursorRects` idiom `MainOutRowView` uses over its icon door. Without
/// it the Bluetooth Connect row keeps the arrow cursor over quiet secondary
/// text and reads as a disabled label rather than the one thing in an empty
/// section the user can click.
final class PointingHandButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
