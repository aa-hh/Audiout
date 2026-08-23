// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutProtocol

@Suite struct CompanionMessageTests {

    // MARK: - Fixtures

    private static func fullSnapshot() -> Snapshot {
        Snapshot(
            serverName: "Alec's Mac",
            devices: [
                DeviceState(
                    id: "device-1",
                    name: "Living Room",
                    kind: "airplay",
                    iconSymbolName: "hifispeaker.fill",
                    isAvailable: true,
                    supportsAirPlay2: true,
                    isLocalDevice: false,
                    volume: 80,
                    isMuted: false,
                    isSelected: true,
                    isMainOutMember: true,
                    connection: DeviceState.ConnectionInfo(state: "connected")
                ),
                DeviceState(
                    id: "device-2",
                    name: "Kitchen",
                    kind: "airplay",
                    iconSymbolName: "speaker.wave.2.fill",
                    isAvailable: false,
                    supportsAirPlay2: true,
                    isLocalDevice: false,
                    volume: 0,
                    isMuted: true,
                    isSelected: false,
                    isMainOutMember: false,
                    connection: DeviceState.ConnectionInfo(
                        state: "failed",
                        failureHeadline: "Couldn't connect",
                        failureSuggestion: "Check the speaker is powered on"
                    )
                ),
            ],
            mainOut: MainOutState(kind: "group", groupID: "group-1"),
            mainOutMasterVolume: 65,
            mainOutMuted: false,
            groups: [
                GroupState(
                    id: "group-1",
                    name: "Downstairs",
                    memberIDs: ["device-1", "device-2"],
                    memberVolumes: ["device-1": 80, "device-2": 40],
                    iconSymbolName: "house.fill",
                    isMuted: false,
                    masterVolume: 85
                ),
            ],
            activeGroupID: "group-1",
            appRoutes: [
                AppRouteState(bundleID: "com.spotify.client", displayName: "Spotify", destinationKind: "device", deviceID: "device-1", volume: 90, isRunning: true),
                AppRouteState(bundleID: "com.apple.Music", displayName: "Music", destinationKind: "noRedirect", volume: 100, isRunning: false),
            ],
            liveRoutedAppNames: ["device-1": ["Spotify"]],
            addableApps: [Snapshot.AddableApp(bundleID: "com.apple.Podcasts", displayName: "Podcasts")],
            localFallbackActive: false,
            takeoverStatus: "Taking over from another Mac",
            settings: SettingsState(connectVolume: 70, connectVolumeMin: 0, connectVolumeMax: 100, startBufferMs: 200, startBufferOptionsMs: [100, 200, 500])
        )
    }

    private func roundTrip(_ message: CompanionMessage) throws -> CompanionMessage {
        let envelope = CompanionEnvelope(message: message)
        let data = try envelope.encoded()
        return try CompanionEnvelope.decode(data).message
    }

    // MARK: - Message round-trips

    @Test func helloRoundTrips() throws {
        let message = CompanionMessage.hello(
            clientID: "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A",
            clientName: "Alec's iPhone",
            protoVersion: 1)
        #expect(try roundTrip(message) == message)
    }

    /// A hello with NO clientID key (a hand-rolled or pre-T24 client) must
    /// decode — as `clientID: ""` — rather than throw, so the server can
    /// refuse it with `CompanionGoodbyeReason.invalidClientID` instead of
    /// closing it as malformed.
    @Test func helloWithoutClientIDDecodesAsEmptyClientID() throws {
        let json = """
        {"v": 1, "type": "hello", "payload": {"clientName": "iPhone", "protoVersion": 1}}
        """
        let envelope = try CompanionEnvelope.decode(Data(json.utf8))
        #expect(envelope.message == .hello(clientID: "", clientName: "iPhone", protoVersion: 1))
    }

    @Test func awaitingApprovalRoundTrips() throws {
        #expect(try roundTrip(.awaitingApproval) == .awaitingApproval)
    }

    @Test func commandMessageRoundTrips() throws {
        let message = CompanionMessage.command(requestID: "req-1", command: .setDeviceVolume(id: "device-1", volume: 55))
        #expect(try roundTrip(message) == message)
    }

    @Test func requestAppIconsCommandMessageRoundTrips() throws {
        let message = CompanionMessage.command(requestID: "req-1", command: .requestAppIcons(bundleIDs: ["a", "b"]))
        #expect(try roundTrip(message) == message)
    }

    @Test func welcomeRoundTrips() throws {
        let message = CompanionMessage.welcome(serverName: "Alec's Mac", protoVersion: 1, snapshot: Self.fullSnapshot())
        #expect(try roundTrip(message) == message)
    }

    @Test func stateRoundTrips() throws {
        let message = CompanionMessage.state(snapshot: Self.fullSnapshot())
        #expect(try roundTrip(message) == message)
    }

