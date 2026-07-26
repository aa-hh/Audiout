// SPDX-License-Identifier: GPL-2.0-or-later

/// Every command the phone can send, 1:1 with an existing Mac controller
/// method (`CompanionCommandDispatcher`, T4, calls the exact method the
/// popover already calls — no new business logic). `beginMainOutDrag` /
/// `setMainOutMasterVolume` / `endMainOutDrag` bracket a Main Out master-drag
/// exactly like the popover's own drag brackets.
///
/// ## Wire format
///
/// Hand-written `Codable`, not synthesized: a plain `enum Codable`
/// synthesizes as a single-key object keyed by the case name (e.g.
/// `{"setDeviceVolume": {"id": "x", "volume": 50}}`), which is fragile to
/// rename-refactor (Swift's synthesized key is the case's identifier, so
/// renaming a case identifier silently changes the wire format with no
/// compiler warning) and awkward for a non-Swift phone client to reason
/// about. Instead every command is one explicit JSON object:
///
/// ```json
/// {"command": "setDeviceVolume", "id": "device-1", "volume": 50}
/// ```
///
/// `"command"` is the discriminator (NOT `"name"` — `createGroup` already has
/// a `name` field, so reusing that key for the discriminator would collide).
/// Every other key is optional depending on the case; see the switch in
/// `encode(to:)`/`init(from:)` below for exactly which keys each case reads
/// and writes.
///
/// **Changing the encoding of an existing case is a protocol break.** Add a
/// new case instead, and bump `CompanionProto.version` only if a peer that
/// doesn't understand the new case would misbehave (it won't — the server
/// answers an unrecognized `"command"` with `.unknown(name:)`, decoded
/// without throwing, so a version mismatch is never required just to add a
/// command).
public enum CompanionCommand: Equatable, Sendable {
    case setDeviceSelected(id: String, selected: Bool)
    case retryConnection(id: String)
    case setMainOut(MainOutState)
    case setDeviceVolume(id: String, volume: Int)
    case setDeviceMuted(id: String, muted: Bool)
    case beginMainOutDrag
    case setMainOutMasterVolume(volume: Int)
    case endMainOutDrag
    case setMainOutMuted(muted: Bool)
    case createGroup(name: String, memberIDs: [String], iconSymbolName: String?)
    case updateGroup(GroupState)
    case deleteGroup(id: String)
    case setGroupMuted(id: String, muted: Bool)
    case addAppRoute(bundleID: String, displayName: String)
    case removeAppRoute(bundleID: String)
    case setAppDestination(bundleID: String, kind: String, deviceID: String?)
    case setAppVolume(bundleID: String, volume: Int)
    case setConnectVolume(volume: Int)
    case setStartBufferMs(ms: Int)

    /// An unrecognized `"command"` string — e.g. a newer phone talking to an
    /// older Mac. Decodes without throwing so the server can answer with a
    /// failed `commandResult` instead of dropping the connection.
    case unknown(name: String)
}

