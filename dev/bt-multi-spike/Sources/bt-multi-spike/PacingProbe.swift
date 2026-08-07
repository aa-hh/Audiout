import AudioToolbox
import Foundation

// ============================================================================
// PacingProbe — passive sampler for a Bluetooth output device's pacing clock
// (research: dev/notes/bt-output-research-2026-08-07.md §3). On a BT device,
// AudioDeviceGetCurrentTime reads the HOST-side BT stack's pacing clock, not
// the speaker's remote DAC — and that clock is suspected to re-anchor (jump)
// when the stack re-buffers, e.g. during the fresh-connect warm-up window.
//
// The probe samples the clock at ~1 Hz via BTOutputEngine.currentDeviceClock
// (query-first, timing-only IOProc fallback, installLock/clockLock discipline
// — reused, not re-derived) WITHOUT ever starting the AVAudioEngine graph, so
// nothing is rendered: worst case the fallback IOProc runs the device with
// silent zero-filled buffers. It logs the rate-normalized clock position vs
// host monotonic time per sample, reports discontinuities the moment they
// happen, then summarizes the ppm trend per steady segment plus every jump's
// magnitude and timestamp. Only meaningful live against real BT hardware.
// ============================================================================

enum PacingProbe {

    /// A step between two ~1s-apart samples larger than this is a clock JUMP
    /// (stack re-anchor / IO restart), not drift — real BT clock drift is a
    /// few hundred ppm, i.e. well under 0.5 ms per second.
    private static let jumpThresholdMs = 2.0
    private static let sampleIntervalSeconds = 1.0
    private static let defaultDurationSeconds = 60
    /// Minimum span a steady segment needs before its ppm figure is worth
    /// printing — under this, clock quantization dominates the slope.
    private static let minSegmentSeconds = 5.0

    private struct Sample {
        let tSeconds: Double // vs baseline, on the device-reported host stamp
        let sampleTime: Double
        let deviationMs: Double // rate-normalized clock position minus host elapsed
    }

    private struct Jump {
        let tSeconds: Double
        let magnitudeMs: Double
        let reason: String
    }

