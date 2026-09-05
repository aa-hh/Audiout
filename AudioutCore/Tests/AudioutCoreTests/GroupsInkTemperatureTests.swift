// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// C5 (2026-09-03): the Groups screen's ink carries TEMPERATURE. A group, a
/// speaker or a member row that is silent is named in `labelCool`; the one the
/// audio is actually reaching is named in `label`. This replaces the frozen-
/// text lock the screen used to live under, whose deal was the opposite one
/// ("separation comes from surfaces, never from recoloring text") — the deal
/// changed, so the test that enforced it did too.
///
/// Two things it still pins from the old lock, unchanged:
///   - the SIDEBAR keeps stock semantic ink. AppKit only re-inks a source-list
///     row's text over the emphasized selection pill when the colour is a
///     system semantic, so a cool authored token would sit grey on a selected
///     row's accent pill.
///   - the editor's checklist really does paint `raised` and `containerEdge`,
///     sampled off a real offscreen render rather than a re-typed expectation.
///
/// "Same colour" throughout means: resolved under BOTH appearances, in sRGB,
/// within 0.01 per channel.
@MainActor
@Suite final class GroupsInkTemperatureTests: IsolatedSuite {

    /// Environment guard for `membershipWellView(of:)`/`sampledColumnColors`:
    /// conditions that in practice never fire under `swift test` on this
    /// toolchain (a real WindowServer is always available). swift-testing has
    /// no in-body "mark skipped" — traits are evaluated before the test runs
    /// (migration cookbook §9) — and both helpers must return a real value, so
    /// hitting this reports the enclosing test FAILED rather than SKIPPED.
    private struct TestEnvironmentLimitation: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Colour identity

    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor? {
        var result: NSColor?
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return result
    }

    private func sameColor(_ a: NSColor?, _ b: NSColor?, tolerance: CGFloat = 0.01) -> Bool {
        guard let a, let b else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    /// `actual` is the same token as `expected` under BOTH appearances.
    private func expectSameToken(_ actual: NSColor?, _ expected: NSColor, _ label: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        guard let actual else {
            Issue.record("\(label): no colour to check", sourceLocation: sourceLocation)
            return
        }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(sameColor(resolved(actual, appearanceName: appearanceName),
                              resolved(expected, appearanceName: appearanceName)),
                    Comment(rawValue: "\(label) did not match the expected token under \(appearanceName.rawValue)"),
                    sourceLocation: sourceLocation)
        }
    }

    /// A LAYER colour is a stamped snapshot: it holds one appearance's value,
    /// not a dynamic pair, so it can only be compared under the appearance it
    /// was stamped in — the same expression the production stamp uses.
    private func expectSameStampedColor(_ actual: NSColor?, _ expected: NSColor, _ label: String,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        guard let actual = actual?.usingColorSpace(.sRGB) else {
            Issue.record("\(label): no stamped colour to check", sourceLocation: sourceLocation)
            return
        }
        var resolvedExpected: NSColor?
        (NSApp?.effectiveAppearance ?? .currentDrawing()).performAsCurrentDrawingAppearance {
            resolvedExpected = expected.usingColorSpace(.sRGB)
        }
        #expect(sameColor(actual, resolvedExpected),
                Comment(rawValue: "\(label) did not match the expected token"),
                sourceLocation: sourceLocation)
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

    // MARK: Fixtures

    private func makeDevice(id: String = "dev-1", name: String = "Kitchen", isAvailable: Bool = true) -> Device {
        Device(id: id, name: name, kind: .generic, isAvailable: isAvailable)
    }

    private func makeGroupController() -> GroupController {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return GroupController(backend: MockBackend(fleet: []), store: GroupStore(directory: dir), loadPersisted: false)
    }

