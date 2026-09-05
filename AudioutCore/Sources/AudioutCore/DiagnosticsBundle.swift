// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import CoreAudio
import OSLog

/// One zip a customer can attach to a support email, built from what is
/// already on this Mac: the decision log and the sender's log, a snapshot of
/// the app's state, the process's own tail of the unified log, and the names
/// of recent crash reports (docs/plans/PLAN-LIVE-DIAGNOSTICS.md C4).
///
/// The interface is one call, ``write(to:snapshot:)``. Settings › About is its
/// first caller.
///
/// What may go in is decided here, once. Speaker and app names stay in
/// cleartext: the user chooses to send this file, and names are what make a
/// failure legible. The licence key, the companion token and any path under
/// the home directory never go in — ``StateSnapshot`` is built from typed fields,
/// not by dumping stores, and every text file this type writes has the home
/// directory replaced with `~`.
public enum DiagnosticsBundle {

    /// The store files copied verbatim. `companion-approvals.json` is left
    /// out on purpose: it holds the ids of approved phones.
    public static let storeFileNames = [
        "routing.json", "groups.json", "device-eq.json",
        "bt-sync-trims.json", "app-routes.json", "device-icons.json",
    ]

    /// Copied from the logs directory when present.
    public static let logFileNames = [
        Telemetry.fileName, Telemetry.rotatedFileName, "engine.log", "engine.log.1",
    ]

    public struct DeviceLine: Encodable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var kind: String
        public var isSelected: Bool
        public var isAvailable: Bool
        public var connectionState: String
        public var volume: Int
        public var isMuted: Bool

