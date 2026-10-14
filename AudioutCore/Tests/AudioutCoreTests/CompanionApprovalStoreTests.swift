// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// The T24 per-phone approval persistence (`CompanionApprovalStore`) and its
/// in-memory model (`CompanionApprovalController`): round-trip, the
/// refuse-forward schema guard every store shares, denial persistence and its
/// cap, the pairing-window gate, the prompt funnel (one alert at a time, one
/// per clientID no matter how many connections pile up behind it, with a
/// cooldown between), and revocation dropping a live client.
@MainActor
@Suite final class CompanionApprovalStoreTests: IsolatedSuite {

    private static let phoneID = "2B5E5A2B58D849799F4192E668FD9C0A2B5E5A2B58D849799F4192E668FD9C0A"

    private func makeStore() -> CompanionApprovalStore {
        CompanionApprovalStore(directory: scratchDir)
    }

    /// A controller inside an open pairing window whose cooldown wake-ups run
    /// at once — for tests about everything but the window and the queue.
    private func makeOpenController(store: CompanionApprovalStore? = nil,
                                    now: @escaping () -> Date = Date.init) -> CompanionApprovalController {
        let controller = CompanionApprovalController(store: store ?? makeStore(), now: now,
                                                     schedule: { _, job in job() })
        controller.isPairingOpen = { true }
        return controller
    }

    // MARK: - Store

    @Test func roundTripsApprovalsIncludingDates() throws {
        let store = makeStore()
        let approval = CompanionApproval(
            clientID: Self.phoneID,
            lastKnownName: "Owner's iPhone",
            decision: .approved,
            firstSeen: Date(timeIntervalSince1970: 1_000),
            lastSeen: Date(timeIntervalSince1970: 2_000))
        try store.save([approval])
        #expect(try store.load() == [approval])
    }

    @Test func missingFileLoadsAsNil() throws {
        #expect(try makeStore().load() == nil)
    }

    /// Refuse-forward: a file from a NEWER schema reads as missing — and for
    /// a trust store the failure direction matters: unknown phones re-prompt,
    /// they are never silently approved.
    @Test func newerSchemaFileIsRefusedNotGuessedAt() throws {
        let json = """
        {"schemaVersion": \(CompanionApprovalStore.currentSchemaVersion + 1), "approvals": []}
        """
        try Data(json.utf8).write(to: scratchDir.appendingPathComponent("companion-approvals.json"))
        #expect(try makeStore().load() == nil)
    }

    /// A denial survives a full relaunch (store reload): the denied phone
    /// must not re-prompt on every reconnect.
    @Test func denialIsRememberedAcrossRelaunch() throws {
        let store = makeStore()
        let first = makeOpenController(store: store)
        var promptCount = 0
        first.presentPrompt = { _, _, _, respond in
            promptCount += 1
            respond(false)
        }
        var decisions: [CompanionServer.ApprovalDecision] = []
        first.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { decisions.append($0) }
        #expect(decisions == [.pending, .denied])
        #expect(promptCount == 1)

        // "Relaunch": a fresh controller over the same directory.
        let second = CompanionApprovalController(store: store)
        second.presentPrompt = { _, _, _, _ in
            Issue.record("a remembered denial must never re-prompt")
        }
        var relaunchDecisions: [CompanionServer.ApprovalDecision] = []
        second.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { relaunchDecisions.append($0) }
        #expect(relaunchDecisions == [.denied])
    }

    // MARK: - Controller: prompt funnel

    @Test func approvedPhoneResolvesInstantlyWithoutAPrompt() throws {
        let store = makeStore()
        try store.save([CompanionApproval(
            clientID: Self.phoneID, lastKnownName: "old name",
            decision: .approved, firstSeen: .distantPast, lastSeen: .distantPast)])
        let lastSeen = Date(timeIntervalSince1970: 5_000)
        let controller = CompanionApprovalController(store: store, now: { lastSeen })
        controller.presentPrompt = { _, _, _, _ in
            Issue.record("an approved phone must never re-prompt")
        }

        // No pairing window is open: a remembered phone never needs one.
        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "renamed iPhone", pairingCode: "123456") { decisions.append($0) }

