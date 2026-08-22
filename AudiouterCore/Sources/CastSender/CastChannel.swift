// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network
import Security

/// The single TLS connection to a Cast receiver's control port (8009), and the
/// request/reply bookkeeping on top of it.
///
/// A receiver presents a self-signed certificate, so the verify block accepts
/// unconditionally. Real senders then run a DeviceAuth challenge over that
/// connection to prove the receiver is genuine Google hardware; this sender
/// skips it (roadmap 006 brief, decision 5) — it is an anti-counterfeit check,
/// not a transport requirement, and playback works without it.
///
/// Everything mutable is confined to ``queue``; every completion this class
/// hands out therefore runs on ``queue`` too.
public final class CastChannel: @unchecked Sendable {

    /// Any message that is neither a heartbeat nor a reply to a pending
    /// request — receiver- and media-status broadcasts, mostly.
    public var onUnsolicited: ((CastMessage, [String: Any]) -> Void)?
    public var onPong: (() -> Void)?
    /// The connection ended: peer error, receiver-sent CLOSE, or EOF.
    public var onClose: ((Error?) -> Void)?

    private let endpoint: NWEndpoint
    private let heartbeatInterval: TimeInterval
    private let requestTimeout: TimeInterval
    private let queue = DispatchQueue(label: "CastChannel")

    /// Lock-guarded, not `queue.sync`-guarded: callers read these from inside
    /// the completions this class hands out, which already run on ``queue`` —
    /// a sync getter would deadlock the first time a request completion asked
    /// for the local address.
    private let stateLock = NSLock()
    private var _localIPv4Address: String?
    private var _pongCount = 0

    // Queue-confined below this line.
    private var connection: NWConnection?
    private var reader = CastFrameReader()
    private var heartbeat: DispatchSourceTimer?
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var timeouts: [Int: DispatchWorkItem] = [:]
    private var nextRequestID = 1
    private var virtualDestinations: Set<String> = []
    private var connectCompletion: ((Result<Void, Error>) -> Void)?
    private var isReady = false
    private var isClosed = false

    public init(endpoint: NWEndpoint, heartbeatInterval: TimeInterval = 5, requestTimeout: TimeInterval = 10) {
        self.endpoint = endpoint
        self.heartbeatInterval = heartbeatInterval
        self.requestTimeout = requestTimeout
    }

    /// The sender's own address on the interface that reached the receiver —
    /// the host a receiver has to fetch the audio stream back from. Nil until
    /// the connection is ready (or if the path has no IPv4 local endpoint).
    public var localIPv4Address: String? { stateLock.withLock { _localIPv4Address } }

    /// How many PONGs the receiver has answered — the liveness signal the
    /// Phase-0 spike reports on.
    public var pongCount: Int { stateLock.withLock { _pongCount } }

    // MARK: - Lifecycle

