// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing
@testable import AudioutCore

/// The drift-correction rule: which measured errors are acted on, whether the
/// move lands at once or is spread out, and how a guessed match is checked.
@Suite struct DriftCorrectionPolicyTests {

    private func observation(_ uid: String, _ errorMs: Double,
                             guess: Bool = false, t: Int64 = 0)
        -> DriftCorrectionPolicy.Observation {
        .init(deviceUID: uid, errorMs: errorMs, hostNanos: t, isBestGuess: guess)
    }

    private func correction(_ actions: [DriftCorrectionPolicy.Action])
        -> DriftCorrectionPolicy.Correction? {
        for action in actions {
            if case .correct(let move) = action { return move }
        }
        return nil
    }

    // Turns red if the lower threshold moves off 10 ms, or if the comparison
    // at the boundary flips from >= to >.
    @Test func theTenMillisecondLineDecidesWhetherToActAtAll() {
        var policy = DriftCorrectionPolicy()
        #expect(policy.decide([observation("a", 9.9)], programIsSilent: false)
                == [.ignore(deviceUID: "a", reason: .belowThreshold)])
        #expect(correction(policy.decide([observation("b", 10)], programIsSilent: false))?.ms == 10)
    }

    // Turns red if the surfacing threshold moves off 40 ms, or if the notify
    // flag stops tracking it at the boundary.
    @Test func theFortyMillisecondLineDecidesWhetherTheUserIsTold() {
        var policy = DriftCorrectionPolicy()
        #expect(correction(policy.decide([observation("a", 39.9)],
                                         programIsSilent: false))?.notify == false)
        #expect(correction(policy.decide([observation("b", 40)],
                                         programIsSilent: false))?.notify == true)
    }

    // Turns red if the sign of the error stops reaching the correction, or if
    // a negative error is band-checked unsigned only on one side.
    @Test func aNegativeErrorIsBandedByItsMagnitudeAndCorrectedSigned() {
        var policy = DriftCorrectionPolicy()
        let move = correction(policy.decide([observation("a", -45)], programIsSilent: false))
        #expect(move?.ms == -45)
        #expect(move?.notify == true)
    }

    // Turns red if silence stops choosing an immediate move, or if playing
    // program stops choosing a slew.
    @Test func silenceCorrectsAtOnceAndMusicSlews() {
        var policy = DriftCorrectionPolicy()
        #expect(correction(policy.decide([observation("a", 20)],
                                         programIsSilent: true))?.placement == .inGap)
        #expect(correction(policy.decide([observation("b", 20)],
                                         programIsSilent: false))?.placement == .slew)
    }

    // Turns red if a gap stops finishing a running slew, or if it returns the
    // whole correction again instead of only the part not yet applied.
    @Test func aGapFinishesWhatIsLeftOfARunningSlew() {
        var policy = DriftCorrectionPolicy()
        _ = policy.decide([observation("a", 30)], programIsSilent: false)
        let actions = policy.programBecameSilent(appliedSoFarMs: ["a": 12])
        #expect(actions == [.correct(.init(deviceUID: "a", ms: 18,
                                           placement: .inGap, notify: false))])
        #expect(policy.programBecameSilent(appliedSoFarMs: ["a": 30]).isEmpty,
                "a slew already finished in a gap is not finished twice")
    }

    // Turns red if a guessed match stops asking for a verify, or if an
    // unambiguous one starts asking for one.
    @Test func onlyAGuessedMatchAsksToBeVerified() {
        var policy = DriftCorrectionPolicy()
        let guessed = policy.decide([observation("a", 25, guess: true),
                                     observation("b", 30, guess: true)],
                                    programIsSilent: false)
        #expect(guessed.last == .scheduleVerify(deviceUIDs: ["a", "b"]))
        var plain = DriftCorrectionPolicy()
        #expect(plain.decide([observation("a", 25)], programIsSilent: false).count == 1)
    }

    // Turns red if a guessed correction below the ignore line still asks for a
    // verify — nothing was applied, so there is nothing to check.
    @Test func aGuessTooSmallToActOnAsksForNoVerify() {
        var policy = DriftCorrectionPolicy()
        let actions = policy.decide([observation("a", 5, guess: true)], programIsSilent: false)
        #expect(actions == [.ignore(deviceUID: "a", reason: .belowThreshold)])
    }

    // Turns red if a verify window that comes back clean is read as a fresh
    // error and corrected a second time.
    @Test func aVerifyThatComesBackCleanEndsTheGuess() {
        var policy = DriftCorrectionPolicy()
        _ = policy.decide([observation("a", 25, guess: true),
                           observation("b", 30, guess: true)], programIsSilent: false)
        let verify = policy.decide([observation("a", 1, t: 1), observation("b", 2, t: 1)],
                                   programIsSilent: false)
        #expect(verify == [.ignore(deviceUID: "a", reason: .corrected),
                           .ignore(deviceUID: "b", reason: .corrected)])
        #expect(policy.isAwaitingConfirmation("a") == false)
    }

    // Turns red if a verify window whose errors persist is treated as ordinary
    // drift instead of a wrong attribution to swap.
    @Test func aVerifyThatStillShowsErrorSwapsAndRecorrects() {
        var policy = DriftCorrectionPolicy()
        _ = policy.decide([observation("a", 25, guess: true),
                           observation("b", 30, guess: true)], programIsSilent: false)
        let verify = policy.decide([observation("a", -30, t: 1), observation("b", -25, t: 1)],
                                   programIsSilent: true)
        #expect(verify == [.swapAndRecorrect([
            .init(deviceUID: "a", ms: -30, placement: .inGap, notify: false),
            .init(deviceUID: "b", ms: -25, placement: .inGap, notify: false)])])
    }

    // Turns red if a swap re-corrects a group member the verify found aligned,
    // which would move a clean speaker by a sub-threshold amount and re-open a
    // device the same window already reported as corrected.
    @Test func aSwapOnlyRecorrectsTheMembersStillOffByEnough() {
        var policy = DriftCorrectionPolicy()
        _ = policy.decide([observation("a", 25, guess: true),
                           observation("b", 30, guess: true),
                           observation("c", 28, guess: true)], programIsSilent: false)
        // c came back clean, so the swap leaves it alone and it resolves as a
        // correction that landed; a and b are still off and are re-corrected.
        let verify = policy.decide([observation("b", -30, t: 1), observation("c", 5, t: 1),
                                    observation("a", 20, t: 1)], programIsSilent: true)
        #expect(verify == [.swapAndRecorrect([
                               .init(deviceUID: "b", ms: -30,
                                     placement: .inGap, notify: false),
                               .init(deviceUID: "a", ms: 20,
                                     placement: .inGap, notify: false)]),
                           .ignore(deviceUID: "c", reason: .corrected)])
        #expect(policy.isAwaitingConfirmation("c") == false)
        #expect(policy.isAwaitingConfirmation("b"))
    }

    // Turns red if a swap re-correction is still marked a guess, which would
    // let the pair swap back and forth forever.
    @Test func aSwappedRecorrectionIsNoLongerAGuess() {
        var policy = DriftCorrectionPolicy()
        _ = policy.decide([observation("a", 25, guess: true),
                           observation("b", 30, guess: true)], programIsSilent: false)
        _ = policy.decide([observation("a", -30, t: 1), observation("b", -25, t: 1)],
                          programIsSilent: false)
        let third = policy.decide([observation("a", 20, t: 2), observation("b", 20, t: 2)],
                                  programIsSilent: false)
        #expect(!third.contains { if case .swapAndRecorrect = $0 { return true }; return false })
    }

    private func corrections(_ actions: [DriftCorrectionPolicy.Action], for uid: String)
        -> [DriftCorrectionPolicy.Correction] {
        actions.flatMap { action -> [DriftCorrectionPolicy.Correction] in
            switch action {
            case .correct(let move): return [move]
            case .swapAndRecorrect(let moves): return moves
            case .ignore, .scheduleVerify: return []
            }
        }.filter { $0.deviceUID == uid }
    }

    // Turns red if a device that re-corrected alone in an earlier window can be
    // moved a second time in one window by another device's stale guessed
    // group, which doubles its trim against a single measured error.
    @Test func aStaleGroupCannotMoveADeviceThatAlreadyActedThisWindow() {
        var policy = DriftCorrectionPolicy()
        _ = policy.decide([observation("a", 25, guess: true),
                           observation("b", 30, guess: true)], programIsSilent: true)
        // Only b's peak was usable this window, so b re-corrects alone while
        // a's outstanding entry still names the pair.
        _ = policy.decide([observation("b", -30, t: 1)], programIsSilent: true)
        let third = policy.decide([observation("b", 20, t: 2), observation("a", 15, t: 2)],
                                  programIsSilent: true)
        #expect(corrections(third, for: "b") == [.init(deviceUID: "b", ms: 20,
                                                       placement: .inGap, notify: false)])
        #expect(corrections(third, for: "a") == [.init(deviceUID: "a", ms: 15,
                                                       placement: .inGap, notify: false)])
    }

    // Turns red if the same double correction appears when the stale group's
    // owner is observed first — the guarantee is one move per device per
    // window whatever the observation order.
    @Test func theOneMovePerWindowRuleHoldsInEitherObservationOrder() {
        var policy = DriftCorrectionPolicy()
        _ = policy.decide([observation("a", 25, guess: true),
                           observation("b", 30, guess: true)], programIsSilent: true)
        _ = policy.decide([observation("b", -30, t: 1)], programIsSilent: true)
        let third = policy.decide([observation("a", 15, t: 2), observation("b", 20, t: 2)],
                                  programIsSilent: true)
        #expect(corrections(third, for: "b") == [.init(deviceUID: "b", ms: 20,
                                                       placement: .inGap, notify: false)])
        #expect(corrections(third, for: "a") == [.init(deviceUID: "a", ms: 15,
                                                       placement: .inGap, notify: false)])
    }

    // Turns red if a guessed group that has shrunk to its own device still
    // reports a swap: the move is right either way, but the field log counts
    // swaps as wrong attributions, and this one is ordinary drift.
    @Test func aGroupLeftHoldingOnlyItsOwnDeviceRecorrectsAsOrdinaryDrift() {
        var policy = DriftCorrectionPolicy()
        _ = policy.decide([observation("a", 25, guess: true),
                           observation("b", 30, guess: true)], programIsSilent: true)
        // b's correction landed, so b leaves a's group and a's guess has
        // nobody left to swap with.
        _ = policy.decide([observation("b", 2, t: 1)], programIsSilent: true)
        let third = policy.decide([observation("a", 20, t: 2)], programIsSilent: true)
        #expect(third == [.correct(.init(deviceUID: "a", ms: 20,
                                         placement: .inGap, notify: false))])
    }

    // Turns red if a lone contended device stores itself as its own guessed
    // group, which is the same mislabel reached from the other direction.
    @Test func aLoneGuessStoresNoGroupToSwapWith() {
        var policy = DriftCorrectionPolicy()
        let first = policy.decide([observation("a", 25, guess: true)], programIsSilent: true)
        #expect(first.contains(.scheduleVerify(deviceUIDs: ["a"])))
        let verify = policy.decide([observation("a", 20, t: 1)], programIsSilent: true)
        #expect(verify == [.correct(.init(deviceUID: "a", ms: 20,
                                          placement: .inGap, notify: false))])
    }

    // Turns red if a device can be corrected twice in one window, before the
    // first correction has had a window to prove it landed.
    @Test func aSecondCorrectionWaitsForTheFirstToBeConfirmed() {
        var policy = DriftCorrectionPolicy()
        let actions = policy.decide([observation("a", 20), observation("a", 35)],
                                    programIsSilent: false)
        #expect(actions.count == 2)
        #expect(correction(actions)?.ms == 20)
        #expect(actions.last == .ignore(deviceUID: "a", reason: .correctionOutstanding))
        #expect(policy.isAwaitingConfirmation("a"))
    }
}
