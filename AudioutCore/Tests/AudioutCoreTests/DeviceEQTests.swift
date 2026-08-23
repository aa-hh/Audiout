import Foundation
import Testing
@testable import AudioutCore

/// `DeviceEQ`'s value contract: everything clamps, the band array is always
/// exactly ten entries however it arrived, and a persisted file survives a
/// round trip. Pure value math — no shared state, so no isolation base.
@Suite struct DeviceEQTests {

    @Test func flatIsNeutralAndReportsItself() {
        let flat = DeviceEQ.flat
        #expect(flat.isFlat)
        #expect(flat.bassDB == 0)
        #expect(flat.trebleDB == 0)
        #expect(flat.balance == 0)
        #expect(flat.loudness == false)
        #expect(flat.bandGainsDB == Array(repeating: 0, count: DeviceEQ.bandCount))
    }

    @Test func anySingleNonNeutralStageEndsFlatness() {
        #expect(!DeviceEQ(bassDB: 1).isFlat)
        #expect(!DeviceEQ(trebleDB: -1).isFlat)
        #expect(!DeviceEQ(balance: 0.25).isFlat)
        #expect(!DeviceEQ(loudness: true).isFlat)
        var bands = [Double](repeating: 0, count: DeviceEQ.bandCount)
        bands[3] = 0.5
        #expect(!DeviceEQ(bandGainsDB: bands).isFlat)
    }

    @Test func gainsClampToRange() {
        let hot = DeviceEQ(bassDB: 99, trebleDB: -99)
        #expect(hot.bassDB == 12)
        #expect(hot.trebleDB == -12)
    }

    @Test func balanceClampsToPlusMinusOne() {
        #expect(DeviceEQ(balance: 5).balance == 1)
        #expect(DeviceEQ(balance: -5).balance == -1)
    }

    @Test func nonFiniteValuesBecomeNeutral() {
        let broken = DeviceEQ(
            bassDB: .nan,
            trebleDB: .infinity,
            balance: -.infinity,
            bandGainsDB: [.nan, 3])
        #expect(broken.bassDB == 0)
        #expect(broken.trebleDB == 0)
        #expect(broken.balance == 0)
        #expect(broken.bandGainsDB[0] == 0)
        #expect(broken.bandGainsDB[1] == 3)
    }

    @Test func shortBandArrayPadsToTen() {
        let eq = DeviceEQ(bandGainsDB: [1, 2, 3])
        #expect(eq.bandGainsDB.count == DeviceEQ.bandCount)
        #expect(eq.bandGainsDB == [1, 2, 3, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func longBandArrayTruncatesToTenAndClampsEach() {
        let eq = DeviceEQ(bandGainsDB: Array(repeating: 40, count: 25))
        #expect(eq.bandGainsDB == Array(repeating: 12, count: DeviceEQ.bandCount))
    }

    @Test func bandCentresMatchBandCount() {
        #expect(DeviceEQ.bandCentresHz.count == DeviceEQ.bandCount)
    }

    @Test func codableRoundTrips() throws {
        let eq = DeviceEQ(
            bassDB: 4.5,
            trebleDB: -3,
            balance: 0.25,
            loudness: true,
            bandGainsDB: [0, 1, -2, 3, -4, 5, -6, 7, -8, 9])
        let data = try JSONEncoder().encode(eq)
        #expect(try JSONDecoder().decode(DeviceEQ.self, from: data) == eq)
    }

    @Test func decodeNormalizesAMalformedBandArray() throws {
        let json = #"{"bassDB": 400, "trebleDB": 0, "balance": -9, "loudness": false, "bandGainsDB": [99, -99, 1]}"#
        let eq = try JSONDecoder().decode(DeviceEQ.self, from: Data(json.utf8))
        #expect(eq.bassDB == 12)
        #expect(eq.balance == -1)
        #expect(eq.bandGainsDB == [12, -12, 1, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func decodeToleratesMissingKeys() throws {
        let eq = try JSONDecoder().decode(DeviceEQ.self, from: Data(#"{"bassDB": 2}"#.utf8))
        #expect(eq.bassDB == 2)
        #expect(eq.bandGainsDB.count == DeviceEQ.bandCount)
        #expect(!eq.isFlat)
    }
}
