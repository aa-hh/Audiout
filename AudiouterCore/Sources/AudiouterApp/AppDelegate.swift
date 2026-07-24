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

/// Resolve a bundle ID to the FULL set of pids that make up that app — its main
/// process AND any audio-playing helper/child processes (W1-T1). This is the real
/// per-app-capture / exclusion resolver the native backend needs: Core can't
/// import AppKit, so the AppKit layer supplies it via
/// `makeBackend(resolveProcessSet:)`.
///
/// The grouping is done by ``ProcessSetResolver`` over the live Core Audio
/// process-object list (bundle-ID prefix match — Chrome helpers carry
/// `com.google.Chrome.helper…`, Firefox children carry the parent identity),
/// with a responsible-pid walk for helpers whose own bundle ID doesn't
/// prefix-match. The walk uses the SPI `responsibility_get_pid_for_pid` when
/// available and is best-effort (returns nil ⇒ prefix match only, which already
/// covers the common browsers). `NSRunningApplication` supplies a fallback for
/// the app's own main pid so a not-yet-audible app (no audio process object yet)
/// still resolves its main process.
///
/// A free `@Sendable` closure (not an instance method) so it can be used in
/// `AppDelegate`'s `backend` property initializer, which runs before `self`.
///
/// The responsible-pid SPI is resolved via `dlsym` (RTLD_DEFAULT) rather than
/// a link-time symbol — it lives in a private library and isn't always
/// available to link against, so a runtime lookup keeps the app linkable and
/// simply degrades to prefix-match-only when the symbol is absent. Same pattern
/// the app uses for other SPIs (`TCCAccessPreflight`).
private typealias ResponsiblePIDFn = @convention(c) (pid_t) -> pid_t
private let responsiblePIDForPID: ResponsiblePIDFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2 /* RTLD_DEFAULT */),
                          "responsibility_get_pid_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsiblePIDFn.self)
}()

