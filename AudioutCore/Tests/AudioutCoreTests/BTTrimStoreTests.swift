// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

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

    // MARK: Measured latencies (roadmap 056 Part A — the wizard's own map)

    @Test func roundTripSavesAndLoadsMeasuredLatencies() throws {
        let store = store()
        let latencies: [String: Double] = ["C4-38-75-0E-BF-4A:output": 320,
                                           "70-99-1C-51-8F-A8:output": 640]
        try store.saveLatencies(latencies)
        #expect(try store.loadLatencies() == latencies)
    }

    /// The two maps are independent: the wizard writes the latency and must
    /// never disturb the user's trim, or the dismissal record.
    @Test func latenciesAndTrimsAndDismissalsSurviveEachOther() throws {
        let store = store()
        try store.save(["a": 40])
        try store.saveDismissedUIDs(["b"])
        try store.saveLatencies(["a": 320])
        #expect(try store.load() == ["a": 40])
        #expect(try store.loadDismissedUIDs() == ["b"])
        #expect(try store.loadLatencies() == ["a": 320])

        try store.save(["a": -10])
        #expect(try store.loadLatencies() == ["a": 320], "a trim write keeps the measurement")
    }

    // MARK: Reset alignment (roadmap 056 — the drawer's clear)

    /// Reset DELETES both of a device's entries. Writing 0 would not do: the
    /// row reads "tuned" off the entry EXISTING, so a stored 0 leaves the chip
    /// on "0 ms" forever instead of returning it to "Not set".
    @Test func clearAlignmentDeletesBothEntriesRatherThanZeroingThem() throws {
        let store = store()
        try store.save(["a": 40])
        try store.saveLatencies(["a": 320])
        try store.clearAlignment(deviceUID: "a")
        #expect(try store.load()?["a"] == nil, "the trim entry is gone, not 0")
        #expect(try store.loadLatencies()?["a"] == nil, "the measurement is gone, not 0")
    }

    /// It clears ONE device and touches nothing else — neither another
    /// speaker's alignment nor the dismissal record.
    @Test func clearAlignmentLeavesOtherDevicesAndDismissalsAlone() throws {
        let store = store()
        try store.save(["a": 40, "b": -10])
        try store.saveLatencies(["a": 320, "b": 640])
        try store.saveDismissedUIDs(["a"])
        try store.clearAlignment(deviceUID: "a")
        #expect(try store.load() == ["b": -10])
        #expect(try store.loadLatencies() == ["b": 640])
        #expect(try store.loadDismissedUIDs() == ["a"], "\"Not now\" is final and survives a reset")
    }

    /// Nothing stored yet (or nothing for this device) is not an error — the
    /// same read-modify-write, landing on an empty payload.
    @Test func clearAlignmentOnAnUnknownDeviceIsHarmless() throws {
        let store = store()
        try store.clearAlignment(deviceUID: "a")
        #expect(try store.load() == [:])
    }

    /// Backward compatible: a file written before latencies existed still
    /// loads, and reads as "nothing measured".
    @Test func aTrimsOnlyFileStillLoads() throws {
        let url = scratchDir.appendingPathComponent("bt-sync-trims.json")
        let payload = #"{"schemaVersion": 1, "trims": {"a": 22}}"#
        try payload.data(using: .utf8)!.write(to: url)
        #expect(try store().load() == ["a": 22])
        #expect(try store().loadLatencies() == nil)
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
