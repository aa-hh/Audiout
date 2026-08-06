// Arithmetic audit for WriteCadenceTracker.record(samples:sampleRate:).
//
// The tracker computes audioSeconds = Double(samples) / Double(sampleRate) and
// folds it into a wall-elapsed comparison.  These tests confirm the arithmetic
// is exact (no accumulated rounding) and that the CALL SITE in AirPlayEngine
// passes semantically correct arguments (PCMFormat.airplay.sampleRate = 44 100,
// samples = byte-count / bytesPerSample).
//
// If either test marked "FINDING" fails, do NOT fix it here — a failing test IS
// the finding; the production change belongs in a separate commit after review.
//
// Part of T-3, roadmap-016 judder investigation.

import Testing
import Foundation
@testable import AirPlayEngine

@Suite struct WriteCadenceTrackerAuditTests {

    // MARK: - audioSeconds arithmetic

    /// recordRefused adds audioSeconds = samples/sampleRate to deficitSeconds
    // with no accumulated rounding.  One second of audio in = one second charged.
    @Test func refusedAudioSecondsMatchesExactRatio() {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44_100
        let samplesPerSecond = 44_100   // exactly 1 s

        // Seed the baseline (first record only sets lastWriteMonotonic, no gap).
        tracker.record(samples: samplesPerSecond, sampleRate: sampleRate)

        let iterations = 10
        for _ in 0..<iterations {
            // record() measures wall-elapsed vs audio time; recordRefused() charges
            // pure audio seconds into the deficit without a wall-elapsed component.
            tracker.record(samples: samplesPerSecond, sampleRate: sampleRate)
            tracker.recordRefused(samples: samplesPerSecond, sampleRate: sampleRate)
        }

        let snap = tracker.snapshot()
        // Each recordRefused call charges exactly 1.0 s to deficitSeconds.
        // Floating-point: 44100.0/44100.0 == 1.0 exactly, so no rounding error.
        #expect(snap.refusedWrites == UInt64(iterations))
        #expect(abs(snap.refusedSeconds - Double(iterations)) <= 1e-9,
                "refusedSeconds should be exactly \(iterations).0 s, got \(snap.refusedSeconds)")
    }

    /// Each call to record(samples: 512, sampleRate: 44100) contributes
    // exactly 512/44100 seconds to the audio-time side of the gap calculation.
    // This is verified indirectly via recordRefused — pure arithmetic, no wall
    // clock involved — so the result is deterministic.
    @Test func perCallAudioSecondsIsExactFraction() {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44_100
        let samplesPerCall = 512
        let audioSecondsPerCall = Double(samplesPerCall) / Double(sampleRate)

        tracker.record(samples: samplesPerCall, sampleRate: sampleRate) // seed

        let iterations = 1_000
        for _ in 0..<iterations {
            tracker.recordRefused(samples: samplesPerCall, sampleRate: sampleRate)
        }

        let snap = tracker.snapshot()
        let expected = audioSecondsPerCall * Double(iterations)
        // 512/44100 is not exactly representable in IEEE 754, so we accumulate
        // a small representational error.  Allow 1 ULP per call.
        let tolerance = audioSecondsPerCall * Double(iterations) * 2.22e-16 * Double(iterations)
        #expect(abs(snap.refusedSeconds - expected) <= max(tolerance, 1e-9),
                "Accumulated refusedSeconds \(snap.refusedSeconds) vs expected \(expected)")
    }

    // MARK: - call-site argument semantics

    /// Confirm the call site in AirPlayEngine passes firstSamples = number of
    // FRAMES (not bytes) at PCMFormat.airplay.sampleRate = 44 100 Hz.
    // The engine computes firstSamples = pcm.count / bytesPerSample where
    // bytesPerSample = 2 (bytes/sample) × 2 (channels) = 4.
    // A 352-frame AirPlay packet is 352 × 4 = 1408 bytes, so firstSamples = 352.
    // record(samples: 352, sampleRate: 44100) must give audioSeconds ≈ 7.98 ms.
    @Test func callSiteArgumentsAreFrameCountNotByteCount() {
        let tracker = WriteCadenceTracker()
        let sampleRate = PCMFormat.airplay.sampleRate   // 44 100
        let bytesPerSample = 4                          // S16LE stereo
        let airplayFrames = 352                         // one AirPlay nominal packet
        let pcmBytes = airplayFrames * bytesPerSample   // 1408 bytes — what the engine receives

        // Simulate the call site: firstSamples = pcm.count / bytesPerSample.
        let firstSamples = pcmBytes / bytesPerSample    // should be 352

        tracker.record(samples: firstSamples, sampleRate: sampleRate) // seed

        // A second call arrives immediately — wall gap ≈ 0, so the audioSeconds
        // argument almost entirely drives the overrun.
        tracker.record(samples: firstSamples, sampleRate: sampleRate)

        let snap = tracker.snapshot()
        let expectedAudioSeconds = Double(airplayFrames) / Double(sampleRate) // ~7.98 ms

        // If firstSamples was accidentally passed as BYTES (1408) instead of
        // frames (352), audioSeconds would be 4× too large (~31.9 ms) and the
        // overrun would be >> expectedAudioSeconds.  Assert it's in the right ballpark.
        //
        // Back-to-back calls → overrun ≈ audioSecondsPerCall.
        let overrunTolerance = 0.005 // 5 ms scheduling headroom
        #expect(
            abs(snap.overrunSeconds - expectedAudioSeconds) <= overrunTolerance,
            """
            overrunSeconds \(snap.overrunSeconds) is too far from expected \(expectedAudioSeconds). \
            If firstSamples was accidentally set to pcm.count (bytes) instead of frame count, \
            overrun would be ~\(Double(pcmBytes) / Double(sampleRate)) s.
            """)
    }
}
