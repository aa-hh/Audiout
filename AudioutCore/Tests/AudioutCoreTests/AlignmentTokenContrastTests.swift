// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutSharedUI

/// Wizard-stage v2 spec §2.1/§6: the alignment wizard's eight new
/// `Tokens.Color` instruments, measured against the same floors the spec's
/// table states. `MembershipWellContrastTests` idiom (own private
/// `relativeLuminance`/`contrastRatio`/`resolved` helpers, deliberately not
/// shared across files).
@MainActor
@Suite final class AlignmentTokenContrastTests: IsolatedSuite {

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

    @Test func syncPartyAndFuseSignalsClearTheNonTextFloorOnThePlateBothAppearances() {
        let floor: CGFloat = 3.0

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let plate = resolved(Tokens.Color.stagePlate, appearanceName: appearance)

            let sync = contrastRatio(resolved(Tokens.Color.wireCore, appearanceName: appearance), plate)
            #expect(sync >= floor, "wireCore vs stagePlate (\(appearance.rawValue)): \(sync):1 below \(floor):1")

            let party = contrastRatio(resolved(Tokens.Color.party, appearanceName: appearance), plate)
            #expect(party >= floor, "party vs stagePlate (\(appearance.rawValue)): \(party):1 below \(floor):1")

            let fuse = contrastRatio(resolved(Tokens.Color.fuseWhite, appearanceName: appearance), plate)
            #expect(fuse >= floor, "fuseWhite vs stagePlate (\(appearance.rawValue)): \(fuse):1 below \(floor):1")
        }
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
    /// than per appearance: the plate has only one. Measured 10.18:1.
    @Test func inkOnFillClearsTheBodyFloorOnThePinnedPrimaryPlateGold() {
        let floor: CGFloat = 4.5
        let fill = resolved(Tokens.Color.gold, appearanceName: .darkAqua)
        let ink = resolved(Tokens.Color.inkOnFill, appearanceName: .darkAqua)
        let ratio = contrastRatio(ink, fill)
        #expect(ratio >= floor,
                "inkOnFill vs the pinned primary-plate gold: \(ratio):1 below the \(floor):1 floor")
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

    @Test func lightPartySignalDeepClearsTheFloorOnLightCanvasAndRaised() {
        let floor: CGFloat = 3.0
        let deep = resolved(Tokens.Color.partyRampDeep, appearanceName: .aqua)

        let vsCanvas = contrastRatio(deep, resolved(Tokens.Color.canvas, appearanceName: .aqua))
        #expect(vsCanvas >= floor, "partyRampDeep vs light canvas: \(vsCanvas):1 below the \(floor):1 floor")

        let vsRaised = contrastRatio(deep, resolved(Tokens.Color.raised, appearanceName: .aqua))
        #expect(vsRaised >= floor, "partyRampDeep vs light raised: \(vsRaised):1 below the \(floor):1 floor")
    }
}
