// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What shape of align-tick run a caller wants (W2) — the public vocabulary
/// the ``CaptureControlling`` seam speaks so the injector's numeric ``AlignmentTickInjector/Config``
/// stays internal. `.manual` is the row's metronome button; `.wizard` is the
/// alignment wizard's continuous run (long budget + keep-alive bed preamble).
public enum AlignTickMode: Equatable, Sendable {
    case off
    case manual
    case wizard
}

/// The align-by-ear aid's tick source (BT-OFFSET-UI): a synthesized
/// woodblock-style transient mixed INTO the whole-system capture's converted
/// PCM, post-capture, so every consumer of that one feed — the AirPlay engine,
/// the synced-local sink, and every Bluetooth sink — renders the SAME tick
/// through its own delay. That is what makes the alignment truthful: the user
/// nudges a device's SYNC trim until the flam between its tick and the rest of
/// the group collapses into one. Playing the tick out loud instead would never
/// work — the app's own render processes are tap-EXCLUDED by design (R-echo).
///
/// Beat spacing deliberately dodges offset aliasing: at 120 BPM (500 ms) a
/// fully-offset device (trim range is ±500 ms) sounds aligned exactly one beat
/// late, so the default is ~72 BPM (~833 ms).
///
/// The tick is SYNTHESIZED (two decaying sine partials with a near-instant
/// attack — a woodblock-shaped transient; the ear detects double-hits down to
/// ~10–20 ms), never a bundled audio file.
///
/// Threading: created on the coordinator's control queue, then touched ONLY
/// from the tap delivery thread via the published `BufferSnapshot` — single
/// consumer, so the mutable cursor needs no lock. `mix` allocates nothing.
///
/// The injector self-limits: after ``Config/maxTicks`` beats (~30 s at the
/// default tempo) it stops emitting on its own, so a UI that forgets to switch
/// it off can only ever leak silence, not a metronome.
///
/// **Keep-alive bed** (live finding 2026-08-07): the Sonos Move power-gates
/// its amplifier after silence and swallows short transients — the first
/// ticks after a quiet stretch simply never come out of it. So while the
/// injector is active it also mixes a quiet low-passed noise bed
/// (~``Config/bedRMSdBFS`` dBFS RMS — just enough signal to hold the amp
/// awake, below noticeability under ticks), and the wizard config prepends a
/// bed-only wake preamble before the first tick. The bed is necessarily ONE
/// SHARED bed for every consumer: this injector mixes into the single
/// converted feed BEFORE the fan-outs, so per-device uncorrelated beds are
/// structurally impossible in this architecture — acceptable, because at
/// −47 dBFS a correlated bed's inter-device flam is inaudible; its only job
/// is keeping the amps powered.
final class AlignmentTickInjector: @unchecked Sendable {

    /// ~30 s of ticks at 72 BPM.
    static let defaultMaxTicks = 36

    /// One activation's shape. `.manual` is the row's metronome button
    /// (self-limits ~30 s, no preamble — the user clicked expecting a tick
    /// now); `.wizard` is the alignment wizard's continuous run (long budget —
    /// the session turns it off on every exit path — plus the ~3 s wake
    /// preamble so the first QUESTION tick lands on already-awake amps).
    struct Config: Equatable, Sendable {
        var bpm: Double = 72
        var maxTicks: Int = AlignmentTickInjector.defaultMaxTicks
        var preambleSeconds: Double = 0
        var bedEnabled: Bool = true

        /// The bed's target RMS. −47 dBFS: measured comfortably below
        /// music/ticks, still enough to defeat the Move's amp gate.
        static let bedRMSdBFS: Double = -47

        static let manual = Config()
        static let wizard = Config(maxTicks: 360, preambleSeconds: 3)
    }

    private let beatFrames: Int
    private let channels: Int
    private let maxTicks: Int
    private let preambleFrames: Int
    /// The pre-rendered mono tick, added to every channel.
    private let tick: [Int32]
    /// Pre-rendered mono noise-bed loop (empty when the bed is disabled).
    private let bed: [Int32]
    /// Frames consumed since injection began — tap-delivery-thread-only.
    private var cursor = 0