    public func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            guard !isClosed else { completion(.failure(CastError.closed)); return }
            connectCompletion = completion

            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, complete in complete(true) },
                queue
            )
            let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            params.includePeerToPeer = false

            let connection = NWConnection(to: endpoint, using: params)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state)
            }
            connection.start(queue: queue)
            // A host that is advertised but unreachable (e.g. another subnet)
            // leaves the connection in .preparing forever; nothing else fails it.
            queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
                guard let self, !self.isReady, !self.isClosed else { return }
                self.finishConnect(.failure(CastError.connectionFailed("connect timed out after \(Int(self.requestTimeout))s")))
                self.closeLocked(notifying: nil)
            }
        }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isReady, !isClosed else { return }
            isReady = true
            recordLocalAddress()
            sendLocked(namespace: CastNamespace.connection, destination: CastIDs.platform, payload: ["type": "CONNECT"])
            armHeartbeat()
            receiveLoop()
            finishConnect(.success(()))
        case .failed(let error):
            handleDisconnect(error)
        case .waiting(let error):
            handleDisconnect(error)
        case .cancelled:
            handleDisconnect(nil)
        default:
            break
        }
    }

    private func handleDisconnect(_ error: NWError?) {
        if !isReady {
            finishConnect(.failure(CastError.connectionFailed(error.map { "\($0)" } ?? "cancelled before ready")))
            closeLocked(notifying: nil)
        } else {
            closeLocked(notifying: error)
        }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        guard let completion = connectCompletion else { return }
        connectCompletion = nil
        completion(result)
    }

    private func recordLocalAddress() {
        guard case let .hostPort(host, _)? = connection?.currentPath?.localEndpoint,
              case let .ipv4(address) = host else { return }
        stateLock.withLock { _localIPv4Address = "\(address)" }
    }

    private func armHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendLocked(namespace: CastNamespace.heartbeat, destination: CastIDs.platform, payload: ["type": "PING"])
        }
        timer.resume()
        heartbeat = timer
    }

    /// Sends CLOSE to every endpoint we opened, then tears the connection
    /// down. Pending requests fail with ``CastError/closed``.
    public func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            for destination in virtualDestinations {
                sendLocked(namespace: CastNamespace.connection, destination: destination, payload: ["type": "CLOSE"])
            }
            sendLocked(namespace: CastNamespace.connection, destination: CastIDs.platform, payload: ["type": "CLOSE"])
            closeLocked(notifying: nil, callOnClose: false)
        }
    }

    private func closeLocked(notifying error: Error?, callOnClose: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        heartbeat?.cancel()
        heartbeat = nil
        connection?.cancel()
        let waiting = pending
        pending.removeAll()
        for (_, work) in timeouts { work.cancel() }
        timeouts.removeAll()
        for (_, completion) in waiting { completion(.failure(CastError.closed)) }
        if callOnClose { onClose?(error) }
    }

    // MARK: - Sending

    /// Opens a "virtual connection" to an application endpoint. The receiver
    /// drops media messages addressed to a transport id the sender never
    /// CONNECTed to, so this must precede any LOAD.
    public func connectVirtual(to destinationID: String) {
        queue.async { [self] in
            guard !virtualDestinations.contains(destinationID) else { return }
            virtualDestinations.insert(destinationID)
            sendLocked(namespace: CastNamespace.connection, destination: destinationID, payload: ["type": "CONNECT"])
        }
    }

    /// Fire-and-forget: no `requestId`, no reply expected.
    public func send(namespace: String, destination: String, payload: [String: Any]) {
        queue.async { [self] in
            sendLocked(namespace: namespace, destination: destination, payload: payload)
        }
    }

    /// Sends `payload` with a fresh `requestId` and completes when the reply
    /// carrying that id arrives, or with ``CastError/timeout``.
    public func request(
        namespace: String,
        destination: String,
        payload: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        queue.async { [self] in
            guard !isClosed else { completion(.failure(CastError.closed)); return }
            let id = nextRequestID
            nextRequestID += 1
            var body = payload
            body["requestId"] = id
            pending[id] = completion

            let expiry = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.timeouts[id] = nil
                guard let waiting = self.pending.removeValue(forKey: id) else { return }
                waiting(.failure(CastError.timeout))
            }
            timeouts[id] = expiry
            queue.asyncAfter(deadline: .now() + requestTimeout, execute: expiry)

            sendLocked(namespace: namespace, destination: destination, payload: body)
        }
    }

    private func sendLocked(namespace: String, destination: String, payload: [String: Any]) {
        guard let connection else { return }
        let message = CastMessage(source: CastIDs.sender, destination: destination, namespace: namespace, json: payload)
        connection.send(content: CastMessage.frame(message), completion: .idempotent)
    }

    // MARK: - Receiving

    private func receiveLoop() {
        guard let connection, !isClosed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // A receive already in flight when `close()` ran still completes
            // here; without this, a late frame would be handled and could send
            // a PONG down a connection we have already torn down.
            guard !self.isClosed else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.reader.append(data) { self.handle(message) }
                } catch {
                    self.closeLocked(notifying: error)
                    return
                }
            }
            if let error { self.closeLocked(notifying: error); return }
            if isComplete { self.closeLocked(notifying: nil); return }
            self.receiveLoop()
        }
    }

    private func handle(_ message: CastMessage) {
        guard case let .utf8(text) = message.payload else {
            onUnsolicited?(message, [:])
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        let type = json["type"] as? String

        if message.namespace == CastNamespace.heartbeat {
            switch type {
            case "PING":
                // Answered to whoever asked: the platform pings on its own
                // channel, a launched application on its transport id.
                sendLocked(namespace: CastNamespace.heartbeat, destination: message.sourceID, payload: ["type": "PONG"])
                return
            case "PONG":
                stateLock.withLock { _pongCount += 1 }
                onPong?()
                return
            default:
                break
            }
        }

        if message.namespace == CastNamespace.connection, type == "CLOSE" {
            closeLocked(notifying: nil)
            return
        }

        if let requestID = json["requestId"] as? Int, requestID != 0, let completion = pending.removeValue(forKey: requestID) {
            timeouts.removeValue(forKey: requestID)?.cancel()
            completion(.success(json))
            return
        }

        onUnsolicited?(message, json)
    }
}
