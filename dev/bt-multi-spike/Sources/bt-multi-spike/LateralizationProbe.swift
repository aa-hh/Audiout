import AVFoundation
import AudioToolbox
import Darwin
import Foundation

// ============================================================================
// LateralizationProbe — measures how small an inter-speaker timing offset THIS
// listener can still hear, when the cue is IMAGE POSITION rather than "one
// click or two".
//
// Why: the by-ear alignment wizard currently asks "do the two clicks sound
// like one or two?", which has a hard perceptual floor around 4 ms — below
// ~1-5 ms two clicks FUSE into one event and the question stops having an
// answer. But the fused event is not position-less: it leans toward whichever
// speaker fired FIRST (the precedence effect), and binaural timing resolution
// is far finer than fusion. If the operator can reliably name the leading
// speaker at, say, 0.4 ms, a "which side does it lean?" wizard can converge an
// order of magnitude tighter than the fusion wizard. This probe measures that
// number for one listener, one speaker pair, one room — before anyone builds
// the wizard.
//
// Method: a blind 1-up/2-down forced-choice staircase. Each trial ticks both
// devices with a randomly-signed offset; the operator says which side it came
// from; the magnitude shrinks after two right answers and grows after one
// wrong. The answer is NEVER revealed during the run — blinding is the entire
// point — only in the final summary.
//
// AUDIO ARCHITECTURE (the live-found silent-BT lesson): each engine is started
// ONCE and loops ONE long-lived buffer forever; every phase and every trial is
// produced by rewriting that buffer's samples in place. There is NO per-trial
// scheduling and NO absolute-time (`play(at:)`) scheduling anywhere — on a
// Bluetooth device the host-time -> device-sample-time mapping goes through
// the BT stack's pacing clock, which this branch's own --pacing-probe measured
// jumping ±5-100 ms for ~40 s after connect; a jump can land a scheduled
// buffer in the device's past and the player renders SILENCE with no error
// (exactly what the first live run hit: Mac ticked, Sonos stayed mute). The
// continuously-running loop is the July known-good path that live-streamed to
// two Sonos for 60 s. The two loops start with an arbitrary-but-constant skew
// (immediate play on two engines); the centre-the-image step absorbs it along
// with the device latency difference.
//
// Other traps respected: the offset lives in the sample data, not in
// AVAudioUnitDelay (whose resolution at 0.05 ms is unspecified); aggregate
// devices are refused outright (AVAudioEngine silently no-ops on them);
// BTOutputEngine does the device pinning, so setDeviceID still happens before
// the first start and nothing ever taps outputNode.
// ============================================================================

enum LateralizationProbe {

    // MARK: - Staircase + stimulus parameters (the report prints these verbatim)

    private static let startMagnitudeMs = 8.0
    private static let downFactor = 0.7 // two correct in a row -> harder
    private static let upFactor = 1.6 // one wrong -> easier
    private static let floorMs = 0.05
    private static let ceilingMs = 30.0
    private static let maxTrials = 24
    private static let maxReversals = 8
    private static let reversalsInThreshold = 6

    /// One tick per loop pass — a steady ~0.8 Hz metronome while a pattern is
    /// set. A trial keeps ticking until the operator answers (a superset of
    /// the fixed 5-tick burst: same blind stimulus, listen as long as needed).
    private static let loopSeconds = 1.2
    /// The tick sits mid-loop so the centre step's ±500 ms and the staircase's
    /// ±30 ms both stay inside the buffer (0.6 ± 0.53 s, tick ends < 1.2 s).
    private static let baseTickSeconds = 0.6
    private static let maxCentreMs = 500.0
    private static let tickDurationSeconds = 0.030
    private static let tickDecayTau = 0.006
    private static let interTrialGapSeconds = 0.6

