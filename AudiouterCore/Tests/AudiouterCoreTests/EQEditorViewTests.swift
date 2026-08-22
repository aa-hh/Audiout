// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI

/// `EQEditorView` — the tone editor's own controls, independent of either
/// host pane (`DeviceDetailViewController`/`MainOutDetailViewController`
/// exercise it through their own suites). Covers the centre notch, magnetic
/// detent, and 0.5 dB / 0.05 quantization, plus the narrower Balance slider
/// with L/R labels.
@MainActor
@Suite struct EQEditorViewTests {

    /// A bare editor, no host pane — its own constraints are enough to lay
    /// it out once given a width, the same way `DeviceDetailViewTests`
    /// forces `AppSurfaceController.minimumContentSize` on the pane.
    private func makeHostedEditor(width: CGFloat = 300) -> EQEditorView {
        let editor = EQEditorView()
        editor.widthAnchor.constraint(equalToConstant: width).isActive = true
        editor.layoutSubtreeIfNeeded()
        return editor
    }

    // MARK: Centre tick (every bipolar slider, not just Balance)

    @Test func balanceHasACentreTick() {
        let editor = makeHostedEditor()
        #expect(editor.test_balanceHasCentreTick)
    }

    @Test func bassHasACentreTick() {
        let editor = makeHostedEditor()
        #expect(editor.test_bassHasCentreTick)
    }

    @Test func trebleHasACentreTick() {
        let editor = makeHostedEditor()
        #expect(editor.test_trebleHasCentreTick)
    }

    @Test func aBandSliderHasACentreTick() {
        let editor = makeHostedEditor()
        #expect(editor.test_bandHasCentreTick(0))
    }

    // MARK: Quantization — every new drag lands on a 0.5 dB / 0.05 step

    @Test func draggingBassSnapsToTheNearestHalfDB() {
        let editor = makeHostedEditor()
        editor.test_dragBass(to: 3.1594182027649786)
        #expect(editor.currentEQ.bassDB == 3.0)
    }

    @Test func draggingBalanceSnapsToTheNearestZeroPointZeroFive() {
        let editor = makeHostedEditor()
        editor.test_dragBalance(to: 0.213)
        #expect(editor.currentEQ.balance == 0.2)
    }

    // MARK: Magnetic detent — pointer gestures only

    @Test func aPointerDragInsideTheDetentRadiusSnapsToZero() {
        let editor = makeHostedEditor()
        editor.test_pointerGestureOverride = true
        editor.test_dragBass(to: 0.4)
        #expect(editor.currentEQ.bassDB == 0)
    }

    @Test func aPointerDragOutsideTheDetentRadiusOnlyQuantizes() {
        let editor = makeHostedEditor()
        editor.test_pointerGestureOverride = true
        editor.test_dragBass(to: 0.9)
        #expect(editor.currentEQ.bassDB == 1.0)
    }

    /// No override → the live-event read, which is `nil` headless — the same
    /// shape a keyboard/VoiceOver step arrives as. It must quantize (already
    /// a valid half-dB step here, so it "survives" unchanged) but never
    /// detent, or a keyboard nudge toward 0 would get pulled the rest of the
    /// way there against the user's own intent.
    @Test func aKeyboardStepInsideTheDetentRadiusIsNotPulledToZero() {
        let editor = makeHostedEditor()
        editor.test_dragBass(to: 0.5)
        #expect(editor.currentEQ.bassDB == 0.5)
    }

    // MARK: Readout — halves print, not just whole numbers

    @Test func theReadoutPrintsAHalfDBStep() {
        let editor = makeHostedEditor()
        editor.test_dragBass(to: 3.5)
        #expect(editor.test_bassReadout == "3.5 dB")
    }

    @Test func theReadoutPrintsAWholeDBStep() {
        let editor = makeHostedEditor()
        editor.test_dragBass(to: 4)
        #expect(editor.test_bassReadout == "4 dB")
    }

    // MARK: Balance readout text — the three shapes

    @Test func balanceReadoutTextAtRestReadsCenter() {
        #expect(EQEditorView.balanceReadoutText(0) == "Center")
    }

    @Test func balanceReadoutTextLeftOfCentreNamesL() {
        #expect(EQEditorView.balanceReadoutText(-0.3) == "L 30%")
    }

    @Test func balanceReadoutTextRightOfCentreNamesR() {
        #expect(EQEditorView.balanceReadoutText(0.2) == "R 20%")
    }

    /// The printed readout and the spoken (accessibility) value are two
    /// different sentences for the SAME model, so they must never disagree
    /// about which side a value has moved to.
    @Test func thePrintedReadoutAndTheSpokenValueAgreeOnDirection() {
        let editor = makeHostedEditor()
        editor.test_dragBalance(to: -0.3)
        #expect(editor.test_balanceReadout == "L 30%")
        #expect(editor.test_balanceAXValue == "left 30 percent")

        editor.test_dragBalance(to: 0.2)
        #expect(editor.test_balanceReadout == "R 20%")
        #expect(editor.test_balanceAXValue == "right 20 percent")

        editor.test_dragBalance(to: 0)
        #expect(editor.test_balanceReadout == "Center")
        #expect(editor.test_balanceAXValue == "center")
    }

    // MARK: Balance layout — narrower, with aligned caption/readout columns

    @Test func theBalanceSliderIsNarrowerThanBassTreble() {
        let editor = makeHostedEditor()
        #expect(editor.test_balanceSliderFrame.width < editor.test_bassSliderFrame.width)
    }

    @Test func balanceCaptionAndReadoutColumnsAlignWithBass() {
        let editor = makeHostedEditor()
        #expect(editor.test_balanceCaptionFrame.minX == editor.test_bassCaptionFrame.minX)
        #expect(editor.test_balanceCaptionFrame.width == editor.test_bassCaptionFrame.width)
        #expect(editor.test_balanceReadoutFrame.minX == editor.test_bassReadoutFrame.minX)
        #expect(editor.test_balanceReadoutFrame.width == editor.test_bassReadoutFrame.width)
    }
}
