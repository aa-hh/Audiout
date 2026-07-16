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
// Run: `swift run popover-snapshot [output-dir]`.

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
    let popover = PopoverController()
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

    snapshot(appearanceName: .aqua, label: "light", outDir: outDir)
    snapshot(appearanceName: .darkAqua, label: "dark", outDir: outDir)

    print("Done.")
    return 0
}

exit(MainActor.assumeIsolated { run() })
