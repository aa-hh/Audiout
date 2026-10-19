// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// The Speakers page behind the sidebar's Overview plate: its caption is the
/// total, one card counts the speakers by kind and then shows only the rows
/// that are true, ending with Pair. Nested under `SerializedSharedState`
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

    /// A fake clock: each armed closure fires when time is advanced past its
    /// due time, earliest first and in arming order on a tie, including the
    /// closures those fires arm.
    private final class Clock {
        private(set) var now: TimeInterval = 0
        private var order = 0
        private var pending: [(due: TimeInterval, order: Int, fire: () -> Void)] = []
        var isIdle: Bool { pending.isEmpty }

        func schedule(_ delay: TimeInterval, _ fire: @escaping () -> Void) {
            order += 1
            pending.append((now + delay, order, fire))
        }

        func advance(to target: TimeInterval) {
            while let next = pending.indices.filter({ pending[$0].due <= target })
                .min(by: { (pending[$0].due, pending[$0].order) < (pending[$1].due, pending[$1].order) }) {
                let entry = pending.remove(at: next)
                now = entry.due
                entry.fire()
            }
            now = target
        }
    }

    // Showing a count or the total before its kind is known, the can't-be-found row before the ceiling, or moving Pair off the end turns it red.
    @Test func captionIsTheSearchResultAndLostWaitsForIt() throws {
        let controller = makeController()
        let library = SpeakerLibraryController(loadPersisted: false)
        let mac = device("mac", kind: .localMac)
        let first = try controller.createGroup(name: "First", memberIDs: ["study", "kitchen"], memberVolumes: [:]).group
        let second = try controller.createGroup(name: "Second", memberIDs: ["study", "den"], memberVolumes: [:]).group
        library.update(liveDevices: [mac, device("kitchen"), device("den")], groups: [first, second])
        let clock = Clock()
        let search = SpeakerSearch(library: library, schedule: clock.schedule)
        search.libraryDidChange()
        let page = SpeakersPageViewController(library: library, groupController: controller)
        page.search = search
        page.test_reduceMotionOverride = false

        #expect(page.test_headerCaption == "")
        #expect(page.test_placeholderCount == 5, "the header, AirPlay, Bluetooth, Cast and Unavailable")
        #expect(page.test_tileValues == ["AirPlay, still looking", "Bluetooth, still looking", "Cast, still looking",
                                         "This Mac, available", "Unavailable, still looking"])
        #expect(page.test_rowTitles == ["Pair Bluetooth speaker\u{2026}"])

        page.test_reduceMotionOverride = true
        page.reload()
        #expect(page.test_headerCaption == "Looking for speakers\u{2026}")
        #expect(page.test_placeholderCount == 0)
        page.test_reduceMotionOverride = false

        clock.advance(to: SpeakerSearch.networkQuietWindow)
        page.reload()
        #expect(page.test_headerCaption == "4 speakers")
        #expect(page.test_placeholderCount == 0)
        #expect(page.test_rowTitles == ["Pair Bluetooth speaker\u{2026}"])

        clock.advance(to: SpeakerSearch.ceiling)
        page.reload()
        #expect(page.test_rowTitles == ["1 speaker can\u{2019}t be found", "Pair Bluetooth speaker\u{2026}"])
        #expect(page.test_rowHelp(forRowTitled: "1 speaker can\u{2019}t be found")
                == "It hasn\u{2019}t appeared since Audiout opened. Forgetting it takes it out of 2 scenes.")
        #expect(page.test_rowButtonTitle(forRowTitled: "1 speaker can\u{2019}t be found") == "Forget 1 speaker\u{2026}")

        library.update(liveDevices: [mac, device("kitchen", available: false), device("den"), device("study")],
                       groups: [first, second])
        search.libraryDidChange()
        page.reload()
        #expect(page.test_headerCaption == "4 speakers")
        #expect(page.test_tileValues == ["2 AirPlay speakers available", "No Bluetooth speakers available",
                                         "No Cast speakers available", "This Mac, available",
                                         "1 speaker unavailable"])
        #expect(page.test_rowTitles == ["Pair Bluetooth speaker\u{2026}"])
    }

    // Counting an unreachable or kindless speaker under its kind, dropping an empty kind's tile, or splitting the AirPlay brands turns it red.
    @Test func countsStripSortsEveryKeptSpeakerIntoItsTile() throws {
        let controller = makeController()
        let library = SpeakerLibraryController(loadPersisted: false)
        let scene = try controller.createGroup(name: "Room", memberIDs: ["ghost", "pod"], memberVolumes: [:]).group
        library.update(liveDevices: [device("mac", kind: .localMac), device("pod", kind: .homePod),
                                     device("sonos", kind: .sonos), device("tv", kind: .appleTV, available: false),
                                     device("bt", kind: .bluetooth)],
                       groups: [scene])
        let page = SpeakersPageViewController(library: library, groupController: controller)
        #expect(page.test_tileValues == ["2 AirPlay speakers available", "1 Bluetooth speaker available",
                                         "No Cast speakers available", "This Mac, available",
                                         "2 speakers unavailable"])
        #expect(page.test_headerCaption == "6 speakers")
    }

    // Letting the card's stack fill the pane, or dropping ListRowView's low-priority pull toward their smallest height so a window's layout hands the pane's spare height to one row, turns it red.
    @Test func cardEndsAtItsLastRow() {
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [device("mac", kind: .localMac), device("kitchen")], groups: [])
        let page = SpeakersPageViewController(library: library, groupController: makeController())
        let heights = page.test_cardHeights(laidOutAt: NSSize(width: 443, height: 760))
        #expect(abs(heights.card - heights.rows) < 1)
        #expect(heights.card < 300)

        // The live order: the page loads while the search still looks, then
        // the ceiling shows the can't-be-found row, and Local Network flips.
        let mac = device("mac", kind: .localMac)
        let lost = SpeakerLibraryController(loadPersisted: false)
        lost.update(liveDevices: [mac, device("kitchen"), device("attic", kind: .bluetooth)], groups: [],
                    confirmedUsedIDs: ["attic"])
        lost.update(liveDevices: [mac, device("kitchen")], groups: [])
        let clock = Clock()
        let search = SpeakerSearch(library: lost, schedule: clock.schedule)
        var denied = false
        search.isLocalNetworkDenied = { denied }
        search.libraryDidChange()
        let filled = SpeakersPageViewController(library: lost, groupController: makeController())
        filled.search = search
        let pane = NSSize(width: 503, height: 1000)
        // Never ordered front — tests stay invisible. A bare view laid out
        // the rows at their height; only a window's layout stretched one.
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: pane), styleMask: [.titled],
                            backing: .buffered, defer: true)
        host.contentView = filled.view
        _ = filled.test_cardHeights(laidOutAt: pane)
        clock.advance(to: SpeakerSearch.ceiling)

        let lostRow = "1 speaker can\u{2019}t be found"
        for networkDenied in [false, true, false] {
            denied = networkDenied
            filled.reload()
            let laidOut = filled.test_cardHeights(laidOutAt: pane)
            let row = filled.test_rowHeights(forRowTitled: lostRow)
            #expect(filled.test_rowTitles.first == lostRow)
            #expect(abs(laidOut.card - laidOut.rows) < 1, "denied \(networkDenied): card \(laidOut.card), rows \(laidOut.rows)")
            #expect(abs((row?.frame ?? 0) - (row?.fitting ?? 0)) < 1, "denied \(networkDenied): row \(String(describing: row))")
        }
    }

    // Reporting a found speaker to Forget, titling a partial loss without its share of Unavailable, a row out of order, or a Pair, Bluetooth or Local Network row that fires nothing turns it red.
    @Test func forgetReportsExactlyTheLostIDsAndTheRowsFire() {
        let library = SpeakerLibraryController(loadPersisted: false)
        let mac = device("mac", kind: .localMac)
        library.update(liveDevices: [mac, device("kitchen"), device("attic", kind: .bluetooth),
                                     device("garage", kind: .bluetooth)], groups: [],
                       confirmedUsedIDs: ["attic", "garage"])
        library.update(liveDevices: [mac, device("kitchen"), device("porch", available: false)], groups: [])
        let clock = Clock()
        let search = SpeakerSearch(library: library, schedule: clock.schedule)
        search.isLocalNetworkDenied = { true }
        search.libraryDidChange()
        clock.advance(to: SpeakerSearch.ceiling)
        let page = SpeakersPageViewController(library: library, groupController: makeController())
        page.search = search
        page.setBluetoothAccess(SpeakerBluetoothAccessPresentation(status: .unknown, priming: false))

        var forgotten: [Set<String>] = []
        var paired = 0
        var accessAsked = 0
        var networkAsked = 0
        page.onForget = { forgotten.append($0) }
        page.onPairBluetooth = { paired += 1 }
        page.onBluetoothAccess = { accessAsked += 1 }
        page.onLocalNetworkAccess = { networkAsked += 1 }

        let lostRow = "2 of the 3 can\u{2019}t be found"
        #expect(page.test_rowTitles == [lostRow, "Local Network access is off", "Bluetooth access is off",
                                        "Pair Bluetooth speaker\u{2026}"])
        #expect(page.test_rowHelp(forRowTitled: lostRow)
                == "2 of the 3 unavailable speakers haven\u{2019}t appeared since Audiout opened. They aren\u{2019}t in any scene.")
        page.test_clickRowButton(forRowTitled: lostRow)
        #expect(forgotten == [["attic", "garage"]])
        page.test_clickPairRow()
        #expect(paired == 1)
        page.test_clickRowButton(forRowTitled: "Bluetooth access is off")
        #expect(accessAsked == 1)
        page.test_clickRowButton(forRowTitled: "Local Network access is off")
        #expect(networkAsked == 1)
    }

    // Capturing before the list goes quiet, more than once per launch, counting a lost speaker as away, or moving the event onto the page's per-kind rule turns it red.
    @Test func searchCapturesTheCountsOnceWhenTheListGoesQuiet() throws {
        let captured = CapturedEvents()
        Analytics.install(Analytics.Sink(capture: { name, props in captured.append(name, props) },
                                         captureError: { _, _ in }, consentChanged: { _ in }), consent: true)
        defer { Analytics.install(nil, consent: false) }
        let library = SpeakerLibraryController(loadPersisted: false)
        let scene = Group(id: "g", name: "Room", memberIDs: ["ghost"], memberVolumes: [:])
        library.update(liveDevices: [], groups: [scene])
        let clock = Clock()
        let search = SpeakerSearch(library: library, schedule: clock.schedule)
        var done = 0
        search.onDone = { done += 1 }

        search.libraryDidChange()
        #expect(clock.isIdle, "an empty list arms nothing")
        library.update(liveDevices: [device("mac", kind: .localMac), device("pod", kind: .homePod),
                                     device("bt", kind: .bluetooth, available: false)], groups: [scene])
        search.libraryDidChange()
        #expect(captured.events().isEmpty)
        clock.advance(to: 0.5)
        #expect(!search.knownKinds.contains(.airplay))
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
        let clock = Clock()
        let search = SpeakerSearch(library: library, schedule: clock.schedule)
        for step in 0...24 {
            clock.advance(to: Double(step) * 0.4)
            library.update(liveDevices: (0...step).map { device("s\($0)") }, groups: [])
            search.libraryDidChange()
        }
        clock.advance(to: 9.9)
        #expect(!search.isDone)
        clock.advance(to: 10.0)
        #expect(search.isDone)
    }

    // Settling AirPlay on the 0.5 s quiet window again, so a late network answer reads as a final 0, turns it red.
    @Test func airplayWaitsForTwoSecondsOfQuietWhileBluetoothSettlesOnHalfASecond() {
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [device("mac", kind: .localMac), device("bt", kind: .bluetooth)], groups: [])
        let clock = Clock()
        let search = SpeakerSearch(library: library, schedule: clock.schedule)
        search.libraryDidChange()
        #expect(search.knownKinds == [.thisMac])

        clock.advance(to: 0.5)
        #expect(search.knownKinds.contains(.bluetooth))
        clock.advance(to: 1.9)
        #expect(!search.knownKinds.contains(.airplay))
        clock.advance(to: 2.0)
        #expect(search.knownKinds.contains(.airplay))
        #expect(search.isEveryKindKnown)
    }

    // Offering Forget before the ceiling, or for network speakers while nothing on the network has answered, turns it red.
    @Test func cantBeFoundWaitsForTheCeilingAndNeedsTheNetworkToHaveAnswered() {
        let mac = device("mac", kind: .localMac)
        let answered = SpeakerLibraryController(loadPersisted: false)
        answered.update(liveDevices: [mac, device("pod", kind: .homePod), device("attic", kind: .homePod)],
                        groups: [], confirmedUsedIDs: ["attic"])
        answered.update(liveDevices: [mac, device("pod", kind: .homePod)], groups: [])
        let clock = Clock()
        let search = SpeakerSearch(library: answered, schedule: clock.schedule)
        search.libraryDidChange()
        clock.advance(to: 9.9)
        #expect(search.cantBeFoundIDs.isEmpty)
        clock.advance(to: 10.0)
        #expect(search.cantBeFoundIDs == ["attic"])

        let silent = SpeakerLibraryController(loadPersisted: false)
        let scene = Group(id: "g", name: "Room", memberIDs: ["ghost"], memberVolumes: [:])
        silent.update(liveDevices: [mac, device("attic", kind: .homePod), device("headset", kind: .bluetooth)],
                      groups: [], confirmedUsedIDs: ["attic", "headset"])
        silent.update(liveDevices: [mac], groups: [scene])
        let quietClock = Clock()
        let quietSearch = SpeakerSearch(library: silent, schedule: quietClock.schedule)
        quietSearch.libraryDidChange()
        quietClock.advance(to: 10.0)
        #expect(quietSearch.cantBeFoundIDs == ["headset"])
        quietClock.advance(to: 30.0)
        #expect(quietSearch.cantBeFoundIDs == ["headset"])
    }

    // Turns red when libraryDidChange fires onChange only when knownKinds grows, so remembered network speakers join the can't-be-found list after the ceiling while the sidebar and pages keep the old one.
    @Test func theFirstNetworkSpeakerAfterTheCeilingRepaintsTheCantBeFoundList() {
        let mac = device("mac", kind: .localMac)
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [mac, device("attic", kind: .homePod)], groups: [], confirmedUsedIDs: ["attic"])
        library.update(liveDevices: [mac], groups: [])
        let clock = Clock()
        let search = SpeakerSearch(library: library, schedule: clock.schedule)
        search.libraryDidChange()
        clock.advance(to: 10.0)
        #expect(search.cantBeFoundIDs.isEmpty)

        var changes = 0
        search.onChange = { changes += 1 }
        library.update(liveDevices: [mac, device("pod", kind: .homePod)], groups: [])
        search.libraryDidChange()
        #expect(changes == 1)
        #expect(search.cantBeFoundIDs == ["attic"])
    }

    // Rebuilding the card's rows on reload(), which drops the Forget button and keyboard focus with it, turns it red.
    @Test func aCountUpdateKeepsTheForgetButtonAndItsFocus() throws {
        let library = SpeakerLibraryController(loadPersisted: false)
        let mac = device("mac", kind: .localMac)
        library.update(liveDevices: [mac, device("kitchen"), device("attic", kind: .homePod)], groups: [],
                       confirmedUsedIDs: ["attic"])
        library.update(liveDevices: [mac, device("kitchen")], groups: [])
        let clock = Clock()
        let search = SpeakerSearch(library: library, schedule: clock.schedule)
        search.libraryDidChange()
        clock.advance(to: SpeakerSearch.ceiling)
        let page = SpeakersPageViewController(library: library, groupController: makeController())
        page.search = search

        // Never ordered front — tests stay invisible.
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 503, height: 600),
                            styleMask: [.titled], backing: .buffered, defer: true)
        host.contentView = page.view
        let button = try #require(page.test_forgetButton)
        // A button takes focus only with keyboard navigation on; the view's identity is checked either way.
        let focused = host.makeFirstResponder(button)

        library.update(liveDevices: [mac, device("kitchen"), device("den")], groups: [])
        search.libraryDidChange()
        page.reload()
        #expect(page.test_forgetButton === button)
        if focused { #expect(host.firstResponder === button) }
    }
}

}