    init(sampleRate: Double = 44_100,
         channels: Int = 2,
         config: Config = .manual,
         amplitude: Double = 0.35) {
        self.beatFrames = max(1, Int((sampleRate * 60.0 / config.bpm).rounded()))
        self.channels = max(1, channels)
        self.maxTicks = config.maxTicks
        self.preambleFrames = max(0, Int((sampleRate * config.preambleSeconds).rounded()))
        self.bed = config.bedEnabled ? Self.renderBed(sampleRate: sampleRate) : []

        // Woodblock-ish transient: ~30 ms, two partials, exponential decay
        // (τ ≈ 6 ms), with a handful of attack samples ramped so the onset is
        // sharp but not a raw DC step.
        let frames = Int(sampleRate * 0.03)
        let tau = 0.006
        let attackFrames = 8
        var rendered = [Int32](repeating: 0, count: frames)
        for f in 0..<frames {
            let t = Double(f) / sampleRate
            let envelope = exp(-t / tau) * (f < attackFrames ? Double(f) / Double(attackFrames) : 1)
            let partials = 0.7 * sin(2 * .pi * 1_800 * t) + 0.3 * sin(2 * .pi * 2_900 * t)
            rendered[f] = Int32((amplitude * envelope * partials * 32_767.0).rounded())
        }
        self.tick = rendered
    }

    /// The keep-alive bed loop: white noise through a one-pole low-pass
    /// (fc ≈ 800 Hz — a soft hiss, no crackle), normalized to
    /// ``Config/bedRMSdBFS`` RMS. Deterministically seeded so tests can assert
    /// exact output; ~0.75 s loop, long enough that the repeat is not a pitch.
    private static func renderBed(sampleRate: Double) -> [Int32] {
        let frames = max(1, Int(sampleRate * 0.75))
        let alpha = 1 - exp(-2 * .pi * 800 / sampleRate)
        var rng: UInt64 = 0x9E3779B97F4A7C15
        var filtered = 0.0
        var raw = [Double](repeating: 0, count: frames)
        var sumSquares = 0.0
        for f in 0..<frames {
            // SplitMix64 — cheap, deterministic, no Foundation RNG state.
            rng &+= 0x9E3779B97F4A7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            let white = Double(z >> 11) / Double(1 << 53) * 2 - 1
            filtered += alpha * (white - filtered)
            raw[f] = filtered
            sumSquares += filtered * filtered
        }
        let rms = (sumSquares / Double(frames)).squareRoot()
        let targetRMS = pow(10, Config.bedRMSdBFS / 20)
        let scale = rms > 0 ? targetRMS / rms : 0
        return raw.map { Int32(($0 * scale * 32_767.0).rounded()) }
    }

    /// Mix the bed + tick into one converted S16LE interleaved buffer in place.
    /// Native-endian Int16 math is correct here: the airplay PCM format is
    /// little-endian and so is every Apple-silicon/Intel Mac this runs on.
    /// Ticks start after the preamble (bed only) and stop after `maxTicks`
    /// beats; the bed stops with them, so an expired injector adds nothing.
    func mix(into pcm: inout Data) {
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        guard bytesPerFrame > 0 else { return }
        let frameCount = pcm.count / bytesPerFrame
        let endFrame = preambleFrames + maxTicks * beatFrames
        guard frameCount > 0, cursor < endFrame else { return }
        let start = cursor
        pcm.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for f in 0..<frameCount {
                let position = start + f
                guard position < endFrame else { break }
                var add: Int32 = 0
                if !bed.isEmpty { add = bed[position % bed.count] }
                if position >= preambleFrames {
                    let phase = (position - preambleFrames) % beatFrames
                    if phase < tick.count { add += tick[phase] }
                }
                guard add != 0 else { continue }
                for ch in 0..<channels {
                    let idx = f * channels + ch
                    samples[idx] = Int16(clamping: Int32(samples[idx]) + add)
                }
            }
        }
        cursor += frameCount
    }

    // MARK: Test seams (pure reads)

    var test_beatFrames: Int { beatFrames }
    var test_tickFrameCount: Int { tick.count }
    var test_maxTicks: Int { maxTicks }
    var test_preambleFrames: Int { preambleFrames }
    var test_bedFrameCount: Int { bed.count }
}
