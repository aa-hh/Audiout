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

        func presentApprovalPrompt(clientID: String, clientName: String,
                                   respond: @escaping (Bool) -> Void) {
            respond(true)
        }
        func withdrawApprovalPrompt(clientID: String) {}
        func runningApplications() -> [(bundleID: String, displayName: String)] { [] }
        func serveAppIconPages(_ requested: [String], to clientID: UUID) {}
        func devices() -> [Device] { [] }
        func symbolName(for device: Device) -> String { "hifispeaker" }
        func routedAppNames() -> [String: [String]] { [:] }
        func clientCountDidChange(_ count: Int) { clientCounts.append(count) }
        func alignmentRunStarted(deviceID: String) {}
        func alignmentMoved(deviceID: String, byMs: Double) {}
        var isTerminating: Bool { false }
        func log(_ message: String) {}
    }

    private func makeCoordinator(host: StubHost, storeName: String) -> CompanionCoordinator {
        let directory = scratchDir.appendingPathComponent(storeName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let approvals = CompanionApprovalController(
            store: CompanionApprovalStore(directory: directory))
        approvals.presentPrompt = { _, _, respond in respond(true) }
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
            serverName: "TestMac",
            server: CompanionServer(),
            approvals: approvals,
            host: host)
    }

    private func approve(clientID: String, name: String, in coordinator: CompanionCoordinator) {
        coordinator.approvals.handleRequest(clientID: clientID, clientName: name, decide: { _ in })
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
}
