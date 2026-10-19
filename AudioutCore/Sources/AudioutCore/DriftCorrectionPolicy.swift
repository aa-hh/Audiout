// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What to do about a Bluetooth speaker whose measured delay has moved.
///
/// The passive drift sampler measures each speaker's delay error from the mic
/// and hands the usable measurements here; this decides whether to act, how
/// big the move may be at once, and when a guessed match has to be checked
/// before it is trusted. Pure: no engine, no clock, no queue — time arrives as
/// nanoseconds on each observation, so every rule is assertable.
///
/// Caller contract:
/// - Call `decide(_:programIsSilent:)` once per sampling window with every
///   usable observation from that window. Confidence is judged upstream; an
///   observation that reaches here is trusted.
/// - Apply the returned actions in order. A `.correct` placed `.inGap` is one
///   immediate move of the per-device trim; `.slew` is the same move spread
///   over small repeated steps slow enough to stay inaudible.
/// - When the program falls silent part-way through a slew, call
///   `programBecameSilent(appliedSoFarMs:)` with how much of each slew has
///   landed; the remainder comes back as an immediate in-gap move.
/// - `.scheduleVerify` means those devices' attribution was a guess: keep
///   sampling them and feed the next window straight back in. This policy
///   reads that window as the verify. Under ``VerifyMode/verifyBeforeApply``
///   no correction for those devices has been returned yet, and the agreeing
///   window is what releases it.
public struct DriftCorrectionPolicy: Sendable {

    /// When a guessed attribution reaches the speaker (spec decision 17).
    public enum VerifyMode: Equatable, Sendable {
        /// Nothing moves until a second window agrees with the guess to
        /// within ``verifyAgreesWithinMs``. The wait is one sampling window,
        /// and a wrong guess never reaches the speaker at all.
        case verifyBeforeApply
        /// The likeliest assignment is applied at once and the next window
        /// checks it. One window quicker to react, at the cost of a wrong
        /// move being live and stored until that window arrives.
        case applyThenVerify
    }

    /// One usable measurement of one speaker's delay error.
    public struct Observation: Equatable, Sendable {
        public let deviceUID: String
        /// Signed delay error in milliseconds against the calibrated baseline.
        public let errorMs: Double
        public let hostNanos: Int64
        /// False when exactly one peak moved and the match is unambiguous;
        /// true when several moved and this assignment is the likeliest of
        /// the possibilities (spec decision 7).
        public let isBestGuess: Bool

        public init(deviceUID: String, errorMs: Double, hostNanos: Int64, isBestGuess: Bool) {
            self.deviceUID = deviceUID
            self.errorMs = errorMs
            self.hostNanos = hostNanos
            self.isBestGuess = isBestGuess
        }
    }

    /// When a correction may be made without being heard.
    public enum Placement: Equatable, Sendable {
        /// The program is silent: move the whole way at once.
        case inGap
        /// Music is playing: spread the move over small repeated steps.
        case slew
    }

    public struct Correction: Equatable, Sendable {
        public let deviceUID: String
        /// Signed milliseconds to move this device's trim by.
        public let ms: Double
        public let placement: Placement
        /// The error was large enough to tell the user about (decision 6).
        public let notify: Bool
    }

    /// Why an observation produced no correction. Carried so the caller can
    /// log the cases apart; all of them mean "do nothing to this device".
    public enum IgnoreReason: Equatable, Sendable {
        /// Below the echo-perception line for music.
        case belowThreshold
        /// A correction for this device is still unconfirmed.
        case correctionOutstanding
        /// This measurement confirmed that an earlier correction landed.
        case corrected
    }

    public enum Action: Equatable, Sendable {
        case ignore(deviceUID: String, reason: IgnoreReason)
        case correct(Correction)
        /// These devices were matched by guess: sample them again and hand the
        /// next window back to `decide`.
        case scheduleVerify(deviceUIDs: [String])
        /// The verify contradicted the guess. Apply these corrections and
        /// count the earlier attribution as wrong. Never carries fewer than
        /// two devices: one device moving alone reattributed nothing and
        /// comes back as `.correct`.
        case swapAndRecorrect([Correction])
    }

    /// Under this the error is inaudible in music and is left alone.
    /// razor: one fixed pair of lines for every speaker, the starting values
    /// from spec decision 6. The upgrade path is per-device lines tuned from
    /// the field log (ticket 06).
    public static let ignoreBelowMs = 10.0
    /// At or above this the correction is also surfaced to the user.
    public static let surfaceAtOrAboveMs = 40.0
    /// Two windows agree about a guessed device when their measured errors sit
    /// this close together. Well past the whole-millisecond quantum a stored
    /// latency rounds to, well short of the 10 ms line that makes an error
    /// worth acting on at all.
    /// razor: one fixed line for every speaker. The upgrade path is a
    /// tolerance that follows the window's own confidence (ticket 10).
    public static let verifyAgreesWithinMs = 1.5

