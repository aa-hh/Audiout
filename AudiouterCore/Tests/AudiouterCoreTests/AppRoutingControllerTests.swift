// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

@Suite struct AppRoutingControllerTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func fileURL(in dir: URL) -> URL {
        dir.appendingPathComponent("app-routes.json")
    }

    // MARK: Add / set / remove round-trip through a reloaded controller

    @Test func addSetRemoveRoundTripsThroughReloadedController() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setVolume(42, for: "com.apple.Music")

        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")

        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        #expect(reloaded.appRoutes == [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .device(id: "homepod-1"), volume: 42),
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify"),
        ])

        reloaded.removeRoute(bundleID: "com.apple.Music")
        let reloadedAgain = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        #expect(reloadedAgain.appRoutes == [
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify"),
        ])
    }

    @Test func insertionOrderIsStable() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "b", displayName: "B")
        controller.addRoute(bundleID: "a", displayName: "A")
        controller.addRoute(bundleID: "c", displayName: "C")
        #expect(controller.appRoutes.map(\.bundleID) == ["b", "a", "c"])
    }

    // MARK: routedAppCount

    /// Every new route defaults to `.noRedirect` (not `.currentDevice`) — this
    /// pins that `routedAppCount` correctly reports 0 for a freshly-added batch,
    /// which would be wrong (3) under the old `!= .currentDevice` comparison.
    @Test func routedAppCountCountsOnlyRedirectedRoutes() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")

        #expect(controller.routedAppCount == 0, "fresh routes default to .noRedirect, not routed")

        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        #expect(controller.routedAppCount == 1)

        controller.setDestination(.device(id: "office"), for: "com.spotify.client")
        #expect(controller.routedAppCount == 2)

        // Explicit Current Device is just as "not routed" as No Redirect.
        controller.setDestination(.currentDevice, for: "com.apple.Music")
        #expect(controller.routedAppCount == 1)

        // Reverting to No Redirect drops it out too.
        controller.setDestination(.noRedirect, for: "com.spotify.client")
        #expect(controller.routedAppCount == 0)
    }

    // MARK: handleDeviceDisappeared

    @Test func handleDeviceDisappearedResetsMatchingRoutesAndPersists() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setDestination(.device(id: "office"), for: "com.spotify.client")

        controller.handleDeviceDisappeared(id: "homepod-1")

        #expect(controller.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination == .noRedirect,
                       "fallback targets No Redirect, not Current Device — losing a device isn't a deliberate choice")
        #expect(controller.appRoutes.first { $0.bundleID == "com.spotify.client" }?.destination == .device(id: "office"),
                       "unrelated device routes must be untouched")

        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        #expect(reloaded.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination == .noRedirect,
                       "the fallback must be persisted")
    }

    @Test func handleDeviceDisappearedWithNoMatchIsNoOpAndDoesNotPersist() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        // First mutation creates the file; capture its state before the no-op.
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.handleDeviceDisappeared(id: "some-other-device")

        let after = try Data(contentsOf: fileURL)
        #expect(before == after, "a no-op fallback must not rewrite the store")
    }

    // MARK: clearRoutes(toDevices:) — a speaker selected into Main Out wins it

    /// Selecting a speaker into Main Out (or activating a group containing it)
    /// reverts every redirect pointed at it back to `.noRedirect` — one role per
    /// speaker, selection is senior — while unrelated routes stay put, and the
    /// change is persisted. Mirrors `handleDeviceDisappeared`, generalized to a set.
    @Test func clearRoutesToDevicesRevertsMatchingRoutesAndPersists() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.device(id: "living-room"), for: "com.apple.Music")
        controller.setDestination(.device(id: "living-room"), for: "com.spotify.client")
        controller.setDestination(.device(id: "office"), for: "com.apple.Safari")

        // "living-room" and (a not-currently-targeted) "kitchen" both join Main Out.
        controller.clearRoutes(toDevices: ["living-room", "kitchen"])

        #expect(controller.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination == .noRedirect)
        #expect(controller.appRoutes.first { $0.bundleID == "com.spotify.client" }?.destination == .noRedirect,
                "every redirect to a now-Main-Out speaker yields, not just the first")
        #expect(controller.appRoutes.first { $0.bundleID == "com.apple.Safari" }?.destination == .device(id: "office"),
                "a redirect to a speaker NOT in the set is untouched")

        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        #expect(reloaded.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination == .noRedirect,
                "the yield must be persisted")
    }

    @Test func clearRoutesToDevicesIsNoOpWhenNothingConflicts() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "office"), for: "com.apple.Music")
        var didFire = false
        controller.onRoutesDidChange = { didFire = true }
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        // Neither an empty set nor a set that matches no route may persist or notify.
        controller.clearRoutes(toDevices: [])
        controller.clearRoutes(toDevices: ["living-room"])

        #expect(didFire == false, "a no-op clear must not fire onRoutesDidChange")
        #expect(try Data(contentsOf: fileURL) == before, "a no-op clear must not rewrite the store")
    }

    // MARK: resetDeviceRoute — a per-app redirect resets when the routed app quits

    @Test func resetDeviceRouteRevertsDeviceRedirectToNoRedirectAndPersists() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "org.mozilla.firefox", displayName: "Firefox")
        controller.setDestination(.device(id: "living-room"), for: "org.mozilla.firefox")

        controller.resetDeviceRoute(bundleID: "org.mozilla.firefox")

        #expect(controller.appRoutes.first { $0.bundleID == "org.mozilla.firefox" }?.destination == .noRedirect,
                       "a device redirect must revert to No Redirect when the routed app quits")
        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        #expect(reloaded.appRoutes.first { $0.bundleID == "org.mozilla.firefox" }?.destination == .noRedirect,
                       "the reset must persist so a relaunch never auto-resumes streaming to the speaker")
    }

    // MARK: clearedDeviceRouteMemory — "Resume → <device>" support

    /// `resetDeviceRoute` (the app-quit-triggered clear) records the cleared
    /// target in-memory so a relaunch can offer a one-click "Resume" back to
    /// it, without reversing the quit-clears-the-route decision itself.
    @Test func resetDeviceRouteRecordsClearedDeviceRouteMemory() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "org.mozilla.firefox", displayName: "Firefox")
        controller.setDestination(.device(id: "living-room"), for: "org.mozilla.firefox")

        controller.resetDeviceRoute(bundleID: "org.mozilla.firefox")

        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == "living-room",
                "the cleared target must be remembered so a relaunch can offer to resume it")
    }

    /// A `resetDeviceRoute` call that no-ops (already `.noRedirect`/`.currentDevice`,
    /// or no route at all) must not fabricate a memory entry — there was nothing
    /// to resume.
    @Test func resetDeviceRouteNoOpDoesNotRecordClearedDeviceRouteMemory() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")     // stays .noRedirect
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.currentDevice, for: "com.apple.Safari")

        controller.resetDeviceRoute(bundleID: "com.apple.Music")
        controller.resetDeviceRoute(bundleID: "com.apple.Safari")
        controller.resetDeviceRoute(bundleID: "com.unknown.app")

        #expect(controller.clearedDeviceRouteTarget(for: "com.apple.Music") == nil)
        #expect(controller.clearedDeviceRouteTarget(for: "com.apple.Safari") == nil)
        #expect(controller.clearedDeviceRouteTarget(for: "com.unknown.app") == nil)
    }

    /// Any `setDestination` call for a bundle ID with a remembered cleared
    /// target consumes (clears) that memory — whether the pick IS the resume
    /// target, a different device entirely, or even the exact same destination
    /// the route already has (a true no-op mutation still consumes it: once the
    /// user has touched this row, the remembered target is moot either way).
    @Test func setDestinationClearsClearedDeviceRouteMemoryOnAnyPick() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "org.mozilla.firefox", displayName: "Firefox")
        controller.setDestination(.device(id: "living-room"), for: "org.mozilla.firefox")
        controller.resetDeviceRoute(bundleID: "org.mozilla.firefox")
        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == "living-room")

        // Picking the SAME device the memory names (the "Resume" pick in
        // production) still consumes the memory — it's now been acted on.
        controller.setDestination(.device(id: "living-room"), for: "org.mozilla.firefox")
        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == nil,
                "picking the resume target consumes the memory")

        // Re-arm, then pick a DIFFERENT destination entirely.
        controller.setDestination(.device(id: "living-room"), for: "org.mozilla.firefox")
        controller.resetDeviceRoute(bundleID: "org.mozilla.firefox")
        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == "living-room")

        controller.setDestination(.device(id: "kitchen"), for: "org.mozilla.firefox")
        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == nil,
                "picking a different destination also consumes the now-stale memory")
    }

    /// `removeRoute` drops any remembered cleared target too — a removed route
    /// has nothing left to resume.
    @Test func removeRouteClearsClearedDeviceRouteMemory() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "org.mozilla.firefox", displayName: "Firefox")
        controller.setDestination(.device(id: "living-room"), for: "org.mozilla.firefox")
        controller.resetDeviceRoute(bundleID: "org.mozilla.firefox")
        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == "living-room")

        controller.removeRoute(bundleID: "org.mozilla.firefox")

        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == nil)
    }

    /// The memory is in-memory ONLY — a reloaded controller (simulating
    /// Audiouter itself relaunching) must never see a remembered target, since
    /// nothing persisted it and no `AppRouteStore` schema field carries it.
    @Test func clearedDeviceRouteMemoryIsNotPersistedAcrossReload() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "org.mozilla.firefox", displayName: "Firefox")
        controller.setDestination(.device(id: "living-room"), for: "org.mozilla.firefox")
        controller.resetDeviceRoute(bundleID: "org.mozilla.firefox")
        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == "living-room")

        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        #expect(reloaded.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == nil,
                "the memory must not survive a reload — it is forgotten for free on quit")
        // And the persisted route itself is exactly what resetDeviceRoute left it as.
        #expect(reloaded.appRoutes.first?.destination == .noRedirect)
    }

    @Test func resetDeviceRouteLeavesNonDeviceRoutesAndMissingBundlesUntouched() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")     // stays .noRedirect (default)
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.currentDevice, for: "com.apple.Safari")
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.resetDeviceRoute(bundleID: "com.apple.Music")    // already .noRedirect → no-op
        controller.resetDeviceRoute(bundleID: "com.apple.Safari")   // .currentDevice is a deliberate pick → no-op
        controller.resetDeviceRoute(bundleID: "com.unknown.app")    // no route → no-op

        #expect(controller.appRoutes.first { $0.bundleID == "com.apple.Safari" }?.destination == .currentDevice,
                       "a 'play on this Mac' pick is deliberate — it must survive the app quitting")
        let after = try Data(contentsOf: fileURL)
        #expect(before == after, "no-op resets must not rewrite the store")
    }

    // MARK: clearAllDeviceRoutes — every `.device` route reverts to `.noRedirect` at launch

    /// Every `.device`-routed app reverts to `.noRedirect`; `.noRedirect` and
    /// `.currentDevice` routes are left untouched, and the reset persists so a
    /// reloaded controller (simulating the NEXT launch) sees it too.
    @Test func clearAllDeviceRoutesRevertsOnlyDeviceRoutesAndPersists() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.setDestination(.device(id: "office"), for: "com.spotify.client")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.currentDevice, for: "com.apple.Safari")
        controller.addRoute(bundleID: "com.apple.TextEdit", displayName: "TextEdit") // stays .noRedirect

        controller.clearAllDeviceRoutes()

        #expect(controller.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination == .noRedirect)
        #expect(controller.appRoutes.first { $0.bundleID == "com.spotify.client" }?.destination == .noRedirect)
        #expect(controller.appRoutes.first { $0.bundleID == "com.apple.Safari" }?.destination == .currentDevice,
                "a deliberate 'play on this Mac' pick must survive the launch-time clear")
        #expect(controller.appRoutes.first { $0.bundleID == "com.apple.TextEdit" }?.destination == .noRedirect)

        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        #expect(reloaded.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination == .noRedirect,
                "the clear must persist")
        #expect(reloaded.appRoutes.first { $0.bundleID == "com.spotify.client" }?.destination == .noRedirect,
                "the clear must persist")
    }

    /// A call with no `.device` routes present at all is a true no-op: it must
    /// not rewrite the store and must not fire `onRoutesDidChange`.
    @Test func clearAllDeviceRoutesWithNoDeviceRoutesIsNoOpAndDoesNotPersist() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music") // stays .noRedirect
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.currentDevice, for: "com.apple.Safari")
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)
        var fireCount = 0
        controller.onRoutesDidChange = { fireCount += 1 }

        controller.clearAllDeviceRoutes()

        let after = try Data(contentsOf: fileURL)
        #expect(before == after, "a no-op clear must not rewrite the store")
        #expect(fireCount == 0, "a no-op clear must not fire onRoutesDidChange")
    }

    /// Batching: with MULTIPLE `.device` routes present, the whole operation
    /// must fire `onRoutesDidChange` exactly once, not once per cleared route.
    @Test func clearAllDeviceRoutesFiresOnRoutesDidChangeExactlyOnce() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.setDestination(.device(id: "office"), for: "com.spotify.client")
        controller.addRoute(bundleID: "org.mozilla.firefox", displayName: "Firefox")
        controller.setDestination(.device(id: "kitchen"), for: "org.mozilla.firefox")

        var fireCount = 0
        controller.onRoutesDidChange = { fireCount += 1 }

        controller.clearAllDeviceRoutes()

        #expect(fireCount == 1, "clearing several device routes in one call must fire the change signal exactly once")
        #expect(controller.routedAppCount == 0)
    }

    /// `clearAllDeviceRoutes` must NOT touch `clearedDeviceRouteMemory` — that
    /// map backs the narrower app-quit "Resume → <device>" offer
    /// (`resetDeviceRoute`), a separate mechanism from this broader
    /// launch-time clear. This is a deliberate judgment call, not an oversight
    /// — see the doc comment on `clearAllDeviceRoutes()`.
    @Test func clearAllDeviceRoutesDoesNotTouchClearedDeviceRouteMemory() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "org.mozilla.firefox", displayName: "Firefox")
        controller.setDestination(.device(id: "living-room"), for: "org.mozilla.firefox")
        controller.resetDeviceRoute(bundleID: "org.mozilla.firefox")
        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == "living-room")

        // A second, unrelated device route exists at the time of the launch-time clear.
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")

        controller.clearAllDeviceRoutes()

        #expect(controller.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination == .noRedirect)
        #expect(controller.clearedDeviceRouteTarget(for: "com.apple.Music") == nil,
               "clearAllDeviceRoutes must not populate clearedDeviceRouteMemory for routes it clears")
        #expect(controller.clearedDeviceRouteTarget(for: "org.mozilla.firefox") == "living-room",
                "an existing memory entry from an earlier resetDeviceRoute must be left untouched")
    }

    // MARK: Duplicate addRoute is a no-op

    @Test func duplicateAddRouteIsNoOp() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setVolume(55, for: "com.apple.Music")

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Different Name")

        #expect(controller.appRoutes.count == 1)
        #expect(controller.appRoutes[0].displayName == "Music", "duplicate add must not overwrite the existing route")
        #expect(controller.appRoutes[0].destination == .device(id: "homepod-1"))
        #expect(controller.appRoutes[0].volume == 55)
    }

    // MARK: Volume clamps

    @Test func setVolumeClamps() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")

        controller.setVolume(150, for: "com.apple.Music")
        #expect(controller.appRoutes[0].volume == 100)

        controller.setVolume(-20, for: "com.apple.Music")
        #expect(controller.appRoutes[0].volume == 0)
    }

    // MARK: No-op setDestination / setVolume must not rewrite the file

    @Test func noOpSetDestinationDoesNotRewriteFile() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.setDestination(.noRedirect, for: "com.apple.Music") // already .noRedirect (the new default)

        let after = try Data(contentsOf: fileURL)
        #expect(before == after, "setting the same destination must not rewrite the store")
    }

    @Test func noOpSetVolumeDoesNotRewriteFile() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music") // volume defaults to 100
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.setVolume(100, for: "com.apple.Music") // same value

        let after = try Data(contentsOf: fileURL)
        #expect(before == after, "setting the same volume must not rewrite the store")
    }

    @Test func noOpMutationsDoNotChangeState() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let before = controller.appRoutes

        controller.setDestination(.noRedirect, for: "com.apple.Music") // already .noRedirect (the new default)
        controller.setVolume(100, for: "com.apple.Music")
        controller.setDestination(.currentDevice, for: "unknown.bundle.id")
        controller.setVolume(50, for: "unknown.bundle.id")
        controller.removeRoute(bundleID: "unknown.bundle.id")

        #expect(controller.appRoutes == before)
    }

    // MARK: routedAppNames(for:) — feeds the DeviceRowView routing sublabel

    @Test func routedAppNamesFiltersByDeviceIDAndExcludesCurrentDevice() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")

        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setDestination(.device(id: "office"), for: "com.spotify.client")
        // com.apple.Safari stays .noRedirect (no redirect) — must be excluded.

        #expect(controller.routedAppNames(for: "homepod-1") == ["Music"])
        #expect(controller.routedAppNames(for: "office") == ["Spotify"])
        #expect(controller.routedAppNames(for: "some-other-device") == [],
                       "a device with no routes gets an empty list")
    }

    @Test func routedAppNamesExcludesNoRedirectAndCurrentDeviceRoutesEntirely() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        // Never redirected — stays .noRedirect (the new default).
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.currentDevice, for: "com.apple.Safari") // explicit local pick

        #expect(controller.routedAppNames(for: "homepod-1") == [],
                       "neither .noRedirect nor .currentDevice routes are ever routed to a device")
    }

    @Test func routedAppNamesPreservesStableRouteOrder() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "b", displayName: "Zebra App")
        controller.addRoute(bundleID: "a", displayName: "Alpha App")
        controller.addRoute(bundleID: "c", displayName: "Charlie App")

        controller.setDestination(.device(id: "homepod-1"), for: "b")
        controller.setDestination(.device(id: "homepod-1"), for: "a")
        controller.setDestination(.device(id: "homepod-1"), for: "c")

        #expect(controller.routedAppNames(for: "homepod-1") == ["Zebra App", "Alpha App", "Charlie App"],
                       "insertion order is preserved, not sorted")
    }

    @Test func routedAppNamesUpdatesWhenDestinationChanges() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        #expect(controller.routedAppNames(for: "homepod-1") == ["Music"])

        controller.setDestination(.currentDevice, for: "com.apple.Music")
        #expect(controller.routedAppNames(for: "homepod-1") == [],
                       "reverting to .currentDevice removes it from the routing set")
    }

    // MARK: onRoutesDidChange — the "routing table changed" signal (T7)
    //
    // T7 wires this callback to `AppRouteConfiguring.updateAppRoutes` so a route
    // change actually streams the app to its device via the per-app capture path
    // (replacing the removed whole-system output-set union). These tests pin that
    // the signal fires exactly on the change edge, and that hooking it to a backend
    // forwards the current table.

    @Test func onRoutesDidChangeFiresOnRealMutationsOnly() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        var fireCount = 0
        controller.onRoutesDidChange = { fireCount += 1 }

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")   // 1
        controller.setDestination(.device(id: "office"), for: "com.apple.Music") // 2
        controller.setVolume(30, for: "com.apple.Music")                         // 3
        #expect(fireCount == 3)

        // No-op mutations must NOT fire (they return before persist()).
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")   // dup — no-op
        controller.setDestination(.device(id: "office"), for: "com.apple.Music") // same dest — no-op
        controller.setVolume(30, for: "com.apple.Music")                         // same vol — no-op
        controller.removeRoute(bundleID: "not-present")                          // missing — no-op
        #expect(fireCount == 3, "no-op mutations don't fire the change signal")

        controller.removeRoute(bundleID: "com.apple.Music")                      // 4
        #expect(fireCount == 4)
    }

    /// Integration proof of the T7 wiring: hooking `onRoutesDidChange` to forward
    /// into an `AppRouteConfiguring` backend means every route change calls through
    /// to `updateAppRoutes` with the current table + excluded set — exactly what
    /// `AppDelegate.pushAppRoutesToBackend()` does in production.
    @Test func routeChangeCallsThroughToBackendUpdateAppRoutes() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        let backend = SpyAppRouteBackend()
        let excluded: Set<String> = ["com.example.excluded"]
        controller.onRoutesDidChange = {
            backend.updateAppRoutes(controller.appRoutes, excludedBundleIDs: excluded)
        }

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "office"), for: "com.apple.Music")

        #expect(backend.calls.count == 2, "each real mutation calls updateAppRoutes once")
        #expect(backend.calls.last?.routes == [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .device(id: "office"), volume: 100),
        ])
        #expect(backend.calls.last?.excluded == excluded,
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
