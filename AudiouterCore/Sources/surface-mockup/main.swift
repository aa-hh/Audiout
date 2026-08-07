// SPDX-License-Identifier: GPL-2.0-or-later
//
// surface-mockup — a RUNNABLE visual prototype of the one-surface window
// described in `docs/plans/PLAN-ONE-SURFACE-032.md` ("End state": tab-bar
// switcher + three-tier translucent header). It exists so the design can be
// looked at on a real Mac before the production unification (Wave 2) lands.
//
// THROWAWAY. It only ADDS files: the shell (`ControlPanelWindowController`),
// the Mixer panel, the Groups split view and the Settings panes are all the
// real production views, instantiated against mock/fake seams and hosted
// unmodified. Nothing here is linked by `AudiouterApp`, and no production
// source is edited to make it work — so the unification that replaces it can
// land on those same files without ever colliding with this target.
//
// What it demonstrates, and what it deliberately fakes:
//   REAL — the shell's warm bubble + beak, anchored under a fake status-item
//          rect; the Mixer panel wired to `MockBackend`; the Groups content
//          controller; the Settings panes; the three header material tiers.
//   FAKE — the pin flip is window-property manners changed from OUTSIDE the
//          shell (no frame persistence, no click policy); the tab bar, its
//          metrics and the theme switch are prototype-owned code that Wave 2
//          will re-implement properly in `PopoverHeaderView`.
//
// Run:      AIRPLAY_BACKEND=mock swift run --package-path AudiouterCore surface-mockup
// Capture:  AIRPLAY_BACKEND=mock swift run --package-path AudiouterCore surface-mockup --snapshot [dir]

import AppKit
import AudiouterCore
import AudiouterPopoverUI
import AudiouterSettingsUI
import AudiouterSharedUI
import AudiouterWindowUI

// MARK: - Fixtures

/// A `LoginItemManaging` fake so the prototype never touches `SMAppService`.
final class MockupLoginItem: LoginItemManaging {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("surface-mockup-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
func waitForFleet(_ backend: MockBackend, count: Int, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while backend.devices.count < count && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return backend.devices.count >= count
}

/// Everything the three screens need, kept alive for the process's lifetime —
/// the screens hold only the VIEWS, and a released controller takes its view
/// tree's targets with it.
@MainActor
final class Fixtures {
    let backend: MockBackend
    let groupController: GroupController
    let popover: PopoverController
    let mixerWindow: MixerWindowController
    let settingsWindow: SettingsWindowController

    init() {
        backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: true, simulatesDropouts: false)
        groupController = GroupController(backend: backend,
                                          store: GroupStore(directory: tempDir()),
                                          routingStore: RoutingStore(directory: tempDir()),
                                          loadPersisted: false)
        popover = PopoverController(
            appRouting: AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                             loadPersisted: false))
        mixerWindow = MixerWindowController(groupController: groupController)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "surface-mockup-\(UUID().uuidString)")!)
        let excludedApps = ExcludedAppsController(store: ExcludedAppsStore(directory: tempDir()),
                                                  loadPersisted: false)
        excludedApps.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")
        settingsWindow = SettingsWindowController(
            settings: settings,
            loginItem: MockupLoginItem(),
            excludedApps: excludedApps,
            runningAppsProvider: { [] },
            latency: LatencySettingModel(optionsMs: AppSettings.startBufferOptionsMs,
                                         initialMs: AppSettings.defaultStartBufferMs,
                                         envOverrideMs: nil,
                                         isStreaming: { false },
                                         apply: { _ in }))
    }

    /// Bring the mock fleet up and push it through every screen.
    func start() {
        // A closed popover deliberately never rebuilds on `update(devices:)`
        // (audit B8); this host isn't an NSPopover, so opt into the
        // shown-repaint path through the designated headless hook.
        popover.test_isShownOverride = true
        backend.start()
        _ = waitForFleet(backend, count: 7)
        popover.configure(groupController: groupController)
        groupController.ensureDefaultSelection()
        popover.update(devices: backend.devices)
        mixerWindow.update(devices: backend.devices)
        seedGroups()
    }

    /// Two saved groups so the Groups screen shows a populated sidebar and a
    /// real editor rather than its empty state.
    private func seedGroups() {
        let ids = backend.devices.map(\.id)
        guard ids.count >= 4 else { return }
        _ = try? groupController.createGroup(name: "Downstairs", memberIDs: Array(ids[1...2]))
        _ = try? groupController.createGroup(name: "Whole House", memberIDs: Array(ids[1...3]))
        mixerWindow.update(devices: backend.devices)
    }

    /// The Mixer screen's content: the REAL assembled popover panel view.
    /// Its own header row is hidden — the prototype's tab bar replaces exactly
    /// that row (plan U3), so leaving both would show two sets of
    /// Groups/Settings/Quit controls.
    /// Also reports how tall that hidden row is, so the screen can scroll the
    /// dead strip it still reserves under the glass.
    var mixerContent: (view: NSView, topTrim: CGFloat) {
        // The `NSPopover` owns the panel view controller until told otherwise,
        // and reclaims its view out of any foreign superview at the next layout
        // pass — the view goes silently missing. Release its claim first; the
        // controller itself is retained by `PopoverController`, so nothing is
        // torn down. Plan U7 deletes this popover outright.
        popover.popover.contentViewController = nil
        let panel = popover.test_panelView
        return (panel, hidePopoverHeaderRow(in: panel) ?? 0)
    }

    /// The Groups screen's content: the real split view the standalone Groups
    /// window hosts, handed over by the seam the plan already relies on.
    var groupsContent: NSView { mixerWindow.contentController.view }

    /// The Settings screen's content: the real tabbed settings root, detached
    /// from its own window for the same reclaim reason as `mixerContent`.
    var settingsContent: NSView {
        let root = settingsWindow.test_rootView
        settingsWindow.window?.contentViewController = nil
        root.removeFromSuperview()
        return root
    }
}

