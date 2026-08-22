import Foundation
import Testing
@testable import AudiouterCore

/// The Bayesian estimator behind the alignment wizard: does it actually find
/// the offset, in how many answers, and does it say so honestly when it
/// cannot. The headline test is a SIMULATED LISTENER — the estimator has no
/// randomness of its own, so all the randomness lives here.
@Suite struct BTAlignmentPosteriorTests {

    /// SplitMix64 — a seed pins a whole simulated run, so a failure is
    /// reproducible rather than a mood.
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

    /// A listener whose real thresholds are NARROWER than the estimator's
    /// model — the realistic case, and the one the published advice is built
    /// on: an over-broad model stays unbiased where an under-broad one does
    /// not.
    private struct Listener {
        static let fusionHalfWindowMs: Double = 4
        static let slopeMs: Double = 3
        static let lapseRate: Double = 0.10

        let trueOffsetMs: Double
        var rng: SeededRNG

        mutating func judge(levelMs: Double) -> BTAlignmentPosterior.Answer {
            let residual = trueOffsetMs - levelMs
            var target = phi((residual - Self.fusionHalfWindowMs) / Self.slopeMs)
            var reference = phi((-residual - Self.fusionHalfWindowMs) / Self.slopeMs)
            target = (1 - Self.lapseRate) * target + Self.lapseRate / 3
            reference = (1 - Self.lapseRate) * reference + Self.lapseRate / 3
            let roll = Double(rng.next() >> 11) / Double(1 << 53)
            if roll < target { return .target }
            if roll < target + reference { return .reference }
            return .together
        }

        private func phi(_ z: Double) -> Double { 0.5 * (1 + erf(z / 2.0.squareRoot())) }
    }

    private static let range: ClosedRange<Double> = -500...500

    /// Drive one run to a terminal-ish phase. Returns the phase it landed on
    /// and how many answers it took.
    private func runToCompletion(trueOffsetMs: Double, seed: UInt64,
                                 answerCap: Int = 60)
        -> (phase: BTAlignmentPosterior.Phase, answers: Int)
    {
        var estimator = BTAlignmentPosterior(range: Self.range)
        var listener = Listener(trueOffsetMs: trueOffsetMs, rng: SeededRNG(seed: seed))
        var answers = 0
        while case .asking(let levelMs) = estimator.phase, answers < answerCap {
            estimator.record(listener.judge(levelMs: levelMs))
            answers += 1
        }
        return (estimator.phase, answers)
    }

