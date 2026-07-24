import XCTest
import Network
@testable import AudiouterCore

/// Unit tests for the DACP request parsing + volume mapping (speaker-input task,
/// phase 2). Pure — no sockets, no Bonjour. This is the exact wire format an
/// AirPlay receiver sends when the user changes volume ON THE SPEAKER.
final class DACPServerTests: XCTestCase {

    private func request(_ raw: String) -> DACPServer.DACPRequest? {
        DACPServer.parse(Data(raw.utf8))
    }

    // MARK: - setproperty device-volume (the real Sonos volume report)

    func testParsesAbsoluteDeviceVolume() {
        let raw = "GET /ctrl-int/1/setproperty?dmcp.device-volume=-16.500000 HTTP/1.1\r\n"
            + "Host: mymac.local.\r\n"
            + "Active-Remote: 460916894\r\n"
            + "\r\n"
        let req = request(raw)
        XCTAssertEqual(req?.command, "setproperty")
        XCTAssertEqual(req?.activeRemote, 460916894)
        XCTAssertEqual(req?.query["dmcp.device-volume"], "-16.500000")
        XCTAssertEqual(req?.deviceVolumeDb ?? 0, -16.5, accuracy: 0.0001)
    }

    func testMuteSentinelParses() {
        let req = request("GET /ctrl-int/1/setproperty?dmcp.device-volume=-144.000000 HTTP/1.1\r\nActive-Remote: 7\r\n\r\n")
        XCTAssertEqual(req?.deviceVolumeDb ?? 0, -144, accuracy: 0.001)
    }

    // MARK: - other verbs