    // MARK: Keep-alive noise bed (live-found 2026-08-07: the Sonos Move 2
    // POWER-GATES its amplifier on signal energy — a `say` sentence lost its
    // first ~6 s while the pacing clock advanced perfectly, so the Mac fed it
    // flawlessly and the speaker's amp just woke late. Sparse 30 ms ticks over
    // silence are exactly the shape such an amp never wakes for, or eats in
    // its attack ramp. A continuous low-level noise floor on BOTH devices
    // holds the amps open for the whole session.)
    /// ~-47 dBFS RMS: enough energy to hold an energy-gated amp open, quiet
    /// enough not to mask a -5 dBFS tick.
    private static let bedRMS: Float = 0.0045
    /// Bed alone at session start, before any UI prompt, so gated amps are
    /// open before the operator hears the first tick.
    private static let bedWakeupSeconds = 3.0

    // MARK: - Entry point

    static func run(_ rawArgs: [String]) -> Int32 {
        let demo = rawArgs.contains("--demo")
        let smoke = rawArgs.contains("--smoke")
        let positional = rawArgs.filter { !$0.hasPrefix("--") }
        let devices = BTDeviceEnumerator.listAllOutputDevices()

        guard positional.count == 2 else {
            printDeviceList(devices)
            elog("")
            elog("lateralization-probe: pick TWO output devices.")
            elog("  usage: --lateralization-probe <A> <B> [--demo | --smoke]")
            elog("  <A>/<B> = the index from the list above, or part of the device name/uid.")
            elog("  A is treated as the LEFT speaker, B as the RIGHT one.")
            return 2
        }
        guard let deviceA = resolve(positional[0], in: devices, label: "A"),
              let deviceB = resolve(positional[1], in: devices, label: "B") else {
            printDeviceList(devices)
            return 1
        }
        guard deviceA.id != deviceB.id else {
            elog("lateralization-probe: A and B resolved to the SAME device (id=\(deviceA.id)) — pick two different outputs.")
            return 2
        }
        for device in [deviceA, deviceB] where device.isAggregate {
            elog("lateralization-probe: \"\(device.name)\" is an AGGREGATE device — refused.")
            elog("  AVAudioEngine accepts an aggregate device and then silently renders nothing;")
            elog("  it would look like it worked and you would hear silence. Pick the real outputs.")
            return 1
        }
        guard smoke || isatty(STDIN_FILENO) != 0 else {
            elog("lateralization-probe: needs a terminal (tty) — it reads single keypresses. (--smoke doesn't.)")
            return 1
        }

        print("lateralization-probe: A(left) = \"\(deviceA.name)\" [\(deviceA.transportLabel)]  B(right) = \"\(deviceB.name)\" [\(deviceB.transportLabel)]")

        guard let stimulus = Stimulus(deviceA: deviceA, deviceB: deviceB) else { return 1 }
        defer { stimulus.stop() }

        // Bed alone before ANY prompt or tick: an energy-gated amp (Sonos
        // Move 2, live 2026-08-07) needs seconds of signal before it opens.
        print("warming up: \(Int(bedWakeupSeconds))s of low-level noise on both devices, so energy-gated amps are awake before the first tick...")
        Thread.sleep(forTimeInterval: bedWakeupSeconds)

        if smoke {
            return runSmoke(stimulus, nameA: deviceA.name, nameB: deviceB.name)
        }

        print("Put A physically on your left and B on your right, sit between them, and don't move your head during the run.")
        installSignalHandlers()
        enableRawMode()
        defer { restoreTerminal() }

        guard levelMatch(stimulus, nameA: deviceA.name, nameB: deviceB.name) else {
            print("\nlateralization-probe: aborted before the run started.")
            return 1
        }
        guard let baseMs = coarseAlign(stimulus, nameA: deviceA.name, nameB: deviceB.name) else {
            print("\nlateralization-probe: aborted before the run started.")
            return 1
        }
        if demo {
            runDemo(stimulus, nameA: deviceA.name, nameB: deviceB.name, baseMs: baseMs)
        } else {
            runStaircase(stimulus, nameA: deviceA.name, nameB: deviceB.name, baseMs: baseMs)
        }
        return 0
    }

