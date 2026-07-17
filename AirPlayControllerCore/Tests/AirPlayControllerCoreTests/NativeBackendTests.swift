import XCTest
import AirPlayEngine
@testable import AirPlayControllerCore

/// Hermetic tests for ``NativeBackend`` (T-NB-BACKEND-1): a spy ``EngineControlling``
/// (records ops, fires synthetic state transitions) + an injected ``DiscoverySource``
/// double (feeds `DiscoveryEvent`s synchronously). No engine thread, no C cluster,
/// no `NWBrowser`, no network, no TCC.
///
/// Covers: `deviceAdded` on discovery, AP1 surfaced-unavailable-and-never-added,
/// `deviceUpdated` on an out-of-band engine state transition, best-effort
/// convergence (D4), and the mute stash/restore shim.
final class NativeBackendTests: XCTestCase {

    // MARK: Doubles

    /// Records every engine op and lets a test drive the device-state stream.
    private final class SpyEngine: EngineControlling, @unchecked Sendable {
        let lock = NSLock()
        private(set) var started = false
        private(set) var stopped = false
        private(set) var discoveryFed: [OutputID] = []
        private(set) var discoveryRemoved: [String] = []   // descriptor names
        private(set) var added: [OutputID] = []
        private(set) var removed: [OutputID] = []
        private(set) var volumes: [(OutputID, Double)] = []
        private(set) var bufferSets: [Int] = []
        /// Interleaved op order (`remove:N` / `setBuffer:N` / `add:N` /
        /// `volume:N`) — the applyStartBuffer invariant is about ORDER across
        /// op kinds (all removes, then the buffer set, then re-adds), which the
        /// per-kind arrays above can't express.
        private(set) var opLog: [String] = []

        /// Ids that should THROW on `addOutput` (best-effort partial-failure test).
        var addFailures: Set<UInt64> = []
        /// Ids that should THROW on `removeOutput`.
        var removeFailures: Set<UInt64> = []

        private var continuation: AsyncStream<(OutputID, OutputState)>.Continuation?

        func start() async throws { lock.withLock { started = true } }
        func stop() async { lock.withLock { stopped = true } }

        @discardableResult
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            let id = descriptor.parsedID ?? OutputID(rawValue: 0)
            lock.withLock { discoveryFed.append(id) }
            return id
        }
        func removeDiscovery(_ descriptor: DeviceDescriptor) async {
            lock.withLock { discoveryRemoved.append(descriptor.name) }
        }
        func addOutput(_ id: OutputID) async throws {
            lock.withLock { added.append(id); opLog.append("add:\(id.rawValue)") }
            if addFailures.contains(id.rawValue) { throw AirPlayEngineError.sessionFailed }
        }
        func removeOutput(_ id: OutputID) async throws {
            lock.withLock { removed.append(id); opLog.append("remove:\(id.rawValue)") }
            if removeFailures.contains(id.rawValue) { throw AirPlayEngineError.sessionFailed }
        }
        func setVolume(_ id: OutputID, _ volume: Double) async throws {
            lock.withLock { volumes.append((id, volume)); opLog.append("volume:\(id.rawValue)") }
        }
        func setStartBufferMs(_ ms: Int) async {
            lock.withLock { bufferSets.append(ms); opLog.append("setBuffer:\(ms)") }
        }
        func makeStateStream() -> AsyncStream<(OutputID, OutputState)> {
            AsyncStream { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }
        /// Push a synthetic out-of-band transition through the state stream.
        func pushState(_ id: OutputID, _ state: OutputState) {
            let c = lock.withLock { continuation }
            c?.yield((id, state))
        }

        // Thread-safe snapshots for assertions.
        var addedIDs: [OutputID] { lock.withLock { added } }
        var removedIDs: [OutputID] { lock.withLock { removed } }
        var fedIDs: [OutputID] { lock.withLock { discoveryFed } }
        var discoveryRemovedNames: [String] { lock.withLock { discoveryRemoved } }
        var volumeCalls: [(OutputID, Double)] { lock.withLock { volumes } }
        var bufferSetCalls: [Int] { lock.withLock { bufferSets } }
        var ops: [String] { lock.withLock { opLog } }
        var didStart: Bool { lock.withLock { started } }
    }

    /// Feeds `DiscoveryEvent`s to the backend synchronously.
    private final class FakeDiscovery: DiscoverySource, @unchecked Sendable {
        var onEvent: (@Sendable (DiscoveryEvent) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
        func fire(_ event: DiscoveryEvent) { onEvent?(event) }
    }

