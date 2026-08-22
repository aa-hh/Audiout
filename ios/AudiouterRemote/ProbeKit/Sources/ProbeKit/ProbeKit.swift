// SPIKE STUB — replaced by dsp track at merge
//
// API surface only, so the app target (Track C "iosui") and its debug probe
// screen compile and can be wired end-to-end before Track B's real matched-
// filter analyzer lands. Every type/case/field name and shape here is BINDING
// per dev/notes/bt-autocal-spike-spec.md's "ProbeKit API" block — Track B
// implements the real bodies and, at reconciliation, replaces this file
// (and this whole Sources/ directory) wholesale. Nothing here should ever be
// treated as a real measurement.

import Foundation

/// The alternating-mute tick pattern's shape (preamble + REF/TGT blocks),
/// shared so the analyzer knows what it's looking for. `.spike` matches the
/// BINDING constants in the spec exactly.
public struct ProbePattern: Sendable {
    public let beatPeriodSeconds: Double
    public let ticksPerBlock: Int
    public let gapBeats: Int
    public let repetitions: Int

    public init(beatPeriodSeconds: Double, ticksPerBlock: Int, gapBeats: Int, repetitions: Int) {
        self.beatPeriodSeconds = beatPeriodSeconds
        self.ticksPerBlock = ticksPerBlock
        self.gapBeats = gapBeats
        self.repetitions = repetitions
    }

    /// 72 BPM ⇒ beat period 60/72 s, 6 ticks/block, 2-beat gaps, 3 repetitions.
    public static let spike = ProbePattern(
        beatPeriodSeconds: 60.0 / 72.0,
        ticksPerBlock: 6,
        gapBeats: 2,
        repetitions: 3
    )
}

/// A completed measurement: the target device's timing vs the reference.
public struct ProbeAnalysis: Sendable {
    /// Positive = target sounds LATE relative to the reference.
    public let offsetMs: Double
    public let spreadMs: Double
    public let usedPairs: Int
    public let confident: Bool

    public init(offsetMs: Double, spreadMs: Double, usedPairs: Int, confident: Bool) {
        self.offsetMs = offsetMs
        self.spreadMs = spreadMs
        self.usedPairs = usedPairs
        self.confident = confident
    }
}

/// Why `ProbeAnalyzer.analyze` couldn't produce a measurement.
public enum ProbeAnalysisError: Error, Sendable {
    case noTicksDetected
    case patternMismatch(detail: String)
    case insufficientPairs(found: Int)
}

/// Recovers the target-vs-reference timing offset from a phone recording of
/// the alternating-mute tick probe (matched filter + PHAT whitening, per the
/// spec's "Measurement math" section). Stub always throws — no recording
/// this build ever accepts is real audio it can analyze.
public struct ProbeAnalyzer: Sendable {
    private let sampleRate: Double
    private let pattern: ProbePattern

    public init(sampleRate: Double, pattern: ProbePattern) {
        self.sampleRate = sampleRate
        self.pattern = pattern
    }

    public func analyze(recording: [Float]) throws -> ProbeAnalysis {
        throw ProbeAnalysisError.noTicksDetected
    }
}