    @Test func commandResultRoundTripsWithRefusal() throws {
        let message = CompanionMessage.commandResult(requestID: "req-2", applied: false, refusalReason: "device unavailable", autoSwappedCurrentDevice: false)
        #expect(try roundTrip(message) == message)
    }

    @Test func commandResultRoundTripsWithoutRefusal() throws {
        let message = CompanionMessage.commandResult(requestID: "req-3", applied: true, refusalReason: nil, autoSwappedCurrentDevice: true)
        #expect(try roundTrip(message) == message)
    }

    @Test func goodbyeRoundTrips() throws {
        let message = CompanionMessage.goodbye(reason: "shutdown")
        #expect(try roundTrip(message) == message)
    }

    @Test func appIconsRoundTrips() throws {
        let message = CompanionMessage.appIcons(
            page: 1,
            pageCount: 3,
            icons: [
                AppIconPayload(bundleID: "com.spotify.client", png: Data([0x89, 0x50, 0x4E, 0x47])),
                AppIconPayload(bundleID: "com.apple.Music", png: nil),
            ])
        let reloaded = try roundTrip(message)
        #expect(reloaded == message)
        guard case .appIcons(_, _, let icons) = reloaded else {
            Issue.record("expected .appIcons")
            return
        }
        #expect(icons[0].png == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(icons[1].png == nil)
    }

    @Test func fullyPopulatedSnapshotRoundTrips() throws {
        let snapshot = Self.fullSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let reloaded = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(reloaded == snapshot)
    }

    // MARK: - Every command case round-trips

    @Test(arguments: [
        CompanionCommand.setDeviceSelected(id: "device-1", selected: true),
        .retryConnection(id: "device-1"),
        .setMainOut(MainOutState(kind: "selected")),
        .setMainOut(MainOutState(kind: "group", groupID: "group-1")),
        .setDeviceVolume(id: "device-1", volume: 42),
        .setDeviceMuted(id: "device-1", muted: true),
        .setMainOutMasterVolume(volume: 33),
        .setMainOutMuted(muted: false),
        .createGroup(name: "Upstairs", memberIDs: ["device-1", "device-2"], iconSymbolName: "bed.double.fill"),
        .createGroup(name: "Upstairs", memberIDs: ["device-1"], iconSymbolName: nil),
        .updateGroup(GroupState(id: "group-1", name: "Downstairs", memberIDs: ["device-1"], memberVolumes: ["device-1": 50], iconSymbolName: nil, isMuted: true)),
        .deleteGroup(id: "group-1"),
        .setGroupMuted(id: "group-1", muted: true),
        .addAppRoute(bundleID: "com.spotify.client", displayName: "Spotify"),
        .removeAppRoute(bundleID: "com.spotify.client"),
        .setAppDestination(bundleID: "com.spotify.client", kind: "device", deviceID: "device-1"),
        .setAppDestination(bundleID: "com.spotify.client", kind: "noRedirect", deviceID: nil),
        .setAppVolume(bundleID: "com.spotify.client", volume: 77),
        .setConnectVolume(volume: 60),
        .setStartBufferMs(ms: 300),
        .requestAppIcons(bundleIDs: ["com.spotify.client", "com.apple.Music"]),
    ])
    func everyCommandCaseRoundTrips(_ command: CompanionCommand) throws {
        let data = try JSONEncoder().encode(command)
        let reloaded = try JSONDecoder().decode(CompanionCommand.self, from: data)
        #expect(reloaded == command)
    }

    // MARK: - Unknown-envelope-type handling

    @Test func unknownEnvelopeTypeDecodesWithoutThrowing() throws {
        let json = """
        {"v": 1, "type": "futureMessageType", "payload": {"someField": 42}}
        """
        let envelope = try CompanionEnvelope.decode(Data(json.utf8))
        #expect(envelope.message == .unknown(type: "futureMessageType"))
    }

    @Test func unknownCommandNameDecodesWithoutThrowing() throws {
        let json = """
        {"command": "futureCommand", "someField": 42}
        """
        let command = try JSONDecoder().decode(CompanionCommand.self, from: Data(json.utf8))
        #expect(command == .unknown(name: "futureCommand"))
    }

    // MARK: - Unknown-key tolerance

    @Test func decodingIgnoresUnknownExtraKeysInPayload() throws {
        let json = """
        {"v": 1, "type": "hello", "payload": {"clientID": "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A", "clientName": "iPhone", "protoVersion": 1, "somethingNewAndUnexpected": true}}
        """
        let envelope = try CompanionEnvelope.decode(Data(json.utf8))
        #expect(envelope.message == .hello(clientID: "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A", clientName: "iPhone", protoVersion: 1))
    }

