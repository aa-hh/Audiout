import Foundation
import Testing
@testable import AudiouterCore

/// Unit tests for the real `OwnToneBackend` and its `OwnToneClient`, run against
/// a stubbed `URLProtocol` — **never** the live OwnTone server. The stub lets a
/// test script per-path responses (and simulate connection-refused), so we can
/// exercise the poll-diff, silent-select-failure, zombie-recovery, empty-queue,
/// and unreachable-backoff paths hermetically.
///
/// Grounded in `dev/notes/p1-owntone-api-brief.md` (poll-primary, re-GET after
/// outputs/set, HTML error bodies, 500-on-empty-queue, "AirPlay 1"/"AirPlay 2").
///
/// **Test isolation note (swift-testing conversion):** `StubURLProtocol` used to
/// hold a single process-global `static var handler`. Under XCTest's
/// one-process-per-test-method model that was accidentally safe (no two test
/// methods ever ran in the same process at the same time). Under
/// swift-testing's in-process concurrent execution, two `@Test`s racing to set
/// that one global would clobber each other's stub and read back a mixture of
/// both tests' responses — a genuine data race, not just a style mismatch. The
/// fix: `StubURLProtocol` now keys its handler lookup by a per-test id carried
/// in a header on each request (`testIDHeaderField`), registered/unregistered
/// per suite instance instead of a single shared `handler` var. This suite is a
/// `final class` (not the usual `struct`) specifically so `deinit` can
/// unregister its id — mirroring the old `tearDown()`'s `StubURLProtocol.reset()`.
@Suite final class OwnToneBackendTests {

    /// Unique per test instance (swift-testing creates a fresh suite instance
    /// per `@Test`), used to key this test's stub responses so concurrent tests
    /// never share a handler.
    private let testID = UUID().uuidString

    deinit {
        StubURLProtocol.unregister(testID)
    }

    // MARK: Helpers

