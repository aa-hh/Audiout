// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// W3/W4 at the popover level: the first-join alignment note (mount, its two
/// actions, rebuild/close survival) and the wizard sheet (every screen
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

    private func waitFor(timeout: TimeInterval? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation,
                     _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    final class Recorder {
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
        var resets: [String] = []
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
    private func showNote(_ popover: PopoverController, id: String = "bt-a:output") {
        popover.update(devices: [local(), airplay(), bt(id)])
        popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_toggleDeviceEnabled(deviceID: id, on: true)
        popover.offerBTAlignment(deviceID: id)
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

    // MARK: Note mount + copy

    @Test func anOfferMountsTheNoteUnderTheRowWithTheLockedCopy() {
        let (popover, _) = makePopover()
        showNote(popover)
        let note = popover.test_btAlignmentNoteView("bt-a:output")
        #expect(note != nil)
        #expect(note?.test_copyText == BTAlignmentNoteView.noteCopy(name: "Move 2"))
        #expect(popover.test_btAlignmentOfferedIDs() == ["bt-a:output"])
    }

    @Test func theNoteSurvivesARebuildAndACloseReopen() {
        let (popover, _) = makePopover()
        showNote(popover)
        popover.rebuild()
        #expect(popover.test_btAlignmentNoteView("bt-a:output") != nil,
                "a rebuild remounts the note")

        popover.surfaceDidHide()
        popover.rebuild()   // the next open's rebuildForOpen path
        #expect(popover.test_btAlignmentNoteView("bt-a:output") != nil,
                "the offer survives close/reopen — the speaker is still unaligned")
    }

    // MARK: The note's two actions (real dispatch)

    /// ✕ is a SESSION hide, not a record: the note goes, and a fresh offer for
    /// the same id in the same session stays hidden. Nothing is written down —
    /// the backend offers again on the next launch.
    @Test func hidingTheNoteIsSessionOnly() {
        let (popover, _) = makePopover()
        showNote(popover)
        popover.test_btAlignmentNoteView("bt-a:output")?.test_clickHide()
        #expect(popover.test_btAlignmentNoteView("bt-a:output") == nil)

        popover.offerBTAlignment(deviceID: "bt-a:output")
        #expect(popover.test_btAlignmentNoteView("bt-a:output") == nil,
                "a re-offer in the same session stays hidden")
    }

    /// Decision 3: the note stands until the speaker is MEASURED. A run
    /// stopped before it measures anything leaves the speaker exactly as
    /// unaligned as the note said, so the invitation has to come back.
    @Test func stoppingTheWizardLeavesTheNoteStanding() {
        let (popover, _) = makePopover()
        showNote(popover)
        popover.test_btAlignmentNoteView("bt-a:output")?.test_clickAlign()
        #expect(popover.test_btWizardIsOpen())

        #expect(popover.test_btWizardView()?
            .test_sendKey(keyCode: 53, characters: "\u{1b}") == true)
        #expect(popover.test_btWizardIsOpen() == false)
        #expect(popover.test_btAlignmentNoteView("bt-a:output") != nil,
                "nothing was measured, so the offer still stands")
        #expect(popover.test_btAlignmentOfferedIDs() == ["bt-a:output"])
    }

    @Test func clickingTheNoteOpensTheWizardWithTheNoteDoor() {
        let (popover, _) = makePopover()
        showNote(popover)
        popover.test_btAlignmentNoteView("bt-a:output")?.test_clickAlign()
        #expect(popover.test_btWizardIsOpen())
        #expect(popover.test_btWizardView()?.test_screen == .intro)
        // The note is NOT consumed by opening the wizard — the sheet covers
        // it, and a run that measures nothing must leave the offer standing
        // (`stoppingTheWizardLeavesTheNoteStanding`).
        #expect(popover.test_btAlignmentNoteView("bt-a:output") != nil)
    }

    /// Two never-aligned speakers joining one mix each get their own note —
    /// there is no queue and no one-at-a-time slot any more.
    @Test func twoOffersMountTwoNotes() {
        let (popover, _) = makeTwoNotes()
        #expect(popover.test_btAlignmentNoteView("bt-a:output") != nil)
        #expect(popover.test_btAlignmentNoteView("bt-b:output") != nil)
        #expect(popover.test_btAlignmentOfferedIDs() == ["bt-a:output", "bt-b:output"])
    }

    /// The note is an invitation to MEASURE: once the speaker has a measured
    /// latency there is nothing left to invite, and a speaker dropped out of
    /// the mix has nothing to align against.
    @Test func theNoteDropsWhenTheSpeakerIsMeasuredOrDeselected() {
        let (popover, _) = makePopover()
        showNote(popover)
        popover.btLatencyProvider = { $0 == "bt-a:output" ? 320 : nil }
        popover.rebuild()
        #expect(popover.test_btAlignmentNoteView("bt-a:output") == nil,
                "a measured speaker's note is gone")
        #expect(popover.test_btAlignmentOfferedIDs().isEmpty,
                "…and the offer with it, so a re-offer cannot revive it")

        let (other, _) = makePopover()
        showNote(other)
        other.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: false)
        #expect(other.test_btAlignmentNoteView("bt-a:output") == nil,
                "a deselected speaker has nothing to align against")
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
        showNote(popover)
        popover.test_btAlignmentNoteView("bt-a:output")?.test_clickAlign()
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
        btOnly.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
        #expect(btOnly.test_btWizardView()?.test_bodyText == BTAlignmentWizardView.introCopy)
    }

    /// Two BT speakers selected into one first mix, both offered.
    private func makeTwoNotes() -> (PopoverController, Recorder) {
        let fleet = [local(), bt("bt-a:output", name: "A"), bt("bt-b:output", name: "B")]
        let (popover, recorder) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.test_toggleDeviceEnabled(deviceID: "bt-b:output", on: true)
        popover.offerBTAlignment(deviceID: "bt-a:output")
        popover.offerBTAlignment(deviceID: "bt-b:output")
        return (popover, recorder)
    }

    // MARK: Wizard screens (every transition through real dispatch)

    private func openWizard(_ popover: PopoverController) -> BTAlignmentWizardView? {
        showNote(popover)
        popover.test_btAlignmentNoteView("bt-a:output")?.test_clickAlign()
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
                    BTAlignmentWizardView.noSoundTitle,
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

    /// Identity colour names WHICH speaker: green for the target, steel blue
    /// for the reference. Magenta is group identity now, and never appears on
    /// this sheet.
    /// The count used to print a denominator the run is allowed to walk
    /// straight past: `BTAlignmentPosterior.maxAnswers` is 40, so a long run
    /// reached "Click 27 of about 15" — the sheet contradicting itself in the
    /// one slot whose arithmetic the user can check.
    @Test func theClickCountDropsItsTotalOnceTheRunPassesIt() {
        let expected = BTAlignmentWizardView.expectedClicks
        #expect(BTAlignmentWizardView.clickCountCopy(1) == "Click 1 of about \(expected)")
        #expect(BTAlignmentWizardView.clickCountCopy(expected)
                == "Click \(expected) of about \(expected)",
                "the advertised run still names its total right up to the end of it")
        #expect(BTAlignmentWizardView.clickCountCopy(expected + 1)
                .contains("of about") == false,
                "past the advertised total the denominator goes, not the count")
        #expect(BTAlignmentWizardView.clickCountCopy(27) == "Click 27 — a few extra to be sure")
    }

    /// A muted target, an asleep speaker or a volume at zero used to have no
    /// screen at all: the run asked forty questions the user was guessing at
    /// and blamed the ESTIMATE ("your answers aren't settling"). The escape
    /// leaves the session running — the tick is the whole point of coming
    /// back — so the questions are still there afterwards.
    @Test func theSilentSpeakerEscapeSwapsTheAnswersForWhatToCheck() {
        let (popover, _) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        wizard?.test_clickButton(titled: BTAlignmentWizardView.noSoundTitle)
        #expect(wizard?.test_bodyText == BTAlignmentWizardView.noSoundCopy)
        #expect(wizard?.test_buttonTitles
                == [BTAlignmentWizardView.keepListeningTitle,
                    BTAlignmentWizardView.stopTitle],
                "the three answers are gone while the user is not listening to them")
        guard case .question? = wizard?.test_screen else {
            Issue.record("the RUN is untouched — only the band changed")
            return
        }
        wizard?.test_clickButton(titled: BTAlignmentWizardView.keepListeningTitle)
        #expect(wizard?.test_buttonTitles.first == "Move 2",
                "…and the same question comes straight back")
    }

    /// Esc is the reflex key on any sheet, and it used to discard a run in
    /// silence — fourteen answers of careful listening gone to a keystroke
    /// nobody aimed. Past the threshold the exit asks first; below it there is
    /// nothing to lose and it stays instant.
    @Test func stopAsksBeforeDiscardingARunWithAnswersInIt() {
        let (popover, _) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")
        #expect(wizard?.test_stopNeedsConfirm == false, "nothing to lose yet")
        for _ in 0..<5 {
            guard case .question? = wizard?.test_screen else { break }
            wizard?.test_clickButton(titled: "Move 2")
        }
        #expect(wizard?.test_stopNeedsConfirm == true,
                "five answers in, a stray Esc is worth a question first")
    }

    @Test func theAnswerPlatesWearGreenAndSteelBlueNeverMagenta() throws {
        let (popover, _) = makePopover()
        let wizard = openWizard(popover)
        wizard?.test_clickButton(titled: "Start")

        let target = try #require(wizard?.test_plateIdentityTint("Move 2")?
            .usingColorSpace(.sRGB))
        #expect(target.greenComponent > target.blueComponent
                    && target.blueComponent > target.redComponent,
                "the target plate is green-led, got \(target)")

        let reference = try #require(wizard?.test_plateIdentityTint("This Mac")?
            .usingColorSpace(.sRGB))
        #expect(reference.blueComponent > reference.redComponent + 0.15
                    && reference.greenComponent > reference.redComponent,
                "the reference plate is blue-led, got \(reference)")
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
        showNote(popover)
        // The metronome button lives in the sync drawer now (D9). The host's
        // own toggle, not the chip: this row must stay UNTUNED so its note
        // stands, and an untuned Bluetooth chip is the wizard's door.
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        popover.test_syncDrawer?.test_fireAlignClick()
        #expect(manualGates == [true])

        popover.test_btAlignmentNoteView("bt-a:output")?.test_clickAlign()
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
        popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()
        #expect(popover.test_syncDrawer?.test_trimMs == 244)

        popover.test_syncDrawer?.test_fireAlignAgainClick()
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
        popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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

    @Test func theDrawersTwoDoorsAreSeparateButtons() {
        let (popover, _) = makePopover()
        // A MEASURED speaker: the drawer belongs to a tuned row, and its chip
        // is what opens it.
        popover.btTrimIsSetProvider = { _ in true }
        _ = selectMixedBT(popover)
        popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()
        let drawer = popover.test_syncDrawer
        drawer?.test_fireAlignClick()
        #expect(popover.test_alignTickDeviceID() == "bt-a:output",
                "the metronome stays the manual tick")
        #expect(popover.test_btWizardIsOpen() == false)

        drawer?.test_fireAlignAgainClick()
        #expect(popover.test_btWizardIsOpen(), "Align again… opens the guided wizard")
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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

        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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
                    BTAlignmentWizardView.noSoundTitle,
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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
            -> (open: Bool, ticks: [Bool], endRuns: Int) {
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
            return (popover.test_btWizardIsOpen(), recorder.ticks, recorder.endRuns)
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
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
        // A measured speaker gets no note (it has nothing left to be invited
        // to) — its drawer's "Align again…" is the door back in.
        showNote(popover)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .drawer)
        let wizard = popover.test_btWizardView()
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
        popover.startBTAlignmentWizard(deviceID: "mac", door: .menu)
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
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .menu)
        #expect(popover.test_btWizardIsOpen() == false,
                "an un-live target never opens — the same conditions that tear one down")
    }

    /// A CONNECTED speaker outside the mix is NOT an un-live one. The run
    /// measures a speaker that is playing, so the click joins it rather than
    /// refusing — a door that is offered has to open.
    @Test func alignJoinsAConnectedTargetThatIsNotInTheMixYet() {
        let (popover, _) = makePopover()
        popover.btTrimIsSetProvider = { _ in false }
        popover.update(devices: [local(), airplay(), bt()])
        popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        #expect(popover.test_isSpeakerSelected("bt-a:output") == false,
                "the target starts outside the mix")

        popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()

        #expect(popover.test_isSpeakerSelected("bt-a:output"),
                "the untuned chip's click puts the speaker into the mix")
        #expect(popover.test_btWizardIsOpen(), "…and opens the run on it")
    }

    /// The join is the user's, not the run's. The REFERENCE is borrowed and
    /// handed back on the way out (`releaseBTWizardReference`); the TARGET was
    /// asked for by name, so it stays in the mix after the run ends.
    @Test func aTargetJoinedByTheAlignClickStaysInTheMixAfterTheRun() {
        let fleet = [airplay("office"), bt()]
        let (popover, _) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.startBTAlignmentWizard(deviceID: "bt-a:output", door: .chip)
        #expect(popover.test_isSpeakerSelected("bt-a:output"))

        popover.test_btWizardView()?.test_clickButton(titled: BTAlignmentWizardView.stopTitle)

        #expect(popover.test_btWizardIsOpen() == false)
        #expect(popover.test_isSpeakerSelected("bt-a:output"),
                "the speaker the user asked to align keeps its seat in the mix")
    }

    // MARK: Reset alignment (roadmap 056) — the way back out of a Keep

    /// After a Keep the whole correction is the MEASURED latency, so the chip
    /// shows it — and the drawer's Reset is the one way to clear it. The row
    /// must return to "Not set" straight away, off the popover's own caches,
    /// without waiting for a backend push.
    @Test func resetClearsTheStoredAlignmentAndReturnsTheChipToItsAlignDoor() {
        let (popover, recorder) = makePopover()
        var latency: Double? = 429
        var trimIsSet = false
        popover.btLatencyProvider = { _ in latency }
        popover.btTrimProvider = { _ in 0 }
        popover.btTrimIsSetProvider = { _ in trimIsSet }
        popover.onResetBTAlignment = { id in
            recorder.resets.append(id)
            latency = nil
            trimIsSet = false
        }
        popover.update(devices: [local(), airplay(), bt()])

        let row = popover.test_deviceRow(for: "bt-a:output")
        #expect(row?.test_syncChipTitle == "429 ms", "the measurement, not a false \"0 ms\"")

        row?.test_fireSyncChipClick()
        let drawer = popover.test_syncDrawer
        #expect(drawer?.test_resetVisible == true, "a measured device has something to clear")

        drawer?.test_fireResetClick()
        #expect(recorder.resets == ["bt-a:output"], "one clear, for this device only")
        // A cleared BLUETOOTH speaker is never-measured again, so its chip is
        // the wizard's door once more — not a readout of nothing.
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_syncChipTitle == "Align")
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_syncChipIsDashed == true,
                "back to the dashed invitation")
    }

    /// Reset flips a Bluetooth row's chip to the wizard's door, so the chip
    /// can no longer close the drawer it opened — leaving one standing with no
    /// way out. The reset collapses it instead.
    @Test func resettingABluetoothRowCollapsesTheDrawerItLeftDoorless() {
        let (popover, _) = makePopover()
        var latency: Double? = 429
        popover.btLatencyProvider = { _ in latency }
        popover.btTrimIsSetProvider = { _ in false }
        popover.onResetBTAlignment = { _ in latency = nil }
        popover.update(devices: [local(), airplay(), bt()])

        popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()
        #expect(popover.test_expandedSyncDeviceID == "bt-a:output")

        popover.test_syncDrawer?.test_fireResetClick()
        #expect(popover.test_expandedSyncDeviceID == nil,
                "the drawer goes with the chip that opened it")
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_syncChipTitle == "Align")
    }

    @Test func resetIsNotOfferedForADeviceWithNothingStored() {
        let (popover, _) = makePopover()
        popover.btLatencyProvider = { _ in nil }
        popover.btTrimIsSetProvider = { _ in false }
        popover.update(devices: [local(), airplay(), bt()])
        // An untuned Bluetooth chip is the wizard's door, so the drawer is
        // reached through the host's own toggle here.
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_syncDrawer?.test_resetVisible == false)
    }
}