        public init(_ device: Device) {
            id = device.id
            name = device.name
            kind = "\(device.kind)"
            isSelected = device.isSelected
            isAvailable = device.isAvailable
            connectionState = "\(device.connectionState)"
            volume = device.volume
            isMuted = device.isMuted
        }
    }

    public struct AudioDeviceLine: Encodable, Equatable, Sendable {
        public var name: String
        public var transport: String
        public var sampleRate: Double
        public var isRunning: Bool
        public var isDefaultOutput: Bool
    }

    public struct StateSnapshot: Encodable, Sendable {
        public var app: String
        public var version: String
        public var build: String
        public var macOS: String
        public var backend: String
        public var analyticsConsent: Bool
        public var installID: String
        /// The coarse state only, never the key.
        public var licenseStatus: String?
        public var ptpHelper: String
        public var devices: [DeviceLine]
        public var audioDevices: [AudioDeviceLine]

        /// Reads the coarse fields from `settings` and leaves the rest to the
        /// caller. `settings` is the one place the licence key and the
        /// companion token live; only `licenseStatus` and `installID` are read
        /// from it, which is what the bundle test pins.
        public init(settings: AppSettings, app: String, version: String, build: String,
                    backend: String, ptpHelper: String, devices: [Device],
                    audioDevices: [AudioDeviceLine] = currentAudioDevices()) {
            self.app = app
            self.version = version
            self.build = build
            self.macOS = ProcessInfo.processInfo.operatingSystemVersionString
            self.backend = backend
            self.analyticsConsent = settings.telemetryOptIn
            self.installID = settings.installID
            self.licenseStatus = settings.licenseStatus?.rawValue
            self.ptpHelper = ptpHelper
            self.devices = devices.map(DeviceLine.init)
            self.audioDevices = audioDevices
        }
    }

    /// Writes the zip at `destination` (any `.zip` path the caller chose) and
    /// returns it. Builds the contents in a temporary directory, then asks
    /// Foundation for the archive (`NSFileCoordinator`'s upload form, which
    /// is a zip). Throws when the archive cannot be produced; a missing log
    /// or store file is not an error, it is simply absent.
    @discardableResult
    public static func write(to destination: URL, snapshot: StateSnapshot,
                             logsDirectory: URL = Telemetry.defaultDirectory,
                             storesDirectory: URL = GroupStore.defaultDirectory,
                             home: String = NSHomeDirectory()) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("Audiout-diagnostics-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try stage(into: staging, snapshot: snapshot, logsDirectory: logsDirectory,
                  storesDirectory: storesDirectory, home: home)

        try? fm.removeItem(at: destination)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading,
                                       error: &coordinatorError) { zipURL in
            do { try fm.copyItem(at: zipURL, to: destination) } catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return destination
    }

    /// Lays the bundle's files out in `directory`: `snapshot.json`, the log
    /// and store copies that exist, `unified-log.txt`, `crashes.txt`. Public
    /// so the test can inspect the entries without unzipping.
    public static func stage(into directory: URL, snapshot: StateSnapshot,
                             logsDirectory: URL, storesDirectory: URL, home: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: directory.appendingPathComponent("snapshot.json"))

        for (source, names) in [(logsDirectory, logFileNames), (storesDirectory, storeFileNames)] {
            for name in names {
                let from = source.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                try? fm.copyItem(at: from, to: directory.appendingPathComponent(name))
            }
        }

        try redacted(unifiedLogTail(), home: home)
            .write(to: directory.appendingPathComponent("unified-log.txt"), atomically: true, encoding: .utf8)
        try redacted(crashReportNames(home: home), home: home)
            .write(to: directory.appendingPathComponent("crashes.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Sources

    /// The last 500 entries the unified log kept for this process, over the
    /// past hour. On 2026-09-05 this came back empty for a whole session; the
    /// bundle still asks, and says so when it gets nothing.
    static func unifiedLogTail() -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-3600))
            let entries = try store.getEntries(at: position)
            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries {
                lines.append("\(entry.date) [\(entry.subsystem):\(entry.category)] \(entry.composedMessage)")
            }
            if lines.isEmpty { return "(the unified log kept nothing from this process in the last hour)\n" }
            return lines.suffix(500).joined(separator: "\n") + "\n"
        } catch {
            return "(unified log unavailable: \(error))\n"
        }
    }

    /// Names only, newest five. The reports themselves stay on the Mac.
    static func crashReportNames(home: String) -> String {
        let reports = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/DiagnosticReports")
        let names = ((try? FileManager.default.contentsOfDirectory(
            at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Audiout") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .prefix(5)
            .map(\.lastPathComponent)
        return names.isEmpty ? "(no crash reports named Audiout)\n" : names.joined(separator: "\n") + "\n"
    }

    static func redacted(_ text: String, home: String) -> String {
        home.isEmpty ? text : text.replacingOccurrences(of: home, with: "~")
    }

    /// Every audio device CoreAudio lists, with the facts that decided the
    /// 2026-09-05 case: transport, rate, whether it is running, and which one
    /// is the default output.
    public static func currentAudioDevices() -> [AudioDeviceLine] {
        func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ fallback: T) -> T {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value = fallback
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : fallback
        }
        func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
                  let s = value?.takeRetainedValue() else { return "?" }
            return s as String
        }
        func transportName(_ raw: UInt32) -> String {
            switch raw {
            case kAudioDeviceTransportTypeBuiltIn: return "builtIn"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
            case kAudioDeviceTransportTypeUSB: return "usb"
            case kAudioDeviceTransportTypeAirPlay: return "airplay"
            case kAudioDeviceTransportTypeVirtual: return "virtual"
            case kAudioDeviceTransportTypeAggregate: return "aggregate"
            default: return String(format: "0x%08x", raw)
            }
        }

        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let defaultOutput = property(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))

        return ids.map { id in
            AudioDeviceLine(
                name: string(id, kAudioObjectPropertyName),
                transport: transportName(property(id, kAudioDevicePropertyTransportType, UInt32(0))),
                sampleRate: property(id, kAudioDevicePropertyNominalSampleRate, Float64(0)),
                isRunning: property(id, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) != 0,
                isDefaultOutput: id == defaultOutput)
        }
    }
}
