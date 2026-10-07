// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// Only unavailable members use cool ink on the scene page.
/// Sidebar selection inks and the membership card are checked in both appearances.
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






    // MARK: The scene page's member rows

    // Cooling an available row because it is unchecked turns it red.
    @Test func anAvailableMemberRowsInkStaysWarm() {
        let row = MembershipRowView(device: makeDevice(), checked: true, surface: .warmPane)
        expectSameToken(row.test_nameColor, Tokens.Color.label, "member name")
        expectSameToken(row.test_glyphTint, Tokens.Color.label2, "member glyph")
        row.isChecked = false
        expectSameToken(row.test_nameColor, Tokens.Color.label, "non-member name")
        expectSameToken(row.test_glyphTint, Tokens.Color.label2, "non-member glyph")
    }

    // Inking the unavailable name in anything but the sidebar's labelCool, or warming it when the scene plays, turns it red.
    @Test func unavailableMemberRowTakesTheSidebarsInk() {
        let row = MembershipRowView(device: makeDevice(isAvailable: false), checked: true, surface: .warmPane)
        expectSameToken(row.test_nameColor, Tokens.Color.labelCool, "unavailable member name")
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

    // MARK: 10. The sidebar's secondary inks are cool

    // Turns red when a sidebar title, subsection header, divider, plate or speaker row goes back to a warm ink (label2, label3, ember, gold or failure), or the headers and unreachable rows stop being cool.
    @Test func sidebarSecondaryInksAreCool() throws {
        let sidebar = SidebarViewController()
        func cell(_ payload: SidebarViewController.Node.Payload) throws -> NSView {
            try #require(sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                             item: SidebarViewController.Node(payload)))
        }
        func all<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
            root.subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + all(type, in: sub) }
        }

        let section = try cell(.header("Speakers"))
        expectSameToken(all(NSTextField.self, in: section).first?.textColor, Tokens.Color.labelCool, "section title")
        let subsection = try cell(.header("Shown in Mixer"))
        expectSameToken(all(NSTextField.self, in: subsection).first?.textColor, Tokens.Color.labelCool,
                        "subsection header")
        let divider = try cell(.divider(2))
        let overview = try cell(.speakersOverview)
        let mainAudio = try cell(.mainOut)
        let reachable = try #require(try cell(.device(makeDevice())) as? IconLabelCellView)
        expectSameToken(reachable.nameLabel.textColor, Tokens.Color.label, "reachable name")
        let unreachable = try #require(try cell(.device(makeDevice(id: "dev-2", isAvailable: false)))
                                       as? IconLabelCellView)
        expectSameToken(unreachable.nameLabel.textColor, Tokens.Color.labelCool, "unreachable name")
        expectSameToken(unreachable.imageView?.contentTintColor, Tokens.Color.labelCool2, "unreachable icon")

        // A bare node has no record, so it never carries the caption: build
        // that row from a hidden speaker in use.
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [Device(id: "onkyo", name: "Onkyo", kind: .bluetooth, connectionState: .connected)],
                       groups: [])
        library.setVisibility(.hideWhenNotInUse, for: ["onkyo"])
        let captionedSidebar = SidebarViewController()
        captionedSidebar.loadViewIfNeeded()
        captionedSidebar.view.frame = NSRect(x: 0, y: 0, width: 210, height: 400)
        captionedSidebar.reload(devices: library.records.map(\.renderingDevice), presentationRecords: library.records)
        let captioned = try #require(captionedSidebar.test_deviceCell(id: "onkyo"))
        try #require(captionedSidebar.test_rowCaption(id: "onkyo") != nil)

        let warm = [(Tokens.Color.label2, "label2"), (Tokens.Color.label3, "label3"), (Tokens.Color.ember, "ember"),
                    (Tokens.Color.gold, "gold"), (Tokens.Color.failure, "failure")]
        func isToken(_ ink: NSColor?, _ token: NSColor) -> Bool {
            guard let ink else { return false }
            return [NSAppearance.Name.aqua, .darkAqua].allSatisfy { name in
                sameColor(resolved(ink, appearanceName: name), resolved(token, appearanceName: name))
            }
        }
        let cells: [(String, NSView)] = [("section title", section), ("subsection header", subsection),
                                         ("divider", divider), ("Overview plate", overview),
                                         ("Main Audio plate", mainAudio), ("reachable row", reachable),
                                         ("unreachable row", unreachable), ("captioned row", captioned)]
        for (name, view) in cells {
            let inks = all(NSTextField.self, in: view).map(\.textColor)
                + all(NSImageView.self, in: view).map(\.contentTintColor)
            for ink in inks {
                for (token, tokenName) in warm {
                    #expect(!isToken(ink, token), "\(name) has an ink in \(tokenName)")
                }
            }
        }
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

    // Filling the current icon's cell gold, or with anything but AppKit's own selection colours, turns it red.
    @Test func pickerSelectedCellWearsTheStockSelectionAndUnselectedIsCool() {
        let picker = IconPickerViewController()
        picker.configure(currentSymbolName: "airpods", defaultSymbolName: "hifispeaker.fill")
        _ = picker.view

        // No window, so not key: AppKit's unemphasized selection.
        expectSameToken(picker.test_cellGlyphTint(for: "airpods"), .unemphasizedSelectedTextColor,
                        "selected cell glyph")
        expectSameStampedColor(picker.test_cellFillColor(for: "airpods"),
                               .unemphasizedSelectedContentBackgroundColor, "selected cell fill")

        expectSameToken(picker.test_cellGlyphTint(for: "hifispeaker.fill"), Tokens.Color.labelCool,
                        "unselected cell glyph")
        expectSameStampedColor(picker.test_cellFillColor(for: "hifispeaker.fill"),
                               Tokens.Color.well, "unselected cell fill")
    }

    // MARK: 14. The Speakers overview carries no warm or alarm ink

    // Drawing any Overview text or glyph in label2, label3, ember, gold or failure turns it red.
    @Test func overviewPageCarriesNoWarmOrAlarmInk() {
        let library = SpeakerLibraryController(loadPersisted: false)
        let mac = Device(id: "mac", name: "Mac", kind: .localMac, isAvailable: true)
        let kitchen = makeDevice(id: "kitchen", name: "Kitchen")
        library.update(liveDevices: [mac, kitchen, Device(id: "attic", name: "Attic", kind: .bluetooth, isAvailable: true)],
                       groups: [], confirmedUsedIDs: ["attic"])
        library.update(liveDevices: [mac, kitchen], groups: [])
        var pending: [() -> Void] = []
        let search = SpeakerSearch(library: library, schedule: { _, fire in pending.append(fire) })
        search.isLocalNetworkDenied = { true }
        // Started by the page appearing, so no counts event reaches another suite's sink.
        search.pageDidAppear()
        while !pending.isEmpty { pending.removeFirst()() }
        let page = SpeakersPageViewController(library: library, groupController: makeGroupController())
        page.search = search
        page.setBluetoothAccess(SpeakerBluetoothAccessPresentation(status: .unknown, priming: false))
        #expect(page.test_rowTitles.count == 4, "every row is shown")

        let banned = [("label2", Tokens.Color.label2), ("label3", Tokens.Color.label3), ("ember", Tokens.Color.ember),
                      ("gold", Tokens.Color.gold), ("failure", Tokens.Color.failure)]
        func isBanned(_ color: NSColor?) -> String? {
            guard let color else { return nil }
            return banned.first { entry in
                [NSAppearance.Name.aqua, .darkAqua].allSatisfy {
                    sameColor(resolved(color, appearanceName: $0), resolved(entry.1, appearanceName: $0))
                }
            }?.0
        }
        var views = [page.view]
        var checked = 0
        while let view = views.popLast() {
            views += view.subviews
            if let field = view as? NSTextField {
                checked += 1
                if let name = isBanned(field.textColor) { Issue.record("\"\(field.stringValue)\" is inked \(name)") }
            } else if let image = view as? NSImageView {
                checked += 1
                if let name = isBanned(image.contentTintColor) { Issue.record("a glyph is tinted \(name)") }
            }
        }
        #expect(checked > 10)
    }
}
