// SPDX-License-Identifier: GPL-2.0-or-later
//
// window-snapshot — offscreen PNG renderer for the "Groups" screen (mirrors
// `settings-snapshot`). The live window isn't visible to an agent shell, so
// this assembles the REAL `MixerWindowController` (Groups content) against a
// MockBackend-backed `GroupController`, hosts it in the REAL one-surface
// shell (`AppSurfaceController`, PLAN-ONE-SURFACE-032 U3) — the same object
// the shipping app builds — and renders the shell's whole frame (beak
// backing bubble + native toolbar header + content) into an explicit @2x
// bitmap via `displayIgnoringOpacity(_:in:)` (see `captureOnce` for why not
// `cacheDisplay(in:to:)`). Every Groups-content state renders at the size the
// surface really presents (the one fixed surface frame —
// `AppSurfaceController.minimumContentSize` is its floor; the Mixer's fit
// decides the height), never a synthetic plain-titled host: a
// fixture built from a fake window carries none of the toolbar strip or beak
// chrome the app actually wraps the screen in, so it can't show what a
// sidebar layout regression would really look like on screen. `create-sheet`
// and `icon-picker` still render standalone — they're anchored popovers with
// no window chrome of their own to mismatch, so the synthetic-host question
// never applied to them (see `snapshotStandaloneView`).
//
// States rendered (light + dark each), all through the real surface except
// where noted:
//   1. default      — fresh window, no groups saved (the state under critique)
//   2. create-sheet — the `GroupCreationSheetController`'s own view, rendered
//                      standalone at its fitted size (`presentAsSheet` never
//                      actually draws in a headless run, so the window-frame
//                      snapshot can't show it — this renders the sheet's view
//                      directly instead)
//   3. edit-group   — an existing (saved, unactivated) group selected in the
//                      sidebar (Edit Group pane) — selecting never activates
//   4. device-detail — a device (with a saved-group membership and an icon
//                      OVERRIDE) selected in the sidebar; the edit badge's
//                      hover step-up is forced visible via
//                      `test_setOverlayVisible(true)` so the approved
//                      custom-drawn element renders in the shot
//   5. panel-chrome  — the same surface + device-detail selection as state 4,
//                      captured again after the group is ACTIVATED (state 7
//                      below) — the gold ring shows on the sidebar/detail
//                      while the surface's toolbar+beak chrome is on screen
//   6. icon-picker   — the icon-picker popover content (Warm Signal W3),
//                      rendered standalone like the create sheet
//                      (`presentIconPicker` never draws in a headless run),
//                      carrying the shown device's CURRENT override — the
//                      gold "current icon" selection ring — in a narrowed
//                      search grid
//   7. edit-active-group — the Edit Group pane while the shown group is the
//                      ACTIVE Main Out target (thin gold ring on the icon
//                      well); activation happens through the model — the
//                      window stays config-only
//
// Run: `swift run window-snapshot [output-dir]`.

import AppKit
import AudiouterCore
import AudiouterPopoverUI
import AudiouterSettingsUI
import AudiouterSharedUI
import AudiouterWindowUI

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("window-snapshot-\(UUID().uuidString)", isDirectory: true)
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

/// One capture of `view` into a fresh explicit-@2x bitmap rep. Explicit pixel
/// dimensions (`snapshotBackingScale` x the point size) keep the output
/// independent of the host screen's backingScaleFactor.
@MainActor
func captureRep(view: NSView, bounds: NSRect) -> NSBitmapImageRep? {
    let pixelsWide = Int((bounds.width * snapshotBackingScale).rounded())
    let pixelsHigh = Int((bounds.height * snapshotBackingScale).rounded())
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide,
                                      pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        return nil
    }
    // Set the size so the rep reports correct point dimensions (backing scale = 2).
    rep.size = bounds.size
    // `NSBitmapImageRep(bitmapDataPlanes:...)` doesn't guarantee a zeroed
    // buffer (unlike `bitmapImageRepForCachingDisplay(in:)`) — zero it so any
    // region `cacheDisplay` doesn't fully repaint has defined (transparent)
    // content instead of stale heap bytes.
    if let bitmapData = rep.bitmapData {
        memset(bitmapData, 0, rep.bytesPerRow * pixelsHigh)
    }
    // Render through an explicit NSGraphicsContext (not `cacheDisplay`) so
    // font smoothing can be VETOED at the CGContext level. Whether AppKit
    // text/symbol drawing applies smoothing (stem darkening — glyph AA
    // coverage ~15-20% heavier) is decided per-cell against display state
    // that resolves asynchronously and latches per capture host, so
    // mixer-6-icon-picker settled bimodally (~1 in 10) in a heavier-glyph
    // vs lighter-glyph state that no amount of settling reconciles.
    // `setAllowsFontSmoothing(false)` overrides any cell-level enable, making
    // glyph rasterization identical no matter which way the latch resolved.
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    ctx.cgContext.setAllowsFontSmoothing(false)
    view.displayIgnoringOpacity(bounds, in: ctx)
    return rep
}