    // MARK: - Device selection

    private static func printDeviceList(_ devices: [BTOutputDevice]) {
        elog("lateralization-probe: output devices:")
        for (i, d) in devices.enumerated() {
            let tag = d.isAggregate ? "  [AGGREGATE — cannot be used]" : ""
            elog("  \(i + 1). \"\(d.name)\"  (\(d.transportLabel))  id=\(d.id) uid=\(d.uid)\(tag)")
        }
    }

    private static func resolve(_ query: String, in devices: [BTOutputDevice], label: String) -> BTOutputDevice? {
        if let index = Int(query) {
            guard index >= 1, index <= devices.count else {
                elog("lateralization-probe: \(label): index \(index) is out of range (1...\(devices.count)).")
                return nil
            }
            return devices[index - 1]
        }
        let lowered = query.lowercased()
        let matches = devices.filter { $0.name.lowercased().contains(lowered) || $0.uid.lowercased().contains(lowered) }
        guard matches.count == 1, let match = matches.first else {
            elog("lateralization-probe: \(label): '\(query)' matched \(matches.count) output device(s) — be more specific or use an index.")
            return nil
        }
        return match
    }

    // MARK: - Stimulus: two forever-looping buffers, rewritten in place

    /// Owns the two engines and the one looping buffer each plays for the
    /// whole run. Patterns are changed by rewriting the buffers' samples —
    /// the players are never stopped, never rescheduled. The render thread
    /// may read a frame mid-rewrite; worst case is one partial-amplitude tick
    /// on one loop pass, which is harmless here and vastly preferable to
    /// rescheduling against a jumpy BT clock.
    private final class Stimulus {
        private let engineA: BTOutputEngine
        private let engineB: BTOutputEngine
        private let bufferA: AVAudioPCMBuffer
        private let bufferB: AVAudioPCMBuffer
        // One keep-alive noise bed per device, INDEPENDENT (uncorrelated).
        // The correlation choice matters: identical (correlated) noise on both
        // speakers would form a coherent phantom image of its own, and that
        // image would shift with any inter-device offset — including the
        // offset under test — handing the operator a second, always-on cue
        // and biasing the which-side judgement. Uncorrelated equal-level
        // noise has no coherent interaural timing image: it reads as diffuse
        // room hiss with no side to lean to, so it can hold the amps open
        // without touching the tick's lateralization.
        private let bedA: [Float]
        private let bedB: [Float]

        init?(deviceA: BTOutputDevice, deviceB: BTOutputDevice) {
            engineA = BTOutputEngine(deviceID: deviceA.id, deviceName: deviceA.name, mode: .click)
            engineB = BTOutputEngine(deviceID: deviceB.id, deviceName: deviceB.name, mode: .click)
            let frames = Int(ToneSource.sampleRate * loopSeconds)
            bedA = Stimulus.makeBed(frames: frames)
            bedB = Stimulus.makeBed(frames: frames)
            bufferA = Stimulus.makeSilentLoop()
            bufferB = Stimulus.makeSilentLoop()
            engineA.setVolume(0.5)
            engineB.setVolume(0.5)
            silence() // = bed only; both loops carry the bed from frame 0
            do {
                try engineA.start()
                try engineB.start()
            } catch {
                elog("lateralization-probe: engine start FAILED: \(error)")
                engineA.stop()
                engineB.stop()
                return nil
            }
            // Replace the engines' own click loop with our silent loop, once.
            // Immediate play() — the ONLY scheduling in the whole probe.
            engineA.playLoopingBuffer(bufferA)
            engineB.playLoopingBuffer(bufferB)
        }

        func stop() {
            engineA.stop()
            engineB.stop()
        }

        func setGainA(_ gain: Float) { engineA.setVolume(gain) }
        func setGainB(_ gain: Float) { engineB.setVolume(gain) }

        /// "Silence" = bed only. Never true digital silence anywhere in the
        /// session — that is what lets an energy-gated amp fall asleep.
        func silence() {
            write(tickSeconds: nil, into: bufferA, bed: bedA)
            write(tickSeconds: nil, into: bufferB, bed: bedB)
        }

