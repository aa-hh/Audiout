// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network
import os
import AudiouterProtocol

/// The Mac side of the companion-app link (PLAN-COMPANION-APP T5): a
/// Bonjour-advertised WebSocket server the iOS app connects to. Transport
/// only — it speaks `CompanionEnvelope` frames (AudiouterProtocol) and knows
/// nothing about controllers or snapshots' meaning. The wiring layer
/// (AppDelegate, T7) feeds it snapshots via ``broadcast(_:)`` and consumes
/// ``onCommand``/``onClientDisconnected``.
///
/// ## Session shape
/// 1. Client connects; it has ``handshakeTimeout`` seconds to send `hello`
///    or it is cancelled (idle-peer hardening, mirroring `DACPServer`'s
///    idle-receive timeout).
/// 2. `hello` with a protocol version NEWER than ours →
///    `goodbye("protoMismatch")` and close (refuse-forward,
///    `CompanionProto.isIncompatible`). Otherwise the client is welcomed
///    with the latest cached snapshot — or, if no snapshot has been
///    broadcast yet, the `welcome` is deferred until the first
///    ``broadcast(_:)`` (the wiring broadcasts immediately after start, so
///    this window is milliseconds).
/// 3. Thereafter: `command` frames flow to ``onCommand``; every
///    ``broadcast(_:)`` fans a `state` frame out to all welcomed clients,
///    suppressed when `Equatable`-identical to the previous snapshot.
///
/// ## Structure (mirrors `DACPServer` deliberately)
/// All mutable state (`listener`, `clients`, `refused`, `latestSnapshot`)
/// is confined to ``queue``: the listener and every connection are started
/// with `queue: queue` so their callbacks already run there, and the public
/// entry points (`start(name:)`/`stop()`/`broadcast(_:)`/`accept(_:)`)
/// dispatch onto it rather than mutating from the caller's thread.
public final class CompanionServer: @unchecked Sendable {

    /// The outcome of one command, as the wiring layer reports it back.
    /// Mirrors `CompanionMessage.commandResult`'s payload; a struct (not a
    /// tuple) so the reply closure has a `Sendable`, `Equatable` currency.
    public struct CommandResult: Equatable, Sendable {
        public var applied: Bool
        public var refusalReason: String?
        public var autoSwappedCurrentDevice: Bool

        public init(applied: Bool, refusalReason: String? = nil, autoSwappedCurrentDevice: Bool = false) {
            self.applied = applied
            self.refusalReason = refusalReason
            self.autoSwappedCurrentDevice = autoSwappedCurrentDevice
        }
    }

    // MARK: - Wiring surface
    //
    // ALL callbacks are invoked on ``queue``. The wiring layer must hop to
    // main ASYNCHRONOUSLY (`DispatchQueue.main.async`) — a synchronous hop
    // from a callback could deadlock against `stop()`, which blocks the
    // caller (typically main) on this queue.

    /// One `command` frame from a client. `reply` may be called once from
    /// ANY thread (the wiring executes on main and replies from there); it
    /// hops back onto ``queue`` and sends the `commandResult` to that client
    /// if it is still connected.
    public var onCommand: (@Sendable (_ requestID: String, _ command: CompanionCommand, _ clientID: UUID, _ reply: @escaping @Sendable (CommandResult) -> Void) -> Void)?

    /// A client went away for any reason — clean close, error, handshake
    /// timeout, or `stop()` — after being accepted. Carries the same
    /// `clientID` that `onCommand` reported, so the wiring can end an
    /// orphaned Main Out drag held by exactly that client (plan T7 item 5).
    public var onClientDisconnected: (@Sendable (UUID) -> Void)?

    /// Observability: fired with the new total whenever the set of accepted
    /// clients grows or shrinks (including to 0 on `stop()`).
    public var onClientCountChanged: (@Sendable (Int) -> Void)?

    // MARK: - State (queue-confined)

    private let log = Logger(subsystem: "com.audiouter.Audiouter", category: "companion")
    private let queue = DispatchQueue(label: "CompanionServer")

    /// One accepted connection's lifecycle state. Mutated only on ``queue``.
    private final class Client {
        let id = UUID()
        let connection: NWConnection
        /// From `hello`; nil until then.
        var clientName: String?
        /// `hello` accepted (name + compatible version).
        var isHelloed = false
        /// `welcome` sent (requires a cached snapshot; may lag `isHelloed`).
        var isWelcomed = false
        /// Pending handshake-deadline work; cancelled by `hello`.
        var handshakeTimeout: DispatchWorkItem?

