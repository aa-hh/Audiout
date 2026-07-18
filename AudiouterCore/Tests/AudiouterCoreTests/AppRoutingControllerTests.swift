// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

final class AppRoutingControllerTests: XCTestCase {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func fileURL(in dir: URL) -> URL {
        dir.appendingPathComponent("app-routes.json")
    }

    // MARK: Add / set / remove round-trip through a reloaded controller

    func testAddSetRemoveRoundTripsThroughReloadedController() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setVolume(42, for: "com.apple.Music")

        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")

        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        XCTAssertEqual(reloaded.appRoutes, [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .device(id: "homepod-1"), volume: 42),
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify"),
        ])

        reloaded.removeRoute(bundleID: "com.apple.Music")
        let reloadedAgain = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        XCTAssertEqual(reloadedAgain.appRoutes, [
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify"),
        ])
    }

    func testInsertionOrderIsStable() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "b", displayName: "B")
        controller.addRoute(bundleID: "a", displayName: "A")
        controller.addRoute(bundleID: "c", displayName: "C")
        XCTAssertEqual(controller.appRoutes.map(\.bundleID), ["b", "a", "c"])
    }

    // MARK: routedAppCount

    /// Every new route defaults to `.noRedirect` (not `.currentDevice`) — this
    /// pins that `routedAppCount` correctly reports 0 for a freshly-added batch,
    /// which would be wrong (3) under the old `!= .currentDevice` comparison.
    func testRoutedAppCountCountsOnlyRedirectedRoutes() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")

        XCTAssertEqual(controller.routedAppCount, 0, "fresh routes default to .noRedirect, not routed")

        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        XCTAssertEqual(controller.routedAppCount, 1)

        controller.setDestination(.device(id: "office"), for: "com.spotify.client")
        XCTAssertEqual(controller.routedAppCount, 2)

        // Explicit Current Device is just as "not routed" as No Redirect.
        controller.setDestination(.currentDevice, for: "com.apple.Music")
        XCTAssertEqual(controller.routedAppCount, 1)

        // Reverting to No Redirect drops it out too.
        controller.setDestination(.noRedirect, for: "com.spotify.client")
        XCTAssertEqual(controller.routedAppCount, 0)
    }

    // MARK: handleDeviceUnavailable

    func testHandleDeviceUnavailableResetsMatchingRoutesAndPersists() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setDestination(.device(id: "office"), for: "com.spotify.client")

        controller.handleDeviceUnavailable(id: "homepod-1")

        XCTAssertEqual(controller.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination, .noRedirect,
                       "fallback targets No Redirect, not Current Device — losing a device isn't a deliberate choice")
        XCTAssertEqual(controller.appRoutes.first { $0.bundleID == "com.spotify.client" }?.destination, .device(id: "office"),
                       "unrelated device routes must be untouched")

        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        XCTAssertEqual(reloaded.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination, .noRedirect,
                       "the fallback must be persisted")
    }

    func testHandleDeviceUnavailableWithNoMatchIsNoOpAndDoesNotPersist() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        // First mutation creates the file; capture its state before the no-op.
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.handleDeviceUnavailable(id: "some-other-device")

        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(before, after, "a no-op fallback must not rewrite the store")
    }

    // MARK: Duplicate addRoute is a no-op

    func testDuplicateAddRouteIsNoOp() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setVolume(55, for: "com.apple.Music")

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Different Name")

        XCTAssertEqual(controller.appRoutes.count, 1)
        XCTAssertEqual(controller.appRoutes[0].displayName, "Music", "duplicate add must not overwrite the existing route")
        XCTAssertEqual(controller.appRoutes[0].destination, .device(id: "homepod-1"))
        XCTAssertEqual(controller.appRoutes[0].volume, 55)
    }

    // MARK: Volume clamps

    func testSetVolumeClamps() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")

        controller.setVolume(150, for: "com.apple.Music")
        XCTAssertEqual(controller.appRoutes[0].volume, 100)

        controller.setVolume(-20, for: "com.apple.Music")
        XCTAssertEqual(controller.appRoutes[0].volume, 0)
    }

    // MARK: No-op setDestination / setVolume must not rewrite the file

    func testNoOpSetDestinationDoesNotRewriteFile() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.setDestination(.noRedirect, for: "com.apple.Music") // already .noRedirect (the new default)

        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(before, after, "setting the same destination must not rewrite the store")
    }

    func testNoOpSetVolumeDoesNotRewriteFile() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music") // volume defaults to 100
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.setVolume(100, for: "com.apple.Music") // same value

        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(before, after, "setting the same volume must not rewrite the store")
    }

    func testNoOpMutationsDoNotChangeState() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let before = controller.appRoutes

        controller.setDestination(.noRedirect, for: "com.apple.Music") // already .noRedirect (the new default)
        controller.setVolume(100, for: "com.apple.Music")
        controller.setDestination(.currentDevice, for: "unknown.bundle.id")
        controller.setVolume(50, for: "unknown.bundle.id")
        controller.removeRoute(bundleID: "unknown.bundle.id")

        XCTAssertEqual(controller.appRoutes, before)
    }

    // MARK: routedAppNames(for:) — feeds the DeviceRowView routing sublabel

    func testRoutedAppNamesFiltersByDeviceIDAndExcludesCurrentDevice() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")

        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setDestination(.device(id: "office"), for: "com.spotify.client")
        // com.apple.Safari stays .noRedirect (no redirect) — must be excluded.

        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), ["Music"])
        XCTAssertEqual(controller.routedAppNames(for: "office"), ["Spotify"])
        XCTAssertEqual(controller.routedAppNames(for: "some-other-device"), [],
                       "a device with no routes gets an empty list")
    }

    func testRoutedAppNamesExcludesNoRedirectAndCurrentDeviceRoutesEntirely() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        // Never redirected — stays .noRedirect (the new default).
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.currentDevice, for: "com.apple.Safari") // explicit local pick

        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), [],
                       "neither .noRedirect nor .currentDevice routes are ever routed to a device")
    }

    func testRoutedAppNamesPreservesStableRouteOrder() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "b", displayName: "Zebra App")
        controller.addRoute(bundleID: "a", displayName: "Alpha App")
        controller.addRoute(bundleID: "c", displayName: "Charlie App")

        controller.setDestination(.device(id: "homepod-1"), for: "b")
        controller.setDestination(.device(id: "homepod-1"), for: "a")
        controller.setDestination(.device(id: "homepod-1"), for: "c")

        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), ["Zebra App", "Alpha App", "Charlie App"],
                       "insertion order is preserved, not sorted")
    }

    func testRoutedAppNamesUpdatesWhenDestinationChanges() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), ["Music"])

        controller.setDestination(.currentDevice, for: "com.apple.Music")
        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), [],
                       "reverting to .currentDevice removes it from the routing set")
    }

    // MARK: onRoutesDidChange — the "routing table changed" signal (T7)
    //
    // T7 wires this callback to `AppRouteConfiguring.updateAppRoutes` so a route
    // change actually streams the app to its device via the per-app capture path
    // (replacing the removed whole-system output-set union). These tests pin that
    // the signal fires exactly on the change edge, and that hooking it to a backend
    // forwards the current table.

    func testOnRoutesDidChangeFiresOnRealMutationsOnly() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        var fireCount = 0
        controller.onRoutesDidChange = { fireCount += 1 }

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")   // 1
        controller.setDestination(.device(id: "office"), for: "com.apple.Music") // 2
        controller.setVolume(30, for: "com.apple.Music")                         // 3
        XCTAssertEqual(fireCount, 3)

        // No-op mutations must NOT fire (they return before persist()).
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")   // dup — no-op
        controller.setDestination(.device(id: "office"), for: "com.apple.Music") // same dest — no-op
        controller.setVolume(30, for: "com.apple.Music")                         // same vol — no-op
        controller.removeRoute(bundleID: "not-present")                          // missing — no-op
        XCTAssertEqual(fireCount, 3, "no-op mutations don't fire the change signal")

        controller.removeRoute(bundleID: "com.apple.Music")                      // 4
        XCTAssertEqual(fireCount, 4)
    }

    /// Integration proof of the T7 wiring: hooking `onRoutesDidChange` to forward
    /// into an `AppRouteConfiguring` backend means every route change calls through
    /// to `updateAppRoutes` with the current table + excluded set — exactly what
    /// `AppDelegate.pushAppRoutesToBackend()` does in production.
    func testRouteChangeCallsThroughToBackendUpdateAppRoutes() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        let backend = SpyAppRouteBackend()
        let excluded: Set<String> = ["com.example.excluded"]
        controller.onRoutesDidChange = {
            backend.updateAppRoutes(controller.appRoutes, excludedBundleIDs: excluded)
        }

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "office"), for: "com.apple.Music")

        XCTAssertEqual(backend.calls.count, 2, "each real mutation calls updateAppRoutes once")
        XCTAssertEqual(backend.calls.last?.routes, [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .device(id: "office"), volume: 100),
        ])
        XCTAssertEqual(backend.calls.last?.excluded, excluded,
                       "the excluded set is forwarded verbatim to the backend")
    }
}

/// A test double capturing every `updateAppRoutes` call, standing in for
/// `NativeBackend` (the only production `AppRouteConfiguring`).
private final class SpyAppRouteBackend: AppRouteConfiguring {
    private(set) var calls: [(routes: [AppRoute], excluded: Set<String>)] = []
    private(set) var terminatedBundleIDs: [String] = []
    func updateAppRoutes(_ routes: [AppRoute], excludedBundleIDs: Set<String>) {
        calls.append((routes, excludedBundleIDs))
    }
    func handleAppTerminated(bundleID: String) {
        terminatedBundleIDs.append(bundleID)
    }
}
