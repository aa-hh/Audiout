// SPDX-License-Identifier: GPL-2.0-or-later
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
// no script timing to wait on, so the render is fully deterministic. This is
// the PRIMARY visual gate for the Warm Signal v3 §3.2 halo ring: `.off` → no
// ring · `.connecting`/`.reconnecting` → dashed `ringConnected` ring (the
// breathing pulse renders settled/full-opacity via `cacheDisplay`, so the PNG
// is deterministic) · `.connected` → solid `ringConnected` ring · `.failed` →
// heavier solid red `failure` ring + red "Couldn't connect" sublabel.

import AppKit
import AudiouterCore
import AudiouterPopoverUI
import AudiouterSharedUI

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

/// Fixed backing scale for every snapshot PNG (visual.md M1). Letting the OS
/// pick the scale (`bitmapImageRepForCachingDisplay(in:)`) makes the pixel
/// dimensions of the output drift by machine — 1x on a non-Retina/headless
/// display, 2x on a Retina one — even though this window is never actually
/// ordered onto a screen. Building the bitmap rep directly at a pinned scale
/// makes the resolution deterministic regardless of what's driving the run.
let snapshotBackingScale: CGFloat = 2

/// Render `view` (already laid out, hosted in a window) to a PNG at `url` under
/// `appearance`. Creates a deterministic @2x bitmap representation regardless of
/// the host screen's backing scale factor.
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

/// Recursively collects every subview of type `T` under `root` (depth-first,
/// pre-order) — used by ``snapshotMeters`` to reach into the assembled row
/// views for their `LevelMeterView` children without either row type needing
/// a new public accessor (T7 is scoped to this file only).
func findViews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    var result: [T] = []
    for sub in root.subviews {
        if let match = sub as? T { result.append(match) }
        result.append(contentsOf: findViews(of: type, in: sub))
    }
    return result
}

