// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// The speaker sidebar: its two groups (the Mixer visibility setting), the
/// reachable-first order with its divider, the row context menu,
/// Command-Delete, drag between groups, the fold, and Cmd-N. The menu acts on the CLICKED row rather than the selected one, so
/// the clicked-vs-selected arbitration is what several of these pin down.
///
/// The sidebar is built on its own here (no window, no split view, no
/// `GroupController`) — it needs none of them, and every action runs through
/// its real `NSMenu`/`NSMenuItem`/`NSEvent` path with only the clicked row
/// injected.
@MainActor
@Suite final class SidebarActionsTests: IsolatedSuite {

    // Making Speakers a nonselectable header again breaks empty-fleet navigation and repeated clicks.
    @Test func speakersCollectionSelectsAndReopensWhenEmpty() {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.reload(devices: [])
        var selections: [SidebarSelection?] = []
        sidebar.onSelect = { selections.append($0) }
        sidebar.test_select(.speakersOverview)
        sidebar.test_clickSpeakersRow()
        #expect(selections == [.speakersOverview, .speakersOverview])
        #expect(sidebar.currentSelection == .speakersOverview)
    }

    // Turns red when the Overview row goes back to a grey header cell, loses its chevron or its "Speakers overview" spoken label, or stops re-reporting a repeated click.
    @Test func speakersRowIsAPlateThatReopens() throws {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.reload(devices: [])
        #expect(sidebar.test_speakersRowIsPlate)
        let cell = try #require(sidebar.test_speakersRowCell)
        #expect(cell.nameLabel.stringValue == "Overview")
        #expect(cell.disclosureView.isHidden == false)
        #expect(cell.nameLabel.accessibilityLabel() == "Speakers overview")
        var selections: [SidebarSelection?] = []
        sidebar.onSelect = { selections.append($0) }
        sidebar.test_select(.speakersOverview)
        sidebar.test_clickSpeakersRow()
        #expect(selections == [.speakersOverview, .speakersOverview])
    }

    // Turns red when the caption returns to every speaker row, leaves the hidden speaker in use, or the captioned row stops being 12 pt taller than the others.
    @Test func onlyAHiddenSpeakerInUseCarriesTheCaption() throws {
        let (sidebar, _) = makeFleetSidebar()
        let cell = try #require(sidebar.test_deviceCell(id: "onkyo"))
        let name = try #require(cell.textField)
        let caption = cell.statusLabel
        let captionedHeight = sidebar.test_standardRowHeight + 12
        #expect(sidebar.test_rowCaption(id: "onkyo") == "Shown while in use")
        #expect(sidebar.test_rowHeight(id: "onkyo") == captionedHeight)
        #expect(!name.convert(name.bounds, to: cell).intersects(caption.convert(caption.bounds, to: cell)))
        for id in ["mac", "alpha", "kitchen", "study", "zeta", "den"] {
            #expect(sidebar.test_rowCaption(id: id) == nil, "\(id) shows no caption")
            #expect(sidebar.test_rowHeight(id: id) != captionedHeight, "\(id) stays one line")
        }
    }

    // MARK: Fleet fixture

    /// The fleet's one scene, which keeps the lost "study" known.
    private static var fleetScene: Group {
        Group(id: "g", name: "Evening", memberIDs: ["study"], memberVolumes: [:])
    }

    /// This Mac, two found speakers, one away, and two hidden speakers of
    /// which one (Bluetooth, connected) is in use.
    private static var fleet: [Device] {
        [
            Device(id: "zeta", name: "Zeta", kind: .generic),
            Device(id: "mac", name: "MacBook Pro Speakers", kind: .localMac, isLocalDevice: true),
            Device(id: "kitchen", name: "Kitchen", kind: .sonos, isAvailable: false),
            Device(id: "onkyo", name: "Onkyo", kind: .bluetooth, connectionState: .connected),
            Device(id: "alpha", name: "Alpha", kind: .homePod),
            Device(id: "den", name: "Den", kind: .generic),
        ]
    }

