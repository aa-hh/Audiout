// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

/// The excluded-apps denylist — the *list* half of the settings persistence
/// split. Mirrors `AppRouteStoreTests`: a throwaway temp directory, round-trip,
/// forward-compat, and the controller's add/remove/no-op-invariant behaviour.
final class ExcludedAppsTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    // MARK: Store

    func testMissingFileLoadsNil() throws {
        let store = ExcludedAppsStore(directory: directory)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = ExcludedAppsStore(directory: directory)
        let apps = [
            ExcludedApp(bundleID: "us.zoom.xos", displayName: "Zoom"),
            ExcludedApp(bundleID: "com.apple.FaceTime", displayName: "FaceTime"),
        ]
        try store.save(apps)
        XCTAssertEqual(try store.load(), apps)
    }

    func testNewerSchemaLoadsNil() throws {
        // Hand-write an envelope from a hypothetical future build.
        let future = #"{"schemaVersion": 99, "apps": []}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(future.utf8).write(to: directory.appendingPathComponent("excluded-apps.json"))
        XCTAssertNil(try ExcludedAppsStore(directory: directory).load())
    }

    // MARK: Controller

    func testExcludeAddsAndPersists() {
        let store = ExcludedAppsStore(directory: directory)
        let controller = ExcludedAppsController(store: store)
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")

        XCTAssertTrue(controller.isExcluded("us.zoom.xos"))
        XCTAssertEqual(controller.excludedBundleIDs, ["us.zoom.xos"])
        // A fresh controller over the same store sees the persisted exclusion.
        XCTAssertTrue(ExcludedAppsController(store: store).isExcluded("us.zoom.xos"))
    }

    func testExcludingTwiceIsANoOp() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom (renamed)")
        XCTAssertEqual(controller.excludedApps.count, 1)
        XCTAssertEqual(controller.excludedApps.first?.displayName, "Zoom")
    }

    func testRemove() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")
        controller.remove(bundleID: "us.zoom.xos")
        XCTAssertFalse(controller.isExcluded("us.zoom.xos"))
        XCTAssertTrue(controller.excludedApps.isEmpty)
    }

    func testInsertionOrderPreserved() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        controller.exclude(bundleID: "a", displayName: "A")
        controller.exclude(bundleID: "b", displayName: "B")
        controller.exclude(bundleID: "c", displayName: "C")
        XCTAssertEqual(controller.excludedApps.map(\.bundleID), ["a", "b", "c"])
    }
}
