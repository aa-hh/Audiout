// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// The Speakers page behind the sidebar's plate: its caption is the search
/// result, and one card counts the speakers by kind and then shows only the
/// rows that are true, ending with Pair. Nested under `SerializedSharedState`
/// because the counts event goes through the process-wide `Analytics` sink.
extension SerializedSharedState {

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

    /// Holds each armed timer so a test fires exactly the one it means to.
    private final class Timers {
        var pending: [() -> Void] = []
        func schedule(_ delay: TimeInterval, _ fire: @escaping () -> Void) { pending.append(fire) }
    }

    // Counting This Mac or a lost speaker as found so far, showing the lost row before the search is done, a wrong caption once it is, or moving Pair off the end turns it red.
    @Test func captionIsTheSearchResultAndLostWaitsForIt() throws {
        let controller = makeController()
        let library = SpeakerLibraryController(loadPersisted: false)
        let mac = device("mac", kind: .localMac)
        let first = try controller.createGroup(name: "First", memberIDs: ["study", "kitchen"], memberVolumes: [:]).group
        let second = try controller.createGroup(name: "Second", memberIDs: ["study", "den"], memberVolumes: [:]).group
        library.update(liveDevices: [mac, device("kitchen"), device("den")], groups: [first, second])
        let page = SpeakersPageViewController(library: library, groupController: controller)

        #expect(page.test_subtitleText == "Looking for speakers on your network\u{2026} \u{00B7} 2 found so far")
        #expect(page.test_discoveryShowsSpinner)
        #expect(page.test_rowTitles == ["Pair Bluetooth speaker\u{2026}"])

        page.isSearchDone = true
        #expect(!page.test_discoveryShowsSpinner)
        #expect(page.test_subtitleText == "Done looking \u{00B7} \u{25CF} 2 found")
        #expect(page.test_rowTitles == ["1 speaker can\u{2019}t be found", "Pair Bluetooth speaker\u{2026}"])
        #expect(page.test_rowHelp(forRowTitled: "1 speaker can\u{2019}t be found")
                == "Forgetting it takes it out of 2 scenes.")
        #expect(page.test_rowButtonTitle(forRowTitled: "1 speaker can\u{2019}t be found") == "Forget 1 speaker\u{2026}")

        library.update(liveDevices: [mac, device("kitchen", available: false), device("den"), device("study")],
                       groups: [first, second])
        page.reload()
        #expect(page.test_subtitleText == "Done looking \u{00B7} \u{25CF} 2 found \u{00B7} \u{25CB} 1 away")

