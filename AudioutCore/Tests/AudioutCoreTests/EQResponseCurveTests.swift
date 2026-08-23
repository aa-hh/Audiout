// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI

/// `EQResponseCurveView` — the EQ editor's scope.
///
/// Almost everything here is asserted against the PURE `Plan`, never against
/// pixels: the shape, the gridlines and the clamp are plain numbers, so they
/// can be pinned without a window, an appearance or a drawing context. Only
/// the accessibility contract and the token contrast floors touch the view or
/// `Tokens` itself.
@MainActor
@Suite struct EQResponseCurveTests {

    // MARK: The plan — three states

    @Test func flatToneResolvesToTheNeutralHairline() {
        let plan = EQResponseCurveView.resolve(eq: .flat, bypassed: false)
        #expect(plan.state == .flat)
        #expect(!plan.points.isEmpty)
        #expect(plan.points.allSatisfy { $0.y == 0 })
    }

    @Test func aBassBoostResolvesToAShapedCurveThatLifts() {
        let plan = EQResponseCurveView.resolve(eq: DeviceEQ(bassDB: 4), bypassed: false)
        #expect(plan.state == .shaped)
        #expect(plan.points.map { abs($0.y) }.max() ?? 0 > 0)
        // 20 Hz sits below the 120 Hz shelf corner, so the trace starts lifted.
        #expect((plan.points.first?.y ?? 0) > 0)
    }

    @Test func aBypassedShapeKeepsItsShapeAndSaysSo() {
        let plan = EQResponseCurveView.resolve(eq: DeviceEQ(bassDB: 4), bypassed: true)
        #expect(plan.state == .bypassed)
        #expect((plan.points.first?.y ?? 0) > 0)
    }

    /// "Not applied" is only worth saying about shaping that exists — a
    /// dashed straight line would read as a broken instrument, not a bypass.
    @Test func aFlatToneIsFlatEvenWhenBypassed() {
        let plan = EQResponseCurveView.resolve(eq: .flat, bypassed: true)
        #expect(plan.state == .flat)
    }

    // MARK: Gridlines

    @Test func gridlinesSitOnTheTenBandCentres() {
        let plan = EQResponseCurveView.resolve(eq: .flat, bypassed: false)
        #expect(plan.gridX.count == 10)
        #expect(plan.gridX.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(zip(plan.gridX, plan.gridX.dropFirst()).allSatisfy { $0 < $1 })
        let expectedFirst = CGFloat(log10(31.5 / 20.0) / 3.0)
        #expect(abs((plan.gridX.first ?? 0) - expectedFirst) < 0.0001)
    }

    // MARK: The clamp

    @Test func stackedFullScaleBandsStayInsideTheFrame() {
        let eq = DeviceEQ(bandGainsDB: Array(repeating: 12, count: DeviceEQ.bandCount))
        let plan = EQResponseCurveView.resolve(eq: eq, bypassed: false)
        #expect(plan.state == .shaped)
        #expect(plan.points.allSatisfy { abs($0.y) <= 1 })
    }

    // MARK: The spoken summary

    @Test func aFlatToneSpeaksAsFlat() {
        #expect(EQResponseCurveView.summary(eq: .flat, bypassed: false) == "Flat")
    }

    /// The three named points come off the SAME response the trace is plotted
    /// from, so the spoken value can never describe a different curve. The
    /// figure is therefore the response AT 100 Hz (the 120 Hz shelf has
    /// already begun rolling off there), not the Bass slider's own setting.
    // `EQEditorView.gainText` renders the half-dB step it honestly reads at
    // 100 Hz rather than rounding a second time to the nearest whole number,
    // so the spoken point is "2.7 dB", not "3 dB".
    @Test func aShapedToneSpeaksItsThreeNamedPoints() {
        let spoken = EQResponseCurveView.summary(eq: DeviceEQ(bassDB: 4), bypassed: false)
        #expect(spoken == "Bass 2.7 dB, mids 0 dB, treble 0 dB")
        #expect(spoken.hasPrefix("Bass "))
        #expect(spoken.contains("mids"))
        #expect(spoken.contains("treble"))
    }

    @Test func aBypassedToneSaysSoBeforeItsValues() {
        let spoken = EQResponseCurveView.summary(eq: DeviceEQ(bassDB: 4), bypassed: true)
        #expect(spoken.hasPrefix("Not applied. "))
        #expect(spoken.hasSuffix("Bass 2.7 dB, mids 0 dB, treble 0 dB"))
    }

    // MARK: The view

    @Test func theScopeIsNonInteractive() {
        let view = EQResponseCurveView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: EQResponseCurveView.height)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test func theScopeSpeaksAsAnImageWhoseValueIsTheSummary() {
        let view = EQResponseCurveView()
        #expect(view.accessibilityRole() == .image)
        #expect(view.accessibilityLabel() == "Response curve")
        #expect(view.test_axValue == "Flat")

        let eq = DeviceEQ(bassDB: 4)
        view.apply(eq: eq, bypassed: false)
        #expect(view.test_plan.state == .shaped)
        #expect(view.test_axValue == EQResponseCurveView.summary(eq: eq, bypassed: false))

        view.apply(eq: eq, bypassed: true)
        #expect(view.test_plan.state == .bypassed)
        #expect(view.test_axValue == EQResponseCurveView.summary(eq: eq, bypassed: true))
    }

