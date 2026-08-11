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
/// 1. Client connects; it enters a bounded PENDING pool — it does NOT count
///    against ``maxClients`` until it completes a valid `hello`, so
///    pre-upgrade probes (the iOS client's own address-resolve probe, port
///    scanners, half-opens) can never exhaust the client cap. It has
///    ``preHelloTimeout`` seconds to say `hello` or it is cancelled; beyond
///    ``pendingCap`` simultaneous un-helloed connections, new ones are
///    dropped immediately (flood backstop — every refused socket is a
///    process-wide fd this app's AirPlay/PTP/DACP work also needs).
/// 2. `hello` with a protocol version NEWER than ours →
///    `goodbye("protoMismatch")` and close (refuse-forward,
///    `CompanionProto.isIncompatible`). A missing/non-UUID `clientID` →
///    `goodbye("invalidClientID")` and close. At the client cap →
///    `goodbye("serverFull")` and close. Otherwise the connection moves to
///    the AWAITING pool (T24 per-phone approval gate) and the app layer is
///    asked via ``onApprovalRequest``; the answer (see ``ApprovalDecision``)
///    settles it: `.approved` → PROMOTED into `clients` (see
///    ``promote(_:)`` — the single decision point) and welcomed with the
///    latest cached snapshot — or, if no snapshot has been broadcast yet,
///    the `welcome` is deferred until the first ``broadcast(_:)`` (the
///    wiring broadcasts immediately after start, so this window is
///    milliseconds); `.denied` → `goodbye("notApproved")` and close;
///    `.pending` → an `awaitingApproval` frame (the phone shows "check your
///    Mac") and the connection is held — released from the pre-hello
///    deadline, bounded instead by the much more generous
///    ``approvalTimeout`` (the user may be walking to the Mac), after which
///    it gets `goodbye("approvalTimedOut")` and may simply reconnect. The
///    server never blocks on the decision; an unwired ``onApprovalRequest``
///    means the deadline eventually closes the connection — closed by
///    default, never silently open.
/// 3. Thereafter: `command` frames flow to ``onCommand``; every
///    ``broadcast(_:)`` fans a `state` frame out to all welcomed clients,
///    suppressed when `Equatable`-identical to the previous snapshot. The
///    server pings each promoted client every ``pingInterval`` and reaps any
///    with no inbound activity (frame or pong) for ``livenessTimeout`` — a
///    phone that vanishes without a FIN (airplane mode, out of range) must
///    not hold its slot, its fd, or an orphaned Main Out drag forever.
///
/// ## Structure (mirrors `DACPServer` deliberately)
/// All mutable state (`listener`, `pending`, `clients`, `latestSnapshot`)
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

    /// The app layer's verdict on one helloed connection (T24). `.pending`
    /// may be sent first — the server then sends the client
    /// `awaitingApproval` and keeps holding it — and must be followed
    /// (possibly minutes later) by exactly one `.approved`/`.denied`; a
    /// verdict for a connection that already died or timed out is a no-op.
    public enum ApprovalDecision: Sendable {
        case approved, denied, pending
    }

    // MARK: - Wiring surface
    //
    // ALL callbacks are invoked on ``queue``, and always via a fresh
    // `queue.async` hop — never inline from a section that may be holding
    // the queue while another thread blocks in `stop()`'s `queue.sync`. That
    // makes even a SYNCHRONOUS main-thread hop inside a callback unable to
    // deadlock against `stop()` (the callback only runs after the sync
    // section has returned). Wirings should still hop to main
    // asynchronously (`DispatchQueue.main.async`) as a matter of hygiene.

    /// One `command` frame from a client. `reply` may be called once from
    /// ANY thread (the wiring executes on main and replies from there); it
    /// hops back onto ``queue`` and sends the `commandResult` to that client
    /// if it is still connected.
    public var onCommand: (@Sendable (_ requestID: String, _ command: CompanionCommand, _ clientID: UUID, _ reply: @escaping @Sendable (CommandResult) -> Void) -> Void)?

    /// T24 approval gate: one valid, compatible, within-cap `hello` arrived
    /// from the phone identified by `clientID` (already validated as a UUID
    /// string and canonicalized to uppercase; `clientName` already
    /// truncated). The wiring answers via `decide` — from any thread, any
    /// time later (see ``ApprovalDecision``); the server holds the
    /// connection meanwhile and NEVER blocks waiting. Left nil, no client
    /// is ever promoted (the awaiting deadline reaps them) — the trust
    /// boundary fails closed.
    public var onApprovalRequest: (@Sendable (_ clientID: String, _ clientName: String, _ decide: @escaping @Sendable (ApprovalDecision) -> Void) -> Void)?

    /// A client went away for any reason — clean close, error, liveness
    /// reaping, or `stop()` — after being accepted (helloed + promoted;
    /// connections that die before their `hello` are removed silently).
    /// Carries the same `clientID` that `onCommand` reported, so the wiring
    /// can end an orphaned Main Out drag held by exactly that client (plan
    /// T7 item 5).
    public var onClientDisconnected: (@Sendable (UUID) -> Void)?

    /// Observability: fired with the new total whenever the set of accepted
    /// clients grows or shrinks (including to 0 on `stop()`). Pending
    /// (un-helloed) connections are never counted.
    public var onClientCountChanged: (@Sendable (Int) -> Void)?

    // MARK: - State (queue-confined)

    private let log = Logger(subsystem: "com.audiouter.Audiouter", category: "companion")
    private let queue = DispatchQueue(label: "CompanionServer")

    /// One connection's lifecycle state (pending or promoted). Mutated only
    /// on ``queue``.
    private final class Client {
        let id = UUID()
        let connection: NWConnection
        /// From `hello`, truncated to ``maxClientNameLength``; nil until then.
        var clientName: String?
        /// From `hello`, validated as a UUID and canonicalized (T24); nil
        /// until then. This is the phone's persistent identity — ``id`` above
        /// is only this CONNECTION's handle.
        var phoneClientID: String?
        /// `welcome` sent (requires a cached snapshot; may lag promotion).
        var isWelcomed = false
        /// The active deadline work item: the pre-hello deadline while in
        /// `pending`, re-armed as the (much longer) approval deadline while
        /// in `awaiting`; cancelled on promotion. For a connection refused
        /// AT hello (proto mismatch / bad clientID / server full) it is
        /// deliberately left armed as the close backstop in case the goodbye
        /// send never flushes.
        var handshakeTimeout: DispatchWorkItem?
        /// Last inbound sign of life — any frame, ping, or pong. Basis of
        /// the liveness reaper.
        var lastActivity = Date()

        init(connection: NWConnection) { self.connection = connection }
    }

    private var listener: NWListener?
    /// Accepted but not yet helloed. Bounded by ``pendingCap``; never
    /// counted against ``maxClients``; reaped by the pre-hello deadline.
    private var pending: [UUID: Client] = [:]
    /// Helloed, valid, but held for the T24 approval gate — not yet counted,
    /// broadcast to, or command-eligible. Bounded by ``awaitingCap``; reaped
    /// by the ``approvalTimeout`` deadline, NOT the pre-hello one.
    private var awaiting: [UUID: Client] = [:]
    /// Helloed + promoted clients — the only connections that count, get
    /// broadcasts, and may send commands.
    private var clients: [UUID: Client] = [:]
    /// The latest snapshot ``broadcast(_:)`` saw — replayed to each new
    /// client in its `welcome`.
    private var latestSnapshot: Snapshot?
    /// Fires ``livenessTick()`` every ``pingInterval`` while the server has
    /// (or has had) clients; torn down by `stop()`.
    private var livenessTimer: DispatchSourceTimer?

    // MARK: - Limits

    /// How long an accepted connection may sit without completing its
    /// `hello` before it's treated as an idle/misbehaving peer (a scanner, a
    /// probing client, a half-open) and closed. A real companion app says
    /// hello within milliseconds of connecting; the iOS app's own
    /// address-resolve probe never upgrades at all and is exactly what this
    /// deadline reaps.
    private static let preHelloTimeout: TimeInterval = 5
    /// Test-only: overrides ``preHelloTimeout`` so a cancellation test
    /// doesn't wait real seconds. Nil (default) uses the real value.
    /// Same seam as `DACPServer.test_idleReceiveTimeoutOverride`.
    public var test_handshakeTimeoutOverride: TimeInterval?

    /// More phones than any household plausibly has; a bound so a
    /// misbehaving LAN peer can't grow `clients` without limit.
    private static let maxClients = 16
    /// Test-only: overrides ``maxClients`` so the cap test doesn't need 17
    /// real sockets.
    public var test_maxClientsOverride: Int?

    /// How long a helloed connection may sit in ``awaiting`` before the
    /// approval question is considered abandoned and the connection is
    /// closed with `goodbye("approvalTimedOut")`. Deliberately generous —
    /// the Mac's user may be in another room when the prompt appears — and
    /// retryable: the phone reconnects and asks again.
    private static let approvalTimeout: TimeInterval = 180
    /// Test-only: overrides ``approvalTimeout``.
    public var test_approvalTimeoutOverride: TimeInterval?

    /// Hard bound on simultaneous awaiting-approval connections — a LAN
    /// peer cycling fresh clientIDs must not grow `awaiting` (each entry
    /// holds an fd for up to ``approvalTimeout``) without limit. Beyond it,
    /// a helloing client gets the same `serverFull` refusal as the client
    /// cap. Smaller than ``maxClients``: a household legitimately onboards
    /// one or two phones at a time.
    private static let awaitingCap = 8
    /// Test-only: overrides ``awaitingCap``.
    public var test_awaitingCapOverride: Int?

    /// Hard bound on simultaneous un-helloed connections. Beyond it, new
    /// connections are cancelled on arrival with no courtesy goodbye — under
    /// a connect-flood the priority is not exhausting this process's file
    /// descriptors (which AirPlay RTP, PTP, DACP and Bonjour also draw on).
    /// razor: a fancier accept-rate limiter (token bucket) was considered
    /// and skipped — this cap already bounds fds at pendingCap + maxClients,
    /// and each over-cap socket is closed immediately.
    private static let pendingCap = 32
    /// Test-only: overrides ``pendingCap`` so the flood test doesn't need
    /// 33 real sockets.
    public var test_pendingCapOverride: Int?

    /// Per-frame size cap. The largest legitimate frame is a `command`
    /// (well under 1 KB); snapshots only ever travel server→client. Enforced
    /// both in the WebSocket options and in code (the in-code check also
    /// covers connections injected via the ``accept(_:)`` test seam, whose
    /// listener options we don't control).
    private static let maxMessageBytes = 64 * 1024

    /// The iOS client caps INBOUND messages at 1 MB — a server frame larger
    /// than this deterministically kills the phone's connection, so it is
    /// loudly logged (see `sendRaw`). Snapshot size is the dispatcher/
    /// builder's to bound; the server can only observe it.
    private static let iosInboundCapBytes = 1_048_576

    /// `hello.clientName` is attacker-controlled input; bound it at parse so
    /// no downstream consumer (logs, future UI) ever sees an unbounded string.
    private static let maxClientNameLength = 64

    /// `hello.clientID` is attacker-controlled too: length-capped before the
    /// (already strict, canonical-36-char) `UUID(uuidString:)` parse, so a
    /// deliberately huge string is rejected without even being scanned.
    private static let maxClientIDLength = 64

    /// Server-initiated WebSocket ping cadence per promoted client. A live
    /// phone's stack auto-pongs; the pong (or any frame) refreshes
    /// `lastActivity`.
    private static let pingInterval: TimeInterval = 20
    /// Test-only: overrides ``pingInterval`` (read when the liveness timer
    /// is created, i.e. at the first client promotion after start/stop).
    public var test_pingIntervalOverride: TimeInterval?

    /// A promoted client with no inbound activity for this long is dead —
    /// with ``pingInterval`` 20 s that is ~3 unanswered pings — and is
    /// cancelled, which fires ``onClientDisconnected`` like any other death.
    private static let livenessTimeout: TimeInterval = 60
    /// Test-only: overrides ``livenessTimeout``.
    public var test_livenessTimeoutOverride: TimeInterval?

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
        stopLocked(reason: CompanionGoodbyeReason.shutdown)

        // TCP keepalive is defense in depth under the WebSocket-level
        // liveness reaper: it lets the kernel notice a peer that vanished
        // without a FIN even if this process's timer logic ever regresses.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let params = NWParameters(tls: nil, tcp: tcp)
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
    ///
    /// `reason` becomes a best-effort `goodbye` to every promoted client, so
    /// the phone learns the close was deliberate instead of seeing a bare
    /// transport error and redialing forever. Pass
    /// `CompanionGoodbyeReason.disabled` when the user turned remote control
    /// off, `shutdown` (the default) when the app is quitting — the phone
    /// treats them differently (settle quietly vs. reconnect on
    /// re-advertise). Best-effort: `stop()` still returns synchronously with
    /// the listener cancelled and all state cleared, but each connection is
    /// cancelled from its goodbye-send completion (an immediate cancel would
    /// abort the enqueued frame), with a 250 ms backstop cancel so a wedged
    /// send can never hold a socket — quit is never blocked waiting for any
    /// of it.
    public func stop(reason: String = CompanionGoodbyeReason.shutdown) {
        queue.sync { [weak self] in
            self?.stopLocked(reason: reason)
        }
    }

    /// MUST only run on ``queue``. Also called directly by
    /// `startLocked(name:)` — see its doc comment for why never via `stop()`.
    private func stopLocked(reason: String) {
        listener?.cancel()
        listener = nil
        livenessTimer?.cancel()
        livenessTimer = nil
        let droppedPending = pending
        pending.removeAll()
        for (_, client) in droppedPending {
            client.handshakeTimeout?.cancel()
            client.connection.cancel()
        }
        // Awaiting-approval clients get the same best-effort goodbye as
        // promoted ones (the phone is showing "check your Mac" and should
        // learn the close was deliberate) but no disconnect signal — they
        // were never counted.
        let droppedAwaiting = awaiting
        awaiting.removeAll()
        for (_, client) in droppedAwaiting {
            client.handshakeTimeout?.cancel()
            let connection = client.connection
            sendRaw(.goodbye(reason: reason), over: connection) {
                connection.cancel()
            }
            queue.asyncAfter(deadline: .now() + 0.25) { connection.cancel() }
        }
        let dropped = clients
        clients.removeAll()
        for (_, client) in dropped {
            // Cancel from the send's completion, not inline — an immediate
            // cancel aborts the just-enqueued goodbye (observed on loopback).
            let connection = client.connection
            sendRaw(.goodbye(reason: reason), over: connection) {
                connection.cancel()
            }
            // Bounded backstop for a send that never completes. A bare
            // asyncAfter is safe HERE (unlike the old `refused` timer bug):
            // it captures this exact connection object — no key reuse — and
            // a second cancel is a no-op.
            queue.asyncAfter(deadline: .now() + 0.25) { connection.cancel() }
        }
        // A restarted server must not welcome new clients with a snapshot
        // from its previous life; the wiring re-seeds on start.
        latestSnapshot = nil
        if !dropped.isEmpty {
            let ids = Array(dropped.keys)
            let disconnected = onClientDisconnected
            let countChanged = onClientCountChanged
            queue.async {
                for id in ids { disconnected?(id) }
                countChanged?(0)
            }
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
        for client in clients.values {
            if !client.isWelcomed {
                sendWelcome(snapshot, to: client)
            } else if changed {
                send(.state(snapshot: snapshot), to: client)
            }
        }
    }

    /// Send one page of app icons to exactly one promoted client. Icons ride
    /// OUTSIDE the snapshot on purpose: `broadcast(_:)`'s identical-snapshot
    /// suppression must never be defeated by icon churn, and snapshots stay
    /// small. A clientID that is no longer promoted is a silent no-op.
    public func sendAppIcons(_ icons: [AppIconPayload], page: Int, pageCount: Int, to clientID: UUID) {
        queue.async { [weak self] in
            guard let self, let client = self.clients[clientID], client.isWelcomed else { return }
            self.send(.appIcons(page: page, pageCount: pageCount, icons: icons), to: client)
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

    /// MUST only run on ``queue``. New connections enter `pending` only —
    /// they are counted, broadcast to, and command-eligible strictly after
    /// ``promote(_:name:)``.
    private func acceptLocked(_ connection: NWConnection) {
        guard pending.count < (test_pendingCapOverride ?? Self.pendingCap) else {
            // Flood: drop on arrival, no courtesy goodbye — see pendingCap.
            log.notice("companion connection dropped: pending pool full")
            connection.cancel()
            return
        }

        let client = Client(connection: connection)
        pending[client.id] = client
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

        // Pre-hello deadline: a peer that connects and never says hello
        // would otherwise sit in `pending` — and hold its kernel socket —
        // for as long as this server runs. Cancelled on promotion; if it
        // fires, the state handler above cleans up like any other death.
        // A cancellable work item (not a bare closure) so no timer can
        // outlive the connection it guards.
        let timeout = test_handshakeTimeoutOverride ?? Self.preHelloTimeout
        let work = DispatchWorkItem { [weak self] in
            self?.pending[id]?.connection.cancel()
        }
        client.handshakeTimeout = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// THE single promotion decision point (awaiting → counted client),
    /// reached only through the T24 approval gate: a valid, compatible,
    /// within-cap `hello` moved the client into ``awaiting`` (name +
    /// clientID already set), and the app layer's `.approved` verdict landed
    /// in ``resolveApproval(_:_:)``, which calls this. MUST only run on
    /// ``queue``.
    private func promote(_ client: Client) {
        client.handshakeTimeout?.cancel()
        client.handshakeTimeout = nil
        awaiting[client.id] = nil
        clients[client.id] = client
        client.lastActivity = Date()
        ensureLivenessTimer()
        // The name is attacker-controlled: already truncated, and logged at
        // default (.private) privacy, never .public.
        log.info("companion client connected: \(client.clientName ?? "?")")
        let count = clients.count
        let countChanged = onClientCountChanged
        queue.async { countChanged?(count) }
        if let snapshot = latestSnapshot {
            sendWelcome(snapshot, to: client)
        }
        // else: welcome deferred to the first broadcast (see class doc).
    }

    /// The app layer's verdict for one held connection arriving back on
    /// ``queue`` (via the `decide` closure handed to ``onApprovalRequest``).
    /// A verdict for a connection that already died, timed out, or was
    /// settled is a silent no-op. MUST only run on ``queue``.
    private func resolveApproval(_ id: UUID, _ decision: ApprovalDecision) {
        guard let client = awaiting[id] else { return }
        switch decision {
        case .pending:
            // The Mac is prompting its user; tell the phone so it can show
            // "check your Mac" instead of a spinner.
            send(.awaitingApproval, to: client)
        case .approved:
            // Re-check the cap AT promotion: other phones may have filled it
            // while this one waited for its human.
            guard clients.count < (test_maxClientsOverride ?? Self.maxClients) else {
                log.notice("companion client approved but refused: at capacity")
                awaiting[id] = nil
                refuse(client, reason: CompanionGoodbyeReason.serverFull)
                return
            }
            promote(client)
        case .denied:
            log.notice("companion client refused: not approved")
            awaiting[id] = nil
            refuse(client, reason: CompanionGoodbyeReason.notApproved)
        }
    }

    /// Best-effort goodbye, then close — with the same 250 ms backstop
    /// cancel `stopLocked` uses, for a client no pre-hello deadline guards
    /// anymore. MUST only run on ``queue``.
    private func refuse(_ client: Client, reason: String) {
        client.handshakeTimeout?.cancel()
        client.handshakeTimeout = nil
        let connection = client.connection
        sendRaw(.goodbye(reason: reason), over: connection) {
            connection.cancel()
        }
        queue.asyncAfter(deadline: .now() + 0.25) { connection.cancel() }
    }

    /// Revocation (T24): close every live connection — promoted or still
    /// awaiting — whose `hello` carried this phone identity. Promoted ones
    /// disconnect like any other death (state handler → ``removeClient(_:)``
    /// → `onClientDisconnected`), so an orphaned Main Out drag still ends.
    public func dropClient(clientID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.phoneClientID == clientID {
                client.connection.cancel()
            }
            for client in self.awaiting.values where client.phoneClientID == clientID {
                client.connection.cancel()
            }
        }
    }

    /// MUST only run on ``queue``. Cancels unconditionally: Apple requires
    /// cancelling even a FAILED connection to release it, and the
    /// receive-loop and state-handler paths can race such that this is the
    /// only place that still holds the object. Cancelling an
    /// already-cancelled connection is a no-op.
    private func removeClient(_ id: UUID) {
        if let waiting = pending.removeValue(forKey: id) ?? awaiting.removeValue(forKey: id) {
            waiting.handshakeTimeout?.cancel()
            waiting.connection.cancel()
            return // never promoted: no disconnect signal, never counted
        }
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        let count = clients.count
        let disconnected = onClientDisconnected
        let countChanged = onClientCountChanged
        queue.async {
            disconnected?(id)
            countChanged?(count)
        }
    }

    // MARK: - Liveness

    /// Lazily created at the first promotion (the test seam never calls
    /// `start`, so the timer can't live there); torn down in `stopLocked`.
    /// An idle tick over zero clients is harmless.
    private func ensureLivenessTimer() {
        guard livenessTimer == nil else { return }
        let interval = test_pingIntervalOverride ?? Self.pingInterval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in self?.livenessTick() }
        timer.resume()
        livenessTimer = timer
    }

    /// MUST only run on ``queue``. Reap the silent, ping the rest.
    private func livenessTick() {
        let timeout = test_livenessTimeoutOverride ?? Self.livenessTimeout
        let now = Date()
        for client in clients.values {
            if now.timeIntervalSince(client.lastActivity) > timeout {
                log.notice("companion client reaped: no activity for \(Int(now.timeIntervalSince(client.lastActivity))) s")
                client.connection.cancel() // state handler → removeClient
            } else {
                sendPing(to: client)
            }
        }
    }

    /// One WebSocket ping. The pong handler (the canonical Network.framework
    /// pong-observation seam) refreshes `lastActivity`; inbound frames in
    /// `receiveLoop` refresh it too, so a chatty client is never pinged into
    /// suspicion. Non-empty payload on purpose: some receive loops (our own
    /// tests' included) treat an empty delivery as EOF.
    private func sendPing(to client: Client) {
        let id = client.id
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { [weak self] error in
            guard error == nil else { return }
            self?.clients[id]?.lastActivity = Date()
        }
        let context = NWConnection.ContentContext(identifier: "companionPing", metadata: [metadata])
        client.connection.send(content: Data("hb".utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    // MARK: - Receiving

    /// Re-arming per-message receive. Completion runs on ``queue``.
    private func receiveLoop(_ client: Client) {
        let id = client.id
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self,
                  self.pending[id] != nil || self.awaiting[id] != nil || self.clients[id] != nil else { return }
            // Close, error, EOF, and oversize are all just "this client is
            // done": cancel and let the state handler do the one cleanup.
            if error != nil {
                client.connection.cancel()
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .close:
                    client.connection.cancel()
                    return
                case .ping, .pong:
                    // Control frames are liveness, not payload — and may
                    // carry empty data, which must not read as EOF below.
                    client.lastActivity = Date()
                    self.receiveLoop(client)
                    return
                default:
                    break
                }
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
            client.lastActivity = Date()
            self.handle(data, from: client)
            // `handle` may have cancelled the connection (malformed frame /
            // proto mismatch); its removal is async via the state handler,
            // so a re-armed receive on a dying connection can still happen —
            // it just completes with an error and cancels a second time,
            // harmlessly.
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

        // Refuse-forward on EVERY frame's envelope version, symmetric with
        // the iOS client (see `CompanionEnvelope`'s doc): a peer that said
        // hello at a compatible version must not smuggle newer-versioned
        // frames past the handshake check.
        guard !CompanionProto.isIncompatible(peerVersion: envelope.v) else {
            log.notice("companion client refused: frame v\(envelope.v) > \(CompanionProto.version)")
            send(.goodbye(reason: CompanionGoodbyeReason.protoMismatch), to: client) {
                client.connection.cancel()
            }
            return
        }

        switch envelope.message {
        case .hello(let rawClientID, let rawName, let protoVersion):
            guard clients[client.id] == nil else { return } // duplicate hello: ignore
            guard pending[client.id] != nil else { return } // awaiting-duplicate, or lost a race with its own death
            guard !CompanionProto.isIncompatible(peerVersion: protoVersion) else {
                // Refuse-forward: a NEWER peer might mean things we can't
                // interpret; tell it why, then close. The pre-hello deadline
                // stays armed as the close backstop if this send never
                // flushes.
                log.notice("companion client refused: proto \(protoVersion) > \(CompanionProto.version)")
                send(.goodbye(reason: CompanionGoodbyeReason.protoMismatch), to: client) {
                    client.connection.cancel()
                }
                return
            }
            // The phone's persistent identity (T24) — untrusted input. It
            // must parse as a UUID (which also bounds it to the canonical
            // 36-char form); canonicalize so "abc…" and "ABC…" can never
            // alias into two approval records for one phone.
            guard rawClientID.count <= Self.maxClientIDLength,
                  let parsedID = UUID(uuidString: rawClientID) else {
                log.notice("companion client refused: missing or malformed clientID")
                send(.goodbye(reason: CompanionGoodbyeReason.invalidClientID), to: client) {
                    client.connection.cancel()
                }
                return
            }
            guard clients.count < (test_maxClientsOverride ?? Self.maxClients) else {
                // The cap is checked HERE, not at accept, so an un-helloed
                // probe can never occupy a slot a real phone needs. Same
                // deadline-backstop as the proto refusal above. (Re-checked
                // at promotion too — approval can take minutes.)
                log.notice("companion client refused: at capacity")
                send(.goodbye(reason: CompanionGoodbyeReason.serverFull), to: client) {
                    client.connection.cancel()
                }
                return
            }
            guard awaiting.count < (test_awaitingCapOverride ?? Self.awaitingCap) else {
                log.notice("companion client refused: awaiting-approval pool full")
                send(.goodbye(reason: CompanionGoodbyeReason.serverFull), to: client) {
                    client.connection.cancel()
                }
                return
            }

            // Valid hello → hold for the approval gate. Off the pre-hello
            // deadline (that guards un-helloed connections), onto the far
            // more generous approval one.
            client.handshakeTimeout?.cancel()
            pending[client.id] = nil
            awaiting[client.id] = client
            client.phoneClientID = parsedID.uuidString
            client.clientName = String(rawName.prefix(Self.maxClientNameLength))
            client.lastActivity = Date()
            let connectionID = client.id
            let approvalWork = DispatchWorkItem { [weak self] in
                guard let self, let held = self.awaiting.removeValue(forKey: connectionID) else { return }
                self.log.notice("companion client refused: approval prompt unanswered")
                self.refuse(held, reason: CompanionGoodbyeReason.approvalTimedOut)
            }
            client.handshakeTimeout = approvalWork
            queue.asyncAfter(
                deadline: .now() + (test_approvalTimeoutOverride ?? Self.approvalTimeout),
                execute: approvalWork)

            let decide: @Sendable (ApprovalDecision) -> Void = { [weak self] decision in
                guard let self else { return }
                self.queue.async { self.resolveApproval(connectionID, decision) }
            }
            if let onApprovalRequest {
                let phoneClientID = parsedID.uuidString
                let clientName = client.clientName ?? ""
                queue.async { onApprovalRequest(phoneClientID, clientName, decide) }
            }
            // else: nothing to ask — the approval deadline reaps it (closed
            // by default; see onApprovalRequest's doc).

        case .command(let requestID, let command):
            guard clients[client.id] != nil else {
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
                queue.async { onCommand(requestID, command, clientID, reply) }
            } else {
                reply(CommandResult(applied: false, refusalReason: "server not ready"))
            }

        case .welcome, .awaitingApproval, .state, .commandResult, .goodbye, .appIcons, .unknown:
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
        if data.count > Self.iosInboundCapBytes {
            // Sent anyway (a future client may accept it), but this WILL
            // kill the current iOS client's connection — the snapshot
            // builder/dispatcher side must shrink what it broadcasts.
            log.error("companion frame is \(data.count) bytes — over the iOS client's \(Self.iosInboundCapBytes)-byte inbound cap; the phone will drop the connection")
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "companionText", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            whenDone?()
        })
    }

    // MARK: - Test seams

    /// Test-only: the (truncated) names of the currently promoted clients —
    /// truncation is otherwise observable only in logs.
    func test_clientNames() -> [String] {
        queue.sync { clients.values.compactMap(\.clientName) }
    }

    /// Test-only: how many connections are currently held for approval.
    func test_awaitingCount() -> Int {
        queue.sync { awaiting.count }
    }
}
