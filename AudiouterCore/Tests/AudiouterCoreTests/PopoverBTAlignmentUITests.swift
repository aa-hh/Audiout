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
    /// `update(devices:)`, but over a STARTED `MockBackend` fleet — the
    /// wizard only opens for a target the user intends audio on
    /// (`wantsAudio`), and `GroupController`'s selection guard needs the id
    /// to exist on the backend.
    private func makePopover(fleet: [Device]) -> (PopoverController, Recorder) {
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        backend.start()
        waitFor { backend.devices.count == fleet.count }
        let recorder = Recorder()
        popover.onResolveBTAlignmentPrompt = { id, dismissed in
            recorder.resolves.append((id, dismissed))
        }
        popover.onBTWizardTrimPreview = { ms, id in recorder.previews.append((ms, id)) }
        popover.onBTWizardEndPreview = { id, keep in recorder.ends.append((id, keep)) }
        popover.onBTWizardTickActive = { recorder.ticks.append($0) }
        return (popover, recorder)
    }

    private func makePopover() -> (PopoverController, Recorder) {
        makePopover(fleet: [local(), airplay(), bt()])
    }

    private func waitFor(timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    final class Recorder {
        var resolves: [(id: String, dismissed: Bool)] = []
        var previews: [(ms: Double, id: String)] = []
        var ends: [(id: String, keep: Double?)] = []
        var ticks: [Bool] = []
    }

    private func local() -> Device {
        Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
    }

    private func airplay(_ id: String = "office", name: String = "Office") -> Device {
        Device(id: id, name: name, kind: .homePod)
    }

    private func bt(_ id: String = "bt-a:output", name: String = "Move 2",
                    available: Bool = true) -> Device {
        Device(id: id, name: name, kind: .bluetooth,
               isAvailable: available, supportsAirPlay2: false)
    }

    /// The first-mix shape: the BT device SELECTED into a mix with the
    /// AirPlay speaker (the intercept only ever fires for a selected member,
    /// and the wizard refuses a target outside the user's audio intent).
    private func showPrompt(_ popover: PopoverController, id: String = "bt-a:output") {
        popover.update(devices: [local(), airplay(), bt(id)])
        popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_toggleDeviceEnabled(deviceID: id, on: true)
        popover.showBTAlignmentPrompt(deviceID: id)
    }

    /// Fire "Align speaker…" through real AppKit menu dispatch, found by
    /// TITLE — every row now carries an "Equalizer…" door above it, so the
    /// alignment item is no longer at index 0.
    @discardableResult
    private func fireAlignItem(_ menu: NSMenu?) -> Bool {
        guard let menu,
              let index = menu.items.firstIndex(where: { $0.title == "Align speaker…" })
        else { return false }
        menu.performActionForItem(at: index)
        return true
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

        popover.surfaceDidHide()
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

    // MARK: Two never-aligned devices in one first mix — the queue

    /// Two BT speakers selected into one first mix: both prompts arrive; the
    /// second QUEUES behind the first card and mounts when it resolves, so
    /// neither device's offer is dropped (its backend hold is only released
    /// by ITS OWN card's resolution).
    private func showTwoPrompts() -> (PopoverController, Recorder) {
        let fleet = [local(), bt("bt-a:output", name: "A"), bt("bt-b:output", name: "B")]
        let (popover, recorder) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.test_toggleDeviceEnabled(deviceID: "bt-b:output", on: true)
        popover.showBTAlignmentPrompt(deviceID: "bt-a:output")
        popover.showBTAlignmentPrompt(deviceID: "bt-b:output")
        return (popover, recorder)
    }

    @Test func aSecondPromptQueuesBehindTheFirstWithoutReleasingIt() {
        let (popover, recorder) = showTwoPrompts()
        #expect(recorder.resolves.isEmpty, "neither device's hold is touched while both offers stand")
        #expect(popover.test_btAlignmentPromptDeviceID() == "bt-a:output",
                "the first offer's card shows")
        #expect(popover.test_btAlignmentPromptQueue() == ["bt-b:output"],
                "…and the second waits its turn")
    }

    @Test func resolvingTheFirstCardMountsTheQueuedSecond() {
        let (popover, recorder) = showTwoPrompts()
        popover.test_btAlignmentPromptView()?.test_clickNotNow()
        #expect(recorder.resolves.map(\.id) == ["bt-a:output"])
        #expect(popover.test_btAlignmentPromptDeviceID() == "bt-b:output",
                "any resolution frees the slot for the queued device")
        #expect(popover.test_btAlignmentPromptView() != nil)
        #expect(popover.test_btAlignmentPromptQueue().isEmpty)
    }

    @Test func queuedCardWaitsOutTheFirstDevicesWizardThenMounts() {
        let (popover, recorder) = showTwoPrompts()
        popover.test_btAlignmentPromptView()?.test_clickAlignWithTicks()
        #expect(popover.test_btWizardIsOpen())
        #expect(popover.test_btAlignmentPromptView() == nil,
                "the wizard replaces the card; the queued offer never mounts beside it")
        #expect(popover.test_btAlignmentPromptQueue() == ["bt-b:output"])

        popover.test_btWizardView()?.test_clickDismiss()
        #expect(popover.test_btWizardIsOpen() == false)
        #expect(popover.test_btAlignmentPromptDeviceID() == "bt-b:output",
                "the wizard's close hands the slot to the queued device")
        #expect(recorder.resolves.map(\.id) == ["bt-a:output"],
                "the queued device's hold is still untouched")
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
        #expect(wizard?.test_buttonTitles == ["Move 2", "This Mac", "Can't tell"],
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
        wizard?.test_clickButton(titled: "This Mac")             // reversal 1
        wizard?.test_clickButton(titled: "Move 2")               // reversal 2 → converged
        #expect(wizard?.test_screen == .receipt(trimMs: 156.25))
        #expect(wizard?.test_bodyText == "Aligned — 156 ms", "the ms value is a receipt only")
        #expect(wizard?.test_showsEducationLine == true)
        #expect(recorder.ticks == [true, false], "the tick ends with the questions")

        wizard?.test_clickButton(titled: "Keep")
        #expect(recorder.ends.map(\.keep) == [156.25], "Keep persists the result")
        #expect(popover.test_btWizardIsOpen() == false, "…and closes the wizard")
    }

    @Test func tryAgainRestoresAndRestarts() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: "Move 2")
        wizard?.test_clickButton(titled: "This Mac")
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
        popover.surfaceDidHide()
        #expect(recorder.ticks == [true, false], "the wizard tick never outlives the surface")
        #expect(recorder.ends.map(\.keep) == [nil], "…and the prior trim is restored")
        #expect(popover.test_btWizardIsOpen() == false)
    }

    @Test func openingTheWizardStopsARunningManualMetronome() {
        let (popover, recorder) = makePopover()
        var manualGates: [Bool] = []
        popover.onAlignTickActiveChange = { manualGates.append($0) }
        showPrompt(popover)
        // The metronome button lives in the sync drawer now (D9).
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        popover.test_syncDrawer?.test_fireAlignClick()
        #expect(manualGates == [true])

        popover.test_btAlignmentPromptView()?.test_clickAlignWithTicks()
        popover.test_btWizardView()?.test_clickButton(titled: "Start")
        #expect(manualGates == [true, false], "one tick source at a time")
        #expect(recorder.ticks == [true])
    }

    // MARK: Manual relaunch (the wizard outlives "Not now" — locked UX)

    /// The mix-selected row without any card: ⌥-click on the DRAWER's
    /// metronome opens the wizard; a plain click still runs the manual 30 s
    /// tick (the button moved off the row into the drawer — D9).
    private func selectMixedBT(_ popover: PopoverController) -> DeviceRowView? {
        popover.update(devices: [local(), airplay(), bt()])
        popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        return popover.test_deviceRow(for: "bt-a:output")
    }

    @Test func optionClickOnTheDrawerMetronomeOpensTheWizardPlainClickKeepsTheManualTick() {
        let (popover, _) = makePopover()
        _ = selectMixedBT(popover)
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        let drawer = popover.test_syncDrawer
        drawer?.test_optionModifierOverride = false
        drawer?.test_fireAlignClick()
        #expect(popover.test_alignTickDeviceID() == "bt-a:output",
                "a plain click stays the manual tick")
        #expect(popover.test_btWizardIsOpen() == false)

        drawer?.test_optionModifierOverride = true
        drawer?.test_fireAlignClick()
        #expect(popover.test_btWizardIsOpen(), "⌥-click opens the guided wizard")
        #expect(popover.test_alignTickDeviceID() == nil,
                "…which stops the running manual tick (one tick source)")
        #expect(popover.test_syncDrawer?.test_alignActive == false,
                "the toggle never flips on the ⌥ path")
    }

    @Test func contextMenuAlignItemOpensTheWizardAndExistsOnBTRowsOnly() {
        let (popover, _) = makePopover()
        let row = selectMixedBT(popover)
        let menu = row?.test_contextMenu()
        #expect(menu?.items.map(\.title) == ["Equalizer…", "Align speaker…"],
                "the discoverable route — ⌥ alone is invisible")
        #expect(fireAlignItem(menu))
        #expect(popover.test_btWizardIsOpen())

        #expect(popover.test_deviceRow(for: "office")?.test_contextMenu()?.items.map(\.title)
                == ["Equalizer…"],
                "AirPlay rows carry the Equalizer door but no alignment item")
    }

    @Test func notNowIsFinalButTheWizardStaysReachableFromTheRow() {
        let (popover, recorder) = makePopover()
        showPrompt(popover)
        popover.test_btAlignmentPromptView()?.test_clickNotNow()
        #expect(recorder.resolves.map(\.dismissed) == [true])

        #expect(fireAlignItem(popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()))
        #expect(popover.test_btWizardIsOpen(),
                "the FINAL dismissal only silences the auto-prompt, never the manual way in")
    }

    // MARK: The target is audible whichever door the wizard came through

    /// A relaunch reaching a device whose card still stands (the ⌥/menu route,
    /// which never went through the card's own action) releases the backend
    /// hold and takes the card's place. A wizard over a held-silent target is
    /// a run with nothing to hear — the live 2026-08-08 report.
    @Test func aRelaunchOverAStandingCardReleasesTheHoldAndReplacesIt() {
        let (popover, recorder) = makePopover()
        showPrompt(popover)
        #expect(recorder.resolves.isEmpty, "the hold stands while the card is up")

        #expect(fireAlignItem(popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()))
        #expect(popover.test_btWizardIsOpen())
        #expect(recorder.resolves.map(\.id) == ["bt-a:output"])
        #expect(recorder.resolves.map(\.dismissed) == [false],
                "un-mute, and never record a dismissal the user didn't give")
        #expect(popover.test_btAlignmentPromptView() == nil, "the wizard takes the card's place")
        #expect(popover.test_btAlignmentPromptDeviceID() == nil)
    }

    /// A device waiting in the QUEUE gets the same treatment when the wizard
    /// opens straight onto it — its hold would otherwise sit out the run.
    @Test func aRelaunchOnAQueuedDeviceReleasesItsHoldAndDropsItFromTheQueue() {
        let (popover, recorder) = showTwoPrompts()
        #expect(popover.test_btAlignmentPromptQueue() == ["bt-b:output"])
        popover.startBTAlignmentWizard(deviceID: "bt-b:output")
        #expect(popover.test_btWizardIsOpen())
        #expect(recorder.resolves.map(\.id) == ["bt-b:output"])
        #expect(popover.test_btAlignmentPromptQueue().isEmpty)
    }

    // MARK: The reference speaker (default, engage, restore, change)

    @Test func theMacIsTheDefaultReferenceAndTheIntroNamesIt() {
        let (popover, _) = makePopover()
        let wizard = openWizard(popover)
        #expect(popover.test_btWizardReferenceID() == "mac",
                "the Mac's own output is the default — always there, always in step")
        #expect(wizard?.test_referenceLineText
                == BTAlignmentWizardView.comparingCopy(target: "Move 2"))
        #expect(wizard?.test_selectedReferenceTitle == "This Mac")
        #expect(wizard?.test_startIsEnabled == true)
        #expect(wizard?.test_referenceOptionTitles == ["This Mac", "Office"],
                "every other available speaker is offered")
    }

    /// No Mac row in the fleet: the ONE other member the user already has
    /// audio on becomes the reference rather than an arbitrary device.
    @Test func withoutAMacTheSingleAudibleMemberIsTheReference() {
        let fleet = [airplay("office"), airplay("kitchen", name: "Kitchen"), bt()]
        let (popover, _) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        #expect(popover.test_btWizardReferenceID() == "office")
        #expect(popover.test_btWizardEngagedReferenceID() == nil,
                "an already-audible reference is left exactly as the user had it")
    }

    /// Nothing else audible and no Mac: the first other AVAILABLE device is
    /// taken and SELECTED for the run — the fix for a wizard that ticked into
    /// a group of one and produced no comparison at all.
    @Test func aSilentReferenceIsSelectedForTheRunAndRestoredAfterKeep() {
        let fleet = [airplay("office"), bt()]
        let (popover, _) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        #expect(popover.test_isSpeakerSelected("office") == false)

        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        #expect(popover.test_btWizardReferenceID() == "office")
        #expect(popover.test_btWizardEngagedReferenceID() == "office")
        #expect(popover.test_isSpeakerSelected("office"),
                "the reference is made audible through GroupController, the one selection owner")

        let wizard = popover.test_btWizardView()
        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: "Move 2")
        wizard?.test_clickButton(titled: "Office")
        wizard?.test_clickButton(titled: "Move 2")
        wizard?.test_clickButton(titled: "Keep")
        #expect(popover.test_btWizardIsOpen() == false)
        #expect(popover.test_isSpeakerSelected("office") == false,
                "Keep puts the user's Selected Devices set back")
        #expect(popover.test_btWizardEngagedReferenceID() == nil)
    }

    /// The restore is not a Keep-only courtesy — it rides the one teardown
    /// funnel, so every way out returns the selection.
    private func exitPathRestoresTheReference(
        _ exit: (PopoverController, BTAlignmentWizardView?) -> Void
    ) {
        let fleet = [airplay("office"), bt()]
        let (popover, _) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        let wizard = popover.test_btWizardView()
        wizard?.test_clickButton(titled: "Start")
        #expect(popover.test_isSpeakerSelected("office"))

        exit(popover, wizard)
        #expect(popover.test_btWizardIsOpen() == false)
        #expect(popover.test_isSpeakerSelected("office") == false)
        #expect(popover.test_btWizardEngagedReferenceID() == nil)
    }

    @Test func dismissRestoresTheEngagedReference() {
        exitPathRestoresTheReference { _, wizard in wizard?.test_clickDismiss() }
    }

    @Test func popoverCloseRestoresTheEngagedReference() {
        exitPathRestoresTheReference { popover, _ in popover.surfaceDidHide() }
    }

    @Test func aGracefulExitRestoresTheEngagedReference() {
        exitPathRestoresTheReference { _, wizard in
            wizard?.test_clickButton(titled: BTAlignmentWizardView.cantTellTitle)
            wizard?.test_clickButton(titled: BTAlignmentWizardView.cantTellTitle)
            wizard?.test_clickButton(titled: "Done")
        }
    }

    @Test func losingTheTargetRestoresTheEngagedReference() {
        exitPathRestoresTheReference { popover, _ in
            popover.update(devices: [airplay("office"), bt(available: false)])
        }
    }

    /// Real menu dispatch on the picker: the new reference is engaged, the old
    /// one released, and the answers so far are DROPPED — they were given
    /// against a different speaker.
    @Test func changingTheReferenceMidRunSwapsTheSelectionAndResetsTheRun() {
        let fleet = [local(), airplay("office"), bt()]
        let (popover, recorder) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        let wizard = popover.test_btWizardView()
        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: "Move 2")
        #expect(recorder.previews.map(\.ms) == [0, 250])

        wizard?.test_selectReference(titled: "Office")
        #expect(popover.test_btWizardReferenceID() == "office")
        #expect(popover.test_isSpeakerSelected("office"), "the new reference is engaged")
        #expect(popover.test_isSpeakerSelected("mac") == false, "…and the old one released")
        #expect(popover.test_btWizardEngagedReferenceID() == "office")
        #expect(wizard?.test_screen == .question(progress: 0, answersSoFar: 0),
                "the bisection restarts — the earlier answers are not evidence about Office")
        #expect(recorder.previews.map(\.ms) == [0, 250, 0])
        #expect(wizard?.test_buttonTitles == ["Move 2", "Office", "Can't tell"])
    }

    /// Nothing else to compare against: the wizard opens, says why, and Start
    /// stays off rather than running a comparison that cannot be heard.
    @Test func withNoOtherSpeakerTheIntroSaysSoAndStartIsDisabled() {
        let fleet = [bt()]
        let (popover, recorder) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        let wizard = popover.test_btWizardView()
        #expect(popover.test_btWizardReferenceID() == nil)
        #expect(wizard?.test_referenceLineText == BTAlignmentWizardView.noReferenceCopy)
        #expect(wizard?.test_referencePickerIsEnabled == false)
        #expect(wizard?.test_startIsEnabled == false)

        wizard?.test_clickButton(titled: "Start")   // performClick on a disabled button
        #expect(wizard?.test_screen == .intro, "the run never begins")
        #expect(recorder.ticks.isEmpty, "…and nothing ticks into a group of one")
    }

    // MARK: Wizard teardown on target loss (power-off keeps the row)

    @Test func wizardTearsDownWhenItsTargetLosesAvailability() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")

        // Power-off: the row stays (greyed) but the sink is gone — the edge
        // also deselects (BT-UI "off = unselected").
        popover.update(devices: [local(), airplay(), bt(available: false)])
        #expect(popover.test_btWizardIsOpen() == false,
                "no wizard over a silent target — the row surviving is not enough")
        #expect(recorder.ends.map(\.keep) == [nil], "the prior trim is restored")
        #expect(recorder.ticks == [true, false], "…and the wizard tick ends")
    }

    @Test func wizardTearsDownWhenItsTargetIsDeselected() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")

        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: false)
        #expect(popover.test_btWizardIsOpen() == false,
                "deselecting the target closes its wizard on the spot")
        #expect(recorder.ends.map(\.keep) == [nil])
        #expect(recorder.ticks == [true, false])
    }

    @Test func wizardRefusesAnUnavailableTarget() {
        let (popover, _) = makePopover()
        _ = selectMixedBT(popover)
        popover.update(devices: [local(), airplay(), bt(available: false)])
        // Losing availability DESELECTS a Bluetooth device on the edge, and a
        // deselected disconnected pairing is not listed (BT-LIST) — so there is
        // no row and no context item left to dispatch. The direct call is what
        // proves the guard now.
        #expect(popover.test_deviceRow(for: "bt-a:output") == nil,
                "the un-live target is off the list entirely")
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        #expect(popover.test_btWizardIsOpen() == false,
                "an un-live target never opens — the same conditions that tear one down")
    }
}
