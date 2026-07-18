// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutedCore
import AudioutedPopoverUI
import AudioutedWindowUI
import AudioutedSettingsUI
import AudioutedSharedUI

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
    private let backend: OutputBackend = makeBackend()

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
        // Redirect targets feed GroupController's connect union (an AirPlay session
        // opens the moment an app is redirected). Union of every app route's
        // .device(id:) target — non-local by construction. Assigned AFTER appRouting
        // exists (groupController was built at :98, before appRouting) — the var is
        // publicly assignable precisely to avoid this init-order cycle.
        groupController.appRouteTargets = { [weak appRouting] in
            guard let appRouting else { return [] }
            return Set(appRouting.appRoutes.compactMap { route in
                if case .device(let id) = route.destination { return id }
                return nil
            })
        }
        popoverController = PopoverController(appRouting: appRouting)
        popoverController.deviceIconController = deviceIconController
        popoverController.configure(groupController: groupController)
        popoverController.onOpenMixer = { [weak self] in self?.openMixer() }
        popoverController.onOpenSettings = { [weak self] in self?.openSettings() }
        // Excluded apps (Settings › Audio) are un-routable: the popover reads this
        // to drop them from the Applications picker + rows.
        popoverController.isAppExcluded = { [weak self] bundleID in
            self?.excludedApps.isExcluded(bundleID) ?? false
        }
        // Enforce the precedence up front: prune any persisted route for an
        // already-excluded app (e.g. excluded in a previous session).
        pruneRoutesForExcludedApps()

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
            controller = MixerWindowController(groupController: groupController,
                                               appRouting: appRouting,
                                               deviceIconController: deviceIconController)
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
        popoverController.update(devices: Array(devicesByID.values))
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

    func applicationWillTerminate(_ notification: Notification) {
        eventTask?.cancel()
        eventTask = nil
        backend.stop()
        log("Audiouted terminating")
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
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[Audiouted] \(message)\n".utf8))
    }
}
