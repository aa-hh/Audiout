import Foundation
import Testing
@testable import AudiouterCore

/// The wizard's which-side bisection (W1): pure state-machine coverage —
/// truthful-oracle convergence for both signs, the two locked stop rules
/// (consecutive disagreements → mean of the last reversal midpoints; two
/// consecutive "can't tell" → graceful exit), the width floor, and seeded
/// starts.
@Suite struct BTAlignmentBisectionTests {

    /// Answer as a listener with a fixed true offset would: the target ticks
    /// first whenever the applied candidate under-delays it.
    private func truthfulAnswer(trueOffsetMs: Double, candidateMs: Double) -> BTAlignmentBisection.Answer {
        trueOffsetMs > candidateMs ? .target : .reference
    }

    private func runToTerminal(
        trueOffsetMs: Double, bracketMs: Double = BTSyncTrim.rangeMs
    ) -> (phase: BTAlignmentBisection.Phase, answers: Int) {
        var engine = BTAlignmentBisection(bracketMs: bracketMs)
        var answers = 0
        while case .asking(let candidate) = engine.phase, answers < 64 {
            engine.record(truthfulAnswer(trueOffsetMs: trueOffsetMs, candidateMs: candidate))
            answers += 1
        }
        return (engine.phase, answers)
    }

    /// A truthful answerer starts alternating the moment the bracket straddles
    /// the true offset, so the consecutive-disagreement stop rule fires within
    /// a few folds — the locked rule's resolution is therefore about an eighth
    /// of the starting bracket, not the width floor. (A real listener's
    /// near-threshold flips land the result closer; this bound is the
    /// deterministic worst case.)
    private static let truthfulOracleToleranceMs = 2 * BTSyncTrim.rangeMs / 8

