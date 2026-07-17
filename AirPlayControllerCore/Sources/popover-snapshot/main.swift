// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.
//
// popover-snapshot — offscreen PNG renderer for the popover panel (the popover
// layout overhaul's visual verification). The live popover isn't visible to an
// agent shell, so this assembles the REAL `PopoverController` panel with a
// MockBackend-backed `GroupController` (the demo fleet + a saved group, one
// expanded), sizes it to the popover width, and renders it via
// `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:)`, writing PNGs to
// `dev/notes/popover-snapshots/` in BOTH light and dark appearances.
//
// T-9: the AppRoutingController is seeded with two routes BEFORE the panel is
// built, so the committed PNGs show the EXPANDED Applications card (PLAN §B —
// expanded iff >=1 app is redirected): "Music" redirected to the "office"
// AirPlay device (an active, non-dimmed slider) and "Safari" left on Current
// Device (a dimmed slider) — Safari isn't in the injected `runningAppsProvider`
// list, so its icon resolves to the generic placeholder (T-8 "not currently
// running" path).
//
// Run: `swift run popover-snapshot [output-dir]`.
//
// Set `AIRPLAY_SNAPSHOT_MODE=connection-states` to render a second scenario
// instead (`p1-connection-status-brief.md` §8): one row per
// `ConnectionState` case (connecting/connected/reconnecting/failed) with the
// failed row's diagnosis panel open, written to
// `popover-connection-{light,dark}.png`. States are set directly on hand-built
// `Device` values and pushed through `PopoverController.update(devices:)` —
// no script timing to wait on, so the render is fully deterministic.

import AppKit
import AirPlayControllerCore
import AirPlayControllerPopoverUI

@MainActor
func waitForFleet(_ backend: MockBackend, count: Int, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while backend.devices.count < count && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return backend.devices.count >= count
}

