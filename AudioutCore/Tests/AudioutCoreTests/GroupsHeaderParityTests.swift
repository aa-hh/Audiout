// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// HEADER PARITY + the elastic content column (design review 2026-07-25).
///
/// The Groups window swaps its whole content pane when the sidebar selection
/// moves between a group and a device. If the header band height or the text
/// block's vertical centring differ between the two panes, that swap reads as
/// the window twitching — which is exactly what happened when the two
/// controllers carried hand-copied literals and drifted ~22.5 pt apart. Both
/// panes now read `GroupsPaneLayout`; these tests assert the REAL laid-out
/// frames still share the band height and the vertical centring, so a future
/// edit to one pane can't quietly desync the other. The icon's x differs by
/// design: the speaker and Main Audio pages start it at
/// `railFreeContentLeadingInset`, the scene editor at `contentLeadingInset`.
///
/// The elastic-column half guards the other half of the same design: the
/// sections stretch with the pane (they used to hug ~277 pt of intrinsic
/// content and leave a dead strip), and the two anchoring traps that stretch
/// exposed — the rail overlay and the delete button both had to move from the
/// container to the column.
@MainActor
@Suite final class GroupsHeaderParityTests: IsolatedSuite {

    private func tempDirectory() -> URL {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeController() -> GroupController {
        GroupController(backend: MockBackend(fleet: []),
                        store: GroupStore(directory: tempDirectory()),
                        loadPersisted: false)
    }

    private func makeDevice(id: String = "office", name: String = "Office",
                            available: Bool = true) -> Device {
        Device(id: id, name: name, kind: .generic, isAvailable: available)
    }

    /// Both panes, laid out inside the SAME content tree at the Groups
    /// screen's shipping content area — the only honest way to compare them,
    /// since a pane's width comes from the split view, not from a frame a test
    /// picked. The controller owns no window (U6): the split view is laid out
    /// directly at the area the surface's Groups screen gives it
    /// (`AppSurfaceController.minimumContentSize` minus the header strip).
    private func makeWindow() throws -> (MixerWindowController, GroupController, [Device], Group) {
        let devices = (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") }
        let controller = makeController()
        let group = try controller.createGroup(name: "Downstairs", memberIDs: ["d0"],
                                               memberVolumes: [:]).group
        let window = MixerWindowController(groupController: controller,
                                           settings: AppSettings(defaults: isolatedDefaults))
        window.setVisibleTab(.speakers)
        window.update(devices: devices)
        // The fixed frame's floor; only the width matters here.
        window.scenesContentController.view.setFrameSize(AppSurfaceController.minimumContentSize)
        window.speakersContentController.view.setFrameSize(AppSurfaceController.minimumContentSize)
        return (window, controller, devices, group)
    }

    private func settle(_ window: MixerWindowController) {
        window.scenesContentController.view.layoutSubtreeIfNeeded()
        window.speakersContentController.view.layoutSubtreeIfNeeded()
    }

    /// How far a HALF-POINT number can move when auto layout writes it into a
    /// frame — normally 0, and 0.5 in a run whose rounding grid is whole points.
    ///
    /// Two of the numbers below are half points by design:
    /// ``GroupsPaneLayout/contentLeadingInset`` is 38.5 (the rail node is 13 pt
    /// across, so its radius lands on a half point), and the device pane's
    /// 19 pt-tall title, centred on the 48 pt icon well, starts on one. Auto
    /// layout snaps every frame onto a rounding grid, and that grid's pitch is a
    /// property of the RUN, not of this layout: the same binary on the same Mac
    /// lays a 38.5 pt constraint out at 38.5 in one run and 39.0 in the next,
    /// while `convertToBacking` reports 2x in both — so it cannot be read off a
    /// view or a screen, only measured. Hence the scratch view: pin one half a
    /// point in and see where it lands.
    ///
    /// This is the ONLY slack these assertions carry, it is zero wherever half
    /// points are representable, and even at its widest it is 45 times finer
    /// than the ~22.5 pt drift the suite was written to catch.
    private func halfPointSlack() -> CGFloat {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let probe = NSView()
        probe.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(probe)
        NSLayoutConstraint.activate([
            probe.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 0.5),
            probe.widthAnchor.constraint(equalToConstant: 1),
            probe.heightAnchor.constraint(equalToConstant: 1),
        ])
        host.layoutSubtreeIfNeeded()
        return abs(probe.frame.minX - 0.5)
    }

    // MARK: Parity

    /// How far `y` sits below the TOP edge of `pane`, the view the header
    /// hooks report their frames in. The editor and the speaker page live in
    /// different hosts (the scenes host carries a footer, the speakers split
    /// does not), so their panes differ in height and only top-relative
    /// positions compare.
    private func distanceFromTop(_ y: CGFloat, in pane: NSView) -> CGFloat {
        pane.isFlipped ? y - pane.bounds.minY : pane.bounds.maxY - y
    }

    // Turns red when either pane changes its icon well's size, moves its text block off the icon's centre line, or moves its header band.
    @Test func bothPanesPutTheIconWellAndTitleAtTheSameGeometry() throws {
        let (window, _, _, group) = try makeWindow()

        window.test_select(.group(id: group.id))
        settle(window)
        let editorIcon = window.test_editor.test_headerIconFrame
        let editorTextBlock = window.test_editor.test_headerTextBlockFrame
        let editorHeader = window.test_editor.test_headerSectionFrame
        let editorTextFromTop = distanceFromTop(editorTextBlock.midY, in: window.test_editor.view)

        window.test_select(.device(id: "d0"))
        settle(window)
        let detailIcon = window.test_detail.test_headerIconFrame
        let detailTextBlock = window.test_detail.test_headerTextBlockFrame
        let detailHeader = window.test_detail.test_headerSectionFrame
        let detailTextFromTop = distanceFromTop(detailTextBlock.midY, in: window.test_detail.view)

        #expect(abs(editorIcon.width - detailIcon.width) <= 0.01)
        #expect(abs(editorIcon.height - detailIcon.height) <= 0.01)
        #expect(abs(editorTextFromTop - detailTextFromTop) <= 0.01 + halfPointSlack(),
                "both text blocks are vertically centred on the icon well beside them")
        #expect(abs(editorHeader.height - detailHeader.height) <= 0.01,
                "identical header BAND height, so the content below starts at the same y")
        #expect(abs(editorHeader.minX - detailHeader.minX) <= 0.01)
        // The two panes centre a width-capped header on panes of different widths, and AppKit's pixel rounding (see `halfPointSlack()`) lands them a point apart.
        #expect(abs(editorHeader.width - detailHeader.width) <= 1.0)
    }

    @Test func headerBandIsTheDerivedSideBySideHeight() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        // 80 = padding + the icon well + padding, all of it derived: the icon
        // and the name share one horizontal band now instead of stacking, which
        // is where the 30 pt this pane needed came from.
        #expect(abs(GroupsPaneLayout.headerBandHeight
                    - (GroupsPaneLayout.headerPadding * 2 + DeviceIconWellView.size)) <= 0.01)
        #expect(abs(window.test_editor.test_headerSectionFrame.height
                    - GroupsPaneLayout.headerBandHeight) <= 0.01)

        let icon = window.test_editor.test_headerIconFrame
        let title = window.test_editor.test_headerTitleAlignmentFrame
        #expect(abs(title.minX - (icon.maxX + GroupsPaneLayout.iconToTitleGap)) <= 0.01,
                "the title sits BESIDE the icon, one gap away")
        #expect(abs(title.midY - icon.midY) <= 0.01,
                "…vertically centred on it, not baselined off its bottom")
    }

    @Test func headerContentStartsAtTheSharedContentInset() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)
        let editorInset = window.test_editor.test_headerIconFrame.minX
            - window.test_editor.test_headerSectionFrame.minX
        window.test_select(.device(id: "d0"))
        settle(window)
        let detailInset = window.test_detail.test_headerIconFrame.minX
            - window.test_detail.test_headerSectionFrame.minX
        window.test_select(.mainOut)
        settle(window)
        let mainInset = window.test_mainOutDetail.test_headerIconFrame.minX
            - window.test_mainOutDetail.test_headerSectionFrame.minX

        let slack = 0.01 + halfPointSlack()
        #expect(abs(editorInset - GroupsPaneLayout.contentLeadingInset) <= slack,
                "the icon starts past the rail gutter the editor reserves")
        #expect(abs(detailInset - GroupsPaneLayout.railFreeContentLeadingInset) <= slack,
                "the speaker page starts its icon where its Equalizer heading starts")
        #expect(abs(mainInset - GroupsPaneLayout.railFreeContentLeadingInset) <= slack,
                "the Main Audio page starts its icon where its Equalizer heading starts")
    }

    // Pinning either page's Equalizer heading row back to the inset itself, without subtracting the symbol's bearing, turns it red.
    @Test func theEqualizerHeadingsDrawnSquareSitsOnThePagesInset() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)
        let detailInset = window.test_detail.test_eqMarkSquareFrame.minX
            - window.test_detail.test_headerSectionFrame.minX
        window.test_select(.mainOut)
        settle(window)
        let mainInset = window.test_mainOutDetail.test_eqMarkSquareFrame.minX
            - window.test_mainOutDetail.test_headerSectionFrame.minX

        let slack = 0.01 + halfPointSlack()
        #expect(abs(detailInset - GroupsPaneLayout.railFreeContentLeadingInset) <= slack,
                "the speaker page's drawn square starts at \(detailInset), not on its inset")
        #expect(abs(mainInset - GroupsPaneLayout.railFreeContentLeadingInset) <= slack,
                "the Main Audio page's drawn square starts at \(mainInset), not on its inset")
    }

    // Moving the list rows off ListRowView.leadingInset, or the header icon off railFreeContentLeadingInset, turns it red.
    @Test func detailListRowsStartOnThePagesOwnInset() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)

        let rowInset = window.test_detail.test_listRowContentInset
        let headerInset = window.test_detail.test_headerIconFrame.minX
            - window.test_detail.test_headerSectionFrame.minX

        #expect(abs(rowInset - ListRowView.leadingInset) <= 0.01 + halfPointSlack(),
                "the list's rows start at their own inset, where the list's dividers start")
        #expect(abs(headerInset - GroupsPaneLayout.railFreeContentLeadingInset) <= 0.01 + halfPointSlack())
        #expect(abs(rowInset - headerInset) <= 0.01 + halfPointSlack(),
                "list text lines up with the page's icon and headings")
    }

    // MARK: The elastic column

    @Test func sectionsStretchWithThePaneInsteadOfHuggingTheirContent() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        let pane = window.test_editor.view.frame.width
        let header = window.test_editor.test_headerSectionFrame
        #expect(abs(header.minX - GroupsPaneLayout.columnInset) <= 0.01,
                "SYMMETRIC margins: the section starts one margin in, not at the pane edge")
        #expect(abs((pane - header.maxX) - GroupsPaneLayout.columnTrailingInset) <= 0.01,
                "…and ends one margin short of the other side, with no dead strip")
        #expect(header.width > 250,
                "the section fills the pane rather than its ~277pt intrinsic content")
    }

    @Test func columnStopsGrowingAtTheContentMaxWidth() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        // A pane far wider than the cap: the section must stop stretching.
        window.scenesContentController.view.setFrameSize(NSSize(width: 1200, height: 700))
        settle(window)

        #expect(abs(window.test_editor.test_headerSectionFrame.width
                    - GroupsPaneLayout.contentMaxWidth) <= 0.5,
                "the column is elastic UP TO the cap — past it the form would read as a slab")
    }

    // MARK: The two anchoring traps the elastic column exposed

    @Test func everyNodeStillLandsOnTheOverlaysGutterLineAfterTheColumnMovedIn() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        // The overlay is pinned to the COLUMN. Pinned to the container (as it
        // was) the spine and the nodes separate by exactly `columnInset`.
        for id in window.test_editor.test_candidateDeviceIDs {
            let x = try #require(window.test_editor.test_nodeCenterXInOverlaySpace(for: id))
            #expect(abs(x - PopoverColumnGrid.railGutterCenterX) <= 0.01,
                    "\(id)'s node must sit exactly on the drawn spine")
        }
    }

    @Test func deleteButtonLinesUpWithTheContentAboveIt() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        #expect(abs(window.test_editor.test_deleteButtonFrame.minX
                    - window.test_editor.test_headerIconFrame.minX) <= 0.01,
                Comment(rawValue: "the button hangs off the COLUMN like everything else — anchored to the " +
                "container it drifts one margin to the left of the whole form"))
    }

    // MARK: The editor's top action band

    /// The two controls that LEAVE the editor share one band above the form
    /// (owner's call, 2026-09-03): "‹ Groups" on the left, the Done/Save
    /// primary on the right, the same height so they read as a matched
    /// secondary/primary pair rather than a caption beside a button.
    @Test func theWayBackAndThePrimaryShareOneBandAtTheTopOfTheForm() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)
        let editor = window.test_editor
        let back = editor.test_backControlFrame
        let primary = editor.test_doneButtonFrame
        let header = editor.test_headerSectionFrame

        #expect(abs(back.height - primary.height) <= 0.01,
                "the way back is sized to the primary, not to a caption")
        #expect(abs(back.minY - primary.minY) <= 0.01, "…and sits on its band")
        #expect(abs(primary.maxX - header.maxX) <= 0.01,
                "the primary closes the form's trailing edge — the TOP RIGHT of the pane")
        #expect(abs(back.minX - header.minX) <= 0.01,
                "…and the way back opens its leading edge")
        #expect(back.maxX < primary.minX, "the two never overlap")
    }

    /// The band rides inside the header section's own (bare, undrawn) top
    /// padding rather than pushing the form down — which is what keeps the
    /// parity assertions above honest with the device pane, whose column has
    /// no band above it at all.
    @Test func theTopBandClearsTheIdentityCardWithoutMovingIt() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)
        let editor = window.test_editor

        // The pane's own coordinates are NOT flipped (the scroll DOCUMENT is),
        // so "above" is a larger y. A bare `>` here once passed on a 0.5 pt
        // gap — assert the real minimum clearance instead so a future change
        // that spends the gap down to nothing fails loudly.
        let clearance = editor.test_backControlFrame.minY - editor.test_headerIconFrame.maxY
        #expect(clearance >= 8,
                Comment(rawValue: "the band needs at least 8 pt of clearance above the " +
                "identity card's icon, not just any gap"))
        #expect(abs(editor.test_headerSectionFrame.maxY
                    - (editor.view.frame.height - GroupsPaneLayout.columnTopInset)) <= 0.5,
                Comment(rawValue: "the form still starts at the inset both detail panes use — a band " +
                "that pushed it down would make every sidebar swap twitch"))
    }

    // MARK: The detail pane: the Equalizer's well and the outlined list

    // A third box, a lost list card, or a returning slot title turns it red.
    @Test func detailPageHasTheWellTheListAndNoOrphanedRule() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)

        #expect(window.test_detail.test_cardFrames.count == 2,
                "the Equalizer's well and the outlined list's card")
        #expect(window.test_detail.test_slotTitles == ["Equalizer"],
                "identity is bare and unlabelled; the list carries no title")
        #expect(!window.test_detail.test_hasBoxDivider,
                Comment(rawValue: "the stock NSBox rule is gone — it drew a 185pt line that stopped a third of " +
                "the way across the pane; the sections' own inset hairlines separate rows now"))
    }

    // MARK: The Main Audio page is the third pane behind the same header

    @Test func mainAudioPaneHeaderMatchesTheDevicePane() throws {
        let (window, _, _, _) = try makeWindow()

        window.test_select(.device(id: "d0"))
        settle(window)
        let detailIcon = window.test_detail.test_headerIconFrame
        let detailTitle = window.test_detail.test_headerTitleAlignmentFrame
        let detailHeader = window.test_detail.test_headerSectionFrame

        window.test_select(.mainOut)
        settle(window)
        let mainIcon = window.test_mainOutDetail.test_headerIconFrame
        let mainTitle = window.test_mainOutDetail.test_headerTitleAlignmentFrame
        let mainHeader = window.test_mainOutDetail.test_headerSectionFrame
        let mainTitleBlock = window.test_mainOutDetail.test_headerTextBlockFrame

        let slack = 0.01 + halfPointSlack()
        #expect(abs(detailIcon.minX - mainIcon.minX) <= slack,
                Comment(rawValue: "the Main Audio page is a third pane behind the same sidebar — its icon " +
                "must land where the other two panes' do"))
        #expect(abs(detailIcon.width - mainIcon.width) <= 0.01)
        #expect(abs(detailIcon.height - mainIcon.height) <= 0.01)
        #expect(abs(detailTitle.minX - mainTitle.minX) <= slack)
        #expect(abs(detailHeader.height - mainHeader.height) <= 0.01,
                "identical header BAND height, so the content below starts at the same y")
        #expect(abs(detailHeader.minX - mainHeader.minX) <= 0.01)
        #expect(abs(detailHeader.width - mainHeader.width) <= 0.01)
        #expect(abs(mainTitleBlock.midY - mainIcon.midY) <= slack,
                "the Main Audio name is centred on its icon well")
    }

    @Test func mainAudioIconWellIsNotEditable() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.mainOut)
        settle(window)

        #expect(!window.test_mainOutDetail.test_iconWellIsEditable,
                Comment(rawValue: "nobody picks a glyph for the whole mix, and the module's vocabulary says a " +
                "well that can't be edited wears no pencil badge"))
    }

}
