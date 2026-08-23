import Foundation
import Testing
@testable import AudiouterCore

/// `EQStreamTopology`'s assignment rules: flat stays on stream 0, identical
/// settings share one stream (one encode), admission is deterministic, and a
/// device whose values still fit its existing stream keeps that stream id so a
/// slider drag never costs a rebind. Pure — no shared state.
@Suite struct EQStreamTopologyTests {

    private let warm = DeviceEQ(bassDB: 3)
    private let bright = DeviceEQ(trebleDB: 6)

    private func resolve(
        _ eqByDevice: [String: DeviceEQ],
        budget: Int = 5,
        allocator: EQStreamAllocator = EQStreamAllocator()
    ) -> EQStreamTopology.Result {
        EQStreamTopology.resolve(
            activeDeviceIDs: Set(eqByDevice.keys),
            eqByDevice: eqByDevice,
            budget: budget,
            allocator: allocator)
    }

    @Test func flatDevicesStayOnStreamZero() {
        let result = resolve(["a": .flat, "b": .flat])
        #expect(result.streamIDByDevice == ["a": 0, "b": 0])
        #expect(result.entries == [EQStreamTopology.Entry(streamID: 0, eq: nil)])
        #expect(result.bypassed.isEmpty)
    }

    @Test func aDeviceWithNoStoredEQCountsAsFlat() {
        let result = EQStreamTopology.resolve(
            activeDeviceIDs: ["a", "b"],
            eqByDevice: ["a": warm],
            budget: 5,
            allocator: EQStreamAllocator())
        #expect(result.streamIDByDevice["b"] == 0)
        #expect(result.streamIDByDevice["a"] != 0)
    }

    @Test func identicalSettingsShareOneStream() {
        let result = resolve(["a": warm, "b": warm, "c": .flat])
        let shared = result.streamIDByDevice["a"]
        #expect(shared != nil && shared != 0)
        #expect(result.streamIDByDevice["b"] == shared)
        #expect(result.streamIDByDevice["c"] == 0)
        #expect(result.entries.count == 2, "stream 0 plus exactly one EQ stream")
        #expect(result.entries.last?.eq == warm)
    }

    @Test func differentSettingsGetSeparateStreams() {
        let result = resolve(["a": warm, "b": bright])
        #expect(result.streamIDByDevice["a"] != result.streamIDByDevice["b"])
        #expect(result.entries.count == 3)
        #expect(result.bypassed.isEmpty)
    }

    @Test func eqStreamIDsAreDisjointFromPerAppIDs() {
        // `AppRouteMixer` allocates upward from 1; EQ ids live in the top half of
        // the space so the two allocators can never hand out the same tag.
        let result = resolve(["a": warm, "b": bright])
        for id in result.streamIDByDevice.values where id != 0 {
            #expect(id >= EQStreamAllocator.idBase)
        }
    }

    @Test func biggerGroupsAreAdmittedFirst() {
        // Budget of one: the pair wins over the loner regardless of ordering.
        let result = resolve(["a": warm, "b": warm, "solo": bright], budget: 1)
        #expect(result.streamIDByDevice["a"] == result.streamIDByDevice["b"])
        #expect(result.streamIDByDevice["a"] != 0)
        #expect(result.streamIDByDevice["solo"] == 0)
        #expect(result.bypassed == ["solo"])
    }

    @Test func equalSizedGroupsBreakTiesOnSmallestMemberID() {
        let result = resolve(["zulu": warm, "alpha": bright], budget: 1)
        #expect(result.streamIDByDevice["alpha"] != 0, "lexicographically smallest member wins the tie")
        #expect(result.bypassed == ["zulu"])
    }

    @Test func admissionIsStableAcrossRepeatedResolves() {
        let eqs = ["a": warm, "b": bright, "c": DeviceEQ(loudness: true)]
        let first = resolve(eqs, budget: 2)
        for _ in 0..<20 {
            #expect(resolve(eqs, budget: 2).bypassed == first.bypassed)
        }
    }

    @Test func overflowingTheBudgetBypassesRatherThanDropsSettings() {
        let result = resolve(["a": warm, "b": bright], budget: 0)
        #expect(result.entries == [EQStreamTopology.Entry(streamID: 0, eq: nil)])
        #expect(result.bypassed == ["a", "b"])
        #expect(result.streamIDByDevice == ["a": 0, "b": 0])
    }

    @Test func negativeBudgetIsTreatedAsNone() {
        #expect(resolve(["a": warm], budget: -3).bypassed == ["a"])
    }

    @Test func editingAValueKeepsTheStreamIDWhenTheMemberSetIsUnchanged() {
        // The whole point of keying on the device-id set: dragging a lone
        // device's slider swaps coefficients instead of rebinding its stream.
        let first = resolve(["a": warm])
        let streamID = first.streamIDByDevice["a"]
        let second = EQStreamTopology.resolve(
            activeDeviceIDs: ["a"],
            eqByDevice: ["a": DeviceEQ(bassDB: 9)],
            budget: 5,
            allocator: first.allocator)
        #expect(second.streamIDByDevice["a"] == streamID)
        #expect(second.entries.last?.eq == DeviceEQ(bassDB: 9))
    }

    @Test func aChangedMemberSetGetsItsOwnStreamID() {
        let first = resolve(["a": warm])
        let second = EQStreamTopology.resolve(
            activeDeviceIDs: ["a", "b"],
            eqByDevice: ["a": warm, "b": warm],
            budget: 5,
            allocator: first.allocator)
        #expect(second.streamIDByDevice["a"] != first.streamIDByDevice["a"])
        #expect(second.allocator.nextCounter == 2, "ids are never reused")
    }
}
