// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `DeviceIconStore` persistence — mirrors `AppRouteStoreTests`/`ExcludedAppsTests`:
/// a throwaway temp directory, round-trip (including the empty-map edge case),
/// missing-file behaviour, and that the directory is genuinely injectable
/// rather than hardcoded to the real Application Support path.
@Suite final class DeviceIconStoreTests {

    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func missingFileLoadsNil() throws {
        let store = DeviceIconStore(directory: directory)
        #expect(try store.load() == nil, "first run — no file on disk yet")
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = DeviceIconStore(directory: directory)
        let icons = [
            "homepod-1": "hifispeaker.2.fill",
            "office": "airpodspro",
        ]
        try store.save(icons)
        #expect(try store.load() == icons)
    }

    @Test func savingEmptyMapRoundTripsAsEmptyNotMissing() throws {
        let store = DeviceIconStore(directory: directory)
        try store.save([:])
        // An explicitly-saved empty map is a real file on disk, distinct from
        // "never saved" — both happen to read back as an empty dictionary,
        // but only the former actually wrote a file.
        #expect(try store.load() == [:])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("device-icons.json").path))
    }

    @Test func newerSchemaLoadsNilRatherThanCrashing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = #"{"schemaVersion": 99, "icons": {"a": "b"}}"#
        try Data(future.utf8).write(to: directory.appendingPathComponent("device-icons.json"))
        #expect(try DeviceIconStore(directory: directory).load() == nil,
                     "a future schema version must not crash an old build")
    }

    @Test func directoryIsInjectedNotHardcoded() throws {
        // Two independently-constructed stores pointed at different temp
        // directories must never see each other's data — proves `directory:`
        // actually drives the file location rather than always falling back
        // to the real Application Support path.
        let otherDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherDirectory) }

        let storeA = DeviceIconStore(directory: directory)
        let storeB = DeviceIconStore(directory: otherDirectory)

        try storeA.save(["device-a": "airpods"])
        #expect(try storeB.load() == nil, "storeB's directory must still be empty")

        try storeB.save(["device-b": "headphones"])
        #expect(try storeA.load() == ["device-a": "airpods"], "storeA's file must be untouched")

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("device-icons.json").path))
        #expect(FileManager.default.fileExists(atPath: otherDirectory.appendingPathComponent("device-icons.json").path))
    }
}
