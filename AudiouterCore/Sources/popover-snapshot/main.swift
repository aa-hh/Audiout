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
//
// `AIRPLAY_SNAPSHOT_MODE=feed-composite` renders the Warm Signal v4.1 item 3
// FEED column's full precedence ladder in one panel — see
// `snapshotFeedComposite` for the per-row breakdown (multi-source composite,
// group-name wording, the AP1 micro-tag, the failure-red override, and the
// STATIC "+N" overflow).
//
// `AIRPLAY_SNAPSHOT_MODE=resting-ring` renders the ring-resting-state task's
// scenario: the DEFAULT {local device} passthrough selection (no toggles) —
// the Main Audio ring shows its thin, hue-neutral RESTING form instead of
// hiding, since audio is genuinely playing locally with no remote AirPlay
// handshake to report. See `snapshotRestingRing`.

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

/// The fleet for the `energize` scenarios (Warm Signal v4.1 item 9). Four
/// AirPlay members caught mid-switch to a group plus one that fails:
///   - `en-kitchen` — already `.connected` (the top of the sweep has landed:
///     filled gold node + gold rail segment),
///   - `en-living` — `.connecting` (mid-handshake: gold DASHED node, ember
///     segment) in the mid-sequence variant; `.connected` in the settled
///     Reduce-Motion variant so there is no in-flight residue to strip,
///   - `en-office` / `en-bedroom` — still `.off`: these carry the energize
///     PENDING beat (ember dashed node) mid-sequence, and SNAP to their
///     resolved filled-gold member node under Reduce Motion,
///   - `en-patio` — `.failed` (never toggled in, so it bounces off selection
///     exactly like the `connection-states` fixture's failed row): red halo
///     ring + "Couldn't connect" + auto-expanded diagnosis panel.
private func energizeFleet(livingConnecting: Bool) -> [Device] {
    [
        Device(id: "en-kitchen", name: "Kitchen HomePod", kind: .homePod,
               volume: 55, isSelected: true, connectionState: .connected),
        Device(id: "en-living", name: "Living Room TV", kind: .appleTV,
               volume: 42, isSelected: true,
               connectionState: livingConnecting ? .connecting : .connected),
        Device(id: "en-office", name: "Office", kind: .sonos,
               volume: 48, connectionState: .off),
        Device(id: "en-bedroom", name: "Bedroom HomePod", kind: .homePod,
               volume: 50, connectionState: .off),
        Device(id: "en-patio", name: "Patio Speaker", kind: .generic,
               volume: 30,
               connectionState: .failed(ConnectionFailure(cause: .notResponding))),
    ]
}

/// Shared staging for both energize fixtures: discover the fleet, select the
/// four non-failed members, push their states, open the panel, then force the
/// energize pending beat on the two still-`.off` members with a fixed Reduce
/// Motion posture (so the render is byte-deterministic regardless of the host
/// machine's accessibility settings). Returns the laid-out panel view.
@MainActor
private func stageEnergize(fleet: [Device], reduceMotion: Bool,
                          appearanceName: NSAppearance.Name) -> NSView? {
    let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let popover = PopoverController(appRouting: appRouting)
    backend.start()
    guard waitForFleet(backend, count: fleet.count) else {
        print("  SETUP FAIL: fleet did not fully discover"); return nil
    }
    popover.configure(groupController: controller)

    // Select every non-failed member (the failed one bounces off, as in
    // `connection-states`), so the rail runs Main Audio → the lowest member.
    for device in fleet {
        if case .failed = device.connectionState { continue }
        _ = popover.test_toggleDeviceEnabled(deviceID: device.id, on: true)
    }
    popover.update(devices: fleet)          // push states + auto-expand the failed panel
    popover.test_simulateOpen()             // rebuild as if reopened → rows mounted

    // Fixed Reduce Motion posture on the still-`.off` members, THEN raise the
    // pending beat: mid-sequence (motion on) → ember dashed pending nodes;
    // settled (motion reduced) → the beat is dropped, the members render their
    // resolved filled-gold member nodes (snap to resolved).
    for id in ["en-office", "en-bedroom"] {
        popover.test_deviceRow(for: id)?.test_reduceMotionOverride = reduceMotion
    }
    popover.test_setEnergizePending(["en-office", "en-bedroom"])

    let appearance = NSAppearance(named: appearanceName)
    let panelView = popover.test_panelView
    panelView.appearance = appearance
    panelView.layoutSubtreeIfNeeded()
    let size = panelView.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentView?.addSubview(panelView)
    panelView.frame = frame
    window.setContentSize(size)
    window.layoutIfNeeded()
    panelView.layoutSubtreeIfNeeded()
    drain(0.1)
    // Re-assert the beat AFTER the final layout pass (a mid-open reflow can run
    // an extra `applySelectionState`; re-forcing keeps the frozen frame exact).
    popover.test_setEnergizePending(["en-office", "en-bedroom"])
    panelView.layoutSubtreeIfNeeded()
    drain(0.05)
    return panelView
}

