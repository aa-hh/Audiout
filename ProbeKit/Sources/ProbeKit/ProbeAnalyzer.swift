// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like `SyncProbeCorrelator` beside it: MIT, not GPL,
// and nothing GPL-derived may move in. See that file's note before editing
// either.

import Foundation

/// What one probe recording measured. RAW measurement only — the Mac owns what
/// a given offset means for a device's trim.
public struct ProbeAnalysis: Sendable, Equatable {
    /// Target arrival minus reference arrival, ms. Positive = the target
    /// sounded LATE, i.e. its applied latency is this much too small.
    public let offsetMs: Double
    /// The weaker of the two arrivals' peak-to-sidelobe ratios — the
    /// measurement's own confidence statement. Pure noise scores ~1; a real
    /// arrival at sane SNR runs to the hundreds.
    public let confidence: Double
}

public enum ProbeAnalysisError: Error, Sendable {
    /// The capture is shorter than a single sweep, so there is nothing a
    /// matched filter could even look for. A setup fault, not an acoustic one.
    case recordingTooShort
    /// One or both sweeps were not found convincingly. The honest outcome of a
    /// room too loud, a speaker too quiet, or a run that was torn down early.
    case probeNotFound
}

/// Recovers a target speaker's alignment error from a phone recording of the
/// two simultaneous sweep probes the Mac stages.
///
/// This is the Mac's own mic-probe measurement (`MicProbeSession.analyze`,
/// roadmap 064) with the phone standing in for the built-in microphone. The
/// technique is unchanged and deliberately so: one microphone hears both
/// speakers, so the capture latency and the probes' shared scheduled start are
/// common to both arrivals and cancel in the DIFFERENCE. What survives is the
/// per-speaker output latency difference plus the speakers' distance
/// asymmetry to the mic.
///
/// **What the phone changes is that the microphone moves.** The Mac's mic sits
/// where the Mac sits; a phone is carried, and distance asymmetry costs about
/// 2.9 ms per metre. Held at the listening position that is the measurement you
/// actually want — sync at the ears, not sync at the laptop. Held beside one
/// speaker it is a confident wrong answer, and nothing in the signal can tell
/// the two apart. Placement is the caller's problem to state plainly to the
/// user; this package cannot detect it.
///
/// The sweeps themselves are recreated locally at the capture's own sample
/// rate, so the phone needs nothing from the Mac but the knowledge that a run
/// is under way — no reference audio crosses the network.
public struct ProbeAnalyzer: Sendable {

    /// The staged sweep's length. **Hand-copy of
    /// `AlignmentTickInjector.probeSweepSeconds`** — the Mac plays a sweep of
    /// exactly this duration and this analyzer matches against one it renders
    /// itself, so the two constants must move together. Fixed, and not an
    /// init parameter on purpose: a caller that could pass its own length
    /// could quietly diverge from what the Mac stages, and the failure is a
    /// confident wrong number rather than a refusal.
    public static let sweepSeconds = 1.0

    /// Ambient weighting needs at least this much probe-free lead-in to
    /// describe anything; below it the slice is noise about noise.
    static let minimumAmbientSeconds = 0.3

    private let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Measure one capture.
    ///
    /// `ambientEndSample` marks where the probe-free lead-in ends — the
    /// capture up to just before the sweeps entered the Mac's feed. Air can
    /// only lag the feed, so that slice is provably probe-free. Pass 0 when
    /// the boundary is unknown; the measurement then runs unweighted, which is
    /// the same path a useless ambient slice falls back to anyway.
    ///
    /// The SNR weighting gets first go, but its failure is never the run's:
    /// during a wizard entry that lead-in slice legitimately carries the tail
    /// of the user's music still draining through the sinks' ~2 s delay (live
    /// finding, 2026-08-28: every probe measured fine acoustically and was then
    /// refused, because weighting by the music's spectrum crushed exactly the
    /// sweep band — for noise that was gone by sweep time). Weighting is an
    /// optimization for noise that is genuinely stationary; when it finds
    /// nothing, the plain matched filter decides.
    public func analyze(recording: [Float], ambientEndSample: Int = 0) throws -> ProbeAnalysis {
        guard sampleRate > 0 else { throw ProbeAnalysisError.recordingTooShort }
        let sweepFrames = Int((Self.sweepSeconds * sampleRate).rounded())
        guard recording.count > sweepFrames else { throw ProbeAnalysisError.recordingTooShort }

        // DOWN is the reference lane, UP the Bluetooth/target lane — the same
        // assignment the Mac stages. On the Mac the high band went to the far,
        // quiet speaker because the Mac's own driver is inches from its mic;
        // at the listening position that reasoning no longer applies, but the
        // assignment is not ours to revisit. The Mac chooses which sweep goes
        // to which fan-out, and swapping the labels here would silently
        // reverse the sign of every measurement.
        let reference = SyncProbe.samples(.downSweep(sampleRate: sampleRate,
                                                     duration: Self.sweepSeconds))
        let target = SyncProbe.samples(.upSweep(sampleRate: sampleRate,
                                                duration: Self.sweepSeconds))
        let correlator = SyncProbeCorrelator(sampleRate: sampleRate)

        let ambientFloor = Int(Self.minimumAmbientSeconds * sampleRate)
        let ambient: [Float]? = ambientEndSample > ambientFloor
            ? Array(recording[0..<min(ambientEndSample, recording.count)])
            : nil

        let measurement = ambient.flatMap {
            correlator.relativeOffset(probeA: reference, probeB: target,
                                      recording: recording, ambientNoise: $0)
        } ?? correlator.relativeOffset(probeA: reference, probeB: target,
                                       recording: recording, ambientNoise: nil)

        guard let m = measurement else { throw ProbeAnalysisError.probeNotFound }
        return ProbeAnalysis(
            offsetMs: m.offsetSeconds * 1000,
            confidence: min(m.arrivalA.peakToSidelobe, m.arrivalB.peakToSidelobe))
    }
}
