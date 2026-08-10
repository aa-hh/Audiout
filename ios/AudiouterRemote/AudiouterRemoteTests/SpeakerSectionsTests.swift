// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AudiouterProtocol
@testable import AudiouterRemote

/// The Speakers-tab section membership rules, most importantly the Bluetooth
/// connected-only rule: a BT device gets a row exactly while `isAvailable` is
/// true, and its `connection.state` must play no part — the Mac keeps a failed
/// BT attempt sticky, so keying a row on it would pin a row for a speaker
/// that's gone.
@Suite struct SpeakerSectionsTests {

    private func makeDevice(
        id: String = "d1",
        kind: String = "generic",
        isAvailable: Bool = true,
        isSelected: Bool = false,
        connectionState: String = "off"
    ) -> DeviceState {
        DeviceState(
            id: id,
            name: "Speaker",
            kind: kind,
            iconSymbolName: "hifispeaker.fill",
            isAvailable: isAvailable,
            supportsAirPlay2: kind != "bluetooth",
            isLocalDevice: false,
            volume: 50,
            isMuted: false,
            isSelected: isSelected,
            isMainOutMember: false,
            connection: DeviceState.ConnectionInfo(state: connectionState)
        )
    }

    @Test func aConnectedBluetoothDeviceGetsABluetoothRowNotAnAirPlayOne() {
        let bt = makeDevice(kind: "bluetooth")
        #expect(SpeakerSections.bluetooth([bt]).map(\.id) == ["d1"])
        #expect(SpeakerSections.airplay([bt]).isEmpty)
    }

    @Test func aDisconnectedBluetoothDeviceShowsNoRowAnywhere() {
        // Connected-only: not even UNAVAILABLE — grey-but-kept rows are an
        // AirPlay notion. The sticky "failed" state is the exact trap: the row
        // must vanish on the availability fact, not linger on the story.
        let gone = makeDevice(kind: "bluetooth", isAvailable: false, connectionState: "failed")
        #expect(SpeakerSections.bluetooth([gone]).isEmpty)
        #expect(SpeakerSections.unavailable([gone]).isEmpty)
        #expect(SpeakerSections.airplay([gone]).isEmpty)
        #expect(SpeakerSections.armed([gone]).isEmpty)
    }

    @Test func anArmedBluetoothDeviceLivesInArmedNotInTheBluetoothSection() {
        let armed = makeDevice(kind: "bluetooth", isSelected: true)
        #expect(SpeakerSections.armed([armed]).map(\.id) == ["d1"])
        #expect(SpeakerSections.bluetooth([armed]).isEmpty)
    }

    @Test func anUnavailableAirPlayDeviceStillGetsItsGreyRow() {
        let offline = makeDevice(isAvailable: false, connectionState: "failed")
        #expect(SpeakerSections.unavailable([offline]).map(\.id) == ["d1"])
    }
}
