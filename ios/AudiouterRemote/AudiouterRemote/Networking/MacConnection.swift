// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network
import AudiouterProtocol

/// idle → connecting → handshaking → live → disconnected(reason).
/// `handshaking`/`live` are the two phases of "connected": transport up +
/// hello sent, vs. welcome received. Terminal state is always
/// `disconnected` — there is no path out of it (a reconnect is a NEW
/// `MacConnection`; see ``ConnectionController``), which is what makes
/// zombie states impossible: after `disconnected`, every handler guards
/// out and the transport is detached.
enum MacConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case handshaking
    case live
    case disconnected(MacDisconnectReason)
}

enum MacDisconnectReason: Equatable, Sendable {
    /// Transport-level error (dial failed, socket died, malformed frame).
    case failed(String)
    /// Two consecutive unanswered keepalive pings.
    case keepaliveTimeout
    /// The server said goodbye; carries its reason
    /// (`"disabled"` / `"shutdown"` / `"protoMismatch"`).
    case goodbye(String)
    /// The peer speaks a NEWER protocol than us (refuse-forward).
    case incompatiblePeer
    /// We closed on purpose (background teardown, user disconnect, or
    /// replacement by a newer connection). The one non-error reason: the
    /// app layer must never surface it as a failure.
    case closedByUs
}

enum MacTransportEvent: Sendable {
    case ready
    case message(Data)
    case failed(String)
    case closed
}

/// The socket seam: ``ResolvedWebSocketTransport`` is the real one; tests
/// inject a fake so ``MacConnection``'s state machine runs without sockets.
/// Contract: `events` (and ping pongs) are delivered on the queue passed to
/// `start(queue:)`, and nothing is delivered after `cancel()`.
protocol MacTransport: AnyObject, Sendable {
    var events: (@Sendable (MacTransportEvent) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func send(_ data: Data)
    /// WebSocket ping; `onPong` fires on the same queue if a pong arrives.
    func sendPing(onPong: @escaping @Sendable () -> Void)
    func cancel()
}

enum MacConnectionEvent: Sendable {
    case stateChanged(MacConnectionState)
    case welcome(serverName: String, snapshot: Snapshot)
    case snapshot(Snapshot)
    case commandResult(requestID: String, applied: Bool, refusalReason: String?, autoSwappedCurrentDevice: Bool)
}

/// One WebSocket session to one ``DiscoveredMac``. All state transitions
/// happen on the single serial `queue` injected at init (shared with
/// ``ConnectionController`` in production); `onEvent` fires on it too.
final class MacConnection: @unchecked Sendable {

    static let keepaliveInterval: TimeInterval = 15
    /// After this many unanswered pings the peer is treated as dead.
    static let maxMissedPings = 2

    let mac: DiscoveredMac
    var onEvent: (@Sendable (MacConnectionEvent) -> Void)?

    private let queue: DispatchQueue
    private let transport: MacTransport
    private let clientName: String
    /// Touched on `queue` only.
    private(set) var state: MacConnectionState = .idle
    private(set) var missedPings = 0
    private var keepaliveTimer: DispatchSourceTimer?

    init(mac: DiscoveredMac, transport: MacTransport, clientName: String, queue: DispatchQueue) {
        self.mac = mac
        self.transport = transport
        self.clientName = clientName
        self.queue = queue
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    /// Deliberate teardown — the ONLY external way to end the session.
    /// `.closedByUs` is the quiet path (expected drop, no error surface).
    func close(reason: MacDisconnectReason = .closedByUs) {
        queue.async { self.tearDown(reason) }
    }

    /// Same-queue variants for ``ConnectionController``, which shares this
    /// connection's serial queue: calling the async versions from the queue
    /// itself would interleave an extra hop between a controller action and
    /// the connection reacting to it (and make state reads racy).
    func startOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        startLocked()
    }

    func closeOnQueue(reason: MacDisconnectReason = .closedByUs) {
        dispatchPrecondition(condition: .onQueue(queue))
        tearDown(reason)
    }

    func send(command: CompanionCommand, requestID: String) {
        queue.async {
            guard case .live = self.state else { return }
            guard let data = try? CompanionEnvelope(
                message: .command(requestID: requestID, command: command)
            ).encoded() else { return }
            self.transport.send(data)
        }
    }

    // MARK: State machine (on `queue`)

    private func startLocked() {
        guard case .idle = state else { return }
        transition(to: .connecting)
        transport.events = { [weak self] event in
            self?.handleTransportEvent(event)
        }
        transport.start(queue: queue)
    }