    private struct Outstanding {
        var correctionMs: Double
        var placement: Placement
        /// Non-nil when the correction came from a guessed match: the devices
        /// the guess ranged over.
        var guessedGroup: [String]?
    }

    /// A guessed correction nothing has been done about yet. It is applied
    /// only once a second window agrees with it.
    private struct Held {
        var errorMs: Double
        /// The devices the guess ranged over, this one included.
        var group: [String]
    }

    private let verifyMode: VerifyMode
    private var outstanding: [String: Outstanding] = [:]
    private var held: [String: Held] = [:]

    public init(verifyMode: VerifyMode = .verifyBeforeApply) {
        self.verifyMode = verifyMode
    }

    /// Whether a correction for this device is still waiting for a later
    /// window to confirm it.
    public func isAwaitingConfirmation(_ deviceUID: String) -> Bool {
        outstanding[deviceUID] != nil
    }

    /// One sampling window's worth of usable observations.
    public mutating func decide(_ observations: [Observation],
                                programIsSilent: Bool) -> [Action] {
        var actions: [Action] = []
        var guessedThisWindow: [String] = []
        /// Every device this window has already emitted a correction for, or
        /// resolved, whatever kind of action carried it. One device gets at
        /// most one move per window, in any observation order.
        var actedThisWindow: Set<String> = []
        /// Devices a swap action in this window already covers. Their own
        /// observations say nothing new, so they produce no second action.
        var swappedThisWindow: Set<String> = []
        let reattributed = reattributedDevices(observations)

        for observation in observations {
            let uid = observation.deviceUID
            if swappedThisWindow.contains(uid) { continue }
            if actedThisWindow.contains(uid) {
                actions.append(.ignore(deviceUID: uid, reason: .correctionOutstanding))
                continue
            }
            if let pending = held[uid] {
                held[uid] = nil
                guard abs(observation.errorMs) >= Self.ignoreBelowMs else {
                    // The error went away before anything was moved, so there
                    // is nothing to apply and nothing to have got wrong.
                    actions.append(.ignore(deviceUID: uid, reason: .belowThreshold))
                    continue
                }
                if reattributed.contains(uid) {
                    // This window read the device onto another member's peak,
                    // so the first attribution was the wrong way round. The
                    // fresh errors are what to move by, and they are no longer
                    // guesses: a further miss is ordinary drift.
                    let corrections = observations
                        .filter { reattributed.contains($0.deviceUID) }
                        .filter { !actedThisWindow.contains($0.deviceUID) }
                        .map { correction(for: $0, programIsSilent: programIsSilent) }
                    for correction in corrections {
                        held[correction.deviceUID] = nil
                        outstanding[correction.deviceUID] = Outstanding(
                            correctionMs: correction.ms,
                            placement: correction.placement,
                            guessedGroup: nil)
                        swappedThisWindow.insert(correction.deviceUID)
                        actedThisWindow.insert(correction.deviceUID)
                    }
                    actions.append(contentsOf: moveActions(corrections))
                    continue
                }
                if abs(observation.errorMs - pending.errorMs) <= Self.verifyAgreesWithinMs {
                    // Two windows agree about a device nothing has moved:
                    // the guess is good and the move is released.
                    let move = correction(for: observation, programIsSilent: programIsSilent)
                    outstanding[uid] = Outstanding(correctionMs: move.ms,
                                                   placement: move.placement,
                                                   guessedGroup: nil)
                    actions.append(.correct(move))
                    actedThisWindow.insert(uid)
                    continue
                }
                // The two windows disagree and neither reading belongs to a
                // neighbour, so this one is a guess in its turn and waits for
                // a verify of its own. Still nothing has moved.
                held[uid] = Held(errorMs: observation.errorMs, group: [uid])
                guessedThisWindow.append(uid)
                continue
            }
            if let pending = outstanding[uid] {
                outstanding[uid] = nil
                if abs(observation.errorMs) < Self.ignoreBelowMs {
                    actions.append(.ignore(deviceUID: uid, reason: .corrected))
                    actedThisWindow.insert(uid)
                    dropFromStoredGroups(uid)
                    continue
                }
                if let group = pending.guessedGroup {
                    // The guess was wrong. Whichever peak was whose, the
                    // residual each device still shows is the move it needs,
                    // so the fresh errors are the re-correction. It is no
                    // longer a guess: a further miss is ordinary drift.
                    // Only members still off by at least the ignore line are
                    // moved; a member the verify found clean is already
                    // aligned and resolves as confirmed in its own iteration.
                    // A member this window has already acted on is left out
                    // too: its move is applied once, not once more here.
                    let corrections = observations
                        .filter { group.contains($0.deviceUID) }
                        .filter { !actedThisWindow.contains($0.deviceUID) }
                        .filter { abs($0.errorMs) >= Self.ignoreBelowMs }
                        .map { correction(for: $0, programIsSilent: programIsSilent) }
                    for correction in corrections {
                        outstanding[correction.deviceUID] = Outstanding(
                            correctionMs: correction.ms,
                            placement: correction.placement,
                            guessedGroup: nil)
                        swappedThisWindow.insert(correction.deviceUID)
                        actedThisWindow.insert(correction.deviceUID)
                        dropFromStoredGroups(correction.deviceUID)
                    }
                    actions.append(contentsOf: moveActions(corrections))
                    continue
                }
                // An unambiguous correction that did not take: correct it
                // again, through the ordinary path below.
            }

            guard abs(observation.errorMs) >= Self.ignoreBelowMs else {
                actions.append(.ignore(deviceUID: uid, reason: .belowThreshold))
                continue
            }
            if verifyMode == .verifyBeforeApply, observation.isBestGuess {
                // Spec decision 17: a guessed match moves nothing until a
                // second window agrees with it.
                held[uid] = Held(errorMs: observation.errorMs, group: [uid])
                guessedThisWindow.append(uid)
                continue
            }
            let move = correction(for: observation, programIsSilent: programIsSilent)
            outstanding[uid] = Outstanding(correctionMs: move.ms,
                                           placement: move.placement,
                                           guessedGroup: nil)
            actions.append(.correct(move))
            actedThisWindow.insert(uid)
            dropFromStoredGroups(uid)
            if observation.isBestGuess { guessedThisWindow.append(uid) }
        }

        guard !guessedThisWindow.isEmpty else { return actions }
        // A group of one is the device itself, which it cannot swap with, so
        // it is stored as no group at all: the verify still runs, and a verify
        // that disagrees re-corrects as ordinary drift rather than reporting a
        // swap nobody made.
        for uid in guessedThisWindow where guessedThisWindow.count > 1 {
            outstanding[uid]?.guessedGroup = guessedThisWindow
            held[uid]?.group = guessedThisWindow
        }
        actions.append(.scheduleVerify(deviceUIDs: guessedThisWindow))
        return actions
    }

