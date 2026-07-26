// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import Network
import AudiouterProtocol
@testable import AudiouterCore

/// Lifecycle tests for `CompanionServer` (PLAN-COMPANION-APP T5), driven
/// through real loopback WebSocket connections handed straight to the
/// internal `accept(_:)` seam — NEVER through `start(name:)`'s own listener.
/// That listener binds ALL interfaces and Bonjour-advertises, and an
/// all-interfaces bind is exactly what trips macOS's Application Firewall
/// "accept incoming network connections?" prompt for the xctest process on a
/// `swift test` run (the same lesson `DACPServerTests` documents, applied
/// again here). The loopback listener below is restricted to `127.0.0.1`
/// via `requiredLocalEndpoint` for the same reason.
@Suite struct CompanionServerTests {

    // MARK: - Concurrency-safe test plumbing

    /// A lock-guarded value box; network callbacks fire on `netQueue`, the
    /// server's callbacks on its own queue, and the test thread spins —
    /// three threads, one lock. (Same rationale as `DACPServerTests.Signal`,
    /// generalized because these tests accumulate messages, not just flags.)
    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
        func withLock<R>(_ body: (inout T) -> R) -> R {
            lock.withLock { body(&_value) }
        }
    }

    /// Everything one test client observed: decoded server frames plus
    /// whether its connection has died (error, EOF, close, or cancel — the
    /// tests treat them uniformly, like the server does).
    private final class MessageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [CompanionMessage] = []
        private var _closed = false
        func append(_ message: CompanionMessage) { lock.withLock { _messages.append(message) } }
        func markClosed() { lock.withLock { _closed = true } }
        var messages: [CompanionMessage] { lock.withLock { _messages } }
        var closed: Bool { lock.withLock { _closed } }
        func contains(_ message: CompanionMessage) -> Bool { messages.contains(message) }
    }

    /// Spin (not block) until `condition` holds or `timeout` elapses —
    /// the `DACPServerTests.waitFor` idiom, generalized to a predicate.
    /// Timeouts are generous: this machine runs several agents' suites at
    /// once.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    // MARK: - Loopback WebSocket harness

    /// A `127.0.0.1`-only WebSocket listener whose accepted server-side
    /// connections are exactly what `CompanionServer.start(name:)`'s own
    /// `newConnectionHandler` would see: un-started, WebSocket in the stack,
    /// ready to hand to `accept(_:)`.
    private final class LoopbackHub: @unchecked Sendable {
        let listener: NWListener
        let netQueue = DispatchQueue(label: "CompanionServerTests.loopback")
        private let lock = NSLock()
        private var pending: [NWConnection] = []
        private var _isReady = false

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.withLock { self.pending.append(connection) }
            }
            // Wait for `.ready`, not a non-nil `.port`: with
            // `requiredLocalEndpoint` pinned to port `.any`, `listener.port`
            // populates EARLY as a placeholder `0` (see DACPServerTests'
            // makeLoopbackPair comment for the standalone repro).
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    guard let self else { return }
                    self.lock.withLock { self._isReady = true }
                }
            }
            listener.start(queue: netQueue)
        }

        var isReady: Bool { lock.withLock { _isReady } }
        var hasPending: Bool { lock.withLock { !pending.isEmpty } }
        func popPending() -> NWConnection? {
            lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        }
        func cancel() { listener.cancel() }
    }

    private func makeHub() throws -> LoopbackHub {
        let hub = try LoopbackHub()
        try #require(waitUntil { hub.isReady }, "test loopback listener never reached .ready")
        let port = try #require(hub.listener.port, "listener bound no port")
        try #require(port.rawValue != 0, "listener port never left the placeholder 0")
        return hub
    }

    /// Connect one WebSocket client through `hub` and hand its server side
    /// to `server.accept(_:)`. The client's WebSocket handshake only
    /// completes once the server side is started, so acceptance happens
    /// in here — waiting for client `.ready` before returning proves the
    /// full upgrade round-tripped.
    private func connectClient(via hub: LoopbackHub, to server: CompanionServer) throws -> (client: NWConnection, log: MessageLog) {
        let port = try #require(hub.listener.port)
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // A WebSocket CLIENT must connect to a `ws://` URL endpoint — with a
        // plain host/port endpoint the upgrade handshake aborts
        // (ECONNABORTED, client stuck in .waiting; reproduced standalone
        // against this SDK). The server side is indifferent.
        let url = try #require(URL(string: "ws://127.0.0.1:\(port.rawValue)"))
        let client = NWConnection(to: .url(url), using: params)

        let log = MessageLog()
        let ready = LockedBox(false)
        client.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.value = true
            case .cancelled, .failed: log.markClosed()
            default: break
            }
        }
        client.start(queue: hub.netQueue)
        receiveInto(log, from: client)

        try #require(waitUntil { hub.hasPending }, "the loopback listener never accepted the client")
        let serverSide = try #require(hub.popPending())
        server.accept(serverSide)
        try #require(waitUntil { ready.value }, "the WebSocket handshake never completed")
        return (client, log)
    }

    /// Re-arming client-side receive: decode every text frame into `log`,
    /// mark closed on error/EOF/close.
    private func receiveInto(_ log: MessageLog, from client: NWConnection) {
        client.receiveMessage { data, context, _, error in
            if error != nil { log.markClosed(); return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                log.markClosed()
                return
            }
            guard let data, !data.isEmpty else { log.markClosed(); return }
            if let envelope = try? CompanionEnvelope.decode(data) {
                log.append(envelope.message)
            }
            self.receiveInto(log, from: client)
        }
    }

    private func sendText(_ data: Data, over client: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        client.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendHello(over client: NWConnection, name: String = "phone", protoVersion: Int = CompanionProto.version) throws {
        sendText(try CompanionEnvelope(message: .hello(clientName: name, protoVersion: protoVersion)).encoded(), over: client)
    }

    /// A minimal-but-real snapshot; `volume` differentiates fixtures so
    /// broadcast tests can assert which one arrived.
    private func makeSnapshot(volume: Int = 50, serverName: String = "TestMac") -> Snapshot {
        Snapshot(
            serverName: serverName,
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

    // MARK: - Handshake

    @Test func handshakeYieldsWelcomeCarryingTheCachedSnapshot() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() }

        let snapshot = makeSnapshot()
        server.broadcast(snapshot) // cached before any client exists

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client)

        #expect(waitUntil { log.contains(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: snapshot)) },
                "the client never received its welcome with the cached snapshot")
    }

    @Test func newerProtoHelloIsRefusedWithGoodbye() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client, protoVersion: CompanionProto.version + 1)

        #expect(waitUntil { log.contains(.goodbye(reason: "protoMismatch")) },
                "the newer-proto client never got its goodbye")
        #expect(waitUntil { log.closed },
                "the refused client's connection was never closed")
        #expect(!log.messages.contains { if case .welcome = $0 { return true } else { return false } },
                "a refused client must never be welcomed")
    }

    @Test func silentClientIsCancelledAfterTheHandshakeDeadline() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        server.test_handshakeTimeoutOverride = 0.3 // real default is 10s
        defer { server.stop() }

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        // Deliberately never send hello — the exact idle-peer shape the
        // deadline exists for.
        #expect(waitUntil { log.closed },
                "the server never cancelled the client that skipped its hello")
    }

    // MARK: - Commands

    @Test func commandRoundTripDeliversTheReply() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() }

        server.onCommand = { requestID, command, _, reply in
            #expect(requestID == "req-1")
            #expect(command == .setDeviceVolume(id: "dev-1", volume: 40))
            // Reply from off the server queue, like the wiring layer's
            // main-thread hop will.
            DispatchQueue.global().async {
                reply(.init(applied: false, refusalReason: "no such device", autoSwappedCurrentDevice: true))
            }
        }

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client)
        sendText(try CompanionEnvelope(message: .command(requestID: "req-1", command: .setDeviceVolume(id: "dev-1", volume: 40))).encoded(), over: client)

        #expect(waitUntil { log.contains(.commandResult(requestID: "req-1", applied: false, refusalReason: "no such device", autoSwappedCurrentDevice: true)) },
                "the command's result never came back")
    }

    // MARK: - Broadcast

    @Test func broadcastReachesEveryClientAndSuppressesIdenticalSnapshots() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() }

        let snap1 = makeSnapshot(volume: 10)
        server.broadcast(snap1)

        let (clientA, logA) = try connectClient(via: hub, to: server)
        defer { clientA.cancel() }
        let (clientB, logB) = try connectClient(via: hub, to: server)
        defer { clientB.cancel() }
        try sendHello(over: clientA, name: "phoneA")
        try sendHello(over: clientB, name: "phoneB")
        try #require(waitUntil {
            logA.contains(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: snap1))
                && logB.contains(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: snap1))
        }, "both clients must be welcomed before broadcasting")

        let snap2 = makeSnapshot(volume: 20)
        let snap3 = makeSnapshot(volume: 30)
        server.broadcast(snap2)
        server.broadcast(snap2) // identical — must be suppressed
        server.broadcast(snap3) // sentinel: once this arrives, snap2's fate is settled

        for log in [logA, logB] {
            #expect(waitUntil { log.contains(.state(snapshot: snap3)) },
                    "a broadcast never reached a connected client")
            #expect(log.messages.filter { $0 == .state(snapshot: snap2) }.count == 1,
                    "an identical snapshot broadcast was not suppressed (or was dropped)")
        }
    }

    // MARK: - Bad clients hurt only themselves

    @Test func malformedFrameClosesOnlyTheOffender() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() }

        let snap1 = makeSnapshot(volume: 10)
        server.broadcast(snap1)
        let (offender, offenderLog) = try connectClient(via: hub, to: server)
        defer { offender.cancel() }
        let (bystander, bystanderLog) = try connectClient(via: hub, to: server)
        defer { bystander.cancel() }
        try sendHello(over: offender, name: "offender")
        try sendHello(over: bystander, name: "bystander")
        try #require(waitUntil {
            offenderLog.messages.count >= 1 && bystanderLog.messages.count >= 1
        }, "both clients must be welcomed first")

        sendText(Data("definitely not json".utf8), over: offender)
        #expect(waitUntil { offenderLog.closed },
                "the malformed-frame sender was never closed")

        let snap2 = makeSnapshot(volume: 20)
        server.broadcast(snap2)
        #expect(waitUntil { bystanderLog.contains(.state(snapshot: snap2)) },
                "the bystander stopped receiving broadcasts after another client misbehaved")
        #expect(!bystanderLog.closed, "the bystander must stay connected")
    }

    @Test func oversizedFrameClosesTheOffender() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() }

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        // Valid JSON, over the 64 KB per-message cap — the size check, not
        // the malformed-frame path, is what must trip.
        let hugeName = String(repeating: "a", count: 70_000)
        try sendHello(over: client, name: hugeName)
        #expect(waitUntil { log.closed },
                "the oversized-frame sender was never closed")
    }

    // MARK: - Client cap

    @Test func clientCapRefusesPolitelyAndKeepsExistingClients() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        server.test_maxClientsOverride = 1 // real cap is 16
        defer { server.stop() }

        let (kept, keptLog) = try connectClient(via: hub, to: server)
        defer { kept.cancel() }
        try sendHello(over: kept, name: "first")

        let (refused, refusedLog) = try connectClient(via: hub, to: server)
        defer { refused.cancel() }
        #expect(waitUntil { refusedLog.contains(.goodbye(reason: "serverFull")) },
                "the over-cap client never got its polite goodbye")
        #expect(waitUntil { refusedLog.closed },
                "the over-cap client's connection was never closed")

        // The kept client said hello before any snapshot existed, so this
        // first broadcast also exercises the deferred-welcome path.
        let snapshot = makeSnapshot()
        server.broadcast(snapshot)
        #expect(waitUntil { keptLog.contains(.welcome(serverName: "TestMac", protoVersion: CompanionProto.version, snapshot: snapshot)) },
                "the within-cap client stopped working after a refusal")
        #expect(!keptLog.closed, "the within-cap client must stay connected")
    }

    // MARK: - Teardown + identity

    @Test func stopCancelsEveryConnection() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() } // idempotent second stop

        let counts = LockedBox<[Int]>([])
        server.onClientCountChanged = { count in
            counts.withLock { $0.append(count) }
        }

        let (clientA, logA) = try connectClient(via: hub, to: server)
        defer { clientA.cancel() }
        let (clientB, logB) = try connectClient(via: hub, to: server)
        defer { clientB.cancel() }
        try sendHello(over: clientA, name: "phoneA")
        try sendHello(over: clientB, name: "phoneB")
        try #require(waitUntil { counts.value.last == 2 }, "both clients were never counted")

        server.stop()
        #expect(waitUntil { logA.closed && logB.closed },
                "stop() left a client connection alive")
        #expect(counts.value.last == 0, "stop() must report the count dropping to 0")
    }

    @Test func disconnectReportsTheSameClientIDCommandsCarried() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() }

        let commandClientID = LockedBox<UUID?>(nil)
        server.onCommand = { _, _, clientID, reply in
            commandClientID.value = clientID
            reply(.init(applied: true))
        }
        let disconnectedIDs = LockedBox<[UUID]>([])
        server.onClientDisconnected = { id in
            disconnectedIDs.withLock { $0.append(id) }
        }

        let (client, log) = try connectClient(via: hub, to: server)
        try sendHello(over: client)
        sendText(try CompanionEnvelope(message: .command(requestID: "r1", command: .beginMainOutDrag)).encoded(), over: client)
        try #require(waitUntil { log.contains(.commandResult(requestID: "r1", applied: true, refusalReason: nil, autoSwappedCurrentDevice: false)) },
                     "the command never completed")
        let observedID = try #require(commandClientID.value)

        // The mid-drag phone walks away — the wiring layer needs to learn
        // WHICH client died so it can end that client's orphaned drag.
        client.cancel()
        #expect(waitUntil { disconnectedIDs.value.contains(observedID) },
                "the disconnect never reported the client's ID (or reported a different one)")
    }
}