    // MARK: Fixtures

    private func ap2Device(id: String = "AA:BB:CC:DD:EE:01", name: String = "Sonos Move", model: String = "S13") -> DiscoveredDevice {
        let txt = ["deviceid": id, "model": model, "features": "0x445F8A00,0x1C340"]
        let (parsedID, outputID) = NativeDiscovery.parseDeviceID(txt)!
        let desc = DeviceDescriptor(name: name, address: "192.168.1.10", family: .ipv4, port: 7000, txtRecord: txt)
        return DiscoveredDevice(id: parsedID, descriptor: desc, outputID: outputID, isAirPlay2Supported: true)
    }

    private func ap1Device(id: String = "AA:BB:CC:DD:EE:99", name: String = "Old Express") -> DiscoveredDevice {
        let txt = ["deviceid": id, "model": "AirPort4,107"]
        let (parsedID, outputID) = NativeDiscovery.parseDeviceID(txt)!
        let desc = DeviceDescriptor(name: name, address: "192.168.1.20", family: .ipv4, port: 5000, txtRecord: txt)
        return DiscoveredDevice(id: parsedID, descriptor: desc, outputID: outputID, isAirPlay2Supported: false)
    }

    private func makeBackend() -> (NativeBackend, SpyEngine, FakeDiscovery) {
        let engine = SpyEngine()
        let discovery = FakeDiscovery()
        let backend = NativeBackend(engineControl: engine, discoverySource: discovery)
        return (backend, engine, discovery)
    }

    /// Collect non-level events until `predicate` holds or timeout.
    private func collect(
        from backend: NativeBackend,
        timeout: TimeInterval = 3,
        until predicate: @escaping @Sendable ([BackendEvent]) -> Bool
    ) async -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let done = expectation(description: "predicate satisfied")
        let box = EventBox()
        let task = Task {
            for await event in stream {
                if case .level = event { continue }
                let all = await box.append(event)
                if predicate(all) { done.fulfill(); break }
            }
        }
        await fulfillment(of: [done], timeout: timeout)
        task.cancel()
        return await box.snapshot()
    }

    private actor EventBox {
        private var events: [BackendEvent] = []
        func append(_ e: BackendEvent) -> [BackendEvent] { events.append(e); return events }
        func snapshot() -> [BackendEvent] { events }
    }