    /// A backend wired to the stubbed transport, no real websocket, fast polls.
    private func makeBackend(pollInterval: TimeInterval = 0.05,
                             connectingTimeout: TimeInterval = 10) -> OwnToneBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = [StubURLProtocol.testIDHeaderField: testID]
        let session = URLSession(configuration: config)
        let client = OwnToneClient(session: session, timeout: 2)
        return OwnToneBackend(client: client, webSocket: nil,
                              pollInterval: pollInterval, unreachablePollInterval: 0.05,
                              connectingTimeout: connectingTimeout)
    }

    /// Register this test's response handler. Replaces the old
    /// `StubURLProtocol.handler = ...` global assignment.
    private func setHandler(_ handler: @escaping @Sendable (URLRequest) -> StubURLProtocol.Response) {
        StubURLProtocol.register(handler, for: testID)
    }

    /// Collect non-level events until `predicate` is satisfied or timeout.
    private func collect(
        from backend: OwnToneBackend,
        timeout: TimeInterval = 3,
        until predicate: @escaping @Sendable ([BackendEvent]) -> Bool
    ) async -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let box = EventCollector()
        await confirmation("predicate satisfied") { done in
            let task = Task {
                for await event in stream {
                    if case .level = event { continue }
                    let all = await box.append(event)
                    if predicate(all) { done(); break }
                }
            }
            defer { task.cancel() }
            // The body must do the waiting itself — `confirmation` does not.
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(timeout)) }
                try await group.next()
                group.cancelAll()
            }
        }
        return await box.all
    }

    private func outputsJSON(_ outputs: [(id: String, name: String, type: String, selected: Bool, volume: Int)],
                             requiresAuth: Bool = false) -> Data {
        let objs = outputs.map { o in
            """
            {"id":"\(o.id)","name":"\(o.name)","type":"\(o.type)","selected":\(o.selected),"volume":\(o.volume),"has_password":false,"requires_auth":\(requiresAuth),"needs_auth_key":false,"offset_ms":0,"format":"alac","supported_formats":["alac"]}
            """
        }.joined(separator: ",")
        return Data("{\"outputs\":[\(objs)]}".utf8)
    }

    /// Extract the connection states (for one device id) from an event list,
    /// in emission order — the backbone of the state-machine ordering asserts.
    private func states(of id: String, in events: [BackendEvent]) -> [ConnectionState] {
        events.compactMap {
            switch $0 {
            case .deviceAdded(let d) where d.id == id:   return d.connectionState
            case .deviceUpdated(let d) where d.id == id: return d.connectionState
            default:                                     return nil
            }
        }
    }

    /// The `.failed` payload of the LAST failed update for `id`, if any.
    private func lastFailure(of id: String, in events: [BackendEvent]) -> ConnectionFailure? {
        for state in states(of: id, in: events).reversed() {
            if case .failed(let f) = state { return f }
        }
        return nil
    }

    private func playerJSON(state: String = "stop", volume: Int = 50) -> Data {
        Data("{\"state\":\"\(state)\",\"repeat\":\"off\",\"consume\":false,\"shuffle\":false,\"volume\":\(volume),\"item_id\":0,\"item_length_ms\":0,\"item_progress_ms\":0}".utf8)
    }

    private var configJSON: Data { Data("{\"version\":\"29.2\",\"websocket_port\":3688}".utf8) }

    // MARK: Tests

    /// Poll discovers outputs and emits `deviceAdded`, mapping the "AirPlay 1"/
    /// "AirPlay 2" type prefix onto `supportsAirPlay2` (brief don't-assume #5).
    @Test func pollDiscoveryEmitsDeviceAddedWithTypeMapping() async {
        setHandler { [self] request in
            switch request.url!.path {
            case "/api/config":  return .ok(configJSON)
            case "/api/outputs": return .ok(outputsJSON([
                ("111", "LG TV", "AirPlay 2", false, 50),
                ("222", "Old Express", "AirPlay 1", false, 70),
            ]))
            case "/api/player":  return .ok(playerJSON())
            default:             return .status(400)
            }
        }
        let backend = makeBackend()
        backend.start(); defer { backend.stop() }

        let events = await collect(from: backend) { events in
            events.filter { if case .deviceAdded = $0 { return true } else { return false } }.count >= 2
        }
        let added = events.compactMap { if case .deviceAdded(let d) = $0 { return d } else { return nil } }
        let lg = added.first { $0.id == "111" }
        let express = added.first { $0.id == "222" }
        #expect(lg?.supportsAirPlay2 == true, "\"AirPlay 2\" → supportsAirPlay2 true")
        #expect(express?.supportsAirPlay2 == false, "\"AirPlay 1\" → supportsAirPlay2 false")
    }

    /// A field change between polls emits exactly one `deviceUpdated` with the
    /// new value (poll-diff, not a re-add).
    @Test func pollDiffEmitsDeviceUpdatedOnVolumeChange() async {
        let volume = Locked(50)
        setHandler { [self] request in
            switch request.url!.path {
            case "/api/config":  return .ok(configJSON)
            case "/api/outputs": return .ok(outputsJSON([("111", "TV", "AirPlay 2", true, volume.get())]))
            case "/api/player":  return .ok(playerJSON(state: "play"))
            default:             return .status(400)
            }
        }
        let backend = makeBackend()
        backend.start(); defer { backend.stop() }

        // Wait for discovery, then flip the polled volume.
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }
        volume.set(80)

        let events = await collect(from: backend) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.volume == 80 } else { return false } }
        }
        #expect(events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "111" && d.volume == 80 } else { return false } })
    }

    /// An output absent from a later poll emits `deviceRemoved`.
    @Test func pollDiffEmitsDeviceRemovedWhenOutputVanishes() async {
        let present = Locked(true)
        setHandler { [self] request in
            switch request.url!.path {
            case "/api/config":  return .ok(configJSON)
            case "/api/outputs":
                return .ok(present.get()
                    ? outputsJSON([("111", "TV", "AirPlay 2", false, 50), ("222", "Speaker", "AirPlay 2", false, 50)])
                    : outputsJSON([("111", "TV", "AirPlay 2", false, 50)]))
            case "/api/player":  return .ok(playerJSON())
            default:             return .status(400)
            }
        }
        let backend = makeBackend()
        backend.start(); defer { backend.stop() }

        _ = await collect(from: backend) { events in
            events.filter { if case .deviceAdded = $0 { return true } else { return false } }.count >= 2
        }
        present.set(false)
        let events = await collect(from: backend) { events in
            events.contains { if case .deviceRemoved(let id) = $0 { return id == "222" } else { return false } }
        }
        #expect(events.contains { if case .deviceRemoved(let id) = $0 { return id == "222" } else { return false } })
    }

    /// Silent-select-failure: `outputs/set` 204s but the re-GET shows the target
    /// still `selected:false`. The backend must detect it (brief don't-assume #2)
    /// and run recovery (re-issue outputs/set). Here recovery keeps failing, so
    /// the device ends `.failed` — but stays *available*: it answered the poll,
    /// so it's on the network; the *session* failed (connection-status brief §1,
    /// which deliberately replaced the old mark-unavailable behaviour).
    @Test func silentSelectFailureDetectedAndSurfacedAsFailed() async {
        let setCalls = Locked(0)
        setHandler { [self] request in
            switch (request.httpMethod ?? "", request.url!.path) {
            case ("GET", "/api/config"):  return .ok(configJSON)
            // Always report the output as NOT selected — the selection never sticks.
            case ("GET", "/api/outputs"): return .ok(outputsJSON([("dead", "Verify Receiver", "AirPlay 1", false, 70)]))
            case ("GET", "/api/player"):  return .ok(playerJSON())
            case ("PUT", "/api/outputs/set"):
                setCalls.set(setCalls.get() + 1)
                return .status(204)                       // 204 but selection won't take
            default:                      return .status(204)
            }
        }
        let backend = makeBackend()
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        backend.setOutputSet(["dead"])

        // The confirm-re-GET sees selected:false → recovery re-issues set once →
        // still false → `.failed`, and it stops retrying.
        let events = await collect(from: backend, timeout: 4) { [self] events in
            lastFailure(of: "dead", in: events) != nil
        }
        #expect(lastFailure(of: "dead", in: events)?.cause == .unknown,
                "a select-revert with no better evidence should fail as .unknown")
        let failedDevice = events.compactMap { event -> Device? in
            if case .deviceUpdated(let d) = event, case .failed = d.connectionState { return d }
            return nil
        }.last
        #expect(failedDevice?.isAvailable == true,
                "recovery failure must keep the device available — the session failed, not the network")
        // outputs/set was called at least twice: the initial set + the recovery re-select.
        #expect(setCalls.get() >= 2, "recovery must re-issue outputs/set")
    }

    /// Zombie recovery success path: the selection sticks on the recovery
    /// re-select, and the `replayHook` (the coordinator's clear→add→play half)
    /// is invoked as part of recovery (brief §4 step 4).
    @Test func zombieRecoveryReselectsAndInvokesReplayHook() async {
        let selected = Locked(false)
        let setCalls = Locked(0)
        setHandler { [self] request in
            switch (request.httpMethod ?? "", request.url!.path) {
            case ("GET", "/api/config"):  return .ok(configJSON)
            case ("GET", "/api/outputs"): return .ok(outputsJSON([("s1", "Speaker", "AirPlay 2", selected.get(), 50)]))
            case ("GET", "/api/player"):  return .ok(playerJSON(state: "play"))
            case ("PUT", "/api/outputs/set"):
                let n = setCalls.get() + 1; setCalls.set(n)
                // First set (user's) silently fails; the recovery re-select sticks.
                if n >= 2 { selected.set(true) }
                return .status(204)
            default:                      return .status(204)
            }
        }
        let replayed = Locked(false)
        let backend = makeBackend()
        backend.replayHook = { replayed.set(true) }
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        backend.setOutputSet(["s1"])

        let events = await collect(from: backend, timeout: 4) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "s1" && d.isSelected } else { return false } }
        }
        #expect(events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "s1" && d.isSelected } else { return false } },
                "recovery should end with the output actually selected")
        #expect(replayed.get(), "the coordinator replay hook must fire during recovery")
    }

    /// Empty-queue guard: `player/play` on an empty queue is a hard 500 (brief
    /// don't-assume #4). The client surfaces it as `.http(500)` rather than
    /// masking it, so a caller (the coordinator) can guard.
    @Test func playOnEmptyQueueSurfaces500() async {
        setHandler { request in
            if request.url!.path == "/api/player/play" { return .html(500) }
            return .status(204)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = [StubURLProtocol.testIDHeaderField: testID]
        let client = OwnToneClient(session: URLSession(configuration: config), timeout: 2)

        do {
            try await client.play()
            Issue.record("player/play on an empty queue should throw, not succeed")
        } catch let error as OwnToneClient.ClientError {
            #expect(error == .http(status: 500))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// Connection-refused: the client maps `URLError.cannotConnectToHost` to
    /// `.unreachable`, and the backend surfaces every known device as unavailable
    /// (Q7 connect-only) while continuing to poll (no crash, no supervise).
    @Test func connectionRefusedSurfacesUnreachableAndKeepsPolling() async {
        // Start reachable so a device is discovered, then flip to refused.
        let refused = Locked(false)
        setHandler { [self] request in
            if refused.get() { return .refused }
            switch request.url!.path {
            case "/api/config":  return .ok(configJSON)
            case "/api/outputs": return .ok(outputsJSON([("111", "TV", "AirPlay 2", false, 50)]))
            case "/api/player":  return .ok(playerJSON())
            default:             return .status(204)
            }
        }
        let backend = makeBackend()
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        refused.set(true)
        let events = await collect(from: backend, timeout: 4) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "111" && !d.isAvailable } else { return false } }
        }
        #expect(events.contains { if case .deviceUpdated(let d) = $0 { return !d.isAvailable } else { return false } },
                "connection-refused should mark known devices unavailable")

        // And it recovers automatically when the server comes back.
        refused.set(false)
        let back = await collect(from: backend, timeout: 4) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "111" && d.isAvailable } else { return false } }
        }
        #expect(back.contains { if case .deviceUpdated(let d) = $0 { return d.isAvailable } else { return false } },
                "polling should resume and re-mark devices available when OwnTone returns")
    }

    /// Client-level: out-of-range volume is caller-clamped (the backend clamps
    /// with `.clampedToVolume` before calling), so the client never sends >100.
    @Test func setVolumeClampsBeforeSending() async {
        let sentVolume = Locked(-1)
        setHandler { request in
            if request.httpMethod == "PUT", request.url!.path.hasPrefix("/api/outputs/"),
               let body = request.bodyData(),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let v = json["volume"] as? Int {
                sentVolume.set(v)
            }
            switch request.url!.path {
            case "/api/config":  return .ok(Data("{\"version\":\"29.2\"}".utf8))
            case "/api/outputs": return .ok(Data("{\"outputs\":[{\"id\":\"111\",\"name\":\"TV\",\"type\":\"AirPlay 2\",\"selected\":false,\"volume\":50}]}".utf8))
            case "/api/player":  return .ok(Data("{\"state\":\"stop\",\"volume\":50}".utf8))
            default:             return .status(204)
            }
        }
        let backend = makeBackend()
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        backend.setVolume(150, for: "111")
        // Poll for the PUT rather than sleeping a fixed beat: under
        // swift-testing's in-process concurrency a fixed 300 ms sleep routinely
        // lost this race (PUT not yet at the stub in half of runs). Returns as
        // soon as the PUT lands; -1 (the sentinel) still surfaces as a real
        // failure at the end.
        var deadline = 400   // 400 x 10 ms = 4 s
        while sentVolume.get() == -1 && deadline > 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            deadline -= 1
        }
        #expect(sentVolume.get() == 100, "the backend must clamp to 100 before PUT — OwnTone 400s on out-of-range")
    }

    // MARK: Connection state machine (dev/notes/p1-connection-status-brief.md §3)

    /// Enabling a device emits `.connecting` immediately (before the
    /// PUT/confirm round-trip resolves), then `.connected` once the confirm
    /// re-GET AND the next poll tick agree it's selected. Once connected, the
    /// timeout must be disarmed — a short `connectingTimeout` here would fail
    /// the device if any stale timer survived.
    @Test func enableEmitsConnectingThenConnectedAndCancelsTimeout() async {
        let selected = Locked(false)
        setHandler { [self] request in
            switch (request.httpMethod ?? "", request.url!.path) {
            case ("GET", "/api/config"):  return .ok(configJSON)
            case ("GET", "/api/outputs"): return .ok(outputsJSON([("s1", "Speaker", "AirPlay 2", selected.get(), 50)]))
            case ("GET", "/api/player"):  return .ok(playerJSON(state: "play"))
            case ("PUT", "/api/outputs/set"):
                selected.set(true)                        // the selection sticks
                return .status(204)
            default:                      return .status(204)
            }
        }
        let backend = makeBackend(connectingTimeout: 0.5)
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        backend.setOutputSet(["s1"])

        let events = await collect(from: backend, timeout: 4) { [self] events in
            states(of: "s1", in: events).contains(.connected)
        }
        let observed = states(of: "s1", in: events)
        guard let connecting = observed.firstIndex(of: .connecting),
              let connected = observed.firstIndex(of: .connected) else {
            Issue.record("expected both .connecting and .connected, got \(observed)")
            return
        }
        #expect(connecting < connected, ".connecting must be emitted before .connected")
        let connectedDevice = events.compactMap { event -> Device? in
            if case .deviceUpdated(let d) = event, d.connectionState == .connected { return d }
            return nil
        }.first
        #expect(connectedDevice?.isSelected == true, "a .connected device must also be selected")

        // Outlive the 0.5 s timeout: it must have been cancelled on connect.
        try? await Task.sleep(nanoseconds: 700_000_000)
        #expect(backend.devices.first?.connectionState == .connected,
                "the connecting timeout must not fire after a successful connect")
    }

    /// Sticky-failed (brief §1): the popover removes a failed id from the
    /// output set as *cleanup*, and that must not erase the warning. Re-adding
    /// the id afterwards is the retry path and goes back to `.connecting`.
    @Test func failedIsStickyAcrossCleanupAndRetriesAsConnecting() async {
        setHandler { [self] request in
            switch request.url!.path {
            case "/api/config":  return .ok(configJSON)
            // The selection never sticks — every enable attempt fails.
            case "/api/outputs": return .ok(outputsJSON([("dead", "Stubborn", "AirPlay 2", false, 40)]))
            case "/api/player":  return .ok(playerJSON())
            default:             return .status(204)
            }
        }
        let backend = makeBackend()
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        backend.setOutputSet(["dead"])
        _ = await collect(from: backend, timeout: 4) { [self] events in
            lastFailure(of: "dead", in: events) != nil
        }

        // Cleanup: drop the id from the set (what the popover does on failure).
        backend.setOutputSet([])
        // Let the set call land and a few polls tick — the state must survive.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard case .failed = backend.devices.first?.connectionState else {
            Issue.record("removing a failed id from the set must keep it .failed (sticky), got \(String(describing: backend.devices.first?.connectionState))")
            return
        }

        // Retry: re-adding the failed id goes back to .connecting.
        backend.setOutputSet(["dead"])
        let retry = await collect(from: backend, timeout: 4) { [self] events in
            states(of: "dead", in: events).contains(.connecting)
        }
        #expect(states(of: "dead", in: retry).contains(.connecting),
                "re-adding a failed id is the retry path → .connecting")
    }

    /// Zombie drop with successful recovery: `.connected → .reconnecting →
    /// .connected`, in that order.
    @Test func zombieDropEmitsReconnectingThenRecoversToConnected() async {
        let selected = Locked(false)
        setHandler { [self] request in
            switch (request.httpMethod ?? "", request.url!.path) {
            case ("GET", "/api/config"):  return .ok(configJSON)
            case ("GET", "/api/outputs"): return .ok(outputsJSON([("s1", "Speaker", "AirPlay 2", selected.get(), 50)]))
            case ("GET", "/api/player"):  return .ok(playerJSON(state: "play"))
            case ("PUT", "/api/outputs/set"):
                selected.set(true)                        // every (re-)select sticks
                return .status(204)
            default:                      return .status(204)
            }
        }
        let backend = makeBackend()
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        backend.setOutputSet(["s1"])
        _ = await collect(from: backend, timeout: 4) { [self] events in
            states(of: "s1", in: events).contains(.connected)
        }

        // Silent drop: OwnTone deselects without the app having asked.
        selected.set(false)
        let events = await collect(from: backend, timeout: 4) { [self] events in
            let observed = states(of: "s1", in: events)
            guard let r = observed.firstIndex(of: .reconnecting) else { return false }
            return observed[r...].contains(.connected)
        }
        let observed = states(of: "s1", in: events)
        guard let reconnecting = observed.firstIndex(of: .reconnecting) else {
            Issue.record("expected .reconnecting after a zombie drop, got \(observed)")
            return
        }
        #expect(observed[reconnecting...].contains(.connected),
                "successful recovery must return to .connected")
    }

    /// Zombie drop where recovery fails: `.reconnecting →
    /// .failed(.droppedMidStream)` — and the device stays available (§1
    /// changed behaviour: the session failed, not the network).
    @Test func zombieRecoveryFailureEndsFailedDroppedMidStreamAndAvailable() async {
        let selected = Locked(false)
        let allowSelect = Locked(true)
        setHandler { [self] request in
            switch (request.httpMethod ?? "", request.url!.path) {
            case ("GET", "/api/config"):  return .ok(configJSON)
            case ("GET", "/api/outputs"): return .ok(outputsJSON([("s1", "Speaker", "AirPlay 2", selected.get(), 50)]))
            case ("GET", "/api/player"):  return .ok(playerJSON(state: "play"))
            case ("PUT", "/api/outputs/set"):
                if allowSelect.get() { selected.set(true) }
                return .status(204)
            default:                      return .status(204)
            }
        }
        let backend = makeBackend()
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        backend.setOutputSet(["s1"])
        _ = await collect(from: backend, timeout: 4) { [self] events in
            states(of: "s1", in: events).contains(.connected)
        }

        // Silent drop, and this time the recovery re-select won't stick.
        allowSelect.set(false)
        selected.set(false)
        let events = await collect(from: backend, timeout: 4) { [self] events in
            lastFailure(of: "s1", in: events) != nil
        }
        #expect(lastFailure(of: "s1", in: events)?.cause == .droppedMidStream,
                "a failed reconnect must report .droppedMidStream")
        #expect(states(of: "s1", in: events).contains(.reconnecting),
                ".reconnecting must be emitted before the failure")
        let failedDevice = events.compactMap { event -> Device? in
            if case .deviceUpdated(let d) = event, case .failed = d.connectionState { return d }
            return nil
        }.last
        #expect(failedDevice?.isAvailable == true,
                "a mid-stream drop must keep the device available")
    }

    /// Timeout path: the confirm re-GET says selected, but no poll tick ever
    /// re-confirms it (a huge poll interval stands in for OwnTone's optimistic
    /// selected-then-revert window), so `.connecting` never resolves and the
    /// generation-token timeout fails it with `.timedOut`.
    @Test func connectingTimeoutFailsWithTimedOut() async {
        let selected = Locked(false)
        setHandler { [self] request in
            switch (request.httpMethod ?? "", request.url!.path) {
            case ("GET", "/api/config"):  return .ok(configJSON)
            case ("GET", "/api/outputs"): return .ok(outputsJSON([("s1", "Speaker", "AirPlay 2", selected.get(), 50)]))
            case ("GET", "/api/player"):  return .ok(playerJSON())
            case ("PUT", "/api/outputs/set"):
                selected.set(true)                        // confirm will see it…
                return .status(204)
            default:                      return .status(204)
            }
        }
        // pollInterval 60 → only the initial discovery poll + the confirm
        // re-GET run; the stability tick never comes.
        let backend = makeBackend(pollInterval: 60, connectingTimeout: 0.3)
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        backend.setOutputSet(["s1"])
        let events = await collect(from: backend, timeout: 4) { [self] events in
            lastFailure(of: "s1", in: events) != nil
        }
        #expect(lastFailure(of: "s1", in: events)?.cause == .timedOut,
                "an unresolved .connecting must fail as .timedOut when the timeout fires")
        #expect(!states(of: "s1", in: events).contains(.connected),
                "the device never stabilized, so .connected must never be emitted")
    }

    /// `stop()` clears the connection lifecycle: a pending connecting timeout
    /// must never fire after the backend is stopped.
    @Test func stopCancelsPendingConnectingTimeout() async {
        let selected = Locked(false)
        setHandler { [self] request in
            switch (request.httpMethod ?? "", request.url!.path) {
            case ("GET", "/api/config"):  return .ok(configJSON)
            case ("GET", "/api/outputs"): return .ok(outputsJSON([("s1", "Speaker", "AirPlay 2", selected.get(), 50)]))
            case ("GET", "/api/player"):  return .ok(playerJSON())
            case ("PUT", "/api/outputs/set"):
                selected.set(true)
                return .status(204)
            default:                      return .status(204)
            }
        }
        let backend = makeBackend(pollInterval: 60, connectingTimeout: 0.2)
        backend.start()
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        // Watch the stream across the stop so a late .failed would be caught.
        let box = EventCollector()
        let watcher = Task {
            for await event in backend.makeEventStream() {
                if case .level = event { continue }
                _ = await box.append(event)
            }
        }
        backend.setOutputSet(["s1"])
        try? await Task.sleep(nanoseconds: 50_000_000)
        backend.stop()

        // Outlive the 0.2 s timeout — nothing may fail after stop.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let events = await box.all
        watcher.cancel()
        #expect(lastFailure(of: "s1", in: events) == nil,
                "stop() must cancel pending timeouts — no .failed after teardown")
    }

    /// `stop()` during an in-flight confirm re-GET: the resumed confirm's
    /// `applyPoll` must not resurrect devices — re-populating `known`/`order`
    /// and emitting `deviceAdded`/`deviceUpdated` AFTER the teardown's
    /// `deviceRemoved` sweep — and a restart must begin from empty state.
    /// (stop() owns and cancels the select/confirm/recovery tasks; the
    /// `started` guard in `applyPoll` closes the remaining race.)
    @Test func stopDuringInFlightConfirmDoesNotResurrectDevices() async {
        let discoveryDone = Locked(false)
        setHandler { [self] request in
            switch (request.httpMethod ?? "", request.url!.path) {
            case ("GET", "/api/config"):  return .ok(configJSON)
            case ("GET", "/api/outputs"):
                if discoveryDone.get() {
                    // Hold the confirm re-GET long enough for stop() to land
                    // mid-flight (pollInterval 60 → no other GET arrives).
                    Thread.sleep(forTimeInterval: 0.3)
                } else {
                    discoveryDone.set(true)   // the discovery poll answers instantly
                }
                return .ok(outputsJSON([("s1", "Speaker", "AirPlay 2", true, 50)]))
            case ("GET", "/api/player"):  return .ok(playerJSON(state: "play"))
            default:                      return .status(204)
            }
        }
        let backend = makeBackend(pollInterval: 60)
        backend.start()
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        // Watch the stream across the stop so a post-teardown resurrection
        // (any add/update after the deviceRemoved sweep) would be caught.
        let box = EventCollector()
        let watcher = Task {
            for await event in backend.makeEventStream() {
                if case .level = event { continue }
                _ = await box.append(event)
            }
        }
        backend.setOutputSet(["s1"])
        try? await Task.sleep(nanoseconds: 100_000_000)   // PUT lands; the confirm re-GET is held
        backend.stop()

        // Outlive the held re-GET: the resumed confirm must find a dead backend.
        try? await Task.sleep(nanoseconds: 600_000_000)
        let events = await box.all
        watcher.cancel()
        #expect(backend.devices.isEmpty,
                "an in-flight confirm must not re-populate devices after stop()")
        guard let removal = events.lastIndex(where: { if case .deviceRemoved = $0 { return true } else { return false } }) else {
            Issue.record("stop() must emit deviceRemoved for the known device")
            return
        }
        #expect(events[(removal + 1)...].isEmpty,
                "no deviceAdded/deviceUpdated may follow the stop() teardown sweep, got \(events[(removal + 1)...])")
    }

    /// The fire-and-forget diagnosis flow (brief §3): the immediate best-guess
    /// failure is emitted first, then replaced by the diagnosed one while the
    /// device is still `.failed`. The `DiagnosisContext` must carry the
    /// captured auth flag and the prior cause.
    @Test func diagnosisReplacesInitialFailureAndGetsAuthFlags() async {
        setHandler { [self] request in
            switch request.url!.path {
            case "/api/config":  return .ok(configJSON)
            // Never selects (enable always fails) + requires_auth:true so the
            // backend's per-id auth capture has something to pick up.
            case "/api/outputs": return .ok(outputsJSON([("dead", "Locked Speaker", "AirPlay 2", false, 40)],
                                                        requiresAuth: true))
            case "/api/player":  return .ok(playerJSON())
            default:             return .status(204)
            }
        }
        let diagnosed = ConnectionFailure(cause: .notResponding, detail: "probe: TCP ready, RTSP silent")
        let diagnostics = RecordingDiagnostics(result: diagnosed)
        let backend = makeBackend()
        backend.diagnostics = diagnostics
        backend.start(); defer { backend.stop() }
        _ = await collect(from: backend) { $0.contains { if case .deviceAdded = $0 { return true } else { return false } } }

        backend.setOutputSet(["dead"])

        let events = await collect(from: backend, timeout: 4) { [self] events in
            lastFailure(of: "dead", in: events) == diagnosed
        }
        // The best guess lands first, the diagnosis replaces it.
        let failures = states(of: "dead", in: events).compactMap { state -> ConnectionFailure? in
            if case .failed(let f) = state { return f }
            return nil
        }
        #expect(failures.first?.cause == .unknown,
                "the immediate best-guess failure must be emitted before diagnosis returns")
        #expect(failures.last == diagnosed,
                "the diagnosed failure must replace the best guess")
        let context = diagnostics.recorded.get()
        #expect(context?.deviceID == "dead")
        #expect(context?.deviceName == "Locked Speaker")
        #expect(context?.requiresAuth == true, "the polled requires_auth flag must reach the diagnoser")
        #expect(context?.priorCause == .unknown)
    }
}