        /// Level-match pattern: A ticks, then B ticks half a loop later.
        func setAlternating() {
            write(tickSeconds: 0.15, into: bufferA, bed: bedA)
            write(tickSeconds: 0.15 + loopSeconds / 2, into: bufferB, bed: bedB)
        }

        /// Only one side ticks (smoke check). The OTHER side still carries
        /// the bed — the smoke test must prove ticks, not wake-from-cold.
        func setSolo(a: Bool) {
            write(tickSeconds: a ? baseTickSeconds : nil, into: bufferA, bed: bedA)
            write(tickSeconds: a ? nil : baseTickSeconds, into: bufferB, bed: bedB)
        }

        /// Both tick once per loop; `offsetMs` > 0 delays B (A leads, image
        /// pulls toward A), < 0 delays A. Sample-accurate: the offset is in
        /// the tick's frame position.
        func setCentered(offsetMs: Double) {
            write(tickSeconds: baseTickSeconds + max(0, -offsetMs) / 1000, into: bufferA, bed: bedA)
            write(tickSeconds: baseTickSeconds + max(0, offsetMs) / 1000, into: bufferB, bed: bedB)
        }

        private static func makeSilentLoop() -> AVAudioPCMBuffer {
            let frameCount = AVAudioFrameCount(ToneSource.sampleRate * loopSeconds)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: ToneSource.format, frameCapacity: frameCount) else {
                fatalError("lateralization-probe: failed to allocate loop buffer")
            }
            buffer.frameLength = frameCount // zero-filled on alloc
            return buffer
        }

        /// One loop of keep-alive noise: white noise through a one-pole
        /// low-pass (~1 kHz corner — "filtered dither", pink-ish, no hissy
        /// top end), normalized to `bedRMS`. Fresh random samples per call,
        /// so A's and B's beds are independent by construction. The loop
        /// seam is a noise-to-noise discontinuity at ~-47 dBFS — inaudible.
        private static func makeBed(frames: Int) -> [Float] {
            var bed = [Float](repeating: 0, count: frames)
            var y: Float = 0
            for i in 0..<frames {
                let white = Float.random(in: -1...1)
                y += 0.15 * (white - y)
                bed[i] = y
            }
            let rms = sqrt(bed.reduce(0) { $0 + $1 * $1 } / Float(frames))
            guard rms > 0 else { return bed }
            let scale = bedRMS / rms
            for i in 0..<frames { bed[i] *= scale }
            return bed
        }

        /// Fill the whole loop with this device's bed, then (unless nil) add
        /// one tick at `tickSeconds`.
        private func write(tickSeconds: Double?, into buffer: AVAudioPCMBuffer, bed: [Float]) {
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            for channel in 0..<Int(buffer.format.channelCount) {
                let data = channels[channel]
                bed.withUnsafeBufferPointer { src in
                    data.update(from: src.baseAddress!, count: min(frames, src.count))
                }
                if let tickSeconds {
                    writeTick(data, at: Int(ToneSource.sampleRate * tickSeconds), capacity: frames)
                }
            }
        }

