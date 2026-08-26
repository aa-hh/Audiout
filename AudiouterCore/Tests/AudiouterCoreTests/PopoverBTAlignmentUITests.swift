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
        // Roadmap 056 Part A: a Bluetooth target's run MEASURES latency, and
        // SUSPENDS the device's trim while it does — so the two seams carry
        // different stories and are recorded apart. `previews`/`ends` are the
        // run's own candidates (the shape every screen test asserts on);
        // `trimPreviews`/`trimEnds` are the suspension and its restore.
        popover.onBTWizardTrimPreview = { ms, id in recorder.trimPreviews.append((ms, id)) }
        popover.onBTWizardEndPreview = { id, keep in recorder.trimEnds.append((id, keep)) }
        popover.onBTWizardLatencyPreview = { ms, id, halfWidthMs in
            recorder.previews.append((ms, id))
            recorder.previewHalfWidths.append(halfWidthMs)
        }
        popover.onBTWizardEndLatencyPreview = { id, keep in
            recorder.ends.append((id, keep))
            recorder.order.append("end")
        }
        popover.onBTWizardEndRun = {
            recorder.endRuns += 1
            recorder.order.append("endRun")
        }
        popover.onBTWizardTickActive = { active, target, reference in
            recorder.ticks.append(active)
            recorder.tickTargets.append(target)
            recorder.tickReferences.append(reference)
        }
        popover.onBTWizardTempo = { recorder.tempos.append($0) }
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
        /// How sure the run was about each candidate — threaded through purely
        /// for the trial's telemetry line.
        var previewHalfWidths: [Double?] = []
        var ends: [(id: String, keep: Double?)] = []
        var trimPreviews: [(ms: Double, id: String)] = []
        var trimEnds: [(id: String, keep: Double?)] = []
        var endRuns = 0
        /// Keep's two backend calls in the order they landed: the measurement
        /// has to be stored BEFORE the raised reference comes back down.
        var order: [String] = []
        var ticks: [Bool] = []
        var tickTargets: [String?] = []
        var tickReferences: [String?] = []
        var tempos: [Double] = []
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
        // The default reference is the Mac, so this pair spans two transports
        // and the intro names the two sounds — see
        // `theIntroNamesTheTwoSoundsOnlyWhenThePairMakesTwo`.
        #expect(popover.test_btWizardView()?.test_bodyText
                == BTAlignmentWizardView.introCopyNamingSounds(
                    target: "Move 2", targetIsBluetooth: true, reference: "This Mac"))
    }

    /// The tick's two timbres are split by TRANSPORT, not by role: the
    /// Bluetooth fan-out gets the bright click, the engine feed (AirPlay + the
    /// Mac's own output) the low knock. So a Bluetooth target against the Mac
    /// really does make two sounds and the intro says which is which — while
    /// Bluetooth-against-Bluetooth plays one identical click on both sides and
    /// the copy stays exactly as it was, because promising a cue the run isn't
    /// giving is worse than saying nothing (research brief §1/§5).
    @Test func theIntroNamesTheTwoSoundsOnlyWhenThePairMakesTwo() {
        let (popover, _) = makePopover()
        showPrompt(popover)
        popover.test_btAlignmentPromptView()?.test_clickAlignWithTicks()
        #expect(popover.test_btWizardView()?.test_bodyText
                == "You’ll hear a bright click from Move 2 and a low knock from "
                + "This Mac. Tap the one you hear first.")

        // Two Bluetooth speakers and nothing else: both sides are on the same
        // fan-out, so both play the SAME click.
        let fleet = [bt("bt-a:output", name: "Move 2"), bt("bt-b:output", name: "Roam")]
        let (btOnly, _) = makePopover(fleet: fleet)
        btOnly.update(devices: fleet)
        btOnly.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        btOnly.test_toggleDeviceEnabled(deviceID: "bt-b:output", on: true)
        btOnly.startBTAlignmentWizard(deviceID: "bt-a:output")
        #expect(btOnly.test_btWizardView()?.test_bodyText == BTAlignmentWizardView.introCopy)
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

        // The key, not the button — `theIntrosStopIsTheSameExitAsEscape`
        // covers the button and proves the two land in the same place.
        #expect(popover.test_btWizardView()?
            .test_sendKey(keyCode: 53, characters: "\u{1b}") == true)
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

    /// Mounts the live sheet's content in a real `NSWindow` — the ONLY seam
    /// that proves the wizard's keyboard actually works.
    ///
    /// TRAP the keyboard tests below exist for (live bug, build wizardv6 —
    /// ←/→ did nothing on the question screen while this suite was green):
    /// AppKit offers a key to `performKeyEquivalent(with:)` only when it
    /// carries a MODIFIER. A plain ←/→/Space/Esc/Return skips that pass
    /// entirely and is delivered to the window's FIRST RESPONDER as an
    /// ordinary `keyDown`. A test that calls `performKeyEquivalent` directly
    /// therefore says nothing about what a real key press does — so the
    /// unmodified keys are driven through this window's `sendEvent`, and only
    /// ⌘Z keeps the key-equivalent seam.
    private func hostSheetInWindow(_ popover: PopoverController) -> NSWindow? {
        guard let sheet = popover.test_btWizardSheet() else {
            Issue.record("expected a wizard sheet to host in a window")
            return nil
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = sheet.view
        return window
    }

    /// A real, unmodified key press: `NSWindow.sendEvent` is what routes it to
    /// the first responder, exactly as it does on screen.
    ///
    /// The flags are AppKit's OWN, not an empty set — the second half of the
    /// live bug (build wizardv7, ←/→ dead while Space/Esc/Return/⌘Z worked).
    /// A real ARROW keyDown carries `.function` + `.numericPad`; a test that
    /// synthesises one with no flags at all is asking a question no keyboard
    /// ever asks, and a map that rejects those bits ships green.
    private static func appKitFlags(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags {
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        return arrows.contains(keyCode) ? [.function, .numericPad] : []
    }

    private func sendKey(_ window: NSWindow, keyCode: UInt16, characters: String) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: Self.appKitFlags(forKeyCode: keyCode), timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        else {
            Issue.record("could not synthesise key \(keyCode)")
            return
        }
        window.sendEvent(event)
    }

    /// Answer every question the way a listener with `trueOffsetMs` would,
    /// through REAL button dispatch. The level being judged is read off the
    /// preview the session just pushed — the stimulus order is randomised, so
    /// a fixed click script would be judging a different offset each run.
    private func driveWizard(
        _ wizard: BTAlignmentWizardView?, _ recorder: Recorder,
        targetTitle: String, referenceTitle: String,
        trueOffsetMs: Double, jndMs: Double = 4
    ) {
        var asked = 0
        while case .question? = wizard?.test_screen, asked < 200 {
            let levelMs = recorder.previews.last?.ms ?? 0
            if abs(levelMs - trueOffsetMs) < jndMs {
                wizard?.test_clickButton(titled: BTAlignmentWizardView.togetherTitle)
            } else {
                // A LATENCY level, not a trim: a larger measured latency feeds
                // the speaker EARLIER, so a level BELOW the truth leaves the
                // target still late and the REFERENCE is what is heard first.
                wizard?.test_clickButton(titled: levelMs < trueOffsetMs ? referenceTitle : targetTitle)
            }
            asked += 1
        }
    }

    /// The mounted panel's screen, for a failure message.
    private func screenName(_ wizard: BTAlignmentWizardView?) -> String {
        String(describing: wizard?.test_screen)
    }

    /// Name the SAME side at every level, rejecting whatever the run
    /// proposes: the listener whose offset this control cannot reach. Which
    /// side pushes the run off which end depends on the run — a Bluetooth run
    /// measures LATENCY, so naming the reference drives the latency UP against
    /// its ceiling, while naming the target drives it below zero and lands on
    /// `.macIsLate` instead.
    @discardableResult
    private func clickAlwaysOneSide(_ wizard: BTAlignmentWizardView?,
                                    titled title: String) -> Int {
        var asked = 0
        while asked < 100 {
            switch wizard?.test_screen {
            case .question:
                wizard?.test_clickButton(titled: title)
                asked += 1
            case .proposal:
                wizard?.test_clickButton(titled: BTAlignmentWizardView.stillOffTitle)
            default:
                return asked
            }
        }
        return asked
    }

    /// The value on the proposal screen, or `nil` if the run is elsewhere.
    private func proposedValue(_ wizard: BTAlignmentWizardView?) -> Double? {
        guard case .proposal(let valueMs)? = wizard?.test_screen else { return nil }
        return valueMs
    }

    @Test func startBeginsTheQuestionsWithDeviceNamedButtons() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        #expect(recorder.ticks == [true], "Start turns the wizard tick on")
        #expect(recorder.previews.count == 1, "the first candidate applies immediately")
        #expect(recorder.previewHalfWidths.count == 1,
                "…carrying how sure the run is, for the trial's telemetry")
        guard case .question? = wizard?.test_screen else {
            Issue.record("expected the question screen, got \(String(describing: wizard?.test_screen))")
            return
        }
        // The QUESTION is the headline under the stage (owner ruling
        // 2026-08-23, reversing v2 §1's cut); the interval is the stage's
        // tooltip and the composed AX label keeps the long form.
        #expect(wizard?.test_readoutText?.hasPrefix(BTAlignmentWizardView.questionPrompt) == true,
                "got \(String(describing: wizard?.test_readoutText))")
        #expect(wizard?.test_stage.toolTip?.hasPrefix("Somewhere between") == true,
                "the interval is on the stage's tooltip, got \(String(describing: wizard?.test_stage.toolTip))")
        #expect(wizard?.test_buttonTitles
                == ["Move 2", "This Mac", BTAlignmentWizardView.togetherTitle,
                    BTAlignmentWizardView.backTitle, BTAlignmentWizardView.stopTitle],
                "the which-side buttons carry the ACTUAL device names, and there is a way out")
        #expect(wizard?.test_buttonIsEnabled(BTAlignmentWizardView.backTitle) == false,
                "there is nothing to go back to yet")
        // The progress bar is gone: the stage above the question IS the
        // readout, showing the live belief as a lit interval rather than a
        // fraction of a run that has no fixed length.
        if case .question? = wizard?.test_stage.test_state {} else {
            Issue.record("""
                expected a lit interval on the stage, got \
                \(String(describing: wizard?.test_stage.test_state))
                """)
        }
        // The click count rides the title row's right slot — "about 15",
        // because a variable-length run has no exact total to give.
        #expect(wizard?.test_clickCountText == BTAlignmentWizardView.clickCountCopy(1))
    }

    @Test func backUndoesTheLastAnswerAndReAsksThatTrial() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        let first = recorder.previews[0].ms
        wizard?.test_clickButton(titled: "Move 2")
        #expect(wizard?.test_buttonIsEnabled(BTAlignmentWizardView.backTitle) == true)

        wizard?.test_clickButton(titled: BTAlignmentWizardView.backTitle)
        #expect(recorder.previews.last?.ms == first, "the undone question is asked again")
        #expect(wizard?.test_buttonIsEnabled(BTAlignmentWizardView.backTitle) == false)
    }

    @Test func answersNarrowToAProposalThenSoundsRightPersists() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        driveWizard(wizard, recorder, targetTitle: "Move 2", referenceTitle: "This Mac",
                    trueOffsetMs: 200)
        guard let valueMs = proposedValue(wizard) else {
            Issue.record("expected a proposal, got \(String(describing: wizard?.test_screen))")
            return
        }
        #expect(abs(valueMs - 200) <= 6, "the proposal is what the listener heard, got \(valueMs)")
        // The NUMBER moved to the readout, freeing the sentence to be about
        // listening (v2 spec §4).
        #expect(wizard?.test_bodyText == "Listen — the clicks should land as one.")
        #expect(wizard?.test_readoutText == "\(Int(valueMs.rounded())) ms")
        #expect(wizard?.test_buttonTitles == [BTAlignmentWizardView.soundsRightTitle,
                                              BTAlignmentWizardView.stillOffTitle,
                                              BTAlignmentWizardView.setByHandTitle,
                                              BTAlignmentWizardView.stopTitle],
                "accept, reject, the manual path, and a way out")
        #expect(recorder.ticks == [true],
                "the tick keeps running — the proposal is judged by listening to it")

        wizard?.test_clickButton(titled: BTAlignmentWizardView.soundsRightTitle)
        #expect(recorder.ends.map(\.keep) == [valueMs], "Sounds right persists the result")
        #expect(recorder.ticks == [true, false], "…and stops the tick exactly once")
        #expect(wizard?.test_screen == .kept(valueMs: valueMs),
                "the panel STAYS UP so the row can be watched changing")
        #expect(popover.test_btWizardIsOpen(), "…session and all")

        wizard?.test_clickButton(titled: "Done")
        #expect(popover.test_btWizardIsOpen() == false)
    }

    /// The live complaint: Keep wrote the value and the row only caught up
    /// after the panel was dismissed, so nobody saw it happen.
    @Test func keepRepaintsTheRowWhileTheKeptScreenIsStillUp() {
        let (popover, recorder) = makePopover()
        var latencies: [String: Double] = [:]
        popover.btLatencyProvider = { latencies[$0] }
        popover.onBTWizardEndLatencyPreview = { id, keep in
            recorder.ends.append((id, keep))
            recorder.order.append("end")
            if let keep { latencies[id] = keep }
        }
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        driveWizard(wizard, recorder, targetTitle: "Move 2", referenceTitle: "This Mac",
                    trueOffsetMs: 200)
        guard let valueMs = proposedValue(wizard) else {
            Issue.record("expected a proposal, got \(String(describing: wizard?.test_screen))")
            return
        }
        wizard?.test_clickButton(titled: BTAlignmentWizardView.soundsRightTitle)

        #expect(wizard?.test_screen == .kept(valueMs: valueMs))
        let row = popover.test_deviceRow(for: "bt-a:output")
        // The owner's live report on v11: the kept screen printed the number
        // and the row printed "0 ms" — the zeroed nudge — so the run's result
        // was nowhere on the row. The chip now carries the measurement itself.
        #expect(row?.test_syncChipTitle == "\(Int(valueMs.rounded())) ms",
                "the row shows what the wizard measured, got \(row?.test_syncChipTitle ?? "none")")
        #expect(row?.test_syncChipTooltip?
            .contains("Measured latency: \(Int(valueMs.rounded())) ms") == true,
                "…and the tooltip still splits it from the nudge")

        // Survives the surface AND the process: a fresh controller reading the
        // same store — no session cache — paints the same number.
        let (reopened, _) = makePopover()
        reopened.btLatencyProvider = { latencies[$0] }
        reopened.update(devices: [local(), airplay(), bt()])
        #expect(reopened.test_deviceRow(for: "bt-a:output")?.test_syncChipTitle
                == "\(Int(valueMs.rounded())) ms",
                "the measurement is read from the store, not the run that made it")
        // Peak first, housekeeping last — the same order the screen prints.
        #expect(popover.test_lastEnergizeAnnouncement?
            .hasPrefix(BTAlignmentWizardView.keptReadyCopy(target: "Move 2")) == true,
                "VoiceOver hears the win first: \(popover.test_lastEnergizeAnnouncement ?? "-")")
        #expect(popover.test_lastEnergizeAnnouncement?.contains("Aligned at") == true,
                "…and the measurement after it: \(popover.test_lastEnergizeAnnouncement ?? "-")")
    }

    /// "Still off" sends the run back to the questions with the tick never
    /// interrupted.
    @Test func stillOffResumesTheQuestions() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        driveWizard(wizard, recorder, targetTitle: "Move 2", referenceTitle: "This Mac",
                    trueOffsetMs: 200)
        guard proposedValue(wizard) != nil else {
            Issue.record("expected a proposal, got \(String(describing: wizard?.test_screen))")
            return
        }
        wizard?.test_clickButton(titled: BTAlignmentWizardView.stillOffTitle)
        guard case .question? = wizard?.test_screen else {
            Issue.record("expected the questions back, got \(String(describing: wizard?.test_screen))")
            return
        }
        #expect(recorder.ticks == [true], "no tick edge either way")
        #expect(recorder.ends.isEmpty, "and nothing persisted or restored")
        #expect(popover.test_btWizardIsOpen())
    }

    /// Contradictory answers never settle, and the run says so — with a route
    /// to the manual control rather than a shrug.
    @Test func answersThatNeverSettleOfferSetItByHand() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        // Two answers one way and one the other: consistent enough to keep the
        // belief moving, contradictory enough that it never settles.
        var asked = 0
        while case .question? = wizard?.test_screen, asked < 120 {
            wizard?.test_clickButton(titled: asked % 3 == 2 ? "This Mac" : "Move 2")
            asked += 1
        }
        guard case .unsettled? = wizard?.test_screen else {
            Issue.record("expected unsettled, got \(String(describing: wizard?.test_screen))")
            return
        }
        #expect(wizard?.test_bodyText == BTAlignmentWizardView.unsettledCopy)
        #expect(wizard?.test_buttonTitles == [BTAlignmentWizardView.tryAgainTitle,
                                              BTAlignmentWizardView.setByHandTitle, "Done"],
                "Try again is the default; the manual path is the quiet alternative")
        #expect(recorder.ends.map(\.keep) == [nil], "the bow-out restored the prior trim")

        wizard?.test_clickButton(titled: BTAlignmentWizardView.setByHandTitle)
        #expect(popover.test_btWizardIsOpen() == false, "the run is over either way")
        let drawer = popover.test_syncDrawer
        #expect(drawer != nil, "…and the manual control is open under the row")
        #expect(drawer?.test_valueFieldText != "0 ms",
                "the field carries the run's best guess: \(drawer?.test_valueFieldText ?? "-")")
        #expect(drawer?.test_trimMs == 0,
                "…SHOWN, never written — the drawer emits committed gestures only")
    }

    /// The wizard is a SHEET now, so the host cannot close under a live run at
    /// all (AppKit refuses `performClose` while a sheet is attached — the
    /// shell's R7). What surviving-a-hide means is therefore the app-switch
    /// tuck-away: host and sheet go together and come back together, and the
    /// run underneath never notices.
    @Test func appSwitchTuckAwayLeavesTheRunAlive() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        popover.surfaceDidHide()
        #expect(popover.test_btWizardIsOpen(), "the run outlives the tuck-away")
        #expect(popover.test_btWizardSheet() != nil)
        #expect(recorder.ticks == [true], "…tick and all")
        #expect(recorder.ends.isEmpty, "nothing restored — the run has not ended")
    }

    /// Why the wizard's target check can no longer sit behind the shown gate: a
    /// tucked-away popover still has to reach a run whose speaker went away.
    @Test func aHiddenPopoverStillTearsDownAWizardWhoseTargetIsGone() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")

        popover.test_isShownOverride = false
        popover.surfaceDidHide()
        #expect(popover.test_btWizardIsOpen(), "the close alone leaves it running")

        popover.update(devices: [local(), airplay(), bt(available: false)])
        #expect(popover.test_btWizardIsOpen() == false,
                "no wizard over a silent target, shown or not")
        #expect(popover.test_btWizardSheet() == nil)
        #expect(recorder.ends.map(\.keep) == [nil], "the prior trim is restored")
        #expect(recorder.ticks == [true, false], "…and the wizard tick ends")
    }

    /// Esc still reaches the wizard now that the sheet's own content stands
    /// between the keystroke and the view — down the seam it genuinely uses.
    /// Esc carries no modifier, so AppKit never offers it as a key equivalent;
    /// it lands on the window's first responder, which mounting the sheet's
    /// content makes the wizard view (see `hostSheetInWindow`).
    @Test func escapeReachesTheWizardThroughTheSheetContent() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        guard let window = hostSheetInWindow(popover) else { return }
        #expect(window.firstResponder === wizard,
                "the sheet's content holds the keys")
        sendKey(window, keyCode: 53, characters: "\u{1b}")
        #expect(popover.test_btWizardIsOpen() == false, "…and it stopped the run")
        #expect(recorder.ends.map(\.keep) == [nil])
        #expect(recorder.ticks == [true, false])
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

    /// The way out, in words. The 9.5 pt ✕ was the only exit and the live run
    /// never found it ("no way to exit").
    @Test func stopEndsTheRunRestoresAndSilences() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: "Move 2")

        wizard?.test_clickButton(titled: BTAlignmentWizardView.stopTitle)
        #expect(recorder.ends.map(\.keep) == [nil], "Stop restores the prior trim")
        #expect(recorder.ticks == [true, false])
        #expect(popover.test_btWizardIsOpen() == false)
    }

    /// A listener who keeps naming the target right off the end of the usable
    /// range gets told the truth — the run could not reach what they heard.
    @Test func aRunThatCannotReachTheOffsetSaysSoAndRestores() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        let asked = clickAlwaysOneSide(wizard, titled: "This Mac")
        #expect(wizard?.test_screen == .unreachable,
                "got \(String(describing: wizard?.test_screen)) after \(asked)")
        #expect(wizard?.test_bodyText == BTAlignmentWizardView.unreachableCopy)
        #expect(recorder.ends.map(\.keep) == [nil], "the prior trim is restored")
        #expect(recorder.ticks == [true, false])

        wizard?.test_clickButton(titled: "Done")
        #expect(popover.test_btWizardIsOpen() == false)
    }

    // MARK: The run suspends the device's trim (roadmap 056 Part A)

    /// A Bluetooth run measures the speaker's LATENCY, and latency and trim are
    /// the same linear term in the delay — so a run made with the trim still
    /// applied converges on `trueLatency + trim` and stores the workaround as
    /// the measurement. The run suspends the nudge to 0 the moment it opens, and
    /// puts the store's value back when the panel goes.
    @Test func aBluetoothRunSuspendsTheDevicesTrimAndRestoresItOnExit() {
        let (popover, recorder) = makePopover()
        popover.btTrimProvider = { _ in -300 }
        popover.btTrimIsSetProvider = { _ in true }
        let wizard = openWizard(popover)
        #expect(recorder.trimPreviews.map(\.ms) == [0],
                "the trim steps aside for the whole run")
        #expect(recorder.trimPreviews.map(\.id) == ["bt-a:output"])
        #expect(recorder.trimEnds.isEmpty, "…and stays aside while the run is live")

        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: "Move 2")
        #expect(recorder.trimEnds.isEmpty)

        wizard?.test_clickButton(titled: BTAlignmentWizardView.stopTitle)
        #expect(recorder.trimEnds.map(\.id) == ["bt-a:output"])
        #expect(recorder.trimEnds.map(\.keep) == [nil],
                "a discarded run puts the user's own trim back, from the store")
        #expect(recorder.endRuns == 1, "…and the raised reference comes down with it")
    }

    /// LIVE DEFECT (Sonos Move, 2026-08-22): Keep wrote the measurement and
    /// zeroed the trim, and the SYNC DRAWER standing open under the row — the
    /// very surface the run was launched from (⌥-click on its metronome) —
    /// went on showing the pre-run nudge. Its next gesture (Revert, a stepper,
    /// or the value field's own commit on the way out) then wrote that stale
    /// number straight back over the zero, and the user saw a run that
    /// "didn't update the value anywhere".
    @Test func keepRefreshesTheOpenDrawerSoItCannotWriteThePreRunTrimBack() {
        let (popover, recorder) = makePopover()
        // The store, standing in for `NativeBackend`'s trim/latency maps: the
        // pre-run nudge the user had tuned by ear, and Keep's two writes.
        var trims: [String: Double] = ["bt-a:output": 244]
        var latencies: [String: Double] = [:]
        popover.btTrimProvider = { trims[$0] ?? 0 }
        popover.btTrimIsSetProvider = { trims[$0] != nil }
        popover.btLatencyProvider = { latencies[$0] }
        popover.onSetBTTrim = { ms, id, persist in if persist { trims[id] = ms } }
        popover.onBTWizardEndLatencyPreview = { id, keep in
            recorder.ends.append((id, keep))
            recorder.order.append("end")
            guard let keep else { return }
            latencies[id] = keep
            trims[id] = 0            // `endBTWizardLatencyPreview` writes both
        }
        _ = selectMixedBT(popover)
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_syncDrawer?.test_trimMs == 244)

        popover.test_syncDrawer?.test_optionModifierOverride = true
        popover.test_syncDrawer?.test_fireAlignClick()
        let wizard = popover.test_btWizardView()
        wizard?.test_clickButton(titled: "Start")
        driveWizard(wizard, recorder, targetTitle: "Move 2", referenceTitle: "This Mac",
                    trueOffsetMs: 200)
        guard let latencyMs = proposedValue(wizard) else {
            Issue.record("expected a proposal, got \(String(describing: wizard?.test_screen))")
            return
        }
        wizard?.test_clickButton(titled: BTAlignmentWizardView.soundsRightTitle)

        #expect(recorder.ends.map(\.keep) == [latencyMs], "Keep persists the measurement")
        #expect(latencies["bt-a:output"] == latencyMs)
        #expect(trims["bt-a:output"] == 0, "…and zeroes the nudge it suspended")
        #expect(recorder.order == ["end"], "the run is not torn down yet")

        // The panel stays up on the kept screen; teardown — and with it the
        // raised reference coming back down — waits for Done.
        wizard?.test_clickButton(titled: "Done")
        #expect(recorder.order == ["end", "endRun"],
                "the reference comes down only once the measurement is stored")

        let row = popover.test_deviceRow(for: "bt-a:output")
        #expect(row?.test_syncChipTitle == "\(Int(latencyMs.rounded())) ms",
                "the row's chip carries the measurement, not the zeroed nudge")
        #expect(row?.test_syncChipTooltip?
            .contains("Measured latency: \(Int(latencyMs.rounded())) ms") == true,
                "…and the tooltip splits it from the nudge")

        let drawer = popover.test_syncDrawer
        #expect(drawer?.test_trimMs == 0, "the open drawer agrees with the store")
        #expect(drawer?.test_valueFieldText == "0 ms")
        #expect(drawer?.test_revertEnabled == false,
                "Revert's baseline moved with it — the suspended nudge is not a value to go back to")

        // The live stomp: the field commits whatever it is SHOWING when it
        // loses focus (the user clicking away, or the drawer closing), so a
        // stale readout is one click away from the store.
        drawer?.test_valueFieldEditor.test_endEditing()
        #expect(trims["bt-a:output"] == 0,
                "no drawer gesture can resurrect the pre-run trim over the measurement")
    }

    /// The whole point of the suspension: a device carrying a −300 ms nudge
    /// still measures its TRUE 200 ms latency. With the trim applied the run
    /// would have had to reach −100 ms of latency, which is not a physical
    /// quantity — it pins at 0 and bows out `.unreachable`.
    @Test func aTrimmedDeviceStillMeasuresItsTrueLatency() {
        let (popover, recorder) = makePopover()
        popover.btTrimProvider = { _ in -300 }
        popover.btTrimIsSetProvider = { _ in true }
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        driveWizard(wizard, recorder, targetTitle: "Move 2", referenceTitle: "This Mac",
                    trueOffsetMs: 200)
        guard let latencyMs = proposedValue(wizard) else {
            Issue.record("expected a proposal, got \(String(describing: wizard?.test_screen))")
            return
        }
        #expect(abs(latencyMs - 200) <= 6, "the measurement is the hardware's, got \(latencyMs)")

        wizard?.test_clickButton(titled: BTAlignmentWizardView.soundsRightTitle)
        #expect(recorder.ends.map(\.keep) == [latencyMs], "Keep persists the measurement")
        // The nudge was a manual stand-in for exactly that latency; keeping both
        // would double the correction, so it starts fresh from the measurement.
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_syncDrawer?.test_trimMs == 0,
                "the row's trim reads 0 after the run, not the pre-run −300")
    }

    /// Real device names are long. The question screen's buttons have to give
    /// way rather than overrun the panel's required content pin — no absolute
    /// widths here, just "does the content still fit what it was given".
    @Test func aLongDeviceNameStillLaysOutInsideThePanel() {
        let longName = "Sony WH-1000XM3 Wireless Headphones"
        let fleet = [local(), airplay(), bt(name: longName)]
        let (popover, _) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        let wizard = popover.test_btWizardView()
        wizard?.test_clickButton(titled: "Start")
        #expect(wizard?.test_buttonTitles.first == longName)
        #expect(wizard?.test_contentFitsItsWidth == true,
                "a long name must shrink its button, not break the panel's layout")
    }

    /// The title row is the other place a name can run past its slot, and the
    /// failure there is invisible in code: both micro-labels are pinned to
    /// opposite edges of a plain container, so an over-long `Align <name>`
    /// draws straight THROUGH `Click n of about 15` rather than being clipped.
    @Test func aVeryLongDeviceNameTruncatesInsteadOfOverprintingTheClickCount() {
        let longName = "Downstairs Living Room Sonos Play:5 Right Channel Speaker"
        let fleet = [local(), airplay(), bt(name: longName)]
        let (popover, _) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        let wizard = popover.test_btWizardView()
        wizard?.test_clickButton(titled: "Start")
        #expect(wizard?.test_clickCountText == "Click 1 of about 15")
        #expect(wizard?.test_titleSlotsAreClear == true,
                "the name gives way to the click count, never overprints it")
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
        #expect(menu?.items.map(\.title) == ["Align speaker…"],
                "the discoverable route — ⌥ alone is invisible")
        menu?.performActionForItem(at: 0)   // real AppKit menu dispatch
        #expect(popover.test_btWizardIsOpen())

        #expect(popover.test_deviceRow(for: "office")?.test_contextMenu() == nil,
                "AirPlay rows carry no alignment menu")
    }

    @Test func notNowIsFinalButTheWizardStaysReachableFromTheRow() {
        let (popover, recorder) = makePopover()
        showPrompt(popover)
        popover.test_btAlignmentPromptView()?.test_clickNotNow()
        #expect(recorder.resolves.map(\.dismissed) == [true])

        let menu = popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()
        menu?.performActionForItem(at: 0)   // real AppKit menu dispatch
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

        let menu = popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()
        menu?.performActionForItem(at: 0)   // real AppKit menu dispatch
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
        #expect(wizard?.test_referenceLineText == BTAlignmentWizardView.compareLabel)
        #expect(wizard?.test_selectedReferenceTitle == "This Mac")
        #expect(wizard?.test_startIsEnabled == true)
        #expect(wizard?.test_referenceOptionTitles == ["This Mac", "Office"],
                "every other available speaker is offered")
        // The intro's SECOND action, and it used to disappear beside the gold
        // Start plate ("blends right into the background beside this huge
        // CTA", owner 2026-08-24). Raising the voice alone was the right
        // direction and not enough ("bring the fact that this is an element you
        // need to interact with further in focus"), so a choice is now a FORM
        // FIELD: labelled line over a large pop-up at the full body measure.
        #expect(wizard?.test_referenceLineIsRaised == true)
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
        let (popover, recorder) = makePopover(fleet: fleet)
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
        driveWizard(wizard, recorder, targetTitle: "Move 2", referenceTitle: "Office",
                    trueOffsetMs: 200)
        wizard?.test_clickButton(titled: BTAlignmentWizardView.soundsRightTitle)
        wizard?.test_clickButton(titled: "Done")
        #expect(popover.test_btWizardIsOpen() == false)
        #expect(popover.test_isSpeakerSelected("office") == false,
                "the close puts the user's Selected Devices set back")
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

    @Test func stopRestoresTheEngagedReference() {
        exitPathRestoresTheReference { _, wizard in
            wizard?.test_clickButton(titled: BTAlignmentWizardView.stopTitle)
        }
    }

    /// The same rule one level down: a popover close is not an exit, so the
    /// reference the run engaged for itself stays engaged with it.
    @Test func popoverCloseKeepsTheEngagedReferenceSelected() {
        let fleet = [airplay("office"), bt()]
        let (popover, _) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        popover.test_btWizardView()?.test_clickButton(titled: "Start")
        #expect(popover.test_isSpeakerSelected("office"))

        popover.surfaceDidHide()
        #expect(popover.test_btWizardIsOpen())
        #expect(popover.test_isSpeakerSelected("office"),
                "only a real exit puts the user's Selected Devices set back")
        #expect(popover.test_btWizardEngagedReferenceID() == "office")
    }

    @Test func aBowOutRestoresTheEngagedReference() {
        exitPathRestoresTheReference { _, wizard in
            self.clickAlwaysOneSide(wizard, titled: "Office")
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
        #expect(recorder.previews.count == 2)

        wizard?.test_selectReference(titled: "Office")
        #expect(popover.test_btWizardReferenceID() == "office")
        #expect(popover.test_isSpeakerSelected("office"), "the new reference is engaged")
        #expect(popover.test_isSpeakerSelected("mac") == false, "…and the old one released")
        #expect(popover.test_btWizardEngagedReferenceID() == "office")
        guard case .question(_, _, let answers)? = wizard?.test_screen, answers == 0 else {
            Issue.record("the answers about the old speaker are dropped, got \(screenName(wizard))")
            return
        }
        #expect(recorder.previews.count == 3, "a fresh run's first candidate is applied")
        #expect(wizard?.test_buttonTitles
                == ["Move 2", "Office", BTAlignmentWizardView.togetherTitle,
                    BTAlignmentWizardView.backTitle, BTAlignmentWizardView.stopTitle])
    }

    /// The tick gate carries BOTH participants, so the backend can hold every
    /// other Bluetooth speaker silent — and a reference swapped mid-run re-pushes
    /// it, or the new reference would be the one left silent.
    @Test func theTickCarriesBothParticipantsAndARefSwapRePushesThem() {
        let fleet = [local(), airplay("office"), bt()]
        let (popover, recorder) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        let wizard = popover.test_btWizardView()
        wizard?.test_clickButton(titled: "Start")
        #expect(recorder.tickTargets == ["bt-a:output"])
        #expect(recorder.tickReferences == ["mac"], "the Mac is the default reference")

        wizard?.test_selectReference(titled: "Office")
        #expect(recorder.ticks == [true, true], "a live run re-pushes rather than re-arming")
        #expect(recorder.tickReferences == ["mac", "office"],
                "the backend hears about the swap, got \(recorder.tickReferences)")

        wizard?.test_clickButton(titled: BTAlignmentWizardView.stopTitle)
        #expect(recorder.ticks.last == false)
    }

    /// A run whose answers put the speaker AHEAD of the Mac has not measured a
    /// latency — with the Mac as the zero that is not a thing a speaker does. It
    /// says so and stores nothing, rather than rounding a bad reading to 0.
    @Test func aRunThatMakesTheMacTheLateOneSaysSoAndPersistsNothing() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        driveWizard(wizard, recorder, targetTitle: "Move 2", referenceTitle: "This Mac",
                    trueOffsetMs: -60)
        #expect(wizard?.test_screen == .macIsLate,
                "got \(String(describing: wizard?.test_screen))")
        #expect(wizard?.test_bodyText == BTAlignmentWizardView.macIsLateCopy)
        // The copy no longer offers "try again" in prose — the screen carries
        // a real button for it (v2 spec §1).
        #expect(wizard?.test_buttonTitles == [BTAlignmentWizardView.tryAgainTitle, "Done"])
        #expect(recorder.ends.map(\.keep) == [nil], "nothing is persisted")

        wizard?.test_clickButton(titled: "Done")
        #expect(popover.test_btWizardIsOpen() == false)
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
        // Nothing to pick, so no field is mounted — the line is a caption.
        #expect(wizard?.test_referenceLineIsRaised == false)
        #expect(wizard?.test_startIsEnabled == false)

        wizard?.test_clickButton(titled: "Start")   // performClick on a disabled button
        #expect(wizard?.test_screen == .intro, "the run never begins")
        #expect(recorder.ticks.isEmpty, "…and nothing ticks into a group of one")
        // …but the screen is never a dead end: Start is off, so Stop is the
        // one enabled control, and it is on screen rather than only on Esc.
        #expect(wizard?.test_buttonIsEnabled(BTAlignmentWizardView.stopTitle) == true)
        wizard?.test_clickButton(titled: BTAlignmentWizardView.stopTitle)
        #expect(popover.test_btWizardIsOpen() == false)
    }

    /// The intro's own way out. A sheet carries no ✕, so before Start the
    /// only exit was Esc — undiscoverable on a mouse, and with no reference
    /// to compare against Start is disabled and the screen held no enabled
    /// control at all. Stop is now in the same trailing corner every other
    /// screen puts it in, and it is the SAME exit: driven through the
    /// button's real dispatch it leaves exactly the state the key leaves.
    @Test func theIntrosStopIsTheSameExitAsEscape() {
        func endTheIntro(byStop: Bool)
            -> (open: Bool, ticks: [Bool], endRuns: Int, resolved: [String]) {
            let (popover, recorder) = makePopover()
            let wizard = openWizard(popover)
            #expect(wizard?.test_screen == .intro)
            #expect(wizard?.test_buttonTitles == ["Start", BTAlignmentWizardView.stopTitle],
                    "the intro offers exactly one action and one exit")
            if byStop {
                wizard?.test_clickButton(titled: BTAlignmentWizardView.stopTitle)
            } else {
                #expect(wizard?.test_sendKey(keyCode: 53, characters: "\u{1b}") == true)
            }
            return (popover.test_btWizardIsOpen(), recorder.ticks, recorder.endRuns,
                    recorder.resolves.map(\.id))
        }
        let stopped = endTheIntro(byStop: true)
        #expect(stopped.open == false, "Stop closes the sheet from the intro")
        #expect(stopped == endTheIntro(byStop: false),
                "…and leaves exactly what Esc leaves")
    }

    /// Exactly one speaker to compare against is not a CHOICE: the intro
    /// states the fact in plain text rather than mounting a pop-up with a
    /// single item in it, and Start is live all the same (v2 spec §1).
    @Test func aSingleReferenceCandidateReadsAsTextWithNoPicker() {
        let fleet = [local(), bt()]
        let (popover, _) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output")
        let wizard = popover.test_btWizardView()
        #expect(popover.test_btWizardReferenceID() == "mac")
        #expect(wizard?.test_referenceLineText == "Compare against This Mac")
        #expect(wizard?.test_referencePickerIsEnabled == false)
        #expect(wizard?.test_startIsEnabled == true)
        // …and it stays a CAPTION with no field mounted. The form field is the
        // choice case's alone: nothing on this line can be clicked, so dressing
        // it as a control would promise an affordance the screen doesn't have.
        #expect(wizard?.test_referenceLineIsRaised == false)
    }

    // MARK: Zero-click (a speaker measured before)

    /// A device with a stored measurement opens straight on the PROPOSAL:
    /// "still right?" is one click where a fresh run is a dozen answers.
    @Test func aPreviouslyMeasuredSpeakerOpensOnTheProposal() {
        let (popover, recorder) = makePopover()
        popover.btLatencyProvider = { $0 == "bt-a:output" ? 244 : nil }
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        #expect(wizard?.test_screen == .proposal(valueMs: 244),
                "got \(String(describing: wizard?.test_screen))")
        #expect(recorder.previews.map(\.ms) == [244], "applied so it can be judged")
        #expect(recorder.ticks == [true])

        wizard?.test_clickButton(titled: BTAlignmentWizardView.stillOffTitle)
        guard case .question? = wizard?.test_screen else {
            Issue.record("Still off falls into the ordinary flow, got \(screenName(wizard))")
            return
        }
    }

    /// The Mac's own row is a SETTING, not a measurement, so it never gets the
    /// shortcut.
    @Test func theMacsOwnRunNeverOpensOnAProposal() {
        let (popover, _) = makePopover()
        popover.btLatencyProvider = { _ in 244 }
        popover.update(devices: [local(), airplay(), bt()])
        // Office FIRST: an AirPlay device turning on while the Mac is the sole
        // selection auto-swaps the Mac out, and the wizard refuses a target
        // outside the user's audio intent.
        popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_toggleDeviceEnabled(deviceID: "mac", on: true)
        popover.startBTAlignmentWizard(deviceID: "mac")
        let wizard = popover.test_btWizardView()
        wizard?.test_clickButton(titled: "Start")
        guard case .question? = wizard?.test_screen else {
            Issue.record("expected a question, got \(String(describing: wizard?.test_screen))")
            return
        }
    }

    /// The Mac's run writes its TRIM, and its row keeps reading that setting —
    /// a Bluetooth speaker's measured latency is never borrowed onto it, and
    /// its chip never grows a "Measured latency" line.
    @Test func theMacsOwnRowKeepsShowingItsTrim() {
        let (popover, _) = makePopover()
        var trim: Double = 18
        popover.btLatencyProvider = { _ in 244 }
        popover.localTrimProvider = { trim }
        popover.localTrimIsSetProvider = { true }
        popover.onLocalTrimEndPreview = { if let keep = $0 { trim = keep } }
        popover.update(devices: [local(), airplay(), bt()])

        let mac = popover.test_deviceRow(for: "mac")
        #expect(mac?.test_syncChipTitle == "18 ms", "the Mac's chip is its own setting")
        #expect(mac?.test_syncChipTooltip?.contains("Measured latency") == false,
                "and a Bluetooth measurement never leaks onto it")
    }

    // MARK: Keyboard

    /// The locked key map, each key through the seam AppKit really uses for
    /// it — the unmodified three as a first-responder `keyDown` delivered by a
    /// real window, ⌘Z as a genuine key equivalent, and each carrying the
    /// flags AppKit itself stamps on it (`sendKey` — the arrows arrive
    /// `.function` + `.numericPad`, never bare). See `hostSheetInWindow` for
    /// why the old `performKeyEquivalent`-only version of this test could pass
    /// over a keyboard that did nothing on screen; the flags are the same
    /// story one layer down — synthesised bare, ← and → answered a question no
    /// real keyboard asks.
    @Test func theQuestionScreenAnswersFromTheKeyboard() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        guard let window = hostSheetInWindow(popover) else { return }

        sendKey(window, keyCode: 123, characters: "\u{F702}")  // ← is the target
        sendKey(window, keyCode: 124, characters: "\u{F703}")  // → is the reference
        sendKey(window, keyCode: 49, characters: " ")          // Space is "Both at once"
        guard case .question(_, _, let answers)? = wizard?.test_screen else {
            Issue.record("expected a question, got \(String(describing: wizard?.test_screen))")
            return
        }
        #expect(answers == 3, "three keys, three answers")

        #expect(wizard?.test_sendKey(keyCode: 6, characters: "z", modifiers: .command) == true,
                "⌘Z is Undo — carrying a modifier, it really is a key equivalent")
        guard case .question(_, _, let afterBack)? = wizard?.test_screen else {
            Issue.record("expected a question, got \(String(describing: wizard?.test_screen))")
            return
        }
        #expect(afterBack == 2)
        #expect(recorder.previews.count == 5, "each key applied a fresh candidate")
    }

    /// Escape belongs to the WIZARD while its sheet is up — the view's own
    /// `keyDown` consumes it, so it never travels on to the shell panel's
    /// "close the whole surface" handling. (`test_sendKey` routes an
    /// unmodified key to `keyDown` for the reason `hostSheetInWindow`
    /// records.)
    @Test func escapeStopsTheWizardRatherThanClosingTheSurface() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        #expect(wizard?.test_sendKey(keyCode: 53, characters: "\u{1b}") == true,
                "the wizard CONSUMED the key")
        #expect(popover.test_btWizardIsOpen() == false, "…and stopped the run")
        #expect(recorder.ends.map(\.keep) == [nil], "Esc restores the prior trim")
        #expect(recorder.ticks == [true, false])
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

    /// Under a LIVE sheet the same loss bows out IN PLACE: the RUN ends on the
    /// spot exactly as above, but a modal that vanishes mid-sentence is more
    /// jarring than one line and a Done, so the sheet stands until it is
    /// answered.
    @Test func targetLostUnderALiveSheetBowsOutInPlace() {
        let (popover, recorder) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        popover.test_btWizardSheet()?.test_isHostedOverride = true

        popover.update(devices: [local(), airplay(), bt(available: false)])
        #expect(popover.test_btWizardIsOpen() == false, "the run is over the moment the sink goes")
        #expect(recorder.ends.map(\.keep) == [nil], "the prior trim is restored")
        #expect(recorder.ticks == [true, false], "…and the wizard tick ends")
        #expect(popover.test_btWizardSheet() != nil, "…but the sheet stays up to say so")
        #expect(popover.test_btWizardView()?.test_bodyText
                == BTAlignmentWizardView.targetLostCopy(target: "Move 2"))

        wizard?.test_clickButton(titled: "Done")
        #expect(popover.test_btWizardSheet() == nil, "Done dismisses and frees the slot")
    }

    /// Return has to reach the ONE control the fourth bow-out has. On the
    /// other three ⏎ lands on Try again; here there is nothing to try again,
    /// so the chip drawn on Done has to be real.
    ///
    /// Return is NOT in the wizard's own key map: it is unmodified, so it goes
    /// to the first responder, whose `keyDown` deliberately falls through to
    /// `super` — up the responder chain to the WINDOW's default-button
    /// dispatch, which fires the plate carrying `keyEquivalent = "\r"`. That
    /// dispatch only exists inside a real window, so this drives one.
    @Test func returnFiresTheTargetLostBowOutsDone() {
        let (popover, _) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        // A real window makes the sheet genuinely hosted — no override needed.
        guard let window = hostSheetInWindow(popover) else { return }
        popover.update(devices: [local(), airplay(), bt(available: false)])
        #expect(popover.test_btWizardSheet() != nil, "the bow-out is up")

        sendKey(window, keyCode: 36, characters: "\r")
        #expect(popover.test_btWizardSheet() == nil,
                "the default plate claims Return, and firing it dismisses the sheet")
    }

    /// The sheet's presentation has to hand the wizard the KEYS: the
    /// unmodified map is delivered to the first responder, so a sheet that
    /// left focus on the window would open with ←/→/Space dead — one of the
    /// two halves of the live bug.
    @Test func theSheetsPresentationMakesTheWizardTheFirstResponder() {
        let (popover, _) = makePopover()
        let wizard = openWizard(popover)
        guard let window = hostSheetInWindow(popover) else { return }
        #expect(window.firstResponder === wizard,
                "mounting the sheet's content claims first responder")
        #expect(window.initialFirstResponder === wizard,
                "…and a later key-window pass lands on the wizard, never a plate")
        // The assignment above is not enough on its own: AppKit's become-key
        // pass SKIPS an `initialFirstResponder` that declines the job (probed
        // on a real sheet — the window kept it), which is how the live sheet
        // opened with focus nowhere useful.
        #expect(wizard?.acceptsFirstResponder == true,
                "…and it only survives that pass because the view accepts")

        // A render tears the plates out. Under Full Keyboard Access a clicked
        // plate holds focus, and losing it drops the window back to itself —
        // where an arrow keyDown dies. Every screen re-claims the keys.
        wizard?.test_clickButton(titled: "Start")
        window.makeFirstResponder(window)
        wizard?.test_clickButton(titled: BTAlignmentWizardView.togetherTitle)
        #expect(window.firstResponder === wizard, "every render re-claims the keys")
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
