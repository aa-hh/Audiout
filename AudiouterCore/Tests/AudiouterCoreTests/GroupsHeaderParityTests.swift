// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

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
final class GroupsHeaderParityTests: IsolatedTestCase {

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

    /// Both panes, laid out inside the SAME window at its shipping default —
    /// the only honest way to compare them, since a pane's width comes from the
    /// split view, not from a frame a test picked.
    private func makeWindow() throws -> (MixerWindowController, GroupController, [Device], Group) {
        let devices = (0..<7).map { makeDevice(id: "d\($0)", name: "Device \($0)") }
        let controller = makeController()
        let group = try controller.createGroup(name: "Downstairs", memberIDs: ["d0"],
                                               memberVolumes: [:]).group
        let window = MixerWindowController(groupController: controller,
                                           frameAutosaveName: uniqueName("GroupsHeaderParityTests"))
        window.update(devices: devices)
        return (window, controller, devices, group)
    }

    private func settle(_ window: MixerWindowController) {
        window.window?.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Parity

    func testBothPanesPutTheIconWellAndTitleAtTheSameGeometry() throws {
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

        XCTAssertEqual(editorIcon.minX, detailIcon.minX, accuracy: 0.01,
                       "the icon well must start at the same x in both panes — a difference here " +
                       "is a visible sideways jump when the sidebar selection changes")
        XCTAssertEqual(editorIcon.width, detailIcon.width, accuracy: 0.01)
        XCTAssertEqual(editorIcon.height, detailIcon.height, accuracy: 0.01)
        XCTAssertEqual(editorTitle.minX, detailTitle.minX, accuracy: 0.01,
                       "the title's leading edge (its ALIGNMENT rect — what auto layout pins) must " +
                       "match, even though one is an editable field and the other a plain label")
        XCTAssertEqual(editorTitle.midY, detailTitle.midY, accuracy: 0.01,
                       "both titles are vertically centred on the icon well beside them")
        XCTAssertEqual(editorHeader.height, detailHeader.height, accuracy: 0.01,
                       "identical header BAND height, so the content below starts at the same y")
        XCTAssertEqual(editorHeader.minX, detailHeader.minX, accuracy: 0.01)
        XCTAssertEqual(editorHeader.width, detailHeader.width, accuracy: 0.01)
    }

    func testHeaderBandIsTheDerivedSideBySideHeight() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        // 92 = padding + the icon well + padding, all of it derived: the icon
        // and the name share one horizontal band now instead of stacking, which
        // is where the 30 pt this pane needed came from.
        XCTAssertEqual(GroupsPaneLayout.headerBandHeight,
                       GroupsPaneLayout.headerPadding * 2 + DeviceIconWellView.size, accuracy: 0.01)
        XCTAssertEqual(window.test_editor.test_headerSectionFrame.height,
                       GroupsPaneLayout.headerBandHeight, accuracy: 0.01)

        let icon = window.test_editor.test_headerIconFrame
        let title = window.test_editor.test_headerTitleAlignmentFrame
        XCTAssertEqual(title.minX, icon.maxX + GroupsPaneLayout.iconToTitleGap, accuracy: 0.01,
                       "the title sits BESIDE the icon, one gap away")
        XCTAssertEqual(title.midY, icon.midY, accuracy: 0.01,
                       "…vertically centred on it, not baselined off its bottom")
    }

