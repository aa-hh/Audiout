// SPDX-License-Identifier: GPL-2.0-or-later
//
// settings-snapshot — offscreen PNG renderer for the Settings panes (mirrors
// `popover-snapshot`). The live surface isn't visible to an agent shell — and
// this app is a menu-bar accessory (`.accessory` activation policy, no Dock
// icon), which also puts it outside computer-use's app resolver — so this
// assembles the REAL `SettingsRootViewController` against fake seams (never
// touching the real login item or `~/Library/Application Support`) and
// renders each pane via a pinned-scale bitmap rep + `cacheDisplay(in:)`,
// writing a PNG to `dev/notes/settings-snapshots/` in both light and dark
// appearances.
//
// Settings is SIDEBAR content (General / Appearance / Audio sections, one
// pane) hosted on the one-surface shell. Each render below is the PANE only —
// the sidebar and the surface's chrome are deliberately absent. These goldens
// verify each pane's own layout and dark-mode appearance; the sidebar itself
// (labels, symbols, selection) is covered by the `SettingsRootViewController`
// tests, not a pixel snapshot.
//
// One PNG per (tab × appearance) — six total:
//   settings-{general,appearance,audio}-{light,dark}.png
//
// Run: `swift run settings-snapshot [output-dir]`.

import AppKit
import AudioutCore
import AudioutSettingsUI

/// Resolve `name` AND pin it as the app-level appearance. On Darwin 27,
/// system-drawn artwork (source-list selection pills, segmented controls)
/// resolves against the APP's effective appearance, so per-window/view
/// overrides alone leave those pieces rendered in the host system's mode
/// (found via window-snapshot's light captures on a dark-mode host).
@MainActor
func snapshotAppearance(_ name: NSAppearance.Name) -> NSAppearance? {
    let appearance = NSAppearance(named: name)
    NSApp.appearance = appearance
    return appearance
}

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

/// Fixed backing scale for every snapshot PNG (visual.md M1). Letting the OS
/// pick the scale (`bitmapImageRepForCachingDisplay(in:)`) makes the pixel
/// dimensions of the output drift by machine — 1x on a non-Retina/headless
/// display, 2x on a Retina one — even though this window is never actually
/// ordered onto a screen. Building the bitmap rep directly at a pinned scale
/// makes the resolution deterministic regardless of what's driving the run.
let snapshotBackingScale: CGFloat = 2

@MainActor
func renderPNG(view: NSView, to url: URL) {
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds
    let pixelsWide = Int((bounds.width * snapshotBackingScale).rounded())
    let pixelsHigh = Int((bounds.height * snapshotBackingScale).rounded())
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide,
                                      pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        print("  FAIL  could not make bitmap rep for \(url.lastPathComponent)")
        return
    }
    rep.size = bounds.size
    // `NSBitmapImageRep(bitmapDataPlanes:...)` doesn't guarantee a zeroed
    // buffer (unlike `bitmapImageRepForCachingDisplay(in:)`) — zero it so any
    // region `cacheDisplay` doesn't fully repaint has defined (transparent)
    // content instead of stale heap bytes.
    if let bitmapData = rep.bitmapData {
        memset(bitmapData, 0, rep.bytesPerRow * pixelsHigh)
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

/// Name of the throwaway defaults suite these fixtures write to instead of the
/// developer's real domain. FIXED, not per-run: `UserDefaults(suiteName:)`
/// creates a real `~/Library/Preferences/<name>.plist`, so a `UUID` in the name
/// leaves one behind on every run. One reused name plus a wipe before each use
/// keeps the fixtures identical run to run at a cost of one plist, ever.
let snapshotDefaultsSuite = "settings-snapshot"

@MainActor
func makeSnapshotDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: snapshotDefaultsSuite)!
    defaults.removePersistentDomain(forName: snapshotDefaultsSuite)
    return defaults
}

/// Assembles a fresh `SettingsRootViewController` against fake seams — same
/// fixtures every time (empty `UserDefaults` suite, temp excluded-apps store
/// seeded with one entry so the Audio pane isn't captured in its empty
/// state, a non-nil `LatencySettingModel` so the Audio pane's Advanced ›
/// Audio buffer section renders).
///
/// A NEW controller per call is required, not an optimization:
/// `paneView(at:)` must run before the controller has ever been shown or
/// selected another section (see `snapshotTab` below), so no controller here
/// is ever reused across two snapshots.
@MainActor
func makeRoot() -> SettingsRootViewController {
    let settings = AppSettings(defaults: makeSnapshotDefaults())
    let excludedApps = ExcludedAppsController(store: ExcludedAppsStore(directory: tempDir()), loadPersisted: false)
    // Seed one excluded app so the Audio section shows a non-empty list, not
    // just the "Add application…" empty state.
    excludedApps.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")

    // Advanced › Audio buffer (PLAN-LATENCY-SETTING.md): render the section so
    // its layout/dark-mode/light-mode appearance is checkable, same as every
    // other control on this pane.
    let latency = LatencySettingModel(
        optionsMs: AppSettings.startBufferOptionsMs,
        initialMs: AppSettings.defaultStartBufferMs,
        envOverrideMs: nil,
        isStreaming: { false },
        apply: { _ in (0, 0) })

    // Section order/labels/symbols mirror the app's own assembly
    // (`AppDelegate.makeSettingsRoot`) exactly.
    return SettingsRootViewController(sections: [
        .init(title: "General", symbolName: "gearshape",
              viewController: GeneralSettingsViewController(loginItem: SnapshotLoginItem(),
                                                            settings: settings)),
        .init(title: "Appearance", symbolName: "paintpalette",
              viewController: AppearanceSettingsViewController(settings: settings)),
        .init(title: "Audio", symbolName: "speaker.wave.2",
              viewController: AudioSettingsViewController(excluded: excludedApps,
                                                          runningAppsProvider: { [] },
                                                          latency: latency)),
    ])
}

