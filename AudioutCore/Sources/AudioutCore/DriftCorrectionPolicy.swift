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
///   reads that window as the verify.
public struct DriftCorrectionPolicy: Sendable {

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
        /// count the earlier attribution as wrong.
        case swapAndRecorrect([Correction])
    }

    /// Under this the error is inaudible in music and is left alone.
    /// razor: one fixed pair of lines for every speaker, the starting values
    /// from spec decision 6. The upgrade path is per-device lines tuned from
    /// the field log (ticket 06).
    public static let ignoreBelowMs = 10.0
    /// At or above this the correction is also surfaced to the user.
    public static let surfaceAtOrAboveMs = 40.0

    private struct Outstanding {
        var correctionMs: Double
        var placement: Placement
        /// Non-nil when the correction came from a guessed match: the devices
        /// the guess ranged over.
        var guessedGroup: [String]?
    }

    private var outstanding: [String: Outstanding] = [:]

    public init() {}

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

        for observation in observations {
            let uid = observation.deviceUID
            if swappedThisWindow.contains(uid) { continue }
            if actedThisWindow.contains(uid) {
                actions.append(.ignore(deviceUID: uid, reason: .correctionOutstanding))
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
                    actions.append(.swapAndRecorrect(corrections))
                    continue
                }
                // An unambiguous correction that did not take: correct it
                // again, through the ordinary path below.
            }

            guard abs(observation.errorMs) >= Self.ignoreBelowMs else {
                actions.append(.ignore(deviceUID: uid, reason: .belowThreshold))
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
        for uid in guessedThisWindow {
            outstanding[uid]?.guessedGroup = guessedThisWindow
        }
        actions.append(.scheduleVerify(deviceUIDs: guessedThisWindow))
        return actions
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
    /// guess and its pending correction is re-tried the ordinary way.
    private mutating func dropFromStoredGroups(_ uid: String) {
        for (other, entry) in outstanding where other != uid {
            guard var group = entry.guessedGroup, group.contains(uid) else { continue }
            group.removeAll { $0 == uid }
            outstanding[other]?.guessedGroup = group.isEmpty ? nil : group
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