    func testHeaderContentStartsAtTheSharedContentInset() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)
        let editorInset = window.test_editor.test_headerIconFrame.minX
            - window.test_editor.test_headerSectionFrame.minX
        window.test_select(.device(id: "d0"))
        settle(window)
        let detailInset = window.test_detail.test_headerIconFrame.minX
            - window.test_detail.test_headerSectionFrame.minX

        XCTAssertEqual(editorInset, GroupsPaneLayout.contentLeadingInset, accuracy: 0.01,
                       "the icon starts past the rail gutter the editor reserves")
        XCTAssertEqual(detailInset, GroupsPaneLayout.contentLeadingInset, accuracy: 0.01,
                       "the detail pane reserves the same lane even though it draws no rail — " +
                       "alignment is worth more than reclaiming it")
    }

    /// The HEADER is pinned across both panes (above), but everything BELOW it
    /// in the rail-less detail pane is not: reserving the spine's lane there
    /// left those sections looking hollow on their leading edge, with nothing
    /// occupying the gap (design review 2026-07-25). The two insets must stay
    /// genuinely different, or one of the two halves of that decision has been
    /// quietly undone.
    func testDetailMetadataRowsUseTheRailFreeInsetNotTheHeaderOne() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)

        let rowInset = window.test_detail.test_metadataRowInset
        let headerInset = window.test_detail.test_headerIconFrame.minX
            - window.test_detail.test_headerSectionFrame.minX

        XCTAssertEqual(rowInset, GroupsPaneLayout.railFreeContentLeadingInset, accuracy: 0.01,
                       "no rail runs past the metadata rows, so they don't reserve its lane")
        XCTAssertLessThan(rowInset, headerInset,
                          "the rows must sit tighter than the header, which stays pinned to the " +
                          "editor's for cross-pane alignment")
        XCTAssertGreaterThan(headerInset - rowInset, 1,
                             "a difference this small means the rail-free inset has drifted back " +
                             "toward the header's and the hollow leading edge is returning")
    }

    // MARK: The elastic column

    func testSectionsStretchWithThePaneInsteadOfHuggingTheirContent() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        let pane = window.test_editor.view.frame.width
        let header = window.test_editor.test_headerSectionFrame
        XCTAssertEqual(header.minX, GroupsPaneLayout.columnInset, accuracy: 0.01,
                       "SYMMETRIC margins: the section starts one margin in, not at the pane edge")
        XCTAssertEqual(pane - header.maxX, GroupsPaneLayout.columnTrailingInset, accuracy: 0.01,
                       "…and ends one margin short of the other side, with no dead strip")
        XCTAssertGreaterThan(header.width, 250,
                             "the section fills the pane rather than its ~277pt intrinsic content")
    }

    func testColumnStopsGrowingAtTheContentMaxWidth() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        // A pane far wider than the cap: the section must stop stretching.
        window.window?.setContentSize(NSSize(width: 1200, height: 700))
        settle(window)

        XCTAssertEqual(window.test_editor.test_headerSectionFrame.width,
                       GroupsPaneLayout.contentMaxWidth, accuracy: 0.5,
                       "the column is elastic UP TO the cap — past it the form would read as a slab")
    }

    // MARK: The two anchoring traps the elastic column exposed

    func testEveryNodeStillLandsOnTheOverlaysGutterLineAfterTheColumnMovedIn() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        // The overlay is pinned to the COLUMN. Pinned to the container (as it
        // was) the spine and the nodes separate by exactly `columnInset`.
        for id in window.test_editor.test_candidateDeviceIDs {
            let x = try XCTUnwrap(window.test_editor.test_nodeCenterXInOverlaySpace(for: id))
            XCTAssertEqual(x, PopoverColumnGrid.railGutterCenterX, accuracy: 0.01,
                           "\(id)'s node must sit exactly on the drawn spine")
        }
    }

    func testDeleteButtonLinesUpWithTheContentAboveIt() throws {
        let (window, _, _, group) = try makeWindow()
        window.test_select(.group(id: group.id))
        settle(window)

        XCTAssertEqual(window.test_editor.test_deleteButtonFrame.minX,
                       window.test_editor.test_headerIconFrame.minX, accuracy: 0.01,
                       "the button hangs off the COLUMN like everything else — anchored to the " +
                       "container it drifts one margin to the left of the whole form")
    }

    // MARK: The detail pane adopts the same sections

    func testDetailPaneWearsGroupedSectionsAndNoOrphanedRule() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)

        XCTAssertEqual(window.test_detail.test_sectionCount, 3,
                       "header + device state + In groups, all the same section shape the editor uses")
        XCTAssertFalse(window.test_detail.test_hasBoxDivider,
                       "the stock NSBox rule is gone — it drew a 185pt line that stopped a third of " +
                       "the way across the pane; the sections' own inset hairlines separate rows now")
    }

    func testDetailValuesRightAlignIntoTheSectionsWidth() throws {
        let (window, _, _, _) = try makeWindow()
        window.test_select(.device(id: "d0"))
        settle(window)

        let section = window.test_detail.test_stateSectionFrame
        let valueTrailing = window.test_detail.test_valueTrailingX
        XCTAssertEqual(section.maxX - valueTrailing, GroupsPaneLayout.contentTrailingInset,
                       accuracy: 2.5,
                       "values right-align on the section's own inset edge (± the text field's own " +
                       "alignment inset), instead of hanging off a fixed 90pt caption column")
    }
}
