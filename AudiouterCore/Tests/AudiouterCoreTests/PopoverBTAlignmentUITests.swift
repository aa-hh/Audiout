// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// W3/W4 at the popover level: the first-mix alignment card (mount, three
/// actions, rebuild/close survival) and the wizard panel (every screen
/// transition through REAL button dispatch — `performClick`, the same
/// target/action AppKit runs; this repo was bitten by hooks bypassing
/// dispatch). `.serialized` for the same reason `PopoverControllerTests` is.
@MainActor
@Suite(.serialized) struct PopoverBTAlignmentUITests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory   // isolation-ok — UUID-suffixed per call
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Same harness as `BTPopoverRowsTests`: rows pushed by hand via
    /// `update(devices:)` over a never-started `MockBackend`.
    private func makePopover() -> (PopoverController, Recorder) {
        let backend = MockBackend(fleet: [], staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        let recorder = Recorder()
        popover.onResolveBTAlignmentPrompt = { id, dismissed in
            recorder.resolves.append((id, dismissed))
        }
        popover.onBTWizardTrimPreview = { ms, id in recorder.previews.append((ms, id)) }
        popover.onBTWizardEndPreview = { id, keep in recorder.ends.append((id, keep)) }
        popover.onBTWizardTickActive = { recorder.ticks.append($0) }
        return (popover, recorder)
    }

    final class Recorder {
        var resolves: [(id: String, dismissed: Bool)] = []
        var previews: [(ms: Int, id: String)] = []
        var ends: [(id: String, keep: Int?)] = []
        var ticks: [Bool] = []
    }

    private func local() -> Device {
        Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
    }

    private func airplay(_ id: String = "office") -> Device {
        Device(id: id, name: "Office", kind: .homePod)
    }

    private func bt(_ id: String = "bt-a:output", name: String = "Move 2") -> Device {
        Device(id: id, name: name, kind: .bluetooth,
               isAvailable: true, supportsAirPlay2: false)
    }

    private func showPrompt(_ popover: PopoverController, id: String = "bt-a:output") {
        popover.update(devices: [local(), airplay(), bt(id)])
        popover.showBTAlignmentPrompt(deviceID: id)
    }

    // MARK: Card mount + copy

    @Test func promptMountsTheCardUnderTheRowWithTheLockedCopy() {
        let (popover, _) = makePopover()
        showPrompt(popover)
        let card = popover.test_btAlignmentPromptView()
        #expect(card != nil)
        #expect(card?.test_copyText == BTAlignmentPromptView.promptCopy)
        #expect(card?.test_buttonTitles == ["Align with your music", "Align with ticks", "Not now"])
        #expect(popover.test_btAlignmentPromptDeviceID() == "bt-a:output")
    }

    @Test func cardIntentSurvivesARebuildAndACloseReopen() {
        let (popover, _) = makePopover()
        showPrompt(popover)
        popover.rebuild()
        #expect(popover.test_btAlignmentPromptView() != nil, "a rebuild remounts the card")

        popover.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        popover.rebuild()   // the next open's rebuildForOpen path
        #expect(popover.test_btAlignmentPromptView() != nil,
                "the offer survives close/reopen — the backend's hold does too")
    }

    // MARK: The three actions (real dispatch)

    @Test func notNowResolvesDismissedAndUnmounts() {
        let (popover, recorder) = makePopover()
        showPrompt(popover)
        popover.test_btAlignmentPromptView()?.test_clickNotNow()
        #expect(recorder.resolves.map(\.id) == ["bt-a:output"])
        #expect(recorder.resolves.map(\.dismissed) == [true], "Not now records the FINAL dismissal")
        #expect(popover.test_btAlignmentPromptView() == nil)
        #expect(popover.test_btWizardIsOpen() == false)
    }

    @Test func alignWithMusicReleasesAndRoutesToTheSyncControl() {
        let (popover, recorder) = makePopover()
        showPrompt(popover)
        popover.test_btAlignmentPromptView()?.test_clickAlignWithMusic()
        #expect(recorder.resolves.map(\.dismissed) == [false], "unmute, no dismissal record")
        #expect(popover.test_btAlignmentPromptView() == nil)
        #expect(popover.test_btWizardIsOpen() == false,
                "music path goes to the row's SYNC control, not the wizard")
    }

    @Test func alignWithTicksReleasesAndOpensTheWizard() {
        let (popover, recorder) = makePopover()
        showPrompt(popover)
        popover.test_btAlignmentPromptView()?.test_clickAlignWithTicks()
        #expect(recorder.resolves.map(\.dismissed) == [false], "the wizard needs the device audible")
        #expect(popover.test_btAlignmentPromptView() == nil, "the wizard replaces the card")
        #expect(popover.test_btWizardIsOpen())
        #expect(popover.test_btWizardView()?.test_screen == .intro)
        #expect(popover.test_btWizardView()?.test_bodyText == BTAlignmentWizardView.introCopy)
    }

    @Test func aSecondPromptReplacesTheFirstReleasingItUnrecorded() {
        let (popover, recorder) = makePopover()
        popover.update(devices: [local(), bt("bt-a:output", name: "A"), bt("bt-b:output", name: "B")])
        popover.showBTAlignmentPrompt(deviceID: "bt-a:output")
        popover.showBTAlignmentPrompt(deviceID: "bt-b:output")
        #expect(recorder.resolves.map(\.id) == ["bt-a:output"])
        #expect(recorder.resolves.map(\.dismissed) == [false],
                "the replaced offer is released, never dismissed")
        #expect(popover.test_btAlignmentPromptDeviceID() == "bt-b:output")
    }

    // MARK: Wizard screens (every transition through real dispatch)

    private func openWizard(_ popover: PopoverController) -> BTAlignmentWizardView? {
        showPrompt(popover)
        popover.test_btAlignmentPromptView()?.test_clickAlignWithTicks()
        return popover.test_btWizardView()
    }

    @Test func startBeginsTheQuestionsWithDeviceNamedButtons() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        #expect(recorder.ticks == [true], "Start turns the wizard tick on")
        #expect(recorder.previews.map(\.ms) == [0], "the centre candidate applies immediately")
        guard case .question(_, _)? = wizard?.test_screen else {
            Issue.record("expected the question screen, got \(String(describing: wizard?.test_screen))")
            return
        }
        #expect(wizard?.test_bodyText == BTAlignmentWizardView.questionCopy)
        #expect(wizard?.test_buttonTitles == ["Move 2", "The other speakers", "Can't tell"],
                "the which-side buttons carry the ACTUAL device names")
        #expect(wizard?.test_progressValue == 0)
    }

    @Test func answersNarrowUntilTheReceiptThenKeepPersists() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: "Move 2")               // target first
        #expect(recorder.previews.map(\.ms) == [0, 250])
        #expect((wizard?.test_progressValue ?? 0) > 0, "the indicator narrows")
        wizard?.test_clickButton(titled: "The other speakers")   // reversal 1
        wizard?.test_clickButton(titled: "Move 2")               // reversal 2 → converged
        #expect(wizard?.test_screen == .receipt(trimMs: 156))
        #expect(wizard?.test_bodyText == "Aligned — 156 ms", "the ms value is a receipt only")
        #expect(wizard?.test_showsEducationLine == true)
        #expect(recorder.ticks == [true, false], "the tick ends with the questions")

        wizard?.test_clickButton(titled: "Keep")
        #expect(recorder.ends.map(\.keep) == [156], "Keep persists the result")
        #expect(popover.test_btWizardIsOpen() == false, "…and closes the wizard")
    }

    @Test func tryAgainRestoresAndRestarts() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: "Move 2")
        wizard?.test_clickButton(titled: "The other speakers")
        wizard?.test_clickButton(titled: "Move 2")
        guard case .receipt(_)? = wizard?.test_screen else {
            Issue.record("expected receipt, got \(String(describing: wizard?.test_screen))")
            return
        }
        wizard?.test_clickButton(titled: "Try again")
        #expect(recorder.ends.map(\.keep) == [nil], "Try again restores the prior trim first")
        #expect(recorder.ticks == [true, false, true])
        guard case .question(_, _)? = wizard?.test_screen else {
            Issue.record("expected a fresh question, got \(String(describing: wizard?.test_screen))")
            return
        }
    }

    @Test func twoCantTellsShowTheGracefulExitAndDoneCloses() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: BTAlignmentWizardView.cantTellTitle)
        wizard?.test_clickButton(titled: BTAlignmentWizardView.cantTellTitle)
        #expect(wizard?.test_screen == .gracefulExit)
        #expect(wizard?.test_bodyText == BTAlignmentWizardView.gracefulExitCopy)
        #expect(wizard?.test_showsEducationLine == true)
        #expect(recorder.ends.map(\.keep) == [nil], "graceful exit restored the prior trim")

        wizard?.test_clickButton(titled: "Done")
        #expect(popover.test_btWizardIsOpen() == false)
        #expect(recorder.ticks.last == false)
    }

    @Test func dismissMidQuestionsCancelsRestoresAndSilences() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: "Move 2")
        wizard?.test_clickDismiss()
        #expect(recorder.ends.map(\.keep) == [nil], "✕ restores the prior trim")
        #expect(recorder.ticks == [true, false])
        #expect(popover.test_btWizardIsOpen() == false)
    }

    @Test func popoverCloseCancelsTheWizardButKeepsNoStaleTick() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        popover.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        #expect(recorder.ticks == [true, false], "the wizard tick never outlives the surface")
        #expect(recorder.ends.map(\.keep) == [nil], "…and the prior trim is restored")
        #expect(popover.test_btWizardIsOpen() == false)
    }

    @Test func openingTheWizardStopsARunningManualMetronome() {
        let (popover, recorder) = makePopover()
        var manualGates: [Bool] = []
        popover.onAlignTickActiveChange = { manualGates.append($0) }
        popover.update(devices: [local(), airplay(), bt()])
        popover.test_deviceRow(for: "bt-a:output")?.test_fireAlignClick()
        #expect(manualGates == [true])

        popover.showBTAlignmentPrompt(deviceID: "bt-a:output")
        popover.test_btAlignmentPromptView()?.test_clickAlignWithTicks()
        popover.test_btWizardView()?.test_clickButton(titled: "Start")
        #expect(manualGates == [true, false], "one tick source at a time")
        #expect(recorder.ticks == [true])
    }
}
