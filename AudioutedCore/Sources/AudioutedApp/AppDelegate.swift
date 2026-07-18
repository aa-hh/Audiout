// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutedCore
import AudioutedPopoverUI
import AudioutedWindowUI
import AudioutedSettingsUI

/// Writes `message` to `STDERR_FILENO` with a raw `write(2)`, retrying on
/// `EINTR` and otherwise ignoring failures.
///
/// `FileHandle.write(_:)` raises an uncatchable `NSException` (not a Swift
/// error) when the underlying fd is closed or broken — e.g. a dev launch
/// from a terminal whose pipe has gone away. That turns routine logging into
/// a crash. This helper never throws and never raises: a lost log line is
/// acceptable, a crashed logger is not. Shared by `main.swift`'s uncaught
/// exception handler and `AppDelegate.log(_:)`.
func audioutedEmergencyWriteStderr(_ message: String) {
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

/// Resolve a bundle ID to the pid of a running instance, or nil if it isn't
/// running (T7). This is the real per-app-capture resolver the native backend
/// needs: Core can't import AppKit (`NSRunningApplication`), so the AppKit layer
/// supplies it via `makeBackend(resolvePID:)`. A free `@Sendable` closure (not an
/// instance method) so it can be used in `AppDelegate`'s `backend` property
/// initializer, which runs before `self` exists.
private let resolveRunningAppPID: @Sendable (String) -> pid_t? = { bundleID in
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first?.processIdentifier
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
    /// `makeBackend()`: explicit arg (none) → `AIRPLAY_BACKEND` env → `.mock`.
    /// Everything downstream holds an `OutputBackend`, never a concrete type.
    /// `resolvePID` threads the real `NSRunningApplication`-backed resolver into
    /// the native backend's per-app capture path (T7).
    private let backend: OutputBackend = makeBackend(resolvePID: resolveRunningAppPID)

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

    /// Per-app routing model (Applications card). Held here (not just handed to
    /// the popover) so the app can enforce the excluded-apps precedence — pruning
    /// a route when its app is excluded.
    private var appRouting: AppRoutingController!

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
        // The button's action toggles the popover (SPEC §9 revised).
        statusItemController = StatusItemController()
        statusItemController.onButtonClicked = { [weak self] button in
            self?.popoverController.toggle(relativeTo: button)
        }

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
        popoverController.configure(groupController: groupController)
        popoverController.onOpenMixer = { [weak self] in self?.openMixer() }
        popoverController.onOpenSettings = { [weak self] in self?.openSettings() }
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

        // T8 (edge case 1): a routed app can quit mid-stream without its route
        // ever changing (the route is left in place so relaunching the app
        // resumes it — see `NativeBackend.handleAppTerminated`'s doc comment), so
        // `onRoutesDidChange` never fires for this. Core can't observe AppKit
        // notifications itself, so this is the one place that forwards the quit
        // across the boundary. Never explicitly removed: this observer's lifetime
        // is the app's own (AppDelegate is never deallocated before termination).
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

        // Subscribe BEFORE start() so we don't miss the initial `deviceAdded`
        // burst the backend emits as it enumerates what's already there.
        subscribeToBackendEvents()
        backend.start()

        log("Audiouted launched (backend: \(type(of: backend)))")
    }

    /// "Open Mixer…" target — open/focus the full mixer window (SPEC §9, T-U4).
    /// Lazily built on first use, then reused; seeded with the current device
    /// snapshot so it's correct the instant it appears. Shares the app's one
    /// `GroupController`, so menu and window never diverge.
    @MainActor
    private func openMixer() {
        let controller: MixerWindowController
        if let existing = mixerWindowController {
            controller = existing
        } else {
            controller = MixerWindowController(groupController: groupController, appRouting: appRouting)
            mixerWindowController = controller
        }
        controller.update(devices: Array(devicesByID.values))
        controller.showWindow()
        log("Open Mixer… (window shown)")
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
                                                  latency: makeLatencySettingModel())
            controller.onThemeChanged = { [weak self] theme in self?.applyAppearance(theme) }
            controller.onExcludedAppsChanged = { [weak self] in self?.handleExcludedAppsChanged() }
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
        log("Audiouted terminating")

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
        case .systemVolumeChanged(let volume):
            return "systemVolumeChanged(\(volume)) — mirroring to Main Out"
        case .routedApps(let deviceID, let appNames):
            return "routedApps(\(deviceID), [\(appNames.joined(separator: ", "))])"
        case .routedAppRunning(let bundleID, let isRunning):
            return "routedAppRunning(\(bundleID), isRunning: \(isRunning))"
        }
    }

    private func log(_ message: String) {
        audioutedEmergencyWriteStderr("[Audiouted] \(message)\n")
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
