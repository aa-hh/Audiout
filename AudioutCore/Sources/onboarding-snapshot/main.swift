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
//   onboarding-<light|dark>-step1-audio.png        row 1 live, nothing granted
//   onboarding-<light|dark>-step2-network.png      audio granted, row 2 live
//   onboarding-<light|dark>-step3-bluetooth.png    audio + network in, row 3 live
//   onboarding-<light|dark>-step2-waiting.png      row 2's prime in flight (the ribbon's wait)
//   onboarding-<light|dark>-step4-speakersync.png  bluetooth skipped, Login Items live
//   onboarding-<light|dark>-denied.png             audio denied → Settings mode demo
//   onboarding-<light|dark>-step5-remotecontrol.png  the two-stage handoff at rest
//   onboarding-<light|dark>-remote-control-retry.png the prompt is spent → plain pane
//   onboarding-<light|dark>-browse-granted.png     a decided row opened for reading
//   onboarding-<light|dark>-skip-reopened.png      a skipped row pressed again — the ask re-armed
//   onboarding-<light|dark>-checking.png           every row decided, the sixth row's check mid-flight
//   onboarding-<light|dark>-complete.png           check passed — six checked rows, settled finale + Start listening CTA
//   onboarding-<light|dark>-permission-lost.png    the re-entry header message
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
import AudioutCore
import AudioutOnboardingUI

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

/// A prime that never answers, so a fixture can render the in-flight caption —
/// the state a real first ask sits in for as long as the system dialog is up.
struct SnapshotWaitingLocalNetwork: LocalNetworkPriming {
    func probe() async -> Bool { false }
    func prime(browseSeconds: TimeInterval,
               onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
        // Parks for the life of the tool: the fixture renders while it waits.
        // A sleep rather than a never-resumed continuation, which is the same
        // wait but makes the runtime log a continuation-leak warning.
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        return .undecided
    }
}

/// Grants the walk's browse, then parks every later one — so the AUTOMATIC
/// final check that follows the last decision is caught mid-flight and the
/// sixth row renders its running state.
final class SnapshotCheckParkedLocalNetwork: LocalNetworkPriming, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func probe() async -> Bool { true }
    func prime(browseSeconds: TimeInterval,
               onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
        let isWalk = lock.withLock { calls += 1; return calls == 1 }
        if isWalk {
            onReachable()
            return .granted(foundSpeakers: 3)
        }
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        return .undecided
    }
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
    /// Render Local Network's Allow MID-FLIGHT (the prime parked on an
    /// unanswered dialog), which is the only way to see the in-flight caption.
    var waitingOnLocalNetwork = false
    /// Render the sixth row's automatic check MID-FLIGHT: the walk's browse
    /// grants, the check's audit re-browse parks, and the fixture is the wait.
    var waitingOnFinalCheck = false
    /// Cards to Skip, after the allows. The only way past an optional step the
    /// fixture's world can't satisfy.
    var skip: [SetupStep] = []
    /// A spine row to PRESS once every decision above is made — a decided row
    /// opens for reading in the hero pane, a skipped one re-arms its ask.
    var press: SetupStep?
    var reason: OnboardingReason = .firstRun
    /// Whether this build has an analytics sink, and therefore a sixth card to
    /// offer. TRUE by default because that is the shipping build; the fixtures
    /// that walk to the finale have to answer it like any other card.
    var usageStatsAvailable = true
}