    // MARK: Lazy plan resolution — the 129-point curve is expensive per drag frame

    /// Repeated `apply` calls that land the same tone, and repeated reads of
    /// the resulting plan, must resolve the 129-point curve exactly ONCE — the
    /// laziness that turns a drag's flood of identical re-applies (and every
    /// `draw` pass in between) into a single filter-design cost.
    @Test func repeatedApplyOfTheSameToneResolvesThePlanOnce() {
        let view = EQResponseCurveView()
        let eq = DeviceEQ(bassDB: 4)

        view.apply(eq: eq, bypassed: false)
        view.apply(eq: eq, bypassed: false)
        _ = view.test_plan
        _ = view.test_plan
        #expect(view.test_planResolveCount == 1)
    }

    /// A later `apply` before the plan is ever read must discard the earlier
    /// one for free — only the value that actually gets READ pays the
    /// resolve cost, so a drag frame nobody ever painted costs nothing.
    @Test func aSupersededApplyNeverPaysToResolve() {
        let view = EQResponseCurveView()
        view.apply(eq: DeviceEQ(bassDB: 4), bypassed: false)
        view.apply(eq: DeviceEQ(bassDB: 6), bypassed: false)
        _ = view.test_plan
        #expect(view.test_planResolveCount == 1)
    }

    // MARK: Token contrast on the authored ground
    //
    // WCAG math + forced appearance resolution, copied from
    // `MembershipWellContrastTests` (its helpers are `private` to that file).

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let c = color.usingColorSpace(.sRGB)!
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    private func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let l1 = relativeLuminance(a), l2 = relativeLuminance(b)
        let (hi, lo) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    /// Everything that carries meaning on the scope is measured against the
    /// scope's own ground, because that is what it is drawn on — the ≥3:1
    /// non-text floor, same as every other instrument token.
    @Test func everyTraceToneClearsTheFloorAgainstTheScopeGround() {
        let floor: CGFloat = 3
        let ground = resolved(Tokens.Color.scopeGround, appearanceName: .darkAqua)
        for (name, token) in [("gold", Tokens.Color.gold),
                              ("scopeFlatLine", Tokens.Color.scopeFlatLine),
                              ("scopeBypassLine", Tokens.Color.scopeBypassLine)] {
            let ratio = contrastRatio(resolved(token, appearanceName: .darkAqua), ground)
            #expect(ratio >= floor, "\(name) vs scopeGround = \(ratio):1")
        }
    }

    /// Straight-alpha composite in sRGB. `contrastRatio` takes two OPAQUE
    /// colours, and the ruler's tone is a semi-transparent label colour, so it
    /// has to be laid over the ground before the ratio means anything.
    private func composited(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let t = top.usingColorSpace(.sRGB)!, b = bottom.usingColorSpace(.sRGB)!
        let a = t.alphaComponent
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * a + y * (1 - a) }
        return NSColor(srgbRed: mix(t.redComponent, b.redComponent),
                       green: mix(t.greenComponent, b.greenComponent),
                       blue: mix(t.blueComponent, b.blueComponent),
                       alpha: 1)
    }

    /// The dB ruler is TEXT on the scope's ground, so it answers to the 4.5:1
    /// text floor, not the 3:1 instrument floor — which is exactly why it is
    /// `secondaryLabel` and not the `tertiaryLabel` the band captions use
    /// (tertiary lands near 2.2:1 here).
    @Test func theRulerTextClearsTheTextFloorOnTheScopeGround() {
        for appearance in [NSAppearance.Name.darkAqua, .accessibilityHighContrastDarkAqua] {
            let ground = resolved(Tokens.Color.scopeGround, appearanceName: appearance)
            let ink = resolved(Tokens.Color.secondaryLabel, appearanceName: appearance)
            let ratio = contrastRatio(composited(ink, over: ground), ground)
            #expect(ratio >= 4.5, "ruler text vs scopeGround in \(appearance.rawValue) = \(ratio):1")
        }
    }

    /// The scope's x-axis IS the faders' x-axis: `bandCentreX` maps the `0…1`
    /// gridline into the view's own coordinates, inside the ruler gutter and
    /// the trailing margin, and the last band's 26 pt column has to still fit.
    @Test func bandCentreXMapsTheGridIntoThePlot() {
        let width: CGFloat = 357
        let span = width - EQResponseCurveView.plotLeadingInset - EQResponseCurveView.plotTrailingInset
        let expectedFirst = EQResponseCurveView.plotLeadingInset
            + EQResponseCurveView.bandGridX[0] * span
        #expect(abs(EQResponseCurveView.bandCentreX(index: 0, width: width) - expectedFirst) < 0.001)
        #expect(EQResponseCurveView.bandCentreX(index: 9, width: width) + 13 <= width)
    }

    /// The instrument never themes: the ground is the SAME authored value in
    /// light and dark, which is what lets the view pin its drawing appearance
    /// without the two modes disagreeing.
    @Test func theScopeGroundIsIdenticalInBothAppearances() {
        let dark = resolved(Tokens.Color.scopeGround, appearanceName: .darkAqua)
        let light = resolved(Tokens.Color.scopeGround, appearanceName: .aqua)
        #expect(abs(dark.redComponent - light.redComponent) < 0.001)
        #expect(abs(dark.greenComponent - light.greenComponent) < 0.001)
        #expect(abs(dark.blueComponent - light.blueComponent) < 0.001)
    }
}
