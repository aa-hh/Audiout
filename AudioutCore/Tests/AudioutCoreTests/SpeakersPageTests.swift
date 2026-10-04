// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// The Speakers page behind the sidebar's plate: it lists no speakers and
/// shows only the rows that are true, ending with Pair.
@MainActor
@Suite final class SpeakersPageTests: IsolatedSuite {

    private func makeController() -> GroupController {
        GroupController(backend: MockBackend(fleet: []),
                        store: GroupStore(directory: scratchDir.appendingPathComponent(UUID().uuidString,
                                                                                       isDirectory: true)),
                        loadPersisted: false)
    }

    private func device(_ id: String, kind: Device.Kind = .generic, available: Bool = true) -> Device {
        Device(id: id, name: id.capitalized, kind: kind, isAvailable: available)
    }

    // Showing a row that isn't true, miscounting the subtitle or the lost speaker's scenes, or moving Pair off the end turns it red.
    @Test func onlyTrueRowsShowInOrder() throws {
        let controller = makeController()
        let library = SpeakerLibraryController(loadPersisted: false)
        let mac = device("mac", kind: .localMac)
        library.update(liveDevices: [mac, device("kitchen"), device("den")], groups: [])
        let page = SpeakersPageViewController(library: library, groupController: controller)
        #expect(page.test_rowTitles == ["All 3 speakers found on your network", "Pair Bluetooth speaker\u{2026}"])
        #expect(!page.test_discoveryShowsSpinner)
        #expect(page.test_subtitleText == "3 speakers: 3 in the Mixer, 0 hidden")

        let first = try controller.createGroup(name: "First", memberIDs: ["study", "kitchen"], memberVolumes: [:]).group
        let second = try controller.createGroup(name: "Second", memberIDs: ["study", "den"], memberVolumes: [:]).group
        library.update(liveDevices: [mac, device("kitchen"), device("den"), device("study")], groups: [first, second])
        library.update(liveDevices: [mac, device("kitchen", available: false), device("den", available: false)],
                       groups: [first, second])
        library.setVisibility(.hideWhenNotInUse, for: "den")
        let denied = SpeakerBluetoothAccessPresentation(status: .denied, priming: false)
        page.setBluetoothAccess(denied)

        #expect(page.test_rowTitles == [
            "Looking for speakers on your network\u{2026}",
            "Bluetooth access is off",
            "1 speaker can\u{2019}t be found",
            "Pair Bluetooth speaker\u{2026}",
        ])
        #expect(page.test_discoveryShowsSpinner)
        #expect(page.test_subtitleText == "4 speakers: 3 in the Mixer, 1 hidden")
        #expect(page.test_rowButtonTitle(forRowTitled: "Bluetooth access is off") == denied.actionTitle)
        #expect(page.test_rowCaption(forRowTitled: "1 speaker can\u{2019}t be found")
                == "Forgetting it takes it out of 2 scenes.")
        #expect(page.test_rowButtonTitle(forRowTitled: "1 speaker can\u{2019}t be found") == "Forget 1 speaker\u{2026}")
    }

    // Reporting a found speaker to Forget, or a Pair or Bluetooth row that fires nothing, turns it red.
    @Test func forgetReportsExactlyTheLostIDsAndTheRowsFire() {
        let library = SpeakerLibraryController(loadPersisted: false)
        let mac = device("mac", kind: .localMac)
        library.update(liveDevices: [mac, device("kitchen"), device("attic"), device("garage")], groups: [],
                       confirmedUsedIDs: ["attic", "garage"])
        library.update(liveDevices: [mac, device("kitchen")], groups: [])
        let page = SpeakersPageViewController(library: library, groupController: makeController())
        page.setBluetoothAccess(SpeakerBluetoothAccessPresentation(status: .unknown, priming: false))

        var forgotten: [Set<String>] = []
        var paired = 0
        var accessAsked = 0
        page.onForget = { forgotten.append($0) }
        page.onPairBluetooth = { paired += 1 }
        page.onBluetoothAccess = { accessAsked += 1 }

        let lostRow = "2 speakers can\u{2019}t be found"
        #expect(page.test_rowCaption(forRowTitled: lostRow) == "They aren\u{2019}t in any scene.")
        page.test_clickRowButton(forRowTitled: lostRow)
        #expect(forgotten == [["attic", "garage"]])
        page.test_clickPairRow()
        #expect(paired == 1)
        page.test_clickRowButton(forRowTitled: "Bluetooth access is off")
        #expect(accessAsked == 1)
    }
}