        /// One woodblock-ish transient: two decaying sine partials (1.8 kHz +
        /// 2.9 kHz) under an exponential envelope with a half-millisecond
        /// attack ramp. Sharper onset than ToneSource's raised-cosine click,
        /// which rises over ~4 ms — far too soft when the whole experiment is
        /// about onset timing.
        private func writeTick(_ data: UnsafeMutablePointer<Float>, at startFrame: Int, capacity: Int) {
            let sr = ToneSource.sampleRate
            let frames = Int(sr * tickDurationSeconds)
            let attackFrames = max(1, Int(sr * 0.0005))
            for i in 0..<frames {
                let frame = startFrame + i
                guard frame >= 0, frame < capacity else { continue }
                let t = Double(i) / sr
                let attack = i < attackFrames ? Double(i) / Double(attackFrames) : 1.0
                let envelope = exp(-t / tickDecayTau)
                let partials = sin(2 * .pi * 1800 * t) + 0.6 * sin(2 * .pi * 2900 * t)
                data[frame] += Float(0.55 * attack * envelope * partials / 1.6)
            }
        }
    }

    // MARK: - Smoke check (non-interactive; no tty, no staircase)

    /// Audible plumbing proof: 5 ticks on A alone, then 5 on B alone, exit.
    /// Runnable from a script — this is the check that would have caught the
    /// silent-Bluetooth scheduling bug before the operator sat down. Five per
    /// side so a late-waking amp still demonstrates several; the idle side
    /// keeps its bed throughout.
    private static func runSmoke(_ stimulus: Stimulus, nameA: String, nameB: String) -> Int32 {
        let perSide = 5.0 * loopSeconds + 0.3
        print("smoke: 5 ticks on A = \"\(nameA)\" ...")
        stimulus.setSolo(a: true)
        Thread.sleep(forTimeInterval: perSide)
        print("smoke: 5 ticks on B = \"\(nameB)\" ...")
        stimulus.setSolo(a: false)
        Thread.sleep(forTimeInterval: perSide)
        stimulus.silence()
        print("smoke: done — you should have heard ticks from BOTH devices, A first.")
        return 0
    }

    // MARK: - Keyboard

    private enum Key: Equatable {
        case left
        case right
        case space
        case char(Character)
    }

    /// One keypress in raw mode. Arrow keys arrive as the three-byte escape
    /// sequence ESC [ D / ESC [ C; a bare Esc therefore blocks until the next
    /// key, which is fine here (Esc is not a probe key).
    private static func readKey() -> Key? {
        func readByte() -> UInt8? {
            var byte: UInt8 = 0
            while true {
                let n = read(STDIN_FILENO, &byte, 1)
                if n == 1 { return byte }
                if n == -1 && errno == EINTR { continue }
                return nil
            }
        }
        guard let first = readByte() else { return nil }
        if first == 0x1B {
            guard let second = readByte(), second == 0x5B, let third = readByte() else { return .char("\u{1B}") }
            switch third {
            case 0x44: return .left
            case 0x43: return .right
            default: return .char("\u{1B}")
            }
        }
        if first == 0x20 { return .space }
        return .char(Character(Unicode.Scalar(first)))
    }

    // MARK: - Step 1: level matching (MANDATORY)

    /// Alternating ticks, A then B, with per-device gain on the keys. A
    /// loudness difference between the speakers imitates a timing offset —
    /// the precedence effect survives roughly 10 dB of level mismatch — so an
    /// unmatched pair would measure loudness, not timing. Returns false if
    /// the operator quit.
    private static func levelMatch(_ stimulus: Stimulus, nameA: String, nameB: String) -> Bool {
        var gainA: Float = 0.5
        var gainB: Float = 0.5
        var selected = 0
        stimulus.setAlternating()
        print("""

        ---- step 1 of 3: LEVEL MATCH (mandatory) ----
        A tick alternates: \(nameA), then \(nameB).
        (No sound from one side = stop here; run --smoke to debug the plumbing.)
        Adjust until the two ticks sound EQUALLY LOUD from where you are sitting.
          1 / 2   pick which device you are adjusting (1=\(nameA), 2=\(nameB))
          ] / [   that device louder / quieter (0.02 steps)
          space   confirm they are equally loud, continue
          q       quit
        """)
        printGains(gainA, gainB, selected: selected, nameA: nameA, nameB: nameB)
        while true {
            guard let key = readKey() else { return false }
            switch key {
            case .space:
                print("[level] accepted — A=\(String(format: "%.2f", gainA)) B=\(String(format: "%.2f", gainB))")
                return true
            case .char("q"):
                return false
            case .char("1"):
                selected = 0
            case .char("2"):
                selected = 1
            case .char("]"), .char("["):
                let delta: Float = key == .char("]") ? 0.02 : -0.02
                if selected == 0 {
                    gainA = min(1, max(0, gainA + delta))
                    stimulus.setGainA(gainA)
                } else {
                    gainB = min(1, max(0, gainB + delta))
                    stimulus.setGainB(gainB)
                }
            default:
                continue
            }
            printGains(gainA, gainB, selected: selected, nameA: nameA, nameB: nameB)
        }
    }

    private static func printGains(_ gainA: Float, _ gainB: Float, selected: Int, nameA: String, nameB: String) {
        let markA = selected == 0 ? ">" : " "
        let markB = selected == 1 ? ">" : " "
        print(String(format: "[level] %@1 %@ = %.2f    %@2 %@ = %.2f", markA, nameA, gainA, markB, nameB, gainB))
    }

    // MARK: - Step 2: coarse alignment

    /// Find the offset at which the fused tick sits in the MIDDLE. Two
    /// speakers have wildly different output latencies (a BT speaker runs
    /// 150-250 ms behind the built-in output), and the two loops also started
    /// with an arbitrary-but-constant scheduling skew; both would otherwise
    /// swamp every trial. Whatever the operator centres here becomes the zero
    /// the staircase measures around — which is the right zero, since the
    /// wizard this probe informs would also work relative to a centred image.
    /// Returns the accepted base offset in ms, or nil if the operator quit.
    private static func coarseAlign(_ stimulus: Stimulus, nameA: String, nameB: String) -> Double? {
        var baseMs = 0.0
        stimulus.setCentered(offsetMs: baseMs)
        print("""

        ---- step 2 of 3: CENTRE THE IMAGE ----
        Both speakers now tick together. Below a few milliseconds you will hear
        ONE tick, not two — that is expected. Do not chase "one tick": adjust
        until that single tick sounds like it comes from BETWEEN the two
        speakers rather than out of one of them.
          left / right arrow   shift 10 ms toward \(nameA) / \(nameB)
          [ / ]                shift 1 ms
          , / .                shift 0.1 ms
          space                accept this as centre, start the run
          q                    quit
        """)
        print(String(format: "[align] offset = %+.1f ms", baseMs))
        while true {
            guard let key = readKey() else { return nil }
            var delta = 0.0
            switch key {
            case .space:
                print(String(format: "[align] accepted centre offset = %+.2f ms", baseMs))
                return baseMs
            case .char("q"):
                return nil
            case .left: delta = -10
            case .right: delta = 10
            case .char("["): delta = -1
            case .char("]"): delta = 1
            case .char(","): delta = -0.1
            case .char("."): delta = 0.1
            default: continue
            }
            baseMs = min(maxCentreMs, max(-maxCentreMs, baseMs + delta))
            stimulus.setCentered(offsetMs: baseMs)
            print(String(format: "[align] offset = %+.2f ms", baseMs))
        }
    }

    // MARK: - Step 3a: the blind staircase

    private struct Trial {
        let magnitudeMs: Double
        let correct: Bool
        let cantTell: Bool
    }

    private static func runStaircase(
        _ stimulus: Stimulus, nameA: String, nameB: String, baseMs: Double
    ) {
        print("""

        ---- step 3 of 3: THE BLIND RUN ----
        Each trial ticks steadily until you answer — listen as long as you need,
        then say which side the ticks came from.
          left arrow    \(nameA)
          right arrow   \(nameB)
          space         can't tell
          q             stop early (the summary still prints)
        The answer is never shown until the end — that is deliberate.
        """)

        var magnitude = startMagnitudeMs
        var consecutiveCorrect = 0
        var lastDirection = 0
        var reversals: [Double] = []
        var trials: [Trial] = []
        var quitEarly = false

        while trials.count < maxTrials && reversals.count < maxReversals {
            let bLeads = Bool.random()
            let delta = bLeads ? -magnitude : magnitude
            stimulus.setCentered(offsetMs: baseMs + delta)

            print("trial \(trials.count + 1)/\(maxTrials) — which side?  [<-] \(nameA)   [->] \(nameB)   [space] can't tell")
            var answer: Key?
            while answer == nil {
                guard let key = readKey() else { quitEarly = true; break }
                switch key {
                case .left, .right, .space: answer = key
                case .char("q"): quitEarly = true; answer = .char("q")
                default: continue
                }
            }
            stimulus.silence()
            if quitEarly { break }
            Thread.sleep(forTimeInterval: interTrialGapSeconds)

            let cantTell = answer == .space
            let correct = !cantTell && ((bLeads && answer == .right) || (!bLeads && answer == .left))
            trials.append(Trial(magnitudeMs: magnitude, correct: correct, cantTell: cantTell))

            consecutiveCorrect = correct ? consecutiveCorrect + 1 : 0
            var next = magnitude
            if correct, consecutiveCorrect >= 2 {
                next = max(floorMs, magnitude * downFactor)
                consecutiveCorrect = 0
            } else if !correct {
                next = min(ceilingMs, magnitude * upFactor)
            }
            if next != magnitude {
                let direction = next < magnitude ? -1 : 1
                if lastDirection != 0, direction != lastDirection {
                    // Convention: a reversal is recorded at the magnitude that
                    // was actually tested when the staircase turned around.
                    reversals.append(magnitude)
                }
                lastDirection = direction
                magnitude = next
            }
        }

        report(trials: trials, reversals: reversals, nameA: nameA, nameB: nameB, baseMs: baseMs, quitEarly: quitEarly)
    }

    // MARK: - Step 3b: demo (NOT blind)

    private static func runDemo(
        _ stimulus: Stimulus, nameA: String, nameB: String, baseMs: Double
    ) {
        let script: [(Double, String)] = [
            (8, "+8 ms — \(nameB) delayed by 8 ms; should lean clearly toward \(nameA)"),
            (-8, "-8 ms — \(nameA) delayed by 8 ms; should lean clearly toward \(nameB)"),
            (2, "+2 ms — \(nameB) delayed by 2 ms; one fused tick, leaning toward \(nameA)"),
            (-2, "-2 ms — \(nameA) delayed by 2 ms; one fused tick, leaning toward \(nameB)"),
            (0, "0 ms — dead centre; no lean either way"),
        ]
        print("""

        ---- DEMO (not blind) ----
        Each offset is announced before it plays for ~6 seconds, so you learn
        what the cue sounds like. Nothing here is scored.
        """)
        for (index, step) in script.enumerated() {
            print("demo \(index + 1)/\(script.count): \(step.1)")
            stimulus.setCentered(offsetMs: baseMs + step.0)
            Thread.sleep(forTimeInterval: 5 * loopSeconds)
            stimulus.silence()
            Thread.sleep(forTimeInterval: interTrialGapSeconds)
        }
        print("demo: done. Re-run without --demo for the blind, scored staircase.")
    }

    // MARK: - Report

    private static func report(
        trials: [Trial], reversals: [Double],
        nameA: String, nameB: String, baseMs: Double, quitEarly: Bool
    ) {
        print("\n==== lateralization-probe summary ====")
        if quitEarly { print("(stopped early — figures below cover the trials that ran)") }
        guard !trials.isEmpty else {
            print("No trials completed; nothing to report.")
            return
        }

        print(String(format: "pair: A(left)=\"%@\"  B(right)=\"%@\"  centred at %+.2f ms", nameA, nameB, baseMs))
        print("staircase: start \(fmt(startMagnitudeMs)) ms, 1-up/2-down, x\(downFactor) down / x\(upFactor) up, floor \(fmt(floorMs)) ms, ceiling \(fmt(ceilingMs)) ms, stop at \(maxTrials) trials or \(maxReversals) reversals")
        print("stimulus: steady tick every \(fmt(loopSeconds)) s until answered, \(Int(tickDurationSeconds * 1000)) ms woodblock (1.8 + 2.9 kHz, exponential decay), offset baked into the samples of a continuously-looping buffer (no per-trial scheduling); continuous uncorrelated ~-47 dBFS noise bed on both devices (amp keep-alive)")

        // Per-magnitude hit rate.
        var order: [String] = []
        var buckets: [String: (n: Int, correct: Int, magnitude: Double)] = [:]
        for trial in trials {
            let key = fmt(trial.magnitudeMs)
            if buckets[key] == nil {
                buckets[key] = (0, 0, trial.magnitudeMs)
                order.append(key)
            }
            buckets[key]!.n += 1
            if trial.correct { buckets[key]!.correct += 1 }
        }
        let sorted = order.sorted { (buckets[$0]?.magnitude ?? 0) > (buckets[$1]?.magnitude ?? 0) }
        print("\nper-magnitude hit rate:")
        print("  magnitude(ms)      n   correct   %")
        for key in sorted {
            guard let bucket = buckets[key] else { continue }
            let pct = 100.0 * Double(bucket.correct) / Double(bucket.n)
            let magnitudeColumn = String(repeating: " ", count: max(0, 12 - key.count)) + key
            print(String(format: "  %@ %6d %9d %5.0f%%", magnitudeColumn, bucket.n, bucket.correct, pct))
        }

        // Threshold estimate.
        print("\nreversals (\(reversals.count)): \(reversals.map(fmt).joined(separator: ", ")) ms")
        let tail = Array(reversals.suffix(reversalsInThreshold))
        if tail.isEmpty {
            print("threshold estimate: none — the staircase never reversed (run more trials).")
        } else {
            let mean = tail.reduce(0, +) / Double(tail.count)
            print(String(format: "threshold estimate: %.2f ms  (estimator: arithmetic mean of the last %d reversal magnitudes)", mean, tail.count))
            if tail.count < reversalsInThreshold {
                print("  NOTE: fewer than \(reversalsInThreshold) reversals — treat this as provisional.")
            }
        }

        // Can't-tell tally.
        let cantTell = trials.filter { $0.cantTell }
        print("\n\"can't tell\": \(cantTell.count) of \(trials.count) trials (counted as wrong by the staircase, tallied separately here)")
        if !cantTell.isEmpty {
            print("  at magnitudes: \(cantTell.map { fmt($0.magnitudeMs) }.sorted().joined(separator: ", ")) ms")
        }

        // Verdict.
        let reliable = sorted.compactMap { key -> (Double, Int, Int)? in
            guard let bucket = buckets[key], bucket.n >= 2,
                  Double(bucket.correct) / Double(bucket.n) >= 0.75 else { return nil }
            return (bucket.magnitude, bucket.n, bucket.correct)
        }
        print("\nverdict:")
        if let smallest = reliable.min(by: { $0.0 < $1.0 }) {
            print(String(format: "  smallest magnitude called correctly at >=75%%: %.2f ms (%d/%d trials)", smallest.0, smallest.2, smallest.1))
            print(String(format: "  IMPLICATION: a \"which side does it lean?\" bisection wizard can converge to about %.2f ms with this listener and this speaker pair.", smallest.0))
            print("  Compare with the fuse/split wizard's floor of ~4 ms — anything well under that is the reason to build the lateralization wizard.")
        } else {
            let overall = Double(trials.filter { $0.correct }.count) / Double(trials.count)
            print(String(format: "  no magnitude reached 75%% over 2+ trials (overall %.0f%% correct).", overall * 100))
            print("  If this is near 50%%, the two speakers are not forming a shared stereo image at all.")
            print("  That is a REAL result, not a failed run: a lateralization wizard cannot work in this arrangement.")
        }

        print("""

        READ THIS BEFORE QUOTING THE NUMBER
        It measures THIS listener, THESE two speakers, and THIS room and seating
        position — nothing more. Move a speaker, turn your head, or swap a
        speaker and it changes. Two speakers in DIFFERENT ROOMS share no stereo
        image at all, so expect chance performance there; that is itself a valid
        finding, and it bounds where the wizard can be offered.
        """)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
