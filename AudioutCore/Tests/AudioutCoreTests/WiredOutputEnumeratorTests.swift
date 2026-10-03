import AudioToolbox
import Foundation
import Testing
@testable import AudioutCore

/// Hermetic tests for ``WiredOutputEnumerator``: the transport/output filter
/// and the hidden default-output row swapping when the default moves. No HAL —
/// both seams are injected closures.
@Suite final class WiredOutputEnumeratorTests: IsolatedSuite {

    // MARK: Fixtures

    private let speakersUID = "BuiltInSpeakerDevice"
    private let headphonesUID = "BuiltInHeadphoneOutputDevice"

    private func output(
        uid: String, name: String = "Output",
        transport: UInt32, hasOutput: Bool = true
    ) -> BTCoreAudioOutput {
        BTCoreAudioOutput(uid: uid, name: name, transportType: transport, hasOutputStreams: hasOutput)
    }

    // MARK: Filter

    /// Defect: an excluded transport, the app's own aggregate UID, or the
    /// default output's UID leaking into the wired row list.
    @Test func filterKeepsOnlyWiredOutputsAndHidesTheDefault() {
        let outputs = [
            output(uid: "BT-1", transport: kAudioDeviceTransportTypeBluetooth),
            output(uid: "BLE-1", transport: kAudioDeviceTransportTypeBluetoothLE),
            output(uid: "AIRP-1", transport: kAudioDeviceTransportTypeAirPlay),
            output(uid: "VIRT-1", transport: kAudioDeviceTransportTypeVirtual),
            output(uid: "AGG-1", transport: kAudioDeviceTransportTypeAggregate),
            output(uid: "AUTOAGG-1", transport: kAudioDeviceTransportTypeAutoAggregate),
            output(uid: "UNK-1", transport: kAudioDeviceTransportTypeUnknown),
            output(uid: AggregateOutputDevice.productUID, transport: kAudioDeviceTransportTypeBuiltIn),
            output(uid: "USB-MIC", transport: kAudioDeviceTransportTypeUSB, hasOutput: false),
            output(uid: speakersUID, transport: kAudioDeviceTransportTypeBuiltIn),
            output(uid: headphonesUID, transport: kAudioDeviceTransportTypeBuiltIn),
            output(uid: "USB-DAC", transport: kAudioDeviceTransportTypeUSB),
            output(uid: "HDMI-1", transport: kAudioDeviceTransportTypeHDMI),
            output(uid: "DP-1", transport: kAudioDeviceTransportTypeDisplayPort),
            output(uid: "TB-1", transport: kAudioDeviceTransportTypeThunderbolt),
        ]
        let kept = WiredOutputEnumerator.filter(outputs: outputs, hiddenUIDs: [speakersUID])
        #expect(kept.map(\.id) == ["BuiltInHeadphoneOutputDevice", "DP-1", "HDMI-1", "TB-1", "USB-DAC"])
        let transports = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0.transport) })
        #expect(transports == [
            headphonesUID: .headphoneJack,
            "USB-DAC": .usb,
            "HDMI-1": .hdmi,
            "DP-1": .hdmi,
            "TB-1": .other,
        ])
        #expect(WiredOutputEnumerator.transport(for: kAudioDeviceTransportTypeBuiltIn, uid: speakersUID)
                == .builtInSpeakers)
    }

    // MARK: Hidden default

    /// Defect: the enumerator keeps hiding the old default after the default
    /// output moves.
    @Test func defaultChangeSwapsTheHiddenRow() {
        let received = SnapshotBox()
        let hidden = HiddenBox(speakersUID)
        let outputs = [
            output(uid: speakersUID, transport: kAudioDeviceTransportTypeBuiltIn),
            output(uid: headphonesUID, transport: kAudioDeviceTransportTypeBuiltIn),
        ]
        let enumerator = WiredOutputEnumerator(
            listOutputs: { outputs },
            hiddenUIDs: { hidden.value })
        enumerator.onSnapshot = { received.append($0) }

        enumerator.refresh()
        #expect(received.all.last?.map(\.id) == [headphonesUID])

        hidden.value = [headphonesUID]
        enumerator.refresh()
        #expect(received.all.last?.map(\.id) == [speakersUID])

        enumerator.refresh()
        #expect(received.all.count == 2, "an unchanged re-enumeration must not emit")
    }

    // MARK: Helpers

    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [[WiredOutputSnapshot]] = []
        func append(_ s: [WiredOutputSnapshot]) { lock.withLock { snapshots.append(s) } }
        var all: [[WiredOutputSnapshot]] { lock.withLock { snapshots } }
    }

    private final class HiddenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var uids: Set<String>
        init(_ uid: String) { uids = [uid] }
        var value: Set<String> {
            get { lock.withLock { uids } }
            set { lock.withLock { uids = newValue } }
        }
    }
}
