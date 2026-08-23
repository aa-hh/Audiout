// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
import AudiouterSharedUI

/// `AlignmentStageView`: two lights riding a wire = the ends of the run's
/// credible interval, windowed onto a candidate range by the confidence
/// LADDER — one settled look per rung, with hysteresis on the boundaries and
/// an authored transition between them. These are pure geometry/model
/// assertions against the view's test seams — no popover harness, no window
/// ever ordered on screen.
@MainActor
@Suite struct AlignmentStageViewTests {

    /// A stage sized like it would be in the wizard window, laid out headless.
    private func makeStage() -> AlignmentStageView {
        let stage = AlignmentStageView()
        stage.setFrameSize(NSSize(width: 504, height: AlignmentStageView.stageHeight))
        stage.layoutSubtreeIfNeeded()
        return stage
    }

    private let range = -500.0...500.0

    private func span(_ display: ClosedRange<Double>) -> Double {
        display.upperBound - display.lowerBound
    }

    /// A symmetric interval with the given 95% credible half-width.
    private func interval(halfWidth: Double) -> ClosedRange<Double> {
        -halfWidth...halfWidth
    }

    // MARK: (a) State mapping

    @Test func questionStateOrdersTargetBeforeReferenceInsideTheFrame() {
        let stage = makeStage()
        stage.apply(.question(intervalMs: 100...160, range: range), animated: false)

        let centres = stage.test_lightCentres
        #expect(centres.target.x < centres.reference.x,
                "the target (interval's low end) sits left of the reference (high end)")
        #expect(centres.target.x >= 0 && centres.target.x <= stage.bounds.width,
                "the target light stays inside the frame")
        #expect(centres.reference.x >= 0 && centres.reference.x <= stage.bounds.width,
                "the reference light stays inside the frame")
    }

    @Test func listeningStateFusesTheLights() {
        let stage = makeStage()
        stage.apply(.listening(valueMs: 40, range: range), animated: false)

        let centres = stage.test_lightCentres
        #expect(abs(centres.target.x - centres.reference.x) < 0.01,
                "listening fuses the two lights to one point")
        #expect(stage.test_rung == .fused, "the listening state IS the fused rung")
    }

    @Test func lockedStateFusesTheLights() {
        let stage = makeStage()
        stage.apply(.locked(valueMs: 40, range: range), animated: false)

        let centres = stage.test_lightCentres
        #expect(abs(centres.target.x - centres.reference.x) < 0.01,
                "locked fuses the two lights to one point")
        #expect(stage.test_rung == .locked)
    }

    /// The lock's thesis on screen: neither voice wins — the ring is warm
    /// white, not the target's green surviving alone.
    @Test func lockedRingIsFuseWhiteNotTheTargetsGreen() throws {
        let stage = makeStage()
        stage.apply(.question(intervalMs: 30...50, range: range), animated: false)
        let live = try #require(stage.test_targetRingColor?.usingColorSpace(.sRGB))
        stage.apply(.locked(valueMs: 40, range: range), animated: false)
        let locked = try #require(stage.test_targetRingColor?.usingColorSpace(.sRGB))
        let fuse = try #require(Tokens.Color.fuseWhite.usingColorSpace(.sRGB))

        #expect(live.greenComponent > 0.9 && live.redComponent < 0.3, "a question ring is Sync Green")
        #expect(abs(locked.redComponent - fuse.redComponent) < 0.02
                    && abs(locked.greenComponent - fuse.greenComponent) < 0.02
                    && abs(locked.blueComponent - fuse.blueComponent) < 0.02,
                "the locked ring is stamped fuseWhite, got \(locked)")
    }

    @Test func dormantKeepsThePreviousDisplayRange() {
        let stage = makeStage()
        stage.apply(.question(intervalMs: 100...160, range: range), animated: false)
        let beforeDormant = stage.test_displayRange

        stage.apply(.dormant, animated: false)

        #expect(stage.test_displayRange == beforeDormant,
                "going dormant must not re-window the wire — it freezes where it was")
        #expect(stage.test_rung == .dormant)
        #expect(stage.test_lastTransition == .bowOut, "a bow-out is the dormant edge")
    }

    // MARK: (b) The ladder — rung resolution

    @Test func rungResolvesAcrossTheEnterBoundaries() {
        // Each case starts from a fresh stage, so nothing is being HELD: this
        // is the enter boundary alone (§5's 250 / 60 / 12).
        let cases: [(halfWidth: Double, rung: AlignmentStageView.Rung)] = [
            (400, .open),
            (251, .open),
            (BTAlignmentWizardSession.fineTempoHalfWidthMs, .closing),
            (61, .closing),
            (60, .near),
            (13, .near),
            (12, .threshold),
            (1, .threshold),
        ]
        for expectation in cases {
            let stage = makeStage()
            stage.apply(.question(intervalMs: interval(halfWidth: expectation.halfWidth),
                                  range: range), animated: false)
            #expect(stage.test_rung == expectation.rung,
                    "half-width \(expectation.halfWidth) belongs to \(expectation.rung)")
        }
    }

    @Test func nonQuestionStatesOwnTheirRungOutright() {
        let stage = makeStage()
        stage.apply(.armed(range: range), animated: false)
        #expect(stage.test_rung == .armed)
        stage.apply(.listening(valueMs: 12, range: range), animated: false)
        #expect(stage.test_rung == .fused)
        stage.apply(.locked(valueMs: 12, range: range), animated: false)
        #expect(stage.test_rung == .locked)
        stage.apply(.dormant, animated: false)
        #expect(stage.test_rung == .dormant)
    }

    @Test func aWideningBeliefHoldsItsRungUntilTheDemoteBoundary() {
        let stage = makeStage()
        stage.apply(.question(intervalMs: interval(halfWidth: 60), range: range),
                    animated: false)
        #expect(stage.test_rung == .near, "60 ms is `near`'s enter boundary")

        stage.apply(.question(intervalMs: interval(halfWidth: 70), range: range),
                    animated: false)
        #expect(stage.test_rung == .near,
                "70 ms is past the ENTER boundary but inside the 75 ms demote — held")

        stage.apply(.question(intervalMs: interval(halfWidth: 80), range: range),
                    animated: false)
        #expect(stage.test_rung == .closing,
                "80 ms clears the 75 ms demote boundary — the rung gives way")
    }

    @Test func tighteningEntersARungImmediately() {
        let stage = makeStage()
        stage.apply(.question(intervalMs: interval(halfWidth: 300), range: range),
                    animated: false)
        #expect(stage.test_rung == .open)
        // Hysteresis is one-sided on purpose: a belief that TIGHTENS lands on
        // its new rung at once — the run has earned it.
        stage.apply(.question(intervalMs: interval(halfWidth: 12), range: range),
                    animated: false)
        #expect(stage.test_rung == .threshold)
    }

    // MARK: (c) Display window — quantized spans, floor, clamp

    @Test func theWindowSpanIsQuantizedPerRung() {
        let cases: [(halfWidth: Double, rung: AlignmentStageView.Rung, span: Double)] = [
            (300, .open, 1000),      // full candidate range
            (100, .closing, 640),
            (30, .near, 200),
            (5, .threshold, 64),
        ]
        for expectation in cases {
            let stage = makeStage()
            stage.apply(.question(intervalMs: interval(halfWidth: expectation.halfWidth),
                                  range: range), animated: false)
            #expect(stage.test_rung == expectation.rung)
            #expect(abs(span(stage.test_displayRange) - expectation.span) < 0.01,
                    "\(expectation.rung) windows onto \(expectation.span) ms")
        }
    }

    @Test func armedShowsTheFullCandidateRange() {
        let stage = makeStage()
        let candidates = -800.0...800.0
        stage.apply(.armed(range: candidates), animated: false)

        #expect(stage.test_displayRange == candidates,
                "armed is the intro: wide open onto the whole candidate range")
    }

    @Test func displayRangeNeverExceedsTheCandidateRangeEvenNearAnEdge() {
        let stage = makeStage()
        // An interval hugging the range's upper edge forces the clamp-by-sliding
        // path in `displayWindow(for:rung:previous:)`.
        stage.apply(.question(intervalMs: 490...495, range: range), animated: false)

        let display = stage.test_displayRange
        #expect(display.lowerBound >= range.lowerBound - 0.01,
                "the window may not spill below the candidate range's floor")
        #expect(display.upperBound <= range.upperBound + 0.01,
                "the window may not spill above the candidate range's ceiling")
        #expect(abs(span(display) - 64) < 0.01,
                "clamping SLIDES the window — it never shrinks it below the rung's span")
    }

    @Test func displayRangeNeverSpansLessThanTheMinimum() {
        let stage = makeStage()
        // A near-zero-width interval would otherwise collapse the window.
        stage.apply(.question(intervalMs: 100...100.01, range: range), animated: false)

        #expect(span(stage.test_displayRange) >= 40 - 0.01,
                "the window never zooms tighter than the 40 ms floor")
    }

    @Test func aNarrowIntervalZoomsTighterThanAWideOneButNeverBelowTheFloor() {
        let stage = makeStage()
        let candidates = -1000.0...1000.0

        stage.apply(.question(intervalMs: 0...2, range: candidates), animated: false)
        let narrowSpan = span(stage.test_displayRange)

        stage.apply(.question(intervalMs: -100...100, range: candidates), animated: false)
        let wideSpan = span(stage.test_displayRange)

        #expect(narrowSpan >= 40 - 0.01, "the narrow interval's window still respects the floor")
        #expect(wideSpan >= 40 - 0.01, "the wide interval's window still respects the floor")
        #expect(narrowSpan < wideSpan,
                "a narrower credible interval yields a tighter zoom than a wider one")
    }

    // MARK: (d) Transitions

    @Test func anIdenticalApplyDispatchesNoTransition() {
        let stage = makeStage()
        let state = AlignmentStageView.State.question(
            intervalMs: interval(halfWidth: 30), range: range)

        stage.apply(state, animated: false)
        #expect(stage.test_lastTransition != .none, "the first apply is a real edge")

        stage.apply(state, animated: false)
        #expect(stage.test_lastTransition == .none,
                "an identical state + window re-stamps colors and replays nothing")
    }

    @Test func tighteningPromotesAndWideningDemotes() {
        let stage = makeStage()
        stage.apply(.question(intervalMs: interval(halfWidth: 300), range: range),
                    animated: false)
        stage.apply(.question(intervalMs: interval(halfWidth: 100), range: range),
                    animated: false)
        #expect(stage.test_lastTransition == .promotion(steps: 1),
                "open → closing is one rung climbed")

        // ⌘Z Back and a rejected proposal both WIDEN, and a widening never
        // brightens: it plays the demotion even when the rung holds.
        stage.apply(.question(intervalMs: interval(halfWidth: 200), range: range),
                    animated: false)
        #expect(stage.test_rung == .closing, "still inside closing's 300 ms demote")
        #expect(stage.test_lastTransition == .demotion,
                "gave ground inside one rung — still the demotion")
    }

    @Test func theFuseAndTheLockAreTheirOwnEdges() {
        let stage = makeStage()
        stage.apply(.question(intervalMs: interval(halfWidth: 8), range: range),
                    animated: false)
        stage.apply(.listening(valueMs: 20, range: range), animated: false)
        #expect(stage.test_lastTransition == .fuse, "threshold → fused")

        var settled = 0
        stage.onLockedSettled = { settled += 1 }
        stage.apply(.locked(valueMs: 20, range: range), animated: false)
        #expect(stage.test_lastTransition == .lock)
        #expect(settled == 1,
                "headless/Reduce-Motion locks settle synchronously — nothing is deferred")
    }

    @Test func everyRungChangeIsReportedOnceAndTheFirstApplyAlways() {
        let stage = makeStage()
        var reported: [AlignmentStageView.Rung] = []
        stage.onRungChange = { reported.append($0) }

        stage.apply(.question(intervalMs: interval(halfWidth: 300), range: range),
                    animated: false)
        stage.apply(.question(intervalMs: interval(halfWidth: 290), range: range),
                    animated: false)   // same rung — no report
        stage.apply(.question(intervalMs: interval(halfWidth: 30), range: range),
                    animated: false)

        #expect(reported == [.open, .near],
                "reported on the first apply and on every CHANGE, never per apply")
    }

    // MARK: (e) Reduce Motion + headless

    @Test func reduceMotionStillChangesTheLookState() {
        let stage = makeStage()
        stage.test_reduceMotionOverride = true

        stage.apply(.question(intervalMs: interval(halfWidth: 300), range: range),
                    animated: true)
        #expect(stage.test_rung == .open)
        let openTarget = stage.test_lightCentres.target

        stage.apply(.question(intervalMs: interval(halfWidth: 5), range: range),
                    animated: true)

        #expect(stage.test_rung == .threshold,
                "Reduce Motion removes the TRAVEL, never the information")
        #expect(abs(span(stage.test_displayRange) - 64) < 0.01,
                "the settled window is the new rung's, instantly")
        #expect(abs(stage.test_lightCentres.target.x - openTarget.x) > 1,
                "the settled geometry moved — the lights closed in")
        #expect(stage.test_lastTransition == .promotion(steps: 3),
                "the transition is still DISPATCHED; only its playback changes")
    }

    // `reconcileBreathing` requires `!HeadlessRuntime.isActive && window != nil`,
    // and test processes are always headless with no window — so
    // `test_isBreathing` is false regardless of rung or the Reduce Motion
    // override. The per-rung tempo table and the Reduce-Motion arm are
    // untestable headless by design; this test only pins that breathing never
    // turns on headless.
    @Test func breathingNeverRunsHeadless() {
        let stage = makeStage()
        stage.apply(.question(intervalMs: 100...160, range: range), animated: false)

        #expect(!stage.test_isBreathing, "breathing never runs headless (no window)")
    }

    /// The living ring's clock rides the same gate as breathing, so headless
    /// the stage renders at PINNED phase: the ported squash is there (it is a
    /// settled property), the wobble and the swell are not. This is what keeps
    /// `cacheDisplay` byte-deterministic for the wizard renders.
    @Test func headlessDrawsThePinnedRingAtTheRungsOwnOpacity() {
        let stage = makeStage()
        // Exactly AT the threshold boundary, so `thresholdProgress` is 0 and
        // the line width is the table's own — this test is about the port, not
        // about the top rung's inner ramp.
        stage.apply(.question(intervalMs: interval(halfWidth: 12), range: range),
                    animated: false)

        let look = AlignmentStageView.look(for: .threshold)
        let light = stage.test_targetLight
        // The ellipse is the ring box inset by half the stroke, shortened 1.12.
        let width = look.ringRadius * 2 - look.ringLineWidth
        #expect(abs(light.ring.width - width) < 0.01,
                "pinned: no wobble — the path is exactly the settled ellipse")
        #expect(abs(light.ring.height - width / 1.12) < 0.01,
                "the emitter's squash IS settled, so it renders at pinned phase too")
        #expect(abs(light.halo.height - look.haloDiameter / 1.12) < 0.01,
                "the halo wears the same squash in its bounds")
        // `thresholdProgress` brightens the halo inside this rung; the RING's
        // opacity is the table's, and the swell must not have touched it.
        #expect(abs(light.ringOpacity - look.ringOpacity) < 0.001,
                "brightness still encodes certainty — pinned means factor 1")
    }
}
