import AudioToolbox
import Foundation

// ============================================================================
// FlowCheck — T5: self-test + rough drift readout.
//
// (a) --selftest: pins ONE BTOutputEngine (T3) to the BUILT-IN output device
//     (no BT hardware required in a build/CI environment) and asserts the
//     render tap actually pulls non-zero-RMS frames over ~2 seconds. This is
//     deliberately a STRONGER check than "engine.isRunning" or "setDeviceID
//     returned noErr" — both can report success while a device stays silent
//     (e.g. wrong device ID accepted but never actually opened, or a route
//     that silently drops to nowhere). The make-or-break signal is the render
//     tap's callback firing with real (non-zero) samples in it.
//
// (b) DriftMonitor: rough relative clock-drift estimate between two-plus
//     running BTOutputEngines, from periodic BTRenderStats snapshots. BT
//     speakers don't share a clock the way AirPlay 2's PTP does, so each
//     device's DAC free-runs at its own (slightly off-nominal) rate; this
//     estimates that offset from actually-rendered-frames vs wall-clock,
//     "rough" is the point — a ballpark Alec reads while listening, not a
//     calibrated measurement.
// ============================================================================

func elog(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

// MARK: - (a) --selftest

enum FlowCheck {

    /// Runs the built-in-output flow-proof described above. Returns a process
    /// exit code (0 = PASS, non-zero = FAIL), mirroring dev/audiocap's
    /// SelfTest.swift PASS/FAIL + exit-code shape.
    static func runSelfTest() -> Int32 {
        elog("selftest: locating built-in output device...")
        guard let builtIn = findBuiltInOutputDevice() else {
            elog("FAIL  no built-in output device found (no audio device in this environment?)")
            elog("SELFTEST: FAIL")
            return 1
        }
        elog("selftest: built-in output device id=\(builtIn.id) name=\"\(builtIn.name)\"")

        let engine = BTOutputEngine(deviceID: builtIn.id, deviceName: builtIn.name, mode: .tone)
        do {
            try engine.start()
        } catch {
            elog("FAIL  engine.start() on built-in output threw: \(error)")
            elog("SELFTEST: FAIL")
            return 1
        }

        // Let it render for ~2s, sampling RMS + frame count a few times so a
        // single lucky/unlucky buffer can't decide the result.
        let sampleWindows = 4
        var sawNonZeroRMS = false
        var sawRenderedFrames = false
        for i in 0..<sampleWindows {
            Thread.sleep(forTimeInterval: 0.5)
            let rms = engine.drainRMS()
            let stats = engine.currentRenderStats()
            elog("selftest: window \(i + 1)/\(sampleWindows) rms=\(rms) renderedFrames=\(stats.frames)")
            if rms > 0.001 { sawNonZeroRMS = true }
            if stats.frames > 0 { sawRenderedFrames = true }
        }

        engine.stop()

        if sawNonZeroRMS && sawRenderedFrames {
            elog("PASS  built-in output: render tap fired with non-zero RMS — audio genuinely flowed")
            elog("SELFTEST: PASS")
            return 0
        } else {
            elog("FAIL  built-in output: render tap \(sawRenderedFrames ? "fired but stayed silent (RMS≈0)" : "never fired") — setDeviceID/isRunning would have lied about this")
            elog("SELFTEST: FAIL")
            return 1
        }
    }

    // MARK: - Built-in device lookup (local, dependency-free copy of the
    // BTDeviceEnumerator plumbing, filtered to kAudioDeviceTransportTypeBuiltIn
    // instead of Bluetooth — kept separate so BTDeviceEnumerator stays
    // BT-only and doesn't grow an unrelated "and also built-in" branch).

    private struct BuiltInDevice {
        let id: AudioObjectID
        let name: String
    }

    private static func findBuiltInOutputDevice() -> BuiltInDevice? {
        guard let devices = allDeviceIDs() else { return nil }
        for device in devices {
            guard hasOutputStreams(device) else { continue }
            guard transportType(device) == kAudioDeviceTransportTypeBuiltIn else { continue }
            let name = deviceName(device) ?? "<unknown built-in>"
            return BuiltInDevice(id: device, name: name)
        }
        return nil
    }

    private static func allDeviceIDs() -> [AudioObjectID]? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var devices = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices) == noErr else { return nil }
        return devices
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let err = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let name = name else { return nil }
        return name as String
    }
}

// MARK: - (b) Real-DAC-clock drift readout

/// One snapshot of a running engine's DEFINITIVE hardware DAC clock (T1's
/// `BTDeviceClock`), tagged with the name used for log lines. The interactive
/// loop (T6) takes one of these per engine on a periodic cadence and hands
/// consecutive pairs to `DriftMonitor.relativeDrift`.
struct DriftSample {
    let deviceName: String
    let clock: BTDeviceClock
}

enum DriftMonitor {

    /// Minimum wall-clock window, in seconds, a baseline/current pair must
    /// span before a drift estimate is trusted. Below this, DAC-clock
    /// quantization and (on the IOProc-fallback path) callback jitter
    /// dominate the reading rather than real drift — short windows produced
    /// the original ±40,000 ppm, sign-flipping-every-2s garbage this readout
    /// replaces. ONE easy-to-retune constant, per the locked design.
    static let minWindowSeconds: Double = 30

