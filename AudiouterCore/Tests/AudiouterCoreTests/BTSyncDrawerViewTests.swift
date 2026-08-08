// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI

/// The **BT sync drawer** (`BTSyncDrawerView`, PLAN-BT-SYNC-DRAWER §3 T5, as
/// redesigned after live feedback): one band — align-by-ear and Revert
/// leading, a ⇧ hint, and a bound `[ − | value ms | + ]` cluster around a
/// click-to-type field, right-aligned under the chip that opened it. The four
/// loose `±1`/`±10` pills were cut: one pair of buttons steps 1 ms, or 10 with
/// ⇧ held. Covers the field/spoken-value mapping (set/unset/negative/
/// at-floor), Revert enablement (D8), each step amount including the ⇧ coarse
/// path, auto-repeat, range clamping, field editing with whole-ms snapping and
/// the signed round-trip, and the align round-trip. Drives gestures via the
/// `test_*` seams so each test exercises the real delegate/action path.
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

    private func makeDrawer(trimMs: Double = 24, isSet: Bool = true,
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

    // MARK: field + spoken value — set, unset, negative, at-floor

    @Test func setPositiveValueShowsSignedNumberAndSpeaksLater() {
        let (drawer, _) = makeDrawer(trimMs: 24, isSet: true)
        #expect(drawer.test_valueFieldText == "24 ms")
        #expect(drawer.test_valueFieldAXValue == "24 milliseconds later",
                "D7 lives in the spoken value — the visible field carries only the sign")
    }

    @Test func setNegativeValueShowsSignedNumberAndSpeaksEarlier() {
        let (drawer, _) = makeDrawer(trimMs: -24, isSet: true)
        #expect(drawer.test_valueFieldText == "-24 ms", "the field is the signed control value, unit included at rest")
        #expect(drawer.test_valueFieldAXValue == "24 milliseconds earlier")
    }

    @Test func unsetDeviceSpeaksNotSet() {
        let (drawer, _) = makeDrawer(trimMs: 0, isSet: false)
        #expect(drawer.test_valueFieldText == "0 ms")
        #expect(drawer.test_valueFieldAXValue == "Not set",
                "D10: untuned is spoken as an invitation, matching the row chip")
    }

    @Test func atUsableFloorStillReadsCorrectly() {
        let (drawer, _) = makeDrawer(trimMs: -100, isSet: true, usableRangeMs: -100...500)
        #expect(drawer.test_valueFieldText == "-100 ms")
        #expect(drawer.test_valueFieldAXValue == "100 milliseconds earlier")
    }

    @Test func exactlyZeroSpeaksInSync() {
        let (drawer, _) = makeDrawer(trimMs: 0, isSet: true)
        #expect(drawer.test_valueFieldText == "0 ms")
        #expect(drawer.test_valueFieldAXValue == "in sync")
    }

    // MARK: Revert enablement (D8)

    @Test func revertDisabledWhenUnchangedSinceOpen() {
        let (drawer, _) = makeDrawer(trimMs: 24)
        #expect(!drawer.test_revertEnabled)
    }

    @Test func revertEnabledAfterAChange() {
        let (drawer, _) = makeDrawer(trimMs: 24)
        drawer.test_fireMinusClick()
        #expect(drawer.test_revertEnabled)
    }

    @Test func revertRestoresTheOpenTimeValueAndDisablesAgain() {
        let (drawer, spy) = makeDrawer(trimMs: 24)
        drawer.test_fireMinusClick()
        #expect(drawer.test_trimMs != 24)
        drawer.test_fireRevertClick()
        #expect(drawer.test_trimMs == 24)
        #expect(!drawer.test_revertEnabled)
        #expect(spy.changes.last?.ms == 24)
        #expect(spy.changes.last?.committed == true, "Revert applies AND persists")
    }

    // MARK: One stepper pair — 1 ms a click, 10 while ⇧ is held

    @Test func minusStepsByOne() {
        let (drawer, spy) = makeDrawer(trimMs: 24)
        drawer.test_fireMinusClick()
        #expect(drawer.test_trimMs == 23)
        #expect(spy.changes.last?.ms == 23)
        #expect(spy.changes.last?.committed == true)
    }

    @Test func plusStepsByOne() {
        let (drawer, _) = makeDrawer(trimMs: 24)
        drawer.test_firePlusClick()
        #expect(drawer.test_trimMs == 25)
    }

    @Test func shiftMakesMinusStepByTen() {
        let (drawer, _) = makeDrawer(trimMs: 24)
        drawer.test_shiftModifierOverride = true
        drawer.test_fireMinusClick()
        #expect(drawer.test_trimMs == 14, "⇧ is the coarse step the cut ±10 buttons used to carry")
    }

    @Test func shiftMakesPlusStepByTen() {
        let (drawer, _) = makeDrawer(trimMs: 24)
        drawer.test_shiftModifierOverride = true
        drawer.test_firePlusClick()
        #expect(drawer.test_trimMs == 34)
    }

    @Test func releasingShiftReturnsToTheFineStep() {
        let (drawer, _) = makeDrawer(trimMs: 24)
        drawer.test_shiftModifierOverride = true
        drawer.test_firePlusClick()
        drawer.test_shiftModifierOverride = false
        drawer.test_firePlusClick()
        #expect(drawer.test_trimMs == 35, "the modifier is read per click, never latched")
    }

    @Test func stepperClampsToUsableRange() {
        let (drawer, _) = makeDrawer(trimMs: 495, usableRangeMs: -500...500)
        drawer.test_shiftModifierOverride = true
        drawer.test_firePlusClick()
        #expect(drawer.test_trimMs == 500, "a hard stop at the ceiling, not past it")
    }

    @Test func steppersAutoRepeatWhileHeld() {
        let (drawer, _) = makeDrawer()
        let repeatSpec = drawer.test_stepperRepeat
        #expect(repeatSpec?.isContinuous == true,
                "press-and-hold has to cover the ±500 ms range — one click per ms is not a control")
        #expect((repeatSpec?.delay ?? 0) > 0, "a deliberate single click must never repeat")
        #expect((repeatSpec?.interval ?? 0) > 0)
    }

    // MARK: The value cluster reads as one control around a typeable field

    /// The field is a STOCK bezeled `NSTextField`, not a custom drawing cell.
    /// A `WarmNameFieldCell` version shipped briefly and its hover pencil
    /// reserved trailing width, so the digits jumped sideways as the pointer
    /// crossed the field and the "ms" suffix was stranded beyond the pencil
    /// (both live-found). The bezel also centres the text vertically, which
    /// the custom cell did not.
    @Test func theValueFieldIsAStockBezeledField() {
        let (drawer, _) = makeDrawer()
        #expect(drawer.test_valueFieldIsBezeled,
                "the stock bezel is what says 'type here' — no hover chrome, no layout shift")
    }

    /// Borderless glyphs on the drawer's flat `well` fill dissolved into the
    /// background and did not read as buttons at all (live-found). Each stepper
    /// carries its own stock bezel now.
    @Test func theStepperButtonsCarryTheirOwnBezel() {
        let (drawer, _) = makeDrawer()
        #expect(drawer.test_stepperButtonsAreBezeled,
                "a button with no edge of its own is invisible against a flat drawer")
    }

    /// The unit sits INSIDE the box at rest, and cannot be deleted — not
    /// because keystrokes are policed, but because editing swaps the whole
    /// string for a bare signed number and the suffix is re-rendered on commit.
    @Test func theUnitRestsInsideTheFieldAndCannotBeEdited() {
        let (drawer, _) = makeDrawer(trimMs: -414, isSet: true)
        #expect(drawer.test_valueFieldText == "-414 ms",
                "the resting box reads as a complete value, not a bare number needing a label")

        drawer.test_valueFieldEditor.test_beginEditing()
        #expect(drawer.test_valueFieldEditor.test_fieldText == "-414",
                "editing exposes a PURE number, so a click selects exactly what may be retyped")

        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(drawer.test_valueFieldText == "-414 ms", "…and the suffix comes back on commit")
        #expect(drawer.test_trimMs == -414, "a no-op edit through the suffix round-trips exactly")
    }

    @Test func theCoarseModifierIsAdvertisedInTheBand() {
        let (drawer, _) = makeDrawer()
        #expect(drawer.test_hintText.contains("10 ms"),
                "a modifier nobody is told about does not exist")
    }

    // MARK: Field editing — whole-ms snap, sign round-trip, unparseable input

    @Test func fieldSnapsTypedDecimalsToWholeMs() {
        let (drawer, _) = makeDrawer(trimMs: 0)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("5.7")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(drawer.test_trimMs == 6, "decimals were cut — a typed 5.7 snaps to whole ms")
    }

    @Test func fieldCommitPersists() {
        let (drawer, spy) = makeDrawer(trimMs: 24)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("30")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(drawer.test_trimMs == 30)
        #expect(spy.changes.last?.ms == 30)
        #expect(spy.changes.last?.committed == true, "a typed commit is a discrete gesture, always persisted")
    }

    @Test func fieldTypedNegativeSetsEarlier() {
        let (drawer, _) = makeDrawer(trimMs: 10, isSet: true)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("-15")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(drawer.test_trimMs == -15)
        #expect(drawer.test_valueFieldAXValue == "15 milliseconds earlier")
    }

    @Test func unparseableFieldTextFallsBackToCommittedValue() {
        let (drawer, _) = makeDrawer(trimMs: 24)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("not a number")
        drawer.test_valueFieldEditor.test_endEditing()
        #expect(drawer.test_trimMs == 24)
    }

    @Test func noOpEditDoesNotFlipTheSign() {
        // Click into a NEGATIVE (earlier) value, change nothing, commit — must
        // not flip to positive. The field shows the signed value both at rest
        // and while editing, so an untouched round-trip is a no-op.
        let (drawer, _) = makeDrawer(trimMs: -24, isSet: true)
        drawer.test_valueFieldEditor.test_beginEditing()
        #expect(drawer.test_valueFieldEditor.test_fieldText == "-24")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(drawer.test_trimMs == -24)
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
        drawer.configure(deviceName: "Kitchen Speaker", trimMs: 24, isSet: true,
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
        let (drawer, spy) = makeDrawer(trimMs: 24)
        drawer.test_valueFieldEditor.test_beginEditing()
        drawer.test_valueFieldEditor.test_setFieldText("999")
        _ = drawer.test_valueFieldEditor.test_performCommand(#selector(NSResponder.cancelOperation(_:)))
        #expect(drawer.test_valueFieldEditor.test_fieldText == "24")
        #expect(spy.closeRequests == 0, "the field's own Escape is consumed — it must not also close the drawer")
        #expect(drawer.test_trimMs == 24, "reverted, never committed")
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

/// A REAL Auto Layout pass over the drawer — the coverage hole every
/// caption/field test above shares. Live-found: subviews that missed
/// `translatesAutoresizingMaskIntoConstraints = false` kept their mask
/// constraints, which fought the explicit chain, and the engine resolved the
/// conflict by collapsing views to ZERO height — a blank drawer on real
/// hardware while every model test stayed green.
@Suite @MainActor struct BTSyncDrawerLayoutTests {

    @Test func aRealLayoutPassGivesEverySubviewRealHeight() {
        let drawer = BTSyncDrawerView()
        drawer.configure(deviceName: "Move 2", trimMs: 34, isSet: true,
                         usableRangeMs: -100...500, alignTickActive: false)
        drawer.widthAnchor.constraint(equalToConstant: 623).isActive = true
        drawer.layoutSubtreeIfNeeded()

        #expect(drawer.frame.height == PopoverColumnGrid.syncDrawerHeight)
        for subview in drawer.subviews {
            #expect(subview.frame.height > 0,
                    "\(type(of: subview)) collapsed to zero height — mask constraints are fighting the layout chain")
            #expect(subview.frame.width > 0,
                    "\(type(of: subview)) collapsed to zero width")
        }
    }
}