/// T7: meter-ON popover render (offline proof for task T-METER). Builds the
/// same panel as ``snapshot(appearanceName:label:outDir:)`` — same fleet,
/// same three selected devices, same expanded Applications card — then feeds
/// fixed per-device RMS readings through `PopoverController.test_pushLevel`
/// and settles each row's `LevelMeterView` synchronously via
/// `test_setDisplayedLevel` (T1) so the PNG never depends on a live
/// `CVDisplayLink` frame arriving before capture. "office" and "sonos-move"
/// render visible green bars (playing); "homepod-bed" is pushed a zero level
/// so its bar renders blank, standing in for a muted/deselected row.
///
/// T8: also seeds THREE Applications-card rows across the three
/// `AppRouteDestination` cases — "Music" → `.device(id: "office")` (routed,
/// active/undimmed slider), "Safari" → `.currentDevice` (explicit local pick,
/// dimmed slider), "Podcasts" → `.noRedirect` (the neutral default, also
/// dimmed) — so every destination state is represented in one panel. Every
/// row is built with `showsMeter: true` (`PopoverController.makeAppRow`
/// always passes that), so all three get a distinct RMS pushed via
/// `test_pushAppLevel` and are settled synchronously via `findViews` +
/// `test_setDisplayedLevel`, mirroring the device-row settling below
/// belt-and-suspenders (push AND settle, no reliance on the async mock
/// timer).
@MainActor
func snapshotMeters(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    // T8: three app rows spanning all three `AppRouteDestination` cases —
    // `.device(id:)` (routed away, active slider), `.currentDevice` (explicit
    // local pick, dimmed slider), `.noRedirect` (neutral default, also
    // dimmed) — so the Applications card proves every destination state at
    // once.
    let musicBundleID = "com.apple.Music"
    let safariBundleID = "com.apple.Safari"
    let podcastsBundleID = "com.apple.podcasts"
    appRouting.addRoute(bundleID: musicBundleID, displayName: "Music")
    appRouting.setDestination(.device(id: "office"), for: musicBundleID)
    appRouting.setVolume(70, for: musicBundleID)
    appRouting.addRoute(bundleID: safariBundleID, displayName: "Safari")
    appRouting.setDestination(.currentDevice, for: safariBundleID)
    appRouting.setVolume(55, for: safariBundleID)
    appRouting.addRoute(bundleID: podcastsBundleID, displayName: "Podcasts")
    // Podcasts stays on `.noRedirect` — the default for a freshly-added route,
    // no explicit `setDestination` call needed.

    let runningApps = [
        RunningAppInfo(bundleID: musicBundleID, displayName: "Music", icon: nil),
        RunningAppInfo(bundleID: safariBundleID, displayName: "Safari", icon: nil),
        RunningAppInfo(bundleID: podcastsBundleID, displayName: "Podcasts", icon: nil),
    ]
    let popover = PopoverController(appRouting: appRouting, runningAppsProvider: { runningApps })
    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("  SETUP FAIL: fleet did not fully discover"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()

    _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
    _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
    _ = popover.test_toggleDeviceEnabled(deviceID: "sonos-move", on: true)
    popover.update(devices: backend.devices)
    popover.test_simulateOpen()

    // Fixed per-device levels (task T-METER's mix): two visibly playing rows,
    // one silent/muted-looking row. "office" also drives Main Out (T4a: Main
    // Out shares the selected devices' level feed).
    let levels: [String: Float] = [
        "office": 0.82,
        "homepod-bed": 0.0,
        "sonos-move": 0.47,
    ]
    for (id, rms) in levels {
        popover.test_pushLevel(rms, for: id)
    }

    // T8: distinct per-app levels, one per seeded route above — proves the
    // Applications card's leading VU meters render independently of each
    // row's destination/dimming state.
    let appLevels: [String: Float] = [
        musicBundleID: 0.72,
        safariBundleID: 0.38,
        podcastsBundleID: 0.18,
    ]
    for (bundleID, rms) in appLevels {
        popover.test_pushAppLevel(rms, for: bundleID)
    }

    let appearance = NSAppearance(named: appearanceName)
    let panelView = popover.test_panelView
    panelView.appearance = appearance
    panelView.layoutSubtreeIfNeeded()

    // Settle every meter synchronously — no reliance on the async
    // MockBackend `emitsLevels` timer or a live CVDisplayLink tick, per T7.
    for row in findViews(of: DeviceRowView.self, in: panelView) {
        let target = CGFloat(levels[row.device.id] ?? 0)
        for meter in findViews(of: LevelMeterView.self, in: row) {
            meter.test_setDisplayedLevel(target)
        }
    }
    for mainOutRow in findViews(of: MainOutRowView.self, in: panelView) {
        let target = CGFloat(levels["office"] ?? 0)
        for meter in findViews(of: LevelMeterView.self, in: mainOutRow) {
            meter.test_setDisplayedLevel(target)
        }
    }
    for appRow in findViews(of: AppRowView.self, in: panelView) {
        let target = CGFloat(appLevels[appRow.appID] ?? 0)
        for meter in findViews(of: LevelMeterView.self, in: appRow) {
            meter.test_setDisplayedLevel(target)
        }
    }

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

    // Re-settle after the layout/drain pass — `layout()` and any stray
    // display-link tick both call `redrawFill()` off the same `displayed`
    // value, so this is belt-and-suspenders against a frame slipping in.
    for row in findViews(of: DeviceRowView.self, in: panelView) {
        let target = CGFloat(levels[row.device.id] ?? 0)
        for meter in findViews(of: LevelMeterView.self, in: row) {
            meter.test_setDisplayedLevel(target)
        }
    }
    for mainOutRow in findViews(of: MainOutRowView.self, in: panelView) {
        let target = CGFloat(levels["office"] ?? 0)
        for meter in findViews(of: LevelMeterView.self, in: mainOutRow) {
            meter.test_setDisplayedLevel(target)
        }
    }
    for appRow in findViews(of: AppRowView.self, in: panelView) {
        let target = CGFloat(appLevels[appRow.appID] ?? 0)
        for meter in findViews(of: LevelMeterView.self, in: appRow) {
            meter.test_setDisplayedLevel(target)
        }
    }

    let url = outDir.appendingPathComponent("popover-meters-\(label).png")
    renderPNG(view: panelView, to: url)
    window.contentView = NSView()
}

/// A small fleet with one row per `ConnectionState` case, for the
/// `connection-states` snapshot mode. Each device's name says what it's
/// demoing so the PNG is self-explanatory without cross-referencing code. This
/// now exercises the halo connection ring (Warm Signal v3 §3.2): `.off` shows
/// no ring, `.connecting`/`.reconnecting` a dashed breathing `ringConnected`
/// ring, `.connected` a solid `ringConnected` ring, `.failed` a heavier solid
/// red `failure` ring with the red "Couldn't connect" sublabel.
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
/// `.failed` transition in `PopoverController`). Construct PopoverController
/// with AppRoutingController backed by a temp-directory AppRouteStore (T-11),
/// so the snapshot tool never touches real Application Support. After update,
/// call test_simulateOpen() to rebuild the panel as if reopened, ensuring the
/// Devices card renders with the current state.
@MainActor
func snapshotConnectionStates(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let fleet = connectionStatesFleet
    let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    // Construct PopoverController with AppRoutingController backed by a temp-directory
    // AppRouteStore (T-11), so the snapshot tool never touches real Application Support.
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let popover = PopoverController(appRouting: appRouting)
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
    popover.test_simulateOpen()   // reopen-style rebuild so the Devices card renders

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
///     its row shows the CONFIRMED label ("Music") — and (S2, spec §3.3) its
///     GOLD route-armed corner dot, lit via the `liveAppNames` branch on an
///     UNCHECKED row (redirect-only: hollow bus node + gold dot + bright feed
///     token).
///   - "homepod-bed": redirected to Safari but given NO live event ⇒ its row
///     falls back to the INTENT-based label ("Safari"), demonstrating the
///     "routed but not yet confirmed streaming" fallback case.
///
/// S2+S3 additionally stage the **armed + muted mix** in the same panel:
///   - "sonos-move": toggled INTO the Selected set (connected) ⇒ armed — gold
///     dot lit on a member row (and Main Out's own dot lit via its aggregate
///     `.connected` ring state).
///   - "homepod-bed": toggled in AND then row-MUTED ⇒ the full mute channel —
///     engaged accent mute pill, DARK corner dot (armed predicate loses its
///     unmuted condition), drained meter, and the leading small-caps
///     `MUTED · System · Safari` sublabel token (no reflow — same row height).
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

    // S2+S3 armed+muted mix: "sonos-move" joins the Selected set (connected ⇒
    // armed, gold dot); "homepod-bed" joins AND is row-muted (engaged pill,
    // dark dot, drained meter, leading MUTED sublabel token).
    _ = popover.test_toggleDeviceEnabled(deviceID: "sonos-move", on: true)
    _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
    popover.test_toggleMute(deviceID: "homepod-bed", muted: true)

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
    // Never show a real window on the developer's screen while this
    // headless tool runs (`HeadlessRuntime` in AudiouterCore) — set BEFORE
    // touching AppKit.
    setenv("AIRPLAY_HEADLESS", "1", 1)
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
            .deletingLastPathComponent()                     // AudiouterCore
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
    snapshotMeters(appearanceName: .aqua, label: "light", outDir: outDir)
    snapshotMeters(appearanceName: .darkAqua, label: "dark", outDir: outDir)

    print("Done.")
    return 0
}

exit(MainActor.assumeIsolated { run() })
