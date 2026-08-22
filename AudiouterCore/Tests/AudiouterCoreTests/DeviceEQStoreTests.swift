// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `DeviceEQStore` persistence — mirrors `DeviceIconStoreTests`: an isolated
/// scratch directory, round-trip of both envelope halves, the flat-entries-are-
/// dropped rule, missing/newer-schema behaviour, and that the directory is
/// genuinely injectable rather than hardcoded to real Application Support.
@Suite final class DeviceEQStoreTests: IsolatedSuite {

    private var fileURL: URL { scratchDir.appendingPathComponent("device-eq.json") }

    @Test func missingFileLoadsNil() throws {
        #expect(try DeviceEQStore(directory: scratchDir).load() == nil, "first run — no file yet")
    }

    @Test func devicesRoundTrip() throws {
        let store = DeviceEQStore(directory: scratchDir)
        let devices = [
            "office": DeviceEQ(bassDB: 4, balance: -0.5),
            "kitchen": DeviceEQ(loudness: true, bandGainsDB: [0, 0, 3, 0, 0, 0, 0, -2, 0, 0]),
        ]
        try store.save(mainOut: nil, devices: devices)
        #expect(try store.load()?.devices == devices)
    }

    @Test func mainOutSlotRoundTripsIndependentlyOfDevices() throws {
        let store = DeviceEQStore(directory: scratchDir)
        let mainOut = DeviceEQ(trebleDB: -6)
        try store.save(mainOut: mainOut, devices: [:])
        let loaded = try store.load()
        #expect(loaded?.mainOut == mainOut)
        #expect(loaded?.devices.isEmpty == true)
    }

    @Test func flatEntriesAreDroppedRatherThanStored() throws {
        let store = DeviceEQStore(directory: scratchDir)
        try store.save(mainOut: .flat, devices: ["office": .flat, "kitchen": DeviceEQ(bassDB: 2)])
        let loaded = try store.load()
        #expect(loaded?.mainOut == nil, "a neutral Main Out is not a setting worth keeping")
        #expect(loaded?.devices.keys.sorted() == ["kitchen"])
    }

    @Test func savingNothingStillWritesARealFile() throws {
        let store = DeviceEQStore(directory: scratchDir)
        try store.save(mainOut: nil, devices: [:])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let loaded = try store.load()
        #expect(loaded?.mainOut == nil)
        #expect(loaded?.devices.isEmpty == true)
    }

    @Test func newerSchemaLoadsNilRatherThanCrashing() throws {
        let future = #"{"schemaVersion": 99, "devices": {"office": {"bassDB": 3}}}"#
        try Data(future.utf8).write(to: fileURL)
        #expect(try DeviceEQStore(directory: scratchDir).load() == nil,
                "a future schema version must not crash an old build")
    }

    @Test func outOfRangeValuesOnDiskAreClampedOnLoad() throws {
        let hostile = #"{"schemaVersion": 1, "devices": {"office": {"bassDB": 400, "bandGainsDB": [99]}}}"#
        try Data(hostile.utf8).write(to: fileURL)
        let loaded = try DeviceEQStore(directory: scratchDir).load()
        #expect(loaded?.devices["office"]?.bassDB == 12)
        #expect(loaded?.devices["office"]?.bandGainsDB.count == DeviceEQ.bandCount)
    }

    @Test func directoryIsInjectedNotHardcoded() throws {
        let otherDirectory = scratchDir.appendingPathComponent("other", isDirectory: true)
        let storeA = DeviceEQStore(directory: scratchDir)
        let storeB = DeviceEQStore(directory: otherDirectory)

        try storeA.save(mainOut: nil, devices: ["office": DeviceEQ(bassDB: 1)])
        #expect(try storeB.load() == nil, "storeB's directory must still be empty")

        try storeB.save(mainOut: nil, devices: ["kitchen": DeviceEQ(bassDB: 2)])
        #expect(try storeA.load()?.devices.keys.sorted() == ["office"], "storeA's file must be untouched")
    }
}
