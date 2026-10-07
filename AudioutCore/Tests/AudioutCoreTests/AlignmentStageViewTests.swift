// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
import AudioutSharedUI

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

    /// The lock's thesis on screen: neither voice wins — the light is warm
    /// white, not the target's green surviving alone.
    @Test func lockedLightIsFuseWhiteNotTheTargetsGreen() throws {
        let stage = makeStage()
        stage.apply(.question(intervalMs: 30...50, range: range), animated: false)
        let live = try #require(stage.test_targetLightColor?.usingColorSpace(.sRGB))
        stage.apply(.locked(valueMs: 40, range: range), animated: false)
        let locked = try #require(stage.test_targetLightColor?.usingColorSpace(.sRGB))
        let fuse = try #require(Tokens.Color.fuseWhite.usingColorSpace(.sRGB))

        #expect(live.greenComponent > 0.9 && live.redComponent < 0.3, "a question light is Sync Green")
        #expect(abs(locked.redComponent - fuse.redComponent) < 0.02
                    && abs(locked.greenComponent - fuse.greenComponent) < 0.02
                    && abs(locked.blueComponent - fuse.blueComponent) < 0.02,
                "the locked light is stamped fuseWhite, got \(locked)")
    }

    /// The stage is a fixed instrument: the reference light is `ring`'s DARK
    /// hex whichever appearance the sheet is in, the way every other stage
    /// token passes one hex for both.
    @Test func referenceLightIsRingsDarkHexInBothAppearances() throws {
        let pinned = try #require(resolved(Tokens.Color.ring, appearanceName: .darkAqua)
            .usingColorSpace(.sRGB))
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let stage = makeStage()
            stage.appearance = NSAppearance(named: appearanceName)
            stage.apply(.question(intervalMs: 30...50, range: range), animated: false)
            let drawn = try #require(stage.test_referenceLightColor?.usingColorSpace(.sRGB))
            #expect(abs(drawn.redComponent - pinned.redComponent) < 0.02
                        && abs(drawn.greenComponent - pinned.greenComponent) < 0.02
                        && abs(drawn.blueComponent - pinned.blueComponent) < 0.02,
                    "\(appearanceName.rawValue): the reference light is the pinned ring, got \(drawn)")
        }
    }

    /// S6: the promotion detent is a brightness pulse in the instrument's own
    /// ink, not the gold the CTA plate owns.
    @Test func detentFlashIsStageInkNotGold() throws {
        let stage = makeStage()
        stage.apply(.question(intervalMs: 30...50, range: range), animated: false)
        let accent = try #require(stage.test_detentAccent?.usingColorSpace(.sRGB))
        let ink = try #require(Tokens.Color.stageInk.usingColorSpace(.sRGB))
        #expect(abs(accent.redComponent - ink.redComponent) < 0.02
                    && abs(accent.greenComponent - ink.greenComponent) < 0.02
                    && abs(accent.blueComponent - ink.blueComponent) < 0.02,
                "the detent is stamped stageInk, got \(accent)")
        #expect(accent.redComponent - accent.blueComponent < 0.1,
                "gold would lead red by ~0.52; the detent is near-neutral")

        // The colour alone is 1.11:1 and ΔE76 5.4 from the fuseWhite the
        // shadow rests at, and slightly darker — so the detent is only an
        // event if the BRIGHTNESS moves. It has to at least half again.
        let (settled, peak) = stage.test_detentShadowOpacity
        #expect(peak >= settled * 1.5,
                "the detent must brighten the bloom, not just retint it (rests at \(settled), peaks at \(peak))")
    }

    /// Force-resolves a dynamic `Tokens.Color` under a fixed appearance — the
    /// same idiom `AlignmentTokenContrastTests` measures with.
    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
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
        stage.apply(.measuring(range: range), animated: false)
        #expect(stage.test_rung == .measuring)
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

    /// Turns red if `measuring → fused` stops dispatching `.gather`, or the
    /// by-ear `threshold → fused` stops dispatching `.fuse`.
    @Test func theGatherTheFuseAndTheLockAreTheirOwnEdges() {
        let stage = makeStage()
        stage.apply(.measuring(range: range), animated: false)
        stage.apply(.listening(valueMs: 20, range: range), animated: false)
        #expect(stage.test_lastTransition == .gather, "measuring → fused, the mic's answer")

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

    /// The light's settled box is the table's diameter, squashed 1.12 in y —
    /// a settled property of the carrier's bounds, present in every render —
    /// and its brightness is the table's own column, untouched by any
    /// transient. This is what keeps `cacheDisplay` deterministic for the
    /// wizard renders.
    @Test func headlessDrawsThePinnedHaloAtTheRungsOwnOpacity() {
        let stage = makeStage()
        // Exactly AT the threshold boundary, so `thresholdProgress` is 0 and
        // the light is the table's own size, without the top rung's inner
        // ramp on top of it.
        stage.apply(.question(intervalMs: interval(halfWidth: 12), range: range),
                    animated: false)

        let look = AlignmentStageView.look(for: .threshold)
        let light = stage.test_targetLight
        #expect(abs(light.halo.width - look.haloDiameter) < 0.01,
                "the light's box is the rung's own diameter")
        #expect(abs(light.halo.height - look.haloDiameter / 1.12) < 0.01,
                "the emitter's squash IS settled, so it renders here too")
        #expect(abs(light.opacity - look.haloOpacity) < 0.001,
                "brightness still encodes certainty — one column, the table's")
    }

    /// Turns red if the fused branch puts the reference back on the target's
    /// variant 0, or the locked branch stops merging it onto variant 0.
    @Test func theReferenceKeepsItsOwnMathsUntilTheLock() {
        let stage = makeStage()
        stage.apply(.question(intervalMs: 30...50, range: range), animated: false)
        #expect(stage.test_referenceVariant == 1, "apart, the two lights differ")

        stage.apply(.listening(valueMs: 40, range: range), animated: false)
        #expect(stage.test_referenceVariant == 1, "fused, the reference keeps its own maths")

        stage.apply(.locked(valueMs: 40, range: range), animated: false)
        #expect(stage.test_referenceVariant == 0, "locked, still one light")

        stage.apply(.dormant, animated: false)
        #expect(stage.test_referenceVariant == 1, "dormant is two lights again")
    }

    /// FUSED (the proposal) is one ring with two edges, not a merge: both
    /// lights lit at one centre, the reference drawn 1.285× the target so its
    /// band sits half a band outside the target's, with no gap between. LOCKED
    /// they merge to one white ring — the reference fades to nothing and only
    /// the target survives. Turns red if the fused size leaves 64 pt or
    /// `fusedReferenceScale` leaves 1.285.
    @Test func fusedIsOneRingWithTwoEdgesAndLockedMergesToOne() {
        let stage = makeStage()

        stage.apply(.question(intervalMs: 30...50, range: range), animated: false)
        #expect(stage.test_referenceLightOpacity > 0, "apart, the reference light is lit")

        stage.apply(.listening(valueMs: 40, range: range), animated: false)
        let target = stage.test_targetLight
        let reference = stage.test_referenceLight
        #expect(reference.opacity > 0, "fused, the reference light is still lit")
        #expect(abs(reference.opacity - target.opacity) < 0.001,
                "fused, both rings sit at the rung's full opacity")
        #expect(reference.halo.width > target.halo.width + 0.5,
                "fused, the reference ring is larger than the target, got \(reference.halo.width) vs \(target.halo.width)")
        #expect(abs(target.halo.width - 64) < 0.01, "fused, the target is 64 pt")
        #expect(abs(reference.halo.width / target.halo.width - 1.285) < 0.001,
                "fused, the reference is 1.285× the target")
        let centres = stage.test_lightCentres
        #expect(abs(centres.target.x - centres.reference.x) < 0.01
                    && abs(centres.target.y - centres.reference.y) < 0.01,
                "fused, the two rings share one centre")

        stage.apply(.locked(valueMs: 40, range: range), animated: false)
        #expect(stage.test_referenceLightOpacity == 0,
                "locked, the reference fades out so a single white ring reads")
        #expect(stage.test_targetLight.opacity > 0,
                "locked, the lone target ring is the kept white light")
    }

    // MARK: (f) Listening — the measuring rung, per light

    /// Turns red if a turn stops growing its light with the smoothed level
    /// above the room, grows the other light, or a finished turn stops
    /// holding its size while it waits for a verdict.
    @Test func aTurnGrowsItsLightWithTheLevelAboveTheRoom() {
        let stage = makeStage()
        stage.apply(.measuring(range: range), animated: false)
        stage.setListeningTurn(.target, levelAboveRoomDB: 24, now: 100)
        stage.setListeningTurn(.target, levelAboveRoomDB: 24, now: 101)

        #expect(stage.test_listeningPhases.target == .turn)
        #expect(abs(stage.test_targetLight.halo.width - 116) < 0.5,
                "+24 dB is full growth, got \(stage.test_targetLight.halo.width)")
        #expect(abs(stage.test_targetLight.opacity - 1) < 0.001)
        #expect(abs(stage.test_referenceLight.halo.width - 84) < 0.01,
                "the other speaker's light is untouched")

        let held = stage.test_targetLight.halo.width
        stage.setListeningTurn(nil, levelAboveRoomDB: nil, now: 102)
        #expect(stage.test_listeningPhases.target == .checking)
        #expect(abs(stage.test_targetLight.halo.width - held) < 0.01,
                "checking holds what the turn ended on")

        let quiet = makeStage()
        quiet.apply(.measuring(range: range), animated: false)
        quiet.setListeningTurn(.reference, levelAboveRoomDB: 6, now: 100)
        quiet.setListeningTurn(.reference, levelAboveRoomDB: 6, now: 101)
        #expect(abs(quiet.test_referenceLight.halo.width - 84) < 0.01,
                "+6 dB is the growth floor: the light holds its resting size")
    }

    /// Turns red if a heard verdict stops seating the light 40 pt left of the
    /// centre at 72 pt, a missed one stops shrinking and dimming it at home in
    /// its hue mixed 80 % toward `stageRule`, or `resetListening` stops
    /// sending both home.
    @Test func verdictsSeatHeardDimMissedAndResetSendsBothHome() throws {
        let stage = makeStage()
        stage.apply(.measuring(range: range), animated: false)
        let homes = stage.test_lightCentres

        stage.setListeningPhase(.heard, for: .target, animated: false)
        #expect(abs(stage.test_lightCentres.target.x - (stage.bounds.midX - 40)) < 0.01)
        #expect(abs(stage.test_targetLight.halo.width - 72) < 0.01)

        stage.setListeningPhase(.missed, for: .reference, animated: false)
        #expect(abs(stage.test_lightCentres.reference.x - homes.reference.x) < 0.01,
                "a missed light stays at its range end")
        #expect(abs(stage.test_referenceLight.halo.width - 72) < 0.01)
        #expect(abs(stage.test_referenceLight.opacity - 0.35) < 0.001)
        let drawn = try #require(stage.test_referenceLightColor?.usingColorSpace(.sRGB))
        let mixed = try #require(resolved(Tokens.Color.ring, appearanceName: .darkAqua)
            .blended(withFraction: 0.8, of: resolved(Tokens.Color.stageRule, appearanceName: .darkAqua))?
            .usingColorSpace(.sRGB))
        #expect(abs(drawn.redComponent - mixed.redComponent) < 0.02
                    && abs(drawn.greenComponent - mixed.greenComponent) < 0.02
                    && abs(drawn.blueComponent - mixed.blueComponent) < 0.02,
                "a missed light leans 80 % to the rule, got \(drawn), wanted \(mixed)")

        stage.resetListening(animated: false)
        #expect(stage.test_listeningPhases.target == .waiting
                    && stage.test_listeningPhases.reference == .waiting)
        #expect(abs(stage.test_lightCentres.target.x - homes.target.x) < 0.01
                    && abs(stage.test_lightCentres.reference.x - homes.reference.x) < 0.01)
        #expect(abs(stage.test_targetLight.halo.width - 84) < 0.01
                    && abs(stage.test_referenceLight.halo.width - 84) < 0.01)
    }

    /// Turns red if the ruler keeps clearing ticks only at the lights' range
    /// ends, so the 250 ms tick of a 50…650 ms range runs through the target
    /// once it is heard and seated 40 pt left of the centre.
    @Test func aSeatedLightClearsTheTicksUnderIt() {
        let stage = makeStage()
        stage.apply(.measuring(range: 50...650), animated: false)
        let seatX = stage.bounds.midX - 40
        #expect(stage.test_tickXs.contains { abs($0 - seatX) < 36 },
                "a tick sits where the target will be seated")

        stage.setListeningPhase(.heard, for: .target, animated: false)
        #expect(!stage.test_tickXs.contains { abs($0 - seatX) < 36 },
                "no tick crosses the seated light, got \(stage.test_tickXs)")
    }

    /// Turns red if Reduce Motion lets a turn grow the light's size, or stops
    /// raising its brightness instead.
    @Test func reduceMotionTurnsGrowthIntoBrightness() {
        let stage = makeStage()
        stage.test_reduceMotionOverride = true
        stage.apply(.measuring(range: range), animated: false)
        stage.setListeningTurn(.target, levelAboveRoomDB: 24, now: 100)
        stage.setListeningTurn(.target, levelAboveRoomDB: 24, now: 101)

        #expect(abs(stage.test_targetLight.halo.width - 84) < 0.01)
        #expect(abs(stage.test_targetLight.opacity - 1) < 0.001)
    }

    /// Turns red if a turn or a verdict lands on any rung but measuring.
    @Test func listeningInputIsIgnoredOffTheMeasuringRung() {
        let stage = makeStage()
        stage.apply(.question(intervalMs: 30...50, range: range), animated: false)
        let centres = stage.test_lightCentres
        let target = stage.test_targetLight
        let reference = stage.test_referenceLight

        stage.setListeningTurn(.target, levelAboveRoomDB: 24, now: 100)
        stage.setListeningTurn(.target, levelAboveRoomDB: 24, now: 101)
        stage.setListeningPhase(.heard, for: .target, animated: false)
        stage.setListeningPhase(.missed, for: .reference, animated: false)

        #expect(stage.test_listeningPhases.target == .waiting
                    && stage.test_listeningPhases.reference == .waiting)
        #expect(stage.test_listeningGrowth == 0)
        #expect(stage.test_lightCentres.target == centres.target
                    && stage.test_lightCentres.reference == centres.reference)
        #expect(stage.test_targetLight.halo == target.halo
                    && stage.test_referenceLight.halo == reference.halo
                    && stage.test_referenceLight.opacity == reference.opacity)
    }
}