/// Hide `PopoverHeaderView` and report its height — internal to
/// `AudiouterPopoverUI`, so matched by class name rather than by type. A
/// prototype-grade reach into a view tree the target does not own; Wave 2
/// replaces that row for real. It is hidden rather than removed because the
/// panel's stack hangs its top constraint off it.
@MainActor
@discardableResult
func hidePopoverHeaderRow(in view: NSView) -> CGFloat? {
    if String(describing: type(of: view)) == "PopoverHeaderView" {
        view.isHidden = true
        return view.frame.height
    }
    for subview in view.subviews {
        if let height = hidePopoverHeaderRow(in: subview) { return height }
    }
    return nil
}

// MARK: - Snapshots

/// Fixed backing scale so the PNGs' pixel dimensions don't drift by machine —
/// the same reasoning as `popover-snapshot` / `settings-snapshot`.
let snapshotBackingScale: CGFloat = 2

/// Mark the whole tree as needing display, so `cacheDisplay` redraws rather
/// than compositing whatever a layer happens to hold.
@MainActor
func markNeedsDisplay(_ view: NSView) {
    view.needsDisplay = true
    for subview in view.subviews { markNeedsDisplay(subview) }
}

/// Render one view on its own with `cacheDisplay(in:to:)`, the primitive the
/// package's other snapshot generators use.
@MainActor
func capture(_ view: NSView) -> CGImage? {
    view.layoutSubtreeIfNeeded()
    markNeedsDisplay(view)
    let bounds = view.bounds
    let pixelsWide = Int((bounds.width * snapshotBackingScale).rounded())
    let pixelsHigh = Int((bounds.height * snapshotBackingScale).rounded())
    guard pixelsWide > 0, pixelsHigh > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide,
                                     pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        return nil
    }
    rep.size = bounds.size
    // `NSBitmapImageRep(bitmapDataPlanes:…)` doesn't guarantee a zeroed buffer,
    // so any region `cacheDisplay` skips would otherwise be stale heap bytes.
    if let bitmapData = rep.bitmapData {
        memset(bitmapData, 0, rep.bytesPerRow * pixelsHigh)
    }
    view.cacheDisplay(in: bounds, to: rep)
    return rep.cgImage
}

