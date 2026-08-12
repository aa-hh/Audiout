import AVFoundation
import Darwin
import Foundation

// ============================================================================
// bt-multi-spike — throwaway CLI for the mixed-brand multi-Bluetooth-output
// feasibility spike. T6 owns/expands argument handling; keep additions here
// small and clearly sectioned per task.
// ============================================================================

// MARK: - T2: --list (Bluetooth output-device enumeration)

func runList() {
    let found = BTDeviceEnumerator.listBluetoothOutputDevices()
    if found.isEmpty {
        print("bt-multi-spike: no Bluetooth output devices found (nothing paired/connected).")
        return
    }
    print("bt-multi-spike: Bluetooth output devices:")
    for d in found {
        let tag = d.isAggregate ? " [AGGREGATE — EXCLUDED]" : ""
        print("  id=\(d.id) name=\"\(d.name)\" uid=\(d.uid)\(tag)")
    }
}

// ============================================================================
// MARK: - T6: interactive control loop
//
// Raw-mode single-keypress control over N per-device BTOutputEngines (T3),
// so Alec can add/remove Bluetooth speakers live and hear where the setup
// falls apart (dropout ceiling), and nudge per-device delay/volume by ear.
// The terminal MUST come back to normal on every exit path (q, SIGINT,
// SIGTERM) — see restoreTerminal()/installSignalHandlers() below.
// ============================================================================

// MARK: Raw-mode termios (global — the signal handler needs unrestricted
// access to the saved settings, so this can't hang off an instance).

private var gOriginalTermios = termios()
private var gRawModeActive = false

