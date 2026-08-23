// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network
import AudioutProtocol

/// idle → connecting → handshaking → (awaitingApproval →) live →
/// disconnected(reason). `handshaking`/`live` are the two phases of
/// "connected": transport up + hello sent, vs. welcome received.
/// `awaitingApproval` is the optional third phase in between: the server
/// answered the hello with an `awaitingApproval` frame — the Mac is showing
/// its user an allow/deny prompt RIGHT NOW. It is NOT an error: the UI shows
/// "check your Mac" (see ``MacConnectionState/approvalStatus``) and the
/// connection is held open for minutes (``MacConnection/approvalTimeout``),
/// resolving into `welcome` → `live` or a `goodbye`. Terminal state is
/// always `disconnected` — there is no path out of it (a reconnect is a NEW
/// `MacConnection`; see ``ConnectionController``), which is what makes
/// zombie states impossible: after `disconnected`, every handler guards
/// out and the transport is detached.
enum MacConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case handshaking
    case awaitingApproval
    case live
    case disconnected(MacDisconnectReason)
}

/// The approval-flow slice of connection state, pre-digested for the
/// Connect tab: one value to switch on, with the human-readable copy
/// attached, instead of the UI pattern-matching goodbye strings. `nil` for
/// every state that has nothing to do with per-phone approval.
enum ApprovalStatus: Equatable, Sendable {
    /// The Mac is showing its user the allow/deny prompt. Long-lived and
    /// healthy — render a waiting surface, never an error.
    case waitingForApproval
    /// The Mac's user pressed "Don't Allow" (now or on an earlier connect —
    /// denials are remembered). TERMINAL: no auto-redial; recovery is on
    /// the Mac (remove this iPhone from Settings › General), then a manual
    /// reconnect.
    case denied
    /// The prompt sat unanswered past the Mac's deadline. Retryable:
    /// reconnecting asks again (and auto-reconnect does keep retrying).
    case promptTimedOut

    var headline: String {
        switch self {
        case .waitingForApproval: return "Waiting for approval"
        case .denied: return "This iPhone wasn't allowed"
        case .promptTimedOut: return "Your Mac didn't answer"
        }
    }

    var guidance: String {
        switch self {
        case .waitingForApproval:
            return "Audiout on your Mac is asking to allow this iPhone. Answer the prompt there — this can take a few minutes."
        case .denied:
            return "To connect, open Audiout's Settings › General on your Mac, remove this iPhone from Remembered iPhones, then connect again."
        case .promptTimedOut:
            return "The approval prompt on your Mac went unanswered. Reconnect to ask again."
        }
    }
}

extension MacConnectionState {
    /// See ``ApprovalStatus``. This is the API the Connect tab renders the
    /// approval flow from — `RemoteSession.connectionStatus.approvalStatus`.
    var approvalStatus: ApprovalStatus? {
        switch self {
        case .awaitingApproval:
            return .waitingForApproval
        case .disconnected(.goodbye(CompanionGoodbyeReason.notApproved)):
            return .denied
        case .disconnected(.goodbye(CompanionGoodbyeReason.approvalTimedOut)):
            return .promptTimedOut
        default:
            return nil
        }
    }
}

enum MacDisconnectReason: Equatable, Sendable {
    /// Transport-level error (dial failed, socket died, malformed frame,
    /// welcome never arrived within ``MacConnection/welcomeTimeout``).
    case failed(String)
    /// Peer liveness lost: either two consecutive unanswered socket-level
    /// pings (detected on the third keepalive tick, so up to
    /// 3 × `keepaliveInterval` ≈ 45s after the peer died), or no app-level
    /// inbound frame within ``MacConnection/appLivenessTimeout`` — the
    /// socket ponged but the Mac APP stopped producing frames (pings from
    /// its reaper, state broadcasts, command results), i.e. a hung app on a
    /// healthy socket.
    case keepaliveTimeout
    /// The server said goodbye; carries its reason (one of
    /// `CompanionGoodbyeReason`'s constants). See
    /// `MacDisconnectReason.reconnectClass` (ConnectionController.swift)
    /// for how each is treated; unknown reasons are retryable by design.
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
    /// An inbound WebSocket control frame (the server's ping, or a pong).
    /// Carries no payload the app cares about, but it is PROOF the peer's
    /// app code is alive — the server pings from its client-reaper loop, so
    /// a ping is app-level traffic, unlike the pongs our own pings elicit
    /// (those are answered inside Network.framework). Feeds the
    /// app-liveness clock and nothing else. Verified experimentally: with
    /// `autoReplyPing = true` inbound pings still surface in
    /// `receiveMessage` (opcode `.ping`, possibly nil data) AND get
    /// auto-answered.
    case activity
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
    case appIcons(page: Int, pageCount: Int, icons: [AppIconPayload])
}

