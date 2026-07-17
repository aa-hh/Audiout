// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.
//
// settings-snapshot — offscreen PNG renderer for the Settings window (mirrors
// `popover-snapshot`). The live window isn't visible to an agent shell — and
// this app is a menu-bar accessory (`.accessory` activation policy, no Dock
// icon), which also puts it outside computer-use's app resolver — so this
// assembles the REAL `SettingsWindowController` against fake seams (never
// touching the real login item or `~/Library/Application Support`), sizes it
// to its own fitted content, and renders it via
// `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:)`, writing a PNG
// to `dev/notes/settings-snapshots/` in both light and dark appearances.
//
// Run: `swift run settings-snapshot [output-dir]`.

import AppKit
import AirPlayControllerCore
import AirPlayControllerSettingsUI

/// A `LoginItemManaging` fake so the snapshot never touches `SMAppService`.
final class SnapshotLoginItem: LoginItemManaging {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-snapshot-\(UUID().uuidString)", isDirectory: true)
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
func snapshot(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let settingsDefaults = UserDefaults(suiteName: "settings-snapshot-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: settingsDefaults)
    let excludedApps = ExcludedAppsController(store: ExcludedAppsStore(directory: tempDir()), loadPersisted: false)
    // Seed one excluded app so the Audio section shows a non-empty list, not
    // just the "Add application…" empty state.
    excludedApps.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")

    let controller = SettingsWindowController(
        settings: settings,
        loginItem: SnapshotLoginItem(),
        excludedApps: excludedApps,
        runningAppsProvider: { [] })

    let appearance = NSAppearance(named: appearanceName)
    let rootView = controller.test_rootView
    rootView.appearance = appearance
    rootView.layoutSubtreeIfNeeded()
    let size = rootView.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentView?.addSubview(rootView)
    rootView.frame = frame
    window.setContentSize(size)
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()

    let url = outDir.appendingPathComponent("settings-\(label).png")
    renderPNG(view: rootView, to: url)
    window.contentView = NSView()   // detach so nothing dangles
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
        let packageRoot = here.deletingLastPathComponent()   // settings-snapshot
            .deletingLastPathComponent()                     // Sources
            .deletingLastPathComponent()                     // AirPlayControllerCore
            .deletingLastPathComponent()                     // repo root
        outDir = packageRoot.appendingPathComponent("dev/notes/settings-snapshots", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    print("Rendering settings snapshots to: \(outDir.path)")

    snapshot(appearanceName: .aqua, label: "light", outDir: outDir)
    snapshot(appearanceName: .darkAqua, label: "dark", outDir: outDir)

    print("Done.")
    return 0
}

exit(MainActor.assumeIsolated { run() })