extension CompanionCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case command
        case id, selected, volume, muted
        case mainOut
        case name, memberIDs, iconSymbolName
        case group
        case bundleID, displayName, kind, deviceID
        case ms
    }

    private enum Name: String {
        case setDeviceSelected, retryConnection, setMainOut, setDeviceVolume, setDeviceMuted
        case beginMainOutDrag, setMainOutMasterVolume, endMainOutDrag, setMainOutMuted
        case createGroup, updateGroup, deleteGroup, setGroupMuted
        case addAppRoute, removeAppRoute, setAppDestination, setAppVolume
        case setConnectVolume, setStartBufferMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawCommand = try c.decode(String.self, forKey: .command)
        guard let name = Name(rawValue: rawCommand) else {
            self = .unknown(name: rawCommand)
            return
        }
        switch name {
        case .setDeviceSelected:
            self = .setDeviceSelected(id: try c.decode(String.self, forKey: .id), selected: try c.decode(Bool.self, forKey: .selected))
        case .retryConnection:
            self = .retryConnection(id: try c.decode(String.self, forKey: .id))
        case .setMainOut:
            self = .setMainOut(try c.decode(MainOutState.self, forKey: .mainOut))
        case .setDeviceVolume:
            self = .setDeviceVolume(id: try c.decode(String.self, forKey: .id), volume: try c.decode(Int.self, forKey: .volume))
        case .setDeviceMuted:
            self = .setDeviceMuted(id: try c.decode(String.self, forKey: .id), muted: try c.decode(Bool.self, forKey: .muted))
        case .beginMainOutDrag:
            self = .beginMainOutDrag
        case .setMainOutMasterVolume:
            self = .setMainOutMasterVolume(volume: try c.decode(Int.self, forKey: .volume))
        case .endMainOutDrag:
            self = .endMainOutDrag
        case .setMainOutMuted:
            self = .setMainOutMuted(muted: try c.decode(Bool.self, forKey: .muted))
        case .createGroup:
            self = .createGroup(
                name: try c.decode(String.self, forKey: .name),
                memberIDs: try c.decode([String].self, forKey: .memberIDs),
                iconSymbolName: try c.decodeIfPresent(String.self, forKey: .iconSymbolName)
            )
        case .updateGroup:
            self = .updateGroup(try c.decode(GroupState.self, forKey: .group))
        case .deleteGroup:
            self = .deleteGroup(id: try c.decode(String.self, forKey: .id))
        case .setGroupMuted:
            self = .setGroupMuted(id: try c.decode(String.self, forKey: .id), muted: try c.decode(Bool.self, forKey: .muted))
        case .addAppRoute:
            self = .addAppRoute(bundleID: try c.decode(String.self, forKey: .bundleID), displayName: try c.decode(String.self, forKey: .displayName))
        case .removeAppRoute:
            self = .removeAppRoute(bundleID: try c.decode(String.self, forKey: .bundleID))
        case .setAppDestination:
            self = .setAppDestination(
                bundleID: try c.decode(String.self, forKey: .bundleID),
                kind: try c.decode(String.self, forKey: .kind),
                deviceID: try c.decodeIfPresent(String.self, forKey: .deviceID)
            )
        case .setAppVolume:
            self = .setAppVolume(bundleID: try c.decode(String.self, forKey: .bundleID), volume: try c.decode(Int.self, forKey: .volume))
        case .setConnectVolume:
            self = .setConnectVolume(volume: try c.decode(Int.self, forKey: .volume))
        case .setStartBufferMs:
            self = .setStartBufferMs(ms: try c.decode(Int.self, forKey: .ms))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setDeviceSelected(let id, let selected):
            try c.encode(Name.setDeviceSelected.rawValue, forKey: .command)
            try c.encode(id, forKey: .id)
            try c.encode(selected, forKey: .selected)
        case .retryConnection(let id):
            try c.encode(Name.retryConnection.rawValue, forKey: .command)
            try c.encode(id, forKey: .id)
        case .setMainOut(let state):
            try c.encode(Name.setMainOut.rawValue, forKey: .command)
            try c.encode(state, forKey: .mainOut)
        case .setDeviceVolume(let id, let volume):
            try c.encode(Name.setDeviceVolume.rawValue, forKey: .command)
            try c.encode(id, forKey: .id)
            try c.encode(volume, forKey: .volume)
        case .setDeviceMuted(let id, let muted):
            try c.encode(Name.setDeviceMuted.rawValue, forKey: .command)
            try c.encode(id, forKey: .id)
            try c.encode(muted, forKey: .muted)
        case .beginMainOutDrag:
            try c.encode(Name.beginMainOutDrag.rawValue, forKey: .command)
        case .setMainOutMasterVolume(let volume):
            try c.encode(Name.setMainOutMasterVolume.rawValue, forKey: .command)
            try c.encode(volume, forKey: .volume)
        case .endMainOutDrag:
            try c.encode(Name.endMainOutDrag.rawValue, forKey: .command)
        case .setMainOutMuted(let muted):
            try c.encode(Name.setMainOutMuted.rawValue, forKey: .command)
            try c.encode(muted, forKey: .muted)
        case .createGroup(let name, let memberIDs, let iconSymbolName):
            try c.encode(Name.createGroup.rawValue, forKey: .command)
            try c.encode(name, forKey: .name)
            try c.encode(memberIDs, forKey: .memberIDs)
            try c.encodeIfPresent(iconSymbolName, forKey: .iconSymbolName)
        case .updateGroup(let group):
            try c.encode(Name.updateGroup.rawValue, forKey: .command)
            try c.encode(group, forKey: .group)
        case .deleteGroup(let id):
            try c.encode(Name.deleteGroup.rawValue, forKey: .command)
            try c.encode(id, forKey: .id)
        case .setGroupMuted(let id, let muted):
            try c.encode(Name.setGroupMuted.rawValue, forKey: .command)
            try c.encode(id, forKey: .id)
            try c.encode(muted, forKey: .muted)
        case .addAppRoute(let bundleID, let displayName):
            try c.encode(Name.addAppRoute.rawValue, forKey: .command)
            try c.encode(bundleID, forKey: .bundleID)
            try c.encode(displayName, forKey: .displayName)
        case .removeAppRoute(let bundleID):
            try c.encode(Name.removeAppRoute.rawValue, forKey: .command)
            try c.encode(bundleID, forKey: .bundleID)
        case .setAppDestination(let bundleID, let kind, let deviceID):
            try c.encode(Name.setAppDestination.rawValue, forKey: .command)
            try c.encode(bundleID, forKey: .bundleID)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(deviceID, forKey: .deviceID)
        case .setAppVolume(let bundleID, let volume):
            try c.encode(Name.setAppVolume.rawValue, forKey: .command)
            try c.encode(bundleID, forKey: .bundleID)
            try c.encode(volume, forKey: .volume)
        case .setConnectVolume(let volume):
            try c.encode(Name.setConnectVolume.rawValue, forKey: .command)
            try c.encode(volume, forKey: .volume)
        case .setStartBufferMs(let ms):
            try c.encode(Name.setStartBufferMs.rawValue, forKey: .command)
            try c.encode(ms, forKey: .ms)
        case .unknown(let name):
            // Round-trips as whatever it decoded from — re-encoding an
            // `.unknown` just forwards the original unrecognized name with
            // no fields, since we never understood its payload shape.
            try c.encode(name, forKey: .command)
        }
    }
}
