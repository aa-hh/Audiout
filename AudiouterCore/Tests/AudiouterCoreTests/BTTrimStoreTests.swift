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
        let trims: [String: Double] = ["C4-38-75-0E-BF-4A:output": -120, "70-99-1C-51-8F-A8:output": 40]
        try store.save(trims)
        #expect(try store.load() == trims)
    }

    /// The store holds a raw `Double` — quantisation to whole ms happens above
    /// it, in the backend, before a write — so it must round-trip any value it
    /// is handed byte-for-byte, including a stale fractional one written by an
    /// older build (which the field's tolerant parse then snaps on next edit).
    @Test func roundTripSavesAndLoadsAnyValueExactly() throws {
        let store = store()
        let trims: [String: Double] = ["C4-38-75-0E-BF-4A:output": 24, "70-99-1C-51-8F-A8:output": -0.3]
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

    /// The no-migration claim in `BTTrimStore`'s doc comment: a hand-written
    /// v1 file whose values are bare JSON integers (what every file on disk
    /// looked like before this widening) must decode straight into `Double`s,
    /// with no schema bump and no crash.
    @Test func aV1FileWithIntegerValuesDecodesAsDoubles() throws {
        let url = scratchDir.appendingPathComponent("bt-sync-trims.json")
        let payload = #"{"schemaVersion": 1, "trims": {"a:output": 22, "b:output": -40}}"#
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try payload.data(using: .utf8)!.write(to: url)
        #expect(try store().load() == ["a:output": 22.0, "b:output": -40.0])
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

    // MARK: BTSyncTrim.quantise — whole-ms snap (BT-SYNC-DRAWER; decimals cut)

    @Test func quantiseSnapsToWholeMillisecondsRoundingHalfAwayFromZero() {
        #expect(BTSyncTrim.quantise(22.4) == 22)
        #expect(BTSyncTrim.quantise(22.5) == 23)
        #expect(BTSyncTrim.quantise(-22.5) == -23)
        #expect(BTSyncTrim.quantise(24) == 24)
    }

    @Test func quantiseClampsToTheRange() {
        #expect(BTSyncTrim.quantise(600) == 500)
        #expect(BTSyncTrim.quantise(-600) == -500)
    }

    /// Direction phrasing shared by the row chip and the drawer (D7 — never a
    /// bare signed number).
    @Test func spokenOffsetSpellsOutDirection() {
        #expect(BTSyncTrim.spokenOffset(24) == "24 milliseconds later")
        #expect(BTSyncTrim.spokenOffset(-24) == "24 milliseconds earlier")
        #expect(BTSyncTrim.spokenOffset(0) == "in sync")
    }
}
