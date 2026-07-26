// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import Network
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
        _ = sender.send(.beginMainOutDrag)
        _ = sender.send(.beginMainOutDrag)
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
    /// same as production wiring in `AudiouterRemoteApp`).
    @MainActor
    private func makeLiveSession(
        clock: CommandClock = WallCommandClock()
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
        let session = RemoteSession(controller: controller, clock: clock)

        controller.connect(to: makeMac())
        controller.queue.sync {}
        let transport = try #require(box.transport)
        try controller.queue.sync {
            transport.events?(.ready)
            transport.events?(.message(try encoded(
                .welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: makeSnapshot())
            )))
        }
        return (session, controller, transport, defaults)
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
    @Test func mainOutDragBracketsWrapTheCoalescedVolumeStream() async throws {
        let clock = FakeClock()
        let (session, _, transport, _) = try makeLiveSession(clock: clock)
        #expect(await waitUntilMain { session.connectionStatus == .live })

        session.beginMainOutDrag()
        session.setMainOutMasterVolume(10, isFinal: false)
        clock.advance(by: CommandSender.minInterval + 0.001)
        session.setMainOutMasterVolume(20, isFinal: false)
        session.setMainOutMasterVolume(30, isFinal: true)
        session.endMainOutDrag()

        #expect(await waitUntilMain { try! commandMessages(transport.sentFrames).count == 5 })
        let commands = try commandMessages(transport.sentFrames).map(\.command)

        guard case .beginMainOutDrag = commands.first! else {
            Issue.record("begin must be sent before any set"); return
        }
        guard case .endMainOutDrag = commands.last! else {
            Issue.record("end must be sent after every set"); return
        }
        let releaseLanded = commands.dropFirst().dropLast().contains {
            if case .setMainOutMasterVolume(30) = $0 { return true }
            return false
        }
        #expect(releaseLanded, "the release value must reach the wire between begin and end")
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
        session.beginMainOutDrag()
        session.setMainOutMasterVolume(60, isFinal: true)
        session.endMainOutDrag()
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
}
