// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One message on the WebSocket connection between the Mac (`CompanionServer`)
/// and the phone. Client→server: `hello`, `command`. Server→client: `welcome`,
/// `awaitingApproval`, `state`, `commandResult`, `goodbye`, `appIcons`. `.unknown` is a
/// decode-only case: a message type neither side recognizes yet (e.g. a newer
/// peer's message type) decodes into it rather than throwing, so a version
/// skew never crashes the connection — the client ignores it, the server
/// answers a `command`-shaped unknown with a failed `commandResult`.
public enum CompanionMessage: Equatable, Sendable {
    // client -> server

    /// `clientID` is a stable opaque identity the PHONE generates once
    /// (a UUID string) and persists forever — it is what the Mac's per-phone
    /// approval is keyed on, so it must survive reinstalls of nothing less
    /// than the phone's own app data. It is attacker-controlled input: the
    /// Mac validates it parses as a UUID and refuses the hello otherwise
    /// (`CompanionGoodbyeReason.invalidClientID`); it is never shown to the
    /// user — `clientName` is the only human-facing string. A missing
    /// `clientID` key decodes as `""` (see `CompanionEnvelope`'s decoder)
    /// so the server can refuse it with a reason instead of dropping the
    /// frame as malformed.
    case hello(clientID: String, clientName: String, protoVersion: Int)
    case command(requestID: String, command: CompanionCommand)

    // server -> client
    case welcome(serverName: String, protoVersion: Int, snapshot: Snapshot)
    /// The hello was valid but this phone isn't approved yet: the Mac is
    /// showing its user an allow/deny prompt, and holds the connection open
    /// (generously — minutes, not the handshake deadline) until they answer.
    /// The phone should show "check your Mac", not an error. Resolves as a
    /// `welcome` (allowed) or a `goodbye` (`notApproved` / `approvalTimedOut`).
    case awaitingApproval
    case state(snapshot: Snapshot)
    case commandResult(requestID: String, applied: Bool, refusalReason: String?, autoSwappedCurrentDevice: Bool)
    /// `reason` is one of `CompanionGoodbyeReason`'s constants.
    case goodbye(reason: String)
    /// One page of the icons the phone requested via
    /// `CompanionCommand.requestAppIcons`, at most
    /// `CompanionAppIcons.pageSize` icons per page.
    case appIcons(page: Int, pageCount: Int, icons: [AppIconPayload])

    case unknown(type: String)
}

/// Every `goodbye` reason the Mac server actually sends, so the phone can
/// switch on them without string drift. A reason the client doesn't
/// recognize (a newer server's) should be treated like `shutdown`: the
/// server closed deliberately.
public enum CompanionGoodbyeReason {
    /// The user unticked "Allow remote control" — don't redial until the
    /// service reappears in Bonjour.
    public static let disabled = "disabled"
    /// The Mac app is quitting (or the server restarted).
    public static let shutdown = "shutdown"
    /// The client's protocol version is newer than the server's.
    public static let protoMismatch = "protoMismatch"
    /// The server is at its client cap.
    public static let serverFull = "serverFull"
    /// The hello carried no `clientID`, or one that doesn't parse as a UUID.
    /// The phone should regenerate/repair its stored identity before retrying.
    public static let invalidClientID = "invalidClientID"
    /// The Mac's user answered "Don't Allow" for this phone (now or on an
    /// earlier connect — denials are remembered). Don't redial: the user must
    /// revoke the denial on the Mac (Settings › General) first.
    public static let notApproved = "notApproved"
    /// The approval prompt sat unanswered past the Mac's deadline. Retryable:
    /// reconnecting asks again.
    public static let approvalTimedOut = "approvalTimedOut"
}

/// The wire envelope every WebSocket text frame carries:
/// `{"v": Int, "type": String, "payload": {...}}`. `v` is the SENDER's
/// `CompanionProto.version` — check it (or `hello`/`welcome`'s own
/// `protoVersion` payload field, which duplicates it) with
/// `CompanionProto.isIncompatible(peerVersion:)` before trusting a peer's
/// snapshot/commands; a peer whose version is greater than ours is refused
/// (refuse-forward, mirroring `AppRouteStore.swift`'s
/// `envelope.schemaVersion <= currentSchemaVersion` guard and the Bonjour TXT
/// `proto` check `CompanionProto` itself performs before a connection even
/// opens).
///
/// Unknown top-level JSON keys inside `payload` are ignored (default
/// `Codable` behavior — we only ever read the keys a given `type` defines).
/// An unrecognized `type` decodes to `CompanionMessage.unknown(type:)`
/// without touching `payload` at all, rather than throwing.
public struct CompanionEnvelope: Equatable, Sendable {
    public var v: Int
    public var message: CompanionMessage

    public init(message: CompanionMessage, v: Int = CompanionProto.version) {
        self.v = v
        self.message = message
    }
}

