import AVFoundation
import AudioToolbox
import Darwin
import Foundation

/// Measures the real clock-rate difference between two Bluetooth speakers
/// acoustically, with nobody listening, in about two minutes. It answers the one
/// question the host-side pacing clock (--pacing-probe) cannot on Bluetooth,
/// where AudioDeviceGetCurrentTime reads the HOST stack's clock, not the
/// speaker's converter: do two speakers DRIFT apart over time, or hold a fixed
/// offset — and when a speaker corrects, is it a smooth free-run (a LINE) or a
/// buffer resync (a STAIRCASE)?
///
/// Method (settled research — see the task brief, not to be redesigned here):
///   1. Play a DIFFERENT continuous pure sine to each speaker via that speaker's
///      own pinned BTOutputEngine (default 7919 Hz to A, 10007 Hz to B —
///      non-harmonic, both under 11 kHz). A slow ±3% ~0.5 Hz amplitude wobble
///      rides each tone so the Sonos Move's power-gated amp doesn't standby on a
///      dead-constant tone.
///   2. Record the BUILT-IN mic (bound by device, plain HAL input — never the
///      default input, never VoiceProcessingIO) for the run.
///   3. Complex-demodulate each tone to DC, low-pass by block-averaging (which
///      also nulls the other tone), unwrap the phase, and least-squares fit
///      phase-vs-time. Each slope is that speaker's sample-rate error vs the
///      MIC's clock; the DIFFERENCE of the two slopes is the inter-speaker
///      drift — the mic's own clock cancels because both tones share one
///      recording.
///   4. Report each device's ppm vs mic, the inter-speaker drift in ppm and
///      ms/min, and whether each phase track is a LINE or a STAIRCASE, printing
///      the per-window series so the shape is visible.
///
/// `--drift-meter-selftest` proves the maths on a synthesized two-tone buffer
/// with a KNOWN injected offset — no hardware, no quiet room.
enum DriftMeterProbe {

    private static let defaultSeconds = 120
    private static let defaultFreqA = 7919.0
    private static let defaultFreqB = 10007.0
    /// Block-average window for the demodulator low-pass. A boxcar of this length
    /// puts spectral nulls at multiples of fs/blockSeconds, deep enough to bury
    /// the OTHER tone (~2 kHz away) by ~40 dB, and decimates the phase track to
    /// 1/blockSeconds Hz — dense enough for a clean least-squares fit.
    private static let blockSeconds = 0.01
    /// Per-window span for the instantaneous-ppm trend and the staircase scan.
    private static let windowSeconds = 5.0
    /// Amplitude wobble that keeps a power-gated amp awake (fraction, and Hz).
    private static let wobbleFraction = 0.03
    private static let wobbleHz = 0.5
    private static let a2dpRate = 44_100.0
    private static let cleanReason = "tone present and coherent throughout"

    // MARK: - Hardware run

