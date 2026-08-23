// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header, unlike most
// siblings. It is original parameter/allocation math written for this project,
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

// MARK: - Stream-id allocation

/// Which AirPlay stream id each EQ group owns, remembered across recomputes.
///
/// Keyed by the group's DEVICE-ID SET rather than by its values: editing a lone
/// device's EQ keeps the same members, so it keeps the same stream and costs a
/// coefficient swap instead of a rebind (and its ~1 s audible gap). Ids are
/// never reused — a released id stays retired for the session.
public struct EQStreamAllocator: Equatable, Sendable {

    /// EQ stream ids live in the top half of the `UInt32` space; `AppRouteMixer`
    /// allocates its per-app ids upward from 1, so the two can never collide.
    public static let idBase: UInt32 = 0x8000_0000

    public private(set) var idsByMembers: [Set<String>: UInt32]
    public private(set) var nextCounter: UInt32

    public init(idsByMembers: [Set<String>: UInt32] = [:], nextCounter: UInt32 = 0) {
        self.idsByMembers = idsByMembers
        self.nextCounter = nextCounter
    }

    fileprivate mutating func id(forMembers members: Set<String>) -> UInt32 {
        if let existing = idsByMembers[members] { return existing }
        let id = Self.idBase | nextCounter
        nextCounter &+= 1
        idsByMembers[members] = id
        return id
    }
}

// MARK: - Topology

/// Pure: which whole-system AirPlay stream each device should be on, given
/// everyone's EQ and how many streams are left in the engine's budget.
///
/// Devices sharing an identical `DeviceEQ` share one stream (one ALAC encode);
/// flat devices stay on stream 0 and are byte-identical passthrough. When more
/// distinct settings exist than the budget allows, the losers keep their stored
/// values but stream flat — `bypassed` is what the UI reads to say so out loud
/// rather than pretending an inaudible EQ is applied.
public enum EQStreamTopology {

    /// One entry of the plan the capture coordinator writes: which stream, and
    /// the EQ it carries. `eq == nil` is stream 0 — main EQ only, no per-device
    /// stage.
    public struct Entry: Equatable, Sendable {
        public let streamID: UInt32
        public let eq: DeviceEQ?

        public init(streamID: UInt32, eq: DeviceEQ?) {
            self.streamID = streamID
            self.eq = eq
        }
    }

    public struct Result: Equatable, Sendable {
        /// Always leads with stream 0; then one entry per admitted EQ group.
        public let entries: [Entry]
        /// Every active device, including the ones left on stream 0.
        public let streamIDByDevice: [String: UInt32]
        /// Non-flat devices that did not fit the budget and stream flat anyway.
        public let bypassed: Set<String>
        public let allocator: EQStreamAllocator
    }

    /// - Parameters:
    ///   - budget: how many EQ streams may exist beyond stream 0. Negative is
    ///     treated as none.
    public static func resolve(
        activeDeviceIDs: Set<String>,
        eqByDevice: [String: DeviceEQ],
        budget: Int,
        allocator: EQStreamAllocator
    ) -> Result {
        var groups: [DeviceEQ: Set<String>] = [:]
        for id in activeDeviceIDs {
            let eq = eqByDevice[id] ?? .flat
            guard !eq.isFlat else { continue }
            groups[eq, default: []].insert(id)
        }

        // Deterministic admission: bigger groups first (one stream serving more
        // speakers is worth more), ties broken by the lexicographically smallest
        // member. Groups are disjoint and non-empty, so that tie-break is total.
        let ordered = groups.sorted { left, right in
            if left.value.count != right.value.count { return left.value.count > right.value.count }
            return left.value.min()! < right.value.min()!
        }

        var allocator = allocator
        var entries = [Entry(streamID: 0, eq: nil)]
        var streamIDByDevice: [String: UInt32] = [:]
        var bypassed: Set<String> = []
        let admissions = Swift.max(0, budget)

        for (index, group) in ordered.enumerated() {
            guard index < admissions else {
                bypassed.formUnion(group.value)
                continue
            }
            let streamID = allocator.id(forMembers: group.value)
            entries.append(Entry(streamID: streamID, eq: group.key))
            for member in group.value { streamIDByDevice[member] = streamID }
        }

        for id in activeDeviceIDs where streamIDByDevice[id] == nil { streamIDByDevice[id] = 0 }

        return Result(
            entries: entries,
            streamIDByDevice: streamIDByDevice,
            bypassed: bypassed,
            allocator: allocator)
    }
}
