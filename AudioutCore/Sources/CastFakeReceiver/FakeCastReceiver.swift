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
/// "playback" it performs is reading the stream and running a clock against it.
///
/// **The timing it models, and why sync work can be tested against it.** The
/// receiver keeps reading the stream for as long as the session lasts and
/// starts its play clock once it holds `startupLead` seconds of audio. The
/// sender paces at exactly real time, so buffer level in is buffer level out:
/// the lead the sender measures (`secondsSent − currentTime`) settles at
/// `startupLead` and stays there. A stall freezes the clock while the stream
/// keeps arriving, which is why its cost is permanent — the measured device
/// gets from 4.6 s to its steady 5.5 s by rebuffering once, about 2 s in, and
/// never gives that 0.9 s back (`dev/notes/006-cast-output-scope-2026-08-22.md`).
///
/// **Where it diverges from the measured device:** PLAYING is announced as
/// soon as PLAY lands or `fetchBytes` arrive, which is well before the buffer
/// is full, so the first seconds of a session report a lead that climbs to
/// `startupLead` rather than one that is settled from the first sample. A
/// caller that needs PLAYING to coincide with a settled lead sets `fetchBytes`
/// to `startupLead` seconds' worth (176 400 B/s).
///
/// The listener is loopback-only, which is what keeps macOS's Application
/// Firewall from prompting on a test run (see DACPServerTests).
@available(macOS 15, *)
public final class FakeCastReceiver: @unchecked Sendable {

    /// 44.1 kHz S16LE stereo — the only format `CastLiveAudioServer` serves.
    private static let bytesPerSecond = 176_400.0

    /// How much of the audio stream counts as "enough to start playing".
    private let fetchBytes: Int
    /// What RECEIVER_STATUS advertises as `volume.controlType`. `fixed` is a
    /// real receiver saying "SET_VOLUME does nothing here, the level belongs
    /// to the TV remote" — the sender is expected to attenuate the feed
    /// instead, and this fake exists to let that split be tested.
    private let controlType: String
    /// How long the receiver sits on a LOAD before it issues the GET. Real
    /// receivers have been measured taking 12 s over it; while a delayed fetch
    /// is outstanding this fake answers PLAY still BUFFERING, the way hardware
    /// does. `0` fetches immediately and answers PLAY with PLAYING.
    private let fetchDelay: TimeInterval
    /// Seconds of audio the receiver holds before it starts playing — and so,
    /// by construction, the lead it reports for the rest of the session. Both
    /// surviving live sessions started at ~4.6 s.
    private let startupLead: TimeInterval
    /// Where the lead ends up. The gap between this and `startupLead` is the
    /// cost of one early rebuffer, injected `startupRebufferAfter` into
    /// playback; equal values mean a session that is flat from the start.
    private let steadyLead: TimeInterval
    private let startupRebufferAfter: TimeInterval
    /// The receiver's crystal against the Mac's. Positive runs the play clock
    /// fast, so the lead shrinks — 100 ppm is ~360 ms an hour. Consumer parts
    /// are tens of ppm; nobody has measured the Streamer's, so the default is
    /// a clock that does not drift at all.
    private let clockDriftPPM: Double
    private let queue = DispatchQueue(label: "FakeCastReceiver")

    /// Lock-guarded rather than `queue.sync`-guarded: a test reads this from
    /// inside a sender completion, which may already be running work this
    /// queue is servicing — a sync getter would deadlock there.
    private let stateLock = NSLock()
    private var _pongCount = 0
    private var _setVolumeCount = 0
    private var _events: [String] = []

    /// Everything fetched from the stream (from the first content byte up to
    /// wherever `fetchBytes` was reached, interior chunk framing included), and
    /// the total byte count — the evidence of what the audio server really
    /// served, header and audio alike.
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
    /// Body bytes the current fetch has read, framing and WAV header included.
    /// Only ever compared against a threshold, never differentiated, so the
    /// ~0.2 % that chunk framing adds moves the moment playback starts by a
    /// few milliseconds and biases nothing after that.
    private var receivedBodyBytes = 0
    private var fetchCompleted = false
    private var playbackStarted = false
    /// Media seconds played, banked whenever the clock stops.
    private var playedSeconds: Double = 0
    /// When the clock last started running; `nil` while it is stopped.
    private var playingSince: DispatchTime?
    private var stalled = false
    /// Who to volunteer a MEDIA_STATUS to: the sender that sent the LOAD. A
    /// status the receiver produces on its own — either edge of a stall, or a
    /// fetch that failed — has no request in hand to reply to.
    private var mediaTarget: (message: CastMessage, session: Session)?