    private func makeEditor() throws -> GroupEditorViewController {
        let devices = [
            Device(id: "a", name: "Alpha", kind: .generic, isAvailable: true),
            Device(id: "b", name: "Bravo", kind: .generic, isAvailable: true),
            Device(id: "c", name: "Charlie", kind: .generic, isAvailable: true),
            Device(id: "d", name: "Delta", kind: .generic, isAvailable: true),
        ]
        let controller = makeGroupController()
        let group = try controller.createGroup(name: "Downstairs", memberIDs: ["a", "b"], memberVolumes: [:]).group
        let editor = GroupEditorViewController(groupController: controller)
        editor.loadView()
        editor.show(groupID: group.id, devices: devices)
        editor.view.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        editor.view.layoutSubtreeIfNeeded()
        return editor
    }

    /// `GroupedSectionView` is private to its own file, so it cannot be named
    /// or constructed here even under `@testable import` — access control on
    /// the TYPE still applies. Only the stored-property VALUE is reachable, by
    /// reflection, and only as its public `NSView` superclass. That is exactly
    /// enough to drive the offscreen render-and-sample idiom below, which
    /// exercises the REAL `draw(_:)` rather than a re-typed expectation.
    private func membershipWellView(of editor: GroupEditorViewController) throws -> NSView {
        let mirror = Mirror(reflecting: editor)
        guard let child = mirror.children.first(where: { $0.label == "membershipWell" }),
              let view = child.value as? NSView else {
            throw TestEnvironmentLimitation(
                description: "membershipWell stored property not found via reflection — GroupEditorViewController's internal layout changed")
        }
        return view
    }

