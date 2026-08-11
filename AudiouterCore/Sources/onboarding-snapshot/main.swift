// SPDX-License-Identifier: GPL-2.0-or-later
//
// onboarding-snapshot — offscreen PNG renderer for the Setup window (mirrors
// `settings-snapshot`). The live window isn't visible to an agent shell, and
// this app is a menu-bar accessory outside computer-use's resolver, so this
// assembles the REAL `OnboardingViewController` against fake permission seams
// (never touching Core Audio or the local network), drives the sequential flow
// through its real Allow path, and renders a PNG to
// `dev/notes/onboarding-snapshots/` in both light and dark appearances.
//
// It writes, per appearance:
//   onboarding-<light|dark>-step1-audio.png      card 1 active, nothing granted
//   onboarding-<light|dark>-step2-network.png    audio granted, card 2 active
//   onboarding-<light|dark>-step3-bluetooth.png  audio + network in, card 3 active
//   onboarding-<light|dark>-denied.png           audio denied → Settings mode demo
//   onboarding-<light|dark>-complete.png         every step in, Done visible
//   onboarding-<light|dark>-permission-lost.png  the re-entry header message
//
// KNOWN LIMIT: prominent buttons render as plain pills here. AppKit fills a
// `bezelColor` only in the active app's key window, and making this offscreen
// window key (`.titled` + `NSApp.activate` + `makeKeyAndOrderFront`) was tried and
// did NOT restore the fill — so button PROMINENCE is not verifiable from these
// fixtures; check it on a live window.
//
// Every demo renders its SETTLED frame: `HeadlessRuntime.isActive` is true here
// (AIRPLAY_HEADLESS=1 below), and the demo pane never animates off-window.
//
// Run: `swift run onboarding-snapshot [output-dir]`.

import AppKit
import AudiouterCore
import AudiouterOnboardingUI

/// Fake audio probe — never touches Core Audio.
struct SnapshotAudioProbe: AudioCapturePermissionProbing {
    let result: PermissionStatus
    func probe() async -> PermissionStatus { result }
    func currentStatusSilently() -> PermissionStatus? { result }
}

/// Fake local-network primer — never touches the network. `foundSpeakers`
/// drives the completed card's "Found N speakers" title.
struct SnapshotLocalNetwork: LocalNetworkPriming {
    let foundSpeakers: Int
    func probe() async -> Bool { foundSpeakers > 0 }
    func probeFoundSpeakers() async -> Int { foundSpeakers }
}

/// Fake remote-control primer — never touches Accessibility.
struct SnapshotRemoteControl: RemoteControlPriming {
    let trusted: Bool
    func prime() {}
    func isTrusted() -> Bool { trusted }
}

/// Fake PTP helper manager — never touches `SMAppService`.
struct SnapshotPTPHelper: PTPHelperManaging {
    let statusToReport: PTPHelperStatus
    var status: PTPHelperStatus { statusToReport }
    func register() throws {}
    func openSystemSettingsLoginItems() {}
    func unregister() async throws {}
}

/// Name of the throwaway defaults suite these fixtures write to instead of the
/// developer's real domain. FIXED, not per-run: `UserDefaults(suiteName:)`
/// creates a real `~/Library/Preferences/<name>.plist`, so a `UUID` in the name
/// leaves one behind on every run. One reused name plus a wipe before each use
/// keeps the fixtures identical run to run at a cost of one plist, ever.
let snapshotDefaultsSuite = "onboarding-snapshot"

@MainActor
func makeSnapshotDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: snapshotDefaultsSuite)!
    defaults.removePersistentDomain(forName: snapshotDefaultsSuite)
    return defaults
}

/// One fixture's whole permission world.
struct SnapshotWorld {
    var audio: PermissionStatus = .granted
    var foundSpeakers = 3
    var remoteControlTrusted = false
    var bluetooth: PermissionStatus = .unknown
    var ptpHelper: PTPHelperStatus = .requiresApproval
    /// Which cards' Allow to fire before rendering — how the flow is walked to
    /// the step this fixture is about.
    var allow: [SetupStep] = []
    var reason: OnboardingReason = .firstRun
}

