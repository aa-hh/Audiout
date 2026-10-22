// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// The T24 per-phone approval persistence (`CompanionApprovalStore`) and its
/// in-memory model (`CompanionApprovalController`): round-trip, the
/// refuse-forward schema guard every store shares, the prompt funnel (one
/// alert at a time, one per clientID no matter how many connections pile up
/// behind it, with a cooldown between), denials kept nowhere, the pause after
/// several denials, and revocation dropping a live client.
@MainActor
@Suite final class CompanionApprovalStoreTests: IsolatedSuite {

    private static let phoneID = "2B5E5A2B58D849799F4192E668FD9C0A2B5E5A2B58D849799F4192E668FD9C0A"

    private func makeStore() -> CompanionApprovalStore {
        CompanionApprovalStore(directory: scratchDir)
    }

    /// A controller whose cooldown wake-ups run at once — for tests about
    /// everything but the queue.
    private func makeController(store: CompanionApprovalStore? = nil,
                                now: @escaping () -> Date = Date.init) -> CompanionApprovalController {
        CompanionApprovalController(store: store ?? makeStore(), now: now, schedule: { _, job in job() })
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

    /// Turns red if a "Don't Allow" is written down anywhere: the same phone
    /// asking again, now or after a relaunch, must get a fresh prompt.
    @Test func aDenialIsNotRememberedSoThePhoneMayAskAgain() throws {
        let store = makeStore()
        let first = makeController(store: store)
        var promptCount = 0
        first.presentPrompt = { _, _, _, respond in
            promptCount += 1
            respond(false)
        }
        var decisions: [CompanionServer.ApprovalDecision] = []
        first.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { decisions.append($0) }
        #expect(decisions == [.pending, .denied])
        #expect(first.approvals.isEmpty)
        #expect(try store.load() == nil, "nothing is saved for a denial")

        first.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { decisions.append($0) }
        #expect(promptCount == 2, "asking again raises a new prompt")

        // "Relaunch": a fresh controller over the same directory asks too.
        let second = makeController(store: store)
        var relaunchPrompts = 0
        second.presentPrompt = { _, _, _, _ in relaunchPrompts += 1 }
        second.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { _ in }
        #expect(relaunchPrompts == 1)
    }

    // MARK: - Controller: prompt funnel

    @Test func approvedPhoneResolvesInstantlyWithoutAPrompt() throws {
        let store = makeStore()
        try store.save([CompanionApproval(
            clientID: Self.phoneID, lastKnownName: "old name",
            decision: .approved, firstSeen: .distantPast, lastSeen: Date(timeIntervalSince1970: 4_000))])
        let lastSeen = Date(timeIntervalSince1970: 5_000)
        let controller = CompanionApprovalController(store: store, now: { lastSeen })
        controller.presentPrompt = { _, _, _, _ in
            Issue.record("an approved phone must never re-prompt")
        }

        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "renamed iPhone", pairingCode: "123456") { decisions.append($0) }

        #expect(decisions == [.approved])
        // Reconnects refresh the display name + lastSeen (and persist both).
        let record = try #require(try store.load()?.first)
        #expect(record.lastKnownName == "renamed iPhone")
        #expect(record.lastSeen == lastSeen)
        #expect(record.firstSeen == .distantPast, "firstSeen must survive reconnects")
    }