    private func sampledColumnColors(of view: NSView, appearanceName: NSAppearance.Name) throws -> [NSColor] {
        view.appearance = NSAppearance(named: appearanceName)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw TestEnvironmentLimitation(description: "no bitmap rep available in this environment")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let x = rep.pixelsWide / 2
        var colors: [NSColor] = []
        for y in 0..<rep.pixelsHigh {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                colors.append(c)
            }
        }
        return colors
    }

    // MARK: 1-4. The group card

    @Test func idleCardInkIsCool() {
        expectSameToken(GroupsOverviewViewController.test_cardNameColor(isLive: false),
                        Tokens.Color.labelCool, "idle card name")
        expectSameToken(GroupsOverviewViewController.test_cardGlyphTint(isLive: false),
                        Tokens.Color.labelCool, "idle card glyph")
        let meta = GroupsOverviewViewController.test_cardMetaAttributedString(isLive: false)
        expectSameToken(meta.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                        Tokens.Color.labelCool2, "idle card meta")
    }

    @Test func liveCardInkIsWarmWithGoldTextPlayingNow() throws {
        expectSameToken(GroupsOverviewViewController.test_cardNameColor(isLive: true),
                        Tokens.Color.label, "live card name")
        expectSameToken(GroupsOverviewViewController.test_cardGlyphTint(isLive: true),
                        Tokens.Color.label, "live card glyph")

        let meta = GroupsOverviewViewController.test_cardMetaAttributedString(isLive: true)
        expectSameToken(meta.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                        Tokens.Color.label2, "live card meta")
        let playingNow = try #require(meta.string.range(of: "Playing"))
        let start = NSRange(playingNow, in: meta.string).location
        expectSameToken(meta.attribute(.foregroundColor, at: start, effectiveRange: nil) as? NSColor,
                        Tokens.Color.goldText, "live card \"Playing\"")
    }

    @Test func liveCardRingsTheSeatGoldAndIdleCardEdgesItCool() {
        let live = GroupsOverviewViewController.test_cardSeatStroke(isLive: true)
        expectSameToken(live.color, Tokens.Color.gold, "live card seat stroke")
        #expect(live.width == 1.5)

        let idle = GroupsOverviewViewController.test_cardSeatStroke(isLive: false)
        expectSameToken(idle.color, Tokens.Color.containerEdge, "idle card seat stroke")
        #expect(idle.width == 1)
    }

    @Test func everyGroupCardCarriesTheIdentityGlow() {
        // Magenta is identity, not state, so both plans carry it. The alphas
        // are `GroupIdentityGlowViewTests`' business, not this suite's.
        #expect(GroupsOverviewViewController.test_cardHasIdentityGlow(isLive: true))
        #expect(GroupsOverviewViewController.test_cardHasIdentityGlow(isLive: false))
    }

    // MARK: 5-7. The editor's member rows

    @Test func memberRowInkFollowsArmedMembership() {
        let row = MembershipRowView(device: makeDevice(), checked: true, surface: .warmPane)
        row.railArmed = true
        expectSameToken(row.test_nameColor, Tokens.Color.label, "armed member name")
        expectSameToken(row.test_glyphTint, Tokens.Color.label2, "armed member glyph")

        row.railArmed = false
        expectSameToken(row.test_nameColor, Tokens.Color.labelCool, "idle-group member name")
        expectSameToken(row.test_glyphTint, Tokens.Color.labelCool2, "idle-group member glyph")

        row.railArmed = true
        row.isChecked = false
        expectSameToken(row.test_nameColor, Tokens.Color.labelCool, "non-member name in an armed group")
    }

    @Test func unavailableMemberRowIsOneCoolTone() {
        let row = MembershipRowView(device: makeDevice(isAvailable: false), checked: true, surface: .warmPane)
        row.railArmed = true
        expectSameToken(row.test_nameColor, Tokens.Color.labelCool2, "unavailable member name")
        expectSameToken(row.test_glyphTint, Tokens.Color.labelCool2, "unavailable member glyph")
        expectSameToken(row.test_unavailableLabelColor, Tokens.Color.labelCool2, "the \"Unavailable\" word")
        #expect(row.test_drawsGlyphTile)
    }

    @Test func systemSheetRowKeepsStockInk() {
        let available = MembershipRowView(device: makeDevice(), checked: true, surface: .systemSheet)
        expectSameToken(available.test_nameColor, Tokens.Color.label, "sheet row name")
        expectSameToken(available.test_glyphTint, Tokens.Color.label2, "sheet row glyph")
        #expect(!available.test_drawsGlyphTile)

        let unavailable = MembershipRowView(device: makeDevice(isAvailable: false), checked: true, surface: .systemSheet)
        expectSameToken(unavailable.test_nameColor, Tokens.Color.label3, "unavailable sheet row name")
        expectSameToken(unavailable.test_glyphTint, Tokens.Color.label3, "unavailable sheet row glyph")
        expectSameToken(unavailable.test_unavailableLabelColor, Tokens.Color.label3,
                        "the sheet's \"Unavailable\" word")
    }

    // MARK: 8-9. The icon well and its glow

    @Test func iconWellGlyphIsCoolUntilTheGroupIsActive() {
        let well = DeviceIconWellView()
        expectSameToken(well.iconImageView.contentTintColor, Tokens.Color.labelCool, "resting well glyph")
        well.isActiveGroup = true
        expectSameToken(well.iconImageView.contentTintColor, Tokens.Color.label, "active-group well glyph")
        well.isActiveGroup = false
        expectSameToken(well.iconImageView.contentTintColor, Tokens.Color.labelCool, "well glyph after deactivation")
    }

    @Test func editorHeaderWellCarriesTheIdentityGlowAtEightyPoints() throws {
        let editor = try makeEditor()
        #expect(editor.test_hasIdentityGlow)
        // The gradient scales to its own bounds, so the mounted size IS the
        // magenta's radius — a 60 pt glow would hide under the 64 pt well.
        #expect(editor.test_identityGlowSide == GroupEditorViewController.iconGlowSide)
    }

    // MARK: 10. The sidebar keeps stock ink

    @Test func sidebarCellsKeepStockInk() throws {
        let sidebar = SidebarViewController()

        let headerCell = try #require(
            sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                item: SidebarViewController.Node(.header("Speakers"))) as? NSTableCellView)
        expectSameToken(headerCell.textField?.textColor, Tokens.Color.label2, "sidebar header cell")

        for (payload, label) in [(SidebarViewController.Node.Payload.groupsOverview, "pinned Groups row"),
                                 (.mainOut, "Main Audio row"),
                                 (.device(makeDevice()), "device row")] {
            let cell = try #require(
                sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                    item: SidebarViewController.Node(payload)) as? NSTableCellView)
            expectSameToken(cell.textField?.textColor, Tokens.Color.label, "sidebar \(label)")
        }

        let unavailableCell = try #require(
            sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                item: SidebarViewController.Node(.device(makeDevice(isAvailable: false)))) as? NSTableCellView)
        expectSameToken(unavailableCell.textField?.textColor, Tokens.Color.label3,
                        "sidebar unavailable-device row")
    }

    // MARK: 11. The checklist card's real pixels

    @Test func membershipCardFillIsRaisedAndDividerIsContainerEdgeBothAppearances() throws {
        let editor = try makeEditor()
        #expect(editor.test_membershipWellRowCount > 1,
                "need >1 row for a divider to exist at all")
        let well = try membershipWellView(of: editor)
        #expect(well.bounds.width > 0, "well must have real layout to sample")

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let colors = try sampledColumnColors(of: well, appearanceName: appearanceName)
            guard let expectedFill = resolved(Tokens.Color.raised, appearanceName: appearanceName),
                  let expectedRule = resolved(Tokens.Color.containerEdge, appearanceName: appearanceName) else {
                // Environment guard: no resolvable token colour ⇒ nothing to
                // assert; a plain `return` works directly inside the Void @Test
                // body (unlike the two throwing helpers above).
                return
            }
            #expect(!colors.filter { sameColor($0, expectedFill, tolerance: 0.02) }.isEmpty,
                Comment(rawValue: "the checklist card's fill under \(appearanceName.rawValue) never matched " +
                "Tokens.Color.raised"))
            #expect(!colors.filter { sameColor($0, expectedRule, tolerance: 0.02) }.isEmpty,
                Comment(rawValue: "the checklist card never painted a Tokens.Color.containerEdge pixel under " +
                "\(appearanceName.rawValue) despite \(editor.test_membershipWellRowCount) rows — a `raised` " +
                "card rules its interior in containerEdge, because hairline on raised is 1.154:1 dark"))
        }
    }

    // MARK: 12. The cool inks clear the text floor

    @Test func coolInksClearTheTextFloorOnEveryGroupsGround() {
        let grounds = [("raised", Tokens.Color.raised),
                       ("panel", Tokens.Color.panel),
                       ("well", Tokens.Color.well)]
        let inks = [("labelCool", Tokens.Color.labelCool),
                    ("labelCool2", Tokens.Color.labelCool2)]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for (groundName, ground) in grounds {
                for (inkName, ink) in inks {
                    guard let g = resolved(ground, appearanceName: appearanceName),
                          let i = resolved(ink, appearanceName: appearanceName) else { return }
                    let ratio = contrastRatio(i, g)
                    #expect(ratio >= 4.5,
                        Comment(rawValue: "\(inkName) on \(groundName) under \(appearanceName.rawValue) is " +
                        "\(String(format: "%.2f", ratio)):1 — under the 4.5:1 text floor. The tightest " +
                        "measured pairs are 4.59 (dark labelCool2 on raised) and 4.60 (light labelCool2 on well)."))
                }
            }
        }
    }

    // MARK: 13. The icon picker's binary

    @Test func pickerSelectedCellIsGoldWithInkOnFillAndUnselectedIsCool() {
        let picker = IconPickerViewController()
        picker.configure(currentSymbolName: "airpods", defaultSymbolName: "hifispeaker.fill")
        _ = picker.view

        expectSameToken(picker.test_cellGlyphTint(for: "airpods"), Tokens.Color.inkOnFill,
                        "selected cell glyph")
        expectSameStampedColor(picker.test_cellFillColor(for: "airpods"),
                               Tokens.Color.gold, "selected cell fill")

        expectSameToken(picker.test_cellGlyphTint(for: "hifispeaker.fill"), Tokens.Color.labelCool,
                        "unselected cell glyph")
        expectSameStampedColor(picker.test_cellFillColor(for: "hifispeaker.fill"),
                               Tokens.Color.well, "unselected cell fill")
    }
}