    private func waitUntilStarted(_ engine: SpyEngine) async {
        for _ in 0..<200 {
            if engine.didStart { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Tests

    /// An AP2 discovery `.appeared` surfaces `deviceAdded` (available, AP2) and
    /// feeds the engine's descriptor so it becomes addOutput-able.
    func testDiscoveryAppearedEmitsDeviceAddedAndFeedsEngine() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        let added = events.compactMap { if case .deviceAdded(let d) = $0 { return d } else { return nil } }
        let d = added.first { $0.id == device.id }
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.supportsAirPlay2, true)
        XCTAssertEqual(d?.isAvailable, true)
        XCTAssertEqual(d?.name, "Sonos Move")
        XCTAssertEqual(d?.kind, .sonos)

        // The engine got the AP2 descriptor.
        await pollUntil { engine.fedIDs.contains(device.outputID) }
        XCTAssertTrue(engine.fedIDs.contains(device.outputID), "AP2 device should be fed to the engine")
    }

    /// An AP1-only device is surfaced `deviceAdded` with supportsAirPlay2=false AND
    /// isAvailable=false, is NEVER fed to the engine, and is NEVER addOutput-ed even
    /// when included in a `setOutputSet`.
    func testAirPlay1SurfacedUnavailableNeverAdded() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap1 = ap1Device()
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap1.id } else { return false } }
        } after: { discovery.fire(.appeared(ap1)) }

        let d = events.compactMap { if case .deviceAdded(let x) = $0 { return x } else { return nil } }.first { $0.id == ap1.id }
        XCTAssertEqual(d?.supportsAirPlay2, false)
        XCTAssertEqual(d?.isAvailable, false, "AP1-only device must be surfaced unavailable (D6)")

        // Never fed to the engine.
        XCTAssertTrue(engine.fedIDs.isEmpty, "AP1 device must NOT be fed to the AP2 engine")

        // Even if the app tries to select it, it is never addOutput-ed.
        backend.setOutputSet([ap1.id])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(engine.addedIDs.isEmpty, "AP1 device must NEVER be addOutput-ed (D6)")
    }

    /// An out-of-band engine state transition (`.streaming` → `.failed` after the
    /// op resolved) emits a `deviceUpdated` marking the device unavailable.
    func testEngineStateTransitionEmitsDeviceUpdated() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Out-of-band failure arrives on the state stream (receiver dropped RTSP).
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == device.id && !d.isAvailable } else { return false } }
        } after: { engine.pushState(device.outputID, .failed) }

        XCTAssertTrue(events.contains {
            if case .deviceUpdated(let d) = $0 { return d.id == device.id && !d.isAvailable && !d.isSelected }
            else { return false }
        }, "an out-of-band .failed transition should mark the device unavailable + deselected")
    }

    /// `setOutputSet` best-effort convergence (D4): with two AP2 devices where one
    /// add fails, the succeeding one stays selected, the failing one is marked
    /// unavailable + not selected, and NOTHING is rolled back.
    func testBestEffortConvergencePartialFailure() async {
        let (backend, engine, discovery) = makeBackend()
        let ok = ap2Device(id: "AA:BB:CC:DD:EE:01", name: "Good")
        let bad = ap2Device(id: "AA:BB:CC:DD:EE:02", name: "Bad")
        engine.addFailures = [bad.outputID.rawValue]

        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        _ = await collect(from: backend) { events in
            events.filter { if case .deviceAdded = $0 { return true } else { return false } }.count >= 2
        } after: {
            discovery.fire(.appeared(ok))
            discovery.fire(.appeared(bad))
        }

        backend.setOutputSet([ok.id, bad.id])

        // Both adds were ATTEMPTED (no rollback of the good one).
        await pollUntil { engine.addedIDs.contains(ok.outputID) && engine.addedIDs.contains(bad.outputID) }
        XCTAssertTrue(engine.addedIDs.contains(ok.outputID))
        XCTAssertTrue(engine.addedIDs.contains(bad.outputID))
        XCTAssertFalse(engine.removedIDs.contains(ok.outputID), "the succeeding add must NOT be rolled back (D4)")

        // Final model: good = selected/available; bad = unavailable/not selected.
        await pollUntil {
            let devs = backend.devices
            let g = devs.first { $0.id == ok.id }
            let b = devs.first { $0.id == bad.id }
            return g?.isSelected == true && b?.isSelected == false && b?.isAvailable == false
        }
        let devs = backend.devices
        XCTAssertEqual(devs.first { $0.id == ok.id }?.isSelected, true)
        XCTAssertEqual(devs.first { $0.id == bad.id }?.isSelected, false)
        XCTAssertEqual(devs.first { $0.id == bad.id }?.isAvailable, false)
    }

    /// applyStartBuffer's core invariant (PLAN-LATENCY-SETTING.md §2): ALL
    /// streaming outputs are removed BEFORE the engine buffer set, which
    /// precedes every re-add — otherwise a surviving session keeps the shared
    /// master session (and its old buffer) alive and the re-adds silently join
    /// it. Also: volumes re-pushed after re-add, model re-selected, and the
    /// stored `startBufferMs` reflects the new value.
    func testApplyStartBufferRemovesAllThenSetsThenReadds() async {
        let (backend, engine, discovery) = makeBackend()
        let d1 = ap2Device(id: "AA:BB:CC:DD:EE:01", name: "Kitchen")
        let d2 = ap2Device(id: "AA:BB:CC:DD:EE:02", name: "Lounge")

        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        _ = await collect(from: backend) { events in
            events.filter { if case .deviceAdded = $0 { return true } else { return false } }.count >= 2
        } after: {
            discovery.fire(.appeared(d1))
            discovery.fire(.appeared(d2))
        }

        backend.setOutputSet([d1.id, d2.id])
        await pollUntil {
            let devs = backend.devices
            return devs.first { $0.id == d1.id }?.isSelected == true
                && devs.first { $0.id == d2.id }?.isSelected == true
        }

        // Baseline AFTER the initial converge — its add/volume ops are not part
        // of the apply sequence under test.
        let baseline = engine.ops.count
        await backend.applyStartBuffer(ms: 1500)

        XCTAssertEqual(backend.startBufferMs, 1500)
        XCTAssertEqual(engine.bufferSetCalls, [1500])

        let ops = Array(engine.ops.dropFirst(baseline))
        guard let setIndex = ops.firstIndex(of: "setBuffer:1500") else {
            return XCTFail("engine never saw the buffer set; ops: \(ops)")
        }
        let before = ops[..<setIndex]
        let after = ops[setIndex...]
        XCTAssertTrue(before.contains("remove:\(d1.outputID.rawValue)")
                   && before.contains("remove:\(d2.outputID.rawValue)"),
                      "ALL removals must precede the buffer set; ops: \(ops)")
        XCTAssertFalse(before.contains { $0.hasPrefix("add:") },
                       "no re-add may precede the buffer set; ops: \(ops)")
        XCTAssertTrue(after.contains("add:\(d1.outputID.rawValue)")
                   && after.contains("add:\(d2.outputID.rawValue)"),
                      "both devices must be re-added after the buffer set; ops: \(ops)")
        XCTAssertTrue(after.contains("volume:\(d1.outputID.rawValue)")
                   && after.contains("volume:\(d2.outputID.rawValue)"),
                      "volumes must be re-pushed after re-add; ops: \(ops)")

        // Model converged back: both selected again.
        let devs = backend.devices
        XCTAssertEqual(devs.first { $0.id == d1.id }?.isSelected, true)
        XCTAssertEqual(devs.first { $0.id == d2.id }?.isSelected, true)
    }

    /// With nothing streaming, applyStartBuffer reduces to the engine set —
    /// no removals, no re-adds (the silent/instant idle path the CTA relies on).
    func testApplyStartBufferWhileIdleOnlySetsBuffer() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        await backend.applyStartBuffer(ms: 2250)

        XCTAssertEqual(backend.startBufferMs, 2250)
        XCTAssertEqual(engine.bufferSetCalls, [2250])
        XCTAssertTrue(engine.removedIDs.isEmpty, "idle apply must not tear anything down")
        XCTAssertTrue(engine.addedIDs.isEmpty, "idle apply must not add anything")
    }

    /// A device that fails its re-add follows D4 best-effort: it ends
    /// unavailable + deselected, the other device comes back streaming.
    func testApplyStartBufferReaddFailureIsBestEffort() async {
        let (backend, engine, discovery) = makeBackend()
        let ok = ap2Device(id: "AA:BB:CC:DD:EE:01", name: "Good")
        let bad = ap2Device(id: "AA:BB:CC:DD:EE:02", name: "Bad")

        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)
        _ = await collect(from: backend) { events in
            events.filter { if case .deviceAdded = $0 { return true } else { return false } }.count >= 2
        } after: {
            discovery.fire(.appeared(ok))
            discovery.fire(.appeared(bad))
        }

        backend.setOutputSet([ok.id, bad.id])
        await pollUntil {
            let devs = backend.devices
            return devs.first { $0.id == ok.id }?.isSelected == true
                && devs.first { $0.id == bad.id }?.isSelected == true
        }

        // Fail only the RE-add (the initial converge above succeeded).
        engine.addFailures = [bad.outputID.rawValue]
        await backend.applyStartBuffer(ms: 1500)

        let devs = backend.devices
        XCTAssertEqual(devs.first { $0.id == ok.id }?.isSelected, true,
                       "the succeeding re-add must not be affected (D4)")
        XCTAssertEqual(devs.first { $0.id == bad.id }?.isSelected, false)
        XCTAssertEqual(devs.first { $0.id == bad.id }?.isAvailable, false)
    }

    /// Mute stashes the pre-mute volume and pushes 0 to the engine; unmute restores
    /// the stashed level and pushes it back (shim pattern).
    func testMuteStashAndRestore() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Set a known level first.
        backend.setVolume(70, for: device.id)
        await pollUntil { backend.devices.first { $0.id == device.id }?.volume == 70 }

        // Mute: model shows volume 0 + isMuted; engine pushed 0.0.
        backend.setMuted(true, for: device.id)
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isMuted == true && d?.volume == 0
        }
        XCTAssertTrue(engine.volumeCalls.contains { $0.0 == device.outputID && $0.1 == 0.0 },
                      "mute should push engine volume 0.0")

        // Unmute: restores 70 in the model AND pushes 0.7 to the engine.
        backend.setMuted(false, for: device.id)
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isMuted == false && d?.volume == 70
        }
        XCTAssertTrue(engine.volumeCalls.contains { $0.0 == device.outputID && abs($0.1 - 0.7) < 0.001 },
                      "unmute should restore the stashed level (0.7) to the engine")
    }

    /// A disappeared AP2 device is marked unavailable (kept in the model) and its
    /// descriptor is removed from the engine's discovery.
    func testDisappearedMarksUnavailableAndRemovesFromEngine() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        let events = await collect(from: backend) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == device.id && !d.isAvailable } else { return false } }
        } after: { discovery.fire(.disappeared(id: device.id, wasAirPlay2Supported: true)) }

        XCTAssertTrue(events.contains { if case .deviceUpdated(let d) = $0 { return d.id == device.id && !d.isAvailable } else { return false } })
        // Still present in the model (not removed).
        XCTAssertTrue(backend.devices.contains { $0.id == device.id })
        // Engine discovery got the removal.
        await pollUntil { engine.discoveryRemovedNames.contains(device.descriptor.name) }
        XCTAssertTrue(engine.discoveryRemovedNames.contains(device.descriptor.name))
    }

    /// Finding 6: an AP2 device that downgrades to AP1 (loses `_airplay._tcp` but
    /// stays on `_raop._tcp`) arrives as `.updated` with isAirPlay2Supported=false.
    /// The backend must tear down the live engine session (removeOutput) AND
    /// deregister the engine descriptor — otherwise it leaks a live RTSP/PTP
    /// session while the UI flips the device to unavailable.
    func testAP2ToAP1DowngradeTearsDownEngineSession() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap2 = ap2Device(id: "AA:BB:CC:DD:EE:07", name: "Flipper")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap2.id } else { return false } }
        } after: { discovery.fire(.appeared(ap2)) }

        // Select it so it is a live engine output.
        backend.setOutputSet([ap2.id])
        await pollUntil { engine.addedIDs.contains(ap2.outputID) }

        // Now it downgrades to AP1-only (same id, isAirPlay2Supported=false).
        let downgraded = DiscoveredDevice(
            id: ap2.id,
            descriptor: ap2.descriptor,
            outputID: ap2.outputID,
            isAirPlay2Supported: false)
        discovery.fire(.updated(downgraded))

        // The engine session is torn down and the descriptor deregistered.
        await pollUntil { engine.removedIDs.contains(ap2.outputID) }
        XCTAssertTrue(engine.removedIDs.contains(ap2.outputID),
                      "an AP2→AP1 downgrade must removeOutput the live engine session (finding 6)")
        await pollUntil { engine.discoveryRemovedNames.contains(ap2.descriptor.name) }
        XCTAssertTrue(engine.discoveryRemovedNames.contains(ap2.descriptor.name),
                      "an AP2→AP1 downgrade must deregister the engine descriptor (finding 6)")
    }

    /// Finding 7: selecting an AP2 device immediately after it appears must not
    /// spuriously fail. The fire-and-forget `updateDiscovery` feed may not have
    /// resolved yet, so converge re-feeds the descriptor and awaits it before
    /// addOutput — the device ends up selected/available, never failed.
    func testSelectImmediatelyAfterAppearDoesNotSpuriouslyFail() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:08", name: "Quick")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Select right away — converge must feed the engine before addOutput.
        backend.setOutputSet([device.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && d?.isAvailable == true
        }
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isSelected, true, "a quickly-selected fresh AP2 device must not be surfaced failed (finding 7)")
        XCTAssertEqual(d?.isAvailable, true)
        XCTAssertTrue(engine.addedIDs.contains(device.outputID))
        // The descriptor was fed to the engine (converge re-feeds before addOutput).
        XCTAssertTrue(engine.fedIDs.contains(device.outputID))
    }

    // MARK: Helpers

    private func pollUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - collect(after:) convenience

private extension NativeBackendTests {
    /// Subscribe, run `after` (which fires the stimulus once the subscription is
    /// live), then collect until `predicate`.
    func collect(
        from backend: NativeBackend,
        timeout: TimeInterval = 3,
        until predicate: @escaping @Sendable ([BackendEvent]) -> Bool,
        after stimulus: @escaping () -> Void
    ) async -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let done = expectation(description: "predicate satisfied")
        let box = EventBox()
        let task = Task {
            for await event in stream {
                if case .level = event { continue }
                let all = await box.append(event)
                if predicate(all) { done.fulfill(); break }
            }
        }
        // Give the subscription a beat to register on stateQueue before stimulating.
        try? await Task.sleep(nanoseconds: 20_000_000)
        stimulus()
        await fulfillment(of: [done], timeout: timeout)
        task.cancel()
        return await box.snapshot()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
