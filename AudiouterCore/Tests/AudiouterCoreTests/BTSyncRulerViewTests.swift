// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI

/// The **fine-adjustment ruler** (`BTSyncRulerView`, PLAN-BT-SYNC-DRAWER §3
/// T4): a ticked tape sliding under a fixed centre pointer. Covers the two
/// traps the plan calls out by name — drag-right-means-later (D3) and the
/// quantise/clamp discipline every emitted value must pass through (D5/T3)
/// — plus the delegate-firing shape (continuous during a drag, exactly one
/// `didEndScrub`) and the accessibility increment/decrement/keyboard
/// contract. Drives gestures via the `test_*` seams (`test_beginScrub` /
/// `test_scrub(byPoints:speed:)` / `test_endScrub`) rather than synthesized
/// `NSEvent`s — a drag can't be synthesized headlessly, and these hooks run
/// through the exact same private commit path (`emit`) the live
/// `mouseDown`/`mouseDragged`/`mouseUp` overrides do.
@MainActor
@Suite struct BTSyncRulerViewTests {

    private final class Spy: BTSyncRulerViewDelegate {
        var scrubs: [Double] = []
        var endCount = 0
        func syncRuler(_ ruler: BTSyncRulerView, didScrubTo ms: Double) { scrubs.append(ms) }
        func syncRulerDidEndScrub(_ ruler: BTSyncRulerView) { endCount += 1 }
    }

    private func makeRuler(valueMs: Double = 0,
                           usableRangeMs: ClosedRange<Double> = -500...500) -> (BTSyncRulerView, Spy) {
        let ruler = BTSyncRulerView()
        ruler.valueMs = valueMs
        ruler.usableRangeMs = usableRangeMs
        let spy = Spy()
        ruler.delegate = spy
        return (ruler, spy)
    }

    // MARK: Direction trap (D3) — "the second easy inversion after T2's sign"

    @Test func draggingRightIncreasesValue() {
        let (ruler, _) = makeRuler()
        ruler.test_beginScrub()
        ruler.test_scrub(byPoints: 30, speed: 1)
        ruler.test_endScrub()
        #expect(ruler.valueMs > 0, "dragging right (+deltaX) must increase the value — larger = plays later (D3)")
    }

    @Test func draggingLeftDecreasesValue() {
        let (ruler, _) = makeRuler()
        ruler.test_beginScrub()
        ruler.test_scrub(byPoints: -30, speed: 1)
        ruler.test_endScrub()
        #expect(ruler.valueMs < 0, "dragging left must decrease the value")
    }

    // MARK: Gearing (D5)