    /// The fleet, plus "study", seen once and then gone, in a scene.
    private func makeFleetLibrary() -> SpeakerLibraryController {
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: Self.fleet + [Device(id: "study", name: "Study", kind: .generic)],
                       groups: [Self.fleetScene])
        library.setVisibility(.hideWhenNotInUse, for: ["den", "onkyo"])
        library.update(liveDevices: Self.fleet, groups: [Self.fleetScene])
        return library
    }

    private func reload(_ sidebar: SidebarViewController, from library: SpeakerLibraryController,
                        cantBeFoundIDs: Set<String> = [], splitsUnreachable: Bool = true) {
        sidebar.reload(devices: library.records.map(\.renderingDevice),
                       presentationRecords: library.records,
                       cantBeFoundIDs: cantBeFoundIDs, splitsUnreachable: splitsUnreachable)
    }

    /// The fleet sidebar, laid out tall enough that every row has a cell.
    private func makeFleetSidebar(cantBeFoundIDs: Set<String> = [], splitsUnreachable: Bool = true)
        -> (SidebarViewController, SpeakerLibraryController) {
        let library = makeFleetLibrary()
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        reload(sidebar, from: library, cantBeFoundIDs: cantBeFoundIDs, splitsUnreachable: splitsUnreachable)
        sidebar.onSetVisibility = { [weak sidebar] ids, visibility in
            library.setVisibility(visibility, for: ids)
            if let sidebar {
                self.reload(sidebar, from: library, cantBeFoundIDs: cantBeFoundIDs,
                            splitsUnreachable: splitsUnreachable)
            }
        }
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 210, height: 800)
        sidebar.view.layoutSubtreeIfNeeded()
        return (sidebar, library)
    }

    // MARK: Groups, order, reachability

    // Turns red when the split runs from the first frame (before every kind is known), stops putting This Mac and the reachable speakers above the divider, or files a hidden speaker under Shown in Mixer.
    @Test func speakersSplitIntoTheTwoGroupsAlphabeticallyWithThisMacFirst() {
        let (sidebar, library) = makeFleetSidebar(splitsUnreachable: false)
        #expect(sidebar.test_sectionTitles == ["System Audio", "Speakers", "Shown in Mixer", "Hidden unless in use"])
        #expect(sidebar.test_groupRows(inGroupTitled: "Shown in Mixer") == ["mac", "alpha", "kitchen", "study", "zeta"])

        reload(sidebar, from: library)
        #expect(sidebar.test_groupRows(inGroupTitled: "Shown in Mixer")
                == ["mac", "alpha", "zeta", "2 unavailable", "kitchen", "study"])
        #expect(sidebar.test_groupRows(inGroupTitled: "Hidden unless in use") == ["den", "onkyo"])
    }

    // Turns red when an unreachable row stops saying so, a speaker outside the can't-be-found list speaks as can't be found, or the hidden speaker in use loses its spoken suffix.
    @Test func eachRowSpeaksItsReachability() throws {
        let (sidebar, library) = makeFleetSidebar()
        let spoken = { (id: String) in sidebar.test_deviceCell(id: id)?.nameLabel.accessibilityLabel() }
        #expect(spoken("study") == "Study, unavailable")
        #expect(spoken("kitchen") == "Kitchen, unavailable")
        #expect(spoken("onkyo") == "Onkyo, shown in the Mixer while in use")
        #expect(spoken("alpha") == "Alpha")

        reload(sidebar, from: library, cantBeFoundIDs: ["study"])
        #expect(spoken("study") == "Study, can\u{2019}t be found")
    }

    // Turns red when a reload falls back to reloadData and keeps only the first selected row, or stops moving a speaker that becomes unreachable under the divider.
    @Test func aMultipleSelectionSurvivesARowMovingUnderTheDivider() {
        let (sidebar, library) = makeFleetSidebar()
        sidebar.test_selectDevices(["alpha", "zeta"])
        let zetaGone = Self.fleet.map { device -> Device in
            var device = device
            if device.id == "zeta" { device.isAvailable = false }
            return device
        }
        library.update(liveDevices: zetaGone, groups: [Self.fleetScene])
        reload(sidebar, from: library)
        #expect(sidebar.test_selectedDeviceIDs == ["alpha", "zeta"])
        #expect(sidebar.test_groupRows(inGroupTitled: "Shown in Mixer")
                == ["mac", "alpha", "3 unavailable", "kitchen", "study", "zeta"])
    }

    // Turns red when viewDidDisappear stops clearing the pointer hold, so a sidebar left with the pointer on it holds every later reload until the pointer crosses it again.
    @Test func leavingTheWindowWithThePointerOnTheListReleasesTheHold() {
        let sidebar = makeSidebar()
        sidebar.test_pointerEntersList()
        sidebar.viewDidDisappear()
        sidebar.reload(devices: [makeDevice(id: "office", name: "Office"),
                                 makeDevice(id: "kitchen", name: "Kitchen"),
                                 makeDevice(id: "patio", name: "Patio"),
                                 makeDevice(id: "attic", name: "Attic")])
        #expect(sidebar.test_groupRows(inGroupTitled: "Shown in Mixer") == ["attic", "kitchen", "office", "patio"])
    }

    // Turns red when the selection filter keeps a header or divider a click proposes (or clears the selection there), keeps the divider in a range, or pulls the Overview plate into one.
    @Test func theDividerAndThePlatesStayOutOfSelections() {
        let (sidebar, _) = makeFleetSidebar()
        sidebar.test_selectDevices(["alpha"])
        for key in ["System Audio", "Speakers", "Shown in Mixer", "2 unavailable", "Hidden unless in use"] {
            #expect(sidebar.test_filteredSelection(ofRowKeys: [key]) == ["alpha"], "a click on \(key) changes nothing")
        }
        #expect(sidebar.test_filteredSelection(ofRowKeys: ["alpha", "2 unavailable", "kitchen"]) == ["alpha", "kitchen"])
        #expect(sidebar.test_filteredSelection(ofRowKeys: ["Overview", "alpha"]) == ["alpha"])
    }

    // Turns red when the selection filter lets an arrow key land on a header or divider (reporting nil, which resets the page to Overview) or stops it there instead of moving on to the next row it may select.
    @Test func arrowKeysStepOverHeadersAndDividers() {
        let (sidebar, _) = makeFleetSidebar()
        var reported: [SidebarSelection?] = []
        sidebar.onSelect = { reported.append($0) }

        sidebar.select(.device(id: "zeta"), notify: false)
        sidebar.test_pressArrow(down: true)
        #expect(sidebar.currentSelection == .device(id: "kitchen"), "down from the last reachable speaker skips the divider")

        sidebar.select(.device(id: "study"), notify: false)
        sidebar.test_pressArrow(down: true)
        #expect(sidebar.currentSelection == .device(id: "den"), "down across the Hidden header")

        sidebar.select(.device(id: "mac"), notify: false)
        sidebar.test_pressArrow(down: false)
        #expect(sidebar.currentSelection == .speakersOverview, "up across the Shown in Mixer header")
        sidebar.test_pressArrow(down: false)
        #expect(sidebar.currentSelection == .mainOut, "up across the Speakers title")
        sidebar.test_pressArrow(down: false)
        #expect(sidebar.currentSelection == .mainOut, "the System Audio title above stays out of reach")

        #expect(reported == [.device(id: "kitchen"), .device(id: "den"), .speakersOverview, .mainOut])
    }

    // Turns red when applySelectionInks leaves any of the name, icon, caption or chevron on its resting ink under either pill, or keeps a pill ink once the row is deselected.
    @Test func everyInkInASelectedRowFollowsThePill() throws {
        let (sidebar, _) = makeFleetSidebar()
        let resting: [NSColor?] = [Tokens.Color.label, Tokens.Color.label, Tokens.Color.labelCool, Tokens.Color.labelCool2]
        for target in [SidebarSelection.device(id: "onkyo"), .speakersOverview] {
            sidebar.select(target, notify: false)
            let rowView = try #require(sidebar.test_rowView(for: target))
            let cell = try #require(rowView.view(atColumn: 0) as? IconLabelCellView)
            let inks = { [cell.nameLabel.textColor, cell.imageView?.contentTintColor,
                          cell.statusLabel.textColor, cell.disclosureView.contentTintColor] }
            rowView.isEmphasized = true
            #expect(inks() == Array(repeating: NSColor.alternateSelectedControlTextColor, count: 4), "\(target) focused pill")
            rowView.isEmphasized = false
            #expect(inks() == Array(repeating: Tokens.Color.label, count: 4), "\(target) grey pill")
            sidebar.select(.groupsOverview, notify: false)
            #expect(inks() == resting, "\(target) deselected")
        }
    }

    // Turns red when the hidden group's header is built with no rows under it, or a reload re-expands a group the user folded.
    @Test func theHiddenGroupAppearsOnlyWithRowsAndItsFoldSurvivesAReload() {
        let sidebar = makeSidebar()
        #expect(sidebar.test_sectionTitles == ["System Audio", "Speakers", "Shown in Mixer"])

        let (fleet, library) = makeFleetSidebar()
        #expect(!fleet.test_hiddenGroupCollapsed)
        fleet.test_collapseHiddenGroup()
        #expect(fleet.test_hiddenGroupCollapsed)
        reload(fleet, from: library)
        #expect(fleet.test_hiddenGroupCollapsed, "the fold is the user's, not the reload's")
    }

    // Turns red when the method drifts off AppKit's `outlineView(_:shouldShowOutlineCellForItem:)` selector, so AppKit never asks and every header gets the default Show/Hide, or when a header other than the hidden group answers true.
    @Test func onlyTheHiddenGroupHeaderShowsTheFoldControl() throws {
        let (sidebar, _) = makeFleetSidebar()
        let scrollView = sidebar.view.subviews.first { $0 is NSScrollView } as? NSScrollView
        let outlineView = try #require(scrollView?.documentView as? NSOutlineView)
        let delegate = try #require(outlineView.delegate)
        let answers: [String: Bool?] = Dictionary(uniqueKeysWithValues:
            (0..<outlineView.numberOfChildren(ofItem: nil)).compactMap { index -> (String, Bool?)? in
                guard let node = outlineView.child(index, ofItem: nil) as? SidebarViewController.Node,
                      case .header(let title) = node.payload else { return nil }
                return (title, delegate.outlineView?(outlineView, shouldShowOutlineCellForItem: node))
            })
        #expect(answers == ["System Audio": false, "Speakers": false, "Shown in Mixer": false,
                            SidebarViewController.hiddenTitle: true])
    }

    // MARK: Drag between groups

    // Turns red when a drop onto a speaker's own group is accepted, This Mac can be dragged into hiding, or a drop reports the wrong visibility.
    @Test func dropOntoTheOtherHeaderReportsItsVisibility() {
        let (sidebar, _) = makeFleetSidebar()
        #expect(sidebar.test_dropTarget(ids: ["den"], ontoHeaderTitled: "Shown in Mixer") == .whenAvailable)
        #expect(sidebar.test_dropTarget(ids: ["alpha"], ontoHeaderTitled: "Hidden unless in use") == .hideWhenNotInUse)
        #expect(sidebar.test_dropTarget(ids: ["alpha"], ontoHeaderTitled: "Shown in Mixer") == nil)
        #expect(sidebar.test_dropTarget(ids: ["den"], ontoHeaderTitled: "Hidden unless in use") == nil)
        #expect(sidebar.test_dropTarget(ids: ["mac"], ontoHeaderTitled: "Hidden unless in use") == nil)
    }

    private func makeDevice(id: String, name: String) -> Device {
        Device(id: id, name: name, kind: .generic, isAvailable: true)
    }

    /// A loaded sidebar with three speakers and no library records.
    private func makeSidebar() -> SidebarViewController {
        let sidebar = SidebarViewController()
        _ = sidebar.view      // triggers `loadView`
        sidebar.reload(devices: [makeDevice(id: "office", name: "Office"),
                                 makeDevice(id: "kitchen", name: "Kitchen"),
                                 makeDevice(id: "patio", name: "Patio")])
        return sidebar
    }

    // MARK: Menu contents per row kind

    // Turns red when a single speaker's menu loses Hide, Keep or Speaker settings…, offers Show in the first group, or brings back "Add scene from…".
    @Test func speakerRowMenuMatchesItsGroup() {
        let (sidebar, _) = makeFleetSidebar()
        #expect(sidebar.test_contextMenuItems(for: .device(id: "alpha"))
                == ["Hide from Mixer", "Show even when unavailable", "", "Speaker settings…"])
        #expect(sidebar.test_contextMenuItems(for: .device(id: "den"))
                == ["Show in Mixer", "", "Speaker settings…"])
        #expect(sidebar.test_contextMenuItems(for: .device(id: "mac")) == ["Speaker settings…"])
    }

    // Turns red when a multi-selection counts This Mac, drops either half of a split selection, or offers Keep or Speaker settings… across groups.
    @Test func speakerRowMenuCountsAMultiSelection() {
        let (sidebar, library) = makeFleetSidebar()
        sidebar.test_selectDevices(["mac", "alpha", "den"])
        #expect(sidebar.test_contextMenuItems(for: .device(id: "alpha"))
                == ["Hide 1 speaker from Mixer", "Show 1 speaker in Mixer"])

        library.setVisibility(.always, for: "alpha")
        reload(sidebar, from: library)
        sidebar.test_selectDevices(["alpha", "zeta"])
        #expect(sidebar.test_contextMenuItems(for: .device(id: "zeta"))
                == ["Hide 2 speakers from Mixer", "Show even when unavailable"])
        #expect(sidebar.test_contextMenuItemState("Show even when unavailable", for: .device(id: "zeta")) == .mixed)
    }

    // Turns red when Keep stops toggling between Always and When available, or its checkmark stops reading the speaker's setting.
    @Test func keepInMixerTogglesAlwaysThroughOnSetVisibility() {
        let (sidebar, library) = makeFleetSidebar()
        let keep = "Show even when unavailable"
        #expect(sidebar.test_contextMenuItemState(keep, for: .device(id: "alpha")) == .off)
        sidebar.test_clickContextMenuItem(keep, for: .device(id: "alpha"))
        #expect(library.visibility(for: "alpha") == .always)
        #expect(sidebar.test_contextMenuItemState(keep, for: .device(id: "alpha")) == .on)
        sidebar.test_clickContextMenuItem(keep, for: .device(id: "alpha"))
        #expect(library.visibility(for: "alpha") == .whenAvailable)
    }

    // Turns red when Forget is offered for a speaker outside the can't-be-found list (one not seen yet in the first seconds, or one the Mac can see), or reports a found speaker's id.
    @Test func forgetIsOfferedOnlyForLostSpeakersAndReportsOnlyThem() {
        let (sidebar, library) = makeFleetSidebar()
        var forgotten: [Set<String>] = []
        sidebar.onForget = { forgotten.append($0) }
        #expect(sidebar.test_contextMenuItems(for: .device(id: "study"))
                == ["Hide from Mixer", "Show even when unavailable", "", "Speaker settings…"])

        reload(sidebar, from: library, cantBeFoundIDs: ["study"])
        #expect(sidebar.test_contextMenuItems(for: .device(id: "study"))
                == ["Hide from Mixer", "Show even when unavailable", "", "Speaker settings…",
                    "", "Forget \u{201C}Study\u{201D}…"])
        #expect(!sidebar.test_contextMenuItems(for: .device(id: "kitchen")).contains { $0.hasPrefix("Forget") })

        sidebar.test_selectDevices(["kitchen", "study"])
        #expect(sidebar.test_clickContextMenuItem("Forget \u{201C}Study\u{201D}…", for: .device(id: "kitchen")))
        #expect(forgotten == [["study"]])
    }

    // Turns red when Command-Delete stops reaching the sidebar from the outline view, or forgets a selected speaker outside the can't-be-found list.
    @Test func commandDeleteForgetsOnlyTheSelectedSpeakersThatCantBeFound() {
        let (sidebar, _) = makeFleetSidebar(cantBeFoundIDs: ["study"])
        var forgotten: [Set<String>] = []
        sidebar.onForget = { forgotten.append($0) }

        sidebar.test_selectDevices(["alpha", "study"])
        sidebar.test_pressCommandDelete()
        #expect(forgotten == [["study"]])

        sidebar.test_selectDevices(["alpha"])
        sidebar.test_pressCommandDelete()
        #expect(forgotten == [["study"]], "a reachable speaker alone is never forgotten")
    }

    // Turns red when Speaker settings… stops selecting the speaker's row and reporting it.
    @Test func speakerSettingsSelectsTheRow() {
        let (sidebar, _) = makeFleetSidebar()
        var reported: [SidebarSelection?] = []
        sidebar.onSelect = { reported.append($0) }
        sidebar.test_clickContextMenuItem("Speaker settings…", for: .device(id: "kitchen"))
        #expect(reported == [.device(id: "kitchen")])
        #expect(sidebar.currentSelection == .device(id: "kitchen"))
    }

    @Test func mainAudioRowHasNoMenu() {
        let sidebar = makeSidebar()
        #expect(sidebar.test_contextMenuItems(for: .mainOut).isEmpty)
    }

    @Test func headerRowsHaveNoMenu() {
        let sidebar = makeSidebar()
        // Section headers and the plate carry no identity to act on.
        #expect(sidebar.test_contextMenuItems(forRowTitled: "System Audio").isEmpty)
        #expect(sidebar.test_contextMenuItems(forRowTitled: "Shown in Mixer").isEmpty)
        #expect(sidebar.test_contextMenuItems(for: .speakersOverview).isEmpty)
    }

    // MARK: Clicked-vs-selected arbitration

    @Test func rightClickInsideTheSelectionActsOnTheWholeSelection() {
        let sidebar = makeSidebar()
        var hidden: Set<String>?
        sidebar.onSetVisibility = { ids, _ in hidden = ids }

        sidebar.test_selectDevices(["office", "patio"])
        sidebar.test_clickContextMenuItem("Hide 2 speakers from Mixer", for: .device(id: "patio"))

        #expect(hidden == ["office", "patio"], "a clicked row inside the selection keeps it")
    }

    @Test func rightClickOutsideTheSelectionActsOnThatRowAlone() {
        let sidebar = makeSidebar()
        var hidden: Set<String>?
        sidebar.onSetVisibility = { ids, _ in hidden = ids }

        sidebar.test_selectDevices(["office", "patio"])
        sidebar.test_clickContextMenuItem("Hide from Mixer", for: .device(id: "kitchen"))

        #expect(hidden == ["kitchen"], "a clicked row outside the selection replaces it")
    }

    @Test func rightClickWithNothingSelectedActsOnTheClickedRow() {
        let sidebar = makeSidebar()
        var hidden: Set<String>?
        sidebar.onSetVisibility = { ids, _ in hidden = ids }

        sidebar.test_clickContextMenuItem("Hide from Mixer", for: .device(id: "office"))

        #expect(hidden == ["office"])
    }

    // MARK: Cmd-N

    @Test func cmdNWithNothingSelectedCreatesAnEmptyGroup() {
        let sidebar = makeSidebar()
        var addCount = 0
        var fromSelection: [String]?
        sidebar.onAddGroup = { addCount += 1 }
        sidebar.onNewGroupFromSelection = { fromSelection = $0 }

        #expect(sidebar.test_performCmdN(), "the sidebar claims the key equivalent")
        #expect(addCount == 1)
        #expect(fromSelection == nil)
    }

    @Test func cmdNWithSpeakersSelectedCreatesFromThatSelection() {
        let sidebar = makeSidebar()
        var addCount = 0
        var fromSelection: [String]?
        sidebar.onAddGroup = { addCount += 1 }
        sidebar.onNewGroupFromSelection = { fromSelection = $0 }

        sidebar.test_selectDevices(["kitchen", "patio"])
        #expect(sidebar.test_performCmdN())

        #expect(fromSelection == ["kitchen", "patio"], "Cmd-N routes exactly like the + button")
        #expect(addCount == 0)
    }

    @Test func cmdNAndThePlusButtonShareOnePath() {
        let sidebar = makeSidebar()
        var calls: [[String]] = []
        sidebar.onNewGroupFromSelection = { calls.append($0) }

        sidebar.test_selectDevices(["office"])
        sidebar.test_tapAdd()
        #expect(sidebar.test_performCmdN())

        #expect(calls == [["office"], ["office"]])
    }

    /// ⌘N is dispatched down the VIEW TREE, before the responder chain sees
    /// the key — so the sidebar was claiming it out from under a text field
    /// the user was typing in.
    @Test func cmdNYieldsToAFieldEditor() {
        let sidebar = makeSidebar()
        var fired = 0
        sidebar.onAddGroup = { fired += 1 }
        sidebar.onNewGroupFromSelection = { _ in fired += 1 }

        // Never ordered front — tests stay invisible.
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextField(string: "typing")
        field.isEditable = true
        field.frame = NSRect(x: 0, y: 260, width: 400, height: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 260)
        container.addSubview(sidebar.view)
        container.addSubview(field)
        host.contentView = container
        guard host.makeFirstResponder(field),
              field.currentEditor() != nil else {
            return   // no field editor in this environment (see GroupRenameFieldTests' note)
        }

        #expect(!sidebar.test_performCmdN(), "the field editor keeps the key")
        #expect(fired == 0)
    }

    // MARK: A selection whose target is gone

    @Test func selectingADeviceThatNoLongerExistsClearsTheHighlight() {
        let sidebar = makeSidebar()
        sidebar.test_select(.device(id: "office"))
        #expect(sidebar.currentSelection == .device(id: "office"))

        sidebar.reload(devices: [makeDevice(id: "kitchen", name: "Kitchen")])

        #expect(sidebar.currentSelection == nil,
                "the row it named is gone — the list must not keep drawing it as selected")
    }

    // MARK: VoiceOver state on a row (P1-8 / P3-6)

    /// Unavailable was COLOUR ONLY. The spoken label carries it — and,
    /// because cells are reused, an ordinary row must never inherit the last
    /// one's suffix.
    @Test func rowLabelsSpeakUnavailable() throws {
        let sidebar = SidebarViewController()
        _ = sidebar.view
        sidebar.reload(devices: [makeDevice(id: "office", name: "Office"),
                                 makeDevice(id: "patio", name: "Patio")])

        let offline = Device(id: "patio", name: "Patio", kind: .generic, isAvailable: false)
        let offlineCell = try #require(
            sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                item: SidebarViewController.Node(.device(offline)))
                as? NSTableCellView)
        #expect(offlineCell.textField?.accessibilityLabel() == "Patio, unavailable")

        let ordinaryCell = try #require(
            sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                item: SidebarViewController.Node(
                                    .device(makeDevice(id: "office", name: "Office"))))
                as? NSTableCellView)
        #expect(ordinaryCell.textField?.accessibilityLabel() == "Office",
                "a reused cell must not keep the previous row's suffix")
        // The glyph is DECORATIVE: it must not repeat the row, which is what
        // VoiceOver read twice before. Note it cannot be made description-LESS
        // — passing nil to `NSImage(systemSymbolName:accessibilityDescription:)`
        // leaves the SYMBOL's own built-in name ("HiFi Speaker"), which says
        // nothing about this row and is what the platform speaks for every
        // undescribed symbol. Not being the row's name is the whole fix.
        #expect(ordinaryCell.imageView?.image?.accessibilityDescription != "Office",
                "the glyph never carries the row's own name")
    }

    // Double-click-to-rename left this file with the group rows (direction C):
    // rename lives on the overview's cards now, covered by
    // `GroupsOverviewViewControllerTests`. A speaker row's first click already
    // opens its detail pane, so the sidebar keeps no `doubleAction` at all.
}
