// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `HiddenSpeakersStore` persistence — mirrors `DeviceIconStoreTests`: a
/// throwaway temp directory, round-trip (including the empty-set edge case),
/// missing-file behaviour, a future schema version, and that the directory is
/// genuinely injectable rather than hardcoded to the real Application Support
/// path.
@Suite final class HiddenSpeakersStoreTests {

    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func missingFileLoadsNil() throws {
        let store = HiddenSpeakersStore(directory: directory)
        #expect(try store.load() == nil, "first run — nothing hidden yet")
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = HiddenSpeakersStore(directory: directory)
        let hidden: Set<String> = ["bt-old-headphones", "bt-car-stereo"]
        try store.save(hidden)
        #expect(try store.load() == hidden)
    }

    @Test func savingEmptySetRoundTripsAsEmptyNotMissing() throws {
        let store = HiddenSpeakersStore(directory: directory)
        try store.save([])
        // Unhiding the last speaker writes a real file, distinct from "never
        // saved" — both read back as an empty set, but only this one is on disk.
        #expect(try store.load() == [])
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("hidden-speakers.json").path))
    }

    @Test func newerSchemaLoadsNilRatherThanCrashing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = #"{"schemaVersion": 99, "hiddenDeviceIDs": ["a"]}"#
        try Data(future.utf8).write(to: directory.appendingPathComponent("hidden-speakers.json"))
        #expect(try HiddenSpeakersStore(directory: directory).load() == nil,
                "a future schema version must not crash an old build")
    }

    @Test func idsArePersistedSortedSoAnUnchangedSetIsAnUnchangedFile() throws {
        let store = HiddenSpeakersStore(directory: directory)
        try store.save(["patio", "attic", "kitchen"])
        let first = try Data(contentsOf: directory.appendingPathComponent("hidden-speakers.json"))
        // A `Set`'s iteration order varies per process; the file must not.
        try store.save(["kitchen", "patio", "attic"])
        let second = try Data(contentsOf: directory.appendingPathComponent("hidden-speakers.json"))
        #expect(first == second)
    }

    @Test func directoryIsInjectedNotHardcoded() throws {
        // Two independently-constructed stores pointed at different temp
        // directories must never see each other's data — proves `directory:`
        // actually drives the file location rather than always falling back
        // to the real Application Support path.
        let otherDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherDirectory) }

        let storeA = HiddenSpeakersStore(directory: directory)
        let storeB = HiddenSpeakersStore(directory: otherDirectory)

        try storeA.save(["device-a"])
        #expect(try storeB.load() == nil, "storeB's directory must still be empty")

        try storeB.save(["device-b"])
        #expect(try storeA.load() == ["device-a"], "storeA's file must be untouched")
    }
}
