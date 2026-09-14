// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Who owns each speaker's calibration right now, and which request it is.
///
/// The executable used to keep one `[String: UUID]` of "which phone asked",
/// shared by the probe, the by-ear metronome, the A/B receipt and the
/// audition. Nothing in it said which KIND of work the entry was for or which
/// request made it, so any of them could erase any other: one refused legacy
/// request orphaned a live audition, and a reply from a request that had long
/// since been replaced could stop its successor.
///
/// Every rule here is therefore per target AND per kind AND per request id. A
/// late callback may answer its own request; it can never erase or stop the
/// one that followed it.
///
/// Public because `AudioutApp` is a separate executable target, and
/// `@MainActor` because the executable touches it only inside its command and
/// disconnect main hops. The backend operations it needs are passed in as
/// closures, so the tests drive the same path `AppDelegate` does rather than a
/// copy of its decisions.
@MainActor public final class CompanionAlignmentOwnership {

    /// What the owner is doing. The three legacy kinds and the audition are
    /// mutually exclusive on one target: a speaker is being calibrated one way
    /// at a time.
    public enum Kind: Sendable, Equatable {
        case probe
        case legacyTick
        case demo
        case audition
    }

    public struct Entry: Sendable, Equatable {
        public let clientID: UUID
        public let kind: Kind
        public let requestID: UUID
        public let referenceID: String?
        /// The lease the ORIGINAL claim set. Repeated starts return this entry
        /// unchanged, so a phone cannot renew its lease by asking again.
        public let leaseDeadline: Date?
        /// Set once the backend has been asked to stand this audition down.
        /// Ownership is kept until the backend says the reservation is gone.
        public var cleanupRequested: Bool

        public init(clientID: UUID, kind: Kind, requestID: UUID,
                    referenceID: String?, leaseDeadline: Date?,
                    cleanupRequested: Bool = false) {
            self.clientID = clientID
            self.kind = kind
            self.requestID = requestID
            self.referenceID = referenceID
            self.leaseDeadline = leaseDeadline
            self.cleanupRequested = cleanupRequested
        }
    }

    public enum Claim: Sendable {
        /// A new entry, with a request id allocated for it.
        case fresh(Entry)
        /// The same client asking again for the same work: the existing entry,
        /// request id and lease, untouched.
        case existing(Entry)
        case refused(String)
    }

    private var entries: [String: Entry] = [:]
    /// Which A/B receipt run a target is on. A receipt ends on the backend's
    /// own four-second clock and reports nothing, so the executable schedules
    /// the release itself — and a second receipt started inside that window is
    /// a NEW run whose speakers are still held when the first release is due.
    private var demoRuns: [String: Int] = [:]

    public init() {}

    public func claim(targetID: String, clientID: UUID, kind: Kind,
                      referenceID: String?, leaseDeadline: Date?) -> Claim {
        if let current = entries[targetID] {
            guard current.clientID == clientID else {
                return .refused("Another phone is using these speaker clicks.")
            }
            guard current.kind == kind else {
                return .refused("This Mac is already measuring a speaker. Finish that first.")
            }
            // An audition is identified by its PAIR as well as its target: a
            // start naming a different reference is a different job.
            if kind == .audition, current.referenceID != referenceID {
                return .refused("This Mac is already measuring a speaker. Finish that first.")
            }
            return .existing(current)
        }
        let entry = Entry(clientID: clientID, kind: kind, requestID: UUID(),
                          referenceID: referenceID, leaseDeadline: leaseDeadline)
        entries[targetID] = entry
        return .fresh(entry)
    }

    public func current(targetID: String) -> Entry? { entries[targetID] }

    /// Retire an entry, but only the exact one named. This is what the
    /// audition's own release signal calls, and it is the only ordinary way an
    /// audition owner goes away.
    @discardableResult
    public func release(targetID: String, kind: Kind, requestID: UUID) -> Bool {
        guard let current = entries[targetID], current.kind == kind,
              current.requestID == requestID else { return false }
        entries.removeValue(forKey: targetID)
        return true
    }

