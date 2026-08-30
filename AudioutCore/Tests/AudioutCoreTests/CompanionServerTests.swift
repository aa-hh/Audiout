// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import Network
import AudioutProtocol
@testable import AudioutCore

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
    private func connectClient(via hub: LoopbackHub, to server: CompanionServer, autoReplyPing: Bool = false) throws -> (client: NWConnection, log: MessageLog) {
        let port = try #require(hub.listener.port)
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = autoReplyPing // the liveness tests' live/dead knob
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

    /// A syntactically valid phone identity for tests that aren't about the
    /// clientID itself.
    static let validClientID = "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A"

    private func sendHello(over client: NWConnection, name: String = "phone", clientID: String = CompanionServerTests.validClientID, protoVersion: Int = CompanionProto.version) throws {
        sendText(try CompanionEnvelope(message: .hello(clientID: clientID, clientName: name, protoVersion: protoVersion)).encoded(), over: client)
    }

    /// A server whose T24 approval gate answers `.approved` instantly — what
    /// every pre-approval test below means by "a client hellos and is
    /// promoted". The gate's own behavior is tested separately at the end.
    private func makeAutoApprovingServer() -> CompanionServer {
        let server = CompanionServer()
        server.onApprovalRequest = { _, _, decide in decide(.approved) }
        return server
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
        let server = makeAutoApprovingServer()
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
        let server = makeAutoApprovingServer()
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
        let server = makeAutoApprovingServer()
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
        let server = makeAutoApprovingServer()
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
        let server = makeAutoApprovingServer()
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
        let server = makeAutoApprovingServer()
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
        let server = makeAutoApprovingServer()
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
        let server = makeAutoApprovingServer()
        server.test_maxClientsOverride = 1 // real cap is 16
        defer { server.stop() }

        let (kept, keptLog) = try connectClient(via: hub, to: server)
        defer { kept.cancel() }
        try sendHello(over: kept, name: "first")
        try #require(waitUntil { server.test_clientNames() == ["first"] },
                     "the first client was never promoted")

        // The cap is enforced at HELLO (promotion), not at accept — merely
        // connecting must not trip it (that's the pre-hello ghost fix).
        let (refused, refusedLog) = try connectClient(via: hub, to: server)
        defer { refused.cancel() }
        try sendHello(over: refused, name: "second")
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
        let server = makeAutoApprovingServer()
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
        #expect(waitUntil { counts.value.last == 0 }, "stop() must report the count dropping to 0")
        // The default stop reason is `shutdown` — every promoted client gets
        // the best-effort goodbye before its socket closes, so the phone
        // never mistakes a deliberate stop for a transport failure.
        for log in [logA, logB] {
            #expect(waitUntil { log.contains(.goodbye(reason: CompanionGoodbyeReason.shutdown)) },
                    "stop() closed a client without its goodbye")
        }
    }

    @Test func stopSendsGoodbyeCarryingTheGivenReason() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client)
        try #require(waitUntil { log.messages.contains { if case .welcome = $0 { return true } else { return false } } },
                     "the client was never welcomed")

        // The Settings-checkbox-off path: the phone must learn the server
        // was DISABLED (settle quietly) rather than see a bare socket error
        // (redial forever).
        server.stop(reason: CompanionGoodbyeReason.disabled)
        #expect(waitUntil { log.contains(.goodbye(reason: CompanionGoodbyeReason.disabled)) },
                "the disabled-stop never sent its goodbye")
        #expect(waitUntil { log.closed }, "the disabled-stop never closed the connection")
    }

    // MARK: - Pre-hello connections never occupy client slots

    /// Regression for the proven iOS-probe bug: a plain connection that
    /// never hellos (the iOS client's own address-resolve probe does exactly
    /// this) used to enter `clients` immediately and count against
    /// `maxClients`, so a few reconnecting phones could exhaust the cap with
    /// ghosts.
    @Test func preHelloConnectionsDoNotConsumeClientSlots() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        server.test_maxClientsOverride = 1
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        // The ghost connects first and never says hello.
        let (ghost, _) = try connectClient(via: hub, to: server)
        defer { ghost.cancel() }

        // A real phone arriving after the ghost must still get the one slot.
        let (real, realLog) = try connectClient(via: hub, to: server)
        defer { real.cancel() }
        try sendHello(over: real, name: "real")
        #expect(waitUntil { realLog.messages.contains { if case .welcome = $0 { return true } else { return false } } },
                "an un-helloed ghost consumed the only client slot")

        // And the cap still bites at promotion: a SECOND helloing client is
        // refused.
        let (late, lateLog) = try connectClient(via: hub, to: server)
        defer { late.cancel() }
        try sendHello(over: late, name: "late")
        #expect(waitUntil { lateLog.contains(.goodbye(reason: CompanionGoodbyeReason.serverFull)) },
                "the over-cap helloing client was never refused")
    }

    @Test func pendingFloodBeyondTheCapIsDroppedImmediately() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        server.test_pendingCapOverride = 1 // real cap is 32
        defer { server.stop() }

        // Occupies the only pending slot and never hellos.
        let (ghost, _) = try connectClient(via: hub, to: server)
        defer { ghost.cancel() }

        // The next arrival must be cancelled on arrival (no goodbye, no held
        // fd) — connect raw because the WS upgrade will never complete.
        let port = try #require(hub.listener.port)
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let url = try #require(URL(string: "ws://127.0.0.1:\(port.rawValue)"))
        let flooder = NWConnection(to: .url(url), using: params)
        defer { flooder.cancel() }
        let dropped = LockedBox(false)
        flooder.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed, .waiting: dropped.value = true
            default: break
            }
        }
        flooder.start(queue: hub.netQueue)
        try #require(waitUntil { hub.hasPending }, "the loopback listener never saw the flooder")
        let serverSide = try #require(hub.popPending())
        server.accept(serverSide)
        #expect(waitUntil { dropped.value },
                "the over-pending-cap connection was never dropped")
    }

    // MARK: - Liveness

    /// A phone that vanishes without a FIN (airplane mode, out of range)
    /// answers no pings; the server must reap it — releasing its slot and
    /// firing `onClientDisconnected` so the wiring can end an orphaned drag.
    @Test func silentDeadClientIsReapedByLivenessPings() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        server.test_pingIntervalOverride = 0.1  // real default is 20 s
        server.test_livenessTimeoutOverride = 0.3 // real default is 60 s
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let disconnected = LockedBox<[UUID]>([])
        server.onClientDisconnected = { id in disconnected.withLock { $0.append(id) } }

        // autoReplyPing defaults to FALSE in this harness — the client
        // upgrades and hellos, then never answers a ping: the dead-phone
        // shape (a real live client's stack auto-pongs).
        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client)
        try #require(waitUntil { log.messages.contains { if case .welcome = $0 { return true } else { return false } } },
                     "the client was never welcomed")

        #expect(waitUntil { !disconnected.value.isEmpty },
                "the server never reaped the client that stopped answering pings")
    }

    @Test func pongAnsweringClientSurvivesLivenessPings() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        server.test_pingIntervalOverride = 0.1
        // Generous vs. the 0.1 s ping cadence: several agents' suites share
        // this machine, and a scheduling stall must not read as death.
        server.test_livenessTimeoutOverride = 1.5
        defer { server.stop() }
        server.broadcast(makeSnapshot(volume: 10))

        let disconnected = LockedBox<[UUID]>([])
        server.onClientDisconnected = { id in disconnected.withLock { $0.append(id) } }

        let (client, log) = try connectClient(via: hub, to: server, autoReplyPing: true)
        defer { client.cancel() }
        try sendHello(over: client)
        try #require(waitUntil { log.messages.contains { if case .welcome = $0 { return true } else { return false } } },
                     "the client was never welcomed")

        // Observe past several ping cycles; the auto-ponging client must
        // never be reaped, and must still be receiving broadcasts at the end.
        _ = waitUntil(timeout: 2) { !disconnected.value.isEmpty }
        #expect(disconnected.value.isEmpty, "a pong-answering client was reaped as dead")
        let snap2 = makeSnapshot(volume: 20)
        server.broadcast(snap2)
        #expect(waitUntil { log.contains(.state(snapshot: snap2)) },
                "the surviving client stopped receiving broadcasts")
        #expect(!log.closed, "the surviving client's connection must stay open")
    }

    // MARK: - Hostile input hygiene

    @Test func clientNameIsTruncatedAtParse() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client, name: String(repeating: "a", count: 200))
        try #require(waitUntil { log.messages.contains { if case .welcome = $0 { return true } else { return false } } },
                     "the long-named client was never welcomed")
        #expect(server.test_clientNames() == [String(repeating: "a", count: 64)],
                "the attacker-controlled clientName was not truncated at parse")
    }

    /// Refuse-forward must hold on EVERY frame, not just the hello — a peer
    /// that hellos at a compatible version and then sends newer-versioned
    /// envelopes gets the same goodbye a newer hello would.
    @Test func newerEnvelopeVersionOnALaterFrameIsRefused() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client)
        try #require(waitUntil { log.messages.contains { if case .welcome = $0 { return true } else { return false } } },
                     "the client was never welcomed")

        let envelope = CompanionEnvelope(
            message: .command(requestID: "r-newer", command: .setMainOutMuted(muted: true)),
            v: CompanionProto.version + 1
        )
        sendText(try envelope.encoded(), over: client)
        #expect(waitUntil { log.contains(.goodbye(reason: CompanionGoodbyeReason.protoMismatch)) },
                "the newer-versioned frame was never refused")
        #expect(waitUntil { log.closed },
                "the newer-versioned frame's sender was never closed")
    }

    @Test func disconnectReportsTheSameClientIDCommandsCarried() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
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
        sendText(try CompanionEnvelope(message: .command(requestID: "r1", command: .setMainOutMuted(muted: true))).encoded(), over: client)
        try #require(waitUntil { log.contains(.commandResult(requestID: "r1", applied: true, refusalReason: nil, autoSwappedCurrentDevice: false)) },
                     "the command never completed")
        let observedID = try #require(commandClientID.value)

        // The phone walks away — the wiring layer needs to learn WHICH
        // client died so it can drop that client's rate-limiter bucket.
        client.cancel()
        #expect(waitUntil { disconnectedIDs.value.contains(observedID) },
                "the disconnect never reported the client's ID (or reported a different one)")
    }

    // MARK: - Per-phone approval gate (T24)

    @Test func approvedDecisionPromotesAndWelcomes() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let asked = LockedBox<(id: String, name: String)?>(nil)
        server.onApprovalRequest = { clientID, clientName, decide in
            asked.value = (clientID, clientName)
            decide(.approved)
        }

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client, name: "Alec's iPhone")

        #expect(waitUntil { log.messages.contains { if case .welcome = $0 { return true } else { return false } } },
                "the approved client was never welcomed")
        let request = try #require(asked.value)
        #expect(request.id == Self.validClientID, "the gate must see the (canonicalized) clientID")
        #expect(request.name == "Alec's iPhone")
        // No awaitingApproval frame on the fast path: an already-approved
        // phone must never flash "check your Mac".
        #expect(!log.contains(.awaitingApproval),
                "an instantly-approved client must not be told it's awaiting approval")
    }

    @Test func deniedDecisionSendsNotApprovedAndCloses() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())
        server.onApprovalRequest = { _, _, decide in decide(.denied) }

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client)

        #expect(waitUntil { log.contains(.goodbye(reason: CompanionGoodbyeReason.notApproved)) },
                "the denied client never learned why it was refused")
        #expect(waitUntil { log.closed }, "the denied client's connection was never closed")
        #expect(!log.messages.contains { if case .welcome = $0 { return true } else { return false } },
                "a denied client must never be welcomed")
    }

    /// The full unknown-phone arc: hold (awaitingApproval frame, connection
    /// alive well past the PRE-HELLO deadline — that guards un-helloed
    /// connections only) → late `.approved` → welcome.
    @Test func unknownClientIsHeldPastTheHandshakeDeadlineThenPromotedOnApproval() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        // Short enough to outlive cheaply below, long enough that the hello
        // itself always lands inside it even on a loaded machine.
        server.test_handshakeTimeoutOverride = 0.5
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let decider = LockedBox<(@Sendable (CompanionServer.ApprovalDecision) -> Void)?>(nil)
        server.onApprovalRequest = { _, _, decide in
            decide(.pending)
            decider.value = decide
        }

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client)

        #expect(waitUntil { log.contains(.awaitingApproval) },
                "the unknown client was never told it's awaiting approval")
        // Outlive the pre-hello deadline several times over while the
        // human decides.
        Thread.sleep(forTimeInterval: 1.5)
        #expect(!log.closed, "the awaiting client was killed by the pre-hello deadline")

        let decide = decider.value
        try #require(decide != nil, "the gate never asked the app layer")
        decide?(.approved)
        #expect(waitUntil { log.messages.contains { if case .welcome = $0 { return true } else { return false } } },
                "the late-approved client was never welcomed")
    }

    @Test func awaitingApprovalTimesOutWithARetryableReason() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        server.test_approvalTimeoutOverride = 0.3 // real default is 180s
        defer { server.stop() }
        server.broadcast(makeSnapshot())
        server.onApprovalRequest = { _, _, decide in decide(.pending) } // never answered

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client)

        #expect(waitUntil { log.contains(.goodbye(reason: CompanionGoodbyeReason.approvalTimedOut)) },
                "the unanswered client never got the timeout goodbye")
        #expect(waitUntil { log.closed }, "the timed-out client's connection was never closed")

        // A verdict arriving AFTER the timeout must be a no-op, not a crash
        // or a ghost promotion.
        #expect(server.test_awaitingCount() == 0)
    }

    @Test func helloWithoutClientIDIsRefusedWithAClearReason() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        // Raw frame with NO clientID key — the exact shape a pre-T24 client
        // would send. It must decode (not read as malformed) and be refused
        // with a reason the phone can act on.
        sendText(Data("""
        {"v": 1, "type": "hello", "payload": {"clientName": "old phone", "protoVersion": 1}}
        """.utf8), over: client)

        #expect(waitUntil { log.contains(.goodbye(reason: CompanionGoodbyeReason.invalidClientID)) },
                "the clientID-less hello never got its reasoned refusal")
        #expect(waitUntil { log.closed }, "the refused client's connection was never closed")
    }

    @Test func helloWithAMalformedClientIDIsRefused() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client, clientID: "definitely-not-a-uuid")

        #expect(waitUntil { log.contains(.goodbye(reason: CompanionGoodbyeReason.invalidClientID)) },
                "the malformed clientID was never refused")
        #expect(waitUntil { log.closed }, "the refused client's connection was never closed")
    }

    @Test func awaitingPoolIsBounded() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = CompanionServer()
        server.test_awaitingCapOverride = 1 // real cap is 8
        defer { server.stop() }
        server.broadcast(makeSnapshot())
        server.onApprovalRequest = { _, _, decide in decide(.pending) } // hold everyone

        let (held, heldLog) = try connectClient(via: hub, to: server)
        defer { held.cancel() }
        try sendHello(over: held, clientID: UUID().uuidString)
        try #require(waitUntil { heldLog.contains(.awaitingApproval) },
                     "the first client was never held")

        let (overflow, overflowLog) = try connectClient(via: hub, to: server)
        defer { overflow.cancel() }
        try sendHello(over: overflow, clientID: UUID().uuidString)
        #expect(waitUntil { overflowLog.contains(.goodbye(reason: CompanionGoodbyeReason.serverFull)) },
                "the over-cap awaiting client was never refused")
        #expect(!heldLog.closed, "the held client must survive the overflow refusal")
    }

    @Test func dropClientClosesTheLiveClientWithThatPhoneIdentity() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let disconnected = LockedBox<[UUID]>([])
        server.onClientDisconnected = { id in disconnected.withLock { $0.append(id) } }

        let revokedID = UUID().uuidString
        let (revoked, revokedLog) = try connectClient(via: hub, to: server)
        defer { revoked.cancel() }
        try sendHello(over: revoked, name: "revoked", clientID: revokedID)
        let (kept, keptLog) = try connectClient(via: hub, to: server)
        defer { kept.cancel() }
        try sendHello(over: kept, name: "kept", clientID: UUID().uuidString)
        try #require(waitUntil { Set(server.test_clientNames()) == ["revoked", "kept"] },
                     "both clients must be promoted first")

        server.dropClient(clientID: revokedID)

        #expect(waitUntil { revokedLog.closed }, "revoking never dropped the live client")
        #expect(waitUntil { !disconnected.value.isEmpty },
                "the revoked drop must fire the normal disconnect signal (orphaned-drag cleanup)")
        #expect(!keptLog.closed, "an unrelated client must survive another phone's revocation")
        #expect(waitUntil { server.test_clientNames() == ["kept"] })
    }

    // MARK: - App icon pages

    /// Icons are addressed, not broadcast: only the asking client should ever
    /// receive a page, because pages answer that client's own request and a
    /// broadcast would push megabytes at phones that already hold the icons.
    @Test func sendAppIconsReachesOnlyTheAddressedClient() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        defer { server.stop() }
        // A cached snapshot is what lets promotion send `welcome` — and
        // `sendAppIcons` guards on `isWelcomed`, which is exactly right: a
        // phone can only ask for icons off a snapshot it has received.
        server.broadcast(makeSnapshot())

        // The addressee's server-side UUID is only observable through
        // `onCommand`, so the asker sends one command to introduce itself.
        let askerID = LockedBox<UUID?>(nil)
        server.onCommand = { _, _, clientID, reply in
            askerID.value = clientID
            reply(.init(applied: true))
        }

        let (asker, askerLog) = try connectClient(via: hub, to: server)
        defer { asker.cancel() }
        try sendHello(over: asker, name: "asker", clientID: UUID().uuidString)
        let (bystander, bystanderLog) = try connectClient(via: hub, to: server)
        defer { bystander.cancel() }
        try sendHello(over: bystander, name: "bystander", clientID: UUID().uuidString)
        try #require(waitUntil { Set(server.test_clientNames()) == ["asker", "bystander"] },
                     "both clients must be promoted first")

        sendText(try CompanionEnvelope(message: .command(
            requestID: "req-icons",
            command: .requestAppIcons(bundleIDs: ["com.example.app"]))).encoded(), over: asker)
        let clientID = try #require(waitUntil { askerID.value != nil } ? askerID.value : nil,
                                    "the asker's command never surfaced its clientID")

        let icons = [AppIconPayload(bundleID: "com.example.app", png: Data([0x89, 0x50, 0x4E, 0x47]))]
        server.sendAppIcons(icons, page: 0, pageCount: 1, to: clientID)

        #expect(waitUntil { askerLog.contains(.appIcons(page: 0, pageCount: 1, icons: icons)) },
                "the addressed client never received its icon page")
        #expect(!bystanderLog.messages.contains { if case .appIcons = $0 { return true } else { return false } },
                "an icon page must never reach a client that didn't ask")
    }

    @Test func sendAppIconsToAnUnknownClientIsASilentNoOp() throws {
        let hub = try makeHub()
        defer { hub.cancel() }
        let server = makeAutoApprovingServer()
        defer { server.stop() }
        server.broadcast(makeSnapshot())

        let (client, log) = try connectClient(via: hub, to: server)
        defer { client.cancel() }
        try sendHello(over: client)
        try #require(waitUntil { server.test_clientNames() == ["phone"] })

        server.sendAppIcons([AppIconPayload(bundleID: "com.example.app", png: nil)],
                            page: 0, pageCount: 1, to: UUID())

        // Nothing to wait FOR — give the server queue a beat, then assert
        // the connected client neither received a stray page nor died.
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!log.messages.contains { if case .appIcons = $0 { return true } else { return false } },
                "a page addressed to an unknown client must not leak to anyone else")
        #expect(!log.closed, "a bad clientID must not disturb live connections")
        #expect(server.test_clientNames() == ["phone"])
    }
}