/// `captureRep`, PNG-encoded — the form `renderPNG`'s stabilization loop
/// compares byte-for-byte.
@MainActor
private func captureOnce(view: NSView, bounds: NSRect) -> Data? {
    captureRep(view: view, bounds: bounds)?.representation(using: .png, properties: [:])
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
    hideNondeterministicChrome(in: view)
    var data = captureOnce(view: view, bounds: bounds)
    var stable = false
    for _ in 0..<40 {
        drain(0.05)
        hideNondeterministicChrome(in: view)
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
func hideNondeterministicChrome(in view: NSView) {
    // Two distinct private views can paint the hairline:
    // - `NSTitlebarSeparatorView`: a dedicated 1pt view (the original fix).
    // - `_NSTitlebarDecorationView`: a FULL-HEIGHT (28pt) titlebar overlay
    //   that draws the separator line + its soft shadow INSIDE itself when
    //   AppKit's async separator resolution latched "separator on" before
    //   `titlebarSeparatorStyle = .none` took effect. Because the view spans
    //   the whole titlebar, no thin view ever intersects the strip
    //   (SNAPSHOT_DEBUG_STRIP found nothing), and whether it draws the line
    //   latches once per window — all whole-window captures of that window
    //   flipped together, ~1 in 3 runs. It draws nothing else we keep, so
    //   hiding it collapses both latch states onto the same pixels.
    let cls = NSStringFromClass(type(of: view))
    if cls.contains("TitlebarSeparator") || cls.contains("TitlebarDecoration") {
        view.isHidden = true
    }
    // The sidebar outline's group-row hover "Show"/"Hide" button: a bare
    // `NSButton` AppKit mounts DIRECTLY on the `NSTableRowView` (real cell
    // content always sits inside an `NSTableCellView`, so this match can't
    // catch app content). It fades in when the live cursor crosses the
    // ordered-in (alpha-0) window OR transiently after a sidebar selection
    // change, on its own animation clock — a capture that stabilizes during
    // a stalled fade keeps a half-faded button (observed as a ~10x6pt glyph
    // at the group row's trailing edge). `ignoresMouseEvents` closes the
    // hover path; this closes the selection-change path.
    if view is NSButton, view.superview is NSTableRowView {
        view.isHidden = true
    }
    for subview in view.subviews { hideNondeterministicChrome(in: subview) }
}

/// DEBUG (SNAPSHOT_DEBUG_STRIP=1): print every view whose frame intersects
/// the 3pt strip at the titlebar's bottom edge, with visibility state — used
/// to identify which view draws the flickering 1pt hairline.
func dumpStrip(in root: NSView) {
    let stripTopFromTop: CGFloat = 26, stripHeight: CGFloat = 4
    let rootH = root.bounds.height
    let strip = NSRect(x: 0, y: rootH - stripTopFromTop - stripHeight,
                       width: root.bounds.width, height: stripHeight)
    let all = ProcessInfo.processInfo.environment["SNAPSHOT_DEBUG_STRIP_ALL"] != nil
    func walk(_ v: NSView, depth: Int) {
        let f = v.convert(v.bounds, to: root)
        if f.intersects(strip) && (all || f.height <= 6) {
            let cls = NSStringFromClass(type(of: v))
            print("  STRIP \(String(repeating: " ", count: depth))\(cls) frame=\(f) hidden=\(v.isHidden) alpha=\(v.alphaValue) layerBG=\(v.layer?.backgroundColor != nil)")
        }
        for s in v.subviews { walk(s, depth: depth + 1) }
    }
    print("STRIP-DUMP rootH=\(rootH)")
    walk(root, depth: 0)
}

/// Render a standalone view controller's view at its fitted size — used for
/// the create sheet, which `presentAsSheet` never actually draws in a
/// headless run. Mirrors `popover-snapshot`'s pattern: host the view in an
/// offscreen borderless window so materials/vibrancy render under the
/// requested appearance, then snapshot just the view.
@MainActor
func snapshotStandaloneView(_ view: NSView, label: String, appearanceName: NSAppearance.Name, outDir: URL) {
    let appearance = NSAppearance(named: appearanceName)
    view.appearance = appearance
    stripScrollers(in: view)
    view.layoutSubtreeIfNeeded()
    let size = view.fittingSize
    let frame = NSRect(origin: .zero, size: size)

    // `view` may already be hosted in a real window (state 2's create sheet
    // is a genuine `presentAsSheet`, not a mock) — remember that superview
    // now, before `backdrop.addSubview(view)` below reparents `view` away
    // from it, so it can go back afterward.
    let originalSuperview = view.superview

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
    // Order the host in, invisibly (alpha 0) — same rationale as
    // `snapshotWindow`: a window that is never ordered in leaves its Core
    // Animation machinery half-engaged, and WHETHER the first commit ran
    // before the capture loop stabilized decided the text/glyph rendering
    // path (layer-backed vs direct → different antialiasing weight), so
    // mixer-6-icon-picker settled in one of two internally-stable states
    // per capture. A full order-in makes the commit happen every run,
    // before the first capture.
    host.alphaValue = 0
    host.ignoresMouseEvents = true   // same live-cursor hover hazard as `snapshotWindow`
    host.orderFront(nil)
    // No text field may keep an active field editor into the capture — an
    // insertion caret blinks on its own clock, far slower than the 0.05s
    // recapture drain, so the loop can "stabilize" in either caret phase.
    host.endEditing(for: nil)
    host.makeFirstResponder(nil)
    drain(0.1)

    let suffix = appearanceName == .darkAqua ? "dark" : "light"
    renderPNG(view: backdrop, to: outDir.appendingPathComponent("mixer-\(label)-\(suffix).png"))
    host.orderOut(nil)
    // Give `view` back to its original superview (if any) BEFORE detaching
    // it from `host` below. For a real presented sheet, leaving `view`
    // orphaned here would make `view.window` read `nil` for the rest of this
    // process — `GroupCreationSheetController.finish`'s `view.window != nil`
    // guard exists so headless tests can drive `commit()`/`cancel()` with no
    // hosting window at all, but it means a later `test_cancel()` on a sheet
    // that WAS really presented would silently skip `dismiss(self)`, leaving
    // the sheet attached to (and dimming) its presenting window through every
    // subsequent capture. Restoring `view` here keeps `view.window` truthful,
    // so that guard takes the real-sheet branch and actually ends it.
    originalSuperview?.addSubview(view)
    host.contentView = NSView()   // detach so the view isn't torn down under us
}

/// Render the control-panel shell (T11) with Groups content: the sticky
/// floating NSPanel + decorative backing window with the beak. Position it
/// with a mock menu-bar status-item anchor (top-right corner), then composite
/// the backing window's chrome with the panel's FRAME view — the unified
/// toolbar header (live-review D1) plus content — into an offscreen render
/// target and snapshot that. `present` performs the actual show so the caller
/// can route it through the one-surface host (which mounts the screen, seats
/// its content below the toolbar strip and sizes the window) rather than the
/// bare shell.
@MainActor
func snapshotControlPanel(_ controller: ControlPanelWindowController,
                         label: String, appearanceName: NSAppearance.Name, outDir: URL,
                         present: (NSRect?) -> Void) {
    let appearance = NSAppearance(named: appearanceName)

    // Position both windows with a mock menu-bar anchor (top-right, like a
    // status item). Use the primary screen if available, otherwise center.
    if let screen = NSScreen.main {
        let vf = screen.visibleFrame
        let mockAnchor = NSRect(x: vf.maxX - 20, y: vf.maxY - 4, width: 24, height: 4)
        present(mockAnchor)
    } else {
        present(nil)
    }

    // Set appearance on both windows; keep them out of mouse routing for the
    // same live-cursor hover hazard as `snapshotWindow` (headless gating
    // means they normally never order in, but this costs nothing).
    controller.test_panel?.appearance = appearance
    controller.test_panel?.ignoresMouseEvents = true
    controller.test_backingWindow?.appearance = appearance
    controller.test_backingWindow?.ignoresMouseEvents = true

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

    // Create a view for the panel's FRAME view — content plus titlebar chrome —
    // positioned to sit visually on top of the beak at its natural position.
    let contentLayer = NSView(
        frame: NSRect(x: 0, y: beakHeight, width: containerWidth, height: panel.frame.height)
    )
    contentLayer.wantsLayer = true
    contentLayer.appearance = appearance
    // CLEAR, not `windowBackgroundColor`: the unpinned panel is transparent
    // wherever its content doesn't paint — most visibly the toolbar strip,
    // which the content is seated BELOW — and the backing bubble behind shows
    // through. An opaque backdrop here would occlude the bubble render below
    // and paint the strip stock grey, which the live window never does.
    contentLayer.layer?.backgroundColor = NSColor.clear.cgColor
    contentLayer.layer?.cornerRadius = ControlPanelBackingView.cornerRadius
    contentLayer.layer?.masksToBounds = true
    container.addSubview(contentLayer)

    // Render the panel's frame view (the contentView's superview), not the
    // contentView: the transparent-titlebar chrome — including the standard
    // close button, the panel's ONE close affordance (V13) — lives on the
    // frame view, so a contentView-only capture can never show it. Same
    // `displayIgnoringOpacity` primitive as `snapshotWindow`: it draws the
    // hierarchy directly, so it traverses the layer-backed subtrees a bare
    // `cacheDisplay` on this root skips. Materials pinned within-window and
    // the rep scale pinned @2x for the same determinism reasons as
    // `renderPNG`.
    let frameView = panel.contentView?.superview ?? panelContent
    frameView.appearance = appearance
    pinMaterialsWithinWindow(in: frameView)
    hideNondeterministicChrome(in: frameView)
    frameView.layoutSubtreeIfNeeded()
    if let rep = captureRep(view: frameView, bounds: frameView.bounds),
       let layer = contentLayer.layer,
       let cgImage = rep.cgImage {
        layer.contents = cgImage
        layer.contentsGravity = .topLeft
    }

    // Render the composite container to PNG.
    container.layoutSubtreeIfNeeded()
    drain(0.1)

    let suffix = appearanceName == .darkAqua ? "dark" : "light"
    renderPNG(view: container, to: outDir.appendingPathComponent("mixer-\(label)-\(suffix).png"))
}

/// Name of the throwaway defaults suite this tool's fixtures write to instead
/// of the developer's real domain. FIXED, not per-run: `UserDefaults(suiteName:)`
/// creates a real `~/Library/Preferences/<name>.plist`, so a `UUID` in the name
/// leaves one behind on every run. One reused name plus a wipe before each use
/// keeps the fixtures identical run to run at a cost of one plist, ever.
let snapshotDefaultsSuite = "window-snapshot"

@MainActor
func makeSnapshotDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: snapshotDefaultsSuite)!
    defaults.removePersistentDomain(forName: snapshotDefaultsSuite)
    return defaults
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
        // App-level appearance too, not just per-window: on Darwin 27,
        // system-drawn artwork (source-list selection pills, segmented
        // controls) resolves against the APP's effective appearance, so a
        // light pass on a dark-mode host rendered those pieces dark/garbled
        // while everything else honored the window override.
        app.appearance = NSAppearance(named: appearanceName)
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
        // `update(devices:)` gates its sidebar/content refresh behind
        // `isEffectivelyVisible` (host visibility OR this override) — this
        // tool never truly puts the content on screen under
        // `AIRPLAY_HEADLESS=1`, so without it every `update(devices:)` below
        // silently no-ops and the sidebar renders empty (caught 2026-07-26:
        // mixer-1's device list vanished the moment this gate landed).
        // Mirrors `popover-harness/main.swift`'s identical
        // `popover.test_isShownOverride = true` for the same B8 gate.
        windowController.test_isVisibleOverride = true
        backend.start()
        guard waitForFleet(backend, count: 7) else {
            print("SETUP FAIL: fleet did not fully discover"); return 2
        }
        windowController.update(devices: backend.devices)

        // The controller owns no window any more (U6) — host every
        // Groups-content state through the REAL one-surface shell
        // (`AppSurfaceController`, U3), the same object the shipping app
        // builds, anchored to a mock menu-bar status item (top-right). Built
        // once per appearance and reused across states 1/3/4/5/7 —
        // `groupsContent` is lazily resolved on the FIRST `.groups` select,
        // so every later capture just reflects the shared `windowController`
        // mutating underneath the same mounted content controller.
        let surfacePopover = PopoverController(
            appRouting: AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                             loadPersisted: false),
            runningAppsProvider: { [] })
        let surfaceSettings = AppSettings(defaults: makeSnapshotDefaults())
        let surface = AppSurfaceController(
            popoverController: surfacePopover,
            settings: surfaceSettings,
            groupsContent: { windowController.contentController },
            settingsContent: {
                // Lazily built on first .settings selection — never reached
                // in this render (only Groups is ever selected).
                SettingsRootViewController(sections: [])
            },
            frameAutosaveName: "WindowSnapshotSurface")
        // `show` mounts + fronts (a no-op re-front once already shown);
        // `select` is a no-op once Groups is already the selected screen —
        // so calling this before every capture just guarantees the surface
        // is showing Groups, without re-running the mount/resize dance.
        let presentGroups: (NSRect?) -> Void = { anchor in
            surface.show(anchorRect: anchor)
            surface.select(.groups)
        }

        // 1. Default state: no groups — the empty "No groups yet" pane (the
        //    mixer pane was removed by live-test feedback 2026-07-18).
        snapshotControlPanel(surface.shell, label: "1-default", appearanceName: appearanceName,
                            outDir: outDir, present: presentGroups)

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
            snapshotControlPanel(surface.shell, label: "3-edit-group", appearanceName: appearanceName,
                                outDir: outDir, present: presentGroups)

            // 4. Device detail: select a device that's a member of the saved
            // group above (so "In groups" renders non-empty) and carries an
            // icon OVERRIDE, with the edit badge's hover step-up forced visible so the
            // approved custom-drawn element (`../../AGENTS.md`) shows up in
            // the render.
            deviceIconController.setSymbolName("homepod.2.fill", for: "sonos-move")
            windowController.test_select(.device(id: "sonos-move"))
            drain()
            windowController.test_detail.test_setOverlayVisible(true)
            drain()
            snapshotControlPanel(surface.shell, label: "4-device-detail", appearanceName: appearanceName,
                                outDir: outDir, present: presentGroups)

            // 4b. The same pane with Advanced open — the scope lives in the
            // fold, so this is the only render that shows it. Put back
            // afterwards: this tool's hosts read `.standard` defaults, and a
            // left-open fold would leak into state 4 on the next run.
            windowController.test_detail.test_eqEditor.test_fireAdvancedClick()
            drain()
            snapshotControlPanel(surface.shell, label: "4b-device-detail-eq-open",
                                appearanceName: appearanceName,
                                outDir: outDir, present: presentGroups)
            windowController.test_detail.test_eqEditor.test_fireAdvancedClick()
            drain()

            // 6. Icon picker (Warm Signal W3): the anchored popover content,
            // rendered standalone like the create sheet (`presentIconPicker`
            // never actually draws headless). Built off the detail pane's
            // real click path so it carries the shown device's CURRENT
            // override — the curated cell with the gold "current icon"
            // selection ring — and a valid exact-name search so the preview
            // glyph renders on its mini warm-canvas tile.
            let picker = windowController.test_detail.test_clickEditIcon()
            // "homepod" is BOTH a valid exact symbol (preview tile renders)
            // and a substring that keeps the ringed current cell
            // ("homepod.2.fill") in the narrowed grid.
            picker.test_setSearchText("homepod")
            drain()
            snapshotStandaloneView(picker.view, label: "6-icon-picker",
                                   appearanceName: appearanceName, outDir: outDir)

            // 7. Edit pane for the ACTIVE group (Warm Signal W3, spec §5.3):
            // the icon well carries the thin gold ring while the shown group
            // is the Main Out target. Activation happens through the MODEL
            // (`GroupController.activateGroup`), exactly as the popover would
            // — the window itself stays config-only; this render just shows
            // how the editor looks while its group is playing.
            controller.activateGroup(id: saved.id)
            windowController.update(devices: backend.devices)
            windowController.test_select(.group(id: saved.id))
            drain()
            snapshotControlPanel(surface.shell, label: "7-edit-active-group",
                                appearanceName: appearanceName, outDir: outDir, present: presentGroups)
            // Back to the detail selection so the panel-chrome state below
            // renders the same content it always did.
            windowController.test_select(.device(id: "sonos-move"))
            windowController.test_detail.test_setOverlayVisible(true)
            drain()

            // 5. Panel chrome: the same surface + device-detail selection as
            // state 4, captured again now that the group is ACTIVE (state 7
            // above) — the standing offscreen proof that the toolbar +
            // beak-backed bubble (live-review D1) actually draws on the
            // unpinned bubble.
            snapshotControlPanel(surface.shell, label: "5-panel-chrome",
                                appearanceName: appearanceName, outDir: outDir, present: presentGroups)
        }
    }

    print("Done.")
    return 0
}

exit(MainActor.assumeIsolated { run() })
