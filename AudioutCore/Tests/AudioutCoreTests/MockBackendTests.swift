import Foundation
import Testing
@testable import AudioutCore

@Suite struct MockBackendTests {

    private let demoFleet = [Device].demoFleet

    /// Deterministic backend for tests: no discovery stagger, no timers.
    private func makeBackend(_ fleet: [Device] = .demoFleet) -> MockBackend {
        MockBackend(fleet: fleet, staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false)
    }

    /// A backend whose scripted connect steps wait on `clock` instead of the
    /// wall clock: nothing runs until the test calls `clock.fireAll()`.
    private func makeScriptedBackend(_ scripts: [String: ConnectScript]) -> (MockBackend, QueuedDelayClock) {
        let clock = QueuedDelayClock()
        let backend = MockBackend(
            fleet: [Device(id: "a", name: "A", kind: .generic)],
            staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false,
            connectScripts: scripts, outputObserver: nil, delayClock: clock.clock)
        return (backend, clock)
    }

    /// Let the backend take what the test just asked of it, then run every
    /// delayed step it scheduled, to completion.
    private func run(_ backend: MockBackend, _ clock: QueuedDelayClock) {
        _ = backend.devices
        clock.fireAll()
    }

    /// Collect the next `count` non-level events. Fails if they don't arrive in time.
    private func collect(_ count: Int, from backend: MockBackend) async -> [BackendEvent] {
        let (box, task) = record(backend.makeEventStream()) { event in
            if case .level = event { return false }
            return true
        }
        defer { task.cancel() }
        backend.start()
        await SuiteWait.until("\(count) events") { box.events.count >= count }
        return Array(box.events.prefix(count))
    }

    @Test func discoveryEmitsWholeFleet() async throws {
        let backend = makeBackend()
        let events = await collect(demoFleet.count, from: backend)
        let added = events.compactMap { if case .deviceAdded(let d) = $0 { return d.id } else { return nil } }
        #expect(Set(added) == Set(demoFleet.map(\.id)))
    }

    @Test func devicesSnapshotMatchesFleetAfterDiscovery() async throws {
        let backend = makeBackend()
        _ = await collect(demoFleet.count, from: backend)
        #expect(backend.devices.map(\.id) == demoFleet.map(\.id))
    }