/// Puts stdin into raw mode: no line buffering (ICANON off), no local echo,
/// one byte at a time (VMIN=1, VTIME=0). Saves the prior settings in
/// `gOriginalTermios` so `restoreTerminal()` can undo this exactly.
func enableRawMode() {
    tcgetattr(STDIN_FILENO, &gOriginalTermios)
    var raw = gOriginalTermios
    raw.c_lflag &= ~UInt(ECHO | ICANON)
    withUnsafeMutablePointer(to: &raw.c_cc) { ccPtr in
        ccPtr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    gRawModeActive = true
}

/// Restores whatever termios settings were in effect before `enableRawMode()`.
/// Idempotent and safe to call from a signal handler (only touches C globals
/// and calls a plain C syscall — no allocation, no Swift runtime machinery).
func restoreTerminal() {
    if gRawModeActive {
        tcsetattr(STDIN_FILENO, TCSANOW, &gOriginalTermios)
        gRawModeActive = false
    }
}

/// CRITICAL: install SIGINT/SIGTERM handlers that restore the terminal
/// before the process dies — without this, Ctrl-C during raw-mode input
/// leaves the invoking shell silently un-echoing and un-line-buffered.
func installSignalHandlers() {
    signal(SIGINT) { _ in
        restoreTerminal()
        _exit(0)
    }
    signal(SIGTERM) { _ in
        restoreTerminal()
        _exit(0)
    }
}

/// One selectable Bluetooth output device slot in the interactive session:
/// its enumerated identity (T2), and — once "added" — the live engine (T3)
/// playing to it plus the delay/volume this session has dialed in (T3's
/// engine has no getters, so the applied values are tracked here for
/// display and for re-applying after a live source-mode swap).
private struct DeviceSlot {
    let index: Int // 0-based; presented to the user as index+1
    let device: BTOutputDevice
    var engine: BTOutputEngine?
    var delayMs: Double = 0
    var volume: Float = 1.0
}

private final class InteractiveController {
    private let lock = NSLock()
    private var slots: [DeviceSlot]
    private var selected: Int = 0
    private var mode: ToneSourceMode = .tone
    private var lastSamples: [DriftSample] = []
    // Uptime-clock stamp of when `lastSamples` was captured — lets
    // printDriftLocked() tell whether the baseline is stale enough to
    // refresh, independent of the 2s status-loop cadence that calls it.
    private var baselineCapturedAtNanos: UInt64 = 0
    private(set) var shouldQuit = false

    init(devices: [BTOutputDevice]) {
        self.slots = devices.enumerated().map { DeviceSlot(index: $0.offset, device: $0.element) }
    }

    // MARK: Banner / help

    func printBanner() {
        print("bt-multi-spike — interactive control")
        print("devices:")
        for slot in slots {
            print("  \(slot.index + 1). \(slot.device.name)  uid=\(slot.device.uid)")
        }
        print("""
        keys:
          1-9  select a device by number (target for a/r/+/-/[/])
          a    add/start the selected device
          r    remove/stop the selected device
          +/=  nudge selected device's delay +10ms
          -/_  nudge selected device's delay -10ms
          ]    selected device volume +0.05
          [    selected device volume -0.05
          t    toggle source click<->tone (live, all active devices)
          s    resync all loops to one shared instant (isolate real per-device latency)
          d    print a drift readout now
          l    reprint device list + status
          q    quit (restores terminal)
        status + drift print automatically every few seconds.
        """)
    }

    // MARK: Key handling (runs on the blocking-read thread)

    func handle(_ key: Character) {
        lock.lock()
        defer { lock.unlock() }

        if let digit = key.wholeNumberValue, digit >= 1, digit <= 9, digit - 1 < slots.count {
            selected = digit - 1
            print("[select] #\(digit) \(slots[selected].device.name)")
            return
        }

        switch key {
        case "a":
            addSelectedLocked()
        case "r":
            removeSelectedLocked()
        case "+", "=":
            nudgeDelayLocked(by: 10)
        case "-", "_":
            nudgeDelayLocked(by: -10)
        case "]":
            nudgeVolumeLocked(by: 0.05)
        case "[":
            nudgeVolumeLocked(by: -0.05)
        case "t":
            toggleSourceLocked()
        case "s":
            resyncAllLocked()
        case "d":
            printDriftLocked()
        case "l":
            printStatusLocked(header: true)
        case "q":
            shouldQuit = true
            print("[quit] stopping all devices...")
            stopAllLocked()
        default:
            break
        }
    }

    private func addSelectedLocked() {
        var slot = slots[selected]
        guard slot.engine == nil else {
            print("[add] #\(selected + 1) \(slot.device.name) already active")
            return
        }
        let engine = BTOutputEngine(deviceID: slot.device.id, deviceName: slot.device.name, mode: mode)
        do {
            try engine.start()
            engine.setDelay(ms: slot.delayMs)
            engine.setVolume(slot.volume)
            slot.engine = engine
            slots[selected] = slot
            print("[add] #\(selected + 1) \(slot.device.name) started (mode=\(mode))")
        } catch {
            print("[add] #\(selected + 1) \(slot.device.name) FAILED: \(error)")
        }
    }

    private func removeSelectedLocked() {
        var slot = slots[selected]
        guard let engine = slot.engine else {
            print("[remove] #\(selected + 1) \(slot.device.name) not active")
            return
        }
        engine.stop()
        slot.engine = nil
        slots[selected] = slot
        print("[remove] #\(selected + 1) \(slot.device.name) stopped")
    }

    private func nudgeDelayLocked(by deltaMs: Double) {
        var slot = slots[selected]
        slot.delayMs = max(0, slot.delayMs + deltaMs)
        slots[selected] = slot
        slot.engine?.setDelay(ms: slot.delayMs)
        print("[delay] #\(selected + 1) \(slot.device.name) -> \(slot.delayMs)ms")
    }

    private func nudgeVolumeLocked(by delta: Float) {
        var slot = slots[selected]
        slot.volume = min(1, max(0, slot.volume + delta))
        slots[selected] = slot
        slot.engine?.setVolume(slot.volume)
        print(String(format: "[volume] #%d %@ -> %.2f", selected + 1, slot.device.name, slot.volume))
    }

    /// Live source swap. BTOutputEngine's mode is fixed at construction, so
    /// "toggling" a running engine means: stop it, build a fresh engine
    /// against the same device with the new mode, re-apply this session's
    /// delay/volume, and start it — from outside BTOutputEngine, using only
    /// its existing public API (this file does not modify BTOutputEngine.swift).
    private func toggleSourceLocked() {
        mode = (mode == .tone) ? .click : .tone
        print("[source] mode -> \(mode)")
        for i in slots.indices {
            guard slots[i].engine != nil else { continue }
            slots[i].engine?.stop()
            let slot = slots[i]
            let fresh = BTOutputEngine(deviceID: slot.device.id, deviceName: slot.device.name, mode: mode)
            do {
                try fresh.start()
                fresh.setDelay(ms: slot.delayMs)
                fresh.setVolume(slot.volume)
                slots[i].engine = fresh
            } catch {
                print("[source] #\(i + 1) \(slot.device.name) restart FAILED: \(error)")
                slots[i].engine = nil
            }
        }
        // Recreating the engines restarts each device's IO, which resets its DAC
        // sampleTime -- so the drift baseline (captured against the old clocks) is
        // now stale. Drop it so the drift readout re-measures from a fresh window.
        lastSamples = []
    }

    /// Restart every active device's loop at ONE shared host time, phase-locking
    /// all the click/tone grids. A steady tone can't reveal a constant offset,
    /// but the click can — and before a resync that click offset is polluted by
    /// the arbitrary gap between when each device was added. After a resync the
    /// only offset left on the click is each speaker's REAL per-device latency,
    /// so nudging +/- until the clicks fold together measures that latency.
    private func resyncAllLocked() {
        let activeIdx = slots.indices.filter { slots[$0].engine != nil }
        guard !activeIdx.isEmpty else {
            print("[resync] no active devices")
            return
        }
        // One shared start instant ~0.3s out, so every engine has time to
        // schedule its loop to the same host time.
        let when = AVAudioTime(hostTime: mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: 0.3))
        for i in activeIdx {
            slots[i].engine?.restartLoop(at: when)
        }
        print("[resync] \(activeIdx.count) device loops restarted at one shared instant — switch to the click (t) and nudge +/- to align; the delay each speaker needs is its real latency")
    }

    private func stopAllLocked() {
        for i in slots.indices {
            slots[i].engine?.stop()
            slots[i].engine = nil
        }
    }

    // MARK: Status / drift (runs on the periodic-status thread too, hence locked)

    func statusTick() {
        lock.lock()
        defer { lock.unlock() }
        printStatusLocked(header: false)
        printDriftLocked()
    }

    private func printStatusLocked(header: Bool) {
        if header {
            print("devices:")
            for slot in slots {
                let mark = slot.engine != nil ? "*" : " "
                print("  \(mark)\(slot.index + 1). \(slot.device.name)")
            }
        }
        let active = slots.filter { $0.engine != nil }
        guard !active.isEmpty else {
            print("status: no devices active (select one with 1-9, then 'a')")
            return
        }
        var line = "status:"
        for slot in active {
            guard let engine = slot.engine else { continue }
            let rms = engine.drainRMS()
            let stats = engine.currentRenderStats()
            line += String(
                format: " [#%d %@ delay=%.0fms vol=%.2f rms=%.4f frames=%llu]",
                slot.index + 1, slot.device.name, slot.delayMs, slot.volume, rms, stats.frames)
        }
        print(line)
    }

    private func printDriftLocked() {
        let active = slots.filter { $0.engine != nil }
        guard active.count >= 2 else {
            lastSamples = []
            return
        }
        let current = active.compactMap { slot -> DriftSample? in
            guard let engine = slot.engine else { return nil }
            return DriftSample(deviceName: slot.device.name, clock: engine.currentDeviceClock())
        }
        // BUGFIX: the earlier version reset the baseline to `current` the moment
        // it aged past the window and returned WITHOUT computing -- so at the one
        // instant the window was finally >= 30s it was thrown away, leaving the
        // readout permanently stuck on "not enough data yet". Correct model: set
        // a baseline once (on startup, or when the active device set changes),
        // show a warm-up countdown until the window matures, then keep the
        // baseline FIXED and report a live reading over a >= 30s (steadily
        // growing, so steadily steadier) window. Add/remove a speaker to restart.
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        if lastSamples.isEmpty || lastSamples.count != current.count {
            lastSamples = current
            baselineCapturedAtNanos = nowNanos
            print(String(format: "drift: measuring... (0/%.0fs window)", DriftMonitor.minWindowSeconds))
            return
        }
        let baselineAgeSeconds = Double(nowNanos &- baselineCapturedAtNanos) / 1_000_000_000.0
        if baselineAgeSeconds < DriftMonitor.minWindowSeconds {
            print(String(format: "drift: measuring... (%.0f/%.0fs window)", baselineAgeSeconds, DriftMonitor.minWindowSeconds))
            return
        }
        let readout = DriftMonitor.relativeDrift(baseline: lastSamples, current: current)
        for l in readout.lines { print(l) }
        if readout.baselinePoisoned {
            // A device's IO restarted mid-window (source toggle / config-change
            // recovery) and reset its DAC clock, so the fixed baseline is stale.
            // Drop it; the next tick captures a fresh baseline over clean reads.
            lastSamples = []
        }
    }
}