@MainActor
func drain(_ interval: TimeInterval) {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("popover-snapshot-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Render `view` (already laid out, hosted in a window) to a PNG at `url` under
/// `appearance`.
@MainActor
func renderPNG(view: NSView, to url: URL) {
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds
    guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
        print("  FAIL  could not make bitmap rep for \(url.lastPathComponent)")
        return
    }
    view.cacheDisplay(in: bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("  FAIL  could not encode PNG for \(url.lastPathComponent)")
        return
    }
    do {
        try data.write(to: url)
        print("  WROTE \(url.path)  (\(Int(bounds.width))x\(Int(bounds.height)))")
    } catch {
        print("  FAIL  write \(url.lastPathComponent): \(error)")
    }
}

@MainActor
func snapshot(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    // Construct PopoverController with AppRoutingController backed by a temp-directory
    // AppRouteStore (T-11), so the snapshot tool never touches real Application Support.
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    // T-9: seed the Applications card with two routes BEFORE the panel is built —
    // "Music" redirected to the "office" AirPlay device (active, non-dimmed
    // slider) and "Safari" left on Current Device (dimmed slider). Only "Music"
    // is in the injected runningAppsProvider list, so Safari's icon resolves to
    // the generic placeholder (T-8 "not currently running" path).
    let musicBundleID = "com.apple.Music"
    let safariBundleID = "com.apple.Safari"
    appRouting.addRoute(bundleID: musicBundleID, displayName: "Music")
    appRouting.setDestination(.device(id: "office"), for: musicBundleID)
    appRouting.setVolume(70, for: musicBundleID)
    appRouting.addRoute(bundleID: safariBundleID, displayName: "Safari")
    // Safari stays on Current Device (the default destination) at volume 100.

    let runningApps = [RunningAppInfo(bundleID: musicBundleID, displayName: "Music", icon: nil)]
    let popover = PopoverController(appRouting: appRouting, runningAppsProvider: { runningApps })
    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("  SETUP FAIL: fleet did not fully discover"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()

    // Compose a couple of AirPlay devices into the Selected Devices set (the
    // popover no longer renders a Groups section, so we just populate the
    // Selected Devices set for the snapshot).
    _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
    _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
    _ = popover.test_toggleDeviceEnabled(deviceID: "sonos-move", on: true)
    popover.update(devices: backend.devices)
    popover.test_simulateOpen()   // reopen-style rebuild so the Applications card expands

    // Host the assembled panel in an offscreen window so the card materials /
    // vibrancy render, under the requested appearance.
    let appearance = NSAppearance(named: appearanceName)
    let panelView = popover.test_panelView
    panelView.appearance = appearance
    panelView.layoutSubtreeIfNeeded()
    let size = panelView.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: frame,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentView?.addSubview(panelView)
    panelView.frame = frame
    window.setContentSize(size)
    window.layoutIfNeeded()
    panelView.layoutSubtreeIfNeeded()
    drain(0.1)

    let url = outDir.appendingPathComponent("popover-\(label).png")
    renderPNG(view: panelView, to: url)
    window.contentView = NSView()   // detach so the next run gets a fresh panel
}

/// A small fleet with one row per `ConnectionState` case, for the
/// `connection-states` snapshot mode. Each device's name says what it's
/// demoing so the PNG is self-explanatory without cross-referencing code. This
/// now exercises the on-icon corner dot (2026-07-17): `.off` hides it,
/// `.connecting`/`.reconnecting` breathe a neutral dot, `.connected` a green
/// dot, `.failed` an amber dot with the "Couldn't connect" sublabel.
private var connectionStatesFleet: [Device] {
    [
        Device(id: "cs-off", name: "Idle Speaker", kind: .generic,
               volume: 40, connectionState: .off),
        Device(id: "cs-connecting", name: "Connecting Speaker", kind: .sonos,
               volume: 45, connectionState: .connecting),
        Device(id: "cs-connected", name: "Connected Speaker", kind: .homePod,
               volume: 60, isSelected: true, connectionState: .connected),
        Device(id: "cs-reconnecting", name: "Reconnecting Speaker", kind: .appleTV,
               volume: 50, isSelected: true, connectionState: .reconnecting),
        Device(id: "cs-failed", name: "Failed Speaker", kind: .airportExpress,
               supportsAirPlay2: false, volume: 30,
               connectionState: .failed(ConnectionFailure(cause: .notResponding))),
    ]
}

/// Render the `connection-states` scenario (brief §8): one row per
/// `ConnectionState` case, with the failed row's diagnosis panel open. Bypasses
/// `ConnectScript` timing entirely — the fleet's `Device` values already carry
/// their target `connectionState`, so a single `update(devices:)` call is all
/// it takes for the panel to reconcile (including the auto-expand-once-on-
/// `.failed` transition in `PopoverController`).
@MainActor
func snapshotConnectionStates(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let fleet = connectionStatesFleet
    let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let popover = PopoverController()
    backend.start()
    guard waitForFleet(backend, count: fleet.count) else {
        print("  SETUP FAIL: fleet did not fully discover"); return
    }
    popover.configure(groupController: controller)

    // Membership in the Selected Devices set drives the switch (never
    // `connectionState` directly — §7.3 "honest toggle"). `.connecting`/
    // `.connected`/`.reconnecting` are all still "expected selected"; only
    // `.failed` should render OFF, and that bounce-off happens for free below
    // via the real `.off → .failed` transition handling.
    for device in fleet {
        guard case .failed = device.connectionState else {
            _ = popover.test_toggleDeviceEnabled(deviceID: device.id, on: true)
            continue
        }
    }

    // Push the fleet's explicit connection states straight through — this is
    // also what auto-expands the failed row's diagnosis panel (§7.3: the
    // `.off → .failed` transition on this first `update` call).
    popover.update(devices: fleet)

    let appearance = NSAppearance(named: appearanceName)
    let panelView = popover.test_panelView
    panelView.appearance = appearance
    panelView.layoutSubtreeIfNeeded()
    let size = panelView.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: frame,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentView?.addSubview(panelView)
    panelView.frame = frame
    window.setContentSize(size)
    window.layoutIfNeeded()
    panelView.layoutSubtreeIfNeeded()
    drain(0.1)

    let url = outDir.appendingPathComponent("popover-connection-\(label).png")
    renderPNG(view: panelView, to: url)
    window.contentView = NSView()
}

/// Render the T9 `live-routing` scenario: the device-row precedence between
/// the CONFIRMED live streaming signal (`BackendEvent.routedApps`, fired here
/// via `MockBackend.test_emitRoutedApps` — the offline fixture, since
/// `MockBackend` has no real per-app streaming) and the intent-based routing
/// label. Two app routes are seeded so the two rungs are visible side by
/// side in one panel:
///   - "office": redirected to Music AND given a live `.routedApps` event ⇒
///     its row shows the CONFIRMED label ("Music").
///   - "homepod-bed": redirected to Safari but given NO live event ⇒ its row
///     falls back to the INTENT-based label ("Safari"), demonstrating the
///     "routed but not yet confirmed streaming" fallback case.
@MainActor
func snapshotLiveRouting(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let musicBundleID = "com.apple.Music"
    let safariBundleID = "com.apple.Safari"
    appRouting.addRoute(bundleID: musicBundleID, displayName: "Music")
    appRouting.setDestination(.device(id: "office"), for: musicBundleID)
    appRouting.addRoute(bundleID: safariBundleID, displayName: "Safari")
    appRouting.setDestination(.device(id: "homepod-bed"), for: safariBundleID)

    let runningApps = [
        RunningAppInfo(bundleID: musicBundleID, displayName: "Music", icon: nil),
        RunningAppInfo(bundleID: safariBundleID, displayName: "Safari", icon: nil),
    ]
    let popover = PopoverController(appRouting: appRouting, runningAppsProvider: { runningApps })
    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("  SETUP FAIL: fleet did not fully discover"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()

    // "office" gets a CONFIRMED live signal via the T9 MockBackend fixture;
    // "homepod-bed" deliberately does NOT, so its row stays on the
    // intent-based fallback label for comparison in the same panel.
    popover.applyRoutedApps(deviceID: "office", appNames: ["Music"])
    popover.update(devices: backend.devices)
    popover.test_simulateOpen()   // reopen-style rebuild so the Applications card expands

    let appearance = NSAppearance(named: appearanceName)
    let panelView = popover.test_panelView
    panelView.appearance = appearance
    panelView.layoutSubtreeIfNeeded()
    let size = panelView.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: frame,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentView?.addSubview(panelView)
    panelView.frame = frame
    window.setContentSize(size)
    window.layoutIfNeeded()
    panelView.layoutSubtreeIfNeeded()
    drain(0.1)

    let url = outDir.appendingPathComponent("popover-live-routing-\(label).png")
    renderPNG(view: panelView, to: url)
    window.contentView = NSView()
}

@MainActor
func run() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let args = CommandLine.arguments
    let outDir: URL
    if args.count > 1 {
        outDir = URL(fileURLWithPath: args[1])
    } else {
        // Default: dev/notes/popover-snapshots relative to the package root.
        // The package root is two levels up from Sources/popover-snapshot.
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()   // popover-snapshot
            .deletingLastPathComponent()                     // Sources
            .deletingLastPathComponent()                     // AirPlayControllerCore
            .deletingLastPathComponent()                     // repo root
        outDir = packageRoot.appendingPathComponent("dev/notes/popover-snapshots", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    print("Rendering popover snapshots to: \(outDir.path)")

    // Mode switch, matching the mock scenario knob's convention
    // (`AIRPLAY_MOCK_SCENARIO`): env var selects an alternate render, default
    // mode is unaffected. See brief §8.
    let mode = ProcessInfo.processInfo.environment["AIRPLAY_SNAPSHOT_MODE"]
    if mode == "connection-states" {
        snapshotConnectionStates(appearanceName: .aqua, label: "light", outDir: outDir)
        snapshotConnectionStates(appearanceName: .darkAqua, label: "dark", outDir: outDir)
        print("Done.")
        return 0
    }
    if mode == "live-routing" {
        snapshotLiveRouting(appearanceName: .aqua, label: "light", outDir: outDir)
        snapshotLiveRouting(appearanceName: .darkAqua, label: "dark", outDir: outDir)
        print("Done.")
        return 0
    }

    snapshot(appearanceName: .aqua, label: "light", outDir: outDir)
    snapshot(appearanceName: .darkAqua, label: "dark", outDir: outDir)

    print("Done.")
    return 0
}

exit(MainActor.assumeIsolated { run() })
