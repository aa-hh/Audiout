// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudioutedCore

/// `DeviceIconStore` persistence — mirrors `AppRouteStoreTests`/`ExcludedAppsTests`:
/// a throwaway temp directory, round-trip (including the empty-map edge case),
/// missing-file behaviour, and that the directory is genuinely injectable
/// rather than hardcoded to the real Application Support path.
final class DeviceIconStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutedTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    func testMissingFileLoadsNil() throws {
        let store = DeviceIconStore(directory: directory)
        XCTAssertNil(try store.load(), "first run — no file on disk yet")
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = DeviceIconStore(directory: directory)
        let icons = [
            "homepod-1": "hifispeaker.2.fill",
            "office": "airpodspro",
        ]
        try store.save(icons)
        XCTAssertEqual(try store.load(), icons)
    }

    func testSavingEmptyMapRoundTripsAsEmptyNotMissing() throws {
        let store = DeviceIconStore(directory: directory)
        try store.save([:])
        // An explicitly-saved empty map is a real file on disk, distinct from
        // "never saved" — both happen to read back as an empty dictionary,
        // but only the former actually wrote a file.
        XCTAssertEqual(try store.load(), [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("device-icons.json").path))
    }

    func testNewerSchemaLoadsNilRatherThanCrashing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = #"{"schemaVersion": 99, "icons": {"a": "b"}}"#
        try Data(future.utf8).write(to: directory.appendingPathComponent("device-icons.json"))
        XCTAssertNil(try DeviceIconStore(directory: directory).load(),
                     "a future schema version must not crash an old build")
    }

    func testDirectoryIsInjectedNotHardcoded() throws {
        // Two independently-constructed stores pointed at different temp
        // directories must never see each other's data — proves `directory:`
        // actually drives the file location rather than always falling back
        // to the real Application Support path.
        let otherDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherDirectory) }

        let storeA = DeviceIconStore(directory: directory)
        let storeB = DeviceIconStore(directory: otherDirectory)

        try storeA.save(["device-a": "airpods"])
        XCTAssertNil(try storeB.load(), "storeB's directory must still be empty")

        try storeB.save(["device-b": "headphones"])
        XCTAssertEqual(try storeA.load(), ["device-a": "airpods"], "storeA's file must be untouched")

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("device-icons.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherDirectory.appendingPathComponent("device-icons.json").path))
    }
}
