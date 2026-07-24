import AudiouterCore
import Foundation

// A tiny headless driver so you can *watch* a backend behave with no UI. It
// starts discovery, prints every event, then scripts a few control changes
// (volume, mute, output-set) so you can see the echoes. Run it with:
//
//     swift run mock-speakers-demo
//
// Talks only to `OutputBackend`. This is the *mock*-speakers demo, so it pins
// `.mock` explicitly rather than resolving from the environment: the app-wide
// default is now `.native` (real speakers), and a demo whose whole point is
// fabricated devices must not silently spin up the native backend. See
// dev/README.md.
//
// Ctrl-C to quit (it also auto-exits after ~8s).

let backend = makeBackend(.mock)

func stamp() -> String {
    let ms = Int(Date().timeIntervalSince1970 * 1000) % 100000
    return String(format: "%05d", ms)
}

func describe(_ event: BackendEvent) -> String? {
    switch event {
    case .deviceAdded(let d):
        let sync = d.supportsAirPlay2 ? "AP2" : "AP1"
        return "＋ discovered  \(d.name.padding(toLength: 18, withPad: " ", startingAt: 0)) [\(sync)] vol \(d.volume)\(d.isSelected ? "  (in output set)" : "")"
    case .deviceRemoved(let id):
        return "－ removed     \(id)"
    case .deviceUpdated(let d):
        var flags: [String] = []
        if !d.isAvailable { flags.append("offline") }
        if d.isMuted { flags.append("muted") }
        if d.isSelected { flags.append("selected") }
        return "≈ updated     \(d.name.padding(toLength: 18, withPad: " ", startingAt: 0)) vol \(d.volume)  [\(flags.joined(separator: ","))]"
    case .level:
        return nil   // too chatty to print every 100ms; see the meter note below
    case .appLevel:
        return nil   // per-app analogue of `.level`; same too-chatty rule
    case .systemVolumeChanged(let volume):
        // Only `NativeBackend` ever emits this (it owns the system-volume listener);
        // under `mock` — this driver's default — it never fires. Handled anyway so
        // the switch stays exhaustive and `AIRPLAY_BACKEND=native` prints it.
        return "♪ system vol  \(volume) (changed outside the app)"
    case .routedApps(let deviceID, let appNames):
        // Only `NativeBackend` emits this (T6 per-app routing); under `mock` it
        // never fires. Handled so the switch stays exhaustive.
        return "♪ routed apps \(deviceID) ← [\(appNames.joined(separator: ", "))]"
    case .routedAppRunning(let bundleID, let isRunning):
        // Only `NativeBackend` emits this (T4 relaunch fix); under `mock` it
        // never fires. Handled so the switch stays exhaustive.
        return "♪ app running  \(bundleID) isRunning:\(isRunning)"
    case .remoteTransport(let command):
        // Also native-only (a key pressed on the speaker itself); never under mock.
        return "▶ remote key  \(command) (from a speaker)"
    case .streamHealth(let id, let recovering):
        // Also native-only (T8 rebind-recovery signal); never under mock.
        return "⚠ stream health \(id) recovering:\(recovering)"
    }
}

let stream = backend.makeEventStream()

// Consume events.
Task {
    var levelCount = 0
    for await event in stream {
        if case .level = event { levelCount += 1; continue }
        if let line = describe(event) { print("[\(stamp())] \(line)") }
        _ = levelCount
    }
}

// Script some interactions after discovery settles.
Task {
    backend.start()
    try? await Task.sleep(nanoseconds: 3_000_000_000)

    print("\n— nudging Sonos Move to 80 —")
    backend.setVolume(80, for: "sonos-move")

    try? await Task.sleep(nanoseconds: 800_000_000)
    print("\n— muting Move 2 —")
    backend.setMuted(true, for: "sonos-move-2")

    try? await Task.sleep(nanoseconds: 800_000_000)
    print("\n— activating a 'Downstairs' group: Sonos Move + Office —")
    backend.setOutputSet(["sonos-move", "office"])

    try? await Task.sleep(nanoseconds: 2_000_000_000)
    print("\n(level meters are firing continuously for playing devices — hidden here to keep the log readable)")
    print("done.")
    backend.stop()
    exit(0)
}

RunLoop.main.run()
