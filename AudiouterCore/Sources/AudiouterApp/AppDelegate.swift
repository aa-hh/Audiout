// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterPopoverUI
import AudiouterWindowUI
import AudiouterSettingsUI
import AudiouterSharedUI
import AudiouterOnboardingUI

/// Writes `message` to `STDERR_FILENO` with a raw `write(2)`, retrying on
/// `EINTR` and otherwise ignoring failures.
///
/// `FileHandle.write(_:)` raises an uncatchable `NSException` (not a Swift
/// error) when the underlying fd is closed or broken — e.g. a dev launch
/// from a terminal whose pipe has gone away. That turns routine logging into
/// a crash. This helper never throws and never raises: a lost log line is
/// acceptable, a crashed logger is not. Shared by `main.swift`'s uncaught
/// exception handler and `AppDelegate.log(_:)`.
func audiouterEmergencyWriteStderr(_ message: String) {
    var bytes = Array(message.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeMutableBytes { buf -> Int in
            write(STDERR_FILENO, buf.baseAddress!.advanced(by: offset), buf.count - offset)
        }
        if written >= 0 {
            offset += written
        } else if errno != EINTR {
            return // Broken/closed fd or other unrecoverable error — drop the log line.
        }
        // EINTR: retry the same write.
    }
}

/// The real per-app-capture process resolver the native backend needs: Core
/// can't import AppKit, so the AppKit layer builds it and supplies it via
/// `makeBackend(resolver:)`. `bundleIDForPID` (`NSRunningApplication`) and
/// `bundlePathForBundleID` (`NSWorkspace`) are the two AppKit-only steps of the
/// resolver's four-layer catch-all attribution (`AudioProcessResolver`'s own doc
/// comment) — everything else (enumerating Core Audio process objects, walking
/// parent pids, reading responsible pids and executable paths) is pure Core
/// Audio + Darwin and lives in `AudioProcessResolver` itself, already wired by
/// its own defaults. A free value (not an instance property) so it can be used
/// in `AppDelegate`'s `backend` property initializer, which runs before `self`
/// exists.
private let audioProcessResolver = AudioProcessResolver(
    enumerator: CoreAudioProcessEnumerator(),
    bundleIDForPID: { pid in
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    },
    bundlePathForBundleID: { bundleID in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    })