    private func handleTransportEvent(_ event: MacTransportEvent) {
        if case .disconnected = state { return }
        switch event {
        case .ready:
            guard case .connecting = state else { return }
            guard let hello = try? CompanionEnvelope(
                message: .hello(clientName: clientName, protoVersion: CompanionProto.version)
            ).encoded() else {
                tearDown(.failed("could not encode hello"))
                return
            }
            transport.send(hello)
            transition(to: .handshaking)
            startKeepalive()
        case .message(let data):
            handleFrame(data)
        case .failed(let message):
            tearDown(.failed(message))
        case .closed:
            tearDown(.failed("connection closed by peer"))
        }
    }

    private func handleFrame(_ data: Data) {
        switch state {
        case .handshaking, .live: break
        default: return
        }
        // Length safety is enforced below the decode (the transport caps
        // frame size); here a malformed frame is fatal — a server sending
        // nonsense is a broken session, not something to limp past.
        guard let envelope = try? CompanionEnvelope.decode(data) else {
            tearDown(.failed("malformed frame"))
            return
        }
        guard !CompanionProto.isIncompatible(peerVersion: envelope.v) else {
            tearDown(.incompatiblePeer)
            return
        }
        switch envelope.message {
        case .welcome(let serverName, let protoVersion, let snapshot):
            guard case .handshaking = state else { return }
            guard !CompanionProto.isIncompatible(peerVersion: protoVersion) else {
                tearDown(.incompatiblePeer)
                return
            }
            transition(to: .live)
            onEvent?(.welcome(serverName: serverName, snapshot: snapshot))
        case .state(let snapshot):
            onEvent?(.snapshot(snapshot))
        case .commandResult(let requestID, let applied, let refusalReason, let autoSwapped):
            onEvent?(.commandResult(
                requestID: requestID,
                applied: applied,
                refusalReason: refusalReason,
                autoSwappedCurrentDevice: autoSwapped
            ))
        case .goodbye(let reason):
            tearDown(.goodbye(reason))
        case .hello, .command:
            break // client→server shapes; a server never sends them — ignore
        case .unknown:
            break // newer peer's message type — ignore by design
        }
    }

    /// App-level keepalive: every `keepaliveInterval`, if the previous
    /// `maxMissedPings` pings all went unanswered, the peer is dead;
    /// otherwise send another ping. A pong resets the miss count. The
    /// server's `autoReplyPing` answers our pings without app code on its
    /// side.
    func keepaliveTick() {
        switch state {
        case .handshaking, .live: break
        default: return
        }
        if missedPings >= Self.maxMissedPings {
            tearDown(.keepaliveTimeout)
            return
        }
        missedPings += 1
        transport.sendPing { [weak self] in
            guard let self else { return }
            if case .disconnected = self.state { return }
            self.missedPings = 0
        }
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.keepaliveInterval,
            repeating: Self.keepaliveInterval
        )
        timer.setEventHandler { [weak self] in self?.keepaliveTick() }
        timer.resume()
        keepaliveTimer = timer
    }

    private func tearDown(_ reason: MacDisconnectReason) {
        if case .disconnected = state { return }
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        transport.events = nil
        transport.cancel()
        transition(to: .disconnected(reason))
    }

    private func transition(to newState: MacConnectionState) {
        state = newState
        onEvent?(.stateChanged(newState))
    }
}

/// The real transport: **resolve, then dial `ws://IP:PORT/`**.
///
/// ## Why not dial the Bonjour `.service` endpoint directly (the plan's
/// first suggestion)?
///
/// `CompanionServerTests` proved (standalone repro, this SDK) that a
/// Network.framework WebSocket CLIENT completes the HTTP upgrade only when
/// dialing a `ws://` **URL** endpoint — with a plain host/port endpoint the
/// upgrade aborts (ECONNABORTED) and the connection sits in `.waiting`
/// forever, never `.failed`. A `.service` endpoint is not a URL endpoint
/// either, so it is exposed to the same failure — and crucially its failure
/// mode would be an indefinite `.waiting`, indistinguishable from a slow
/// network, so "attempt it first and observe it failing fast" is not
/// actually possible. Racing a possibly-doomed attempt against a timeout
/// buys nothing over one cheap resolve probe, so we go straight to
/// resolve-then-dial:
///
/// 1. a short plain-TCP probe `NWConnection` to the `.service` endpoint
///    (the `NativeDiscovery` `resolvedAddress` idiom) reads the resolved
///    host/port off `currentPath.remoteEndpoint`, then
/// 2. the WebSocket connection dials `ws://IP:PORT/`.
///
/// The probe is forced to IPv4, mirroring `NativeDiscovery.probeIPv4First`:
/// an unconstrained probe on a dual-stack LAN can settle on an IPv6
/// link-local address, whose zone index does not survive a URL round-trip.
// razor: IPv6-only Wi-Fi LANs are unsupported (probe fails → normal
// connection-failure surface + backoff retry). Upgrade path: bracketed
// `ws://[addr]/` with a percent-encoded zone, gated on a real-hardware
// interop test — same deferred-IPv6 posture as NativeDiscovery.
final class ResolvedWebSocketTransport: MacTransport, @unchecked Sendable {

