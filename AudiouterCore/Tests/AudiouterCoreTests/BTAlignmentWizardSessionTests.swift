import Foundation
import Testing
@testable import AudiouterCore

/// The wizard session (W2): drives the bisection end to end against recording
/// closures — tick lifecycle, live candidate previews relative to the base
/// trim, Keep persisting, Try again / cancel / graceful exit restoring.
@Suite final class BTAlignmentWizardSessionTests {

    private final class Recorder {
        var previews: [Int] = []
        var ends: [Int?] = []
        var ticks: [Bool] = []
        var screens: [BTAlignmentWizardSession.Screen] = []

        func makeSession(baseTrimMs: Int = 0, seedBracketMs: Int? = nil) -> BTAlignmentWizardSession {
            let session = BTAlignmentWizardSession(
                deviceID: "AA:BB:output",
                targetName: "Move 2",
                referenceName: "Kitchen HomePod",
                baseTrimMs: baseTrimMs,
                seedBracketMs: seedBracketMs,
                applyPreviewTrim: { [weak self] in self?.previews.append($0) },
                endPreview: { [weak self] in self?.ends.append($0) },
                setTick: { [weak self] in self?.ticks.append($0) })
            session.onScreenChange = { [weak self] in self?.screens.append($0) }
            return session
        }
    }

    @Test func startTurnsTheTickOnAndAppliesTheCentreCandidate() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 40)
        #expect(session.screen == .intro)
        session.start()
        #expect(recorder.ticks == [true])
        #expect(recorder.previews == [40], "first candidate = base + 0")
        #expect(session.screen == .question(progress: 0, answersSoFar: 0))
        session.cancel()
    }

    @Test func answersApplyCandidatesRelativeToTheBaseTrim() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 100)
        session.start()
        session.answer(.target)      // bracket folds up: candidate +250
        #expect(recorder.previews == [100, 350])
        session.answer(.reference)   // folds down: candidate +125
        #expect(recorder.previews.last == 225)
        guard case .question(_, let answers) = session.screen else {
            Issue.record("expected a question, got \(session.screen)")
            return
        }
        #expect(answers == 2)
        session.cancel()
    }

    @Test func candidatesClampToTheTrimRange() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 400)
        session.start()
        session.answer(.target)      // base 400 + candidate 250 → clamped 500
        #expect(recorder.previews.last == BTSyncTrim.rangeMs)
        session.cancel()
    }

    @Test func convergenceShowsTheReceiptAndStopsTheTick() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        session.answer(.target)      // candidate 250
        session.answer(.reference)   // reversal 1 → 125
        session.answer(.target)      // reversal 2 → converged (125+187)/2
        guard case .receipt(let trimMs) = session.screen else {
            Issue.record("expected receipt, got \(session.screen)")
            return
        }
        #expect(trimMs == 156)
        #expect(recorder.previews.last == 156, "the result is applied live for the receipt audition")
        #expect(recorder.ticks == [true, false], "the tick ends with the questions")
        #expect(recorder.ends.isEmpty, "nothing persisted or restored until Keep/Try again")
        session.cancel()
    }

    @Test func keepPersistsTheResultOnce() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        session.answer(.target)
        session.answer(.reference)
        session.answer(.target)
        session.keep()
        #expect(recorder.ends == [156], "Keep commits the applied result")
        session.keep()
        session.cancel()
        #expect(recorder.ends == [156], "terminal: neither a second Keep nor cancel does anything")
    }

    @Test func tryAgainRestoresThePriorTrimAndRestarts() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 60)
        session.start()
        session.answer(.target)
        session.answer(.reference)
        session.answer(.target)
        guard case .receipt = session.screen else {
            Issue.record("expected receipt, got \(session.screen)")
            return
        }
        session.tryAgain()
        #expect(recorder.ends == [nil], "Try again restores the prior trim first")
        #expect(recorder.ticks == [true, false, true], "and the tick comes back for the fresh run")
        #expect(recorder.previews.last == 60, "restart re-centres on the base trim")
        #expect(session.screen == .question(progress: 0, answersSoFar: 0))
        session.cancel()
    }

    @Test func cancelRestoresThePriorTrimAndSilencesTheTick() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: -30)
        session.start()
        session.answer(.target)
        session.cancel()
        #expect(recorder.ends == [nil])
        #expect(recorder.ticks == [true, false])
        session.answer(.reference)
        #expect(recorder.previews.count == 2, "a cancelled session ignores further answers")
    }

    @Test func twoConsecutiveCantTellsExitGracefullyAndRestore() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 25)
        session.start()
        session.answer(.cantTell)
        session.answer(.cantTell)
        #expect(session.screen == .gracefulExit)
        #expect(recorder.ends == [nil], "graceful exit restores the prior trim")
        #expect(recorder.ticks == [true, false])
        session.cancel()
        #expect(recorder.ends == [nil, nil], "the unconditional cancel re-push is harmless")
    }

    @Test func abandonedSessionCleansUpOnDeinit() {
        let recorder = Recorder()
        do {
            let session = recorder.makeSession()
            session.start()
            session.answer(.target)
        }
        #expect(recorder.ticks == [true, false], "deinit behaves as cancel")
        #expect(recorder.ends == [nil])
    }

    @Test func seededBracketNarrowsTheFirstFold() {
        let recorder = Recorder()
        let session = recorder.makeSession(baseTrimMs: 0, seedBracketMs: 100)
        session.start()
        session.answer(.target)
        #expect(recorder.previews == [0, 50], "a ±100 seed folds to 50, not 250")
        session.cancel()
    }

    @Test func screenChangesAreAnnounced() {
        let recorder = Recorder()
        let session = recorder.makeSession()
        session.start()
        session.answer(.cantTell)
        session.answer(.cantTell)
        #expect(recorder.screens.count == 3, "start + two answers each announced")
        #expect(recorder.screens.last == .gracefulExit)
        session.cancel()
    }
}
