// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import Network
import AudiouterProtocol
@testable import AudiouterRemote

/// State-logic tests for the T11 networking layer, run entirely without
/// sockets: backoff math and the permission-denial heuristic are pure;
/// `MacConnection`/`ConnectionController` are driven through the
/// `MacTransport` seam with a fake. Everything network-real (Bonjour
/// browse, resolve probe, WebSocket interop against the Mac's
/// `CompanionServer`) is deferred to the T18 simulator gate.
@Suite struct NetworkingStateTests {

    // MARK: - Shared plumbing

    /// Spin (not block) until `condition` holds — the codebase's
    /// `waitUntil` idiom, needed only where a DispatchWorkItem delay is in
    /// play; direct transitions are driven synchronously via `queue.sync`.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    private final class FakeTransport: MacTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: (@Sendable (MacTransportEvent) -> Void)?
        private var _sent: [Data] = []
        private var _pongs: [@Sendable () -> Void] = []
        private var _started = false
        private var _cancelled = false

        var events: (@Sendable (MacTransportEvent) -> Void)? {
            get { lock.withLock { _events } }
            set { lock.withLock { _events = newValue } }
        }
        func start(queue: DispatchQueue) { lock.withLock { _started = true } }
        func send(_ data: Data) { lock.withLock { _sent.append(data) } }
        func sendPing(onPong: @escaping @Sendable () -> Void) {
            lock.withLock { _pongs.append(onPong) }
        }
        func cancel() { lock.withLock { _cancelled = true } }

        var started: Bool { lock.withLock { _started } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        var sentFrames: [Data] { lock.withLock { _sent } }
        var pingCount: Int { lock.withLock { _pongs.count } }
        /// Answer the oldest outstanding ping (caller must be on the
        /// connection's queue, matching the transport contract).
        func pong() {
            let handler = lock.withLock { _pongs.isEmpty ? nil : _pongs.removeFirst() }
            handler?()
        }
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [MacConnectionEvent] = []
        func append(_ event: MacConnectionEvent) { lock.withLock { _events.append(event) } }
        var events: [MacConnectionEvent] { lock.withLock { _events } }
        var snapshots: [Snapshot] {
            events.compactMap {
                switch $0 {
                case .welcome(_, let s), .snapshot(let s): return s
                default: return nil
                }
            }
        }
    }