@MainActor
func makeViewController(_ world: SnapshotWorld) -> OnboardingViewController {
    let suite = makeSnapshotDefaults()
    let bluetooth = SimulatedBluetoothPermission(status: world.bluetooth)
    let model = SetupModel(audioProbe: SnapshotAudioProbe(result: world.audio),
                           localNetwork: SnapshotLocalNetwork(foundSpeakers: world.foundSpeakers),
                           remoteControl: SnapshotRemoteControl(trusted: world.remoteControlTrusted),
                           ptpHelper: SnapshotPTPHelper(statusToReport: world.ptpHelper),
                           bluetoothReader: bluetooth,
                           bluetoothPrimer: bluetooth,
                           settings: AppSettings(defaults: suite))
    return OnboardingViewController(model: model,
                                    reason: world.reason,
                                    onOpenSettings: { _ in },
                                    onDone: {})
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

@MainActor
func snapshot(appearanceName: NSAppearance.Name,
              label: String,
              world: SnapshotWorld,
              outDir: URL) async {
    let controller = makeViewController(world)
    let appearance = NSAppearance(named: appearanceName)
    let rootView = controller.test_rootView
    rootView.appearance = appearance
    // Awaited, unlike the load-time fire-and-forget: Bluetooth and Remote
    // Control only ever reach `.granted` through the silent re-read, so a
    // fixture that means "these are already granted" has to wait for it.
    await controller.test_refreshStatuses()
    await controller.test_allow(world.allow)
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

    let url = outDir.appendingPathComponent("onboarding-\(label).png")
    renderPNG(view: rootView, to: url)
    window.contentView = NSView()   // detach so nothing dangles
}

/// Every step granted: audio + network really probe, Bluetooth and the helper
/// report satisfied from their seams, Accessibility is already trusted.
let completeWorld = SnapshotWorld(audio: .granted,
                                  foundSpeakers: 3,
                                  remoteControlTrusted: true,
                                  bluetooth: .granted,
                                  ptpHelper: .enabled,
                                  allow: [.audio, .localNetwork])

@MainActor
func run() async -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let args = CommandLine.arguments
    let outDir: URL
    if args.count > 1 {
        outDir = URL(fileURLWithPath: args[1])
    } else {
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()   // onboarding-snapshot
            .deletingLastPathComponent()                     // Sources
            .deletingLastPathComponent()                     // AudiouterCore
            .deletingLastPathComponent()                     // repo root
        outDir = packageRoot.appendingPathComponent("dev/notes/onboarding-snapshots", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    print("Rendering onboarding snapshots to: \(outDir.path)")

    for (name, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        await snapshot(appearanceName: name, label: "\(tag)-step1-audio",
                       world: SnapshotWorld(), outDir: outDir)
        await snapshot(appearanceName: name, label: "\(tag)-step2-network",
                       world: SnapshotWorld(allow: [.audio]), outDir: outDir)
        await snapshot(appearanceName: name, label: "\(tag)-step3-bluetooth",
                       world: SnapshotWorld(allow: [.audio, .localNetwork]), outDir: outDir)
        // Audio denied: the card's Allow has become the Settings deep link, and
        // the demo swaps to the Settings-pane miniature.
        await snapshot(appearanceName: name, label: "\(tag)-denied",
                       world: SnapshotWorld(audio: .denied, allow: [.audio]), outDir: outDir)
        await snapshot(appearanceName: name, label: "\(tag)-complete",
                       world: completeWorld, outDir: outDir)
        await snapshot(appearanceName: name, label: "\(tag)-permission-lost",
                       world: SnapshotWorld(audio: .denied,
                                            ptpHelper: .requiresApproval,
                                            allow: [.audio],
                                            reason: .permissionLost([.audioCapture, .ptpHelper])),
                       outDir: outDir)
    }

    print("Done.")
    return 0
}

// Headless: no window ever reaches the screen, and every animated instrument
// (including the demo pane's timelines) must resolve to its settled frame.
setenv("AIRPLAY_HEADLESS", "1", 1)
// Top-level `await` (SE-0343): the fixtures drive the REAL async Allow path, so
// this entry point is async — unlike the other snapshot tools, which are
// synchronous and use `MainActor.assumeIsolated`.
exit(await run())
