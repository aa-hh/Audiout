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

enum SoakProbe {

    private static let defaultMinutes = 45
    private static let defaultIntervalSeconds = 60.0
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

    /// Set from the SIGINT handler so a Ctrl-C ends the run at the next sample
    /// instead of killing the process before the summary prints.
    private static var interrupted = false

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
        log.write("soak: \(devices.count) device(s), \(minutes) min, sampling every \(Int(interval))s")
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

        signal(SIGINT) { _ in SoakProbe.interrupted = true }
        signal(SIGTERM) { _ in SoakProbe.interrupted = true }

        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Double(minutes) * 60)
        var driftBaseline: [DriftSample] = []
        var baselineAt = Date()

        while Date() < deadline, !interrupted {
            Thread.sleep(forTimeInterval: interval)
            if interrupted { break }
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
                // A device's IO restarted and reset its DAC clock — which is
                // itself a dropout, and it invalidates the fixed baseline.
                log.write(String(format: "  drift: baseline dropped after %.1f min — a device's IO restarted mid-window",
                                 Date().timeIntervalSince(baselineAt) / 60))
                driftBaseline = []
            }
        }

        log.write(interrupted ? "soak: interrupted — stopping" : "soak: duration reached — stopping")
        for r in runs { r.engine.stop() }

        let ranMinutes = Date().timeIntervalSince(startedAt) / 60
        log.write(String(format: "soak SUMMARY after %.1f min, %d device(s):", ranMinutes, runs.count))
        var clean = true
        for r in runs {
            log.write("  \(r.device.name): \(r.stalls) stall sample(s), \(r.silentSamples) silent sample(s)")
            if r.stalls > 0 || r.silentSamples > 0 { clean = false }
        }
        log.write(clean
            ? "  VERDICT: no stalls or silence — this device count held for the whole run."
            : "  VERDICT: stalls/silence present — this device count is above the reliable ceiling.")
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
