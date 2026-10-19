// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header, unlike most
// siblings. It is original parameter math written for this project,
// kept free of GPL-derived code so the license-clean Bluetooth sink
// (`BTSyncedSink.swift`) can hold the same `DeviceEQ` values the AirPlay path
// does. Do not add a GPL header to this file, and do not move GPL-derived code
// into it.

import Foundation

/// One speaker's (or Main Out's) tone settings.
///
/// Two independent tiers that BOTH apply — the simple controls are not a lossy
/// front end for the ten bands, they are their own filter stages, so a user can
/// dial in a band curve and still reach for Bass without losing it.
///
/// Values are clamped on construction and on decode; a persisted file written by
/// a future build with a longer band array (or a corrupt one) normalizes to
/// exactly ``bandCount`` entries rather than being rejected.
public struct DeviceEQ: Codable, Hashable, Sendable {

    /// The graphic EQ is always exactly this many bands — the array length is an
    /// invariant the DSP and the UI both rely on.
    public static let bandCount = 10

    /// Peaking-filter centres, one per entry of ``bandGainsDB``.
    public static let bandCentresHz: [Double] = [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    /// Every gain in this model — simple tier and bands alike — lives in this range.
    public static let gainRangeDB: ClosedRange<Double> = -12...12

    /// −1 = hard left, 0 = centre, +1 = hard right.
    public static let balanceRange: ClosedRange<Double> = -1...1

    public var bassDB: Double
    public var trebleDB: Double
    public var balance: Double
    public var loudness: Bool
    public var bandGainsDB: [Double]

    /// Every stage neutral. A device sitting on this must be streamed as
    /// byte-identical passthrough — never routed through an `EQProcessor`.
    public static let flat = DeviceEQ()

    public var isFlat: Bool {
        bassDB == 0 && trebleDB == 0 && balance == 0 && !loudness && bandGainsDB.allSatisfy { $0 == 0 }
    }

    public init(
        bassDB: Double = 0,
        trebleDB: Double = 0,
        balance: Double = 0,
        loudness: Bool = false,
        bandGainsDB: [Double] = Array(repeating: 0, count: DeviceEQ.bandCount)
    ) {
        self.bassDB = Self.clamp(bassDB, to: Self.gainRangeDB)
        self.trebleDB = Self.clamp(trebleDB, to: Self.gainRangeDB)
        self.balance = Self.clamp(balance, to: Self.balanceRange)
        self.loudness = loudness
        self.bandGainsDB = Self.normalizedBands(bandGainsDB)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case bassDB, trebleDB, balance, loudness, bandGainsDB
    }

    /// Decoding routes every value back through the clamping initializer, so a
    /// hand-edited or future-build file can never hand the DSP an out-of-range
    /// gain or a band array of the wrong length.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bassDB: try container.decodeIfPresent(Double.self, forKey: .bassDB) ?? 0,
            trebleDB: try container.decodeIfPresent(Double.self, forKey: .trebleDB) ?? 0,
            balance: try container.decodeIfPresent(Double.self, forKey: .balance) ?? 0,
            loudness: try container.decodeIfPresent(Bool.self, forKey: .loudness) ?? false,
            bandGainsDB: try container.decodeIfPresent([Double].self, forKey: .bandGainsDB) ?? [])
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
    }

    /// Exactly ``bandCount`` clamped entries: extras dropped, shortfall padded flat.
    private static func normalizedBands(_ gains: [Double]) -> [Double] {
        var normalized = gains.prefix(bandCount).map { clamp($0, to: gainRangeDB) }
        if normalized.count < bandCount {
            normalized.append(contentsOf: Array(repeating: 0, count: bandCount - normalized.count))
        }
        return normalized
    }
}
