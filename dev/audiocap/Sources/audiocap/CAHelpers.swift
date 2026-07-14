import AudioToolbox
import AppKit
import Foundation

// MARK: - Diagnostics routing
//
// When --stdout is active, raw PCM goes to fd 1 and ALL diagnostics MUST go to
// stderr. `elog` is the single diagnostics sink used everywhere.
func elog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - OSStatus formatting
//
// Core Audio OSStatus values are frequently 4-char codes ('who?', 'obj!', etc.).
// Render both the numeric value and, when printable, the FourCC.
func osStatusString(_ status: OSStatus) -> String {
    let code = UInt32(bitPattern: status)
    let chars: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF)
    ]
    let printable = chars.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    if printable {
        let fourCC = String(bytes: chars, encoding: .ascii) ?? "????"
        return "\(status) ('\(fourCC)')"
    }
    return "\(status)"
}

struct CAError: Error, CustomStringConvertible {
    let message: String
    let status: OSStatus?
    init(_ message: String, status: OSStatus? = nil) {
        self.message = message
        self.status = status
    }
    var description: String {
        if let s = status {
            return "\(message) (OSStatus \(osStatusString(s)))"
        }
        return message
    }
}

func checkStatus(_ status: OSStatus, _ context: String) throws {
    guard status == noErr else {
        throw CAError(context, status: status)
    }
}

// MARK: - Device UID reads

/// Reads the UID string of an AudioObjectID (device).
func readDeviceUID(_ deviceID: AudioObjectID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var uid: CFString? = nil
    let err = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
    }
    try checkStatus(err, "read kAudioDevicePropertyDeviceUID")
    guard let uid = uid else {
        throw CAError("device UID was null")
    }
    return uid as String
}

/// The current default *system* output device object ID (what the tap follows).
func defaultSystemOutputDeviceID() throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    try checkStatus(err, "read kAudioHardwarePropertyDefaultSystemOutputDevice")
    guard deviceID != kAudioObjectUnknown else {
        throw CAError("no default system output device")
    }
    return deviceID
}

// MARK: - PID / bundle -> Core Audio process object translation
//
// Taps identify processes by a Core Audio `AudioObjectID` (the "process object"),
// NOT by raw pid. Translate a pid via kAudioHardwarePropertyTranslatePIDToProcessObject
// on the system object, with the pid passed as the property qualifier (0e brief §2).

/// Translate a Unix pid to its Core Audio process AudioObjectID.
/// Throws if the pid is not a known audio process (never opened an audio stream).
func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var pidQualifier = pid
    var objID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), &pidQualifier,
        &size, &objID)
    guard err == noErr else {
        throw CAError("translate pid \(pid) -> process object failed", status: err)
    }
    guard objID != kAudioObjectUnknown else {
        throw CAError("pid \(pid) is not a known Core Audio process "
            + "(it has not opened an audio stream — start playback in it first)")
    }
    return objID
}

/// Resolve a bundle identifier (e.g. com.spotify.client) to the pid of a running
/// instance via NSRunningApplication. Throws if no running app matches.
func pidForBundleID(_ bundleID: String) throws -> pid_t {
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard let app = matches.first else {
        throw CAError("no running application with bundle id '\(bundleID)'")
    }
    let pid = app.processIdentifier
    guard pid > 0 else {
        throw CAError("running application '\(bundleID)' has no valid pid")
    }
    return pid
}

// MARK: - Float32 -> S16LE conversion (pipe bridge, T-0f-2)
//
// OwnTone's pipe input is raw headerless S16LE interleaved. The tap delivers
// interleaved Float32. Convert scalar-wise with clamping to [-1, 1] then scale to
// the full Int16 range. No dither (not needed for the spike). Kept out of the
// realtime IOProc: this runs on the writer thread.

/// Convert one Float32 sample in [-1, 1] to a clamped little-endian Int16.
/// Uses 32767 as the positive scale and clamps to [-32768, 32767]. Rounding is
/// round-half-away-from-zero so symmetric levels map symmetrically.
@inline(__always)
func floatToInt16(_ x: Float) -> Int16 {
    // Clamp first so NaN/inf and out-of-range values can't wrap.
    var v = x
    if v.isNaN { v = 0 }
    if v > 1.0 { v = 1.0 }
    if v < -1.0 { v = -1.0 }
    let scaled = v * 32767.0
    let rounded = (scaled >= 0) ? (scaled + 0.5) : (scaled - 0.5)
    if rounded >= 32767.0 { return Int16(32767) }
    if rounded <= -32768.0 { return Int16(-32768) }
    return Int16(rounded)
}

/// Convert a buffer of `count` Float32 samples into S16LE bytes appended to `out`.
/// `out` must have room for count*2 bytes; writes little-endian regardless of host.
@inline(__always)
func convertFloat32ToS16LE(_ src: UnsafePointer<Float>, count: Int,
                           into out: UnsafeMutablePointer<UInt8>) {
    var j = 0
    for i in 0..<count {
        let s = floatToInt16(src[i])
        let u = UInt16(bitPattern: s)
        out[j] = UInt8(u & 0xFF)          // low byte first (LE)
        out[j + 1] = UInt8((u >> 8) & 0xFF)
        j += 2
    }
}

// MARK: - ASBD description

func describeASBD(_ asbd: AudioStreamBasicDescription) -> String {
    let flags = asbd.mFormatFlags
    var flagNames: [String] = []
    if flags & kAudioFormatFlagIsFloat != 0 { flagNames.append("Float") }
    if flags & kAudioFormatFlagIsSignedInteger != 0 { flagNames.append("SignedInt") }
    if flags & kAudioFormatFlagIsBigEndian != 0 { flagNames.append("BigEndian") } else { flagNames.append("LittleEndian") }
    if flags & kAudioFormatFlagIsPacked != 0 { flagNames.append("Packed") }
    if flags & kAudioFormatFlagIsNonInterleaved != 0 { flagNames.append("NonInterleaved") } else { flagNames.append("Interleaved") }

    let fourCC: String = {
        let id = asbd.mFormatID
        let bytes: [UInt8] = [
            UInt8((id >> 24) & 0xFF), UInt8((id >> 16) & 0xFF),
            UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(id)"
    }()

    return """
    ASBD:
      sampleRate      = \(asbd.mSampleRate)
      formatID        = '\(fourCC)'
      formatFlags     = 0x\(String(flags, radix: 16)) [\(flagNames.joined(separator: ", "))]
      bytesPerPacket  = \(asbd.mBytesPerPacket)
      framesPerPacket = \(asbd.mFramesPerPacket)
      bytesPerFrame   = \(asbd.mBytesPerFrame)
      channelsPerFrame= \(asbd.mChannelsPerFrame)
      bitsPerChannel  = \(asbd.mBitsPerChannel)
    """
}