    @Test func setVolumeClampsAndEchoes() async throws {
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic, volume: 50)])
        let (box, task) = record(backend.makeEventStream()) { event in
            if case .deviceUpdated(let d) = event, d.id == "a" { return true }
            return false
        }
        defer { task.cancel() }
        backend.start()
        // wait for discovery, then over-drive the volume past the ceiling
        await SuiteWait.until("discovery of a") { backend.devices.count == 1 }
        backend.setVolume(150, for: "a")
        await SuiteWait.until("the volume echo") { !box.devices.isEmpty }
        let updated = box.devices.first
        #expect(updated?.volume == 100, "volume should clamp to 100")
    }

    @Test func setEQEchoesTheSettingsBack() async throws {
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic)])
        let eq = DeviceEQ(bassDB: 5, balance: -0.25, loudness: true)
        let (box, task) = record(backend.makeEventStream()) { event in
            if case .deviceUpdated(let d) = event, d.id == "a" { return true }
            return false
        }
        defer { task.cancel() }
        backend.start()
        await SuiteWait.until("discovery of a") { backend.devices.count == 1 }   // let discovery settle
        backend.setEQ(eq, for: "a", commit: true)
        await SuiteWait.until("the EQ echo") { !box.devices.isEmpty }
        #expect(box.devices.first?.eq == eq)
    }

    @Test func setMainOutEQIsRecordedNotApplied() async throws {
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic)])
        _ = await collect(1, from: backend)
        #expect(backend.mainOutEQ == .flat)

        backend.setMainOutEQ(DeviceEQ(trebleDB: -3), commit: false)
        await SuiteWait.until("the Main Out EQ to record the new treble") {
            backend.mainOutEQ == DeviceEQ(trebleDB: -3)
        }
        #expect(backend.mainOutEQ == DeviceEQ(trebleDB: -3))
        #expect(backend.devices.allSatisfy { $0.eq.isFlat }, "Main Out EQ is not a per-device setting")
    }

    @Test func setOutputSetSelectsExactlyTheGivenDevices() async throws {
        let backend = makeBackend()
        _ = await collect(demoFleet.count, from: backend)

        backend.setOutputSet(["office", "homepod-bed"])
        await SuiteWait.until("the output set to become exactly the given devices") {
            Set(backend.devices.filter(\.isSelected).map(\.id)) == ["office", "homepod-bed"]
        }

        let selected = Set(backend.devices.filter(\.isSelected).map(\.id))
        #expect(selected == ["office", "homepod-bed"])
    }

    @Test func noOpChangeDoesNotEmit() async throws {
        // Setting a device's volume to the value it already has must not echo.
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic, volume: 42)])
        _ = await collect(1, from: backend)   // the initial deviceAdded

        let (box, task) = record(backend.makeEventStream()) { event in
            if case .deviceUpdated = event { return true }
            return false
        }
        defer { task.cancel() }
        backend.setVolume(42, for: "a")            // same value → no-op
        // Events arrive in order, so once this real change echoes, a no-op echo
        // would already be in the box ahead of it.
        backend.setVolume(43, for: "a")
        await SuiteWait.until("the real change to echo") { !box.events.isEmpty }
        let sawUpdate = box.devices.count > 1
        #expect(!sawUpdate, "a no-op change should not emit deviceUpdated")
    }

    @Test func unscriptedEnableAndDisableAreStillSingleSynchronousEvents() async throws {
        // Backward-compat requirement (brief §5): a device with no script
        // keeps the exact current one-event-per-toggle behaviour, just now
        // also carrying `.connected`/`.off` in that same event.
        let backend = makeBackend([Device(id: "a", name: "A", kind: .generic)])
        _ = await collect(1, from: backend)   // initial deviceAdded

        let (box, task) = record(backend.makeEventStream()) { event in
            if case .deviceUpdated(let d) = event, d.id == "a" { return true }
            return false
        }
        defer { task.cancel() }
        backend.setOutputSet(["a"])
        await SuiteWait.until("the enable echo") { !box.devices.isEmpty }
        let enabledDevice = box.devices.first
        #expect(enabledDevice?.isSelected == true)
        #expect(enabledDevice?.connectionState == .connected)

        let (box2, task2) = record(backend.makeEventStream()) { event in
            if case .deviceUpdated(let d) = event, d.id == "a" { return true }
            return false
        }
        defer { task2.cancel() }
        backend.setOutputSet([])
        await SuiteWait.until("the disable echo") { !box2.devices.isEmpty }
        let disabledDevice = box2.devices.first
        #expect(disabledDevice?.isSelected == false)
        #expect(disabledDevice?.connectionState == .off)
    }

    @Test func scriptedConnectGoesConnectingThenConnected() async throws {
        let script = ConnectScript(attempts: [.connect(after: 0.1)])
        let (backend, clock) = makeScriptedBackend(["a": script])
        _ = await collectFleetDiscovery(backend)

        let updates = await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])
            run(backend, clock)
        }
        #expect(updates.map(\.connectionState) == [.connecting, .connected])
        #expect(updates.last?.isSelected == true)
    }

    @Test func scriptedFailGoesConnectingThenFailedWithIsSelectedFalse() async throws {
        let failure = ConnectionFailure(cause: .notResponding)
        let (backend, clock) = makeScriptedBackend(["a": ConnectScript(attempts: [.fail(after: 0.1, failure)])])
        _ = await collectFleetDiscovery(backend)

        let updates = await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])
            run(backend, clock)
        }
        #expect(updates.map(\.connectionState) == [.connecting, .failed(failure)])
        #expect(updates.last?.isSelected == false)
    }

    @Test func failedStateIsStickyAcrossDeselect() async throws {
        // §1: dropping a failed device from the expected set (the popover's
        // honest-toggle cleanup) must not erase the warning.
        let failure = ConnectionFailure(cause: .vanished)
        let (backend, clock) = makeScriptedBackend(["a": ConnectScript(attempts: [.fail(after: 0.1, failure)])])
        _ = await collectFleetDiscovery(backend)
        _ = await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])
            run(backend, clock)
        }

        let cleanup = await collectUpdates(for: "a", count: 1, from: backend) {
            backend.setOutputSet([])   // remove from expected set without retrying
            run(backend, clock)
        }
        #expect(cleanup.last?.connectionState == .failed(failure), "sticky-failed must survive deselect")
        #expect(cleanup.last?.isSelected == false)
    }

    @Test func retryAfterFailureUsesTheSecondScriptedAttempt() async throws {
        let failure = ConnectionFailure(cause: .notResponding)
        let (backend, clock) = makeScriptedBackend(["a": ConnectScript(attempts: [
                .fail(after: 0.1, failure),
                .connect(after: 0.1),
            ])])
        _ = await collectFleetDiscovery(backend)
        _ = await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])       // attempt 1: fails
            run(backend, clock)
        }
        _ = await collectUpdates(for: "a", count: 1, from: backend) {
            backend.setOutputSet([])          // cleanup (sticky-failed)
            run(backend, clock)
        }
        let retry = await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])       // attempt 2: connects
            run(backend, clock)
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
        let (backend, clock) = makeScriptedBackend(["a": ConnectScript(attempts: [
                .fail(after: 0.1, failure),
                .connect(after: 0.1),
            ])])
        _ = await collectFleetDiscovery(backend)
        _ = await collectUpdates(for: "a", count: 2, from: backend) {
            backend.setOutputSet(["a"])       // attempt 1: fails
            run(backend, clock)
        }

        // "a" is still in the requested set (R12 never dropped it). Re-issuing
        // the SAME set is routing noise, not a retry — the device must stay in
        // its resting `.failed`, with attempt 2 left unconsumed.
        backend.setOutputSet(["a"])
        run(backend, clock)   // no step is pending, so nothing may change
        let resting = try #require(backend.devices.first { $0.id == "a" })
        #expect(resting.connectionState == .failed(failure),
                "a membership-neutral setOutputSet must not restart a .failed device's script")

        // The dedicated retry entry point consumes attempt 2 and connects.
        let retry = await collectUpdates(for: "a", count: 2, from: backend) {
            backend.retryOutput("a")
            run(backend, clock)
        }
        #expect(retry.map(\.connectionState) == [.connecting, .connected])
        #expect(retry.last?.isSelected == true)
    }

    @Test func connectThenDropRecovers() async throws {
        let (backend, clock) = makeScriptedBackend(["a": ConnectScript(attempts: [
                .connectThenDrop(connectAfter: 0.1, dropAfter: 0.1, recovers: true),
            ])])
        _ = await collectFleetDiscovery(backend)

        // connecting -> connected -> reconnecting -> connected
        let updates = await collectUpdates(for: "a", count: 4, from: backend) {
            backend.setOutputSet(["a"])
            run(backend, clock)
        }
        #expect(updates.map(\.connectionState) == [.connecting, .connected, .reconnecting, .connected])
        #expect(updates.last?.isSelected == true)
    }

    @Test func connectThenDropFails() async throws {
        let (backend, clock) = makeScriptedBackend(["a": ConnectScript(attempts: [
                .connectThenDrop(connectAfter: 0.1, dropAfter: 0.1, recovers: false),
            ])])
        _ = await collectFleetDiscovery(backend)

        let updates = await collectUpdates(for: "a", count: 4, from: backend) {
            backend.setOutputSet(["a"])
            run(backend, clock)
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
        _ = await collect(demoFleet.count, from: backend)   // drain discovery

        let (box, task) = record(backend.makeEventStream()) { event in
            if case .routedApps = event { return true }
            return false
        }
        defer { task.cancel() }
        backend.test_emitRoutedApps(deviceID: "office", appNames: ["Music", "Safari"])
        await SuiteWait.until("routedApps event received") { !box.events.isEmpty }

        guard case .routedApps(let deviceID, let appNames) = box.events.first else {
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
        _ = await collect(demoFleet.count, from: backend)

        let (box, task) = record(backend.makeEventStream()) { event in
            if case .routedApps = event { return true }
            return false
        }
        defer { task.cancel() }
        backend.test_emitRoutedApps(deviceID: "office", appNames: [])
        await SuiteWait.until("empty routedApps event received") { !box.events.isEmpty }

        guard case .routedApps(let deviceID, let appNames) = box.events.first else {
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
        _ = await collect(demoFleet.count, from: backend)   // drain discovery

        let (box, task) = record(backend.makeEventStream()) { event in
            if case .appLevel = event { return true }
            return false
        }
        defer { task.cancel() }
        backend.test_emitAppLevel(bundleID: "com.apple.Music", rms: 0.42)
        await SuiteWait.until("appLevel event received") { !box.events.isEmpty }

        guard case .appLevel(let bundleID, let rms) = box.events.first else {
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
        _ = await collect(demoFleet.count, from: backend)   // drain discovery; metering still inactive

        let (box, collector) = record(backend.makeEventStream())
        defer { collector.cancel() }

        // Default: metering inactive, so no `.appLevel` should show up yet. The
        // level timer ticks every 0.1 s on the real clock, so give it three ticks.
        await SuiteWait.until("an .appLevel the gate should have blocked", timeout: 0.3) {
            box.events.contains { if case .appLevel = $0 { return true } else { return false } }
        }
        var seen = box.events
        #expect(
            !seen.contains { if case .appLevel = $0 { return true } else { return false } },
            "no .appLevel may be emitted while metering is inactive"
        )

        // Flip metering on: both registered apps must start showing up.
        backend.setMeteringActive(true)
        await SuiteWait.until("both apps to emit an .appLevel") {
            Set(box.events.compactMap { event -> String? in
                if case .appLevel(let bundleID, _) = event { return bundleID } else { return nil }
            }) == ["com.apple.Music", "com.apple.Podcasts"]
        }
        seen = box.events
        let seenBundleIDs = Set(seen.compactMap { event -> String? in
            if case .appLevel(let bundleID, _) = event { return bundleID } else { return nil }
        })
        #expect(seenBundleIDs == ["com.apple.Music", "com.apple.Podcasts"])
    }
}

extension MockBackendTests {
    /// Discover the (single-device) fleet used by the scripted-choreography
    /// tests above, starting the backend.
    func collectFleetDiscovery(_ backend: MockBackend) async -> [BackendEvent] {
        await collect(1, from: backend)
    }

    /// Run `action`, then collect the next `count` `deviceUpdated` events for
    /// `id` that follow it.
    func collectUpdates(
        for id: String, count: Int, from backend: MockBackend,
        after action: () -> Void
    ) async -> [Device] {
        let (box, task) = record(backend.makeEventStream()) { event in
            if case .deviceUpdated(let d) = event, d.id == id { return true }
            return false
        }
        defer { task.cancel() }
        action()
        await SuiteWait.until("\(count) updates for \(id)") { box.events.count >= count }
        return Array(box.devices.prefix(count))
    }
}

// Small thread-safe boxes to carry mutable state across the async boundary without races.

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [BackendEvent] = []
    var events: [BackendEvent] { lock.withLock { all } }
    var devices: [Device] {
        events.compactMap { if case .deviceUpdated(let d) = $0 { return d } else { return nil } }
    }
    func append(_ event: BackendEvent) { lock.withLock { all.append(event) } }
}

/// Feed every event of `stream` that passes `keep` into a box, until the task is cancelled.
private func record(
    _ stream: AsyncStream<BackendEvent>, where keep: @escaping @Sendable (BackendEvent) -> Bool = { _ in true }
) -> (EventBox, Task<Void, Never>) {
    let box = EventBox()
    let task = Task { for await event in stream where keep(event) { box.append(event) } }
    return (box, task)
}

/// A delay clock that holds every scheduled step until `fireAll()`, then runs
/// them on the queue they were scheduled for, in order, including steps they
/// schedule in turn — so a scripted choreography finishes in one call.
private final class QueuedDelayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [(queue: DispatchQueue, work: DispatchWorkItem)] = []
    var clock: NativeBackend.DelayClock {
        { [self] _, queue, work in lock.withLock { jobs.append((queue, work)) } }
    }
    func fireAll() {
        while true {
            let batch = lock.withLock { () -> [(queue: DispatchQueue, work: DispatchWorkItem)] in
                defer { jobs = [] }; return jobs
            }
            if batch.isEmpty { return }
            for job in batch { job.queue.async(execute: job.work) }
            for job in batch { job.queue.sync {} }   // everything queued above has run
        }
    }
}
