// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// The companion wiring `AppDelegate` used to hold inline (code review 2026-09-17,
/// ticket 24). `CompanionCoordinator` owns it in the library, where the suite can
/// reach it; `AppDelegate` is only its AppKit host. Controllers are built the way
/// `CompanionEndToEndTests.Rig` builds them (real types, temp-directory stores).
@MainActor
@Suite final class CompanionWiringTests: IsolatedSuite {

    /// A `CompanionCoordinatorHost` that answers every approval prompt with
    /// "Allow" and records what the coordinator asked of AppKit.
    private final class StubHost: CompanionCoordinatorHost {
        var clientCounts: [Int] = []
        /// One entry per icon request handed over, holding its completion.
        var iconCompletions: [@MainActor () -> Void] = []
        /// When false, prompts stay open and their answers wait in `openPrompts`.
        var answersPromptsAtOnce = true
        var openPrompts: [(Bool) -> Void] = []
        var promptCodes: [String] = []

        func presentApprovalPrompt(clientID: String, clientName: String, pairingCode: String,
                                   respond: @escaping (Bool) -> Void) {
            promptCodes.append(pairingCode)
            if answersPromptsAtOnce { respond(true) } else { openPrompts.append(respond) }
        }
        func withdrawApprovalPrompt(clientID: String) {}
        var codeChecks: [(clientID: String, name: String, code: String)] = []
        var withdrawnCodeChecks: [String] = []
        func presentPairingCodeCheck(clientID: String, clientName: String, pairingCode: String) {
            codeChecks.append((clientID, clientName, pairingCode))
        }
        func withdrawPairingCodeCheck(clientID: String) { withdrawnCodeChecks.append(clientID) }
        var activatedKeys: [String] = []
        func activateLicenseKey(_ key: String,
                                reply: @escaping (CompanionServer.CommandResult) -> Void) {
            activatedKeys.append(key)
            reply(CompanionServer.CommandResult(applied: true))
        }
        func runningApplications() -> [(bundleID: String, displayName: String)] { [] }
        func serveAppIconPages(_ requested: [String], to clientID: UUID,
                               completion: @escaping @MainActor () -> Void) {
            iconCompletions.append(completion)
        }
        func devices() -> [Device] { [] }
        func symbolName(for device: Device) -> String { "hifispeaker" }
        func routedAppNames() -> [String: [String]] { [:] }
        func clientCountDidChange(_ count: Int) { clientCounts.append(count) }
        func alignmentRunStarted(deviceID: String) {}
        func alignmentMoved(deviceID: String, byMs: Double) {}
        var isTerminating: Bool { false }
        func log(_ message: String) {}
    }

    /// Never hands out an identity, and counts how often it was asked: the
    /// suite must never touch the login keychain or start a real listener.
    private final class RefusingIdentityStore: CompanionIdentityStoring {
        var loads = 0
        func loadOrCreate() throws -> CompanionIdentity {
            loads += 1
            throw CompanionIdentityError.identityNotFound
        }
    }

    /// Replies from the coordinator's command path, which arrive on main.
    private final class ReplyLog: @unchecked Sendable {
        var results: [CompanionServer.CommandResult] = []
    }