// MARK: - Test support

/// Thread-safe box for scripting stub state and asserting captured values.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}

private actor EventCollector {
    private(set) var all: [BackendEvent] = []
    func append(_ event: BackendEvent) -> [BackendEvent] { all.append(event); return all }
}

/// A `ConnectionDiagnosing` fake: records the context it was handed and
/// returns a canned failure, so the backend's fire-and-forget replacement flow
/// is testable without any real probes.
private struct RecordingDiagnostics: ConnectionDiagnosing {
    let recorded = Locked<DiagnosisContext?>(nil)
    let result: ConnectionFailure

    func diagnose(_ context: DiagnosisContext) async -> ConnectionFailure {
        recorded.set(context)
        return result
    }
}

extension URLRequest {
    /// `URLProtocol` strips `httpBody` for some methods, exposing it only via
    /// `httpBodyStream`. Read whichever is present so stubs can inspect bodies.
    func bodyData() -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

/// A scriptable `URLProtocol` stub. Tests set a handler (keyed by their own
/// unique test id) to map a request to a canned `Response`; `.refused`
/// simulates connection-refused so the unreachable/backoff path is exercised
/// without a real socket.
///
/// **Not a single global `handler` any more.** swift-testing can run multiple
/// `@Test`s concurrently in one process, and two tests racing to overwrite one
/// shared `static var handler` would silently cross-contaminate each other's
/// stubbed responses. Instead each test tags its `URLSessionConfiguration`
/// with a unique id header (`testIDHeaderField`); `startLoading()` reads that
/// header back off the actual request and looks up only that test's handler in
/// a lock-protected dictionary.
final class StubURLProtocol: URLProtocol {

