// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

#if canImport(AudioToolbox)
import AudioToolbox

/// The measured breakdown of the CURRENT DEFAULT OUTPUT DEVICE's total output
/// latency (brief `dev/notes/p2b-synced-local-brief.md` §4b), used by the
/// synced local sink to compute how far ahead of "now" a frame must be
/// scheduled so it leaves the Mac's speaker at the same instant it leaves an
/// AirPlay receiver.
public struct LocalOutputLatencyMeasurement: Equatable, Sendable {
    public let safetyOffsetFrames: UInt32
    public let deviceLatencyFrames: UInt32
    public let streamLatencyFrames: UInt32
    public let bufferFrameSizeFrames: UInt32
    public let nominalSampleRate: Double

    public init(
        safetyOffsetFrames: UInt32,
        deviceLatencyFrames: UInt32,
        streamLatencyFrames: UInt32,
        bufferFrameSizeFrames: UInt32,
        nominalSampleRate: Double
    ) {
        self.safetyOffsetFrames = safetyOffsetFrames
        self.deviceLatencyFrames = deviceLatencyFrames
        self.streamLatencyFrames = streamLatencyFrames
        self.bufferFrameSizeFrames = bufferFrameSizeFrames
        self.nominalSampleRate = nominalSampleRate
    }

    /// `safetyOffset + deviceLatency + streamLatency + bufferFrameSize` — the
    /// standard Core Audio formula (Apple's `kAudioDevicePropertyLatency` docs;
    /// coreaudio-api mailing list latency-formula thread, brief §4b). The
    /// buffer term is included because a callback's samples don't actually
    /// leave the driver's I/O buffer until the buffer fills.
    public var totalFrames: UInt32 {
        safetyOffsetFrames &+ deviceLatencyFrames &+ streamLatencyFrames &+ bufferFrameSizeFrames
    }

    public var totalSeconds: Double {
        guard nominalSampleRate > 0, nominalSampleRate.isFinite else { return 0 }
        return Double(totalFrames) / nominalSampleRate
    }

    public var totalMilliseconds: Double { totalSeconds * 1000 }
}

public enum LocalOutputLatencyError: Error, Equatable, Sendable {
    case noDefaultOutputDevice(reason: String)
    case noOutputStreams(reason: String)
    case propertyReadFailed(selector: String, status: OSStatus)
}

/// Reads the default output device's latency-contributing properties and
/// converts them to seconds/milliseconds for the synced local sink's delay
/// math (T-LATENCY; consumed by `SyncedLocalSink`'s
/// `engine.startBufferMs − localOutputLatencyMs − safetyMarginMs` formula).
public enum LocalOutputLatency {

    /// Measures the CURRENT DEFAULT OUTPUT DEVICE — always
    /// `kAudioHardwarePropertyDefaultOutputDevice`, never
    /// `kAudioHardwarePropertyDefaultSystemOutputDevice` (the alert-sound
    /// device); see AGENTS.md "Tap follows default output device" — the same
    /// selector mistake has drifted back in before.
    public static func measure() throws -> LocalOutputLatencyMeasurement {
        try measure(deviceID: defaultOutputDeviceID())
    }

    /// The CURRENT DEFAULT OUTPUT DEVICE's nominal sample rate (Hz) — read from
    /// `kAudioHardwarePropertyDefaultOutputDevice`, never
    /// `kAudioHardwarePropertyDefaultSystemOutputDevice` (see `measure()`). Used to
    /// build ``SyncedLocalSink`` at the device's own render rate so opening it never
    /// forces a 48↔44.1 kHz renegotiation (T3 Part B). A lighter read than
    /// ``measure()`` — it touches only the one property, so a device that momentarily
    /// exposes no output streams still yields a rate rather than throwing.
    public static func defaultOutputDeviceNominalSampleRate() throws -> Double {
        try readDouble(
            defaultOutputDeviceID(), selector: kAudioDevicePropertyNominalSampleRate,
            scopes: [kAudioObjectPropertyScopeGlobal])
    }

