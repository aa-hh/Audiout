// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `Group.iconSymbolName` persistence through `GroupStore` — a phase-2
/// addition to a schema that already shipped without it. Mirrors
/// `AppRouteStoreTests`'s forward-compat style, but here the interesting case
/// is *backward* compat: a pre-phase-2 file on disk simply has no
/// `iconSymbolName` key at all, and must decode as `nil` rather than fail.
@Suite final class GroupIconPersistenceTests {

    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func roundTripPreservesIconSymbolNameWhenSet() throws {
        let store = GroupStore(directory: directory)
        let group = Group(id: "g1", name: "Whole house", memberIDs: ["a", "b"], memberVolumes: ["a": 50, "b": 60],
                           iconSymbolName: "house.fill")
        try store.save([group])

        let reloaded = try GroupStore(directory: directory).load()
        #expect(reloaded == [group])
        #expect(reloaded.first?.iconSymbolName == "house.fill")
    }

    @Test func roundTripPreservesNilIconSymbolName() throws {
        let store = GroupStore(directory: directory)
        let group = Group(id: "g1", name: "Downstairs", memberIDs: ["a"], memberVolumes: ["a": 50])
        #expect(group.iconSymbolName == nil)
        try store.save([group])

        let reloaded = try GroupStore(directory: directory).load()
        #expect(reloaded == [group])
        #expect(reloaded.first?.iconSymbolName == nil)
    }

    @Test func decodingPrePhase2JSONWithNoIconSymbolNameKeyYieldsNil() throws {
        // Hand-written envelope in the exact shape a phase-1 build would have
        // written — no `iconSymbolName` key present anywhere in the group
        // object, not even as `null`.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prePhase2 = """
        {
          "schemaVersion": 1,
          "groups": [
            {
              "id": "g1",
              "name": "Whole house",
              "memberIDs": ["a", "b"],
              "memberVolumes": {"a": 50, "b": 60}
            }
          ]
        }
        """
        try Data(prePhase2.utf8).write(to: directory.appendingPathComponent("groups.json"))

        let groups = try GroupStore(directory: directory).load()
        #expect(groups.count == 1)
        #expect(groups.first?.id == "g1")
        #expect(groups.first?.name == "Whole house")
        #expect(groups.first?.memberIDs == ["a", "b"])
        #expect(groups.first?.iconSymbolName == nil, "a missing key must decode as nil, not fail or default to a symbol")
    }
}