    /// Estimates each device's effective DAC sample rate from
    /// (ΔmSampleTime / Δseconds), where Δseconds comes from THAT SAME
    /// device's own hostTimeNanos delta (never a separate wall-clock read —
    /// that reintroduces the dispatch-jitter bug this replaces), then
    /// normalizes by THAT device's own nominal rate — never a shared/global
    /// rate, which would fabricate drift for devices with genuinely
    /// different nominal rates. Every non-reference device is then reported
    /// RELATIVE to the first device (index 0) as reference: since both
    /// figures are already normalized to their own nominal, the difference
    /// between them is a dimensionally-consistent ppm figure for how much
    /// faster/slower one DAC runs than the other's, which is what actually
    /// produces an audible beat between two speakers. Returns human-readable
    /// lines ready to print; empty if there isn't enough data yet (e.g.
    /// startup, before two windowed reads exist).
    /// Result of a drift computation: the human-readable lines, plus whether the
    /// caller should DROP its fixed baseline because a device's clock jumped
    /// (its audio IO was restarted mid-window -- e.g. a source toggle or a
    /// config-change recovery resets the device's DAC sampleTime, poisoning a
    /// baseline captured against the old clock).
    struct DriftReadout {
        let lines: [String]
        let baselinePoisoned: Bool
        /// True only when `lines` carries an actual ppm comparison. Every other
        /// return here also produces lines -- warm-up notices, "not enough data
        /// yet", restart notices -- so a caller counting non-empty `lines` as a
        /// successful reading would over-report. Callers that summarise whether
        /// drift was ever measured must read THIS, not `lines`.
        let measured: Bool
    }

    /// How far off its OWN nominal a device's measured rate must be before we
    /// treat the reading as a clock DISCONTINUITY rather than drift. Real BT DAC
    /// drift is at most a few hundred ppm; anything past this is a stale baseline
    /// (a restart happened after the baseline was captured).
    static let discontinuityPpm: Double = 2500

    static func relativeDrift(
        baseline: [DriftSample],
        current: [DriftSample]
    ) -> DriftReadout {
        guard baseline.count == current.count, current.count >= 2 else {
            return DriftReadout(lines: [], baselinePoisoned: false, measured: false)
        }

        struct DeviceOffset {
            let name: String
            let ppmVsOwnNominal: Double
        }
        var offsets: [DeviceOffset] = []
        for i in 0..<current.count {
            let b = baseline[i].clock
            let c = current[i].clock
            guard b.valid, c.valid, c.nominalRate > 0 else { continue }
            // DAC sampleTime running BACKWARDS means this device's IO restarted
            // and reset its clock origin -- the fixed baseline is stale.
            if c.mSampleTime < b.mSampleTime {
                return DriftReadout(
                    lines: ["drift: \(current[i].deviceName)'s clock restarted (IO reset) -- starting a fresh \(Int(minWindowSeconds))s window"],
                    baselinePoisoned: true, measured: false)
            }
            guard c.hostTimeNanos > b.hostTimeNanos else { continue } // stale/degenerate read
            let dtNanos = c.hostTimeNanos - b.hostTimeNanos
            let seconds = Double(dtNanos) / 1_000_000_000.0
            guard seconds >= minWindowSeconds else { continue } // reject short windows
            let dSampleTime = c.mSampleTime - b.mSampleTime
            let effectiveRate = dSampleTime / seconds
            let ppm = (effectiveRate - c.nominalRate) / c.nominalRate * 1_000_000
            // A rate this far off the device's OWN nominal isn't drift -- it's a
            // discontinuity from an IO restart AFTER the baseline (source toggle
            // or config-change recovery). Drop the poisoned baseline and re-measure.
            if abs(ppm) > discontinuityPpm {
                return DriftReadout(
                    lines: [String(format: "drift: %@ read %.0f ppm off its own clock -- a device restarted mid-window; restarting the %.0fs window", current[i].deviceName, ppm, minWindowSeconds)],
                    baselinePoisoned: true, measured: false)
            }
            offsets.append(DeviceOffset(name: current[i].deviceName, ppmVsOwnNominal: ppm))
        }

        guard offsets.count >= 2 else {
            return DriftReadout(
                lines: ["drift: not enough data yet (need >=2 devices with a >= \(Int(minWindowSeconds))s window of valid DAC-clock reads)"],
                baselinePoisoned: false, measured: false)
        }

        let reference = offsets[0]
        var lines: [String] = []
        for o in offsets.dropFirst() {
            let ppm = o.ppmVsOwnNominal - reference.ppmVsOwnNominal
            // Over T seconds of wall time, accumulated offset = T * ppm * 1e-6
            // seconds. Per minute of wall time (T=60s), that's ppm * 0.06 ms.
            let msPerMinute = ppm * 0.06
            // Two sine tones at f and f*(1+ppm/1e6) beat at their frequency
            // difference: beatHz = 440 * ppm / 1e6, i.e. how far apart two
            // 440Hz tones actually land once each DAC's real rate is applied.
            let beatHz = 440.0 * ppm / 1_000_000.0
            let swellDescription: String
            if abs(beatHz) > 0.0001 {
                let swellSeconds = 1.0 / abs(beatHz)
                swellDescription = String(format: "swell every ~%.1fs", swellSeconds)
            } else {
                swellDescription = "no audible beat (clocks effectively matched)"
            }
            lines.append(String(
                format: "drift: %@ vs %@ (ref): %.1f ppm  (~%.2f ms/min, beat=%.4f Hz@440, %@)",
                o.name, reference.name, ppm, msPerMinute, beatHz, swellDescription
            ))
        }
        return DriftReadout(lines: lines, baselinePoisoned: false, measured: true)
    }
}