    /// One sender connection: its frame reader and the endpoints it has opened
    /// a virtual connection to.
    private final class Session {
        let connection: NWConnection
        var reader = CastFrameReader()
        var connectedDestinations: Set<String> = []
        var pinged = false
        init(connection: NWConnection) { self.connection = connection }
    }

    public init(
        fetchBytes: Int = 65_536,
        controlType: String = "attenuation",
        fetchDelay: TimeInterval = 0,
        startupLead: TimeInterval = 4.6,
        steadyLead: TimeInterval = 5.5,
        startupRebufferAfter: TimeInterval = 2,
        clockDriftPPM: Double = 0
    ) {
        self.fetchBytes = fetchBytes
        self.controlType = controlType
        self.fetchDelay = fetchDelay
        self.startupLead = startupLead
        self.steadyLead = steadyLead
        self.startupRebufferAfter = startupRebufferAfter
        self.clockDriftPPM = clockDriftPPM
    }

    /// Injects a rebuffer: the receiver re-enters BUFFERING for `duration` and
    /// its play clock stands still, so every lead it reports afterwards is
    /// `duration` higher — permanently, because the sender paces at real time
    /// and can never catch back up. This is the event the room-delay policy is
    /// built around.
    ///
    /// `after` runs from the call. A stall that lands before playback has
    /// started simply holds the start off that much longer, which puts the
    /// lead in the same place.
    public func stall(after: TimeInterval, duration: TimeInterval) {
        queue.asyncAfter(deadline: .now() + after) { [weak self] in self?.beginStall(duration) }
    }

    public var pongCount: Int { stateLock.withLock { _pongCount } }

    /// How many `SET_VOLUME` messages arrived. A `fixed` receiver must see
    /// none: the sender attenuates the audio it serves instead.
    public var setVolumeCount: Int { stateLock.withLock { _setVolumeCount } }

    /// Sender-connection and app-lifecycle milestones in arrival order —
    /// `connect`, `close`, `LAUNCH`, `STOP`. What a relaunch-ordering test
    /// reads to prove the second LAUNCH followed the first channel's close.
    public var events: [String] { stateLock.withLock { _events } }