    static func run(_ rawArgs: [String]) -> Int32 {
        var query: String?
        var durationSeconds = defaultDurationSeconds
        var i = 0
        while i < rawArgs.count {
            if rawArgs[i] == "--seconds", i + 1 < rawArgs.count, let n = Int(rawArgs[i + 1]), n > 0 {
                durationSeconds = n
                i += 2
            } else if query == nil, !rawArgs[i].hasPrefix("-") {
                query = rawArgs[i]
                i += 1
            } else {
                elog("pacing-probe: unexpected argument '\(rawArgs[i])' (usage: --pacing-probe <name-or-uid> [--seconds N])")
                return 2
            }
        }
        guard let query else {
            elog("pacing-probe: which device? usage: --pacing-probe <name-or-uid> [--seconds N]")
            return 2
        }

        let candidates = BTDeviceEnumerator.listBluetoothOutputDevices().filter { !$0.isAggregate }
        let lowered = query.lowercased()
        let matches = candidates.filter { $0.name.lowercased().contains(lowered) || $0.uid.lowercased().contains(lowered) }
        guard matches.count == 1, let device = matches.first else {
            elog("pacing-probe: '\(query)' matched \(matches.count) Bluetooth output device(s); available:")
            for c in candidates { elog("  id=\(c.id) name=\"\(c.name)\" uid=\(c.uid)") }
            return 1
        }

        // PASSIVE: the engine is never start()ed — only its clock reader (and,
        // if the bare query refuses on an idle device, its timing-only IOProc
        // fallback) is used. No tone is scheduled, nothing is rendered.
        let engine = BTOutputEngine(deviceID: device.id, deviceName: device.name, mode: .tone)
        var nominalRate = BTOutputEngine.readNominalSampleRate(device.id) ?? 0
        print("pacing-probe: device id=\(device.id) name=\"\(device.name)\" nominalRate=\(nominalRate) — sampling ~1 Hz for \(durationSeconds)s (passive, no audio out)")

        var baseline: BTDeviceClock?
        var previous: Sample?
        var segmentStart: Sample?
        var segments: [String] = []
        var jumps: [Jump] = []
        var lastRawSampleTime = -Double.greatestFiniteMagnitude
        var pathsSeen: Set<String> = []

        func closeSegment(at end: Sample?) {
            guard let start = segmentStart, let end, end.tSeconds > start.tSeconds else { return }
            let span = end.tSeconds - start.tSeconds
            guard span >= minSegmentSeconds else {
                segments.append(String(format: "  [t=+%.0fs .. +%.0fs] too short (%.0fs) for a ppm figure", start.tSeconds, end.tSeconds, span))
                return
            }
            // deviation is in ms; ppm = (Δdeviation seconds / Δt seconds) * 1e6.
            let ppm = (end.deviationMs - start.deviationMs) * 1000.0 / span
            segments.append(String(format: "  [t=+%.0fs .. +%.0fs] %+.1f ppm over %.0fs", start.tSeconds, end.tSeconds, ppm, span))
        }

        for tick in 0...Int(Double(durationSeconds) / sampleIntervalSeconds) {
            if tick > 0 { Thread.sleep(forTimeInterval: sampleIntervalSeconds) }

            // A mid-run nominal-rate change (rate renegotiation / HFP-style
            // collapse) invalidates the deviation denominator — report it and
            // restart the measurement rather than printing garbage.
            if let rate = BTOutputEngine.readNominalSampleRate(device.id), rate != nominalRate {
                print("pacing-probe: NOMINAL RATE CHANGED \(nominalRate) -> \(rate) — restarting measurement (rate renegotiation mid-run)")
                nominalRate = rate
                closeSegment(at: previous)
                baseline = nil
                previous = nil
                segmentStart = nil
                continue
            }

            let clock = engine.currentDeviceClock()
            pathsSeen.insert("\(engine.lastClockPath)")
            guard clock.valid else {
                print("pacing-probe: waiting for a valid clock read (query refused; IOProc fallback warming up)...")
                continue
            }

            // A frozen sampleTime means the device isn't running IO and the
            // query hands back a stale stamp — deviation math would read that
            // as a runaway backwards drift. Say so and hold.
            if clock.mSampleTime == lastRawSampleTime {
                print("pacing-probe: device clock FROZEN (device idle, no IO running) — waiting; play audio to the device or let the IOProc fallback engage")
                closeSegment(at: previous)
                baseline = nil
                previous = nil
                segmentStart = nil
                continue
            }
            lastRawSampleTime = clock.mSampleTime

            guard let base = baseline else {
                baseline = clock
                continue
            }

            if clock.mSampleTime < base.mSampleTime || clock.hostTimeNanos <= base.hostTimeNanos {
                // sampleTime running backwards = the device's IO restarted and
                // reset its clock origin (same poison the drift readout guards).
                let t = previous?.tSeconds ?? 0
                jumps.append(Jump(tSeconds: t, magnitudeMs: .nan, reason: "clock restarted (IO reset)"))
                print(String(format: "pacing-probe: JUMP at t=+%.0fs — clock RESTARTED (sampleTime went backwards); rebaselining", t))
                closeSegment(at: previous)
                baseline = clock
                previous = nil
                segmentStart = nil
                continue
            }

            let t = Double(clock.hostTimeNanos - base.hostTimeNanos) / 1_000_000_000.0
            let deviationMs = ((clock.mSampleTime - base.mSampleTime) / clock.nominalRate - t) * 1000.0
            let sample = Sample(tSeconds: t, sampleTime: clock.mSampleTime, deviationMs: deviationMs)

            if let prev = previous {
                let step = sample.deviationMs - prev.deviationMs
                if abs(step) > jumpThresholdMs {
                    jumps.append(Jump(tSeconds: t, magnitudeMs: step, reason: "re-anchor suspected"))
                    print(String(format: "pacing-probe: JUMP at t=+%.0fs — step %+.2fms in one sample (re-anchor suspected)", t, step))
                    closeSegment(at: prev)
                    segmentStart = sample
                }
            } else {
                segmentStart = sample
            }

            print(String(format: "pacing: t=+%4.0fs sampleTime=%14.0f dev=%+9.3fms path=%@", t, clock.mSampleTime, deviationMs, "\(engine.lastClockPath)"))
            previous = sample
        }
        closeSegment(at: previous)
        engine.stop() // tears down the timing IOProc if the fallback engaged

        print("pacing-probe: ---- summary ----")
        print("pacing-probe: device \"\(device.name)\" nominalRate=\(nominalRate) clockPath(s)=\(pathsSeen.sorted().joined(separator: ","))")
        print("pacing-probe: ppm trend per steady segment:")
        if segments.isEmpty { print("  (no segment long enough — run longer or check the device was running IO)") }
        for line in segments { print(line) }
        print("pacing-probe: jumps: \(jumps.count)")
        for jump in jumps {
            if jump.magnitudeMs.isNaN {
                print(String(format: "  t=+%.0fs  %@", jump.tSeconds, jump.reason))
            } else {
                print(String(format: "  t=+%.0fs  %+.2fms  (%@)", jump.tSeconds, jump.magnitudeMs, jump.reason))
            }
        }
        return 0
    }
}
