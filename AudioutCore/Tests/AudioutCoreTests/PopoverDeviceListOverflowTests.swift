// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// Roadmap 039 — the Mixer's device list has a ceiling and scrolls past it.
///
/// Before this, the panel had no maximum at all: with a big fleet it grew until
/// the screen clamp stopped it and the last row was sliced by the screen edge.
/// These tests assert the real measured heights on both sides of the ceiling,
/// and that only the LIST moves when it scrolls — the header strip's inset, the
/// banners, the System Audio card and the "Source"/"Offset" legends hold still.
@MainActor
@Suite final class PopoverDeviceListOverflowTests: IsolatedSuite {

    private func tempDirectory() -> URL {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fleet of `count` plain AirPlay speakers — enough of them to walk past
    /// the twelve-row ceiling with room to spare.
    private func fleet(_ count: Int) -> [Device] {
        (0..<count).map {
            Device(id: "speaker-\($0)", name: "Speaker \($0)", kind: .generic, volume: 40)
        }
    }

    private func makePopover(deviceCount: Int) -> PopoverController {
        let backend = MockBackend(fleet: fleet(deviceCount), staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let groups = GroupController(backend: backend,
                                     store: GroupStore(directory: tempDirectory()),
                                     routingStore: RoutingStore(directory: tempDirectory()),
                                     loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: groups)
        groups.ensureDefaultSelection()
        popover.test_isShownOverride = true
        // `MockBackend.devices` stays empty until `start()` has published the
        // fleet on its own queue. Reading it before that hands the popover an
        // empty list, and every row assertion below then measures the "Looking
        // for speakers…" placeholder instead of the speakers.
        backend.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && backend.devices.count < deviceCount {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        popover.update(devices: backend.devices)
        popover.test_panelView.layoutSubtreeIfNeeded()
        return popover
    }

    private var devicesCard: String { "Output Devices" }

    // MARK: The ceiling

    /// The overflow itself: twenty-four speakers used to make a panel as tall as
    /// the content, which is taller than any screen has room for. It now stops
    /// at the ceiling, and the surplus rows live inside the list's scroller.
    @Test func aLargeFleetStopsAtTheDeviceListCeiling() throws {
        let popover = makePopover(deviceCount: 24)
        popover.test_applyContentHeightLimit(.greatestFiniteMagnitude)

        let ceiling = PopoverPanelViewController.deviceListMaxHeight
        #expect(popover.test_deviceListCeiling == ceiling,
                "no screen pressure, so the list wears its own twelve-row maximum")

        let list = try #require(popover.test_cardBodyClipHeight(title: devicesCard))
        #expect(abs(list - ceiling) < 1,
                Comment(rawValue: "the list draws \(list)pt, ceiling \(ceiling)pt"))

        let scroll = try #require(popover.test_deviceListScrollView)
        let document = try #require(scroll.documentView)
        #expect(document.fittingSize.height > ceiling + 100,
                Comment(rawValue: "twenty-four rows really do overflow — the document "
                        + "carries \(document.fittingSize.height)pt of rows"))

        // Every row is still built, mounted and reachable — a row past the
        // ceiling is scrolled away, never dropped, so VoiceOver and the key-view
        // loop still reach it.
        let rows = deviceRows(under: document)
        #expect(rows.count == 24, "all 24 rows stay in the list, visible or not")
        for row in rows {
            #expect(!row.isHidden, "a scrolled-away row is not a hidden row")
        }
    }

