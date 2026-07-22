// SPDX-License-Identifier: GPL-2.0-or-later
//
// onboarding-snapshot — offscreen PNG renderer for the first-run onboarding
// window (mirrors `settings-snapshot`). The live window isn't visible to an
// agent shell, and this app is a menu-bar accessory outside computer-use's
// resolver, so this assembles the REAL `OnboardingViewController` against fake
// permission seams (never touching Core Audio or the local network), forces each
// permission status, and renders a PNG to `dev/notes/onboarding-snapshots/` in
// both light and dark appearances.
//
// It writes:
//   onboarding-<light|dark>-initial.png   all three permissions unknown ("Allow…")
//   onboarding-<light|dark>-resolved.png  audio granted + network/remote-control requested
//   onboarding-<light|dark>-denied.png    audio denied (Open Settings fallback)
//
// Run: `swift run onboarding-snapshot [output-dir]`.

import AppKit
import AudiouterCore
import AudiouterOnboardingUI

/// Fake audio probe — never touches Core Audio.
struct SnapshotAudioProbe: AudioCapturePermissionProbing {
    let result: PermissionStatus
    func probe() async -> PermissionStatus { result }
}

/// Fake local-network primer — never touches the network.
struct SnapshotLocalNetwork: LocalNetworkPriming {
    func probe() async -> Bool { false }
}

/// Fake remote-control primer — never touches Accessibility.
struct SnapshotRemoteControl: RemoteControlPriming {
    func prime() {}
    func isTrusted() -> Bool { false }
}

/// Fake PTP helper manager — never touches `SMAppService`.
struct SnapshotPTPHelper: PTPHelperManaging {
    let statusToReport: PTPHelperStatus
    var status: PTPHelperStatus { statusToReport }
    func register() throws {}
    func openSystemSettingsLoginItems() {}
}

@MainActor
func makeViewController() -> OnboardingViewController {
    let suite = UserDefaults(suiteName: "onboarding-snapshot-\(UUID().uuidString)")!
    let model = SetupModel(audioProbe: SnapshotAudioProbe(result: .granted),
                           localNetwork: SnapshotLocalNetwork(),
                           remoteControl: SnapshotRemoteControl(),
                           ptpHelper: SnapshotPTPHelper(statusToReport: .enabled),
                           settings: AppSettings(defaults: suite))
    return OnboardingViewController(model: model,
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
              audio: PermissionStatus,
              network: PermissionStatus,
              remoteControl: PermissionStatus,
              outDir: URL) {
    let controller = makeViewController()
    let appearance = NSAppearance(named: appearanceName)
    let rootView = controller.test_rootView
    rootView.appearance = appearance
    controller.test_applyStatuses(audio: audio, isProbingAudio: false, network: network,
                                  remoteControl: remoteControl)
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
        let packageRoot = here.deletingLastPathComponent()   // onboarding-snapshot
            .deletingLastPathComponent()                     // Sources
            .deletingLastPathComponent()                     // AudiouterCore
            .deletingLastPathComponent()                     // repo root
        outDir = packageRoot.appendingPathComponent("dev/notes/onboarding-snapshots", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    print("Rendering onboarding snapshots to: \(outDir.path)")

    for (name, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        snapshot(appearanceName: name, label: "\(tag)-initial",
                 audio: .unknown, network: .unknown, remoteControl: .unknown, outDir: outDir)
        snapshot(appearanceName: name, label: "\(tag)-resolved",
                 audio: .granted, network: .requested, remoteControl: .requested, outDir: outDir)
        snapshot(appearanceName: name, label: "\(tag)-denied",
                 audio: .denied, network: .requested, remoteControl: .requested, outDir: outDir)
    }

    print("Done.")
    return 0
}

exit(MainActor.assumeIsolated { run() })
