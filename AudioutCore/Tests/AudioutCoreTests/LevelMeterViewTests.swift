// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import Testing
@testable import AudioutSharedUI

/// Unit coverage for ``LevelMeterView/ballisticsStep(displayed:target:)`` (task
/// T8) — the pure ease function the live display-link loop calls every frame.
/// Asserted standalone with no view/display link involved, mirroring
/// `NativeCaptureCoordinatorTests`' pure-function style for `rmsOfS16LE`.
@Suite struct LevelMeterViewTests {

    // MARK: Perceptual dB height mapping (the "levels look extremely low" fix)

    @Test func displayHeightIsPerceptualNotLinear() {
        // Endpoints + floor.
        #expect(abs(LevelMeterView.displayHeight(forLevel: 0.0) - 0.0) <= 0.001)
        #expect(abs(LevelMeterView.displayHeight(forLevel: 1.0) - 1.0) <= 0.001)
        // Silence-ish and sub-floor levels show no fill.
        #expect(abs(LevelMeterView.displayHeight(forLevel: 0.0005) - 0.0) <= 0.001) // ≈ −66 dBFS

        // The whole point: typical program RMS (~0.05 ≈ −26 dBFS) must fill a
        // HEALTHY chunk of the meter, not the ~5% a linear map gave it.
        let normal = LevelMeterView.displayHeight(forLevel: 0.05)
        #expect(normal > 0.4, "normal audio should fill a visible portion, not a sliver")
        #expect(normal < 0.9)
        #expect(normal > 0.05 * 5, "must be well above the old linear fill (0.05)")

        // Monotonic across the audible range.
        var prev = LevelMeterView.displayHeight(forLevel: 0.001)
        for milli in stride(from: 2, through: 1000, by: 20) {
            let h = LevelMeterView.displayHeight(forLevel: CGFloat(milli) / 1000.0)
            #expect(h >= prev)
            prev = h
        }
    }

    // MARK: Attack is faster than decay

    @Test func attackStepIsLargerThanDecayStep() {
        // Same distance-to-target (0.5) on both sides of `displayed`: a rise
        // from 0.25 toward 1.0 and a fall from 0.75 toward 0.0.
        let rising = LevelMeterView.ballisticsStep(displayed: 0.25, target: 1.0) - 0.25
        let falling = 0.75 - LevelMeterView.ballisticsStep(displayed: 0.75, target: 0.0)
        #expect(rising > falling,
                "the attack coefficient (rising) must produce a bigger step than decay (falling)")
    }

    // MARK: Monotone convergence toward target

    @Test func repeatedStepsMonotonicallyConvergeUpwardToTarget() {
        var displayed: CGFloat = 0
        let target: CGFloat = 1
        var previous: CGFloat = -1
        for _ in 0..<200 {
            displayed = LevelMeterView.ballisticsStep(displayed: displayed, target: target)
            #expect(displayed >= previous, "each attack step must move toward, never past, target")
            #expect(displayed <= target, "an ease step never overshoots the target")
            previous = displayed
        }
        #expect(abs(displayed - target) <= 0.001, "200 steps is enough to converge on the target")
    }

    @Test func repeatedStepsMonotonicallyConvergeDownwardToTarget() {
        var displayed: CGFloat = 1
        let target: CGFloat = 0
        var previous: CGFloat = 2
        for _ in 0..<200 {
            displayed = LevelMeterView.ballisticsStep(displayed: displayed, target: target)
            #expect(displayed <= previous, "each decay step must move toward, never past, target")
            #expect(displayed >= target, "an ease step never overshoots the target")
            previous = displayed
        }
        #expect(abs(displayed - target) <= 0.001, "200 steps is enough to converge on the target")
    }

    // MARK: Idle-stop condition

    @Test func displayedAtRestWithZeroTargetStaysAtRest() {
        // The idle-stop condition the display link's `tick()` checks: displayed
        // ~0 and target 0 ⇒ the step must not push `displayed` away from rest
        // (verifies the ease function itself has a fixed point at zero, which is
        // what makes the display-link teardown safe).
        let displayed: CGFloat = 0
        let target: CGFloat = 0
        #expect(LevelMeterView.ballisticsStep(displayed: displayed, target: target) == 0,
                "zero displayed easing toward a zero target must stay exactly at rest")
    }

    @Test func nearRestDisplayedWithZeroTargetStaysBelowRestEpsilon() {
        // A displayed value already inside the documented rest epsilon (0.001)
        // must decay to something still at/under that epsilon, not bounce back up.
        let displayed: CGFloat = 0.0005
        let stepped = LevelMeterView.ballisticsStep(displayed: displayed, target: 0)
        #expect(stepped <= displayed, "decaying toward zero never increases displayed")
        #expect(stepped >= 0, "the step never goes negative")
    }
}