    static func run(_ rawArgs: [String]) -> Int32 {
        var positional: [String] = []
        var seconds = defaultSeconds
        var freqA = defaultFreqA
        var freqB = defaultFreqB
        var logPath: String?
        var i = 0
        while i < rawArgs.count {
            switch rawArgs[i] {
            case "--seconds":
                guard i + 1 < rawArgs.count, let n = Int(rawArgs[i + 1]), n > 0 else {
                    elog("drift-meter: --seconds needs a positive integer"); return 2
                }
                seconds = n; i += 2
            case "--freqA":
                guard i + 1 < rawArgs.count, let f = Double(rawArgs[i + 1]), f > 0, f < 11_000 else {
                    elog("drift-meter: --freqA needs a positive number under 11000"); return 2
                }
                freqA = f; i += 2
            case "--freqB":
                guard i + 1 < rawArgs.count, let f = Double(rawArgs[i + 1]), f > 0, f < 11_000 else {
                    elog("drift-meter: --freqB needs a positive number under 11000"); return 2
                }
                freqB = f; i += 2
            case "--log":
                guard i + 1 < rawArgs.count else { elog("drift-meter: --log needs a path"); return 2 }
                logPath = rawArgs[i + 1]; i += 2
            default:
                if rawArgs[i].hasPrefix("-") {
                    elog("drift-meter: unexpected argument '\(rawArgs[i])'"); return 2
                }
                positional.append(rawArgs[i]); i += 1
            }
        }
        guard positional.count == 2 else {
            elog("drift-meter: need exactly two device names; usage: --drift-meter <deviceA> <deviceB> [--seconds N] [--freqA hz] [--freqB hz] [--log path]")
            return 2
        }

        let candidates = BTDeviceEnumerator.listBluetoothOutputDevices().filter { !$0.isAggregate }
        func resolve(_ query: String) -> BTOutputDevice? {
            let lowered = query.lowercased()
            let matches = candidates.filter { $0.name.lowercased().contains(lowered) || $0.uid.lowercased().contains(lowered) }
            guard matches.count == 1 else {
                elog("drift-meter: '\(query)' matched \(matches.count) Bluetooth output device(s); available:")
                for c in candidates { elog("  name=\"\(c.name)\" uid=\(c.uid)") }
                return nil
            }
            return matches.first
        }
        guard let devA = resolve(positional[0]), let devB = resolve(positional[1]) else { return 1 }
        guard devA.id != devB.id else { elog("drift-meter: both names matched the same device"); return 1 }

        guard let mic = findBuiltInMic() else {
            elog("drift-meter: no BUILT-IN microphone found (transport type built-in with input streams). Refusing to fall back to the default input — it may be AirPods in 24 kHz voice mode, which would corrupt the measurement.")
            return 1
        }

        let log = DriftLog(path: logPath)
        log.write("drift-meter: A=\"\(devA.name)\" @ \(Int(freqA))Hz  B=\"\(devB.name)\" @ \(Int(freqB))Hz  mic=\"\(mic.name)\" @ \(Int(mic.rate))Hz  recording \(seconds)s")

        // Start each speaker on its own pinned engine, then replace the default
        // tone with this device's custom sine (playLoopingBuffer swaps the queued
        // buffer immediately — the config-change-safe path the lateralization
        // probe uses).
        let engineA = BTOutputEngine(deviceID: devA.id, deviceName: devA.name, mode: .tone)
        let engineB = BTOutputEngine(deviceID: devB.id, deviceName: devB.name, mode: .tone)
        // A power-gated speaker (the Sonos Move parks its amp when idle) can fail
        // the first start outright — the device isn't ready to accept audio while
        // the amp wakes. Retry before giving up; name the speaker that won't come up.
        for (engine, dev) in [(engineA, devA), (engineB, devB)] {
            guard startWithRetry(engine, log: log, name: dev.name) else {
                log.write("drift-meter: \"\(dev.name)\" would not start after retries — it may be asleep; play any audio to it for a few seconds to wake it, then rerun.")
                engineA.stop(); engineB.stop(); log.close()
                return 1
            }
        }
        engineA.playLoopingBuffer(makeToneBuffer(freq: freqA))
        engineB.playLoopingBuffer(makeToneBuffer(freq: freqB))

        // Warm-up before measuring: a parked amp swallows the first few seconds of
        // tone after silence, so let both speakers come fully up to level first.
        // Then confirm neither collapsed to a call-mode (HFP 16k/24k) rate, which
        // is silent-but-"healthy" and would poison the run.
        Thread.sleep(forTimeInterval: 3.0)
        for d in [devA, devB] {
            let rate = BTOutputEngine.readNominalSampleRate(d.id) ?? 0
            if rate <= 24_000 {
                log.write("drift-meter: ABORT — \"\(d.name)\" is at \(Int(rate))Hz, i.e. call mode (HFP), not A2DP \(Int(a2dpRate)). Nothing was measured.")
                engineA.stop(); engineB.stop(); log.close()
                return 1
            }
            if abs(rate - a2dpRate) > 1 {
                log.write("drift-meter: WARNING — \"\(d.name)\" nominal rate is \(Int(rate))Hz, not \(Int(a2dpRate)); continuing (not a call-mode collapse).")
            }
        }

        guard let capture = BuiltInMicCapture(deviceID: mic.id, sampleRate: mic.rate, maxSeconds: Double(seconds)) else {
            log.write("drift-meter: FAILED to open the built-in mic capture unit.")
            engineA.stop(); engineB.stop(); log.close()
            return 1
        }
        gDriftInterrupted = 0
        signal(SIGINT) { _ in gDriftInterrupted = 1 }
        signal(SIGTERM) { _ in gDriftInterrupted = 1 }

        guard capture.start() else {
            log.write("drift-meter: mic capture failed to start (grant Microphone access to this binary).")
            capture.stop(); engineA.stop(); engineB.stop(); log.close()
            return 1
        }
        log.write("drift-meter: recording... (Ctrl-C stops early and analyzes what was captured)")

        let deadline = Date().addingTimeInterval(Double(seconds))
        while Date() < deadline, gDriftInterrupted == 0 {
            Thread.sleep(forTimeInterval: min(1.0, max(0, deadline.timeIntervalSinceNow)))
        }

        // Re-read the speakers' rates BEFORE stopping the engines: the 1s check
        // at the top only proves they started on A2DP, not that they stayed. A
        // mid-run drop to call mode reads as silence in the analysis too, but
        // this names the cause instead of leaving it to the SNR gate to infer.
        for d in [devA, devB] {
            let rate = BTOutputEngine.readNominalSampleRate(d.id) ?? 0
            if rate <= 24_000 {
                log.write("drift-meter: NOTE — \"\(d.name)\" is now at \(Int(rate))Hz (call mode); it dropped off A2DP at some point during the run, so its track is not trustworthy.")
            }
        }

        capture.stop()
        engineA.stop()
        engineB.stop()
        let samples = capture.drain()
        let fs = capture.sampleRate
        log.write(String(format: "drift-meter: captured %d samples (%.1fs at %.0f Hz)", samples.count, Double(samples.count) / fs, fs))

        guard samples.count > Int(fs * 10) else {
            log.write("drift-meter: too little audio captured to fit phase (need >10s). Aborting analysis.")
            log.close()
            return 1
        }

        let a = analyze(samples: samples, fs: fs, f0: freqA)
        let b = analyze(samples: samples, fs: fs, f0: freqB)
        report(name: devA.name, freq: freqA, analysis: a, log: log)
        report(name: devB.name, freq: freqB, analysis: b, log: log)

        let inter = a.ppmVsMic - b.ppmVsMic
        log.write("drift-meter: ---- inter-speaker result ----")
        if !a.reliable || !b.reliable {
            log.write("drift-meter: *** RESULT UNRELIABLE — at least one tone was not cleanly present, so the drift figure below is meaningless. Fix the cause (speaker silent / dropped to call mode / too much room noise) and rerun. ***")
        }
        log.write(String(format: "drift-meter: \"%@\" vs \"%@\" inter-speaker drift = %+.2f ppm  (%+.3f ms/min)",
                         devA.name, devB.name, inter, inter * 0.06))
        if a.reliable && b.reliable {
            let shapeA = a.isStaircase ? "STAIRCASE (buffer resync)" : "LINE (free-running)"
            let shapeB = b.isStaircase ? "STAIRCASE (buffer resync)" : "LINE (free-running)"
            log.write("drift-meter: \"\(devA.name)\" phase shape: \(shapeA);  \"\(devB.name)\" phase shape: \(shapeB)")
            if a.isStaircase || b.isStaircase {
                log.write("drift-meter: at least one speaker is doing buffer-resync corrections — the fixed-offset question is 'no': it re-anchors rather than free-running.")
            } else {
                log.write("drift-meter: both tracks are straight lines — true free-running drift; the inter-speaker figure above is the fixed rate offset.")
            }
            log.write(String(format: "drift-meter: over a 30-minute session that %+.2f ppm accumulates to about %+.0f ms — cross-reference against ~10ms (audible colouration) and ~30ms (slap).", inter, inter * 0.06 * 30))
        }
        if let p = log.path { log.write("drift-meter: log written to \(p)") }
        log.close()
        return (a.reliable && b.reliable) ? 0 : 1
    }

