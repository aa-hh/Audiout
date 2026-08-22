import Foundation
import Testing
@testable import AudiouterCore

/// The alignment wizard's estimator (spec §Part 2): the coarse search that
/// finds a badly-out speaker's offset, then the constant-stimuli blocks that
/// measure it — randomized presentation, δ always subtracted back out, a
/// simulated observer with a real lapse rate, Back across the phase boundary,
/// the re-centre escape, and all three terminal states. Pure — no audio, no
/// clocks, no queues.
@Suite struct BTAlignmentConstantStimuliTests {

    /// SplitMix64 — deterministic, so a seed pins a whole run.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func engine(seed: UInt64,
                        range: ClosedRange<Double> = -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
    -> BTAlignmentConstantStimuli {
        BTAlignmentConstantStimuli(range: range, randomNumberGenerator: SeededRNG(seed: seed))
    }

    /// A listener who genuinely hears the flam: below the true offset the target
    /// leads, above it the reference does, and inside ±`jndMs` the two clicks
    /// fuse and there is nothing to call.
    private func truthful(_ levelMs: Double, trueOffsetMs: Double, jndMs: Double = 2)
    -> BTAlignmentConstantStimuli.Answer {
        if abs(levelMs - trueOffsetMs) < jndMs { return .cantTell }
        return levelMs < trueOffsetMs ? .target : .reference
    }

    /// Answer until the run terminates (or a generous ceiling, so a broken stop
    /// rule fails the test instead of hanging it). Returns how many questions
    /// the run actually asked.
    @discardableResult
    private func drive(
        _ engine: inout BTAlignmentConstantStimuli,
        answer: (Double) -> BTAlignmentConstantStimuli.Answer
    ) -> Int {
        var asked = 0
        while case .asking(let candidateMs) = engine.phase, asked < 200 {
            engine.record(answer(candidateMs))
            asked += 1
        }
        return asked
    }

    /// Skip the coarse staircase the cheapest way there is — one "can't tell"
    /// hands straight over to the blocks, with the estimate still at 0.
    private func firstBlockOrder(seed: UInt64) -> [Double] {
        var engine = engine(seed: seed)
        engine.record(.cantTell)
        var order: [Double] = []
        for _ in 0..<BTAlignmentConstantStimuli.stimuliMs.count {
            guard case .asking(let candidateMs) = engine.phase else { break }
            order.append(candidateMs)
            engine.record(.cantTell)
        }
        return order
    }

    // MARK: Presentation