    private func makeMac(id: String = "TestMac._audiouter._tcplocal.", name: String = "TestMac") -> DiscoveredMac {
        DiscoveredMac(
            id: id,
            endpoint: .service(name: name, type: CompanionProto.serviceType, domain: "local.", interface: nil),
            name: name,
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

    private func encoded(_ message: CompanionMessage, v: Int = CompanionProto.version) throws -> Data {
        try CompanionEnvelope(message: message, v: v).encoded()
    }

    /// A connection wired to a fake transport, its `start()` already
    /// flushed so the transport's `events` hook is installed.
    private func makeConnection() -> (MacConnection, FakeTransport, DispatchQueue, EventLog) {
        let queue = DispatchQueue(label: "NetworkingStateTests.connection")
        let transport = FakeTransport()
        let log = EventLog()
        let conn = MacConnection(mac: makeMac(), transport: transport, clientName: "TestPhone", queue: queue)
        conn.onEvent = { log.append($0) }
        conn.start()
        queue.sync {} // flush startOnQueue
        return (conn, transport, queue, log)
    }

    /// Drive the connection all the way to `.live`.
    private func makeLiveConnection() throws -> (MacConnection, FakeTransport, DispatchQueue, EventLog) {
        let (conn, transport, queue, log) = makeConnection()
        let welcome = try encoded(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: makeSnapshot()))
        queue.sync {
            transport.events?(.ready)
            transport.events?(.message(welcome))
        }
        try #require(queue.sync { conn.state } == .live)
        return (conn, transport, queue, log)
    }

    // MARK: - Backoff schedule

    @Test func backoffScheduleMirrorsNativeDiscovery() {
        let delays = (0...6).map { NetworkBackoff.delay(afterAttempt: $0) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test func backoffNeverExceedsTheCap() {
        for attempt in 0...100 {
            #expect(NetworkBackoff.delay(afterAttempt: attempt) <= NetworkBackoff.maxSeconds)
        }
    }

    // MARK: - Permission-denial heuristic

    @Test func denialIsSuspectedOnlyAfterItPersistsPastTheThreshold() {
        var detector = PermissionDenialDetector()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t0)
        #expect(!detector.isSuspected(at: t0))
        #expect(!detector.isSuspected(at: t0.addingTimeInterval(2.9)))
        #expect(detector.isSuspected(at: t0.addingTimeInterval(3.1)))
    }

    @Test func aDifferentWaitingErrorClearsThePendingDenial() {
        var detector = PermissionDenialDetector()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t0)
        detector.browserWaiting(dnsErrorCode: -65563, at: t0.addingTimeInterval(1))
        #expect(!detector.isSuspected(at: t0.addingTimeInterval(10)))
    }

    @Test func nonDenialErrorsNeverSuspect() {
        var detector = PermissionDenialDetector()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        detector.browserWaiting(dnsErrorCode: -65563, at: t0)
        detector.browserWaiting(dnsErrorCode: nil, at: t0.addingTimeInterval(1))
        #expect(!detector.isSuspected(at: t0.addingTimeInterval(60)))
    }

    @Test func clearingRestartsTheDenialClock() {
        var detector = PermissionDenialDetector()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t0)
        detector.cleared()
        #expect(!detector.isSuspected(at: t0.addingTimeInterval(10)))

        let t1 = t0.addingTimeInterval(20)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t1)
        #expect(!detector.isSuspected(at: t1.addingTimeInterval(2)))
        #expect(detector.isSuspected(at: t1.addingTimeInterval(4)))
    }

    @Test func repeatedDenialEventsKeepTheOriginalStart() {
        var detector = PermissionDenialDetector()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t0)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t0.addingTimeInterval(2))
        #expect(detector.isSuspected(at: t0.addingTimeInterval(3.5)))
    }

    // MARK: - MacConnection state machine

    @Test func readySendsHelloAndMovesToHandshaking() throws {
        let (conn, transport, queue, _) = makeConnection()
        #expect(queue.sync { conn.state } == .connecting)
        #expect(transport.started)

        queue.sync { transport.events?(.ready) }
        #expect(queue.sync { conn.state } == .handshaking)

        let frames = transport.sentFrames
        try #require(frames.count == 1)
        let hello = try CompanionEnvelope.decode(frames[0])
        #expect(hello.message == .hello(clientName: "TestPhone", protoVersion: CompanionProto.version))
        #expect(hello.v == CompanionProto.version)
    }

    @Test func welcomeMovesToLiveAndDeliversItsSnapshot() throws {
        let (conn, transport, queue, log) = makeConnection()
        let snapshot = makeSnapshot(volume: 42)
        queue.sync { transport.events?(.ready) }
        try queue.sync {
            transport.events?(.message(try encoded(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: snapshot))))
        }
        #expect(queue.sync { conn.state } == .live)
        #expect(log.snapshots == [snapshot])
    }

    @Test func stateMessageDeliversASnapshot() throws {
        // `conn` must stay referenced: the transport holds it weakly (as the
        // real controller-owned wiring does), so dropping it kills delivery.
        let (conn, transport, queue, log) = try makeLiveConnection()
        let snapshot = makeSnapshot(volume: 77)
        try queue.sync { transport.events?(.message(try encoded(.state(snapshot: snapshot)))) }
        #expect(log.snapshots.last == snapshot)
        #expect(queue.sync { conn.state } == .live)
    }

    @Test func commandResultIsDeliveredTyped() throws {
        let (conn, transport, queue, log) = try makeLiveConnection()
        try queue.sync {
            transport.events?(.message(try encoded(.commandResult(
                requestID: "req-9", applied: false, refusalReason: "nope", autoSwappedCurrentDevice: true
            ))))
        }
        let match = log.events.contains {
            if case .commandResult("req-9", false, "nope", true) = $0 { return true }
            return false
        }
        #expect(match)
        #expect(queue.sync { conn.state } == .live)
    }

    @Test func goodbyeDisconnectsWithTheServersReason() throws {
        let (conn, transport, queue, _) = try makeLiveConnection()
        try queue.sync { transport.events?(.message(try encoded(.goodbye(reason: "disabled")))) }
        #expect(queue.sync { conn.state } == .disconnected(.goodbye("disabled")))
        #expect(transport.cancelled)
    }

    @Test func newerEnvelopeVersionDisconnectsAsIncompatible() throws {
        let (conn, transport, queue, _) = makeConnection()
        queue.sync { transport.events?(.ready) }
        let newer = try encoded(
            .welcome(serverName: "Future", protoVersion: CompanionProto.version + 1, snapshot: makeSnapshot()),
            v: CompanionProto.version + 1
        )
        queue.sync { transport.events?(.message(newer)) }
        #expect(queue.sync { conn.state } == .disconnected(.incompatiblePeer))
        #expect(transport.cancelled)
    }

    @Test func malformedFrameDisconnects() throws {
        let (conn, transport, queue, _) = try makeLiveConnection()
        queue.sync { transport.events?(.message(Data("definitely not json".utf8))) }
        #expect(queue.sync { conn.state } == .disconnected(.failed("malformed frame")))
    }

    @Test func transportFailureDisconnects() throws {
        let (conn, transport, queue, _) = try makeLiveConnection()
        queue.sync { transport.events?(.failed("socket died")) }
        #expect(queue.sync { conn.state } == .disconnected(.failed("socket died")))
    }

    @Test func unansweredPingsKillTheConnectionAfterTwoMisses() throws {
        let (conn, transport, queue, _) = try makeLiveConnection()
        queue.sync { conn.keepaliveTick() } // miss 1
        queue.sync { conn.keepaliveTick() } // miss 2
        #expect(queue.sync { conn.state } == .live)
        #expect(transport.pingCount == 2)
        queue.sync { conn.keepaliveTick() } // two misses outstanding → dead
        #expect(queue.sync { conn.state } == .disconnected(.keepaliveTimeout))
        #expect(transport.pingCount == 2, "a dead connection must not keep pinging")
    }

    @Test func aPongResetsTheMissCount() throws {
        let (conn, transport, queue, _) = try makeLiveConnection()
        for _ in 0..<6 {
            queue.sync {
                conn.keepaliveTick()
                transport.pong()
            }
        }
        #expect(queue.sync { conn.state } == .live)
        #expect(queue.sync { conn.missedPings } == 0)
    }

    @Test func quietCloseDisconnectsWithoutAnErrorAndIgnoresLaterEvents() throws {
        let (conn, transport, queue, log) = try makeLiveConnection()
        conn.close() // .closedByUs
        queue.sync {}
        #expect(queue.sync { conn.state } == .disconnected(.closedByUs))
        #expect(transport.cancelled)

        // No zombie: nothing after disconnect changes state or emits events.
        let eventCount = log.events.count
        queue.sync {
            transport.events?(.failed("late failure")) // a real transport would be detached; belt and braces
            conn.keepaliveTick()
        }
        queue.sync { transport.events?(.ready) }
        #expect(queue.sync { conn.state } == .disconnected(.closedByUs))
        #expect(log.events.count == eventCount)
    }

    @Test func commandsAreOnlySentWhileLive() throws {
        let (conn, transport, queue, _) = makeConnection()
        conn.send(command: .beginMainOutDrag, requestID: "early")
        queue.sync {}
        #expect(transport.sentFrames.isEmpty, "no frames before the transport is even ready")

        queue.sync { transport.events?(.ready) } // hello goes out
        conn.send(command: .beginMainOutDrag, requestID: "handshaking")
        queue.sync {}
        #expect(transport.sentFrames.count == 1, "commands must not be sent before welcome")

        try queue.sync {
            transport.events?(.message(try encoded(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: makeSnapshot()))))
        }
        conn.send(command: .setDeviceVolume(id: "dev-1", volume: 30), requestID: "req-1")
        queue.sync {}
        let frames = transport.sentFrames
        try #require(frames.count == 2)
        let sent = try CompanionEnvelope.decode(frames[1])
        #expect(sent.message == .command(requestID: "req-1", command: .setDeviceVolume(id: "dev-1", volume: 30)))
    }

    // MARK: - ConnectionController

    private final class FactoryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _transports: [FakeTransport] = []
        func append(_ transport: FakeTransport) { lock.withLock { _transports.append(transport) } }
        var transports: [FakeTransport] { lock.withLock { _transports } }
        var count: Int { lock.withLock { _transports.count } }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "NetworkingStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeController(defaults: UserDefaults) -> (ConnectionController, FactoryLog) {
        let factory = FactoryLog()
        let controller = ConnectionController(
            defaults: defaults,
            clientName: "TestPhone",
            transportFactory: { _ in
                let transport = FakeTransport()
                factory.append(transport)
                return transport
            }
        )
        // NOTE: `start()` is never called — no browser, no path monitor, no
        // sockets. Discovery is driven through `handleMacsChanged`.
        return (controller, factory)
    }

    /// Drive the controller's current connection to `.live` through its fake
    /// transport.
    private func goLive(_ controller: ConnectionController, transport: FakeTransport) throws {
        try controller.queue.sync {
            transport.events?(.ready)
            transport.events?(.message(try encoded(
                .welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: makeSnapshot())
            )))
        }
        try #require(controller.queue.sync { controller.connectionState } == .live)
    }

    @Test func connectPersistsTheLastUsedMacIDAndOnlyThat() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.connect(to: mac)
        controller.queue.sync {}
        #expect(factory.count == 1)
        #expect(controller.queue.sync { controller.connectionState } == .connecting)
        #expect(defaults.string(forKey: "lastUsedMacID") == mac.id)

        // A fresh controller over the same defaults remembers the Mac.
        let (rebornController, _) = makeController(defaults: defaults)
        #expect(rebornController.lastUsedMacID == mac.id)
    }

    @Test func welcomeSnapshotIsStoredAndRepublished() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let received = LockedSnapshots()
        controller.onSnapshot = { received.append($0) }

        controller.connect(to: makeMac())
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])

        #expect(controller.queue.sync { controller.latestSnapshot } == makeSnapshot())
        #expect(received.all == [makeSnapshot()])
    }

    private final class LockedSnapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [Snapshot] = []
        func append(_ snapshot: Snapshot) { lock.withLock { _all.append(snapshot) } }
        var all: [Snapshot] { lock.withLock { _all } }
    }

    @Test func backgroundTearsDownQuietlyAndForegroundEagerlyReconnects() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])

        controller.enterBackground()
        controller.queue.sync {}
        #expect(controller.queue.sync { controller.connectionState } == .disconnected(.closedByUs),
                "background teardown must read as the quiet, expected reason")
        #expect(factory.transports[0].cancelled)
        #expect(factory.count == 1, "no reconnect may be attempted while backgrounded")

        controller.enterForeground()
        // Eager first attempt = 0-delay work item; give it a beat.
        #expect(waitUntil { factory.count == 2 },
                "foreground must eagerly redial the last-used Mac")
        #expect(controller.queue.sync { controller.connectionState } == .connecting)
    }

    @Test func dropWhileForegroundedReconnectsWhenTheMacIsStillBrowsed() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])

        controller.queue.sync { factory.transports[0].events?(.failed("socket died")) }
        #expect(waitUntil { factory.count == 2 },
                "an unexpected drop with the Mac still browsed must reconnect")
    }

    @Test func dropDoesNotReconnectUntilTheMacIsBrowsedAgain() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        // Connected, but the browse list is (still) empty.
        controller.connect(to: mac)
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])
        controller.queue.sync { factory.transports[0].events?(.failed("socket died")) }
        controller.queue.sync {}
        #expect(factory.count == 1, "no reconnect while the Mac is not browsed")

        // The Mac reappears → the pending desire fires.
        controller.queue.sync { controller.handleMacsChanged([mac]) }
        #expect(waitUntil { factory.count == 2 },
                "the Mac reappearing in the browse list must trigger the reconnect")
    }

    @Test func explicitDisconnectStopsAutoReconnect() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])

        controller.disconnect()
        controller.queue.sync {}
        #expect(controller.queue.sync { controller.connectionState } == .disconnected(.closedByUs))

        // Neither the browse list refreshing nor time passing may redial.
        controller.queue.sync { controller.handleMacsChanged([mac]) }
        Thread.sleep(forTimeInterval: 0.1)
        controller.queue.sync {}
        #expect(factory.count == 1, "a user who hung up must not be auto-redialed")
        // The Mac stays remembered for the next explicit connect/foreground.
        #expect(defaults.string(forKey: "lastUsedMacID") == mac.id)
    }
}
