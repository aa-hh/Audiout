import Foundation
import Testing
@testable import AudioutCore

/// Covers `DiagnosticsBundle` (PLAN-LIVE-DIAGNOSTICS.md C4). The defects
/// these catch: a bundle missing one of its entries so support reads half the
/// story, a zip that is not a zip, and — the one that matters — the licence
/// key, the companion token or the home directory path leaking into a file a
/// customer is told is safe to attach.
extension SerializedSharedState {
    @Suite final class DiagnosticsBundleTests: IsolatedSuite {

        private static let key = "AUDT-TEST0-KEY00-LEAK0-CHECK"
        private static let token = "eyJ0ZXN0LXRva2VuLWxlYWstY2hlY2sifQ"

        /// An `AppSettings` holding a key and a token, the two secrets the
        /// bundle must never carry, plus the fields it may.
        private func seededSettings() -> AppSettings {
            let settings = AppSettings(defaults: makeDefaults())
            settings.licenseKey = Self.key
            settings.companionToken = Self.token
            settings.licenseStatus = .active
            settings.telemetryOptIn = true
            return settings
        }

        private func seededSnapshot() -> DiagnosticsBundle.StateSnapshot {
            var device = Device(id: "54:2A:1B:79:08:9E", name: "Sonos Move", kind: .sonos)
            device.isSelected = true
            device.connectionState = .failed(ConnectionFailure(cause: .droppedMidStream))
            return DiagnosticsBundle.StateSnapshot(
                settings: seededSettings(), app: "Audiout", version: "1.0.0", build: "5",
                backend: "NativeBackend", ptpHelper: "enabled", devices: [device],
                audioDevices: [.init(name: "Audiout", transport: "virtual", sampleRate: 44100,
                                     isRunning: true, isDefaultOutput: true)])
        }

        private func seededDirectories() throws -> (logs: URL, stores: URL) {
            let logs = scratchDir.appendingPathComponent("Logs")
            let stores = scratchDir.appendingPathComponent("Stores")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stores, withIntermediateDirectories: true)
            try "{\"cat\":\"airplay\",\"evt\":\"airplay:session_failed\"}\n"
                .write(to: logs.appendingPathComponent(Telemetry.fileName), atomically: true, encoding: .utf8)
            try "2026-09-05T21:34:39.539Z [raop] TEARDOWN request failed\n"
                .write(to: logs.appendingPathComponent("engine.log"), atomically: true, encoding: .utf8)
            try "{\"schemaVersion\":1,\"state\":{\"selectedDeviceIDs\":[\"54:2A:1B:79:08:9E\"]}}"
                .write(to: stores.appendingPathComponent("routing.json"), atomically: true, encoding: .utf8)
            // Present on a real Mac, must NOT be copied: it names approved phones.
            try "{\"approved\":[\"phone-id\"]}"
                .write(to: stores.appendingPathComponent("companion-approvals.json"), atomically: true, encoding: .utf8)
            return (logs, stores)
        }

        @Test func stagedBundleHoldsEveryEntryAndNothingItMustNot() throws {
            let (logs, stores) = try seededDirectories()
            let staging = scratchDir.appendingPathComponent("staging")
            try DiagnosticsBundle.stage(into: staging, snapshot: seededSnapshot(),
                                        logsDirectory: logs, storesDirectory: stores,
                                        home: scratchDir.path)

            let entries = Set(try FileManager.default.contentsOfDirectory(atPath: staging.path))
            #expect(entries.isSuperset(of: ["snapshot.json", "telemetry.jsonl", "engine.log",
                                            "routing.json", "unified-log.txt", "crashes.txt"]),
                    "entries: \(entries.sorted())")
            #expect(!entries.contains("companion-approvals.json"), "approved phone ids stay on the Mac")

            let snapshot = try String(contentsOf: staging.appendingPathComponent("snapshot.json"), encoding: .utf8)
            #expect(snapshot.contains("\"licenseStatus\" : \"active\""))
            #expect(snapshot.contains("Sonos Move"), "names stay in cleartext by design")
            #expect(snapshot.contains("droppedMidStream"))

            for entry in entries {
                let text = try String(contentsOf: staging.appendingPathComponent(entry), encoding: .utf8)
                #expect(!text.contains(Self.key), "\(entry) carries the licence key")
                #expect(!text.contains(Self.token), "\(entry) carries the companion token")
                #expect(!text.contains(scratchDir.path), "\(entry) carries the home directory path")
            }
        }

        @Test func writeProducesAZipAtTheChosenPath() throws {
            let (logs, stores) = try seededDirectories()
            let destination = scratchDir.appendingPathComponent("Audiout-diagnostics-test.zip")
            let written = try DiagnosticsBundle.write(to: destination, snapshot: seededSnapshot(),
                                                      logsDirectory: logs, storesDirectory: stores,
                                                      home: scratchDir.path)
            #expect(written == destination)
            let head = try Data(contentsOf: destination).prefix(2)
            #expect(head == Data([0x50, 0x4B]), "a zip starts with PK")
        }

        @Test func homePathIsRedactedInGeneratedText() {
            let home = "/Users/someone"
            let text = DiagnosticsBundle.redacted("saved at \(home)/Library/Logs/Audiout/x.log", home: home)
            #expect(text == "saved at ~/Library/Logs/Audiout/x.log")
        }
    }
}