    /// Give back a claim whose work the backend then refused.
    ///
    /// ONLY a claim that was just created. A repeat request returns the live
    /// run's own entry and token, so releasing on it erases a run that is
    /// still going — and the phone stops getting that run's events, because
    /// they are addressed to whoever owns the target.
    @discardableResult
    public func releaseFresh(_ claim: Claim, targetID: String) -> Bool {
        guard case .fresh(let entry) = claim else { return false }
        return release(targetID: targetID, kind: entry.kind, requestID: entry.requestID)
    }

    /// Note that an A/B receipt has started (or restarted) on `targetID`, and
    /// return the run to quote when scheduling its release.
    @discardableResult
    public func noteDemoStarted(targetID: String) -> Int {
        let run = (demoRuns[targetID] ?? 0) + 1
        demoRuns[targetID] = run
        return run
    }

    /// Retire a receipt's owner once its own four seconds are up — but only if
    /// no later receipt has started since, and only for the matching token.
    @discardableResult
    public func releaseDemoRun(targetID: String, requestID: UUID, run: Int) -> Bool {
        guard demoRuns[targetID] == run else { return false }
        guard release(targetID: targetID, kind: .demo, requestID: requestID) else { return false }
        demoRuns.removeValue(forKey: targetID)
        return true
    }

    /// Retire an entry on its own owner's instruction — the phone's Cancel.
    ///
    /// A client that does not own the target changes nothing and is told so,
    /// which is what stops one phone's cancel erasing another phone's run and
    /// disarming the disconnect that would have cleaned it up. An audition is
    /// never retired this way: its stop command is the only thing that ends it.
    @discardableResult
    public func releaseOwned(targetID: String, clientID: UUID) -> Entry? {
        guard let current = entries[targetID], current.clientID == clientID,
              current.kind != .audition else { return nil }
        entries.removeValue(forKey: targetID)
        demoRuns.removeValue(forKey: targetID)
        return current
    }

    /// Take the probe owner for a measurement report and return the phone to
    /// address the result to. Leaves any other kind — an audition especially —
    /// exactly where it is.
    public func takeProbeForReport(targetID: String) -> UUID? {
        guard let current = entries[targetID], current.kind == .probe else { return nil }
        entries.removeValue(forKey: targetID)
        return current.clientID
    }

    /// The phone asked to stop its own audition. Records that cleanup is
    /// wanted and hands back the token to call the backend with — the
    /// executable always makes that call, so a repeated stop joins the same
    /// cleanup and gets its own one-shot reply. Ownership is NOT released
    /// here: the reservation is still held while the room is put back.
    public func markExplicitAuditionStop(targetID: String, clientID: UUID) -> UUID? {
        guard var current = entries[targetID], current.kind == .audition,
              current.clientID == clientID else { return nil }
        current.cleanupRequested = true
        entries[targetID] = current
        return current.requestID
    }

    /// Stand an audition down on this Mac's own initiative — a lease that ran
    /// out, or a pair that changed. Returns whether THIS call started the
    /// backend cleanup; a token that does not match the current owner starts
    /// nothing, so a timer armed by an old request cannot end its successor.
    @discardableResult
    public func requestAuditionCleanup(targetID: String, requestID: UUID,
                                       stop: @MainActor (String) -> Void) -> Bool {
        guard var current = entries[targetID], current.kind == .audition,
              current.requestID == requestID, !current.cleanupRequested else { return false }
        current.cleanupRequested = true
        entries[targetID] = current
        stop(targetID)
        return true
    }

    /// A phone went away. Its audition is stood down immediately but still
    /// OWNED while the cleanup drains, so nothing else may start in that
    /// window; its legacy work is cancelled and released outright, which is
    /// what those paths have always meant.
    public func disconnect(clientID: UUID,
                           stopAudition: @MainActor (String) -> Void,
                           cancelLegacy: @MainActor (String) -> Void) {
        for (targetID, entry) in entries where entry.clientID == clientID {
            if entry.kind == .audition {
                requestAuditionCleanup(targetID: targetID, requestID: entry.requestID,
                                       stop: stopAudition)
            } else {
                entries.removeValue(forKey: targetID)
                cancelLegacy(targetID)
            }
        }
    }

    /// The original lease ran out. Token-checked like every other callback, so
    /// a lease timer from a replaced request ends nothing.
    public func expireAudition(targetID: String, requestID: UUID,
                               stopAudition: @MainActor (String) -> Void) {
        requestAuditionCleanup(targetID: targetID, requestID: requestID, stop: stopAudition)
    }
}