    /// Turns red if an allowed phone stops being let in after a long gap
    /// without connecting: approvals last until the user removes them.
    @Test func anApprovalNeverLapses() throws {
        let store = makeStore()
        try store.save([CompanionApproval(
            clientID: Self.phoneID, lastKnownName: "Owner's iPhone",
            firstSeen: .distantPast, lastSeen: Date(timeIntervalSince1970: 0))])
        let years = Date(timeIntervalSince1970: 5 * 365 * 24 * 60 * 60)
        let controller = makeController(store: store, now: { years })
        controller.presentPrompt = { _, _, _, _ in Issue.record("an allowed phone is never asked about") }

        #expect(controller.approvals.map(\.clientID) == [Self.phoneID])
        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "Owner's iPhone", pairingCode: "000000") { decisions.append($0) }
        #expect(decisions == [.approved])
    }

    @Test func unknownPhonePromptsOnceAndTheAnswerResolvesEveryWaiter() throws {
        let controller = makeController()
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
        #expect(controller.approvals.map(\.clientID) == [Self.phoneID])
    }

    /// Turns red if a second stranger's prompt opens while the first is on
    /// screen, or as soon as the first is answered: a click or Return aimed
    /// at one alert would then land on the next.
    @Test func aSecondUnknownPhoneWaitsUntilTheFirstPromptResolvesAndTheCooldownPasses() throws {
        var jobs: [(delay: TimeInterval, job: @MainActor () -> Void)] = []
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let controller = CompanionApprovalController(store: makeStore(), now: { fixedNow },
                                                     schedule: { delay, job in jobs.append((delay, job)) })
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

    /// Turns red if an unknown phone needs anything opened on the Mac before
    /// it may ask: a controller nobody configured still prompts for it.
    @Test func anUnknownPhonePromptsWithoutAnyPairingWindow() throws {
        let controller = CompanionApprovalController(store: makeStore())
        var prompts: [(name: String, code: String)] = []
        controller.presentPrompt = { _, name, code, _ in prompts.append((name, code)) }

        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { decisions.append($0) }

        #expect(decisions == [.pending])
        #expect(prompts.map(\.code) == ["123456"])
    }

    /// Turns red if withdrawing an unanswered prompt keeps its entry, so the
    /// phone's next connect joins a dead prompt instead of asking again, or
    /// if the next prompt skips the cooldown the withdrawal started.
    @Test func abandonedRequestFreesTheEntryAndWithdrawsThePrompt() throws {
        var jobs: [@MainActor () -> Void] = []
        let controller = CompanionApprovalController(store: makeStore(),
                                                     schedule: { _, job in jobs.append(job) })
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
            decision: .approved, firstSeen: .distantPast, lastSeen: Date())])
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

    /// Turns red if removing a phone only drops it instead of forgetting it:
    /// its next connect must prompt again and the answer replace the record.
    @Test func revokingClearsMemorySoTheNextConnectRePromptsFresh() throws {
        let store = makeStore()
        try store.save([CompanionApproval(
            clientID: Self.phoneID, lastKnownName: "iPhone",
            firstSeen: .distantPast, lastSeen: .distantPast)])
        let controller = makeController(store: store)
        controller.dropClient = { _ in }

        controller.revoke(clientID: Self.phoneID)

        var prompts = 0
        controller.presentPrompt = { _, _, _, respond in prompts += 1; respond(true) }
        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: Self.phoneID, clientName: "iPhone", pairingCode: "123456") { decisions.append($0) }

        #expect(prompts == 1, "a revoked phone must re-prompt on its next connect")
        #expect(decisions == [.pending, .approved])
        #expect(controller.approvals.map(\.clientID) == [Self.phoneID],
                "the fresh answer replaces the revoked record, not stacks on it")
    }

    // MARK: - Prompt copy

    /// Turns red if the prompt quotes the name iOS reports without the
    /// device-name entitlement ("iPhone", in any case or padding), or stops
    /// quoting a name that says more.
    @Test func thePromptQuotesThePhonesNameOnlyWhenItSaysMoreThanIPhone() {
        let generic = "Allow only if the iPhone shows the same code.\n\n"
            + "It will see and control what's playing on this Mac's speakers, including which apps are playing. "
            + "You can remove it later in Settings › Audiout Remote."
        for name in ["iPhone", " iphone ", "IPHONE", ""] {
            #expect(CompanionApprovalPrompt.informativeText(clientName: name) == generic, "\(name)")
        }
        #expect(CompanionApprovalPrompt.informativeText(clientName: "Ada's iPhone")
                == "Allow only if the iPhone shows the same code. It calls itself \"Ada's iPhone\".\n\n"
                + "It will see and control what's playing on this Mac's speakers, including which apps are playing. "
                + "You can remove it later in Settings › Audiout Remote.")
        #expect(CompanionApprovalPrompt.messageText == "Allow an iPhone to control Audiout on this Mac?")
    }

    /// Turns red if VoiceOver is handed the code's digits as one number.
    @Test func theCodeIsReadDigitByDigit() {
        #expect(CompanionApprovalPrompt.accessibilityLabel(code: "482913") == "Pairing code 4 8 2 9 1 3")
    }

    // MARK: - Pause after repeated denials

    /// One hello from `clientID`, and every decision it got back.
    private func ask(_ controller: CompanionApprovalController, _ clientID: String) -> [CompanionServer.ApprovalDecision] {
        var decisions: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: clientID, clientName: "iPhone", pairingCode: "000000") { decisions.append($0) }
        return decisions
    }

    /// Turns red if three "Don't Allow"s within ten minutes stop pausing new
    /// phones, if the pause shows a prompt or sends the wrong seconds, if it
    /// turns away an allowed phone, or if it outlasts fifteen minutes.
    @Test func threeDenialsInTenMinutesPauseNewPhonesForFifteen() throws {
        let store = makeStore()
        try store.save([CompanionApproval(clientID: Self.phoneID, lastKnownName: "Owner's iPhone",
                                          firstSeen: .distantPast, lastSeen: .distantPast)])
        var now = Date(timeIntervalSince1970: 1_000_000)
        let controller = makeController(store: store, now: { now })
        var prompts = 0
        controller.presentPrompt = { _, _, _, respond in prompts += 1; respond(false) }

        for index in 0..<3 {
            #expect(ask(controller, "STRANGER-\(index)") == [.pending, .denied])
            now = now.addingTimeInterval(4 * 60)
        }
        // The third denial was 4 minutes ago: 11 minutes of pause are left.
        #expect(ask(controller, "STRANGER-3") == [.paused(seconds: 11 * 60)])
        #expect(prompts == 3, "no prompt while paused")
        #expect(ask(controller, Self.phoneID) == [.approved], "an allowed phone is never paused")

        now = now.addingTimeInterval(11 * 60 - 0.5)
        #expect(ask(controller, "STRANGER-3") == [.paused(seconds: 1)], "seconds round up")
        now = now.addingTimeInterval(0.5)
        #expect(ask(controller, "STRANGER-3") == [.pending, .denied], "the pause is over")
        #expect(prompts == 4)
    }

    /// Turns red if denials spread wider than ten minutes start a pause, or
    /// if a prompt that times out unanswered counts as a denial.
    @Test func spreadOutDenialsAndTimeoutsDoNotPause() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let controller = makeController(now: { now })
        var answer: Bool? = false
        controller.presentPrompt = { _, _, _, respond in if let answer { respond(answer) } }

        #expect(ask(controller, "A") == [.pending, .denied])
        now = now.addingTimeInterval(6 * 60)
        #expect(ask(controller, "B") == [.pending, .denied])
        now = now.addingTimeInterval(5 * 60)
        #expect(ask(controller, "C") == [.pending, .denied], "the first denial is 11 minutes old")

        answer = nil
        #expect(ask(controller, "D") == [.pending])
        controller.abandonRequest(clientID: "D")
        answer = false
        #expect(ask(controller, "E") == [.pending, .denied], "the timeout was not a denial")
        #expect(ask(controller, "F") == [.paused(seconds: 15 * 60)], "B, C and E are three in ten minutes")
    }

    /// Turns red if a phone already queued behind the prompt that started
    /// the pause is still shown a prompt later, or left waiting unanswered.
    @Test func thePauseTurnsAwayPhonesAlreadyQueued() throws {
        var jobs: [@MainActor () -> Void] = []
        let controller = CompanionApprovalController(store: makeStore(), schedule: { _, job in jobs.append(job) })
        var answers: [(Bool) -> Void] = []
        controller.presentPrompt = { _, _, _, respond in answers.append(respond) }
        func endCooldown() {
            let due = jobs
            jobs.removeAll()
            for job in due { job() }
        }

        _ = ask(controller, "A")
        answers[0](false)
        endCooldown()
        _ = ask(controller, "B")
        answers[1](false)
        endCooldown()
        _ = ask(controller, "C")
        var queued: [CompanionServer.ApprovalDecision] = []
        controller.handleRequest(clientID: "QUEUED", clientName: "iPhone", pairingCode: "000000") { queued.append($0) }
        #expect(queued == [.pending], "waiting behind C's prompt")

        answers[2](false)
        #expect(queued == [.pending, .paused(seconds: 15 * 60)], "the third denial turns it away")
        endCooldown()
        #expect(answers.count == 3, "no prompt opens for it later")
    }

    /// Turns red if an approval keyed by a protocol-v1 UUID, or a denial an
    /// older build saved, survives load, or if the cleaned list is not
    /// written back.
    @Test func aProtocolV1ApprovalAndOldDenialsAreDroppedOnLoad() throws {
        let store = makeStore()
        let v1 = CompanionApproval(clientID: "8E4CE9B0-B2C1-4E0E-9D25-000000000001", lastKnownName: "Old iPhone",
                                   firstSeen: .distantPast, lastSeen: .distantPast)
        let current = CompanionApproval(clientID: Self.phoneID, lastKnownName: "Owner's iPhone",
                                        firstSeen: .distantPast, lastSeen: Date())
        let denial = CompanionApproval(clientID: String(repeating: "A", count: 64), lastKnownName: "Guest's iPhone",
                                       decision: .denied, firstSeen: .distantPast, lastSeen: .distantPast)
        try store.save([v1, current, denial])

        let controller = CompanionApprovalController(store: store)

        #expect(controller.approvals == [current])
        #expect(try store.load() == [current])
    }
}
