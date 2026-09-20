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

        // MARK: Newer schema quarantines the file instead of leaving it in place

        /// An older build that reads a newer-schema file leaves it in place today,
        /// and the caller's first save atomically overwrites it, destroying the
        /// newer build's data. The file must be quarantined on the way to the
        /// nil/empty fallback, same as a corrupt file.
        @Test func newerSchemaFileIsQuarantinedBeforeReturningEmpty() throws {
            let cases: [(fileName: String, payload: String, load: (URL) throws -> Void)] = [
                ("app-routes.json", #"{"schemaVersion": 999, "routes": []}"#, {
                    _ = try AppRouteStore(directory: $0).load()
                }),
                ("groups.json", #"{"schemaVersion": 999, "groups": []}"#, {
                    _ = try GroupStore(directory: $0).load()
                }),
                ("routing.json", #"{"schemaVersion": 999, "state": {"selectedDeviceIDs": [], "mainOutKind": "selected"}}"#, {
                    _ = try RoutingStore(directory: $0).load()
                }),
                ("device-eq.json", #"{"schemaVersion": 999, "devices": {}}"#, {
                    _ = try DeviceEQStore(directory: $0).load()
                }),
                ("device-icons.json", #"{"schemaVersion": 999, "icons": {}}"#, {
                    _ = try DeviceIconStore(directory: $0).load()
                }),
                ("hidden-speakers.json", #"{"schemaVersion": 999, "deviceIDs": []}"#, {
                    _ = try HiddenSpeakersStore(directory: $0).load()
                }),
                ("excluded-apps.json", #"{"schemaVersion": 999, "apps": []}"#, {
                    _ = try ExcludedAppsStore(directory: $0).load()
                }),
                ("bt-sync-trims.json", #"{"schemaVersion": 999, "trims": {}}"#, {
                    _ = try BTTrimStore(directory: $0).load()
                }),
                ("bt-hardware-volume.json", #"{"schemaVersion": 999, "disabledUIDs": []}"#, {
                    _ = BTHardwareVolumeStore(directory: $0)
                }),
            ]

            for testCase in cases {
                let base = (testCase.fileName as NSString).deletingPathExtension
                let dir = try directory("newer-\(base)")
                try Data(testCase.payload.utf8).write(to: dir.appendingPathComponent(testCase.fileName))
                try testCase.load(dir)
                try expectSetAside(testCase.fileName, in: dir)
            }
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

        // MARK: CompanionApprovalStore — the tenth store, plus its save-failure path

        /// Defect: a newer-schema approvals file is left in place, and the first
        /// approval this build records overwrites it atomically, losing every
        /// phone the newer build had approved.
        @Test func companionApprovalStoreQuarantinesNewerSchemaFile() throws {
            let dir = try directory("companion-approvals-newer")
            let json = #"{"schemaVersion": 999, "approvals": []}"#
            try Data(json.utf8).write(to: dir.appendingPathComponent("companion-approvals.json"))
            #expect(try CompanionApprovalStore(directory: dir).load() == nil)
            try expectSetAside("companion-approvals.json", in: dir)
        }

        /// Defect: a corrupt approvals file is left in place and the first new
        /// approval overwrites the evidence, with every approved phone
        /// re-prompting and no record of why.
        @Test func companionApprovalStoreQuarantinesCorruptFile() throws {
            let dir = try directory("companion-approvals")
            try writeGarbage("companion-approvals.json", in: dir)
            let store = CompanionApprovalStore(directory: dir)
            #expect(throws: (any Error).self) { try store.load() }
            try expectSetAside("companion-approvals.json", in: dir)
            #expect(try store.load() == nil)
        }

        /// Defect: a failed approvals save goes only to stderr, so the user is
        /// never told their phone approval did not reach disk.
        @Test func companionApprovalWriteFailureFiresHandler() throws {
            // A FILE where the store wants a directory: `createDirectory` cannot
            // make one underneath it, so the save fails for a real reason.
            let blocker = scratchDir.appendingPathComponent("blocker-approvals")
            try Data().write(to: blocker)
            let controller = CompanionApprovalController(
                store: CompanionApprovalStore(directory: blocker.appendingPathComponent("x")))

            let failures = FailureCounter()
            StoreRecovery.onWriteFailure = { _ in failures.count += 1 }
            defer { StoreRecovery.onWriteFailure = nil }

            controller.presentPrompt = { _, respond in respond(true) }
            controller.handleRequest(clientID: "test-client", clientName: "Test Phone") { _ in }

            #expect(failures.count == 1)
            #expect(controller.approvals.count == 1,
                    "the in-memory approval survives — only the disk write failed")
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
