// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI

/// The **BT sync drawer** (`BTSyncDrawerView`, PLAN-BT-SYNC-DRAWER §3 T5):
/// composes T4's `BTSyncRulerView` with the click-to-edit readout, −/+
/// steppers, the align-by-ear toggle, and Revert. Covers the visual-state
/// mapping (set/unset/negative→"earlier"/at-floor), Revert enablement (D8),
/// ⌥-click fine stepping, the `committed` flag's shape (false during a live
/// scrub, true on every discrete gesture — D6's whole reason for existing),
/// and the align-toggle round-trip. Drives gestures via the `test_*` seams
/// (mirroring `BTSyncRulerViewTests`'s own convention) so each test exercises
/// the exact delegate/action path a live gesture does.
@MainActor
@Suite struct BTSyncDrawerViewTests {

    private final class Spy: BTSyncDrawerViewDelegate {
        var changes: [(ms: Double, committed: Bool)] = []
        var alignToggles: [Bool] = []
        var closeRequests = 0
        func syncDrawer(_ d: BTSyncDrawerView, didChangeTrimMs ms: Double, committed: Bool) {
            changes.append((ms, committed))
        }
        func syncDrawer(_ d: BTSyncDrawerView, didToggleAlignTick active: Bool) {
            alignToggles.append(active)
        }
        func syncDrawerDidRequestClose(_ d: BTSyncDrawerView) {
            closeRequests += 1
        }
    }

    private func makeDrawer(trimMs: Double = 22.4, isSet: Bool = true,
                            usableRangeMs: ClosedRange<Double> = -500...500,
                            alignTickActive: Bool = false) -> (BTSyncDrawerView, Spy) {
        let drawer = BTSyncDrawerView()
        drawer.configure(deviceName: "Kitchen Speaker", trimMs: trimMs, isSet: isSet,
                         usableRangeMs: usableRangeMs, alignTickActive: alignTickActive)
        drawer.noteOpened(trimMs: trimMs)
        let spy = Spy()
        drawer.delegate = spy
        return (drawer, spy)
    }

    // MARK: configure/read-back — set, unset, negative, at-floor (T5 test list)

    @Test func setPositiveValueReadsLater() {
        let (drawer, _) = makeDrawer(trimMs: 22.4, isSet: true)
        #expect(drawer.test_valueFieldText == "22.4")
        #expect(drawer.test_suffixText == "ms later")
        #expect(drawer.test_captionText == "Kitchen Speaker plays")
    }

    @Test func setNegativeValueReadsEarlierWithAbsoluteMagnitude() {
        let (drawer, _) = makeDrawer(trimMs: -22.4, isSet: true)
        #expect(drawer.test_valueFieldText == "22.4", "D7: the readout shows the MAGNITUDE, never a bare signed number")
        #expect(drawer.test_suffixText == "ms earlier")
    }

    @Test func unsetDeviceReadsNotSet() {
        let (drawer, _) = makeDrawer(trimMs: 0, isSet: false)
        #expect(drawer.test_valueFieldText == "Not set", "D10: untuned reads as an invitation, not \"0.0\"")
        #expect(drawer.test_suffixText == "")
    }

    @Test func atUsableFloorStillReadsCorrectly() {
        let (drawer, _) = makeDrawer(trimMs: -100, isSet: true, usableRangeMs: -100...500)
        #expect(drawer.test_valueFieldText == "100.0")
        #expect(drawer.test_suffixText == "ms earlier")
    }

    @Test func exactlyZeroReadsNeutralSuffix() {
        let (drawer, _) = makeDrawer(trimMs: 0, isSet: true)
        #expect(drawer.test_valueFieldText == "0.0")
        #expect(drawer.test_suffixText == "ms", "in sync — neither later nor earlier")
    }

    // MARK: Revert enablement (D8)

    @Test func revertDisabledWhenUnchangedSinceOpen() {
        let (drawer, _) = makeDrawer(trimMs: 22.4)
        #expect(!drawer.test_revertEnabled)
    }

