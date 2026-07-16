// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore
import AirPlayControllerPopoverUI
import AirPlayControllerWindowUI

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
    private let popoverController = PopoverController()

    /// UI-agnostic mixer model (groups, proportional master, mute) shared
    /// by the menu and the mixer window (T-U4). Built lazily in
    /// `applicationDidFinishLaunching` so it binds to the resolved `backend`.
    private var groupController: GroupController!

    /// The full mixer window (SPEC §9 "Full window", T-U4). Created lazily the
    /// first time "Open Mixer…" is chosen, then reused/focused. Holds the same
    /// `GroupController` as the menu, so both views stay in lockstep.
    private var mixerWindowController: MixerWindowController?

    /// The app's device model, kept as a pure function of backend events. Keyed
    /// by `Device.id`. T-U2 reads this to build rows; for now it just backs the
    /// placeholder master-volume value the status symbol tracks.
    private var devicesByID: [String: Device] = [:]

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
        popoverController.configure(groupController: groupController)
        popoverController.onOpenMixer = { [weak self] in self?.openMixer() }

        // Subscribe BEFORE start() so we don't miss the initial `deviceAdded`
        // burst the backend emits as it enumerates what's already there.
        subscribeToBackendEvents()
        backend.start()

        log("AirPlay Controller launched (backend: \(type(of: backend)))")
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
            controller = MixerWindowController(groupController: groupController)
            mixerWindowController = controller
        }
        controller.update(devices: Array(devicesByID.values))
        controller.showWindow()
        log("Open Mixer… (window shown)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTask?.cancel()
        eventTask = nil
        backend.stop()
        log("AirPlay Controller terminating")
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
        case .level:
            // Meters are SKIPPED in Phase 1 (RESOLVED Q8) — ignore for now.
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
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[AirPlayController] \(message)\n".utf8))
    }
}
