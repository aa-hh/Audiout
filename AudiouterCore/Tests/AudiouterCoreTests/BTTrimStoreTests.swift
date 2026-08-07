// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `BTTrimStore` (BT-OFFSET-UI persistence) + the shared `BTSyncTrim` numeric
/// contract. Mirrors `DeviceIconStoreTests`' shape: throwaway temp directory,
/// never the real Application Support.
@Suite final class BTTrimStoreTests: IsolatedSuite {

    private func store() -> BTTrimStore {
        BTTrimStore(directory: scratchDir)
    }

    @Test func roundTripSavesAndLoadsTrimsByUID() throws {
        let store = store()
        let trims = ["C4-38-75-0E-BF-4A:output": -120, "70-99-1C-51-8F-A8:output": 40]
        try store.save(trims)
        #expect(try store.load() == trims)
    }

    @Test func missingFileLoadsAsNil() throws {
        #expect(try store().load() == nil)
    }

    @Test func newerSchemaReadsAsMissingNotACrash() throws {
        let url = scratchDir.appendingPathComponent("bt-sync-trims.json")
        let payload = #"{"schemaVersion": 99, "trims": {"x": 1}}"#
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try payload.data(using: .utf8)!.write(to: url)
        #expect(try store().load() == nil)
    }

    @Test func overwriteReplacesThePayload() throws {
        let store = store()
        try store.save(["a:output": 10])
        try store.save(["b:output": -20])
        #expect(try store.load() == ["b:output": -20])
    }

    // MARK: BTSyncTrim — the one clamp/step contract UI and backend share

    @Test func clampBoundsTheTrimToPlusMinusRange() {
        #expect(BTSyncTrim.rangeMs == 500)
        #expect(BTSyncTrim.coarseStepMs == 10)
        #expect(BTSyncTrim.clamp(620) == 500)
        #expect(BTSyncTrim.clamp(-620) == -500)
        #expect(BTSyncTrim.clamp(499) == 499)
        #expect(BTSyncTrim.clamp(-1) == -1)
        #expect(BTSyncTrim.clamp(0) == 0)
    }
}