    @Test func revertEnabledAfterAChange() {
        let (drawer, _) = makeDrawer(trimMs: 22.4)
        drawer.test_fireMinusClick()
        #expect(drawer.test_revertEnabled)
    }

    @Test func revertRestoresTheOpenTimeValueAndDisablesAgain() {
        let (drawer, spy) = makeDrawer(trimMs: 22.4)
        drawer.test_fireMinusClick()
        #expect(drawer.test_trimMs != 22.4)
        drawer.test_fireRevertClick()
        #expect(drawer.test_trimMs == 22.4)
        #expect(!drawer.test_revertEnabled)
        #expect(spy.changes.last?.ms == 22.4)
        #expect(spy.changes.last?.committed == true, "Revert applies AND persists")
    }

    // MARK: −/+ steppers — coarseStepMs plain, fineStepMs with ⌥ (T5 spec)

    @Test func minusStepsByCoarseStepByDefault() {
        let (drawer, spy) = makeDrawer(trimMs: 22.4)
        drawer.test_fireMinusClick()
        let expected = BTSyncTrim.quantise(22.4 - BTSyncTrim.coarseStepMs)
        #expect(drawer.test_trimMs == expected)
        #expect(spy.changes.last?.ms == expected)
        #expect(spy.changes.last?.committed == true)
    }

    @Test func plusStepsByCoarseStepByDefault() {
        let (drawer, _) = makeDrawer(trimMs: 22.4)
        drawer.test_firePlusClick()
        #expect(drawer.test_trimMs == BTSyncTrim.quantise(22.4 + BTSyncTrim.coarseStepMs))
    }

    @Test func optionClickStepsByFineStep() {
        let (drawer, _) = makeDrawer(trimMs: 22.4)
        drawer.test_optionModifierOverride = true
        drawer.test_firePlusClick()
        #expect(drawer.test_trimMs == BTSyncTrim.quantise(22.4 + BTSyncTrim.fineStepMs))
    }

    @Test func stepperClampsToUsableRange() {
        let (drawer, _) = makeDrawer(trimMs: 495, usableRangeMs: -500...500)
        drawer.test_firePlusClick()
        #expect(drawer.test_trimMs == 500, "a hard stop at the ceiling, not past it")
    }

    // MARK: `committed` flag shape — false during a live scrub, true otherwise (D6)

    @Test func rulerScrubAppliesWithoutCommitting() {
        let (drawer, spy) = makeDrawer(trimMs: 0)
        drawer.test_ruler.test_beginScrub()
        drawer.test_ruler.test_scrub(byPoints: 30, speed: 1)
        #expect(spy.changes.count == 1)
        #expect(spy.changes[0].committed == false, "D6: continuous during the drag, never persisted mid-scrub")
        #expect(drawer.test_trimMs == drawer.test_ruler.valueMs)
    }

    @Test func rulerScrubEndCommits() {
        let (drawer, spy) = makeDrawer(trimMs: 0)
        drawer.test_ruler.test_beginScrub()
        drawer.test_ruler.test_scrub(byPoints: 30, speed: 1)
        drawer.test_ruler.test_endScrub()
        #expect(spy.changes.last?.committed == true, "drag end is the commit/persist point")
    }

    @Test func fieldCommitIsAlwaysCommittedTrue() {
        let (drawer, spy) = makeDrawer(trimMs: 22.4)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("30.0")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(drawer.test_trimMs == 30.0)
        #expect(spy.changes.last?.ms == 30.0, "a typed commit is a discrete gesture, always persisted")
        #expect(spy.changes.last?.committed == true)
    }

    // MARK: Align toggle round-trip

