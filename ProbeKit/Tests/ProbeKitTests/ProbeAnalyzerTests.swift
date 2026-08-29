// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like the files under test: MIT, not GPL.

import Foundation
import Testing
@testable import ProbeKit

/// The phone-side reduction of a probe capture to one number: does it recover
/// a known offset at the sample rates a phone actually hands us, does it keep
/// the sign the Mac expects, and does it refuse rather than guess.
///
/// Every scene here uses the SHIPPING sweep designs — the ones the Mac stages —
/// rather than the small fast sweeps `SyncProbeCorrelatorTests` uses to
/// exercise the filter itself. That is the point of this suite: it tests the
/// contract with the Mac, not the mathematics.
@Suite struct ProbeAnalyzerTests {

    /// SplitMix64 — a seed pins a whole synthetic scene, so a failure is
    /// reproducible rather than a mood.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Phones hand us 48 kHz most of the time and 44.1 kHz sometimes; nothing
    /// in the analyzer may assume either. 24 kHz keeps most scenes cheap while
    /// still clearing the 10 kHz top of the high band.
    private static let rate = 24_000.0
    private static let sweep = ProbeAnalyzer.sweepSeconds

    /// A capture with the reference (DOWN) and target (UP) sweeps landing at
    /// given fractional delays, over optional noise and hum.
    private func renderCapture(sampleRate: Double,
                               referenceDelay: Double,
                               targetDelay: Double,
                               referenceGain: Double = 0.5,
                               targetGain: Double = 0.5,
                               seconds: Double = 3,
                               noiseRMS: Double = 0,
                               humHz: Double = 0,
                               humAmplitude: Double = 0,
                               seed: UInt64 = 11) -> [Float] {
        let down = SyncProbe.SweepDesign.downSweep(sampleRate: sampleRate, duration: Self.sweep)
        let up = SyncProbe.SweepDesign.upSweep(sampleRate: sampleRate, duration: Self.sweep)
        var rng = SeededRNG(seed: seed)
        let length = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var sample = 0.0
            sample += referenceGain * SyncProbe.value(down, at: (Double(i) - referenceDelay) / sampleRate)
            sample += targetGain * SyncProbe.value(up, at: (Double(i) - targetDelay) / sampleRate)
            if noiseRMS > 0 {
                // Box–Muller: one Gaussian per sample.
                let u1 = Double.random(in: 1e-12..<1, using: &rng)
                let u2 = Double.random(in: 0..<1, using: &rng)
                sample += noiseRMS * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
            }
            if humAmplitude > 0 {
                sample += humAmplitude * sin(2 * .pi * humHz * Double(i) / sampleRate)
            }
            out[i] = Float(sample)
        }
        return out
    }

    // MARK: the measurement

    @Test func aKnownOffsetIsRecoveredInMilliseconds() throws {
        // Target 20 ms later than the reference.
        let lead = Self.rate * 0.5
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: lead,
                                    targetDelay: lead + Self.rate * 0.020)
        let analysis = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: capture)
        #expect(abs(analysis.offsetMs - 20) < 0.5,
                "a 20 ms lag must read as 20 ms: got \(analysis.offsetMs)")
        #expect(analysis.confidence > 10,
                "a clean two-lane capture is confident: \(analysis.confidence)")
    }

    @Test func theSignSaysTheTargetSoundedLate() throws {
        let lead = Self.rate * 0.5
        let late = try ProbeAnalyzer(sampleRate: Self.rate)
            .analyze(recording: renderCapture(sampleRate: Self.rate,
                                              referenceDelay: lead,
                                              targetDelay: lead + Self.rate * 0.015))
        let early = try ProbeAnalyzer(sampleRate: Self.rate)
            .analyze(recording: renderCapture(sampleRate: Self.rate,
                                              referenceDelay: lead,
                                              targetDelay: lead - Self.rate * 0.015))
        #expect(late.offsetMs > 0, "target after reference is POSITIVE — the Mac's convention")
        #expect(early.offsetMs < 0, "target before reference is negative")
        #expect(abs(late.offsetMs + early.offsetMs) < 0.5, "and the two are symmetric")
    }

    @Test func fortyFourPointOneKilohertzMeasuresTheSameOffset() throws {
        let rate = 44_100.0
        let lead = rate * 0.5
        let analysis = try ProbeAnalyzer(sampleRate: rate)
            .analyze(recording: renderCapture(sampleRate: rate,
                                              referenceDelay: lead,
                                              targetDelay: lead + rate * 0.020,
                                              seconds: 2.5))
        #expect(abs(analysis.offsetMs - 20) < 0.5,
                "the rate is a parameter, not an assumption: got \(analysis.offsetMs)")
    }

    /// The property that made disjoint bands worth the trouble: the phone sits
    /// somewhere, and "somewhere" is rarely equidistant.
    @Test func aQuietTargetIsFoundBesideALoudReference() throws {
        let lead = Self.rate * 0.5
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: lead,
                                    targetDelay: lead + Self.rate * 0.030,
                                    referenceGain: 0.7,
                                    targetGain: 0.05,   // ~23 dB down
                                    noiseRMS: 0.002)
        let analysis = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: capture)
        #expect(abs(analysis.offsetMs - 30) < 1.0,
                "the quiet lane shares no bins with the loud one: got \(analysis.offsetMs)")
    }

    @Test func aHumIsSurvivedWhenTheAmbientLeadInIsSupplied() throws {
        // Probes start at 1 s, so everything before that is provably probe-free.
        let lead = Self.rate * 1.0
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: lead,
                                    targetDelay: lead + Self.rate * 0.012,
                                    referenceGain: 0.25,
                                    targetGain: 0.25,
                                    seconds: 3.5,
                                    humHz: 700,
                                    humAmplitude: 0.5)
        let analysis = try ProbeAnalyzer(sampleRate: Self.rate)
            .analyze(recording: capture, ambientEndSample: Int(Self.rate * 0.9))
        #expect(abs(analysis.offsetMs - 12) < 1.0,
                "weighting discounts the hum's bins: got \(analysis.offsetMs)")
    }

    /// A lead-in too short to describe the room must not be handed to the
    /// weighting — it falls through to the plain matched filter instead.
    @Test func aUselessAmbientSliceStillMeasures() throws {
        let lead = Self.rate * 0.5
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: lead,
                                    targetDelay: lead + Self.rate * 0.020)
        let analysis = try ProbeAnalyzer(sampleRate: Self.rate)
            .analyze(recording: capture, ambientEndSample: Int(Self.rate * 0.1))
        #expect(abs(analysis.offsetMs - 20) < 0.5,
                "below the ambient floor the unweighted pass decides: got \(analysis.offsetMs)")
    }

    // MARK: refusal

    @Test func pureNoiseIsRefused() {
        var rng = SeededRNG(seed: 99)
        let noise = (0..<Int(Self.rate * 3)).map { _ -> Float in
            let u1 = Double.random(in: 1e-12..<1, using: &rng)
            let u2 = Double.random(in: 0..<1, using: &rng)
            return Float(0.1 * sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
        }
        #expect(throws: ProbeAnalysisError.probeNotFound) {
            _ = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: noise)
        }
    }

    /// Only ONE lane present is still a refusal: a measurement needs both
    /// arrivals, and half of one is not "best effort".
    @Test func aCaptureMissingTheTargetLaneIsRefused() {
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: Self.rate * 0.5,
                                    targetDelay: 0,
                                    targetGain: 0)
        #expect(throws: ProbeAnalysisError.probeNotFound) {
            _ = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: capture)
        }
    }

    @Test func aCaptureShorterThanOneSweepIsRefused() {
        let short = [Float](repeating: 0, count: Int(Self.rate * 0.5))
        #expect(throws: ProbeAnalysisError.recordingTooShort) {
            _ = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: short)
        }
    }

    // MARK: the contract with the Mac

    /// `AlignmentTickInjector.probeSweepSeconds` is 1.0 and this analyzer
    /// renders its references at `ProbeAnalyzer.sweepSeconds`. They are two
    /// copies of one constant; this pins ours so a drift is a red test rather
    /// than a confidently wrong number in the field.
    @Test func theSweepLengthMatchesTheMacsStagedProbe() {
        #expect(ProbeAnalyzer.sweepSeconds == 1.0,
                "hand-copy of AlignmentTickInjector.probeSweepSeconds")
    }

    /// The lane assignment is not ours to revisit — the Mac decides which
    /// sweep goes to which fan-out. Reading them the other way round flips
    /// every sign, so this pins which band belongs to which side.
    @Test func theReferenceLaneIsTheLowBandAndTheTargetLaneTheHigh() {
        let down = SyncProbe.SweepDesign.downSweep(sampleRate: Self.rate)
        let up = SyncProbe.SweepDesign.upSweep(sampleRate: Self.rate)
        #expect(down.startHz == 2_000 && down.endHz == 500, "reference lane sweeps down")
        #expect(up.startHz == 3_200 && up.endHz == 10_000, "target lane sweeps up")
        #expect(down.startHz < up.startHz, "and the bands stay disjoint, with a guard gap")
    }
}
