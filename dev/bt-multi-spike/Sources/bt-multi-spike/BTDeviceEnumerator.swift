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
    /// The raw kAudioDevicePropertyTransportType value, so a caller that is NOT
    /// Bluetooth-only (the lateralization probe pairs built-in with BT) can
    /// still label what it picked.
    let transport: UInt32

    /// Short human label for the transport — display only.
    var transportLabel: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        default: return "other"
        }
    }
}

enum BTDeviceEnumerator {

    /// Every Core Audio device with at least one output stream, whatever its
    /// transport. Aggregates are flagged, never filtered out — callers that
    /// drive audio MUST refuse them (AVAudioEngine silently no-ops on an
    /// aggregate device).
    static func listAllOutputDevices() -> [BTOutputDevice] {
        guard let devices = allDeviceIDs() else { return [] }
        return devices.compactMap { device in
            guard hasOutputStreams(device), let transport = transportType(device) else { return nil }
            return BTOutputDevice(
                id: device,
                name: deviceName(device) ?? "<unknown>",
                uid: (try? readDeviceUID(device)) ?? "<no-uid>",
                isAggregate: transport == kAudioDeviceTransportTypeAggregate,
                transport: transport)
        }
    }

    /// All output devices with a Bluetooth transport type, plus every aggregate
    /// device. Aggregates rarely self-report as Bluetooth transport, but we
    /// conservatively surface ALL of them so the silent-no-op trap is visible,
    /// and let the caller decide (marked EXCLUDED in the CLI output).
    static func listBluetoothOutputDevices() -> [BTOutputDevice] {
        listAllOutputDevices().filter {
            $0.isAggregate || $0.transport == kAudioDeviceTransportTypeBluetooth
        }
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
