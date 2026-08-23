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
/// moves between a group and a device. If the icon well, the title, or the
/// header band land differently in the two panes, that swap reads as the window
/// twitching — which is exactly what happened when the two controllers carried
/// hand-copied literals and drifted ~22.5 pt apart. Both panes now read
/// `GroupsPaneLayout`; these tests assert the REAL laid-out frames still match,
/// so a future edit to one pane can't quietly desync the other.
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
        window.setHostVisible(true)
        window.update(devices: devices)
        // The fixed frame's floor; only the width matters here.
        window.contentController.view.setFrameSize(AppSurfaceController.minimumContentSize)
        return (window, controller, devices, group)
    }

    private func settle(_ window: MixerWindowController) {
        window.contentController.view.layoutSubtreeIfNeeded()
    }

    /// How far a HALF-POINT number can move when auto layout writes it into a
    /// frame — normally 0, and 0.5 in a run whose rounding grid is whole points.
    ///
    /// Two of the numbers below are half points by design:
    /// ``GroupsPaneLayout/contentLeadingInset`` is 38.5 (the rail node is 13 pt
    /// across, so its radius lands on a half point), and the device pane's
    /// 19 pt-tall title, centred on the 64 pt icon well, starts on one. Auto
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

    @Test func bothPanesPutTheIconWellAndTitleAtTheSameGeometry() throws {
        let (window, _, _, group) = try makeWindow()

        window.test_select(.group(id: group.id))
        settle(window)
        let editorIcon = window.test_editor.test_headerIconFrame
        let editorTitle = window.test_editor.test_headerTitleAlignmentFrame
        let editorHeader = window.test_editor.test_headerSectionFrame

        window.test_select(.device(id: "d0"))
        settle(window)
        let detailIcon = window.test_detail.test_headerIconFrame
        let detailTitle = window.test_detail.test_headerTitleAlignmentFrame
        let detailHeader = window.test_detail.test_headerSectionFrame

        #expect(abs(editorIcon.minX - detailIcon.minX) <= 0.01,
                Comment(rawValue: "the icon well must start at the same x in both panes — a difference here " +
                "is a visible sideways jump when the sidebar selection changes"))
        #expect(abs(editorIcon.width - detailIcon.width) <= 0.01)
        #expect(abs(editorIcon.height - detailIcon.height) <= 0.01)
        #expect(abs(editorTitle.minX - detailTitle.minX) <= 0.01,
                Comment(rawValue: "the title's leading edge (its ALIGNMENT rect — what auto layout pins) must " +
                "match, even though one is an editable field and the other a plain label"))
        #expect(abs(editorTitle.midY - detailTitle.midY) <= 0.01 + halfPointSlack(),
                "both titles are vertically centred on the icon well beside them")
        #expect(abs(editorHeader.height - detailHeader.height) <= 0.01,
                "identical header BAND height, so the content below starts at the same y")
        #expect(abs(editorHeader.minX - detailHeader.minX) <= 0.01)
        #expect(abs(editorHeader.width - detailHeader.width) <= 0.01)
    }

    @Test func headerBandIsTheDerivedSideBySideHeight() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        // 92 = padding + the icon well + padding, all of it derived: the icon
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

        let slack = 0.01 + halfPointSlack()
        #expect(abs(editorInset - GroupsPaneLayout.contentLeadingInset) <= slack,
                "the icon starts past the rail gutter the editor reserves")
        #expect(abs(detailInset - GroupsPaneLayout.contentLeadingInset) <= slack,
                Comment(rawValue: "the detail pane reserves the same lane even though it draws no rail — " +
                "alignment is worth more than reclaiming it"))
    }

    /// The HEADER is pinned across both panes (above), but everything BELOW it
    /// in the rail-less detail pane is not: reserving the spine's lane there
    /// left those sections looking hollow on their leading edge, with nothing
    /// occupying the gap (design review 2026-07-25). The two insets must stay
    /// genuinely different, or one of the two halves of that decision has been
    /// quietly undone.
    @Test func detailMetadataRowsUseTheRailFreeInsetNotTheHeaderOne() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)

        let rowInset = window.test_detail.test_metadataRowInset
        let headerInset = window.test_detail.test_headerIconFrame.minX
            - window.test_detail.test_headerSectionFrame.minX

        #expect(abs(rowInset - GroupsPaneLayout.railFreeContentLeadingInset) <= 0.01,
                "no rail runs past the metadata rows, so they don't reserve its lane")
        #expect(rowInset < headerInset,
                Comment(rawValue: "the rows must sit tighter than the header, which stays pinned to the " +
                "editor's for cross-pane alignment"))
        #expect(headerInset - rowInset > 1,
                Comment(rawValue: "a difference this small means the rail-free inset has drifted back " +
                "toward the header's and the hollow leading edge is returning"))
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
        window.contentController.view.setFrameSize(NSSize(width: 1200, height: 700))
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

    // MARK: The detail pane is one housing: one card, three titled slots

    @Test func detailPageHasOneCardThreeTitlesAndNoOrphanedRule() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)

        #expect(window.test_detail.test_cardFrames.count == 1,
                "the Equalizer is the page's one instrument, so the page's one card")
        #expect(window.test_detail.test_slotTitles == ["Equalizer", "Groups", "About"],
                "identity is bare and unlabelled; every other slot is a titled bare list")
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
    }

    @Test func mainAudioIconWellIsNotEditable() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.mainOut)
        settle(window)

        #expect(!window.test_mainOutDetail.test_iconWellIsEditable,
                Comment(rawValue: "nobody picks a glyph for the whole mix, and the module's vocabulary says a " +
                "well that can't be edited wears no pencil badge"))
    }

    @Test func detailValuesRightAlignIntoTheSectionsWidth() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)

        let section = window.test_detail.test_aboutSectionFrame
        let valueTrailing = window.test_detail.test_valueTrailingX
        #expect(abs((section.maxX - valueTrailing) - GroupsPaneLayout.contentTrailingInset) <= 2.5,
                Comment(rawValue: "values right-align on the section's own inset edge (± the text field's own " +
                "alignment inset), instead of hanging off a fixed 90pt caption column"))
    }
}