    @Test func convergesOnPositiveOffset() {
        let (phase, answers) = runToTerminal(trueOffsetMs: 180)
        guard case .converged(let result) = phase else {
            Issue.record("expected convergence, got \(phase)")
            return
        }
        #expect(abs(result - 180) <= Self.truthfulOracleToleranceMs,
                "converged \(result), wanted ≈180")
        #expect(answers <= 12, "must terminate in about log2(1000/2) answers, took \(answers)")
    }

    @Test func convergesOnNegativeOffset() {
        let (phase, _) = runToTerminal(trueOffsetMs: -320)
        guard case .converged(let result) = phase else {
            Issue.record("expected convergence, got \(phase)")
            return
        }
        #expect(abs(result - (-320)) <= Self.truthfulOracleToleranceMs,
                "converged \(result), wanted ≈−320")
    }

    @Test func convergesAtZero() {
        let (phase, _) = runToTerminal(trueOffsetMs: 0)
        guard case .converged(let result) = phase else {
            Issue.record("expected convergence, got \(phase)")
            return
        }
        #expect(abs(result) <= Self.truthfulOracleToleranceMs)
    }

    /// A one-sided answerer (offset outside the bracket) rides the width floor
    /// to the bracket edge rather than looping forever.
    @Test func consistentOneSidedAnswersTerminateAtTheFloor() {
        let (phase, answers) = runToTerminal(trueOffsetMs: 5_000)
        guard case .converged(let result) = phase else {
            Issue.record("expected convergence, got \(phase)")
            return
        }
        #expect(result >= BTSyncTrim.rangeMs - 4, "pinned to the bracket's high edge, got \(result)")
        #expect(answers <= 12)
    }

    /// A seeded (narrower) bracket starts at the same centre but folds within
    /// the seed — a coarse pass's result constrains the fine pass.
    @Test func seededBracketStaysInsideTheSeed() {
        var engine = BTAlignmentBisection(bracketMs: 100)
        #expect(engine.phase == .asking(candidateMs: 0))
        engine.record(.target)
        #expect(engine.test_bracket.lowMs == 0)
        #expect(engine.test_bracket.highMs == 100)
        #expect(engine.phase == .asking(candidateMs: 50))
        let (phase, answers) = runToTerminal(trueOffsetMs: 30, bracketMs: 100)
        guard case .converged(let result) = phase else {
            Issue.record("expected convergence, got \(phase)")
            return
        }
        #expect(abs(result - 30) <= 2 * 100 / 8, "a narrower start converges proportionally tighter")
        #expect(answers <= 9, "a narrower start converges in fewer answers")
    }

    /// Two consecutive disagreements (target, reference, target) stop the loop
    /// at the mean of the two reversal midpoints.
    @Test func twoConsecutiveDisagreementsConvergeOnReversalMean() {
        var engine = BTAlignmentBisection(bracketMs: 500)
        engine.record(.target)      // low = 0, candidate 250
        engine.record(.reference)   // reversal #1: high = 250, midpoint 125
        engine.record(.target)      // reversal #2: low = 125, midpoint 187.5
        guard case .converged(let result) = engine.phase else {
            Issue.record("expected convergence, got \(engine.phase)")
            return
        }
        #expect(result == (125 + 187.5) / 2, "mean of the last two reversal midpoints")
        #expect(engine.answerCount == 3)
    }

    /// A single disagreement followed by agreement keeps going — only the
    /// CONSECUTIVE pair stops the loop.
    @Test func nonConsecutiveDisagreementsKeepAsking() {
        var engine = BTAlignmentBisection(bracketMs: 500)
        engine.record(.target)      // candidate 250
        engine.record(.reference)   // reversal #1 → candidate 125
        engine.record(.reference)   // same direction — no stop
        guard case .asking = engine.phase else {
            Issue.record("expected to keep asking, got \(engine.phase)")
            return
        }
    }

    /// Two consecutive "can't tell" exit gracefully; a directional answer in
    /// between resets the run.
    @Test func twoConsecutiveCantTellsExitGracefully() {
        var engine = BTAlignmentBisection()
        engine.record(.cantTell)
        #expect(engine.phase == .asking(candidateMs: 0), "one can't-tell keeps asking")
        engine.record(.cantTell)
        #expect(engine.phase == .gracefulExit)
        #expect(engine.cantTellCount == 2)
    }

    @Test func directionalAnswerResetsTheCantTellRun() {
        var engine = BTAlignmentBisection()
        engine.record(.cantTell)
        engine.record(.target)
        engine.record(.cantTell)
        guard case .asking = engine.phase else {
            Issue.record("expected to keep asking, got \(engine.phase)")
            return
        }
        #expect(engine.cantTellCount == 2, "every can't-tell is still counted")
        engine.record(.cantTell)
        #expect(engine.phase == .gracefulExit, "the second consecutive one exits")
    }

    /// A can't-tell never folds the bracket.
    @Test func cantTellLeavesTheBracketUntouched() {
        var engine = BTAlignmentBisection(bracketMs: 500)
        let before = engine.test_bracket
        engine.record(.cantTell)
        #expect(engine.test_bracket == before)
    }

    /// Terminal phases ignore further answers.
    @Test func terminalPhasesIgnoreFurtherAnswers() {
        var engine = BTAlignmentBisection()
        engine.record(.cantTell)
        engine.record(.cantTell)
        let terminal = engine.phase
        engine.record(.target)
        #expect(engine.phase == terminal)
    }

    /// Progress is monotone in the fold count and pinned to 1 at a terminal.
    @Test func progressNarrowsMonotonically() {
        var engine = BTAlignmentBisection()
        var previous = engine.progress
        #expect(previous == 0)
        for _ in 0..<5 {
            engine.record(.target)
            guard case .asking = engine.phase else { break }
            #expect(engine.progress > previous)
            previous = engine.progress
        }
        var exited = BTAlignmentBisection()
        exited.record(.cantTell)
        exited.record(.cantTell)
        #expect(exited.progress == 1)
    }
}
