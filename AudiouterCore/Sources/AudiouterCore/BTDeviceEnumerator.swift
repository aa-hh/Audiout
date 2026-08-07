// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5): this file carries NO
// GPL SPDX header, unlike most siblings. It is a fresh Apple-only implementation
// (Core Audio + IOBluetooth + CoreBluetooth) written for this project — the
// throwaway `dev/bt-multi-spike` harness was read for its findings only, never
// copied. Do not add a GPL header to this file, and do not move GPL-derived
// code into it.

import AudioToolbox
import CoreBluetooth
import Foundation
import IOBluetooth

// MARK: - Records

/// One Bluetooth audio output as the enumerator reports it — the merged view of
/// the Core Audio device list (connected endpoints) and the IOBluetooth paired
/// list (everything macOS has ever paired, connected or not).
public struct BTDeviceSnapshot: Sendable, Equatable {
    /// Stable identity: the Core Audio `kAudioDevicePropertyDeviceUID` when the
    /// device is connected; for a paired-but-disconnected device, the UID
    /// derived from its BT MAC address in the same `AA-BB-CC-DD-EE-FF:output`
    /// form macOS assigns (live-verified on real hardware 2026-08-07), so the
    /// id survives disconnect/rejoin and a saved group keyed on it holds.
    public let id: String
    public let name: String
    /// True iff a Core Audio output endpoint exists right now — i.e. the
    /// device can actually carry audio. A baseband-connected speaker with no
    /// audio endpoint is NOT connected in this sense.
    public let isConnected: Bool
    /// When macOS last used this pairing (`IOBluetoothDevice.recentAccessDate`).
    /// macOS keeps every pairing forever, so a UI listing all of them shows
    /// years-dead ghosts — this is the fact a later wave filters/sorts by.
    /// `nil` when unknown (no paired record, or the OS reported none).
    public let lastUsed: Date?

    public init(id: String, name: String, isConnected: Bool, lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.lastUsed = lastUsed
    }
}

/// One Core Audio device as the enumeration seam reports it, pre-filter.
/// Plain values so the transport/output filter is unit-testable with no HAL.
struct BTCoreAudioOutput: Sendable, Equatable {
    let uid: String
    let name: String
    /// `kAudioDevicePropertyTransportType` — the filter keeps only
    /// `kAudioDeviceTransportTypeBluetooth`, which excludes aggregate/virtual
    /// devices (their own transport types) by the same comparison.
    let transportType: UInt32
    let hasOutputStreams: Bool
}

/// One IOBluetooth paired-list entry as the pairing seam reports it.
struct BTPairedRecord: Sendable, Equatable {
    let name: String?
    /// The BT MAC address string (any of the OS's `aa-bb-cc-dd-ee-ff` /
    /// colon-separated casings — matching normalizes). `nil` = no stable
    /// identity is derivable, so the record is skipped.
    let address: String?
    /// Advertises audio: a cached A2DP AudioSink SDP record, or Class-of-Device
    /// major class Audio/Video (recorded at pairing, so it survives for
    /// long-disconnected devices whose SDP cache is gone). Filters keyboards,
    /// mice, and phones out of the merge.
    let isAudioCapable: Bool
    let lastUsed: Date?
}

// MARK: - Seam

/// The slice of ``BTDeviceEnumerator`` ``NativeBackend`` drives. Extracted as a
/// protocol (same discipline as `DiscoverySource`) so tests feed snapshots
/// synchronously with no HAL, no IOBluetooth, and no Bluetooth TCC.
protocol BTDeviceEnumerating: AnyObject, Sendable {
    var onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - Enumerator

/// Enumerates Bluetooth audio outputs: Core Audio devices with Bluetooth
/// transport (connected, `isConnected == true`) merged with the IOBluetooth
/// paired list (paired-but-disconnected speakers surface with
/// `isConnected == false`, so a powered-off speaker keeps its row).
///
/// TCC (live-verified 2026-08-07, macOS 27): an IOBluetooth call from a process
/// without the Bluetooth grant KILLS the process — no prompt, no error, SIGABRT.
/// Every IOBluetooth touch is therefore gated on `isBluetoothAuthorized()`
/// (`CBManager.authorization`, a prompt-free read); ungranted, the enumerator
/// degrades to Core-Audio-only enumeration (connected speakers still surface,
/// paired-but-disconnected ones don't) instead of crashing the app or the test
/// runner. Requesting the grant is a later wave's job (BT-CONNECT).
final class BTDeviceEnumerator: BTDeviceEnumerating, @unchecked Sendable {