        #expect(decisions == [.approved])
        // Reconnects refresh the display name + lastSeen (and persist both).
        let record = try #require(try store.load()?.first)
        #expect(record.lastKnownName == "renamed iPhone")
        #expect(record.lastSeen == lastSeen)
        #expect(record.firstSeen == .distantPast, "firstSeen must survive reconnects")
    }

    @Test func unknownPhonePromptsOnceAndTheAnswerResolvesEveryWaiter() throws {
        let controller = makeOpenController()
        var prompts: [(name: String, code: String, respond: (Bool) -> Void)] = []
        controller.presentPrompt = { _, name, code, respond in prompts.append((name, code, respond)) }

        var firstDecisions: [CompanionServer.ApprovalDecision] = []
        var secondDecisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "042317") { firstDecisions.append($0) }
        // The same phone reconnects while the alert is open — it must JOIN
        // the open prompt, not stack a second one.
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "042317") { secondDecisions.append($0) }

        #expect(prompts.count == 1, "one clientID must produce exactly one prompt")
        #expect(prompts.first?.code == "042317", "the prompt shows the code the phone shows")
        #expect(firstDecisions == [.pending])
        #expect(secondDecisions == [.pending])

        prompts[0].respond(true)
        #expect(firstDecisions == [.pending, .approved])
        #expect(secondDecisions == [.pending, .approved], "the single answer must resolve every held connection")
        #expect(controller.approvals.first?.decision == .approved)
    }

    /// Turns red if a second stranger's prompt opens while the first is on
    /// screen, or as soon as the first is answered: a click or Return aimed
    /// at one alert would then land on the next.
    @Test func aSecondUnknownPhoneWaitsUntilTheFirstPromptResolvesAndTheCooldownPasses() throws {
        var jobs: [(delay: TimeInterval, job: @MainActor () -> Void)] = []
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let controller = CompanionApprovalController(store: makeStore(), now: { fixedNow },
                                                     schedule: { delay, job in jobs.append((delay, job)) })
        controller.isPairingOpen = { true }
        var prompts: [(name: String, respond: (Bool) -> Void)] = []
        controller.presentPrompt = { _, name, _, respond in prompts.append((name, respond)) }

        controller.handleRequest(clientID: Self.phoneID, clientName: "Owner's iPhone", pairingCode: "111111") { _ in }
        var guestDecisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: "GUEST", clientName: "Guest's iPhone", pairingCode: "222222") { guestDecisions.append($0) }
        #expect(prompts.map(\.name) == ["Owner's iPhone"], "one prompt on screen at a time")
        #expect(guestDecisions == [.pending], "the waiting phone is held, not refused")

        prompts[0].respond(true)
        #expect(prompts.count == 1, "the next prompt waits out the cooldown")
        #expect(jobs.map { $0.delay } == [CompanionApprovalController.promptCooldown])

        // A third phone arriving during the cooldown queues behind the guest.
        controller.handleRequest(clientID: "THIRD", clientName: "Third iPhone", pairingCode: "333333") { _ in }
        #expect(prompts.count == 1)

        let wake = jobs.removeFirst()
        wake.job()
        #expect(prompts.map(\.name) == ["Owner's iPhone", "Guest's iPhone"])
    }

    /// Turns red if an unknown phone can raise a prompt, or leave a record,
    /// while no pairing window is open.
    @Test func unknownPhoneWhileNoPairingWindowIsRefusedWithoutAPrompt() throws {
        let controller = CompanionApprovalController(store: makeStore())
        controller.presentPrompt = { _, _, _, _ in
            Issue.record("no prompt may open outside a pairing window")
        }

        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { decisions.append($0) }

        #expect(decisions == [.pairingClosed])
        #expect(controller.approvals.isEmpty, "a refused stranger leaves no record")
    }

    /// Turns red if withdrawing an unanswered prompt keeps its entry, so the
    /// phone's next connect joins a dead prompt instead of asking again, or
    /// if the next prompt skips the cooldown the withdrawal started.
    @Test func abandonedRequestFreesTheEntryAndWithdrawsThePrompt() throws {
        var jobs: [@MainActor () -> Void] = []
        let controller = CompanionApprovalController(store: makeStore(),
                                                     schedule: { _, job in jobs.append(job) })
        controller.isPairingOpen = { true }
        var promptCount = 0
        var withdrawn: [String] = []
        controller.presentPrompt = { _, _, _, _ in promptCount += 1 }
        controller.withdrawPrompt = { clientID in withdrawn.append(clientID) }

        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { _ in }
        #expect(promptCount == 1)

        controller.abandonRequest(clientID: Self.phoneID)
        #expect(withdrawn == [Self.phoneID])
        #expect(controller.approvals.isEmpty, "abandonment must not persist a decision")

        // The entry was freed, not just hidden: the phone's next connect
        // re-prompts rather than joining a dead prompt — once the cooldown
        // the withdrawal started has passed.
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { _ in }
        #expect(promptCount == 1)
        for job in jobs { job() }
        #expect(promptCount == 2)
    }

    @Test func abandonForAPhoneThatWasNeverPromptedIsANoOp() throws {
        let controller = CompanionApprovalController(store: makeStore())
        var withdrawn: [String] = []
        controller.withdrawPrompt = { clientID in withdrawn.append(clientID) }

        controller.abandonRequest(clientID: Self.phoneID)
        #expect(withdrawn.isEmpty)
    }

    // MARK: - Revocation

    @Test func revokeForgetsTheRecordAndDropsTheLiveClient() throws {
        let store = makeStore()
        try store.save([CompanionApproval(
            clientID: Self.phoneID, lastKnownName: "iPhone",
            decision: .approved, firstSeen: .distantPast, lastSeen: .distantPast)])
        let controller = CompanionApprovalController(store: store)
        var dropped: [String] = []
        controller.dropClient = { dropped.append($0) }
        var changed = 0
        controller.onChange = { changed += 1 }

        controller.revoke(clientID: Self.phoneID)

        #expect(controller.approvals.isEmpty)
        #expect(try store.load() == [], "the revocation must persist")
        #expect(dropped == [Self.phoneID], "revoking must disconnect the live client")
        #expect(changed == 1)

        // Revoking an unknown ID is a no-op — no phantom drop, no change ping.
        controller.revoke(clientID: UUID().uuidString)
        #expect(dropped.count == 1)
        #expect(changed == 1)
    }

    /// Revocation must truly FORGET the phone, not just drop it: a revoked
    /// phone (even a previously DENIED one) is unknown again, so its next
    /// connect re-prompts and the fresh answer replaces the old record. This
    /// is the whole point of revoke being reachable for denials too — it's how
    /// you give a phone you once refused a second chance.
    @Test func revokingClearsMemorySoTheNextConnectRePromptsFresh() throws {
        let store = makeStore()
        try store.save([CompanionApproval(
            clientID: Self.phoneID, lastKnownName: "iPhone",
            decision: .denied, firstSeen: .distantPast, lastSeen: .distantPast)])
        let controller = makeOpenController(store: store)
        controller.dropClient = { _ in }

        controller.revoke(clientID: Self.phoneID)

        // Now unknown again → the next connect must prompt (a remembered denial
        // would NOT have), and approving replaces the forgotten record.
        var prompts = 0
        controller.presentPrompt = { _, _, _, respond in prompts += 1; respond(true) }
        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { decisions.append($0) }

        #expect(prompts == 1, "a revoked phone must re-prompt on its next connect")
        #expect(decisions == [.pending, .approved])
        #expect(controller.approvals.map(\.clientID) == [Self.phoneID])
        #expect(controller.approvals.first?.decision == .approved,
                "the fresh answer replaces the revoked record, not stacks on it")
    }

    // MARK: - Denial cap and the approved set

    /// Turns red if remembered denials stop being capped, or if the cap
    /// drops the newest denial or an approval instead of the oldest denial.
    @Test func denialsAreCappedAtEight() throws {
        let store = makeStore()
        try store.save([CompanionApproval(
            clientID: Self.phoneID, lastKnownName: "Owner's iPhone",
            decision: .approved, firstSeen: .distantPast, lastSeen: .distantPast)])
        var tick = 0.0
        let controller = makeOpenController(store: store, now: {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        })
        controller.presentPrompt = { _, _, _, respond in respond(false) }

        for index in 0..<10 {
            controller.handleRequest(clientID: "STRANGER-\(index)", clientName: "iPhone \(index)",
                                     pairingCode: "000000") { _ in }
        }

        let denied = controller.approvals.filter { $0.decision == .denied }.map(\.clientID)
        #expect(denied == (2..<10).map { "STRANGER-\($0)" })
        #expect(controller.approvals.contains { $0.clientID == Self.phoneID && $0.decision == .approved })
        #expect(try store.load()?.count == 9, "the cap is persisted, not just held in memory")
    }

    /// Turns red if approving or revoking a phone stops telling the
    /// coordinator, which starts or stops the server and closes the pairing
    /// window on it — or if a denial is reported as a change to the approved
    /// set.
    @Test func onApprovedSetChangedFiresOnApproveAndRevoke() throws {
        let controller = makeOpenController()
        controller.dropClient = { _ in }
        var changes = 0
        controller.onApprovedSetChanged = { changes += 1 }

        controller.presentPrompt = { _, _, _, respond in respond(true) }
        controller.handleRequest(clientID: Self.phoneID, clientName: "Owner's iPhone", pairingCode: "111111") { _ in }
        #expect(changes == 1)

        controller.presentPrompt = { _, _, _, respond in respond(false) }
        controller.handleRequest(clientID: "GUEST", clientName: "Guest's iPhone", pairingCode: "222222") { _ in }
        #expect(changes == 1, "a denial leaves the approved set alone")

        controller.revoke(clientID: Self.phoneID)
        #expect(changes == 2)
        controller.revoke(clientID: "GUEST")
        #expect(changes == 2, "revoking a denial leaves the approved set alone")
    }

    /// Turns red if `onPendingRequestsSettled` fires while another phone still
    /// waits, so the coordinator stops the server under it, or stays silent
    /// when the last waiting request is abandoned or answered, so a server
    /// kept up for that prompt never stops.
    @Test func onPendingRequestsSettledFiresOnlyWhenTheLastWaitingRequestEnds() throws {
        var jobs: [@MainActor () -> Void] = []
        let controller = CompanionApprovalController(store: makeStore(),
                                                     schedule: { _, job in jobs.append(job) })
        controller.isPairingOpen = { true }
        var answers: [(Bool) -> Void] = []
        controller.presentPrompt = { _, _, _, respond in answers.append(respond) }
        var settled = 0
        controller.onPendingRequestsSettled = { settled += 1 }

        controller.handleRequest(clientID: "FIRST", clientName: "iPhone", pairingCode: "111111") { _ in }
        controller.handleRequest(clientID: "SECOND", clientName: "iPhone", pairingCode: "222222") { _ in }
        answers[0](false)
        #expect(settled == 0, "the second phone is still queued")
        #expect(controller.hasPendingRequest)

        controller.abandonRequest(clientID: "SECOND")
        #expect(settled == 1)
        #expect(!controller.hasPendingRequest)

        controller.handleRequest(clientID: "THIRD", clientName: "iPhone", pairingCode: "333333") { _ in }
        for job in jobs { job() }
        answers[1](true)
        #expect(settled == 2)
        #expect(!controller.hasPendingRequest)
    }

    /// Turns red if an approval keyed by a protocol-v1 UUID survives load,
    /// where it counts as an approved phone no current phone can be, or if
    /// the cleaned list is not written back.
    @Test func aProtocolV1ApprovalIsDroppedOnLoad() throws {
        let store = makeStore()
        let v1 = CompanionApproval(clientID: "8E4CE9B0-B2C1-4E0E-9D25-000000000001", lastKnownName: "Old iPhone",
                                   decision: .approved, firstSeen: .distantPast, lastSeen: .distantPast)
        let current = CompanionApproval(clientID: Self.phoneID, lastKnownName: "Owner's iPhone",
                                        decision: .approved, firstSeen: .distantPast, lastSeen: .distantPast)
        let denial = CompanionApproval(clientID: "GUEST", lastKnownName: "Guest's iPhone",
                                       decision: .denied, firstSeen: .distantPast, lastSeen: .distantPast)
        try store.save([v1, current, denial])

        let controller = CompanionApprovalController(store: store)

        #expect(controller.approvals == [current, denial])
        #expect(try store.load() == [current, denial])
    }
}