extension CompanionEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case v, type, payload
    }

    private enum PayloadKeys: String, CodingKey {
        case clientID, clientName, protoVersion
        case requestID, command
        case serverName, snapshot
        case applied, refusalReason, autoSwappedCurrentDevice
        case reason
        case page, pageCount, icons
    }

    private enum TypeName: String {
        case hello, command, welcome, awaitingApproval, state, commandResult, goodbye, appIcons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        let rawType = try c.decode(String.self, forKey: .type)
        guard let type = TypeName(rawValue: rawType) else {
            message = .unknown(type: rawType)
            return
        }
        let payload = try c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        switch type {
        case .hello:
            message = .hello(
                // `""`, not a throw, for an absent clientID: the server must
                // refuse it with a REASON (`invalidClientID`), which it can
                // only do if the frame still decodes.
                clientID: try payload.decodeIfPresent(String.self, forKey: .clientID) ?? "",
                clientName: try payload.decode(String.self, forKey: .clientName),
                protoVersion: try payload.decode(Int.self, forKey: .protoVersion)
            )
        case .command:
            message = .command(
                requestID: try payload.decode(String.self, forKey: .requestID),
                command: try payload.decode(CompanionCommand.self, forKey: .command)
            )
        case .welcome:
            message = .welcome(
                serverName: try payload.decode(String.self, forKey: .serverName),
                protoVersion: try payload.decode(Int.self, forKey: .protoVersion),
                snapshot: try payload.decode(Snapshot.self, forKey: .snapshot)
            )
        case .awaitingApproval:
            message = .awaitingApproval
        case .state:
            message = .state(snapshot: try payload.decode(Snapshot.self, forKey: .snapshot))
        case .commandResult:
            message = .commandResult(
                requestID: try payload.decode(String.self, forKey: .requestID),
                applied: try payload.decode(Bool.self, forKey: .applied),
                refusalReason: try payload.decodeIfPresent(String.self, forKey: .refusalReason),
                autoSwappedCurrentDevice: try payload.decode(Bool.self, forKey: .autoSwappedCurrentDevice)
            )
        case .goodbye:
            message = .goodbye(reason: try payload.decode(String.self, forKey: .reason))
        case .appIcons:
            message = .appIcons(
                page: try payload.decode(Int.self, forKey: .page),
                pageCount: try payload.decode(Int.self, forKey: .pageCount),
                icons: try payload.decode([AppIconPayload].self, forKey: .icons)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        switch message {
        case .hello(let clientID, let clientName, let protoVersion):
            try c.encode(TypeName.hello.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(clientID, forKey: .clientID)
            try payload.encode(clientName, forKey: .clientName)
            try payload.encode(protoVersion, forKey: .protoVersion)
        case .command(let requestID, let command):
            try c.encode(TypeName.command.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(requestID, forKey: .requestID)
            try payload.encode(command, forKey: .command)
        case .welcome(let serverName, let protoVersion, let snapshot):
            try c.encode(TypeName.welcome.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(serverName, forKey: .serverName)
            try payload.encode(protoVersion, forKey: .protoVersion)
            try payload.encode(snapshot, forKey: .snapshot)
        case .awaitingApproval:
            try c.encode(TypeName.awaitingApproval.rawValue, forKey: .type)
            // Empty payload object — every type carries one (decode reads the
            // container before switching on the type).
            _ = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        case .state(let snapshot):
            try c.encode(TypeName.state.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(snapshot, forKey: .snapshot)
        case .commandResult(let requestID, let applied, let refusalReason, let autoSwappedCurrentDevice):
            try c.encode(TypeName.commandResult.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(requestID, forKey: .requestID)
            try payload.encode(applied, forKey: .applied)
            try payload.encodeIfPresent(refusalReason, forKey: .refusalReason)
            try payload.encode(autoSwappedCurrentDevice, forKey: .autoSwappedCurrentDevice)
        case .goodbye(let reason):
            try c.encode(TypeName.goodbye.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(reason, forKey: .reason)
        case .appIcons(let page, let pageCount, let icons):
            try c.encode(TypeName.appIcons.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(page, forKey: .page)
            try payload.encode(pageCount, forKey: .pageCount)
            try payload.encode(icons, forKey: .icons)
        case .unknown(let type):
            // Round-trips as whatever it decoded from; there is no payload
            // to re-emit since we never understood its shape.
            try c.encode(type, forKey: .type)
            _ = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        }
    }
}

extension CompanionEnvelope {
    /// Top-level encode helper — the only place a `CompanionMessage` gets
    /// turned into wire bytes.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Top-level decode helper — the only place wire bytes get turned into a
    /// `CompanionEnvelope`. Never throws on an unrecognized `type` (see
    /// `CompanionMessage.unknown`); only throws on genuinely malformed JSON
    /// (missing `v`/`type`, wrong field types, etc.).
    public static func decode(_ data: Data) throws -> CompanionEnvelope {
        try JSONDecoder().decode(CompanionEnvelope.self, from: data)
    }
}
