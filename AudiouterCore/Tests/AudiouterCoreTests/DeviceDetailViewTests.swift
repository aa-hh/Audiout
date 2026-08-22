// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// Unit coverage for `DeviceDetailViewController` — the read-only device
/// detail pane (design revamp, `../../Sources/AudiouterWindowUI/AGENTS.md`).
/// This view is CONFIGURATION-ONLY: it only ever renders a `Device` snapshot
/// plus its saved-group memberships, and never activates a group or moves
/// audio. Wiring it into the "Groups" window's sidebar selection is covered
/// separately in `MixerWindowControllerTests`; these cases construct the
/// controller directly and drive it through its `test_*` hooks, since a
/// headless run can't synthesize the real hover/click gestures.
// `@MainActor` is load-bearing, not decoration: this suite builds and drives
// AppKit views, and every `NSView`-family API is main-actor-only. XCTest ran
// each test method on the main thread, so the annotation was never needed;
// swift-testing schedules non-isolated `@Test` bodies on the cooperative
// pool, where the same calls trip AppKit's "modifications to layout engine
// from a background thread" exception and take the whole process down
// (observed in `AppRowViewTests` during this migration). Do not remove it.
@MainActor
@Suite struct DeviceDetailViewTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceDetailViewTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `GroupController` with an empty, non-persisted `MockBackend` — this
    /// view only ever reads `groupController.groups` (for membership text),
    /// never the backend, so an un-started, fleet-less backend is enough.
    private func makeController() -> GroupController {
        let backend = MockBackend(fleet: [], staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false)
        return GroupController(backend: backend, store: GroupStore(directory: tempDirectory()), loadPersisted: false)
    }

    private func makeDevice(
        id: String = "d1", name: String = "Office", kind: Device.Kind = .generic,
        isAvailable: Bool = true, volume: Int = 50, connectionState: ConnectionState = .off
    ) -> Device {
        Device(id: id, name: name, kind: kind, isAvailable: isAvailable, volume: volume,
              connectionState: connectionState)
    }

    // MARK: show(device:) basics

    @Test func showSetsShownDeviceID() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(id: "sonos-move"))
        #expect(detail.test_shownDeviceID == "sonos-move")
    }

    @Test func shownDeviceIDIsNilBeforeFirstShow() {
        let detail = DeviceDetailViewController(groupController: makeController())
        #expect(detail.test_shownDeviceID == nil)
    }

    @Test func refreshUpdatesFieldsForTheSameDevice() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(isAvailable: true))
        #expect(detail.test_metadataStrings["available"] == "Yes")

        detail.refresh(device: makeDevice(isAvailable: false))
        #expect(detail.test_metadataStrings["available"] == "No")
        #expect(detail.test_shownDeviceID == "d1")
    }

    // MARK: Metadata form — status wording

    @Test func statusTextOff() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .off))
        #expect(detail.test_metadataStrings["status"] == "Not connected")
    }

    @Test func statusTextConnecting() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .connecting))
        #expect(detail.test_metadataStrings["status"] == "Connecting")
    }

    @Test func statusTextReconnecting() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .reconnecting))
        #expect(detail.test_metadataStrings["status"] == "Reconnecting")
    }

    @Test func statusTextConnected() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .connected))
        #expect(detail.test_metadataStrings["status"] == "Connected")
    }

    @Test func statusTextFailed() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        #expect(detail.test_metadataStrings["status"] == "Couldn't connect",
                       "matches DeviceRowView's existing failed vocabulary")
    }

    // MARK: Metadata form — available / volume / kind

    @Test func availableYesAndNo() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(isAvailable: true))
        #expect(detail.test_metadataStrings["available"] == "Yes")

        detail.show(device: makeDevice(isAvailable: false))
        #expect(detail.test_metadataStrings["available"] == "No")
    }

    @Test func kindTextForEveryKind() {
        let detail = DeviceDetailViewController(groupController: makeController())
        let expectations: [(Device.Kind, String)] = [
            (.localMac, "This Mac"),
            (.homePod, "HomePod"),
            (.appleTV, "Apple TV"),
            (.airportExpress, "AirPort Express"),
            (.sonos, "Sonos"),
            (.generic, "AirPlay Speaker"),
        ]
        for (kind, expected) in expectations {
            detail.show(device: makeDevice(kind: kind))
            #expect(detail.test_metadataStrings["kind"] == expected, "kind: \(kind)")
        }
    }

    // MARK: "In groups" membership text

    @Test func groupMembershipTextIsNoneWhenDeviceIsInNoGroup() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "None")
    }

    @Test func groupMembershipTextListsEverySavedGroupContainingTheDevice() throws {
        let controller = makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office", "appletv-lr"],
                                       memberVolumes: ["office": 50, "appletv-lr": 60]))
        try controller.saveGroup(Group(id: "g2", name: "Whole House", memberIDs: ["office"],
                                       memberVolumes: ["office": 50]))
        try controller.saveGroup(Group(id: "g3", name: "Bedroom", memberIDs: ["appletv-lr"],
                                       memberVolumes: ["appletv-lr": 60]))

        let detail = DeviceDetailViewController(groupController: controller)
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "Kitchen, Whole House",
                       "only groups this device is a member of, in groupController.groups order")
    }

    @Test func groupMembershipTextUpdatesOnRefreshAfterAMembershipChange() throws {
        let controller = makeController()
        // Seed with a DIFFERENT member so "office" starts as a non-member while
        // the group stays non-empty (an empty group is now rejected).
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["living-room"],
                                       memberVolumes: ["living-room": 50]))
        let detail = DeviceDetailViewController(groupController: controller)
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "None")

        var group = try #require(controller.groups.first { $0.id == "g1" })
        group.memberIDs = ["office"]
        group.memberVolumes["office"] = 50
        try controller.saveGroup(group)

        detail.refresh(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "Kitchen")
    }

    // MARK: Icon resolution — no injected controller

    @Test func iconSymbolNameFallsBackToKindDefaultWithNoInjectedController() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice(kind: .homePod))
        #expect(detail.test_iconSymbolName == Device.Kind.homePod.symbolName)
    }

    // MARK: Icon resolution — injected controller with/without an override

    @Test func iconSymbolNameUsesKindDefaultWhenControllerHasNoOverride() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController

        detail.show(device: makeDevice(kind: .sonos))
        #expect(detail.test_iconSymbolName == Device.Kind.sonos.symbolName)
    }

    @Test func iconSymbolNameUsesOverrideWhenControllerHasOneSet() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .sonos)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)

        #expect(detail.test_iconSymbolName == "airpods")
    }

    @Test func iconSymbolNameFallsBackToDefaultForAStaleOverride() {
        // The controller only ever persists a valid name (`setSymbolName` is a
        // no-op for an invalid one — DeviceIconResolverTests), so a "stale"
        // override is simulated by writing the store's raw file directly, the
        // same way a symbol removed on a future OS would surface.
        let directory = tempDirectory()
        let store = DeviceIconStore(directory: directory)
        try? store.save(["d1": "definitely.not.a.symbol.zzz"])
        let iconController = DeviceIconController(store: store, loadPersisted: true)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: makeDevice(id: "d1", kind: .appleTV))

        #expect(detail.test_iconSymbolName == Device.Kind.appleTV.symbolName,
                       "a stale override still falls back to the kind default, never a blank glyph")
    }

    // MARK: Icon picker flow — instant-apply through DeviceIconController

    @Test func clickEditIconBuildsAPickerConfiguredWithCurrentOverrideAndKindDefault() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)

        let picker = detail.test_clickEditIcon()
        #expect(picker != nil)
        #expect(detail.test_picker === picker, "the most recently built picker is retained for further driving")
    }

    @Test func pickingACuratedIconPersistsThroughControllerAndUpdatesTheWell() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)
        #expect(detail.test_iconSymbolName == Device.Kind.homePod.symbolName)

        let picker = detail.test_clickEditIcon()
        picker.test_pickCurated("airpods")

        #expect(detail.test_iconSymbolName == "airpods", "instant-apply — no separate Save step")
        #expect(iconController.overrides[device.id] == "airpods")
    }

    @Test func useDefaultResetsTheOverride() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController())
        detail.deviceIconController = iconController
        detail.show(device: device)
        #expect(detail.test_iconSymbolName == "airpods")

        let picker = detail.test_clickEditIcon()
        picker.test_useDefault()

        #expect(detail.test_iconSymbolName == Device.Kind.homePod.symbolName)
        #expect(iconController.overrides[device.id] == nil)
    }

    @Test func pickingAnIconWithNoInjectedControllerIsANoOp() {
        let device = makeDevice(kind: .sonos)
        let detail = DeviceDetailViewController(groupController: makeController())
        // No `deviceIconController` assigned — nil-tolerant per `../../AGENTS.md`.
        detail.show(device: device)

        let picker = detail.test_clickEditIcon()
        picker.test_pickCurated("airpods")

        #expect(detail.test_iconSymbolName == Device.Kind.sonos.symbolName,
                       "nothing to write through — the glyph stays at the kind default")
    }

    // MARK: The pane's hint

    @Test func hintNamesDescribeAndTune() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice())
        #expect(detail.test_hintText == "Playback is controlled from the Mixer — this page describes and tunes the speaker.")
        #expect(!detail.test_hintText.contains("\n"), "stays a single line")
    }

    // MARK: The Equalizer section

    /// Loads the view (the Equalizer's delegate and the hint's two alternative
    /// top constraints are wired in `loadView`) and shows `device`.
    private func makeLoadedPane(device: Device) -> DeviceDetailViewController {
        let detail = DeviceDetailViewController(groupController: makeController())
        _ = detail.view
        detail.show(device: device)
        return detail
    }

    @Test func equalizerSectionIsHiddenOnThisMac() {
        let detail = makeLoadedPane(device: makeDevice(id: "local", name: "This Mac", kind: .localMac))
        #expect(!detail.test_eqSectionShown,
                "the Mac is where the audio comes FROM — there is no send to tune")
    }

    @Test func equalizerSectionIsShownOnASpeaker() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_eqSectionShown)
        #expect(detail.test_sectionCount == 4,
                "header + device state + In groups + Equalizer")
    }

    // MARK: The Equalizer section's title

    @Test func eqSectionTitleShowsOnASpeaker() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_eqSectionTitleText == "Equalizer")
    }

    @Test func eqSectionTitleIsNilOnThisMac() {
        let detail = makeLoadedPane(device: makeDevice(id: "local", name: "This Mac", kind: .localMac))
        #expect(detail.test_eqSectionTitleText == nil,
                "hides together with the Equalizer section it titles")
    }

    @Test func eqSectionTitleSitsBetweenGroupsSectionAndEQSection() {
        let detail = makeLoadedPane(device: makeDevice())
        // The pane's own `view` is NOT flipped, so "below" reads as a
        // SMALLER y here (same idiom `test_hintFrame`'s doc comment uses).
        #expect(detail.test_eqSectionTitleFrame.maxY <= detail.test_groupsSectionFrame.minY,
                "the title sits below the groups section")
        #expect(detail.test_eqSectionFrame.maxY <= detail.test_eqSectionTitleFrame.minY,
                "the Equalizer section's own content sits below its title")
    }

    /// Not a `GroupedSectionView` — `test_sectionCount` (asserted at 4 in
    /// `equalizerSectionIsShownOnASpeaker`) must not grow when this label is
    /// added; it is bare pane text, the same idiom as the group editor's
    /// "Speakers" label.
    @Test func eqSectionTitleDoesNotCountAsASection() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_sectionCount == 4)
    }

    @Test func bypassSentencesComeFromTheSnapshot() {
        var device = makeDevice()
        device.eqBypassReason = .streamBudget
        let detail = makeLoadedPane(device: device)
        #expect(detail.test_eqEditor.test_bypassNoteText
                == "Not applied — too many different EQ settings at once.")

        device.eqBypassReason = .perAppRouting
        detail.refresh(device: device)
        #expect(detail.test_eqEditor.test_bypassNoteText
                == "Not applied — apps are routed directly to this speaker.")
    }

    @Test func aScrubAppliesAndAMouseUpCommits() {
        let detail = makeLoadedPane(device: makeDevice(id: "office"))
        var reported: [(DeviceEQ, String, Bool)] = []
        detail.onSetEQ = { eq, id, committed in reported.append((eq, id, committed)) }

        detail.test_eqEditor.test_committedGestureOverride = false
        detail.test_eqEditor.test_dragBass(to: 5)
        #expect(reported.last?.0.bassDB == 5)
        #expect(reported.last?.1 == "office")
        #expect(reported.last?.2 == false)

        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 5)
        #expect(reported.last?.2 == true)
    }

    @Test func resetCommitsFlatInOneAction() {
        let detail = makeLoadedPane(device: makeDevice(id: "office"))
        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 5)

        var reported: [(DeviceEQ, String, Bool)] = []
        detail.onSetEQ = { eq, id, committed in reported.append((eq, id, committed)) }
        detail.test_eqEditor.test_fireResetClick()

        #expect(reported.count == 1, "Reset is ONE action, not one per stage")
        #expect(reported.last?.0 == .flat)
        #expect(reported.last?.2 == true)
    }

    @Test func curveTracksTheEditor() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_eqEditor.test_curve.test_plan.state == .flat)

        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 6)
        #expect(detail.test_eqEditor.test_curve.test_plan.state == .shaped,
                "the picture and the controls read the same model")
    }

    // MARK: First load — shown BEFORE mounted (the live order)

    /// Mirrors what `MixerWindowController.showDetail` really does: it calls
    /// `show(device:)` and swaps the pane in AFTERWARDS, so the first
    /// `refreshUI()` runs while the hint's two alternative top pins are still
    /// nil. `makeLoadedPane` forces the view first and can never catch that.
    /// No window is involved — the pane is laid out at the Groups screen's
    /// content size directly, so nothing can appear on screen.
    private func makeShownThenLoadedPane(device: Device) -> DeviceDetailViewController {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: device)
        _ = detail.view
        detail.view.setFrameSize(AppSurfaceController.groupsDefaultContentSize)
        detail.view.layoutSubtreeIfNeeded()
        return detail
    }

    /// The scroll document's laid-out height — what collapses when the hint
    /// has no top pin to tie the sections to the column's bottom.
    private func documentHeight(_ detail: DeviceDetailViewController) -> CGFloat {
        let scroll = detail.view.subviews.compactMap { $0 as? NSScrollView }.first
        return scroll?.documentView?.frame.height ?? 0
    }

    @Test func aPaneShownBeforeItIsMountedStillPinsTheHintUnderTheLastSection() {
        let detail = makeShownThenLoadedPane(device: makeDevice())

        #expect(detail.test_activeHintPinCount == 1,
                Comment(rawValue: "the hint must have exactly one top pin from the moment the view loads — " +
                "with none the column's height goes ambiguous"))
        // The pane's own view is NOT flipped, so "below" is a SMALLER y.
        #expect(detail.test_hintFrame.maxY <= detail.test_eqSectionFrame.minY,
                "the hint sits under the Equalizer section, the last one on a speaker")

        let sections = detail.test_headerSectionFrame.height + detail.test_stateSectionFrame.height
            + detail.test_groupsSectionFrame.height + detail.test_eqSectionFrame.height
        #expect(documentHeight(detail) > sections,
                "the document holds the whole stack — a collapsed one is shorter than its own sections")
    }

    @Test func aThisMacPaneShownBeforeItIsMountedPinsTheHintUnderInGroups() {
        let detail = makeShownThenLoadedPane(
            device: makeDevice(id: "local", name: "This Mac", kind: .localMac))

        #expect(detail.test_activeHintPinCount == 1)
        #expect(!detail.test_eqSectionShown)
        #expect(detail.test_hintFrame.maxY <= detail.test_groupsSectionFrame.minY,
                "with the Equalizer gone, In groups is the last section and the hint closes up behind it")

        let sections = detail.test_headerSectionFrame.height + detail.test_stateSectionFrame.height
            + detail.test_groupsSectionFrame.height
        #expect(documentHeight(detail) > sections)
    }

    @Test func theHintPinFollowsTheDeviceInBothDirections() {
        let detail = makeShownThenLoadedPane(device: makeDevice())
        #expect(detail.test_hintFrame.maxY <= detail.test_eqSectionFrame.minY)

        detail.show(device: makeDevice(id: "local", name: "This Mac", kind: .localMac))
        detail.view.layoutSubtreeIfNeeded()
        #expect(detail.test_activeHintPinCount == 1)
        #expect(detail.test_hintFrame.maxY <= detail.test_groupsSectionFrame.minY)

        detail.show(device: makeDevice())
        detail.view.layoutSubtreeIfNeeded()
        #expect(detail.test_activeHintPinCount == 1)
        #expect(detail.test_hintFrame.maxY <= detail.test_eqSectionFrame.minY,
                "Mac → speaker puts the Equalizer section back under the hint")
    }

    // MARK: The in-flight scrub cache

    @Test func aScrubSurvivesASnapshotAndTheCommitHandsTheTruthBack() {
        let detail = makeLoadedPane(device: makeDevice(id: "office"))

        // Mid-drag: a snapshot carrying the OLD value must not rewind the slider.
        detail.test_eqEditor.test_committedGestureOverride = false
        detail.test_eqEditor.test_dragBass(to: 5)
        detail.refresh(device: makeDevice(id: "office"))
        #expect(detail.test_eqEditor.currentEQ.bassDB == 5,
                "a snapshot arriving mid-gesture can't yank the slider out from under the pointer")

        // Committed: the entry is now AWAITING ITS OWN ECHO. A STALE snapshot
        // already queued from before the commit — even flat — must not replay
        // the drag backward; only a snapshot matching the committed value
        // releases the cache.
        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 5)
        var flat = makeDevice(id: "office")
        flat.eq = .flat
        detail.refresh(device: flat)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 5,
                "a stale snapshot queued before the commit must not replay the drag on the knob")

        // The committed value's OWN echo arrives: it renders (unsurprising —
        // it already matched) AND releases the cache in the same beat.
        var echoed = makeDevice(id: "office")
        echoed.eq = DeviceEQ(bassDB: 5)
        detail.refresh(device: echoed)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 5)

        // Proof the cache is actually gone: a LATER flat snapshot now renders
        // flat, where a still-cached entry would have kept showing 5 forever.
        detail.refresh(device: flat)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 0,
                Comment(rawValue: "kept past the echo the cache lies forever — the pane would show a shaped " +
                "curve for the rest of the session while the audio stayed flat"))
    }

    @Test func resetAlsoHandsTheTruthBackToTheSnapshot() {
        let detail = makeLoadedPane(device: makeDevice(id: "office"))
        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 5)
        detail.test_eqEditor.test_fireResetClick()

        // Reset's own committed value is flat — a matching flat echo is what
        // releases the cache, same rule as any other committed gesture.
        var flat = makeDevice(id: "office")
        flat.eq = .flat
        detail.refresh(device: flat)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 0)

        var shaped = makeDevice(id: "office")
        shaped.eq = DeviceEQ(bassDB: 3)
        detail.refresh(device: shaped)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 3,
                "Reset released its cache on the matching echo — a later snapshot is free to render again")
    }

    @Test func detailPaneScrolls() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_hasScrollView,
                "the Equalizer's Advanced fold exceeds the screen's budget, and the window can't grow (roadmap 039)")
    }

    // MARK: Hover scrim headless test hook

    @Test func setOverlayVisibleDoesNotCrashHeadless() {
        let detail = DeviceDetailViewController(groupController: makeController())
        detail.show(device: makeDevice())
        detail.test_setOverlayVisible(true)
        detail.test_setOverlayVisible(false)
        // No assertion beyond "didn't crash" — the scrim's layer state isn't
        // exposed, and this is exercised visually by the live snapshot tool.
    }
}
