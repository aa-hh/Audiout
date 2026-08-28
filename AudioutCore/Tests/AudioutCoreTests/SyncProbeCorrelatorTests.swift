// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design, like the file under test: no GPL SPDX header.

import Foundation
import Testing
@testable import AudioutCore

/// The matched filter behind mic-probe calibration: does it find a probe's
/// arrival to a fraction of a sample, tell two simultaneous probes apart,
/// survive noise and echoes, and refuse to answer when no probe is there.
/// Every acoustic scene here is synthetic — arrivals are rendered
/// analytically at fractional delays, so the expected answer is exact by
/// construction.
@Suite struct SyncProbeCorrelatorTests {

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

    // MARK: scene construction

    /// A probe landing in the recording at a (possibly fractional) sample
    /// delay, scaled by `gain`.
    private struct PlacedProbe {
        var design: SyncProbe.SweepDesign
        var delaySamples: Double
        var gain: Double
    }

    /// Renders a mic "recording": each placed probe evaluated analytically at
    /// its fractional delay, plus optional white noise and a hum tone.
    private func renderScene(length: Int, sampleRate: Double,
                             probes: [PlacedProbe],
                             noiseRMS: Double = 0, humHz: Double = 0,
                             humAmplitude: Double = 0,
                             seed: UInt64 = 7) -> [Float] {
        var rng = SeededRNG(seed: seed)
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var sample = 0.0
            for probe in probes {
                let t = (Double(i) - probe.delaySamples) / sampleRate
                sample += probe.gain * SyncProbe.value(probe.design, at: t)
            }
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

    /// Small, fast scene: 8 kHz clock, 200–3000 Hz sweeps.
    private static let fastRate = 8_000.0
    private static func fastUp(duration: Double = 0.5) -> SyncProbe.SweepDesign {
        SyncProbe.SweepDesign(sampleRate: fastRate, startHz: 200, endHz: 3_000,
                              duration: duration, fadeDuration: 0.01)
    }
    private static func fastDown(duration: Double = 0.5) -> SyncProbe.SweepDesign {
        SyncProbe.SweepDesign(sampleRate: fastRate, startHz: 3_000, endHz: 200,
                              duration: duration, fadeDuration: 0.01)
    }

    // MARK: synthesis

    @Test func sweepSamplesMatchTheAnalyticFormAndStayBounded() {
        let design = Self.fastUp()
        let samples = SyncProbe.samples(design)
        #expect(samples.count == 4_000, "0.5 s at 8 kHz is 4000 samples")
        for (i, s) in samples.enumerated() {
            #expect(abs(s) <= 1.0001, "a constant-amplitude sweep never clips")
            let analytic = Float(SyncProbe.value(design, at: Double(i) / design.sampleRate))
            #expect(s == analytic, "samples(_:) is value(_:at:) on the sample grid")
        }
        #expect(abs(samples[0]) < 1e-6 && abs(samples[samples.count - 1]) < 0.05,
                "the fades take the ends to (near) zero — no click on air")
    }

    // MARK: single-probe arrival

