// SPDX-License-Identifier: GPL-2.0-or-later
//
// window-snapshot — offscreen PNG renderer for the "Groups" window (mirrors
// `settings-snapshot`). The live window isn't visible to an agent shell, so
// this assembles the REAL `MixerWindowController` against a MockBackend-backed
// `GroupController` and renders the whole window frame (titlebar + toolbar +
// split view) via `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:)`.
// Also renders the control-panel shell (T11) hosting the same Groups content
// in a sticky floating NSPanel with decorative beak chrome.
//
// States rendered (light + dark each):
//   1. default      — fresh window, no groups saved (the state under critique)
//   2. create-sheet — the `GroupCreationSheetController`'s own view, rendered
//                      offscreen at its fitted size (`presentAsSheet` never
//                      actually draws in a headless run, so the window-frame
//                      snapshot can't show it — this renders the sheet's view
//                      directly instead)
//   3. edit-group   — an existing (saved, unactivated) group selected in the
//                      sidebar (Edit Group pane) — selecting never activates
//   4. device-detail — a device (with a saved-group membership and an icon
//                      OVERRIDE) selected in the sidebar; the hover scrim is
//                      forced visible via `test_setOverlayVisible(true)` so
//                      the approved custom-drawn element renders in the shot
//   5. panel-chrome  — the control-panel shell (T11) hosting Groups content,
//                      anchored to a mock menu-bar status item (top-right),
//                      with the sticky NSPanel + decorative backing window
//                      with beak, right-edge-aligned
//
// Run: `swift run window-snapshot [output-dir]`.

