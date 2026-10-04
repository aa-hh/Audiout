// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutCore
@testable import AudioutWindowUI

@MainActor
@Suite final class SpeakersOverviewTests: IsolatedSuite {
    // A zero-height table control or missing action breaks visible individual visibility changes without playback.
    @Test func individualAndBulkActionsSharePreferencesWithoutPlayback() throws {
        let local = Device(id: "mac", name: "Mac", kind: .localMac, isLocalDevice: true)
        let bt = Device(id: "bt", name: "Bluetooth", kind: .bluetooth, isAvailable: false)
        let network = Device(id: "airplay", name: "AirPlay", kind: .sonos)
        let backend = MockBackend(fleet: [local, bt, network], staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let groups = GroupController(backend: backend, store: GroupStore(directory: scratchDir),
                                     routingStore: RoutingStore(directory: scratchDir),
                                     settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        groups.updateDevices([local, bt, network])
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [local, bt, network], groups: [])
        let pane = SpeakersOverviewViewController(library: library)
        pane.reload()
        pane.view.frame = NSRect(x: 0, y: 0, width: 440, height: 400)
        pane.view.layoutSubtreeIfNeeded()
        for id in pane.test_recordIDs {
            let popup = try #require(pane.test_visibilityPopup(id: id))
            #expect(popup.isDescendant(of: pane.view))
            #expect(popup.visibleRect.width > 100)
            #expect(popup.visibleRect.height >= 20)
            #expect(popup.titleOfSelectedItem == SpeakerMixerVisibility.whenAvailable.label)
            #expect(popup.isEnabled == (id != local.id))
        }
        #expect(pane.test_visibilityColumnTitle == "Show in Mixer")
        pane.test_changeVisibility(.always, id: "bt")
        #expect(library.visibility(for: "bt") == .always)
        let secondPane = SpeakersOverviewViewController(library: library)
        secondPane.reload()
        secondPane.view.frame = NSRect(x: 0, y: 0, width: 440, height: 400)
        secondPane.view.layoutSubtreeIfNeeded()
        secondPane.test_select(["bt", "airplay"])
        #expect(secondPane.test_bulkTitle == "Mixed")
        secondPane.test_selectAll()
        #expect(secondPane.test_bulkShown)
        secondPane.test_changeBulkVisibility(.hideWhenNotInUse)
        #expect(library.visibility(for: "bt") == .hideWhenNotInUse)
        #expect(library.visibility(for: "airplay") == .hideWhenNotInUse)
        #expect(library.visibility(for: "mac") == .whenAvailable)
        pane.test_changeVisibility(.always, id: "mac")
        #expect(library.visibility(for: "mac") == .whenAvailable)
        #expect(groups.activeGroupID == nil)
        #expect(!groups.isSpeakerSelected("bt"))
        #expect(!groups.isSpeakerSelected("airplay"))
    }
    // A popup retained while discovery reorders rows must still edit its original speaker ID.
    @Test func individualPopupRetainsIdentityAcrossAvailabilityReorder() throws {
        let a = Device(id: "a", name: "Alpha", kind: .sonos)
        let b = Device(id: "b", name: "Beta", kind: .sonos)
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [a, b], groups: [])
        let pane = SpeakersOverviewViewController(library: library)
        pane.reload()
        pane.view.frame = NSRect(x: 0, y: 0, width: 440, height: 400)
        pane.view.layoutSubtreeIfNeeded()
        let popup = try #require(pane.test_visibilityPopup(id: a.id))
        let before = pane.test_recordIDs
        var unavailable = a
        unavailable.isAvailable = false
        library.update(liveDevices: [unavailable, b], groups: [])
        pane.reload()
        #expect(pane.test_recordIDs != before)
        popup.selectItem(withTitle: SpeakerMixerVisibility.always.label)
        NSApp.sendAction(try #require(popup.action), to: popup.target, from: popup)
        #expect(library.visibility(for: a.id) == .always)
        #expect(library.visibility(for: b.id) == .whenAvailable)
    }

    // A table wider than the visible scroll area clips the Show in Mixer arrows when a legacy scrollbar appears.
    @Test func visibilityPopupFitsBesideVisibleLegacyScrollbar() throws {
        let longName = "A very long speaker name that must truncate when the scrollbar takes space"
        let devices = (0..<8).map { index in
            Device(id: "speaker-\(index)", name: index == 0 ? longName : "Speaker \(index)", kind: .sonos)
        }
        let library = SpeakerLibraryController(store: SpeakerLibraryStore(directory: scratchDir),
                                               loadPersisted: false)
        library.update(liveDevices: devices, groups: [])
        let pane = SpeakersOverviewViewController(library: library)
        pane.reload()
        pane.setBluetoothAccessExplanation(
            "Allow Bluetooth access in System Settings to see paired speakers that are not connected.",
            actionTitle: "Open Bluetooth Privacy…")
        let scroll = try #require(pane.view.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        pane.view.frame = NSRect(x: 0, y: 0, width: 440, height: 400)
        pane.view.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()

        let table = try #require(scroll.documentView as? NSTableView)
        let clip = scroll.contentView
        #expect(scroll.verticalScroller?.isHidden == false)
        #expect(table.frame.height > clip.bounds.height)
        #expect(table.tableColumns[1].width == 172)
        #expect(table.tableColumns[0].width < GroupsPaneLayout.contentMaxWidth - 172)
        let popup = try #require(pane.test_visibilityPopup(id: "speaker-0"))
        let popupInClip = popup.convert(popup.bounds, to: clip)
        #expect(popupInClip.maxX <= clip.bounds.maxX + 0.5)
        #expect(popupInClip.minX >= clip.bounds.minX - 0.5)
        let identityCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSStackView)
        let labels = try #require(identityCell.arrangedSubviews.last as? NSStackView)
        let name = try #require(labels.arrangedSubviews.first as? NSTextField)
        #expect(name.intrinsicContentSize.width > name.bounds.width)
        #expect(name.convert(name.bounds, to: clip).maxX < popupInClip.minX)
        #expect(popup.titleOfSelectedItem == SpeakerMixerVisibility.whenAvailable.label)
        #expect(popup.isEnabled)
    }

}