        init(connection: NWConnection) { self.connection = connection }
    }

    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    /// Connections refused at the client cap: kept alive just long enough to
    /// deliver their `goodbye`, then cancelled. Never counted as clients.
    private var refused: [ObjectIdentifier: NWConnection] = [:]
    /// The latest snapshot ``broadcast(_:)`` saw — replayed to each new
    /// client in its `welcome`.
    private var latestSnapshot: Snapshot?

    // MARK: - Limits

    /// How long an accepted connection may sit without completing its
    /// `hello` before it's treated as an idle/misbehaving peer (a scanner, a
    /// probing client, a half-open) and closed. A real companion app says
    /// hello within milliseconds of connecting.
    private static let handshakeTimeout: TimeInterval = 10
    /// Test-only: overrides ``handshakeTimeout`` so a cancellation test
    /// doesn't wait 10 real seconds. Nil (default) uses the real value.
    /// Same seam as `DACPServer.test_idleReceiveTimeoutOverride`.
    public var test_handshakeTimeoutOverride: TimeInterval?

    /// More phones than any household plausibly has; a bound so a
    /// misbehaving LAN peer can't grow `clients` without limit.
    private static let maxClients = 16
    /// Test-only: overrides ``maxClients`` so the cap test doesn't need 17
    /// real sockets.
    public var test_maxClientsOverride: Int?

    /// Per-frame size cap. The largest legitimate frame is a `command`
    /// (well under 1 KB); snapshots only ever travel server→client. Enforced
    /// both in the WebSocket options and in code (the in-code check also
    /// covers connections injected via the ``accept(_:)`` test seam, whose
    /// listener options we don't control).
    private static let maxMessageBytes = 64 * 1024

    public init() {}

    // MARK: - Lifecycle

    /// Advertise `_audiouter._tcp` as `name` (TXT: proto + name) on an
    /// ephemeral port and start accepting. Idempotent-ish: a second call
    /// restarts. `.async` for the same reason as `DACPServer.start`:
    /// `listener.start` is itself asynchronous, so there is no synchronous
    /// guarantee worth blocking the caller for.
    public func start(name: String) {
        queue.async { [weak self] in
            self?.startLocked(name: name)
        }
    }

