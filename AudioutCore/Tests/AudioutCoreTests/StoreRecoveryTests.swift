// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// Nested under `SerializedSharedState` because `StoreRecovery`'s handler and
/// quarantine list are process-global — `onWriteFailure` in particular is one
/// slot two concurrent tests would tear out from under each other.
extension SerializedSharedState {

    @Suite final class StoreRecoveryTests: IsolatedSuite {

        // MARK: Fixtures

        /// A fresh subdirectory of this test's scratch space, so each store's
        /// quarantine leaves exactly one set-aside file to count.
        private func directory(_ name: String) throws -> URL {
            let dir = scratchDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        private func writeGarbage(_ fileName: String, in dir: URL) throws {
            try Data("not json".utf8).write(to: dir.appendingPathComponent(fileName))
        }

        /// The whole point of the feature: the unreadable file is MOVED, not
        /// left in place for the next save to overwrite, and it is named.
        private func expectSetAside(_ fileName: String, in dir: URL) throws {
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path),
                    "the corrupt file must be moved out of the way of the next save")
            let setAside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.contains(".corrupt-") && $0.hasSuffix(".json") }
            #expect(setAside.count == 1, "expected one set-aside copy, found \(setAside)")
            // `contains`, not equality: the list is process-global and accumulates
            // across every test in this suite.
            #expect(StoreRecovery.quarantinedFileNames.contains(fileName))
        }

        // MARK: One per store

        @Test func groupStoreQuarantinesCorruptFile() throws {
            let dir = try directory("groups")
            try writeGarbage("groups.json", in: dir)
            let store = GroupStore(directory: dir)
            #expect(throws: (any Error).self) { try store.load() }
            try expectSetAside("groups.json", in: dir)
            #expect(try store.load().isEmpty, "second load falls back to the empty default")
        }

        @Test func routingStoreQuarantinesCorruptFile() throws {
            let dir = try directory("routing")
            try writeGarbage("routing.json", in: dir)
            let store = RoutingStore(directory: dir)
            #expect(throws: (any Error).self) { try store.load() }
            try expectSetAside("routing.json", in: dir)
            #expect(try store.load() == nil)
        }

        @Test func appRouteStoreQuarantinesCorruptFile() throws {
            let dir = try directory("app-routes")
            try writeGarbage("app-routes.json", in: dir)
            let store = AppRouteStore(directory: dir)
            #expect(throws: (any Error).self) { try store.load() }
            try expectSetAside("app-routes.json", in: dir)
            #expect(try store.load() == nil)
        }

        @Test func excludedAppsStoreQuarantinesCorruptFile() throws {
            let dir = try directory("excluded-apps")
            try writeGarbage("excluded-apps.json", in: dir)
            let store = ExcludedAppsStore(directory: dir)
            #expect(throws: (any Error).self) { try store.load() }
            try expectSetAside("excluded-apps.json", in: dir)
            #expect(try store.load() == nil)
        }

        @Test func deviceIconStoreQuarantinesCorruptFile() throws {
            let dir = try directory("device-icons")
            try writeGarbage("device-icons.json", in: dir)
            let store = DeviceIconStore(directory: dir)
            #expect(throws: (any Error).self) { try store.load() }
            try expectSetAside("device-icons.json", in: dir)
            #expect(try store.load() == nil)
        }

        @Test func deviceEQStoreQuarantinesCorruptFile() throws {
            let dir = try directory("device-eq")
            try writeGarbage("device-eq.json", in: dir)
            let store = DeviceEQStore(directory: dir)
            #expect(throws: (any Error).self) { try store.load() }
            try expectSetAside("device-eq.json", in: dir)
            #expect(try store.load() == nil)
        }

        @Test func btTrimStoreQuarantinesCorruptFile() throws {
            let dir = try directory("bt-sync-trims")
            try writeGarbage("bt-sync-trims.json", in: dir)
            let store = BTTrimStore(directory: dir)
            #expect(throws: (any Error).self) { try store.load() }
            try expectSetAside("bt-sync-trims.json", in: dir)
            #expect(try store.load() == nil)
        }

        // MARK: Nothing to set aside

        @Test func quarantineOnMissingFileRecordsNothing() throws {
            let dir = try directory("empty")
            let before = StoreRecovery.quarantinedFileNames
            StoreRecovery.quarantine(dir.appendingPathComponent("never-written.json"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
            #expect(StoreRecovery.quarantinedFileNames == before, "a failed move records nothing")
        }

        // MARK: Through a real caller

        /// The stores throw, but every caller swallows that with `try?`. This
        /// pins that the quarantine still happens on the way past.
        @Test func corruptGroupsFileIsSetAsideByTheControllersOwnLoad() async throws {
            let dir = try directory("controller-groups")
            try writeGarbage("groups.json", in: dir)
            let backend = try await makeBackend()
            let controller = GroupController(backend: backend,
                                             store: GroupStore(directory: dir),
                                             settings: AppSettings(defaults: isolatedDefaults),
                                             loadPersisted: true)
            #expect(controller.groups.isEmpty)
            try expectSetAside("groups.json", in: dir)
        }

        @Test func writeFailureFiresHandler() throws {
            // A FILE where the store wants a directory: `createDirectory` cannot
            // make one underneath it, so the save fails for a real reason.
            let blocker = scratchDir.appendingPathComponent("blocker")
            try Data().write(to: blocker)
            let controller = AppRoutingController(
                store: AppRouteStore(directory: blocker.appendingPathComponent("x")),
                loadPersisted: false)

            let failures = FailureCounter()
            StoreRecovery.onWriteFailure = { _ in failures.count += 1 }
            defer { StoreRecovery.onWriteFailure = nil }

            controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")

            #expect(failures.count == 1)
            #expect(controller.appRoutes.count == 1,
                    "the in-memory change survives — only the disk write failed")
        }

        /// Reference box so the handler (an escaping closure) can report back.
        private final class FailureCounter {
            var count = 0
        }

        // MARK: Backend fixture (shape copied from `GroupControllerTests`)

        /// Deterministic backend: no discovery stagger, no timers, pre-populated
        /// synchronously via a blocking discovery wait.
        private func makeBackend(_ fleet: [Device] = .demoFleet) async throws -> MockBackend {
            let backend = MockBackend(fleet: fleet, staggerDiscovery: false, emitsLevels: false,
                                      simulatesDropouts: false)
            let stream = backend.makeEventStream()
            let box = DiscoveryCountBox()
            try await confirmation("fleet discovered") { discovered in
                let task = Task {
                    for await event in stream {
                        if case .deviceAdded = event, await box.increment() >= fleet.count {
                            discovered(); break
                        }
                    }
                }
                defer { task.cancel() }
                backend.start()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { _ = await task.value }
                    group.addTask { try await Task.sleep(for: .seconds(2)) }
                    try await group.next()
                    group.cancelAll()
                }
            }
            return backend
        }
    }
}

private actor DiscoveryCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
