import XCTest
@testable import AirPlayControllerCore

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
