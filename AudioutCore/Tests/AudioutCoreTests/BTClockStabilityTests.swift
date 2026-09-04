// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing
@testable import AudioutCore

/// The clock-stability rule: what one device-clock sample a second means, and
/// when ten of them add up to a clock the Mac will trust.
@Suite struct BTClockStabilityTests {

    private let rate = 44_100.0

    /// A sample `t` seconds after the first, with the clock `offsetMs` ahead
    /// of where a perfect clock would be. The sample time starts well above
    /// zero so a restart has somewhere to go backwards to.
    private func observe(_ detector: inout BTClockStability, t: Double,
                         offsetMs: Double = 0) -> BTClockStability.Outcome {
        detector.observe(sampleTime: (100 + t + offsetMs / 1_000) * rate,
                         hostNanos: Int64(t * 1_000_000_000),
                         nominalRate: rate)
    }

    @Test func theFirstSampleOnlySetsTheBaseline() {
        var detector = BTClockStability()
        #expect(observe(&detector, t: 0) == .ignored)
        #expect(observe(&detector, t: 1) == .advanced)
        #expect(detector.stableForSeconds == 1)
    }

    @Test func aStepAboveTwoMillisecondsIsAJump() {
        var detector = BTClockStability()
        _ = observe(&detector, t: 0)
        _ = observe(&detector, t: 1)
        let outcome = observe(&detector, t: 2, offsetMs: 2.5)
        guard case .jumped(let magnitudeMs) = outcome else {
            Issue.record("expected a jump, got \(outcome)")
            return
        }
        #expect(abs(magnitudeMs - 2.5) < 0.01)
        #expect(detector.stableForSeconds == 0, "a jump starts the count over")
    }

    @Test func aStepOfOnePointNineMillisecondsIsDrift() {
        var detector = BTClockStability()
        _ = observe(&detector, t: 0)
        _ = observe(&detector, t: 1)
        #expect(observe(&detector, t: 2, offsetMs: 1.9) == .advanced)
        #expect(detector.stableForSeconds == 2)
    }

    /// The step is measured sample to sample, not against the baseline: a
    /// clock that drifted a little and then holds is steady.
    @Test func aHeldOffsetIsNotAJumpAgain() {
        var detector = BTClockStability()
        _ = observe(&detector, t: 0)
        _ = observe(&detector, t: 1, offsetMs: 1.5)
        #expect(observe(&detector, t: 2, offsetMs: 1.5) == .advanced)
    }

    @Test func aFrozenSampleHoldsTheCount() {
        var detector = BTClockStability()
        for t in 0...2 { _ = observe(&detector, t: Double(t)) }
        #expect(detector.stableForSeconds == 2)
        // The same sample time under a later host stamp: the device is idle.
        #expect(detector.observe(sampleTime: 102 * rate, hostNanos: 3_000_000_000,
                                 nominalRate: rate) == .frozen)
        #expect(detector.stableForSeconds == 2, "neither advanced nor reset")
    }

    /// After a freeze the first moving sample starts a new baseline: the
    /// clock stood still while host time ran, so measuring it against the
    /// old baseline would read the whole idle stretch as one huge jump.
    @Test func theFirstSampleAfterAFreezeRebaselinesInsteadOfJumping() {
        var detector = BTClockStability()
        for t in 0...2 { _ = observe(&detector, t: Double(t)) }
        #expect(detector.observe(sampleTime: 102 * rate, hostNanos: 3_000_000_000,
                                 nominalRate: rate) == .frozen)
        #expect(detector.observe(sampleTime: 102 * rate, hostNanos: 20_000_000_000,
                                 nominalRate: rate) == .frozen)
        // The clock resumes 18 s later from where it stood.
        #expect(detector.observe(sampleTime: 103 * rate, hostNanos: 21_000_000_000,
                                 nominalRate: rate) == .ignored)
        #expect(detector.stableForSeconds == 0, "a fresh baseline starts the count over")
        #expect(detector.observe(sampleTime: 104 * rate, hostNanos: 22_000_000_000,
                                 nominalRate: rate) == .advanced)
        #expect(detector.stableForSeconds == 1)
    }

    /// A step of a second or more is a clock whose origin moved, not a
    /// re-anchor: a lost baseline, never a jump to sum. Seen live as a sink
    /// rebuild that read as a 19 s jump.
    @Test func aStepOfASecondOrMoreIsALostBaselineNotAJump() {
        var detector = BTClockStability()
        for t in 0...2 { _ = observe(&detector, t: Double(t)) }
        #expect(observe(&detector, t: 3, offsetMs: 19_000) == .rebaselined)
        #expect(detector.stableForSeconds == 0)
        // Measured from the new origin, the clock is steady again.
        #expect(observe(&detector, t: 4, offsetMs: 19_000) == .advanced)
        #expect(detector.stableForSeconds == 1)
    }

    @Test func aBackwardsSampleRebaselines() {
        var detector = BTClockStability()
        for t in 0...5 { _ = observe(&detector, t: Double(t)) }
        #expect(detector.stableForSeconds == 5)
        #expect(detector.observe(sampleTime: 0.5 * rate, hostNanos: 6_000_000_000,
                                 nominalRate: rate) == .rebaselined)
        #expect(detector.stableForSeconds == 0)
        // The next sample is measured from the new baseline, not the old.
        #expect(detector.observe(sampleTime: 1.5 * rate, hostNanos: 7_000_000_000,
                                 nominalRate: rate) == .advanced)
        #expect(detector.stableForSeconds == 1)
    }

    @Test func tenSecondsOfAdvancingSamplesIsStable() {
        var detector = BTClockStability()
        for t in 0...9 { _ = observe(&detector, t: Double(t)) }
        #expect(!detector.isStable)
        #expect(observe(&detector, t: 10) == .advanced)
        #expect(detector.isStable)
    }

    @Test func aJumpAfterStableStartsTheCountOver() {
        var detector = BTClockStability()
        for t in 0...10 { _ = observe(&detector, t: Double(t)) }
        #expect(detector.isStable)
        _ = observe(&detector, t: 11, offsetMs: 40)
        #expect(!detector.isStable)
        #expect(detector.stableForSeconds == 0)
    }
}
