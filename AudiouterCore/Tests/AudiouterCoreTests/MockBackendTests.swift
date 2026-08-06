import Foundation
import Testing
@testable import AudiouterCore

@Suite struct MockBackendTests {

    private let demoFleet = [Device].demoFleet

    /// Deterministic backend for tests: no discovery stagger, no timers.
    private func makeBackend(_ fleet: [Device] = .demoFleet) -> MockBackend {
        MockBackend(fleet: fleet, staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false)
    }

    /// Collect the next `count` non-level events. Fails if they don't arrive in time.
    private func collect(_ count: Int, from backend: MockBackend, timeout: TimeInterval = 2) async throws -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let box = EventBox()
        try await confirmation("received \(count) events") { received in
            let task = Task {
                for await event in stream {
                    if case .level = event { continue }
                    if await box.append(event) >= count { received(); break }
                }
            }
            defer { task.cancel() }
            backend.start()
            // The body must do the waiting itself — `confirmation` does not.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(timeout)) }
                try await group.next()
                group.cancelAll()
            }
        }
        return await box.events
    }

    @Test func discoveryEmitsWholeFleet() async throws {
        let backend = makeBackend()
        let events = try await collect(demoFleet.count, from: backend)
        let added = events.compactMap { if case .deviceAdded(let d) = $0 { return d.id } else { return nil } }
        #expect(Set(added) == Set(demoFleet.map(\.id)))
    }

    @Test func devicesSnapshotMatchesFleetAfterDiscovery() async throws {
        let backend = makeBackend()
        _ = try await collect(demoFleet.count, from: backend)
        #expect(backend.devices.map(\.id) == demoFleet.map(\.id))
    }

    @Test func setVolumeClampsAndEchoes() async throws {
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic, volume: 50)])
        let stream = backend.makeEventStream()
        backend.start()

        let box = DeviceBox()
        try await confirmation("volume echoed") { echoed in
            let task = Task {
                for await event in stream {
                    if case .deviceUpdated(let d) = event, d.id == "a" {
                        await box.set(d); echoed(); break
                    }
                }
            }
            defer { task.cancel() }
            // wait for discovery, then over-drive the volume past the ceiling
            try await Task.sleep(nanoseconds: 200_000_000)
            backend.setVolume(150, for: "a")
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }
        let updated = await box.value
        #expect(updated?.volume == 100, "volume should clamp to 100")
    }

    @Test func setOutputSetSelectsExactlyTheGivenDevices() async throws {
        let backend = makeBackend()
        _ = try await collect(demoFleet.count, from: backend)

        backend.setOutputSet(["office", "homepod-bed"])
        try await Task.sleep(nanoseconds: 200_000_000)

        let selected = Set(backend.devices.filter(\.isSelected).map(\.id))
        #expect(selected == ["office", "homepod-bed"])
    }

    @Test func noOpChangeDoesNotEmit() async throws {
        // Setting a device's volume to the value it already has must not echo.
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic, volume: 42)])
        _ = try await collect(1, from: backend)   // the initial deviceAdded

        let stream = backend.makeEventStream()
        let box = FlagBox()
        let task = Task {
            for await event in stream {
                if case .deviceUpdated = event { await box.raise() }
            }
        }
        backend.setVolume(42, for: "a")            // same value → no-op
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let sawUpdate = await box.value
        #expect(!sawUpdate, "a no-op change should not emit deviceUpdated")
    }

    @Test func unscriptedEnableAndDisableAreStillSingleSynchronousEvents() async throws {
        // Backward-compat requirement (brief §5): a device with no script
        // keeps the exact current one-event-per-toggle behaviour, just now
        // also carrying `.connected`/`.off` in that same event.
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic)])
        _ = try await collect(1, from: backend)   // initial deviceAdded

        let stream = backend.makeEventStream()
        let box = DeviceBox()
        try await confirmation("enabled") { enabled in
            let task = Task {
                for await event in stream {
                    if case .deviceUpdated(let d) = event, d.id == "a" {
                        await box.set(d); enabled(); break
                    }
                }
            }
            defer { task.cancel() }
            backend.setOutputSet(["a"])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }
        let enabledDevice = await box.value
        #expect(enabledDevice?.isSelected == true)
        #expect(enabledDevice?.connectionState == .connected)

        let stream2 = backend.makeEventStream()
        let box2 = DeviceBox()
        try await confirmation("disabled") { disabled in
            let task2 = Task {
                for await event in stream2 {
                    if case .deviceUpdated(let d) = event, d.id == "a" {
                        await box2.set(d); disabled(); break
                    }
                }
            }
            defer { task2.cancel() }
            backend.setOutputSet([])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task2.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }
        let disabledDevice = await box2.value
        #expect(disabledDevice?.isSelected == false)
        #expect(disabledDevice?.connectionState == .off)
    }

    @Test func scriptedConnectGoesConnectingThenConnected() async throws {
        let script = ConnectScript(attempts: [.connect(after: 0.1)])
        let backend = MockBackend(
            fleet: [Device(id: "a", name: "A", kind: .generic)],
            staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false,
            connectScripts: ["a": script]
        )
        _ = try await collectFleetDiscovery(backend)

        let updates = try await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])
        }
        #expect(updates.map(\.connectionState) == [.connecting, .connected])
        #expect(updates.last?.isSelected == true)
    }

    @Test func scriptedFailGoesConnectingThenFailedWithIsSelectedFalse() async throws {
        let failure = ConnectionFailure(cause: .notResponding)
        let backend = MockBackend(
            fleet: [Device(id: "a", name: "A", kind: .generic)],
            staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false,
            connectScripts: ["a": ConnectScript(attempts: [.fail(after: 0.1, failure)])]
        )
        _ = try await collectFleetDiscovery(backend)

        let updates = try await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])
        }
        #expect(updates.map(\.connectionState) == [.connecting, .failed(failure)])
        #expect(updates.last?.isSelected == false)
    }

    @Test func failedStateIsStickyAcrossDeselect() async throws {
        // §1: dropping a failed device from the expected set (the popover's
        // honest-toggle cleanup) must not erase the warning.
        let failure = ConnectionFailure(cause: .vanished)
        let backend = MockBackend(
            fleet: [Device(id: "a", name: "A", kind: .generic)],
            staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false,
            connectScripts: ["a": ConnectScript(attempts: [.fail(after: 0.1, failure)])]
        )
        _ = try await collectFleetDiscovery(backend)
        _ = try await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])
        }

        let cleanup = try await collectUpdates(for: "a", count: 1, from: backend) {
            backend.setOutputSet([])   // remove from expected set without retrying
        }
        #expect(cleanup.last?.connectionState == .failed(failure), "sticky-failed must survive deselect")
        #expect(cleanup.last?.isSelected == false)
    }

    @Test func retryAfterFailureUsesTheSecondScriptedAttempt() async throws {
        let failure = ConnectionFailure(cause: .notResponding)
        let backend = MockBackend(
            fleet: [Device(id: "a", name: "A", kind: .generic)],
            staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false,
            connectScripts: ["a": ConnectScript(attempts: [
                .fail(after: 0.1, failure),
                .connect(after: 0.1),
            ])]
        )
        _ = try await collectFleetDiscovery(backend)
        _ = try await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])       // attempt 1: fails
        }
        _ = try await collectUpdates(for: "a", count: 1, from: backend) {
            backend.setOutputSet([])          // cleanup (sticky-failed)
        }
        let retry = try await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])       // attempt 2: connects
        }
        #expect(retry.map(\.connectionState) == [.connecting, .connected])
        #expect(retry.last?.isSelected == true)
    }

    /// Storm fix (2026-08-06, reverses the earlier R12-era contract): a
    /// membership-NEUTRAL `setOutputSet` — the id still in the requested set,
    /// nothing added or removed — must NOT restart a `.failed` device's
    /// choreography. Under R12 every unrelated routing call re-issues the same
    /// set, and treating that as a retry is what made the autonomous retry
    /// storm self-sustaining. The deliberate retry is `retryOutput(_:)`, which
    /// `GroupController.retryConnection(for:)` now calls.
    @Test func membershipNeutralSetOutputSetDoesNotRetryButRetryOutputDoes() async throws {
        let failure = ConnectionFailure(cause: .notResponding)
        let backend = MockBackend(
            fleet: [Device(id: "a", name: "A", kind: .generic)],
            staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false,
            connectScripts: ["a": ConnectScript(attempts: [
                .fail(after: 0.1, failure),
                .connect(after: 0.1),
            ])]
        )
        _ = try await collectFleetDiscovery(backend)
        _ = try await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])       // attempt 1: fails
        }

        // "a" is still in the requested set (R12 never dropped it). Re-issuing
        // the SAME set is routing noise, not a retry — the device must stay in
        // its resting `.failed`, with attempt 2 left unconsumed.
        backend.setOutputSet(["a"])
        try await Task.sleep(nanoseconds: 300_000_000)
        let resting = try #require(backend.devices.first { $0.id == "a" })
        #expect(resting.connectionState == .failed(failure),
                "a membership-neutral setOutputSet must not restart a .failed device's script")

        // The dedicated retry entry point consumes attempt 2 and connects.
        let retry = try await collectUpdates(for: "a", count: 2, from: backend) {
            backend.retryOutput("a")
        }
        #expect(retry.map(\.connectionState) == [.connecting, .connected])
        #expect(retry.last?.isSelected == true)
    }

    @Test func connectThenDropRecovers() async throws {
        let backend = MockBackend(
            fleet: [Device(id: "a", name: "A", kind: .generic)],
            staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false,
            connectScripts: ["a": ConnectScript(attempts: [
                .connectThenDrop(connectAfter: 0.1, dropAfter: 0.1, recovers: true),
            ])]
        )
        _ = try await collectFleetDiscovery(backend)

        // connecting -> connected -> reconnecting -> connected
        let updates = try await collectUpdates(for: "a", count: 4, from: backend, timeout: 5) {
            backend.setOutputSet(["a"])
        }
        #expect(updates.map(\.connectionState) == [.connecting, .connected, .reconnecting, .connected])
        #expect(updates.last?.isSelected == true)
    }

    @Test func connectThenDropFails() async throws {
        let backend = MockBackend(
            fleet: [Device(id: "a", name: "A", kind: .generic)],
            staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false,
            connectScripts: ["a": ConnectScript(attempts: [
                .connectThenDrop(connectAfter: 0.1, dropAfter: 0.1, recovers: false),
            ])]
        )
        _ = try await collectFleetDiscovery(backend)

        let updates = try await collectUpdates(for: "a", count: 4, from: backend, timeout: 5) {
            backend.setOutputSet(["a"])
        }
        #expect(
            updates.map(\.connectionState) ==
            [.connecting, .connected, .reconnecting, .failed(ConnectionFailure(cause: .droppedMidStream))]
        )
        #expect(updates.last?.isSelected == false)
    }

    @Test func scenarioFactoryMapsEnvironmentToConnectionDemoScripts() {
        let none = MockBackend.resolveScenarioScripts(environment: [:])
        #expect(none.isEmpty, "no AIRPLAY_MOCK_SCENARIO → no scripting")

        let other = MockBackend.resolveScenarioScripts(environment: ["AIRPLAY_MOCK_SCENARIO": "something-else"])
        #expect(other.isEmpty)

        let scripts = MockBackend.resolveScenarioScripts(environment: ["AIRPLAY_MOCK_SCENARIO": "connection-demo"])
        guard case .fail(let after, let failure) = scripts["airport-mixer"]?.attempts.first else {
            Issue.record("airport-mixer should start with a .fail attempt")
            return
        }
        #expect(after == 1.5)
        #expect(failure.cause == .notResponding)
        guard case .connect = scripts["airport-mixer"]?.attempts.dropFirst().first else {
            Issue.record("airport-mixer's retry attempt should be .connect")
            return
        }

        guard case .connect(let sonosAfter) = scripts["sonos-move-2"]?.attempts.first else {
            Issue.record("sonos-move-2 should be a plain slow .connect")
            return
        }
        #expect(sonosAfter == 4.0)

        guard case .connectThenDrop(_, _, let recovers) = scripts["office"]?.attempts.first else {
            Issue.record("office should be .connectThenDrop")
            return
        }
        #expect(!recovers)

        // Every other fleet device gets the plain quick-connect fallback.
        guard case .connect(let fallbackAfter) = scripts["homepod-bed"]?.attempts.first else {
            Issue.record("unlisted devices should fall back to a plain .connect")
            return
        }
        #expect(fallbackAfter == 0.8)
    }

    // MARK: T9 — offline `.routedApps` fixture
    //
    // `MockBackend` has no per-app capture of its own (only `NativeBackend`
    // emits `.routedApps` organically); `test_emitRoutedApps` is the offline
    // escape hatch T9 gives `popover-harness`/`popover-snapshot`/tests for
    // exercising the live per-device streaming indicator without a real
    // per-app-routing backend.

    /// The fixture's event reaches a subscriber through the real
    /// `makeEventStream()` channel, carrying the exact deviceID + appNames
    /// given — same channel every other `BackendEvent` travels.
    @Test func emitRoutedAppsFixtureFiresThroughTheEventStream() async throws {
        let backend = makeBackend()
        _ = try await collect(demoFleet.count, from: backend)   // drain discovery

        let stream = backend.makeEventStream()
        let box = EventBox()
        try await confirmation("routedApps event received") { received in
            let task = Task {
                for await event in stream {
                    if case .routedApps = event {
                        _ = await box.append(event)
                        received()
                        break
                    }
                }
            }
            defer { task.cancel() }
            backend.test_emitRoutedApps(deviceID: "office", appNames: ["Music", "Safari"])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }

        guard case .routedApps(let deviceID, let appNames) = await box.events.first else {
            Issue.record("expected a .routedApps event")
            return
        }
        #expect(deviceID == "office")
        #expect(appNames == ["Music", "Safari"])
    }

    /// An empty `appNames` fixture is the "mapping cleared" case (matches
    /// `NativeBackend`'s real emission when a redirect leaves a device) — the
    /// fixture can produce it too, not just the non-empty case.
    @Test func emitRoutedAppsFixtureCanEmitAnEmptyMapping() async throws {
        let backend = makeBackend()
        _ = try await collect(demoFleet.count, from: backend)

        let stream = backend.makeEventStream()
        let box = EventBox()
        try await confirmation("empty routedApps event received") { received in
            let task = Task {
                for await event in stream {
                    if case .routedApps = event {
                        _ = await box.append(event)
                        received()
                        break
                    }
                }
            }
            defer { task.cancel() }
            backend.test_emitRoutedApps(deviceID: "office", appNames: [])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }

        guard case .routedApps(let deviceID, let appNames) = await box.events.first else {
            Issue.record("expected a .routedApps event")
            return
        }
        #expect(deviceID == "office")
        #expect(appNames == [])
    }

    // MARK: T7 — offline `.appLevel` fixtures

    /// `test_emitAppLevel`'s event reaches a subscriber through the real
    /// `makeEventStream()` channel, carrying the exact bundleID + rms given —
    /// same channel every other `BackendEvent` travels, mirroring
    /// `test_emitRoutedApps`.
    @Test func emitAppLevelFixtureFiresThroughTheEventStream() async throws {
        let backend = makeBackend()
        _ = try await collect(demoFleet.count, from: backend)   // drain discovery

        let stream = backend.makeEventStream()
        let box = EventBox()
        try await confirmation("appLevel event received") { received in
            let task = Task {
                for await event in stream {
                    if case .appLevel = event {
                        _ = await box.append(event)
                        received()
                        break
                    }
                }
            }
            defer { task.cancel() }
            backend.test_emitAppLevel(bundleID: "com.apple.Music", rms: 0.42)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }

        guard case .appLevel(let bundleID, let rms) = await box.events.first else {
            Issue.record("expected an .appLevel event")
            return
        }
        #expect(bundleID == "com.apple.Music")
        #expect(rms == 0.42)
    }

    /// `test_setMeteredApps` registers bundle IDs the level timer should also
    /// fabricate `.appLevel` samples for, on the exact same
    /// `meteringActive`/`emitsLevels` gate as the device `.level` timer
    /// (T-GATE): silent by default, then animating every listed app once the
    /// popover-visibility gate flips on — regardless of whether that app is
    /// actually routed anywhere, since the mock has no route table of its own.
    @Test func meteredAppsEmitAppLevelOnlyWhileMeteringActive() async throws {
        let backend = MockBackend(
            fleet: demoFleet, staggerDiscovery: false, emitsLevels: true, simulatesDropouts: false
        )
        backend.test_setMeteredApps(["com.apple.Music", "com.apple.Podcasts"])
        _ = try await collect(demoFleet.count, from: backend)   // drain discovery; metering still inactive

        let stream = backend.makeEventStream()
        let box = EventBox()
        let collector = Task {
            for await event in stream { _ = await box.append(event) }
        }

        // Default: metering inactive, so no `.appLevel` should show up yet.
        try? await Task.sleep(nanoseconds: 200_000_000)
        var seen = await box.events
        #expect(
            !seen.contains { if case .appLevel = $0 { return true } else { return false } },
            "no .appLevel may be emitted while metering is inactive"
        )

        // Flip metering on: both registered apps must start showing up.
        backend.setMeteringActive(true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        seen = await box.events
        let seenBundleIDs = Set(seen.compactMap { event -> String? in
            if case .appLevel(let bundleID, _) = event { return bundleID } else { return nil }
        })
        #expect(seenBundleIDs == ["com.apple.Music", "com.apple.Podcasts"])

        collector.cancel()
    }
}

