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

    private let isolation = TestIsolation(owner: "EQEditorViewTests")

    /// A bare editor, no host pane — its own constraints are enough to lay
    /// it out once given a width, the same way `DeviceDetailViewTests`
    /// forces `AppSurfaceController.minimumContentSize` on the pane.
    /// Backed by an isolated store so no test ever reads or writes `.standard`.
    private func makeHostedEditor(width: CGFloat = 300) -> EQEditorView {
        let editor = EQEditorView(settings: AppSettings(defaults: isolation.isolatedDefaults))
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

    /// The loudness row now holds the checkbox alone: Reset moved onto the
    /// host's "Equalizer" title line. Half-point tolerance, no absolute
    /// widths — the Groups-pane rounding grid varies per run.
    @Test func loudnessRowIsTheCheckboxAlone() {
        let editor = makeHostedEditor(width: 357)
        #expect(abs(editor.test_loudnessCheckboxFrame.minX - editor.test_bassCaptionFrame.minX) <= 0.5)

        func containsResetButton(_ view: NSView) -> Bool {
            if let button = view as? NSButton, button.title == "Reset" { return true }
            return view.subviews.contains(where: containsResetButton)
        }
        #expect(!containsResetButton(editor))
    }

    // MARK: The Advanced section row — hairline, hint, readout, persistence

    @Test func advancedReadoutIsBlankWhenFlat() {
        let editor = makeHostedEditor()
        #expect(editor.test_advancedReadoutText == "")
    }

    @Test func advancedReadoutCountsOneShapedBand() {
        let editor = makeHostedEditor()
        editor.apply(eq: DeviceEQ(bandGainsDB: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0]), bypassReason: nil)
        #expect(editor.test_advancedReadoutText == "1 set")
    }

    @Test func advancedReadoutCountsThreeShapedBands() {
        let editor = makeHostedEditor()
        editor.apply(eq: DeviceEQ(bandGainsDB: [3, 0, -2, 0, 0, 1, 0, 0, 0, 0]), bypassReason: nil)
        #expect(editor.test_advancedReadoutText == "3 set")
    }

    @Test func advancedHintNamesTheBandCount() {
        let editor = makeHostedEditor()
        #expect(editor.test_advancedHintText == "10 bands")
    }

    /// The hairline sits between the loudness row and the Advanced row, and
    /// spans the same content lane the caption/readout columns anchor to.
    /// Editor coordinates are NOT flipped, so "above" means a larger Y.
    @Test func hairlineSitsBetweenLoudnessAndAdvanced() {
        let editor = makeHostedEditor(width: 357)
        let hairline = editor.test_advancedHairlineFrame
        let checkbox = editor.test_loudnessCheckboxFrame
        let row = editor.test_advancedRowFrame
        #expect(hairline.minY >= row.maxY - 0.5)
        #expect(hairline.maxY <= checkbox.minY + 0.5)
        #expect(abs(hairline.minX - editor.test_bassCaptionFrame.minX) <= 0.5)
        #expect(abs(hairline.maxX - editor.test_bassReadoutFrame.maxX) <= 0.5)
    }

    @Test func advancedReadoutColumnAlignsWithBass() {
        let editor = makeHostedEditor(width: 357)
        #expect(abs(editor.test_advancedReadoutFrame.maxX - editor.test_bassReadoutFrame.maxX) <= 0.5)
    }

    @Test func aFreshStoreShipsCollapsed() {
        let editor = makeHostedEditor()
        #expect(editor.test_advancedExpanded == false)
    }

    @Test func clickingTheTitleTogglesExpansionLikeTheTriangle() {
        let editor = makeHostedEditor()
        editor.test_fireAdvancedTitleClick()
        #expect(editor.test_advancedExpanded == true)
        editor.test_fireAdvancedTitleClick()
        #expect(editor.test_advancedExpanded == false)
    }

    @Test func expandedStatePersistsAcrossASecondEditorOnTheSameStore() {
        let editorA = makeHostedEditor()
        editorA.test_fireAdvancedTitleClick()
        #expect(editorA.test_advancedExpanded == true)
        #expect(AppSettings(defaults: isolation.isolatedDefaults).eqAdvancedExpanded == true)

        let editorB = EQEditorView(settings: AppSettings(defaults: isolation.isolatedDefaults))
        editorB.widthAnchor.constraint(equalToConstant: 300).isActive = true
        editorB.layoutSubtreeIfNeeded()
        #expect(editorB.test_advancedExpanded == true)
    }

    @Test func applyingAShapedEQToACollapsedEditorLeavesItCollapsed() {
        let editor = makeHostedEditor()
        editor.apply(eq: DeviceEQ(bandGainsDB: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0]), bypassReason: nil)
        #expect(editor.test_advancedExpanded == false)
    }

    @Test func spokenLabelComposesBandCountShapedCountAndState() {
        let editor = makeHostedEditor()
        #expect(editor.test_advancedAXLabel == "Advanced, 10 bands, collapsed")

        editor.apply(eq: DeviceEQ(bandGainsDB: [3, 0, -2, 0, 0, 1, 0, 0, 0, 0]), bypassReason: nil)
        #expect(editor.test_advancedAXLabel == "Advanced, 10 bands, 3 set, collapsed")

        editor.test_fireAdvancedTitleClick()
        #expect(editor.test_advancedAXLabel?.hasSuffix(", expanded") == true)
    }

    // MARK: The scope lives in the Advanced fold, on the faders' x-axis
    //
    // Frames only ever compared RELATIVELY (the Groups-pane rounding-grid
    // trap), and the editor is not flipped, so "below" means a smaller y.

    /// The resting card is the simple tier alone — no scope, and none of the
    /// old centred axis caption that used to sit under it.
    @Test func theRestingCardHasNoScope() {
        let editor = makeHostedEditor(width: 357)
        #expect(editor.test_curveFrame == nil)
        #expect(!labels(in: editor).contains { $0.stringValue == "+12 dB · −12 dB" })
    }

    @Test func openingAdvancedRevealsTheScopeAboveTheFaders() throws {
        let editor = makeHostedEditor(width: 357)
        editor.test_fireAdvancedClick()
        editor.layoutSubtreeIfNeeded()

        let curve = try #require(editor.test_curveFrame)
        #expect(abs(curve.width - editor.bounds.width) <= 0.5)
        #expect(curve.maxY <= editor.test_advancedRowFrame.minY + 0.5)
        let topFader = try #require(editor.test_bandSliderFrame(0))
        #expect(topFader.maxY <= curve.minY + 0.5)
    }

    /// The whole point of the move: each fader stands under the gridline for
    /// its own band, so the trace and the control that shapes it share one
    /// x-axis.
    @Test func faderColumnsCentreOnTheScopesGridLines() throws {
        let editor = makeHostedEditor(width: 357)
        editor.test_fireAdvancedClick()
        editor.layoutSubtreeIfNeeded()

        let curve = try #require(editor.test_curveFrame)
        for index in 0..<DeviceEQ.bandCount {
            let centre = try #require(editor.test_bandColumnCenterX(index))
            let gridline = curve.minX
                + EQResponseCurveView.bandCentreX(index: index, width: curve.width)
            #expect(abs(centre - gridline) <= 0.5, "band \(index): \(centre) vs \(gridline)")
        }
    }

    /// "Hz" is the unit for the row of band numbers, so it parks in the
    /// scope's ruler gutter rather than becoming an eleventh column.
    @Test func theHzLegendSitsInTheRulerGutter() throws {
        let editor = makeHostedEditor(width: 357)
        editor.test_fireAdvancedClick()
        editor.layoutSubtreeIfNeeded()

        let curve = try #require(editor.test_curveFrame)
        let legend = try #require(editor.test_hzLegendFrame)
        #expect(abs(legend.midX - (curve.minX + EQResponseCurveView.plotLeadingInset / 2)) <= 0.5)
        #expect(legend.maxX <= curve.minX + EQResponseCurveView.plotLeadingInset + 0.5)
    }

    private func labels(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }
}