    @Test func slowDragChangesValueBySmallAmount() {
        let (ruler, _) = makeRuler()
        ruler.test_beginScrub()
        ruler.test_scrub(byPoints: 30, speed: 1)
        ruler.test_endScrub()
        #expect(abs(ruler.valueMs - 1.0) < 0.15,
                "30 pt at the slow anchor (≈0.033 ms/pt) should land near 1 ms, got \(ruler.valueMs)")
    }

    @Test func fastDragChangesValueByFarMore() {
        let (ruler, _) = makeRuler()
        ruler.test_beginScrub()
        ruler.test_scrub(byPoints: 30, speed: 40)
        ruler.test_endScrub()
        #expect(ruler.valueMs > 30,
                "30 pt at the fast anchor (2 ms/pt) should land far past the slow drag's ~1 ms, got \(ruler.valueMs)")
    }

    @Test func optionForcesFineGearingRegardlessOfSpeed() {
        let (ruler, _) = makeRuler()
        ruler.test_optionModifierOverride = true
        ruler.test_beginScrub()
        ruler.test_scrub(byPoints: 30, speed: 40)   // would be fast gearing without ⌥
        ruler.test_endScrub()
        #expect(abs(ruler.valueMs - 1.0) < 0.15,
                "⌥ must force the slow anchor even though speed=40 asked for fast, got \(ruler.valueMs)")
    }

    // MARK: Quantise + clamp discipline — never emit a raw drag delta

    @Test func everyEmittedValueIsQuantisedToOneTenthMs() {
        let (ruler, _) = makeRuler()
        ruler.test_beginScrub()
        ruler.test_scrub(byPoints: 7, speed: 3)   // an arbitrary, not-suspiciously-round drag
        ruler.test_endScrub()
        let scaled = (ruler.valueMs / BTSyncTrim.resolutionMs).rounded()
        #expect(abs(ruler.valueMs - scaled * BTSyncTrim.resolutionMs) < 0.0001,
                "\(ruler.valueMs) is not a whole multiple of \(BTSyncTrim.resolutionMs)")
    }

    @Test func valueNeverLeavesUsableRangeAtCeiling() {
        let (ruler, _) = makeRuler(valueMs: 490, usableRangeMs: -500...500)
        ruler.test_beginScrub()
        ruler.test_scrub(byPoints: 1000, speed: 40)   // a huge drag past the ceiling
        ruler.test_endScrub()
        #expect(ruler.valueMs == 500, "a hard stop at the usable ceiling, not a rubber band")
    }

    @Test func valueNeverLeavesUsableRangeAtFloor() {
        let (ruler, _) = makeRuler(valueMs: -100, usableRangeMs: -100...500)
        ruler.test_beginScrub()
        ruler.test_scrub(byPoints: -1000, speed: 40)
        ruler.test_endScrub()
        #expect(ruler.valueMs == -100, "a hard stop at the device's real usable floor (T3/D11)")
    }

    // MARK: Delegate shape

    @Test func delegateFiresContinuouslyDuringDragAndEndsOnce() {
        let (ruler, spy) = makeRuler()
        ruler.test_beginScrub()
        ruler.test_scrub(byPoints: 5, speed: 5)
        ruler.test_scrub(byPoints: 5, speed: 5)
        ruler.test_scrub(byPoints: 5, speed: 5)
        #expect(spy.scrubs.count == 3, "each drag increment reports a scrub")
        #expect(spy.endCount == 0, "no end yet — the drag hasn't finished")
        ruler.test_endScrub()
        #expect(spy.endCount == 1, "exactly one end, on the drag's release")
    }

    @Test func settingValueMsExternallyDoesNotFireDelegate() {
        let (ruler, spy) = makeRuler()
        ruler.valueMs = 42.3
        #expect(spy.scrubs.isEmpty, "an external set repositions the tape, it isn't a user gesture")
        #expect(spy.endCount == 0)
    }

    // MARK: Accessibility increment/decrement — exactly resolutionMs

    @Test func accessibilityIncrementMovesByExactlyOneTenthMs() {
        let (ruler, spy) = makeRuler(valueMs: 10)
        _ = ruler.accessibilityPerformIncrement()
        #expect(abs(ruler.valueMs - 10.1) < 0.0001)
        #expect(spy.scrubs.count == 1)
        #expect(spy.endCount == 1, "an AX nudge is a complete, discrete commit")
    }

    @Test func accessibilityDecrementMovesByExactlyOneTenthMs() {
        let (ruler, _) = makeRuler(valueMs: 10)
        _ = ruler.accessibilityPerformDecrement()
        #expect(abs(ruler.valueMs - 9.9) < 0.0001)
    }

    // MARK: Keyboard nudge (←/→ resolutionMs, ⌥←/→ coarseStepMs)

    @Test func rightArrowNudgesByResolution() {
        let (ruler, _) = makeRuler(valueMs: 10)
        ruler.test_pressArrowKey(.right)
        #expect(abs(ruler.valueMs - 10.1) < 0.0001)
    }

    @Test func leftArrowNudgesByResolution() {
        let (ruler, _) = makeRuler(valueMs: 10)
        ruler.test_pressArrowKey(.left)
        #expect(abs(ruler.valueMs - 9.9) < 0.0001)
    }

    @Test func optionRightArrowNudgesByCoarseStep() {
        let (ruler, _) = makeRuler(valueMs: 10)
        ruler.test_pressArrowKey(.right, optionHeld: true)
        #expect(abs(ruler.valueMs - (10 + BTSyncTrim.coarseStepMs)) < 0.0001)
    }

    // MARK: Accessibility value description (D7 — never a bare signed number)

    @Test func accessibilityValueDescriptionReadsLaterOrEarlier() {
        #expect(BTSyncRulerView.accessibilityValueDescription(for: 22.4) == "22.4 milliseconds later")
        #expect(BTSyncRulerView.accessibilityValueDescription(for: -22.4) == "22.4 milliseconds earlier")
        #expect(BTSyncRulerView.accessibilityValueDescription(for: 0) == "In sync")
    }
}
