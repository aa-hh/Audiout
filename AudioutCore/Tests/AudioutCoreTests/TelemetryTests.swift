import Foundation
import Testing
@testable import AudioutCore

/// Covers `Telemetry` (`Sources/AudioutCore/Telemetry.swift`, T1): line
/// format/required fields, rotation/size-bound, `HeadlessRuntime`
/// neutralization (the single most important property — an always-on-by-
/// default logger must never pollute or race the real suite), concurrent-
/// write safety, and fail-safe behavior on a write error.
///
/// Subclasses `IsolatedSuite` and uses `scratchDir` for every real write —
/// this suite is the ONE place allowed to re-arm `Telemetry` via
/// `_resetForTesting`/`_installTestSink`; every other suite must see it stay
/// neutralized by default. Nested under `SerializedSharedState` because
/// `_installTestSink`/`_resetForTesting` mutate process-global state that
/// would otherwise race any other test in this file's parent suite running
/// concurrently (cookbook §18).
extension SerializedSharedState {
    @Suite final class TelemetryTests: IsolatedSuite {

        deinit {
            // Release Telemetry's grip on `scratchDir` (and drop any installed
            // sink / cap override) BEFORE IsolatedSuite's own cleanup removes
            // the directory, and before the next test runs. Swift runs a
            // subclass's deinit before its superclass's, so this fires ahead
            // of `TestIsolation`'s directory removal for free.
            Telemetry._installTestSink(nil)
            Telemetry.testPerFileCapBytesOverride = nil
            Telemetry._resetForTesting(directory: nil)
        }

        // MARK: - Line format

        @Test func logWritesValidJSONWithRequiredFields() throws {
            Telemetry._resetForTesting(directory: scratchDir)
            Telemetry.log(.airplay, "test_event", ["device": "Kitchen", "gen": "3"])
            drain()

            let lines = try readLines()
            #expect(lines.count >= 2, "expected at least the session banner + our line")
            for line in lines {
                let obj = try parseJSONObject(line)
                #expect(obj["ts"] as? String != nil, "every line needs ts: \(line)")
                #expect(obj["sid"] as? String != nil, "every line needs sid: \(line)")
                #expect(obj["cat"] as? String != nil, "every line needs cat: \(line)")
                #expect(obj["evt"] as? String != nil, "every line needs evt: \(line)")
            }
            let last = try parseJSONObject(lines.last!)
            #expect(last["cat"] as? String == "airplay")
            #expect(last["evt"] as? String == "test_event")
            #expect(last["level"] as? String == "info", "a plain log line must not read as a failure")
            #expect(last["device"] as? String == "Kitchen")
            #expect(last["gen"] as? String == "3")
        }

        /// The defect this catches: a `local` field (a device id, an error
        /// description) reaching the analytics sink, or a failure line written
        /// at `info` so a reader grepping `level":"error` misses it.
        @Test func failWritesErrorLineAndForwardsOnlySharedFields() throws {
            let forwarded = Locked([(String, [String: String])]())
            Analytics.install(Analytics.Sink(capture: { _, _ in },
                                             captureError: { name, props in forwarded.append((name, props)) },
                                             consentChanged: { _ in }), consent: true)
            defer { Analytics.install(nil, consent: false) }
            let capturedBox = Locked([String]())
            Telemetry._installTestSink { line in capturedBox.append(line) }

            Telemetry.fail(.airplay, "airplay:session_failed",
                           local: ["device": "54:2A:1B:79:08:9E"],
                           shared: ["cause": "droppedMidStream"])
            drain()

            let line = try #require(capturedBox.snapshot().last { $0.contains("airplay:session_failed") })
            let obj = try parseJSONObject(line)
            #expect(obj["level"] as? String == "error")
            #expect(obj["device"] as? String == "54:2A:1B:79:08:9E", "the local line keeps the device id")
            #expect(obj["cause"] as? String == "droppedMidStream")

            let sent = forwarded.snapshot()
            #expect(sent.count == 1)
            #expect(sent.first?.0 == "airplay:session_failed")
            #expect(sent.first?.1 == ["cause": "droppedMidStream"], "only `shared` may leave the Mac")
        }