/// Render the `energize-mid-sequence` scenario (Warm Signal v4.1 item 9): a
/// FROZEN mid-switch frame — one member landed (gold), one connecting (gold
/// dashed), two on the ember PENDING beat, one failed — so the whole energize
/// vocabulary reads in one panel. Motion ON (the pending nodes are dashed).
@MainActor
func snapshotEnergizeMidSequence(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    guard let panelView = stageEnergize(fleet: energizeFleet(livingConnecting: true),
                                        reduceMotion: false, appearanceName: appearanceName)
    else { return }
    let url = outDir.appendingPathComponent("popover-energize-mid-\(label).png")
    renderPNG(view: panelView, to: url)
    panelView.window?.contentView = NSView()
}

/// Render the `energize-reduce-motion-static` scenario (item 9's motion gate):
/// the SAME switch under Reduce Motion — the sweep is removed, so the two
/// would-be-pending members snap straight to their resolved filled-gold member
/// nodes and the connecting member is settled to connected; only the genuine
/// failure stays red. No animation residue, at rest.
@MainActor
func snapshotEnergizeReduceMotion(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    guard let panelView = stageEnergize(fleet: energizeFleet(livingConnecting: false),
                                        reduceMotion: true, appearanceName: appearanceName)
    else { return }
    let url = outDir.appendingPathComponent("popover-energize-reduce-motion-\(label).png")
    renderPNG(view: panelView, to: url)
    panelView.window?.contentView = NSView()
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
    // `connectionState` directly — §7.3 "honest toggle"). EVERY state here is
    // "expected selected", `.failed` included: this used to leave the failed
    // device unselected, on the pre-R12 rule that a failure bounced it back OFF,
    // but R12 (W2-T3) removed that bounce — a failed device KEEPS the user's
    // intent. So an unselected-and-failed row no longer models anything the app
    // can actually produce, and staging it here suppressed the very thing this
    // scenario exists to show: since 2026-08-06 the diagnosis panel is retired
    // when the user drops the selection, so an unselected failed row renders no
    // panel at all. Selecting it stages the real post-R12 state — red ring, red
    // "Couldn't connect" feed token, panel open.
    for device in fleet {
        _ = popover.test_toggleDeviceEnabled(deviceID: device.id, on: true)
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

/// Render the `dormant-group` scenario (spec §4.7, the §4.8 fixture list's
/// **dormant-tinted** node): Audio Out targets a saved group ("Upstairs" =
/// Sonos Move + Bedroom HomePod) while the CHECKED set genuinely diverges
/// (Sonos Move + Office), so:
///   - the Devices card mounts the **"Inactive — Audio Out is using
///     'Upstairs'"** card note (only under genuine divergence — the
///     derived-identity case posts none),
///   - every row OUTSIDE the group's member set de-emphasizes via **node
///     TINT** (`test_busNodeIsDimmed` — checkbox stays full-alpha, never a
///     whole-row alpha dim), while members (Sonos Move, Bedroom HomePod)
///     keep full emphasis,
///   - "Sonos Move" (a checked group member) is additionally ROW-MUTED, so the
///     same panel carries the S3 mute channel: engaged accent mute pill, dark
///     corner dot, and the leading small-caps `MUTED · System` sublabel token.
@MainActor
func snapshotDormantGroup(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let popover = PopoverController(appRouting: appRouting)
    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("  SETUP FAIL: fleet did not fully discover"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()

    // Checked set = {Sonos Move, Office} (the first toggle auto-swaps the local
    // default off) — deliberately NOT equal to the group's member set below.
    _ = popover.test_toggleDeviceEnabled(deviceID: "sonos-move", on: true)
    _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)

    // Saved group "Upstairs" = {Sonos Move, Bedroom HomePod}, activated as the
    // Main Out target → genuine divergence vs the checked set.
    guard let created = try? controller.createGroup(
        name: "Upstairs", memberIDs: ["sonos-move", "homepod-bed"]) else {
        print("  SETUP FAIL: could not create the 'Upstairs' group"); return
    }
    controller.setMainOut(.group(id: created.group.id))

    // S3 mute channel on a checked group member: MUTED · System token, engaged
    // pill, dark dot — at FULL emphasis (member rows never dim, §4.7).
    popover.test_toggleMute(deviceID: "sonos-move", muted: true)

    popover.update(devices: backend.devices)
    popover.test_simulateOpen()   // reopen-style rebuild mounts the card note

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

    let url = outDir.appendingPathComponent("popover-dormant-group-\(label).png")
    renderPNG(view: panelView, to: url)
    window.contentView = NSView()
}

/// Render the `rail-depth` scenario (Warm Signal v4 §Call-1 fixture: "left-rail
/// spine at varying selection depths"): only ONE AirPlay device (Bedroom
/// HomePod) is checked, so the spine runs Main Audio → HomePod and TERMINATES
/// there — every AirPlay row below it (Living Room TV, Mixer, Move 2, Office,
/// Sonos Move) renders a BARE hollow clickable node with NO rail through it. The
/// local Mac (above the terminus) is local-mix blocked and detoured. This proves
/// the rail's length is information — "how far down the mix reaches" — and the
/// bare-node vocabulary the energize agent extends the spine into.
@MainActor
func snapshotRailDepth(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let popover = PopoverController(appRouting: appRouting)
    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("  SETUP FAIL: fleet did not fully discover"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()

    // Shallow selection: ONLY Bedroom HomePod (the first AirPlay row). The rail
    // terminates at it; every AirPlay row below renders BARE.
    _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
    popover.update(devices: backend.devices)
    popover.test_simulateOpen()

    let appearance = NSAppearance(named: appearanceName)
    let panelView = popover.test_panelView
    panelView.appearance = appearance
    panelView.layoutSubtreeIfNeeded()
    let size = panelView.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentView?.addSubview(panelView)
    panelView.frame = frame
    window.setContentSize(size)
    window.layoutIfNeeded()
    panelView.layoutSubtreeIfNeeded()
    drain(0.1)

    let url = outDir.appendingPathComponent("popover-rail-depth-\(label).png")
    renderPNG(view: panelView, to: url)
    window.contentView = NSView()
}

/// Render the `resting-ring` scenario (ring-resting-state task): the DEFAULT
/// {local device} passthrough selection with no toggles applied — audio is
/// genuinely playing through the Mac, unmuted, but there's no remote AirPlay
/// handshake for `mainOutConnectionState` to report, so the Main Audio ring
/// shows its RESTING form (thin, hue-neutral `ringConnected`, never the gold/
/// ember `connected` override) rather than hiding — the rail's curve into the
/// ring always has something to land on.
@MainActor
func snapshotRestingRing(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let popover = PopoverController(appRouting: appRouting)
    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("  SETUP FAIL: fleet did not fully discover"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()   // {local device} only — no toggles.
    popover.update(devices: backend.devices)
    popover.test_simulateOpen()

    let appearance = NSAppearance(named: appearanceName)
    let panelView = popover.test_panelView
    panelView.appearance = appearance
    panelView.layoutSubtreeIfNeeded()
    let size = panelView.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentView?.addSubview(panelView)
    panelView.frame = frame
    window.setContentSize(size)
    window.layoutIfNeeded()
    panelView.layoutSubtreeIfNeeded()
    drain(0.1)

    let url = outDir.appendingPathComponent("popover-resting-ring-\(label).png")
    renderPNG(view: panelView, to: url)
    window.contentView = NSView()
}

/// Render the `local-mix-blocked` scenario (spec §4.6, the §4.8 fixture list's
/// **greyed-blocked** and **hover** nodes): an AirPlay device (Office) is
/// checked, so the Mac's own row ("MacBook Pro Speakers") is local-mix BLOCKED —
/// greyed hollow bus node, honestly-disabled checkbox, tertiary name. The
/// production body-click branch (`test_simulateBlockedBodyClick` → the exact
/// `mouseDown` path) then MOUNTS the in-place one-line refusal note
/// (`GroupController.localMixRefusalReason`) under the row — the reachable
/// trigger, proven rendered rather than tooltip-only. "Bedroom HomePod"
/// (an ordinary hollow row) is set HOVERED via `test_setHovered(true)` (the
/// same `setHovered` path a real pointer crossing drives), so the neutral
/// hover wash — never gold, never on the node — is pinned in the same panel.
@MainActor
func snapshotLocalMixBlocked(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let popover = PopoverController(appRouting: appRouting)
    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("  SETUP FAIL: fleet did not fully discover"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()

    // Checking Office auto-swaps the local default off → the checked set holds
    // an AirPlay device, so the unchecked local row is now BLOCKED
    // (`!canSelectLocalSpeaker`, spec §4.6).
    _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
    popover.update(devices: backend.devices)
    popover.test_simulateOpen()

    // Mount the refusal note through the REAL blocked-body-click branch — the
    // same `mouseDown(with:)` production path, minus the synthesized event.
    guard let localRow = popover.test_deviceRow(for: "local-mac") else {
        print("  SETUP FAIL: no local-mac row mounted"); return
    }
    localRow.test_simulateBlockedBodyClick()
    // `insertRow(animated: true)` mounts the note at its full height straight
    // away — its reveal clip's height constraint takes the grown value the
    // moment the animator retargets it, so the capture needs no end-state
    // settling of its own even though a windowless view never fires the
    // animation's completion handler.
    drain(0.1)

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

    // Hover LAST: `apply(...)` and window re-attach both clear the transient
    // hover (by design), so it must land after every layout/model pass and
    // immediately before capture — mirrors how a live hover exists only while
    // nothing repaints the row.
    popover.test_deviceRow(for: "homepod-bed")?.test_setHovered(true)

    let url = outDir.appendingPathComponent("popover-local-mix-blocked-\(label).png")
    renderPNG(view: panelView, to: url)
    window.contentView = NSView()
}

/// Render the `feed-composite` scenario (Warm Signal v4.1 item 3): a device
/// row per FEED-column rung, so the whole precedence ladder is visible in one
/// panel. Main Out stays on **Selected Devices** throughout (Main Out is one
/// GLOBAL target for the whole popover, so a group-target row can't share a
/// panel with a "System" row — the group-name wording is covered instead by
/// `popover-harness`'s `[23] FEED column` section and `FeedColumnTests`) —
///   - "feed-manual": a MANUAL member (checked into Selected Devices) with
///     "Music" redirected to it ⇒ FEED reads **"System · Music"** — the
///     multi-source composite, never collapsed to one reason.
///   - "feed-group": a plain manual member with no redirect ⇒ FEED reads the
///     bare **"System"** token, for contrast against the composite above.
///   - "feed-ap1": an AP1-only device (`supportsAirPlay2: false`), also a
///     manual member ⇒ FEED reads **"AP1 System"** — the one monochrome
///     micro-tag exception, prefixed ahead of the composite.
///   - "feed-failed": `.failed` ⇒ FEED reads **"Couldn't connect"** — the
///     failure-red override, replacing the composite entirely (paired with
///     the red halo ring + open diagnosis panel).
///   - "feed-overflow": FIVE apps redirected to it, not itself a mix member
///     ⇒ FEED overflows to a STATIC "+N" suffix (no interactive reveal).
/// Every row's sublabel is asserted empty by `popover-harness`'s `[23] FEED
/// column` section — this snapshot is the visual counterpart.
@MainActor
func snapshotFeedComposite(appearanceName: NSAppearance.Name, label: String, outDir: URL) {
    // A hand-built fleet (rather than `.demoFleet`) so every FEED rung has an
    // unambiguous, purpose-named row instead of overloading the shared fleet's
    // existing device roles.
    let fleet: [Device] = [
        Device(id: "feed-manual", name: "Office Speaker", kind: .homePod,
              volume: 55, isSelected: true, connectionState: .connected),
        Device(id: "feed-group", name: "Living Room Sonos", kind: .sonos,
              volume: 60, isSelected: true, connectionState: .connected),
        Device(id: "feed-ap1", name: "Attic AirPort Express", kind: .airportExpress,
              supportsAirPlay2: false, volume: 40, isSelected: true, connectionState: .connected),
        Device(id: "feed-failed", name: "Basement Speaker", kind: .generic,
              volume: 45, connectionState: .failed(ConnectionFailure(cause: .notResponding))),
        Device(id: "feed-overflow", name: "Overflow Speaker", kind: .appleTV,
              volume: 35, connectionState: .connected),
    ]
    let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let musicBundleID = "com.apple.Music"
    appRouting.addRoute(bundleID: musicBundleID, displayName: "Music")
    appRouting.setDestination(.device(id: "feed-manual"), for: musicBundleID)

    // Five-app overflow fixture on "feed-overflow" — none of the five apps
    // ever gets its OWN row (only the first counts toward the Applications
    // card's redirect-destination UI); `applyRoutedApps` (T9's confirmed-live
    // signal) is enough on its own to drive the FEED column's segment list
    // without seeding five real app routes.
    let overflowAppNames = [
        "Alpha Streaming App", "Bravo Streaming App", "Charlie Streaming App",
        "Delta Streaming App", "Echo Streaming App",
    ]

    let popover = PopoverController(appRouting: appRouting)
    backend.start()
    guard waitForFleet(backend, count: fleet.count) else {
        print("  SETUP FAIL: fleet did not fully discover"); return
    }
    popover.configure(groupController: controller)

    // Manual members: Main Out stays on Selected Devices (the default) for
    // this fixture, so every non-failed row's neutral segment reads "System".
    _ = popover.test_toggleDeviceEnabled(deviceID: "feed-manual", on: true)
    _ = popover.test_toggleDeviceEnabled(deviceID: "feed-group", on: true)
    _ = popover.test_toggleDeviceEnabled(deviceID: "feed-ap1", on: true)

    popover.applyRoutedApps(deviceID: "feed-overflow", appNames: overflowAppNames)
    popover.update(devices: backend.devices)
    popover.test_simulateOpen()   // reopen-style rebuild so the Applications card expands

    let appearance = NSAppearance(named: appearanceName)
    let panelView = popover.test_panelView
    panelView.appearance = appearance
    panelView.layoutSubtreeIfNeeded()
    let size = panelView.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentView?.addSubview(panelView)
    panelView.frame = frame
    window.setContentSize(size)
    window.layoutIfNeeded()
    panelView.layoutSubtreeIfNeeded()
    drain(0.1)

    let url = outDir.appendingPathComponent("popover-feed-composite-\(label).png")
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
    if mode == "dormant-group" {
        snapshotDormantGroup(appearanceName: .aqua, label: "light", outDir: outDir)
        snapshotDormantGroup(appearanceName: .darkAqua, label: "dark", outDir: outDir)
        print("Done.")
        return 0
    }
    if mode == "local-mix-blocked" {
        snapshotLocalMixBlocked(appearanceName: .aqua, label: "light", outDir: outDir)
        snapshotLocalMixBlocked(appearanceName: .darkAqua, label: "dark", outDir: outDir)
        print("Done.")
        return 0
    }
    if mode == "resting-ring" {
        snapshotRestingRing(appearanceName: .aqua, label: "light", outDir: outDir)
        snapshotRestingRing(appearanceName: .darkAqua, label: "dark", outDir: outDir)
        print("Done.")
        return 0
    }
    if mode == "rail-depth" {
        snapshotRailDepth(appearanceName: .aqua, label: "light", outDir: outDir)
        snapshotRailDepth(appearanceName: .darkAqua, label: "dark", outDir: outDir)
        print("Done.")
        return 0
    }
    if mode == "feed-composite" {
        snapshotFeedComposite(appearanceName: .aqua, label: "light", outDir: outDir)
        snapshotFeedComposite(appearanceName: .darkAqua, label: "dark", outDir: outDir)
        print("Done.")
        return 0
    }
    if mode == "energize-mid-sequence" {
        snapshotEnergizeMidSequence(appearanceName: .aqua, label: "light", outDir: outDir)
        snapshotEnergizeMidSequence(appearanceName: .darkAqua, label: "dark", outDir: outDir)
        print("Done.")
        return 0
    }
    if mode == "energize-reduce-motion-static" {
        snapshotEnergizeReduceMotion(appearanceName: .aqua, label: "light", outDir: outDir)
        snapshotEnergizeReduceMotion(appearanceName: .darkAqua, label: "dark", outDir: outDir)
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