    func testParsesRelativeAndTransportVerbs() {
        XCTAssertEqual(request("GET /ctrl-int/1/volumeup HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.command, "volumeup")
        XCTAssertEqual(request("GET /ctrl-int/1/pause HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.command, "pause")
        // A non-setproperty verb has no device volume.
        XCTAssertNil(request("GET /ctrl-int/1/volumeup HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.deviceVolumeDb)
    }

    func testActiveRemoteCaseInsensitiveAndOptional() {
        // Header name casing varies across receivers.
        XCTAssertEqual(request("GET /ctrl-int/1/pause HTTP/1.1\r\nactive-remote: 42\r\n\r\n")?.activeRemote, 42)
        // Missing header → nil token (dispatch will drop it).
        XCTAssertNil(request("GET /ctrl-int/1/pause HTTP/1.1\r\nHost: x\r\n\r\n")?.activeRemote)
    }

    func testNonControlRequestIsRejected() {
        XCTAssertNil(request("GET /favicon.ico HTTP/1.1\r\n\r\n"))
        XCTAssertNil(request(""))
    }

    // MARK: - dB → 0…1 level mapping (mirrors the outbound map)

    func testVolumeLevelMapping() {
        XCTAssertEqual(DACPServer.level(fromDb: -144), 0, accuracy: 0.0001) // mute
        XCTAssertEqual(DACPServer.level(fromDb: -30), 0, accuracy: 0.0001)  // min
        XCTAssertEqual(DACPServer.level(fromDb: -15), 0.5, accuracy: 0.0001) // mid
        XCTAssertEqual(DACPServer.level(fromDb: 0), 1, accuracy: 0.0001)     // max
        XCTAssertEqual(DACPServer.level(fromDb: 5), 1, accuracy: 0.0001)     // clamp above
    }

    // MARK: - Idle-connection timeout (unbounded-growth hardening)
    //
    // These drive `accept(_:)` directly with a real loopback `NWConnection`,
    // rather than going through `start(dacpID:)`'s own listener. That
    // listener binds ALL interfaces and Bonjour-advertises — neither of
    // which these tests need, and an all-interfaces bind is exactly what
    // trips macOS's Application Firewall "accept incoming network
    // connections?" prompt for the xctest process on a `swift test` run
    // (the same root cause already fixed for the PTP test daemon; see
    // PTPHelperIPCTests.swift's loopback-bind comment). The loopback pair
    // built here is ALSO restricted to `127.0.0.1` via
    // `requiredLocalEndpoint`, for the same reason. `accept(_:)` is
    // `internal` (not `private`) expressly so a test can hand it a real
    // connection like this — see its doc comment.

    /// A same-process loopback TCP pair. `serverSide` is exactly what a
    /// listener's `newConnectionHandler` sees on accept: an un-started
    /// connection, ready to hand to `DACPServer.accept(_:)` directly, just
    /// like the production listener does.
    private func makeLoopbackPair() throws -> (listener: NWListener, client: NWConnection, serverSide: NWConnection) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)

        var serverSideConnection: NWConnection?
        let accepted = expectation(description: "loopback connection accepted")
        listener.newConnectionHandler = { connection in
            serverSideConnection = connection
            accepted.fulfill()
        }
        // With `requiredLocalEndpoint`'s port pinned to `.any`, `listener.port`
        // populates EARLY as `0` (echoing that request) rather than staying
        // nil until bound — confirmed with a standalone repro against this
        // SDK. Wait for the `.ready` state itself, not a non-nil `.port`,
        // and only then read the real assigned port.
        var isReady = false
        listener.stateUpdateHandler = { state in
            if case .ready = state { isReady = true }
        }
        let netQueue = DispatchQueue(label: "DACPServerTests.loopback")
        listener.start(queue: netQueue)

        let readyDeadline = Date().addingTimeInterval(2)
        while !isReady && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard isReady, let port = listener.port, port.rawValue != 0 else {
            listener.cancel()
            throw XCTSkip("test loopback listener never reached .ready with a bound port; skipping (likely sandboxing/port contention)")
        }

        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let clientReady = expectation(description: "client connection ready")
        client.stateUpdateHandler = { state in
            if case .ready = state { clientReady.fulfill() }
        }
        client.start(queue: netQueue)

        wait(for: [accepted, clientReady], timeout: 2)
        guard let serverSide = serverSideConnection else {
            listener.cancel()
            client.cancel()
            throw XCTSkip("loopback connection was never accepted")
        }
        return (listener, client, serverSide)
    }

    /// The bug this guards: a peer that opens a TCP connection to the DACP
    /// listener and never sends anything (a network scanner, a
    /// misbehaving/probing client, a flaky receiver that half-opens) used to
    /// stay in `connections` — and hold its kernel socket open — for as long
    /// as the server ran, since nothing ever timed it out.
    func testIdleConnectionIsCancelledAfterItsTimeout() throws {
        let (listener, client, serverSide) = try makeLoopbackPair()
        defer { listener.cancel(); client.cancel() }

        let server = DACPServer()
        server.test_idleReceiveTimeoutOverride = 0.3 // real default is 30s
        defer { server.stop() }
        server.accept(serverSide)

        // Deliberately send nothing — the exact "idle peer" shape the
        // timeout exists for. The client's own pending receive should
        // complete (EOF or error) once the server closes its end after the
        // shortened idle deadline, rather than hang forever waiting on data
        // that will never arrive.
        let idleClosed = expectation(description: "server cancelled the idle connection")
        client.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { idleClosed.fulfill() }
        }
        wait(for: [idleClosed], timeout: 2)
    }

    /// Regression check for the idle-timeout hardening: a connection that
    /// sends a real request promptly must still dispatch it and get its
    /// `204` back — the idle-timeout machinery must not disturb the normal
    /// (non-idle) path.
    func testRealRequestStillDispatchesAndGetsA204() throws {
        let (listener, client, serverSide) = try makeLoopbackPair()
        defer { listener.cancel(); client.cancel() }

        let server = DACPServer()
        // Short on purpose: proves the round trip completes well inside the
        // idle window on its own merits, not because the timeout happens to
        // be generous.
        server.test_idleReceiveTimeoutOverride = 0.3
        // `onVolume` is `@Sendable` (DACPServer.swift), so the compiler
        // rightly refuses to let this closure mutate a captured local `var`
        // — assert inline instead of capturing the reported values out.
        let volumeReported = expectation(description: "onVolume fired")
        server.onVolume = { token, level in
            XCTAssertEqual(token, 460916894)
            XCTAssertEqual(level, DACPServer.level(fromDb: -16.5), accuracy: 0.0001)
            volumeReported.fulfill()
        }
        defer { server.stop() }
        server.accept(serverSide)

        let request = "GET /ctrl-int/1/setproperty?dmcp.device-volume=-16.500000 HTTP/1.1\r\n"
            + "Active-Remote: 460916894\r\n\r\n"
        client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })

        let responseReceived = expectation(description: "204 response received")
        var responseText: String?
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            if let data { responseText = String(data: data, encoding: .utf8) }
            responseReceived.fulfill()
        }
        wait(for: [volumeReported, responseReceived], timeout: 2)
        XCTAssertEqual(responseText?.hasPrefix("HTTP/1.1 204 No Content"), true)
    }
}