    static func measure(deviceID: AudioObjectID) throws -> LocalOutputLatencyMeasurement {
        let safetyOffset = try readUInt32(
            deviceID, selector: kAudioDevicePropertySafetyOffset,
            scopes: [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal])
        let deviceLatency = try readUInt32(
            deviceID, selector: kAudioDevicePropertyLatency,
            scopes: [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal])
        let bufferFrameSize = try readUInt32(
            deviceID, selector: kAudioDevicePropertyBufferFrameSize,
            scopes: [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal])
        let nominalSampleRate = try readDouble(
            deviceID, selector: kAudioDevicePropertyNominalSampleRate,
            scopes: [kAudioObjectPropertyScopeGlobal])
        let streamLatency = try readActiveOutputStreamLatency(deviceID)

        return LocalOutputLatencyMeasurement(
            safetyOffsetFrames: safetyOffset,
            deviceLatencyFrames: deviceLatency,
            streamLatencyFrames: streamLatency,
            bufferFrameSizeFrames: bufferFrameSize,
            nominalSampleRate: nominalSampleRate)
    }

    static func defaultOutputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            throw LocalOutputLatencyError.noDefaultOutputDevice(
                reason: "no default output device (\(err))")
        }
        return deviceID
    }

    private static func readActiveOutputStreamLatency(_ deviceID: AudioObjectID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard sizeErr == noErr, count > 0 else {
            throw LocalOutputLatencyError.noOutputStreams(reason: "no output streams (\(sizeErr))")
        }
        var streams = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams)
        guard err == noErr, let activeStream = streams.first else {
            throw LocalOutputLatencyError.noOutputStreams(reason: "read output streams failed (\(err))")
        }
        return try readUInt32(
            activeStream, selector: kAudioStreamPropertyLatency,
            scopes: [kAudioObjectPropertyScopeGlobal])
    }

    private static func readUInt32(
        _ objectID: AudioObjectID, selector: AudioObjectPropertySelector,
        scopes: [AudioObjectPropertyScope]
    ) throws -> UInt32 {
        var lastStatus: OSStatus = noErr
        for scope in scopes {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
            if err == noErr { return value }
            lastStatus = err
        }
        throw LocalOutputLatencyError.propertyReadFailed(
            selector: fourCC(selector), status: lastStatus)
    }

    private static func readDouble(
        _ objectID: AudioObjectID, selector: AudioObjectPropertySelector,
        scopes: [AudioObjectPropertyScope]
    ) throws -> Double {
        var lastStatus: OSStatus = noErr
        for scope in scopes {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
            if err == noErr { return value }
            lastStatus = err
        }
        throw LocalOutputLatencyError.propertyReadFailed(
            selector: fourCC(selector), status: lastStatus)
    }

    private static func fourCC(_ selector: AudioObjectPropertySelector) -> String {
        let bytes: [UInt8] = [
            UInt8((selector >> 24) & 0xff), UInt8((selector >> 16) & 0xff),
            UInt8((selector >> 8) & 0xff), UInt8(selector & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(selector)
    }
}

#else

public struct LocalOutputLatencyMeasurement: Equatable, Sendable {
    public let safetyOffsetFrames: UInt32 = 0
    public let deviceLatencyFrames: UInt32 = 0
    public let streamLatencyFrames: UInt32 = 0
    public let bufferFrameSizeFrames: UInt32 = 0
    public let nominalSampleRate: Double = 0
    public var totalFrames: UInt32 { 0 }
    public var totalSeconds: Double { 0 }
    public var totalMilliseconds: Double { 0 }
}

public enum LocalOutputLatencyError: Error, Equatable, Sendable {
    case unsupportedPlatform
}

public enum LocalOutputLatency {
    public static func measure() throws -> LocalOutputLatencyMeasurement {
        throw LocalOutputLatencyError.unsupportedPlatform
    }

    public static func defaultOutputDeviceNominalSampleRate() throws -> Double {
        throw LocalOutputLatencyError.unsupportedPlatform
    }
}

#endif
