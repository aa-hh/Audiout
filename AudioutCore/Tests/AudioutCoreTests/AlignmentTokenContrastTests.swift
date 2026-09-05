// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutSharedUI
@testable import AudioutPopoverUI

/// Wizard-stage v2 spec §2.1/§6: the alignment wizard's stage instruments in
/// `Tokens.Color`, measured against the same floors the spec's
/// table states. `MembershipWellContrastTests` idiom (own private
/// `relativeLuminance`/`contrastRatio`/`resolved` helpers, deliberately not
/// shared across files).
///
/// Nested into `SerializedSharedState` (see `SerializedSharedStateSuite.swift`):
/// the Increase-Contrast sweeps below drive
/// `Tokens.test_increaseContrastOverride`, which is global to the process, so
/// running alongside another suite that does the same would be a real race.
@MainActor
extension SerializedSharedState {

@Suite final class AlignmentTokenContrastTests: IsolatedSuite {

    deinit {
        // Process-global test seam; restore it unconditionally so no other
        // test in the process inherits a forced Increase-Contrast reading.
        Tokens.test_increaseContrastOverride = nil
    }

    /// Runs `body` once with Increase Contrast forced off and once forced on,
    /// then restores the live reading.
    private func acrossIncreaseContrast(_ body: (Bool) -> Void) {
        defer { Tokens.test_increaseContrastOverride = nil }
        for increaseContrast in [false, true] {
            Tokens.test_increaseContrastOverride = increaseContrast
            body(increaseContrast)
        }
    }

    // MARK: WCAG contrast math (mirrors MembershipWellContrastTests' private helpers)

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

    /// Force-resolves a `Tokens.Color` dynamic `NSColor` under a specific
    /// appearance (the pattern `MembershipWellContrastTests` established for
    /// this same token module).
    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    // MARK: stagePlate's on-plate instruments (spec §2.1)

    @Test func stageRuleClearsTheNonTextFloorOnThePlateBothAppearances() {
        let floor: CGFloat = 3.0

        let dark = contrastRatio(resolved(Tokens.Color.stageRule, appearanceName: .darkAqua),
                                 resolved(Tokens.Color.stagePlate, appearanceName: .darkAqua))
        #expect(dark >= floor, "stageRule vs stagePlate (dark): \(dark):1 below the \(floor):1 floor")

        let light = contrastRatio(resolved(Tokens.Color.stageRule, appearanceName: .aqua),
                                  resolved(Tokens.Color.stagePlate, appearanceName: .aqua))
        #expect(light >= floor, "stageRule vs stagePlate (light): \(light):1 below the \(floor):1 floor")
    }

    @Test func stageInkClearsTheValueStampFloorOnThePlateBothAppearances() {
        let floor: CGFloat = 16.0

        let dark = contrastRatio(resolved(Tokens.Color.stageInk, appearanceName: .darkAqua),
                                 resolved(Tokens.Color.stagePlate, appearanceName: .darkAqua))
        #expect(dark >= floor, "stageInk vs stagePlate (dark): \(dark):1 below the \(floor):1 floor")

        let light = contrastRatio(resolved(Tokens.Color.stageInk, appearanceName: .aqua),
                                  resolved(Tokens.Color.stagePlate, appearanceName: .aqua))
        #expect(light >= floor, "stageInk vs stagePlate (light): \(light):1 below the \(floor):1 floor")
    }

    @Test func wireCoreRingAndFuseWhiteClearTheNonTextFloorOnThePlateBothAppearances() {
        let floor: CGFloat = 3.0

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let plate = resolved(Tokens.Color.stagePlate, appearanceName: appearance)

            let sync = contrastRatio(resolved(Tokens.Color.wireCore, appearanceName: appearance), plate)
            #expect(sync >= floor, "wireCore vs stagePlate (\(appearance.rawValue)): \(sync):1 below \(floor):1")

            let fuse = contrastRatio(resolved(Tokens.Color.fuseWhite, appearanceName: appearance), plate)
            #expect(fuse >= floor, "fuseWhite vs stagePlate (\(appearance.rawValue)): \(fuse):1 below \(floor):1")
        }

