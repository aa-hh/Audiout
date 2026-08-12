import AVFoundation
import Foundation

/// Unattended long-run counterpart to the interactive loop, which needs a human
/// at the keyboard and so can't answer what only surfaces over tens of minutes:
/// whether an N-speaker set keeps streaming under real airtime contention, and
/// where relative clock drift settles once the fresh-connect warm-up is past
/// (`dev/notes/bt-output-research-2026-08-07.md` §1 — latency is not
/// session-stable; a ~60ms warm-up decay runs for the first 20-30 minutes).
///
/// Starts every selected device at one shared instant, streams continuously,
/// and samples rendered frames, output RMS and each device's DAC clock on an
/// interval. A device whose frames or sample-time stop advancing between two
/// samples is a stall — the dropout signal. Ends with a per-device summary.

/// Interrupt flag, written from a signal handler and polled by the run loop.
///
/// Swift has no strictly async-signal-safe global: this is still lazily
/// initialised through an accessor, and `nonisolated(unsafe)` only silences the
/// concurrency check -- it changes no codegen. Safety here rests on two things
/// the code actually does: the type is single-word so the write cannot tear,
/// and `run()` touches the flag on the main thread BEFORE installing the
/// handlers, so initialisation can never happen inside one.
private nonisolated(unsafe) var gSoakInterrupted: sig_atomic_t = 0

enum SoakProbe {

    private static let defaultMinutes = 45
    /// Every health signal here is cumulative across one interval, so a
    /// dropout shorter than the interval that self-recovers leaves no trace.
    /// The interval IS the blind window — keep it short.
    private static let defaultIntervalSeconds = 10.0
    /// The first minutes after connect are the documented warm-up: clock jumps
    /// are expected and their ppm is meaningless. Drift is measured from a
    /// baseline captured AFTER this, so the reported figure is settled drift.
    private static let warmUpSeconds = 300.0

    private struct DeviceRun {
        let device: BTOutputDevice
        let engine: BTOutputEngine
        var lastFrames: UInt64 = 0
        var lastSampleTime: Double = 0
        var stalls = 0
        var silentSamples = 0
    }

    static func run(_ rawArgs: [String]) -> Int32 {
        var minutes = defaultMinutes
        var interval = defaultIntervalSeconds
        var only: [String] = []
        var logPath: String?
        var i = 0
        while i < rawArgs.count {
            if rawArgs[i] == "--minutes", i + 1 < rawArgs.count, let n = Int(rawArgs[i + 1]), n > 0 {
                minutes = n
                i += 2
            } else if rawArgs[i] == "--interval", i + 1 < rawArgs.count, let n = Double(rawArgs[i + 1]), n > 0 {
                interval = n
                i += 2
            } else if rawArgs[i] == "--log", i + 1 < rawArgs.count {
                logPath = rawArgs[i + 1]
                i += 2
            } else if rawArgs[i] == "--devices", i + 1 < rawArgs.count {
                only = rawArgs[i + 1].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
                i += 2
            } else {
                elog("soak: unexpected argument '\(rawArgs[i])' (usage: --soak [--minutes N] [--interval S] [--devices a,b] [--log path])")
                return 2
            }
        }

        var devices = BTDeviceEnumerator.listBluetoothOutputDevices().filter { !$0.isAggregate }
        if !only.isEmpty {
            devices = devices.filter { d in only.contains { d.name.lowercased().contains($0) } }
        }
        guard !devices.isEmpty else {
            elog("soak: no Bluetooth output devices found — pair and connect them in System Settings first.")
            return 1
        }

        let log = SoakLog(path: logPath)
        log.write(String(format: "soak: %d device(s), %d min, sampling every %.1fs", devices.count, minutes, interval))
        for d in devices { log.write("  - \(d.name)  uid=\(d.uid)") }

        // Start every device, then phase-align them on one shared instant so the
        // click/tone grids match — the same trick the interactive 's' key uses.
        var runs: [DeviceRun] = []
        for d in devices {
            let engine = BTOutputEngine(deviceID: d.id, deviceName: d.name, mode: .tone)
            do {
                try engine.start()
                runs.append(DeviceRun(device: d, engine: engine))
            } catch {
                log.write("soak: \(d.name) FAILED to start: \(error) — excluded from this run")
            }
        }
        guard !runs.isEmpty else {
            elog("soak: no device started.")
            return 1
        }
        let sharedStart = AVAudioTime(hostTime: mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: 0.3))
        for r in runs { r.engine.restartLoop(at: sharedStart) }

