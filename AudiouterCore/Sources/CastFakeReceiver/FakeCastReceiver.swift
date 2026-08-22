// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import CastSender
import Foundation
import Network
import Security

/// A Cast receiver, faked well enough to drive the whole Phase-0 loop offline:
/// CONNECT, heartbeat, LAUNCH, LOAD, fetch the audio stream, play, pause, stop.
///
/// It exists so the sender is exercised end to end before any hardware
/// arrives — the protocol bugs that matter (framing, virtual connections,
/// requestId routing) all show up against this. It is NOT a Cast emulator: no
/// Bonjour advertising, no DeviceAuth, no app registry, no real decoding. The
/// "playback" it performs is fetching the first `fetchBytes` of the stream and
/// then declaring itself PLAYING.
///
/// The listener is loopback-only, which is what keeps macOS's Application
/// Firewall from prompting on a test run (see DACPServerTests).
@available(macOS 15, *)
public final class FakeCastReceiver: @unchecked Sendable {

    /// How much of the audio stream counts as "enough to start playing".
    private let fetchBytes: Int
    private let queue = DispatchQueue(label: "FakeCastReceiver")

    /// Lock-guarded rather than `queue.sync`-guarded: a test reads this from
    /// inside a sender completion, which may already be running work this
    /// queue is servicing — a sync getter would deadlock there.
    private let stateLock = NSLock()
    private var _pongCount = 0

    /// The first 44 bytes fetched from the stream, and the total byte count —
    /// the evidence that the audio server really served WAV.
    public var onFetchComplete: ((Data, Int) -> Void)?

    // Queue-confined below this line.
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var volumeLevel: Double = 1
    private var muted = false
    private var applications: [[String: Any]] = []
    private var transportCounter = 0
    private var mediaSessionCounter = 0
    private var playerState = "IDLE"
    private var idleReason: String?
    private var currentMediaSessionID: Int?
    private var fetch: NWConnection?

    /// One sender connection: its frame reader and the endpoints it has opened
    /// a virtual connection to.
    private final class Session {
        let connection: NWConnection
        var reader = CastFrameReader()
        var connectedDestinations: Set<String> = []
        var pinged = false
        init(connection: NWConnection) { self.connection = connection }
    }

    public init(fetchBytes: Int = 65_536) {
        self.fetchBytes = fetchBytes
    }

    public var pongCount: Int { stateLock.withLock { _pongCount } }

    // MARK: - Lifecycle

