import XCTest
@testable import AirPlayControllerCore

/// Unit tests for the real `OwnToneBackend` and its `OwnToneClient`, run against
/// a stubbed `URLProtocol` — **never** the live OwnTone server. The stub lets a
/// test script per-path responses (and simulate connection-refused), so we can
/// exercise the poll-diff, silent-select-failure, zombie-recovery, empty-queue,
/// and unreachable-backoff paths hermetically.
///
/// Grounded in `dev/notes/p1-owntone-api-brief.md` (poll-primary, re-GET after
/// outputs/set, HTML error bodies, 500-on-empty-queue, "AirPlay 1"/"AirPlay 2").
final class OwnToneBackendTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    /// A backend wired to the stubbed transport, no real websocket, fast polls.
    private func makeBackend(pollInterval: TimeInterval = 0.05) -> OwnToneBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OwnToneClient(session: session, timeout: 2)
        return OwnToneBackend(client: client, webSocket: nil,
                              pollInterval: pollInterval, unreachablePollInterval: 0.05)
    }

    /// Collect non-level events until `predicate` is satisfied or timeout.
    private func collect(
        from backend: OwnToneBackend,
        timeout: TimeInterval = 3,
        until predicate: @escaping @Sendable ([BackendEvent]) -> Bool
    ) async -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let done = expectation(description: "predicate satisfied")
        let box = EventCollector()
        let task = Task {
            for await event in stream {
                if case .level = event { continue }
                let all = await box.append(event)
                if predicate(all) { done.fulfill(); break }
            }
        }
        await fulfillment(of: [done], timeout: timeout)
        task.cancel()
        return await box.all
    }

    private func outputsJSON(_ outputs: [(id: String, name: String, type: String, selected: Bool, volume: Int)]) -> Data {
        let objs = outputs.map { o in
            """
            {"id":"\(o.id)","name":"\(o.name)","type":"\(o.type)","selected":\(o.selected),"volume":\(o.volume),"has_password":false,"requires_auth":false,"needs_auth_key":false,"offset_ms":0,"format":"alac","supported_formats":["alac"]}
            """
        }.joined(separator: ",")
        return Data("{\"outputs\":[\(objs)]}".utf8)
    }

    private func playerJSON(state: String = "stop", volume: Int = 50) -> Data {
        Data("{\"state\":\"\(state)\",\"repeat\":\"off\",\"consume\":false,\"shuffle\":false,\"volume\":\(volume),\"item_id\":0,\"item_length_ms\":0,\"item_progress_ms\":0}".utf8)
    }

    private var configJSON: Data { Data("{\"version\":\"29.2\",\"websocket_port\":3688}".utf8) }

    // MARK: Tests

    /// Poll discovers outputs and emits `deviceAdded`, mapping the "AirPlay 1"/
    /// "AirPlay 2" type prefix onto `supportsAirPlay2` (brief don't-assume #5).
    func testPollDiscoveryEmitsDeviceAddedWithTypeMapping() async {
        StubURLProtocol.handler = { [self] request in
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
        XCTAssertEqual(lg?.supportsAirPlay2, true, "\"AirPlay 2\" → supportsAirPlay2 true")
        XCTAssertEqual(express?.supportsAirPlay2, false, "\"AirPlay 1\" → supportsAirPlay2 false")
    }

    /// A field change between polls emits exactly one `deviceUpdated` with the
    /// new value (poll-diff, not a re-add).
    func testPollDiffEmitsDeviceUpdatedOnVolumeChange() async {
        let volume = Locked(50)
        StubURLProtocol.handler = { [self] request in
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
        XCTAssertTrue(events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "111" && d.volume == 80 } else { return false } })
    }

    /// An output absent from a later poll emits `deviceRemoved`.
    func testPollDiffEmitsDeviceRemovedWhenOutputVanishes() async {
        let present = Locked(true)
        StubURLProtocol.handler = { [self] request in
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
        XCTAssertTrue(events.contains { if case .deviceRemoved(let id) = $0 { return id == "222" } else { return false } })
    }

    /// Silent-select-failure: `outputs/set` 204s but the re-GET shows the target
    /// still `selected:false`. The backend must detect it (brief don't-assume #2)
    /// and run recovery (re-issue outputs/set). Here recovery keeps failing, so
    /// the device ends up surfaced as unavailable (device-level error state).
    func testSilentSelectFailureDetectedAndSurfacedAsError() async {
        let setCalls = Locked(0)
        StubURLProtocol.handler = { [self] request in
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
        // still false → device surfaced unavailable, and it stops retrying.
        let events = await collect(from: backend, timeout: 4) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "dead" && !d.isAvailable } else { return false } }
        }
        XCTAssertTrue(events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "dead" && !d.isAvailable } else { return false } },
                      "a persistently-failing selection should surface the device as unavailable")
        // outputs/set was called at least twice: the initial set + the recovery re-select.
        XCTAssertGreaterThanOrEqual(setCalls.get(), 2, "recovery must re-issue outputs/set")
    }

    /// Zombie recovery success path: the selection sticks on the recovery
    /// re-select, and the `replayHook` (the coordinator's clear→add→play half)
    /// is invoked as part of recovery (brief §4 step 4).
    func testZombieRecoveryReselectsAndInvokesReplayHook() async {
        let selected = Locked(false)
        let setCalls = Locked(0)
        StubURLProtocol.handler = { [self] request in
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
        XCTAssertTrue(events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "s1" && d.isSelected } else { return false } },
                      "recovery should end with the output actually selected")
        XCTAssertTrue(replayed.get(), "the coordinator replay hook must fire during recovery")
    }

    /// Empty-queue guard: `player/play` on an empty queue is a hard 500 (brief
    /// don't-assume #4). The client surfaces it as `.http(500)` rather than
    /// masking it, so a caller (the coordinator) can guard.
    func testPlayOnEmptyQueueSurfaces500() async {
        StubURLProtocol.handler = { request in
            if request.url!.path == "/api/player/play" { return .html(500) }
            return .status(204)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = OwnToneClient(session: URLSession(configuration: config), timeout: 2)

        do {
            try await client.play()
            XCTFail("player/play on an empty queue should throw, not succeed")
        } catch let error as OwnToneClient.ClientError {
            XCTAssertEqual(error, .http(status: 500))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// Connection-refused: the client maps `URLError.cannotConnectToHost` to
    /// `.unreachable`, and the backend surfaces every known device as unavailable
    /// (Q7 connect-only) while continuing to poll (no crash, no supervise).
    func testConnectionRefusedSurfacesUnreachableAndKeepsPolling() async {
        // Start reachable so a device is discovered, then flip to refused.
        let refused = Locked(false)
        StubURLProtocol.handler = { [self] request in
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
        XCTAssertTrue(events.contains { if case .deviceUpdated(let d) = $0 { return !d.isAvailable } else { return false } },
                      "connection-refused should mark known devices unavailable")

        // And it recovers automatically when the server comes back.
        refused.set(false)
        let back = await collect(from: backend, timeout: 4) { events in
            events.contains { if case .deviceUpdated(let d) = $0 { return d.id == "111" && d.isAvailable } else { return false } }
        }
        XCTAssertTrue(back.contains { if case .deviceUpdated(let d) = $0 { return d.isAvailable } else { return false } },
                      "polling should resume and re-mark devices available when OwnTone returns")
    }

    /// Client-level: out-of-range volume is caller-clamped (the backend clamps
    /// with `.clampedToVolume` before calling), so the client never sends >100.
    func testSetVolumeClampsBeforeSending() async {
        let sentVolume = Locked(-1)
        StubURLProtocol.handler = { request in
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
        // Give the async PUT a moment.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sentVolume.get(), 100, "the backend must clamp to 100 before PUT — OwnTone 400s on out-of-range")
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

/// A scriptable `URLProtocol` stub. Tests set `handler` to map a request to a
/// canned `Response`; `.refused` simulates connection-refused so the
/// unreachable/backoff path is exercised without a real socket.
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

    /// Set by each test. `nonisolated(unsafe)`-style access guarded by the tests'
    /// single-threaded setup; the closure itself must be thread-safe (uses `Locked`).
    static var handler: (@Sendable (URLRequest) -> Response)?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
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
