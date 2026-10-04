// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import ProbeKit

/// Finds each streamed probe in the microphone recording and reports how long
/// after its pts it sounded: `delay = targetDelay + c`.
enum MirrorMeasurement {

    /// The `MicProbeSession` acceptance floor for a correlation peak.
    private static let minConfidence = 20.0

    /// The 100 ms 3.2–10 kHz up-sweep, unscaled; the run applies the gain.
    static func probe(sampleRate: Double) -> [Float] {
        SyncProbe.samples(.upSweep(sampleRate: sampleRate, duration: 0.1))
    }

    /// The first probe found from its pts to `targetDelay + 1.5 s` after it is
    /// the anchor and fixes `c₀`; probes before it count as not found, and every
    /// later probe is searched ±0.4 s around
    /// `pts + targetDelay + c₀`, narrower than the period so a window holds one.
    static func arrivals(
        recording: [Float],
        recordingStartNanos: Int64,
        micRate: Double,
        probes: [(index: Int, ptsNanos: UInt64)],
        targetDelayMs: Int
    ) -> [(index: Int, delayMs: Double, confidence: Double)] {
        let sweep = probe(sampleRate: micRate)
        let correlator = SyncProbeCorrelator(sampleRate: micRate)
        let target = Int64(targetDelayMs) * 1_000_000
        let sorted = probes.sorted { $0.index < $1.index }

        /// Arrival in `[from, to)` nanoseconds, on CLOCK_MONOTONIC, if confident.
        func find(from: Int64, to: Int64) -> (nanos: Int64, confidence: Double)? {
            let start = max(0, Int(Double(from - recordingStartNanos) / 1e9 * micRate))
            let end = min(recording.count, Int(Double(to - recordingStartNanos) / 1e9 * micRate))
            guard end - start >= sweep.count,
                  let hit = correlator.arrival(of: sweep, in: Array(recording[start..<end])),
                  hit.peakToSidelobe >= minConfidence else { return nil }
            let nanos = recordingStartNanos + Int64((Double(start) + hit.sampleOffset) / micRate * 1e9)
            return (nanos, hit.peakToSidelobe)
        }

        guard let (at, first, anchor) = sorted.enumerated().lazy.compactMap({ i, probe in
            find(from: Int64(probe.ptsNanos), to: Int64(probe.ptsNanos) + target + 1_500_000_000)
                .map { (i, probe, $0) }
        }).first else {
            return []
        }
        let c0 = anchor.nanos - Int64(first.ptsNanos) - target
        var out = [(index: first.index, delayMs: Double(anchor.nanos - Int64(first.ptsNanos)) / 1e6,
                    confidence: anchor.confidence)]
        for probe in sorted.dropFirst(at + 1) {
            let expected = Int64(probe.ptsNanos) + target + c0
            guard let hit = find(from: expected - 400_000_000, to: expected + 400_000_000) else { continue }
            out.append((probe.index, Double(hit.nanos - Int64(probe.ptsNanos)) / 1e6, hit.confidence))
        }
        return out
    }

    static func summary(_ arrivals: [(index: Int, delayMs: Double, confidence: Double)], targetDelayMs: Int) -> String {
        guard !arrivals.isEmpty else { return "summary count=0" }
        let delays = arrivals.map(\.delayMs).sorted()
        let median = delays.count % 2 == 1
            ? delays[delays.count / 2]
            : (delays[delays.count / 2 - 1] + delays[delays.count / 2]) / 2
        let mean = delays.reduce(0, +) / Double(delays.count)
        let sd = (delays.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(delays.count)).squareRoot()
        return String(format: "summary count=%d median_ms=%.2f min_ms=%.2f max_ms=%.2f sd_ms=%.2f c_ms=%.2f",
                      delays.count, median, delays.first!, delays.last!, sd, median - Double(targetDelayMs))
    }
}