/// Resolve every wrapping label's `preferredMaxLayoutWidth` from the width it
/// has actually been given.
///
/// Multiline `NSTextField`s report a single-line intrinsic width until this is
/// set. The Audio pane's "Connects at N% …" hint wants 521pt on one line,
/// which drags the whole pane to 561pt — wider than the 460pt window it ships
/// in. A live window hides this because a real display cycle re-wraps the
/// label; a one-shot offscreen render has no such cycle, so the wrap width is
/// pinned here explicitly before anything is measured.
@MainActor
func resolveWrapWidths(_ view: NSView) {
    if let field = view as? NSTextField,
       !field.cell!.usesSingleLineMode,
       field.cell!.wraps,
       field.frame.width > 0 {
        field.preferredMaxLayoutWidth = field.frame.width
    }
    for sub in view.subviews { resolveWrapWidths(sub) }
}

/// Render one tab's pane, in one appearance, to
/// `settings-{tabLabel}-{appearanceLabel}.png`.
///
/// **Pin the pane with CONSTRAINTS, never by assigning `frame`.** Panes come
/// from `SettingsForm.paneView(rows:)` with
/// `translatesAutoresizingMaskIntoConstraints = false`, so an assigned frame
/// is advisory — the layout engine overwrites it at the next pass, and
/// `cacheDisplay` runs exactly such a pass. Measure after a manual frame set
/// and the numbers describe a wrapped 460pt layout while the PNG draws the
/// unwrapped, clipped one the engine settled on.
///
/// The sequence below is load-bearing: size to `contentWidth` FIRST, resolve
/// wrap widths at that width, and only then measure the height. Measuring
/// before the wrap resolves reports a pane 561pt wide — wider than the window
/// it ships in.
///
/// A fresh controller per snapshot (see `makeRoot()`) keeps each render
/// independent of tab order and of any size a previous tab left behind.
@MainActor
func snapshotTab(index: Int, tabLabel: String, appearanceName: NSAppearance.Name, appearanceLabel: String, outDir: URL) {
    // Mirrors `SettingsForm.contentWidth` (= `SurfaceLayout.contentPaneWidth`),
    // which is internal to AudioutSettingsUI. Any drift shows up at once as
    // a changed golden width.
    let contentWidth: CGFloat = 413
    let root = makeRoot()
    let appearance = snapshotAppearance(appearanceName)
    let paneView = root.paneView(at: index)
    paneView.removeFromSuperview()

    // Mirror `SettingsRootViewController`'s opaque, appearance-adaptive
    // backing. That `WarmPanelView` is the pane host's root view inside the
    // root controller (an `NSSplitViewController`), so a pane grabbed directly
    // bypasses it — without it the controls draw light-adapted text over a
    // transparent window in dark mode.
    let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 100))
    background.material = .windowBackground
    background.blendingMode = .behindWindow
    background.state = .followsWindowActiveState
    background.appearance = appearance
    background.autoresizingMask = [.width, .height]

    paneView.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(paneView)
    NSLayoutConstraint.activate([
        paneView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
        paneView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        paneView.topAnchor.constraint(equalTo: background.topAnchor),
        paneView.widthAnchor.constraint(equalToConstant: contentWidth),
    ])

    // Lay out at the shipping width, resolve the wraps that width implies,
    // then let the settled height fall out of it.
    background.layoutSubtreeIfNeeded()
    resolveWrapWidths(paneView)
    background.layoutSubtreeIfNeeded()

    let height = paneView.fittingSize.height
    let frame = NSRect(x: 0, y: 0, width: contentWidth, height: height)
    background.frame = frame

    // Host in a borderless offscreen window so the visual-effect material
    // resolves; the window is sized to the already-settled content, never the
    // other way round.
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = background
    background.layoutSubtreeIfNeeded()

    let url = outDir.appendingPathComponent("settings-\(tabLabel)-\(appearanceLabel).png")
    renderPNG(view: background, to: url)
    window.contentView = NSView()   // detach so nothing dangles
}

@MainActor
func run() -> Int32 {
    // Never show a real window on the developer's screen while this
    // headless tool runs (`HeadlessRuntime` in AudioutCore) — set BEFORE
    // touching AppKit.
    setenv("AIRPLAY_HEADLESS", "1", 1)
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
            .deletingLastPathComponent()                     // AudioutCore
            .deletingLastPathComponent()                     // repo root
        outDir = packageRoot.appendingPathComponent("dev/notes/settings-snapshots", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    print("Rendering settings snapshots to: \(outDir.path)")

    // Superseded single-pane goldens from the one-screen (pre-tab) design —
    // the tabbed window has no single "the content" view, so these no longer
    // represent any real screen. Remove them so a stale golden can't linger
    // next to the six per-tab ones below.
    for stale in ["settings-light.png", "settings-dark.png"] {
        try? FileManager.default.removeItem(at: outDir.appendingPathComponent(stale))
    }

    // Tab order/labels mirror `makeRoot()`'s tabs literal exactly.
    let tabs: [(index: Int, label: String)] = [
        (0, "general"),
        (1, "appearance"),
        (2, "audio"),
    ]
    let appearances: [(name: NSAppearance.Name, label: String)] = [
        (.aqua, "light"),
        (.darkAqua, "dark"),
    ]

    for tab in tabs {
        for appearance in appearances {
            snapshotTab(index: tab.index, tabLabel: tab.label,
                        appearanceName: appearance.name, appearanceLabel: appearance.label,
                        outDir: outDir)
        }
    }

    print("Done.")
    return 0
}

exit(MainActor.assumeIsolated { run() })