    /// MUST only run on ``queue``. Calls `stopLocked()` directly, never the
    /// public `stop()` — that does `queue.sync`, which from here would
    /// recursively sync onto the queue we're already on and deadlock (the
    /// exact hazard `DACPServer.startLocked` documents).
    private func startLocked(name: String) {
        stopLocked()

        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxMessageBytes
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let listener: NWListener
        do {
            listener = try NWListener(using: params) // ephemeral port
        } catch {
            log.error("companion listener could not start: \(String(describing: error), privacy: .public)")
            return
        }

        var txt = NWTXTRecord()
        txt[CompanionProto.TXTKey.proto] = String(CompanionProto.version)
        txt[CompanionProto.TXTKey.name] = name
        listener.service = NWListener.Service(name: name, type: CompanionProto.serviceType, txtRecord: txt)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.log.error("companion listener failed: \(String(describing: error), privacy: .public)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        log.notice("companion server advertising \(name, privacy: .public) (\(CompanionProto.serviceType, privacy: .public))")
    }

    /// `.sync`, unlike `start`'s `.async`, for `DACPServer.stop`'s reason:
    /// the app-quit path calls this inline and must see the listener and
    /// every connection already cancelled when it returns — cancelling a
    /// handful of local objects is cheap, there is no network I/O to wait
    /// for. Do NOT call from ``queue`` (i.e. from inside a callback) — that
    /// would deadlock; callbacks have no reason to stop the server anyway.
    public func stop() {
        queue.sync { [weak self] in
            self?.stopLocked()
        }
    }

    /// MUST only run on ``queue``. Also called directly by
    /// `startLocked(name:)` — see its doc comment for why never via `stop()`.
    private func stopLocked() {
        listener?.cancel()
        listener = nil
        let dropped = clients
        clients.removeAll()
        for (_, client) in dropped {
            client.handshakeTimeout?.cancel()
            client.connection.cancel()
            onClientDisconnected?(client.id)
        }
        for (_, connection) in refused { connection.cancel() }
        refused.removeAll()
        // A restarted server must not welcome new clients with a snapshot
        // from its previous life; the wiring re-seeds on start.
        latestSnapshot = nil
        if !dropped.isEmpty {
            onClientCountChanged?(0)
        }
    }

    // MARK: - Broadcast

    /// Cache `snapshot` and fan a `state` frame out to every welcomed
    /// client; clients that said hello before any snapshot existed get their
    /// deferred `welcome` now instead. Suppressed (except for those pending
    /// welcomes) when identical to the last broadcast — the server is the
    /// one place snapshot-identity suppression lives (`Snapshot`'s doc).
    public func broadcast(_ snapshot: Snapshot) {
        queue.async { [weak self] in
            self?.broadcastLocked(snapshot)
        }
    }

    /// MUST only run on ``queue``.
    private func broadcastLocked(_ snapshot: Snapshot) {
        let changed = snapshot != latestSnapshot
        latestSnapshot = snapshot
        for client in clients.values where client.isHelloed {
            if !client.isWelcomed {
                sendWelcome(snapshot, to: client)
            } else if changed {
                send(.state(snapshot: snapshot), to: client)
            }
        }
    }

    // MARK: - Connection handling

    /// `internal` (not `private`) so `CompanionServerTests` can hand it a
    /// real loopback connection directly via `@testable import`, without
    /// going through `start(name:)`'s own listener — which binds ALL
    /// interfaces and Bonjour-advertises, neither of which tests need, and
    /// an all-interfaces bind is exactly what trips macOS's Application
    /// Firewall "accept incoming network connections?" prompt for the xctest
    /// process on a `swift test` run (same lesson as `DACPServer.accept`).
    /// Unlike `DACPServer.accept`, this dispatches onto ``queue`` itself, so
    /// the test seam never mutates state from the test's thread; the
    /// production `newConnectionHandler` already runs on ``queue`` and the
    /// extra hop is harmless.
    func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            self?.acceptLocked(connection)
        }
    }

    /// MUST only run on ``queue``.
    private func acceptLocked(_ connection: NWConnection) {
        guard clients.count < (test_maxClientsOverride ?? Self.maxClients) else {
            refuse(connection)
            return
        }

        let client = Client(connection: connection)
        clients[client.id] = client
        let id = client.id
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                // Close, error, and our own cancels all land here — the ONE
                // cleanup path, so there is exactly one disconnect signal
                // per client no matter how it died.
                self?.queue.async { self?.removeClient(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(client)

        // Handshake deadline: a peer that connects and never says hello
        // would otherwise sit in `clients` — and hold its kernel socket —
        // for as long as this server runs. Cancelled by `hello`; if it
        // fires, the state handler above cleans up like any other death.
        let timeout = test_handshakeTimeoutOverride ?? Self.handshakeTimeout
        let work = DispatchWorkItem { [weak self] in
            self?.clients[id]?.connection.cancel()
        }
        client.handshakeTimeout = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)

        onClientCountChanged?(clients.count)
    }

    /// Client-cap refusal: start the connection just long enough to deliver
    /// `goodbye("serverFull")`, then close. Held in `refused` (not
    /// `clients`) so it never counts against the cap it just hit, with its
    /// own deadline in case the WebSocket handshake never completes and the
    /// send can therefore never flush. MUST only run on ``queue``.
    private func refuse(_ connection: NWConnection) {
        log.notice("companion client refused: at capacity")
        let key = ObjectIdentifier(connection)
        refused[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.queue.async { self?.refused[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        sendRaw(.goodbye(reason: "serverFull"), over: connection) {
            connection.cancel()
        }
        let timeout = test_handshakeTimeoutOverride ?? Self.handshakeTimeout
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.refused[key]?.cancel()
        }
    }

    /// MUST only run on ``queue``.
    private func removeClient(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.handshakeTimeout?.cancel()
        onClientDisconnected?(client.id)
        onClientCountChanged?(clients.count)
    }

    /// Re-arming per-message receive. Completion runs on ``queue``.
    private func receiveLoop(_ client: Client) {
        let id = client.id
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, self.clients[id] != nil else { return }
            // Close, error, EOF, and oversize are all just "this client is
            // done": cancel and let the state handler do the one cleanup.
            if error != nil {
                client.connection.cancel()
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                client.connection.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                client.connection.cancel()
                return
            }
            guard data.count <= Self.maxMessageBytes else {
                self.log.notice("companion client sent an oversized frame (\(data.count) bytes); closing it")
                client.connection.cancel()
                return
            }
            self.handle(data, from: client)
            // `handle` may have cancelled the connection (malformed frame /
            // proto mismatch); its removal from `clients` is async via the
            // state handler, so a re-armed receive on a dying connection can
            // still happen — it just completes with an error and cancels a
            // second time, harmlessly.
            self.receiveLoop(client)
        }
    }

    /// One decoded-or-rejected frame. MUST only run on ``queue``.
    private func handle(_ data: Data, from client: Client) {
        guard let envelope = try? CompanionEnvelope.decode(data) else {
            // Malformed frame: close THIS client only; the server and every
            // other client are unaffected.
            log.notice("companion client sent a malformed frame; closing it")
            client.connection.cancel()
            return
        }

        switch envelope.message {
        case .hello(let clientName, let protoVersion):
            client.handshakeTimeout?.cancel()
            client.handshakeTimeout = nil
            guard !CompanionProto.isIncompatible(peerVersion: protoVersion) else {
                // Refuse-forward: a NEWER peer might mean things we can't
                // interpret; tell it why, then close (its state handler
                // cleans up as usual).
                log.notice("companion client refused: proto \(protoVersion) > \(CompanionProto.version)")
                send(.goodbye(reason: "protoMismatch"), to: client) {
                    client.connection.cancel()
                }
                return
            }
            client.clientName = clientName
            guard !client.isHelloed else { return } // duplicate hello: ignore
            client.isHelloed = true
            log.info("companion client connected: \(clientName, privacy: .public)")
            if let snapshot = latestSnapshot {
                sendWelcome(snapshot, to: client)
            }
            // else: welcome deferred to the first broadcast (see class doc).

        case .command(let requestID, let command):
            guard client.isHelloed else {
                // Commands before hello are a protocol violation, and the
                // sender's version was never checked — close it.
                client.connection.cancel()
                return
            }
            let clientID = client.id
            let reply: @Sendable (CommandResult) -> Void = { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard let stillConnected = self.clients[clientID] else { return }
                    self.send(.commandResult(
                        requestID: requestID,
                        applied: result.applied,
                        refusalReason: result.refusalReason,
                        autoSwappedCurrentDevice: result.autoSwappedCurrentDevice
                    ), to: stillConnected)
                }
            }
            if let onCommand {
                onCommand(requestID, command, clientID, reply)
            } else {
                reply(CommandResult(applied: false, refusalReason: "server not ready"))
            }

        case .welcome, .state, .commandResult, .goodbye, .unknown:
            // Server-to-client message types arriving FROM a client, or a
            // frame type from a future protocol: not actionable, not worth a
            // disconnect. Ignore (forward-compat, `CompanionMessage.unknown`).
            break
        }
    }

    // MARK: - Sending (queue-confined)

    /// The `welcome`'s `serverName` comes from the snapshot itself (the
    /// wiring sets `Snapshot.serverName` from the same host name it passes
    /// to `start(name:)`) — one source of truth, and the value the
    /// ``accept(_:)`` test seam exercises without ever starting a listener.
    private func sendWelcome(_ snapshot: Snapshot, to client: Client) {
        client.isWelcomed = true
        send(.welcome(serverName: snapshot.serverName, protoVersion: CompanionProto.version, snapshot: snapshot), to: client)
    }

    private func send(_ message: CompanionMessage, to client: Client, whenDone: (@Sendable () -> Void)? = nil) {
        sendRaw(message, over: client.connection, whenDone: whenDone)
    }

    /// Encode and send one text frame. `whenDone` fires on ``queue`` once
    /// the frame has been handed to the stack (used to close after a
    /// `goodbye` has actually been sent, not before).
    private func sendRaw(_ message: CompanionMessage, over connection: NWConnection, whenDone: (@Sendable () -> Void)? = nil) {
        guard let data = try? CompanionEnvelope(message: message).encoded() else {
            log.error("companion frame failed to encode; dropping it")
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "companionText", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            whenDone?()
        })
    }
}
