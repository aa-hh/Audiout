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

        /// Ids that should THROW on `addOutput` (best-effort partial-failure test).
        var addFailures: Set<UInt64> = []
        /// Ids that should THROW on `removeOutput`.
        var removeFailures: Set<UInt64> = []

        /// Optional hook run INSIDE `addOutput`'s op body, after the add is recorded
        /// but before it returns successfully. Lets a test deterministically inject
        /// an out-of-band state transition in the window between addOutput resolving
        /// and NativeBackend's post-success write (medium finding).
        var onAddOutputBody: (@Sendable (OutputID) -> Void)?

        /// Artificial per-op latency (ns). Used by the toggle-spam test to force
        /// slow op completions to race fast toggle flips, so a broken (unserialized)
        /// converge would issue overlapping ops for the same device.
        var opDelayNanos: UInt64 = 0

        /// Count of `updateDiscovery` calls per parsed OutputID (root cause 2: assert
        /// no re-feed of an unchanged descriptor per toggle).
        private var feedCounts: [UInt64: Int] = [:]
        /// The max number of ops (add or remove) observed IN FLIGHT concurrently for
        /// any single device — must stay 1 with per-device serialization.
        private var inFlightByID: [UInt64: Int] = [:]
        private(set) var maxConcurrentPerDevice = 0

        private var continuation: AsyncStream<(OutputID, OutputState)>.Continuation?

        func start() async throws { lock.withLock { started = true } }
        func stop() async { lock.withLock { stopped = true } }

        @discardableResult
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            let id = descriptor.parsedID ?? OutputID(rawValue: 0)
            lock.withLock {
                discoveryFed.append(id)
                feedCounts[id.rawValue, default: 0] += 1
            }
            return id
        }
        func removeDiscovery(_ descriptor: DeviceDescriptor) async {
            lock.withLock { discoveryRemoved.append(descriptor.name) }
        }
        func addOutput(_ id: OutputID) async throws {
            try await runOp(id) {
                self.lock.withLock { self.added.append(id) }
                let hook = self.lock.withLock { self.onAddOutputBody }
                hook?(id)
                if self.addFailures.contains(id.rawValue) { throw AirPlayEngineError.sessionFailed }
            }
        }
        func removeOutput(_ id: OutputID) async throws {
            try await runOp(id) {
                self.lock.withLock { self.removed.append(id) }
                if self.removeFailures.contains(id.rawValue) { throw AirPlayEngineError.sessionFailed }
            }
        }

        /// Run a device op, tracking concurrent-in-flight-per-device (to catch
        /// overlapping ops) and applying the artificial latency.
        private func runOp(_ id: OutputID, _ body: () throws -> Void) async throws {
            lock.withLock {
                let n = (inFlightByID[id.rawValue] ?? 0) + 1
                inFlightByID[id.rawValue] = n
                maxConcurrentPerDevice = max(maxConcurrentPerDevice, n)
            }
            defer { lock.withLock { inFlightByID[id.rawValue, default: 1] -= 1 } }
            let delay = lock.withLock { opDelayNanos }
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            try body()
        }

        func feedCount(for id: OutputID) -> Int { lock.withLock { feedCounts[id.rawValue] ?? 0 } }
        func setVolume(_ id: OutputID, _ volume: Double) async throws {
            lock.withLock { volumes.append((id, volume)) }
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
        var didStart: Bool { lock.withLock { started } }
        var maxConcurrent: Int { lock.withLock { maxConcurrentPerDevice } }
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

    // MARK: Toggle-spam converge race (2026-07-17 gated session)

    /// Rapid enable/disable spam on one device — N fast toggle flips racing slow op
    /// completions — must (a) never run overlapping add/removeOutput for the same
    /// device (at most one op in flight), (b) coalesce to the LATEST desired state
    /// (intermediate flips dropped), and (c) leave the engine holding the device
    /// IFF the final toggle was ON (no zombie session, no wedge).
    func testToggleSpamCoalescesToLatestNoOverlap() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 20_000_000 // 20ms/op: ops complete slower than the flips
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:11", name: "Spam Target")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Spam 12 alternating flips with no waits between: on,off,on,off,…,on.
        // Final desired = ON (even count of "off"s ⇒ last op is on).
        let flips = 12
        for i in 0..<flips {
            let on = (i % 2 == 0)
            backend.setOutputSet(on ? [device.id] : [])
        }
        // Final flip explicitly ON so the settled state is deterministic.
        backend.setOutputSet([device.id])

        // Let all ops drain.
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && engine.addedIDs.contains(device.outputID)
        }

        // (a) never overlapped ops for the one device.
        XCTAssertLessThanOrEqual(engine.maxConcurrent, 1,
                                 "at most one add/removeOutput may be in flight per device (root cause 1)")

        // (b) coalesced: far fewer engine ops than the ~13 flips issued (intermediate
        // flips dropped, not one op per flip).
        let totalOps = engine.addedIDs.count + engine.removedIDs.count
        XCTAssertLessThan(totalOps, flips,
                          "rapid flips must coalesce, not issue one engine op per flip (got \(totalOps))")

        // (c) final engine state == final toggle state (ON): the engine holds it.
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isSelected, true, "final desired ON ⇒ device selected, no wedge")
        XCTAssertEqual(d?.isAvailable, true)
        XCTAssertTrue(engine.addedIDs.contains(device.outputID),
                      "engine holds the device iff final state is on (no zombie)")
    }

    /// The mirror case: spam ending OFF must leave the engine NOT holding the device
    /// (a removeOutput reached it) — no zombie session that keeps streaming while the
    /// UI shows it off.
    func testToggleSpamEndingOffTearsDownSession() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 15_000_000
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:12", name: "End Off")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        for i in 0..<10 { backend.setOutputSet((i % 2 == 0) ? [device.id] : []) }
        backend.setOutputSet([]) // final: OFF

        // Settled: deselected AND every add was matched by a remove (net not added).
        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.isSelected == false
                && Self.netAdded(engine, device.outputID) == false
        }

        XCTAssertLessThanOrEqual(engine.maxConcurrent, 1)
        XCTAssertFalse(Self.netAdded(engine, device.outputID),
                       "spam ending OFF must not leave a live engine session (no zombie)")
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.isSelected, false)
    }

    /// True iff the engine is NET holding `id` (more adds than removes observed).
    /// The converge loop issues one add per on-transition and one remove per
    /// off-transition, so an equal count means the last op was a remove.
    private static func netAdded(_ engine: SpyEngine, _ id: OutputID) -> Bool {
        let adds = engine.addedIDs.filter { $0 == id }.count
        let removes = engine.removedIDs.filter { $0 == id }.count
        return adds > removes
    }

    /// Root cause 2: repeatedly toggling a device with an UNCHANGED descriptor must
    /// not re-feed the engine's discovery per toggle — the duplicate "Adding AirPlay
    /// device" storm. After a fresh appear + several on/off cycles, updateDiscovery
    /// for that id was called at most once (the initial discovery feed).
    func testNoDiscoveryRefeedForUnchangedDescriptor() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 5_000_000
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:13", name: "No Refeed")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Wait for the initial discovery-driven feed to land.
        await pollUntil { engine.feedCount(for: device.outputID) >= 1 }

        // Several on/off cycles with the SAME descriptor (no discovery updates).
        for i in 0..<8 { backend.setOutputSet((i % 2 == 0) ? [device.id] : []) }
        backend.setOutputSet([device.id])

        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.isSelected == true
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertLessThanOrEqual(engine.feedCount(for: device.outputID), 1,
                                 "an unchanged descriptor must NOT be re-fed per toggle (root cause 2), got \(engine.feedCount(for: device.outputID))")
    }

    /// Root cause 4 + 5: a device whose add fails (engine NACKs SETPEERS under a
    /// session storm) is marked unavailable and PARKED (converge stops issuing
    /// sessions), but must be RECOVERABLE — a subsequent discovery re-resolution
    /// clears the park and a user re-toggle re-enables it, with the retry succeeding.
    func testSetPeersFailureRecoversNotWedged() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:14", name: "NACKer")
        engine.addFailures = [device.outputID.rawValue]  // first add throws (SETPEERS negative)
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Select it: the add fails, device goes unavailable + deselected (wedged look).
        backend.setOutputSet([device.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isAvailable == false && d?.isSelected == false
        }
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.isAvailable, false)

        // RECOVERY: the receiver settles; discovery re-resolves it (clears the park),
        // and the engine now accepts the add.
        engine.addFailures = []
        discovery.fire(.updated(device))
        await pollUntil {
            backend.devices.first { $0.id == device.id }?.isAvailable == true
        }

        // A user re-toggle now succeeds — the device is not permanently wedged.
        backend.setOutputSet([device.id])
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && d?.isAvailable == true
        }
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isSelected, true, "a NACKed device must be re-enableable after recovery (root cause 4)")
        XCTAssertEqual(d?.isAvailable, true)
        XCTAssertTrue(engine.addedIDs.contains(device.outputID))
    }

    // MARK: State-stream vs converge ordering (2026-07-17 findings)

    /// High finding: a stale `.streaming`/`.connected` state event that arrives AFTER
    /// a successful OFF converge must NOT re-wedge the device ON. The real engine
    /// yields the good transition on the state stream behind the op completion (STATE
    /// STREAM contract), so an OFF that lands before the queued `.streaming` is
    /// processed could otherwise leave the device selected+available+metering with
    /// desiredOn=false and no converge scheduled — a session shown on while the user
    /// turned it off. The state-stream event must reconcile against `desiredOn`.
    func testStaleStreamingAfterOffDoesNotReWedge() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:21", name: "Stale Streamer")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Turn it ON: converge issues addOutput; it succeeds and the device selects.
        backend.setOutputSet([device.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && engine.addedIDs.contains(device.outputID)
        }

        // Turn it OFF: converge issues removeOutput; it succeeds and the device
        // deselects. desiredOn[id] is now false and no loop is scheduled.
        backend.setOutputSet([])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == false && engine.removedIDs.contains(device.outputID)
        }

        // The real engine now yields the queued `.streaming` from the ON op (which
        // resolved behind the op completion). It is STALE — the user turned the
        // device off. It must NOT re-select / re-mark-available the device.
        engine.pushState(device.outputID, .streaming)
        // Give the state-stream consumer time to (mis)handle it.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isSelected, false,
                       "a stale .streaming after a successful OFF must not re-select the device")
        // And no phantom re-add of the engine session: removes >= adds (net off).
        XCTAssertFalse(Self.netAdded(engine, device.outputID),
                       "a stale .streaming must not leave a live engine session the user turned off")
    }

    /// High finding, in-flight variant: a stale `.streaming` arrives while the device
    /// is STILL in `added` (the OFF converge hasn't torn it down yet, e.g. the good
    /// transition raced ahead) and desiredOn is false. The state-stream handler must
    /// re-kick converge so the stale session is torn down, not leave it selected.
    func testStaleStreamingWhileAddedReKicksTeardown() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 30_000_000 // slow ops so we can wedge a stale event mid-flight
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:22", name: "InFlight Stale")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // ON, let it fully settle (added contains id, selected).
        backend.setOutputSet([device.id])
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == true && engine.addedIDs.contains(device.outputID)
        }

        // Turn OFF but push the stale .streaming immediately, BEFORE the (slow)
        // removeOutput completes. At this instant desiredOn=false and the device is
        // still in `added`. The handler must re-kick converge to tear it down rather
        // than re-selecting it.
        backend.setOutputSet([])
        engine.pushState(device.outputID, .streaming)

        // Eventually the device is off and the engine holds no session.
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.isSelected == false && !Self.netAdded(engine, device.outputID)
        }
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.isSelected, false,
                       "a stale .streaming with desiredOn=false must converge OFF, not re-wedge ON")
        XCTAssertFalse(Self.netAdded(engine, device.outputID))
        XCTAssertLessThanOrEqual(engine.maxConcurrent, 1,
                                 "the re-kick must not overlap ops for the same device")
    }

    /// Medium finding: an out-of-band `.failed` that lands between addOutput returning
    /// and its post-success write must not be clobbered. The post-write must respect
    /// the interim failure park instead of force-selecting a dead session — otherwise
    /// the device shows selected+available while the engine session actually failed,
    /// with no scheduled recovery.
    func testOutOfBandFailedNotClobberedByAddSuccessWrite() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:23", name: "Racey Fail")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        // Deterministically reproduce the interleave: inject the out-of-band `.failed`
        // from INSIDE addOutput's body (after the add is recorded, before it returns),
        // then block briefly so the state-stream consumer runs `applyEngineState` and
        // sets the failure park BEFORE addOutput returns and NativeBackend's
        // post-success write executes. The post-write must respect that park.
        engine.onAddOutputBody = { [weak engine] id in
            engine?.pushState(id, .failed)
            Thread.sleep(forTimeInterval: 0.1) // let applyEngineState park the id
        }

        backend.setOutputSet([device.id])

        // Let everything settle: the post-write should have deferred to the park.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.isAvailable, false,
                       "an interim .failed must not be clobbered by the add-success write")
        XCTAssertEqual(d?.isSelected, false,
                       "a failed session must not be shown selected")
    }

    // MARK: connectionState wiring (mirrors OwnToneBackend's T2 state machine semantics)

    /// add → connecting → connected: `setOutputSet` flips the id ON, which must go
    /// `.connecting` immediately (before the engine op resolves), then `.connected`
    /// once `addOutput` succeeds and the post-success write lands.
    func testConnectionStateAddGoesConnectingThenConnected() async {
        let (backend, engine, discovery) = makeBackend()
        engine.opDelayNanos = 30_000_000 // slow enough to observe the connecting frame
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:30", name: "State Machine")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }
        XCTAssertEqual(backend.devices.first { $0.id == device.id }?.connectionState, .off)

        let events = await collect(from: backend) { events in
            events.contains {
                if case .deviceUpdated(let d) = $0 { return d.id == device.id && d.connectionState == .connecting }
                else { return false }
            }
        } after: { backend.setOutputSet([device.id]) }
        XCTAssertTrue(events.contains {
            if case .deviceUpdated(let d) = $0 { return d.id == device.id && d.connectionState == .connecting }
            else { return false }
        }, "a newly-desired-on device must go .connecting immediately, before the op resolves")

        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.connectionState == .connected
        }
        let final = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(final?.connectionState, .connected, "a successful addOutput must land .connected")
        XCTAssertEqual(final?.isSelected, true)
    }

    /// NACK → failed: an `addOutput` throw (engine NACK) must land `.failed`, not
    /// just `isAvailable = false` — the status dot must light up amber.
    func testConnectionStateAddFailureGoesFailed() async {
        let (backend, engine, discovery) = makeBackend()
        let device = ap2Device(id: "AA:BB:CC:DD:EE:31", name: "NACKer")
        engine.addFailures = [device.outputID.rawValue]
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil {
            let d = backend.devices.first { $0.id == device.id }
            if case .failed = d?.connectionState { return true }
            return false
        }
        let d = backend.devices.first { $0.id == device.id }
        guard case .failed(let failure) = d?.connectionState else {
            XCTFail("expected .failed after a NACKed addOutput, got \(String(describing: d?.connectionState))")
            return
        }
        XCTAssertEqual(failure.cause, .unknown, "NativeBackend has no diagnostics seam — always .unknown")
        XCTAssertEqual(d?.isAvailable, false)
        XCTAssertEqual(d?.isSelected, false)
    }

    /// Recovery clears to connecting/connected: after a NACK parks the device
    /// `.failed`, a discovery re-resolution clears the park (root cause 4) and a
    /// user re-toggle retries — the connection dot must follow through
    /// `.failed → .connecting → .connected`, not stay stuck amber.
    func testConnectionStateRecoveryClearsFailedThenReconnects() async {
        let (backend, engine, discovery) = makeBackend()
        let device = ap2Device(id: "AA:BB:CC:DD:EE:32", name: "Recoverer")
        engine.addFailures = [device.outputID.rawValue]
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil {
            if case .failed = backend.devices.first(where: { $0.id == device.id })?.connectionState { return true }
            return false
        }

        // The receiver settles; discovery re-resolves it. This clears the park but
        // is not itself a retry, so the dot should NOT jump to .connecting on its
        // own here — it stays .failed (sticky) until the user re-toggles.
        engine.addFailures = []
        discovery.fire(.updated(device))
        await pollUntil { backend.devices.first { $0.id == device.id }?.isAvailable == true }

        // User re-toggle: the dot must move .failed → .connecting → .connected.
        backend.setOutputSet([device.id])
        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.connectionState == .connected
        }
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.connectionState, .connected, "a retry after recovery must reach .connected")
        XCTAssertEqual(d?.isSelected, true)
    }

    /// toggle-off → off: deselecting a connected device must clear the dot back to
    /// `.off` (NativeBackend has no sticky-failed-survives-deselect behavior — its
    /// failure park is unconditionally cleared on any toggle, so the connection dot
    /// mirrors that and does not stay amber after the user turns the device off).
    func testConnectionStateToggleOffGoesOff() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let device = ap2Device(id: "AA:BB:CC:DD:EE:33", name: "Toggle Off")
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == device.id } else { return false } }
        } after: { discovery.fire(.appeared(device)) }

        backend.setOutputSet([device.id])
        await pollUntil(timeout: 5) {
            backend.devices.first { $0.id == device.id }?.connectionState == .connected
        }

        backend.setOutputSet([])
        // The dot goes .off eagerly (synchronously, ahead of the removeOutput op
        // resolving) — wait for isSelected to catch up too so the assertion below
        // isn't racing the in-flight removal.
        await pollUntil(timeout: 5) {
            let d = backend.devices.first { $0.id == device.id }
            return d?.connectionState == .off && d?.isSelected == false
        }
        let d = backend.devices.first { $0.id == device.id }
        XCTAssertEqual(d?.connectionState, .off)
        XCTAssertEqual(d?.isSelected, false)
    }

    /// AP1-only devices are never routed (D6: never fed to the engine, never
    /// addOutput-ed even if included in `setOutputSet`) and must stay `.off`
    /// permanently — no connecting/failed dot for a device that can't be enabled.
    func testConnectionStateAP1StaysOffPermanently() async {
        let (backend, engine, discovery) = makeBackend()
        backend.start(); defer { backend.stop() }
        await waitUntilStarted(engine)

        let ap1 = ap1Device()
        _ = await collect(from: backend) { events in
            events.contains { if case .deviceAdded(let d) = $0 { return d.id == ap1.id } else { return false } }
        } after: { discovery.fire(.appeared(ap1)) }
        XCTAssertEqual(backend.devices.first { $0.id == ap1.id }?.connectionState, .off)

        // Attempting to select it must not move the dot — it's never addOutput-ed.
        backend.setOutputSet([ap1.id])
        try? await Task.sleep(nanoseconds: 150_000_000)
        let d = backend.devices.first { $0.id == ap1.id }
        XCTAssertEqual(d?.connectionState, .off, "an AP1-only device must never show connecting/failed")
        XCTAssertTrue(engine.addedIDs.isEmpty)
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
