// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// Two phones, injected backend stop completions, and old callback tokens
/// driven through the production owner. Every case names the erasure it
/// prevents: before this type the executable kept one "which phone asked" map
/// with no kind and no request id in it, so any refused legacy request could
/// orphan a live audition and any replaced reply could stop its successor.
@Suite @MainActor struct CompanionAlignmentOwnershipTests {

    private let phoneA = UUID()
    private let phoneB = UUID()
    private let target = "C4-38-75-0E-BF-4A:output"
    private let reference = "70-99-1C-51-8F-A8:output"

    /// Records which targets a closure was asked to act on, in order.
    private final class Calls {
        var targets: [String] = []
        var stop: @MainActor (String) -> Void { { self.targets.append($0) } }
    }

    private func claimedAudition(
        _ owner: CompanionAlignmentOwnership, client: UUID? = nil,
        lease: Date = Date().addingTimeInterval(600)
    ) -> CompanionAlignmentOwnership.Entry {
        let claim = owner.claim(targetID: target, clientID: client ?? phoneA, kind: .audition,
                                referenceID: reference, leaseDeadline: lease)
        guard case .fresh(let entry) = claim else {
            Issue.record("expected a fresh audition claim, got \(claim)")
            return CompanionAlignmentOwnership.Entry(
                clientID: phoneA, kind: .audition, requestID: UUID(),
                referenceID: reference, leaseDeadline: lease)
        }
        return entry
    }

    /// Another phone's refused probe used to remove the target's entry
    /// outright, leaving a live audition with no owner at all.
    @Test func anotherPhonesRefusedProbeLeavesTheAuditionOwner() {
        let owner = CompanionAlignmentOwnership()
        let audition = claimedAudition(owner)

        let probe = owner.claim(targetID: target, clientID: phoneB, kind: .probe,
                                referenceID: reference, leaseDeadline: nil)
        guard case .refused = probe else { Issue.record("a second phone must be refused"); return }
        #expect(owner.current(targetID: target) == audition)

        // The same phone asking for a DIFFERENT kind is refused too, and
        // equally leaves the audition standing.
        for kind in [CompanionAlignmentOwnership.Kind.probe, .legacyTick, .demo] {
            let sameClient = owner.claim(targetID: target, clientID: phoneA, kind: kind,
                                         referenceID: nil, leaseDeadline: nil)
            guard case .refused = sameClient else {
                Issue.record("\(kind) must be refused while an audition owns the target"); return
            }
            #expect(owner.current(targetID: target) == audition)
        }
    }