    /// Start an engine, retrying a parked-amp start failure a few times. A Sonos
    /// Move that has been idle rejects the first start while its amp wakes; a
    /// short wait and another attempt succeeds.
    private static func startWithRetry(_ engine: BTOutputEngine, log: DriftLog, name: String) -> Bool {
        for attempt in 1...4 {
            do {
                try engine.start()
                return true
            } catch {
                log.write("drift-meter: \"\(name)\" start attempt \(attempt)/4 failed (\(error)) — waking and retrying")
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
        return false
    }

    private static func report(name: String, freq: Double, analysis: ToneAnalysis, log: DriftLog) {
        log.write("drift-meter: ---- \"\(name)\" @ \(Int(freq)) Hz ----")
        if !analysis.reliable {
            log.write("drift-meter: *** UNRELIABLE — \(analysis.reason). The ppm below is NOT trustworthy for this speaker. ***")
        } else if analysis.reason != cleanReason {
            log.write("drift-meter: note — \(analysis.reason).")
        }
        log.write(String(format: "drift-meter: %@ = %+.2f ppm vs mic  (%+.3f ms/min)", name, analysis.ppmVsMic, analysis.ppmVsMic * 0.06))
        log.write("drift-meter: per-\(Int(windowSeconds))s window (instantaneous ppm, phase at window end):")
        for w in analysis.windows {
            let flag = w.hasStep ? "  <-- STEP" : (w.lowSignal ? "  <-- LOW SIGNAL" : "")
            log.write(String(format: "  [t=+%5.0fs] inst=%+8.2f ppm   phase=%+10.2f rad%@", w.tStart, w.ppm, w.phaseAtEnd, flag))
        }
        if analysis.steps.isEmpty {
            log.write("drift-meter: no phase steps detected — track is a straight line.")
        } else {
            log.write("drift-meter: \(analysis.steps.count) phase step(s) detected (staircase):")
            for s in analysis.steps {
                log.write(String(format: "  t=+%.1fs  step %+.2f rad", s.t, s.deltaRad))
            }
        }
    }

    // MARK: - Self-test (no hardware)

    static func runSelfTest() -> Int32 {
        let fs = 48_000.0
        let secs = 60.0
        let fA = defaultFreqA
        let fB = defaultFreqB
        var failures = 0

        func check(_ label: String, _ pass: Bool, _ detail: String) {
            elog("  \(pass ? "PASS" : "FAIL")  \(label): \(detail)")
            if !pass { failures += 1 }
        }

        // Case 1: inject a KNOWN +12 ppm on tone B; A stays nominal.
        elog("drift-meter-selftest: case 1 — inject +12 ppm on B (A nominal), expect inter ~ -12 ppm")
        let inject = 12.0
        let buf1 = synthesize(fs: fs, seconds: secs, fA: fA, fB: fB, ppmB: inject, stepOnB: nil)
        let a1 = analyze(samples: buf1, fs: fs, f0: fA)
        let b1 = analyze(samples: buf1, fs: fs, f0: fB)
        let inter1 = a1.ppmVsMic - b1.ppmVsMic
        elog(String(format: "         recovered ppmA=%+.3f ppmB=%+.3f inter=%+.3f (want ppmB~%+.1f, inter~%.1f)", a1.ppmVsMic, b1.ppmVsMic, inter1, inject, -inject))
        check("ppmA ~ 0", abs(a1.ppmVsMic) < 0.5, String(format: "%+.3f ppm", a1.ppmVsMic))
        check("ppmB ~ +12", abs(b1.ppmVsMic - inject) < 0.5, String(format: "%+.3f ppm", b1.ppmVsMic))
        check("inter ~ -12", abs(inter1 + inject) < 0.5, String(format: "%+.3f ppm", inter1))
        check("both tracks read as LINE", !a1.isStaircase && !b1.isStaircase, "A staircase=\(a1.isStaircase) B staircase=\(b1.isStaircase)")
        check("clean tones read as RELIABLE", a1.reliable && b1.reliable, "A=\(a1.reliable) B=\(b1.reliable)")

        // Case 2: zero drift — both nominal, expect inter ~ 0.
        elog("drift-meter-selftest: case 2 — zero drift, expect inter ~ 0 ppm")
        let buf2 = synthesize(fs: fs, seconds: secs, fA: fA, fB: fB, ppmB: 0, stepOnB: nil)
        let a2 = analyze(samples: buf2, fs: fs, f0: fA)
        let b2 = analyze(samples: buf2, fs: fs, f0: fB)
        let inter2 = a2.ppmVsMic - b2.ppmVsMic
        elog(String(format: "         recovered inter=%+.3f ppm", inter2))
        check("inter ~ 0", abs(inter2) < 0.5, String(format: "%+.3f ppm", inter2))

        // Case 3: staircase — a mid-record phase step on B; A must stay a line.
        elog("drift-meter-selftest: case 3 — +2.0 rad phase step on B mid-record, expect B=STAIRCASE, A=LINE")
        let buf3 = synthesize(fs: fs, seconds: secs, fA: fA, fB: fB, ppmB: 0, stepOnB: 2.0)
        let a3 = analyze(samples: buf3, fs: fs, f0: fA)
        let b3 = analyze(samples: buf3, fs: fs, f0: fB)
        elog("         A staircase=\(a3.isStaircase) (want false); B staircase=\(b3.isStaircase) (want true), B steps=\(b3.steps.count)")
        check("B flagged STAIRCASE", b3.isStaircase, "steps=\(b3.steps.count)")
        check("A stays a LINE", !a3.isStaircase, "steps=\(a3.steps.count)")

        // Case 4: tone B goes silent halfway (only noise after) — the exact
        // "confident wrong number" failure. B must be flagged UNRELIABLE; A,
        // present throughout, must stay reliable.
        elog("drift-meter-selftest: case 4 — B drops to silence at 30s, expect B=UNRELIABLE, A=reliable")
        let buf4 = synthesize(fs: fs, seconds: secs, fA: fA, fB: fB, ppmB: 0, stepOnB: nil, silenceBAfter: secs / 2)
        let a4 = analyze(samples: buf4, fs: fs, f0: fA)
        let b4 = analyze(samples: buf4, fs: fs, f0: fB)
        elog("         A reliable=\(a4.reliable); B reliable=\(b4.reliable) reason=\"\(b4.reason)\"")
        check("B flagged UNRELIABLE", !b4.reliable, b4.reason)
        check("A stays reliable", a4.reliable, a4.reason)

        // Case 5: B silent for only the last ~2% (a stop tail / transient) —
        // must NOT flag the whole run; the ppm is still good.
        elog("drift-meter-selftest: case 5 — B silent for last ~2% (stop tail), expect B still reliable")
        let buf5 = synthesize(fs: fs, seconds: secs, fA: fA, fB: fB, ppmB: 0, stepOnB: nil, silenceBAfter: secs * 0.98)
        let b5 = analyze(samples: buf5, fs: fs, f0: fB)
        elog("         B reliable=\(b5.reliable) reason=\"\(b5.reason)\"")
        check("brief tail stays reliable", b5.reliable, b5.reason)

        if failures == 0 {
            elog("DRIFT-METER-SELFTEST: PASS")
            return 0
        } else {
            elog("DRIFT-METER-SELFTEST: FAIL (\(failures) check(s) failed)")
            return 1
        }
    }

    /// A synthetic mic recording: tones A and B summed at the mic rate, with an
    /// optional per-mille rate offset on B (its effective sample clock running
    /// `ppmB` faster) and an optional one-off phase step on B at the midpoint.
    /// The same ±3% 0.5 Hz amplitude wobble the live path uses rides both tones,
    /// so the self-test also proves the analysis is blind to amplitude.
    private static func synthesize(fs: Double, seconds: Double, fA: Double, fB: Double,
                                   ppmB: Double, stepOnB: Double?, silenceBAfter: Double? = nil) -> [Float] {
        let n = Int(fs * seconds)
        var out = [Float](repeating: 0, count: n)
        let midpoint = n / 2
        let bScale = 1.0 + ppmB * 1e-6
        // Deterministic low-level noise floor (fixed-seed LCG) so a "silent"
        // tone reads as a real mic would — noise, never numerical zero, which is
        // what makes the coherence gate meaningful.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 40) / Double(1 << 24) - 0.5) * 0.02
        }
        let silenceBFrom = silenceBAfter.map { Int(fs * $0) } ?? Int.max
        for i in 0..<n {
            let t = Double(i) / fs
            let wobble = 1.0 + wobbleFraction * sin(2 * .pi * wobbleHz * t)
            let a = sin(2 * .pi * fA * Double(i) / fs)
            var bPhase = 2 * .pi * fB * bScale * Double(i) / fs
            if let step = stepOnB, i >= midpoint { bPhase += step }
            let b = i >= silenceBFrom ? 0.0 : sin(bPhase)
            out[i] = Float(0.4 * wobble * (a + b) + noise())
        }
        return out
    }

    // MARK: - Analysis

    private struct WindowStat {
        let tStart: Double
        let ppm: Double
        let phaseAtEnd: Double
        let hasStep: Bool
        let lowSignal: Bool // this window's tone level fell far below the record's own median
    }
    private struct PhaseStep {
        let t: Double
        let deltaRad: Double
    }
    private struct ToneAnalysis {
        let ppmVsMic: Double
        let isStaircase: Bool
        let windows: [WindowStat]
        let steps: [PhaseStep]
        /// False when the tone was too weak or too incoherent for the ppm/shape
        /// to be believed — a silent speaker still produces a slope, so without
        /// this the tool would report a confident wrong number. `reason` says why.
        let reliable: Bool
        let reason: String
    }

    /// Complex-demodulate `samples` at `f0`, block-average (low-pass + decimate)
    /// to isolate that tone, unwrap the phase, and least-squares fit it to time.
    /// Returns the ppm vs the mic clock plus the per-window trend and any phase
    /// steps (a staircase from buffer resync, distinct from a smooth line).
    private static func analyze(samples: [Float], fs: Double, f0: Double) -> ToneAnalysis {
        let blockLen = max(1, Int((fs * blockSeconds).rounded()))
        let blockRate = fs / Double(blockLen)
        let blockCount = samples.count / blockLen
        guard blockCount >= 2 else {
            return ToneAnalysis(ppmVsMic: 0, isStaircase: false, windows: [], steps: [],
                                reliable: false, reason: "recording too short to analyze")
        }

        // Block-average the complex-demodulated signal. The demod phase is
        // reduced modulo fs BEFORE scaling to radians: for integer f0/fs the
        // product f0*n is an exact integer, so the reduction is loss-free even at
        // n in the millions, where a raw 2*pi*f0*n/fs would shed precision.
        // `mag` is the demodulated tone level per block: a present tone gives a
        // strong steady magnitude; a silent/absent one gives near-zero noise.
        var phase = [Double](repeating: 0, count: blockCount)
        var times = [Double](repeating: 0, count: blockCount)
        var mag = [Double](repeating: 0, count: blockCount)
        for k in 0..<blockCount {
            var re = 0.0, im = 0.0
            for j in 0..<blockLen {
                let idx = k * blockLen + j
                let x = Double(samples[idx])
                let reduced = (f0 * Double(idx)).truncatingRemainder(dividingBy: fs)
                let angle = -2 * .pi * reduced / fs
                re += x * cos(angle)
                im += x * sin(angle)
            }
            phase[k] = atan2(im, re)
            mag[k] = (re * re + im * im).squareRoot() / Double(blockLen)
            times[k] = (Double(k) * Double(blockLen) + Double(blockLen) / 2) / fs
        }
        let medMag = median(mag)
        // A block whose tone level is a quarter of the record's own median is a
        // dropout (HFP collapse, amp standby, or the speaker simply gone) — its
        // phase is meaningless and must not feed the slope or the step scan.
        let dropoutFloor = 0.25 * medMag
        let lowSignalBlocks = mag.reduce(0) { $0 + ($1 < dropoutFloor ? 1 : 0) }

        // Unwrap.
        var unwrapped = [Double](repeating: 0, count: blockCount)
        unwrapped[0] = phase[0]
        for k in 1..<blockCount {
            let raw = phase[k] - phase[k - 1]
            let wrapped = atan2(sin(raw), cos(raw))
            unwrapped[k] = unwrapped[k - 1] + wrapped
        }

        let slope = leastSquaresSlope(x: times, y: unwrapped)
        let ppm = slope / (2 * .pi * f0) * 1e6

        // Staircase scan: block-to-block increments cluster tightly around the
        // steady drift rate; a resync injects one large outlier. Flag on
        // deviation from the median beyond a fixed floor (a real buffer
        // correction is many samples of phase) or many times the spread.
        // `mad` is measured over increments between HEALTHY blocks only, so a
        // dropout can't inflate the spread and mask a real step — and steps are
        // only trusted where both endpoint blocks carried the tone, which kills
        // the false step a reflection null or transient (both level dips) would
        // otherwise produce. LIMIT: a resync larger than ~half a cycle at f0
        // (~63 us at 7919 Hz) is folded by the unwrap and under-measured; the
        // magnitude dip that accompanies it is the more reliable tell.
        var increments = [Double](repeating: 0, count: blockCount - 1)
        for k in 1..<blockCount { increments[k - 1] = unwrapped[k] - unwrapped[k - 1] }
        let healthyIncrements = (1..<blockCount)
            .filter { mag[$0] >= dropoutFloor && mag[$0 - 1] >= dropoutFloor }
            .map { increments[$0 - 1] }
        let med = median(healthyIncrements.isEmpty ? increments : healthyIncrements)
        let mad = median((healthyIncrements.isEmpty ? increments : healthyIncrements).map { abs($0 - med) })
        let stepThreshold = max(0.5, 8 * mad)
        var steps: [PhaseStep] = []
        for k in 1..<blockCount {
            guard mag[k] >= dropoutFloor, mag[k - 1] >= dropoutFloor else { continue }
            let dev = increments[k - 1] - med
            if abs(dev) > stepThreshold {
                steps.append(PhaseStep(t: times[k], deltaRad: dev))
            }
        }

        // Reliability. Two independent ways the number can be a lie: the tone was
        // never coherently present (phase random-walks -> large increment spread,
        // absolute test, needs no healthy baseline), or it dropped out for part of
        // the run (relative level test above). Either makes ppm/shape untrustworthy.
        var reliable = true
        var reason = cleanReason
        let lowPct = lowSignalBlocks * 100 / blockCount
        if mad > 0.3 {
            reliable = false
            reason = String(format: "tone incoherent (phase-noise %.2f rad/block) — likely not present; check the speaker is actually playing", mad)
        } else if lowSignalBlocks * 20 > blockCount {
            // >5% of the run silent is a real collapse (HFP flip, amp standby, or
            // the speaker gone), not a transient — the number can't be trusted.
            reliable = false
            reason = "tone dropped out for \(lowPct)% of the run — a mid-run HFP collapse or amp standby"
        } else if lowSignalBlocks > 0 {
            // A handful of brief dips — a cough, a chair, one BT hiccup, or the
            // moment the run was stopped — don't invalidate an otherwise coherent
            // record. Surface them, keep the result.
            reason = "\(lowSignalBlocks) brief low-signal block(s) (\(lowPct)%) — within tolerance, result kept"
        }

        // Per-window instantaneous ppm + phase, marking windows that contain a step.
        var windows: [WindowStat] = []
        let windowBlocks = max(2, Int((windowSeconds * blockRate).rounded()))
        var start = 0
        while start < blockCount {
            let end = min(start + windowBlocks, blockCount)
            if end - start >= 2 {
                let xs = Array(times[start..<end])
                let ys = Array(unwrapped[start..<end])
                let wSlope = leastSquaresSlope(x: xs, y: ys)
                let wPpm = wSlope / (2 * .pi * f0) * 1e6
                let tStart = times[start]
                let tEnd = times[end - 1]
                let hasStep = steps.contains { $0.t > tStart && $0.t <= tEnd + 1e-9 }
                let winLow = median(Array(mag[start..<end])) < dropoutFloor
                windows.append(WindowStat(tStart: tStart, ppm: wPpm, phaseAtEnd: ys.last ?? 0,
                                          hasStep: hasStep, lowSignal: winLow))
            }
            start = end
        }

        return ToneAnalysis(ppmVsMic: ppm, isStaircase: !steps.isEmpty, windows: windows, steps: steps,
                            reliable: reliable, reason: reason)
    }

    private static func leastSquaresSlope(x: [Double], y: [Double]) -> Double {
        let n = Double(x.count)
        guard n >= 2 else { return 0 }
        let sx = x.reduce(0, +)
        let sy = y.reduce(0, +)
        let meanX = sx / n
        let meanY = sy / n
        var num = 0.0, den = 0.0
        for i in 0..<x.count {
            let dx = x[i] - meanX
            num += dx * (y[i] - meanY)
            den += dx * dx
        }
        return den == 0 ? 0 : num / den
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - Custom tone buffer (seamless loop + amplitude wobble)

    /// A stereo ToneSource-format buffer of a single sine at `freq` with the
    /// standby-defeating amplitude wobble. The buffer length is chosen so it
    /// holds a WHOLE number of tone cycles AND exactly one wobble cycle, so the
    /// loop seam lands on a continuous phase for any `freq` — a seam
    /// discontinuity would read downstream as a periodic staircase.
    private static func makeToneBuffer(freq: Double) -> AVAudioPCMBuffer {
        let fs = ToneSource.sampleRate
        let targetSeconds = 1.0 / wobbleHz // one full wobble period (~2s)
        let wholeCycles = max(1.0, (freq * targetSeconds).rounded())
        let bufferSeconds = wholeCycles / freq
        let frameCount = AVAudioFrameCount((bufferSeconds * fs).rounded())
        let wobblePeriod = bufferSeconds // exactly one wobble cycle over the buffer

        guard let buffer = AVAudioPCMBuffer(pcmFormat: ToneSource.format, frameCapacity: frameCount) else {
            fatalError("DriftMeterProbe: failed to allocate tone buffer")
        }
        buffer.frameLength = frameCount
        guard let channels = buffer.floatChannelData else {
            fatalError("DriftMeterProbe: tone buffer has no float channel data")
        }
        let channelCount = Int(ToneSource.format.channelCount)
        let base = 0.5
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / fs
            let wobble = 1.0 + wobbleFraction * sin(2 * .pi * t / wobblePeriod)
            let sample = Float(base * wobble * sin(2 * .pi * freq * t))
            for ch in 0..<channelCount { channels[ch][frame] = sample }
        }
        return buffer
    }

    // MARK: - Built-in mic lookup

    private struct MicDevice {
        let id: AudioObjectID
        let name: String
        let rate: Double
    }

    /// The built-in microphone, matched by transport type (built-in) AND the
    /// presence of input streams — never the current default input, which on
    /// this Mac can already be AirPods in 24 kHz voice mode. Returns nil (caller
    /// aborts) rather than falling back.
    private static func findBuiltInMic() -> MicDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices) == noErr else { return nil }