    @Test func alignToggleRoundTrips() {
        let (drawer, spy) = makeDrawer(alignTickActive: false)
        #expect(!drawer.test_alignActive)
        drawer.test_fireAlignClick()
        #expect(drawer.test_alignActive)
        #expect(spy.alignToggles == [true])
        drawer.test_fireAlignClick()
        #expect(!drawer.test_alignActive)
        #expect(spy.alignToggles == [true, false])
    }

    @Test func configurePushesAlignStateWithoutFiringDelegate() {
        let (drawer, spy) = makeDrawer(alignTickActive: false)
        drawer.configure(deviceName: "Kitchen Speaker", trimMs: 22.4, isSet: true,
                         usableRangeMs: -500...500, alignTickActive: true)
        #expect(drawer.test_alignActive)
        #expect(spy.alignToggles.isEmpty, "an external push repositions state, it isn't a user gesture")
    }

    // MARK: Escape — drawer-level close vs field-level revert don't collide

    @Test func escapeOnTheDrawerRequestsClose() {
        let (drawer, spy) = makeDrawer()
        drawer.test_fireCancelOperation()
        #expect(spy.closeRequests == 1)
    }

    @Test func escapeWhileEditingRevertsTheFieldAndDoesNotRequestClose() {
        let (drawer, spy) = makeDrawer(trimMs: 22.4)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("999")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.cancelOperation(_:)))
        #expect(drawer.test_valueFieldEditor.test_fieldText == "22.4")
        #expect(spy.closeRequests == 0, "the field's own Escape is consumed — it must not also close the drawer")
        #expect(drawer.test_trimMs == 22.4, "reverted, never committed")
    }

    // MARK: Field editing — decimals, sign round-trip, unparseable input

    @Test func fieldAcceptsDecimals() {
        let (drawer, _) = makeDrawer(trimMs: 0)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("5.7")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(drawer.test_trimMs == 5.7)
    }

    @Test func fieldTypedNegativeSetsEarlier() {
        let (drawer, _) = makeDrawer(trimMs: 10, isSet: true)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("-15")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(drawer.test_trimMs == -15)
        #expect(drawer.test_suffixText == "ms earlier")
    }

    @Test func unparseableFieldTextFallsBackToCommittedValue() {
        let (drawer, _) = makeDrawer(trimMs: 22.4)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("not a number")
        drawer.test_valueFieldEditor.test_endEditing()
        #expect(drawer.test_trimMs == 22.4)
    }

    @Test func noOpEditRoundTripsThroughSignedPrefillWithoutFlippingSign() {
        // The regression this design exists to prevent: click into a NEGATIVE
        // (earlier) value, change nothing, commit — must not silently flip to
        // positive because the resting display shows only the magnitude.
        let (drawer, _) = makeDrawer(trimMs: -22.4, isSet: true)
        drawer.test_valueFieldEditor.test_beginEditing()
        #expect(drawer.test_valueFieldEditor.test_fieldText == "-22.4", "editing shows the SIGNED value, not the split magnitude+suffix")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(drawer.test_trimMs == -22.4)
    }

    // MARK: `noteOpened` reuse (T7 reuses one drawer instance across devices)

    @Test func noteOpenedResetsTheRevertBaseline() {
        let (drawer, _) = makeDrawer(trimMs: 10)
        drawer.test_fireMinusClick()
        #expect(drawer.test_revertEnabled)
        drawer.configure(deviceName: "Office Speaker", trimMs: 50, isSet: true,
                         usableRangeMs: -500...500, alignTickActive: false)
        drawer.noteOpened(trimMs: 50)
        #expect(!drawer.test_revertEnabled, "a fresh open's baseline is the fresh device's own value")
    }

    // MARK: Height — definite, derived (Trap #6: an ambiguous height silently
    // collapses the popover instead of erroring)

    @Test func heightIsDefiniteAndMatchesTheDerivedGridConstant() {
        let drawer = BTSyncDrawerView()
        drawer.layoutSubtreeIfNeeded()
        #expect(drawer.fittingSize.height == PopoverColumnGrid.syncDrawerHeight)
    }
}