        // Force initialisation on this thread first: a signal arriving before
        // the flag's first main-thread touch would otherwise run the lazy-init
        // accessor inside the handler, which is not async-signal-safe.
        gSoakInterrupted = 0
        signal(SIGINT) { _ in gSoakInterrupted = 1 }
        signal(SIGTERM) { _ in gSoakInterrupted = 1 }

        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Double(minutes) * 60)
        var driftBaseline: [DriftSample] = []
        var baselineAt = Date()
        var ioRestarts = 0
        var driftReadings = 0

        while Date() < deadline, gSoakInterrupted == 0 {
            // Sliced so an interrupt lands within a second rather than waiting
            // out a whole interval — an operator who has to reach for kill -9
            // loses the summary this run exists to produce.
            let wakeAt = Date().addingTimeInterval(interval)
            while gSoakInterrupted == 0 {
                let remaining = wakeAt.timeIntervalSinceNow
                if remaining <= 0 { break }
                Thread.sleep(forTimeInterval: min(1, remaining))
            }
            if gSoakInterrupted != 0 { break }
            let elapsed = Date().timeIntervalSince(startedAt)

            var line = String(format: "[%5.1f min]", elapsed / 60)
            for idx in runs.indices {
                let stats = runs[idx].engine.currentRenderStats()
                let clock = runs[idx].engine.currentDeviceClock()
                let rms = runs[idx].engine.drainRMS()

                let framesStalled = stats.frames == runs[idx].lastFrames
                let clockStalled = clock.valid && clock.mSampleTime == runs[idx].lastSampleTime
                if framesStalled || clockStalled { runs[idx].stalls += 1 }
                if rms < 0.0001 { runs[idx].silentSamples += 1 }

                var flags = ""
                if framesStalled { flags += " FRAMES-STALL" }
                if clockStalled { flags += " CLOCK-STALL" }
                if rms < 0.0001 { flags += " SILENT" }
                line += String(format: " [%@ rms=%.4f frames=%llu%@]", runs[idx].device.name, rms, stats.frames, flags)

                runs[idx].lastFrames = stats.frames
                runs[idx].lastSampleTime = clock.mSampleTime
            }
            log.write(line)

            // Drift, measured only against a post-warm-up baseline.
            guard runs.count >= 2 else { continue }
            let current = runs.map { DriftSample(deviceName: $0.device.name, clock: $0.engine.currentDeviceClock()) }
            if driftBaseline.isEmpty {
                if elapsed >= warmUpSeconds {
                    driftBaseline = current
                    baselineAt = Date()
                    log.write("  drift: warm-up over — baseline captured, first reading in \(Int(DriftMonitor.minWindowSeconds))s")
                } else {
                    log.write(String(format: "  drift: warming up (%.0f/%.0fs before the baseline)", elapsed, warmUpSeconds))
                }
                continue
            }
            let readout = DriftMonitor.relativeDrift(baseline: driftBaseline, current: current)
            for l in readout.lines { log.write("  " + l) }
            if readout.baselinePoisoned {
                // A device's IO restarted and reset its DAC clock. That is a
                // dropout in its own right, and the stall check cannot see it:
                // the engine's frame counter accumulates across the restart, so
                // it keeps advancing and never trips.
                ioRestarts += 1
                log.write(String(format: "  drift: baseline dropped after %.1f min — a device's IO restarted mid-window (counts as a dropout)",
                                 Date().timeIntervalSince(baselineAt) / 60))
                driftBaseline = []
            } else if readout.measured {
                driftReadings += 1
            }
        }

        let wasInterrupted = gSoakInterrupted != 0
        log.write(wasInterrupted ? "soak: interrupted — stopping" : "soak: duration reached — stopping")
        for r in runs { r.engine.stop() }

        let ranMinutes = Date().timeIntervalSince(startedAt) / 60
        log.write(String(format: "soak SUMMARY after %.1f of %d min, %d device(s):", ranMinutes, minutes, runs.count))
        var clean = true
        for r in runs {
            log.write("  \(r.device.name): \(r.stalls) stall sample(s), \(r.silentSamples) silent sample(s)")
            if r.stalls > 0 || r.silentSamples > 0 { clean = false }
        }
        if ioRestarts > 0 {
            log.write("  \(ioRestarts) sample(s) in which a device's IO restarted — each is a dropout")
            clean = false
        }
        if !clean {
            log.write("  VERDICT: dropouts present — this device count is above the reliable ceiling.")
        } else if wasInterrupted {
            log.write(String(format: "  VERDICT: no dropouts seen, but the run was cut short at %.1f of %d min — not a clean bill of health for the full duration.", ranMinutes, minutes))
        } else {
            log.write("  VERDICT: no stalls, silence or IO restarts — this device count held for the whole run.")
        }

        // Whatever the verdict says, it is bounded by what this tool can see.
        // Stating the bounds beside the result is the difference between
        // evidence and a number someone over-reads later.
        log.write("  scope of that verdict:")
        log.write(String(format: "    - blind to any dropout shorter than the %.1fs sampling interval that recovers on its own", interval))
        log.write("    - level is the MEAN over each interval, so partial silence inside one is invisible at any interval length — only a fully dead interval trips SILENT")
        log.write("    - level is read at the mixer, upstream of the speaker: a connected-but-silent device (e.g. a headset flipped to call mode) reads as healthy here")
        log.write(String(format: "    - the IO-restart check rides on the drift baseline, so it is OFF for the first %.0fs of any run%@",
                         warmUpSeconds, runs.count < 2 ? " and for this single-device run entirely" : ""))
        if wasInterrupted {
            log.write(String(format: "    - INTERRUPTED at %.1f min of %d — not the full run", ranMinutes, minutes))
        }
        if runs.count < 2 {
            log.write("    - drift not measured: needs 2+ devices")
        } else if driftReadings == 0 {
            log.write(String(format: "    - drift never measured: needs %.0fs warm-up plus a %.0fs window of valid clock reads",
                             warmUpSeconds, DriftMonitor.minWindowSeconds))
        } else {
            log.write("    - drift on Bluetooth reads the host pacing clock, not each speaker's converter — treat it as unverified")
        }
        if let p = log.path { log.write("  log written to \(p)") }
        log.close()
        return 0
    }
}

/// Tees every line to stdout and, when a path is given, to a file — so a soak
/// left running in a detached shell still leaves evidence behind.
private final class SoakLog {
    let path: String?
    private var handle: FileHandle?

    init(path: String?) {
        self.path = path
        guard let path else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func write(_ line: String) {
        let stamped = Self.stamp() + " " + line
        print(stamped)
        fflush(stdout)
        handle?.write(Data((stamped + "\n").utf8))
    }

    func close() {
        try? handle?.close()
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