        for device in devices {
            guard hasInputStreams(device), transportType(device) == kAudioDeviceTransportTypeBuiltIn else { continue }
            let name = deviceName(device) ?? "<built-in mic>"
            let rate = BTOutputEngine.readNominalSampleRate(device) ?? 48_000
            return MicDevice(id: device, name: name, rate: rate)
        }
        return nil
    }

    private static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
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
        guard err == noErr, let name else { return nil }
        return name as String
    }
}

/// Interrupt flag for the drift-meter record loop, written from a signal handler
/// and polled by `run`. Same discipline SoakProbe documents: single-word type
/// (can't tear), and `run` zeroes it on the main thread before installing any
/// handler, so the lazy-init accessor can never fire inside one.
private nonisolated(unsafe) var gDriftInterrupted: sig_atomic_t = 0

/// Plain HAL input capture (kAudioUnitSubType_HALOutput with input enabled) bound
/// to ONE device by id. Deliberately NOT VoiceProcessingIO: that couples input to
/// output and applies echo cancellation, which would destroy an acoustic drift
/// measurement. Records mono Float32 at the device's own rate into one
/// preallocated buffer; the real-time callback only memcpys under a lock, matching
/// the RT discipline BTOutputEngine's timing IOProc already uses here.
private final class BuiltInMicCapture {
    let sampleRate: Double
    private var unit: AudioUnit?
    private let bufLock = NSLock()
    private let storage: UnsafeMutableBufferPointer<Float>
    private let scratch: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private var writeIndex = 0
    private var started = false

