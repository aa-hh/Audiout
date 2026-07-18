// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudioutedCore

/// `Group.iconSymbolName` persistence through `GroupStore` — a phase-2
/// addition to a schema that already shipped without it. Mirrors
/// `AppRouteStoreTests`'s forward-compat style, but here the interesting case
/// is *backward* compat: a pre-phase-2 file on disk simply has no
/// `iconSymbolName` key at all, and must decode as `nil` rather than fail.
final class GroupIconPersistenceTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutedTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    func testRoundTripPreservesIconSymbolNameWhenSet() throws {
        let store = GroupStore(directory: directory)
        let group = Group(id: "g1", name: "Whole house", memberIDs: ["a", "b"], memberVolumes: ["a": 50, "b": 60],
                           iconSymbolName: "house.fill")
        try store.save([group])

        let reloaded = try GroupStore(directory: directory).load()
        XCTAssertEqual(reloaded, [group])
        XCTAssertEqual(reloaded.first?.iconSymbolName, "house.fill")
    }

    func testRoundTripPreservesNilIconSymbolName() throws {
        let store = GroupStore(directory: directory)
        let group = Group(id: "g1", name: "Downstairs", memberIDs: ["a"], memberVolumes: ["a": 50])
        XCTAssertNil(group.iconSymbolName)
        try store.save([group])

        let reloaded = try GroupStore(directory: directory).load()
        XCTAssertEqual(reloaded, [group])
        XCTAssertNil(reloaded.first?.iconSymbolName)
    }

    func testDecodingPrePhase2JSONWithNoIconSymbolNameKeyYieldsNil() throws {
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
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "g1")
        XCTAssertEqual(groups.first?.name, "Whole house")
        XCTAssertEqual(groups.first?.memberIDs, ["a", "b"])
        XCTAssertNil(groups.first?.iconSymbolName, "a missing key must decode as nil, not fail or default to a symbol")
    }
}
