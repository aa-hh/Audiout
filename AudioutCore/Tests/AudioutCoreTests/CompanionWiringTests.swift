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

    /// Decisions the approval gate hands back on main.
    private final class DecisionLog: @unchecked Sendable {
        var value: [CompanionServer.ApprovalDecision] = []
    }

    /// Prompts are answered Allow and follow one another at once, so a test
    /// can approve several phones in a row without wiring the coordinator;
    /// ``CompanionCoordinator/wire()`` hands prompts to the host instead.
    /// The Allow switch is off unless `allowRemoteControl` says otherwise, so
    /// the server never tries to start by accident.
    private func makeCoordinator(host: StubHost, storeName: String,
                                 identityStore: RefusingIdentityStore = RefusingIdentityStore(),
                                 allowRemoteControl: Bool = false,
                                 schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil)
        -> CompanionCoordinator {
        let directory = scratchDir.appendingPathComponent(storeName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let approvals = CompanionApprovalController(
            store: CompanionApprovalStore(directory: directory),
            schedule: schedule ?? { _, job in job() })
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
            settings: {
                let settings = AppSettings(defaults: makeDefaults())
                settings.allowRemoteControl = allowRemoteControl
                return settings
            }(),
            excludedBundleIDs: { [] },
            speakerLibrary: SpeakerLibraryController(store: SpeakerLibraryStore(directory: directory),
                                                     loadPersisted: false),
            serverName: "TestMac",
            server: CompanionServer(),
            approvals: approvals,
            identityStore: identityStore,
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

    // MARK: Pairing without a window

    /// Turns red if the server needs an approved phone (or anything but the
    /// Allow switch) before it starts: a Mac nobody has paired with must be
    /// findable, or no new phone can ask. The identity store refuses, so the
    /// count of identity loads is how far the start got.
    @Test func theServerStartsWithTheSwitchOnAndNoPhoneApproved() {
        let off = RefusingIdentityStore()
        makeCoordinator(host: StubHost(), storeName: "switch-off", identityStore: off).wire()
        #expect(off.loads == 0, "switch off: the server never tries to start")

        let on = RefusingIdentityStore()
        let coordinator = makeCoordinator(host: StubHost(), storeName: "switch-on", identityStore: on,
                                          allowRemoteControl: true)
        coordinator.wire()
        #expect(coordinator.approvals.approvals.isEmpty)
        #expect(on.loads == 1, "switch on and no phone approved: the server tries to start")
    }

    /// Turns red if a hello from an unknown phone stops reaching the host's
    /// Allow prompt through the wired coordinator, with nothing opened on the
    /// Mac first.
    @Test func anUnknownPhonesHelloRaisesThePromptWithNothingOpened() async {
        let host = StubHost()
        host.answersPromptsAtOnce = false
        let coordinator = makeCoordinator(host: host, storeName: "no-window")
        coordinator.wire()
        let decisions = DecisionLog()
        coordinator.server.onApprovalRequest?(String(repeating: "D", count: 64), "iPhone", "482913") {
            decisions.value.append($0)
        }

        await SuiteWait.until("the prompt reaches the host") { host.promptCodes == ["482913"] }
        #expect(decisions.value == [.pending])
        host.openPrompts.first?(true)
        #expect(decisions.value == [.pending, .approved])
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
