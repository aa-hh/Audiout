// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network
import os

/// The sender-side **DACP** endpoint — the missing half of speaker-initiated
/// volume (speaker-input task, phase 2).
///
/// ## Why this exists
/// When a user changes the volume ON THE SPEAKER (its buttons, or its companion
/// app), an AirPlay receiver does NOT report it over the RTSP/event channel —
/// it calls the *sender* back over DACP. The engine already advertises that it
/// accepts these calls: every RTSP request carries `DACP-ID: <libhash>` and
/// `Active-Remote: <low-32-bits-of-device-id>` (`airplay.c`). The receiver then
/// browses mDNS for `iTunes_Ctrl_<DACP-ID>`, resolves it, and sends e.g.
/// `GET /ctrl-int/1/setproperty?dmcp.device-volume=-16.5` with its `Active-Remote`
/// header. Nothing was ever listening — so the call hit a closed door and the
/// slider never moved. This is that door.
///
/// See the AirPlay spec (openairplay `remote_control` / `volume_control`) and
/// OwnTone's `httpd_dacp.c`, which this mirrors in miniature: we only need the
/// volume verbs, not the full DAAP/now-playing surface.
///
/// ## Scope
/// - Advertises one `_dacp._tcp` service named `iTunes_Ctrl_<DACP-ID hex>`.
/// - Accepts the receiver's HTTP GETs, parses the command + `Active-Remote`.
/// - Reports absolute volume (`setproperty?dmcp.device-volume=<dB>`) via
///   ``onVolume``; the backend maps the token to a device and moves its slider.
/// - Answers `204 No Content` (what a real DACP server returns).
/// - Deliberately does NOT act on transport verbs (`pause`/`playpause`/`nextitem`/
///   `previtem`): the RTSP event channel already delivers those, and acting here
///   too would double-fire. We still 204 them so the receiver is satisfied.
///
/// Request PARSING is a pure static function (``parse(_:)``) so it's unit-tested
/// with no sockets; the `Network` plumbing around it is thin.
public final class DACPServer: @unchecked Sendable {

    /// Called for an absolute device-volume report: the receiver's `Active-Remote`
    /// token and the new level (0…1). The backend routes the token to a device.
    /// Invoked on ``queue``.
    public var onVolume: (@Sendable (_ activeRemote: UInt32, _ level: Double) -> Void)?

    /// Called for a relative `volumeup`/`volumedown` verb: the receiver's
    /// `Active-Remote` token and the direction (+1 / −1). The backend steps that
    /// device's CURRENT level, so consecutive presses accumulate. Invoked on
    /// ``queue``.
    public var onVolumeStep: (@Sendable (_ activeRemote: UInt32, _ direction: Int) -> Void)?

    private let log = Logger(subsystem: "com.audiouter.Audiouter", category: "dacp")
    private let queue = DispatchQueue(label: "DACPServer")

