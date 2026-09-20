// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network
import Testing
@testable import CastSender

/// `CastLiveAudioServer` turns a connection away three ways and used to cancel
/// the socket without a word every time, so a wrongly refused GET from the
/// receiver's own address left nothing in the log and stalled the session
/// until the 20 s play deadline (live failure, 2026-09-20). These tests hold
/// `onRefused` to reporting ALL THREE, with the peer that arrived, and to
/// staying silent about a connection that was served.
@Suite struct CastLiveAudioServerRefusalTests {

    private final class RefusalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (reason: String, peer: String)?
        func set(_ reason: String, _ peer: String) { lock.withLock { stored = (reason, peer) } }
        var value: (reason: String, peer: String)? { lock.withLock { stored } }
    }

    private final class PortBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt16?
        func set(_ port: UInt16) { lock.withLock { stored = port } }
        var value: UInt16? { lock.withLock { stored } }
    }

    /// Connects once to a loopback-only server and returns whatever refusal it
    /// reported, or nil if it accepted the connection.
    private func refusal(
        allowedPeer: String?,
        maxConnections: Int,
        idleDeadline: TimeInterval = 30,
        sending request: String? = nil
    ) throws -> (reason: String, peer: String)? {
        let server = CastLiveAudioServer(
            source: SineSource(),
            loopbackOnly: true,
            allowedPeer: allowedPeer,
            maxConnections: maxConnections,
            idleDeadline: idleDeadline
        )
        defer { server.stop() }
        let refused = RefusalBox()
        server.onRefused = { reason, peer in refused.set(reason, peer) }
        let bound = PortBox()
        server.start { result in
            if case .success(let port) = result { bound.set(port) }
        }
        var deadline = Date().addingTimeInterval(2)
        while bound.value == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        let port = try #require(bound.value, "live audio server never bound a loopback port")

        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "CastLiveAudioServerRefusalTests"))
        defer { connection.cancel() }
        if let request {
            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        }
        deadline = Date().addingTimeInterval(2)
        while refused.value == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        return refused.value
    }

    @Test func reportsThePeerItTurnedAway() throws {
        let reported = try refusal(allowedPeer: "10.0.0.1", maxConnections: 32)
        let refused = try #require(reported, "a connection from the wrong peer was refused with no report")
        #expect(refused.reason == "wrong_peer")
        #expect(refused.peer.contains("127.0.0.1"))
    }

    @Test func reportsAConnectionCapRefusal() throws {
        let reported = try refusal(allowedPeer: nil, maxConnections: 0)
        let refused = try #require(reported, "a connection over the cap was refused with no report")
        #expect(refused.reason == "max_connections")
        #expect(refused.peer.contains("127.0.0.1"))
    }

    /// A receiver that connects and then asks for nothing is cancelled at the
    /// idle deadline. That drop was the third silent one, so it looked from
    /// the log exactly like a receiver that never connected at all.
    @Test func reportsAConnectionDroppedForIdleness() throws {
        let reported = try refusal(allowedPeer: nil, maxConnections: 32, idleDeadline: 0.3)
        let refused = try #require(reported, "a connection dropped at the idle deadline was closed with no report")
        #expect(refused.reason == "idle_timeout")
        #expect(refused.peer.contains("127.0.0.1"))
    }

    /// The deadline is cancelled the moment a complete request head arrives,
    /// so a GET that was served is never a refusal — however long the stream
    /// then runs past that deadline.
    @Test func staysSilentForAConnectionItServed() throws {
        let reported = try refusal(
            allowedPeer: nil,
            maxConnections: 32,
            idleDeadline: 0.3,
            sending: "GET /audiout.wav HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        #expect(reported == nil, "a served GET was reported as a refusal")
    }
}