/// Owns app lifecycle: activation policy, the status item, the backend, and the
/// event-stream consumer that holds the app's device model.
///
/// The dropdown is a Control-Center-style `NSPopover` (SPEC §9 revised — NSMenu
/// → NSPopover): the status button's action toggles the popover, which hosts the
/// groups + devices panel built by `PopoverController`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The one place that talks to a concrete backend type. Resolved via
    /// `makeBackend()`: explicit arg (none) → `AIRPLAY_BACKEND` env → `.native`.
    /// Everything downstream holds an `OutputBackend`, never a concrete type.
    /// `resolver` threads the real `AudioProcessResolver` (AppKit-backed
    /// `bundleIDForPID`) into the native backend's per-app capture AND
    /// whole-system-exclusion paths.
    private let backend: OutputBackend = makeBackend(resolver: audioProcessResolver)

    /// Owns the status item's `.button` (SPEC §9 / brief §4 — customize ONLY
    /// via `.button`, never the deprecated `.view`/`.title`/`.image`).
    private var statusItemController: StatusItemController!

    /// The popover dropdown (SPEC §9 revised). Owns the `NSPopover` and, via the
    /// injected `GroupController`, all group/master/mute/routing interaction.
    /// Wired with an explicit production `AppRoutingController` so app routes
    /// persist to Application Support (T-11).
    private var popoverController: PopoverController!

    /// UI-agnostic mixer model (groups, master gain, mute) shared
    /// by the menu and the mixer window (T-U4). Built lazily in
    /// `applicationDidFinishLaunching` so it binds to the resolved `backend`.
    private var groupController: GroupController!

    /// The full mixer window (SPEC §9 "Full window", T-U4). Created lazily the
    /// first time "Open Mixer…" is chosen, then reused/focused. Holds the same
    /// `GroupController` as the menu, so both views stay in lockstep.
    private var mixerWindowController: MixerWindowController?

    /// Scalar user preferences (theme, density, …), backed by `UserDefaults`.
    /// The app reads `theme` at launch to apply the appearance override, and the
    /// Settings window writes it back.
    private let settings = AppSettings()

    /// The Settings window (header gear). Lazily built on first open, then
    /// reused/focused — same lifecycle as the mixer window.
    private var settingsWindowController: SettingsWindowController?

    /// The resolved backend kind (same resolution `makeBackend()` used). The
    /// first-run setup flow only presents on `.native` — the sole path that taps
    /// audio in-process and discovers under the app's own identity, so the sole
    /// path that needs the two OS grants.
    private let backendKind = BackendKind.resolved()

    /// The four OS permission seams (audio capture, Local Network, Accessibility,
    /// PTP helper), resolved ONCE from `AIRPLAY_PERMISSIONS` (see
    /// ``PermissionMode``). Default `.system` = the real production probes, so a
    /// plain launch is unchanged; `granted`/`denied` inject simulated seams so
    /// the whole permission flow can be driven without touching real TCC (which
    /// re-pins to the binary on every ad-hoc rebuild — the iteration tax this
    /// knob removes). Threaded into BOTH `SetupModel` construction sites,
    /// `registerPTPHelperIfNeeded()`, and `MediaKeyController` so nothing reads a
    /// real grant behind the simulation's back.
    private let permissionProviders = PermissionMode.resolved().makeProviders()

    /// The first-run onboarding/permission-priming window, retained while open
    /// (first launch, or "Check Permissions…" from Settings ▸ General).
    private var onboardingWindowController: OnboardingWindowController?

    /// The `SetupModel` behind the last-presented onboarding window, kept alive
    /// after the window closes and REUSED by every subsequent automatic
    /// revocation audit (see `auditRequiredPermissionsIfNeeded`) rather than
    /// rebuilding a blank one each time. `SetupModel` never re-probes Local
    /// Network from `.unknown` (that would spring an untouched prompt — see
    /// `SetupModel.auditRequiredPermissions()`'s doc comment), so throwing the
    /// model away between audits would permanently disable Local Network
    /// revocation detection for the rest of the run; reusing it means the
    /// first audit after Local Network was actually engaged (during onboarding,
    /// or a previous audit) can see it change.
    private var permissionAuditModel: SetupModel?

    /// True while an automatic revocation audit's async probes are in flight —
    /// guards against a second `didBecomeActive`/wake firing before the first
    /// audit's Local Network browse resolves.
    private var isAuditingRequiredPermissions = false

    /// Set right after a `.permissionLost` onboarding window is dismissed;
    /// automatic audits are skipped until this elapses. Local Network's status
    /// can read a false "not reachable right now" for reasons that have nothing
    /// to do with the permission (speakers off, Wi-Fi hiccup — see
    /// `PermissionStatus`'s doc comment on why it never reports a hard
    /// `.denied`), so without this a transient blip could reopen the window
    /// again on the very next reactivate/wake and nag the user in a loop. A
    /// real, sustained revocation is still caught on the next audit once the
    /// cooldown elapses.
    private var permissionAuditCooldownUntil: Date?
    private let permissionAuditCooldown: TimeInterval = 30

    /// Bumped every time `presentSetup` actually constructs a NEW controller
    /// (never on the re-front branch). The constructing call captures the
    /// post-increment value into a plain `let` at closure-creation time (no
    /// chicken-egg timing problem, unlike trying to capture `controller`
    /// itself before it exists) and its `onFinished` compares that snapshot
    /// against the live counter before clearing `onboardingWindowController`
    /// — so a finish callback can only ever nil out the reference to the
    /// controller IT belongs to, never a newer one built after it. Defensive
    /// belt-and-suspenders on top of `presentSetup`'s own reentrancy guard
    /// (see that method's doc comment for the bug this whole pair of guards
    /// closes): even if some future caller reintroduces reentrancy, a stale
    /// finish can no longer wipe a live controller's reference out from
    /// under it.
    private var onboardingPresentationGeneration = 0

    /// True once EITHER the launch-time check or the popover-open check
    /// (T4/B3) has auto-presented the friendly `.firstRun` Setup window for
    /// an `.undetermined` audio-capture verdict this session. Both call
    /// sites discover `.undetermined` completely independently of each
    /// other (one at launch, one on click), so a single shared flag — set by
    /// whichever fires first, in ``presentSetupForUndeterminedIfNeeded()`` —
    /// is what stops the other from popping a second window later in the
    /// same session. Never reset: this is a one-shot-per-launch guard, not a
    /// cooldown (see `permissionAuditCooldownUntil` for the separate,
    /// time-based guard against fighting the reactivate/wake audit).
    private var didAutoPresentSetupForUndetermined = false

    /// Detects the system-audio grant ARRIVING mid-session (T6-rev). Retained
    /// for the app's lifetime because the `CFNotificationCenter` registration it
    /// owns holds an unretained pointer back to it — see
    /// ``PermissionStateObserver``'s `deinit`. Armed at launch only when the
    /// grant isn't already in place, and kicked (never polled) by wake, popover
    /// open, and every routing action.
    private let permissionObserver = PermissionStateObserver()

    /// Whether `backend.start()` has run. On first-run native the backend start
    /// (and its Bonjour discovery, which triggers the Local Network prompt) is
    /// DEFERRED until onboarding is dismissed, so the prompt is primed by the
    /// setup screen rather than sprung at launch. Guards against double-start.
    private var backendStarted = false

    /// Per-app routing model (Applications card). Held here (not just handed to
    /// the popover) so the app can enforce the excluded-apps precedence — pruning
    /// a route when its app is excluded.
    private var appRouting: AppRoutingController!

    /// Per-device icon overrides (T-14). One shared instance so an icon edited
    /// in the mixer window's device detail pane reflects immediately in the
    /// menu popover, and vice versa. Persists to Application Support alongside
    /// `GroupStore` (mirrors how `AppRouteStore`/`ExcludedAppsStore` pick their
    /// directory) — `loadPersisted: true` so overrides survive relaunch.
    private let deviceIconController = DeviceIconController(loadPersisted: true)

    /// The excluded-apps denylist (Settings › Audio, "never captured"). Shared
    /// between the Settings window (edits it) and the popover (reads it to hide /
    /// filter excluded apps); the app coordinates the "excluded ⇒ un-routable"
    /// precedence between it and `appRouting`.
    private let excludedApps = ExcludedAppsController(store: ExcludedAppsStore())

    /// The app's device model, kept as a pure function of backend events. Keyed
    /// by `Device.id`. T-U2 reads this to build rows; for now it just backs the
    /// placeholder master-volume value the status symbol tracks.
    private var devicesByID: [String: Device] = [:]

    /// The live per-device CONFIRMED per-app streaming map (`BackendEvent
    /// .routedApps`), mirroring `PopoverController`'s own `liveRoutedAppNames`
    /// bookkeeping — kept here too because the status item's idle/streaming
    /// decision (`MenuBarStatus.isStreaming`) needs it and has no other route
    /// to it (the popover's copy is private). An empty `appNames` clears the
    /// entry for that device, same discipline as the popover's copy.
    private var routedAppNamesByDeviceID: [String: [String]] = [:]

    /// AIRPLAY_DEBUG_LEVELS=1 → log capture RMS ~1/sec (see the `.level` case).
    private let debugLevels = ProcessInfo.processInfo.environment["AIRPLAY_DEBUG_LEVELS"] == "1"
    private var lastLevelLog = Date.distantPast

    /// The task consuming the backend event stream. Cancelled on teardown so the
    /// stream finishes cleanly and we don't leak it past app exit.
    private var eventTask: Task<Void, Never>?

    /// Turns a transport key pressed ON A SPEAKER (`BackendEvent.remoteTransport`)
    /// into a Mac media key so the frontmost player responds. Owns the one-time
    /// Accessibility prompt the feature needs.
    private lazy var mediaKeyController = MediaKeyController(
        remoteControl: permissionProviders.remoteControl)

    /// Control-panel prototype (design review 2026-07-18): route Groups through a
    /// sticky floating `NSPanel` anchored under the menu-bar item instead of a
    /// standalone window, gated by `AIRPLAY_CONTROL_PANEL=1`. Off by default, so
    /// the shipping window path is untouched. See `dev/notes/`.
    private let useControlPanel = ProcessInfo.processInfo.environment["AIRPLAY_CONTROL_PANEL"] == "1"

    /// True while a control-panel session is live (panel opened, not yet closed).
    /// A status-item click during a session re-summons the tucked panel (restore
    /// in place) instead of toggling the popover.
    private var controlPanelSessionActive = false

    /// The ONE shared control-panel shell (control-panel rollout). The Groups,
    /// Settings, and future Setup surfaces unify onto this single sticky floating
    /// `NSPanel` instead of each owning an orphaned window: opening a different
    /// surface swaps its content (`setContent`) rather than stacking a second
    /// window. Created lazily on the first control-panel open, then reused; its
    /// `onClose` "lands home" by re-presenting the popover.
    private var controlPanel: ControlPanelWindowController?

    /// Set once `applicationShouldTerminate` has begun tearing down (C1). A second
    /// Quit while the first is still waiting on `stopAndWait` must not re-enter
    /// `backend.stop()` or reply to `NSApp` a second time — AppKit only expects one
    /// `reply(toApplicationShouldTerminate:)` per terminate request.
    private var isTerminating = false

    /// The "Disconnecting…" indicator shown while the terminate reply is pending
    /// (C1, user-requested). Owned here so it can be closed before the reply fires.
    private var quittingIndicator: QuittingIndicatorPanel?

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: no Dock icon, no app menu (RESOLVED Q1). Set before
        // finishing launch so a Dock icon never even flickers.
        NSApp.setActivationPolicy(.accessory)
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // T1 diagnostic (`AUDIOUTER_TCC_DIAG=1`, off by default): starts a
        // once-per-second raw-bucket poll as early as possible so a fresh
        // `open`-launch is captured before any permission prompt can fire.
        // See `TCCBucketDiagnostic` for what it settles and why.
        TCCBucketDiagnostic.startIfEnabled()

        // Apply the persisted appearance override BEFORE building any UI, so the
        // status item and popover pick it up on first paint (Settings ›
        // Appearance). `.system` is a no-op (`NSApp.appearance = nil`).
        applyAppearance(settings.theme)
        // Seed the accent dial's live token remap (W1, spec §1.3) before any
        // UI paints — the token module defaults to `.fullGold`, so this only
        // matters when the user has dialed it elsewhere. Changes made later in
        // Settings › Appearance apply themselves (the pane writes
        // `Tokens.accentStyle` directly); this is the launch-time read of the
        // persisted choice.
        Tokens.accentStyle = settings.accentStyle

        // Status item first so there's immediate UI feedback that we launched.
        // The button's action toggles the popover (SPEC §9 revised) — EXCEPT while
        // first-run setup is open: setup is the only thing the user should be in
        // until it's done, and it's how they get the window back after clicking
        // away (e.g. to grant a permission in System Settings). So while it's up,
        // the menu-bar click re-fronts Setup instead of opening the popover.
        statusItemController = StatusItemController()
        statusItemController.onButtonClicked = { [weak self] button in
            guard let self else { return }
            if let onboarding = self.onboardingWindowController {
                onboarding.present()
                return
            }
            // Control-panel rollout: while a control-panel session is live, the
            // menu-bar click TOGGLES the shared shell (whatever surface it's
            // hosting) rather than the popover. If the shell is showing, close it
            // (a real close → lands home on the popover, exactly like the ✕/Esc);
            // if it's tucked away after an app-switch, restore it in place. A bare
            // re-show here (the old behavior) could never dismiss the panel, so a
            // click on an already-open panel did nothing.
            if self.useControlPanel, self.controlPanelSessionActive,
               let shell = self.controlPanel {
                if shell.isPanelVisible {
                    shell.performClose()
                } else {
                    shell.show(anchorRect: self.statusAnchorRect())
                }
                return
            }
            // T6-rev: a menu-bar click is a "the user is engaging with the app
            // right now" event, so it's one of the five triggers that re-checks
            // the grant out-of-process. Asynchronous by contract, so it can't
            // change the verdict THIS click reads (that one is still the
            // possibly-stale in-process read below) — it's what makes the NEXT
            // click, or any routing action in between, see the truth.
            self.permissionObserver.kick(source: "popover_open")
            // T4 (B2): a cheap, silent read — NEVER the `.permissionLost` alarm
            // banner, which is reserved for an explicit `.denied` (B1, the
            // reactivate/wake audit). `.undetermined` here typically means the
            // user completed Setup without ever actually granting the tap
            // (Done doesn't require a grant — see `OnboardingViewController`'s
            // Done handler), and a menu-bar click is the user's own explicit
            // decision to use the app — the natural moment to offer the
            // friendly first-run nudge rather than silently opening a popover
            // that can do nothing. `presentSetupForUndeterminedIfNeeded()`
            // one-shot/cooldown-gates the presentation (T4/B3) and reports
            // whether it actually took over, so the popover doesn't ALSO open
            // underneath it in the same click.
            if SystemAudioCaptureTCC.effectiveStatus() == .undetermined,
               self.presentSetupForUndeterminedIfNeeded() {
                return
            }
            self.popoverController.toggle(relativeTo: button)
        }

        // Secondary (right/control) click on the menu-bar icon raises a small menu
        // — the discoverable way to reach Settings, Groups, and Quit in a Dock-less
        // app. A minimal main menu supplies ⌘Q / ⌘, while the app is active.
        statusItemController.secondaryClickMenu = { [weak self] in self?.makeStatusMenu() }
        installMainMenu()

        // The mixer model binds to the resolved backend, then the popover binds
        // to the model. From here the popover drives all group/master/mute/
        // routing math.
        groupController = GroupController(backend: backend)
        // T-BACKEND: NativeBackend needs to know when the Mac is ALSO part of
        // what Main Out points at (not just which AirPlay devices are) to detect
        // "play everywhere" — neither `GroupController.applyRouting` nor
        // `activateGroup` ever hands the local device to `backend.setOutputSet`,
        // so that call alone can't carry this. `isMainOutMember(_:)` is the read
        // that answers it for BOTH Main Out targets; wire it in once, here, right
        // after both are constructed. Deliberately NOT `isSpeakerSelected(_:)`,
        // which sees only the Selected Devices set: under a group target that
        // both fails to arm the sink for a group containing the Mac and arms it
        // for an AirPlay-only group whose Mac is merely still sitting in the
        // untargeted Selected Devices set. For `.selectedDevices` the two are the
        // same read, so this is a group-path-only change.
        // `backend as? NativeBackend` is nil for `MockBackend`/`OwnToneBackend`,
        // matching the `MeteringControlling`/`LatencyConfigurable`
        // optional-capability pattern used below.
        (backend as? NativeBackend)?.selectedDevicesQuery = { [weak self] id in
            self?.groupController?.isMainOutMember(id) ?? false
        }
        // T6-rev: every user action that routes audio funnels into exactly two
        // backend methods (`setOutputSet` / `updateAppRoutes`), and both fire
        // this. Kicking from there rather than from the four `GroupController`
        // call sites is what catches a group activated through `applyRouting`'s
        // group branch, and keeps the check in one place. `kick` returns
        // immediately (it only enqueues an out-of-process resolution), which is
        // required: both chokepoints run on the main thread.
        (backend as? NativeBackend)?.onRoutingAction = { [weak self] in
            self?.permissionObserver.kick(source: "routing_action")
        }

        // Construct the production AppRoutingController explicitly (T-11), using
        // the default store directory so app routes persist to Application Support.
        appRouting = AppRoutingController(store: AppRouteStore())
        // T7: whenever the routing table changes, push it into the backend's per-app
        // capture path (`AppRouteConfiguring.updateAppRoutes`). This is what actually
        // streams a routed app's audio to its own device — replacing the old
        // whole-system-output-set union, which sent the ENTIRE mix to the target and
        // muted the Mac. `AppRoutingController` fires this on the change edge only, so
        // no-op mutations never reach the backend. Fired synchronously from a UI
        // mutation (no lock held) → no deadlock with the backend's internal queues.
        appRouting.onRoutesDidChange = { [weak self] in self?.pushAppRoutesToBackend() }
        // One role per speaker: when Main Out membership changes (a device
        // selected, or a group activated), any per-app redirect still pointed at
        // one of those speakers yields back to "follows main output" — selecting
        // the speaker is the senior action (a receiver holds ONE AirPlay session;
        // the two roles can't share it). `clearRoutes` no-ops when nothing
        // conflicts, so this is cheap on every selection change; its change edge
        // fires `onRoutesDidChange` → `pushAppRoutesToBackend()`, tearing down the
        // now-stale per-app tap. The popover's picker refuses the mirror-image
        // conflict up front (a Main Out member is never offered as a redirect
        // target), so the two directions can never build the overlap.
        groupController.onMainOutMembersChanged = { [weak self] memberIDs in
            self?.appRouting.clearRoutes(toDevices: memberIDs)
        }
        popoverController = PopoverController(appRouting: appRouting)
        popoverController.deviceIconController = deviceIconController
        popoverController.configure(groupController: groupController)
        popoverController.onOpenMixer = { [weak self] in self?.openMixer() }
        popoverController.onOpenSettings = { [weak self] in self?.openSettings() }
        // T6 (takeover status strip, state 1's "Open Login Items…" button): the
        // same `PTPHelperManaging` seam `registerPTPHelperIfNeeded()` already
        // reads, reused rather than standing up a second instance.
        popoverController.onOpenPTPHelperLoginItems = { [weak self] in
            self?.permissionProviders.ptpHelper.openSystemSettingsLoginItems()
        }
        // Wave 3 T5 (routing-blocked warning's "Use Audiouter" button, Q6): the
        // user's own click IS their intent, so re-selecting the public aggregate as
        // the Mac's default output here is the ONLY sanctioned re-select — never
        // programmatic (Q2). No-op on backends without the aggregate
        // (`MockBackend`/`OwnToneBackend`), matching the other `NativeBackend`-only
        // capability hooks above.
        popoverController.onReselectAudiouter = { [weak self] in
            (self?.backend as? NativeBackend)?.reselectAggregateAsDefault()
        }
        // Metering-active gate (T-GATE): only compute/emit `.level` while the
        // popover is actually open. `backend as? MeteringControlling` is nil for
        // backends without the capability (`OwnToneBackend`), so this is a no-op
        // there — mirrors the `LatencyConfigurable` optional-capability pattern.
        popoverController.onMeteringActiveChange = { [weak self] active in
            (self?.backend as? MeteringControlling)?.setMeteringActive(active)
        }
        // Bug T2: an Applications-card slider drive on a `.currentDevice` app must
        // reach its LOCAL playback stream immediately (low latency), not only after
        // the persisted route round-trips through `updateAppRoutes`. No-ops on
        // backends without per-app local playback (`MockBackend`/`OwnToneBackend`).
        popoverController.onSetLocalPlaybackVolume = { [weak self] volume, bundleID in
            (self?.backend as? AppRouteConfiguring)?.setLocalPlaybackVolume(
                volume: volume, bundleID: bundleID)
        }
        // BT-UI: the OUTPUT DEVICES "+" menu's "Pair a Bluetooth speaker…" —
        // pairing is Apple-owned, so the one-tap Settings trip is the whole
        // affordance; the fresh row auto-appears on return (connect
        // notification → enumerator refresh).
        popoverController.onPairBluetoothSpeaker = {
            NSWorkspace.shared.open(SystemSettingsPane.bluetooth.url)
        }
        // BT-UI ghost pairings: recency feed for the Bluetooth subsection's
        // stale-to-the-bottom sort. Capability-gated like the hooks above —
        // nil on MockBackend/OwnToneBackend, which sorts by name alone.
        popoverController.btLastUsedProvider = { [weak self] in
            (self?.backend as? BTOutputControlling)?.lastUsedDatesForBTDevices() ?? [:]
        }
        // BT-OFFSET-UI: the SYNC column's trim round-trip (live-applied to the
        // device's BTSyncedSink delay + persisted per device UID) and the
        // align-by-ear tick gate. Same capability posture as above.
        popoverController.onSetBTTrim = { [weak self] ms, deviceID, persist in
            (self?.backend as? BTOutputControlling)?
                .setBTSyncTrim(ms, forDevice: deviceID, persist: persist)
        }
        popoverController.btTrimProvider = { [weak self] deviceID in
            (self?.backend as? BTOutputControlling)?.btSyncTrim(forDevice: deviceID) ?? 0
        }
        // BT-SYNC-DRAWER T7: D10's real "tuned or never tuned" signal. `false`
        // without the capability, so a mock/dev popover starts every chip at
        // "Not set" and only the user's own edits mark one tuned.
        popoverController.btTrimIsSetProvider = { [weak self] deviceID in
            (self?.backend as? BTOutputControlling)?.btHasSyncTrim(forDevice: deviceID) ?? false
        }
        // BT-SYNC-DRAWER T3: the drawer's hard-stop range. `nil` fallback
        // matches the protocol's own default (full ±range) so a MockBackend/
        // OwnToneBackend popover keeps working with no BT capability at all.
        popoverController.btTrimRangeProvider = { [weak self] deviceID in
            (self?.backend as? BTOutputControlling)?.btUsableTrimRangeMs(forDevice: deviceID)
                ?? (-BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
        }
        popoverController.onAlignTickActiveChange = { [weak self] active in
            (self?.backend as? BTOutputControlling)?.setBTAlignTickActive(active)
        }
        // Excluded apps (Settings › Audio) are un-routable: the popover reads this
        // to drop them from the Applications picker + rows.
        popoverController.isAppExcluded = { [weak self] bundleID in
            self?.excludedApps.isExcluded(bundleID) ?? false
        }
        // Enforce the precedence up front: prune any persisted route for an
        // already-excluded app (e.g. excluded in a previous session).
        pruneRoutesForExcludedApps()
        // NO persisted redirect of any kind survives a full Audiouter restart —
        // every launch starts with every application on "Follows main output"
        // (product decision, Alec 2026-07-26: live testing showed restored
        // `.currentDevice` routes going live at launch, silently starting
        // captures/exclusions the user never asked for that session). Mirrors
        // the existing "the live routing set is not auto-resumed at launch"
        // discipline (AudiouterCore/AGENTS.md) at the per-app level. Called
        // BEFORE the initial `pushAppRoutesToBackend()` below so the backend
        // never sees a stale redirect even transiently at launch.
        appRouting.clearAllRedirectsAtLaunch()
        // Seed the backend with the persisted route table + excluded set (T7). A
        // prune/clear above would already have pushed via `onRoutesDidChange`, but
        // that fires only when something changed — this unconditional push syncs
        // the loaded routes even when nothing was pruned/cleared.
        pushAppRoutesToBackend()

        // A routed app quitting now RESETS its route (product decision 2026-07-22):
        // a per-app redirect to a speaker no longer silently persists across the
        // routed app's own quit/relaunch — which is what let a stale route re-tap
        // (and, before the cold-prompt guard, re-prompt) on a later launch.
        // `resetDeviceRoute` reverts a `.device` redirect back to `.noRedirect` and
        // fires `onRoutesDidChange` → `pushAppRoutesToBackend()`, tearing the
        // per-app tap down through the SAME un-route path a manual change takes —
        // but ONLY for a `.device` route: it deliberately leaves a `.currentDevice`
        // ("play on this Mac") route untouched (see its own doc comment), so on its
        // own it can't tear down THAT tap on quit — it would otherwise leak
        // (registered in coreaudiod against a dead pid) forever. Forwarding to
        // `backend.handleAppTerminated` below covers both cases directly (capture
        // lifecycle, orthogonal to `resetDeviceRoute`'s route persistence) —
        // called FIRST so its routed/local membership check sees the pre-reset
        // state rather than racing `resetDeviceRoute`'s own cascade having already
        // changed it. Core can't observe AppKit notifications itself, so this is
        // the one place that forwards the quit across the boundary. Never
        // explicitly removed: this observer's lifetime is the app's own
        // (AppDelegate is never deallocated before termination).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                let bundleID = app.bundleIdentifier
            else { return }
            (self?.backend as? AppRouteConfiguring)?.handleAppTerminated(bundleID: bundleID)
            self?.appRouting.resetDeviceRoute(bundleID: bundleID)
        }

        // T4 (bug fix): a routed app that quit and relaunched got no capture
        // restart — the persisted route stayed but the live tap was never
        // re-established. Forward the launch so the backend can restart capture
        // and clear the offline indicator the terminate observer raised.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                let bundleID = app.bundleIdentifier
            else { return }
            (self?.backend as? AppRouteConfiguring)?.handleAppLaunched(bundleID: bundleID)
        }

        // B6b: the app has ZERO sleep/wake awareness otherwise — sleep silently
        // severs the RTSP/PTP sockets and the intent-keyed capture gate would keep
        // the Mac muted forever if a receiver never returned. Proactively disconnect
        // cleanly on sleep (intent preserved) and re-converge on wake; the backend
        // arms a fallback watchdog (below) that un-mutes the Mac if nothing comes
        // back. Core can't observe `NSWorkspace` notifications (AppKit), so the seam
        // is driven from here. Never explicitly removed — AppDelegate's lifetime is
        // the app's own, like the app-lifecycle observers above.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.backend.handleSystemWillSleep() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.backend.handleSystemDidWake() }
        // Seed the backend with the persisted wake-restore fallback (B6b) before it
        // can ever wake; the Settings pane re-pushes on change.
        pushWakeRestoreSetting()

        // First-run priming: on the native path, explain BOTH permissions before
        // either system prompt fires. We hold the backend (its discovery triggers
        // the Local Network prompt) until the user has seen the setup screen —
        // otherwise the OS dialog would be their first exposure to the ask, which
        // is the exact thing this flow exists to prevent. Every other launch (and
        // every non-native backend) starts immediately.
        let presentOnLaunch = SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: backendKind)
        // T5: the onboarding-presentation gate's decision + the inputs behind
        // it. `hasCompletedSetup` is the "setup says done/granted" side of
        // tonight's bug; the live `SystemAudioCaptureTCC.isGranted()` read
        // just below (logged separately) is the "real gate" side — together
        // they let a reader see the exact moment those two disagree.
        Telemetry.log(.permission, "onboarding_gate", [
            "site": "AppDelegate.launch.shouldPresentOnLaunch",
            "decision": presentOnLaunch ? "present" : "skip",
            "hasCompletedSetup": "\(settings.hasCompletedSetup)",
            "backendKind": "\(backendKind)",
        ])
        if presentOnLaunch {
            log("Audiouter launched (backend: \(type(of: backend))) — first-run setup")
            presentSetup()
        } else {
            startBackendIfNeeded()
            log("Audiouter launched (backend: \(type(of: backend)))")
            // Existing users who completed onboarding before the PTP helper
            // daemon existed never got `register()` called — it previously only
            // ran from `OnboardingViewController.viewDidLoad`, which this launch
            // path skips entirely. Give every native-backend launch one silent
            // registration attempt so their Login Items entry appears too.
            registerPTPHelperIfNeeded()
            healPTPHelperZombieIfNeeded()
            // If audio capture is already NOT granted at launch (revoked or reset
            // since setup completed), present setup NOW — synchronously, since the
            // grant is a silent read — so it's the first thing on screen. Without
            // this, setup only reappeared via the async reactivate/wake audit,
            // which lagged the launch: the user saw the popover first (a menu-bar
            // click, `onboardingWindowController` still nil) and setup flashed in
            // after. Local Network / PTP gaps are still caught by that audit.
            //
            // T4 (B1): reads `effectiveStatus()`, NOT `isGranted()` — `isGranted()`
            // collapses `.undetermined` to `false`, which used to fire the
            // alarming `.permissionLost` "your permission was turned off" banner
            // for a user who simply never granted it yet (Done doesn't require a
            // grant — see `OnboardingViewController`'s Done handler), a SECOND
            // false-banner path that never showed up in the probe telemetry at
            // all. Only an explicit `.denied` — something WAS decided and is now
            // off — gets the alarm; `.undetermined` takes the same friendly
            // `.firstRun` path the popover-open check below uses, one-shot-gated
            // by `presentSetupForUndeterminedIfNeeded()` so the two call sites
            // can't double-present.
            let effectiveAudioStatus = SystemAudioCaptureTCC.effectiveStatus()
            // T5: the live-permission-triggered half of the gate. Logged
            // unconditionally (not only when it re-presents) so the common
            // "still granted" case is on record too, not just the exception —
            // and `backendKind` is included because this specific check, unlike
            // `shouldPresentOnLaunch` above, runs regardless of backend kind.
            Telemetry.log(.permission, "onboarding_gate", [
                "site": "AppDelegate.launch.liveAudioCaptureCheck",
                "decision": (onboardingWindowController == nil && effectiveAudioStatus != .granted) ? "present" : "skip",
                "hasCompletedSetup": "\(settings.hasCompletedSetup)",
                "backendKind": "\(backendKind)",
                "effectiveStatus": "\(effectiveAudioStatus)",
            ])
            switch effectiveAudioStatus {
            case .denied:
                if onboardingWindowController == nil {
                    log("Audio capture explicitly denied at launch — presenting setup")
                    presentSetup(reason: .permissionLost([.audioCapture]))
                }
            case .undetermined:
                presentSetupForUndeterminedIfNeeded()
            case .granted:
                break
            }
        }

        // T6-rev: arm the mid-session grant detector. Both launch branches above
        // reach here, because a first-run user is the MOST likely to grant while
        // this process is already running — and this process's own
        // `TCCAccessPreflight` read is cached for its whole lifetime, so without
        // this the app would keep refusing its own taps until the user quit and
        // relaunched, even though macOS had already authorized it.
        //
        // Armed only when the grant isn't already in place: an already-granted
        // launch has nothing to detect (`kick` would short-circuit on every
        // trigger anyway), and leaving it unarmed also leaves the Darwin
        // registration — and its unretained back-pointer — unmade.
        // NOTE: the observer's ONLY job is to latch the fresh grant
        // (`SystemAudioCaptureTCC.recordFreshGrant`), so `isGranted()` starts
        // answering true in THIS process — a mid-session grant is otherwise
        // invisible to it for the process's whole life (the TCC read is
        // process-lifetime cached). Nothing auto-resumes off the back of it:
        // the app deliberately starts empty, per-app `.device` routes are
        // cleared at launch (`AppRoutingController.clearAllRedirectsAtLaunch()`),
        // and the user re-picks a destination themselves. The latch is what
        // makes that re-pick actually produce audio without a relaunch.
        if SystemAudioCaptureTCC.effectiveStatus() != .granted {
            permissionObserver.start()
        }

        // Revocation watch: if a REQUIRED permission (audio capture, local
        // network, PTP helper — NOT Remote Control, an enhancement) gets turned
        // off after setup already completed, force onboarding back open with a
        // banner rather than silently degrading. Reactivate and wake are the two
        // moments a permission flip made elsewhere (System Settings, or the PTP
        // helper's Login Items toggle) is most likely to have just happened.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this runs on the main thread; `MainActor
            // .assumeIsolated` tells the compiler what the queue already
            // guarantees (same idiom `OnboardingViewController`'s Timer closures
            // use for the identical shape of problem).
            MainActor.assumeIsolated { self?.auditRequiredPermissionsIfNeeded() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.auditRequiredPermissionsIfNeeded()
                // Re-check the grant on wake so the latch is current. This does
                // NOT resume anything — the app's own sleep/wake reconnect
                // (`NativeBackend.handleSystemDidWake`) is what brings a live
                // stream back; this only keeps `isGranted()` honest.
                self.permissionObserver.kick(source: "wake")
            }
        }
    }

    /// Register the PTP helper daemon once at launch, outside onboarding
    /// (T6 follow-up). Registering shows no system prompt of its own (see
    /// `PTPHelperManaging.register()`'s doc comment) — it just adds a disabled
    /// Login Items entry — so it's safe to fire unconditionally. Gated to
    /// `.notRegistered` (skip the no-op call once already registered) and to
    /// the native backend, same posture as `SetupModel.shouldPresentOnLaunch`:
    /// the mock/OwnTone paths don't use the helper at all.
    @MainActor
    private func registerPTPHelperIfNeeded() {
        guard case .native = backendKind else { return }
        let ptpHelper = permissionProviders.ptpHelper
        guard ptpHelper.status == .notRegistered else { return }
        do {
            try ptpHelper.register()
            log("PTP helper registered at launch (existing-user path)")
        } catch {
            log("PTP helper registration failed at launch: \(error)")
        }
    }

    /// One-shot launch-time auto-heal for the PTP helper "zombie" state
    /// (T-ZOMBIE, T4): `SMAppService` reports `.enabled` (Login Items approved)
    /// yet launchd has no loaded job for the label, so every AirPlay 2 session
    /// silently loses its shared clock. WHY `auditRequiredPermissionsIfNeeded()`
    /// just below can't catch this: that audit is a STATUS-only read
    /// (`SetupModel.auditRequiredPermissions()` calls `PTPHelperManaging
    /// .status`), and a zombie helper reports `.enabled` right through it — a
    /// status-only check PASSES a zombie silently. Only an ACTIVE liveness probe
    /// distinguishes an `.enabled`-but-dead job from a genuinely healthy one,
    /// which is exactly what `PTPHelperReconciler.reconcile()` runs. This method
    /// is both the detection and the auto-repair; a false zombie verdict on a
    /// valid, merely-contended connection is impossible by construction (only
    /// `XPC_ERROR_CONNECTION_INVALID` ever maps to `.zombie` — see
    /// `PTPLivenessProbeResult`), so healing here can never tear down a daemon
    /// that is still mid-takeover for its ports.
    ///
    /// `reconcile()` is async (a bounded XPC probe, ~1.5s worst case), so this
    /// fires it inside its own `Task` rather than awaiting inline — launch must
    /// never block on it. Native-backend-gated, same posture as
    /// `registerPTPHelperIfNeeded()` above: the mock/OwnTone paths never
    /// register the helper, so there is nothing to reconcile. On `.healed`
    /// landing back in `.requiresApproval`, or on `.healFailed` (the auto-heal
    /// itself didn't work and the user needs the manual recovery), presents the
    /// `.permissionLost([.ptpHelper])` approval screen — guarded on
    /// `onboardingWindowController == nil`, the same guard the launch-time
    /// audio-capture `.permissionLost` call site above uses, so this can't
    /// double-present against another site opening onboarding first.
    @MainActor
    private func healPTPHelperZombieIfNeeded() {
        guard case .native = backendKind else { return }
        let reconciler = PTPHelperReconciler(helper: permissionProviders.ptpHelper)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await reconciler.reconcile()
            switch outcome {
            case .healed(let newStatus) where newStatus == .requiresApproval:
                self.log("PTP helper zombie healed at launch — re-registration needs Login Items approval")
                if self.onboardingWindowController == nil {
                    self.presentSetup(reason: .permissionLost([.ptpHelper]))
                }
            case .healFailed:
                self.log("PTP helper zombie heal failed at launch — surfacing manual recovery")
                if self.onboardingWindowController == nil {
                    self.presentSetup(reason: .permissionLost([.ptpHelper]))
                }
            case .notEnabled, .healthy, .indeterminate, .healed:
                break
            }
        }
    }

    /// The automatic post-onboarding revocation check, run from reactivate/wake.
    /// Builds/reuses `permissionAuditModel`, audits the three required
    /// permissions with SILENT/functional reads only (`SetupModel.auditRequiredPermissions()`
    /// — never an audible probe, never an untouched prompt), and force-reopens
    /// onboarding with the `.permissionLost` banner if anything's unmet.
    @MainActor
    private func auditRequiredPermissionsIfNeeded() {
        guard !HeadlessRuntime.isActive else { return }
        guard settings.hasCompletedSetup else { return }
        guard onboardingWindowController == nil else { return }
        guard case .native = backendKind else { return }
        guard !isAuditingRequiredPermissions else { return }
        if let cooldownUntil = permissionAuditCooldownUntil, Date() < cooldownUntil { return }

        let model = permissionAuditModel ?? SetupModel(
            providers: permissionProviders,
            settings: settings,
            localNetworkGated: SetupModel.osGatesLocalNetwork)
        permissionAuditModel = model

        isAuditingRequiredPermissions = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let unmet = await model.auditRequiredPermissions()
            self.isAuditingRequiredPermissions = false
            // Re-check onboarding isn't already open — the audit's awaits give a
            // window for another trigger (or the user) to have opened it since.
            guard !unmet.isEmpty, self.onboardingWindowController == nil else { return }
            self.log("Required permission(s) turned off since setup completed: \(unmet) — reopening setup")
            self.presentSetup(reason: .permissionLost(unmet), model: model)
        }
    }

    /// Present the friendly `.firstRun` Setup window in response to an
    /// `.undetermined` audio-capture verdict — shared by the launch-time
    /// check (B1) and the popover-open check (B2), the two independent sites
    /// that each discover `.undetermined` on their own. `.undetermined` means
    /// "not yet decided," not "revoked," so this is deliberately the calm
    /// first-run presentation, never the `.permissionLost` alarm banner.
    ///
    /// Four guards, all required (T4/B3):
    /// 1. `onboardingWindowController == nil` — `presentSetup` itself already
    ///    re-fronts rather than double-presenting even without this (see its
    ///    own reentrancy guard), but checking here first avoids flipping
    ///    ``didAutoPresentSetupForUndetermined`` for no reason when a window
    ///    is already up for some unrelated reason.
    /// 2. `!didAutoPresentSetupForUndetermined` — once per app session, not
    ///    on every popover click.
    /// 3. `permissionAuditCooldownUntil` — the SAME cooldown a
    ///    `.permissionLost` dismissal already arms (`presentSetup`'s
    ///    `onFinished`), so this friendly path can't immediately re-pop right
    ///    after the user just dismissed the alarm banner without granting —
    ///    it would otherwise fight the reactivate/wake audit's own cooldown
    ///    wait.
    /// 4. Setting the flag BEFORE calling `presentSetup`, not after — so a
    ///    caller cannot re-enter this method (there is none today, but the
    ///    ordering itself is what makes "once per session" true regardless).
    ///
    /// Returns whether it actually presented, so a caller that would
    /// otherwise ALSO open something else in the same gesture (the popover
    /// click, B2) can skip that when Setup just took over instead.
    @discardableResult
    @MainActor
    private func presentSetupForUndeterminedIfNeeded() -> Bool {
        guard onboardingWindowController == nil else { return false }
        guard !didAutoPresentSetupForUndetermined else { return false }
        if let cooldownUntil = permissionAuditCooldownUntil, Date() < cooldownUntil { return false }
        didAutoPresentSetupForUndetermined = true
        presentSetup(reason: .firstRun)
        return true
    }

    /// Start the backend exactly once. Subscribes to the event stream BEFORE
    /// `start()` so the initial `deviceAdded` burst isn't missed. On first-run
    /// native this runs when onboarding is dismissed; otherwise at launch.
    @MainActor
    private func startBackendIfNeeded() {
        guard !backendStarted else { return }
        backendStarted = true
        subscribeToBackendEvents()
        backend.start()
    }

    /// Build (or reuse) a ``SetupModel`` (production probes) + onboarding window
    /// and present it. Used for first-run, "Check Permissions…", the automatic
    /// permission-revocation reopen (`auditRequiredPermissionsIfNeeded`), and the
    /// undetermined-verdict popover-open path (`onButtonClicked`). `onFinished`
    /// starts the backend if it hasn't already (first run) and is a guarded
    /// no-op on a re-run (backend already streaming).
    ///
    /// **REENTRANCY GUARD (fix for a live-reported bug: "the setup window will
    /// just close even though I haven't finished").** A second call while a
    /// Setup window is ALREADY open used to construct a brand-new controller
    /// and overwrite `onboardingWindowController` with it. That drops the app's
    /// only strong reference to the OLD controller — and releasing a window
    /// controller whose window is still on screen tears the window down as
    /// part of that release, which fires `windowWillClose` → `dismiss()` →
    /// `onFinished` on the OLD controller. So a reentrant call didn't just fail
    /// to show a second window — it silently CLOSED THE FIRST ONE and ran its
    /// finish side effects (`startBackendIfNeeded`, `pushAppRoutesToBackend`,
    /// `showPopoverHome`) before the user had actually finished. Three of five
    /// call sites happened to already guard `onboardingWindowController == nil`
    /// before calling this; "Check Permissions…" (`onRunSetupAgain`) did not,
    /// and the popover-open check this task adds would have been a sixth
    /// unguarded site — so the fix belongs HERE, unconditionally, rather than
    /// as yet another guard every caller has to remember to add. When a window
    /// is already open, this simply re-fronts it and returns — no new model,
    /// no new controller, no risk of the drop-and-tear-down above.
    ///
    /// The incoming `reason` is NOT applied to an already-open window: no
    /// existing caller can actually reach the re-front branch with
    /// `.permissionLost` (every `.permissionLost` call site already guards
    /// `onboardingWindowController == nil`), so there is no live case that
    /// needs an "upgrade," and silently reinterpreting an open `.firstRun`
    /// window as `.permissionLost` would risk showing the "permission turned
    /// off" alarm banner without the explicit denial the locked design
    /// requires it to have (see `onButtonClicked`'s doc comment). A future
    /// caller that genuinely needs to upgrade an open window's banner should
    /// do so deliberately, respecting that rule — this method does not
    /// preempt that decision by guessing.
    ///
    /// - Parameters:
    ///   - reason: `.firstRun` (default) for the ordinary flows, unchanged from
    ///     before; `.permissionLost` for the automatic reopen, which also shows
    ///     the "turned off" banner. Ignored when re-fronting an already-open
    ///     window (see above).
    ///   - model: pass the SAME model the triggering audit already refreshed
    ///     (so the rows reflect the just-observed unmet statuses instead of
    ///     resetting to blank); `nil` builds a fresh one, as every pre-existing
    ///     call site did. Either way the result is stashed in
    ///     `permissionAuditModel` so later automatic audits keep reusing it.
    ///     Ignored when re-fronting an already-open window.
    @MainActor
    private func presentSetup(reason: OnboardingReason = .firstRun, model providedModel: SetupModel? = nil) {
        // Re-entry guard (matches the three other call sites' `onboardingWindowController
        // == nil` pattern above). Both this branch and the memory-leak branch hit
        // this independently, which is how confident we are it's real: without the
        // guard, a second call while a first onboarding window is still open
        // (reachable via Settings ▸ General's "Run Setup Again…" — the window is
        // normal-level, so Settings stays clickable) silently overwrites
        // `onboardingWindowController`. Releasing the old controller fires its
        // `windowWillClose` → `onFinished`, which nils the reference to the NEW
        // controller just stored, leaving it unretained so it deallocates and
        // vanishes — and orphaning the first window's two live 1.5 s polling
        // Timers (`OnboardingViewController`), never stopped. Observed live as
        // "the setup window just closes while I'm still granting permissions."
        // Re-front the existing window instead, so a repeat click visibly does
        // something rather than silently no-op'ing.
        if let existing = onboardingWindowController {
            existing.present()
            return
        }

        // Generation stamp: `onFinished` below only clears
        // `onboardingWindowController` when the closing controller is still the
        // CURRENT one, so a late teardown can never clobber a newer window even
        // if a future caller reintroduces re-entrancy past the guard above.
        onboardingPresentationGeneration += 1
        let presentationGeneration = onboardingPresentationGeneration

        let model = providedModel ?? SetupModel(
            providers: permissionProviders,
            settings: settings,
            localNetworkGated: SetupModel.osGatesLocalNetwork)
        permissionAuditModel = model
        let controller = OnboardingWindowController(model: model, reason: reason) { [weak self] in
            guard let self else { return }
            // Belt-and-suspenders identity check (see
            // `onboardingPresentationGeneration`'s doc comment): only clear the
            // stored reference if THIS finish still belongs to the current
            // controller, so a stale finish can never wipe a newer one.
            if self.onboardingPresentationGeneration == presentationGeneration {
                self.onboardingWindowController = nil
            }
            self.startBackendIfNeeded()
            // Re-apply persisted per-app routes now that Setup has closed. Kept
            // for the case a route was ADDED/CHANGED while Setup was open — but
            // this is NOT what restarts a route that was REFUSED before the grant
            // (the cold-prompt guard in the capture coordinators — see
            // `SystemAudioCaptureTCC`): `updateAppRoutes` starts only the
            // route-table DIFF, so re-pushing the SAME unchanged table yields an
            // EMPTY start set and starts nothing. NOTHING revives a refused route
            // mid-session any more — that auto-resume machinery was deleted
            // (2026-07-25, see `AudiouterCore/AGENTS.md`); relaunching after the
            // grant is the supported recovery, and launch clears `.device` routes
            // anyway. Still a no-op push when nothing is routed, and still safe if they
            // finished WITHOUT granting: the guard simply refuses again, never
            // prompting.
            self.pushAppRoutesToBackend()
            if case .permissionLost = reason {
                self.permissionAuditCooldownUntil = Date().addingTimeInterval(self.permissionAuditCooldown)
            }
            // First-run Done (or the ✕/lost-permission reopen) currently left
            // the user with NO window at all — the whole point of finishing
            // setup is to start using the app, so open the main popover the
            // moment onboarding dismisses rather than making them go find the
            // menu-bar icon themselves.
            self.showPopoverHome()
        }
        onboardingWindowController = controller
        controller.present()
    }

    // MARK: Menu-bar secondary menu + app main menu (Quit / Settings discoverability)

    /// The menu shown on a right/control-click of the status item — the
    /// discoverable path to Settings, Groups, and Quit for a Dock-less app whose
    /// only other quit affordance is the small power glyph in the popover header.
    @MainActor
    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        let groups = menu.addItem(withTitle: "Groups…", action: #selector(menuOpenGroups), keyEquivalent: "")
        groups.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Audiouter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }

    /// A minimal application main menu. A menu-bar-only (`.accessory`) app shows
    /// no menu bar, but a main menu still supplies working key equivalents while
    /// the app is active — this is what makes ⌘Q (and ⌘,) work, which the app
    /// otherwise lacked entirely.
    ///
    /// Also installs a File menu with a single Close item (⌘W): AppKit only
    /// synthesizes ⌘W automatically for a `.closable` window when a main menu
    /// with a File ▸ Close item exists at all — with no main menu (the prior
    /// state) or a main menu missing this item, ⌘W does nothing. `target: nil`
    /// sends `performClose:` down the responder chain, so it reaches whichever
    /// window is key (Settings or the Groups panel/mixer window) rather than
    /// being hardwired to one.
    @MainActor
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Quit Audiouter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let close = fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.target = nil
        fileItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    @MainActor @objc private func menuOpenSettings() { openSettings() }
    @MainActor @objc private func menuOpenGroups() { openMixer() }

    /// "Open Mixer…" target — open/focus the full mixer window (SPEC §9, T-U4).
    /// Lazily built on first use, then reused; seeded with the current device
    /// snapshot so it's correct the instant it appears. Shares the app's one
    /// `GroupController`, so menu and window never diverge.
    @MainActor
    private func openMixer() {
        if useControlPanel {
            openGroupsPanel()
            return
        }
        let controller: MixerWindowController
        if let existing = mixerWindowController {
            controller = existing
        } else {
            controller = MixerWindowController(groupController: groupController,
                                               appRouting: appRouting,
                                               deviceIconController: deviceIconController)
            mixerWindowController = controller
        }
        controller.update(devices: Array(devicesByID.values))
        controller.showWindow()
        log("Open Mixer… (window shown)")
    }

    /// Control-panel rollout: open Groups in the shared floating shell anchored
    /// under the menu-bar item. Build/reuse the `MixerWindowController` (WINDOW
    /// chrome — the shell provides the panel now; this controller only supplies
    /// its content view), then host its content in the one shared shell.
    @MainActor
    private func openGroupsPanel() {
        let controller: MixerWindowController
        if let existing = mixerWindowController {
            controller = existing
        } else {
            controller = MixerWindowController(groupController: groupController,
                                               appRouting: appRouting,
                                               deviceIconController: deviceIconController)
            mixerWindowController = controller
        }
        controller.update(devices: Array(devicesByID.values))
        presentInControlPanel(content: controller.contentController,
                              title: "Groups",
                              defaultSize: NSSize(width: 720, height: 460))
        log("Open Groups (control panel)")
    }

    /// Host `content` in the ONE shared control-panel shell (control-panel
    /// rollout — Groups only; Settings now owns a standalone window). Create
    /// the shell and wire its land-home `onClose` exactly once; otherwise swap
    /// its content in place. Hands off from the popover (close it first),
    /// marks the session live, and shows the shell anchored just under the
    /// menu-bar item. When the shell later closes for real, `onClose`
    /// re-presents the popover so you always land back "home" and are never
    /// stranded in a dockless void. `defaultSize` is Groups' own documented
    /// size (`MixerWindowController`'s 720×460) passed explicitly rather than
    /// relied on as `setContent`'s default.
    @MainActor
    private func presentInControlPanel(content: NSViewController,
                                       title: String,
                                       defaultSize: NSSize) {
        let shell: ControlPanelWindowController
        if let existing = controlPanel {
            shell = existing
        } else {
            shell = ControlPanelWindowController()
            shell.onClose = { [weak self] in
                guard let self else { return }
                self.controlPanelSessionActive = false
                self.showPopoverHome()
            }
            controlPanel = shell
        }
        shell.setContent(content, defaultSize: defaultSize)
        shell.setTitle(title)
        controlPanelSessionActive = true
        popoverController.popover.performClose(nil)   // hand off from the popover
        shell.show(anchorRect: statusAnchorRect())
    }

    /// Re-present the popover from the status item — the "return home" after the
    /// control panel closes. No-op if it's somehow already showing.
    @MainActor
    private func showPopoverHome() {
        guard let button = statusItemController.button else { return }
        if !popoverController.popover.isShown {
            popoverController.toggle(relativeTo: button)
        }
    }

    /// The menu-bar item's frame in screen coordinates, for anchoring the panel
    /// just beneath it. `nil` (item not yet in the bar) → the panel centers.
    @MainActor
    private func statusAnchorRect() -> NSRect? {
        guard let button = statusItemController.button, let win = button.window else { return nil }
        return win.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Header gear target — open/focus the Settings window (previously a
    /// `// TODO: settings` stub). Lazily built, then reused; theme changes made
    /// in the Appearance pane are applied app-wide via `applyAppearance`.
    @MainActor
    private func openSettings() {
        let controller: SettingsWindowController
        if let existing = settingsWindowController {
            controller = existing
        } else {
            controller = SettingsWindowController(settings: settings,
                                                  excludedApps: excludedApps,
                                                  latency: makeLatencySettingModel(),
                                                  wakeRestore: makeWakeRestoreSettingModel())
            controller.onThemeChanged = { [weak self] theme in self?.applyAppearance(theme) }
            // Accent dial (W1, spec §1.3): the pane has already persisted and
            // remapped `Tokens.accentStyle`; this nudge repaints whatever is
            // on screen so `draw(_:)`-based instruments re-resolve now.
            // Layer-color instruments re-read the tokens on their next state
            // update/rebuild (the popover rebuilds on every open).
            controller.onAccentChanged = { [weak self] _ in self?.repaintOpenWindowsForAccentChange() }
            controller.onExcludedAppsChanged = { [weak self] in self?.handleExcludedAppsChanged() }
            // "Check Permissions…" (General pane) re-opens the first-run priming
            // window; the backend is already running, so its onFinished is a
            // guarded no-op.
            controller.onRunSetupAgain = { [weak self] in self?.presentSetup() }
            settingsWindowController = controller
        }
        controller.showWindow()
        log("Open Settings (window shown)")
    }

    /// The Advanced › Audio buffer model (PLAN-LATENCY-SETTING.md), or nil when
    /// the resolved backend can't honor the control (the section then never
    /// renders). The apply closure persists FIRST, then reconnects — a partial
    /// reconnect failure must not lose the chosen setting for the next launch.
    @MainActor
    private func makeLatencySettingModel() -> LatencySettingModel? {
        guard let configurable = backend as? LatencyConfigurable else { return nil }
        return LatencySettingModel(
            optionsMs: AppSettings.startBufferOptionsMs,
            initialMs: configurable.startBufferMs,
            envOverrideMs: nativeStartBufferEnvOverrideMs(),
            isStreaming: { [weak self] in
                self?.devicesByID.values.contains { $0.isSelected } ?? false
            },
            apply: { [weak self] ms in
                self?.settings.startBufferMs = ms
                await configurable.applyStartBuffer(ms: ms)
            }
        )
    }

    /// The Settings › Audio wake-restore model (B6b). Reads the persisted minutes
    /// and, on change, persists + re-pushes to the backend. Built unconditionally —
    /// the setting is a universal preference; on backends without a capture gate the
    /// pushed delay is simply a no-op.
    @MainActor
    private func makeWakeRestoreSettingModel() -> WakeAudioRestoreModel {
        WakeAudioRestoreModel(
            minuteOptions: AppSettings.wakeRestoreMinuteOptions,
            initialMinutes: settings.wakeRestoreMinutes,
            apply: { [weak self] minutes in
                self?.settings.wakeRestoreMinutes = minutes
                self?.pushWakeRestoreSetting()
            })
    }

    /// Push the persisted wake-restore fallback into the backend (B6b). `0` minutes
    /// ("Never") maps to `nil` (watchdog disabled); otherwise minutes → seconds.
    @MainActor
    private func pushWakeRestoreSetting() {
        let minutes = settings.wakeRestoreMinutes
        backend.setWakeAudioRestoreDelay(minutes <= 0 ? nil : TimeInterval(minutes * 60))
    }

    /// The excluded-apps list changed (Settings › Audio). Enforce the "excluded ⇒
    /// un-routable" precedence — prune any per-app route for a now-excluded app —
    /// then repaint the popover so its Applications card reflects the change.
    @MainActor
    private func handleExcludedAppsChanged() {
        pruneRoutesForExcludedApps()
        // The excluded SET feeds the backend's whole-system tap exclusion (T4/T7),
        // so re-push even when no route was pruned: excluding an app that has no
        // route still changes what the tap must exclude.
        pushAppRoutesToBackend()
        popoverController.update(devices: Array(devicesByID.values))
    }

    /// Push the current app-routing table + excluded set into the backend's per-app
    /// capture path (T7). No-ops on backends without per-app routing
    /// (`MockBackend` / `OwnToneBackend` don't conform to `AppRouteConfiguring`).
    /// Called from `onRoutesDidChange`, the excluded-apps handler, and once at
    /// launch. Never invoked from inside a backend lock/queue (T6's deadlock
    /// warning) — every caller is a plain MainActor path.
    @MainActor
    private func pushAppRoutesToBackend() {
        (backend as? AppRouteConfiguring)?.updateAppRoutes(
            appRouting.appRoutes,
            excludedBundleIDs: excludedApps.excludedBundleIDs)
    }

    /// Remove any per-app route whose app is currently excluded (an excluded app
    /// always plays locally, so a redirect for it is contradictory). No-op when
    /// nothing is excluded / routed.
    @MainActor
    private func pruneRoutesForExcludedApps() {
        for bundleID in excludedApps.excludedBundleIDs {
            appRouting.removeRoute(bundleID: bundleID)
        }
    }

    /// Accent-dial change nudge (W1, spec §1.3): mark every open window's view
    /// tree display-dirty so `draw(_:)`-based instruments (bus, icon wells,
    /// tiles) re-resolve the freshly remapped gold/ember/glow tokens on the
    /// next display pass. Deliberately NOT a rebuild: layer-color instruments
    /// pick the remap up on their own next state update, and the popover
    /// rebuilds on every open anyway.
    @MainActor
    private func repaintOpenWindowsForAccentChange() {
        func markDirty(_ view: NSView) {
            view.needsDisplay = true
            for subview in view.subviews { markDirty(subview) }
        }
        for window in NSApp.windows {
            if let contentView = window.contentView { markDirty(contentView) }
        }
    }

    /// Apply the appearance override app-wide (Settings › Appearance). `.system`
    /// clears the override so the app follows the system again (SPEC §9 — the
    /// historical default). The adaptive UI reads `effectiveAppearance`, which
    /// reflects this immediately.
    @MainActor
    private func applyAppearance(_ theme: AppearanceTheme) {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Gives graceful AirPlay teardown a bounded window before the process exits
    /// (C1). A plain `applicationWillTerminate` fires `backend.stop()` and then the
    /// process dies immediately — `stop()`'s engine teardown is deliberately
    /// fire-and-forget (see its doc comment), so process exit routinely outran the
    /// RTSP/RTP goodbye, leaving receivers with stale sessions that make the next
    /// reconnect flaky. `.terminateLater` holds the process open just long enough to
    /// await `stopAndWait(timeout:)` (bounded at 2s so a wedged engine can never hang
    /// the quit), then replies to let AppKit finish terminating.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        eventTask?.cancel()
        eventTask = nil
        backend.stop()
        log("Audiouter terminating")

        // Only show the indicator if the wait is actually slow (~300ms) — an instant
        // quit must never flash UI.
        let indicatorDelay = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.isTerminating else { return }
            self.quittingIndicator = QuittingIndicatorPanel.showCentered()
        }

        Task { @MainActor [weak self] in
            await self?.backend.stopAndWait(timeout: .seconds(2))
            indicatorDelay.cancel()
            self?.quittingIndicator?.close()
            self?.quittingIndicator = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    // MARK: Backend event plumbing

    /// Drive the app's device model from the backend's event stream (the ONLY
    /// state channel — OutputBackend.swift). For T-U1 we fold events into
    /// `devicesByID`, refresh the placeholder master-volume symbol, and log to
    /// stderr. T-U2 will additionally rebuild the menu here.
    private func subscribeToBackendEvents() {
        let stream = backend.makeEventStream()
        eventTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                await MainActor.run { [weak self] in self?.apply(event) }
            }
        }
    }

    @MainActor
    private func apply(_ event: BackendEvent) {
        switch event {
        case .deviceAdded(let device), .deviceUpdated(let device):
            devicesByID[device.id] = device
            log("event: \(describe(event))")
        case .deviceRemoved(let id):
            devicesByID.removeValue(forKey: id)
            log("event: deviceRemoved(\(id))")
        case .level(let id, let rms):
            // Meters are SKIPPED in Phase 1 (RESOLVED Q8) — ignore for now.
            // AIRPLAY_DEBUG_LEVELS=1: log capture RMS ~1/sec. The one observable
            // that splits "tap delivers audio" from "tap delivers TCC-denied
            // zeros" (a denied tap returns noErr + all-zero buffers — it cannot
            // self-report, so this is the only place the silence is visible).
            if debugLevels, Date().timeIntervalSince(lastLevelLog) >= 1 {
                lastLevelLog = Date()
                log("level: \(id) rms \(rms)")
            }
            popoverController.updateLevel(rms, for: id)
            return
        case .appLevel(let bundleID, let rms):
            popoverController.updateAppLevel(rms, for: bundleID)
            return
        case .systemVolumeChanged(let volume):
            // The volume keys moved the system output, which IS Main Out's own value.
            // Nothing is redistributed: Main is a stored master gain, and every device
            // picks the change up because `Main × Group × Device` is formed at the
            // write boundary. So the keys drive whatever is actually playing without
            // any device's own level being touched.
            //
            // The system hardware is ALREADY at `volume` — this only brings Main into
            // agreement and re-pushes the dependent gains. It deliberately writes no
            // hardware, which is what keeps the keys from feeding back on themselves.
            //
            // This delegate is the whole reason the backend can stay below the routing
            // brain: `NativeBackend` owns the system-volume listener but must not know
            // `GroupController` exists, so it publishes the fact and this — already the
            // place backend events meet app-level controllers — does the wiring.
            groupController.applyExternalSystemVolume(volume)
            log("event: \(describe(event))")
            // Falls through to the repaint below, to keep the master readout honest.
        case .routedApps(let deviceID, let appNames):
            // The live "which app streams here now" map (T6). T9: store it on the
            // popover so the device row's routing sublabel can prefer this
            // CONFIRMED signal over the intent-based one (see
            // `PopoverController.applyRoutedApps` / `DeviceRowView.apply`'s
            // `liveAppNames` doc). Falls through to the shared repaint below like
            // every other event — this call only updates state, it doesn't repaint
            // itself.
            popoverController.applyRoutedApps(deviceID: deviceID, appNames: appNames)
            // The menu-bar glyph's streaming decision reads this same live-route
            // signal (empty list = the live set for this device went back to empty).
            if appNames.isEmpty {
                routedAppNamesByDeviceID.removeValue(forKey: deviceID)
            } else {
                routedAppNamesByDeviceID[deviceID] = appNames
            }
            log("event: \(describe(event))")
        case .routedAppRunning(let bundleID, let isRunning):
            // T4 (bug fix): a routed app quit or relaunched — update the popover's
            // offline indicator for its row. Falls through to the shared repaint
            // so the row paint reflects the new state on the next cycle.
            popoverController.applyRoutedAppRunning(bundleID: bundleID, isRunning: isRunning)
            log("event: \(describe(event))")
        case .remoteTransport(let command):
            // A transport key pressed on the speaker itself. Drive the Mac's media
            // playback so the actual song responds. No device model to repaint — this
            // targets whatever app is playing — so handle it and return.
            mediaKeyController.handle(command)
            log("event: \(describe(event))")
            return
        case .localFallbackActive(let active):
            // The generalized silence watchdog (R11) un-gated (or re-gated) whole-system
            // capture: nothing the user selected stayed connected, so the Mac fell back
            // to local playback (or a device reconnected and audio moved back). Show or
            // clear the popover banner; the selection intent is untouched, so no device
            // model changed — handle it and return.
            popoverController.setLocalFallbackActive(active)
            log("event: \(describe(event))")
            return
        case .systemDefaultIsAirPlayActive(let active):
            // W3-T3: the macOS system default output is (or stopped being)
            // AirPlay-class while we're actively streaming — double-path/echo
            // risk. Purely informational: show or clear the popover note; no
            // device model changed, no audio path is altered — handle it and
            // return.
            popoverController.setSystemAirPlayNoteActive(active)
            log("event: \(describe(event))")
            return
        case .streamHealth:
            // Signal-only (T8): a re-capture/rebind was detected on some device
            // and is in flight (`recovering == true`) or resolved
            // (`recovering == false`). No UI surfaces this yet — designing that
            // is an explicit follow-up. Log and return; no device model to repaint.
            log("event: \(describe(event))")
            return
        case .takeoverStatus(let status):
            // T6: a progressive explanation of the T5+T4 handover, alongside the
            // connecting row it explains. Purely informational: show or clear the
            // popover's takeover strip; no device model changed, no audio path is
            // altered — handle it and return.
            popoverController.setTakeoverStatus(status)
            log("event: \(describe(event))")
            return
        case .routingBlockedNeedsDefault(let active):
            // Wave 3 T5: the app is actively routing but the Mac's default output
            // isn't our public aggregate, so audio is dead until the user switches
            // back. Show or clear the popover's routing-blocked warning; a whole-app
            // condition with no home on a `Device` — handle it and return.
            popoverController.setRoutingBlockedNeedsDefault(active)
            log("event: \(describe(event))")
            return
        }
        // Establish the out-of-the-box default (current device selected ⇒
        // passthrough) once the fleet is known (SPEC §9b). No-op after the first
        // time / if a persisted selection was loaded.
        groupController.ensureDefaultSelection()
        // Feed the popover (repaints open rows in place, or caches for next
        // open), then drive the status symbol from the Main Out master.
        let devices = Array(devicesByID.values)
        popoverController.update(devices: devices)
        // The status glyph is a truthful glance: the arc is the Main Out master,
        // and the symbol goes accent-coloured while anything is actually leaving
        // the Mac (Main Out membership OR a live per-app redirect).
        statusItemController.updateMasterVolume(popoverController.statusMasterVolume)
        statusItemController.updateStreamingState(devices: devices, liveRoutedAppNames: routedAppNamesByDeviceID)
        // Keep the mixer window (if open) in lockstep with the same snapshot.
        mixerWindowController?.update(devices: devices)
    }

    // MARK: stderr logging (T-U1 — real UI in T-U2)

    private func describe(_ event: BackendEvent) -> String {
        switch event {
        case .deviceAdded(let d):
            return "deviceAdded(\(d.name), vol \(d.volume), selected \(d.isSelected))"
        case .deviceUpdated(let d):
            return "deviceUpdated(\(d.name), vol \(d.volume), muted \(d.isMuted), selected \(d.isSelected))"
        case .deviceRemoved(let id):
            return "deviceRemoved(\(id))"
        case .level(let id, let rms):
            return "level(\(id), \(rms))"
        case .appLevel(let bundleID, let rms):
            return "appLevel(\(bundleID), \(rms))"
        case .systemVolumeChanged(let volume):
            return "systemVolumeChanged(\(volume)) — syncing Main Out"
        case .routedApps(let deviceID, let appNames):
            return "routedApps(\(deviceID), [\(appNames.joined(separator: ", "))])"
        case .routedAppRunning(let bundleID, let isRunning):
            return "routedAppRunning(\(bundleID), isRunning: \(isRunning))"
        case .remoteTransport(let command):
            return "remoteTransport(\(command)) — driving Mac media playback"
        case .localFallbackActive(let active):
            return "localFallbackActive(\(active)) — \(active ? "speakers unreachable, playing on this Mac" : "device reconnected, resuming")"
        case .systemDefaultIsAirPlayActive(let active):
            return "systemDefaultIsAirPlayActive(\(active)) — \(active ? "system default output is also AirPlay, echo risk" : "no longer double-pathed")"
        case .streamHealth(let id, let recovering):
            return "streamHealth(\(id), recovering: \(recovering))"
        case .takeoverStatus(let status):
            return "takeoverStatus(\(status.map { "\($0)" } ?? "nil"))"
        case .routingBlockedNeedsDefault(let active):
            return "routingBlockedNeedsDefault(\(active)) — \(active ? "actively routing but the aggregate isn't the Mac's default output" : "aggregate is default again / routing stopped")"
        }
    }

    private func log(_ message: String) {
        audiouterEmergencyWriteStderr("[Audiouter] \(message)\n")
    }
}

/// Small floating "Disconnecting…" indicator shown while `applicationShouldTerminate`
/// waits on `stopAndWait(timeout:)` (C1, user-requested) — so a multi-hundred-ms quit
/// reads as deliberate rather than a hang. Nonactivating so it never steals focus, and
/// dies with the process regardless, but `AppDelegate` closes it explicitly before
/// replying so the exit looks clean rather than an indicator vanishing mid-frame.
@MainActor
final class QuittingIndicatorPanel: NSPanel {

    static func showCentered() -> QuittingIndicatorPanel {
        let panel = QuittingIndicatorPanel()
        panel.center()
        panel.orderFrontRegardless()
        return panel
    }

    private init() {
        let size = NSSize(width: 220, height: 64)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        // A programmatic NSPanel defaults `isReleasedWhenClosed` to true (AppKit
        // releases it on close) — combined with the strong `quittingIndicator`
        // property that ALSO releases it (cleared to nil after close), that's a
        // double-release. This class has no window controller to own that
        // instead, so ARC via the property is the one owner.
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effectView.material = .popover
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Disconnecting…")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(spinner)
        effectView.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 24),
            spinner.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
        ])

        contentView = effectView
    }
}
