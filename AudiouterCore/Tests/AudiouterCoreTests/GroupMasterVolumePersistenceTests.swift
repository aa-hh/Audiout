// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `Group.masterVolume` persistence through `GroupStore` — a field added
/// after groups were already shipping. Unlike `Group.iconSymbolName` (an
/// `Optional`, which the synthesized `Decodable` handles for free when a key
/// is missing), `masterVolume` is a non-optional `Int` with a default value,
/// which the synthesized decoder does NOT apply to a missing key — that
/// requires the hand-written `init(from:)` in `GroupStore.swift` using
/// `decodeIfPresent`. The interesting case here is backward compat: a file
/// written before this field existed has no `masterVolume` key at all, and
/// must decode to `100` rather than fail. `GroupController` loads groups via
/// `(try? store.load()) ?? []`, so a decode failure here would silently wipe
/// every saved group rather than surface an error.
@Suite final class GroupMasterVolumePersistenceTests {

    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func roundTripPreservesMasterVolumeWhenSet() throws {
        let store = GroupStore(directory: directory)
        let group = Group(id: "g1", name: "Whole house", memberIDs: ["a", "b"], memberVolumes: ["a": 50, "b": 60],
                           masterVolume: 42)
        try store.save([group])

        let reloaded = try GroupStore(directory: directory).load()
        #expect(reloaded == [group])
        #expect(reloaded.first?.masterVolume == 42)
    }

    @Test func memberwiseInitDefaultsMasterVolumeTo100() throws {
        let group = Group(id: "g1", name: "Downstairs", memberIDs: ["a"], memberVolumes: ["a": 50])
        #expect(group.masterVolume == 100)
    }

    @Test func decodingPreMasterVolumeJSONWithNoKeyYields100AndPreservesEverythingElse() throws {
        // Hand-written envelope in the exact shape a build before this field
        // existed would have written — no `masterVolume` key present
        // anywhere, not even as `null`, across two groups.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preMasterVolume = """
        {
          "schemaVersion": 1,
          "groups": [
            {
              "id": "g1",
              "name": "Whole house",
              "memberIDs": ["a", "b"],
              "memberVolumes": {"a": 10, "b": 90},
              "iconSymbolName": "house.fill"
            },
            {
              "id": "g2",
              "name": "Downstairs",
              "memberIDs": ["a"],
              "memberVolumes": {"a": 50}
            }
          ]
        }
        """
        try Data(preMasterVolume.utf8).write(to: directory.appendingPathComponent("groups.json"))

        let groups = try GroupStore(directory: directory).load()
        #expect(groups.count == 2)

        #expect(groups[0].id == "g1")
        #expect(groups[0].name == "Whole house")
        #expect(groups[0].memberIDs == ["a", "b"])
        #expect(groups[0].memberVolumes == ["a": 10, "b": 90])
        #expect(groups[0].iconSymbolName == "house.fill")
        #expect(groups[0].masterVolume == 100, "a missing key must decode as 100, not fail or default to 0")

        #expect(groups[1].id == "g2")
        #expect(groups[1].name == "Downstairs")
        #expect(groups[1].memberIDs == ["a"])
        #expect(groups[1].memberVolumes == ["a": 50])
        #expect(groups[1].iconSymbolName == nil)
        #expect(groups[1].masterVolume == 100)
    }
}