    /// A legacy report, cancel or release must not take an audition owner with
    /// it — each is token- and kind-checked.
    @Test func legacyCallbacksCannotEraseAnAudition() {
        let owner = CompanionAlignmentOwnership()
        let audition = claimedAudition(owner)

        #expect(owner.takeProbeForReport(targetID: target) == nil,
                "a measurement report finds no probe owner here")
        #expect(owner.release(targetID: target, kind: .probe, requestID: audition.requestID) == false)
        #expect(owner.release(targetID: target, kind: .demo, requestID: audition.requestID) == false)
        #expect(owner.release(targetID: target, kind: .legacyTick, requestID: audition.requestID) == false)
        #expect(owner.release(targetID: target, kind: .audition, requestID: UUID()) == false,
                "a stale audition token releases nothing either")
        #expect(owner.current(targetID: target) == audition)

        #expect(owner.release(targetID: target, kind: .audition, requestID: audition.requestID) == true,
                "only the matching kind and token retire the owner")
        #expect(owner.current(targetID: target) == nil)
    }

    /// Giving a claim back because the backend refused the work must give back
    /// only a claim that was JUST created. A repeat request returns the live
    /// run's own token, so releasing on it erases the run that is still going —
    /// and the phone then stops getting that run's events.
    @Test func onlyAFreshClaimIsGivenBackWhenTheBackendRefuses() {
        for kind in [CompanionAlignmentOwnership.Kind.probe, .legacyTick, .demo] {
            let owner = CompanionAlignmentOwnership()
            let first = owner.claim(targetID: target, clientID: phoneA, kind: kind,
                                    referenceID: nil, leaseDeadline: nil)
            guard case .fresh(let live) = first else { Issue.record("expected fresh"); return }

            // The same phone asks again; the backend refuses because the first
            // run is still going, and the executable gives the claim back.
            let repeated = owner.claim(targetID: target, clientID: phoneA, kind: kind,
                                       referenceID: nil, leaseDeadline: nil)
            #expect(owner.releaseFresh(repeated, targetID: target) == false,
                    "a joined claim owns nothing to give back")
            #expect(owner.current(targetID: target)?.requestID == live.requestID,
                    "\(kind): the live run keeps its owner, so its events still reach the phone")

            // A genuinely new claim that the backend refuses IS given back.
            #expect(owner.releaseFresh(first, targetID: target) == true)
            #expect(owner.current(targetID: target) == nil)
        }
    }

    /// A repeat A/B receipt is a new four-second run. The release scheduled by
    /// the FIRST one must not hand ownership back while the second is still
    /// holding the speakers silent.
    @Test func aRepeatedReceiptHoldsOwnershipUntilItsOwnRunEnds() {
        let owner = CompanionAlignmentOwnership()
        let claim = owner.claim(targetID: target, clientID: phoneA, kind: .demo,
                                referenceID: nil, leaseDeadline: nil)
        guard case .fresh(let entry) = claim else { Issue.record("expected fresh"); return }
        let firstRun = owner.noteDemoStarted(targetID: target)

        // A second receipt starts before the first one's release is due.
        let secondRun = owner.noteDemoStarted(targetID: target)
        #expect(secondRun != firstRun)

        #expect(owner.releaseDemoRun(targetID: target, requestID: entry.requestID,
                                     run: firstRun) == false,
                "the first receipt's release cannot end the second one's run")
        #expect(owner.current(targetID: target)?.requestID == entry.requestID)

        #expect(owner.releaseDemoRun(targetID: target, requestID: entry.requestID,
                                     run: secondRun) == true)
        #expect(owner.current(targetID: target) == nil)

        // And a stale token releases nothing, whatever the run.
        let later = owner.claim(targetID: target, clientID: phoneB, kind: .audition,
                                referenceID: reference, leaseDeadline: nil)
        guard case .fresh(let audition) = later else { Issue.record("expected fresh"); return }
        let run = owner.noteDemoStarted(targetID: target)
        #expect(owner.releaseDemoRun(targetID: target, requestID: entry.requestID,
                                     run: run) == false)
        #expect(owner.current(targetID: target)?.requestID == audition.requestID)
    }

    /// A phone that reopens the sheet on the same pair must not get a fresh
    /// lease — that is how a ten-minute budget becomes unbounded.
    @Test func aRepeatedSamePairStartKeepsTheOwnerAndTheOriginalLease() {
        let owner = CompanionAlignmentOwnership()
        let lease = Date().addingTimeInterval(600)
        let first = claimedAudition(owner, lease: lease)

        let again = owner.claim(targetID: target, clientID: phoneA, kind: .audition,
                                referenceID: reference,
                                leaseDeadline: Date().addingTimeInterval(9_000))
        guard case .existing(let entry) = again else {
            Issue.record("a same-pair repeat must join, not claim"); return
        }
        #expect(entry.requestID == first.requestID)
        #expect(entry.leaseDeadline == lease, "repeated starts cannot renew the lease")

        // Only the first claim is fresh. The executable arms the lease timer
        // and the pair monitor off that, so reopening the sheet ten times must
        // not leave ten self-rearming monitors running for the audition's life.
        var freshCount = 1
        for _ in 0..<10 {
            if case .fresh = owner.claim(targetID: target, clientID: phoneA, kind: .audition,
                                         referenceID: reference, leaseDeadline: lease) {
                freshCount += 1
            }
        }
        #expect(freshCount == 1, "ten idempotent starts arm one monitor")

        // A different reference is a different job, and is refused rather than
        // silently adopted.
        let otherPair = owner.claim(targetID: target, clientID: phoneA, kind: .audition,
                                    referenceID: "AA-BB-CC-DD-EE-77:output", leaseDeadline: nil)
        guard case .refused = otherPair else { Issue.record("a new pair must be refused"); return }
        #expect(owner.current(targetID: target)?.requestID == first.requestID)
    }

    /// An old start completion, lease timer, pair monitor or stop completion
    /// firing against a REPLACED request must neither remove nor stop the
    /// owner that came after it.
    @Test func anOldRequestsCallbacksCannotStopASuccessor() {
        let owner = CompanionAlignmentOwnership()
        let stale = claimedAudition(owner)
        #expect(owner.release(targetID: target, kind: .audition, requestID: stale.requestID))
        let current = claimedAudition(owner, client: phoneB)

        let calls = Calls()
        owner.expireAudition(targetID: target, requestID: stale.requestID, stopAudition: calls.stop)
        #expect(owner.requestAuditionCleanup(targetID: target, requestID: stale.requestID,
                                             stop: calls.stop) == false)
        #expect(owner.release(targetID: target, kind: .audition, requestID: stale.requestID) == false)
        #expect(owner.markExplicitAuditionStop(targetID: target, clientID: phoneA) == nil,
                "the old client no longer owns this target")
        #expect(calls.targets.isEmpty, "no backend stop is issued for a replaced request")
        #expect(owner.current(targetID: target) == current)
    }

    /// Disconnecting while an audition prepares must start the backend cleanup
    /// exactly once, and must KEEP ownership until that cleanup says it is
    /// done — otherwise a new run overlaps the one still being put back.
    @Test func disconnectStopsAnAuditionOnceAndKeepsOwnershipUntilReleased() {
        let owner = CompanionAlignmentOwnership()
        let audition = claimedAudition(owner)
        let stops = Calls()
        let cancels = Calls()

        owner.disconnect(clientID: phoneA, stopAudition: stops.stop, cancelLegacy: cancels.stop)
        #expect(stops.targets == [target])
        #expect(cancels.targets.isEmpty, "an audition is not a legacy cancel")
        #expect(owner.current(targetID: target)?.cleanupRequested == true)
        #expect(owner.current(targetID: target)?.requestID == audition.requestID,
                "ownership is kept while the cleanup drains")

        // Nothing else may claim the target in that window, and no later
        // trigger issues a second stop.
        let intruder = owner.claim(targetID: target, clientID: phoneB, kind: .audition,
                                   referenceID: reference, leaseDeadline: nil)
        guard case .refused = intruder else { Issue.record("a busy owner refuses"); return }
        owner.disconnect(clientID: phoneA, stopAudition: stops.stop, cancelLegacy: cancels.stop)
        owner.expireAudition(targetID: target, requestID: audition.requestID, stopAudition: stops.stop)
        #expect(stops.targets == [target], "cleanup is asked for once")

        // The backend's own release signal is the one thing that retires it.
        #expect(owner.release(targetID: target, kind: .audition, requestID: audition.requestID))
        #expect(owner.current(targetID: target) == nil)
    }

    /// Legacy work belonging to a vanished phone IS cancelled and released —
    /// and only that phone's.
    @Test func disconnectCancelsOnlyItsOwnLegacyWork() {
        let owner = CompanionAlignmentOwnership()
        let mine = "mine"
        let theirs = "theirs"
        _ = owner.claim(targetID: mine, clientID: phoneA, kind: .legacyTick,
                        referenceID: nil, leaseDeadline: nil)
        _ = owner.claim(targetID: theirs, clientID: phoneB, kind: .demo,
                        referenceID: nil, leaseDeadline: nil)

        let stops = Calls()
        let cancels = Calls()
        owner.disconnect(clientID: phoneA, stopAudition: stops.stop, cancelLegacy: cancels.stop)
        #expect(cancels.targets == [mine])
        #expect(stops.targets.isEmpty)
        #expect(owner.current(targetID: mine) == nil)
        #expect(owner.current(targetID: theirs)?.clientID == phoneB)
    }

    /// One phone's Cancel must not end another phone's work. Erasing that
    /// owner also disarms the disconnect that would have cancelled it, so the
    /// first phone's metronome keeps running with nothing left to stop it.
    @Test func aCancelFromAnotherPhoneLeavesTheOwnerAndItsDisconnectIntact() {
        let owner = CompanionAlignmentOwnership()
        _ = owner.claim(targetID: target, clientID: phoneA, kind: .legacyTick,
                        referenceID: nil, leaseDeadline: nil)

        #expect(owner.releaseOwned(targetID: target, clientID: phoneB) == nil,
                "phone B owns nothing here, so its cancel retires nothing")
        #expect(owner.current(targetID: target)?.clientID == phoneA)

        // Phone A's disconnect must still find its work and cancel it.
        let stops = Calls()
        let cancels = Calls()
        owner.disconnect(clientID: phoneA, stopAudition: stops.stop, cancelLegacy: cancels.stop)
        #expect(cancels.targets == [target], "A's disconnect still puts the room back")
        #expect(stops.targets.isEmpty)
        #expect(owner.current(targetID: target) == nil)

        // The owner's OWN cancel does retire it, and an audition never goes
        // this way — only its stop command ends that.
        _ = owner.claim(targetID: target, clientID: phoneA, kind: .demo,
                        referenceID: nil, leaseDeadline: nil)
        #expect(owner.releaseOwned(targetID: target, clientID: phoneA)?.kind == .demo)
        #expect(owner.current(targetID: target) == nil)
        let audition = claimedAudition(owner)
        #expect(owner.releaseOwned(targetID: target, clientID: phoneA) == nil)
        #expect(owner.current(targetID: target)?.requestID == audition.requestID)
    }

    /// Switching the by-ear metronome off is the owner's exit too. One phone
    /// ending another's session leaves that phone with a sheet open over a
    /// session it no longer owns, and its nudges unwritten.
    @Test func aTickOffFromAnotherPhoneLeavesTheOwnersSession() {
        let owner = CompanionAlignmentOwnership()
        let claim = owner.claim(targetID: target, clientID: phoneA, kind: .legacyTick,
                                referenceID: nil, leaseDeadline: nil)
        guard case .fresh(let session) = claim else { Issue.record("expected fresh"); return }

        #expect(owner.releaseOwned(targetID: target, clientID: phoneB) == nil,
                "phone B's tick-off ends nothing of phone A's")
        #expect(owner.current(targetID: target)?.requestID == session.requestID)

        #expect(owner.releaseOwned(targetID: target, clientID: phoneA)?.kind == .legacyTick,
                "the owner's own tick-off retires it")
        #expect(owner.current(targetID: target) == nil)
    }

    /// The phone's own stop keeps the owner (the room is still being put back)
    /// and hands back the token every repeat stop joins.
    @Test func anExplicitStopMarksCleanupWithoutReleasingTheOwner() {
        let owner = CompanionAlignmentOwnership()
        let audition = claimedAudition(owner)

        #expect(owner.markExplicitAuditionStop(targetID: target, clientID: phoneB) == nil,
                "another phone cannot stop this audition")
        #expect(owner.markExplicitAuditionStop(targetID: target, clientID: phoneA) == audition.requestID)
        #expect(owner.current(targetID: target)?.cleanupRequested == true)
        #expect(owner.markExplicitAuditionStop(targetID: target, clientID: phoneA) == audition.requestID,
                "a repeated stop joins the same cleanup")

        // With cleanup already requested, this Mac's own triggers add nothing.
        let calls = Calls()
        #expect(owner.requestAuditionCleanup(targetID: target, requestID: audition.requestID,
                                             stop: calls.stop) == false)
        #expect(calls.targets.isEmpty)
    }

    /// A pair that changed or a lease that ran out stands the audition down
    /// once, through the same token-checked path.
    @Test func aPairChangeAndALeaseExpiryShareOneCleanup() {
        let owner = CompanionAlignmentOwnership()
        let audition = claimedAudition(owner)
        let calls = Calls()

        #expect(owner.requestAuditionCleanup(targetID: target, requestID: audition.requestID,
                                             stop: calls.stop) == true)
        owner.expireAudition(targetID: target, requestID: audition.requestID, stopAudition: calls.stop)
        #expect(calls.targets == [target])
        #expect(owner.current(targetID: target)?.requestID == audition.requestID)
    }
}
