// SPDX-License-Identifier: GPL-2.0-or-later
//
// window-snapshot — offscreen PNG renderer for the mixer window (mirrors
// `settings-snapshot`). The live window isn't visible to an agent shell, so
// this assembles the REAL `MixerWindowController` against a MockBackend-backed
// `GroupController` and renders the whole window frame (titlebar + toolbar +
// split view) via `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:)`.
//
// States rendered (light + dark each):
//   1. default   — fresh window, no groups saved (the state under critique)
//   2. draft     — after clicking the sidebar "+" (New Group editor, empty)
//   3. edit      — an existing group selected (Edit Group pane)
//
// Run: `swift run window-snapshot [output-dir]`.

import AppKit
import AudioutedCore
import AudioutedWindowUI

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("window-snapshot-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

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
func waitForFleet(_ backend: MockBackend, count: Int, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while backend.devices.count < count && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return backend.devices.count >= count
}

@MainActor
func drain(_ interval: TimeInterval = 0.15) {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
}

/// Render the WHOLE window (titlebar + toolbar + content) by snapshotting the
/// window frame view (the contentView's superview). The window is laid out but
/// never ordered in.
@MainActor
func snapshotWindow(_ window: NSWindow, label: String, appearanceName: NSAppearance.Name, outDir: URL) {
    let appearance = NSAppearance(named: appearanceName)
    window.appearance = appearance
    window.layoutIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
    drain(0.1)
    let frameView = window.contentView?.superview ?? window.contentView!
    let suffix = appearanceName == .darkAqua ? "dark" : "light"
    renderPNG(view: frameView, to: outDir.appendingPathComponent("mixer-\(label)-\(suffix).png"))
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
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()   // window-snapshot
            .deletingLastPathComponent()                     // Sources
            .deletingLastPathComponent()                     // AudioutedCore
            .deletingLastPathComponent()                     // repo root
        outDir = packageRoot.appendingPathComponent("dev/notes/window-snapshots", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    print("Rendering mixer-window snapshots to: \(outDir.path)")

    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend, store: GroupStore(directory: tempDir()),
                                         loadPersisted: false)
        let windowController = MixerWindowController(groupController: controller)
        backend.start()
        guard waitForFleet(backend, count: 7) else {
            print("SETUP FAIL: fleet did not fully discover"); return 2
        }
        windowController.update(devices: backend.devices)
        guard let window = windowController.window else {
            print("SETUP FAIL: no window"); return 2
        }
        window.setContentSize(NSSize(width: 720, height: 460))
        drain()

        // 1. Default state: no groups, mixer pane showing all devices.
        snapshotWindow(window, label: "1-default", appearanceName: appearanceName, outDir: outDir)

        // 2. New Group draft (sidebar "+" with nothing selected).
        windowController.test_tapAddGroup()
        drain()
        snapshotWindow(window, label: "2-new-group-draft", appearanceName: appearanceName, outDir: outDir)

        // 3. Edit an existing group: save one, select it.
        _ = controller.setDeviceSelected("sonos-move", true)
        _ = controller.setDeviceSelected("office", true)
        if let saved = try? controller.saveCurrentSetupAsGroup(name: "Downstairs").group {
            windowController.update(devices: backend.devices)
            windowController.test_select(.group(id: saved.id))
            drain()
            snapshotWindow(window, label: "3-edit-group", appearanceName: appearanceName, outDir: outDir)
        }
    }

    print("Done.")
    return 0
}

exit(MainActor.assumeIsolated { run() })