    struct Response {
        let statusCode: Int
        let body: Data
        let refuse: Bool

        static func ok(_ body: Data) -> Response { Response(statusCode: 200, body: body, refuse: false) }
        static func status(_ code: Int) -> Response { Response(statusCode: code, body: Data(), refuse: false) }
        /// A non-2xx with an HTML body (brief §5: error bodies are HTML).
        static func html(_ code: Int) -> Response {
            Response(statusCode: code, body: Data("<html><body>error</body></html>".utf8), refuse: false)
        }
        static let refused = Response(statusCode: 0, body: Data(), refuse: true)
    }

    /// Header carrying the requesting test's unique id, set via
    /// `URLSessionConfiguration.httpAdditionalHeaders` in each test's session.
    static let testIDHeaderField = "X-Test-Stub-ID"

    private static let lock = NSLock()
    private static var handlersByTestID: [String: @Sendable (URLRequest) -> Response] = [:]

    /// Register `handler` for one test's id. Overwrites any previous handler
    /// for the same id (a test re-scripting mid-run), never another test's.
    static func register(_ handler: @escaping @Sendable (URLRequest) -> Response, for testID: String) {
        lock.lock(); handlersByTestID[testID] = handler; lock.unlock()
    }

    /// Drop a test's handler once it's done — called from the suite's `deinit`.
    static func unregister(_ testID: String) {
        lock.lock(); handlersByTestID.removeValue(forKey: testID); lock.unlock()
    }

    private static func handler(for testID: String?) -> (@Sendable (URLRequest) -> Response)? {
        guard let testID else { return nil }
        lock.lock(); defer { lock.unlock() }
        return handlersByTestID[testID]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let testID = request.value(forHTTPHeaderField: StubURLProtocol.testIDHeaderField)
        guard let handler = StubURLProtocol.handler(for: testID) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        let response = handler(request)
        if response.refuse {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.statusCode,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": response.statusCode >= 400 ? "text/html" : "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