        @Test func fieldsWithSpecialCharactersAreEscapedAndRoundTrip() throws {
            Telemetry._resetForTesting(directory: scratchDir)
            let tricky = "Kitchen \"HomePod\" \\ line1\nline2\tend \u{1F600}"
            Telemetry.log(.airplay, "weird_name", ["device": tricky])
            drain()

            let lines = try readLines()
            let match = lines.compactMap { try? parseJSONObject($0) }
                .first { ($0["evt"] as? String) == "weird_name" }
            let obj = try #require(match, "expected the weird_name line to be present and parse as JSON")
            #expect(obj["device"] as? String == tricky)
        }

        @Test func bannerIsFirstLineOfEachSession() throws {
            Telemetry._resetForTesting(directory: scratchDir)
            Telemetry.log(.permission, "gate_check", [:])
            drain()

            let lines = try readLines()
            let first = try parseJSONObject(lines[0])
            #expect(first["cat"] as? String == "lifecycle")
            #expect(first["evt"] as? String == "session_start")
            // Same session id threads through both lines.
            let second = try parseJSONObject(lines[1])
            #expect(first["sid"] as? String == second["sid"] as? String)
        }

        // MARK: - Rotation / size-bound

        @Test func rotationBoundsTotalSizeAndRetainsNewestData() throws {
            Telemetry.testPerFileCapBytesOverride = 2048
            Telemetry._resetForTesting(directory: scratchDir)
            for i in 0..<400 {
                Telemetry.log(.captureWS, "transition", ["i": "\(i)"])
            }
            drain()

            let activeURL = scratchDir.appendingPathComponent(Telemetry.fileName)
            let backupURL = scratchDir.appendingPathComponent(Telemetry.rotatedFileName)
            let activeSize = fileSize(activeURL)
            let backupSize = fileSize(backupURL)

            #expect(backupSize > 0, "400 lines at a 2 KB cap must have rotated at least once")
            #expect(activeSize <= 2048, "active file must never exceed the per-file cap")
            #expect(backupSize <= 2048, "backup file must never exceed the per-file cap")
            #expect(activeSize + backupSize <= 2 * 2048,
                                      "total footprint across both files must stay near the target")

            let activeContent = (try? String(contentsOf: activeURL, encoding: .utf8)) ?? ""
            #expect(activeContent.contains("\"i\":\"399\""), "the newest write must be retained")
            #expect(!activeContent.contains("\"i\":\"0\""), "the oldest write must have scrolled off the active file")
            let backupContent = (try? String(contentsOf: backupURL, encoding: .utf8)) ?? ""
            #expect(!backupContent.contains("\"i\":\"0\""), "the oldest write must have scrolled off the backup too")
        }

        // MARK: - HeadlessRuntime neutralization

        @Test func defaultUnderXCTestNeverTouchesProductionPath() {
            #expect(HeadlessRuntime.isActive, "sanity: this test runs under XCTest")
            #expect(!Telemetry.isEnabled, "must be neutralized by default under HeadlessRuntime")

            // Compare before/after rather than asserting non-existence outright —
            // a real (non-test) launch of the app on this same machine may have
            // already created this file at some point; the property under test is
            // "this run doesn't touch it," not "it has never existed."
            let prodFile = Telemetry.defaultDirectory.appendingPathComponent(Telemetry.fileName)
            let before = fileSize(prodFile)

            Telemetry.log(.lifecycle, "should_never_reach_disk", [:])
            drain()

            #expect(fileSize(prodFile) == before, "the production path must be untouched while neutralized")
        }

