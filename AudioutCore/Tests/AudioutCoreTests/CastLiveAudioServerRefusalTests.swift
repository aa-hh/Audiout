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

/// `CastLiveAudioServer` refuses a connection two ways and used to cancel the
/// socket without a word either time, so a wrongly refused GET from the
/// receiver's own address left nothing in the log and stalled the session
/// until the 20 s play deadline (live failure, 2026-09-20). These tests hold
/// `onRefused` to reporting BOTH refusals, with the peer that arrived.
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
    private func refusal(allowedPeer: String?, maxConnections: Int) throws -> (reason: String, peer: String)? {
        let server = CastLiveAudioServer(
            source: SineSource(),
            loopbackOnly: true,
            allowedPeer: allowedPeer,
            maxConnections: maxConnections
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
}