    /// Diagnostic sink: when `AIRPLAYENGINE_LOG_FILE` is set (the gated live-test
    /// env), mirror key DACP events into that same file so a real `open`-launched
    /// session — where stderr/os_log are swallowed — is still observable. No-op
    /// otherwise.
    private static let debugPath = ProcessInfo.processInfo.environment["AIRPLAYENGINE_LOG_FILE"]
    private func debugLog(_ message: String) {
        guard let path = Self.debugPath, let data = ("[dacp] " + message + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
    private var listener: NWListener?
    /// Held so a connection isn't deallocated mid-exchange.
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init() {}

    // MARK: - Lifecycle

    /// Advertise `iTunes_Ctrl_<dacpID>` and start listening. `dacpID` MUST equal
    /// the value the engine sends in its `DACP-ID` header (``AirPlayEngine/dacpID``)
    /// or the receiver won't find us. Idempotent-ish: a second call restarts.
    public func start(dacpID: UInt64) {
        stop()
        // `%08llX`-style upper-hex, matching airplay.c's `%" PRIX64 "` DACP-ID.
        let serviceName = "iTunes_Ctrl_" + String(format: "%016llX", dacpID)

        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let listener: NWListener
        do {
            listener = try NWListener(using: params) // ephemeral port
        } catch {
            log.error("DACP listener could not start: \(String(describing: error), privacy: .public)")
            return
        }

        // TXT mirrors what a DAAP/DACP control server advertises. The receiver
        // matches on the service NAME (the DACP-ID); these are best-effort metadata.
        var txt = NWTXTRecord()
        txt["txtvers"] = "1"
        txt["Ver"] = "131075"
        txt["DbId"] = String(format: "%016llX", dacpID)
        txt["OSsi"] = "0x1F5"
        listener.service = NWListener.Service(name: serviceName, type: "_dacp._tcp", txtRecord: txt)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.log.error("DACP listener failed: \(String(describing: error), privacy: .public)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        log.notice("DACP server advertising \(serviceName, privacy: .public)")
        debugLog("advertising \(serviceName)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.queue.async { self?.connections[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        // DACP requests are single small header-only GETs; one receive is enough.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, let request = DACPServer.parse(data) {
                self.dispatch(request)
            }
            if error != nil {
                connection.cancel()
                return
            }
            // Always answer so the receiver's request completes, then close.
            connection.send(content: DACPServer.response204, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func dispatch(_ request: DACPRequest) {
        debugLog("request cmd=\(request.command) token=\(request.activeRemote.map(String.init) ?? "nil") query=\(request.query)")
        guard let token = request.activeRemote else { return }
        if let db = request.deviceVolumeDb {
            let level = DACPServer.level(fromDb: db)
            log.info("DACP volume: token \(token) -> \(level, format: .fixed(precision: 3)) (\(db, format: .fixed(precision: 1)) dB)")
            debugLog("VOLUME token=\(token) -> \(level) (\(db) dB)")
            onVolume?(token, level)
        }
        // volumeup/volumedown are RELATIVE; the backend applies them against the
        // level it currently holds for the device. Transport verbs are
        // intentionally ignored (the event channel owns them).
        if request.command == "volumeup" || request.command == "volumedown" {
            let direction = request.command == "volumeup" ? 1 : -1
            log.info("DACP volume step: token \(token) direction \(direction)")
            debugLog("VOLUME-STEP token=\(token) direction=\(direction)")
            onVolumeStep?(token, direction)
        }
    }

    // MARK: - Pure parsing (unit-tested; no sockets)

    /// The subset of a DACP request we care about.
    public struct DACPRequest: Equatable {
        /// The verb after `/ctrl-int/1/` — e.g. `setproperty`, `volumeup`, `pause`.
        public let command: String
        /// The query string parsed to key/value, e.g. `["dmcp.device-volume": "-16.5"]`.
        public let query: [String: String]
        /// The `Active-Remote` token (identifies which device sent it), if present.
        public let activeRemote: UInt32?

        public init(command: String, query: [String: String], activeRemote: UInt32?) {
            self.command = command
            self.query = query
            self.activeRemote = activeRemote
        }

        /// The absolute device volume in dB carried by a `setproperty` request.
        public var deviceVolumeDb: Double? {
            guard command == "setproperty", let raw = query["dmcp.device-volume"] else { return nil }
            return Double(raw)
        }
    }

    /// Parse a raw HTTP request into a ``DACPRequest``. Reads only the request
    /// line (`GET /ctrl-int/1/<cmd>[?query] HTTP/1.1`) and the `Active-Remote`
    /// header — everything a DACP control call carries. Returns nil if it isn't a
    /// recognizable `/ctrl-int/` request.
    public static func parse(_ data: Data) -> DACPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        // "GET /ctrl-int/1/setproperty?dmcp.device-volume=-16.5 HTTP/1.1"
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        let target = String(fields[1])

        guard let range = target.range(of: "/ctrl-int/1/") else { return nil }
        let tail = String(target[range.upperBound...]) // "setproperty?dmcp.device-volume=-16.5"

        let command: String
        var query: [String: String] = [:]
        if let q = tail.firstIndex(of: "?") {
            command = String(tail[..<q])
            let queryString = String(tail[tail.index(after: q)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        } else {
            command = tail
        }

        var activeRemote: UInt32?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("active-remote:") {
                let value = line.dropFirst("active-remote:".count).trimmingCharacters(in: .whitespaces)
                activeRemote = UInt32(value)
                break
            }
        }

        return DACPRequest(command: command, query: query, activeRemote: activeRemote)
    }

    /// Map an AirPlay volume in dB to a 0…1 level, mirroring the outbound map for
    /// the default `max_volume` (`airplay_volume_from_pct`): −30…0 dB ↔ 0…1, and
    /// ≤ −30 dB (including the −144 mute sentinel) clamps to 0.
    public static func level(fromDb db: Double) -> Double {
        if db <= -30 { return 0 }
        if db >= 0 { return 1 }
        return (db + 30) / 30
    }

    /// The response a DACP server returns to a control command (per the spec).
    private static let response204 = Data(
        "HTTP/1.1 204 No Content\r\nDAAP-Server: Audiouter/1.0\r\nContent-Length: 0\r\n\r\n".utf8
    )
}
