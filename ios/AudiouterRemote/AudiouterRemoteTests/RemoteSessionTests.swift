// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import Network
import UIKit
import AudiouterProtocol
@testable import AudiouterRemote

/// T12 tests, in two halves:
///
/// - ``CommandSenderCoalescingTests``: the throttle/requestID engine in
///   total isolation — a fake clock advanced by hand, no sockets, no real
///   time, no actors.
/// - ``RemoteSessionTests``: the session wired to a real
///   ``ConnectionController`` driven through a fake ``MacTransport`` (the
///   exact idiom `NetworkingStateTests` uses for T11), proving the whole
///   pipe end to end — snapshot passthrough, drag-bracket ordering,
///   requestID correlation to a toast, and the no-persistence house rule.
///   `RemoteSession` is `@MainActor`, so this half's tests are async and
///   poll (`waitUntilMain`) for the `Task { @MainActor in ... }` hops
///   `ConnectionController`'s background-queue callbacks trigger.
@Suite struct CommandSenderCoalescingTests {

    private final class FakeClock: CommandClock {
        private var time: TimeInterval = 0
        func now() -> TimeInterval { time }
        func advance(by delta: TimeInterval) { time += delta }
    }

    private final class SentLog {
        private(set) var sent: [(command: CompanionCommand, requestID: String)] = []
        func record(_ command: CompanionCommand, _ requestID: String) {
            sent.append((command, requestID))
        }
    }

    @Test func coalescedSendsAreThrottledToAtMost20Hz() {
        let clock = FakeClock()
        let log = SentLog()
        let sender = CommandSender(transport: log.record, clock: clock, makeRequestID: { "id" })

        // 200 rapid sets, 2ms apart in simulated time = 400ms total.
        for i in 0..<200 {
            _ = sender.sendCoalesced(.setDeviceVolume(id: "d1", volume: i), key: "d1")
            clock.advance(by: 0.002)
        }
        // ≤20Hz over 400ms allows at most 9 sends (edges at 0, 50, ..., 400ms).
        #expect(log.sent.count >= 1)
        #expect(log.sent.count <= 9)
    }

    @Test func coalescedSendsResumeOnlyAfterTheThrottleWindowElapses() {
        let clock = FakeClock()
        let log = SentLog()
        let sender = CommandSender(transport: log.record, clock: clock, makeRequestID: { "id" })

        #expect(sender.sendCoalesced(.setDeviceVolume(id: "d1", volume: 1), key: "d1") != nil)
        #expect(sender.sendCoalesced(.setDeviceVolume(id: "d1", volume: 2), key: "d1") == nil, "too soon")
        clock.advance(by: CommandSender.minInterval + 0.001)
        #expect(sender.sendCoalesced(.setDeviceVolume(id: "d1", volume: 3), key: "d1") != nil)
        #expect(log.sent.count == 2)
    }

    @Test func sendFinalAlwaysSendsEvenInsideTheThrottleWindow() {
        let clock = FakeClock()
        let log = SentLog()
        let sender = CommandSender(transport: log.record, clock: clock, makeRequestID: { "id" })

        _ = sender.sendCoalesced(.setDeviceVolume(id: "d1", volume: 1), key: "d1")
        #expect(sender.sendCoalesced(.setDeviceVolume(id: "d1", volume: 2), key: "d1") == nil)
        // Zero time elapsed since the last send — the release must still land.
        _ = sender.sendFinal(.setDeviceVolume(id: "d1", volume: 99), key: "d1")

        #expect(log.sent.count == 2)
        guard case .setDeviceVolume(_, let volume) = log.sent.last!.command else {
            Issue.record("expected setDeviceVolume"); return
        }
        #expect(volume == 99)
    }

    @Test func differentKeysThrottleIndependently() {
        let log = SentLog()
        let sender = CommandSender(transport: log.record, clock: FakeClock(), makeRequestID: { "id" })
        #expect(sender.sendCoalesced(.setDeviceVolume(id: "d1", volume: 1), key: "d1") != nil)
        #expect(sender.sendCoalesced(.setDeviceVolume(id: "d2", volume: 1), key: "d2") != nil)
        #expect(log.sent.count == 2)
    }