        // The reference light is measured ONCE, outside the loop: the stage
        // pins `ring` to its dark hex in both appearances.
        let reference = contrastRatio(resolved(Tokens.Color.ring, appearanceName: .darkAqua),
                                      resolved(Tokens.Color.stagePlate, appearanceName: .darkAqua))
        #expect(reference >= floor, "the pinned ring vs stagePlate: \(reference):1 below \(floor):1")
    }

    // MARK: rim — required >=3:1 vs BOTH raised and canvas, both appearances (decision 12)

    @Test func plateRimClearsTheRimFloorVsRaisedAndCanvasBothAppearances() {
        let floor: CGFloat = 3.0

        let darkRim = resolved(Tokens.Color.rim, appearanceName: .darkAqua)
        let darkVsRaised = contrastRatio(darkRim, resolved(Tokens.Color.raised, appearanceName: .darkAqua))
        #expect(darkVsRaised >= floor, "rim vs raised (dark): \(darkVsRaised):1 below the \(floor):1 floor")
        let darkVsCanvas = contrastRatio(darkRim, resolved(Tokens.Color.canvas, appearanceName: .darkAqua))
        #expect(darkVsCanvas >= floor, "rim vs canvas (dark): \(darkVsCanvas):1 below the \(floor):1 floor")

        let lightRim = resolved(Tokens.Color.rim, appearanceName: .aqua)
        let lightVsRaised = contrastRatio(lightRim, resolved(Tokens.Color.raised, appearanceName: .aqua))
        #expect(lightVsRaised >= floor, "rim vs raised (light): \(lightVsRaised):1 below the \(floor):1 floor")
        let lightVsCanvas = contrastRatio(lightRim, resolved(Tokens.Color.canvas, appearanceName: .aqua))
        #expect(lightVsCanvas >= floor, "rim vs canvas (light): \(lightVsCanvas):1 below the \(floor):1 floor")
    }

    // MARK: The primary plate — bright gold + black ink, ONE value everywhere

