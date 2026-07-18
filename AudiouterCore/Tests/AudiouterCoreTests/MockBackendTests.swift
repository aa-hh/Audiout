import XCTest
@testable import AudiouterCore

final class MockBackendTests: XCTestCase {

    private let demoFleet = [Device].demoFleet

    /// Deterministic backend for tests: no discovery stagger, no timers.
    private func makeBackend(_ fleet: [Device] = .demoFleet) -> MockBackend {
        MockBackend(fleet: fleet, staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false)
    }

    /// Collect the next `count` non-level events. Fails if they don't arrive in time.
    private func collect(_ count: Int, from backend: MockBackend, timeout: TimeInterval = 2) async throws -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let expectation = expectation(description: "received \(count) events")
        let box = EventBox()
        let task = Task {
            for await event in stream {
                if case .level = event { continue }
                if await box.append(event) >= count { expectation.fulfill(); break }
            }
        }
        backend.start()
        await fulfillment(of: [expectation], timeout: timeout)
        task.cancel()
        return await box.events
    }

    func testDiscoveryEmitsWholeFleet() async throws {
        let backend = makeBackend()
        let events = try await collect(demoFleet.count, from: backend)
        let added = events.compactMap { if case .deviceAdded(let d) = $0 { return d.id } else { return nil } }
        XCTAssertEqual(Set(added), Set(demoFleet.map(\.id)))
    }

    func testDevicesSnapshotMatchesFleetAfterDiscovery() async throws {
        let backend = makeBackend()
        _ = try await collect(demoFleet.count, from: backend)
        XCTAssertEqual(backend.devices.map(\.id), demoFleet.map(\.id))
    }

    func testSetVolumeClampsAndEchoes() async throws {
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic, volume: 50)])
        let stream = backend.makeEventStream()
        backend.start()

        let box = DeviceBox()
        let done = expectation(description: "volume echoed")
        let task = Task {
            for await event in stream {
                if case .deviceUpdated(let d) = event, d.id == "a" {
                    await box.set(d); done.fulfill(); break
                }
            }
        }
        // wait for discovery, then over-drive the volume past the ceiling
        try await Task.sleep(nanoseconds: 200_000_000)
        backend.setVolume(150, for: "a")
        await fulfillment(of: [done], timeout: 2)
        task.cancel()
        let updated = await box.value
        XCTAssertEqual(updated?.volume, 100, "volume should clamp to 100")
    }

    func testSetOutputSetSelectsExactlyTheGivenDevices() async throws {
        let backend = makeBackend()
        _ = try await collect(demoFleet.count, from: backend)

        backend.setOutputSet(["office", "homepod-bed"])
        try await Task.sleep(nanoseconds: 200_000_000)

        let selected = Set(backend.devices.filter(\.isSelected).map(\.id))
        XCTAssertEqual(selected, ["office", "homepod-bed"])
    }

    func testNoOpChangeDoesNotEmit() async throws {
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
        XCTAssertFalse(sawUpdate, "a no-op change should not emit deviceUpdated")
    }

    func testUnscriptedEnableAndDisableAreStillSingleSynchronousEvents() async throws {
        // Backward-compat requirement (brief §5): a device with no script
        // keeps the exact current one-event-per-toggle behaviour, just now
        // also carrying `.connected`/`.off` in that same event.
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic)])
        _ = try await collect(1, from: backend)   // initial deviceAdded

        let stream = backend.makeEventStream()
        let box = DeviceBox()
        let done = expectation(description: "enabled")
        let task = Task {
            for await event in stream {
                if case .deviceUpdated(let d) = event, d.id == "a" {
                    await box.set(d); done.fulfill(); break
                }
            }
        }
        backend.setOutputSet(["a"])
        await fulfillment(of: [done], timeout: 2)
        task.cancel()
        let enabled = await box.value
        XCTAssertEqual(enabled?.isSelected, true)
        XCTAssertEqual(enabled?.connectionState, .connected)

        let stream2 = backend.makeEventStream()
        let box2 = DeviceBox()
        let done2 = expectation(description: "disabled")
        let task2 = Task {
            for await event in stream2 {
                if case .deviceUpdated(let d) = event, d.id == "a" {
                    await box2.set(d); done2.fulfill(); break
                }
            }
        }
        backend.setOutputSet([])
        await fulfillment(of: [done2], timeout: 2)
        task2.cancel()
        let disabled = await box2.value
        XCTAssertEqual(disabled?.isSelected, false)
        XCTAssertEqual(disabled?.connectionState, .off)
    }

    func testScriptedConnectGoesConnectingThenConnected() async throws {
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
        XCTAssertEqual(updates.map(\.connectionState), [.connecting, .connected])
        XCTAssertEqual(updates.last?.isSelected, true)
    }

    func testScriptedFailGoesConnectingThenFailedWithIsSelectedFalse() async throws {
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
        XCTAssertEqual(updates.map(\.connectionState), [.connecting, .failed(failure)])
        XCTAssertEqual(updates.last?.isSelected, false)
    }

    func testFailedStateIsStickyAcrossDeselect() async throws {
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
        XCTAssertEqual(cleanup.last?.connectionState, .failed(failure), "sticky-failed must survive deselect")
        XCTAssertEqual(cleanup.last?.isSelected, false)
    }

    func testRetryAfterFailureUsesTheSecondScriptedAttempt() async throws {
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
        XCTAssertEqual(retry.map(\.connectionState), [.connecting, .connected])
        XCTAssertEqual(retry.last?.isSelected, true)
    }

    func testConnectThenDropRecovers() async throws {
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
        XCTAssertEqual(updates.map(\.connectionState), [.connecting, .connected, .reconnecting, .connected])
        XCTAssertEqual(updates.last?.isSelected, true)
    }

    func testConnectThenDropFails() async throws {
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
        XCTAssertEqual(
            updates.map(\.connectionState),
            [.connecting, .connected, .reconnecting, .failed(ConnectionFailure(cause: .droppedMidStream))]
        )
        XCTAssertEqual(updates.last?.isSelected, false)
    }

    func testScenarioFactoryMapsEnvironmentToConnectionDemoScripts() {
        let none = MockBackend.resolveScenarioScripts(environment: [:])
        XCTAssertTrue(none.isEmpty, "no AIRPLAY_MOCK_SCENARIO → no scripting")

        let other = MockBackend.resolveScenarioScripts(environment: ["AIRPLAY_MOCK_SCENARIO": "something-else"])
        XCTAssertTrue(other.isEmpty)

        let scripts = MockBackend.resolveScenarioScripts(environment: ["AIRPLAY_MOCK_SCENARIO": "connection-demo"])
        guard case .fail(let after, let failure) = scripts["airport-mixer"]?.attempts.first else {
            return XCTFail("airport-mixer should start with a .fail attempt")
        }
        XCTAssertEqual(after, 1.5)
        XCTAssertEqual(failure.cause, .notResponding)
        guard case .connect = scripts["airport-mixer"]?.attempts.dropFirst().first else {
            return XCTFail("airport-mixer's retry attempt should be .connect")
        }

        guard case .connect(let sonosAfter) = scripts["sonos-move-2"]?.attempts.first else {
            return XCTFail("sonos-move-2 should be a plain slow .connect")
        }
        XCTAssertEqual(sonosAfter, 4.0)

        guard case .connectThenDrop(_, _, let recovers) = scripts["office"]?.attempts.first else {
            return XCTFail("office should be .connectThenDrop")
        }
        XCTAssertFalse(recovers)

        // Every other fleet device gets the plain quick-connect fallback.
        guard case .connect(let fallbackAfter) = scripts["homepod-bed"]?.attempts.first else {
            return XCTFail("unlisted devices should fall back to a plain .connect")
        }
        XCTAssertEqual(fallbackAfter, 0.8)
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
    func testEmitRoutedAppsFixtureFiresThroughTheEventStream() async throws {
        let backend = makeBackend()
        _ = try await collect(demoFleet.count, from: backend)   // drain discovery

        let stream = backend.makeEventStream()
        let expectation = expectation(description: "routedApps event received")
        let box = EventBox()
        let task = Task {
            for await event in stream {
                if case .routedApps = event {
                    _ = await box.append(event)
                    expectation.fulfill()
                    break
                }
            }
        }
        backend.test_emitRoutedApps(deviceID: "office", appNames: ["Music", "Safari"])
        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()

        guard case .routedApps(let deviceID, let appNames) = await box.events.first else {
            return XCTFail("expected a .routedApps event")
        }
        XCTAssertEqual(deviceID, "office")
        XCTAssertEqual(appNames, ["Music", "Safari"])
    }

    /// An empty `appNames` fixture is the "mapping cleared" case (matches
    /// `NativeBackend`'s real emission when a redirect leaves a device) — the
    /// fixture can produce it too, not just the non-empty case.
    func testEmitRoutedAppsFixtureCanEmitAnEmptyMapping() async throws {
        let backend = makeBackend()
        _ = try await collect(demoFleet.count, from: backend)

        let stream = backend.makeEventStream()
        let expectation = expectation(description: "empty routedApps event received")
        let box = EventBox()
        let task = Task {
            for await event in stream {
                if case .routedApps = event {
                    _ = await box.append(event)
                    expectation.fulfill()
                    break
                }
            }
        }
        backend.test_emitRoutedApps(deviceID: "office", appNames: [])
        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()

        guard case .routedApps(let deviceID, let appNames) = await box.events.first else {
            return XCTFail("expected a .routedApps event")
        }
        XCTAssertEqual(deviceID, "office")
        XCTAssertEqual(appNames, [])
    }
}

private extension MockBackendTests {
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
        let expectation = expectation(description: "\(count) updates for \(id)")
        let box = EventBox()
        let task = Task {
            for await event in stream {
                if case .deviceUpdated(let d) = event, d.id == id {
                    if await box.append(event) >= count { expectation.fulfill(); break }
                }
            }
        }
        action()
        await fulfillment(of: [expectation], timeout: timeout)
        task.cancel()
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