    @Test func aBlockPresentsEveryStimulusInARandomisedOrder() {
        let order = firstBlockOrder(seed: 7)
        #expect(Set(order) == Set(BTAlignmentConstantStimuli.stimuliMs),
                "one block is one pass over the whole stimulus set")
        #expect(order == firstBlockOrder(seed: 7), "a seed pins the order")
        #expect(order != firstBlockOrder(seed: 99), "another seed shuffles differently")
    }

    @Test func theStimulusSetIsCoarseWingedAndDenseInTheCentre() {
        // Below ~4 ms two clicks fuse (heard as image position, not order), so
        // the centre steps 4 ms and the wings widen out to 24.
        #expect(BTAlignmentConstantStimuli.stimuliMs == [-24, -16, -8, -4, 0, 4, 8, 16, 24])
    }

    /// The δ-subtraction guarantee: the offset added to each trial lives in the
    /// PRESENTED level and never in the answer, so which order the levels came
    /// in cannot change where a consistent listener lands.
    @Test func theResultIsInvariantUnderTheShuffle() {
        var results: [Double] = []
        for seed in UInt64(1)...5 {
            var engine = engine(seed: seed)
            drive(&engine) { truthful($0, trueOffsetMs: 10) }
            guard case .converged(let resultMs) = engine.phase else {
                Issue.record("seed \(seed): expected convergence, got \(engine.phase)")
                continue
            }
            results.append(resultMs)
        }
        #expect(Set(results).count == 1, "five different orders, one answer: \(results)")
        #expect(abs((results.first ?? .nan) - 10) <= 4, "and it is the true offset: \(results)")
    }

    // MARK: The coarse search — the whole reason a never-aligned speaker works

    /// The live failure this phase exists for: a speaker 200–300 ms out sits
    /// entirely outside the ±24 ms stimulus fan, so every trial in a block
    /// sounded like the same pulse. The staircase walks the estimate into range
    /// first, and the run lands on the offset inside a run the user will sit
    /// through.
    @Test func aBadlyOutSpeakerIsFoundAndMeasured() {
        for trueOffsetMs in [200.0, 300.0] {
            var engine = engine(seed: 2)
            let asked = drive(&engine) { truthful($0, trueOffsetMs: trueOffsetMs) }
            guard case .converged(let resultMs) = engine.phase else {
                Issue.record("\(trueOffsetMs) ms: expected convergence, got \(engine.phase)")
                continue
            }
            #expect(abs(resultMs - trueOffsetMs) <= 4,
                    "landed at \(resultMs) for a \(trueOffsetMs) ms speaker")
            #expect(asked <= 28, "\(asked) questions for \(trueOffsetMs) ms")
        }
    }

    /// The staircase itself: it steps 96 ms toward the side the listener names
    /// and halves on each change of direction, so the estimate is inside the
    /// fan's half-width before the first block is built.
    @Test func theSearchStepsWideThenHalvesOnEachReversal() {
        var engine = engine(seed: 1)
        #expect(engine.phase == .asking(candidateMs: 0), "the staircase opens at the device's trim")
        engine.record(.target)
        #expect(engine.phase == .asking(candidateMs: 96), "a whole 96 ms step, not 24")
        #expect(engine.test_searchStepMs == 96)
        engine.record(.reference)
        #expect(engine.test_searchStepMs == 48, "the first reversal halves the step")
        #expect(engine.phase == .asking(candidateMs: 48))
    }

    /// "Can't tell" during the search is not a level's verdict — at 96 ms
    /// spacings there is nothing to fuse — so it simply hands over to the blocks
    /// wherever the estimate has got to.
    @Test func cantTellDuringTheSearchHandsOverToTheBlocks() {
        var engine = engine(seed: 5)
        engine.record(.target)
        engine.record(.cantTell)
        #expect(engine.test_estimateMs == 96)
        #expect(engine.test_pendingCount == BTAlignmentConstantStimuli.stimuliMs.count,
                "the first block is up, with the whole fan still to ask")
        guard case .asking(let candidateMs) = engine.phase else {
            Issue.record("expected a block question, got \(engine.phase)")
            return
        }
        #expect(BTAlignmentConstantStimuli.stimuliMs.contains(candidateMs - 96),
                "…around the estimate the staircase reached")
    }

    // MARK: Convergence under a real listener

    /// The whole reason for the constant-stimuli design: a wrong answer must
    /// nudge the fit, not derail it. With a 10 % lapse rate — one inattentive
    /// trial per block or so — the estimate still lands on the true offset for
    /// the majority of runs.
    ///
    /// It is deliberately NOT "every run": a block presents each level ONCE, so
    /// a lapse at a wing flips that level's whole verdict, and the locked
    /// crossover rule (highest target-first vs lowest reference-first) reads it
    /// at face value. That is the accepted cost of ~25 fast trials.
    @Test func aTenPercentLapseRateStillLandsOnTheTrueOffset() {
        let trueOffsetMs = 10.0
        var errors: [Double] = []
        var exits = 0
        for seed in UInt64(0)..<40 {
            var engine = engine(seed: seed)
            var observer = SeededRNG(seed: seed &+ 1_000)
            drive(&engine) { levelMs in
                guard Double.random(in: 0..<1, using: &observer) < 0.10 else {
                    return truthful(levelMs, trueOffsetMs: trueOffsetMs)
                }
                let lapses: [BTAlignmentConstantStimuli.Answer] = [.target, .reference, .cantTell]
                return lapses.randomElement(using: &observer) ?? .cantTell
            }
            guard case .converged(let resultMs) = engine.phase else {
                exits += 1
                continue
            }
            errors.append(abs(resultMs - trueOffsetMs))
        }
        #expect(exits <= 6, "a lapsing listener should still reach an answer, \(exits) bowed out")
        let within = errors.filter { $0 <= 4 }.count
        #expect(within > 20, "\(within)/40 runs landed within ±4 ms")
    }

    /// A listener whose true offset sits outside the ±24 ms fan gives a wholly
    /// one-sided block. The fan re-centres 48 ms toward the side they keep
    /// naming rather than converging on a crossover that isn't there.
    @Test func aOneSidedBlockRecentresAndThenConverges() {
        var engine = engine(seed: 3)
        drive(&engine) { truthful($0, trueOffsetMs: 60) }
        guard case .converged(let resultMs) = engine.phase else {
            Issue.record("expected convergence, got \(engine.phase)")
            return
        }
        #expect(abs(resultMs - 60) <= 4, "landed at \(resultMs)")
        #expect(engine.test_blocksCompleted >= 2, "one block is never an answer on its own")
    }

    /// A block does not have to run to its end to know it is one-sided: once both
    /// wings name the same side with nothing fused, the fan moves and the trials
    /// it never asked come back around the new estimate.
    @Test func aPlainlyOneSidedBlockRecentresWithoutAskingTheRestOfTheFan() {
        var engine = engine(seed: 3)
        engine.record(.cantTell)      // hand over to the blocks with the estimate at 0
        var asked = 0
        while engine.test_estimateMs == 0, asked < BTAlignmentConstantStimuli.stimuliMs.count {
            engine.record(.target)
            asked += 1
        }
        #expect(engine.test_estimateMs == BTAlignmentConstantStimuli.recenterStepMs,
                "the fan moved toward the side the listener keeps naming")
        #expect(asked < BTAlignmentConstantStimuli.stimuliMs.count,
                "and it moved before the whole fan had been asked, after \(asked)")
        #expect(engine.test_pendingCount == BTAlignmentConstantStimuli.stimuliMs.count - asked,
                "the trials it never asked are still queued, now at the new estimate")
    }

    // MARK: The three terminal states

    @Test func twoAllCantTellBlocksBowOut() {
        var engine = engine(seed: 11)
        drive(&engine) { _ in .cantTell }
        #expect(engine.phase == .gracefulExit,
                "nothing directional twice over: there is no alignment the ear can find")
        #expect(engine.cantTellCount == 2 * BTAlignmentConstantStimuli.stimuliMs.count + 1,
                "the one that ended the search, plus two full blocks")
    }

    /// The honest opposite of the graceful exit — and the outcome the old run
    /// reported as "already as aligned as they need to be".
    @Test func pinningAgainstTheSameBoundTwiceIsUnreachableNotAligned() {
        // A usable range this narrow cannot reach the offset the listener keeps
        // reporting, so the second move lands on the same clamp as the first.
        var engine = engine(seed: 4, range: -10...10)
        drive(&engine) { _ in .target }
        #expect(engine.phase == .unreachable,
                "the control cannot move any further toward what they're hearing")
        #expect(engine.test_estimateMs == 10, "pinned at the usable range's ceiling")
    }

    // MARK: Back

    @Test func backRequeuesTheQuestionItUndid() {
        var engine = engine(seed: 5)
        engine.record(.cantTell)   // into the blocks, estimate at 0
        guard case .asking(let first) = engine.phase else {
            Issue.record("expected a question")
            return
        }
        engine.record(.target)
        #expect(engine.answerCount == 2)
        guard case .asking(let second) = engine.phase else {
            Issue.record("expected the next question")
            return
        }

        engine.back()
        #expect(engine.answerCount == 1, "the answer is gone")
        #expect(engine.phase == .asking(candidateMs: first), "and its trial is next again")

        // Answering it again resumes exactly where the run was.
        engine.record(.target)
        #expect(engine.phase == .asking(candidateMs: second))
    }

    /// Back crosses the search/blocks boundary: the first block's first question
    /// undoes into the staircase answer that ended the search.
    @Test func backCrossesThePhaseBoundary() {
        var engine = engine(seed: 5)
        engine.record(.target)                    // search: estimate → 96
        guard case .asking(let searchQuestion) = engine.phase else {
            Issue.record("expected a second search question")
            return
        }
        engine.record(.cantTell)                  // ends the search, first block up
        #expect(engine.test_pendingCount == BTAlignmentConstantStimuli.stimuliMs.count)

        engine.back()
        #expect(engine.phase == .asking(candidateMs: searchQuestion),
                "back into the staircase, at the question it was asking")
        #expect(engine.test_estimateMs == 96, "with the estimate the staircase had reached")
        #expect(engine.answerCount == 1)

        engine.back()
        #expect(engine.phase == .asking(candidateMs: 0))
        #expect(engine.test_estimateMs == 0, "and the step it undid is off the estimate")
    }

    @Test func backWithNothingAnsweredIsANoOp() {
        var engine = engine(seed: 6)
        let before = engine.phase
        engine.back()
        #expect(engine.phase == before)
        #expect(engine.answerCount == 0)
    }

    /// The bar can never say "done" with questions left to answer — the live
    /// report's third complaint (it pegged at 100 % with 18 to go).
    @Test func progressIsMeasuredAgainstTheRunsWorstCase() {
        var engine = engine(seed: 8)
        #expect(engine.progress == 0)
        #expect(engine.questionNumber == 1)
        for _ in 0..<20 { engine.record(.cantTell) }
        if case .asking = engine.phase {
            #expect(engine.progress < 1, "still asking, so the bar is not full")
        }
        var runaway = self.engine(seed: 8)
        let asked = drive(&runaway) { _ in .cantTell }
        #expect(asked < BTAlignmentConstantStimuli.worstCaseQuestionCount,
                "the worst case really is the ceiling: \(asked)")
    }
}
