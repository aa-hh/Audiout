import XCTest
@testable import ProbeKit

/// The spike's verdict rests on these: synthetic probe recordings with a known
/// injected offset, and the analyzer recovering it.
final class ProbeAnalyzerTests: XCTestCase {

    /// The recovery tolerance the spike is judged on.
    private let toleranceMs = 1.0

    // MARK: Recovery

    /// Doubles as the SIGN test: target ticks arriving LATER than the grid
    /// predicts must come back POSITIVE. Track A's trim math depends on it.
    func testRecoversLateTargetAt48k() throws {
        let analysis = try analyze(offsetMs: 37.4, sampleRate: 48_000)
        XCTAssertGreaterThan(analysis.offsetMs, 0, "a late target must read positive")
        XCTAssertEqual(analysis.offsetMs, 37.4, accuracy: toleranceMs)
        XCTAssertTrue(analysis.confident)
        XCTAssertEqual(analysis.usedPairs, 3)
    }

    func testRecoversLateTargetAt44k1() throws {
        let analysis = try analyze(offsetMs: 37.4, sampleRate: 44_100)
        XCTAssertEqual(analysis.offsetMs, 37.4, accuracy: toleranceMs)
        XCTAssertTrue(analysis.confident)
    }

    func testRecoversEarlyTargetAt48k() throws {
        let analysis = try analyze(offsetMs: -112, sampleRate: 48_000)
        XCTAssertEqual(analysis.offsetMs, -112, accuracy: toleranceMs)
        XCTAssertTrue(analysis.confident)
    }

    func testRecoversEarlyTargetAt44k1() throws {
        let analysis = try analyze(offsetMs: -112, sampleRate: 44_100)
        XCTAssertEqual(analysis.offsetMs, -112, accuracy: toleranceMs)
        XCTAssertTrue(analysis.confident)
    }

    /// The discard-first-tick rule doing its job: every block opens with a tick
    /// the mute switch cut in half, and the measurement is unaffected.
    func testRecoversThroughClippedBlockBoundaryTicks() throws {
        let analysis = try analyze(offsetMs: 37.4, sampleRate: 48_000, clipped: true)
        XCTAssertEqual(analysis.offsetMs, 37.4, accuracy: toleranceMs)
        XCTAssertTrue(analysis.confident)
    }

    /// The two devices stand in different places, so they get different
    /// reflections — the one asymmetry that could BIAS the answer rather than
    /// just blur it, since nothing cancels between the two blocks. This is what
    /// the whitening is there for.
    func testDifferentReflectionsPerDeviceDoNotBiasTheAnswer() throws {
        var recording = SyntheticProbeRecording(sampleRate: 48_000)
        recording.targetOffsetMs = 37.4
        recording.targetReflection = .init(delaySeconds: 0.003, gain: 0.63)  // −4 dB, 3 ms
        let analysis = try ProbeAnalyzer(sampleRate: 48_000, pattern: .spike)
            .analyze(recording: recording.build())
        XCTAssertEqual(analysis.offsetMs, 37.4, accuracy: toleranceMs)
        XCTAssertTrue(analysis.confident)
    }

    // MARK: Refusals

    /// A target that never made a sound leaves only REF blocks, so no REF→TGT
    /// pair exists. Refuse rather than pair two references.
    func testSilentTargetHasNoPairs() {
        var recording = SyntheticProbeRecording(sampleRate: 48_000)
        recording.includeTarget = false
        XCTAssertThrowsError(try ProbeAnalyzer(sampleRate: 48_000, pattern: .spike)
            .analyze(recording: recording.build())) { error in
            guard case ProbeAnalysisError.insufficientPairs(let found) = error else {
                return XCTFail("expected insufficientPairs, got \(error)")
            }
            XCTAssertEqual(found, 0)
        }
    }

    func testNoiseWithoutTicksDetectsNothing() {
        var recording = SyntheticProbeRecording(sampleRate: 48_000)
        recording.includeTicks = false
        XCTAssertThrowsError(try ProbeAnalyzer(sampleRate: 48_000, pattern: .spike)
            .analyze(recording: recording.build())) { error in
            guard case ProbeAnalysisError.noTicksDetected = error else {
                return XCTFail("expected noTicksDetected, got \(error)")
            }
        }
    }

    // MARK: Helpers

    private func analyze(offsetMs: Double,
                         sampleRate: Double,
                         clipped: Bool = false) throws -> ProbeAnalysis {
        var recording = SyntheticProbeRecording(sampleRate: sampleRate)
        recording.targetOffsetMs = offsetMs
        recording.clipFirstTickOfEachBlock = clipped
        let analysis = try ProbeAnalyzer(sampleRate: sampleRate, pattern: .spike)
            .analyze(recording: recording.build())
        print(String(format: "injected %+.1f ms at %.0f Hz -> recovered %+.2f ms (spread %.2f ms, %d pairs, confident %@)",
                     offsetMs, sampleRate, analysis.offsetMs, analysis.spreadMs,
                     analysis.usedPairs, analysis.confident ? "yes" : "no"))
        return analysis
    }
}

final class CenteredRemainderTests: XCTestCase {
    func testWrapsToHalfOpenIntervalAroundZero() {
        let period = 60.0 / 72.0
        XCTAssertEqual(centeredRemainder(0.1, period), 0.1, accuracy: 1e-12)
        XCTAssertEqual(centeredRemainder(-0.1, period), -0.1, accuracy: 1e-12)
        // A target 0.8 s late is indistinguishable from one 33 ms early.
        XCTAssertEqual(centeredRemainder(0.8, period), 0.8 - period, accuracy: 1e-12)
        XCTAssertEqual(centeredRemainder(period / 2, period), period / 2, accuracy: 1e-12)
        XCTAssertEqual(centeredRemainder(-period / 2, period), period / 2, accuracy: 1e-12)
    }
}