@MainActor
func makeViewController(_ world: SnapshotWorld) -> OnboardingViewController {
    let suite = makeSnapshotDefaults()
    let bluetooth = SimulatedBluetoothPermission(status: world.bluetooth)
    let localNetwork: LocalNetworkPriming
    if world.waitingOnLocalNetwork {
        localNetwork = SnapshotWaitingLocalNetwork()
    } else if world.waitingOnFinalCheck {
        localNetwork = SnapshotCheckParkedLocalNetwork()
    } else {
        localNetwork = SnapshotLocalNetwork(foundSpeakers: world.foundSpeakers)
    }
    let model = SetupModel(audioProbe: SnapshotAudioProbe(result: world.audio),
                           localNetwork: localNetwork,
                           remoteControl: SnapshotRemoteControl(trusted: world.remoteControlTrusted),
                           ptpHelper: SnapshotPTPHelper(statusToReport: world.ptpHelper),
                           bluetoothReader: bluetooth,
                           bluetoothPrimer: bluetooth,
                           settings: AppSettings(defaults: suite),
                           usageStatsAvailable: world.usageStatsAvailable)
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
    let appearance = snapshotAppearance(appearanceName)
    let rootView = controller.test_rootView
    rootView.appearance = appearance
    // Awaited, unlike the load-time fire-and-forget: Bluetooth and Remote
    // Control only ever reach `.granted` through the silent re-read, so a
    // fixture that means "these are already granted" has to wait for it.
    await controller.test_refreshStatuses()
    await controller.test_allow(world.allow)
    // Before any waiting: a skipped card is a DECIDED card, and the final
    // check below is what waits on every card being decided.
    world.skip.forEach(controller.test_tapSkip)
    // The row press comes last, on a spine where every decision is already made:
    // a browse is a reading position on a DECIDED row, and a re-arm needs the
    // skip to have happened.
    if let press = world.press { _ = await controller.test_pressRow(press) }
    if world.waitingOnLocalNetwork {
        // Deliberately NOT awaited: this prime never answers, and the fixture is
        // the wait itself. Poll for the ribbon's wait rather than sleeping a guess.
        Task { await controller.test_tapAllow(.localNetwork) }
        for _ in 0..<200 where !controller.test_ribbonIsWaiting {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    if world.waitingOnFinalCheck {
        // The walk's last decision auto-started the check, whose audit browse
        // is parked — poll for the running row, and never await the check.
        for _ in 0..<200 where controller.test_checkRowState != .running {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    } else {
        // Complete fixtures render AFTER the beat: check passed, CTA + finale in.
        await controller.test_awaitFinalCheck()
    }
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
                                  allow: [.audio, .localNetwork, .usageStats])

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
            .deletingLastPathComponent()                     // AudioutCore
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
        // Local Network's Allow fired and the system dialog is still up: the
        // card shows the wait, and says what it is waiting for.
        await snapshot(appearanceName: name, label: "\(tag)-step2-waiting",
                       world: SnapshotWorld(allow: [.audio], waitingOnLocalNetwork: true),
                       outDir: outDir)
        // Speaker Sync active: the Login Items pane with the toggle. A
        // single-stage demo — "Open Login Items…" opens System Settings
        // directly, with no alert in between.
        await snapshot(appearanceName: name, label: "\(tag)-step4-speakersync",
                       world: SnapshotWorld(allow: [.audio, .localNetwork],
                                            skip: [.bluetooth]),
                       outDir: outDir)
        // Audio denied: the card's Allow has become the Settings deep link, and
        // the demo swaps to the Settings-pane miniature.
        await snapshot(appearanceName: name, label: "\(tag)-denied",
                       world: SnapshotWorld(audio: .denied, allow: [.audio]), outDir: outDir)
        // Remote Control's first ask: the demo is the TWO-STAGE handoff —
        // settled on stage one, the Accessibility alert with its "Open System
        // Settings" button, because that alert is what the Allow raises.
        await snapshot(appearanceName: name, label: "\(tag)-step5-remotecontrol",
                       world: SnapshotWorld(bluetooth: .granted, ptpHelper: .enabled,
                                            allow: [.audio, .localNetwork]),
                       outDir: outDir)
        // Remote Control asked and is still waiting: the prompt is spent, so its
        // Allow has become the deep link and the demo is the plain pane.
        await snapshot(appearanceName: name, label: "\(tag)-remote-control-retry",
                       world: SnapshotWorld(bluetooth: .granted, ptpHelper: .enabled,
                                            allow: [.audio, .localNetwork, .remoteControl]),
                       outDir: outDir)
        // A DECIDED row opened for reading: the hero shows the pane its switch
        // lives on, resting already ON, with the quiet way back to it.
        await snapshot(appearanceName: name, label: "\(tag)-browse-granted",
                       world: SnapshotWorld(allow: [.audio, .localNetwork], press: .audio),
                       outDir: outDir)
        // A skipped row pressed again: the skip comes back, and the ribbon says
        // it cost nothing.
        await snapshot(appearanceName: name, label: "\(tag)-skip-reopened",
                       world: SnapshotWorld(allow: [.audio, .localNetwork],
                                            skip: [.bluetooth], press: .bluetooth),
                       outDir: outDir)
        // Every card decided, the sixth row's automatic check still running:
        // no CTA, no finale yet — the beat the redesign exists to show.
        await snapshot(appearanceName: name, label: "\(tag)-checking",
                       world: SnapshotWorld(remoteControlTrusted: true,
                                            bluetooth: .granted,
                                            ptpHelper: .enabled,
                                            allow: [.audio, .localNetwork, .usageStats],
                                            waitingOnFinalCheck: true),
                       outDir: outDir)
        // The sixth card: the one stage that is not a rehearsal of a macOS
        // surface, because this step raises none. The frame carries the LEDGER
        // — what a yes would send, over what it never sends, each of those
        // struck through — and the bar offers "No Thanks" rather than the
        // shared "Skip for now", since this answer is final.
        await snapshot(appearanceName: name, label: "\(tag)-step6-usagestats",
                       world: SnapshotWorld(remoteControlTrusted: true,
                                            bluetooth: .granted,
                                            ptpHelper: .enabled,
                                            allow: [.audio, .localNetwork]),
                       outDir: outDir)
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
