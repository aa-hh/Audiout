import Foundation
import Testing
import Network
@testable import AudioutCore

/// Unit tests for the DACP request parsing + volume mapping (speaker-input task,
/// phase 2). Pure — no sockets, no Bonjour. This is the exact wire format an
/// AirPlay receiver sends when the user changes volume ON THE SPEAKER.
@Suite struct DACPServerTests {

    private func request(_ raw: String) -> DACPServer.DACPRequest? {
        DACPServer.parse(Data(raw.utf8))
    }

    // MARK: - setproperty device-volume (the real Sonos volume report)

    @Test func parsesAbsoluteDeviceVolume() {
        let raw = "GET /ctrl-int/1/setproperty?dmcp.device-volume=-16.500000 HTTP/1.1\r\n"
            + "Host: mymac.local.\r\n"
            + "Active-Remote: 460916894\r\n"
            + "\r\n"
        let req = request(raw)
        #expect(req?.command == "setproperty")
        #expect(req?.activeRemote == 460916894)
        #expect(req?.query["dmcp.device-volume"] == "-16.500000")
        #expect(abs((req?.deviceVolumeDb ?? 0) - -16.5) <= 0.0001)
    }

    @Test func muteSentinelParses() {
        let req = request("GET /ctrl-int/1/setproperty?dmcp.device-volume=-144.000000 HTTP/1.1\r\nActive-Remote: 7\r\n\r\n")
        #expect(abs((req?.deviceVolumeDb ?? 0) - -144) <= 0.001)
    }

    // MARK: - other verbs

    @Test func parsesRelativeAndTransportVerbs() {
        #expect(request("GET /ctrl-int/1/volumeup HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.command == "volumeup")
        #expect(request("GET /ctrl-int/1/pause HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.command == "pause")
        // A non-setproperty verb has no device volume.
        #expect(request("GET /ctrl-int/1/volumeup HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.deviceVolumeDb == nil)
    }

    @Test func activeRemoteCaseInsensitiveAndOptional() {
        // Header name casing varies across receivers.
        #expect(request("GET /ctrl-int/1/pause HTTP/1.1\r\nactive-remote: 42\r\n\r\n")?.activeRemote == 42)
        // Missing header → nil token (dispatch will drop it).
        #expect(request("GET /ctrl-int/1/pause HTTP/1.1\r\nHost: x\r\n\r\n")?.activeRemote == nil)
    }

    @Test func nonControlRequestIsRejected() {
        #expect(request("GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
        #expect(request("") == nil)
    }

    // MARK: - dB → 0…1 level mapping (mirrors the outbound map)

    @Test func volumeLevelMapping() {
        #expect(abs(DACPServer.level(fromDb: -144) - 0) <= 0.0001) // mute
        #expect(abs(DACPServer.level(fromDb: -30) - 0) <= 0.0001)  // min
        #expect(abs(DACPServer.level(fromDb: -15) - 0.5) <= 0.0001) // mid
        #expect(abs(DACPServer.level(fromDb: 0) - 1) <= 0.0001)     // max
        #expect(abs(DACPServer.level(fromDb: 5) - 1) <= 0.0001)     // clamp above
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

    /// A `@Sendable`-safe one-shot flag. Replaces `XCTestCase.expectation` +
    /// `wait(for:)`, which are `XCTestCase` instance members and therefore
    /// unavailable inside a swift-testing `@Suite struct`. Network callbacks
    /// fire on `netQueue`, so the flag is lock-guarded.
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false
        func fire() { lock.withLock { _fired = true } }
        var fired: Bool { lock.withLock { _fired } }
    }

    /// Spin (not block) until every signal has fired or `timeout` elapses.
    /// Returns whether all fired. Same shape as the listener `.ready` wait
    /// below — deliberately consistent rather than introducing a second idiom.
    private func waitFor(_ signals: [Signal], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if signals.allSatisfy(\.fired) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return signals.allSatisfy(\.fired)
    }

    /// A same-process loopback TCP pair. `serverSide` is exactly what a
    /// listener's `newConnectionHandler` sees on accept: an un-started
    /// connection, ready to hand to `DACPServer.accept(_:)` directly, just
    /// like the production listener does.
    private func makeLoopbackPair() throws -> (listener: NWListener, client: NWConnection, serverSide: NWConnection) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)

        var serverSideConnection: NWConnection?
        let accepted = Signal()
        listener.newConnectionHandler = { connection in
            serverSideConnection = connection
            accepted.fire()
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
        // swift-testing has no runtime skip, so an environment that cannot
        // bind loopback FAILS loudly instead of passing silently. The bind
        // is deliberately narrowed to 127.0.0.1 (see the comment above)
        // precisely so this is reliable; if it ever does flake, that should
        // be visible.
        try #require(isReady, "test loopback listener never reached .ready")
        let port = try #require(listener.port, "listener bound no port")
        try #require(port.rawValue != 0, "listener port never left the placeholder 0")

        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let clientReady = Signal()
        client.stateUpdateHandler = { state in
            if case .ready = state { clientReady.fire() }
        }
        client.start(queue: netQueue)

        #expect(waitFor([accepted, clientReady], timeout: 2),
                "loopback pair did not come up within 2s")
        guard let serverSide = serverSideConnection else {
            listener.cancel()
            client.cancel()
            throw LoopbackUnavailable()
        }
        return (listener, client, serverSide)
    }

    /// The bug this guards: a peer that opens a TCP connection to the DACP
    /// listener and never sends anything (a network scanner, a
    /// misbehaving/probing client, a flaky receiver that half-opens) used to
    /// stay in `connections` — and hold its kernel socket open — for as long
    /// as the server ran, since nothing ever timed it out.
    @Test func idleConnectionIsCancelledAfterItsTimeout() throws {
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
        let idleClosed = Signal()
        client.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { idleClosed.fire() }
        }
        #expect(waitFor([idleClosed], timeout: 2),
                "the server never cancelled the idle connection")
    }

    /// Regression check for the idle-timeout hardening: a connection that
    /// sends a real request promptly must still dispatch it and get its
    /// `204` back — the idle-timeout machinery must not disturb the normal
    /// (non-idle) path.
    @Test func realRequestStillDispatchesAndGetsA204() throws {
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
        let volumeReported = Signal()
        server.onVolume = { token, level in
            #expect(token == 460916894)
            #expect(abs(level - DACPServer.level(fromDb: -16.5)) < 0.0001)
            volumeReported.fire()
        }
        defer { server.stop() }
        server.accept(serverSide)

        let request = "GET /ctrl-int/1/setproperty?dmcp.device-volume=-16.500000 HTTP/1.1\r\n"
            + "Active-Remote: 460916894\r\n\r\n"
        client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })

        let responseReceived = Signal()
        var responseText: String?
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            if let data { responseText = String(data: data, encoding: .utf8) }
            responseReceived.fire()
        }
        #expect(waitFor([volumeReported, responseReceived], timeout: 2),
                "the request round trip did not complete within 2s")
        #expect(responseText?.hasPrefix("HTTP/1.1 204 No Content") == true)
    }
}

/// Thrown when the same-process loopback pair cannot be established at all.
/// swift-testing has no runtime skip, so this surfaces as a real failure
/// rather than a silent pass.
private struct LoopbackUnavailable: Error, CustomStringConvertible {
    var description: String { "loopback connection was never accepted" }
}
