import AVFoundation

// ============================================================================
// T4: shared click+tone source. ONE agreed PCM format that every per-device
// engine (T5) attaches to and plays from, so all outputs are comparable —
// same sample rate, channel count, and buffer content — with only the AVAudio-
// Engine-per-device routing differing between them.
//
// Two purposes:
//   - CLICK: a short impulse repeating ~1/sec, for hearing inter-speaker
//     delay/alignment by ear (a "metronome").
//   - TONE: a sustained 440 Hz sine, for hearing clock-rate drift between
//     devices as slow beating/phasing over tens of seconds.
// ============================================================================

enum ToneSourceMode {
    case click
    case tone
}

enum ToneSource {

    // MARK: - Shared format (single source of truth for every engine)

    /// Sample rate every per-device AVAudioEngine, buffer, and connection format
    /// must agree on. 44.1 kHz stereo, non-interleaved Float32 — the layout
    /// AVAudioEngine's own render format uses internally, so no extra
    /// conversion node is needed anywhere in the graph.
    static let sampleRate: Double = 44_100

    static let channelCount: AVAudioChannelCount = 2

    /// Non-interleaved Float32 — AVAudioEngine's native internal format.
    static let format: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        ) else {
            fatalError("ToneSource: failed to construct shared AVAudioFormat")
        }
        return fmt
    }()

    // Click cadence and tone pitch — spike constants, not configurable.
    static let clickIntervalSeconds: Double = 1.0
    static let clickDurationSeconds: Double = 0.008 // ~8ms audible tick
    static let toneFrequencyHz: Double = 440.0

    // MARK: - Buffer construction

    /// One loop period of the click metronome: a single short impulse at the
    /// start of a `clickIntervalSeconds`-long buffer of silence. Looping this
    /// buffer end-to-end reproduces a steady ~1/sec click.
    static func makeClickBuffer() -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * clickIntervalSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("ToneSource: failed to allocate click buffer")
        }
        buffer.frameLength = frameCount

        let clickFrames = Int(sampleRate * clickDurationSeconds)
        guard let channels = buffer.floatChannelData else {
            fatalError("ToneSource: click buffer has no float channel data")
        }
        let channelCount = Int(format.channelCount)

        for ch in 0..<channelCount {
            let data = channels[ch]
            // Everything defaults to zero (AVAudioPCMBuffer zero-fills on alloc).
            // Write a short raised-cosine-windowed burst of a fixed pitch so the
            // click has an audible timbre rather than a pure zero-crossing pop.
            for frame in 0..<clickFrames {
                let t = Double(frame) / sampleRate
                let window = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(frame) / Double(max(clickFrames - 1, 1))))
                let carrier = sin(2.0 * Double.pi * 1000.0 * t) // 1kHz tick tone
                data[frame] = Float(window * carrier * 0.8)
            }
        }
        return buffer
    }

    /// One loop period of the sustained tone: exactly one full cycle count of
    /// `toneFrequencyHz` at `sampleRate`, so looping this buffer end-to-end is
    /// phase-continuous (no click/discontinuity at the loop seam).
    static func makeToneBuffer() -> AVAudioPCMBuffer {
        // Choose a buffer length that's an integer number of full cycles, close
        // to ~1 second, so the loop seam lands exactly on a zero-crossing.
        let cyclesPerSecond = toneFrequencyHz
        let wholeCycles = max(1, Int(cyclesPerSecond.rounded()))
        let frameCount = AVAudioFrameCount((Double(wholeCycles) / toneFrequencyHz * sampleRate).rounded())

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("ToneSource: failed to allocate tone buffer")
        }
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else {
            fatalError("ToneSource: tone buffer has no float channel data")
        }
        let channelCount = Int(format.channelCount)
        let amplitude: Double = 0.5

        for ch in 0..<channelCount {
            let data = channels[ch]
            for frame in 0..<Int(frameCount) {
                let t = Double(frame) / sampleRate
                data[frame] = Float(amplitude * sin(2.0 * Double.pi * toneFrequencyHz * t))
            }
        }
        return buffer
    }

    /// Produce the loopable buffer for a given mode. Each call allocates a
    /// fresh buffer — callers scheduling on multiple player nodes should call
    /// this once per node (AVAudioPlayerNode does not support sharing a single
    /// AVAudioPCMBuffer instance's scheduling state across nodes safely for
    /// looped playback, though the underlying sample data could be shared by
    /// a smarter implementation; this spike keeps it simple).
    static func makeBuffer(for mode: ToneSourceMode) -> AVAudioPCMBuffer {
        switch mode {
        case .click:
            return makeClickBuffer()
        case .tone:
            return makeToneBuffer()
        }
    }
}