    /// THE test: 210 seeded runs across the usable range, judged by a listener
    /// the estimator's model does not exactly match. Almost every run has to
    /// reach a proposal, that proposal has to be right, and it has to get
    /// there fast — the whole point of replacing the ~30-answer method that
    /// came before.
    ///
    /// Two thresholds rather than one, because the two failure modes are
    /// different animals: a WRONG proposal is an estimator defect, a bow-out
    /// is the bow-out rules' strictness. ``stagnationFloorMs`` exists because
    /// this test once measured 9 of its 10 bow-outs as the stagnation rule
    /// catching the endgame's slow crawl from ~13 ms of half-width down to 6
    /// — runs whose next few answers would have proposed accurately. Both
    /// thresholds sit below what this build measures with room for the seeds
    /// to move, and tight enough that a real regression trips them.
    @Test func simulatedListenersReachAnAccurateProposalQuickly() {
        let offsets: [Double] = [0, 3, -3, 180, -180, 450, -450]
        var proposals = 0
        var accurate = 0
        var total = 0
        var answerCounts: [Int] = []
        var misses: [String] = []
        for offset in offsets {
            for seed in UInt64(1)...30 {
                total += 1
                let (phase, answers) = runToCompletion(trueOffsetMs: offset, seed: seed)
                answerCounts.append(answers)
                guard case .proposing(let valueMs) = phase else {
                    misses.append("offset \(offset) seed \(seed): \(phase) after \(answers)")
                    continue
                }
                proposals += 1
                if abs(valueMs - offset) <= 4 { accurate += 1 }
                else { misses.append("offset \(offset) seed \(seed): proposed \(valueMs)") }
            }
        }
        #expect(total == 210)
        #expect(Double(proposals) / Double(total) >= 0.95,
                "\(proposals)/\(total) reached a proposal — \(misses.prefix(8))")
        #expect(Double(accurate) / Double(proposals) >= 0.95,
                "\(accurate)/\(proposals) proposals landed within 4 ms — \(misses.prefix(8))")
        let median = answerCounts.sorted()[answerCounts.count / 2]
        #expect(median <= 20, "median run length was \(median) answers")
    }

    /// "They sound together" is EVIDENCE, not a shrug: the old constant-stimuli
    /// design needed whole blocks because a staircase cannot use a
    /// non-monotonic answer. Repeated at one level it should pull the belief
    /// onto that level.
    @Test func togetherConcentratesTheBeliefOnThePresentedLevel() {
        var estimator = BTAlignmentPosterior(range: Self.range)
        let openingHalfWidth = estimator.credibleHalfWidthMs
        var levels: [Double] = []
        for _ in 0..<6 {
            guard case .asking(let levelMs) = estimator.phase else { break }
            levels.append(levelMs)
            estimator.record(.together)
        }
        #expect(estimator.credibleHalfWidthMs < openingHalfWidth,
                "the interval narrowed on together answers alone")
        let interval = estimator.credibleIntervalMs
        #expect(levels.allSatisfy { abs($0 - estimator.medianMs) < 40 },
                "levels \(levels) vs median \(estimator.medianMs)")
        #expect(interval.contains(estimator.medianMs))
    }

    // MARK: The confirm step

    private func drivenToProposal(trueOffsetMs: Double = 120, seed: UInt64 = 7)
        -> (BTAlignmentPosterior, Double)
    {
        var estimator = BTAlignmentPosterior(range: Self.range)
        var listener = Listener(trueOffsetMs: trueOffsetMs, rng: SeededRNG(seed: seed))
        var answers = 0
        while case .asking(let levelMs) = estimator.phase, answers < 60 {
            estimator.record(listener.judge(levelMs: levelMs))
            answers += 1
        }
        guard case .proposing(let valueMs) = estimator.phase else { return (estimator, .nan) }
        return (estimator, valueMs)
    }

    @Test func acceptingAProposalConvergesOnIt() {
        var (estimator, proposed) = drivenToProposal()
        #expect(!proposed.isNaN, "the run reached a proposal: \(estimator.phase)")
        estimator.acceptProposal()
        guard case .converged(let resultMs) = estimator.phase else {
            Issue.record("expected converged, got \(estimator.phase)")
            return
        }
        #expect(abs(resultMs - proposed) <= 1, "got \(resultMs) for a \(proposed) ms proposal")
    }

    @Test func rejectingAProposalWidensTheIntervalAndResumesQuestions() {
        var (estimator, proposed) = drivenToProposal()
        #expect(!proposed.isNaN)
        let halfWidthBefore = estimator.credibleHalfWidthMs
        let progressBefore = estimator.progress
        estimator.rejectProposal()
        guard case .asking = estimator.phase else {
            Issue.record("one rejection resumes questions, got \(estimator.phase)")
            return
        }
        #expect(estimator.credibleHalfWidthMs > halfWidthBefore,
                "\(estimator.credibleHalfWidthMs) vs \(halfWidthBefore)")
        #expect(estimator.progress < progressBefore,
                "the bar RETREATS, honestly — \(estimator.progress) vs \(progressBefore)")
    }

    @Test func twoRejectionsBowOutAsUnsettled() {
        var (estimator, proposed) = drivenToProposal()
        #expect(!proposed.isNaN)
        estimator.rejectProposal()
        // Back to the same listener until it proposes again, then reject once
        // more: that is the run's last word.
        var listener = Listener(trueOffsetMs: 120, rng: SeededRNG(seed: 99))
        var answers = 0
        while case .asking(let levelMs) = estimator.phase, answers < 60 {
            estimator.record(listener.judge(levelMs: levelMs))
            answers += 1
        }
        guard case .proposing = estimator.phase else {
            Issue.record("expected a second proposal, got \(estimator.phase)")
            return
        }
        estimator.rejectProposal()
        guard case .unsettled(let bestGuessMs) = estimator.phase else {
            Issue.record("expected unsettled, got \(estimator.phase)")
            return
        }
        #expect(estimator.test_rejections == BTAlignmentPosterior.maxRejections)
        #expect(Self.range.contains(bestGuessMs))
    }

    // MARK: The bow-outs

    /// A listener who names the target at every level pushes the belief off
    /// the top of the usable range: whatever they are hearing, this control
    /// cannot reach it. The belief piles up fast enough to PROPOSE the range's
    /// own edge first — which the listener rejects, because it is not what
    /// they are hearing — and only then does the wing rule get its say. It
    /// must never be called before that rule's own eight-answer floor.
    @Test func massPinnedInAWingBowsOutUnreachableAndNeverBeforeEightAnswers() {
        var estimator = BTAlignmentPosterior(range: Self.range)
        var answers = 0
        var rejections = 0
        while answers < 60 {
            switch estimator.phase {
            case .asking:
                estimator.record(.target)
                answers += 1
                if answers < BTAlignmentPosterior.minAnswersForUnreachable {
                    #expect(estimator.phase != .unreachable,
                            "bowed out after only \(answers) answers")
                }
            case .proposing:
                estimator.rejectProposal()
                rejections += 1
            default:
                break
            }
            if case .asking = estimator.phase { continue }
            if case .proposing = estimator.phase { continue }
            break
        }
        #expect(estimator.phase == .unreachable, "got \(estimator.phase) after \(answers)")
        #expect(answers >= BTAlignmentPosterior.minAnswersForUnreachable)
        #expect(rejections < BTAlignmentPosterior.maxRejections,
                "unreachable, not talked out of two proposals")
    }

    /// A listener whose answers contradict each other never lets the interval
    /// close, and the run says so rather than asking forever. Two-thirds one
    /// way and a third the other is the shape that does it: consistent enough
    /// to keep the belief moving, contradictory enough that it never settles.
    static let contradictoryAnswers: [BTAlignmentPosterior.Answer] =
        [.target, .target, .reference]

    @Test func answersThatNeverNarrowBowOutAsUnsettled() {
        var estimator = BTAlignmentPosterior(range: Self.range)
        var answers = 0
        while case .asking = estimator.phase, answers < 80 {
            estimator.record(Self.contradictoryAnswers[answers % 3])
            answers += 1
        }
        guard case .unsettled(let bestGuessMs) = estimator.phase else {
            Issue.record("expected unsettled, got \(estimator.phase) after \(answers)")
            return
        }
        #expect(answers <= BTAlignmentPosterior.maxAnswers,
                "nobody is asked more than \(BTAlignmentPosterior.maxAnswers): got \(answers)")
        #expect(Self.range.contains(bestGuessMs))
    }

    /// The hard cap, on its own: forty answers is the end of the run whatever
    /// the interval is doing.
    @Test func fortyAnswersEndsTheRun() {
        var estimator = BTAlignmentPosterior(range: Self.range)
        var answers = 0
        while case .asking = estimator.phase, answers < 200 {
            estimator.record(.together)
            answers += 1
        }
        #expect(answers <= BTAlignmentPosterior.maxAnswers,
                "the run ran \(answers) answers past its cap")
    }

    // MARK: Back

    /// The undo is a REFOLD from the flat prior, not a stack of saved states —
    /// a posterior does not care what order its evidence arrived in, so
    /// replaying it has to land on exactly the same numbers.
    @Test func backRefoldsToABitwiseIdenticalBelief() {
        var straight = BTAlignmentPosterior(range: Self.range)
        var undone = BTAlignmentPosterior(range: Self.range)
        straight.record(.target)
        straight.record(.reference)

        undone.record(.target)
        undone.record(.reference)
        undone.back()
        #expect(undone.answerCount == 1)
        undone.record(.reference)

        #expect(undone.test_belief == straight.test_belief,
                "the refolded belief is not bit-for-bit the straight one")
        #expect(undone.phase == straight.phase)
    }

    @Test func backBeforeAnyAnswerIsInert() {
        var estimator = BTAlignmentPosterior(range: Self.range)
        let opening = estimator.phase
        estimator.back()
        #expect(estimator.phase == opening)
        #expect(estimator.answerCount == 0)
    }

    // MARK: The zero-click opening

    @Test func anOpeningProposalStartsOnTheProposalOverAFlatPrior() {
        let estimator = BTAlignmentPosterior(range: Self.range, openingProposalMs: 244)
        #expect(estimator.phase == .proposing(valueMs: 244))
        #expect(estimator.answerCount == 0)
        let flat = BTAlignmentPosterior(range: Self.range)
        #expect(estimator.test_belief == flat.test_belief,
                "the prior behind a zero-click proposal is FLAT — no seeding")
    }

    /// The value the user agreed to is the value that comes out — even here,
    /// where the belief behind it is still flat and its median is nowhere near
    /// the proposal.
    @Test func acceptingAnOpeningProposalConvergesOnIt() {
        var estimator = BTAlignmentPosterior(range: Self.range, openingProposalMs: 244)
        estimator.acceptProposal()
        #expect(estimator.phase == .converged(resultMs: 244), "got \(estimator.phase)")
    }

    @Test func rejectingAnOpeningProposalFallsIntoTheOrdinaryQuestionFlow() {
        var estimator = BTAlignmentPosterior(range: Self.range, openingProposalMs: 244)
        estimator.rejectProposal()
        guard case .asking(let levelMs) = estimator.phase else {
            Issue.record("expected the questions to start, got \(estimator.phase)")
            return
        }
        #expect(Self.range.contains(levelMs))
        #expect(estimator.answerCount == 0, "a rejection is not an answer")
    }

    // MARK: Determinism (there is no RNG anywhere in the estimator)

    @Test func theSameAnswersProduceTheSameLevels() {
        let answers: [BTAlignmentPosterior.Answer] =
            [.target, .target, .reference, .together, .target, .reference, .together]
        func levels() -> [Double] {
            var estimator = BTAlignmentPosterior(range: Self.range)
            var seen: [Double] = []
            for answer in answers {
                guard case .asking(let levelMs) = estimator.phase else { break }
                seen.append(levelMs)
                estimator.record(answer)
            }
            return seen
        }
        #expect(levels() == levels())
        #expect(levels().count == answers.count)
    }
}
