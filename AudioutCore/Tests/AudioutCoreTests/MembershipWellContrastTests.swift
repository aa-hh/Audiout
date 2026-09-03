// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// The Groups screen's surface separation, measured.
///
/// The screen is ONE housing: bare lists on `panel`, and exactly one lifted
/// card per page (`GroupedSectionView` `.card` — `raised`, bounded by a
/// `containerEdge` and ruled inside by `hairline`). Before any of it the
/// checklist painted no surface at all — measured on the real tones, `panel`
/// vs `canvas` is 1.060:1 dark and 1.000:1 light (light resolves both to the
/// same hex), effectively invisible as a boundary.
///
/// Locked constraint (Alec): text colors stay frozen everywhere — separation
/// must come entirely from surfaces
/// (`Tokens.Color.raised`/`.containerEdge`/`.hairline`), never
/// a text-color change. These tests assert the measured floors against
/// `Tokens.Color.panel` the task specifies, in BOTH appearances, using the
/// SAME real WCAG relative-luminance math `AppTetherColorTests` already
/// established for a token contrast floor (its `relativeLuminance`/
/// `contrastRatio` are `private` to that file, so this file
/// carries its own copies rather than reaching across files).
@MainActor
@Suite final class MembershipWellContrastTests: IsolatedSuite {

    // MARK: WCAG contrast math (mirrors AppTetherColorTests' private helpers)

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
    /// appearance (the pattern `SettingsAccentAndHintsTests.resolved(_:
    /// appearanceName:)` already established for this same token module —
    /// `.usingColorSpace(.sRGB)` alone always reads the CURRENT/default
    /// appearance, not a chosen one).
    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    // MARK: Measured floors (task spec: well vs panel >= 1.10:1, hairline vs panel >= 1.25:1)

    @Test func wellVsPanelClearsTheContainerFloorBothAppearances() {
        let floor: CGFloat = 1.10

        let darkWell = resolved(Tokens.Color.well, appearanceName: .darkAqua)
        let darkPanel = resolved(Tokens.Color.panel, appearanceName: .darkAqua)
        let darkRatio = contrastRatio(darkWell, darkPanel)
        #expect(darkRatio >= floor,
                "well vs panel (dark): \(darkRatio):1 below the \(floor):1 container floor")