        library.update(liveDevices: [mac, device("kitchen"), device("den"), device("study")], groups: [first, second])
        page.reload()
        #expect(page.test_subtitleText == "All 4 speakers found")
        #expect(page.test_rowTitles == ["Pair Bluetooth speaker\u{2026}"])
    }

    // Dropping the Unknown kind, showing a kind with no speakers, leaving a lost speaker out, or splitting the AirPlay brands turns it red.
    @Test func kindsRowCountsEveryKeptSpeakerAndOmitsEmptyKinds() throws {
        let controller = makeController()
        let library = SpeakerLibraryController(loadPersisted: false)
        let scene = try controller.createGroup(name: "Room", memberIDs: ["ghost", "pod"], memberVolumes: [:]).group
        library.update(liveDevices: [device("mac", kind: .localMac), device("pod", kind: .homePod),
                                     device("sonos", kind: .sonos), device("tv", kind: .appleTV, available: false),
                                     device("bt", kind: .bluetooth)],
                       groups: [scene])
        let page = SpeakersPageViewController(library: library, groupController: controller)
        #expect(page.test_kinds == ["3 AirPlay", "1 Bluetooth", "1 This Mac", "1 Unknown"])
    }

    // Letting the card's stack fill the pane, so the card stretches past its last row, turns it red.
    @Test func cardEndsAtItsLastRow() {
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [device("mac", kind: .localMac), device("kitchen")], groups: [])
        let page = SpeakersPageViewController(library: library, groupController: makeController())
        let heights = page.test_cardHeights(laidOutAt: NSSize(width: 443, height: 760))
        #expect(abs(heights.card - heights.rows) < 1)
        #expect(heights.card < 300)
    }

    // Reporting a found speaker to Forget, or a Pair or Bluetooth row that fires nothing, turns it red.
    @Test func forgetReportsExactlyTheLostIDsAndTheRowsFire() {
        let library = SpeakerLibraryController(loadPersisted: false)
        let mac = device("mac", kind: .localMac)
        library.update(liveDevices: [mac, device("kitchen"), device("attic"), device("garage")], groups: [],
                       confirmedUsedIDs: ["attic", "garage"])
        library.update(liveDevices: [mac, device("kitchen")], groups: [])
        let page = SpeakersPageViewController(library: library, groupController: makeController())
        page.isSearchDone = true
        page.setBluetoothAccess(SpeakerBluetoothAccessPresentation(status: .unknown, priming: false))

        var forgotten: [Set<String>] = []
        var paired = 0
        var accessAsked = 0
        page.onForget = { forgotten.append($0) }
        page.onPairBluetooth = { paired += 1 }
        page.onBluetoothAccess = { accessAsked += 1 }

        let lostRow = "2 speakers can\u{2019}t be found"
        #expect(page.test_rowTitles.first == "Bluetooth access is off")
        #expect(page.test_rowHelp(forRowTitled: lostRow) == "They aren\u{2019}t in any scene.")
        page.test_clickRowButton(forRowTitled: lostRow)
        #expect(forgotten == [["attic", "garage"]])
        page.test_clickPairRow()
        #expect(paired == 1)
        page.test_clickRowButton(forRowTitled: "Bluetooth access is off")
        #expect(accessAsked == 1)
    }

    // Capturing before the list goes quiet, more than once per launch, or counting a lost speaker as away turns it red.
    @Test func searchCapturesTheCountsOnceWhenTheListGoesQuiet() throws {
        let captured = CapturedEvents()
        Analytics.install(Analytics.Sink(capture: { name, props in captured.append(name, props) },
                                         captureError: { _, _ in }, consentChanged: { _ in }), consent: true)
        defer { Analytics.install(nil, consent: false) }
        let library = SpeakerLibraryController(loadPersisted: false)
        let scene = Group(id: "g", name: "Room", memberIDs: ["ghost"], memberVolumes: [:])
        library.update(liveDevices: [], groups: [scene])
        let timers = Timers()
        let search = SpeakerSearch(library: library, schedule: timers.schedule)
        var done = 0
        search.onDone = { done += 1 }

        search.libraryDidChange()
        #expect(timers.pending.isEmpty, "an empty list arms nothing")
        library.update(liveDevices: [device("mac", kind: .localMac), device("pod", kind: .homePod),
                                     device("bt", kind: .bluetooth, available: false)], groups: [scene])
        search.libraryDidChange()
        #expect(captured.events().isEmpty)
        try #require(timers.pending.count == 2)
        timers.pending[1]()
        timers.pending[0]()
        search.libraryDidChange()

        #expect(done == 1 && search.isDone)
        let events = captured.events().filter { $0.0 == "speaker:library_counted" }
        #expect(events.count == 1)
        #expect(events.first?.1 == ["airplay": "1", "bluetooth": "1", "cast": "0", "mac": "1", "unknown": "1",
                                    "found": "1", "away": "1", "lost": "1", "total": "4"])
    }

    // Dropping the ceiling, so a list that never stops changing never finishes, turns it red.
    @Test func searchFinishesAtTheCeilingWhenTheListNeverGoesQuiet() {
        let library = SpeakerLibraryController(loadPersisted: false)
        let timers = Timers()
        let search = SpeakerSearch(library: library, schedule: timers.schedule)
        library.update(liveDevices: [device("a")], groups: [])
        search.libraryDidChange()
        library.update(liveDevices: [device("a"), device("b")], groups: [])
        search.libraryDidChange()
        #expect(!search.isDone)
        timers.pending[0]()
        #expect(search.isDone)
    }
}

}