/// Blocking single-byte read loop. Runs on the main thread so the process
/// naturally stays alive on it; returns once `q` sets shouldQuit.
private func runKeyLoop(_ controller: InteractiveController) {
    var byte: UInt8 = 0
    while !controller.shouldQuit {
        let n = read(STDIN_FILENO, &byte, 1)
        guard n == 1 else {
            if errno == EINTR { continue }
            break
        }
        let scalar = Unicode.Scalar(byte)
        controller.handle(Character(scalar))
    }
}

/// Periodic status/drift printer, run on a background thread so it doesn't
/// block (or get blocked by) the key-read loop.
private func runStatusLoop(_ controller: InteractiveController) {
    while !controller.shouldQuit {
        Thread.sleep(forTimeInterval: 2.0)
        if controller.shouldQuit { break }
        controller.statusTick()
    }
}

func runInteractive() {
    guard isatty(STDIN_FILENO) != 0 else {
        elog("bt-multi-spike: interactive mode needs a terminal (tty). Use --list or --selftest for non-interactive use.")
        exit(1)
    }
    let devices = BTDeviceEnumerator.listBluetoothOutputDevices().filter { !$0.isAggregate }
    guard !devices.isEmpty else {
        print("bt-multi-spike: no Bluetooth output devices found — pair/connect one and retry.")
        exit(1)
    }

    let controller = InteractiveController(devices: devices)
    controller.printBanner()

    installSignalHandlers()
    enableRawMode()

    let statusThread = Thread { runStatusLoop(controller) }
    statusThread.start()

    runKeyLoop(controller)

    restoreTerminal()
    exit(0)
}