    /// The other half of the promise: a short list changes nothing. No ceiling
    /// bites, the clip is exactly the rows, and the scroller has nothing to show.
    @Test func aSmallFleetStillHugsItsRowsExactly() throws {
        let popover = makePopover(deviceCount: 4)
        popover.test_applyContentHeightLimit(.greatestFiniteMagnitude)

        let list = try #require(popover.test_cardBodyClipHeight(title: devicesCard))
        let scroll = try #require(popover.test_deviceListScrollView)
        let document = try #require(scroll.documentView)

        #expect(list < PopoverPanelViewController.deviceListMaxHeight,
                "four speakers are nowhere near the ceiling")
        #expect(abs(list - document.fittingSize.height) < 1,
                Comment(rawValue: "the list is exactly its rows: \(list)pt for "
                        + "\(document.fittingSize.height)pt of content"))
        #expect(scroll.contentView.bounds.height + 1 >= document.fittingSize.height,
                "nothing to scroll — the clip already shows every row")
    }

    /// A short screen lowers the ceiling below the twelve-row maximum: the two
    /// bounds are the lower of each other, not one or the other.
    @Test func aShortScreenLowersTheCeilingBelowTheTwelveRowMaximum() throws {
        let popover = makePopover(deviceCount: 24)
        // A budget between the three-row floor and the twelve-row maximum, so
        // the SCREEN is what sets the ceiling and neither bound gets there
        // first. Derived from the chrome this build actually measures rather
        // than a fixed number, which would drift with any row or banner change.
        let budget = chromeAroundTheList(popover)
            + (PopoverPanelViewController.deviceListMaxHeight
               + PopoverPanelViewController.deviceListMinHeight) / 2
        popover.test_applyContentHeightLimit(budget)

        let ceiling = popover.test_deviceListCeiling
        #expect(ceiling < PopoverPanelViewController.deviceListMaxHeight,
                Comment(rawValue: "the screen's budget won, not the maximum "
                        + "(ceiling \(ceiling)pt)"))
        #expect(ceiling > PopoverPanelViewController.deviceListMinHeight,
                "and the floor never came into it")

        let height = popover.test_panelFittingSize.height
        #expect(height <= budget + 1,
                Comment(rawValue: "the panel measures \(height)pt against a \(budget)pt budget"))
    }

    /// The other end of the same clamp: a budget too small even for three rows
    /// stops at the floor rather than shrinking further. The panel then wants
    /// more than the budget on purpose — `measureSessionContentSize` takes that
    /// surplus off with its own screen clamp, so the list never collapses to a
    /// sliver on a very short screen.
    @Test func aBudgetBelowTheFloorStopsAtThreeRows() throws {
        let popover = makePopover(deviceCount: 24)
        popover.test_applyContentHeightLimit(0)

        let floor = PopoverPanelViewController.deviceListMinHeight
        #expect(popover.test_deviceListCeiling == floor,
                "a budget of nothing still leaves three rows")
        let list = try #require(popover.test_cardBodyClipHeight(title: devicesCard))
        #expect(abs(list - floor) < 1,
                Comment(rawValue: "the list draws \(list)pt, floor \(floor)pt"))
    }

    // MARK: Chrome holds still

    /// The point of scrolling only the card's BODY: scrolling the speakers must
    /// not move the header strip's inset, the System Audio block, or the card
    /// header carrying the "Source" and "Offset" legends.
    @Test func scrollingTheListLeavesTheChromeWhereItWas() throws {
        let popover = makePopover(deviceCount: 24)
        popover.test_applyContentHeightLimit(.greatestFiniteMagnitude)
        let panel = popover.test_panelView

        func chromeFrames() -> [NSRect] {
            panel.layoutSubtreeIfNeeded()
            return [popover.test_mainOutRow.convert(popover.test_mainOutRow.bounds, to: panel),
                    devicesHeader(popover, panel: panel)]
        }

        let before = chromeFrames()
        let heightBefore = popover.test_panelFittingSize.height

        let scroll = try #require(popover.test_deviceListScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)

        #expect(scroll.contentView.bounds.origin.y > 0, "the list really scrolled")
        #expect(chromeFrames() == before, "the chrome above the list did not move")
        #expect(popover.test_panelFittingSize.height == heightBefore,
                "and the panel did not resize under it")
    }

    /// Every column in the popover is measured inward from the row's trailing
    /// edge, so a scroller that took width would drag the whole grid left. The
    /// rows are the same width with a fleet that scrolls and one that does not.
    @Test func theScrollerTakesNoWidthFromTheColumns() throws {
        let small = makePopover(deviceCount: 4)
        let large = makePopover(deviceCount: 24)
        large.test_applyContentHeightLimit(.greatestFiniteMagnitude)

        func rowWidth(_ popover: PopoverController) throws -> CGFloat {
            popover.test_panelView.layoutSubtreeIfNeeded()
            let row = try #require(popover.test_deviceRow(for: "speaker-0"))
            return row.frame.width
        }

        let narrow = try rowWidth(small)
        let wide = try rowWidth(large)
        #expect(narrow == wide,
                Comment(rawValue: "row width \(wide)pt with an overflowing list vs "
                        + "\(narrow)pt without — an overlay scroller takes none"))
        let scroll = try #require(large.test_deviceListScrollView)
        #expect(scroll.scrollerStyle == .overlay)
    }

    // MARK: Keyboard

    /// Tabbing to a row below the fold brings it up. Without this, focus lands
    /// somewhere the user cannot see.
    @Test func focusingARowBelowTheFoldScrollsItIntoView() throws {
        let popover = makePopover(deviceCount: 24)
        popover.test_applyContentHeightLimit(.greatestFiniteMagnitude)
        let scroll = try #require(popover.test_deviceListScrollView)
        let document = try #require(scroll.documentView)
        // Lexicographic order puts "Speaker 9" last of the twenty-four.
        let last = try #require(popover.test_deviceRow(for: "speaker-9"))
        let lastInDocument = document.convert(last.bounds, from: last)

        #expect(scroll.contentView.bounds.origin.y == 0, "starts at the top of the list")
        #expect(!scroll.documentVisibleRect.contains(lastInDocument),
                "the row under test starts below the fold")

        popover.test_revealFocusedRow(last)
        scroll.reflectScrolledClipView(scroll.contentView)

        #expect(scroll.contentView.bounds.origin.y > 0,
                "the list scrolled to bring the focused row up")
    }

    // MARK: Helpers

    /// The Output Devices card's own header row — the one carrying the section
    /// title and the "Source" / "Offset" column legends.
    private func devicesHeader(_ popover: PopoverController, panel: NSView) -> NSRect {
        guard let header = popover.test_cardHeaderRow(title: devicesCard) else { return .zero }
        return header.convert(header.bounds, to: panel)
    }

    /// Everything in the panel except the device list — banners, the Main Audio
    /// block, both card headers, the App Routing card. Measured the same way
    /// `applyContentHeightLimit` measures it: the whole panel with the list
    /// uncapped, less the list.
    private func chromeAroundTheList(_ popover: PopoverController) -> CGFloat {
        popover.test_applyContentHeightLimit(.greatestFiniteMagnitude)
        let list = popover.test_cardBodyClipHeight(title: devicesCard) ?? 0
        return popover.test_panelFittingSize.height - list
    }

    private func deviceRows(under view: NSView) -> [DeviceRowView] {
        if let row = view as? DeviceRowView { return [row] }
        return view.subviews.flatMap { deviceRows(under: $0) }
    }
}