private let resolveRunningAppProcessSet: @Sendable (String) -> [pid_t] = { bundleID in
    let base = ProcessSetResolver(
        enumerate: ProcessSetResolver.systemEnumerator(),
        responsiblePID: { pid in
            guard let fn = responsiblePIDForPID else { return nil }
            let owner = fn(pid)
            return (owner > 0 && owner != pid) ? owner : nil
        })
    var pids = base.pids(forBundleID: bundleID)
    // Fallback: an app that hasn't opened an audio stream yet has no process
    // object in the list, so include its NSRunningApplication main pid(s) too
    // (deduped, appended after any audio-process pids so `.first` stays the
    // main process). This preserves the pre-Wave-1 "resolve the main pid"
    // behaviour for apps that aren't audible yet.
    let seen = Set(pids)
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
        let pid = app.processIdentifier
        if pid > 0 && !seen.contains(pid) { pids.append(pid) }
    }
    return pids
}

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
    /// `resolveProcessSet` threads the real process-set resolver (W1-T1) into
    /// the native backend's per-app capture + exclusion paths.
    private let backend: OutputBackend = makeBackend(resolveProcessSet: resolveRunningAppProcessSet)

    /// Owns the status item's `.button` (SPEC §9 / brief §4 — customize ONLY
    /// via `.button`, never the deprecated `.view`/`.title`/`.image`).
    private var statusItemController: StatusItemController!

    /// The popover dropdown (SPEC §9 revised). Owns the `NSPopover` and, via the
    /// injected `GroupController`, all group/master/mute/routing interaction.
    /// Wired with an explicit production `AppRoutingController` so app routes
    /// persist to Application Support (T-11).
    private var popoverController: PopoverController!

    /// UI-agnostic mixer model (groups, proportional master, mute) shared
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

    /// AIRPLAY_DEBUG_LEVELS=1 → log capture RMS ~1/sec (see the `.level` case).
    private let debugLevels = ProcessInfo.processInfo.environment["AIRPLAY_DEBUG_LEVELS"] == "1"
    private var lastLevelLog = Date.distantPast

    /// The task consuming the backend event stream. Cancelled on teardown so the
    /// stream finishes cleanly and we don't leak it past app exit.
    private var eventTask: Task<Void, Never>?

    /// Turns a transport key pressed ON A SPEAKER (`BackendEvent.remoteTransport`)
    /// into a Mac media key so the frontmost player responds. Owns the one-time
    /// Accessibility prompt the feature needs.
    private let mediaKeyController = MediaKeyController()

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

    /// Which surface the shared shell is currently hosting (control-panel
    /// rollout). Groups today; Settings folds onto the same shell next.
    private enum ControlPanelSurface { case groups, settings }
    private var activePanelSurface: ControlPanelSurface = .groups

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
        // Apply the persisted appearance override BEFORE building any UI, so the
        // status item and popover pick it up on first paint (Settings ›
        // Appearance). `.system` is a no-op (`NSApp.appearance = nil`).
        applyAppearance(settings.theme)

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
        popoverController = PopoverController(appRouting: appRouting)
        popoverController.deviceIconController = deviceIconController
        popoverController.configure(groupController: groupController)
        popoverController.onOpenMixer = { [weak self] in self?.openMixer() }
        popoverController.onOpenSettings = { [weak self] in self?.openSettings() }
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
        // Excluded apps (Settings › Audio) are un-routable: the popover reads this
        // to drop them from the Applications picker + rows.
        popoverController.isAppExcluded = { [weak self] bundleID in
            self?.excludedApps.isExcluded(bundleID) ?? false
        }
        // Enforce the precedence up front: prune any persisted route for an
        // already-excluded app (e.g. excluded in a previous session).
        pruneRoutesForExcludedApps()
        // Seed the backend with the persisted route table + excluded set (T7). A
        // prune above would already have pushed via `onRoutesDidChange`, but that
        // fires only when something changed — this unconditional push syncs the
        // loaded routes even when nothing was pruned.
        pushAppRoutesToBackend()

        // A routed app quitting now RESETS its route (product decision 2026-07-22):
        // a per-app redirect to a speaker no longer silently persists across the
        // routed app's own quit/relaunch — which is what let a stale route re-tap
        // (and, before the cold-prompt guard, re-prompt) on a later launch.
        // `resetDeviceRoute` reverts a `.device` redirect back to `.noRedirect` and
        // fires `onRoutesDidChange` → `pushAppRoutesToBackend()`, tearing the
        // per-app tap down through the SAME un-route path a manual change takes
        // (so it supersedes the old `handleAppTerminated` "keep route, show
        // offline" behavior). Core can't observe AppKit notifications itself, so
        // this is the one place that forwards the quit across the boundary. Never
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
        if SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: backendKind) {
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
            // If audio capture is already NOT granted at launch (revoked or reset
            // since setup completed), present setup NOW — synchronously, since the
            // grant is a silent read — so it's the first thing on screen. Without
            // this, setup only reappeared via the async reactivate/wake audit,
            // which lagged the launch: the user saw the popover first (a menu-bar
            // click, `onboardingWindowController` still nil) and setup flashed in
            // after. Local Network / PTP gaps are still caught by that audit.
            if onboardingWindowController == nil, !SystemAudioCaptureTCC.isGranted() {
                log("Audio capture not granted at launch — presenting setup")
                presentSetup(reason: .permissionLost([.audioCapture]))
            }
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
            MainActor.assumeIsolated { self?.auditRequiredPermissionsIfNeeded() }
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
        let ptpHelper = SMAppServicePTPHelper()
        guard ptpHelper.status == .notRegistered else { return }
        do {
            try ptpHelper.register()
            log("PTP helper registered at launch (existing-user path)")
        } catch {
            log("PTP helper registration failed at launch: \(error)")
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
            audioProbe: AudioCapturePermissionProbeFactory.makeDefault(),
            localNetwork: LocalNetworkPrimerFactory.makeDefault(),
            remoteControl: RemoteControlPrimerFactory.makeDefault(),
            ptpHelper: SMAppServicePTPHelper(),
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
    /// and present it. Used for first-run, "Check Permissions…", AND the
    /// automatic permission-revocation reopen (`auditRequiredPermissionsIfNeeded`).
    /// `onFinished` starts the backend if it hasn't already (first run) and is a
    /// guarded no-op on a re-run (backend already streaming).
    ///
    /// - Parameters:
    ///   - reason: `.firstRun` (default) for the ordinary flows, unchanged from
    ///     before; `.permissionLost` for the automatic reopen, which also shows
    ///     the "turned off" banner.
    ///   - model: pass the SAME model the triggering audit already refreshed
    ///     (so the rows reflect the just-observed unmet statuses instead of
    ///     resetting to blank); `nil` builds a fresh one, as every pre-existing
    ///     call site did. Either way the result is stashed in
    ///     `permissionAuditModel` so later automatic audits keep reusing it.
    @MainActor
    private func presentSetup(reason: OnboardingReason = .firstRun, model providedModel: SetupModel? = nil) {
        let model = providedModel ?? SetupModel(
            audioProbe: AudioCapturePermissionProbeFactory.makeDefault(),
            localNetwork: LocalNetworkPrimerFactory.makeDefault(),
            remoteControl: RemoteControlPrimerFactory.makeDefault(),
            ptpHelper: SMAppServicePTPHelper(),
            settings: settings,
            localNetworkGated: SetupModel.osGatesLocalNetwork)
        permissionAuditModel = model
        let controller = OnboardingWindowController(model: model, reason: reason) { [weak self] in
            guard let self else { return }
            self.onboardingWindowController = nil
            self.startBackendIfNeeded()
            // Re-apply persisted per-app routes now that Setup has closed. Any
            // capture tap they need was REFUSED before the grant (the cold-prompt
            // guard in the capture coordinators — see `SystemAudioCaptureTCC`), so
            // this is what actually starts routing once the user has granted. A
            // no-op push when nothing is routed, and still safe if they finished
            // WITHOUT granting: the guard simply refuses again, never prompting.
            self.pushAppRoutesToBackend()
            if case .permissionLost = reason {
                self.permissionAuditCooldownUntil = Date().addingTimeInterval(self.permissionAuditCooldown)
            }
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
                              surface: .groups)
        log("Open Groups (control panel)")
    }

    /// Host `content` in the ONE shared control-panel shell (control-panel
    /// rollout). Create the shell and wire its land-home `onClose` exactly once;
    /// otherwise swap its content in place (opening a different surface replaces
    /// the current one in the same shell). Hands off from the popover (close it
    /// first), records the active surface, marks the session live, and shows the
    /// shell anchored just under the menu-bar item. When the shell later closes
    /// for real, `onClose` re-presents the popover so you always land back
    /// "home" and are never stranded in a dockless void.
    @MainActor
    private func presentInControlPanel(content: NSViewController,
                                       title: String,
                                       surface: ControlPanelSurface) {
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
        shell.setContent(content)
        shell.setTitle(title)
        activePanelSurface = surface
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
            controller.onExcludedAppsChanged = { [weak self] in self?.handleExcludedAppsChanged() }
            // "Check Permissions…" (General pane) re-opens the first-run priming
            // window; the backend is already running, so its onFinished is a
            // guarded no-op.
            controller.onRunSetupAgain = { [weak self] in self?.presentSetup() }
            settingsWindowController = controller
        }
        if useControlPanel {
            presentInControlPanel(content: controller.settingsContentViewController,
                                  title: "Settings",
                                  surface: .settings)
            log("Open Settings (control panel)")
            return
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
            // The volume keys move the system output = the local "Current Device",
            // which the capture tap mutes while streaming — so they were adjusting a
            // device the user couldn't hear. Hand the fact to the routing brain, which
            // mirrors it onto the Main Out master so the keys drive what's actually
            // playing (and no-ops in passthrough, where the keys already did the job).
            //
            // This delegate is the whole reason the backend can stay below the routing
            // brain: `NativeBackend` owns the system-volume listener but must not know
            // `GroupController` exists, so it publishes the fact and this — already the
            // place backend events meet app-level controllers — does the wiring.
            groupController.mirrorSystemVolumeToMainOut(volume)
            log("event: \(describe(event))")
            // Falls through to the repaint below. The mirror's own `setVolume` calls
            // echo back as `deviceUpdated`s and repaint again with the settled values;
            // this pass just keeps the master readout honest in the meantime.
        case .routedApps(let deviceID, let appNames):
            // The live "which app streams here now" map (T6). T9: store it on the
            // popover so the device row's routing sublabel can prefer this
            // CONFIRMED signal over the intent-based one (see
            // `PopoverController.applyRoutedApps` / `DeviceRowView.apply`'s
            // `liveAppNames` doc). Falls through to the shared repaint below like
            // every other event — this call only updates state, it doesn't repaint
            // itself.
            popoverController.applyRoutedApps(deviceID: deviceID, appNames: appNames)
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
        }
        // Establish the out-of-the-box default (current device selected ⇒
        // passthrough) once the fleet is known (SPEC §9b). No-op after the first
        // time / if a persisted selection was loaded.
        groupController.ensureDefaultSelection()
        // Feed the popover (repaints open rows in place, or caches for next
        // open), then drive the status symbol from the Main Out master.
        let devices = Array(devicesByID.values)
        popoverController.update(devices: devices)
        statusItemController.updateMasterVolume(popoverController.statusMasterVolume)
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
            return "systemVolumeChanged(\(volume)) — mirroring to Main Out"
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
