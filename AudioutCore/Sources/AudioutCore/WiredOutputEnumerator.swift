// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header, unlike most
// siblings. It is a fresh Core-Audio-only implementation written for this
// project; nothing in it is copied from `SyncedLocalSink.swift` or any other
// GPL-derived source. Do not add a GPL header to this file, and do not move
// GPL-derived code into it.

import AudioToolbox
import Foundation

/// One wired Core Audio output as ``WiredOutputEnumerator`` reports it.
///
/// Keyed by the Core Audio UID only. An `AudioObjectID` is never carried:
/// ticket 01's hardware pass saw the same devices change ids across hotplugs,
/// and one id later reused for a different device, so a cached id can pin the
/// wrong output.
public struct WiredOutputSnapshot: Sendable, Equatable {
    /// `kAudioDevicePropertyDeviceUID`.
    public let id: String
    public let name: String
    public let transport: Device.WiredTransport
}

/// The slice of ``WiredOutputEnumerator`` ``NativeBackend`` drives, so tests
/// feed snapshots with no HAL.
protocol WiredOutputEnumerating: AnyObject, Sendable {
    var onSnapshot: (@Sendable ([WiredOutputSnapshot]) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
}

/// Enumerates the Mac's wired Core Audio outputs (built-in speakers, headphone
/// jack, USB, HDMI/DisplayPort, Thunderbolt) through the HAL alone.
///
/// The current system default output is hidden, along with every sub-device of
/// it when it is an aggregate: "This Mac" already plays through it. The
/// enumerator listens for both the device list and the default output changing,
/// so the hidden row swaps when the default moves.
final class WiredOutputEnumerator: WiredOutputEnumerating, @unchecked Sendable {

    /// Fires on the enumerator's own serial queue with the full list whenever
    /// it changes (and once after `start()`).
    var onSnapshot: (@Sendable ([WiredOutputSnapshot]) -> Void)? {
        get { queue.sync { _onSnapshot } }
        set { queue.sync { _onSnapshot = newValue } }
    }

    private let queue = DispatchQueue(label: "WiredOutputEnumerator")
    private var _onSnapshot: (@Sendable ([WiredOutputSnapshot]) -> Void)?
    private var lastEmitted: [WiredOutputSnapshot]?
    private var listenersInstalled = false

    private let listOutputs: @Sendable () -> [BTCoreAudioOutput]
    private let hiddenUIDs: @Sendable () -> Set<String>

    init(
        listOutputs: @escaping @Sendable () -> [BTCoreAudioOutput] = BTDeviceEnumerator.systemOutputs,
        hiddenUIDs: @escaping @Sendable () -> Set<String> = WiredOutputEnumerator.systemHiddenOutputUIDs
    ) {
        self.listOutputs = listOutputs
        self.hiddenUIDs = hiddenUIDs
    }

    func start() {
        queue.async {
            self.installListenersLocked()
            self.refreshLocked()
        }
    }

    func stop() {
        queue.sync {
            removeListenersLocked()
            lastEmitted = nil
        }
    }

    /// Re-enumerate and emit if the list changed. Tests drive it synchronously;
    /// production reaches `refreshLocked` through `start()` and the listeners.
    func refresh() {
        queue.sync { refreshLocked() }
    }

    private func refreshLocked() {
        let outputs = Self.filter(outputs: listOutputs(), hiddenUIDs: hiddenUIDs())
        guard outputs != lastEmitted else { return }
        lastEmitted = outputs
        _onSnapshot?(outputs)
    }

    // MARK: Pure filter (unit-tested)

    private static let excludedTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBluetooth,
        kAudioDeviceTransportTypeBluetoothLE,
        kAudioDeviceTransportTypeAirPlay,
        kAudioDeviceTransportTypeVirtual,
        kAudioDeviceTransportTypeAggregate,
        kAudioDeviceTransportTypeAutoAggregate,
        kAudioDeviceTransportTypeUnknown,
    ]

    /// Keeps output-capable devices on a wired transport, minus this app's own
    /// aggregate and anything in `hiddenUIDs`, sorted by UID.
    static func filter(outputs: [BTCoreAudioOutput], hiddenUIDs: Set<String>) -> [WiredOutputSnapshot] {
        let ownAggregate = AggregateOutputDevice.productUID
        return outputs
            .filter {
                $0.hasOutputStreams
                    && !excludedTransports.contains($0.transportType)
                    && $0.uid != ownAggregate
                    && !hiddenUIDs.contains($0.uid)
            }
            .map { WiredOutputSnapshot(id: $0.uid, name: $0.name,
                                       transport: transport(for: $0.transportType, uid: $0.uid)) }
            .sorted { $0.id < $1.id }
    }

    /// The glyph-level transport for a HAL transport. Ticket 01 found the
    /// built-in speakers and the headphone jack are separate devices that both
    /// report `'bltn'`, so only the UID (`BuiltInHeadphoneOutputDevice`) tells
    /// the jack apart.
    static func transport(for rawTransport: UInt32, uid: String) -> Device.WiredTransport {
        switch rawTransport {
        case kAudioDeviceTransportTypeBuiltIn:
            return uid == "BuiltInHeadphoneOutputDevice" ? .headphoneJack : .builtInSpeakers
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .hdmi
        default:
            return .other
        }
    }

    // MARK: Real HAL reads (production seam default)

    /// The UIDs to hide: the default output's own UID and, when it is an
    /// aggregate or auto-aggregate, every UID in its full sub-device list.
    ///
    /// Resolves through ANY aggregate, not only this app's `productUID`: other
    /// Audiout builds leave their own aggregates (`…shots.aggregate`,
    /// `…btwake.aggregate`) as the default, and a user's own multi-output
    /// device counts too. Reads `kAudioHardwarePropertyDefaultOutputDevice`,
    /// never the system-sounds default.
    static let systemHiddenOutputUIDs: @Sendable () -> Set<String> = {
        guard let device = defaultOutputDeviceID(), let uid = stringProperty(device, kAudioDevicePropertyDeviceUID)
        else { return [] }
        var hidden: Set<String> = [uid]
        let transport = transportType(device)
        if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate {
            hidden.formUnion(subDeviceUIDs(device))
        }
        return hidden
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    private static func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let err = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let value else { return nil }
        return value as String
    }

    /// `kAudioAggregateDevicePropertyFullSubDeviceList`: a `CFArray` of
    /// `CFString` UIDs of every device the aggregate contains.
    private static func subDeviceUIDs(_ device: AudioObjectID) -> [String] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFArray?>.size)
        var value: CFArray?
        let err = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let value else { return [] }
        return (value as? [String]) ?? []
    }

    // MARK: Listeners

    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refreshLocked()   // the listener fires on `queue` already
    }

    private static let watchedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    private func installListenersLocked() {
        guard !listenersInstalled else { return }
        for selector in Self.watchedSelectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        }
        listenersInstalled = true
    }

    private func removeListenersLocked() {
        guard listenersInstalled else { return }
        for selector in Self.watchedSelectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        }
        listenersInstalled = false
    }
}