/// Composite one screen into a PNG.
///
/// A single `cacheDisplay` on the screen's root view returns a blank canvas:
/// this surface is layer-backed all the way down, and `cacheDisplay` does not
/// traverse into `NSClipView`'s or `NSSplitView`'s own layer subtree — only the
/// top-level control cells come through. (`CALayer.render(in:)` fares worse,
/// and ordering the window on screen first changes nothing.) So each piece is
/// captured on its own — where the primitive works fine — and drawn at its
/// frame in root coordinates, the composite idiom `window-snapshot` already
/// uses for the shell's two windows.
@MainActor
func renderScreenPNG(_ screen: SurfaceScreenViewController, to url: URL) {
    let root = screen.view
    root.layoutSubtreeIfNeeded()
    let bounds = root.bounds
    let pixelsWide = Int((bounds.width * snapshotBackingScale).rounded())
    let pixelsHigh = Int((bounds.height * snapshotBackingScale).rounded())
    guard pixelsWide > 0, pixelsHigh > 0,
          let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("  FAIL  could not make a bitmap context for \(url.lastPathComponent)")
        return
    }
    context.scaleBy(x: snapshotBackingScale, y: snapshotBackingScale)
    for piece in screen.snapshotPieces {
        guard let image = capture(piece) else { continue }
        context.draw(image, in: piece.convert(piece.bounds, to: root))
    }

    guard let composite = context.makeImage() else {
        print("  FAIL  could not composite \(url.lastPathComponent)")
        return
    }
    let rep = NSBitmapImageRep(cgImage: composite)
    rep.size = bounds.size
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

/// Capture every (screen × theme) combination. `cacheDisplay` re-draws each
/// view rather than reading back a composited window, so the glass header comes
/// out as its own material fallback rather than as live glass — expected, and
/// the reason the run prints the tier it actually resolved to.
@MainActor
func runSnapshots(_ controller: SurfaceMockupController, outDir: URL) -> Int32 {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    print("Header material tier: \(controller.headerTierDescription)")
    controller.animatesResize = false
    controller.show()
    for theme in MockupTheme.allCases {
        controller.setTheme(theme)
        for tab in SurfaceTab.allCases {
            controller.select(tab)
            guard let screen = controller.screen(tab) else { continue }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            let name = "surface-\(tab.label.lowercased())-\(theme == .warmSignal ? "warm" : "muted").png"
            renderScreenPNG(screen, to: outDir.appendingPathComponent(name))
        }
    }
    controller.shell.window?.orderOut(nil)
    return 0
}

// MARK: - Entry

@MainActor
func makeController() -> (SurfaceMockupController, Fixtures) {
    let fixtures = Fixtures()
    fixtures.start()

    // Fake status-item rect: menu-bar band, near the top-right of the main
    // screen, roughly where Audiouter's own item sits.
    let screenFrame = (NSScreen.main ?? NSScreen.screens[0]).frame
    let anchor = NSRect(x: screenFrame.maxX - 140, y: screenFrame.maxY - 24, width: 30, height: 22)

    let mixer = fixtures.mixerContent
    let controller = SurfaceMockupController(
        mixer: mixer.view, mixerTopTrim: mixer.topTrim,
        groups: fixtures.groupsContent,
        settings: fixtures.settingsContent,
        settingsHeight: fixtures.settingsWindow.test_contentFittingSize.height + 12,
        anchorRect: anchor)
    return (controller, fixtures)
}

@MainActor
func run() -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let isSnapshot = arguments.first == "--snapshot"
    if isSnapshot {
        arguments.removeFirst()
        // Never order a real window onto the developer's screen from the
        // capture path (`HeadlessRuntime` in AudiouterCore) — set BEFORE
        // touching AppKit.
        setenv("AIRPLAY_HEADLESS", "1", 1)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let (controller, fixtures) = makeController()
    // Retained for the process's lifetime — see `Fixtures`.
    withExtendedLifetime(fixtures) {}

    if isSnapshot {
        let outDir = URL(fileURLWithPath: arguments.first ?? "dev/notes/surface-mockup")
        let status = runSnapshots(controller, outDir: outDir)
        withExtendedLifetime(fixtures) {}
        return status
    }

    controller.show()
    print("""
    surface-mockup — header material tier: \(controller.headerTierDescription)
      Tabs switch screens · Pin flips the window's manners · power quits.
      Force a tier with AIRPLAY_MOCKUP_HEADER_TIER=glass|frost|opaque.
      Close the window (✕ or Escape) to quit.
    """)
    fflush(stdout)
    app.run()
    withExtendedLifetime(fixtures) {}
    return 0
}

exit(MainActor.assumeIsolated { run() })