    /// Prompts open in a pairing window and follow one another at once, so a
    /// test can approve several phones in a row without wiring the
    /// coordinator; ``CompanionCoordinator/wire()`` replaces the window
    /// check with the real one.
    private func makeCoordinator(host: StubHost, storeName: String,
                                 identityStore: RefusingIdentityStore = RefusingIdentityStore(),
                                 schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil,
                                 now: (() -> Date)? = nil,
                                 scheduleWork: ((TimeInterval, DispatchWorkItem) -> Void)? = nil)
        -> CompanionCoordinator {
        let directory = scratchDir.appendingPathComponent(storeName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let approvals = CompanionApprovalController(
            store: CompanionApprovalStore(directory: directory),
            now: now ?? Date.init,
            schedule: schedule ?? { _, job in job() })
        approvals.isPairingOpen = { true }
        approvals.presentPrompt = { _, _, _, respond in respond(true) }
        return CompanionCoordinator(
            backend: backend,
            groupController: GroupController(
                backend: backend,
                store: GroupStore(directory: directory),
                routingStore: RoutingStore(directory: directory),
                loadPersisted: false),
            appRouting: AppRoutingController(store: AppRouteStore(directory: directory),
                                             loadPersisted: false),
            settings: AppSettings(defaults: makeDefaults()),
            excludedBundleIDs: { [] },
            speakerLibrary: SpeakerLibraryController(store: SpeakerLibraryStore(directory: directory),
                                                     loadPersisted: false),
            serverName: "TestMac",
            server: CompanionServer(),
            approvals: approvals,
            identityStore: identityStore,
            schedule: scheduleWork ?? { _, _ in },
            host: host)
    }

    private func approve(clientID: String, name: String, in coordinator: CompanionCoordinator) {
        coordinator.approvals.handleRequest(clientID: clientID, clientName: name, pairingCode: "000000",
                                            decide: { _ in })
    }

    /// Turns red if `CompanionCoordinator.noteSlot` reorders the popover's
    /// precedence or stops calling a timed-out takeover a warning.
    @Test func theNoteSlotFollowsThePopoversPrecedence() {
        let all = CompanionCoordinator.noteSlot(captureFailure: "The tap died.", routingBlocked: true,
                                                takeover: .takingOver, doublePath: true)
        #expect(all?.text == "The tap died.")
        #expect(all?.severity == "warning")

        let blocked = CompanionCoordinator.noteSlot(captureFailure: nil, routingBlocked: true,
                                                    takeover: .takingOver, doublePath: true)
        #expect(blocked?.text == CompanionCoordinator.routingBlockedText)
        #expect(blocked?.severity == "warning")

        let takeover = CompanionCoordinator.noteSlot(captureFailure: nil, routingBlocked: false,
                                                     takeover: .takingOver, doublePath: true)
        #expect(takeover?.text == CompanionCoordinator.takeoverText(.takingOver))
        #expect(takeover?.severity == "info")

        let timedOut = CompanionCoordinator.noteSlot(captureFailure: nil, routingBlocked: false,
                                                     takeover: .timedOut, doublePath: false)
        #expect(timedOut?.severity == "warning")

        let doublePath = CompanionCoordinator.noteSlot(captureFailure: nil, routingBlocked: false,
                                                       takeover: nil, doublePath: true)
        #expect(doublePath?.text == CompanionCoordinator.doublePathText)
        #expect(doublePath?.severity == "info")

        #expect(CompanionCoordinator.noteSlot(captureFailure: nil, routingBlocked: false,
                                              takeover: nil, doublePath: false) == nil)
    }

    /// The wizard's iPhone panel names a phone only when exactly one is
    /// connected AND exactly one is on file (`shape-mac-invites.md` §2.2).
    ///
    /// Defect this catches: the Mac naming one phone while another approved
    /// phone is also on file — the panel would then name the wrong phone.
    @Test func invitePhoneNameIsGivenOnlyWhenExactlyOnePhoneIsConnectedAndOneApproved() {
        let host = StubHost()

        let twoOnFile = makeCoordinator(host: host, storeName: "two-on-file")
        approve(clientID: "8E4CE9B0-B2C1-4E0E-4B37-9D25-000000000001",
                name: "Ada's iPhone", in: twoOnFile)
        approve(clientID: "8E4CE9B0-B2C1-4E0E-4B37-9D25-000000000002",
                name: "Grace's iPhone", in: twoOnFile)
        twoOnFile.noteClientCount(1)
        #expect(twoOnFile.approvals.approvals.count == 2,
                "both phones were approved, so both are on file")
        #expect(twoOnFile.invitePhoneName == nil,
                "two approved phones on file: the Mac can't know which one is in the room")

        let oneOnFile = makeCoordinator(host: host, storeName: "one-on-file")
        approve(clientID: "8E4CE9B0-B2C1-4E0E-4B37-9D25-000000000001",
                name: "Ada's iPhone", in: oneOnFile)
        oneOnFile.noteClientCount(1)
        #expect(oneOnFile.invitePhoneName == "Ada's iPhone",
                "one phone connected and one on file: the wizard names it")

        #expect(host.clientCounts == [1, 1],
                "every client-count change reaches the host")
    }

    // MARK: Pairing window

    /// Turns red if the coordinator stops feeding the approval controller
    /// its pairing window, or stops closing the window once a phone is
    /// approved — an unknown phone could then ask with no window open, or
    /// the window would stay open after it did its job. The positive half of
    /// the server gate is not observable here: this build does not offer the
    /// phone app, so `resolvedAllowRemoteControl` is off inside the suite and
    /// the server never starts — which the identity store's untouched count
    /// pins.
    @Test func theServerRunsOnlyWithAnApprovedPhoneOrAnOpenPairingWindow() {
        let host = StubHost()
        let identities = RefusingIdentityStore()
        let coordinator = makeCoordinator(host: host, storeName: "pairing-window", identityStore: identities)
        var windowChanges = 0
        coordinator.onPairingWindowChanged = { windowChanges += 1 }
        coordinator.wire()

        var stranger: [CompanionServer.ApprovalDecision] = []
        coordinator.approvals.handleRequest(clientID: "STRANGER", clientName: "iPhone",
                                            pairingCode: "000000") { stranger.append($0) }
        #expect(stranger == [.pairingClosed], "no window open: the stranger is refused unasked")

        coordinator.openPairingWindow()
        #expect(coordinator.pairingWindowOpen)
        #expect(windowChanges == 1)

        var invited: [CompanionServer.ApprovalDecision] = []
        coordinator.approvals.handleRequest(clientID: "INVITED", clientName: "iPhone",
                                            pairingCode: "000000") { invited.append($0) }
        #expect(invited == [.pending, .approved])
        #expect(!coordinator.pairingWindowOpen, "the first approval closes the window that let it in")
        #expect(windowChanges == 2)
        #expect(identities.loads == 0,
                "a build that does not offer the phone app never reaches for the TLS identity")
    }

    /// Turns red if `wantsServer` stops counting a phone still waiting on its
    /// prompt, so the pairing window's expiry stops the server under it, or
    /// keeps counting it once its prompt is answered, so a Mac with nothing
    /// approved stays on the network. The expiry is the window's work item
    /// calling `closePairingWindow()`, called directly here; the server's
    /// own start and stop are out of reach, as the test above explains.
    @Test func aPromptOpenWhenThePairingWindowEndsKeepsTheServerWantedUntilAnswered() {
        let host = StubHost()
        host.answersPromptsAtOnce = false
        let coordinator = makeCoordinator(host: host, storeName: "window-expiry")
        coordinator.wire()
        coordinator.openPairingWindow()

        var decisions: [CompanionServer.ApprovalDecision] = []
        coordinator.approvals.handleRequest(clientID: "WAITING", clientName: "iPhone",
                                            pairingCode: "000000") { decisions.append($0) }
        #expect(decisions == [.pending])

        coordinator.closePairingWindow()
        #expect(!coordinator.pairingWindowOpen)
        #expect(coordinator.wantsServer, "the phone on the prompt keeps the server wanted")

        host.openPrompts.first?(false)
        #expect(decisions == [.pending, .denied])
        #expect(!coordinator.wantsServer, "answered, and nothing approved: nothing wants the server")
    }

    /// Turns red if a phone whose approval lapsed closes or changes the
    /// pairing window the user opened, with or without another phone still
    /// approved, or is let in without the Allow/Don't Allow prompt showing
    /// its code.
    @Test func aLapsedPhoneIsAskedAgainAndLeavesThePairingWindowOpen() throws {
        let lapsed = String(repeating: "D", count: 64)
        for anotherPhoneApproved in [true, false] {
            let storeName = "lapse-\(anotherPhoneApproved)"
            let directory = scratchDir.appendingPathComponent(storeName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var records = [CompanionApproval(
                clientID: lapsed, lastKnownName: "Old iPhone", decision: .approved, firstSeen: .distantPast,
                lastSeen: Date().addingTimeInterval(-CompanionApprovalStore.trustLapse - 60))]
            if anotherPhoneApproved {
                records.append(CompanionApproval(clientID: String(repeating: "E", count: 64),
                                                 lastKnownName: "Owner's iPhone", decision: .approved,
                                                 firstSeen: .distantPast, lastSeen: Date()))
            }
            try CompanionApprovalStore(directory: directory).save(records)
            let host = StubHost()
            host.answersPromptsAtOnce = false
            let coordinator = makeCoordinator(host: host, storeName: storeName)
            coordinator.wire()
            coordinator.openPairingWindow()
            var windowChanges = 0
            coordinator.onPairingWindowChanged = { windowChanges += 1 }

            var decisions: [CompanionServer.ApprovalDecision] = []
            coordinator.approvals.handleRequest(clientID: lapsed, clientName: "Old iPhone",
                                                pairingCode: "482913") { decisions.append($0) }

            #expect(decisions == [.pending], "another phone approved: \(anotherPhoneApproved)")
            #expect(host.promptCodes == ["482913"], "another phone approved: \(anotherPhoneApproved)")
            #expect(coordinator.pairingWindowOpen, "another phone approved: \(anotherPhoneApproved)")
            #expect(windowChanges == 0, "another phone approved: \(anotherPhoneApproved)")
        }
    }

    /// Turns red if the coordinator stops arming a re-check of the server
    /// decision for the moment an approval lapses. `approvals` drops a lapsed
    /// approval on its own, with no phone connecting and no setting changing,
    /// so without the armed re-check a Mac left running past the 30 days
    /// keeps the listener up and keeps advertising with nothing approved
    /// (DESIGN.md: discoverable only while a pairing window is open or a
    /// phone is paired).
    @Test func anApprovalLapsingWithNothingConnectedRechecksTheServerDecision() throws {
        let directory = scratchDir.appendingPathComponent("lapse-recheck")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let approvedAt = Date()
        try CompanionApprovalStore(directory: directory).save([CompanionApproval(
            clientID: String(repeating: "A", count: 64), lastKnownName: "Ada's iPhone",
            decision: .approved, firstSeen: approvedAt, lastSeen: approvedAt)])
        var clock = approvedAt
        var rechecks: [(after: TimeInterval, work: DispatchWorkItem)] = []
        let coordinator = makeCoordinator(host: StubHost(), storeName: "lapse-recheck",
                                          now: { clock },
                                          scheduleWork: { rechecks.append(($0, $1)) })
        coordinator.wire()

        #expect(coordinator.wantsServer, "an approved phone keeps the server wanted")
        #expect(rechecks.count == 1, "one approval on file: one re-check armed")
        #expect(abs((rechecks.first?.after ?? 0) - CompanionApprovalStore.trustLapse) < 2,
                "the re-check is armed for the moment that approval lapses")

        clock = approvedAt.addingTimeInterval(CompanionApprovalStore.trustLapse + 60)
        rechecks[0].work.perform()
        #expect(!coordinator.wantsServer, "the approval lapsed unused: nothing wants the server")
        #expect(rechecks.count == 1, "nothing is approved now, so no further re-check is armed")
    }

    // MARK: Pairing-code alert

    /// Turns red if the coordinator stops handing the hello's code-check flag
    /// to the approval controller, stops sending the alert to the host, or
    /// stops closing it on that connection's first command, its close, or
    /// its refusal or death before it was admitted.
    @Test func thePairingCodeAlertReachesTheHostAndClosesOnCommandOrDisconnect() async {
        let host = StubHost()
        let coordinator = makeCoordinator(host: host, storeName: "code-check", schedule: { _, _ in })
        let phone = String(repeating: "C", count: 64)
        approve(clientID: phone, name: "Owner's iPhone", in: coordinator)
        coordinator.wire()
        let server = coordinator.server
        func hello(on connection: UUID) {
            server.onApprovalRequest?(phone, "Owner's iPhone", "482913", true, connection) { _ in }
        }

        let first = UUID()
        hello(on: first)
        await SuiteWait.until("the alert reaches the host") { host.codeChecks.count == 1 }
        #expect(host.codeChecks.first?.name == "Owner's iPhone")
        #expect(host.codeChecks.first?.code == "482913")
        server.onCommand?("r1", .requestAppIcons(bundleIDs: []), first) { _ in }
        await SuiteWait.until("the first command closes it") { host.withdrawnCodeChecks == [phone] }

        let second = UUID()
        hello(on: second)
        await SuiteWait.until("the reconnect's alert reaches the host") { host.codeChecks.count == 2 }
        server.onClientDisconnected?(second)
        await SuiteWait.until("the close closes it") { host.withdrawnCodeChecks == [phone, phone] }

        let third = UUID()
        hello(on: third)
        await SuiteWait.until("the third alert reaches the host") { host.codeChecks.count == 3 }
        server.onAwaitingConnectionClosed?(third)
        await SuiteWait.until("a refusal before admission closes it") {
            host.withdrawnCodeChecks == [phone, phone, phone]
        }
    }

    // MARK: Icon requests

    /// Turns red if the coordinator answers a phone's second icon request
    /// while the first one's pages are still going out, or keeps refusing
    /// after they are done.
    @Test func aSecondIconRequestWhileOneIsInFlightIsRefused() async {
        let host = StubHost()
        let coordinator = makeCoordinator(host: host, storeName: "icons")
        coordinator.wire()
        let onCommand = coordinator.server.onCommand
        let replies = ReplyLog()
        let phone = UUID()
        func request(_ id: String) {
            onCommand?(id, .requestAppIcons(bundleIDs: ["com.example.app"]), phone) { result in
                DispatchQueue.main.async { replies.results.append(result) }
            }
        }

        request("first")
        await SuiteWait.until("the first icon request is answered") { replies.results.count == 1 }
        request("second")
        await SuiteWait.until("the second icon request is answered") { replies.results.count == 2 }
        #expect(replies.results.map(\.applied) == [true, false])
        #expect(replies.results.last?.refusalReason == "Icons are still being sent. Wait a moment.")
        #expect(host.iconCompletions.count == 1, "the refused request never reached the host")

        host.iconCompletions[0]()
        request("third")
        await SuiteWait.until("the third icon request is answered") { replies.results.count == 3 }
        #expect(replies.results.last?.applied == true, "a finished request frees the phone to ask again")
    }
}