        let lightWell = resolved(Tokens.Color.well, appearanceName: .aqua)
        let lightPanel = resolved(Tokens.Color.panel, appearanceName: .aqua)
        let lightRatio = contrastRatio(lightWell, lightPanel)
        #expect(lightRatio >= floor,
                "well vs panel (light): \(lightRatio):1 below the \(floor):1 container floor")
    }

    @Test func hairlineVsPanelClearsTheSeparatorFloorBothAppearances() {
        let floor: CGFloat = 1.25

        let darkHairline = resolved(Tokens.Color.hairline, appearanceName: .darkAqua)
        let darkPanel = resolved(Tokens.Color.panel, appearanceName: .darkAqua)
        let darkRatio = contrastRatio(darkHairline, darkPanel)
        #expect(darkRatio >= floor,
                "hairline vs panel (dark): \(darkRatio):1 below the \(floor):1 separator floor")

        let lightHairline = resolved(Tokens.Color.hairline, appearanceName: .aqua)
        let lightPanel = resolved(Tokens.Color.panel, appearanceName: .aqua)
        let lightRatio = contrastRatio(lightHairline, lightPanel)
        #expect(lightRatio >= floor,
                "hairline vs panel (light): \(lightRatio):1 below the \(floor):1 separator floor")
    }

    /// THE CARD'S EDGE, which is what actually separates it. The one card per
    /// page is `raised` on `panel`, and on dark that pair measures 1.07:1 —
    /// UNDER the 1.10:1 surface floor above. The fill is deliberately that
    /// quiet: the card is a lift, not a slab. So the separation rides on the
    /// 1 pt edge instead, and THAT is what this floor pins.
    ///
    /// The edge is `containerEdge`, the heavier of the two hairline weights,
    /// and it may never rank below the `hairline` divider it bounds — a
    /// container's edge reading lighter than the rules inside it inverts the
    /// structure. Dark resolves the two tokens to one value by decision (dark
    /// still has a fill ladder; light's `panel` and `canvas` are the same
    /// hex), so the rank holds at `>=` rather than `>`.
    ///
    /// There is deliberately NO fill-floor assertion for raised-on-panel — it
    /// would fail by design, and adding one would mean either loosening the
    /// floor or brightening the card.
    @Test func containerEdgeClearsTheCardEdgeFloorAndOutranksTheDivider() {
        let floor: CGFloat = 1.25

        for appearanceName in [NSAppearance.Name.darkAqua, .aqua] {
            let raised = resolved(Tokens.Color.raised, appearanceName: appearanceName)
            let edgeRatio = contrastRatio(resolved(Tokens.Color.containerEdge,
                                                  appearanceName: appearanceName), raised)
            #expect(edgeRatio >= floor,
                    Comment(rawValue: "containerEdge vs raised (\(appearanceName.rawValue)): " +
                    "\(edgeRatio):1 below the \(floor):1 floor — the card's fill alone is " +
                    "1.07:1 dark / 1.10:1 light on panel, so a weak edge leaves no card at all"))

            let dividerRatio = contrastRatio(resolved(Tokens.Color.hairline,
                                                      appearanceName: appearanceName), raised)
            #expect(edgeRatio >= dividerRatio,
                    Comment(rawValue: "containerEdge (\(edgeRatio):1) ranks BELOW the hairline " +
                    "divider (\(dividerRatio):1) in \(appearanceName.rawValue) — a container's " +
                    "edge must never read lighter than the rules inside it"))
        }
    }

    /// The dividers INSIDE that card are drawn in `hairline` on the same
    /// `raised` fill, so the lighter weight carries the same separator floor
    /// on the same ground. This is the interior half of the pair above; both
    /// have to hold, or a card loses either its boundary or its rows.
    @Test func hairlineVsRaisedClearsTheDividerFloorInsideACard() {
        let floor: CGFloat = 1.25

        let darkRatio = contrastRatio(resolved(Tokens.Color.hairline, appearanceName: .darkAqua),
                                      resolved(Tokens.Color.raised, appearanceName: .darkAqua))
        #expect(darkRatio >= floor,
                Comment(rawValue: "hairline vs raised (dark): \(darkRatio):1 below the \(floor):1 floor"))

        let lightRatio = contrastRatio(resolved(Tokens.Color.hairline, appearanceName: .aqua),
                                       resolved(Tokens.Color.raised, appearanceName: .aqua))
        #expect(lightRatio >= floor,
                "hairline vs raised (light): \(lightRatio):1 below the \(floor):1 floor")
    }

    // MARK: The rail's idle ink, measured on the surface it actually runs over

    /// `ember` is a NON-TEXT instrument (the rail's idle wire and its member
    /// discs), so it carries the ≥3:1 floor — and in the group editor it is
    /// drawn on the card's `raised` fill, not on `panel`. Measured against
    /// `panel` alone it passed while failing on the ground under it: light
    /// `#AC8C46` was 3.07:1 on `panel` but 2.55:1 on the card (2026-08-12).
    ///
    /// Increase Contrast can't be forced from a test (`Tokens` reads the LIVE
    /// `NSWorkspace` flag, there is no appearance name for it), so this pins the
    /// BASE light value; the IC variant is authored strictly darker still.
    @Test func lightEmberClearsTheNonTextFloorOnBothSurfaces() {
        let floor: CGFloat = 3.0
        let ember = resolved(Tokens.Color.ember, appearanceName: .aqua)

        let onRaised = contrastRatio(ember, resolved(Tokens.Color.raised, appearanceName: .aqua))
        #expect(onRaised >= floor,
                Comment(rawValue: "light ember vs raised: \(onRaised):1 below the \(floor):1 non-text floor — " +
                "the editor's rail runs over the card fill, not the pane"))

        let onPanel = contrastRatio(ember, resolved(Tokens.Color.panel, appearanceName: .aqua))
        #expect(onPanel >= floor,
                "light ember vs panel: \(onPanel):1 below the \(floor):1 non-text floor")
    }

    /// `gold` carries the same ≥3:1 non-text floor on the same two surfaces —
    /// the node discs sit on the card's `raised` fill, where the pre-retune
    /// `#A97F1E` measured only 2.92:1 (2026-08-12). Same base-value-only
    /// caveat as ember's: Increase Contrast can't be forced from a test, and
    /// the IC variant is authored strictly darker still.
    @Test func lightGoldClearsTheNonTextFloorOnBothSurfaces() {
        let floor: CGFloat = 3.0
        let gold = resolved(Tokens.Color.gold, appearanceName: .aqua)

        let onRaised = contrastRatio(gold, resolved(Tokens.Color.raised, appearanceName: .aqua))
        #expect(onRaised >= floor,
                Comment(rawValue: "light gold vs raised: \(onRaised):1 below the \(floor):1 non-text floor — " +
                "the editor's nodes sit on the card fill, not the pane"))

        let onPanel = contrastRatio(gold, resolved(Tokens.Color.panel, appearanceName: .aqua))
        #expect(onPanel >= floor,
                "light gold vs panel: \(onPanel):1 below the \(floor):1 non-text floor")
    }

    /// …and darkening GOLD must not let ember catch up: gold stays the louder
    /// instrument on both axes it can still spend in light mode — chroma, and
    /// (narrowly, since both inks are pinned just over 3:1 on the same ground)
    /// luminance.
    @Test func lightGoldStaysTheLouderInkBesideEmber() {
        let gold = resolved(Tokens.Color.gold, appearanceName: .aqua)
        let ember = resolved(Tokens.Color.ember, appearanceName: .aqua)

        #expect(gold.saturationComponent > ember.saturationComponent,
                "gold must stay the more saturated ink")
        #expect(relativeLuminance(gold) > relativeLuminance(ember),
                Comment(rawValue: "gold \(relativeLuminance(gold)) vs ember \(relativeLuminance(ember)) — " +
                "gold must not converge with (or drop below) its own dim companion"))
    }

    /// …and darkening it must not walk it into `gold`. The two are the rail's
    /// idle/armed pair, so they have to stay visibly different inks. In LIGHT
    /// mode that separation is CHROMA, not luminance: nothing clearing 3:1 on
    /// `well` can also be lighter than light gold (see `Tokens`' rationale).
    @Test func lightEmberStaysTheDullerInkBesideGold() {
        let ember = resolved(Tokens.Color.ember, appearanceName: .aqua)
        let gold = resolved(Tokens.Color.gold, appearanceName: .aqua)

        #expect(gold.saturationComponent - ember.saturationComponent >= 0.15,
                Comment(rawValue: "ember \(ember.saturationComponent) vs gold \(gold.saturationComponent) — " +
                "ember is gold's DIM companion; converged chroma makes the idle rail " +
                "read as the live one"))
        #expect(abs(gold.hueComponent - ember.hueComponent) <= 0.03,
                "…while staying in the same warm family, not becoming a second hue")
    }

    // MARK: Structural — the editor's checklist actually wears the new surface

    /// A group editor showing two members over a four-device candidate list,
    /// laid out at a realistic pane size — enough rows to exercise the
    /// hairline-between-adjacent-rows path.
    private func makeEditor() throws -> GroupEditorViewController {
        let devices = [
            Device(id: "a", name: "Alpha", kind: .generic, isAvailable: true),
            Device(id: "b", name: "Bravo", kind: .generic, isAvailable: true),
            Device(id: "c", name: "Charlie", kind: .generic, isAvailable: true),
            Device(id: "d", name: "Delta", kind: .generic, isAvailable: true),
        ]
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let controller = GroupController(backend: MockBackend(fleet: []),
                                         store: GroupStore(directory: dir),
                                         loadPersisted: false)
        let group = try controller.createGroup(name: "Downstairs",
                                               memberIDs: ["a", "b"],
                                               memberVolumes: [:]).group
        let editor = GroupEditorViewController(groupController: controller)
        editor.loadView()
        editor.show(groupID: group.id, devices: devices)
        editor.view.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        editor.view.layoutSubtreeIfNeeded()
        return editor
    }

    /// The warm pane's checklist gets the recessed well + hairlines: the well
    /// is kept in sync with the current candidate rows (4 devices here) and
    /// sits BEHIND the row stack in z-order, so it never steals a row's click.
    @Test func warmPaneChecklistHasARecessedWellBehindTheRows() throws {
        let editor = try makeEditor()
        #expect(editor.test_membershipWellRowCount == 4,
                "the well is fed one entry per candidate row")
        #expect(editor.test_membershipWellIsBehindStack,
                "the well sits BEHIND the stack in z-order")
    }

    /// A membership toggle rebuilds the row list (an unchecked unavailable
    /// device can disappear) — the well must be re-pointed at the CURRENT
    /// rows on every rebuild, not just the initial `show`.
    @Test func wellRowCountFollowsARebuild() throws {
        let editor = try makeEditor()
        #expect(editor.test_membershipWellRowCount == 4)
        editor.test_setMembership(true, for: "c")
        #expect(editor.test_membershipWellRowCount == 4,
                "still 4 — no device dropped out of the candidate list")
    }
}