/// One WebSocket session to one ``DiscoveredMac``. All state transitions
/// happen on the single serial `queue` injected at init (shared with
/// ``ConnectionController`` in production); `onEvent` fires on it too.
final class MacConnection: @unchecked Sendable {

    static let keepaliveInterval: TimeInterval = 15
    /// After this many unanswered pings the peer is treated as dead.
    static let maxMissedPings = 2

    /// Bound on `handshaking → live`: the server defers `welcome` until its
    /// first broadcast runs on its main actor, so a Mac with a stalled main
    /// thread would otherwise leave us in `.handshaking` FOREVER (the
    /// socket is healthy — no transport event will ever save us). `var` so
    /// tests shrink it; set before `start()`. An `awaitingApproval` frame
    /// cancels this deadline and replaces it with the (much longer)
    /// ``approvalTimeout`` — the FIX-D deadline was left cancellable for
    /// exactly this.
    var welcomeTimeout: TimeInterval = 10
    /// Bound on `awaitingApproval → live`: the server holds an unapproved
    /// connection for up to 180s while its user answers the prompt (they
    /// may be walking to the Mac), then sends `goodbye(approvalTimedOut)`
    /// itself. This local deadline is belt-and-braces for that goodbye
    /// getting lost — 180s + generous slack, NEVER shorter than the
    /// server's window. `var` so tests shrink it; set before `start()`.
    var approvalTimeout: TimeInterval = 240
    /// App-level liveness bound after `.live`: the server pings every
    /// client (its reaper loop) and those pings surface here as
    /// `.activity`, so a healthy-but-idle link still produces inbound
    /// frames well inside this window. No inbound frame of ANY kind for
    /// this long means the Mac app is hung even though the socket pongs.
    /// `var` so tests shrink it; set before `start()`.
    var appLivenessTimeout: TimeInterval = 60

    let mac: DiscoveredMac
    /// Set on `queue` (or before `start()` — dispatch's enqueue barrier
    /// makes pre-start assignment safe); never reassigned mid-session.
    var onEvent: (@Sendable (MacConnectionEvent) -> Void)?