// MARK: - (c) --drift-selftest

extension FlowCheck {

    /// Validates the DEFINITIVE hardware-clock READING mechanism itself
    /// (T1's `currentDeviceClock()`) on the built-in output device: asserts
    /// `mSampleTime` and `hostTimeNanos` both advance monotonically across
    /// repeated reads, and the measured effective rate lands within a sane
    /// band of the device's own nominal rate. This is independent of
    /// `DriftMonitor`'s 30s live-readout window — it only needs ~10s because
    /// it is checking that the clock reads are sane, not measuring real
    /// cross-device drift (which needs two actual speakers). Returns a
    /// process exit code (0 = PASS, non-zero = FAIL), mirroring
    /// `runSelfTest`'s PASS/FAIL + exit-code shape.
    static func runDriftSelfTest() -> Int32 {
        elog("drift-selftest: locating built-in output device...")
        guard let builtIn = findBuiltInOutputDevice() else {
            elog("FAIL  no built-in output device found (no audio device in this environment?)")
            elog("DRIFT-SELFTEST: FAIL")
            return 1
        }
        elog("drift-selftest: built-in output device id=\(builtIn.id) name=\"\(builtIn.name)\"")

        let engine = BTOutputEngine(deviceID: builtIn.id, deviceName: builtIn.name, mode: .tone)
        do {
            try engine.start()
        } catch {
            elog("FAIL  engine.start() on built-in output threw: \(error)")
            elog("DRIFT-SELFTEST: FAIL")
            return 1
        }

        // Let the DAC clock settle (and, if the query path errors on this
        // Mac, give the IOProc fallback time to fire at least once) before
        // the first read.
        Thread.sleep(forTimeInterval: 0.5)

        let windowSeconds = 10.0 // independent of DriftMonitor.minWindowSeconds (30s) by design
        let sampleInterval = 1.0
        var samples: [BTDeviceClock] = [engine.currentDeviceClock()]
        var elapsed = 0.0
        while elapsed < windowSeconds {
            Thread.sleep(forTimeInterval: sampleInterval)
            elapsed += sampleInterval
            samples.append(engine.currentDeviceClock())
        }

        let path = engine.lastClockPath
        engine.stop()

        elog("drift-selftest: clock path used = \(path)")

        guard samples.allSatisfy({ $0.valid }) else {
            elog("FAIL  one or more clock reads were invalid (query errored and the IOProc fallback never produced a timestamp)")
            elog("DRIFT-SELFTEST: FAIL")
            return 1
        }

        var monotonicOK = true
        for i in 1..<samples.count {
            if samples[i].hostTimeNanos <= samples[i - 1].hostTimeNanos { monotonicOK = false }
            if samples[i].mSampleTime <= samples[i - 1].mSampleTime { monotonicOK = false }
        }
        guard monotonicOK else {
            elog("FAIL  mSampleTime/hostTimeNanos did not advance monotonically across repeated reads")
            elog("DRIFT-SELFTEST: FAIL")
            return 1
        }

        let first = samples[0]
        let last = samples[samples.count - 1]
        let seconds = Double(last.hostTimeNanos - first.hostTimeNanos) / 1_000_000_000.0
        guard seconds > 0 else {
            elog("FAIL  zero/negative elapsed window between first and last read")
            elog("DRIFT-SELFTEST: FAIL")
            return 1
        }
        let effectiveRate = (last.mSampleTime - first.mSampleTime) / seconds
        let ppm = (effectiveRate - last.nominalRate) / last.nominalRate * 1_000_000
        let beatHz = 440.0 * ppm / 1_000_000.0
        elog(String(
            format: "drift-selftest: measured %.1f ppm vs own nominal (%.0f Hz) over %.1fs, beat=%.4f Hz@440",
            ppm, last.nominalRate, seconds, beatHz))

        let saneBandPPM = 2000.0
        guard abs(ppm) <= saneBandPPM else {
            elog("FAIL  measured \(ppm) ppm is outside the sane band (±\(saneBandPPM) ppm) — clock read looks bogus, not just a fast/slow DAC")
            elog("DRIFT-SELFTEST: FAIL")
            return 1
        }

        elog("PASS  hardware DAC clock (\(path)) reads monotonic and within a sane band of nominal")
        elog("DRIFT-SELFTEST: PASS")
        return 0
    }
}
