// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// Scene, speaker and Main Audio pages share the header geometry and content inset.
/// The elastic column and delete action stay aligned as the pane grows.
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

        let slack = 0.01 + halfPointSlack()
        #expect(abs(editorIcon.minX - detailIcon.minX) <= slack)
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

    // Moving the name-and-caption block off the icon centre or changing the title gap turns it red.
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
        #expect(abs(window.test_editor.test_headerTextBlockFrame.midY - icon.midY) <= 0.01,
                "the name-and-caption block is centred on the icon")
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
        #expect(abs(editorInset - GroupsPaneLayout.railFreeContentLeadingInset) <= slack,
                "the scene page shares the other pages' inset")
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

    // Moving the Overview's well back to the rail inset, changing its band height, or hanging its caption under a name centred alone turns it red.
    @Test func overviewHeaderMatchesTheSpeakerPageAndLinesUpWithItsList() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)
        let detailIcon = window.test_detail.test_headerIconFrame
        let detailHeader = window.test_detail.test_headerSectionFrame

        window.test_select(.speakersOverview)
        settle(window)
        let page = window.test_speakersPage
        let overview = page.test_headerFrames
        let iconInset = overview.icon.minX - overview.band.minX

        let slack = 0.01 + halfPointSlack()
        #expect(abs(iconInset - GroupsPaneLayout.railFreeContentLeadingInset) <= slack,
                "the Overview has no rail, so its well starts on the rail-free inset")
        #expect(abs(overview.icon.minX - detailIcon.minX) <= slack,
                "the well lands where the speaker page's does")
        #expect(abs(overview.band.height - detailHeader.height) <= 0.01,
                "identical header band height, so the content below starts at the same y")
        #expect(abs(overview.textBlock.midY - overview.icon.midY) <= slack,
                "the name and the caption are one block centred on the well")
        let rowInset = try #require(page.test_listRowContentInset)
        #expect(abs(rowInset - iconInset) <= slack, "the well lines up with the list's text")
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


    @Test func deleteButtonLinesUpWithTheContentAboveIt() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        #expect(abs(window.test_editor.test_deleteButtonFrame.minX
                    - window.test_editor.test_headerIconFrame.minX) <= 0.01,
                Comment(rawValue: "the button hangs off the COLUMN like everything else — anchored to the " +
                "container it drifts one margin to the left of the whole form"))
    }

    // MARK: The scene form's top inset


    // Moving the scene form away from the shared top inset turns it red.
    @Test func theFormStartsAtTheSharedTopInset() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)
        let editor = window.test_editor
        #expect(abs(editor.test_headerSectionFrame.maxY
                    - (editor.view.frame.height - GroupsPaneLayout.columnTopInset)) <= 0.5)
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
