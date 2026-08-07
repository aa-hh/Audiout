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

    /// BT-SYNC-DRAWER T1: the whole point of the `Int` → `Double` widening —
    /// a fractional trim must survive the round trip exactly, not just a
    /// whole-ms one.
    @Test func roundTripSavesAndLoadsAFractionalTrimExactly() throws {
        let store = store()
        let trims: [String: Double] = ["C4-38-75-0E-BF-4A:output": 22.4, "70-99-1C-51-8F-A8:output": -0.3]
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

    // MARK: BTSyncTrim.quantise — the ruler's 0.1 ms snap (BT-SYNC-DRAWER T1)

    @Test func quantiseSnapsToOneDecimalPlaceRoundingHalfAwayFromZero() {
        #expect(BTSyncTrim.quantise(22.44) == 22.4)
        #expect(BTSyncTrim.quantise(22.45) == 22.5)
        #expect(BTSyncTrim.quantise(-22.45) == -22.5)
    }

    @Test func quantiseClampsToTheRange() {
        #expect(BTSyncTrim.quantise(600) == 500)
        #expect(BTSyncTrim.quantise(-600) == -500)
    }

    /// The dust-free requirement: two inputs that are decimal-equal but
    /// bit-different going in (a classic binary-float artifact) must land on
    /// the exact same `Double` coming out — not merely an equal-looking one.
    @Test func quantiseOutputIsFreeOfBinaryFloatDust() {
        let fromMultiplication = BTSyncTrim.quantise(0.1 * 3)
        let fromLiteral = BTSyncTrim.quantise(0.3)
        #expect(fromMultiplication.bitPattern == fromLiteral.bitPattern)
    }
}