    private let queue: DispatchQueue
    private let transport: MacTransport
    private let clientName: String
    /// The stable per-phone identity the hello carries (see
    /// ``ClientIdentity``) — what the Mac's approval is keyed on.
    private let clientID: String
    /// Touched on `queue` only.
    private(set) var state: MacConnectionState = .idle
    private(set) var missedPings = 0
    private var keepaliveTimer: DispatchSourceTimer?
    private var welcomeDeadline: DispatchWorkItem?
    /// Uptime of the last inbound frame (`.message` or `.activity`).
    private var lastInboundUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    init(mac: DiscoveredMac, transport: MacTransport, clientID: String, clientName: String, queue: DispatchQueue) {
        self.mac = mac
        self.transport = transport
        self.clientID = clientID
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
                message: .hello(clientID: clientID, clientName: clientName, protoVersion: CompanionProto.version)
            ).encoded() else {
                tearDown(.failed("could not encode hello"))
                return
            }
            transport.send(hello)
            lastInboundUptime = ProcessInfo.processInfo.systemUptime
            transition(to: .handshaking)
            startWelcomeDeadline()
            startKeepalive()
        case .message(let data):
            lastInboundUptime = ProcessInfo.processInfo.systemUptime
            handleFrame(data)
        case .activity:
            lastInboundUptime = ProcessInfo.processInfo.systemUptime
        case .failed(let message):
            tearDown(.failed(message))
        case .closed:
            tearDown(.failed("connection closed by peer"))
        }
    }

    private func handleFrame(_ data: Data) {
        switch state {
        case .handshaking, .awaitingApproval, .live: break
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
            switch state {
            case .handshaking, .awaitingApproval: break // approval resolved → welcome is the happy exit
            default: return
            }
            guard !CompanionProto.isIncompatible(peerVersion: protoVersion) else {
                tearDown(.incompatiblePeer)
                return
            }
            welcomeDeadline?.cancel()
            welcomeDeadline = nil
            transition(to: .live)
            onEvent?(.welcome(serverName: serverName, snapshot: snapshot))
        case .awaitingApproval:
            // Only meaningful as the server's answer to our hello; a repeat
            // must not restart the (already long) approval deadline.
            guard case .handshaking = state else { return }
            welcomeDeadline?.cancel()
            welcomeDeadline = nil
            transition(to: .awaitingApproval)
            startApprovalDeadline()
        case .state(let snapshot):
            onEvent?(.snapshot(snapshot))
        case .appIcons(let page, let pageCount, let icons):
            onEvent?(.appIcons(page: page, pageCount: pageCount, icons: icons))
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

    /// Keepalive tick: every `keepaliveInterval`, if the previous
    /// `maxMissedPings` pings all went unanswered, the peer is dead;
    /// otherwise send another ping. A pong resets the miss count. Timing
    /// honesty: a dead SOCKET is detected on the third tick after it died
    /// (ping, ping, verdict — up to 45s, not 30). The pings-and-pongs prove
    /// only the socket: the server's `autoReplyPing` answers our pings
    /// without app code on its side, which is why the tick ALSO enforces
    /// `appLivenessTimeout` over inbound frames (see `.activity`).
    func keepaliveTick() {
        dispatchPrecondition(condition: .onQueue(queue))
        switch state {
        case .handshaking, .awaitingApproval, .live: break
        default: return
        }
        if missedPings >= Self.maxMissedPings {
            tearDown(.keepaliveTimeout)
            return
        }
        // App-level liveness (independent of socket pongs, which the peer's
        // Network.framework answers even when the Mac app is hung).
        // Suspended while awaiting approval: the Mac app is deliberately
        // quiet for up to 180s while its prompt is up — the (longer)
        // approval deadline owns that window; socket death is still caught
        // by the ping misses above.
        if state != .awaitingApproval,
           ProcessInfo.processInfo.systemUptime - lastInboundUptime > appLivenessTimeout {
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

    private func startWelcomeDeadline() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.welcomeDeadline = nil
            guard case .handshaking = self.state else { return }
            self.tearDown(.failed("welcome timed out"))
        }
        welcomeDeadline = item
        queue.asyncAfter(deadline: .now() + welcomeTimeout, execute: item)
    }

    /// Replaces the welcome deadline once `awaitingApproval` arrives (same
    /// `welcomeDeadline` slot — exactly one handshake-phase deadline is ever
    /// armed). Fires only if the approval never resolves AND the server's
    /// own `goodbye(approvalTimedOut)` was lost.
    private func startApprovalDeadline() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.welcomeDeadline = nil
            guard case .awaitingApproval = self.state else { return }
            self.tearDown(.failed("approval wait timed out"))
        }
        welcomeDeadline = item
        queue.asyncAfter(deadline: .now() + approvalTimeout, execute: item)
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
        welcomeDeadline?.cancel()
        welcomeDeadline = nil
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
///
/// Probe cost (remaining, by design): the first connect to a Mac — and the
/// first after a TTL expiry or an invalidation — still costs one plain-TCP
/// probe, which the Mac's listener sees as a hello-less connection held in
/// its bounded pre-hello pending pool until its short pre-hello deadline
/// reaps it. ``ResolvedAddressCache`` keeps that to one probe per Mac per
/// TTL window instead of one per attempt.
// razor: IPv6-only Wi-Fi LANs are unsupported (probe fails → normal
// connection-failure surface + backoff retry). Upgrade path: bracketed
// `ws://[addr]/` with a percent-encoded zone, gated on a real-hardware
// interop test — same deferred-IPv6 posture as NativeDiscovery.
/// Cache of resolve-probe results, keyed by `DiscoveredMac.id`. Each probe
/// is not free on the SERVER either: the plain-TCP connect fires the Mac
/// listener's `newConnectionHandler` and holds one of its (bounded)
/// pre-hello pending-pool slots until its pre-hello deadline reaps it — so
/// a reconnect storm must not re-probe every attempt. The TTL is short
/// because a Mac's LAN address CAN change (DHCP renewal, interface flap),
/// and a stale hit self-heals: the dial fails fast, the entry is
/// invalidated, and the next attempt re-probes.
final class ResolvedAddressCache: @unchecked Sendable {
    static let shared = ResolvedAddressCache()
    static let ttl: TimeInterval = 30

    private let lock = NSLock()
    private var entries: [String: (url: URL, storedAt: TimeInterval)] = [:]
    private let now: () -> TimeInterval

    /// `now` injected (uptime-based by default) so TTL expiry is testable.
    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func url(forMacID id: String) -> URL? {
        lock.withLock {
            guard let entry = entries[id], now() - entry.storedAt < Self.ttl else { return nil }
            return entry.url
        }
    }

    func store(_ url: URL, forMacID id: String) {
        lock.withLock { entries[id] = (url, now()) }
    }

    func invalidate(macID id: String) {
        lock.withLock { entries[id] = nil }
    }
}

final class ResolvedWebSocketTransport: MacTransport, @unchecked Sendable {

    static let probeTimeout: TimeInterval = 10
    /// Inbound frame cap (length-safe decode): a `Snapshot` is a few KB;
    /// 1 MB is generous headroom, not an invitation.
    static let maxInboundFrameBytes = 1_048_576

    var events: (@Sendable (MacTransportEvent) -> Void)?

    private let macID: String
    private let endpoint: NWEndpoint
    private let cache: ResolvedAddressCache
    private var queue: DispatchQueue?
    /// Internal (not private) so tests can assert the probe is gone after
    /// every exit path; all exits funnel through `abandonProbe()`.
    private(set) var probe: NWConnection?
    private var probeTimeoutItem: DispatchWorkItem?
    /// True while dialing an address served from `cache` — a dial failure
    /// then invalidates the entry so the next attempt re-probes.
    private var dialedFromCache = false
    private var connection: NWConnection?
    private var finished = false // failed once or cancelled — emit nothing more

    init(mac: DiscoveredMac, cache: ResolvedAddressCache = .shared) {
        self.macID = mac.id
        self.endpoint = mac.endpoint
        self.cache = cache
    }

    func start(queue: DispatchQueue) {
        self.queue = queue
        queue.async {
            guard !self.finished else { return }
            // Skip the probe entirely when we already hold a fresh address
            // for this Mac — the common reconnect case.
            if let cached = self.cache.url(forMacID: self.macID) {
                self.dialedFromCache = true
                self.dial(url: cached, on: queue)
            } else {
                self.startProbe(on: queue)
            }
        }
    }

    func cancel() {
        guard let queue else { return }
        queue.async {
            self.finished = true
            self.events = nil
            self.abandonProbe()
            self.connection?.cancel()
            self.connection = nil
        }
    }

    /// The ONE probe exit: every path out of the resolve phase — success,
    /// `.failed`, `.waiting`, timeout, external cancel — must release the
    /// probe connection promptly (an un-cancelled probe holds a server-side
    /// pending slot until the server reaps it).
    private func abandonProbe() {
        probeTimeoutItem?.cancel()
        probeTimeoutItem = nil
        probe?.stateUpdateHandler = nil
        probe?.cancel()
        probe = nil
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
                self.abandonProbe()
                if case let .hostPort(host, port) = remote,
                   let url = Self.wsURL(host: host, port: port) {
                    self.cache.store(url, forMacID: self.macID)
                    self.dial(url: url, on: queue)
                } else {
                    self.fail("resolved no usable IPv4 address for \(self.endpoint)")
                }
            case .failed(let error):
                // Cancel even though the connection already failed —
                // Network.framework wants a cancel to release resources,
                // and skipping it here leaked the NWConnection.
                self.abandonProbe()
                self.fail("resolve failed: \(error)")
            case .waiting(let error):
                // A probe to a vanished service can wait forever; treat it
                // as failure now — the reconnect backoff owns retrying.
                self.abandonProbe()
                self.fail("resolve stalled: \(error)")
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.probe != nil else { return }
            self.abandonProbe()
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
            // The resolved address can carry an interface scope
            // ("192.168.4.84%en0" — seen live on iOS 27); a bare "%" is an
            // illegal URL escape, so interpolating it makes URL(string:)
            // return nil and the connect die as "no usable IPv4 address".
            // IPv4 needs no scope to dial — drop it.
            hostString = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
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
                // The address we dialed didn't pan out — don't let the
                // cache serve it to the next attempt.
                self.cache.invalidate(macID: self.macID)
                self.fail("\(error)")
            case .waiting(let error):
                // We dialed a freshly resolved address; if it isn't
                // accepting NOW, fail fast and let the backoff retry rather
                // than sitting in `.waiting` (the exact hang the ws:// URL
                // requirement produces when violated — never wait it out).
                self.cache.invalidate(macID: self.macID)
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
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .close:
                    self.finished = true
                    self.events?(.closed)
                    return
                case .ping, .pong:
                    // The server's app-level ping (auto-answered by
                    // `autoReplyPing`; delivery verified experimentally).
                    // It can arrive with nil/empty data — falling through
                    // to the empty-frame check below would misread it as a
                    // CLOSE and kill a healthy session.
                    self.events?(.activity)
                    self.receiveLoop(connection)
                    return
                default:
                    break
                }
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