extension MockBackendTests {
    /// Discover the (single-device) fleet used by the scripted-choreography
    /// tests below, starting the backend.
    func collectFleetDiscovery(_ backend: MockBackend, timeout: TimeInterval = 2) async throws -> [BackendEvent] {
        try await collect(1, from: backend, timeout: timeout)
    }

    /// Run `action`, then collect the next `count` `deviceUpdated` events for
    /// `id` that follow it.
    func collectUpdates(
        for id: String, count: Int, from backend: MockBackend, timeout: TimeInterval = 4,
        after action: () -> Void
    ) async throws -> [Device] {
        let stream = backend.makeEventStream()
        let box = EventBox()
        try await confirmation("\(count) updates for \(id)") { received in
            let task = Task {
                for await event in stream {
                    if case .deviceUpdated(let d) = event, d.id == id {
                        if await box.append(event) >= count { received(); break }
                    }
                }
            }
            defer { task.cancel() }
            action()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(timeout)) }
                try await group.next()
                group.cancelAll()
            }
        }
        let events = await box.events
        return events.compactMap { if case .deviceUpdated(let d) = $0 { return d } else { return nil } }
    }
}

// Small actors to carry mutable state across the async boundary without races.

private actor EventBox {
    private(set) var events: [BackendEvent] = []
    func append(_ event: BackendEvent) -> Int { events.append(event); return events.count }
}

private actor DeviceBox {
    private(set) var value: Device?
    func set(_ device: Device) { value = device }
}

private actor FlagBox {
    private(set) var value = false
    func raise() { value = true }
}