/// The wizard's four doors, asserted on the REAL `bt_sync:wizard_started`
/// event rather than on the enum's spelling.
///
/// Nested under `SerializedSharedState` because `Analytics.install` mutates
/// process-global state — the rule in `SerializedSharedStateSuite.swift`. The
/// parent suite above stays parallel; only this handful of tests pays for the
/// global sink.
extension SerializedSharedState {
    @MainActor
    @Suite struct WizardDoorAnalyticsTests {

        private final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(String, [String: String])] = []
            func append(_ name: String, _ props: [String: String]) {
                lock.withLock { items.append((name, props)) }
            }
            /// The `door` property of every `bt_sync:wizard_started` captured.
            func doors() -> [String?] {
                lock.withLock {
                    items.filter { $0.0 == "bt_sync:wizard_started" }.map { $0.1["door"] }
                }
            }
        }

        private func local() -> Device {
            Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
        }

        private func bt() -> Device {
            Device(id: "bt-a:output", name: "Move 2", kind: .bluetooth,
                   isAvailable: true, supportsAirPlay2: false)
        }

        /// A popover over a started `MockBackend`, with the Bluetooth speaker
        /// in a mix so the wizard will accept it as a target. `tuned` decides
        /// which door the row's own chip is.
        private func makePopover(tuned: Bool) -> PopoverController {
            let fleet = [local(), Device(id: "office", name: "Office", kind: .homePod), bt()]
            let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                      emitsLevels: false, simulatesDropouts: false)
            let controller = GroupController(
                backend: backend,
                store: GroupStore(directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)),
                routingStore: RoutingStore(directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)),
                loadPersisted: false)
            let popover = PopoverController()
            popover.configure(groupController: controller)
            popover.test_isShownOverride = true
            backend.start()
            SuiteWait.untilOnRunLoop { backend.devices.count == fleet.count }
            popover.btTrimIsSetProvider = { _ in tuned }
            popover.update(devices: fleet)
            popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
            popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
            return popover
        }

        /// Runs `body` with a consenting sink installed and hands back the
        /// doors it captured.
        private func doorsCaptured(_ body: () -> Void) -> [String?] {
            let captured = Captured()
            Analytics.install(Analytics.Sink(capture: { captured.append($0, $1) },
                                             consentChanged: { _ in }), consent: true)
            defer { Analytics.install(nil, consent: false) }
            body()
            return captured.doors()
        }

        @Test func theNoteDoorIsCaptured() {
            let popover = makePopover(tuned: false)
            let doors = doorsCaptured {
                popover.offerBTAlignment(deviceID: "bt-a:output")
                popover.test_btAlignmentNoteView("bt-a:output")?.test_clickAlign()
            }
            #expect(popover.test_btWizardIsOpen())
            #expect(doors == ["note"])
        }

        @Test func theChipDoorIsCaptured() {
            let popover = makePopover(tuned: false)
            let doors = doorsCaptured {
                popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()
            }
            #expect(popover.test_btWizardIsOpen())
            #expect(doors == ["chip"])
        }

        @Test func theMenuDoorIsCaptured() throws {
            let popover = makePopover(tuned: false)
            let menu = try #require(popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu())
            let index = try #require(menu.items.firstIndex { $0.title == "Align speaker…" })
            let doors = doorsCaptured {
                menu.performActionForItem(at: index)   // real AppKit menu dispatch
            }
            #expect(popover.test_btWizardIsOpen())
            #expect(doors == ["menu"])
        }

        @Test func theDrawerDoorIsCaptured() {
            // A measured speaker: its chip opens the drawer, whose
            // "Align again…" is the door under test.
            let popover = makePopover(tuned: true)
            popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()
            let doors = doorsCaptured {
                popover.test_syncDrawer?.test_fireAlignAgainClick()
            }
            #expect(popover.test_btWizardIsOpen())
            #expect(doors == ["drawer"])
        }
    }
}