    /// Held devices whose fresh reading matches ANOTHER member of their
    /// guessed group rather than their own held reading: the peaks were
    /// attributed the wrong way round, and this window says which way round
    /// they really go.
    private func reattributedDevices(_ observations: [Observation]) -> Set<String> {
        guard !held.isEmpty else { return [] }
        var swapped: Set<String> = []
        for observation in observations {
            guard let own = held[observation.deviceUID],
                  abs(observation.errorMs - own.errorMs) > Self.verifyAgreesWithinMs
            else { continue }
            for member in own.group where member != observation.deviceUID {
                guard let other = held[member],
                      abs(observation.errorMs - other.errorMs) <= Self.verifyAgreesWithinMs
                else { continue }
                swapped.insert(observation.deviceUID)
                break
            }
        }
        return swapped
    }

    /// How a batch of re-corrections is reported. Only a batch that moves more
    /// than one device reattributed anything; a lone move is ordinary drift,
    /// and the field log counts a swap as a wrong attribution.
    private func moveActions(_ corrections: [Correction]) -> [Action] {
        switch corrections.count {
        case 0: return []
        case 1: return [.correct(corrections[0])]
        default: return [.swapAndRecorrect(corrections)]
        }
    }

    /// The program fell silent while slews were still running.
    /// `appliedSoFarMs` is the signed amount of each slew the caller has
    /// already put in; the rest comes back as one immediate in-gap move.
    public mutating func programBecameSilent(appliedSoFarMs: [String: Double]) -> [Action] {
        var actions: [Action] = []
        for uid in outstanding.keys.sorted() {
            guard let pending = outstanding[uid], pending.placement == .slew else { continue }
            outstanding[uid]?.placement = .inGap
            let remaining = pending.correctionMs - (appliedSoFarMs[uid] ?? 0)
            guard remaining != 0 else { continue }
            // The user was told when the slew started, if it was big enough
            // to be worth telling them.
            actions.append(.correct(Correction(deviceUID: uid, ms: remaining,
                                               placement: .inGap, notify: false)))
        }
        return actions
    }

    /// A device that has just resolved or been corrected on its own can no
    /// longer be moved as part of an older guess, so it leaves every other
    /// device's stored group. A group left with nothing to swap stops being a
    /// guess and its pending correction is re-tried the ordinary way — and a
    /// group holding only its own device is exactly that case, because a
    /// device cannot be swapped with itself.
    private mutating func dropFromStoredGroups(_ uid: String) {
        for (other, entry) in outstanding where other != uid {
            guard var group = entry.guessedGroup, group.contains(uid) else { continue }
            group.removeAll { $0 == uid }
            let swappable = group.contains { $0 != other }
            outstanding[other]?.guessedGroup = swappable ? group : nil
        }
    }

    private func correction(for observation: Observation,
                            programIsSilent: Bool) -> Correction {
        Correction(deviceUID: observation.deviceUID,
                   ms: observation.errorMs,
                   placement: programIsSilent ? .inGap : .slew,
                   notify: abs(observation.errorMs) >= Self.surfaceAtOrAboveMs)
    }
}