import AppKit
import AudiouterCore
import AudiouterSharedUI
import AudiouterWindowUI

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("window-snapshot-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Render `view` (already laid out, hosted in a window) to a PNG at `url` under
/// `appearance`. Creates a deterministic @2x bitmap representation regardless of
/// the host screen's backing scale factor.
/// One capture of `view` into a fresh explicit-@2x bitmap, PNG-encoded.
/// Explicit pixel dimensions (2x the point size) keep the output independent
/// of the host screen's backingScaleFactor.
@MainActor
private func captureOnce(view: NSView, bounds: NSRect) -> Data? {
    let pixelsWide = Int(bounds.width * 2)
    let pixelsHigh = Int(bounds.height * 2)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { return nil }
    // Set the size so the rep reports correct point dimensions (backing scale = 2).
    rep.size = bounds.size
    view.cacheDisplay(in: bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
}

@MainActor
func renderPNG(view: NSView, to url: URL) {
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds

    // Capture-until-stable: material backdrops (and an appearance switch's
    // re-tint) settle asynchronously, so the FIRST capture after a window is
    // built or its appearance flips can race that settling — a fixed-length
    // drain is only accidentally long enough. Instead, re-capture with short
    // drains until two consecutive captures are byte-identical; that settled
    // state is deterministic, so the goldens are too.
    // Re-hide titlebar separators before EVERY capture: AppKit creates the
    // separator view lazily/asynchronously, so a single pre-capture hide pass
    // can run before the view exists (it then appears mid-loop in some runs).
    // Hiding inside the loop guarantees the only stable end state is
    // separator-free.
    hideTitlebarSeparators(in: view)
    var data = captureOnce(view: view, bounds: bounds)
    var stable = false
    for _ in 0..<40 {
        drain(0.05)
        hideTitlebarSeparators(in: view)
        let next = captureOnce(view: view, bounds: bounds)
        if next != nil && next == data { stable = true; break }
        data = next
    }
    if ProcessInfo.processInfo.environment["SNAPSHOT_DEBUG_STRIP"] != nil {
        dumpStrip(in: view)
    }
    guard let data else {
        print("  FAIL  could not encode PNG for \(url.lastPathComponent)")
        return
    }
    if !stable {
        print("  WARN  \(url.lastPathComponent) never stabilized after 40 recaptures; writing last")
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
    // Pin the titlebar separator OFF: AppKit decides it dynamically from the
    // content's perceived scroll-under state, and even with `.line` it FADES
    // the separator view in/out, settling differently run-to-run (a 1pt
    // full-width line at the titlebar's bottom edge flickered in and out of
    // dark captures). `.none` removes the separator view entirely — the only
    // end state that can't race. NSSplitViewItem carries a per-pane override,
    // so pin those too.
    window.titlebarSeparatorStyle = .none
    if let split = window.contentViewController as? NSSplitViewController {
        for item in split.splitViewItems { item.titlebarSeparatorStyle = .none }
    }
    // Order the window in, invisibly (alpha 0). A window that is never
    // ordered in leaves the titlebar machinery half-initialized, and its
    // separator decision latches mid-flight — differently run-to-run. A full
    // order-in lets AppKit finish the titlebar lifecycle so the pinned
    // `.none` above is actually applied; alpha 0 keeps the run headless-quiet
    // and `cacheDisplay` reads model values, unaffected by window alpha.
    if !window.isVisible {
        window.alphaValue = 0
        window.orderFront(nil)
        drain(0.1)
    }
    window.layoutIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
    let frameView = window.contentView?.superview ?? window.contentView!
    pinMaterialsWithinWindow(in: frameView)
    hideTitlebarSeparators(in: frameView)
    drain(0.1)
    let suffix = appearanceName == .darkAqua ? "dark" : "light"
    renderPNG(view: frameView, to: outDir.appendingPathComponent("mixer-\(label)-\(suffix).png"))
}

/// Render a standalone view controller's view at its fitted size — used for
/// the create sheet, which `presentAsSheet` never actually draws in a
/// headless run. Mirrors `popover-snapshot`'s pattern: host the view in an
/// offscreen borderless window so materials/vibrancy render under the
/// requested appearance, then snapshot just the view.
/// Remove overlay scrollers from a captured view subtree. Overlay scroller
/// knobs fade on their own animation clock, so a capture races the fade and
/// the PNG differs run-to-run (observed: mixer-2-create-sheet-dark drifting
/// by a few hundred bytes). The knob is transient in real use anyway; a
/// deterministic golden simply omits it.
@MainActor
func stripScrollers(in view: NSView) {
    if let scrollView = view as? NSScrollView {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
    }
    for subview in view.subviews { stripScrollers(in: subview) }
}

/// Force every behind-window material in a captured hierarchy to blend
/// within-window instead. Behind-window vibrancy samples the LIVE desktop
/// (wallpaper, Dock, the ticking menu-bar clock near the mock status-item
/// anchor), so captures drift run-to-run with wall-clock time — the goldens
/// were only accidentally stable while runs were fast. Within-window blending
/// samples the window's own backing store: identical every run.
@MainActor
func pinMaterialsWithinWindow(in view: NSView) {
    if let effectView = view as? NSVisualEffectView, effectView.blendingMode == .behindWindow {
        effectView.blendingMode = .withinWindow
    }
    for subview in view.subviews { pinMaterialsWithinWindow(in: subview) }
}

/// Hide AppKit's private titlebar-separator view(s) in a captured window's
/// frame-view subtree. `titlebarSeparatorStyle = .none` (on the window AND the
/// split-view items) is NOT reliably honored for a window that was already
/// built — whether the separator view exists is decided once at window
/// creation and post-hoc style changes race it, so a 1pt hairline at the
/// titlebar's bottom edge flickered run-to-run in captures. Hiding the view
/// itself is deterministic. Generator-only; never ships in the app.
func hideTitlebarSeparators(in view: NSView) {
    if NSStringFromClass(type(of: view)).contains("TitlebarSeparator") {
        view.isHidden = true
    }
    for subview in view.subviews { hideTitlebarSeparators(in: subview) }
}

/// DEBUG (SNAPSHOT_DEBUG_STRIP=1): print every view whose frame intersects
/// the 3pt strip at the titlebar's bottom edge, with visibility state — used
/// to identify which view draws the flickering 1pt hairline.
func dumpStrip(in root: NSView) {
    let stripTopFromTop: CGFloat = 26, stripHeight: CGFloat = 4
    let rootH = root.bounds.height
    let strip = NSRect(x: 0, y: rootH - stripTopFromTop - stripHeight,
                       width: root.bounds.width, height: stripHeight)
    func walk(_ v: NSView, depth: Int) {
        let f = v.convert(v.bounds, to: root)
        if f.intersects(strip) && f.height <= 6 {
            let cls = NSStringFromClass(type(of: v))
            print("  STRIP \(String(repeating: " ", count: depth))\(cls) frame=\(f) hidden=\(v.isHidden) alpha=\(v.alphaValue) layerBG=\(v.layer?.backgroundColor != nil)")
        }
        for s in v.subviews { walk(s, depth: depth + 1) }
    }
    print("STRIP-DUMP rootH=\(rootH)")
    walk(root, depth: 0)
}


@MainActor
func snapshotStandaloneView(_ view: NSView, label: String, appearanceName: NSAppearance.Name, outDir: URL) {
    let appearance = NSAppearance(named: appearanceName)
    view.appearance = appearance
    stripScrollers(in: view)
    view.layoutSubtreeIfNeeded()
    let size = view.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    let host = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    host.appearance = appearance

    // The captured view has no background of its own — a presented sheet draws
    // on the window's background. Snapshotting the bare view therefore yields
    // transparent PNGs (white-on-nothing in dark mode). Render onto a
    // layer-backed backdrop filled with `windowBackgroundColor` resolved under
    // the requested appearance, and capture the backdrop.
    let backdrop = NSView(frame: frame)
    backdrop.wantsLayer = true
    backdrop.appearance = appearance
    appearance?.performAsCurrentDrawingAppearance {
        backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    host.contentView?.appearance = appearance
    host.contentView?.addSubview(backdrop)
    backdrop.addSubview(view)
    view.frame = frame
    host.setContentSize(size)
    host.layoutIfNeeded()
    pinMaterialsWithinWindow(in: backdrop)
    view.layoutSubtreeIfNeeded()
    drain(0.1)

    let suffix = appearanceName == .darkAqua ? "dark" : "light"
    renderPNG(view: backdrop, to: outDir.appendingPathComponent("mixer-\(label)-\(suffix).png"))
    host.contentView = NSView()   // detach so the view isn't torn down under us
}

/// Render the control-panel shell (T11) with Groups content: the sticky
/// floating NSPanel + decorative backing window with the beak. Position it
/// with a mock menu-bar status-item anchor (top-right corner), then composite
/// the backing window's chrome with the panel's content into an offscreen render
/// target and snapshot that.
@MainActor
func snapshotControlPanel(_ controller: ControlPanelWindowController,
                         label: String, appearanceName: NSAppearance.Name, outDir: URL) {
    let appearance = NSAppearance(named: appearanceName)

    // Position both windows with a mock menu-bar anchor (top-right, like a
    // status item). Use the primary screen if available, otherwise center.
    if let screen = NSScreen.main {
        let vf = screen.visibleFrame
        let mockAnchor = NSRect(x: vf.maxX - 20, y: vf.maxY - 4, width: 24, height: 4)
        controller.show(anchorRect: mockAnchor)
    } else {
        controller.show(anchorRect: nil)
    }

    // Set appearance on both windows.
    controller.test_panel?.appearance = appearance
    controller.test_backingWindow?.appearance = appearance

    // Layout the panel's content.
    controller.test_panel?.layoutIfNeeded()
    controller.test_panel?.contentView?.layoutSubtreeIfNeeded()
    drain(0.1)

    guard let backingWindow = controller.test_backingWindow,
          let panel = controller.test_panel,
          let panelContent = panel.contentView else {
        print("  FAIL  control panel snapshot: missing windows")
        return
    }

    // Create a composite container that renders both the backing window's
    // chrome (beak + bubble) and the panel's hosted content. The backing
    // window is positioned at (0, beakHeight) in the container, with the
    // panel's content layered on top at the same position.
    let beakHeight = ControlPanelBackingView.beakHeight
    let containerHeight = panel.frame.height + beakHeight + 10   // small padding
    let containerWidth = panel.frame.width

    let container = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
    container.wantsLayer = true
    container.appearance = appearance
    appearance?.performAsCurrentDrawingAppearance {
        container.layer?.backgroundColor = NSColor.clear.cgColor
    }

    // Create a view to hold the backing window's rendering (the beak + bubble shape).
    let backingLayer = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))
    backingLayer.wantsLayer = true
    backingLayer.appearance = appearance
    container.addSubview(backingLayer)

    // Render the backing window's content view (ControlPanelBackingView) into
    // the backing layer. We render it at its fitted position within the layer.
    if let backingContent = backingWindow.contentView {
        backingContent.appearance = appearance
        backingContent.layoutSubtreeIfNeeded()
        backingContent.frame = NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight)
        if let rep = backingContent.bitmapImageRepForCachingDisplay(in: backingContent.bounds) {
            backingContent.cacheDisplay(in: backingContent.bounds, to: rep)
            if let layer = backingLayer.layer,
               let cgImage = rep.cgImage {
                layer.contents = cgImage
                layer.contentsGravity = .topLeft
            }
        }
    }

    // Create a view for the panel's content (the Groups interface), positioned
    // to sit visually on top of the beak at its natural position.
    let contentLayer = NSView(
        frame: NSRect(x: 0, y: beakHeight, width: containerWidth, height: panel.frame.height)
    )
    contentLayer.wantsLayer = true
    contentLayer.appearance = appearance
    appearance?.performAsCurrentDrawingAppearance {
        contentLayer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    contentLayer.layer?.cornerRadius = ControlPanelBackingView.cornerRadius
    contentLayer.layer?.masksToBounds = true
    container.addSubview(contentLayer)

    // Render the panel's content view into the content layer. Materials are
    // pinned within-window and the rep scale pinned @2x for the same
    // determinism reasons as `renderPNG` (behind-window vibrancy samples the
    // live desktop; `bitmapImageRepForCachingDisplay` inherits the host
    // screen's scale).
    panelContent.appearance = appearance
    pinMaterialsWithinWindow(in: panelContent)
    panelContent.layoutSubtreeIfNeeded()
    let contentBounds = NSRect(x: 0, y: 0, width: containerWidth, height: panel.frame.height)
    if let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(contentBounds.width * 2),
        pixelsHigh: Int(contentBounds.height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) {
        rep.size = contentBounds.size
        panelContent.cacheDisplay(in: contentBounds, to: rep)
        if let layer = contentLayer.layer,
           let cgImage = rep.cgImage {
            layer.contents = cgImage
            layer.contentsGravity = .topLeft
        }
    }

    // Render the composite container to PNG.
    container.layoutSubtreeIfNeeded()
    drain(0.1)

    let suffix = appearanceName == .darkAqua ? "dark" : "light"
    renderPNG(view: container, to: outDir.appendingPathComponent("mixer-\(label)-\(suffix).png"))
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
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()   // window-snapshot
            .deletingLastPathComponent()                     // Sources
            .deletingLastPathComponent()                     // AudiouterCore
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
        // Constructed explicitly (rather than relying on the default param) so
        // state 4 can seed an icon override on the SAME controller instance
        // every child pane shares.
        let deviceIconController = DeviceIconController(loadPersisted: false)
        let windowController = MixerWindowController(groupController: controller,
                                                      deviceIconController: deviceIconController)
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

        // 1. Default state: no groups — the empty "No groups yet" pane (the
        //    mixer pane was removed by live-test feedback 2026-07-18).
        snapshotWindow(window, label: "1-default", appearanceName: appearanceName, outDir: outDir)

        // 2. Create sheet: the sidebar "+" with nothing selected presents the
        // standard macOS "New Group" sheet. `presentAsSheet` doesn't actually
        // draw offscreen/headless, so render the sheet controller's own view
        // directly at its fitted size instead of the window frame.
        windowController.test_presentCreateSheet(preselected: [])
        if let sheet = windowController.test_createSheet {
            drain()
            snapshotStandaloneView(sheet.view, label: "2-create-sheet",
                                   appearanceName: appearanceName, outDir: outDir)
            sheet.test_cancel()
            drain()
        }

        // 3. Edit an existing (saved, unactivated) group: save one, select it
        // in the sidebar. Selecting never activates the group — CONFIG-ONLY.
        _ = controller.setDeviceSelected("sonos-move", true)
        _ = controller.setDeviceSelected("office", true)
        if let saved = try? controller.saveCurrentSetupAsGroup(name: "Downstairs").group {
            windowController.update(devices: backend.devices)
            windowController.test_select(.group(id: saved.id))
            drain()
            snapshotWindow(window, label: "3-edit-group", appearanceName: appearanceName, outDir: outDir)

            // 4. Device detail: select a device that's a member of the saved
            // group above (so "In groups:" renders non-empty) and carries an
            // icon OVERRIDE, with the hover scrim forced visible so the
            // approved custom-drawn element (`../../AGENTS.md`) shows up in
            // the render.
            deviceIconController.setSymbolName("homepod.2.fill", for: "sonos-move")
            windowController.test_select(.device(id: "sonos-move"))
            drain()
            windowController.test_detail.test_setOverlayVisible(true)
            drain()
            snapshotWindow(window, label: "4-device-detail", appearanceName: appearanceName, outDir: outDir)

            // 5. Panel chrome (T11): the control-panel shell with Groups content
            // anchored to a mock menu-bar status item (top-right). The sticky
            // floating NSPanel + decorative backing window with the beak,
            // right-edge-aligned and rendered together.
            let panelController = ControlPanelWindowController(
                contentViewController: windowController.contentController,
                title: "Groups"
            )
            snapshotControlPanel(panelController, label: "5-panel-chrome",
                                appearanceName: appearanceName, outDir: outDir)
        }
    }

    print("Done.")
    return 0
}

exit(MainActor.assumeIsolated { run() })