    @Test func plainSendIsNeverThrottledAndEachSendGetsAFreshRequestID() {
        let log = SentLog()
        var counter = 0
        let sender = CommandSender(transport: log.record, clock: FakeClock(), makeRequestID: {
            counter += 1
            return "id-\(counter)"
        })
        _ = sender.send(.setMainOutMuted(muted: true))
        _ = sender.send(.setMainOutMuted(muted: true))
        #expect(log.sent.count == 2)
        #expect(log.sent[0].requestID != log.sent[1].requestID)
    }
}

@Suite struct RemoteSessionTests {

    // MARK: - Fake transport (mirrors NetworkingStateTests' FakeTransport)

    private final class FakeTransport: MacTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: (@Sendable (MacTransportEvent) -> Void)?
        private var _sent: [Data] = []

        var events: (@Sendable (MacTransportEvent) -> Void)? {
            get { lock.withLock { _events } }
            set { lock.withLock { _events = newValue } }
        }
        func start(queue: DispatchQueue) {}
        func send(_ data: Data) { lock.withLock { _sent.append(data) } }
        func sendPing(onPong: @escaping @Sendable () -> Void) {}
        func cancel() {}
        var sentFrames: [Data] { lock.withLock { _sent } }
    }

    /// Captures the transport `ConnectionController` creates for its one
    /// connect — a lock-backed box (not a plain `var`) because the factory
    /// closure crosses into `@Sendable` territory.
    private final class TransportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _transport: FakeTransport?
        func store(_ transport: FakeTransport) { lock.withLock { _transport = transport } }
        var transport: FakeTransport? { lock.withLock { _transport } }
    }

    private final class FakeClock: CommandClock {
        private var time: TimeInterval = 0
        func now() -> TimeInterval { time }
        func advance(by delta: TimeInterval) { time += delta }
    }

    // MARK: - Shared fixtures

    private func makeMac() -> DiscoveredMac {
        DiscoveredMac(
            id: "TestMac._audiouter._tcplocal.",
            endpoint: .service(name: "TestMac", type: CompanionProto.serviceType, domain: "local.", interface: nil),
            name: "TestMac",
            protoVersion: CompanionProto.version,
            isIncompatible: false
        )
    }

    private func makeSnapshot(volume: Int = 50) -> Snapshot {
        Snapshot(
            serverName: "TestMac",
            devices: [],
            mainOut: MainOutState(kind: "selected"),
            mainOutMasterVolume: volume,
            mainOutMuted: false,
            groups: [],
            appRoutes: [],
            liveRoutedAppNames: [:],
            addableApps: [],
            localFallbackActive: false,
            settings: SettingsState(
                connectVolume: 25, connectVolumeMin: 0, connectVolumeMax: 100,
                startBufferMs: 2000, startBufferOptionsMs: [1000, 2000, 4000]
            )
        )
    }

    private func encoded(_ message: CompanionMessage) throws -> Data {
        try CompanionEnvelope(message: message).encoded()
    }

    /// Just the `.command` frames, in order — filters out the `hello` every
    /// fake transport also records once it reaches `.ready` (see
    /// `MacConnection.handleTransportEvent`'s `.ready` case), so tests don't
    /// have to hardcode "+1 for hello" against every frame count.
    private func commandMessages(_ frames: [Data]) throws -> [(requestID: String, command: CompanionCommand)] {
        try frames.compactMap {
            guard case .command(let requestID, let command) = try CompanionEnvelope.decode($0).message else { return nil }
            return (requestID, command)
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "RemoteSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Every test's on-ramp: a session already attached to a controller
    /// that's live over a fake transport (RemoteSession is constructed
    /// BEFORE `connect(to:)` so it actually catches the welcome snapshot,
    /// same as production wiring in `AudiouterRemoteApp`). `iconStore` and
    /// `snapshot` are nil-by-default so every existing call site is
    /// unaffected — pass them only for the app-icon tests below.
    @MainActor
    private func makeLiveSession(
        clock: CommandClock = WallCommandClock(),
        iconStore: AppIconStore? = nil,
        snapshot: Snapshot? = nil
    ) throws -> (session: RemoteSession, controller: ConnectionController, transport: FakeTransport, defaults: UserDefaults) {
        let defaults = try makeDefaults()
        let box = TransportBox()
        let controller = ConnectionController(
            defaults: defaults,
            clientName: "TestPhone",
            transportFactory: { _ in
                let transport = FakeTransport()
                box.store(transport)
                return transport
            }
        )
        let session = RemoteSession(controller: controller, iconStore: iconStore, clock: clock)

        controller.connect(to: makeMac())
        controller.queue.sync {}
        let transport = try #require(box.transport)
        try controller.queue.sync {
            transport.events?(.ready)
            transport.events?(.message(try encoded(
                .welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: snapshot ?? makeSnapshot())
            )))
        }
        return (session, controller, transport, defaults)
    }

    /// An `AppIconStore` backed by a scratch directory unique to this test —
    /// never the real `Caches/AppIcons`, and never shared between tests.
    @MainActor
    private func makeIconStore() -> AppIconStore {
        AppIconStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteSessionTests-\(UUID().uuidString)", isDirectory: true))
    }

    /// `makeSnapshot()` plus two app routes and one addable app, all with
    /// distinct bundle IDs, for exercising `requestMissingIcons`.
    private func makeSnapshotWithApps() -> Snapshot {
        var snapshot = makeSnapshot()
        snapshot.appRoutes = [
            AppRouteState(bundleID: "com.example.routeA", displayName: "Route A", destinationKind: "noRedirect", volume: 50, isRunning: true),
            AppRouteState(bundleID: "com.example.routeB", displayName: "Route B", destinationKind: "noRedirect", volume: 50, isRunning: false)
        ]
        snapshot.addableApps = [
            Snapshot.AddableApp(bundleID: "com.example.addable", displayName: "Addable")
        ]
        return snapshot
    }

    /// A tiny, genuinely-decodable PNG — `AppIconStore.store` refuses
    /// anything `UIImage(data:)` can't parse.
    private func makeTestPNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func requestAppIconsCommands(_ frames: [Data]) throws -> [[String]] {
        try commandMessages(frames).compactMap {
            guard case .requestAppIcons(let bundleIDs) = $0.command else { return nil }
            return bundleIDs
        }
    }

    /// Spin the main actor's own executor (not `Thread.sleep`, which
    /// wouldn't let a queued `Task { @MainActor in ... }` job run at all —
    /// see `RemoteSession`'s doc comment on the queue → main-actor hop)
    /// until `condition` holds.
    @MainActor
    private func waitUntilMain(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: - Snapshot passthrough

    @MainActor
    @Test func snapshotPassesThroughFromWelcomeAndEveryLaterState() async throws {
        let (session, controller, transport, _) = try makeLiveSession()
        #expect(await waitUntilMain { session.snapshot == makeSnapshot() })

        let updated = makeSnapshot(volume: 77)
        try controller.queue.sync {
            transport.events?(.message(try encoded(.state(snapshot: updated))))
        }
        #expect(await waitUntilMain { session.snapshot == updated })
    }

    @MainActor
    @Test func connectionStatusTracksTheControllersState() async throws {
        let (session, _, _, _) = try makeLiveSession()
        #expect(await waitUntilMain { session.connectionStatus == .live })
    }

    // MARK: - requestID correlation → toast

    @MainActor
    @Test func aRefusalResultSurfacesTheMacsReasonAsAToast() async throws {
        let (session, controller, transport, _) = try makeLiveSession()
        #expect(await waitUntilMain { session.connectionStatus == .live })

        session.setGroupMuted(id: "g1", muted: true)
        #expect(await waitUntilMain { try! commandMessages(transport.sentFrames).count == 1 })
        let requestID = try commandMessages(transport.sentFrames)[0].requestID

        try controller.queue.sync {
            transport.events?(.message(try encoded(.commandResult(
                requestID: requestID,
                applied: false,
                refusalReason: "Group must have at least one member.",
                autoSwappedCurrentDevice: false
            ))))
        }
        #expect(await waitUntilMain { session.toasts.current != nil })
        #expect(session.toasts.current?.message == "Group must have at least one member.")
    }

    @MainActor
    @Test func anAutoSwapResultSurfacesAToast() async throws {
        let (session, controller, transport, _) = try makeLiveSession()
        #expect(await waitUntilMain { session.connectionStatus == .live })

        session.setDeviceSelected(id: "d1", selected: true)
        #expect(await waitUntilMain { try! commandMessages(transport.sentFrames).count == 1 })
        let requestID = try commandMessages(transport.sentFrames)[0].requestID

        try controller.queue.sync {
            transport.events?(.message(try encoded(.commandResult(
                requestID: requestID, applied: true, refusalReason: nil, autoSwappedCurrentDevice: true
            ))))
        }
        #expect(await waitUntilMain { session.toasts.current?.kind == .autoSwap })
    }

    // MARK: - Slider policy

    @MainActor
    @Test func rapidDeviceVolumeSetsAreCoalescedToAtMost20Hz() async throws {
        let clock = FakeClock()
        let (session, _, transport, _) = try makeLiveSession(clock: clock)
        #expect(await waitUntilMain { session.connectionStatus == .live })

        for i in 0..<200 {
            session.setDeviceVolume(id: "d1", volume: i, isFinal: false)
            clock.advance(by: 0.002) // 200 * 2ms = 400ms simulated
        }
        #expect(await waitUntilMain { !transport.sentFrames.isEmpty })
        // ≤20Hz over 400ms ⇒ at most 9 sends.
        #expect(transport.sentFrames.count <= 9)
    }

    @MainActor
    @Test func theReleaseValueIsAlwaysSentEvenInsideTheCoalescingWindow() async throws {
        let clock = FakeClock()
        let (session, _, transport, _) = try makeLiveSession(clock: clock)
        #expect(await waitUntilMain { session.connectionStatus == .live })

        session.setAppVolume(bundleID: "com.example.app", volume: 10, isFinal: false)
        session.setAppVolume(bundleID: "com.example.app", volume: 20, isFinal: false) // dropped: no time elapsed
        session.setAppVolume(bundleID: "com.example.app", volume: 99, isFinal: true)  // must land regardless

        #expect(await waitUntilMain { try! commandMessages(transport.sentFrames).count == 2 })
        let commands = try commandMessages(transport.sentFrames)
        guard case .setAppVolume(_, let lastVolume) = commands.last!.command else {
            Issue.record("expected setAppVolume"); return
        }
        #expect(lastVolume == 99)
    }

    @MainActor
    @Test func mainOutMasterSliderCoalescesLikeEveryOtherSliderAndAlwaysSendsTheRelease() async throws {
        let clock = FakeClock()
        let (session, _, transport, _) = try makeLiveSession(clock: clock)
        #expect(await waitUntilMain { session.connectionStatus == .live })

        session.setMainOutMasterVolume(10, isFinal: false)
        clock.advance(by: CommandSender.minInterval + 0.001)
        session.setMainOutMasterVolume(20, isFinal: false)
        session.setMainOutMasterVolume(30, isFinal: true)

        // No drag bracket exists (Main is a stateless set): the wire carries
        // exactly the coalesced interior sets plus the always-sent release.
        #expect(await waitUntilMain { try! commandMessages(transport.sentFrames).count == 3 })
        let commands = try commandMessages(transport.sentFrames).map(\.command)

        guard case .setMainOutMasterVolume(30) = commands.last! else {
            Issue.record("the release value must be the last thing on the wire"); return
        }
    }

    // MARK: - No phone-side persistence

    @MainActor
    @Test func drivingEveryKindOfCommandPersistsNothingButTheLastUsedMacID() async throws {
        let (session, _, _, defaults) = try makeLiveSession()
        #expect(await waitUntilMain { session.connectionStatus == .live })

        // Baseline AFTER connecting (so it already includes `lastUsedMacID`
        // plus whatever noise `dictionaryRepresentation()` merges in from
        // the search list) — the real assertion is that driving every kind
        // of command adds nothing on top of this.
        let baseline = Set(defaults.dictionaryRepresentation().keys)

        session.setDeviceSelected(id: "d1", selected: true)
        session.setDeviceVolume(id: "d1", volume: 40, isFinal: true)
        session.setDeviceMuted(id: "d1", muted: true)
        session.setMainOut(MainOutState(kind: "group", groupID: "g1"))
        session.setMainOutMasterVolume(60, isFinal: true)
        session.setMainOutMuted(false)
        session.createGroup(name: "Living Room", memberIDs: ["d1"], iconSymbolName: nil)
        session.updateGroup(GroupState(id: "g1", name: "Living Room", memberIDs: ["d1"], memberVolumes: ["d1": 40], isMuted: false))
        session.deleteGroup(id: "g1")
        session.setGroupMuted(id: "g1", muted: true)
        session.addAppRoute(bundleID: "com.example.app", displayName: "Example")
        session.removeAppRoute(bundleID: "com.example.app")
        session.setAppDestination(bundleID: "com.example.app", kind: "device", deviceID: "d1")
        session.setAppVolume(bundleID: "com.example.app", volume: 55, isFinal: true)
        session.setConnectVolume(30, isFinal: true)
        session.setStartBufferMs(4000)
        session.retryConnection(id: "d1")

        let after = Set(defaults.dictionaryRepresentation().keys)
        #expect(after == baseline,
                "RemoteSession must never persist routing/session state on the phone; new keys: \(after.subtracting(baseline))")
    }

    // MARK: - Late subscriber

    @MainActor
    @Test func aSessionConstructedAfterTheLinkWentLiveStillGetsTheSnapshot() async throws {
        // Live FIRST, RemoteSession second: the welcome is long gone and an
        // idle Mac never rebroadcasts (identical snapshots are suppressed),
        // so only the controller's replay-on-subscribe can populate this.
        let defaults = try makeDefaults()
        let box = TransportBox()
        let controller = ConnectionController(
            defaults: defaults,
            clientName: "TestPhone",
            transportFactory: { _ in
                let transport = FakeTransport()
                box.store(transport)
                return transport
            }
        )
        controller.connect(to: makeMac())
        controller.queue.sync {}
        let transport = try #require(box.transport)
        try controller.queue.sync {
            transport.events?(.ready)
            transport.events?(.message(try encoded(
                .welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: makeSnapshot())
            )))
        }

        let session = RemoteSession(controller: controller)
        #expect(await waitUntilMain { session.snapshot == makeSnapshot() },
                "a late subscriber on a healthy idle link must not render blank forever")
        #expect(await waitUntilMain { session.connectionStatus == .live })
    }

    // MARK: - FIFO event delivery

    @MainActor
    @Test func rapidSnapshotsLandInOrderAndTheNewestSticks() async throws {
        let (session, controller, transport, _) = try makeLiveSession()
        #expect(await waitUntilMain { session.connectionStatus == .live })

        // A burst of distinct snapshots delivered back-to-back on the
        // controller queue: FIFO main-queue delivery means the LAST one is
        // what remains — an unordered Task-per-event hop could leave a
        // stale interior value stuck.
        try controller.queue.sync {
            for volume in 1...20 {
                transport.events?(.message(try encoded(.state(snapshot: makeSnapshot(volume: volume)))))
            }
        }
        #expect(await waitUntilMain { session.snapshot == makeSnapshot(volume: 20) })
        // And it STAYS the newest — no late out-of-order delivery reverts it.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.snapshot == makeSnapshot(volume: 20))
    }

    // MARK: - Per-request timeout

    @MainActor
    @Test func anUnansweredCommandSurfacesAToastInsteadOfVanishing() async throws {
        let (session, _, transport, _) = try makeLiveSession()
        #expect(await waitUntilMain { session.connectionStatus == .live })
        session.commandTimeout = 0.05

        session.setDeviceMuted(id: "d1", muted: true)
        #expect(await waitUntilMain { try! commandMessages(transport.sentFrames).count == 1 })

        // No commandResult ever arrives (the Mac app is hung; the socket —
        // and therefore the ping/pong layer — still looks healthy).
        #expect(await waitUntilMain { session.toasts.current != nil },
                "silence past the deadline must be surfaced, not swallowed")
        #expect(session.toasts.current?.message == RemoteSession.commandTimeoutToastText)
    }

    @MainActor
    @Test func anAnsweredCommandNeverFiresTheTimeoutToast() async throws {
        let (session, controller, transport, _) = try makeLiveSession()
        #expect(await waitUntilMain { session.connectionStatus == .live })
        session.commandTimeout = 0.1

        session.setDeviceMuted(id: "d1", muted: true)
        #expect(await waitUntilMain { try! commandMessages(transport.sentFrames).count == 1 })
        let requestID = try commandMessages(transport.sentFrames)[0].requestID
        try controller.queue.sync {
            transport.events?(.message(try encoded(.commandResult(
                requestID: requestID, applied: true, refusalReason: nil, autoSwappedCurrentDevice: false
            ))))
        }

        // Outlive the deadline: the answered request must not toast.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(session.toasts.current == nil,
                "an answered command must clear its pending-timeout tracking")
    }

    @MainActor
    @Test func aDisconnectClearsPendingTimeoutsAndTheSnapshot() async throws {
        let (session, controller, transport, _) = try makeLiveSession()
        #expect(await waitUntilMain { session.snapshot != nil })
        session.commandTimeout = 0.1

        session.setDeviceMuted(id: "d1", muted: true)
        #expect(await waitUntilMain { try! commandMessages(transport.sentFrames).count == 1 })

        controller.queue.sync { transport.events?(.failed("socket died")) }
        #expect(await waitUntilMain {
            if case .disconnected = session.connectionStatus { return true }
            return false
        })
        #expect(session.snapshot == nil,
                "the staleness contract: no snapshot may be rendered after a disconnect")

        // The in-flight command's deadline passes AFTER the disconnect: the
        // disconnect is the surface — no redundant timeout toast on top.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(session.toasts.current == nil)
    }

    // MARK: - T24: approval flow surface (what the Connect tab renders)

    /// A session whose controller is mid-handshake (hello sent, nothing
    /// answered yet) — the on-ramp for driving approval-flow frames.
    @MainActor
    private func makeHandshakingSession() throws -> (session: RemoteSession, controller: ConnectionController, transport: FakeTransport) {
        let defaults = try makeDefaults()
        let box = TransportBox()
        let controller = ConnectionController(
            defaults: defaults,
            clientName: "TestPhone",
            transportFactory: { _ in
                let transport = FakeTransport()
                box.store(transport)
                return transport
            }
        )
        let session = RemoteSession(controller: controller)
        controller.connect(to: makeMac())
        controller.queue.sync {}
        let transport = try #require(box.transport)
        controller.queue.sync { transport.events?(.ready) }
        return (session, controller, transport)
    }

    @MainActor
    @Test func awaitingApprovalSurfacesAsAWaitingStateNotAnError() async throws {
        let (session, controller, transport) = try makeHandshakingSession()
        try controller.queue.sync { transport.events?(.message(try encoded(.awaitingApproval))) }

        #expect(await waitUntilMain { session.connectionStatus == .awaitingApproval })
        #expect(session.connectionStatus.approvalStatus == .waitingForApproval)
        #expect(session.toasts.current == nil, "waiting is healthy — no error surface")

        // The Mac's user pressed Allow: the late welcome lands normally.
        try controller.queue.sync {
            transport.events?(.message(try encoded(
                .welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: makeSnapshot())
            )))
        }
        #expect(await waitUntilMain { session.connectionStatus == .live })
        #expect(session.snapshot == makeSnapshot())
        #expect(session.connectionStatus.approvalStatus == nil)
    }

    @MainActor
    @Test func deniedAndTimedOutAreDistinguishableWithGuidance() async throws {
        let (session, controller, transport) = try makeHandshakingSession()
        try controller.queue.sync { transport.events?(.message(try encoded(.awaitingApproval))) }
        try controller.queue.sync { transport.events?(.message(try encoded(.goodbye(reason: "notApproved")))) }

        #expect(await waitUntilMain { session.connectionStatus.approvalStatus == .denied })

        // The three surfaces are distinct AND carry human-readable copy.
        let statuses: [ApprovalStatus] = [.waitingForApproval, .denied, .promptTimedOut]
        #expect(Set(statuses.map(\.headline)).count == 3)
        #expect(Set(statuses.map(\.guidance)).count == 3)
        #expect(ApprovalStatus.denied.guidance.contains("Settings"),
                "denial recovery lives in the Mac's Settings — the copy must point there")
    }

    // MARK: - T11: app icon requests

    @MainActor
    @Test func snapshotWithAppsRequestsMissingIconsRoutesFirst() async throws {
        let iconStore = makeIconStore()
        let snapshot = makeSnapshotWithApps()
        let (session, _, transport, _) = try makeLiveSession(iconStore: iconStore, snapshot: snapshot)

        // Precondition before behavior: the welcome snapshot must land at
        // all, or the icon request can't be expected — and its absence is a
        // different bug than a broken request policy.
        #expect(await waitUntilMain { session.snapshot != nil },
                "the welcome snapshot never reached the session")

        #expect(await waitUntilMain { !(try! requestAppIconsCommands(transport.sentFrames)).isEmpty })
        let requests = try requestAppIconsCommands(transport.sentFrames)
        #expect(requests.count == 1)
        // `first`, never `[0]`: a failed count expectation above must fail
        // this test, not crash the whole suite process on an empty subscript.
        let request = try #require(requests.first)
        #expect(request == ["com.example.routeA", "com.example.routeB", "com.example.addable"],
                "routes fill the visible Apps tab before the Add sheet's addable apps")
    }

    @MainActor
    @Test func anIdenticalLaterSnapshotDoesNotReRequestTheSameIcons() async throws {
        let iconStore = makeIconStore()
        let snapshot = makeSnapshotWithApps()
        let (session, controller, transport, _) = try makeLiveSession(iconStore: iconStore, snapshot: snapshot)
        // The session IS the requester: discarded, ARC frees it and every
        // [weak self] callback goes nil before the first request can send.
        defer { withExtendedLifetime(session) {} }
        #expect(await waitUntilMain { !(try! requestAppIconsCommands(transport.sentFrames)).isEmpty })

        try controller.queue.sync {
            transport.events?(.message(try encoded(.state(snapshot: snapshot))))
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try requestAppIconsCommands(transport.sentFrames).count == 1,
                "a snapshot with nothing new to ask for must not re-request")
    }

    @MainActor
    @Test func anAppIconsFrameWithARealPNGLandsInTheInjectedStore() async throws {
        let iconStore = makeIconStore()
        let snapshot = makeSnapshotWithApps()
        let (session, controller, transport, _) = try makeLiveSession(iconStore: iconStore, snapshot: snapshot)
        // The session IS the requester: discarded, ARC frees it and every
        // [weak self] callback goes nil before the first request can send.
        defer { withExtendedLifetime(session) {} }
        #expect(await waitUntilMain { !(try! requestAppIconsCommands(transport.sentFrames)).isEmpty })

        let png = makeTestPNG()
        try controller.queue.sync {
            transport.events?(.message(try encoded(.appIcons(
                page: 1, pageCount: 1,
                icons: [AppIconPayload(bundleID: "com.example.routeA", png: png)]
            ))))
        }
        #expect(await waitUntilMain { iconStore.image(for: "com.example.routeA") != nil })
    }

    @MainActor
    @Test func aNilIconPayloadStoresNothingAndIsNotReRequested() async throws {
        let iconStore = makeIconStore()
        let snapshot = makeSnapshotWithApps()
        let (session, controller, transport, _) = try makeLiveSession(iconStore: iconStore, snapshot: snapshot)
        // The session IS the requester: discarded, ARC frees it and every
        // [weak self] callback goes nil before the first request can send.
        defer { withExtendedLifetime(session) {} }
        #expect(await waitUntilMain { !(try! requestAppIconsCommands(transport.sentFrames)).isEmpty })

        try controller.queue.sync {
            transport.events?(.message(try encoded(.appIcons(
                page: 1, pageCount: 1,
                icons: [AppIconPayload(bundleID: "com.example.routeA", png: nil)]
            ))))
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(iconStore.image(for: "com.example.routeA") == nil,
                "a definitive nil reply must store nothing")

        try controller.queue.sync {
            transport.events?(.message(try encoded(.state(snapshot: snapshot))))
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try requestAppIconsCommands(transport.sentFrames).count == 1,
                "a bundle ID answered with nil must not be re-asked this process")
    }
}
