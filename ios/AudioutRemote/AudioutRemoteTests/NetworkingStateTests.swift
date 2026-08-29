// Copyright (c) 2026 ahh. All rights reserved.

import Foundation
import Testing
import Network
import AudioutProtocol
@testable import AudioutRemote

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

    private func makeMac(id: String = "TestMac._audiout._tcplocal.", name: String = "TestMac") -> DiscoveredMac {
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

    /// Fixed valid identity for direct `MacConnection` tests (the
    /// controller-level tests exercise the real load-or-create path).
    static let testClientID = "A6E1F0C4-6A4B-4E7B-9D2C-1B2F3A4C5D6E"

    /// A connection wired to a fake transport, its `start()` already
    /// flushed so the transport's `events` hook is installed.
    private func makeConnection() -> (MacConnection, FakeTransport, DispatchQueue, EventLog) {
        let queue = DispatchQueue(label: "NetworkingStateTests.connection")
        let transport = FakeTransport()
        let log = EventLog()
        let conn = MacConnection(mac: makeMac(), transport: transport, clientID: Self.testClientID, clientName: "TestPhone", queue: queue)
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

    // MARK: - wsURL (probe → dial handoff)

    @Test func wsURLDropsTheIPv4InterfaceScope() throws {
        // Live-caught (iOS 27 sim → real Mac): the probe's resolved address
        // arrives as "192.168.4.84%en0" — a bare "%" is an illegal URL
        // escape, so keeping it makes URL(string:) nil and the whole connect
        // dies as "no usable IPv4 address" without ever dialing.
        let host = NWEndpoint.Host.ipv4(try #require(IPv4Address("192.168.4.84%en0")))
        let url = ResolvedWebSocketTransport.wsURL(host: host, port: 53224)
        #expect(url?.absoluteString == "ws://192.168.4.84:53224/")
    }

    @Test func wsURLPlainIPv4AndNameStillBuild() throws {
        let plain = NWEndpoint.Host.ipv4(try #require(IPv4Address("10.0.0.7")))
        #expect(ResolvedWebSocketTransport.wsURL(host: plain, port: 1)?.absoluteString == "ws://10.0.0.7:1/")
        #expect(ResolvedWebSocketTransport.wsURL(host: .name("mac.local", nil), port: 2)?.absoluteString == "ws://mac.local:2/")
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
        let threshold = PermissionDenialDetector.threshold
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t0)
        #expect(!detector.isSuspected(at: t0))
        #expect(!detector.isSuspected(at: t0.addingTimeInterval(threshold - 0.1)))
        #expect(detector.isSuspected(at: t0.addingTimeInterval(threshold + 0.1)))
    }

    @Test func theThresholdOutlastsAUserReadingThePermissionAlert() {
        // -65570 is emitted the whole time the system permission prompt is
        // on screen; calling "denied" in under a few seconds accuses a user
        // who is still reading. 3s was measured too short — pin the floor.
        #expect(PermissionDenialDetector.threshold >= 8)
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

        let threshold = PermissionDenialDetector.threshold
        let t1 = t0.addingTimeInterval(20)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t1)
        #expect(!detector.isSuspected(at: t1.addingTimeInterval(threshold - 1)))
        #expect(detector.isSuspected(at: t1.addingTimeInterval(threshold + 1)))
    }

    @Test func repeatedDenialEventsKeepTheOriginalStart() {
        var detector = PermissionDenialDetector()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t0)
        detector.browserWaiting(dnsErrorCode: PermissionDenialDetector.policyDeniedCode, at: t0.addingTimeInterval(2))
        #expect(detector.isSuspected(at: t0.addingTimeInterval(PermissionDenialDetector.threshold + 0.5)))
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
        #expect(hello.message == .hello(clientID: Self.testClientID, clientName: "TestPhone", protoVersion: CompanionProto.version))
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
        conn.send(command: .setMainOutMuted(muted: true), requestID: "early")
        queue.sync {}
        #expect(transport.sentFrames.isEmpty, "no frames before the transport is even ready")

        queue.sync { transport.events?(.ready) } // hello goes out
        conn.send(command: .setMainOutMuted(muted: true), requestID: "handshaking")
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
        controller.setOnSnapshot { received.append($0) }

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

    // MARK: - Handshake deadline + app-level liveness

    @Test func handshakingEscapesWhenWelcomeNeverArrives() throws {
        let queue = DispatchQueue(label: "NetworkingStateTests.welcomeTimeout")
        let transport = FakeTransport()
        let conn = MacConnection(mac: makeMac(), transport: transport, clientID: Self.testClientID, clientName: "TestPhone", queue: queue)
        conn.welcomeTimeout = 0.05
        conn.start()
        queue.sync { transport.events?(.ready) }
        #expect(queue.sync { conn.state } == .handshaking)

        #expect(waitUntil { queue.sync { conn.state } == .disconnected(.failed("welcome timed out")) },
                "a Mac whose main thread never produces the welcome must not hold the phone in handshaking forever")
        #expect(transport.cancelled)
    }

    @Test func aPromptWelcomeCancelsTheDeadline() throws {
        let queue = DispatchQueue(label: "NetworkingStateTests.welcomeInTime")
        let transport = FakeTransport()
        let conn = MacConnection(mac: makeMac(), transport: transport, clientID: Self.testClientID, clientName: "TestPhone", queue: queue)
        conn.welcomeTimeout = 0.05
        conn.start()
        let welcome = try encoded(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: makeSnapshot()))
        queue.sync {
            transport.events?(.ready)
            transport.events?(.message(welcome))
        }
        #expect(queue.sync { conn.state } == .live)
        Thread.sleep(forTimeInterval: 0.1) // outlive the (cancelled) deadline
        #expect(queue.sync { conn.state } == .live,
                "the deadline must be cancelled the moment welcome lands")
    }

    @Test func aHungMacAppIsDetectedEvenWhenEveryPingIsPonged() throws {
        // Pongs prove the socket, not the app: the peer's Network.framework
        // answers pings with no app code running. App-level liveness rides
        // on inbound frames instead.
        let queue = DispatchQueue(label: "NetworkingStateTests.appLiveness")
        let transport = FakeTransport()
        let conn = MacConnection(mac: makeMac(), transport: transport, clientID: Self.testClientID, clientName: "TestPhone", queue: queue)
        conn.appLivenessTimeout = 0.2
        conn.start()
        let welcome = try encoded(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: makeSnapshot()))
        queue.sync {
            transport.events?(.ready)
            transport.events?(.message(welcome))
        }
        try #require(queue.sync { conn.state } == .live)

        // Fresh inbound activity (the server's ping) + an immediate tick:
        // alive, and stays alive despite the ponged ping.
        queue.sync {
            transport.events?(.activity)
            conn.keepaliveTick()
            transport.pong()
        }
        #expect(queue.sync { conn.state } == .live)

        // Now the Mac app goes silent (no frames, no pings) while the
        // socket keeps ponging: past the window, the tick calls it dead.
        Thread.sleep(forTimeInterval: 0.3)
        queue.sync { conn.keepaliveTick() }
        #expect(queue.sync { conn.state } == .disconnected(.keepaliveTimeout),
                "no app-level inbound traffic within the window must read as a dead peer")
    }

    // MARK: - Terminal-vs-retryable classification

    @Test func disconnectReasonsClassifyTerminalVsRetryable() {
        #expect(MacDisconnectReason.goodbye("protoMismatch").reconnectClass == .terminal)
        #expect(MacDisconnectReason.incompatiblePeer.reconnectClass == .terminal)
        #expect(MacDisconnectReason.goodbye("serverFull").reconnectClass == .longBackoff)
        #expect(MacDisconnectReason.goodbye("disabled").reconnectClass == .waitForReadvertise)
        #expect(MacDisconnectReason.goodbye("shutdown").reconnectClass == .retry)
        #expect(MacDisconnectReason.goodbye("some-future-reason").reconnectClass == .retry,
                "unknown goodbye reasons from a newer server must default to retryable")
        #expect(MacDisconnectReason.failed("socket died").reconnectClass == .retry)
        #expect(MacDisconnectReason.keepaliveTimeout.reconnectClass == .retry)
        #expect(MacDisconnectReason.closedByUs.reconnectClass == .quiet)
    }

    @Test func protoMismatchGoodbyeStopsAutoRedialAndSettles() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])

        try controller.queue.sync {
            factory.transports[0].events?(.message(try encoded(.goodbye(reason: "protoMismatch"))))
        }
        // A retryable drop redials eagerly (0-delay); give that window time
        // to prove nothing fires here.
        Thread.sleep(forTimeInterval: 0.2)
        controller.queue.sync {}
        #expect(factory.count == 1, "a proto-mismatched Mac must not be redialed — every attempt gets the same goodbye")
        #expect(controller.queue.sync { controller.connectionState } == .disconnected(.goodbye("protoMismatch")),
                "the settled state is what the UI renders the 'update the app' message from")

        // Browse refreshes must not resurrect the redial loop.
        controller.queue.sync { controller.handleMacsChanged([mac]) }
        Thread.sleep(forTimeInterval: 0.1)
        controller.queue.sync {}
        #expect(factory.count == 1)

        // An explicit user connect is the ONE way back in.
        controller.connect(to: mac)
        controller.queue.sync {}
        #expect(factory.count == 2)
    }

    @Test func anIncompatibleMacIsNeverDialedAtAll() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let newer = DiscoveredMac(
            id: "Future._audiout._tcplocal.",
            endpoint: .service(name: "Future", type: CompanionProto.serviceType, domain: "local.", interface: nil),
            name: "Future",
            protoVersion: CompanionProto.version + 1,
            isIncompatible: true
        )

        controller.connect(to: newer)
        controller.queue.sync {}
        #expect(factory.count == 0, "refuse-forward means refusing the DIAL, not just documenting it")
        #expect(controller.queue.sync { controller.connectionState } == .disconnected(.incompatiblePeer))

        // Browse events must not auto-redial it either.
        controller.queue.sync { controller.handleMacsChanged([newer]) }
        Thread.sleep(forTimeInterval: 0.1)
        controller.queue.sync {}
        #expect(factory.count == 0)
    }

    @Test func serverFullBacksOffLongInsteadOfHammering() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])

        try controller.queue.sync {
            factory.transports[0].events?(.message(try encoded(.goodbye(reason: "serverFull"))))
        }
        Thread.sleep(forTimeInterval: 0.3)
        controller.queue.sync {}
        #expect(factory.count == 1, "serverFull must not be redialed eagerly — a slot does not free on our schedule")
        #expect(controller.queue.sync { controller.reconnectAttempts } == 1,
                "a retry IS scheduled (on the long fixed delay), not abandoned")
        #expect(controller.queue.sync { controller.connectionState } == .disconnected(.goodbye("serverFull")))
    }

    @Test func disabledSettlesUntilTheMacReadvertises() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])

        try controller.queue.sync {
            factory.transports[0].events?(.message(try encoded(.goodbye(reason: "disabled"))))
        }
        Thread.sleep(forTimeInterval: 0.2)
        controller.queue.sync {}
        #expect(factory.count == 1, "a Mac that said it is turned off must not be hammered")

        // Still advertised (withdrawal lags): a refresh with the Mac
        // present must NOT redial.
        controller.queue.sync { controller.handleMacsChanged([mac]) }
        Thread.sleep(forTimeInterval: 0.1)
        controller.queue.sync {}
        #expect(factory.count == 1)

        // Advertisement disappears, then comes back (checkbox re-ticked):
        // NOW reconnect.
        controller.queue.sync { controller.handleMacsChanged([]) }
        controller.queue.sync { controller.handleMacsChanged([mac]) }
        #expect(waitUntil { factory.count == 2 },
                "the Mac re-advertising is the resume signal")
    }

    // MARK: - Late subscriber + snapshot staleness (controller level)

    @Test func aLateSnapshotSubscriberIsReplayedTheCurrentValue() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)

        // Live FIRST, subscriber second — the welcome already happened and
        // the server suppresses identical broadcasts, so without replay
        // this subscriber would stare at nil forever.
        controller.connect(to: makeMac())
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])

        let received = LockedSnapshots()
        controller.setOnSnapshot { received.append($0) }
        controller.queue.sync {}
        #expect(received.all == [makeSnapshot()],
                "subscribing after live must deliver the current snapshot immediately")

        let states = LockedStates()
        controller.setOnConnectionStateChanged { states.append($0) }
        controller.queue.sync {}
        #expect(states.all == [.live],
                "the status subscriber gets the current state on attach too")
    }

    private final class LockedStates: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [MacConnectionState] = []
        func append(_ state: MacConnectionState) { lock.withLock { _all.append(state) } }
        var all: [MacConnectionState] { lock.withLock { _all } }
    }

    @Test func aDisconnectClearsTheSnapshotAndNothingStaleIsReplayed() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)

        controller.connect(to: makeMac())
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])
        #expect(controller.queue.sync { controller.latestSnapshot } != nil)

        controller.queue.sync { factory.transports[0].events?(.failed("socket died")) }
        #expect(controller.queue.sync { controller.latestSnapshot } == nil,
                "an hour-old fleet must never be rendered as current after a drop")

        // A subscriber attaching while disconnected gets NO stale replay.
        let received = LockedSnapshots()
        controller.setOnSnapshot { received.append($0) }
        controller.queue.sync {}
        #expect(received.all.isEmpty)
    }

    // MARK: - Wi-Fi return

    @Test func wifiReturnCancelsTheBackoffAndRetriesImmediately() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        try goLive(controller, transport: factory.transports[0])

        // Two consecutive failures: the eager attempt (transport 2) fires,
        // fails too, and the NEXT retry is pending on a 1s backoff.
        controller.queue.sync { factory.transports[0].events?(.failed("socket died")) }
        try #require(waitUntil { factory.count == 2 })
        controller.queue.sync { factory.transports[1].events?(.failed("still down")) }
        controller.queue.sync {}
        try #require(factory.count == 2, "the second retry must be waiting out its backoff")

        // Wi-Fi drops and returns: the backoff was priced for a network
        // that no longer exists — retry must fire well inside the 1s delay.
        controller.queue.sync { controller.handlePathUpdate(satisfied: false) }
        controller.queue.sync { controller.handlePathUpdate(satisfied: true) }
        #expect(waitUntil(timeout: 0.5) { factory.count == 3 },
                "path-satisfied must reset the backoff and redial immediately")
    }

    // MARK: - Resolve probe cost + hygiene

    private final class UptimeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: TimeInterval = 0
        var value: TimeInterval {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    @Test func resolvedAddressCacheHonorsTTLAndInvalidation() throws {
        let uptime = UptimeBox()
        let cache = ResolvedAddressCache(now: { uptime.value })
        let url = try #require(URL(string: "ws://192.168.1.20:7000/"))

        #expect(cache.url(forMacID: "mac-1") == nil)
        cache.store(url, forMacID: "mac-1")
        #expect(cache.url(forMacID: "mac-1") == url)
        #expect(cache.url(forMacID: "mac-2") == nil, "entries are per Mac id")

        uptime.value = ResolvedAddressCache.ttl - 1
        #expect(cache.url(forMacID: "mac-1") == url, "fresh inside the TTL")
        uptime.value = ResolvedAddressCache.ttl + 1
        #expect(cache.url(forMacID: "mac-1") == nil, "expired entries must force a re-probe")

        uptime.value = 100
        cache.store(url, forMacID: "mac-1")
        cache.invalidate(macID: "mac-1")
        #expect(cache.url(forMacID: "mac-1") == nil, "a failed dial invalidates immediately")
    }

    @Test func aFailedResolveProbeIsCancelledNotLeaked() throws {
        // Real localhost networking: a TCP probe to a port nothing listens
        // on is refused/stalled fast, exercising the probe's failure exit.
        let mac = DiscoveredMac(
            id: "probe-test",
            endpoint: .hostPort(host: "127.0.0.1", port: 1),
            name: "probe-test",
            protoVersion: CompanionProto.version,
            isIncompatible: false
        )
        let queue = DispatchQueue(label: "NetworkingStateTests.probeCancel")
        let transport = ResolvedWebSocketTransport(mac: mac, cache: ResolvedAddressCache())
        let failed = UptimeBox() // 0 = not failed, 1 = failed
        transport.events = { event in
            if case .failed = event { failed.value = 1 }
        }
        transport.start(queue: queue)
        #expect(waitUntil { failed.value == 1 }, "the probe's failure must surface as a transport failure")
        #expect(queue.sync { transport.probe == nil },
                "every probe exit funnels through abandonProbe — the NWConnection must be cancelled and released")
    }

    // MARK: - T24: client identity

    @Test func identityIsStableAcrossLaunchesAndUppercaseCanonical() throws {
        let defaults = try makeDefaults()

        // First "launch": generated, persisted, uppercase, valid.
        let first = ClientIdentity.stableID(in: defaults)
        #expect(UUID(uuidString: first) != nil)
        #expect(first == first.uppercased(),
                "the server canonicalizes to uppercase — generating anything else risks becoming 'a different phone'")
        #expect(defaults.string(forKey: ClientIdentity.defaultsKey) == first)

        // Second "launch" over the same defaults: SAME id, no churn.
        #expect(ClientIdentity.stableID(in: defaults) == first)

        // A lowercase-stored id (e.g. written by an older build) is
        // canonicalized in place, not regenerated — same phone.
        defaults.set(first.lowercased(), forKey: ClientIdentity.defaultsKey)
        #expect(ClientIdentity.stableID(in: defaults) == first)
        #expect(defaults.string(forKey: ClientIdentity.defaultsKey) == first)

        // Garbage in the slot is repaired to a fresh VALID identity.
        defaults.set("not-a-uuid", forKey: ClientIdentity.defaultsKey)
        let repaired = ClientIdentity.stableID(in: defaults)
        #expect(UUID(uuidString: repaired) != nil)
        #expect(defaults.string(forKey: ClientIdentity.defaultsKey) == repaired)
    }

    @Test func theControllerSendsThePersistedIdentityInItsHello() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let persisted = try #require(defaults.string(forKey: ClientIdentity.defaultsKey),
                                     "constructing the controller must mint + persist the identity")

        controller.connect(to: makeMac())
        controller.queue.sync {}
        controller.queue.sync { factory.transports[0].events?(.ready) }
        let hello = try CompanionEnvelope.decode(factory.transports[0].sentFrames[0])
        #expect(hello.message == .hello(clientID: persisted, clientName: "TestPhone", protoVersion: CompanionProto.version))
    }

    // MARK: - T24: awaitingApproval

    @Test func awaitingApprovalOutlivesTheWelcomeDeadlineAndAcceptsALateWelcome() throws {
        let queue = DispatchQueue(label: "NetworkingStateTests.awaitingApproval")
        let transport = FakeTransport()
        let log = EventLog()
        let conn = MacConnection(mac: makeMac(), transport: transport, clientID: Self.testClientID, clientName: "TestPhone", queue: queue)
        conn.welcomeTimeout = 0.05
        conn.onEvent = { log.append($0) }
        conn.start()
        queue.sync { transport.events?(.ready) }
        try queue.sync { transport.events?(.message(try encoded(.awaitingApproval))) }
        #expect(queue.sync { conn.state } == .awaitingApproval)

        // Far past the (cancelled) welcome deadline: still waiting — the
        // user may literally be walking to their Mac.
        Thread.sleep(forTimeInterval: 0.2)
        #expect(queue.sync { conn.state } == .awaitingApproval,
                "awaitingApproval must cancel the welcome deadline, not be killed by it")

        // The user pressed Allow: the late welcome is the happy exit.
        let snapshot = makeSnapshot(volume: 42)
        try queue.sync {
            transport.events?(.message(try encoded(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: snapshot))))
        }
        #expect(queue.sync { conn.state } == .live)
        #expect(log.snapshots == [snapshot])
    }

    @Test func awaitingApprovalIsExemptFromAppLivenessButItsOwnDeadlineStillBounds() throws {
        let queue = DispatchQueue(label: "NetworkingStateTests.approvalLiveness")
        let transport = FakeTransport()
        let conn = MacConnection(mac: makeMac(), transport: transport, clientID: Self.testClientID, clientName: "TestPhone", queue: queue)
        conn.welcomeTimeout = 0.05
        conn.appLivenessTimeout = 0.05 // would kill a quiet handshake/live link
        conn.approvalTimeout = 0.5
        conn.start()
        queue.sync { transport.events?(.ready) }
        try queue.sync { transport.events?(.message(try encoded(.awaitingApproval))) }

        // A Mac showing its prompt sends NOTHING for minutes; ticks past
        // the app-liveness window must not read that silence as a hang
        // (pings are ponged — the socket is provably alive).
        Thread.sleep(forTimeInterval: 0.1)
        queue.sync {
            conn.keepaliveTick()
            transport.pong()
        }
        #expect(queue.sync { conn.state } == .awaitingApproval,
                "app-level liveness must be suspended while the Mac's prompt is up")

        // But not FOREVER: if the server's own timeout goodbye is lost,
        // the local approval deadline is the backstop.
        #expect(waitUntil { queue.sync { conn.state } == .disconnected(.failed("approval wait timed out")) })
        #expect(transport.cancelled)
    }

    @Test func approvalTimeoutOutlastsTheServersWindow() {
        let (conn, _, queue, _) = makeConnection()
        #expect(queue.sync { conn.approvalTimeout } > 180,
                "the local backstop must never fire before the server's own 180s prompt window")
    }

    // MARK: - T24: goodbye classification + redial policy

    @Test func approvalGoodbyesClassifyAsSpecified() {
        #expect(MacDisconnectReason.goodbye("notApproved").reconnectClass == .terminal)
        #expect(MacDisconnectReason.goodbye("approvalTimedOut").reconnectClass == .retry)
        #expect(MacDisconnectReason.goodbye("invalidClientID").reconnectClass == .repairIdentity)
    }

    @Test func notApprovedStopsRedialing() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        controller.queue.sync { factory.transports[0].events?(.ready) }
        try controller.queue.sync {
            factory.transports[0].events?(.message(try encoded(.goodbye(reason: "notApproved"))))
        }
        Thread.sleep(forTimeInterval: 0.2) // the eager-retry window, were one scheduled
        controller.queue.sync {}
        #expect(factory.count == 1, "a remembered denial gets the same goodbye every time — redialing is harassment")
        #expect(controller.queue.sync { controller.connectionState } == .disconnected(.goodbye("notApproved")))
        #expect(MacConnectionState.disconnected(.goodbye("notApproved")).approvalStatus == .denied)

        // Browse refreshes must not resurrect it either.
        controller.queue.sync { controller.handleMacsChanged([mac]) }
        Thread.sleep(forTimeInterval: 0.1)
        controller.queue.sync {}
        #expect(factory.count == 1)

        // An explicit user connect (after fixing it on the Mac) is the way back.
        controller.connect(to: mac)
        controller.queue.sync {}
        #expect(factory.count == 2)
    }

    @Test func approvalTimedOutRetriesOnTheNormalBackoff() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        controller.queue.sync { factory.transports[0].events?(.ready) }
        try controller.queue.sync {
            factory.transports[0].events?(.message(try encoded(.goodbye(reason: "approvalTimedOut"))))
        }
        #expect(waitUntil { factory.count == 2 },
                "an unanswered prompt is retryable — reconnecting re-asks the Mac's user")
        #expect(MacConnectionState.disconnected(.goodbye("approvalTimedOut")).approvalStatus == .promptTimedOut)
    }

    @Test func invalidClientIDRegeneratesOnceThenSettlesIfItRecurs() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()
        let originalID = try #require(defaults.string(forKey: ClientIdentity.defaultsKey))

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        controller.queue.sync { factory.transports[0].events?(.ready) }
        try controller.queue.sync {
            factory.transports[0].events?(.message(try encoded(.goodbye(reason: "invalidClientID"))))
        }

        // Repair: exactly one fresh, persisted identity + one redial.
        #expect(waitUntil { factory.count == 2 },
                "the first invalidClientID must repair the identity and retry")
        let repairedID = try #require(defaults.string(forKey: ClientIdentity.defaultsKey))
        #expect(repairedID != originalID)
        #expect(UUID(uuidString: repairedID) != nil)

        // The redial's hello carries the REPAIRED identity.
        controller.queue.sync { factory.transports[1].events?(.ready) }
        let hello = try CompanionEnvelope.decode(factory.transports[1].sentFrames[0])
        #expect(hello.message == .hello(clientID: repairedID, clientName: "TestPhone", protoVersion: CompanionProto.version))

        // The fresh identity is refused too: NOT an identity problem —
        // settle, do not mint identities in a loop.
        try controller.queue.sync {
            factory.transports[1].events?(.message(try encoded(.goodbye(reason: "invalidClientID"))))
        }
        Thread.sleep(forTimeInterval: 0.2)
        controller.queue.sync {}
        #expect(factory.count == 2, "a recurring invalidClientID must settle, not loop")
        #expect(defaults.string(forKey: ClientIdentity.defaultsKey) == repairedID,
                "settling must not churn the identity again")
        #expect(controller.queue.sync { controller.connectionState } == .disconnected(.goodbye("invalidClientID")))
    }

    @Test func aWelcomeResetsTheIdentityRepairBudget() throws {
        let defaults = try makeDefaults()
        let (controller, factory) = makeController(defaults: defaults)
        let mac = makeMac()

        controller.queue.sync { controller.handleMacsChanged([mac]) }
        controller.connect(to: mac)
        controller.queue.sync {}
        controller.queue.sync { factory.transports[0].events?(.ready) }
        try controller.queue.sync {
            factory.transports[0].events?(.message(try encoded(.goodbye(reason: "invalidClientID"))))
        }
        try #require(waitUntil { factory.count == 2 })
        try goLive(controller, transport: factory.transports[1])

        // A whole successful session later, a (far-fetched) second
        // invalidClientID gets a fresh repair budget instead of instantly
        // settling on the stale "already repaired once" flag.
        try controller.queue.sync {
            factory.transports[1].events?(.message(try encoded(.goodbye(reason: "invalidClientID"))))
        }
        #expect(waitUntil { factory.count == 3 },
                "the repair budget is per failure streak, not per controller lifetime")
    }
}