    @Test func decodingIgnoresUnknownExtraKeysInCommand() throws {
        let json = """
        {"command": "setDeviceVolume", "id": "device-1", "volume": 10, "extraFutureField": "ignored"}
        """
        let command = try JSONDecoder().decode(CompanionCommand.self, from: Data(json.utf8))
        #expect(command == .setDeviceVolume(id: "device-1", volume: 10))
    }

    // MARK: - Refuse-forward, both directions

    @Test func refuseForwardRefusesAPeerOnANewerVersion() {
        #expect(CompanionProto.isIncompatible(peerVersion: CompanionProto.version + 1))
    }

    @Test func refuseForwardAcceptsAPeerOnAnOlderOrEqualVersion() {
        #expect(!CompanionProto.isIncompatible(peerVersion: CompanionProto.version))
        #expect(!CompanionProto.isIncompatible(peerVersion: max(0, CompanionProto.version - 1)))
    }

    /// Client-side direction: the phone receives `welcome` and checks the
    /// Mac's `protoVersion`.
    @Test func clientRefusesAWelcomeAdvertisingANewerProtoVersion() throws {
        let envelope = CompanionEnvelope(message: .welcome(serverName: "Mac", protoVersion: CompanionProto.version + 1, snapshot: Self.fullSnapshot()))
        let decoded = try CompanionEnvelope.decode(envelope.encoded())
        guard case .welcome(_, let protoVersion, _) = decoded.message else {
            Issue.record("expected .welcome")
            return
        }
        #expect(CompanionProto.isIncompatible(peerVersion: protoVersion))
    }

    /// Server-side direction: the Mac receives `hello` and checks the
    /// phone's `protoVersion`.
    @Test func serverRefusesAHelloAdvertisingANewerProtoVersion() throws {
        let envelope = CompanionEnvelope(message: .hello(clientID: "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A", clientName: "iPhone", protoVersion: CompanionProto.version + 1))
        let decoded = try CompanionEnvelope.decode(envelope.encoded())
        guard case .hello(_, _, let protoVersion) = decoded.message else {
            Issue.record("expected .hello")
            return
        }
        #expect(CompanionProto.isIncompatible(peerVersion: protoVersion))
    }

    // MARK: - Stable wire format (accidental coding-format drift breaks these)

    @Test func helloDecodesFromAHandWrittenWireLiteral() throws {
        let json = """
        {"v": 1, "type": "hello", "payload": {"clientID": "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A", "clientName": "Alec's iPhone", "protoVersion": 1}}
        """
        let envelope = try CompanionEnvelope.decode(Data(json.utf8))
        #expect(envelope.v == 1)
        #expect(envelope.message == .hello(clientID: "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A", clientName: "Alec's iPhone", protoVersion: 1))
    }

    @Test func awaitingApprovalDecodesFromAHandWrittenWireLiteral() throws {
        let json = """
        {"v": 1, "type": "awaitingApproval", "payload": {}}
        """
        let envelope = try CompanionEnvelope.decode(Data(json.utf8))
        #expect(envelope.message == .awaitingApproval)
    }

    @Test func setDeviceSelectedCommandDecodesFromAHandWrittenWireLiteral() throws {
        let json = """
        {"v": 1, "type": "command", "payload": {"requestID": "req-1", "command": {"command": "setDeviceSelected", "id": "device-1", "selected": true}}}
        """
        let envelope = try CompanionEnvelope.decode(Data(json.utf8))
        #expect(envelope.message == .command(requestID: "req-1", command: .setDeviceSelected(id: "device-1", selected: true)))
    }

    @Test func welcomeDecodesFromAHandWrittenWireLiteral() throws {
        let json = """
        {"v": 1, "type": "welcome", "payload": {"serverName": "Alec's Mac", "protoVersion": 1, "snapshot": {
            "serverName": "Alec's Mac",
            "devices": [],
            "mainOut": {"kind": "selected"},
            "mainOutMasterVolume": 50,
            "mainOutMuted": false,
            "groups": [],
            "appRoutes": [],
            "liveRoutedAppNames": {},
            "addableApps": [],
            "localFallbackActive": false,
            "settings": {"connectVolume": 50, "connectVolumeMin": 0, "connectVolumeMax": 100, "startBufferMs": 200, "startBufferOptionsMs": [100, 200]}
        }}}
        """
        let envelope = try CompanionEnvelope.decode(Data(json.utf8))
        guard case .welcome(let serverName, let protoVersion, let snapshot) = envelope.message else {
            Issue.record("expected .welcome")
            return
        }
        #expect(serverName == "Alec's Mac")
        #expect(protoVersion == 1)
        #expect(snapshot.mainOut == MainOutState(kind: "selected"))
        #expect(snapshot.devices.isEmpty)
        #expect(snapshot.activeGroupID == nil)
        #expect(snapshot.takeoverStatus == nil)
    }
}