// MARK: - Main

let args = CommandLine.arguments.dropFirst()
if args.contains("--list") {
    runList()
    exit(0)
}

// MARK: - Wave 0 probes (BT-SPIKE-CONNECT + pacing-clock verification)
// These take sub-arguments, so they strip their own flag and hand the rest on.

if args.contains("--connect-probe") {
    exit(ConnectProbe.run(args.filter { $0 != "--connect-probe" }))
}

if args.contains("--pacing-probe") {
    exit(PacingProbe.run(args.filter { $0 != "--pacing-probe" }))
}

// MARK: - Perceptual probe: how fine an offset reads as image POSITION
// (throwaway — decides whether the by-ear wizard asks "one tick or two?"
// or "which side does it lean?"). Emits audio; the operator runs it live.

if args.contains("--lateralization-probe") {
    exit(LateralizationProbe.run(args.filter { $0 != "--lateralization-probe" }))
}

// MARK: - Unattended soak (dropout ceiling + settled drift over tens of minutes)

if args.contains("--soak") {
    exit(SoakProbe.run(args.filter { $0 != "--soak" }))
}

// MARK: - Drift meter (acoustic inter-speaker clock drift via the built-in mic)

if args.contains("--drift-meter-selftest") {
    exit(DriftMeterProbe.runSelfTest())
}

if args.contains("--drift-meter") {
    exit(DriftMeterProbe.run(args.filter { $0 != "--drift-meter" }))
}

// MARK: - T5: --selftest (flow-proof against the built-in output device)

if args.contains("--selftest") {
    exit(FlowCheck.runSelfTest())
}

// MARK: - T2: --drift-selftest (validates the real-DAC-clock reading path)

if args.contains("--drift-selftest") {
    exit(FlowCheck.runDriftSelfTest())
}

if args.contains("-h") || args.contains("--help") {
    print("bt-multi-spike — macOS Bluetooth multi-device feasibility spike")
    print("usage: bt-multi-spike            (interactive control loop)")
    print("       bt-multi-spike --list")
    print("       bt-multi-spike --selftest")
    print("       bt-multi-spike --drift-selftest")
    print("       bt-multi-spike --connect-probe [name-or-address] [--disconnect]")
    print("       bt-multi-spike --pacing-probe <name-or-uid> [--seconds N]")
    print("       bt-multi-spike --lateralization-probe <A> <B> [--demo | --smoke]")
    print("       bt-multi-spike --soak [--minutes N] [--interval S] [--devices a,b] [--log path]")
    print("       bt-multi-spike --drift-meter <deviceA> <deviceB> [--seconds N] [--freqA hz] [--freqB hz] [--log path]")
    print("       bt-multi-spike --drift-meter-selftest")
    exit(0)
}

runInteractive()
