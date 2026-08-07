// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

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
/// The injector self-limits: after ``maxTicks`` beats (~30 s at the default
/// tempo) it stops emitting on its own, so a UI that forgets to switch it off
/// can only ever leak silence, not a metronome.
final class AlignmentTickInjector: @unchecked Sendable {

    /// ~30 s of ticks at 72 BPM.
    static let defaultMaxTicks = 36

    private let beatFrames: Int
    private let channels: Int
    private let maxTicks: Int
    /// The pre-rendered mono tick, added to every channel.
    private let tick: [Int32]
    /// Frames consumed since injection began — tap-delivery-thread-only.
    private var cursor = 0

    init(sampleRate: Double = 44_100,
         channels: Int = 2,
         bpm: Double = 72,
         maxTicks: Int = AlignmentTickInjector.defaultMaxTicks,
         amplitude: Double = 0.35) {
        self.beatFrames = max(1, Int((sampleRate * 60.0 / bpm).rounded()))
        self.channels = max(1, channels)
        self.maxTicks = maxTicks

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

    /// Mix the tick into one converted S16LE interleaved buffer in place.
    /// Native-endian Int16 math is correct here: the airplay PCM format is
    /// little-endian and so is every Apple-silicon/Intel Mac this runs on.
    func mix(into pcm: inout Data) {
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        guard bytesPerFrame > 0 else { return }
        let frameCount = pcm.count / bytesPerFrame
        guard frameCount > 0, cursor / beatFrames < maxTicks else { return }
        let start = cursor
        pcm.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for f in 0..<frameCount {
                let position = start + f
                guard position / beatFrames < maxTicks else { break }
                let phase = position % beatFrames
                guard phase < tick.count else { continue }
                let add = tick[phase]
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
}