    /// The wizard's primary plates (Start / Sounds right / Try again / Done)
    /// fill with ``Tokens/Color/gold``'s DARK-appearance value in BOTH
    /// appearances and set their title in ``Tokens/Color/inkOnFill`` (owner
    /// ruling 2026-08-24), which is why this measures the pair ONCE rather
    /// than per appearance: the plate has only one, and the cell pins the ink
    /// with `primaryInkColor` for the same reason. Measured 10.18:1.
    @Test func inkOnFillClearsTheBodyFloorOnThePinnedPrimaryPlateGold() {
        let floor: CGFloat = 4.5
        let fill = resolved(Tokens.Color.gold, appearanceName: .darkAqua)
        let ink = resolved(Tokens.Color.inkOnFill, appearanceName: .darkAqua)
        let ratio = contrastRatio(ink, fill)
        #expect(ratio >= floor,
                "inkOnFill vs the pinned primary-plate gold: \(ratio):1 below the \(floor):1 floor")
    }

    /// The pair above, swept across BOTH Increase-Contrast readings and BOTH
    /// window appearances — the seam the single measurement above does not
    /// drive, and the seam this ink's pinning exists for. `inkOnFill` goes WHITE
    /// under light + Increase Contrast: right on the light-Increase-Contrast
    /// gold it was authored for, 1.84:1 on the dark gold this plate actually
    /// draws. Both halves are read from the cell, so a lost pinning fails here
    /// rather than in someone's eyes.
    @Test func primaryPlateInkClearsTheBodyFloorAcrossTheIncreaseContrastSeam() {
        let floor: CGFloat = 4.5
        acrossIncreaseContrast { increaseContrast in
            for window in [NSAppearance.Name.aqua, .darkAqua] {
                var ratio: CGFloat = 0
                NSAppearance(named: window)?.performAsCurrentDrawingAppearance {
                    ratio = self.contrastRatio(AlignmentPlateCell.primaryInkColor,
                                               AlignmentPlateCell.primaryFillColor)
                }
                #expect(ratio >= floor,
                        """
                        the primary plate's ink on its gold \
                        (\(window.rawValue), Increase Contrast \(increaseContrast)): \
                        \(ratio):1 below the \(floor):1 floor
                        """)
            }
        }
    }

    // MARK: The stage plate's bezel — a fixed dark instrument, a pinned edge

    /// `AlignmentStageView` draws the plate's 1pt bezel in `rim`, at 0.35 alpha
    /// under a dark window and 0.9 under a light one. The alpha follows the
    /// window because the heavier edge is what separates a black plate from
    /// white paper — but the plate itself is FIXED dark in both appearances, so
    /// the ratio that matters is edge against `stagePlate`, and the edge's
    /// COLOUR has to come from the appearance the plate actually is.
    ///
    /// The light window is what this measures: the dark one draws the bezel at
    /// 0.35 deliberately faint inside a dark chassis and has no floor. Left
    /// resolving with the window, the light hexes gave 3.47:1 with Increase
    /// Contrast off and 2.89:1 with it ON: the setting a user turns on to read
    /// better made the bezel worse and pushed it under the floor. The last
    /// assertion forbids that direction outright, floor or no floor.
    @Test func stagePlateEdgeClearsTheNonTextFloorAcrossTheIncreaseContrastSeam() throws {
        let floor: CGFloat = 3.0
        // Mirrors `AlignmentStageView.stampColors`' light-window branch.
        let lightWindowAlpha: CGFloat = 0.9

        var measured: [Bool: CGFloat] = [:]
        acrossIncreaseContrast { increaseContrast in
            let plate = self.resolved(Tokens.Color.stagePlate, appearanceName: .darkAqua)
            var edge = Tokens.Color.rim
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                edge = AlignmentStageView.plateEdge.usingColorSpace(.sRGB) ?? edge
            }
            let composited = edge.blended(withFraction: 1 - lightWindowAlpha, of: plate) ?? edge
            measured[increaseContrast] = self.contrastRatio(composited, plate)
        }

        let off = try #require(measured[false])
        let on = try #require(measured[true])
        #expect(off >= floor, "the stage plate's bezel: \(off):1 below the \(floor):1 floor")
        #expect(on >= floor,
                "the stage plate's bezel under Increase Contrast: \(on):1 below the \(floor):1 floor")
        #expect(on >= off,
                "Increase Contrast LOWERED the stage plate's bezel contrast, \(off):1 -> \(on):1")
    }

    // MARK: The Deep companions — themed chrome, light grounds only (spec §2.1)

    @Test func lightSyncSignalDeepClearsTheFloorOnLightCanvasAndRaised() {
        let floor: CGFloat = 3.0
        let deep = resolved(Tokens.Color.syncSignalDeep, appearanceName: .aqua)

        let vsCanvas = contrastRatio(deep, resolved(Tokens.Color.canvas, appearanceName: .aqua))
        #expect(vsCanvas >= floor, "syncSignalDeep vs light canvas: \(vsCanvas):1 below the \(floor):1 floor")

        let vsRaised = contrastRatio(deep, resolved(Tokens.Color.raised, appearanceName: .aqua))
        #expect(vsRaised >= floor, "syncSignalDeep vs light raised: \(vsRaised):1 below the \(floor):1 floor")
    }

    /// `ring` carries its own light hex, so the reference plate needs no Deep
    /// companion — but its rim draws at `lightRimAlpha` 0.9, so what has to
    /// clear the floor is the COMPOSITE over the light ground, not the token.
    @Test func lightRingAtTheRimAlphaClearsTheFloorOnTheLightGround() throws {
        let floor: CGFloat = 3.0
        let canvas = resolved(Tokens.Color.canvas, appearanceName: .aqua)
        let well = resolved(Tokens.Color.well, appearanceName: .aqua)
        let ring = resolved(Tokens.Color.ring, appearanceName: .aqua)
        let composited = try #require(ring.blended(withFraction: 0.1, of: canvas))

        let vsCanvas = contrastRatio(composited, canvas)
        #expect(vsCanvas >= floor, "ring @0.9 vs light canvas: \(vsCanvas):1 below the \(floor):1 floor")

        let vsWell = contrastRatio(composited, well)
        #expect(vsWell >= floor, "ring @0.9 vs light well: \(vsWell):1 below the \(floor):1 floor")
    }
}

}