    private func record(_ event: String) { stateLock.withLock { _events.append(event) } }

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
            // The target holds the last sender session, and with it a
            // connection this has just cancelled.
            mediaTarget = nil
            resetPlayback()
        }
    }

    // MARK: - The play clock (queue-confined)

    /// Where the receiver is in the stream. It only moves while playback is
    /// actually running, which is what makes a stall's cost permanent.
    private func currentTime() -> Double {
        guard let since = playingSince else { return playedSeconds }
        return playedSeconds + Self.seconds(since: since) * (1 + clockDriftPPM / 1_000_000)
    }

    private func freezeClock() {
        guard playingSince != nil else { return }
        playedSeconds = currentTime()
        playingSince = nil
    }

    private func resumeClock() {
        guard playbackStarted, !stalled, playerState == "PLAYING", playingSince == nil else { return }
        playingSince = .now()
    }

    /// Starts the clock the moment the buffer holds `startupLead` seconds —
    /// the one decision that fixes the lead for the rest of the session.
    private func startPlaybackIfBuffered() {
        guard !playbackStarted, !stalled, playerState == "PLAYING" else { return }
        guard Double(receivedBodyBytes) / Self.bytesPerSecond >= startupLead else { return }
        playbackStarted = true
        playingSince = .now()
        guard steadyLead > startupLead else { return }
        stall(after: startupRebufferAfter, duration: steadyLead - startupLead)
    }

    private func beginStall(_ duration: TimeInterval) {
        guard currentMediaSessionID != nil, !stalled else { return }
        stalled = true
        freezeClock()
        playerState = "BUFFERING"
        idleReason = nil
        sendUnsolicitedMediaStatus()
        queue.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.stalled, self.currentMediaSessionID != nil else { return }
            self.stalled = false
            // A PAUSE that landed mid-stall outranks the resume.
            if self.playerState == "BUFFERING" { self.playerState = "PLAYING" }
            self.resumeClock()
            self.sendUnsolicitedMediaStatus()
        }
    }

    private func resetPlayback() {
        receivedBodyBytes = 0
        fetchCompleted = false
        playbackStarted = false
        playedSeconds = 0
        playingSince = nil
        stalled = false
    }

    private static func seconds(since: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - One sender connection

    private func accept(_ connection: NWConnection) {
        let session = Session(connection: connection)
        sessions[ObjectIdentifier(connection)] = session
        record("connect")
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                if self.sessions.removeValue(forKey: ObjectIdentifier(connection)) != nil { self.record("close") }
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
            record("LAUNCH")
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
            record("STOP")
            let sessionID = json["sessionId"] as? String
            applications.removeAll { ($0["sessionId"] as? String) == sessionID }
            // A fetch left running would still reach `fetchBytes` and flip the
            // stopped app back to PLAYING, emitting an unsolicited status.
            fetch?.cancel()
            fetch = nil
            playerState = "IDLE"
            idleReason = "CANCELLED"
            currentMediaSessionID = nil
            mediaTarget = nil
            resetPlayback()
        case "SET_VOLUME":
            stateLock.withLock { _setVolumeCount += 1 }
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
        var status: [String: Any] = [
            "volume": ["level": volumeLevel, "muted": muted, "controlType": controlType],
        ]
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
            resetPlayback()
            mediaTarget = (message, session)
            reply(to: message, on: session, payload: mediaStatusPayload(), requestID: requestID)
            let contentID = (json["media"] as? [String: Any])?["contentId"] as? String
            guard fetchDelay > 0 else {
                startFetch(contentID: contentID)
                return
            }
            queue.asyncAfter(deadline: .now() + fetchDelay) { [weak self] in
                self?.startFetch(contentID: contentID)
            }
            return
        case "PAUSE":
            playerState = "PAUSED"
            freezeClock()
        case "PLAY":
            // A receiver whose GET has not landed yet is still BUFFERING when
            // PLAY arrives; it reports PLAYING once the stream reaches it,
            // which the fetch below already does. Once the stream HAS landed,
            // PLAY is also what brings a PAUSED session back — a delayed-fetch
            // receiver that ignored it would stay paused for good.
            if (fetchDelay == 0 || fetchCompleted), !stalled { playerState = "PLAYING" }
            resumeClock()
        case "STOP":
            // Same reason the receiver-namespace STOP cancels: a fetch left
            // running would still reach `fetchBytes` and flip the stopped
            // session back to PLAYING.
            fetch?.cancel()
            fetch = nil
            playerState = "IDLE"
            idleReason = "CANCELLED"
            currentMediaSessionID = nil
            mediaTarget = nil
            resetPlayback()
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
            // Reported to ~10 ms, as the measured device does; a controller
            // that trusted finer resolution would be reading noise.
            "currentTime": (currentTime() * 100).rounded() / 100,
            "playbackRate": 1,
        ]
        if let idleReason { entry["idleReason"] = idleReason }
        return ["type": "MEDIA_STATUS", "status": [entry]]
    }

    // MARK: - "Playback" — read the stream and run a clock against it

    private func startFetch(contentID: String?) {
        // A LOAD over a still-running fetch ends that one for real, rather than
        // just dropping the reference and leaving it pulling the stream. This
        // must run before the URL guard below so a bad-URL LOAD also clears
        // any previous fetch — otherwise `failFetch(nil)`'s identity check
        // would fail and the stale fetch would live on to report a later
        // session as PLAYING.
        fetch?.cancel()
        fetch = nil
        receivedBodyBytes = 0
        fetchCompleted = false
        guard let contentID,
              let url = URL(string: contentID),
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            failFetch(nil)
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
                self.readBody(connection, header: Data(), body: Data())
            case .failed, .cancelled:
                self.failFetch(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Reads the stream for as long as the session lasts — a real receiver
    /// does not stop at the point it has enough to start, and a fetch that
    /// stopped would leave the play clock with nothing to run against. The
    /// first `fetchBytes` are kept as the evidence `onFetchComplete` hands
    /// back; past that only the count matters, so the bytes are dropped.
    /// Chunk-framing bytes are counted along with the audio.
    private func readBody(_ connection: NWConnection, header: Data, body: Data) {
        // 4 KB is ~23 ms of audio, and it is the bound on how far past
        // `startupLead` the buffer can get before the read that crosses it
        // returns — which is the error in the lead for the whole session. A
        // busy machine coalesces reads; it must not cost more than that.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // A receive completion queued before a STOP landed must not
            // resurrect the stopped session: it would flip an app-less
            // receiver to PLAYING, emit an unsolicited empty MEDIA_STATUS,
            // feed a NEWER fetch's byte count, and nil out the fetch a later
            // LOAD had already started. Identity is the whole test — STOP
            // cancels `fetch` and nils it, and a new LOAD cancels and replaces
            // it. `playerState` is NOT tested: the no-autoplay recipe
            // legitimately reaches PLAYING (LOAD → PLAY) while this fetch is
            // still filling.
            guard connection === self.fetch else { return }
            var header = header
            var body = body
            var arrived = Data()
            if let data, !data.isEmpty {
                if header.range(of: Data("\r\n\r\n".utf8)) == nil {
                    header.append(data)
                    if let terminator = header.range(of: Data("\r\n\r\n".utf8)) {
                        arrived = Data(header[terminator.upperBound...])
                    }
                } else {
                    arrived = data
                }
            }
            self.receivedBodyBytes += arrived.count
            if !self.fetchCompleted { body.append(arrived) }
            if error != nil || isComplete {
                self.failFetch(connection)
                return
            }
            if !self.fetchCompleted, self.receivedBodyBytes >= self.fetchBytes {
                self.fetchCompleted = true
                self.onFetchComplete?(Self.payloadBytes(of: body), self.receivedBodyBytes)
                body = Data()
                if !self.stalled, self.playerState == "BUFFERING" {
                    self.playerState = "PLAYING"
                    self.idleReason = nil
                    self.sendUnsolicitedMediaStatus()
                }
            }
            self.startPlaybackIfBuffered()
            self.readBody(connection, header: header, body: body)
        }
    }

    /// Everything fetched, starting at the first content byte — the WAV header
    /// first, if the stream is one. A real receiver dechunks before it decodes;
    /// this does just enough of that to step over the LEADING
    /// `Transfer-Encoding: chunked` size line, so the body starts on audio
    /// rather than framing. Later chunk headers stay in, exactly as counted.
    private static func payloadBytes(of body: Data) -> Data {
        guard let lineEnd = body.range(of: Data("\r\n".utf8)),
              Int(String(decoding: body[body.startIndex..<lineEnd.lowerBound], as: UTF8.self), radix: 16) != nil else {
            return body
        }
        return Data(body[lineEnd.upperBound...])
    }

    /// `connection` is the fetch that failed. A `.cancelled`/`.failed` state or
    /// an errored receive from the connection a newer LOAD already REPLACED
    /// still arrives after the replacement started, and `playerState` is
    /// BUFFERING for that new session — so without the identity check the dead
    /// connection would cancel the live fetch and report the new session as
    /// ERROR. A `nil` connection means the LOAD failed before a fetch existed;
    /// `startFetch` clears any previous fetch first, so the identity check
    /// holds.
    private func failFetch(_ connection: NWConnection?) {
        guard connection === fetch else { return }
        // BUFFERING is also how a stall shows itself, and a stall is a
        // receiver that is fine — only a session that never got enough to
        // play is an error.
        guard playerState == "BUFFERING", !stalled else { return }
        fetch?.cancel()
        fetch = nil
        playerState = "IDLE"
        idleReason = "ERROR"
        sendUnsolicitedMediaStatus()
    }

    /// requestId 0 is the wire's way of saying "nobody asked for this".
    private func sendUnsolicitedMediaStatus() {
        guard let target = mediaTarget else { return }
        reply(to: target.message, on: target.session, payload: mediaStatusPayload(), requestID: nil)
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