    @Test func integerDelayIsRecoveredToWellUnderASample() throws {
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [PlacedProbe(design: Self.fastUp(),
                                                   delaySamples: 400, gain: 0.8)])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let arrival = try #require(correlator.arrival(of: up, in: rec),
                                   "a clean, loud probe must be found")
        #expect(abs(arrival.sampleOffset - 400) < 0.1,
                "clean integer-sample arrival lands on the sample: got \(arrival.sampleOffset)")
        #expect(arrival.peakToSidelobe > 10,
                "a clean arrival is confident, not borderline: PSR \(arrival.peakToSidelobe)")
    }

    @Test func fractionalDelayIsResolvedSubSample() throws {
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [PlacedProbe(design: Self.fastUp(),
                                                   delaySamples: 400.37, gain: 0.8)])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let arrival = try #require(correlator.arrival(of: up, in: rec))
        #expect(abs(arrival.sampleOffset - 400.37) < 0.35,
                "parabolic interpolation resolves a fractional arrival: got \(arrival.sampleOffset)")
    }

    @Test func aWeakEchoDoesNotStealTheArrivalFromTheDirectPath() throws {
        // Direct path plus a −6 dB reflection 15 ms later — the everyday room.
        let up = SyncProbe.samples(Self.fastUp())
        let echoDelay = 400.0 + 0.015 * Self.fastRate
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [
                                PlacedProbe(design: Self.fastUp(), delaySamples: 400, gain: 0.8),
                                PlacedProbe(design: Self.fastUp(), delaySamples: echoDelay, gain: 0.4),
                              ])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let arrival = try #require(correlator.arrival(of: up, in: rec))
        #expect(abs(arrival.sampleOffset - 400) < 0.5,
                "the stronger direct path wins over its echo: got \(arrival.sampleOffset)")
    }

    // MARK: refusal

    @Test func pureNoiseYieldsNoArrival() {
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [], noiseRMS: 0.3)
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        #expect(correlator.arrival(of: up, in: rec) == nil,
                "no probe in the room means no answer — never a confident hallucination")
    }

    @Test func theWrongProbeIsNotMistakenForTheRightOne() {
        // Only the DOWN sweep is in the air; asking for the UP sweep must fail.
        // This is the orthogonality that lets both speakers play at once.
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [PlacedProbe(design: Self.fastDown(),
                                                   delaySamples: 400, gain: 0.8)])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        #expect(correlator.arrival(of: up, in: rec) == nil,
                "an up-sweep matched filter must not fire on a down sweep")
    }

    @Test func degenerateInputsReturnNilNotNonsense() {
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let up = SyncProbe.samples(Self.fastUp())
        #expect(correlator.arrival(of: up, in: []) == nil)
        #expect(correlator.arrival(of: up, in: [0.1, 0.2]) == nil,
                "a recording shorter than the probe cannot contain it")
        #expect(correlator.arrival(of: [], in: up) == nil)
    }

    // MARK: two probes, one recording

    @Test func simultaneousUpAndDownProbesSeparateAndTheOffsetIsExact() throws {
        // Both speakers play at once, arrivals 333.5 samples apart, unequal
        // loudness — the shape of the real calibration moment.
        let up = SyncProbe.samples(Self.fastUp())
        let down = SyncProbe.samples(Self.fastDown())
        let rec = renderScene(length: 12_000, sampleRate: Self.fastRate,
                              probes: [
                                PlacedProbe(design: Self.fastUp(), delaySamples: 400.4, gain: 0.8),
                                PlacedProbe(design: Self.fastDown(), delaySamples: 733.9, gain: 0.4),
                              ],
                              noiseRMS: 0.02)
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let m = try #require(correlator.relativeOffset(probeA: up, probeB: down,
                                                       recording: rec))
        let expected = (733.9 - 400.4) / Self.fastRate
        #expect(abs(m.offsetSeconds - expected) < 0.5 / Self.fastRate,
                "the arrival difference is the measurement: got \(m.offsetSeconds * 1000) ms, wanted \(expected * 1000) ms")
        #expect(m.offsetSeconds > 0, "B arriving later reads positive by contract")
    }

    @Test func fullRateSceneDeliversWellUnderAMillisecond() throws {
        // The realistic calibration: 44.1 kHz, one-second production probes,
        // heavy white noise (probes ~13 dB below the noise per-sample), plus
        // a room echo on each arrival. Processing gain must carry it.
        let rate = 44_100.0
        let upDesign = SyncProbe.SweepDesign.upSweep(sampleRate: rate)
        let downDesign = SyncProbe.SweepDesign.downSweep(sampleRate: rate)
        let up = SyncProbe.samples(upDesign)
        let down = SyncProbe.samples(downDesign)
        let delayUp = 7_938.25    // 180.0 ms
        let delayDown = 8_269.0   // 187.5 ms → true Δ exactly 7.5 ms
        let rec = renderScene(length: 66_150, sampleRate: rate,
                              probes: [
                                PlacedProbe(design: upDesign, delaySamples: delayUp, gain: 0.05),
                                PlacedProbe(design: upDesign, delaySamples: delayUp + 620, gain: 0.02),
                                PlacedProbe(design: downDesign, delaySamples: delayDown, gain: 0.05),
                                PlacedProbe(design: downDesign, delaySamples: delayDown + 400, gain: 0.02),
                              ],
                              noiseRMS: 0.15)
        let correlator = SyncProbeCorrelator(sampleRate: rate)
        let m = try #require(correlator.relativeOffset(probeA: up, probeB: down,
                                                       recording: rec),
                             "quiet probes under loud noise are the design point")
        let expected = (delayDown - delayUp) / rate
        #expect(abs(m.offsetSeconds - expected) < 0.000_1,
                "blend-grade needs ±6 ms; the probe delivers sub-0.1 ms: got \(m.offsetSeconds * 1000) ms")
    }

    @Test func theTwoLaneBandsDoNotOverlap() {
        // The isolation between the lanes is their disjoint bands, not their
        // opposite sweep directions — see the note on `SyncProbe`. Overlap
        // them again and the loud lane's leakage buries the quiet one.
        let up = SyncProbe.SweepDesign.upSweep(sampleRate: 48_000)
        let down = SyncProbe.SweepDesign.downSweep(sampleRate: 48_000)
        let upBand = (min(up.startHz, up.endHz), max(up.startHz, up.endHz))
        let downBand = (min(down.startHz, down.endHz), max(down.startHz, down.endHz))
        #expect(upBand.0 > downBand.1,
                "the lanes must not share a hertz: up \(upBand), down \(downBand)")
        #expect(upBand.0 / downBand.1 >= 1.25,
                "abutting edges lose the isolation — keep a guard gap")
    }

    @Test func theQuietLaneIsFoundBesideALaneTwentyThreeDecibelsLouder() throws {
        // The live 2026-08-28 refusal, to scale. One mic, built into the Mac:
        // the Mac's own speakers arrived at amplitude 0.0395 and the Bluetooth
        // speaker across the room at 0.00268 — 23.4 dB down — over a room
        // noise floor of −71 dBFS. Both sweeps were plainly audible and every
        // run was refused, because with both lanes sharing 500 Hz–10 kHz the
        // loud lane's cross-correlation leakage stood ABOVE the quiet lane's
        // true peak. Nothing here is quiet in absolute terms; the imbalance
        // alone is the whole failure.
        let rate = 48_000.0
        let upDesign = SyncProbe.SweepDesign.upSweep(sampleRate: rate)
        let downDesign = SyncProbe.SweepDesign.downSweep(sampleRate: rate)
        let delayDown = 21_684.0   // 451.75 ms
        let delayUp = 20_590.0     // 428.958 ms → true Δ exactly −22.79 ms
        let rec = renderScene(length: 96_000, sampleRate: rate,
                              probes: [
                                PlacedProbe(design: downDesign, delaySamples: delayDown,
                                            gain: 0.0395),
                                PlacedProbe(design: downDesign, delaySamples: delayDown + 4_800,
                                            gain: 0.0135),
                                PlacedProbe(design: upDesign, delaySamples: delayUp,
                                            gain: 0.00268),
                                PlacedProbe(design: upDesign, delaySamples: delayUp + 4_800,
                                            gain: 0.00092),
                              ],
                              noiseRMS: 0.000_5)
        let correlator = SyncProbeCorrelator(sampleRate: rate)
        let m = try #require(
            correlator.relativeOffset(probeA: SyncProbe.samples(downDesign),
                                      probeB: SyncProbe.samples(upDesign),
                                      recording: rec),
            "a 23 dB quieter speaker is the ordinary geometry, not a bad capture")
        let expected = (delayUp - delayDown) / rate
        #expect(abs(m.offsetSeconds - expected) < 0.000_5,
                "got \(m.offsetSeconds * 1000) ms, wanted \(expected * 1000) ms")
        #expect(m.arrivalB.peakToSidelobe >= correlator.minPeakToSidelobe,
                "the quiet lane clears the shipping gate with margin, not barely: PSR \(m.arrivalB.peakToSidelobe)")
    }

    // MARK: noise weighting

    @Test func aLoudHumIsSurvivedWhenAmbientNoiseIsSupplied() throws {
        // A tonal interferer well above the probe's level, sitting inside the
        // probe band. The ambient lead-in lets the correlator discount that
        // bin instead of letting it vote at full weight.
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 12_000, sampleRate: Self.fastRate,
                              probes: [PlacedProbe(design: Self.fastUp(),
                                                   delaySamples: 2_400, gain: 0.1)],
                              noiseRMS: 0.02, humHz: 997, humAmplitude: 0.7)
        // The probe-free lead-in of the same scene is the ambient sample.
        let ambient = Array(rec[0..<2_000])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let weighted = try #require(correlator.arrival(of: up, in: rec,
                                                       ambientNoise: ambient),
                                    "with the noise spectrum known, the hum must not drown the probe")
        #expect(abs(weighted.sampleOffset - 2_400) < 0.5,
                "the arrival stays accurate under the hum: got \(weighted.sampleOffset)")

        if let unweighted = correlator.arrival(of: up, in: rec) {
            #expect(weighted.peakToSidelobe >= unweighted.peakToSidelobe,
                    "noise weighting never costs confidence on the scene it models")
        }
    }
}