    /// Fires on the enumerator's own serial queue with the full merged list
    /// whenever it changes (and once after `start()`).
    var onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)? {
        get { queue.sync { _onSnapshot } }
        set { queue.sync { _onSnapshot = newValue } }
    }

    private let queue = DispatchQueue(label: "BTDeviceEnumerator")
    private var _onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)?
    private var lastEmitted: [BTDeviceSnapshot]?
    private var listenerInstalled = false

    private let listOutputs: @Sendable () -> [BTCoreAudioOutput]
    private let listPaired: @Sendable () -> [BTPairedRecord]
    private let isBluetoothAuthorized: @Sendable () -> Bool

    /// Production defaults touch the real HAL / IOBluetooth; tests inject all
    /// three (`NativeBackend`'s designated init defaults to NO enumerator, so
    /// no test constructs a real one by accident).
    init(
        listOutputs: @escaping @Sendable () -> [BTCoreAudioOutput] = BTDeviceEnumerator.systemOutputs,
        listPaired: @escaping @Sendable () -> [BTPairedRecord] = BTDeviceEnumerator.systemPairedRecords,
        isBluetoothAuthorized: @escaping @Sendable () -> Bool = { CBManager.authorization == .allowedAlways }
    ) {
        self.listOutputs = listOutputs
        self.listPaired = listPaired
        self.isBluetoothAuthorized = isBluetoothAuthorized
    }

    /// Initial enumeration + a `kAudioHardwarePropertyDevices` listener so a
    /// speaker connecting/disconnecting re-enumerates (its audio endpoint
    /// appearing/vanishing is the availability edge). A fresh pairing made in
    /// System Settings connects too, so it arrives through the same listener.
    func start() {
        queue.async {
            self.installDeviceListListenerLocked()
            self.refreshLocked()
        }
    }

    func stop() {
        queue.sync {
            removeDeviceListListenerLocked()
            lastEmitted = nil
        }
    }

    /// Re-enumerate and emit if the merged list changed. Exposed internally so
    /// tests drive it synchronously (production entry points are `start()` and
    /// the device-list listener, both funneling here on `queue`).
    func refresh() {
        queue.sync { refreshLocked() }
    }

    private func refreshLocked() {
        let paired = isBluetoothAuthorized() ? listPaired() : []
        let merged = Self.merge(outputs: listOutputs(), paired: paired)
        guard merged != lastEmitted else { return }
        lastEmitted = merged
        _onSnapshot?(merged)
    }

    // MARK: Pure filter + merge (unit-tested)

    /// The merge: connected Core Audio BT outputs are the truth for "can carry
    /// audio now" (id = real UID); audio-capable paired records with no
    /// matching endpoint become disconnected snapshots under the derived UID.
    /// Matching is by normalized MAC hex, so address-formatting differences
    /// between IOBluetooth (`aa-bb-cc-dd-ee-ff`) and Core Audio UIDs
    /// (`AA-BB-CC-DD-EE-FF:output`) never split one speaker into two rows.
    static func merge(outputs: [BTCoreAudioOutput], paired: [BTPairedRecord]) -> [BTDeviceSnapshot] {
        let connected = outputs.filter {
            $0.transportType == kAudioDeviceTransportTypeBluetooth && $0.hasOutputStreams
        }
        let pairedByMAC: [String: BTPairedRecord] = paired.reduce(into: [:]) { acc, record in
            guard let key = macKey(record.address) else { return }
            acc[key] = record
        }
        var snapshots: [BTDeviceSnapshot] = []
        var seenMACs: Set<String> = []
        for output in connected {
            let key = macKey(output.uid)
            if let key {
                guard seenMACs.insert(key).inserted else { continue }   // one row per speaker
            }
            let record = key.flatMap { pairedByMAC[$0] }
            snapshots.append(BTDeviceSnapshot(
                id: output.uid, name: output.name, isConnected: true, lastUsed: record?.lastUsed))
        }
        for record in paired {
            guard record.isAudioCapable,
                  let key = macKey(record.address), !seenMACs.contains(key),
                  let id = derivedUID(fromAddress: record.address ?? "")
            else { continue }
            seenMACs.insert(key)
            snapshots.append(BTDeviceSnapshot(
                id: id, name: record.name ?? record.address ?? id,
                isConnected: false, lastUsed: record.lastUsed))
        }
        return snapshots.sorted { $0.id < $1.id }
    }

    /// The Core Audio UID a Bluetooth output gets on this platform:
    /// dash-separated uppercase MAC + `:output` (observed on real hardware —
    /// e.g. `C4-38-75-0E-BF-4A:output`). This is what makes a
    /// paired-but-disconnected row's id equal the id the same speaker carries
    /// while connected. `nil` when the address isn't a full 6-byte MAC.
    static func derivedUID(fromAddress address: String) -> String? {
        let hex = normalizedHex(address)
        guard hex.count == 12 else { return nil }
        let pairs = stride(from: 0, to: 12, by: 2).map { i -> Substring in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return hex[start..<hex.index(start, offsetBy: 2)]
        }
        return pairs.joined(separator: "-") + ":output"
    }

    /// The 12-hex-digit MAC key both sides merge on, or `nil` when the string
    /// doesn't contain exactly a 6-byte address (a non-MAC UID keeps its row
    /// but can never be claimed by a paired record). Works on any of the
    /// observed formats — `aa-bb-cc-dd-ee-ff`, `AA:BB:CC:DD:EE:FF`, and Core
    /// Audio's `AA-BB-CC-DD-EE-FF:output` — because neither the separators nor
    /// the `output`/`input` suffix contain hex characters.
    private static func macKey(_ s: String?) -> String? {
        guard let s else { return nil }
        let hex = normalizedHex(s)
        return hex.count == 12 ? hex : nil
    }

    private static func normalizedHex(_ s: String) -> String {
        String(s.uppercased().unicodeScalars.filter { CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) })
    }

    // MARK: Real Core Audio listing (production seam default)

    private static let systemOutputs: @Sendable () -> [BTCoreAudioOutput] = {
        allDeviceIDs().compactMap { device in
            guard let transport = transportType(device), let uid = deviceUID(device) else { return nil }
            return BTCoreAudioOutput(
                uid: uid,
                name: deviceName(device) ?? uid,
                transportType: transport,
                hasOutputStreams: hasOutputStreams(device))
        }
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var devices = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices) == noErr else { return [] }
        return devices
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

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        stringProperty(device, selector: kAudioObjectPropertyName)
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
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

    // MARK: Real IOBluetooth listing (production seam default)
    //
    // NEVER call without the authorization gate having passed — see the class
    // doc: an ungranted IOBluetooth touch kills the process outright.

    private static let systemPairedRecords: @Sendable () -> [BTPairedRecord] = {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.map { device in
            BTPairedRecord(
                name: device.name,
                address: device.addressString,
                isAudioCapable: isAudioCapable(device),
                lastUsed: device.recentAccessDate())
        }
    }

    /// A cached A2DP AudioSink SDP record (UUID16 0x110B) is the strong signal;
    /// Class-of-Device major Audio/Video is the fallback that survives for
    /// long-disconnected devices with no SDP cache.
    private static func isAudioCapable(_ device: IOBluetoothDevice) -> Bool {
        if device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x110B)) != nil { return true }
        return device.deviceClassMajor == kBluetoothDeviceClassMajorAudio
    }

    // MARK: Device-list listener

    private lazy var deviceListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refreshLocked()   // the listener fires on `queue` already
    }

    private func installDeviceListListenerLocked() {
        guard !listenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, deviceListListener)
        listenerInstalled = (err == noErr)
    }

    private func removeDeviceListListenerLocked() {
        guard listenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, deviceListListener)
        listenerInstalled = false
    }
}