    init?(deviceID: AudioObjectID, sampleRate: Double, maxSeconds: Double) {
        self.sampleRate = sampleRate
        self.capacity = Int(sampleRate * maxSeconds) + Int(sampleRate)
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        self.scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 16_384)

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { cleanup(); return nil }
        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let au else { cleanup(); return nil }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4) == noErr,
              AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, 4) == noErr else {
            AudioComponentInstanceDispose(au); cleanup(); return nil
        }
        var dev = deviceID
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4) == noErr else {
            AudioComponentInstanceDispose(au); cleanup(); return nil
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        guard AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            AudioComponentInstanceDispose(au); cleanup(); return nil
        }
        let callback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
            let capture = Unmanaged<BuiltInMicCapture>.fromOpaque(refCon).takeUnretainedValue()
            return capture.render(flags, timeStamp, bus, frames)
        }
        var cbStruct = AURenderCallbackStruct(inputProc: callback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(au) == noErr else {
            AudioComponentInstanceDispose(au); cleanup(); return nil
        }
        self.unit = au
    }

    private func cleanup() {
        storage.deallocate()
        scratch.deallocate()
    }

    deinit {
        stop()
        storage.deallocate()
        scratch.deallocate()
    }

    func start() -> Bool {
        guard let unit, !started else { return started }
        guard AudioOutputUnitStart(unit) == noErr else { return false }
        started = true
        return true
    }

    func stop() {
        guard let unit else { return }
        if started { AudioOutputUnitStop(unit); started = false }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        _ timeStamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        let renderFrames = min(Int(frames), scratch.count)
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers.mNumberChannels = 1
        abl.mBuffers.mDataByteSize = UInt32(renderFrames * 4)
        abl.mBuffers.mData = UnsafeMutableRawPointer(scratch.baseAddress)
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, &abl)
        guard status == noErr else { return status }
        bufLock.lock()
        let n = min(renderFrames, capacity - writeIndex)
        if n > 0 {
            memcpy(storage.baseAddress!.advanced(by: writeIndex), scratch.baseAddress!, n * 4)
            writeIndex += n
        }
        bufLock.unlock()
        return noErr
    }

    func drain() -> [Float] {
        bufLock.lock()
        defer { bufLock.unlock() }
        return Array(UnsafeBufferPointer(start: storage.baseAddress, count: writeIndex))
    }
}

/// Tees every line to stdout and, when a path is given, to a file — so a run left
/// unattended still leaves its measurement behind.
private final class DriftLog {
    let path: String?
    private var handle: FileHandle?

    init(path: String?) {
        self.path = path
        guard let path else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func write(_ line: String) {
        print(line)
        fflush(stdout)
        handle?.write(Data((line + "\n").utf8))
    }

    func close() {
        try? handle?.close()
    }
}
