// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// T5 — the membership checklist's recessed container + hairline dividers.
///
/// Before this task the checklist (`GroupEditorViewController`'s
/// `membershipStack`) painted no surface of its own at all: no background, no
/// divider, nothing — measured on the real post-T6 tones, `panel` vs `canvas`
/// is ~1.06:1 dark / ~1.08:1 light, effectively invisible as a boundary.
///
/// Locked constraint (Alec): text colors stay frozen everywhere — separation
/// must come entirely from surfaces (`Tokens.Color.well`/`.hairline`), never a
/// text-color change. These tests assert the two measured floors against
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

    /// FOR THE RECORD (design review 2026-07-25): the inline rename field is
    /// filled with `raised` and sits beside the icon well, which is filled with
    /// the same token, inside a header section filled with `well`. That pairing
    /// is the whole reason the two header controls read as a pair — so the
    /// separation between the control fill and the section fill gets the same
    /// measured floor the other surface pairs carry. Measured: 1.186:1 dark /
    /// 1.251:1 light.
    @Test func raisedVsWellClearsTheControlOnSectionFloorBothAppearances() {
        let floor: CGFloat = 1.15

        let darkRatio = contrastRatio(resolved(Tokens.Color.raised, appearanceName: .darkAqua),
                                      resolved(Tokens.Color.well, appearanceName: .darkAqua))
        #expect(darkRatio >= floor,
                Comment(rawValue: "raised vs well (dark): \(darkRatio):1 below the \(floor):1 floor — " +
                "the rename field/icon well would sink into the section they sit in"))

        let lightRatio = contrastRatio(resolved(Tokens.Color.raised, appearanceName: .aqua),
                                       resolved(Tokens.Color.well, appearanceName: .aqua))
        #expect(lightRatio >= floor,
                "raised vs well (light): \(lightRatio):1 below the \(floor):1 floor")
    }

    // MARK: The rail's idle ink, measured on the surface it actually runs over

    /// `ember` is a NON-TEXT instrument (the rail's idle wire and its member
    /// discs), so it carries the ≥3:1 floor — and in the group editor it is
    /// drawn on the section's `well` fill, not on `panel`. Measured against
    /// `panel` alone it passed while failing on the ground under it: light
    /// `#AC8C46` was 3.07:1 on `panel` but 2.55:1 on `well` (2026-08-12).
    ///
    /// Increase Contrast can't be forced from a test (`Tokens` reads the LIVE
    /// `NSWorkspace` flag, there is no appearance name for it), so this pins the
    /// BASE light value; the IC variant is authored strictly darker still.
    @Test func lightEmberClearsTheNonTextFloorOnBothSurfaces() {
        let floor: CGFloat = 3.0
        let ember = resolved(Tokens.Color.ember, appearanceName: .aqua)

        let onWell = contrastRatio(ember, resolved(Tokens.Color.well, appearanceName: .aqua))
        #expect(onWell >= floor,
                Comment(rawValue: "light ember vs well: \(onWell):1 below the \(floor):1 non-text floor — " +
                "the editor's rail runs over the section fill, not the pane"))

        let onPanel = contrastRatio(ember, resolved(Tokens.Color.panel, appearanceName: .aqua))
        #expect(onPanel >= floor,
                "light ember vs panel: \(onPanel):1 below the \(floor):1 non-text floor")
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