    static let probeTimeout: TimeInterval = 10
    /// Inbound frame cap (length-safe decode): a `Snapshot` is a few KB;
    /// 1 MB is generous headroom, not an invitation.
    static let maxInboundFrameBytes = 1_048_576

    var events: (@Sendable (MacTransportEvent) -> Void)?

    private let endpoint: NWEndpoint
    private var queue: DispatchQueue?
    private var probe: NWConnection?
    private var probeTimeoutItem: DispatchWorkItem?
    private var connection: NWConnection?
    private var finished = false // failed once or cancelled — emit nothing more

    init(mac: DiscoveredMac) {
        self.endpoint = mac.endpoint
    }

    func start(queue: DispatchQueue) {
        self.queue = queue
        queue.async { self.startProbe(on: queue) }
    }

    func cancel() {
        guard let queue else { return }
        queue.async {
            self.finished = true
            self.events = nil
            self.probeTimeoutItem?.cancel()
            self.probeTimeoutItem = nil
            self.probe?.cancel()
            self.probe = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    func send(_ data: Data) {
        queue?.async {
            guard let connection = self.connection else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
    }

    func sendPing(onPong: @escaping @Sendable () -> Void) {
        queue?.async {
            guard let connection = self.connection, let queue = self.queue else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            metadata.setPongHandler(queue) { error in
                if error == nil { onPong() }
            }
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
            connection.send(
                content: Data(),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
    }

    // MARK: Resolve (on `queue`)

    private func startProbe(on queue: DispatchQueue) {
        guard !finished else { return }
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let probe = NWConnection(to: endpoint, using: params)
        self.probe = probe
        probe.stateUpdateHandler = { [weak self] state in
            guard let self, probe === self.probe else { return }
            switch state {
            case .ready:
                let remote = probe.currentPath?.remoteEndpoint
                self.probeTimeoutItem?.cancel()
                self.probeTimeoutItem = nil
                probe.stateUpdateHandler = nil
                probe.cancel()
                self.probe = nil
                if case let .hostPort(host, port) = remote,
                   let url = Self.wsURL(host: host, port: port) {
                    self.dial(url: url, on: queue)
                } else {
                    self.fail("resolved no usable IPv4 address for \(self.endpoint)")
                }
            case .failed(let error):
                self.probe = nil
                self.fail("resolve failed: \(error)")
            case .waiting(let error):
                // A probe to a vanished service can wait forever; treat it
                // as failure now — the reconnect backoff owns retrying.
                probe.cancel()
                self.probe = nil
                self.fail("resolve stalled: \(error)")
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let probe = self.probe else { return }
            self.probeTimeoutItem = nil
            probe.cancel()
            self.probe = nil
            self.fail("resolve timed out")
        }
        probeTimeoutItem = timeout
        queue.asyncAfter(deadline: .now() + Self.probeTimeout, execute: timeout)
        probe.start(queue: queue)
    }

    /// Pure URL construction from a resolved remote endpoint.
    static func wsURL(host: NWEndpoint.Host, port: NWEndpoint.Port) -> URL? {
        let hostString: String
        switch host {
        case .ipv4(let address):
            hostString = "\(address)"
        case .name(let name, _):
            hostString = name
        case .ipv6:
            return nil // razor ceiling above: IPv6 dialing deferred
        @unknown default:
            return nil
        }
        return URL(string: "ws://\(hostString):\(port.rawValue)/")
    }

    // MARK: Dial (on `queue`)

    private func dial(url: URL, on queue: DispatchQueue) {
        guard !finished else { return }
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxInboundFrameBytes
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let connection = NWConnection(to: .url(url), using: params)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, connection === self.connection else { return }
            switch state {
            case .ready:
                self.receiveLoop(connection)
                self.events?(.ready)
            case .failed(let error):
                self.fail("\(error)")
            case .waiting(let error):
                // We dialed a freshly resolved address; if it isn't
                // accepting NOW, fail fast and let the backoff retry rather
                // than sitting in `.waiting` (the exact hang the ws:// URL
                // requirement produces when violated — never wait it out).
                connection.cancel()
                self.fail("dial stalled: \(error)")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.finished, connection === self.connection else { return }
            if error != nil {
                self.fail("receive failed")
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                self.finished = true
                self.events?(.closed)
                return
            }
            guard let data, !data.isEmpty else {
                self.finished = true
                self.events?(.closed)
                return
            }
            self.events?(.message(data))
            self.receiveLoop(connection)
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        events?(.failed(message))
    }
}
