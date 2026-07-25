import AudioToolbox
import Foundation

// ============================================================================
// BTDeviceEnumerator — lists Core Audio output devices whose transport type is
// Bluetooth, and flags aggregate devices (the silent-no-op trap surface: an
// aggregate device can pass a "has output streams" check while never actually
// delivering audio through a real BT transport).
//
// Property-address plumbing re-derived from LocalPlaybackEngine.builtInOutputDeviceID
// (AudiouterCore) against the actual CoreAudio headers — see hasOutputStreams/
// transportType below.
// ============================================================================

struct BTOutputDevice {
    let id: AudioObjectID
    let name: String
    let uid: String
    let isAggregate: Bool
}

enum BTDeviceEnumerator {

    /// All Core Audio devices with at least one output stream AND a Bluetooth
    /// transport type. Also flags kAudioDeviceTransportTypeAggregate devices
    /// (excluded by convention — callers should skip them for real BT routing).
    static func listBluetoothOutputDevices() -> [BTOutputDevice] {
        guard let devices = allDeviceIDs() else { return [] }
        var results: [BTOutputDevice] = []
        for device in devices {
            guard hasOutputStreams(device) else { continue }
            guard let transport = transportType(device) else { continue }
            let isAggregate = transport == kAudioDeviceTransportTypeAggregate
            guard transport == kAudioDeviceTransportTypeBluetooth || isAggregate else { continue }
            // Aggregates rarely self-report as Bluetooth transport, but we only
            // want to surface an aggregate here if it's plausibly BT-composed;
            // conservatively include ALL aggregates so the trap is visible, and
            // let the caller decide (marked EXCLUDED in the CLI output below).
            let name = deviceName(device) ?? "<unknown>"
            let uid = (try? readDeviceUID(device)) ?? "<no-uid>"
            results.append(BTOutputDevice(id: device, name: name, uid: uid, isAggregate: isAggregate))
        }
        return results
    }

    // MARK: - CoreAudio plumbing (pattern: LocalPlaybackEngine.builtInOutputDeviceID)

    private static func allDeviceIDs() -> [AudioObjectID]? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var devices = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices) == noErr else { return nil }
        return devices
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

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString? = nil
        let err = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let name = name else { return nil }
        return name as String
    }

    /// Reads the UID string of an AudioObjectID (device). Local copy (kept
    /// dependency-free from audiocap's CAHelpers.swift, which this target does
    /// not share).
    private static func readDeviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString? = nil
        let err = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let uid = uid else {
            throw CAError("read kAudioDevicePropertyDeviceUID failed", status: err)
        }
        return uid as String
    }
}

struct CAError: Error, CustomStringConvertible {
    let message: String
    let status: OSStatus?
    init(_ message: String, status: OSStatus? = nil) {
        self.message = message
        self.status = status
    }
    var description: String { message }
}