        @Test func explicitResetWritesOnlyToInjectedDirectory() throws {
            let prodFile = Telemetry.defaultDirectory.appendingPathComponent(Telemetry.fileName)
            let prodSizeBefore = fileSize(prodFile)

            Telemetry._resetForTesting(directory: scratchDir)
            Telemetry.log(.lifecycle, "test", [:])
            drain()

            let ourFile = scratchDir.appendingPathComponent(Telemetry.fileName)
            #expect(FileManager.default.fileExists(atPath: ourFile.path),
                          "an explicit _resetForTesting(directory:) must write to the injected directory")
            #expect(fileSize(prodFile) == prodSizeBefore,
                           "the production path must stay untouched even while a test session is active")
        }

        // MARK: - Concurrency

        @Test func concurrentLogCallsNeverCrashOrCorruptLines() throws {
            Telemetry._resetForTesting(directory: scratchDir)
            let iterations = 200
            DispatchQueue.concurrentPerform(iterations: iterations) { i in
                Telemetry.log(.capturePA, "concurrent", ["i": "\(i)"])
            }
            drain()

            let lines = try readLines()
            #expect(lines.count == iterations + 1, "banner + one line per concurrent call, none dropped or merged")

            var seen = Set<Int>()
            for line in lines {
                // Throws (failing the test) if any line is not valid, complete
                // JSON — the direct check for "no interleaved/partial line".
                let obj = try parseJSONObject(line)
                if let iStr = obj["i"] as? String, let i = Int(iStr) {
                    seen.insert(i)
                }
            }
            #expect(seen.count == iterations, "every concurrent write must be intact and present exactly once")
        }

        // MARK: - Test sink

        @Test func installTestSinkCapturesWithoutTouchingDisk() {
            let prodFile = Telemetry.defaultDirectory.appendingPathComponent(Telemetry.fileName)
            let prodSizeBefore = fileSize(prodFile)

            let capturedBox = Locked([String]())
            Telemetry._installTestSink { line in capturedBox.append(line) }
            Telemetry.log(.permission, "gate_check", ["granted": "false"])
            drain()

            #expect(capturedBox.snapshot().count >= 1)
            #expect(capturedBox.snapshot().contains { $0.contains("gate_check") })
            #expect(fileSize(prodFile) == prodSizeBefore, "a sink-only session must never touch the filesystem")
        }

        // MARK: - Fail-safe

        @Test func writeErrorFailsSafeAndWriterRecovers() throws {
            Telemetry._resetForTesting(directory: scratchDir)
            let activeURL = scratchDir.appendingPathComponent(Telemetry.fileName)
            FileManager.default.createFile(atPath: activeURL.path, contents: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: activeURL.path)

            // Must not throw / crash even though the active file is read-only.
            Telemetry.log(.lifecycle, "should_not_crash", [:])
            drain()

            // Restore permissions and prove the writer isn't permanently wedged —
            // it reopens fresh on every call, so recovery needs no special reset.
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: activeURL.path)
            Telemetry.log(.lifecycle, "recovered", [:])
            drain()

            let content = (try? String(contentsOf: activeURL, encoding: .utf8)) ?? ""
            #expect(content.contains("recovered"), "the writer must self-heal once the file is writable again")
        }

        // MARK: - Helpers

        /// A synchronous round-trip through `Telemetry`'s internal writer queue.
        /// `_installTestSink(nil)` is documented to act as a flush barrier
        /// (serial/FIFO queue), so this reliably waits for every write enqueued
        /// so far without depending on sleeps or polling.
        private func drain() {
            Telemetry._installTestSink(nil)
        }

        private func readLines() throws -> [String] {
            let url = scratchDir.appendingPathComponent(Telemetry.fileName)
            let content = try String(contentsOf: url, encoding: .utf8)
            return content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }

        private func parseJSONObject(_ line: String) throws -> [String: Any] {
            let data = Data(line.utf8)
            let obj = try JSONSerialization.jsonObject(with: data)
            return try #require(obj as? [String: Any], "not a JSON object: \(line)")
        }

        private func fileSize(_ url: URL) -> Int {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
            return (attrs[.size] as? Int) ?? 0
        }

        /// Minimal thread-safe box for the sink test — the sink itself is called
        /// from Telemetry's serial writer queue (a different thread than the
        /// test body), so appending straight into a plain `[String]` here would
        /// race the read below.
        private final class Locked<Value>: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Value
            init(_ value: Value) { self.value = value }
            func append<Element>(_ element: Element) where Value == [Element] {
                lock.lock(); value.append(element); lock.unlock()
            }
            func snapshot() -> Value {
                lock.lock(); defer { lock.unlock() }
                return value
            }
        }
    }
}
