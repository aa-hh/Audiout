// AirPlayEngine — public value types (T-API-1).
//
// These are the neutral, OwnTone-free Swift types the app (via NativeBackend,
// T-BACKEND-1) and the probe CLI use. They map onto the vendored C cluster's
// structs at the FFI boundary (see AirPlayEngine.swift) but never expose a C
// type in the public surface.
//
// SPEC.md §4: no OwnTone naming in any public symbol.

import Foundation

/// A stable identifier for a discovered/added output, echoing the AirPlay
/// device id (the 64-bit value parsed from the mDNS `deviceid` TXT key). The
/// app holds this opaque handle; the engine owns the underlying C device.
public struct OutputID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { String(format: "0x%016llX", rawValue) }
}

/// The address family of a resolved endpoint.
public enum AddressFamily: Sendable {
    case ipv4
    case ipv6
}

/// A resolved AirPlay receiver descriptor, produced by the app-side discovery
/// layer (an `NWBrowser` for `_airplay._tcp` — discovery is app-owned per the
/// RESOLVED Q5 decision) and fed to the engine via ``AirPlayEngine/addOutput(_:)``
/// or ``AirPlayEngine/updateDiscovery(_:)``.
///
/// The engine builds the vendored `output_device` from this by driving the
/// sender's own discovery callback (seam-map §4), so features/deviceid parsing,
/// the AP2 gate, and the reconnect/keep-alive heuristic all run in the vetted C
/// code rather than being reimplemented in Swift.
public struct DeviceDescriptor: Sendable {
    /// The mDNS service instance name — also the identity key used when the
    /// device disappears (removal matches on this name; seam-map §4).
    public var name: String
    /// The resolved host name (informational; the engine connects by `address`).
    public var hostname: String
    /// The resolved numeric IP address string (v4 or v6 per `family`).
    public var address: String
    /// Address family of `address`.
    public var family: AddressFamily
    /// The RTSP port advertised by the receiver.
    public var port: Int

    /// The raw DNS-SD TXT record key/value pairs. At minimum this must carry
    /// `deviceid` (colon-hex MAC form, e.g. `AA:BB:CC:DD:EE:FF`) and `features`
    /// (the AP2 feature bitmask string); `model` is used for the reconnect/
    /// keep-alive heuristic. The engine passes these verbatim into the sender's
    /// `keyval` so the vendored `features_parse`/`device_id_colon_parse` run.
    public var txtRecord: [String: String]

    public init(
        name: String,
        hostname: String = "",
        address: String,
        family: AddressFamily,
        port: Int,
        txtRecord: [String: String]
    ) {
        self.name = name
        self.hostname = hostname
        self.address = address
        self.family = family
        self.port = port
        self.txtRecord = txtRecord
    }

    /// The device id parsed from the `deviceid` TXT key, if present/valid.
    /// Convenience for the app to correlate a descriptor with an ``OutputID``.
    public var parsedID: OutputID? {
        guard let idStr = txtRecord["deviceid"] ?? txtRecord["DeviceID"] else { return nil }
        let hex = idStr.replacingOccurrences(of: ":", with: "")
        guard let value = UInt64(hex, radix: 16) else { return nil }
        return OutputID(rawValue: value)
    }
}

/// The lifecycle state of an output, mirroring the vendored
/// `enum output_device_state` (seam-map §2.1) but named neutrally.
public enum OutputState: Sendable, Equatable {
    case stopped
    case startup
    case connected
    case streaming
    case failed
    /// The receiver requires a password/PIN we don't have.
    case passwordRequired

    /// Terminal states an async op (`addOutput`) can resolve to. `startup`/
    /// `connected` are intermediate progress reports.
    var isTerminal: Bool {
        switch self {
        case .streaming, .stopped, .failed, .passwordRequired: return true
        case .startup, .connected: return false
        }
    }
}

/// Errors surfaced from the engine's async surface.
public enum AirPlayEngineError: Error, Sendable, Equatable {
    /// `start()`/init hasn't completed (or `stop()` already ran).
    case engineNotRunning
    /// The vendored `airplay_init` returned failure.
    case initFailed
    /// A device op returned "no callback promised" (N <= 0) unexpectedly, or the
    /// backend rejected the request outright.
    case operationRejected
    /// The session reached a terminal failure (`failed`).
    case sessionFailed
    /// The receiver requires a password/PIN (`passwordRequired`).
    case passwordRequired
    /// No output is registered for the given id.
    case unknownOutput(OutputID)
    /// The descriptor is missing a valid `deviceid` TXT key.
    case invalidDescriptor
    /// The engine thread's event base could not be created / dispatcher wiring failed.
    case engineThreadFailed
}

/// Audio format the engine's `write(pcm:)` expects: interleaved signed 16-bit
/// little-endian PCM. The AirPlay 2 sender is fixed at 44100 Hz / 16-bit / 2ch
/// (the ALAC frame is 352 samples; seam-map §5). Exposed as a constant so the
/// app can assert its capture pipeline matches.
public struct PCMFormat: Sendable, Equatable {
    public let sampleRate: Int
    public let bitsPerSample: Int
    public let channels: Int

    /// The one format the AirPlay 2 sender accepts (S16LE / 44100 / stereo).
    public static let airplay = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 2)
}