    public func start(completion: @escaping (Result<NWEndpoint, Error>) -> Void) {
        queue.async { [self] in
            let listener: NWListener
            do {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try FakeCastIdentity.load())
                let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
                params.includePeerToPeer = false
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                listener = try NWListener(using: params)
            } catch {
                completion(.failure(error))
                return
            }
            var reported = false
            listener.stateUpdateHandler = { state in
                guard !reported else { return }
                switch state {
                case .ready:
                    guard let port = listener.port, port.rawValue != 0 else { return }
                    reported = true
                    completion(.success(NWEndpoint.hostPort(host: "127.0.0.1", port: port)))
                case .failed(let error):
                    reported = true
                    completion(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            fetch?.cancel()
            fetch = nil
            for (_, session) in sessions { session.connection.cancel() }
            sessions.removeAll()
        }
    }

    // MARK: - One sender connection

    private func accept(_ connection: NWConnection) {
        let session = Session(connection: connection)
        sessions[ObjectIdentifier(connection)] = session
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.sessions.removeValue(forKey: ObjectIdentifier(connection))
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: session)
    }

    private func receive(on session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                guard let messages = try? session.reader.append(data) else {
                    session.connection.cancel()
                    return
                }
                for message in messages { self.handle(message, on: session) }
            }
            if error != nil || isComplete {
                session.connection.cancel()
                return
            }
            self.receive(on: session)
        }
    }

    // MARK: - Dispatch

    private func handle(_ message: CastMessage, on session: Session) {
        guard case let .utf8(text) = message.payload,
              let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""
        let requestID = json["requestId"] as? Int

        switch message.namespace {
        case CastNamespace.connection:
            switch type {
            case "CONNECT":
                session.connectedDestinations.insert(message.destinationID)
                pingOnce(session)
            case "CLOSE":
                session.connectedDestinations.remove(message.destinationID)
            default:
                break
            }
        case CastNamespace.heartbeat:
            switch type {
            case "PING":
                reply(to: message, on: session, payload: ["type": "PONG"], requestID: nil)
            case "PONG":
                stateLock.withLock { _pongCount += 1 }
            default:
                break
            }
        case CastNamespace.receiver where message.destinationID == CastIDs.platform:
            handleReceiver(type: type, json: json, requestID: requestID, message: message, session: session)
        case CastNamespace.media:
            // A real receiver drops media addressed to an app the sender never
            // opened a virtual connection to; that trap is exactly what this
            // fake exists to catch, so it is reproduced rather than smoothed.
            guard isRunningApplication(message.destinationID),
                  session.connectedDestinations.contains(message.destinationID) else { return }
            handleMedia(type: type, json: json, requestID: requestID, message: message, session: session)
        default:
            break
        }
    }

    /// Real receivers ping the sender too. Once per connection is enough to
    /// prove the sender answers.
    private func pingOnce(_ session: Session) {
        guard !session.pinged else { return }
        session.pinged = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.sessions[ObjectIdentifier(session.connection)] != nil else { return }
            self.send(
                CastMessage(
                    source: CastIDs.platform,
                    destination: CastIDs.sender,
                    namespace: CastNamespace.heartbeat,
                    json: ["type": "PING"]
                ),
                on: session
            )
        }
    }

    // MARK: - Receiver namespace

    private func handleReceiver(
        type: String,
        json: [String: Any],
        requestID: Int?,
        message: CastMessage,
        session: Session
    ) {
        switch type {
        case "GET_STATUS":
            break
        case "LAUNCH":
            transportCounter += 1
            applications.append([
                "appId": json["appId"] as? String ?? "",
                "displayName": "Default Media Receiver",
                "sessionId": UUID().uuidString,
                "transportId": "web-\(transportCounter)",
                "statusText": "Ready To Cast",
                "isIdleScreen": false,
                "namespaces": [["name": CastNamespace.media]],
            ])
        case "STOP":
            let sessionID = json["sessionId"] as? String
            applications.removeAll { ($0["sessionId"] as? String) == sessionID }
            // A fetch left running would still reach `fetchBytes` and flip the
            // stopped app back to PLAYING, emitting an unsolicited status.
            fetch?.cancel()
            fetch = nil
            playerState = "IDLE"
            idleReason = "CANCELLED"
            currentMediaSessionID = nil
        case "SET_VOLUME":
            let volume = json["volume"] as? [String: Any] ?? [:]
            if let level = volume["level"] as? Double { volumeLevel = level }
            if let flag = volume["muted"] as? Bool { muted = flag }
        default:
            reply(to: message, on: session, payload: ["type": "INVALID_REQUEST", "reason": "INVALID_COMMAND"], requestID: requestID)
            return
        }
        reply(to: message, on: session, payload: receiverStatusPayload(), requestID: requestID)
    }

    /// Real receivers omit `applications` entirely when nothing is running,
    /// rather than sending an empty array.
    private func receiverStatusPayload() -> [String: Any] {
        var status: [String: Any] = ["volume": ["level": volumeLevel, "muted": muted]]
        if !applications.isEmpty { status["applications"] = applications }
        return ["type": "RECEIVER_STATUS", "status": status]
    }

    private func isRunningApplication(_ transportID: String) -> Bool {
        applications.contains { ($0["transportId"] as? String) == transportID }
    }

    // MARK: - Media namespace

    private func handleMedia(
        type: String,
        json: [String: Any],
        requestID: Int?,
        message: CastMessage,
        session: Session
    ) {
        switch type {
        case "LOAD":
            mediaSessionCounter += 1
            currentMediaSessionID = mediaSessionCounter
            playerState = "BUFFERING"
            idleReason = nil
            reply(to: message, on: session, payload: mediaStatusPayload(), requestID: requestID)
            let contentID = (json["media"] as? [String: Any])?["contentId"] as? String
            startFetch(contentID: contentID, message: message, session: session)
            return
        case "PAUSE":
            playerState = "PAUSED"
        case "PLAY":
            playerState = "PLAYING"
        case "STOP":
            playerState = "IDLE"
            idleReason = "CANCELLED"
            currentMediaSessionID = nil
        case "GET_STATUS":
            break
        default:
            return
        }
        reply(to: message, on: session, payload: mediaStatusPayload(), requestID: requestID)
    }

    private func mediaStatusPayload() -> [String: Any] {
        guard let session = currentMediaSessionID else {
            return ["type": "MEDIA_STATUS", "status": []]
        }
        var entry: [String: Any] = [
            "mediaSessionId": session,
            "playerState": playerState,
            "currentTime": 0,
            "playbackRate": 1,
        ]
        if let idleReason { entry["idleReason"] = idleReason }
        return ["type": "MEDIA_STATUS", "status": [entry]]
    }

    // MARK: - "Playback" — fetch the stream, then call it PLAYING

    private func startFetch(contentID: String?, message: CastMessage, session: Session) {
        guard let contentID,
              let url = URL(string: contentID),
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            failFetch(message: message, session: session)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        fetch = connection
        let path = url.path.isEmpty ? "/" : url.path
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.send(
                    content: Data("GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8),
                    completion: .idempotent
                )
                self.readBody(connection, header: Data(), body: Data(), message: message, session: session)
            case .failed, .cancelled:
                self.failFetch(message: message, session: session)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Counts everything after the response head. Chunk-framing bytes are
    /// counted along with the audio — "at least `fetchBytes` arrived" is all
    /// this needs to decide the stream is real.
    private func readBody(
        _ connection: NWConnection,
        header: Data,
        body: Data,
        message: CastMessage,
        session: Session
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var header = header
            var body = body
            if let data, !data.isEmpty {
                if header.range(of: Data("\r\n\r\n".utf8)) == nil {
                    header.append(data)
                    if let terminator = header.range(of: Data("\r\n\r\n".utf8)) {
                        body.append(Data(header[terminator.upperBound...]))
                    }
                } else {
                    body.append(data)
                }
            }
            if error != nil || (isComplete && body.count < self.fetchBytes) {
                self.failFetch(message: message, session: session)
                return
            }
            guard body.count < self.fetchBytes else {
                connection.cancel()
                self.fetch = nil
                self.onFetchComplete?(Self.firstPayloadBytes(of: body), body.count)
                self.playerState = "PLAYING"
                self.idleReason = nil
                self.sendUnsolicitedMediaStatus(message: message, session: session)
                return
            }
            self.readBody(connection, header: header, body: body, message: message, session: session)
        }
    }

    /// The first 44 bytes of actual content — the WAV header, if the stream is
    /// one. A real receiver dechunks before it decodes; this does just enough
    /// of that to step over the leading `Transfer-Encoding: chunked` size line,
    /// so the sample is audio bytes rather than framing.
    private static func firstPayloadBytes(of body: Data) -> Data {
        guard let lineEnd = body.range(of: Data("\r\n".utf8)),
              Int(String(decoding: body[body.startIndex..<lineEnd.lowerBound], as: UTF8.self), radix: 16) != nil else {
            return Data(body.prefix(44))
        }
        return Data(body[lineEnd.upperBound...].prefix(44))
    }

    private func failFetch(message: CastMessage, session: Session) {
        guard playerState == "BUFFERING" else { return }
        fetch?.cancel()
        fetch = nil
        playerState = "IDLE"
        idleReason = "ERROR"
        sendUnsolicitedMediaStatus(message: message, session: session)
    }

    /// requestId 0 is the wire's way of saying "nobody asked for this".
    private func sendUnsolicitedMediaStatus(message: CastMessage, session: Session) {
        reply(to: message, on: session, payload: mediaStatusPayload(), requestID: nil)
    }

    // MARK: - Sending

    private func reply(to message: CastMessage, on session: Session, payload: [String: Any], requestID: Int?) {
        var body = payload
        body["requestId"] = requestID ?? 0
        send(
            CastMessage(
                source: message.destinationID,
                destination: message.sourceID,
                namespace: message.namespace,
                json: body
            ),
            on: session
        )
    }

    private func send(_ message: CastMessage, on session: Session) {
        session.connection.send(content: CastMessage.frame(message), completion: .idempotent)
    }
}
