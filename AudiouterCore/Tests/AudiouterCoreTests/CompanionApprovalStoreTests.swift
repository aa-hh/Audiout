// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// The T24 per-phone approval persistence (`CompanionApprovalStore`) and its
/// in-memory model (`CompanionApprovalController`): round-trip, the
/// refuse-forward schema guard every store shares, denial persistence, the
/// prompt funnel (one alert per clientID no matter how many connections pile
/// up behind it), and revocation dropping a live client.
@MainActor
@Suite final class CompanionApprovalStoreTests: IsolatedSuite {

    private static let phoneID = "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A"

    private func makeStore() -> CompanionApprovalStore {
        CompanionApprovalStore(directory: scratchDir)
    }

    // MARK: - Store

    @Test func roundTripsApprovalsIncludingDates() throws {
        let store = makeStore()
        let approval = CompanionApproval(
            clientID: Self.phoneID,
            lastKnownName: "Alec's iPhone",
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
        let first = CompanionApprovalController(store: store)
        var promptCount = 0
        first.presentPrompt = { _, respond in
            promptCount += 1
            respond(false)
        }
        var decisions: [CompanionServer.ApprovalDecision] = []
        first.handleRequest(clientID: Self.phoneID, clientName: "iPhone") { decisions.append($0) }
        #expect(decisions == [.pending, .denied])
        #expect(promptCount == 1)

        // "Relaunch": a fresh controller over the same directory.
        let second = CompanionApprovalController(store: store)
        second.presentPrompt = { _, _ in
            Issue.record("a remembered denial must never re-prompt")
        }
        var relaunchDecisions: [CompanionServer.ApprovalDecision] = []
        second.handleRequest(clientID: Self.phoneID, clientName: "iPhone") { relaunchDecisions.append($0) }
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
        controller.presentPrompt = { _, _ in
            Issue.record("an approved phone must never re-prompt")
        }

        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "renamed iPhone") { decisions.append($0) }

        #expect(decisions == [.approved])
        // Reconnects refresh the display name + lastSeen (and persist both).
        let record = try #require(try store.load()?.first)
        #expect(record.lastKnownName == "renamed iPhone")
        #expect(record.lastSeen == lastSeen)
        #expect(record.firstSeen == .distantPast, "firstSeen must survive reconnects")
    }

    @Test func unknownPhonePromptsOnceAndTheAnswerResolvesEveryWaiter() throws {
        let controller = CompanionApprovalController(store: makeStore())
        var prompts: [(name: String, respond: (Bool) -> Void)] = []
        controller.presentPrompt = { name, respond in prompts.append((name, respond)) }

        var firstDecisions: [CompanionServer.ApprovalDecision] = []
        var secondDecisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone") { firstDecisions.append($0) }
        // The same phone reconnects while the alert is open — it must JOIN
        // the open prompt, not stack a second one.
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone") { secondDecisions.append($0) }

        #expect(prompts.count == 1, "one clientID must produce exactly one prompt")
        #expect(firstDecisions == [.pending])
        #expect(secondDecisions == [.pending])

        prompts[0].respond(true)
        #expect(firstDecisions == [.pending, .approved])
        #expect(secondDecisions == [.pending, .approved], "the single answer must resolve every held connection")
        #expect(controller.approvals.first?.decision == .approved)
    }

    @Test func differentPhonesPromptIndependently() throws {
        let controller = CompanionApprovalController(store: makeStore())
        var prompts: [(name: String, respond: (Bool) -> Void)] = []
        controller.presentPrompt = { name, respond in prompts.append((name, respond)) }

        controller.handleRequest(clientID: Self.phoneID, clientName: "Alec's iPhone") { _ in }
        controller.handleRequest(clientID: UUID().uuidString, clientName: "Guest's iPhone") { _ in }
        #expect(prompts.map(\.name) == ["Alec's iPhone", "Guest's iPhone"])
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
        let controller = CompanionApprovalController(store: store)
        controller.dropClient = { _ in }

        controller.revoke(clientID: Self.phoneID)

        // Now unknown again → the next connect must prompt (a remembered denial
        // would NOT have), and approving replaces the forgotten record.
        var prompts = 0
        controller.presentPrompt = { _, respond in prompts += 1; respond(true) }
        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone") { decisions.append($0) }

        #expect(prompts == 1, "a revoked phone must re-prompt on its next connect")
        #expect(decisions == [.pending, .approved])
        #expect(controller.approvals.map(\.clientID) == [Self.phoneID])
        #expect(controller.approvals.first?.decision == .approved,
                "the fresh answer replaces the revoked record, not stacks on it")
    }
}
