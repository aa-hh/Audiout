// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// The excluded-apps denylist — the *list* half of the settings persistence
/// split. Mirrors `AppRouteStoreTests`: a throwaway temp directory, round-trip,
/// forward-compat, and the controller's add/remove/no-op-invariant behaviour.
@Suite final class ExcludedAppsTests {

    private let directory: URL

    init() {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Store

    @Test func missingFileLoadsNil() throws {
        let store = ExcludedAppsStore(directory: directory)
        #expect(try store.load() == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = ExcludedAppsStore(directory: directory)
        let apps = [
            ExcludedApp(bundleID: "us.zoom.xos", displayName: "Zoom"),
            ExcludedApp(bundleID: "com.apple.FaceTime", displayName: "FaceTime"),
        ]
        try store.save(apps)
        #expect(try store.load() == apps)
    }

    @Test func newerSchemaLoadsNil() throws {
        // Hand-write an envelope from a hypothetical future build.
        let future = #"{"schemaVersion": 99, "apps": []}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(future.utf8).write(to: directory.appendingPathComponent("excluded-apps.json"))
        #expect(try ExcludedAppsStore(directory: directory).load() == nil)
    }

    // MARK: Controller

    @Test func excludeAddsAndPersists() {
        let store = ExcludedAppsStore(directory: directory)
        let controller = ExcludedAppsController(store: store)
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")

        #expect(controller.isExcluded("us.zoom.xos"))
        #expect(controller.excludedBundleIDs == ["us.zoom.xos"])
        // A fresh controller over the same store sees the persisted exclusion.
        #expect(ExcludedAppsController(store: store).isExcluded("us.zoom.xos"))
    }

    @Test func excludingTwiceIsANoOp() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom (renamed)")
        #expect(controller.excludedApps.count == 1)
        #expect(controller.excludedApps.first?.displayName == "Zoom")
    }

    @Test func remove() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")
        controller.remove(bundleID: "us.zoom.xos")
        #expect(!controller.isExcluded("us.zoom.xos"))
        #expect(controller.excludedApps.isEmpty)
    }

    @Test func insertionOrderPreserved() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        controller.exclude(bundleID: "a", displayName: "A")
        controller.exclude(bundleID: "b", displayName: "B")
        controller.exclude(bundleID: "c", displayName: "C")
        #expect(controller.excludedApps.map(\.bundleID) == ["a", "b", "c"])
    }

    // MARK: onChange — change hook (T2, PLAN-COMPANION-APP.md)

    @Test func excludeFiresOnChangeOnRealChange() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        var fireCount = 0
        controller.onChange = { fireCount += 1 }

        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")

        #expect(fireCount == 1)
    }

    @Test func excludingTwiceDoesNotFireOnChangeTwice() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")
        var fireCount = 0
        controller.onChange = { fireCount += 1 }

        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom (renamed)")   // already excluded — no-op

        #expect(fireCount == 0, "excluding an already-excluded bundle must not fire onChange")
    }

    @Test func removeFiresOnChangeOnRealChange() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        controller.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")
        var fireCount = 0
        controller.onChange = { fireCount += 1 }

        controller.remove(bundleID: "us.zoom.xos")

        #expect(fireCount == 1)
    }

    @Test func removeDoesNotFireOnChangeForNonExcludedBundle() {
        let controller = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        var fireCount = 0
        controller.onChange = { fireCount += 1 }

        controller.remove(bundleID: "us.zoom.xos")   // never excluded — no-op

        #expect(fireCount == 0, "removing a bundle that was never excluded must not fire onChange")
    }
}
